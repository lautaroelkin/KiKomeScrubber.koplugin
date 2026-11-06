-- kobold/ui/clock_popup.lua — Kobold
-- Clock popup, opened by tapping the time in the status bar. Left-aligned
-- under the bar, in the same rounded box style as the other popups. It only
-- shows: the time (as KOReader is set to show it), the weekday and the full
-- date with the year. What the bar itself shows, and in which layout, is
-- chosen in Settings > General > Status bar. A tap anywhere closes it.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local KoboldClock     = require("kobold.data.clock")
local KoboldPopup     = require("kobold.ui.popup")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local KoboldClockPopup = InputContainer:extend{
    modal = true,
    name = "kobold_clock",
}

function KoboldClockPopup:build()
    local pad, border = Screen:scaleBySize(18), Screen:scaleBySize(2)
    local gap = Screen:scaleBySize(6)
    local fw = KoboldPopup.width()
    local inner = fw - 2 * (pad + border)
    local fx, fy = KoboldPopup.originLeft()

    local time_text, weekday, date = KoboldClock.popupLines()
    local content = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = time_text, face = KoboldWidgets.face(30), bold = true, max_width = inner },
        VerticalSpan:new{ width = gap },
        TextWidget:new{ text = weekday, face = KoboldWidgets.face(20), max_width = inner },
        TextWidget:new{ text = date, face = KoboldWidgets.face(20), max_width = inner },
    }
    local box = FrameContainer:new{
        bordersize = border, padding = pad,
        radius = KoboldPopup.boxRadius(),
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    local fh = box:getSize().h
    self.frame_dimen = Geom:new{ x = fx, y = fy, w = fw, h = fh }
    return KoboldPopup.place(self.dimen, fx, fy, box, KoboldPopup.anchor("clock"))
end

function KoboldClockPopup:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self[1] = self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapClock = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

-- Nothing in the box to press: any tap, inside or outside, closes it.
function KoboldClockPopup:onTapClock()
    return self:onClose()
end

function KoboldClockPopup:onClose()
    KoboldPopup.close(self)
    return true
end

function KoboldClockPopup.show()
    KoboldPopup.show(KoboldClockPopup:new{})
end

return KoboldClockPopup
