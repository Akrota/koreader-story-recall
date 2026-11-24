-- Test: UX-Durchgang (23.10.2026). Rückblick ohne Notizen, Profil mit Stand/Zuletzt/Früher,
-- Suche im Lexikon, "KI fragen" (gefunden, nicht gefunden, abgebrochen), Textstellen ohne
-- Leerzeichen vor Satzzeichen. Läuft auf reise.epub mit erfundenen Notizen und einem
-- vorgetäuschten Anbieter (Anfragen laufen im Unterprozess wie auf dem Kobo).
local UIManager = require("ui/uimanager")
local json = require("json")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/ux-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function textOf(w)
    if not w then return "" end
    return tostring(w.text or (w.scroll_text_w and w.scroll_text_w.text) or (w[1] and w[1].text) or "")
end

local steps, n = {}, 0
local function add(delay, fn) table.insert(steps, { delay, fn }) end
local function run()
    n = n + 1
    local step = steps[n]
    if not step then f:close(); UIManager:quit(); return end
    UIManager:scheduleIn(step[1], function()
        local ok, e = pcall(step[2])
        if not ok then log("ERROR", e) end
        run()
    end)
end

local ui, p, toc, AI, Context
add(4, function()
    ui = require("apps/reader/readerui").instance
    p = ui.storyrecall
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
    toc = ui.toc.toc
    AI = require("storyrecall/ai")
    Context = require("storyrecall/context")
    require("ui/network/manager").runWhenConnected = function(_self, cb) cb() end
    AI.setKey("gemini", nil)

    -- A. Rückblick ohne Notizen und ohne KI: Hinweis auf "+ Notiz" und auf ☰
    p:showRecap()
    local text = textOf(top())
    check("A1 empty recap points to + Notiz", text:find("„+ Notiz“", 1, true) ~= nil)
    check("A2 empty recap explains how to set up the AI", text:find("Noch keine KI eingerichtet", 1, true) ~= nil)
    UIManager:close(top())

    -- I. Rückblick nach einer Pause: nicht bei leerem Buch, nicht bei falscher Uhr
    p.ux_real_showRecap = p.showRecap
    p.ux_shown = 0
    p.showRecap = function(_self, after_break) if after_break then p.ux_shown = p.ux_shown + 1 end end
    p:setSetting("welcome_enabled", true)
    p:setSetting("welcome_ask", false) -- I: the window directly; K tests the question
    p.last_seen = os.time() - 30 * 86400
    p:checkForBreak()

    -- Notizen für Kapitel 1-12, gelesen bis 10
    for i = 1, 12 do
        local entities = {
            { name = "Mara", type = "character", aliases = {}, facts = { "MARA-FAKT-" .. i .. "." },
              status = (i == 7) and "verschwunden" or ((i == 11) and "SPOILER-STAND" or nil) },
            { name = "Elias", type = "character", aliases = {}, facts = { "Elias reist." } },
            i <= 2 and { name = "Joren", type = "character", aliases = {}, facts = { "Joren hilft." } } or nil,
        }
        p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
            summary = "KAPITEL-" .. i .. " passiert.", story_so_far = "BISHER-" .. i .. ".",
            protagonist = "Elias", entities = entities,
        })
    end
    for i = 1, 10 do p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title }) end
    p.store.data.furthest_chapter = 10; p.store.data.furthest_key = toc[10].xpointer
    ui:handleEvent(require("ui/event"):new("GotoPage", ui.document:getPageFromXPointer(toc[11].xpointer) + 1))
end)

add(1, function()
    check("I1 no recap after a break when there is nothing to recap", p.ux_shown == 0)
    p.last_seen = os.time() - 30 * 365 * 86400 -- clock reset to long ago
    p:checkForBreak()
    p.last_seen = os.time() - 30 * 86400 -- a real break, with notes now
    p:checkForBreak()
end)

add(1, function()
    check("I2 wrong clock ignored, a real break with notes shows the recap", p.ux_shown == 1)
    p.showRecap = p.ux_real_showRecap
    -- B. Profil: Stand, Zuletzt/Früher, nichts nach der Lesestelle
    local profiles, by_name = p:getProfiles()
    local mara = Context.find(profiles, by_name, "Mara")[1]
    local text = Context.buildText(mara, "Elias")
    log("profile:\n" .. text)
    check("B1 status line with chapter", text:find("Stand (7", 1, true) ~= nil and text:find("verschwunden", 1, true) ~= nil)
    check("B2 no status from after the reading position", not text:find("SPOILER-STAND", 1, true))
    check("B3 long profile split into Zuletzt and Früher", text:find("Zuletzt", 1, true) ~= nil and text:find("Früher", 1, true) ~= nil)
    local lately = text:find("Zuletzt", 1, true)
    check("B4 newest fact under Zuletzt", text:find("MARA-FAKT-10.", lately, true) ~= nil
        and text:find("MARA-FAKT-10.", 1, true) > lately)
    local elias = Context.find(profiles, by_name, "Elias")[1]
    local joren = Context.find(profiles, by_name, "Joren")[1]
    check("B5 short profile keeps Bisher", joren and Context.buildText(joren, "Elias"):find("Bisher", 1, true) ~= nil
        and not Context.buildText(joren, "Elias"):find("Früher", 1, true))

    -- C. Suche im Lexikon
    check("C1 search finds part of a name, any case", Context.search(profiles, "ARA")[1] == mara)
    check("C2 search finds nothing for unknown words", #Context.search(profiles, "Kühlschrank") == 0)

    -- G. Textstellen: kein Leerzeichen vor Komma
    local passages = Context.passages(ui, elias, ui.document:getPageCount())
    local bad = false
    for _i, passage in ipairs(passages) do if passage.text:find(" ,", 1, true) then bad = true end end
    check("G1 passages found", #passages > 0)
    check("G2 no space before a comma in passages", not bad)

    -- D. KI fragen: gefunden
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    os.remove(OUT .. "/ux-message.txt")
    AI.complete = function(cfg, system, user)
        local m = io.open(OUT .. "/ux-message.txt", "w"); m:write(system .. "\n=====\n" .. user); m:close()
        return json.encode({ found = true, name = "Kühlschrank", type = "object",
            facts = { "Ein kalter Schrank im Hof." }, relation_to_protagonist = "" })
    end
    local _p2, _b2, ctx = p:getProfiles()
    check("D0 lexicon offers to ask the AI when a key is set", ctx.ask_ai ~= nil)
    p:askAI("Kühlschrank")
    check("D1 busy message says how to cancel", textOf(top()):find("Tippen zum Abbrechen", 1, true) ~= nil)
end)

add(4, function()
    local w = top()
    check("D2 profile of the answer shown", w and w.title == "Kühlschrank")
    check("D3 marked as asked", textOf(w):find("von der KI nachgefragt", 1, true) ~= nil)
    if w and w.title == "Kühlschrank" then UIManager:close(w) end
    local in_notes = false
    for _k, note in pairs(p.store.data.ai_chapters) do
        for _i, entity in ipairs(note.entities or {}) do
            if entity.name == "Kühlschrank" then in_notes = true end
        end
    end
    check("D4 stored apart from the chapter notes", p.store.data.lookups and #p.store.data.lookups == 1 and not in_notes)
    local msg = io.open(OUT .. "/ux-message.txt"):read("*a")
    check("D5 read chapter summaries sent", msg:find("KAPITEL-10 ", 1, true) ~= nil)
    check("D6 nothing after the reading position sent", not msg:find("KAPITEL-11", 1, true) and not msg:find("KAPITEL-12", 1, true))
    local profiles, by_name = p:getProfiles()
    check("D7 lexicon knows it now", #Context.find(profiles, by_name, "Kühlschrank") == 1)
    check("D8 kept when the notes are re-created", (function()
        local saved = p.store.data.ai_chapters
        p.store:clearChapterNotes()
        local kept = p.store.data.lookups and #p.store.data.lookups == 1
        p.store.data.ai_chapters = saved
        return kept
    end)())

    -- E. KI fragen: nichts gefunden
    AI.complete = function() return json.encode({ found = false, name = "", type = "term", facts = {}, relation_to_protagonist = "" }) end
    p:askAI("Etwas")
end)

add(4, function()
    check("E1 nothing found is said plainly", textOf(top()):find("nichts zu „Etwas“", 1, true) ~= nil)
    UIManager:close(top())
    check("E2 nothing stored", #p.store.data.lookups == 1)

    -- F. KI fragen: abbrechen durch Antippen
    AI.complete = function()
        os.execute("sleep 4")
        return json.encode({ found = true, name = "Spaet", type = "term", facts = { "Zu spät." }, relation_to_protagonist = "" })
    end
    p.ux_standby_before = UIManager._prevent_standby_count or 0
    p:askAI("Spaet")
end)

add(1, function()
    check("F1 request running in a subprocess", p.lookup_job and p.lookup_job.pid ~= nil)
    check("F2 standby blocked while it runs", (UIManager._prevent_standby_count or 0) > p.ux_standby_before)
    UIManager:close(p.lookup_job.busy) -- what a tap on the message does
    check("F3 cancelled at once", p.lookup_job.done == true)
    check("F4 standby free again", (UIManager._prevent_standby_count or 0) == p.ux_standby_before)
end)

add(6, function()
    check("F5 nothing shown or stored after the cancel", (not top() or top().title ~= "Spaet") and #p.store.data.lookups == 1)
    -- A new request is possible after a cancel
    AI.complete = function() return json.encode({ found = false, name = "", type = "term", facts = {}, relation_to_protagonist = "" }) end
    p:askAI("Nochmal")
end)

add(4, function()
    check("F6 asking again works after a cancel", textOf(top()):find("Nochmal", 1, true) ~= nil)
    UIManager:close(top())

    -- H. Einstecken (auch USB): erst nach einer Wartezeit starten, Ausstecken bricht ab
    p:setSetting("ai_when", "charging")
    local started = 0
    local real_start = p.startProcessing
    p.startProcessing = function() started = started + 1 end
    p:onCharging()
    check("H1 nothing starts right when plugged in (USB question first)", started == 0 and p.charging_task ~= nil)
    p:onNotCharging()
    check("H2 unplugging in the wait cancels the start", p.charging_task == nil)
    p:onCharging()
    p.charging_task()
    check("H3 after the wait it starts", started == 1)
    p.startProcessing = real_start
    AI.setKey("gemini", nil)

    -- J. Lesezeit nur, wenn wirklich gelesen (geblättert oder Pause-Frage beantwortet)
    local old = os.time() - 20 * 86400
    p.store:setLastSeen(old); p.last_seen = old
    p:startSession()
    p:rememberSession()
    check("J1 a quick look (no page turned) keeps the break", p.store:getLastSeen() == old)
    p:startSession()
    ui:handleEvent(require("ui/event"):new("GotoPage", ui:getCurrentPage() + 1))
end)

add(1, function()
    p:rememberSession()
    check("J2 turning a page counts as reading", p.store:getLastSeen() > os.time() - 60)

    -- K. Pause-Frage statt großem Fenster (Standard)
    local old = os.time() - 12 * 86400
    p.store:setLastSeen(old); p.last_seen = old
    p:setSetting("welcome_ask", true)
    p:startSession()
    p:checkForBreak()
end)

add(1, function()
    local w = top()
    check("K1 asks first, with the number of days", textOf(w):find("12 Tage nicht in diesem Buch", 1, true) ~= nil)
    check("K2 answering counts as reading (no second question)", p.session_read == true)
    if w and w.cancel_callback then w.cancel_callback() end
    UIManager:close(w)

    -- L. Neuer Band: auch erst fragen
    local Series = require("storyrecall/series")
    local real_prev = Series.previousVolumes
    Series.previousVolumes = function() return { { series_index = 1, title = "Band 1", summary = { text = "VORBAND" } } } end
    local props = ui.doc_props
    p.ux_saved = { props.series, props.series_index, p.store.data.furthest_chapter, p.store.data.series_recap_shown }
    props.series, props.series_index = "Testreihe", 2
    p.store.data.furthest_chapter = 1
    p.store.data.series_recap_shown = nil
    p.ux_series_started = p:checkForSeriesStart()
    Series.previousVolumes = real_prev
end)

add(1, function()
    local w = top()
    check("L1 new volume: asks before the series recap", p.ux_series_started and textOf(w):find("Band 2 von „Testreihe“", 1, true) ~= nil)
    UIManager:close(w)
    local props = ui.doc_props
    props.series, props.series_index, p.store.data.furthest_chapter, p.store.data.series_recap_shown = table.unpack and table.unpack(p.ux_saved) or unpack(p.ux_saved)
    p:setSetting("welcome_ask", false) -- the next tests expect the window directly

    -- M. Wartezeit und Tageslimit erkennen, für alle Anbieter
    local gemini_body = { error = { code = 429, message = "You exceeded your current quota", details = {
        { ["@type"] = "type.googleapis.com/google.rpc.QuotaFailure",
          violations = { { quotaId = "GenerateRequestsPerDayPerProjectPerModel-FreeTier" } } },
        { ["@type"] = "type.googleapis.com/google.rpc.RetryInfo", retryDelay = "1231s" } } } }
    local wait, daily = AI.parseRateLimit({}, gemini_body, "you exceeded your current quota")
    check("M1 Gemini: wait and daily limit from its own details", wait == 1231 and daily == true)
    wait, daily = AI.parseRateLimit({ ["retry-after"] = "20" }, nil, "rate limit reached")
    check("M2 Retry-After header (Claude, OpenAI, Mistral…), not daily", wait == 20 and daily == false)
    wait = AI.parseRateLimit({}, nil, "rate limit reached for gpt. please try again in 6m0s.")
    check("M3 'try again in 6m0s' in the text", wait == 360)
    wait = AI.parseRateLimit({ ["x-ratelimit-reset-requests"] = "200ms" }, nil, "")
    check("M4 OpenAI reset in milliseconds is not minutes", wait == 1)
    local _w, d = AI.parseRateLimit({}, nil, "limit of 200 requests per day reached")
    check("M5 'per day' in the text means a daily limit", d == true)
    local AIMenu = require("storyrecall/aimenu")
    local text = AIMenu.describeError({ kind = "rate_limit", daily = true, retry_after = 600 })
    check("M6 plain message with the time", text:find("Tageslimit", 1, true) ~= nil
        and text:find(os.date("%H:%M", os.time() + 600), 1, true) ~= nil)

    -- N. Alle Modelle am Tageslimit: warten bis zur genannten Zeit, nicht jede Minute neu
    p.store.data.ai_chapters = nil
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini"); p:setSetting("ai_delay", 0)
    p:setSetting("ai_quota_wait_until", nil)
    AI.complete = function() return nil, { kind = "rate_limit", code = 429, message = "quota", daily = true, retry_after = 900 } end
    p.processor:stop("stopped")
    p.processor:start()
end)

add(8, function()
    local AIMenu = require("storyrecall/aimenu")
    check("N1 waits for the daily limit", p.processor.state == "waiting_quota" and p.processor.message == "quota:daily")
    local until_ = p:getSetting("ai_quota_wait_until") or 0
    check("N2 until the time the provider gave", math.abs(until_ - (os.time() + 900)) < 30)
    check("N3 status line says when it goes on", AIMenu.statusText(p):find("Limit, weiter um", 1, true) ~= nil)
    log("status:", AIMenu.statusText(p))
    p.processor:stop("stopped")
    p:setSetting("ai_quota_wait_until", nil)
    if p.quota_task then UIManager:unschedule(p.quota_task); p.quota_task = nil end
    AI.setKey("gemini", nil)

    -- O. Große Antwort kommt vollständig aus dem Unterprozess
    local big = string.rep("Ä1234567890", 200000) -- about 2.4 MB
    p.ux_big_len = nil
    require("storyrecall/subprocess").run{
        text = "Test",
        work = function() return { text = big } end,
        on_done = function(result) p.ux_big_len = result.text and #result.text end,
    }
    p.ux_big_expected = #big
end)

add(6, function()
    check("O1 a 2 MB answer arrives complete", p.ux_big_len == p.ux_big_expected)

    -- P. Kleine Kategorien (unter 3) kommen unter "Sonstiges"; Figuren und Orte bleiben immer
    local function profile(name, type_) return { name = name, type = type_, aliases = {}, facts = { { index = 1, text = "x" } } } end
    local profiles = {
        profile("Anna", "character"), profile("Ben", "character"), profile("Café", "place"),
        profile("Ring", "object"), profile("Brief", "object"),
        profile("Wolf", "creature"), profile("Bär", "creature"), profile("Luchs", "creature"), profile("Fuchs", "creature"),
        profile("Ehrenwort", "term"),
    }
    local _p2, _b2, ctx = p:getProfiles()
    Context.browse(ctx, profiles)
    local labels = {}
    for _r, row in ipairs(top().buttontable.buttons_layout) do
        for _c, b in ipairs(row) do table.insert(labels, b.text) end
    end
    local joined = table.concat(labels, " | ")
    log("categories:", joined)
    check("P1 one place still gets its own category", joined:find("Orte (1)", 1, true) ~= nil)
    check("P2 two objects go under Sonstiges", not joined:find("Gegenstände", 1, true) and joined:find("Sonstiges (3)", 1, true) ~= nil)
    check("P3 four creatures get their own category", joined:find("Kreaturen (4)", 1, true) ~= nil)
    check("P4 All still counts everything", joined:find("Alle (10)", 1, true) ~= nil)
    while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end
end)

run()
