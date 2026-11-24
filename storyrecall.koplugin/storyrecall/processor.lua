--[[--
Background processing: sends small batches of chapters to the AI and stores
the results. Each request runs in a subprocess so reading never freezes; the
reader polls for the answer once a second. Standby is only blocked while a
request is actually in flight; falling asleep by itself (which turns Wi-Fi
off) while the processor is running.

Chapters are processed in reading order, because every request carries the
summaries of the chapters before it. Without Wi-Fi nothing happens; the work
continues when the device is online again.
--]]

local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local json = require("json")
local logger = require("logger")
local time = require("ui/time")
local AI = require("storyrecall/ai")
local Chapters = require("storyrecall/chapters")
local Prompt = require("storyrecall/prompt")
local Store = require("storyrecall/store")
local Subprocess = require("storyrecall/subprocess")

local POLL_INTERVAL = 1           -- seconds between checks for the answer
local REQUEST_TIMEOUT = 660       -- give up on a request after this many seconds (above ai.lua's TOTAL_TIMEOUT)
local MAX_RETRIES = 6             -- per chapter, after every model was tried
local RATE_LIMIT_WAIT = 60        -- seconds, when the provider gives no retry-after
local MAX_PREVIOUS = 40           -- earlier chapters sent with their full summary (older ones: the story so far)
local QUOTA_WAIT = 3600           -- seconds, after the provider's limit stayed reached (e.g. a daily limit)
local SWITCH_AFTER = 3            -- setting "switch": failures in a row before another model is tried
local OVERLOAD_WAIT = 600         -- setting "wait": pause after the retries, before trying the same model again

-- Errors that say nothing about the chapter itself. They never mark a chapter
-- as failed, so it is not skipped later (which would leave a gap).
local TRANSIENT = { rate_limit = true, server = true, timeout = true, network = true, quota = true }

local function isTransientFailure(failure)
    local kind = failure and tostring(failure.reason or ""):match("^([%w_]+):")
    return kind ~= nil and TRANSIENT[kind] == true
end

local Processor = {}
Processor.__index = Processor
Processor.OVERLOAD_RETRY = 120     -- seconds, first pause after "overloaded"; doubles each time
Processor.OVERLOAD_RETRY_MAX = 480 -- longest such pause
Processor.REST_OVERLOAD = 900      -- seconds the main model rests after it made us switch (overload, timeouts)
Processor.REST_DAILY = 3600        -- same after its daily limit
-- Series: send entries of earlier volumes that a request's chapters name (series lexicon,
-- stage 2). Off until compared with real requests, old against new (17.11.2026).
Processor.SEND_EARLIER_ENTRIES = false

-- On macOS (the desktop emulator) a forked child must not use the system's
-- network stack, so requests run in the main process there. The UI is busy
-- for the duration of a request; e-readers always use the subprocess.
local function runInline()
    return jit.os == "OSX"
end

--- @param plugin the StoryRecall plugin instance (ui, store, settings)
function Processor.new(plugin)
    return setmetatable({
        plugin = plugin,
        state = "idle", -- idle | running | waiting_network | waiting_retry | waiting_quota | stopped | done | error
        message = nil,  -- last error, for the status line
        retries = 0,
    }, Processor)
end

function Processor:isActive()
    return self.state == "running" or self.state == "waiting_retry"
end

--- Chapters to process, in reading order (front matter excluded).
function Processor:pendingChapters()
    local ui, store = self.plugin.ui, self.plugin.store
    local limit = self.plugin:getProcessingLimit()
    local pending = {}
    for _, chapter in ipairs(Chapters.upTo(ui, limit or math.huge)) do
        local failure = store:getChapterFailure(chapter.key)
        if not store:getChapterNote(chapter.key) and (not failure or isTransientFailure(failure)) then
            table.insert(pending, chapter)
        end
    end
    return pending
end

--- Start or continue processing. Safe to call repeatedly.
-- @return true if work started or is already running, else false + reason
function Processor:start()
    if self:isActive() then return true end
    local cfg, reason = AI.configFrom(self.plugin.settings)
    if not cfg then
        self:setState("error", "config:" .. reason)
        return false, reason
    end
    if #self:pendingChapters() == 0 then
        self:setState("done")
        return false, "done"
    end
    if not NetworkMgr:isConnected() then
        self:setState("waiting_network")
        return false, "network"
    end
    self.cfg = cfg
    self.earlier_volumes = nil
    self.plugin.earlier_lexicons = nil -- notes of earlier volumes may have changed meanwhile
    self.single_batch = nil -- after a cut-off answer: one chapter per request for this run
    self.primary_model = cfg.model
    self.models_tried = nil
    self.using_fallback = false
    self.primary_rest_until = nil
    self.retries = 0
    self.fail_streak = 0
    self:setState("running")
    self:next()
    return true
end

--- During a pause after an error: try again right away.
function Processor:retryNow()
    if self.state ~= "waiting_retry" then return false end
    if self.next_task then
        UIManager:unschedule(self.next_task)
        self.next_task = nil
    end
    self.models_tried = nil
    self:next()
    return true
end

--- Stop processing (closing the book, sleep, or the user pressed pause).
function Processor:stop(state)
    if self.child then
        if self.child.pid then Subprocess.cancel(self.child.pid, self.child.fd) end
        self.child = nil
    end
    if self.poll_task then
        UIManager:unschedule(self.poll_task)
        self.poll_task = nil
    end
    if self.next_task then
        UIManager:unschedule(self.next_task)
        self.next_task = nil
    end
    self:allowStandby()
    self:setState(state or "stopped")
end

-- Keep the device awake only while a request is in flight.
function Processor:preventStandby()
    if not self.standby_prevented then
        UIManager:preventStandby()
        self.standby_prevented = true
    end
end

function Processor:allowStandby()
    if self.standby_prevented then
        UIManager:allowStandby()
        self.standby_prevented = false
    end
end

function Processor:setState(state, message)
    local changed = state ~= self.state or message ~= self.message
    self.state = state
    self.message = message
    logger.dbg("StoryRecall processor:", state, message or "")
    -- Also in the pauses between attempts and while waiting for a limit to reset, while plugged in: after a night of retries the
    -- device went to sleep in such a pause and Wi-Fi went off for five hours (19.11.2026).
    self:pauseAutoSuspend(state == "running" or ((state == "waiting_retry" or state == "waiting_quota") and self:isCharging()))
    if changed then self:progress() end
end

-- While the AI works, the device must not fall asleep by itself after the
-- idle time: going to sleep turns Wi-Fi off in the middle of a request.
-- KOReader's own switch for this; closing the cover still works. In pauses before
-- a new attempt the device may sleep as usual, unless it is charging.
function Processor:isCharging()
    local ok, Device = pcall(require, "device")
    if not ok or type(Device) ~= "table" or not Device.hasBattery or not Device:hasBattery() then return false end
    local powerd = Device:getPowerDevice()
    local ok2, charging = pcall(function() return powerd:isCharging() end)
    return ok2 and charging == true
end

function Processor:pauseAutoSuspend(on)
    local ok, PluginShare = pcall(require, "pluginshare")
    if not ok or type(PluginShare) ~= "table" then return end
    if on and not self.suspend_paused and not PluginShare.pause_auto_suspend then
        PluginShare.pause_auto_suspend = true
        self.suspend_paused = true
    elseif not on and self.suspend_paused then
        -- Only undo what we set ourselves.
        PluginShare.pause_auto_suspend = false
        self.suspend_paused = false
    end
end

--- Live progress: let an open menu redraw the status line.
function Processor:progress()
    if self.plugin.refreshStatusMenu then self.plugin:refreshStatusMenu() end
end

function Processor:scheduleNext(delay)
    self.next_task = function()
        self.next_task = nil
        self:next()
    end
    UIManager:scheduleIn(delay, self.next_task)
end

--- Build the request for the next batch of chapters and send it from a subprocess.
function Processor:next()
    if self.state ~= "running" and self.state ~= "waiting_retry" then return end
    local pending = self:pendingChapters()
    if #pending == 0 then
        self:stop("done")
        return
    end
    if not NetworkMgr:isConnected() then
        self:stop("waiting_network")
        return
    end
    self:setState("running")

    local ui, store = self.plugin.ui, self.plugin.store
    -- Only extract text for the few chapters that can go into this batch.
    local max_chapters = self.plugin:getSetting("ai_batch_chapters") or Prompt.MAX_BATCH_CHAPTERS
    -- After an answer that was cut off or declined, try one chapter at a time.
    if self.single_batch then max_chapters = 1 end
    local candidates = {}
    for i = 1, math.min(#pending, max_chapters) do
        local chapter = pending[i]
        chapter.text = self:chapterText(chapter)
        table.insert(candidates, chapter)
    end
    local saved_max = Prompt.MAX_BATCH_CHAPTERS
    Prompt.MAX_BATCH_CHAPTERS = max_chapters
    local batch = Prompt.batch(candidates)
    Prompt.MAX_BATCH_CHAPTERS = saved_max
    local first = batch[1]

    -- Long books (web serials with hundreds of chapters): only the latest
    -- chapters go with their summary; everything before them is covered by
    -- the "story so far" of the last chapter left out. Keeps requests bounded.
    local previous, story_before = {}, nil
    local earlier = store:getChapterNotes(first.index - 1)
    local first_kept = math.max(1, #earlier - MAX_PREVIOUS + 1)
    if first_kept > 1 then
        local cut = earlier[first_kept - 1]
        story_before = cut.story_so_far and { index = cut.index, text = cut.story_so_far }
    end
    for i = first_kept, #earlier do
        local note = earlier[i]
        table.insert(previous, { index = note.index, title = note.title, summary = note.summary })
    end
    -- Entries from earlier volumes of the series that these chapters name: they go
    -- along with the known entities, so the AI keeps their names and adds only
    -- what is new (the series lexicon continues them).
    local known = store:getKnownEntities(first.index - 1)
    local earlier_lexicons = Processor.SEND_EARLIER_ENTRIES and self.plugin.earlierLexicons
        and self.plugin:earlierLexicons() or {}
    if #earlier_lexicons > 0 then
        local texts = {}
        for _, chapter in ipairs(batch) do table.insert(texts, chapter.text or "") end
        local ok, mentioned = pcall(Store.earlierMentioned, earlier_lexicons, known, table.concat(texts, " \n "))
        if ok then
            for _, entity in ipairs(mentioned) do table.insert(known, entity) end
        else
            logger.warn("StoryRecall: earlier entries:", mentioned)
        end
    end
    local all_chapters = Chapters.upTo(ui, math.huge)
    local last_index = all_chapters[#all_chapters] and all_chapters[#all_chapters].index
    local message, truncated = Prompt.build{
        book = self.plugin:getBookInfo(),
        notes_language = self.plugin:getNotesLanguage(),
        earlier_volumes = self:earlierVolumes(),
        story_before = story_before,
        last_index = last_index,
        chapters = batch,
        previous = previous,
        known = known,
    }
    for _, chapter in ipairs(batch) do chapter.text = nil end
    if truncated then
        logger.warn("StoryRecall: a chapter near", first.index, "is longer than", Prompt.MAX_CHAPTER_CHARS, "characters, sent in part")
    end

    local cfg = self.cfg
    if runInline() then
        local child = { batch = batch, started = time.now(), truncated = truncated, last_index = last_index }
        self.child = child
        self:preventStandby()
        self.next_task = function()
            self.next_task = nil
            local answer, err = AI.complete(cfg, Prompt.SYSTEM, message, Prompt.SCHEMA)
            if self.child ~= child then return end -- stopped meanwhile
            self.child = nil
            self:handleResult(child, { text = answer, err = err })
        end
        UIManager:scheduleIn(0.2, self.next_task) -- let the screen update first
        return
    end
    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local answer, err = AI.complete(cfg, Prompt.SYSTEM, message, Prompt.SCHEMA)
        Subprocess.writeAll(write_fd, json.encode({ text = answer, err = err }))
    end, true)
    if not pid then
        self:stop("error")
        self.message = "subprocess"
        return
    end
    self:preventStandby()
    self.child = { pid = pid, fd = fd, batch = batch, started = time.now(), truncated = truncated, last_index = last_index }
    self:schedulePoll()
    -- Keep the UI usable: nothing else happens until the poll sees the answer.
    if ui and ui.storyrecall_status_changed then ui.storyrecall_status_changed() end
end

--- Summaries of the earlier volumes of the series, as background for the AI
-- (looked up once per run).
function Processor:earlierVolumes()
    if self.earlier_volumes == nil then
        local ok, volumes = pcall(require("storyrecall/series").previousVolumes,
            self.plugin.ui.document.file, self.plugin:getBookInfo())
        self.earlier_volumes = {}
        for _, volume in ipairs(ok and volumes or {}) do
            table.insert(self.earlier_volumes, { series_index = volume.series_index, title = volume.title,
                text = volume.summary.text, story_so_far = volume.summary.story_so_far })
        end
    end
    return self.earlier_volumes
end

--- Text of one chapter, from its start to the start of the next one.
function Processor:chapterText(chapter)
    local ui = self.plugin.ui
    local doc = ui.document
    if not doc.getTextFromXPointers or not chapter.key:find("^/") then
        return "" -- page-based documents (PDF): not supported yet
    end
    -- Up to the next visible chapter: hidden sub-sections belong to this one.
    local next_chapter = Chapters.next(ui, chapter.index)
    local end_xp = next_chapter and next_chapter.key or doc:getPageXPointer(doc:getPageCount())
    return doc:getTextFromXPointers(chapter.key, end_xp) or ""
end

function Processor:schedulePoll()
    self.poll_task = function()
        self.poll_task = nil
        self:poll()
    end
    UIManager:scheduleIn(POLL_INTERVAL, self.poll_task)
end

function Processor:poll()
    local child = self.child
    if not child then return end
    local has_data = ffiutil.getNonBlockingReadSize(child.fd) ~= 0
    local done = not has_data and ffiutil.isSubProcessDone(child.pid)
    -- It may have written its answer right before ending: look once more.
    if done then has_data = ffiutil.getNonBlockingReadSize(child.fd) ~= 0 end
    if has_data then
        local raw = ffiutil.readAllFromFD(child.fd)
        if not done then Subprocess.reap(child.pid) end
        self.child = nil
        local ok, result = pcall(json.decode, raw)
        if not ok or type(result) ~= "table" then
            result = { err = { kind = "format", message = "no answer from subprocess" } }
        end
        self:handleResult(child, result)
    elseif done then
        ffiutil.readAllFromFD(child.fd) -- close the pipe
        self.child = nil
        self:handleResult(child, { err = { kind = "network", message = "request ended without answer" } })
    elseif time.to_s(time.since(child.started)) > REQUEST_TIMEOUT then
        Subprocess.cancel(child.pid, child.fd)
        self.child = nil
        self:handleResult(child, { err = { kind = "server", message = "timeout" } })
    else
        self:schedulePoll()
    end
end

function Processor:handleResult(child, result)
    self:allowStandby()
    local store = self.plugin.store
    local batch = child.batch
    local chapter = batch[1]
    if type(result.text) == "string" then
        local notes, reason = Prompt.validate(AI.parseJSON(result.text), batch, child.last_index)
        if notes and notes[chapter.index] then
            for _, batch_chapter in ipairs(batch) do
                local note = notes[batch_chapter.index]
                if note then
                    note.provider = self.cfg.provider
                    note.model = self.cfg.model
                    note.truncated = child.truncated or nil
                    store:addChapterNote(batch_chapter, note)
                    self.plugin:onChapterNoteAdded(batch_chapter)
                end
            end
            store:save()
            self:progress()
            self.retries = 0
            self.models_tried = nil
            self.fail_streak = 0
            -- A fallback model only stands in after a failure: go back to the main one,
            -- but not while it is still resting (it just failed over and over: trying it again
            -- for every batch cost ~5 failed requests each, 19.11.2026).
            if self.primary_model and self.cfg.model ~= self.primary_model
                    and os.time() >= (self.primary_rest_until or 0) then
                self.cfg.model = self.primary_model
                self.using_fallback = false
                -- One failure is enough to send it back to the fallback straight away.
                self.fail_streak = SWITCH_AFTER - 1
            end
            logger.dbg("StoryRecall: chapters", chapter.index, "to", batch[#batch].index, "done")
            self:scheduleNext(self.plugin:getSetting("ai_delay"))
            return
        end
        result.err = { kind = "format", message = reason or "first chapter missing" }
        -- For diagnosis: what the model actually sent (only in the local log).
        logger.warn("StoryRecall: unusable answer from", self.cfg.model, "length", #result.text, ":",
            (result.text:sub(1, 600):gsub("%s+", " ")),
            #result.text > 900 and ("… " .. result.text:sub(-300):gsub("%s+", " ")) or "")
    end

    local err = type(result.err) == "table" and result.err or { kind = "http", message = "unknown error" }
    self.last_error = err
    logger.warn("StoryRecall: chapters from", chapter.index, "failed:", err.kind, err.message)

    if err.kind == "quota" then
        -- No credit left, or the account's limit is used up: retrying won't help.
        self:stop("waiting_quota")
        self.message = "quota:credit"
        self.plugin:onAIBlocked("credit")
        return
    end
    if err.kind == "auth" or err.kind == "config" then
        self:stop("error")
        self.message = err.expired and "auth:expired" or (err.kind .. ":" .. tostring(err.message))
        if err.kind == "auth" then self.plugin:onAIBlocked(err.expired and "expired" or "auth") end
        return
    end
    if err.kind == "network" and not NetworkMgr:isConnected() then
        self:stop("waiting_network")
        return
    end
    -- Answer cut off (too long), declined, or broken JSON for several chapters:
    -- try again with one chapter at a time before giving up on a chapter.
    if (err.kind == "too_long" or err.kind == "refused" or err.kind == "format") and #batch > 1 then
        self.single_batch = true
        self:scheduleNext(1)
        return
    end
    if err.kind == "refused" or err.kind == "too_long" then
        -- Even a single chapter does not work: note it and go on.
        store:setChapterFailure(chapter, err.kind .. ": " .. tostring(err.message))
        store:save()
        self:scheduleNext(self.plugin:getSetting("ai_delay"))
        return
    end
    -- Overloaded, limit reached or no answer in time. Setting "on overload":
    -- "wait" (default) stays with the chosen model, so a book's notes come from
    -- one model and never from a pricier one; "switch" tries the provider's
    -- other models after SWITCH_AFTER failures in a row (a daily limit at once,
    -- it won't pass by waiting).
    -- (A lost connection is no reason to switch models: just wait.)
    local transient = err.kind == "rate_limit" or err.kind == "server" or err.kind == "timeout"
    if transient and self.cfg.switch_models then
        self.fail_streak = (self.fail_streak or 0) + 1
        if self.fail_streak >= SWITCH_AFTER or (err.kind == "rate_limit" and err.daily) then
            self.fail_streak = 0
            local next_model = self:nextModel()
            if next_model then
                logger.info("StoryRecall:", err.kind, "- switching to model", next_model)
                if self.cfg.model == self.primary_model then
                    -- Let the main model rest: a daily limit longer, overload shorter.
                    self.primary_rest_until = os.time()
                        + ((err.kind == "rate_limit" and err.daily) and Processor.REST_DAILY or Processor.REST_OVERLOAD)
                end
                self.cfg.model = next_model
                self.using_fallback = next_model ~= self.primary_model
                self:setState("waiting_retry", err.kind == "rate_limit" and "rate_limit" or "server")
                self:scheduleNext(1)
                return
            end
            self.models_tried = nil -- every model was tried: wait, then go round again
        end
    end
    if transient then
        if err.kind == "rate_limit" and err.daily then
            -- Every model has used up its daily requests: no point in retrying
            -- every minute. Wait until the provider says it resets.
            self.retries = 0
            self:stop("waiting_quota")
            self.message = "quota:daily"
            self.plugin:onQuotaReached(math.max(err.retry_after or QUOTA_WAIT, 60))
            return
        end
    end
    self.retries = self.retries + 1
    if self.retries > MAX_RETRIES then
        self.retries = 0
        if (err.kind == "server" or err.kind == "timeout") and not self.cfg.switch_models then
            -- "Wait": stay with the model until it answers again, in longer pauses.
            self:setState("waiting_retry", "server")
            self:scheduleNext(OVERLOAD_WAIT)
            return
        end
        if err.kind == "rate_limit" then
            -- Still limited after all models and several minutes: most likely
            -- a daily limit. Wait an hour, then try again by itself.
            self:stop("waiting_quota")
            self.message = "quota:limit"
            self.plugin:onQuotaReached(QUOTA_WAIT)
            return
        end
        if not TRANSIENT[err.kind] then
            store:setChapterFailure(chapter, err.kind .. ": " .. tostring(err.message))
            store:save()
        end
        self:stop("error")
        self.message = err.kind .. ":" .. tostring(err.message)
        return
    end
    local wait
    if err.kind == "rate_limit" then
        wait = err.retry_after or RATE_LIMIT_WAIT
    elseif err.kind == "server" then
        -- Provider overloaded: 2, 4, 8, 8 ... minutes. Such spikes last a while, and every
        -- failed attempt may count against a free daily limit (Gemini, 17.11.2026).
        wait = math.min(Processor.OVERLOAD_RETRY * 2 ^ (self.retries - 1), Processor.OVERLOAD_RETRY_MAX)
    else
        wait = math.min(30 * self.retries, 120)
    end
    -- The status line tells overload, limit and an unusable answer apart.
    self:setState("waiting_retry", (err.kind == "rate_limit" or err.kind == "format") and err.kind or "server")
    self:scheduleNext(wait)
end

--- The next model to try after a failure: the provider's models in their
-- order (best first), the small fallback model last, each once per round.
-- (Going straight to the fallback gave a whole book of weaker notes while the
-- main model was overloaded for a while.)
function Processor:nextModel()
    self.models_tried = self.models_tried or {}
    self.models_tried[self.cfg.model] = true
    local candidates = {}
    local provider = AI.getProvider(self.cfg.provider)
    for _, model in ipairs(provider and provider.models or {}) do
        if model ~= self.cfg.fallback_model then table.insert(candidates, model) end
    end
    table.insert(candidates, self.cfg.fallback_model)
    table.insert(candidates, self.primary_model)
    for _, model in ipairs(candidates) do
        if model and not self.models_tried[model] then
            return model
        end
    end
end

--- Send a tiny request to check provider, model and key. Calls back with (ok, err).
function Processor.testConnection(cfg, callback)
    if runInline() then
        UIManager:scheduleIn(0.2, function()
            local answer, err = AI.complete(cfg, "Reply with the JSON object {\"ok\": true} and nothing else.", "Test", nil)
            callback(type(answer) == "string", err)
        end)
        return
    end
    local pid, fd = ffiutil.runInSubProcess(function(_pid, write_fd)
        local answer, err = AI.complete(cfg, "Reply with the JSON object {\"ok\": true} and nothing else.", "Test", nil)
        Subprocess.writeAll(write_fd, json.encode({ text = answer, err = err }))
    end, true)
    if not pid then return callback(false, { kind = "subprocess" }) end
    local started = time.now()
    local function check()
        if ffiutil.getNonBlockingReadSize(fd) ~= 0 then
            local ok, result = pcall(json.decode, ffiutil.readAllFromFD(fd))
            ffiutil.isSubProcessDone(pid)
            if ok and type(result) == "table" and type(result.text) == "string" then
                return callback(true)
            end
            return callback(false, ok and type(result) == "table" and result.err or { kind = "format" })
        elseif ffiutil.isSubProcessDone(pid) then
            return callback(false, { kind = "network" })
        elseif time.to_s(time.since(started)) > 60 then
            ffiutil.terminateSubProcess(pid)
            return callback(false, { kind = "server", message = "timeout" })
        end
        UIManager:scheduleIn(POLL_INTERVAL, check)
    end
    UIManager:scheduleIn(POLL_INTERVAL, check)
end

return Processor
