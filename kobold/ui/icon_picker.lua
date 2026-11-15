-- kobold/ui/icon_picker.lua — KiKome
-- A full-screen icon picker: the folders of the device and their svg / png
-- files as a grid of tiles, in the look of the list picker (list_picker.lua):
-- Cancel on the left, the title in the middle, a black action pill on the
-- right, the open folder under them, then the tiles with a page bar on the
-- right. Tap a folder to open it, tap an icon to pick it (tap it again to let
-- it go), swipe up / down to turn the page.
--
-- It opens in the plugin's own icons folder (the one the icon that was
-- already chosen is in, or the last folder used, when there is one); the
-- "Parent folder" tile goes up from there to any folder of KOReader.
--
--   require("kobold.ui.icon_picker").show{
--       title        = "Choose an icon",
--       action_label = "Use icon",        -- the black pill with an icon picked
--       none_label   = "Skip",            -- optional: with it the pill also works with
--                                         -- nothing picked, and on_finish gets nil
--       current      = "/a/icon.svg",     -- optional: an icon spec (see action_icon.lua)
--       on_finish    = function(spec) end,   -- the screen is already closed; spec is a
--                                            -- file path, "kobold:<name>" for one of the
--                                            -- plugin's own icons, or nil
--   }
--
-- Pictures that are too big to draw quickly (an svg over 200 KB, a png over
-- 1 MP or 1 MB) show a plain picture icon on their tile; they can still be picked.

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
local ActionIcon      = require("kobold.ui.action_icon")
local KoboldWidgets   = require("kobold.ui.widgets")
local OptionSheet     = require("kobold.ui.option_sheet")

local Screen = Device.screen
local BLACK, WHITE = Blitbuffer.COLOR_BLACK, Blitbuffer.COLOR_WHITE
local C_FIELD       = Blitbuffer.Color8(0xE8)   -- the tiles, the pill when off
local C_PLACEHOLDER = Blitbuffer.Color8(0x77)

local function U(n) return Screen:scaleBySize(n) end

local SCAN_MAX = 600     -- entries looked at to count the icons of a folder
local MAX_SVG  = 200 * 1024
local MAX_PNG_BYTES, MAX_PNG_PIXELS = 1024 * 1024, 1000 * 1000

-- Files that are not worth asking whether they are folders.
local NOT_FOLDERS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, kepub = true, cbz = true,
    cbr = true, fb2 = true, djvu = true, txt = true, zip = true, rar = true, json = true,
    xml = true, html = true, htm = true, db = true, lua = true, mp3 = true, mp4 = true,
    gif = true, webp = true, bmp = true, jpg = true, jpeg = true, doc = true, docx = true,
    odt = true, po = true, pot = true, md = true, ttf = true, otf = true,
}

local last_dir = nil   -- the folder the picker closed in, for the next time

local function isDir(path) return path ~= nil and lfs.attributes(path, "mode") == "directory" end

local function parentOf(dir)
    local parent = dir:match("^(.*)/[^/]+/*$")
    if not parent or parent == "" then return "/" end
    return parent
end

-- The spec to keep for a picked file: one of the plugin's own icons by name,
-- anything else by its path.
local function specFor(path)
    local dir = ActionIcon.builtinDir()
    if dir and path:sub(1, #dir + 1) == dir .. "/" then
        local name = path:sub(#dir + 2):match("^([^/]+)%.svg$")
        if name then return "kobold:" .. name end
    end
    return path
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

-- Text with its first characters cut (and "…" put first) until it fits, so
-- the end of a path stays visible.
local function tail(text, face, max_w)
    local function width(s)
        local t = TextWidget:new{ text = s, face = face }
        local w = t:getSize().w
        t:free()
        return w
    end
    if width(text) <= max_w then return text end
    local guard = 0
    while text ~= "" and width("…" .. text) > max_w and guard < 300 do
        text = (text:gsub("^[%z\1-\127\194-\244][\128-\191]*", "", 1))
        guard = guard + 1
    end
    return "…" .. text
end

local function inside(r, pos)
    return r and pos.x >= r.x and pos.x < r.x + r.w and pos.y >= r.y and pos.y < r.y + r.h
end

local Picker = InputContainer:extend{
    name = "kobold_icon_picker",
    covers_fullscreen = true,
    dithered = true,
    title = nil, action_label = nil, none_label = nil, current = nil, on_finish = nil,
}

function Picker:init()
    local W, H = Screen:getWidth(), Screen:getHeight()
    self.dimen = Geom:new{ x = 0, y = 0, w = W, h = H }
    self.page = 1
    self.counts, self.cache = {}, {}

    -- Where it opens: the folder of the icon in use, else the last folder used,
    -- else the plugin's own icons, else the home folder.
    local current = ActionIcon.path(self.current)
    local start = current and current:match("^(.*)/[^/]+$") or nil
    if not isDir(start) then start = last_dir end
    if not isDir(start) then start = ActionIcon.builtinDir() end
    if not isDir(start) then start = G_reader_settings and G_reader_settings:readSetting("home_dir") end
    if not isDir(start) then start = "/" end
    self.dir = (start:gsub("(.)/+$", "%1"))
    self.picked = current

    self:readDir()
    self:build()
    if Device:hasKeys() then
        self.key_events = { Close = { { Device.input.group.Back } } }
    end
    if Device:isTouchDevice() then
        self.ges_events = {
            TapPicker = { GestureRange:new{ ges = "tap", range = self.dimen } },
            SwipePicker = { GestureRange:new{ ges = "swipe", range = self.dimen } },
        }
        KoboldWidgets.registerBarDrag(self, {
            rect = function() return self.bar_rect end,
            bar  = function() return self.bar end,
            top  = function() return self.bar_rect.y end,
            goTo = function(page) self:goToPage(page) end,
        })
    end
end

-- The folders and icons of the open folder: the "Parent folder" tile, the
-- folders, then the icons, each group by name.
function Picker:readDir()
    local dir = self.dir
    local folders, icons = {}, {}
    local ok, iter, st = pcall(lfs.dir, dir)
    if ok then
        for name in iter, st do
            if name:sub(1, 1) ~= "." and not name:match("%.sdr$") then
                local path = (dir == "/" and "" or dir) .. "/" .. name
                if ActionIcon.isIconFile(name) then
                    icons[#icons + 1] = { kind = "icon", name = name, key = name:lower(), path = path }
                else
                    local ext = name:match("%.(%w+)$")
                    if not (ext and NOT_FOLDERS[ext:lower()]) and isDir(path) then
                        folders[#folders + 1] = { kind = "folder", name = name, key = name:lower(), path = path }
                    end
                end
            end
        end
    end
    local function byKey(a, b)
        if a.key ~= b.key then return a.key < b.key end
        return a.name < b.name
    end
    table.sort(folders, byKey)
    table.sort(icons, byKey)
    local items = {}
    if dir ~= "/" then
        items[#items + 1] = { kind = "up", name = _("Parent folder"), path = parentOf(dir) }
    end
    for _i, f in ipairs(folders) do items[#items + 1] = f end
    for _i, f in ipairs(icons) do items[#items + 1] = f end
    self.items = items
end

-- "3 icons" under a folder's name, counted by name alone (nothing is opened or
-- measured), looking at no more than SCAN_MAX entries.
function Picker:folderCount(path)
    local known = self.counts[path]
    if known ~= nil then return known end
    local text = ""
    local ok, iter, st = pcall(lfs.dir, path)
    if ok then
        local n, seen, cut = 0, 0, false
        for name in iter, st do
            seen = seen + 1
            if name:sub(1, 1) ~= "." and ActionIcon.isIconFile(name) then n = n + 1 end
            if seen >= SCAN_MAX then cut = true; break end
        end
        if n == 0 then
            text = cut and "" or _("No icons")
        elseif cut then
            text = string.format(_("%d+ icons"), n)
        else
            text = (n == 1) and _("1 icon") or string.format(_("%d icons"), n)
        end
    end
    self.counts[path] = text
    return text
end

-- The picture on an icon's tile. Made once per folder and size.
function Picker:iconInner(item, size)
    local key = item.path .. "|" .. size
    local made = self.cache[key]
    if made then return made end
    local light = false
    local attr = lfs.attributes(item.path)
    if attr then
        if item.name:lower():match("%.svg$") then
            light = (attr.size or 0) <= MAX_SVG
        else
            local ok, info = pcall(function() return require("kobold.data.image_thumbs").info(item.path) end)
            light = ok and info and info.width and info.height
                and info.width * info.height <= MAX_PNG_PIXELS
                and (attr.size or 0) <= MAX_PNG_BYTES or false
        end
    end
    if light then
        made = ActionIcon.widget(item.path, size, "image")
    else
        made = OptionSheet.iconWidget("image", size, C_PLACEHOLDER)
    end
    self.cache[key] = made
    return made
end

-- One cell of the grid: a grey tile with its picture, the name under it and,
-- for a folder, how many icons it holds.
function Picker:cell(item, cell_w, tile)
    local selected = (item.kind == "icon" and item.path == self.picked)
    local b = selected and U(3) or 0
    local inner
    if item.kind == "icon" then
        inner = self:iconInner(item, math.floor(tile * 0.56))
    elseif item.kind == "folder" then
        inner = OptionSheet.iconWidget("folder", math.floor(tile * 0.46), BLACK)
    else
        inner = OptionSheet.iconWidget("arrow-left", math.floor(tile * 0.40), BLACK)
    end
    local inside_w = tile - 2 * b
    local box = FrameContainer:new{
        bordersize = b, color = BLACK, background = C_FIELD, radius = U(14), padding = 0,
        KoboldWidgets.fixed(inside_w, inside_w, CenterContainer:new{
            dimen = Geom:new{ w = inside_w, h = inside_w }, inner,
        }),
    }
    local label_h, sub_h = U(22), U(18)
    local label = TextWidget:new{
        text = item.name, face = KoboldWidgets.face(14), fgcolor = BLACK,
        max_width = cell_w - U(8), bold = selected,
    }
    local sub
    if item.kind == "folder" then
        local count = self:folderCount(item.path)
        if count ~= "" then
            sub = TextWidget:new{
                text = count, face = KoboldWidgets.secondaryFace(12),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = cell_w - U(8),
            }
        end
    end
    return VerticalGroup:new{
        align = "left",
        VerticalSpan:new{ width = U(4) },
        CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = tile }, box },
        VerticalSpan:new{ width = U(6) },
        CenterContainer:new{ dimen = Geom:new{ w = cell_w, h = label_h }, label },
        CenterContainer:new{
            dimen = Geom:new{ w = cell_w, h = sub_h },
            sub or HorizontalSpan:new{ width = 0 },
        },
    }
end

function Picker:canFinish()
    return self.picked ~= nil or self.none_label ~= nil
end

function Picker:build()
    local W, H = Screen:getWidth(), Screen:getHeight()
    local margin = U(30)
    local content_w = W - 2 * margin
    local gap = U(12)

    local body = VerticalGroup:new{ align = "left" }
    local y = U(32)
    body[#body + 1] = VerticalSpan:new{ width = y }

    -- Header: Cancel, the title, and the action pill.
    local header_h = U(52)
    local can = self:canFinish()
    local has_pick = self.picked ~= nil
    local label = has_pick and (self.action_label or _("Use icon"))
        or (self.none_label or self.action_label or _("Use icon"))
    local create, create_w = pill(label, U(40), can and BLACK or C_FIELD, can and WHITE or C_PLACEHOLDER, true)
    local cancel = TextWidget:new{ text = _("Cancel"), face = KoboldWidgets.face(17) }
    local side_w = math.max(create_w, cancel:getSize().w) + U(8)
    local title = TextWidget:new{
        text = self.title or _("Choose an icon"), face = KoboldWidgets.face(18), bold = true,
        max_width = math.max(U(60), content_w - 2 * side_w - gap),
    }
    body[#body + 1] = KoboldWidgets.fixed(content_w, header_h, HorizontalGroup:new{
        align = "center",
        LeftContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, cancel },
        CenterContainer:new{ dimen = Geom:new{ w = content_w - 2 * side_w, h = header_h }, title },
        RightContainer:new{ dimen = Geom:new{ w = side_w, h = header_h }, create },
    })
    self.cancel_rect = Geom:new{ x = margin, y = y, w = side_w, h = header_h }
    self.create_rect = Geom:new{ x = margin + content_w - side_w, y = y, w = side_w, h = header_h }
    y = y + header_h
    body[#body + 1] = VerticalSpan:new{ width = U(6) }
    y = y + U(6)

    -- The line under the header: the folder that is open.
    local sub_h = U(28)
    local face = KoboldWidgets.secondaryFace(14)
    body[#body + 1] = KoboldWidgets.fixed(content_w, sub_h, LeftContainer:new{
        dimen = Geom:new{ w = content_w, h = sub_h },
        TextWidget:new{
            text = tail(self.dir, face, content_w - U(8)), face = face,
            fgcolor = KoboldWidgets.subtitleColor(),
        },
    })
    y = y + sub_h
    body[#body + 1] = VerticalSpan:new{ width = gap }
    y = y + gap

    -- The grid: as many whole rows as fit.
    local grid_h = H - U(20) - y
    local bar_w, bar_gap, arrow = U(28), U(10), U(24)
    local grid_w = content_w - bar_w - bar_gap
    local cols = math.max(3, math.min(6, math.floor(grid_w / U(130))))
    local cell_w = math.floor(grid_w / cols)
    local tile = cell_w - U(16)
    local cell_h = U(4) + tile + U(6) + U(22) + U(18) + U(10)
    local rows_per_page = math.max(1, math.floor(grid_h / cell_h))
    local per_page = cols * rows_per_page
    self.pages = math.max(1, math.ceil(#self.items / per_page))
    self.page = math.max(1, math.min(self.page, self.pages))
    local first = (self.page - 1) * per_page
    self.y_grid, self.grid_end = y, y + grid_h
    self.cell_hits = {}

    local grid = VerticalGroup:new{ align = "left" }
    if #self.items == 0 then
        grid[#grid + 1] = CenterContainer:new{
            dimen = Geom:new{ w = grid_w, h = grid_h },
            TextWidget:new{
                text = _("No folders or icons here."), face = KoboldWidgets.secondaryFace(15),
                fgcolor = KoboldWidgets.subtitleColor(), max_width = grid_w,
            },
        }
    else
        local used = 0
        for r = 0, rows_per_page - 1 do
            local row = HorizontalGroup:new{}
            local any = false
            for c = 1, cols do
                local item = self.items[first + r * cols + c]
                if item then
                    any = true
                    row[#row + 1] = self:cell(item, cell_w, tile)
                    self.cell_hits[#self.cell_hits + 1] = {
                        rect = Geom:new{
                            x = margin + (c - 1) * cell_w, y = y + r * cell_h, w = cell_w, h = cell_h,
                        },
                        item = item,
                    }
                else
                    row[#row + 1] = HorizontalSpan:new{ width = cell_w }
                end
            end
            if not any then break end
            grid[#grid + 1] = row
            used = used + cell_h
        end
        grid[#grid + 1] = VerticalSpan:new{ width = math.max(0, grid_h - used) }
    end

    self.bar = { w = bar_w, h = grid_h, page = self.page, pages = self.pages, arrow = arrow }
    local bar_x = margin + grid_w + math.floor(bar_gap / 2)
    self.bar_rect = Geom:new{ x = bar_x, y = y, w = W - bar_x, h = grid_h }
    body[#body + 1] = HorizontalGroup:new{
        align = "top",
        grid,
        HorizontalSpan:new{ width = bar_gap },
        KoboldWidgets.pageBar(self.bar),
    }

    local layers = OverlapGroup:new{
        dimen = Geom:new{ w = W, h = H },
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = margin, body },
    }
    self[1] = FrameContainer:new{
        width = W, height = H, bordersize = 0, padding = 0,
        background = WHITE,
        layers,
    }
end

-- ── Taps ───────────────────────────────────────────────────────────────────
function Picker:markClosed()
    if self.closed then return end
    self.closed = true
    self.cache = {}
    pcall(function() require("kobold.data.image_thumbs").clear() end)
end

function Picker:dismiss()
    self:markClosed()
    UIManager:close(self, "ui")
    return true
end

function Picker:finish()
    if not self:canFinish() then return end
    local picked = self.picked
    if picked then last_dir = self.dir end
    self:markClosed()
    UIManager:close(self, "ui")
    if self.on_finish then self.on_finish(picked and specFor(picked) or nil) end
end

function Picker:goToPage(page)
    page = math.max(1, math.min(self.pages, page))
    if page == self.page then return end
    self.page = page
    self:build()
    local region = Geom:new{ x = 0, y = self.y_grid, w = Screen:getWidth(), h = self.grid_end - self.y_grid }
    UIManager:setDirty(self, function() return "ui", region end)
end

-- Opens a folder: its icons are read, the page goes back to the first.
function Picker:openDir(path)
    self.dir = path
    self.page = 1
    self.cache = {}
    self:readDir()
    self:build()
    UIManager:setDirty(self, "ui")
end

function Picker:onTapPicker(_ev, ges)
    local pos = ges.pos
    if inside(self.cancel_rect, pos) then return self:dismiss() end
    if inside(self.create_rect, pos) then
        self:finish()
        return true
    end
    if inside(self.bar_rect, pos) then
        local page = KoboldWidgets.pageBarTarget(pos.y - self.y_grid, self.bar)
        if page then self:goToPage(page) end
        return true
    end
    for _i, hit in ipairs(self.cell_hits or {}) do
        if inside(hit.rect, pos) then
            local item = hit.item
            if item.kind == "icon" then
                -- one icon at a time: tapping it again lets it go
                self.picked = (self.picked ~= item.path) and item.path or nil
                self:build()
                UIManager:setDirty(self, "ui")
            else
                self:openDir(item.path)
            end
            return true
        end
    end
    return true
end

-- Swipe up for the next page, down for the previous one, like the Library.
function Picker:onSwipePicker(_ev, ges)
    if ges.pos.y < (self.y_grid or 0) then return true end
    if ges.direction == "north" then
        self:goToPage(self.page + 1)
    elseif ges.direction == "south" then
        self:goToPage(self.page - 1)
    end
    return true
end

function Picker:onClose()
    return self:dismiss()
end

local IconPicker = {}

function IconPicker.show(opts)
    local picker = Picker:new(opts)
    UIManager:show(picker, "ui")
    return picker
end

return IconPicker
