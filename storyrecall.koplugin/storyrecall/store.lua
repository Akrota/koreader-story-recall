--[[--
Per-book storage for Story Recall.

Everything lives in one file next to KOReader's own book metadata, inside the
book's sidecar folder (`book.sdr/story_recall.lua`), so it travels with the book.

Notes are append-only: a note is only changed or removed when the reader edits
it. Generated content added in later stages follows the same rule.
--]]

local DocSettings = require("docsettings")
local LuaSettings = require("luasettings")
local lfs = require("libs/libkoreader-lfs")
local util = require("util")

local FILENAME = "story_recall.lua"
local DATA_VERSION = 1

local Store = {}
Store.__index = Store

function Store.open(doc_path)
    local dir = DocSettings:getSidecarDir(doc_path)
    local self = setmetatable({
        dir = dir,
        path = dir .. "/" .. FILENAME,
        dirty = false,
    }, Store)
    self.settings = LuaSettings:open(self.path)
    local data = self.settings.data
    data.version = data.version or DATA_VERSION
    data.chapters = data.chapters or {} -- chapter key -> { title, index, completed_at }
    data.notes = data.notes or {}       -- list of { id, chapter_key, chapter_index, chapter_title, text, source, created, updated }
    data.next_note_id = data.next_note_id or 1
    self.data = data
    self:dropPlaceholderNotes()
    return self
end

-- A real chapter summary is never this short. Claude sometimes answered with a
-- placeholder ("x") instead of the summary (24.10.2026).
Store.MIN_SUMMARY_CHARS = 20

--- Remove AI chapter notes whose summary is only a placeholder, so they are
-- processed again, and cut leftovers of the answer format off the texts.
-- @return number removed
function Store:dropPlaceholderNotes()
    local removed = 0
    for key, note in pairs(self.data.ai_chapters or {}) do
        -- Leftovers of the answer format at the end ("… ist offen.}, {", Claude 24.10.2026)
        for _i, field in ipairs({ "summary", "story_so_far", "volume_summary" }) do
            local text = note[field]
            local tail = type(text) == "string" and text:match("[%s,\"%[%]{}]+$")
            if tail and tail:find("[%[%]{}]") then
                note[field] = text:sub(1, #text - #tail)
                self:markDirty()
            end
        end
        local summary = type(note.summary) == "string" and note.summary:gsub("^%s+", ""):gsub("%s+$", "") or ""
        if #summary < Store.MIN_SUMMARY_CHARS then
            self.data.ai_chapters[key] = nil
            removed = removed + 1
        end
    end
    if removed > 0 then self:markDirty() end
    return removed
end

function Store:markDirty()
    self.dirty = true
end

function Store:save()
    if not self.dirty then return end
    if lfs.attributes(self.dir, "mode") ~= "directory" then
        util.makePath(self.dir)
    end
    self.settings:flush()
    self.dirty = false
end

-- Book info

function Store:setBookInfo(info)
    local old = self.data.book or {}
    local changed = false
    for k, v in pairs(info) do
        if old[k] ~= v then changed = true end
    end
    -- A removed field (e.g. series deleted in the book information) counts too.
    for k in pairs(old) do
        if info[k] == nil then changed = true end
    end
    if changed then
        self.data.book = info
        self:markDirty()
    end
end

-- Time of the last reading session

function Store:getLastSeen()
    return self.data.last_seen
end

function Store:setLastSeen(ts)
    self.data.last_seen = ts
    self:markDirty()
end

-- Furthest chapter reached by reading on (jumps don't count).
-- Chronicle and recap never show anything beyond it.

function Store:getFurthestChapter()
    return self.data.furthest_chapter
end

-- @param key the chapter's xpointer: TOC positions can change (alternative
--        TOC), the xpointer stays, so the index can be found again
function Store:setFurthestChapter(index, key)
    if self.data.furthest_chapter and self.data.furthest_chapter >= index then return end
    self.data.furthest_chapter = index
    self.data.furthest_key = key
    self:markDirty()
end

--- Undo the last reading progress (used when it came from a re-layout).
function Store:restoreProgress(furthest, furthest_key, completed_keys)
    self.data.furthest_chapter = furthest
    self.data.furthest_key = furthest_key
    for _, key in ipairs(completed_keys or {}) do self.data.chapters[key] = nil end
    self:markDirty()
end

--- The TOC changed (e.g. KOReader's alternative TOC): find every chapter
-- again by its xpointer and renumber notes, chapters and the reading point.
-- @param indexOf function(key) -> current chapter index, or nil
function Store:renumber(indexOf)
    local function fix(entry, key_field, index_field)
        local index = entry[key_field] and indexOf(entry[key_field])
        if index then entry[index_field] = index end
    end
    for _, note in pairs(self.data.ai_chapters or {}) do fix(note, "key", "index") end
    for key, entry in pairs(self.data.chapters) do
        local index = indexOf(key)
        if index then entry.index = index end
    end
    for _, note in ipairs(self.data.notes) do fix(note, "chapter_key", "chapter_index") end
    if self.data.furthest_key then
        local index = indexOf(self.data.furthest_key)
        if index then self.data.furthest_chapter = index end
    end
    self:markDirty()
end

-- Chapters

function Store:getChapter(key)
    return self.data.chapters[key]
end

function Store:markChapterCompleted(chapter)
    local entry = self.data.chapters[chapter.key]
    if entry and entry.completed_at then return false end
    self.data.chapters[chapter.key] = {
        title = chapter.title,
        index = chapter.index,
        completed_at = os.time(),
    }
    self:markDirty()
    return true
end

function Store:countCompletedChapters()
    local count = 0
    for _, entry in pairs(self.data.chapters) do
        if entry.completed_at then count = count + 1 end
    end
    return count
end

-- AI chapter notes: one entry per chapter, written once and never overwritten
-- by the AI. Descriptions of characters etc. are assembled from all entries.

function Store:getChapterNote(key)
    return self.data.ai_chapters and self.data.ai_chapters[key]
end

function Store:addChapterNote(chapter, note)
    self.data.ai_chapters = self.data.ai_chapters or {}
    if self.data.ai_chapters[chapter.key] then return false end
    note.key = chapter.key
    note.index = chapter.index
    note.title = chapter.title
    note.created = note.created or os.time()
    self.data.ai_chapters[chapter.key] = note
    self:markDirty()
    return true
end

--- AI chapter notes up to (and including) a chapter index, in reading order.
function Store:getChapterNotes(max_index)
    local result = {}
    for _key, note in pairs(self.data.ai_chapters or {}) do
        if not max_index or note.index <= max_index then
            table.insert(result, note)
        end
    end
    table.sort(result, function(a, b) return a.index < b.index end)
    return result
end

-- Chapters the AI could not process (declined or failed repeatedly).
function Store:getChapterFailure(key)
    return self.data.ai_failures and self.data.ai_failures[key]
end

function Store:setChapterFailure(chapter, reason)
    self.data.ai_failures = self.data.ai_failures or {}
    self.data.ai_failures[chapter.key] = { index = chapter.index, reason = tostring(reason), at = os.time() }
    self:markDirty()
end

function Store:clearChapterFailures()
    self.data.ai_failures = nil
    self:markDirty()
end

--- Remove all AI notes of this book (only on the reader's explicit request,
-- e.g. to create them again with a better model). Own notes stay.
--- Remember what the AI said about a looked-up name (kept when the notes are re-created).
-- @param entry { name, type, facts, relation, index, title, model }
function Store:addLookup(entry)
    self.data.lookups = self.data.lookups or {}
    local key = Store.normalizeName(entry.name)
    for i, old in ipairs(self.data.lookups) do
        if Store.normalizeName(old.name) == key then table.remove(self.data.lookups, i) break end
    end
    entry.created = os.time()
    table.insert(self.data.lookups, entry)
    self:markDirty()
end

function Store:clearChapterNotes()
    self.data.ai_chapters = nil
    self.data.ai_failures = nil
    self.data.volume_summary = nil -- belongs to the old notes
    self:markDirty()
end

-- Earlier AI notes of this book, up to two sets per provider
-- (data.ai_sets[provider] = list, newest first), so switching back to a
-- provider or undoing "re-create all" costs no new requests. A set holds the
-- chapter notes and the volume summary; own notes, reading position and "ask
-- the AI" answers are not part of it.
Store.MAX_SETS_PER_PROVIDER = 2

--- Provider and model most of the current AI notes come from, and how many there are.
function Store:currentSetInfo()
    local by_provider, models, count = {}, {}, 0
    for _key, note in pairs(self.data.ai_chapters or {}) do
        count = count + 1
        local provider = note.provider or "unknown"
        by_provider[provider] = (by_provider[provider] or 0) + 1
        models[provider] = models[provider] or {}
        if note.model then models[provider][note.model] = (models[provider][note.model] or 0) + 1 end
    end
    local best, best_n = nil, 0
    for provider, n in pairs(by_provider) do
        if n > best_n or (n == best_n and provider < best) then best, best_n = provider, n end
    end
    local model, model_n = nil, 0
    for name, n in pairs(best and models[best] or {}) do
        if n > model_n or (n == model_n and name < model) then model, model_n = name, n end
    end
    return best, model, count
end

--- The saved sets of one provider, newest first. Data from before 25.10.2026
-- held a single set per provider: it becomes a list of one.
function Store:setsOf(provider)
    local sets = self.data.ai_sets
    if not sets then return nil end
    local list = sets[provider]
    if list and list.ai_chapters then
        list = { list }
        sets[provider] = list
    end
    for _i, set in ipairs(list or {}) do
        if not set.id then
            set.id = (self.data.ai_set_next_id or 1)
            self.data.ai_set_next_id = set.id + 1
        end
    end
    return list
end

--- The set that putting the current notes aside would push out (the oldest
-- of its provider, when that provider already has the maximum), or nil.
function Store:stashWouldDrop()
    local provider, _model, count = self:currentSetInfo()
    if count == 0 then return nil end
    local list = self:setsOf(provider)
    if list and #list >= Store.MAX_SETS_PER_PROVIDER then return list[#list] end
end

--- Put the current AI notes aside under their provider; the oldest set of
-- that provider goes when there are more than the maximum.
-- @return provider, or nil if there was nothing to keep
function Store:stashChapterNotes()
    local provider, model, count = self:currentSetInfo()
    if count == 0 then return nil end
    self.data.ai_sets = self.data.ai_sets or {}
    local list = self:setsOf(provider) or {}
    self.data.ai_sets[provider] = list
    local id = self.data.ai_set_next_id or 1
    self.data.ai_set_next_id = id + 1
    table.insert(list, 1, {
        id = id,
        ai_chapters = self.data.ai_chapters,
        volume_summary = self.data.volume_summary,
        provider = provider, model = model, count = count, saved = os.time(),
    })
    for i = #list, Store.MAX_SETS_PER_PROVIDER + 1, -1 do list[i] = nil end
    self:clearChapterNotes()
    return provider
end

--- Saved sets, newest first: { id, provider, model, count, saved }.
function Store:getSavedSets()
    local list = {}
    for provider in pairs(self.data.ai_sets or {}) do
        for _i, set in ipairs(self:setsOf(provider) or {}) do table.insert(list, set) end
    end
    table.sort(list, function(a, b)
        if (a.saved or 0) ~= (b.saved or 0) then return (a.saved or 0) > (b.saved or 0) end
        return (a.id or 0) > (b.id or 0)
    end)
    return list
end

--- Take a saved set out of the list. @return the set, or nil
local function takeSet(self, id)
    for provider in pairs(self.data.ai_sets or {}) do
        local list = self:setsOf(provider)
        for i, set in ipairs(list or {}) do
            if set.id == id then
                table.remove(list, i)
                if #list == 0 then self.data.ai_sets[provider] = nil end
                if next(self.data.ai_sets) == nil then self.data.ai_sets = nil end
                return set
            end
        end
    end
end

--- Use a saved set again. The current AI notes are put aside first (under
-- their own provider), so restoring twice swaps back. @return true if done
function Store:restoreChapterNotes(id)
    local set = takeSet(self, id)
    if not set then return false end
    self:stashChapterNotes()
    self.data.ai_chapters = set.ai_chapters
    self.data.volume_summary = set.volume_summary
    self.data.ai_failures = nil
    self:markDirty()
    return true
end

--- Delete one saved set. @return true if it existed
function Store:deleteSavedSet(id)
    if not takeSet(self, id) then return false end
    self:markDirty()
    return true
end

--- Delete all saved sets (frees space; the current notes stay).
function Store:deleteSavedSets()
    if not self.data.ai_sets then return false end
    self.data.ai_sets = nil
    self:markDirty()
    return true
end

--- The reader corrects an AI note (summary or story so far). The AI's
-- original text is kept, so the correction can always be undone.
function Store:editChapterNote(key, field, text)
    local note = self:getChapterNote(key)
    if not note then return false end
    note.original = note.original or {}
    if note.original[field] == nil then note.original[field] = note[field] or false end
    note[field] = text
    note.edited = os.time()
    self:markDirty()
    return true
end

function Store:restoreChapterNote(key, field)
    local note = self:getChapterNote(key)
    if not (note and note.original and note.original[field] ~= nil) then return false end
    note[field] = note.original[field] or nil
    note.original[field] = nil
    if next(note.original) == nil then
        note.original = nil
        note.edited = nil
    end
    self:markDirty()
    return true
end

function Store:countChapterNotes()
    local count = 0
    for _ in pairs(self.data.ai_chapters or {}) do count = count + 1 end
    return count
end

--- A name without rarity or level, for recognising the same entity:
-- "Feuerball (selten)" and "Grauer Wolf – Level 12"
-- become "feuerball" and "grauer wolf".
-- @return lowercased key, display name
function Store.normalizeName(name)
    local clean = name:gsub("%s*%b()", ""):gsub("%s*%b[]", "")
    local lower = clean:lower()
    -- "– Level 46", "Level 46", "Stufe 3", "Lvl 12" at the end
    for _, word in ipairs({ "level", "lvl", "stufe" }) do
        local pos = lower:find("[%s%-]*" .. word .. "%s*%d+%s*$")
        if pos then
            clean = clean:sub(1, pos - 1)
            lower = lower:sub(1, pos - 1)
        end
    end
    -- Trailing dashes (also the typographic ones, several bytes each) and spaces.
    local changed = true
    while changed do
        local before = clean
        clean = clean:gsub("%s+$", ""):gsub("%-+$", ""):gsub("–$", ""):gsub("—$", ""):gsub(":$", "")
        changed = clean ~= before
    end
    clean = clean:gsub("^%s+", "")
    if clean == "" then clean = name end
    return clean:lower(), clean
end

--- A short form that is only part of the name ("Dungeon" for "Challenge-Dungeon").
-- It still finds the entity, but never merges two different names into one:
-- several places can share it.
function Store.isPartOfName(alias_key, name_key)
    return alias_key ~= name_key and name_key:find(alias_key, 1, true) ~= nil
end

--- Entities known up to a chapter: name, type, aliases (merged across chapters).
function Store:getKnownEntities(max_index)
    return Store.knownFromNotes(self:getChapterNotes(max_index))
end

--- Known entities from a list of chapter notes (oldest first), see getKnownEntities.
-- Also used for the notes of earlier volumes of a series.
function Store.knownFromNotes(notes)
    -- by_name maps every lowercased name and alias to its entity, so an AI
    -- answer that uses a nickname as the name still lands on the same entity.
    local by_name, list, partial = {}, {}, {}
    for _, note in ipairs(notes) do
        for _, entity in ipairs(note.entities or {}) do
            local known = by_name[entity.name:lower()]
            if not known then
                for _, alias in ipairs(entity.aliases or {}) do
                    if not partial[alias:lower()] then known = known or by_name[alias:lower()] end
                end
            end
            if not known then
                known = { name = entity.name, type = entity.type, aliases = {}, alias_set = {} }
                by_name[entity.name:lower()] = known
                table.insert(list, known)
            end
            -- Remember where it was last seen and the last thing learned about it.
            known.last_index = note.index
            known.volume = note.volume
            if entity.facts and #entity.facts > 0 then
                known.last_fact = entity.facts[#entity.facts]
                known.last_fact_index = note.index
            end
            local names = { entity.name }
            for _, alias in ipairs(entity.aliases or {}) do table.insert(names, alias) end
            for _, alias in ipairs(names) do
                local key = alias:lower()
                if key ~= known.name:lower() and not known.alias_set[key] then
                    known.alias_set[key] = true
                    table.insert(known.aliases, alias)
                end
                if not by_name[key] then
                    by_name[key] = known
                    partial[key] = Store.isPartOfName(key, known.name:lower())
                end
            end
        end
    end
    for _, known in ipairs(list) do known.alias_set = nil end
    return list
end

-- At most this many entries from earlier volumes go into one request.
Store.MAX_EARLIER_KNOWN = 40

-- Does the lowercased text name this lowercased word? It must start a word; at its
-- end a short ending may follow (genitive and plural: "Carls", "Donuts", "Katzen").
local function namedInText(text, name)
    if #name < 3 then return false end
    local start = 1
    while true do
        local from, to = text:find(name, start, true)
        if not from then return false end
        local before = text:byte(from - 1)
        if not (before and (before >= 128 or string.char(before):match("%w"))) then
            local rest = text:sub(to + 1, to + 4)
            local ending = rest:match("^(%a?%a?)")
            local after = rest:byte(#ending + 1)
            if #ending == 0 or ending == "s" or ending == "es" or ending == "n" or ending == "en" or ending == "ns" then
                if not (after and (after >= 128 or string.char(after):match("%w"))) then return true end
            end
        end
        start = from + 1
    end
end
Store.namedInText = namedInText

--- Entries from earlier volumes of the series that this request's chapters
-- name (by name or alias) and that the current book does not know yet.
-- Only these go to the AI, so a request grows by a few lines at most.
-- @param volumes Series.previousLexicons
-- @param current known entities of the current book (getKnownEntities)
-- @param text the chapters' text
-- @return list like getKnownEntities, each with `volume`
function Store.earlierMentioned(volumes, current, text)
    if not volumes or #volumes == 0 or type(text) ~= "string" or text == "" then return {} end
    local sequence = {}
    for _, volume in ipairs(volumes) do
        for _, note in ipairs(volume.notes or {}) do
            table.insert(sequence, { index = note.index, title = note.title, entities = note.entities,
                volume = volume.series_index })
        end
    end
    local taken = {}
    for _, entity in ipairs(current or {}) do
        taken[entity.name:lower()] = true
        for _, alias in ipairs(entity.aliases or {}) do taken[alias:lower()] = true end
    end
    local lower = text:lower()
    local found = {}
    for _, entity in ipairs(Store.knownFromNotes(sequence)) do
        local names = { entity.name }
        for _, alias in ipairs(entity.aliases or {}) do table.insert(names, alias) end
        local already, named = false, false
        for _, name in ipairs(names) do
            local key = name:lower()
            if taken[key] then already = true break end
            -- a short form that is only part of the name ("Dungeon") is too vague here
            if not named and not Store.isPartOfName(key, entity.name:lower()) and namedInText(lower, key) then
                named = true
            end
        end
        if named and not already then table.insert(found, entity) end
    end
    -- Characters first, then the most recently seen.
    table.sort(found, function(a, b)
        local a_char, b_char = a.type == "character", b.type == "character"
        if a_char ~= b_char then return a_char end
        if (a.volume or 0) ~= (b.volume or 0) then return (a.volume or 0) > (b.volume or 0) end
        return (a.last_index or 0) > (b.last_index or 0)
    end)
    for i = #found, Store.MAX_EARLIER_KNOWN + 1, -1 do found[i] = nil end
    return found
end

--- Older notes call beasts "character"; a name with a level ("Grauer Wolf – Level 12")
-- is a creature, not a person.
-- @param display the name without level, from normalizeName
function Store.fixEntityType(entity, display)
    local lower = entity.name:lower()
    if entity.type == "character" and display ~= entity.name
            and (lower:find("level%s*%d") or lower:find("lvl%s*%d") or lower:find("stufe%s*%d")) then
        local copy = {}
        for k, v in pairs(entity) do copy[k] = v end
        copy.type = "creature"
        return copy
    end
    return entity
end

-- Bytes that belong to a word: ASCII letters and digits, and UTF-8 (umlauts).
local function isWordByte(byte)
    return byte and (byte >= 128 or string.char(byte):match("%w") ~= nil)
end

--- Does the text name this exact word (not as part of a longer word)?
local function mentions(text, name)
    if #name < 3 then return false end
    local start = 1
    while true do
        local from, to = text:find(name, start, true)
        if not from then return false end
        if not isWordByte(text:byte(from - 1)) and not isWordByte(text:byte(to + 1)) then
            return true
        end
        start = from + 1
    end
end

--- The AI sometimes names a known character in a chapter's summary but leaves
-- them out of that chapter's entities (a side character's big scene, e.g. a
-- death). Then the summary's sentences about them become facts, so the
-- lexicon still knows what happened.
-- @param listed profiles the note already has facts for
function Store.addFactsFromSummary(list, listed, note, order)
    local summary = note.summary
    if type(summary) ~= "string" or summary == "" then return end
    local sentences = {}
    for sentence in (summary .. " "):gmatch("(.-[%.!%?…]+[\"“”«»']?)%s+") do
        table.insert(sentences, (sentence:gsub("^%s+", "")))
    end
    if #sentences == 0 then sentences = { summary } end
    for _, profile in ipairs(list) do
        if not listed[profile] and (profile.type == "character" or profile.type == "creature") then
            local names = { profile.name }
            for _, alias in ipairs(profile.aliases) do table.insert(names, alias) end
            local added = 0
            for _, sentence in ipairs(sentences) do
                for _, name in ipairs(names) do
                    if added < 4 and mentions(sentence, name) then
                        added = added + 1
                        table.insert(profile.facts, { index = note.index, title = note.title,
                            text = sentence, from_summary = true, volume = note.volume })
                        profile.last_index = note.index
                        profile.last_title = note.title
                        profile.last_volume = note.volume
                        profile.last_order = order or profile.last_order
                        break
                    end
                end
            end
        end
    end
end

--- Full profiles of all entities up to a chapter, assembled from every AI
-- note (never from an earlier profile): all facts in reading order, the
-- latest relation to the protagonist, first and last appearance.
-- @return list of profiles, plus a lookup table by lowercased name/alias
-- @param earlier optional, earlier volumes of the series (Series.previousLexicons): their
--   notes come first, so an entry continues across volumes like in one long book
--   (facts add up, the latest status and relation win, "first seen" stays in the
--   earlier volume). Their notes carry `volume`; the current book's do not.
function Store:getEntityProfiles(max_index, earlier)
    local by_name, list, partial = {}, {}, {}
    local normalize = Store.normalizeName
    local sequence = {}
    for _, volume in ipairs(earlier or {}) do
        for _, note in ipairs(volume.notes or {}) do
            table.insert(sequence, { index = note.index, title = note.title, entities = note.entities,
                volume = volume.series_index })
        end
    end
    for _, note in ipairs(self:getChapterNotes(max_index)) do table.insert(sequence, note) end
    for order, note in ipairs(sequence) do
        local listed = {}
        for _, entity in ipairs(note.entities or {}) do
            local key, display = normalize(entity.name)
            entity = Store.fixEntityType(entity, display)
            local profile = by_name[key]
            if not profile then
                for _, alias in ipairs(entity.aliases or {}) do
                    local alias_key = normalize(alias)
                    if not partial[alias_key] then profile = profile or by_name[alias_key] end
                end
            end
            if not profile then
                profile = {
                    name = display, type = entity.type, aliases = {}, alias_set = {}, type_counts = {},
                    facts = {}, first_index = note.index, first_title = note.title, first_volume = note.volume,
                }
                by_name[key] = profile
                table.insert(list, profile)
            end
            -- The type the AI gave most often wins (a place called a "term" once stays a place).
            profile.type_counts[entity.type] = (profile.type_counts[entity.type] or 0) + 1
            if profile.type_counts[entity.type] > (profile.type_counts[profile.type] or 0) then
                profile.type = entity.type
            end
            profile.last_index = note.index
            profile.last_title = note.title
            profile.last_volume = note.volume
            profile.last_order = order
            if entity.relation then profile.relation = entity.relation end
            if entity.status then
                profile.status = { text = entity.status, index = note.index, title = note.title, volume = note.volume }
            end
            for _, fact in ipairs(entity.facts or {}) do
                if type(fact) == "string" then
                    table.insert(profile.facts, { index = note.index, title = note.title, text = fact,
                        volume = note.volume })
                end
            end
            local names = { entity.name }
            for _, alias in ipairs(entity.aliases or {}) do table.insert(names, alias) end
            for _, alias in ipairs(names) do
                local alias_key, alias_display = normalize(alias)
                if alias_key ~= normalize(profile.name) and not profile.alias_set[alias_key] then
                    profile.alias_set[alias_key] = true
                    table.insert(profile.aliases, alias_display)
                end
                if not by_name[alias_key] then
                    by_name[alias_key] = profile
                    partial[alias_key] = Store.isPartOfName(alias_key, (normalize(profile.name)))
                end
            end
            listed[profile] = true
        end
        Store.addFactsFromSummary(list, listed, note, order)
    end
    -- Answers of "ask the AI", only for what the notes do not know themselves.
    for _, lookup in ipairs(self.data.lookups or {}) do
        local key, display = normalize(lookup.name)
        if not by_name[key] and (not max_index or lookup.index <= max_index) then
            local profile = {
                name = display, type = lookup.type, aliases = {}, alias_set = {}, facts = {},
                first_index = lookup.index, first_title = lookup.title,
                last_index = lookup.index, last_title = lookup.title, last_order = #sequence,
                relation = lookup.relation, asked = true,
            }
            for _i, fact in ipairs(lookup.facts) do
                table.insert(profile.facts, { index = lookup.index, title = lookup.title, text = fact })
            end
            by_name[key] = profile
            table.insert(list, profile)
        end
    end
    for _, profile in ipairs(list) do
        -- in how many chapters it appears (lexicon order "frequency")
        local chapters = 0
        for _type, n in pairs(profile.type_counts or {}) do chapters = chapters + n end
        profile.chapter_count = chapters
        profile.alias_set = nil
        profile.type_counts = nil
    end
    return list, by_name
end

-- Notes

function Store:addNote(chapter, text, source)
    local now = os.time()
    local note = {
        id = self.data.next_note_id,
        chapter_key = chapter.key,
        chapter_index = chapter.index,
        chapter_title = chapter.title,
        text = text,
        source = source or "user",
        created = now,
        updated = now,
    }
    self.data.next_note_id = note.id + 1
    table.insert(self.data.notes, note)
    self:markDirty()
    return note
end

function Store:updateNote(id, text)
    for _, note in ipairs(self.data.notes) do
        if note.id == id then
            note.text = text
            note.updated = os.time()
            self:markDirty()
            return note
        end
    end
end

function Store:deleteNote(id)
    for i, note in ipairs(self.data.notes) do
        if note.id == id then
            table.remove(self.data.notes, i)
            self:markDirty()
            return true
        end
    end
    return false
end

--- Notes sorted by chapter, then by creation time.
-- @int max_chapter_index only notes up to this chapter (nil = all)
function Store:getNotes(max_chapter_index)
    local result = {}
    for _, note in ipairs(self.data.notes) do
        if not max_chapter_index or note.chapter_index <= max_chapter_index then
            table.insert(result, note)
        end
    end
    table.sort(result, function(a, b)
        if a.chapter_index ~= b.chapter_index then
            return a.chapter_index < b.chapter_index
        end
        return a.id < b.id
    end)
    return result
end

return Store
