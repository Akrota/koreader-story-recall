-- Nachtest (Windows-Claude): Schrift groesser auf der vorletzten Seite eines Kapitels, dann weiterblaettern.
-- KOReader baut danach erst teilweise neu auf (Inhaltsverzeichnis mit alten Seitenzahlen) und laedt
-- das Buch spaeter neu. Der Lesestand darf dabei nicht ueber das gelesene Kapitel hinaus springen.
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/lesestand2-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end

local function ui() return require("apps/reader/readerui").instance end
local function p() return ui().storyrecall end
local function page() return ui().document:getCurrentPage() end
local function chapterPage(i) return ui().document:getPageFromXPointer(ui().toc.toc[i].xpointer) end
local function furthest() return p().store:getFurthestChapter() or 0 end
local function done() return p().store:countCompletedChapters() end
local function turn() ui():handleEvent(Event:new("GotoViewRel", 1)) end
local function state(t) log(t, "| Seite", page(), "Kap.9 ab", chapterPage(9), "Kap.10 ab", chapterPage(10),
    "| Lesestand", furthest(), "abgeschlossen", done(), "| Instanz", tostring(ui()):sub(-8)) end

local steps = {}
local function nextStep(delay)
    local s = table.remove(steps, 1)
    if not s then f:close(); return UIManager:quit() end
    UIManager:scheduleIn(delay or 1, function()
        local ok, e = pcall(s)
        if not ok then log("ERROR", e); f:close(); return UIManager:quit() end
    end)
end

table.insert(steps, function()
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget().name ~= "ReaderUI" do
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
    ui():handleEvent(Event:new("GotoPage", 1))
    p().store.data.furthest_chapter = 1
    local target = chapterPage(9) - 2
    while page() < target do turn() end
    state("vorletzte Seite Kapitel 8")
    check("Ausgangslage: Lesestand Kapitel 8", furthest() == 8)
    ui():handleEvent(Event:new("SetFontSize", ui().document.configurable.font_size + 8))
    nextStep(1)
end)
table.insert(steps, function()
    state("1 s nach Schrift groesser")
    check("Schriftaenderung allein erhoeht den Lesestand nicht", furthest() == 8 and done() == 7)
    turn()
    state("eine Seite weiter (Teil-Neuaufbau)")
    check("eine Seite weiter: hoechstens Kapitel 9", furthest() <= 9)
    nextStep(25)
end)
table.insert(steps, function()
    state("25 s spaeter (nach dem Neuladen?)")
    check("nach dem Neuladen hoechstens Kapitel 9", furthest() <= 9)
    turn()
    state("nach dem Neuladen eine Seite weiter")
    check("danach weiter normal: hoechstens Kapitel 9", furthest() <= 9)
    nextStep(1)
end)

UIManager:scheduleIn(4, function() nextStep(0) end)
