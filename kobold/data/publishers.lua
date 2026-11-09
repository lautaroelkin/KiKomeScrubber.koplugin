-- kobold/data/publishers.lua — KiKome
-- The publishers of the books in the library, to offer while one is typed (as
-- the series, authors and keywords are). KOReader's cover browser does not keep
-- the publisher, so it is read from each EPUB's own OPF (epub_writer.lua) and
-- kept in a small file of ours.
--
--   Publishers.known()         -> { { name, count } } the most used first
--   Publishers.ensureScan()    reads the EPUBs not read yet, once per session, in
--                              the background (see below); asked when a publisher
--                              is about to be typed
--   Publishers.update(file)    one book's entry after its publisher was corrected
--                              or restored (the corrected value wins)
--   Publishers.touch()         the screen was used just now: the scan waits
--
-- The scan is gentle on purpose: one book per step, with a pause between steps,
-- and it waits while the screen is being used (two quiet seconds) or while a
-- book is open in the reader. A book is read again only when its file changed
-- (size and date), so after the first time only new books cost anything.

local lfs     = require("libs/libkoreader-lfs")
local logger  = require("logger")

local Publishers = {}

local VERSION = 1
local STEP_PAUSE   = 0.3    -- seconds between two books
local QUIET_NEEDED = 2      -- seconds without a tap before the scan goes on

local index = nil           -- { version, files = { [path] = { stamp, name = "..." | false } } }
local scanning, scanned = false, false
local last_activity = 0

local function clock()
    local ok, socket = pcall(require, "socket")
    if ok and socket and socket.gettime then return socket.gettime() end
    return os.time()
end

local function openStore()
    local ok_d, DataStorage = pcall(require, "datastorage")
    local ok_p, Persist = pcall(require, "persist")
    if not (ok_d and ok_p and DataStorage and Persist) then return nil end
    local dir = DataStorage:getDataDir() .. "/cache"
    if lfs.attributes(dir, "mode") ~= "directory" then pcall(lfs.mkdir, dir) end
    local ok, store = pcall(function()
        return Persist:new{ path = dir .. "/kobold_publishers.dat", codec = "zstd" }
    end)
    return ok and store or nil
end

local function load()
    if index then return index end
    index = { version = VERSION, files = {} }
    local store = openStore()
    if store then
        local ok, data = pcall(store.load, store)
        if ok and type(data) == "table" and data.version == VERSION and type(data.files) == "table" then
            index = data
        end
    end
    return index
end

local function save()
    local store = openStore()
    if store and index then pcall(store.save, store, index) end
end

local function clean(name)
    if type(name) ~= "string" then return nil end
    name = name:gsub("%s+", " "):match("^%s*(.-)%s*$")
    if name == "" or #name > 80 then return nil end
    return name
end

local function stampOf(file)
    local attr = lfs.attributes(file)
    if not attr then return nil end
    return tostring(attr.modification or 0) .. ":" .. tostring(attr.size or 0)
end

function Publishers.touch()
    last_activity = clock()
end

function Publishers.known()
    local counts, names = {}, {}
    for _path, entry in pairs(load().files) do
        local name = entry.name
        if name then
            local key = name:lower()
            counts[key] = (counts[key] or 0) + 1
            if not names[key] then names[key] = name end
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

-- A book's entry from what is true now: its corrected publisher, or the one the
-- book says (an empty correction means none, on purpose).
function Publishers.update(file)
    local stamp = stampOf(file)
    if not stamp then return end
    local Metadata = require("kobold.data.metadata")
    local custom = Metadata.custom(file)
    local name
    if custom.publisher ~= nil then
        name = clean(custom.publisher)
    else
        name = clean(Metadata.extraOriginals(file).publisher)
    end
    load().files[file] = { stamp = stamp, name = name or false }
    save()
end

local function readerHasBookOpen()
    local ReaderUI = package.loaded["apps/reader/readerui"]
    return ReaderUI ~= nil and ReaderUI.instance ~= nil and ReaderUI.instance.document ~= nil
end

function Publishers.ensureScan()
    if scanning or scanned then return end
    local ok_l, Library = pcall(require, "kobold.data.library")
    if not ok_l then return end
    local ok_s, books = pcall(Library.scan)
    if not (ok_s and type(books) == "table") then return end
    scanning = true

    local files = load().files
    local queue, present = {}, {}
    for _i, book in ipairs(books) do
        present[book.file] = true
        if book.file:lower():match("%.epub$") then
            local stamp = tostring(book.mtime or 0) .. ":" .. tostring(book.size or 0)
            local entry = files[book.file]
            if not (entry and entry.stamp == stamp) then
                queue[#queue + 1] = { file = book.file, stamp = stamp }
            end
        end
    end
    -- books that are gone leave the index
    local dropped = false
    for path in pairs(files) do
        if not present[path] then files[path] = nil; dropped = true end
    end
    if #queue == 0 then
        if dropped then save() end
        scanning, scanned = false, true
        return
    end

    local UIManager = require("ui/uimanager")
    local position = 1
    local function finish()
        scanning, scanned = false, true
        save()
        logger.info("KiKome: publishers read from", #queue, "books")
    end
    local function step()
        -- the screen is in use, or a book is open: not now
        if readerHasBookOpen() then return UIManager:scheduleIn(5, step) end
        if clock() - last_activity < QUIET_NEEDED then return UIManager:scheduleIn(1, step) end
        local item = queue[position]
        position = position + 1
        local ok, info = pcall(function() return require("kobold.data.epub_writer").readInfo(item.file) end)
        files[item.file] = { stamp = item.stamp, name = clean(ok and info and info.publisher or nil) or false }
        if position % 25 == 0 then save() end   -- so that a long scan is not lost
        if position <= #queue then
            UIManager:scheduleIn(STEP_PAUSE, step)
        else
            finish()
        end
    end
    UIManager:scheduleIn(1, step)
end

return Publishers
