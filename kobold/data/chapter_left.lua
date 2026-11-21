-- kobold/data/chapter_left.lua — KiKome
-- How much is left in the chapter the reader is on, kept with the book so Home
-- can say "12 minutes left in chapter" while the book is closed (a closed book
-- has no table of contents to ask).
--
-- The reader saves it into the book's sidecar on every save (main.lua,
-- Kobold:onSaveSettings), next to percent_finished:
--   kikome_chapter_left = { pct = <where the book was>, pages = <pages left in
--   the chapter>, seconds = <the time for them>, text = <the same, as the
--   reader writes it> }
-- It is worked out the way the reader's own status bar does it (and the Page
-- Scrubber's table of contents): the pages up to the next chapter, and the
-- time for them asked of KOReader's statistics plugin (getTimeForPages, which
-- answers with text such as "12m"). `text` is that answer as it is; `seconds`
-- is read out of it, or comes from the plugin's average time per page when the
-- text cannot be read. Both are missing when that plugin is off or knows
-- nothing of the book; Home then uses the reading speed in the statistics
-- database for `pages`. `pct` says which position it was taken at: when
-- percent_finished is no longer that, the figure is old and not used.

local ChapterLeft = {}

-- How far `pct` and the sidecar's percent_finished may differ and still be the
-- same position.
local TOLERANCE = 0.01

-- The seconds in a time as KOReader writes it ("12m", "1h 5m", "1:05", also
-- with its words translated), or nil when it cannot be read.
function ChapterLeft.parseDuration(text)
    if type(text) ~= "string" then return nil end
    local h = tonumber(text:match("(%d+)%s*h"))
    local m = tonumber(text:match("(%d+)%s*m"))
    if h or m then return ((h or 0) * 60 + (m or 0)) * 60 end
    local a, b = text:match("^%s*(%d+):(%d+)")
    if a then return (tonumber(a) * 60 + tonumber(b)) * 60 end
    return nil
end

-- The value to keep for the open book `ui` (a ReaderUI), or nil when it cannot
-- be told (no table of contents, no page count...).
function ChapterLeft.snapshot(ui)
    local doc = ui and ui.document
    if not doc then return nil end
    local total = tonumber(doc.getPageCount and doc:getPageCount())
    if not total or total <= 0 then return nil end
    -- the page the reader's footer and the scrubber use as the current one
    local pageno = ui.view and ui.view.state and ui.view.state.page
    if type(pageno) ~= "number" and doc.getCurrentPage then pageno = doc:getCurrentPage() end
    if type(pageno) ~= "number" then return nil end

    -- pages left in the chapter: same logic as scrubber_toc.lua
    local left
    local raw_toc = ui.toc and ui.toc.toc
    if type(raw_toc) == "table" and #raw_toc > 0 then
        local flat = {}
        local min_d = 999
        for _i, e in ipairs(raw_toc) do
            local p = e.page or e.pageno
            if not p and e.pos0 and doc and doc.getPageFromXPointer then
                pcall(function() p = doc:getPageFromXPointer(e.pos0) end)
            end
            p = tonumber(p)
            if p and p >= 1 and p <= total then
                local d = tonumber(e.depth) or 1
                if d <= 3 then
                    flat[#flat + 1] = { page = math.floor(p), depth = d }
                    if d < min_d then min_d = d end
                end
            end
        end
        if #flat > 0 then
            if min_d < 999 and min_d > 0 then
                for _i, ch in ipairs(flat) do ch.depth = ch.depth - min_d end
            end
            local cur_idx = 1
            for i, ch in ipairs(flat) do
                if ch.page <= pageno then cur_idx = i else break end
            end
            local cur_depth = flat[cur_idx].depth or 0
            local next_page, has_next = total, false
            for j = cur_idx + 1, #flat do
                if (flat[j].depth or 0) <= cur_depth then
                    next_page, has_next = flat[j].page, true
                    break
                end
            end
            left = has_next and (next_page - pageno - 1) or (next_page - pageno)
        end
    end
    if left == nil and ui.toc and ui.toc.getChapterPagesLeft then
        local ok, n = pcall(ui.toc.getChapterPagesLeft, ui.toc, pageno)
        if ok then left = tonumber(n) end
    end
    if left == nil and doc.getTotalPagesLeft then
        local ok, n = pcall(doc.getTotalPagesLeft, doc, pageno)
        if ok then left = tonumber(n) end
    end
    if not left then return nil end
    left = math.max(0, math.floor(left))

    -- the position, as the reader saves it in percent_finished
    local pct
    local mod = ui.rolling or ui.paging
    if mod and mod.getLastPercent then
        local ok, p = pcall(mod.getLastPercent, mod)
        if ok then pct = tonumber(p) end
    end
    pct = pct or (pageno / total)

    -- the time for those pages, asked of the statistics plugin as the Page
    -- Scrubber does; "N/A" and the like (no digit) mean it has no figure
    local seconds, text
    local stats = ui.statistics
    if stats and left > 0 then
        if type(stats.getTimeForPages) == "function" then
            local ok, t = pcall(stats.getTimeForPages, stats, left)
            if ok and type(t) == "string" and t ~= "" and t:find("%d") then
                text = t
                seconds = ChapterLeft.parseDuration(t)
            end
        end
        if not seconds then
            -- the text could not be read: the plugin's own average, if it has one
            local avg = tonumber(stats.avg_time)
            if avg and avg > 0 then seconds = math.floor(left * avg + 0.5) end
        end
    end

    return {
        pct = math.floor(pct * 100000 + 0.5) / 100000,
        pages = left,
        seconds = seconds,
        text = text,
    }
end

-- True when `snap` was taken at the position the sidecar says (`pct`).
local function samePosition(snap, pct)
    pct = tonumber(pct)
    local at = type(snap) == "table" and tonumber(snap.pct)
    return (pct and at and pct > 0 and pct < 1 and math.abs(at - pct) <= TOLERANCE) and true or false
end

-- The time left in the chapter as the reader wrote it ("12m"), for when it
-- cannot be read as minutes; nil when the position has changed or there is none.
function ChapterLeft.text(snap, pct)
    if not samePosition(snap, pct) then return nil end
    return (type(snap.text) == "string" and snap.text ~= "") and snap.text or nil
end

-- Minutes left in the chapter, or nil. `snap` is what the sidecar holds, `pct`
-- its percent_finished, `pages` its page count and `seconds_per_page` the
-- book's reading speed (only needed when the snapshot has no `seconds`).
function ChapterLeft.minutes(snap, pct, pages, seconds_per_page)
    if not samePosition(snap, pct) then return nil end
    if tonumber(snap.seconds) then return tonumber(snap.seconds) / 60 end
    local rate = tonumber(seconds_per_page)
    if not rate then return nil end
    if tonumber(snap.pages) then return tonumber(snap.pages) * rate / 60 end
    -- the first version kept the share of the book instead of the pages
    pages = tonumber(pages)
    if tonumber(snap.left) and pages then return tonumber(snap.left) * pages * rate / 60 end
    return nil
end

return ChapterLeft
