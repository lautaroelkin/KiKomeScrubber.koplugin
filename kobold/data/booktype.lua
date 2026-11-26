-- kobold/data/booktype.lua — Kobold
-- The kind of a file, for the Type filter of the Sort & Filter sheet on Home and
-- Library: "book" (EPUB, MOBI...), "comic" (graphic novels: CBZ...) and
-- "document" (PDF, Markdown, Word...). It goes by the file's name alone, so it
-- costs nothing per book. A "Name.fb2.zip" counts as the format inside; a plain
-- "Name.zip" counts as a graphic novel (a zip of images, like a CBZ).
-- Builds no widgets.

local _ = require("kobold.i18n")

local BookType = {}

-- Type ids in menu order.
BookType.TYPES = { "book", "comic", "document" }

-- extension (lowercase) -> type id. An extension that is not here counts as
-- a book, so a format added to the scan later is never left out of the filter.
local BY_EXT = {
    -- books
    epub = "book", kepub = "book", mobi = "book", azw = "book", azw3 = "book",
    fb2 = "book", fb3 = "book", prc = "book", pdb = "book", chm = "book",
    -- graphic novels
    cbz = "comic", cbr = "comic", cbt = "comic", cb7 = "comic",
    -- documents
    pdf = "document", djvu = "document", djv = "document", xps = "document",
    oxps = "document", md = "document", markdown = "document", txt = "document",
    rtf = "document", doc = "document", docx = "document", odt = "document",
    htm = "document", html = "document", xhtml = "document",
}

-- The type id of a file (a path or a file name).
function BookType.of(file)
    if type(file) ~= "string" then return "book" end
    local ext = file:match("%.([^%./]+)$")
    ext = ext and ext:lower()
    if ext == "zip" then
        -- "Name.fb2.zip": the format inside it; a plain "Name.zip": a zip of images
        local inner = file:match("%.([^%./]+)%.[^%./]+$")
        return (inner and BY_EXT[inner:lower()]) or "comic"
    end
    return (ext and BY_EXT[ext]) or "book"
end

-- The label of a type id, in the language in use (asked when it is shown).
function BookType.label(id)
    if id == "comic" then return _("Graphic novels") end
    if id == "document" then return _("Documents") end
    return _("Books")
end

-- The types that `files` (paths, or entries with a .file) have at least one
-- book of, in menu order.
function BookType.available(files)
    local seen, list = {}, {}
    for _i, f in ipairs(files or {}) do
        seen[BookType.of(type(f) == "table" and f.file or f)] = true
    end
    for _i, id in ipairs(BookType.TYPES) do
        if seen[id] then list[#list + 1] = id end
    end
    return list
end

return BookType
