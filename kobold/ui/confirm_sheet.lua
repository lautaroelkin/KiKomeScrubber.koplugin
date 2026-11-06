-- kobold/ui/confirm_sheet.lua — Kobold
-- A small confirmation sheet, in the same style as the other sheets of the
-- plugin (option_sheet.lua): a white panel that rises from the bottom edge
-- with rounded top corners, a chevron, a bold title over a rule, a short
-- message and two pills: Cancel (grey) and the confirm action (black).
-- Meant to be reused wherever something must be confirmed.
--
--   local ConfirmSheet = require("kobold.ui.confirm_sheet")
--   ConfirmSheet.show{
--       title        = "Morning reads",          -- bold line on top (optional: with none,
--                                                -- the message alone is the question)
--       title_tail   = false,                    -- true: a long title (a path) is cut at
--                                                -- its start so its end stays visible
--       message      = "The books stay in your library.",
--       confirm_text = "Remove",                 -- default "Confirm"
--       cancel_text  = "Cancel",                 -- default "Cancel"
--       toggle       = {                         -- optional: a row to tick between the message
--           label  = "Keep a backup copy",       -- and the pills (square-dot ticked, square not)
--           detail = "Book.epub.kikome.bak",     -- optional smaller line under the label
--           value  = true,                       -- how it starts (default true)
--       },
--       on_confirm   = function(ticked) end,     -- `ticked`: the toggle's value (nil with no toggle)
--       on_cancel    = function() end,           -- optional (also runs on a tap outside)
--   }

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local _              = require("kobold.i18n")
local KoboldWidgets  = require("kobold.ui.widgets")
local OptionSheet    = require("kobold.ui.option_sheet")
local Refresh        = require("kobold.ui.refresh")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_RULE = Blitbuffer.Color8(0x99)  -- thin grey rule under the title
local C_IDLE = Blitbuffer.Color8(0xDD)  -- the Cancel pill
local C_TEXT = Blitbuffer.Color8(0x55)  -- the message

local function U(n) return Screen:scaleBySize(n) end

-- Text with its first characters cut (and "…" put first) until it fits.
local function tailText(text, face, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = face, bold = true }
        local w = t:getSize().w
        t:free()
        return w
    end
    if width(text) <= max_w then return text end
    local guard = 0
    while text ~= "" and width("…" .. text) > max_w and guard < 300 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return "…" .. text
end

local Sheet = InputContainer:extend{
    modal = true,
    name = "kobold_confirm_sheet",
    title = "",
    title_tail = false,
    message = nil,
    confirm_text = nil,
    cancel_text = nil,
    toggle = nil,
    on_confirm = nil,
    on_cancel = nil,
}

function Sheet:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.width, self.left, self.bottom = Screen:getWidth(), 0, Screen:getHeight()
    self.corner, self.border = U(14), U(2)
    self.ges_events = {
        TapSheet   = { GestureRange:new{ ges = "tap",   range = self.dimen } },
        SwipeSheet = { GestureRange:new{ ges = "swipe", range = self.dimen } },
    }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self:build()
end

function Sheet:release()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = nil
end

function Sheet:build()
    self:release()
    self.widgets = {}
    local function keep(w)
        self.widgets[#self.widgets + 1] = w
        return w
    end
    local w = self.width
    local inset = U(45)
    local inner = w - 2 * inset

    self.chevron_size = U(26)
    self.chevron = keep(OptionSheet.iconWidget("chevron-down", self.chevron_size, BLACK))

    -- Title over a rule (same measures as OptionSheet's heading); with no
    -- title the message below is the question and starts right under the handle.
    local has_title = self.title ~= nil and self.title ~= ""
    local y
    self.heading, self.rule = nil, nil
    if has_title then
        local face = KoboldWidgets.face(17)
        local title = self.title
        if self.title_tail then title = tailText(title, face, inner) end
        self.heading = keep(TextWidget:new{ text = title, face = face, bold = true, max_width = inner })
        local center = U(3) + U(61)
        self.heading_pos = { x = inset, y = center - math.floor(self.heading:getSize().h / 2) }
        self.rule = { x = U(17.5), y = center + U(24), w = w - 2 * U(17.5), h = math.max(1, U(2)) }
        y = self.rule.y + self.rule.h + U(16)
    else
        y = U(56)
    end

    -- The message, wrapped.
    self.msg = nil
    if self.message and self.message ~= "" then
        self.msg = keep(TextBoxWidget:new{
            text = self.message, face = KoboldWidgets.face(has_title and 15 or 17), width = inner,
            fgcolor = has_title and C_TEXT or BLACK, alignment = "left",
        })
        self.msg_pos = { x = inset, y = y }
        y = y + self.msg:getSize().h + U(20)
    end

    -- The row to tick: the box, the label and (smaller, under it) the detail.
    self.toggle_row = nil
    if self.toggle then
        local size = U(26)
        local text_x = U(38)
        local text_w = inner - text_x
        self.toggle_on = keep(OptionSheet.iconWidget("square-dot", size, BLACK))
        self.toggle_off = keep(OptionSheet.iconWidget("square", size, BLACK))
        self.toggle_size = size
        self.toggle_label = keep(TextWidget:new{
            text = self.toggle.label or "", face = KoboldWidgets.face(16), bold = true, max_width = text_w,
        })
        local label_h = self.toggle_label:getSize().h
        local row_h = math.max(size, label_h)
        self.toggle_detail = nil
        if self.toggle.detail and self.toggle.detail ~= "" then
            -- a long file name is cut at its start, so its ending stays in view
            local detail_face = KoboldWidgets.face(14)
            self.toggle_detail = keep(TextWidget:new{
                text = tailText(self.toggle.detail, detail_face, text_w), face = detail_face,
                fgcolor = C_TEXT, max_width = text_w,
            })
            row_h = math.max(size, label_h + U(2) + self.toggle_detail:getSize().h)
        end
        row_h = row_h + U(16)   -- room to tap
        self.toggle_row = { x = inset, y = y - U(8), w = inner, h = row_h }
        self.toggle_text_x = text_x
        self.toggle_label_h = label_h
        y = y - U(8) + row_h + U(14)
    end

    -- Two pills of the same width.
    local pill_h, gap = U(44), U(12)
    local pill_w = math.floor((inner - gap) / 2)
    self.cancel_pill = { x = inset, y = y, w = pill_w, h = pill_h }
    self.ok_pill = { x = inset + pill_w + gap, y = y, w = pill_w, h = pill_h }
    -- Each label knows the colour it sits on, so no white box shows around it.
    self.cancel_label = keep(TextWidget:new{
        text = self.cancel_text or _("Cancel"), face = KoboldWidgets.face(16),
        bgcolor = C_IDLE, max_width = pill_w - U(20),
    })
    self.ok_label = keep(TextWidget:new{
        text = self.confirm_text or _("Confirm"), face = KoboldWidgets.face(16), bold = true,
        fgcolor = WHITE, bgcolor = BLACK, max_width = pill_w - U(20),
    })
    self.height = y + pill_h + U(26)
    self.top = self.bottom - self.height
end

-- A rectangle with the top corners rounded (the bottom is off screen).
local function fillTop(bb, x, y, w, h, color, r)
    r = math.max(0, math.min(r, math.floor(math.min(w, h) / 2)))
    if h - r > 0 then bb:paintRect(x, y + r, w, h - r, color) end
    if r > 0 then bb:paintRoundedRect(x, y, w, 2 * r, color, r) end
end

function Sheet:region()
    return Geom:new{ x = self.left, y = self.top - U(3), w = self.width, h = self.height + U(3) }
end

function Sheet:paintTo(bb, x, y)
    local top = y + self.top
    local w, h, r, b = self.width, self.height, self.corner, self.border
    fillTop(bb, x, top - U(3), w, h + U(3), WHITE, r)          -- white line standing it off
    fillTop(bb, x, top, w, h, BLACK, r)                        -- outline
    fillTop(bb, x + b, top + b, w - 2 * b, h - b, WHITE, math.max(0, r - b))
    self.chevron:paintTo(bb, x + math.floor((w - self.chevron_size) / 2),
        top + U(21) - math.floor(self.chevron_size / 2))
    if self.rule then
        bb:paintRect(x + self.rule.x, top + self.rule.y, self.rule.w, self.rule.h, C_RULE)
    end
    if self.heading then self.heading:paintTo(bb, x + self.heading_pos.x, top + self.heading_pos.y) end
    if self.msg then self.msg:paintTo(bb, x + self.msg_pos.x, top + self.msg_pos.y) end
    if self.toggle_row then
        local r = self.toggle_row
        local icon = self.toggle.value and self.toggle_on or self.toggle_off
        local ty = top + r.y + U(8)
        icon:paintTo(bb, x + r.x, ty)
        self.toggle_label:paintTo(bb, x + r.x + self.toggle_text_x, ty)
        if self.toggle_detail then
            self.toggle_detail:paintTo(bb, x + r.x + self.toggle_text_x, ty + self.toggle_label_h + U(2))
        end
    end
    local function pill(p, color, label)
        bb:paintRoundedRect(x + p.x, top + p.y, p.w, p.h, color, math.floor(p.h / 2))
        local sz = label:getSize()
        label:paintTo(bb, x + p.x + math.floor((p.w - sz.w) / 2), top + p.y + math.floor((p.h - sz.h) / 2))
    end
    pill(self.cancel_pill, C_IDLE, self.cancel_label)
    pill(self.ok_pill, BLACK, self.ok_label)
end

local function hit(p, top, pos)
    return pos.x >= p.x and pos.x < p.x + p.w and pos.y >= top + p.y and pos.y < top + p.y + p.h
end

-- Closing without confirming (a tap outside, the handle, Back, Cancel).
function Sheet:cancel()
    UIManager:close(self)
    if self.on_cancel then self.on_cancel() end
    return true
end

function Sheet:onTapSheet(_ev, ges)
    local pos = ges.pos
    if pos.y < self.top + U(42) then return self:cancel() end
    if hit(self.ok_pill, self.top, pos) then
        UIManager:close(self)
        local fn = self.on_confirm
        -- the toggle's value as it is (false stays false); nil only with no toggle
        local ticked
        if self.toggle then ticked = self.toggle.value end
        if fn then UIManager:nextTick(function() fn(ticked) end) end
        return true
    end
    if self.toggle_row and hit(self.toggle_row, self.top, pos) then
        self.toggle.value = not self.toggle.value
        local r = self.toggle_row
        UIManager:setDirty(self, "ui", Geom:new{ x = r.x, y = self.top + r.y, w = r.w, h = r.h })
        return true
    end
    if hit(self.cancel_pill, self.top, pos) then return self:cancel() end
    return true
end

function Sheet:onSwipeSheet(_ev, ges)
    if ges.direction == "south" then return self:cancel() end
    return true
end

function Sheet:onClose()
    return self:cancel()
end

function Sheet:onShow()
    UIManager:setDirty(self, "ui", self:region())
    Refresh.settle(self, function() return self:region() end)
    return true
end

function Sheet:onCloseWidget()
    self:release()
    UIManager:setDirty(nil, "ui", self:region())
end

local ConfirmSheet = {}

function ConfirmSheet.show(opts)
    local sheet = Sheet:new{
        title = opts.title, title_tail = opts.title_tail, message = opts.message,
        confirm_text = opts.confirm_text, cancel_text = opts.cancel_text,
        toggle = opts.toggle and {
            label = opts.toggle.label, detail = opts.toggle.detail,
            value = opts.toggle.value ~= false,
        } or nil,
        on_confirm = opts.on_confirm, on_cancel = opts.on_cancel,
    }
    UIManager:show(sheet, "ui", sheet:region())
    return sheet
end

return ConfirmSheet
