-- kobold/ui/cover_splash.lua — KiKome
-- The book's cover, large and centred on a white screen, with something under
-- it. Two uses:
--   * Opening: shown when the mini cover in the navigation bar is tapped, with
--     the black "Opening" pill under it, while KOReader opens the book. Painted
--     at once, so it is on screen during the slow part. It goes away when the
--     book is open (see reader.lua). Turned on and off with the rest of the
--     opening and closing indicators in KiKome Settings.
--   * Viewing: shown when the cover in Book Details is tapped, with a round
--     close button under it. A tap anywhere (or Back) closes it.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InputContainer  = require("ui/widget/container/inputcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local UIManager       = require("ui/uimanager")
local _               = require("gettext")
local CoverBadge      = require("kobold.ui.cover_badge")
local Rounded         = require("kobold.ui.rounded")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local CoverSplash = {}

local Splash = InputContainer:extend{
    modal = true,
    name = "kobold_cover_splash",
    file = nil,
    view = false,   -- true: viewing the cover, with a close button
}

function Splash:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    -- The largest cover (2:3) that leaves room around it and for the pill.
    local cover_h = math.min(math.floor(H * 0.6), math.floor(W * 0.74 * 1.5))
    local cover_w = math.floor(cover_h / 1.5)
    local cover = Rounded.cover(self.file, cover_w, cover_h, { outline = true })
    local sw, sh = KoboldWidgets.coverBox(self.file, cover_w, cover_h)
    sw, sh = math.min(sw or cover_w, cover_w), math.min(sh or cover_h, cover_h)
    -- What goes under the cover: the "Opening" pill, or a round close button.
    local under
    if self.view then
        local d = Screen:scaleBySize(48)
        under = FrameContainer:new{
            bordersize = 0, margin = 0, padding = 0, radius = math.floor(d / 2),
            background = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY,
            CenterContainer:new{
                dimen = Geom:new{ w = d, h = d },
                KoboldWidgets.icon("close", Screen:scaleBySize(20)),
            },
        }
    else
        under = CoverBadge.pill(_("Opening"), Screen:scaleBySize(130), W - 2 * Screen:scaleBySize(24), 18)
    end
    local us = under:getSize()
    local gap = Screen:scaleBySize(28)
    local top = math.floor((H - (sh + gap + us.h)) / 2)
    cover.overlap_offset = { math.floor((W - sw) / 2), top }
    under.overlap_offset = { math.floor((W - us.w) / 2), top + sh + gap }
    self[1] = FrameContainer:new{
        bordersize = 0, margin = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, cover, under },
    }
    if self.view then
        -- A tap anywhere closes it; so does the Back key.
        KoboldTaps.add(self, "KoboldSplashClose", 0, 0, W, H, function() self:onClose() end)
        if Device:hasKeys() then
            self.key_events = { Close = { { Device.input.group.Back } } }
        end
    end
end

function Splash:onClose()
    CoverSplash.close()
    return true
end

local current = nil

-- Shows the splash for `file` and paints it right away. With `view`, it is the
-- cover viewer (a close button, closed by a tap); without, the opening splash.
function CoverSplash.show(file, view)
    CoverSplash.close()
    current = Splash:new{ file = file, view = view and true or false }
    UIManager:show(current, "ui", current.dimen)
    if view then return end
    UIManager:forceRePaint()
    -- It is modal and blocks taps, so it never stays longer than this even if
    -- the book never reports back.
    local shown = current
    UIManager:scheduleIn(15, function()
        if current == shown then CoverSplash.close() end
    end)
end

function CoverSplash.close()
    if current then
        local w = current
        current = nil
        UIManager:close(w)
    end
end

return CoverSplash
