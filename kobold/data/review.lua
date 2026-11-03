-- kobold/data/review.lua — Kobold
-- What the Edit screen of the book details page reads and writes about one
-- book: its star rating, its review, its reading status and whether it is in
-- Favorites. No UI.
--
-- Rating, review and status live where KOReader's own Book status screen
-- keeps them, in the book's sidecar under "summary" (summary.rating 1 to 5,
-- summary.note, summary.status), so both sides always agree. Favorites is
-- KOReader's Favorites collection.
--
--   Review.get(file)               -> { rating = 0..5, note = string|nil,
--                                       status = "unread"|"reading"|"onhold"|"finished",
--                                       favorite = bool }
--   Review.setRating(file, n)      n = 1..5, or nil / 0 to clear it
--   Review.setNote(file, text)     "" or nil clears it
--   Review.setStatus(file, id)     "reading", "onhold" or "finished"
--   Review.setFavorite(file, on)
-- Each setter returns true when it saved.

local Review = {}

local STATUS_TO_KOREADER = { reading = "reading", onhold = "abandoned", finished = "complete" }

local function nonEmpty(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

-- The settings of a book that is open in the reader right now (it is parked
-- under Kobold while Kobold is on screen). The reader keeps them in memory
-- and writes them back when it closes, so a second copy written from here
-- would be overwritten.
local function liveSettings(file)
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local ui = ReaderUI and ReaderUI.instance
    if ui and ui.document and ui.document.file == file and ui.doc_settings then
        return ui.doc_settings
    end
    return nil
end

-- Runs fn(summary) on the book's summary table and saves it. Returns true
-- when it was saved.
local function updateSummary(file, fn)
    -- A book that was never opened has no sidecar yet: the library scan
    -- (library.lua) must look again once this one is made, or the book
    -- would still read as unread there.
    local had_sidecar = true
    pcall(function()
        had_sidecar = require("kobold.data.library").sidecarStamp(file) ~= nil
    end)
    local ds = liveSettings(file)
    local own = false
    if not ds then
        local ok, DocSettings = pcall(require, "docsettings")
        if not (ok and DocSettings) then return false end
        local ok_open, opened = pcall(function() return DocSettings:open(file) end)
        if not (ok_open and opened) then return false end
        ds, own = opened, true
    end
    local ok = pcall(function()
        local summary = ds:readSetting("summary")
        if type(summary) ~= "table" then summary = {} end
        fn(summary)
        summary.modified = os.date("%Y-%m-%d", os.time())
        ds:saveSetting("summary", summary)
        ds:flush()
    end)
    if own then pcall(function() ds:close() end) end
    if ok and not had_sidecar then
        pcall(function() require("kobold.data.library").invalidate() end)
    end
    return ok
end

local function readSummary(file)
    local ds = liveSettings(file)
    local own = false
    if not ds then
        local ok, DocSettings = pcall(require, "docsettings")
        if not (ok and DocSettings) then return {} end
        local ok_open, opened = pcall(function() return DocSettings:open(file) end)
        if not (ok_open and opened) then return {} end
        ds, own = opened, true
    end
    local summary = ds:readSetting("summary")
    if own then pcall(function() ds:close() end) end
    return type(summary) == "table" and summary or {}
end

-- ── Favorites ──────────────────────────────────────────────────────────────

local function collections()
    local ok, RC = pcall(require, "readcollection")
    if not (ok and RC) then return nil end
    if not RC.coll and RC._read then pcall(RC._read, RC) end
    if type(RC.coll) ~= "table" then return nil end
    return RC
end

-- The key KOReader stores Favorites under.
local function favoritesKey(RC)
    local ok, Chips = pcall(require, "kobold.data.chips")
    local key = ok and Chips and Chips.collectionKey(RC, "favorites")
    return key or RC.default_collection_name or "favorites"
end

function Review.isFavorite(file)
    local RC = collections()
    if not RC then return false end
    local name = favoritesKey(RC)
    if RC.isFileInCollection then
        local ok, inside = pcall(RC.isFileInCollection, RC, file, name)
        if ok then return inside and true or false end
    end
    local coll = RC.coll[name]
    return type(coll) == "table" and coll[file] ~= nil
end

function Review.setFavorite(file, on)
    local RC = collections()
    if not RC then return false end
    local name = favoritesKey(RC)
    local method = on and RC.addItem or RC.removeItem
    if not method then return false end
    local ok = pcall(method, RC, file, name)
    return ok and (Review.isFavorite(file) == (on and true or false))
end

-- ── Rating, review, status ─────────────────────────────────────────────────

-- The status Kobold shows for a book, as My Books works it out: a book with
-- progress and no status of its own counts as reading.
local function statusId(file, summary)
    if summary.status == "complete" then return "finished" end
    if summary.status == "abandoned" then return "onhold" end
    if summary.status == "reading" then return "reading" end
    local ok, MyBooks = pcall(require, "kobold.data.mybooks")
    if ok and MyBooks and MyBooks.statusOf then
        local ok_s, status = pcall(MyBooks.statusOf, file)
        if ok_s and status then return status end
    end
    return "unread"
end

function Review.get(file)
    local summary = readSummary(file)
    local rating = tonumber(summary.rating) or 0
    return {
        rating = math.max(0, math.min(5, math.floor(rating))),
        note = nonEmpty(summary.note),
        status = statusId(file, summary),
        favorite = Review.isFavorite(file),
    }
end

function Review.setRating(file, n)
    n = tonumber(n)
    if n and (n < 1 or n > 5) then n = nil end
    return updateSummary(file, function(summary)
        summary.rating = n and math.floor(n) or nil
    end)
end

function Review.setNote(file, text)
    return updateSummary(file, function(summary)
        summary.note = nonEmpty(text)
    end)
end

function Review.setStatus(file, id)
    local status = STATUS_TO_KOREADER[id]
    if not status then return false end
    local saved = updateSummary(file, function(summary)
        summary.status = status
    end)
    if saved then
        -- The file browser keeps its own copy of the status (its icons).
        pcall(function()
            require("ui/widget/booklist").setBookInfoCacheProperty(file, "status", status)
        end)
    end
    return saved
end

return Review
