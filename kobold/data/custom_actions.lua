-- kobold/data/custom_actions.lua — KiKome
-- The reader's own actions: a name, an icon and what they run. Builds no
-- widgets. Kept in KOReader's settings file, so they survive updates of the
-- plugin.
--
-- There is one library (list): every action exists once, here. The places
-- that show actions (a "surface": the Actions chip of Home, "actions"; the
-- Action center, "center") keep no copies. Each only remembers an order of
-- ids and which of them are off there. An action made later is on by default.
--
--   CustomActions.list()          the library: every action, in the order they were made
--   CustomActions.get(id)         one action, or nil
--   CustomActions.save(c)         adds `c` (no id yet) or replaces it (same id,
--                                 same place); returns its id
--   CustomActions.delete(id)      also takes it out of every surface
--   CustomActions.run(id, ui)     runs it (ui: the reader, from inside a book); false when it could not run
--   CustomActions.state(c)        true / false: what it toggles is on / off now; nil: no such state
--   CustomActions.describe(c)     "KOReader action · Toggle night mode"
--
--   CustomActions.surfaceList(surface)
--                                 every action of the library in the order of that
--                                 surface: { { action = c, enabled = bool }, ... }
--   CustomActions.isShown(surface, id) / setShown(surface, id, on)
--   CustomActions.shownCount(surface)   how many are on there
--   CustomActions.moveIn(surface, id, dir, visible_only)
--                                 dir = -1 (earlier) or 1 (later). With visible_only
--                                 it swaps with the next one that is on (what a tile
--                                 shows); without it, with the next one in the list.
--   CustomActions.forChip(chip)   the actions a chip shows: for the Actions chip the
--                                 ones that are on in "actions", in that order. An
--                                 action can also carry chips = { [chip_id] = true }
--                                 so other chips can list it (nothing sets that yet).
--   CustomActions.addTileHidden() / setAddTileHidden(on)
--                                 whether the "+" tile at the end of the Actions chip
--                                 is hidden (the More menu of Home turns it on and off)
--   CustomActions.signature()     a string that changes when the actions, or what the
--                                 Actions chip shows of them, change
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

-- ── Surfaces ───────────────────────────────────────────────────────────────
-- Saved as saved.surfaces[surface] = { order = { id, ... }, off = { [id] = true } }.
-- Nothing saved yet means: library order, everything on (so the Actions chip
-- of Home looks as it always did).
-- The Action center is one surface with two faces: "center" (when it opens on Home)
-- and "center_docs" (when it opens inside a book). They share the order; each has
-- its own set of actions that are off (off, off_docs).
local HOME = "actions"

local function splitSurface(surface)
    local base = tostring(surface):match("^(.+)_docs$")
    if base then return base, true end
    return surface, false
end

local function surfaceState(surface)
    local base, docs = splitSurface(surface)
    local surfaces = readSaved().surfaces
    local s = type(surfaces) == "table" and surfaces[base] or nil
    if type(s) ~= "table" then return {}, {} end
    local off = docs and s.off_docs or s.off
    return type(s.order) == "table" and s.order or {}, type(off) == "table" and off or {}
end

function CustomActions.surfaceList(surface)
    local library = CustomActions.list()
    local by_id = {}
    for _i, c in ipairs(library) do by_id[c.id] = c end
    local order, off = surfaceState(surface)
    local out, seen = {}, {}
    -- the saved order first (ids that are gone are skipped) ...
    for _i, id in ipairs(order) do
        local c = by_id[id]
        if c and not seen[id] then
            seen[id] = true
            out[#out + 1] = { action = c, enabled = not off[id] }
        end
    end
    -- ... then the actions made since, at the end
    for _i, c in ipairs(library) do
        if not seen[c.id] then
            seen[c.id] = true
            out[#out + 1] = { action = c, enabled = not off[c.id] }
        end
    end
    return out
end

local function storeSurface(surface, entries)
    local saved = readSaved()
    if type(saved.surfaces) ~= "table" then saved.surfaces = {} end
    local base, docs = splitSurface(surface)
    local order, off = {}, {}
    for _i, e in ipairs(entries) do
        order[#order + 1] = e.action.id
        if not e.enabled then off[e.action.id] = true end
    end
    local st = saved.surfaces[base]
    if docs then
        -- only the set of actions that are off inside a book changes; the order is the other face's
        if type(st) ~= "table" then st = { order = order, off = {} } end
        st.off_docs = off
        saved.surfaces[base] = st
    else
        saved.surfaces[base] = {
            order = order, off = off,
            off_docs = (type(st) == "table" and type(st.off_docs) == "table") and st.off_docs or nil,
        }
    end
    writeSaved(saved)
end

function CustomActions.isShown(surface, id)
    for _i, e in ipairs(CustomActions.surfaceList(surface)) do
        if e.action.id == id then return e.enabled end
    end
    return false
end

function CustomActions.setShown(surface, id, on)
    local entries = CustomActions.surfaceList(surface)
    for _i, e in ipairs(entries) do
        if e.action.id == id then
            if e.enabled == (on and true or false) then return true end
            e.enabled = on and true or false
            storeSurface(surface, entries)
            return true
        end
    end
    return false
end

function CustomActions.shownCount(surface)
    local n = 0
    for _i, e in ipairs(CustomActions.surfaceList(surface)) do
        if e.enabled then n = n + 1 end
    end
    return n
end

function CustomActions.moveIn(surface, id, dir, visible_only)
    local entries = CustomActions.surfaceList(surface)
    local idx
    for i, e in ipairs(entries) do
        if e.action.id == id then idx = i; break end
    end
    if not idx then return false end
    local target = idx + dir
    if visible_only then
        while entries[target] and not entries[target].enabled do target = target + dir end
    end
    if not entries[target] then return false end
    entries[idx], entries[target] = entries[target], entries[idx]
    storeSurface(surface, entries)
    return true
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
    if not found then return false end
    store(list)
    -- ... and out of every surface that remembered it
    local saved = readSaved()
    if type(saved.surfaces) == "table" then
        for _name, s in pairs(saved.surfaces) do
            if type(s) == "table" then
                if type(s.order) == "table" then
                    for i = #s.order, 1, -1 do
                        if s.order[i] == id then table.remove(s.order, i) end
                    end
                end
                if type(s.off) == "table" then s.off[id] = nil end
                if type(s.off_docs) == "table" then s.off_docs[id] = nil end
            end
        end
        writeSaved(saved)
    end
    return true
end

-- Whether what an action toggles is on now (true / false), or nil when it has no
-- on / off state. A KOReader action knows it for night mode, the frontlight,
-- Wi-Fi and the accelerometer; a plugin entry when the plugin says it (a file
-- server that is running, ...). See data/plugins.lua.
function CustomActions.state(c)
    if type(c) ~= "table" then return nil end
    if c.kind == "action" then
        return require("kobold.ui.actions").state(c.action)
    elseif c.kind == "plugin" then
        return require("kobold.data.plugins").state(c.module, c.entry)
    end
    return nil
end

-- `ui` (optional): the reader, when the action is run from inside a book.
function CustomActions.run(id, ui)
    local c = CustomActions.get(id)
    if not c then return false end
    if c.kind == "action" then
        return require("kobold.ui.actions").run(c.action, ui)
    end
    local ok = require("kobold.data.plugins").run(c.module, c.entry, ui)
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
    if chip_id == HOME then
        local shown = {}
        for _i, e in ipairs(CustomActions.surfaceList(HOME)) do
            if e.enabled then shown[#shown + 1] = e.action end
        end
        return shown
    end
    local all = CustomActions.list()
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
    for _i, e in ipairs(CustomActions.surfaceList(HOME)) do
        local c = e.action
        parts[#parts + 1] = c.id .. (e.enabled and "+" or "-") .. ":" .. c.name .. ":" .. (c.icon or "")
    end
    return table.concat(parts, "|")
end

return CustomActions
