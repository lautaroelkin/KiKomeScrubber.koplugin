-- kobold/ui/metrics.lua — Kobold
-- Sizes shared by every Kobold screen, so they cannot drift apart:
--
--   * statusBar(): where the status bar sits. Home, Library and Settings all
--     take their margin, top edge and height from here, so the bar stays put
--     when you change tab or open Settings.
--   * gridCols(): how many covers fit in a row, from the room the screen has
--     (width and height), so landscape and big screens get more columns.
--   * sizeChanged(): true when the screen was rotated or resized since a
--     screen was built (screens rebuild themselves then, see router.lua).

local Device = require("device")

local Screen = Device.screen

local KoboldMetrics = {}

-- Status bar: one place for every screen. Change these three numbers and the
-- bar moves on all of them at once.
local STATUS_MARGIN = 30   -- left / right / top edge, in dp
local STATUS_HEIGHT = 40

function KoboldMetrics.statusBar()
    local margin = Screen:scaleBySize(STATUS_MARGIN)
    return {
        margin    = margin,                              -- left and right
        top       = margin,                              -- screen edge to the bar
        h         = Screen:scaleBySize(STATUS_HEIGHT),
        content_w = Screen:getWidth() - 2 * margin,
        bottom    = margin + Screen:scaleBySize(STATUS_HEIGHT),   -- where it ends
    }
end

-- Grid columns ---------------------------------------------------------------

local COVER_RATIO = 1.5      -- cover height / width
local TARGET_DP   = 108      -- cover width the grid aims for (4 on a 6" e-reader)
local MIN_DP      = 60       -- never narrower than this
local MIN_COLS    = 3
local MIN_ROWS    = 2        -- the grid always shows at least this many rows

KoboldMetrics.MIN_ROWS = MIN_ROWS

-- Columns that fit in a row of `content_w` px, with `gap_x` between them.
--   avail_h   height the rows have (px)
--   gap_y     space between rows (px)
--   extra_h   height of what sits under each cover (caption, buttons...), px
--   fixed_h   height each row takes besides its cover (shelf board...), px
--   min_rows  rows that must fit (default MIN_ROWS)
-- Covers aim for TARGET_DP wide. When the screen is short (landscape), two
-- rows of those covers would not fit, so the covers get as small as two rows
-- need and more of them fit across. Big screens get more columns because
-- they have more width.
function KoboldMetrics.gridCols(content_w, gap_x, avail_h, gap_y, extra_h, fixed_h, min_rows)
    gap_y, extra_h, fixed_h = gap_y or 0, extra_h or 0, fixed_h or 0
    local rows = math.max(1, min_rows or MIN_ROWS)
    local cover_h = math.floor((avail_h - (rows - 1) * gap_y) / rows) - extra_h - fixed_h
    local fit_w = math.floor(cover_h / COVER_RATIO)
    local w = math.min(Screen:scaleBySize(TARGET_DP), fit_w)
    w = math.max(w, Screen:scaleBySize(MIN_DP))
    local cols = math.floor((content_w + gap_x) / (w + gap_x))
    return math.max(MIN_COLS, cols)
end

-- Fitting a row to covers that came out narrower than planned -----------------
-- The grid first picks a number of columns from a target cover width, but a
-- cover is often smaller than its cell (the rows have to fit the height, so the
-- cover shrinks and the width it frees would only become empty space between
-- the books). fitRow() works the columns out again from the width the covers
-- really have, so more of them fit across, and shares out what is left.
--   content_w  width of the row (px)       base_gap  the smallest gap (px)
--   item_w     width of a cover (px)       min_cols  never fewer than this
-- Returns cols and gap: `cols` covers of `item_w` span the row exactly, `gap`
-- apart (never less than base_gap).
function KoboldMetrics.fitRow(content_w, base_gap, item_w, min_cols)
    item_w = math.max(1, item_w)
    local cols = math.max(min_cols or 1, math.floor((content_w + base_gap) / (item_w + base_gap)))
    local gap = base_gap
    if cols > 1 then
        gap = math.max(base_gap, math.floor((content_w - cols * item_w) / (cols - 1)))
    end
    return cols, gap
end

-- Orientation ----------------------------------------------------------------

function KoboldMetrics.isLandscape()
    return Screen:getWidth() > Screen:getHeight()
end

-- True when the screen is not the size `widget` was built for. `widget.dimen`
-- holds the size it was made with.
function KoboldMetrics.sizeChanged(widget)
    local d = widget and widget.dimen
    if not d then return false end
    return d.w ~= Screen:getWidth() or d.h ~= Screen:getHeight()
end

return KoboldMetrics
