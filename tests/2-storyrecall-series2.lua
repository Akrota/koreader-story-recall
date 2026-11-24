-- Test: series archive, missing volumes, linking translations, internet summary,
-- notes language, earlier volumes in the prompt, "already read elsewhere".
-- Uses made-up series data only (no real book text is shown).
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/series2-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end

local function volumeData(text_prefix, chapters, furthest)
    local data = { ai_chapters = {}, furthest_chapter = furthest, chapters = {} }
    for i = 1, chapters do
        -- Chapters before the furthest one are finished; the furthest one only at the end of the book.
        if i < furthest or (i == furthest and furthest == chapters) then
            data.chapters["k" .. i] = { index = i, completed_at = 1 }
        end
        data.ai_chapters["k" .. i] = { key = "k" .. i, index = i, title = "Kapitel " .. i, summary = "S" .. i,
            story_so_far = text_prefix .. " bis Kapitel " .. i .. ".",
            volume_summary = i == chapters and (text_prefix .. ": ganzer Band.") or nil }
    end
    return data
end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local Series = require("storyrecall/series")
    closeTop(); closeTop()
    os.remove(Series.archivePath())

    -- 1. Archive keeps a volume after its book is gone
    local author = "Ada Testautorin"
    local vol1 = { title = "Archivreihe 1", authors = author, series = "Archivreihe", series_index = 1, language = "de" }
    check("finished volume archived", Series.archive(vol1, volumeData("Band eins", 5, 5)))
    check("unchanged volume not rewritten", Series.archive(vol1, volumeData("Band eins", 5, 5)) == false)
    local vol2 = { title = "Archivreihe 2", authors = author, series = "Archivreihe", series_index = 2, language = "de" }
    local found = Series.previousVolumes("/nowhere/testreihe2.epub", vol2)
    check("deleted book found via archive", #found == 1 and found[1].source == "archive" and found[1].summary.text == "Band eins: ganzer Band.")
    -- An unfinished volume contributes only its finished chapters (reading chapter 3: up to 2)
    local vol2_data = volumeData("Band zwei", 6, 3)
    Series.archive(vol2, vol2_data)
    local vol4 = { title = "Archivreihe 4", authors = author, series = "Archivreihe", series_index = 4, language = "de" }
    found = Series.previousVolumes("/nowhere/testreihe4.epub", vol4)
    for _, v in ipairs(found) do log("found", v.series_index, v.source, v.summary.text, v.summary.finished) end
    check("volume 3 missing: volumes 1 and 2, no error", #found == 2 and found[2].summary.text == "Band zwei bis Kapitel 2." and found[2].summary.finished == false)

    -- 2. Primal Hunter 3 is not on the device: nothing breaks
    local ph3 = { title = "Primal Hunter 3", authors = "Zogarth", series = "Primal Hunter", series_index = 3, language = "de" }
    local ok_ph3, ph3_found = pcall(Series.previousVolumes, "/nowhere/Primal Hunter 3.epub", ph3)
    check("Primal Hunter 3 missing: lookup works", ok_ph3 and type(ph3_found) == "table")
    log("Primal Hunter volumes found for vol 3:", ok_ph3 and #ph3_found)

    -- 3. Translation with another series name
    local orig = { title = "Test Saga 1", authors = author, series = "Test Saga", series_index = 1, language = "en" }
    Series.archive(orig, volumeData("Original one", 4, 4))
    local transl = { title = "Die Saga 2", authors = author, series = "Die Saga", series_index = 2, language = "de" }
    local candidates = Series.otherNamedCandidates("/nowhere/x.epub", transl)
    local saga
    for _, c in ipairs(candidates) do if c.key == "test saga" then saga = c end end
    check("other-named series by same author offered", saga ~= nil and saga.language == "en")
    check("asked automatically for other language", p:linkCandidate(transl, true) ~= nil)
    local same_lang = { title = "Andere 2", authors = author, series = "Andere Reihe", series_index = 2, language = "de" }
    local auto = p:linkCandidate(same_lang, true)
    check("not asked automatically within one language", auto == nil or auto.language ~= "de")
    Series.link(transl, "test saga")
    found = Series.previousVolumes("/nowhere/x.epub", transl)
    check("linked series found", #found == 1 and found[1].summary.text == "Original one: ganzer Band.")

    -- 4. Internet summary (fake provider answer, no network)
    local AI = require("storyrecall/ai")
    local WebSummary = require("storyrecall/websummary")
    local sent
    local orig_post = AI.post
    AI.post = function(url, headers, body)
        sent = { url = url, body = body }
        return { stop_reason = "end_turn", content = {
            { type = "text", text = "Ich suche.\n" },
            { type = "server_tool_use" },
            { type = "text", text = "### Band 1: Erster Teil\nErfundene Handlung eins.\n### Band 2: Zweiter Teil\nErfundene Handlung zwei.\n### Band 3: Verboten\nDas darf nicht gespeichert werden.",
              citations = { { type = "web_search_result_location", url = "https://verlag.example/reihe", title = "Verlag" } } },
        } }
    end
    local web_book = { title = "Webreihe 3", authors = "Bea Beispiel", series = "Webreihe", series_index = 3, language = "de" }
    local cfg = { provider = "anthropic", model = "claude-opus-5-5", key = "test-key-not-real" }
    local volumes, sources = WebSummary.run(cfg, web_book, "de")
    check("web search tool requested", sent and sent.url:find("anthropic", 1, true) and sent.body.tools[1].name == "web_search")
    check("only earlier volumes kept", volumes and #volumes == 2 and volumes[2].series_index == 2)
    check("sources collected", sources and sources[1] == "Verlag")
    for _, v in ipairs(volumes) do
        Series.archiveExternal(web_book, v.series_index, { title = v.title, authors = web_book.authors, text = v.text, finished = true, source = "internet", sources = sources })
    end
    found = Series.previousVolumes("/nowhere/web3.epub", web_book)
    check("internet volumes in series recap", #found == 2 and found[1].source == "internet")
    require("storyrecall/views").showSeriesRecap(web_book, found)
    local w = top()
    check("marked as from the internet, with sources", w and w.text:find("aus dem Internet", 1, true) and w.text:find("Verlag", 1, true))
    UIManager:forceRePaint(); Screen:shot(OUT .. "/40-series-internet.png")
    closeTop()
    -- A book summary always wins over an internet one
    check("internet never replaces book summary", Series.archiveExternal(vol1, 1, { text = "x", source = "internet" }) == false)
    AI.post = orig_post
    check("unsupported providers have no web search", not WebSummary.supported("mistral") and not WebSummary.supported("deepseek") and not WebSummary.supported("custom"))

    -- 5. Offer in "no earlier volumes" (needs a configured provider with web search)
    AI.setKey("anthropic", "test-key-not-real")
    local saved_provider = p:getSetting("ai_provider")
    p:setSetting("ai_provider", "anthropic")
    p:showNoEarlierVolumes({ series = "Gibtsnicht", series_index = 2, title = "X" })
    w = top()
    check("internet offer shown", w and w.text and w.text:find("Internet", 1, true) ~= nil)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/41-no-volumes-offer.png")
    check("offer is short now", w and w.text and #w.text < 400)
    w.ok_callback()
    local caveat = top()
    check("caveat about fan wikis comes before any request", caveat ~= w and caveat.text
        and caveat.text:find("Fan-Wikis", 1, true) ~= nil and p.web_job == nil)
    closeTop()
    closeTop()
    p:setSetting("ai_provider", "mistral")
    p:showNoEarlierVolumes({ series = "Gibtsnicht", series_index = 2, title = "X" })
    w = top()
    check("no offer without web search", w and w.text and w.text:find("Aus dem Internet", 1, true) == nil)
    closeTop()
    p:setSetting("ai_provider", saved_provider)
    AI.setKey("anthropic", nil)

    -- 6. Notes language and earlier volumes in the prompt
    local Prompt = require("storyrecall/prompt")
    local msg = Prompt.build{ book = { title = "B", language = "en" }, notes_language = "de", chapters = {}, previous = {}, known = {},
        earlier_volumes = { { series_index = 1, title = "Eins", text = "Absatz A.\n\nAbsatz B." }, { series_index = 2, title = "Zwei", text = "Voller Text zwei." } } }
    check("notes language in request", msg:find("Notes language: de", 1, true) ~= nil)
    check("earlier volumes in request", msg:find("Volume 2 (Zwei): Voller Text zwei.", 1, true) ~= nil and msg:find("Volume 1 (Eins): Absatz A.", 1, true) ~= nil and not msg:find("Absatz B", 1, true))
    -- Story so far in parts (25.10.): all plot paragraphs, without "Zuletzt"
    msg = Prompt.build{ book = { title = "B", language = "en" }, notes_language = "de", chapters = {}, previous = {}, known = {},
        earlier_volumes = { { series_index = 1, title = "Eins", text = "Teil A.\n\nTeil B.\n\nTeil C.\n\nZuletzt Z.", story_so_far = true }, { series_index = 2, title = "Zwei", text = "Voller Text zwei." } } }
    check("earlier volume in parts: whole plot, no Zuletzt", msg:find("Teil A.", 1, true) ~= nil and msg:find("Teil C.", 1, true) ~= nil and not msg:find("Zuletzt Z", 1, true))
    local saved_lang = p:getSetting("ai_notes_language")
    p:setSetting("ai_notes_language", "book")
    check("notes language like the book", p:getNotesLanguage() == p:getBookInfo().language)
    p:setSetting("ai_notes_language", nil)
    check("notes language like KOReader by default", p:getNotesLanguage() == (G_reader_settings:readSetting("language") or p:getBookInfo().language))
    p:setSetting("ai_notes_language", saved_lang)

    -- 7. Already read elsewhere
    p:markReadElsewhere()
    w = top()
    check("read elsewhere asks first", w and w.ok_callback ~= nil)
    w.ok_callback(); UIManager:close(w)
    local chapters = require("storyrecall/chapters").upTo(ui, math.huge)
    check("unlocked to the last chapter", p.store:getFurthestChapter() == chapters[#chapters].index and p.store.data.read_elsewhere ~= nil)
    closeTop()

    os.remove(Series.archivePath())
    f:close(); UIManager:quit()
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
