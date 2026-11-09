-- main.lua — KiKome (internal module name: kobold)
-- Plugin entry point. Adds a "KiKome" entry to the file browser main menu
-- and a "KiKome" option to the "Start with" menu. When that option is
-- selected, KiKome opens right away, and again at every boot. Nothing else is
-- changed.

-- The plugin's facts live in _meta.lua (the file KOReader also reads). The
-- rest of KiKome asks for them as require("kobold.meta"); this points that
-- name at _meta.lua, so there is no second meta file.
do
    local dir = (debug.getinfo(1, "S").source or ""):match("^@(.*)/main%.lua$")
    if dir and not package.loaded["kobold.meta"] then
        package.preload["kobold.meta"] = function() return dofile(dir .. "/_meta.lua") end
    end
end

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager       = require("ui/uimanager")
local _               = require("kobold.i18n")

local START_WITH_VALUE = "kobold_home"
local boot_handled = false  -- set once per KOReader session, on the file browser

local Kobold = WidgetContainer:extend{
    name = "kobold",
}

-- True when a KiKome screen (Home, My Books, ...) is already in the window stack.
local function koboldScreenShown()
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if w and w.kobold_tab then return true end
    end
    return false
end

-- Adds the "KiKome" radio item to the "Start with" submenu. Patched once
-- per session. The native items are left untouched; each radio item reads the
-- setting directly, so the checkmarks stay in sync.
local function patchStartWithMenu()
    local ok, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not ok or not FileManagerMenu then return end
    if FileManagerMenu._kobold_startwith_patched then return end

    local orig_fn = FileManagerMenu.getStartWithMenuTable
    if not orig_fn then return end
    FileManagerMenu._kobold_startwith_patched = true

    FileManagerMenu.getStartWithMenuTable = function(fmm_self)
        local result = orig_fn(fmm_self)
        local sub = result.sub_item_table
        if type(sub) ~= "table" then return result end

        local item_text = _("KiKome")
        for _i, item in ipairs(sub) do
            if item.text == item_text then return result end
        end

        table.insert(sub, math.max(1, #sub), {
            text = item_text,
            checked_func = function()
                return G_reader_settings:readSetting("start_with") == START_WITH_VALUE
            end,
            callback = function(touchmenu_instance)
                G_reader_settings:saveSetting("start_with", START_WITH_VALUE)
                G_reader_settings:flush()
                -- Takes effect now, without restarting KOReader (as Bookshelf does):
                -- the menu closes first (a radio item does not close it by itself,
                -- and a screen shown above it would leave it orphaned in the stack),
                -- then KiKome opens over the file browser. Books opened from it
                -- then return to it, as after a restart.
                if touchmenu_instance and touchmenu_instance.closeMenu then
                    pcall(function() touchmenu_instance:closeMenu() end)
                end
                if not koboldScreenShown() then
                    local plugin = fmm_self and fmm_self.ui and fmm_self.ui.kobold
                    if plugin and plugin.showHome then
                        pcall(function() plugin:showHome() end)
                    end
                end
            end,
            radio = true,
        })

        local orig_text_func = result.text_func
        result.text_func = function()
            if G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
                return _("Start with") .. ": " .. item_text
            end
            return orig_text_func and orig_text_func() or _("Start with")
        end
        return result
    end
end

-- Every KiKome window in KOReader's window stack: the screens (Home, My
-- Books, ...) and whatever sits on them (book details, menus, a toast). They
-- are all named "kobold_*". Also forgets the book parked under them.
local function closeAllKoboldWindows()
    local found = {}
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if w and (w.kobold_tab or (type(w.name) == "string" and w.name:sub(1, 7) == "kobold_")) then
            found[#found + 1] = w
        end
    end
    for i = #found, 1, -1 do
        local w = found[i]
        pcall(function() UIManager:close(w) end)
    end
    local Park = package.loaded["kobold.ui.park"]
    if Park then pcall(Park.noteRealClose) end
    local Session = package.loaded["kobold.ui.session"]
    if Session then pcall(Session.take) end
end

-- KOReader quits when its window stack is empty. Its Exit closes the file
-- browser (or the book) and nothing else, so the KiKome screens left on top
-- kept KOReader alive until "Exit KiKome" closed them. Exit and Restart (the
-- file browser menu and the reader menu) now close KiKome first. Patched once
-- per session; a menu without exitOrRestart is left as it is.
local function patchExitMenus()
    for _i, module_name in ipairs({ "apps/filemanager/filemanagermenu", "apps/reader/modules/readermenu" }) do
        local ok, Menu = pcall(require, module_name)
        if ok and type(Menu) == "table" and type(Menu.exitOrRestart) == "function"
                and not Menu._kobold_exit_patched then
            Menu._kobold_exit_patched = true
            local orig = Menu.exitOrRestart
            Menu.exitOrRestart = function(menu_self, ...)
                pcall(closeAllKoboldWindows)
                return orig(menu_self, ...)
            end
        end
    end
end

-- This plugin was called Booko before. Moves its saved settings to the new
-- names once, so the Start with choice and My Books filters are kept.
local function migrateOldSettings()
    if not G_reader_settings then return end
    if G_reader_settings:readSetting("start_with") == "boo" .. "ko_home" then
        G_reader_settings:saveSetting("start_with", START_WITH_VALUE)
    end
    for _i, suffix in ipairs({ "mybooks_filter", "mybooks_sort", "mybooks_group_sort" }) do
        local old_key = "boo" .. "ko_" .. suffix
        local old = G_reader_settings:readSetting(old_key)
        if old ~= nil then
            if G_reader_settings:readSetting("kobold_" .. suffix) == nil then
                G_reader_settings:saveSetting("kobold_" .. suffix, old)
            end
            G_reader_settings:delSetting(old_key)
        end
    end
end

function Kobold:init()
    migrateOldSettings()
    patchStartWithMenu()
    patchExitMenus()
    self:_extendMenuOrder()
    -- Windows hidden under Kobold must not refresh the screen (see the module).
    pcall(function() require("kobold.ui.repaint_guard").install() end)

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- In a book: the File browser tab of the reader menu parks the book under
    -- KiKome instead of closing it (see kobold/ui/park.lua). The menu may
    -- build its items a moment later, so the tab is wired again after the
    -- reader is shown.
    if self.ui and self.ui.document then
        self:_wireFastFileBrowserTab()
        UIManager:nextTick(function() self:_wireFastFileBrowserTab(true) end)
    end

    -- The real close of a parked book builds a new file browser, which runs
    -- this init again: park.lua puts the screen back itself, so nothing else
    -- is done here.
    if self.ui and not self.ui.document then
        local Park = package.loaded["kobold.ui.park"]
        if Park and Park.isFinishing() then
            boot_handled = true
            return
        end
    end

    -- Back from a book that was opened from Kobold: closing the book builds a
    -- new file browser, which runs this init again. Reopen the Kobold screen
    -- the book was opened from, on top of it.
    if self.ui and not self.ui.document then
        local back = require("kobold.ui.session").take()
        if back then
            boot_handled = true
            -- The screen parked under the book is lifted above this new file
            -- browser as it is shown, so it appears with no rebuild; its data
            -- (progress, last book) is refreshed just after. Without one, the
            -- tab is built fresh. Both use a full refresh, which clears what
            -- the book page left on the screen.
            local Session = require("kobold.ui.session")
            self:showWithFileManager(function()
                local parked = back.screen
                require("kobold.ui.transition").close()
                require("kobold.ui.reader").opened()
                if parked and Session.raise(parked) then
                    -- KOReader runs waiting tasks before it repaints, so
                    -- the screen is painted first here; only then is its
                    -- data read again (that takes a moment).
                    UIManager:nextTick(function()
                        UIManager:forceRePaint()
                        if parked.onKoboldReturn then parked:onKoboldReturn() end
                    end)
                else
                    self:showTab(back.tab, back.state, "full")
                end
            end)
            return
        end
    end

    -- Boot-time open. Runs only in the file browser (no document open), and
    -- only for the first Kobold init of the session, so returning to the file
    -- browser some other way does not reopen KiKome.
    if self.ui and not self.ui.document and not boot_handled then
        boot_handled = true
        if G_reader_settings:readSetting("start_with") == START_WITH_VALUE then
            self:showWithFileManager(function()
                if not self:showHome() then
                    -- Turn the boot open off so a broken screen can't reopen
                    -- on every start. The user can select KiKome again.
                    G_reader_settings:saveSetting("start_with", "filemanager")
                end
            end)
        end
    end
end

-- Runs `open` (which shows a Kobold screen) right when KOReader puts this
-- file browser on screen, in the same step, so the browser is never painted
-- before Kobold covers it (it used to flash for a moment when a book
-- closed). UIManager:show is wrapped once for that; the wrapper steps aside
-- after use. If the browser is shown some other way, `open` still runs on
-- the next tick.
function Kobold:showWithFileManager(open)
    local fm = self.ui
    local done = false
    local function run()
        if done then return end
        done = true
        open()
    end
    local orig_show = UIManager.show
    local wrapper
    wrapper = function(um, widget, ...)
        local result = orig_show(um, widget, ...)
        if widget == fm and not done then
            -- Unwrap only if nothing wrapped show after us.
            if UIManager.show == wrapper then UIManager.show = orig_show end
            run()
        end
        return result
    end
    UIManager.show = wrapper
    UIManager:scheduleIn(0, function()
        if UIManager.show == wrapper then UIManager.show = orig_show end
        run()
    end)
end

-- In the reader: the book is closing. When it was opened from Kobold (so
-- Kobold comes back), show the "Closing" pill while KOReader closes it.
function Kobold:onCloseDocument()
    local Session = require("kobold.ui.session")
    -- A parked book that is really closing (see park.lua) shows no pill: the
    -- screen is already on show, or another book is opening.
    local Park = package.loaded["kobold.ui.park"]
    if Park then
        Park.noteRealClose()
        if Park.isFinishing() or Park.isSwitching() then return end
    end
    if Session.returning() then
        local _ = require("kobold.i18n")
        require("kobold.ui.transition").show(_("Closing"))
    end
end

-- KOReader's "Exit" event (the Exit KOReader action of gestures and profiles):
-- KiKome closes its windows so KOReader can quit. The event goes on to KOReader.
function Kobold:onExit()
    pcall(closeAllKoboldWindows)
end

-- KOReader's own "File browser" action (a gesture or the quick menu send
-- the Home event): in a book opened from KiKome the book is parked under
-- KiKome instead of being closed. Anything else falls through to KOReader.
function Kobold:onHome()
    if not (self.ui and self.ui.document) then return end
    local ok, Park = pcall(require, "kobold.ui.park")
    if not ok then return end
    if Park.isParked() then return true end  -- already parked: nothing to close
    if Park.park(self.ui) then return true end
end

-- Replaces the callback of the reader menu's "File browser" tab with one
-- that parks the book when it can, and runs KOReader's own otherwise.
function Kobold:_wireFastFileBrowserTab(force)
    local menu = self.ui and self.ui.menu
    if not (self.ui and self.ui.document and menu) then return end
    if menu._kobold_fm_wrapper and not force then return end
    local items = menu.menu_items
    local item = items and items.filemanager
    if not (item and item.callback) then return end
    if item.callback == menu._kobold_fm_wrapper then return end
    local plugin = self
    local prev = item.callback
    local wrapper = function(...)
        local ok, Park = pcall(require, "kobold.ui.park")
        if ok and Park.canPark(plugin.ui) then
            if menu.onTapCloseMenu then menu:onTapCloseMenu() end
            if Park.park(plugin.ui) then return end
        end
        return prev(...)
    end
    item.callback = wrapper
    menu._kobold_fm_wrapper = wrapper
end

-- The reader menu has built its items by now (or is about to be shown).
function Kobold:onReaderReady()
    self:_wireFastFileBrowserTab(true)
    -- A book whose page count was put in Metadata > More details gets KOReader's
    -- stable page numbers made to match it (see kobold/data/stable_pages.lua).
    -- Unless the book was set to KOReader's numbering (Edit > Book settings >
    -- Stable pages): apply() does nothing then. A moment later, when the book
    -- has finished laying itself out; a failure is only logged.
    do
        local ui = self.ui
        UIManager:scheduleIn(0.8, function()
            if not (ui and ui.document) then return end
            local ok, status, size, _chars, changed = pcall(function()
                return require("kobold.data.stable_pages").apply(ui)
            end)
            if not ok then
                require("logger").warn("KiKome: stable pages failed:", tostring(status))
            elseif changed then
                require("kobold.data.stable_pages").announce(ui, status, size)
            end
        end)
    end
    -- "Show in book" from the annotations list of Book Details: the book is
    -- open now, so it can jump to the annotation it was opened for.
    local Reader = package.loaded["kobold.ui.reader"]
    if Reader and Reader.runPendingGoto then Reader.runPendingGoto(self.ui) end
end

function Kobold:onShowReaderMenu()
    UIManager:nextTick(function() self:_wireFastFileBrowserTab(true) end)
end

-- KiKome's entry in KOReader's menu. The two entries are the same everywhere.
--   File browser: KiKome's own tab in the top menu bar, like Bookshelf's: its icon
--   sits next to the others and the two entries are the rows inside it. The tab is
--   placed by _extendMenuOrder (below), right after the file browser's Settings
--   tab, so it is not buried in the Tools tab.
--   In a book: one row, "KiKome", at the top of the Tools tab, that opens a submenu
--   with the two entries (not inside More tools). It has a `sorting_hint`: an entry
--   without one is placed nowhere, and KOReader drops it, marked "NEW:", into the
--   first tab of the menu. The reader menu has no order of ours for the tab.
function Kobold:addToMainMenu(menu_items)
    -- Unicode icons (a glyph from the icon font, as Bookshelf draws its own
    -- status icons), not SVG files: the row text is drawn with the font, so
    -- no image loading is involved.
    local open_item = {
        text = "\xee\xb3\x99  " .. _("Open KiKome Home"),
        -- the divider: a line under this row, between the two entries
        separator = true,
        callback = function()
            self:showHome()
        end,
    }
    local config_item = {
        text = "⚙ " .. _("Configurations"),
        callback = function()
            require("kobold.ui.settings").show()
        end,
    }

    if self.ui and self.ui.document then
        menu_items.kobold = {
            text = _("KiKome"),
            sorting_hint = "tools",
            sub_item_table = { open_item, config_item },
        }
        return
    end

    menu_items.kobold_tab = { icon = "book.opened", text = _("KiKome") }
    menu_items.kobold_open = open_item
    menu_items.kobold_configurations = config_item
end

-- Puts the KiKome tab into the file browser's top menu bar, in the order
-- KOReader uses for its tabs. Idempotent: the tab is added once per session.
function Kobold:_extendMenuOrder()
    local ok, order = pcall(require, "ui/elements/filemanager_menu_order")
    if not ok or type(order) ~= "table"
       or type(order["KOMenu:menu_buttons"]) ~= "table" then
        return
    end
    for _i, id in ipairs(order["KOMenu:menu_buttons"]) do
        if id == "kobold_tab" then return end
    end
    -- Position 2: filemanager_settings stays at [1], as in Bookshelf.
    table.insert(order["KOMenu:menu_buttons"], 2, "kobold_tab")
    order.kobold_tab = { "kobold_open", "kobold_configurations" }
end

-- Opens KiKome. Errors are caught and shown as a message so a broken
-- screen can't crash KOReader (the menu path and the boot path both use this).
function Kobold:showHome()
    return self:showTab("home")
end

-- Opens the Kobold screen for `tab` ("home", "books" or "more"), with an
-- optional saved state to restore and e-ink refresh type (see router.lua).
-- Errors are shown, not raised.
function Kobold:showTab(tab, state, refresh)
    -- Opened over a book: close the book first, the way KOReader's Home
    -- does. The file browser that replaces it opens Kobold (see init), and
    -- Kobold then has the file browser's menus to work with.
    local ReaderUI = package.loaded["apps/reader/readerui"]
    if ReaderUI and ReaderUI.instance and ReaderUI.instance.onHome then
        -- The screen of this tab is waiting under the book: park the book.
        local screen = require("kobold.ui.session").parkedScreen()
        if screen and screen.kobold_tab == tab then
            local ok_park, Park = pcall(require, "kobold.ui.park")
            if ok_park and Park.park(ReaderUI.instance) then return true end
        end
        require("kobold.ui.session").rememberTab(tab, state)
        local closed = pcall(function() ReaderUI.instance:onHome() end)
        if closed then return true end
        require("kobold.ui.session").take()
    end
    local ok, err = pcall(function()
        require("kobold.ui.router").show(tab, nil, state, refresh)
    end)
    if not ok then
        require("kobold.ui.toast").error(_("KiKome failed to open.") .. "\n" .. tostring(err), { timeout = 6 })
    else
        self:_warmUp()
    end
    return ok
end

-- Once per session, after the first KiKome screen is up: loads the other
-- screens' code a little at a time while nobody is touching anything, so the
-- first visit to My Books, Book Details, the menus or Settings does not have
-- to read and compile it then. One module per step, stopping at once when
-- the device is being used.
local warmed = false
local WARM_MODULES = {
    "kobold.ui.option_sheet", "kobold.ui.book_menu", "kobold.ui.book_details",
    "kobold.ui.mybooks", "kobold.ui.view_sheet", "kobold.ui.settings",
}
function Kobold:_warmUp()
    if warmed then return end
    warmed = true
    local i = 0
    local function step()
        i = i + 1
        local name = WARM_MODULES[i]
        if not name then return end
        -- Busy (a book is opening, a touch just happened): try this one later.
        local Park = package.loaded["kobold.ui.park"]
        local busy = Park and (Park.isFinishing() or Park.isSwitching())
        if busy then i = i - 1 else pcall(require, name) end
        UIManager:scheduleIn(busy and 2 or 0.6, step)
    end
    UIManager:scheduleIn(2.5, step)
end

return Kobold
