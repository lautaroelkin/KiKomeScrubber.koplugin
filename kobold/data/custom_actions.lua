-- kobold/data/custom_actions.lua — KiKome
-- The reader's own actions: a name, an icon and what they run, shown as tiles
-- in the Actions chip of Home. Builds no widgets. Kept in KOReader's settings
-- file, so they survive updates of the plugin.
--
--   CustomActions.list()          every action, in order
--   CustomActions.get(id)         one action, or nil
--   CustomActions.save(c)         adds `c` (no id yet) or replaces it (same id,
--                                 same place); returns its id
--   CustomActions.delete(id)
--   CustomActions.move(id, dir)   dir = -1 (earlier) or 1 (later)
--   CustomActions.run(id)         runs it; false when it could not run
--   CustomActions.describe(c)     "KOReader action · Toggle night mode"
--   CustomActions.forChip(chip)   the actions a chip shows. Today only the
--                                 Actions chip has them; an action can also carry
--                                 chips = { [chip_id] = true } so other chips can
--                                 list it later (nothing sets that yet).
--   CustomActions.addTileHidden() / setAddTileHidden(on)
--                                 whether the "+" tile at the end of the Actions chip
--                                 is hidden (the More menu of Home turns it on and off)
--   CustomActions.signature()     a string that changes when the actions change
--
-- An action is a table:
--   { id = "act:3", name = "Night mode", icon = "/path/to/icon.svg" | "kobold:moon" | nil,
--     kind = "action",  action = <KOReader action id>
--       or kind = "plugin", module = <file browser key>, entry = <menu key>,
--     target = "Toggle night mode"   -- the title of what it runs, for display
--   }
-- The icon is a file (svg or png) or "kobold:<name>" for one of the plugin's own
-- (see ui/action_icon.lua, which draws it). nil draws the default icon.

local _ = require("kobold.i18n")

local CustomActions = {}

local KEY = "kikome_custom_actions"

local function readSaved()
    local ok, saved = pcall(function() return G_reader_settings:readSetting(KEY) end)
    if ok and type(saved) == "table" then return saved end
    return {}
end

local function writeSaved(saved)
    pcall(function() G_reader_settings:saveSetting(KEY, saved) end)
end

local function text(v)
    return (type(v) == "string" and v ~= "") and v or nil
end

-- A clean copy of a saved entry, or nil when it is not usable.
local function normalise(e)
    if type(e) ~= "table" then return nil end
    local id, name = text(e.id), text(e.name)
    if not (id and name) then return nil end
    local c = { id = id, name = name, icon = text(e.icon), target = text(e.target), chips = e.chips }
    if e.kind == "plugin" then
        c.kind, c.module, c.entry = "plugin", text(e.module), text(e.entry)
        if not (c.module and c.entry) then return nil end
    else
        c.kind, c.action = "action", text(e.action)
        if not c.action then return nil end
    end
    return c
end

function CustomActions.list()
    local out, seen = {}, {}
    for _i, e in ipairs(readSaved().list or {}) do
        local c = normalise(e)
        if c and not seen[c.id] then
            seen[c.id] = true
            out[#out + 1] = c
        end
    end
    return out
end

function CustomActions.get(id)
    for _i, c in ipairs(CustomActions.list()) do
        if c.id == id then return c end
    end
    return nil
end

local function store(list, next_id)
    local saved = readSaved()
    saved.list = list
    if next_id then saved.next = next_id end
    writeSaved(saved)
end

function CustomActions.save(c)
    local clean = normalise({
        id = c.id or "act:new", name = c.name, icon = c.icon, kind = c.kind,
        action = c.action, module = c.module, entry = c.entry, target = c.target,
        chips = c.chips,
    })
    if not clean then return nil end
    local list = CustomActions.list()
    if c.id then
        for i, old in ipairs(list) do
            if old.id == c.id then
                list[i] = clean
                store(list)
                return clean.id
            end
        end
        -- an id that is not there (deleted meanwhile): it goes at the end
        list[#list + 1] = clean
        store(list)
        return clean.id
    end
    local n = tonumber(readSaved().next) or 1
    -- never reuse an id still in the list
    local taken = {}
    for _i, old in ipairs(list) do taken[old.id] = true end
    while taken["act:" .. n] do n = n + 1 end
    clean.id = "act:" .. n
    list[#list + 1] = clean
    store(list, n + 1)
    return clean.id
end

function CustomActions.delete(id)
    local list, found = {}, false
    for _i, c in ipairs(CustomActions.list()) do
        if c.id == id then found = true else list[#list + 1] = c end
    end
    if found then store(list) end
    return found
end

function CustomActions.move(id, dir)
    local list = CustomActions.list()
    local idx
    for i, c in ipairs(list) do
        if c.id == id then idx = i; break end
    end
    if not idx then return false end
    local target = idx + dir
    if target < 1 or target > #list then return false end
    list[idx], list[target] = list[target], list[idx]
    store(list)
    return true
end

function CustomActions.run(id)
    local c = CustomActions.get(id)
    if not c then return false end
    if c.kind == "action" then
        return require("kobold.ui.actions").run(c.action)
    end
    local ok = require("kobold.data.plugins").run(c.module, c.entry)
    if not ok then
        require("kobold.ui.toast").error(
            string.format(_("%s is not available. The plugin may be turned off."), c.name))
    end
    return ok
end

-- What an action runs, in words: the kind and the title.
function CustomActions.describe(c)
    local kind = (c.kind == "plugin") and _("Plugin") or _("KOReader action")
    local target = c.target
    if not target and c.kind == "action" then
        target = require("kobold.ui.actions").title(c.action)
    end
    if target and target ~= "" then return kind .. " \u{00B7} " .. target end
    return kind
end

-- The actions that chip `chip_id` lists.
function CustomActions.forChip(chip_id)
    local all = CustomActions.list()
    if chip_id == "actions" then return all end
    local out = {}
    for _i, c in ipairs(all) do
        if type(c.chips) == "table" and c.chips[chip_id] then out[#out + 1] = c end
    end
    return out
end

function CustomActions.addTileHidden()
    return readSaved().hide_add == true
end

function CustomActions.setAddTileHidden(on)
    local saved = readSaved()
    saved.hide_add = on and true or nil
    writeSaved(saved)
end

function CustomActions.signature()
    local parts = {}
    for _i, c in ipairs(CustomActions.list()) do
        parts[#parts + 1] = c.id .. ":" .. c.name .. ":" .. (c.icon or "")
    end
    return table.concat(parts, "|")
end

return CustomActions
