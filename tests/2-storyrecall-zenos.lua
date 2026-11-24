-- Test: ZenOS Home widget (run in the file browser with ZenOS installed).
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local Blitbuffer = require("ffi/blitbuffer")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/zenos-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
UIManager:scheduleIn(8, function()
  local ok, e = pcall(function()
    local FM = require("apps/filemanager/filemanager").instance
    check("file browser running", FM ~= nil)
    check("plugin loaded in file browser", FM and FM.storyrecall ~= nil)
    check("ZenOS registry present", type(rawget(_G, "__ZENOS_REGISTER_HOME_ITEM")) == "function")
    local Registry = require("modules/filebrowser/patches/home/components/registry")
    local comp = Registry.get("storyrecall.current_book")
    check("home widget registered", comp ~= nil and comp.label == "Story Recall")
    local book = require("storyrecall/zenos").currentBook()
    log("current book:", book and book.title, book and book.chapter_index, book and book.text and #book.text)
    check("current book has text", book and book.text and #book.text > 50)
    local w = comp.build({ width = Screen:getWidth() - 40, height = Screen:scaleBySize(160) })
    check("widget builds", w ~= nil)
    local bb = Blitbuffer.new(w:getSize().w, w:getSize().h, Screen.bb:getType())
    bb:fill(Blitbuffer.COLOR_WHITE)
    w:paintTo(bb, 0, 0)
    local tmp = Screen.bb; Screen.bb = bb
    Screen:shot(OUT .. "/30-zenos-home-widget.png")
    Screen.bb = tmp
    local tapped
    w.on_tap = function(file) tapped = file end
    w:onTapStoryRecall()
    check("tap passes the book", tapped == book.file)
    -- No ZenOS: registering is a no-op
    local saved = rawget(_G, "__ZENOS_REGISTER_HOME_ITEM"); local saved2 = rawget(_G, "__ZEN_UI_REGISTER_HOME_ITEM")
    rawset(_G, "__ZENOS_REGISTER_HOME_ITEM", nil); rawset(_G, "__ZEN_UI_REGISTER_HOME_ITEM", nil)
    check("without ZenOS nothing happens", require("storyrecall/zenos").registerHome(function() end) == false)
    rawset(_G, "__ZENOS_REGISTER_HOME_ITEM", saved); rawset(_G, "__ZEN_UI_REGISTER_HOME_ITEM", saved2)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/31-zenos-fm.png")
  end)
  if not ok then log("ERROR", e) end
  f:close(); UIManager:quit()
end)
