--[[--
Story Recall: reminds you of the story so far, spoiler-free.

Chapter, break and series detection, own notes per chapter, AI chapter notes
processed in the background, the story chronicle and the recap.
--]]

local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local time = require("ui/time")
local logger = require("logger")
local util = require("util")
local AIMenu = require("storyrecall/aimenu")
local Chapters = require("storyrecall/chapters")
local Context = require("storyrecall/context")
local Guide = require("storyrecall/guide")
local Processor = require("storyrecall/processor")
local Series = require("storyrecall/series")
local Store = require("storyrecall/store")
local Views = require("storyrecall/views")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local SETTINGS_KEY = "story_recall"
local DEFAULTS = {
    welcome_enabled = true,
    welcome_ask = true, -- after a break: ask before showing the recap
    pause_days = 7,
    recap_chapters = 3,
    ai_provider = "gemini",
    ai_whole_book = true,
    ai_on_overload = "wait", -- "wait": stay with the chosen model; "switch": other models after 3 failures
    ai_delay = 5,
    ai_when = "charging", -- "wifi" | "charging" | "manual": when processing starts by itself
    ai_batch_chapters = 3,
    ai_wifi_when_charging = true, -- turn Wi-Fi on while charging when notes are missing
}
-- Page jumps up to this size still count as reading on (not as skipping ahead).
local MAX_READING_STEP = 2
-- A longer break means the clock was wrong (reset after an empty battery).
local MAX_BREAK = 5 * 365 * 86400

local StoryRecall = WidgetContainer:extend{
    name = "storyrecall",
    -- Also loaded in the file browser, only for the ZenOS Home widget.
    is_doc_only = false,
}

-- Book opened from the ZenOS Home widget: show its recap once it is ready.
local open_with_recap

function StoryRecall:init()
    self.settings = G_reader_settings:readSetting(SETTINGS_KEY, {})
    for k, v in pairs(DEFAULTS) do
        if self.settings[k] == nil then self.settings[k] = v end
    end
    self:registerZenOSHome()

    -- In the file browser there is nothing else to do.
    local file = self.ui.document and self.ui.document.file
    if not file then return end

    -- Comics: Story Recall ganz aus (kein Menue, keine Gesten, keine Rueckblick-Frage, keine KI).
    -- Auch keine Ereignisse, damit nichts im Hintergrund anspringt.
    if require("storyrecall/comic").isComic(file) then
        self.comic = true
        self.handleEvent = function() return false end
        return
    end

    -- Our entry goes to the top of the reader's Tools menu. The plugins used
    -- most often share one fixed order there, whichever is loaded first.
    local TOP = { "story_recall", "guitar_tab_reader", "comicdisplay" }
    local tools = require("ui/elements/reader_menu_order").tools
    for i = #tools, 1, -1 do if tools[i] == "story_recall" then table.remove(tools, i) end end
    local my_rank, pos = util.arrayContains(TOP, "story_recall"), 1
    for i, key in ipairs(tools) do
        local rank = util.arrayContains(TOP, key)
        if rank and rank < my_rank then pos = i + 1 end
    end
    table.insert(tools, pos, "story_recall")
    self.ui.menu:registerToMainMenu(self)
    self:onDispatcherRegisterActions()
    self:registerLookupButtons()

    self.store = Store.open(file)
    self.processor = Processor.new(self)
    -- Wi-Fi stays on while the AI works (KOReader would turn it off mid-request).
    local WifiHold = require("storyrecall/wifihold")
    WifiHold.install()
    WifiHold.set("storyrecall", function()
        return (self.processor and self.processor:isActive()) or self.recap_job ~= nil or self.lookup_job ~= nil
    end)

    -- Books opened before the plugin was installed have no own timestamp yet.
    -- KOReader's metadata file was last written when the book was last closed
    -- or the device went to sleep, and it has not been rewritten yet at this point.
    self.last_seen = self.store:getLastSeen()
    if not self.last_seen then
        local sidecar = DocSettings:findSidecarFile(file)
        self.last_seen = sidecar and lfs.attributes(sidecar, "modification")
    end
end

-- ZenOS: Home widget. ZenOS may load after this plugin; then it announces
-- itself with ZenOSReady (ZenUIReady in older versions).
function StoryRecall:registerZenOSHome()
    require("storyrecall/zenos").registerHome(function(file)
        if not file then return end
        open_with_recap = file
        local ReaderUI = require("apps/reader/readerui")
        ReaderUI:showReader(file)
    end)
end

function StoryRecall:onZenOSReady()
    self:registerZenOSHome()
end
StoryRecall.onZenUIReady = StoryRecall.onZenOSReady

-- Actions for gestures, ZenOS Controls/Navbar/Launcher and everything else
-- that uses KOReader's action picker.
function StoryRecall:onDispatcherRegisterActions()
    Dispatcher:registerAction("storyrecall_recap",
        { category = "none", event = "StoryRecallShowRecap", title = "Story Recall: " .. _("Recap"), reader = true })
    Dispatcher:registerAction("storyrecall_chronicle",
        { category = "none", event = "StoryRecallShowChronicle", title = "Story Recall: " .. _("Story chronicle"), reader = true })
    Dispatcher:registerAction("storyrecall_series",
        { category = "none", event = "StoryRecallShowSeriesRecap", title = "Story Recall: " .. _("Series recap"), reader = true })
    Dispatcher:registerAction("storyrecall_process",
        { category = "none", event = "StoryRecallProcess", title = "Story Recall: " .. _("Create AI notes now"), reader = true })
    Dispatcher:registerAction("storyrecall_characters",
        { category = "none", event = "StoryRecallShowCharacters", title = "Story Recall: " .. _("Story lexicon"), reader = true })
    Dispatcher:registerAction("storyrecall_add_note",
        { category = "none", event = "StoryRecallAddNote", title = "Story Recall: " .. _("Add note to current chapter"), reader = true })
    Dispatcher:registerAction("storyrecall_rewrite",
        { category = "none", event = "StoryRecallRewrite", title = "Story Recall: " .. _("Rewrite the story so far"), reader = true })
end

function StoryRecall:onStoryRecallRewrite()
    if self.store then self:rewriteStorySoFar() end
    return true
end

function StoryRecall:onStoryRecallShowRecap()
    if self.store then self:showRecap() end
    return true
end

function StoryRecall:onStoryRecallShowChronicle()
    if self.store then self:showChronicle() end
    return true
end

function StoryRecall:onStoryRecallProcess()
    if not self.processor then return true end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        self.store:clearChapterFailures()
        self:setSetting("ai_quota_wait_until", nil)
        self.ai_block_notified = nil -- a new failure may tell again
        local ok, reason = self.processor:start()
        if ok then
            UIManager:show(InfoMessage:new{ text = _("Creating AI notes in the background."), timeout = 2 })
        elseif reason == "done" then
            UIManager:show(InfoMessage:new{ text = _("All chapters already have AI notes."), timeout = 2 })
        else
            UIManager:show(InfoMessage:new{ text = require("storyrecall/aimenu").statusText(self) })
        end
    end)
    return true
end

function StoryRecall:onStoryRecallShowCharacters()
    if self.store then self:showCharacters() end
    return true
end

function StoryRecall:onStoryRecallAddNote()
    if self.store then self:addNoteToCurrentChapter() end
    return true
end

-- Settings helpers

function StoryRecall:getSetting(key)
    return self.settings[key]
end

function StoryRecall:setSetting(key, value)
    self.settings[key] = value
    G_reader_settings:saveSetting(SETTINGS_KEY, self.settings)
end

-- Book and position

function StoryRecall:getBookInfo()
    local props = self.ui.doc_props or {}
    return {
        title = props.display_title or props.title,
        authors = props.authors,
        series = props.series,
        series_index = props.series_index,
        language = props.language,
    }
end

function StoryRecall:getCurrentPage()
    return self.ui:getCurrentPage()
end

function StoryRecall:getCurrentChapter()
    return Chapters.atPage(self.ui, self:getCurrentPage(), self:getBookInfo().title)
end

function StoryRecall:buildContext()
    local chapter = self:getCurrentChapter()
    -- Strictly the furthest chapter read: jumping ahead (TOC, search) must not
    -- reveal the chapters skipped over.
    local furthest = self.store:getFurthestChapter() or 0
    local read_chapter = Chapters.byIndex(self.ui, furthest)
    if not read_chapter then
        -- Nothing read yet: never fall back to the current chapter (the reader
        -- may have jumped there). Books without a TOC are a single chapter.
        read_chapter = Chapters.hasToc(self.ui) and Chapters.front() or chapter
    end
    -- AI notes describe a chapter up to its end, so they are only shown for
    -- chapters the reader has finished.
    local ai_index = read_chapter.index
    local entry = read_chapter.index > 0 and self.store:getChapter(read_chapter.key)
    if read_chapter.index > 0 and not (entry and entry.completed_at) then
        local prev = Chapters.prev(self.ui, read_chapter.index)
        ai_index = prev and prev.index or 0
    end
    -- The recap follows where the reader is: the story up to the chapter
    -- before the current one, so going back in the book recaps up to there.
    -- The current chapter counts once its last page is reached and it is
    -- finished (reaching the last page of the book finishes the last
    -- chapter, but reading in it should still recap the one before).
    -- Never beyond ai_index.
    local recap_index = ai_index
    if chapter.index > 0 then
        local before = Chapters.prev(self.ui, chapter.index)
        local upto = before and before.index or 0
        local after = Chapters.next(self.ui, chapter.index)
        local last_page = after and after.page - 1 or self.ui.document:getPageCount()
        local current = self.store:getChapter(chapter.key)
        if self:getCurrentPage() >= last_page and current and current.completed_at then
            upto = chapter.index
        end
        recap_index = math.min(ai_index, upto)
    end
    -- Last page of the furthest chapter read.
    local next_chapter = Chapters.next(self.ui, read_chapter.index)
    local read_limit_page = next_chapter and next_chapter.page - 1 or self.ui.document:getPageCount()
    -- Own notes and highlights in the recap: after going back in the book,
    -- only up to the current chapter (like the story so far).
    local recap_upto, recap_limit_page = read_chapter.index, read_limit_page
    if chapter.index > 0 and chapter.index < read_chapter.index then
        recap_upto = chapter.index
        local after_current = Chapters.next(self.ui, chapter.index)
        recap_limit_page = after_current and after_current.page - 1 or read_limit_page
    end
    -- Text passages: finished chapters, plus the current page when reading at the frontier.
    local passage_limit_page = 0
    if ai_index > 0 then
        local after = Chapters.next(self.ui, ai_index)
        -- After the last chapter there is no next one: up to the end of the book.
        passage_limit_page = after and after.page - 1 or self.ui.document:getPageCount()
    end
    if chapter.index == read_chapter.index then
        passage_limit_page = math.max(passage_limit_page, self:getCurrentPage())
    end
    local chapters = Chapters.upTo(self.ui, read_chapter.index)
    if #chapters == 0 and not Chapters.hasToc(self.ui) then
        chapters = { read_chapter }
    end
    return {
        ui = self.ui,
        store = self.store,
        book = self:getBookInfo(),
        chapter = chapter,
        read_chapter = read_chapter,
        ai_index = ai_index,
        recap_index = recap_index,
        recap_upto = recap_upto,
        recap_limit_page = recap_limit_page,
        read_limit_page = read_limit_page,
        passage_limit_page = passage_limit_page,
        chapters = chapters,
        recap_chapters = self:getSetting("recap_chapters"),
        last_seen = self.last_seen,
    }
end

-- AI processing

--- Language the AI writes the notes in: KOReader's language, or the book's.
function StoryRecall:getNotesLanguage()
    local book_language = self:getBookInfo().language
    if self:getSetting("ai_notes_language") == "book" then return book_language end
    return G_reader_settings:readSetting("language") or book_language
end

--- Last chapter the AI may process: all chapters, or only those read so far.
function StoryRecall:getProcessingLimit()
    if self:getSetting("ai_whole_book") then return nil end
    return self.store:getFurthestChapter() or 0
end

local function isCharging()
    local Device = require("device")
    local powerd = Device.getPowerDevice and Device:getPowerDevice()
    return powerd and powerd:isCharging() or false
end

--- While charging, Wi-Fi may have been turned off (by hand or by KOReader
-- after a while): turn it on if there is something to process.
-- @return true if Wi-Fi is being turned on (processing starts once connected)
function StoryRecall:turnOnWifiForProcessing()
    if not self:getSetting("ai_wifi_when_charging") or self.wifi_connecting then return false end
    local Device = require("device")
    local NetworkMgr = require("ui/network/manager")
    if NetworkMgr:isConnected() or not (Device.hasWifiToggle and Device:hasWifiToggle()) then return false end
    if #self.processor:pendingChapters() == 0 then return false end
    self.wifi_connecting = true
    logger.info("StoryRecall: charging, turning Wi-Fi on for the AI notes")
    local ok = NetworkMgr:turnOnWifiAndWaitForConnection(function()
        self.wifi_connecting = false
        -- Unplugged or book closed in the meantime: nothing to do.
        if self.processor and self.ui and self.ui.document and isCharging() then self.processor:start() end
    end)
    if ok == false then self.wifi_connecting = false end
    -- No callback when the connection fails: allow a new attempt later.
    UIManager:scheduleIn(90, function() self.wifi_connecting = false end)
    return true
end

--- Start background processing by itself, if the settings allow it now.
-- Quiet: never shows dialogs; turns Wi-Fi on only while charging (setting).
function StoryRecall:startProcessing()
    if not self.processor then return end
    local AI = require("storyrecall/ai")
    if not AI.configFrom(self.settings) then return end
    local when = self:getSetting("ai_when")
    if when == "manual" then return end
    if when == "charging" and not isCharging() then return end
    -- The provider's limit was reached recently: don't ask again yet, but
    -- make sure a retry is planned (also after reopening the book).
    local wait_until = self:getSetting("ai_quota_wait_until") or 0
    if os.time() < wait_until then
        self:scheduleQuotaRetry(wait_until - os.time())
        return
    end
    if when == "charging" and self:turnOnWifiForProcessing() then return end
    self.processor:start()
end

--- The provider's limit stayed reached: try again later by itself.
function StoryRecall:onQuotaReached(wait)
    self:setSetting("ai_quota_wait_until", os.time() + wait)
    self:scheduleQuotaRetry(wait)
end

function StoryRecall:scheduleQuotaRetry(wait)
    if self.quota_task then UIManager:unschedule(self.quota_task) end
    self.quota_task = function()
        self.quota_task = nil
        if self.processor and not self.processor:isActive() then
            self:startProcessing()
        end
    end
    -- The timer does not count time in sleep; onResume checks the deadline again.
    UIManager:scheduleIn(wait + 5, self.quota_task)
end

-- Seconds to wait after plugging in: a USB cable also asks about mass storage
-- (KOReader then closes the book); only plain charging should start anything.
local CHARGING_DELAY = 15

function StoryRecall:onCharging()
    if self:getSetting("ai_when") ~= "charging" then return end
    if self.charging_task then UIManager:unschedule(self.charging_task) end
    self.charging_task = function()
        self.charging_task = nil
        if self.processor and self.ui and self.ui.document then self:startProcessing() end
    end
    UIManager:scheduleIn(CHARGING_DELAY, self.charging_task)
end

function StoryRecall:onNotCharging()
    if self.charging_task then
        UIManager:unschedule(self.charging_task)
        self.charging_task = nil
    end
    -- Unplugged: stop, so processing does not drain the battery.
    if self.processor and self:getSetting("ai_when") == "charging" and self.processor:isActive() then
        self.processor:stop("stopped")
    end
end

--- Phone setup of the API key (QR code); afterwards offer to start right away.
function StoryRecall:startKeySetup()
    if self.ui.menu then self.ui.menu:onCloseReaderMenu() end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        require("storyrecall/keysetup").start(self:getSetting("ai_provider"), function(provider_id, custom)
            self:setSetting("ai_provider", provider_id)
            if custom then
                self:setSetting("ai_custom_url", custom.url)
                local models = self:getSetting("ai_models") or {}
                models.custom = custom.model
                self:setSetting("ai_models", models)
            end
            self:onApiKeySaved()
        end, {
            url = self:getSetting("ai_custom_url"),
            model = (self:getSetting("ai_models") or {}).custom,
        })
    end)
end

--- After any way of entering a key: ask whether to create the notes now.
function StoryRecall:onApiKeySaved()
    if not self.processor then return end
    self.ai_block_notified = nil
    if AIMenu.nothingToDo(self) then
        -- Nothing missing: offer to re-create instead (e.g. after switching to a better provider).
        AIMenu.confirmRecreate(self, _("API key saved. This book already has all AI notes."),
            _("Re-create with the new key"), nil, _("Done"))
        return
    end
    Guide.offerStart(function() self:onStoryRecallProcess() end)
end

--- The AI notes stopped for good (no credit, key rejected or expired): tell the
-- reader once, with a way to the AI settings. Only once per failure, so it does
-- not come back on every page; a new start by the reader may tell again.
-- @param reason "credit", "expired" or "auth"
--- Use a set of AI notes that was put aside ("Earlier AI notes"); the current
-- ones are kept instead. Missing chapters are processed as usual.
function StoryRecall:restoreSavedNotes(id)
    if not self.store then return false end
    if self.processor then self.processor:stop("stopped") end
    if not self.store:restoreChapterNotes(id) then return false end
    self.store:save()
    self:archiveVolume()
    UIManager:show(InfoMessage:new{ text = _("The earlier AI notes are back."), timeout = 2 })
    self:startProcessing()
    return true
end

--- Live progress: redraw the status line if Story Recall's menu is open
-- (called by the processor after each batch and when its state changes).
function StoryRecall:refreshStatusMenu()
    UIManager:nextTick(function()
        if self.ui and self.ui.menu then AIMenu.refreshOpenMenu(self) end
    end)
end

function StoryRecall:onAIBlocked(reason)
    if self.ai_block_notified then return end
    self.ai_block_notified = true
    local AI = require("storyrecall/ai")
    local provider = AI.getProvider(self:getSetting("ai_provider")) or AI.PROVIDERS[1]
    local name = _(provider.name)
    local text
    if reason == "credit" then
        text = T(_("Story Recall: no credit left at %1. The AI notes are paused.\n\nTop up your account, or choose another provider in the AI settings."), name)
    elseif reason == "expired" then
        text = T(_("Story Recall: the %1 API key has expired. The AI notes are paused.\n\nEnter a new key in the AI settings."), name)
    else
        text = T(_("Story Recall: %1 rejected the API key (wrong, deleted or expired). The AI notes are paused.\n\nCheck the key in the AI settings."), name)
    end
    UIManager:show(ConfirmBox:new{
        text = text,
        ok_text = _("Open AI settings"),
        cancel_text = _("OK"),
        ok_callback = function() self:openSettingsMenu() end,
    })
end

function StoryRecall:showGuide()
    Guide.show(function() self:startKeySetup() end)
end

function StoryRecall:onChapterNoteAdded(chapter)
    logger.dbg("StoryRecall: AI note for chapter", chapter.index)
    -- Once per batch, not once per chapter (fewer writes to flash memory).
    if self.archive_task then UIManager:unschedule(self.archive_task) end
    self.archive_task = function()
        self.archive_task = nil
        self:archiveVolume()
        -- All chapters have notes (book read to the end): write the volume summary
        -- for the next volume's series recap, quietly in the background.
        local data = self.store and self.store.data
        local last = data and data.last_chapter_index
        if last and not data.volume_summary and self.store:countChapterNotes() > 1 then
            local has_last = false
            for _key, note in pairs(data.ai_chapters or {}) do
                if note.index == last then has_last = true end
            end
            if has_last and require("ui/network/manager"):isConnected() then
                self:createVolumeSummary(self.store, self:getBookInfo(), { quiet = true })
            end
        end
    end
    UIManager:scheduleIn(2, self.archive_task)
end

local askModels -- defined further down (one request, best models first)

--- Write the summary of a whole volume (for the next volume's series recap) in
-- its own request, from all chapter summaries, and keep it in the book's data
-- and the series archive.
-- @param store the volume's Store (this book, or an earlier volume's)
-- @param book { title, authors, series, series_index, language }
-- @param opts { quiet = no messages (background), on_done = function(ok) }
function StoryRecall:createVolumeSummary(store, book, opts)
    opts = opts or {}
    local function done(ok, message)
        if message and not opts.quiet then UIManager:show(InfoMessage:new{ text = message }) end
        if opts.on_done then opts.on_done(ok) end
    end
    if self.volume_job and not self.volume_job.done then return done(false) end
    local AI = require("storyrecall/ai")
    local Prompt = require("storyrecall/prompt")
    local cfg = AI.configFrom(self.settings)
    if not cfg then return done(false, _("No AI is set up yet. See Story Recall → Settings → AI.")) end
    local notes = store:getChapterNotes()
    if #notes < 2 then return done(false, _("There are not enough AI notes for this yet.")) end
    local chapters, protagonist = {}, nil
    for _i, note in ipairs(notes) do
        table.insert(chapters, { index = note.index, title = note.title, summary = note.summary })
        protagonist = note.protagonist or protagonist
    end
    local message = Prompt.buildVolume{
        book = book, notes_language = self:getNotesLanguage(), protagonist = protagonist, chapters = chapters,
    }
    local function request()
        local result = askModels(cfg, Prompt.VOLUME_SYSTEM, message, Prompt.VOLUME_SCHEMA, Prompt.validateVolume)
        return result.value and { text = result.value, model = result.model } or { err = result.err }
    end
    local function finish(result)
        self.volume_job = nil
        if not (result and result.text) then
            logger.warn("StoryRecall: volume summary failed:", result and result.err and result.err.kind)
            return done(false, T(_("The volume summary could not be written: %1"),
                AIMenu.describeError(result and result.err or {})))
        end
        store.data.volume_summary = { text = result.text, model = result.model, created = os.time() }
        store:markDirty()
        store:save()
        pcall(Series.archive, book, store == self.store and self:archiveData() or store.data)
        logger.info("StoryRecall: volume summary written with", result.model)
        done(true)
    end
    local job = require("storyrecall/subprocess").run{
        text = not opts.quiet and _("Writing the volume summary… This may take a moment.") or nil,
        work = request,
        on_done = finish,
    }
    if not job.done then self.volume_job = job end
end

--- This book's Story Recall data for the series archive: marked as finished in
-- KOReader, it counts as read in full (also when read elsewhere).
function StoryRecall:archiveData()
    local summary = self.ui and self.ui.doc_settings and self.ui.doc_settings:readSetting("summary")
    if type(summary) == "table" and summary.status == "complete" then
        return Series.asFinished(self.store.data)
    end
    return self.store.data
end

--- Keep this volume's summary in the series archive, so the series recap
-- still finds it after the book was deleted.
function StoryRecall:archiveVolume()
    if not self.store then return end
    local ok, err = pcall(Series.archive, self:getBookInfo(), self:archiveData())
    if not ok then logger.warn("StoryRecall: archiving failed:", err) end
end

function StoryRecall:onNetworkConnected()
    if self.processor and self.processor.state == "waiting_network" then
        self:startProcessing()
    end
end

-- Events

function StoryRecall:onReaderReady()
    if not self.store then return end
    self.store:setBookInfo(self:getBookInfo())
    self:checkTocChanged()
    -- The series recap needs to know whether a volume was read to its end.
    local all = Chapters.upTo(self.ui, math.huge)
    if all[#all] and self.store.data.last_chapter_index ~= all[#all].index then
        self.store.data.last_chapter_index = all[#all].index
        self.store:markDirty()
    end
    -- Older data has no xpointer for the reading point yet.
    if self.store.data.furthest_chapter and not self.store.data.furthest_key then
        local chapter = Chapters.byIndex(self.ui, self.store.data.furthest_chapter)
        self.store.data.furthest_key = chapter and chapter.key
    end
    self:startSession()
    self.last_page = self:getCurrentPage()
    self.last_chapter = self:getCurrentChapter()
    -- Books started before the plugin was installed: assume everything up to
    -- the current chapter has been read.
    if not self.store:getFurthestChapter() then
        self.store:setFurthestChapter(self.last_chapter.index, self.last_chapter.key)
    end
    if open_with_recap == self.ui.document.file then
        open_with_recap = nil
        UIManager:scheduleIn(0.5, function() self:showRecap() end)
    elseif not self:getSetting("guide_shown") then
        -- First use ever: explain the setup instead of a recap.
        self:setSetting("guide_shown", true)
        UIManager:scheduleIn(0.5, function() self:showGuide() end)
    elseif not self:checkForSeriesStart() then
        self:checkForBreak()
    end
    self:startProcessing()
end

function StoryRecall:onPageUpdate(pageno)
    if not self.store or not pageno then return end
    local prev_page, prev_chapter = self.last_page, self.last_chapter
    local chapter = Chapters.atPage(self.ui, pageno, self:getBookInfo().title)
    self.last_page, self.last_chapter = pageno, chapter
    if not (prev_page and prev_chapter) then return end
    -- Remember the state before this update: if it came from a re-layout
    -- (font change), onDocumentRerendered undoes it.
    local snapshot = { at = time.now(), furthest = self.store.data.furthest_chapter,
        furthest_key = self.store.data.furthest_key, completed = {}, session_read = self.session_read }
    self.progress_snapshot = snapshot
    -- Turning a page means this session is real reading (see rememberSession).
    if self.session_page and pageno ~= self.session_page then self.session_read = true end
    local function complete(ch)
        if self.store:markChapterCompleted(ch) then table.insert(snapshot.completed, ch.key) end
    end

    -- Reading on into a new chapter completes the previous one(s).
    -- Jumps (TOC, search, skimming) don't count.
    local step = pageno - prev_page
    -- Only a step that starts inside what was already read, or in the chapter
    -- right after it, counts: after a jump far ahead (footnote at the end of
    -- the book, TOC, search), turning one page must not unlock everything up
    -- to there.
    local furthest = self.store:getFurthestChapter() or 0
    local frontier = Chapters.next(self.ui, furthest)
    local frontier_index = frontier and frontier.index or furthest
    local reading_on = step > 0 and step <= MAX_READING_STEP and prev_chapter.index <= frontier_index
    if reading_on then
        local before = self.store:getFurthestChapter()
        self.store:setFurthestChapter(chapter.index, chapter.key)
        if before ~= self.store:getFurthestChapter() and not self:getSetting("ai_whole_book") then
            -- A newly read chapter can be processed; start after the page is drawn.
            UIManager:scheduleIn(1, function()
                if self.processor then self:startProcessing() end
            end)
        end
    end
    -- Reaching the last page finishes the last chapter (books often end with
    -- pages of ads that still belong to it).
    if reading_on and pageno >= self.ui.document:getPageCount() and chapter.index > 0 then
        complete(chapter)
    end
    if reading_on and chapter.index > prev_chapter.index then
        if prev_chapter.index > 0 then -- front matter is not a chapter
            complete(prev_chapter)
        end
        -- Chapters passed over in one page turn (very short ones); hidden TOC
        -- levels are not chapters.
        local skipped = Chapters.next(self.ui, prev_chapter.index)
        while skipped and skipped.index < chapter.index do
            complete(skipped)
            skipped = Chapters.next(self.ui, skipped.index)
        end
    end
end

-- Scroll mode ("continuous" view) sends position updates instead of page updates.
function StoryRecall:onPosUpdate(_pos, pageno)
    if self.ui.view and self.ui.view.view_mode ~= "page" and pageno then
        self:onPageUpdate(pageno)
    end
end

-- After a font or layout change KOReader sends the page update first and
-- then this event: the page step just seen was not reading. Undo it and start
-- counting again from the new layout.
function StoryRecall:onDocumentRerendered()
    if not self.store then return end
    local snapshot = self.progress_snapshot
    -- Real time (os.clock would count CPU time, which barely moves while reading).
    if snapshot and time.to_s(time.since(snapshot.at)) < 1 then
        self.store:restoreProgress(snapshot.furthest, snapshot.furthest_key, snapshot.completed)
        self.session_read = snapshot.session_read
    end
    self.progress_snapshot = nil
    -- The TOC's page numbers are updated by now or on the next tick.
    UIManager:nextTick(function()
        if not (self.ui and self.ui.document) then return end
        self.last_page = self:getCurrentPage()
        self.last_chapter = self:getCurrentChapter()
        if not self.session_read then self.session_page = self.last_page end
    end)
end

--- The TOC was rebuilt (alternative TOC, custom TOC): find chapters again by xpointer.
function StoryRecall:onTocReset()
    self:checkTocChanged()
end

function StoryRecall:checkTocChanged()
    if not self.store then return end
    local signature = Chapters.signature(self.ui)
    local old = self.store.data.toc_signature
    if old == signature then return end
    if old then
        self.store:renumber(function(key) return Chapters.indexForXPointer(self.ui, key) end)
        logger.info("StoryRecall: TOC changed, chapters renumbered")
    end
    self.store.data.toc_signature = signature
    self.store:markDirty()
    if self.ui.document then
        self.last_page = self:getCurrentPage()
        self.last_chapter = self:getCurrentChapter()
    end
end

-- Series and other book info edited in KOReader's "Book information".
function StoryRecall:onBookMetadataChanged()
    if not self.store then return end
    self.store:setBookInfo(self:getBookInfo())
end

function StoryRecall:onEndOfBook()
    if not self.store then return end
    self.store:markChapterCompleted(self:getCurrentChapter())
end

function StoryRecall:onSuspend()
    if not self.store then return end
    -- Wi-Fi goes away during sleep; continue after waking up.
    self.resume_processing = self.processor:isActive()
    if self.resume_processing then self.processor:stop("stopped") end
    -- Single requests (rewrite, ask the AI, internet summary) would only run
    -- into a timeout without Wi-Fi: stop them; the reader can start them again.
    self:cancelWebSummary()
    self:cancelRecapRewrite()
    self:cancelLookup()
    self:rememberSession()
    self.store:save()
    self:archiveVolume()
end

function StoryRecall:onResume()
    if not self.store then return end
    self.last_seen = self.store:getLastSeen() or self.last_seen
    self:startSession()
    self:checkForBreak()
    if self.processor.state == "waiting_quota" and (self.processor.message == "quota:limit" or self.processor.message == "quota:daily") then
        self:startProcessing() -- starts if the waiting time has passed during sleep
    end
    if self.resume_processing then
        self.resume_processing = false
        self.processor.state = "waiting_network"
        self:startProcessing()
    end
end

function StoryRecall:onSaveSettings()
    if not self.store then return end
    self.store:save()
end

function StoryRecall:onCloseDocument()
    self:cancelWebSummary()
    self:cancelRecapRewrite()
    self:cancelLookup()
    if self.archive_task then
        UIManager:unschedule(self.archive_task)
        self.archive_task = nil
    end
    if self.quota_task then
        UIManager:unschedule(self.quota_task)
        self.quota_task = nil
    end
    if self.charging_task then
        UIManager:unschedule(self.charging_task)
        self.charging_task = nil
    end
    if not self.store then return end
    require("storyrecall/wifihold").set("storyrecall", nil)
    self.processor:stop("stopped")
    self:rememberSession()
    self.store:save()
    self:archiveVolume()
end

--- End of a session (book closed, device asleep): remember when it was read,
-- but only if it really was: the reader turned a page or answered the break
-- question. A quick look (where was I?) or waking the device to check the
-- time must not end a real break.
function StoryRecall:rememberSession()
    if self.session_read then
        self.store:setLastSeen(os.time())
        self.last_seen = self.store:getLastSeen()
    end
    self.session_read = false
end

--- A new session starts here (book opened, device woken up).
function StoryRecall:startSession()
    self.session_read = false
    self.session_page = self:getCurrentPage()
end

-- Series recap

--- Starting a later volume of a series: show what happened in the earlier ones (once).
-- @return true if the series recap is shown
function StoryRecall:checkForSeriesStart()
    local book = self:getBookInfo()
    if not tonumber(book.series_index) or tonumber(book.series_index) <= 1 then return false end
    if self.store.data.series_recap_shown or (self.store:getFurthestChapter() or 0) > 1 then return false end
    local volumes = Series.previousVolumes(self.ui.document.file, book)
    local candidate = #volumes == 0 and self:linkCandidate(book, true)
    if #volumes == 0 and not candidate then return false end
    self.store.data.series_recap_shown = true
    self.store:markDirty()
    UIManager:scheduleIn(0.5, function()
        if not (self.ui and self.ui.document) then return end
        if candidate then
            -- Already a question ("the same series?").
            self:askLink(book, candidate, function(found) Views.showSeriesRecap(book, found, self:seriesRecapActions(book)) end)
        elseif self:getSetting("welcome_ask") then
            UIManager:show(ConfirmBox:new{
                text = T(_("This is volume %1 of \"%2\". Would you like a recap of the earlier volumes?"), book.series_index, book.series),
                ok_text = _("Series recap"),
                cancel_text = _("Continue reading"),
                ok_callback = function() Views.showSeriesRecap(book, volumes, self:seriesRecapActions(book)) end,
            })
        else
            Views.showSeriesRecap(book, volumes, self:seriesRecapActions(book))
        end
    end)
    return true
end

--- An earlier volume by the same author under another series name (e.g. the
-- original of a translation) that the reader has not declined yet.
-- @bool automatic asked without the reader opening the series recap: then only
--       for a book in another language, so authors with several series don't nag
function StoryRecall:linkCandidate(book, automatic)
    local declined = self.store.data.series_link_declined or {}
    local language = Series.normalize(book.language)
    for _, candidate in ipairs(Series.otherNamedCandidates(self.ui.document.file, book)) do
        local other_language = Series.normalize(candidate.language)
        local other_language_differs = language and other_language
            and language:sub(1, 2) ~= other_language:sub(1, 2)
        if not declined[candidate.key] and (not automatic or other_language_differs) then
            return candidate
        end
    end
end

--- Ask whether another series name is the same series; link it if so.
-- @param on_found function(volumes), called only if earlier volumes are found after linking
function StoryRecall:askLink(book, candidate, on_found)
    UIManager:show(ConfirmBox:new{
        text = T(_("Is the series \"%1\" (volume %2: %3) the same series as this book, for example its original or a translation?"),
            candidate.name, candidate.series_index, candidate.title or "?"),
        ok_text = _("Same series"),
        cancel_text = _("No"),
        ok_callback = function()
            Series.link(book, candidate.key)
            local volumes = Series.previousVolumes(self.ui.document.file, book)
            if #volumes > 0 then on_found(volumes) end
        end,
        cancel_callback = function()
            self.store.data.series_link_declined = self.store.data.series_link_declined or {}
            self.store.data.series_link_declined[candidate.key] = true
            self.store:markDirty()
        end,
    })
end

--- ☰ of the series recap: write the previous volume's summary again (one request).
function StoryRecall:seriesRecapActions(book)
    local file = self.ui.document and self.ui.document.file
    return {
        recreate = function(volume, on_done)
            UIManager:show(ConfirmBox:new{
                text = T(_("Write the summary of volume %1 again from its chapter notes? This is one request to the AI."), volume.series_index),
                ok_text = _("Write again"),
                ok_callback = function()
                    require("ui/network/manager"):runWhenConnected(function()
                        local ok, store = pcall(Store.open, volume.file)
                        if not ok or not store then
                            UIManager:show(InfoMessage:new{ text = _("The notes of that volume could not be opened.") })
                            return
                        end
                        local info = store.data.book or {}
                        local volume_book = {
                            title = info.title or volume.title, authors = info.authors or book.authors,
                            series = info.series or book.series, series_index = info.series_index or volume.series_index,
                            language = info.language,
                        }
                        self:createVolumeSummary(store, volume_book, { on_done = function(done)
                            if done and file then on_done(Series.previousVolumes(file, book)) end
                        end })
                    end)
                end,
            })
        end,
    }
end

function StoryRecall:showSeriesRecap()
    local book = self:getBookInfo()
    -- The first volume (gesture, ZenOS action): nothing came before it, so no
    -- search for earlier volumes and no offer to summarise them from the internet.
    local index = tonumber(book.series_index)
    if book.series and index and index <= 1 then
        UIManager:show(InfoMessage:new{ text = T(_("This is volume 1 of \"%1\": there are no earlier volumes to recap. The series recap is available from volume 2 on."), book.series) })
        return
    end
    local volumes = Series.previousVolumes(self.ui.document.file, book)
    if #volumes == 0 then
        local candidate = self:linkCandidate(book)
        if candidate then
            self:askLink(book, candidate, function(found) Views.showSeriesRecap(book, found, self:seriesRecapActions(book)) end)
            return
        end
        self:showNoEarlierVolumes(book)
        return
    end
    Views.showSeriesRecap(book, volumes, self:seriesRecapActions(book))
end

function StoryRecall:showNoEarlierVolumes(book)
    local text = _("No earlier volumes with AI notes found. Open them once and let Story Recall create their notes (series and number come from the book information).")
    local AI = require("storyrecall/ai")
    local WebSummary = require("storyrecall/websummary")
    local cfg = AI.configFrom(self.settings)
    -- Only with a known volume number above 1: the AI has to know which volumes came before.
    if not (cfg and WebSummary.supported(cfg.provider) and book.series
            and (tonumber(book.series_index) or 0) > 1) then
        UIManager:show(InfoMessage:new{ text = text })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("Don't have them as e-books? The AI can summarise them from the internet (one request)."),
        ok_text = _("Summarise from the internet"),
        cancel_text = _("Close"),
        ok_callback = function()
            -- The caveat only for those who want it.
            UIManager:show(ConfirmBox:new{
                text = _("Websites, especially fan wikis, can contain mistakes and spoilers for later volumes. The AI is told to leave those out, but that cannot be guaranteed."),
                ok_text = _("Continue"),
                ok_callback = function() self:createWebSummary(book, cfg) end,
            })
        end,
    })
end

--- Ask the AI to summarise the earlier volumes from the internet, store the
-- result in the series archive and show the series recap.
function StoryRecall:createWebSummary(book, cfg)
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if (self.web_job and not self.web_job.done) or not (self.ui and self.ui.document) then return end
        local WebSummary = require("storyrecall/websummary")
        local language = self:getNotesLanguage()
        local file = self.ui.document.file
        local job
        job = require("storyrecall/subprocess").run{
            text = _("Summarising the earlier volumes from the internet… This may take a moment."),
            work = function()
                local volumes, extra = WebSummary.run(cfg, book, language)
                return { volumes = volumes, extra = extra }
            end,
            on_done = function(result)
                if self.web_job == job then self.web_job = nil end
                local volumes = result.volumes
                if not volumes then
                    local err = result.err or result.extra or {}
                    UIManager:show(InfoMessage:new{ text = T(_("No summary could be created: %1"),
                        AIMenu.describeError(err)) })
                    return
                end
                for _i, volume in ipairs(volumes) do
                    Series.archiveExternal(book, volume.series_index, {
                        title = volume.title, authors = book.authors, language = language,
                        text = volume.text, finished = true, source = "internet", sources = result.extra,
                    })
                end
                local found = Series.previousVolumes(file, book)
                if #found > 0 then Views.showSeriesRecap(book, found, self:seriesRecapActions(book)) end
            end,
        }
        -- A finished job (error before it started) is not kept.
        if not job.done then self.web_job = job end
    end)
end

--- Book closed while the internet summary runs: stop it cleanly.
function StoryRecall:cancelWebSummary()
    -- Also the volume summary (it belongs to the book being closed; it is
    -- written again next time, because none was stored).
    if self.volume_job then
        self.volume_job.cancel()
        self.volume_job = nil
    end
    local job = self.web_job
    if not job then return end
    self.web_job = nil
    job.cancel()
end

--- The models to try for a single important request, best first: the chosen
-- model, the provider's others, the small fallback model last.
local function modelsFor(cfg)
    local list, seen = {}, {}
    local function add(model)
        if model and model ~= "" and not seen[model] then
            seen[model] = true
            table.insert(list, model)
        end
    end
    add(cfg.model)
    local provider = require("storyrecall/ai").getProvider(cfg.provider)
    for _i, model in ipairs(provider and provider.models or {}) do
        if model ~= cfg.fallback_model then add(model) end
    end
    add(cfg.fallback_model)
    return list
end

--- One important request, trying the models best first (in the subprocess).
-- @param validate function(parsed answer) returning the value, or nil
-- @return { value = …, model = … } or { err = … }
function askModels(cfg, system, message, schema, validate)
    local AI = require("storyrecall/ai")
    local last_err
    -- Setting "on overload: wait": only the chosen model, tried twice.
    local models = cfg.switch_models and modelsFor(cfg) or { cfg.model, cfg.model }
    for i, model in ipairs(models) do
        if i > 1 and not cfg.switch_models then require("ffi/util").sleep(15) end
        cfg.model = model
        local answer, err = AI.complete(cfg, system, message, schema)
        local value = answer and validate(AI.parseJSON(answer))
        if value then return { value = value, model = model } end
        last_err = err or { kind = "format", message = "unexpected answer" }
        -- Only overload, limits and timeouts are worth another try.
        if not (last_err.kind == "server" or last_err.kind == "rate_limit"
                or last_err.kind == "timeout" or last_err.kind == "format") then
            break
        end
    end
    return { err = last_err }
end

--- Ask for a fresh "story so far" from all chapter summaries up to the point
-- read, and store it as a correction of the newest note (the AI's text stays
-- restorable). Runs in a subprocess like the internet summary.
-- @param on_done optional callback(ok)
function StoryRecall:rewriteStorySoFar(on_done)
    if (self.recap_job and not self.recap_job.done) or not self.store then return end
    local AI = require("storyrecall/ai")
    local Prompt = require("storyrecall/prompt")
    local cfg = AI.configFrom(self.settings)
    if not cfg then
        UIManager:show(InfoMessage:new{ text = _("No AI is set up yet. See Story Recall → Settings → AI.") })
        if on_done then on_done(false) end
        return
    end
    local ctx = self:buildContext()
    local notes = self.store:getChapterNotes(ctx.recap_index or ctx.ai_index)
    local latest
    for i = #notes, 1, -1 do
        if notes[i].story_so_far then latest = notes[i] break end
    end
    if not latest or #notes < 2 then
        UIManager:show(InfoMessage:new{ text = _("There are not enough AI notes for this yet.") })
        if on_done then on_done(false) end
        return
    end
    local chapters, protagonist = {}, nil
    for _i, note in ipairs(notes) do
        if note.index <= latest.index then
            table.insert(chapters, { index = note.index, title = note.title, summary = note.summary })
            protagonist = note.protagonist or protagonist
        end
    end
    local message = Prompt.buildRecap{
        book = self:getBookInfo(), notes_language = self:getNotesLanguage(),
        protagonist = protagonist, chapters = chapters,
    }
    local function request()
        local result = askModels(cfg, Prompt.RECAP_SYSTEM, message, Prompt.RECAP_SCHEMA, Prompt.validateRecap)
        return result.value and { text = result.value, model = result.model } or { err = result.err }
    end

    local key = latest.key
    local function finish(result)
        self.recap_job = nil
        if not (result and result.text) then
            local err = result and result.err or {}
            UIManager:show(InfoMessage:new{ text = T(_("The story so far could not be written: %1"),
                AIMenu.describeError(err)) })
            if on_done then on_done(false) end
            return
        end
        self.store:editChapterNote(key, "story_so_far", result.text)
        local note = self.store:getChapterNote(key)
        if note then note.story_so_far_model = result.model end
        self.store:save()
        logger.info("StoryRecall: story so far rewritten with", result.model)
        if on_done then on_done(true) else self:showRecap() end
    end

    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if (self.recap_job and not self.recap_job.done) or not self.store then return end
        local job = require("storyrecall/subprocess").run{
            text = _("Writing the story so far… This may take a moment."),
            work = request,
            on_done = finish,
        }
        if not job.done then self.recap_job = job end
    end)
end

--- "Ask the AI" about a name the lexicon does not know: one request with the
-- chapter summaries and the book's passages up to the reading position. The
-- answer is kept apart from the chapter notes (Store:addLookup).
function StoryRecall:askAI(query)
    if (self.lookup_job and not self.lookup_job.done) or not self.store then return end
    local AI = require("storyrecall/ai")
    local Prompt = require("storyrecall/prompt")
    local cfg = AI.configFrom(self.settings)
    if not cfg then return end
    local ctx = self:buildContext()
    local chapters, protagonist = {}, nil
    for _i, note in ipairs(self.store:getChapterNotes(ctx.ai_index)) do
        table.insert(chapters, { index = note.index, title = note.title, summary = note.summary })
        protagonist = note.protagonist or protagonist
    end
    -- Passages come newest first; send the oldest ones (how it was introduced).
    local found = Context.passages(self.ui, { name = query, aliases = {}, type = "term" }, ctx.passage_limit_page)
    local passages = {}
    for i = #found, math.max(1, #found - 19), -1 do table.insert(passages, found[i].text) end
    if #passages == 0 and #chapters == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No story notes about \"%1\" up to where you have read."), query) })
        return
    end
    local message = Prompt.buildLookup{
        book = self:getBookInfo(), notes_language = self:getNotesLanguage(),
        protagonist = protagonist, query = query, chapters = chapters, passages = passages,
    }
    local read = Chapters.byIndex(self.ui, ctx.ai_index)
    local function finish(result)
        self.lookup_job = nil
        local value = result.value
        if not value then
            local err = result.err or {}
            UIManager:show(InfoMessage:new{ text = T(_("The AI could not be asked: %1"), AIMenu.describeError(err)) })
            return
        end
        if not value.found then
            UIManager:show(InfoMessage:new{ text = T(_("The AI found nothing about \"%1\" up to where you have read."), query) })
            return
        end
        self.store:addLookup{
            name = value.name, type = value.type, facts = value.facts, relation = value.relation,
            index = ctx.ai_index, title = read and read.title, model = result.model,
        }
        self.store:save()
        local profiles, by_name, show_ctx = self:getProfiles()
        local matches = Context.find(profiles, by_name, value.name)
        if #matches > 0 then
            show_ctx.profile = matches[1]
            Context.show(show_ctx)
        end
    end
    local NetworkMgr = require("ui/network/manager")
    NetworkMgr:runWhenConnected(function()
        if (self.lookup_job and not self.lookup_job.done) or not self.store then return end
        local job = require("storyrecall/subprocess").run{
            text = T(_("Asking the AI about \"%1\"…"), query),
            work = function()
                return askModels(cfg, Prompt.LOOKUP_SYSTEM, message, Prompt.LOOKUP_SCHEMA, Prompt.validateLookup)
            end,
            on_done = finish,
        }
        if not job.done then self.lookup_job = job end
    end)
end

--- Book closed while the story so far is being rewritten: stop it cleanly.
function StoryRecall:cancelRecapRewrite()
    local job = self.recap_job
    if not job then return end
    self.recap_job = nil
    job.cancel()
end

--- Book closed while the AI is asked about a name.
function StoryRecall:cancelLookup()
    local job = self.lookup_job
    if not job then return end
    self.lookup_job = nil
    job.cancel()
end

function StoryRecall:onStoryRecallShowSeriesRecap()
    if self.store then self:showSeriesRecap() end
    return true
end

-- Recap

function StoryRecall:checkForBreak()
    if not self:getSetting("welcome_enabled") or not self.last_seen then return end
    local pause = os.time() - self.last_seen
    if pause < self:getSetting("pause_days") * 86400 then return end
    -- A clock that was reset (empty battery) makes absurd breaks: ignore them.
    if pause > MAX_BREAK then
        logger.info("StoryRecall: break of", pause, "seconds looks like a wrong clock, no recap")
        return
    end
    -- Nothing to recap yet (book only just started, no notes): no empty window.
    if not self:hasSomethingToRecap() then return end
    logger.dbg("StoryRecall: break of", pause, "seconds, showing recap")
    -- Let the reader finish drawing the page first.
    UIManager:scheduleIn(0.5, function()
        if not (self.ui and self.ui.document) then return end
        -- Seeing the recap or the question ends the break: it does not come
        -- again on the next opening, whatever the answer.
        self.session_read = true
        if not self:getSetting("welcome_ask") then
            self:showRecap(true)
            return
        end
        -- Ask first: a short question instead of the whole window.
        UIManager:show(ConfirmBox:new{
            text = math.floor(pause / 86400) == 1
                and _("You haven't read this book for a day. Would you like a recap?")
                or T(_("You haven't read this book for %1 days. Would you like a recap?"), math.floor(pause / 86400)),
            ok_text = _("Recap"),
            cancel_text = _("Continue reading"),
            ok_callback = function() self:showRecap(true) end,
        })
    end)
end

--- AI notes, own notes or highlights up to where the reader is.
function StoryRecall:hasSomethingToRecap()
    local ctx = self:buildContext()
    if #self.store:getChapterNotes(ctx.recap_index or ctx.ai_index) > 0 then return true end
    if #self.store:getNotes(ctx.recap_upto or ctx.read_chapter.index) > 0 then return true end
    local annotations = self.ui.annotation and self.ui.annotation.annotations
    return annotations ~= nil and #annotations > 0
end

--- @bool after_break true when shown automatically after a break (adds a greeting)
function StoryRecall:showRecap(after_break)
    local ctx = self:buildContext()
    ctx.after_break = after_break
    local AI = require("storyrecall/ai")
    local ai_ready = AI.configFrom(self.settings) ~= nil
    -- Shown when there is nothing to recap yet: what to do next.
    if not ai_ready then
        ctx.empty_hint = _("No AI is set up yet: tap ☰ at the top left → AI notes to set it up.")
    elseif self.processor:isActive() then
        ctx.empty_hint = AIMenu.statusText(self)
    end
    -- ☰ menu of the recap window
    local menu = {}
    -- The AI notes' status: tap to start, pause or set up the API key.
    table.insert(menu, {
        text = AIMenu.statusText(self),
        callback = function()
            AIMenu.toggleProcessing(self)
            if ai_ready then
                UIManager:show(InfoMessage:new{ text = AIMenu.statusText(self), timeout = 2 })
            end
        end,
    })
    table.insert(menu, {
        text = _("Rewrite the story so far"),
        enabled = self.store:countChapterNotes() > 1,
        close_recap = true, -- it opens again with the new text
        callback = function() self:rewriteStorySoFar() end,
    })
    local index = tonumber(ctx.book.series_index)
    if index and index > 1 then
        table.insert(menu, {
            text = _("Series recap"),
            callback = function() self:showSeriesRecap() end,
        })
    end
    table.insert(menu, {
        text = _("Edit notes"),
        close_recap = true,
        callback = function()
            Views.showNotesList(self.store, function() self.store:save() end)
        end,
    })
    table.insert(menu, {
        text = _("Correct AI notes"),
        enabled = self.store:countChapterNotes() > 0,
        close_recap = true,
        callback = function()
            Views.showAINotesList(self.store, self:buildContext().ai_index,
                function() self.store:save(); self:archiveVolume() end)
        end,
    })
    table.insert(menu, {
        text = _("Story Recall settings"),
        close_recap = true,
        callback = function() self:openSettingsMenu() end,
    })
    Views.showRecap(ctx, {
        chronicle = function() self:showChronicle() end,
        lexicon = function(recap_viewer) self:showCharacters(recap_viewer) end,
        note = function() self:addNoteToCurrentChapter() end,
        menu = menu,
    })
end

--- Open KOReader's menu right at Story Recall → Settings (from the recap ☰).
function StoryRecall:openSettingsMenu()
    if not self.ui.menu then return end
    self.ui.menu:onShowMenu()
    UIManager:nextTick(function()
        local menu = self.ui.menu.menu_container and self.ui.menu.menu_container[1]
        if not (menu and menu.tab_item_table) then return end
        for i, tab in ipairs(menu.tab_item_table) do
            for _j, item in ipairs(tab) do
                if item.text == "Story Recall" then
                    menu:switchMenuTab(i)
                    menu:onMenuSelect(item)
                    for _k, sub in ipairs(menu.item_table or {}) do
                        if sub.text == _("Settings") then
                            menu:onMenuSelect(sub)
                            break
                        end
                    end
                    return
                end
            end
        end
    end)
end

function StoryRecall:showChronicle()
    Views.showChronicle(self:buildContext(), function()
        self:showRecap()
    end)
end

-- Story context ("Who was that again?")

--- Lexicon material of the earlier volumes of this book's series (looked up once
-- while the book is open). The lexicon continues their entries.
function StoryRecall:earlierLexicons()
    if self.earlier_lexicons == nil then
        local ok, volumes = pcall(Series.previousLexicons, self.ui.document.file, self:getBookInfo())
        if not ok then logger.warn("StoryRecall: earlier lexicons:", volumes) end
        self.earlier_lexicons = ok and volumes or {}
    end
    return self.earlier_lexicons
end

--- Profiles of everything known up to the furthest chapter read.
function StoryRecall:getProfiles()
    local ctx = self:buildContext()
    local profiles, by_name = self.store:getEntityProfiles(ctx.ai_index, self:earlierLexicons())
    local protagonist
    for _, note in ipairs(self.store:getChapterNotes(ctx.ai_index)) do
        protagonist = note.protagonist or protagonist
    end
    local ask_ai
    if require("storyrecall/ai").configFrom(self.settings) then
        ask_ai = function(query) self:askAI(query) end
    end
    return profiles, by_name, {
        ui = self.ui,
        protagonist = protagonist,
        read_limit_page = ctx.passage_limit_page,
        ask_ai = ask_ai,
    }
end

--- Show the story context for a selected text (highlight or dictionary).
-- @return true if something was found
function StoryRecall:showStoryContext(selection)
    local profiles, by_name, ctx = self:getProfiles()
    local matches = Context.find(profiles, by_name, selection)
    if #matches == 0 then
        local text = util.cleanupSelectedText(selection or "")
        if #profiles == 0 then
            UIManager:show(InfoMessage:new{ text = _("No AI notes yet. Create them under Story Recall → AI notes.") })
        else
            Context.notFound(ctx, text)
        end
        return false
    elseif #matches == 1 then
        ctx.profile = matches[1]
        Context.show(ctx)
    else
        Context.choose(ctx, matches)
    end
    return true
end

--- The story lexicon. @param parent window it was opened from (closed too on a jump into the book)
function StoryRecall:showCharacters(parent)
    local profiles, _by_name, ctx = self:getProfiles()
    if #profiles == 0 then
        UIManager:show(InfoMessage:new{ text = _("No AI notes yet. Create them under Story Recall → AI notes.") })
        return
    end
    if parent then Context.remember(ctx, parent) end
    ctx.lexicon_sort = self:getSetting("lexicon_sort")
    ctx.set_lexicon_sort = function(sort) self:setSetting("lexicon_sort", sort) end
    Context.browse(ctx, profiles)
end

--- "Story context" buttons in the highlight menu and the dictionary popup.
function StoryRecall:registerLookupButtons()
    if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
        -- Sorted by key: right before "12_search", which stays last.
        self.ui.highlight:addToHighlightDialog("11_storyrecall", function(this)
            return {
                text = _("Story context"),
                show_in_highlight_dialog_func = function()
                    return self.store ~= nil and self.store:countChapterNotes() > 0
                end,
                callback = function()
                    local text = this.selected_text and this.selected_text.text
                    this:onClose()
                    self:showStoryContext(text)
                end,
            }
        end)
    end
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        -- Conditional: only shown when the word is known, so it never clutters
        -- the popup for ordinary words.
        self.ui.dictionary:addToDictButtons({
            id = "storyrecall_context",
            text = _("Story context"),
            conditional = true,
            show_func = function(dict_popup)
                if not self.store or self.store:countChapterNotes() == 0 or not dict_popup.word then return false end
                local profiles, by_name = self:getProfiles()
                return #Context.find(profiles, by_name, dict_popup.word) > 0
            end,
            callback = function(dict_popup)
                local word = dict_popup.word
                dict_popup:onClose()
                self:showStoryContext(word)
            end,
        })
    end
end

--- Older KOReader versions without addToDictButtons.
function StoryRecall:onDictButtonsReady(dict_popup, buttons)
    if self.ui.dictionary and self.ui.dictionary.addToDictButtons then return end
    if not self.store or self.store:countChapterNotes() == 0 or not dict_popup.word then return end
    local profiles, by_name = self:getProfiles()
    if #Context.find(profiles, by_name, dict_popup.word) == 0 then return end
    table.insert(buttons, 1, {{
        id = "storyrecall_context",
        text = _("Story context"),
        callback = function()
            local word = dict_popup.word
            dict_popup:onClose()
            self:showStoryContext(word)
        end,
    }})
end

-- Notes

function StoryRecall:addNoteToCurrentChapter()
    local chapter = self:getCurrentChapter()
    Views.editNote(T(_("Note: %1"), Views.chapterLabel(chapter)), nil, function(text)
        self.store:addNote(chapter, text, "user")
        self.store:save()
        UIManager:show(InfoMessage:new{ text = _("Note saved."), timeout = 2 })
    end)
end

--- The reader has read this book elsewhere (e.g. on paper): unlock it to the
-- end and create the AI notes for the whole book, also for the series recap.
function StoryRecall:markReadElsewhere()
    UIManager:show(ConfirmBox:new{
        text = _("Have you already read this whole book, for example on paper?\n\nStory Recall then shows everything up to the end and creates the AI notes for the whole book, so the next volume's series recap can use it."),
        ok_text = _("Yes, read it"),
        ok_callback = function()
            local chapters = Chapters.upTo(self.ui, math.huge)
            local last = chapters[#chapters]
            if last then
                self.store:setFurthestChapter(last.index, last.key)
                for _i, chapter in ipairs(chapters) do
                    if chapter.index > 0 then self.store:markChapterCompleted(chapter) end
                end
            end
            self.store.data.read_elsewhere = os.time()
            self.store:save()
            self:archiveVolume()
            local AI = require("storyrecall/ai")
            if AI.configFrom(self.settings) then
                self:onStoryRecallProcess()
            else
                UIManager:show(InfoMessage:new{ text = _("Done. Set up the AI first (Story Recall → Settings → AI); then the notes for the whole book are created.") })
            end
        end,
    })
end

function StoryRecall:exportNotes()
    local path, err = require("storyrecall/export").write(self:buildContext(), self.ui.document.file)
    if path then
        UIManager:show(InfoMessage:new{ text = T(_("Saved as:\n%1"), path) })
    else
        UIManager:show(InfoMessage:new{ text = T(_("Could not save the file: %1"), tostring(err)) })
    end
end

function StoryRecall:showBookInfo()
    local book = self:getBookInfo()
    local chapter = self:getCurrentChapter()
    local lines = {
        book.title or "",
        Views.seriesLine(book) or _("Not part of a series (no series information in the book)."),
        "",
        T(_("Current chapter: %1"), Views.chapterLabel(chapter)),
        T(_("Finished chapters: %1 of %2"), self.store:countCompletedChapters(), Chapters.count(self.ui)),
        T(_("Own notes: %1"), #self.store:getNotes()),
        AIMenu.statusText(self),
    }
    if self.last_seen then
        table.insert(lines, T(_("Previous session: %1"), Views.formatDate(self.last_seen)))
    end
    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
end

-- Menu

function StoryRecall:addToMainMenu(menu_items)
    menu_items.story_recall = {
        text = "Story Recall",
        -- Built each time it is opened: some entries depend on the book and the settings.
        sub_item_table_func = function() return self:getMainMenu() end,
    }
end

function StoryRecall:getMainMenu()
    local items = {
        {
            text = _("Recap"),
            enabled_func = function() return self.store ~= nil end,
            callback = function() self:showRecap() end,
        },
        {
            text = _("Story chronicle"),
            enabled_func = function() return self.store ~= nil end,
            callback = function() self:showChronicle() end,
        },
        {
            text = _("Series recap"),
            series_only = true,
            callback = function() self:showSeriesRecap() end,
        },
        {
            text = _("Story lexicon"),
            enabled_func = function() return self.store ~= nil end,
            callback = function() self:showCharacters() end,
        },
        {
            text = _("Add note to current chapter"),
            enabled_func = function() return self.store ~= nil end,
            callback = function() self:addNoteToCurrentChapter() end,
        },
        {
            text = _("Edit notes"),
            enabled_func = function() return self.store ~= nil end,
            callback = function()
                Views.showNotesList(self.store, function() self.store:save() end)
            end,
            separator = true,
        },
        AIMenu.statusItem(self),
        AIMenu.rewriteItem(self),
        {
            text = _("Book and notes"),
            enabled_func = function() return self.store ~= nil end,
            sub_item_table = self:getBookMenu(),
        },
        {
            text = _("Settings"),
            sub_item_table = self:getSettingsMenu(),
        },
    }
    -- Series recap only from volume 2 on (volume 1 has nothing before it).
    local index = tonumber(self:getBookInfo().series_index)
    local has_series_recap = self.store ~= nil and index ~= nil and index > 1
    for i = #items, 1, -1 do
        if items[i].series_only then
            if has_series_recap then items[i].series_only = nil else table.remove(items, i) end
        end
    end
    return items
end

--- Things done now and then for this book.
function StoryRecall:getBookMenu()
    return {
        {
            text = _("About this book"),
            callback = function() self:showBookInfo() end,
        },
        {
            text = _("Correct AI notes"),
            enabled_func = function() return self.store:countChapterNotes() > 0 end,
            callback = function()
                Views.showAINotesList(self.store, self:buildContext().ai_index,
                    function() self.store:save(); self:archiveVolume() end)
            end,
        },
        AIMenu.recreateItem(self),
        AIMenu.savedNotesItem(self),
        {
            text = _("Export story notes"),
            help_text = _("Saves the story so far, the chronicle and the characters, up to where you have read, as a text file (Markdown) next to the book."),
            callback = function() self:exportNotes() end,
        },
        {
            text = _("Already read elsewhere"),
            help_text = _("For a book you have read elsewhere, e.g. on paper: shows everything up to the end and creates the AI notes for the whole book, so the series recap of the next volume works."),
            callback = function() self:markReadElsewhere() end,
        },
    }
end

--- "Gestures and shortcuts": short sections instead of one long message.
function StoryRecall:showShortcutsHelp()
    local TextBoxWidget = require("ui/widget/textboxwidget")
    local TextViewer = require("ui/widget/textviewer")
    local function bold(text) return TextBoxWidget.PTF_BOLD_START .. text .. TextBoxWidget.PTF_BOLD_END end
    local sections = {
        { _("Actions"), _("Recap, Story chronicle, Series recap, Story lexicon, Add note to current chapter, Rewrite the story so far, Create AI notes now.") },
        { _("Gesture"), _("Settings (gear icon) → Taps and gestures → Gesture manager → pick a gesture → Reader → choose a Story Recall action.") },
        { _("Who was that again?"), _("Select a name in the book and tap \"Story context\". For known names it also appears in the dictionary popup.") },
        { "ZenOS", _("Buttons: Zen Settings → Interface → Controls, Navbar or Launcher → Buttons → Add → Action → choose a Story Recall action.") .. "\n"
            .. _("\"Story context\" in the highlight and dictionary menus: Zen Settings → Reader → Highlight / Lookup → Show other items.") .. "\n"
            .. _("Home widget: Zen Settings → Home → Widgets → Story Recall.") },
    }
    local lines = {}
    for i, section in ipairs(sections) do
        if i > 1 then table.insert(lines, "") end
        table.insert(lines, bold(section[1]))
        table.insert(lines, section[2])
    end
    UIManager:show(TextViewer:new{
        title = _("Gestures and shortcuts"),
        text = TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n"),
        justified = false,
    })
end

function StoryRecall:getSettingsMenu()
    local items = {
        {
            text = _("AI"),
            sub_item_table_func = function() return AIMenu.settingsItems(self) end,
        },
        {
            text = _("Gestures and shortcuts"),
            keep_menu_open = true,
            separator = true,
            callback = function() self:showShortcutsHelp() end,
        },
        {
            text = _("Show recap after a break"),
            checked_func = function() return self:getSetting("welcome_enabled") end,
            callback = function()
                self:setSetting("welcome_enabled", not self:getSetting("welcome_enabled"))
            end,
        },
        {
            text = _("Ask first"),
            help_text = _("After a break and when starting a new volume, first ask whether you want to see the recap instead of opening it right away."),
            enabled_func = function() return self:getSetting("welcome_enabled") end,
            checked_func = function() return self:getSetting("welcome_ask") end,
            callback = function()
                self:setSetting("welcome_ask", not self:getSetting("welcome_ask"))
            end,
        },
        {
            text_func = function()
                return T(_("Break length: %1 days"), self:getSetting("pause_days"))
            end,
            enabled_func = function() return self:getSetting("welcome_enabled") end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Break length"),
                    info_text = _("Show the recap when a book is opened after this many days."),
                    value = self:getSetting("pause_days"),
                    value_min = 1,
                    value_max = 365,
                    default_value = DEFAULTS.pause_days,
                    unit = _("days"),
                    callback = function(spin)
                        self:setSetting("pause_days", spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
        {
            text_func = function()
                return T(_("Chapters in the recap: %1"), self:getSetting("recap_chapters"))
            end,
            keep_menu_open = true,
            callback = function(touchmenu_instance)
                UIManager:show(SpinWidget:new{
                    title_text = _("Chapters in the recap"),
                    info_text = _("How many of the last chapters the recap covers."),
                    value = self:getSetting("recap_chapters"),
                    value_min = 1,
                    value_max = 20,
                    default_value = DEFAULTS.recap_chapters,
                    callback = function(spin)
                        self:setSetting("recap_chapters", spin.value)
                        touchmenu_instance:updateItems()
                    end,
                })
            end,
        },
    }
    -- Hilfe als letzter Eintrag (Standard in allen Plugins)
    items[#items].separator = true
    table.insert(items, {
        text = _("How does it work?"),
        callback = function() self:showGuide() end,
    })
    return items
end

return StoryRecall
