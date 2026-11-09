-- kobold/data/epub_writer.lua — Kobold
-- Writes a book's metadata into the EPUB file itself (its OPF), the way
-- Calibre does, so the data goes wherever the file goes. No UI.
--
-- Adapted from rebind.koplugin by Rameez Khan (MIT License, copyright (c)
-- 2026 Rameez Khan): the same way of editing the OPF and of repacking the
-- zip, cut down to the fields KiKome edits, with a backup that is copied in
-- pieces and with the refinements of replaced authors taken out. The XML
-- parser is SLAXML (kobold/vendor, MIT, Gavin Kistner).
--
--   EpubWriter.isEpub(path)                  true for a .epub file
--   EpubWriter.backupPath(path)              where the copy of the old file is kept
--   EpubWriter.readInfo(path)                -> { publisher, year, isbn } the book says (each may be nil), or nil
--   EpubWriter.rewrite(path, changes, opts)  -> true, backup_path (nil with no backup)   |   false, "why"
--                                            opts.backup = false: no copy of the old file is kept
--
-- `changes` holds only what is to be written (a field that is absent is not
-- touched):
--   title        string
--   authors      { "name", ... }     replaces every author
--   subjects     { "word", ... }     replaces every keyword (dc:subject)
--   description  string
--   language     string
--   publisher    string              (dc:publisher)
--   year         "2019"              (dc:date: a date that already has this year is left as it is)
--   isbn         "9788420412146"     (the dc:identifier that holds an ISBN, or a new one: urn:isbn:...)
--   series       string              with series_index (number or text, optional)
--   remove_series true               takes the series out
--   cover_file   "/path/cover.jpg"   a picture (jpg or png) that becomes the book's cover
--
-- The book is repacked into a temporary file first, that file is checked
-- (the mimetype comes first, the OPF reads), the old file is copied beside it
-- (unless no backup was asked for) and only then is the temporary file put in
-- its place. Any failure leaves the book as it was.

local _ = require("kobold.i18n")
local Archiver = require("ffi/archiver")
local SLAXML = require("kobold.vendor.slaxdom")

local DC_NS = "http://purl.org/dc/elements/1.1/"

local EpubWriter = {}

function EpubWriter.isEpub(path)
    return type(path) == "string" and path:lower():match("%.epub$") ~= nil
end

function EpubWriter.backupPath(path)
    return path .. ".kikome.bak"
end

-- ── The OPF as a tree ───────────────────────────────────────────────────────

local function is_element(node)
    return type(node) == "table" and node.type == "element"
end

local function child_elements(el)
    local out = {}
    for _i, kid in ipairs(el.kids) do
        if is_element(kid) then out[#out + 1] = kid end
    end
    return out
end

local function is_dc(el, localname)
    return is_element(el) and el.name == localname and (el.nsURI == DC_NS or el.nsPrefix == "dc")
end

local function is_meta(el)
    return is_element(el) and el.name == "meta"
end

local function attr_get(el, name)
    return el.attr and el.attr[name]
end

local function attr_set(el, name, value)
    el.attr = el.attr or {}
    el.attr[name] = value
    for _i, a in ipairs(el.attr) do
        if a.name == name and not a.nsPrefix then
            a.value = value
            return
        end
    end
    table.insert(el.attr, { type = "attribute", name = name, value = value })
end

local function get_text(el)
    local parts = {}
    for _i, kid in ipairs(el.kids) do
        if kid.type == "text" then parts[#parts + 1] = kid.value end
    end
    return table.concat(parts)
end

local function set_text(el, value)
    el.kids = { { type = "text", name = "#text", value = value } }
end

local function new_element(name, nsPrefix, attrs, text)
    local el = { type = "element", name = name, nsPrefix = nsPrefix, kids = {}, attr = {} }
    for _i, a in ipairs(attrs or {}) do
        el.attr[a[1]] = a[2]
        table.insert(el.attr, { type = "attribute", name = a[1], value = a[2] })
    end
    if text ~= nil then
        el.kids = { { type = "text", name = "#text", value = text } }
    end
    return el
end

local function append_child(metadata, el)
    table.insert(metadata.kids, { type = "text", name = "#text", value = "\n    " })
    table.insert(metadata.kids, el)
end

local function find_metadata(pkg)
    for _i, el in ipairs(child_elements(pkg)) do
        if el.name == "metadata" then return el end
    end
    return nil
end

local function detect_dc_prefix(metadata)
    for _i, el in ipairs(child_elements(metadata)) do
        if el.nsURI == DC_NS and el.nsPrefix then return el.nsPrefix end
    end
    return "dc"
end

local function fmt_index(v)
    if v == nil or v == "" then return nil end
    local n = tonumber(v)
    if n then
        if n == math.floor(n) then return tostring(math.floor(n)) end
        return tostring(n)
    end
    return tostring(v)
end

-- Calibre writes the index as a float: 3.0, 2.5.
local function calibre_index(v)
    if v == nil or v == "" then return nil end
    local n = tonumber(v)
    if n then
        if n == math.floor(n) then return string.format("%.1f", n) end
        return tostring(n)
    end
    return tostring(v)
end

local function find_meta(metadata, predicate)
    for _i, el in ipairs(child_elements(metadata)) do
        if is_meta(el) and predicate(el) then return el end
    end
    return nil
end

local function remove_meta(metadata, predicate)
    local kept = {}
    for _i, kid in ipairs(metadata.kids) do
        if not (is_meta(kid) and predicate(kid)) then kept[#kept + 1] = kid end
    end
    metadata.kids = kept
end

local function remove_dc(metadata, localname)
    local kept = {}
    for _i, kid in ipairs(metadata.kids) do
        if not is_dc(kid, localname) then kept[#kept + 1] = kid end
    end
    metadata.kids = kept
end

local function dc_texts(metadata, localname)
    local out = {}
    for _i, el in ipairs(child_elements(metadata)) do
        if is_dc(el, localname) then out[#out + 1] = get_text(el) end
    end
    return out
end

local function same_list(a, b)
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

-- An ISBN-10 or ISBN-13 in an identifier ("urn:isbn:978-84-...", "isbn 8420..."),
-- upper case and with no hyphens, or nil.
local function isbn_of(text)
    local plain = tostring(text):lower()
    plain = plain:gsub("^%s*urn:isbn:", "")
    plain = plain:gsub("[%s%-]", "")
    plain = plain:gsub("^isbn:?", "")
    if plain:match("^97[89]%d%d%d%d%d%d%d%d%d%d$") or plain:match("^%d%d%d%d%d%d%d%d%d[%dx]$") then
        return plain:upper()
    end
    return nil
end

-- The identifier that already holds an ISBN gets the new one (keeping its
-- "urn:isbn:" when it had it); a book with none gets a new identifier.
local function set_isbn(metadata, prefix, isbn)
    for _i, el in ipairs(child_elements(metadata)) do
        if is_dc(el, "identifier") then
            local text = get_text(el)
            local own = isbn_of(text)
            if own then
                if own ~= isbn then
                    local urn = text:lower():match("^%s*urn:isbn:") and "urn:isbn:" or ""
                    set_text(el, urn .. isbn)
                end
                return
            end
        end
    end
    append_child(metadata, new_element("identifier", prefix, nil, "urn:isbn:" .. isbn))
end

-- Only the year changes: a date that already says this year keeps its month and day.
local function set_year(metadata, prefix, year)
    for _i, el in ipairs(child_elements(metadata)) do
        if is_dc(el, "date") then
            if get_text(el):match("^%s*(%d%d%d%d)") ~= year then set_text(el, year) end
            return
        end
    end
    append_child(metadata, new_element("date", prefix, nil, year))
end

local function set_dc_text(metadata, localname, prefix, value)
    for _i, el in ipairs(child_elements(metadata)) do
        if is_dc(el, localname) then
            set_text(el, value)
            return
        end
    end
    append_child(metadata, new_element(localname, prefix, nil, value))
end

-- Every element `localname` goes, and so do the <meta refines="#id"> that
-- described them (an author's role or file-as), which would point at nothing.
local function replace_dc_list(metadata, localname, prefix, values)
    if same_list(dc_texts(metadata, localname), values) then return end
    local refined = {}
    for _i, el in ipairs(child_elements(metadata)) do
        if is_dc(el, localname) then
            local id = attr_get(el, "id")
            if id and id ~= "" then refined["#" .. id] = true end
        end
    end
    remove_dc(metadata, localname)
    if next(refined) then
        remove_meta(metadata, function(el)
            local r = attr_get(el, "refines")
            return r ~= nil and refined[r] == true
        end)
    end
    for _i, value in ipairs(values) do
        append_child(metadata, new_element(localname, prefix, nil, value))
    end
end

-- ── Series: Calibre's way and EPUB 3's, both ────────────────────────────────

local function set_calibre_series(metadata, series, series_index)
    remove_meta(metadata, function(el)
        local name = attr_get(el, "name")
        return name == "calibre:series" or name == "calibre:series_index"
    end)
    append_child(metadata, new_element("meta", metadata.nsPrefix, {
        { "name", "calibre:series" },
        { "content", series },
    }))
    local idx = calibre_index(series_index)
    if idx then
        append_child(metadata, new_element("meta", metadata.nsPrefix, {
            { "name", "calibre:series_index" },
            { "content", idx },
        }))
    end
end

-- The collection that is a series (a book can also belong to collections of
-- another type, which are left alone).
local function find_series_collection(metadata)
    for _i, el in ipairs(child_elements(metadata)) do
        if is_meta(el) and attr_get(el, "property") == "belongs-to-collection" then
            local id = attr_get(el, "id")
            if id and id ~= "" then
                local kind = find_meta(metadata, function(m)
                    return attr_get(m, "refines") == "#" .. id
                        and attr_get(m, "property") == "collection-type"
                end)
                if kind and get_text(kind):match("^%s*series%s*$") then return el end
            end
        end
    end
    return nil
end

local function set_epub3_series(metadata, series, series_index)
    local coll_el = find_series_collection(metadata)
    local coll_id
    if coll_el then
        coll_id = attr_get(coll_el, "id")
        set_text(coll_el, series)
    else
        coll_id = "kikome-series"
        append_child(metadata, new_element("meta", metadata.nsPrefix, {
            { "property", "belongs-to-collection" },
            { "id", coll_id },
        }, series))
    end

    local refines = "#" .. coll_id
    local type_el = find_meta(metadata, function(el)
        return attr_get(el, "refines") == refines and attr_get(el, "property") == "collection-type"
    end)
    if type_el then
        set_text(type_el, "series")
    else
        append_child(metadata, new_element("meta", metadata.nsPrefix, {
            { "refines", refines },
            { "property", "collection-type" },
        }, "series"))
    end

    local idx = fmt_index(series_index)
    if idx then
        local pos_el = find_meta(metadata, function(el)
            return attr_get(el, "refines") == refines and attr_get(el, "property") == "group-position"
        end)
        if pos_el then
            set_text(pos_el, idx)
        else
            append_child(metadata, new_element("meta", metadata.nsPrefix, {
                { "refines", refines },
                { "property", "group-position" },
            }, idx))
        end
    end
end

-- Takes the series out: Calibre's two metas and EPUB 3's series collection
-- (with everything that refines it).
local function remove_series(metadata)
    remove_meta(metadata, function(el)
        local name = attr_get(el, "name")
        return name == "calibre:series" or name == "calibre:series_index"
    end)
    local guard = 0
    local coll = find_series_collection(metadata)
    while coll and guard < 10 do
        guard = guard + 1
        local id = attr_get(coll, "id")
        if id and id ~= "" then
            remove_meta(metadata, function(el)
                return attr_get(el, "refines") == "#" .. id
            end)
        end
        remove_meta(metadata, function(el) return el == coll end)
        coll = find_series_collection(metadata)
    end
end

-- ── Reading and editing the OPF ─────────────────────────────────────────────

local function opf_path_from_container(container)
    return container:match('full%-path%s*=%s*"([^"]+)"')
        or container:match("full%-path%s*=%s*'([^']+)'")
end

-- ── The cover ───────────────────────────────────────────────────────────────

local function has_token(value, token)
    if type(value) ~= "string" then return false end
    for word in value:gmatch("%S+") do
        if word == token then return true end
    end
    return false
end

-- The manifest item that is the cover picture of the OPF (EPUB 3's
-- properties="cover-image", else EPUB 2's <meta name="cover" content="id">,
-- else an image item whose id says "cover"), with the manifest itself.
local function find_cover_item(doc, metadata)
    local pkg = doc.root
    local manifest
    for _i, el in ipairs(child_elements(pkg)) do
        if el.name == "manifest" then manifest = el break end
    end
    if not manifest then return nil end
    local items = {}
    for _i, el in ipairs(child_elements(manifest)) do
        if el.name == "item" then items[#items + 1] = el end
    end
    for _i, it in ipairs(items) do
        if has_token(attr_get(it, "properties"), "cover-image") then return it, manifest end
    end
    local meta = find_meta(metadata, function(m) return attr_get(m, "name") == "cover" end)
    local wanted = meta and attr_get(meta, "content")
    if wanted then
        for _i, it in ipairs(items) do
            if attr_get(it, "id") == wanted then
                local mt = attr_get(it, "media-type") or ""
                if mt:find("^image/") then return it, manifest end
            end
        end
    end
    for _i, it in ipairs(items) do
        local id = (attr_get(it, "id") or ""):lower()
        local mt = attr_get(it, "media-type") or ""
        if mt:find("^image/") and (id == "cover" or id == "cover-image" or id == "coverimage") then
            return it, manifest
        end
    end
    return nil, manifest
end

local function url_decode(s)
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- "OEBPS/content.opf" + "Images/cover.jpg" -> "OEBPS/Images/cover.jpg"
local function join_zip_path(opf_path, href)
    href = url_decode((href:gsub("#.*$", "")))
    local dir = opf_path:match("^(.*)/[^/]*$") or ""
    local parts = {}
    for seg in ((dir ~= "" and (dir .. "/") or "") .. href):gmatch("[^/]+") do
        if seg == ".." then parts[#parts] = nil
        elseif seg ~= "." then parts[#parts + 1] = seg end
    end
    return table.concat(parts, "/")
end

local function cover_kind(bytes)
    if type(bytes) ~= "string" then return nil end
    if bytes:sub(1, 3) == "\255\216\255" then return "jpg", "image/jpeg" end
    if bytes:sub(1, 4) == "\137PNG" then return "png", "image/png" end
    return nil
end

local function parse_metadata(opf_xml)
    local ok, doc = pcall(function() return SLAXML:dom(opf_xml) end)
    if not ok or not doc or not doc.root then
        return nil, nil, _("Could not parse the OPF.")
    end
    local metadata = find_metadata(doc.root)
    if not metadata then
        return nil, nil, "The OPF has no <metadata>."
    end
    return doc, metadata
end

local function open_reader(path)
    local reader = Archiver.Reader:new()
    if not reader:open(path) then return nil end
    return reader
end

local function extract_named(path, names)
    local reader = open_reader(path)
    if not reader then return nil, _("Could not open the EPUB.") end
    local out = {}
    for entry in reader:iterate() do
        if names[entry.path] and out[entry.path] == nil then
            out[entry.path] = reader:extractToMemory(entry.path)
        end
    end
    reader:close()
    return out
end

local function edit_opf(opf_xml, changes, cover_plan)
    local doc, metadata, err = parse_metadata(opf_xml)
    if not metadata then return nil, err end
    local prefix = detect_dc_prefix(metadata)

    if cover_plan then
        if cover_plan.item_id then
            -- the book's own cover item keeps its place and name: only the type may change
            local it = nil
            local _, manifest = find_cover_item(doc, metadata)
            if manifest then
                for _i, el in ipairs(child_elements(manifest)) do
                    if el.name == "item" and attr_get(el, "id") == cover_plan.item_id then it = el end
                end
            end
            if it and cover_plan.media_type then attr_set(it, "media-type", cover_plan.media_type) end
        elseif cover_plan.new_href then
            -- the book had no cover: one is added
            local _, manifest = find_cover_item(doc, metadata)
            if manifest then
                append_child(manifest, new_element("item", manifest.nsPrefix, {
                    { "id", "kikome-cover" },
                    { "href", cover_plan.new_href },
                    { "media-type", cover_plan.media_type },
                    { "properties", "cover-image" },
                }))
                remove_meta(metadata, function(m) return attr_get(m, "name") == "cover" end)
                append_child(metadata, new_element("meta", metadata.nsPrefix, {
                    { "name", "cover" },
                    { "content", "kikome-cover" },
                }))
            end
        end
    end

    if changes.title ~= nil and changes.title ~= "" then
        set_dc_text(metadata, "title", prefix, changes.title)
    end
    if changes.authors ~= nil and #changes.authors > 0 then
        replace_dc_list(metadata, "creator", prefix, changes.authors)
    end
    if changes.subjects ~= nil and #changes.subjects > 0 then
        replace_dc_list(metadata, "subject", prefix, changes.subjects)
    end
    if changes.description ~= nil and changes.description ~= "" then
        set_dc_text(metadata, "description", prefix, changes.description)
    end
    if changes.language ~= nil and changes.language ~= "" then
        set_dc_text(metadata, "language", prefix, changes.language)
    end
    if changes.publisher ~= nil and changes.publisher ~= "" then
        set_dc_text(metadata, "publisher", prefix, changes.publisher)
    end
    if changes.year ~= nil and changes.year ~= "" then
        set_year(metadata, prefix, changes.year)
    end
    if changes.isbn ~= nil and changes.isbn ~= "" then
        set_isbn(metadata, prefix, changes.isbn)
    end
    if changes.remove_series then
        remove_series(metadata)
    elseif changes.series ~= nil and changes.series ~= "" then
        set_calibre_series(metadata, changes.series, changes.series_index)
        set_epub3_series(metadata, changes.series, changes.series_index)
    end

    local ok, out = pcall(function() return SLAXML:xml(doc) end)
    if not ok or not out then
        return nil, _("Could not write the edited OPF.")
    end
    return out
end

-- What the book itself says about its publisher, year and ISBN (they are not
-- among the properties KOReader reads). nil when it cannot be read.
function EpubWriter.readInfo(path)
    if not EpubWriter.isEpub(path) then return nil end
    local got = extract_named(path, { ["META-INF/container.xml"] = true })
    local container = got and got["META-INF/container.xml"]
    local opf_path = container and opf_path_from_container(container)
    if not opf_path then return nil end
    local only = extract_named(path, { [opf_path] = true })
    local opf_text = only and only[opf_path]
    if not opf_text then return nil end
    local doc, metadata = parse_metadata(opf_text)
    if not doc then return nil end
    local info = {}
    local publisher = dc_texts(metadata, "publisher")[1]
    if publisher then
        publisher = publisher:match("^%s*(.-)%s*$")
        if publisher ~= "" then info.publisher = publisher end
    end
    local date = dc_texts(metadata, "date")[1]
    if date then info.year = date:match("(%d%d%d%d)") end
    for _i, text in ipairs(dc_texts(metadata, "identifier")) do
        local isbn = isbn_of(text)
        if isbn then info.isbn = isbn break end
    end
    return info
end

-- ── Repacking ───────────────────────────────────────────────────────────────

-- A copy in pieces: a big book is never held in memory whole.
local function copy_file(src, dst)
    local fi = io.open(src, "rb")
    if not fi then return false end
    local fo = io.open(dst, "wb")
    if not fo then
        fi:close()
        return false
    end
    local ok = true
    while true do
        local chunk = fi:read(65536)
        if not chunk then break end
        if not fo:write(chunk) then
            ok = false
            break
        end
    end
    fi:close()
    fo:close()
    if not ok then os.remove(dst) end
    return ok
end

local function validate_epub(path, opf_path)
    local reader = open_reader(path)
    if not reader then return false end
    local first_path, mimetype, opf_xml
    for entry in reader:iterate() do
        if not first_path then first_path = entry.path end
        if entry.path == "mimetype" then
            mimetype = reader:extractToMemory(entry.path)
        elseif entry.path == opf_path then
            opf_xml = reader:extractToMemory(entry.path)
        end
    end
    reader:close()
    if first_path ~= "mimetype" then return false end
    if not mimetype or not mimetype:find("application/epub%+zip") then return false end
    if not opf_xml then return false end
    return (pcall(function() return SLAXML:dom(opf_xml) end))
end

function EpubWriter.rewrite(path, changes, opts)
    local keep_backup = not (opts and opts.backup == false)
    if not EpubWriter.isEpub(path) then
        return false, _("Only EPUB books can be written.")
    end
    local got, err = extract_named(path, { ["META-INF/container.xml"] = true })
    if not got then return false, err end
    local container = got["META-INF/container.xml"]
    if not container then return false, "The book has no META-INF/container.xml." end
    local opf_path = opf_path_from_container(container)
    if not opf_path then return false, _("Could not find the OPF in the book.") end

    -- A new cover: where it goes in the zip is found in the OPF before anything is repacked.
    local cover_bytes, cover_plan, cover_zip_path
    if changes.cover_file then
        local f = io.open(changes.cover_file, "rb")
        cover_bytes = f and f:read("*a")
        if f then f:close() end
        local ext, mime = cover_kind(cover_bytes)
        if not ext then return false, _("The cover picture could not be read.") end
        local opf_only = extract_named(path, { [opf_path] = true })
        local opf_text = opf_only and opf_only[opf_path]
        if not opf_text then return false, _("Could not find the OPF in the book.") end
        local doc, metadata, perr = parse_metadata(opf_text)
        if not doc then return false, perr end
        local item = find_cover_item(doc, metadata)
        if item and attr_get(item, "href") then
            cover_zip_path = join_zip_path(opf_path, attr_get(item, "href"))
            cover_plan = { item_id = attr_get(item, "id"), media_type = mime }
        else
            local dir = opf_path:match("^(.*)/[^/]*$")
            local name = "kikome_cover." .. ext
            cover_zip_path = (dir and dir ~= "") and (dir .. "/" .. name) or name
            cover_plan = { new_href = name, media_type = mime }
        end
    end

    local reader = open_reader(path)
    if not reader then return false, _("Could not open the EPUB.") end

    local tmp = path .. ".kikome.tmp"
    os.remove(tmp)
    local writer = Archiver.Writer:new{}
    if not writer:open(tmp, "epub") then
        reader:close()
        return false, _("Could not create the temporary file.")
    end

    -- the mimetype goes first and stored, as an EPUB needs it
    writer:setZipCompression("store")
    writer:addFileFromMemory("mimetype", "application/epub+zip")
    writer:setZipCompression("deflate")

    local wrote_opf = false
    local edit_err
    for entry in reader:iterate() do
        if entry.path ~= "mimetype" and not edit_err then
            local content = reader:extractToMemory(entry.path)
            if cover_bytes and entry.path == cover_zip_path then
                content = cover_bytes   -- the old picture is replaced
                cover_zip_path = nil    -- (so it is not added again below)
                cover_plan.written = true
            end
            if content then
                if entry.path == opf_path then
                    local edited, e = edit_opf(content, changes, cover_plan)
                    if edited then
                        content = edited
                        wrote_opf = true
                    else
                        edit_err = e
                        content = nil
                    end
                end
                if content then writer:addFileFromMemory(entry.path, content) end
            end
        end
    end
    -- a book that had no cover picture gets the new one added
    if cover_bytes and cover_zip_path and cover_plan and cover_plan.new_href and not edit_err then
        writer:addFileFromMemory(cover_zip_path, cover_bytes)
    end
    writer:close()
    reader:close()

    if not edit_err and cover_bytes and cover_plan and cover_plan.item_id and not cover_plan.written then
        edit_err = _("The cover picture of the book was not found inside it.")
    end
    if edit_err then
        os.remove(tmp)
        return false, edit_err
    end
    if not wrote_opf then
        os.remove(tmp)
        return false, _("The OPF was not found while repacking.")
    end
    if not validate_epub(tmp, opf_path) then
        os.remove(tmp)
        return false, _("The new file did not pass the check; the book was left as it was.")
    end

    local backup
    if keep_backup then
        backup = EpubWriter.backupPath(path)
        os.remove(backup)
        if not copy_file(path, backup) then
            os.remove(tmp)
            return false, _("Could not keep a copy of the book; it was left as it was.")
        end
    end

    local ok_rename, rename_err = os.rename(tmp, path)
    if not ok_rename then
        os.remove(tmp)
        return false, string.format(_("Could not replace the book: %s"), tostring(rename_err))
    end
    return true, backup
end

-- for tests: edits an OPF text without touching any file
EpubWriter._edit_opf = edit_opf

return EpubWriter
