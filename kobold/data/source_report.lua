-- kobold/data/source_report.lua — KiKome
-- A test, not a feature: asks every source about the open book and writes what
-- each one REALLY answers, so that nothing has to be guessed about the data
-- (pages, publisher, year, description...) the sources hold.
--
--   SourceReport.run(book, progress) -> text, path
--       book     = { title, author, isbn, language }
--       progress = function(text) called before each request (optional)
--       Meant to run inside a coroutine, like CoverOnline.search: it yields before
--       every request. `text` is the report; `path` is where it was saved.
--
-- The report has a summary (which source gives which data) and, for every
-- source, EVERY field of the first match with a short sample of its value, so a
-- field nobody expected shows up too. Google Books is asked even when it gave a
-- 429 a moment ago: the test says what it answers now.

local DataStorage = require("datastorage")
local logger      = require("logger")

local SourceReport = {}

local FIELDS = { "title", "authors", "year", "publisher", "isbn", "pages", "description", "categories", "language", "series", "cover" }

local function present(v)
    if v == nil or v == "" then return false end
    if type(v) == "userdata" then return false end   -- a JSON null
    if type(v) == "table" and next(v) == nil then return false end
    return true
end

local function flat(s)
    return (tostring(s):gsub("%s+", " "))
end

-- A value in one short piece.
local function describe(v, depth)
    depth = depth or 0
    local t = type(v)
    if t == "userdata" then return "null" end
    if t == "string" then
        local s = flat(v)
        if #s > 70 then return string.format('"%s…" (%d characters)', s:sub(1, 60), #v) end
        return '"' .. s .. '"'
    end
    if t ~= "table" then return tostring(v) end
    if #v > 0 then
        local first = (depth < 1) and (" first: " .. describe(v[1], depth + 1)) or ""
        return string.format("[%d items]%s", #v, first)
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    if #keys == 0 then return "{}" end
    if #keys > 10 then
        return "{" .. table.concat(keys, ", ", 1, 10) .. ", … " .. (#keys - 10) .. " more}"
    end
    return "{" .. table.concat(keys, ", ") .. "}"
end

local function dump(out, record)
    local keys = {}
    for k in pairs(record) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    for _i, k in ipairs(keys) do out("  " .. k .. ": " .. describe(record[k])) end
end

-- The plain values at the top of an answer ("numFound=0, start=0"), so that a
-- "no match" says what the source really answered.
local function scalars(data)
    local keys = {}
    for k, v in pairs(data) do
        if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then keys[#keys + 1] = tostring(k) end
    end
    table.sort(keys)
    local parts = {}
    for _i, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. flat(tostring(data[k])):sub(1, 40) end
    return table.concat(parts, ", ")
end

local function first(v) if type(v) == "table" then return v[1] end return v end

local function joined(v, n)
    if type(v) ~= "table" then return v end
    local t = {}
    for i = 1, math.min(#v, n or 3) do
        local item = v[i]
        if type(item) == "table" then item = item.name or item.id or item.value end
        if item ~= nil then t[#t + 1] = tostring(item) end
    end
    if #t == 0 then return nil end
    return table.concat(t, ", ")
end

local function text_of(v)   -- Open Library's description is a string or { value = "..." }
    if type(v) == "table" then return v.value end
    return v
end

function SourceReport.run(book, progress)
    local CoverOnline = require("kobold.data.cover_online")
    local getJson, enc = CoverOnline.getJson, CoverOnline.urlEncode
    local body, sources = {}, {}   -- lines of the sections; { name, norm | nil, err | nil }
    local function out(s) body[#body + 1] = s end

    local isbn = book.isbn
    local q = {}
    if book.title and book.title ~= "" then q[#q + 1] = book.title end
    if book.author and book.author ~= "" then q[#q + 1] = book.author end
    local query = table.concat(q, " ")
    local country = (CoverOnline.appleCountries and CoverOnline.appleCountries(book) or { "us" })[1] or "us"

    -- One request of one source: shows its url, its failure or its first match.
    -- `pick(data)` returns the record to dump, how many matches there were and
    -- the normalized fields.
    local function ask(name, url, pick, note)
        if progress then progress(name) end
        out("")
        out("== " .. name .. " ==")
        out("  " .. url)
        local data, why = getJson(url)
        if not data then
            out("  FAILED: " .. tostring(why))
            if tostring(why):find("429", 1, true) then
                out("  (429: the source's quota ran out; it answers nothing now)")
            end
            sources[#sources + 1] = { name = name, err = why }
            return nil
        end
        local ok, record, count, norm, extra = pcall(pick, data)
        if not ok then
            out("  could not read the answer: " .. tostring(record))
            sources[#sources + 1] = { name = name, err = "unexpected answer" }
            return nil
        end
        if not record then
            out("  no match. What it answered: " .. describe(data))
            local plain = scalars(data)
            if plain ~= "" then out("  " .. plain) end
            sources[#sources + 1] = { name = name, norm = {} , empty = true }
            return nil
        end
        out(string.format("  matches: %s. Fields of the first one:", tostring(count or 1)))
        dump(out, record)
        if extra then
            for _i, line in ipairs(extra) do out("  " .. line) end
        end
        if note then out("  " .. note) end
        sources[#sources + 1] = { name = name, norm = norm or {} }
        return record
    end

    -- Open Library: the search
    local function ol_pick(data)
        local d = data.docs and data.docs[1]
        if not d then return nil end
        return d, data.numFound or #data.docs, {
            title = d.title, authors = joined(d.author_name), year = d.first_publish_year,
            publisher = first(d.publisher), isbn = first(d.isbn), pages = d.number_of_pages_median,
            description = nil, categories = joined(d.subject), language = joined(d.language),
            series = nil, cover = d.cover_i,
        }
    end
    local ol_url
    if isbn then
        ol_url = "https://openlibrary.org/search.json?isbn=" .. enc(isbn) .. "&limit=3&fields=*"
    elseif query ~= "" then
        ol_url = "https://openlibrary.org/search.json?q=" .. enc(query) .. "&limit=3&fields=*"
    end
    local ol_doc
    if ol_url then ol_doc = ask("Open Library (search)", ol_url, ol_pick) end
    -- an ISBN it does not know: does it know the book at all? (the title before
    -- the first colon and the author, which is how it is usually catalogued)
    if isbn and not ol_doc and sources[#sources] and sources[#sources].empty then
        local short = (book.title or ""):match("^%s*([^:]+)")
        local words = {}
        if short and short ~= "" then words[#words + 1] = short end
        if book.author and book.author ~= "" then words[#words + 1] = book.author end
        if #words > 0 then
            ol_doc = ask("Open Library (search by title)",
                "https://openlibrary.org/search.json?q=" .. enc(table.concat(words, " ")) .. "&limit=3&fields=*", ol_pick)
        end
    end

    -- Open Library: the edition of this ISBN (the pages of THAT edition)
    if isbn then
        ask("Open Library (ISBN edition)",
            "https://openlibrary.org/api/books?bibkeys=ISBN:" .. enc(isbn) .. "&format=json&jscmd=data",
            function(data)
                local r = data["ISBN:" .. isbn]
                if not r then return nil end
                local ids = type(r.identifiers) == "table" and r.identifiers or {}
                return r, 1, {
                    title = r.title, authors = joined(r.authors), year = r.publish_date,
                    publisher = joined(r.publishers, 2), isbn = first(ids.isbn_13) or first(ids.isbn_10),
                    pages = r.number_of_pages, categories = joined(r.subjects), cover = r.cover,
                }
            end)
    end

    -- Open Library: the work (where the description is)
    local work_key = ol_doc and ol_doc.key
    if type(work_key) == "string" and work_key:match("^/works/") then
        ask("Open Library (work)", "https://openlibrary.org" .. work_key .. ".json", function(data)
            return data, 1, {
                title = data.title, year = data.first_publish_date, description = text_of(data.description),
                authors = (type(data.authors) == "table" and #data.authors > 0) and (#data.authors .. " author reference(s), no names") or nil,
                categories = joined(data.subjects), series = nil, cover = first(data.covers),
            }
        end)

        -- Open Library: the editions of the work (publisher, pages and ISBN belong to an
        -- edition, not to the work: here they are listed side by side)
        ask("Open Library (editions of the work)", "https://openlibrary.org" .. work_key .. "/editions.json?limit=10",
            function(data)
                local entries = data.entries
                if type(entries) ~= "table" or not entries[1] then return nil end
                local lines = { "Editions (publisher | date | pages | ISBN | language):" }
                local any_pages
                for i = 1, math.min(#entries, 10) do
                    local e = entries[i]
                    local lang = type(e.languages) == "table" and e.languages[1] and e.languages[1].key or nil
                    lines[#lines + 1] = string.format("%d. %s | %s | %s | %s | %s", i,
                        tostring(joined(e.publishers, 1) or "-"), tostring(e.publish_date or "-"),
                        tostring(e.number_of_pages or "-"), tostring(first(e.isbn_13) or first(e.isbn_10) or "-"),
                        tostring(lang or "-"))
                    if not any_pages and e.number_of_pages then any_pages = e.number_of_pages end
                end
                local e = entries[1]
                return e, data.size or #entries, {
                    title = e.title, publisher = joined(e.publishers, 1), year = e.publish_date,
                    isbn = first(e.isbn_13) or first(e.isbn_10), pages = any_pages,
                    description = text_of(e.description), language = type(e.languages) == "table" and e.languages[1] and e.languages[1].key or nil,
                    series = joined(e.series), cover = first(e.covers),
                }, lines
            end)
    end

    -- Apple Books
    local apple_term = isbn or (query ~= "" and query) or nil
    if apple_term then
        ask("Apple Books (" .. country .. " store)",
            "https://itunes.apple.com/search?media=ebook&country=" .. country .. "&term=" .. enc(apple_term) .. "&limit=3",
            function(data)
                local r = data.results and data.results[1]
                if not r then return nil end
                return r, data.resultCount or #data.results, {
                    title = r.trackName, authors = r.artistName,
                    year = type(r.releaseDate) == "string" and r.releaseDate:sub(1, 4) or nil,
                    publisher = r.publisher, isbn = r.isbn, pages = r.pageCount,
                    description = r.description, categories = joined(r.genres),
                    language = joined(r.languageCodesISO2A), series = r.seriesName, cover = r.artworkUrl100,
                }
            end)
    end

    -- Google Books (asked even if it said 429 before: this says what it answers now)
    local g_q
    if isbn then
        g_q = "isbn:" .. isbn
    elseif book.title and book.title ~= "" then
        g_q = "intitle:" .. book.title .. ((book.author and book.author ~= "") and (" inauthor:" .. book.author) or "")
    end
    if g_q then
        ask("Google Books", "https://www.googleapis.com/books/v1/volumes?q=" .. enc(g_q) .. "&maxResults=3",
            function(data)
                local item = data.items and data.items[1]
                if not item then return nil end
                local v = item.volumeInfo or {}
                local ids = {}
                for _i, id in ipairs(type(v.industryIdentifiers) == "table" and v.industryIdentifiers or {}) do
                    ids[#ids + 1] = id.identifier
                end
                return v, data.totalItems or #data.items, {
                    title = v.title, authors = joined(v.authors), year = type(v.publishedDate) == "string" and v.publishedDate:sub(1, 4) or nil,
                    publisher = v.publisher, isbn = ids[1], pages = v.pageCount, description = v.description,
                    categories = joined(v.categories), language = v.language, series = v.seriesInfo, cover = v.imageLinks,
                }
            end)
    end

    -- Amazon gives pictures only
    out("")
    out("== Amazon ==")
    out("  covers only (no data to read)")

    -- The summary goes first
    local head = {
        "WHAT THE SOURCES GIVE",
        "Book: " .. tostring(book.title or "-") .. " | " .. tostring(book.author or "-")
            .. " | ISBN " .. tostring(isbn or "none") .. " | language " .. tostring(book.language or "-"),
        "",
        "SUMMARY (data found in the first match)",
    }
    local pages = {}
    for _i, src in ipairs(sources) do
        if src.err then
            head[#head + 1] = "- " .. src.name .. ": FAILED (" .. tostring(src.err) .. ")"
        elseif src.empty then
            head[#head + 1] = "- " .. src.name .. ": no match"
        else
            local has, lacks = {}, {}
            for _j, f in ipairs(FIELDS) do
                if present(src.norm[f]) then has[#has + 1] = f else lacks[#lacks + 1] = f end
            end
            head[#head + 1] = "- " .. src.name .. ": " .. (#has > 0 and table.concat(has, ", ") or "nothing")
                .. "  |  missing: " .. (#lacks > 0 and table.concat(lacks, ", ") or "none")
            if present(src.norm.pages) then pages[#pages + 1] = src.name .. " = " .. tostring(src.norm.pages) end
        end
    end
    head[#head + 1] = ""
    head[#head + 1] = "PAGES: " .. (#pages > 0 and table.concat(pages, "; ") or "no source gave a page count")
    head[#head + 1] = ""
    head[#head + 1] = "DETAIL (every field the first match carries)"

    local lines = {}
    for _i, l in ipairs(head) do lines[#lines + 1] = l end
    for _i, l in ipairs(body) do lines[#lines + 1] = l end
    local text = table.concat(lines, "\n")

    local path = DataStorage:getDataDir() .. "/kikome_source_report.txt"
    local f = io.open(path, "wb")
    if f then
        f:write(text, "\n")
        f:close()
    else
        path = nil
    end
    logger.info("KiKome: source report written to", tostring(path))
    return text, path
end

return SourceReport
