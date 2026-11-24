--[[--
Performance test: builds a chronicle with as much text as AI notes will
produce and measures how long it takes to open on this device.
The data only exists in memory; nothing is written to any book.
--]]

local InfoMessage = require("ui/widget/infomessage")
local Store = require("storyrecall/store")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local Views = require("storyrecall/views")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local PerfTest = {}

-- About 150 words per chapter: a summary plus facts, as AI notes will be.
local SUMMARY = "Elias erreicht mit Mara und Joren die Stadt am Fluss. Der Rat verweigert ihnen den Zugang zum Archiv, bis Mara ihr Siegel zeigt. Im Archiv finden sie den Brief, der beweist, dass Joren damals gelogen hat. Es kommt zum Streit, Joren verschwindet in der Nacht. Am Morgen erfahren sie, dass der Nordturm gefallen ist und die Wölfe über den Pass ziehen."
local FACTS = {
    "Mara: Schwester des Königs, Heilerin; misstraut Joren seit dem Brief.",
    "Joren: hat den Brief gefälscht, um den Rat zu täuschen; verschwindet nachts.",
    "Elias: Hauptfigur; trägt das Siegel des alten Hauses, ohne es zu wissen.",
    "Stadt am Fluss: Sitz des Rates, Archiv mit den alten Verträgen.",
    "Nordturm: gefallen; der Pass ist offen.",
}

local function memoryStore()
    local store = setmetatable({
        data = { chapters = {}, notes = {}, next_note_id = 1 },
        dirty = false,
    }, { __index = Store })
    store.save = function() end
    return store
end

function PerfTest.run(ui, chapter_count)
    local store = memoryStore()
    local chapters = {}
    for i = 1, chapter_count do
        local chapter = { index = i, key = "perf:" .. i, title = "Testkapitel " .. i }
        table.insert(chapters, chapter)
        store:addNote(chapter, SUMMARY, "ai")
        for _j, fact in ipairs(FACTS) do
            store:addNote(chapter, fact, "ai")
        end
        if i < chapter_count then store:markChapterCompleted(chapter) end
    end

    local t0 = time.now()
    local ctx = {
        ui = ui,
        store = store,
        chapter = chapters[chapter_count],
        read_chapter = chapters[chapter_count],
        read_limit_page = 0,
        chapters = chapters,
        title = _("Performance test"),
    }
    local text = Views.buildChronicleText(ctx)
    local build_ms = time.to_ms(time.since(t0))

    -- Opening = building the window, laying out all lines, jumping to the end.
    local t1 = time.now()
    local ok, err = pcall(Views.showChronicle, ctx, function() end)
    local open_ms = time.to_ms(time.since(t1))
    if not ok then
        logger.err("StoryRecall perf test failed:", err)
        UIManager:show(InfoMessage:new{ text = tostring(err) })
        return
    end

    local words = select(2, text:gsub("%S+", ""))
    local result = T(_("%1 chapters, %2 words: text %3 ms, window %4 ms"), chapter_count, words, build_ms, open_ms)
    logger.info("StoryRecall perf test:", result)
    UIManager:show(InfoMessage:new{ text = result, timeout = 6 })
    return { chapters = chapter_count, words = words, build_ms = build_ms, open_ms = open_ms }
end

return PerfTest
