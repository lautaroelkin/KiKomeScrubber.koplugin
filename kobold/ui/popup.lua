-- kobold/ui/popup.lua — Kobold
-- Placement and refresh for the small status bar popups (brightness, Wi-Fi,
-- battery, clock): a box with rounded corners and a thin outline, floating
-- just under the status bar (no pointer towards the icon that opened it).
-- Showing and closing refresh only the box.

local Device          = require("device")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Refresh         = require("kobold.ui.refresh")

local Screen = Device.screen

local KoboldPopup = {}

-- Same margin and status bar height as the Kobold screens.
local function margin() return Screen:scaleBySize(30) end
local function statusH() return Screen:scaleBySize(40) end

-- Corner radius of the status bar popups: the same rounding as the book menu
-- (book_menu.lua) and the sheets.
function KoboldPopup.boxRadius()
    return Screen:scaleBySize(14)
end

-- Corner radius of the large panels (Kobold Settings, About, book details):
-- square, as on the e-reader.
function KoboldPopup.radius()
    return 0
end

-- Screen area of a large panel (Kobold Settings, About): inset from the
-- screen edges, so the screen below shows around it.
function KoboldPopup.panelRect()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local side = Screen:scaleBySize(22)
    local top = Screen:scaleBySize(36)
    return Geom:new{ x = side, y = top, w = W - 2 * side, h = H - top - side }
end

function KoboldPopup.width()
    return math.floor(Screen:getWidth() / 2)
end

-- Gap between the status bar and the box.
local function topGap() return Screen:scaleBySize(8) end

-- Top-left corner for a popup left-aligned under the status bar (the clock).
function KoboldPopup.originLeft()
    return margin(), margin() + statusH() + topGap()
end

-- Top-left corner of a box `fw` wide: its right edge lines up with the right
-- edge of the status bar.
function KoboldPopup.origin(fw)
    local x = Screen:getWidth() - margin() - fw
    local y = margin() + statusH() + topGap()
    return x, y
end

-- Screen x of the middle of each status bar item, recorded when the bar is
-- built (widgets.lua): "clock", "brightness", "wifi", "battery", "search".
local anchors = {}

function KoboldPopup.setAnchor(name, x)
    anchors[name] = x
end

function KoboldPopup.anchor(name)
    return anchors[name]
end

-- Full-screen transparent layer with `box` drawn at (fx, fy). (Older callers
-- still pass an anchor for a pointer; there is none now and it is ignored.)
function KoboldPopup.place(dimen, fx, fy, box)
    return OverlapGroup:new{
        dimen = dimen,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = fy },
            HorizontalGroup:new{ HorizontalSpan:new{ width = fx }, box },
        },
    }
end

-- The part of the screen to refresh for `popup`: its box, with a little
-- around it so the rounded outline is drawn and cleared completely.
local function region(popup)
    local d = popup.frame_dimen
    if not d then return nil end
    local m = Screen:scaleBySize(2)
    return Geom:new{ x = d.x - m, y = d.y - m, w = d.w + 2 * m, h = d.h + 2 * m }
end

-- Shows `popup` and refreshes only its box (popup.frame_dimen).
function KoboldPopup.show(popup)
    UIManager:show(popup, "ui", region(popup))
    -- Once more when the panel is free, in case this first update is lost.
    Refresh.settle(popup, function() return region(popup) end)
end

-- Closes `popup`. The screen below is repainted and the box area refreshed,
-- so no trace of the box is left on e-ink.
function KoboldPopup.close(popup)
    UIManager:close(popup, "ui", region(popup))
end

return KoboldPopup
