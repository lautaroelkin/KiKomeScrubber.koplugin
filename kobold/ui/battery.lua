-- kobold/ui/battery.lua — Kobold
-- Battery icon for the status bar. Kobold's own icons are drawn with bars
-- (icons/battery-full.svg, -medium, -low and the empty battery.svg; the
-- charging one is battery-charging.svg), the tip on the left, and the one that
-- matches the charge is shown. In percentage mode (Kobold Settings > Battery)
-- the icon is the same, and the charge percentage is written to its right.
-- KOReader's old icon has a black fill that follows the charge instead.

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local Geom            = require("ui/geometry")
local IconWidget      = require("ui/widget/iconwidget")
local TextWidget      = require("ui/widget/textwidget")
local Widget          = require("ui/widget/widget")
local lfs             = require("libs/libkoreader-lfs")
local KoboldMeta      = require("kobold.meta")

local Screen = Device.screen

-- Kobold's own battery icon; its tip already points left.
-- Two icon sets, picked by Kobold Settings > Icons. Each has its icon, the
-- charging icon (fill mode only), the turn to apply, and in the SVG's 24 x 24
-- grid INNER (the inside of the outline, for the percentage) and FILL (the
-- area the charge fills).
local SETS = {
    -- Kobold's own. The drawings have the tip on the right, so they are turned
    -- 180 degrees to put it on the left (set rotation = 0 to have it on the
    -- right). `bars` lists the icons by charge: the first one whose `min` the
    -- charge reaches is shown; under all of them, the empty one (`icon`).
    kobold = {
        icon = "battery.svg", charging = "battery-charging.svg", rotation = 180,
        bars = {
            { min = 70, icon = "battery-full.svg" },
            { min = 40, icon = "battery-medium.svg" },
            { min = 15, icon = "battery-low.svg" },
        },
        -- The inside of the outline once turned, for the percentage.
        INNER = { x = 7, y = 7, w = 14, h = 10 },
    },
    -- The battery Kobold used before its own icons, turned 180 degrees so
    -- the tip faces left.
    koreader = {
        icon = "battery-classic.svg", charging = "battery-classic-charging.svg", rotation = 180,
        -- Its bolt is plain black, so a fill under it would hide it.
        no_fill_while_charging = true,
        INNER = { x = 7, y = 9, w = 13, h = 6 },
        FILL  = { x = 8, y = 10, w = 11, h = 4 },
    },
}

local function existing(name)
    local path = name and KoboldMeta.icon(name)
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

-- Charge 0..100, or nil when the device does not report it.
local function capacity()
    local ok, level = pcall(function() return Device:getPowerDevice():getCapacity() end)
    if ok and tonumber(level) then return math.max(0, math.min(100, tonumber(level))) end
    return nil
end

local function charging()
    local ok, on = pcall(function() return Device:getPowerDevice():isCharging() end)
    return ok and on and true or false
end

local KoboldBattery = Widget:extend{
    size   = nil,     -- the SVG is drawn size x size
    slot_h = nil,     -- height given to the icon in the status bar row
    style  = "fill",  -- "fill" or "percent"
}

function KoboldBattery:init()
    self.level = capacity()
    local set = require("kobold.data.prefs").get("icons") == "koreader" and SETS.koreader or SETS.kobold
    self.set = set
    local file = existing(set.icon)
    -- The icon follows the charge: the bars icon that matches it (Kobold's
    -- icons)...
    if set.bars and self.level then
        for _i, bar in ipairs(set.bars) do
            if self.level >= bar.min then
                file = existing(bar.icon) or file
                break
            end
        end
    end
    -- ...and while charging, the charging icon.
    local charging_svg = charging() and existing(set.charging)
    if charging_svg then file = charging_svg end
    self.show_level = not (charging_svg and set.no_fill_while_charging)
    if file then
        local ok, icon = pcall(function()
            return IconWidget:new{
                file = file, width = self.size, height = self.size,
                alpha = true, original_in_nightmode = false,
                rotation_angle = set.rotation,
            }
        end)
        if ok then self.icon = icon end
    end
    -- In percentage mode the slot is wider: the number sits to the right of the
    -- icon, in room kept for three digits so the icons beside it never shift.
    self.dimen = Geom:new{
        w = self.size + (self.style == "percent" and KoboldBattery.labelWidth() or 0),
        h = self.slot_h,
    }
end

-- The face of the percentage written beside the icon.
local function labelFace()
    return Font:getFace("cfont", 14)
end

local LABEL_GAP = 2   -- dp between the icon and its percentage

-- Room the percentage takes to the right of the icon: the gap and "100%".
function KoboldBattery.labelWidth()
    local t = TextWidget:new{ text = "100%", face = labelFace() }
    local w = t:getSize().w
    t:free()
    return Screen:scaleBySize(LABEL_GAP) + w
end

function KoboldBattery:getSize()
    return self.dimen
end

-- The SVG only uses the middle band of its square, so the square is centred
-- on the row; the transparent parts may reach past the row without showing.
function KoboldBattery:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local top = y + math.floor((self.slot_h - self.size) / 2)
    local FILL = self.set.FILL
    local u = self.size / 24
    local function px(v) return math.floor(v * u + 0.5) end
    -- The fill is painted first and the icon over it, so a charging bolt
    -- stays visible on top of the fill.
    if FILL and self.level and self.show_level then
        -- Drains toward the tip: the full part stays on the right.
        local fill_w = px(FILL.w)
        local w = math.floor(fill_w * self.level / 100 + 0.5)
        if w > 0 then
            bb:paintRect(x + px(FILL.x) + fill_w - w, top + px(FILL.y), w, px(FILL.h),
                Blitbuffer.COLOR_BLACK)
        end
    end
    if self.icon then self.icon:paintTo(bb, x, top) end

    -- Percentage mode: the number to the right of the icon, centred on the row.
    if self.style == "percent" and self.level then
        local text = TextWidget:new{
            text = math.floor(self.level + 0.5) .. "%",
            face = labelFace(),
            max_width = self.dimen.w - self.size,
        }
        local ts = text:getSize()
        text:paintTo(bb, x + self.size + Screen:scaleBySize(LABEL_GAP),
            y + math.floor((self.slot_h - ts.h) / 2))
        text:free()
    end
end

-- Charge 0..100 (or nil) and whether the device is charging.
function KoboldBattery.state()
    return capacity(), charging()
end

function KoboldBattery:free()
    if self.icon then self.icon:free() end
end

return KoboldBattery
