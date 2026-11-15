-- kobold/ui/action_icon.lua — KiKome
-- The picture of a custom action (data/custom_actions.lua): an svg or png file,
-- or "kobold:<name>" for one of the plugin's own icons. Used by the tiles of
-- the Actions chip (library_shelf.lua) and by the icon picker (icon_picker.lua).
--
--   ActionIcon.path(spec)               the file of an icon spec, or nil when it is
--                                       not there (a file that was deleted)
--   ActionIcon.widget(spec, size, fallback)   a size x size widget; the plugin's
--                                       `fallback` icon (default "sparkles") when
--                                       the spec is empty or cannot be drawn
--   ActionIcon.isIconFile(name)         true for the files the picker lists (svg, png)
--   ActionIcon.builtinDir()             the plugin's own icons folder, or nil

local Blitbuffer = require("ffi/blitbuffer")
local IconWidget = require("ui/widget/iconwidget")
local lfs        = require("libs/libkoreader-lfs")
local KoboldMeta = require("kobold.meta")
local OptionSheet = require("kobold.ui.option_sheet")

local ActionIcon = {}

function ActionIcon.isIconFile(name)
    local l = tostring(name):lower()
    return l:match("%.svg$") ~= nil or l:match("%.png$") ~= nil
end

function ActionIcon.builtinDir()
    local probe = KoboldMeta.icon("plus.svg")
    return probe and probe:match("^(.*)/[^/]+$") or nil
end

function ActionIcon.path(spec)
    if type(spec) ~= "string" or spec == "" then return nil end
    local name = spec:match("^kobold:(.+)$")
    local path = name and KoboldMeta.icon(name .. ".svg") or spec
    if path and lfs.attributes(path, "mode") == "file" then return path end
    return nil
end

function ActionIcon.widget(spec, size, fallback)
    local path = ActionIcon.path(spec)
    if path then
        local ok, widget = pcall(function()
            return IconWidget:new{
                file = path, width = size, height = size,
                alpha = true, original_in_nightmode = false,
            }
        end)
        if ok and widget then return widget end
    end
    return OptionSheet.iconWidget(fallback or "sparkles", size, Blitbuffer.COLOR_BLACK)
end

return ActionIcon
