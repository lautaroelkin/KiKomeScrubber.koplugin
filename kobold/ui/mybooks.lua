-- kobold/ui/mybooks.lua — Kobold
-- My Books screen, laid out like the e-reader's own library: the shared status bar, the
-- Books / Authors / Series / Collections / Genres / Files tabs (which of them
-- are on, and in what order, is set in Settings > Library options > Tabs; see
-- data/tabs.lua) over a light rule, a row of
-- pills, then a page of rows (a thin separator under each folder row). Swipe the list
-- up or down, or use the side bar, to move through the list. Bottom nav is shared with the other
-- screens.
--
-- Views:
--   Books tab         book rows; the adjust button opens the View sheet
--                     (view_sheet.lua, the same as on Home): Grid / List, and
--                     Sort & Filter (status, sort, A-Z, language)
--   other tabs        author / series / collection / genre rows; adjust has
--                     Grid / List and A-Z / Z-A
--   a tapped group    that group's book rows, with a back pill
-- A book row opens the book; its "…" opens KOReader's own book menu (status,
-- delete, and so on), the same menu as a long-press in the file browser.
-- A long-press on a collection or a folder opens Kobold's own row of options
-- (book_menu.lua): rename, add books, remove / set as home, delete; renaming
-- uses rename_prompt.lua and every confirmation uses confirm_sheet.lua.
--
-- Split in three files: this one (the screen: layout, tabs, lists, grid, taps,
-- selection mode, the More menu), mybooks_collections.lua (what collections
-- can do) and mybooks_files.lua (the Files tab: folders, copy / move / delete).

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local InputDialog     = require("ui/widget/inputdialog")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local OptionSheet     = require("kobold.ui.option_sheet")
local ViewSheet       = require("kobold.ui.view_sheet")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local _               = require("kobold.i18n")
local lfs             = require("libs/libkoreader-lfs")
local Clipboard       = require("kobold.data.clipboard")
local KoboldCovers    = require("kobold.data.covers")
local KoboldPrefs     = require("kobold.data.prefs")
local KoboldLibrary   = require("kobold.data.library")
local KoboldMyBooksData = require("kobold.data.mybooks")
local BookLang        = require("kobold.data.booklang")
local Genres          = require("kobold.data.genres")
local KoboldTabs      = require("kobold.data.tabs")
local KoboldNav       = require("kobold.ui.nav")
local KoboldMetrics   = require("kobold.ui.metrics")
local CoverBadge      = require("kobold.ui.cover_badge")
local KoboldReader    = require("kobold.ui.reader")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local Rounded         = require("kobold.ui.rounded")
local Toast           = require("kobold.ui.toast")

local Screen = Device.screen

local COVER_RATIO = 1.5  -- height / width of a book cover
local PAGE_TURNS_PER_FLASH = 10  -- see refreshList

-- Filter and sort choices are kept between sessions under these settings keys.
local FILTER_KEY     = "kobold_mybooks_filter"      -- status: all / reading / unread / finished
local SORT_KEY       = "kobold_mybooks_sort"        -- recent / oldest / added_newest / added_oldest
local ALPHA_KEY      = "kobold_mybooks_alpha"       -- az / za
local LANG_KEY       = "kobold_mybooks_lang"        -- a language code, e.g. "ES"
local GROUP_SORT_KEY = "kobold_mybooks_group_sort"
local VIEW_KEY       = "kobold_mybooks_view"  -- Books tab: "list" or "grid"

-- Older versions saved one sort that also held the title order; its new homes.
local OLD_SORTS = {
    opened_desc = { sort = "recent" },
    added_desc  = {},
    added_asc   = { sort = "added_oldest" },
    title_asc   = { alpha = "az" },
    title_desc  = { alpha = "za" },
}

-- Tabs shown: the ones that are on in Settings > Library options > Tabs, in the
-- order set there. { id, text }
local function visibleTabs()
    local out = {}
    for _i, tab in ipairs(KoboldTabs.enabledList()) do
        out[#out + 1] = { id = tab.id, text = tab.label }
    end
    return out
end

local fileChooser  -- defined with the book menu, used by the Files tab too

local KoboldMyBooks = InputContainer:extend{
    -- Not modal: KOReader menus and dialogs (also non-modal) must be able to
    -- open on top of this screen.
    covers_fullscreen = true,
    -- Shows book covers: asks the e-ink controller to dither its refreshes,
    -- so cover images come out smooth instead of banded.
    dithered = true,
    name = "kobold_mybooks",
    kobold_tab = "books",
}
KoboldWidgets.addScreenEvents(KoboldMyBooks)

-- Background of the pills: a pale gray, so black text on it stays easy to
-- read. Falls back to COLOR_LIGHT_GRAY if Color8 is missing.
local function pillColor()
    local ok, c = pcall(function() return Blitbuffer.Color8(0xDD) end)
    if ok and c then return c end
    return Blitbuffer.COLOR_LIGHT_GRAY
end

local function readChoice(key, valid, default)
    local v = G_reader_settings and G_reader_settings:readSetting(key)
    for _i, id in ipairs(valid) do
        if id == v then return v end
    end
    return default
end

-- Saves a choice; nil removes it (nothing chosen).
local function saveChoice(key, value)
    if not G_reader_settings then return end
    if value == nil then G_reader_settings:delSetting(key) else G_reader_settings:saveSetting(key, value) end
end

-- The saved sort and alphabetical order, with the older single sort turned
-- into the two choices of today.
local function loadSort()
    local stored = G_reader_settings and G_reader_settings:readSetting(SORT_KEY)
    local alpha = readChoice(ALPHA_KEY, { "az", "za" }, nil)
    local old = OLD_SORTS[stored]
    if old then
        local sort = old.sort
        alpha = old.alpha or alpha
        saveChoice(SORT_KEY, sort)
        saveChoice(ALPHA_KEY, alpha)
        return sort, alpha
    end
    return readChoice(SORT_KEY, KoboldMyBooksData.VIEW_SORTS, nil), alpha
end

local function countText(n)
    if n == 1 then return _("1 book") end
    return n .. _(" books")
end

-- Index of the rectangle in `hits` that contains point `pos`, or nil.
local function hitIndex(hits, pos)
    for i, r in ipairs(hits or {}) do
        if pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h then
            return i
        end
    end
    return nil
end

-- Rows per page chosen in Settings > Library, or nil for Automatic.
local function rowsPref(key, lo, hi)
    local ok, v = pcall(KoboldPrefs.get, key)
    v = ok and tonumber(v) or nil
    if not v then return nil end
    return math.max(lo, math.min(hi, math.floor(v)))
end

-- Book rows per page (View: list). Automatic works like Home's shelf (see
-- LibraryShelf:fitScale): a row has a natural height; one more row is fitted
-- in by shrinking the rows up to 12%, otherwise the rows keep that height and
-- the last one takes what is left over (the list always ends at the nav bar).
function KoboldMyBooks:listRowsCount(L)
    local n = rowsPref("library_list_rows", 1, 12)
    if n then return n end
    local natural = math.floor(L.W * 0.25)
    local total = L.list_h + L.line_h
    local up = math.max(1, math.ceil(total / (natural + L.line_h)))
    local n = up
    if total / up - L.line_h < natural * 0.88 then n = math.max(1, up - 1) end
    -- never outside what Settings offers for a fixed count
    return math.max(KoboldPrefs.COVER_ROWS_MIN or 3, math.min(KoboldPrefs.COVER_ROWS_MAX or 8, n))
end

-- Rows per page of the grid (View: grid), or nil for Automatic.
function KoboldMyBooks:gridRowsPref()
    return rowsPref("library_grid_rows", 4, 6)
end

-- Everything in the layout that depends on the rows per page (and so on the
-- settings): the list rows, the grid cells and the sizes inside a row. It runs
-- when the screen is made and again when a setting changes.
function KoboldMyBooks:layoutRows()
    local L = self.L
    -- n rows fill the list exactly, with a separator between rows but none
    -- after the last, so the last row ends right at the bottom nav. A slot
    -- is a row plus the separator under it.
    -- Book rows (with covers): the count set in Settings > Library > View: list,
    -- or worked out to fit (see listRowsCount) when that is Automatic.
    -- Group rows (authors etc., text only): as many as fit at 76 px.
    local function rowsOf(n)
        local row_h = math.floor((L.list_h - (n - 1) * L.line_h) / n)
        return n, row_h + L.line_h, row_h
    end
    L.per_page, L.slot_h, L.row_h = rowsOf(self:listRowsCount(L))
    L.gper_page, L.gslot_h, L.grow_h = rowsOf(math.max(1,
        math.floor((L.list_h + L.line_h) / (Screen:scaleBySize(76) + L.line_h))))

    -- Grid (Books tab, grid view): 4 covers a row, as many rows as fit down to
    -- the nav bar. A book cell is just its cover: the read badge and the "..."
    -- button sit on top of it. A series cell has its name and book count
    -- under the cover.
    L.grid_gap_x  = Screen:scaleBySize(18)
    L.grid_gap_y  = Screen:scaleBySize(14)
    -- Room kept free under the grid, so the covers do not sit right on the
    -- nav bar. (The nav's mini cover sticks up about 36 px over the bar; the
    -- old page footer kept 40 px free. Raise this to clear it completely.)
    L.grid_bottom_gap = Screen:scaleBySize(24)
    L.grid_text_gap = Screen:scaleBySize(6)
    L.grid_status_h = TextWidget:new{ text = "Ag", face = KoboldWidgets.face(14) }:getSize().h
    L.grid_dots_h = TextWidget:new{ text = "…", face = KoboldWidgets.face(18), bold = true }:getSize().h
    L.grid_h      = L.list_h - L.grid_bottom_gap
    -- Columns: as many covers as the width allows, but with the height of the
    -- tallest cell (a group card, with its name and count under the cover) in
    -- mind, so that at least two rows always fit. Portrait e-readers get 4, a
    -- big screen or landscape gets more. The same columns serve books and
    -- groups, so the grid does not jump when you change tab.
    L.grid_cols   = KoboldMetrics.gridCols(L.content_w, L.grid_gap_x, L.grid_h, L.grid_gap_y,
        L.grid_text_gap + L.grid_status_h + L.grid_dots_h, 0)
    L.grid_cell_w = math.floor((L.content_w - (L.grid_cols - 1) * L.grid_gap_x) / L.grid_cols)
    -- Cover height, cell height, rows and cells per page for a cell with
    -- `text_h` of text under its cover (0: just the cover).
    local function gridSet(text_h)
        local extra = text_h > 0 and (L.grid_text_gap + text_h) or 0
        local nat_cover = math.floor(L.grid_cell_w * COVER_RATIO)
        local nat_cell = nat_cover + extra
        local gap = L.grid_gap_y
        local avail = L.grid_h + gap
        local fixed = self:gridRowsPref()
        local rows, cover_h
        if fixed then
            -- A number of rows chosen in Settings: the covers take the height
            -- that makes exactly that many fit (each keeps its shape).
            rows = fixed
            cover_h = math.floor((L.grid_h - (rows - 1) * gap) / rows) - extra
        else
            -- Automatic, as on Home (LibraryShelf:fitScale): the covers shrink
            -- by up to 12% when that makes one more row fit; otherwise they
            -- keep their size and the spare height stays empty at the bottom.
            rows = math.floor(avail / (nat_cell + gap))
            cover_h = nat_cover
            local up = math.ceil(avail / (nat_cell + gap))
            if up > rows then
                local sc = (avail / up - gap - extra) / nat_cover
                if sc >= 0.88 and sc < 1 then
                    rows = up
                    cover_h = math.floor((L.grid_h - (rows - 1) * gap) / rows) - extra
                end
            end
        end
        -- At least two rows, as on the e-reader: when full-width covers are
        -- too tall for two, the covers shrink to fit (each still keeps its
        -- shape inside the cell).
        if rows < 2 then
            rows = 2
            cover_h = math.floor((L.grid_h - gap) / 2) - extra
        end
        -- A floor for very short screens, but never one that pushes the last
        -- row under the nav bar: it stops at what MIN_ROWS rows can hold.
        local min_rows = KoboldMetrics.MIN_ROWS
        local room_h = math.floor((L.grid_h - (min_rows - 1) * gap) / min_rows) - extra
        local floor_h = math.max(1, math.min(math.floor(L.grid_cell_w * 0.5), room_h))
        cover_h = math.max(floor_h, cover_h)
        local cell_h = cover_h + extra
        return { cover_h = cover_h, cell_h = cell_h, rows = rows, per_page = L.grid_cols * rows }
    end
    L.grid_books  = gridSet(0)
    L.grid_groups = gridSet(L.grid_status_h + L.grid_dots_h)
    -- The covers are often narrower than their cell: the rows have to fit the
    -- height, so the cover shrinks (it keeps its shape) and the width it frees
    -- would only be empty space between the books. Work the columns out again
    -- from the width the covers really have, so more of them fit across (a few
    -- passes at most: each pass can only add columns).
    local base_gap_x = L.grid_gap_x
    local max_cols = L.grid_cols * 2
    for _pass = 1, 3 do
        local cw = math.floor(L.grid_books.cover_h / COVER_RATIO)
        if cw >= L.grid_cell_w * 0.92 then break end
        local cols = math.min(max_cols, (KoboldMetrics.fitRow(L.content_w, base_gap_x, cw, L.grid_cols)))
        if cols <= L.grid_cols then break end
        L.grid_cols   = cols
        L.grid_cell_w = math.floor((L.content_w - (cols - 1) * base_gap_x) / cols)
        L.grid_books  = gridSet(0)
        L.grid_groups = gridSet(L.grid_status_h + L.grid_dots_h)
    end
    -- What is left over goes between the covers (cells as wide as the covers
    -- are), so a row still spans the whole width, with the first cover at the
    -- left edge and the last one at the right edge.
    do
        local cw = math.min(L.grid_cell_w, math.floor(L.grid_books.cover_h / COVER_RATIO))
        if L.grid_cols > 1 and cw >= 1 and cw < L.grid_cell_w then
            L.grid_cell_w = cw
            L.grid_gap_x = math.max(base_gap_x, math.floor((L.content_w - L.grid_cols * cw) / (L.grid_cols - 1)))
        end
    end
    L.grid_cover_h, L.grid_cell_h = L.grid_books.cover_h, L.grid_books.cell_h
    L.grid_rows, L.grid_per_page = L.grid_books.rows, L.grid_books.per_page
    L.y_grid_end  = L.y_list + L.grid_h

    L.thumb_h  = L.row_h - 2 * L.row_pad
    L.thumb_w  = math.floor(L.thumb_h / COVER_RATIO)
    L.right_w  = math.floor(L.list_w * 0.27)
    L.text_w   = L.list_w - L.thumb_w - 2 * L.col_gap - L.right_w
    -- Titles wrap to at most two lines (this is their height), or one line
    -- when the rows are too short for two lines plus the author.
    local face_title = KoboldWidgets.face(17)
    local two = TextBoxWidget:new{ text = "A\nA", face = face_title, width = L.text_w }
    local one = TextBoxWidget:new{ text = "A", face = face_title, width = L.text_w }
    local author_h = TextWidget:new{ text = "Ag", face = KoboldWidgets.face(14) }:getSize().h
        + Screen:scaleBySize(4)
    -- Room for the series line too (shown for books in a series).
    author_h = author_h + TextWidget:new{ text = "AG", face = KoboldWidgets.face(12) }:getSize().h
        + Screen:scaleBySize(2)
    L.title_max_h = two:getSize().h
    if L.title_max_h + author_h > L.row_h - 2 * L.row_pad then
        L.title_max_h = one:getSize().h
    end
    two:free()
    one:free()
end

function KoboldMyBooks:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }

    if Device:hasKeys() then
        -- Page-turn buttons (on the device or a connected remote) move
        -- through the list like swipes do.
        self.key_events = {
            Close = { { Device.input.group.Back } },
            NextListPage = { { Device.input.group.PgFwd } },
            PrevListPage = { { Device.input.group.PgBack } },
        }
    end

    self.tab        = KoboldTabs.first()
    self.group      = nil  -- the author / series / collection / genre being shown
    self.filter     = readChoice(FILTER_KEY, KoboldMyBooksData.FILTERS, "all")
    self.sort, self.alpha = loadSort()
    local lang = G_reader_settings and G_reader_settings:readSetting(LANG_KEY)
    self.lang       = (type(lang) == "string" and lang ~= "") and lang or nil
    self.group_sort = readChoice(GROUP_SORT_KEY, KoboldMyBooksData.GROUP_SORTS, "name_asc")
    self.view       = readChoice(VIEW_KEY, { "list", "grid" }, "list")
    self.page       = 1
    self.books      = KoboldMyBooksData.getBooks()

    self:setupLayout()

    Clipboard.exitSelect()
    self:hookFileManager()
    self:restoreState(self.restore)
    self:applyList()
    self[1] = self:build()
    self:ensureCovers()
end

-- Everything that depends on the size of the screen: the bands, the rows or
-- grid, and the tap zones (they sit at fixed places). Runs when the screen is
-- made and again, in place, when the screen is rotated (see relayout).
function KoboldMyBooks:setupLayout()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen.w, self.dimen.h = W, H

    -- Fixed layout. Every band has a set height except the list, which takes
    -- what is left between the pills and the bottom nav.
    local bar = KoboldMetrics.statusBar()
    local margin = bar.margin
    local L = {
        W = W, H = H,
        margin     = margin,
        content_w  = W - 2 * margin,
        status_h   = bar.h,
        tabs_gap   = Screen:scaleBySize(12),
        tabs_h     = Screen:scaleBySize(40),
        tab_bar_h  = Screen:scaleBySize(3),   -- black bar under the selected tab
        tab_rule_h = Screen:scaleBySize(2),   -- light rule under all the tabs
        tab_gap    = Screen:scaleBySize(26),
        pills_gap  = Screen:scaleBySize(12),
        pills_h    = Screen:scaleBySize(38),
        pill_gap   = Screen:scaleBySize(10),
        pill_pad   = Screen:scaleBySize(12),
        list_gap   = Screen:scaleBySize(10),
        line_h     = Screen:scaleBySize(1),
        list_bottom_gap = 0,  -- the last row's own padding is the gap to the nav
        bar_w      = Screen:scaleBySize(28),  -- side bar column
        bar_gap    = Screen:scaleBySize(10),  -- between the rows and the bar
        track_line_w = Screen:scaleBySize(2),
        thumb_bar_w  = Screen:scaleBySize(8),
        thumb_min_h  = Screen:scaleBySize(24),
        row_pad    = Screen:scaleBySize(10),
        col_gap    = Screen:scaleBySize(16),
        dots_w     = Screen:scaleBySize(64),  -- tap width of a row's "…"
        chevron    = Screen:scaleBySize(24),
    }
    L.y_tabs   = margin + L.status_h + L.tabs_gap
    L.y_pills  = L.y_tabs + L.tabs_h + L.pills_gap
    L.y_list   = L.y_pills + L.pills_h + L.list_gap
    L.list_h   = H - KoboldNav.height() - L.list_bottom_gap - L.y_list
    -- Rows take the content width minus the side bar on the right.
    L.list_w   = L.content_w - L.bar_gap - L.bar_w
    L.x_bar    = margin + L.list_w + L.bar_gap
    -- The side bar is a little shorter than the list, centred on it. Only
    -- its look: the pages are the same.
    L.bar_inset = Screen:scaleBySize(20)
    L.bar_h     = L.list_h - 2 * L.bar_inset

    self.L = L
    self:layoutRows()
    self.prefs_rev = KoboldPrefs.revision()

    -- Swipe down from the top edge opens the KOReader menu.
    KoboldTaps.topMenu(self)
    -- Tabs, pills and rows change with the view, so each band has one tap
    -- zone that looks up what is under the finger when it fires.
    KoboldTaps.add(self, "KoboldTabs", 0, L.y_tabs, W, L.tabs_h, function(ges)
        local i = hitIndex(self.tab_hits, ges.pos)
        if i then self:showTab(visibleTabs()[i].id) end
    end)
    KoboldTaps.add(self, "KoboldPills", 0, L.y_pills, W, L.pills_h, function(ges)
        local i = hitIndex(self.pill_hits, ges.pos)
        if i then self.pill_actions[i](self.pill_hits[i]) end
    end)
    local split_x = L.x_bar - math.floor(L.bar_gap / 2)
    KoboldTaps.add(self, "KoboldList", 0, L.y_list, split_x, L.list_h, function(ges)
        self:onListTap(ges.pos)
    end)
    KoboldTaps.add(self, "KoboldSideBar", split_x, L.y_list, W - split_x, L.list_h, function(ges)
        self:onBarTap(ges.pos)
    end)
    -- Full width: in grid view the last column reaches under the side bar strip.
    KoboldTaps.hold(self, "KoboldListHold", 0, L.y_list, W, L.list_h, function(ges)
        self:onListHold(ges.pos)
    end)
    self:registerTouchZones({
        {
            id = "KoboldListSwipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = 0, ratio_y = L.y_list / H,
                ratio_w = 1, ratio_h = L.list_h / H,
            },
            handler = function(ges)
                -- Like scrolling: swipe up for the next page, down for the
                -- previous one. Sideways swipes do nothing.
                -- Other directions (diagonals) are left for KOReader's own
                -- gestures (see addScreenEvents).
                local d = ges.direction
                local grid = self:isGrid()
                if d == "north" or (grid and d == "west") then
                    self:goToPage(self.page + 1)
                elseif d == "south" or (grid and d == "east") then
                    self:goToPage(self.page - 1)
                else
                    return false
                end
                return true
            end,
        },
    })
    -- Touch the side bar and slide the finger: the bar and the page follow it.
    -- Registered after the list hold and swipe zones so it is asked first. Not in grid view,
    -- where this strip is part of the grid.
    KoboldWidgets.registerBarDrag(self, {
        rect = function()
            if self:isGrid() then return nil end
            return Geom:new{ x = split_x, y = L.y_list, w = W - split_x, h = L.list_h }
        end,
        bar  = function() return self:barOpts() end,
        top  = function() return L.y_list + L.bar_inset end,
        goTo = function(page) self:goToPage(page) end,
    })
end

-- The screen was rotated or resized: lay it out again at the new size and
-- build the page. The first item on screen stays on screen.
function KoboldMyBooks:relayout()
    local first = (self.page - 1) * self:perPage()
    self:setupLayout()
    self.page = math.floor(first / math.max(1, self:perPage())) + 1
    self:applyList()
    self[1] = self:build()
    self:ensureCovers()
end

-- What to restore when coming back from a book opened here (session.lua).
function KoboldMyBooks:getReturnState()
    return {
        tab = self.tab,
        group_key = self.group and self.group.key,
        page = self.page,
        group_page = self.group_page,
        folder = self.folder,
    }
end

-- Puts back the tab, open group and page from getReturnState(). The page is
-- clamped by applyList afterwards, in case the list got shorter.
function KoboldMyBooks:restoreState(state)
    if type(state) ~= "table" then return end
    for _i, tab in ipairs(visibleTabs()) do
        if tab.id == state.tab then self.tab = tab.id end
    end
    if self.tab ~= "books" and state.group_key then
        for _i, g in ipairs(KoboldMyBooksData.getGroups(self.books, self.tab)) do
            if g.key == state.group_key then self.group = g break end
        end
    end
    self.folder = type(state.folder) == "string" and state.folder or nil
    self.page = tonumber(state.page) or 1
    self.group_page = tonumber(state.group_page)
end

-- True on the Authors, Series and Collections lists (not inside a group).
function KoboldMyBooks:showsGroups()
    return self.tab ~= "books" and self.tab ~= "files" and not self.group
end

-- Rows per page, slot height and row height for the current view. Authors,
-- Series and Collections all show a cover on each row, like the book rows, so
-- they use the same taller rows.
function KoboldMyBooks:rowSize()
    local L = self.L
    return L.per_page, L.slot_h, L.row_h
end

function KoboldMyBooks:perPage()
    if self:isGrid() then
        self:useGridSet()
        return self.L.grid_per_page
    end
    return (self:rowSize())
end

-- The grid measures for what is shown: book cells (cover only) or series
-- cells (cover, name and count).
function KoboldMyBooks:useGridSet()
    local L = self.L
    local set = self:showsGroups() and L.grid_groups or L.grid_books
    L.grid_cover_h, L.grid_cell_h = set.cover_h, set.cell_h
    L.grid_rows, L.grid_per_page = set.rows, set.per_page
end

-- True when grid view is chosen (on every tab, Files too). On Authors, Series
-- and Collections it covers both the list of groups and the books of one; on
-- Files, the folders (a grey tile with a folder) and the books.
function KoboldMyBooks:isGrid()
    return self.view == "grid"
end

-- Recomputes the list for the current view and clamps the page to it.
function KoboldMyBooks:applyList()
    if self.tab == "files" then
        self.list = self:listFolder(self:currentFolder())
    elseif self.tab == "books" then
        local list = KoboldMyBooksData.filter(self.books, self.filter)
        list = KoboldMyBooksData.byLanguage(list, self.lang)
        self.list = KoboldMyBooksData.arrange(list, self.sort, self.alpha)
    elseif self.group then
        self.list = self.group.books
    else
        local groups = KoboldMyBooksData.getGroups(self.books, self.tab)
        self.list = KoboldMyBooksData.sortGroups(groups, self.group_sort)
    end
    self.pages = math.max(1, math.ceil(#self.list / self:perPage()))
    self.page = math.max(1, math.min(self.page, self.pages))
end

-- Rebuilds the whole screen for the current view and page.
function KoboldMyBooks:build()
    local L = self.L
    local per_page = self:perPage()
    local first = (self.page - 1) * per_page
    self.page_items = {}
    for i = 1, per_page do
        self.page_items[i] = self.list[first + i]
    end
    -- Book rows need their reading status; read it for this page only.
    if not self:showsGroups() then
        local books = {}
        for _i, item in ipairs(self.page_items) do
            if not item.is_dir then books[#books + 1] = item end
        end
        KoboldMyBooksData.resolve(books)
    end

    local body = FrameContainer:new{
        width = L.W, bordersize = 0, padding = L.margin, padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            KoboldWidgets.sharedStatusBar(self),
            VerticalSpan:new{ width = L.tabs_gap },
            self:buildTabs(),
            VerticalSpan:new{ width = L.pills_gap },
            -- Always pills_h tall, also with no pills (only icons on the right),
            -- so the list keeps its place under it.
            LeftContainer:new{
                dimen = Geom:new{ w = L.content_w, h = L.pills_h },
                self:buildPills(),
            },
            VerticalSpan:new{ width = L.list_gap },
            self:isGrid() and VerticalGroup:new{
                align = "left",
                self:buildGrid(),
            } or HorizontalGroup:new{
                align = "top",
                self:buildList(),
                HorizontalSpan:new{ width = L.bar_gap },
                self:buildSidebar(),
            },
        },
    }

    return FrameContainer:new{
        width = L.W,
        height = L.H,
        bordersize = 0,
        padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = L.W, h = L.H },
            body,
            KoboldNav.attach(self, L.W, L.H, "books"),
        },
    }
end

function KoboldMyBooks:refresh()
    self[1] = self:build()
    UIManager:setDirty(self, "ui")
    self:ensureCovers()
end

-- Redraws for a new page: only the list and side bar change, so only that
-- band of the screen is refreshed.
--
-- Page turns use the quiet "ui" refresh, which slowly leaves ghosting on
-- e-ink. Every 10th one flashes ("flashui") to clear it.
function KoboldMyBooks:refreshList()
    local L = self.L
    self[1] = self:build()
    self.quiet_turns = (self.quiet_turns or 0) + 1
    local mode = "ui"
    if self.quiet_turns >= PAGE_TURNS_PER_FLASH then
        self.quiet_turns = 0
        mode = "flashui"
    end
    -- Down to the bottom edge: the page indicator sits under the nav's mini cover.
    UIManager:setDirty(self, function()
        return mode, Geom:new{ x = 0, y = L.y_list, w = L.W, h = L.H - L.y_list }
    end)
    self:ensureCovers()
end

-- Background extraction for covers on this page that the cover browser does
-- not have yet (book rows, and the first book of each series row).
function KoboldMyBooks:ensureCovers()
    local files = {}
    for _i, item in ipairs(self.page_items) do
        local file = item.file or (item.books and item.books[1] and item.books[1].file)
        if file then files[#files + 1] = file end
    end
    KoboldCovers.ensure(files)
end

-- KoboldCoversUpdated: covers finished extracting, redraw the rows.
function KoboldMyBooks:refreshCovers()
    if not self.closed then self:refreshList() end
end

-- The four tabs over a full-width light rule. The selected tab is bold with
-- a black bar that sits on the rule. Records each tab's tap rectangle.
function KoboldMyBooks:buildTabs()
    local L = self.L
    local row = HorizontalGroup:new{}
    local x = L.margin
    self.tab_hits = {}
    local tabs = visibleTabs()
    -- With many tabs on a narrow screen they would run off the edge: the gap
    -- between them shrinks first, then the letters.
    local font_size, tab_gap = 17, L.tab_gap
    local function widths(size)
        local total = 0
        for _i, tab in ipairs(tabs) do
            local t = TextWidget:new{ text = tab.text, face = KoboldWidgets.face(size), bold = true }
            total = total + t:getSize().w
            t:free()
        end
        return total
    end
    local min_gap = Screen:scaleBySize(10)
    local text_total = widths(font_size)
    if #tabs > 1 and text_total + min_gap * (#tabs - 1) > L.content_w then
        font_size = 15
        text_total = widths(font_size)
    end
    if #tabs > 1 then
        tab_gap = math.max(min_gap, math.min(L.tab_gap, math.floor((L.content_w - text_total) / (#tabs - 1))))
    end
    for i, tab in ipairs(tabs) do
        local selected = tab.id == self.tab
        local text = TextWidget:new{ text = tab.text, face = KoboldWidgets.face(font_size), bold = selected }
        local w = text:getSize().w
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = tab_gap } end
        row[#row + 1] = VerticalGroup:new{
            align = "left",
            CenterContainer:new{
                dimen = Geom:new{ w = w, h = L.tabs_h - L.tab_bar_h },
                text,
            },
            selected and LineWidget:new{
                dimen = Geom:new{ w = w, h = L.tab_bar_h },
                background = Blitbuffer.COLOR_BLACK,
            } or VerticalSpan:new{ width = L.tab_bar_h },
        }
        -- Tap area reaches halfway into the gaps on both sides.
        local half = math.floor(tab_gap / 2)
        self.tab_hits[i] = Geom:new{ x = x - half, y = L.y_tabs, w = w + 2 * half, h = L.tabs_h }
        x = x + w + tab_gap
    end
    return OverlapGroup:new{
        dimen = Geom:new{ w = L.content_w, h = L.tabs_h },
        VerticalGroup:new{
            VerticalSpan:new{ width = L.tabs_h - L.tab_rule_h },
            LineWidget:new{
                dimen = Geom:new{ w = L.content_w, h = L.tab_rule_h },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
        },
        row,
    }
end

-- One rounded gray pill, exactly pills_h tall. `icon` is a widget placed
-- after the label, or before it when `icon_first` is set. `max_text_w`
-- shortens long labels.
function KoboldMyBooks:buildPill(label, icon, icon_first, max_text_w)
    local L = self.L
    local text = TextWidget:new{ text = label, face = KoboldWidgets.face(15), max_width = max_text_w }
    local gap = HorizontalSpan:new{ width = Screen:scaleBySize(6) }
    local content = icon_first
        and HorizontalGroup:new{ align = "center", icon, gap, text }
        or HorizontalGroup:new{ align = "center", text, gap, icon }
    local content_h = content:getSize().h
    local pad_top = math.floor((L.pills_h - content_h) / 2)
    local pill = FrameContainer:new{
        bordersize = 0,
        radius = math.floor(L.pills_h / 2),
        background = pillColor(),
        padding = 0,
        padding_left = L.pill_pad,
        padding_right = L.pill_pad,
        padding_top = pad_top,
        padding_bottom = L.pills_h - content_h - pad_top,
        content,
    }
    return pill, pill:getSize().w
end

-- The pills for the current view, left to right. Records each pill's tap
-- rectangle and action.
function KoboldMyBooks:buildPills()
    local L = self.L
    local icon_size = Screen:scaleBySize(18)
    local specs
    if self.tab == "files" then
        -- Back pill to the parent folder, also above the home folder; at
        -- the top of the file system a plain label.
        local dir = self:currentFolder()
        local name = dir:match("([^/]+)/*$") or dir
        if dir == "/" then
            specs = { { label = name, plain = true, action = function() end } }
        else
            specs = { { label = name, back = true, action = function() self:openFolder(self:parentFolder()) end } }
        end
    elseif self.tab == "books" then
        specs = {}  -- Status, sort, A-Z and language live in the adjust sheet
    elseif self.group then
        specs = { {
            label = self.group.name, back = true,
            action = function() self:closeGroup() end,
        } }
    elseif self.tab == "collections" then
        -- Where the Filter / Sort pills were: a grey pill to make a collection.
        specs = { { label = _("Add collection"), add = true, action = function() self:newCollection() end } }
    else
        specs = {}  -- A-Z / Z-A lives in the adjust sheet
    end

    local row = HorizontalGroup:new{ align = "center" }
    local x = L.margin
    self.pill_hits, self.pill_actions = {}, {}
    for i, spec in ipairs(specs) do
        local pill, w
        if spec.plain then
            pill, w = self:buildPill(spec.label,
                KoboldWidgets.icon("home", icon_size, { fallback = "appbar.filebrowser" }), true,
                L.content_w - 2 * L.pill_pad - icon_size - Screen:scaleBySize(6))
        elseif spec.add then
            pill, w = self:buildPill(spec.label,
                OptionSheet.iconWidget("plus", icon_size, Blitbuffer.COLOR_BLACK), true)
        elseif spec.back then
            -- Back pill: left chevron and the group's name, cut to fit.
            local max_text = L.content_w - 2 * L.pill_pad - icon_size - Screen:scaleBySize(6)
            max_text = max_text - Screen:scaleBySize(40) - 3 * L.pill_gap
            if self.tab == "collections" then   -- and room for the plus
                max_text = max_text - Screen:scaleBySize(26) - Screen:scaleBySize(18)
            end
            pill, w = self:buildPill(spec.label, KoboldWidgets.icon("chevron.left", icon_size), true, max_text)
        else
            pill, w = self:buildPill(spec.label, KoboldWidgets.chevronDown(icon_size))
        end
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = L.pill_gap } end
        row[#row + 1] = pill
        self.pill_hits[i] = Geom:new{ x = x, y = L.y_pills, w = w, h = L.pills_h }
        self.pill_actions[i] = spec.action
        x = x + w + L.pill_gap
    end

    -- Right end: inside a collection a plus that adds books to it, then the
    -- adjust icon (view, sort & filter) on every tab (on Files only the view). The "more" button
    -- (three dots) always comes last: on Files it opens a small menu (Select,
    -- Paste here, Settings); elsewhere it goes straight to Kobold Settings.
    -- In selection mode both are replaced by the actions button and a close X.
    local items = {}
    local selecting = self:selecting()
    if selecting then
        -- Selection mode: the actions menu and the way out.
        local act = OptionSheet.iconWidget("square-arrow-right-enter", Screen:scaleBySize(26), Blitbuffer.COLOR_BLACK)
        items[#items + 1] = {
            widget = act, width = act:getSize().w,
            action = function(rect) self:showSelectionMenu(rect) end,
        }
        local close_size = Screen:scaleBySize(26)
        items[#items + 1] = {
            widget = KoboldWidgets.icon("close", close_size), width = close_size,
            action = function() self:exitSelect() end,
        }
    end
    if not selecting and self.tab == "collections" and self.group then
        -- Inside a collection the plus adds books to it (on the list of
        -- collections, the Add collection pill makes a new one).
        local plus_size = Screen:scaleBySize(26)
        items[#items + 1] = {
            widget = OptionSheet.iconWidget("plus", plus_size, Blitbuffer.COLOR_BLACK), width = plus_size,
            action = function() self:addBookToCollection() end,
        }
    end
    if not selecting and self.tab == "files" then
        -- Files: the plus moves books into the folder that is open ("Move to ...").
        local plus_size = Screen:scaleBySize(26)
        items[#items + 1] = {
            widget = OptionSheet.iconWidget("plus", plus_size, Blitbuffer.COLOR_BLACK), width = plus_size,
            action = function() self:moveToFolder() end,
        }
    end
    if not selecting then
        local dots = OptionSheet.iconWidget("adjust", Screen:scaleBySize(26), Blitbuffer.COLOR_BLACK)
        items[#items + 1] = {
            widget = dots, width = dots:getSize().w,
            action = function() self:showViewDialog() end,
        }
    end
    if not selecting then
        -- With something on the clipboard (Files tab) the dots become a
        -- square-plus, so it is clear there is a pending copy / move.
        local pending = self.tab == "files" and Clipboard.hasBoard()
        local more = OptionSheet.iconWidget(pending and "square-plus" or "more", Screen:scaleBySize(26), Blitbuffer.COLOR_BLACK)
        items[#items + 1] = {
            widget = more, width = more:getSize().w,
            action = function(rect) self:openMoreMenu(rect) end,
        }
    end
    if #items > 0 then
        -- The last button is kept a little in from the right edge.
        local inset = Screen:scaleBySize(14)
        local between = Screen:scaleBySize(18)
        local total = between * (#items - 1)
        for _i, it in ipairs(items) do total = total + it.width end
        -- Width of the pills so far, from the loop above. Not row:getSize():
        -- that would fix the group's layout before the icons are added, and
        -- painting the unlaid-out icons crashes KOReader.
        local used = (#specs > 0) and (x - L.margin - L.pill_gap) or 0
        row[#row + 1] = HorizontalSpan:new{ width = math.max(0, L.content_w - used - total - inset) }
        local cx = L.margin + L.content_w - inset - total
        local half = math.floor(between / 2)
        for i, it in ipairs(items) do
            if i > 1 then
                row[#row + 1] = HorizontalSpan:new{ width = between }
                cx = cx + between
            end
            row[#row + 1] = it.widget
            -- Tap area a little wider than the icon; the last one reaches the edge.
            local right_pad = (i == #items) and (inset + half) or half
            self.pill_hits[#self.pill_hits + 1] = Geom:new{
                x = cx - half, y = L.y_pills, w = it.width + half + right_pad, h = L.pills_h,
            }
            self.pill_actions[#self.pill_actions + 1] = it.action
            cx = cx + it.width
        end
    end
    return row
end

-- Item under `pos` in the list, or nil (same rows as onListTap).
function KoboldMyBooks:itemAt(pos)
    local _n, slot_h = self:rowSize()
    local i = math.floor((pos.y - self.L.y_list) / slot_h) + 1
    return self.page_items and self.page_items[i]
end

-- Long-press on the Collections list: that collection's options.
function KoboldMyBooks:onListHold(pos)
    if self:isGrid() then return self:onGridHold(pos) end
    if pos.x >= self.L.x_bar - math.floor(self.L.bar_gap / 2) then return end  -- the side bar
    local item = self:itemAt(pos)
    if not item then return end
    if self:selecting() then
        -- Selection mode (Files or inside a collection): a hold ticks the book too.
        if not item.is_dir and item.file then self:toggleSelect(item.file) end
        return
    end
    if self.tab == "files" then
        if item.is_dir then
            self:showFolderMenu(item.path, self:rowRect(pos), "side")
        else
            self:openBookMenu(item.file, self:rowRect(pos), "side", item)
        end
    elseif self.tab == "collections" and not self.group then
        self:showCollectionOptions(item, self:rowRect(pos), "side")
    elseif not self:showsGroups() and item.file then
        if self:inCollection() then
            -- inside a collection (it has the selection menu): the same menu as its "..."
            self:openBookMenu(item.file, self:rowRect(pos), "side", item)
        else
            -- the other tabs have no selection menu: straight to the details page
            self:openBookDetails(item.file)
        end
    end
end

-- Holding a book in a tab without a selection menu (Books, Authors, Series,
-- Genres): its details page opens directly, with no menu of rows.
function KoboldMyBooks:openBookDetails(file)
    require("kobold.ui.book_details").show(file, self, function() self:scheduleReload() end)
end

-- Selection mode and the clipboard --------------------------------------
-- Selection mode exists on the Files tab (copy / move / delete) and inside an
-- open collection (remove from the collection). The clipboard itself is only
-- used by Files.

function KoboldMyBooks:inCollection()
    return self.tab == "collections" and self.group ~= nil
end

function KoboldMyBooks:selecting()
    return (self.tab == "files" or self:inCollection()) and Clipboard.isSelecting()
end

function KoboldMyBooks:toggleSelect(file)
    Clipboard.toggle(file)
    self:refreshList()
end

function KoboldMyBooks:exitSelect()
    Clipboard.exitSelect()
    self:refresh()
end

-- Refresh library (More menu): the library is scanned from the disk again and
-- everything Kobold remembered about the books (titles, authors, languages,
-- genres, KOReader's own metadata changes) is forgotten and read anew. The
-- same as when KOReader announces a metadata change, done by hand.
function KoboldMyBooks:refreshLibrary()
    local working = Toast.working(_("Refreshing…"))
    KoboldLibrary.forgetAll()
    self:reload()   -- scans the disk again and redraws (the open group stays open)
    Toast.dismiss(working)
    Toast.show(_("Library refreshed."))
end

-- The More button. On Files it opens a menu with Select, Paste here (when
-- the clipboard holds something) and, last, Settings; inside a collection,
-- Select and Settings; on the other tabs, Refresh library and Settings.
function KoboldMyBooks:openMoreMenu(rect)
    local function settings() require("kobold.ui.settings").show() end
    if self:inCollection() then
        -- Inside a collection: Select (to remove several books at once), Settings.
        local items = {
            { text = _("Select"), icon = { "crop", "square-dot" },
              action = function()
                  Clipboard.enterSelect()
                  self:refresh()
              end },
            { text = _("Settings"), icon = { "settings", "settings-2" }, action = settings },
        }
        require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
        return
    end
    if self.tab ~= "files" then
        -- Books, Authors, Series, Genres and the list of collections.
        local items = {
            { text = _("Refresh library"), icon = { "refresh-cw", "undo" },
              action = function() self:refreshLibrary() end },
            { text = _("Settings"), icon = { "settings", "settings-2" }, action = settings },
        }
        require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
        return
    end
    local items = {}
    -- Select only exists while the clipboard is empty: with a pending copy /
    -- move, clear it (or paste) first.
    if not Clipboard.hasBoard() then
        items[#items + 1] = { text = _("Select"), icon = { "crop", "square-dot" },
          action = function()
              Clipboard.enterSelect()
              self:refresh()
          end }
    end
    items[#items + 1] = { text = _("New Folder"), icon = { "Folder", "folder" },
        action = function() self:newFolder() end }
    local board = Clipboard.board()
    if Clipboard.hasBoard() then
        items[#items + 1] = { text = string.format(_("Paste here (%d)"), #board.paths),
            icon = { "2square-arrow-right-enter", "square-arrow-right-enter" }, action = function() self:pasteHere() end }
        items[#items + 1] = { text = _("Clear clipboard"), icon = { "undo", "trash-2" },
            action = function()
                Clipboard.clear()
                self:refresh()
            end }
    end
    items[#items + 1] = { text = _("Settings"), icon = { "settings", "settings-2" }, action = settings }
    require("kobold.ui.book_menu").show{ screen = self, anchor = rect, align = "right", items = items }
end

-- Status text in the right column: Unread, 42% read, or Finished.
local function statusText(item)
    if item.status == "finished" then return _("Finished") end
    if item.status == "onhold" then return _("On hold") end
    if item.status == "reading" then
        if item.percent then
            return math.floor(item.percent * 100) .. _("% read")
        end
        return _("Reading")
    end
    return _("Unread")
end

-- One book row: cover, title over authors, and status over format and size
-- on the right, with the "…" menu button under them. Exactly row_h tall.
local SERIES_MAX_CHARS = 26

-- "NAME - N" for the series line, the name cut after SERIES_MAX_CHARS.
local function seriesLine(item)
    local util = require("util")
    local name = item.series:upper()
    local chars = util.splitToChars and util.splitToChars(name) or nil
    if chars and #chars > SERIES_MAX_CHARS then
        name = table.concat(chars, "", 1, SERIES_MAX_CHARS):gsub("%s+$", "") .. "..."
    elseif not chars and #name > SERIES_MAX_CHARS then
        name = name:sub(1, SERIES_MAX_CHARS) .. "..."
    end
    if item.series_index then
        local n = item.series_index
        if n == math.floor(n) then n = math.floor(n) end
        name = name .. " - " .. tostring(n)
    end
    return name
end

function KoboldMyBooks:buildBookRow(item)
    local L = self.L
    local face_title = KoboldWidgets.face(17)
    local title = TextBoxWidget:new{
        text = item.title, face = face_title, width = L.text_w, alignment = "left",
    }
    if title:getSize().h > L.title_max_h then
        title:free()
        title = TextBoxWidget:new{
            text = item.title, face = face_title, width = L.text_w, alignment = "left",
            height = L.title_max_h, height_overflow_show_ellipsis = true,
        }
    end

    local middle = VerticalGroup:new{ align = "left", title }
    -- Series under the title, in small capitals: the name cut short, then
    -- its number ("THE SAGA OF TANYA... - 1").
    if item.series then
        middle[#middle + 1] = VerticalSpan:new{ width = Screen:scaleBySize(2) }
        middle[#middle + 1] = TextWidget:new{
            text = seriesLine(item),
            face = KoboldWidgets.face(12),
            max_width = L.text_w,
        }
    end
    if item.authors then
        middle[#middle + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        middle[#middle + 1] = TextWidget:new{
            text = item.authors,
            face = KoboldWidgets.face(14),
            fgcolor = KoboldWidgets.subtitleColor(),
            max_width = L.text_w,
        }
    end

    local size = KoboldMyBooksData.formatSize(item.size)
    local format = item.ext ~= "" and item.ext or nil
    if format and size then format = format .. " · " .. size else format = format or size end
    local right = VerticalGroup:new{
        align = "right",
        TextWidget:new{ text = statusText(item), face = KoboldWidgets.face(14), max_width = L.right_w },
    }
    if format then
        right[#right + 1] = VerticalSpan:new{ width = Screen:scaleBySize(2) }
        right[#right + 1] = TextWidget:new{
            text = format,
            face = KoboldWidgets.face(13),
            fgcolor = KoboldWidgets.subtitleColor(),
            max_width = L.right_w,
        }
    end
    right[#right + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
    local dots
    if self:selecting() then
        -- Selection mode: a box that is ticked when the book is selected.
        dots = OptionSheet.iconWidget(Clipboard.isSelected(item.file) and "square-dot" or "square",
            Screen:scaleBySize(26), Blitbuffer.COLOR_BLACK)
    else
        dots = TextWidget:new{ text = "…", face = KoboldWidgets.face(18), bold = true }
    end
    right[#right + 1] = dots
    -- Where the "..." sits in the row (its middle, from the row's top), for
    -- the book menu's arrow. The right column is centred in the row.
    local right_h = right:getSize().h
    item.dots_y = math.floor((L.row_h - right_h) / 2) + right_h - math.floor(dots:getSize().h / 2)

    -- The thumbnail, with the "Opening" pill over it while the book opens.
    local tw, th = KoboldWidgets.coverBox(item.file, L.thumb_w, L.thumb_h)
    tw, th = math.min(tw or L.thumb_w, L.thumb_w), math.min(th or L.thumb_h, L.thumb_h)
    local thumb = OverlapGroup:new{
        dimen = Geom:new{ w = L.thumb_w, h = L.row_h },
        CenterContainer:new{
            dimen = Geom:new{ w = L.thumb_w, h = L.row_h },
            Rounded.cover(item.file, L.thumb_w, L.thumb_h),
        },
        CoverBadge.Overlay:new{
            w = L.thumb_w, h = L.row_h, path = item.file,
            rect = {
                x = math.floor((L.thumb_w - tw) / 2), y = math.floor((L.row_h - th) / 2),
                w = tw, h = th,
            },
        },
    }
    return HorizontalGroup:new{
        thumb,
        HorizontalSpan:new{ width = L.col_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = L.text_w, h = L.row_h },
            middle,
        },
        HorizontalSpan:new{ width = L.col_gap },
        RightContainer:new{
            dimen = Geom:new{ w = L.right_w, h = L.row_h },
            right,
        },
    }
end

-- One author / series / collection row, the same for all three, as on the
-- e-reader's series list: the first book's cover (with a small stack of edges
-- above it when there is more than one book), the name, and the book count at
-- the bottom. A series row also shows its author under the name. Exactly as
-- tall as rowSize() says.
function KoboldMyBooks:buildSeriesRow(group)
    local L = self.L
    local _n, _slot, row_h = self:rowSize()
    local first = group.books[1]

    -- Cover, shortened to make room for the stack lines when there are any.
    local line_h = Screen:scaleBySize(2)
    local line_gap = Screen:scaleBySize(2)
    local stacked = #group.books > 1
    local stack_h = stacked and 2 * (line_h + line_gap) or 0
    local cover_h = L.thumb_h - stack_h
    local cover_w = math.floor(cover_h / COVER_RATIO)
    local cw = first and first.file and KoboldWidgets.coverSize(first.file, cover_w, cover_h) or cover_w
    local thumb = VerticalGroup:new{ align = "center" }
    if stacked then
        local inset = Screen:scaleBySize(4)
        for k = 2, 1, -1 do
            thumb[#thumb + 1] = LineWidget:new{
                dimen = Geom:new{ w = math.max(1, cw - 2 * k * inset), h = line_h },
                background = Blitbuffer.COLOR_DARK_GRAY,
            }
            thumb[#thumb + 1] = VerticalSpan:new{ width = line_gap }
        end
    end
    if first and first.file then
        thumb[#thumb + 1] = Rounded.cover(first.file, cover_w, cover_h)
    else
        -- a collection with no books yet: a plain grey block, as in the grid
        thumb[#thumb + 1] = KoboldWidgets.fixed(cover_w, cover_h, LineWidget:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            background = Blitbuffer.Color8(0xDD),
        })
    end

    -- Authors of a series: the first book's, which the others share in
    -- almost every series. (An author's or a collection's row has no such line.)
    local authors = self.tab == "series" and first and first.authors or nil
    local text_w = L.list_w - L.thumb_w - L.col_gap
    local top = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = group.name, face = KoboldWidgets.face(17), max_width = text_w },
    }
    if authors then
        top[#top + 1] = VerticalSpan:new{ width = Screen:scaleBySize(4) }
        top[#top + 1] = TextWidget:new{ text = authors, face = KoboldWidgets.face(14), max_width = text_w }
    end
    local count = TextWidget:new{
        text = countText(#group.books), face = KoboldWidgets.face(14), max_width = text_w,
    }
    local pad = L.row_pad
    local fill = math.max(0, row_h - 2 * pad - top:getSize().h - count:getSize().h)

    -- Exactly the list's width: rows sized by their text made the list
    -- narrower on a page with a single series (no separator lines to set
    -- the width), and the side bar moved toward the middle with it.
    return KoboldWidgets.fixed(L.list_w, row_h, HorizontalGroup:new{
        CenterContainer:new{ dimen = Geom:new{ w = L.thumb_w, h = row_h }, thumb },
        HorizontalSpan:new{ width = L.col_gap },
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = pad },
            top,
            VerticalSpan:new{ width = fill },
            count,
            VerticalSpan:new{ width = pad },
        },
    })
end

function KoboldMyBooks:buildGroupRow(group)
    -- Authors, Series and Collections share one look.
    return self:buildSeriesRow(group)
end

-- Message shown when the current view has nothing to list.
function KoboldMyBooks:emptyText()
    if self.tab == "files" then return _("This folder is empty.") end
    if self.tab == "books" then
        if self.filter == "all" and not self.lang then return _("No books found in your home folder.") end
        return _("No books match this filter.")
    end
    if self.group then return _("No books here.") end
    if self.tab == "authors" then return _("No authors found.") end
    if self.tab == "series" then return _("No series found.") end
    if self.tab == "genres" then return _("No genres found. They come from the keywords of your books.") end
    return _("No collections yet.")
end

-- The rows of the current page. A folder row (an author, series or collection,
-- or a folder in Files) has a thin grey separator under it; a book row has none,
-- only the same space, so the rows keep their sizes. Always list_w x list_h, so
-- the side bar stays put on a short last page.
function KoboldMyBooks:buildList()
    local L = self.L
    if #self.list == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = L.list_w, h = L.list_h },
            TextWidget:new{
                text = self:emptyText(),
                face = KoboldWidgets.face(16),
                fgcolor = KoboldWidgets.subtitleColor(),
                max_width = L.list_w,
            },
        }
    end
    local groups = self:showsGroups()
    local _n, slot_h = self:rowSize()
    local list = VerticalGroup:new{ align = "left" }
    local used = 0
    local count = #self.page_items
    for i, item in ipairs(self.page_items) do
        if groups then
            list[#list + 1] = self:buildGroupRow(item)
        elseif item.is_dir then
            list[#list + 1] = self:buildFolderRow(item)
        else
            list[#list + 1] = self:buildBookRow(item)
        end
        used = used + slot_h - L.line_h
        -- Nothing under the last row of the page.
        if i < count then
            if groups or item.is_dir then
                list[#list + 1] = LineWidget:new{
                    dimen = Geom:new{ w = L.list_w, h = L.line_h },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                }
            else
                -- a book row: the room of the separator, left empty
                list[#list + 1] = VerticalSpan:new{ width = L.line_h }
            end
            used = used + L.line_h
        end
    end
    list[#list + 1] = VerticalSpan:new{ width = math.max(0, L.list_h - used) }
    return list
end

-- Side bar that makes the pages read like one scrolling list: an up arrow,
-- a track with a thumb showing where this page sits, and a down arrow. With
-- a single page only a faint track is drawn. Exactly list_h tall.
function KoboldMyBooks:buildSidebar()
    local L = self.L
    return VerticalGroup:new{
        VerticalSpan:new{ width = L.bar_inset },
        KoboldWidgets.pageBar(self:barOpts()),
    }
end

-- Size and position of the side bar, for pageBar and pageBarTarget.
function KoboldMyBooks:barOpts()
    local L = self.L
    return { w = L.bar_w, h = L.bar_h, page = self.page, pages = self.pages, arrow = L.chevron }
end

-- Things drawn on top of a book cover in grid view (the badge is shared with
-- Home: kobold/ui/cover_badge.lua; the "..." button is Library's own) ──────
local function moreSize() return Screen:scaleBySize(24) end

-- Tap area of the "..." button: a square in the cover's bottom right corner.
local function moreHit(rect)
    local z = Screen:scaleBySize(40)
    return { x = rect.x + rect.w - z, y = rect.y + rect.h - z, w = z, h = z }
end

-- An svg icon in white with a black outline. The svg is drawn once, in black,
-- onto a white scratch buffer, and the dark pixels are kept as a mask; each
-- paint then fills that mask in black, grown by the outline, and again in
-- white. (A white tint of the svg itself does not come out white.)
local OutlinedIcon = Widget:extend{ name = nil, size = 0 }

function OutlinedIcon:init()
    local img = OptionSheet.iconWidget(self.name, self.size, Blitbuffer.COLOR_BLACK)
    local mask = Blitbuffer.new(self.size, self.size, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    pcall(function() img:paintTo(mask, 0, 0) end)
    self.pts = {}
    for yy = 0, self.size - 1 do
        for xx = 0, self.size - 1 do
            local px = mask:getPixel(xx, yy)
            if px and px:getColor8().a < 140 then
                self.pts[#self.pts + 1] = xx
                self.pts[#self.pts + 1] = yy
            end
        end
    end
    mask:free()
    if img.free then img:free() end
end

function OutlinedIcon:getSize() return Geom:new{ w = self.size, h = self.size } end

function OutlinedIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local o = math.max(1, Screen:scaleBySize(1))
    local d = 2 * o + 1
    local pts = self.pts
    for i = 1, #pts, 2 do
        bb:paintRect(x + pts[i] - o, y + pts[i + 1] - o, d, d, Blitbuffer.COLOR_BLACK)
    end
    for i = 1, #pts, 2 do
        bb:paintRect(x + pts[i], y + pts[i + 1], 1, 1, Blitbuffer.COLOR_WHITE)
    end
end

function OutlinedIcon:free() end

-- The square of selection mode, in the place of the "..." on a cover: empty,
-- or ticked (square-dot) when the book is selected. Same outline as the "...".
function KoboldMyBooks:selectIcon(selected)
    self.select_icons = self.select_icons or {}
    local name = selected and "square-dot" or "square"
    if not self.select_icons[name] then
        self.select_icons[name] = OutlinedIcon:new{ name = name, size = moreSize() }
    end
    return self.select_icons[name]
end

-- How many items a folder holds (hidden files and .sdr folders left out).
local function folderCount(path)
    local count = 0
    local ok, iter, state = pcall(lfs.dir, path)
    if ok then
        for name in iter, state do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then count = count + 1 end
        end
    end
    return count
end

local function itemsText(count)
    return count == 1 and _("1 item") or string.format(_("%d items"), count)
end

-- A folder in grid view (Files): a light grey tile with the folder icon and,
-- lying on its foot, the same black pill as the folders of Home, with the
-- folder's name and how many items it holds. The tile follows Settings >
-- Rounded corners: with that off it has square corners (the pill stays as is).
function KoboldMyBooks:buildFolderTile(item)
    local L = self.L
    local square = not Rounded.enabled()
    local w, h = L.grid_cell_w, L.grid_cover_h
    local icon_size = math.floor(math.min(w, h) * 0.45)
    local tile = FrameContainer:new{
        width = w, height = h,
        bordersize = 0, margin = 0, padding = 0,
        radius = square and 0 or Screen:scaleBySize(6),
        background = Blitbuffer.Color8(0xDD),
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            KoboldWidgets.icon("folder", icon_size, { fallback = "appbar.filebrowser" }),
        },
    }
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        tile,
        CoverBadge.titlePill(item.name, folderCount(item.path), w, h, math.floor(w / 2)),
    }
end

-- One "..." icon shared by every cell (made once, freed with the screen).
function KoboldMyBooks:moreIcon()
    if not self.more_icon then
        self.more_icon = OutlinedIcon:new{ name = "more", size = moreSize() }
    end
    return self.more_icon
end

-- Where the cover really is inside a cell whose top left is (x, y): covers
-- keep their shape, so it can be smaller than the cell; it sits on the bottom.
function KoboldMyBooks:coverRect(file, x, y)
    local L = self.L
    local sw, sh = KoboldWidgets.coverBox(file, L.grid_cell_w, L.grid_cover_h)
    sw = math.min(sw or L.grid_cell_w, L.grid_cell_w)
    sh = math.min(sh or L.grid_cover_h, L.grid_cover_h)
    return { x = x, y = y + L.grid_cover_h - sh, w = sw, h = sh }
end

-- Grid view: rows of covers. A book is its cover with a read badge and a
-- "..." button on it; an author, series or collection (all alike) has the
-- stack lines above its first cover and its name and count under it.
-- Covers stand on a common bottom line. Exactly grid_h tall.
function KoboldMyBooks:buildGrid()
    local L = self.L
    if #self.list == 0 then
        return CenterContainer:new{
            dimen = Geom:new{ w = L.content_w, h = L.grid_h },
            TextWidget:new{
                text = self:emptyText(), face = KoboldWidgets.face(16),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = L.content_w,
            },
        }
    end
    local grid = VerticalGroup:new{ align = "left" }
    local used = 0
    for r = 1, L.grid_rows do
        local row = HorizontalGroup:new{ align = "top" }
        local any = false
        for c = 1, L.grid_cols do
            local item = self.page_items[(r - 1) * L.grid_cols + c]
            if c > 1 then row[#row + 1] = HorizontalSpan:new{ width = L.grid_gap_x } end
            if item then
                any = true
                -- A series shows its first book's cover, its name and count;
                -- a book its cover with the read badge and the "..." button.
                local is_group = item.books ~= nil
                local file = is_group and item.books[1] and item.books[1].file or item.file
                local cover
                if item.is_dir then
                    cover = nil   -- a folder tile is built whole below
                elseif file and is_group and #item.books > 1 then
                    -- A group of several books looks like a series row of the
                    -- list: two short lines stacked above the first book's
                    -- cover, which is shortened to make room for them.
                    local line_h, line_gap = Screen:scaleBySize(2), Screen:scaleBySize(2)
                    local inset = Screen:scaleBySize(4)
                    local stack_h = 2 * (line_h + line_gap)
                    local cov_h = L.grid_cover_h - stack_h
                    local sw, sh = KoboldWidgets.coverBox(file, L.grid_cell_w, cov_h)
                    sw = math.min(sw or L.grid_cell_w, L.grid_cell_w)
                    sh = math.min(sh or cov_h, cov_h)
                    local stack = VerticalGroup:new{
                        align = "left",
                        VerticalSpan:new{ width = cov_h - sh },
                    }
                    for k = 2, 1, -1 do
                        stack[#stack + 1] = HorizontalGroup:new{
                            HorizontalSpan:new{ width = k * inset },
                            LineWidget:new{
                                dimen = Geom:new{ w = math.max(1, sw - 2 * k * inset), h = line_h },
                                background = Blitbuffer.COLOR_DARK_GRAY,
                            },
                        }
                        stack[#stack + 1] = VerticalSpan:new{ width = line_gap }
                    end
                    stack[#stack + 1] = Rounded.cover(file, L.grid_cell_w, cov_h)
                    cover = KoboldWidgets.fixed(L.grid_cell_w, L.grid_cover_h, stack)
                elseif file then
                    local _sw, sh = KoboldWidgets.coverBox(file, L.grid_cell_w, L.grid_cover_h)
                    cover = KoboldWidgets.fixed(L.grid_cell_w, L.grid_cover_h, VerticalGroup:new{
                        align = "left",
                        VerticalSpan:new{ width = (sh and L.grid_cover_h - sh) or 0 },
                        Rounded.cover(file, L.grid_cell_w, L.grid_cover_h),
                    })
                else
                    -- a collection with no books yet: a plain grey block
                    cover = KoboldWidgets.fixed(L.grid_cell_w, L.grid_cover_h, LineWidget:new{
                        dimen = Geom:new{ w = L.grid_cell_w, h = L.grid_cover_h },
                        background = Blitbuffer.Color8(0xDD),
                    })
                end
                if item.is_dir then
                    row[#row + 1] = self:buildFolderTile(item)
                elseif is_group then
                    row[#row + 1] = VerticalGroup:new{
                        align = "left",
                        cover,
                        VerticalSpan:new{ width = L.grid_text_gap },
                        TextWidget:new{ text = item.name, face = KoboldWidgets.face(14), max_width = L.grid_cell_w },
                        TextWidget:new{
                            text = countText(#item.books), face = KoboldWidgets.face(13),
                            fgcolor = KoboldWidgets.subtitleColor(), max_width = L.grid_cell_w,
                        },
                    }
                else
                    row[#row + 1] = OverlapGroup:new{
                        dimen = Geom:new{ w = L.grid_cell_w, h = L.grid_cover_h },
                        cover,
                        CoverBadge.Overlay:new{
                            w = L.grid_cell_w, h = L.grid_cover_h,
                            rect = self:coverRect(file, 0, 0),
                            badge = CoverBadge.make(
                                (item.status == "reading" or item.status == "onhold") and item.percent or nil,
                                item.status == "finished",
                                item.status == "onhold"),
                            -- selection mode: a square (ticked when selected)
                            -- where the "..." is
                            more = self:selecting() and self:selectIcon(Clipboard.isSelected(file))
                                or self:moreIcon(),
                            more_size = moreSize(),
                            path = file,
                        },
                    }
                end
            else
                row[#row + 1] = HorizontalSpan:new{ width = L.grid_cell_w }
            end
        end
        if not any then break end
        if r > 1 then
            grid[#grid + 1] = VerticalSpan:new{ width = L.grid_gap_y }
            used = used + L.grid_gap_y
        end
        grid[#grid + 1] = KoboldWidgets.fixed(L.content_w, L.grid_cell_h, row)
        used = used + L.grid_cell_h
    end
    grid[#grid + 1] = VerticalSpan:new{ width = math.max(0, L.grid_h - used) }
    return grid
end

-- Page and page count for the nav bar's indicator ("1|3", under the mini
-- cover, as on Home). Only the grid view shows it: the list views have the
-- side bar.
function KoboldMyBooks:getPageInfo()
    if self:isGrid() then return self.page, self.pages end
    return nil
end

-- The grid cell under `pos`: its item, its column, and its top left corner on
-- screen. nil outside the cells (gaps, empty places).
function KoboldMyBooks:gridCellAt(pos)
    local L = self.L
    if pos.y >= L.y_grid_end then return nil end
    local rel_x, rel_y = pos.x - L.margin, pos.y - L.y_list
    if rel_x < 0 or rel_y < 0 then return nil end
    local col = math.floor(rel_x / (L.grid_cell_w + L.grid_gap_x))
    local row = math.floor(rel_y / (L.grid_cell_h + L.grid_gap_y))
    if col >= L.grid_cols or row >= L.grid_rows then return nil end
    local cell_x = L.margin + col * (L.grid_cell_w + L.grid_gap_x)
    local cell_y = L.y_list + row * (L.grid_cell_h + L.grid_gap_y)
    if pos.x - cell_x > L.grid_cell_w or pos.y - cell_y > L.grid_cell_h then return nil end
    local item = self.page_items[row * L.grid_cols + col + 1]
    if not item then return nil end
    return item, col, cell_x, cell_y
end

-- Where a menu of a whole grid cell (a collection, a folder) points: the cell,
-- opening to its left or right edge depending on the column.
function KoboldMyBooks:cellAnchor(col, cell_x, cell_y)
    local L = self.L
    return Geom:new{ x = cell_x, y = cell_y, w = L.grid_cell_w, h = L.grid_cell_h },
        (col < L.grid_cols / 2) and "left" or "right"
end

-- The book menu of a grid book, opened from the "..." on its cover or by a
-- long-press. It points at the "..." corner of the cover.
function KoboldMyBooks:openGridMenu(item, col, cell_x, cell_y)
    local L = self.L
    local z = moreHit(self:coverRect(item.file, cell_x, cell_y))
    self:openBookMenu(item.file, Geom:new{ x = z.x, y = z.y, w = z.w, h = z.h },
        col < L.grid_cols / 2 and "left" or "right", item)
end

-- A tap on the grid: on a series, its books
-- open; on a book, the "..." corner of the cover opens the book menu and
-- anywhere else opens the book.
function KoboldMyBooks:onGridTap(pos)
    local L = self.L
    local item, col, cell_x, cell_y = self:gridCellAt(pos)
    if not item then return end
    if item.is_dir then
        self:openFolder(item.path)
        return
    end
    if item.books then
        self:openGroup(item)
        return
    end
    if self:selecting() and item.file then
        -- Selection mode: a tap anywhere on a book ticks it.
        self:toggleSelect(item.file)
        return
    end
    local z = moreHit(self:coverRect(item.file, cell_x, cell_y))
    if pos.x >= z.x and pos.x < z.x + z.w and pos.y >= z.y and pos.y < z.y + z.h then
        -- the same menu everywhere; inside a collection it also has "Remove from collection"
        self:openGridMenu(item, col, cell_x, cell_y)
    else
        KoboldReader.tapOpen(self, item.file)
    end
end

-- A long-press on a grid book: its book menu.
function KoboldMyBooks:onGridHold(pos)
    local item, col, cell_x, cell_y = self:gridCellAt(pos)
    if not item then return end
    if item.is_dir then
        if not self:selecting() then
            local anchor, align = self:cellAnchor(col, cell_x, cell_y)
            self:showFolderMenu(item.path, anchor, align)
        end
        return
    end
    if self:selecting() then
        if item.file then self:toggleSelect(item.file) end
        return
    end
    if item.books then
        -- a collection: its options, as in the list
        if self.tab == "collections" and not self.group then
            local anchor, align = self:cellAnchor(col, cell_x, cell_y)
            self:showCollectionOptions(item, anchor, align)
        end
        return
    end
    if self.tab == "files" or self:inCollection() then
        self:openGridMenu(item, col, cell_x, cell_y)
    else
        self:openBookDetails(item.file)
    end
end

-- A tap on the side bar: the arrows turn one page, a tap on the track jumps
-- to the page at that height.
function KoboldMyBooks:onBarTap(pos)
    -- In grid view this strip is part of the grid.
    if self:isGrid() then return self:onGridTap(pos) end
    local page = KoboldWidgets.pageBarTarget(pos.y - self.L.y_list - self.L.bar_inset, self:barOpts())
    if page then self:goToPage(page) end
end

-- A tap in the list: opens the group or book under it. On a book row, the
-- right edge (the "…") opens the book menu instead.
function KoboldMyBooks:onListTap(pos)
    if self:isGrid() then return self:onGridTap(pos) end
    local L = self.L
    local groups = self:showsGroups()
    local _n, slot_h = self:rowSize()
    local i = math.floor((pos.y - L.y_list) / slot_h) + 1
    local item = self.page_items and self.page_items[i]
    if not item then return end
    if item.is_dir then
        self:openFolder(item.path)
    elseif groups then
        self:openGroup(item)
    elseif self:selecting() and item.file then
        -- Selection mode: a tap on a book ticks it (a folder still opens).
        self:toggleSelect(item.file)
    elseif pos.x >= L.margin + L.list_w - L.dots_w then
        -- The book menu, pointing right at the "..." (see buildBookRow). Inside a
        -- collection it also has "Remove from collection".
        local dots_h = Screen:scaleBySize(20)
        local dy = item.dots_y or math.floor(slot_h / 2)
        self:openBookMenu(item.file, Geom:new{
            x = L.margin + L.list_w - L.dots_w, y = L.y_list + (i - 1) * slot_h + dy - math.floor(dots_h / 2),
            w = L.dots_w, h = dots_h,
        }, "side", item)
    else
        KoboldReader.tapOpen(self, item.file)
    end
end

function KoboldMyBooks:onNextListPage()
    self:goToPage(self.page + 1)
    return true
end

function KoboldMyBooks:onPrevListPage()
    self:goToPage(self.page - 1)
    return true
end

function KoboldMyBooks:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:refreshList()
end

-- Files tab ------------------------------------------------------------

-- A folder row: folder icon, name, and how many items are inside.
function KoboldMyBooks:buildFolderRow(item)
    local L = self.L
    local _n, _slot, row_h = self:rowSize()
    local count = folderCount(item.path)
    local icon_size = math.floor(L.thumb_w * 0.8)
    local text_w = L.list_w - L.thumb_w - 3 * L.col_gap - L.chevron
    return HorizontalGroup:new{
        CenterContainer:new{
            dimen = Geom:new{ w = L.thumb_w, h = row_h },
            KoboldWidgets.icon("folder", icon_size, { fallback = "appbar.filebrowser" }),
        },
        HorizontalSpan:new{ width = L.col_gap },
        LeftContainer:new{
            dimen = Geom:new{ w = text_w, h = row_h },
            VerticalGroup:new{
                align = "left",
                TextWidget:new{ text = item.name, face = KoboldWidgets.face(17), max_width = text_w },
                VerticalSpan:new{ width = Screen:scaleBySize(4) },
                TextWidget:new{
                    text = itemsText(count),
                    face = KoboldWidgets.face(14),
                    fgcolor = KoboldWidgets.subtitleColor(),
                    max_width = text_w,
                },
            },
        },
        HorizontalSpan:new{ width = L.col_gap },
        CenterContainer:new{
            dimen = Geom:new{ w = L.chevron, h = row_h },
            KoboldWidgets.icon("chevron.right", L.chevron),
        },
    }
end

function KoboldMyBooks:showTab(id)
    -- The selection survives only a tap on Files while already on Files.
    if id ~= "files" or self.tab ~= "files" then Clipboard.exitSelect() end
    if id == "files" then
        -- The Files tab always opens at the user's home folder, also when it
        -- is tapped again from inside a subfolder: the way back to home.
        local at_home = self.tab == "files" and not self.group
            and self:currentFolder() == self:filesRoot()
        if at_home then return end
        self.folder = nil   -- currentFolder() falls back to the home folder
        self.folder_pages = nil
    elseif id == self.tab and not self.group then
        return
    end
    self.tab = id
    self.group = nil
    self.page = 1
    self:applyList()
    self:refresh()
end

-- The open tab was turned off in Settings > Library options > Tabs: the first
-- tab that is on opens instead.
function KoboldMyBooks:keepTabOn()
    if KoboldTabs.isEnabled(self.tab) then return end
    self.tab = KoboldTabs.first()
    self.group, self.group_page, self.page = nil, nil, 1
    Clipboard.exitSelect()
end

-- Shows the books of one author, series, collection or genre. The group list page
-- is remembered so the back pill returns to it.
function KoboldMyBooks:openGroup(group)
    Clipboard.exitSelect()
    self.group = group
    self.group_page = self.page
    self.page = 1
    self:applyList()
    self:refresh()
end

function KoboldMyBooks:closeGroup()
    Clipboard.exitSelect()
    self.group = nil
    self.page = self.group_page or 1
    self:applyList()
    self:refresh()
end

-- Saves a new filter, sort or view choice (nil: nothing chosen) and redraws
-- the list from page 1. The sheet stays open, so several can be changed.
function KoboldMyBooks:setChoice(field, key, id)
    self[field] = id
    saveChoice(key, id)
    self.page = 1
    self:applyList()
    self:refresh()
end

-- The adjust button: the same View sheet as Home. The Books tab has all of it;
-- the Authors, Series and Collections lists have Grid / List and A-Z / Z-A;
-- inside a group only Grid / List.
function KoboldMyBooks:showViewDialog()
    local layout = {
        selected = self.view,
        on_pick = function(id) self:setChoice("view", VIEW_KEY, id) end,
    }
    if self.tab == "books" then
        ViewSheet.show{
            layout = layout,
            -- no status chosen is the filter "all"
            status = {
                selected = (self.filter ~= "all") and self.filter or nil,
                on_pick = function(id) self:setChoice("filter", FILTER_KEY, id or "all") end,
            },
            sort   = { selected = self.sort,   on_pick = function(id) self:setChoice("sort", SORT_KEY, id) end },
            alpha  = { selected = self.alpha,  on_pick = function(id) self:setChoice("alpha", ALPHA_KEY, id) end },
            lang   = {
                list = BookLang.languages(self.books), selected = self.lang,
                on_pick = function(id) self:setChoice("lang", LANG_KEY, id) end,
            },
        }
    elseif self:showsGroups() then
        ViewSheet.show{
            layout = layout,
            -- the lists always have an order: A-Z unless Z-A is chosen
            alpha = {
                selected = (self.group_sort == "name_desc") and "za" or "az",
                toggle = false,
                on_pick = function(id)
                    self:setChoice("group_sort", GROUP_SORT_KEY, (id == "za") and "name_desc" or "name_asc")
                end,
            },
        }
    else
        ViewSheet.show{ layout = layout }
    end
end

-- `need`: the file browser is really needed (the book menu): with a book
-- parked it is made now. Hooking its refresh does not need it.
fileChooser = function(need)
    local fm
    if need then
        fm = require("kobold.ui.park").fm()
    else
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        fm = FileManager and FileManager.instance
    end
    return fm and fm.file_chooser
end

-- KOReader's book menu for `file`: the dialog the file browser shows on a
-- long-press (book status, delete, book information, and so on). It opens on
-- top of this screen; changes it makes are picked up by hookFileManager.
-- Kobold's book menu (Read now, View Details, KOReader Details), pointing
-- at `anchor` (a Geom on screen). Changes made from it reload the list.
-- `align` "side" opens it beside the anchor (book rows, as on the e-reader).
-- `item` (optional) is the list item of the book; inside a collection it adds
-- "Remove from collection" (it asks first, see confirmRemoveFromCollection).
function KoboldMyBooks:openBookMenu(file, anchor, align, item)
    local on_remove, on_select
    if item and self.tab == "collections" and self.group then
        on_remove = function() self:confirmRemoveFromCollection(item) end
    end
    -- Select: on Files (while the clipboard is empty) and inside a collection.
    local can_select = (self.tab == "files" and not Clipboard.hasBoard()) or self:inCollection()
    if item and can_select and not item.is_dir and not self:selecting() then
        on_select = function()
            Clipboard.enterSelect()
            Clipboard.add(file)
            self:refresh()
        end
    end
    require("kobold.ui.book_menu").show{
        file = file, screen = self, anchor = anchor,
        on_remove = on_remove,
        on_select = on_select,
        align = align ~= "side" and align or nil, side = align == "side",
        koreader = true,   -- the Library tab is where a book gets edited
        on_change = function() self:scheduleReload() end,
    }
end

-- Screen rectangle of the "..." column of the list row under `pos`.
function KoboldMyBooks:rowRect(pos)
    local L = self.L
    local _n, slot_h, row_h = self:rowSize()
    local i = math.floor((pos.y - L.y_list) / slot_h)
    return Geom:new{ x = L.margin + L.list_w - L.dots_w, y = L.y_list + i * slot_h, w = L.dots_w, h = row_h }
end

function KoboldMyBooks:showBookMenu(file)
    local fc = fileChooser(true)
    local show = fc and (fc.showFileDialog or fc.onFileHold)
    local ok = false
    if show then
        local item = { path = file, file = file, is_file = true, text = file:match("[^/]+$") }
        ok = pcall(show, fc, item)
    end
    if not ok then
        Toast.error(_("The book menu is not available."))
    end
end

-- The file browser refreshes its file list after every change made from the
-- book menu (status, delete, reset, ...). While this screen is open, that
-- refresh also reloads My Books. Undone in onCloseWidget.
function KoboldMyBooks:hookFileManager()
    local fc = fileChooser()
    if not fc or not fc.refreshPath then return end
    local orig = fc.refreshPath
    local own = rawget(fc, "refreshPath")
    fc.refreshPath = function(...)
        local result = orig(...)
        self:scheduleReload()
        return result
    end
    self.unhook = function()
        fc.refreshPath = own  -- nil restores the class method
    end
end

-- Reloads once on the next tick, however many refreshes come in together.
function KoboldMyBooks:scheduleReload()
    if self.reload_pending or self.closed then return end
    self.reload_pending = true
    UIManager:nextTick(function()
        self.reload_pending = false
        if not self.closed then self:reload() end
    end)
end

-- Reads the library again and redraws the current view. An open group is
-- found again by its key; if it is gone, the group list is shown instead.
function KoboldMyBooks:reload()
    KoboldLibrary.invalidate()
    BookLang.forget()
    Genres.forget()
    self.books = KoboldMyBooksData.getBooks()
    if self.group then
        local key = self.group.key
        self.group = nil
        for _i, g in ipairs(KoboldMyBooksData.getGroups(self.books, self.tab)) do
            if g.key == key then self.group = g break end
        end
        if not self.group then self.page = self.group_page or 1 end
    end
    self:applyList()
    self:refresh()
end

-- A setting changed in Settings (rows per page, cover outline, rounded
-- corners...): lay the screen out again with it, on the page it was on.
function KoboldMyBooks:paintTo(bb, x, y)
    -- Rotated (or resized) since it was built: lay it out again first.
    if KoboldMetrics.sizeChanged(self) then self:relayout() end
    if self.prefs_rev ~= nil and KoboldPrefs.revision() ~= self.prefs_rev then
        self.prefs_rev = KoboldPrefs.revision()
        self:keepTabOn()
        self:layoutRows()
        self:applyList()
        self[1] = self:build()
    end
    InputContainer.paintTo(self, bb, x, y)
end

-- Back from a book on a parked screen (session.lua). The file browser was
-- replaced while reading, so the refresh hook moves to the new one; then
-- the list is read again for the new progress and status.
function KoboldMyBooks:onKoboldReturn()
    if self.unhook then self.unhook() self.unhook = nil end
    self:hookFileManager()
    self:scheduleReload()
end

function KoboldMyBooks:onCloseWidget()
    self.closed = true
    if self.more_icon then
        self.more_icon:free()
        self.more_icon = nil
    end
    if self.unhook then
        self.unhook()
        self.unhook = nil
    end
end

function KoboldMyBooks:onClose()
    require("kobold.ui.park").closeScreen(self)
    return true
end

-- The rest of the class lives in two files, mixed into it here: the
-- collections' own actions (rename, remove, add, remove the selected books)
-- and the Files tab (folders, copy / move / delete). They add methods to
-- this class and use `self` as every other method does.
local mixin_ctx = { countText = countText }
require("kobold.ui.mybooks_collections").install(KoboldMyBooks, mixin_ctx)
require("kobold.ui.mybooks_files").install(KoboldMyBooks, mixin_ctx)

return KoboldMyBooks
