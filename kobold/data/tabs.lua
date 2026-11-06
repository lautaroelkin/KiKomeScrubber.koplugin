-- kobold/data/tabs.lua — KiKome
-- The tabs along the top of the Library (My Books): their order and which are
-- on. Stored in G_reader_settings, so the Library (mybooks.lua) and
-- Settings > Library options > Tabs read the same list.
--
--   Tabs.list()           every tab, in order (on and off): { id, label, enabled }
--   Tabs.enabledList()    the tabs on, in order
--   Tabs.isEnabled(id)
--   Tabs.setEnabled(id, on)   false, "last" when it would leave no tab on
--   Tabs.move(id, dir)    dir = -1 (up) or 1 (down)
--   Tabs.first()          id of the first tab that is on
--   Tabs.signature()      a string that changes when the tabs change

local _ = require("kobold.i18n")

local M = {}

local KEY = "kikome_library_tabs"

-- The tabs and their names. Their order here is the order they start in.
local ORDER = { "books", "authors", "series", "collections", "genres", "files" }
local function labelOf(id)
    if id == "books" then return _("Books") end
    if id == "authors" then return _("Authors") end
    if id == "series" then return _("Series") end
    if id == "collections" then return _("Collections") end
    if id == "genres" then return _("Genres") end
    if id == "files" then return _("Files") end
end

local function readSaved()
    local ok, saved = pcall(function() return G_reader_settings:readSetting(KEY) end)
    return (ok and type(saved) == "table") and saved or {}
end

local function writeSaved(list)
    local out = {}
    for _i, t in ipairs(list) do out[#out + 1] = { id = t.id, enabled = t.enabled } end
    pcall(function() G_reader_settings:saveSetting(KEY, out) end)
    -- The Library is told something changed (it checks this when it is painted).
    local ok, Prefs = pcall(require, "kobold.data.prefs")
    if ok and Prefs and Prefs.touch then Prefs.touch() end
end

function M.list()
    local out, seen = {}, {}
    for _i, e in ipairs(readSaved()) do
        if type(e) == "table" and type(e.id) == "string" and labelOf(e.id) and not seen[e.id] then
            seen[e.id] = true
            out[#out + 1] = { id = e.id, label = labelOf(e.id), enabled = (e.enabled ~= false) }
        end
    end
    -- Tabs missing from the saved list (a new version, or nothing saved yet)
    -- go in their own order, on.
    for _i, id in ipairs(ORDER) do
        if not seen[id] then
            seen[id] = true
            out[#out + 1] = { id = id, label = labelOf(id), enabled = true }
        end
    end
    return out
end

function M.enabledList()
    local out = {}
    for _i, t in ipairs(M.list()) do
        if t.enabled then out[#out + 1] = t end
    end
    return out
end

function M.isEnabled(id)
    for _i, t in ipairs(M.list()) do
        if t.id == id then return t.enabled end
    end
    return false
end

function M.first()
    local on = M.enabledList()
    return on[1] and on[1].id or "books"
end

local function countEnabled(list)
    local n = 0
    for _i, t in ipairs(list) do
        if t.enabled then n = n + 1 end
    end
    return n
end

function M.setEnabled(id, on)
    local list = M.list()
    for _i, t in ipairs(list) do
        if t.id == id then
            if not on and t.enabled and countEnabled(list) <= 1 then
                return false, "last"
            end
            t.enabled = on and true or false
            writeSaved(list)
            return true
        end
    end
    return false
end

function M.move(id, dir)
    local list = M.list()
    local idx
    for i, t in ipairs(list) do
        if t.id == id then idx = i; break end
    end
    if not idx then return false end
    local target = idx + dir
    if target < 1 or target > #list then return false end
    list[idx], list[target] = list[target], list[idx]
    writeSaved(list)
    return true
end

function M.signature()
    local parts = {}
    for _i, t in ipairs(M.list()) do
        parts[#parts + 1] = t.id .. (t.enabled and "+" or "-")
    end
    return table.concat(parts, "|")
end

return M
