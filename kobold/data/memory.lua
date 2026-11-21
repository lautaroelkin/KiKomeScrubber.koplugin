-- kobold/data/memory.lua — KiKome
-- How much memory the device has left, and what KiKome gives back when a book
-- opens. Builds no widgets.
--
-- Why it exists: on a device with little RAM (a basic Kindle) a big book needs
-- most of what is free. Everything KiKome keeps while a book is open (the
-- covers in memory, the Home screen parked under the reader, garbage that
-- nobody collected yet: the bitmaps live outside Lua's own heap, so Lua's
-- collector does not "feel" them) is memory the book cannot use, and the
-- device slows down more and more with each book opened. So:
--
--   * the cover cache budget follows the device (see Memory.coverBudget);
--   * when a book is about to open, the cover cache is cut down and Lua's
--     garbage is collected (Memory.releaseForReader);
--   * a little after the book is open, with memory still short, the screen
--     parked under it is let go (Memory.trimParked); it is built again when
--     the book is closed;
--   * when the book is left, the budget is given back (Memory.afterReader).
--
-- Every function is safe to call anywhere: a failure is only logged.

local logger = require("logger")

local Memory = {}

local MIB = 1024 * 1024

-- Cover cache: the most it ever takes, the least it is cut to, and the share
-- of the device's RAM / of what is free it may use.
local COVER_MAX          = 12 * MIB
local COVER_MIN          = 3 * MIB
local COVER_TOTAL_SHARE  = 0.04
local COVER_FREE_SHARE   = 0.10
-- While a book is open the cache keeps this part of its budget.
local READER_SHARE       = 0.25

-- A device with at most this much RAM is "low memory" (a basic Kindle has
-- about 512 MB, of which the system leaves a part to KOReader).
local LOW_MEMORY_TOTAL   = 640 * MIB
-- Free memory (available / total) under which the pressure is "low" and
-- "critical".
local LOW_FRACTION       = 0.25
local CRITICAL_FRACTION  = 0.15

-- /proc/meminfo is read at most once a second.
local read_at, read_avail, read_total
local function readMemory()
    local now = os.time()
    if read_at == now then return read_avail, read_total end
    read_at = now
    read_avail, read_total = nil, nil
    local ok_u, util = pcall(require, "util")
    if not (ok_u and type(util) == "table" and type(util.calcFreeMem) == "function") then
        return nil, nil
    end
    local ok, avail, total = pcall(util.calcFreeMem)
    avail, total = tonumber(avail), tonumber(total)
    if ok and avail and total and avail >= 0 and total > 0 then
        read_avail, read_total = avail, total
    end
    return read_avail, read_total
end

-- { available, total, fraction, pressure = "normal" | "low" | "critical",
--   low_memory = true on a small device }. Without a reading (no /proc/meminfo)
-- the pressure is "normal" and nothing is cut.
function Memory.profile()
    local avail, total = readMemory()
    local p = { available = avail, total = total, pressure = "normal", low_memory = false }
    if avail and total then
        p.fraction = avail / total
        p.low_memory = total <= LOW_MEMORY_TOTAL
        if p.fraction < CRITICAL_FRACTION then
            p.pressure = "critical"
        elseif p.fraction < LOW_FRACTION then
            p.pressure = "low"
        end
    end
    return p
end

-- Bytes the cover cache may hold with no book open.
function Memory.coverBudget(profile)
    profile = profile or Memory.profile()
    if not (profile.total and profile.available) then return COVER_MAX end
    local by_total = math.floor(profile.total * COVER_TOTAL_SHARE)
    local by_free  = math.floor(profile.available * COVER_FREE_SHARE)
    local budget = math.min(COVER_MAX, by_total, by_free)
    if profile.pressure == "critical" then budget = math.floor(budget / 2) end
    return math.max(COVER_MIN, budget)
end

-- True when screens should not load more than they show (warm-up of the
-- other screens' code, and so on).
function Memory.canPrewarm(profile)
    profile = profile or Memory.profile()
    return profile.pressure == "normal"
end

-- True when a book can be kept open under KiKome (hot parking, park.lua):
-- not while memory is short, because the book then takes what the next one
-- would need.
function Memory.canPark(profile)
    profile = profile or Memory.profile()
    return profile.pressure ~= "critical"
end

local function collect()
    pcall(collectgarbage, "collect")
    pcall(collectgarbage, "collect")
end

-- Writes how things stand to KOReader's log ("[kobold perf] mem ..."), to see
-- on a real device what a book costs: free memory, and the Lua heap.
function Memory.log(label)
    local p = Memory.profile()
    local ok, kb = pcall(collectgarbage, "count")
    logger.info(string.format("[kobold perf] mem %s: available=%s MB of %s MB (%s), lua heap=%.1f MB",
        tostring(label),
        p.available and string.format("%.0f", p.available / MIB) or "?",
        p.total and string.format("%.0f", p.total / MIB) or "?",
        p.pressure,
        (ok and tonumber(kb) or 0) / 1024))
end

local function covers()
    return package.loaded["kobold.data.covers"]
end

-- A book is about to open: what KiKome keeps in memory is cut down and the
-- garbage is collected, so the book finds as much free memory as possible.
-- Called after a parked book has been closed, right before the new one loads.
function Memory.releaseForReader()
    pcall(function()
        Memory.log("before opening")
        local Covers = covers()
        if Covers and Covers.setBudget then
            Covers.setBudget(math.floor(Memory.coverBudget() * READER_SHARE))
        end
        collect()
        read_at = nil  -- the next reading is fresh
        Memory.log("after release")
    end)
end

-- The book is open (a moment after, when its loading is done). With memory
-- still short the KiKome screen parked under it is let go: it comes back
-- built again when the book is closed. True when something was let go.
function Memory.trimParked()
    local dropped = false
    pcall(function()
        collect()
        read_at = nil
        local p = Memory.profile()
        Memory.log("book open")
        if p.pressure == "normal" then return end
        local Park = package.loaded["kobold.ui.park"]
        if Park and Park.isParked() then return end  -- the book itself is the parked one
        local Session = package.loaded["kobold.ui.session"]
        if Session and Session.dropParkedQuiet then
            Session.dropParkedQuiet()
            dropped = true
            collect()
        end
    end)
    return dropped
end

-- The book was left (parked or closed): the cover cache gets its normal
-- budget back.
function Memory.afterReader()
    pcall(function()
        local Covers = covers()
        if Covers and Covers.setBudget then
            Covers.setBudget(Memory.coverBudget())
        end
    end)
end

-- Garbage collected now (the real close of a parked book, a screen that was
-- dropped).
function Memory.collect()
    pcall(collect)
end

return Memory
