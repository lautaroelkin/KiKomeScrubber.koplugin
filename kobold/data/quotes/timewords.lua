--[[
The time in words, in the styles the quotes in the dataset use:
"twenty-seven minutes to ten", "nine thirty-three", "a quarter past eleven",
"five past ten", "nine oh five", "midnight".

12-hour clock, no a.m./p.m.

    TimeWords.forms(h, m)          -> list of every form for h:m (h 0-23)
    TimeWords.time_to_words(h, m)  -> one of them, picked at random
]]

local TimeWords = {}

local ONES = {
    [0] = "zero", "one", "two", "three", "four", "five", "six", "seven",
    "eight", "nine", "ten", "eleven", "twelve", "thirteen", "fourteen",
    "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
}
local TENS = { [2] = "twenty", [3] = "thirty", [4] = "forty", [5] = "fifty" }

--- 0-59 in words, hyphenated: 27 -> "twenty-seven".
function TimeWords.number(n)
    if n < 20 then return ONES[n] end
    local t, o = math.floor(n / 10), n % 10
    if o == 0 then return TENS[t] end
    return TENS[t] .. "-" .. ONES[o]
end

local function hour12(h)
    h = h % 12
    return h == 0 and 12 or h
end

local function minutesWord(n)
    return n == 1 and "minute" or "minutes"
end

function TimeWords.forms(h, m)
    local hw   = TimeWords.number(hour12(h))
    local next = TimeWords.number(hour12(h + 1))
    local out = {}
    local function add(s) out[#out + 1] = s end

    if m == 0 then
        add(hw .. " o'clock")
        add(hw)
        if h == 0 then add("midnight") end
        if h == 12 then add("noon") end
        return out
    end

    -- Digital style: "nine thirty-three", "nine oh five".
    if m < 10 then
        add(hw .. " oh " .. TimeWords.number(m))
    else
        add(hw .. " " .. TimeWords.number(m))
    end

    if m == 15 then
        add("a quarter past " .. hw)
        add("quarter past " .. hw)
    elseif m == 30 then
        add("half past " .. hw)
    elseif m == 45 then
        add("a quarter to " .. next)
        add("quarter to " .. next)
    elseif m < 30 then
        add(TimeWords.number(m) .. " " .. minutesWord(m) .. " past " .. hw)
        if m % 5 == 0 then add(TimeWords.number(m) .. " past " .. hw) end
    else
        local to = 60 - m
        add(TimeWords.number(to) .. " " .. minutesWord(to) .. " to " .. next)
        if to % 5 == 0 then add(TimeWords.number(to) .. " to " .. next) end
    end
    return out
end

function TimeWords.time_to_words(h, m)
    local forms = TimeWords.forms(h, m)
    return forms[math.random(#forms)]
end

return TimeWords
