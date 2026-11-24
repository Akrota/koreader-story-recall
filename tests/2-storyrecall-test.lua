-- Automated test run for Story Recall (test environment only).
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local results = io.open(OUT .. "/test-results.txt", "w")
local function log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    results:write(table.concat(parts, " ") .. "\n"); results:flush()
end
local function check(name, ok) log(ok and "PASS" or "FAIL", name) end
local function shot(name) Screen:shot(OUT .. "/shots/" .. name .. ".png") end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end

local steps = {}
local function add(delay, fn) steps[#steps + 1] = { delay, fn } end
local function run(i)
    local s = steps[i]; if not s then return end
    UIManager:scheduleIn(s[1], function()
        local ok, err = pcall(s[2])
        if not ok then log("ERROR in step", i, err) end
        run(i + 1)
    end)
end

local ui, plugin
add(3, function()
    ui = require("apps/reader/readerui").instance
    plugin = ui and ui.storyrecall
    check("plugin registered on ReaderUI", plugin ~= nil)
    local w = top()
    check("recap shown after 10-day break", w and w.title == "Rückblick" and w.text:find("Willkommen zurück!", 1, true) ~= nil)
    shot("01-recap-auto")
    closeTop()
end)
add(0.5, function()
    local ch = plugin:getCurrentChapter()
    log("start chapter", ch.index, ch.title)
    for _ = 1, 25 do
        if plugin:getCurrentChapter().index >= 2 then break end
        ui:handleEvent(Event:new("GotoViewRel", 1))
    end
    local now = plugin:getCurrentChapter()
    log("after paging chapter", now.index, now.title, "page", ui:getCurrentPage())
    local key1 = ui.toc.toc[1].xpointer
    check("chapter 1 completed by reading on", plugin.store:getChapter(key1) and plugin.store:getChapter(key1).completed_at ~= nil)
    plugin.store:addNote(now, "Mara misstraut Elias und beobachtet ihn heimlich.", "user")
end)
add(0.5, function()
    ui:handleEvent(Event:new("GotoPage", ui.toc.toc[5].page))
    log("jumped to chapter", plugin:getCurrentChapter().index)
    check("chapter 2 not completed by jumping", plugin.store:getChapter(ui.toc.toc[2].xpointer) == nil)
    check("chapter 4 not completed by jumping", plugin.store:getChapter(ui.toc.toc[4].xpointer) == nil)
    ui:handleEvent(Event:new("GotoPage", ui.toc.toc[3].page))
    local ch3 = plugin:getCurrentChapter()
    check("back in chapter 3", ch3.index == 3)
    plugin.store:addNote(ch3, "Im Wald trifft Elias auf die Wölfe.", "user")
end)
add(0.5, function()
    check("furthest is chapter 2 (jumps do not count)", plugin.store:getFurthestChapter() == 2)
    plugin:showChronicle()
end)
add(1, function()
    local w = top()
    check("chronicle hides chapter 3 note before reading it", w.text:find("Maras Geheimnis") and not w.text:find("Der Wald") and w.text:find("ausgeblendet"))
    log("chronicle (furthest 2):\n" .. w.text)
    shot("02a-chronicle-hidden-note"); closeTop()
    ui:handleEvent(Event:new("GotoViewRel", 1))
    check("reading on in chapter 3 moves furthest to 3", plugin.store:getFurthestChapter() == 3)
    ui:handleEvent(Event:new("GotoPage", 1))
    log("back on page", ui:getCurrentPage(), "chapter", plugin:getCurrentChapter().index)
    plugin:showChronicle()
end)
add(1, function()
    local w = top()
    check("chronicle on page 1 still shows up to chapter 3", w.text:find("Wölfe") and not w.text:find("Die Flucht") and not w.text:find("ausgeblendet"))
    log("chronicle text:\n" .. w.text)
    shot("02-chronicle"); closeTop()
    plugin:showChronicle()
end)
add(1, function()
    local w = top()
    local label = w.button_table:getButtonById("page").text
    log("page label:", label)
    check("short chronicle has a single page", label == "1 / 1")
    shot("02b-chronicle-pagebar")
    w.buttons_table[2][1].callback()
end)
add(1, function()
    local w = top()
    check("chronicle button goes back to recap", w and w.title == "Rückblick")
    closeTop()
    -- Still on page 1: the recap ends where the reader is, so no note from chapter 3 yet
    plugin:showRecap()
    local early = top()
    check("recap on page 1 does not list the chapter 3 note", early and early.text and not early.text:find("Wölfe"))
    closeTop()
    -- Back in chapter 3, where the reader is
    ui:handleEvent(Event:new("GotoPage", ui.toc.toc[3].page + 1))
    plugin:showRecap()
end)
add(1, function()
    local w = top()
    check("recap lists own notes", w and w.text and w.text:find("Wölfe") ~= nil)
    log("recap text:\n" .. tostring(w and w.text))
    shot("03-recap-with-notes"); closeTop()
    plugin:showBookInfo()
end)
add(1, function()
    local w = top()
    log("book info:\n" .. tostring(w and w.text))
    check("book info shows series", w and w.text and w.text:find("Testreihe, Band 2") ~= nil)
    shot("04-book-info"); closeTop()
    local items = {}
    plugin:addToMainMenu(items)
    local settings_menu; for _, it in ipairs(items.story_recall.sub_item_table_func()) do if it.text == "Einstellungen" then settings_menu = it.sub_item_table end end
    for _, it in ipairs(settings_menu) do
        log("setting:", it.text or it.text_func())
    end
    ui.menu:onShowMenu()
end)
add(1, function()
    local c = ui.menu.menu_container[1]
    local tm = c.tab_item_table and c or c[1]
    local found
    for i, tab in ipairs(tm.tab_item_table or {}) do
        for _, it in ipairs(tab) do
            local text = it.text or (it.text_func and it.text_func())
            if text == "Story Recall" then found = it; tm:switchMenuTab(i); log("menu tab", i) end
        end
    end
    check("Story Recall entry in reader menu", found ~= nil)
    if found then tm:onMenuSelect(found) end
end)
add(1, function()
    shot("05-menu")
    ui.menu:onCloseReaderMenu()
    require("storyrecall/views").showNotesList(plugin.store, function() end)
end)
add(1, function()
    shot("06-notes-list"); closeTop()
    plugin:addNoteToCurrentChapter()
end)
add(1, function()
    shot("07-add-note-dialog"); closeTop()
    log("closing document")
    ui:onClose()
end)
add(2, function()
    log("done")
    results:close()
    UIManager:quit()
end)
run(1)
