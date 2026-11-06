-- kobold/ui/taps.lua — Kobold
-- Registers named tap zones on a widget.

local Device          = require("device")
local _               = require("kobold.i18n")

local Screen = Device.screen

local KoboldTaps = {}

-- The last tap on any KiKome zone, so whoever opens a book can tell where on
-- the screen it was tapped (see cover_badge.lua).
local last_tap = nil  -- { pos = Geom point, at = os.time() }

-- The point of the latest tap, or nil when it was not just now.
function KoboldTaps.recentPos()
    if last_tap and os.time() - last_tap.at <= 3 then return last_tap.pos end
    return nil
end

-- Adds a tap zone at pixel rect (x, y, w, h) to an InputContainer `screen`.
-- KOReader's registerTouchZones expects screen_zone as ratios of the screen
-- size (ratio_x, ratio_y, ratio_w, ratio_h), so pixels are converted here.
-- `id` must be unique per screen; registering the same id again replaces the
-- zone. `handler` gets the gesture (ges.pos is the tap point).
function KoboldTaps.add(screen, id, x, y, w, h, handler)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    screen:registerTouchZones({
        {
            id = id,
            ges = "tap",
            screen_zone = {
                ratio_x = x / sw,
                ratio_y = y / sh,
                ratio_w = w / sw,
                ratio_h = h / sh,
            },
            handler = function(ges)
                if ges and ges.pos then last_tap = { pos = ges.pos, at = os.time() } end
                handler(ges)
                return true
            end,
        },
    })
end

-- Like add(), for a long-press ("hold") instead of a tap.
function KoboldTaps.hold(screen, id, x, y, w, h, handler)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    screen:registerTouchZones({
        {
            id = id,
            ges = "hold",
            screen_zone = { ratio_x = x / sw, ratio_y = y / sh, ratio_w = w / sw, ratio_h = h / sh },
            handler = function(ges)
                handler(ges)
                return true
            end,
        },
    })
end

-- Swipe down from the top edge opens KOReader's file manager menu, the same
-- pull-down menu the file browser has. Kobold screens sit above the file
-- manager, so its own swipe zone never sees the gesture; this forwards it.
-- The zone height matches KOReader's default top menu zone (1/8 of the screen).
function KoboldTaps.topMenu(screen)
    screen:registerTouchZones({
        {
            id = "KoboldTopMenu",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0,
                ratio_y = 0,
                ratio_w = 1,
                ratio_h = 1 / 8,
            },
            handler = function(ges)
                if ges.direction ~= "south" then return false end
                -- A book parked under KiKome has no file browser: it is made now,
                -- which closes the book and takes a moment. A message says so
                -- first, so the screen does not look frozen meanwhile.
                local Park = require("kobold.ui.park")
                local working, Toast
                if Park.isParked() then
                    local ok, T = pcall(require, "kobold.ui.toast")
                    if ok and T then
                        Toast = T
                        local ok2, entry = pcall(T.working, _("Closing the book…"), { timeout = 15 })
                        if ok2 then working = entry end
                    end
                end
                local fm = Park.fm()
                if working then pcall(Toast.dismiss, working) end
                local menu = fm and fm.menu
                if not menu then return false end
                if menu.onSwipeShowMenu then
                    return menu:onSwipeShowMenu(ges)
                end
                menu:onShowMenu()
                return true
            end,
        },
    })
end

return KoboldTaps
