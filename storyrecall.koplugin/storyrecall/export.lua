--[[--
Export the story notes of a book as a Markdown file next to the book:
the story so far, the chronicle and the characters, all only up to the
furthest chapter read.
--]]

local util = require("util")
local _ = require("storyrecall/i18n")
local T = require("ffi/util").template

local Export = {}

local function heading(level, text)
    return string.rep("#", level) .. " " .. text
end

--- The Markdown text.
-- @param ctx context from the plugin (store, book, chapters, read_chapter)
function Export.markdown(ctx)
    local store, max_index = ctx.store, ctx.read_chapter.index
    local lines = { heading(1, (ctx.book.title or "?") .. " – Story Recall") }
    if ctx.book.authors then table.insert(lines, ctx.book.authors) end
    table.insert(lines, "")
    local read_title = ctx.read_chapter.title or ""
    table.insert(lines, T(_("Read up to: %1"), max_index > 0 and (max_index .. " · " .. read_title) or read_title))
    table.insert(lines, os.date("%Y-%m-%d"))

    -- AI notes only for finished chapters (they describe a chapter up to its end).
    local ai_index = ctx.ai_index or max_index
    local notes = store:getChapterNotes(ai_index)
    local last = notes[#notes]
    if last and last.story_so_far then
        table.insert(lines, "")
        table.insert(lines, heading(2, _("The story so far")))
        table.insert(lines, "")
        table.insert(lines, last.story_so_far)
    end

    local summary_by_key, own_by_key = {}, {}
    for _i, note in ipairs(notes) do summary_by_key[note.key] = note.summary end
    for _i, note in ipairs(store:getNotes(max_index)) do
        own_by_key[note.chapter_key] = own_by_key[note.chapter_key] or {}
        table.insert(own_by_key[note.chapter_key], note.text)
    end
    table.insert(lines, "")
    table.insert(lines, heading(2, _("Story chronicle")))
    for _i, chapter in ipairs(ctx.chapters) do
        table.insert(lines, "")
        local label = chapter.index > 0 and (chapter.index .. " · " .. (chapter.title or "")) or (chapter.title or "")
        table.insert(lines, heading(3, label))
        if summary_by_key[chapter.key] then
            table.insert(lines, "")
            table.insert(lines, summary_by_key[chapter.key])
        end
        for _j, text in ipairs(own_by_key[chapter.key] or {}) do
            table.insert(lines, "")
            table.insert(lines, "> " .. text:gsub("\n", "\n> "))
        end
    end

    local profiles = store:getEntityProfiles(ai_index)
    if #profiles > 0 then
        local order = { character = 1, place = 2, group = 3, object = 4, term = 5 }
        table.sort(profiles, function(a, b)
            local oa, ob = order[a.type] or 9, order[b.type] or 9
            if oa ~= ob then return oa < ob end
            return a.name:lower() < b.name:lower()
        end)
        table.insert(lines, "")
        table.insert(lines, heading(2, _("Story lexicon")))
        for _i, profile in ipairs(profiles) do
            table.insert(lines, "")
            local name = "**" .. profile.name .. "**"
            if #profile.aliases > 0 then name = name .. " (" .. table.concat(profile.aliases, ", ") .. ")" end
            if profile.relation then name = name .. " – " .. profile.relation end
            table.insert(lines, name)
            for _j, fact in ipairs(profile.facts) do
                table.insert(lines, string.format("- [%d] %s", fact.index, fact.text))
            end
        end
    end
    table.insert(lines, "")
    return table.concat(lines, "\n")
end

--- Write the file next to the book.
-- @return path, or nil + error
function Export.write(ctx, book_file)
    local dir, name = book_file:match("^(.*)/([^/]+)$")
    if not dir then return nil, "no folder" end
    local base = name:gsub("%.[^.]+$", "")
    local path = dir .. "/" .. util.getSafeFilename(base .. " - Story Recall.md", dir)
    local file, err = io.open(path, "w")
    if not file then return nil, err end
    file:write(Export.markdown(ctx))
    file:close()
    return path
end

return Export
