-- Test (24.10.2026): Live-Fortschritt. Ist das Story-Recall-Menue offen, wird die Statuszeile
-- nach jedem fertigen Paket und bei jedem Statuswechsel neu gezeichnet. In einem Untermenue
-- oder bei geschlossenem Menue passiert nichts. Mit nachgestellter KI-Antwort (keine echte Anfrage).
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/live-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end

local function finish()
    f:close()
    UIManager:quit()
end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
    local AIMenu = require("storyrecall/aimenu")
    local json = require("json")
    local processor = p.processor
    processor:stop("idle")

    -- Menue oeffnen und zu Story Recall gehen
    ui.menu:onShowMenu()
    local menu = ui.menu.menu_container[1]
    local found = false
    for i, tab in ipairs(menu.tab_item_table) do
      for _j, item in ipairs(tab) do
        if item.text == "Story Recall" then
          menu:switchMenuTab(i)
          menu:onMenuSelect(item)
          found = true
          break
        end
      end
      if found then break end
    end
    check("Story-Recall-Menue geoeffnet", found)
    local has_status = false
    for _i, item in ipairs(menu.item_table) do
      if item.storyrecall_status then has_status = true end
    end
    check("Statuszeile im offenen Menue", has_status)

    -- updateItems mitzaehlen
    local calls = 0
    local original = menu.updateItems
    menu.updateItems = function(m, ...) calls = calls + 1; return original(m, ...) end
    local function shownStatus()
      for _i, w in ipairs(menu.item_group) do
        if type(w) == "table" and w.item and w.item.storyrecall_status then
          return w.item.text_func()
        end
      end
    end

    local steps = {}
    local function step(fn) table.insert(steps, fn) end
    local function run()
      local fn = table.remove(steps, 1)
      if not fn then
        menu.updateItems = original
        processor:stop("idle")
        log("Fertig.")
        return finish()
      end
      fn()
      UIManager:scheduleIn(0.5, run)
    end

    -- 1. Statuswechsel "Pause: ueberlastet"
    step(function() calls = 0; processor:setState("waiting_retry", "server") end)
    step(function()
      check("Statuswechsel zeichnet das offene Menue neu", calls == 1)
      local s = shownStatus() or ""
      log("Status:", s)
      check("Angezeigte Statuszeile ist aktuell", s == AIMenu.statusText(p))
    end)
    -- 2. Gleicher Status noch einmal: kein unnoetiges Neuzeichnen
    step(function() calls = 0; processor:setState("waiting_retry", "server") end)
    step(function() check("Gleicher Status: kein Neuzeichnen", calls == 0) end)
    -- 3. Fertiges Paket (nachgestellte Antwort): Zaehler steigt im offenen Menue
    local before = p.store:countChapterNotes()
    local chapters = require("storyrecall/chapters").upTo(ui, math.huge)
    local target
    for _i, ch in ipairs(chapters) do
      if not p.store:getChapterNote(ch.key) then target = ch; break end
    end
    step(function()
      calls = 0
      processor.cfg = processor.cfg or { provider = "gemini", model = "test" }
      local answer = json.encode({ chapters = { {
        index = target.index, summary = "Live-Test: Mara findet den Schluessel.", story_so_far = "Bisher.", protagonist = "Mara", entities = {},
      } } })
      processor:handleResult({ batch = { target }, last_index = chapters[#chapters].index }, { text = answer })
      if processor.next_task then UIManager:unschedule(processor.next_task); processor.next_task = nil end
    end)
    step(function()
      check("Neue Notiz gespeichert", p.store:countChapterNotes() == before + 1)
      check("Fertiges Paket zeichnet das offene Menue neu", calls >= 1)
      local s = shownStatus() or ""
      log("Status:", s)
      check("Zaehler im Menue zeigt die neue Zahl", s:find(tostring(before + 1) .. "/", 1, true) ~= nil)
    end)
    -- 3b. Unbrauchbare Antwort (wie Claude am 24.10.: leere Kapitel-Liste): eigene Statuszeile
    step(function()
      calls = 0
      local next_ch
      for _i, ch in ipairs(chapters) do
        if not p.store:getChapterNote(ch.key) then next_ch = ch; break end
      end
      processor.retries = 0
      processor:handleResult({ batch = { next_ch }, last_index = chapters[#chapters].index }, { text = '{"chapters": []}' })
      if processor.next_task then UIManager:unschedule(processor.next_task); processor.next_task = nil end
    end)
    step(function()
      local s = shownStatus() or ""
      log("Status:", s)
      check("Unbrauchbare Antwort: Status 'Antwort unbrauchbar' statt 'ueberlastet'",
        processor.message == "format" and s:find("unbrauchbar", 1, true) ~= nil)
      check("Unbrauchbare Antwort: Menue neu gezeichnet", calls >= 1)
    end)
    -- 3c. Platzhalter "x" statt Zusammenfassung (Claude, 24.10.): nicht speichern, alte beim Oeffnen entfernen
    step(function()
      local Prompt = require("storyrecall/prompt")
      local Store = require("storyrecall/store")
      local one = { chapters[1] }
      check("Platzhalter 'x' wird nicht als Notiz angenommen",
        Prompt.validate({ chapters = { { index = chapters[1].index, summary = "x", story_so_far = "x", entities = {} } } }, one) == nil)
      check("Echte Zusammenfassung wird angenommen",
        Prompt.validate({ chapters = { { index = chapters[1].index, summary = "Mara findet den Schluessel im Keller.", entities = {} } } }, one) ~= nil)
      local path = OUT .. "/platzhalter.epub"
      os.execute("rm -rf '" .. OUT .. "/platzhalter.sdr'")
      local s = Store.open(path)
      s.data.ai_chapters = {
        a = { index = 1, key = "a", summary = "x", story_so_far = "x", entities = {} },
        b = { index = 2, key = "b", summary = "Mara findet den Schluessel im Keller.",
              story_so_far = "Was Beute bringt, ist offen.}, {", entities = {} },
      }
      s:markDirty(); s:save()
      local again = Store.open(path)
      check("Beim Oeffnen: Platzhalter-Notiz entfernt, echte bleibt",
        again:getChapterNote("a") == nil and again:getChapterNote("b") ~= nil and again:countChapterNotes() == 1)
      check("Beim Oeffnen: Reste '}, {' am Ende entfernt",
        again:getChapterNote("b").story_so_far == "Was Beute bringt, ist offen.")
      -- Neue Antworten: Reste am Ende abgeschnitten, normale Anfuehrungszeichen bleiben
      local notes = Prompt.validate({ chapters = { { index = chapters[1].index,
        summary = 'Mara sagt "Komm mit" und geht.', story_so_far = "Es bleibt offen.}, {", entities = {} } } }, one)
      local n = notes and notes[chapters[1].index]
      check("Neue Antwort: Reste '}, {' abgeschnitten", n and n.story_so_far == "Es bleibt offen.")
      check("Neue Antwort: Anfuehrungszeichen im Text bleiben", n and n.summary == 'Mara sagt "Komm mit" und geht.')
    end)
    -- 3d. Alles fertig und nichts laeuft: "tippen zum Neuerstellen" statt "tippen zum Starten"
    step(function()
      require("storyrecall/ai").setKey("gemini", "test-key-not-real")
      p:setSetting("ai_provider", "gemini")
      local saved = p.store.data.ai_chapters
      p.store.data.ai_chapters = {}
      for _i, ch in ipairs(chapters) do
        p.store.data.ai_chapters[ch.key] = { key = ch.key, index = ch.index, summary = "Zusammenfassung von Kapitel " .. ch.index, entities = {} }
      end
      processor:setState("idle")
      local s = AIMenu.statusText(p)
      log("Status:", s)
      check("Alle Kapitel fertig: 'tippen zum Neuerstellen'", s:find("Neuerstellen", 1, true) ~= nil)
      p.store.data.ai_chapters = saved
      check("Kapitel fehlen: 'tippen zum Starten'", AIMenu.statusText(p):find("Starten", 1, true) ~= nil)
    end)
    -- 4. Untermenue (Einstellungen) offen: kein Neuzeichnen
    step(function()
      for _i, item in ipairs(menu.item_table) do
        if item.sub_item_table or item.sub_item_table_func then
          if not item.storyrecall_status then menu:onMenuSelect(item); break end
        end
      end
      calls = 0
      processor:setState("waiting_network")
    end)
    step(function()
      local in_sub = true
      for _i, item in ipairs(menu.item_table) do if item.storyrecall_status then in_sub = false end end
      check("Untermenue offen", in_sub)
      check("Im Untermenue: kein Neuzeichnen", calls == 0)
    end)
    -- 5. Menue geschlossen: kein Neuzeichnen, kein Fehler
    step(function()
      ui.menu:onCloseReaderMenu()
      calls = 0
      processor:setState("done")
    end)
    step(function()
      check("Menue geschlossen: kein Neuzeichnen", calls == 0)
      check("KOReader laeuft weiter", ui.document ~= nil)
    end)
    run()
  end)
  if not ok then log("ERROR", e); finish() end
end)
