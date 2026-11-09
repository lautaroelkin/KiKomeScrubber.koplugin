-- kobold/ui/park.lua — KiKome
-- Instant exit from a book. Leaving a book for KiKome does NOT close it: the
-- KiKome screen that opened the book (it already waits under the reader, see
-- session.lua) is lifted above the reader, so it shows at once, and the book
-- stays open "parked" underneath. The real close (KOReader saves the book and
-- the file browser is built again: one to three seconds in which nothing else
-- can run) happens later, at a moment you are not using the device:
--
--   * after IDLE_FINISH_S seconds with no touch or key (checked every
--     PROBE_EVERY_S, and only with a KiKome screen on top);
--   * when something needs KOReader's file browser (its top menu, a book's
--     KOReader menu, an action, a gesture): see Park.fm();
--   * when the KiKome screen is closed (Back): the book closes with the
--     "Closing" pill, then the file browser shows;
--   * when another book is opened: the parked one is closed first, inside the
--     wait of opening the new one (see Park.closeForSwitch).
--
-- While it is parked, opening the same book again is the reverse move:
-- the reader is lifted above the screen again, with no loading at all.
--
-- Nothing here is saved: the state is only in memory and is checked against
-- the live ReaderUI every time, so it can never outlive the book. Turn it off
-- in KiKome Settings (Instant exit from books).

local Device        = require("device")
local Event         = require("ui/event")
local UIManager     = require("ui/uimanager")
local logger        = require("logger")
local KoboldPrefs   = require("kobold.data.prefs")
local KoboldSession = require("kobold.ui.session")

local Screen = Device.screen

local Park = {}

local IDLE_FINISH_S = 15
local PROBE_EVERY_S = 5

local _parked = nil       -- { rui = ReaderUI, file = path }
local _finishing = false  -- the real close is running (init and onCloseDocument stand aside)
local _switching = false  -- the parked book is closing to open another one
local _probe = nil        -- the scheduled idle probe
local _last_input = 0     -- os.time() of the last touch or key

function Park.enabled()
    return KoboldPrefs.get("hot_park") ~= false
end

local function readerInstance()
    local RU = package.loaded["apps/reader/readerui"]
    return RU and RU.instance or nil
end

function Park.isParked()
    if not _parked then return false end
    if readerInstance() ~= _parked.rui then
        _parked = nil  -- closed some other way
        return false
    end
    return true
end

function Park.parkedFile()
    return Park.isParked() and _parked.file or nil
end

function Park.isFinishing() return _finishing end
function Park.isSwitching() return _switching end

local function cancelProbe()
    if _probe then
        UIManager:unschedule(_probe)
        _probe = nil
    end
end

-- Any real close (whoever asked for it) ends the parked state.
function Park.noteRealClose()
    _parked = nil
    cancelProbe()
end

-- Input stamp for the idle trigger: UIManager:sendEvent is where every touch
-- and key passes, whichever window is on top, so a popup counts as activity.
local function installInputStamp()
    if UIManager._kobold_input_stamp then return end
    UIManager._kobold_input_stamp = true
    local orig = UIManager.sendEvent
    if not orig then return end
    UIManager.sendEvent = function(um, event, ...)
        local h = type(event) == "table" and event.handler
        if h == "onGesture" or h == "onKeyPress" or h == "onKeyRepeat" then
            _last_input = os.time()
        end
        return orig(um, event, ...)
    end
end

local function isKoboldScreen(w)
    return w and w.covers_fullscreen and type(w.name) == "string" and w.name:sub(1, 7) == "kobold_"
end

local function topWidget()
    local stack = UIManager._window_stack
    local entry = stack and stack[#stack]
    return entry and entry.widget or nil
end

-- True when `w` is a window of the stack; moves it to the top (no repaint).
local function toTop(w)
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    for i, entry in ipairs(stack) do
        if entry.widget == w then
            if i ~= #stack then
                table.remove(stack, i)
                table.insert(stack, entry)
            end
            return true
        end
    end
    return false
end

-- True when KiKome can park the book `rui` is showing: the setting is on and
-- the KiKome screen that opened it is still under it, laid out for the
-- current screen size (after a rotation the normal close rebuilds it).
function Park.canPark(rui)
    if not Park.enabled() then return false end
    if not (rui and rui.document) then return false end
    if Park.isParked() then return false end
    local screen = KoboldSession.parkedScreen()
    if not screen then return false end
    local d = screen.dimen
    if d and (d.w ~= Screen:getWidth() or d.h ~= Screen:getHeight()) then return false end
    return true
end

-- Brings the screens' data up to date after a park (progress, last book).
local function refreshScreen(screen, rui, file)
    pcall(function() rui:saveSettings() end)
    pcall(function()
        local BookList = require("ui/widget/booklist")
        BookList.setBookInfoCacheProperty(file, "percent_finished",
            rui.doc_settings:readSetting("percent_finished"))
    end)
    UIManager:forceRePaint()
    if screen and screen.onKoboldReturn then pcall(function() screen:onKoboldReturn() end) end
end

local probe

local function armProbe(rui)
    cancelProbe()
    _probe = function() probe(rui) end
    UIManager:scheduleIn(PROBE_EVERY_S, _probe)
end

-- Parks the book: lifts the KiKome screen above it. False when it cannot
-- (the caller then closes the book the usual way).
function Park.park(rui)
    if not Park.canPark(rui) then return false end
    local screen = KoboldSession.parkedScreen()
    local file = rui.document.file
    -- Close the reader's own chrome first, as KOReader does when it switches
    -- books: a menu left open would sit above the screen.
    pcall(function()
        rui:handleEvent(Event:new("CloseReaderMenu"))
        rui:handleEvent(Event:new("CloseConfigMenu"))
        if rui.highlight and rui.highlight.onClose then rui.highlight:onClose() end
    end)
    if not KoboldSession.raise(screen) then return false end
    _parked = { rui = rui, file = file }
    installInputStamp()
    _last_input = os.time()
    -- The screen is on show; its data is read again right after it is painted.
    UIManager:nextTick(function()
        if not (_parked and _parked.rui == rui) then return end
        refreshScreen(screen, rui, file)
    end)
    armProbe(rui)
    return true
end

-- Lifts the parked reader above the KiKome screens again. Windows KiKome
-- opened on top of the screen (book details, menus) are closed first, since
-- no book-opening event reaches them on this route.
function Park.unpark(screen)
    if not Park.isParked() then return false end
    local rui = _parked.rui
    local stack = UIManager._window_stack
    if type(stack) ~= "table" then return false end
    local found = false
    for _i, entry in ipairs(stack) do
        if entry.widget == rui then found = true break end
    end
    if not found then
        _parked = nil
        cancelProbe()
        return false
    end
    _parked = nil
    cancelProbe()
    if screen then
        local idx
        for i, entry in ipairs(stack) do
            if entry.widget == screen then idx = i end
        end
        if idx then
            local extra = {}
            for i = #stack, idx + 1, -1 do
                local w = stack[i].widget
                if w ~= rui then extra[#extra + 1] = w end
            end
            for _i, w in ipairs(extra) do pcall(function() UIManager:close(w) end) end
        end
    end
    toTop(rui)
    UIManager:setDirty(rui, "full")
    return true
end

-- Every window from the lowest KiKome screen up to the top of the stack, in
-- stack order, except the reader itself: the screens and whatever sits on
-- them (book details, menus, a toast). The real close puts all of them back
-- above the new file browser, not only the one that was on top.
local function kikomeWindows(rui)
    local stack = UIManager._window_stack
    local out = {}
    if type(stack) ~= "table" then return out end
    local first
    for i, entry in ipairs(stack) do
        if isKoboldScreen(entry.widget) then first = i break end
    end
    if not first then return out end
    for i = first, #stack do
        local w = stack[i].widget
        if w ~= rui then out[#out + 1] = w end
    end
    return out
end

-- The real close of the parked book, behind the KiKome screen that is on
-- top. Blocks for a moment: callers choose when. True when it ran.
local function finishCore(reason)
    if not Park.isParked() then return false end
    local rui, file = _parked.rui, _parked.file
    local top = topWidget()
    local windows = kikomeWindows(rui)
    _parked = nil
    cancelProbe()
    _finishing = true
    pcall(function() rui:onClose(false) end)
    if rui.showFileManager then pcall(function() rui:showFileManager(file) end) end
    -- The new file browser went on top of the screens: put them back, in
    -- their old order (each one moved to the top in turn). A window that is
    -- gone by now is skipped. Without any KiKome screen, only the top one.
    if #windows > 0 then
        for _i, w in ipairs(windows) do toTop(w) end
    elseif top then
        toTop(top)
    end
    if top then UIManager:setDirty(top, "ui") end
    KoboldSession.take()
    -- A screen hooked the old file browser (My Books): hook the new one.
    for _i, entry in ipairs(UIManager._window_stack or {}) do
        local w = entry.widget
        if isKoboldScreen(w) and w.hookFileManager then
            pcall(function()
                if w.unhook then w.unhook() w.unhook = nil end
                w:hookFileManager()
            end)
        end
    end
    UIManager:nextTick(function() _finishing = false end)
    logger.dbg("[kobold park] finished:", reason)
    return true
end

-- Idle probe: reschedules itself until nothing was touched for
-- IDLE_FINISH_S seconds and a KiKome screen is on top, then finishes.
probe = function(rui)
    _probe = nil
    if not (_parked and _parked.rui == rui) then return end
    if readerInstance() ~= rui then
        _parked = nil
        return
    end
    if os.time() - _last_input >= IDLE_FINISH_S and isKoboldScreen(topWidget()) then
        finishCore("idle")
        return
    end
    armProbe(rui)
end

-- KOReader's file browser (its menu, file dialog, gestures, actions). A
-- parked book has none, so it is made first (the book closes now). Returns
-- the file browser, or nil when there is none.
function Park.fm()
    if Park.isParked() then finishCore("file browser needed") end
    local FM = package.loaded["apps/filemanager/filemanager"]
    return FM and FM.instance or nil
end

-- A KiKome screen was closed (Back). With a book parked below it, the book
-- closes (the "Closing" pill shows meanwhile) and the file browser shows;
-- otherwise the screen is simply closed. Always handled.
function Park.closeScreen(screen)
    if not Park.isParked() then
        UIManager:close(screen)
        return
    end
    local Transition = require("kobold.ui.transition")
    pcall(function() Transition.show(require("kobold.i18n")("Closing")) end)
    UIManager:nextTick(function()
        finishCore("screen closed")
        Transition.close()
        UIManager:close(screen)
    end)
end

-- The real close of the parked book now, for a change that only a fresh opening
-- shows (the stable pages: KOReader builds its own numbering when the book
-- loads). The caller shows the "Closing" pill. True when it ran.
function Park.finish(reason)
    return finishCore(reason or "asked")
end

-- Another book is about to open while one is parked: the parked one closes
-- first (no file browser is built; the new book takes its place). This runs
-- inside the opening wait, so its cost is not felt separately.
function Park.closeForSwitch()
    if not Park.isParked() then return end
    local rui = _parked.rui
    _parked = nil
    cancelProbe()
    _switching = true
    -- What KOReader's own switchDocument sets before closing a reader.
    pcall(function() rui.tearing_down = true; rui.dithered = nil end)
    pcall(function() rui:onClose(false) end)
    _switching = false
end

return Park
