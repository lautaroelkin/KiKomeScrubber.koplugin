-- kobold/data/plugins.lua — KiKome
-- KOReader plugins (and the file browser's own tools) for custom actions:
-- every entry they put in KOReader's main menu that does something when
-- tapped, and running one of them. Builds no widgets.
--
--   Plugins.list()          every runnable menu entry, sorted by title:
--                           { { module, entry, title }, ... }
--   Plugins.run(module, entry)   runs one; false when it is gone or failed
--   Plugins.state(module, entry) true / false: what the entry toggles is on / off
--                           now (a server running, ...); nil: it has no such state
--
-- A plugin adds its menu entries in addToMainMenu(menu_items). Calling that
-- on an empty table shows what it would add, without touching the real
-- menu; an entry with a callback is something a button can run.
-- (Adapted from Kobold's data/plugins.lua.)

local logger = require("logger")

local KoboldPlugins = {}

-- KOReader's file browser. A book parked under KiKome has none, so it is made
-- now (see park.lua), the same as when an action runs.
local function fileBrowser()
    local ok, Park = pcall(require, "kobold.ui.park")
    if ok and Park and Park.fm then
        local fm = Park.fm()
        if fm then return fm end
    end
    local FileManager = package.loaded["apps/filemanager/filemanager"]
    return FileManager and FileManager.instance
end

-- The entries `module` adds to the main menu: { [key] = item }, or nil.
local function menuEntries(module)
    if type(module) ~= "table" or type(module.addToMainMenu) ~= "function" then return nil end
    local items = {}
    local ok = pcall(module.addToMainMenu, module, items)
    if not ok then return nil end
    return items
end

local function entryTitle(item, fallback)
    local text = item.text
    if not text and type(item.text_func) == "function" then
        local ok, t = pcall(item.text_func)
        if ok then text = t end
    end
    return (type(text) == "string" and text ~= "") and text or fallback
end

-- Every runnable menu entry, sorted by title.
function KoboldPlugins.list()
    local fm = fileBrowser()
    if not fm then return {} end
    local out, seen = {}, {}
    for key, module in pairs(fm) do
        if type(key) == "string" and type(module) == "table" and not seen[module] then
            local entries = menuEntries(module)
            if entries then
                seen[module] = true
                for entry_key, item in pairs(entries) do
                    if type(item) == "table" and type(item.callback) == "function" then
                        out[#out + 1] = {
                            module = key, entry = entry_key,
                            title = entryTitle(item, entry_key),
                        }
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        local ta, tb = a.title:lower(), b.title:lower()
        if ta ~= tb then return ta < tb end
        return (a.module .. a.entry) < (b.module .. b.entry)
    end)
    return out
end

-- Runs menu entry `entry` of the file browser module `module`. Inside a book
-- (`ui` is the reader) the module is looked for there first. False when it is
-- gone (the plugin was turned off or removed) or failed.
function KoboldPlugins.run(module, entry, ui)
    local host = (type(ui) == "table" and type(ui[module]) == "table") and ui[module] or nil
    if not host then
        local fm = fileBrowser()
        host = fm and fm[module]
    end
    local entries = host and menuEntries(host)
    local item = entries and entries[entry]
    if not (item and type(item.callback) == "function") then return false end
    local ok, err = pcall(item.callback)
    if not ok then logger.warn("KiKome: plugin action failed:", module, entry, tostring(err)) end
    return ok
end

-- ── On / off state ─────────────────────────────────────────────────────────
-- A plugin entry that switches something (a file server, a VPN) says whether it is
-- on in two ways: a `checked_func` on its menu entry, or an `isRunning()` /
-- `daemon.status()` on the plugin itself. Neither is needed to run it.
--
-- This is called often (every time a tile is drawn, and again after a tap), so it
-- must never change anything: it does NOT use fileBrowser() above, because that
-- closes a parked book to make the file browser. It looks only at the reader and
-- the file browser that already exist.

-- Plugins that tell whether they run (lowercase key of the plugin). The same ones
-- Zenos asks in its quick settings.
local RUNNING_CHECK = {
    zenfm = true, tailscale = true,
}

-- The file browser servers (FileBrowser, FileBrowser Plus) write a pid file for as
-- long as they run; Zenos reads the same ones. Their own isRunning() is not
-- reliable, so this is what says whether they are on.
local PID_FILES = {
    standard = "/tmp/filebrowser_koreader.pid",
    plus     = "/tmp/filebrowserplus_koreader.pid",
}

local function pidFileOf(module)
    local key = (module:lower():gsub("[^%a%d]", ""))
    if not key:find("filebrowser", 1, true) then return nil end
    return key:find("plus", 1, true) and PID_FILES.plus or PID_FILES.standard
end

local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

local function liveHost(module)
    for _i, name in ipairs({ "apps/reader/readerui", "apps/filemanager/filemanager" }) do
        local mod = package.loaded[name]
        local inst = type(mod) == "table" and mod.instance or nil
        local host = type(inst) == "table" and inst[module] or nil
        if type(host) == "table" then return host end
    end
    -- not in the reader nor the file browser: the plugin loader keeps the ones it loaded
    local loader = package.loaded["pluginloader"]
    local loaded = type(loader) == "table" and loader.loaded_plugins or nil
    local host = type(loaded) == "table" and loaded[module] or nil
    if type(host) == "table" then return host end
    return nil
end

local function isCallable(value)
    if type(value) == "function" then return true end
    local mt = type(value) == "table" and getmetatable(value) or nil
    return type(mt) == "table" and type(mt.__call) == "function"
end

-- true / false from the plugin itself, or nil when it does not say.
local function pluginRunning(host)
    if isCallable(host.isRunning) then
        local ok, value = pcall(host.isRunning, host)
        if ok and type(value) == "boolean" then return value end
    end
    local daemon = host.daemon
    if type(daemon) == "table" and isCallable(daemon.status) then
        local ok, value = pcall(daemon.status, daemon)
        if ok and value ~= nil then return value == true end
    end
    return nil
end

function KoboldPlugins.state(module, entry)
    if type(module) ~= "string" then return nil end

    -- 0. the file browser servers: their pid file (no plugin needed)
    local pid_file = pidFileOf(module)
    if pid_file then return fileExists(pid_file) end

    local host = liveHost(module)
    if not host then return nil end

    -- 1. the plugins that tell whether they run (cheap: no menu is built)
    if RUNNING_CHECK[module:lower()] then
        local running = pluginRunning(host)
        if running ~= nil then return running end
    end

    -- 2. any other plugin: the checkmark of its menu entry
    local entries = menuEntries(host)
    local item = entries and entries[entry]
    if type(item) ~= "table" then return nil end
    if isCallable(item.checked_func) then
        local ok, value = pcall(item.checked_func)
        if ok and value ~= nil then return value and true or false end
    elseif type(item.checked) == "boolean" then
        return item.checked
    end
    return nil
end

-- The same, for a KOReader action (a gesture) that a plugin registers, told by the
-- name of its event ("ToggleFilebrowserPlusServer", "ToggleZenFM", ...) or its id.
-- true / false; nil when it is not one of the plugins that say whether they run.
function KoboldPlugins.stateOfEvent(event, id)
    for _i, raw in ipairs({ tostring(event or ""), tostring(id or "") }) do
        local key = raw:lower():gsub("[^%a%d]", "")
        if key:find("filebrowser", 1, true) then
            return KoboldPlugins.state(key, nil)
        elseif key:find("zenfm", 1, true) then
            return KoboldPlugins.state("zenfm", nil)
        elseif key:find("tailscale", 1, true) then
            return KoboldPlugins.state("tailscale", nil)
        end
    end
    return nil
end

return KoboldPlugins
