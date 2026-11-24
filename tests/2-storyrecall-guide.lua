local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/guide-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local p0 = require("apps/reader/readerui").instance.storyrecall
    local w0 = top(); if w0 and w0.name ~= "ReaderUI" then UIManager:close(w0) end
    p0:showGuide()
    local w = top()
    check("guide window opens", w and w.title == "Erste Schritte mit Story Recall")
    Screen:shot(OUT .. "/shots/14-guide.png")
    UIManager:close(w)
    local p = require("apps/reader/readerui").instance.storyrecall
    -- Chapters still missing: the usual "create now?" question
    local AIMenu0 = require("storyrecall/aimenu")
    local orig_nothing0 = AIMenu0.nothingToDo
    AIMenu0.nothingToDo = function() return false end
    p:onApiKeySaved()
    AIMenu0.nothingToDo = orig_nothing0
    UIManager:scheduleIn(1, function()
      local c = top()
      check("start offered after key saved", c and c.text and c.text:find("jetzt erstellen", 1, true) ~= nil)
      Screen:shot(OUT .. "/shots/15-offer-start.png")
      UIManager:close(c)
      local items = {}; p:addToMainMenu(items)
      local main = items.story_recall.sub_item_table_func()
      local function find(list, text)
          for _, it in ipairs(list or {}) do
              if (it.text or (it.text_func and it.text_func())) == text then return it end
          end
      end
      local settings = find(main, "Einstellungen")
      check("guide in the settings", settings and find(settings.sub_item_table, "Wie funktioniert das?") ~= nil)
      -- Menu layout: one page (10 items), everyday things first
      check("main menu fits on one page", #main <= 10)
      check("rewrite in the main menu", find(main, "Geschichte bisher neu schreiben") ~= nil)
      local book = find(main, "Buch & Notizen")
      check("book submenu has re-create and export", book and find(book.sub_item_table, "Alle KI-Notizen neu erstellen") ~= nil
          and find(book.sub_item_table, "Story-Notizen exportieren") ~= nil)
      local ai = settings and find(settings.sub_item_table, "KI")
      local ai_items = ai and ai.sub_item_table_func() or {}
      check("address hidden for Gemini", find(ai_items, "Adresse: nicht gesetzt") == nil)
      check("AI menu fits on one page", #ai_items <= 10)
      local advanced = find(ai_items, "Erweitert")
      check("advanced holds pause and batch size", advanced and #advanced.sub_item_table == 3)
      check("rewrite no longer in the AI settings", find(ai_items, "Geschichte bisher neu schreiben") == nil)
      -- Series recap only from volume 2 on (KOReader menus ignore show_func)
      local props = p.ui.doc_props
      local saved_series, saved_index = props.series, props.series_index
      props.series, props.series_index = "Testreihe", 1
      check("no series recap in volume 1", find(items.story_recall.sub_item_table_func(), "Reihen-Rückblick") == nil)
      props.series_index = 2
      check("series recap in volume 2", find(items.story_recall.sub_item_table_func(), "Reihen-Rückblick") ~= nil)
      props.series, props.series_index = saved_series, saved_index
      log("status:", require("storyrecall/aimenu").statusText(p))
      -- Menu order: AI status, rewrite, then the two submenus
      local function pos(text) for i, it in ipairs(main) do if (it.text or (it.text_func and it.text_func())) == text then return i end end end
      check("rewrite right after the AI status, book menu before settings",
          pos("Geschichte bisher neu schreiben") and pos("Buch & Notizen") == pos("Geschichte bisher neu schreiben") + 1
          and pos("Einstellungen") == pos("Buch & Notizen") + 1)
      -- All chapters done: key saved and tapping the status offer to re-create
      local AIMenu = require("storyrecall/aimenu")
      local orig_nothing = AIMenu.nothingToDo
      AIMenu.nothingToDo = function() return true end
      p:onApiKeySaved()
      local box = top()
      check("key saved with all notes: offers re-create", box and box.text and box.text:find("schon alle KI-Notizen", 1, true) ~= nil)
      Screen:shot(OUT .. "/shots/16-key-all-done.png")
      UIManager:close(box)
      -- Pretend a key is set (the test has none), then tap the status
      local AI = require("storyrecall/ai")
      local orig_cfg = AI.configFrom
      AI.configFrom = function() return {} end
      AIMenu.toggleProcessing(p)
      AI.configFrom = orig_cfg
      box = top()
      check("tap on finished status: asks to re-create", box and box.text and box.text:find("Alle Kapitel haben schon", 1, true) ~= nil)
      UIManager:close(box)
      AIMenu.nothingToDo = orig_nothing
      -- Lexicon order: cycles A–Z → most often → recently seen, choice is saved
      local Context = require("storyrecall/context")
      local fake = {
        { name = "Anna", type = "character", aliases = {}, chapter_count = 2, last_index = 9 },
        { name = "Bert", type = "character", aliases = {}, chapter_count = 7, last_index = 3 },
        { name = "Carl", type = "character", aliases = {}, chapter_count = 1, last_index = 12 },
      }
      local saved_sort
      local lctx = { lexicon_sort = nil, set_lexicon_sort = function(s) saved_sort = s end }
      Context.browse(lctx, fake)
      local function button(dialog, prefix)
        for _r, row in ipairs(dialog.buttons) do for _b, b in ipairs(row) do
          if b.text:find(prefix, 1, true) == 1 then return b end end end
      end
      local function firstOf(dialog)
        button(dialog, "Alle").callback()
        local list = top()[1].item_table
        local names = list[1].text .. "," .. list[2].text .. "," .. list[3].text
        UIManager:close(top())
        return names
      end
      local d = top()
      check("lexicon starts A–Z", button(d, "Sortierung: A–Z") ~= nil and firstOf(d) == "Anna,Bert,Carl")
      Screen:shot(OUT .. "/shots/17-lexicon-order.png")
      button(d, "Sortierung").callback()
      d = top()
      check("lexicon: most often", saved_sort == "count" and button(d, "Sortierung: Häufigkeit") ~= nil and firstOf(d) == "Bert,Anna,Carl")
      button(d, "Sortierung").callback()
      d = top()
      check("lexicon: recently seen", saved_sort == "recent" and button(d, "Sortierung: zuletzt") ~= nil and firstOf(d) == "Carl,Anna,Bert")
      button(d, "Sortierung").callback()
      check("lexicon: back to A–Z", saved_sort == "name")
      UIManager:close(top())
      -- Recap ☰ → "Story Recall settings" opens KOReader's menu right there
      p:openSettingsMenu()
      UIManager:scheduleIn(1, function()
        local m = p.ui.menu.menu_container and p.ui.menu.menu_container[1]
        check("settings menu opened from the recap", m and find(m.item_table, "Wie funktioniert das?") ~= nil and find(m.item_table, "KI") ~= nil)
        if p.ui.menu.onCloseReaderMenu then p.ui.menu:onCloseReaderMenu() end
        f:close(); UIManager:quit()
      end)
    end)
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
