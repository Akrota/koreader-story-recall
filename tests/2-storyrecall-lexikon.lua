-- Nachtest 0.9.4 (Windows-Claude): Story-Lexikon, Fenster-Reihenfolge, Tipp ausserhalb, Sprung zur Textstelle.
-- Laeuft auf reise.epub mit nachgebauten KI-Notizen. Tipps kommen als echte Maus-Klicks (xdotool).
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/lexikon-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end

local ui, p, sort_was
local function top() return UIManager:getTopmostVisibleWidget() end
local function name(w)
    if not w then return "nil" end
    if w.name == "ReaderUI" then return "Buch" end
    local inner = w[1]
    return (w.title or (inner and inner.title) or w.name or tostring(w):sub(1, 20))
end
local function stack()
    local t = {}
    for i = #UIManager._window_stack, 1, -1 do table.insert(t, name(UIManager._window_stack[i].widget)) end
    return table.concat(t, " > ")
end
local function shot(n) os.execute("import -display :99 -window root " .. OUT .. "/lexikon-" .. n .. ".png") end
local function click(x, y) os.execute(string.format("DISPLAY=:99 xdotool mousemove %d %d click 1", x, y)) end
local function button(widget, text)
    local bt = widget.button_table or widget.buttontable
    for _r, row in ipairs(bt.buttons_layout) do
        for _c, b in ipairs(row) do
            if b.text and b.text:find(text, 1, true) then return b end
        end
    end
end

local steps = {}
local function nextStep(delay)
    local s = table.remove(steps, 1)
    if not s then f:close(); return UIManager:quit() end
    UIManager:scheduleIn(delay or 1, function()
        local ok, e = pcall(s)
        if not ok then log("ERROR", e); f:close(); return UIManager:quit() end
    end)
end
local function step(fn) table.insert(steps, function() fn(); nextStep(1.5) end) end

local recap, lexicon, list, profile_viewer

-- FIX=1: Loesungsvorschlag testen, ohne das Plugin zu aendern (Liste schliesst sich nicht beim Antippen)
local function applyFix()
    if os.getenv("LEXIKON_FIX") ~= "1" then return end
    local Context = require("storyrecall/context")
    local orig = Context.choose
    Context.choose = function(...)
        local menu, container = orig(...)
        menu.close_callback = nil
        menu.onCloseAllMenus = function() UIManager:close(container) return true end
        return menu, container
    end
end

step(function()
    ui = require("apps/reader/readerui").instance
    applyFix()
    p = ui.storyrecall
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
    local toc = ui.toc.toc
    -- Notizen fuer Kapitel 1-4: eine Figur (mit Level-Variante), ein Ort, ein Gegenstand
    for i = 1, 4 do
        p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
            summary = "Zusammenfassung " .. i, story_so_far = "Bisher bis Kapitel " .. i .. ".",
            protagonist = "Elias",
            entities = {
                { name = i == 2 and "Elias (Held)" or "Elias", type = "character", aliases = {}, facts = { "Fakt " .. i } },
                { name = "Graufels", type = i == 3 and "term" or "place", aliases = {}, facts = { "Ort " .. i } },
                { name = i == 4 and "Raptor – Level 46" or "Raptor", type = "character", aliases = {}, facts = { "Tier " .. i } },
            },
        })
        p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title })
    end
    p.store.data.furthest_chapter = 5
    ui:handleEvent(Event:new("GotoPage", ui.document:getPageFromXPointer(toc[5].xpointer) + 1))
    local profiles = p.store:getEntityProfiles(4)
    local names = {}
    for _i, pr in ipairs(profiles) do table.insert(names, pr.name .. "/" .. pr.type) end
    log("Profile:", table.concat(names, ", "))
    check("Doppelte zusammengefasst (Elias, Graufels, Raptor = 3 Eintraege)", #profiles == 3)
    local graufels
    for _i, pr in ipairs(profiles) do if pr.name == "Graufels" then graufels = pr end end
    check("Haeufigster Typ gewinnt (Graufels = Ort)", graufels and graufels.type == "place")
    p:showRecap()
end)
step(function()
    recap = top()
    log("Stapel:", stack())
    check("Rueckblick offen", name(recap) ~= "Buch")
    check("Knopf Story-Lexikon da", button(recap, "Story-Lexikon") ~= nil)
    check("Knopf + Notiz da", button(recap, "Notiz") ~= nil)
    shot("1-rueckblick")
    button(recap, "Story-Lexikon").callback()
end)
step(function()
    lexicon = top()
    log("Stapel:", stack())
    check("Lexikon ueber dem Rueckblick", lexicon ~= recap and UIManager:isWidgetShown(recap))
    shot("2-kategorien")
    -- Sortierung auf "Häufigkeit" stellen (Kobo 23.10.: Liste blieb alphabetisch)
    local was = p:getSetting("lexicon_sort")
    p:setSetting("lexicon_sort", nil)
    button(lexicon, "Sortierung").callback()
    lexicon = top()
    check("Sortierknopf zeigt Häufigkeit", button(lexicon, "Sortierung: Häufigkeit") ~= nil)
    sort_was = was
    button(lexicon, "Figuren").callback()
end)
step(function()
    list = top()
    log("Stapel:", stack())
    check("Liste ueber dem Lexikon", list ~= lexicon and UIManager:isWidgetShown(lexicon))
    shot("3-liste")
    local menu = list[1]
    log("Listeneintraege:", #menu.item_table, menu.item_table[1] and menu.item_table[1].text)
    -- nach Häufigkeit: die Zahl der Kapitel fällt von oben nach unten nie an
    local profiles = p:getProfiles()
    local count = {}
    for _i, pr in ipairs(profiles) do
        count[pr.name] = pr.chapter_count
    end
    local order, sorted = {}, true
    for i, it in ipairs(menu.item_table) do
        order[#order + 1] = it.text .. "=" .. tostring(count[it.text])
        if i > 1 and (count[it.text] or 0) > (count[menu.item_table[i - 1].text] or 0) then sorted = false end
    end
    log("Reihenfolge:", table.concat(order, ", "))
    check("Figuren nach Häufigkeit sortiert", sorted and (count[menu.item_table[1].text] or 0) > 0)
    p:setSetting("lexicon_sort", sort_was)
    menu:onMenuSelect(menu.item_table[1])
end)
step(function()
    profile_viewer = top()
    log("Stapel:", stack())
    check("Profil ueber der Liste", profile_viewer ~= list and UIManager:isWidgetShown(list))
    shot("4-profil")
    button(profile_viewer, "Schlie").callback()
end)
step(function()
    log("Stapel:", stack())
    check("Profil zu -> Liste oben", top() == list)
    -- Tipp ausserhalb der Liste (Liste ist 92 % x 88 %, also oben links in der Ecke)
    click(10, 10)
end)
step(function()
    log("Stapel:", stack())
    check("Tipp ausserhalb schliesst nur die Liste -> Lexikon oben", top() == lexicon)
    check("Rueckblick noch offen", UIManager:isWidgetShown(recap))
    button(lexicon, "Schlie").callback()
end)
step(function()
    log("Stapel:", stack())
    check("Lexikon zu -> Rueckblick oben", top() == recap)
    -- Textstelle: Lexikon -> Alle -> Eintrag -> Textstellen -> Stelle
    button(recap, "Story-Lexikon").callback()
end)
step(function()
    lexicon = top()
    button(lexicon, "Alle").callback()
end)
step(function()
    list = top()
    local menu = list[1]
    local idx = 1
    for i, item in ipairs(menu.item_table) do if item.text == "Elias" then idx = i end end
    menu:onMenuSelect(menu.item_table[idx])
end)
step(function()
    profile_viewer = top()
    button(profile_viewer, "Textstellen").callback()
end)
step(function()
    local passages = top()
    log("Stapel:", stack())
    local items = passages.item_table or {}
    log("Textstellen:", #items)
    check("Textstellen gefunden", #items > 0)
    if #items > 0 then
        log("Sprung zu Seite", items[1].mandatory)
        items[1].callback()
    end
end)
step(function()
    log("Stapel:", stack(), "| Seite", ui.document:getCurrentPage())
    check("Nach dem Sprung: nur noch das Buch offen", top() and top().name == "ReaderUI" and #UIManager._window_stack == 1)
    shot("5-nach-sprung")
end)

UIManager:scheduleIn(4, function() nextStep(0) end)
