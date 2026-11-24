-- Stress test for Story Recall: 40 chapters, many notes and highlights.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local results = io.open(OUT .. "/stress-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end results:write(table.concat(p, " ") .. "\n"); results:flush() end
local function check(name, ok) log(ok and "PASS" or "FAIL", name) end
local function shot(name) Screen:shot(OUT .. "/shots-big/" .. name .. ".png") end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end
local steps = {}
local function add(d, fn) steps[#steps+1] = { d, fn } end
local function run(i) local s = steps[i]; if not s then return end
    UIManager:scheduleIn(s[1], function() local ok, err = pcall(s[2]); if not ok then log("ERROR step", i, err) end; run(i + 1) end) end
local ui, plugin, Views
local LONG = "Joren gesteht Mara, dass er den Brief damals gefälscht hat, um den Rat zu täuschen. Mara ist wütend, weil dadurch ihr Bruder verbannt wurde, aber sie braucht Joren für die Reise in den Norden. Elias merkt, dass zwischen den beiden etwas nicht stimmt, sagt aber nichts."
add(3, function()
    ui = require("apps/reader/readerui").instance
    plugin = ui.storyrecall
    Views = require("storyrecall/views")
    local w = top()
    check("auto recap titled Rückblick", w and w.title == "Rückblick")
    check("greeting line after break", w and w.text and w.text:find("Willkommen zurück!", 1, true) ~= nil)
    shot("01-recap-after-break-empty"); closeTop()
    local toc = ui.toc.toc
    -- 2 notes per chapter in 1..36, every 5th one long; 8 notes beyond the read point
    for i = 1, 40 do
        local ch = { index = i, key = toc[i].xpointer, title = toc[i].title }
        local count = i <= 36 and 2 or 2
        for k = 1, count do
            local text = (i % 5 == 0 and k == 1) and LONG or ("Notiz " .. k .. " zu Kapitel " .. i .. ": Elias und Mara streiten über den Weg.")
            plugin.store:addNote(ch, text, "user")
        end
    end
    for i = 1, 36 do
        plugin.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title })
    end
    plugin.store:setFurthestChapter(37)
    for i = 30, 37 do
        ui.annotation:addItem({ page = toc[i].xpointer, pos0 = toc[i].xpointer, pos1 = toc[i].xpointer,
            text = "Markierter Satz aus Kapitel " .. i .. ": Elias, Mara und Joren reisen weiter durch das Land, bis die Nacht hereinbricht und der Fluss über die Ufer tritt.",
            note = (i % 2 == 0) and "Wichtig für später!" or nil, chapter = toc[i].title, drawer = "lighten" })
    end
    ui:handleEvent(require("ui/event"):new("GotoPage", toc[37].page + 1))
    log("notes", #plugin.store:getNotes(), "page", ui:getCurrentPage(), "chapter", plugin:getCurrentChapter().index)
end)
add(1, function()
    local t0 = os.clock()
    local ctx = plugin:buildContext()
    local recap = Views.buildRecapText(ctx)
    local chron = Views.buildChronicleText(ctx, #ctx.chapters)
    log(string.format("build time: %.1f ms (recap %d chars, chronicle %d chars)", (os.clock() - t0) * 1000, #recap, #chron))
    plugin:showRecap(false)
end)
add(1, function()
    local w = top()
    check("manual recap has no greeting", w and w.text and not w.text:find("Willkommen zurück!"))
    log("recap text:\n" .. w.text)
    shot("02-recap-manual"); closeTop()
    plugin:showChronicle()
end)
add(1, function()
    local w = top()
    check("chronicle hides chapters 38-40", w.text:find("Verrat (37)", 1, true) and not w.text:find("(38)", 1, true))
    check("chronicle mentions hidden notes", w.text:find("6 Notiz") ~= nil)
    local label = w.button_table:getButtonById("page").text
    local cur, total = label:match("^(%d+) / (%d+)$")
    log("page label on open:", label)
    check("chronicle opens on its last page", cur ~= nil and cur == total and tonumber(total) > 1)
    check("chronicle starts with chapter 1 (reading order)", w.text:find("Der Hof", 1, true) < w.text:find("Verrat (37)", 1, true))
    shot("03-chronicle-last-page")
    w.button_table:getButtonById("prev").callback() -- ◁
end)
add(1, function()
    local w = top()
    local label = w.button_table:getButtonById("page").text
    log("page label after ◁:", label)
    local cur, total = label:match("^(%d+) / (%d+)$")
    check("◁ goes back one page", tonumber(cur) == tonumber(total) - 1)
    shot("04-chronicle-previous-page")
    w.scroll_widget:scrollToTop()
end)
add(1, function()
    local w = top()
    log("page label at top:", w.button_table:getButtonById("page").text)
    check("label follows other scrolling", w.button_table:getButtonById("page").text:find("^1 / ") ~= nil)
    shot("05-chronicle-first-page"); closeTop()
    Views.showNotesList(plugin.store, function() end)
end)
add(1, function()
    shot("06-notes-list"); closeTop()
    plugin:showBookInfo()
end)
add(1, function()
    shot("07-book-info"); closeTop()
    log("done"); results:close(); UIManager:quit()
end)
run(1)
