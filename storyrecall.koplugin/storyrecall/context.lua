--[[--
"Who was that again?": the story context of a character, place, object,
group or term, assembled on the device from all AI facts up to the furthest
chapter read. Nothing from later chapters is shown, and nothing is sent to
the AI.
--]]

local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local CenterContainer = require("ui/widget/container/centercontainer")
local Event = require("ui/event")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local Screen = require("device").screen
local Store = require("storyrecall/store")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local Context = {}

local MAX_PASSAGES = 60
-- Long profiles show this many of the latest facts under "Lately".
local RECENT_FACTS = 4

local TYPE_LABELS = {
    character = "Character",
    place = "Place",
    object = "Object",
    creature = "Creature",
    group = "Group",
    term = "Term",
}

local function bold(text)
    return TextBoxWidget.PTF_BOLD_START .. text .. TextBoxWidget.PTF_BOLD_END
end

local function chapterLabel(index, title, volume)
    local label
    if index and index > 0 and title and title ~= "" then
        label = index .. " · " .. title
    else
        label = title or T(_("Chapter %1"), index or "?")
    end
    -- From an earlier volume of the series (series lexicon)
    if volume then label = T(_("Vol. %1 · %2"), volume, label) end
    return label
end

--- Clean up a selection: trim, drop surrounding punctuation and quotes.
-- Typographic quotes are several bytes in UTF-8; Lua patterns work on bytes,
-- so they are replaced one by one (inside [...] they would cut other letters).
local QUOTES = { "„", "“", "”", "‚", "‘", "«", "»", "‹", "›" }

local function cleanSelection(text)
    text = util.cleanupSelectedText(text or "")
    text = text:gsub("’", "'")
    for _i, quote in ipairs(QUOTES) do
        text = text:gsub(quote, " ")
    end
    -- %s and %p only match ASCII characters here.
    text = text:gsub("^[%s%p]+", ""):gsub("[%s%p]+$", "")
    return text
end

--- Find the profiles a selected text refers to.
-- Tries, in order: the exact name or alias, the same without a genitive "s",
-- then single words of the selection against single words of names.
-- @return list of matching profiles (best first)
function Context.find(profiles, by_name, selection)
    local text = cleanSelection(selection):lower()
    if text == "" then return {} end
    local candidates = { text }
    -- German/English genitive: "Toms", "Tom's", "Maras"
    local stripped = text:gsub("'s$", ""):gsub("s$", "")
    if stripped ~= text then table.insert(candidates, stripped) end
    -- Names are stored without rarity or level ("Wolf – Level 40" is "wolf").
    for i = 1, #candidates do table.insert(candidates, (Store.normalizeName(candidates[i]))) end
    for _i, candidate in ipairs(candidates) do
        if by_name[candidate] then return { by_name[candidate] } end
    end

    -- Word match: "Brenner" finds "Tom Brenner"; "Anna" finds "Anna Smith".
    local words = {}
    for word in text:gmatch("[%w\128-\255]+") do
        if #word >= 3 then
            words[word] = true
            words[(word:gsub("s$", ""))] = true
        end
    end
    local matches, seen = {}, {}
    for _i, profile in ipairs(profiles) do
        local names = { profile.name }
        for _i, alias in ipairs(profile.aliases) do table.insert(names, alias) end
        for _i, name in ipairs(names) do
            for word in name:lower():gmatch("[%w\128-\255]+") do
                if words[word] and not seen[profile] then
                    seen[profile] = true
                    table.insert(matches, profile)
                end
            end
        end
    end
    -- Characters first, then by how much is known.
    table.sort(matches, function(a, b)
        local a_char, b_char = a.type == "character", b.type == "character"
        if a_char ~= b_char then return a_char end
        return #a.facts > #b.facts
    end)
    return matches
end

--- The profile as formatted text.
function Context.buildText(profile, protagonist)
    local lines = {}
    if profile.asked then
        -- From "Ask the AI", not from the chapter notes.
        table.insert(lines, T(_("%1 · asked the AI, as of %2"), _(TYPE_LABELS[profile.type] or "Term"),
            chapterLabel(profile.first_index, profile.first_title, profile.first_volume)))
    else
        table.insert(lines, T(_("%1 · first seen in %2"), _(TYPE_LABELS[profile.type] or "Term"),
            chapterLabel(profile.first_index, profile.first_title, profile.first_volume)))
    end
    if #profile.aliases > 0 then
        table.insert(lines, T(_("Also: %1"), table.concat(profile.aliases, ", ")))
    end
    -- The last fundamental change (died, disappeared, changed sides…).
    if profile.status then
        table.insert(lines, "")
        table.insert(lines, bold(T(_("Status (%1):"), chapterLabel(profile.status.index, profile.status.title, profile.status.volume)))
            .. " " .. profile.status.text)
    end

    if profile.facts[1] then
        table.insert(lines, "")
        table.insert(lines, bold(_("Who or what is it?")))
        table.insert(lines, profile.facts[1].text)
    end

    if profile.relation and protagonist and profile.name ~= protagonist then
        table.insert(lines, "")
        table.insert(lines, bold(T(_("Relation to %1"), protagonist)))
        table.insert(lines, profile.relation)
    end

    local function appendFacts(from, to)
        local last_index, last_volume
        for i = from, to do
            local fact = profile.facts[i]
            if fact.index ~= last_index or fact.volume ~= last_volume then
                table.insert(lines, chapterLabel(fact.index, fact.title, fact.volume))
                last_index, last_volume = fact.index, fact.volume
            end
            table.insert(lines, "• " .. fact.text)
        end
    end
    local count = #profile.facts
    if count > 1 + RECENT_FACTS + 2 then
        -- A long profile (main characters): the latest facts first, so the
        -- reader sees where things stand without scrolling to the end.
        table.insert(lines, "")
        table.insert(lines, bold(_("Lately")))
        appendFacts(count - RECENT_FACTS + 1, count)
        table.insert(lines, "")
        table.insert(lines, bold(_("Earlier")))
        appendFacts(2, count - RECENT_FACTS)
    elseif count > 1 then
        table.insert(lines, "")
        table.insert(lines, bold(_("So far")))
        appendFacts(2, count)
    end

    table.insert(lines, "")
    table.insert(lines, T(_("Last mentioned: %1"), chapterLabel(profile.last_index, profile.last_title, profile.last_volume)))
    return TextBoxWidget.PTF_HEADER .. table.concat(lines, "\n")
end

--- Passages in the book that mention the profile, only before the read limit.
function Context.passages(ui, profile, read_limit_page)
    local doc = ui.document
    if not doc.findAllText then return {} end
    -- Search every name the story uses for it; for a character also the first
    -- name alone ("Tom" for "Tom Brenner"), as that is how most books refer to them.
    local terms, seen_terms = {}, {}
    local function addTerm(term)
        if term and #term >= 3 and not seen_terms[term:lower()] then
            seen_terms[term:lower()] = true
            table.insert(terms, term)
        end
    end
    addTerm(profile.name)
    for _i, alias in ipairs(profile.aliases) do addTerm(alias) end
    -- The first name alone, unless it is an article or title ("The Butcher", "Lord Brand").
    local NOT_A_NAME = { the = true, der = true, die = true, das = true, ein = true, eine = true, ["la"] = true, ["le"] = true,
        lord = true, lady = true, sir = true, king = true, queen = true, ["könig"] = true, ["königin"] = true, herr = true, frau = true,
        mr = true, mrs = true, ms = true, dr = true, captain = true, general = true }
    local first = profile.type == "character" and profile.name:match("^(%S+)%s")
    if first and not NOT_A_NAME[first:lower():gsub("%.$", "")] then addTerm(first) end

    local results, seen = {}, {}
    for _i, term in ipairs(terms) do
        local ok, hits = pcall(doc.findAllText, doc, term, true, 6, 2000, false)
        for _j, hit in ipairs(ok and type(hits) == "table" and hits or {}) do
            local page = hit.start and doc:getPageFromXPointer(hit.start)
            if page and page <= read_limit_page and not seen[hit.start] then
                seen[hit.start] = true
                -- Like KOReader's search: a space only where the context does
                -- not bring its own, none before punctuation ("Elias, Mara").
                local prev, next_text = hit.prev_text or "", hit.next_text or ""
                if prev ~= "" and not prev:find("%s$") then prev = prev .. " " end
                if next_text ~= "" and not next_text:find("^[%s%p]") then next_text = " " .. next_text end
                table.insert(results, { page = page, xpointer = hit.start,
                    text = ((prev .. (hit.matched_text or "") .. next_text):gsub("%s+", " ")) })
            end
        end
    end
    -- Newest first: the last mentions are usually the ones you want.
    table.sort(results, function(a, b) return a.page > b.page end)
    while #results > MAX_PASSAGES do table.remove(results) end
    return results
end

function Context.showPassages(ui, profile, read_limit_page, on_jump)
    local passages = Context.passages(ui, profile, read_limit_page)
    if #passages == 0 then
        UIManager:show(InfoMessage:new{ text = T(_("No passages found for %1 up to where you have read."), profile.name) })
        return
    end
    local menu
    local items = {}
    for _i, passage in ipairs(passages) do
        table.insert(items, {
            text = "…" .. passage.text .. "…",
            mandatory = tostring(passage.page),
            callback = function()
                UIManager:close(menu)
                on_jump()
                ui.link:addCurrentLocationToStack()
                ui:handleEvent(Event:new("GotoXPointer", passage.xpointer, passage.xpointer))
            end,
        })
    end
    menu = Menu:new{
        title = T(_("Passages: %1"), profile.name),
        item_table = items,
        covers_fullscreen = true,
        is_borderless = true,
        is_popout = false,
        multilines_show_more_text = true,
    }
    UIManager:show(menu)
end

--- Show the story context.
-- @param ctx { ui, profile, protagonist, read_limit_page }
function Context.show(ctx)
    local viewer
    viewer = TextViewer:new{
        title = ctx.profile.name,
        text = Context.buildText(ctx.profile, ctx.protagonist),
        justified = false,
        buttons_table = {{
            {
                text = _("Passages"),
                enabled = ctx.ui.document.findAllText ~= nil,
                callback = function()
                    Context.showPassages(ctx.ui, ctx.profile, ctx.read_limit_page, function()
                        -- Jumping into the book: close every Story Recall window on the way.
                        UIManager:close(viewer)
                        Context.closeAll(ctx)
                    end)
                end,
            },
            {
                text = _("Close"),
                callback = function() UIManager:close(viewer) end,
            },
        }},
    }
    UIManager:show(viewer)
end

--- A list of profiles in a window; tapping one shows it on top, closing the
-- profile returns to the list.
-- @bool hide_type the list is one category: no need to repeat it on every line
function Context.choose(ctx, matches, title, hide_type)
    local items = {}
    for _i, profile in ipairs(matches) do
        table.insert(items, {
            text = profile.name,
            mandatory = not hide_type and _(TYPE_LABELS[profile.type] or "Term") or nil,
            callback = function()
                ctx.profile = profile
                Context.show(ctx)
            end,
        })
    end
    -- A window over the recap, not a full screen.
    local container = CenterContainer:new{ dimen = Screen:getSize() }
    local menu = Menu:new{
        title = title or _("Which one do you mean?"),
        item_table = items,
        width = math.floor(Screen:getWidth() * 0.92),
        height = math.floor(Screen:getHeight() * 0.88),
        covers_fullscreen = false,
        is_borderless = false,
        is_popout = true,
        show_parent = container,
    }
    -- Not close_callback: Menu calls it after every item tap too, which would
    -- close the list under the profile. X and a tap outside both end up here.
    function menu:onCloseAllMenus()
        UIManager:close(container)
        return true
    end
    container[1] = menu
    UIManager:show(container)
    Context.remember(ctx, container)
    return menu, container
end

--- Windows opened on the way (recap, lexicon, lists), closed together on a jump.
function Context.remember(ctx, widget)
    ctx.windows = ctx.windows or {}
    table.insert(ctx.windows, widget)
end

function Context.closeAll(ctx)
    for i = #(ctx.windows or {}), 1, -1 do UIManager:close(ctx.windows[i]) end
    ctx.windows = {}
end

local CATEGORIES = {
    { types = { character = true }, label = "Characters", always = true },
    { types = { place = true }, label = "Places", always = true },
    { types = { object = true }, label = "Objects" },
    { types = { group = true }, label = "Groups" },
    { types = { creature = true }, label = "Creatures" },
    { types = { term = true }, label = "Other", always = true },
}
-- A category with fewer entries goes under "Other", so a book without many
-- objects, groups or creatures (a romance with one dog) gets no tiny category.
local MIN_CATEGORY = 3

local function byName(a, b)
    return require("ffi/util").strcoll(a.name, b.name)
end

local function lower(text)
    local ok, utf8proc = pcall(require, "ffi/utf8proc")
    if ok and utf8proc.lowercase then return utf8proc.lowercase(text) end
    return text:lower()
end

--- Profiles whose name or another name contains the text (case does not matter).
function Context.search(profiles, query)
    local needle = lower(util.cleanupSelectedText(query or ""))
    local matches = {}
    if needle == "" then return matches end
    for _i, profile in ipairs(profiles) do
        local hit = lower(profile.name):find(needle, 1, true)
        for _j, alias in ipairs(profile.aliases) do
            hit = hit or lower(alias):find(needle, 1, true)
        end
        if hit then table.insert(matches, profile) end
    end
    table.sort(matches, byName)
    return matches
end

--- "Search…" in the lexicon: type a name, see what is known about it.
-- When nothing is found and ctx.ask_ai is set, offer to ask the AI.
function Context.askSearch(ctx, profiles)
    local dialog
    dialog = InputDialog:new{
        title = _("Search the lexicon"),
        input_hint = _("Name or part of it"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Search"), is_enter_default = true, callback = function()
                local query = util.cleanupSelectedText(dialog:getInputText() or "")
                UIManager:close(dialog)
                if query == "" then return end
                local matches = Context.search(profiles, query)
                if #matches == 1 then
                    ctx.profile = matches[1]
                    Context.show(ctx)
                elseif #matches > 1 then
                    Context.choose(ctx, matches, T(_("Search: %1"), query))
                else
                    Context.notFound(ctx, query)
                end
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

--- Nothing known about a name: say so, and offer to ask the AI if possible.
function Context.notFound(ctx, query)
    local text = T(_("No story notes about \"%1\" up to where you have read."), query)
    if not ctx.ask_ai then
        UIManager:show(InfoMessage:new{ text = text })
        return
    end
    UIManager:show(ConfirmBox:new{
        text = text .. "\n\n" .. _("The AI can look it up in the chapters you have read (one request). Nothing after your reading position is sent."),
        ok_text = _("Ask the AI"),
        ok_callback = function() ctx.ask_ai(query) end,
    })
end

-- Lexicon order: alphabetical, by how many chapters an entry appears in, or by last appearance.
local SORTS = { "name", "count", "recent" }
local SORT_LABELS = { name = "A–Z", count = "frequency", recent = "recent" } -- translated when shown

-- Number of chapters with a note about this entry.
local function chapterCount(profile)
    return profile.chapter_count or 0
end

local SORTERS = {
    name = byName,
    count = function(a, b)
        local ca, cb = chapterCount(a), chapterCount(b)
        if ca ~= cb then return ca > cb end
        return byName(a, b)
    end,
    recent = function(a, b)
        -- last_order counts across the volumes of a series (last_index restarts in every volume)
        local la, lb = a.last_order or a.last_index or 0, b.last_order or b.last_index or 0
        if la ~= lb then return la > lb end
        return byName(a, b)
    end,
}

--- The story lexicon: pick a category, then browse it in the chosen order.
-- ctx.lexicon_sort: "name", "count" or "recent"; ctx.set_lexicon_sort saves a new choice.
function Context.browse(ctx, profiles)
    local dialog
    local sort = SORTERS[ctx.lexicon_sort] and ctx.lexicon_sort or "name"
    local rows = {{
        {
            text = _("Search…"),
            callback = function()
                UIManager:close(dialog)
                Context.askSearch(ctx, profiles)
            end,
        },
        {
            text = T(_("Order: %1"), _(SORT_LABELS[sort])),
            callback = function()
                local next_sort = SORTS[1]
                for i, s in ipairs(SORTS) do
                    if s == sort then next_sort = SORTS[i % #SORTS + 1] end
                end
                ctx.lexicon_sort = next_sort
                if ctx.set_lexicon_sort then ctx.set_lexicon_sort(next_sort) end
                UIManager:close(dialog)
                Context.browse(ctx, profiles)
            end,
        },
    }}
    local function open(label, list, mixed)
        table.sort(list, SORTERS[sort])
        Context.choose(ctx, list, T("%1 (%2)", label, #list), not mixed)
    end
    local lists, small = {}, {}
    for i, category in ipairs(CATEGORIES) do
        local list = {}
        for _j, profile in ipairs(profiles) do
            if category.types[profile.type] then table.insert(list, profile) end
        end
        if not category.always and #list < MIN_CATEGORY then
            for _j, profile in ipairs(list) do table.insert(small, profile) end
            list = {}
        end
        lists[i] = list
    end
    local other = lists[#CATEGORIES]
    for _j, profile in ipairs(small) do table.insert(other, profile) end
    for i, category in ipairs(CATEGORIES) do
        local list = lists[i]
        if #list > 0 then
            local label = _(category.label)
            -- "Other" with entries from small categories: show each entry's type.
            local mixed = i == #CATEGORIES and #small > 0
            table.insert(rows, {{
                text = T("%1 (%2)", label, #list),
                callback = function() open(label, list, mixed) end,
            }})
        end
    end
    local all = {}
    for _i, profile in ipairs(profiles) do table.insert(all, profile) end
    table.insert(rows, {{
        text = T("%1 (%2)", _("All"), #all),
        callback = function() open(_("All"), all, true) end,
    }})
    table.insert(rows, {{
        text = _("Close"),
        callback = function() UIManager:close(dialog) end,
    }})
    dialog = ButtonDialog:new{
        title = _("Story lexicon"),
        title_align = "center",
        buttons = rows,
    }
    UIManager:show(dialog)
    Context.remember(ctx, dialog)
    return dialog
end

return Context
