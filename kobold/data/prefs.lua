-- kobold/data/prefs.lua — Kobold
-- Kobold's own settings (Kobold Settings in the More tab), kept together in
-- one table in KOReader's settings file. Builds no widgets.

local KoboldPrefs = {}

local KEY = "kobold_settings"

-- Goes up on every change, so a screen can tell whether settings changed
-- while it was open.
local revision = 0

function KoboldPrefs.revision()
    return revision
end

-- Books per page on lists with covers (Books, Series, a group's books).
KoboldPrefs.COVER_ROWS_MIN = 3
KoboldPrefs.COVER_ROWS_MAX = 8

local DEFAULT_ACTION = "stats_calendar_view"  -- a KOReader action id

local DEFAULTS = {
    cover_rows = 5,
    -- Home reading stats. Each line is a preset stat or custom text, with its
    -- own tap action. Line 2 shows only when Continue Reading wraps.
    stats_line1_kind   = "stat",         -- "stat" or "text"
    stats_line1        = "total_hours",  -- stat id, see KoboldStats.LINES
    stats_line1_text   = "",
    stats_line1_action = DEFAULT_ACTION,
    stats_line2_kind   = "stat",
    stats_line2        = "week_hours",
    stats_line2_text   = "",
    stats_line2_action = DEFAULT_ACTION,
    stats_label        = nil,            -- nil = "Reading Stats"
    battery            = "fill",         -- "fill" or "percent"
    -- The top of Home (Settings > Home > Top of Home): "recent" is the row of recent
    -- books, "current" one card with the book being read (see ui/home_current.lua),
    -- "clock" the time with a line from a book that mentions it (see ui/home_clock.lua).
    home_top           = "recent",
    -- Status bar clock (see data/clock.lua). The 12 / 24-hour choice is not
    -- here: the clock follows KOReader's own setting.
    clock_layout       = "time",         -- "time", "day_time", "time_date", "time_numeric", "date", "two_lines" or "custom"
    clock_date_order   = "dm",           -- "dm" (5 Nov) or "md" (Nov 5)
    clock_year         = false,          -- add the year to the date
    clock_pattern      = "%K, %a %e %b", -- the custom layout
    open_tap           = "koreader",     -- "koreader", "single" or "double"
    hot_park           = true,           -- leaving a book keeps it open under KiKome (see park.lua)
    -- Stable pages: "stable_pages_mode" is "off", "koreader" or "metadata" (see data/stable_pages.lua).
    -- It has no default here on purpose: with none chosen yet, Settings shows KOReader's own switch
    -- (Default settings for new books > use stable page numbers), or what the older switch below said.
    stable_pages       = false,          -- older switch (Metadata page count on / off), taken over by stable_pages_mode
    -- The plugin's two fonts (see data/fonts.lua): the path of a font file, or nil for KOReader's own font.
    font_primary       = nil,
    font_secondary     = nil,
}

-- The settings behind the reading stats popup, for its reset button.
KoboldPrefs.STATS_KEYS = {
    "stats_line1_kind", "stats_line1", "stats_line1_text", "stats_line1_action",
    "stats_line2_kind", "stats_line2", "stats_line2_text", "stats_line2_action",
    "stats_label",
}

local function all()
    local t = G_reader_settings and G_reader_settings:readSetting(KEY)
    if type(t) ~= "table" then t = {} end
    return t
end

function KoboldPrefs.get(name)
    local v = all()[name]
    if v == nil then return DEFAULTS[name] end
    return v
end

-- Saves one setting. nil goes back to the default.
function KoboldPrefs.set(name, value)
    if not G_reader_settings then return end
    local t = all()
    t[name] = value
    G_reader_settings:saveSetting(KEY, t)
    revision = revision + 1
end

-- Tells the open screens that something changed (the Library tabs, which are
-- kept elsewhere, use it): the revision goes up, nothing is saved.
function KoboldPrefs.touch()
    revision = revision + 1
end

-- Puts the given settings back to their defaults.
function KoboldPrefs.reset(names)
    if not G_reader_settings then return end
    local t = all()
    for _i, name in ipairs(names) do t[name] = nil end
    G_reader_settings:saveSetting(KEY, t)
    revision = revision + 1
end

-- Puts every Kobold setting back to its default.
function KoboldPrefs.resetAll()
    if G_reader_settings then G_reader_settings:delSetting(KEY) end
    revision = revision + 1
end

-- Top of Home views: ordered list of { id = "recent"|"current"|"clock", enabled = bool }.
local HOME_TOP_ORDER = { "recent", "current", "clock" }
local HOME_TOP_VALID = { recent = true, current = true, clock = true }

function KoboldPrefs.homeTopList()
    local t = all()
    local saved = t.home_top_items
    local out, seen = {}, {}
    if type(saved) == "table" then
        for _i, e in ipairs(saved) do
            if type(e) == "table" and HOME_TOP_VALID[e.id] and not seen[e.id] then
                seen[e.id] = true
                out[#out + 1] = { id = e.id, enabled = e.enabled == true }
            end
        end
        for _i, id in ipairs(HOME_TOP_ORDER) do
            if not seen[id] then
                seen[id] = true
                out[#out + 1] = { id = id, enabled = false }
            end
        end
    else
        local legacy = t.home_top
        local first = (legacy == "current" or legacy == "clock") and legacy or "recent"
        out[#out + 1] = { id = first, enabled = true }
        for _i, id in ipairs(HOME_TOP_ORDER) do
            if id ~= first then
                out[#out + 1] = { id = id, enabled = false }
            end
        end
    end
    local any = false
    for _i, e in ipairs(out) do
        if e.enabled then any = true; break end
    end
    if not any and out[1] then out[1].enabled = true end
    return out
end

function KoboldPrefs.homeTopEnabled()
    local out = {}
    for _i, e in ipairs(KoboldPrefs.homeTopList()) do
        if e.enabled then out[#out + 1] = e.id end
    end
    return out
end

local function saveHomeTopList(list)
    if not G_reader_settings then return end
    local t = all()
    local saved = {}
    local first_enabled
    for _i, e in ipairs(list) do
        saved[#saved + 1] = { id = e.id, enabled = e.enabled and true or false }
        if e.enabled and not first_enabled then first_enabled = e.id end
    end
    t.home_top_items = saved
    if first_enabled then t.home_top = first_enabled end
    G_reader_settings:saveSetting(KEY, t)
    revision = revision + 1
end

function KoboldPrefs.setHomeTopEnabled(id, on)
    local list = KoboldPrefs.homeTopList()
    local enabled_count = 0
    for _i, e in ipairs(list) do
        if e.enabled then enabled_count = enabled_count + 1 end
    end
    for _i, e in ipairs(list) do
        if e.id == id then
            if not on and e.enabled and enabled_count <= 1 then
                return false, "last"
            end
            e.enabled = on and true or false
            saveHomeTopList(list)
            return true
        end
    end
    return false
end

function KoboldPrefs.moveHomeTop(id, dir)
    local list = KoboldPrefs.homeTopList()
    local idx
    for i, e in ipairs(list) do
        if e.id == id then idx = i; break end
    end
    if not idx then return false end
    local target = idx + dir
    if target < 1 or target > #list then return false end
    list[idx], list[target] = list[target], list[idx]
    saveHomeTopList(list)
    return true
end

function KoboldPrefs.homeTopSignature()
    local parts = {}
    for _i, e in ipairs(KoboldPrefs.homeTopList()) do
        parts[#parts + 1] = e.id .. (e.enabled and "+" or "-")
    end
    return table.concat(parts, "|")
end

-- Books per page on cover lists, kept inside the allowed range.
function KoboldPrefs.coverRows()
    local n = tonumber(KoboldPrefs.get("cover_rows")) or DEFAULTS.cover_rows
    return math.max(KoboldPrefs.COVER_ROWS_MIN, math.min(KoboldPrefs.COVER_ROWS_MAX, math.floor(n)))
end

return KoboldPrefs
