-- kobold/data/mybooks.lua — Kobold
-- Book list for the My Books screen: one entry per book with its title,
-- authors, series, reading status, format and file size, plus filtering,
-- sorting and grouping by author, series, collection or genre. Builds no widgets.

local lfs             = require("libs/libkoreader-lfs")
local KoboldBookInfo  = require("kobold.data.bookinfo")
local KoboldLibrary   = require("kobold.data.library")
local KoboldPerf      = require("kobold.data.perf")
local Chips             = require("kobold.data.chips")
local BookLang          = require("kobold.data.booklang")
local Genres            = require("kobold.data.genres")
local _               = require("gettext")

local KoboldMyBooksData = {}

-- Filter ids in menu order. "onhold" is KOReader's On hold status (abandoned).
KoboldMyBooksData.FILTERS = { "all", "reading", "unread", "finished", "onhold" }

-- Sort ids in menu order. "added" is the file's modification time, the same
-- order the library scan uses.
-- "opened" is the last time the book was opened, from KOReader's history;
-- never opened books come last, newest added first.
KoboldMyBooksData.SORTS = { "opened_desc", "added_desc", "added_asc", "title_asc", "title_desc" }

-- { [file] = time } of every book in KOReader's history.
local function openedTimes()
    local times = {}
    local ok, RH = pcall(require, "readhistory")
    if ok and RH and type(RH.hist) == "table" then
        for _i, h in ipairs(RH.hist) do
            if h.file and h.time then times[h.file] = h.time end
        end
    end
    return times
end

-- Sort ids of the Sort & Filter sheet (shared with Home). With none chosen the
-- list is newest added first. "recent" is the last time a book was opened,
-- "oldest" the opposite (never opened books first), "added_*" the file's
-- modification time.
KoboldMyBooksData.VIEW_SORTS = { "recent", "oldest", "added_newest", "added_oldest" }

-- Sort ids for the Authors, Series and Collections lists.
KoboldMyBooksData.GROUP_SORTS = { "name_asc", "name_desc" }

-- KOReader keeps several authors in one string, one per line.
local function splitAuthors(authors)
    local list = {}
    if type(authors) ~= "string" then return list end
    for name in authors:gmatch("[^\n]+") do
        name = name:match("^%s*(.-)%s*$")
        if name ~= "" then list[#list + 1] = name end
    end
    return list
end

local function nonEmpty(s)
    if type(s) == "string" and s ~= "" then return s end
    return nil
end

local function fileTitle(file)
    return file:match("([^/]+)%.[^%.]+$") or file
end

-- Some books store the number in the series name ("Name #3"). Returns the
-- name and number, or the name unchanged when there is no number.
local function splitSeries(series, index)
    if not series or index then return series, index end
    local name, num = series:match("^(.-)%s*#%s*([%d%.]+)$")
    if name and name ~= "" and tonumber(num) then return name, tonumber(num) end
    return series, index
end

-- One entry for the list:
--   file, mtime, title, sort_key (lowercase title), authors ("A, B" or nil),
--   author_list ({ "A", "B" }), series (or nil), series_index (or nil),
--   status ("unread"|"reading"|"onhold"|"finished", nil until resolved),
--   percent (0..1, or nil), ext ("EPUB"), size (bytes, or nil)
-- `book` is { file, mtime, size } from the scan, `props` the cover browser's
-- row for it (or nil). Built from those two alone, with no file reads, so the
-- whole library is cheap to list. Reading status comes later, from the
-- sidecar, and only for the books that need it (see resolve).
local function buildEntry(book, props)
    local file = book.file
    props = props or {}
    local title = nonEmpty(props.title)
    local author_list = splitAuthors(nonEmpty(props.authors))
    local series, series_index = splitSeries(nonEmpty(props.series), tonumber(props.series_index))
    return {
        file = file,
        mtime = book.mtime or 0,
        title = title or fileTitle(file),
        title_from_file = title == nil,
        sort_key = (title or fileTitle(file)):lower(),
        authors = #author_list > 0 and table.concat(author_list, ", ") or nil,
        author_list = author_list,
        series = series,
        series_index = series_index,
        status = nil,  -- set by resolve()
        percent = nil,
        ext = (file:match("%.([^%./]+)$") or ""):upper(),
        size = book.size or lfs.attributes(file, "size"),
    }
end

-- Sidecar facts kept between calls: { [file] = { stamp, status, percent,
-- title, authors, series, series_index } }. Re-read only when the sidecar's
-- stamp changes (the book was read, its status set, ...).
local sidecar_memo = {}

-- Forgets the remembered sidecar facts (KOReader changed some metadata).
function KoboldMyBooksData.forget()
    sidecar_memo = {}
end

local function readSidecar(file)
    local stamp = KoboldLibrary.sidecarStamp(file)
    local m = sidecar_memo[file]
    if m and m.stamp == stamp then return m end
    m = { stamp = stamp, status = "unread" }
    if stamp ~= nil then
        local info = KoboldLibrary.getDocInfoCached(file) or {}
        if info.status == "complete" then
            m.status = "finished"
        elseif info.status == "abandoned" then
            m.status = "onhold"
        elseif (info.percent and info.percent > 0) or info.status == "reading" then
            m.status = "reading"
        end
        m.percent = info.percent
        m.title, m.authors = nonEmpty(info.title), nonEmpty(info.authors)
        m.series, m.series_index = nonEmpty(info.series), tonumber(info.series_index)
    end
    sidecar_memo[file] = m
    return m
end

-- Fills in status and progress (and, for books the cover browser has not
-- read, title, authors and series from the sidecar) on `entries`. Books
-- never opened cost one folder lookup; opened ones are read once per change.
function KoboldMyBooksData.resolve(entries)
    for _i, e in ipairs(entries) do
        if e then
            local m = readSidecar(e.file)
            e.status, e.percent = m.status, m.percent
            if e.title_from_file and m.title then
                e.title, e.sort_key, e.title_from_file = m.title, m.title:lower(), false
            end
            if not e.authors and m.authors then
                e.author_list = splitAuthors(m.authors)
                e.authors = #e.author_list > 0 and table.concat(e.author_list, ", ") or nil
            end
            if not e.series and m.series then
                e.series, e.series_index = splitSeries(m.series, m.series_index)
            end
        end
    end
    return entries
end

-- Every book in the library, as list entries in library scan order. No
-- sidecar is read here; call resolve() on the entries that are shown.
function KoboldMyBooksData.getBooks()
    local t = KoboldPerf.start()
    local scan = KoboldLibrary.scan()
    local meta = KoboldBookInfo.getMap()
    local books = {}
    for i, book in ipairs(scan) do
        books[i] = buildEntry(book, meta[book.file])
    end
    KoboldPerf.log("my books entries", t, "books=%d", #books)
    return books
end

-- Reading status of one book: "unread", "reading", "onhold" or "finished". Read from
-- its sidecar once per change (see readSidecar).
function KoboldMyBooksData.statusOf(file)
    return readSidecar(file).status
end

-- Entries (or paths) of `books` in language `lang`, in the same order. Without
-- a language, all of them.
function KoboldMyBooksData.byLanguage(books, lang)
    if not lang then return books end
    local out = {}
    for _i, b in ipairs(books) do
        if BookLang.of(type(b) == "table" and b.file or b) == lang then out[#out + 1] = b end
    end
    return out
end

-- Entries of `books` that match filter id `filter`, in the same order. Any
-- filter but All needs every book's status, so all of them are resolved.
function KoboldMyBooksData.filter(books, filter)
    if filter == "all" then return books end
    local t = KoboldPerf.start()
    KoboldMyBooksData.resolve(books)
    KoboldPerf.log("my books filter resolve", t, "books=%d", #books)
    local out = {}
    for _i, b in ipairs(books) do
        if b.status == filter then out[#out + 1] = b end
    end
    return out
end

-- Title order, then path, so books with the same title keep a stable order.
local function byTitle(a, b)
    if a.sort_key ~= b.sort_key then return a.sort_key < b.sort_key end
    return a.file < b.file
end

-- New table with `books` sorted by sort id `sort`. Ties are broken by title,
-- so the list does not shuffle between page turns.
function KoboldMyBooksData.sort(books, sort)
    local out = {}
    for i, b in ipairs(books) do out[i] = b end
    local cmp
    if sort == "added_asc" then
        cmp = function(a, b)
            if a.mtime ~= b.mtime then return a.mtime < b.mtime end
            return byTitle(a, b)
        end
    elseif sort == "opened_desc" then
        local times = openedTimes()
        cmp = function(a, b)
            local ta, tb = times[a.file] or 0, times[b.file] or 0
            if ta ~= tb then return ta > tb end
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return byTitle(a, b)
        end
    elseif sort == "title_asc" then
        cmp = byTitle
    elseif sort == "title_desc" then
        cmp = function(a, b) return byTitle(b, a) end
    else -- added_desc
        cmp = function(a, b)
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return byTitle(a, b)
        end
    end
    table.sort(out, cmp)
    return out
end

-- New table with `books` ordered by the Sort & Filter sheet: `sort` is one of
-- VIEW_SORTS (nil: newest added first) and `alpha` is "az" or "za" (nil: none).
-- With a sort, the alphabetical order only breaks its ties; with no sort it
-- orders the list by title on its own.
function KoboldMyBooksData.arrange(books, sort, alpha)
    local out = {}
    for i, b in ipairs(books) do out[i] = b end
    local function tie(a, b)
        if alpha == "za" then return byTitle(b, a) end
        return byTitle(a, b)
    end
    local cmp
    if not sort and alpha then
        cmp = tie
    elseif sort == "recent" or sort == "oldest" then
        local times = openedTimes()
        local newest = (sort == "recent")
        cmp = function(a, b)
            local ta, tb = times[a.file] or 0, times[b.file] or 0
            if ta ~= tb then
                if newest then return ta > tb end
                return ta < tb
            end
            if not alpha and a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return tie(a, b)
        end
    elseif sort == "added_oldest" then
        cmp = function(a, b)
            if a.mtime ~= b.mtime then return a.mtime < b.mtime end
            return tie(a, b)
        end
    else -- added_newest, or nothing chosen
        cmp = function(a, b)
            if a.mtime ~= b.mtime then return a.mtime > b.mtime end
            return tie(a, b)
        end
    end
    table.sort(out, cmp)
    return out
end

-- Display name of a KOReader collection. The built-in one is stored as
-- "favorites" and shown as Favorites, as in KOReader's own collection list.
local function collectionTitle(RC, name)
    if name == (RC.default_collection_name or "favorites") then return _("Favorites") end
    return name
end

-- Groups for the Authors, Series, Collections or Genres tab (`kind` is
-- "authors", "series", "collections" or "genres"). Each group is
--   { key, name, books = { entry, ... }, unknown = true for "Unknown author" }
-- with its books in reading order: by title for an author or a genre, by
-- series number for a series, and in the collection's own order for a
-- collection. Books without a series are left out of Series, and books with
-- no keywords out of Genres (a book with several keywords is in several
-- genres, as a book with several authors is under each). Empty collections
-- are kept.
function KoboldMyBooksData.getGroups(books, kind)
    local groups, by_key = {}, {}
    local function group(key, name)
        local g = by_key[key]
        if not g then
            g = { key = key, name = name, books = {}, order = {} }
            by_key[key] = g
            groups[#groups + 1] = g
        end
        return g
    end

    if kind == "authors" then
        for _i, b in ipairs(books) do
            if #b.author_list == 0 then
                local g = group("\0unknown", _("Unknown author"))
                g.unknown = true
                g.books[#g.books + 1] = b
            else
                for _j, name in ipairs(b.author_list) do
                    local g = group(name:lower(), name)
                    g.books[#g.books + 1] = b
                end
            end
        end
    elseif kind == "series" then
        for _i, b in ipairs(books) do
            if b.series then
                local g = group(b.series:lower(), b.series)
                g.books[#g.books + 1] = b
            end
        end
    elseif kind == "genres" then
        for _i, b in ipairs(books) do
            for _j, name in ipairs(Genres.of(b.file)) do
                local g = group(name:lower(), name)
                g.books[#g.books + 1] = b
            end
        end
    elseif kind == "collections" then
        local ok, RC = pcall(require, "readcollection")
        if ok and RC and type(RC.coll) == "table" then
            local by_file = {}
            for _i, b in ipairs(books) do by_file[b.file] = b end
            for name, items in pairs(RC.coll) do
                -- Favorites / To be read can be hidden (Settings > Library options > Collections).
                local g = not Chips.libraryCollectionHidden(RC, name) and group(name, collectionTitle(RC, name)) or nil
                for file, item in pairs(g and items or {}) do
                    local path = type(item) == "table" and item.file or file
                    local b = by_file[path]
                    -- Collections can hold books outside the home folder.
                    local attr = not b and type(path) == "string" and lfs.attributes(path)
                    if attr and attr.mode == "file" then
                        b = buildEntry({ file = path, mtime = attr.modification, size = attr.size },
                            KoboldBookInfo.get(path))
                        by_file[path] = b
                    end
                    if b then
                        g.books[#g.books + 1] = b
                        g.order[b.file] = type(item) == "table" and tonumber(item.order) or nil
                    end
                end
            end
        end
    end

    for _i, g in ipairs(groups) do
        if kind == "series" then
            table.sort(g.books, function(a, b)
                local ia, ib = a.series_index or math.huge, b.series_index or math.huge
                if ia ~= ib then return ia < ib end
                return byTitle(a, b)
            end)
        elseif kind == "collections" then
            local order = g.order
            table.sort(g.books, function(a, b)
                local oa, ob = order[a.file] or math.huge, order[b.file] or math.huge
                if oa ~= ob then return oa < ob end
                return byTitle(a, b)
            end)
        else
            table.sort(g.books, byTitle)
        end
        g.order = nil
    end
    return groups
end

-- `groups` sorted by name, A to Z or Z to A. "Unknown author" is always last.
function KoboldMyBooksData.sortGroups(groups, sort)
    table.sort(groups, function(a, b)
        if a.unknown ~= b.unknown then return not a.unknown end
        local ka, kb = a.name:lower(), b.name:lower()
        if ka == kb then return a.key < b.key end
        if sort == "name_desc" then return ka > kb end
        return ka < kb
    end)
    return groups
end

-- "64.3 MB" / "788 KB", or nil when the size is unknown.
function KoboldMyBooksData.formatSize(bytes)
    if not bytes then return nil end
    if bytes >= 1024 * 1024 then
        return string.format("%.1f MB", bytes / (1024 * 1024))
    end
    return string.format("%d KB", math.max(1, math.floor(bytes / 1024 + 0.5)))
end

return KoboldMyBooksData
