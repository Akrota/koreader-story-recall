-- Test (24.10.2026): Band-Zusammenfassung als eigene Anfrage und "neu schreiben" im Reihen-Rückblick.
-- Mit nachgestellter KI-Antwort (keine echte Anfrage).
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/volume-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local VOLUME_TEXT = "Erster Absatz zur Handlung.\n\nZweiter Absatz zu den Figuren.\n\nAm Ende des Bandes ist vieles offen."

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
    local AI = require("storyrecall/ai")
    local Prompt = require("storyrecall/prompt")
    local Series = require("storyrecall/series")
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    local sent = {}
    AI.complete = function(cfg, system, message, schema)
      local mf = io.open(OUT .. "/volume-request.txt", "w"); mf:write(system == Prompt.VOLUME_SYSTEM and "VOLUME\n" or "OTHER\n", message); mf:close()
      if system == Prompt.VOLUME_SYSTEM then
        return require("json").encode({ volume_summary = VOLUME_TEXT })
      end
      return nil, { kind = "http", message = "not in this test" }
    end
    check("Claude accepts the volume template", (function()
      local s = AI.closedSchema(Prompt.VOLUME_SCHEMA); return s.additionalProperties == false
    end)())
    -- Notes for every chapter, book read to the end
    local chapters = require("storyrecall/chapters").upTo(ui, math.huge)
    for _i, ch in ipairs(chapters) do
      p.store:addChapterNote(ch, { summary = "Zusammenfassung " .. ch.index, story_so_far = "Bisher bis " .. ch.index, protagonist = "Mara", entities = {} })
    end
    local last = chapters[#chapters]
    p.store.data.last_chapter_index = last.index
    p.store.data.furthest_chapter = last.index
    p.store.data.chapters = p.store.data.chapters or {}
    p.store.data.chapters[last.key] = { index = last.index, title = last.title, completed_at = os.time() }
    p.store:save()
    log("Kapitel:", #chapters)
    -- 1. Automatically after the last chapter's notes (quietly)
    p.store.data.volume_summary = nil
    p:onChapterNoteAdded(last)
    local tries = 0
    local function waitAuto()
      tries = tries + 1
      if not (p.store.data.volume_summary) and tries < 100 then return UIManager:scheduleIn(0.2, waitAuto) end
      local vs = p.store.data.volume_summary
      check("volume summary written automatically when the book is complete", vs and vs.text == VOLUME_TEXT)
      check("no waiting message in the background", not (top() and top().text and top().text:find("Band-Zusammenfassung wird", 1, true)))
      local rf = io.open(OUT .. "/volume-request.txt"); local req = rf and rf:read("*a") or ""; if rf then rf:close() end
      check("own request with all chapter summaries", req:find("^VOLUME") ~= nil and req:find("Zusammenfassung " .. last.index, 1, true) ~= nil
        and req:find("Zusammenfassung 1:", 1, true) == nil and req:find("%[1%]") ~= nil)
      local summary = Series.volumeSummary(p.store.data)
      check("series recap uses the volume summary", summary and summary.text == VOLUME_TEXT and summary.finished)
      -- 2. Notes re-created: the volume summary belongs to the old notes
      p.store:clearChapterNotes()
      check("re-creating all notes drops the volume summary", p.store.data.volume_summary == nil)
      -- 3. ☰ of the series recap: write the previous volume again
      local book = { series = "Testreihe", series_index = 2, title = "Band 2" }
      local volumes = { { title = "Band 1", series_index = 1, source = "book", file = ui.document.file,
        summary = { text = "Alt", finished = true } } }
      local called
      require("storyrecall/views").showSeriesRecap(book, volumes, { recreate = function(v) called = v end })
      local viewer = top()
      viewer:onShowMenu()
      local dialog = top()
      local entry
      for _r, row in ipairs(dialog.buttons or {}) do for _b, b in ipairs(row) do
        if b.text and b.text:find("Zusammenfassung von Band 1 neu schreiben", 1, true) then entry = b end end end
      check("series recap ☰ offers to write volume 1 again", entry ~= nil and entry.enabled ~= false)
      if entry then entry.callback() end
      check("☰ entry hands over the volume", called and called.series_index == 1)
      while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
      -- an archive-only volume (book no longer on the device) cannot be rewritten
      volumes[1].source, volumes[1].file = "archive", nil
      require("storyrecall/views").showSeriesRecap(book, volumes, { recreate = function() end })
      top():onShowMenu()
      local d2 = top()
      local e2
      for _r, row in ipairs(d2.buttons or {}) do for _b, b in ipairs(row) do
        if b.text and b.text:find("neu schreiben", 1, true) then e2 = b end end end
      check("not offered when the volume's notes are gone", e2 and e2.enabled == false)
      while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
      AI.setKey("gemini", nil)
      f:close(); UIManager:quit()
    end
    waitAuto()
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
