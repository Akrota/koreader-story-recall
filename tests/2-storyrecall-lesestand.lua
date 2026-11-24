-- Nachtest (Windows-Claude): Lesestand im Bildlauf-Modus (M11) und nach Schriftaenderung (M12).
-- Laeuft auf reise.epub (40 Kapitel).
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/lesestand-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end

local ui, p
local function page() return ui.document:getCurrentPage() end
local function chapterPage(i) return ui.document:getPageFromXPointer(ui.toc.toc[i].xpointer) end
local function furthest() return p.store:getFurthestChapter() or 0 end
local function turn() ui:handleEvent(Event:new("GotoViewRel", 1)) end
local function fontSize() return ui.document.configurable.font_size end
local function setFont(size) ui:handleEvent(Event:new("SetFontSize", size)) end

local steps = {}
local function nextStep(delay)
    local s = table.remove(steps, 1)
    if not s then f:close(); return UIManager:quit() end
    UIManager:scheduleIn(delay or 1, function()
        local ok, e = pcall(s)
        if not ok then log("ERROR", e); f:close(); return UIManager:quit() end
    end)
end

-- Reihenfolge der Ereignisse mitschreiben
local order = {}
local function hook()
    local up, rr = p.onPageUpdate, p.onDocumentRerendered
    p.onPageUpdate = function(self, n) table.insert(order, "PageUpdate " .. tostring(n)); return up(self, n) end
    p.onDocumentRerendered = function(self) table.insert(order, "DocumentRerendered"); return rr(self) end
end

-- M11: Bildlauf-Modus, von Kapitel 1 bis in Kapitel 4 scrollen
table.insert(steps, function()
    ui = require("apps/reader/readerui").instance
    p = ui.storyrecall
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget().name ~= "ReaderUI" do
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
    hook()
    ui:handleEvent(Event:new("GotoPage", 1))
    p.store.data.furthest_chapter = 1
    ui:handleEvent(Event:new("SetViewMode", "scroll"))
    nextStep(2)
end)
table.insert(steps, function()
    log("Ansicht:", ui.view.view_mode)
    ui:handleEvent(Event:new("GotoPage", 1))
    local target = chapterPage(4) + 1
    local n = 0
    while page() < target and n < 500 do turn(); n = n + 1 end
    log("M11: nach", n, "Bildlauf-Schritten auf Seite", page(), "Ziel", target, "Lesestand", furthest(),
        "abgeschlossen", p.store:countCompletedChapters())
    check("M11: Bildlauf zaehlt als Weiterlesen (Lesestand Kapitel 4)", furthest() == 4)
    check("M11: Kapitel 1-3 abgeschlossen", p.store:countCompletedChapters() >= 3)
    ui:handleEvent(Event:new("SetViewMode", "page"))
    nextStep(2)
end)

-- M12: auf der vorletzten Seite von Kapitel 5 die Schrift kleiner stellen
table.insert(steps, function()
    log("Ansicht:", ui.view.view_mode)
    local target = chapterPage(6) - 2
    while page() < target do turn() end
    log("M12: Seite", page(), "Kapitel 6 beginnt auf", chapterPage(6), "Lesestand", furthest())
    check("M12: vor der Schriftaenderung Lesestand Kapitel 5", furthest() == 5)
    order = {}
    setFont(fontSize() - 6)
    nextStep(3)
end)
table.insert(steps, function()
    log("M12: Ereignisse:", table.concat(order, ", "))
    log("M12: nach kleinerer Schrift Seite", page(), "Kapitel 6 beginnt auf", chapterPage(6), "Lesestand", furthest())
    check("M12: kleinere Schrift erhoeht den Lesestand nicht", furthest() == 5)
    setFont(fontSize() + 6)
    nextStep(3)
end)

-- M12b: vorletzte Seite von Kapitel 8, Schrift GROESSER (Seitenzahl springt nach vorn), dann 20 s warten
table.insert(steps, function()
    local target = chapterPage(9) - 2
    while page() < target do turn() end
    log("M12b: Seite", page(), "Kapitel 9 beginnt auf", chapterPage(9), "Lesestand", furthest(),
        "abgeschlossen", p.store:countCompletedChapters())
    check("M12b: vor der Schriftaenderung Lesestand Kapitel 8", furthest() == 8)
    order = {}
    setFont(fontSize() + 8)
    nextStep(1)
end)
table.insert(steps, function()
    log("M12b nach 1 s: Ereignisse:", table.concat(order, ", "), "| Seite", page(), "Lesestand", furthest(),
        "abgeschlossen", p.store:countCompletedChapters())
    nextStep(20)
end)
table.insert(steps, function()
    log("M12b nach 21 s: Ereignisse:", table.concat(order, ", "), "| Seite", page(), "Kapitel 9 beginnt auf",
        chapterPage(9), "Lesestand", furthest(), "abgeschlossen", p.store:countCompletedChapters())
    check("M12b: groessere Schrift erhoeht den Lesestand nicht", furthest() == 8)
    check("M12b: kein Kapitel durch die Schriftaenderung abgeschlossen", p.store:countCompletedChapters() == 7)
    nextStep(1)
end)

UIManager:scheduleIn(4, function() nextStep(0) end)
