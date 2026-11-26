-- kobold/ui/rounded.lua — Kobold
-- Rounded corners for covers. The option lives in Settings > Appearance > Rounded
-- corners and is on by default. Off means every cover keeps square corners.
--
--   Rounded.enabled()             the current setting
--   Rounded.cover(file, w, h, o)  KoboldWidgets.makeCover, with the corners
--                                 rounded when the setting is on
--   Rounded.snapCorners(...)      }  the two halves of the corner clipping,
--   Rounded.finish(...)           }  for code that paints a cover itself
--
-- The covers of the Home reading row are clipped by home.lua itself (it
-- clips the row, with Rounded.finish); this module covers everything else:
-- the library shelf, folder stacks and the list thumbnails.
--
-- How a corner is cut: the grey of the pixels of the four r x r corners of the
-- background is saved BEFORE the cover is painted, and AFTER it the pixels
-- outside the arc are put back (the shape of the scrubber's
-- _snapCorners/_restoreCorners). So
-- whatever was there shows through the corner (the second book of a stack, a
-- wallpaper) instead of a white square, and no pixel of the cover can stay
-- outside the outline: the same arc cuts the cover and draws the outline.
--
-- The outline's thickness comes from KoboldWidgets.outlineWidth(): 0 when the
-- "cover outline" option is off, and then the corners are cut with no line.
--
-- The arc is anti-aliased: each pixel on the edge takes a grey that is the mix
-- of what is outside, the outline and the cover, by how much of the pixel lies
-- in each. A stair-step arc looked rough on a Kindle's fine screen. If the
-- smoothing ever fails it turns itself off and the plain cut is used.

local Blitbuffer = require("ffi/blitbuffer")
local Device     = require("device")
local Geom       = require("ui/geometry")
local Widget     = require("ui/widget/widget")
local KoboldPrefs   = require("kobold.data.prefs")
local KoboldWidgets = require("kobold.ui.widgets")

local Screen = Device.screen
local WHITE = Blitbuffer.COLOR_WHITE
-- The same grey makeCover's frame uses on the straight sides.
local OUTLINE_COLOR = Blitbuffer.COLOR_DARK_GRAY

local M = {}

function M.enabled()
    return KoboldPrefs.get("rounded_corners") ~= false
end

local function radius() return Screen:scaleBySize(10) end

-- The radius for a cover of w x h: the usual one, smaller on a small cover (a
-- list thumbnail), where a big radius turns the cover into a blob.
function M.radiusFor(w, h)
    local r = radius()
    local cap = math.floor(math.min(w, h) * 0.09)
    return math.max(3, math.min(r, cap))
end

local function clampRadius(w, h, r)
    return math.max(0, math.min(r or 0, math.floor(w / 2), math.floor(h / 2)))
end

-- How many pixels of row `j` (0 = the edge) of an r x r corner lie outside
-- the arc.
local function outsideInset(j, r)
    if r <= 0 or j < 0 or j >= r then return 0 end
    local d = r - j - 0.5
    return r - math.ceil(math.sqrt(r * r - d * d))
end

-- ── Coverage of the corner pixels ───────────────────────────────────────────
local cov_cache = {}

-- For the top-left r x r corner: how much of each pixel lies inside the circle
-- of radius R centred on (r, r), from a 4 x 4 grid of samples. Row-major,
-- 1-based: t[j * r + i + 1] for the pixel in column i, row j.
local function circleCoverage(r, R)
    local t, N = {}, 4
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            local n = 0
            for b = 0, N - 1 do
                local py = j + (b + 0.5) / N - r
                for a = 0, N - 1 do
                    local px = i + (a + 0.5) / N - r
                    if px * px + py * py <= R * R then n = n + 1 end
                end
            end
            t[j * r + i + 1] = n / (N * N)
        end
    end
    return t
end

-- The coverage of the outer arc (radius r) and of the inner one (radius r - t,
-- the edge of the outline), kept for each pair.
local function coverageTables(r, t)
    local key = r * 64 + t
    local c = cov_cache[key]
    if not c then
        c = { out = circleCoverage(r, r) }
        if t > 0 and r - t >= 1 then c.inn = circleCoverage(r, r - t) end
        cov_cache[key] = c
    end
    return c
end

-- The grey (0-255) of a pixel as getPixel gives it.
local function gray(color) return color:getColor8().a end

-- All the pixel work below reads with bb:getPixel and writes with bb:setPixel
-- on the same buffer, and takes the outline's and the bar's grey from pixels
-- that were painted there. Whatever the screen does to colours (night mode
-- inverts them), a value read from it and written back to it comes out the
-- same, so the corners are right in day and in night mode. (A copy of the
-- corners in a buffer of its own holds them the other way round in night mode.)

-- Saves the grey of the four r x r corners of the rect x, y, w, h, only where
-- the arc cuts: the pixels it does not cover completely. Call it before
-- painting. Each corner is a table like circleCoverage's.
function M.snapCorners(bb, x, y, w, h, r)
    r = clampRadius(w, h, r)
    if r < 2 then return nil end
    local ok, snap = pcall(function()
        local out = coverageTables(r, 0).out
        -- px, py: where the corner starts on the screen; flip_x / flip_y: it is
        -- the mirror image of the top-left one `out` is made for.
        local function patch(px, py, flip_x, flip_y)
            local t = {}
            for j = 0, r - 1 do
                for i = 0, r - 1 do
                    local ci = flip_x and (r - 1 - i) or i
                    local cj = flip_y and (r - 1 - j) or j
                    if out[cj * r + ci + 1] < 1 then
                        t[j * r + i + 1] = gray(bb:getPixel(px + i, py + j))
                    end
                end
            end
            return t
        end
        return { r = r,
                 tl = patch(x, y, false, false), tr = patch(x + w - r, y, true, false),
                 bl = patch(x, y + h - r, false, true), br = patch(x + w - r, y + h - r, true, true) }
    end)
    return ok and snap or nil
end

-- Cuts the corners of the rect after it was painted: each pixel outside the
-- arc goes back to what `snap` saved (or to `fill`, white by default, when
-- there is no snapshot), the pixels on the arc get a grey that is the mix of
-- what is outside, the outline and the cover by how much of the pixel lies in
-- each, and the outline follows the arc. `line` is the outline's thickness, 0
-- for none. Only the corners are touched: the straight sides are the cover's
-- own frame.
local function finishCorners(bb, x, y, w, h, r, line, snap, fill)
    local t = math.max(0, math.min(line or 0, r - 1))
    local cov = coverageTables(r, t)
    local fill_g
    if not snap then
        fill = fill or WHITE
        fill_g = gray(fill)
        if r >= 4 then
            -- the grey that `fill` has when read back: the corner pixel is outside the arc
            bb:paintRect(x, y, 1, 1, fill)
            fill_g = gray(bb:getPixel(x, y))
        end
    end
    -- the outline's grey: a pixel of the cover's own frame, on the top side
    local line_g = gray(OUTLINE_COLOR)
    if t > 0 then
        local okp, g = pcall(function() return gray(bb:getPixel(x + math.floor(w / 2), y)) end)
        if okp then line_g = g end
    end
    -- One pixel (i, j) of the top-left corner, mirrored to a corner: bx, by is
    -- where it is on `bb`, `sn`, ki the saved corner and the index in it.
    local function px(i, j, bx, by, sn, ki)
        local k = j * r + i + 1
        local co = cov.out[k]
        local ci = (t > 0) and (cov.inn and cov.inn[k] or 0) or co
        if co >= 1 and ci >= 1 then return end            -- inside the cover
        -- what was outside the arc (only saved where the arc cuts the pixel)
        local out_g = (co < 1) and (sn and sn[ki] or fill_g) or 0
        if co <= 0 then                                   -- outside the arc
            bb:setPixel(bx, by, Blitbuffer.Color8(out_g))
            return
        end
        local in_g = (ci > 0) and gray(bb:getPixel(bx, by)) or 0
        local v = (1 - co) * out_g + (co - ci) * line_g + ci * in_g
        bb:setPixel(bx, by, Blitbuffer.Color8(math.floor(v + 0.5)))
    end
    for j = 0, r - 1 do
        for i = 0, r - 1 do
            px(i, j, x + i, y + j, snap and snap.tl, j * r + i + 1)
            px(i, j, x + w - 1 - i, y + j, snap and snap.tr, j * r + (r - 1 - i) + 1)
            px(i, j, x + i, y + h - 1 - j, snap and snap.bl, (r - 1 - j) * r + i + 1)
            px(i, j, x + w - 1 - i, y + h - 1 - j, snap and snap.br, (r - 1 - j) * r + (r - 1 - i) + 1)
        end
    end
end

-- The same cut with whole pixels: no mixing of greys. The fallback if the
-- smoothing ever fails here.
local function finishHard(bb, x, y, w, h, r, line, snap, fill)
    fill = fill or WHITE
    for j = 0, r - 1 do
        local o = outsideInset(j, r)
        for i = 0, o - 1 do
            local function put(bx, by, sn, ki)
                if sn and sn[ki] then
                    bb:setPixel(bx, by, Blitbuffer.Color8(sn[ki]))
                else
                    bb:paintRect(bx, by, 1, 1, fill)
                end
            end
            put(x + i, y + j, snap and snap.tl, j * r + i + 1)
            put(x + w - 1 - i, y + j, snap and snap.tr, j * r + (r - 1 - i) + 1)
            put(x + i, y + h - 1 - j, snap and snap.bl, (r - 1 - j) * r + i + 1)
            put(x + w - 1 - i, y + h - 1 - j, snap and snap.br, (r - 1 - j) * r + (r - 1 - i) + 1)
        end
    end
    if (line or 0) <= 0 then return end
    -- The outline: what lies between the outer arc (radius r) and an inner
    -- arc (radius r - line) in each row of the corner.
    local t = math.min(line, r - 1)
    local ri = r - t
    for j = 0, r - 1 do
        local o = outsideInset(j, r)
        local inner
        if j < t then
            inner = r                                   -- the straight top/bottom side
        elseif ri >= 2 then
            inner = t + outsideInset(j - t, ri)
        else
            inner = t
        end
        if inner <= o then inner = o + 1 end
        local span = inner - o
        bb:paintRect(x + o, y + j, span, 1, OUTLINE_COLOR)
        bb:paintRect(x + w - inner, y + j, span, 1, OUTLINE_COLOR)
        bb:paintRect(x + o, y + h - 1 - j, span, 1, OUTLINE_COLOR)
        bb:paintRect(x + w - inner, y + h - 1 - j, span, 1, OUTLINE_COLOR)
    end
end

local aa_ok = true

function M.finish(bb, x, y, w, h, r, line, snap, fill)
    r = snap and snap.r or clampRadius(w, h, r)
    if r < 2 then return end
    if aa_ok then
        local ok = pcall(finishCorners, bb, x, y, w, h, r, line, snap, fill)
        if ok then return end
        aa_ok = false  -- the smoothing does not work here: whole pixels from now on
    end
    finishHard(bb, x, y, w, h, r, line, snap, fill)
end

-- A bar lying along the foot of a cover, flush with its sides and bottom edge:
-- straight top, and the two bottom corners cut along the cover's own arc
-- (radius r, smoothed) so the bar looks like part of the cover. `color` over
-- what is on `bb`; the rect is x, y, w, h and h should be at least r.
function M.fillBottomBar(bb, x, y, w, h, r, color)
    r = math.max(0, math.min(r or 0, h, math.floor(w / 2)))
    if r < 2 then
        bb:paintRect(x, y, w, h, color)
        return
    end
    bb:paintRect(x, y, w, h - r, color)
    bb:paintRect(x + r, y + h - r, w - 2 * r, r, color)
    local cov = coverageTables(r, 0).out
    -- the bar's grey as getPixel gives it (night mode inverts it)
    local col_g = gray(color)
    local okp, g = pcall(function()
        return gray(bb:getPixel(x + math.floor(w / 2), (h - r > 0) and y or (y + h - 1)))
    end)
    if okp then col_g = g end
    for j = 0, r - 1 do                  -- j = 0 is the bottom row
        for i = 0, r - 1 do              -- i = 0 is the left / right edge
            local c = cov[j * r + i + 1]
            if c > 0 then
                local py = y + h - 1 - j
                local lx, rx = x + i, x + w - 1 - i
                if c >= 1 then
                    local solid = Blitbuffer.Color8(col_g)
                    bb:setPixel(lx, py, solid)
                    bb:setPixel(rx, py, solid)
                else
                    local function blend(bx)
                        local v = c * col_g + (1 - c) * gray(bb:getPixel(bx, py))
                        bb:setPixel(bx, py, Blitbuffer.Color8(math.floor(v + 0.5)))
                    end
                    blend(lx)
                    blend(rx)
                end
            end
        end
    end
end

-- A cover drawn with its corners rounded. Same size as the cover inside.
local RoundedCover = Widget:extend{ child = nil, line = 0 }

function RoundedCover:getSize()
    return self.child:getSize()
end

function RoundedCover:paintTo(bb, x, y)
    local sz = self.child:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local r = M.radiusFor(sz.w, sz.h)
    local snap = M.snapCorners(bb, x, y, sz.w, sz.h, r)
    self.child:paintTo(bb, x, y)
    M.finish(bb, x, y, sz.w, sz.h, r, self.line, snap)
end

function RoundedCover:free()
    if self.child and self.child.free then self.child:free() end
end

function M.cover(file, w, h, opts)
    local child = KoboldWidgets.makeCover(file, w, h, opts)
    if not M.enabled() then return child end
    return RoundedCover:new{ child = child, line = KoboldWidgets.outlineWidth(opts) }
end

return M
