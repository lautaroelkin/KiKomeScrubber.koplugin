-- kobold/data/clipboard.lua — Kobold
-- Selection and clipboard state for file operations (copy / move). Pure data,
-- no UI. Lives for the whole session, so the clipboard survives while the
-- screens come and go; the selection is cleared when a screen starts.
--
--   selection  the books ticked in selection mode (kept in tap order)
--   board      what Copy / Move put aside: { paths = {...}, mode = "copy" | "cut" }

local Clipboard = {}

local sel = { active = false, order = {}, set = {} }
local board = nil

-- Selection ------------------------------------------------------------

function Clipboard.isSelecting() return sel.active end

function Clipboard.enterSelect() sel.active = true end

function Clipboard.exitSelect()
    sel.active = false
    sel.order = {}
    sel.set = {}
end

function Clipboard.isSelected(path) return sel.set[path] == true end

function Clipboard.count() return #sel.order end

function Clipboard.add(path)
    if sel.set[path] then return end
    sel.set[path] = true
    sel.order[#sel.order + 1] = path
end

function Clipboard.remove(path)
    if not sel.set[path] then return end
    sel.set[path] = nil
    local kept = {}
    for _i, p in ipairs(sel.order) do
        if p ~= path then kept[#kept + 1] = p end
    end
    sel.order = kept
end

-- Flips one path; returns true when it is selected afterwards.
function Clipboard.toggle(path)
    if sel.set[path] then
        Clipboard.remove(path)
        return false
    end
    Clipboard.add(path)
    return true
end

-- A copy of the selected paths, in the order they were ticked.
function Clipboard.selected()
    local out = {}
    for i, p in ipairs(sel.order) do out[i] = p end
    return out
end

-- Clipboard ------------------------------------------------------------

-- Puts `paths` aside for a later paste. mode: "copy" or "cut" (move).
function Clipboard.put(paths, mode)
    local copy = {}
    for i, p in ipairs(paths) do copy[i] = p end
    board = { paths = copy, mode = mode }
end

function Clipboard.board() return board end

function Clipboard.hasBoard() return board ~= nil and #board.paths > 0 end

function Clipboard.clear() board = nil end

return Clipboard
