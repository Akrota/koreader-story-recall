-- Test (0.9.7): the recap follows where the reader is (up to the chapter before the current one,
-- the current one only on its last page once finished), and the ☰ menu of the recap window.
-- Runs on reise.epub with made-up notes; the AI is faked (state in files: subprocess).
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local json = require("json")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/position-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeAll() while top() and top().name ~= "ReaderUI" do UIManager:close(top()) end end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local Views = require("storyrecall/views")
    closeAll()
    local toc = ui.toc.toc
    local function page(i) return ui.document:getPageFromXPointer(toc[i].xpointer) end
    for i = 1, 10 do
        p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
            summary = "KAPITEL-" .. i .. " passiert.", story_so_far = "BISHER-BIS-" .. i .. ".",
            protagonist = "Elias", entities = {},
        })
        p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title })
    end
    p.store.data.furthest_chapter = 10; p.store.data.furthest_key = toc[10].xpointer
    local function recapAt(pg)
        ui:handleEvent(Event:new("GotoPage", pg))
        local ctx = p:buildContext()
        return Views.buildRecapText(ctx), ctx
    end

    local text, ctx = recapAt(page(10) + 1)
    log("in chapter 10: recap_index", ctx.recap_index, "ai_index", ctx.ai_index)
    check("in the last finished chapter: recap up to the one before", text:find("BISHER-BIS-9.", 1, true) and not text:find("BISHER-BIS-10", 1, true))
    check("…and 'last chapter' is the one before", text:find("KAPITEL-9 passiert.", 1, true) and not text:find("KAPITEL-10 passiert.", 1, true))
    text, ctx = recapAt(page(11) - 1)
    check("on the last page of a finished chapter: it counts", text:find("BISHER-BIS-10.", 1, true) ~= nil)
    text = recapAt(page(5) + 1)
    check("gone back to chapter 5: recap up to chapter 4", text:find("BISHER-BIS-4.", 1, true) and not text:find("BISHER-BIS-5", 1, true))
    p.store:addNote({ key = toc[4].xpointer, index = 4, title = toc[4].title }, "EIGENE-NOTIZ-4")
    p.store:addNote({ key = toc[9].xpointer, index = 9, title = toc[9].title }, "EIGENE-NOTIZ-9")
    text = recapAt(page(5) + 1)
    check("gone back: own notes up to the current chapter only", text:find("EIGENE-NOTIZ-4", 1, true) and not text:find("EIGENE-NOTIZ-9", 1, true))
    text = recapAt(page(10) + 1)
    check("at the frontier: recent own notes shown", text:find("EIGENE-NOTIZ-9", 1, true) ~= nil)
    text = recapAt(page(1) + 1)
    check("in chapter 1: no story so far yet", not text:find("BISHER-BIS", 1, true))
    text, ctx = recapAt(page(20) + 1)
    check("jumped ahead past what was read: never beyond the furthest finished chapter", ctx.recap_index == 10 and text:find("BISHER-BIS-10.", 1, true) ~= nil)

    -- ☰ menu of the recap window
    recapAt(page(6) + 1)
    p:showRecap()
    local recap = top()
    recap:onShowMenu()
    local dialog = top()
    local labels = {}
    for _r, row in ipairs(dialog.buttontable.buttons_layout) do
        for _c, b in ipairs(row) do table.insert(labels, b.text) end
    end
    log("menu:", table.concat(labels, " | "))
    local function has(t) for _i, l in ipairs(labels) do if l == t then return true end end end
    local status_first = labels[1] and labels[1]:find("^KI%-Notizen: ") ~= nil
    check("menu: status, rewrite, edit notes, correct, settings, display",
        status_first and has("Geschichte bisher neu schreiben") and has("Notizen bearbeiten") and has("KI-Notizen korrigieren")
        and has("Story-Recall-Einstellungen") and has("Darstellung …"))
    check("menu: no create/export any more (status line, Book & notes)",
        not has("KI-Notizen jetzt erstellen") and not has("Story-Notizen exportieren"))
    check("menu: no series recap outside a series volume > 1",
        not has("Reihen-Rückblick") or (tonumber(p:getBookInfo().series_index) or 0) > 1)
    local display
    for _r, row in ipairs(dialog.buttontable.buttons_layout) do
        for _c, b in ipairs(row) do if b.text == "Darstellung …" then display = b end end
    end
    display.callback()
    local own = top()
    local own_labels = {}
    for _r, row in ipairs(own.buttontable.buttons_layout) do
        for _c, b in ipairs(row) do table.insert(own_labels, b.text or (b.text_func and b.text_func()) or "?") end
    end
    log("display menu:", table.concat(own_labels, " | "))
    check("'Display…' opens KOReader's own text options", table.concat(own_labels, " "):find("Schrift", 1, true) ~= nil
        or table.concat(own_labels, " "):find("Font", 1, true) ~= nil)
    closeAll()

    -- Rewrite works for where the reader is: in chapter 6 -> up to chapter 5
    local AI = require("storyrecall/ai")
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    os.remove(OUT .. "/position-message.txt")
    AI.complete = function(_cfg, _system, user)
        local m = io.open(OUT .. "/position-message.txt", "w"); m:write(user); m:close()
        return json.encode({ story_so_far = "NEU-BIS-5 Elias beginnt.\n\nZuletzt ruht er." })
    end
    require("ui/network/manager").runWhenConnected = function(_self, cb) cb() end
    p:rewriteStorySoFar(function(done)
        local ok2, e2 = pcall(function()
            local msg = io.open(OUT .. "/position-message.txt"):read("*a")
            check("rewrite: sent chapters 1-5 only", done and msg:find("KAPITEL-5 ", 1, true) and not msg:find("KAPITEL-6", 1, true))
            check("rewrite: stored on chapter 5", p.store:getChapterNote(toc[5].xpointer).story_so_far:find("NEU-BIS-5", 1, true) ~= nil)
            check("rewrite: chapter 10 untouched", p.store:getChapterNote(toc[10].xpointer).story_so_far == "BISHER-BIS-10.")
            check("recap in chapter 6 shows the new text", Views.buildRecapText(p:buildContext()):find("NEU-BIS-5", 1, true) ~= nil)
            AI.setKey("gemini", nil)
        end)
        if not ok2 then log("ERROR", e2) end
        f:close(); UIManager:quit()
    end)
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
