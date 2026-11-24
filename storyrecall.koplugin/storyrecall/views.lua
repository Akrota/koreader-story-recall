--[[--
Dialogs and text views of Story Recall.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local Views = {}

local MAX_HIGHLIGHTS = 5
local HIGHLIGHT_MAX_CHARS = 200

local function formatDate(ts)
    if _("date_format") ~= "date_format" then
        return os.date(_("date_format"), ts)
    end
    return os.date("%Y-%m-%d", ts)
end

local function formatDaysAgo(ts)
    local days = math.floor((os.time() - ts) / 86400)
    if days <= 0 then
        return _("today")
    elseif days == 1 then
        return _("yesterday")
    end
    return T(_("%1 days ago"), days)
end

-- Simple bold text, as supported by KOReader's text box ("poor text formatting").
local function bold(text)
    return TextBoxWidget.PTF_BOLD_START .. text .. TextBoxWidget.PTF_BOLD_END
end

local function formatted(lines)
    -- No blank lines at the end: they could spill onto a page of their own.
    local text = table.concat(lines, "\n"):gsub("%s+$", "")
    return TextBoxWidget.PTF_HEADER .. text
end

local function truncate(text, max_chars)
    local chars = util.splitToChars(text)
    if #chars <= max_chars then return text end
    return table.concat(chars, "", 1, max_chars) .. "…"
end

local NUMBERED_TITLE_WORDS = {
    kapitel = true, chapter = true, chapitre = true, capitulo = true, capitolo = true, hoofdstuk = true,
}

-- The book's own chapter title, with its position in the TOC as a neutral
-- list number ("12 · Title"). It is not called "chapter 12": interludes and
-- prologues count too, so it may differ from the book's own numbering.
local function chapterLabel(chapter)
    local title = chapter.title and util.trim(chapter.title) or ""
    if not chapter.index or chapter.index <= 0 then
        return title
    end
    if title == "" then
        return T(_("Chapter %1"), chapter.index)
    end
    -- Titles that already carry a chapter number ("Kapitel 3", "3. Der Wald")
    -- need no second one.
    if title:match("^%d") then
        return title
    end
    local first_word = title:lower():match("^(%a+)%s+%d")
    if first_word and NUMBERED_TITLE_WORDS[first_word] then
        return title
    end
    return chapter.index .. " · " .. title
end

local function seriesLine(book)
    if not book or not book.series then return end
    if book.series_index then
        return T(_("Series: %1, volume %2"), book.series, book.series_index)
    end
    return T(_("Series: %1"), book.series)
end

local function appendNotes(lines, notes)
    local last_key
    for _i, note in ipairs(notes) do
        if note.chapter_key ~= last_key then
            table.insert(lines, "")
            table.insert(lines, bold(chapterLabel{ index = note.chapter_index, title = note.chapter_title }))
            last_key = note.chapter_key
        end
        table.insert(lines, "• " .. note.text)
    end
end

--- Highlights before the current page, newest position last.
local function recentHighlights(ui, current_page)
    local result = {}
    local annotations = ui.annotation and ui.annotation.annotations or {}
    for _i, item in ipairs(annotations) do
        if item.text and item.text ~= "" and item.pageno and item.pageno <= current_page then
            table.insert(result, item)
        end
    end
    local first = math.max(1, #result - MAX_HIGHLIGHTS + 1)
    local recent = {}
    for i = first, #result do
        table.insert(recent, result[i])
    end
    return recent
end

--- Recap text.
-- @param ctx table with ui, store, book, chapter (current), read_chapter (furthest read),
--            read_limit_page, recap_chapters, last_seen, after_break
function Views.buildRecapText(ctx)
    local lines = {}
    if ctx.after_break then
        table.insert(lines, bold(_("Welcome back!")))
        table.insert(lines, "")
    end
    if ctx.last_seen then
        table.insert(lines, T(_("Last read: %1 (%2)"), formatDaysAgo(ctx.last_seen), formatDate(ctx.last_seen)))
    end
    local series = seriesLine(ctx.book)
    if series then table.insert(lines, series) end
    table.insert(lines, T(_("You are in: %1"), chapterLabel(ctx.chapter)))
    if ctx.read_chapter.index > ctx.chapter.index then
        table.insert(lines, T(_("Read up to: %1"), chapterLabel(ctx.read_chapter)))
    end

    -- Own notes and highlights: the last chapters up to where the reader is.
    local upto = ctx.recap_upto or ctx.read_chapter.index
    local min_index = math.max(0, upto - ctx.recap_chapters + 1)
    local notes = {}
    for _i, note in ipairs(ctx.store:getNotes(upto)) do
        if note.chapter_index >= min_index then
            table.insert(notes, note)
        end
    end
    local highlights = recentHighlights(ctx.ui, ctx.recap_limit_page or ctx.read_limit_page)

    -- The story so far: from the newest AI note up to the point read.
    local recap_index = ctx.recap_index or ctx.ai_index
    local chapter_notes = ctx.store:getChapterNotes(recap_index)
    local latest
    for i = #chapter_notes, 1, -1 do
        if chapter_notes[i].story_so_far then latest = chapter_notes[i] break end
    end
    local summaries = {}
    if latest then
        table.insert(summaries, latest)
        -- AI notes may not reach the point read yet (still being created):
        -- then say how far they go instead of calling it the last chapter.
        local complete = latest.index >= recap_index
        table.insert(lines, "")
        if complete then
            table.insert(lines, bold(_("The story so far")))
        else
            table.insert(lines, bold(T(_("The story so far (up to %1)"), chapterLabel(latest))))
        end
        -- Always the story so far, also for a finished book: the volume summary
        -- is written for the start of the NEXT volume ("In this first volume…")
        -- and belongs in its series recap, not here.
        table.insert(lines, latest.story_so_far)
        table.insert(lines, "")
        if complete then
            table.insert(lines, bold(T(_("Last chapter: %1"), chapterLabel(latest))))
        else
            table.insert(lines, bold(T(_("Last chapter with AI notes: %1"), chapterLabel(latest))))
        end
        table.insert(lines, latest.summary)
        if not complete then
            table.insert(lines, "")
            table.insert(lines, _("AI notes for the chapters after it are still being created."))
        end
    else
        -- Notes created before story-so-far summaries existed: list the last chapters.
        for _i, note in ipairs(chapter_notes) do
            if note.index >= min_index then
                table.insert(summaries, note)
            end
        end
        if #summaries > 0 then
            table.insert(lines, "")
            table.insert(lines, bold(_("What happened recently")))
            for _i, note in ipairs(summaries) do
                table.insert(lines, "")
                table.insert(lines, bold(chapterLabel(note)))
                table.insert(lines, note.summary)
            end
        end
    end

    if #notes > 0 then
        table.insert(lines, "")
        table.insert(lines, bold(_("Your notes from the last chapters")))
        appendNotes(lines, notes)
    end

    if #highlights > 0 then
        table.insert(lines, "")
        table.insert(lines, bold(_("Your latest highlights")))
        for _i, item in ipairs(highlights) do
            table.insert(lines, "")
            local text = truncate(util.cleanupSelectedText(item.text), HIGHLIGHT_MAX_CHARS)
            table.insert(lines, "„" .. text .. "“")
            if item.chapter then
                table.insert(lines, "   " .. item.chapter)
            end
            if item.note and item.note ~= "" then
                table.insert(lines, "   " .. T(_("Note: %1"), item.note))
            end
        end
    end

    if #notes == 0 and #highlights == 0 and #summaries == 0 then
        table.insert(lines, "")
        table.insert(lines, _("Nothing to recap yet. With “+ Note” below you can write something down yourself; the AI notes appear here once they have been created."))
        if ctx.empty_hint then
            table.insert(lines, "")
            table.insert(lines, ctx.empty_hint)
        end
    end
    return formatted(lines)
end

--- The recap: the main Story Recall window.
-- @param actions { chronicle = fn(), lexicon = fn(recap_viewer), note = fn() }
function Views.showRecap(ctx, actions)
    local viewer
    viewer = TextViewer:new{
        title = _("Recap"),
        text = Views.buildRecapText(ctx),
        justified = false,
        buttons_table = {
            {
                {
                    text = _("Story chronicle"),
                    callback = function()
                        UIManager:close(viewer)
                        actions.chronicle()
                    end,
                },
                {
                    text = _("Story lexicon"),
                    enabled = actions.lexicon ~= nil,
                    callback = function()
                        -- Opens on top; closing it comes back here.
                        actions.lexicon(viewer)
                    end,
                },
            },
            {
                {
                    text = "+ " .. _("Note"),
                    enabled = actions.note ~= nil,
                    callback = function() actions.note() end,
                },
                {
                    text = _("Continue reading"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
    }
    -- ☰ (title bar): Story Recall actions first, KOReader's own text options
    -- (font size, justify…) under "Display…".
    if actions.menu then
        function viewer:onShowMenu()
            local dialog
            local rows = {}
            for _i, item in ipairs(actions.menu) do
                table.insert(rows, {{
                    text = item.text,
                    enabled = item.enabled ~= false,
                    align = "left",
                    callback = function()
                        UIManager:close(dialog)
                        if item.close_recap then UIManager:close(viewer) end
                        item.callback()
                    end,
                }})
            end
            table.insert(rows, {{
                text = _("Display…"),
                align = "left",
                callback = function()
                    UIManager:close(dialog)
                    TextViewer.onShowMenu(viewer)
                end,
            }})
            dialog = ButtonDialog:new{
                shrink_unneeded_width = true,
                buttons = rows,
                anchor = function() return viewer.titlebar.left_button.image.dimen end,
            }
            UIManager:show(dialog)
            return true
        end
    end
    UIManager:show(viewer)
end

--- Chronicle text: every chapter up to the furthest one read, with its notes,
-- in reading order.
-- @return text, and the character offset of each chapter heading (by chapter
--         index) in the text as displayed (without formatting marks)
function Views.buildChronicleText(ctx)
    local chapters = ctx.chapters
    local lines = {}
    local heading_lines = {}
    local notes_by_key = {}
    for _i, note in ipairs(ctx.store:getNotes(ctx.read_chapter.index)) do
        notes_by_key[note.chapter_key] = notes_by_key[note.chapter_key] or {}
        table.insert(notes_by_key[note.chapter_key], note)
    end
    local summary_by_key = {}
    for _i, note in ipairs(ctx.store:getChapterNotes(ctx.ai_index)) do
        summary_by_key[note.key] = note.summary
    end

    -- Notes taken before the first TOC entry (front matter) come first.
    for _j, note in ipairs(notes_by_key.front or {}) do
        table.insert(lines, "• " .. note.text)
    end
    if notes_by_key.front then
        table.insert(lines, "")
    end

    for _i, chapter in ipairs(chapters) do
        local entry = ctx.store:getChapter(chapter.key)
        local status = ""
        if entry and entry.completed_at then
            status = "  ✓"
        elseif chapter.key == ctx.chapter.key then
            status = "  ← " .. _("reading")
        end
        -- Chapters without notes stay compact; chapters with notes get some air.
        local chapter_notes = notes_by_key[chapter.key]
        local summary = summary_by_key[chapter.key]
        local has_text = chapter_notes or summary
        if has_text and #lines > 0 and lines[#lines] ~= "" then
            table.insert(lines, "")
        end
        table.insert(lines, bold(chapterLabel(chapter)) .. status)
        heading_lines[chapter.index] = #lines
        if summary then
            table.insert(lines, summary)
        end
        for _j, note in ipairs(chapter_notes or {}) do
            table.insert(lines, "• " .. note.text)
        end
        if has_text then
            table.insert(lines, "")
        end
    end
    if lines[#lines] ~= "" then
        table.insert(lines, "")
    end

    -- Never let anything look deleted: say what is hidden and why.
    local hidden = #ctx.store:getNotes() - #ctx.store:getNotes(ctx.read_chapter.index)
    if hidden > 0 then
        table.insert(lines, T(_("%1 note(s) after the furthest point you have read are hidden."), hidden))
    end

    local line_offsets, offset = {}, 1
    for i, line in ipairs(lines) do
        line_offsets[i] = offset
        local plain = line:gsub(TextBoxWidget.PTF_BOLD_START, ""):gsub(TextBoxWidget.PTF_BOLD_END, "")
        offset = offset + #util.splitToChars(plain) + 1 -- + newline
    end
    local heading_offsets = {}
    for index, line_num in pairs(heading_lines) do
        heading_offsets[index] = line_offsets[line_num]
    end
    return formatted(lines), heading_offsets
end

--- The chronicle. Opens on its last page (where you are); the bar at the
-- bottom pages back and forth.
-- @param on_recap function to go back to the recap
function Views.showChronicle(ctx, on_recap)
    local viewer
    local text, heading_offsets = Views.buildChronicleText(ctx)
    local function pageInfo()
        local text_widget = viewer.scroll_widget.text_widget
        local total_lines = #text_widget.vertical_string_list
        local per_page = math.max(1, text_widget.lines_per_page)
        local total = math.max(1, math.ceil(total_lines / per_page))
        -- The last page ends with the last line, so it may start between page
        -- boundaries: round up.
        local current = math.min(total, math.ceil((text_widget.virtual_line_num - 1) / per_page) + 1)
        return current, total
    end
    local function updateBar()
        local current, total = pageInfo()
        local label = viewer.button_table:getButtonById("page")
        label:setText(T(_("%1 / %2"), current, total), label.width)
        viewer.button_table:getButtonById("first"):enableDisable(current > 1)
        viewer.button_table:getButtonById("prev"):enableDisable(current > 1)
        viewer.button_table:getButtonById("next"):enableDisable(current < total)
        viewer.button_table:getButtonById("last"):enableDisable(current < total)
        if viewer.shown then
            UIManager:setDirty(viewer, "ui")
        end
    end
    local function goToPage(page)
        local _current, total = pageInfo()
        page = math.max(1, math.min(total, page))
        viewer.scroll_widget:scrollToRatio(total > 1 and (page - 1) / (total - 1) or 0, true)
    end
    local function goToChapter(index)
        local charpos = heading_offsets[index]
        if not charpos then return false end
        -- Put the heading at the top of the view (not on the page grid, where
        -- it could end up as the last line).
        local text_widget = viewer.scroll_widget.text_widget
        local lines = text_widget.vertical_string_list
        local line = 1
        while lines[line + 1] and lines[line + 1].offset <= charpos do line = line + 1 end
        text_widget:scrollLines(line - text_widget.virtual_line_num)
        viewer.scroll_widget:updateScrollBar(true)
        return true
    end
    Views.chronicleGoTo = { page = goToPage, chapter = goToChapter, offsets = heading_offsets } -- for tests
    local function askJump()
        local dialog
        dialog = InputDialog:new{
            title = _("Go to"),
            input_hint = _("chapter number, or p12 for page 12"),
            description = _("Enter a chapter number. For a page, put a p in front, e.g. p12."),
            buttons = {{
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function() UIManager:close(dialog) end,
                },
                {
                    text = _("Go"),
                    is_enter_default = true,
                    callback = function()
                        local input = (dialog:getInputText() or ""):gsub("%s", ""):lower()
                        local page = tonumber(input:match("^[ps](%d+)$"))
                        local chapter = tonumber(input:match("^(%d+)$"))
                        if page then
                            UIManager:close(dialog)
                            goToPage(page)
                        elseif chapter and goToChapter(chapter) then
                            UIManager:close(dialog)
                        else
                            UIManager:show(InfoMessage:new{
                                text = chapter and T(_("Chapter %1 is not in the chronicle (yet)."), chapter)
                                    or _("Enter a chapter number, or p and a page number."),
                                timeout = 3,
                            })
                        end
                    end,
                },
            }},
        }
        UIManager:show(dialog)
        dialog:onShowKeyboard()
    end
    viewer = TextViewer:new{
        title = ctx.title or _("Story chronicle"),
        text = text,
        justified = false,
        buttons_table = {
            {
                {
                    id = "first",
                    text = "◁◁",
                    callback = function() goToPage(1) end,
                },
                {
                    id = "prev",
                    text = "◁",
                    callback = function() viewer.scroll_widget:scrollUp() end,
                },
                {
                    id = "page",
                    text = T(_("%1 / %2"), 1, 1),
                    callback = askJump,
                    hold_callback = askJump,
                },
                {
                    id = "next",
                    text = "▷",
                    callback = function() viewer.scroll_widget:scrollDown() end,
                },
                {
                    id = "last",
                    text = "▷▷",
                    callback = function() goToPage(math.huge) end,
                },
            },
            {
                {
                    text = "‹ " .. _("Recap"),
                    callback = function()
                        UIManager:close(viewer)
                        on_recap()
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(viewer)
                    end,
                },
            },
        },
    }
    -- Keep the page label in sync however the text is scrolled
    -- (bar buttons, swipes, page keys).
    local scroll_widget = viewer.scroll_widget
    local updateScrollBar = scroll_widget.updateScrollBar
    scroll_widget.updateScrollBar = function(widget, is_partial)
        updateScrollBar(widget, is_partial)
        updateBar()
    end
    -- Open on the last page, aligned to the same page grid as paging from the top.
    scroll_widget:scrollToRatio(1, true)
    UIManager:show(viewer)
    viewer.shown = true
end

--- Series recap text.
-- @param book current book { series, series_index }
-- @param volumes from Series.previousVolumes, oldest first
function Views.buildSeriesRecapText(book, volumes)
    local lines = { bold(T(_("%1 – before volume %2"), book.series or "", book.series_index or "?")) }
    local sources, sources_seen = {}, {}
    for i, volume in ipairs(volumes) do
        local summary = volume.summary
        table.insert(lines, "")
        local heading = T(_("Volume %1: %2"), volume.series_index, volume.title or "")
        table.insert(lines, bold(heading))
        if volume.source == "internet" then
            table.insert(lines, _("(from the internet, may contain mistakes)"))
        elseif not summary.finished then
            table.insert(lines, T(_("(read up to: %1)"), chapterLabel{ index = summary.chapter_index, title = summary.chapter_title }))
        end
        local text = summary.text
        if i < #volumes then
            -- Older volumes: only the main plot, so a long series stays readable.
            -- The volume right before gets everything. A volume summary has the
            -- plot in its first paragraph; the story so far may spread it over
            -- several (one per part), followed by "Zuletzt …".
            if summary.story_so_far then
                text = text:match("^(.*)\n%s*\n") or text
            else
                text = text:match("^(.-)\n%s*\n") or text
            end
        end
        table.insert(lines, text)
        for _j, source in ipairs(volume.source == "internet" and volume.sources or {}) do
            if not sources_seen[source] then
                sources_seen[source] = true
                table.insert(sources, source)
            end
        end
    end
    if #sources > 0 then
        table.insert(lines, "")
        table.insert(lines, _("Sources:"))
        for _j, source in ipairs(sources) do table.insert(lines, "• " .. source) end
    end
    return formatted(lines)
end

-- @param actions optional { recreate = function(volume, on_done) } for the ☰ menu
function Views.showSeriesRecap(book, volumes, actions)
    local viewer
    viewer = TextViewer:new{
        title = _("Series recap"),
        text = Views.buildSeriesRecapText(book, volumes),
        justified = false,
        buttons_table = {{
            {
                text = _("Continue reading"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    -- ☰: write the summary of the volume right before again (its notes are on the
    -- device), KOReader's own text options under "Display…".
    local previous = volumes[#volumes]
    if actions and actions.recreate then
        function viewer:onShowMenu()
            local dialog
            local can = previous and previous.source == "book" and previous.file ~= nil
            dialog = ButtonDialog:new{
                shrink_unneeded_width = true,
                buttons = {
                    {{
                        text = T(_("Write the summary of volume %1 again"), previous and previous.series_index or "?"),
                        enabled = can,
                        align = "left",
                        callback = function()
                            UIManager:close(dialog)
                            actions.recreate(previous, function(found)
                                UIManager:close(viewer)
                                if found then Views.showSeriesRecap(book, found, actions) end
                            end)
                        end,
                    }},
                    {{
                        text = _("Display…"),
                        align = "left",
                        callback = function()
                            UIManager:close(dialog)
                            TextViewer.onShowMenu(viewer)
                        end,
                    }},
                },
                anchor = function() return viewer.titlebar.left_button.image.dimen end,
            }
            UIManager:show(dialog)
            return true
        end
    end
    UIManager:show(viewer)
end

--- Dialog to add or edit a note.
-- @param title dialog title
-- @param text initial text (nil for a new note)
-- @param on_save function(text)
function Views.editNote(title, text, on_save, hint)
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = text or "",
        input_hint = hint or _("What happened? Who is important?"),
        allow_newline = true,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = util.trim(dialog:getInputText() or "")
                    UIManager:close(dialog)
                    if value ~= "" then
                        on_save(value)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- AI notes up to the furthest chapter read; tap one to correct it.
-- @param max_index furthest chapter read
function Views.showAINotesList(store, max_index, on_changed)
    local menu
    local function buildItems()
        local items = {}
        local notes = store:getChapterNotes(max_index)
        for i = #notes, 1, -1 do
            local note = notes[i]
            table.insert(items, {
                text = chapterLabel(note),
                mandatory = note.edited and ("✎ " .. _("corrected")) or nil,
                note = note,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("No AI notes yet."), select_enabled = false })
        end
        return items
    end
    local function refresh()
        menu:switchItemTable(nil, buildItems())
        on_changed()
    end
    local FIELDS = {
        { key = "summary", label = _("Chapter summary") },
        { key = "story_so_far", label = _("The story so far") },
        { key = "volume_summary", label = _("Summary of the volume") },
    }
    menu = Menu:new{
        title = _("Correct AI notes"),
        item_table = buildItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_menu, item)
            local note = item.note
            if not note then return true end
            local dialog
            local buttons = {}
            for _i, field in ipairs(FIELDS) do
                if note[field.key] then
                    table.insert(buttons, {{
                        text = T(_("Edit: %1"), field.label),
                        callback = function()
                            UIManager:close(dialog)
                            Views.editNote(field.label, note[field.key], function(value)
                                store:editChapterNote(note.key, field.key, value)
                                refresh()
                            end, field.label)
                        end,
                    }})
                end
                if note.original and note.original[field.key] ~= nil then
                    table.insert(buttons, {{
                        text = T(_("Restore original: %1"), field.label),
                        callback = function()
                            UIManager:close(dialog)
                            store:restoreChapterNote(note.key, field.key)
                            refresh()
                        end,
                    }})
                end
            end
            dialog = ButtonDialog:new{
                title = chapterLabel(note),
                buttons = buttons,
            }
            UIManager:show(dialog)
            return true
        end,
    }
    UIManager:show(menu)
end

--- List of all own notes; tap one to edit or delete it.
function Views.showNotesList(store, on_changed)
    local menu
    local function buildItems()
        local items = {}
        local notes = store:getNotes()
        -- Newest chapter first, like the chronicle.
        for i = #notes, 1, -1 do
            local note = notes[i]
            table.insert(items, {
                text = note.text:gsub("\n", " "),
                mandatory = note.chapter_index > 0 and tostring(note.chapter_index) or nil,
                note = note,
            })
        end
        if #items == 0 then
            table.insert(items, { text = _("No notes yet."), select_enabled = false })
        end
        return items
    end

    local function refresh()
        menu:switchItemTable(nil, buildItems())
        on_changed()
    end

    menu = Menu:new{
        title = _("Edit notes"),
        item_table = buildItems(),
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        onMenuChoice = function(_menu, item)
            local note = item.note
            if not note then return true end
            local dialog
            dialog = ButtonDialog:new{
                title = chapterLabel{ index = note.chapter_index, title = note.chapter_title },
                buttons = {
                    {{
                        text = _("Edit"),
                        callback = function()
                            UIManager:close(dialog)
                            Views.editNote(_("Edit note"), note.text, function(value)
                                store:updateNote(note.id, value)
                                refresh()
                            end)
                        end,
                    }},
                    {{
                        text = _("Delete"),
                        callback = function()
                            UIManager:close(dialog)
                            UIManager:show(ConfirmBox:new{
                                text = _("Delete this note?"),
                                ok_text = _("Delete"),
                                ok_callback = function()
                                    store:deleteNote(note.id)
                                    refresh()
                                end,
                            })
                        end,
                    }},
                },
            }
            UIManager:show(dialog)
            return true
        end,
    }
    UIManager:show(menu)
end

Views.chapterLabel = chapterLabel
Views.seriesLine = seriesLine
Views.formatDate = formatDate

return Views
