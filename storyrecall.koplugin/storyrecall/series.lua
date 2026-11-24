--[[--
Series recap: what happened in the earlier volumes of the series.

Earlier volumes come from two places:
  * books on the device with Story Recall data (KOReader's history and the
    same folder), matched by series name and a lower volume number;
  * the series archive, a file in KOReader's settings folder where every
    volume's summary is kept as well, so a volume stays available after its
    book was deleted, and where summaries from the internet are stored.

Each volume contributes its "story so far" at the furthest chapter read
there, so a volume that was not finished does not spoil its own ending.
Translations often name a series differently; such a series can be linked
once (same author, lower volume number) and is found from then on.
--]]

local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local Series = {}

local FILENAME = "story_recall.lua"

local function normalize(name)
    return type(name) == "string" and name:lower():gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "") or nil
end
Series.normalize = normalize

-- First author only, lowercased ("Anna Berg\nOther" -> "anna berg").
local function normalizeAuthor(authors)
    if type(authors) ~= "string" then return nil end
    return normalize(authors:match("^[^\n,;&]+"))
end

local function archivePath()
    return DataStorage:getSettingsDir() .. "/story_recall_series.lua"
end

local function openArchive()
    local settings = LuaSettings:open(archivePath())
    settings.data.series = settings.data.series or {}
    settings.data.links = settings.data.links or {}
    return settings
end
Series.archivePath = archivePath

local function candidateFiles(current_file)
    local files, seen = {}, { [current_file] = true }
    local isComic = require("storyrecall/comic").isComic
    local function add(file)
        if file and not seen[file] and not isComic(file) then
            seen[file] = true
            table.insert(files, file)
        end
    end
    local ok, ReadHistory = pcall(require, "readhistory")
    if ok and ReadHistory and ReadHistory.hist then
        for _, item in ipairs(ReadHistory.hist) do add(item.file) end
    end
    -- Books in the same folder, but only those that already have a sidecar
    -- folder next to them (cheap check, no hashing), and at most a few thousand.
    local dir = current_file and current_file:match("^(.*)/[^/]+$")
    if dir and lfs.attributes(dir, "mode") == "directory" then
        local checked = 0
        for entry in lfs.dir(dir) do
            checked = checked + 1
            if checked > 3000 then break end
            local base = entry:match("^(.+)%.[^.]+$")
            if base and entry:sub(1, 1) ~= "." and not entry:match("%.sdr$")
                    and lfs.attributes(dir .. "/" .. base .. ".sdr", "mode") == "directory" then
                add(dir .. "/" .. entry)
            end
        end
    end
    return files
end
Series.candidateFiles = candidateFiles

--- KOReader's book status "finished" (marked by the reader, or set at the end of the book).
-- Such a volume counts as read in full, even if it was read elsewhere (paper, audiobook).
local function markedFinished(file)
    local ok, finished = pcall(function()
        local summary = DocSettings:open(file):readSetting("summary")
        return type(summary) == "table" and summary.status == "complete"
    end)
    return ok and finished == true
end
Series.markedFinished = markedFinished

--- The data, seen as a volume read in full (for noteVisible), without changing it.
function Series.asFinished(data)
    return setmetatable({ marked_finished = true }, { __index = data })
end

local function storedData(file)
    if lfs.attributes(file, "mode") ~= "file" then return end
    local path = DocSettings:getSidecarDir(file) .. "/" .. FILENAME
    if lfs.attributes(path, "mode") ~= "file" then return end
    local ok, settings = pcall(LuaSettings.open, LuaSettings, path)
    local data = ok and settings and settings.data or nil
    if data and markedFinished(file) then data = Series.asFinished(data) end
    return data
end
Series.storedData = storedData

--- May this AI note be shown? Notes describe a chapter up to its end, so
-- only chapters before the furthest one, or the furthest one once finished.
function Series.noteVisible(data, note)
    if data.marked_finished then return true end
    local furthest = data.furthest_chapter
    if not furthest then return true end
    if note.index < furthest then return true end
    local entry = data.chapters and data.chapters[note.key]
    return note.index == furthest and entry ~= nil and entry.completed_at ~= nil
end

--- The volume's story so far at the furthest chapter read there.
function Series.volumeSummary(data)
    local notes = {}
    local last_index = 0
    for _, note in pairs(data.ai_chapters or {}) do
        table.insert(notes, note)
        last_index = math.max(last_index, note.index or 0)
    end
    if #notes == 0 then return end
    table.sort(notes, function(a, b) return a.index < b.index end)
    local chosen
    for _, note in ipairs(notes) do
        if Series.noteVisible(data, note) and note.story_so_far then chosen = note end
    end
    if not chosen then return end
    -- A finished volume has its own, longer summary written for the next volume.
    -- Only if it belongs to the book's last chapter: older answers sometimes
    -- carried one on chapters in the middle of the book.
    local last = notes[#notes]
    local book_finished = Series.noteVisible(data, last) and last.index >= (data.last_chapter_index or last.index)
    -- Best: the volume summary from its own request (Story Recall → volume summary).
    local own = data.volume_summary
    if book_finished and type(own) == "table" and own.text then
        return {
            text = own.text,
            chapter_index = last.index,
            chapter_title = last.title,
            finished = true,
        }
    end
    if book_finished and last.volume_summary then
        return {
            text = last.volume_summary,
            chapter_index = last.index,
            chapter_title = last.title,
            finished = true,
        }
    end
    return {
        text = chosen.story_so_far,
        chapter_index = chosen.index,
        chapter_title = chosen.title,
        finished = chosen.index >= (data.last_chapter_index or last_index),
        story_so_far = true, -- plot in one or more paragraphs, then "Zuletzt"
    }
end

--- The volume's lexicon material: the entities of every chapter note that may
-- be shown (up to the furthest chapter read), oldest first. The series lexicon
-- replays them before the current volume's notes, as if it were one long book.
-- @return list of { index, title, entities = { {name, type, aliases, facts, relation, status} } }
function Series.volumeLexicon(data)
    local notes = {}
    for _, note in pairs(data and data.ai_chapters or {}) do
        if type(note) == "table" and note.index and Series.noteVisible(data, note)
                and type(note.entities) == "table" and #note.entities > 0 then
            local entities = {}
            for _, e in ipairs(note.entities) do
                if type(e) == "table" and type(e.name) == "string" and e.name ~= "" then
                    table.insert(entities, { name = e.name, type = e.type, aliases = e.aliases, facts = e.facts,
                        relation = e.relation, status = e.status })
                end
            end
            if #entities > 0 then
                table.insert(notes, { index = note.index, title = note.title, entities = entities })
            end
        end
    end
    table.sort(notes, function(a, b) return a.index < b.index end)
    return notes
end

-- Series keys that count as the same series as `key` (itself and linked ones).
local function sameSeriesKeys(links, key)
    local keys = { [key] = true }
    if links[key] then keys[links[key]] = true end
    for from, to in pairs(links) do
        if to == key then keys[from] = true end
    end
    return keys
end

--- Keep a volume's summary in the archive (called whenever its notes change).
-- @param book { title, authors, series, series_index, language }
-- @param data the book's Story Recall data
-- @return true if the archive changed
function Series.archive(book, data)
    local key, index = normalize(book.series), tonumber(book.series_index)
    if not key or not index then return false end
    local summary = Series.volumeSummary(data)
    if not summary then return false end
    local ok, archive = pcall(openArchive)
    if not ok then logger.warn("StoryRecall: series archive:", archive) return false end
    local series = archive.data.series[key] or { name = book.series, volumes = {} }
    archive.data.series[key] = series
    local id = tostring(index)
    local old = series.volumes[id]
    -- The lexicon goes along, so later volumes can continue its entries after this book is gone.
    local lexicon = Series.volumeLexicon(data)
    local lexicon_last = lexicon[#lexicon] and lexicon[#lexicon].index or 0
    if old and old.source == "book" and old.text == summary.text and old.finished == summary.finished
            and old.lexicon_count == #lexicon and old.lexicon_last == lexicon_last then
        return false
    end
    series.volumes[id] = {
        title = book.title, authors = book.authors, language = book.language,
        text = summary.text, chapter_index = summary.chapter_index, chapter_title = summary.chapter_title,
        finished = summary.finished, source = "book", updated = os.time(),
        lexicon = lexicon, lexicon_count = #lexicon, lexicon_last = lexicon_last,
    }
    archive:flush()
    return true
end

--- Store a summary that did not come from the book itself (e.g. the internet).
function Series.archiveExternal(book, series_index, entry)
    local key = normalize(book.series)
    if not key then return false end
    local archive = openArchive()
    local series = archive.data.series[key] or { name = book.series, volumes = {} }
    archive.data.series[key] = series
    local id = tostring(series_index)
    -- Never replace a summary made from the book text.
    if series.volumes[id] and series.volumes[id].source == "book" then return false end
    entry.updated = os.time()
    series.volumes[id] = entry
    archive:flush()
    return true
end

--- Earlier volumes of the current book's series, oldest first.
-- @param file current book
-- @param book { series, series_index }
-- @return list of { title, series_index, source = "book"|"archive"|"internet",
--          summary = {text, chapter_index, chapter_title, finished}, sources }
function Series.previousVolumes(file, book)
    local key, index = normalize(book.series), tonumber(book.series_index)
    if not key or not index or index <= 1 then return {} end
    local archive_ok, archive = pcall(openArchive)
    local links = archive_ok and archive.data.links or {}
    local keys = sameSeriesKeys(links, key)
    local volumes, by_index = {}, {}
    for _, candidate in ipairs(candidateFiles(file)) do
        local data = storedData(candidate)
        local info = data and data.book
        local volume_index = info and tonumber(info.series_index)
        local volume_key = info and normalize(info.series)
        if volume_key and keys[volume_key] and volume_index and volume_index < index
                and not by_index[volume_index] then
            local summary = Series.volumeSummary(data)
            if summary then
                by_index[volume_index] = true
                table.insert(volumes, { title = info.title, series_index = volume_index, summary = summary,
                    file = candidate, source = "book" })
            end
        end
    end
    -- Volumes no longer (or never) on the device.
    if archive_ok then
        for series_key in pairs(keys) do
            local series = archive.data.series[series_key]
            for id, entry in pairs(series and series.volumes or {}) do
                local volume_index = tonumber(id)
                if volume_index and volume_index < index and not by_index[volume_index] and entry.text then
                    by_index[volume_index] = true
                    table.insert(volumes, {
                        title = entry.title, series_index = volume_index,
                        source = entry.source == "internet" and "internet" or "archive",
                        sources = entry.sources,
                        summary = { text = entry.text, chapter_index = entry.chapter_index,
                            chapter_title = entry.chapter_title, finished = entry.finished },
                    })
                end
            end
        end
    end
    table.sort(volumes, function(a, b) return a.series_index < b.series_index end)
    logger.dbg("StoryRecall: found", #volumes, "earlier volumes of", book.series)
    return volumes
end

--- Lexicon material of the earlier volumes of the current book's series, oldest
-- first: from the books on the device, otherwise from the series archive.
-- Only what was read there (see Series.volumeLexicon), so nothing is spoiled.
-- @return list of { series_index, title, notes = Series.volumeLexicon(...) }
function Series.previousLexicons(file, book)
    local key, index = normalize(book and book.series), tonumber(book and book.series_index)
    if not key or not index or index <= 1 then return {} end
    local archive_ok, archive = pcall(openArchive)
    local keys = sameSeriesKeys(archive_ok and archive.data.links or {}, key)
    local volumes, by_index = {}, {}
    for _, candidate in ipairs(candidateFiles(file)) do
        local data = storedData(candidate)
        local info = data and data.book
        local volume_index = info and tonumber(info.series_index)
        local volume_key = info and normalize(info.series)
        if volume_key and keys[volume_key] and volume_index and volume_index < index
                and not by_index[volume_index] then
            local notes = Series.volumeLexicon(data)
            if #notes > 0 then
                by_index[volume_index] = true
                table.insert(volumes, { series_index = volume_index, title = info.title, notes = notes })
            end
        end
    end
    if archive_ok then
        for series_key in pairs(keys) do
            local series = archive.data.series[series_key]
            for id, entry in pairs(series and series.volumes or {}) do
                local volume_index = tonumber(id)
                if volume_index and volume_index < index and not by_index[volume_index]
                        and type(entry.lexicon) == "table" and #entry.lexicon > 0 then
                    by_index[volume_index] = true
                    table.insert(volumes, { series_index = volume_index, title = entry.title, notes = entry.lexicon })
                end
            end
        end
    end
    table.sort(volumes, function(a, b) return a.series_index < b.series_index end)
    return volumes
end

--- Series by the same author with earlier volumes but another name (e.g. the
-- original of a translation), for linking.
-- @return list of { key, name, title, series_index, language }
function Series.otherNamedCandidates(file, book)
    local key, index, author = normalize(book.series), tonumber(book.series_index), normalizeAuthor(book.authors)
    if not key or not index or index <= 1 or not author then return {} end
    local found, result = {}, {}
    local function consider(info)
        local other_key = info and normalize(info.series)
        local other_index = info and tonumber(info.series_index)
        if other_key and other_key ~= key and other_index and other_index < index
                and normalizeAuthor(info.authors) == author and not found[other_key] then
            found[other_key] = true
            table.insert(result, { key = other_key, name = info.series, title = info.title, series_index = other_index,
                language = info.language })
        end
    end
    for _, candidate in ipairs(candidateFiles(file)) do
        local data = storedData(candidate)
        if data and Series.volumeSummary(data) then consider(data.book) end
    end
    local ok, archive = pcall(openArchive)
    if ok then
        for other_key, series in pairs(archive.data.series) do
            for id, entry in pairs(series.volumes or {}) do
                consider({ series = series.name or other_key, series_index = id, authors = entry.authors, title = entry.title,
                    language = entry.language })
            end
        end
    end
    return result
end

--- Treat another series name as the same series from now on.
function Series.link(book, other_key)
    local key = normalize(book.series)
    if not key or not other_key or key == other_key then return false end
    local archive = openArchive()
    archive.data.links[key] = other_key
    archive:flush()
    return true
end

return Series
