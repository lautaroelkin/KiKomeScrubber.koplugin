-- kobold/ui/action_center.lua — KiKome
-- The Action center: a panel that comes down from the top edge and shows the
-- actions chosen in Settings > Your actions > Action center, as tiles. It opens
-- with a swipe down from the top edge on Home and Library (taps.lua) and inside
-- a book (main.lua), or with the "KiKome: Action center" action of KOReader's
-- gestures. It is off until it is turned on in Settings.
--
-- A tile is a grey rounded square with the action's icon and its name below.
-- An action that toggles something (night mode, the frontlight, Wi-Fi, the
-- accelerometer) shows its state: black with a white icon and "On" when it is
-- on, grey and "Off" when it is off. Tapping it changes it and the panel stays
-- open, so the new state is seen. Any other action closes the panel and runs.
-- Tap below the panel, swipe it up or press a key to close it; with more tiles
-- than fit, swipe left or right to turn the page. The pages are shown as short
-- horizontal lines above the handle: the current page is a longer black line,
-- the others short grey ones. Tapping a line goes to that page.
--
--   local ActionCenter = require("kobold.ui.action_center")
--   ActionCenter.enabled()          whether the swipe should open it
--   ActionCenter.show{ ui = ... }   opens it; ui is the reader inside a book (the
--                                   actions then run there), nil elsewhere

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local _              = require("kobold.i18n")
local ActionIcon     = require("kobold.ui.action_icon")
local CustomActions  = require("kobold.data.custom_actions")
local KoboldPrefs    = require("kobold.data.prefs")
local KoboldWidgets  = require("kobold.ui.widgets")
local OptionSheet    = require("kobold.ui.option_sheet")
local Refresh        = require("kobold.ui.refresh")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_TAG       = Blitbuffer.Color8(0xDD)   -- grey of a tile that is off (the same as Home's)
local C_RULE      = Blitbuffer.Color8(0x99)
local C_SECONDARY = Blitbuffer.Color8(0x55)

local SURFACE = "center"       -- which actions it shows (custom_actions.lua)
local PREF = "action_center"   -- the setting that turns it on

local function U(n) return Screen:scaleBySize(n) end

local ActionCenter = {}
local open_panel = nil   -- the panel on screen, if any

function ActionCenter.enabled()
    return KoboldPrefs.get(PREF) == true
end

-- ── The panel ──────────────────────────────────────────────────────────────
local Panel = InputContainer:extend{ ui = nil, page = 1 }

function Panel:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.ges_events = {
        TapCenter   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        SwipeCenter = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = {}
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self:build()
end

function Panel:release()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = {}
end

-- The actions to show, each with its state: { { c = action, on = true | false | nil }, ... }
local function entries()
    local out = {}
    for _i, c in ipairs(CustomActions.surfaceList(SURFACE)) do
        if c.enabled then
            out[#out + 1] = { c = c.action, on = CustomActions.state(c.action) }
        end
    end
    return out
end

-- A string that changes when the state of any tile changes.
function Panel:stateSig()
    local parts = {}
    for _i, e in ipairs(entries()) do
        parts[#parts + 1] = e.c.id .. ":" .. (e.on == nil and "-" or (e.on and "1" or "0"))
    end
    return table.concat(parts, ",")
end

function Panel:build()
    self:release()
    local function keep(w)
        self.widgets[#self.widgets + 1] = w
        return w
    end
    local W = Screen:getWidth()
    local inset = U(24)
    local tile, gap, label_gap, row_gap = U(72), U(14), U(6), U(14)
    local cols = math.max(3, math.min(6, math.floor((W - 2 * inset + gap) / (tile + gap))))
    local rows = 3
    local per_page = cols * rows

    -- heading and rule, like the sheets
    self.heading = keep(TextWidget:new{ text = _("Action center"), face = KoboldWidgets.face(17), bold = true })
    local center_y = U(34)
    self.heading_pos = { x = inset, y = center_y - math.floor(self.heading:getSize().h / 2) }
    self.rule = { x = U(17.5), y = center_y + U(24), w = W - 2 * U(17.5), h = math.max(1, U(2)) }
    local y = self.rule.y + self.rule.h + U(18)

    local all = entries()
    self.pages = math.max(1, math.ceil(#all / per_page))
    if self.page > self.pages then self.page = self.pages end
    if self.page < 1 then self.page = 1 end

    self.cells = {}
    self.empty = nil
    if #all == 0 then
        self.empty = keep(TextBoxWidget:new{
            text = _("No actions here yet. Choose them in Settings > Your actions > Action center."),
            face = KoboldWidgets.secondaryFace(15), width = W - 2 * inset, fgcolor = C_SECONDARY,
        })
        self.empty_pos = { x = inset, y = y }
        y = y + self.empty:getSize().h + U(8)
    else
        local first = (self.page - 1) * per_page + 1
        local last = math.min(#all, first + per_page - 1)
        local total_w = cols * tile + (cols - 1) * gap
        local x0 = math.floor((W - total_w) / 2)
        local label_w = tile + gap - U(2)
        -- room for a second line (On / Off) only when something on the page has it
        local any_state = false
        for i = first, last do if all[i].on ~= nil then any_state = true end end
        local label_h, state_h = 0, 0
        local n = 0
        for i = first, last do
            local e = all[i]
            local col, row = n % cols, math.floor(n / cols)
            local cell = { c = e.c, on = e.on }
            cell.label = keep(TextWidget:new{
                text = e.c.name, face = KoboldWidgets.face(13), max_width = label_w,
                truncate_with_ellipsis = true,
            })
            label_h = math.max(label_h, cell.label:getSize().h)
            if e.on ~= nil then
                cell.state = keep(TextWidget:new{
                    text = e.on and _("On") or _("Off"), face = KoboldWidgets.secondaryFace(12),
                    fgcolor = C_SECONDARY, max_width = label_w,
                })
                state_h = math.max(state_h, cell.state:getSize().h)
            end
            cell.icon = keep(ActionIcon.widget(e.c.icon, math.floor(tile * 0.5)))
            cell.col, cell.row = col, row
            self.cells[#self.cells + 1] = cell
            n = n + 1
        end
        local cell_h = tile + label_gap + label_h + (any_state and state_h or 0) + row_gap
        for _i, cell in ipairs(self.cells) do
            local cx = x0 + cell.col * (tile + gap)
            local cy = y + cell.row * cell_h
            cell.rect = { x = cx, y = cy, w = tile, h = tile }
            cell.label_x = cx + math.floor((tile - cell.label:getSize().w) / 2)
            cell.label_y = cy + tile + label_gap
            if cell.state then
                cell.state_x = cx + math.floor((tile - cell.state:getSize().w) / 2)
                cell.state_y = cell.label_y + label_h
            end
        end
        local used_rows = math.floor((#self.cells - 1) / cols) + 1
        y = y + used_rows * cell_h
    end

    -- page lines, when there are several pages: one horizontal line per page,
    -- the current one longer and black, centered above the handle
    self.dots = nil
    if self.pages > 1 then
        local thin, thick = math.max(2, U(3)), math.max(3, U(5))
        local short_w, long_w, dgap = U(12), U(32), U(7)
        local total = (self.pages - 1) * (short_w + dgap) + long_w
        local dx = math.floor((W - total) / 2)
        local dy = y + U(4)
        local rects = {}
        local cx = dx
        for i = 1, self.pages do
            local active = (i == self.page)
            local w = active and long_w or short_w
            local h = active and thick or thin
            rects[#rects + 1] = {
                x = cx, y = dy + math.floor((thick - h) / 2), w = w, h = h,
                cx = cx + math.floor(w / 2), active = active,
            }
            cx = cx + w + dgap
        end
        self.dots = { rects = rects, x = dx, y = dy, w = total, h = thick }
        y = dy + thick + U(10)
    end

    -- the handle at the bottom: a chevron pointing up (swipe up closes)
    self.chevron_size = U(26)
    self.chevron = keep(OptionSheet.iconWidget("chevron-up", self.chevron_size, BLACK))
    self.handle_y = y + U(2)
    self.border = U(2)
    self.height = self.handle_y + self.chevron_size + U(10) + self.border
end

-- A thin white line under the black one keeps the panel apart from the page.
local function sepHeight() return U(3) end

function Panel:region()
    return Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self.height + sepHeight() }
end

function Panel:paintTo(bb, x, y)
    local W, h, b = Screen:getWidth(), self.height, self.border
    bb:paintRect(x, y, W, h + sepHeight(), WHITE)
    bb:paintRect(x, y + h - b, W, b, BLACK)
    bb:paintRect(x + self.rule.x, y + self.rule.y, self.rule.w, self.rule.h, C_RULE)
    self.heading:paintTo(bb, x + self.heading_pos.x, y + self.heading_pos.y)
    if self.empty then
        self.empty:paintTo(bb, x + self.empty_pos.x, y + self.empty_pos.y)
    end
    for _i, cell in ipairs(self.cells) do
        local r = cell.rect
        local radius = math.floor(r.w * 0.22)
        local isz = cell.icon:getSize()
        local ix = x + r.x + math.floor((r.w - isz.w) / 2)
        local iy = y + r.y + math.floor((r.h - isz.h) / 2)
        if cell.on == true then
            -- on: black tile, white icon (the icon is drawn black on white, then inverted)
            bb:paintRoundedRect(x + r.x, y + r.y, r.w, r.h, BLACK, radius)
            bb:paintRect(ix, iy, isz.w, isz.h, WHITE)
            cell.icon:paintTo(bb, ix, iy)
            bb:invertRect(ix, iy, isz.w, isz.h)
        else
            bb:paintRoundedRect(x + r.x, y + r.y, r.w, r.h, C_TAG, radius)
            cell.icon:paintTo(bb, ix, iy)
        end
        cell.label:paintTo(bb, x + cell.label_x, y + cell.label_y)
        if cell.state then cell.state:paintTo(bb, x + cell.state_x, y + cell.state_y) end
    end
    if self.dots then
        for _i, r in ipairs(self.dots.rects) do
            bb:paintRoundedRect(x + r.x, y + r.y, r.w, r.h, r.active and BLACK or C_RULE, math.floor(r.h / 2))
        end
    end
    self.chevron:paintTo(bb, x + math.floor((W - self.chevron_size) / 2), y + self.handle_y)
end

function Panel:dismiss()
    UIManager:close(self)
    return true
end

-- Draws the panel again (the state of a tile changed, or the page did).
function Panel:redraw()
    if self.closed then return end
    self:build()
    UIManager:setDirty(self, "ui", self:region())
end

-- After a toggle the state changes a moment later (Wi-Fi takes seconds): the
-- panel looks again a few times and redraws only if something changed.
function Panel:followState(before)
    local function look()
        if self.closed then return end
        local now = self:stateSig()
        if now ~= before then
            before = now
            self:redraw()
        end
    end
    UIManager:scheduleIn(0.3, look)
    UIManager:scheduleIn(1.5, look)
    UIManager:scheduleIn(4, look)
end

function Panel:activate(cell)
    local c = cell.c
    if cell.on ~= nil then
        -- an on / off action: it changes, the panel stays open and shows the new state
        local before = self:stateSig()
        CustomActions.run(c.id, self.ui)
        self:followState(before)
    else
        self:dismiss()
        UIManager:nextTick(function() CustomActions.run(c.id, self.ui) end)
    end
end

function Panel:onTapCenter(_ev, ges)
    local pos = ges.pos
    -- on the page lines (with a generous touch area): go to the nearest page
    local d = self.dots
    if d and pos.y >= d.y - U(12) and pos.y < d.y + d.h + U(12)
        and pos.x >= d.x - U(16) and pos.x < d.x + d.w + U(16) then
        local best, best_dist = nil, nil
        for i, r in ipairs(d.rects) do
            local dist = math.abs(pos.x - r.cx)
            if not best_dist or dist < best_dist then best, best_dist = i, dist end
        end
        if best and best ~= self.page then
            self.page = best
            self:redraw()
        end
        return true
    end
    -- below the panel, or on its handle: close
    if pos.y >= self.height or pos.y >= self.handle_y then return self:dismiss() end
    for _i, cell in ipairs(self.cells or {}) do
        local r = cell.rect
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            self:activate(cell)
            break
        end
    end
    return true
end

function Panel:onSwipeCenter(_ev, ges)
    local d = ges.direction
    if d == "north" then return self:dismiss() end
    if d == "west" and self.page < self.pages then
        self.page = self.page + 1
        self:redraw()
    elseif d == "east" and self.page > 1 then
        self.page = self.page - 1
        self:redraw()
    end
    return true
end

function Panel:onAnyKeyPressed()
    return self:dismiss()
end

function Panel:onShow()
    UIManager:setDirty(self, "ui", self:region())
    Refresh.settle(self, function() return self:region() end)
    return true
end

function Panel:onCloseWidget()
    self.closed = true
    self:release()
    UIManager:setDirty(nil, "ui", self:region())
    if open_panel == self then open_panel = nil end
end

-- Opens the Action center. opts.ui: the reader, inside a book.
function ActionCenter.show(opts)
    if open_panel then return open_panel end
    opts = opts or {}
    local panel = Panel:new{ ui = opts.ui }
    open_panel = panel
    UIManager:show(panel, "ui", panel:region())
    return panel
end

return ActionCenter
