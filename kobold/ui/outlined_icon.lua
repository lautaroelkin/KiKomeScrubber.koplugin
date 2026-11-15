-- kobold/ui/outlined_icon.lua — KiKome
-- An svg icon in white with a black outline, drawn over a book cover (the
-- "..." of Library's grid and the squares of selection mode, in Library and
-- in Home). Shared by mybooks.lua and library_shelf.lua.

local Blitbuffer  = require("ffi/blitbuffer")
local Device      = require("device")
local Geom        = require("ui/geometry")
local Widget      = require("ui/widget/widget")
local OptionSheet = require("kobold.ui.option_sheet")

local Screen = Device.screen

-- An svg icon in white with a black outline. The svg is drawn once, in black,
-- onto a white scratch buffer, and the dark pixels are kept as a mask; each
-- paint then fills that mask in black, grown by the outline, and again in
-- white. (A white tint of the svg itself does not come out white.)
local OutlinedIcon = Widget:extend{ name = nil, size = 0 }

function OutlinedIcon:init()
    local img = OptionSheet.iconWidget(self.name, self.size, Blitbuffer.COLOR_BLACK)
    local mask = Blitbuffer.new(self.size, self.size, Blitbuffer.TYPE_BB8)
    mask:fill(Blitbuffer.COLOR_WHITE)
    pcall(function() img:paintTo(mask, 0, 0) end)
    self.pts = {}
    for yy = 0, self.size - 1 do
        for xx = 0, self.size - 1 do
            local px = mask:getPixel(xx, yy)
            if px and px:getColor8().a < 140 then
                self.pts[#self.pts + 1] = xx
                self.pts[#self.pts + 1] = yy
            end
        end
    end
    mask:free()
    if img.free then img:free() end
end

function OutlinedIcon:getSize() return Geom:new{ w = self.size, h = self.size } end

function OutlinedIcon:paintTo(bb, x, y)
    self.dimen = Geom:new{ x = x, y = y, w = self.size, h = self.size }
    local o = math.max(1, Screen:scaleBySize(1))
    local d = 2 * o + 1
    local pts = self.pts
    for i = 1, #pts, 2 do
        bb:paintRect(x + pts[i] - o, y + pts[i + 1] - o, d, d, Blitbuffer.COLOR_BLACK)
    end
    for i = 1, #pts, 2 do
        bb:paintRect(x + pts[i], y + pts[i + 1], 1, 1, Blitbuffer.COLOR_WHITE)
    end
end

function OutlinedIcon:free() end

return OutlinedIcon
