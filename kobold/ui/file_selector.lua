-- kobold/ui/file_selector.lua — KiKome
-- A full-screen "Files" for when the Files tab of the Library is turned off:
-- the folders and books of a folder, the same square / square-dot ticks as the
-- selection mode of the Files tab, and the same Selection menu (Copy, Move,
-- Select all, Delete). It is opened by the Select button of the Edit screen
-- (book_details.lua), with that book already ticked and its folder open.
--
-- Top: a pill with the name of the open folder (tap it to go to the parent
-- folder), then the actions button (the Selection menu) and a close X. Under
-- them how many books are ticked, then the list: folders (tap to open) and
-- books (tap to tick), with the page bar on the right. Swipe up / down to turn
-- the page, as in the Library.
--
-- Copy and Move ask for the destination folder on a full-screen list (the
-- same one as the Copy / Cut buttons of Edit), since there is no Files tab
-- where a clipboard could be pasted. Delete asks first, as it always does.
--
--   require("kobold.ui.file_selector").show{
--       file      = "/path/book.epub",   -- ticked at the start; its folder opens first
--       on_change = function() end,      -- runs once this screen closes, if books
--                                        -- were copied, moved or deleted
--   }

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local _               = require("kobold.i18n")
local FileActions     = require("kobold.ui.file_actions")
local KoboldCovers    = require("kobold.data.covers")
local KoboldMyBooksData = require("kobold.data.mybooks")
local KoboldWidgets   = require("kobold.ui.widgets")
local ListPicker      = require("kobold.ui.list_picker")
local OptionSheet     = require("kobold.ui.option_sheet")
local Toast           = require("kobold.ui.toast")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_PILL = Blitbuffer.Color8(0xDD)   -- the folder pill, like the Library's pills

local function U(n) return Screen:scaleBySize(n) end

local function inside(r, pos)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local function isDir(path)
    return path ~= nil and lfs.attributes(path, "mode") == "directory"
end

local function parentOf(dir)
    local parent = dir:match("^(.*)/[^/]+/*$")
    if not parent or parent == "" then return "/" end
    return parent
end

-- The home folder set in KOReader (where the library lives), or nil.
local function homeDir()
    local home = G_reader_settings and G_reader_settings:readSetting("home_dir")
    if home and isDir(home) then return (home:gsub("/+$", "")) end
    return nil
end

local FileSelector = InputContainer:extend{
    -- Shown on top of the screen it was opened from, which stays alive under it.
    name = "kobold_file_selector",
    covers_fullscreen = true,
    dithered = true,
    file = nil,
    on_change = nil,
}

-- ── The folder ─────────────────────────────────────────────────────────────

-- Entries of folder `dir`: subfolders, then the books KOReader can open, each
-- sorted by name. Hidden files and book data folders (.sdr) are left out.
-- Books use the library's entries when known, so title and authors match.
function FileSelector:listFolder(dir)
    local DocumentRegistry = require("document/documentregistry")
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
                files[#files + 1] = self.by_file[path] or {
                    file = path,
                    title = (name:gsub("%.[^%.]+$", "")),
                }
            end
        end
    end
    table.sort(dirs, function(a, b) return a.name:lower() < b.name:lower() end)
    table.sort(files, function(a, b)
        return (a.file:match("[^/]+$") or ""):lower() < (b.file:match("[^/]+$") or ""):lower()
    end)
    for _i, f in ipairs(files) do dirs[#dirs + 1] = f end
    return dirs
end

function FileSelector:applyList()
    if not isDir(self.folder) then self.folder = homeDir() or "/" end
    self.list = self:listFolder(self.folder)
end

function FileSelector:countSelected()
    local n = 0
    for _f in pairs(self.selected) do n = n + 1 end
    return n
end

-- The ticked books, sorted (a stable order for the file work).
function FileSelector:selectedFiles()
    local out = {}
    for f in pairs(self.selected) do out[#out + 1] = f end
    table.sort(out)
    return out
end

-- ── The screen ─────────────────────────────────────────────────────────────

function FileSelector:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.by_file = {}
    for _i, b in ipairs(KoboldMyBooksData.getBooks() or {}) do
        if b.file then self.by_file[b.file] = b end
    end
    -- It opens in the folder of the book, with the book ticked and its page
    -- showing.
    local dir = self.file and self.file:match("^(.*)/[^/]+$") or nil
    if not dir or dir == "" then dir = "/" end
    if not isDir(dir) then dir = homeDir() or "/" end
    self.folder = dir
    self.selected = {}
    if self.file then self.selected[self.file] = true end
    self.focus_file = self.file
    self.page = 1
    self:applyList()
    self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapSelector = { GestureRange:new{ ges = "tap", range = self.dimen } },
            SwipeSelector = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
        -- Hold the side bar and slide the finger: the bar and the page follow it.
        KoboldWidgets.registerBarDrag(self, {
            rect = function() return self.bar_rect end,
            bar  = function() return self.bar end,
            top  = function() return self.bar_rect.y end,
            goTo = function(page) self:goToPage(page) end,
        })
    end
end

-- The pill with the folder's name: the chevron back to the parent folder (at
-- the top of the file system a plain pill with a home icon). Returns it and
-- its width.
function FileSelector:folderPill(h, max_text_w)
    local at_top = (self.folder == "/")
    local name = at_top and "/" or (self.folder:match("([^/]+)/*$") or self.folder)
    local icon_size = U(18)
    local icon = at_top
        and KoboldWidgets.icon("home", icon_size, { fallback = "appbar.filebrowser" })
        or KoboldWidgets.icon("chevron.left", icon_size)
    local t = TextWidget:new{ text = name, face = KoboldWidgets.face(16), max_width = max_text_w }
    local th = t:getSize().h
    local top = math.max(0, math.floor((h - th) / 2))
    local frame = FrameContainer:new{
        bordersize = 0, radius = math.floor(h / 2), background = C_PILL,
        padding = 0, padding_left = U(14), padding_right = U(18),
        padding_top = top, padding_bottom = math.max(0, h - th - top),
        HorizontalGroup:new{ align = "center", icon, HorizontalSpan:new{ width = U(6) }, t },
    }
    return frame, frame:getSize().w
end

-- One folder row: its icon, its name and a chevron.
function FileSelector:folderRow(item, row_w, row_h)
    local gap = U(16)
    local thumb_h = row_h - U(20)
    local thumb_w = math.floor(thumb_h / 1.5)
    local chev_w = U(26)
    local text_w = row_w - thumb_w - chev_w - 2 * gap
    return KoboldWidgets.fixed(row_w, row_h, HorizontalGroup:new{
        align = "center",
        CenterContainer:new{
            dimen = Geom:new{ w = thumb_w, h = row_h },
            KoboldWidgets.icon("folder", math.floor(thumb_w * 0.8), { fallback = "appbar.filebrowser" }),
        },
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = row_h },
            TextWidget:new{ text = item.name, face = KoboldWidgets.face(17), max_width = text_w },
        },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{
            dimen = Geom:new{ w = chev_w, h = row_h },
            KoboldWidgets.icon("chevron.right", chev_w),
        },
    })
end

-- One book row: cover, title over authors, and the tick on the right.
function FileSelector:bookRow(book, row_w, row_h)
    local gap = U(16)
    local thumb_h = row_h - U(20)
    local thumb_w = math.floor(thumb_h / 1.5)
    local check_w = U(26)
    local text_w = row_w - thumb_w - check_w - 2 * gap
    local text = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = book.title or "", face = KoboldWidgets.face(17), max_width = text_w },
    }
    if book.authors then
        text[#text + 1] = VerticalSpan:new{ width = U(4) }
        text[#text + 1] = TextWidget:new{
            text = book.authors, face = KoboldWidgets.face(14),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
        }
    end
    local cover = CenterContainer:new{
        dimen = Geom:new{ w = thumb_w, h = row_h },
        KoboldWidgets.makeCover(book.file, thumb_w, thumb_h),
    }
    local tick = OptionSheet.iconWidget(self.selected[book.file] and "square-dot" or "square", check_w, BLACK)
    return KoboldWidgets.fixed(row_w, row_h, HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = row_h }, text },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{ dimen = Geom:new{ w = check_w, h = row_h }, tick },
    })
end

function FileSelector:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local body = VerticalGroup:new{ align = "left" }
    local y = U(32)
    body[#body + 1] = VerticalSpan:new{ width = y }

    -- Header: the folder pill on the left; the actions button and the X on the
    -- right (the same two icons as the selection mode of the Library).
    local header_h = U(52)
    local icon_size = U(26)
    local between = U(18)
    local right_w = icon_size + between + icon_size
    local chrome = U(14) + U(18) + U(6) + U(18)
    local pill, pill_w = self:folderPill(U(40), math.max(U(60), content_w - right_w - U(16) - chrome))
    body[#body + 1] = KoboldWidgets.fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = content_w - right_w, h = header_h }, pill },
        RightContainer:new{
            dimen = Geom:new{ w = right_w, h = header_h },
            HorizontalGroup:new{
                align = "center",
                OptionSheet.iconWidget("square-arrow-right-enter", icon_size, BLACK),
                HorizontalSpan:new{ width = between },
                KoboldWidgets.icon("close", icon_size),
            },
        },
    })
    local right_x = margin + content_w - right_w
    self.pill_rect = (self.folder ~= "/")
        and Geom:new{ x = margin, y = y, w = pill_w, h = header_h } or nil
    self.act_rect = Geom:new{ x = right_x - U(8), y = y, w = icon_size + U(8) + math.floor(between / 2), h = header_h }
    local close_x = right_x + icon_size + math.floor(between / 2)
    self.close_rect = Geom:new{ x = close_x, y = y, w = W - close_x, h = header_h }
    y = y + header_h

    -- How many books are ticked.
    local n = self:countSelected()
    local count_h = U(26)
    body[#body + 1] = KoboldWidgets.fixed(content_w, count_h, LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = count_h },
        TextWidget:new{
            text = n > 0 and string.format(_("%s selected"), FileActions.countText(n))
                or _("Tap a book to select it"),
            face = KoboldWidgets.face(14), fgcolor = KoboldWidgets.subtitleColor(),
            max_width = content_w,
        },
    })
    y = y + count_h
    body[#body + 1] = VerticalSpan:new{ width = U(8) }
    y = y + U(8)

    -- The list, down to the bottom edge, with the page bar on the right. As
    -- many whole rows as fit; the room left over is shared out among them.
    local list_h = H - U(20) - y
    local bar_w, bar_gap, arrow = U(28), U(10), U(24)
    local row_w = content_w - bar_w - bar_gap
    local base_h = math.floor(W * 0.17)
    local per_page = math.max(1, math.floor(list_h / base_h))
    local row_h = math.floor(list_h / per_page)
    if row_h > math.floor(base_h * 1.4) then row_h = base_h end
    self.per_page = per_page
    self.pages = math.max(1, math.ceil(#self.list / per_page))
    -- The first time: the page the book is on.
    if self.focus_file then
        for i, it in ipairs(self.list) do
            if it.file == self.focus_file then
                self.page = math.ceil(i / per_page)
                break
            end
        end
        self.focus_file = nil
    end
    self.page = math.max(1, math.min(self.page, self.pages))
    local first = (self.page - 1) * per_page
    self.y_list, self.list_end = y, y + list_h
    self.row_hits = {}

    local rows = VerticalGroup:new{ align = "left" }
    local used = 0
    local page_files = {}
    if #self.list == 0 then
        rows[#rows + 1] = CenterContainer:new{
            dimen = Geom:new{ w = row_w, h = list_h },
            TextWidget:new{
                text = _("This folder is empty."), face = KoboldWidgets.face(15),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = row_w,
            },
        }
        used = list_h
    end
    for i = 1, per_page do
        local item = self.list[first + i]
        if not item then break end
        local hit = { rect = Geom:new{ x = margin, y = y + used, w = row_w, h = row_h } }
        if item.is_dir then
            hit.dir = item.path
            rows[#rows + 1] = self:folderRow(item, row_w, row_h)
        else
            hit.file = item.file
            page_files[#page_files + 1] = item.file
            rows[#rows + 1] = self:bookRow(item, row_w, row_h)
        end
        self.row_hits[#self.row_hits + 1] = hit
        used = used + row_h
    end
    rows[#rows + 1] = VerticalSpan:new{ width = math.max(0, list_h - used) }
    KoboldCovers.ensure(page_files)

    self.bar = { w = bar_w, h = list_h, page = self.page, pages = self.pages, arrow = arrow }
    local bar_x = margin + row_w + math.floor(bar_gap / 2)
    self.bar_rect = Geom:new{ x = bar_x, y = y, w = W - bar_x, h = list_h }
    body[#body + 1] = HorizontalGroup:new{
        align = "top",
        rows,
        HorizontalSpan:new{ width = bar_gap },
        KoboldWidgets.pageBar(self.bar),
    }

    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = H },
            FrameContainer:new{ bordersize = 0, padding = 0, padding_left = margin, body },
        },
    }
end

-- Draws the screen again (a new folder, a change on disk).
function FileSelector:redrawAll()
    self:build()
    UIManager:setDirty(self, "ui")
end

-- ── Folders and pages ──────────────────────────────────────────────────────

function FileSelector:openFolder(dir)
    self.folder = dir
    self.page = 1
    self:applyList()
    self:redrawAll()
end

function FileSelector:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:build()
    local region = Geom:new{ x = 0, y = self.y_list, w = Screen:getWidth(), h = self.list_end - self.y_list }
    UIManager:setDirty(self, function() return "ui", region end)
end

-- ── The Selection menu ─────────────────────────────────────────────────────
-- The same rows as the Selection menu of the Files tab: Copy, Move, Select all
-- and, with books ticked, Delete.

function FileSelector:showSelectionMenu(rect)
    local n = self:countSelected()
    local function needBooks()
        if n > 0 then return false end
        Toast.show(_("Select at least one book first."))
        return true
    end
    local items = {
        { text = string.format(_("Copy (%d)"), n), icon = { "copy", "square-plus" },
          action = function()
              if needBooks() then return end
              self:pickFolder("copy")
          end },
        { text = string.format(_("Move (%d)"), n), icon = { "scissors", "square-arrow-right-enter" },
          action = function()
              if needBooks() then return end
              self:pickFolder("cut")
          end },
        { text = _("Select all"), icon = { "list-checks", "square-dot" },
          action = function()
              for _i, it in ipairs(self.list) do
                  if not it.is_dir and it.file then self.selected[it.file] = true end
              end
              self:redrawAll()
          end },
    }
    if n > 0 then
        items[#items + 1] = { text = string.format(_("Delete (%d)"), n), icon = { "trash-2" },
            action = function() self:confirmDelete() end }
    end
    require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
end

-- Something was copied, moved or deleted: nothing stays ticked, the folder is
-- read again, and whoever opened this screen is told when it closes.
function FileSelector:afterChange()
    self.changed = true
    self.selected = {}
    self:applyList()
    self:redrawAll()
end

function FileSelector:confirmDelete()
    FileActions.confirmDelete(self:selectedFiles(), function(summary)
        if not summary or summary.done == 0 then return end
        self:afterChange()
    end)
end

-- Copy and Move: a full-screen list of folders to choose the destination (the
-- same one as the Copy / Cut buttons of Edit, but for every ticked book). Tap
-- a folder to open it, the first row goes up; the pill at the top puts the
-- books in the folder that is open.
function FileSelector:pickFolder(mode)
    local files = self:selectedFiles()
    if #files == 0 then return end
    local home = homeDir()
    -- It starts in the home folder (where the Files tab starts), or in the open
    -- folder when that is outside it.
    local start = self.folder
    if home and (self.folder == home or self.folder:sub(1, #home + 1) == home .. "/") then start = home end

    local function folders(dir)
        local out = {}
        local ok, iter, st = pcall(lfs.dir, dir)
        if not ok then return out end
        for name in iter, st do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = (dir == "/" and "" or dir) .. "/" .. name
                if isDir(path) then out[#out + 1] = { name = name, path = path } end
            end
        end
        table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
        return out
    end
    -- The folder as the Files tab shows it: from the home folder on.
    local function shown(dir)
        if home and dir:sub(1, #home) == home then dir = dir:sub(#home + 1) end
        return dir == "" and "/" or dir
    end

    local cut = (mode == "cut")
    ListPicker.show{
        title = cut and _("Move to") or _("Copy to"),
        action_label = cut and _("Move here") or _("Copy here"),
        empty_text = _("No folders here."),
        state = { dir = start },
        subtitle = function(picker) return shown(picker.state.dir) end,
        rows = function(picker)
            local dir = picker.state.dir
            local rows = {}
            if dir ~= "/" then
                rows[#rows + 1] = {
                    id = "__up", icon = "arrow-left", text = _("Parent folder"),
                    sub = shown(parentOf(dir)), dir = parentOf(dir),
                }
            end
            for _i, f in ipairs(folders(dir)) do
                rows[#rows + 1] = {
                    id = f.path, icon = "folder", text = f.name,
                    marker = "chevron", dir = f.path,
                }
            end
            return rows
        end,
        can_finish = function() return true end,
        on_tap = function(row, picker)
            picker.state.dir = row.dir
            picker:reload(true)
        end,
        on_finish = function(picker)
            FileActions.transfer(files, picker.state.dir, mode, function(summary)
                if not summary or summary.done == 0 then return end
                self:afterChange()
            end)
        end,
    }
end

-- ── Taps ───────────────────────────────────────────────────────────────────

function FileSelector:dismiss()
    if self.closed then return true end
    self.closed = true
    UIManager:close(self, "ui")
    if self.changed and self.on_change then
        local cb = self.on_change
        UIManager:nextTick(function() cb() end)
    end
    return true
end

function FileSelector:onTapSelector(_ev, ges)
    local pos = ges.pos
    if inside(self.close_rect, pos) then return self:dismiss() end
    if inside(self.act_rect, pos) then
        self:showSelectionMenu(self.act_rect)
        return true
    end
    if inside(self.pill_rect, pos) then
        self:openFolder(parentOf(self.folder))
        return true
    end
    if inside(self.bar_rect, pos) then
        local page = KoboldWidgets.pageBarTarget(pos.y - self.y_list, self.bar)
        if page then self:goToPage(page) end
        return true
    end
    for _i, hit in ipairs(self.row_hits or {}) do
        if inside(hit.rect, pos) then
            if hit.dir then
                self:openFolder(hit.dir)
            elseif hit.file then
                self.selected[hit.file] = (not self.selected[hit.file]) or nil
                self:build()
                -- the tick and the count above the list
                local region = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = self.list_end }
                UIManager:setDirty(self, function() return "ui", region end)
            end
            return true
        end
    end
    return true
end

-- Swipe up for the next page, down for the previous one, like Library.
function FileSelector:onSwipeSelector(_ev, ges)
    if ges.pos.y < (self.y_list or 0) then return true end
    if ges.direction == "north" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "south" then
        self:goToPage(self.page - 1)
    end
    return true
end

function FileSelector:onClose()
    return self:dismiss()
end

-- KoboldCoversUpdated: covers finished extracting, redraw the rows.
function FileSelector:onKoboldCoversUpdated()
    if self.closed then return end
    self:build()
    UIManager:setDirty(self, "ui")
end

local M = {}

function M.show(opts)
    UIManager:show(FileSelector:new(opts), "ui")
end

return M
