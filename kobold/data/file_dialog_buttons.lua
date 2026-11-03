-- kobold/data/file_dialog_buttons.lua — KiKome
-- The buttons other plugins add to KOReader's file dialog (the long-press
-- menu of a book in the file browser), for the Plugins section of Book
-- settings. A plugin registers them with FileManager:addFileDialogButtons
-- (id, function(file, is_file, book_props) -> a row of buttons); here every
-- button of every row becomes one entry of a flat list. This is how Bookshelf
-- shows them too.
--
--   FDButtons.collect(file)   -> { { key, text, enabled, callback }, ... }
--
-- `key` identifies a button across file browsers ("<registration id>#<place
-- in its row>"): when a parked book has to be closed to get a live file
-- browser, the buttons are collected again and the same key is looked up.
-- The cover browser's own buttons (ignore cover, refresh cached info) are
-- left out: Book settings has its own Refresh metadata. Every call into a
-- plugin is guarded, so a broken one can never break the screen.

local FDButtons = {}

local function registry()
    local ok, FileManager = pcall(require, "apps/filemanager/filemanager")
    if not ok or not FileManager then return nil end
    local fm = FileManager.instance
    local added = (fm and fm.file_dialog_added_buttons) or FileManager.file_dialog_added_buttons
    if type(added) ~= "table" or #added == 0 then return nil end
    return added, fm
end

local function call(f)
    if type(f) ~= "function" then return nil end
    local ok, value = pcall(f)
    if ok then return value end
    return nil
end

function FDButtons.collect(file)
    local out = {}
    local added, fm = registry()
    if not added then return out end
    -- registration position -> id
    local id_at = {}
    if type(added.index) == "table" then
        for id, pos in pairs(added.index) do id_at[pos] = id end
    end
    local book_props
    pcall(function()
        if fm and fm.coverbrowser and fm.coverbrowser.getBookInfo then
            book_props = fm.coverbrowser:getBookInfo(file)
        end
    end)
    for i = 1, #added do
        local id = id_at[i]
        if not (type(id) == "string" and id:find("^coverbrowser")) then
            local ok, row = pcall(added[i], file, true, book_props)
            if ok and type(row) == "table" then
                for j, spec in ipairs(row) do
                    if type(spec) == "table" then
                        local text = spec.text or call(spec.text_func)
                        if type(text) == "string" and text ~= "" then
                            local enabled = spec.enabled
                            if enabled == nil and spec.enabled_func then enabled = call(spec.enabled_func) end
                            out[#out + 1] = {
                                key = tostring(id or i) .. "#" .. j,
                                text = text,
                                enabled = enabled ~= false and type(spec.callback) == "function",
                                callback = spec.callback,
                            }
                        end
                    end
                end
            end
        end
    end
    return out
end

return FDButtons
