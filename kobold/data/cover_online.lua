-- kobold/data/cover_online.lua — KiKome
-- Finds covers of a book on the internet, downloads them so they can be
-- looked at and picked, and saves the chosen one as the book's custom cover
-- (the same one KOReader's "Set custom cover" makes: cover.<ext> in the
-- book's sidecar folder). No UI. The way the sources are asked is the one of
-- the Cover picker of the bookshelf plugin.
--
--   CoverOnline.isbnFrom(text)            an ISBN found in a book's identifiers, or nil
--   CoverOnline.search(book, progress)    -> { candidate, ... }, best resolution first
--       Meant to run inside a coroutine: it yields before every request, so the
--       screen can keep answering (the caller resumes it from UIManager).
--       CoverOnline.report afterwards lists what failed: { { source, reason }, ... }
--       book     = { filepath, title, author, isbn, language, wide }
--                  (title and author are optional, one of title / isbn is needed;
--                  language = the book's language code, it picks the Apple store;
--                  wide = true looks in the stores of several countries, for a
--                  search typed by hand)
--       progress = function(text) called before each source (optional)
--       candidate = { path, width, height, size, hash, label, url }
--   CoverOnline.inspect(path)             -> candidate of a picture on the device, or nil, "why"
--   CoverOnline.apply(file, image_path)   -> true   |   false, "why"
--   CoverOnline.revert(file)              the book's own cover comes back
--   CoverOnline.cleanup()                 deletes what a search downloaded
--
-- Every source is best effort: one that fails (no network, no match, a
-- rate limit) is skipped and never stops the others.

local DataStorage = require("datastorage")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local _           = require("kobold.i18n")

local CoverOnline = {}

local MAX_PER_SOURCE = 4
local MAX_PER_STORE  = 3   -- Apple: pictures taken from each country's store

-- Google Books answers 429 when its shared quota is gone. Asking again only
-- costs the wait, so after a 429 it is left alone for a while.
local GOOGLE_PAUSE = 600
local google_blocked_until = 0

local function clock()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end
local MAX_JSON  = 2 * 1024 * 1024
local MAX_IMAGE = 8 * 1024 * 1024
local MAX_TOTAL = 18

-- ── Where the downloads go ──────────────────────────────────────────────────

local function ensureDir(dir)
    if lfs.attributes(dir, "mode") == "directory" then return true end
    local parent = dir:match("^(.*)/[^/]+$")
    if parent and parent ~= "" then ensureDir(parent) end
    pcall(lfs.mkdir, dir)
    return lfs.attributes(dir, "mode") == "directory"
end

local function cacheDir()
    return DataStorage:getDataDir() .. "/cache/kikome_covers"
end

-- Deletes what the last search downloaded.
function CoverOnline.cleanup()
    local dir = cacheDir()
    if lfs.attributes(dir, "mode") ~= "directory" then return end
    local ok, iter, dobj = pcall(lfs.dir, dir)
    if ok then
        for name in iter, dobj do
            if name ~= "." and name ~= ".." then pcall(os.remove, dir .. "/" .. name) end
        end
    end
    pcall(lfs.rmdir, dir)
end

-- ── The network ─────────────────────────────────────────────────────────────

-- Inside a coroutine (see search) this gives the screen back for a moment.
local function pause(text)
    local co, is_main = coroutine.running()
    if co and not is_main then coroutine.yield(text) end
end

-- What went wrong with a source, for the caller to show.
CoverOnline.report = {}
local function note(source, reason)
    for _i, r in ipairs(CoverOnline.report) do
        if r.source == source then return end
    end
    CoverOnline.report[#CoverOnline.report + 1] = { source = source, reason = reason }
    logger.warn("KiKome: cover source", source, "failed:", reason)
end

-- One GET. `sink` is an ltn12 sink. Returns the HTTP code, or nil and why.
-- The waits are short on purpose: the screen does not answer while a request
-- runs, so no request may keep it for long.
local function request(url, sink, accept, total)
    local ok_req, http, socket, socketutil = pcall(function()
        return require("socket.http"), require("socket"), require("socketutil")
    end)
    if not ok_req then return nil, "no socket library" end
    local ok, code, err = pcall(function()
        socketutil:set_timeout(4, total or 8)
        local c, e = socket.skip(1, http.request{
            url = url, method = "GET",
            headers = { ["User-Agent"] = "KOReader-KiKome", ["Accept"] = accept or "*/*" },
            sink = sink, redirect = true,
        })
        socketutil:reset_timeout()
        return c, e
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok then return nil, tostring(code) end
    if type(code) ~= "number" then return nil, tostring(code or err or "no answer") end
    return code
end

-- JSON of a URL, or nil and why.
local function getJson(url)
    pause()
    local chunks, total = {}, 0
    local function sink(chunk)
        if chunk then
            total = total + #chunk
            if total > MAX_JSON then return nil, "too large" end
            chunks[#chunks + 1] = chunk
        end
        return 1
    end
    local code, why = request(url, sink, "application/json", 8)
    if code ~= 200 then return nil, code and ("HTTP " .. code) or why end
    local ok_j, json = pcall(require, "rapidjson")
    if not (ok_j and json and json.decode) then
        ok_j, json = pcall(require, "json")
        if not (ok_j and json and json.decode) then return nil, "no JSON library" end
    end
    local ok_d, data = pcall(json.decode, table.concat(chunks))
    if ok_d and type(data) == "table" then return data end
    return nil, "the answer is not JSON"
end

-- Downloads `url` into `dest` (through a temporary name). True when done,
-- else false and why.
local function download(url, dest)
    pause()
    local tmp = dest .. ".tmp"
    local file = io.open(tmp, "wb")
    if not file then return false, "cannot write in the cache folder" end
    local total = 0
    local function sink(chunk)
        if chunk then
            total = total + #chunk
            if total > MAX_IMAGE then return nil, "too large" end
            if not file:write(chunk) then return nil, "write failed" end
        end
        return 1
    end
    local code, why = request(url, sink, "image/*", 12)
    pcall(function() file:close() end)
    if code ~= 200 then
        pcall(os.remove, tmp)
        return false, code and ("HTTP " .. code) or why
    end
    pcall(os.remove, dest)
    if not os.rename(tmp, dest) then
        pcall(os.remove, tmp)
        return false, "cannot move the picture"
    end
    return true
end

local function enc(s)
    return (tostring(s):gsub("[^%w]", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

-- ── Looking at a downloaded image ───────────────────────────────────────────

local function u16(s, o) return s:byte(o) * 256 + s:byte(o + 1) end

-- "jpg" or "png", with the pixel size, read from the file's header without
-- decoding it. nil for anything else (a web page, a webp...).
local function imageInfo(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local kind, w, h
    local sig = f:read(8)
    if sig and #sig >= 4 and sig:sub(1, 3) == "\255\216\255" then
        kind = "jpg"
        f:seek("set", 2)
        while true do
            local m = f:read(2)
            if not m or #m < 2 or m:byte(1) ~= 0xFF then break end
            local marker = m:byte(2)
            local lenb = f:read(2)
            if not lenb or #lenb < 2 then break end
            local len = u16(lenb, 1)
            if marker >= 0xC0 and marker <= 0xCF
                and marker ~= 0xC4 and marker ~= 0xC8 and marker ~= 0xCC then
                local seg = f:read(5)
                if seg and #seg >= 5 then w, h = u16(seg, 4), u16(seg, 2) end
                break
            end
            if len < 2 then break end
            f:seek("cur", len - 2)
        end
    elseif sig and #sig >= 4 and sig:sub(1, 4) == "\137PNG" then
        kind = "png"
        f:seek("set", 16)
        local b = f:read(8)
        if b and #b >= 8 then
            w = b:byte(1) * 16777216 + b:byte(2) * 65536 + b:byte(3) * 256 + b:byte(4)
            h = b:byte(5) * 16777216 + b:byte(6) * 65536 + b:byte(7) * 256 + b:byte(8)
        end
    end
    f:close()
    if kind and w and h and w > 0 and h > 0 then return kind, w, h end
    return nil
end

local function fileHash(path)
    local ok_s, sha2 = pcall(require, "ffi/sha2")
    if not (ok_s and sha2 and sha2.md5) then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    if not data then return nil end
    local ok, h = pcall(sha2.md5, data)
    return ok and h or nil
end

-- Downloads one candidate and checks it is a picture. Returns the candidate
-- (without its label and url) or nil.
local function materialise(url, tag)
    if type(url) ~= "string" or url == "" then return nil, "no address" end
    local dir = cacheDir()
    if not ensureDir(dir) then return nil, "cannot make the cache folder" end
    local name = tostring(tag):gsub("[^%w_-]", "_")
    local raw = dir .. "/" .. name .. ".bin"
    local ok_dl, why = download(url, raw)
    if not ok_dl then return nil, why end
    local kind, w, h = imageInfo(raw)
    if not kind then
        pcall(os.remove, raw)
        return nil, "not a jpg or png picture"
    end
    local dest = dir .. "/" .. name .. "." .. kind
    pcall(os.remove, dest)
    if not os.rename(raw, dest) then
        pcall(os.remove, raw)
        return nil, "cannot move the picture"
    end
    return {
        path = dest, width = w, height = h,
        size = lfs.attributes(dest, "size"), hash = fileHash(dest),
    }
end

local function add(out, cand, label, url)
    if not cand then return false end
    cand.label, cand.url = label, url
    out[#out + 1] = cand
    return true
end

-- ── The book's ISBN ─────────────────────────────────────────────────────────

-- An ISBN inside a book's identifiers ("urn:isbn:978-84-...", "isbn 8420...").
function CoverOnline.isbnFrom(text)
    if type(text) ~= "string" or text == "" then return nil end
    local plain = text:gsub("[%s%-]", "")
    local isbn13 = plain:match("97[89]%d%d%d%d%d%d%d%d%d%d")
    if isbn13 then return isbn13 end
    local isbn10 = plain:lower():match("isbn:?(%d%d%d%d%d%d%d%d%d[%dx])")
    if isbn10 then return isbn10 end
    return nil
end

local function queryOf(book)
    local parts = {}
    if type(book.title) == "string" and book.title ~= "" then parts[#parts + 1] = book.title end
    if type(book.author) == "string" and book.author ~= "" then parts[#parts + 1] = book.author end
    return table.concat(parts, " ")
end

local function hasIsbn(book)
    return type(book.isbn) == "string" and book.isbn ~= ""
end

-- ── The sources ─────────────────────────────────────────────────────────────

local GOOGLE, OPENLIB, APPLE, AMAZON = _("Google Books"), _("Open Library"), _("Apple Books"), _("Amazon")

-- The biggest picture of a Google Books imageLinks table.
local function googlePick(il)
    local best = il.extraLarge or il.large or il.medium
    if best then
        return (best:gsub("^http:", "https:"):gsub("&edge=curl", ""))
    end
    best = il.small or il.thumbnail or il.smallThumbnail
    if best then
        return (best:gsub("^http:", "https:"):gsub("&edge=curl", ""))
    end
    return nil
end

local function noQuotes(text) return (tostring(text):gsub('"', " ")) end

local function google(book, out)
    if clock() < google_blocked_until then
        logger.info("KiKome: Google Books skipped (rate limit)")
        return
    end
    local base = "https://www.googleapis.com/books/v1/volumes?printType=books&maxResults=10&country=US&q="
    local urls = {}
    if hasIsbn(book) then urls[#urls + 1] = base .. "isbn:" .. enc(book.isbn) end
    if type(book.title) == "string" and book.title ~= "" then
        local q = enc('intitle:"' .. noQuotes(book.title) .. '"')
        if type(book.author) == "string" and book.author ~= "" then
            q = q .. "+" .. enc('inauthor:"' .. noQuotes(book.author) .. '"')
        end
        urls[#urls + 1] = base .. q
    end
    local plain = queryOf(book)
    if plain ~= "" then urls[#urls + 1] = base .. enc(plain) end
    local n, seen = 0, {}
    for _u, url in ipairs(urls) do
        if n >= MAX_PER_SOURCE then break end
        local data, why = getJson(url)
        if not data then
            note(GOOGLE, why)
            if tostring(why):find("429", 1, true) then
                google_blocked_until = clock() + GOOGLE_PAUSE
                break
            end
        elseif type(data.items) == "table" then
            for _i, item in ipairs(data.items) do
                if n >= MAX_PER_SOURCE then break end
                local il = item.volumeInfo and item.volumeInfo.imageLinks
                if type(il) == "table" and item.id and not seen[item.id] then
                    seen[item.id] = true
                    -- the id's own address gives the biggest picture (zoom=0); the
                    -- one the API lists is the second try
                    local tries = {
                        "https://books.google.com/books/content?id=" .. enc(item.id)
                            .. "&printsec=frontcover&img=1&zoom=0&source=gbs_api",
                    }
                    local listed = googlePick(il)
                    if listed then tries[#tries + 1] = listed end
                    for t, address in ipairs(tries) do
                        local c, reason = materialise(address, "google_" .. n .. "_" .. t)
                        if c then
                            if add(out, c, GOOGLE, address) then n = n + 1 end
                            break
                        end
                        note(GOOGLE, reason)
                    end
                end
            end
        end
    end
end

local function openLibrary(book, out)
    local n = 0
    if hasIsbn(book) then
        -- default=false: a missing cover is an error, not a blank picture
        local cu = "https://covers.openlibrary.org/b/isbn/" .. enc(book.isbn) .. "-L.jpg?default=false"
        local c, reason = materialise(cu, "openlib_isbn")
        if not c and not (reason or ""):find("HTTP 404") then note(OPENLIB, reason) end
        if add(out, c, OPENLIB, cu) then n = n + 1 end
    end
    local q = queryOf(book)
    if q ~= "" and n < MAX_PER_SOURCE then
        local data, why = getJson("https://openlibrary.org/search.json?q=" .. enc(q) .. "&limit=8&fields=cover_i,title")
        if not data then note(OPENLIB, why) end
        if data and type(data.docs) == "table" then
            for _i, doc in ipairs(data.docs) do
                if n >= MAX_PER_SOURCE then break end
                if doc.cover_i then
                    local cu = "https://covers.openlibrary.org/b/id/" .. tostring(doc.cover_i) .. "-L.jpg"
                    local c, reason = materialise(cu, "openlib_" .. tostring(doc.cover_i))
                    if not c then note(OPENLIB, reason) end
                    if add(out, c, OPENLIB, cu) then n = n + 1 end
                end
            end
        end
    end
end

-- Apple Books, through the iTunes search. Its pictures grow to what Apple has.
-- Every country has its own store, with the covers of its own editions: a
-- book in Spanish is found in the Spanish store with its Spanish cover.
local COUNTRY_OF_LANG = {
    es = "es", pt = "br", fr = "fr", de = "de", it = "it", en = "us",
    nl = "nl", ja = "jp", pl = "pl", sv = "se", da = "dk", no = "no",
}
local WIDE_COUNTRIES = { "us", "es", "br", "fr", "de", "it", "gb" }

local function appleCountries(book)
    if book.wide then return WIDE_COUNTRIES end
    local list = { "us" }
    local lang = tostring(book.language or ""):lower():sub(1, 2)
    local own = COUNTRY_OF_LANG[lang]
    if own and own ~= "us" then table.insert(list, 1, own) end
    return list
end

local function apple(book, out)
    local terms = {}
    if hasIsbn(book) then terms[#terms + 1] = book.isbn end
    local q = queryOf(book)
    if q ~= "" then terms[#terms + 1] = q end
    local per_store = book.wide and 2 or MAX_PER_STORE
    for _c, country in ipairs(appleCountries(book)) do
        local n = 0
        for u, term in ipairs(terms) do
            if n >= per_store then break end
            local data, why = getJson("https://itunes.apple.com/search?media=ebook&country=" .. country
                .. "&term=" .. enc(term) .. "&limit=8")
            if not data then
                note(APPLE, why)
                -- a rate limit is the same for every store: stop asking
                if tostring(why):find("429", 1, true) or tostring(why):find("403", 1, true) then return end
            end
            if data and type(data.results) == "table" then
                for i, r in ipairs(data.results) do
                    if n >= per_store then break end
                    local art = r.artworkUrl100
                    if type(art) == "string" then
                        local hi = art:gsub("/%d+x%d+bb", "/1200x1200bb")
                        local c, reason = materialise(hi, "apple_" .. country .. "_" .. u .. "_" .. i)
                        if not c then note(APPLE, reason) end
                        if add(out, c, APPLE, hi) then n = n + 1 end
                    end
                end
            end
        end
    end
end

-- Amazon keeps the picture of a book under its ISBN-10 (an address that is not
-- documented: it can stop working). A book it does not have answers with a
-- 1 px picture, which is dropped without a word.
local function toIsbn10(isbn)
    local d = (tostring(isbn):gsub("[^%dXx]", ""))
    if #d == 10 then return d:upper() end
    if #d == 13 and d:sub(1, 3) == "978" then
        local core, sum = d:sub(4, 12), 0
        for i = 1, 9 do sum = sum + (11 - i) * tonumber(core:sub(i, i)) end
        local check = (11 - sum % 11) % 11
        return core .. (check == 10 and "X" or tostring(check))
    end
    return nil
end

local function amazon(book, out)
    if not hasIsbn(book) then return end
    local isbn10 = toIsbn10(book.isbn)
    if not isbn10 then return end
    local cu = "https://m.media-amazon.com/images/P/" .. isbn10 .. ".01.LZZZZZZZ.jpg"
    local c, reason = materialise(cu, "amazon_" .. isbn10)
    if not c and not (reason or ""):find("HTTP 404", 1, true)
        and not (reason or ""):find("not a jpg or png", 1, true) then
        note(AMAZON, reason)
    end
    add(out, c, AMAZON, cu)
end

-- ── The search ──────────────────────────────────────────────────────────────

-- The same picture from two sources shows once.
local function dedup(list)
    local seen, out = {}, {}
    for _i, c in ipairs(list) do
        local key = c.hash or table.concat({ c.width or "?", c.height or "?", c.size or "?" }, "|")
        if not seen[key] then
            seen[key] = true
            out[#out + 1] = c
        else
            pcall(os.remove, c.path)
        end
    end
    return out
end

function CoverOnline.search(book, progress)
    local out = {}
    if type(book) ~= "table" then return out end
    CoverOnline.cleanup()
    CoverOnline.report = {}
    local function step(text, fn)
        if progress then pcall(progress, text) end
        local ok, err = pcall(fn, book, out)
        if not ok then logger.warn("KiKome: cover source failed:", tostring(err)) end
    end
    step(_("Searching Apple Books…"), apple)
    step(_("Searching Open Library…"), openLibrary)
    step(_("Searching Amazon…"), amazon)
    step(_("Searching Google Books…"), google)

    -- A cover is upright: wide pictures (banners, wrong matches) are dropped.
    local upright = {}
    for _i, c in ipairs(out) do
        -- (a picture under 100 px wide is the "no cover" placeholder some sources give)
        if c.height >= c.width and c.width >= 100 then upright[#upright + 1] = c else pcall(os.remove, c.path) end
    end
    local list = dedup(upright)
    -- the biggest first: the small ones of Open Library go to the back
    table.sort(list, function(a, b) return a.width * a.height > b.width * b.height end)
    while #list > MAX_TOTAL do
        local last = table.remove(list)
        pcall(os.remove, last.path)
    end
    return list
end

-- A picture already on the device, as a candidate (the file is not copied or
-- moved: applying it makes KOReader's own copy). nil and why when it is not a
-- JPG or PNG picture.
function CoverOnline.inspect(path)
    if type(path) ~= "string" or lfs.attributes(path, "mode") ~= "file" then return nil, "no such file" end
    local kind, w, h = imageInfo(path)
    if not kind then return nil, "not a jpg or png picture" end
    return {
        path = path, width = w, height = h,
        size = lfs.attributes(path, "size"),
        label = path:match("([^/]+)$") or path,
    }
end

-- ── Using one ───────────────────────────────────────────────────────────────

local function removeCustomCovers(DocSettings, file)
    local active = DocSettings:findCustomCoverFile(file)
    local guard = 0
    while active and guard < 5 do
        guard = guard + 1
        pcall(os.remove, active)
        local nxt = DocSettings:findCustomCoverFile(file)
        if nxt == active then break end   -- cannot be removed: do not spin
        active = nxt
    end
end

function CoverOnline.apply(file, image_path)
    if type(file) ~= "string" then return false, "no file" end
    if type(image_path) ~= "string" or lfs.attributes(image_path, "mode") ~= "file" then
        return false, "cover image not found"
    end
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings and DocSettings.flushCustomCover) then
        return false, "this KOReader cannot keep a custom cover"
    end
    -- a cover.png next to a cover.jpg would leave KOReader to pick either
    pcall(removeCustomCovers, DocSettings, file)
    local ok = pcall(function() DocSettings:flushCustomCover(file, image_path) end)
    pcall(function() DocSettings:getCustomCoverFile(true) end)
    if not ok then return false, "could not write the cover" end
    local found = false
    pcall(function() found = DocSettings:findCustomCoverFile(file) ~= nil end)
    if not found then return false, "the cover was not saved" end
    return true
end

function CoverOnline.revert(file)
    local ok_ds, DocSettings = pcall(require, "docsettings")
    if not (ok_ds and DocSettings and DocSettings.findCustomCoverFile) then return false end
    pcall(removeCustomCovers, DocSettings, file)
    pcall(function() DocSettings:getCustomCoverFile(true) end)
    return true
end

-- For the online metadata search (online_meta.lua), which asks the same way.
CoverOnline.getJson = getJson
CoverOnline.urlEncode = enc
CoverOnline.appleCountries = appleCountries

return CoverOnline
