-- kobold/data/book_tools.lua — KiKome
-- What the Book settings screen of the book details does to a book's data.
-- No UI (the confirmations and messages are in ui/file_actions.lua).
--
--   BookTools.canReset()     true when this KOReader can reset only the
--                            reading data (see below)
--   BookTools.reset(file)    -> true, or false and why
--
-- Reset this document: KOReader's own "Reset" of the file dialog, without its
-- dialog. It erases the book's reading data: progress, bookmarks, highlights,
-- notes, status, rating, review and the settings of the book (the sidecar's
-- metadata.<ext>.lua). It keeps the book file, a custom cover and the
-- corrected metadata (custom_metadata.lua), which have their own "Restore" in
-- Edit > Metadata. A KOReader whose DocSettings:purge cannot be told what to
-- erase is left to its own dialog (see FileActions.resetDocument).

local logger = require("logger")

local BookTools = {}

local function docSettings()
    local ok, DocSettings = pcall(require, "docsettings")
    if ok and DocSettings then return DocSettings end
    return nil
end

function BookTools.canReset()
    local DocSettings = docSettings()
    if not (DocSettings and type(DocSettings.purge) == "function") then return false end
    -- purge(self, sidecar_to_keep, data_to_purge): older versions take no
    -- second argument and would erase the custom cover and metadata too
    local ok, info = pcall(debug.getinfo, DocSettings.purge, "u")
    return ok and info ~= nil and (info.isvararg or (info.nparams or 0) >= 3)
end

function BookTools.reset(file)
    local DocSettings = docSettings()
    if not DocSettings then return false, "no docsettings" end
    local ok, err = pcall(function()
        local ds = DocSettings:open(file)
        ds:purge(nil, { doc_settings = true, custom_cover_file = false, custom_metadata_file = false })
    end)
    if not ok then
        logger.warn("Kobold: reset document failed:", tostring(err))
        return false, tostring(err)
    end
    -- the history entry knows its settings are gone
    pcall(function()
        local ReadHistory = require("readhistory")
        if ReadHistory.fileSettingsPurged then ReadHistory:fileSettingsPurged(file) end
    end)
    pcall(function() require("kobold.data.library").forgetDocInfo() end)
    return true
end

return BookTools
