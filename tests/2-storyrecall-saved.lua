-- Test (24./25.10.2026): Fruehere KI-Notizen. "Alle KI-Notizen neu erstellen" hebt den bisherigen Stand auf
-- (bis zu zwei pro Anbieter), "Fruehere KI-Notizen" tauscht zurueck oder loescht einen Stand, ohne neue Anfragen.
-- Eigene Notizen und Lesestelle bleiben unberuehrt. Mit nachgestellter KI (keine echte Anfrage).
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/saved-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
    local AI = require("storyrecall/ai")
    local AIMenu = require("storyrecall/aimenu")
    local Store = require("storyrecall/store")
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    p:setSetting("ai_when", "manual") -- keine automatische Verarbeitung waehrend des Tests
    local requests = 0
    AI.complete = function() requests = requests + 1; return nil, { kind = "http", message = "not in this test" } end

    local store = p.store
    local chapters = require("storyrecall/chapters").upTo(ui, math.huge)
    local function fill(provider, model, n, tag)
      for i = 1, n do
        store:addChapterNote(chapters[i], { summary = tag .. ": Zusammenfassung von Kapitel " .. i, story_so_far = tag .. " bisher " .. i,
          protagonist = "Mara", entities = {}, provider = provider, model = model })
      end
      store.data.volume_summary = { text = tag .. "-Band", chapter_index = n }
      store:save()
    end
    local function firstSummary() local n = store:getChapterNote(chapters[1].key); return n and n.summary or "" end
    local function find(model)
      for _i, s in ipairs(store:getSavedSets()) do if s.model == model then return s end end
    end
    local function countOf(provider)
      local n = 0
      for _i, s in ipairs(store:getSavedSets()) do if s.provider == provider then n = n + 1 end end
      return n
    end
    store:addNote(chapters[1], "Meine eigene Notiz", "user")
    local own_before = #(store.data.notes or {})
    store.data.furthest_chapter = 2
    store:save()

    -- 1. Gemini-Notizen vorhanden
    fill("gemini", "gemini-3.8-flash", 3, "GEMINI")
    local prov, model, count = store:currentSetInfo()
    check("Aktueller Stand erkannt (gemini, 3 Kapitel)", prov == "gemini" and model == "gemini-3.8-flash" and count == 3)
    check("Menue 'Fruehere KI-Notizen' anfangs ausgegraut", not AIMenu.savedNotesItem(p).enabled_func())

    -- 2. "Alle KI-Notizen neu erstellen" ueber die echte Rueckfrage
    AIMenu.confirmRecreate(p)
    local box = top()
    check("Rueckfrage erwaehnt 'Fruehere KI-Notizen'", box and box.text and box.text:find("Frühere KI%-Notizen") ~= nil)
    if box and box.ok_callback then box.ok_callback(); UIManager:close(box) end
    check("Nach Neu-Erstellen: keine aktuellen KI-Notizen", store:countChapterNotes() == 0)
    check("Gemini-Stand aufgehoben", #store:getSavedSets() == 1 and find("gemini-3.8-flash").count == 3)
    check("Menue 'Fruehere KI-Notizen' jetzt aktiv", AIMenu.savedNotesItem(p).enabled_func())

    -- 3. Claude erstellt neu, dann zurueck auf Gemini (ohne Anfrage) und wieder auf Claude
    p.processor:stop("stopped")
    fill("anthropic", "claude-sonnet-5-5", 2, "CLAUDE")
    requests = 0
    p:restoreSavedNotes(find("gemini-3.8-flash").id)
    check("Gemini wieder da (3 Kapitel, Band-Zusammenfassung)", store:countChapterNotes() == 3
      and firstSummary():find("^GEMINI") ~= nil and store.data.volume_summary.text == "GEMINI-Band")
    check("Claude-Stand dafuer aufgehoben", #store:getSavedSets() == 1 and find("claude-sonnet-5-5") ~= nil)
    check("Keine KI-Anfrage beim Wiederherstellen", requests == 0)
    p:restoreSavedNotes(find("claude-sonnet-5-5").id)
    check("Claude wieder da, Gemini aufgehoben", firstSummary():find("^CLAUDE") ~= nil and find("gemini-3.8-flash") ~= nil)

    -- 4. Bis zu zwei Staende pro Anbieter: Claude Sonnet -> Haiku -> Opus
    store:stashChapterNotes()                        -- Sonnet beiseite
    fill("anthropic", "claude-haiku-5-5", 3, "HAIKU")
    check("Kein Hinweis aufs Loeschen bei einem Claude-Stand", AIMenu.dropWarning(p) == "")
    store:stashChapterNotes()                        -- Haiku beiseite (2 Claude-Staende)
    fill("anthropic", "claude-opus-5-5", 3, "OPUS")
    check("Zwei Claude-Staende aufgehoben (Sonnet, Haiku)", countOf("anthropic") == 2
      and find("claude-sonnet-5-5") ~= nil and find("claude-haiku-5-5") ~= nil)
    local warning = AIMenu.dropWarning(p)
    log("Hinweis:", warning)
    check("Hinweis nennt den aeltesten Claude-Stand (Sonnet)", warning:find("claude%-sonnet%-5%-5") ~= nil)
    store:stashChapterNotes()                        -- Opus beiseite: Sonnet faellt weg
    check("Dritter Claude-Stand: aeltester (Sonnet) faellt weg", countOf("anthropic") == 2
      and find("claude-sonnet-5-5") == nil and find("claude-opus-5-5") ~= nil and find("claude-haiku-5-5") ~= nil)
    check("Gemini-Stand bleibt davon unberuehrt", find("gemini-3.8-flash") ~= nil)

    -- 5. Verwenden eines Claude-Stands bei Claude als aktuellem Stand: nichts faellt weg
    fill("anthropic", "claude-sonnet-5-5", 2, "CLAUDE")
    check("Kein Hinweis, wenn ein Stand desselben Anbieters zurueckgeholt wird",
      AIMenu.dropWarning(p, find("claude-haiku-5-5")) == "")
    p:restoreSavedNotes(find("claude-haiku-5-5").id)
    check("Haiku zurueck, Sonnet und Opus aufgehoben", firstSummary():find("^HAIKU") ~= nil
      and find("claude-sonnet-5-5") ~= nil and find("claude-opus-5-5") ~= nil and countOf("anthropic") == 2)

    -- 6. Einzelnen Stand loeschen ueber das Menue (Knopf "Loeschen")
    local items = AIMenu.savedNotesItem(p).sub_item_table_func()
    log("Menue:", items[1] and items[1].text, "|", items[#items] and items[#items].text)
    check("Menue: drei Staende und 'Alle loeschen'", #items == 4 and items[#items].text:find("Alle") ~= nil)
    local target
    for _i, item in ipairs(items) do if item.text:find("claude%-opus%-5%-5") then target = item end end
    target.callback()
    box = top()
    local delete_button
    for _i, row in ipairs(box.other_buttons or {}) do
      for _j, b in ipairs(row) do if b.text == "Löschen" then delete_button = b end end
    end
    check("Rueckfrage hat 'Verwenden' und 'Loeschen'", box.ok_text == "Verwenden" and delete_button ~= nil)
    delete_button.callback()
    check("Opus-Stand einzeln geloescht, die anderen bleiben", find("claude-opus-5-5") == nil
      and find("claude-sonnet-5-5") ~= nil and find("gemini-3.8-flash") ~= nil)

    -- 7. Eigene Notizen und Lesestelle unberuehrt
    check("Eigene Notizen unveraendert", #(store.data.notes or {}) == own_before)
    check("Lesestelle unveraendert", store.data.furthest_chapter == 2)

    -- 8. Bleibt nach dem Schliessen erhalten
    store:save()
    local again = Store.open(ui.document.file)
    check("Nach erneutem Oeffnen: Stand und aufgehobene Saetze da",
      again:countChapterNotes() == 3 and #again:getSavedSets() == 2)

    -- 9. Alter Speicherstand (bis 24.10.: ein Satz pro Anbieter, ohne Liste) wird uebernommen
    store.data.ai_sets = { anthropic = { ai_chapters = { x = { index = 1, summary = "Alter Claude-Stand von gestern" } },
      provider = "anthropic", model = "claude-sonnet-5-5", count = 1, saved = 100 } }
    store:markDirty(); store:save()
    local old = Store.open(ui.document.file)
    local sets = old:getSavedSets()
    check("Alter Speicherstand: als Liste uebernommen, mit Nummer", #sets == 1 and sets[1].id ~= nil and sets[1].model == "claude-sonnet-5-5")
    store = old; p.store = old
    p:restoreSavedNotes(sets[1].id)
    check("Alter Stand laesst sich verwenden", old:getChapterNote("x") ~= nil)

    -- 10. Alle loeschen
    old:deleteSavedSets(); old:save()
    check("Alle loeschen: keine aufgehobenen Saetze, aktuelle bleiben", #old:getSavedSets() == 0 and old:countChapterNotes() == 1)
    check("Book-Menue enthaelt 'Fruehere KI-Notizen'", (function()
      for _i, item in ipairs(p:getBookMenu()) do if item.text == "Frühere KI-Notizen" then return true end end
    end)() == true)
  end)
  if not ok then log("ERROR", e) end
  f:close()
  UIManager:quit()
end)
