-- kobold/data/stable_pages.lua — KiKome
-- Makes KOReader's stable page numbers follow the page count the user put in
-- Metadata > More details ("Pages"), for a book that is open.
--
-- There are three choices, the same for every book and for Settings > General > Stable pages:
--   "off"       stable pages off
--   "koreader"  stable pages on, with KOReader's own numbering (its count, or the publisher's)
--   "metadata"  stable pages on, numbered from the Metadata page count (which also replaces the
--               publisher's own page numbers, if the book has them). A book with no page count
--               in Metadata uses KOReader's numbering instead.
-- The choice of Settings is the one every book follows; a book can have its own
-- (Edit > Book settings > Stable pages). In both places a dot marks a choice that was made
-- and bold marks what is in use. While no choice has been made in Settings, KiKome leaves
-- the books alone and they follow KOReader's own switch by themselves. "off" is a choice:
-- stable pages off in every book without a choice of its own. When a choice is taken away,
-- a book that got its stable pages from it gets back what it had before (the next time it
-- opens, or at once if it is open now).
--
--   StablePages.apply(ui, opts) -> status, size, chars, changed
--       opts.force: act even if it was done for this number before
--       status: "ok"          the total is the one asked for (size = how many there are now)
--               "approx"      the closest total KOReader can make (it cannot reach the asked one)
--               "koreader"    stable pages on, with KOReader's numbering
--               "koreader_later"  the same, but the numbers change when the book opens again
--               "off"         stable pages off for this book
--               "idle"        no choice for this book and the setting is off: left alone
--               "locked"      KOReader kept the publisher's page numbers
--               "unsupported" this KOReader (or this book) cannot do it from here
--       changed: true when something was done now (false when it was already so)
--   StablePages.announce(ui, status, size, all)   the short message (all: for every status)
--   StablePages.pagesOf(file)              the page count put in Metadata, or nil
--   StablePages.liveUi(file)               the reader that has this book open now (parked too), or nil
--   StablePages.choice(file) -> effective, own   the option the book follows, and the one chosen for it alone (or nil)
--   StablePages.setMode(file, mode)        -> true when it saved: the book's own choice
--   StablePages.clearMode(file)            -> true when it saved: the book follows the setting again
--   StablePages.globalMode()               what Settings shows: KiKome's own choice, or while there is none,
--                                          KOReader's own switch (Default settings for new books > use stable page numbers)
--   StablePages.ownChoice()                KiKome's own choice (the dot), nil while none has been made
--   StablePages.clearGlobalMode()          -> true when it saved: no choice made (KiKome follows KOReader's switch)
--   StablePages.setGlobalMode(mode)        -> true when it saved
--   StablePages.applyOpen()                the pages of the book that is open now (parked too), if any
--
-- How it works. KOReader numbers stable pages by characters: a new page every N
-- characters (its "Characters per page" setting). A page count is turned into
-- that N by trying values between 500 and 3000 (KOReader's own limits for the
-- setting) and keeping the one whose total is closest: the search the "Stable
-- Page Count" plugin does. Nothing is invented: the pages are KOReader's own
-- synthetic pages, only with the N that gives the total that was asked for. At
-- 3000 characters per page a book has a smallest total (about 6/10 of what it
-- has at 1750): a smaller one cannot be made, and the closest is used and said.
-- An EPUB is made of HTML files and each one starts a new page, so some totals
-- cannot be reached exactly either.
--
-- The N is saved with the book (KOReader's own "pagemap_chars_per_synthetic_page"
-- and "pagemap_use_page_labels"), so KOReader itself builds the same pages the
-- next time the book opens and this has nothing left to do.

local logger = require("logger")

local StablePages = {}

local MIN_CHARS, MAX_CHARS = 500, 3000
local MAX_PROBES = 14

local function pagesOf(file)
    local ok, custom = pcall(function() return require("kobold.data.metadata").custom(file) end)
    if not ok or type(custom) ~= "table" then return nil end
    local n = tonumber(custom.pages)
    if n and n >= 1 then return math.floor(n) end
    return nil
end

StablePages.pagesOf = pagesOf

-- ── The book's own choice ──────────────────────────────────────────────────
-- Kept in the book's sidecar, next to the numbers KOReader itself saves there.
local MODE_KEY = "kikome_stable"   -- "metadata", "koreader" or "off"
-- What this file saved when it made the pages: taken out when the book stops using the Metadata count.
-- (kikome_pages_chars: our number of characters per page; _orig: what the book had before it,
-- _pub: the book had the publisher's own page numbers, which the Metadata count replaced)
local MADE_KEYS = {
    "pagemap_chars_per_synthetic_page", "kikome_pages_target", "kikome_pages_size",
    "kikome_pages_chars", "kikome_pages_orig", "kikome_pages_pub",
}

-- The reader that has this book open right now. A book that is parked under
-- KiKome is open too: its settings live in memory and are written when it closes.
function StablePages.liveUi(file)
    local RU = package.loaded["apps/reader/readerui"]
    local ui = RU and RU.instance
    if ui and ui.document and ui.document.file == file and ui.doc_settings then return ui end
    return nil
end

-- The settings of a book: the live ones when it is open, else its sidecar.
local function openSettings(file)
    local ui = StablePages.liveUi(file)
    if ui then return ui.doc_settings, false end
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings) then return nil end
    local ok_open, ds = pcall(function() return DocSettings:open(file) end)
    if ok_open and ds then return ds, true end
    return nil
end

local function release(ds, own)
    if own and ds then pcall(function() ds:close() end) end
end

-- The book's own choice, or nil when it has none. (Two earlier versions kept it
-- as kikome_pages_mode "on"/"off" and kikome_pages_off: read as the same choices.)
local function savedMode(ds)
    if not ds then return nil end
    local ok, mode, old_mode, old_off = pcall(function()
        return ds:readSetting(MODE_KEY), ds:readSetting("kikome_pages_mode"), ds:readSetting("kikome_pages_off")
    end)
    if not ok then return nil end
    if mode == "metadata" or mode == "koreader" or mode == "off" then return mode end
    if old_mode == "on" then return "metadata" end
    if old_mode == "off" or old_off == true then return "koreader" end
    return nil
end

-- KiKome's own choice ("off", "koreader" or "metadata"), nil while none has been made.
-- A KiKome that only had the older switch ("Use metadata page number", now part of
-- this choice) keeps what it said.
local function ownChoice()
    local ok, mode = pcall(function()
        local Prefs = require("kobold.data.prefs")
        local m = Prefs.get("stable_pages_mode")
        if m == nil and Prefs.get("stable_pages") == true then m = "metadata" end
        return m
    end)
    if ok and (mode == "koreader" or mode == "metadata" or mode == "off") then return mode end
    return nil
end
StablePages.ownChoice = ownChoice

-- KOReader's own switch, read as it is now: Settings > Default settings for new books >
-- use stable page numbers ("pagemap_use_page_labels" in its settings). The books that
-- have no value of their own follow it by themselves.
local function koreaderDefaultOn()
    local ok, on = pcall(function()
        return G_reader_settings ~= nil and G_reader_settings:readSetting("pagemap_use_page_labels") == true
    end)
    return ok and on == true
end

-- What Settings shows in bold: KiKome's own choice; while none has been made, KOReader's
-- switch, as it is now ("koreader" when it is on, else "off").
local function globalMode()
    local m = ownChoice()
    if m then return m end
    return koreaderDefaultOn() and "koreader" or "off"
end
StablePages.globalMode = globalMode

function StablePages.setGlobalMode(mode)
    if mode ~= "koreader" and mode ~= "metadata" then mode = "off" end
    local ok = pcall(function()
        local Prefs = require("kobold.data.prefs")
        Prefs.set("stable_pages_mode", mode)
        Prefs.set("stable_pages", nil)   -- the older switch: it is part of this choice now
    end)
    return ok
end

-- Takes the choice of Settings away: none of the three has a dot, and KiKome follows
-- KOReader's own switch again. Apply it afterwards (applyOpen) like any other change.
function StablePages.clearGlobalMode()
    local ok = pcall(function()
        local Prefs = require("kobold.data.prefs")
        Prefs.set("stable_pages_mode", nil)
        Prefs.set("stable_pages", nil)
    end)
    return ok
end

-- What the book does: "metadata", "koreader", "off", or nil (left alone: no choice
-- of its own, and the setting is off).
local function modeOf(ds)
    local mode = savedMode(ds)
    if mode then return mode end
    -- the choice of Settings; nil while none has been made (the book is left alone)
    return ownChoice()
end

-- Whether the book shows stable pages now, in KOReader's own switch: the live
-- reader if the book is open, else what its sidecar says, else KOReader's default.
local function labelsOn(file, ds)
    local ui = StablePages.liveUi(file)
    if ui and ui.pagemap and ui.pagemap.use_page_labels ~= nil then
        return ui.pagemap.use_page_labels == true
    end
    local ok, value = pcall(function()
        local v = ds and ds:readSetting("pagemap_use_page_labels")
        if v == nil and G_reader_settings then v = G_reader_settings:readSetting("pagemap_use_page_labels") end
        return v
    end)
    return ok and value == true
end

-- What the card of the book shows: `effective`, the option the book follows (bold), and
-- `own`, the one chosen for this book alone (the dot), nil when there is none.
-- Without a choice of its own, the book follows the setting. With the setting off, it
-- follows what it will have: a book that got its stable pages from the setting goes back
-- to what it had before; any other has what it really has (stable pages turned on from
-- KOReader's own menu show as "koreader").
function StablePages.choice(file)
    local ds, was_own = openSettings(file)
    local saved = savedMode(ds)
    local effective = saved
    if not effective then
        local global = ownChoice()
        if global then
            effective = global
        else
            local prev, made
            pcall(function()
                prev = ds and ds:readSetting("kikome_global_prev")
                made = ds ~= nil and ds:readSetting("kikome_pages_target") ~= nil
            end)
            if prev ~= nil or made then
                effective = (prev == true) and "koreader" or "off"
            else
                effective = labelsOn(file, ds) and "koreader" or "off"
            end
        end
    end
    release(ds, was_own)
    return effective, saved
end

function StablePages.setMode(file, mode)
    if mode ~= "metadata" and mode ~= "koreader" then mode = "off" end
    -- A book that was never opened has no sidecar yet: the library scan must
    -- look again once this one is made (the same care as the review's).
    local had_sidecar = true
    pcall(function()
        had_sidecar = require("kobold.data.library").sidecarStamp(file) ~= nil
    end)
    local ds, own = openSettings(file)
    if not ds then return false end
    local ok = pcall(function()
        ds:saveSetting(MODE_KEY, mode)
        ds:delSetting("kikome_pages_mode")
        ds:delSetting("kikome_pages_off")
        -- what the book had before KiKome touched it, for when it follows the setting again
        if ds:readSetting("kikome_global_prev") == nil then
            local had = labelsOn(file, ds)
            if ds:readSetting("kikome_pages_target") ~= nil then had = false end   -- those were ours
            ds:saveSetting("kikome_global_prev", had)
        end
        -- what was made for this book goes. A book that is open keeps its marks
        -- for now: apply() needs them to know there is a number of ours to take back.
        -- The rest of what was made stays: the next time the book opens, apply()
        -- uses it to see whether our number is still in the pages, and takes it back.
        if own and mode ~= "metadata"
            and (ds:readSetting("kikome_pages_target") ~= nil or ds:readSetting("kikome_pages_chars") ~= nil) then
            ds:delSetting("pagemap_chars_per_synthetic_page")
        end
        ds:flush()
    end)
    release(ds, own)
    if ok and not had_sidecar then pcall(function() require("kobold.data.library").invalidate() end) end
    return ok
end

-- The book follows the setting again: its own choice goes. Apply it afterwards, so that
-- the book gets what the setting says (with the setting off, what it had before).
function StablePages.clearMode(file)
    local ds, own = openSettings(file)
    if not ds then return false end
    local ok = pcall(function()
        ds:delSetting(MODE_KEY)
        ds:delSetting("kikome_pages_mode")
        ds:delSetting("kikome_pages_off")
        ds:flush()
    end)
    release(ds, own)
    return ok
end

-- How many stable pages the document has now.
local function mapSize(doc)
    if type(doc.getPageMap) ~= "function" then return nil end
    local ok, map = pcall(doc.getPageMap, doc)
    if ok and type(map) == "table" then return #map end
    return nil
end

-- True when the map in use is the publisher's own (not a synthetic one).
local function usesPublisherMap(doc)
    if type(doc.isPageMapDocumentProvided) == "function" then
        local ok, provided = pcall(doc.isPageMapDocumentProvided, doc)
        if ok then return provided and true or false end
    end
    if type(doc.hasPageMap) ~= "function" then return false end
    local ok, has = pcall(doc.hasPageMap, doc)
    if not (ok and has) then return false end
    if type(doc.isPageMapSynthetic) ~= "function" then return true end   -- cannot tell: leave it alone
    local ok2, synthetic = pcall(doc.isPageMapSynthetic, doc)
    if ok2 then return not synthetic end
    return true
end

-- Builds the synthetic map again with `chars` characters per page. The IfNone...
-- variant is NOT used: it leaves a synthetic map that already exists as it is.
local function build(doc, chars)
    local fn = doc.buildSyntheticPageMap
    if type(fn) ~= "function" then return false end
    if not pcall(fn, doc, chars) then return false end
    -- the document must say it took the new value
    if type(doc.getSyntheticPageMapCharsPerPage) == "function" then
        local ok, now = pcall(doc.getSyntheticPageMapCharsPerPage, doc)
        if ok and type(now) == "number" and now ~= chars then return false end
    end
    return true
end

local function close(size, n)
    return size ~= nil and math.abs(size - n) <= math.max(1, math.floor(n * 0.01))
end

-- The total of pages falls as the characters per page grow: a binary search.
local function search(doc, n)
    local lo, hi = MIN_CHARS, MAX_CHARS
    local best_chars, best_diff, best_size
    for _i = 1, MAX_PROBES do
        if lo > hi then break end
        local mid = math.floor((lo + hi) / 2)
        if not build(doc, mid) then return nil end
        local size = mapSize(doc)
        if not size then return nil end
        local diff = math.abs(size - n)
        if not best_diff or diff < best_diff then best_chars, best_diff, best_size = mid, diff, size end
        if size == n then break end
        if size > n then lo = mid + 1 else hi = mid - 1 end
    end
    if best_chars then
        -- the last probe is not always the best one: leave the best one built
        if mapSize(doc) ~= best_size and not build(doc, best_chars) then return nil end
        return best_chars, best_size
    end
    return nil
end

-- Turns on KOReader's stable page numbers for this book and remembers the result.
local function enable(ui, chars, n, size)
    local pm, settings = ui.pagemap, ui.doc_settings
    pcall(function()
        pm.chars_per_synthetic_page = chars
        pm.use_page_labels = true
    end)
    if settings then
        pcall(function()
            settings:saveSetting("pagemap_chars_per_synthetic_page", chars)
            settings:saveSetting("kikome_pages_chars", chars)
            settings:saveSetting("pagemap_use_page_labels", true)
            settings:saveSetting("kikome_pages_target", n)
            settings:saveSetting("kikome_pages_size", size)
        end)
    end
    pcall(function() ui.view.footer:onUpdateFooter(true) end)
    pcall(function() require("ui/uimanager"):setDirty("all", "partial") end)
end

-- KOReader's own count of characters per page, when nothing else says (the book's
-- own before ours, then the one KOReader has as default, then a common value).
local DEFAULT_CHARS = 1500
local function koreaderChars(settings)
    local orig = settings and settings:readSetting("kikome_pages_orig")
    if type(orig) == "number" then return orig end
    local global = G_reader_settings and G_reader_settings:readSetting("pagemap_chars_per_synthetic_page")
    if type(global) == "number" then return global end
    return DEFAULT_CHARS
end

-- Redraws what shows the page numbers.
local function touchView(ui)
    pcall(function() ui.view.footer:onUpdateFooter(true) end)
    pcall(function() require("ui/uimanager"):setDirty("all", "partial") end)
end

-- Takes back what was made from the Metadata count. Our number can be in the
-- pages in two ways: in memory (KOReader writes the characters per page it has
-- into the sidecar every time the book closes) and in the pages the document
-- itself keeps from last time (it can load them already built, and then it
-- does not build them again). So it looks at the pages in use: the characters
-- the document has, or a total as close to ours as we made.
-- Returns: rebuilt (the pages are KOReader's again now), reopen (they can only
-- be, when the book is loaded again: the publisher's page numbers were replaced).
local function restore(ui)
    local doc, pm, settings = ui.document, ui.pagemap, ui.doc_settings
    if not settings then return false, false end
    local target = settings:readSetting("kikome_pages_target")
    local marker = settings:readSetting("kikome_pages_chars")
    if target == nil and marker == nil then return false, false end
    local in_effect = false
    local ok, doc_chars = pcall(function() return doc:getSyntheticPageMapCharsPerPage() end)
    if marker and ok and doc_chars == marker then in_effect = true end
    if not in_effect and target and close(mapSize(doc), target) then in_effect = true end
    local rebuilt, reopen = false, false
    if in_effect then
        if settings:readSetting("kikome_pages_pub") == true then
            reopen = true
        elseif not usesPublisherMap(doc) then
            rebuilt = build(doc, koreaderChars(settings))
        end
    end
    pcall(function()
        pm.chars_per_synthetic_page = G_reader_settings
            and G_reader_settings:readSetting("pagemap_chars_per_synthetic_page") or nil
        for _i, k in ipairs(MADE_KEYS) do settings:delSetting(k) end
    end)
    return rebuilt, reopen
end

-- "off": stable pages are turned off for this book, and what was made for it goes.
local function turnOff(ui)
    local pm, settings = ui.pagemap, ui.doc_settings
    local rebuilt = restore(ui)
    local changed = pm.use_page_labels ~= false
    pcall(function() pm.use_page_labels = false end)
    if settings then pcall(function() settings:saveSetting("pagemap_use_page_labels", false) end) end
    if changed or rebuilt then touchView(ui) end
    return "off", nil, nil, changed or rebuilt
end

-- "koreader": stable pages on, and the numbering is KOReader's own: what was made
-- from the Metadata count is taken back.
local function useKOReader(ui)
    local pm, settings = ui.pagemap, ui.doc_settings
    local rebuilt, reopen = restore(ui)
    local changed = pm.use_page_labels ~= true
    pcall(function() pm.use_page_labels = true end)
    if settings then pcall(function() settings:saveSetting("pagemap_use_page_labels", true) end) end
    if changed or rebuilt then touchView(ui) end
    local size = mapSize(ui.document)
    -- no pages yet, or the publisher's are gone from this session: KOReader gives them when the book loads again
    local later = reopen or (size or 0) == 0
    return later and "koreader_later" or "koreader", size, nil, changed or rebuilt or reopen
end

-- The choice of Settings was taken away and this book has no choice of its own: if its stable
-- pages came from the setting (not from KOReader's own menu), it gets back what it had
-- before. A book that got them from the older switch (no mark, but our Metadata pages)
-- had none before. Taken out right away, so that it happens once.
local function undoGlobal(ui)
    local settings = ui.doc_settings
    if not settings then return "idle" end
    local prev = settings:readSetting("kikome_global_prev")
    local legacy = prev == nil and settings:readSetting("kikome_pages_target") ~= nil
    if prev == nil and not legacy then return "idle" end
    pcall(function() settings:delSetting("kikome_global_prev") end)
    if prev == true then return useKOReader(ui) end   -- it had KOReader's stable pages on already
    return turnOff(ui)
end

function StablePages.apply(ui, opts)
    opts = opts or {}
    local doc, pm = ui and ui.document, ui and ui.pagemap
    if not (doc and pm) then return "unsupported" end
    if doc.info and doc.info.has_pages then return "unsupported" end   -- PDF and the like
    local mode = modeOf(ui.doc_settings)
    if mode == nil then return undoGlobal(ui) end
    -- A book that follows the setting remembers whether it had stable pages before,
    -- to give that back when the setting goes off.
    local ds = ui.doc_settings
    if ds and savedMode(ds) == nil and ds:readSetting("kikome_global_prev") == nil then
        pcall(function()
            local had = pm.use_page_labels == true
            if ds:readSetting("kikome_pages_target") ~= nil then had = false end   -- those were ours
            ds:saveSetting("kikome_global_prev", had)
        end)
    end
    if mode == "off" then return turnOff(ui) end
    if mode == "koreader" then return useKOReader(ui) end
    local n = pagesOf(doc.file)
    if not n then return useKOReader(ui) end   -- no page count in Metadata: KOReader's numbering
    -- the publisher's own page numbers, if the book has them, are replaced
    local publisher = usesPublisherMap(doc)

    local settings = ui.doc_settings
    local remembered = settings and settings:readSetting("kikome_pages_target")
    local remembered_size = settings and settings:readSetting("kikome_pages_size")
    local stored_chars = settings and settings:readSetting("pagemap_chars_per_synthetic_page")
    -- The first time: what the book has before our pages, to give it back
    if settings and remembered == nil and settings:readSetting("kikome_pages_chars") == nil then
        local before
        if not publisher then pcall(function() before = doc:getSyntheticPageMapCharsPerPage() end) end
        pcall(function()
            settings:saveSetting("kikome_pages_orig", type(before) == "number" and before or false)
            settings:saveSetting("kikome_pages_pub", publisher and true or nil)
        end)
    end

    -- Already so: KOReader built the saved pages when the book opened.
    local now = mapSize(doc)
    if not opts.force and remembered == n and now and now == remembered_size then
        return close(now, n) and "ok" or "approx", now, stored_chars, false
    end

    -- Same page count as last time: one build with the saved value is enough.
    if not opts.force and remembered == n and type(stored_chars) == "number" and build(doc, stored_chars) then
        local size = mapSize(doc)
        if size and size == remembered_size then
            enable(ui, stored_chars, n, size)
            return close(size, n) and "ok" or "approx", size, stored_chars, true
        end
    end

    local chars, size = search(doc, n)
    if not chars then return "unsupported" end
    -- the publisher's map is still the one in use: KOReader did not let it go
    if publisher and usesPublisherMap(doc) then return "locked" end
    enable(ui, chars, n, size)
    logger.info("KiKome: stable pages", size, "for a target of", n, "with", chars, "characters per page")
    return close(size, n) and "ok" or "approx", size, chars, true
end

-- The words for a result, or nil when there is nothing to say.
function StablePages.message(status, size, n)
    local _ = require("kobold.i18n")
    if status == "ok" then
        return string.format(_("Stable pages: %d"), size or 0)
    elseif status == "approx" and n then
        return string.format(_("Stable pages: %d, the closest to %d that KOReader allows"), size or 0, n)
    elseif status == "locked" then
        return _("KOReader would not replace the publisher's page numbers.")
    elseif status == "none" then
        return _("No page count in Metadata.")
    elseif status == "off" then
        return _("Stable pages are off for this book.")
    elseif status == "koreader" then
        if size then return string.format(_("KOReader's numbering: %d stable pages."), size) end
        return _("Stable pages are on, with KOReader's numbering.")
    elseif status == "koreader_later" then
        return _("Stable pages are on, with KOReader's numbering. It changes when the book is opened again.")
    end
    return nil
end

-- The book that is open now (parked under KiKome too, where it would not load
-- again), if there is one: its stable pages, as its choice or the setting says.
function StablePages.applyOpen()
    local RU = package.loaded["apps/reader/readerui"]
    local ui = RU and RU.instance
    if not (ui and ui.document and ui.doc_settings) then return end
    local status, size = StablePages.apply(ui)
    StablePages.announce(ui, status, size)
end

-- The short message after the pages were set: only when something changed
-- (`all`: for every result, when the user asked for it).
function StablePages.announce(ui, status, size, all)
    local Toast = require("kobold.ui.toast")
    if not all and status ~= "ok" and status ~= "approx" then return end
    local n = ui and ui.document and pagesOf(ui.document.file)
    local text = StablePages.message(status, size, n)
    if text then Toast.show(text, { timeout = (status == "approx") and 6 or 4 }) end
end

return StablePages
