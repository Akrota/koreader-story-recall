-- Test: "Who was that again?" (story context), dictionary/highlight buttons, custom service setup.
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/context-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function top() return UIManager:getTopmostVisibleWidget() end
local function closeTop() local w = top(); if w and w.name ~= "ReaderUI" then UIManager:close(w) end end
UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local Context = require("storyrecall/context")
    closeTop(); closeTop()
    -- Without a book that already has AI notes (e.g. on the generated
    -- reise.epub): create made-up notes for every chapter. The book text
    -- mentions Elias, Mara and Joren, so text passages can be found too.
    if p.store:countChapterNotes() < 10 then
        local toc = ui.toc.toc
        local people = {
            { name = "Elias Varn", aliases = { "Elias" }, fact = "Elias ist ein junger Kartograf aus dem Hof." },
            { name = "Mara", aliases = { "die Heilerin" }, fact = "Mara ist eine Heilerin, die Elias begleitet." },
            { name = "Joren", aliases = {}, fact = "Joren ist ein Söldner mit einer Narbe." },
        }
        local others = {
            { "Der Hof", "place" }, { "Nordturm", "place" }, { "Fluss Arl", "place" },
            { "Silberdolch", "object" }, { "Karte des Nordens", "object" },
            { "Rat der Drei", "group" }, { "Händlergilde", "group" },
            { "Sternenlesen", "term" }, { "Eidbruch", "term" }, { "Wächterin Ilsa", "character" },
            { "Bote Fenn", "character" }, { "Alte Brigid", "character" },
        }
        for i = 1, #toc do
            local entities = {}
            for _, person in ipairs(people) do
                table.insert(entities, { name = person.name, type = "character", aliases = person.aliases,
                    facts = { i == 1 and person.fact or (person.name .. " erlebt etwas in Kapitel " .. i .. ".") },
                    relation = person.name ~= "Elias Varn" and "Gefährte" or nil })
            end
            -- A rarely seen character with an open thread (chapters 3, 7, 10)
            if i == 3 or i == 7 or i == 10 then
                table.insert(entities, { name = "Casper", type = "character", aliases = {},
                    facts = { "Casper zeigt sich in Kapitel " .. i .. "." }, relation = "Kollege" })
            end
            local other = others[(i - 1) % #others + 1]
            table.insert(entities, { name = other[1], type = other[2], aliases = {}, facts = { other[1] .. " wird in Kapitel " .. i .. " wichtig." } })
            p.store:addChapterNote({ index = i, key = toc[i].xpointer, title = toc[i].title }, {
                summary = "Zusammenfassung von Kapitel " .. i .. ": Elias, Mara und Joren reisen weiter. " .. string.rep("Mehr Text. ", 25),
                story_so_far = "Die Geschichte bis Kapitel " .. i .. ".\n\nAm Ende des Kapitels " .. i .. " ruhen sie.",
                protagonist = "Elias Varn", entities = entities,
            })
            p.store:markChapterCompleted({ index = i, key = toc[i].xpointer, title = toc[i].title })
        end
        p.store.data.furthest_chapter = #toc
        p.store.data.furthest_key = toc[#toc].xpointer
        log("made-up notes created for", #toc, "chapters")
    end
    local furthest = p.store:getFurthestChapter()
    local saved_furthest = furthest
    local profiles, by_name, ctx = p:getProfiles()
    log("furthest", furthest, "profiles", #profiles, "protagonist", ctx.protagonist)
    check("profiles exist", #profiles > 10)
    local spoiler = false
    for _, pr in ipairs(profiles) do for _, fa in ipairs(pr.facts) do if fa.index > furthest then spoiler = true end end end
    check("no facts after furthest chapter", not spoiler)

    -- Exact name, genitive, single word
    local m = Context.find(profiles, by_name, ctx.protagonist)
    check("protagonist found", #m == 1 and m[1].name == ctx.protagonist)
    local first = ctx.protagonist:match("^(%S+)")
    m = Context.find(profiles, by_name, " „" .. first .. "s“, ")
    check("genitive + quotes", #m >= 1)
    m = Context.find(profiles, by_name, "Kühlschrank")
    check("unknown word -> nothing", #m == 0)

    p:showStoryContext(ctx.protagonist)
    local w = top()
    check("profile viewer opens", w and w.title == ctx.protagonist)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/20-context-protagonist.png")
    closeTop()

    -- A rarely seen character with few facts: Casper if known
    if by_name["casper"] then
      p:showStoryContext("Casper")
      UIManager:forceRePaint(); Screen:shot(OUT .. "/21-context-casper.png")
      log("casper facts", #by_name["casper"].facts, "first", by_name["casper"].first_index, "last", by_name["casper"].last_index)
      closeTop()
    else
      log("casper not known up to", furthest)
    end

    p:showStoryContext("Kühlschrank")
    w = top()
    check("unknown -> message", w and w.text and w.text:find("Kühlschrank", 1, true) ~= nil)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/22-context-unknown.png")
    closeTop()

    -- Passages only up to the read limit
    local pr = by_name[ctx.protagonist:lower()]
    local t0 = os.clock()
    local passages = Context.passages(p.ui, pr, ctx.read_limit_page)
    local late = false
    for _, ps in ipairs(passages) do if ps.page > ctx.read_limit_page then late = true end end
    log("passages", #passages, "in", string.format("%.2fs", os.clock() - t0), "limit page", ctx.read_limit_page)
    check("passages found, none beyond read point", #passages > 0 and not late)
    ctx.profile = pr
    Context.showPassages(p.ui, pr, ctx.read_limit_page, function() end)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/23-context-passages.png")
    closeTop()

    -- Story lexicon from the recap: categories, window list, stays open after a profile
    p:showRecap()
    local recap = top()
    local lex_button, note_button
    for _, row in ipairs(recap.buttons_table) do for _, b in ipairs(row) do
        if b.text == "Story-Lexikon" then lex_button = b end
        if b.text == "+ Notiz" then note_button = b end
    end end
    check("recap buttons: Story-Lexikon and + Notiz", lex_button ~= nil and note_button ~= nil)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/24a-recap-buttons.png")
    lex_button.callback()
    local dialog = top()
    check("lexicon opens with categories", dialog and dialog.title == "Story-Lexikon")
    UIManager:forceRePaint(); Screen:shot(OUT .. "/24b-lexicon-categories.png")
    local fig
    for _, row in ipairs(dialog.buttons) do if row[1].text:find("^Figuren %(") then fig = row[1] end end
    check("category Figuren present", fig ~= nil)
    fig.callback()
    local list_container = top()
    local list = list_container[1]
    check("list is a window titled Figuren", list and list.title and list.title:find("^Figuren %(") ~= nil and list.dimen.w < Screen:getWidth())
    local names = {}
    for _, item in ipairs(list.item_table) do table.insert(names, item.text) end
    local sorted = true
    for i = 2, #names do if require("ffi/util").strcoll(names[i], names[i - 1]) then sorted = false end end
    check("list sorted alphabetically", sorted)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/24c-lexicon-list.png")
    list:onMenuSelect(list.item_table[1]) -- like a real tap (Menu also runs close_callback)
    local prof = top()
    check("profile opens on top of the list", prof and prof.title == list.item_table[1].text)
    UIManager:close(prof)
    check("closing the profile returns to the list", top() == list_container)
    list:onClose()
    check("closing the list returns to the categories", top() == dialog)
    UIManager:close(dialog)
    check("then back to the recap", top() == recap)
    UIManager:close(recap)


    -- Chronicle navigation: first/last, jump to chapter / page
    p:showChronicle()
    local cv = top()
    local Views = require("storyrecall/views")
    local function curPage() local tw = cv.scroll_widget.text_widget; return math.ceil((tw.virtual_line_num - 1) / tw.lines_per_page) + 1 end
    local tw = cv.scroll_widget.text_widget
    local total = math.ceil(#tw.vertical_string_list / tw.lines_per_page)
    log("chronicle pages", total)
    -- The last page must show text (no page with only a trailing blank line)
    local chars = require("util").splitToChars(tw.text)
    local last_start = tw.vertical_string_list[(total - 1) * tw.lines_per_page + 1]
    local tail = last_start and table.concat(chars, "", last_start.offset, #chars) or ""
    check("last chronicle page is not blank", tail:find("%S") ~= nil)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/25-chronicle-bar.png")
    cv.button_table:getButtonById("first").callback()
    check("first page button", curPage() == 1 and cv.button_table:getButtonById("page").text:find("^1 / "))
    cv.button_table:getButtonById("last").callback()
    check("last page button", curPage() == total)
    Views.chronicleGoTo.page(3)
    check("go to page 3", curPage() == 3)
    check("go to chapter 20", Views.chronicleGoTo.chapter(20))
    local lines = tw.vertical_string_list
    local cp = Views.chronicleGoTo.offsets[20]
    local chars = require("util").splitToChars(tw.text)
    local first_line = tw.virtual_line_num
    local next_start = lines[first_line + tw.lines_per_page]
    log("text type", type(tw.text), tw.text and #tw.text, "chars", #chars, "charlist", type(tw.charlist)); log("ch20 charpos", cp, "chars", chars[cp], chars[cp + 1], chars[cp + 2], chars[cp + 3])
    check("chapter 20 heading offset right", chars[cp] == "2" and chars[cp + 1] == "0" and chars[cp + 3] == "·")
    check("chapter 20 heading at the top", lines[first_line].offset <= cp and (not lines[first_line + 1] or lines[first_line + 1].offset > cp))
    UIManager:forceRePaint(); Screen:shot(OUT .. "/26-chronicle-chapter20.png")
    check("unknown chapter refused", Views.chronicleGoTo.chapter(999) == false)
    cv.button_table:getButtonById("page").hold_callback()
    UIManager:forceRePaint(); Screen:shot(OUT .. "/27-chronicle-jump-dialog.png")
    closeTop(); closeTop()

    -- Correcting AI notes keeps the original
    local n2 = p.store:getChapterNotes(2)[2]
    local original = n2.summary
    p.store:editChapterNote(n2.key, "summary", "Korrigierte Zusammenfassung.")
    check("corrected summary used", p.store:getChapterNote(n2.key).summary == "Korrigierte Zusammenfassung." and n2.edited ~= nil)
    p.store:editChapterNote(n2.key, "summary", "Zweite Korrektur.")
    check("original kept across corrections", n2.original.summary == original)
    p.store:restoreChapterNote(n2.key, "summary")
    check("original restored", n2.summary == original and n2.original == nil and n2.edited == nil)
    require("storyrecall/views").showAINotesList(p.store, furthest, function() end)
    UIManager:forceRePaint(); Screen:shot(OUT .. "/28-correct-ai-notes.png")
    closeTop()

    -- Export stops at the furthest chapter read
    p.store.data.furthest_chapter = 5
    local md = require("storyrecall/export").markdown(p:buildContext())
    p.store.data.furthest_chapter = saved_furthest
    check("export has chapters up to 5", md:find("### 5 · ", 1, true) ~= nil and md:find("### 6 · ", 1, true) == nil)
    check("export has story so far and characters", md:find("## Die Geschichte bisher", 1, true) ~= nil and md:find("## Story-Lexikon", 1, true) ~= nil)
    local fh = io.open(OUT .. "/export-sample.md", "w"); fh:write(md); fh:close()
    -- Spoiler gate: pretend only chapter 3 was read
    local saved = p.store.data.furthest_chapter
    p.store.data.furthest_chapter = 3
    local early = p:getProfiles()
    local early_spoiler = false
    for _, ep in ipairs(early) do for _, fa in ipairs(ep.facts) do if fa.index > 3 then early_spoiler = true end end end
    check("gate at chapter 3", #early < #profiles and not early_spoiler)
    p.store.data.furthest_chapter = saved

    -- Buttons registered
    check("highlight button registered", p.ui.highlight._highlight_buttons["11_storyrecall"] ~= nil)
    local spec = p.ui.dictionary._dict_buttons and p.ui.dictionary._dict_buttons["storyrecall_context"]
    check("dictionary button registered", spec ~= nil)
    if spec then
      check("dict button shown for known name", spec.show_func({ word = first }) == true)
      check("dict button hidden for normal word", spec.show_func({ word = "und" }) == false)
    end
    local hb = p.ui.highlight._highlight_buttons["11_storyrecall"]({ selected_text = { text = first } })
    check("highlight button visible with notes", hb.text == "Story-Kontext" and hb.show_in_highlight_dialog_func())

    -- Custom service on the phone page
    local KS = require("storyrecall/keysetup")
    local c = KS.cleanCustom(" https://openrouter.ai/api/v1/chat/completions/ ", " google/gemini-2.5-flash ")
    check("custom url cleaned", c and c.url == "https://openrouter.ai/api/v1" and c.model == "google/gemini-2.5-flash")
    check("custom url rejected", KS.cleanCustom("openrouter.ai", "x") == nil and KS.cleanCustom("https://a.b/v1", "") == nil)
    local page = setmetatable({ token = "ab", provider_id = "custom", custom_url = "https://x.y/v1", custom_model = "m1" }, { __index = KS }):formPage()
    check("custom fields on page", page:find('id="cu"', 1, true) and page:find("https://x.y/v1", 1, true) and page:find('value="m1"', 1, true))
    local fh = io.open(OUT .. "/custom-page.html", "w"); fh:write(page); fh:close()
    f:close(); UIManager:quit()
  end)
  if not ok then log("ERROR", e); f:close(); UIManager:quit() end
end)
