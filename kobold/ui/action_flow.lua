-- kobold/ui/action_flow.lua — KiKome
-- The screens for making and changing custom actions (data/custom_actions.lua),
-- all in KiKome's own pickers: a sheet for the kind, the list picker for what
-- it runs, the rename prompt (with KiKome's keyboard) for the name and the icon
-- picker (icon_picker.lua) for the icon. Every function calls `on_change` once
-- something was saved, so whoever shows the actions can draw them again.
--
--   Flow.add(on_change)                 new action: what it runs, name, icon
--   Flow.rename(c, on_change)
--   Flow.changeIcon(c, on_change)
--   Flow.changeTarget(c, on_change)     what it runs
--   Flow.confirmDelete(c, on_change)
--   Flow.menu{ screen, anchor, align, action = c, on_change }
--                                        the small menu of holding a tile (on the
--                                        Actions chip of Home)
--
-- `c` is an action as CustomActions.list() gives it.

local UIManager     = require("ui/uimanager")
local _             = require("kobold.i18n")
local CustomActions = require("kobold.data.custom_actions")
local IconPicker    = require("kobold.ui.icon_picker")
local ListPicker    = require("kobold.ui.list_picker")
local OptionSheet   = require("kobold.ui.option_sheet")
local RenamePrompt  = require("kobold.ui.rename_prompt")
local Toast         = require("kobold.ui.toast")

local Flow = {}

local function call(fn, ...) if fn then fn(...) end end

-- The next screen opens a moment after the one before it closed.
local function later(fn) UIManager:nextTick(fn) end

-- ── What it runs ───────────────────────────────────────────────────────────
-- The choices of one kind, as { id, title, sub, target } for the list picker.
local function targetChoices(kind)
    local out = {}
    if kind == "action" then
        for _i, a in ipairs(require("kobold.ui.actions").list()) do
            out[#out + 1] = {
                id = a.id, title = a.title, sub = a.id,
                target = { kind = "action", action = a.id, title = a.title },
            }
        end
    else
        for _i, e in ipairs(require("kobold.data.plugins").list()) do
            out[#out + 1] = {
                id = e.module .. "\0" .. e.entry, title = e.title, sub = e.module,
                target = { kind = "plugin", module = e.module, entry = e.entry, title = e.title },
            }
        end
    end
    return out
end

-- The id `c` has among the choices of its kind (to start with it ticked).
local function currentChoiceId(c, kind)
    if not c or c.kind ~= kind then return nil end
    if kind == "action" then return c.action end
    return c.module .. "\0" .. c.entry
end

-- A full-screen list of every KOReader action, or every plugin entry.
-- on_pick(target) runs once "Next" is tapped.
local function pickFrom(kind, c, on_pick)
    local choices = targetChoices(kind)
    local by_id = {}
    for _i, ch in ipairs(choices) do by_id[ch.id] = ch end
    ListPicker.show{
        title = (kind == "action") and _("KOReader action") or _("Plugin"),
        action_label = _("Next"),
        empty_text = (kind == "action") and _("No KOReader actions were found.")
            or _("No plugins with menu entries were found."),
        state = { picked = currentChoiceId(c, kind) },
        rows = function(picker)
            local rows = {}
            for _i, ch in ipairs(choices) do
                rows[#rows + 1] = {
                    id = ch.id, text = ch.title, sub = ch.sub,
                    icon = (kind == "action") and "play" or "package",
                    marker = "tick", selected = (picker.state.picked == ch.id),
                }
            end
            return rows
        end,
        can_finish = function(picker) return picker.state.picked ~= nil end,
        on_tap = function(row, picker)
            -- one at a time: tapping it again lets it go
            picker.state.picked = (picker.state.picked ~= row.id) and row.id or nil
            picker:reload()
        end,
        on_finish = function(picker)
            local ch = by_id[picker.state.picked]
            if ch then later(function() on_pick(ch.target) end) end
        end,
    }
end

-- Step 1: KOReader action or plugin, then the list of that kind.
local function chooseTarget(c, on_pick)
    OptionSheet.show{
        title = _("What should it run?"),
        rows = {
            {
                options = {
                    { id = "action", label = _("KOReader action"), icon = "play" },
                    { id = "plugin", label = _("Plugin"), icon = "package" },
                },
                close = true,
                on_pick = function(kind)
                    later(function() pickFrom(kind, c, on_pick) end)
                end,
            },
        },
    }
end

-- ── Name and icon ──────────────────────────────────────────────────────────
local function askName(default, save_text, on_save)
    RenamePrompt.show{
        title = _("Action name"), text = default or "", placeholder = _("Name"),
        save_text = save_text, allow_unchanged = true, on_save = on_save,
    }
end

local function askIcon(current, none_label, on_finish)
    IconPicker.show{
        title = _("Choose an icon"), action_label = _("Use icon"),
        none_label = none_label, current = current, on_finish = on_finish,
    }
end

local function saved(c, message, on_change)
    if CustomActions.save(c) then
        if message then Toast.show(message) end
    else
        Toast.error(_("The action could not be saved."))
    end
    call(on_change)
end

-- ── The flows ──────────────────────────────────────────────────────────────
function Flow.add(on_change)
    chooseTarget(nil, function(target)
        askName(target.title, _("Next"), function(name)
            later(function()
                askIcon(nil, _("Skip"), function(spec)
                    saved({
                        name = name, icon = spec, kind = target.kind, action = target.action,
                        module = target.module, entry = target.entry, target = target.title,
                    }, _("Action added."), on_change)
                end)
            end)
        end)
    end)
end

function Flow.rename(c, on_change)
    askName(c.name, _("Save"), function(name)
        c.name = name
        saved(c, nil, on_change)
    end)
end

function Flow.changeIcon(c, on_change)
    askIcon(c.icon, _("Default icon"), function(spec)
        c.icon = spec
        saved(c, nil, on_change)
    end)
end

function Flow.changeTarget(c, on_change)
    chooseTarget(c, function(target)
        c.kind, c.action = target.kind, target.action
        c.module, c.entry, c.target = target.module, target.entry, target.title
        saved(c, _("Action updated."), on_change)
    end)
end

function Flow.confirmDelete(c, on_change)
    require("kobold.ui.confirm_sheet").show{
        title = _("Delete this action?"),
        message = c.name .. "\n" .. _("It is deleted for good. What it runs is not changed."),
        confirm_text = _("Delete"),
        on_confirm = function()
            CustomActions.delete(c.id)
            call(on_change)
        end,
    }
end

-- The small menu of holding a tile: Rename, Change icon, Change what it runs,
-- Move earlier / later (among the tiles Home shows), Hide from Home (the action
-- stays in Settings > Actions) and Delete.
function Flow.menu(o)
    local c, on_change = o.action, o.on_change
    local idx, count = nil, 0
    for i, a in ipairs(CustomActions.forChip("actions")) do
        count = i
        if a.id == c.id then idx = i end
    end
    local items = {
        { text = _("Rename"), icon = "pencil", action = function() Flow.rename(c, on_change) end },
        { text = _("Change icon"), icon = "image", action = function() Flow.changeIcon(c, on_change) end },
        { text = _("Change what it runs"), icon = "settings-2",
          action = function() Flow.changeTarget(c, on_change) end },
    }
    if idx and idx > 1 then
        items[#items + 1] = { text = _("Move earlier"), icon = "chevron-left",
            action = function() CustomActions.moveIn("actions", c.id, -1, true); call(on_change) end }
    end
    if idx and idx < count then
        items[#items + 1] = { text = _("Move later"), icon = "chevron-right",
            action = function() CustomActions.moveIn("actions", c.id, 1, true); call(on_change) end }
    end
    items[#items + 1] = { text = _("Hide from Home"), icon = { "square-minus", "minus" },
        action = function() CustomActions.setShown("actions", c.id, false); call(on_change) end }
    items[#items + 1] = { text = _("Delete"), icon = "trash-2",
        action = function() Flow.confirmDelete(c, on_change) end }
    require("kobold.ui.book_menu").show{
        screen = o.screen, anchor = o.anchor, align = o.align or "right", items = items,
    }
end

return Flow
