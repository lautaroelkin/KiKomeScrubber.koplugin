-- kobold/ui/clock_popup.lua — Kobold
-- Clock popup, opened by tapping the time in the status bar. Left-aligned
-- under the bar, in the same rounded box style as the other popups. It only
-- shows: the time (as KOReader is set to show it), the weekday and the full
-- date with the year. What the bar itself shows, and in which layout, is
-- chosen in Settings > General > Status bar. A tap anywhere closes it.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Event           = require("ui/event")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("kobold.i18n")
local KoboldClock     = require("kobold.data.clock")
local KoboldPopup     = require("kobold.ui.popup")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local KoboldClockPopup = InputContainer:extend{
    modal = true,
    name = "kobold_clock",
}

local function is24Hour()
    return not (G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock"))
end

function KoboldClockPopup:build()
    local pad    = Screen:scaleBySize(18)
    local pad_b  = Screen:scaleBySize(10)
    local border = Screen:scaleBySize(2)
    local line_h = Screen:scaleBySize(1)
    local row_h  = Screen:scaleBySize(44)
    local fw     = KoboldPopup.width()
    local inner  = fw - 2 * (pad + border)
    local fx, fy = KoboldPopup.originLeft()

    local time_text, weekday, date = KoboldClock.popupLines()
    local time_w = TextWidget:new{ text = time_text, face = KoboldWidgets.face(28), bold = true }
    local day_gap = Screen:scaleBySize(10)
    local day_max_w = math.max(Screen:scaleBySize(40), inner - time_w:getSize().w - day_gap)
    local day_w = TextWidget:new{
        text = weekday,
        face = KoboldWidgets.secondaryFace(18),
        fgcolor = KoboldWidgets.subtitleColor(),
        max_width = day_max_w,
    }

    local header = VerticalGroup:new{
        align = "left",
        HorizontalGroup:new{
            align = "center",
            time_w,
            HorizontalSpan:new{ width = day_gap },
            day_w,
        },
        VerticalSpan:new{ width = Screen:scaleBySize(4) },
        TextWidget:new{ text = date, face = KoboldWidgets.face(18), max_width = inner },
    }

    local above_line = Screen:scaleBySize(12)
    local below_line = Screen:scaleBySize(4)
    local divider = KoboldWidgets.fixed(inner, line_h, HorizontalGroup:new{
        HorizontalSpan:new{ width = -pad },
        LineWidget:new{
            dimen = Geom:new{ w = inner + 2 * pad, h = line_h },
            background = Blitbuffer.COLOR_LIGHT_GRAY,
        },
    })

    local content = VerticalGroup:new{
        align = "left",
        header,
        VerticalSpan:new{ width = above_line },
        divider,
        VerticalSpan:new{ width = below_line },
        KoboldWidgets.switchRow(inner, row_h, _("24-hour clock"), is24Hour()),
    }

    local box = FrameContainer:new{
        width = fw, bordersize = border,
        padding = pad, padding_bottom = pad_b,
        radius = KoboldPopup.boxRadius(),
        background = Blitbuffer.COLOR_WHITE,
        content,
    }
    local fh = box:getSize().h
    self.frame_dimen = Geom:new{ x = fx, y = fy, w = fw, h = fh }

    local line_y = fy + border + pad + header:getSize().h + above_line
    self.toggle_rect = Geom:new{
        x = fx,
        y = line_y,
        w = fw,
        h = (fy + fh) - line_y,
    }
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

function KoboldClockPopup:refresh()
    local old = self.frame_dimen
    self[1] = self:build()
    local area = old and old:combine(self.frame_dimen) or self.frame_dimen
    UIManager:setDirty(self, "ui", area)
end

-- Tapping the 24-hour row toggles KOReader's clock format; any other tap closes.
function KoboldClockPopup:onTapClock(_, ges)
    if ges and ges.pos and self.toggle_rect and ges.pos:intersectWith(self.toggle_rect) then
        if G_reader_settings then
            G_reader_settings:saveSetting("twelve_hour_clock", is24Hour())
        end
        UIManager:broadcastEvent(Event:new("KoboldSettingsChanged"))
        self:refresh()
        return true
    end
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
