-- kobold/data/booklang.lua — Kobold
-- The language of a book ("EN", "ES", ...), for the Language filter of the
-- Sort & Filter sheet on Home and Library. It comes from the book's custom
-- metadata first, then from the cover browser's book info (the same order of
-- priority as author and series). Builds no widgets.

local BookLang = {}

-- Three letter codes that books sometimes carry, folded into the two letter
-- ones, so one language is never two chips.
local ALIASES = {
    ENG = "EN", SPA = "ES", FRE = "FR", FRA = "FR", GER = "DE", DEU = "DE",
    ITA = "IT", POR = "PT", RUS = "RU", JPN = "JA", ZHO = "ZH", CHI = "ZH",
    LAT = "LA", CAT = "CA", DUT = "NL", NLD = "NL", POL = "PL", SWE = "SV",
}

local cache = {}  -- file -> code, or false when the book has none

local function nonEmpty(v)
    return (type(v) == "string" and v ~= "") and v or nil
end

-- "es-AR" -> "ES", "eng" -> "EN"
local function normalize(lang)
    local code = (lang:match("^(%a+)") or lang):upper()
    return ALIASES[code] or code
end

local function customLanguage(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings and DocSettings.findCustomMetadataFile) then return nil end
    local ok2, props = pcall(function()
        local path = DocSettings:findCustomMetadataFile(file)
        if not path then return nil end
        return DocSettings.openSettingsFile(path):readSetting("custom_props")
    end)
    if ok2 and type(props) == "table" then return nonEmpty(props.language) end
    return nil
end

-- The book's language code, or nil when it has none. A book the cover browser
-- has not read yet is asked again next time.
function BookLang.of(file)
    local c = cache[file]
    if c ~= nil then return c or nil end
    local lang = customLanguage(file)
    local known = lang ~= nil
    if not lang then
        local ok_bim, bim = pcall(require, "bookinfomanager")
        if ok_bim and bim and bim.getBookInfo then
            local ok, info = pcall(bim.getBookInfo, bim, file, false)
            if ok and type(info) == "table" then
                known = true
                lang = nonEmpty(info.language)
            end
        end
    end
    local code = lang and normalize(lang) or nil
    if known then cache[file] = code or false end
    return code
end

-- The distinct languages of `files` (paths, or entries with a .file), sorted.
function BookLang.languages(files)
    local seen, list = {}, {}
    for _i, f in ipairs(files or {}) do
        local l = BookLang.of(type(f) == "table" and f.file or f)
        if l and not seen[l] then
            seen[l] = true
            list[#list + 1] = l
        end
    end
    table.sort(list)
    return list
end

-- Forget what was read, so edits made in the book information show up.
function BookLang.forget()
    cache = {}
end

return BookLang
