-- kobold/ui/mybooks_collections.lua — Kobold
-- What the Library's collections can do, split out of mybooks.lua: the options
-- of a collection (rename, add books, remove), removing one book or the
-- selected books from a collection, and opening one. KOReader's own
-- collections (readcollection) hold the data; changes are written right away.
--
-- These are methods of the My Books screen: install() adds them to the class,
-- so they run with `self` as the screen, like the ones in mybooks.lua.

local ConfirmSheet      = require("kobold.ui.confirm_sheet")
local RenamePrompt      = require("kobold.ui.rename_prompt")
local Toast             = require("kobold.ui.toast")
local Clipboard         = require("kobold.data.clipboard")
local KoboldMyBooksData = require("kobold.data.mybooks")
local _                 = require("gettext")

local Methods = {}
local countText   -- "3 books"; given by mybooks.lua in install()

-- A small message that goes away by itself (toast.lua stacks several).
local function toast(text)
    Toast.show(text)
end

-- New collection: the full-screen editor (collection_editor.lua) asks for a
-- name and the books to put in it, creates it in KOReader's collections, then
-- opens it here.
function Methods:newCollection()
    local ok_rc, ReadCollection = pcall(require, "readcollection")
    if not ok_rc or not ReadCollection or not ReadCollection.addCollection then
        Toast.error(_("KOReader's collections are not available."))
        return
    end
    require("kobold.ui.collection_editor").show{
        mode = "new",
        title = _("New collection"),
        books = self.books,
        validate = function(name)
            if ReadCollection.coll and ReadCollection.coll[name] then
                return _("A collection with that name already exists.")
            end
        end,
        on_done = function(name, picked)
            local ok = pcall(function()
                ReadCollection:addCollection(name)
                if next(picked) then
                    ReadCollection:addItemsMultiple(picked, { [name] = true })
                end
                ReadCollection:write()
            end)
            if not ok then
                Toast.error(_("The collection could not be created."))
                return
            end
            self:openCollection(name)
        end,
    }
end

local function readCollection()
    local ok, ReadCollection = pcall(require, "readcollection")
    if ok and ReadCollection and ReadCollection.coll then return ReadCollection end
    return nil
end

-- Options for one collection, as a row of Kobold's own menu (book_menu.lua):
-- its name (a title that also opens it), Rename, Add to it and Remove.
-- `anchor` (a Geom) and `align` ("side", "left" or "right") say where the
-- menu points, as for a book. KOReader's built-in Favorites cannot be
-- renamed or removed, as in KOReader.
function Methods:showCollectionOptions(group, anchor, align)
    local RC = readCollection()
    if not RC then return end
    local name = group.key
    local items = {
        { text = group.name, icon = "book-marked", bold = true,
          action = function() self:openGroup(group) end },
    }
    local editable = name ~= RC.default_collection_name
    if editable then
        items[#items + 1] = { text = _("Rename collection"), icon = "square-arrow-right-enter",
            action = function() self:renameCollection(group) end }
    end
    items[#items + 1] = { text = string.format(_("Add to %s"), group.name), icon = "square-plus",
        action = function() self:addBookToCollection(group) end }
    if editable then
        items[#items + 1] = { text = _("Remove Collection"), icon = "trash-2",
            action = function() self:confirmRemoveCollection(group) end }
    end
    require("kobold.ui.book_menu").show{
        items = items, screen = self, anchor = anchor,
        align = align ~= "side" and align or nil, side = align == "side",
    }
end

-- Saves KOReader's collections file. KOReader itself only writes it when its
-- collections screen closes, so changes made here are written right away.
local function saveCollections(RC, names)
    pcall(function() RC:write(names) end)
end

-- The default collection is the one KOReader suggests when adding books.
function Methods:toggleDefaultCollection(name)
    local RC = readCollection()
    if not RC then return end
    local settings = RC.coll_settings[name]
    if not settings then return end
    local updated = { [name] = true }
    if RC.coll_default == name then
        RC.coll_default = nil
        settings.default = nil
    else
        local old = RC.coll_default
        if old and RC.coll_settings[old] then
            RC.coll_settings[old].default = nil
            updated[old] = true
        end
        RC.coll_default = name
        settings.default = true
    end
    saveCollections(RC, updated)
end

function Methods:renameCollection(group)
    local RC = readCollection()
    if not RC then return end
    local old = group.key
    RenamePrompt.show{
        title = _("Rename collection"),
        text = old,
        placeholder = _("Collection name"),
        validate = function(new)
            if RC.coll[new] then return _("A collection with that name already exists.") end
        end,
        on_save = function(new)
            if new == "" or new == old then return end
            RC:renameCollection(old, new)
            saveCollections(RC, nil)  -- also drops the old name from the file
            self:scheduleReload()
        end,
    }
end

-- Asks before removing a collection; only the collection goes, never the books.
function Methods:confirmRemoveCollection(group)
    if not readCollection() then return end
    ConfirmSheet.show{
        title = group.name,
        message = _("Only the collection is removed. Your books stay in your library."),
        confirm_text = _("Remove"),
        on_confirm = function()
            local RC = readCollection()
            if not RC then return end
            RC:removeCollection(group.key)
            saveCollections(RC, nil)
            self:scheduleReload()
        end,
    }
end

-- Adds books to a collection: the plus inside a collection (no argument: the
-- open one) and "Add to ..." in a collection's long-press menu use it.
function Methods:addBookToCollection(group)
    local RC = readCollection()
    group = group or self.group
    local name = group and group.key
    if not RC or not name or not RC.coll[name] then return end
    -- Every library book not in the collection yet, by title.
    local books = {}
    for _i, b in ipairs(self.books) do
        if not RC.coll[name][b.file] then books[#books + 1] = b end
    end
    books = KoboldMyBooksData.sort(books, "title_asc")
    require("kobold.ui.collection_editor").show{
        mode = "add",
        title = string.format(_("Add to %s"), group.name),
        books = books,
        on_done = function(_name, picked)
            local ok = pcall(function()
                RC:addItemsMultiple(picked, { [name] = true })
                RC:write({ [name] = true })
            end)
            if not ok then
                Toast.error(_("The books could not be added."))
            end
            self:scheduleReload()
        end,
    }
end

-- "Remove from collection" in the menu of a book inside a collection: asks, then
-- removes it from the collection (the book itself is not touched).
function Methods:confirmRemoveFromCollection(item)
    local RC = readCollection()
    local name = self.group and self.group.key
    if not RC or not name then return end
    ConfirmSheet.show{
        title = item.title,
        message = _("Removes it from this collection only. The book stays in your library."),
        confirm_text = _("Remove"),
        on_confirm = function()
            RC:removeItem(item.file, name)  -- writes the collections file
            self:scheduleReload()
        end,
    }
end

-- Menu of the actions button in selection mode inside a collection: remove the
-- selected books from it, or select every book of the collection.
function Methods:showCollectionSelectionMenu(rect)
    local n = Clipboard.count()
    local items = {
        { text = string.format(_("Remove from collection (%d)"), n), icon = { "square-minus", "trash-2" },
          action = function()
              if n == 0 then
                  toast(_("Select at least one book first."))
                  return
              end
              self:confirmRemoveSelectedFromCollection()
          end },
        { text = _("Select all"), icon = { "list-checks", "square-dot" },
          action = function()
              for _i, it in ipairs(self.list) do
                  if not it.is_dir and it.file then Clipboard.add(it.file) end
              end
              self:refreshList()
          end },
    }
    require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
end

-- Asks before removing the selected books from the open collection (the books
-- themselves are never touched).
function Methods:confirmRemoveSelectedFromCollection()
    local RC = readCollection()
    local name = self.group and self.group.key
    local paths = Clipboard.selected()
    if not RC or not name or #paths == 0 then return end
    ConfirmSheet.show{
        title = self.group.name,
        message = string.format(_("Remove %s from this collection? Only the collection changes. The books stay in your library."),
            countText(#paths)),
        confirm_text = _("Remove"),
        on_confirm = function() self:runRemoveSelectedFromCollection(name, paths) end,
    }
end

function Methods:runRemoveSelectedFromCollection(name, paths)
    local RC = readCollection()
    if not RC or not RC.coll[name] then return end
    local removed = 0
    for _i, file in ipairs(paths) do
        if RC.coll[name][file] then
            -- no_write: the file is written once, below
            if pcall(RC.removeItem, RC, file, name, true) then removed = removed + 1 end
        end
    end
    saveCollections(RC, { [name] = true })
    Clipboard.exitSelect()
    Toast.show(string.format(_("%s removed from the collection."), countText(removed)), { timeout = 4 })
    self:reload()
end

-- Shows collection `name` (by its ReadCollection key) inside the
-- Collections tab, with the back pill returning to the list.
function Methods:openCollection(name)
    self.group_page = self.page
    self.group = nil
    for _i, g in ipairs(KoboldMyBooksData.getGroups(self.books, "collections")) do
        if g.key == name then self.group = g break end
    end
    self.page = 1
    self:applyList()
    self:refresh()
end

-- Adds these methods to the My Books class. `ctx.countText` is its helper.
function Methods.install(KoboldMyBooks, ctx)
    countText = ctx.countText
    for name, fn in pairs(Methods) do
        if name ~= "install" then KoboldMyBooks[name] = fn end
    end
end

return Methods
