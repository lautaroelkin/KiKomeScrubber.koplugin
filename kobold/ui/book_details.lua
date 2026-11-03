-- kobold/ui/book_details.lua — Kobold
-- Kobold's book details page (View Details in the book menu): a rounded
-- sheet with the cover, title, series, author, a progress bar, a Read now
-- pill and, beside it, two round buttons: Annotations (a bookmark: the list of
-- the book's bookmarks, highlights and notes, see below) and Edit (a pencil:
-- it swaps the sheet's content for the Edit screen: rating, review, status and
-- the book's actions); then a row of facts (pages, language, format, size) and
-- a Synopsis / Details switch. The data comes from KOReader (its book info,
-- with any corrections made in Book information).
--
-- Look: soft grey surfaces with big rounded corners, one black pill for the
-- main action, white pills for values, hairlines instead of boxes, small grey
-- captions. Every measure goes through U() so it scales with the screen.
-- The sheet keeps the same size on both tabs: only the part under the
-- Synopsis / Details switch changes.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local Annotations     = require("kobold.data.annotations")
local KoboldLibrary   = require("kobold.data.library")
local KoboldMyBooksData = require("kobold.data.mybooks")
local KoboldPopup     = require("kobold.ui.popup")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local OptionSheet     = require("kobold.ui.option_sheet")
local Rounded         = require("kobold.ui.rounded")
local CoverBadge      = require("kobold.ui.cover_badge")
local Review          = require("kobold.data.review")
local Metadata        = require("kobold.data.metadata")
local Toast           = require("kobold.ui.toast")
local Keyboard        = require("kobold.ui.keyboard")
local FileActions     = require("kobold.ui.file_actions")
local ListPicker      = require("kobold.ui.list_picker")
local FDButtons       = require("kobold.data.file_dialog_buttons")
local logger          = require("logger")

local Screen = Device.screen

local BLACK = Blitbuffer.COLOR_BLACK
local WHITE = Blitbuffer.COLOR_WHITE
-- The soft grey of tiles, chips and buttons (a little lighter than the
-- light grey where the device has it), and the grey of lines and tracks.
local SOFT = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY
local LINE = Blitbuffer.COLOR_LIGHT_GRAY

local function U(n) return Screen:scaleBySize(n) end

local KoboldBookDetails = InputContainer:extend{
    name = "kobold_book_details",
    file = nil,
    screen = nil,    -- the Kobold screen it opened from
    on_change = nil, -- runs when the page closes, if Edit changed something
    hide_koreader = false, -- not used any more (Edit took the place of the "..." button); callers may still pass it
    view = "details", -- "details", "edit", "metadata" or "editor": the same sheet with another screen in it
    tab = "synopsis",
}

local function italicFace(size)
    local ok, face = pcall(function() return KoboldWidgets.italicFace(size) end)
    if ok and face then return face end
    return KoboldWidgets.face(size)
end

local function nonEmpty(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

-- Book facts from KOReader's book info (title, authors, series, language,
-- keywords, description, pages), with corrections from Book information.
-- The book is not opened for this.
local function bookProps(file)
    local props = {}
    -- The file browser has it; with a book parked under KiKome the reader does
    -- (and the file browser is not built just for this).
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local bookinfo = (FileManager and FileManager.instance and FileManager.instance.bookinfo)
        or (ReaderUI and ReaderUI.instance and ReaderUI.instance.bookinfo)
    if bookinfo and bookinfo.getDocProps then
        local ok, p = pcall(bookinfo.getDocProps, bookinfo, file, nil, true)
        if ok and type(p) == "table" then props = p end
        local ok_x, extended = pcall(function() return bookinfo.extendProps(props, file) end)
        if ok_x and type(extended) == "table" then props = extended end
    end
    -- Fall back to the sidecar for anything missing.
    local info = KoboldLibrary.getDocInfoCached(file) or {}
    props.title = nonEmpty(props.title) or nonEmpty(props.display_title) or info.title
    props.authors = nonEmpty(props.authors) or info.authors
    props.series = nonEmpty(props.series) or info.series
    props.series_index = props.series_index or info.series_index
    props.pages = props.pages or info.pages
    return props, info
end

-- Description without HTML, as KOReader shows it.
local function plainText(s)
    s = nonEmpty(s)
    if not s then return nil end
    local ok, util = pcall(require, "util")
    if ok and util.htmlToPlainTextIfHtml then
        local ok2, out = pcall(util.htmlToPlainTextIfHtml, s)
        if ok2 and out then return nonEmpty(out) end
    end
    return nonEmpty((s:gsub("<[^>]+>", "")))
end

local function statusLine(info)
    if info.status == "abandoned" then
        -- On hold keeps showing how far the book got (the bar too, see fraction).
        if info.percent and info.percent > 0 then
            return string.format(_("On hold · %d%%"), math.floor(info.percent * 100 + 0.5))
        end
        return _("On hold")
    end
    if info.status == "complete" then return _("Finished") end
    if info.percent and info.percent > 0 then
        return string.format(_("%d%% read"), math.floor(info.percent * 100 + 0.5))
    end
    return _("Unread")
end

-- How far through the book, 0 to 1.
local function fraction(info)
    if info.status == "complete" then return 1 end
    return math.max(0, math.min(1, info.percent or 0))
end

-- ── Small building blocks ──────────────────────────────────────────────────

-- An empty w x h box: a FrameContainer around it paints a plain rounded shape.
local function block(w, h)
    return CenterContainer:new{
        dimen = Geom:new{ w = w, h = h },
        HorizontalSpan:new{ width = 0 },
    }
end

-- A w x h box with rounded corners (radius r), `child` centred in it.
local function roundBox(w, h, r, color, child)
    return FrameContainer:new{
        bordersize = 0, padding = 0, radius = r, background = color,
        CenterContainer:new{ dimen = Geom:new{ w = w, h = h }, child or HorizontalSpan:new{ width = 0 } },
    }
end

-- A pill: the corners are half the height.
local function pill(w, h, color, child)
    return roundBox(w, h, math.floor(h / 2), color, child)
end

-- A thin rounded progress bar: a grey track and a black fill.
local function progressBar(w, h, frac)
    local track = FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = LINE,
        block(w, h),
    }
    if frac <= 0 then return track end
    local fill_w = math.max(h, math.floor(w * frac))
    local fill = FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = BLACK,
        block(fill_w, h),
    }
    return OverlapGroup:new{ dimen = Geom:new{ w = w, h = h }, track, fill }
end

-- How tight the sheet is drawn. Level 1 is the roomy look; on a short screen
-- (the Kindle) build() goes down to levels 2 and 3 until everything fits: the
-- facts, and every row of Details. Values go through U().
local LEVELS = {
    { pad = 22, gap = 18, top = 44, tile = 70, seg = 38, button = 52, cover = 0.32, info_gap = 10,
      card_pad = 14, row_pad = 9, pill_py = 7, pill_px = 14, chip_h = 32, chip_gap = 8, font = 14,
      bar = 46, row = 44 },
    { pad = 18, gap = 12, top = 38, tile = 60, seg = 34, button = 46, cover = 0.27, info_gap = 7,
      card_pad = 10, row_pad = 6, pill_py = 5, pill_px = 12, chip_h = 28, chip_gap = 6, font = 13,
      bar = 42, row = 40 },
    { pad = 14, gap = 8, top = 32, tile = 52, seg = 30, button = 42, cover = 0.22, info_gap = 5,
      card_pad = 8, row_pad = 4, pill_py = 3, pill_px = 10, chip_h = 24, chip_gap = 5, font = 12,
      bar = 38, row = 36 },
}

-- Keywords as small white pills that wrap onto several lines.
local function chipRows(words, max_w, M)
    local face = KoboldWidgets.face(M.font)
    local gap, chip_h, pad_x = U(M.chip_gap), U(M.chip_h), U(M.pill_px)
    local rows = VerticalGroup:new{ align = "left" }
    local line = HorizontalGroup:new{}
    local used = 0
    local function flush()
        if used > 0 then
            rows[#rows + 1] = line
            rows[#rows + 1] = VerticalSpan:new{ width = gap }
            line = HorizontalGroup:new{}
            used = 0
        end
    end
    for i, word in ipairs(words) do
        if i > 12 then break end
        local label = TextWidget:new{ text = word, face = face, max_width = max_w - 2 * pad_x }
        local chip_w = label:getSize().w + 2 * pad_x
        if used > 0 and used + gap + chip_w > max_w then flush() end
        if used > 0 then
            line[#line + 1] = HorizontalSpan:new{ width = gap }
            used = used + gap
        end
        line[#line + 1] = pill(chip_w, chip_h, WHITE, label)
        used = used + chip_w
    end
    flush()
    if #rows > 0 then table.remove(rows) end  -- the gap after the last line
    return rows
end

-- A value as a white pill (Added, File name, Path). One line: a pill as wide
-- as the text. Too long for one line: the text wraps inside a rounded box as
-- wide as max_w.
local function valuePill(text, max_w, M)
    local face = KoboldWidgets.face(M.font)
    local pad_x, pad_y = U(M.pill_px), U(M.pill_py)
    local avail = max_w - 2 * pad_x
    local one = TextWidget:new{ text = text, face = face }
    local one_size = one:getSize()
    if one_size.w <= avail then
        return pill(one_size.w + 2 * pad_x, one_size.h + 2 * pad_y, WHITE, one)
    end
    pcall(function() one:free() end)
    local many = TextBoxWidget:new{ text = text, face = face, width = avail }
    local h = many:getSize().h + 2 * pad_y
    return roundBox(max_w, h, math.min(math.floor(h / 2), U(18)), WHITE,
        LeftContainer:new{ dimen = Geom:new{ w = avail, h = many:getSize().h }, many })
end

-- The Details tab: a rounded grey card of "caption  value" rows with
-- hairlines between them. Rows that do not fit in max_h are left out (the
-- least important ones come last).
local function detailsCard(rows, w, max_h, M)
    local card_pad = U(M.card_pad)
    local row_pad = U(M.row_pad)
    local label_w = math.floor(w * 0.26)
    local value_w = w - 2 * card_pad - label_w - U(10)
    local list = VerticalGroup:new{ align = "left" }
    local used = 2 * card_pad
    local first = true
    for _i, row in ipairs(rows) do
        local value
        if row.chips then
            value = chipRows(row.chips, value_w, M)
        else
            value = valuePill(row.value, value_w, M)
        end
        local label = TextWidget:new{
            text = row.label, face = KoboldWidgets.face(M.font - 1),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = label_w,
        }
        local row_h = math.max(value:getSize().h, label:getSize().h) + 2 * row_pad
        local line_h = first and 0 or U(1)
        if not first and used + line_h + row_h > max_h then
            pcall(function() value:free() end)
            break
        end
        if not first then
            list[#list + 1] = LineWidget:new{
                dimen = Geom:new{ w = w - 2 * card_pad, h = line_h }, background = LINE,
            }
        end
        list[#list + 1] = VerticalSpan:new{ width = row_pad }
        list[#list + 1] = HorizontalGroup:new{
            align = "top",
            LeftContainer:new{ dimen = Geom:new{ w = label_w, h = label:getSize().h }, label },
            HorizontalSpan:new{ width = U(10) },
            value,
        }
        list[#list + 1] = VerticalSpan:new{ width = row_pad }
        used = used + line_h + row_h
        first = false
    end
    return FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        list,
    }
end

-- Keywords split into words (one per line, or separated by , or ;).
local function splitKeywords(s)
    local words = {}
    s = nonEmpty(s)
    if not s then return words end
    for part in s:gmatch("[^\n,;]+") do
        part = nonEmpty(part)
        if part then words[#words + 1] = part end
    end
    return words
end

function KoboldBookDetails:buildDetails(level)
    level = level or 1
    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    local gap_h   = U(20)   -- between the cover and the text
    self.panel_rect = R

    local file = self.file
    local props, info = bookProps(file)
    local title = props.title or (file:match("([^/]+)$") or file)

    -- Top bar: a round close button on the right and, on the left, the book's
    -- series as a grey pill when it has one (it takes the place of the title
    -- "Book Details", which makes room), otherwise "Book Details".
    local close_d = U(36)
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local bar_max_w = inner_w - close_d - U(16)
    local top_left
    if props.series then
        local series = props.series:upper()
        if props.series_index then
            local n = tonumber(props.series_index)
            if n and n == math.floor(n) then n = math.floor(n) end
            series = series .. "  ·  " .. tostring(n or props.series_index)
        end
        local pad_x = U(14)
        local label = TextWidget:new{
            text = series, face = KoboldWidgets.face(14), max_width = bar_max_w - 2 * pad_x,
        }
        top_left = pill(label:getSize().w + 2 * pad_x, U(32), SOFT, label)
    else
        top_left = TextWidget:new{
            text = _("Book Details"), face = KoboldWidgets.face(19), bold = true,
            max_width = bar_max_w,
        }
    end
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, close_button },
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- Header: the cover (rounded) on the left; on the right the title, the
    -- author, the progress bar, and the buttons at the bottom, lined up with
    -- the foot of the cover (never lower than it).
    local cover_w = math.floor(inner_w * M.cover)
    local cover_h = math.floor(cover_w * 1.5)
    local text_w  = inner_w - cover_w - gap_h
    -- The cover as it really is: it keeps its shape, so it can be smaller
    -- than its box.
    local csw, csh = KoboldWidgets.coverBox(file, cover_w, cover_h)
    csw, csh = math.min(csw or cover_w, cover_w), math.min(csh or cover_h, cover_h)

    -- Progress: a bar, then "42% read" (or "On hold") on the left and the
    -- pages on the right.
    local frac = fraction(info)
    local label_h = TextWidget:new{ text = "0", face = KoboldWidgets.face(14) }:getSize().h
    local progress_note
    if props.pages and frac > 0 and frac < 1 then
        progress_note = string.format(_("%d of %d pages"), math.floor(frac * props.pages + 0.5), props.pages)
    end

    -- The text column for one variant v = { title_lines, authors, bar, note }.
    local title_face = KoboldWidgets.face(24)
    local function buildInfo(v)
        local col = VerticalGroup:new{ align = "left" }
        if v.title_lines then
            -- the title cut to that many lines, ending in "..."
            local probe = TextBoxWidget:new{
                text = "A" .. ("\nA"):rep(v.title_lines - 1), face = title_face, bold = true, width = text_w,
            }
            local h = probe:getSize().h
            probe:free()
            col[#col + 1] = TextBoxWidget:new{
                text = title, face = title_face, bold = true, width = text_w,
                height = h, height_overflow_show_ellipsis = true,
            }
        else
            col[#col + 1] = TextBoxWidget:new{ text = title, face = title_face, bold = true, width = text_w }
        end
        if props.authors and v.authors then
            col[#col + 1] = VerticalSpan:new{ width = U(M.info_gap) }
            col[#col + 1] = TextWidget:new{
                text = (props.authors:gsub("\n", ", ")), face = KoboldWidgets.face(17),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
            }
        end
        if v.bar then
            col[#col + 1] = VerticalSpan:new{ width = U(M.info_gap + 6) }
            col[#col + 1] = progressBar(text_w, U(8), frac)
            if v.note then
                col[#col + 1] = VerticalSpan:new{ width = U(8) }
                local note_row = OverlapGroup:new{
                    dimen = Geom:new{ w = text_w, h = label_h },
                    TextWidget:new{ text = statusLine(info), face = KoboldWidgets.face(14), bold = true },
                }
                if progress_note then
                    note_row[#note_row + 1] = RightContainer:new{
                        dimen = Geom:new{ w = text_w, h = label_h },
                        TextWidget:new{
                            text = progress_note, face = KoboldWidgets.face(13),
                            fgcolor = KoboldWidgets.subtitleColor(), max_width = math.floor(text_w * 0.6),
                        },
                    }
                end
                col[#col + 1] = note_row
            end
        end
        return col
    end

    local button_h = U(M.button)
    local button_gap = U(10)
    -- Read now must not go below the foot of the cover: when the text above
    -- it is too tall, it loses what does not fit, a step at a time (title
    -- lines first, then the note, the bar and, last, the author).
    local info_btn_gap = U(M.info_gap + 8)   -- between the text and the buttons
    local avail = csh - button_h - info_btn_gap
    local VARIANTS = {
        { authors = true, bar = true, note = true },
        { title_lines = 3, authors = true, bar = true, note = true },
        { title_lines = 2, authors = true, bar = true, note = true },
        { title_lines = 2, authors = true, bar = true },
        { title_lines = 1, authors = true, bar = true },
        { title_lines = 1, authors = true },
        { title_lines = 1 },
    }
    local info_col
    for _i, v in ipairs(VARIANTS) do
        info_col = buildInfo(v)
        if info_col:getSize().h <= avail then break end
    end
    -- Read now, and beside it two round buttons with only an icon: Annotations
    -- (a bookmark) and Edit (a pencil).
    local round_w = button_h
    local read_w = text_w - 2 * (round_w + button_gap)
    local info_h = info_col:getSize().h
    local header_h = cover_h

    -- Read now: a black pill with white text. Round "..." beside it.
    local icon_sz = U(20)
    local read_label = TextWidget:new{ text = _("Read now"), face = italicFace(19), fgcolor = WHITE }
    local read_content = HorizontalGroup:new{
        align = "center",
        KoboldWidgets.inverted(OptionSheet.iconWidget("play", icon_sz, BLACK)),
        HorizontalSpan:new{ width = U(10) },
        read_label,
    }
    local read_button = pill(read_w, button_h, BLACK, read_content)
    local annot_button = pill(round_w, button_h, SOFT, OptionSheet.iconWidget("bookmark", icon_sz, BLACK))
    local edit_button = pill(round_w, button_h, SOFT, OptionSheet.iconWidget("pencil", icon_sz, BLACK))
    local header_y = y0 + top_h + gap
    -- the text and the buttons form one block, centred on the cover
    local block_h = info_h + info_btn_gap + button_h
    local top_off = math.max(0, math.floor((csh - block_h) / 2))
    local buttons_y = header_y + top_off + info_h + info_btn_gap
    local right_x = x0 + cover_w + gap_h
    self.read_rect = Geom:new{ x = right_x, y = buttons_y, w = read_w, h = button_h }
    self.annot_rect = Geom:new{
        x = right_x + read_w + button_gap, y = buttons_y, w = round_w, h = button_h,
    }
    self.edit_rect = Geom:new{
        x = right_x + read_w + 2 * button_gap + round_w, y = buttons_y, w = round_w, h = button_h,
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
    -- Tapping the cover shows it large (see cover_splash.lua).
    self.cover_rect = Geom:new{ x = x0, y = header_y, w = csw, h = csh }
    local cover = OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = cover_h },
        Rounded.cover(file, cover_w, cover_h),
        CoverBadge.Overlay:new{
            w = cover_w, h = cover_h, rect = { x = 0, y = 0, w = csw, h = csh }, path = file,
        },
    }
    local header = KoboldWidgets.fixed(inner_w, header_h, HorizontalGroup:new{
        align = "top",
        cover,
        HorizontalSpan:new{ width = gap_h },
        right,
    })

    -- Facts: pages, language, format and size as rounded tiles.
    local facts = {}
    if props.pages then facts[#facts + 1] = { value = tostring(props.pages), label = _("Pages") } end
    local lang = nonEmpty(props.language)
    if lang then facts[#facts + 1] = { value = (lang:match("^(%a+)") or lang):upper(), label = _("Language") } end
    local format = (file:match("%.([^%./]+)$") or ""):upper()
    if format ~= "" then facts[#facts + 1] = { value = format, label = _("Format") } end
    local size = KoboldMyBooksData.formatSize(lfs.attributes(file, "size"))
    if size then facts[#facts + 1] = { value = size, label = _("Size") } end

    local tile_h = U(M.tile)
    local tile_gap = U(10)
    local seg_h, seg_pad = U(M.seg), U(3)
    local seg_total = seg_h + 2 * seg_pad
    -- The facts are always there; a short screen tightens the spacing instead.
    local show_tiles = #facts > 0
    local body_h = math.max(U(60), inner_h - top_h - gap - header_h - gap
        - (show_tiles and (tile_h + gap) or 0) - seg_total - gap)

    -- The rows of Details, all of them. If they do not fit this tight a level
    -- allows, draw the whole sheet again one level tighter.
    local rows = {}
    local words = splitKeywords(props.keywords)
    if #words > 0 then rows[#rows + 1] = { label = _("Keywords"), chips = words } end
    local added = lfs.attributes(file, "modification")
    if added then rows[#rows + 1] = { label = _("Added"), value = os.date("%d %b %Y", added) } end
    rows[#rows + 1] = { label = _("File name"), value = file:match("([^/]+)$") or file }
    local dir = file:match("^(.*)/[^/]+$")
    if dir then rows[#rows + 1] = { label = _("Path"), value = dir } end
    local full_card = detailsCard(rows, inner_w, math.huge, M)
    local full_h = full_card:getSize().h
    if full_h > body_h and level < #LEVELS then
        pcall(function() full_card:free() end)
        return self:buildDetails(level + 1)
    end

    local tiles
    if show_tiles then
        tiles = HorizontalGroup:new{}
        local tile_w = math.floor((inner_w - (#facts - 1) * tile_gap) / #facts)
        for i, f in ipairs(facts) do
            if i > 1 then tiles[#tiles + 1] = HorizontalSpan:new{ width = tile_gap } end
            tiles[#tiles + 1] = roundBox(tile_w, tile_h, U(16), SOFT, VerticalGroup:new{
                align = "center",
                TextWidget:new{
                    text = f.value, face = KoboldWidgets.face(19), bold = true,
                    max_width = tile_w - U(12),
                },
                VerticalSpan:new{ width = U(2) },
                TextWidget:new{
                    text = f.label, face = KoboldWidgets.face(12),
                    fgcolor = KoboldWidgets.subtitleColor(), max_width = tile_w - U(12),
                },
            })
        end
    end

    -- Synopsis / Details as a segmented control: a grey pill track with the
    -- chosen segment in black.
    local seg_y = header_y + header_h + gap + (show_tiles and (tile_h + gap) or 0)
    local seg_w = math.floor((inner_w - 2 * seg_pad) / 2)
    local segments = HorizontalGroup:new{}
    self.tab_rects = {}
    for i, t in ipairs({ { id = "synopsis", text = _("Synopsis") }, { id = "details", text = _("Details") } }) do
        local selected = t.id == self.tab
        segments[#segments + 1] = pill(seg_w, seg_h, selected and BLACK or SOFT, TextWidget:new{
            text = t.text, face = KoboldWidgets.face(16), bold = selected,
            fgcolor = selected and WHITE or BLACK,
        })
        self.tab_rects[t.id] = Geom:new{
            x = x0 + seg_pad + (i - 1) * seg_w, y = seg_y + seg_pad, w = seg_w, h = seg_h,
        }
    end
    local tabs = FrameContainer:new{
        bordersize = 0, padding = seg_pad, radius = math.floor(seg_total / 2), background = SOFT,
        segments,
    }

    -- Tab content fills the rest of the sheet.
    local body
    if self.tab == "synopsis" then
        body = ScrollTextWidget:new{
            text = plainText(props.description) or _("No synopsis."), face = KoboldWidgets.face(16),
            width = inner_w, height = body_h, dialog = self,
        }
        pcall(function() full_card:free() end)
    else
        -- the whole card when it fits (it does, unless even the tightest level
        -- is too tall: then the last rows are left out)
        local card = full_h <= body_h and full_card or detailsCard(rows, inner_w, body_h, M)
        -- Same height as the synopsis, so the sheet is the same size on both tabs.
        body = VerticalGroup:new{
            align = "left",
            card,
            VerticalSpan:new{ width = math.max(0, body_h - card:getSize().h) },
        }
    end

    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = gap },
        header,
        VerticalSpan:new{ width = gap },
    }
    if tiles then
        column[#column + 1] = tiles
        column[#column + 1] = VerticalSpan:new{ width = gap }
    end
    column[#column + 1] = tabs
    column[#column + 1] = VerticalSpan:new{ width = gap }
    column[#column + 1] = body

    local panel = FrameContainer:new{
        bordersize = border, padding = pad,
        radius = radius,
        background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

-- ── The Edit screen ────────────────────────────────────────────────────────
-- The same sheet (same size, same outline) with other content: a title bar
-- with a back button, then one bar with Favorites (the star on the left), the
-- review (the middle) and the star rating (the five stars on the right);
-- under it the reading status, a card of rows (Metadata, Collections, Book
-- settings) and, apart from it, a row of four buttons for the book's file:
-- Rename, Copy, Cut and Delete. Rating, status and Favorites save as they are tapped
-- (see kobold/data/review.lua). The review bar opens the review screen
-- (below), and the Metadata row opens the metadata screen; the other rows are
-- still to come: they only say so for now.

local STAR_OFF, STAR_ON = "img-folder-fav", "img-folder-fav-filled"

-- The favorite mark of the review bar is like.svg, filled when it is on. The
-- filled one is like-filled.svg: if the icons folder has it, that is used;
-- if not, it is made once from like.svg (the same shape with a black fill).
local LIKE_OFF, LIKE_ON = "like", "like-filled"
local like_checked = false
local function ensureLikeFilled()
    if like_checked then return end
    like_checked = true
    local ok_meta, meta = pcall(require, "kobold.meta")
    local dir = ok_meta and meta and meta.DIR
    if not dir then return end
    local subs = { "/icons/", "/kobold/icons/", "/icons/toolbar/" }
    for _i, sub in ipairs(subs) do
        if lfs.attributes(dir .. sub .. LIKE_ON .. ".svg", "mode") == "file" then return end
    end
    for _i, sub in ipairs(subs) do
        local src = dir .. sub .. LIKE_OFF .. ".svg"
        if lfs.attributes(src, "mode") == "file" then
            pcall(function()
                local f = io.open(src, "rb")
                if not f then return end
                local text = f:read("*a")
                f:close()
                local filled, n = text:gsub('(<svg[^>]-)fill="none"', '%1fill="black"', 1)
                if n == 0 then filled = (text:gsub("<svg", '<svg fill="black"', 1)) end
                local out = io.open(dir .. sub .. LIKE_ON .. ".svg", "wb")
                if out then
                    out:write(filled)
                    out:close()
                end
            end)
            return
        end
    end
end

local STATUSES = {
    { id = "reading",  text = _("Reading") },
    { id = "onhold",   text = _("On hold") },
    { id = "finished", text = _("Finished") },
}

local EDIT_ROWS = {
    { id = "metadata",    icon = "notepad-text", text = _("Metadata") },
    { id = "collections", icon = "book-marked",  text = _("Collections") },
    { id = "settings",    icon = "settings-2",   text = _("Book settings") },
}

-- Book settings: what is done to the book's data, as rows of a card.
local SETTINGS_ROWS = {
    { id = "reset",   icon = "undo",                      text = _("Reset this document") },
    { id = "export",  icon = "2square-arrow-right-enter", text = _("Export notes of the document (.md)") },
    { id = "refresh", icon = "refresh-cw",                text = _("Refresh metadata") },
}

-- The book's file: its own row of buttons under the card of rows.
local FILE_ACTIONS = {
    { id = "rename", icon = "square-arrow-right-enter", text = _("Rename") },
    { id = "copy",   icon = "copy",                     text = _("Copy") },
    { id = "cut",    icon = "scissors",                 text = _("Cut") },
    { id = "delete", icon = "trash-2",                  text = _("Delete") },
}

function KoboldBookDetails:buildEdit(level)
    level = level or 1
    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    self.panel_rect = R

    local file = self.file
    local props = bookProps(file)
    if not self.rv then self.rv = Review.get(file) end
    local rv = self.rv
    local title = props.title or (file:match("([^/]+)$") or file)

    -- Every height is worked out first, so a short screen can go down a
    -- level before anything big is built.
    local sub_gap   = U(M.info_gap)
    local bar_h     = U(M.bar)
    local seg_h, seg_pad = U(M.seg), U(3)
    local seg_total = seg_h + 2 * seg_pad
    local row_h     = U(M.row)
    local line_h    = U(1)
    local card_pad  = U(M.card_pad)
    local card_h    = #EDIT_ROWS * row_h + (#EDIT_ROWS - 1) * line_h + 2 * card_pad
    local act_h     = row_h + U(8)                       -- an icon over its name
    local act_card_h = act_h + 2 * card_pad
    local cap_gap   = U(6)

    local sub_text = title
    if props.authors then
        sub_text = title .. "  ·  " .. (props.authors:gsub("\n", ", "))
    end
    local subtitle = TextWidget:new{
        text = sub_text, face = KoboldWidgets.face(M.font + 1),
        fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w,
    }
    local caption = TextWidget:new{
        text = _("Status"), face = KoboldWidgets.face(M.font),
        fgcolor = KoboldWidgets.subtitleColor(),
    }
    local sub_h, cap_h = subtitle:getSize().h, caption:getSize().h

    local used = top_h + sub_gap + sub_h + gap + bar_h + gap + cap_h + cap_gap
        + seg_total + gap + card_h + gap + act_card_h
    if used > inner_h and level < #LEVELS then
        pcall(function() subtitle:free() end)
        pcall(function() caption:free() end)
        return self:buildEdit(level + 1)
    end

    local sub_y  = y0 + top_h + sub_gap
    local bar_y  = sub_y + sub_h + gap
    local cap_y  = bar_y + bar_h + gap
    local seg_y  = cap_y + cap_h + cap_gap
    local card_y = seg_y + seg_total + gap
    local act_y  = card_y + card_h + gap

    local rects = { stars = {}, status = {}, rows = {}, actions = {} }
    self.edit_rects = rects

    -- Title bar: back on the left with the title, close on the right.
    local close_d = U(36)
    local back_button = pill(close_d, close_d, SOFT, OptionSheet.iconWidget("chevron-left", U(18), BLACK))
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local top_left = HorizontalGroup:new{
        align = "center",
        back_button,
        HorizontalSpan:new{ width = U(12) },
        TextWidget:new{ text = _("Edit"), face = KoboldWidgets.face(19), bold = true },
    }
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, close_button },
    }
    rects.back = Geom:new{
        x = R.x, y = R.y, w = border + pad + close_d + U(12), h = top_h + pad + border,
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- The review bar: [favorite] | review text | [5 stars].
    ensureLikeFilled()
    local bs = U(1)
    local bar_pad = U(14)
    local fav_sz = U(24)
    local line_gap = U(10)
    local star_sz, star_gap = U(22), U(4)
    local bar_inner_w, bar_inner_h = inner_w - 2 * bs, bar_h - 2 * bs
    local function fixedPart() return bar_pad + fav_sz + line_gap + U(1) + line_gap + U(10) + (5 * star_sz + 4 * star_gap) + U(14) end
    local text_w = bar_inner_w - fixedPart()
    if text_w < U(90) then
        star_sz, star_gap = U(18), U(2)
        text_w = bar_inner_w - fixedPart()
    end
    text_w = math.max(U(20), text_w)
    local stars_w = 5 * star_sz + 4 * star_gap

    local note = rv.note and (rv.note:gsub("%s+", " "))
    local review_label = TextWidget:new{
        text = note or _("Add review…"),
        face = note and KoboldWidgets.face(15) or italicFace(15),
        fgcolor = note and BLACK or Blitbuffer.Color8(0x77),
        max_width = text_w,
    }
    local star_row = HorizontalGroup:new{ align = "center" }
    for i = 1, 5 do
        if i > 1 then star_row[#star_row + 1] = HorizontalSpan:new{ width = star_gap } end
        star_row[#star_row + 1] = OptionSheet.iconWidget(i <= rv.rating and STAR_ON or STAR_OFF, star_sz, BLACK)
    end
    local bar_row = HorizontalGroup:new{
        align = "center",
        HorizontalSpan:new{ width = bar_pad },
        OptionSheet.iconWidget(rv.favorite and LIKE_ON or LIKE_OFF, fav_sz, BLACK),
        HorizontalSpan:new{ width = line_gap },
        LineWidget:new{ dimen = Geom:new{ w = U(1), h = U(22) }, background = LINE },
        HorizontalSpan:new{ width = line_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = review_label:getSize().h }, review_label,
        },
        HorizontalSpan:new{ width = U(10) },
        star_row,
        HorizontalSpan:new{ width = U(14) },
    }
    local review_bar = FrameContainer:new{
        bordersize = bs, color = LINE, padding = 0,
        radius = math.floor(bar_h / 2), background = SOFT,
        LeftContainer:new{ dimen = Geom:new{ w = bar_inner_w, h = bar_inner_h }, bar_row },
    }
    -- Where each part of the bar is tapped (the whole height of the bar).
    local text_x = x0 + bs + bar_pad + fav_sz + line_gap + U(1) + line_gap
    local stars_x = text_x + text_w + U(10)
    rects.bar = Geom:new{ x = x0, y = bar_y, w = inner_w, h = bar_h }
    rects.fav = Geom:new{ x = x0, y = bar_y, w = text_x - x0 - line_gap, h = bar_h }
    rects.review = Geom:new{
        x = rects.fav.x + rects.fav.w, y = bar_y,
        w = stars_x - math.floor(star_gap / 2) - (rects.fav.x + rects.fav.w), h = bar_h,
    }
    for i = 1, 5 do
        local sx = stars_x + (i - 1) * (star_sz + star_gap) - math.floor(star_gap / 2)
        rects.stars[i] = Geom:new{
            x = sx, y = bar_y, w = star_sz + star_gap + (i == 5 and U(12) or 0), h = bar_h,
        }
    end

    -- Reading status: a segmented control, the same look as Synopsis / Details.
    local seg_w = math.floor((inner_w - 2 * seg_pad) / #STATUSES)
    local segments = HorizontalGroup:new{}
    for i, st in ipairs(STATUSES) do
        local selected = (st.id == rv.status)
        segments[#segments + 1] = pill(seg_w, seg_h, selected and BLACK or SOFT, TextWidget:new{
            text = st.text, face = KoboldWidgets.face(16), bold = selected,
            fgcolor = selected and WHITE or BLACK, max_width = seg_w - U(8),
        })
        rects.status[i] = {
            id = st.id,
            rect = Geom:new{ x = x0 + seg_pad + (i - 1) * seg_w, y = seg_y + seg_pad, w = seg_w, h = seg_h },
        }
    end
    rects.status_rect = Geom:new{ x = x0, y = seg_y, w = inner_w, h = seg_total }
    local status_track = FrameContainer:new{
        bordersize = 0, padding = seg_pad, radius = math.floor(seg_total / 2), background = SOFT,
        segments,
    }

    -- The card of rows: an icon, the name, a chevron.
    local card_w = inner_w - 2 * card_pad
    local list = VerticalGroup:new{ align = "left" }
    for i, row in ipairs(EDIT_ROWS) do
        if i > 1 then
            list[#list + 1] = LineWidget:new{ dimen = Geom:new{ w = card_w, h = line_h }, background = LINE }
        end
        list[#list + 1] = OverlapGroup:new{
            dimen = Geom:new{ w = card_w, h = row_h },
            LeftContainer:new{
                dimen = Geom:new{ w = card_w, h = row_h },
                HorizontalGroup:new{
                    align = "center",
                    OptionSheet.iconWidget(row.icon, U(18), BLACK),
                    HorizontalSpan:new{ width = U(12) },
                    TextWidget:new{
                        text = row.text, face = KoboldWidgets.face(17),
                        max_width = card_w - U(18) - U(12) - U(30),
                    },
                },
            },
            RightContainer:new{
                dimen = Geom:new{ w = card_w, h = row_h },
                OptionSheet.iconWidget("chevron-right", U(16), KoboldWidgets.subtitleColor()),
            },
        }
        rects.rows[i] = {
            id = row.id,
            rect = Geom:new{ x = x0, y = card_y + card_pad + (i - 1) * (row_h + line_h), w = inner_w, h = row_h },
        }
    end
    local card = FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        list,
    }

    -- The file's buttons, a card of their own: icon over name, four equal
    -- cells with a hairline between them.
    local sep_w  = line_h
    local cell_w = math.floor((card_w - (#FILE_ACTIONS - 1) * sep_w) / #FILE_ACTIONS)
    local act_icon = U(M.font + 5)
    local actions = HorizontalGroup:new{ align = "center" }
    for i, act in ipairs(FILE_ACTIONS) do
        if i > 1 then
            actions[#actions + 1] = LineWidget:new{
                dimen = Geom:new{ w = sep_w, h = act_h - U(18) }, background = LINE,
            }
        end
        actions[#actions + 1] = CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = act_h },
            VerticalGroup:new{
                align = "center",
                OptionSheet.iconWidget(act.icon, act_icon, BLACK),
                VerticalSpan:new{ width = U(3) },
                TextWidget:new{
                    text = act.text, face = KoboldWidgets.face(M.font + 1),
                    max_width = cell_w - U(6),
                },
            },
        }
        rects.actions[i] = {
            id = act.id,
            rect = Geom:new{
                x = x0 + card_pad + (i - 1) * (cell_w + sep_w), y = act_y + card_pad,
                w = cell_w + (i < #FILE_ACTIONS and sep_w or 0), h = act_h,
            },
        }
    end
    local act_card = FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        actions,
    }

    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = sub_gap },
        subtitle,
        VerticalSpan:new{ width = gap },
        review_bar,
        VerticalSpan:new{ width = gap },
        caption,
        VerticalSpan:new{ width = cap_gap },
        status_track,
        VerticalSpan:new{ width = gap },
        card,
        VerticalSpan:new{ width = gap },
        act_card,
        -- the sheet is as tall as the details page, whatever the rows take
        VerticalSpan:new{ width = math.max(0, inner_h - used) },
    }
    local panel = FrameContainer:new{
        bordersize = border, padding = pad,
        radius = radius,
        background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

-- ── The text editor screen ─────────────────────────────────────────────────
-- Writing a review, or a field of the metadata: the same sheet again. On top
-- Cancel, the name of what is edited and a Save pill; under the book's name a
-- big grey field with the text; and the plugin's own keyboard (keyboard.lua,
-- with an enter key when the text may have several lines) at the bottom of the
-- screen, over the lower part of the sheet. The hide key lowers it, and the
-- field then uses the whole sheet; tapping the field brings it back. While
-- typing, the field shows the end of the text (where the caret is); with the
-- keyboard down it shows the start, cut with "…" if it is long. A small
-- "Restore original" under the field, for a corrected metadata field.
-- openEditor{ heading, value, placeholder, max, multiline, save, restore }
-- opens it; `save(text)` returns true when it saved (the editor then closes),
-- `restore()` the same.

local REVIEW_MAX = 2000   -- characters

local function trim(s) return (s:match("^%s*(.-)%s*$")) end
local function ulen(s) return #(s:gsub("[\128-\191]", "")) end

-- Width of a piece of text, remembered: wrapping asks for the same lines
-- again after every key, and only the end of the text is new.
local function measure(cache, face, s)
    if s == "" then return 0 end
    local w = cache[s]
    if not w then
        local t = TextWidget:new{ text = s, face = face }
        w = t:getSize().w
        t:free()
        cache[s] = w
    end
    return w
end

-- A word wider than a whole line, cut into pieces that fit.
local function breakWord(word, face, max_w, cache)
    local pieces, piece = {}, ""
    for c in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
        if piece ~= "" and measure(cache, face, piece .. c) > max_w then
            pieces[#pieces + 1] = piece
            piece = c
        else
            piece = piece .. c
        end
    end
    if piece ~= "" then pieces[#pieces + 1] = piece end
    return pieces
end

-- The text as lines no wider than max_w: a new line where the text has one,
-- and a break at a space where a line is full. Returns the lines and, for
-- each, the byte offset in the text where it starts (the caret is a byte
-- offset too, which is how it is drawn and how a tap finds it).
local function wrapText(text, face, max_w, cache)
    local lines, starts = {}, {}
    local pstart = 0
    for para in (text .. "\n"):gmatch("(.-)\n") do
        local cur = pstart
        local line = ""
        local function push(l)
            lines[#lines + 1] = l
            starts[#starts + 1] = cur
            cur = cur + #l
        end
        for tok in para:gmatch("%s*%S+%s*") do
            local cand = line .. tok
            if line == "" or measure(cache, face, (cand:gsub("%s+$", ""))) <= max_w then
                line = cand
            else
                push(line)
                line = tok
            end
            if measure(cache, face, (line:gsub("%s+$", ""))) > max_w then
                local pieces = breakWord(line, face, max_w, cache)
                for i = 1, #pieces - 1 do push(pieces[i]) end
                line = pieces[#pieces] or ""
            end
        end
        push(line)
        pstart = pstart + #para + 1
    end
    return lines, starts
end

-- Where the character that ends at byte `pos` begins (UTF-8).
local function prevCharStart(s, pos)
    local i = pos
    while i > 1 do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return i
end

-- "fantasy, epic; magic" -> { "fantasy", "epic", "magic" }, as written.
local function splitKeywordList(raw)
    local out, seen = {}, {}
    for part in ((raw or "") .. ","):gmatch("([^,;\n]*)[,;\n]") do
        local word = trim((part:gsub("%s+", " ")))
        if word ~= "" and not seen[word:lower()] then
            seen[word:lower()] = true
            out[#out + 1] = word
        end
    end
    return out
end

-- The line the caret is on: its text and the byte range it covers (a text
-- of several lines is how authors are written, one to a line).
local function lineAtCaret(st)
    local pos = math.max(0, math.min(st.pos or #st.value, #st.value))
    local before = st.value:sub(1, pos)
    local ls = before:match(".*\n()") or 1
    local nl = st.value:find("\n", pos + 1, true)
    local le = nl and (nl - 1) or #st.value
    return st.value:sub(ls, le), ls, le
end

-- What the editor holds as one text: the text itself, or for keywords the
-- pills (and the word being typed) joined with commas.
local function editorText(st)
    if not st.chips then return trim(st.value) end
    local list = {}
    local seen = {}
    for _i, c in ipairs(st.chips) do
        list[#list + 1] = c
        seen[c:lower()] = true
    end
    local pending = trim((st.value:gsub("%s+", " ")))
    if pending ~= "" and not seen[pending:lower()] then list[#list + 1] = pending end
    return table.concat(list, ", ")
end

-- The word being typed becomes a pill (unless it is there already).
local function commitChip(st)
    local word = trim((st.value:gsub("%s+", " ")))
    st.value, st.pos = "", 0
    if word == "" then return end
    local lower = word:lower()
    for _i, c in ipairs(st.chips) do
        if c:lower() == lower then return end
    end
    if ulen(table.concat(st.chips, ", ")) + ulen(word) + 2 > st.max then return end
    st.chips[#st.chips + 1] = word
end

-- With a number beside the text (the series) the editor holds two texts: the
-- name and the number. Without one, just the text.
local function editorTexts(st)
    if not st.num then return editorText(st) end
    return editorText(st), trim(st.num.value)
end

-- Both texts as one, to tell whether anything changed.
local function editorSignature(st)
    local text, number = editorTexts(st)
    if number then return text .. "\n" .. number end
    return text
end

function KoboldBookDetails:editorCanSave()
    local st = self.editor
    return st ~= nil and editorSignature(st) ~= st.original
end

function KoboldBookDetails:buildEditor()
    local st = self.editor
    local M = LEVELS[1]
    local W, H = Screen:getWidth(), Screen:getHeight()
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    local sub_gap = U(M.info_gap)
    self.panel_rect = R

    local file = self.file
    local props = bookProps(file)
    local title = props.title or (file:match("([^/]+)$") or file)
    local sub_text = title
    if props.authors then
        sub_text = title .. "  ·  " .. (props.authors:gsub("\n", ", "))
    end
    local subtitle = TextWidget:new{
        text = sub_text, face = KoboldWidgets.face(M.font + 1),
        fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w,
    }
    local sub_h = subtitle:getSize().h

    -- Top bar: Cancel, the title, the Save pill (grey until there is a change).
    local can = self:editorCanSave()
    st.shown_can = can
    local grey = Blitbuffer.Color8(0x77)
    local save_label = TextWidget:new{
        text = _("Save"), face = KoboldWidgets.face(16), bold = true,
        fgcolor = can and WHITE or grey, bgcolor = can and BLACK or SOFT,
    }
    local save_w = save_label:getSize().w + 2 * U(18)
    local save_button = pill(save_w, U(40), can and BLACK or SOFT, save_label)
    local cancel = TextWidget:new{ text = _("Cancel"), face = KoboldWidgets.face(17) }
    local side_w = math.max(save_w, cancel:getSize().w) + U(8)
    local heading = TextWidget:new{
        text = st.heading or "", face = KoboldWidgets.face(18), bold = true,
        max_width = math.max(U(60), inner_w - 2 * side_w),
    }
    local top_bar = KoboldWidgets.fixed(inner_w, top_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = top_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = inner_w - 2 * side_w, h = top_h }, heading },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = top_h }, save_button },
    })
    st.cancel_rect = Geom:new{ x = R.x, y = R.y, w = border + pad + side_w, h = top_h + pad + border }
    st.save_rect = Geom:new{
        x = x0 + inner_w - side_w, y = R.y, w = side_w + pad + border, h = top_h + pad + border,
    }

    -- The text's measures come first: they decide how tall the field is.
    local field_pad = U(14)
    local text_w = inner_w - 2 * field_pad
    local face = KoboldWidgets.face(18)
    local probe = TextWidget:new{ text = "Ag", face = face }
    local text_h = probe:getSize().h
    probe:free()
    local line_h = text_h + U(4)
    local caret_w = U(2) + U(3)
    local pill_h = text_h + U(10)        -- a keyword pill
    local chip_row_h = pill_h + U(8)
    -- the caret is in the text only while the text is where the keyboard types
    -- (with a number beside it, the number may be)
    local caret_on = st.kb_open and st.focus ~= "number"

    -- Where the field goes: under the name, above the keyboard if it is up.
    -- A field of one line (a title, a series) is a short box; a text of
    -- several lines takes all the room there is.
    local kb_h = st.kb_open and self.kb:height() or 0
    st.kb_y = st.kb_open and (H - kb_h) or nil
    local counter_h = U(22)
    local counter_gap = U(6)
    -- the series' number: a box of one line under the text
    local num_gap = st.num and U(10) or 0
    local num_box_h = st.num and (line_h + 2 * U(10)) or 0
    local num_extra = st.num and (num_gap + num_box_h) or 0
    local field_y = y0 + top_h + sub_gap + sub_h + gap
    local bottom = st.kb_open and (st.kb_y - U(8)) or (y0 + inner_h)
    local field_h = math.max(U(90), bottom - field_y - counter_gap - counter_h - num_extra)
    if st.chips then
        field_h = math.min(field_h, 4 * chip_row_h + 2 * field_pad)
    elseif not st.multiline or st.suggest then
        -- A short box. A field with a list to pick from (the authors, one to
        -- a line) is short too: a box that took all the room left none for it.
        field_h = math.min(field_h, (st.num and 2 or 3) * line_h + 2 * field_pad)
    end
    local avail_h = field_h - 2 * field_pad
    local counter_y = field_y + field_h + counter_gap + num_extra
    st.field_rect = Geom:new{ x = x0, y = field_y, w = inner_w, h = field_h }
    st.counter_rect = Geom:new{ x = x0, y = counter_y, w = inner_w, h = counter_h }

    -- Suggestions (the series that already exist), in the room under the
    -- counter: as many rows as fit, at most six.
    -- A line of explanation under the counter, when the field has one.
    local hint_text = st.hint
    if type(hint_text) == "function" then hint_text = hint_text(st) end
    local hint = hint_text and TextWidget:new{
        text = hint_text, face = KoboldWidgets.face(15),
        fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w,
    } or nil
    local hint_h = hint and (gap + hint:getSize().h) or 0
    local matches = st.suggest and st.suggest(st.value, st) or nil
    local sug_y = counter_y + counter_h + hint_h + gap
    local sug_row_h = U(M.row)
    local sug_caption, sug_fit, sug_cap_h, sug_h = nil, 0, 0, 0
    st.had_sug = st.sug_region   -- where the list was: it is cleared if it goes
    st.sug, st.sug_rects, st.sug_region = {}, {}, nil
    if matches and #matches > 0 then
        sug_caption = TextWidget:new{
            text = st.suggest_title or "", face = KoboldWidgets.face(12),
            fgcolor = KoboldWidgets.subtitleColor(),
        }
        sug_cap_h = sug_caption:getSize().h + U(4)
        sug_fit = math.min(6, #matches, math.floor((bottom - sug_y - sug_cap_h) / (sug_row_h + U(1))))
        if sug_fit >= 1 then
            sug_h = sug_cap_h + sug_fit * sug_row_h + (sug_fit - 1) * U(1)
        else
            sug_fit = 0
        end
    end
    local used = (counter_y + counter_h - y0) + hint_h + (sug_h > 0 and (gap + sug_h) or 0)
    local function caret()
        return HorizontalGroup:new{
            HorizontalSpan:new{ width = U(3) },
            LineWidget:new{ dimen = Geom:new{ w = U(2), h = text_h }, background = BLACK },
        }
    end
    local function lineBox(inner)
        return LeftContainer:new{ dimen = Geom:new{ w = text_w, h = line_h }, inner }
    end

    st.pos = math.max(0, math.min(st.pos or #st.value, #st.value))
    st.layout, st.chip_rects = nil, {}
    local text_x, text_y = x0 + field_pad, field_y + field_pad
    local group = VerticalGroup:new{ align = "left" }
    if st.chips then
        -- Keywords: every one a pill (tap it to take it off) and, at the end,
        -- the word being typed.
        local gap_x = U(8)
        local pill_pad = U(12)
        local x_sz = U(12)
        local rows = { {} }
        local x = 0
        for i, label in ipairs(st.chips) do
            local w = math.min(text_w, measure(st.cache, face, label) + 2 * pill_pad + U(6) + x_sz)
            if x > 0 and x + w > text_w then
                rows[#rows + 1] = {}
                x = 0
            end
            table.insert(rows[#rows], { chip = i, label = label, w = w, x = x })
            x = x + w + gap_x
        end
        if st.kb_open or st.value ~= "" or #st.chips == 0 then
            local input_w = text_w - x
            if x > 0 and input_w < U(110) then
                rows[#rows + 1] = {}
                x, input_w = 0, text_w
            end
            table.insert(rows[#rows], { input = true, w = input_w, x = x })
        end
        local row_vis = math.max(1, math.floor(avail_h / chip_row_h))
        local first_row = st.kb_open and math.max(1, #rows - row_vis + 1) or 1
        local last_row = math.min(#rows, first_row + row_vis - 1)
        for r = first_row, last_row do
            local row = HorizontalGroup:new{ align = "center" }
            for _i, item in ipairs(rows[r]) do
                if #row > 0 then row[#row + 1] = HorizontalSpan:new{ width = gap_x } end
                if item.chip then
                    local bs = U(1)
                    row[#row + 1] = FrameContainer:new{
                        bordersize = bs, color = BLACK, radius = math.floor(pill_h / 2),
                        background = WHITE, padding = 0,
                        LeftContainer:new{
                            dimen = Geom:new{ w = item.w - 2 * bs, h = pill_h - 2 * bs },
                            HorizontalGroup:new{
                                align = "center",
                                HorizontalSpan:new{ width = pill_pad },
                                TextWidget:new{
                                    text = item.label, face = face,
                                    max_width = item.w - 2 * pill_pad - U(6) - x_sz,
                                },
                                HorizontalSpan:new{ width = U(6) },
                                KoboldWidgets.icon("close", x_sz),
                            },
                        },
                    }
                    st.chip_rects[#st.chip_rects + 1] = {
                        index = item.chip,
                        rect = Geom:new{
                            x = text_x + item.x,
                            y = text_y + (r - first_row) * chip_row_h + math.floor((chip_row_h - pill_h) / 2),
                            w = item.w, h = pill_h,
                        },
                    }
                else
                    local room = item.w - caret_w
                    local shown = st.value
                    if shown == "" then
                        if st.kb_open then row[#row + 1] = caret() end
                        if #st.chips == 0 then
                            row[#row + 1] = TextWidget:new{
                                text = st.placeholder or "", face = italicFace(18), fgcolor = grey,
                                bgcolor = SOFT, max_width = room,
                            }
                        end
                    else
                        -- a word too long for the line shows its end
                        while shown ~= "" and measure(st.cache, face, shown) > room do
                            local nxt = shown:find("[%z\1-\127\194-\244]", 2)
                            shown = nxt and shown:sub(nxt) or ""
                        end
                        row[#row + 1] = TextWidget:new{ text = shown, face = face, bgcolor = SOFT }
                        if st.kb_open then row[#row + 1] = caret() end
                    end
                    if #row == 0 then row[#row + 1] = HorizontalSpan:new{ width = 0 } end
                end
            end
            group[#group + 1] = LeftContainer:new{ dimen = Geom:new{ w = text_w, h = chip_row_h }, row }
        end
    elseif st.value == "" then
        local row = HorizontalGroup:new{ align = "center" }
        if caret_on then row[#row + 1] = caret() end
        row[#row + 1] = TextWidget:new{
            text = st.placeholder or "", face = italicFace(18), fgcolor = grey,
            bgcolor = SOFT, max_width = text_w - caret_w,
        }
        group[#group + 1] = lineBox(row)
    else
        local lines, starts = wrapText(st.value, face, text_w - caret_w, st.cache)
        local vis = math.max(1, math.floor(avail_h / line_h))
        -- the line the caret is on
        local ci = #lines
        for i = 1, #lines do
            if starts[i] <= st.pos then ci = i else break end
        end
        -- scrolls only as far as the caret needs
        local f = st.first or 1
        if ci < f then f = ci elseif ci > f + vis - 1 then f = ci - vis + 1 end
        f = math.max(1, math.min(f, math.max(1, #lines - vis + 1)))
        st.first = f
        local first = st.kb_open and f or 1
        local last = math.min(#lines, first + vis - 1)
        for i = first, last do
            local text = lines[i]
            if not st.kb_open and i == last and last < #lines then
                text = text:gsub("%s+$", "") .. "…"   -- more below: the field is cut here
            end
            local inner
            if text == "" then
                inner = HorizontalSpan:new{ width = 0 }
            else
                inner = TextWidget:new{ text = text, face = face, bgcolor = SOFT, max_width = text_w }
            end
            if caret_on and i == ci then
                local k = math.min(#lines[i], st.pos - starts[i])
                local cx = measure(st.cache, face, lines[i]:sub(1, k))
                group[#group + 1] = OverlapGroup:new{
                    dimen = Geom:new{ w = text_w, h = line_h },
                    LeftContainer:new{ dimen = Geom:new{ w = text_w, h = line_h }, inner },
                    LeftContainer:new{
                        dimen = Geom:new{ w = text_w, h = line_h },
                        HorizontalGroup:new{
                            HorizontalSpan:new{ width = cx },
                            LineWidget:new{ dimen = Geom:new{ w = U(2), h = text_h }, background = BLACK },
                        },
                    },
                }
            else
                group[#group + 1] = lineBox(inner)
            end
        end
        st.layout = {
            first = first, last = last, lines = lines, starts = starts,
            line_h = line_h, text_x = text_x, text_y = text_y, face = face,
        }
    end
    -- (a FrameContainer's own width and height only change what it paints,
    -- not the room it takes: the size comes from a fixed box inside it)
    -- With a number under it, the box being typed in has a black outline (the
    -- other one a grey that is not seen); the size stays the same either way.
    local fbs = st.num and U(2) or 0
    local field = FrameContainer:new{
        bordersize = fbs, color = (st.focus == "number") and SOFT or BLACK,
        radius = U(16), background = SOFT, padding = field_pad - fbs,
        KoboldWidgets.fixed(text_w, avail_h, group),
    }
    -- The series' number: its name on the left, a small box on the right.
    local num_row
    st.num_rect = nil
    if st.num then
        local focused = (st.focus == "number")
        local bs = U(2)
        local box_w = U(130)
        local box_pad = U(12)
        local num_text_w = box_w - 2 * bs - 2 * box_pad - caret_w
        local content = HorizontalGroup:new{ align = "center", HorizontalSpan:new{ width = box_pad } }
        if st.num.value == "" then
            if focused and st.kb_open then content[#content + 1] = caret() end
            content[#content + 1] = TextWidget:new{
                text = st.num.placeholder or "", face = italicFace(18), fgcolor = grey,
                bgcolor = SOFT, max_width = num_text_w,
            }
        else
            content[#content + 1] = TextWidget:new{
                text = st.num.value, face = face, bgcolor = SOFT, max_width = num_text_w,
            }
            if focused and st.kb_open then content[#content + 1] = caret() end
        end
        local box = FrameContainer:new{
            bordersize = bs, color = focused and BLACK or SOFT, radius = U(14),
            background = SOFT, padding = 0,
            LeftContainer:new{ dimen = Geom:new{ w = box_w - 2 * bs, h = num_box_h - 2 * bs }, content },
        }
        local num_label = TextWidget:new{
            text = st.num.label or "", face = KoboldWidgets.face(15),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w - box_w - U(12),
        }
        num_row = OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = num_box_h },
            LeftContainer:new{
                dimen = Geom:new{ w = inner_w, h = num_box_h },
                HorizontalGroup:new{ HorizontalSpan:new{ width = U(6) }, num_label },
            },
            RightContainer:new{ dimen = Geom:new{ w = inner_w, h = num_box_h }, box },
        }
        st.num_rect = Geom:new{ x = x0, y = field_y + field_h + num_gap, w = inner_w, h = num_box_h }
    end
    local counter = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = counter_h },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = counter_h },
            TextWidget:new{
                text = ulen(st.chips and editorText(st) or st.value) .. " / " .. st.max, face = KoboldWidgets.face(13),
                fgcolor = KoboldWidgets.subtitleColor(),
            },
        },
    }
    st.restore_rect = nil
    if st.restore then
        local restore_label = TextWidget:new{ text = _("Restore original"), face = KoboldWidgets.face(14), bold = true }
        counter[#counter + 1] = LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = counter_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = U(6) }, restore_label },
        }
        st.restore_rect = Geom:new{
            x = x0, y = st.counter_rect.y - U(4), w = restore_label:getSize().w + U(24), h = counter_h + U(8),
        }
    end

    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = sub_gap },
        subtitle,
        VerticalSpan:new{ width = gap },
        field,
        VerticalSpan:new{ width = counter_gap },
        counter,
    }
    if num_row then
        -- between the text and the counter
        table.insert(column, 6, VerticalSpan:new{ width = num_gap })
        table.insert(column, 7, num_row)
    end
    if hint then
        column[#column + 1] = VerticalSpan:new{ width = gap }
        column[#column + 1] = hint
    end
    if sug_h > 0 then
        local sug_group = VerticalGroup:new{ align = "left", sug_caption, VerticalSpan:new{ width = U(4) } }
        for i = 1, sug_fit do
            local m = matches[i]
            if i > 1 then
                sug_group[#sug_group + 1] = LineWidget:new{ dimen = Geom:new{ w = inner_w, h = U(1) }, background = LINE }
            end
            sug_group[#sug_group + 1] = OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = sug_row_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = inner_w, h = sug_row_h },
                    HorizontalGroup:new{
                        HorizontalSpan:new{ width = U(6) },
                        TextWidget:new{ text = m.label or m.name, face = KoboldWidgets.face(17), max_width = inner_w - U(80) },
                    },
                },
                RightContainer:new{
                    dimen = Geom:new{ w = inner_w, h = sug_row_h },
                    HorizontalGroup:new{
                        (m.count and m.count > 0) and TextWidget:new{
                            text = tostring(m.count), face = KoboldWidgets.face(14),
                            fgcolor = KoboldWidgets.subtitleColor(),
                        } or HorizontalSpan:new{ width = 0 },
                        HorizontalSpan:new{ width = U(6) },
                    },
                },
            }
            st.sug[i] = m.name
            st.sug_rects[i] = Geom:new{
                x = x0, y = sug_y + sug_cap_h + (i - 1) * (sug_row_h + U(1)), w = inner_w, h = sug_row_h,
            }
        end
        st.sug_region = Geom:new{ x = x0, y = sug_y, w = inner_w, h = sug_h }
        column[#column + 1] = VerticalSpan:new{ width = gap }
        column[#column + 1] = sug_group
    end
    -- the sheet keeps its size; the keyboard covers its lower part
    column[#column + 1] = VerticalSpan:new{ width = math.max(0, inner_h - used) }
    local panel = FrameContainer:new{
        bordersize = border, padding = pad, radius = radius, background = WHITE,
        column,
    }
    local layers = OverlapGroup:new{
        dimen = self.dimen,
        KoboldPopup.place(self.dimen, R.x, R.y, panel),
    }
    if st.kb_open then
        layers[#layers + 1] = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = st.kb_y },
            self.kb:build(W),
        }
    elseif self.kb then
        self.kb:free()
    end
    return layers
end

-- The part of the screen the sheet and the keyboard cover.
function KoboldBookDetails:editorRegion()
    local R = self.panel_rect or KoboldPopup.panelRect()
    return Geom:new{ x = 0, y = R.y, w = Screen:getWidth(), h = Screen:getHeight() - R.y }
end

function KoboldBookDetails:openEditor(opts)
    local value = opts.value or ""
    local st = {
        heading = opts.heading, placeholder = opts.placeholder,
        value = value, pos = #value,   -- the caret: a byte offset in the text
        max = opts.max or REVIEW_MAX, multiline = opts.multiline and true or false,
        lower = opts.lowercase and true or false,   -- no capital for the first letter
        save = opts.save, restore = opts.restore,
        suggest = opts.suggest, suggest_title = opts.suggest_title,   -- a list of values to pick from
        pick = opts.pick,   -- what tapping one does (by default it replaces the text)
        hint = opts.hint,   -- a line of explanation under the counter
        back = self.view,   -- the screen it goes back to
        kb_open = true, cache = {},
    }
    if opts.chips then
        -- keywords: a list of pills and, apart, the word being typed
        st.chips = {}
        for _i, c in ipairs(opts.chips) do st.chips[#st.chips + 1] = c end
        st.value, st.pos = "", 0
        st.multiline = true   -- the keyboard gets its enter key: it makes the pill
    end
    if opts.number then
        -- a second, small box under the text (the series' number); the keyboard
        -- types in the one that was tapped last
        st.num = {
            value = tostring(opts.number.value or ""), max = opts.number.max or 10,
            label = opts.number.label, placeholder = opts.number.placeholder,
        }
        st.focus = "main"
    end
    st.original = editorSignature(st)
    self.editor = st
    self.kb = Keyboard.new{
        multiline = st.multiline,
        on_insert = function(c)
            if st.num and st.focus == "number" then
                -- the number: digits and one point (a comma is a point)
                if c == "," then c = "." end
                local v = st.num.value
                if c:match("^%d$") or (c == "." and v ~= "" and not v:find(".", 1, true)) then
                    if #v < st.num.max then st.num.value = v .. c end
                end
                return
            end
            if st.chips then
                if c == "\n" or c == "," then
                    commitChip(st)
                    return
                end
                st.pos = #st.value
            end
            if c == "\n" and not st.chips and not st.multiline then return end
            if ulen(st.value) >= st.max then return end
            st.value = st.value:sub(1, st.pos) .. c .. st.value:sub(st.pos + 1)
            st.pos = st.pos + #c
        end,
        on_delete = function()
            if st.num and st.focus == "number" then
                st.num.value = st.num.value:sub(1, -2)
                return
            end
            if st.chips then
                st.pos = #st.value
                if st.value == "" then
                    table.remove(st.chips)   -- delete on an empty word takes the last pill off
                    return
                end
            end
            if st.pos > 0 then
                local i = prevCharStart(st.value, st.pos)
                st.value = st.value:sub(1, i - 1) .. st.value:sub(st.pos + 1)
                st.pos = i - 1
            end
        end,
        on_clear = function()
            if st.num and st.focus == "number" then
                st.num.value = ""
                return
            end
            st.value, st.pos = "", 0
        end,
        on_hide = function() self:setEditorKeyboard(false) end,
        is_empty = function() return st.focus ~= "number" and st.value == "" and not st.lower end,
        -- a tapped key lets go: its darker look is drawn away, only that key refreshed
        on_redraw = function(rects)
            if self.view ~= "editor" or self.editor ~= st or not (st.kb_open and st.kb_y) then return end
            self[1] = self:build()
            for _i, r in ipairs(rects or {}) do
                UIManager:setDirty(self, function() return "ui", r end)
            end
        end,
    }
    self.kb:reset(st.value == "" and not st.lower)
    self.view = "editor"
    self:refresh(self:editorRegion())
end

-- Back to the screen it came from. With `save`, the text goes to opts.save
-- first; when that does not return true (it said why) the editor stays open.
function KoboldBookDetails:closeEditor(save)
    local st = self.editor
    if not st then return end
    if save and st.save and st.save(editorTexts(st)) ~= true then return end
    local region = self:editorRegion()
    if self.kb then
        self.kb:free()
        self.kb = nil
    end
    self.editor = nil
    self.view = st.back or "edit"
    self:refresh(region)
end

-- The review of the book: free text, several lines.
function KoboldBookDetails:openReview()
    self:openEditor{
        heading = _("Review"),
        placeholder = _("Write your review…"),
        value = (self.rv and self.rv.note) or "",
        max = REVIEW_MAX, multiline = true,
        save = function(text)
            if not Review.setNote(self.file, text) then
                Toast.error(_("The review could not be saved."))
                return false
            end
            self.rv.note = (text ~= "") and text or nil
            self.changed = true
            return true
        end,
    }
end

-- Keyboard up or down: the field grows or shrinks with it.
function KoboldBookDetails:setEditorKeyboard(open)
    local st = self.editor
    if not st or st.kb_open == open then return end
    st.kb_open = open
    self:resetEditorKeyboard()
    self:refresh(self:editorRegion())
end

-- The keyboard as it starts for the box being typed in: letters (with a capital
-- first when the text is empty), or numbers for the series' number.
function KoboldBookDetails:resetEditorKeyboard()
    local st = self.editor
    if not (st and self.kb) then return end
    if st.num and st.focus == "number" then
        self.kb:reset(false)
        self.kb.layer = "num"
    else
        self.kb:reset(st.value == "" and not st.lower)
    end
end

-- With a number beside the text: the keyboard types in the other box (and
-- comes up if it was down).
function KoboldBookDetails:focusEditorField(which)
    local st = self.editor
    if not (st and st.num) then return end
    if st.focus == which and st.kb_open then return end
    st.focus = which
    st.kb_open = true
    self:resetEditorKeyboard()
    self:refresh(self:editorRegion())
end

-- After a key: only what it changed is refreshed, never the whole sheet. A
-- letter changes the field and the counter (and the Save pill, when it turns
-- on or off); a key changes its own pad, unless the keys look different
-- (shift, 123, accent), when the keyboard is drawn again.
function KoboldBookDetails:refreshEditorTyping(text_changed, kb_changed, rects, prev_can)
    local st = self.editor
    if not (st and st.kb_open and st.kb_y) then
        self:refresh(self:editorRegion())
        return
    end
    local function grow(r, n)
        return Geom:new{ x = r.x - n, y = r.y - n, w = r.w + 2 * n, h = r.h + 2 * n }
    end
    local n = U(2)
    local regions = {}
    if text_changed then
        regions[#regions + 1] = grow(st.field_rect, n)
        regions[#regions + 1] = grow(st.counter_rect, n)
        if st.num_rect then regions[#regions + 1] = grow(st.num_rect, n) end
        if st.sug_region or st.had_sug then regions[#regions + 1] = grow(st.sug_region or st.had_sug, n) end
        if st.shown_can ~= prev_can then regions[#regions + 1] = grow(st.save_rect, n) end
    end
    if kb_changed then
        regions[#regions + 1] = Geom:new{
            x = 0, y = st.kb_y, w = Screen:getWidth(), h = Screen:getHeight() - st.kb_y,
        }
    else
        for _i, r in ipairs(rects or {}) do regions[#regions + 1] = r end
    end
    for _i, r in ipairs(regions) do
        UIManager:setDirty(self, function() return "ui", r end)
    end
end

function KoboldBookDetails:onEditorTap(pos)
    local st = self.editor
    if not st then return end
    if pos:intersectWith(st.cancel_rect) then return self:closeEditor(false) end
    if pos:intersectWith(st.save_rect) then
        if self:editorCanSave() then self:closeEditor(true) end
        return
    end
    if st.restore_rect and pos:intersectWith(st.restore_rect) then
        if st.restore() == true then self:closeEditor(false) end
        return
    end
    for i, rect in ipairs(st.sug_rects or {}) do
        if pos:intersectWith(rect) then
            -- a picked value replaces the text (or, for keywords, becomes a
            -- pill); Save keeps it
            local prev_can = st.shown_can
            if st.pick then
                st.pick(st, st.sug[i])
            else
                st.value = st.sug[i]
                if st.chips then commitChip(st) else st.pos = #st.value end
            end
            -- with a number to type next (the series), the keyboard moves on to it
            local kb_changed = false
            if st.num and st.focus == "main" then
                st.focus = "number"
                self:resetEditorKeyboard()
                kb_changed = true
            end
            self[1] = self:build()
            self:refreshEditorTyping(true, kb_changed, nil, prev_can)
            return
        end
    end
    if st.kb_open and st.kb_y and pos.y >= st.kb_y then
        local handled, text_changed, kb_changed, rects = self.kb:tap(pos, st.kb_y)
        if handled and self.editor == st and st.kb_open and (text_changed or kb_changed) then
            local prev_can = st.shown_can
            self[1] = self:build()
            self:refreshEditorTyping(text_changed, kb_changed, rects, prev_can)
        end
        return
    end
    if st.num_rect and pos:intersectWith(st.num_rect) then return self:focusEditorField("number") end
    if pos:intersectWith(st.field_rect) then
        if st.num and st.focus == "number" then return self:focusEditorField("main") end
        return self:onEditorFieldTap(pos)
    end
end

-- Where in the text a tap landed: the byte offset of the caret, between the
-- two letters nearest to the finger.
function KoboldBookDetails:caretFromTap(pos)
    local st = self.editor
    local L = st.layout
    if not (L and #L.lines > 0) then return #st.value end
    local idx = L.first + math.floor((pos.y - L.text_y) / L.line_h)
    idx = math.max(L.first, math.min(L.last, idx))
    local line, start = L.lines[idx], L.starts[idx]
    local n = #line
    local rel_x = pos.x - L.text_x
    local chosen = n
    local prev, i = 0, 1
    while i <= n do
        local j = i + 1
        while j <= n and line:byte(j) >= 0x80 and line:byte(j) < 0xC0 do j = j + 1 end
        local w = measure(st.cache, L.face, line:sub(1, j - 1))
        if w >= rel_x then
            chosen = (rel_x - prev < w - rel_x) and (i - 1) or (j - 1)
            break
        end
        prev = w
        i = j
    end
    -- the end of a full line is the start of the next one: stay before its spaces
    if L.starts[idx + 1] == start + n then
        chosen = math.min(chosen, #(line:gsub("%s+$", "")))
    end
    return start + chosen
end

-- A tap on the field: a pill goes off (keywords), or the caret goes where the
-- finger is (and the keyboard comes up if it was down).
function KoboldBookDetails:onEditorFieldTap(pos)
    local st = self.editor
    if st.chips then
        for _i, c in ipairs(st.chip_rects or {}) do
            if pos:intersectWith(c.rect) then
                local prev_can = st.shown_can
                table.remove(st.chips, c.index)
                self[1] = self:build()
                self:refreshEditorTyping(true, false, nil, prev_can)
                return
            end
        end
        if not st.kb_open then self:setEditorKeyboard(true) end
        return
    end
    st.pos = self:caretFromTap(pos)
    if st.kb_open then
        self[1] = self:build()
        local rect = st.field_rect
        UIManager:setDirty(self, function() return "ui", rect end)
    else
        self:setEditorKeyboard(true)
    end
end

-- Hold the keyboard's delete key: the whole text is cleared.
function KoboldBookDetails:onEditorHold(pos)
    local st = self.editor
    if not (st and st.kb_open and st.kb_y and pos.y >= st.kb_y) then return end
    local _handled, text_changed, kb_changed = self.kb:hold(pos, st.kb_y)
    if self.editor == st and st.kb_open and (text_changed or kb_changed) then
        local prev_can = st.shown_can
        self[1] = self:build()
        self:refreshEditorTyping(text_changed, kb_changed, nil, prev_can)
    end
end


-- ── The Metadata screen ────────────────────────────────────────────────────
-- A card with the book's title, authors, series, series number, language,
-- keywords and description, each with its value under its name. A field that
-- was corrected carries a small pencil (as in KOReader's Book information).
-- Tapping a field opens it in the text editor above. The corrections are
-- saved in the book's sidecar (see kobold/data/metadata.lua); the book file
-- is not touched by them. "Restore original metadata" puts every field back.
-- The series goes with its number, in the same editor (a second box under the
-- name). A pill beside the close button, "Write to book", puts every correction
-- into the EPUB file itself, as Calibre does (see kobold/data/epub_writer.lua),
-- after a confirmation that says what will happen.

local META_FIELDS = {
    { key = "title",        label = _("Title"),         max = 300 },
    { key = "authors",      label = _("Authors"),       max = 600, multiline = true,
      placeholder = _("One author per line") },
    { key = "series",       label = _("Series"),        max = 200 },
    { key = "series_index", label = _("Series number"), max = 10 },
    { key = "language",     label = _("Language"),      max = 20, lowercase = true },
    { key = "keywords",     label = _("Keywords"),      max = 500, chips = true,
      placeholder = _("Type a keyword and press Enter") },
    { key = "description",  label = _("Description"),   max = 4000, multiline = true },
}

-- The cover goes first on this screen: it is part of how a book looks, like its title.
-- The series number has no row of its own: it is edited together with the series.
local META_ROWS = { { key = "cover", label = _("Cover") } }
for _i, f in ipairs(META_FIELDS) do
    if f.key ~= "series_index" then META_ROWS[#META_ROWS + 1] = f end
end

-- One line per author, no empty ones.
local function cleanLines(text)
    local out = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = trim(line)
        if line ~= "" then out[#out + 1] = line end
    end
    return table.concat(out, "\n")
end

-- What is read from the book (and the corrections over it), kept while the
-- screen is open.
function KoboldBookDetails:loadMeta()
    self.meta = {
        props = (bookProps(self.file)),
        custom = Metadata.custom(self.file),
        originals = Metadata.originals(self.file),
        cover_custom = Metadata.customCover(self.file) ~= nil,
    }
    if not self.meta_restored then self.meta_restored = {} end
end

-- A field's value as text, or nil when the book has none. The corrected value
-- wins; a field restored a moment ago shows the book's own value even if the
-- cover browser has not read the book again yet.
function KoboldBookDetails:metaValue(key)
    local m = self.meta
    local v = m.custom[key]
    if v == nil then v = self.meta_restored[key] end
    if v == nil then v = m.props[key] end
    if v == nil then return nil end
    if type(v) == "number" then v = string.format("%g", v) end
    v = tostring(v)
    return v ~= "" and v or nil
end

-- A change was saved: KOReader's cover browser reads the book again, the
-- screen below shows it when this page closes, and this one is drawn again.
function KoboldBookDetails:metaSaved(restored)
    if restored and self.meta then
        if type(restored) == "string" then restored = { restored } end
        for _i, key in ipairs(restored) do
            self.meta_restored[key] = self.meta.originals[key]
        end
    end
    Metadata.invalidate(self.file)
    self.meta_changed = true
    self.changed = true
    self:loadMeta()
end

function KoboldBookDetails:buildMetadata(level)
    level = level or 1
    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    self.panel_rect = R
    if not self.meta then self:loadMeta() end
    local meta = self.meta

    local row_h    = math.floor(U(M.row) * 1.35)
    local line_h   = U(1)
    local card_pad = U(M.card_pad)
    local card_h   = #META_ROWS * row_h + (#META_ROWS - 1) * line_h + 2 * card_pad
    local any_custom = false
    for _i, f in ipairs(META_FIELDS) do
        if meta.custom[f.key] ~= nil then any_custom = true end
    end
    local restore_h = U(40)
    local used = top_h + gap + card_h + (any_custom and (gap + restore_h) or 0)
    if used > inner_h and level < #LEVELS then
        return self:buildMetadata(level + 1)
    end
    local card_y = y0 + top_h + gap

    local rects = { rows = {} }
    self.meta_rects = rects

    -- Title bar: back on the left with the title, close on the right.
    local close_d = U(36)
    local back_button = pill(close_d, close_d, SOFT, OptionSheet.iconWidget("chevron-left", U(18), BLACK))
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    -- Beside the close button: the pill that writes the corrections into the
    -- book file. Black when it can (an EPUB with something corrected), grey
    -- when it cannot (a tap says why).
    local can_write = any_custom and Metadata.isEpub(self.file)
    local write_grey = Blitbuffer.Color8(0x77)
    local write_label = TextWidget:new{
        text = _("Write to book"), face = KoboldWidgets.face(15), bold = true,
        fgcolor = can_write and WHITE or write_grey, bgcolor = can_write and BLACK or SOFT,
    }
    local write_w = write_label:getSize().w + 2 * U(16)
    local write_button = pill(write_w, close_d, can_write and BLACK or SOFT, write_label)
    local top_left = HorizontalGroup:new{
        align = "center",
        back_button,
        HorizontalSpan:new{ width = U(12) },
        TextWidget:new{ text = _("Metadata"), face = KoboldWidgets.face(19), bold = true },
    }
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{
            dimen = Geom:new{ w = inner_w, h = top_h },
            HorizontalGroup:new{ align = "center", write_button, HorizontalSpan:new{ width = U(12) }, close_button },
        },
    }
    rects.back = Geom:new{
        x = R.x, y = R.y, w = border + pad + close_d + U(12), h = top_h + pad + border,
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }
    rects.write = Geom:new{
        x = self.close_rect.x - write_w, y = R.y, w = write_w, h = top_h + pad + border,
    }

    -- The card: name (with a pencil when corrected) over the value.
    local card_w = inner_w - 2 * card_pad
    local grey = Blitbuffer.Color8(0x77)
    local list = VerticalGroup:new{ align = "left" }
    for i, f in ipairs(META_ROWS) do
        if i > 1 then
            list[#list + 1] = LineWidget:new{ dimen = Geom:new{ w = card_w, h = line_h }, background = LINE }
        end
        local is_cover = (f.key == "cover")
        local is_custom = is_cover and meta.cover_custom or (meta.custom[f.key] ~= nil)
        if f.key == "series" and meta.custom.series_index ~= nil then is_custom = true end
        local text
        if is_cover then
            text = meta.cover_custom and _("Custom cover") or _("From the book")
        else
            text = self:metaValue(f.key)
            if text and f.key == "description" then text = plainText(text) end
            if text and f.key == "series" then
                local number = self:metaValue("series_index")
                if number then text = text .. "  ·  " .. number end
            end
            if text then text = trim((text:gsub("%s*\n%s*", ", "):gsub("%s+", " "))) end
        end
        local value_w = card_w - U(40)
        local value = TextWidget:new{
            text = text or _("Not set"),
            face = text and KoboldWidgets.face(16) or italicFace(16),
            fgcolor = text and BLACK or grey,
            max_width = value_w,
        }
        local name_row = HorizontalGroup:new{
            align = "center",
            TextWidget:new{ text = f.label, face = KoboldWidgets.face(12), fgcolor = KoboldWidgets.subtitleColor() },
        }
        if is_custom then
            name_row[#name_row + 1] = HorizontalSpan:new{ width = U(6) }
            name_row[#name_row + 1] = OptionSheet.iconWidget("pencil", U(12), KoboldWidgets.subtitleColor())
        end
        list[#list + 1] = OverlapGroup:new{
            dimen = Geom:new{ w = card_w, h = row_h },
            LeftContainer:new{
                dimen = Geom:new{ w = card_w, h = row_h },
                VerticalGroup:new{ align = "left", name_row, VerticalSpan:new{ width = U(2) }, value },
            },
            RightContainer:new{
                dimen = Geom:new{ w = card_w, h = row_h },
                OptionSheet.iconWidget("chevron-right", U(16), KoboldWidgets.subtitleColor()),
            },
        }
        rects.rows[i] = {
            field = f,
            rect = Geom:new{ x = x0, y = card_y + card_pad + (i - 1) * (row_h + line_h), w = inner_w, h = row_h },
        }
    end
    local card = FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        list,
    }

    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = gap },
        card,
    }
    rects.restore = nil
    if any_custom then
        local label = TextWidget:new{
            text = _("Restore original metadata"), face = KoboldWidgets.face(15), bold = true,
            max_width = inner_w - U(44),
        }
        local button_w = label:getSize().w + U(44)
        column[#column + 1] = VerticalSpan:new{ width = gap }
        column[#column + 1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = restore_h },
            pill(button_w, restore_h, SOFT, label),
        }
        rects.restore = Geom:new{
            x = x0 + math.floor((inner_w - button_w) / 2), y = card_y + card_h + gap,
            w = button_w, h = restore_h,
        }
    end
    -- the sheet keeps its size, whatever the card takes
    column[#column + 1] = VerticalSpan:new{ width = math.max(0, inner_h - used) }
    local panel = FrameContainer:new{
        bordersize = border, padding = pad, radius = radius, background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

function KoboldBookDetails:openMetadata()
    self.meta_restored = {}
    self:loadMeta()
    self.view = "metadata"
    self:refresh()
end

function KoboldBookDetails:closeMetadata()
    self.view = "edit"
    self.meta_rects = nil
    self:refresh()
end

-- One field in the text editor. The series goes with its number: a second,
-- small box under the name (the number only says which book of the series
-- this is).
function KoboldBookDetails:editField(f)
    local file = self.file
    if f.key == "cover" then
        Toast.show(_("Coming soon."))   -- the cover options come with the next step
        return
    end
    local current = self:metaValue(f.key)
    if current and f.key == "description" then current = plainText(current) end
    local is_series = (f.key == "series")
    local customized = self.meta.custom[f.key] ~= nil
    if is_series and self.meta.custom.series_index ~= nil then customized = true end
    -- What can be picked from: the series, languages or keywords of the library.
    local known, known_title
    if f.key == "series" then
        known, known_title = Metadata.knownSeries(), _("Series in your library")
    elseif f.key == "language" then
        known, known_title = Metadata.knownLanguages(), _("Languages")
    elseif f.key == "keywords" then
        known, known_title = Metadata.knownKeywords(), _("Keywords in your library")
    elseif f.key == "authors" then
        known, known_title = Metadata.knownAuthors(), _("Authors in your library")
    end
    -- A line under the field. For the series: how many books the one typed has
    -- in the library (counted once for each name that is typed).
    local hint
    if is_series then
        local counted = {}
        hint = function(st)
            local name = trim(st.value)
            if name == "" then
                return (current == nil) and _("This book is not in a series yet.") or nil
            end
            if counted[name] == nil then counted[name] = Metadata.seriesBooks(name, file) end
            local count = counted[name]
            return (count == 1) and string.format(_("%s has 1 book in your library."), name)
                or string.format(_("%s has %d books in your library."), name, count)
        end
    end
    self:openEditor{
        heading = f.label,
        chips = f.chips and splitKeywordList(current) or nil,
        lowercase = f.lowercase,
        suggest_title = known_title,
        hint = hint,
        -- the series' number: nothing is filled in, a book can be any of them
        number = is_series and {
            value = self:metaValue("series_index") or "", max = 10,
            label = _("Series number"), placeholder = _("Number"),
        } or nil,
        -- an author goes on a line of its own: the one being typed becomes the
        -- picked author, and with the others untouched it is added after them
        pick = (f.key == "authors") and function(st, name)
            local line, ls, le = lineAtCaret(st)
            local typed = trim(line):lower()
            if typed == "" or name:lower():find(typed, 1, true) then
                st.value = st.value:sub(1, ls - 1) .. name .. st.value:sub(le + 1)
                st.pos = ls - 1 + #name
            else
                st.value = st.value .. ((st.value == "") and "" or "\n") .. name
                st.pos = #st.value
            end
        end or nil,
        -- untouched text shows everything; typing narrows the list
        suggest = known and function(query, st)
            if f.key == "authors" and st then
                -- the line being typed is what narrows the list, and the
                -- authors already written are not offered again
                query = lineAtCaret(st)
                if trim(st.value) == trim(current or "") then query = "" end
                local have, out = {}, {}
                for l in (st.value .. "\n"):gmatch("(.-)\n") do have[trim(l):lower()] = true end
                for _i, e in ipairs(Metadata.matchList(known, query)) do
                    if not have[e.name:lower()] then out[#out + 1] = e end
                end
                return out
            end
            if not (st and st.chips) and trim(query) == trim(current or "") then query = "" end
            local list = Metadata.matchList(known, query)
            if st and st.chips then
                -- the keywords already added are not offered again
                local have, out = {}, {}
                for _i, c in ipairs(st.chips) do have[c:lower()] = true end
                for _i, e in ipairs(list) do
                    if not have[e.name:lower()] then out[#out + 1] = e end
                end
                list = out
            end
            return list
        end or nil,
        placeholder = f.placeholder or f.label,
        value = current or "",
        max = f.max, multiline = f.multiline,
        save = function(text, number)
            if is_series then return self:saveSeries(text, number or "") end
            if f.key == "authors" then text = cleanLines(text) end
            if text == "" then
                -- empty puts the book's own value back (what KOReader does too)
                if not customized then return true end
                if not Metadata.restore(file, f.key) then
                    Toast.error(_("The metadata could not be saved."))
                    return false
                end
                self:metaSaved(f.key)
                return true
            end
            if not Metadata.set(file, f.key, text, self.meta.props) then
                Toast.error(_("The metadata could not be saved."))
                return false
            end
            self:metaSaved()
            return true
        end,
        restore = customized and function()
            local keys = is_series and { "series", "series_index" } or { f.key }
            local ok
            if is_series then
                ok = Metadata.setMany(file, { series = "", series_index = "" })
            else
                ok = Metadata.restore(file, f.key)
            end
            if not ok then
                Toast.error(_("The metadata could not be saved."))
                return false
            end
            self:metaSaved(keys)
            return true
        end or nil,
    }
end

-- The series and its number, saved together. An empty name puts the book's own
-- series back; an empty number puts its own number back.
function KoboldBookDetails:saveSeries(name, number)
    local file = self.file
    local custom = self.meta.custom
    number = (number:gsub(",", "."))   -- a comma is a point
    if number ~= "" and not tonumber(number) then
        Toast.error(_("The series number must be a number."))
        return false
    end
    -- the number belongs to a series: the one typed, or else the book's own
    local own = (custom.series ~= nil) and self.meta.originals.series or self.meta.props.series
    if number ~= "" and name == "" and not (own and own ~= "") then
        Toast.error(_("Write the series first: the number belongs to it."))
        return false
    end
    if not Metadata.setMany(file, { series = name, series_index = number }, self.meta.props) then
        Toast.error(_("The metadata could not be saved."))
        return false
    end
    local restored = {}
    if name == "" and custom.series ~= nil then restored[#restored + 1] = "series" end
    if number == "" and custom.series_index ~= nil then restored[#restored + 1] = "series_index" end
    self:metaSaved(#restored > 0 and restored or nil)
    return true
end

-- Is the book open in the reader (or parked there)? Its file must not change then.
local function bookIsOpen(file)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local rui = ReaderUI and ReaderUI.instance
    return rui ~= nil and rui.document ~= nil and rui.document.file == file
end

-- The "Write to book" pill: asks first (Kobold's confirmation sheet), saying
-- what will be written and everything that changes with it.
function KoboldBookDetails:writeMetaToBook()
    local file = self.file
    if not Metadata.isEpub(file) then
        Toast.show(_("Only EPUB books can be written to."))
        return
    end
    local changes, keys = Metadata.bookChanges(file)
    if not changes then
        Toast.show(_("Nothing is corrected yet: there is nothing to write."))
        return
    end
    if bookIsOpen(file) then
        Toast.error(_("The book is open in the reader. Close it first."))
        return
    end
    local labels = {}
    for _i, key in ipairs(keys) do
        for _j, f in ipairs(META_FIELDS) do
            if f.key == key then labels[#labels + 1] = f.label end
        end
    end
    local name = file:match("([^/]+)$") or file
    local lines = {
        string.format(_("Goes into the EPUB: %s."), table.concat(labels, ", ")),
        "",
        _("The book file itself is rewritten, so Calibre and other apps will see the changes. Its checksum changes: KOReader may treat it as a new book for statistics and sync."),
        "",
        _("What you corrected here is cleared from KiKome, since the book holds it now. Only a backup copy lets you undo this."),
    }
    if self.meta.cover_custom then
        lines[#lines + 1] = ""
        lines[#lines + 1] = _("The cover is not written.")
    end
    require("kobold.ui.confirm_sheet").show{
        title = _("Write to the book file"),
        message = table.concat(lines, "\n"),
        toggle = { label = _("Keep a backup copy"), detail = name .. ".kikome.bak", value = true },
        confirm_text = _("Write"),
        on_confirm = function(keep_backup)
            if self.closed or self.view ~= "metadata" then return end
            self:doWriteMeta(keep_backup ~= false)
        end,
    }
end

-- Writes the corrections into the book (see Metadata.writeToBook) and shows it.
function KoboldBookDetails:doWriteMeta(keep_backup)
    local file = self.file
    local custom = Metadata.custom(file)   -- what is about to become the book's own
    local working = Toast.working(_("Writing to the book…"), { timeout = 180 })
    local ok, result = Metadata.writeToBook(file, { backup = keep_backup ~= false })
    Toast.dismiss(working)
    if not ok then
        logger.warn("KiKome: could not write the metadata into", file, result)
        Toast.error(_("The book could not be written: ") .. tostring(result), { timeout = 6 })
        return
    end
    -- The book says it itself now. Until the cover browser reads it again, the
    -- screen shows these values (as it does for a field restored a moment ago).
    for _i, f in ipairs(META_FIELDS) do
        local v = custom[f.key]
        if v ~= nil and v ~= "" then self.meta_restored[f.key] = v end
    end
    Metadata.invalidate(file)
    self.meta_changed = true
    self.changed = true
    self:loadMeta()
    self:refresh()
    Toast.show(_("Metadata written to the book."))
end

function KoboldBookDetails:restoreAllMeta()
    local file = self.file
    require("kobold.ui.confirm_sheet").show{
        title = _("Restore original metadata"),
        message = _("The title, authors, series (and its number), language, keywords and description go back to what the book itself says."),
        confirm_text = _("Restore"),
        on_confirm = function()
            if self.closed or self.view ~= "metadata" then return end
            if not Metadata.restoreAll(file) then
                Toast.error(_("The metadata could not be saved."))
                return
            end
            for _i, f in ipairs(META_FIELDS) do
                if self.meta.custom[f.key] ~= nil then
                    self.meta_restored[f.key] = self.meta.originals[f.key]
                end
            end
            Metadata.invalidate(file)
            self.meta_changed = true
            self.changed = true
            self:loadMeta()
            self:refresh()
        end,
    }
end

function KoboldBookDetails:onMetadataTap(pos)
    local r = self.meta_rects
    if not r then return end
    local function hit(rect) return rect and pos:intersectWith(rect) end
    if hit(self.close_rect) then return self:dismiss() end
    if hit(r.back) then return self:closeMetadata() end
    if hit(r.write) then return self:writeMetaToBook() end
    if hit(r.restore) then return self:restoreAllMeta() end
    for _i, row in ipairs(r.rows) do
        if hit(row.rect) then return self:editField(row.field) end
    end
end

-- ── The annotations list and one annotation ────────────────────────────────
-- The bookmark button beside Read now opens the same sheet with every
-- bookmark, highlight and note of the book (see kobold/data/annotations.lua,
-- which reads them from the book's sidecar without opening it).
--
-- List: a title bar (back, name, a filter pill, close), the book's name, then
-- a grey card of rows, one for each annotation: its icon (a bookmark, or the
-- highlight's style: droplet, underline, contrast for invert, strikethrough),
-- the quote (or the note, or the chapter of a bookmark) on up to two lines,
-- under it the chapter and page, and a pencil when it has a note. The filter
-- pill (kind in words, style as its icon) opens the option sheet: Show (All /
-- Bookmarks / Highlights / Notes) and, when the book has several, the
-- highlight style; each tap filters at once. More rows than fit are paged (the
-- bar at the foot, or a swipe). A highlight has a small dot of its colour at
-- the start of its third line (the chapter and page).
--
-- One annotation: the same layout as the detail panel of Page Scrubber: the
-- type and colour as the title ("Highlight (Yellow)"), the date in italics,
-- the type's icon with the chapter, the quote painted the way the book paints
-- it (colour, underline, strikethrough or inverted), the note under a pencil,
-- "Show in book - Page N" (opens the book at that annotation) and, at the
-- bottom, one dot for each annotation of the list (tap a dot, or swipe, to
-- move between them). The same filter pill is in its title bar.

local STYLE_ICON = {
    normal = "droplet", underline = "underline", invert = "contrast", strikethrough = "strikethrough",
}

local function entryIcon(e)
    if e.kind == "bookmark" then return "bookmark" end
    return STYLE_ICON[e.style] or "droplet"
end

-- "Highlight (Yellow)", "Underline (Red)", "Invert", "Bookmark", "Note".
local function entryTitle(e)
    if e.kind == "bookmark" then
        return e.note and _("Note") or _("Bookmark")
    end
    local names = {
        normal = _("Highlight"), invert = _("Invert"),
        underline = _("Underline"), strikethrough = _("Strikethrough"),
    }
    local t = names[e.style] or _("Highlight")
    if e.style ~= "invert" and e.color then
        t = t .. " (" .. Annotations.colorName(e.color) .. ")"
    end
    return t
end

local function oneLine(s)
    return (s:gsub("%s+", " "))
end

-- What a row of the list says: the main text and, under it, where it is.
local function rowTexts(e, prefer_note)
    local main, main_is_chapter
    if prefer_note and e.note then
        main = oneLine(e.note)
    elseif e.kind == "bookmark" then
        if e.note then
            main = oneLine(e.note)
        elseif e.chapter then
            main, main_is_chapter = oneLine(e.chapter), true
        else
            main = _("Bookmark")
        end
    else
        main = e.text and ("“" .. oneLine(e.text) .. "”") or entryTitle(e)
    end
    local parts = {}
    if e.kind == "bookmark" and main_is_chapter then
        parts[#parts + 1] = _("Bookmark")
    elseif e.chapter and e.chapter ~= main then
        parts[#parts + 1] = oneLine(e.chapter)
    end
    if e.page then parts[#parts + 1] = _("Page") .. " " .. e.page end
    local meta = table.concat(parts, "  ·  ")
    if meta == "" then meta = Annotations.formatDate(e.date) or "" end
    return main, meta
end

-- Text cut to at most `lines` lines, ending in "..." when it is longer. One
-- line of text stays a plain TextWidget (so a short quote does not leave a
-- blank line under it).
local function limitedText(text, face, width, lines, opts)
    opts = opts or {}
    local one = TextWidget:new{ text = text, face = face, bold = opts.bold }
    local fits = one:getSize().w <= width
    if fits then
        one:free()
        return TextWidget:new{
            text = text, face = face, bold = opts.bold, fgcolor = opts.fgcolor, bgcolor = opts.bgcolor,
        }
    end
    one:free()
    if lines <= 1 then
        return TextWidget:new{
            text = text, face = face, bold = opts.bold, fgcolor = opts.fgcolor, bgcolor = opts.bgcolor,
            max_width = width, truncate_with_ellipsis = true,
        }
    end
    local probe = TextBoxWidget:new{
        text = "A" .. ("\nA"):rep(lines - 1), face = face, width = width, bold = opts.bold,
    }
    local h = probe:getSize().h
    probe:free()
    return TextBoxWidget:new{
        text = text, face = face, width = width, bold = opts.bold, fgcolor = opts.fgcolor,
        bgcolor = opts.bgcolor, height_overflow_show_ellipsis = true, height = h,
    }
end

local function styleCount(counts)
    local n = 0
    for _k, v in pairs(counts.styles) do if v > 0 then n = n + 1 end end
    return n
end

-- Is there anything to filter by? (One kind and one style: no filter pill.)
local function canFilter(counts)
    if counts.all < 2 then return false end
    if counts.bookmark > 0 and counts.highlight > 0 then return true end
    if counts.note > 0 and counts.note < counts.all then return true end
    return styleCount(counts) >= 2
end

-- Paints a colour rectangle the way the book paints a highlight: with the
-- screen's blend where it has colour, plain otherwise.
local function paintColorRect(bb, x, y, w, h, color)
    if w <= 0 or h <= 0 then return end
    if bb.blendRectRGB32 then bb:blendRectRGB32(x, y, w, h, color)
    elseif bb.paintRectRGB32 then bb:paintRectRGB32(x, y, w, h, color)
    else bb:paintRect(x, y, w, h, color) end
end

-- A filled circle of the highlight's colour, painted line by line so it works
-- with the screen's colour blend and on a black and white screen alike.
local function paintColorCircle(bb, x, y, d, color)
    local r = d / 2
    for j = 0, d - 1 do
        local dy = j + 0.5 - r
        local half = math.floor(math.sqrt(math.max(0, r * r - dy * dy)) + 0.5)
        if half > 0 then paintColorRect(bb, x + math.floor(r) - half, y + j, 2 * half, 1, color) end
    end
end

-- A small plain dot of the highlight's colour.
local ColorDot = Widget:extend{ d = 0, color = nil }
function ColorDot:getSize() return Geom:new{ w = self.d, h = self.d } end
function ColorDot:free() end
function ColorDot:paintTo(bb, x, y) paintColorCircle(bb, x, y, self.d, self.color) end

-- The icon of an annotation in a d x d box.
local function entryBadge(e, d, icon_sz)
    return CenterContainer:new{
        dimen = Geom:new{ w = d, h = d },
        OptionSheet.iconWidget(entryIcon(e), icon_sz, BLACK),
    }
end

-- The filter pill of the title bar: the kind in words (All, Bookmarks,
-- Highlights, Notes), the highlight style as its icon, a chevron. Black when a
-- filter is on. Returns the pill and its width, or nothing when there is
-- nothing to filter by.
local function filterPill(f, counts, height, inner_w)
    if not canFilter(counts) then return nil, 0 end
    local active = (f.kind ~= nil or f.style ~= nil)
    local kinds = { bookmark = _("Bookmarks"), highlight = _("Highlights"), note = _("Notes") }
    local px = U(14)
    local row = HorizontalGroup:new{ align = "center" }
    local w = 2 * px
    if f.kind or not f.style then
        local label = TextWidget:new{
            text = f.kind and kinds[f.kind] or _("All"), face = KoboldWidgets.face(15), bold = true,
            fgcolor = active and WHITE or BLACK, max_width = math.floor(inner_w * 0.3),
        }
        row[#row + 1] = label
        w = w + label:getSize().w
    end
    if f.style then
        if #row > 0 then
            row[#row + 1] = HorizontalSpan:new{ width = U(8) }
            w = w + U(8)
        end
        local icon = OptionSheet.iconWidget(STYLE_ICON[f.style] or "droplet", U(18), BLACK)
        row[#row + 1] = active and KoboldWidgets.inverted(icon) or icon
        w = w + U(18)
    end
    local chev = OptionSheet.iconWidget("chevron-down", U(14), BLACK)
    row[#row + 1] = HorizontalSpan:new{ width = U(8) }
    row[#row + 1] = active and KoboldWidgets.inverted(chev) or chev
    w = w + U(8) + U(14)
    return pill(w, height, active and BLACK or SOFT, row), w
end

-- Text cut into lines no wider than max_w, at spaces; a word wider than a
-- whole line is cut by letters. measure(str) gives a width in pixels.
local function wrapWords(measure, text, max_w)
    local lines = {}
    for para in (text .. "\n"):gmatch("(.-)\n") do
        if para == "" then
            lines[#lines + 1] = ""
        else
            local cur = ""
            for word in para:gmatch("%S+") do
                local cand = (cur == "") and word or (cur .. " " .. word)
                if measure(cand) <= max_w then
                    cur = cand
                else
                    if cur ~= "" then lines[#lines + 1] = cur; cur = "" end
                    if measure(word) <= max_w then
                        cur = word
                    else
                        local piece = ""
                        for ch in word:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                            if piece == "" or measure(piece .. ch) <= max_w then
                                piece = piece .. ch
                            else
                                lines[#lines + 1] = piece
                                piece = ch
                            end
                        end
                        cur = piece
                    end
                end
            end
            lines[#lines + 1] = cur
        end
    end
    return lines
end

local function makeMeasure(face, bold)
    local cache = {}
    return function(str)
        if str == "" then return 0 end
        local w = cache[str]
        if not w then
            local t = TextWidget:new{ text = str, face = face, bold = bold }
            w = t:getSize().w
            t:free()
            cache[str] = w
        end
        return w
    end
end

-- The quote of a highlight, painted the way the book paints it: a colour
-- behind each line (normal), a line under it (underline), through it
-- (strikethrough) or white on black (invert). Shows `vis` lines from `first`;
-- a small chevron at the right says there is more above or below.
local QuoteBlock = Widget:extend{
    lines = nil, widths = nil, first = 1, vis = 1, line_h = 0, width = 0,
    style = "normal", color = nil, face = nil,
}

function QuoteBlock:init()
    self.tws = {}
    local fg = (self.style == "invert") and WHITE or BLACK
    for i = 0, self.vis - 1 do
        local ln = self.lines[self.first + i]
        if not ln then break end
        if ln ~= "" then
            self.tws[i] = TextWidget:new{ text = ln, face = self.face, bold = true, fgcolor = fg }
        end
    end
    local total = #self.lines
    local isz = U(14)
    if self.first > 1 then self.up = OptionSheet.iconWidget("chevron-up", isz, BLACK) end
    if self.first + self.vis - 1 < total then self.down = OptionSheet.iconWidget("chevron-down", isz, BLACK) end
end

function QuoteBlock:getSize()
    return Geom:new{ w = self.width, h = self.vis * self.line_h }
end

function QuoteBlock:free()
    for _i, t in pairs(self.tws or {}) do pcall(function() t:free() end) end
    self.tws = {}
    if self.up then pcall(function() self.up:free() end) end
    if self.down then pcall(function() self.down:free() end) end
end

function QuoteBlock:paintTo(bb, x, y)
    local lh = self.line_h
    for i = 0, self.vis - 1 do
        local li = self.first + i
        local ln = self.lines[li]
        if not ln then break end
        local lw = self.widths[li]
        local ly = y + i * lh
        local tw = self.tws[i]
        if ln ~= "" and tw then
            if self.style == "invert" then
                bb:paintRect(x, ly, lw, lh, BLACK)
                tw:paintTo(bb, x, ly)
            else
                if self.style == "normal" then paintColorRect(bb, x, ly, lw, lh, self.color) end
                tw:paintTo(bb, x, ly)
                if self.style == "underline" then
                    paintColorRect(bb, x, ly + lh - U(3), lw, U(2), self.color)
                elseif self.style == "strikethrough" then
                    paintColorRect(bb, x, ly + math.floor(lh / 2), lw, U(2), self.color)
                end
            end
        end
    end
    if self.up then self.up:paintTo(bb, x + self.width - U(14), y) end
    if self.down then self.down:paintTo(bb, x + self.width - U(14), y + self.vis * lh - U(14)) end
end

-- The row of dots at the bottom of one annotation: one for each annotation of
-- the list, the current one bigger and black.
local NavDots = Widget:extend{ n = 1, idx = 1, width = 0, height = 0, pitch = 0, r = 2, rmax = 3 }

function NavDots:getSize() return Geom:new{ w = self.width, h = self.height } end
function NavDots:free() end

function NavDots:paintTo(bb, x, y)
    local dots_w = (self.n - 1) * self.pitch + 2 * self.rmax
    local x0 = x + math.floor((self.width - dots_w) / 2) + self.rmax
    local cy = y + math.floor(self.height / 2)
    for i = 1, self.n do
        local cur = (i == self.idx)
        local r = cur and self.rmax or self.r
        bb:paintRoundedRect(x0 + (i - 1) * self.pitch - r, cy - r, 2 * r, 2 * r,
            cur and BLACK or Blitbuffer.COLOR_DARK_GRAY, r)
    end
end

-- Loads the book's annotations and shows the list.
function KoboldBookDetails:openAnnotations()
    self.ann_all = Annotations.load(self.file)
    self.ann_counts = Annotations.counts(self.ann_all)
    self.ann_filter = {}
    self.ann_list = self.ann_all
    self.ann_page = 1
    self.ann_idx = 1
    self.view = "annotations"
    self:refresh()
end

function KoboldBookDetails:closeAnnotations()
    self.view = "details"
    self.ann_rects = nil
    self:refresh()
end

function KoboldBookDetails:applyAnnotationFilter()
    self.ann_list = Annotations.filter(self.ann_all, self.ann_filter)
    self.ann_page = 1
end

-- The filter pill: the option sheet with what to show and, when the book has
-- several, the highlight style. Every tap filters at once: the part of the
-- sheet the option sheet does not cover is drawn again behind it. It works the
-- same from the list and from one annotation.
function KoboldBookDetails:openAnnotationFilter()
    local f = self.ann_filter
    local c = self.ann_counts
    local sheet
    local function withCount(label, n) return string.format("%s (%d)", label, n) end

    local function changed()
        if self.closed then return end
        local current = (self.ann_list or {})[self.ann_idx or 1]
        self:applyAnnotationFilter()
        if self.view == "annotation" then
            -- stays on the same annotation when the filter keeps it
            local keep
            for i, e in ipairs(self.ann_list) do
                if e == current then keep = i break end
            end
            self.ann_idx = keep or 1
            self.ann_q_first = 1
            if #self.ann_list == 0 then self.view = "annotations" end
        end
        local region = self.panel_rect
        local sr = sheet and sheet:region()
        if sr then
            region = Geom:new{ x = region.x, y = region.y, w = region.w, h = math.max(1, sr.y - region.y) }
        end
        self:refresh(region)
    end

    -- No "All" chip: with no chip chosen everything shows.
    local kind_options = {}
    if c.bookmark > 0 then
        kind_options[#kind_options + 1] = { id = "bookmark", label = withCount(_("Bookmarks"), c.bookmark), icon = "bookmark" }
    end
    if c.highlight > 0 then
        kind_options[#kind_options + 1] = { id = "highlight", label = withCount(_("Highlights"), c.highlight) }
    end
    if c.note > 0 then
        kind_options[#kind_options + 1] = { id = "note", label = withCount(_("Notes"), c.note) }
    end
    local kind_row = { label = _("Show"), options = kind_options, selected = f.kind, toggle = true }
    local rows = { kind_row }

    local style_row
    if styleCount(c) >= 2 then
        local defs = {
            { id = "normal", label = _("Highlight"), icon = "droplet" },
            { id = "underline", label = _("Underline"), icon = "underline" },
            { id = "invert", label = _("Invert"), icon = "contrast" },
            { id = "strikethrough", label = _("Strikethrough"), icon = "strikethrough" },
        }
        local options = {}
        for _i, d in ipairs(defs) do
            if (c.styles[d.id] or 0) > 0 then
                options[#options + 1] = { id = d.id, label = d.label, icon = d.icon }
            end
        end
        style_row = { label = _("Highlight style"), options = options, selected = f.style, toggle = true }
        rows[#rows + 1] = style_row
    end

    kind_row.on_pick = function(id)
        f.kind = id
        -- a bookmark has no style
        if f.kind == "bookmark" then
            f.style = nil
            if style_row then style_row.selected = nil end
        end
        changed()
    end
    if style_row then
        style_row.on_pick = function(id)
            f.style = id
            -- a style only exists on highlights
            if id and f.kind == "bookmark" then
                f.kind = "highlight"
                kind_row.selected = "highlight"
            end
            changed()
        end
    end

    sheet = OptionSheet.show{
        title = _("Filter"), rows = rows,
        anchor = self.panel_rect, bottom_radius = U(22),
    }
end

function KoboldBookDetails:buildAnnotations(level)
    level = level or 1
    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    self.panel_rect = R

    local file = self.file
    local props = bookProps(file)
    local book_title = props.title or (file:match("([^/]+)$") or file)
    local f = self.ann_filter or {}
    local list = self.ann_list or {}
    local counts = self.ann_counts or Annotations.counts(self.ann_all or {})

    local rects = { rows = {} }
    self.ann_rects = rects

    -- Title bar: back and the name on the left; on the right the filter pill
    -- (when there is something to filter by) and close.
    local close_d = U(36)
    local back_button = pill(close_d, close_d, SOFT, OptionSheet.iconWidget("chevron-left", U(18), BLACK))
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local right_group = HorizontalGroup:new{ align = "center" }
    local pill_widget, filter_w = filterPill(f, counts, close_d, inner_w)
    if pill_widget then
        right_group[#right_group + 1] = pill_widget
        right_group[#right_group + 1] = HorizontalSpan:new{ width = U(14) }
        rects.filter = Geom:new{
            x = x0 + inner_w - close_d - U(14) - filter_w, y = y0, w = filter_w, h = top_h,
        }
    end
    right_group[#right_group + 1] = close_button
    local heading_w = inner_w - (filter_w > 0 and (filter_w + U(14)) or 0) - 2 * close_d - U(24)
    local top_left = HorizontalGroup:new{
        align = "center",
        back_button,
        HorizontalSpan:new{ width = U(12) },
        TextWidget:new{
            text = _("Annotations"), face = KoboldWidgets.face(19), bold = true,
            max_width = math.max(U(60), heading_w),
        },
    }
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, right_group },
    }
    rects.back = Geom:new{
        x = R.x, y = R.y, w = border + pad + close_d + U(12), h = top_h + pad + border,
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- The book's name (and how many annotations the filter leaves).
    local sub_gap = U(M.info_gap)
    local sub_text = book_title
    if props.authors then sub_text = book_title .. "  ·  " .. (props.authors:gsub("\n", ", ")) end
    local subtitle = TextWidget:new{
        text = sub_text, face = KoboldWidgets.face(M.font + 1),
        fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w,
    }
    local sub_h = subtitle:getSize().h

    -- Rows: as many as fit, the rest on the next pages.
    local main_face = KoboldWidgets.face(M.font + 2)
    local meta_face = KoboldWidgets.face(M.font - 1)
    local probe_main = TextWidget:new{ text = "Ag", face = main_face }
    local probe_meta = TextWidget:new{ text = "Ag", face = meta_face }
    local main_lh, meta_lh = probe_main:getSize().h, probe_meta:getSize().h
    probe_main:free()
    probe_meta:free()
    local row_pad = U(M.row_pad + 3)
    local row_h = 2 * main_lh + U(3) + meta_lh + 2 * row_pad
    local line_h = U(1)
    local card_pad = U(M.card_pad)
    local foot_h = U(M.button)
    local list_y = y0 + top_h + sub_gap + sub_h + gap
    local avail_h = inner_h - (top_h + sub_gap + sub_h + gap)
    local function fit(h)
        return math.max(1, math.floor((h - 2 * card_pad + line_h) / (row_h + line_h)))
    end
    local per_page = fit(avail_h)
    if #list > per_page then per_page = fit(avail_h - gap - foot_h) end
    if per_page < 3 and level < #LEVELS then return self:buildAnnotations(level + 1) end
    local pages = math.max(1, math.ceil(#list / per_page))
    local page = math.max(1, math.min(self.ann_page or 1, pages))
    self.ann_page, self.ann_per_page = page, per_page
    local first_i = (page - 1) * per_page + 1
    local last_i = math.min(#list, first_i + per_page - 1)

    local card_w = inner_w - 2 * card_pad
    local rows = VerticalGroup:new{ align = "left" }
    local card_h
    if #list == 0 then
        local text = (#(self.ann_all or {}) == 0) and _("No annotations yet.") or _("Nothing matches this filter.")
        local empty_h = 2 * U(M.row)
        rows[#rows + 1] = CenterContainer:new{
            dimen = Geom:new{ w = card_w, h = empty_h },
            TextWidget:new{
                text = text, face = italicFace(M.font + 3), bgcolor = SOFT,
                fgcolor = KoboldWidgets.subtitleColor(), max_width = card_w - U(20),
            },
        }
        card_h = empty_h + 2 * card_pad
    else
        local badge_d = U(30)
        local icon_sz = U(18)
        local icon_col = badge_d + U(12)
        local chevron_w = U(16)
        -- A highlight's colour is a small dot that starts the third line (the
        -- chapter and page), so the quote above keeps the whole width.
        local dot_d, dot_gap = U(8), U(8)
        for i = first_i, last_i do
            local e = list[i]
            if i > first_i then
                rows[#rows + 1] = LineWidget:new{ dimen = Geom:new{ w = card_w, h = line_h }, background = LINE }
            end
            local note_w = e.note and (U(14) + U(8)) or 0
            local text_w = card_w - icon_col - chevron_w - U(10) - note_w
            local main_text, meta_text = rowTexts(e, f.kind == "note")
            local main = limitedText(main_text, main_face, text_w, 2, { bgcolor = SOFT })
            local has_dot = e.kind == "highlight" and e.color
            local meta = TextWidget:new{
                text = meta_text, face = meta_face, fgcolor = KoboldWidgets.subtitleColor(), bgcolor = SOFT,
                max_width = has_dot and (text_w - dot_d - dot_gap) or text_w, truncate_with_ellipsis = true,
            }
            if has_dot then
                meta = HorizontalGroup:new{
                    align = "center",
                    ColorDot:new{ d = dot_d, color = Annotations.resolveColor(e.color) },
                    HorizontalSpan:new{ width = dot_gap },
                    meta,
                }
            end
            local right = HorizontalGroup:new{ align = "center" }
            if e.note then
                right[#right + 1] = OptionSheet.iconWidget("pencil", U(14), KoboldWidgets.subtitleColor())
                right[#right + 1] = HorizontalSpan:new{ width = U(8) }
            end
            right[#right + 1] = OptionSheet.iconWidget("chevron-right", chevron_w, KoboldWidgets.subtitleColor())
            rows[#rows + 1] = OverlapGroup:new{
                dimen = Geom:new{ w = card_w, h = row_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = card_w, h = row_h },
                    HorizontalGroup:new{
                        align = "center",
                        entryBadge(e, badge_d, icon_sz),
                        HorizontalSpan:new{ width = U(12) },
                        VerticalGroup:new{
                            align = "left",
                            main,
                            VerticalSpan:new{ width = U(3) },
                            meta,
                        },
                    },
                },
                RightContainer:new{ dimen = Geom:new{ w = card_w, h = row_h }, right },
            }
            rects.rows[#rects.rows + 1] = {
                index = i,
                rect = Geom:new{
                    x = x0, y = list_y + card_pad + (i - first_i) * (row_h + line_h),
                    w = inner_w, h = row_h,
                },
            }
        end
        local shown = last_i - first_i + 1
        card_h = shown * row_h + (shown - 1) * line_h + 2 * card_pad
    end
    local card = FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        rows,
    }

    -- The foot: previous page, "2 / 5", next page (only with several pages).
    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = sub_gap },
        subtitle,
        VerticalSpan:new{ width = gap },
        card,
    }
    local used = top_h + sub_gap + sub_h + gap + card_h
    if pages > 1 then
        local btn_w = U(64)
        local grey = Blitbuffer.Color8(0xAA)
        local function navPill(icon, on)
            return pill(btn_w, foot_h, SOFT, OptionSheet.iconWidget(icon, U(18), on and BLACK or grey))
        end
        local foot = OverlapGroup:new{
            dimen = Geom:new{ w = inner_w, h = foot_h },
            LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = foot_h }, navPill("chevron-left", page > 1) },
            CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = foot_h },
                TextWidget:new{ text = page .. " / " .. pages, face = KoboldWidgets.face(16), bold = true },
            },
            RightContainer:new{ dimen = Geom:new{ w = inner_w, h = foot_h }, navPill("chevron-right", page < pages) },
        }
        local foot_y = y0 + inner_h - foot_h
        rects.prev = Geom:new{ x = x0, y = foot_y, w = btn_w, h = foot_h }
        rects.next = Geom:new{ x = x0 + inner_w - btn_w, y = foot_y, w = btn_w, h = foot_h }
        rects.foot = Geom:new{ x = x0, y = foot_y, w = inner_w, h = foot_h }
        column[#column + 1] = VerticalSpan:new{ width = math.max(0, inner_h - used - foot_h) }
        column[#column + 1] = foot
    else
        -- the sheet keeps its size, whatever the card takes
        column[#column + 1] = VerticalSpan:new{ width = math.max(0, inner_h - used) }
    end
    local panel = FrameContainer:new{
        bordersize = border, padding = pad, radius = radius, background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

-- One annotation of the list (self.ann_idx), laid out like Page Scrubber's
-- detail panel.
function KoboldBookDetails:buildAnnotation(level)
    level = level or 1
    local list = self.ann_list or {}
    local n = #list
    local idx = math.max(1, math.min(self.ann_idx or 1, math.max(n, 1)))
    local e = list[idx]
    if not e then   -- the list is empty now: back to it
        self.view = "annotations"
        return self:buildAnnotations()
    end
    self.ann_idx = idx

    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    self.panel_rect = R

    local rects = {}
    self.ann_rects = rects

    -- Title bar: back, the type and colour, close.
    local close_d = U(36)
    local back_button = pill(close_d, close_d, SOFT, OptionSheet.iconWidget("chevron-left", U(18), BLACK))
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local right_group = HorizontalGroup:new{ align = "center" }
    local pill_widget, filter_w = filterPill(self.ann_filter or {}, self.ann_counts or Annotations.counts(self.ann_all or {}), close_d, inner_w)
    if pill_widget then
        right_group[#right_group + 1] = pill_widget
        right_group[#right_group + 1] = HorizontalSpan:new{ width = U(14) }
        rects.filter = Geom:new{
            x = x0 + inner_w - close_d - U(14) - filter_w, y = y0, w = filter_w, h = top_h,
        }
    end
    right_group[#right_group + 1] = close_button
    local top_left = HorizontalGroup:new{
        align = "center",
        back_button,
        HorizontalSpan:new{ width = U(12) },
        TextWidget:new{
            text = entryTitle(e), face = KoboldWidgets.face(19), bold = true,
            max_width = math.max(U(60), inner_w - 2 * close_d - U(36) - (filter_w > 0 and (filter_w + U(14)) or 0)),
            truncate_with_ellipsis = true,
        },
    }
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, right_group },
    }
    rects.back = Geom:new{
        x = R.x, y = R.y, w = border + pad + close_d + U(12), h = top_h + pad + border,
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- The date, in italics, under the title.
    local sub_gap = U(M.info_gap)
    local date_text = Annotations.formatDate(e.date)
    local date_w
    local date_h = 0
    if date_text then
        date_w = TextWidget:new{
            text = date_text, face = italicFace(M.font),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = inner_w,
        }
        date_h = date_w:getSize().h
    end

    -- The icon of the type and the chapter beside it; everything under them
    -- (the quote, the note) lines up with the chapter.
    local icon_sz = U(20)
    local indent = icon_sz + U(12)
    local col_w = inner_w - indent
    local chapter_text = e.chapter and oneLine(e.chapter) or nil
    local chapter_w = chapter_text and limitedText(chapter_text, KoboldWidgets.face(M.font + 2), col_w, 2) or nil
    local chapter_h = chapter_w and chapter_w:getSize().h or 0
    local head_h = math.max(icon_sz, chapter_h)
    local head_row = HorizontalGroup:new{
        align = "center",
        OptionSheet.iconWidget(entryIcon(e), icon_sz, BLACK),
        HorizontalSpan:new{ width = U(12) },
        chapter_w or HorizontalSpan:new{ width = 0 },
    }

    -- The foot: the link to the book and the dots.
    local link_h = U(36)
    local nav_h = U(40)
    local link_text = _("Show in book")
    if e.page then link_text = link_text .. " - " .. _("Page") .. " " .. e.page end
    local link_label = TextWidget:new{
        text = link_text, face = KoboldWidgets.face(M.font + 1), bold = true, max_width = inner_w,
    }
    local link_label_w = link_label:getSize().w
    local link_row = CenterContainer:new{
        dimen = Geom:new{ w = inner_w, h = link_h },
        VerticalGroup:new{
            align = "center",
            link_label,
            LineWidget:new{ dimen = Geom:new{ w = link_label_w, h = math.max(1, U(2)) }, background = BLACK },
        },
    }

    local top_used = top_h + (date_w and (sub_gap + date_h) or 0) + gap + head_h + gap
    local avail = inner_h - top_used - link_h - nav_h
    if avail < U(80) and level < #LEVELS then return self:buildAnnotation(level + 1) end
    local content_y = y0 + top_used   -- screen y where the quote starts

    -- The quote and the note share what is left (as in Page Scrubber: when both
    -- are long the note gets about two fifths, never less than two lines).
    local q_face = KoboldWidgets.face(M.font + 1)
    local probe = TextWidget:new{ text = "Ag", face = q_face, bold = true }
    local qlh = probe:getSize().h + U(2)
    probe:free()
    local note_face = KoboldWidgets.face(M.font + 1)
    local quote_lines, quote_widths
    if e.text then
        local measure = makeMeasure(q_face, true)
        quote_lines = wrapWords(measure, e.text, col_w - U(18))
        quote_widths = {}
        for i, ln in ipairs(quote_lines) do quote_widths[i] = measure(ln) end
    end
    local pencil_h = U(16)
    local note_hdr = e.note and (pencil_h + U(4)) or 0
    local div = (quote_lines and e.note) and U(12) or 0
    local space = avail - div - note_hdr
    local nat_q = quote_lines and (#quote_lines * qlh) or 0
    local nat_n = 0
    if e.note then
        local t = TextBoxWidget:new{ text = e.note, face = note_face, width = col_w }
        nat_n = t:getSize().h
        t:free()
    end
    local q_h, n_h = nat_q, nat_n
    local limited = false
    if nat_q + nat_n > space then
        limited = true
        if quote_lines and e.note then
            n_h = math.min(nat_n, math.max(2 * qlh, math.floor(space * 0.4)))
            q_h = space - n_h
            if nat_q < q_h then q_h = nat_q; n_h = math.min(nat_n, space - q_h) end
        elseif quote_lines then
            q_h = space
        else
            n_h = space
        end
    end

    local body = VerticalGroup:new{ align = "left" }
    local body_used = 0
    if quote_lines then
        local vis = #quote_lines
        if limited then
            vis = math.max(1, math.floor(q_h / qlh))
            q_h = vis * qlh
        end
        local first = math.max(1, math.min(self.ann_q_first or 1, math.max(1, #quote_lines - vis + 1)))
        self.ann_q_first = first
        local style = e.style or "normal"
        local block = QuoteBlock:new{
            lines = quote_lines, widths = quote_widths, first = first, vis = vis,
            line_h = qlh, width = col_w, face = q_face, style = style,
            color = (style ~= "invert") and Annotations.resolveColor(e.color or "yellow") or nil,
        }
        body[#body + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = indent }, block }
        rects.quote = Geom:new{ x = x0, y = content_y, w = inner_w, h = q_h }
        rects.quote_vis, rects.quote_total = vis, #quote_lines
        body_used = body_used + q_h
        if e.note then
            body[#body + 1] = VerticalSpan:new{ width = U(12) }
            body_used = body_used + U(12)
        end
    end
    if e.note then
        local note_y = content_y + body_used
        body[#body + 1] = HorizontalGroup:new{
            HorizontalSpan:new{ width = indent },
            OptionSheet.iconWidget("pencil", pencil_h, BLACK),
        }
        body[#body + 1] = VerticalSpan:new{ width = U(4) }
        local note_widget
        if limited then
            note_widget = ScrollTextWidget:new{
                text = e.note, face = note_face, width = col_w, height = math.max(qlh, n_h), dialog = self,
            }
        else
            note_widget = TextBoxWidget:new{ text = e.note, face = note_face, width = col_w }
        end
        body[#body + 1] = HorizontalGroup:new{ HorizontalSpan:new{ width = indent }, note_widget }
        rects.note = Geom:new{ x = x0, y = note_y + note_hdr, w = inner_w, h = n_h }
        body_used = body_used + note_hdr + n_h
    end
    if body_used == 0 then
        -- a bookmark with nothing else to say: a quiet bookmark in the middle
        body[#body + 1] = CenterContainer:new{
            dimen = Geom:new{ w = inner_w, h = avail },
            OptionSheet.iconWidget("bookmark", U(56), Blitbuffer.Color8(0xBB)),
        }
        body_used = avail
    end

    -- The dots (or "2 / 9" with arrows when there are too many to fit).
    local nav
    local nav_y = y0 + inner_h - nav_h
    if n > 1 then
        local dot_r = math.max(2, math.floor(U(2.5)))
        local dot_rmax = math.floor(dot_r * 1.5)
        local min_pitch = 2 * dot_r + U(3)
        local pitch = math.floor(math.min(U(11), (inner_w - 2 * dot_rmax) / (n - 1)))
        if pitch >= min_pitch then
            nav = NavDots:new{
                n = n, idx = idx, width = inner_w, height = nav_h,
                pitch = pitch, r = dot_r, rmax = dot_rmax,
            }
            local dots_w = (n - 1) * pitch + 2 * dot_rmax
            rects.dots = {
                rect = Geom:new{ x = x0, y = nav_y, w = inner_w, h = nav_h },
                x0 = x0 + math.floor((inner_w - dots_w) / 2) + dot_rmax, pitch = pitch,
            }
        else
            local grey = Blitbuffer.Color8(0xAA)
            local btn_w = U(64)
            nav = OverlapGroup:new{
                dimen = Geom:new{ w = inner_w, h = nav_h },
                LeftContainer:new{
                    dimen = Geom:new{ w = inner_w, h = nav_h },
                    OptionSheet.iconWidget("chevron-left", U(18), idx > 1 and BLACK or grey),
                },
                CenterContainer:new{
                    dimen = Geom:new{ w = inner_w, h = nav_h },
                    TextWidget:new{ text = idx .. " / " .. n, face = KoboldWidgets.face(15), bold = true },
                },
                RightContainer:new{
                    dimen = Geom:new{ w = inner_w, h = nav_h },
                    OptionSheet.iconWidget("chevron-right", U(18), idx < n and BLACK or grey),
                },
            }
            rects.prev = Geom:new{ x = x0, y = nav_y, w = btn_w, h = nav_h }
            rects.next = Geom:new{ x = x0 + inner_w - btn_w, y = nav_y, w = btn_w, h = nav_h }
        end
    end
    rects.link = Geom:new{ x = x0, y = nav_y - link_h, w = inner_w, h = link_h }

    local column = VerticalGroup:new{ align = "left", top_bar }
    if date_w then
        column[#column + 1] = VerticalSpan:new{ width = sub_gap }
        column[#column + 1] = date_w
    end
    column[#column + 1] = VerticalSpan:new{ width = gap }
    column[#column + 1] = head_row
    column[#column + 1] = VerticalSpan:new{ width = gap }
    column[#column + 1] = body
    column[#column + 1] = VerticalSpan:new{ width = math.max(0, avail - body_used) }
    column[#column + 1] = link_row
    column[#column + 1] = nav or VerticalSpan:new{ width = nav_h }
    local panel = FrameContainer:new{
        bordersize = border, padding = pad, radius = radius, background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

-- The list shows entry `i`.
function KoboldBookDetails:openAnnotation(i)
    self.ann_idx = i
    self.ann_q_first = 1
    self.view = "annotation"
    self:refresh()
end

-- Back to the list, on the page the annotation is on.
function KoboldBookDetails:closeAnnotation()
    local per_page = math.max(1, self.ann_per_page or 1)
    self.ann_page = math.max(1, math.ceil((self.ann_idx or 1) / per_page))
    self.view = "annotations"
    self.ann_rects = nil
    self:refresh()
end

-- Another annotation of the list (by -1 or +1, or straight to index `to`).
function KoboldBookDetails:stepAnnotation(by, to)
    local n = #(self.ann_list or {})
    local new = to or ((self.ann_idx or 1) + by)
    new = math.max(1, math.min(n, new))
    if new == self.ann_idx then return end
    self.ann_idx = new
    self.ann_q_first = 1
    self:refresh()
end

function KoboldBookDetails:stepAnnotationPage(by)
    local per_page = math.max(1, self.ann_per_page or 1)
    local pages = math.max(1, math.ceil(#(self.ann_list or {}) / per_page))
    local new = math.max(1, math.min(pages, (self.ann_page or 1) + by))
    if new == self.ann_page then return end
    self.ann_page = new
    self:refresh()
end

function KoboldBookDetails:onAnnotationsTap(pos)
    local r = self.ann_rects
    if not r then return end
    local function hit(rect) return rect and pos:intersectWith(rect) end
    if hit(r.filter) then return self:openAnnotationFilter() end
    if hit(self.close_rect) then return self:dismiss() end
    if hit(r.back) then return self:closeAnnotations() end
    if hit(r.prev) then return self:stepAnnotationPage(-1) end
    if hit(r.next) then return self:stepAnnotationPage(1) end
    for _i, row in ipairs(r.rows) do
        if hit(row.rect) then return self:openAnnotation(row.index) end
    end
end

function KoboldBookDetails:onAnnotationTap(pos)
    local r = self.ann_rects
    if not r then return end
    local function hit(rect) return rect and pos:intersectWith(rect) end
    if hit(r.filter) then return self:openAnnotationFilter() end
    if hit(self.close_rect) then return self:dismiss() end
    if hit(r.back) then return self:closeAnnotation() end
    if hit(r.link) then
        local e = (self.ann_list or {})[self.ann_idx or 1]
        if e then self:openBook(e.item) end
        return
    end
    if hit(r.prev) then return self:stepAnnotation(-1) end
    if hit(r.next) then return self:stepAnnotation(1) end
    if r.dots and hit(r.dots.rect) then
        local i = math.floor((pos.x - r.dots.x0) / r.dots.pitch + 0.5) + 1
        return self:stepAnnotation(0, i)
    end
end

-- A swipe that nothing under it took: sideways turns the page of the list, or
-- moves to the previous / next annotation; up and down on a long quote scroll it.
function KoboldBookDetails:onDetailsSwipe(ges)
    if self.opening then return false end
    local dir = ges.direction
    if self.view == "annotations" then
        if dir == "west" then self:stepAnnotationPage(1) return true end
        if dir == "east" then self:stepAnnotationPage(-1) return true end
    elseif self.view == "settings" then
        if dir == "west" then self:stepSettingsPage(1) return true end
        if dir == "east" then self:stepSettingsPage(-1) return true end
    elseif self.view == "annotation" then
        if dir == "west" then self:stepAnnotation(1) return true end
        if dir == "east" then self:stepAnnotation(-1) return true end
        local r = self.ann_rects
        if (dir == "north" or dir == "south") and r and r.quote and ges.pos
            and ges.pos:intersectWith(r.quote) and r.quote_total and r.quote_total > r.quote_vis then
            local step = math.max(1, r.quote_vis - 1)
            local first = (self.ann_q_first or 1) + (dir == "north" and step or -step)
            first = math.max(1, math.min(first, r.quote_total - r.quote_vis + 1))
            if first ~= self.ann_q_first then
                self.ann_q_first = first
                self:refresh(r.quote)
            end
            return true
        end
    end
    return false
end

function KoboldBookDetails:build(level)
    if self.view == "editor" then return self:buildEditor() end
    if self.view == "annotation" then return self:buildAnnotation(level) end
    if self.view == "annotations" then return self:buildAnnotations(level) end
    if self.view == "metadata" then return self:buildMetadata(level) end
    if self.view == "settings" then return self:buildSettings(level) end
    if self.view == "edit" then return self:buildEdit(level) end
    return self:buildDetails(level)
end

-- ── Moving between the two screens, saving ─────────────────────────────────

function KoboldBookDetails:openEdit()
    self.rv = Review.get(self.file)
    self.view = "edit"
    self:refresh()
end

function KoboldBookDetails:closeEdit()
    self.view = "details"
    self.edit_rects = nil
    self:refresh()
end

-- Once the page is gone, if Edit saved anything: Home and the Library show the
-- new status, Favorites or metadata. A change of metadata is announced to
-- everyone (KOReader and Kobold's own screens reload from it); the rest only
-- needs on_change.
function KoboldBookDetails:notifyChange()
    if not self.changed then return end
    self.changed = false
    local announce = self.meta_changed
    self.meta_changed = false
    local callback = self.on_change
    local file = self.file
    UIManager:nextTick(function()
        if announce then
            Metadata.announce(file)
        elseif callback then
            pcall(callback)
        end
    end)
end

function KoboldBookDetails:toggleFavorite()
    local rv = self.rv
    local want = not rv.favorite
    if Review.setFavorite(self.file, want) then
        rv.favorite = want
        self.changed = true
        self:refresh(self.edit_rects.bar)
    else
        Toast.error(_("The Favorites collection could not be changed."))
    end
end

-- Tapping the star that is already the rating clears it.
function KoboldBookDetails:setRating(n)
    local rv = self.rv
    local new = (rv.rating == n) and 0 or n
    if Review.setRating(self.file, new > 0 and new or nil) then
        rv.rating = new
        self.changed = true
        self:refresh(self.edit_rects.bar)
    else
        Toast.error(_("The rating could not be saved."))
    end
end

function KoboldBookDetails:setStatus(id)
    local rv = self.rv
    if rv.status == id then return end
    if Review.setStatus(self.file, id) then
        rv.status = id
        self.changed = true
        self:refresh(self.edit_rects.status_rect)
    else
        Toast.error(_("The status could not be saved."))
    end
end

-- ── Book settings ──────────────────────────────────────────────────────────
-- The third row of Edit. A title bar (back, name, close), a card with three
-- actions that KOReader's own menu has and Kobold did not:
--   Reset this document   erases the reading data (asks first)
--   Export notes of the document (.md)   the highlights and notes as a Markdown file
--   Refresh metadata      reads the book again (title, authors, cover...)
-- and, under it, a Plugins section: the buttons other plugins add to
-- KOReader's file dialog (data/file_dialog_buttons.lua), two to a row. When
-- they do not fit they are paged: a pager under them, or a swipe sideways.
-- With no plugin buttons the section is not there.

function KoboldBookDetails:buildSettings(level)
    level = level or 1
    local M = LEVELS[level]
    local R = KoboldPopup.panelRect()
    local border  = U(2)
    local pad     = U(M.pad)
    local radius  = U(22)   -- the sheet's corners
    local inner_w = R.w - 2 * (border + pad)
    local inner_h = R.h - 2 * (border + pad)
    local x0, y0  = R.x + border + pad, R.y + border + pad
    local top_h   = U(M.top)
    local gap     = U(M.gap)
    self.panel_rect = R

    local row_h    = U(M.row)
    local line_h   = U(1)
    local card_pad = U(M.card_pad)
    local card_h   = #SETTINGS_ROWS * row_h + (#SETTINGS_ROWS - 1) * line_h + 2 * card_pad
    local plugins  = self.plugin_buttons or {}
    local grey     = Blitbuffer.Color8(0x99)

    -- The Plugins section: how many rows of buttons fit, and whether a pager
    -- is needed. Every height is worked out before anything big is built.
    local cap_gap, cell_gap, pager_h = U(6), U(8), U(36)
    local btn_h = row_h
    local caption = TextWidget:new{
        text = _("Plugins"), face = KoboldWidgets.face(M.font), fgcolor = KoboldWidgets.subtitleColor(),
    }
    local cap_h = caption:getSize().h
    local used = top_h + gap + card_h
    local rows_fit, paged = 0, false
    if #plugins > 0 then
        local avail = inner_h - used - gap - cap_h - cap_gap
        rows_fit = math.floor((avail + cell_gap) / (btn_h + cell_gap))
        if rows_fit * 2 < #plugins then
            paged = true
            rows_fit = math.floor((avail - pager_h) / (btn_h + cell_gap))
        end
        if rows_fit < 1 then
            if level < #LEVELS then
                pcall(function() caption:free() end)
                return self:buildSettings(level + 1)
            end
            rows_fit = 1   -- the last level: at least one row, even if it overflows
        end
    end
    local per_page = math.max(1, rows_fit * 2)
    local pages = (#plugins > 0) and math.ceil(#plugins / per_page) or 1
    self.set_page = math.max(1, math.min(self.set_page or 1, pages))
    self.set_pages = pages

    local card_y = y0 + top_h + gap
    local rects = { rows = {}, buttons = {} }
    self.set_rects = rects

    -- Title bar: back on the left with the title, close on the right.
    local close_d = U(36)
    local back_button = pill(close_d, close_d, SOFT, OptionSheet.iconWidget("chevron-left", U(18), BLACK))
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local top_left = HorizontalGroup:new{
        align = "center",
        back_button,
        HorizontalSpan:new{ width = U(12) },
        TextWidget:new{ text = _("Book settings"), face = KoboldWidgets.face(19), bold = true },
    }
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, top_left },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, close_button },
    }
    rects.back = Geom:new{
        x = R.x, y = R.y, w = border + pad + close_d + U(12), h = top_h + pad + border,
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- The card of actions: an icon and the name.
    local card_w = inner_w - 2 * card_pad
    local list = VerticalGroup:new{ align = "left" }
    for i, row in ipairs(SETTINGS_ROWS) do
        if i > 1 then
            list[#list + 1] = LineWidget:new{ dimen = Geom:new{ w = card_w, h = line_h }, background = LINE }
        end
        list[#list + 1] = LeftContainer:new{
            dimen = Geom:new{ w = card_w, h = row_h },
            HorizontalGroup:new{
                align = "center",
                OptionSheet.iconWidget(row.icon, U(18), BLACK),
                HorizontalSpan:new{ width = U(12) },
                TextWidget:new{
                    text = row.text, face = KoboldWidgets.face(17),
                    max_width = card_w - U(18) - U(12),
                },
            },
        }
        rects.rows[i] = {
            id = row.id,
            rect = Geom:new{ x = x0, y = card_y + card_pad + (i - 1) * (row_h + line_h), w = inner_w, h = row_h },
        }
    end
    local card = FrameContainer:new{
        bordersize = 0, padding = card_pad, radius = U(16), background = SOFT,
        list,
    }

    local column = VerticalGroup:new{
        align = "left",
        top_bar,
        VerticalSpan:new{ width = gap },
        card,
    }

    if #plugins > 0 then
        local cap_y = card_y + card_h + gap
        column[#column + 1] = VerticalSpan:new{ width = gap }
        column[#column + 1] = caption
        column[#column + 1] = VerticalSpan:new{ width = cap_gap }
        local grid_y = cap_y + cap_h + cap_gap
        local col_w = math.floor((inner_w - cell_gap) / 2)
        local first = (self.set_page - 1) * per_page
        local visible = math.min(per_page, #plugins - first)
        local grid = VerticalGroup:new{ align = "left" }
        local nrows = math.ceil(visible / 2)
        for r = 1, nrows do
            local line = HorizontalGroup:new{ align = "top" }
            for c = 1, 2 do
                local item = plugins[first + (r - 1) * 2 + c]
                if c == 2 then line[#line + 1] = HorizontalSpan:new{ width = cell_gap } end
                if item then
                    line[#line + 1] = roundBox(col_w, btn_h, U(14), SOFT, TextWidget:new{
                        text = item.text, face = KoboldWidgets.face(16),
                        fgcolor = item.enabled and BLACK or grey, max_width = col_w - U(16),
                    })
                    rects.buttons[#rects.buttons + 1] = {
                        item = item,
                        rect = Geom:new{
                            x = x0 + (c - 1) * (col_w + cell_gap),
                            y = grid_y + (r - 1) * (btn_h + cell_gap), w = col_w, h = btn_h,
                        },
                    }
                else
                    line[#line + 1] = HorizontalSpan:new{ width = col_w }
                end
            end
            grid[#grid + 1] = line
            if r < nrows then grid[#grid + 1] = VerticalSpan:new{ width = cell_gap } end
        end
        column[#column + 1] = grid
        local grid_h = nrows * btn_h + (nrows - 1) * cell_gap
        used = used + gap + cap_h + cap_gap + grid_h
        -- the part of the sheet that changes when the page turns
        rects.plugins_area = Geom:new{ x = x0, y = grid_y, w = inner_w, h = grid_h + (paged and (cell_gap + pager_h) or 0) }
        if paged then
            local function arrow(icon, enabled)
                return pill(pager_h, pager_h, SOFT, OptionSheet.iconWidget(icon, U(16), enabled and BLACK or grey))
            end
            local label = TextWidget:new{
                text = self.set_page .. " / " .. pages, face = KoboldWidgets.face(M.font + 1),
                fgcolor = KoboldWidgets.subtitleColor(),
            }
            local label_w = label:getSize().w + U(28)
            local pager = HorizontalGroup:new{
                align = "center",
                arrow("chevron-left", self.set_page > 1),
                CenterContainer:new{ dimen = Geom:new{ w = label_w, h = pager_h }, label },
                arrow("chevron-right", self.set_page < pages),
            }
            local pager_w = 2 * pager_h + label_w
            local pager_y = grid_y + grid_h + cell_gap
            local pager_x = x0 + math.floor((inner_w - pager_w) / 2)
            column[#column + 1] = VerticalSpan:new{ width = cell_gap }
            column[#column + 1] = CenterContainer:new{
                dimen = Geom:new{ w = inner_w, h = pager_h }, pager,
            }
            rects.prev = Geom:new{ x = pager_x, y = pager_y, w = pager_h + math.floor(label_w / 2), h = pager_h }
            rects.next = Geom:new{
                x = pager_x + pager_h + math.floor(label_w / 2), y = pager_y,
                w = pager_h + math.ceil(label_w / 2), h = pager_h,
            }
            used = used + cell_gap + pager_h
        end
    end
    -- the sheet keeps its size, whatever the rows take
    column[#column + 1] = VerticalSpan:new{ width = math.max(0, inner_h - used) }
    local panel = FrameContainer:new{
        bordersize = border, padding = pad, radius = radius, background = WHITE,
        column,
    }
    return KoboldPopup.place(self.dimen, R.x, R.y, panel)
end

function KoboldBookDetails:openSettings()
    self.set_page = 1
    self.plugin_buttons = FDButtons.collect(self.file)
    self.view = "settings"
    self:refresh()
end

function KoboldBookDetails:closeSettings()
    self.view = "edit"
    self.set_rects = nil
    self.plugin_buttons = nil
    self:refresh()
end

-- The pager of the Plugins section (its arrows, a swipe, the page keys).
function KoboldBookDetails:stepSettingsPage(delta)
    local pages = self.set_pages or 1
    local page = math.max(1, math.min(pages, (self.set_page or 1) + delta))
    if page == self.set_page then return end
    self.set_page = page
    local r = self.set_rects
    self:refresh(r and r.plugins_area)
end

function KoboldBookDetails:onSettingsTap(pos)
    local r = self.set_rects
    if not r then return end
    local function hit(rect) return rect and pos:intersectWith(rect) end
    if hit(self.close_rect) then return self:dismiss() end
    if hit(r.back) then return self:closeSettings() end
    if hit(r.prev) then return self:stepSettingsPage(-1) end
    if hit(r.next) then return self:stepSettingsPage(1) end
    for _i, row in ipairs(r.rows) do
        if hit(row.rect) then return self:runSettingsAction(row.id) end
    end
    for _i, b in ipairs(r.buttons) do
        if hit(b.rect) and b.item.enabled then return self:runPluginButton(b.item) end
    end
end

-- Reset, Export, Refresh: the work (and the questions) are in file_actions.lua.
function KoboldBookDetails:runSettingsAction(id)
    local file = self.file
    if id == "reset" then
        FileActions.resetDocument(file, function()
            self.changed, self.meta_changed = true, true   -- Home and the Library show it
            self.rv = Review.get(file)
            self:refresh()
        end)
    elseif id == "export" then
        local title = bookProps(file).title or (file:match("([^/]+)$") or file)
        FileActions.exportNotes(file, title)
    elseif id == "refresh" then
        FileActions.refreshMetadata(file, function()
            self.changed, self.meta_changed = true, true
        end)
    end
end

-- A button another plugin added to KOReader's file dialog. With a book parked
-- there is no file browser (the plugins' buttons belong to it): it is made
-- first (the book closes) and the same button is looked up in the new one.
function KoboldBookDetails:runPluginButton(item)
    local callback = item.callback
    local ok_park, Park = pcall(require, "kobold.ui.park")
    if ok_park and Park and Park.isParked() then
        pcall(Park.fm)
        for _i, it in ipairs(FDButtons.collect(self.file)) do
            if it.key == item.key then
                callback = it.callback
                break
            end
        end
    end
    self.changed = true
    local ok, err = pcall(callback)
    if not ok then
        logger.warn("Kobold: plugin button failed:", tostring(err))
        Toast.error(_("That plugin action failed."))
    end
end

-- ── Collections and the book's file (the rows of Edit) ─────────────────────

-- Collections: a full-screen list of KOReader's collections (the same screen
-- as Add to collection, with collections where it has books). The ones that
-- already hold the book show ticked ("Already added") and can be unticked to
-- take it out; tick the others to put it in. Nothing changes until Save.
function KoboldBookDetails:openCollectionsPicker()
    local ok_rc, RC = pcall(require, "readcollection")
    if ok_rc and RC and not RC.coll and RC._read then pcall(RC._read, RC) end
    if not ok_rc or not RC or type(RC.coll) ~= "table" then
        Toast.error(_("KOReader's collections are not available."))
        return
    end
    local file = self.file
    local default_name = RC.default_collection_name or "favorites"
    local function title(name)
        if name == default_name then return _("Favorites") end
        return name
    end
    local function size(name)
        local n = 0
        for _k in pairs(RC.coll[name] or {}) do n = n + 1 end
        return n
    end
    local names = {}
    for name in pairs(RC.coll) do names[#names + 1] = name end
    -- Favorites first, then A to Z.
    table.sort(names, function(a, b)
        if (a == default_name) ~= (b == default_name) then return a == default_name end
        return title(a):lower() < title(b):lower()
    end)
    local function holds(name)
        return type(RC.coll[name]) == "table" and RC.coll[name][file] ~= nil
    end
    local held = {}   -- the collections that hold the book now
    local want = {}   -- what the ticks say: it starts as it is, a tap flips one
    for _i, name in ipairs(names) do
        held[name] = holds(name)
        want[name] = held[name]
    end
    -- what Save would do: the collections to put the book in and to take it out of
    local function changes()
        local add, remove = {}, {}
        for _i, name in ipairs(names) do
            if want[name] and not held[name] then
                add[#add + 1] = name
            elseif held[name] and not want[name] then
                remove[#remove + 1] = name
            end
        end
        return add, remove
    end
    local function count()
        local add, remove = changes()
        return #add + #remove
    end
    local book_title = bookProps(file).title or (file:match("([^/]+)$") or file)
    ListPicker.show{
        title = _("Add to collections"),
        action_label = _("Save"),
        empty_text = _("You have no collections yet."),
        subtitle = book_title,
        rows = function()
            local rows = {}
            for _i, name in ipairs(names) do
                local n = size(name)
                local sub
                if held[name] and want[name] then
                    sub = _("Already added")
                elseif held[name] then
                    sub = _("Will be removed")
                else
                    sub = (n == 1) and _("1 book") or (n .. _(" books"))
                end
                rows[#rows + 1] = {
                    id = name, icon = "book-marked", text = title(name), sub = sub,
                    marker = "tick", selected = want[name] == true, locked = false,
                }
            end
            return rows
        end,
        count = count,
        can_finish = function() return count() > 0 end,
        on_tap = function(row, picker)
            want[row.id] = not want[row.id]
            picker:reload()
        end,
        on_finish = function()
            local add, remove = changes()
            local ok = pcall(function()
                local touched = {}
                if #add > 0 then
                    local picked = {}
                    for _i, name in ipairs(add) do
                        picked[name] = true
                        touched[name] = true
                    end
                    RC:addItemsMultiple({ [file] = true }, picked)
                end
                for _i, name in ipairs(remove) do
                    local coll = RC.coll[name]
                    if coll and coll[file] ~= nil then
                        if RC.removeItem then pcall(RC.removeItem, RC, file, name, true) end
                        if coll[file] ~= nil then coll[file] = nil end   -- whatever the version does
                    end
                    touched[name] = true
                end
                RC:write(touched)
            end)
            if not ok then
                Toast.error(_("The collections could not be saved."))
                return
            end
            self.changed = true
            -- Favorites may be one of them: the like of the review bar follows.
            self.rv = Review.get(file)
            self:refresh()
            local na, nr = #add, #remove
            if na > 0 and nr > 0 then
                Toast.show(_("Collections updated."))
            elseif na > 0 then
                Toast.show(na == 1 and _("Added to 1 collection.")
                    or string.format(_("Added to %d collections."), na))
            else
                Toast.show(nr == 1 and _("Removed from 1 collection.")
                    or string.format(_("Removed from %d collections."), nr))
            end
        end,
    }
end

-- Copy and Cut: a full-screen list of folders to choose the destination (the
-- New folder screen, with folders where it has books). Tap a folder to open it,
-- the first row goes up; the pill at the top puts the book in the folder that
-- is open. The move itself is the one of the selection mode (file_actions.lua).
function KoboldBookDetails:openFolderPicker(mode)
    local file = self.file
    local book_dir = file:match("^(.*)/[^/]+$") or "/"
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then
        home = home:gsub("/+$", "")
    else
        home = nil
    end
    -- It starts in the home folder (where the Files tab starts), or in the
    -- book's own folder when the book is outside it.
    local start = book_dir
    if home and (book_dir == home or book_dir:sub(1, #home + 1) == home .. "/") then start = home end

    local function parentOf(dir)
        local parent = dir:match("^(.*)/[^/]+$")
        if not parent or parent == "" then return "/" end
        return parent
    end
    local function folders(dir)
        local out = {}
        local ok, iter, st = pcall(lfs.dir, dir)
        if not ok then return out end
        for name in iter, st do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = (dir == "/" and "" or dir) .. "/" .. name
                if lfs.attributes(path, "mode") == "directory" then
                    out[#out + 1] = { name = name, path = path }
                end
            end
        end
        table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
        return out
    end
    -- The folder as the Files tab shows it: from the home folder on.
    local function shown(dir)
        if home and dir:sub(1, #home) == home then
            dir = dir:sub(#home + 1)
        end
        return dir == "" and "/" or dir
    end

    local cut = (mode == "cut")
    ListPicker.show{
        title = cut and _("Move to") or _("Copy to"),
        action_label = cut and _("Move here") or _("Copy here"),
        empty_text = _("No folders here."),
        state = { dir = start },
        subtitle = function(picker) return shown(picker.state.dir) end,
        rows = function(picker)
            local dir = picker.state.dir
            local rows = {}
            if dir ~= "/" then
                rows[#rows + 1] = {
                    id = "__up", icon = "arrow-left", text = _("Parent folder"),
                    sub = shown(parentOf(dir)), dir = parentOf(dir),
                }
            end
            for _i, f in ipairs(folders(dir)) do
                rows[#rows + 1] = {
                    id = f.path, icon = "folder", text = f.name,
                    sub = f.path == book_dir and _("This book is here") or nil,
                    marker = "chevron", dir = f.path,
                }
            end
            return rows
        end,
        -- the book is already in the folder that is open: nothing to do
        can_finish = function(picker) return picker.state.dir ~= book_dir end,
        on_tap = function(row, picker)
            picker.state.dir = row.dir
            picker:reload(true)
        end,
        on_finish = function(picker)
            FileActions.transfer({ file }, picker.state.dir, mode, function(summary)
                if not summary or summary.done == 0 then return end
                self.changed = true
                -- A moved book has another path: this page is about the old one.
                if cut then self:dismiss() end
            end)
        end,
    }
end

-- Rename, Copy, Cut, Delete: the book's file.
function KoboldBookDetails:runFileAction(id)
    local file = self.file
    if id == "rename" then
        FileActions.renameBook(file, function()
            self.changed = true
            self:dismiss()   -- the book has another name now
        end)
    elseif id == "copy" then
        self:openFolderPicker("copy")
    elseif id == "cut" then
        self:openFolderPicker("cut")
    elseif id == "delete" then
        FileActions.confirmDelete({ file }, function(summary)
            if not summary or summary.done == 0 then return end
            self.changed = true
            self:dismiss()
        end)
    end
end

function KoboldBookDetails:onEditTap(pos)
    local r = self.edit_rects
    if not r then return end
    local function hit(rect) return rect and pos:intersectWith(rect) end
    if hit(self.close_rect) then return self:dismiss() end
    if hit(r.back) then return self:closeEdit() end
    if hit(r.fav) then return self:toggleFavorite() end
    for i, rect in ipairs(r.stars) do
        if hit(rect) then return self:setRating(i) end
    end
    if hit(r.review) then return self:openReview() end
    for _i, st in ipairs(r.status) do
        if hit(st.rect) then return self:setStatus(st.id) end
    end
    for _i, row in ipairs(r.rows) do
        if hit(row.rect) then
            if row.id == "metadata" then return self:openMetadata() end
            if row.id == "collections" then return self:openCollectionsPicker() end
            if row.id == "settings" then return self:openSettings() end
            return
        end
    end
    for _i, act in ipairs(r.actions or {}) do
        if hit(act.rect) then return self:runFileAction(act.id) end
    end
end

-- Opens the book, and with `annotation` (an annotation as KOReader saved it)
-- at that annotation: "Show in book" in the annotations list. The "Opening"
-- pill is drawn over the cover, so the sheet shows the details page first.
function KoboldBookDetails:openBook(annotation)
    if self.view ~= "details" then
        self.view = "details"
        self.ann_rects = nil
        self:refresh()
    end
    if require("kobold.ui.transition").enabled() then
        -- Stays open: its cover shows the "Opening" pill, and it
        -- closes once the book is open.
        self.opening = true
        require("kobold.ui.reader").open(self.screen, self.file, {
            pill_screen = self,
            annotation = annotation,
            on_ready = function()
                self.closed = true
                self:notifyChange()
                UIManager:close(self)
            end,
            on_fail = function() self.opening = false end,
        })
    else
        self:dismiss()
        require("kobold.ui.reader").open(self.screen, self.file, { annotation = annotation })
    end
end

function KoboldBookDetails:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
        -- The page keys turn the pages of the annotations list, or move to the
        -- previous / next annotation.
        local group = Device.input.group
        if group and group.PgFwd and group.PgBack then
            self.key_events.KoboldAnnNext = { { group.PgFwd } }
            self.key_events.KoboldAnnPrev = { { group.PgBack } }
        end
    end
    self[1] = self:build()
    KoboldTaps.add(self, "KoboldDetailsTap", 0, 0, W, H, function(ges)
        local pos = ges.pos
        if self.opening then return end   -- the book is opening: taps wait
        if self.view == "editor" then
            self:onEditorTap(pos)
        elseif self.view == "annotation" then
            self:onAnnotationTap(pos)
        elseif self.view == "annotations" then
            self:onAnnotationsTap(pos)
        elseif self.view == "metadata" then
            self:onMetadataTap(pos)
        elseif self.view == "settings" then
            self:onSettingsTap(pos)
        elseif self.view == "edit" then
            self:onEditTap(pos)
        elseif pos:intersectWith(self.close_rect) then
            self:dismiss()
        elseif self.cover_rect and pos:intersectWith(self.cover_rect) then
            require("kobold.ui.cover_splash").show(self.file, true)
        elseif pos:intersectWith(self.read_rect) then
            self:openBook()
        elseif self.annot_rect and pos:intersectWith(self.annot_rect) then
            self:openAnnotations()
        elseif self.edit_rect and pos:intersectWith(self.edit_rect) then
            self:openEdit()
        else
            for id, rect in pairs(self.tab_rects) do
                if pos:intersectWith(rect) and id ~= self.tab then
                    self.tab = id
                    self:refresh()
                    return
                end
            end
        end
    end)
    -- Holding the keyboard's delete key (in the text editor) clears the text.
    KoboldTaps.hold(self, "KoboldDetailsHold", 0, 0, W, H, function(ges)
        if self.view == "editor" then self:onEditorHold(ges.pos) end
    end)
    -- Swipes in the annotations list and in one annotation. Whatever a widget
    -- under it takes (the scrolling synopsis, a long note) never gets here.
    self:registerTouchZones({
        {
            id = "KoboldDetailsSwipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges) return self:onDetailsSwipe(ges) end,
        },
    })
end

-- The page keys: in the list they turn its pages, in one annotation they go to
-- the previous / next one.
function KoboldBookDetails:onKoboldAnnNext()
    if self.opening then return false end
    if self.view == "settings" then self:stepSettingsPage(1) return true end
    if self.view == "annotations" then self:stepAnnotationPage(1) return true end
    if self.view == "annotation" then self:stepAnnotation(1) return true end
    return false
end

function KoboldBookDetails:onKoboldAnnPrev()
    if self.opening then return false end
    if self.view == "settings" then self:stepSettingsPage(-1) return true end
    if self.view == "annotations" then self:stepAnnotationPage(-1) return true end
    if self.view == "annotation" then self:stepAnnotation(-1) return true end
    return false
end

-- Draws the sheet again. With `rect` (a Geom), only that part of the screen
-- is refreshed: a tap on a star must not flash the whole sheet.
function KoboldBookDetails:refresh(rect)
    if self.closed then return end
    self[1] = self:build()
    UIManager:setDirty(self, function() return "ui", rect or self.panel_rect end)
end

function KoboldBookDetails:dismiss()
    if self.kb then
        self.kb:free()
        self.kb = nil
    end
    self.closed = true
    self:notifyChange()
    UIManager:close(self, "ui", self.panel_rect)
    return true
end

-- The Back key: from one annotation it goes back to the list, from the list
-- and from Edit back to the details, from the details it closes the page.
function KoboldBookDetails:onClose()
    if self.view == "editor" then
        self:closeEditor(false)
        return true
    end
    if self.view == "annotation" and not self.opening then
        self:closeAnnotation()
        return true
    end
    if self.view == "annotations" and not self.opening then
        self:closeAnnotations()
        return true
    end
    if self.view == "metadata" then
        self:closeMetadata()
        return true
    end
    if self.view == "settings" then
        self:closeSettings()
        return true
    end
    if self.view == "edit" and not self.opening then
        self:closeEdit()
        return true
    end
    return self:dismiss()
end

-- Opens the details page for `file`, over `screen` (the Kobold screen).
-- `on_change` runs after the page closes, if Edit changed something.
-- `hide_koreader` is not used any more. `start_view` (optional) is the screen
-- the page opens on: "edit" goes straight to Edit (the pencil), as the
-- Library's "Edit book" row does; Back from there returns to the details.
function KoboldBookDetails.show(file, screen, on_change, hide_koreader, start_view)
    local w = KoboldBookDetails:new{
        file = file, screen = screen, on_change = on_change, hide_koreader = hide_koreader,
        view = start_view == "edit" and "edit" or nil,
    }
    UIManager:show(w, "ui", w.panel_rect)
    require("kobold.ui.refresh").settle(w, function() return w.panel_rect end)
end

return KoboldBookDetails
