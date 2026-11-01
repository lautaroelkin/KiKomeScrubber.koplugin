-- kobold/ui/refresh.lua — KiKome
-- A menu (a sheet, a popup, the book menu...) is painted and its area refreshed
-- the moment it opens. On some e-ink panels that first update can be lost: it
-- is asked for while the panel is still busy with the update that came before
-- it (the tap's own flash, a page change under it), and the menu stays blank or
-- half drawn until the next touch makes another refresh, which then shows
-- everything at once.
--
-- Refresh.settle(widget, region) asks for the same area once more a moment
-- later, when the panel is free. Nothing is painted again: it only sends what
-- is already in the screen buffer to the panel, so if the first update went
-- through the second one changes nothing the eye can see.
--
--   Refresh.settle(widget, region)   region: a Geom, or a function returning one
--                                    (the area the widget covers, nil = all)

local UIManager = require("ui/uimanager")

local Refresh = {}

-- Long enough for a panel to finish the update that opened the menu (the
-- slowest "ui" waveforms take about a quarter of a second), short enough that
-- nobody has time to touch the screen first.
local DELAY_S = 0.3

local function inStack(widget)
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        if entry.widget == widget then return true end
    end
    return false
end

function Refresh.settle(widget, region)
    if type(widget) ~= "table" then return end
    -- A newer call for the same widget replaces the pending one.
    local token = {}
    widget._kobold_settle = token
    UIManager:scheduleIn(DELAY_S, function()
        if widget._kobold_settle ~= token then return end
        widget._kobold_settle = nil
        -- Closed in the meantime: closing refreshed its own area.
        if widget.closed or not inStack(widget) then return end
        local r = region
        if type(region) == "function" then
            local ok, res = pcall(region)
            r = ok and res or nil
        end
        if not r then return end
        -- No widget given: only the panel is updated, nothing is painted again.
        UIManager:setDirty(nil, "ui", r)
    end)
end

return Refresh
