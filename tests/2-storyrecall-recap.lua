-- Test: "Rewrite the story so far" (0.9.7). One request from the chapter summaries up to the
-- point read, the better model is tried before the small fallback, the old text stays restorable.
-- Runs on reise.epub with made-up notes and a fake provider (state in files: the request
-- runs in a subprocess on e-readers and Linux).
local UIManager = require("ui/uimanager")
local json = require("json")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/recap-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    while UIManager:getTopmostVisibleWidget() and UIManager:getTopmostVisibleWidget().name ~= "ReaderUI" do
        UIManager:close(UIManager:getTopmostVisibleWidget())
    end
    local toc = ui.toc.toc
    -- Notes for chapters 1-12, but only 1-10 are read: 11 and 12 must not be sent
    for i = 1, 12 do
        p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
            summary = "KAPITEL-" .. i .. " passiert.", story_so_far = "ALT-" .. i .. " nur das Ende.",
            protagonist = "Elias", entities = {},
        })
    end
    for i = 1, 10 do p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title }) end
    p.store.data.furthest_chapter = 10; p.store.data.furthest_key = toc[10].xpointer
    -- Reading in chapter 11: the recap (and the rewrite) goes up to chapter 10
    ui:handleEvent(require("ui/event"):new("GotoPage", ui.document:getPageFromXPointer(toc[11].xpointer) + 1))

    local AI = require("storyrecall/ai")
    AI.setKey("gemini", "test-key-not-real")
    p:setSetting("ai_provider", "gemini")
    p:setSetting("ai_on_overload", "switch") -- this test checks trying the next model
    os.remove(OUT .. "/recap-calls.log"); os.remove(OUT .. "/recap-message.txt")
    AI.complete = function(cfg, system, user)
        local cl = io.open(OUT .. "/recap-calls.log", "a"); cl:write(cfg.model .. "\n"); cl:close()
        local m = io.open(OUT .. "/recap-message.txt", "w"); m:write(system .. "\n=====\n" .. user); m:close()
        if cfg.model == "gemini-3.8-flash" then return nil, { kind = "server", code = 503, message = "high demand" } end
        return json.encode({ story_so_far = "NEU-VON-ANFANG Elias beginnt.\n\nZuletzt steht er am Fluss." })
    end
    require("ui/network/manager").runWhenConnected = function(_self, cb) cb() end

    p:rewriteStorySoFar(function(done)
        local ok2, e2 = pcall(function()
            check("rewrite finished", done == true)
            local models = {}
            for line in io.lines(OUT .. "/recap-calls.log") do table.insert(models, line) end
            log("models tried:", table.concat(models, " "))
            check("one request per model, better model before the fallback",
                models[1] == "gemini-3.8-flash" and models[2] == "gemini-3.6-flash" and #models == 2)
            local msg = io.open(OUT .. "/recap-message.txt"):read("*a")
            check("all read chapter summaries sent", msg:find("KAPITEL-1 ", 1, true) and msg:find("KAPITEL-10 ", 1, true))
            check("no summary after the point read (spoiler)", not msg:find("KAPITEL-11", 1, true) and not msg:find("KAPITEL-12", 1, true))
            check("old story-so-far texts not sent", not msg:find("ALT-", 1, true))
            local note = p.store:getChapterNote(toc[10].xpointer)
            check("stored on the newest read chapter", note.story_so_far:find("NEU-VON-ANFANG", 1, true) ~= nil)
            check("model noted", note.story_so_far_model == "gemini-3.6-flash")
            check("old text kept for restoring", note.original and note.original.story_so_far == "ALT-10 nur das Ende.")
            local recap = require("storyrecall/views").buildRecapText(p:buildContext())
            check("recap shows the new overview", recap:find("NEU-VON-ANFANG", 1, true) ~= nil)
            check("recap still shows the last chapter", recap:find("KAPITEL-10 passiert.", 1, true) ~= nil)
            check("no story-recall window left open", UIManager:getTopmostVisibleWidget().name == "ReaderUI")
            p.store:restoreChapterNote(toc[10].xpointer, "story_so_far")
            check("restore brings the old text back", p.store:getChapterNote(toc[10].xpointer).story_so_far == "ALT-10 nur das Ende.")
            -- Every model fails: a message, nothing stored
            AI.complete = function() return nil, { kind = "auth", code = 401, message = "invalid key" } end
            p:rewriteStorySoFar(function(done2)
                check("auth error: reported as failed", done2 == false)
                check("auth error: nothing changed", p.store:getChapterNote(toc[10].xpointer).story_so_far == "ALT-10 nur das Ende.")
                AI.setKey("gemini", nil)
                f:close(); UIManager:quit()
            end)
        end)
        if not ok2 then log("ERROR", e2); f:close(); UIManager:quit() end
    end)
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
