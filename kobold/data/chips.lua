-- kobold/data/chips.lua — KiKome
-- The chips along the top of the Home shelf: their order, which are on, and
-- the folder and collection chips the reader added. Stored in G_reader_settings, so the
-- shelf (library_shelf.lua) and Settings > Shelves read the same list.
--
--   Chips.list()            every chip, in order (on and off)
--   Chips.enabledList()     the chips on, in order
--   Chips.add(path)         a chip for a folder: ok | false, "max" | "dup"
--   Chips.addCollection(name)  a chip for one KOReader collection: ok | false, "max" | "dup"
--   Chips.collectionNames() the collections that can get a chip (Favorites / To be read have theirs)
--   Chips.remove(id)        removes a folder or collection chip (built-in ones stay)
--   Chips.setEnabled(id, on)  false, "last" when it would leave no chip on
--   Chips.move(id, dir)     dir = -1 (up) or 1 (down)
--   Chips.subfolders(files, path)  names of the folders right under path
--   Chips.rootDir()         KOReader's home folder ("" for "/")
--   Chips.shelvesOn(id)     true when the chip draws its shelf boards (default)
--   Chips.setShelves(id, on)
--   Chips.collectionKind(RC, name)  "favorites" | "tbr" | nil: which special collection `name` is
--   Chips.collectionKey(RC, kind)   the ReadCollection key of Favorites / To be read, or nil
--   Chips.collectionHidden(RC, name) true when `name` is Favorites / To be read and is hidden
--                           from the Collections list (Settings > Shelves > Collections)
--   Chips.collectionShown(kind)     true when that collection is listed under Collections (default)
--   Chips.setCollectionShown(kind, on)
--   Chips.libraryCollectionShown(kind) / Chips.setLibraryCollectionShown(kind, on) /
--   Chips.libraryCollectionHidden(RC, name)   the same three for the Collections tab of the
--                           Library (My Books), kept apart from the Home chip
--   Chips.signature()       a string that changes when the chips change

local M = {}

-- The most chips that can be on at once. Chips that are off do not count,
-- and there is no limit on how many folder chips can be saved. The chip bar
-- shows as many as fit and pages through the rest with a chevron.
M.MAX = 12

local KEY = "kikome_shelf_chips"

-- Built-in chips and their names. Their order here is the order they start in.
local BUILTIN = {
    folders = "Home", home = "Library", series = "Series",
    authors = "Authors", collections = "Collections",
    favorites = "Favorites", tbr = "To be read", genres = "Genres",
}
local BUILTIN_ORDER = { "folders", "home", "series", "authors", "collections", "favorites", "tbr", "genres" }

-- Built-in chips that start off: Favorites and To be read show one KOReader
-- collection each, which is also listed under Collections (see collectionShown
-- below); Genres groups the books by their keywords, as the Library's Genres tab.
local DEFAULT_OFF = { favorites = true, tbr = true, genres = true }

-- Whether Favorites / To be read are listed inside the Collections chip.
local SHOWN_KEY = "kikome_shelf_collections_shown"

-- The name a folder chip shows. The home folder itself is "" (no name).
local function labelFor(path)
    if path == "" then return "All books" end
    return path:match("([^/]+)$") or path
end

local function readSaved()
    local ok, saved = pcall(function() return G_reader_settings:readSetting(KEY) end)
    return (ok and type(saved) == "table") and saved or {}
end

local function writeSaved(list)
    local out = {}
    for _i, c in ipairs(list) do
        out[#out + 1] = { id = c.id, enabled = c.enabled, path = c.path, name = c.name, shelves = c.shelves }
    end
    pcall(function() G_reader_settings:saveSetting(KEY, out) end)
end

local function normalise(e)
    if type(e) ~= "table" or type(e.id) ~= "string" then return nil end
    local on
    if DEFAULT_OFF[e.id] then on = (e.enabled == true) else on = (e.enabled ~= false) end
    local shelves = e.shelves ~= false
    if BUILTIN[e.id] then
        return { id = e.id, label = BUILTIN[e.id], enabled = on, kind = "builtin", shelves = shelves }
    end
    if e.id:sub(1, 7) == "folder:" and type(e.path) == "string" then
        return { id = e.id, path = e.path, label = labelFor(e.path), enabled = on, kind = "folder", shelves = shelves }
    end
    if e.id:sub(1, 11) == "collection:" and type(e.name) == "string" and e.name ~= "" then
        return { id = e.id, name = e.name, label = e.name, enabled = on, kind = "collection", shelves = shelves }
    end
    return nil
end

function M.list()
    local out, seen = {}, {}
    for _i, e in ipairs(readSaved()) do
        local c = normalise(e)
        if c and not seen[c.id] then
            seen[c.id] = true
            out[#out + 1] = c
        end
    end
    -- Built-in chips missing from the saved list (new versions) go at the end, on
    -- (Favorites and To be read: off).
    for _i, id in ipairs(BUILTIN_ORDER) do
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = normalise({ id = id })
        end
    end
    return out
end

function M.enabledList()
    local out = {}
    for _i, c in ipairs(M.list()) do
        if c.enabled then out[#out + 1] = c end
    end
    return out
end

local function countEnabled(list)
    local n = 0
    for _i, c in ipairs(list) do
        if c.enabled then n = n + 1 end
    end
    return n
end

-- True when MAX chips are already on.
function M.isFull()
    return countEnabled(M.list()) >= M.MAX
end

function M.add(path)
    local list = M.list()
    if countEnabled(list) >= M.MAX then return false, "max" end
    local id = "folder:" .. path
    for _i, c in ipairs(list) do
        if c.id == id then return false, "dup" end
    end
    list[#list + 1] = { id = id, path = path, label = labelFor(path), enabled = true, kind = "folder", shelves = true }
    writeSaved(list)
    return true
end

-- A chip for one KOReader collection (not Favorites / To be read: they have
-- chips of their own). The chip takes the collection's name.
function M.addCollection(name)
    local list = M.list()
    if countEnabled(list) >= M.MAX then return false, "max" end
    local id = "collection:" .. name
    for _i, c in ipairs(list) do
        if c.id == id then return false, "dup" end
    end
    list[#list + 1] = { id = id, name = name, label = name, enabled = true, kind = "collection", shelves = true }
    writeSaved(list)
    return true
end

function M.remove(id)
    local list = M.list()
    for i, c in ipairs(list) do
        if c.id == id and (c.kind == "folder" or c.kind == "collection") then
            table.remove(list, i)
            writeSaved(list)
            return true
        end
    end
    return false
end

function M.setEnabled(id, on)
    local list = M.list()
    for _i, c in ipairs(list) do
        if c.id == id then
            if not on and c.enabled and countEnabled(list) <= 1 then
                return false, "last"
            end
            if on and not c.enabled and countEnabled(list) >= M.MAX then
                return false, "max"
            end
            c.enabled = on and true or false
            writeSaved(list)
            return true
        end
    end
    return false
end

function M.shelvesOn(id)
    for _i, c in ipairs(M.list()) do
        if c.id == id then return c.shelves end
    end
    return true
end

function M.setShelves(id, on)
    local list = M.list()
    for _i, c in ipairs(list) do
        if c.id == id then
            c.shelves = on and true or false
            writeSaved(list)
            return true
        end
    end
    return false
end

function M.move(id, dir)
    local list = M.list()
    local idx
    for i, c in ipairs(list) do
        if c.id == id then idx = i; break end
    end
    if not idx then return false end
    local target = idx + dir
    if target < 1 or target > #list then return false end
    list[idx], list[target] = list[target], list[idx]
    writeSaved(list)
    return true
end

-- Folder names directly under `path`, from a list of book files.
-- Books that sit straight in `path` are not counted; only folders are.
function M.subfolders(files, path)
    local prefix = (path == "") and "/" or (path .. "/")
    local seen, names = {}, {}
    for _i, file in ipairs(files or {}) do
        if file:sub(1, #prefix) == prefix then
            local seg = file:sub(#prefix + 1):match("^([^/]+)/")
            if seg and not seen[seg] then
                seen[seg] = true
                names[#names + 1] = seg
            end
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

function M.rootDir()
    local root = G_reader_settings and G_reader_settings:readSetting("home_dir") or ""
    if #root > 1 then root = root:gsub("/+$", "") end
    if root == "/" then root = "" end
    return root
end

-- ── Favorites and To be read inside Collections ────────────────────────────
local function squash(s)
    return (tostring(s):lower():gsub("[^%w]", ""))
end

local TBR_NAMES = { toberead = true, tbr = true }

-- Which special collection `name` is: "favorites", "tbr" (To be read), or nil
-- for any other collection. Favorites is the built-in one (stored as
-- "favorites"); To be read matches "To be read", "to-be-read", "TBR"...
function M.collectionKind(RC, name)
    if type(name) ~= "string" then return nil end
    if name == ((RC and RC.default_collection_name) or "favorites") or name:lower() == "favorites" then
        return "favorites"
    end
    if TBR_NAMES[squash(name)] then return "tbr" end
    return nil
end

-- The key under which KOReader stores that collection, or nil if it has none.
function M.collectionKey(RC, kind)
    if not (RC and type(RC.coll) == "table") then return nil end
    for name in pairs(RC.coll) do
        if M.collectionKind(RC, name) == kind then return name end
    end
    return nil
end

-- Names of the collections that can get a chip, sorted: every KOReader
-- collection except Favorites and To be read.
function M.collectionNames()
    local names = {}
    local ok, rc = pcall(require, "readcollection")
    if not (ok and rc) then return names end
    if not rc.coll and rc._read then pcall(rc._read, rc) end
    for name in pairs(rc.coll or {}) do
        if type(name) == "string" and M.collectionKind(rc, name) == nil then
            names[#names + 1] = name
        end
    end
    table.sort(names, function(a, b) return a:lower() < b:lower() end)
    return names
end

local LIB_SHOWN_KEY = "kikome_library_collections_shown"

local function readLibraryShown()
    local ok, saved = pcall(function() return G_reader_settings:readSetting(LIB_SHOWN_KEY) end)
    return (ok and type(saved) == "table") and saved or {}
end

-- True (the default) when the collection is listed in the Library's Collections tab.
function M.libraryCollectionShown(kind)
    return readLibraryShown()[kind] ~= false
end

function M.setLibraryCollectionShown(kind, on)
    local out = {}
    for k, v in pairs(readLibraryShown()) do out[k] = v end
    out[kind] = on and true or false
    pcall(function() G_reader_settings:saveSetting(LIB_SHOWN_KEY, out) end)
    return true
end

-- True when `name` is Favorites / To be read and its Library toggle is off.
function M.libraryCollectionHidden(RC, name)
    local kind = M.collectionKind(RC, name)
    return kind ~= nil and not M.libraryCollectionShown(kind)
end

local function readShown()
    local ok, saved = pcall(function() return G_reader_settings:readSetting(SHOWN_KEY) end)
    return (ok and type(saved) == "table") and saved or {}
end

-- True (the default) when the collection is listed under Collections.
function M.collectionShown(kind)
    return readShown()[kind] ~= false
end

function M.setCollectionShown(kind, on)
    local out = {}
    for k, v in pairs(readShown()) do out[k] = v end
    out[kind] = on and true or false
    pcall(function() G_reader_settings:saveSetting(SHOWN_KEY, out) end)
    return true
end

-- True when `name` is Favorites / To be read and its toggle is off.
function M.collectionHidden(RC, name)
    local kind = M.collectionKind(RC, name)
    return kind ~= nil and not M.collectionShown(kind)
end

function M.signature()
    local parts = {}
    for _i, c in ipairs(M.list()) do
        parts[#parts + 1] = c.id .. (c.enabled and "+" or "-") .. (c.shelves and "s" or "n")
    end
    parts[#parts + 1] = "c" .. (M.collectionShown("favorites") and "f" or "-")
        .. (M.collectionShown("tbr") and "t" or "-")
    return table.concat(parts, "|")
end

return M
