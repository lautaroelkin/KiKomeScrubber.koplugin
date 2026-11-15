-- kobold/data/literary.lua — KiKome
-- The quote for the current minute, for the Clock card at the top of Home
-- (ui/home_clock.lua). Builds no widgets.
--
-- Based on the Literary Clock plugin (GNU AGPL-3.0); the quotes in
-- data/quotes/ are under CC BY-NC-SA 2.5, see data/quotes/NOTICE.md.
--
-- data/quotes/en/HH.lua: one file per hour, each returning
--   { ["HH:MM"] = { quote, title, author } }
-- The collection is trimmed to keep the plugin small: safe-for-work quotes
-- only, one short quote per minute (1321 minutes of the day; the rest get a
-- line written for the time, see fallbacks.lua).
-- Only the hour on screen is kept in memory. The quote text carries its own
-- styling: \1 ... \2 italic, \3 ... \4 the time phrase.
--
--   Literary.pick(now) -> quote, title, author
--   Literary.hasQuotes()               -> false when the data is missing

local KoboldMeta = require("kobold.meta")

local Literary = {}

local LANG = "en"   -- the only collection shipped for now

local base_dir = (KoboldMeta.DIR or ".") .. "/kobold/data/quotes"
local cache_hour, cache_data

local function loadHour(hh)
    if cache_hour == hh then return cache_data end
    local ok, data = pcall(dofile, string.format("%s/%s/%s.lua", base_dir, LANG, hh))
    if not ok or type(data) ~= "table" then data = {} end
    cache_hour, cache_data = hh, data
    return data
end

function Literary.hasQuotes()
    local f = io.open(string.format("%s/%s/12.lua", base_dir, LANG), "r")
    if f then f:close(); return true end
    return false
end

-- The quote for "HH:MM": { text, title, author }, or nil.
local function quoteAt(hhmm)
    local q = loadHour(hhmm:sub(1, 2))[hhmm]
    if type(q) == "table" and type(q[1]) == "string" then return q end
    return nil
end

---------------------------------------------------------------------------
-- Minutes with no quote: a line written like one (data/quotes/fallbacks.lua)
---------------------------------------------------------------------------

local TimeWords, fallbacks
local FAMILIES = { "narrator", "reader" }
local next_family, last_index = 1, {}
local cached_minute, cached_text

local function loadFallbacks()
    if fallbacks then return fallbacks end
    pcall(require, "random")   -- seeds math.random
    local ok_t, tw = pcall(dofile, base_dir .. "/timewords.lua")
    local ok_f, fb = pcall(dofile, base_dir .. "/fallbacks.lua")
    TimeWords = ok_t and tw or nil
    fallbacks = (ok_f and type(fb) == "table") and fb or {}
    for _i, name in ipairs(FAMILIES) do
        local list = {}
        for _j, s in ipairs(type(fallbacks[name]) == "table" and fallbacks[name] or {}) do
            if type(s) == "string" and s:find("{time}", 1, true) then list[#list + 1] = s end
        end
        fallbacks[name] = list
    end
    return fallbacks
end

local function randomIndex(n, avoid)
    if n <= 1 then return 1 end
    local i = math.random(n - 1)
    if avoid and i >= avoid then i = i + 1 end
    return i
end

-- Upper-cases the first letter, skipping the \3 \4 markers.
local function capitalise(s)
    return (s:gsub("^([\1-\4]*)(%l)", function(marks, c) return marks .. c:upper() end))
end

local function fallbackLine(now)
    local minute = math.floor(now / 60)
    if minute == cached_minute then return cached_text end
    local fb = loadFallbacks()
    local hour, min = tonumber(os.date("%H", now)), tonumber(os.date("%M", now))
    local words = TimeWords and TimeWords.time_to_words(hour, min) or os.date("%H:%M", now)

    local list
    for _k = 1, #FAMILIES do
        local family = FAMILIES[next_family]
        next_family = next_family % #FAMILIES + 1
        list = fb[family]
        if list and #list > 0 then
            local i = randomIndex(#list, last_index[family])
            last_index[family] = i
            local marked = "\3" .. words .. "\4"
            cached_minute = minute
            cached_text = capitalise((list[i]:gsub("{time}", function() return marked end)))
            return cached_text
        end
    end
    cached_minute = minute
    cached_text = capitalise("\3" .. words .. "\4.")
    return cached_text
end

---------------------------------------------------------------------------
-- The pick
---------------------------------------------------------------------------

-- The quote for time `now` (seconds). A minute with no quote gets a fallback
-- line. Returns quote, title, author (title and author are "" for a fallback).
function Literary.pick(now)
    now = now or os.time()
    local q = quoteAt(os.date("%H:%M", now))
    if not q then return fallbackLine(now), "", "" end
    return q[1], q[2] or "", q[3] or ""
end

return Literary
