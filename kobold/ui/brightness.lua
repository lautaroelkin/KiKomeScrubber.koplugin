-- kobold/ui/brightness.lua — Kobold
-- Brightness popup opened from the contrast icon in the status bar. It has a
-- frontlight slider, plus a natural light slider only on devices that have one.
-- Tap the minus or plus to step, or tap the track to jump. Tap outside the box
-- to close it.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local Widget          = require("ui/widget/widget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local KoboldPopup     = require("kobold.ui.popup")
local KoboldWidgets   = require("kobold.ui.widgets")
local _               = require("kobold.i18n")

local Screen = Device.screen

-- Frontlight on/off, same rules as the Scrubber menu's toggle: on means the
-- intensity is above 0 (the slider is off when it sits at its minimum).
local function frontlightIsOn()
    local ok, res = pcall(function()
        local powerd = Device:getPowerDevice()
        if powerd and type(powerd.frontlightIntensity) == "function" then
            return (tonumber(powerd:frontlightIntensity()) or 0) > 0
        elseif powerd and type(powerd.isFrontlightOn) == "function" then
            return powerd:isFrontlightOn()
        end
    end)
    return ok and res == true
end

-- Level the light goes back to when turned on: the last one it had before
-- being turned off (shared with the Scrubber menu), else one step up.
local function lightOnLevel(powerd)
    local lo = (tonumber(powerd.fl_min) or 0) + 1
    local hi = tonumber(powerd.fl_max) or 100
    local last = G_reader_settings and tonumber(G_reader_settings:readSetting("page_scrubber_fl_last"))
    if not last or last < lo then
        last = math.max(lo, math.floor((hi - lo) / 10 + 0.5))
    end
    return math.min(hi, last)
end

-- Drawn controls. They are painted by hand (not with font glyphs) so they sit
-- exactly in the middle of their row, level with the text beside them.

-- "-" / "+" sign, drawn without any circle around it.
local StepButton = Widget:extend{ size = 0, plus = false }

function StepButton:getSize() return Geom:new{ w = self.size, h = self.size } end

function StepButton:paintTo(bb, x, y)
    local s = self.size
    local arm = math.floor(s * 0.62)
    local th = Screen:scaleBySize(3)
    bb:paintRect(x + math.floor((s - arm) / 2), y + math.floor((s - th) / 2), arm, th, Blitbuffer.COLOR_BLACK)
    if self.plus then
        bb:paintRect(x + math.floor((s - th) / 2), y + math.floor((s - arm) / 2), th, arm, Blitbuffer.COLOR_BLACK)
    end
end

function StepButton:free() end

-- Slider: rounded grey track, rounded black fill up to the knob, and a ring
-- knob (thin black ring, white centre).
local SliderBar = Widget:extend{ w = 0, h = 0, frac = 0, knob = 0, track_h = 0 }

function SliderBar:getSize() return Geom:new{ w = self.w, h = self.h } end

function SliderBar:paintTo(bb, x, y)
    local cy = y + math.floor(self.h / 2)
    local ty = cy - math.floor(self.track_h / 2)
    local kx = math.max(0, math.min(self.w - self.knob,
        math.floor(self.frac * self.w) - math.floor(self.knob / 2)))
    local fill_w = math.max(self.track_h, kx + math.floor(self.knob / 2))
    local tr = math.floor(self.track_h / 2)
    bb:paintRoundedRect(x, ty, self.w, self.track_h, Blitbuffer.COLOR_LIGHT_GRAY, tr)
    bb:paintRoundedRect(x, ty, fill_w, self.track_h, Blitbuffer.COLOR_BLACK, tr)
    local ring = Screen:scaleBySize(2)
    local ky = cy - math.floor(self.knob / 2)
    bb:paintRoundedRect(x + kx, ky, self.knob, self.knob, Blitbuffer.COLOR_BLACK, math.floor(self.knob / 2))
    bb:paintRoundedRect(x + kx + ring, ky + ring, self.knob - 2 * ring, self.knob - 2 * ring,
        Blitbuffer.COLOR_WHITE, math.floor((self.knob - 2 * ring) / 2))
end

function SliderBar:free() end

local KoboldBrightness = InputContainer:extend{
    modal = true,
    name = "kobold_brightness",
}

-- Sliders for this device. Natural light is added only when the device has it.
-- Brightness starts at 1, because 0 would toggle the frontlight off.
function KoboldBrightness:buildSliders()
    local powerd = Device:getPowerDevice()
    local sliders = {
        {
            -- The lowest level that really lights the screen: on some devices the
            -- minimum level (fl_min) is the "off" state, so the first lit level is
            -- one above it. The percentage counts from the off level.
            title = _("Brightness"), min = (tonumber(powerd.fl_min) or 0) + 1, max = powerd.fl_max,
            base = tonumber(powerd.fl_min) or 0,
            get = function() return powerd:frontlightIntensity() end,
            set = function(v)
                powerd:setIntensity(v)
                -- If the light stayed off (that level counts as off on this
                -- device), go up until it lights, so +/- never get stuck at 0%.
                local top = tonumber(powerd.fl_max) or 100
                local try = v
                while v > 0 and try < top and (tonumber(powerd:frontlightIntensity()) or 0) <= 0 do
                    try = try + 1
                    powerd:setIntensity(try)
                end
                powerd:updateResumeFrontlightState()
            end,
        },
    }
    if Device:hasNaturalLight() then
        sliders[#sliders + 1] = {
            title = _("Natural light"), min = powerd.fl_warmth_min, max = powerd.fl_warmth_max,
            get = function() return powerd:toNativeWarmth(powerd:frontlightWarmth()) end,
            set = function(v) powerd:setWarmth(powerd:fromNativeWarmth(v)) end,
        }
    end
    return sliders
end

-- Builds the popup box and records each slider's touch rectangles, in screen
-- coordinates. The box sits just under the status bar, right-aligned with it.
function KoboldBrightness:build()
    local pad       = Screen:scaleBySize(18)
    local border    = Screen:scaleBySize(2)
    local title_h   = Screen:scaleBySize(34)
    local row_h     = Screen:scaleBySize(50)
    local sec_gap   = Screen:scaleBySize(18)
    local label_w   = Screen:scaleBySize(34)   -- the round - / + buttons
    local slide_gap = Screen:scaleBySize(14)
    local knob      = Screen:scaleBySize(30)
    local track_h   = Screen:scaleBySize(6)
    local sw_w = select(2, KoboldWidgets.switch(false))

    local fw    = KoboldPopup.width()
    local inner = fw - 2 * (pad + border)
    local track_w = inner - 2 * (label_w + slide_gap)
    local n  = #self.sliders
    local night_h = Screen:scaleBySize(44)
    local fh = n * (title_h + row_h) + (n - 1) * sec_gap + 2 * (pad + border)
        + sec_gap + night_h
    local fx, fy = KoboldPopup.origin(fw)
    local x0 = fx + border + pad
    local y0 = fy + border + pad
    self.frame_dimen = Geom:new{ x = fx, y = fy, w = fw, h = fh }
    self.hit = {}
    self.light_rect = nil

    local function step(plus)
        return CenterContainer:new{
            dimen = Geom:new{ w = label_w, h = row_h },
            StepButton:new{ size = label_w, plus = plus },
        }
    end
    -- A thin grey line centred in the gap between two sections (the gap keeps
    -- its exact height, so the touch rectangles do not move).
    local function divider()
        local line = math.max(1, Screen:scaleBySize(1))
        local above = math.floor((sec_gap - line) / 2)
        return VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = above },
            LineWidget:new{ dimen = Geom:new{ w = inner, h = line }, background = Blitbuffer.COLOR_LIGHT_GRAY },
            VerticalSpan:new{ width = sec_gap - above - line },
        }
    end

    local sections = VerticalGroup:new{ align = "left" }
    for i, s in ipairs(self.sliders) do
        local base = s.base or s.min
        local frac = (s.get() - base) / math.max(s.max - base, 1)
        frac = math.max(0, math.min(1, frac))
        local row_y = y0 + (i - 1) * (title_h + row_h + sec_gap) + title_h

        -- Title row: name (with the frontlight switch beside it on the first
        -- slider) on the left, percentage on the right; all centred in the row.
        local title = TextWidget:new{ text = s.title, face = KoboldWidgets.face(19), bold = true }
        local pct = TextWidget:new{
            text = math.floor(frac * 100 + 0.5) .. "%",
            face = KoboldWidgets.face(16),
            fgcolor = KoboldWidgets.subtitleColor(),
        }
        local head = HorizontalGroup:new{ align = "center", title }
        if i == 1 and self.has_light then
            -- Percentage right after the name; the frontlight switch takes
            -- the right end of the row, straight above the night mode one.
            local sp = Screen:scaleBySize(12)
            head[#head + 1] = HorizontalSpan:new{ width = sp }
            head[#head + 1] = pct
            local sw = KoboldWidgets.switch(frontlightIsOn())
            local used_w = title:getSize().w + sp + pct:getSize().w + sw_w
            head[#head + 1] = HorizontalSpan:new{ width = math.max(0, inner - used_w) }
            head[#head + 1] = sw
            local hit_pad = Screen:scaleBySize(10)
            self.light_rect = Geom:new{
                x = x0 + inner - sw_w - hit_pad, y = row_y - title_h,
                w = sw_w + 2 * hit_pad, h = title_h,
            }
        else
            local used_w = title:getSize().w + pct:getSize().w
            head[#head + 1] = HorizontalSpan:new{ width = math.max(0, inner - used_w) }
            head[#head + 1] = pct
        end
        sections[#sections + 1] = CenterContainer:new{
            dimen = Geom:new{ w = inner, h = title_h }, head,
        }

        -- Slider row: round - button, the slider, round + button.
        sections[#sections + 1] = HorizontalGroup:new{
            align = "center",
            step(false), HorizontalSpan:new{ width = slide_gap },
            SliderBar:new{ w = track_w, h = row_h, frac = frac, knob = knob, track_h = track_h },
            HorizontalSpan:new{ width = slide_gap }, step(true),
        }
        sections[#sections + 1] = divider()

        self.hit[i] = {
            minus = Geom:new{ x = x0, y = row_y, w = label_w, h = row_h },
            plus  = Geom:new{ x = x0 + inner - label_w, y = row_y, w = label_w, h = row_h },
            track = Geom:new{ x = x0 + label_w + slide_gap, y = row_y, w = track_w, h = row_h },
        }
    end

    -- Night mode row: KOReader's inverted display, with the same switch.
    local night = G_reader_settings:isTrue("night_mode")
    local night_title = TextWidget:new{ text = _("Night mode"), face = KoboldWidgets.face(19), bold = true }
    sections[#sections + 1] = CenterContainer:new{
        dimen = Geom:new{ w = inner, h = night_h },
        HorizontalGroup:new{
            align = "center",
            night_title,
            HorizontalSpan:new{ width = math.max(0, inner - night_title:getSize().w - sw_w) },
            (KoboldWidgets.switch(night)),
        },
    }
    local night_y = y0 + n * (title_h + row_h + sec_gap)
    self.night_rect = Geom:new{ x = x0, y = night_y, w = inner, h = night_h }

    local box = FrameContainer:new{
        width = fw, bordersize = border, padding = pad,
        radius = KoboldPopup.boxRadius(),
        background = Blitbuffer.COLOR_WHITE,
        sections,
    }
    return KoboldPopup.place(self.dimen, fx, fy, box, KoboldPopup.anchor("brightness"))
end

function KoboldBrightness:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.sliders = self:buildSliders()
    self.has_light = (Device.hasFrontlight and Device:hasFrontlight()) and true or false
    self[1] = self:build()

    if Device:hasKeys() then
        self.key_events = {
            Close = { { Device.input.group.Back } },
        }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapBrightness = {
                GestureRange:new{
                    ges = "tap",
                    range = self.dimen,
                },
            },
            -- Drag the knob: touch it and slide (pan), or press and then slide
            -- (hold, hold_pan). A swipe may close a quick drag.
            -- Quick repeated taps on - / + can arrive as a double tap, and a
            -- slightly long press as a hold: both count as a tap too.
            DoubleTapBrightness   = { GestureRange:new{ ges = "double_tap",   range = self.dimen } },
            PanBrightness         = { GestureRange:new{ ges = "pan",          range = self.dimen } },
            PanReleaseBrightness  = { GestureRange:new{ ges = "pan_release",  range = self.dimen } },
            HoldBrightness        = { GestureRange:new{ ges = "hold",         range = self.dimen } },
            HoldPanBrightness     = { GestureRange:new{ ges = "hold_pan",     range = self.dimen } },
            HoldReleaseBrightness = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
            SwipeBrightness       = { GestureRange:new{ ges = "swipe",        range = self.dimen } },
        }
    end
end

-- Applies a new value to slider i, then redraws the box with the new position.
function KoboldBrightness:setValue(i, value)
    local s = self.sliders[i]
    value = math.max(s.min, math.min(s.max, math.floor(value + 0.5)))
    s.set(value)
    self.changed = true
    self[1] = self:build()
    UIManager:setDirty(self, function()
        return "ui", self.frame_dimen
    end)
end

-- Taps on -/+ step by 1% of the range (at least one level). Taps on the track jump to that point.
-- Taps outside the box close the popup. Taps inside the box but off a control do nothing.
function KoboldBrightness:onTapBrightness(_, ges)
    local pos = ges.pos
    if not pos:intersectWith(self.frame_dimen) then
        self:onClose()
        return true
    end
    if self.light_rect and pos:intersectWith(self.light_rect) then
        self:toggleLight()
        return true
    end
    if self.night_rect and pos:intersectWith(self.night_rect) then
        self:toggleNightMode()
        return true
    end
    for i, s in ipairs(self.sliders) do
        local hit = self.hit[i]
        if hit then
            local step = math.max(1, math.floor((s.max - s.min) / 100 + 0.5))
            local current = s.get()
            if pos:intersectWith(hit.minus) then
                self:setValue(i, current - step)
                return true
            elseif pos:intersectWith(hit.plus) then
                self:setValue(i, current + step)
                return true
            elseif pos:intersectWith(hit.track) then
                local frac = (pos.x - hit.track.x) / hit.track.w
                frac = math.max(0, math.min(1, frac))
                local base = s.base or s.min
                self:setValue(i, base + frac * (s.max - base))
                return true
            end
        end
    end
    return true
end

-- Dragging a knob. The touch area of a track reaches half a knob past each end,
-- so the knob can be grabbed at the ends too.
local function grabArea(hit)
    local pad = Screen:scaleBySize(15)
    return Geom:new{ x = hit.track.x - pad, y = hit.track.y, w = hit.track.w + 2 * pad, h = hit.track.h }
end

-- Moves slider i to the finger's x. Redraws only when the value changes.
function KoboldBrightness:dragTo(i, x)
    local s, hit = self.sliders[i], self.hit[i]
    if not (s and hit) then return end
    local frac = math.max(0, math.min(1, (x - hit.track.x) / hit.track.w))
    local base = s.base or s.min
    local value = math.floor(base + frac * (s.max - base) + 0.5)
    if value ~= s.get() then self:setValue(i, value) end
end

function KoboldBrightness:startDrag(ges)
    if not ges.pos then return false end
    for i = 1, #self.sliders do
        local hit = self.hit[i]
        if hit and ges.pos:intersectWith(grabArea(hit)) then
            self.drag = i
            return true
        end
    end
    return false
end

function KoboldBrightness:endDrag()
    if not self.drag then return false end
    self.drag = nil
    self.drag_end = KoboldWidgets.now()
    return true
end

function KoboldBrightness:onPanBrightness(_, ges)
    if not self.drag then
        -- Vertical pans are not for a horizontal slider.
        if ges.direction == "north" or ges.direction == "south" then return false end
        if not self:startDrag(ges) then return false end
    end
    self:dragTo(self.drag, ges.pos.x)
    return true
end

function KoboldBrightness:onHoldBrightness(_, ges)
    if self:startDrag(ges) then return true end
    -- A press that lasted a bit too long on a control still presses it.
    if ges.pos and self.frame_dimen and ges.pos:intersectWith(self.frame_dimen) then
        return self:onTapBrightness(_, ges)
    end
    return false
end

function KoboldBrightness:onDoubleTapBrightness(_, ges)
    return self:onTapBrightness(_, ges)
end

function KoboldBrightness:onHoldPanBrightness(_, ges)
    if not self.drag then return false end
    self:dragTo(self.drag, ges.pos.x)
    return true
end

function KoboldBrightness:onPanReleaseBrightness() return self:endDrag() end
function KoboldBrightness:onHoldReleaseBrightness() return self:endDrag() end

-- The swipe that can follow a quick drag must not do anything else.
function KoboldBrightness:onSwipeBrightness()
    if self.drag then self:endDrag(); return true end
    return self.drag_end ~= nil and KoboldWidgets.now() - self.drag_end < 0.4
end

-- Writes the light level and warmth to KOReader's settings file right away.
-- Changing the light only changes the hardware; KOReader saves it on a clean
-- exit, so after a crash or a forced power-off the next start restored an
-- older level. powerd:saveSettings is KOReader's own save; the keys are
-- written directly when it is missing.
local function saveLight()
    local powerd = Device:getPowerDevice()
    local ok = powerd.saveSettings and pcall(powerd.saveSettings, powerd)
    if not ok and G_reader_settings then
        if powerd.fl_intensity then G_reader_settings:saveSetting("frontlight_intensity", powerd.fl_intensity) end
        if powerd.fl_warmth then G_reader_settings:saveSetting("frontlight_warmth", powerd.fl_warmth) end
    end
    if G_reader_settings and G_reader_settings.flush then
        pcall(G_reader_settings.flush, G_reader_settings)
    end
end

-- Turns the frontlight on or off from the switch next to "Brightness": off
-- is intensity 0 (the level is remembered), on goes back to that level.
function KoboldBrightness:toggleLight()
    pcall(function()
        local powerd = Device:getPowerDevice()
        if frontlightIsOn() then
            local cur = tonumber(powerd:frontlightIntensity()) or 0
            if cur > 0 and G_reader_settings then
                G_reader_settings:saveSetting("page_scrubber_fl_last", cur)
            end
            powerd:setIntensity(0)
        else
            powerd:setIntensity(lightOnLevel(powerd))
        end
        if type(powerd.updateResumeFrontlightState) == "function" then
            powerd:updateResumeFrontlightState()
        end
    end)
    saveLight()
    self[1] = self:build()
    UIManager:setDirty(self, function()
        return "ui", self.frame_dimen
    end)
end

-- KOReader's own night mode toggle (the one in its menu and gestures),
-- sent to the file browser or reader that handles it. It refreshes the
-- whole screen itself; the popup is redrawn with the new state.
function KoboldBrightness:toggleNightMode()
    local Event = require("ui/event")
    local fm = package.loaded["apps/filemanager/filemanager"]
    local rui = package.loaded["apps/reader/readerui"]
    local target = (rui and rui.instance) or (fm and fm.instance)
    if target then
        target:handleEvent(Event:new("ToggleNightMode"))
    else
        UIManager:broadcastEvent(Event:new("ToggleNightMode"))
    end
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
end

function KoboldBrightness:onClose()
    if self.changed then saveLight() end
    KoboldPopup.close(self)
    return true
end

-- Opens the popup. Called from the contrast icon in the status bar.
function KoboldBrightness.show()
    KoboldPopup.show(KoboldBrightness:new{})
end

return KoboldBrightness
