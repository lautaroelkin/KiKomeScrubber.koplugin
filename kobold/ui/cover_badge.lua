-- kobold/ui/cover_badge.lua — Kobold
-- What is drawn on top of a book cover, shared by My Books (Library) and the
-- Home shelves so both look the same:
--   * a badge in the cover's top right corner: the percentage read, as the
--     Kindle shows it (a black ribbon with white text, no outline, its bottom cut to a
--     point), or "Read" in a small black pill once the book is finished;
--   * optionally a "more" button in the bottom right corner (Library only);
--   * while a book opens, an "Opening" pill along the bottom of its cover,
--     in the same black pill style as "Read" (it covers the "more" button);
--   * the same black pill, on its own, for the "Closing" message and under
--     the cover splash (CoverBadge.pill).
--
-- Usage:
--   local CoverBadge = require("kobold.ui.cover_badge")
--   local badge = CoverBadge.make(pct, done)   -- pct: 0..1 or nil, done: boolean
--   local overlay = CoverBadge.Overlay:new{
--       w = cell_w, h = cell_h,
--       rect = { x = 0, y = cell_h - sh, w = sw, h = sh },  -- the cover inside the cell
--       badge = badge,                                      -- may be nil
--       more = icon, more_size = size,                      -- optional
--       path = file,                                        -- for the "Opening" pill
--   }
-- and put `overlay` over the cover in an OverlapGroup.

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local Widget         = require("ui/widget/widget")
local _              = require("gettext")
local KoboldWidgets  = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE

local CoverBadge = {}

-- Distance from the cover's edges to the things drawn on it.
function CoverBadge.inset() return Screen:scaleBySize(5) end

-- ── The ribbon with the percentage ──────────────────────────────────────────
local RibbonBadge = Widget:extend{ text = "", w = 0, h = 0, ribbon = true }

function RibbonBadge:init()
    self.label = TextWidget:new{
        text = self.text, face = KoboldWidgets.face(13), bold = true, fgcolor = WHITE,
    }
    local ts = self.label:getSize()
    self.w = ts.w + 2 * Screen:scaleBySize(8)
    self.body_h = ts.h + 2 * Screen:scaleBySize(4)
    self.point = math.floor(self.w * 0.28)
    self.h = self.body_h + self.point
end

function RibbonBadge:getSize() return Geom:new{ w = self.w, h = self.h } end

-- Width of the point `i` rows below the body.
function RibbonBadge:pointWidth(i)
    return math.max(1, math.floor(self.w * (1 - i / self.point)))
end

function RibbonBadge:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    -- The ribbon.
    bb:paintRect(x, y, self.w, self.body_h, BLACK)
    for i = 0, self.point - 1 do
        local wi = self:pointWidth(i)
        bb:paintRect(x + math.floor((self.w - wi) / 2), y + self.body_h + i, wi, 1, BLACK)
    end
    local ts = self.label:getSize()
    self.label:paintTo(bb, x + math.floor((self.w - ts.w) / 2), y + math.floor((self.body_h - ts.h) / 2))
end

function RibbonBadge:free()
    if self.label then self.label:free() end
end

-- The badge for a book: the ribbon with the percentage read, or the "Read"
-- pill when finished. nil for a book not started.
function CoverBadge.make(pct, done)
    if done then
        return FrameContainer:new{
            bordersize = 0,
            margin = 0, radius = Screen:scaleBySize(5),
            background = BLACK, padding = 0,
            padding_left = Screen:scaleBySize(6), padding_right = Screen:scaleBySize(6),
            padding_top = Screen:scaleBySize(1), padding_bottom = Screen:scaleBySize(1),
            TextWidget:new{ text = _("Read"), face = KoboldWidgets.face(12), fgcolor = WHITE },
        }
    elseif pct and pct > 0 then
        return RibbonBadge:new{ text = math.max(1, math.floor(pct * 100)) .. "%" }
    end
    return nil
end

-- ── The layer over one cover ────────────────────────────────────────────────
-- `rect` is the cover inside the cell (x, y, w, h): covers keep their shape,
-- so it can be smaller than the cell.
CoverBadge.Overlay = Widget:extend{
    w = 0, h = 0, rect = nil, badge = nil, more = nil, more_size = 0,
    path = nil,  -- the book's file; used to show the "Opening" pill
}

-- ── The pill ────────────────────────────────────────────────────────────────
-- A black pill with white bold text: "Opening" on a cover, "Closing" while a
-- book closes. Not narrower than `min_w`; its text shrinks, down to a small
-- size, until it fits `max_w`.
local Pill = Widget:extend{ label = nil, w = 0, h = 0 }

function Pill:getSize() return Geom:new{ w = self.w, h = self.h } end

function Pill:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    bb:paintRoundedRect(x, y, self.w, self.h, BLACK, Screen:scaleBySize(5))
    local ts = self.label:getSize()
    self.label:paintTo(bb, x + math.floor((self.w - ts.w) / 2), y + math.floor((self.h - ts.h) / 2))
end

function Pill:free()
    if self.label then self.label:free() end
end

function CoverBadge.pill(text, min_w, max_w, start_size)
    local padx, pady = Screen:scaleBySize(8), Screen:scaleBySize(3)
    local label
    for size = start_size or 13, 9, -1 do
        if label then label:free() end
        label = TextWidget:new{
            text = text, face = KoboldWidgets.face(size), bold = true, fgcolor = WHITE,
        }
        if not max_w or label:getSize().w + 2 * padx <= max_w then break end
    end
    local ts = label:getSize()
    return Pill:new{
        label = label,
        w = math.max(ts.w + 2 * padx, min_w or 0),
        h = ts.h + 2 * pady,
    }
end

-- ── Which book is opening ───────────────────────────────────────────────────
-- The book being opened (its file), or nil. Every overlay of that book draws
-- the pill the next time it is painted. `seen` remembers the overlays that
-- have been painted (weakly, so closed screens do not stay alive) and in
-- which order, to find the one on screen.
local opening_path = nil
local opening_target = nil  -- the one overlay that draws the pill
local seen, paint_count = setmetatable({}, { __mode = "k" }), 0

-- Marks `path` as opening and paints it at once, before KOReader starts the
-- slow part of opening the book. `screen` is the window that holds the cover.
-- When the same book is on screen more than once (the top row and the list
-- under it), only the cover that was tapped gets the pill: the one nearest to
-- `pos`, the tap point. Without `pos`, the one painted last.
function CoverBadge.setOpening(path, screen, pos)
    opening_path = path
    opening_target = nil
    if not path then return end
    local best
    for ov, serial in pairs(seen) do
        if ov.path == path and ov.dimen then
            local d = ov.dimen
            local dist = 0
            if pos then
                local dx = math.max(d.x - pos.x, 0, pos.x - (d.x + d.w))
                local dy = math.max(d.y - pos.y, 0, pos.y - (d.y + d.h))
                dist = dx * dx + dy * dy
            end
            if not best or dist < best.dist or (dist == best.dist and serial > best.serial) then
                best = { ov = ov, dist = dist, serial = serial }
            end
        end
    end
    if best then
        opening_target = best.ov
        UIManager:setDirty(screen or "all", "ui", best.ov.dimen)
        UIManager:forceRePaint()
    end
end

-- Takes the pill away. With `refresh`, the cover is repainted too (use it
-- when the screen is still visible, for example when the book failed to open).
function CoverBadge.clearOpening(screen, refresh)
    local target = opening_target
    opening_path, opening_target = nil, nil
    if refresh and target and target.dimen then
        UIManager:setDirty(screen or "all", "ui", target.dimen)
    end
end

-- The "Opening" pill along the bottom of the cover, as wide as the cover
-- (less the inset); on a small cover the text gets smaller to fit.
function CoverBadge.Overlay:paintOpening(bb, x, y)
    local r, inset = self.rect, CoverBadge.inset()
    if not self.opening_pill then
        local avail = r.w - 2 * inset
        self.opening_pill = CoverBadge.pill(_("Opening"), avail, avail, 13)
    end
    local ps = self.opening_pill:getSize()
    self.opening_pill:paintTo(bb,
        x + r.x + math.floor((r.w - ps.w) / 2),
        y + r.y + r.h - ps.h - inset)
end

function CoverBadge.Overlay:getSize() return Geom:new{ w = self.w, h = self.h } end

function CoverBadge.Overlay:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    local r, inset = self.rect, CoverBadge.inset()
    if self.badge then
        local bs = self.badge:getSize()
        local bx, by
        if self.badge.ribbon then
            -- hangs just under the cover's grey outline, a little in from the right
            bx, by = r.x + r.w - bs.w - Screen:scaleBySize(8), r.y + KoboldWidgets.outlineWidth()
        else
            bx, by = r.x + r.w - bs.w - inset, r.y + inset
        end
        self.badge:paintTo(bb, x + bx, y + by)
    end
    paint_count = paint_count + 1
    seen[self] = paint_count
    if opening_target and self == opening_target then
        -- the pill takes the place of the "more" button
        self:paintOpening(bb, x, y)
        return
    end
    if self.more then
        local s = self.more_size
        self.more:paintTo(bb, x + r.x + r.w - s - inset, y + r.y + r.h - s - inset)
    end
end

function CoverBadge.Overlay:free()
    if self.badge and self.badge.free then self.badge:free() end
    if self.opening_pill then self.opening_pill:free() end
    seen[self] = nil
end

return CoverBadge
