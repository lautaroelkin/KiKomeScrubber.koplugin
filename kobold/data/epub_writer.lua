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
--   series       string              with series_index (number or text, optional)
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

-- ── Reading and editing the OPF ─────────────────────────────────────────────

local function opf_path_from_container(container)
    return container:match('full%-path%s*=%s*"([^"]+)"')
        or container:match("full%-path%s*=%s*'([^']+)'")
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

local function edit_opf(opf_xml, changes)
    local doc, metadata, err = parse_metadata(opf_xml)
    if not metadata then return nil, err end
    local prefix = detect_dc_prefix(metadata)

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
    if changes.series ~= nil and changes.series ~= "" then
        set_calibre_series(metadata, changes.series, changes.series_index)
        set_epub3_series(metadata, changes.series, changes.series_index)
    end

    local ok, out = pcall(function() return SLAXML:xml(doc) end)
    if not ok or not out then
        return nil, _("Could not write the edited OPF.")
    end
    return out
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
            if content then
                if entry.path == opf_path then
                    local edited, e = edit_opf(content, changes)
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
    writer:close()
    reader:close()

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
