-- kobold/ui/transition.lua — Kobold
-- The small "Closing" pill shown while KOReader closes a book that was opened
-- from KiKome: the same black pill as the "Opening" one on the covers, low on
-- the page, so the page stays in view. Painted at once, so it is on screen
-- while KOReader does the slow part. Opening has no panel: the book's cover
-- shows an "Opening" pill instead (see cover_badge.lua and reader.lua). Both
-- can be turned off together in KiKome Settings.

local Device          = require("device")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local UIManager       = require("ui/uimanager")
local KoboldPrefs     = require("kobold.data.prefs")
local CoverBadge      = require("kobold.ui.cover_badge")

local Screen = Device.screen

local KoboldTransition = {}

-- The closing message: a small black pill ("Closing") at the bottom of the
-- screen, the same pill as the "Opening" one on the covers.
local Panel = InputContainer:extend{
    modal = true,
    name = "kobold_transition",
    text = nil,
}

function Panel:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pill = CoverBadge.pill(self.text, Screen:scaleBySize(120), W - 2 * Screen:scaleBySize(24), 17)
    local size = pill:getSize()
    -- The window covers the screen (so it blocks taps); box_dimen is the
    -- part that needs refreshing.
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    local px = math.floor((W - size.w) / 2)
    local py = H - size.h - Screen:scaleBySize(72)
    self.box_dimen = Geom:new{ x = px, y = py, w = size.w, h = size.h }
    pill.overlap_offset = { px, py }
    self[1] = OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, pill }
end


local current = nil

-- True when the opening pill and the closing panel are turned on (KiKome
-- Settings, off by default). On, KOReader's "Opening file" message is hidden;
-- off, opening and closing look exactly as in KOReader.
function KoboldTransition.enabled()
    return KoboldPrefs.get("transition") == true
end

-- Shows the panel with `text` and paints it right away.
function KoboldTransition.show(text)
    if not KoboldTransition.enabled() then return end
    KoboldTransition.close()
    current = Panel:new{ text = text }
    UIManager:show(current, "ui", current.box_dimen)
    UIManager:forceRePaint()
    -- Safety: the panel is modal and blocks taps, so it never stays longer
    -- than this even if the book never reports back.
    local shown = current
    UIManager:scheduleIn(15, function()
        if current == shown then KoboldTransition.close() end
    end)
end

-- Closes the panel once the book is fully open (see reader.lua), with a
-- full refresh: the book was opened quietly (no KOReader message, a light
-- refresh), so this leaves the page clean.
function KoboldTransition.bookReady()
    if current then
        KoboldTransition.close()
        UIManager:setDirty("all", "full")
    end
end

function KoboldTransition.close()
    if current then
        local p = current
        current = nil
        UIManager:close(p)
    end
end

return KoboldTransition
