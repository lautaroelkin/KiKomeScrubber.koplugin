-- kobold/ui/rounded.lua — Kobold
-- Rounded corners for covers. The option lives in Settings > Home > Rounded
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
-- How a corner is cut: the four r x r corners of the background are copied
-- BEFORE the cover is painted, and AFTER it only the pixels outside the arc are
-- put back (the shape of the scrubber's _snapCorners/_restoreCorners). So
-- whatever was there shows through the corner (the second book of a stack, a
-- wallpaper) instead of a white square, and no pixel of the cover can stay
-- outside the outline: the same arc cuts the cover and draws the outline.
--
-- The outline's thickness comes from KoboldWidgets.outlineWidth(): 0 when the
-- "cover outline" option is off, and then the corners are cut with no line.

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

-- Copies the four corners of the rect x, y, w, h. Call it before painting.
function M.snapCorners(bb, x, y, w, h, r)
    r = clampRadius(w, h, r)
    if r < 2 then return nil end
    local ok, snap = pcall(function()
        local t = bb:getType()
        local function patch(px, py)
            local pb = Blitbuffer.new(r, r, t)
            pb:blitFrom(bb, 0, 0, px, py, r, r)
            return pb
        end
        return { r = r,
                 tl = patch(x, y), tr = patch(x + w - r, y),
                 bl = patch(x, y + h - r), br = patch(x + w - r, y + h - r) }
    end)
    return ok and snap or nil
end

local function freeSnap(snap)
    if not snap then return end
    for _i, k in ipairs({ "tl", "tr", "bl", "br" }) do
        pcall(function() snap[k]:free() end)
    end
end

-- Cuts the corners of the rect after it was painted: the pixels outside the
-- arc go back to what `snap` saved (or to `fill`, white by default, when
-- there is no snapshot), then the outline is drawn along the same arc.
-- `line` is the outline's thickness, 0 for none. Only the corners are touched:
-- the straight sides are the cover's own frame.
function M.finish(bb, x, y, w, h, r, line, snap, fill)
    r = snap and snap.r or clampRadius(w, h, r)
    if r < 2 then freeSnap(snap); return end
    fill = fill or WHITE
    for j = 0, r - 1 do
        local o = outsideInset(j, r)
        if o > 0 then
            if snap then
                bb:blitFrom(snap.tl, x, y + j, 0, j, o, 1)
                bb:blitFrom(snap.tr, x + w - o, y + j, r - o, j, o, 1)
                bb:blitFrom(snap.bl, x, y + h - 1 - j, 0, r - 1 - j, o, 1)
                bb:blitFrom(snap.br, x + w - o, y + h - 1 - j, r - o, r - 1 - j, o, 1)
            else
                bb:paintRect(x, y + j, o, 1, fill)
                bb:paintRect(x + w - o, y + j, o, 1, fill)
                bb:paintRect(x, y + h - 1 - j, o, 1, fill)
                bb:paintRect(x + w - o, y + h - 1 - j, o, 1, fill)
            end
        end
    end
    freeSnap(snap)
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

-- A cover drawn with its corners rounded. Same size as the cover inside.
local RoundedCover = Widget:extend{ child = nil, line = 0 }

function RoundedCover:getSize()
    return self.child:getSize()
end

function RoundedCover:paintTo(bb, x, y)
    local sz = self.child:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    local snap = M.snapCorners(bb, x, y, sz.w, sz.h, radius())
    self.child:paintTo(bb, x, y)
    M.finish(bb, x, y, sz.w, sz.h, radius(), self.line, snap)
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
