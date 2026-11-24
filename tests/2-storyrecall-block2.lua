-- Test: review block 2 (M2–M13). Fake HTTP answers and a fake provider; no network.
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/block2-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end

local json = require("json")
local http = require("socket.http")

-- Fake HTTP: answers from a queue of { code, body } and records request bodies.
local queue, sent = {}, {}
local real_request = http.request
local function fakeHttp()
    http.request = function(req)
        local body = req.source and req.source() or ""
        table.insert(sent, body)
        local answer = table.remove(queue, 1) or { 500, "{}" }
        req.sink(answer[2]); req.sink(nil)
        return 1, answer[1], {}, "HTTP/1.1 " .. answer[1]
    end
end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local AI = require("storyrecall/ai")
    local Processor = require("storyrecall/processor")
    local Chapters = require("storyrecall/chapters")
    closeTop(); closeTop()

    -- M2–M5: error classification with fake HTTP answers
    fakeHttp()
    local cfg = { provider = "openai", model = "gpt-test", key = "k", base_url = "https://api.openai.com/v1" }
    queue = { { 429, json.encode({ error = { message = "You exceeded your current quota, please check your plan.", type = "insufficient_quota", code = "insufficient_quota" } }) } }
    local _, err = AI.complete(cfg, "s", "u")
    check("M2: OpenAI without credit -> quota", err and err.kind == "quota")
    queue = { { 400, json.encode({ error = { code = 400, message = "API key not valid. Please pass a valid API key.", status = "INVALID_ARGUMENT", details = { { reason = "API_KEY_INVALID" } } } }) } }
    _, err = AI.complete({ provider = "gemini", model = "g", key = "bad" }, "s", "u")
    check("M3: wrong Gemini key -> auth", err and err.kind == "auth")
    sent = {}
    queue = { { 200, json.encode({ choices = { { message = { content = "{\"chapters\":[]}" }, finish_reason = "stop" } } }) } }
    AI.complete(cfg, "s", "u")
    check("M4: no temperature for OpenAI", sent[1] and not sent[1]:find("temperature", 1, true))
    sent = {}
    queue = { { 400, json.encode({ error = { message = "Unsupported value: 'temperature' does not support 0.3" } }) },
              { 200, json.encode({ choices = { { message = { content = "{}" }, finish_reason = "stop" } } }) } }
    local text = AI.complete({ provider = "mistral", model = "m", key = "k", base_url = "https://api.mistral.ai/v1" }, "s", "u")
    check("M4: retried without temperature", text == "{}" and #sent == 2 and not sent[2]:find("temperature", 1, true))
    queue = { { 200, json.encode({ choices = { { message = { content = "{\"chap" }, finish_reason = "length" } } }) } }
    _, err = AI.complete(cfg, "s", "u")
    check("M5: cut-off OpenAI answer -> too_long", err and err.kind == "too_long")
    queue = { { 200, json.encode({ candidates = { { finishReason = "MAX_TOKENS" } } }) } }
    _, err = AI.complete({ provider = "gemini", model = "g", key = "k" }, "s", "u")
    check("M5: Gemini MAX_TOKENS -> too_long (not refused)", err and err.kind == "too_long")
    queue = { { 200, json.encode({ stop_reason = "max_tokens", content = { { type = "text", text = "{\"ch" } } }) } }
    _, err = AI.complete({ provider = "anthropic", model = "claude-haiku-5-5", key = "k" }, "s", "u")
    check("M5: Claude max_tokens -> too_long", err and err.kind == "too_long")
    http.request = real_request

    -- M5 + M7 in the processor: fake provider
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    p:setSetting("ai_when", "wifi")
    p:setSetting("ai_quota_wait_until", nil)
    local calls = {}
    os.remove(OUT .. "/b2-calls.log"); os.remove(OUT .. "/b2-first")
    AI.complete = function(c, system, user)
        local n = select(2, user:gsub('<chapter index="', ""))
        -- State in files (from Windows-Claude): on e-readers and Linux each
        -- request runs in a fresh subprocess, so Lua variables would not stick.
        local cl = io.open(OUT .. "/b2-calls.log", "a"); cl:write(c.model .. " " .. n .. "\n"); cl:close()
        if not io.open(OUT .. "/b2-first", "r") then io.open(OUT .. "/b2-first", "w"):close(); return nil, { kind = "rate_limit", message = "busy" } end
        if n > 1 then return nil, { kind = "too_long", message = "length" } end
        local index = tonumber(user:match('<chapter index="(%d+)"'))
        return json.encode({ chapters = { { index = index, summary = "Zusammenfassung von Kapitel " .. index, story_so_far = "B" .. index, protagonist = "E", entities = {} } } })
    end
    local orig_next = Processor.scheduleNext
    Processor.scheduleNext = function(self) return orig_next(self, 0.01) end
    p.processor:start()
    local tries = 0
    local function waitDone()
        tries = tries + 1
        if p.processor:isActive() and tries < 900 then return UIManager:scheduleIn(0.1, waitDone) end
        for line in io.lines(OUT .. "/b2-calls.log") do
            local m, k = line:match("^(%S+) (%d+)$")
            if m then table.insert(calls, { model = m, chapters = tonumber(k) }) end
        end
        local log_calls = {}
        for _, c in ipairs(calls) do table.insert(log_calls, c.model .. "x" .. c.chapters) end
        log("calls:", table.concat(log_calls, " "))
        local total = #Chapters.upTo(ui, math.huge)
        check("M5: cut-off batch retried chapter by chapter, all notes created", p.store:countChapterNotes() == total)
        check("M5: no chapter marked failed", next(p.store.data.ai_failures or {}) == nil)
        check("M7: back to the main model after the fallback worked", calls[#calls].model == p.processor.primary_model and not p.processor.using_fallback)
        Processor.scheduleNext = orig_next

        -- M8: a waiting time survives closing and reopening (fresh processor state)
        p:setSetting("ai_quota_wait_until", os.time() + 600)
        if p.quota_task then UIManager:unschedule(p.quota_task); p.quota_task = nil end
        p.processor.state = "idle"
        p:startProcessing()
        check("M8: retry planned again, nothing sent meanwhile", p.quota_task ~= nil and not p.processor:isActive())
        UIManager:unschedule(p.quota_task); p.quota_task = nil
        p:setSetting("ai_quota_wait_until", nil)
        AI.setKey("gemini", nil)

        -- M11: scroll mode counts reading on
        local toc = ui.toc.toc
        p.store.data.furthest_chapter = 1; p.store.data.furthest_key = toc[1].xpointer; p.store.data.chapters = {}
        local saved_mode = ui.view.view_mode
        ui.view.view_mode = "scroll"
        p.last_page, p.last_chapter = toc[2].page - 1, Chapters.atPage(ui, toc[2].page - 1)
        p:onPosUpdate(nil, toc[2].page)
        p:onPosUpdate(nil, toc[2].page + 1)
        ui.view.view_mode = saved_mode
        check("M11: scrolling into chapter 2 advances", p.store:getFurthestChapter() == 2)

        -- M12: a page step caused by a re-layout is undone
        p.last_page, p.last_chapter = toc[3].page - 1, Chapters.atPage(ui, toc[3].page - 1)
        p:onPageUpdate(toc[3].page)
        local advanced = p.store:getFurthestChapter() == 3
        p:onDocumentRerendered()
        check("M12: re-layout step undone", advanced and p.store:getFurthestChapter() == 2 and p.store:getChapter(toc[2].xpointer) == nil)

        -- M13: TOC renumbered (e.g. alternative TOC): found again by xpointer
        local key3 = toc[3].xpointer
        p.store.data.furthest_chapter = 3; p.store.data.furthest_key = key3
        p.store:renumber(function(key) return key == key3 and 7 or nil end)
        check("M13: reading point follows its xpointer", p.store:getFurthestChapter() == 7)
        p.store:renumber(function(key) return key == key3 and 3 or nil end)
        local signature_before = p.store.data.toc_signature
        p:checkTocChanged()
        check("M13: TOC fingerprint stored", signature_before ~= nil and p.store.data.toc_signature == signature_before)

        -- M9: the key setup page cannot be stalled by a client
        local KeySetup = require("storyrecall/keysetup")
        local setup = setmetatable({ token = "abc", provider_id = "gemini" }, { __index = KeySetup })
        local endless = { settimeout = function() end, send = function() end,
            receive = function() return "X-Header: 1" end }
        local first = true
        endless.receive = function() if first then first = false; return "GET /?t=abc HTTP/1.1" end return "X-Header: 1" end
        local t0 = os.time()
        setup:handle(endless)
        check("M9: endless headers stop", os.time() - t0 < 4)
        local silent = { settimeout = function() end, send = function() end, receive = function() return nil, "timeout" end }
        setup:handle(silent)
        check("M9: silent client ignored", true)


        -- Low-priority fixes
        check("L: https address accepted", KeySetup.cleanUrl(" https://api.example.com/v1/chat/completions ") == "https://api.example.com/v1")
        check("L: http only in the home network", KeySetup.cleanUrl("http://192.168.1.20:8080/v1") ~= nil and KeySetup.cleanUrl("http://evil.example.com/v1") == nil)
        AI.setKey("custom", "eins"); AI.setKey("custom", nil)
        check("L: no backup copy of keys", io.open(AI.keysFile() .. ".old", "r") == nil)
        local info = p:getBookInfo()
        p.store.data.book = { title = info.title, series = "Alte Reihe", series_index = 2 }
        p.store:setBookInfo({ title = info.title })
        check("L: removed series noticed", p.store.data.book.series == nil)
        local Context = require("storyrecall/context")
        local orig_find = ui.document.findAllText
        local searched = {}
        ui.document.findAllText = function(_doc, term) table.insert(searched, term) return {} end
        Context.passages(ui, { name = "The Butcher", type = "character", aliases = {} }, 99999)
        ui.document.findAllText = orig_find
        check("L: no search for an article as first name", #searched == 1 and searched[1] == "The Butcher")
        f:close(); UIManager:quit()
    end
    waitDone()
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
