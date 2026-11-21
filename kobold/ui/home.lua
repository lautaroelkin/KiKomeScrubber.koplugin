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
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local DocSettings     = require("docsettings")
local ReadHistory     = require("readhistory")
local lfs             = require("libs/libkoreader-lfs")
local KoboldLibrary   = require("kobold.data.library")
local KoboldCovers    = require("kobold.data.covers")
local KoboldHomeData  = require("kobold.data.home")
local KoboldFonts     = require("kobold.data.fonts")
local KoboldPrefs     = require("kobold.data.prefs")
local Rounded        = require("kobold.ui.rounded")
local CoverBadge     = require("kobold.ui.cover_badge")
local Chips          = require("kobold.data.chips")
local CustomActions  = require("kobold.data.custom_actions")
local KoboldNav       = require("kobold.ui.nav")
local KoboldMetrics   = require("kobold.ui.metrics")
local KoboldReader    = require("kobold.ui.reader")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local LibraryShelf    = require("kobold.ui.library_shelf")

local Screen = Device.screen
local COVER_RATIO = 1.5
local RECENT_ACROSS = 4.5   -- covers across the row of recent books

local KoboldHome = InputContainer:extend{
    covers_fullscreen = true,
    dithered = true,
    name = "kobold_home",
    kobold_tab = "home",
}
KoboldWidgets.addScreenEvents(KoboldHome)

local function spacedRow(cells, gap)
    local row = HorizontalGroup:new{}
    for i, cell in ipairs(cells) do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = cell
    end
    return row
end

local ClipRow = Widget:extend{
    width = 0, height = 0, offset = 0, child = nil,
    rounded = nil, radius = 0, outline = 1,
}

local function roundRect(bb, x, y, w, h, r, outline)
    local pad = Screen:scaleBySize(3)
    bb:paintRect(x + w, y, pad, h + pad, Blitbuffer.COLOR_WHITE)
    bb:paintRect(x, y + h, w, pad, Blitbuffer.COLOR_WHITE)
    -- the row is painted on a white buffer, so what is outside the arc is white
    pcall(Rounded.finish, bb, x, y, w, h, r, outline, nil, Blitbuffer.COLOR_WHITE)
end

function ClipRow:getSize() return Geom:new{ w = self.width, h = self.height } end

function ClipRow:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local full_w = math.max(self.child:getSize().w, self.width)
    local off = Blitbuffer.new(full_w, self.height, bb:getType())
    off:fill(Blitbuffer.COLOR_WHITE)
    self.child:paintTo(off, 0, 0)
    for _i, rc in ipairs(self.rounded or {}) do
        roundRect(off, rc.x, rc.y, rc.w, rc.h, self.radius, self.outline)
    end
    bb:blitFrom(off, x, y, self.offset, 0, self.width, self.height)
    off:free()
end

function ClipRow:free()
    if self.child and self.child.free then self.child:free() end
end

function KoboldHome:activeTopModes()
    local enabled = KoboldPrefs.homeTopEnabled()
    local current = self.data and self.data.reading and self.data.reading[1]
    local modes = {}
    for _i, id in ipairs(enabled) do
        if id ~= "current" or (current and current.file) then
            modes[#modes + 1] = id
        end
    end
    if #modes == 0 then modes[1] = "recent" end
    return modes
end

function KoboldHome:setTopIndex(idx)
    local modes = self:activeTopModes()
    if #modes <= 1 then return false end
    idx = math.max(1, math.min(#modes, idx))
    if idx == (self.top_index or 1) then return false end
    self.top_index = idx
    self:build()
    UIManager:setDirty(self, "ui")
    return true
end

function KoboldHome:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.reading_page = 1
    self.top_index = 1
    if Device:isTouchDevice() then
        self.ges_events = self.ges_events or {}
        self.ges_events.SwipeCovers = {
            GestureRange:new{ ges = "swipe", range = self.dimen }
        }
        self.ges_events.SwipeShelf = {
            GestureRange:new{ ges = "swipe", range = self.dimen }
        }
    end
    if Device:hasKeys() then
        self.key_events = { Back = { { Device.input.group.Back } } }
    end
    self:loadData()
    self:build()
end

function KoboldHome:readStamp()
    local h = ReadHistory.hist and ReadHistory.hist[1]
    if not h or not h.file then return "none" end
    local side
    local ok, path = pcall(function() return DocSettings:findSidecarFile(h.file) end)
    if ok and path then
        side = lfs.attributes(path, "modification")
    else
        side = KoboldLibrary.sidecarStamp(h.file)
    end
    return tostring(h.file) .. "|" .. tostring(h.time) .. "|" .. tostring(side)
end

-- Title of each library book by file, for the captions under the reading row.
-- Looked up when a caption is drawn (from the cover browser's data, or the
-- file name), not built for the whole library at every refresh.
local function bookTitles()
    return setmetatable({}, { __index = function(t, file)
        local ok, title = pcall(KoboldLibrary.getTitle, file)
        if ok and type(title) == "string" and title ~= "" then
            rawset(t, file, title)
            return title
        end
        return nil
    end })
end

function KoboldHome:loadData()
    self.data = KoboldHomeData.getHomeData()
    self.read_stamp = self:readStamp()
    self.titles = bookTitles()
    
    -- The whole library, newest file first. data.my_books is only the three
    -- newest, so the shelf must not use it.
    self.all_books = {}
    local ok, books = pcall(KoboldLibrary.scan)
    if ok and type(books) == "table" then
        for _i, b in ipairs(books) do
            if b.file then self.all_books[#self.all_books + 1] = b.file end
        end
    end
    if #self.all_books == 0 then
        self.all_books = self.data.my_books or {}
    end

    KoboldCovers.ensure(self.all_books)
end

-- The screen was rotated or resized: build it again at the new size. The
-- shelf keeps its chip, view and page (build reads them from the old shelf).
function KoboldHome:relayout()
    self.dimen.w, self.dimen.h = Screen:getWidth(), Screen:getHeight()
    self:build()
end

function KoboldHome:paintTo(bb, x, y)
    -- Rotated (or resized) since it was built: lay it out again first.
    if KoboldMetrics.sizeChanged(self) then self:relayout() end
    if self.read_stamp and self:readStamp() ~= self.read_stamp then
        self.reading_page = 1
        self:loadData()
        self:build()
    end
    -- The Rounded corners setting was changed in Settings: redraw the covers.
    -- (same for the Cover outline setting)
    if (self.corners_on ~= nil and Rounded.enabled() ~= self.corners_on)
        or (self.outline_w ~= nil and KoboldWidgets.outlineWidth() ~= self.outline_w) then
        self:build()
    end
    -- The shelf chips were changed in Settings > Shelves.
    if self.chips_sig ~= nil and Chips.signature() ~= self.chips_sig then
        self:build()
    end
    -- The actions were changed in Settings > Your actions (or which ones Home shows).
    if self.actions_sig ~= nil and CustomActions.signature() ~= self.actions_sig then
        self:build()
    end
    -- A font was changed in Settings > Appearance > Fonts.
    if self.font_sig ~= nil and KoboldFonts.signature() ~= self.font_sig then
        self:build()
    end
    -- Settings > Home > Top of Home: ordered toggles (first enabled is the default).
    if self.top_sig ~= nil and KoboldPrefs.homeTopSignature() ~= self.top_sig then
        self.top_index = 1
        self:build()
    end
    -- The Clock card: the font changed in Settings, the minute turned while Home was
    -- covered (a book, a menu), or the tick was lost: catch up.
    if self.clock_holder then
        if self.clock_sig ~= self:clockSig() then
            self:build()
        elseif self.clock_minute ~= math.floor(os.time() / 60) then
            self:refreshClockCard()
        end
        if self.clock_holder and not self.clock_tick then self:scheduleClock() end
    end
    -- The time in the status bar: whatever makes Home repaint (a swipe, a tap, coming
    -- back from a book) also brings it up to date. Nothing is refreshed for it alone.
    self:refreshStatusClock()
    InputContainer.paintTo(self, bb, x, y)
end

function KoboldHome:onKoboldReturn()
    self.reading_page = 1
    LibraryShelf.invalidateMeta()  -- the book info may have been edited
    self:loadData()
    self:refreshCovers()
end

function KoboldHome:refreshCovers()
    LibraryShelf.forgetMisses()
    self:build()
    UIManager:setDirty(self, "ui")
end

function KoboldHome:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local data      = self.data
    -- Margins and status bar come from metrics.lua, the same as Library and
    -- Settings, so the status bar does not move between them.
    local bar       = KoboldMetrics.statusBar()
    local margin    = bar.margin
    local gap       = Screen:scaleBySize(16)
    local content_w = W - 2 * margin

    -- On a short screen the grid shrinks instead (see fitScale in
    -- library_shelf.lua).
    local margin_top    = bar.top                  -- screen edge to the status bar
    local status_h      = bar.h
    local status_gap    = Screen:scaleBySize(8)    -- status bar to the recent row
    local shelf_gap     = Screen:scaleBySize(10)   -- recent row to the shelf
    local tight_gap     = Screen:scaleBySize(4)    -- cover to its title
    -- One line under each cover, the book's title: as tall as the text itself,
    -- at any screen density. (The percentage read is the badge on the cover.)
    local line_h        = TextWidget:new{ text = "Ag", face = KoboldWidgets.face(16) }:getSize().h
    local caption_h     = line_h + Screen:scaleBySize(2)
    local nav_h         = KoboldNav.height()

    -- The recent row is smaller than the shelf's covers so it takes less height.
    -- On a short screen (landscape) it takes at most ~33% of the height under
    -- the status bar so both the Current book card and the shelves fit cleanly.
    local room_h = H - nav_h - (margin_top + status_h + status_gap) - Screen:scaleBySize(8)
    local top_w = math.floor((content_w - 3 * gap) / RECENT_ACROSS)
    local max_top_h = math.floor(room_h * 0.33) - tight_gap - caption_h
    top_w = math.min(top_w, math.floor(max_top_h / COVER_RATIO))
    top_w = math.max(top_w, Screen:scaleBySize(60))
    local top_h = math.floor(top_w * COVER_RATIO)

    local n_cover    = math.max(#(data.reading or {}), 4)
    local step       = top_w + gap
    -- A swipe moves the covers that were fully showing: 3 in portrait (as it
    -- always was), more when more fit across.
    local per_view   = math.max(1, math.floor((content_w + gap) / step))
    local page_step  = per_view * step
    local max_offset = math.max(0, n_cover * step - gap - content_w)
    local pages      = max_offset > 0 and (math.ceil(max_offset / page_step) + 1) or 1
    self.reading_pages = pages
    self.reading_page  = math.min(math.max(self.reading_page or 1, 1), pages)
    local read_offset  = math.min((self.reading_page - 1) * page_step, max_offset)
    local read_h       = top_h + tight_gap + caption_h

    -- All Top of Home modes share the exact same height (`read_h`) so the
    -- shelves below never shift when switching modes.
    local current = data.reading and data.reading[1]
    local modes = self:activeTopModes()
    self.top_index = math.min(math.max(self.top_index or 1, 1), #modes)
    local top_mode = modes[self.top_index]
    local clock_mode = top_mode == "clock"
    local card_mode = top_mode == "current" and current and current.file
    if #modes > 1 then
        self._kobold_top_dots = {
            count = #modes,
            current = self.top_index,
            on_select = function(idx) self:setTopIndex(idx) end,
            on_swipe = function(dir) self:setTopIndex((self.top_index or 1) + dir) end,
        }
    else
        self._kobold_top_dots = nil
    end

    local y_read  = margin_top + status_h + status_gap
    local y_lib   = y_read + read_h + shelf_gap
    local shelf_h = H - nav_h - y_lib - Screen:scaleBySize(8)

    -- Keep the open tab, page and series / author across rebuilds.
    local prev_state = self.library_shelf and self.library_shelf:getState()

    self.library_shelf = LibraryShelf:new{
        x = margin, y = y_lib, width = content_w, height = shelf_h,
        home = self,
        files = self.all_books,
        state = prev_state,
        onTapFile = function(file) KoboldReader.tapOpen(self, file) end,
        -- Holding a book opens its details page directly (no menu of rows).
        onHoldFile = function(file, _anchor)
            require("kobold.ui.book_details").show(file, self, function()
                if self.onKoboldReturn then self:onKoboldReturn() end
            end)
        end,
    }
    self.top_rect   = Geom:new{ x = margin, y = y_read, w = content_w, h = read_h }
    self.shelf_rect = Geom:new{ x = margin, y = y_lib, w = content_w, h = shelf_h }

    local L = {
        read_offset = read_offset, read_h = read_h, n_cover = n_cover,
        top_w = top_w, top_h = top_h, top_gap = gap,
        tight_gap = tight_gap, caption_h = caption_h,
        content_w = content_w,
    }

    self.corners_on = Rounded.enabled()
    self.status_minute = math.floor(os.time() / 60)
    self.outline_w = KoboldWidgets.outlineWidth()
    self.chips_sig = Chips.signature()
    self.actions_sig = CustomActions.signature()
    self.font_sig = KoboldFonts.signature()

    -- The top: the row of recent books, or (Settings > Home > Top of Home) one
    -- card with the book being read, or the clock. With no book read yet, the row stays.
    self.top_sig = KoboldPrefs.homeTopSignature()
    self.card_hits, self.card_file = nil, nil
    -- Whatever the clock card had (and its minute tick) goes: it is made again below if it is on.
    self:cancelClock()
    self.clock_holder, self.clock_args, self.clock_sig, self.clock_hits = nil, nil, nil, nil
    local top_widget
    if clock_mode then
        L.x, L.y = margin, y_read
        top_widget = self:buildClockCard(current, L)
    elseif card_mode then
        L.x, L.y = margin, y_read
        top_widget = self:buildCurrentCard(current, L)
    else
        top_widget = self:buildReadingSection(data.reading, L)
    end

    local body = FrameContainer:new{
        width = W, bordersize = 0, padding = margin, padding_top = margin_top, padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            KoboldWidgets.sharedStatusBar(self),
            VerticalSpan:new{ width = status_gap },
            top_widget,
            VerticalSpan:new{ width = shelf_gap },
            self.library_shelf,
        },
    }

    KoboldTaps.topMenu(self)

    if clock_mode then
        -- Only the controls row responds to touch (play pill, annotations, edit);
        -- the quote box itself does nothing.
        self.reading_rect = nil
        local function openClockDetails(start_view)
            if not self.clock_file then return end
            require("kobold.ui.book_details").show(self.clock_file, self, function()
                if self.onKoboldReturn then self:onKoboldReturn() end
            end, nil, start_view)
        end
        KoboldTaps.add(self, "KoboldTopRow", margin, y_read, content_w, read_h, function(ges)
            local h, pos = self.clock_hits, ges.pos
            if not (h and self.clock_file) then return end
            if pos:intersectWith(h.annot) then
                openClockDetails("annotations")
            elseif pos:intersectWith(h.edit) then
                openClockDetails("edit")
            elseif pos:intersectWith(h.read) then
                KoboldReader.tapOpen(self, self.clock_file)
            end
        end)
        KoboldTaps.hold(self, "KoboldTopRowHold", margin, y_read, content_w, read_h, function(ges)
            local h, pos = self.clock_hits, ges.pos
            if not (h and self.clock_file) then return end
            if pos:intersectWith(h.read) or pos:intersectWith(h.annot) or pos:intersectWith(h.edit) then
                openClockDetails()
            end
        end)
    elseif card_mode then
        -- One zone for the whole card (the same ids as the row, which they replace).
        self.reading_rect = nil
        local function openDetails(start_view)
            require("kobold.ui.book_details").show(self.card_file, self, function()
                if self.onKoboldReturn then self:onKoboldReturn() end
            end, nil, start_view)
        end
        KoboldTaps.add(self, "KoboldTopRow", margin, y_read, content_w, read_h, function(ges)
            local h, pos = self.card_hits, ges.pos
            if not (h and self.card_file) then return end
            if pos:intersectWith(h.annot) then
                openDetails("annotations")
            elseif pos:intersectWith(h.edit) then
                openDetails("edit")
            elseif pos:intersectWith(h.read) or pos:intersectWith(h.cover) then
                KoboldReader.tapOpen(self, self.card_file)
            else
                openDetails()
            end
        end)
        KoboldTaps.hold(self, "KoboldTopRowHold", margin, y_read, content_w, read_h, function()
            if self.card_file then openDetails() end
        end)
    else
        self.reading_rect = Geom:new{ x = margin, y = y_read, w = content_w, h = read_h }
        local function coverAt(ges)
            local rel = ges.pos.x - margin + read_offset
            local i = math.floor(rel / step) + 1
            local inside = rel - (i - 1) * step
            local item = data.reading and data.reading[i]
            if item and item.file and inside <= top_w then
                return item, margin + (i - 1) * step - read_offset
            end
        end
        KoboldTaps.add(self, "KoboldTopRow", margin, y_read, content_w, top_h, function(ges)
            local item = coverAt(ges)
            if item then KoboldReader.tapOpen(self, item.file) end
        end)
        KoboldTaps.hold(self, "KoboldTopRowHold", margin, y_read, content_w, top_h, function(ges)
            local item = coverAt(ges)
            if not item then return end
            require("kobold.ui.book_details").show(item.file, self, function()
                if self.onKoboldReturn then self:onKoboldReturn() end
            end)
        end)
    end

    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = H },
            body,
            -- With the current book card on show, the mini cover of the last book
            -- would be the same book twice: it is left out.
            KoboldNav.attach(self, W, H, "home", { no_cover = card_mode and true or false }),
        },
    }
end

-- Title shown under a cover: the book's title, or its file name without the
-- extension when none is known.
function KoboldHome:titleOf(item)
    if not item then return "" end
    local title = item.title or (self.titles and self.titles[item.file])
    if title and title ~= "" then return title end
    local name = tostring(item.file or ""):match("([^/]+)$") or ""
    return (name:gsub("%.[^%.]+$", ""))
end

-- How far a book is, as the shelves read it: a fraction, and whether it is
-- finished (the same rule as library_shelf.lua, so both show the same badge).
local function readState(item)
    local ok, info = pcall(KoboldLibrary.getDocInfoCached, item.file)
    info = (ok and type(info) == "table") and info or {}
    local pct = tonumber(info.percent) or tonumber(item.percent)
    if info.status == "abandoned" then return pct, false, true end   -- On hold
    if info.status == "complete" or (pct and pct >= 1) then return 1, true end
    local ReaderUI = package.loaded["apps/reader/readerui"]
    local rui = ReaderUI and ReaderUI.instance
    if rui and rui.document and rui.document.file == item.file then
        pcall(function()
            local mod = rui.rolling or rui.paging
            local live = mod and mod.getLastPercent and mod:getLastPercent()
            if tonumber(live) then pct = tonumber(live) end
        end)
        if pct and pct >= 1 then return 1, true end
    end
    if pct and pct > 0 then return pct, false end
    return nil, false
end

-- The current book card (home_current.lua) for `item`, the most recent book.
-- L.x, L.y, L.content_w and L.read_h say where it goes and how big it is.
-- Remembers the book and the rects of its cover and pills for the taps.
function KoboldHome:buildCurrentCard(item, L)
    local pct, done, onhold = readState(item)
    local ok, info = pcall(KoboldLibrary.getDocInfoCached, item.file)
    info = (ok and type(info) == "table") and info or {}
    local ok_m, meta = pcall(LibraryShelf.bookMeta, item.file)
    meta = (ok_m and type(meta) == "table") and meta or {}
    -- Minutes left in the chapter: same logic as menu_tab.lua
    local minutes, left_text
    pcall(function()
        local ChapterLeft = require("kobold.data.chapter_left")
        local ReaderUI = package.loaded["apps/reader/readerui"]
        local rui = ReaderUI and ReaderUI.instance
        if rui and rui.document and rui.document.file == item.file then
            local snap = ChapterLeft.snapshot(rui)
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
            local pages_count = tonumber(info.pages) or tonumber(item.pages)
            -- Only the time the reader measured and kept (the figure KOReader's statistics
            -- gave for those pages, the same one shown inside the book). With none, or when
            -- the book has moved since, nothing is guessed: the card says "Read now".
            minutes = ChapterLeft.minutes(snap, pct, pages_count, nil)
            if not minutes then left_text = ChapterLeft.text(snap, pct) end
        end
    end)
    -- The pages of "Page X of Y": the same count as Book details (the Metadata count or KOReader's
    -- stable pages, when the book has them); otherwise the layout's, as before.
    local card_pages = tonumber(info.pages) or tonumber(item.pages)
    local ok_p, shown = pcall(function() return require("kobold.data.stable_pages").shown(item.file) end)
    if ok_p and tonumber(shown) then card_pages = tonumber(shown) end
    local card, hits = require("kobold.ui.home_current").build{
        file = item.file, x = L.x, y = L.y, w = L.content_w, h = L.read_h,
        title = (not meta.pending and meta.title) or self:titleOf(item),
        authors = meta.authors, series = meta.series, series_index = meta.series_index,
        pct = pct, done = done, onhold = onhold,
        pages = card_pages, minutes_left = minutes, left_text = left_text,
    }
    self.card_file, self.card_hits = item.file, hits
    return card
end

-- The Clock card (home_clock.lua) at the top of Home. It remembers what it
-- needs to be drawn again each minute (clock_args) and sits in a holder whose
-- only child is swapped, so a new minute does not build the whole of Home.
-- `item` is the book being read: the pill on top says its title and opens it.
function KoboldHome:buildClockCard(item, L)
    local file, book_title
    if item and item.file then
        file = item.file
        local ok_m, meta = pcall(LibraryShelf.bookMeta, file)
        meta = (ok_m and type(meta) == "table") and meta or {}
        book_title = (not meta.pending and meta.title) or self:titleOf(item)
    end
    self.clock_file = file
    self.clock_args = { x = L.x, y = L.y, w = L.content_w, h = L.read_h, file = file, book_title = book_title }
    local args = { w = L.content_w, h = L.read_h, now = os.time(), file = file, book_title = book_title }
    local card, rel_hits = require("kobold.ui.home_clock").build(args)
    self:setClockHits(rel_hits)
    self.clock_holder = KoboldWidgets.fixed(L.content_w, L.read_h, card)
    self.clock_minute = math.floor(args.now / 60)
    self.clock_sig = self:clockSig()
    self:scheduleClock()
    return self.clock_holder
end

-- Translates the controls' card-relative rects into screen coordinates for taps.
function KoboldHome:setClockHits(rel_hits)
    local a = self.clock_args
    if not (a and rel_hits) then self.clock_hits = nil; return end
    local function shift(r)
        return Geom:new{ x = a.x + r.x, y = a.y + r.y, w = r.w, h = r.h }
    end
    self.clock_hits = {
        read  = shift(rel_hits.read),
        annot = shift(rel_hits.annot),
        edit  = shift(rel_hits.edit),
    }
end

-- What the card depends on besides the minute, to notice a change in Settings.
function KoboldHome:clockSig()
    return KoboldFonts.signature()
end

-- Draws the card again for the current minute, in place. False when it cannot.
-- The time of the status bar is brought up to date with it.
function KoboldHome:refreshClockCard()
    if not (self.clock_holder and self.clock_args) then return false end
    local a = self.clock_args
    local now = os.time()
    local ok, card, rel_hits = pcall(require("kobold.ui.home_clock").build,
        { w = a.w, h = a.h, now = now, file = a.file, book_title = a.book_title })
    if not ok or not card then return false end
    local old = self.clock_holder[1]
    self.clock_holder[1] = card
    if old and old.free then pcall(old.free, old) end
    self:setClockHits(rel_hits)
    self.clock_minute = math.floor(now / 60)
    self:refreshStatusClock()
    return true
end

-- Puts the status bar's time right for the current minute, without asking for a
-- refresh: the caller is painting, or is already refreshing the screen around it.
function KoboldHome:refreshStatusClock()
    local minute = math.floor(os.time() / 60)
    if self.status_minute == minute then return end
    self.status_minute = minute
    local s = self._kobold_status
    if s and s.frame then
        local ok, bar = pcall(KoboldWidgets.statusBar, s.dimen.w, self._kobold_top_dots)
        if ok and bar then s.frame[1] = bar end
    end
end

local function inWindowStack(widget)
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        if entry.widget == widget then return true end
    end
    return false
end

-- The card changes at the start of each minute, only while Home is what the
-- reader sees (a book, a menu or the screensaver on top keep it from
-- refreshing the e-ink for nothing; paintTo catches up when Home comes back).
function KoboldHome:scheduleClock()
    self:cancelClock()
    if not self.clock_holder then return end
    local delay = 60 - (os.time() % 60) + 1
    self.clock_tick = function() self:onClockTick() end
    UIManager:scheduleIn(delay, self.clock_tick)
end

function KoboldHome:cancelClock()
    if self.clock_tick then
        UIManager:unschedule(self.clock_tick)
        self.clock_tick = nil
    end
end

function KoboldHome:onClockTick()
    self.clock_tick = nil
    if not self.clock_holder or not inWindowStack(self) then return end
    local stack = UIManager._window_stack
    local top = stack and stack[#stack] and stack[#stack].widget
    if top == self and not Device.screen_saver_mode and self:refreshClockCard() then
        -- The card changes, so the status bar's time goes with it in the same refresh:
        -- one region from the top of the bar down to the bottom of the card.
        local c, s = self.clock_args, self._kobold_status
        UIManager:setDirty(self, function()
            local y0 = s and s.dimen and math.min(s.dimen.y, c.y) or c.y
            local x0 = s and s.dimen and math.min(s.dimen.x, c.x) or c.x
            local x1 = s and s.dimen and math.max(s.dimen.x + s.dimen.w, c.x + c.w) or (c.x + c.w)
            return "ui", Geom:new{ x = x0, y = y0, w = x1 - x0, h = c.y + c.h - y0 }
        end)
    end
    -- Not on top (a book, a menu): no more wakeups every minute for a card
    -- nobody sees. paintTo starts the tick again when Home is painted.
    if top ~= self then return end
    self:scheduleClock()
end

function KoboldHome:buildReadingSection(reading, L)
    local cells, rounded = {}, {}
    for i = 1, L.n_cover do
        local item = reading[i]
        local sw, sh = KoboldWidgets.coverBox(item and item.file, L.top_w, L.top_h)
        sw = math.min(sw or L.top_w, L.top_w)
        sh = math.min(sh or L.top_h, L.top_h)
        rounded[#rounded + 1] = {
            x = (i - 1) * (L.top_w + L.top_gap), y = L.top_h - sh, w = sw, h = sh,
        }
        -- The badge in the cover's corner: the percentage read, or "Read".
        local badge
        if item and item.file then
            local pct, done, onhold = readState(item)
            badge = CoverBadge.make(pct, done, onhold)
        end
        cells[i] = VerticalGroup:new{
            align = "left",
            OverlapGroup:new{
                dimen = Geom:new{ w = L.top_w, h = L.top_h },
                VerticalGroup:new{
                    align = "left",
                    VerticalSpan:new{ width = L.top_h - sh },
                    KoboldWidgets.makeCover(item and item.file, L.top_w, L.top_h, { outline = true }),
                },
                CoverBadge.Overlay:new{
                    w = L.top_w, h = L.top_h,
                    rect = { x = 0, y = L.top_h - sh, w = sw, h = sh },
                    badge = badge,
                    path = item and item.file,
                },
            },
            VerticalSpan:new{ width = L.tight_gap },
            -- The book's title, centred under the cover, cut with "..." when it
            -- is wider than the cover.
            LeftContainer:new{
                dimen = Geom:new{ w = L.top_w, h = L.caption_h },
                CenterContainer:new{
                    dimen = Geom:new{ w = sw, h = L.caption_h },
                    TextWidget:new{ text = self:titleOf(item), face = KoboldWidgets.face(16), max_width = sw },
                },
            },
        }
    end
    return ClipRow:new{
        width = L.content_w, height = L.read_h,
        offset = L.read_offset,
        rounded = Rounded.enabled() and rounded or nil,
        radius = Screen:scaleBySize(10),
        outline = KoboldWidgets.outlineWidth(),
        child = spacedRow(cells, L.top_gap),
    }
end

function KoboldHome:onSwipeCovers(_, ges)
    if self.reading_rect and ges.pos:intersectWith(self.reading_rect) then
        local total = self.reading_pages or 1
        if ges.direction == "west" then
            if self.reading_page < total then
                self.reading_page = self.reading_page + 1
                self:build()
                UIManager:setDirty(self, "ui")
            else
                self:setTopIndex((self.top_index or 1) + 1)
            end
        elseif ges.direction == "east" then
            if self.reading_page > 1 then
                self.reading_page = self.reading_page - 1
                self:build()
                UIManager:setDirty(self, "ui")
            else
                self:setTopIndex((self.top_index or 1) - 1)
            end
        end
        return true
    end
    if self.top_rect and ges.pos:intersectWith(self.top_rect) then
        if ges.direction == "west" then
            self:setTopIndex((self.top_index or 1) + 1)
        elseif ges.direction == "east" then
            self:setTopIndex((self.top_index or 1) - 1)
        end
        return true
    end
    return false
end

function KoboldHome:onSwipeShelf(_, ges)
    if not self.library_shelf or not self.shelf_rect then return false end
    if not ges.pos:intersectWith(self.shelf_rect) then return false end
    -- A swipe that starts on the chips turns the page of chips.
    local chips = self.library_shelf:chipBarRect()
    if chips and (ges.direction == "west" or ges.direction == "east")
        and ges.pos:intersectWith(chips) and self.library_shelf:swipeChips(ges.direction) then
        return true
    end
    if ges.direction == "west" then
        self.library_shelf:nextPage()
    elseif ges.direction == "east" then
        self.library_shelf:prevPage()
    else
        return false
    end
    return true
end

-- The Back key (or gesture): one step back, not out of KiKome. In selection
-- mode it leaves that mode. Inside a
-- series, author, collection or folder of the shelf it goes up one level; from
-- the top of Home it leaves KiKome.
function KoboldHome:onBack()
    local shelf = self.library_shelf
    -- In selection mode Back only leaves selection mode.
    if shelf and shelf.selecting and shelf:selecting() then
        shelf:exitSelect()
        return true
    end
    if shelf and shelf.canGoBack and shelf:canGoBack() then
        shelf:goBack()
        return true
    end
    -- Back from the top of Home would leave KiKome for KOReader: ask first.
    local _ = require("kobold.i18n")
    require("kobold.ui.confirm_sheet").show{
        title = _("Leave KiKome?"),
        message = _("You will go back to KOReader."),
        confirm_text = _("Leave"),
        on_confirm = function() self:onClose() end,
    }
    return true
end

function KoboldHome:onClose()
    self:cancelClock()
    require("kobold.ui.park").closeScreen(self)
    return true
end

return KoboldHome
