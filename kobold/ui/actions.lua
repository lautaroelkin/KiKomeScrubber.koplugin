-- kobold/ui/actions.lua — Kobold
-- KOReader actions (the ones gestures and profiles can run, including those
-- other plugins register) for Kobold's tap targets: listing them for a
-- picker, and running one by id.

local Event           = require("ui/event")
local UIManager       = require("ui/uimanager")
local _               = require("kobold.i18n")

local KoboldActions = {}

-- KOReader keeps its action table private inside the dispatcher module. Its
-- registerAction function closes over it, so it is read from there. Returns
-- the table, or nil when this KOReader build is laid out differently.
local function actionTable()
    local ok, Dispatcher = pcall(require, "dispatcher")
    if not ok or not Dispatcher or not Dispatcher.registerAction then return nil end
    pcall(function() Dispatcher:init() end)
    local i = 1
    while true do
        local name, value = debug.getupvalue(Dispatcher.registerAction, i)
        if not name then return nil end
        if name == "settingsList" and type(value) == "table" then return value end
        i = i + 1
    end
end

-- A runnable action: a plain event with no value to choose.
local function isSimple(def)
    return type(def) == "table" and def.title and def.event and def.category == "none"
        and (def.condition == nil or def.condition == true)
end

-- Every simple action, sorted by title: { { id, title }, ... }.
function KoboldActions.list()
    local out = {}
    for id, def in pairs(actionTable() or {}) do
        if isSimple(def) then out[#out + 1] = { id = id, title = tostring(def.title) } end
    end
    table.sort(out, function(a, b) return a.title:lower() < b.title:lower() end)
    return out
end

-- Title of action `id`, or the id itself when it is not registered.
function KoboldActions.title(id)
    local def = (actionTable() or {})[id]
    return def and def.title and tostring(def.title) or tostring(id)
end

-- ── On / off state ─────────────────────────────────────────────────────────
-- Some actions toggle something: night mode, the frontlight, Wi-Fi, the
-- accelerometer. They are told by the event they send; each has a function
-- that says whether the thing is on now. An action that is not here has no
-- state (it just does something), unless a plugin says it has one (see state()).
local STATE = {
    ToggleNightMode = function()
        return G_reader_settings:isTrue("night_mode")
    end,
    ToggleFrontlight = function()
        local Device = require("device")
        local powerd = Device:getPowerDevice()
        if powerd and type(powerd.isFrontlightOn) == "function" then return powerd:isFrontlightOn() end
        if powerd and type(powerd.frontlightIntensity) == "function" then
            return (tonumber(powerd:frontlightIntensity()) or 0) > 0
        end
    end,
    ToggleGSensor = function()
        return G_reader_settings:nilOrFalse("input_ignore_gsensor")
    end,
    ToggleWifi = function()
        return require("ui/network/manager"):isWifiOn()
    end,
}

-- Whether the thing action `id` toggles is on now: true or false; nil when the
-- action has no on / off state.
function KoboldActions.state(id)
    local def = (actionTable() or {})[id]
    if not (def and def.event) then return nil end
    local fn = STATE[def.event]
    if fn then
        local ok, value = pcall(fn)
        if ok and value ~= nil then return value and true or false end
        return nil
    end
    -- Toggles that plugins add (FileBrowser Plus, ZenFM, ...): see data/plugins.lua
    local ok, value = pcall(function()
        return require("kobold.data.plugins").stateOfEvent(def.event, id)
    end)
    if ok and value ~= nil then return value and true or false end
    return nil
end

-- Runs action `id`. Its event goes to `ui` (the reader, when it is run from
-- inside a book) or else to the file manager, which passes it to KOReader's
-- modules and plugins (statistics, cloud storage, ...). Sending it through
-- UIManager would hand it to the top widget, a Kobold screen, which does not
-- handle it. Anything it opens shows above Kobold.
function KoboldActions.run(id, ui)
    local def = (actionTable() or {})[id]
    -- A book parked under KiKome has no file browser: it is made now.
    local fm = isSimple(def) and (ui or require("kobold.ui.park").fm()) or nil
    if not (isSimple(def) and fm) then
        require("kobold.ui.toast").error(_("This action is not available: ") .. tostring(id))
        return false
    end
    local ok, err = pcall(function() fm:handleEvent(Event:new(def.event, def.arg)) end)
    if not ok then
        require("kobold.ui.toast").error(_("The action failed: ") .. tostring(err))
    end
    return ok
end

return KoboldActions
