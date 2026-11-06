-- kobold/data/clock.lua — Kobold
-- What the status bar shows where the time used to be: the time alone, or the
-- time with the weekday and the date, in the layout chosen in Settings >
-- General > Status bar. Builds no widgets: it only returns text.
--
-- Every layout is a pattern, and the preset layouts are patterns too, so the
-- custom pattern and the presets go through the same code. A pattern is
-- strftime-like (os.date), with a few additions:
--
--   %K   the time as KOReader is set to show it (24 hours, or 12 with AM/PM)
--   %e   day of the month without a leading zero (5, not 05)
--   %n   a line break (the status bar shows two lines at most)
--   %a %A %b %B   weekday and month names, short / long, from KOReader's own
--                 translated names (datetime.lua), so the plugin has nothing
--                 of its own to translate
--
-- Anything else after a % goes to os.date (%H %M %I %p %d %m %y %Y %j ...).
-- A layout that has the time uses %K, so it follows KOReader's clock setting.

local KoboldPrefs = require("kobold.data.prefs")

local KoboldClock = {}

-- Layouts, in the order the Settings page lists them.
KoboldClock.LAYOUTS = { "time", "day_time", "time_date", "time_numeric", "date", "two_lines", "custom" }

-- Pattern of the custom layout until the user writes their own.
KoboldClock.DEFAULT_PATTERN = "%K, %a %e %b"

---------------------------------------------------------------------------
-- Time and names
---------------------------------------------------------------------------

-- True when the clock shows 24-hour time: KOReader's own clock setting.
function KoboldClock.clock24()
    return not (G_reader_settings and G_reader_settings:isTrue("twelve_hour_clock"))
end

-- "22:42" or "10:42 PM".
function KoboldClock.timeText(t)
    if KoboldClock.clock24() then return os.date("%H:%M", t) end
    return (os.date("%I:%M %p", t):gsub("^0", ""))
end

-- A weekday or month name as KOReader translates it. `table_name` is one of
-- the translation tables of KOReader's datetime module, keyed by the English
-- name os.date gives. Without the table, or the name, the English name stays.
local function translated(table_name, english)
    local ok, datetime = pcall(require, "datetime")
    local tbl = ok and type(datetime) == "table" and datetime[table_name]
    return (type(tbl) == "table" and tbl[english]) or english
end

local NAMES = {
    a = { "%a", "shortDayOfWeekTranslation" },
    A = { "%A", "longDayOfWeekTranslation" },
    b = { "%b", "shortMonthTranslation" },
    B = { "%B", "longMonthTranslation" },
}

---------------------------------------------------------------------------
-- Patterns
---------------------------------------------------------------------------

-- The text of `pattern` for time `t` (now when nil).
function KoboldClock.expand(pattern, t)
    t = t or os.time()
    local out, i, n = {}, 1, #pattern
    while i <= n do
        local c = pattern:sub(i, i)
        if c == "%" and i < n then
            local k = pattern:sub(i + 1, i + 1)
            i = i + 2
            local v
            if k == "%" then
                v = "%"
            elseif k == "K" then
                v = KoboldClock.timeText(t)
            elseif k == "n" then
                v = "\n"
            elseif k == "e" then
                v = tostring(tonumber(os.date("%d", t)) or "")
            elseif NAMES[k] then
                v = translated(NAMES[k][2], os.date(NAMES[k][1], t))
            else
                local ok, r = pcall(os.date, "%" .. k, t)
                v = (ok and type(r) == "string") and r or ("%" .. k)
            end
            out[#out + 1] = v
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return table.concat(out)
end

-- The date as words: "5 Nov" (day first) or "Nov 5" (month first), with the
-- year when asked: "5 Nov 2026" / "Nov 5, 2026".
local function wordsDate(order, year)
    if order == "md" then return year and "%b %e, %Y" or "%b %e" end
    return year and "%e %b %Y" or "%e %b"
end

-- The date as numbers: "05/11" or "11/05", with "/2026" when asked.
local function numbersDate(order, year)
    local s = (order == "md") and "%m/%d" or "%d/%m"
    return year and (s .. "/%Y") or s
end

-- The pattern of a preset layout.
local function presetPattern(layout, order, year)
    if layout == "day_time" then return "%a %K" end
    if layout == "time_date" then return "%K, %a " .. wordsDate(order, year) end
    if layout == "time_numeric" then return "%K · " .. numbersDate(order, year) end
    if layout == "date" then return "%a " .. wordsDate(order, year) end
    if layout == "two_lines" then return "%K%n%a " .. wordsDate(order, year) end
    return "%K"   -- "time", and anything unknown
end

---------------------------------------------------------------------------
-- Settings
---------------------------------------------------------------------------

local function isLayout(id)
    for _i, l in ipairs(KoboldClock.LAYOUTS) do
        if l == id then return true end
    end
    return false
end

function KoboldClock.layout()
    local id = KoboldPrefs.get("clock_layout")
    return isLayout(id) and id or "time"
end

function KoboldClock.order()
    return KoboldPrefs.get("clock_date_order") == "md" and "md" or "dm"
end

function KoboldClock.year()
    return KoboldPrefs.get("clock_year") == true
end

function KoboldClock.customPattern()
    local p = KoboldPrefs.get("clock_pattern")
    if type(p) == "string" and p ~= "" then return p end
    return KoboldClock.DEFAULT_PATTERN
end

-- The pattern of `layout` (the chosen one when nil) with the date order and
-- year chosen in Settings.
function KoboldClock.pattern(layout)
    layout = layout or KoboldClock.layout()
    if layout == "custom" then return KoboldClock.customPattern() end
    return presetPattern(layout, KoboldClock.order(), KoboldClock.year())
end

---------------------------------------------------------------------------
-- What the status bar and Settings show
---------------------------------------------------------------------------

-- The lines to draw, one or two: a third line and empty lines are dropped. A
-- pattern that comes out empty falls back to the time.
function KoboldClock.lines(t)
    local text = KoboldClock.expand(KoboldClock.pattern(), t)
    local lines = {}
    for line in (text .. "\n"):gmatch("(.-)\n") do
        line = line:match("^%s*(.-)%s*$")
        if line ~= "" then lines[#lines + 1] = line end
        if #lines == 2 then break end
    end
    if #lines == 0 then lines[1] = KoboldClock.timeText(t) end
    return lines
end

-- A preview of `layout` for the Settings page, on one line: how it looks now,
-- with the date order and year chosen.
function KoboldClock.preview(layout)
    local text = KoboldClock.expand(KoboldClock.pattern(layout))
    return (text:gsub("%s*\n%s*", " / "))
end

-- Date formats, as one choice in Settings: the order and the year together.
-- "dm" = 5 Nov, "dm_y" = 5 Nov 2026, "md" = Nov 5, "md_y" = Nov 5, 2026.
KoboldClock.FORMATS = { "dm", "dm_y", "md", "md_y" }

local function formatParts(id)
    return (id:sub(1, 2) == "md") and "md" or "dm", id:sub(-2) == "_y"
end

-- The format now chosen.
function KoboldClock.formatId()
    return KoboldClock.order() .. (KoboldClock.year() and "_y" or "")
end

-- The order and the year of a format id, to save them.
function KoboldClock.formatParts(id)
    return formatParts(id)
end

-- A preview of a format for its Settings page: the date in words and in
-- numbers ("5 Nov · 05/11", "Nov 5, 2026 · 11/05/2026").
function KoboldClock.formatPreview(id)
    local order, year = formatParts(id)
    return KoboldClock.expand(wordsDate(order, year) .. " · " .. numbersDate(order, year))
end

-- The same in words only ("5 Nov"), short enough for the value of a row.
function KoboldClock.formatWords(id)
    local order, year = formatParts(id)
    return KoboldClock.expand(wordsDate(order, year))
end

-- True when `layout` (the chosen one when nil) shows a date, so the date
-- format matters to it.
function KoboldClock.hasDate(layout)
    layout = layout or KoboldClock.layout()
    return layout == "time_date" or layout == "time_numeric" or layout == "date" or layout == "two_lines"
end

-- For the popup opened by tapping the clock: the time and the full date.
function KoboldClock.popupLines(t)
    local order = KoboldClock.order()
    local date = (order == "md") and "%B %e, %Y" or "%e %B %Y"
    return KoboldClock.timeText(t), KoboldClock.expand("%A", t), KoboldClock.expand(date, t)
end

return KoboldClock
