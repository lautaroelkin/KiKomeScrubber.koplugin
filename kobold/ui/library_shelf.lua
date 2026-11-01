-- kobold/ui/library_shelf.lua — KiKome
-- A small take on Bookshelf: tabs along the top (Home, Library, Series,
-- Authors) and, under them, covers standing on wooden shelves.
--
--   Home         the file browser: your home folder, with folders as cards
--                and books on shelves; it never goes above the home folder
--   Library      every book, newest file first
--   Series       one card per series (a stack of covers); tap to open it
--   Authors      one card per author; tap to open it
--   Collections  your KOReader collections, one card each
--   Genres       one card per genre (a keyword of the books); off by default
--
-- Every chip has its own layout, Grid or List, picked from the adjust button
-- on the right of the chips. Folders, series, authors, collections and genres show as
-- stacked covers in both layouts.
--
-- Opening a card shows its books, with a Back row on top. Authors and series
-- come from custom metadata first, then the cover browser's book info: the
-- same order of priority Bookshelf uses.

local Blitbuffer      = require("ffi/blitbuffer")
local ffi             = require("ffi")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local CenterContainer = require("ui/widget/container/centercontainer")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local RightContainer  = require("ui/widget/container/rightcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local ReadHistory     = require("readhistory")
local ImageWidget     = require("ui/widget/imagewidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local UIManager       = require("ui/uimanager")
local KoboldLibrary   = require("kobold.data.library")
local lfs             = require("libs/libkoreader-lfs")
local KoboldMetrics   = require("kobold.ui.metrics")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local OptionSheet     = require("kobold.ui.option_sheet")
local CoverBadge      = require("kobold.ui.cover_badge")
local Rounded         = require("kobold.ui.rounded")
local Chips           = require("kobold.data.chips")
local BookLang        = require("kobold.data.booklang")
local Genres          = require("kobold.data.genres")
local KoboldBookInfo  = require("kobold.data.bookinfo")
local MyBooksData     = require("kobold.data.mybooks")
local ViewSheet       = require("kobold.ui.view_sheet")

local Screen = Device.screen
local COVER_RATIO = 1.5
local MAX_TABS    = Chips.MAX
local MAX_GRID    = 40
local MAX_RECENT  = 60

-- A folder chip's id is "folder:<path>"; this gives the path back.
local function customPath(tab)
    if type(tab) == "string" and tab:sub(1, 7) == "folder:" then return tab:sub(8) end
    return nil
end

-- A collection chip's id is "collection:<name>"; this gives the name back.
local function customCollection(tab)
    if type(tab) == "string" and tab:sub(1, 11) == "collection:" then return tab:sub(12) end
    return nil
end

-- ── Layout per chip ────────────────────────────────────────────────────────
local DEFAULT_LAYOUT = {
    folders = "grid", home = "grid", recent = "list", oldest = "list",
    series = "grid", authors = "grid", collections = "grid",
    favorites = "grid", tbr = "grid", genres = "grid",
}
local LAYOUT_KEY = "kikome_shelf_layouts"

local function layoutFor(tab)
    local ok, saved = pcall(function() return G_reader_settings:readSetting(LAYOUT_KEY) end)
    local v = ok and type(saved) == "table" and saved[tab] or nil
    if v == "grid" or v == "list" then return v end
    return DEFAULT_LAYOUT[tab] or "grid"
end

local function setLayout(tab, value)
    pcall(function()
        local saved = G_reader_settings:readSetting(LAYOUT_KEY)
        if type(saved) ~= "table" then saved = {} end
        saved[tab] = value
        G_reader_settings:saveSetting(LAYOUT_KEY, saved)
    end)
end

-- ── Look ───────────────────────────────────────────────────────────────────
-- Greys and metrics follow the reference Kindle-style UI: thin mid-grey
-- outlines, black only for what is chosen, secondary text in dark grey.
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_OUTLINE   = Blitbuffer.Color8(0x99)
local C_SECONDARY = Blitbuffer.Color8(0x55)
local C_TRACK     = Blitbuffer.Color8(0xCC)
local C_FILL      = Blitbuffer.Color8(0x33)
local C_TAG       = Blitbuffer.Color8(0xDD)

local function U(n) return Screen:scaleBySize(n) end

-- ── Icons ──
-- Drawn by the shared option sheet module.
local iconWidget = OptionSheet.iconWidget

-- ── Book info ──────────────────────────────────────────────────────────────
-- Cached for the session, but only once the cover browser has actually
-- answered: a book it has not indexed yet is asked again next time.
local META = {}
local UNKNOWN_AUTHOR = "Unknown author"

local function trim(s)
    return (s:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function fileStem(file)
    return ((file:match("([^/]+)$") or file):gsub("%.[^.]+$", ""))
end

-- What the reader (or a plugin acting for them) wrote with KOReader's own
-- metadata editor. It outranks what was extracted from the file.
local function customProps(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings and DocSettings.findCustomMetadataFile) then return nil end
    local ok2, props = pcall(function()
        local path = DocSettings:findCustomMetadataFile(file)
        if not path then return nil end
        return DocSettings.openSettingsFile(path):readSetting("custom_props")
    end)
    if ok2 and type(props) == "table" then return props end
    return nil
end

local function text(v)
    return (type(v) == "string" and v ~= "") and v or nil
end

-- Splits "Name #3" into the name and the number.
local function splitSeries(s, idx)
    local name, n = s:match("^(.-)%s*#([%d%.]+)$")
    if name and name ~= "" then return name, idx or tonumber(n) end
    return s, idx
end

local function readMeta(file)
    local m = META[file]
    if m then return m end
    m = { authors = {}, title = fileStem(file) }
    -- The cover browser's data for the whole library comes from one query (or
    -- the saved snapshot), the same source as the Library tabs. Asking it book
    -- by book was one SQLite query each: seconds on an e-reader with a big
    -- library, with the screen waiting.
    local info = KoboldBookInfo.get(file)
    local cp = customProps(file)
    if not info and not cp then
        -- Not read by the cover browser yet: remembered as such, so sorting
        -- does not look again at every comparison. forgetMisses() lets the
        -- next look happen once covers were prepared (their data arrives then).
        m.pending = true
        META[file] = m
        return m
    end
    info = info or {}

    m.title = text(cp and cp.title) or text(info.title) or m.title

    local authors = text(cp and cp.authors) or text(info.authors)
    if authors then
        for part in authors:gmatch("[^\n]+") do
            local a = trim(part)
            if a ~= "" then m.authors[#m.authors + 1] = a end
        end
    end

    local series = text(cp and cp.series) or text(info.series)
    if series then
        local idx = tonumber(text(cp and cp.series_index) or info.series_index)
        series, idx = splitSeries(series, idx)
        series = trim(series)
        if series ~= "" then m.series, m.series_index = series, idx end
    end
    META[file] = m
    return m
end

-- Forget what was read, so edits made in the book information show up.
-- file -> last time it was opened, from KOReader's history
local function readTimes()
    local t = {}
    for _i, h in ipairs(ReadHistory.hist or {}) do
        if h.file then
            local when = h.time or 0
            if not t[h.file] or when > t[h.file] then t[h.file] = when end
        end
    end
    return t
end

local function memberLess(kind)
    return function(a, b)
        local ma, mb = readMeta(a), readMeta(b)
        if kind == "series" then
            local ia, ib = ma.series_index or math.huge, mb.series_index or math.huge
            if ia ~= ib then return ia < ib end
        end
        local ta, tb = ma.title:lower(), mb.title:lower()
        if ta ~= tb then return ta < tb end
        return a < b
    end
end

-- ── Shelf board ────────────────────────────────────────────────────────────
-- The wooden board the books stand on: a light top lip and a darker front.
local ShelfBoard = Widget:extend{ width = 0, height = 0 }

function ShelfBoard:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function ShelfBoard:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.hidden then return end   -- Settings > Shelves: this chip has no boards
    local lip = math.max(2, math.floor(self.height * 0.4))
    bb:paintRect(x, y, self.width, lip, Blitbuffer.COLOR_LIGHT_GRAY)
    bb:paintRect(x, y + lip, self.width, self.height - lip, Blitbuffer.COLOR_GRAY)
end

-- A thin line across the width.
local Rule = Widget:extend{ width = 0, height = 1, color = nil }

function Rule:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function Rule:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    bb:paintRect(x, y, self.width, self.height, self.color or Blitbuffer.COLOR_LIGHT_GRAY)
end

-- Rounded progress bar, as in the reference rows.
local ProgressBar = Widget:extend{ width = 0, height = 0, percentage = 0 }

function ProgressBar:getSize() return Geom:new{ w = self.width, h = self.height } end

function ProgressBar:paintTo(bb, x, y)
    local radius = math.floor(self.height / 2)
    bb:paintRoundedRect(x, y, self.width, self.height, C_TRACK, radius)
    local fill = math.floor(self.width * self.percentage)
    if fill > 0 then
        bb:paintRoundedRect(x, y, math.max(fill, self.height), self.height, C_FILL, radius)
    end
end

-- A small arrow pointing right (the "opens" mark on folder rows), drawn as two
-- strokes meeting at the right edge.

-- A pill like the reference chips: thin grey outline, or filled black when
-- it is the one in use.
local Chip = Widget:extend{ text = "", selected = false, font_size = 15, height = 0 }

function Chip:init()
    self.label = TextWidget:new{
        text = self.text, face = KoboldWidgets.face(self.font_size),
        fgcolor = self.selected and WHITE or BLACK,
    }
    self.pad = U(14)
    self.width = self.label:getSize().w + 2 * self.pad
end

function Chip:getSize() return Geom:new{ w = self.width, h = self.height } end

function Chip:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local radius = math.floor(self.height / 2)
    if self.selected then
        bb:paintRoundedRect(x, y, self.width, self.height, BLACK, radius)
    else
        bb:paintRoundedRect(x, y, self.width, self.height, C_TAG, radius)
    end
    self.label:paintTo(bb, x + self.pad, y + math.floor((self.height - self.label:getSize().h) / 2))
end

function Chip:free() if self.label then self.label:free() end end

-- "Locked Tomb, The" reads as "The Locked Tomb" (calibre's naming). Display
-- only: groups keep the raw name so they sort the way the library files them.
local function flipArticle(name)
    local stem, article = name:match("^(.-),%s+(The)$")
    if not stem then stem, article = name:match("^(.-),%s+(An)$") end
    if not stem then stem, article = name:match("^(.-),%s+(A)$") end
    if stem and stem ~= "" then return article .. " " .. stem end
    return name
end

local LibraryShelf = Widget:extend{
    x = 0, y = 0, width = 0, height = 0,
    home = nil,
    files = {},
    onTapFile = nil,
    onHoldFile = nil,
    state = nil,  -- { tab, page, drill = { kind, name } } to pick up where it was
}

function LibraryShelf.invalidateMeta()
    META = {}
    BookLang.forget()
    Genres.forget()
end

-- Books the cover browser had not read when they were looked at are looked at
-- again next time (background cover extraction has brought their data since).
function LibraryShelf.forgetMisses()
    for file, m in pairs(META) do
        if m.pending then META[file] = nil end
    end
end

function LibraryShelf:init()
    local st = self.state or {}
    self.tab  = st.tab or "folders"
    -- The view (Recent, Oldest, Newest added, Oldest added) is kept per chip:
    -- everything opened inside a chip follows the chip's view.
    self.views = {}
    for k, v in pairs(st.views or {}) do self.views[k] = v end
    if st.view and not st.views then self.views[self.tab] = st.view end      -- older saved state
    -- Alphabetical order (az / za), language and reading status filters, also
    -- kept per chip.
    self.alphas, self.langs, self.statuses = {}, {}, {}
    for k, v in pairs(st.statuses or {}) do self.statuses[k] = v end
    for k, v in pairs(st.alphas or {}) do self.alphas[k] = v end
    for k, v in pairs(st.langs or {}) do self.langs[k] = v end
    if self.tab == "recent" then self.tab = "home"; self.views.home = "recent" end  -- older saved state
    self.page = st.page or 1
    self.path = st.path
    self.chips = Chips.enabledList()
    if not self:chipOn(self.tab) then
        -- The open chip was turned off in Settings: open the first one on.
        self.tab = self.chips[1] and self.chips[1].id or "home"
        self.path, self.page = nil, 1
    end

    self.chip_h     = Screen:scaleBySize(41)
    self.chip_pad   = Screen:scaleBySize(8)
    self.chip_gap   = Screen:scaleBySize(8)
    self.gap        = Screen:scaleBySize(14)
    self.board_h    = Screen:scaleBySize(12)
    self.top_min    = Screen:scaleBySize(10)
    self.cap_gap    = Screen:scaleBySize(4)
    self.cap_name_h = Screen:scaleBySize(26)
    self.indicator_h = Screen:scaleBySize(30)

    self.groups_cache = {}
    self.item_rects   = {}
    self.page_items   = {}
    self.page_kinds   = {}
    self.main_chips   = {}
    self.back_w       = nil
    self.grid_y       = 0
    self.total_pages  = 1

    if st.drill and st.drill.name then
        for _i, g in ipairs(self:computeGroups(st.drill.kind)) do
            if g.name == st.drill.name then
                self.drill = { kind = st.drill.kind, name = g.name, files = g.files }
                break
            end
        end
    end
    self:rebuild()
end

function LibraryShelf:getState()
    return {
        tab = self.tab, views = self.views, alphas = self.alphas, langs = self.langs,
        statuses = self.statuses,
        page = self.page, path = self.path,
        drill = self.drill and { kind = self.drill.kind, name = self.drill.name } or nil,
    }
end

function LibraryShelf:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function LibraryShelf:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    if self.child then self.child:paintTo(bb, x, y) end
    -- Touch zones are registered after painting, when the real positions exist.
    if self.needs_tap_registration then
        self.needs_tap_registration = false
        self:registerTaps()
    end
end

function LibraryShelf:free()
    if self.child and self.child.free then self.child:free() end
end

-- ── What each tab shows ────────────────────────────────────────────────────
-- Groups of books for the Series, Authors, Collections and Genres tabs, most
-- recently read first.
function LibraryShelf:computeGroups(kind)
    if self.groups_cache[kind] then return self.groups_cache[kind] end
    local times = readTimes()
    local map, list = {}, {}
    local function add(name, file)
        local g = map[name]
        if not g then
            g = { name = name, files = {}, last = 0, added = 0 }
            map[name] = g
            list[#list + 1] = g
        end
        g.files[#g.files + 1] = file
        local t = times[file] or 0
        if t > g.last then g.last = t end
        local a = lfs.attributes(file, "modification") or 0
        if a > g.added then g.added = a end
    end
    if kind == "collections" then
        local ok, rc = pcall(require, "readcollection")
        if ok and rc then
            if not rc.coll and rc._read then pcall(rc._read, rc) end
            for name, coll in pairs(rc.coll or {}) do
                -- Favorites / To be read can be hidden (Settings > Shelves > Collections).
                if type(coll) == "table" and not Chips.collectionHidden(rc, name) then
                    for file in pairs(coll) do
                        if type(file) == "string" and lfs.attributes(file, "mode") == "file" then
                            add(tostring(name), file)
                        end
                    end
                end
            end
        end
    elseif kind == "genres" then
        -- A book with several keywords stands in each of its genres. Genres
        -- that differ only in case are one (Genres.of gives one spelling).
        local by_key = {}
        for _i, file in ipairs(self.files or {}) do
            for _j, name in ipairs(Genres.of(file)) do
                local key = name:lower()
                by_key[key] = by_key[key] or name
                add(by_key[key], file)
            end
        end
    else
        for _i, file in ipairs(self.files or {}) do
            local m = readMeta(file)
            if kind == "series" then
                if m.series then add(m.series, file) end
            else
                add(m.authors[1] or UNKNOWN_AUTHOR, file)
            end
        end
    end
    local less = memberLess(kind)
    for _i, g in ipairs(list) do table.sort(g.files, less) end
    table.sort(list, function(a, b)
        if a.last ~= b.last then return a.last > b.last end
        return a.name:lower() < b.name:lower()
    end)
    self.groups_cache[kind] = list
    return list
end

-- Returns "books" with a list of files, or "groups" with a list of groups.
-- The folder Home starts in, and never leaves: KOReader's home folder.
function LibraryShelf:rootDir()
    local root = G_reader_settings and G_reader_settings:readSetting("home_dir") or ""
    if #root > 1 then root = root:gsub("/+$", "") end
    if root == "/" then root = "" end
    return root
end

local function baseName(path)
    return path:match("([^/]+)$") or path
end

-- The current folder's subfolders and books, from the library scan (so only
-- folders that hold books appear, and nothing is read from disk here).
function LibraryShelf:computeFolder()
    local root = self:rootDir()
    local path = self.path
    if not path or path:sub(1, #root) ~= root then path = root end
    self.path = path
    local prefix = path .. "/"
    local folders, by_name, books, total = {}, {}, {}, 0
    for _i, file in ipairs(self.files or {}) do
        if file:sub(1, #prefix) == prefix then
            total = total + 1
            local seg = file:sub(#prefix + 1):match("^([^/]+)/")
            if seg then
                local f = by_name[seg]
                if not f then
                    f = { name = seg, path = prefix .. seg, files = {} }
                    by_name[seg] = f
                    folders[#folders + 1] = f
                end
                f.files[#f.files + 1] = file
            else
                books[#books + 1] = file
            end
        end
    end
    table.sort(folders, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(books, function(a, b)
        local fa, fb = baseName(a):lower(), baseName(b):lower()
        if fa ~= fb then return fa < fb end
        return a < b
    end)
    self.folder_total = total
    return { folders = folders, books = books }
end

-- Last time each book was opened, from KOReader's reading history.
local function lastOpened()
    local when = {}
    for _i, h in ipairs(ReadHistory.hist or {}) do
        if h.file and (when[h.file] or 0) < (h.time or 0) then when[h.file] = h.time or 0 end
    end
    return when
end

-- Recent: the books you opened, most recently opened first.
function LibraryShelf:recentFiles()
    local when, list = lastOpened(), {}
    for file in pairs(when) do
        if lfs.attributes(file, "mode") == "file" then list[#list + 1] = file end
    end
    table.sort(list, function(a, b)
        if when[a] ~= when[b] then return when[a] > when[b] end
        return a < b
    end)
    for i = #list, MAX_RECENT + 1, -1 do list[i] = nil end
    return list
end

-- Oldest: the whole library, least recently opened first (never opened = first).
function LibraryShelf:oldestFiles()
    local when, list = lastOpened(), {}
    for _i, file in ipairs(self.files or {}) do list[#list + 1] = file end
    table.sort(list, function(a, b)
        local ta, tb = when[a] or 0, when[b] or 0
        if ta ~= tb then return ta < tb end
        return a < b
    end)
    return list
end

-- ── Sort / alphabetical / language ─────────────────────────────────────────
-- Four independent choices that combine: reading status and language (they
-- narrow the list first), Sort (Recent, Oldest, ...) and an alphabetical order
-- (A-Z / Z-A). Sort orders what is left; the alphabetical order breaks the
-- ties of Sort, or orders the list by itself when no Sort is chosen.
local function titleKey(file)
    return readMeta(file).title:lower()
end

-- True when file a goes before file b in the chosen alphabetical order.
function LibraryShelf:alphaLess(a, b)
    local ta, tb = titleKey(a), titleKey(b)
    if ta ~= tb then
        if self.alpha == "za" then return ta > tb end
        return ta < tb
    end
    return a < b
end

-- Tie-breaker between two books: alphabetical if chosen, else by path.
function LibraryShelf:tie(a, b)
    if self.alpha then return self:alphaLess(a, b) end
    return a < b
end

-- True when a book passes the language and reading status filters.
function LibraryShelf:keepFile(file)
    if self.lang and BookLang.of(file) ~= self.lang then return false end
    if self.status and MyBooksData.statusOf(file) ~= self.status then return false end
    return true
end

-- Keeps only the books that pass the filters (all of them when none is on).
function LibraryShelf:filtered(files)
    if not (self.lang or self.status) then return files end
    local out = {}
    for _i, file in ipairs(files) do
        if self:keepFile(file) then out[#out + 1] = file end
    end
    return out
end

-- The distinct languages of the library, sorted (e.g. { "EN", "ES" }).
function LibraryShelf:languages()
    return BookLang.languages(self.files)
end

-- The four views (Recent, Oldest, Newest added, Oldest added), applied to any
-- list of books: Library, a folder chip, a series, author or collection.
-- With no view picked, the list keeps its own order (Library and folder chips:
-- newest file first). Recent only lists books that were opened.
function LibraryShelf:viewFiles(files, keep_all)
    local view = self.view
    files = self:filtered(files)
    local list = {}
    if view == "recent" or view == "oldest" then
        local when = lastOpened()
        for _i, file in ipairs(files) do
            -- keep_all (inside a folder or series): books never opened stay, last
            if keep_all or view == "oldest" or (when[file] or 0) > 0 then list[#list + 1] = file end
        end
        table.sort(list, function(a, b)
            local ta, tb = when[a] or 0, when[b] or 0
            if ta ~= tb then
                if view == "recent" then return ta > tb end
                return ta < tb
            end
            return self:tie(a, b)
        end)
        if view == "recent" and not keep_all then
            for i = #list, MAX_RECENT + 1, -1 do list[i] = nil end
        end
        return list
    end
    local stamp = {}
    for _i, file in ipairs(files) do
        list[#list + 1] = file
        stamp[file] = lfs.attributes(file, "modification") or 0
    end
    -- Only an alphabetical order chosen (no Sort): the list is just A-Z / Z-A.
    if not view and self.alpha then
        table.sort(list, function(a, b) return self:alphaLess(a, b) end)
        return list
    end
    local newest_first = (view ~= "added_oldest")
    table.sort(list, function(a, b)
        if stamp[a] ~= stamp[b] then
            if newest_first then return stamp[a] > stamp[b] end
            return stamp[a] < stamp[b]
        end
        return self:tie(a, b)
    end)
    return list
end

-- Books inside a folder, series, author or collection: with no view picked
-- they keep their own order; with one, all of them are re-sorted.
function LibraryShelf:ordered(files)
    if not (self.view or self.alpha or self.lang or self.status) then return files end
    return self:viewFiles(files, true)
end

-- The same four views for groups (series, authors, collections). The groups
-- come most recently read first; a view re-sorts a copy of that list.
function LibraryShelf:viewGroups(groups)
    local view = self.view
    local list = {}
    -- A language or status keeps the groups that have at least one book that
    -- passes it.
    for _i, g in ipairs(groups) do
        local keep = true
        if self.lang or self.status then
            keep = false
            for _j, file in ipairs(g.files) do
                if self:keepFile(file) then keep = true; break end
            end
        end
        if keep then list[#list + 1] = g end
    end
    local za = (self.alpha == "za")
    local function nameLess(a, b)
        local na, nb = a.name:lower(), b.name:lower()
        if self.alpha and na ~= nb then
            if za then return na > nb end
            return na < nb
        end
        return na < nb
    end
    if not view then
        if self.alpha then table.sort(list, nameLess) end
        return list
    end
    if view == "recent" then
        local kept = {}
        for _i, g in ipairs(list) do
            if g.last > 0 then kept[#kept + 1] = g end
        end
        list = kept
        table.sort(list, function(a, b)
            if a.last ~= b.last then return a.last > b.last end
            return nameLess(a, b)
        end)
    elseif view == "oldest" then
        table.sort(list, function(a, b)
            if a.last ~= b.last then return a.last < b.last end
            return nameLess(a, b)
        end)
    else
        local newest_first = (view ~= "added_oldest")
        table.sort(list, function(a, b)
            if a.added ~= b.added then
                if newest_first then return a.added > b.added end
                return a.added < b.added
            end
            return nameLess(a, b)
        end)
    end
    return list
end

-- The books under a folder, at any depth (for a folder chip).
function LibraryShelf:filesUnder(path)
    local prefix = (path == "") and "/" or (path .. "/")
    local out = {}
    for _i, file in ipairs(self.files or {}) do
        if file:sub(1, #prefix) == prefix then out[#out + 1] = file end
    end
    return out
end

-- The books of KOReader's Favorites or To be read collection (kind is
-- "favorites" or "tbr"). Books outside the home folder are kept too.
-- `own_name` is given for a collection chip: the books of that collection.
function LibraryShelf:collectionFiles(kind, own_name)
    local files = {}
    local ok, rc = pcall(require, "readcollection")
    if not (ok and rc) then return files end
    if not rc.coll and rc._read then pcall(rc._read, rc) end
    local name = own_name or Chips.collectionKey(rc, kind)
    local coll = name and rc.coll and rc.coll[name]
    if type(coll) == "table" then
        for file, item in pairs(coll) do
            local path = type(item) == "table" and item.file or file
            if type(path) == "string" and lfs.attributes(path, "mode") == "file" then
                files[#files + 1] = path
            end
        end
    end
    return files
end

function LibraryShelf:chipOn(id)
    for _i, c in ipairs(self.chips or {}) do
        if c.id == id then return true end
    end
    return false
end

function LibraryShelf:computeItems()
    if self.tab == "folders" and not self.drill then
        local content = self:computeFolder()
        -- Folders stay first, as they are; the books after them follow the view.
        content.books = self:ordered(content.books)
        return "mixed", content
    end
    if self.drill then return "books", self:ordered(self.drill.files) end
    if self.tab == "series" or self.tab == "authors" or self.tab == "collections" or self.tab == "genres" then
        return "groups", self:viewGroups(self:computeGroups(self.tab))
    end
    if self.tab == "favorites" or self.tab == "tbr" then
        return "books", self:viewFiles(self:collectionFiles(self.tab))
    end
    local custom = customPath(self.tab)
    if custom then
        return "books", self:viewFiles(self:filesUnder(custom))
    end
    local own_collection = customCollection(self.tab)
    if own_collection then
        return "books", self:viewFiles(self:collectionFiles(nil, own_collection))
    end
    -- Library: the whole library
    return "books", self:viewFiles(self.files or {})
end

-- ── Navigation ─────────────────────────────────────────────────────────────
function LibraryShelf:setTab(id)
    self.tab, self.drill, self.page, self.path = id, nil, 1, nil
    self:rebuild()
end

-- Recent, Oldest and the Added views are views of Library, not chips of their own: they share
-- Library's layout, so switching between any of them or none never
-- changes Grid / List.
function LibraryShelf:layoutKey()
    return self.tab
end

-- The view belongs to the chip: every folder, series or author opened inside
-- it shows the same order, and changing it anywhere changes it for the chip.
function LibraryShelf:locKey()
    return self.tab
end

-- self.view is the view of the chip being shown.
function LibraryShelf:syncView()
    local key = self:locKey()
    self.view  = self.views[key]
    self.alpha = self.alphas[key]
    self.lang  = self.langs[key]
    self.status = self.statuses[key]
end

function LibraryShelf:setView(id)
    self.views[self:locKey()] = id   -- nil when the chosen one is tapped again
    self.page = 1
    self:rebuild()
end

function LibraryShelf:setAlpha(id)
    self.alphas[self:locKey()] = id  -- nil when the chosen one is tapped again
    self.page = 1
    self:rebuild()
end

function LibraryShelf:setLang(id)
    self.langs[self:locKey()] = id
    self.page = 1
    self:rebuild()
end

function LibraryShelf:setStatus(id)
    self.statuses[self:locKey()] = id  -- nil (the chosen one tapped again): every book
    self.page = 1
    self:rebuild()
end

function LibraryShelf:openGroup(group)
    if group.path then  -- a folder
        self.path, self.page = group.path, 1
    else
        self.drill = { kind = self.tab, name = group.name, files = group.files }
        self.page = 1
    end
    self:rebuild()
end

-- One step back: out of a series / author, or up one folder, but never above
-- the home folder.
function LibraryShelf:goBack()
    if self.drill then
        self.drill = nil
    elseif self.tab == "folders" and self.path then
        local root = self:rootDir()
        local parent = self.path:match("^(.*)/[^/]+$")
        if not parent or #parent < #root then parent = root end
        self.path = parent
    end
    self.page = 1
    self:rebuild()
end

-- The adjust button opens the View sheet (view_sheet.lua, the same as in
-- Library): Grid / List for the open chip, then Sort & Filter: Status, Sort,
-- Alphabetical and, only when the library has more than one language,
-- Language. Tapping a chosen option again clears it.
function LibraryShelf:openLayoutMenu(_anchor)
    ViewSheet.show{
        layout = {
            selected = layoutFor(self:layoutKey()),
            on_pick = function(id)
                setLayout(self:layoutKey(), id)
                self.page = 1
                self:rebuild()
            end,
        },
        status = { selected = self.status, on_pick = function(id) self:setStatus(id) end },
        sort   = { selected = self.view,  on_pick = function(id) self:setView(id) end },
        alpha  = { selected = self.alpha, on_pick = function(id) self:setAlpha(id) end },
        lang   = {
            list = self:languages(), selected = self.lang,
            on_pick = function(id) self:setLang(id) end,
        },
    }
end

function LibraryShelf:nextPage()
    if self.page < self.total_pages then
        self.page = self.page + 1
        self:rebuild()
    end
end

function LibraryShelf:prevPage()
    if self.page > 1 then
        self.page = self.page - 1
        self:rebuild()
    end
end

-- ── Widgets ────────────────────────────────────────────────────────────────
function LibraryShelf:makeChip(label, selected, onClick, font_size)
    local chip = Chip:new{ text = label, selected = selected, font_size = font_size or 15, height = self.chip_h }
    return { widget = chip, width = chip.width, height = self.chip_h, onClick = onClick }
end

-- Two buttons at the right end of the chips: View options (adjust), and
-- Settings (more). `width` covers both.
function LibraryShelf:buildAdjustButton()
    local icon = iconWidget("adjust", U(24))
    local btn = FrameContainer:new{
        bordersize = 0, margin = 0, padding = U(10), icon,
    }
    local more = FrameContainer:new{
        bordersize = 0, margin = 0, padding = U(10),
        KoboldWidgets.customIcon("more", U(24), "appbar.menu"),
    }
    local btn_w, more_w = btn:getSize().w, more:getSize().w
    return { widget = btn, width = btn_w + more_w, more_widget = more, more_w = more_w }
end

-- The chips along the top. When they all fit they sit in one row, as before.
-- When they do not (even at the small size) they are split in pages: a
-- chevron right after the last chip of a page goes to the next page of
-- chips, and from the second page on a chevron left at the start goes back.
function LibraryShelf:buildChipBar()
    local adjust = self:buildAdjustButton()
    self.adjust = adjust
    self.chips = Chips.enabledList()
    self.chip_nav = {}
    local gap = self.chip_gap
    local avail = self.width - adjust.width - gap

    local function build(size)
        local all, total = {}, 0
        for i, t in ipairs(self.chips) do
            local chip = self:makeChip(t.label, (self.tab == t.id), function() self:setTab(t.id) end, size)
            all[#all + 1] = chip
            total = total + chip.width + (i > 1 and gap or 0)
        end
        return all, total
    end

    local function finish(row, used)
        -- the adjust button sits at the right edge
        local fill = math.max(gap, self.width - used - adjust.width)
        row[#row + 1] = HorizontalSpan:new{ width = fill }
        row[#row + 1] = adjust.widget
        row[#row + 1] = adjust.more_widget
    end

    -- Everything in one row, at the big size or else at the small one.
    local all, total = build(15)
    if total > avail then all, total = build(13) end
    if total <= avail then
        self.chip_page = 1
        self.chip_pages = 1
        local row = HorizontalGroup:new{}
        for i, chip in ipairs(all) do
            if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
            row[#row + 1] = chip.widget
        end
        finish(row, total)
        return row, all
    end

    -- Pages (small size). Each page keeps room for the chevrons it needs.
    local function navButton(name)
        local btn = FrameContainer:new{
            bordersize = 0, margin = 0, padding = U(8), iconWidget(name, U(20), BLACK),
        }
        return { widget = btn, width = btn:getSize().w }
    end
    local prev_nav, next_nav = navButton("chevron-left"), navButton("chevron-right")
    local pages, i, n = {}, 1, #all
    while i <= n do
        local budget = avail - ((#pages > 0) and (prev_nav.width + gap) or 0)
        local need = 0
        for j = i, n do need = need + all[j].width + (j > i and gap or 0) end
        if need > budget then budget = budget - (next_nav.width + gap) end
        local from, used = i, 0
        while i <= n do
            local w = all[i].width + (i > from and gap or 0)
            if i > from and used + w > budget then break end
            used = used + w
            i = i + 1
        end
        pages[#pages + 1] = { from = from, to = i - 1 }
    end

    self.chip_pages = #pages

    -- Which page: the one asked for with a chevron or a swipe, else the one
    -- holding the chip that is open.
    local page = self.chip_page
    if not page or page > #pages then
        page = 1
        for idx, t in ipairs(self.chips) do
            if t.id == self.tab then
                for pi, pg in ipairs(pages) do
                    if idx >= pg.from and idx <= pg.to then page = pi end
                end
            end
        end
    end
    page = math.max(1, math.min(page, #pages))
    self.chip_page = page

    local row, visible, used = HorizontalGroup:new{}, {}, 0
    if page > 1 then
        row[#row + 1] = prev_nav.widget
        used = used + prev_nav.width + gap
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        prev_nav.onClick = function() self.chip_page = page - 1; self:rebuild() end
        self.chip_nav.prev = prev_nav
    end
    local pg = pages[page]
    for idx = pg.from, pg.to do
        local chip = all[idx]
        if idx > pg.from then
            row[#row + 1] = HorizontalSpan:new{ width = gap }
            used = used + gap
        end
        row[#row + 1] = chip.widget
        used = used + chip.width
        visible[#visible + 1] = chip
    end
    if page < #pages then
        row[#row + 1] = HorizontalSpan:new{ width = gap }
        row[#row + 1] = next_nav.widget
        used = used + gap + next_nav.width
        next_nav.onClick = function() self.chip_page = page + 1; self:rebuild() end
        self.chip_nav.next = next_nav
    end
    finish(row, used)
    return row, visible
end

-- The band the chips sit in, in screen coordinates (nil before first draw).
function LibraryShelf:chipBarRect()
    if not self.dimen then return nil end
    return Geom:new{
        x = self.dimen.x, y = self.dimen.y,
        w = self.width, h = self.chip_pad + self.chip_h + self.chip_pad,
    }
end

-- A swipe that starts on the chips turns their page, like the chevrons: left
-- goes to the next page of chips, right to the previous one. Returns false
-- when the chips fit in one row (the swipe is then left to the shelf).
function LibraryShelf:swipeChips(direction)
    local pages = self.chip_pages or 1
    if pages <= 1 then return false end
    local page = self.chip_page or 1
    if direction == "west" and page < pages then
        self.chip_page = page + 1
    elseif direction == "east" and page > 1 then
        self.chip_page = page - 1
    else
        return true  -- already at that end: nothing to do, but not a shelf swipe
    end
    self:rebuild()
    return true
end

-- Back row, shown only inside a series, author or collection: a plain arrow
-- and word (no box), the name of what is open, and a line under it.
function LibraryShelf:buildHeader()
    local title, count
    if self.drill then
        title, count = self.drill.name, #self.drill.files
    elseif self.tab == "folders" and self.path and self.path ~= self:rootDir() then
        title, count = baseName(self.path), self.folder_total or 0
    else
        return nil
    end
    local back = HorizontalGroup:new{
        iconWidget("chevron-left", U(18), BLACK),
        HorizontalSpan:new{ width = U(6) },
        TextWidget:new{ text = "Back", face = KoboldWidgets.face(17) },
    }
    self.back_w = back:getSize().w + Screen:scaleBySize(28)
    local name_w = math.max(self.width - self.back_w - Screen:scaleBySize(20), 50)
    local label = flipArticle(title) .. "  \u{00B7}  " .. count .. (count == 1 and " book" or " books")
    local row = HorizontalGroup:new{
        back,
        HorizontalSpan:new{ width = Screen:scaleBySize(28) },
        TextWidget:new{
            text = label, face = KoboldWidgets.face(17),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = name_w,
        },
    }
    return VerticalGroup:new{
        align = "left",
        LeftContainer:new{ dimen = Geom:new{ w = self.width, h = self.chip_h }, row },
        Rule:new{ width = self.width, height = math.max(1, Screen:scaleBySize(1)) },
    }
end


-- An empty book: a plain grey cover. A folder stack always shows two books,
-- and these stand where the folder has fewer, instead of leaving a gap.
local EmptyBook = Widget:extend{ width = 0, height = 0 }

function EmptyBook:getSize()
    return Geom:new{ w = self.width, h = self.height }
end

function EmptyBook:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local radius = math.max(2, U(4))
    local line = math.max(1, U(1))
    bb:paintRoundedRect(x, y, self.width, self.height, C_OUTLINE, radius)
    bb:paintRoundedRect(x + line, y + line, self.width - 2 * line, self.height - 2 * line,
        C_TRACK, math.max(1, radius - line))
end

function EmptyBook:free() end

-- A cover lying down: the finished cover turned 90 degrees clockwise, as if
-- the book had fallen to the right. It reports the lying size (w x h).
local LyingCover = Widget:extend{ child = nil, cw = 0, ch = 0, w = 0, h = 0 }

function LyingCover:getSize()
    return Geom:new{ w = self.w, h = self.h }
end

local function turnClockwise(child, cw, ch)
    local src = Blitbuffer.new(cw, ch, Blitbuffer.TYPE_BBRGB32)
    src:fill(Blitbuffer.COLOR_WHITE)
    child:paintTo(src, 0, 0)
    local dst = Blitbuffer.new(ch, cw, Blitbuffer.TYPE_BBRGB32)
    local sp, sstride = ffi.cast("uint8_t*", src.data), src.stride
    local dp, dstride = ffi.cast("uint8_t*", dst.data), dst.stride
    for y = 0, ch - 1 do
        local srow = y * sstride
        local dcol = (ch - 1 - y) * 4
        for x = 0, cw - 1 do
            local si, di = srow + x * 4, x * dstride + dcol
            dp[di], dp[di + 1], dp[di + 2], dp[di + 3] = sp[si], sp[si + 1], sp[si + 2], sp[si + 3]
        end
    end
    src:free()
    return dst
end

function LyingCover:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.w, h = self.h }
    if self.turned == nil then
        local ok, turned = pcall(turnClockwise, self.child, self.cw, self.ch)
        self.turned = ok and turned or false
    end
    if self.turned then
        bb:blitFrom(self.turned, x, y, 0, 0, self.w, self.h)
    else
        -- could not turn it: it stands up, as before
        self.child:paintTo(bb, x, y + self.h - self.ch)
    end
end

function LyingCover:free()
    if self.turned then self.turned:free(); self.turned = nil end
    if self.child and self.child.free then self.child:free() end
end

-- The name of a folder, series, author or collection: a black pill with white
-- letters lying on the foot of its stack of covers, with no outline, with the
-- number of books after the name. It is
-- centred on the front cover (center_x, in the card); a name too long for that
-- makes it grow to the right, over the second cover, up to the card's width.
local function titlePill(name, count, cell_w, cell_h, center_x)
    return CoverBadge.titlePill(flipArticle(name), count, cell_w, cell_h, center_x)
end

-- `lying`: a folder with one single book shows it lying down, as wide as the
-- stack of covers a folder with several books draws.
-- `title`: the name to show in a pill on the card (grid); nil in the list.
local function makeCard(files, cell_w, cell_h, lying, title)
    -- Two books: one in front and a smaller one behind it, peeking out to the
    -- right (a third one was too small to be of any use).
    local spec = { { 0.62, 0 }, { 0.42, 0.56 } }
    local card = OverlapGroup:new{ dimen = Geom:new{ w = cell_w, h = cell_h } }
    if lying and #files == 1 then
        -- The upright cover is as tall as the card is wide, so lying down it
        -- takes the card's width and sits on the board.
        local up = Rounded.cover(files[1], math.floor(cell_w / COVER_RATIO), cell_w, { outline = true })
        local usz = up:getSize()
        local lie = LyingCover:new{ child = up, cw = usz.w, ch = usz.h, w = usz.h, h = usz.w }
        lie.overlap_offset = { math.max(0, math.floor((cell_w - usz.h) / 2)), cell_h - usz.w }
        card[#card + 1] = lie
        if title then
            -- the lying cover is centred in the card
            card[#card + 1] = titlePill(title, #files, cell_w, cell_h,
                lie.overlap_offset[1] + math.floor(usz.h / 2))
        end
        return card
    end
    local front_center   -- the middle of the front cover, for the title pill
    for k = 2, 1, -1 do
        local bw = math.min(math.floor(cell_w * spec[k][1]), math.floor(cell_h / COVER_RATIO))
        local bh = math.floor(bw * COVER_RATIO)
        local cover, sh
        local cw = bw
        if files[k] then
            local _sw
            _sw, sh = KoboldWidgets.coverSize(files[k], bw, bh)
            sh = math.min(sh or bh, bh)
            cw = math.min(_sw or bw, bw)
            cover = Rounded.cover(files[k], bw, bh, { outline = true })
        else
            sh = bh
            cover = EmptyBook:new{ width = bw, height = bh }
        end
        -- never past the card's right edge, so nothing of it is cut off
        local cx = math.min(math.floor(cell_w * spec[k][2]), math.max(0, cell_w - bw))
        cover.overlap_offset = { cx, math.max(0, cell_h - sh) }
        card[#card + 1] = cover
        if k == 1 then front_center = cx + math.floor(cw / 2) end
    end
    if title then
        card[#card + 1] = titlePill(title, #files, cell_w, cell_h, front_center or math.floor(cell_w / 2))
    end
    return card
end

function LibraryShelf:makeCaption(name, cell_w)
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = self.cap_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = cell_w, h = self.cap_name_h },
            TextWidget:new{ text = flipArticle(name), face = KoboldWidgets.face(16), max_width = cell_w },
        },
    }
end

local function emptySlot(w, h)
    return VerticalGroup:new{ HorizontalSpan:new{ width = w }, VerticalSpan:new{ width = h } }
end

-- Sizes of a card (series, author, collection, folder: a stack of covers with
-- its name in a pill on it) and of a book cover.
-- `scale` (1 or less) shrinks the covers. The width they free is shared out
-- between them, so a row still spans the whole shelf: 4 books, or 3 cards.
-- A row is as tall for cards as for books, so every chip fits the same number
-- of rows, whatever it holds; the cards stand on the board, with a little more
-- air above them than the books have.
function LibraryShelf:shelfMetrics(scale)
    scale = scale or 1
    -- Columns come from setColumns(): 4 books or 3 cards in portrait on a
    -- 6" e-reader, more on a wide screen or in landscape.
    local nb, nc = self.cols_book or 4, self.cols_card or 3
    local base_gap = self.gap
    local wb = math.floor((self.width - base_gap * (nb - 1)) / nb)
    local bw = math.floor(wb * scale)
    local gap = base_gap
    if scale < 1 then
        -- The covers got smaller: work the columns out again from their real
        -- width, so another one fits across when there is room for it, instead
        -- of the width they freed turning into wide gaps between the books.
        local fit = KoboldMetrics.fitRow(self.width, base_gap, bw, nb)
        if fit > nb then
            nb = fit
            nc = math.max(2, math.floor(nb * 3 / 4))
        end
        gap = math.floor((self.width - nb * bw) / (nb - 1))
    end
    local wc = math.floor((self.width - gap * (nc - 1)) / nc)
    local book = { w = bw, h = math.floor(bw * COVER_RATIO) }
    return {
        gap = gap,
        book_cols = nb, card_cols = nc,
        -- no caption row: the name is a pill on the stack of covers (makeCard)
        card = { w = wc, h = book.h, cap_h = 0 },
        book = book,
    }
end

-- How many books (and cards) fit across a row of the shelf, from its width
-- and the height `avail` it has: the covers aim for a set width, and get
-- smaller, with more of them across, when the screen is too short for that.
-- A shelf needs only one row (landscape has little height under the recent
-- row and the chips; the page holds more covers across instead).
function LibraryShelf:setColumns(avail)
    local fixed = self.top_min + self.board_h + 2
    local nb = KoboldMetrics.gridCols(self.width, self.gap, avail, 0, 0, fixed, 1)
    self.cols_book = nb
    -- 3 cards stand where 4 books do
    self.cols_card = math.max(2, math.floor(nb * 3 / 4))
end

-- Grid: how much to shrink the covers so one more row fits on a page, worked
-- out from the height of a row of books for every chip (cards use the same row
-- height), so the covers are the same size and a page has the same number of
-- rows in all of them. The columns come from setColumns() and the covers
-- cannot grow: they shrink by
-- up to 20% when that makes the rows fill the page, and up to 45% when that is
-- what it takes for a second row to fit (the list view fits two rows easily, so
-- the grid should too). Otherwise they keep their size and the spare height
-- becomes air and empty shelves, as before.
function LibraryShelf:fitScale(entries, avail)
    local m = self:shelfMetrics(1)
    local fixed, flex = self.top_min + self.board_h, m.book.h
    local rows = math.ceil(avail / (fixed + flex))
    if rows < 1 then return 1 end
    -- 2 px of slack per row, so rounding never pushes the last row off the page
    local sc = (avail / rows - fixed - 2) / flex
    local min_scale = (rows == 2) and 0.55 or 0.80
    if sc >= min_scale and sc < 1 then
        -- If those smaller covers leave wide gaps and are not far from the size
        -- that lets one more column in, take that size: the covers are only a
        -- little smaller (the rows still fit) and the gaps stay tight.
        local nb = self.cols_book or 4
        if nb > 1 then
            local base_gap = self.gap
            local wb = math.floor((self.width - base_gap * (nb - 1)) / nb)
            local bw = math.floor(wb * sc)
            local gap_now = (self.width - nb * bw) / (nb - 1)
            if gap_now > base_gap * 1.8 then
                local bw_next = math.floor((self.width - base_gap * nb) / (nb + 1))
                local sn = bw_next / wb
                if sn >= 0.70 and sn < sc then return sn end
            end
        end
        return sc
    end
    return 1
end

-- The things to show as one flat list: { kind = "card" | "book", data }.
local function toEntries(kind, items)
    local out = {}
    if kind == "mixed" then
        for _i, f in ipairs(items.folders) do out[#out + 1] = { kind = "card", data = f } end
        for _i, b in ipairs(items.books) do out[#out + 1] = { kind = "book", data = b } end
    elseif kind == "groups" then
        for _i, g in ipairs(items) do out[#out + 1] = { kind = "card", data = g } end
    else
        for _i, b in ipairs(items) do out[#out + 1] = { kind = "book", data = b } end
    end
    return out
end

-- How far a book is: a fraction, and whether it is finished.
local function readState(file)
    local ok, info = pcall(KoboldLibrary.getDocInfoCached, file)
    info = (ok and type(info) == "table") and info or {}
    local pct = tonumber(info.percent)
    if info.status == "abandoned" then return pct, false, true end   -- On hold
    if info.status == "complete" or (pct and pct >= 1) then return 1, true end
    if pct and pct > 0 then return pct, false end
    return nil, false
end

-- Grid: covers and cards standing on boards. They flow left to right and a
-- row takes whatever fits, so a lone folder shares its shelf with books
-- instead of leaving the rest of the row empty. Pages are filled row by row,
-- the space left on a page becomes empty shelves, and what remains is shared
-- out as air above each row.
function LibraryShelf:buildShelves(entries, avail)
    self:setColumns(avail)
    local m = self:shelfMetrics(self:fitScale(entries, avail))
    local gap = m.gap
    local boards = Chips.shelvesOn(self.tab)   -- false: same layout, boards not drawn

    local rows, cur, curw = {}, nil, 0
    for _i, e in ipairs(entries) do
        local w = (e.kind == "card") and m.card.w or m.book.w
        if not cur or curw + gap + w > self.width then
            cur = { items = { e } }
            rows[#rows + 1] = cur
            curw = w
        else
            cur.items[#cur.items + 1] = e
            curw = curw + gap + w
        end
    end
    for _i, r in ipairs(rows) do
        local has_card, has_book = false, false
        for _j, e in ipairs(r.items) do
            if e.kind == "card" then has_card = true else has_book = true end
        end
        r.cell_h = math.max(has_card and m.card.h or 0, has_book and m.book.h or 0)
        r.cap_h  = has_card and m.card.cap_h or 0
        r.h      = self.top_min + r.cell_h + self.board_h + r.cap_h
    end

    -- Greedy page breaks
    local pages, pg, used = {}, nil, 0
    for i, r in ipairs(rows) do
        if not pg or used + r.h > avail then
            pg = { first = i, last = i }
            pages[#pages + 1] = pg
            used = r.h
        else
            pg.last = i
            used = used + r.h
        end
    end
    self.total_pages = math.max(1, #pages)
    if self.page > self.total_pages then self.page = self.total_pages end
    if self.page < 1 then self.page = 1 end

    local page_rows = {}
    used = 0
    local cur_page = pages[self.page]
    if cur_page then
        for i = cur_page.first, cur_page.last do
            page_rows[#page_rows + 1] = rows[i]
            used = used + rows[i].h
        end
    end
    if #page_rows > 0 then
        local last = page_rows[#page_rows]
        local only_cards = true
        for _i, e in ipairs(last.items) do if e.kind ~= "card" then only_cards = false end end
        local pad
        if only_cards then
            pad = { items = {}, pad_n = m.card_cols, pad_w = m.card.w, cell_h = m.card.h, cap_h = m.card.cap_h }
        else
            pad = { items = {}, pad_n = m.book_cols, pad_w = m.book.w, cell_h = m.book.h, cap_h = 0 }
        end
        pad.h = self.top_min + pad.cell_h + self.board_h + pad.cap_h
        while boards and avail - used >= pad.h do
            local copy = {}
            for k, v in pairs(pad) do copy[k] = v end
            page_rows[#page_rows + 1] = copy
            used = used + pad.h
        end
    end
    -- Spare height becomes a little air above each row, never big gaps: what
    -- is left stays empty at the bottom of the page.
    local per = (#page_rows > 0) and math.floor(math.max(0, avail - used) / #page_rows) or 0
    per = math.min(per, U(10))

    self.page_items, self.page_kinds, self.item_rects = {}, {}, {}
    local slot, y = 0, 0
    local rows_out = {}
    for _i, r in ipairs(page_rows) do
        local top_gap = self.top_min + per
        local slots = r.items
        if #slots == 0 then
            slots = {}
            for k = 1, r.pad_n do slots[k] = { kind = "empty" } end
        end
        local cells, caps, x = HorizontalGroup:new{}, HorizontalGroup:new{}, 0
        for k, e in ipairs(slots) do
            local w = (e.kind == "card") and m.card.w
                or (e.kind == "book") and m.book.w or r.pad_w
            if e.kind == "card" then
                local files = e.data.files
                slot = slot + 1
                local bw = math.min(math.floor(w * 0.62), math.floor(r.cell_h / COVER_RATIO))
                local h1 = math.floor(bw * COVER_RATIO)
                self.page_items[slot], self.page_kinds[slot] = e.data, "cards"
                self.item_rects[slot] = { x = x, y = y + top_gap + r.cell_h - h1, w = w, h = h1 }
                cells[#cells + 1] = makeCard(files, w, r.cell_h, nil, e.data.name)
            elseif e.kind == "book" then
                local sw, sh = KoboldWidgets.coverBox(e.data, w, m.book.h)
                sw = math.min(sw or w, w)
                sh = math.min(sh or m.book.h, m.book.h)
                slot = slot + 1
                self.page_items[slot], self.page_kinds[slot] = e.data, "books"
                self.item_rects[slot] = { x = x, y = y + top_gap + (r.cell_h - sh), w = sw, h = sh }
                local pct, done, onhold = readState(e.data)
                cells[#cells + 1] = OverlapGroup:new{
                    dimen = Geom:new{ w = w, h = r.cell_h },
                    VerticalGroup:new{
                        align = "left",
                        VerticalSpan:new{ width = r.cell_h - sh },
                        LeftContainer:new{
                            dimen = Geom:new{ w = w, h = sh },
                            Rounded.cover(e.data, w, m.book.h, { outline = true }),
                        },
                    },
                    -- the same badge as Library: percentage read, or "Read"
                    CoverBadge.Overlay:new{
                        w = w, h = r.cell_h,
                        rect = { x = 0, y = r.cell_h - sh, w = sw, h = sh },
                        badge = CoverBadge.make(pct, done, onhold),
                        path = e.data,
                    },
                }
                if r.cap_h > 0 then caps[#caps + 1] = emptySlot(w, r.cap_h) end
            else
                cells[#cells + 1] = emptySlot(w, r.cell_h)
                if r.cap_h > 0 then caps[#caps + 1] = emptySlot(w, r.cap_h) end
            end
            if k < #slots then
                cells[#cells + 1] = HorizontalSpan:new{ width = gap }
                if r.cap_h > 0 then caps[#caps + 1] = HorizontalSpan:new{ width = gap } end
            end
            x = x + w + gap
        end
        rows_out[#rows_out + 1] = VerticalSpan:new{ width = top_gap }
        rows_out[#rows_out + 1] = cells
        rows_out[#rows_out + 1] = ShelfBoard:new{ width = self.width, height = self.board_h, hidden = not boards }
        if r.cap_h > 0 then rows_out[#rows_out + 1] = caps end
        y = y + top_gap + r.cell_h + self.board_h + r.cap_h
    end
    rows_out.align = "left"
    return VerticalGroup:new(rows_out)
end

-- List, built like the reference rows: the cover on the left, a bold title
-- (two lines at most), the author in grey, then a thin rounded progress bar
-- with "NN% Read" beside it. Cards (folders, series, authors, collections)
-- put their stack of covers where the cover goes and show the name and how
-- many books they hold. Grey lines separate the folder rows only.
function LibraryShelf:buildList(entries, avail)
    local line_h   = math.max(1, U(1))
    -- The number of rows that fits best is chosen, and the covers grow or
    -- shrink a little so those rows fill the page exactly. A row is the cover
    -- plus a margin of 8% of it above and below (about 1.16 x the cover).
    local base_thumb = U(110)
    local base_row   = base_thumb + 2 * math.floor(base_thumb * 0.08)
    local min_thumb  = math.floor(base_thumb * 0.88)   -- below this the text no longer fits
    local min_row    = min_thumb + 2 * math.floor(min_thumb * 0.08)
    local rows = math.floor((avail + line_h) / (base_row + line_h) + 0.5)
    rows = math.min(rows, math.floor((avail + line_h) / (min_row + line_h)))
    rows = math.max(1, rows)
    local row_target = math.floor((avail + line_h) / rows) - line_h
    local thumb_h  = math.floor(row_target / 1.16)
    local margin   = math.floor((row_target - thumb_h) / 2)
    local book_w   = math.floor(thumb_h * 0.72)
    local card_w   = thumb_h
    local col_w    = math.max(book_w, card_w)
    local row_h    = thumb_h + 2 * margin
    local text_gap = math.floor(thumb_h * 0.15)
    local text_w   = self.width - col_w - text_gap
    local arrow_w  = U(36)                       -- room for the arrow on folder rows
    local card_text_w = text_w - arrow_w
    local gap      = U(4)

    self.total_pages = math.max(1, math.ceil(#entries / rows))
    if self.page > self.total_pages then self.page = self.total_pages end
    if self.page < 1 then self.page = 1 end

    local start_i = (self.page - 1) * rows + 1
    local count_on_page = math.min(rows, #entries - start_i + 1)
    self.page_items, self.page_kinds, self.item_rects = {}, {}, {}

    local title_face = KoboldWidgets.face(17)
    local tline_h = math.floor((title_face.size or U(17)) * 1.3 + 0.5)
    local function titleWidget(text, w)
        return TextBoxWidget:new{
            text = text, face = title_face, bold = true, width = w or text_w,
            height = 2 * tline_h, height_adjust = true, height_overflow_show_ellipsis = true,
        }
    end
    local function grey(text, size, w)
        return TextWidget:new{ text = text, face = KoboldWidgets.face(size), fgcolor = C_SECONDARY, max_width = w or text_w }
    end

    local out = {}
    local y_acc = 0
    for r = 1, count_on_page do
        local e = entries[start_i + r - 1]
        local thumb, texts, thumb_box
        if e.kind == "card" then
            local count = #e.data.files
            thumb = makeCard(e.data.files, card_w, thumb_h)
            texts = VerticalGroup:new{
                align = "left",
                titleWidget(flipArticle(e.data.name), card_text_w),
                VerticalSpan:new{ width = gap },
                grey(count .. (count == 1 and " book" or " books"), 14, card_text_w),
            }
            thumb_box = LeftContainer:new{ dimen = Geom:new{ w = col_w, h = thumb_h }, thumb }
            self.page_kinds[r] = "cards"
        else
            local file = e.data
            local m = readMeta(file)
            thumb = Rounded.cover(file, book_w, thumb_h, { outline = true })
            texts = VerticalGroup:new{ align = "left", titleWidget(m.title) }
            if m.authors[1] then
                texts[#texts + 1] = VerticalSpan:new{ width = gap }
                texts[#texts + 1] = grey(m.authors[1], 14)
            end
            local pct, done, onhold = readState(file)
            if onhold then
                -- On hold: the same tag as Read, then how far the book got
                -- (no bar).
                texts[#texts + 1] = VerticalSpan:new{ width = gap }
                local hold = HorizontalGroup:new{
                    align = "center",
                    FrameContainer:new{
                        bordersize = 0, margin = 0, radius = U(7), background = C_TAG,
                        padding_left = U(12), padding_right = U(12), padding_top = U(3), padding_bottom = U(3),
                        TextWidget:new{ text = "On hold", face = KoboldWidgets.face(13), fgcolor = BLACK },
                    },
                }
                if pct and pct > 0 then
                    hold[#hold + 1] = HorizontalSpan:new{ width = U(10) }
                    hold[#hold + 1] = grey(math.floor(pct * 100 + 0.5) .. "%", 13)
                end
                texts[#texts + 1] = hold
            elseif done then
                texts[#texts + 1] = VerticalSpan:new{ width = gap }
                texts[#texts + 1] = FrameContainer:new{
                    bordersize = 0, margin = 0, radius = U(7), background = C_TAG,
                    padding_left = U(12), padding_right = U(12), padding_top = U(3), padding_bottom = U(3),
                    TextWidget:new{ text = "Read", face = KoboldWidgets.face(13), fgcolor = BLACK },
                }
            elseif pct then
                local label = grey(math.floor(pct * 100 + 0.5) .. "% Read", 13)
                local space = U(14)
                local bar_w = math.min(U(110), text_w - label:getSize().w - space)
                texts[#texts + 1] = VerticalSpan:new{ width = gap }
                texts[#texts + 1] = HorizontalGroup:new{
                    align = "center",
                    ProgressBar:new{ width = math.max(bar_w, U(30)), height = math.max(3, U(5)), percentage = pct },
                    HorizontalSpan:new{ width = space },
                    label,
                }
            end
            -- A single book is narrower than a folder's stack: centre it in the
            -- same column so the gap before the title is shared on both sides.
            -- With the "Opening" pill over it while the book opens.
            local tw, th = KoboldWidgets.coverBox(file, book_w, thumb_h, { outline = true })
            tw, th = math.min(tw or book_w, book_w), math.min(th or thumb_h, thumb_h)
            thumb_box = OverlapGroup:new{
                dimen = Geom:new{ w = col_w, h = thumb_h },
                CenterContainer:new{ dimen = Geom:new{ w = col_w, h = thumb_h }, thumb },
                CoverBadge.Overlay:new{
                    w = col_w, h = thumb_h, path = file,
                    rect = {
                        x = math.floor((col_w - tw) / 2), y = math.floor((thumb_h - th) / 2),
                        w = tw, h = th,
                    },
                },
            }
            self.page_kinds[r] = "books"
        end
        self.page_items[r] = e.data
        local row = HorizontalGroup:new{
            thumb_box,
            HorizontalSpan:new{ width = text_gap },
            LeftContainer:new{ dimen = Geom:new{ w = (e.kind == "card") and card_text_w or text_w, h = thumb_h }, texts },
        }
        if e.kind == "card" then
            row[#row + 1] = RightContainer:new{
                dimen = Geom:new{ w = arrow_w, h = thumb_h },
                iconWidget("chevron-right", U(16), C_SECONDARY),
            }
        end
        out[#out + 1] = VerticalSpan:new{ width = margin }
        out[#out + 1] = row
        out[#out + 1] = VerticalSpan:new{ width = margin }
        self.item_rects[r] = { x = 0, y = y_acc, w = self.width, h = row_h }
        y_acc = y_acc + row_h
        -- A grey line only under folder rows (to set folders apart from each
        -- other and from the books that follow); never between two books.
        if e.kind == "card" and r < count_on_page then
            out[#out + 1] = Rule:new{ width = self.width, height = line_h }
            y_acc = y_acc + line_h
        end
    end
    out.align = "left"
    return VerticalGroup:new(out)
end

function LibraryShelf:rebuild()
    self:syncView()
    self.needs_tap_registration = true
    local chip_row, main_chips = self:buildChipBar()
    self.main_chips = main_chips

    local kind, items = self:computeItems()
    local header = self:buildHeader()
    if not header then self.back_w = nil end

    local chips_h  = self.chip_pad + self.chip_h + self.chip_pad
    local header_h = header and (self.chip_h + math.max(1, Screen:scaleBySize(1)) + self.chip_pad) or 0
    -- The page indicator lives in the nav bar, so the list goes right down to
    -- it; the small cover of the last book may overlap the last row.
    local avail    = self.height - chips_h - header_h
    self.grid_y    = chips_h + header_h

    local entries = toEntries(kind, items)
    local empty = (#entries == 0)

    local body
    if empty then
        self.page_items, self.page_kinds, self.item_rects, self.total_pages = {}, {}, {}, 1
        local msg = "Nothing here yet"
        if self.tab == "folders" then
            msg = "No books in this folder."
        elseif self.tab == "series" then
            msg = "No series found in your books. Your collections are under Collections."
        elseif self.tab == "authors" then
            msg = "No authors found yet. Open a book once so its info gets read."
        elseif self.tab == "collections" then
            msg = "No collections yet. Make one from a book's menu in the file browser."
        elseif self.tab == "genres" then
            msg = "No genres found. They come from the keywords of your books."
        elseif self.tab == "favorites" then
            msg = "No books in Favorites yet. Add one from a book's menu in the file browser."
        elseif self.tab == "tbr" then
            msg = "No books in To be read yet. Add one from a book's menu in the file browser."
        elseif customPath(self.tab) then
            msg = "No books in this folder."
        elseif customCollection(self.tab) then
            msg = "No books in this collection yet. Add one from a book's menu in the file browser."
        end
        body = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = Screen:scaleBySize(24) },
            TextWidget:new{ text = msg, face = KoboldWidgets.face(16), max_width = self.width },
        }
    elseif layoutFor(self:layoutKey()) == "list" then
        body = self:buildList(entries, avail)
    else
        body = self:buildShelves(entries, avail)
    end

    local children = {
        align = "left",
        VerticalSpan:new{ width = self.chip_pad },
        LeftContainer:new{ dimen = Geom:new{ w = self.width, h = self.chip_h }, chip_row },
        VerticalSpan:new{ width = self.chip_pad },
    }
    if header then
        children[#children + 1] = header
        children[#children + 1] = VerticalSpan:new{ width = self.chip_pad }
    end
    children[#children + 1] = body
    self.child = VerticalGroup:new(children)

    if self.home then
        local UIManager = require("ui/uimanager")
        UIManager:setDirty(self.home, "ui")
    end
end

-- ── More menu ──────────────────────────────────────────────────────────────
-- The more button of Home: Refresh library and Settings (the same two rows as
-- the More menu of Library's Books tab). `anchor` is the button's rectangle.
function LibraryShelf:openMoreMenu(anchor)
    local _ = require("gettext")
    local items = {
        { text = _("Refresh library"), icon = { "refresh-cw", "undo" },
          action = function() self:refreshLibrary() end },
        { text = _("Settings"), icon = { "settings", "settings-2" },
          action = function() require("kobold.ui.settings").show() end },
    }
    require("kobold.ui.book_menu").show{
        screen = self.home, anchor = anchor, align = "right", items = items,
    }
end

-- Refresh library: the disk is scanned again and everything Kobold remembered
-- about the books (titles, authors, languages, genres, KOReader's metadata
-- changes) is forgotten and read anew; then Home is drawn again. The chip,
-- view and page of the shelf stay as they were.
function LibraryShelf:refreshLibrary()
    local home = self.home
    if not home then return end
    local _ = require("gettext")
    local Toast = require("kobold.ui.toast")
    local working = Toast.working(_("Refreshing…"))
    KoboldLibrary.forgetAll()
    LibraryShelf.invalidateMeta()
    home:loadData()
    home:refreshCovers()
    Toast.dismiss(working)
    Toast.show(_("Library refreshed."))
end

-- ── Touch ──────────────────────────────────────────────────────────────────
-- A tap zone that can never fire: parks an unused name off screen so a zone
-- left over from an earlier layout cannot answer taps.
local function park(home, name)
    KoboldTaps.add(home, name, -1000, -1000, 1, 1, function() end)
end
local function parkHold(home, name)
    KoboldTaps.hold(home, name, -1000, -1000, 1, 1, function() end)
end

function LibraryShelf:registerTaps()
    local home = self.home
    if not home or not self.dimen then return end

    -- Chips that are on can outnumber MAX_TABS if older settings were saved.
    for i = 1, math.max(MAX_TABS, #(self.chips or {})) do
        local chip = self.main_chips[i]
        local d = chip and chip.widget.dimen
        if d then
            KoboldTaps.add(home, "shelf_mchip_" .. i, d.x, d.y, d.w, d.h, chip.onClick)
        else
            park(home, "shelf_mchip_" .. i)
        end
    end

    -- The chevrons that page through the chips, when there are more than fit.
    for _i, which in ipairs({ "prev", "next" }) do
        local nav = self.chip_nav and self.chip_nav[which]
        local d = nav and nav.widget.dimen
        if d then
            KoboldTaps.add(home, "shelf_chip_" .. which, d.x, d.y, d.w, d.h, nav.onClick)
        else
            park(home, "shelf_chip_" .. which)
        end
    end

    local ad = self.adjust and self.adjust.widget.dimen
    if ad then
        KoboldTaps.add(home, "shelf_adjust", ad.x, ad.y, ad.w, ad.h, function() self:openLayoutMenu(ad) end)
    else
        park(home, "shelf_adjust")
    end

    -- The more button opens a small menu: Refresh library and Settings.
    local mr = self.adjust and self.adjust.more_widget and self.adjust.more_widget.dimen
    if mr then
        KoboldTaps.add(home, "shelf_more", mr.x, mr.y, mr.w, mr.h, function()
            self:openMoreMenu(Geom:new{ x = mr.x, y = mr.y, w = mr.w, h = mr.h })
        end)
    else
        park(home, "shelf_more")
    end

    -- The whole Back row answers (arrow, word and name), not just its left end.
    if self.back_w then
        local by = self.dimen.y + self.chip_pad + self.chip_h + self.chip_pad
        KoboldTaps.add(home, "shelf_back", self.dimen.x, by, self.width, self.chip_h,
            function() self:goBack() end)
    else
        park(home, "shelf_back")
    end

    -- Books and cards: rectangles worked out while building, relative to the
    -- top-left of the shelves.
    local ox = self.dimen.x
    local oy = self.dimen.y + self.grid_y
    for i = 1, MAX_GRID do
        local rc   = self.item_rects[i]
        local item = self.page_items and self.page_items[i]
        local kind = self.page_kinds and self.page_kinds[i]
        if rc and item then
            local x, y, w, h = ox + rc.x, oy + rc.y, rc.w, rc.h
            if kind == "cards" then
                KoboldTaps.add(home, "shelf_grid_" .. i, x, y, w, h, function() self:openGroup(item) end)
                parkHold(home, "shelf_grid_hold_" .. i)
            else
                KoboldTaps.add(home, "shelf_grid_" .. i, x, y, w, h, function()
                    if self.onTapFile then self.onTapFile(item) end
                end)
                KoboldTaps.hold(home, "shelf_grid_hold_" .. i, x, y, w, h, function()
                    if self.onHoldFile then
                        self.onHoldFile(item, Geom:new{ x = x, y = y, w = w, h = h })
                    end
                end)
            end
        else
            park(home, "shelf_grid_" .. i)
            parkHold(home, "shelf_grid_hold_" .. i)
        end
    end
end

return LibraryShelf
