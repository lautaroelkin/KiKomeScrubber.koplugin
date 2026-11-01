-- kobold/ui/rename_prompt.lua — Kobold
-- A small text prompt, not full screen: a white panel with rounded top
-- corners that sits on top of the plugin's own keyboard (keyboard.lua), the
-- screen underneath stays visible. Cancel on the left, the title in the
-- middle and a black Save pill on the right (the same header as the
-- collection editor), then the grey name pill. The hide key of the keyboard
-- lowers the panel to the bottom; tapping the pill brings the keyboard back.
--
--   require("kobold.ui.rename_prompt").show{
--       title       = "Rename collection",
--       text        = "Current name",            -- what the pill starts with
--       placeholder = "Collection name",         -- optional
--       save_text   = "Save",                    -- optional
--       validate    = function(name) return "message" or nil end,   -- optional
--       on_save     = function(name) end,        -- gets the trimmed name
--   }
-- Save stays grey while the name is empty, unchanged or refused by validate.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local Keyboard        = require("kobold.ui.keyboard")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD       = Blitbuffer.Color8(0xE8)  -- the name pill and the Save pill when off
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)

local function U(n) return Screen:scaleBySize(n) end

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

-- Text with its first characters cut until it fits `max_w`, so the end of
-- what is typed (where the caret is) always shows.
local function tail(text, face, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = face }
        local w = t:getSize().w
        t:free()
        return w
    end
    local guard = 0
    while text ~= "" and width(text) > max_w and guard < 200 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return text
end

-- A rounded pill of exactly h tall around a label. Returns it and its width.
local function pill(text, h, bg, fg, bold)
    local t = TextWidget:new{ text = text, face = KoboldWidgets.face(16), bold = bold, fgcolor = fg, bgcolor = bg }
    local th = t:getSize().h
    local top = math.floor((h - th) / 2)
    local frame = FrameContainer:new{
        bordersize = 0, radius = math.floor(h / 2), background = bg,
        padding = 0, padding_left = U(18), padding_right = U(18),
        padding_top = top, padding_bottom = h - th - top,
        t,
    }
    return frame, frame:getSize().w
end

local Prompt = InputContainer:extend{
    modal = true,
    name = "kobold_rename_prompt",
    title = "",
    text = "",
    placeholder = nil,
    save_text = nil,
    validate = nil,
    on_save = nil,
}

function Prompt:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.original = trim(self.text or "")
    self.value = self.text or ""
    self.kb_open = true
    self.kb = Keyboard.new{
        on_insert = function(c) self.value = self.value .. c end,
        on_delete = function()
            self.value = self.value:gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
        end,
        on_clear = function() self.value = "" end,
        on_hide = function() self:setKeyboard(false) end,
        is_empty = function() return self.value == "" end,
        -- a tapped key lets go: its darker look is drawn away, and only that
        -- key is refreshed on the panel
        on_redraw = function(rects)
            if not (self.kb_open and self.kb_y) then return end
            self:rebuild()
            self:refreshRects(rects)
        end,
    }
    self.kb:reset(self.value == "")
    self:validateName()
    self:rebuild()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPrompt = { GestureRange:new{ ges = "tap", range = self.dimen } },
            HoldPrompt = { GestureRange:new{ ges = "hold", range = self.dimen } },
        }
    end
end

function Prompt:validateName()
    self.error = nil
    local name = trim(self.value)
    if name ~= "" and name ~= self.original and self.validate then
        self.error = self.validate(name)
    end
end

function Prompt:canSave()
    local name = trim(self.value)
    return name ~= "" and name ~= self.original and not self.error
end

-- The grey name pill, with the caret while the keyboard is up.
function Prompt:field(w, h)
    local pad = U(18)
    local inner_w = w - 2 * pad
    local face = KoboldWidgets.face(18)
    local caret_w = self.kb_open and (U(2) + U(3)) or 0
    local avail = inner_w - caret_w - U(4)
    local function caret()
        local th = TextWidget:new{ text = "Ag", face = face }:getSize().h
        return HorizontalGroup:new{
            HorizontalSpan:new{ width = U(3) },
            LineWidget:new{ dimen = Geom:new{ w = U(2), h = th }, background = BLACK },
        }
    end
    local row = HorizontalGroup:new{ align = "center" }
    if self.value == "" then
        if self.kb_open then row[#row + 1] = caret() end
        row[#row + 1] = TextWidget:new{
            text = self.placeholder or _("Name"), face = face, fgcolor = C_PLACEHOLDER,
            bgcolor = C_FIELD, max_width = avail,
        }
    else
        row[#row + 1] = TextWidget:new{ text = tail(self.value, face, avail), face = face, bgcolor = C_FIELD }
        if self.kb_open then row[#row + 1] = caret() end
    end
    return FrameContainer:new{
        bordersize = 0, radius = math.floor(h / 2), background = C_FIELD,
        padding = 0, padding_left = pad, padding_right = pad,
        KoboldWidgets.fixed(inner_w, h, LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = h }, row,
        }),
    }
end

function Prompt:rebuild()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local border, radius = U(2), U(14)
    local gap = U(12)

    -- Header: Cancel, the title, the Save pill.
    local header_h = U(52)
    local can = self:canSave()
    -- what the header and the hint show now, to refresh them only when they change
    self.shown_can, self.shown_error = can, self.error
    local save, save_w = pill(self.save_text or _("Save"), U(40),
        can and BLACK or C_FIELD, can and WHITE or C_PLACEHOLDER, true)
    local cancel = TextWidget:new{ text = _("Cancel"), face = KoboldWidgets.face(17) }
    local side_w = math.max(save_w, cancel:getSize().w) + U(8)
    local title = TextWidget:new{
        text = self.title or "", face = KoboldWidgets.face(18), bold = true,
        max_width = math.max(U(60), content_w - 2 * side_w - gap),
    }
    local field_h = U(48)
    local hint_h = U(24)
    local content_h = U(12) + header_h + U(8) + field_h + hint_h
    local kb_h = self.kb_open and self.kb:height() or 0
    -- With the keyboard down the panel leaves some air under the pill.
    local bottom_air = self.kb_open and 0 or U(16)
    local panel_top = H - kb_h - bottom_air - content_h - border

    local hint = self.error and TextWidget:new{
        text = self.error, face = KoboldWidgets.face(13),
        fgcolor = KoboldWidgets.subtitleColor(), max_width = content_w - U(18),
    } or HorizontalSpan:new{ width = 0 }

    local body = VerticalGroup:new{ align = "left" }
    body[#body + 1] = VerticalSpan:new{ width = U(12) }
    body[#body + 1] = KoboldWidgets.fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = content_w - 2 * side_w, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, save },
    })
    body[#body + 1] = VerticalSpan:new{ width = U(8) }
    body[#body + 1] = self:field(content_w, field_h)
    body[#body + 1] = KoboldWidgets.fixed(content_w, hint_h, LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = hint_h },
        HorizontalGroup:new{ HorizontalSpan:new{ width = U(18) }, hint },
    })

    -- Tap zones, in screen coordinates.
    local y0 = panel_top + border + U(12)
    self.panel_top = panel_top
    self.cancel_rect = Geom:new{ x = margin, y = y0, w = side_w, h = header_h }
    self.save_rect = Geom:new{ x = margin + content_w - side_w, y = y0, w = side_w, h = header_h }
    self.field_rect = Geom:new{ x = margin, y = y0 + header_h + U(8), w = content_w, h = field_h }

    -- The panel reaches below the screen, so only its top corners show.
    local panel = FrameContainer:new{
        bordersize = border, radius = radius, background = WHITE,
        padding = 0, padding_left = margin - border,
        width = W, height = content_h + kb_h + bottom_air + radius * 3,
        body,
    }
    panel.overlap_offset = { 0, panel_top }
    local layers = OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = W, h = H },
        panel,
    }
    self.kb_y = nil
    if self.kb_open then
        self.kb_y = H - kb_h
        local kb = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = self.kb_y },
            self.kb:build(W),
        }
        layers[#layers + 1] = kb
    else
        self.kb:free()
    end
    self[1] = layers
end

-- The area the panel and the keyboard cover.
function Prompt:panelRegion()
    local H = Screen:getHeight()
    local top = math.max(0, (self.panel_top or 0) - U(4))
    return Geom:new{ x = 0, y = top, w = Screen:getWidth(), h = H - top }
end

-- Redraws the panel. `part` narrows it, which matters on e-ink: "top" is the
-- header and the name pill (what a typed letter changes), "keyboard" is only
-- the keys (a key lets go); nothing means the panel and the keyboard.
function Prompt:refreshPanel(part)
    local region = self:panelRegion()
    if part and self.kb_open and self.kb_y then
        if part == "top" then
            region = Geom:new{ x = 0, y = region.y, w = region.w, h = self.kb_y - region.y }
        elseif part == "keyboard" then
            region = Geom:new{ x = 0, y = self.kb_y, w = region.w, h = Screen:getHeight() - self.kb_y }
        end
    end
    UIManager:setDirty(self, function() return "ui", region end)
end

-- Refreshes just these areas (screen Geoms) of the prompt: the few keys whose
-- look changed. Without any, the whole keyboard.
function Prompt:refreshRects(rects)
    if not rects or #rects == 0 then
        self:refreshPanel("keyboard")
        return
    end
    for _i, r in ipairs(rects) do
        UIManager:setDirty(self, function() return "ui", r end)
    end
end

-- After typing: refreshes only what the keystroke changed, never the whole
-- panel. A letter changes the name pill (and the Save pill or the hint under it
-- only when they switch); a key changes only its own pad, unless the keys look
-- different (shift, 123, accent), when the keyboard is redrawn.
function Prompt:refreshTyping(text_changed, kb_changed, rects, prev_can, prev_error)
    if not (self.kb_open and self.kb_y) then
        self:refreshPanel()
        return
    end
    local function grow(r, n)
        return Geom:new{ x = r.x - n, y = r.y - n, w = r.w + 2 * n, h = r.h + 2 * n }
    end
    local n = U(2)
    local regions = {}
    if text_changed then
        regions[#regions + 1] = grow(self.field_rect, n)
        if self.shown_can ~= prev_can then
            regions[#regions + 1] = grow(self.save_rect, n)
        end
        if self.shown_error ~= prev_error then
            local f = self.field_rect
            regions[#regions + 1] = Geom:new{ x = f.x, y = f.y + f.h, w = f.w, h = U(24) }
        end
    end
    if kb_changed then
        regions[#regions + 1] = Geom:new{ x = 0, y = self.kb_y, w = Screen:getWidth(), h = Screen:getHeight() - self.kb_y }
    else
        for _i, r in ipairs(rects or {}) do regions[#regions + 1] = r end
    end
    for _i, r in ipairs(regions) do
        UIManager:setDirty(self, function() return "ui", r end)
    end
end

-- Keyboard up or down; the panel moves with it, so the old area is cleared too.
function Prompt:setKeyboard(open)
    if self.kb_open == open then return end
    local old = self:panelRegion()
    self.kb_open = open
    self.kb:reset(self.value == "")
    self:rebuild()
    local new = self:panelRegion()
    local top = math.min(old.y, new.y)
    local region = Geom:new{ x = 0, y = top, w = old.w, h = Screen:getHeight() - top }
    UIManager:setDirty(nil, function() return "ui", region end)
    UIManager:setDirty(self, function() return "ui", region end)
end

function Prompt:dismiss()
    UIManager:close(self)
    return true
end

function Prompt:save()
    if not self:canSave() then return end
    local name = trim(self.value)
    UIManager:close(self)
    if self.on_save then self.on_save(name) end
end

local function inside(r, pos)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Prompt:onTapPrompt(_ev, ges)
    local pos = ges.pos
    if pos.y < self.panel_top then return self:dismiss() end   -- a tap outside closes it
    if inside(self.cancel_rect, pos) then return self:dismiss() end
    if inside(self.save_rect, pos) then
        self:save()
        return true
    end
    if self.kb_open and self.kb_y and pos.y >= self.kb_y then
        local handled, text_changed, kb_changed, rects = self.kb:tap(pos, self.kb_y)
        if handled and self.kb_open and (text_changed or kb_changed) then
            local prev_can, prev_error = self.shown_can, self.shown_error
            if text_changed then self:validateName() end
            self:rebuild()
            -- only the name pill and the key that was tapped; a shift or a
            -- layout switch also changes the keys
            self:refreshTyping(text_changed, kb_changed, rects, prev_can, prev_error)
        end
        return true
    end
    if inside(self.field_rect, pos) and not self.kb_open then
        self:setKeyboard(true)
    end
    return true
end

-- Hold the keyboard's delete key: the whole name is cleared.
function Prompt:onHoldPrompt(_ev, ges)
    if self.kb_open and self.kb_y and ges.pos.y >= self.kb_y then
        local _handled, text_changed, kb_changed = self.kb:hold(ges.pos, self.kb_y)
        if self.kb_open and (text_changed or kb_changed) then
            local prev_can, prev_error = self.shown_can, self.shown_error
            if text_changed then self:validateName() end
            self:rebuild()
            self:refreshTyping(text_changed, kb_changed, nil, prev_can, prev_error)
        end
    end
    return true
end

function Prompt:onClose()
    return self:dismiss()
end

function Prompt:onShow()
    self:refreshPanel()
    return true
end

function Prompt:onCloseWidget()
    local region = self:panelRegion()
    self.kb:free()
    UIManager:setDirty(nil, function() return "ui", region end)
end

local RenamePrompt = {}

function RenamePrompt.show(opts)
    UIManager:show(Prompt:new{
        title = opts.title, text = opts.text, placeholder = opts.placeholder,
        save_text = opts.save_text, validate = opts.validate, on_save = opts.on_save,
    })
end

return RenamePrompt
