-- AI pipeline test with a fake provider (no network, no real key).
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/ai-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end

local AI
local json = require("json")
-- Fake provider: answers from the request itself. Runs in the subprocess.
local function fakeComplete(cfg, system, user, schema)
    local log_file = io.open(OUT .. "/requests.log", "a"); log_file:write(user:match("<chapter index=\"%d+\"") and "request\n" or "other\n"); log_file:close()
    local previous = select(2, user:gsub("\n%[%d+%] ", ""))
    local known = user:find("Known entities so far", 1, true) and "ja" or "nein"
    if user:find('<chapter index="3"', 1, true) and not io.open(OUT .. "/ratelimit-done", "r") then
        io.open(OUT .. "/ratelimit-done", "w"):close()
        return nil, { kind = "rate_limit", message = "too many requests", retry_after = 1 }
    end
    local chapters = {}
    for n, text in user:gmatch('<chapter index="(%d+)"[^>]*>(.-)</chapter>') do
        n = tonumber(n)
        local words = select(2, text:gsub("%S+", ""))
        table.insert(chapters, {
            index = n,
            summary = string.format("Testzusammenfassung Kapitel %d: %d Wörter gelesen, %d frühere Zusammenfassungen, bekannte Figuren: %s.", n, words, previous, known),
            story_so_far = "Bisherige Geschichte bis Kapitel " .. n .. ".",
            protagonist = "Elias",
            entities = {
                { name = "Mara", type = "character", aliases = { n == 2 and "die Heilerin" or "Mara" }, facts = { "Fakt aus Kapitel " .. n }, relation_to_protagonist = "Gefährtin" },
                { name = "Elias", type = "character", aliases = {}, facts = { "Elias in Kapitel " .. n }, relation_to_protagonist = "" },
            },
        })
    end
    return json.encode({ chapters = chapters })
end

local ui, p
local waited = 0
local steps
local function waitDone(next_step)
    return function()
        if (p.processor.state == "running" or p.processor.state == "waiting_retry") and waited < 60 then
            waited = waited + 1
            UIManager:scheduleIn(1, steps[next_step - 1])
            return "wait"
        end
    end
end
steps = {
  function()
    AI = require("storyrecall/ai"); AI.complete = fakeComplete
    -- Claude rejects a schema unless every object has additionalProperties = false
    -- (Kobo, 23.10.: "Geschichte bisher" failed with Claude). Optional properties are
    -- fine for Claude (volume_summary only comes with the last chapter of a volume).
    local Prompt = require("storyrecall/prompt")
    local function closedEverywhere(s)
        if type(s) ~= "table" then return true end
        if s.type == "object" and s.additionalProperties ~= false then return false end
        for k, v in pairs(s) do if type(v) == "table" and not closedEverywhere(v) then return false end end
        return true
    end
    for _i, name in ipairs({ "SCHEMA", "RECAP_SCHEMA", "LOOKUP_SCHEMA" }) do
        check("Claude accepts " .. name, closedEverywhere(AI.closedSchema(Prompt[name])) and closedEverywhere(Prompt[name]))
    end
    check("closedSchema fills in what is missing", closedEverywhere(AI.closedSchema({ type = "object", properties = {} })))
    ui = require("apps/reader/readerui").instance; p = ui.storyrecall; closeTop()
    log("state before key:", p.processor.state, p.processor.message)
    local status = require("storyrecall/aimenu").statusText(p)
    log("status without key:", status)
    check("without key: nothing sent, status says key missing", p.processor.state == "idle" and status:find("API-Schlüssel fehlt", 1, true) ~= nil)
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini"); p:setSetting("ai_delay", 0); p:setSetting("ai_batch_chapters", 3)
    p:setSetting("ai_when", "manual"); p:startProcessing()
    check("'only on request' does not start by itself", p.processor.state == "idle")
    p:setSetting("ai_when", "charging"); p:startProcessing()
    check("'only while charging' does not start on battery", p.processor.state == "idle")
    local ok, reason = p.processor:start()
    log("start:", ok, reason, "state", p.processor.state)
  end,
}
-- poll until finished
local function poll()
  if (p.processor.state == "running" or p.processor.state == "waiting_retry") and waited < 60 then
    waited = waited + 1; UIManager:scheduleIn(1, poll); return
  end
  local ok, e = pcall(function()
    log("finished state:", p.processor.state, p.processor.message, "after", waited, "s")
    check("all 5 chapters processed", p.store:countChapterNotes() == 5)
    local requests = 0; for _ in io.lines(OUT .. "/requests.log") do requests = requests + 1 end
    log("requests sent:", requests)
    check("batched: 2 requests + 1 rate-limited retry", requests == 3)
    local n3 = p.store:getChapterNote(ui.toc.toc[3].xpointer)
    check("wait (default): rate limit retried with the same model, no switch",
        n3 and n3.model == "gemini-3.8-flash" and p.processor.cfg.model == p.processor.primary_model)
    check("rate limit was retried", io.open(OUT .. "/ratelimit-done", "r") ~= nil and p.store:getChapterNote(ui.toc.toc[3].xpointer) ~= nil)
    local n1 = p.store:getChapterNote(ui.toc.toc[1].xpointer)
    local n4 = p.store:getChapterNote(ui.toc.toc[4].xpointer)
    log("ch1:", n1 and n1.summary); log("ch4:", n4 and n4.summary)
    check("chapter text was sent", n1 and tonumber(n1.summary:match("(%d+) Wörter")) > 300)
    check("earlier summaries passed along", n4 and n4.summary:find("3 frühere") ~= nil)
    check("each chapter got its own text", n1 and n4 and n1.summary:match("(%d+) Wörter") == n4.summary:match("(%d+) Wörter"))
    check("known entities passed along", n4 and n4.summary:find("bekannte Figuren: ja") ~= nil)
    local known = p.store:getKnownEntities(5)
    local mara; for _, k in ipairs(known) do if k.name == "Mara" then mara = k end end
    log("Mara aliases:", mara and table.concat(mara.aliases, ","))
    check("aliases merged", mara and #mara.aliases == 1 and mara.aliases[1] == "die Heilerin")
    -- spoiler gate: reader has finished chapter 2 and just started chapter 3
    -- (AI notes describe a chapter up to its end: only finished chapters show)
    p.store.data.furthest_chapter = 3
    -- …and is reading there (the recap follows the reading position)
    ui:handleEvent(require("ui/event"):new("GotoPage", ui.document:getPageFromXPointer(ui.toc.toc[3].xpointer) + 1))
    p:showChronicle()
  end)
  if not ok then log("ERROR", e) end
  UIManager:scheduleIn(1, function()
    local ok2, e2 = pcall(function()
      local w = top()
      check("chronicle shows AI summary of read chapters", w.text:find("Testzusammenfassung Kapitel 2", 1, true) ~= nil)
      check("chronicle hides AI summaries after read point", not w.text:find("Testzusammenfassung Kapitel 3", 1, true))
      Screen:shot(OUT .. "/shots/10-ai-chronicle.png"); closeTop()
      p:showRecap(true)
    end)
    if not ok2 then log("ERROR", e2) end
    UIManager:scheduleIn(1, function()
      local ok3, e3 = pcall(function()
        local w = top()
        check("recap shows 'Die Geschichte bisher' up to the read point", w.text:find("Die Geschichte bisher", 1, true) ~= nil and w.text:find("Bisherige Geschichte bis Kapitel 2.", 1, true) ~= nil and not w.text:find("Kapitel 3.", 1, true))
        check("recap shows the last chapter", w.text:find("Im letzten Kapitel", 1, true) ~= nil)
        Screen:shot(OUT .. "/shots/11-ai-recap.png"); closeTop()
        log("status:", require("storyrecall/aimenu").statusText(p))
        -- overload storm with "other model": timeout on the first model, overloaded second, third works
        -- (switch only after 3 failures in a row; pauses shortened for the test)
        local working = fakeComplete
        p:setSetting("ai_on_overload", "switch")
        local scheduleNext = p.processor.scheduleNext
        p.processor.scheduleNext = function(self) return scheduleNext(self, 0.2) end
        os.remove(OUT .. "/storm.log")
        local function first_calls()
            local n = 0
            for _l in io.lines(OUT .. "/storm.log") do n = n + 1 end
            return n
        end
        _G.storm_calls = first_calls
        AI.complete = function(cfg, system, user, schema)
            if cfg.model == "gemini-3.8-flash" then local sl = io.open(OUT .. "/storm.log", "a"); sl:write("x\n"); sl:close(); return nil, { kind = "timeout", message = "wantread" } end
            if cfg.model == "gemini-3.5-flash-lite" then return nil, { kind = "server", code = 503, message = "high demand" } end
            return working(cfg, system, user, schema)
        end
        p.store.data.ai_chapters[ui.toc.toc[5].xpointer] = nil
        p.processor:start()
      end)
      if not ok3 then log("ERROR", e3) end
      UIManager:scheduleIn(6, function()
        local ok4, e4 = pcall(function()
          log("after overload storm:", p.processor.state, p.processor.cfg.model, "first_calls", _G.storm_calls(), "n5", tostring(p.store:getChapterNote(ui.toc.toc[5].xpointer) and p.store:getChapterNote(ui.toc.toc[5].xpointer).model))
          local n5 = p.store:getChapterNote(ui.toc.toc[5].xpointer)
          check("timeout is not treated as 'no Wi-Fi'", p.processor.state ~= "waiting_network")
          check("other model: switched after 3 failures in a row and finished", n5 ~= nil and n5.model == "gemini-3.6-flash" and _G.storm_calls() == 3)
          -- "wait": the same storm never leaves the chosen model
          p:setSetting("ai_on_overload", "wait")
          p.store.data.ai_chapters[ui.toc.toc[5].xpointer] = nil
          os.remove(OUT .. "/storm.log")
          p.processor:start()
        end)
        if not ok4 then log("ERROR", e4) end
      UIManager:scheduleIn(4, function()
        local ok5, e5 = pcall(function()
          log("wait storm:", p.processor.state, p.processor.message, p.processor.cfg.model, _G.storm_calls())
          check("wait: stays with the chosen model during an overload", p.processor.cfg.model == "gemini-3.8-flash" and _G.storm_calls() >= 3 and p.store:getChapterNote(ui.toc.toc[5].xpointer) == nil)
          check("wait: Anthropic fallback off, not switching", not p.processor.cfg.switch_models)
          p.processor:stop("stopped")
          p.processor.scheduleNext = scheduleNext
          -- auth error stops processing
          AI.complete = function() return nil, { kind = "auth", code = 401, message = "invalid key" } end
          p:setSetting("ai_when", "charging")
          p.store.data.ai_chapters[ui.toc.toc[5].xpointer] = nil
          p.processor:start()
        end)
        if not ok5 then log("ERROR", e5) end

      UIManager:scheduleIn(4, function()
        log("after auth error:", p.processor.state, p.processor.message)
        check("rejected key stops processing", p.processor.state == "error" and tostring(p.processor.message):find("auth") ~= nil)
        log("status:", require("storyrecall/aimenu").statusText(p))
        AI.setKey("gemini", nil)
        f:close(); UIManager:quit()
      end)
      end)
      end)
    end)
  end)
end
UIManager:scheduleIn(5, function()
  local ok, e = pcall(steps[1]); if not ok then log("ERROR", e) end
  UIManager:scheduleIn(1, poll)
end)
