-- kobold/data/online_meta.lua — KiKome
-- What the online sources say about a book, field by field, so that the
-- metadata editor can offer it as a list to pick from ("Search online", the
-- last row under a field in Edit > Metadata).
--
--   OnlineMeta.collect(book, progress) -> data
--       book     = { file, title, author, isbn, language }
--       progress = function(source_name) called before each request (optional)
--       Meant to run inside a coroutine, like CoverOnline.search and
--       CoverOnline.search: CoverOnline.getJson yields before every request.
--       `data` = { fields = { [key] = { item... } }, failed = { { name, why } }, asked = n }
--       where an item is { value = "text", sources = { "Open Library", ... }, note = "small line" | nil }.
--
--   OnlineMeta.values(data, key) -> the items of one field, best first
--   OnlineMeta.cached(book) / OnlineMeta.store(book, data) / OnlineMeta.forget(book)
--       The answer is kept in memory for each book (same title, author and ISBN),
--       so that going from one field to the next does not ask again.
--
-- The keys are the metadata fields of the editor: title, authors, series,
-- language, keywords, description, publisher, year, isbn, pages. Nothing here
-- writes anything: it only gathers values.

local _ = require("kobold.i18n")

local OnlineMeta = {}

local OL, APPLE, GOOGLE = "Open Library", "Apple Books", "Google Books"

-- How many values of each field are kept (the rest is noise).
local LIMITS = {
    title = 8, authors = 12, series = 6, language = 6, keywords = 40,
    description = 6, publisher = 15, year = 12, isbn = 12, pages = 12,
}

-- ── The cache ──────────────────────────────────────────────────────────────
local KEEP = 6                 -- books remembered
local cache, order = {}, {}

local function signature(book)
    return table.concat({
        tostring(book.file or ""), tostring(book.title or ""),
        tostring(book.author or ""), tostring(book.isbn or ""),
    }, "\0")
end

function OnlineMeta.cached(book)
    return cache[signature(book)]
end

function OnlineMeta.store(book, data)
    local sig = signature(book)
    if not cache[sig] then
        order[#order + 1] = sig
        while #order > KEEP do
            cache[table.remove(order, 1)] = nil
        end
    end
    cache[sig] = data
end

function OnlineMeta.forget(book)
    local sig = signature(book)
    if cache[sig] == nil then return end
    cache[sig] = nil
    for i, s in ipairs(order) do
        if s == sig then
            table.remove(order, i)
            break
        end
    end
end

-- ── Small helpers ──────────────────────────────────────────────────────────
local function trim(s) return (s:match("^%s*(.-)%s*$")) end

local function present(v)
    if v == nil or v == "" then return false end
    if type(v) == "userdata" then return false end   -- a JSON null
    return true
end

local function first(v)
    if type(v) == "table" then return v[1] end
    return v
end

-- The text of a list item that may be a name, an id or a { name = ... }.
local function nameOf(item)
    if type(item) == "table" then item = item.name or item.value or item.id end
    if item == nil or type(item) == "userdata" then return nil end
    return tostring(item)
end

local ENTITIES = { amp = "&", quot = '"', apos = "'", lt = "<", gt = ">", nbsp = " " }

-- HTML (Apple and Google give descriptions with tags) as plain text.
local function stripHtml(s)
    s = tostring(s)
    if not s:find("[<&]") then return trim(s) end
    s = s:gsub("<%s*[bB][rR]%s*/?>", "\n")
    s = s:gsub("</%s*[pP]%s*>", "\n\n")
    s = s:gsub("</%s*[dD][iI][vV]%s*>", "\n")
    s = s:gsub("</%s*[lL][iI]%s*>", "\n")
    s = s:gsub("<[^>]*>", "")
    s = s:gsub("&#(%d+);", function(n)
        n = tonumber(n)
        if n and n < 128 then return string.char(n) end
        if n == 8217 or n == 8216 then return "'" end
        if n == 8220 or n == 8221 then return '"' end
        return " "
    end)
    s = s:gsub("&(%a+);", function(e) return ENTITIES[e:lower()] or " " end)
    s = s:gsub("[ \t]+\n", "\n"):gsub("\n\n\n+", "\n\n"):gsub("[ \t]+", " ")
    return trim(s)
end

-- A year from "2011", "Nov 2011", "2011-11-01T00:00:00Z"...
local function yearOf(v)
    if v == nil or type(v) == "userdata" then return nil end
    if type(v) == "number" then v = tostring(math.floor(v)) end
    return tostring(v):match("%f[%d](%d%d%d%d)%f[%D]")
end

-- Language codes: the editor keeps the two-letter one ("en").
local LANG3 = {
    eng = "en", spa = "es", fre = "fr", fra = "fr", ger = "de", deu = "de",
    ita = "it", por = "pt", cat = "ca", rus = "ru", jpn = "ja", chi = "zh",
    zho = "zh", dut = "nl", nld = "nl", pol = "pl", swe = "sv", nor = "no",
    dan = "da", fin = "fi", lat = "la", gre = "el", ell = "el", tur = "tr",
    ara = "ar", heb = "he", hin = "hi", kor = "ko", cze = "cs", ces = "cs",
    hun = "hu", ukr = "uk", rum = "ro", ron = "ro", glg = "gl", eus = "eu",
    baq = "eu", bul = "bg", hrv = "hr", srp = "sr", slo = "sk", slk = "sk",
}

local function lang2(code)
    if not present(code) then return nil end
    code = tostring(code):lower():gsub("^/languages/", "")
    if #code == 2 then return code end
    return LANG3[code]
end

local function isIsbn(s)
    return s:match("^97[89]%d%d%d%d%d%d%d%d%d%d$") ~= nil or s:match("^%d%d%d%d%d%d%d%d%d[%dX]$") ~= nil
end

-- ── The bag where values pile up ───────────────────────────────────────────
local function newBag()
    return { fields = {}, seen = {}, failed = {}, asked = 0, answered = 0 }
end

-- The same value written a little differently ("George R.R. Martin" and
-- "George R. R. Martin") counts once.
local function sameKey(key, value)
    if key == "description" then
        return (value:lower():gsub("[%s%p]", ""):sub(1, 120))
    end
    return (value:lower():gsub("[%s%p]", ""))
end

-- Adds one value of a field, found by `source`. `note` is a small line about
-- where in the source it came from (the edition's publisher and year).
local function add(bag, key, value, source, note)
    if not present(value) then return end
    value = trim(tostring(value))
    if key ~= "description" then value = trim((value:gsub("%s+", " "))) end
    if value == "" then return end
    if key == "language" then value = lang2(value); if not value then return end end
    if key == "year" then value = yearOf(value); if not value then return end end
    if key == "isbn" then
        value = value:gsub("[%s%-]", ""):upper()
        if not isIsbn(value) then return end
    end
    if key == "pages" then
        local n = tonumber(value)
        if not (n and n >= 1 and n <= 99999) then return end
        value = tostring(math.floor(n))
    end
    local seen = bag.seen[key]
    if not seen then
        seen = {}
        bag.seen[key] = seen
        bag.fields[key] = {}
    end
    local k = sameKey(key, value)
    if k == "" then return end
    local item = seen[k]
    if not item then
        item = { value = value, sources = {}, note = nil, n = #bag.fields[key] + 1 }
        seen[k] = item
        table.insert(bag.fields[key], item)
    end
    local has = false
    for _i, s in ipairs(item.sources) do
        if s == source then has = true break end
    end
    if not has then item.sources[#item.sources + 1] = source end
    if note and note ~= "" and not item.note then item.note = note end
end

local function addAll(bag, key, list, source, max)
    if type(list) ~= "table" then return end
    for i = 1, math.min(#list, max or 10) do
        add(bag, key, nameOf(list[i]), source)
    end
end

-- ── Asking the sources ─────────────────────────────────────────────────────
function OnlineMeta.collect(book, progress)
    local CoverOnline = require("kobold.data.cover_online")
    local getJson, enc = CoverOnline.getJson, CoverOnline.urlEncode
    local bag = newBag()
    local late = {}   -- what is added after everything else (the noisiest lists)

    local isbn = book.isbn
    local q = {}
    if book.title and book.title ~= "" then q[#q + 1] = book.title end
    if book.author and book.author ~= "" then q[#q + 1] = book.author end
    local query = table.concat(q, " ")
    local country = (CoverOnline.appleCountries and CoverOnline.appleCountries(book) or { "us" })[1] or "us"
    local book_lang = lang2(book.language)

    -- One request: its answer, or nil (the failure is noted).
    local function ask(name, url)
        if progress then progress(name) end
        bag.asked = bag.asked + 1
        local data, why = getJson(url)   -- yields before the request (see above)
        if not data then
            bag.failed[#bag.failed + 1] = { name = name, why = tostring(why) }
            return nil
        end
        bag.answered = bag.answered + 1
        return data
    end

    -- Open Library: the search, with the fields that matter only (the answer
    -- with every field is huge).
    local OL_FIELDS = "key,title,author_name,first_publish_year,publisher,isbn,number_of_pages_median,subject,cover_i"
    local function olSearch(term_query, by_isbn)
        local url = "https://openlibrary.org/search.json?"
            .. (by_isbn and ("isbn=" .. enc(by_isbn)) or ("q=" .. enc(term_query)))
            .. "&limit=3&fields=" .. OL_FIELDS
        local data = ask(OL, url)
        return data and data.docs and data.docs[1] or nil
    end

    local doc
    if isbn then
        doc = olSearch(nil, isbn)
    elseif query ~= "" then
        doc = olSearch(query)
    end
    if isbn and not doc then
        -- an ISBN it does not know: the title before the first colon and the
        -- author, which is how it is usually catalogued
        local short = (book.title or ""):match("^%s*([^:]+)")
        local words = {}
        if short and short ~= "" then words[#words + 1] = short end
        if book.author and book.author ~= "" then words[#words + 1] = book.author end
        if #words > 0 then doc = olSearch(table.concat(words, " ")) end
    end
    if doc then
        add(bag, "title", doc.title, OL)
        addAll(bag, "authors", doc.author_name, OL, 6)
        add(bag, "year", doc.first_publish_year, OL, _("first published"))
        add(bag, "pages", doc.number_of_pages_median, OL, _("median of its editions"))
        late[#late + 1] = function()
            addAll(bag, "publisher", doc.publisher, OL, 8)
            local n = 0
            for _i, code in ipairs(type(doc.isbn) == "table" and doc.isbn or {}) do
                if type(code) == "string" and code:match("^97[89]%d+$") and isIsbn(code) then
                    add(bag, "isbn", code, OL)
                    n = n + 1
                    if n >= 5 then break end
                end
            end
        end
        addAll(bag, "keywords", doc.subject, OL, 25)
    end

    -- Open Library: the edition of this ISBN (the data of THAT edition)
    if isbn then
        local data = ask(OL, "https://openlibrary.org/api/books?bibkeys=ISBN:" .. enc(isbn) .. "&format=json&jscmd=data")
        local r = data and data["ISBN:" .. isbn]
        if type(r) == "table" then
            local pub = nameOf(first(r.publishers))
            local note = pub and (pub .. (yearOf(r.publish_date) and (", " .. yearOf(r.publish_date)) or "")) or nil
            add(bag, "title", r.title, OL)
            addAll(bag, "authors", r.authors, OL, 6)
            addAll(bag, "publisher", r.publishers, OL, 3)
            add(bag, "year", r.publish_date, OL, pub)
            add(bag, "pages", r.number_of_pages, OL, note)
            addAll(bag, "keywords", r.subjects, OL, 15)
            local ids = type(r.identifiers) == "table" and r.identifiers or {}
            add(bag, "isbn", first(ids.isbn_13) or first(ids.isbn_10), OL, note)
        end
    end

    -- Open Library: the work (the description is here) and its editions
    local work_key = doc and doc.key
    if type(work_key) == "string" and work_key:match("^/works/") then
        local w = ask(OL, "https://openlibrary.org" .. work_key .. ".json")
        if w then
            local d = w.description
            if type(d) == "table" then d = d.value end
            if present(d) then add(bag, "description", stripHtml(d), OL) end
            addAll(bag, "keywords", w.subjects, OL, 15)
        end

        local e = ask(OL, "https://openlibrary.org" .. work_key .. "/editions.json?limit=10")
        local entries = e and e.entries
        if type(entries) == "table" then
            -- the editions in the language of the book come first; if none is
            -- known to be, all of them count
            local mine, rest = {}, {}
            for _i, ed in ipairs(entries) do
                local lang = type(ed.languages) == "table" and ed.languages[1] and lang2(ed.languages[1].key) or nil
                add(bag, "language", lang, OL)
                if book_lang and lang and lang ~= book_lang then
                    rest[#rest + 1] = ed
                else
                    mine[#mine + 1] = ed
                end
            end
            if #mine == 0 then mine = rest end
            for _i, ed in ipairs(mine) do
                local pub = nameOf(first(ed.publishers))
                local year = yearOf(ed.publish_date)
                local note = pub and (pub .. (year and (", " .. year) or "")) or year
                add(bag, "publisher", pub, OL)
                add(bag, "year", year, OL, pub)
                add(bag, "pages", ed.number_of_pages, OL, note)
                add(bag, "isbn", first(ed.isbn_13) or first(ed.isbn_10), OL, note)
                if type(ed.series) == "table" then add(bag, "series", first(ed.series), OL) end
                local d = ed.description
                if type(d) == "table" then d = d.value end
                if present(d) then add(bag, "description", stripHtml(d), OL) end
            end
        end
    end

    -- Apple Books
    local apple_term = isbn or (query ~= "" and query) or nil
    if apple_term then
        local data = ask(APPLE, "https://itunes.apple.com/search?media=ebook&country=" .. country
            .. "&term=" .. enc(apple_term) .. "&limit=3")
        local r = data and data.results and data.results[1]
        if type(r) == "table" then
            add(bag, "title", r.trackName, APPLE)
            add(bag, "authors", r.artistName, APPLE)
            add(bag, "year", r.releaseDate, APPLE)
            add(bag, "publisher", r.publisher, APPLE)
            add(bag, "isbn", r.isbn, APPLE)
            add(bag, "pages", r.pageCount, APPLE)
            if present(r.description) then add(bag, "description", stripHtml(r.description), APPLE) end
            if type(r.genres) == "table" then
                for _i, g in ipairs(r.genres) do
                    if tostring(g) ~= "Books" then add(bag, "keywords", g, APPLE) end
                end
            end
            add(bag, "language", first(r.languageCodesISO2A), APPLE)
            add(bag, "series", r.seriesName, APPLE)
        end
    end

    -- Google Books
    local g_q
    if isbn then
        g_q = "isbn:" .. isbn
    elseif book.title and book.title ~= "" then
        g_q = "intitle:" .. book.title .. ((book.author and book.author ~= "") and (" inauthor:" .. book.author) or "")
    end
    if g_q then
        local data = ask(GOOGLE, "https://www.googleapis.com/books/v1/volumes?q=" .. enc(g_q) .. "&maxResults=3")
        local item = data and data.items and data.items[1]
        local v = type(item) == "table" and item.volumeInfo or nil
        if type(v) == "table" then
            add(bag, "title", v.title, GOOGLE)
            addAll(bag, "authors", v.authors, GOOGLE, 6)
            add(bag, "year", v.publishedDate, GOOGLE)
            add(bag, "publisher", v.publisher, GOOGLE)
            for _i, id in ipairs(type(v.industryIdentifiers) == "table" and v.industryIdentifiers or {}) do
                if type(id) == "table" then add(bag, "isbn", id.identifier, GOOGLE) end
            end
            add(bag, "pages", v.pageCount, GOOGLE)
            if present(v.description) then add(bag, "description", stripHtml(v.description), GOOGLE) end
            addAll(bag, "keywords", v.categories, GOOGLE, 6)
            add(bag, "language", v.language, GOOGLE)
        end
    end

    for _i, fn in ipairs(late) do fn() end

    local data = { fields = {}, failed = bag.failed, asked = bag.asked, answered = bag.answered }
    for key, list in pairs(bag.fields) do
        -- the most sources first; with the same number, the order it was found
        table.sort(list, function(a, b)
            if #a.sources ~= #b.sources then return #a.sources > #b.sources end
            if key == "isbn" and #a.value ~= #b.value then return #a.value > #b.value end   -- 13 before 10
            return a.n < b.n
        end)
        local limit = LIMITS[key] or 10
        for i = #list, limit + 1, -1 do list[i] = nil end
        data.fields[key] = list
    end
    return data
end

-- The items of one field, best first (an empty list when there are none).
function OnlineMeta.values(data, key)
    return (data and data.fields and data.fields[key]) or {}
end

-- "Open Library · Apple Books": the line under a value.
function OnlineMeta.sourcesLine(item)
    local line = table.concat(item.sources, "  ·  ")
    if item.note and item.note ~= "" then line = line .. "  ·  " .. item.note end
    return line
end

-- "Open Library (HTTP 429), Google Books (timeout)": what failed.
function OnlineMeta.failedLine(data)
    local parts = {}
    for _i, f in ipairs(data and data.failed or {}) do
        parts[#parts + 1] = string.format("%s (%s)", f.name, f.why)
    end
    return table.concat(parts, ", ")
end

return OnlineMeta
