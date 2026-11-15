-- kobold/ui/home_current.lua — KiKome
-- The "Current book" card: what the top of Home shows instead of the row of
-- recent books when Settings > Home > Top of Home is set to Current book. It
-- takes the same room as that row and shows one book, with the top of Book
-- Details one line shorter:
--
--   [cover]  Series name · 2       (plain text, the secondary font; only when the book has one)
--            Title (one or two lines)
--            Author                (the primary font)
--            [=====----]  42% · Page 120 of 300   (or Finished, On hold, Unread)
--            [(play) 12 minutes left in chapter] (bookmark) (pencil)
--
-- The first pill is as wide as its text. It says how long is left in the
-- chapter (from what the reader kept in the sidecar, see data/chapter_left.lua)
-- and, with no such figure, "Read now"; it opens the book, like the cover. The
-- bookmark opens the annotations and the pencil the Edit screen (both inside
-- Book Details, see home.lua). When the card is too short for everything, the
-- lines go in this order: the series, the second line of the title, the author.
-- The three pills are grey, or on a colour screen a pale shade of the cover's
-- colour (data/cover_color.lua).
--
-- HomeCurrent.build{ ... } returns the widget and the rects (screen
-- coordinates) of the cover and the three pills, for home.lua's taps.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("kobold.i18n")
local CoverBadge      = require("kobold.ui.cover_badge")
local KoboldWidgets   = require("kobold.ui.widgets")
local OptionSheet     = require("kobold.ui.option_sheet")
local Rounded         = require("kobold.ui.rounded")
local CoverColor      = require("kobold.data.cover_color")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local SOFT = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY   -- the grey of Book Details' pills
local LINE = Blitbuffer.COLOR_LIGHT_GRAY                              -- the empty part of the bar

local HomeCurrent = {}

local function U(n) return Screen:scaleBySize(n) end

-- The same small shapes as Book Details (book_details.lua keeps its own copies).
local function block(w, h)
    return CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, HorizontalSpan:new{ width = 0 } }
end

local function pill(w, h, color, child)
    return FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = color,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, child or HorizontalSpan:new{ width = 0 } },
    }
end

-- A thin rounded progress bar: a grey track and a black fill.
local function progressBar(w, h, frac)
    local track = FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = LINE, block(w, h),
    }
    if frac <= 0 then return track end
    local fill_w = math.max(h, math.floor(w * frac))
    local fill = FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = BLACK, block(fill_w, h),
    }
    return OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, track, fill }
end

-- "Page 120 of 300" when the book has been started and its page count is known.
local function pageText(o)
    local frac = tonumber(o.pct) or 0
    if o.pages and o.pages > 0 and frac > 0 and not o.done then
        local page = math.max(1, math.min(o.pages, math.floor(frac * o.pages + 0.5)))
        return string.format(_("Page %d of %d"), page, o.pages)
    end
    return nil
end

-- What stands beside the bar: how far the book is, the page, or its state.
--   42% · Page 120 of 300   Finished   On hold · Page 120 of 300   Unread
local function statusText(o, frac)
    local pct = math.floor(frac * 100 + 0.5)
    local page = pageText(o)
    if o.onhold then
        if page then return _("On hold") .. " · " .. page end
        if pct > 0 then return string.format(_("On hold · %d%%"), pct) end
        return _("On hold")
    end
    if o.done then return _("Finished") end
    if pct > 0 then
        local text = string.format("%d%%", pct)
        return page and (text .. " · " .. page) or text
    end
    return _("Unread")
end

-- The text of the first pill: the time left in the chapter, or "Read now".
local function leftText(o)
    local minutes = tonumber(o.minutes_left)
    if o.done then return _("Read now"), false end
    if not minutes then
        -- a time the reader wrote in a form that could not be read as minutes
        if type(o.left_text) == "string" and o.left_text ~= "" then
            return string.format(_("%s left in chapter"), o.left_text), true
        end
        return _("Read now"), false
    end
    local m = math.floor(minutes + 0.5)
    if m < 1 then return _("<1 minute left in chapter"), true end
    if m == 1 then return _("1 minute left in chapter"), true end
    if m < 60 then return string.format(_("%d minutes left in chapter"), m), true end
    return string.format(_("%d h %d min left in chapter"), math.floor(m / 60), m % 60), true
end

-- Options (o):
--   file                the book
--   x, y, w, h          where the card goes on the screen, and its size
--   title, authors (a list), series, series_index
--   pct (0..1), done, onhold, pages, minutes_left (nil when not known), left_text
--   (the time left as the reader wrote it, used when minutes_left is nil)
function HomeCurrent.build(o)
    local file, W, H = o.file, o.w, o.h
    local gap_h = U(18)   -- cover to text

    -- The cover: as tall as the card, but never more than a third of its width.
    local cover_w = math.min(math.floor(H / 1.5), math.floor(W * 0.34))
    local cover_h = math.floor(cover_w * 1.5)
    local csw, csh = KoboldWidgets.coverBox(file, cover_w, cover_h)
    csw, csh = math.min(csw or cover_w, cover_w), math.min(csh or cover_h, cover_h)
    local cover_off = math.max(0, math.floor((H - cover_h) / 2))
    local text_w = W - cover_w - gap_h

    local frac = o.done and 1 or math.max(0, math.min(1, tonumber(o.pct) or 0))

    local series
    if o.series and o.series ~= "" then
        series = o.series
        if o.series_index then
            local n = tonumber(o.series_index)
            if n and n == math.floor(n) then n = math.floor(n) end
            series = series .. " · " .. tostring(n or o.series_index)
        end
    end
    local authors = (type(o.authors) == "table" and #o.authors > 0) and table.concat(o.authors, ", ") or nil
    local title = o.title or ""

    local title_face = KoboldWidgets.face(20)
    local info_gap = U(4)

    -- The text column for one variant v = { series, title_lines, authors }.
    local function buildInfo(v)
        local col = VerticalGroup:new{ align = "left" }
        if v.series and series then
            -- the series: plain text above the title, in the secondary font
            col[#col + 1] = TextWidget:new{
                text = series, face = KoboldWidgets.secondaryFace(15),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
            }
            col[#col + 1] = VerticalSpan:new{ width = U(4) }
        end
        -- the title, cut to that many lines with "..." at the end
        local probe = TextBoxWidget:new{
            text = "A" .. ("\nA"):rep(v.title_lines - 1), face = title_face, bold = true, width = text_w,
        }
        local max_h = probe:getSize().h
        probe:free()
        local tb = TextBoxWidget:new{ text = title, face = title_face, bold = true, width = text_w }
        if tb:getSize().h > max_h then
            tb:free()
            tb = TextBoxWidget:new{
                text = title, face = title_face, bold = true, width = text_w,
                height = max_h, height_overflow_show_ellipsis = true,
            }
        end
        col[#col + 1] = tb
        if authors and v.authors then
            col[#col + 1] = VerticalSpan:new{ width = info_gap }
            col[#col + 1] = TextWidget:new{
                text = authors, face = KoboldWidgets.face(16),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
            }
        end
        -- the bar with its percentage (or Finished, On hold...) beside it
        local label = TextWidget:new{
            text = statusText(o, frac), face = KoboldWidgets.face(14), bold = true,
            max_width = math.floor(text_w * 0.62),
        }
        local bar_gap = U(12)
        local bar_w = math.max(U(40), text_w - label:getSize().w - bar_gap)
        col[#col + 1] = VerticalSpan:new{ width = U(9) }
        col[#col + 1] = HorizontalGroup:new{
            align = "center",
            progressBar(bar_w, U(8), frac),
            HorizontalSpan:new{ width = bar_gap },
            label,
        }
        return col
    end

    -- The pills: the time left in the chapter, annotations and edit.
    local button_h = U(40)
    local button_gap = U(8)
    local info_btn_gap = U(10)
    local avail = H - button_h - info_btn_gap
    local VARIANTS = {
        { series = true,  title_lines = 2, authors = true },
        { series = false, title_lines = 2, authors = true },
        { series = false, title_lines = 1, authors = true },
        { series = false, title_lines = 1, authors = false },
    }
    local info_col
    for _i, v in ipairs(VARIANTS) do
        if info_col and info_col.free then pcall(function() info_col:free() end) end
        info_col = buildInfo(v)
        if info_col:getSize().h <= avail then break end
    end
    local info_h = info_col:getSize().h

    local round_w = button_h
    -- The first pill is the same colour as the round ones, so the row does not weigh as
    -- much as the chips above it. It is only as wide as its text (icon + label +
    -- padding), never wider than what is left once the two round buttons have
    -- theirs; the round buttons follow right after it.
    local max_read_w = text_w - 2 * (round_w + button_gap)
    local icon_sz = U(18)
    local read_pad = U(14)
    local label_text = leftText(o)
    local read_label = TextWidget:new{
        text = label_text, face = KoboldWidgets.face(17), fgcolor = BLACK,
        max_width = math.max(U(40), max_read_w - 2 * read_pad - icon_sz - U(8)),
    }
    local read_w = math.min(max_read_w, read_label:getSize().w + icon_sz + U(8) + 2 * read_pad)
    -- On a colour screen the three pills take a pale shade of the cover's colour.
    local pill_color = CoverColor.pill(file) or SOFT
    local read_button = pill(read_w, button_h, pill_color, HorizontalGroup:new{
        align = "center",
        OptionSheet.iconWidget("play", icon_sz, BLACK),
        HorizontalSpan:new{ width = U(8) },
        read_label,
    })
    local annot_button = pill(round_w, button_h, pill_color, OptionSheet.iconWidget("bookmark", icon_sz, BLACK))
    local edit_button = pill(round_w, button_h, pill_color, OptionSheet.iconWidget("pencil", icon_sz, BLACK))

    -- The text and the pills are one block, centred on the card.
    local block_h = info_h + info_btn_gap + button_h
    local top_off = math.max(0, math.floor((H - block_h) / 2))
    local right_x = o.x + cover_w + gap_h
    local buttons_y = o.y + top_off + info_h + info_btn_gap
    local hits = {
        cover = Geom:new{ x = o.x, y = o.y + cover_off, w = csw, h = csh },
        read  = Geom:new{ x = right_x, y = buttons_y, w = read_w, h = button_h },
        annot = Geom:new{ x = right_x + read_w + button_gap, y = buttons_y, w = round_w, h = button_h },
        edit  = Geom:new{ x = right_x + read_w + 2 * button_gap + round_w, y = buttons_y, w = round_w, h = button_h },
    }

    local right = VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = top_off },
        info_col,
        VerticalSpan:new{ width = info_btn_gap },
        HorizontalGroup:new{
            read_button,
            HorizontalSpan:new{ width = button_gap },
            annot_button,
            HorizontalSpan:new{ width = button_gap },
            edit_button,
        },
    }
    -- The cover, with the "Opening" pill over it while the book opens.
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = cover_h },
        Rounded.cover(file, cover_w, cover_h),
        CoverBadge.Overlay:new{
            w = cover_w, h = cover_h, rect = { x = 0, y = 0, w = csw, h = csh }, path = file,
        },
    }
    local card = KoboldWidgets.fixed(W, H, HorizontalGroup:new{
        align = "top",
        VerticalGroup:new{ align = "left", VerticalSpan:new{ width = cover_off }, cover },
        HorizontalSpan:new{ width = gap_h },
        right,
    })
    return card, hits
end

return HomeCurrent
