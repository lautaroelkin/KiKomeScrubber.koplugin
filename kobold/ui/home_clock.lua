-- kobold/ui/home_clock.lua — KiKome
-- The "Clock" card: what the top of Home shows when Settings > Home > Top of
-- Home is set to Clock. It tells the time with a line from a book that mentions
-- it (see data/literary.lua, based on the Literary Clock plugin). The book the
-- line comes from is always under it (title and author, no switch for that).
-- On top of everything there is a pill with a play button and the title of the
-- book being read; it is the colour of the cover (or grey), as the buttons of
-- the Current book card, and tapping it opens that book.
--
--              [(play) Title of the book being read]
--
--      ...and at ten past two the telephone rang...        (secondary font, the time
--                                                            words in the primary font)
--                      Book title, Author                  (title primary, author secondary)
--
-- HomeClock.build{ w, h, now, file, book_title } returns the widget, and the
-- width and height of the pill (nil when there is no book being read).

local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local TextWidget      = require("ui/widget/textwidget")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local CoverColor      = require("kobold.data.cover_color")
local KoboldFonts     = require("kobold.data.fonts")
local KoboldWidgets   = require("kobold.ui.widgets")
local Literary        = require("kobold.data.literary")
local OptionSheet     = require("kobold.ui.option_sheet")
local QuoteLayout     = require("kobold.ui.quote_layout")
local Rounded         = require("kobold.ui.rounded")

local Screen = Device.screen
local BLACK = Blitbuffer.COLOR_BLACK
local SOFT  = Blitbuffer.COLOR_GRAY_E or Blitbuffer.COLOR_LIGHT_GRAY   -- the grey of the Current book pills

local HomeClock = {}

local MIN_QUOTE = 9    -- smallest quote font size (dp)
local MAX_QUOTE = 21   -- largest quote font size (dp)

-- Height of the controls row and gap below the quote box, in dp (matches home_current.lua).
HomeClock.PILL_H   = 40
HomeClock.PILL_GAP = 8

local function U(n) return Screen:scaleBySize(n) end

-- The name KOReader finds a font file by: its file name, or the whole path.
local function fontName(path)
    local Font = require("ui/font")
    local base = path:match("([^/\\]+)$") or path
    for _i, candidate in ipairs({ base, path }) do
        local ok, face = pcall(function() return Font:getFace(candidate, 12) end)
        if ok and face then return candidate end
    end
    return nil
end

-- The four-style font set quote_layout.lua expects:
--   [0] regular      the quote's body and the author         (secondary)
--   [1] italic       (secondary; upright when it has none)
--   [2] bold         the time words and the book title        (primary)
--   [3] bold italic
-- With no font chosen for a role, KOReader's own Noto Sans.
local function fontSet()
    local secondary = KoboldFonts.chosen("secondary")
    local primary   = KoboldFonts.chosen("primary")
    local sec_name  = secondary and fontName(secondary)
    local pri_name  = primary and fontName(primary)
    local reg  = sec_name or "NotoSans-Regular.ttf"
    local ital = sec_name or "NotoSans-Italic.ttf"
    local bold = pri_name or "NotoSans-Bold.ttf"
    -- A chosen primary font is one file of unknown weight: KOReader thickens
    -- it itself, so the emphasis shows whatever the font is.
    local fake = {}
    if pri_name then fake[2], fake[3] = true, true end
    return {
        [0] = reg, [1] = ital, [2] = bold, [3] = bold,
        fake_bold = fake,
        key = table.concat({ reg, ital, bold, fake[2] and "fb" or "" }, "|"),
    }
end

local function pill(w, h, color, child)
    return FrameContainer:new{
        bordersize = 0, padding = 0, radius = math.floor(h / 2), background = color,
        CenterContainer:new{
            dimen = Geom:new{ w = w, h = h },
            child or HorizontalSpan:new{ width = 0 },
        },
    }
end

-- The play pill plus the annotations and edit round buttons, matching
-- home_current.lua. Returns the row widget, relative hit rects, and height.
local function buildControls(file, title, max_w)
    if not file or type(title) ~= "string" or title == "" then return nil end
    local h = U(HomeClock.PILL_H)
    local round_w = h
    local button_gap = U(8)
    local max_read_w = max_w - 2 * (round_w + button_gap)
    local pad = U(14)
    local icon_sz = U(18)
    local gap = U(8)
    local label = TextWidget:new{
        text = title, face = KoboldWidgets.face(17), fgcolor = BLACK,
        max_width = math.max(U(40), max_read_w - 2 * pad - icon_sz - gap),
    }
    local read_w = math.min(max_read_w, label:getSize().w + icon_sz + gap + 2 * pad)
    -- the same colour as the buttons of the Current book card: a pale shade of the
    -- cover on a colour screen, grey otherwise
    local color = CoverColor.pill(file) or SOFT
    local read_button = pill(read_w, h, color, HorizontalGroup:new{
        align = "center",
        OptionSheet.iconWidget("play", icon_sz, BLACK),
        HorizontalSpan:new{ width = gap },
        label,
    })
    local annot_button = pill(round_w, h, color, OptionSheet.iconWidget("bookmark", icon_sz, BLACK))
    local edit_button = pill(round_w, h, color, OptionSheet.iconWidget("pencil", icon_sz, BLACK))

    local row = HorizontalGroup:new{
        align = "center",
        read_button,
        HorizontalSpan:new{ width = button_gap },
        annot_button,
        HorizontalSpan:new{ width = button_gap },
        edit_button,
    }
    local rel_hits = {
        read  = { x = 0, w = read_w, h = h },
        annot = { x = read_w + button_gap, w = round_w, h = h },
        edit  = { x = read_w + 2 * button_gap + round_w, w = round_w, h = h },
    }
    return row, rel_hits, h
end

-- Options (o): w, h (the size of the card), now (default: now), file and
-- book_title (the book being read, for the controls below the quote box).
-- Returns the widget and the controls' rects relative to it (or nil).
function HomeClock.build(o)
    local W, H = o.w, o.h
    local text, title, author = Literary.pick(o.now or os.time())
    local show_attr = (title or "") ~= "" or (author or "") ~= ""

    local controls, rel_hits, controls_h = buildControls(o.file, o.book_title, W)
    local pill_gap = U(HomeClock.PILL_GAP)
    local box_h    = controls and math.max(U(40), H - controls_h - pill_gap) or H

    local pad_x   = U(16)
    local pad_y   = U(12)
    local radius  = Rounded.enabled() and U(12) or 0
    local inner_w = math.max(U(40), W - 2 * pad_x)
    local inner_h = math.max(U(24), box_h - 2 * pad_y)

    local quote = QuoteLayout.build{
        quote = text, title = title, author = author, show_attribution = show_attr,
        width = inner_w, height = inner_h, min_size = MIN_QUOTE, max_size = MAX_QUOTE,
        attr_scale = 0.75, min_attr_size = 10,
        fonts = fontSet(), emphasis = QuoteLayout.EMPHASIS.bold, line_spacing = 1.0,
        fg = BLACK, accent = BLACK, muted = BLACK,
        align = "left", align_attribution = "left",
    }

    local quote_box = FrameContainer:new{
        width = W,
        height = box_h,
        bordersize = 0,
        background = SOFT,
        radius = radius,
        padding_left = pad_x,
        padding_right = pad_x,
        padding_top = pad_y,
        padding_bottom = pad_y,
        quote,
    }

    local body = quote_box
    local hits
    if controls then
        local controls_y = box_h + pill_gap
        hits = {
            read  = Geom:new{ x = rel_hits.read.x,  y = controls_y, w = rel_hits.read.w,  h = rel_hits.read.h },
            annot = Geom:new{ x = rel_hits.annot.x, y = controls_y, w = rel_hits.annot.w, h = rel_hits.annot.h },
            edit  = Geom:new{ x = rel_hits.edit.x,  y = controls_y, w = rel_hits.edit.w,  h = rel_hits.edit.h },
        }
        body = VerticalGroup:new{
            align = "left",
            quote_box,
            VerticalSpan:new{ width = pill_gap },
            controls,
        }
    end

    return KoboldWidgets.fixed(W, H, body), hits
end

return HomeClock
