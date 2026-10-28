-- _meta.lua — KiKome
-- The one file with the plugin's facts. KOReader reads `name`, `fullname` and
-- `description` for Plugin management; the rest (version, repo, license, the
-- folder, icon paths, debug mode) is used by KiKome itself — About, the
-- updater, the icons — through require("kobold.meta"), which main.lua points
-- at this file.
-- `name` stays "kobold" so it matches main.lua and any saved enable/disable
-- choice. Change VERSION here when releasing.

local _ = require("gettext")

local KoboldMeta = {
    -- Read by KOReader.
    name        = "kobold",
    fullname    = _("KiKome"),
    description = _([[A mix of Kindle and Kobo for KOReader: a Home with swipeable recent books, My Books, and page navigation and annotation browsing.]]),

    -- Used by KiKome.
    NAME    = "KiKome",
    VERSION = "1",
    REPO    = "https://github.com/lautaroelkin/KiKomeScrubber.koplugin",
    LICENSE = "GPL-3.0",
    -- Developer tools, default state. When on: long-press the clock in the
    -- status bar to save a screenshot (see KoboldWidgets.statusBarFrame).
    -- Tapping the Kobold logo on the About page 10 times toggles it and
    -- saves the choice, which then wins over this default.
    DEBUG   = false,
}

-- Plugin folder (…/KiKomeScrubber.koplugin), from this file's own path.
KoboldMeta.DIR = (debug.getinfo(1, "S").source or ""):match("^@(.*)/_meta%.lua$")

-- True when debug mode is on: the saved toggle, or DEBUG when never toggled.
function KoboldMeta.debugOn()
    local saved = G_reader_settings and G_reader_settings:readSetting("kobold_settings")
    if type(saved) == "table" and saved.debug ~= nil then return saved.debug == true end
    return KoboldMeta.DEBUG
end

-- Full path of a file in the plugin's icons folder, or nil.
function KoboldMeta.icon(name)
    return KoboldMeta.DIR and (KoboldMeta.DIR .. "/icons/" .. name) or nil
end

return KoboldMeta
