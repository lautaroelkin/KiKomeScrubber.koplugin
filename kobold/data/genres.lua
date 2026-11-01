-- kobold/data/genres.lua — KiKome
-- The genres of a book, for the Genres tab of the Library and the Genres chip
-- of Home. A genre is one of the book's keywords (the "subjects" of an EPUB:
-- Fantasy, Science Fiction...). They come from the book's custom metadata
-- first, then from the cover browser's book info (the same order of priority
-- as author, series and language). Builds no widgets.
--
--   Genres.split(raw)   the genres in a keywords string: { "Fantasy", ... }
--   Genres.of(file)     the genres of one book, remembered: { "Fantasy", ... }
--   Genres.forget()     forget what was read (the book info may have changed)
--
-- A genre is always returned in one canonical spelling, so that "fantasy",
-- "FANTASY" and "Fantasy" end up in one group: group them by name:lower().

local Genres = {}

local KoboldBookInfo = require("kobold.data.bookinfo")
local KoboldLibrary  = require("kobold.data.library")

-- Keywords of one book are cut at these. EPUB subjects come as one per line
-- (or joined with a comma or semicolon); BISAC / Library of Congress subjects
-- carry their levels in one string ("FICTION / Fantasy / Epic",
-- "Fantasy fiction -- Juvenile"), and each level is a genre of its own.
local SEPARATORS = { "\n", "\r", ";", ",", "|", " / ", " -- ", " > ", " \u{2013} " }

local MIN_LEN, MAX_LEN = 2, 40

local cache = {}  -- file -> list of genres ({} when the book has none)

local function trim(s)
    return (s:gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

-- "fantasy" and "FANTASY" -> "Fantasy". Anything with mixed case ("Epic
-- fantasy", "LitRPG") was written on purpose and stays as it is.
local function canonical(s)
    local has_lower, has_upper = s:find("%l") ~= nil, s:find("%u") ~= nil
    if has_lower and has_upper then return s end
    return (s:lower():gsub("(%S+)", function(w)
        return (w:gsub("^%l", string.upper))
    end))
end

-- The genres in a keywords string, without repeats, in the order written.
function Genres.split(raw)
    local out = {}
    if type(raw) ~= "string" or raw == "" then return out end
    -- One marker for every kind of separator, then cut there.
    local marked = raw
    for _i, sep in ipairs(SEPARATORS) do
        marked = marked:gsub((sep:gsub("%p", "%%%0")), "\1")
    end
    local seen = {}
    for part in marked:gmatch("[^\1]+") do
        local name = trim(part)
        -- Too short or too long to be a genre, or only digits (a year, an id).
        if #name >= MIN_LEN and #name <= MAX_LEN and not name:match("^[%d%p%s]+$") then
            name = canonical(name)
            local key = name:lower()
            if not seen[key] then
                seen[key] = true
                out[#out + 1] = name
            end
        end
    end
    return out
end

local function nonEmpty(v)
    return (type(v) == "string" and v ~= "") and v or nil
end

-- What the reader wrote with KOReader's metadata editor, if anything. Only
-- looked up for books that have a sidecar folder (the editor keeps its file
-- there), and the answer to that comes from the library scan, not the disk.
local function customKeywords(file)
    if KoboldLibrary.sidecarStamp(file) == nil then return nil end
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings and DocSettings.findCustomMetadataFile) then return nil end
    local ok2, props = pcall(function()
        local path = DocSettings:findCustomMetadataFile(file)
        if not path then return nil end
        return DocSettings.openSettingsFile(path):readSetting("custom_props")
    end)
    if ok2 and type(props) == "table" then return nonEmpty(props.keywords) end
    return nil
end

-- The genres of one book. A book the cover browser has not read yet has none
-- for now, and is asked again next time.
function Genres.of(file)
    local c = cache[file]
    if c then return c end
    local raw = customKeywords(file)
    local known = raw ~= nil
    if not raw then
        -- One query for the whole library (see bookinfo.lua), not one per book.
        local row = KoboldBookInfo.get(file)
        if row then
            known = true
            raw = nonEmpty(row.keywords)
        end
    end
    local list = Genres.split(raw)
    if known then cache[file] = list end
    return list
end

function Genres.forget()
    cache = {}
end

return Genres
