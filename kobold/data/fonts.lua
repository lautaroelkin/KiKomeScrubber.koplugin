-- kobold/data/fonts.lua — Kobold
-- The plugin's two fonts. Builds no widgets.
--
--   primary    most of the text: titles, names, rows, menus, buttons, tabs, chips,
--              the status bar.
--   secondary  the details: authors, book counts, section headings, notes,
--              hints, values on the right, counters, placeholders.
--
-- Each one is a font file chosen in Settings > Appearance > Fonts (stored as a path in the
-- "font_primary" / "font_secondary" settings). With nothing chosen, or when the
-- file can no longer be loaded, it is KOReader's own font ("cfont"), the one
-- the rest of KOReader uses, so by default the plugin looks like KOReader.
--
-- Every text of the plugin gets its face from KoboldWidgets.face (primary) or
-- KoboldWidgets.secondaryFace (secondary), which end up in KoboldFonts.face.

local Font        = require("ui/font")
local _           = require("kobold.i18n")
local KoboldPrefs = require("kobold.data.prefs")

local KoboldFonts = {}

local KEYS = { primary = "font_primary", secondary = "font_secondary" }
local SYSTEM_FONT = "cfont"

-- Font files that are not for text: symbol and emoji fonts.
local function hidden(path)
    local lower = path:lower()
    return lower:find("/nerdfonts/", 1, true) ~= nil
        or lower:find("symbols", 1, true) ~= nil
        or lower:find("emoji", 1, true) ~= nil
end

local function baseName(path)
    return path:match("([^/\\]+)$") or path
end

-- "NotoSerif-BoldItalic.ttf" -> "Noto Serif Bold Italic"
local function prettify(path)
    local s = baseName(path):gsub("%.%w+$", "")
    s = s:gsub("[-_]+", " ")
    s = s:gsub("(%l)(%u)", "%1 %2")
    return s
end

local function isTrue(v)
    return v == true or v == 1
end

---------------------------------------------------------------------------
-- What is chosen
---------------------------------------------------------------------------

-- The font file chosen for a role ("primary" or "secondary"), or nil when it
-- follows KOReader's font.
function KoboldFonts.chosen(role)
    local v = KoboldPrefs.get(KEYS[role])
    if type(v) == "string" and v ~= "" then return v end
    return nil
end

-- Saves the choice (nil goes back to KOReader's font).
function KoboldFonts.set(role, path)
    KoboldFonts.forgetFailures()
    KoboldPrefs.set(KEYS[role], path)
end

-- Both back to KOReader's font.
function KoboldFonts.reset()
    KoboldFonts.forgetFailures()
    KoboldPrefs.reset({ KEYS.primary, KEYS.secondary })
end

-- Changes whenever a choice does, so a screen can tell its fonts changed.
function KoboldFonts.signature()
    return (KoboldFonts.chosen("primary") or "") .. "|" .. (KoboldFonts.chosen("secondary") or "")
end

---------------------------------------------------------------------------
-- Faces
---------------------------------------------------------------------------

local resolved = {}  -- font path -> the name Font:getFace took for it
local failed   = {}  -- font paths that could not be loaded (not tried again)

function KoboldFonts.forgetFailures()
    for path in pairs(failed) do failed[path] = nil end
end

local function tryName(name, size)
    local ok, face = pcall(function() return Font:getFace(name, size) end)
    if ok and face then return face end
    return nil
end

-- KOReader's own font.
function KoboldFonts.systemFace(size)
    return Font:getFace(SYSTEM_FONT, size)
end

-- The face of a font file at `size`, or nil when it cannot be loaded. KOReader
-- finds fonts by file name in its font folders, so the name is tried first,
-- then the whole path.
function KoboldFonts.faceForPath(path, size)
    if type(path) ~= "string" or path == "" or failed[path] then return nil end
    local name = resolved[path]
    if name then return tryName(name, size) end
    for _i, candidate in ipairs({ baseName(path), path }) do
        local face = tryName(candidate, size)
        if face then
            resolved[path] = candidate
            return face
        end
    end
    failed[path] = true
    return nil
end

-- The face for a role. Never nil: when the chosen font is missing it is
-- KOReader's font.
function KoboldFonts.face(role, size)
    local path = KoboldFonts.chosen(role)
    if path then
        local face = KoboldFonts.faceForPath(path, size)
        if face then return face end
    end
    return KoboldFonts.systemFace(size)
end

---------------------------------------------------------------------------
-- The list of fonts to choose from
---------------------------------------------------------------------------

local function labelFor(FontList, path)
    local info = type(FontList.fontinfo) == "table" and FontList.fontinfo[path] or nil
    local first = type(info) == "table" and info[1] or nil
    local name = type(first) == "table" and first.name or nil
    if type(name) ~= "string" or name == "" then return prettify(path) end
    local lower = name:lower()
    if isTrue(first.bold) and not lower:find("bold", 1, true) then name = name .. " " .. _("Bold") end
    if isTrue(first.italic) and not lower:find("italic", 1, true) then name = name .. " " .. _("Italic") end
    return name
end

local list_cache = nil

-- Every font KOReader knows (its own folder and the user's fonts folder), as
-- { path = ..., label = ... }, sorted by name. Kept for the session.
function KoboldFonts.list()
    if list_cache then return list_cache end
    local out = {}
    local ok, FontList = pcall(require, "fontlist")
    if ok and type(FontList) == "table" then
        local ok_list, paths = pcall(function() return FontList:getFontList() end)
        if ok_list and type(paths) == "table" then
            local seen = {}
            for _i, path in ipairs(paths) do
                if type(path) == "string" and not seen[path] and not hidden(path) then
                    seen[path] = true
                    local ok_label, label = pcall(labelFor, FontList, path)
                    out[#out + 1] = { path = path, label = ok_label and label or prettify(path) }
                end
            end
        end
    end
    -- Two files with the same name: the file name tells them apart.
    local count = {}
    for _i, f in ipairs(out) do count[f.label] = (count[f.label] or 0) + 1 end
    for _i, f in ipairs(out) do
        if count[f.label] > 1 then f.label = f.label .. " (" .. prettify(f.path) .. ")" end
    end
    table.sort(out, function(a, b)
        local la, lb = a.label:lower(), b.label:lower()
        if la ~= lb then return la < lb end
        return a.path < b.path
    end)
    if #out > 0 then list_cache = out end
    return out
end

-- What Settings shows for a role: the font's name, or KOReader's font.
function KoboldFonts.name(role)
    local path = KoboldFonts.chosen(role)
    if not path then return _("KOReader font") end
    for _i, f in ipairs(KoboldFonts.list()) do
        if f.path == path then return f.label end
    end
    return prettify(path)
end

return KoboldFonts
