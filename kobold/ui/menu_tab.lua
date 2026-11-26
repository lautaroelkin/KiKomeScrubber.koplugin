-- kobold/ui/menu_tab.lua — KiKome
-- The Action center: the FIRST TAB of KOReader's menu (the one that comes down
-- from the top edge, on Home and inside a book). The other tabs of the menu
-- stay next to it, so everything else in KOReader is one tap away.
--
--   Library  ( ) (#) ( ) ( ) >      inside a book: back to Home (icon + the word, in bold); then the actions chosen in
--                                   Settings > Your actions > Action center, as round
--                                   buttons (icons only) that scroll when they do not fit
--   [ book you are reading: cover, title, author, progress ]     (swipe it to the side:
--   [ the recent books, the one being read left out ]             a second page, with lines)
--   [ time left in the chapter ]  [notes]            Hide (sliders icon)
--
-- A round button is black with a white icon when what the action toggles is on (night
-- mode, the frontlight, Wi-Fi, the accelerometer), and grey otherwise, like the tiles of
-- Home. A toggle changes and the menu stays open, so the new
-- state is seen; any other action closes the menu and runs. "Hide KOReader menu" takes
-- every other tab out of the menu (as Zenos' zen mode does) and the button becomes "Show
-- KOReader menu"; turning the Action center off brings them back. On Home the card has a "Read now" pill and tapping it
-- opens the book; inside the book there is no pill (you are there), only the facts,
-- and a "Library" label (icon + bold word) that goes back to Home (what the menu's File browser tab does,
-- which KiKome makes instant).
--
-- It is off until it is turned on in Settings. KOReader's TouchMenu only knows
-- lists of rows, so this patches it (once, install()) to draw a tab that holds a
-- panel instead: the tab is { id, icon, kikome_panel = function(touch_menu) ... }.
--
--   MenuTab.install(ui)        patches TouchMenu and, by where it is called from (the file
--                              manager or a book), the file manager's menu or the reader's
--   MenuTab.enabled()          whether the tab is on
--   MenuTab.hidden()           whether KOReader's own tabs are hidden

local Blitbuffer     = require("ffi/blitbuffer")
local Device         = require("device")
local Event          = require("ui/event")
local FocusManager   = require("ui/widget/focusmanager")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local Widget         = require("ui/widget/widget")
local lfs            = require("libs/libkoreader-lfs")
local CustomActions  = require("kobold.data.custom_actions")
local KoboldPrefs    = require("kobold.data.prefs")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_TAG       = Blitbuffer.Color8(0xDD)   -- the grey of an action with no on / off state
local C_SECONDARY = Blitbuffer.Color8(0x55)

local PREF = "action_center"   -- the setting that turns the tab on
local HIDE_PREF = "action_center_hide_menu"   -- the other tabs of the menu are hidden
-- which actions it shows (custom_actions.lua): one list on Home, another inside a book
local function surfaceFor(ui)
    return (ui and ui.document) and "center_docs" or "center"
end
local TAB_ID = "kikome_center"

local function U(n) return Screen:scaleBySize(n) end

local MenuTab = {}
local installed, fm_installed, reader_installed = false, false, false

function MenuTab.enabled()
    return KoboldPrefs.get(PREF) == true
end

-- KOReader's own tabs are hidden (only this one is left): only while the tab is on, so
-- turning it off always brings the menu back.
function MenuTab.hidden()
    return MenuTab.enabled() and KoboldPrefs.get(HIDE_PREF) == true
end

-- ── What the tab shows ─────────────────────────────────────────────────────
-- The actions to show, each with its state: { { c = action, on = true | false | nil }, ... }
local function entries(ui)
    local out = {}
    for _i, e in ipairs(CustomActions.surfaceList(surfaceFor(ui))) do
        if e.enabled then
            out[#out + 1] = { c = e.action, on = CustomActions.state(e.action) }
        end
    end
    return out
end

-- A string that changes when the state of any button changes.
local function stateSig(ui)
    local parts = {}
    for _i, e in ipairs(entries(ui)) do
        parts[#parts + 1] = e.c.id .. ":" .. (e.on == nil and "-" or (e.on and "1" or "0"))
    end
    return table.concat(parts, ",")
end

-- The book to show: the open one inside a book, else the one read last.
local function currentBook(ui)
    if ui and ui.document and ui.document.file then return ui.document.file end
    local ok, ReadHistory = pcall(require, "readhistory")
    local last = ok and ReadHistory and ReadHistory.hist and ReadHistory.hist[1]
    local file = last and last.file
    if file and lfs.attributes(file, "mode") == "file" then return file end
end

-- The card of the book (home_current.lua, with only the "Read now" pill): the same
-- facts as Home's current book card. Returns the widget and the rects of its parts,
-- relative to the card.
local function buildCard(file, w, h, ui, extra)
    local KoboldLibrary = require("kobold.data.library")
    local LibraryShelf = require("kobold.ui.library_shelf")
    local ok, info = pcall(KoboldLibrary.getDocInfoCached, file)
    info = (ok and type(info) == "table") and info or {}

    -- how far the book is (as Home reads it), or, inside the book, where the reader is now
    local pct = tonumber(info.percent)
    local done, onhold = false, false
    if info.status == "abandoned" then
        onhold = true
    elseif info.status == "complete" or (pct and pct >= 1) then
        pct, done = 1, true
    end
    if ui and ui.document and ui.document.file == file and not (done or onhold) then
        pcall(function()
            local mod = ui.rolling or ui.paging
            local live = mod and mod.getLastPercent and mod:getLastPercent()
            if tonumber(live) then pct = tonumber(live) end
        end)
    end
    if pct and pct <= 0 and not done then pct = nil end

    local ok_m, meta = pcall(LibraryShelf.bookMeta, file)
    meta = (ok_m and type(meta) == "table") and meta or {}
    local fallback_title = (tostring(file):match("([^/]+)$") or ""):gsub("%.[^%.]+$", "")

    local minutes, left_text
    pcall(function()
        local ChapterLeft = require("kobold.data.chapter_left")
        if ui and ui.document and ui.document.file == file then
            local snap = ChapterLeft.snapshot(ui)
            if snap then
                if tonumber(snap.seconds) then
                    minutes = tonumber(snap.seconds) / 60
                end
                if not minutes and type(snap.text) == "string" and snap.text ~= "" then
                    left_text = snap.text
                end
            end
        end
        if not minutes and not left_text then
            local snap = info.chapter_left
            if type(snap) ~= "table" then return end
            -- Only the time the reader measured and kept (the figure KOReader's statistics
            -- gave for those pages, the same one shown inside the book). With none, or when
            -- the book has moved since, nothing is guessed: the card says "Read now".
            minutes = ChapterLeft.minutes(snap, pct, info.pages, nil)
            if not minutes then left_text = ChapterLeft.text(snap, pct) end
        end
    end)
    local pages = tonumber(info.pages)
    local ok_p, shown = pcall(function() return require("kobold.data.stable_pages").shown(file) end)
    if ok_p and tonumber(shown) then pages = tonumber(shown) end

    local in_book = (ui and ui.document and ui.document.file == file) and true or false
    return require("kobold.ui.home_current").build{
        file = file, x = 0, y = 0, w = w, h = h, read_only = true, info_only = in_book, extra = extra, details = true,
        title = (not meta.pending and meta.title) or fallback_title,
        authors = meta.authors, series = meta.series, series_index = meta.series_index,
        pct = pct, done = done, onhold = onhold,
        pages = pages, minutes_left = minutes, left_text = left_text,
    }
end

-- ── The row of round buttons ───────────────────────────────────────────────
-- Icons only, in one row (next to the Library button inside a book, at the start on
-- Home). When they do not all fit, a chevron says so and the row scrolls: tap the
-- chevron or swipe it, as the chips of Home do.
local Strip = Widget:extend{ entries = nil, width = 0, page = 1 }

function Strip:init()
    local ActionIcon = require("kobold.ui.action_icon")
    local OptionSheet = require("kobold.ui.option_sheet")
    self.widgets = {}
    self.d = U(38)      -- diameter of a round button (it sets the height of the row)
    self.gap = U(10)
    self.chev = U(26)   -- the room of a chevron
    self.cells = {}
    for i, e in ipairs(self.entries) do
        local icon = ActionIcon.widget(e.c.icon, U(20))
        self.widgets[#self.widgets + 1] = icon
        self.cells[i] = { c = e.c, on = e.on, icon = icon }
    end
    self.chev_left = OptionSheet.iconWidget("chevron-left", U(18), BLACK)
    self.chev_right = OptionSheet.iconWidget("chevron-right", U(18), BLACK)
    self.widgets[#self.widgets + 1] = self.chev_left
    self.widgets[#self.widgets + 1] = self.chev_right
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.d }
    self:layout()
end

-- The pages, worked out once: where each starts and how many buttons it holds. The
-- first has no chevron on the left, the others do, so they hold a little less; going
-- back is therefore to the start of the page before, whatever it holds.
function Strip:layout()
    local n = #self.cells
    local step = self.d + self.gap
    local function fits(avail) return math.max(0, math.floor((avail + self.gap) / step)) end
    if not self.pages then
        local pages = {}
        local first = 1
        repeat
            local left = (#pages > 0) and self.chev or 0
            local rest = n - first + 1
            local avail = self.width - left
            local page
            if fits(avail) >= rest then
                page = { first = first, count = rest, more = false, left = left }
            else
                page = { first = first, count = math.max(1, fits(avail - self.chev)), more = true, left = left }
            end
            pages[#pages + 1] = page
            first = first + page.count
        until first > n
        self.pages = pages
    end
    if self.page > #self.pages then self.page = #self.pages end
    if self.page < 1 then self.page = 1 end
    local cur = self.pages[self.page]
    self.first, self.count, self.more, self.left_reserved = cur.first, cur.count, cur.more, cur.left
end

function Strip:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local r = math.floor(self.d / 2)
    local step = self.d + self.gap
    for i = 0, self.count - 1 do
        local cell = self.cells[self.first + i]
        if cell then
            local left = x + self.left_reserved + i * step
            -- on: black; off, and the actions that have no state: grey (as on Home)
            bb:paintRoundedRect(left, y, self.d, self.d, cell.on == true and BLACK or C_TAG, r)
            local isz = cell.icon:getSize()
            local ix = left + math.floor((self.d - isz.w) / 2)
            local iy = y + math.floor((self.d - isz.h) / 2)
            if cell.on == true then
                -- white icon on black: drawn black on white, then inverted
                bb:paintRect(ix, iy, isz.w, isz.h, WHITE)
                cell.icon:paintTo(bb, ix, iy)
                bb:invertRect(ix, iy, isz.w, isz.h)
            else
                cell.icon:paintTo(bb, ix, iy)
            end
        end
    end
    local function chevron(widget, cx)
        local sz = widget:getSize()
        widget:paintTo(bb, cx - math.floor(sz.w / 2), y + math.floor((self.d - sz.h) / 2))
    end
    if self.first > 1 then chevron(self.chev_left, x + math.floor(self.chev / 2)) end
    if self.more then chevron(self.chev_right, x + self.width - math.floor(self.chev / 2)) end
end

-- What is under a point: "prev", "next", a button, or nil.
function Strip:hit(pos)
    local x, y = self.dimen.x, self.dimen.y
    if pos.y < y or pos.y >= y + self.d or pos.x < x or pos.x >= x + self.width then return nil end
    if self.first > 1 and pos.x < x + self.chev then return "prev" end
    if self.more and pos.x >= x + self.width - self.chev then return "next" end
    local step = self.d + self.gap
    for i = 0, self.count - 1 do
        local left = x + self.left_reserved + i * step
        if pos.x >= left - math.floor(self.gap / 2) and pos.x < left + self.d + math.floor(self.gap / 2) then
            return self.cells[self.first + i]
        end
    end
end

-- Goes to the next page (dir 1) or the one before (dir -1) and draws the row again.
-- `remember(page)` keeps where it is, for when the panel is made again.
function Strip:scroll(dir, remember)
    local target = self.page + dir
    if target < 1 or target > #self.pages then return end
    self.page = target
    self:layout()
    if remember then remember(self.page) end
    UIManager:setDirty("all", function() return "ui", self.dimen end)
end

function Strip:free()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then w:free() end
    end
    self.widgets = {}
end

-- ── The recent books (the second page) ─────────────────────────────────────
-- Covers in a row with the title under each, spanning the full width. Tap one to open it.
local Recents = Widget:extend{ files = nil, width = 0 }

function Recents.metrics(width)
    local KoboldWidgets = require("kobold.ui.widgets")
    local gap = U(14)
    local label_gap = U(6)
    local base_h = U(124)
    local base_w = math.floor(base_h * 2 / 3)
    local cols = math.max(1, math.floor((width + gap) / (base_w + gap) + 0.5))
    local cover_w = math.floor((width - (cols - 1) * gap) / cols)
    local cover_h = math.floor(cover_w * 3 / 2)
    local probe = TextWidget:new{ text = "Ag", face = KoboldWidgets.face(12) }
    local label_h = probe:getSize().h
    probe:free()
    return {
        gap = gap,
        label_gap = label_gap,
        cols = cols,
        cover_w = cover_w,
        cover_h = cover_h,
        label_h = label_h,
        height = cover_h + label_gap + label_h,
    }
end

function Recents:init()
    local Rounded = require("kobold.ui.rounded")
    local KoboldWidgets = require("kobold.ui.widgets")
    local LibraryShelf = require("kobold.ui.library_shelf")
    local m = Recents.metrics(self.width)
    self.widgets = {}
    self.cells = {}
    self.gap = m.gap
    self.label_gap = m.label_gap
    self.cols = m.cols
    self.cover_w = m.cover_w
    self.cover_h = m.cover_h
    local label_h = m.label_h
    for i = 1, math.min(#self.files, self.cols) do
        local file = self.files[i]
        local ok_c, cover = pcall(Rounded.cover, file, self.cover_w, self.cover_h)
        local ok_m, meta = pcall(LibraryShelf.bookMeta, file)
        meta = (ok_m and type(meta) == "table") and meta or {}
        local title = (not meta.pending and meta.title) or ((tostring(file):match("([^/]+)$") or ""):gsub("%.[^%.]+$", ""))
        local label = TextWidget:new{
            text = title, face = KoboldWidgets.face(12), max_width = self.cover_w + self.gap - U(4),
            truncate_with_ellipsis = true,
        }
        label_h = math.max(label_h, label:getSize().h)
        local cell = { file = file, cover = ok_c and cover or nil, label = label }
        self.widgets[#self.widgets + 1] = label
        if cell.cover then self.widgets[#self.widgets + 1] = cell.cover end
        self.cells[#self.cells + 1] = cell
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self.cover_h + self.label_gap + label_h }
end

function Recents:colLeft(x, i)
    if self.cols <= 1 then return x end
    return x + math.floor((i - 1) * (self.width - self.cover_w) / (self.cols - 1))
end

function Recents:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    for i, cell in ipairs(self.cells) do
        local left = self:colLeft(x, i)
        if cell.cover then
            local csz = cell.cover:getSize()
            cell.cover:paintTo(bb, left + math.floor((self.cover_w - csz.w) / 2), y)
        end
        local lw = cell.label:getSize().w
        local lx = math.max(x, math.min(x + self.width - lw, left + math.floor((self.cover_w - lw) / 2)))
        cell.label:paintTo(bb, lx, y + self.cover_h + self.label_gap)
    end
end

-- The book under a point, or nil.
function Recents:hit(pos)
    local x, y = self.dimen.x, self.dimen.y
    if pos.y < y or pos.y >= y + self.dimen.h then return nil end
    local half_gap = math.floor(self.gap / 2)
    for i, cell in ipairs(self.cells) do
        local left = self:colLeft(x, i) - half_gap
        if pos.x >= left and pos.x < left + self.cover_w + self.gap then return cell end
    end
end

function Recents:free()
    for _i, w in ipairs(self.widgets or {}) do
        if w.free then pcall(function() w:free() end) end
    end
    self.widgets = {}
end

-- Horizontal lines in the footer next to KOReader's close chevron, one per page: the
-- active page is a longer, thicker black line, the others short thin grey ones.
-- (Kept under the name Dots: the footer code below uses it.)
local C_OFF = Blitbuffer.Color8(0x99)   -- grey of the lines of the pages that are not shown
local Dots = Widget:extend{ count = 2, current = 1 }

function Dots:init()
    self.short_w = U(12)
    self.long_w = U(32)
    self.gap = U(7)
    self.thin = math.max(2, U(3))
    self.thick = math.max(self.thin + 1, U(5))
    self.dimen = Geom:new{ x = 0, y = 0,
        w = (self.count - 1) * (self.short_w + self.gap) + self.long_w, h = self.thick }
end

function Dots:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    local cx = x
    for i = 1, self.count do
        local active = (i == self.current)
        local w = active and self.long_w or self.short_w
        local h = active and self.thick or self.thin
        bb:paintRoundedRect(cx, y + math.floor((self.thick - h) / 2), w, h,
            active and BLACK or C_OFF, math.floor(h / 2))
        cx = cx + w + self.gap
    end
end

local function buildHideButton()
    local KoboldWidgets = require("kobold.ui.widgets")
    local OptionSheet = require("kobold.ui.option_sheet")
    local _ = require("kobold.i18n")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local ok, italic = pcall(function() return require("ui/font"):getFace("NotoSans-Italic.ttf", 15) end)
    local label = TextWidget:new{
        text = MenuTab.hidden() and _("Show") or _("Hide"),
        face = (ok and italic) or KoboldWidgets.face(14),
        fgcolor = BLACK,
    }
    return HorizontalGroup:new{
        align = "center",
        label,
        HorizontalSpan:new{ width = U(8) },
        OptionSheet.iconWidget("adjust", U(18), BLACK),
    }
end

-- The books read last, the one being read left out: file names, most recent first.
local function recentFiles(current, limit)
    local out, seen = {}, {}
    local ok, ReadHistory = pcall(require, "readhistory")
    local hist = (ok and ReadHistory and ReadHistory.hist) or {}
    for _i, item in ipairs(hist) do
        local f = item.file
        if f and f ~= current and not seen[f] and lfs.attributes(f, "mode") == "file" then
            seen[f] = true
            out[#out + 1] = f
            if #out >= limit then break end
        end
    end
    return out
end

-- ── The panel ──────────────────────────────────────────────────────────────
local function inside(rect, pos)
    return pos.x >= rect.x and pos.x < rect.x + rect.w and pos.y >= rect.y and pos.y < rect.y + rect.h
end

-- The "Library" label, inside a book: the library icon and the word in bold, with no
-- pill behind them; tapping it goes back to Home. Its width is the one the old pill
-- had (icon + word at size 15 + 18 of padding on each side), so the round buttons
-- at its right stay exactly where they were, even with the word a little bigger.
local function buildLibraryButton(h)
    local KoboldWidgets = require("kobold.ui.widgets")
    local OptionSheet = require("kobold.ui.option_sheet")
    local _ = require("kobold.i18n")
    local LeftContainer = require("ui/widget/container/leftcontainer")
    local HorizontalGroup = require("ui/widget/horizontalgroup")
    local HorizontalSpan = require("ui/widget/horizontalspan")
    local old_label = TextWidget:new{ text = _("Library"), face = KoboldWidgets.face(15), bold = true }
    local w = U(18) + U(8) + old_label:getSize().w + 2 * U(18)
    old_label:free()
    local content = HorizontalGroup:new{
        align = "center",
        OptionSheet.iconWidget("my-books", U(23), BLACK),
        HorizontalSpan:new{ width = U(8) },
        TextWidget:new{ text = _("Library"), face = KoboldWidgets.face(16), bold = true },
    }
    w = math.max(w, content:getSize().w)
    return FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        LeftContainer:new{ dimen = Geom:new{ w = w, h = h }, content },
    }, w
end

-- Builds the panel for `touch_menu` (width: its item_width). `ui` is the reader
-- inside a book, the file manager elsewhere: the actions run there.
function MenuTab.buildPanel(touch_menu, ui)
    -- the panel that was here goes
    local old = touch_menu._kikome_refs
    if old then
        if old.strip then old.strip:free() end
        if old.library and old.library.frame and old.library.frame.free then pcall(function() old.library.frame:free() end) end
        if old.lower and old.lower.free then pcall(function() old.lower:free() end) end
        touch_menu._kikome_refs = nil
    end
    local _ = require("kobold.i18n")
    local W = touch_menu.item_width or (Screen:getWidth() - 2 * U(16))
    local pad = U(18)
    local inner = W - 2 * pad
    local refs = { ui = ui }
    local group = VerticalGroup:new{ align = "left" }
    group[#group + 1] = VerticalSpan:new{ width = U(11) }

    -- The first row: the way back to Home (inside a book), then the round buttons.
    local list = entries(ui)
    local row_h = U(38)
    local lib_frame, lib_w
    if ui and ui.document then
        lib_frame, lib_w = buildLibraryButton(row_h)
        refs.library = { frame = lib_frame }
    end
    if lib_frame or #list > 0 then
        local HorizontalGroup = require("ui/widget/horizontalgroup")
        local HorizontalSpan = require("ui/widget/horizontalspan")
        local row = HorizontalGroup:new{ align = "center" }
        local strip_w = inner
        if lib_frame then
            row[#row + 1] = lib_frame
            row[#row + 1] = HorizontalSpan:new{ width = U(12) }
            strip_w = inner - lib_w - U(12)
        end
        if #list > 0 then
            refs.strip = Strip:new{ entries = list, width = strip_w, page = touch_menu._kikome_strip_page or 1 }
            row[#row + 1] = refs.strip
        end
        group[#group + 1] = row
        group[#group + 1] = VerticalSpan:new{ width = U(12) }
    end
    if #list == 0 and not lib_frame then
        local KoboldWidgets = require("kobold.ui.widgets")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        group[#group + 1] = TextBoxWidget:new{
            text = _("No actions here yet. Choose them in Settings > Your actions > Action center."),
            face = KoboldWidgets.secondaryFace(15), width = inner, fgcolor = C_SECONDARY,
        }
        group[#group + 1] = VerticalSpan:new{ width = U(18) }
    end

    -- The lower part has two pages (swipe it to the side or tap the footer dots):
    -- the book being read, with the Hide / Show button at the right end of its last row;
    -- and the recent books. Both pages share the exact height of the taller one so the
    -- bottom bar never shifts vertically when switching pages.
    local page = touch_menu._kikome_page or 1
    local lower = VerticalGroup:new{ align = "left" }
    local file = currentBook(ui)
    local files = recentFiles(file, 10)
    local card_h = U(150)
    local h1 = file and card_h or 0
    local h2 = 0
    local empty_recents
    if #files > 0 then
        h2 = Recents.metrics(inner).height
    else
        local KoboldWidgets = require("kobold.ui.widgets")
        local TextBoxWidget = require("ui/widget/textboxwidget")
        empty_recents = TextBoxWidget:new{
            text = _("No other recent books."),
            face = KoboldWidgets.secondaryFace(15), width = inner, fgcolor = C_SECONDARY,
        }
        h2 = empty_recents:getSize().h
    end

    if page == 1 then
        if empty_recents then empty_recents:free() end
        local hide_extra = {
            text = MenuTab.hidden() and _("Show") or _("Hide"),
            icon = "adjust",
        }
        if file then
            local ok, card, hits = pcall(buildCard, file, inner, card_h, ui, hide_extra)
            if ok and card then
                local frame = FrameContainer:new{ bordersize = 0, padding = 0, margin = 0, card }
                lower[#lower + 1] = frame
                refs.card = { frame = frame, hits = hits, file = file }
            else
                h1 = 0
            end
        else
            local hide_frame = FrameContainer:new{
                bordersize = 0, padding = 0, margin = 0,
                buildHideButton(),
            }
            local HorizontalGroup = require("ui/widget/horizontalgroup")
            local HorizontalSpan = require("ui/widget/horizontalspan")
            local hw = hide_frame:getSize().w
            lower[#lower + 1] = HorizontalGroup:new{
                align = "center",
                HorizontalSpan:new{ width = math.max(0, inner - hw) },
                hide_frame,
            }
            refs.hide = { frame = hide_frame }
            h1 = hide_frame:getSize().h
        end
    else
        if #files > 0 then
            refs.recents = Recents:new{ files = files, width = inner }
            lower[#lower + 1] = refs.recents
        else
            lower[#lower + 1] = empty_recents
        end
    end

    local CenterContainer = require("ui/widget/container/centercontainer")
    local lower_h = math.max(h1, h2)
    local lower_frame = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0,
        CenterContainer:new{
            dimen = Geom:new{ w = inner, h = lower_h },
            lower,
        },
    }
    refs.lower = lower_frame
    group[#group + 1] = lower_frame
    group[#group + 1] = VerticalSpan:new{ width = U(8) }

    touch_menu._kikome_refs = refs
    return FrameContainer:new{
        bordersize = 0, padding = 0, padding_left = pad, padding_right = pad, width = W,
        group,
    }
end

-- The panel looks again a few times after a toggle (Wi-Fi takes seconds to come
-- on) and is drawn again only if something changed.
local function followState(touch_menu, before, ui)
    local function look()
        if not (touch_menu.item_table and touch_menu.item_table.kikome_panel) then return end
        if not touch_menu.show_parent or not UIManager:isWidgetShown(touch_menu.show_parent) then return end
        local now = stateSig(ui)
        if now ~= before then
            before = now
            touch_menu:updateItems(1)
        end
    end
    UIManager:scheduleIn(0.3, look)
    UIManager:scheduleIn(1.5, look)
    UIManager:scheduleIn(4, look)
end

-- The Kobold screen under the menu (Home, Library), to come back to.
local function koboldScreen()
    local stack = UIManager._window_stack or {}
    for i = #stack, 1, -1 do
        local w = stack[i] and stack[i].widget
        if w and w.kobold_tab then return w end
    end
end

-- Library (inside a book): the same as the menu's File browser tab, which KiKome
-- makes instant (main.lua): the book is parked under Home when it can be, else the
-- usual exit to the file browser.
local function goLibrary(touch_menu, ui)
    local menu = ui and ui.menu
    local item = menu and menu.menu_items and menu.menu_items.filemanager
    if item and type(item.callback) == "function" then
        item.callback()
        return
    end
    touch_menu:closeMenu()
    if ui then pcall(function() ui:handleEvent(Event:new("Home")) end) end
end

local function openBook(touch_menu, refs)
    local file, ui = refs.card.file, refs.ui
    touch_menu:closeMenu()
    -- already inside this book: closing the menu is all
    if ui and ui.document and ui.document.file == file then return end
    UIManager:nextTick(function()
        require("kobold.ui.reader").open(koboldScreen(), file, { splash = true })
    end)
end

-- A recent book: inside a book KOReader switches to it; on Home it opens as usual.
local function openRecent(touch_menu, refs, file)
    local ui = refs.ui
    touch_menu:closeMenu()
    UIManager:nextTick(function()
        if ui and ui.document and type(ui.switchDocument) == "function" then
            local Transition = require("kobold.ui.transition")
            if Transition.enabled() then
                local Splash = require("kobold.ui.cover_splash")
                Splash.show(file)
                require("kobold.ui.refresh").afterPaint(Splash.region(), function()
                    local ReaderUI = package.loaded["apps/reader/readerui"] or require("apps/reader/readerui")
                    local orig_show = ReaderUI.showReader
                    ReaderUI.showReader = function(cls, f, provider, _seamless, blocking, after_open)
                        ReaderUI.showReader = orig_show
                        return orig_show(cls, f, provider, true, blocking, function(...)
                            Splash.close()
                            if type(after_open) == "function" then after_open(...) end
                            UIManager:setDirty("all", "full")
                        end)
                    end
                    local ok, err = pcall(function() ui:switchDocument(file) end)
                    if ReaderUI.showReader ~= orig_show then
                        ReaderUI.showReader = orig_show
                    end
                    if not ok then
                        Splash.close()
                        require("kobold.ui.toast").error(_("Could not open the book: ") .. tostring(err), { timeout = 6 })
                    end
                end)
            else
                ui:switchDocument(file)
            end
        else
            require("kobold.ui.reader").open(koboldScreen(), file, { splash = true })
        end
    end)
end

-- The notepad button: the details of the book (the same sheet Home opens).
local function openDetails(touch_menu, refs)
    local file = refs.card.file
    touch_menu:closeMenu()
    UIManager:nextTick(function()
        local screen = koboldScreen()
        require("kobold.ui.book_details").show(file, screen, function()
            if screen and screen.onKoboldReturn then screen:onKoboldReturn() end
        end)
    end)
end

-- Hide / Show KOReader menu: the other tabs of the menu go (this one stays alone)
-- or come back. The menu in front has the tabs it was made with, so it is closed
-- and opened again on this tab; opening a menu syncs its tabs (syncTabs).
local function toggleHide(touch_menu, refs)
    KoboldPrefs.set(HIDE_PREF, KoboldPrefs.get(HIDE_PREF) ~= true)
    local ui = refs and refs.ui
    touch_menu:closeMenu()
    UIManager:nextTick(function()
        local menu = ui and ui.menu
        if menu and menu.onShowMenu then pcall(menu.onShowMenu, menu, 1) end
    end)
end

local function activate(touch_menu, refs, cell)
    local c = cell.c
    if cell.on ~= nil then
        -- it switches something: it changes, the menu stays open and shows the new state
        local before = stateSig(refs.ui)
        CustomActions.run(c.id, refs.ui)
        followState(touch_menu, before, refs.ui)
    else
        touch_menu:closeMenu()
        UIManager:nextTick(function() CustomActions.run(c.id, refs.ui) end)
    end
end

-- Which page of the row of round buttons is shown, kept for the next time the panel is made.
local function rememberPage(touch_menu)
    return function(page) touch_menu._kikome_strip_page = page end
end

local function setPanelPage(touch_menu, target)
    if (touch_menu._kikome_page or 1) ~= target then
        touch_menu._kikome_page = target
        touch_menu:updateItems(1)
    end
end

local function selectDotPage(touch_menu, pos)
    local r = touch_menu._kikome_dots_rect
    local mid_x = (r and r.cx) or (r and (r.x + math.floor(r.w / 2))) or 0
    setPanelPage(touch_menu, (pos.x < mid_x) and 1 or 2)
end

-- A tap inside the menu while the panel is shown. True: it was taken here.
local function handleTap(touch_menu, ges)
    local refs = touch_menu._kikome_refs
    if not refs then return true end
    local pos = ges.pos
    if touch_menu._kikome_dots_rect and inside(touch_menu._kikome_dots_rect, pos) then
        selectDotPage(touch_menu, pos)
        return true
    end
    if refs.hide and refs.hide.frame and refs.hide.frame.dimen then
        local d = refs.hide.frame.dimen
        local hit_pad = U(10)
        if inside({
            x = d.x - hit_pad,
            y = d.y - hit_pad,
            w = d.w + 2 * hit_pad,
            h = d.h + 2 * hit_pad,
        }, pos) then
            toggleHide(touch_menu, refs)
            return true
        end
    end
    if refs.library then
        local d = refs.library.frame.dimen
        if d and inside(d, pos) then
            goLibrary(touch_menu, refs.ui)
            return true
        end
    end
    if refs.strip then
        local hit = refs.strip:hit(pos)
        if hit == "prev" then
            refs.strip:scroll(-1, rememberPage(touch_menu))
            return true
        elseif hit == "next" then
            refs.strip:scroll(1, rememberPage(touch_menu))
            return true
        elseif hit then
            activate(touch_menu, refs, hit)
            return true
        end
    end
    if refs.recents then
        local cell = refs.recents:hit(pos)
        if cell then
            openRecent(touch_menu, refs, cell.file)
            return true
        end
    end
    if refs.card then
        local d = refs.card.frame.dimen
        if d and inside(d, pos) then
            local hits = refs.card.hits or {}
            local function onCard(r)
                return r and inside({ x = d.x + r.x, y = d.y + r.y, w = r.w, h = r.h }, pos)
            end
            if onCard(hits.extra) then
                toggleHide(touch_menu, refs)
            elseif onCard(hits.details) then
                openDetails(touch_menu, refs)
            else
                openBook(touch_menu, refs)
            end
            return true
        end
    end
    return true   -- the rest of the panel does nothing, and does not close the menu
end

local function inPanelMode(touch_menu)
    return touch_menu and touch_menu.item_table and touch_menu.item_table.kikome_panel ~= nil
end

-- ── The tab in the menus ───────────────────────────────────────────────────
-- The icon of the tab is the plugin's settings-2.svg. KOReader's menu only knows icons by
-- name, so the tab carries one of its own ("home", which always draws) and, once the menu
-- is built, the button's picture is swapped for ours (swapTabIcon).
local here = debug.getinfo(1, "S").source:match("^@?(.*[/\\])") or "./"
local ICON_DIRS = {
    here .. "../icons/",
    here .. "icons/",
    here .. "../../icons/",
    here .. "../assets/icons/",
}

local function findSettings2Svg()
    for _i, dir in ipairs(ICON_DIRS) do
        local p = dir .. "settings-2.svg"
        local f = io.open(p, "r")
        if f then
            f:close()
            return p
        end
    end
    return nil
end

local function loadSettings2Icon(w, h)
    local path = findSettings2Svg()
    if path then
        local ImageWidget = require("ui/widget/imagewidget")
        local ok, img = pcall(function()
            return ImageWidget:new{
                file = path,
                width = w,
                height = h,
                alpha = true,
                fgcolor = BLACK,
                original_in_nightmode = false,
                file_do_cache = false,
            }
        end)
        if ok and img then
            img._kikome_settings2 = true
            return img
        end
    end
    local ok, w_opt = pcall(function()
        return require("kobold.ui.option_sheet").iconWidget("settings-2", math.min(w, h), BLACK)
    end)
    if ok and w_opt then
        w_opt._kikome_settings2 = true
        return w_opt
    end
    return nil
end

local function replaceChild(node, target, replacement, seen)
    if type(node) ~= "table" or seen[node] then return false end
    seen[node] = true
    for k, v in pairs(node) do
        if v == target then
            node[k] = replacement
            return true
        elseif type(v) == "table" and k ~= "parent" and k ~= "show_parent" and k ~= "_kikome_orig_footer" then
            if replaceChild(v, target, replacement, seen) then
                return true
            end
        end
    end
    return false
end

local function swapTabIcon(touch_menu)
    local bar = touch_menu.bar
    local button = bar and bar.icon_widgets and bar.icon_widgets[1]
    local old = button and button.image
    if not old or old._kikome_settings2 then return end
    local sz = old:getSize()
    local icon = loadSettings2Icon(sz.w, sz.h)
    if not icon then return end
    if replaceChild(button, old, icon, {}) then
        button.image = icon
        if old.free then pcall(function() old:free() end) end
    end
end

local function makeTab(ui)
    return {
        id = TAB_ID,
        icon = "home",
        remember = false,
        ui = ui,
        kikome_panel = function(touch_menu) return MenuTab.buildPanel(touch_menu, ui) end,
    }
end

-- Puts the tabs of `menu` (a FileManagerMenu or a ReaderMenu) as they should be now:
-- this tab first when it is on, and gone when it is off; KOReader's own tabs away
-- (kept in menu._kikome_hidden, in order) while "Hide KOReader menu" is on, and back
-- otherwise. It changes the table the menu already has, in place, and runs every time
-- the menu opens (as Zenos' zen mode does), so a change in Settings or the button needs
-- no restart and no menu made again.
local function syncTabs(menu)
    local tabs = menu and menu.tab_item_table
    if type(tabs) ~= "table" then return end
    local function indexOf(tab)
        for i, t in ipairs(tabs) do
            if t == tab then return i end
        end
    end

    -- KOReader's tabs back first, when they should be shown
    local hidden = menu._kikome_hidden
    if type(hidden) == "table" and not MenuTab.hidden() then
        for _i, tab in ipairs(hidden) do
            if not indexOf(tab) then tabs[#tabs + 1] = tab end
        end
        menu._kikome_hidden = nil
    end

    -- this tab: first when on, gone when off
    local ours_i
    for i, t in ipairs(tabs) do
        if t.id == TAB_ID then ours_i = i; break end
    end
    if MenuTab.enabled() then
        if not ours_i then
            table.insert(tabs, 1, makeTab(menu.ui))
        elseif ours_i ~= 1 then
            table.insert(tabs, 1, table.remove(tabs, ours_i))
        end
    elseif ours_i then
        table.remove(tabs, ours_i)
    end

    -- Hide KOReader menu: this tab alone
    if MenuTab.hidden() then
        local removed = {}
        for i = #tabs, 1, -1 do
            if tabs[i].id ~= TAB_ID then
                table.insert(removed, 1, tabs[i])
                table.remove(tabs, i)
            end
        end
        if #removed > 0 then menu._kikome_hidden = removed end
    end
end

-- The two menu classes (the file manager's, the reader's): the tabs are synced when
-- they are made and every time the menu opens.
local function patchMenuClass(Class)
    local orig_set = Class.setUpdateItemTable
    if orig_set then
        function Class:setUpdateItemTable()
            orig_set(self)
            self._kikome_hidden = nil   -- the tabs are new ones
            syncTabs(self)
        end
    end
    local orig_show = Class.onShowMenu
    if orig_show then
        function Class:onShowMenu(tab_index, ...)
            if self.tab_item_table == nil and self.setUpdateItemTable then self:setUpdateItemTable() end
            syncTabs(self)
            return orig_show(self, tab_index, ...)
        end
    end
end

-- The file manager's menu (the one Home opens).
local function installFileManager()
    if fm_installed then return end
    local ok, FileManagerMenu = pcall(require, "apps/filemanager/filemanagermenu")
    if not (ok and FileManagerMenu) then return end
    fm_installed = true
    patchMenuClass(FileManagerMenu)
end

-- The reader's menu. Only called when a book is open: its modules are loaded by then.
local function installReader()
    if reader_installed then return end
    local ok, ReaderMenu = pcall(require, "apps/reader/modules/readermenu")
    if not (ok and ReaderMenu) then return end
    reader_installed = true
    patchMenuClass(ReaderMenu)
end

-- `ui`: the file manager or the reader the plugin is loaded in.
function MenuTab.install(ui)
    -- which menu this process can patch now (the classes of the other one may not be loaded)
    if ui and ui.document then installReader() else installFileManager() end
    if not installed then
        installed = true
        MenuTab.patchTouchMenu()
    end
end

function MenuTab.patchTouchMenu()
    local TouchMenu = require("ui/widget/touchmenu")

    -- The menu opens on the first tab, this one.
    local orig_init = TouchMenu.init
    function TouchMenu:init()
        local first = self.tab_item_table and self.tab_item_table[1]
        if first and first.id == TAB_ID then
            self.last_index = 1
            -- In a book KOReader opens its bottom bar (typography, margins...) together
            -- with the menu. It is another menu: it does not belong with this tab. It is
            -- closed in the same tick it was asked for, so it is never drawn.
            local ui = first.ui
            if ui and ui.document then
                pcall(function() ui:handleEvent(Event:new("CloseConfigMenu")) end)
            end
        end
        local result = orig_init(self)
        if first and first.id == TAB_ID then pcall(swapTabIcon, self) end
        return result
    end

    -- A tab with a panel instead of rows.
    local orig_updateItems = TouchMenu.updateItems
    function TouchMenu:updateItems(target_page, target_item_id)
        if not inPanelMode(self) then
            self._kikome_refs = nil
            self._kikome_dots_rect = nil
            self._kikome_dots = nil
            local res = orig_updateItems(self, target_page, target_item_id)
            if self.footer and self.footer.resetLayout then
                self.footer:resetLayout()
            end
            return res
        end
        local function patchFooterBtn(btn, fn)
            if btn and not btn._kikome_dots_patched then
                btn._kikome_dots_patched = true
                local orig_tap = btn.onTapSelectButton
                btn.onTapSelectButton = function(b, arg, ges)
                    if inPanelMode(self) then
                        local handled = fn(ges)
                        if handled ~= nil then return handled end
                    end
                    return orig_tap(b, arg, ges)
                end
            end
        end
        patchFooterBtn(self.page_info_left_chev, function()
            setPanelPage(self, 1)
            return true
        end)
        patchFooterBtn(self.page_info_right_chev, function()
            setPanelPage(self, 2)
            return true
        end)
        patchFooterBtn(self.page_info_text, function(ges)
            if ges and ges.pos then
                selectDotPage(self, ges.pos)
            else
                setPanelPage(self, (self._kikome_page == 2) and 1 or 2)
            end
            return true
        end)
        patchFooterBtn(self.close_button, function(ges)
            if ges and ges.pos then
                if self._kikome_dots_rect and inside(self._kikome_dots_rect, ges.pos) then
                    selectDotPage(self, ges.pos)
                    return true
                end
            end
            return nil
        end)
        local old_dimen = self.dimen and self.dimen:copy()
        local real_table = self.item_table
        self.item_table = { { text = "" } }
        pcall(orig_updateItems, self, 1, nil)
        self.item_table = real_table
        if type(self.updateTimeInfo) == "function" then pcall(self.updateTimeInfo, self) end
        if type(self.updateFooter) == "function" then pcall(self.updateFooter, self) end
        for _i, w in ipairs(self.item_group) do
            if w ~= self.bar and w ~= self.footer_top_margin and w ~= self.footer and w.free then
                pcall(function() w:free() end)
            end
        end
        self._kikome_dots = Dots:new{ count = 2, current = self._kikome_page or 1 }
        self.item_group:clear()
        self.layout = {}
        table.insert(self.item_group, self.bar)
        table.insert(self.layout, self.bar.icon_widgets)
        table.insert(self.item_group, self.item_table.kikome_panel(self))
        table.insert(self.item_group, self.footer_top_margin)
        table.insert(self.item_group, self.footer)
        self.page, self.page_num = 1, 1
        self.page_info_text:setText("")
        self.page_info_left_chev:showHide(false)
        self.page_info_right_chev:showHide(false)
        if self.footer and self.footer.resetLayout then
            self.footer:resetLayout()
        end
        self.dimen.w = self.width
        self.dimen.h = self.item_group:getSize().h + self.bordersize * 2 + self.padding
        self:moveFocusTo(self.cur_tab, 1, FocusManager.NOT_FOCUS)
        pcall(swapTabIcon, self)
        -- "all": the tab before may have been taller, and what it left below this one
        -- is repainted too.
        UIManager:setDirty("all", function()
            local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
            return "ui", refresh_dimen
        end)
    end

    -- A swipe to the side on the row of round buttons scrolls it; on the lower part it
    -- changes its page (the book / the recent books); elsewhere it does nothing.
    local orig_onSwipe = TouchMenu.onSwipe
    if orig_onSwipe then
        function TouchMenu:onSwipe(arg, ges_ev)
            local d = ges_ev and ges_ev.direction
            if inPanelMode(self) and (d == "west" or d == "east") then
                local refs = self._kikome_refs
                local pos = ges_ev and ges_ev.pos
                if refs and pos then
                    if refs.strip and refs.strip.dimen and pos:intersectWith(refs.strip.dimen) then
                        refs.strip:scroll(d == "west" and 1 or -1, rememberPage(self))
                    elseif (refs.lower and refs.lower.dimen and pos:intersectWith(refs.lower.dimen))
                        or (self.dimen and pos:intersectWith(self.dimen)) then
                        -- the lower part: to the left, the recent books; to the right, back to the book
                        local target = (d == "west") and 2 or 1
                        if target ~= (self._kikome_page or 1) then
                            self._kikome_page = target
                            self:updateItems(1)
                        end
                    end
                end
                return true
            end
            return orig_onSwipe(self, arg, ges_ev)
        end
    end

    local orig_paintTo = TouchMenu.paintTo
    function TouchMenu:paintTo(bb, x, y)
        orig_paintTo(self, bb, x, y)
        if not inPanelMode(self) or not self.footer then return end
        local fd = self.footer.dimen
        local fsz = self.footer:getSize()
        local fx = (fd and fd.x) or (x + (self.bordersize or 0) + (self.padding or 0))
        local fy = (fd and fd.y) or (y + self.dimen.h - (self.bordersize or 0) - (self.padding or 0) - fsz.h)
        local fw = (fd and fd.w) or fsz.w
        local fh = (fd and fd.h) or fsz.h

        if self._kikome_dots then
            local dsz = self._kikome_dots:getSize()
            local dx = fx + math.floor((fw - dsz.w) / 2)
            local dy = fy + math.floor((fh - dsz.h) / 2)
            self._kikome_dots:paintTo(bb, dx, dy)
            local dots_cx = dx + math.floor(dsz.w / 2)
            local left_limit = fx + U(60)
            local right_limit = fx + fw - U(60)
            local half_w = math.max(U(28), math.min(dots_cx - left_limit, right_limit - dots_cx))
            self._kikome_dots_rect = {
                x = dots_cx - half_w,
                y = fy - U(12),
                w = half_w * 2,
                h = fh + U(24),
                cx = dots_cx,
            }
        end
    end

    -- Taps on the panel.
    local orig_onTapCloseAllMenus = TouchMenu.onTapCloseAllMenus
    function TouchMenu:onTapCloseAllMenus(arg, ges_ev)
        if inPanelMode(self) and ges_ev and ges_ev.pos and self.dimen and ges_ev.pos:intersectWith(self.dimen) then
            return handleTap(self, ges_ev)
        end
        return orig_onTapCloseAllMenus(self, arg, ges_ev)
    end
end

return MenuTab
