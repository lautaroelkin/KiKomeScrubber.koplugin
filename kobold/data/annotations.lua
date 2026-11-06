-- kobold/data/annotations.lua — KiKome
-- A book's annotations (bookmarks, highlights and notes) for the annotations
-- list of Book Details, without opening the book.
--
-- Where they come from: KOReader keeps them in the book's sidecar
-- (metadata.<ext>.lua, key "annotations"). When the book is open (parked under
-- KiKome, see park.lua) the reader's own list is used instead, because the
-- sidecar is only written when the book closes.
--
-- How they are told apart is the way Page Scrubber does it (scrubber_ui.lua,
-- _extractAnnotations):
--   * highlight: has a drawer, or a pos0 + pos1 selection, or highlight = true.
--     Its style comes from the drawer: lighten = normal, invert, underscore =
--     underline, strikeout = strikethrough. Its colour is item.color (gray
--     when the item has none); "invert" has no colour.
--   * bookmark: anything else (a page marked with the dog-ear).
--   * note: any item with a non-empty note (a highlight or a bookmark).
-- An item that is a highlight with a note is one entry; it shows under the
-- Highlights filter and under the Notes filter.
--
--   Annotations.load(file)            list of entries, in book order
--   Annotations.filter(list, f)       f = { kind = "bookmark"|"highlight"|"note"|nil, style = "normal"|... }
--   Annotations.counts(list)          { all, bookmark, highlight, note, styles = { normal = n, ... } }
--   Annotations.formatDate(raw)       "January 5, 2026 · 21:15"
--   Annotations.toMarkdown(file, title)  the notes as Markdown (Export document), text and count
--   Annotations.colorName(key)        "Yellow"
--   Annotations.resolveColor(key)     the Blitbuffer colour KOReader paints that highlight with
--
-- An entry:
--   { index, item, kind = "bookmark"|"highlight", style, color, text, note,
--     date, chapter, page (number or nil) }

local Blitbuffer = require("ffi/blitbuffer")
local _          = require("kobold.i18n")

local Annotations = {}

local function nonEmpty(s)
    if type(s) ~= "string" then return nil end
    s = s:match("^%s*(.-)%s*$")
    return s ~= "" and s or nil
end

-- ── Reading ────────────────────────────────────────────────────────────────

-- The reader's own list, when the book is open right now.
local function liveAnnotations(file)
    local RU = package.loaded["apps/reader/readerui"]
    local rui = RU and RU.instance
    if rui and rui.document and rui.document.file == file
        and rui.annotation and type(rui.annotation.annotations) == "table" then
        return rui.annotation.annotations, rui
    end
    return nil
end

-- The list saved in the sidecar.
local function sidecarAnnotations(file)
    local ok, DocSettings = pcall(require, "docsettings")
    if not (ok and DocSettings) then return nil end
    if DocSettings.hasSidecarFile then
        local ok_has, has = pcall(function() return DocSettings:hasSidecarFile(file) end)
        if ok_has and not has then return nil end
    end
    local ok_open, ds = pcall(function() return DocSettings:open(file) end)
    if not (ok_open and ds) then return nil end
    local list = ds:readSetting("annotations")
    pcall(function() ds:close() end)
    return type(list) == "table" and list or nil
end

-- The page of an annotation. In an open reflowable book the xpointer is the
-- truth (the saved pageno goes stale when the layout changes: font, margins,
-- screen DPI); otherwise the pageno KOReader saved with it, or the page itself
-- (PDF and other fixed layouts).
local function pageOf(item, rui)
    local doc = rui and rui.document
    if doc and type(doc.getPageFromXPointer) == "function" then
        for _i, xp in ipairs({ item.page, item.pos0 }) do
            if type(xp) == "string" and not tonumber(xp) then
                local ok, p = pcall(function() return doc:getPageFromXPointer(xp) end)
                if ok and type(p) == "number" then return p end
            end
        end
    end
    local n = tonumber(item.pageno)
    if n then return math.floor(n) end
    n = tonumber(item.page)
    if n then return math.floor(n) end
    return nil
end

local function styleOf(drawer)
    if drawer == "invert" then return "invert"
    elseif drawer == "underscore" then return "underline"
    elseif drawer == "strikeout" then return "strikethrough"
    end
    return "normal"   -- lighten, or none
end

function Annotations.load(file)
    local list, rui = liveAnnotations(file)
    if not list then list = sidecarAnnotations(file) end
    local out = {}
    for idx, item in ipairs(list or {}) do
        if type(item) == "table" then
            local is_hl = item.drawer ~= nil
                or (item.pos0 ~= nil and item.pos1 ~= nil)
                or item.highlight == true
            local note = nonEmpty(item.note)
            local entry = {
                index = idx, item = item,
                kind = is_hl and "highlight" or "bookmark",
                note = note,
                date = item.datetime or item.time or item.date or item.timestamp,
                chapter = nonEmpty(item.chapter),
                page = pageOf(item, rui),
            }
            if is_hl then
                entry.style = styleOf(item.drawer)
                -- "invert" takes no colour
                if item.drawer ~= "invert" then
                    entry.color = nonEmpty(item.color) or "gray"
                end
                entry.text = nonEmpty(item.text)
            end
            -- (a bookmark's own text is KOReader's automatic one, not a quote: it is not kept)
            out[#out + 1] = entry
        end
    end
    return out
end

-- ── Export ─────────────────────────────────────────────────────────────────

-- The notes of a book as Markdown, in the format of Page Scrubber's "Export
-- notes of this document" (scrubber_settings.lua, exportNotes): the title, a
-- line with the pages that only have a bookmark, then one section for each
-- page that has a highlight or a note: the quote with a mark for its style
-- (✪ normal, ◧ invert, ﹏ underline, ✖ strikethrough) and the note as a list
-- item. Returns the text and how many highlights and notes it holds, or nil
-- when there is nothing to export.
local QUOTE = {
    invert        = function(t) return "> ◧ *" .. t .. "*\n" end,
    underline     = function(t) return "> ﹏ **" .. t .. "**\n" end,
    strikethrough = function(t) return "> ✖ ~~" .. t .. "~~\n" end,
}

function Annotations.toMarkdown(file, title)
    local list = Annotations.load(file)
    local pages, order, bookmarks = {}, {}, {}
    local count = 0
    for _i, e in ipairs(list) do
        if e.text or e.note then
            local key = e.page or 0   -- no page known: its own section at the end
            if not pages[key] then
                pages[key] = {}
                order[#order + 1] = key
            end
            pages[key][#pages[key] + 1] = e
            count = count + 1
        elseif e.page then
            bookmarks[e.page] = true
        end
    end
    local bm = {}
    for p in pairs(bookmarks) do bm[#bm + 1] = p end
    table.sort(bm)
    if count == 0 and #bm == 0 then return nil end
    table.sort(order, function(a, b)
        if a == 0 then return false end
        if b == 0 then return true end
        return a < b
    end)

    local out = { "# " .. (title or "Book") .. "\n\n" }
    if #bm > 0 then
        local names = {}
        for _i, p in ipairs(bm) do names[#names + 1] = tostring(p) end
        out[#out + 1] = "⚑ : " .. table.concat(names, ", ") .. "\n\n"
    end
    out[#out + 1] = "---\n\n"
    for _i, p in ipairs(order) do
        out[#out + 1] = "## " .. (p == 0 and "?" or tostring(p)) .. "\n"
        for _j, e in ipairs(pages[p]) do
            if e.text then
                local text = (e.text:gsub("\n", " "))
                out[#out + 1] = (QUOTE[e.style] or function(t) return "> ✪ " .. t .. "\n" end)(text)
            end
            if e.note then out[#out + 1] = "- " .. (e.note:gsub("\n", " ")) .. "\n" end
            out[#out + 1] = "\n"
        end
        out[#out + 1] = "---\n\n"
    end
    return table.concat(out), count
end

-- ── Filtering ──────────────────────────────────────────────────────────────

function Annotations.filter(list, f)
    f = f or {}
    if not f.kind and not f.style then return list end
    local out = {}
    for _i, e in ipairs(list) do
        local ok = true
        if f.kind == "bookmark" then ok = (e.kind == "bookmark")
        elseif f.kind == "highlight" then ok = (e.kind == "highlight")
        elseif f.kind == "note" then ok = (e.note ~= nil)
        end
        -- a style only exists on highlights
        if ok and f.style then ok = (e.style == f.style) end
        if ok then out[#out + 1] = e end
    end
    return out
end

function Annotations.counts(list)
    local c = { all = #list, bookmark = 0, highlight = 0, note = 0, styles = {} }
    for _i, e in ipairs(list) do
        if e.kind == "bookmark" then c.bookmark = c.bookmark + 1 else c.highlight = c.highlight + 1 end
        if e.note then c.note = c.note + 1 end
        if e.style then c.styles[e.style] = (c.styles[e.style] or 0) + 1 end
    end
    return c
end

-- ── Dates ──────────────────────────────────────────────────────────────────

local MONTHS
-- "2026-01-05 21:15:03" (or a timestamp) as "January 5, 2026 · 21:15".
function Annotations.formatDate(raw)
    if raw == nil or raw == "" then return nil end
    if not MONTHS then
        MONTHS = { _("January"), _("February"), _("March"), _("April"), _("May"), _("June"),
                   _("July"), _("August"), _("September"), _("October"), _("November"), _("December") }
    end
    local y, m, d, hh, mm
    if type(raw) == "number" then
        local t = os.date("*t", raw)
        if t then y, m, d, hh, mm = t.year, t.month, t.day, t.hour, t.min end
    else
        local s = tostring(raw)
        y, m, d = s:match("(%d%d%d%d)[%-%/%.](%d%d)[%-%/%.](%d%d)")
        if not y then
            d, m, y = s:match("(%d%d)[%-%/%.](%d%d)[%-%/%.](%d%d%d%d)")
        end
        hh, mm = s:match("[%sT_](%d%d):(%d%d)")
    end
    y, m, d = tonumber(y), tonumber(m), tonumber(d)
    if not (y and m and d and MONTHS[m]) then return tostring(raw) end
    local out = string.format("%s %d, %d", MONTHS[m], d, y)
    if hh and mm then out = out .. string.format(" · %02d:%02d", tonumber(hh), tonumber(mm)) end
    return out
end

-- ── Colours ────────────────────────────────────────────────────────────────

-- The same hues KOReader uses for its highlight colours (in case the
-- Blitbuffer table is missing).
local COLOR_HEX = {
    red = "#FF3300", orange = "#FF8800", yellow = "#FFFF33", green = "#00AA66",
    olive = "#88FF77", cyan = "#00FFEE", blue = "#0066FF", purple = "#EE00FF",
    gray = "#808080",
}

local COLOR_NAMES = {
    red = _("Red"), orange = _("Orange"), yellow = _("Yellow"), green = _("Green"),
    olive = _("Olive"), cyan = _("Cyan"), blue = _("Blue"), purple = _("Purple"),
    gray = _("Gray"),
}

function Annotations.colorName(key)
    if type(key) ~= "string" or key == "" then return nil end
    return COLOR_NAMES[key] or (key:sub(1, 1):upper() .. key:sub(2))
end

local color_cache = {}

-- The colour KOReader paints highlight `name` with. On a black and white
-- screen it still returns a colour: the caller paints it with the screen's own
-- blend (see paintRect in book_details.lua), which turns it into a grey.
function Annotations.resolveColor(name)
    name = name or "yellow"
    if color_cache[name] then return color_cache[name] end
    local c
    local code = Blitbuffer.HIGHLIGHT_COLORS and Blitbuffer.HIGHLIGHT_COLORS[name]
    if not code and COLOR_HEX[name] then code = COLOR_HEX[name] end
    if code and Blitbuffer.colorFromString then
        local ok, col = pcall(Blitbuffer.colorFromString, code)
        if ok and col then c = col end
    end
    -- gray is the plain grey readerhighlight.lua uses
    if not c or name == "gray" then
        if Blitbuffer.gray then
            local ok, col = pcall(Blitbuffer.gray, 0.2)
            if ok and col then c = col end
        end
    end
    c = c or Blitbuffer.COLOR_GRAY
    color_cache[name] = c
    return c
end

return Annotations
