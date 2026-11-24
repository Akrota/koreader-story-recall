-- Test: provider limits never mark chapters as failed; daily limit waits and resumes; no credit stops.
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/quota-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local mode = "limit"
UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local AI = require("storyrecall/ai")
    local Processor = require("storyrecall/processor")
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    p:setSetting("ai_when", "wifi")
    AI.complete = function()
      if mode == "credit" then return nil, { kind = "quota", message = "Your credit balance is too low" } end
      if mode == "expired" then return nil, { kind = "auth", code = 400, expired = true, message = "API key expired. Please renew the API key." } end
      return nil, { kind = "rate_limit", message = "You exceeded your current quota", retry_after = 0 }
    end
    -- Speed up all waits.
    local orig = Processor.scheduleNext
    Processor.scheduleNext = function(self) return orig(self, 0.01) end
    local scheduled_wait
    local orig_quota = p.onQuotaReached
    p.onQuotaReached = function(self, wait) scheduled_wait = wait; return orig_quota(self, wait) end
    -- A legacy failure from a rate limit must not hide the chapter.
    local first = require("storyrecall/chapters").upTo(ui, math.huge)[1]
    p.store:setChapterFailure(first, "rate_limit: You exceeded your current quota")
    check("legacy rate-limit failure does not skip the chapter", p.processor:pendingChapters()[1].key == first.key)
    p.store:clearChapterFailures()

    p.processor:start()
    local tries = 0
    local function waitLimit()
      tries = tries + 1
      if p.processor.state ~= "waiting_quota" and tries < 900 then return UIManager:scheduleIn(0.1, waitLimit) end
      log("state:", p.processor.state, p.processor.message, "after", tries)
      check("daily limit -> waiting_quota", p.processor.state == "waiting_quota" and p.processor.message == "quota:limit")
      check("no chapter marked failed", next(p.store.data.ai_failures or {}) == nil)
      check("retry scheduled in an hour", scheduled_wait == 3600 and p.quota_task ~= nil)
      local status = require("storyrecall/aimenu").statusText(p)
      log("status:", status)
      check("status says when it goes on", status:find("Limit, weiter um", 1, true) ~= nil)
      log("details:", require("storyrecall/aimenu").statusDetails(p))
      p:startProcessing()
      check("automatic start waits during the hour", p.processor.state == "waiting_quota")
      -- The scheduled retry fires: pretend the hour is over.
      p:setSetting("ai_quota_wait_until", os.time() - 1)
      mode = "credit"
      p.quota_task()
      tries = 0
      local function waitCredit()
        tries = tries + 1
        if p.processor.message ~= "quota:credit" and tries < 600 then return UIManager:scheduleIn(0.1, waitCredit) end
        check("resumes after the wait, no credit -> stops at once", p.processor.state == "waiting_quota" and p.processor.message == "quota:credit")
        check("still no chapter marked failed", next(p.store.data.ai_failures or {}) == nil)
        log("status:", require("storyrecall/aimenu").statusText(p))
        -- One window when the notes stop for good (Kobo 24.10.), with a way to the AI settings
        local top = UIManager:getTopmostVisibleWidget()
        check("no credit: one window", top and top.text and top.text:find("Kein Guthaben mehr bei", 1, true) ~= nil
            and top.ok_text == "KI-Einstellungen öffnen")
        log("window:", top and top.text)
        UIManager:close(top)
        p:onAIBlocked("credit")
        local again = UIManager:getTopmostVisibleWidget()
        check("only once per failure", not (again and again.text and again.text:find("Kein Guthaben", 1, true)))
        -- Expired key (Gemini says so): own wording in window and status line
        mode = "expired"
        p.ai_block_notified = nil
        p:setSetting("ai_quota_wait_until", nil)
        p.processor:stop("stopped")
        p.processor:start()
        tries = 0
        local function waitExpired()
          tries = tries + 1
          if p.processor.state ~= "error" and tries < 600 then return UIManager:scheduleIn(0.1, waitExpired) end
          local status = require("storyrecall/aimenu").statusText(p)
          log("status:", status)
          check("expired key -> status says expired", status:find("API-Schlüssel abgelaufen", 1, true) ~= nil)
          local w = UIManager:getTopmostVisibleWidget()
          check("expired key -> window says expired", w and w.text and w.text:find("ist abgelaufen", 1, true) ~= nil)
          if w and w.text then UIManager:close(w) end
          AI.setKey("gemini", nil); p:setSetting("ai_quota_wait_until", nil)
          f:close(); UIManager:quit()
        end
        waitExpired()
      end
      waitCredit()
    end
    waitLimit()
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
