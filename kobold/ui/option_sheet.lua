-- kobold/ui/option_sheet.lua — KiKome
-- A reusable bottom sheet: a white panel that rises from the bottom edge with a
-- black top line and a chevron-down at the top, a bold heading over a rule,
-- then one or more rows of pill options. Each row can have a small label
-- above it. The chosen option of a row is filled black with an inverted icon;
-- the others are filled grey with a black icon.
--
-- A row can be an action instead of a choice: set close = true and the sheet
-- closes after the tap (use it to jump somewhere, e.g. open the Recent tab).
--
-- Usage from anywhere in the plugin:
--
--   local OptionSheet = require("kobold.ui.option_sheet")
--   OptionSheet.show{
--       title = "View options",
--       rows  = {
--           { label = "Layout",
--             options  = { { id = "grid", label = "Grid", icon = "grid" },
--                          { id = "list", label = "List", icon = "list" } },
--             selected = "grid",
--             on_pick  = function(id) ... end },
--           { label = "Order", options = { ... }, selected = "desc", on_pick = ... },
--           { options = { { id = "recent", label = "Recent", icon = "sparkles" } },
--             close = true, on_pick = function(id) ... end },
--       },
--   }
--
-- By default the sheet rises from the bottom of the screen, full width, with
-- its top corners rounded. Pass anchor (a Geom: the rectangle of a window) to
-- sit it at the bottom of that window instead, as wide as the window, with all
-- the bottom corners following the window's own. radius sets the radius of the
-- top corners (default: the same as the book menu, 14); bottom_radius, the
-- radius of the window's corners (default: radius).
--
--   OptionSheet.show{ title = "Filter", anchor = popup_dimen,
--                     bottom_radius = popup_radius, rows = { ... } }
--
-- Icons are svg files in the plugin's icons folder (grid.svg, list.svg, ...).
-- "grid", "list" and "adjust" also have drawn fallbacks if the file is missing.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local ImageWidget    = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")
local lfs            = require("libs/libkoreader-lfs")
local KoboldWidgets  = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_RULE      = Blitbuffer.Color8(0x99)  -- thin grey rule under the heading
local C_IDLE      = Blitbuffer.Color8(0xDD)  -- fill of an option that is not chosen
local C_SECONDARY = Blitbuffer.Color8(0x55)  -- row labels

local function U(n) return Screen:scaleBySize(n) end

local OptionSheet = {}

-- ── Icons ──────────────────────────────────────────────────────────────────
local function iconPath(name)
    local ok, meta = pcall(require, "kobold.meta")
    local dir = ok and meta and meta.DIR
    if not dir then return nil, {} end
    local tried = {}
    for _i, sub in ipairs({ "/icons/", "/kobold/icons/", "/icons/toolbar/" }) do
        local path = dir .. sub .. name .. ".svg"
        tried[#tried + 1] = path
        if lfs.attributes(path, "mode") == "file" then return path, tried end
    end
    return nil, tried
end

local Glyph = Widget:extend{ kind = "adjust", size = 24, color = nil }

function Glyph:getSize() return Geom:new{ w = self.size, h = self.size } end
function Glyph:free() end

function Glyph:paintTo(bb, x, y)
    local s, t = self.size, math.max(2, math.floor(self.size / 12))
    local ink = self.color or BLACK
    if self.kind == "grid" then
        local c = math.floor((s - 2 * t) / 2)
        for i = 0, 1 do for j = 0, 1 do
            bb:paintBorder(x + i * (c + 2 * t), y + j * (c + 2 * t), c, c, t, ink, math.floor(c / 5))
        end end
    elseif self.kind == "list" then
        for i = 0, 2 do
            local ly = y + math.floor(s * (0.2 + 0.3 * i)) - math.floor(t / 2)
            bb:paintRect(x, ly, t * 2, t * 2, ink)
            bb:paintRect(x + t * 3, ly + math.floor(t / 2), s - t * 3, t, ink)
        end
    else -- adjust: two sliders
        for i = 0, 1 do
            local ly = y + math.floor(s * (0.3 + 0.4 * i))
            bb:paintRect(x, ly, s, t, ink)
            local kx = x + math.floor(s * (i == 0 and 0.65 or 0.3)) - t * 2
            bb:paintRoundedRect(kx, ly - t * 2, t * 4 + 2, t * 4 + 2, ink, t * 2 + 1)
        end
    end
end

-- An icon widget by name, tinted with fg (default black). The tint goes
-- through fgcolor with alpha = true, which keeps the svg background
-- transparent on a grey fill instead of painting it white.
local function iconWidget(name, size, fg)
    fg = fg or BLACK
    local path, tried = iconPath(name)
    if path then
        local ok, w = pcall(function()
            return ImageWidget:new{
                file = path, width = size, height = size,
                alpha = true, fgcolor = fg,
                original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and w then return w end
    end
    local okl, logger = pcall(require, "logger")
    if okl and logger then
        logger.warn("KiKome: icon '" .. name .. ".svg' not found, tried: " .. table.concat(tried, ", "))
    end
    return Glyph:new{ kind = name, size = size, color = fg }
end

OptionSheet.iconWidget = iconWidget

-- ── The sheet ──────────────────────────────────────────────────────────────
local Sheet = InputContainer:extend{
    title = "Options", rows = {},
    anchor = nil,   -- Geom of the window it sits at the bottom of (nil: the screen)
    corner = nil,   -- radius of the top corners
    bottom_corner = nil,  -- radius of the bottom corners when anchored to a window
}

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    -- Where the sheet stands: the whole screen's width, or one window's.
    local a = self.anchor
    self.left   = a and a.x or 0
    self.width  = a and a.w or Screen:getWidth()
    self.bottom = a and (a.y + a.h) or Screen:getHeight()
    self.corner = self.corner or U(14)
    -- On the screen the bottom edge is square (off-screen); in a window it
    -- takes the window's own radius, so only the window's corner shows there.
    self.anchored = (a ~= nil)
    self.bottom_corner = a and (self.bottom_corner or self.corner) or 0
    self.border = U(2)
    self.ges_events = {
        TapSheet   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    self.key_events = self.key_events or {}
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self.chevron_size = U(26)
    self:build()
end

function Sheet:release()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
end

function Sheet:build()
    self:release()
    self.widgets, self.chips = {}, {}
    local function keep(w)
        self.widgets[#self.widgets + 1] = w
        return w
    end
    local w = self.width
    local inset = U(45)
    local chip_h, chip_gap, chip_pad = U(41), U(8), U(17)
    local icon_size, icon_gap = U(20), U(15)
    local label_h, row_gap = U(24), U(14)

    local y = U(3)
    self.chevron = keep(iconWidget("chevron-down", self.chevron_size, BLACK))
    self.heading = keep(TextWidget:new{ text = self.title, face = KoboldWidgets.face(17), bold = true })
    local center = y + U(61)
    self.heading_pos = { x = inset, y = center - math.floor(self.heading:getSize().h / 2) }
    local rule_y = center + U(24)
    self.rule = { x = U(17.5), y = rule_y, w = w - 2 * U(17.5), h = math.max(1, U(2)) }
    y = rule_y + self.rule.h + U(13)

    for ri, row in ipairs(self.rows) do
        if row.label then
            local lbl = keep(TextWidget:new{
                text = row.label, face = KoboldWidgets.face(14), fgcolor = C_SECONDARY,
            })
            self.labels = self.labels or {}
            self.labels[#self.labels + 1] = { w = lbl, x = inset, y = y, h = label_h }
            y = y + label_h
        end
        local x = inset
        for _i, opt in ipairs(row.options or {}) do
            local selected = (opt.id == row.selected)
            local chip = { id = opt.id, row = ri, selected = selected }
            chip.label = keep(TextWidget:new{
                text = opt.label, face = KoboldWidgets.face(15),
                fgcolor = selected and WHITE or BLACK,
            })
            if opt.icon then
                chip.image = keep(iconWidget(opt.icon, icon_size, BLACK))
            end
            local icon_space = chip.image and (icon_size + icon_gap) or 0
            local chip_w = chip.label:getSize().w + icon_space + 2 * chip_pad
            if x > inset and x + chip_w > w - inset then
                -- no room left on this line: continue on the next one
                x = inset
                y = y + chip_h + chip_gap
            end
            chip.rect = Geom:new{ x = x, y = y, w = chip_w, h = chip_h }
            chip.label_x = x + chip_w - chip_pad - chip.label:getSize().w
            self.chips[#self.chips + 1] = chip
            x = x + chip_w + chip_gap
        end
        y = y + chip_h + row_gap
    end
    self.height = y + U(5)
    self.top = self.bottom - self.height
end

-- A thin white line sits just above the black one, so the sheet stands off
-- from whatever is behind it. The region covers it, so it is drawn and cleared.
local function sepHeight() return U(3) end

-- Inside a window the sheet needs no such line: the window is already white.
function Sheet:sep()
    return self.anchored and 0 or sepHeight()
end

-- Fills a rectangle with its top corners of radius rt and its bottom corners
-- of radius rb (0: square).
local function fillRounded(bb, x, y, w, h, color, rt, rb)
    local limit = math.floor(math.min(w, h) / 2)
    rt = math.max(0, math.min(rt, limit))
    rb = math.max(0, math.min(rb, limit))
    -- the body between the corner bands; a pill two radii tall gives each pair of corners
    if h - rt - rb > 0 then bb:paintRect(x, y + rt, w, h - rt - rb, color) end
    if rt > 0 then
        bb:paintRoundedRect(x, y, w, 2 * rt, color, rt)
    end
    if rb > 0 then
        bb:paintRoundedRect(x, y + h - 2 * rb, w, 2 * rb, color, rb)
    end
end

function Sheet:region()
    local sep = self:sep()
    return Geom:new{ x = self.left, y = self.top - sep, w = self.width, h = self.height + sep }
end

function Sheet:paintTo(bb, x, y)
    x = x + self.left
    local top = y + self.top
    local w, h, r, b = self.width, self.height, self.corner, self.border
    local rb = self.bottom_corner
    local sep = self:sep()
    if sep > 0 then fillRounded(bb, x, top - sep, w, h + sep, WHITE, r, rb) end
    -- black outline, then the white panel inside it (no bottom outline on the
    -- screen, where the bottom edge is off-screen; in a window it closes the
    -- window's own bottom edge, square or rounded like the window)
    fillRounded(bb, x, top, w, h, BLACK, r, rb)
    fillRounded(bb, x + b, top + b, w - 2 * b, h - b - (self.anchored and b or 0), WHITE,
        math.max(0, r - b), math.max(0, rb - b))
    self.chevron:paintTo(bb, x + math.floor((w - self.chevron_size) / 2),
        top + U(21) - math.floor(self.chevron_size / 2))
    bb:paintRect(x + self.rule.x, top + self.rule.y, self.rule.w, self.rule.h, C_RULE)
    self.heading:paintTo(bb, x + self.heading_pos.x, top + self.heading_pos.y)
    for _i, l in ipairs(self.labels or {}) do
        l.w:paintTo(bb, x + l.x, top + l.y + math.floor((l.h - l.w:getSize().h) / 2))
    end
    for _i, chip in ipairs(self.chips) do
        local r = chip.rect
        local radius = math.floor(r.h / 2)
        if chip.selected then
            bb:paintRoundedRect(x + r.x, top + r.y, r.w, r.h, BLACK, radius)
        else
            bb:paintRoundedRect(x + r.x, top + r.y, r.w, r.h, C_IDLE, radius)
        end
        if chip.image then
            local isz = chip.image:getSize()
            local ix, iy = x + r.x + U(17), top + r.y + math.floor((r.h - isz.h) / 2)
            if chip.selected then
                -- black icon on white, then invert the area: white icon on the black chip
                bb:paintRect(ix, iy, isz.w, isz.h, WHITE)
                chip.image:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, isz.w, isz.h)
            else
                chip.image:paintTo(bb, ix, iy)
            end
        end
        chip.label:paintTo(bb, x + chip.label_x, top + r.y + math.floor((r.h - chip.label:getSize().h) / 2))
    end
end

function Sheet:dismiss()
    UIManager:close(self)
    return true
end

function Sheet:onTapSheet(_ev, ges)
    local pos = ges.pos
    -- a tap outside the sheet, or on its handle, closes it
    if pos.y < self.top + U(42) or pos.x < self.left or pos.x >= self.left + self.width then
        return self:dismiss()
    end
    for _i, chip in ipairs(self.chips) do
        local r = chip.rect
        if pos.x >= self.left + r.x and pos.x < self.left + r.x + r.w
            and pos.y >= self.top + r.y and pos.y < self.top + r.y + r.h then
            local row = self.rows[chip.row]
            if chip.selected and not row.toggle then break end
            -- a toggle row clears its choice when the chosen chip is tapped again
            local value = (not chip.selected) and chip.id or nil
            row.selected = value
            if row.on_pick then row.on_pick(value) end
            if row.close then return self:dismiss() end
            self:build()
            UIManager:setDirty(self, "ui", self:region())
            break
        end
    end
    return true
end

function Sheet:onSwipeSheet(_ev, ges)
    if ges.direction == "south" then return self:dismiss() end
    return true
end

function Sheet:onAnyKeyPressed()
    return self:dismiss()
end

function Sheet:onShow()
    UIManager:setDirty(self, "ui", self:region())
    return true
end

function Sheet:onCloseWidget()
    self:release()
    UIManager:setDirty(nil, "ui", self:region())
end

-- Open the sheet. opts.title, opts.anchor and opts.radius (both optional, see
-- the top of this file), and opts.rows: a list of
--   { label?, options = { {id, label, icon?}, ... }, selected = id,
--     on_pick = function(id) end, close? = true, toggle? = true }
-- toggle: tapping the chosen option again clears it; on_pick receives nil.
-- Without rows, a single row can be given as opts.options / opts.selected / opts.on_pick.
function OptionSheet.show(opts)
    local rows = opts.rows or {
        { options = opts.options or {}, selected = opts.selected, on_pick = opts.on_pick },
    }
    local sheet = Sheet:new{
        title = opts.title or "Options", rows = rows,
        anchor = opts.anchor, corner = opts.radius, bottom_corner = opts.bottom_radius,
    }
    UIManager:show(sheet)
    return sheet
end

return OptionSheet
