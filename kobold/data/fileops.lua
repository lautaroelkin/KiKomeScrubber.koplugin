-- kobold/data/fileops.lua — Kobold
-- Copy and move books between folders. No UI: the screens ask for a plan,
-- show it, then run it. Adapted from the move engine of the Bookshelf plugin
-- (AGPL-3.0, like KOReader): a moved book takes its sidecar folder, reading
-- history, collections and cached cover along; a copy gets its own copy of
-- the sidecar. Never overwrites: a name clash at the destination is skipped.
-- KOReader requires are lazy, so the pure helpers can run on their own.

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local FileOps = {}

-- Path helpers ---------------------------------------------------------

local function normDir(p)
    if p == "/" then return "/" end
    return (tostring(p):gsub("/+$", ""))
end

local function basename(p)
    return tostring(p):match("([^/]+)/*$")
end

local function parentDir(p)
    local parent = normDir(p):match("^(.*)/[^/]+$")
    if parent == nil or parent == "" then return "/" end
    return parent
end

local function joinDir(dir, name)
    local base = normDir(dir)
    if base == "/" then base = "" end
    return base .. "/" .. name
end

local function exists(path)
    return lfs.attributes(path, "mode") ~= nil
end

local function safe(name, path, fn)
    local ok, err = pcall(fn)
    if not ok then logger.warn("kobold fileops:", name, path, err) end
    return ok
end

-- Planning -------------------------------------------------------------

-- Books that must not be moved right now: the one open in the reader.
function FileOps.inUsePaths()
    local set = {}
    local ok, ReaderUI = pcall(require, "apps/reader/readerui")
    local rui = ok and ReaderUI and ReaderUI.instance or nil
    if rui and rui.document and rui.document.file then
        set[rui.document.file] = true
    end
    return set
end

-- Checks every path before anything is touched.
-- Returns { moves = { { from, to }, ... }, skipped = { [reason] = count } }
-- with reasons: same_dir, exists, missing, in_use, bad_dest.
function FileOps.plan(paths, dest_dir, mode)
    local plan = { moves = {}, skipped = {}, skipped_total = 0 }
    local function skip(reason)
        plan.skipped[reason] = (plan.skipped[reason] or 0) + 1
        plan.skipped_total = plan.skipped_total + 1
    end
    dest_dir = normDir(dest_dir)
    local dest_ok = lfs.attributes(dest_dir, "mode") == "directory"
    local in_use = mode == "cut" and FileOps.inUsePaths() or {}
    for _i, from in ipairs(paths) do
        local to = joinDir(dest_dir, basename(from))
        if not dest_ok then
            skip("bad_dest")
        elseif in_use[from] then
            skip("in_use")
        elseif parentDir(from) == dest_dir then
            skip("same_dir")
        elseif not exists(from) then
            skip("missing")
        elseif exists(to) then
            skip("exists")
        else
            plan.moves[#plan.moves + 1] = { from = from, to = to }
        end
    end
    return plan
end

-- Moving ---------------------------------------------------------------

-- os.rename first (one syscall); anything it cannot do (another filesystem,
-- say) falls back to KOReader's own move.
local function physicalMove(from, to)
    if os.rename(from, to) then return true end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if ok and FileManager and FileManager.moveFile then
        local ok2, res = pcall(function() return FileManager:moveFile(from, to) end)
        return ok2 and res and true or false
    end
    return false
end

-- Moves a book's sidecar by renaming its folder: one syscall that carries
-- the metadata, a custom cover and anything other plugins keep in there.
-- True when the sidecar is dealt with (moved, or there was none); false means
-- "use DocSettings.updateLocation instead".
local function renameSidecar(old_path, new_path)
    local DocSettings = require("docsettings")
    -- Hash location keys the sidecar by file content: nothing to move.
    if G_reader_settings:readSetting("document_metadata_folder", "doc") == "hash" then
        return true
    end
    local sidecar_file, location = DocSettings:findSidecarFile(old_path, true)
    if not sidecar_file then return true end
    -- A sidecar in both locations needs a merge, not a rename.
    local name = DocSettings.getSidecarFilename(old_path)
    local held = 0
    for _i, loc in ipairs({ "doc", "dir" }) do
        local dir = DocSettings:getSidecarDir(old_path, loc)
        if dir ~= "" and lfs.attributes(dir .. "/" .. name, "mode") == "file" then
            held = held + 1
        end
    end
    if held > 1 then return false end
    local old_sdr = DocSettings:getSidecarDir(old_path, location)
    local new_sdr = DocSettings:getSidecarDir(new_path, location)
    if old_sdr == "" or new_sdr == "" or old_sdr == new_sdr then return false end
    if lfs.attributes(new_sdr, "mode") then return false end
    local parent = new_sdr:match("^(.*)/[^/]+$")
    if parent then pcall(function() require("util").makePath(parent) end) end
    return os.rename(old_sdr, new_sdr) and true or false
end

-- Files KOReader keeps BESIDE a book as "<book filename>.<ext>": the
-- notebook (.txt) and the converted copy (.html). They follow the book.
local DERIVED_SIBLING_EXTS = { "txt", "html" }

local function relocateSiblings(old_path, new_path)
    for _i, ext in ipairs(DERIVED_SIBLING_EXTS) do
        local old_sib = old_path .. "." .. ext
        local new_sib = new_path .. "." .. ext
        if lfs.attributes(old_sib, "mode") == "file" and not exists(new_sib)
            and physicalMove(old_sib, new_sib) then
            -- A converted html is a book of its own: its sidecar follows.
            if not renameSidecar(old_sib, new_sib) then
                pcall(function() require("docsettings").updateLocation(old_sib, new_sib) end)
            end
            if ext == "txt" then
                local DocSettings = require("docsettings")
                if DocSettings:hasSidecarFile(new_path) then
                    local ds = DocSettings:open(new_path)
                    -- Follow a notebook path only when it named this sibling.
                    if ds:readSetting("notebook_file") == old_sib then
                        ds:saveSetting("notebook_file", new_sib)
                        ds:flush()
                    end
                end
            end
        end
    end
end

-- The cover browser's cache keys a row on (directory, filename), the
-- directory ending in a slash. Re-keying it keeps the extracted cover.
-- Returns false when the row could not be re-keyed.
local function openBimDb()
    local ok_ds, DataStorage = pcall(require, "datastorage")
    if not ok_ds then return nil, "no-datastorage" end
    local db_path = DataStorage:getSettingsDir() .. "/bookinfo_cache.sqlite3"
    if not lfs.attributes(db_path, "mode") then return nil, "no-db" end
    local ok_sq, SQ3 = pcall(require, "lua-ljsqlite3/init")
    if not ok_sq then return nil, "no-sqlite" end
    local ok_open, db = pcall(SQ3.open, db_path)
    if not (ok_open and db) then return nil, "open-failed" end
    return db
end

local function updateBimRow(old_path, new_path, db)
    if not db then return true end   -- no cache yet: no stale row either
    local old_dir, old_name = old_path:match("^(.*/)([^/]+)$")
    local new_dir, new_name = new_path:match("^(.*/)([^/]+)$")
    if not old_dir or not new_dir then return false end
    return (pcall(function()
        local stmt = db:prepare(
            "UPDATE bookinfo SET directory = ?, filename = ? WHERE directory = ? AND filename = ?;")
        stmt:bind(new_dir, new_name, old_dir, old_name)
        stmt:step()
        stmt:close()
    end))
end

-- What follows a book after its file has moved. Each step on its own, so one
-- failing never undoes the move (worst case a stale cache entry).
local function fixupMoved(old_path, new_path, db)
    safe("sidecar", old_path, function()
        if not renameSidecar(old_path, new_path) then
            require("docsettings").updateLocation(old_path, new_path)
        end
    end)
    safe("siblings", old_path, function() relocateSiblings(old_path, new_path) end)
    safe("booklist-cache", old_path, function()
        require("ui/widget/booklist").resetBookInfoCache(old_path)
    end)
    if not updateBimRow(old_path, new_path, db) then
        safe("bim-invalidate", old_path, function()
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", old_path))
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", new_path))
        end)
    end
end

-- History and collections, in one pass for the whole batch (every move goes
-- to the same folder). A "/" destination is done one by one: the batch APIs
-- would store a doubled slash there.
local function updateHistoryAndCollections(done, dest)
    local ReadHistory = require("readhistory")
    local ReadCollection = require("readcollection")
    local files = {}
    for _i, m in ipairs(done) do files[m.from] = true end
    if dest ~= "/" and ReadHistory.updateItems and ReadCollection.updateItems then
        safe("history", dest, function() ReadHistory:updateItems(files, dest) end)
        safe("collections", dest, function() ReadCollection:updateItems(files, dest) end)
    else
        for _i, m in ipairs(done) do
            safe("history", m.from, function() ReadHistory:updateItem(m.from, m.to) end)
            safe("collections", m.from, function() ReadCollection:updateItem(m.from, m.to) end)
        end
    end
end

-- Copying --------------------------------------------------------------

-- Copies in 1 MB pieces and checks the size at the end; a failed copy leaves
-- nothing behind.
local function physicalCopy(from, to)
    local src = io.open(from, "rb")
    if not src then return false end
    local dst = io.open(to, "wb")
    if not dst then src:close() return false end
    local ok = true
    while true do
        local chunk = src:read(1024 * 1024)
        if not chunk then break end
        if not dst:write(chunk) then ok = false break end
    end
    src:close()
    local closed = dst:close()
    if not ok or not closed or lfs.attributes(from, "size") ~= lfs.attributes(to, "size") then
        os.remove(to)
        return false
    end
    return true
end

-- Gives the copy its own sidecar (reading progress, notes, custom cover).
-- Only when DocSettings.updateLocation takes the "copy" flag: without it the
-- call would MOVE the original's sidecar, so then the copy simply starts clean.
local function copySidecar(from, to)
    local DocSettings = require("docsettings")
    local info = debug.getinfo(DocSettings.updateLocation, "u")
    if not info or info.nparams < 3 then return end
    if DocSettings:hasSidecarFile(from) then
        DocSettings.updateLocation(from, to, true)
    end
end

-- Running --------------------------------------------------------------

-- Executes a plan. mode: "copy" or "cut" (move). Returns
-- { done = n, failed = n, skipped = { [reason] = count }, skipped_total = n }.
-- Synchronous on purpose: every intermediate state is a real state of the
-- disk, and a yielding loop would let the user tap into a half-moved library.
function FileOps.run(plan, mode)
    local summary = { done = 0, failed = 0, skipped = plan.skipped, skipped_total = plan.skipped_total }
    local done = {}
    local db = (mode == "cut") and #plan.moves > 0 and openBimDb() or nil
    for _i, m in ipairs(plan.moves) do
        local ok_call, ok = pcall(function()
            if mode == "cut" then
                if not physicalMove(m.from, m.to) then return false end
                fixupMoved(m.from, m.to, db)
                return true
            end
            if not physicalCopy(m.from, m.to) then return false end
            safe("copy-sidecar", m.from, function() copySidecar(m.from, m.to) end)
            return true
        end)
        if ok_call and ok then
            summary.done = summary.done + 1
            done[#done + 1] = m
        else
            summary.failed = summary.failed + 1
            logger.warn("kobold fileops: failed", mode, m.from, m.to)
        end
    end
    if db then pcall(function() db:close() end) end
    if mode == "cut" and #done > 0 then
        safe("history", plan.moves[1].to, function()
            updateHistoryAndCollections(done, parentDir(done[1].to))
        end)
    end
    -- The library and the remembered sidecar reads point at the old paths.
    safe("library", "", function() require("kobold.data.library").forgetDocInfo() end)
    return summary
end

-- Deleting -------------------------------------------------------------

-- Books that can be deleted right now: still there, and not the one open in
-- the reader. Returns { files = { path, ... }, skipped = { [reason] = n },
-- skipped_total = n } with reasons: in_use, missing.
function FileOps.planDelete(paths)
    local plan = { files = {}, skipped = {}, skipped_total = 0 }
    local in_use = FileOps.inUsePaths()
    for _i, p in ipairs(paths) do
        local reason
        if in_use[p] then reason = "in_use"
        elseif not exists(p) then reason = "missing" end
        if reason then
            plan.skipped[reason] = (plan.skipped[reason] or 0) + 1
            plan.skipped_total = plan.skipped_total + 1
        else
            plan.files[#plan.files + 1] = p
        end
    end
    return plan
end

-- Forgets a deleted file's cover-browser row.
local function deleteBimRow(path, db)
    if not db then return true end
    local dir, name = path:match("^(.*/)([^/]+)$")
    if not dir then return false end
    return (pcall(function()
        local stmt = db:prepare("DELETE FROM bookinfo WHERE directory = ? AND filename = ?;")
        stmt:bind(dir, name)
        stmt:step()
        stmt:close()
    end))
end

-- What goes with a book once its file is gone: reading progress and notes
-- (the sidecar, which holds a custom cover too), history, collections and
-- the cover browser's row. Each step on its own, so one failing never
-- stops the others.
local function forgetDeleted(path, db)
    safe("sidecar", path, function()
        local DocSettings = require("docsettings")
        DocSettings:open(path):purge()
    end)
    safe("history", path, function() require("readhistory"):removeItemByPath(path) end)
    safe("collections", path, function() require("readcollection"):removeItem(path) end)
    safe("booklist-cache", path, function()
        require("ui/widget/booklist").resetBookInfoCache(path)
    end)
    if not deleteBimRow(path, db) then
        safe("bim-invalidate", path, function()
            local UIManager = require("ui/uimanager")
            local Event = require("ui/event")
            UIManager:broadcastEvent(Event:new("InvalidateMetadataCache", path))
        end)
    end
end

-- Deletes the files of a plan (from planDelete) together with everything
-- that goes with them: the same things a move carries along. The notebook
-- and the converted copy that sit beside a book go too.
-- Returns { done = n, failed = n, skipped = {...}, skipped_total = n }.
function FileOps.delete(plan)
    local summary = { done = 0, failed = 0, skipped = plan.skipped, skipped_total = plan.skipped_total }
    local db = #plan.files > 0 and openBimDb() or nil
    for _i, path in ipairs(plan.files) do
        local ok_call, ok = pcall(function()
            for _j, ext in ipairs(DERIVED_SIBLING_EXTS) do
                local sib = path .. "." .. ext
                if lfs.attributes(sib, "mode") == "file" and os.remove(sib) then
                    forgetDeleted(sib, db)
                end
            end
            if not os.remove(path) then return false end
            forgetDeleted(path, db)
            return true
        end)
        if ok_call and ok then
            summary.done = summary.done + 1
        else
            summary.failed = summary.failed + 1
            logger.warn("kobold fileops: delete failed", path)
        end
    end
    if db then pcall(function() db:close() end) end
    safe("library", "", function() require("kobold.data.library").forgetDocInfo() end)
    return summary
end

return FileOps
