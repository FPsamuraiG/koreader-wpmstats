-- SPDX-License-Identifier: AGPL-3.0-or-later
-- Copyright (c) 2026 FPsamuraiG

-- Minimal KOReader mocks to exercise the plugin's state machine.
local clock = 0
local settings = {}
local function deepcopy(v) return v end

G_reader_settings = {
    readSetting = function(_, k) return settings[k] end,
    saveSetting = function(_, k, v) settings[k] = v end,
    nilOrTrue = function(_, k) return settings[k] == nil or settings[k] == true end,
}

package.preload["ui/widget/confirmbox"] = function() return {} end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
package.preload["ui/widget/spinwidget"] = function() return {} end
local top_widget = nil -- set to a menu widget to simulate a menu on top
package.preload["ui/uimanager"] = function()
    return {
        show = function() end,
        scheduleIn = function() end,
        unschedule = function() end,
        getTopmostVisibleWidget = function() return top_widget end,
    }
end
package.preload["ui/widget/container/widgetcontainer"] = function()
    local W = {}
    function W:extend(o) o = o or {}; setmetatable(o, { __index = self }); return o end
    function W:new(o) o = o or {}; setmetatable(o, { __index = self }); if o.init then o:init() end; return o end
    return W
end
package.preload["ffi/util"] = function()
    return { template = function(s, ...)
        local args = { ... }
        return (s:gsub("%%(%d)", function(i) return tostring(args[tonumber(i)]) end))
    end }
end
package.preload["gettext"] = function() return function(s) return s end end
local log_lines = {}
package.preload["logger"] = function()
    return { info = function(msg) table.insert(log_lines, msg) end }
end
package.preload["ui/time"] = function()
    return { monotonic = function() return clock end, to_s = function(v) return v end }
end

local WORDS = 250
local page_count = 500
local view_mode = "page"
local current = 1
local text = string.rep("word ", WORDS)

local doc = {
    info = { has_pages = false },
    getPageXPointer = function(_, p) return p end,
    getTextFromXPointers = function(_, a, b) return string.rep(text, b - a) end,
    getPageCount = function() return page_count end,
    getVisiblePageCount = function() return 1 end,
    getCurrentPage = function() return current end,
}
local doc_settings = {
    data = {},
    readSetting = function(self, k) return self.data[k] end,
    saveSetting = function(self, k, v) self.data[k] = v end,
}
local ui = {
    document = doc,
    doc_settings = doc_settings,
    view = { view_mode = "page" },
    menu = { registerToMainMenu = function() end },
}

local Plugin = dofile(arg_plugin_path)
local p = Plugin:new{ ui = ui }
p:onReaderReady()

local function wait(s) clock = clock + s end
local function go(page) current = page; p:onPageUpdate(page) end
local function pages() return p.book.pages end
local results = {}
local function check(name, cond)
    table.insert(results, (cond and "PASS " or "FAIL ") .. name)
end

-- 1. Normal reading: 4 forward turns at 60 s/page -> 4 samples at 250 wpm.
for i = 2, 5 do wait(60); go(i) end
check("normal reading counts 4 pages", pages() == 4)
check("normal reading speed 250 wpm", p:recentWpm() == 250)

-- 2. Flipping at 2 s/page counts nothing (implausible).
local before = pages()
for i = 6, 10 do wait(2); go(i) end
check("fast flipping ignored", pages() == before)

-- 3. Short detour (1 back, 10 s) with include: page gets full time.
before = pages()
wait(30); go(9); wait(10); go(10); wait(20); go(11)
check("short detour counts frontier page once", pages() == before + 1)
check("short detour includes check time (60 s)", p.recent[#p.recent].seconds == 60)

-- 4. Long detour (200 pages back) then back: frontier page discarded, nothing fast.
before = pages()
wait(20); go(11 - 10 + 1); wait(5); go(11); wait(30); go(12)
check("long detour discards frontier page", pages() == before)
wait(60); go(13)
check("counting resumes after long detour", pages() == before + 1)

-- 5. Re-reading run behind the frontier: 3 plausible turns commit.
before = pages()
go(3) -- jump far back (long detour)
wait(60); go(4); wait(60); go(5)
check("run not committed before 3 turns", pages() == before)
wait(60); go(6)
check("run committed after 3 turns", pages() == before + 3)
check("frontier moved to run position", p.frontier == 6)

-- 6. Sleep with ignore: page interrupted by sleep is not counted.
before = pages()
wait(30); p:onSuspend(); wait(3600); p:onResume(); wait(30); go(7)
check("sleep-interrupted page ignored", pages() == before)

-- 6b. Sleep with count: time excludes sleep.
settings["wpm_stats_sleep_mode"] = "count"
before = pages()
wait(30); p:onSuspend(); wait(3600); p:onResume(); wait(30); go(8)
check("sleep-interrupted page counted (count mode)", pages() == before + 1)
check("sleep time excluded (60 s)", p.recent[#p.recent].seconds == 60)
settings["wpm_stats_sleep_mode"] = nil

-- 7. Layout change (page count changes) resets without counting.
before = pages()
wait(60); page_count = 520; go(9)
check("layout change does not count", pages() == before)
wait(60); go(10)
check("counting resumes after layout change", pages() == before + 1)

-- 8. Scroll mode pauses tracking.
before = pages()
ui.view.view_mode = "scroll"
wait(60); go(11); wait(60); go(12)
check("scroll mode paused", pages() == before and p.paused)
ui.view.view_mode = "page"
wait(60); go(13); wait(60); go(14)
check("tracking resumes after scroll mode", pages() == before + 1 and not p.paused)

-- 9. Back-and-forth glance (re-read page counted only once).
before = pages()
wait(40); go(13); wait(8); go(14); wait(30); go(15)
check("glance back does not double count", pages() == before + 1)

-- 10. Jump ahead: skipped pages not counted, frontier moves.
before = pages()
wait(20); go(100)
check("jump ahead counts nothing", pages() == before and p.frontier == 100)

-- 11. Exclude detour time.
settings["wpm_stats_detour_mode"] = "exclude"
before = pages()
wait(30); go(99); wait(15); go(100); wait(30); go(101)
check("exclude mode counts 60 s", p.recent[#p.recent].seconds == 60 and pages() == before + 1)
settings["wpm_stats_detour_mode"] = nil

-- 12. Menu open pauses the timer.
before = pages()
top_widget = ui
wait(30)
top_widget = { name = "TouchMenu" }; p:checkOverlay()
wait(300)
top_widget = ui; p:checkOverlay()
wait(30); go(102)
check("menu time excluded (60 s)", pages() == before + 1 and p.recent[#p.recent].seconds == 60)

-- 13. TOC jump made from the menu: new page timer starts paused, then runs.
before = pages()
wait(20)
top_widget = { name = "TouchMenu" }; p:checkOverlay()
wait(40); go(150) -- jump ahead while menu is open
wait(40)
top_widget = ui; p:checkOverlay()
wait(60); go(151)
check("timer after menu jump counts only reading time", pages() == before + 1 and p.recent[#p.recent].seconds == 60)

-- 14. Sleep while a menu is open, then wake and close the menu.
before = pages()
top_widget = { name = "TouchMenu" }; p:checkOverlay()
wait(10); p:onSuspend(); wait(600); p:onResume()
top_widget = ui; p:checkOverlay()
settings["wpm_stats_sleep_mode"] = "count"
wait(60); go(152)
check("sleep during menu: only reading time counted", pages() == before + 1 and p.recent[#p.recent].seconds == 60)
settings["wpm_stats_sleep_mode"] = nil

-- 15. Polling stops once the page passes the max time, restarts on a turn.
check("polling active while timing", p.poll_func ~= nil)
wait(700); p.poll_func()
check("polling stops after max time per page", p.poll_func == nil)
before = pages()
wait(60); go(153)
check("page over max time not counted", pages() == before)
check("polling restarts on page turn", p.poll_func ~= nil)

-- 16. Menu already open when polling restarts (TOC jump from menu).
wait(700); p.poll_func() -- stop polling again
top_widget = { name = "TouchMenu" }
wait(30); go(200) -- jump while menu open; immediate overlay check holds timer
wait(40)
top_widget = ui; p.poll_func()
before = pages()
wait(60); go(201)
check("idle-restart excludes open menu time", pages() == before + 1 and p.recent[#p.recent].seconds == 60)

-- 17. Scroll mode stops polling.
ui.view.view_mode = "scroll"
wait(5); go(202)
check("scroll mode stops polling", p.poll_func == nil)
ui.view.view_mode = "page"

-- 18. Debug log: silent by default; when on, logs each decision with its reason.
local function logged(pattern)
    for _i, line in ipairs(log_lines) do
        if line:find(pattern) then return true end
    end
    return false
end
check("debug log silent by default", #log_lines == 0)
settings["wpm_stats_debug_log"] = true
wait(5); go(203)                              -- resume after scroll mode
wait(60); go(204)                             -- counted
wait(2); go(205)                              -- too fast
top_widget = { name = "TouchMenu" }; p:checkOverlay()
top_widget = ui; p:checkOverlay()
wait(30); go(204); wait(5); go(205)           -- short detour
wait(30); go(206)
check("log: tracking resumed", logged("^wpmstats: tracking resumed at page 203"))
check("log: counted page with numbers", logged("^wpmstats: page 203 counted %(250 words, 60%.0 s, 250 wpm%)"))
check("log: rejected page with reason", logged("^wpmstats: page 204 rejected: too fast"))
check("log: menu hold names the widget", logged("hold on: overlay %(TouchMenu%)") and logged("hold off: overlay"))
check("log: short detour", logged("detour: back on frontier 205, short, page kept"))
local n = #log_lines
settings["wpm_stats_debug_log"] = nil
wait(60); go(207)
check("log: silent again when turned off", #log_lines == n)

return table.concat(results, "\n")
