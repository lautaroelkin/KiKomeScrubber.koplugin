-- kobold/ui/collection_editor.lua — KiKome
-- Full-screen editor to make a collection or a folder (a name and the books
-- in it) or to add books to a collection that exists. Everything happens on this one screen: no
-- KOReader dialogs. Top: Cancel, the title and a black Create / Add pill that
-- shows how many books are ticked. Under it a rounded name field (new
-- collection only), a search field with the adjust button (the same Sort &
-- Filter sheet as Home and Library), then the books, with the same square /
-- square-dot ticks as the selection mode of the Files tab. The text fields
-- are typed with the plugin's own keyboard (keyboard.lua), which rises from
-- the bottom while a field is in use and shrinks the list instead of covering
-- it.
--
--   require("kobold.ui.collection_editor").show{
--       mode     = "new",            -- or "add" (no name field; button says Add, or
--                                    -- action_label),
--                                    -- or "search" (no name, no ticks: a tap opens the book)
--       title    = "New collection",
--       name_placeholder = "Collection name",   -- optional
--       action_label = "Move",       -- optional: the button of "add" mode (default Add)
--       empty_text = "...",          -- optional: shown when "add" mode has no books
--       show_path = false,           -- a line with the folder each book is in
--       root     = "/path/home",     -- show_path: paths are shown from here
--       books    = entries,          -- see data/mybooks.lua
--       validate = function(name) return "message" or nil end,  -- optional
--       on_done  = function(name, picked) end,   -- picked = { [file] = true }
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
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local RightContainer  = require("ui/widget/container/rightcontainer")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("kobold.i18n")
local BookLang        = require("kobold.data.booklang")
local CoverBadge      = require("kobold.ui.cover_badge")
local KoboldCovers    = require("kobold.data.covers")
local Keyboard        = require("kobold.ui.keyboard")
local KoboldMyBooksData = require("kobold.data.mybooks")
local OptionSheet     = require("kobold.ui.option_sheet")
local ViewSheet       = require("kobold.ui.view_sheet")
local KoboldReader    = require("kobold.ui.reader")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD       = Blitbuffer.Color8(0xE8)  -- the name field and the Create pill when off
local C_OUTLINE     = Blitbuffer.Color8(0x99)  -- the search field's outline
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)

local function U(n) return Screen:scaleBySize(n) end

local function trim(s)
    return (s:match("^%s*(.-)%s*$"))
end

-- Text with its first characters cut until it fits `max_w`, so the end of
-- what is being typed (where the caret is) always shows.
local function tail(text, face, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = face }
        local w = t:getSize().w
        t:free()
        return w
    end
    local guard = 0
    while text ~= "" and width(text) > max_w and guard < 200 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return text
end

-- A rounded pill of exactly h tall around a label. Returns it and its width.
local function pill(text, h, bg, fg, bold)
    local t = TextWidget:new{ text = text, face = KoboldWidgets.face(16), bold = bold, fgcolor = fg }
    local th = t:getSize().h
    local top = math.floor((h - th) / 2)
    local frame = FrameContainer:new{
        bordersize = 0, radius = math.floor(h / 2), background = bg,
        padding = 0, padding_left = U(18), padding_right = U(18),
        padding_top = top, padding_bottom = h - th - top,
        t,
    }
    return frame, frame:getSize().w
end

-- ── The screen ─────────────────────────────────────────────────────────────
local Editor = InputContainer:extend{
    -- Shown on top of Library, which stays alive underneath.
    name = "kobold_collection_editor",
    covers_fullscreen = true,
    dithered = true,
    mode = "new",
    title = nil,
    books = nil,
    validate = nil,
    on_done = nil,
    action_label = nil,
    empty_text = nil,
}

function Editor:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.coll_name = ""
    self.query = nil
    self.selected = {}
    self.all_books = self.books or {}
    -- The order and filters of the list (see ViewSheet): A-Z until changed.
    self.sort, self.alpha, self.status, self.lang = nil, "az", nil, nil
    -- The keyboard types into whichever field has the focus.
    self.kb = Keyboard.new{
        on_insert = function(text) self:insert(text) end,
        on_delete = function() self:deleteLast() end,
        on_clear = function() self:clearField() end,
        on_hide = function() self:setFocus(nil) end,
        is_empty = function() return self:fieldIsEmpty() end,
        -- a tapped key lets go: its black look is drawn away, refreshing only
        -- that key
        on_redraw = function(rects)
            if not (self.focus and self.kb_y) then return end
            self:build()
            if not rects or #rects == 0 then
                rects = { Geom:new{ x = 0, y = self.kb_y, w = Screen:getWidth(), h = Screen:getHeight() - self.kb_y } }
            end
            for _i, r in ipairs(rects) do
                UIManager:setDirty(self, function() return "ui", r end)
            end
        end,
        -- sliding over the space bar moves the caret
        on_move = function(delta)
            self.pos = Keyboard.moveCaret(self:fieldText(), self:caretPos(), delta)
        end,
    }
    -- A new collection starts with the name field ready to type in, a search
    -- with the search field.
    if self.mode == "new" then
        self.focus = "name"
    elseif self.mode == "search" then
        self.focus = "search"
    end
    self.kb:reset(self.focus == "name")
    self.page = 1
    self:applyView()
    self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapEditor = { GestureRange:new{ ges = "tap", range = self.dimen } },
            SwipeEditor = { GestureRange:new{ ges = "swipe", range = self.dimen } },
            HoldEditor = { GestureRange:new{ ges = "hold", range = self.dimen } },
            -- a slide over the keyboard's space bar moves the caret
            PanEditor = { GestureRange:new{ ges = "pan", range = self.dimen } },
            HoldPanEditor = { GestureRange:new{ ges = "hold_pan", range = self.dimen } },
            PanReleaseEditor = { GestureRange:new{ ges = "pan_release", range = self.dimen } },
            HoldReleaseEditor = { GestureRange:new{ ges = "hold_release", range = self.dimen } },
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

function Editor:countSelected()
    local n = 0
    for _f in pairs(self.selected) do n = n + 1 end
    return n
end

-- The books shown: the search, status and language narrow them down, then the
-- chosen order. Ticks are kept; the list goes back to its first page.
function Editor:applyView()
    local list = self.all_books
    if self.query then
        local q = self.query:lower()
        local found = {}
        for _i, b in ipairs(list) do
            local hay = table.concat({ b.title or "", b.authors or "", b.series or "",
                b.file:match("([^/]+)$") or "", self.show_path and self:pathOf(b.file) or "" }, "\n"):lower()
            if hay:find(q, 1, true) then found[#found + 1] = b end
        end
        list = found
    end
    list = KoboldMyBooksData.filter(list, self.status or "all")
    list = KoboldMyBooksData.byLanguage(list, self.lang)
    self.books_shown = KoboldMyBooksData.arrange(list, self.sort, self.alpha)
    self.page = 1
end

function Editor:validateName()
    self.name_error = nil
    local name = trim(self.coll_name)
    if name ~= "" and self.validate then self.name_error = self.validate(name) end
end

function Editor:canFinish()
    if self.mode == "new" then
        return trim(self.coll_name) ~= "" and not self.name_error
    end
    return next(self.selected) ~= nil
end

-- ── Typing ─────────────────────────────────────────────────────────────────
-- The text of the field being typed in, and its caret: a byte offset in that
-- text (nil: at the end, as when the field was just focused or emptied). A
-- slide over the space bar moves it; typing and deleting happen where it is.
function Editor:fieldText()
    if self.focus == "name" then return self.coll_name end
    return self.query or ""
end

function Editor:caretPos()
    local n = #self:fieldText()
    local p = self.pos
    if p == nil or p > n then return n end
    return math.max(0, p)
end

function Editor:setFieldText(text)
    if self.focus == "name" then
        self.coll_name = text
    elseif self.focus == "search" then
        self.query = (text ~= "") and text or nil
    end
end

-- The first byte of the UTF-8 letter that ends at byte `pos`.
local function prevCharStart(text, pos)
    local i = pos
    while i > 1 and text:byte(i) >= 0x80 and text:byte(i) < 0xC0 do i = i - 1 end
    return i
end

-- Adds a character to the field being typed in, at the caret.
function Editor:insert(c)
    if self.focus ~= "name" and self.focus ~= "search" then return end
    local text, pos = self:fieldText(), self:caretPos()
    self:setFieldText(text:sub(1, pos) .. c .. text:sub(pos + 1))
    self.pos = pos + #c
end

-- Removes the letter (a whole UTF-8 letter) before the caret.
function Editor:deleteLast()
    if self.focus ~= "name" and self.focus ~= "search" then return end
    local text, pos = self:fieldText(), self:caretPos()
    if pos == 0 then return end
    local i = prevCharStart(text, pos)
    self:setFieldText(text:sub(1, i - 1) .. text:sub(pos + 1))
    self.pos = i - 1
end

function Editor:fieldIsEmpty()
    if self.focus == "name" then return self.coll_name == "" end
    return (self.query or "") == ""
end

-- Delete held down: the whole field.
function Editor:clearField()
    if self.focus == "name" then
        self.coll_name = ""
    elseif self.focus == "search" then
        self.query = nil
    end
    self.pos = nil
end

-- Focus moves to the name, the search, or nowhere (the keyboard goes down).
function Editor:setFocus(f)
    self.focus = f
    self.pos = nil   -- the caret starts at the end of the field
    self.kb:reset(f == "name" and self.coll_name == "")
    self:build()
    UIManager:setDirty(self, "ui")
end

-- Redraws after an edit, refreshing only the parts of the screen that changed
-- (on e-ink every extra area refreshed is more flashing and ghosting):
--   * typing in the name: just the name field (and the Create pill or the hint
--     under it, only when they switch);
--   * typing in the search: the search field and the list under it, which
--     follows the query;
--   * a key: only its own pad (`rects`), or the whole keyboard when the keys
--     look different (shift, 123, accent).
function Editor:redraw(text_changed, kb_changed, rects)
    local prev_can, prev_error = self.shown_can, self.shown_name_error
    if text_changed then
        if self.focus == "search" then
            self:applyView()
        else
            self:validateName()
        end
    end
    self:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local n = U(2)
    -- the name field in the fast mode, the keys and the rest in "ui"
    local fast, regions = {}, {}
    if text_changed then
        if self.focus == "search" then
            local top = math.max(0, self.search_rect.y - n)
            regions[#regions + 1] = Geom:new{ x = 0, y = top, w = W, h = self.list_end - top }
        elseif self.name_rect then
            local f = self.name_rect
            fast[#fast + 1] = Geom:new{ x = f.x - n, y = f.y - n, w = f.w + 2 * n, h = f.h + 2 * n }
            if self.shown_can ~= prev_can and self.create_rect then
                local c = self.create_rect
                regions[#regions + 1] = Geom:new{ x = c.x - n, y = c.y - n, w = c.w + 2 * n, h = c.h + 2 * n }
            end
            if self.shown_name_error ~= prev_error then
                regions[#regions + 1] = Geom:new{ x = f.x, y = f.y + f.h, w = f.w, h = U(24) }
            end
        end
    end
    if self.kb_y then
        if kb_changed then
            regions[#regions + 1] = Geom:new{ x = 0, y = self.kb_y, w = W, h = H - self.kb_y }
        else
            for _i, r in ipairs(rects or {}) do regions[#regions + 1] = r end
        end
    end
    for _i, r in ipairs(regions) do
        UIManager:setDirty(self, function() return "ui", r end)
    end
    for _i, r in ipairs(fast) do
        UIManager:setDirty(self, function() return Keyboard.REFRESH, r end)
    end
end

-- ── Drawing ────────────────────────────────────────────────────────────────
-- A rounded grey field with its text (or placeholder) and, while it has the
-- keyboard, a caret. The search field has a magnifier and, once something is
-- typed, an X to clear it.
function Editor:fieldBox(w, h, kind)
    local pad = U(18)
    -- The search field is only an outline; the name field is filled.
    local outline = (kind == "search")
    local bs = outline and U(2) or 0
    local inner_w = w - 2 * pad - 2 * bs
    local inner_h = h - 2 * bs
    local face = KoboldWidgets.face(18)
    local focused = (self.focus == kind)
    local text = (kind == "name") and self.coll_name or (self.query or "")
    local placeholder = (kind == "name") and (self.name_placeholder or _("Collection name")) or _("Search books")

    local row = HorizontalGroup:new{ align = "center" }
    local used = 0
    if kind == "search" then
        local size = U(22)
        row[#row + 1] = KoboldWidgets.customIcon("search", size, "appbar.search")
        row[#row + 1] = HorizontalSpan:new{ width = U(10) }
        used = used + size + U(10)
    end
    local clear_w = (kind == "search" and text ~= "") and (U(20) + U(10)) or 0
    local caret_w = focused and U(2) + U(3) or 0
    local avail = inner_w - used - clear_w - caret_w - U(4)
    local function caret()
        local th = TextWidget:new{ text = "Ag", face = face }:getSize().h
        return HorizontalGroup:new{
            HorizontalSpan:new{ width = U(3) },
            LineWidget:new{ dimen = Geom:new{ w = U(2), h = th }, background = BLACK },
        }
    end
    local text_w = 0
    if text == "" then
        if focused then row[#row + 1] = caret() end
        local t = TextWidget:new{ text = placeholder, face = face, fgcolor = C_PLACEHOLDER, max_width = avail }
        row[#row + 1] = t
        text_w = t:getSize().w
    else
        -- the text before the caret (its tail, if long), the caret, and what
        -- is left after it up to the end of the field
        local pos = focused and self:caretPos() or #text
        local before, after = text:sub(1, pos), text:sub(pos + 1)
        if before ~= "" then
            local t = TextWidget:new{ text = tail(before, face, avail), face = face }
            row[#row + 1] = t
            text_w = t:getSize().w
        end
        if focused then row[#row + 1] = caret() end
        if after ~= "" and text_w < avail then
            local a = TextWidget:new{ text = after, face = face, max_width = avail - text_w }
            row[#row + 1] = a
            text_w = text_w + a:getSize().w
        end
    end
    used = used + text_w + caret_w
    if clear_w > 0 then
        row[#row + 1] = HorizontalSpan:new{ width = math.max(0, inner_w - used - clear_w) }
        row[#row + 1] = HorizontalSpan:new{ width = U(10) }
        row[#row + 1] = KoboldWidgets.icon("close", U(20))
    end
    return FrameContainer:new{
        bordersize = bs, color = C_OUTLINE, radius = math.floor(h / 2),
        background = outline and WHITE or C_FIELD,
        padding = 0, padding_left = pad, padding_right = pad,
        KoboldWidgets.fixed(inner_w, inner_h, LeftContainer:new{
            dimen = Geom:new{ w = inner_w, h = inner_h }, row,
        }),
    }
end

-- The folder a book is in, from the root on ("/" for the root itself).
function Editor:pathOf(file)
    local dir = file:match("^(.*)/[^/]+$") or ""
    local root = self.root
    if root and root ~= "" and dir:sub(1, #root) == root then
        dir = dir:sub(#root + 1)
    end
    return dir == "" and "/" or dir
end

-- One book row: cover, title over authors (and the folder it is in), and the
-- tick on the right.
function Editor:bookRow(book, row_w, row_h)
    local gap = U(16)
    local thumb_h = row_h - U(20)
    local thumb_w = math.floor(thumb_h / 1.5)
    local check_w = U(26)
    local text_w = row_w - thumb_w - check_w - 2 * gap
    local text = VerticalGroup:new{
        align = "left",
        TextWidget:new{ text = book.title, face = KoboldWidgets.face(17), max_width = text_w },
    }
    if book.authors then
        text[#text + 1] = VerticalSpan:new{ width = U(4) }
        text[#text + 1] = TextWidget:new{
            text = book.authors, face = KoboldWidgets.face(14),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = text_w,
        }
    end
    if self.show_path then
        text[#text + 1] = VerticalSpan:new{ width = U(2) }
        text[#text + 1] = TextWidget:new{
            text = self:pathOf(book.file), face = KoboldWidgets.face(12),
            fgcolor = C_PLACEHOLDER, max_width = text_w,
        }
    end
    local cover = CenterContainer:new{
        dimen = Geom:new{ w = thumb_w, h = row_h },
        KoboldWidgets.makeCover(book.file, thumb_w, thumb_h),
    }
    if self.mode == "search" then
        -- The "Opening" pill shows on the cover of the book being opened.
        local tw, th = KoboldWidgets.coverBox(book.file, thumb_w, thumb_h)
        tw, th = math.min(tw or thumb_w, thumb_w), math.min(th or thumb_h, thumb_h)
        cover = OverlapGroup:new{
            dimen = Geom:new{ w = thumb_w, h = row_h },
            cover,
            CoverBadge.Overlay:new{
                w = thumb_w, h = row_h, path = book.file,
                rect = {
                    x = math.floor((thumb_w - tw) / 2), y = math.floor((row_h - th) / 2),
                    w = tw, h = th,
                },
            },
        }
    end
    local right
    if self.mode == "search" then
        right = HorizontalSpan:new{ width = 0 }
    else
        right = OptionSheet.iconWidget(self.selected[book.file] and "square-dot" or "square", check_w, BLACK)
    end
    return KoboldWidgets.fixed(row_w, row_h, HorizontalGroup:new{
        align = "center",
        cover,
        HorizontalSpan:new{ width = gap },
        LeftContainer:new{ dimen = Geom:new{ w = text_w, h = row_h }, text },
        HorizontalSpan:new{ width = gap },
        CenterContainer:new{ dimen = Geom:new{ w = check_w, h = row_h }, right },
    })
end

function Editor:emptyText()
    if #self.all_books == 0 then
        if self.mode == "add" then
            return self.empty_text or _("Every book is already in this collection.")
        end
        return _("No books yet.")
    end
    return _("No books match.")
end

function Editor:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local gap = U(12)
    local new = (self.mode == "new")
    local n = self:countSelected()

    local body = VerticalGroup:new{ align = "left" }
    local y = U(32)
    body[#body + 1] = VerticalSpan:new{ width = y }

    -- Header: Cancel, the title, and the Create / Add pill with the count.
    local header_h = U(52)
    local can = self:canFinish()
    -- what the header and the hint show now, to refresh them only when they change
    self.shown_can, self.shown_name_error = can, self.name_error
    local searching = (self.mode == "search")
    local label = (new and _("Create") or (self.action_label or _("Add"))) .. (n > 0 and (" (" .. n .. ")") or "")
    local create, create_w = HorizontalSpan:new{ width = 0 }, 0
    if not searching then
        create, create_w = pill(label, U(40), can and BLACK or C_FIELD, can and WHITE or C_PLACEHOLDER, true)
    end
    local cancel = TextWidget:new{ text = searching and _("Close") or _("Cancel"), face = KoboldWidgets.face(17) }
    local side_w = math.max(create_w, cancel:getSize().w) + U(8)
    local title = TextWidget:new{
        text = self.title or "", face = KoboldWidgets.face(18), bold = true,
        max_width = math.max(U(60), content_w - 2 * side_w - gap),
    }
    body[#body + 1] = KoboldWidgets.fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = content_w - 2 * side_w, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, create },
    })
    self.cancel_rect = Geom:new{ x = margin, y = y, w = side_w, h = header_h }
    self.create_rect = (not searching)
        and Geom:new{ x = margin + content_w - side_w, y = y, w = side_w, h = header_h } or nil
    y = y + header_h
    body[#body + 1] = VerticalSpan:new{ width = U(10) }
    y = y + U(10)

    -- Name field, and under it a line for what is wrong with the name.
    local field_h = U(48)
    self.name_rect = nil
    if new then
        self.name_rect = Geom:new{ x = margin, y = y, w = content_w, h = field_h }
        body[#body + 1] = self:fieldBox(content_w, field_h, "name")
        y = y + field_h
        local hint_h = U(24)
        local hint = self.name_error and TextWidget:new{
            text = self.name_error, face = KoboldWidgets.face(13),
            fgcolor = KoboldWidgets.subtitleColor(), max_width = content_w - U(18),
        } or HorizontalSpan:new{ width = 0 }
        body[#body + 1] = KoboldWidgets.fixed(content_w, hint_h, LeftContainer:new{
            dimen = Geom:new{ w = content_w, h = hint_h },
            HorizontalGroup:new{ HorizontalSpan:new{ width = U(18) }, hint },
        })
        y = y + hint_h
    else
        body[#body + 1] = VerticalSpan:new{ width = U(6) }
        y = y + U(6)
    end

    -- Search field and the adjust button.
    local adj_size = U(26)
    local search_w = content_w - adj_size - U(16)
    body[#body + 1] = KoboldWidgets.fixed(content_w, field_h, HorizontalGroup:new{
        align = "center",
        self:fieldBox(search_w, field_h, "search"),
        HorizontalSpan:new{ width = U(16) },
        OptionSheet.iconWidget("adjust", adj_size, BLACK),
    })
    self.search_rect = Geom:new{ x = margin, y = y, w = search_w - (self.query and (U(20) + U(28)) or 0), h = field_h }
    self.clear_rect = self.query and Geom:new{
        x = margin + search_w - U(18) - U(20) - U(14), y = y, w = U(20) + U(14) + U(18), h = field_h,
    } or nil
    self.adjust_rect = Geom:new{ x = margin + search_w, y = y, w = content_w - search_w, h = field_h }
    y = y + field_h
    body[#body + 1] = VerticalSpan:new{ width = gap }
    y = y + gap

    -- The books, with the keyboard's room taken off the bottom.
    local kb_h = self.focus and self.kb:height() or 0
    local list_h = H - kb_h - (kb_h > 0 and U(6) or U(20)) - y
    local bar_w, bar_gap, arrow = U(28), U(10), U(24)
    local row_w = content_w - bar_w - bar_gap
    -- As many whole rows as fit; the room left over (up to almost one row, more
    -- visible with the keyboard up) is shared out among them, so the books fill
    -- the list to its bottom edge instead of leaving a blank band. If that would
    -- stretch the rows too much (a very short list), they keep their own height.
    local base_h = math.floor(W * 0.17)
    local per_page = math.max(1, math.floor(list_h / base_h))
    local row_h = math.floor(list_h / per_page)
    if row_h > math.floor(base_h * 1.4) then row_h = base_h end
    self.per_page = per_page
    self.pages = math.max(1, math.ceil(#self.books_shown / per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local first = (self.page - 1) * per_page
    self.y_list, self.list_end = y, y + list_h
    self.row_hits = {}

    local rows = VerticalGroup:new{ align = "left" }
    local used = 0
    local page_files = {}
    if #self.books_shown == 0 then
        rows[#rows + 1] = CenterContainer:new{
            dimen = Geom:new{ w = row_w, h = list_h },
            TextWidget:new{
                text = self:emptyText(), face = KoboldWidgets.face(15),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = row_w,
            },
        }
        used = list_h
    end
    for i = 1, per_page do
        local book = self.books_shown[first + i]
        if not book then break end
        page_files[#page_files + 1] = book.file
        rows[#rows + 1] = self:bookRow(book, row_w, row_h)
        self.row_hits[#self.row_hits + 1] = {
            rect = Geom:new{ x = margin, y = y + used, w = row_w, h = row_h }, file = book.file,
        }
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

    local layers = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = margin, body },
    }
    self.kb_y = nil
    if self.focus then
        self.kb_y = H - kb_h
        layers[#layers + 1] = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = self.kb_y },
            self.kb:build(W),
        }
    else
        self.kb:free()
    end
    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = WHITE,
        layers,
    }
end

-- ── Taps ───────────────────────────────────────────────────────────────────
function Editor:dismiss()
    UIManager:close(self, "ui")
    return true
end

function Editor:finish()
    if not self:canFinish() then return end
    local name = trim(self.coll_name)
    local picked = self.selected
    UIManager:close(self, "ui")
    if self.on_done then self.on_done(name, picked) end
end

function Editor:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:build()
    local W = Screen:getWidth()
    local region = Geom:new{ x = 0, y = self.y_list, w = W, h = self.list_end - self.y_list }
    UIManager:setDirty(self, function() return "ui", region end)
end

-- The Sort & Filter sheet of Home and Library, over this list.
function Editor:showAdjust()
    if self.focus then self:setFocus(nil) end
    local function apply(field, id)
        self[field] = id
        self:applyView()
        self:build()
        UIManager:setDirty(self, "ui")
    end
    ViewSheet.show{
        status = { selected = self.status, on_pick = function(id) apply("status", id) end },
        sort   = { selected = self.sort,   on_pick = function(id) apply("sort", id) end },
        alpha  = { selected = self.alpha,  on_pick = function(id) apply("alpha", id) end },
        lang   = {
            list = BookLang.languages(self.all_books), selected = self.lang,
            on_pick = function(id) apply("lang", id) end,
        },
    }
end

local function inside(r, pos)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

function Editor:onTapEditor(_ev, ges)
    local pos = ges.pos
    if inside(self.cancel_rect, pos) then return self:dismiss() end
    if inside(self.create_rect, pos) then
        self:finish()
        return true
    end
    -- the keyboard
    if self.focus and self.kb_y and pos.y >= self.kb_y then
        local handled, text_changed, kb_changed, rects = self.kb:tap(pos, self.kb_y)
        if handled and self.focus and (text_changed or kb_changed) then
            self:redraw(text_changed, kb_changed, rects)
        end
        return true
    end
    if inside(self.clear_rect, pos) then
        self.query = nil
        self:applyView()
        self:build()
        UIManager:setDirty(self, "ui")
        return true
    end
    if inside(self.name_rect, pos) then
        if self.focus ~= "name" then self:setFocus("name") end
        return true
    end
    if inside(self.search_rect, pos) then
        if self.focus ~= "search" then self:setFocus("search") end
        return true
    end
    if inside(self.adjust_rect, pos) then
        self:showAdjust()
        return true
    end
    if inside(self.bar_rect, pos) then
        local page = KoboldWidgets.pageBarTarget(pos.y - self.y_list, self.bar)
        if page then self:goToPage(page) end
        return true
    end
    for _i, hit in ipairs(self.row_hits or {}) do
        if inside(hit.rect, pos) and self.mode == "search" then
            -- open the book; the "Opening" pill shows on this screen
            KoboldReader.tapOpen(self, hit.file, { pill_screen = self })
            return true
        elseif inside(hit.rect, pos) then
            self.selected[hit.file] = (not self.selected[hit.file]) or nil
            self:redraw(false, false)
            -- the tick and the count in the Create pill
            local W = Screen:getWidth()
            local region = Geom:new{ x = 0, y = 0, w = W, h = self.list_end }
            UIManager:setDirty(self, function() return "ui", region end)
            return true
        end
    end
    return true
end

-- Hold the keyboard's delete key: the field is cleared.
function Editor:onHoldEditor(_ev, ges)
    if self.focus and self.kb_y and ges.pos.y >= self.kb_y then
        local _handled, text_changed, kb_changed, rects = self.kb:hold(ges.pos, self.kb_y)
        if self.focus and (text_changed or kb_changed) then
            self:redraw(text_changed, kb_changed, rects)
        end
    end
    return true
end

-- Sliding the finger over the keyboard's space bar moves the caret. While the
-- finger is down the field is refreshed in the fast mode; when it lets go, once
-- more in "ui".
function Editor:fieldRegion()
    local r = (self.focus == "name") and self.name_rect or self.search_rect
    if not r then return nil end
    local n = U(2)
    return Geom:new{ x = r.x - n, y = r.y - n, w = r.w + 2 * n, h = r.h + 2 * n }
end

function Editor:onPanEditor(_ev, ges)
    if not (self.focus and self.kb_y) then return false end
    local handled, moved = self.kb:pan(ges, self.kb_y)
    if moved then
        self:build()
        local region = self:fieldRegion()
        if region then
            UIManager:setDirty(self, function() return Keyboard.REFRESH, region end)
        end
    end
    return handled
end

function Editor:onHoldPanEditor(ev, ges) return self:onPanEditor(ev, ges) end

function Editor:onPanReleaseEditor()
    local was = self.kb:panEnd()
    if was and self.focus then
        local region = self:fieldRegion()
        if region then
            UIManager:setDirty(self, function() return "ui", region end)
        end
    end
    return was
end

function Editor:onHoldReleaseEditor() return self:onPanReleaseEditor() end

-- Swipe up for the next page, down for the previous one, like Library.
function Editor:onSwipeEditor(_ev, ges)
    if self.kb:recentDrag() then return true end
    -- A swipe that started on a key is a tap (see Keyboard:swipe): typing fast,
    -- the touch driver sometimes reads a tap as a short swipe. A real swipe
    -- over the keyboard still turns the page, as before.
    if self.focus and self.kb_y and ges.pos.y >= self.kb_y then
        local handled, text_changed, kb_changed, rects = self.kb:swipe(ges, self.kb_y)
        if handled then
            if self.focus and (text_changed or kb_changed) then
                self:redraw(text_changed, kb_changed, rects)
            end
            return true
        end
    end
    if ges.pos.y < (self.y_list or 0) then return true end
    if ges.direction == "north" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "south" then
        self:goToPage(self.page - 1)
    end
    return true
end

-- Back: first the keyboard goes down, then the screen closes.
function Editor:onClose()
    if self.focus then
        self:setFocus(nil)
        return true
    end
    return self:dismiss()
end

-- KoboldCoversUpdated: covers finished extracting, redraw the rows.
function Editor:onKoboldCoversUpdated()
    self:build()
    UIManager:setDirty(self, "ui")
end

-- A book is opening (from here): this screen is not needed under the reader.
-- The screen it was opened over is parked by its own handler (session.lua).
function Editor:onShowingReader()
    UIManager:nextTick(function() UIManager:close(self) end)
end

function Editor:onCloseWidget()
    self.kb:free()
end

local CollectionEditor = {}

function CollectionEditor.show(opts)
    UIManager:show(Editor:new(opts), "ui")
end

return CollectionEditor
