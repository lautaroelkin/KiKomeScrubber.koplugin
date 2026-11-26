-- kobold/ui/widgets.lua — Kobold
-- Small widget helpers shared by the Kobold screens.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local IconWidget      = require("ui/widget/iconwidget")
local ImageWidget     = require("ui/widget/imagewidget")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local lfs             = require("libs/libkoreader-lfs")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local KoboldMeta      = require("kobold.meta")
local KoboldCovers    = require("kobold.data.covers")
local KoboldPrefs     = require("kobold.data.prefs")
local KoboldFonts     = require("kobold.data.fonts")
local KoboldClock     = require("kobold.data.clock")
local KoboldBattery   = require("kobold.ui.battery")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldMetrics   = require("kobold.ui.metrics")

local Screen = Device.screen

local KoboldWidgets = {}

-- A box exactly w x h with `child` drawn at its top-left corner. Use this
-- instead of FrameContainer width/height: FrameContainer:getSize() ignores
-- those and reports its content's size, so groups lay it out too small.
function KoboldWidgets.fixed(w, h, child)
    return OverlapGroup:new{
        dimen = Geom:new{ w = w, h = h },
        child,
    }
end

-- The plugin has two fonts (Settings > Appearance > Fonts; KOReader's own font until one is
-- chosen, see data/fonts.lua). Every text asks for one of these two faces:
--
--   face(size)           PRIMARY: most of the text. Titles, names, rows, menus,
--                        buttons, tabs, chips, the status bar, badges.
--   secondaryFace(size)  SECONDARY: the details. Authors, book counts, section
--                        headings, notes and hints, values on the right,
--                        counters, placeholders.
--
-- To move a text from one to the other, change which of the two it calls.
function KoboldWidgets.face(size)
    return KoboldFonts.face("primary", size)
end

function KoboldWidgets.secondaryFace(size)
    return KoboldFonts.face("secondary", size)
end

function KoboldWidgets.bookTitle(file)
    local t = file:match("([^/]+)%.[^%.]+$") or file
    if #t > 40 then t = t:sub(1, 37) .. "..." end
    return t
end

-- Size of a real cover fitted inside w x h, keeping its aspect ratio.
-- Returns w, h unchanged when there is no cover (placeholder size).
function KoboldWidgets.coverSize(file, w, h)
    local sw, sh = KoboldCovers.fittedSize(file, w, h)
    if not sw then return w, h end
    return sw, sh
end

-- Thickness of the grey outline around a cover: 0 when the caller turns it off
-- (opts.outline == false) or when the "cover_outline" setting is off. Every
-- cover drawing and measuring goes through here, so a single setting removes
-- the outline everywhere (makeCover, coverBox, Rounded, the badge's position).
function KoboldWidgets.outlineWidth(opts)
    if opts and opts.outline == false then return 0 end
    if KoboldPrefs.get("cover_outline") == false then return 0 end
    return Screen:scaleBySize(1)
end

-- Size makeCover really gives a cover asked for in w x h: the image is fitted
-- inside the outline, so the whole thing can be a pixel or two smaller than
-- coverSize says. Anything laid over a cover (badges, buttons) must use this.
function KoboldWidgets.coverBox(file, w, h, opts)
    local line = KoboldWidgets.outlineWidth(opts)
    local sw, sh = KoboldCovers.fittedSize(file, w - 2 * line, h - 2 * line)
    if not sw then return w, h end
    return sw + 2 * line, sh + 2 * line
end

-- Some cover images carry a thin light frame of their own along the edge (IT's,
-- for one). With the outline on it hides under ours; with it off it would show
-- as a stray outline. So, with the outline off, the outer rows and columns of
-- the cover are painted over with the ones next to them: the same picture, with
-- no frame, and nothing moves (the cover keeps its size).
local EdgeTrim = Widget:extend{ child = nil, k = 1 }

function EdgeTrim:getSize() return self.child:getSize() end

function EdgeTrim:paintTo(bb, x, y)
    local sz = self.child:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = sz.w, h = sz.h }
    self.child:paintTo(bb, x, y)
    local w, h = sz.w, sz.h
    local k = math.min(self.k, math.floor(w / 4), math.floor(h / 4))
    if k < 1 then return end
    pcall(function()
        for i = 0, k - 1 do
            bb:blitFrom(bb, x, y + i, x, y + k, w, 1)
            bb:blitFrom(bb, x, y + h - 1 - i, x, y + h - 1 - k, w, 1)
        end
        for i = 0, k - 1 do
            bb:blitFrom(bb, x + i, y, x + k, y, 1, h)
            bb:blitFrom(bb, x + w - 1 - i, y, x + w - 1 - k, y, 1, h)
        end
    end)
end

function EdgeTrim:free()
    if self.child and self.child.free then self.child:free() end
end

-- Real cover when KOReader has one, otherwise a bordered title placeholder.
-- A nil file yields a blank slot of the same w x h so rows stay aligned.
-- Covers come from the shared memory cache (data/covers.lua), so drawing the
-- same book again on another screen or page costs no decode.
-- opts.outline draws a thin dark line around the cover (Home), as the
-- e-reader's own home screen does; the cover shrinks to keep the outline
-- inside w x h.
function KoboldWidgets.makeCover(file, w, h, opts)
    if not file then
        return KoboldWidgets.fixed(w, h, HorizontalSpan:new{ width = w })
    end
    -- Every cover gets the thin outline unless a caller turns it off.
    local line = KoboldWidgets.outlineWidth(opts)
    local bb = KoboldCovers.get(file, w, h)
    if bb then
        -- The size is worked out once here and the cover is scaled to
        -- exactly that (it already has the cover's shape), so the outline
        -- fits it. Letting ImageWidget fit it again rounded differently and
        -- left a pixel or two of white inside the outline.
        local sw, sh = KoboldCovers.fittedSize(file, w - 2 * line, h - 2 * line)
        local image = ImageWidget:new{
            image = bb,
            image_disposable = false,
            width = sw,
            height = sh,
        }
        if line == 0 then
            -- about 1 px per 120 px of width, which is what such frames measure
            return EdgeTrim:new{ child = image, k = math.max(1, math.floor(sw / 120 + 0.5)) }
        end
        return FrameContainer:new{
            bordersize = line, padding = 0,
            color = Blitbuffer.COLOR_DARK_GRAY,
            image,
        }
    end
    local ok, cover = pcall(KoboldWidgets.titleCover, file, w, h, opts)
    if ok and cover then return cover end
    -- Whatever went wrong drawing the title, the book still gets its plate.
    local okl, logger = pcall(require, "logger")
    if okl and logger then logger.warn("KiKome: cover for " .. tostring(file) .. " failed: " .. tostring(cover)) end
    return KoboldWidgets.plainPlate(w, h, opts)
end

-- The plate of a cover with no picture and no text (a thumbnail too small for
-- a title): white with a black spine down the left, so even a tiny one reads as
-- a book. Exactly w x h. The grey frame stays when the cover outline is off, or
-- the plate would vanish into the page.
function KoboldWidgets.plainPlate(w, h, opts)
    local border = math.max(KoboldWidgets.outlineWidth(opts), Screen:scaleBySize(1))
    local inner_w, inner_h = math.max(2, w - 2 * border), math.max(2, h - 2 * border)
    local spine_w = math.min(math.floor(inner_w / 3), math.max(Screen:scaleBySize(3), math.floor(w * 0.08)))
    return KoboldWidgets.fixed(w, h, FrameContainer:new{
        bordersize = border,
        color = (KoboldWidgets.outlineWidth(opts) > 0) and Blitbuffer.COLOR_DARK_GRAY or Blitbuffer.COLOR_GRAY,
        background = Blitbuffer.COLOR_WHITE, padding = 0,
        HorizontalGroup:new{
            align = "top",
            LineWidget:new{ dimen = Geom:new{ w = spine_w, h = inner_h }, background = Blitbuffer.COLOR_BLACK },
            KoboldWidgets.fixed(inner_w - spine_w, inner_h, HorizontalSpan:new{ width = 0 }),
        },
    })
end

-- The author and title of a book with no cover, as the cover shows them: the
-- title and author the cover browser read (or the file name, tidied up, when it
-- has none) and the format. Nothing here reads the book.
local function plateText(file)
    local title, author
    local ok, BookInfo = pcall(require, "kobold.data.bookinfo")
    if ok and BookInfo then
        local ok_get, info = pcall(BookInfo.get, file)
        if ok_get and type(info) == "table" then
            if type(info.title) == "string" and info.title ~= "" then title = info.title end
            if type(info.authors) == "string" and info.authors ~= "" then
                local names = {}
                for name in info.authors:gmatch("[^\n]+") do
                    name = name:match("^%s*(.-)%s*$")
                    if name ~= "" then names[#names + 1] = name end
                end
                if #names > 0 then author = table.concat(names, ", ") end
            end
        end
    end
    if not title then
        title = (file:match("([^/]+)%.[^%.]+$") or file):gsub("[_]+", " "):gsub("%s+", " ")
    end
    if #title > 90 then title = title:sub(1, 87) .. "..." end
    local ext = (file:match("%.([^%./]+)$") or ""):upper()
    return title, author, ext
end

-- The cover of a book that has none, drawn like a real one: white, with a black
-- spine down the left; the format (EPUB, MD...) in a small black tag at the
-- top; the title in bold, as large as fits, with a short thick rule under it
-- in the middle; the author in grey at the foot. The text sizes follow the
-- cover's size. A small cover (Home's list thumbnails) keeps the spine and the
-- title; one too small for text is the plain plate. Exactly w x h.
function KoboldWidgets.titleCover(file, w, h, opts)
    local border = KoboldWidgets.outlineWidth(opts)
    local small = w < Screen:scaleBySize(95)
    local inner_w, inner_h = w - 2 * border, h - 2 * border
    local spine_w = math.max(Screen:scaleBySize(small and 3 or 5), math.floor(w * 0.07))
    local pad = math.max(Screen:scaleBySize(small and 4 or 8), math.floor(w * 0.08))
    local cw = inner_w - spine_w - 2 * pad
    local ch = inner_h - 2 * pad
    if cw < Screen:scaleBySize(30) or ch < Screen:scaleBySize(30) then
        return KoboldWidgets.plainPlate(w, h, opts)
    end

    local title, author, ext = plateText(file)
    local gap = Screen:scaleBySize(small and 3 or 7)
    local unit = math.max(0.5, Screen:scaleBySize(1000) / 1000)  -- pixels of one design unit

    -- Format tag, top left.
    local tag
    if ext ~= "" and ch >= Screen:scaleBySize(110) then
        local label = TextWidget:new{
            text = ext, face = KoboldWidgets.secondaryFace(9), bold = true,
            fgcolor = Blitbuffer.COLOR_WHITE, max_width = cw - Screen:scaleBySize(12),
        }
        tag = FrameContainer:new{
            bordersize = 0, margin = 0, radius = Screen:scaleBySize(3),
            background = Blitbuffer.COLOR_BLACK,
            padding_left = Screen:scaleBySize(5), padding_right = Screen:scaleBySize(5),
            padding_top = Screen:scaleBySize(1), padding_bottom = Screen:scaleBySize(1),
            label,
        }
    end
    -- Author, at the foot, up to two lines.
    local author_box
    if author and ch >= Screen:scaleBySize(100) then
        author_box = TextBoxWidget:new{
            text = author, face = KoboldWidgets.secondaryFace(math.max(10, math.min(13, math.floor(cw / unit / 9)))),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY, width = cw, alignment = "left",
            height = math.floor(ch * 0.2), height_adjust = true, height_overflow_show_ellipsis = true,
        }
    end
    local top_h = tag and (tag:getSize().h + gap) or 0
    local foot_h = author_box and (author_box:getSize().h + gap) or 0

    -- The title block is centred in what the tag and the author leave: the
    -- largest title size that fits, down to a floor (past it, cut with "...").
    local rule_h = Screen:scaleBySize(small and 2 or 3)
    local reserve = 2 * math.max(top_h, foot_h)
    local max_title_h = math.max(Screen:scaleBySize(24), ch - reserve - gap - rule_h)
    local floor_size = small and 8 or 11
    local start = math.max(floor_size + 1, math.min(24, math.floor(cw / unit / (small and 6 or 7))))
    local title_box
    for size = start, floor_size, -1 do
        local tb = TextBoxWidget:new{
            text = title, face = KoboldWidgets.face(size), bold = true,
            width = cw, alignment = "left",
        }
        if tb:getSize().h <= max_title_h or size == floor_size then
            if tb:getSize().h > max_title_h then
                tb:free()
                tb = TextBoxWidget:new{
                    text = title, face = KoboldWidgets.face(floor_size), bold = true,
                    width = cw, alignment = "left",
                    height = max_title_h, height_adjust = true,
                    height_overflow_show_ellipsis = true,
                }
            end
            title_box = tb
            break
        end
        tb:free()
    end

    local stack = VerticalGroup:new{
        align = "left",
        title_box,
        VerticalSpan:new{ width = gap },
        LineWidget:new{
            dimen = Geom:new{ w = math.max(Screen:scaleBySize(16), math.floor(cw * 0.22)), h = rule_h },
            background = Blitbuffer.COLOR_BLACK,
        },
    }
    local box = OverlapGroup:new{
        dimen = Geom:new{ w = cw, h = ch },
        CenterContainer:new{ dimen = Geom:new{ w = cw, h = ch }, stack },
    }
    if tag then
        tag.overlap_offset = { 0, 0 }
        box[#box + 1] = tag
    end
    if author_box then
        author_box.overlap_offset = { 0, ch - author_box:getSize().h }
        box[#box + 1] = author_box
    end

    return FrameContainer:new{
        bordersize = border, color = Blitbuffer.COLOR_DARK_GRAY,  -- the grey of every cover's outline
        padding = 0, background = Blitbuffer.COLOR_WHITE,
        HorizontalGroup:new{
            align = "top",
            LineWidget:new{ dimen = Geom:new{ w = spine_w, h = inner_h }, background = Blitbuffer.COLOR_BLACK },
            FrameContainer:new{
                bordersize = 0, margin = 0, padding = pad, background = Blitbuffer.COLOR_WHITE,
                box,
            },
        },
    }
end

-- Row of n covers taken from `files`, separated by `gap`.
function KoboldWidgets.coverRow(files, n, w, h, gap)
    local row = HorizontalGroup:new{}
    for i = 1, n do
        if i > 1 then row[#row + 1] = HorizontalSpan:new{ width = gap } end
        row[#row + 1] = KoboldWidgets.makeCover(files[i], w, h)
    end
    return row
end

-- Folders IconWidget looks in for icons, user folder first.
local icon_dirs = nil
local function iconDirs()
    if icon_dirs then return icon_dirs end
    icon_dirs = {}
    local ok, DataStorage = pcall(require, "datastorage")
    if ok and DataStorage then icon_dirs[#icon_dirs + 1] = DataStorage:getDataDir() .. "/icons" end
    icon_dirs[#icon_dirs + 1] = "resources/icons/mdlight"
    icon_dirs[#icon_dirs + 1] = "resources/icons"
    return icon_dirs
end

-- True when an icon file with this name exists. IconWidget does not fail on
-- a missing icon (it draws a warning sign), so this is checked up front.
function KoboldWidgets.hasIcon(name)
    for _i, dir in ipairs(iconDirs()) do
        for _j, ext in ipairs({ ".svg", ".png" }) do
            if lfs.attributes(dir .. "/" .. name .. ext, "mode") == "file" then return true end
        end
    end
    return false
end

-- KOReader's built-in icon by name (e.g. "home", "appbar.settings"), sized
-- size x size. Falls back to an outlined placeholder if the icon fails to load.
-- opts (optional):
--   rotation = degrees, e.g. 180 turns chevron.up into a down chevron
--   fallback = icon used instead when `name` does not exist
-- Icons are drawn with alpha: IconWidget's default (alpha = false) flattens
-- the SVG onto white, which shows as a white box on the gray pills.
-- One of Kobold's own icons (icons/<name>.svg in the plugin). Drawn as a
-- KOReader icon, so night mode turns it white on black like KOReader's
-- own. Falls back to KOReader icon `fallback` when the file is missing.
-- Kobold Settings > Icons can switch to KOReader's own icons instead: then
-- `fallback` is always used. KOReader's Wi-Fi icon has only two states.
local KOREADER_WIFI = {
    ["wifi-off"] = "wifi.open.0", ["wifi-disconnected"] = "wifi.open.0",
    ["wifi-weak"] = "wifi.open.100", ["wifi-medium"] = "wifi.open.100",
    ["wifi-strong"] = "wifi.open.100",
}

-- True when Kobold's own icons are used (the default).
function KoboldWidgets.koboldIcons()
    return KoboldPrefs.get("icons") ~= "koreader"
end

function KoboldWidgets.customIcon(name, size, fallback)
    fallback = KOREADER_WIFI[name] or fallback
    if not KoboldWidgets.koboldIcons() then
        -- Older KOReader builds may lack a newer icon (such as "library").
        return KoboldWidgets.icon(fallback or name, size, { fallback = "appbar.filebrowser" })
    end
    local path = KoboldMeta.icon(name .. ".svg")
    if path and lfs.attributes(path, "mode") == "file" then
        local ok, widget = pcall(function()
            return IconWidget:new{
                file = path, width = size, height = size,
                alpha = true, original_in_nightmode = false,
            }
        end)
        if ok and widget then return widget end
    end
    return KoboldWidgets.icon(fallback or name, size)
end

function KoboldWidgets.icon(name, size, opts)
    opts = opts or {}
    if opts.fallback and not KoboldWidgets.hasIcon(name) then name = opts.fallback end
    local ok, widget = pcall(function()
        return IconWidget:new{
            icon = name, width = size, height = size,
            rotation_angle = opts.rotation or 0,
            alpha = true,
        }
    end)
    if ok and widget then return widget end
    return KoboldWidgets.iconPlaceholder(size)
end

-- Path of an SVG icon file by name, or nil.
local function iconSvgPath(name)
    for _i, dir in ipairs(iconDirs()) do
        local path = dir .. "/" .. name .. ".svg"
        if lfs.attributes(path, "mode") == "file" then return path end
    end
    return nil
end

-- Writes a copy of SVG icon `name` turned by `degrees` around its centre to
-- Kobold's cache folder and returns its path, or nil. Bitmaps can only be
-- turned in steps of 90 degrees, so the turn is done in the SVG itself by
-- wrapping its drawing in a rotate transform.
local rotated_svgs = {}
local function rotatedSvg(name, degrees)
    local key = name .. "@" .. degrees
    if rotated_svgs[key] ~= nil then return rotated_svgs[key] or nil end
    rotated_svgs[key] = false
    local src = iconSvgPath(name)
    if not src then return nil end
    local ok, out = pcall(function()
        local f = assert(io.open(src, "rb"))
        local svg = f:read("*a")
        f:close()
        local s_tag, e_tag = svg:find("<svg[^>]*>")
        local close = svg:find("</svg>%s*$")
        if not s_tag or not close then return nil end
        local tag = svg:sub(s_tag, e_tag)
        local vx, vy, vw, vh = (tag:match('viewBox%s*=%s*"([^"]+)"') or ""):match(
            "([%-%d%.]+)[%s,]+([%-%d%.]+)[%s,]+([%-%d%.]+)[%s,]+([%-%d%.]+)")
        if not vx then
            vx, vy = 0, 0
            vw = tonumber((tag:match('width%s*=%s*"([%d%.]+)')))
            vh = tonumber((tag:match('height%s*=%s*"([%d%.]+)')))
            if not vw or not vh then return nil end
        end
        local cx = tonumber(vx) + tonumber(vw) / 2
        local cy = tonumber(vy) + tonumber(vh) / 2
        local turned = svg:sub(1, e_tag)
            .. string.format('<g transform="rotate(%s %s %s)">', degrees, cx, cy)
            .. svg:sub(e_tag + 1, close - 1) .. "</g></svg>\n"
        local DataStorage = require("datastorage")
        local cache = DataStorage:getDataDir() .. "/cache"
        local dir = cache .. "/kobold_icons"
        if lfs.attributes(cache, "mode") ~= "directory" then lfs.mkdir(cache) end
        if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
        local path = dir .. "/" .. name .. "_r" .. degrees .. ".svg"
        local w = assert(io.open(path, "wb"))
        w:write(turned)
        w:close()
        return path
    end)
    if ok and out then
        rotated_svgs[key] = out
        return out
    end
    return nil
end

-- Plus sign for "add" buttons: KOReader's exit icon (an X) turned 45
-- degrees, which has heavier strokes than its plus icon. Falls back to the
-- plus icon when the exit icon cannot be turned.
function KoboldWidgets.plusIcon(size)
    local path = rotatedSvg("exit", 45)
    if path then
        local ok, widget = pcall(function()
            return IconWidget:new{ file = path, width = size, height = size, alpha = true }
        end)
        if ok and widget then return widget end
    end
    return KoboldWidgets.icon("plus", size)
end

-- A black icon drawn white on a black fill: a white square is painted under
-- the icon, the icon is drawn, and the square is inverted, so the black
-- strokes come out white and the black fill around them stays black. Works
-- for any icon widget (the same trick scrubber_ui.lua uses for its tabs).
local InvertedIcon = Widget:extend{ child = nil }

function InvertedIcon:getSize() return self.child:getSize() end

function InvertedIcon:paintTo(bb, x, y)
    local s = self.child:getSize()
    self.dimen = Geom:new{ x = x, y = y, w = s.w, h = s.h }
    bb:paintRect(x, y, s.w, s.h, Blitbuffer.COLOR_WHITE)
    self.child:paintTo(bb, x, y)
    bb:invertRect(x, y, s.w, s.h)
end

function InvertedIcon:free()
    if self.child and self.child.free then self.child:free() end
end

function KoboldWidgets.inverted(child)
    return InvertedIcon:new{ child = child }
end

-- Down chevron: KOReader has no chevron.down, so chevron.up is turned over.
function KoboldWidgets.chevronDown(size)
    return KoboldWidgets.icon("chevron.up", size, { rotation = 180 })
end

-- Side page bar that makes paged lists read like scrolling ones: an up
-- arrow, a track with a thumb showing where the current page sits, and a
-- down arrow. With a single page only a faint track is drawn.
--   opts = { w = column width, h = bar height, page, pages, arrow = size }
-- Exactly w x h.
function KoboldWidgets.pageBar(opts)
    local w, h, arrow = opts.w, opts.h, opts.arrow
    local line_w  = Screen:scaleBySize(2)
    local thumb_w = Screen:scaleBySize(8)
    local thumb_min_h = Screen:scaleBySize(24)
    local track_h = h - 2 * arrow
    local multi = opts.pages > 1
    local track = OverlapGroup:new{
        dimen = Geom:new{ w = w, h = track_h },
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = track_h },
            LineWidget:new{
                dimen = Geom:new{ w = line_w, h = track_h },
                background = Blitbuffer.COLOR_LIGHT_GRAY,
            },
        },
    }
    if multi then
        local thumb_h = math.max(thumb_min_h, math.floor(track_h / opts.pages))
        local thumb_y = math.floor((track_h - thumb_h) * (opts.page - 1) / (opts.pages - 1))
        -- The thumb's size comes from its content: FrameContainer:getSize()
        -- ignores width/height.
        track[#track + 1] = VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = thumb_y },
            HorizontalGroup:new{
                HorizontalSpan:new{ width = math.floor((w - thumb_w) / 2) },
                FrameContainer:new{
                    bordersize = 0, padding = 0,
                    radius = math.floor(thumb_w / 2),
                    background = Blitbuffer.COLOR_DARK_GRAY,
                    KoboldWidgets.fixed(thumb_w, thumb_h, HorizontalSpan:new{ width = 0 }),
                },
            },
        }
    end
    local function arrowCell(icon)
        return CenterContainer:new{
            dimen = Geom:new{ w = w, h = arrow },
            multi and icon or HorizontalSpan:new{ width = arrow },
        }
    end
    return VerticalGroup:new{
        arrowCell(KoboldWidgets.icon("chevron.up", arrow)),
        track,
        arrowCell(KoboldWidgets.chevronDown(arrow)),
    }
end

-- Page a tap on a pageBar asks for: `y` is measured from the bar's top. The
-- arrows step one page (taps above or below the bar count as them), the
-- track jumps to the page at that height. nil with a single page.
function KoboldWidgets.pageBarTarget(y, opts)
    if opts.pages <= 1 then return nil end
    if y < opts.arrow then return opts.page - 1 end
    if y >= opts.h - opts.arrow then return opts.page + 1 end
    local frac = (y - opts.arrow) / math.max(opts.h - 2 * opts.arrow, 1)
    return math.floor(frac * opts.pages) + 1
end

-- Page for a finger dragging along a pageBar: the thumb follows the finger,
-- so the thumb's centre sits at `y` (measured from the bar's top), clamped
-- to the track. Unlike pageBarTarget the arrows count as the ends of the
-- track. nil with a single page.
function KoboldWidgets.pageBarDragTarget(y, opts)
    if opts.pages <= 1 then return nil end
    local track_h = opts.h - 2 * opts.arrow
    local thumb_h = math.max(Screen:scaleBySize(24), math.floor(track_h / opts.pages))
    local span = math.max(track_h - thumb_h, 1)
    local frac = (y - opts.arrow - thumb_h / 2) / span
    frac = math.max(0, math.min(1, frac))
    return math.floor(frac * (opts.pages - 1) + 0.5) + 1
end

-- Wall-clock seconds, with fractions when KOReader's ffi util offers them.
-- (os.clock counts CPU time, which barely moves while the device is idle.)
local ok_ffiutil, ffiUtil = pcall(require, "ffi/util")
function KoboldWidgets.now()
    if ok_ffiutil and ffiUtil and ffiUtil.getTimestamp then
        local ok, sec, usec = pcall(ffiUtil.getTimestamp)
        if ok and sec then return sec + (usec or 0) / 1e6 end
    end
    return os.time()
end

-- Lets a screen's page bar be dragged, like the knob of a progress slider:
-- put the finger on the bar and slide it up or down, and the thumb (and the
-- page) follows it. A plain touch-and-move arrives as "pan"; a press that
-- waits first arrives as "hold" then "hold_pan"; both are handled. The zones
-- only act on a drag that starts on the bar and let every other gesture
-- through. The swipe that can follow a quick drag is swallowed, so it does
-- not turn one more page.
--
-- Zones are asked newest first, so call this AFTER the screen has registered
-- its own swipe and hold zones, or those answer before this does.
-- cfg = {
--   rect = function() -> Geom of the bar's touch area, or nil to turn it off,
--   bar  = function() -> the opts table given to pageBar (current one),
--   top  = function() -> y of the bar's top edge,
--   goTo = function(page) }
function KoboldWidgets.registerBarDrag(widget, cfg)
    local state = { active = false, last = nil, stamp = 0 }
    local RECENT, STALE = 0.4, 3
    local full = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 }

    -- Does the gesture start on the bar? (a little slack on the left)
    local function onBar(ges)
        local rect, bar = cfg.rect(), cfg.bar()
        if not (rect and bar and bar.pages > 1 and ges and ges.pos) then return false end
        local slack = Screen:scaleBySize(12)
        return ges.pos:intersectWith(Geom:new{
            x = rect.x - slack, y = rect.y, w = rect.w + slack, h = rect.h,
        })
    end
    local function follow(ges)
        local bar = cfg.bar()
        local page = bar and KoboldWidgets.pageBarDragTarget(ges.pos.y - cfg.top(), bar)
        if page then cfg.goTo(page) end
    end
    local function finish()
        state.active = false
        state.last = KoboldWidgets.now()
    end
    local function release()
        if not state.active then return false end
        finish()
        return true
    end
    -- True while a drag is on, or just ended. Once a drag has started, no
    -- swipe may count as a swipe: not the one that can close a quick drag, and
    -- not one detected in the middle of it. The screen's own gesture entry
    -- point is wrapped (once) so such a swipe is eaten before ANY zone or
    -- handler sees it, whatever order the zones were registered in (a page
    -- change re-registers the screen's zones, which can put its own swipe
    -- zone ahead of this one).
    -- Should this swipe be eaten? Yes if it comes in the middle of a drag (that
    -- ends the drag) or right after one. A drag that never got its release
    -- (no event for STALE seconds) is dropped, so it can never block swipes.
    widget._bar_drag_busy = function()
        local t = KoboldWidgets.now()
        if state.active then
            if t - state.stamp > STALE then
                state.active = false
            else
                finish()
                return true
            end
        end
        return state.last ~= nil and t - state.last < RECENT
    end
    if not widget._bar_drag_wrapped then
        widget._bar_drag_wrapped = true
        local original = widget.onGesture
        widget.onGesture = function(self, ev)
            if ev and ev.ges == "swipe" and self._bar_drag_busy and self._bar_drag_busy() then
                return true
            end
            return original(self, ev)
        end
    end

    widget:registerTouchZones({
        {
            id = "KoboldBarHold", ges = "hold", screen_zone = full,
            handler = function(ges)
                if onBar(ges) then state.active = true; state.stamp = KoboldWidgets.now(); return true end
                return false
            end,
        },
        {
            id = "KoboldBarPan", ges = "pan", screen_zone = full,
            handler = function(ges)
                if state.active then state.stamp = KoboldWidgets.now(); follow(ges); return true end
                -- Sideways pans are not for the bar.
                if ges.direction == "west" or ges.direction == "east" then return false end
                if onBar(ges) then
                    state.active = true
                    state.stamp = KoboldWidgets.now()
                    follow(ges)
                    return true
                end
                return false
            end,
        },
        {
            id = "KoboldBarHoldPan", ges = "hold_pan", screen_zone = full,
            handler = function(ges)
                if not state.active then return false end
                state.stamp = KoboldWidgets.now()
                follow(ges)
                return true
            end,
        },
        { id = "KoboldBarPanRelease",  ges = "pan_release",  screen_zone = full, handler = release },
        { id = "KoboldBarHoldRelease", ges = "hold_release", screen_zone = full, handler = release },
        {
            id = "KoboldBarSwipe", ges = "swipe", screen_zone = full,
            handler = function()
                return widget._bar_drag_busy()
            end,
        },
    })
    return state
end

-- On/off switch shared by the popups (brightness, Wi-Fi, clock): a pill with
-- a round knob, painted by hand so it sits exactly in the middle of its row.
-- On: black pill, white knob on the right. Off: white pill with a black
-- outline, black knob on the left.
local Switch = Widget:extend{ w = 0, h = 0, on = false }

function Switch:getSize() return Geom:new{ w = self.w, h = self.h } end

function Switch:paintTo(bb, x, y)
    local border = Screen:scaleBySize(2)
    local gap = Screen:scaleBySize(3)
    local r = math.floor(self.h / 2)
    bb:paintRoundedRect(x, y, self.w, self.h, Blitbuffer.COLOR_BLACK, r)
    if not self.on then
        bb:paintRoundedRect(x + border, y + border, self.w - 2 * border, self.h - 2 * border,
            Blitbuffer.COLOR_WHITE, r - border)
    end
    local k = self.h - 2 * (border + gap)
    local kx = self.on and (x + self.w - border - gap - k) or (x + border + gap)
    bb:paintRoundedRect(kx, y + border + gap, k, k,
        self.on and Blitbuffer.COLOR_WHITE or Blitbuffer.COLOR_BLACK, math.floor(k / 2))
end

function Switch:free() end

KoboldWidgets.Switch = Switch

-- A switch of the standard size. Returns the widget and its width.
function KoboldWidgets.switch(on)
    local w, h = Screen:scaleBySize(52), Screen:scaleBySize(28)
    return Switch:new{ w = w, h = h, on = on and true or false }, w
end

-- A row with a label at the left and the switch flush with the right edge,
-- both centred in the row. The same look on every status bar popup.
function KoboldWidgets.switchRow(inner, h, text, on)
    local sw, sw_w = KoboldWidgets.switch(on)
    local label = TextWidget:new{
        text = text, face = KoboldWidgets.face(19), bold = true,
        max_width = inner - sw_w - Screen:scaleBySize(12),
    }
    return CenterContainer:new{
        dimen = Geom:new{ w = inner, h = h },
        HorizontalGroup:new{
            align = "center",
            label,
            HorizontalSpan:new{ width = math.max(0, inner - label:getSize().w - sw_w) },
            sw,
        },
    }
end

-- Square outlined placeholder, used as the fallback when an icon cannot load.
function KoboldWidgets.iconPlaceholder(size)
    local bs = Screen:scaleBySize(2)
    return FrameContainer:new{
        bordersize = bs,
        padding = 0,
        KoboldWidgets.fixed(size - 2 * bs, size - 2 * bs, HorizontalSpan:new{ width = 0 }),
    }
end

-- Subtitle gray: darker than the old COLOR_DARK_GRAY, lighter than the black
-- titles. Falls back to COLOR_DARK_GRAY if the Color8 constructor is missing.
function KoboldWidgets.subtitleColor()
    local ok, c = pcall(function() return Blitbuffer.Color8(0x22) end)
    if ok and c then return c end
    return Blitbuffer.COLOR_DARK_GRAY
end

-- Name of Kobold's Wi-Fi icon for the current state: wifi-off when Wi-Fi is
-- off, wifi-disconnected when on but not connected, otherwise the signal:
-- wifi-weak, wifi-medium or wifi-strong (strong when the device does not
-- report it).
function KoboldWidgets.wifiIconName()
    local ok, NetworkMgr = pcall(require, "ui/network/manager")
    if not ok or not NetworkMgr then return "wifi-off" end
    local function ask(method)
        local ok_m, v = pcall(function() return NetworkMgr[method](NetworkMgr) end)
        return ok_m and v or nil
    end
    if not ask("isWifiOn") then return "wifi-off" end
    if not ask("isConnected") then return "wifi-disconnected" end
    local network = ask("getCurrentNetwork")
    local q = type(network) == "table" and tonumber(network.signal_quality)
    if q and q < 40 then return "wifi-weak" end
    if q and q < 70 then return "wifi-medium" end
    return "wifi-strong"
end

local STATUS_ICON = 26  -- status bar icon size, before screen scaling
local STATUS_GAP  = 18

-- Widths of the status bar icons, left to right: contrast, Wi-Fi, battery,
-- search. The battery SVG only fills the middle of its square, so it is drawn
-- larger than the others. In percentage mode its slot is wider by the number
-- written to its right (the icon itself keeps its size). The fifth value is
-- the battery icon alone.
local function statusIconWidths()
    local size = Screen:scaleBySize(STATUS_ICON)
    local style = KoboldPrefs.get("battery")
    -- Kobold's own battery fills more of its square than KOReader's old one, so
    -- it is drawn a little smaller for the same look.
    local own = KoboldWidgets.koboldIcons()
    local battery_icon = math.floor(size * (own and 1.15 or 1.3))
    local battery = battery_icon + (style == "percent" and KoboldBattery.labelWidth() or 0)
    return { size, size, battery, size }, size, Screen:scaleBySize(STATUS_GAP), style, battery_icon
end

-- Width the clock may take: the bar up to the icons, with one gap left before
-- them. The text is cut there (with "...") and never reaches the icons.
local function clockMaxWidth(content_w)
    local widths, _size, gap = statusIconWidths()
    local total = (#widths - 1) * gap
    for _i, w in ipairs(widths) do total = total + w end
    return math.max(0, content_w - total - gap)
end

-- The clock of the status bar, at most `max_w` wide: one line in the usual
-- size, or two smaller lines (as small as it takes to fit the bar's height).
local function clockWidget(max_w)
    local lines = KoboldClock.lines()
    if #lines == 1 then
        return TextWidget:new{ text = lines[1], face = KoboldWidgets.face(16), max_width = max_w }
    end
    local bar_h = KoboldMetrics.statusBar().h
    local size, group = 13, nil
    while true do
        group = VerticalGroup:new{
            align = "left",
            TextWidget:new{ text = lines[1], face = KoboldWidgets.face(size), max_width = max_w },
            TextWidget:new{ text = lines[2], face = KoboldWidgets.face(size), max_width = max_w },
        }
        if group:getSize().h <= bar_h or size <= 8 then break end
        group:free()
        size = size - 1
    end
    return group
end

-- Top of Home indicator in the center of the status bar, one mark per mode.
-- Two looks, chosen with STYLE (kept under the name StatusDots, which
-- statusBar uses):
--   "pill":     the current mode is a black elongated pill, the others empty rings
--   "segments": thin bars, the current one thicker and black, the others grey
local StatusDots = Widget:extend{ count = 2, current = 1 }
StatusDots.STYLE = "pill"

function StatusDots:init()
    if StatusDots.STYLE == "segments" then
        self.seg_w = Screen:scaleBySize(16)
        self.gap = Screen:scaleBySize(4)
        self.thin = math.max(1, Screen:scaleBySize(2))
        self.thick = math.max(self.thin + 1, Screen:scaleBySize(4))
        self.dimen = Geom:new{ x = 0, y = 0, w = self.count * self.seg_w + (self.count - 1) * self.gap, h = self.thick }
    else
        self.d = Screen:scaleBySize(8)                      -- ring diameter / pill height
        self.pill_w = math.max(self.d * 2, Screen:scaleBySize(18))
        self.border = math.max(1, Screen:scaleBySize(1))    -- ring line thickness
        self.gap = Screen:scaleBySize(7)
        self.dimen = Geom:new{ x = 0, y = 0,
            w = (self.count - 1) * (self.d + self.gap) + self.pill_w, h = self.d }
    end
end

function StatusDots:getSize()
    return self.dimen
end

function StatusDots:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    if StatusDots.STYLE == "segments" then
        local off_color = Blitbuffer.Color8(0x99)
        for i = 1, self.count do
            local active = (i == self.current)
            local h = active and self.thick or self.thin
            bb:paintRoundedRect(x + (i - 1) * (self.seg_w + self.gap), y + math.floor((self.thick - h) / 2),
                self.seg_w, h, active and Blitbuffer.COLOR_BLACK or off_color, math.floor(h / 2))
        end
        return
    end
    local r = math.floor(self.d / 2)
    local cx = x
    for i = 1, self.count do
        if i == self.current then
            bb:paintRoundedRect(cx, y, self.pill_w, self.d, Blitbuffer.COLOR_BLACK, r)
            cx = cx + self.pill_w + self.gap
        else
            bb:paintRoundedRect(cx, y, self.d, self.d, Blitbuffer.COLOR_BLACK, r)
            local b = self.border
            bb:paintRoundedRect(cx + b, y + b, self.d - 2 * b, self.d - 2 * b,
                Blitbuffer.COLOR_WHITE, math.max(0, r - b))
            cx = cx + self.d + self.gap
        end
    end
end

function StatusDots:free() end

-- Shared top status bar: the clock on the left (time, or time and date, as
-- chosen in Settings), optional centered page dots, then contrast, Wi-Fi,
-- battery and search icons on the right.
function KoboldWidgets.statusBar(content_w, dots_cfg)
    local widths, size, gap, style, battery_icon = statusIconWidths()
    local icons = HorizontalGroup:new{
        align = "center",
        KoboldWidgets.customIcon("brightness", size, "appbar.contrast"),
        HorizontalSpan:new{ width = gap },
        KoboldWidgets.customIcon(KoboldWidgets.wifiIconName(), size, "wifi.open.100"),
        HorizontalSpan:new{ width = gap },
        KoboldBattery:new{ size = battery_icon, slot_h = size, style = style },
        HorizontalSpan:new{ width = gap },
        KoboldWidgets.customIcon("search", size, KoboldWidgets.hasIcon("lookup.search") and "lookup.search" or "appbar.search"),
    }
    local icons_w = icons:getSize().w
    if dots_cfg and (dots_cfg.count or 0) > 1 then
        local dots = StatusDots:new{ count = dots_cfg.count, current = dots_cfg.current or 1 }
        local dots_w = dots:getSize().w
        local min_gap = Screen:scaleBySize(8)
        local max_dots_x = math.max(0, content_w - icons_w - min_gap - dots_w)
        local dots_x = math.min(math.floor((content_w - dots_w) / 2), max_dots_x)
        local clock_max = math.max(0, dots_x - min_gap)
        local clock = clockWidget(clock_max)
        local clock_w = clock:getSize().w
        local left_span = math.max(0, dots_x - clock_w)
        local right_span = math.max(0, content_w - dots_x - dots_w - icons_w)
        return HorizontalGroup:new{
            align = "center",
            clock,
            HorizontalSpan:new{ width = left_span },
            dots,
            HorizontalSpan:new{ width = right_span },
            icons,
        }, { x = dots_x, w = dots_w, count = dots_cfg.count }
    end
    local clock = clockWidget(clockMaxWidth(content_w))
    local spacer = content_w - clock:getSize().w - icons_w
    return HorizontalGroup:new{
        align = "center",
        clock,
        HorizontalSpan:new{ width = math.max(spacer, 0) },
        icons,
    }, nil
end

-- Left edge and width of status bar icon `index` (1 = contrast ... 4 =
-- search), from the same sizes statusBar() uses. Icons sit at the right edge.
local function statusIconX(margin, content_w, index)
    local widths, _size, gap = statusIconWidths()
    local total = (#widths - 1) * gap
    for _i, w in ipairs(widths) do total = total + w end
    local x = margin + content_w - total
    for i = 1, index - 1 do x = x + widths[i] + gap end
    return x, widths[index], gap
end

-- True when the clock shows 24-hour time: KOReader's own clock setting.
function KoboldWidgets.clock24()
    return KoboldClock.clock24()
end

-- What the clock of the status bar shows now (two lines are joined by a line
-- break). See data/clock.lua.
function KoboldWidgets.clockText()
    return table.concat(KoboldClock.lines(), "\n")
end

-- The clock's tap zone (popup with the time and the full date) and its
-- long-press zone (debug screenshot): the left third of the bar, or all of the
-- clock when its text is wider than that, and never over the icons or center dots.
local function registerClockZones(screen, margin, top, content_w, status_h, dots_info)
    local clock_max = clockMaxWidth(content_w)
    if dots_info then
        clock_max = math.min(clock_max, math.max(0, dots_info.x - Screen:scaleBySize(8)))
    end
    local clock = clockWidget(clock_max)
    local clock_w = clock:getSize().w
    clock:free()
    require("kobold.ui.popup").setAnchor("clock", margin + math.floor(clock_w / 2))
    local zone_w = math.min(math.max(math.floor(content_w / 3), clock_w), clock_max)
    KoboldTaps.add(screen, "KoboldClockTap", margin, top, zone_w, status_h,
        function() require("kobold.ui.clock_popup").show() end)
    -- Debug mode: long-press the clock to screenshot. Always registered and
    -- checked when pressed, so toggling debug mode on the About page works on
    -- screens that are already open.
    KoboldTaps.hold(screen, "KoboldDebugShot", margin, top, zone_w, status_h,
        function()
            if KoboldMeta.debugOn() then KoboldWidgets.debugScreenshot() end
        end)
end

-- Registers tap & swipe zones on the center of the status bar when page dots are shown.
local function registerTopDotsZones(screen, margin, top, content_w, status_h, dots_info)
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    local active = dots_info and screen._kobold_top_dots and (screen._kobold_top_dots.count or 0) > 1
    local icon1_x = statusIconX(margin, content_w, 1)
    local tap_x, tap_w = 0, 0
    local swipe_x, swipe_w = 0, 0
    if active then
        local pad = Screen:scaleBySize(14)
        local dx = margin + dots_info.x
        local dw = dots_info.w
        local left_bound = margin + math.floor(content_w * 0.28)
        local right_bound = icon1_x - Screen:scaleBySize(6)
        tap_x = math.max(left_bound, dx - pad)
        tap_w = math.max(dw, math.min(right_bound, dx + dw + pad) - tap_x)
        swipe_x = left_bound
        swipe_w = math.max(tap_w, right_bound - swipe_x)
    end
    KoboldTaps.add(screen, "KoboldTopDotsTap", tap_x, top, tap_w, status_h, function(ges)
        local cfg = screen._kobold_top_dots
        if not (cfg and (cfg.count or 0) > 1 and cfg.on_select) then return end
        local count = cfg.count
        local idx = cfg.current or 1
        if ges and ges.pos and tap_w > 0 then
            local rel = (ges.pos.x - tap_x) / tap_w
            local picked = math.max(1, math.min(count, math.floor(rel * count) + 1))
            if picked == idx then
                idx = (idx % count) + 1
            else
                idx = picked
            end
        else
            idx = (idx % count) + 1
        end
        cfg.on_select(idx)
    end)
    screen:registerTouchZones({
        {
            id = "KoboldTopDotsSwipe",
            ges = "swipe",
            screen_zone = {
                ratio_x = swipe_x / sw,
                ratio_y = 0,
                ratio_w = swipe_w / sw,
                ratio_h = (top + status_h + Screen:scaleBySize(8)) / sh,
            },
            handler = function(ges)
                local cfg = screen._kobold_top_dots
                if not (cfg and (cfg.count or 0) > 1 and cfg.on_swipe) then return false end
                if ges.direction == "west" then
                    cfg.on_swipe(1)
                    return true
                elseif ges.direction == "east" then
                    cfg.on_swipe(-1)
                    return true
                end
                return false
            end,
        },
    })
end

-- The status bar in a fixed-size frame, for the top of a Kobold screen whose
-- body starts at (margin, margin). Also registers the tap zones over the
-- contrast icon (brightness popup), the Wi-Fi icon (Wi-Fi popup) and the
-- search icon (KOReader's file search). The frame is remembered on `screen`
-- so refreshStatusBar can redraw just the bar.
-- `top` (optional) is the y of the bar's top edge; it defaults to `margin`.
function KoboldWidgets.statusBarFrame(screen, margin, content_w, status_h, top)
    top = top or margin
    local bar_widget, dots_info = KoboldWidgets.statusBar(content_w, screen._kobold_top_dots)
    local frame = CenterContainer:new{
        dimen = Geom:new{ w = content_w, h = status_h },
        bar_widget,
    }
    screen._kobold_status = {
        frame = frame,
        dimen = Geom:new{ x = margin, y = top, w = content_w, h = status_h },
    }

    -- Icon index -> action, in icon order. Required on tap: the popups use
    -- these helpers themselves.
    local actions = {
        function() require("kobold.ui.brightness").show() end,
        function() require("kobold.ui.wifi").show() end,
        function() require("kobold.ui.battery_popup").show() end,
        KoboldWidgets.showFileSearch,
    }
    for i, action in ipairs(actions) do
        local x, icon_w, icon_gap = statusIconX(margin, content_w, i)
        -- Where the popups' arrows point.
        require("kobold.ui.popup").setAnchor(({ "brightness", "wifi", "battery", "search" })[i],
            math.floor(x + icon_w / 2))
        KoboldTaps.add(screen, "KoboldStatusIcon" .. i, math.floor(x - icon_gap / 2), top,
            icon_w + icon_gap, status_h, action)
    end
    registerClockZones(screen, margin, top, content_w, status_h, dots_info)
    registerTopDotsZones(screen, margin, top, content_w, status_h, dots_info)
    return frame
end

-- The status bar at the one place every screen shares (see metrics.lua):
-- Home, Library and Settings all call this, so the bar does not move when you
-- change tab or open Settings. Screens start their own content at
-- KoboldMetrics.statusBar().bottom.
function KoboldWidgets.sharedStatusBar(screen)
    local bar = KoboldMetrics.statusBar()
    return KoboldWidgets.statusBarFrame(screen, bar.margin, bar.content_w, bar.h, bar.top)
end

-- Redraws the status bar of `screen` (time, Wi-Fi and battery) and refreshes
-- only that strip of the screen.
function KoboldWidgets.refreshStatusBar(screen)
    local s = screen._kobold_status
    if not s then return end
    local bar_widget, dots_info = KoboldWidgets.statusBar(s.dimen.w, screen._kobold_top_dots)
    s.frame[1] = bar_widget
    -- The clock may have changed width (layout, date): its tap zone follows.
    registerClockZones(screen, s.dimen.x, s.dimen.y, s.dimen.w, s.dimen.h, dots_info)
    registerTopDotsZones(screen, s.dimen.x, s.dimen.y, s.dimen.w, s.dimen.h, dots_info)
    UIManager:setDirty(screen, function() return "ui", s.dimen end)
end

-- KOReader's book menu for `file`: the dialog the file browser shows on a
-- long-press (book status, delete, book information, and so on), opened on
-- top of the Kobold screen. `on_change`, when given, runs once after the
-- menu changed something (the file browser refreshes its list then).
-- False when the file browser is not there to provide it.
function KoboldWidgets.showBookMenu(file, on_change)
    local fm = require("kobold.ui.park").fm()   -- made now when a book is parked
    local fc = fm and fm.file_chooser
    local show = fc and (fc.showFileDialog or fc.onFileHold)
    if not show then return false end
    if on_change and fc.refreshPath then
        local own = rawget(fc, "refreshPath")
        local orig = fc.refreshPath
        fc.refreshPath = function(...)
            fc.refreshPath = own  -- once only; nil restores the class method
            local result = orig(...)
            UIManager:nextTick(on_change)
            return result
        end
    end
    local item = { path = file, file = file, is_file = true, text = file:match("[^/]+$") }
    return (pcall(show, fc, item))
end

-- Debug mode: saves the screen as it is, through KOReader's own
-- Screenshoter, so the file lands in the screenshot folder set in KOReader
-- and its "saved to..." message confirms it. (Saving with Screen:shot to our
-- own path left no trace when it failed.) The Screenshoter only reads
-- ui.document and ui.file_chooser, neither of which applies here, so it is
-- given an empty ui. Two seconds later a full refresh: the sign that it is
-- safe to let go.
function KoboldWidgets.debugScreenshot()
    local logger = require("logger")
    logger.info("[kobold] debug screenshot")
    local ok, err = pcall(function()
        local Screenshoter = require("ui/widget/screenshoter")
        Screenshoter:new{ ui = {} }:onScreenshot()
    end)
    if not ok then
        logger.warn("Kobold: screenshot failed:", tostring(err))
        require("kobold.ui.toast").error("Screenshot failed: " .. tostring(err))
    end
    UIManager:scheduleIn(2, function() UIManager:setDirty("all", "full") end)
end

-- The search button of the status bar: Kobold's own full-screen search (the
-- collection editor in search mode: a search field, the library's books, tap
-- one to open it). KOReader's own file search stays as the fallback.
function KoboldWidgets.showFileSearch()
    local gettext = require("kobold.i18n")
    local ok_own = pcall(function()
        require("kobold.ui.collection_editor").show{
            mode = "search",
            title = gettext("Search"),
            books = require("kobold.data.mybooks").getBooks(),
        }
    end)
    if ok_own then return end
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    local fm = ok and FileManager and FileManager.instance
    local searcher = fm and fm.filesearcher
    local shown = searcher and searcher.onShowFileSearch
        and pcall(searcher.onShowFileSearch, searcher)
    if not shown then
        require("kobold.ui.toast").error(require("kobold.i18n")("File search is not available."))
    end
end

-- Adds event handlers every Kobold screen class needs. KOReader broadcasts
-- these events to every open widget.
--   NetworkConnected / NetworkDisconnected: redraw the status bar Wi-Fi icon.
--   Charging / NotCharging / KoboldSettingsChanged: redraw the battery.
--   ShowingReader: a book is opening (from search results, the book menu,
--     ...), so close this screen instead of leaving it under the reader.
-- True for a swipe starting in the left or right edge strip, the same
-- strips KOReader's edge gestures use (1/8 of the width by default).
local function isEdgeSwipe(ev)
    if ev.ges ~= "swipe" or not ev.pos then return false end
    local edge = 1 / 8
    local ok, d = pcall(function() return G_defaults:readSetting("DSWIPE_ZONE_LEFT_EDGE") end)
    if ok and type(d) == "table" and tonumber(d.w) then edge = tonumber(d.w) end
    local W = Screen:getWidth()
    return ev.pos.x < W * edge or ev.pos.x > W * (1 - edge)
end

local function isTopBarHorizontalSwipe(screen, ev)
    if ev.ges ~= "swipe" or not ev.pos then return false end
    if ev.direction ~= "west" and ev.direction ~= "east" then return false end
    local s = screen._kobold_status
    local bottom = (s and s.dimen and (s.dimen.y + s.dimen.h)) or KoboldMetrics.statusBar().bottom
    return ev.pos.y <= bottom + Screen:scaleBySize(8)
end

-- A vertical swipe along a side edge: where KOReader's brightness and warmth
-- gestures usually sit. Horizontal swipes from the edge (paging) are not.
local function isEdgeAlongSwipe(ev)
    return isEdgeSwipe(ev) and (ev.direction == "north" or ev.direction == "south")
end

-- The file browser's Gestures plugin, or nil.
-- `need`: with a book parked under KiKome the file browser does not exist;
-- it is made now (the book closes) only when `need` is true. Edge swipes and
-- set corners need it; the catch-all for any other touch does not, so
-- ordinary taps never end the parking.
local function gesturesPlugin(need)
    local fm
    if need then
        fm = require("kobold.ui.park").fm()
    else
        local FileManager = package.loaded["apps/filemanager/filemanager"]
        fm = FileManager and FileManager.instance
    end
    return fm, fm and fm.gestures
end

-- Runs fm:onGesture(ev) with KOReader's events sent to every window. The
-- action a KOReader gesture runs (brightness, warmth, refresh, ...) is
-- sent as an event to the top window only, which is Kobold; the file
-- browser that handles it would never see it. SimpleUI does the same.
local function runOnFileBrowser(fm, ev)
    local orig = UIManager.sendEvent
    UIManager.sendEvent = function(_um, e) return UIManager:broadcastEvent(e) end
    local ok, handled = pcall(fm.onGesture, fm, ev)
    UIManager.sendEvent = orig
    return ok and handled and true or false
end

-- Runs a gesture through the file browser's gesture zones. KOReader keeps
-- one set of gestures for the file browser and one for the reader; the
-- file browser's set is tried first, then the reader's (actions that only
-- make sense in a book simply do nothing here). True when one ran.
local function forwardGesture(ev, need)
    local fm, g = gesturesPlugin(need)
    if not fm or not fm.onGesture then return false end
    if runOnFileBrowser(fm, ev) then return true end
    local reader_set = g and g.data and g.data.gesture_reader
    if type(reader_set) ~= "table" or g.gestures == reader_set then return false end
    local own = g.gestures
    g.gestures = reader_set
    local handled = runOnFileBrowser(fm, ev)
    g.gestures = own
    return handled
end

-- Name of the corner gesture for a tap or hold at ev.pos, using KOReader's
-- corner zones, or nil when it is not in a corner.
local CORNERS = {
    { key = "DTAP_ZONE_TOP_LEFT",     tap = "tap_top_left_corner",     hold = "hold_top_left_corner" },
    { key = "DTAP_ZONE_TOP_RIGHT",    tap = "tap_top_right_corner",    hold = "hold_top_right_corner" },
    { key = "DTAP_ZONE_BOTTOM_LEFT",  tap = "tap_left_bottom_corner",  hold = "hold_bottom_left_corner" },
    { key = "DTAP_ZONE_BOTTOM_RIGHT", tap = "tap_right_bottom_corner", hold = "hold_bottom_right_corner" },
}
local function cornerGesture(ev)
    if (ev.ges ~= "tap" and ev.ges ~= "hold") or not ev.pos then return nil end
    local W, H = Screen:getWidth(), Screen:getHeight()
    for _i, c in ipairs(CORNERS) do
        local ok, z = pcall(function() return G_defaults:readSetting(c.key) end)
        if ok and type(z) == "table" then
            local x, y = ev.pos.x / W, ev.pos.y / H
            if x >= z.x and x < z.x + z.w and y >= z.y and y < z.y + z.h then
                return c[ev.ges]
            end
        end
    end
    return nil
end

-- True when the user has an action set for corner gesture `name`, in the
-- file browser or reader gestures. Kobold's own taps keep corners that have
-- nothing set.
local function cornerIsSet(name)
    local _fm, g = gesturesPlugin()
    if not g then
        -- A book is parked under KiKome: the reader holds the same data.
        local RU = package.loaded["apps/reader/readerui"]
        g = RU and RU.instance and RU.instance.gestures
    end
    if not name or not g or not g.data then return false end
    for _i, set in ipairs({ g.data.gesture_fm, g.data.gesture_reader }) do
        if type(set) == "table" and set[name] ~= nil then return true end
    end
    return false
end

-- True when one of the screen's own tap or hold zones (status bar icons,
-- tabs, pills, rows, the nav bar) is under the gesture. Such taps are
-- always Kobold's, whatever KOReader has set for that corner.
local function koboldControlAt(screen, ev)
    local ok, found = pcall(function()
        for _i, zone in ipairs(screen._ordered_touch_zones or {}) do
            if zone.gs_range and zone.gs_range:match(ev) then return true end
        end
        return false
    end)
    return ok and found
end

-- Lays `screen` out again when the screen size is not the one it was built
-- for. Returns false, so the event goes on to the other windows.
function KoboldWidgets.handleResize(screen)
    if screen.closed or not screen.relayout then return false end
    if not KoboldMetrics.sizeChanged(screen) then return false end
    screen:relayout()
    UIManager:setDirty(screen, "full")
    return false
end

function KoboldWidgets.addScreenEvents(ScreenClass)
    -- KOReader's own gestures (the Gestures plugin: edge swipes, diagonal
    -- and two-finger gestures, multiswipes, ...) live on the file browser
    -- below Kobold, and KOReader only gives a touch to the top window, so
    -- Kobold passes them on (see forwardGesture). Swipes that start on the
    -- left or right edge go to KOReader first, so edge gestures such as
    -- brightness and warmth win over My Books paging. Corner taps and holds
    -- go to KOReader first when a corner gesture is set. Everything else
    -- goes to Kobold first.
    function ScreenClass:onGesture(ev)
        local InputContainer = require("ui/widget/container/inputcontainer")
        -- Edge swipes go to KOReader first. With a book parked under KiKome
        -- the file browser is made for a vertical one (brightness, warmth);
        -- a horizontal one (paging the shelf) does not end the parking.
        if ev.ges == "swipe" and self._bar_drag_busy and self._bar_drag_busy() then
            return true
        end
        local top_bar_hswipe = isTopBarHorizontalSwipe(self, ev)
        if not top_bar_hswipe and isEdgeSwipe(ev) and forwardGesture(ev, isEdgeAlongSwipe(ev)) then return true end
        if cornerIsSet(cornerGesture(ev)) and not koboldControlAt(self, ev)
            and forwardGesture(ev, true) then return true end
        if InputContainer.onGesture(self, ev) then return true end
        if top_bar_hswipe then return true end
        return forwardGesture(ev)
    end

    -- KOReader changed a book's metadata (Book information, custom title or
    -- author, ...): forget what Kobold remembered and show the new data.
    function ScreenClass:onBookMetadataChanged()
        require("kobold.data.library").forgetAll()
        if self.scheduleReload then
            self:scheduleReload()
        elseif self.kobold_tab == "home" and self.refreshCovers then
            UIManager:nextTick(function()
                self.data = require("kobold.data.home").getHomeData()
                self:refreshCovers()
            end)
        end
    end

    -- KoboldCoversUpdated: background cover extraction finished; screens
    -- with covers define refreshCovers to redraw with them.
    function ScreenClass:onKoboldCoversUpdated()
        if self.refreshCovers then self:refreshCovers() end
    end
    function ScreenClass:onNetworkConnected() KoboldWidgets.refreshStatusBar(self) end
    function ScreenClass:onNetworkDisconnected() KoboldWidgets.refreshStatusBar(self) end
    -- The device can still report "not charging" when the event arrives,
    -- so the battery is drawn again a moment later.
    function ScreenClass:onCharging()
        KoboldWidgets.refreshStatusBar(self)
        UIManager:scheduleIn(2, function() KoboldWidgets.refreshStatusBar(self) end)
    end
    function ScreenClass:onKoboldSettingsChanged() KoboldWidgets.refreshStatusBar(self) end
    -- Kobold Settings > Icons changed: the whole screen is built again, so
    -- the status bar and nav bar both use the other icon set.
    function ScreenClass:onKoboldIconsChanged()
        if self.kobold_tab == "home" then
            self:refreshCovers()
        elseif self.kobold_tab == "books" then
            self:refresh()
        else
            self:init()
            UIManager:setDirty(self, "ui")
        end
    end
    function ScreenClass:onNotCharging()
        KoboldWidgets.refreshStatusBar(self)
        UIManager:scheduleIn(2, function() KoboldWidgets.refreshStatusBar(self) end)
    end
    -- The screen was rotated or resized: lay this screen out again, in place
    -- (a screen that defines relayout()), and ask for a full repaint. Nothing
    -- is closed or opened, so the window stack stays as it was. paintTo checks
    -- the size too, in case a screen is painted before the event reaches it.
    function ScreenClass:onSetDimensions() return KoboldWidgets.handleResize(self) end
    function ScreenClass:onScreenResize() return KoboldWidgets.handleResize(self) end

    -- A book is opening (from Kobold or elsewhere): park this screen under
    -- the reader instead of closing it (see session.lua).
    function ScreenClass:onShowingReader()
        require("kobold.ui.session").rememberScreen(self)
    end
end

return KoboldWidgets
