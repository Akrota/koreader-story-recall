-- Test: spoiler protection (review K1, H1, H2, H4) and cancelling the internet summary (H3).
-- Runs on the generated 40-chapter book (reise.epub) with made-up AI notes.
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/spoiler-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local Chapters = require("storyrecall/chapters")
    local Views = require("storyrecall/views")
    closeTop(); closeTop()
    local toc = ui.toc.toc
    -- Made-up AI notes for every chapter: chapter N mentions "GEHEIMNIS-N".
    for i = 1, #toc do
        p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
            summary = "Zusammenfassung GEHEIMNIS-" .. i, story_so_far = "Bisher bis GEHEIMNIS-" .. i .. ".\n\nAm Ende des Kapitels " .. i .. ".",
            entities = { { name = "Figur" .. i, type = "character", aliases = {}, facts = { "Fakt GEHEIMNIS-" .. i } } },
        })
    end
    local function goto_page(page)
        ui:handleEvent(Event:new("GotoPage", page))
    end
    local function recap() return Views.buildRecapText(p:buildContext()) end

    -- K1: nothing read (cover), then a jump to chapter 30
    p.store.data.furthest_chapter = 0
    p.store.data.chapters = {}
    goto_page(toc[30].page + 1)
    local ctx = p:buildContext()
    check("K1: nothing read -> read chapter is the front matter", ctx.read_chapter.index == 0 and #ctx.chapters == 0)
    check("K1: no AI text after a jump", not recap():find("GEHEIMNIS", 1, true))
    check("K1: no characters after a jump", #select(1, p:getProfiles()) == 0)
    check("K1: export has no AI text", not require("storyrecall/export").markdown(ctx):find("GEHEIMNIS", 1, true))

    -- H1: one page turn after the jump must not count as reading on
    goto_page(toc[30].page + 2)
    check("H1: page turn after a jump does not advance", (p.store:getFurthestChapter() or 0) == 0)

    -- Normal reading from the start: page by page into chapter 4
    goto_page(1)
    p.store.data.furthest_chapter = 1
    for page = 1, toc[4].page + 1 do goto_page(page) end
    log("furthest after reading:", p.store:getFurthestChapter(), "completed:", p.store:countCompletedChapters())
    check("reading on advances to chapter 4", p.store:getFurthestChapter() == 4 and p.store:countCompletedChapters() == 3)

    -- H2: chapter 4 just started -> only notes up to chapter 3
    ctx = p:buildContext()
    local text = recap()
    check("H2: ai limit is the last finished chapter", ctx.ai_index == 3)
    check("H2: recap shows chapter 3", text:find("GEHEIMNIS-3", 1, true) ~= nil)
    check("H2: recap hides the started chapter 4", not text:find("GEHEIMNIS-4", 1, true))
    local chron = Views.buildChronicleText(ctx)
    check("H2: chronicle hides chapter 4's summary", chron:find("GEHEIMNIS-3", 1, true) and not chron:find("GEHEIMNIS-4", 1, true))
    local profiles = p:getProfiles()
    local max_fact = 0
    for _, prof in ipairs(profiles) do for _, fa in ipairs(prof.facts) do max_fact = math.max(max_fact, fa.index) end end
    check("H2: story context only up to chapter 3", max_fact == 3)
    local md = require("storyrecall/export").markdown(ctx)
    check("H2: export hides chapter 4", md:find("GEHEIMNIS-3", 1, true) and not md:find("GEHEIMNIS-4", 1, true))
    check("H2: passages end at the current page", ctx.passage_limit_page == ui:getCurrentPage())
    local Series = require("storyrecall/series")
    local data = p.store.data
    check("H2: series/widget rule hides started chapter", Series.noteVisible(data, { index = 3, key = toc[3].xpointer })
        and not Series.noteVisible(data, { index = 4, key = toc[4].xpointer }))
    -- Finishing chapter 4 shows it
    for page = toc[4].page + 1, toc[5].page + 1 do goto_page(page) end
    check("H2: finished chapter appears", recap():find("GEHEIMNIS-4", 1, true) and not recap():find("GEHEIMNIS-5", 1, true))

    -- Finished book: the recap still shows the story so far; the volume summary is for the next volume
    local last = #toc
    p.store:getChapterNote(toc[last].xpointer).volume_summary = "GANZER-BAND von Anfang an."
    p.store.data.furthest_chapter = last; p.store.data.furthest_key = toc[last].xpointer
    for i = 1, last do p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title }) end
    goto_page(ui.document:getPageCount()) -- on the last page: the last chapter counts
    check("finished book: recap shows the story so far, not the volume summary",
        recap():find("GEHEIMNIS-" .. last, 1, true) ~= nil and not recap():find("GANZER-BAND", 1, true))
    -- A volume summary on a chapter in the middle (seen with gemini flash-lite) is dropped
    local Prompt = require("storyrecall/prompt")
    local stray = Prompt.validate({ chapters = {
        { index = 3, summary = "Zusammenfassung von Kapitel 3", story_so_far = "B3", volume_summary = "FALSCH" },
        { index = last, summary = "Zusammenfassung des letzten Kapitels", story_so_far = "BL", volume_summary = "RICHTIG" } } },
        { { index = 3 }, { index = last } }, last)
    check("validate: volume summary only kept for the last chapter",
        stray and stray[3] and stray[3].volume_summary == nil and stray[last].volume_summary == "RICHTIG")
    -- Series recap ignores a stray volume summary when the notes stop before the last chapter
    local Series2 = require("storyrecall/series")
    local vs = Series2.volumeSummary({ last_chapter_index = last, furthest_chapter = 3,
        chapters = { [toc[3].xpointer] = { completed_at = 1 } },
        ai_chapters = { a = { index = 3, key = toc[3].xpointer, story_so_far = "BIS-3", volume_summary = "STRAY" } } })
    check("series recap: stray volume summary in the middle is ignored", vs and vs.text == "BIS-3")
    p.store.data.furthest_chapter = 5

    -- H4: hidden TOC levels (fake TOC)
    local fake = { toc = {
        toc = { { depth = 1, title = "A", page = 1, xpointer = "/a" }, { depth = 2, title = "A.1", page = 3, xpointer = "/a1" },
                { depth = 2, title = "A.2", page = 5, xpointer = "/a2" }, { depth = 1, title = "B", page = 7, xpointer = "/b" },
                { depth = 1, title = "C", page = 9, xpointer = "/c" } },
        toc_ticks_ignored_levels = { [2] = true }, fillToc = function() end } }
    check("H4: next skips hidden sub-sections", Chapters.next(fake, 1).index == 4 and Chapters.next(fake, 4).index == 5 and Chapters.next(fake, 5) == nil)
    check("H4: prev skips hidden sub-sections", Chapters.prev(fake, 4).index == 1 and Chapters.prev(fake, 1) == nil)
    local visible = Chapters.upTo(fake, math.huge)
    check("H4: visible chapters numbered in order", #visible == 3 and visible[2].index == 4 and visible[2].seq == 2)
    local Prompt = require("storyrecall/prompt")
    for _, c in ipairs(visible) do c.text = "Wort" end
    check("H4: chapters around hidden levels batched together", #Prompt.batch(visible) == 3)

    -- H3: closing the book while the internet summary runs
    local WebSummary = require("storyrecall/websummary")
    local called = false
    local orig_run = WebSummary.run
    WebSummary.run = function() called = true; return nil, { message = "should not run" } end
    local cfg = { provider = "anthropic", model = "x", key = "test" }
    p:createWebSummary({ series = "S", series_index = 2, title = "T" }, cfg)
    local started = p.web_job ~= nil
    p:cancelWebSummary()
    UIManager:scheduleIn(1.5, function()
        check("H3: summary was running", started)
        check("H3: cancelled cleanly, nothing ran after closing", not called and p.web_job == nil)
        WebSummary.run = orig_run
        f:close(); UIManager:quit()
    end)
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
