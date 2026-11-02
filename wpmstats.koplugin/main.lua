-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 FPsamuraiG

--[[--
Reading speed (WPM) for KOReader.

Measures words per minute for reflowable books (EPUB, FB2, TXT...) in
single-page mode.

Model
- Frontier: the furthest page reached this session. Only the frontier
  page is timed, and it is counted when you turn forward one page.
- Plausibility: a sample counts only if it has enough words, stays under
  the max time per page, and implies a speed under the max plausible wpm.
- Detours: going back from the frontier. A short detour (few pages back,
  short time away) keeps the frontier page's timing (include or exclude
  the detour time); a long one discards that page's sample.
- Re-reading: plausible forward turns behind the frontier form a
  tentative run; after N in a row they are committed and the frontier
  moves there.
- Sleep: timers pause while asleep; an interrupted page is ignored or
  counted with its full (awake) time, depending on the setting.
- Menus and popups: timers pause while anything covers the page (menus,
  settings, dialogs, dictionary and footnote popups).
- Layout changes (font, margins, rotation, re-layout) reset the frontier.
  Scroll mode and two-page mode pause tracking.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local T = require("ffi/util").template
local _ = require("gettext")

local MIN_WORDS = 30      -- skip near-empty pages (chapter titles, images)
local TYPICAL_SHARE = 0.4 -- also skip pages under 40% of a typical page...
local TYPICAL_PAGES = 5   -- ...once this many pages in this layout counted
local ROLLING_PAGES = 20  -- window for the "recent" speed
local POLL_SECONDS = 3    -- how often to check whether a menu covers the page

local DEFAULTS = {
    max_minutes = 10,         -- max time per page
    max_wpm = 1000,           -- max plausible speed
    sleep_mode = "ignore",    -- "ignore" | "count"
    detour_mode = "include",  -- "include" | "exclude"
    detour_pages = 3,         -- short detour: max pages back
    detour_minutes = 2,       -- short detour: max time away
    run_length = 3,           -- turns in a row to confirm re-reading
    debug_log = false,        -- log every decision to crash.log
}

local ok_logger, logger = pcall(require, "logger")

-- Clock -------------------------------------------------------------------

local ok_time, time = pcall(require, "ui/time")

local function now()
    if ok_time and type(time) == "table" and time.monotonic and time.to_s then
        local ok, v = pcall(time.monotonic)
        if ok and v then return time.to_s(v) end
    end
    return os.time()
end

-- Timers ------------------------------------------------------------------

local function newTimer(t_now)
    return { elapsed = 0, start = t_now, interrupted = false }
end

local function timerStart(t, t_now)
    if t and not t.start then t.start = t_now end
end

local function timerPause(t, t_now)
    if t and t.start then
        t.elapsed = t.elapsed + math.max(0, t_now - t.start)
        t.start = nil
    end
end

local function timerTotal(t, t_now)
    local s = t.elapsed
    if t.start then s = s + math.max(0, t_now - t.start) end
    return s
end

-- Formatting --------------------------------------------------------------

local function calcWpm(words, seconds)
    if not words or not seconds or seconds < 60 then return nil end
    return math.floor(words * 60 / seconds + 0.5)
end

local function formatDuration(seconds)
    seconds = math.floor(seconds or 0)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return T(_("%1 h %2 min"), h, m)
    end
    return T(_("%1 min"), m)
end

-- Plugin ------------------------------------------------------------------

local WpmStats = WidgetContainer:extend{
    name = "wpmstats",
    is_doc_only = true,
}

function WpmStats:init()
    self.supported = false   -- reflowable document with the APIs we need
    self.paused = true       -- scroll / two-page mode, or not started
    self.position = nil      -- page currently shown
    self.frontier = nil      -- furthest page reached this session
    self.ftimer = nil        -- timer for the frontier page
    self.frontier_discard = false
    self.detour = nil        -- { left_at, min_page, run = { page, timer, samples } }
    self.layout_sig = nil
    self.session = { words = 0, seconds = 0 }
    self.book = { words = 0, seconds = 0, pages = 0 }
    self.recent = {}
    self.page_words = {}     -- words on recent counted pages in this layout
    self.show_in_footer = G_reader_settings:nilOrTrue("wpm_stats_footer")
    self.ui.menu:registerToMainMenu(self)
end

function WpmStats:getSetting(key)
    local v = G_reader_settings:readSetting("wpm_stats_" .. key)
    if v == nil then return DEFAULTS[key] end
    return v
end

function WpmStats:setSetting(key, value)
    G_reader_settings:saveSetting("wpm_stats_" .. key, value)
end

-- Debug log: one line per decision, written to crash.log when enabled.
function WpmStats:log(fmt, ...)
    if not self:getSetting("debug_log") then return end
    if not (ok_logger and type(logger) == "table" and logger.info) then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if ok then pcall(logger.info, "wpmstats: " .. msg) end
end

-- Document helpers --------------------------------------------------------

function WpmStats:isSupported()
    local doc = self.ui.document
    if not doc then return false end
    if doc.info and doc.info.has_pages then return false end -- PDF, CBZ...
    return doc.getPageXPointer ~= nil and doc.getTextFromXPointers ~= nil
end

function WpmStats:getPageCount()
    local doc = self.ui.document
    local ok, total = pcall(doc.getPageCount, doc)
    if ok then return total end
end

function WpmStats:getVisiblePages()
    local doc = self.ui.document
    if doc.getVisiblePageCount then
        local ok, n = pcall(doc.getVisiblePageCount, doc)
        if ok and n then return n end
    end
    return 1
end

function WpmStats:getViewMode()
    return self.ui.view and self.ui.view.view_mode or "page"
end

function WpmStats:isTrackable()
    return self.supported
        and self:getViewMode() ~= "scroll"
        and self:getVisiblePages() == 1
end

-- Anything that re-paginates the book changes at least one of these.
function WpmStats:layoutSignature()
    return table.concat({
        tostring(self:getPageCount()),
        tostring(self:getViewMode()),
        tostring(self:getVisiblePages()),
    }, "|")
end

function WpmStats:countWords(page)
    local doc = self.ui.document
    local total = self:getPageCount()
    if total and page >= total then return nil end
    local ok0, xp0 = pcall(doc.getPageXPointer, doc, page)
    local ok1, xp1 = pcall(doc.getPageXPointer, doc, page + 1)
    if not (ok0 and ok1 and xp0 and xp1) then return nil end
    local ok, text = pcall(doc.getTextFromXPointers, doc, xp0, xp1, false)
    if not ok or type(text) ~= "string" then return nil end
    local n = 0
    for _word in text:gmatch("%S+") do
        n = n + 1
    end
    return n
end

-- Samples -----------------------------------------------------------------

-- Returns { words, seconds } if the timed page passes every check,
-- or nil and the reason (for the debug log).
function WpmStats:evaluate(page, timer, t_now)
    local seconds = timerTotal(timer, t_now)
    if seconds <= 0 then return nil, "no time" end
    if timer.interrupted and self:getSetting("sleep_mode") == "ignore" then
        return nil, string.format("interrupted by sleep (%.1f s)", seconds)
    end
    local max_seconds = self:getSetting("max_minutes") * 60
    if seconds > max_seconds then
        return nil, string.format("over max time (%.1f s > %d s)", seconds, max_seconds)
    end
    local words = self:countWords(page)
    if not words then return nil, "could not count words" end
    local min_words = self:minWords()
    if words < min_words then
        return nil, string.format("too few words (%d < %d)", words, min_words)
    end
    local wpm = words * 60 / seconds
    if wpm > self:getSetting("max_wpm") then
        return nil, string.format("too fast (%d words, %.1f s, %d wpm)",
            words, seconds, math.floor(wpm + 0.5))
    end
    return { words = words, seconds = seconds }
end

-- Title pages, chapter ends and mostly-image pages have few words, so the
-- time to turn the page dominates and a flip can pass the speed check.
-- Compare with a typical page in the current layout (font size etc.).
function WpmStats:minWords()
    local n = #self.page_words
    if n < TYPICAL_PAGES then return MIN_WORDS end
    local sorted = {}
    for i = 1, n do sorted[i] = self.page_words[i] end
    table.sort(sorted)
    local median
    if n % 2 == 1 then
        median = sorted[(n + 1) / 2]
    else
        median = (sorted[n / 2] + sorted[n / 2 + 1]) / 2
    end
    return math.max(MIN_WORDS, math.floor(median * TYPICAL_SHARE + 0.5))
end

function WpmStats:logSample(what, page, sample, reason)
    if sample then
        self:log("%s %d counted (%d words, %.1f s, %d wpm)", what, page,
            sample.words, sample.seconds,
            math.floor(sample.words * 60 / sample.seconds + 0.5))
    else
        self:log("%s %d rejected: %s", what, page, reason or "?")
    end
end

function WpmStats:addSample(sample)
    local words, seconds = sample.words, sample.seconds

    self.session.words = self.session.words + words
    self.session.seconds = self.session.seconds + seconds

    self.book.words = (self.book.words or 0) + words
    self.book.seconds = (self.book.seconds or 0) + seconds
    self.book.pages = (self.book.pages or 0) + 1

    table.insert(self.recent, { words = words, seconds = seconds })
    if #self.recent > ROLLING_PAGES then
        table.remove(self.recent, 1)
    end

    table.insert(self.page_words, words)
    if #self.page_words > ROLLING_PAGES then
        table.remove(self.page_words, 1)
    end

    local all = G_reader_settings:readSetting("wpm_stats_total")
        or { words = 0, seconds = 0 }
    all.words = all.words + words
    all.seconds = all.seconds + seconds
    G_reader_settings:saveSetting("wpm_stats_total", all)
end

function WpmStats:recentWpm()
    local words, seconds = 0, 0
    for _i, s in ipairs(self.recent) do
        words = words + s.words
        seconds = seconds + s.seconds
    end
    return calcWpm(words, seconds)
end

-- Holds (sleep, menus) -----------------------------------------------------

-- While any hold is active, all timers are paused. Timers that were
-- running are marked `held` and resume when the last hold is released.

function WpmStats:isHeld()
    return self.holds ~= nil and next(self.holds) ~= nil
end

function WpmStats:activeTimers()
    local timers = {}
    if self.ftimer then table.insert(timers, self.ftimer) end
    if self.detour and self.detour.run then
        table.insert(timers, self.detour.run.timer)
    end
    return timers
end

function WpmStats:setHold(reason, on, detail)
    self.holds = self.holds or {}
    local was = self:isHeld()
    if (self.holds[reason] or false) ~= (on and true or false) then
        self:log("hold %s: %s%s", on and "on" or "off", reason,
            detail and (" (" .. detail .. ")") or "")
    end
    self.holds[reason] = on and true or nil
    local is = self:isHeld()
    local t_now = now()
    if is and not was then
        for _i, t in ipairs(self:activeTimers()) do
            if t.start then
                timerPause(t, t_now)
                t.held = true
            end
        end
    elseif was and not is then
        for _i, t in ipairs(self:activeTimers()) do
            if t.held then
                timerStart(t, t_now)
                t.held = nil
            end
        end
    end
end

-- New timers start paused if a hold is active (e.g. a TOC jump made from
-- the menu), and begin counting once it is released.
function WpmStats:makeTimer(t_now)
    local t = newTimer(t_now)
    if self:isHeld() then
        t.start = nil
        t.held = true
    end
    return t
end

function WpmStats:resumeTimer(t, t_now)
    if not t or t.start then return end
    if self:isHeld() then
        t.held = true
    else
        timerStart(t, t_now)
    end
end

-- Returns whether something covers the page, and its name (for the log).
function WpmStats:isReaderObscured()
    local ok, top = pcall(function()
        if UIManager.getTopmostVisibleWidget then
            return UIManager:getTopmostVisibleWidget()
        elseif UIManager.getTopWidget then
            return UIManager:getTopWidget()
        end
    end)
    if not ok or top == nil then return false end
    if top == self.ui then return false end
    if type(top) == "table" then
        local name = top.name or top.id
        return name ~= "ReaderUI", tostring(name or "unnamed widget")
    end
    if type(top) == "string" then return top ~= "ReaderUI", top end
    return false
end

function WpmStats:checkOverlay()
    if self.supported and not self.paused then
        local covered, what = self:isReaderObscured()
        self:setHold("overlay", covered, what)
    end
end

-- Polling only runs while a page is actually being timed: a timer that can
-- still produce a sample (not over the max time per page, not discarded).
function WpmStats:needsPolling()
    if not self.supported or self.paused then return false end
    local t_now = now()
    local max_seconds = self:getSetting("max_minutes") * 60
    if self.ftimer and not self.frontier_discard
            and timerTotal(self.ftimer, t_now) <= max_seconds then
        return true
    end
    if self.detour and self.detour.run
            and timerTotal(self.detour.run.timer, t_now) <= max_seconds then
        return true
    end
    return false
end

function WpmStats:startPolling()
    if self.poll_func or not self:needsPolling() then return end
    self.poll_func = function()
        self:checkOverlay()
        if self:needsPolling() then
            UIManager:scheduleIn(POLL_SECONDS, self.poll_func)
        else
            self:stopPolling()
        end
    end
    UIManager:scheduleIn(POLL_SECONDS, self.poll_func)
    self:log("polling started")
end

function WpmStats:stopPolling()
    if self.poll_func then
        UIManager:unschedule(self.poll_func)
        self.poll_func = nil
        self:log("polling stopped")
    end
    -- Nothing watches menus while stopped, so don't leave timers held.
    self:setHold("overlay", false)
end

-- State transitions -------------------------------------------------------

-- Start fresh with the frontier on `page` (open, jump ahead, layout change,
-- confirmed re-reading run).
function WpmStats:resetAt(page, t_now)
    self.position = page
    self.frontier = page
    self.ftimer = self:makeTimer(t_now)
    self.frontier_discard = false
    self.detour = nil
end

function WpmStats:startRun(page, t_now)
    if not self.detour then return end
    self.detour.run = { page = page, timer = self:makeTimer(t_now), samples = {} }
end

function WpmStats:leaveFrontier(new, t_now)
    if self:getSetting("detour_mode") == "exclude" then
        timerPause(self.ftimer, t_now)
    end
    self.detour = { left_at = t_now, min_page = new }
    self:log("detour: left frontier %d for page %d", self.frontier, new)
    self:startRun(new, t_now)
end

function WpmStats:returnToFrontier(t_now)
    local d = self.detour
    local pages_back = self.frontier - d.min_page
    local away = t_now - d.left_at
    local short = pages_back <= self:getSetting("detour_pages")
        and away <= self:getSetting("detour_minutes") * 60
    if short then
        self:resumeTimer(self.ftimer, t_now) -- resumes if paused (exclude mode)
    else
        self.frontier_discard = true   -- long detour: drop this page's sample
    end
    self:log("detour: back on frontier %d, %s (%d pages back, %.1f s away)",
        self.frontier, short and "short, page kept" or "long, page will be discarded",
        pages_back, away)
    self.detour = nil
end

function WpmStats:onDetourTurn(old, new, t_now)
    local d = self.detour
    if new < d.min_page then d.min_page = new end

    if new == self.frontier then
        self:returnToFrontier(t_now)
        return
    end

    if new > self.frontier then
        self:log("detour: jumped from %d past frontier %d to %d, frontier reset",
            old, self.frontier, new)
        self:resetAt(new, t_now) -- jumped past the frontier
        return
    end

    local run = d.run
    if run and new == old + 1 and run.page == old then
        local sample, reason = self:evaluate(old, run.timer, t_now)
        if sample then
            table.insert(run.samples, sample)
            local needed = self:getSetting("run_length")
            self:log("re-read page %d plausible, held (%d/%d)", old, #run.samples, needed)
            if #run.samples >= needed then
                -- Confirmed re-reading: commit and move the frontier here.
                for _i, s in ipairs(run.samples) do
                    self:addSample(s)
                end
                self:log("re-read run committed: %d pages, frontier moved to %d",
                    #run.samples, new)
                self:resetAt(new, t_now)
                return
            end
            run.page = new
            run.timer = self:makeTimer(t_now)
            return
        end
        self:logSample("re-read page", old, nil, reason)
    end

    -- Implausible turn, backward turn or jump: break the run.
    if run and #run.samples > 0 then
        self:log("re-read run broken, %d held pages dropped", #run.samples)
    end
    self:startRun(new, t_now)
end

-- Events ------------------------------------------------------------------

function WpmStats:onReaderReady()
    self.supported = self:isSupported()
    if not self.supported then return end
    self.book = self.ui.doc_settings:readSetting("wpm_stats")
        or { words = 0, seconds = 0, pages = 0 }
    self:setupFooter()
    local doc = self.ui.document
    local ok, page = pcall(doc.getCurrentPage, doc)
    self.layout_sig = self:layoutSignature()
    if ok and page and self:isTrackable() then
        self.paused = false
        self:resetAt(page, now())
        self:log("book opened at page %s, tracking", tostring(page))
        self:startPolling()
    else
        self.paused = true
        self.position = ok and page or nil
        self:log("book opened at page %s, paused (scroll or two-page mode)", tostring(page))
    end
end

function WpmStats:onPageUpdate(new)
    if not self.supported or not new then return end
    local was_polling = self.poll_func ~= nil
    self:handlePageUpdate(new)
    if self.paused then
        self:stopPolling()
    elseif not was_polling then
        -- Polling was idle: check right away in case a menu is open (e.g. a
        -- TOC jump), so the new page's timer doesn't count menu time.
        self:checkOverlay()
        self:startPolling()
    end
end

function WpmStats:handlePageUpdate(new)
    local t_now = now()

    if not self:isTrackable() then
        if not self.paused then
            self:log("tracking paused at page %d (scroll or two-page mode)", new)
        end
        self.paused = true
        self.position = new
        return
    end

    local sig = self:layoutSignature()
    if self.paused or sig ~= self.layout_sig or not self.frontier then
        -- (Re)start after a layout change or leaving scroll/two-page mode.
        if self.paused then
            self:log("tracking resumed at page %d", new)
        else
            self:log("layout changed (%s -> %s), frontier reset at page %d",
                tostring(self.layout_sig), sig, new)
        end
        if sig ~= self.layout_sig then
            -- Words per page differ in the new layout; relearn what's typical.
            self.page_words = {}
        end
        self.paused = false
        self.layout_sig = sig
        self:resetAt(new, t_now)
        return
    end

    local old = self.position
    if new == old then return end -- same page re-rendered
    self.position = new

    if old == self.frontier then
        if new == self.frontier + 1 then
            if self.frontier_discard then
                self:log("page %d discarded (long detour)", self.frontier)
            else
                local sample, reason = self:evaluate(self.frontier, self.ftimer, t_now)
                if sample then self:addSample(sample) end
                self:logSample("page", self.frontier, sample, reason)
            end
            self:resetAt(new, t_now)
        elseif new > self.frontier + 1 then
            self:log("jumped ahead from %d to %d, frontier reset", old, new)
            self:resetAt(new, t_now) -- jumped ahead
        else
            self:leaveFrontier(new, t_now)
        end
    elseif self.detour then
        self:onDetourTurn(old, new, t_now)
    else
        self:log("unexpected state at page %d, frontier reset", new)
        self:resetAt(new, t_now) -- shouldn't happen; recover
    end
end

function WpmStats:onSuspend()
    if not self.supported then return end
    self:setHold("sleep", true)
    if self.paused then return end
    -- Mark the page being read when the device went to sleep.
    if self.position == self.frontier and self.ftimer then
        self.ftimer.interrupted = true
        self:log("page %d marked interrupted by sleep", self.position)
    elseif self.detour and self.detour.run and self.detour.run.page == self.position then
        self.detour.run.timer.interrupted = true
        self:log("re-read page %d marked interrupted by sleep", self.position)
    end
end

function WpmStats:onResume()
    if not self.supported then return end
    self:setHold("sleep", false)
    self:startPolling()
end

function WpmStats:onSaveSettings()
    if self.supported then
        self.ui.doc_settings:saveSetting("wpm_stats", self.book)
    end
end

function WpmStats:onCloseDocument()
    self:stopPolling()
    local footer = self:getFooter()
    if footer and self.footer_func and footer.removeAdditionalFooterContent then
        pcall(footer.removeAdditionalFooterContent, footer, self.footer_func)
    end
end

-- Status bar --------------------------------------------------------------

function WpmStats:getFooter()
    local footer = self.ui.view and self.ui.view.footer
    if footer and footer.addAdditionalFooterContent then
        return footer
    end
end

function WpmStats:setupFooter()
    local footer = self:getFooter()
    if not footer or self.footer_func then return end
    self.footer_func = function()
        if not self.show_in_footer then return nil end
        local v = self:recentWpm()
        if v then return T(_("%1 wpm"), v) end
        return nil
    end
    footer:addAdditionalFooterContent(self.footer_func)
end

function WpmStats:refreshFooter()
    local footer = self:getFooter()
    if footer and footer.onUpdateFooter then
        pcall(footer.onUpdateFooter, footer, true)
    end
end

-- Stats window ------------------------------------------------------------

function WpmStats:timeLeftText(book_wpm)
    if not book_wpm or (self.book.pages or 0) < 5 then return nil end
    local total = self:getPageCount()
    if not (total and self.position) then return nil end
    local pages_left = total - self.position
    if pages_left <= 0 then return nil end
    local words_per_page = self.book.words / self.book.pages
    local minutes = pages_left * words_per_page / book_wpm
    return formatDuration(minutes * 60)
end

function WpmStats:showStats()
    if not self.supported then
        UIManager:show(InfoMessage:new{
            text = _("Reading speed is only tracked for reflowable books (EPUB, FB2, TXT…), not PDFs or comics."),
        })
        return
    end

    local none = _("not enough data yet")
    local function line(label, words, seconds, extra)
        local v = calcWpm(words, seconds)
        if not v then return T(_("%1: %2"), label, none) end
        local s = T(_("%1: %2 wpm (%3"), label, v, formatDuration(seconds))
        if extra then s = s .. ", " .. extra end
        return s .. ")"
    end

    local recent_words, recent_seconds = 0, 0
    for _i, s in ipairs(self.recent) do
        recent_words = recent_words + s.words
        recent_seconds = recent_seconds + s.seconds
    end
    local all = G_reader_settings:readSetting("wpm_stats_total")
        or { words = 0, seconds = 0 }

    local lines = {
        _("Reading speed"),
        "",
        line(T(_("Last %1 pages"), #self.recent), recent_words, recent_seconds),
        line(_("This session"), self.session.words, self.session.seconds),
        line(_("This book"), self.book.words, self.book.seconds,
            T(_("%1 pages"), self.book.pages or 0)),
        line(_("All books"), all.words, all.seconds),
    }
    local left = self:timeLeftText(calcWpm(self.book.words, self.book.seconds))
    if left then
        table.insert(lines, "")
        table.insert(lines, T(_("Time left in book at this speed: %1"), left))
    end
    if self.paused then
        table.insert(lines, "")
        table.insert(lines, _("Tracking is paused in scroll mode and two-page mode."))
    end

    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

-- Menu --------------------------------------------------------------------

function WpmStats:spinItem(key, label, title, info, min, max, step, hold, unit)
    return {
        text_func = function()
            return T(label, self:getSetting(key))
        end,
        keep_menu_open = true,
        callback = function(touchmenu_instance)
            UIManager:show(SpinWidget:new{
                title_text = title,
                info_text = info,
                value = self:getSetting(key),
                value_min = min,
                value_max = max,
                value_step = step,
                value_hold_step = hold,
                default_value = DEFAULTS[key],
                unit = unit,
                callback = function(spin)
                    self:setSetting(key, spin.value)
                    if touchmenu_instance then touchmenu_instance:updateItems() end
                end,
            })
        end,
    }
end

-- choices = { { value, short_label, full_label }, ... }
function WpmStats:choiceItem(key, label, choices)
    local sub = {}
    for _i, c in ipairs(choices) do
        table.insert(sub, {
            text = c[3],
            radio = true,
            checked_func = function() return self:getSetting(key) == c[1] end,
            callback = function() self:setSetting(key, c[1]) end,
        })
    end
    return {
        text_func = function()
            local current = self:getSetting(key)
            for _i, c in ipairs(choices) do
                if c[1] == current then return T(label, c[2]) end
            end
            return T(label, tostring(current))
        end,
        sub_item_table = sub,
    }
end

function WpmStats:addToMainMenu(menu_items)
    menu_items.wpm_stats = {
        text = _("Reading speed (WPM)"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Show reading speed"),
                keep_menu_open = true,
                callback = function() self:showStats() end,
            },
            {
                text = _("Show in status bar"),
                enabled_func = function()
                    return self.supported and self:getFooter() ~= nil
                end,
                checked_func = function() return self.show_in_footer end,
                callback = function()
                    self.show_in_footer = not self.show_in_footer
                    G_reader_settings:saveSetting("wpm_stats_footer", self.show_in_footer)
                    self:refreshFooter()
                end,
                separator = true,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    self:spinItem("max_minutes",
                        _("Max time per page: %1 min"),
                        _("Max time per page"),
                        _("Pages you stay on longer than this are ignored, since you probably stepped away."),
                        1, 60, 1, 5, _("min")),
                    self:spinItem("max_wpm",
                        _("Max plausible speed: %1 wpm"),
                        _("Max plausible speed"),
                        _("Pages read faster than this are treated as skimming or flipping and ignored."),
                        300, 3000, 50, 250, _("wpm")),
                    self:choiceItem("sleep_mode",
                        _("Pages interrupted by sleep: %1"), {
                            { "ignore", _("ignore"), _("Ignore (most accurate speed)") },
                            { "count", _("count"), _("Count full time, excluding sleep") },
                        }),
                    self:choiceItem("detour_mode",
                        _("Time checking earlier pages: %1"), {
                            { "include", _("include"), _("Include (counts toward the page you were reading)") },
                            { "exclude", _("exclude"), _("Exclude (pause while on earlier pages)") },
                        }),
                    self:spinItem("detour_pages",
                        _("Short detour: up to %1 pages back"),
                        _("Short detour: pages back"),
                        _("Going back further than this discards the page you were reading."),
                        1, 20, 1, 5, _("pages")),
                    self:spinItem("detour_minutes",
                        _("Short detour: up to %1 min away"),
                        _("Short detour: time away"),
                        _("Staying away longer than this discards the page you were reading."),
                        1, 30, 1, 5, _("min")),
                    self:spinItem("run_length",
                        _("Pages in a row to confirm re-reading: %1"),
                        _("Confirm re-reading"),
                        _("When reading behind your furthest page, this many plausible page turns in a row count as real reading."),
                        2, 10, 1, 2, _("pages")),
                    {
                        text = _("Debug log (writes to crash.log)"),
                        checked_func = function() return self:getSetting("debug_log") end,
                        callback = function()
                            self:setSetting("debug_log", not self:getSetting("debug_log"))
                            self:log("debug log on (page %s, frontier %s, %s)",
                                tostring(self.position), tostring(self.frontier),
                                self.paused and "paused" or "tracking")
                        end,
                    },
                },
                separator = true,
            },
            {
                text = _("Reset this book"),
                keep_menu_open = true,
                enabled_func = function() return self.supported end,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset reading speed data for this book?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            self.book = { words = 0, seconds = 0, pages = 0 }
                            self.session = { words = 0, seconds = 0 }
                            self.recent = {}
                            self.ui.doc_settings:saveSetting("wpm_stats", self.book)
                            self:refreshFooter()
                        end,
                    })
                end,
            },
            {
                text = _("Reset all books"),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(ConfirmBox:new{
                        text = _("Reset reading speed data for all books?"),
                        ok_text = _("Reset"),
                        ok_callback = function()
                            G_reader_settings:saveSetting("wpm_stats_total",
                                { words = 0, seconds = 0 })
                        end,
                    })
                end,
            },
        },
    }
end

return WpmStats
