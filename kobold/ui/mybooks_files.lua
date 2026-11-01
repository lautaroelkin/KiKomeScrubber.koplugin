-- kobold/ui/mybooks_files.lua — Kobold
-- The Files tab of the Library, split out of mybooks.lua: the selection menu
-- (copy / move / delete), Paste here, New folder, and the folders themselves
-- (home folder, open, rename, set as home, delete). The file work is done by
-- data/fileops.lua; the clipboard is data/clipboard.lua.
--
-- These are methods of the My Books screen: install() adds them to the class,
-- so they run with `self` as the screen, like the ones in mybooks.lua.

local ConfirmSheet = require("kobold.ui.confirm_sheet")
local RenamePrompt = require("kobold.ui.rename_prompt")
local Toast        = require("kobold.ui.toast")
local Clipboard    = require("kobold.data.clipboard")
local FileOps      = require("kobold.data.fileops")
local lfs          = require("libs/libkoreader-lfs")
local _            = require("gettext")

local Methods = {}
local countText   -- "3 books"; given by mybooks.lua in install()

-- A small message that goes away by itself (toast.lua stacks several).
local function toast(text)
    Toast.show(text)
end

-- Menu of the actions button in selection mode: put the selection on the
-- clipboard to copy or move it, or select every book of this folder.
function Methods:showSelectionMenu(rect)
    if self:inCollection() then return self:showCollectionSelectionMenu(rect) end
    local n = Clipboard.count()
    local function put(mode)
        if n == 0 then
            toast(_("Select at least one book first."))
            return
        end
        Clipboard.put(Clipboard.selected(), mode)
        Clipboard.exitSelect()
        self:refresh()
        toast(mode == "cut"
            and string.format(_("%s ready to move. Open the destination folder, then More > Paste here."), countText(n))
            or string.format(_("%s ready to copy. Open the destination folder, then More > Paste here."), countText(n)))
    end
    local items = {
            { text = string.format(_("Copy (%d)"), n), icon = { "copy", "square-plus" },
              action = function() put("copy") end },
            { text = string.format(_("Move (%d)"), n), icon = { "scissors", "square-arrow-right-enter" },
              action = function() put("cut") end },
            { text = _("Select all"), icon = { "list-checks", "square-dot" },
              action = function()
                  for _i, it in ipairs(self.list) do
                      if not it.is_dir and it.file then Clipboard.add(it.file) end
                  end
                  self:refreshList()
              end },
    }
    if n > 0 then
        items[#items + 1] = { text = string.format(_("Delete (%d)"), n), icon = { "trash-2" },
            action = function() self:confirmDelete() end }
    end
    require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
end

-- Why books were left out of a paste, one short line.
local function skippedText(plan_or_summary)
    local s = plan_or_summary.skipped or {}
    local parts = {}
    local there = (s.same_dir or 0) + (s.exists or 0)
    if there > 0 then parts[#parts + 1] = string.format(_("%d already there"), there) end
    if (s.in_use or 0) > 0 then parts[#parts + 1] = string.format(_("%d open now"), s.in_use) end
    if (s.missing or 0) > 0 then parts[#parts + 1] = string.format(_("%d not found"), s.missing) end
    if (s.bad_dest or 0) > 0 then parts[#parts + 1] = _("folder not found") end
    return table.concat(parts, ", ")
end

-- Pastes the clipboard into the folder that is open.
function Methods:pasteHere()
    local board = Clipboard.board()
    if not board then return end
    local dest = self:currentFolder()
    local plan = FileOps.plan(board.paths, dest, board.mode)
    if #plan.moves == 0 then
        local why = skippedText(plan)
        Toast.show(_("Nothing to paste here.") .. (why ~= "" and ("\n" .. why) or ""), { timeout = 4 })
        return
    end
    local folder = dest:match("([^/]+)/*$") or dest
    local verb = board.mode == "cut" and _("Move") or _("Copy")
    local text = string.format(_("%s %s to \"%s\"?"), verb, countText(#plan.moves), folder)
    local why = skippedText(plan)
    if why ~= "" then text = text .. "\n\n" .. _("Left out: ") .. why end
    ConfirmSheet.show{
        message = text,
        confirm_text = verb,
        on_confirm = function() self:runPaste(plan, board.mode) end,
    }
end

function Methods:runPaste(plan, mode)
    local working = Toast.working(_("Working…"))
    local summary = FileOps.run(plan, mode)
    Toast.dismiss(working)
    Clipboard.clear()
    local lines = {
        string.format(mode == "cut" and _("%s moved.") or _("%s copied."), countText(summary.done)),
    }
    if summary.failed > 0 then lines[#lines + 1] = string.format(_("%d failed."), summary.failed) end
    local why = skippedText(summary)
    if why ~= "" then lines[#lines + 1] = _("Left out: ") .. why end
    Toast.show(table.concat(lines, "\n"), { timeout = 4 })
    self:reload()
end

-- Asks before deleting the selected books.
function Methods:confirmDelete()
    local paths = Clipboard.selected()
    if #paths == 0 then return end
    local plan = FileOps.planDelete(paths)
    if #plan.files == 0 then
        local why = skippedText(plan)
        Toast.show(_("Nothing to delete.") .. (why ~= "" and ("\n" .. why) or ""), { timeout = 4 })
        return
    end
    local text = string.format(_("Delete %s? Their reading progress, history and collections go too. This cannot be undone."),
        countText(#plan.files))
    local why = skippedText(plan)
    if why ~= "" then text = text .. "\n\n" .. _("Left out: ") .. why end
    ConfirmSheet.show{
        message = text,
        confirm_text = _("Delete"),
        on_confirm = function() self:runDelete(plan) end,
    }
end

function Methods:runDelete(plan)
    local working = Toast.working(_("Working…"))
    local summary = FileOps.delete(plan)
    Toast.dismiss(working)
    Clipboard.exitSelect()
    local lines = { string.format(_("%s deleted."), countText(summary.done)) }
    if summary.failed > 0 then lines[#lines + 1] = string.format(_("%d failed."), summary.failed) end
    local why = skippedText(summary)
    if why ~= "" then lines[#lines + 1] = _("Left out: ") .. why end
    Toast.show(table.concat(lines, "\n"), { timeout = 4 })
    self:reload()
end

-- New folder: the full-screen editor (collection_editor.lua) asks for a name
-- and, if wanted, the books to move into it; each book shows the folder it is
-- in now. The folder is made inside the one that is open, then the ticked
-- books are moved into it (as Move + Paste here does).
function Methods:newFolder()
    local parent = self:currentFolder()
    local root = self:filesRoot()
    require("kobold.ui.collection_editor").show{
        mode = "new",
        title = _("New folder"),
        name_placeholder = _("Folder name"),
        books = self.books,
        show_path = true,
        root = root ~= "/" and root or nil,
        validate = function(name)
            if name:find("/", 1, true) or name == "." or name == ".." then
                return _("That name is not valid for a folder.")
            end
            local path = (parent == "/" and "" or parent) .. "/" .. name
            if lfs.attributes(path, "mode") then
                return _("A file or folder with that name already exists.")
            end
        end,
        on_done = function(name, picked)
            local path = (parent == "/" and "" or parent) .. "/" .. name
            if not lfs.mkdir(path) then
                Toast.error(_("The folder could not be created."))
                return
            end
            local files = {}
            for file in pairs(picked) do files[#files + 1] = file end
            if #files == 0 then
                self:reload()
                return
            end
            table.sort(files)
            local plan = FileOps.plan(files, path, "cut")
            if #plan.moves == 0 then
                local why = skippedText(plan)
                Toast.show(_("Nothing to move.") .. (why ~= "" and ("\n" .. why) or ""), { timeout = 4 })
                self:reload()
                return
            end
            local working = Toast.working(_("Working…"))
            local summary = FileOps.run(plan, "cut")
            Toast.dismiss(working)
            local lines = { string.format(_("%s moved."), countText(summary.done)) }
            if summary.failed > 0 then lines[#lines + 1] = string.format(_("%d failed."), summary.failed) end
            local why = skippedText(summary)
            if why ~= "" then lines[#lines + 1] = _("Left out: ") .. why end
            Toast.show(table.concat(lines, "\n"), { timeout = 4 })
            self:reload()
        end,
    }
end

-- The home folder set in KOReader (where the library lives).
function Methods:filesRoot()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and lfs.attributes(home, "mode") == "directory" then return (home:gsub("/+$", "")) end
    return "/"
end

function Methods:currentFolder()
    local dir = self.folder
    if not dir or lfs.attributes(dir, "mode") ~= "directory" then dir = self:filesRoot() end
    if dir ~= "/" then dir = dir:gsub("/+$", "") end
    self.folder = dir
    return dir
end

function Methods:parentFolder()
    local dir = self:currentFolder()
    local parent = dir:match("^(.*)/[^/]+/*$")
    if not parent or parent == "" then parent = "/" end
    return parent
end

-- Entries of folder `dir`: subfolders, then books KOReader can open, each
-- sorted by name. Hidden files and book data folders (.sdr) are left out.
-- Books use the library's entries when known, so status and covers match.
function Methods:listFolder(dir)
    local DocumentRegistry = require("document/documentregistry")
    local by_file = {}
    for _i, b in ipairs(self.books) do by_file[b.file] = b end
    local dirs, files = {}, {}
    local ok, iter, state = pcall(lfs.dir, dir)
    if not ok then return {} end
    for name in iter, state do
        if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
            local path = (dir == "/" and "" or dir) .. "/" .. name
            local attr = lfs.attributes(path)
            if attr and attr.mode == "directory" then
                dirs[#dirs + 1] = { is_dir = true, path = path, name = name }
            elseif attr and attr.mode == "file" and DocumentRegistry:hasProvider(path) then
                files[#files + 1] = by_file[path] or {
                    file = path, mtime = attr.modification or 0, size = attr.size,
                    title = name:gsub("%.[^%.]+$", ""), title_from_file = true,
                    sort_key = name:lower(), author_list = {},
                    ext = (name:match("%.([^%.]+)$") or ""):upper(),
                }
            end
        end
    end
    table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b) return (a.file:match("[^/]+$") or ""):lower() < (b.file:match("[^/]+$") or ""):lower() end)
    for _i, f in ipairs(files) do dirs[#dirs + 1] = f end
    return dirs
end

-- Shows folder `dir`; the page of the folder being left is remembered for
-- coming back to it.
function Methods:openFolder(dir)
    self.folder_pages = self.folder_pages or {}
    self.folder_pages[self:currentFolder()] = self.page
    self.folder = dir
    self.page = self.folder_pages[dir] or 1
    self:applyList()
    self:refresh()
end

-- Long-press on a folder: Kobold's own row of options (book_menu.lua): its
-- name (a title that also opens it), Rename, Set as home and Delete Folder.
-- `anchor` and `align` say where the menu points, as for a book.
function Methods:showFolderMenu(dir, anchor, align)
    local name = dir:match("[^/]+$") or dir
    local items = {
        { text = name, icon = "folder", bold = true,
          action = function() self:openFolder(dir) end },
        { text = _("Rename"), icon = "square-arrow-right-enter",
          action = function() self:renameFolder(dir) end },
        { text = _("Set as home"), icon = "house",
          action = function() self:setHomeFolder(dir) end },
        { text = _("Delete Folder"), icon = "trash-2",
          action = function() self:confirmDeleteFolder(dir) end },
    }
    require("kobold.ui.book_menu").show{
        items = items, screen = self, anchor = anchor,
        align = align ~= "side" and align or nil, side = align == "side",
    }
end

-- True when `path` is `dir` itself or something inside it.
local function isInside(path, dir)
    return path ~= nil and (path == dir or path:sub(1, #dir + 1) == dir .. "/")
end

-- Rename a folder (same parent): the name is typed in the rename prompt; the
-- books inside keep their progress, history and collections (FileOps).
function Methods:renameFolder(dir)
    local parent = dir:match("^(.*)/[^/]+/*$")
    if not parent or parent == "" then parent = "/" end
    local old_name = dir:match("[^/]+$") or dir
    RenamePrompt.show{
        title = _("Rename folder"),
        text = old_name,
        placeholder = _("Folder name"),
        validate = function(new)
            if new:find("/", 1, true) or new == "." or new == ".." then
                return _("That name is not valid for a folder.")
            end
            local path = (parent == "/" and "" or parent) .. "/" .. new
            if lfs.attributes(path, "mode") then
                return _("A file or folder with that name already exists.")
            end
        end,
        on_save = function(new)
            local ok, result = FileOps.renameFolder(dir, new)
            if not ok then
                Toast.error(result == "in_use"
                    and _("A book of this folder is open. Close it first.")
                    or _("The folder could not be renamed."))
                return
            end
            -- The home folder follows the rename when it was this folder or inside it.
            local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
            if isInside(home, dir) then
                G_reader_settings:saveSetting("home_dir", result .. home:sub(#dir + 1))
            end
            self:reload()
        end,
    }
end

-- Makes a folder the home folder of KOReader (where the Files tab starts).
function Methods:setHomeFolder(dir)
    if not G_reader_settings then return end
    G_reader_settings:saveSetting("home_dir", dir)
    pcall(function() G_reader_settings:flush() end)
    toast(string.format(_("%s is now your home folder."), dir:match("[^/]+$") or dir))
end

-- Deleting a folder takes its books and reading progress with it for good, so
-- it asks first: the folder's path on top, what is lost below.
function Methods:confirmDeleteFolder(dir)
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if isInside(home, dir) then
        Toast.error(_("This folder holds your home folder. Set another home first."))
        return
    end
    ConfirmSheet.show{
        title = dir,
        title_tail = true,
        message = _("Deletes the whole folder, including its books and your reading progress, permanently. This cannot be undone."),
        confirm_text = _("Delete"),
        on_confirm = function()
            local working = Toast.working(_("Working…"))
            local ok, why = FileOps.deleteFolder(dir)
            Toast.dismiss(working)
            if ok then
                toast(_("Folder deleted."))
            elseif why == "in_use" then
                Toast.error(_("A book of this folder is open. Close it first."))
            else
                Toast.error(_("The folder could not be deleted."))
            end
            self:reload()
        end,
    }
end

-- Adds these methods to the My Books class. `ctx.countText` is its helper.
function Methods.install(KoboldMyBooks, ctx)
    countText = ctx.countText
    for name, fn in pairs(Methods) do
        if name ~= "install" then KoboldMyBooks[name] = fn end
    end
end

return Methods
