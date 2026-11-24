--[[--
Chapter detection on top of KOReader's table of contents.

A chapter is a TOC entry. Levels the reader has hidden from the progress bar
("chapter ticks") are skipped, so the chapter granularity follows the reader's
own TOC settings. Books without a TOC are treated as one single chapter.
--]]

local _ = require("storyrecall/i18n")

local Chapters = {}

local WHOLE_BOOK_KEY = "book"

local function chapterFromToc(ui, index)
    local item = ui.toc.toc[index]
    if not item then return end
    return {
        index = index,
        -- The xpointer survives font and layout changes, page numbers don't.
        key = item.xpointer or ("page:" .. tostring(item.page)),
        title = item.title,
        page = item.page,
        depth = item.depth,
    }
end

function Chapters.hasToc(ui)
    ui.toc:fillToc()
    return ui.toc.toc and #ui.toc.toc > 0
end

--- The chapter containing the given page.
function Chapters.atPage(ui, pageno, book_title)
    if Chapters.hasToc(ui) then
        local index = ui.toc:getTocIndexByPage(pageno, true)
        if index then
            return chapterFromToc(ui, index)
        end
        -- Before the first TOC entry (cover, front matter): chapter 0.
        return Chapters.front()
    end
    return { index = 0, key = WHOLE_BOOK_KEY, title = book_title, page = 1 }
end

local function ignored(ui, index)
    local item = ui.toc.toc[index]
    return item and ui.toc.toc_ticks_ignored_levels[item.depth]
end

--- The chapter before the first TOC entry (cover, front matter).
function Chapters.front()
    return { index = 0, key = "front", title = _("Before the first chapter"), page = 1 }
end

--- The next chapter after `index`, skipping TOC levels the reader has hidden.
function Chapters.next(ui, index)
    if not Chapters.hasToc(ui) then return end
    for i = (index or 0) + 1, #ui.toc.toc do
        if not ignored(ui, i) then return chapterFromToc(ui, i) end
    end
end

--- The chapter before `index`, skipping hidden TOC levels (nil before the first).
function Chapters.prev(ui, index)
    if not Chapters.hasToc(ui) then return end
    for i = math.min((index or 0) - 1, #ui.toc.toc), 1, -1 do
        if not ignored(ui, i) then return chapterFromToc(ui, i) end
    end
end

--- Index of the visible chapter containing an xpointer (0 before the first).
function Chapters.indexForXPointer(ui, xpointer)
    if not (Chapters.hasToc(ui) and type(xpointer) == "string" and xpointer:find("^/")) then return end
    local doc = ui.document
    local found = 0
    for i, item in ipairs(ui.toc.toc) do
        if not ignored(ui, i) and item.xpointer then
            if item.xpointer == xpointer then return i end
            local order = doc.compareXPointers and doc:compareXPointers(item.xpointer, xpointer)
            if order == nil then return end
            if order >= 0 then found = i else break end
        end
    end
    return found
end

--- A short fingerprint of the TOC, to notice when it changes.
function Chapters.signature(ui)
    if not Chapters.hasToc(ui) then return "none" end
    local toc = ui.toc.toc
    return table.concat({ #toc, toc[1].xpointer or "", toc[#toc].xpointer or "" }, "|")
end

function Chapters.byIndex(ui, index)
    if index and index > 0 and Chapters.hasToc(ui) then
        return chapterFromToc(ui, index)
    end
end

--- All chapters from the first one up to (and including) the given index.
function Chapters.upTo(ui, max_index)
    local result = {}
    if not Chapters.hasToc(ui) then return result end
    for index = 1, math.min(max_index, #ui.toc.toc) do
        if not ignored(ui, index) then
            local chapter = chapterFromToc(ui, index)
            chapter.seq = #result + 1 -- position among the visible chapters
            table.insert(result, chapter)
        end
    end
    return result
end

function Chapters.count(ui)
    if not Chapters.hasToc(ui) then return 1 end
    local count = 0
    for _, item in ipairs(ui.toc.toc) do
        if not ui.toc.toc_ticks_ignored_levels[item.depth] then
            count = count + 1
        end
    end
    return count
end

return Chapters
