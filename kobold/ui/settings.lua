-- kobold/ui/settings.lua — Kobold
-- Kobold Settings: a full-screen window in the style of the Kindle settings
-- screen. Shared status bar on top, then a header (back arrow inside a
-- submenu, title, close button), a thin divider and rows of
-- icon / text / value-or-chevron. No frame, border, radius or shadow.
--
-- Structure follows scrubber_settings.lua:
--   getPageDefinition(page_id) -> { title = ..., items = {...} }
--   pushView(page_id) / popView() with a history; a pop without history closes.
--
-- Item format (the only one this file uses):
--   { section = "General" }                        a small gray heading
--   {
--     text     = "Battery",                       row label
--     icon     = "grid.svg",                      string, or a list of names to try in order
--     kind     = "submenu" | "toggle" | "action" | "radio",
--     value    = "5",                             text on the right (optional)
--     bold     = true,                            bold label (optional)
--     disabled = true,                            gray, not tappable (optional)
--     desc     = "...",                           shown when the row is held (optional)
--     -- submenu: target = page_id               tap pushes that page
--     -- toggle:  setting = "transition",        tap flips the pref (true / nil);
--     --          default = false                drawn with the same on / off glyph as scrubber_settings
--     -- action:  callback = function() end      tap runs it
--     -- radio:   checked = bool,                a choice inside a choice page: draws a check,
--     --          on_pick = function() end       tap runs on_pick and goes back one level
--   }
-- Pages: "root" (the main screen), "general" (opening panel, corners, outline,
-- shelves and the status bar), "advanced" and one choice page per setting
-- (battery, library_list_rows, library_grid_rows), and "library".
-- Everything stays inside this window; no KOReader menus.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Event           = require("ui/event")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("gettext")
local KoboldChips     = require("kobold.data.chips")
local KoboldCovers    = require("kobold.data.covers")
local KoboldLibrary   = require("kobold.data.library")
local KoboldMeta      = require("kobold.meta")
local KoboldPrefs     = require("kobold.data.prefs")
local KoboldEditors   = require("kobold.ui.editors")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local BATTERY_LABELS = { fill = _("Fill"), percent = _("Percentage") }

local KoboldSettings = InputContainer:extend{
    -- Not modal: its editors and the stats popup open on top of it.
    -- Full screen, so the nav bar of the screen below stays covered.
    covers_fullscreen = true,
    name = "kobold_settings",
    history = nil,
    current_view = "root",
}
KoboldWidgets.addScreenEvents(KoboldSettings)

---------------------------------------------------------------------------
-- Icons
---------------------------------------------------------------------------

-- Folders where Kobold's SVG icons may live, relative to this file
-- (kobold/ui/settings.lua). The first one that holds the file wins.
local here = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local ICON_DIRS = {
    here .. "../icons/",
    here .. "icons/",
    here .. "../../icons/",
    here .. "../assets/icons/",
}

local _path_cache = {}

-- Path of an icon file, or nil when no folder has it.
local function getSvgPath(filename)
    if not filename or filename == "" then return nil end
    local cached = _path_cache[filename]
    if cached ~= nil then return cached or nil end
    -- A full path (such as KoboldMeta.icon gives) is used as it is.
    if filename:sub(1, 1) == "/" then
        local f = io.open(filename, "r")
        if f then
            f:close()
            _path_cache[filename] = filename
            return filename
        end
        _path_cache[filename] = false
        return nil
    end
    for _i, dir in ipairs(ICON_DIRS) do
        local p = dir .. filename
        local f = io.open(p, "r")
        if f then
            f:close()
            _path_cache[filename] = p
            return p
        end
    end
    _path_cache[filename] = false
    return nil
end

-- A new icon widget (never shared between rows: widgets are freed with
-- their parent), or nil when the file is missing or fails to load.
-- `filename` may be a list of names; the first one found is used.
local function loadSvg(filename, size, fgcolor)
    local names = type(filename) == "table" and filename or { filename }
    for _i, name in ipairs(names) do
        local path = getSvgPath(name)
        if path then
            local ImageWidget = require("ui/widget/imagewidget")
            local ok, widget = pcall(function()
                return ImageWidget:new{
                    file = path,
                    width = size,
                    height = size,
                    alpha = true,
                    fgcolor = fgcolor or Blitbuffer.COLOR_BLACK,
                    original_in_nightmode = false,
                    file_do_cache = false,
                }
            end)
            if ok and widget then return widget end
        end
    end
    return nil
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Open Kobold screens redraw their status bar (the battery style changed).
local function broadcastChange()
    UIManager:broadcastEvent(Event:new("KoboldSettingsChanged"))
end

local function prepareCovers()
    local files = {}
    for i, book in ipairs(KoboldLibrary.scan()) do files[i] = book.file end
    local n = KoboldCovers.prepareAll(files)
    local text
    if n == nil then
        text = _("Covers cannot be prepared right now. The cover browser is busy or not enabled.")
    elseif n == 0 then
        text = _("Every book already has its cover.")
    else
        text = string.format(_("Preparing %d covers in the background."), n)
    end
    UIManager:show(InfoMessage:new{ text = text })
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

-- Closes the Kobold screen this window was opened over (Home, My Books...).
-- Those screens carry `kobold_tab`.
local function closeKoboldScreens()
    local found = {}
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if w and w.kobold_tab then found[#found + 1] = w end
    end
    for _i, w in ipairs(found) do UIManager:close(w) end
end

-- A page of radio rows: one row per option, the current one checked.
-- Picking one sets it and goes back to the page that opened this one.
local function radioPage(title, options, current, set)
    local items = {}
    for _i, opt in ipairs(options) do
        items[#items + 1] = {
            text = opt.label, kind = "radio", checked = (opt.id == current),
            on_pick = function() set(opt.id) end,
        }
    end
    return { title = title, items = items }
end

-- Pages are built fresh on every redraw, so values are always current.
function KoboldSettings:getPageDefinition(page_id)
    local done = function() self:refresh() end

    -- The main screen: everything in one list.
    if page_id == "root" then
        return {
            title = _("Settings"),
            items = {
                {
                    text = _("General"), icon = { "settings.svg", "settings-2.svg" }, kind = "submenu", target = "general",
                    desc = _("Opening pill, rounded corners, cover outline and the status bar."),
                },
                {
                    text = _("Shelves"), icon = "square-library.svg", kind = "submenu", target = "shelves",
                    desc = _("The chips along the top of Home: their order, which are on, and folder chips."),
                },
                { section = _("Library") },
                {
                    text = _("Library options"), icon = { "library.svg", "grid.svg" }, kind = "submenu", target = "library",
                    desc = _("How the Library (My Books) lays out its books: rows per page in list and in grid view."),
                },
                { section = _("App") },
                {
                    text = _("Restart KiKome"), icon = "undo.svg", kind = "action",
                    callback = function() self:restartKobold() end,
                },
                {
                    text = _("Exit KiKome"), icon = "2square-arrow-right-enter.svg", kind = "action",
                    callback = function() self:exitKobold() end,
                },
                { section = _("Other") },
                {
                    text = _("Advanced settings"), icon = "settings-2.svg", kind = "submenu", target = "advanced",
                },
            },
        }
    end

    -- General: what used to be the General section, and the Status bar.
    if page_id == "general" then
        return {
            title = _("General"),
            items = {
                {
                    text = _("Opening and closing"), icon = "sparkles.svg", kind = "toggle",
                    setting = "transition", default = false,
                    desc = _("An \"Opening\" pill on the book's cover and a small \"Closing\" pill instead of KOReader's messages. Off: the same as KOReader."),
                },
                {
                    text = _("Rounded corners"), icon = "square.svg", kind = "toggle",
                    setting = "rounded_corners", default = true,
                    desc = _("Round the corners of the covers on Home and in the library, folders included. Off: square corners."),
                },
                {
                    text = _("Cover outline"), icon = "image.svg", kind = "toggle",
                    setting = "cover_outline", default = true,
                    desc = _("A thin grey line around every cover, on Home and in the library, in grid and list. Off: covers with no outline."),
                },
                { section = _("Status bar") },
                {
                    text = _("Battery"), icon = "zap.svg", kind = "submenu", target = "battery",
                    value = BATTERY_LABELS[KoboldPrefs.get("battery")] or BATTERY_LABELS.fill,
                    desc = _("Show the charge as a fill inside the icon, or as a number."),
                },
            },
        }
    end

    -- Library (My Books): how it lays out its books.
    if page_id == "library" then
        local function rowsValue(key)
            local v = tonumber(KoboldPrefs.get(key))
            return v and tostring(v) or _("Automatic")
        end
        return {
            title = _("Library"),
            items = {
                { section = _("View: list") },
                {
                    text = _("Books per page"), icon = { "list.svg", "grid.svg" }, kind = "submenu",
                    target = "library_list_rows", value = rowsValue("library_list_rows"),
                    desc = _("Rows on lists with covers: Books, Series, and the books of an author, series or collection. Automatic fits as many as the screen allows, as Home does."),
                },
                { section = _("View: grid") },
                {
                    text = _("Rows per page"), icon = "grid.svg", kind = "submenu",
                    target = "library_grid_rows", value = rowsValue("library_grid_rows"),
                    desc = _("Rows of covers in grid view. Automatic fits as many as the screen allows, as Home does."),
                },
            },
        }
    end

    -- Advanced settings: the rarely used things.
    if page_id == "advanced" then
        -- The row shows the Kobold logo that About uses; info.svg if missing.
        local about_icon = { "info.svg" }
        local logo = KoboldMeta.icon("book-marked.svg")
        if logo then table.insert(about_icon, 1, logo) end
        return {
            title = _("Advanced settings"),
            items = {
                {
                    text = _("Based on Kobold"), icon = about_icon, kind = "action",
                    callback = function()
                        -- Guarded: a missing or broken About module shows its
                        -- error instead of taking KOReader down.
                        local ok, err = pcall(function() require("kobold.ui.about").show() end)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = tostring(err) })
                        end
                    end,
                },
                {
                    text = _("Reset to defaults"), icon = "undo.svg", kind = "action",
                    value = _("Reset"),
                    desc = _("Put every KiKome setting back as it was when first installed."),
                    callback = function()
                        KoboldEditors.confirm(_("Reset all KiKome settings?"), _("Reset"), function()
                            KoboldPrefs.resetAll()
                            broadcastChange()
                            UIManager:broadcastEvent(Event:new("KoboldIconsChanged"))
                        end, done)
                    end,
                },
                {
                    text = _("Load missing covers"), icon = "image.svg", kind = "action",
                    value = _("Start"),
                    desc = _("Read the cover of every book that has none yet, in the background. Can take several minutes."),
                    callback = function()
                        KoboldEditors.confirm(_("Load the missing covers for all books now?"), _("Start"), prepareCovers)
                    end,
                },
                {
                    text = _("Check for updates"), icon = "zap.svg", kind = "action",
                    value = KoboldMeta.VERSION and ("v" .. tostring(KoboldMeta.VERSION)) or nil,
                    callback = function()
                        -- Guarded: a missing or broken updater shows its error
                        -- instead of taking KOReader down.
                        local ok, err = pcall(function() require("kobold.updater").check() end)
                        if not ok then
                            UIManager:show(InfoMessage:new{ text = tostring(err) })
                        end
                    end,
                },
            },
        }
    end

    -- Shelves: the chips along the top of Home.
    if page_id == "shelves" then
        local chips = KoboldChips.list()
        local items = { { section = _("Chips") } }
        for i, c in ipairs(chips) do
            items[#items + 1] = {
                kind = "chip", chip_id = c.id, text = c.label,
                enabled = c.enabled, is_custom = (c.kind == "folder"),
                can_up = (i > 1), can_down = (i < #chips),
            }
        end
        items[#items + 1] = {
            text = _("Add a chip"), icon = "plus.svg", kind = "action",
            desc = _("A chip for one folder of your books. The chip takes the folder's name."),
            callback = function()
                if KoboldChips.isFull() then
                    UIManager:show(InfoMessage:new{
                        text = string.format(_("Maximum of %d chips on. Turn one off first."), KoboldChips.MAX),
                    })
                    return
                end
                self:pushView("chip_folders:" .. KoboldChips.rootDir())
            end,
        }
        return { title = _("Shelves"), items = items }
    end

    -- One chip's own options.
    if page_id:sub(1, 5) == "chip:" then
        local id = page_id:sub(6)
        local chip
        for _i, c in ipairs(KoboldChips.list()) do
            if c.id == id then chip = c; break end
        end
        if not chip then return { title = _("Shelves"), items = {} } end
        local items = {
            {
                text = _("Shelf boards"), icon = "layers.svg", kind = "toggle",
                get = function() return KoboldChips.shelvesOn(id) end,
                set = function(on) KoboldChips.setShelves(id, on) end,
                desc = _("The boards the books stand on in Grid view. Off: the books show without them."),
            },
        }
        -- The Collections chip: whether Favorites and To be read are listed in it.
        -- (They also have chips of their own, off by default.)
        if id == "collections" then
            items[#items + 1] = { section = _("Show in Collections") }
            items[#items + 1] = {
                text = _("To be read"), kind = "toggle",
                get = function() return KoboldChips.collectionShown("tbr") end,
                set = function(on) KoboldChips.setCollectionShown("tbr", on) end,
                desc = _("List the To be read collection here. Off: it is hidden from Collections."),
            }
            items[#items + 1] = {
                text = _("Favorites"), kind = "toggle",
                get = function() return KoboldChips.collectionShown("favorites") end,
                set = function(on) KoboldChips.setCollectionShown("favorites", on) end,
                desc = _("List the Favorites collection here. Off: it is hidden from Collections."),
            }
        end
        if chip.kind == "folder" then
            items[#items + 1] = { section = _("Chip") }
            items[#items + 1] = {
                text = _("Remove chip"), icon = "trash-2.svg", kind = "action",
                desc = _("Takes this folder's chip off the shelves. The folder and its books stay."),
                callback = function()
                    KoboldEditors.confirm(string.format(_("Remove \"%s\" from the shelves?"), chip.label), _("Remove"), function()
                        KoboldChips.remove(id)
                        self:popView()
                    end)
                end,
            }
        end
        return { title = chip.label, items = items }
    end

    -- Choosing a folder for a new chip. The page id carries the folder path,
    -- so Back goes to the folder above.
    if page_id:sub(1, 13) == "chip_folders:" then
        local path = page_id:sub(14)
        local root = KoboldChips.rootDir()
        local files = {}
        local ok, books = pcall(KoboldLibrary.scan)
        if ok and type(books) == "table" then
            for _i, b in ipairs(books) do
                if b.file then files[#files + 1] = b.file end
            end
        end
        local items = {}
        for _i, name in ipairs(KoboldChips.subfolders(files, path)) do
            items[#items + 1] = {
                text = name, icon = "folder.svg", kind = "submenu",
                target = "chip_folders:" .. path .. "/" .. name,
            }
        end
        if #items == 0 then
            items[#items + 1] = { text = _("No folders here."), kind = "action", disabled = true }
        end
        -- Only once a folder is open: the folder you are in is the one added.
        if path ~= root and path ~= "" then
            items[#items + 1] = { section = _("This folder") }
            items[#items + 1] = {
                text = _("Add this folder as a chip"), icon = "plus.svg", kind = "action",
                desc = _("Adds a chip with this folder's name, showing the books under it."),
                callback = function()
                    local ok_add, why = KoboldChips.add(path)
                    if not ok_add then
                        local msg = (why == "dup") and _("That folder already has a chip.")
                            or string.format(_("Maximum of %d chips on. Turn one off first."), KoboldChips.MAX)
                        UIManager:show(InfoMessage:new{ text = msg })
                        return
                    end
                    self:backToShelves()
                end,
            }
        end
        return {
            title = (path == root or path == "") and _("Choose a folder") or path:match("([^/]+)$"),
            items = items,
        }
    end

    -- Choice pages: same window, same style, a check on the current option.
    if page_id == "battery" then
        return radioPage(_("Battery"), {
            { id = "fill", label = BATTERY_LABELS.fill },
            { id = "percent", label = BATTERY_LABELS.percent },
        }, KoboldPrefs.get("battery") or "fill", function(id)
            KoboldPrefs.set("battery", id)
            broadcastChange()
        end)
    elseif page_id == "library_list_rows" then
        local options = { { id = "auto", label = _("Automatic") } }
        for n = KoboldPrefs.COVER_ROWS_MIN or 3, KoboldPrefs.COVER_ROWS_MAX or 8 do
            options[#options + 1] = { id = n, label = tostring(n) }
        end
        return radioPage(_("Books per page"), options, tonumber(KoboldPrefs.get("library_list_rows")) or "auto", function(n)
            KoboldPrefs.set("library_list_rows", n ~= "auto" and n or nil)
        end)
    elseif page_id == "library_grid_rows" then
        local options = { { id = "auto", label = _("Automatic") } }
        for n = 4, 6 do
            options[#options + 1] = { id = n, label = tostring(n) }
        end
        return radioPage(_("Rows per page"), options, tonumber(KoboldPrefs.get("library_grid_rows")) or "auto", function(n)
            KoboldPrefs.set("library_grid_rows", n ~= "auto" and n or nil)
        end)
    end

    -- Unknown page: an empty one, never a crash.
    return { title = _("Settings"), items = {} }
end

---------------------------------------------------------------------------
-- Restart and exit KiKome
---------------------------------------------------------------------------

-- Closes this window without the refresh of onClose (used when Kobold is
-- about to go away).
function KoboldSettings:closeAll()
    self.closed = true
    UIManager:close(self)
    closeKoboldScreens()
end

function KoboldSettings:exitKobold()
    self:closeAll()
end

-- Restarts Kobold inside KOReader: closes it, forgets every loaded Kobold
-- module (so the code and its caches are read again from disk) and opens
-- Home fresh. KOReader itself keeps running.
function KoboldSettings:restartKobold()
    self:closeAll()
    for name in pairs(package.loaded) do
        if name:match("^kobold%.") then package.loaded[name] = nil end
    end
    UIManager:nextTick(function()
        local ok, err = pcall(function() require("kobold.ui.router").show("home") end)
        if not ok then
            UIManager:show(InfoMessage:new{ text = _("Kobold failed to restart.") .. "\n" .. tostring(err) })
        end
    end)
end

---------------------------------------------------------------------------
-- Navigation
---------------------------------------------------------------------------

function KoboldSettings:pushView(target)
    table.insert(self.history, self.current_view)
    self.current_view = target
    self.page = 1
    self:refresh()
end

-- Back one level; with no history left it closes the window.
function KoboldSettings:popView()
    if #self.history > 0 then
        self.current_view = table.remove(self.history)
        self.page = 1
        self:refresh()
    else
        self:onClose()
    end
end

-- Leaves the folder picker, however deep it went, and lands on Shelves.
function KoboldSettings:backToShelves()
    while self.current_view:sub(1, 13) == "chip_folders:" and #self.history > 0 do
        self.current_view = table.remove(self.history)
    end
    self.page = 1
    self:refresh()
end

---------------------------------------------------------------------------
-- Layout
---------------------------------------------------------------------------

local function scale(px) return Screen:scaleBySize(px) end

local function rowHeight() return scale(64) end
local function sectionHeight() return scale(44) end

local function itemHeight(item)
    return item.section and sectionHeight() or rowHeight()
end

-- First item of every page. A section heading never ends a page.
local function paginate(items, max_h)
    local starts = { 1 }
    local used, i = 0, 1
    while i <= #items do
        local h = itemHeight(items[i])
        local need = h
        if items[i].section and items[i + 1] then need = need + itemHeight(items[i + 1]) end
        if used > 0 and used + need > max_h then
            starts[#starts + 1] = i
            used = 0
        else
            used = used + h
            i = i + 1
        end
    end
    return starts
end

-- A chip row: switch on the left (on / off), the name, then the up and down
-- chevrons on the right. The taps are split up by chipZones().
local function chipGeometry(w)
    local tog_w   = scale(44)
    local arrow_w = scale(44)
    return tog_w, arrow_w
end

-- Tap zones of a chip row, relative to the row's left edge.
local function chipZones(w)
    local tog_w, arrow_w = chipGeometry(w)
    return {
        toggle = { x = 0, w = tog_w },
        text   = { x = tog_w, w = w - tog_w - 2 * arrow_w },
        up     = { x = w - 2 * arrow_w, w = arrow_w },
        down   = { x = w - arrow_w, w = arrow_w },
    }
end

local function buildChipRow(item, w)
    local row_h = rowHeight()
    local tog_w, arrow_w = chipGeometry(w)
    local icon_sz = scale(20)
    local is_on = item.enabled
    local color = is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY

    local glyph = TextWidget:new{
        text = is_on and "\u{EC20}" or "\u{EC21}",
        face = Font:getFace("cfont", scale(24)),
        fgcolor = is_on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY,
    }
    local chev_sz = scale(18)
    local name = TextWidget:new{
        text = item.text, face = KoboldWidgets.face(18),
        fgcolor = color, max_width = w - tog_w - 2 * arrow_w - chev_sz - scale(16),
        truncate_with_ellipsis = true,
    }
    -- A small, soft chevron right after the name: the chip opens its own options.
    local chevron = loadSvg("chevron-right.svg", chev_sz, Blitbuffer.COLOR_DARK_GRAY)

    local function arrow(file, fallback)
        local icon = loadSvg(file, icon_sz, Blitbuffer.COLOR_BLACK)
        if icon then return icon end
        return TextWidget:new{
            text = fallback, face = Font:getFace("cfont", scale(14)), bold = true,
            fgcolor = Blitbuffer.COLOR_BLACK,
        }
    end

    local group = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = row_h },
        LeftContainer:new{
            dimen = Geom:new{ w = w, h = row_h },
            HorizontalGroup:new{
                LeftContainer:new{ dimen = Geom:new{ w = tog_w, h = row_h }, glyph },
                LeftContainer:new{
                    dimen = Geom:new{ w = w - tog_w, h = row_h },
                    HorizontalGroup:new{
                        align = "center",
                        name,
                        chevron and HorizontalSpan:new{ width = scale(8) } or HorizontalSpan:new{ width = 0 },
                        chevron or HorizontalSpan:new{ width = 0 },
                    },
                },
            },
        },
    }
    -- The arrows sit in fixed slots at the right edge, so rows line up.
    local slots = HorizontalGroup:new{}
    local up_slot = CenterContainer:new{
        dimen = Geom:new{ w = arrow_w, h = row_h },
        item.can_up and arrow("chevron-up.svg", "↑") or HorizontalSpan:new{ width = icon_sz },
    }
    local down_slot = CenterContainer:new{
        dimen = Geom:new{ w = arrow_w, h = row_h },
        item.can_down and arrow("chevron-down.svg", "↓") or HorizontalSpan:new{ width = icon_sz },
    }
    slots[#slots + 1] = up_slot
    slots[#slots + 1] = down_slot
    group[#group + 1] = RightContainer:new{ dimen = Geom:new{ w = w, h = row_h }, slots }
    return KoboldWidgets.fixed(w, row_h, group)
end

-- One row, exactly w x row_h.
local function buildRow(item, w)
    local row_h    = rowHeight()
    local icon_sz  = scale(26)
    local icon_gap = scale(18)
    local gap      = scale(12)
    local chev_sz  = scale(22)
    local color    = item.disabled and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_BLACK

    -- Right side: value text, then a chevron (submenu), the on / off glyph
    -- (toggle) or a check (radio).
    local right = HorizontalGroup:new{}
    local right_w = 0
    local function addRight(widget, width, spaced)
        if spaced and #right > 0 then
            right[#right + 1] = HorizontalSpan:new{ width = gap }
            right_w = right_w + gap
        end
        right[#right + 1] = widget
        right_w = right_w + width
    end
    if item.value and item.kind ~= "toggle" then
        local value = TextWidget:new{
            text = item.value, face = KoboldWidgets.face(16),
            fgcolor = KoboldWidgets.subtitleColor(),
            max_width = math.floor(w * 0.34),
        }
        addRight(value, value:getSize().w)
    end
    if item.kind == "submenu" then
        local chevron = loadSvg("chevron-right.svg", chev_sz, color)
        if chevron then addRight(chevron, chev_sz, true) end
    elseif item.kind == "toggle" then
        -- The same switch glyphs scrubber_settings uses: on is black, off gray.
        local on
        if item.get then
            on = item.get()
        else
            on = KoboldPrefs.get(item.setting)
            if on == nil then on = item.default end
        end
        local glyph = TextWidget:new{
            text = on and "\u{EC20}" or "\u{EC21}",
            face = Font:getFace("cfont", scale(24)),
            fgcolor = item.disabled and Blitbuffer.COLOR_DARK_GRAY
                or (on and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_DARK_GRAY),
        }
        addRight(glyph, glyph:getSize().w, true)
    elseif item.kind == "radio" and item.checked then
        local check = TextWidget:new{
            text = "✓", face = Font:getFace("cfont", scale(22)), bold = true, fgcolor = color,
        }
        addRight(check, check:getSize().w, true)
    end

    -- Left side: icon (blank space when the file is missing, so the labels
    -- stay aligned; radio rows have no icon) and the label.
    local left = HorizontalGroup:new{}
    local lead_w = 0
    if item.kind ~= "radio" then
        left[#left + 1] = loadSvg(item.icon, icon_sz, color) or HorizontalSpan:new{ width = icon_sz }
        left[#left + 1] = HorizontalSpan:new{ width = icon_gap }
        lead_w = icon_sz + icon_gap
    end
    local text_w = w - lead_w - (right_w > 0 and right_w + gap or 0)
    left[#left + 1] = TextWidget:new{
        text = item.text, face = KoboldWidgets.face(18),
        bold = item.bold or false, fgcolor = color, max_width = text_w,
    }

    local group = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = row_h },
        LeftContainer:new{ dimen = Geom:new{ w = w, h = row_h }, left },
    }
    if #right > 0 then
        group[#group + 1] = RightContainer:new{ dimen = Geom:new{ w = w, h = row_h }, right }
    end
    return KoboldWidgets.fixed(w, row_h, group)
end

local function buildSection(item, w)
    local h = sectionHeight()
    return KoboldWidgets.fixed(w, h, LeftContainer:new{
        dimen = Geom:new{ w = w, h = h },
        TextWidget:new{
            text = item.section, face = KoboldWidgets.face(14),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = w,
        },
    })
end

function KoboldSettings:build()
    local W, H = self.dimen.w, self.dimen.h
    local margin    = scale(30)
    local content_w = W - 2 * margin
    local status_h  = scale(40)
    local header_h  = scale(64)
    local line_h    = scale(3)
    local title_sz  = scale(26)
    local back_sz   = scale(28)
    local close_sz  = scale(26)
    local bar_w     = scale(24)
    local bar_gap   = scale(12)

    local data  = self:getPageDefinition(self.current_view)
    local items = data.items or {}
    local has_back = #self.history > 0

    -- Screen y where the rows start, and the room they have.
    local head_y   = margin + status_h
    local rows_top = head_y + header_h + line_h
    local max_h    = H - rows_top - margin

    -- Pages. With one page the rows use the full width; with more, the
    -- page bar takes the right edge.
    self.page_starts = paginate(items, max_h)
    local list_w = content_w
    if #self.page_starts > 1 then list_w = content_w - bar_w - bar_gap end
    self.pages = #self.page_starts
    self.page = math.max(1, math.min(self.page or 1, self.pages))

    local first = self.page_starts[self.page]
    local last = (self.page_starts[self.page + 1] or (#items + 1)) - 1

    local list = VerticalGroup:new{ align = "left" }
    local hits = {}
    local cy = rows_top
    for i = first, last do
        local item = items[i]
        if item.section then
            list[#list + 1] = buildSection(item, list_w)
            cy = cy + sectionHeight()
        else
            if item.kind == "chip" then
                list[#list + 1] = buildChipRow(item, list_w)
                local z = chipZones(list_w)
                for zone_name, zr in pairs(z) do
                    hits[#hits + 1] = {
                        rect = Geom:new{ x = margin + zr.x, y = cy, w = zr.w, h = rowHeight() },
                        item = item, zone = zone_name,
                    }
                end
            else
                list[#list + 1] = buildRow(item, list_w)
            end
            if item.kind ~= "chip" and not item.disabled then
                hits[#hits + 1] = {
                    rect = Geom:new{ x = 0, y = cy, w = margin + list_w, h = rowHeight() },
                    item = item,
                }
            end
            cy = cy + rowHeight()
        end
    end
    self.hits = hits

    self.bar = { w = bar_w, h = max_h, page = self.page, pages = self.pages, arrow = scale(22) }
    self.bar_rect = Geom:new{ x = margin + list_w, y = rows_top, w = bar_w + bar_gap + margin, h = max_h }

    -- Header: [back] title ........ [X]
    local close_hit = scale(64)
    self.close_rect = Geom:new{ x = W - margin - close_hit, y = head_y, w = close_hit + margin, h = header_h }
    -- The whole title line goes back (everything left of the X), not only the arrow.
    self.back_rect = has_back and Geom:new{ x = 0, y = head_y, w = self.close_rect.x, h = header_h } or nil

    local title_group = HorizontalGroup:new{}
    if has_back then
        title_group[#title_group + 1] = loadSvg("chevron-left.svg", back_sz)
            or TextWidget:new{ text = "‹", face = KoboldWidgets.face(30) }
        title_group[#title_group + 1] = HorizontalSpan:new{ width = scale(12) }
    end
    title_group[#title_group + 1] = TextWidget:new{
        text = data.title or _("Settings"), face = KoboldWidgets.face(24), bold = true,
        max_width = content_w - close_sz - scale(80),
    }
    local header = OverlapGroup:new{
        dimen = Geom:new{ w = content_w, h = header_h },
        LeftContainer:new{ dimen = Geom:new{ w = content_w, h = header_h }, title_group },
        RightContainer:new{
            dimen = Geom:new{ w = content_w, h = header_h },
            KoboldWidgets.icon("close", close_sz),
        },
    }

    -- Status bar and header keep the side margin; the divider below them runs
    -- edge to edge; the rows start at the side margin again.
    local top = FrameContainer:new{
        bordersize = 0, padding = 0,
        padding_top = margin, padding_left = margin, padding_right = margin,
        VerticalGroup:new{ align = "left", self.status_bar, header },
    }
    local divider = LineWidget:new{
        dimen = Geom:new{ w = W, h = line_h },
        background = Blitbuffer.COLOR_LIGHT_GRAY,
    }
    local rows = FrameContainer:new{
        bordersize = 0, padding = 0, padding_left = margin,
        self.pages > 1 and HorizontalGroup:new{
            align = "top",
            KoboldWidgets.fixed(list_w, max_h, list),
            HorizontalSpan:new{ width = bar_gap },
            KoboldWidgets.pageBar(self.bar),
        } or KoboldWidgets.fixed(list_w, max_h, list),
    }

    -- Plain white, edge to edge: no border, radius or shadow.
    return FrameContainer:new{
        width = W, height = H,
        bordersize = 0, padding = 0, margin = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{ align = "left", top, divider, rows },
    }
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

function KoboldSettings:goToPage(page)
    page = math.max(1, math.min(self.pages or 1, page))
    if page == self.page then return end
    self.page = page
    self:refresh()
end

function KoboldSettings:onSettingsNextPage() self:goToPage(self.page + 1) return true end
function KoboldSettings:onSettingsPrevPage() self:goToPage(self.page - 1) return true end

-- Hardware Back key: one level up, or close from the root.
function KoboldSettings:onBack()
    self:popView()
    return true
end

-- Runs what a tapped row does.
function KoboldSettings:activate(item, zone)
    local done = function() self:refresh() end
    if item.kind == "chip" then
        if zone == "toggle" then
            local ok, why = KoboldChips.setEnabled(item.chip_id, not item.enabled)
            if not ok and why == "last" then
                UIManager:show(InfoMessage:new{ text = _("At least one chip must stay on.") })
            elseif not ok and why == "max" then
                UIManager:show(InfoMessage:new{
                    text = string.format(_("Maximum of %d chips on. Turn one off first."), KoboldChips.MAX),
                })
            end
            done()
        elseif zone == "up" and item.can_up then
            KoboldChips.move(item.chip_id, -1)
            done()
        elseif zone == "down" and item.can_down then
            KoboldChips.move(item.chip_id, 1)
            done()
        elseif zone == "text" then
            self:pushView("chip:" .. item.chip_id)
        end
    elseif item.kind == "submenu" then
        if item.target then self:pushView(item.target) end
    elseif item.kind == "toggle" then
        if item.get and item.set then
            item.set(not item.get())
        else
            local on = KoboldPrefs.get(item.setting)
            if on == nil then on = item.default end
            KoboldPrefs.set(item.setting, not on)
        end
        done()
    elseif item.kind == "radio" then
        if item.on_pick then item.on_pick() end
        self:popView()
    elseif item.kind == "action" then
        if item.callback then item.callback() end
    end
end

function KoboldSettings:itemAt(pos)
    for _i, hit in ipairs(self.hits or {}) do
        if pos:intersectWith(hit.rect) then return hit.item, hit.zone end
    end
    return nil
end

function KoboldSettings:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.history = {}
    self.current_view = "root"
    self.page = 1
    if Device:hasKeys() then
        self.key_events = {
            Back = { { Device.input.group.Back } },
            SettingsNextPage = { { Device.input.group.PgFwd } },
            SettingsPrevPage = { { Device.input.group.PgBack } },
        }
    end
    self.start_revision = KoboldPrefs.revision()

    -- The shared status bar, made once and reused on every redraw.
    local margin = scale(30)
    self.status_bar = KoboldWidgets.statusBarFrame(self, margin, W - 2 * margin, scale(40))
    self[1] = self:build()

    -- One tap zone for the whole screen; the handler finds the button or row.
    KoboldTaps.add(self, "KoboldSettingsTap", 0, 0, W, H, function(ges)
        if self.back_rect and ges.pos:intersectWith(self.back_rect) then
            self:popView()
            return
        end
        if ges.pos:intersectWith(self.close_rect) then
            self:onClose()
            return
        end
        if self.pages > 1 and ges.pos:intersectWith(self.bar_rect) then
            local page = KoboldWidgets.pageBarTarget(ges.pos.y - self.bar_rect.y, self.bar)
            if page then self:goToPage(page) end
            return
        end
        local item, zone = self:itemAt(ges.pos)
        if item then self:activate(item, zone) end
    end)

    self:registerTouchZones({
        -- Swipe up for the next page, down for the previous one.
        {
            id = "KoboldSettingsSwipe",
            ges = "swipe",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                if ges.direction == "north" then
                    self:goToPage(self.page + 1)
                elseif ges.direction == "south" then
                    self:goToPage(self.page - 1)
                else
                    return false
                end
                return true
            end,
        },
        -- Hold a row for its description.
        {
            id = "KoboldSettingsHold",
            ges = "hold",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            handler = function(ges)
                local item = self:itemAt(ges.pos)
                if item and item.desc then
                    UIManager:show(InfoMessage:new{
                        text = item.text .. "\n\n" .. item.desc,
                        show_icon = false,
                        width = math.floor(Screen:getWidth() * 0.75),
                    })
                    return true
                end
                return false
            end,
        },
    })
end

function KoboldSettings:refresh()
    if self.closed then return end
    self[1] = self:build()
    UIManager:setDirty(self, "ui", self.dimen)
end

-- The X and the last Back close the whole window. After a change the screen
-- below refreshes in full, clearing what the quick redraws left behind.
function KoboldSettings:onClose()
    if self.closed then return true end
    self.closed = true
    if KoboldPrefs.revision() ~= self.start_revision then
        UIManager:close(self, "full")
    else
        UIManager:close(self, "ui", self.dimen)
    end
    return true
end

function KoboldSettings.show()
    local w = KoboldSettings:new{}
    UIManager:show(w, "ui", w.dimen)
    return w
end

return KoboldSettings
