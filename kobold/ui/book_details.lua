-- kobold/ui/book_details.lua — Kobold
-- Kobold's book details page (View Details in the book menu): a rounded
-- sheet with the cover, title, series, author, a progress bar, a Read now
-- pill and a round "..." for KOReader's own book menu; then a row of facts
-- (pages, language, format, size) and a Synopsis / Details switch. The data
-- comes from KOReader (its book info, with any corrections made in Book
-- information).
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
local lfs             = require("libs/libkoreader-lfs")
local _               = require("gettext")
local KoboldLibrary   = require("kobold.data.library")
local KoboldMyBooksData = require("kobold.data.mybooks")
local KoboldPopup     = require("kobold.ui.popup")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local OptionSheet     = require("kobold.ui.option_sheet")
local Rounded         = require("kobold.ui.rounded")
local CoverBadge      = require("kobold.ui.cover_badge")

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
    on_change = nil, -- runs after the KOReader menu changed something
    hide_koreader = false, -- true: no "..." button (KOReader's book menu)
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
    local ok_fm, FileManager = pcall(require, "apps/filemanager/filemanager")
    local bookinfo = ok_fm and FileManager and FileManager.instance and FileManager.instance.bookinfo
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
      card_pad = 14, row_pad = 9, pill_py = 7, pill_px = 14, chip_h = 32, chip_gap = 8, font = 14 },
    { pad = 18, gap = 12, top = 38, tile = 60, seg = 34, button = 46, cover = 0.27, info_gap = 7,
      card_pad = 10, row_pad = 6, pill_py = 5, pill_px = 12, chip_h = 28, chip_gap = 6, font = 13 },
    { pad = 14, gap = 8, top = 32, tile = 52, seg = 30, button = 42, cover = 0.22, info_gap = 5,
      card_pad = 8, row_pad = 4, pill_py = 3, pill_px = 10, chip_h = 24, chip_gap = 5, font = 12 },
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

function KoboldBookDetails:build(level)
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

    -- Top bar: the title on the left and a round close button on the right.
    local close_d = U(36)
    local close_button = pill(close_d, close_d, SOFT, KoboldWidgets.icon("close", U(16)))
    local top_bar = OverlapGroup:new{
        dimen = Geom:new{ w = inner_w, h = top_h },
        LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = top_h },
            TextWidget:new{
                text = _("Book Details"), face = KoboldWidgets.face(19), bold = true,
                max_width = inner_w - close_d - U(16),
            },
        },
        RightContainer:new{ dimen = Geom:new{ w = inner_w, h = top_h }, close_button },
    }
    self.close_rect = Geom:new{
        x = x0 + inner_w - close_d - U(12), y = R.y,
        w = close_d + U(12) + pad, h = top_h + pad,
    }

    -- Header: the cover (rounded) on the left; on the right the title, a
    -- series pill, the author, the progress bar, and the buttons at the
    -- bottom, lined up with the foot of the cover.
    local cover_w = math.floor(inner_w * M.cover)
    local cover_h = math.floor(cover_w * 1.5)
    local text_w  = inner_w - cover_w - gap_h
    local info_col = VerticalGroup:new{
        align = "left",
        TextBoxWidget:new{
            text = title, face = KoboldWidgets.face(24), bold = true, width = text_w,
        },
    }
    if props.series then
        local series = props.series:upper()
        if props.series_index then
            local n = tonumber(props.series_index)
            if n and n == math.floor(n) then n = math.floor(n) end
            series = series .. "  ·  " .. tostring(n or props.series_index)
        end
        local pad_x = U(12)
        local label = TextWidget:new{
            text = series, face = KoboldWidgets.face(12), max_width = text_w - 2 * pad_x,
        }
        info_col[#info_col + 1] = VerticalSpan:new{ width = U(M.info_gap) }
        info_col[#info_col + 1] = pill(label:getSize().w + 2 * pad_x, U(26), SOFT, label)
    end
    if props.authors then
        info_col[#info_col + 1] = VerticalSpan:new{ width = U(M.info_gap) }
        info_col[#info_col + 1] = TextWidget:new{
            text = (props.authors:gsub("\n", ", ")), face = KoboldWidgets.face(17),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
        }
    end
    -- Progress: a bar, then "42% read" on the left and the pages on the right.
    local frac = fraction(info)
    local label_h = TextWidget:new{ text = "0", face = KoboldWidgets.face(14) }:getSize().h
    local progress_note
    if props.pages and frac > 0 and frac < 1 then
        progress_note = string.format(_("%d of %d pages"), math.floor(frac * props.pages + 0.5), props.pages)
    end
    info_col[#info_col + 1] = VerticalSpan:new{ width = U(M.info_gap + 6) }
    info_col[#info_col + 1] = progressBar(text_w, U(8), frac)
    info_col[#info_col + 1] = VerticalSpan:new{ width = U(8) }
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
    info_col[#info_col + 1] = note_row

    local button_h = U(M.button)
    local button_gap = U(10)
    -- Without the "..." the Read now pill takes the whole width.
    local read_w = self.hide_koreader and text_w or (text_w - button_h - button_gap)
    local info_h = info_col:getSize().h
    local header_h = math.max(cover_h, info_h + gap + button_h)

    -- Read now: a black pill with white text. Round "..." beside it.
    local icon_sz = U(20)
    local read_label = TextWidget:new{ text = _("Read now"), face = italicFace(19), fgcolor = WHITE }
    local read_content = HorizontalGroup:new{
        align = "center",
        OptionSheet.iconWidget("book-open-text", icon_sz, WHITE),
        HorizontalSpan:new{ width = U(10) },
        read_label,
    }
    local read_button = pill(read_w, button_h, BLACK, read_content)
    local dots_button = not self.hide_koreader and pill(button_h, button_h, SOFT,
        TextWidget:new{ text = "…", face = KoboldWidgets.face(22), bold = true }) or nil
    local header_y = y0 + top_h + gap
    local buttons_y = header_y + header_h - button_h
    local right_x = x0 + cover_w + gap_h
    self.read_rect = Geom:new{ x = right_x, y = buttons_y, w = read_w, h = button_h }
    self.dots_rect = dots_button and Geom:new{
        x = right_x + read_w + button_gap, y = buttons_y, w = button_h, h = button_h,
    } or nil
    local right = VerticalGroup:new{
        align = "left",
        info_col,
        VerticalSpan:new{ width = header_h - info_h - button_h },
        dots_button
            and HorizontalGroup:new{ read_button, HorizontalSpan:new{ width = button_gap }, dots_button }
            or read_button,
    }
    -- The cover, with the "Opening" pill over it while the book opens.
    local csw, csh = KoboldWidgets.coverBox(file, cover_w, cover_h)
    csw, csh = math.min(csw or cover_w, cover_w), math.min(csh or cover_h, cover_h)
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
        return self:build(level + 1)
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

function KoboldBookDetails:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    self[1] = self:build()
    KoboldTaps.add(self, "KoboldDetailsTap", 0, 0, W, H, function(ges)
        local pos = ges.pos
        if self.opening then return end   -- the book is opening: taps wait
        if pos:intersectWith(self.close_rect) then
            self:onClose()
        elseif self.cover_rect and pos:intersectWith(self.cover_rect) then
            require("kobold.ui.cover_splash").show(self.file, true)
        elseif pos:intersectWith(self.read_rect) then
            if require("kobold.ui.transition").enabled() then
                -- Stays open: its cover shows the "Opening" pill, and it
                -- closes once the book is open.
                self.opening = true
                require("kobold.ui.reader").open(self.screen, self.file, {
                    pill_screen = self,
                    on_ready = function()
                        self.closed = true
                        UIManager:close(self)
                    end,
                    on_fail = function() self.opening = false end,
                })
            else
                self:onClose()
                require("kobold.ui.reader").open(self.screen, self.file)
            end
        elseif self.dots_rect and pos:intersectWith(self.dots_rect) then
            if not KoboldWidgets.showBookMenu(self.file, function()
                if self.on_change then self.on_change() end
                self:refresh()
            end) then
                UIManager:show(require("ui/widget/infomessage"):new{
                    text = _("The KOReader book menu is not available."),
                })
            end
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
end

function KoboldBookDetails:refresh()
    if self.closed then return end
    self[1] = self:build()
    UIManager:setDirty(self, function() return "ui", self.panel_rect end)
end

function KoboldBookDetails:onClose()
    self.closed = true
    UIManager:close(self, "ui", self.panel_rect)
    return true
end

-- Opens the details page for `file`, over `screen` (the Kobold screen).
function KoboldBookDetails.show(file, screen, on_change, hide_koreader)
    local w = KoboldBookDetails:new{
        file = file, screen = screen, on_change = on_change, hide_koreader = hide_koreader,
    }
    UIManager:show(w, "ui", w.panel_rect)
end

return KoboldBookDetails
