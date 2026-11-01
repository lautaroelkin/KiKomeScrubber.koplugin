-- kobold/ui/keyboard.lua — KiKome
-- A small on-screen keyboard drawn by the plugin, to type text inside any
-- KiKome screen without KOReader's own dialogs. Letters (with ñ and an accent
-- key: tap ´ and then a vowel), numbers and punctuation, shift, a delete key
-- (hold it to clear everything) and a key that hides the keyboard.
--
-- The screen that owns it only places it and passes it the taps:
--
--   local Keyboard = require("kobold.ui.keyboard")
--   local kb = Keyboard.new{
--       on_insert = function(text) end,   -- a character was typed
--       on_delete = function() end,       -- delete: the last character
--       on_clear  = function() end,       -- delete held down: everything
--       on_hide   = function() end,       -- the hide key
--       is_empty  = function() return true end,  -- optional: the field is empty
--       on_redraw = function(rects) end,  -- the keys must be drawn again (a pressed
--                                         -- key lets go): rebuild, then refresh
--                                         -- only `rects` (screen Geoms: the keys
--                                         -- that changed), never the whole keyboard
--   }
--   kb:reset(true)            -- a field got the keyboard (true: start with a capital)
--   local widget = kb:build(Screen:getWidth())   -- put it at the bottom: kb:height() tall
--   -- on a tap / hold at `pos`, with `y0` the screen y of the keyboard's top:
--   local handled, text_changed, kb_changed, rects = kb:tap(pos, y0)
--   local handled, text_changed, kb_changed = kb:hold(pos, y0)
--   -- redraw what changed, and only that, so the e-ink panel does not flash:
--   --   text_changed  the typed text (refresh just the field)
--   --   kb_changed    the look of the keys changed (shift, 123, accent): refresh
--   --                 the whole keyboard
--   --   rects         (tap only) when kb_changed is false, the few keys that
--   --                 changed their pressed look: refresh only those
--   kb:free()                 -- when the screen closes

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Geom       = require("ui/geometry")
local TextWidget = require("ui/widget/textwidget")
local UIManager  = require("ui/uimanager")
local Widget     = require("ui/widget/widget")
local _          = require("gettext")
local OptionSheet   = require("kobold.ui.option_sheet")
local KoboldWidgets = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_KEY         = Blitbuffer.Color8(0xE8)  -- letter keys
local C_SPECIAL     = Blitbuffer.Color8(0xD0)  -- shift, delete, 123, hide
local C_ACTIVE      = Blitbuffer.Color8(0x99)  -- shift / accent switched on
local C_PRESSED     = Blitbuffer.Color8(0xC0)  -- a key for the moment after it is tapped
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)
local C_RULE        = Blitbuffer.Color8(0xBB)

local function U(n) return Screen:scaleBySize(n) end

local KEY_H, KEY_GAP_X, KEY_GAP_Y, KEY_SIDE, KEY_TOP, KEY_BOTTOM = 48, 6, 8, 6, 10, 10

local UPPER = { ["ñ"] = "Ñ" }
local ACCENT = { a = "á", e = "é", i = "í", o = "ó", u = "ú" }
local ACCENT_UPPER = { a = "Á", e = "É", i = "Í", o = "Ó", u = "Ú" }

local function ch(c, w) return { kind = "char", ch = c, w = w } end

local function letters(s)
    local row = {}
    for c in s:gmatch("%S+") do row[#row + 1] = ch(c) end
    return row
end

-- A row from keys and lists of keys.
local function withKeys(...)
    local row = {}
    for _i, part in ipairs({ ... }) do
        if part.kind then row[#row + 1] = part else for _j, k in ipairs(part) do row[#row + 1] = k end end
    end
    return row
end

local ROWS_ABC = {
    letters("q w e r t y u i o p"),
    letters("a s d f g h j k l ñ"),
    withKeys({ kind = "shift", w = 1.5 }, letters("z x c v b n m"), { kind = "back", w = 1.5 }),
    withKeys({ kind = "layer", w = 1.5 }, { kind = "accent" }, { kind = "space", w = 4.5 },
        ch("."), { kind = "hide", w = 2 }),
}

local ROWS_NUM = {
    letters("1 2 3 4 5 6 7 8 9 0"),
    letters("- / : ; ( ) $ & @ \""),
    withKeys(letters(". , ? ! ' ¿ ¡"), { kind = "back", w = 2 }),
    withKeys({ kind = "layer", w = 2 }, { kind = "space", w = 6 }, { kind = "hide", w = 2 }),
}

-- Where each key goes, in the keyboard's own coordinates.
local function layoutKeys(rows, width, key_h, gap_x, gap_y, side, top)
    local out = {}
    for ri, row in ipairs(rows) do
        local total = 0
        for _i, k in ipairs(row) do total = total + (k.w or 1) end
        local unit = (width - 2 * side - (#row - 1) * gap_x) / total
        local x = side
        local y = top + (ri - 1) * (key_h + gap_y)
        for _i, k in ipairs(row) do
            local kw = unit * (k.w or 1)
            out[#out + 1] = {
                kind = k.kind, ch = k.ch,
                rect = { x = math.floor(x), y = y, w = math.floor(kw), h = key_h },
            }
            x = x + kw + gap_x
        end
    end
    return out
end

-- The keys, painted: rounded grey pads with a centred label or icon.
local Pad = Widget:extend{ w = 0, h = 0, keys = nil }

function Pad:getSize() return Geom:new{ w = self.w, h = self.h } end
function Pad:free() end

function Pad:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    bb:paintRect(x, y, self.w, self.h, WHITE)
    bb:paintRect(x, y, self.w, math.max(1, U(1)), C_RULE)
    local radius = U(8)
    for _i, k in ipairs(self.keys or {}) do
        local r = k.rect
        bb:paintRoundedRect(x + r.x, y + r.y, r.w, r.h, k.bg, radius)
        if k.widget then
            local sz = k.widget:getSize()
            k.widget:paintTo(bb, x + r.x + math.floor((r.w - sz.w) / 2),
                y + r.y + math.floor((r.h - sz.h) / 2))
        end
    end
end

local Keyboard = {}
Keyboard.__index = Keyboard

function Keyboard.new(opts)
    local self = setmetatable({}, Keyboard)
    self.on_insert = opts.on_insert
    self.on_delete = opts.on_delete
    self.on_clear = opts.on_clear
    self.on_hide = opts.on_hide
    self.is_empty = opts.is_empty
    self.on_redraw = opts.on_redraw
    self.pressed = nil  -- index of the key that was just tapped
    self.pressed_rects = {}  -- screen areas of keys whose pressed look is on screen
    self:reset(false)
    return self
end

-- Total height of the keyboard.
function Keyboard:height()
    return U(KEY_TOP) + 4 * U(KEY_H) + 3 * U(KEY_GAP_Y) + U(KEY_BOTTOM)
end

-- Back to letters, no accent; capital = start the next word with a capital.
function Keyboard:reset(capital)
    self.layer, self.accent = "abc", false
    self.shift = capital and "once" or "off"
    self.pressed = nil
    self.pressed_rects = {}
end

-- The character a letter key types or shows now: accented while the accent
-- key is on, in capitals while shift is.
function Keyboard:display(c)
    if self.layer ~= "abc" then return c end
    local upper = self.shift ~= "off"
    if self.accent and ACCENT[c] then
        return upper and ACCENT_UPPER[c] or ACCENT[c]
    end
    if upper then return UPPER[c] or c:upper() end
    return c
end

function Keyboard:freeWidgets()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = nil
end

-- Lets go of everything: the widgets and a pending key release.
function Keyboard:free()
    if self.release then
        UIManager:unschedule(self.release)
        self.release = nil
    end
    self.pressed = nil
    self.pressed_rects = {}
    self:freeWidgets()
end

-- Makes the keyboard's widget for the current state, `width` wide. Call it
-- again after a tap that changed the keys (shift, 123, accent).
function Keyboard:build(width)
    self:freeWidgets()
    local rows = (self.layer == "num") and ROWS_NUM or ROWS_ABC
    local keys = layoutKeys(rows, width, U(KEY_H), U(KEY_GAP_X), U(KEY_GAP_Y), U(KEY_SIDE), U(KEY_TOP))
    local widgets = {}
    for i, key in ipairs(keys) do
        local k = key.kind
        local bg, w = C_KEY, nil
        key.idx = i
        -- A key that was just tapped shows a little darker for a moment
        -- (see tap).
        local pressed = (self.pressed == i)
        if k == "char" then
            w = TextWidget:new{ text = self:display(key.ch), face = KoboldWidgets.face(22) }
            if pressed then bg = C_PRESSED end
        elseif k == "shift" then
            bg = (self.shift ~= "off") and C_ACTIVE or C_SPECIAL
            w = OptionSheet.iconWidget("chevron-up", U(26), BLACK)
        elseif k == "back" then
            bg = pressed and C_PRESSED or C_SPECIAL
            w = OptionSheet.iconWidget("arrow-left", U(26), BLACK)
        elseif k == "layer" then
            bg = C_SPECIAL
            w = TextWidget:new{ text = (self.layer == "num") and "ABC" or "123", face = KoboldWidgets.face(17) }
        elseif k == "accent" then
            bg = self.accent and C_ACTIVE or C_SPECIAL
            w = TextWidget:new{ text = "´", face = KoboldWidgets.face(24) }
        elseif k == "space" then
            bg = pressed and C_PRESSED or C_KEY
            w = TextWidget:new{ text = _("space"), face = KoboldWidgets.face(15), fgcolor = C_PLACEHOLDER }
        elseif k == "hide" then
            bg = C_SPECIAL
            w = OptionSheet.iconWidget("chevron-down", U(26), BLACK)
        end
        key.bg, key.widget = bg, w
        widgets[#widgets + 1] = w
    end
    self.keys = keys
    self.widgets = widgets
    return Pad:new{ w = width, h = self:height(), keys = keys }
end

-- The key under screen point `pos`, `y0` being the screen y of the top.
function Keyboard:keyAt(pos, y0)
    local ky = pos.y - y0
    for _i, key in ipairs(self.keys or {}) do
        local r = key.rect
        if pos.x >= r.x and pos.x < r.x + r.w and ky >= r.y and ky < r.y + r.h then
            return key
        end
    end
    return nil
end

local function call(fn, ...) if fn then fn(...) end end

-- The screen area of a key (a hair larger, for its rounded corners), `y0`
-- being the screen y of the keyboard's top.
function Keyboard:keyRegion(key, y0)
    local r = key.rect
    return Geom:new{ x = r.x - 1, y = y0 + r.y - 1, w = r.w + 2, h = r.h + 2 }
end

-- The tapped key lets go a moment later and only that key is drawn again.
function Keyboard:pressKeyDown(key, y0)
    self.pressed = key.idx
    local rect = self:keyRegion(key, y0)
    self.pressed_rects[#self.pressed_rects + 1] = rect
    if self.release then UIManager:unschedule(self.release) end
    self.release = function()
        self.release = nil
        if self.pressed then
            self.pressed = nil
            self.pressed_rects = {}
            call(self.on_redraw, { rect })
        end
    end
    UIManager:scheduleIn(0.15, self.release)
end

-- After a delete: an emptied field starts with a capital again.
function Keyboard:capitalAgain()
    if self.is_empty and self.is_empty() and self.layer == "abc" and self.shift == "off" then
        self.shift = "once"
        return true
    end
    return false
end

-- A tap. Returns handled (it was on the keyboard), text_changed (the typed
-- text changed), kb_changed (the keys look different now: shift, 123, accent,
-- capitals) and rects: the screen areas of the keys whose pressed look changed,
-- the one just tapped and the one that was still showing it. When kb_changed is
-- true the whole keyboard is redrawn anyway; when it is false only `rects` need
-- a refresh (a plain letter changes nothing else on the keyboard).
function Keyboard:tap(pos, y0)
    if pos.y < y0 then return false, false, false end
    local key = self:keyAt(pos, y0)
    if not key then return true, false, false end
    local k = key.kind
    local text_changed, kb_changed = false, false
    -- The key that was still dark (tapped a moment ago) has to be drawn
    -- normally again: its area goes into the refresh too.
    local rects = self.pressed_rects or {}
    self.pressed_rects = {}
    self.pressed = nil
    if k == "char" then
        call(self.on_insert, self:display(key.ch))
        text_changed = true
        self:pressKeyDown(key, y0)
        if self.accent then self.accent, kb_changed = false, true end
        if self.layer == "abc" and self.shift == "once" then self.shift, kb_changed = "off", true end
    elseif k == "space" then
        call(self.on_insert, " ")
        text_changed = true
        self:pressKeyDown(key, y0)
        if self.accent then self.accent, kb_changed = false, true end
    elseif k == "back" then
        call(self.on_delete)
        text_changed = true
        self:pressKeyDown(key, y0)
        if self:capitalAgain() then kb_changed = true end
    elseif k == "shift" then
        self.shift = (self.shift == "off") and "once" or "off"
        kb_changed = true
    elseif k == "layer" then
        self.layer = (self.layer == "abc") and "num" or "abc"
        self.accent = false
        kb_changed = true
    elseif k == "accent" then
        self.accent = not self.accent
        kb_changed = true
    elseif k == "hide" then
        call(self.on_hide)
    end
    for _i, r in ipairs(self.pressed_rects) do rects[#rects + 1] = r end
    return true, text_changed, kb_changed, rects
end

-- A long press: on the delete key it clears everything.
function Keyboard:hold(pos, y0)
    if pos.y < y0 then return false, false, false end
    local key = self:keyAt(pos, y0)
    if key and key.kind == "back" then
        call(self.on_clear)
        return true, true, self:capitalAgain()
    end
    return true, false, false
end

return Keyboard
