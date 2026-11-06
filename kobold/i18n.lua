-- kobold/i18n.lua — KiKome
-- Translations for the plugin. KOReader's own gettext only knows KOReader's
-- own texts, so KiKome reads its own files: locales/<language>.po inside the
-- plugin folder (the same way as the Page Scrubber plugin). Every file of the
-- plugin does
--
--     local _ = require("kobold.i18n")
--
-- instead of require("gettext"), and writes its texts in English as always:
-- _("Settings"). With no file for the language in use (English, or a language
-- that has no .po yet), or no translation for a text, the text comes out as
-- written (or, if KOReader itself has it translated, as KOReader has it).
--
-- The language is the one set in KOReader (Settings > Language). A file is
-- looked for by the full code first (pt_BR.po) and then by the first two
-- letters (pt.po). The language is checked on every call, so a change of
-- language is followed at once by the texts that are asked for again; those
-- kept in a variable when a file is loaded change when KOReader restarts.
--
-- To add a language: copy locales/es.po to locales/<code>.po, change the
-- "Language:" line and translate each msgstr. Nothing else has to change.

local gettext = require("gettext")   -- KOReader's, used as the last resort

-- The plugin folder (…/KiKomeScrubber.koplugin/), from this file's own path.
local source = debug.getinfo(1, "S").source or ""
local PLUGIN_DIR = source:match("^@?(.*)[/\\]kobold[/\\]i18n%.lua$")
local LOCALES_DIR = PLUGIN_DIR and (PLUGIN_DIR .. "/locales/") or nil

local dict = {}          -- msgid -> msgstr, for `loaded_lang`
local loaded_lang = nil  -- the language `dict` was read for ("" = none)

-- The language KOReader is using: its setting, or what its own gettext has
-- (the system language when nothing was chosen).
local function currentLang()
    local lang
    if G_reader_settings then
        local ok, value = pcall(function() return G_reader_settings:readSetting("language") end)
        if ok and type(value) == "string" and value ~= "" then lang = value end
    end
    if not lang and type(gettext.current_lang) == "string" then lang = gettext.current_lang end
    if not lang or lang == "" or lang == "C" or lang == "POSIX" then return "en" end
    return (lang:gsub("%..*$", ""))   -- "es_AR.UTF-8" -> "es_AR"
end

-- The text of one quoted .po line: the quotes off, escapes undone.
local ESCAPES = { n = "\n", t = "\t", r = "\r", ['"'] = '"', ["\\"] = "\\" }
local function unquote(s)
    return (s:gsub("\\(.)", function(c) return ESCAPES[c] or ("\\" .. c) end))
end

-- Reads a .po file into a table. Handles texts split over several lines,
-- escapes, and skips fuzzy entries and empty translations.
local function readPo(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local out = {}
    local msgid, msgstr, field, fuzzy, skip_next_fuzzy = nil, nil, nil, false, false
    local function flush()
        if msgid and msgid ~= "" and msgstr and msgstr ~= "" and not fuzzy then
            out[msgid] = msgstr
        end
        msgid, msgstr, field, fuzzy = nil, nil, nil, skip_next_fuzzy
        skip_next_fuzzy = false
    end
    for line in f:lines() do
        line = line:gsub("\r$", "")
        if line:match("^#,.*fuzzy") then
            -- the flag belongs to the entry that comes next
            if msgid or msgstr then flush() end
            fuzzy = true
        elseif line:match("^msgctxt") then
            -- contexts are not used
        elseif line:match("^msgid%s") then
            if msgstr ~= nil then flush() end
            msgid = unquote(line:match('^msgid%s+"(.*)"%s*$') or "")
            field = "msgid"
        elseif line:match("^msgstr%s") then
            msgstr = unquote(line:match('^msgstr%s+"(.*)"%s*$') or "")
            field = "msgstr"
        else
            local cont = line:match('^%s*"(.*)"%s*$')
            if cont and field == "msgid" then
                msgid = (msgid or "") .. unquote(cont)
            elseif cont and field == "msgstr" then
                msgstr = (msgstr or "") .. unquote(cont)
            end
        end
    end
    if msgstr ~= nil then flush() end
    f:close()
    return out
end

-- Loads the file of `lang` into `dict` (nothing for English).
local function load(lang)
    loaded_lang = lang
    dict = {}
    if lang == "en" or not LOCALES_DIR then return end
    local tried = { lang }
    local short = lang:match("^(%a+)[_%-]")
    if short then tried[#tried + 1] = short end
    for _i, code in ipairs(tried) do
        local po = readPo(LOCALES_DIR .. code .. ".po")
        if po then
            dict = po
            return
        end
    end
end

local function translate(text)
    if type(text) ~= "string" then return text end
    local lang = currentLang()
    if lang ~= loaded_lang then load(lang) end
    local found = dict[text]
    if found then return found end
    return gettext(text)
end

-- Callable, and with the rest of what KOReader's gettext offers for the few
-- places that need plurals or contexts.
local M = setmetatable({}, {
    __call = function(_self, text) return translate(text) end,
    __index = function(_self, key) return gettext[key] end,
})

M.translate = translate

return M
