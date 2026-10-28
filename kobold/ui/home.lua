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
local Rounded        = require("kobold.ui.rounded")
local CoverBadge     = require("kobold.ui.cover_badge")
local Chips          = require("kobold.data.chips")
local KoboldNav       = require("kobold.ui.nav")
local KoboldReader    = require("kobold.ui.reader")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")
local LibraryShelf    = require("kobold.ui.library_shelf")

local Screen = Device.screen
local COVER_RATIO = 1.5

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

function KoboldHome:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.reading_page = 1
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
        self.key_events = { Close = { { Device.input.group.Back } } }
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
local function bookTitles()
    local map = {}
    local ok, books = pcall(function() return require("kobold.data.mybooks").getBooks() end)
    if ok and type(books) == "table" then
        for _i, b in ipairs(books) do
            if b.file and b.title then map[b.file] = b.title end
        end
    end
    return map
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

function KoboldHome:paintTo(bb, x, y)
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
    InputContainer.paintTo(self, bb, x, y)
end

function KoboldHome:onKoboldReturn()
    self.reading_page = 1
    LibraryShelf.invalidateMeta()  -- the book info may have been edited
    self:loadData()
    self:refreshCovers()
end

function KoboldHome:refreshCovers()
    self:build()
    UIManager:setDirty(self, "ui")
end

function KoboldHome:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local data      = self.data
    local margin    = Screen:scaleBySize(20)
    local gap       = Screen:scaleBySize(20)
    local content_w = W - 2 * margin

    -- The spacing Home always had; on a short screen the grid shrinks instead
    -- (see fitScale in library_shelf.lua).
    local margin_top    = Screen:scaleBySize(20)   -- screen edge to the status bar
    local status_h      = Screen:scaleBySize(30)
    local status_gap    = Screen:scaleBySize(16)   -- status bar to the recent row
    local shelf_gap     = Screen:scaleBySize(16)   -- recent row to the shelf
    local tight_gap     = Screen:scaleBySize(4)    -- cover to its title
    -- One line under each cover, the book's title: as tall as the text itself,
    -- at any screen density. (The percentage read is the badge on the cover.)
    local line_h        = TextWidget:new{ text = "Ag", face = KoboldWidgets.face(16) }:getSize().h
    local caption_h     = line_h + Screen:scaleBySize(2)
    local nav_h         = KoboldNav.height()

    -- The recent row is a little smaller: 3.7 covers across, not 3.4.
    local top_w = math.floor((content_w - 3 * gap) / 3.7)
    local top_h = math.floor(top_w * COVER_RATIO)

    local n_cover    = math.max(#(data.reading or {}), 4)
    local step       = top_w + gap
    local page_step  = 3 * step
    local max_offset = math.max(0, n_cover * step - gap - content_w)
    local pages      = max_offset > 0 and (math.ceil(max_offset / page_step) + 1) or 1
    self.reading_pages = pages
    self.reading_page  = math.min(math.max(self.reading_page or 1, 1), pages)
    local read_offset  = math.min((self.reading_page - 1) * page_step, max_offset)
    local read_h       = top_h + tight_gap + caption_h

    local y_read  = margin_top + status_h + status_gap
    local y_lib   = y_read + read_h + shelf_gap
    local shelf_h = H - nav_h - y_lib - Screen:scaleBySize(10)

    -- Keep the open tab, page and series / author across rebuilds.
    local prev_state = self.library_shelf and self.library_shelf:getState()

    self.library_shelf = LibraryShelf:new{
        x = margin, y = y_lib, width = content_w, height = shelf_h,
        home = self,
        files = self.all_books,
        state = prev_state,
        onTapFile = function(file) KoboldReader.tapOpen(self, file) end,
        onHoldFile = function(file, anchor)
            local W_ = Screen:getWidth()
            require("kobold.ui.book_menu").show{
                file = file, screen = self, anchor = anchor,
                align = anchor.x < W_ / 2 and "left" or "right",
                on_change = function()
                    if self.onKoboldReturn then self:onKoboldReturn() end
                end,
            }
        end,
    }
    self.shelf_rect = Geom:new{ x = margin, y = y_lib, w = content_w, h = shelf_h }

    local L = {
        read_offset = read_offset, read_h = read_h, n_cover = n_cover,
        top_w = top_w, top_h = top_h, top_gap = gap,
        tight_gap = tight_gap, caption_h = caption_h,
        content_w = content_w,
    }

    self.corners_on = Rounded.enabled()
    self.outline_w = KoboldWidgets.outlineWidth()
    self.chips_sig = Chips.signature()

    local body = FrameContainer:new{
        width = W, bordersize = 0, padding = margin, padding_top = margin_top, padding_bottom = 0,
        VerticalGroup:new{
            align = "left",
            KoboldWidgets.statusBarFrame(self, margin, content_w, status_h, margin_top),
            VerticalSpan:new{ width = status_gap },
            self:buildReadingSection(data.reading, L),
            VerticalSpan:new{ width = shelf_gap },
            self.library_shelf,
        },
    }

    KoboldTaps.topMenu(self)

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
        local item, x = coverAt(ges)
        if not item then return end
        local vx = math.max(x, margin)
        require("kobold.ui.book_menu").show{
            file = item.file, screen = self,
            anchor = Geom:new{ x = vx, y = y_read, w = math.min(top_w, margin + content_w - vx), h = top_h },
            align = vx < W / 2 and "left" or "right",
            on_change = function()
                if self.onKoboldReturn then self:onKoboldReturn() end
            end,
        }
    end)

    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = Blitbuffer.COLOR_WHITE,
        OverlapGroup:new{
            dimen = Geom:new{ w = W, h = H },
            body,
            KoboldNav.attach(self, W, H, "home"),
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
    if info.status == "complete" or (pct and pct >= 1) then return 1, true end
    if pct and pct > 0 then return pct, false end
    return nil, false
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
            local pct, done = readState(item)
            badge = CoverBadge.make(pct, done)
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
    if not self.reading_rect then return false end
    if ges.pos:intersectWith(self.reading_rect) then
        local total = self.reading_pages or 1
        if ges.direction == "west" and self.reading_page < total then
            self.reading_page = self.reading_page + 1
        elseif ges.direction == "east" and self.reading_page > 1 then
            self.reading_page = self.reading_page - 1
        else
            return false
        end
        self:build()
        UIManager:setDirty(self, "ui")
        return true
    end
    return false
end

function KoboldHome:onSwipeShelf(_, ges)
    if not self.library_shelf or not self.shelf_rect then return false end
    if not ges.pos:intersectWith(self.shelf_rect) then return false end
    if ges.direction == "west" then
        self.library_shelf:nextPage()
    elseif ges.direction == "east" then
        self.library_shelf:prevPage()
    else
        return false
    end
    return true
end

function KoboldHome:onClose()
    UIManager:close(self)
    return true
end

return KoboldHome
