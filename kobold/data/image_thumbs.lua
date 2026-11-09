-- kobold/data/image_thumbs.lua — KiKome
-- Small pictures of image files (JPG / PNG) for a list, made without making the
-- screen wait. Used by the image picker of the cover screen (book_details.lua).
--
--   Thumbs.info(path)               -> { width, height, size, ... } read from the
--                                      file's header only (cheap), or nil
--   Thumbs.widget(path, size, load) -> an ImageWidget that fits in size x size, or
--                                      nil, true when it still has to be made
--       load = false: only what is already made is returned (never decodes);
--       load = true : a picture that is not there yet is decoded now.
--       A picture too big to decode quickly (see MAX_PIXELS / MAX_FILE), or one
--       that cannot be read, gives nil and not pending: its row keeps its icon.
--   Thumbs.clear()                  forgets everything (the picker closed)
--
-- Made pictures are kept in memory, newest use last, up to BYTE_BUDGET: going
-- back to a page or ticking a row never decodes again.

local lfs = require("libs/libkoreader-lfs")

local Thumbs = {}

local MAX_PIXELS  = 8 * 1000 * 1000        -- bigger pictures cost too long to decode
local MAX_FILE    = 6 * 1024 * 1024
local BYTE_BUDGET = 6 * 1024 * 1024

local cache, cache_bytes, counter = {}, 0, 0   -- [key] = { bb, bytes, used } or false
local infos = {}                               -- [path] = info or false

function Thumbs.info(path)
    local known = infos[path]
    if known ~= nil then return known or nil end
    local ok, CoverOnline = pcall(require, "kobold.data.cover_online")
    local info = ok and CoverOnline and CoverOnline.inspect(path) or nil
    infos[path] = info or false
    return info
end

local function bbBytes(bb)
    local ok, n = pcall(function() return tonumber(bb.stride) * bb:getHeight() end)
    if ok and n then return n end
    return bb:getWidth() * bb:getHeight() * 4
end

local function evict()
    while cache_bytes > BYTE_BUDGET do
        local oldest, oldest_used = nil, math.huge
        for key, entry in pairs(cache) do
            if entry and entry.used < oldest_used then oldest, oldest_used = key, entry.used end
        end
        if not oldest then return end
        cache_bytes = cache_bytes - cache[oldest].bytes
        cache[oldest] = nil   -- not freed by hand: a widget may still draw it
    end
end

local function decode(path, size, key)
    local ok, bb = pcall(function()
        local RenderImage = require("ui/renderimage")
        local src = RenderImage:renderImageFile(path, false)
        if not src then return nil end
        local sw, sh = src:getWidth(), src:getHeight()
        local scale = math.min(size / sw, size / sh)
        if scale >= 1 then return src end
        local out = src:scale(math.max(1, math.floor(sw * scale)), math.max(1, math.floor(sh * scale)))
        pcall(function() src:free() end)
        return out
    end)
    if not (ok and bb) then
        cache[key] = false
        return nil
    end
    counter = counter + 1
    local entry = { bb = bb, bytes = bbBytes(bb), used = counter }
    cache[key] = entry
    cache_bytes = cache_bytes + entry.bytes
    evict()
    return entry
end

function Thumbs.widget(path, size, load)
    local info = Thumbs.info(path)
    if not info then return nil end
    if info.width * info.height > MAX_PIXELS or (info.size or 0) > MAX_FILE then return nil end
    local key = table.concat({ path, size, lfs.attributes(path, "modification") or 0 }, "|")
    local entry = cache[key]
    if entry == false then return nil end
    if not entry then
        if not load then return nil, true end
        entry = decode(path, size, key)
        if not entry then return nil end
    end
    counter = counter + 1
    entry.used = counter
    local ok, widget = pcall(function()
        local ImageWidget = require("ui/widget/imagewidget")
        return ImageWidget:new{
            image = entry.bb, image_disposable = false,
            width = entry.bb:getWidth(), height = entry.bb:getHeight(),
            scale_factor = 0,
        }
    end)
    if ok and widget then return widget end
    return nil
end

function Thumbs.clear()
    cache, cache_bytes, infos = {}, 0, {}
end

return Thumbs
