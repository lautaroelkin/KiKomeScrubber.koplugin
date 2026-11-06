-- kobold/ui/toast.lua — Kobold
-- Short messages that appear by themselves and go away by themselves, in the
-- plugin's own look instead of KOReader's InfoMessage: a rounded pill with a
-- thin black outline (white inside; an error is black with white text),
-- centred near the bottom, just above the navigation bar. Taps go straight
-- through to the screen underneath.
--
-- Several messages at once stack neatly: the newest sits lowest, the older
-- ones above it with a small gap, and when one goes the rest settle down. The
-- same text shown again while it is still up only renews its time instead of
-- piling up.
--
--   local Toast = require("kobold.ui.toast")
--   Toast.show("1 book ready to copy.")
--   Toast.show("Left out: 2 already there", { timeout = 4 })
--   Toast.error("The folder could not be renamed.")
--   Toast.clear()
--
-- For something that blocks while it runs (copying, deleting) the message
-- stays until it is dismissed, and is painted before the work starts:
--
--   local working = Toast.working()          -- "Working…", or your own text
--   doTheHeavyThing()
--   Toast.dismiss(working)
--   (Toast.working(text, { timeout = 15 }) also goes by itself after 15 s, in case
--   the work never gets to dismiss it.)
--
-- Options of show / error: timeout (seconds; default 3, errors 4),
-- persistent (true: no timeout, stays until Toast.dismiss),
-- kind ("info" or "error"), bottom (pixels from the bottom edge of the screen
-- to the lowest message; default: over the nav bar and its mini cover).

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Geom           = require("ui/geometry")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local _              = require("kobold.i18n")
local Widget         = require("ui/widget/widget")
local KoboldNav      = require("kobold.ui.nav")
local KoboldWidgets  = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local function U(n) return Screen:scaleBySize(n) end

local MAX_VISIBLE = 4   -- more than this and the oldest goes at once

local entries = {}      -- oldest first: { text, kind, timeout, tb, w, h, expire }
local layer             -- the one widget that paints them all, while any is up

-- ── Measuring ──────────────────────────────────────────────────────────────
-- Makes the text widget of an entry and its size. The pill is as wide as its
-- longest line (up to most of the screen); longer lines wrap.
local function measure(entry)
    if entry.tb then return end
    local face = KoboldWidgets.face(15)
    local pad_x, pad_y = U(20), U(12)
    local max_text_w = math.floor(Screen:getWidth() * 0.86) - 2 * pad_x
    local natural = 0
    for line in (entry.text .. "\n"):gmatch("(.-)\n") do
        local t = TextWidget:new{ text = line, face = face }
        natural = math.max(natural, t:getSize().w)
        t:free()
    end
    local text_w = math.max(U(40), math.min(natural + U(2), max_text_w))
    -- A text box paints its own background (white by default), so on the black
    -- pill of an error it needs a black one, or it shows as a white block.
    local is_error = entry.kind == "error"
    entry.tb = TextBoxWidget:new{
        text = entry.text, face = face, width = text_w, alignment = "center",
        fgcolor = is_error and WHITE or BLACK,
        bgcolor = is_error and BLACK or WHITE,
    }
    local sz = entry.tb:getSize()
    entry.w, entry.h = sz.w + 2 * pad_x, sz.h + 2 * pad_y
    entry.pad_x, entry.pad_y = pad_x, pad_y
end

local function release(entry)
    if entry.tb then
        entry.tb:free()
        entry.tb = nil
    end
end

-- Where the stack's bottom edge is: the lowest message ends here.
local function bottomEdge(opts_bottom)
    local inset = opts_bottom or (KoboldNav.height() + U(44))
    return Screen:getHeight() - inset
end

-- The rectangle each entry occupies, newest at the bottom. Returns the list
-- (same order as `entries`) and the rectangle that holds them all.
local function layout()
    local W = Screen:getWidth()
    local gap = U(8)
    local last = entries[#entries]
    local y = bottomEdge(last and last.bottom)
    local rects = {}
    local top, bottom = nil, nil
    for i = #entries, 1, -1 do
        local e = entries[i]
        measure(e)
        y = y - e.h
        rects[i] = Geom:new{ x = math.floor((W - e.w) / 2), y = y, w = e.w, h = e.h }
        top = y
        bottom = bottom or (y + e.h)
        y = y - gap
    end
    local all
    if top then
        -- a little around it, so the outline is cleared when it goes
        all = Geom:new{ x = 0, y = top - U(4), w = W, h = bottom - top + U(8) }
    end
    return rects, all
end

-- ── The widget that paints the stack ───────────────────────────────────────
local Layer = Widget:extend{
    name = "kobold_toast",
    -- KOReader passes events on to the widget below a `toast`: taps, swipes
    -- and keys reach the screen as if nothing was drawn over it.
    toast = true,
}

function Layer:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    self.rects, self.area = layout()
end

function Layer:getSize() return self.dimen end
function Layer:free() end

-- Lays the stack out again; returns the area that has to be redrawn (the old
-- stack and the new one).
function Layer:relayout()
    local old = self.area
    self.rects, self.area = layout()
    if old and self.area then return old:combine(self.area) end
    return old or self.area
end

function Layer:paintTo(bb, x, y)
    for i, e in ipairs(entries) do
        local r = self.rects and self.rects[i]
        if r and e.tb then
            local rx, ry = x + r.x, y + r.y
            local radius = math.min(U(20), math.floor(r.h / 2))
            local border = U(2)
            if e.kind == "error" then
                bb:paintRoundedRect(rx, ry, r.w, r.h, BLACK, radius)
            else
                bb:paintRoundedRect(rx, ry, r.w, r.h, BLACK, radius)
                bb:paintRoundedRect(rx + border, ry + border, r.w - 2 * border, r.h - 2 * border,
                    WHITE, math.max(0, radius - border))
            end
            e.tb:paintTo(bb, rx + e.pad_x, ry + e.pad_y)
        end
    end
end

function Layer:onCloseWidget()
    if self.area then UIManager:setDirty(nil, "ui", self.area) end
end

-- ── Public ─────────────────────────────────────────────────────────────────
local Toast = {}

-- Redraws after the stack changed.
local function refresh()
    if #entries == 0 then
        if layer then
            local l = layer
            layer = nil
            -- No refresh arguments: closing with one would redraw the whole
            -- screen. The layer's onCloseWidget refreshes just its own area.
            UIManager:close(l)
        end
        return
    end
    if not layer then
        layer = Layer:new{}
        UIManager:show(layer, "ui", layer.area)
        return
    end
    local region = layer:relayout()
    if region then UIManager:setDirty(layer, function() return "ui", region end) end
end

local function remove(entry)
    for i, e in ipairs(entries) do
        if e == entry then
            table.remove(entries, i)
            break
        end
    end
    if entry.expire then
        UIManager:unschedule(entry.expire)
        entry.expire = nil
    end
    refresh()
    release(entry)
end

function Toast.show(text, opts)
    opts = opts or {}
    text = tostring(text or "")
    if text == "" then return end
    local kind = opts.kind or "info"
    local timeout = opts.timeout or (kind == "error" and 4 or 3)
    local persistent = opts.persistent

    -- The same message already up: it just stays a while longer.
    for _i, e in ipairs(entries) do
        if e.text == text and e.kind == kind then
            if e.expire then UIManager:unschedule(e.expire) end
            e.expire = nil
            if not persistent then
                e.expire = function()
                    e.expire = nil
                    remove(e)
                end
                UIManager:scheduleIn(timeout, e.expire)
            end
            return e
        end
    end

    local entry = { text = text, kind = kind, bottom = opts.bottom }
    if not persistent then
        entry.expire = function()
            entry.expire = nil
            remove(entry)
        end
    end
    entries[#entries + 1] = entry
    -- Too many at once: the oldest goes.
    while #entries > MAX_VISIBLE do
        local oldest = entries[1]
        remove(oldest)
    end
    if entry.expire then UIManager:scheduleIn(timeout, entry.expire) end
    refresh()
    return entry
end

function Toast.error(text, opts)
    opts = opts or {}
    opts.kind = "error"
    return Toast.show(text, opts)
end

-- A message for work that blocks: it stays until Toast.dismiss(entry) and is
-- painted right away, before the work starts.
function Toast.working(text, opts)
    opts = opts or {}
    opts.persistent = (opts.timeout == nil)   -- with a timeout it also goes by itself, as a safety
    local entry = Toast.show(text or _("Working…"), opts)
    UIManager:forceRePaint()
    return entry
end

function Toast.dismiss(entry)
    if entry then remove(entry) end
end

-- Takes every message away at once.
function Toast.clear()
    while #entries > 0 do remove(entries[#entries]) end
end

return Toast
