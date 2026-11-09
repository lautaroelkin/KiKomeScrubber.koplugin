-- kobold/data/metadata.lua — Kobold
-- Corrections to a book's title, authors, series, series number, language,
-- keywords and description, made from the Edit screen of the book details
-- page. No UI.
--
-- They are kept where KOReader's own Book information keeps them: in
-- custom_metadata.lua in the book's sidecar folder, under "custom_props".
-- The book file is not touched by them (only writeToBook, asked for on its
-- own, puts them into an EPUB), and every part of KOReader (and of Kobold)
-- that reads a book's metadata already lets these values win over the
-- book's own. Next to them, when the file is first made, goes a copy of the
-- book's original values ("doc_props"), as KOReader does.
--
--   Metadata.FIELDS                      the keys, in the order the screen lists them
--   Metadata.custom(file)                -> { key = value } of what is corrected now
--   Metadata.originals(file)             -> { key = value } the book's own values, if known
--   Metadata.extraOriginals(file)        -> { publisher, year, isbn } the book's own (read from the EPUB,
--                                           kept while the file does not change); {} for other formats
--   Metadata.set(file, key, value, base) value "" puts the original back;
--                                        `base` (the book's props, optional) is the
--                                        copy of the originals when the file is made
--   Metadata.setMany(file, values, base) several keys in one save ({ key = value }, "" clears one);
--                                        Metadata.BLANK as a value leaves that key EMPTY on purpose
--                                        (the book's own value does not come back: "no series")
--   Metadata.restore(file, key)          the original comes back for that key
--   Metadata.restoreAll(file)            ... for every key
--   Metadata.knownSeries()               -> { { name, count } } the series already in the library
--   Metadata.knownAuthors()              -> { { name, count } } the authors already in the library
--   Metadata.seriesBooks(name, file)     how many books the series has in the library
--   Metadata.customCover(file)           the custom cover's path, or nil
--   Metadata.knownKeywords()             -> { { name, count } } the keywords already used
--   Metadata.knownLanguages()            -> { { name, label, count } } the languages to pick from
--   Metadata.matchList(known, text)      the ones that contain `text`
--   Metadata.isEpub(file)                true when the book can be written (an EPUB)
--   Metadata.bookChanges(file)           -> changes, keys: what the corrections would write into
--                                        the EPUB (see epub_writer.lua), and which fields
--   Metadata.writeToBook(file, opts)     writes the corrections into the EPUB itself (the way
--                                        Calibre does) and clears them from the sidecar:
--                                        -> true, backup_path (nil with no backup)   |   false, "why"
--                                        opts.backup = false: no copy of the old book is kept
--   Metadata.backupPath(file)            where that copy is kept
--   Metadata.invalidate(file)            KOReader's cover browser forgets what it read
--   Metadata.announce(file)              everything on screen shows the new data
-- The writers return true when they saved.

local _ = require("kobold.i18n")
local Metadata = {}

Metadata.FIELDS = {
    "title", "authors", "series", "series_index", "language", "keywords", "description",
    "publisher", "year", "isbn", "pages",   -- the "More details" of the screen
}

local function isField(key)
    for _i, k in ipairs(Metadata.FIELDS) do
        if k == key then return true end
    end
    return false
end

local function docSettingsClass()
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings and DocSettings.findCustomMetadataFile then return DocSettings end
    return nil
end

-- The custom metadata file of a book, or nil when it has none.
local function customPath(file)
    local DocSettings = docSettingsClass()
    if not DocSettings then return nil end
    local ok, path = pcall(function() return DocSettings:findCustomMetadataFile(file) end)
    if ok and path then return path end
    return nil
end

local function copyFields(props)
    local out = {}
    if type(props) ~= "table" then return out end
    for _i, k in ipairs(Metadata.FIELDS) do
        if props[k] ~= nil then out[k] = props[k] end
    end
    return out
end

function Metadata.custom(file)
    local DocSettings = docSettingsClass()
    local path = customPath(file)
    if not (DocSettings and path) then return {} end
    local ok, custom = pcall(function()
        return DocSettings.openSettingsFile(path):readSetting("custom_props")
    end)
    if not (ok and type(custom) == "table") then return {} end
    local out = {}
    for k, v in pairs(custom) do out[k] = v end
    return out
end

-- The book's own values: the copy KOReader keeps beside the corrections, or
-- else the one in the book's sidecar.
function Metadata.originals(file)
    local DocSettings = docSettingsClass()
    if not DocSettings then return {} end
    local path = customPath(file)
    if path then
        local ok, props = pcall(function()
            return DocSettings.openSettingsFile(path):readSetting("doc_props")
        end)
        if ok and type(props) == "table" and next(props) ~= nil then return copyFields(props) end
    end
    local ok_open, ds = pcall(function() return DocSettings:open(file) end)
    if ok_open and ds then
        local props = ds:readSetting("doc_props")
        pcall(function() ds:close() end)
        if type(props) == "table" then return copyFields(props) end
    end
    return {}
end

-- The publisher, year and ISBN of the book itself. KOReader does not read them,
-- so they come from the EPUB's own OPF (see epub_writer.lua). Read once for a
-- file as it is (its size and date): a book that was rewritten is read again.
local extra_cache = {}

function Metadata.extraOriginals(file)
    local lfs = require("libs/libkoreader-lfs")
    local stamp = tostring(lfs.attributes(file, "modification")) .. ":" .. tostring(lfs.attributes(file, "size"))
    local hit = extra_cache[file]
    if hit and hit.stamp == stamp then return hit.info end
    local info = {}
    if Metadata.isEpub(file) then
        local ok, got = pcall(function() return require("kobold.data.epub_writer").readInfo(file) end)
        if ok and type(got) == "table" then info = got end
    end
    extra_cache[file] = { stamp = stamp, info = info }
    return info
end

-- Opens the custom metadata (making it, with the copy of the originals, when
-- the book has none), lets `mutate` change its custom_props, and saves. A
-- file left with no corrections is deleted.
local function save(file, mutate, base)
    local DocSettings = docSettingsClass()
    if not DocSettings then return false end
    local path = customPath(file)
    local ok = pcall(function()
        local cds
        if path then
            cds = DocSettings.openSettingsFile(path)
        else
            cds = DocSettings.openSettingsFile()
            local stash = Metadata.originals(file)
            if next(stash) == nil then stash = copyFields(base) end
            cds:saveSetting("doc_props", stash)
        end
        local custom = cds:readSetting("custom_props")
        if type(custom) ~= "table" then custom = {} end
        mutate(custom)
        if next(custom) == nil then
            if path then os.remove(path) end
        else
            cds:saveSetting("custom_props", custom)
            cds:flushCustomMetadata(file)
        end
    end)
    return ok
end

function Metadata.restore(file, key)
    if not customPath(file) then return true end   -- nothing was corrected
    return save(file, function(custom) custom[key] = nil end)
end

function Metadata.restoreAll(file)
    if not customPath(file) then return true end
    return save(file, function(custom)
        for _i, k in ipairs(Metadata.FIELDS) do custom[k] = nil end
    end)
end

-- A value for setMany: the key is saved as an empty text, so it shows as empty
-- (a book with no series) instead of falling back to what the book says.
Metadata.BLANK = {}

function Metadata.set(file, key, value, base)
    if not isField(key) then return false end
    if key == "series_index" and value ~= nil and value ~= "" then
        value = tonumber(value)
        if not value then return false end
    end
    if value == nil or value == "" then return Metadata.restore(file, key) end
    return save(file, function(custom) custom[key] = value end, base)
end

-- Several corrections in one save: { series = "Dune", series_index = "2" }.
-- A value of "" puts that key's original back.
function Metadata.setMany(file, values, base)
    local clean, any = {}, false
    for key, value in pairs(values) do
        if not isField(key) then return false end
        if value == Metadata.BLANK then
            clean[key] = Metadata.BLANK
            any = true
        else
            if key == "series_index" and value ~= nil and value ~= "" then
                value = tonumber(value)
                if not value then return false end
            end
            if value == nil then value = "" end
            clean[key] = value
            if value ~= "" then any = true end
        end
    end
    if not any and not customPath(file) then return true end   -- nothing was corrected
    return save(file, function(custom)
        for key, value in pairs(clean) do
            if value == Metadata.BLANK then custom[key] = ""
            elseif value == "" then custom[key] = nil
            else custom[key] = value end
        end
    end, base)
end

-- The series that already exist in the library, from what the cover browser
-- has read: { { name = "...", count = books }, ... }, A to Z.
function Metadata.knownSeries()
    local ok, BookInfo = pcall(require, "kobold.data.bookinfo")
    if not (ok and BookInfo and BookInfo.getMap) then return {} end
    local ok_map, map = pcall(BookInfo.getMap)
    if not (ok_map and type(map) == "table") then return {} end
    local counts = {}
    for _path, row in pairs(map) do
        local name = type(row) == "table" and row.series or nil
        if type(name) == "string" then
            name = name:match("^%s*(.-)%s*$")
            if name ~= "" then counts[name] = (counts[name] or 0) + 1 end
        end
    end
    local list = {}
    for name, count in pairs(counts) do list[#list + 1] = { name = name, count = count } end
    table.sort(list, function(a, b)
        local la, lb = a.name:lower(), b.name:lower()
        if la ~= lb then return la < lb end
        return a.name < b.name
    end)
    return list
end

-- The authors already in the library, the most used first: { { name, count } }.
function Metadata.knownAuthors()
    local ok, BookInfo = pcall(require, "kobold.data.bookinfo")
    if not (ok and BookInfo and BookInfo.getMap) then return {} end
    local ok_map, map = pcall(BookInfo.getMap)
    if not (ok_map and type(map) == "table") then return {} end
    local counts, names = {}, {}
    for _path, row in pairs(map) do
        local raw = type(row) == "table" and row.authors or nil
        if type(raw) == "string" then
            for part in (raw .. "\n"):gmatch("(.-)\n") do
                local name = part:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if name ~= "" then
                    local key = name:lower()
                    counts[key] = (counts[key] or 0) + 1
                    if not names[key] then names[key] = name end
                end
            end
        end
    end
    local list = {}
    for key, count in pairs(counts) do list[#list + 1] = { name = names[key], count = count } end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

-- How many books of the library are in the series `name`, this one (`file`)
-- included whether or not the cover browser has read its series yet.
function Metadata.seriesBooks(name, file)
    local total = 1
    local ok, BookInfo = pcall(require, "kobold.data.bookinfo")
    if not (ok and BookInfo and BookInfo.getMap) then return total end
    local ok_map, map = pcall(BookInfo.getMap)
    if not (ok_map and type(map) == "table") then return total end
    for path, row in pairs(map) do
        if path ~= file and type(row) == "table" and type(row.series) == "string"
            and row.series:match("^%s*(.-)%s*$") == name then
            total = total + 1
        end
    end
    return total
end

-- The custom cover of a book (the file's path), or nil when it has none.
function Metadata.customCover(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings and DocSettings.findCustomCoverFile) then return nil end
    local ok_find, path = pcall(function() return DocSettings:findCustomCoverFile(file) end)
    if ok_find and path then return path end
    return nil
end

-- The keywords already used by books in the library, the most used first:
-- { { name, count } }.
function Metadata.knownKeywords()
    local ok, BookInfo = pcall(require, "kobold.data.bookinfo")
    if not (ok and BookInfo and BookInfo.getMap) then return {} end
    local ok_map, map = pcall(BookInfo.getMap)
    if not (ok_map and type(map) == "table") then return {} end
    local counts, names = {}, {}
    for _path, row in pairs(map) do
        local raw = type(row) == "table" and row.keywords or nil
        if type(raw) == "string" then
            for part in (raw .. ","):gmatch("([^,;\n]*)[,;\n]") do
                local word = part:gsub("%s+", " "):match("^%s*(.-)%s*$")
                if word ~= "" and #word <= 40 then
                    local key = word:lower()
                    counts[key] = (counts[key] or 0) + 1
                    if not names[key] then names[key] = word end
                end
            end
        end
    end
    local list = {}
    for key, count in pairs(counts) do list[#list + 1] = { name = names[key], count = count } end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name:lower() < b.name:lower()
    end)
    return list
end

local LANGUAGE_NAMES = {
    en = _("English"), es = _("Spanish"), fr = _("French"), de = _("German"), it = _("Italian"),
    pt = _("Portuguese"), ru = _("Russian"), ja = _("Japanese"), zh = _("Chinese"), ko = _("Korean"),
    ar = _("Arabic"), la = _("Latin"), ca = _("Catalan"), nl = _("Dutch"), pl = _("Polish"),
    sv = _("Swedish"), tr = _("Turkish"), el = _("Greek"), he = _("Hebrew"), hi = _("Hindi"),
}
local COMMON_LANGUAGES = {
    "en", "es", "fr", "de", "it", "pt", "ru", "ja", "zh", "ko", "ar", "la", "ca", "nl", "pl", "sv",
}

-- The languages to pick from: the ones the library already has (the most used
-- first, with their count), then the usual ones it does not have yet.
-- { { name = "es", label = "es · Spanish", count } }.
function Metadata.knownLanguages()
    local counts = {}
    local ok_l, Library = pcall(require, "kobold.data.library")
    local ok_b, BookLang = pcall(require, "kobold.data.booklang")
    if ok_l and ok_b then
        local ok_s, books = pcall(Library.scan)
        if ok_s and type(books) == "table" then
            for _i, book in ipairs(books) do
                local ok_c, code = pcall(BookLang.of, book.file)
                if ok_c and type(code) == "string" and code ~= "" then
                    code = code:lower()
                    counts[code] = (counts[code] or 0) + 1
                end
            end
        end
    end
    local function entry(code, count)
        local name = LANGUAGE_NAMES[code]
        return { name = code, label = name and (code .. " · " .. name) or code, count = count }
    end
    local list, have = {}, {}
    for code, count in pairs(counts) do list[#list + 1] = entry(code, count); have[code] = true end
    table.sort(list, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    for _i, code in ipairs(COMMON_LANGUAGES) do
        if not have[code] then list[#list + 1] = entry(code, 0) end
    end
    return list
end

-- The ones of `known` that contain what was typed (any case, in the name or
-- the label); everything when nothing was typed.
function Metadata.matchList(known, query)
    query = (query or ""):match("^%s*(.-)%s*$"):lower()
    if query == "" then return known end
    local out = {}
    for _i, entry in ipairs(known) do
        if (entry.label or entry.name):lower():find(query, 1, true) then out[#out + 1] = entry end
    end
    return out
end

-- ── Writing the corrections into the book ──────────────────────────────────

function Metadata.isEpub(file)
    return type(file) == "string" and file:lower():match("%.epub$") ~= nil
end

local function filled(v)
    return v ~= nil and v ~= ""
end

local function trimmed(s)
    return (tostring(s):match("^%s*(.-)%s*$"))
end

-- What the corrections would put into the EPUB, in the shape epub_writer.lua
-- takes, and the keys of the fields that go (in the order of FIELDS). Nothing
-- (nil) when no field is corrected.
function Metadata.bookChanges(file)
    local custom = Metadata.custom(file)
    local changes, keys = {}, {}
    if filled(custom.title) then
        changes.title = tostring(custom.title)
        keys[#keys + 1] = "title"
    end
    if filled(custom.authors) then
        local list = {}
        for line in (tostring(custom.authors) .. "\n"):gmatch("(.-)\n") do
            line = trimmed(line)
            if line ~= "" then list[#list + 1] = line end
        end
        if #list > 0 then
            changes.authors = list
            keys[#keys + 1] = "authors"
        end
    end
    -- A series emptied on purpose: it is taken out of the EPUB.
    local series_blank = (custom.series == "")
    if series_blank then
        changes.remove_series = true
        keys[#keys + 1] = "series"
    end
    -- The number alone (the series left as the book has it) still needs the
    -- series' name to be written: it comes from the book's own values.
    if not series_blank and (filled(custom.series) or filled(custom.series_index)) then
        local own = Metadata.originals(file)
        local name = filled(custom.series) and custom.series or own.series
        local index = filled(custom.series_index) and custom.series_index or own.series_index
        if filled(name) and trimmed(name) ~= "" then
            changes.series = trimmed(name)
            changes.series_index = index
            if filled(custom.series) then keys[#keys + 1] = "series" end
            if filled(custom.series_index) then keys[#keys + 1] = "series_index" end
        end
    end
    if filled(custom.language) then
        changes.language = trimmed(custom.language)
        keys[#keys + 1] = "language"
    end
    if filled(custom.keywords) then
        local list, seen = {}, {}
        for part in (tostring(custom.keywords) .. ","):gmatch("([^,;\n]*)[,;\n]") do
            local word = trimmed((part:gsub("%s+", " ")))
            if word ~= "" and not seen[word:lower()] then
                seen[word:lower()] = true
                list[#list + 1] = word
            end
        end
        if #list > 0 then
            changes.subjects = list
            keys[#keys + 1] = "keywords"
        end
    end
    if filled(custom.description) then
        changes.description = tostring(custom.description)
        keys[#keys + 1] = "description"
    end
    if filled(custom.publisher) then
        changes.publisher = trimmed(custom.publisher)
        keys[#keys + 1] = "publisher"
    end
    if filled(custom.year) then
        changes.year = trimmed(custom.year)
        keys[#keys + 1] = "year"
    end
    if filled(custom.isbn) then
        changes.isbn = trimmed(custom.isbn)
        keys[#keys + 1] = "isbn"
    end
    -- A custom cover goes into the EPUB too (it replaces the book's own picture).
    local cover = Metadata.customCover(file)
    if cover then
        changes.cover_file = cover
        keys[#keys + 1] = "cover"
    end
    if #keys == 0 then return nil end
    return changes, keys
end

-- The book's own copy of its properties (in its sidecar, once it was opened)
-- would still say the old values after the book was rewritten: it is brought up
-- to date. True when nothing is left that says otherwise.
local function refreshSidecarProps(file, custom)
    local DocSettings = docSettingsClass()
    if not DocSettings then return true end
    local ok, done = pcall(function()
        local ds = DocSettings:open(file)
        local props = ds:readSetting("doc_props")
        if type(props) ~= "table" then return true end   -- nothing kept: it is read from the book
        for _i, k in ipairs(Metadata.FIELDS) do
            if filled(custom[k]) then props[k] = custom[k] end
        end
        if custom.series == "" then props.series = nil; props.series_index = nil end
        if filled(custom.title) and props.display_title ~= nil then props.display_title = custom.title end
        ds:saveSetting("doc_props", props)
        ds:flush()
        return true
    end)
    return ok and done == true
end

-- Writes the corrections into the EPUB and, once the book says them itself,
-- clears them from the sidecar (the book's old values are in the copy that
-- epub_writer keeps beside the book). If the sidecar cannot be brought up to
-- date, the corrections stay: they say the same as the book.
-- Returns true, backup_path   or   false, "why".
function Metadata.backupPath(file)
    local ok, EpubWriter = pcall(require, "kobold.data.epub_writer")
    return ok and EpubWriter.backupPath(file) or nil
end

function Metadata.writeToBook(file, opts)
    if not Metadata.isEpub(file) then return false, _("Only EPUB books can be written.") end
    local changes = Metadata.bookChanges(file)
    if not changes then return false, _("There is nothing to write.") end
    local custom = Metadata.custom(file)
    local ok_mod, EpubWriter = pcall(require, "kobold.data.epub_writer")
    if not ok_mod then return false, _("The EPUB writer could not be loaded.") end
    local ok_run, ok, result = pcall(EpubWriter.rewrite, file, changes, opts)
    if not ok_run then return false, tostring(ok) end
    if not ok then return false, result end
    if refreshSidecarProps(file, custom) then
        local path = customPath(file)
        if path then os.remove(path) end
    end
    -- the number of pages is not something an EPUB can hold: it stays as a
    -- correction of KiKome, the only thing that is left after the rest went in
    if filled(custom.pages) then
        save(file, function(c) c.pages = custom.pages end, {})
    end
    -- the book holds the cover itself now: the custom one is not needed any more
    if changes.cover_file then
        local ok_c, CoverOnline = pcall(require, "kobold.data.cover_online")
        if ok_c and CoverOnline then pcall(CoverOnline.revert, file) end
    end
    return true, result
end

-- KOReader's cover browser keeps what it read from each book; this makes it
-- read the book again (and see the corrections) the next time.
function Metadata.invalidate(file)
    pcall(function()
        local Event = require("ui/event")
        local UIManager = require("ui/uimanager")
        UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", file))
    end)
end

-- Tells every part of KOReader and of Kobold (Home, the Library, other
-- plugins) that this book's metadata changed.
function Metadata.announce(file)
    pcall(function()
        local Event = require("ui/event")
        local UIManager = require("ui/uimanager")
        UIManager:broadcastEvent(Event:new("BookMetadataChanged", { filepath = file }))
    end)
end

return Metadata
