-- kobold/ui/nav.lua — Kobold
-- Bottom navigation bar shared by the Kobold screens: Home and Library.
-- Settings is not here; it opens from the button beside the shelf chips.
-- Each tab has a bar above it: black for the selected tab, light gray for the rest.
-- Between the two tabs, centred on the bar line, sits a small cover of the
-- book opened last, on a white backing that cuts the line. Tapping it opens
-- that book. With Settings > Home > Rounded corners on, the cover and its
-- backing have rounded corners.

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local LineWidget      = require("ui/widget/linewidget")
local OverlapGroup    = require("ui/widget/overlapgroup")
local ReadHistory     = require("readhistory")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local Widget          = require("ui/widget/widget")
local lfs             = require("libs/libkoreader-lfs")
local KoboldRouter    = require("kobold.ui.router")
local Rounded         = require("kobold.ui.rounded")
local KoboldTaps      = require("kobold.ui.taps")
local KoboldWidgets   = require("kobold.ui.widgets")

local Screen = Device.screen

local KoboldNav = {}

-- `icon` is one of Kobold's own icons; `fallback` is the KOReader icon used
-- when that file is missing.
local TABS = {
    { id = "home",  text = "Home",    icon = "home",     fallback = "home",    event = "NavHome" },
    { id = "books", text = "Library", icon = "my-books", fallback = "library", event = "NavBooks" },
}

function KoboldNav.height()
    return Screen:scaleBySize(72)
end

-- The bar above one tab: black when the tab is selected, light gray otherwise.
local function tabBar(tab_w, bar_h, selected)
    return LineWidget:new{
        dimen = Geom:new{ w = tab_w, h = bar_h },
        background = selected and Blitbuffer.COLOR_BLACK or Blitbuffer.COLOR_LIGHT_GRAY,
    }
end

-- The file of the book opened last, if it still exists.
local function lastBookFile()
    local h = ReadHistory.hist and ReadHistory.hist[1]
    if h and h.file and lfs.attributes(h.file, "mode") == "file" then return h.file end
    return nil
end

-- Opens the book of the mini cover. A tap can reach both the cover's own zone
-- and the tab zone under it, so a second request within a moment is ignored.
local opening = false
local function openBook(screen, file)
    if opening then return true end
    opening = true
    UIManager:scheduleIn(1.5, function() opening = false end)
    require("kobold.ui.reader").open(screen, file, { splash = true })
    return true
end

-- The page and the page count a screen shows: the screen's own getPageInfo()
-- (My Books), or the Home shelf's. nil when there is nothing to show.
local function pageInfo(screen)
    if not screen then return nil end
    if screen.getPageInfo then return screen:getPageInfo() end
    local shelf = screen.library_shelf
    if shelf then return shelf.page or 1, shelf.total_pages or 1 end
    return nil
end

-- The page indicator ("1|3"), small and centred under the mini cover. It
-- reads the page when it paints, so it follows page turns without the screen
-- being rebuilt. Nothing is drawn when there is one page.
local PageTag = Widget:extend{ screen = nil, width = 0, height = 0 }

function PageTag:getSize() return Geom:new{ w = self.width, h = self.height } end

function PageTag:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.width, h = self.height }
    local page, total = pageInfo(self.screen)
    if not page or (total or 1) <= 1 then return end
    local tw = TextWidget:new{
        text = page .. "|" .. total,
        face = KoboldWidgets.face(13),
        fgcolor = KoboldWidgets.subtitleColor(),
    }
    local sz = tw:getSize()
    tw:paintTo(bb, x + math.floor((self.width - sz.w) / 2), y + math.floor((self.height - sz.h) / 2))
    tw:free()
end

-- The small cover between the tabs. It straddles the line above the tabs:
-- half over it, half inside the bar, on a white backing that cuts the line
-- and outlines the cover. Returns nil when there is no book yet; otherwise the
-- box, where it ends, the book's file, and the rectangle to tap to open it.
local function lastBookCover(W, nav_top, bar_h)
    local file = lastBookFile()
    if not file then return nil, nil end
    local pad     = Screen:scaleBySize(4)
    local cover_h = Screen:scaleBySize(74)
    local cover_w = math.floor(cover_h / 1.5)
    local box_w, box_h = cover_w + 2 * pad, cover_h + 2 * pad
    -- A book with no cover gets a plain block: makeCover leaves the title off
    -- covers this small.
    -- Rounded corners follow the setting (Rounded.cover returns the plain
    -- cover when it is off); the white backing is rounded the same way.
    local cover = Rounded.cover(file, cover_w, cover_h, { outline = true })
    local box = FrameContainer:new{
        bordersize = 0, margin = 0, padding = pad,
        radius = Rounded.enabled() and Screen:scaleBySize(14) or 0,
        background = Blitbuffer.COLOR_WHITE,
        cover,
    }
    -- centred on the line
    local line_mid = nav_top + math.floor(bar_h / 2)
    local drop = Screen:scaleBySize(4)   -- a little lower than centred
    local top = line_mid - math.floor(box_h / 2) + drop
    local left = math.floor((W - box_w) / 2)
    box.overlap_offset = { left, top }
    -- a little more than the cover itself is a tap on it
    local m = Screen:scaleBySize(6)
    local rect = Geom:new{ x = left - m, y = math.max(0, top - m), w = box_w + 2 * m, h = box_h + 2 * m }
    return box, top + box_h, file, rect
end

-- Registers the tab tap zones on `screen` (sized W x H) and returns the nav
-- widget, pushed to the bottom edge. Use it inside an OverlapGroup.
function KoboldNav.attach(screen, W, H, active)
    local nav_h = KoboldNav.height()
    local bar_h = Screen:scaleBySize(3)
    local tab_w = math.floor(W / #TABS)
    local nav_top = H - nav_h

    -- The mini cover opens the last book. Its zone is registered before the
    -- tabs', and the tab zones hand a tap that lands on the cover to it too,
    -- since the cover sits over the line between them.
    local cover, cover_bottom, cover_file, cover_rect = lastBookCover(W, nav_top, bar_h)
    if cover then
        KoboldTaps.add(screen, "NavLastBook", cover_rect.x, cover_rect.y, cover_rect.w, cover_rect.h, function()
            return openBook(screen, cover_file)
        end)
    end

    local row = HorizontalGroup:new{}
    for i, tab in ipairs(TABS) do
        local id = tab.id
        local selected = tab.id == active
        KoboldTaps.add(screen, tab.event, (i - 1) * tab_w, nav_top, tab_w, nav_h, function(ges)
            if cover and ges and ges.pos and ges.pos:intersectWith(cover_rect) then
                return openBook(screen, cover_file)
            end
            KoboldRouter.show(id, screen)
        end)
        row[#row + 1] = VerticalGroup:new{
            tabBar(tab_w, bar_h, selected),
            CenterContainer:new{
                dimen = Geom:new{ w = tab_w, h = nav_h - bar_h },
                VerticalGroup:new{
                    KoboldWidgets.customIcon(tab.icon, Screen:scaleBySize(24), tab.fallback),
                    VerticalSpan:new{ width = Screen:scaleBySize(3) },
                    TextWidget:new{
                        text = tab.text,
                        face = KoboldWidgets.face(16),
                        bold = selected,
                    },
                },
            },
        }
    end
    row.overlap_offset = { 0, nav_top }

    local stack = OverlapGroup:new{ dimen = Geom:new{ w = W, h = H } }
    -- A thin white line just above the bars, so a book cut by the edge of the
    -- shelf does not run into them.
    local sep_h = Screen:scaleBySize(3)
    local sep = LineWidget:new{
        dimen = Geom:new{ w = W, h = sep_h },
        background = Blitbuffer.COLOR_WHITE,
    }
    sep.overlap_offset = { 0, nav_top - sep_h }
    stack[#stack + 1] = sep
    stack[#stack + 1] = row
    -- after the row, so the backing sits on top of the line
    if cover then stack[#stack + 1] = cover end

    -- Page indicator under the cover (or just under the line when there is none).
    local tag_h = Screen:scaleBySize(18)
    local tag_y = math.min((cover_bottom or (nav_top + bar_h)) + Screen:scaleBySize(1), H - tag_h)
    local tag = PageTag:new{ screen = screen, width = W, height = tag_h }
    tag.overlap_offset = { 0, tag_y }
    stack[#stack + 1] = tag
    return stack
end

return KoboldNav
