-- kobold/ui/file_actions.lua — Kobold
-- The file work every screen shares: move / copy books into a folder, delete
-- books (with the confirmation sheet) and rename one book. The Files tab's
-- selection mode (mybooks_files.lua) and the Edit screen of the book details
-- both go through here, so a book is moved, copied, deleted and renamed the
-- same way everywhere. The disk work is done by data/fileops.lua.
--
-- Every function that changes something takes an `on_done(summary)` callback
-- that runs once it is finished (so the caller can reload its screen).

local ConfirmSheet = require("kobold.ui.confirm_sheet")
local RenamePrompt = require("kobold.ui.rename_prompt")
local Toast        = require("kobold.ui.toast")
local FileOps      = require("kobold.data.fileops")
local lfs          = require("libs/libkoreader-lfs")
local _            = require("kobold.i18n")

local FileActions = {}

-- "3 books"
function FileActions.countText(n)
    if n == 1 then return _("1 book") end
    return n .. _(" books")
end
local countText = FileActions.countText

-- Why books were left out of a paste or a delete, one short line.
function FileActions.skippedText(plan_or_summary)
    local s = plan_or_summary.skipped or {}
    local parts = {}
    local there = (s.same_dir or 0) + (s.exists or 0)
    if there > 0 then parts[#parts + 1] = string.format(_("%d already there"), there) end
    if (s.in_use or 0) > 0 then parts[#parts + 1] = string.format(_("%d open now"), s.in_use) end
    if (s.missing or 0) > 0 then parts[#parts + 1] = string.format(_("%d not found"), s.missing) end
    if (s.bad_dest or 0) > 0 then parts[#parts + 1] = _("folder not found") end
    return table.concat(parts, ", ")
end
local skippedText = FileActions.skippedText

-- Moves (mode "cut") or copies (mode "copy") the books `files` (a list of
-- paths) into folder `dest`, and says what happened. This is Move + Paste
-- here without the clipboard step.
function FileActions.transfer(files, dest, mode, on_done)
    local verb_none = mode == "cut" and _("Nothing to move.") or _("Nothing to copy.")
    if mode == "cut" then
        -- a parked book (the one just read) is closed first, or it would be left out
        for _i, f in ipairs(files) do FileActions.releaseBook(f) end
    end
    local plan = FileOps.plan(files, dest, mode)
    if #plan.moves == 0 then
        local why = skippedText(plan)
        Toast.show(verb_none .. (why ~= "" and ("\n" .. why) or ""), { timeout = 4 })
        if on_done then on_done(nil) end
        return
    end
    local working = Toast.working(_("Working…"))
    local summary = FileOps.run(plan, mode)
    Toast.dismiss(working)
    local lines = {
        string.format(mode == "cut" and _("%s moved.") or _("%s copied."), countText(summary.done)),
    }
    if summary.failed > 0 then lines[#lines + 1] = string.format(_("%d failed."), summary.failed) end
    local why = skippedText(summary)
    if why ~= "" then lines[#lines + 1] = _("Left out: ") .. why end
    Toast.show(table.concat(lines, "\n"), { timeout = 4 })
    if on_done then on_done(summary) end
end

-- Asks before deleting the books `paths`; then deletes them with everything
-- that goes with them (progress, history, collections).
function FileActions.confirmDelete(paths, on_done)
    if #paths == 0 then return end
    for _i, p in ipairs(paths) do FileActions.releaseBook(p) end
    local plan = FileOps.planDelete(paths)
    if #plan.files == 0 then
        local why = skippedText(plan)
        Toast.show(_("Nothing to delete.") .. (why ~= "" and ("\n" .. why) or ""), { timeout = 4 })
        return
    end
    local text
    if #plan.files == 1 then
        text = _("Delete this book? Its reading progress, history and collections go too. This cannot be undone.")
    else
        text = string.format(_("Delete %s? Their reading progress, history and collections go too. This cannot be undone."),
            countText(#plan.files))
    end
    local why = skippedText(plan)
    if why ~= "" then text = text .. "\n\n" .. _("Left out: ") .. why end
    ConfirmSheet.show{
        message = text,
        confirm_text = _("Delete"),
        on_confirm = function() FileActions.runDelete(plan, on_done) end,
    }
end

function FileActions.runDelete(plan, on_done)
    local working = Toast.working(_("Working…"))
    local summary = FileOps.delete(plan)
    Toast.dismiss(working)
    local lines = { string.format(_("%s deleted."), countText(summary.done)) }
    if summary.failed > 0 then lines[#lines + 1] = string.format(_("%d failed."), summary.failed) end
    local why = skippedText(summary)
    if why ~= "" then lines[#lines + 1] = _("Left out: ") .. why end
    Toast.show(table.concat(lines, "\n"), { timeout = 4 })
    if on_done then on_done(summary) end
end

-- A book that is open in the reader cannot be moved, renamed or reset (the
-- reader saves its data when it closes, over whatever was done). Leaving a
-- book for KiKome only parks it, so this closes a parked one first (KOReader
-- saves it, see park.lua). True when the book is free.
function FileActions.releaseBook(file)
    if not FileOps.inUsePaths()[file] then return true end
    local ok, Park = pcall(require, "kobold.ui.park")
    if ok and Park and Park.parkedFile and Park.parkedFile() == file then
        pcall(Park.fm)
    end
    return not FileOps.inUsePaths()[file]
end

-- Rename one book: the same rename prompt as folders and collections. The
-- name is typed without the extension, which stays as it is. `on_done(new_path)`
-- runs after the book was renamed.
function FileActions.renameBook(file, on_done)
    if not FileActions.releaseBook(file) then
        Toast.error(_("This book is open. Close it first."))
        return
    end
    local parent = file:match("^(.*)/[^/]+$") or "/"
    local name = file:match("([^/]+)$") or file
    local base, ext = name:match("^(.*)(%.[^%.]+)$")
    if not base or base == "" then base, ext = name, "" end
    RenamePrompt.show{
        title = _("Rename book"),
        text = base,
        placeholder = _("File name"),
        validate = function(new)
            if new:find("/", 1, true) or new == "." or new == ".." then
                return _("That name is not valid for a file.")
            end
            local path = (parent == "/" and "" or parent) .. "/" .. new .. ext
            if path ~= file and lfs.attributes(path, "mode") then
                return _("A file or folder with that name already exists.")
            end
        end,
        on_save = function(new)
            if new == "" or new == base then return end
            local ok, result = FileOps.renameFile(file, new .. ext)
            if not ok then
                Toast.error(result == "in_use"
                    and _("This book is open. Close it first.")
                    or _("The book could not be renamed."))
                return
            end
            if on_done then on_done(result) end
        end,
    }
end

-- Reset this document: erases the reading data of the book (progress,
-- bookmarks, highlights, notes, status, review, its settings), after asking.
-- The file, a custom cover and corrected metadata stay. `on_done` runs after.
function FileActions.resetDocument(file, on_done)
    if not FileActions.releaseBook(file) then
        Toast.error(_("This book is open. Close it first."))
        return
    end
    local BookTools = require("kobold.data.book_tools")
    if not BookTools.canReset() then
        -- an older KOReader: its own Reset dialog does it
        local ok = pcall(function()
            local util = require("apps/filemanager/filemanagerutil")
            util.genResetSettingsButton(file, function() if on_done then on_done() end end).callback()
        end)
        if not ok then Toast.error(_("The document could not be reset.")) end
        return
    end
    ConfirmSheet.show{
        message = _("Reset this document? Its reading progress, highlights, notes, status and settings are erased. The book file, its custom cover and corrected metadata stay. This cannot be undone."),
        confirm_text = _("Reset"),
        on_confirm = function()
            if not BookTools.reset(file) then
                Toast.error(_("The document could not be reset."))
                return
            end
            Toast.show(_("Document reset."))
            if on_done then on_done() end
        end,
    }
end

-- Export document: the book's highlights and notes as a Markdown file next to
-- the book (the format of Page Scrubber's export). The name is asked for with
-- the same prompt as Rename, with a free one already in it.
function FileActions.exportNotes(file, title, on_done)
    local text, count = require("kobold.data.annotations").toMarkdown(file, title)
    if not text then
        Toast.show(_("This book has no annotations to export."))
        return
    end
    local parent = file:match("^(.*)/[^/]+$") or "/"
    local function pathOf(name) return (parent == "/" and "" or parent) .. "/" .. name .. ".md" end
    local safe = title:gsub("%s+", "_"):gsub('[\\/:*?"<>|]', "")
    if safe == "" then safe = "Book" end
    local base = safe .. "_" .. _("Notes")
    local name, n = base, 1
    while lfs.attributes(pathOf(name), "mode") do
        n = n + 1
        name = base .. " (" .. n .. ")"
    end
    RenamePrompt.show{
        title = _("Export document"),
        text = name,
        placeholder = _("File name"),
        save_text = _("Export"),
        allow_unchanged = true,
        validate = function(new)
            local bare = new:gsub("%.md$", "")
            if bare == "" or bare:find("/", 1, true) or bare == "." or bare == ".." then
                return _("That name is not valid for a file.")
            end
            if lfs.attributes(pathOf(bare), "mode") then
                return _("A file or folder with that name already exists.")
            end
        end,
        on_save = function(new)
            local bare = new:gsub("%.md$", "")
            local full = pathOf(bare)
            local f = io.open(full, "w")
            if not f then
                Toast.error(_("The notes could not be exported."))
                return
            end
            f:write(text)
            f:close()
            Toast.show(_("Saved in:") .. "\n" .. full, { timeout = 5 })
            if on_done then on_done(full) end
        end,
    }
end

-- Refresh metadata: the book is read again (title, authors, series, pages and
-- cover as the cover browser keeps them), for when they are out of date: the
-- file was replaced or edited (Calibre), or the cover is wrong. Corrections
-- made in Edit > Metadata and a custom cover are not touched.
function FileActions.refreshMetadata(file, on_done)
    local ok = pcall(function() require("kobold.data.covers").refreshBook(file) end)
    if not ok then
        Toast.error(_("The metadata could not be refreshed."))
        return
    end
    Toast.show(_("Metadata refresh queued."))
    if on_done then on_done() end
end

return FileActions
