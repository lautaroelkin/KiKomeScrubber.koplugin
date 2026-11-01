-- kobold/ui/view_sheet.lua — KiKome
-- The Adjust sheet of Home and Library, the same on both: View (Grid / List),
-- then a Sort & Filter section with Status (Reading / Unread / Finished / On hold), Sort (Recent, Oldest, Newest added, Oldest added) and, side by
-- side, Alphabetical (A-Z / Z-A) and Language (only when the library has more
-- than one). Every part is optional: pass only what the screen has.
--
--   ViewSheet.show{
--       layout = { selected = "grid", on_pick = function(id) end },
--       status = { selected = nil,    on_pick = function(id) end },  -- id or nil
--       sort   = { selected = nil,    on_pick = function(id) end },  -- id or nil
--       alpha  = { selected = nil,    on_pick = function(id) end, toggle = true },
--       lang   = { list = { "EN", "ES" }, selected = nil, on_pick = function(id) end },
--   }
--
-- status, sort, alpha and lang are toggles: tapping the chosen one again clears
-- it (on_pick gets nil). With no status chosen, every book shows.

local OptionSheet = require("kobold.ui.option_sheet")

local ViewSheet = {}

local STATUS = {
    { id = "reading",  label = "Reading" },
    { id = "unread",   label = "Unread" },
    { id = "finished", label = "Finished" },
    { id = "onhold",   label = "On hold" },
}

local SORT = {
    { id = "recent",       label = "Recent" },
    { id = "oldest",       label = "Oldest" },
    { id = "added_newest", label = "Newest added" },
    { id = "added_oldest", label = "Oldest added" },
}

local ALPHA = {
    { id = "az", label = "A-Z" },
    { id = "za", label = "Z-A" },
}

function ViewSheet.show(o)
    local rows = {}
    if o.layout then
        rows[#rows + 1] = {
            options = {
                { id = "grid", label = "Grid", icon = "grid" },
                { id = "list", label = "List", icon = "list" },
            },
            selected = o.layout.selected,
            on_pick = o.layout.on_pick,
        }
    end
    -- With a View part, Sort & Filter is a second section under it; on its own
    -- it is the sheet's title (no empty "View" above it).
    if o.layout and (o.status or o.sort or o.alpha or o.lang) then
        rows[#rows + 1] = { heading = "Sort & Filter" }
    end
    if o.status then
        rows[#rows + 1] = {
            label = "Status", options = STATUS,
            selected = o.status.selected, toggle = true, on_pick = o.status.on_pick,
        }
    end
    if o.sort then
        rows[#rows + 1] = {
            label = "Sort", options = SORT,
            selected = o.sort.selected, toggle = true, on_pick = o.sort.on_pick,
        }
    end
    local cols = {}
    if o.alpha then
        cols[#cols + 1] = {
            label = "Alphabetical", options = ALPHA,
            selected = o.alpha.selected, toggle = o.alpha.toggle ~= false,
            on_pick = o.alpha.on_pick,
        }
    end
    if o.lang then
        local list = {}
        local has_selected = false
        for _i, code in ipairs(o.lang.list or {}) do
            list[#list + 1] = { id = code, label = code }
            if code == o.lang.selected then has_selected = true end
        end
        -- A language that is chosen stays on the sheet, so it can be cleared.
        if o.lang.selected and not has_selected then
            list[#list + 1] = { id = o.lang.selected, label = o.lang.selected }
        end
        if #list > 1 or o.lang.selected then
            cols[#cols + 1] = {
                label = "Language", options = list,
                selected = o.lang.selected, toggle = true, on_pick = o.lang.on_pick,
            }
        end
    end
    if #cols > 0 then rows[#rows + 1] = { cols = cols } end
    return OptionSheet.show{ title = o.layout and "View" or "Sort & Filter", rows = rows }
end

return ViewSheet
