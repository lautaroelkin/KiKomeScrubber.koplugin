-- kobold/ui/book_menu.lua — Kobold
-- The small menu for one book: Read now, View Details (Kobold's details
-- page) and, only in the Library tab, KOReader Details (the file browser's own
-- book menu). Opened from a book's "..." in My Books and by holding one of
-- Home's recent books (there without the KOReader row: a book is edited from
-- the Library tab only).
-- A box with rounded corners next to what opened it: below it when there is
-- room, otherwise above it (or beside it, for a row's "...").

local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local InputContainer  = require("ui/widget/container/inputcontainer")
local LeftContainer   = require("ui/widget/container/leftcontainer")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local lfs             = require("libs/libkoreader-lfs")
local VerticalGroup   = require("ui/widget/verticalgroup")
local _               = require("gettext")
local OptionSheet     = require("kobold.ui.option_sheet")
local KoboldMeta      = require("kobold.meta")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local KoboldBookMenu = InputContainer:extend{
    modal = true,
    name = "kobold_book_menu",
    file = nil,
    screen = nil,   -- the Kobold screen it opened from
    anchor = nil,   -- Geom of what it points at (a cover, a "..."), screen coordinates
    align = "right", -- "right": box ends at the anchor's right edge; "left": starts at its left
    side = false,    -- true: beside the anchor (to its left)
    on_change = nil, -- runs after the KOReader menu changed something
    koreader = false, -- true (Library tab): the KOReader Details row, and "..." on the details page
    on_remove = nil, -- inside a collection: adds "Remove from collection" and runs this when tapped
    on_select = nil, -- Files tab: adds "Select" and runs this when tapped
    items = nil,     -- a list of { text, icon, action = function } that replaces the book rows
}

-- The first icon of `names` (a name or a list of names) whose svg exists in
-- the plugin's icons folder, so a missing file never shows as a stray glyph.
local function pickIcon(names)
    if type(names) ~= "table" then return names end
    for _i, name in ipairs(names) do
        local path = KoboldMeta.icon(name .. ".svg")
        if path and lfs.attributes(path, "mode") == "file" then return name end
    end
    return names[#names]
end

local function italicFace(size)
    local ok, face = pcall(function() return KoboldWidgets.italicFace(size) end)
    if ok and face then return face end
    return KoboldWidgets.face(size)
end

function KoboldBookMenu:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local pad, border = Screen:scaleBySize(4), Screen:scaleBySize(2)
    local row_h = Screen:scaleBySize(42)
    local text_pad = Screen:scaleBySize(14)
    -- Each row: an svg icon, then the text (same measures as the Page Scrubber
    -- settings rows). The icons are svg files in the plugin's icons folder.
    local icon_size = Screen:scaleBySize(17)
    local icon_pad  = Screen:scaleBySize(18)   -- before the icon
    local icon_gap  = Screen:scaleBySize(8)    -- between icon and text
    local line_h = Screen:scaleBySize(1)
    local fw = math.floor(W * 0.45)
    local inner = fw - 2 * (pad + border)
    local margin = Screen:scaleBySize(12)
    local gap = Screen:scaleBySize(6)        -- between the anchor and the box
    local radius = Screen:scaleBySize(14)    -- rounded corners

    local items = self.items
    if not items then
        items = {
            { text = _("Read now"), action = "read", icon = "book-open-text" },
            { text = _("View Details"), action = "details", icon = "notepad-text" },
        }
        if self.on_select then
            items[#items + 1] = { text = _("Select"), action = "select", icon = { "crop", "square-dot" } }
        end
        if self.koreader then
            items[#items + 1] = { text = _("KOReader Details"), action = "koreader", icon = "square-arrow-right-enter" }
        end
        if self.on_remove then
            items[#items + 1] = { text = _("Remove from collection"), action = "remove", icon = "trash-2" }
        end
    end
    local list = VerticalGroup:new{ align = "left" }
    for i, item in ipairs(items) do
        if i > 1 then
            list[#list + 1] = LineWidget:new{
                dimen = Geom:new{ w = inner, h = line_h }, background = Blitbuffer.COLOR_LIGHT_GRAY,
            }
        end
        list[#list + 1] = KoboldWidgets.fixed(inner, row_h, LeftContainer:new{
            dimen = Geom:new{ w = inner, h = row_h },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = icon_pad },
                OptionSheet.iconWidget(pickIcon(item.icon), icon_size, Blitbuffer.COLOR_BLACK),
                HorizontalSpan:new{ width = icon_gap },
                TextWidget:new{
                    text = item.text, face = italicFace(17),
                    max_width = inner - icon_pad - icon_size - icon_gap - text_pad,
                },
            },
        })
    end
    local box = FrameContainer:new{
        bordersize = border, padding = pad,
        radius = radius,
        background = Blitbuffer.COLOR_WHITE,
        list,
    }
    local fh = box:getSize().h

    local a = self.anchor
    if self.side then
        -- Beside the anchor, to its left, with the box centred on it (the
        -- "..." sits at the box's middle), moved only as far as needed to
        -- stay on screen.
        local mid = a.y + math.floor(a.h / 2)
        local fx = math.max(margin, a.x - gap - fw)
        local fy = math.max(margin, math.min(H - margin - fh, mid - math.floor(fh / 2)))
        self.frame_dimen = Geom:new{ x = fx, y = fy, w = fw, h = fh }
        self:recordRows(fx, fy, border, pad, row_h, line_h, items)
        return self:place(fx, fy, box)
    end

    -- Below the anchor when it fits, else above it; never off screen.
    local below = a.y + a.h + gap + fh + margin <= H
    local fy = below and (a.y + a.h + gap) or (a.y - gap - fh)
    local fx = self.align == "left" and a.x or (a.x + a.w - fw)
    fx = math.max(margin, math.min(W - margin - fw, fx))
    fy = math.max(margin, fy)

    self.frame_dimen = Geom:new{ x = fx, y = fy, w = fw, h = fh }
    self:recordRows(fx, fy, border, pad, row_h, line_h, items)
    return self:place(fx, fy, box)
end

-- The box at (fx, fy) on a full-screen layer.
function KoboldBookMenu:place(fx, fy, box)
    box.overlap_offset = { fx, fy }
    return OverlapGroup:new{
        dimen = Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.dimen.h },
        box,
    }
end

-- Tap rectangle of each row, in screen coordinates.
function KoboldBookMenu:recordRows(fx, fy, border, pad, row_h, line_h, items)
    self.rows = {}
    local y = fy + border + pad
    for i, item in ipairs(items) do
        self.rows[i] = { rect = Geom:new{ x = fx, y = y, w = self.frame_dimen.w, h = row_h }, action = item.action }
        y = y + row_h + line_h
    end
end

function KoboldBookMenu:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self[1] = self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapMenu = { GestureRange:new{ ges = "tap", range = self.dimen } },
        }
    end
end

function KoboldBookMenu:onTapMenu(_, ges)
    for _i, row in ipairs(self.rows) do
        if ges.pos:intersectWith(row.rect) then
            self:onClose()
            UIManager:nextTick(function() self:run(row.action) end)
            return true
        end
    end
    -- Outside the rows: just close.
    return self:onClose()
end

function KoboldBookMenu:run(action)
    if type(action) == "function" then
        action()
    elseif action == "read" then
        require("kobold.ui.reader").open(self.screen, self.file)
    elseif action == "details" then
        -- Outside the Library tab the details page has no "..." to KOReader's menu either.
        require("kobold.ui.book_details").show(self.file, self.screen, self.on_change, not self.koreader)
    elseif action == "select" then
        if self.on_select then self.on_select() end
    elseif action == "remove" then
        if self.on_remove then self.on_remove() end
    elseif action == "koreader" then
        if not KoboldWidgets.showBookMenu(self.file, self.on_change) then
            UIManager:show(require("ui/widget/infomessage"):new{
                text = _("The KOReader book menu is not available."),
            })
        end
    end
end

function KoboldBookMenu:onClose()
    UIManager:close(self)
    return true
end

function KoboldBookMenu:onShow()
    UIManager:setDirty(self, "ui", self.frame_dimen)
    return true
end

function KoboldBookMenu:onCloseWidget()
    UIManager:setDirty(nil, "ui", self.frame_dimen)
end

-- Opens the menu. opts = { file, screen, anchor (Geom), align, side, on_change,
-- koreader, on_remove, on_select, items }. With `items` it is a plain menu of
-- the given rows (the Library's More and selection menus), not a book's. It is always Kobold's own menu; `koreader` (the Library tab sets
-- it) adds the row that opens KOReader's book menu.
function KoboldBookMenu.show(opts)
    UIManager:show(KoboldBookMenu:new(opts))
end

return KoboldBookMenu
