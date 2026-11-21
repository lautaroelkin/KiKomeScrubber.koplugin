-- kobold/data/cover_color.lua — KiKome
-- The colour of a book's cover, for the three buttons of the Current book card
-- (ui/home_current.lua). The cover is shrunk to a few pixels; the ones that are
-- nearly grey, black or white are dropped and the rest vote by hue, weighted by
-- how saturated they are. The winning hue gives one pale shade for the buttons.
--
--   CoverColor.pill(file)   a colour to paint a button with, or nil when it
--                           should stay grey: no cover, a jacket with too few
--                           coloured pixels, or a screen that shows no colour.
--
-- The answer is worked out once per cover and kept.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local lfs        = require("libs/libkoreader-lfs")

local Screen = Device.screen

local CoverColor = {}

local SAMPLE_W, SAMPLE_H = 24, 36
local BINS = 36

-- ── Colour maths (hue, lightness, saturation in 0..1) ──────────────────────
local function rgbToHls(r, g, b)
    local maxc, minc = math.max(r, g, b), math.min(r, g, b)
    local l = (minc + maxc) / 2
    if maxc == minc then return 0, l, 0 end
    local d = maxc - minc
    local s = l <= 0.5 and d / (maxc + minc) or d / (2 - maxc - minc)
    local rc, gc, bc = (maxc - r) / d, (maxc - g) / d, (maxc - b) / d
    local h
    if r == maxc then h = bc - gc
    elseif g == maxc then h = 2 + rc - bc
    else h = 4 + gc - rc end
    return (h / 6) % 1, l, s
end

local function hueValue(m1, m2, hue)
    hue = hue % 1
    if hue < 1 / 6 then return m1 + (m2 - m1) * hue * 6 end
    if hue < 0.5 then return m2 end
    if hue < 2 / 3 then return m1 + (m2 - m1) * (2 / 3 - hue) * 6 end
    return m1
end

local function hlsToRgb(h, l, s)
    if s == 0 then return l, l, l end
    local m2 = l <= 0.5 and l * (1 + s) or l + s - l * s
    local m1 = 2 * l - m2
    return hueValue(m1, m2, h + 1 / 3), hueValue(m1, m2, h), hueValue(m1, m2, h - 1 / 3)
end

-- ── The screen ─────────────────────────────────────────────────────────────
-- Older KOReader builds cannot paint RGB fills.
local function canPaintColour()
    local ok, yes = pcall(function()
        return Screen:isColorEnabled() and Blitbuffer.ColorRGB32 ~= nil
    end)
    return ok and yes == true
end

-- ── The cover's hue ────────────────────────────────────────────────────────
-- hue, saturation of the winning hue, or nil when the cover is not coloured.
local function dominantHue(bb)
    local bins, sats = {}, {}
    for i = 0, BINS - 1 do bins[i], sats[i] = 0, {} end
    local total = bb:getWidth() * bb:getHeight()
    if total == 0 then return nil end
    for y = 0, bb:getHeight() - 1 do
        for x = 0, bb:getWidth() - 1 do
            local c = bb:getPixel(x, y):getColorRGB32()
            local h, l, s = rgbToHls(c.r / 255, c.g / 255, c.b / 255)
            if s >= 0.28 and l >= 0.12 and l <= 0.9 then
                local k = math.floor(h * BINS) % BINS
                bins[k] = bins[k] + s * (1 - math.abs(l - 0.5))
                sats[k][#sats[k] + 1] = s
            end
        end
    end
    -- Neighbouring bins vote together, so a hue split across a bin edge wins.
    local best, best_v = 0, -1
    for i = 0, BINS - 1 do
        local v = bins[(i - 1) % BINS] * 0.5 + bins[i] + bins[(i + 1) % BINS] * 0.5
        if v > best_v then best, best_v = i, v end
    end
    if best_v / total < 0.06 then return nil end
    local list = sats[best]
    table.sort(list)
    local sat = #list > 0 and list[math.floor(#list / 2) + 1] or 0.5
    return (best + 0.5) / BINS, sat
end

local cache, cache_count = {}, 0
local NONE = false

-- The pale colour for `file`'s buttons: { r, g, b } in 0..1, or nil.
local function shade(file)
    local mtime = lfs.attributes(file, "modification") or 0
    local key = file .. "|" .. tostring(mtime)
    local hit = cache[key]
    if hit ~= nil then return hit or nil end

    local out = nil
    local ok = pcall(function()
        local src = require("kobold.data.covers").get(file, 120, 180)
        if not src then return end
        -- a small copy to look at (the cached cover is not changed)
        local small = src:scale(SAMPLE_W, SAMPLE_H)
        if not small then return end
        local hue, sat = dominantHue(small)
        if small ~= src and small.free then small:free() end
        if not hue then return end
        sat = math.min(0.75, math.max(0.45, sat))
        out = { hue = hue, sat = sat }
    end)
    if not ok then out = nil end

    if cache_count > 200 then cache, cache_count = {}, 0 end
    cache[key] = out or NONE
    cache_count = cache_count + 1
    return out
end

function CoverColor.pill(file)
    if not file or not canPaintColour() then return nil end
    -- Night mode: a tinted pill is drawn two ways at once (its straight middle is
    -- inverted, its round ends are not), so it showed two colours. The plain grey the
    -- other pills and tiles use is drawn the same all over.
    if Screen.night_mode then return nil end
    local s = shade(file)
    if not s then return nil end
    local hue = s.hue
    -- Night mode inverts the screen: paint the hue turned half way round, so
    -- the inverted screen shows the cover's own hue.
    if Screen.night_mode then hue = (hue + 0.5) % 1 end
    local r, g, b = hlsToRgb(hue, 0.86, s.sat)
    local function byte(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
    local ok, color = pcall(function()
        return Blitbuffer.ColorRGB32(byte(r), byte(g), byte(b), 0xFF)
    end)
    return ok and color or nil
end

return CoverColor
