--[[--
What Story Recall asks the AI, and how the answer is checked.

One request covers a small batch of consecutive chapters (to save requests
and battery). The AI sees those chapters' text plus the summaries of all
chapters before them, never anything later. Within a batch it is told not to
let a later chapter leak into an earlier chapter's notes; batches stay small
to keep that risk low.

It returns new facts only; descriptions are assembled on the device from all
facts, so nothing it once said can be lost by a later answer.
--]]

local util = require("util")

local Prompt = {}

local ENTITY_TYPES = { character = true, creature = true, place = true, object = true, group = true, term = true }
-- Shorter summaries are placeholders, not answers (same limit as Store.MIN_SUMMARY_CHARS).
local MIN_SUMMARY_CHARS = 20

-- Batching limits.
Prompt.MAX_BATCH_CHAPTERS = 3
Prompt.MAX_BATCH_WORDS = 30000
-- At most this many known entities are listed in a request (most recently seen).
Prompt.MAX_KNOWN = 120
-- Upper bound for the earlier volumes' summaries in a request (characters).
Prompt.MAX_EARLIER_CHARS = 8000
-- Upper bound for one chapter's text (characters). Real chapters stay far below.
Prompt.MAX_CHAPTER_CHARS = 120000

Prompt.SYSTEM = [[
You write a reader's story notes for chapters of a novel, so that someone returning to the book after weeks still remembers what happened.

Rules:
- Use ONLY the chapter texts and the earlier chapter summaries you are given. Never use outside knowledge of this book, its series, its author, film adaptations or fan wikis, even if you recognise the book. Never hint at anything that happens later.
- You may get several consecutive chapters. Write the notes for each chapter as if you had read only up to the end of THAT chapter: nothing from a later chapter may appear in an earlier chapter's notes.
- Write in the language given as "Notes language" (e.g. German for "de"), even if the book is in another language. Keep the names of characters, places and groups as the book uses them; for translated terms (skills, titles, items) you may add the other language's term in brackets the first time.
- You may get a summary of the earlier volumes of the series. Use it only as background, to recognise returning characters and threads. Names can differ there if this book is a translation or the original of the earlier volumes. Never retell the earlier volumes in a chapter's notes.
- If the text leaves something open (whether someone is really dead, who is behind a mask, what a prophecy means), write it as open; never resolve it. If you are not sure a detail is stated in the text, leave out that detail instead of guessing; the rest of the notes stay complete.
- Ignore everything that is not story: author's notes, acknowledgements, announcements of the next volume, advertising, and appendices that only list stats.
- Prefer concrete events over abstract wording. Feelings are welcome when they are tied to what happened ("after his brother's death he withdraws"), not as vague labels ("he gains inner strength").
- Return a single JSON object {"chapters": [...]} with one entry per chapter, in order, nothing else.

Each chapter entry:
"index": the chapter number given in the chapter header.
"summary": 4 to 6 sentences. Say what happens, who drives it, why it matters, and what changed by the end of the chapter (new abilities, decisions, relationships, open questions, cliffhangers). Name characters. Be concrete: places, numbers, items, names of skills or spells. No vague phrases like "things get complicated". Do not retell earlier chapters. Cover the whole chapter evenly, beginning, middle and end: a short scene can matter most, wherever it is (a twist, or what really became of someone). Scenes told from the view of a side character count as much as the protagonist's.
"story_so_far": the whole story from the beginning up to the end of THIS chapter, condensed for a reader who paused for weeks, in two paragraphs separated by a blank line. First paragraph (5 to 8 sentences): the whole story so far in order, starting with how it began (the setup of the book's first chapters), then the main turning points up to now; give the early events as much weight as the recent ones, never only the last chapters; it does not describe the situation at the end of the chapter and never starts a sentence with "Am Ende des Kapitels". Second paragraph (2 to 4 sentences), starting with "Am Ende des Kapitels" (or the equivalent in the notes language): where things stand: where the protagonist is and what they are doing, what became of the important characters (alive, dead, separated, allied), and the open questions. Also mention characters who appear rarely but whose last appearance left an open thread (a secret, a betrayal, a promise, a mysterious change); the known entities list shows the last thing learned about each. Build it from the earlier chapter summaries, the known entities and this chapter. No events after this chapter. Never call a chapter a "section".
"volume_summary": ONLY for the chapter marked as the last chapter of the book; leave it out for all other chapters. Three paragraphs separated by blank lines, 12 to 18 sentences in total, for a reader about to start the next volume: (1) the plot of the whole book with its turning points, (2) the important characters, including rarely seen ones with open threads, how they relate to the protagonist and what became of them, (3) where everything stands at the end of the book, starting with "Am Ende des Bandes" (or the equivalent in the notes language), with the open questions and hints for what comes next.
"protagonist": the name of the main viewpoint character of the book so far.
"entities": the characters, places, objects, groups and terms that matter in this chapter. For each:
  "name": the most complete name used so far. If it is someone from the known list, use exactly that name.
  "type": one of character, creature, place, object, group, term:
    character = a person, or a being that acts like one in the story (talks, has goals of its own): humans, gods, spirits, named intelligent beings;
    creature = animals, monsters and beasts that are hunted, fought or met, including a single notable one such as a boss; one entry per kind;
    place = any location where scenes happen: country, city, camp, settlement, building, room, dungeon, forest, area of a game world; also places without a proper name that the story keeps returning to ("das Lager", "der Wald");
    object = a thing: weapon, armour, item, potion, ingredient, artefact;
    group = a faction, family, guild, team, people or species as a whole;
    term = everything else: skills, spells, classes, titles, professions, system rules, concepts.
  "aliases": other names, titles or nicknames used for it in this chapter (may be empty). Do not list a family name shared with other characters as an alias.
  "facts": 1 to 4 short, self-contained sentences with information that is NEW in this chapter: who or what it is, what it did, what happened to it, how it relates to others. When an entity appears for the first time, the first fact says who or what it is. Do not repeat facts already known from earlier summaries or earlier chapters of this request.
  "relation_to_protagonist": one short phrase (e.g. "his sister", "rival", "his mentor"), or "" if none or if it is the protagonist.
  "status": only when this chapter fundamentally changes the situation of a character or creature: a few words on where they now stand (e.g. "dead", "missing", "arrested", "has left the city", "now on the enemy's side", "married to Anna"); also when an earlier status no longer applies (e.g. "back with the group"); "" if nothing fundamental changed. Not for places, objects, groups or terms.

Which entities to list:
- Every character named in your summary, with at least one fact about this chapter, including things only reported about them (a death, a disappearance, a revealed secret).
- Every place where this chapter's scenes happen (a camp, a room, a building, a dungeon, a town), even if it was listed before, with a fact about what happens there in this chapter. Use the name the book uses, or a short description such as "das Lager der Rebellen" if it has no proper name.
- Skip entities that are only mentioned in passing without any new information.
- Creatures: list a kind of creature once, as a creature, and only if it matters; never a single unnamed one with its level (e.g. "Grauer Wolf", not "Grauer Wolf Level 12").
- One name per entity, without rarity or level in brackets (e.g. "Feuerball", not "Feuerball (selten)").
]]

local ENTITY_SCHEMA = {
    type = "object",
    additionalProperties = false,
    required = { "name", "type", "aliases", "facts", "relation_to_protagonist", "status" },
    properties = {
        name = { type = "string" },
        type = { type = "string", enum = { "character", "creature", "place", "object", "group", "term" } },
        aliases = { type = "array", items = { type = "string" } },
        facts = { type = "array", items = { type = "string" } },
        relation_to_protagonist = { type = "string" },
        status = { type = "string" },
    },
}

-- JSON schema (used where the provider supports structured output).
Prompt.SCHEMA = {
    type = "object",
    additionalProperties = false,
    required = { "chapters" },
    properties = {
        chapters = {
            type = "array",
            items = {
                type = "object",
                additionalProperties = false,
                required = { "index", "summary", "story_so_far", "protagonist", "entities" },
                properties = {
                    index = { type = "integer" },
                    summary = { type = "string" },
                    story_so_far = { type = "string" },
                    volume_summary = { type = "string" },
                    protagonist = { type = "string" },
                    entities = { type = "array", items = ENTITY_SCHEMA },
                },
            },
        },
    },
}

local function countWords(text)
    return select(2, text:gsub("%S+", ""))
end

--- Pick the batch: the first pending chapter plus following ones, within limits.
-- @param pending chapters in reading order, each with .text
-- @return list of chapters for one request
function Prompt.batch(pending)
    local batch, words = {}, 0
    for _, chapter in ipairs(pending) do
        local chapter_words = countWords(chapter.text or "")
        if #batch > 0 and (words + chapter_words > Prompt.MAX_BATCH_WORDS
                or #batch >= Prompt.MAX_BATCH_CHAPTERS
                or (chapter.seq or chapter.index) ~= (batch[#batch].seq or batch[#batch].index) + 1) then
            break
        end
        table.insert(batch, chapter)
        words = words + chapter_words
    end
    return batch
end

--- Build the user message.
-- @param ctx { book = {title, authors, language}, chapters = { {index, title, text}, ... },
--              previous = { {index, title, summary}, ... }, known = { {name, type, aliases}, ... } }
-- @return message, truncated (bool)
function Prompt.build(ctx)
    local lines = {}
    table.insert(lines, "Book: " .. (ctx.book.title or "?") .. (ctx.book.authors and (" by " .. ctx.book.authors) or ""))
    table.insert(lines, "Book language: " .. (ctx.book.language or "unknown"))
    table.insert(lines, "Notes language: " .. (ctx.notes_language or ctx.book.language or "unknown"))
    table.insert(lines, "")

    if ctx.earlier_volumes and #ctx.earlier_volumes > 0 then
        table.insert(lines, "Earlier volumes of the series (background only):")
        local budget = Prompt.MAX_EARLIER_CHARS
        -- The volume right before matters most: newest first within the budget.
        local parts = {}
        for i = #ctx.earlier_volumes, 1, -1 do
            local volume = ctx.earlier_volumes[i]
            local text = volume.text or ""
            if i < #ctx.earlier_volumes then
                -- Only the plot: a volume summary has it in the first paragraph,
                -- the story so far in all paragraphs before "Zuletzt".
                text = text:match(volume.story_so_far and "^(.*)\n%s*\n" or "^(.-)\n%s*\n") or text
            end
            if #text > budget then
                text = budget > 200 and text:sub(1, budget):gsub("[\192-\255][\128-\191]*$", "") or ""
            end
            if text == "" then break end
            budget = budget - #text
            table.insert(parts, 1, string.format("Volume %s%s: %s", tostring(volume.series_index),
                volume.title and (" (" .. volume.title .. ")") or "", text))
        end
        for _, part in ipairs(parts) do table.insert(lines, part) end
        table.insert(lines, "")
    end

    if ctx.story_before then
        table.insert(lines, string.format("The story up to chapter %d (condensed):", ctx.story_before.index))
        table.insert(lines, ctx.story_before.text)
        table.insert(lines, "")
    end
    if #ctx.previous > 0 then
        table.insert(lines, "Summaries of the earlier chapters (in order):")
        for _, prev in ipairs(ctx.previous) do
            table.insert(lines, string.format("[%d] %s: %s", prev.index, prev.title or "", prev.summary or ""))
        end
    else
        table.insert(lines, "These are the first chapters; there are no earlier summaries.")
    end
    table.insert(lines, "")

    if #ctx.known > 0 then
        -- Keep the list bounded. Characters come first, so a rarely seen
        -- character with an open thread is not pushed out by places or terms;
        -- within a group the most recently seen win.
        local known = ctx.known
        if #known > Prompt.MAX_KNOWN then
            known = {}
            for _, entity in ipairs(ctx.known) do table.insert(known, entity) end
            table.sort(known, function(a, b)
                local a_char, b_char = a.type == "character", b.type == "character"
                if a_char ~= b_char then return a_char end
                return (a.last_index or 0) > (b.last_index or 0)
            end)
            for i = #known, Prompt.MAX_KNOWN + 1, -1 do known[i] = nil end
        end
        local from_earlier = false
        for _, entity in ipairs(known) do from_earlier = from_earlier or entity.volume ~= nil end
        table.insert(lines, "Known entities so far, with the last thing learned about each (chapter in brackets):")
        if from_earlier then
            -- Series: entries from an earlier volume that these chapters name again.
            table.insert(lines, "(Entries marked \"vol.\" are known from an earlier volume of the series: they are not new, keep their name.)")
        end
        for _, entity in ipairs(known) do
            local line = "- " .. entity.name .. " (" .. tostring(entity.type) .. ")"
            if entity.aliases and #entity.aliases > 0 then
                line = line .. " aka " .. table.concat(entity.aliases, ", ")
            end
            if entity.last_fact and entity.volume then
                line = line .. string.format(": [vol. %s, ch. %d] %s", tostring(entity.volume),
                    entity.last_fact_index or 0, entity.last_fact)
            elseif entity.volume then
                line = line .. string.format(": [vol. %s]", tostring(entity.volume))
            elseif entity.last_fact then
                line = line .. string.format(": [%d] %s", entity.last_fact_index or 0, entity.last_fact)
            end
            table.insert(lines, line)
        end
        table.insert(lines, "")
    end

    local truncated = false
    for _, chapter in ipairs(ctx.chapters) do
        -- Invalid UTF-8 (broken EPUBs) would make the JSON request fail.
        local text = util.fixUtf8(chapter.text or "", "?")
        if #text > Prompt.MAX_CHAPTER_CHARS then
            -- Cut, then drop a character the cut may have split.
            text = text:sub(1, Prompt.MAX_CHAPTER_CHARS):gsub("[\192-\255][\128-\191]*$", "")
            truncated = true
        end
        if ctx.last_index and chapter.index == ctx.last_index then
            table.insert(lines, string.format("Chapter %d is the LAST chapter of the book: add \"volume_summary\" for it.", chapter.index))
        end
        table.insert(lines, string.format("<chapter index=\"%d\" title=\"%s\">", chapter.index, (chapter.title or ""):gsub("\"", "'")))
        table.insert(lines, text)
        table.insert(lines, "</chapter>")
        table.insert(lines, "")
    end
    return table.concat(lines, "\n"), truncated
end

--- Leftovers of the answer format at the end of a text ("… ist offen.}, {",
-- Claude 24.10.2026). Only removed when they contain a brace or bracket.
local function stripJsonTail(value)
    local tail = value:match("[%s,\"%[%]{}]+$")
    if tail and tail:find("[%[%]{}]") then value = value:sub(1, #value - #tail) end
    return value
end
Prompt.stripJsonTail = stripJsonTail

local function cleanString(value)
    if type(value) ~= "string" then return nil end
    value = stripJsonTail(value):gsub("^%s+", ""):gsub("%s+$", "")
    if value == "" then return nil end
    return value
end

-- "Rewrite the story so far": one request that turns all chapter summaries up
-- to the point read into a fresh overview from the very beginning.
Prompt.RECAP_SYSTEM = [[
You write the "story so far" for a reader who returns to a novel after weeks and wants to get their bearings again before reading on.

You get the summaries of all chapters the reader has finished, in order. Use ONLY these summaries; never use outside knowledge of the book or its series, and never hint at anything after the last chapter given.

Write an overview, not a retelling: the big picture and the thread of the story, not every fight, item or number. The reader sees the summary of the last chapter right below your text, so do not retell that chapter in detail.

Return a single JSON object {"story_so_far": "..."} in the given notes language, with paragraphs separated by a blank line, exactly as the structure in the request says:
- The plot paragraphs tell the whole story in order. When the chapters are split into parts, write one paragraph per part, covering only the chapters of that part, in the number of sentences the request gives; this keeps the middle from being squeezed. A part with many important events may get one sentence more; never fewer than 2 sentences per paragraph.
- The first plot paragraph begins with how it all started (who the protagonist is, where they are, how it began), in at most 2 sentences; they count towards that paragraph.
- Name the important characters and what they mean to the protagonist. Also mention side characters who appear rarely but whose fate leaves an open thread, even if they appear in only one chapter.
- The last paragraph has 2 to 3 sentences and starts with "Zuletzt" (or the equivalent in the notes language): where things stand now, what the protagonist is about to do, and the open questions. It does not repeat the events of the last plot paragraph. Do not start it with "Am Ende des Bandes" or "Am Ende des Kapitels".
- Write only what the summaries say: rather shorter than padded. The sentence numbers are an upper frame, not a target.
- Tell the story, do not list it: connect events by cause and consequence (why something happens, what it leads to). Rather leave out a minor event than string events together. Use only connections the summaries state: a suspicion stays a suspicion, an open question stays open; never invent motives or causes.
- When a character first appears in your text and the sentence does not make clear who they are, add two to four words (for example "the group's healer" or "her lawyer"), so a reader who forgot them can follow. The protagonist and their closest companions need no such note.
- Write everything in the present tense and in the notes language. Do not switch to another language for ordinary words; only names and the book's own terms stay as the summaries use them.

Keep names and terms as the summaries use them. No headings, no part labels, no chapter numbers, no lists, no sentence like "In this book" or "In diesem Band".]]

Prompt.RECAP_SCHEMA = {
    type = "object",
    additionalProperties = false,
    properties = { story_so_far = { type = "string" } },
    required = { "story_so_far" },
}

-- Length of the story so far, by the number of chapters read: the longer the
-- book so far, the more parts (each its own paragraph) and the more sentences
-- per part. "Zuletzt" (2 to 3 sentences) comes on top. A Kobo page holds
-- about 8 of these long sentences.
local RECAP_PLAN = {
    { upto = 5, parts = 1, min = 3, max = 5 },
    { upto = 20, parts = 3, min = 2, max = 3 },
    { upto = 40, parts = 3, min = 3, max = 3 },
    { upto = 80, parts = 3, min = 4, max = 5 },
    { upto = 120, parts = 3, min = 5, max = 7 },
    { upto = math.huge, parts = 4, min = 5, max = 7 },
}

--- How to split `count` chapters for the story so far.
-- @return { parts, min, max, ranges = { {first, last}, … } } (positions 1..count)
function Prompt.recapPlan(count)
    local plan
    for _, step in ipairs(RECAP_PLAN) do
        if count <= step.upto then plan = step break end
    end
    local ranges, first = {}, 1
    for part = 1, plan.parts do
        -- Split by number of chapters, not by length: 72 → 1–24, 25–48, 49–72.
        local last = math.floor(count * part / plan.parts + 0.5)
        table.insert(ranges, { first, last })
        first = last + 1
    end
    return { parts = plan.parts, min = plan.min, max = plan.max, ranges = ranges }
end

--- The request for "rewrite the story so far".
-- @param ctx { book, notes_language, chapters = { {index, title, summary}, … } }
function Prompt.buildRecap(ctx)
    local chapters = ctx.chapters
    local plan = Prompt.recapPlan(#chapters)
    local lines = {}
    table.insert(lines, "Book: " .. (ctx.book.title or "?") .. (ctx.book.authors and (" by " .. ctx.book.authors) or ""))
    table.insert(lines, "Notes language: " .. (ctx.notes_language or ctx.book.language or "unknown"))
    if ctx.protagonist then table.insert(lines, "Protagonist: " .. ctx.protagonist) end
    table.insert(lines, "")
    local sentences = plan.min == plan.max and string.format("about %d", plan.min)
        or string.format("%d to %d", plan.min, plan.max)
    if plan.parts == 1 then
        table.insert(lines, string.format("Structure: one plot paragraph of %s sentences, then the \"Zuletzt\" paragraph (2 to 3 sentences). 2 paragraphs in total.",
            sentences))
    else
        table.insert(lines, string.format("Structure: the %d chapters read are split into %d parts below. Write %d plot paragraphs, one per part and in order, each %s sentences, then the \"Zuletzt\" paragraph (2 to 3 sentences). %d paragraphs in total.",
            #chapters, plan.parts, plan.parts, sentences, plan.parts + 1))
    end
    for part, range in ipairs(plan.ranges) do
        table.insert(lines, "")
        local from, to = chapters[range[1]], chapters[range[2]]
        if plan.parts == 1 then
            table.insert(lines, "Summaries of the finished chapters (in order):")
        else
            table.insert(lines, string.format("Part %d of %d (chapters %d to %d), summaries in order:",
                part, plan.parts, from.index, to.index))
        end
        for i = range[1], range[2] do
            local chapter = chapters[i]
            table.insert(lines, string.format("[%d] %s: %s", chapter.index, chapter.title or "", chapter.summary or ""))
        end
    end
    return table.concat(lines, "\n")
end

--- Check the answer of buildRecap. @return text or nil
function Prompt.validateRecap(answer)
    return type(answer) == "table" and cleanString(answer.story_so_far) or nil
end

-- Summary of a whole volume for the series recap. Its own request: as a side
-- field of the last chapter's notes it often came back short or not at all.
Prompt.VOLUME_SYSTEM = [[
You write the summary of a whole novel for a reader who is about to start the next volume of the series, maybe months later, and wants to remember what happened.

You get the summaries of all chapters of the book, in order. Use ONLY these summaries; never use outside knowledge of the book or its series, and never mention anything from later volumes.

Return a single JSON object {"volume_summary": "..."} with three paragraphs separated by blank lines, 12 to 18 sentences in total, in the given notes language:
1. The plot of the whole book in order, from how it began (who the protagonist is, where they are and how it all started) to the end, with its main turning points. Give the beginning, the middle and the end the same weight.
2. The important characters: who they are, how they relate to the protagonist and what became of them (alive, dead, separated, allied, changed). Also mention side characters who appear rarely but leave an open thread (a secret, a betrayal, a promise).
3. Starting with "Am Ende des Bandes" (or the equivalent in the notes language): where everything stands at the end of the book, the open questions and what the ending sets up for the next volume.

Keep names and terms as the summaries use them. Full sentences only: no headings, no lists, no fragments, no remarks in brackets, no sentence like "In this book" or "In diesem Band".]]

Prompt.VOLUME_SCHEMA = {
    type = "object",
    additionalProperties = false,
    properties = { volume_summary = { type = "string" } },
    required = { "volume_summary" },
}

--- The request for the volume summary.
-- @param ctx { book, notes_language, protagonist, chapters = { {index, title, summary}, … } }
function Prompt.buildVolume(ctx)
    local lines = {}
    table.insert(lines, "Book: " .. (ctx.book.title or "?") .. (ctx.book.authors and (" by " .. ctx.book.authors) or ""))
    if ctx.book.series then
        table.insert(lines, "Series: " .. ctx.book.series .. (ctx.book.series_index and (", volume " .. ctx.book.series_index) or ""))
    end
    table.insert(lines, "Notes language: " .. (ctx.notes_language or ctx.book.language or "unknown"))
    if ctx.protagonist then table.insert(lines, "Protagonist: " .. ctx.protagonist) end
    table.insert(lines, "")
    table.insert(lines, "Summaries of all chapters of the book (in order):")
    for _, chapter in ipairs(ctx.chapters) do
        table.insert(lines, string.format("[%d] %s: %s", chapter.index, chapter.title or "", chapter.summary or ""))
    end
    return table.concat(lines, "\n")
end

--- Check the answer of buildVolume. @return text or nil
function Prompt.validateVolume(answer)
    return type(answer) == "table" and cleanString(answer.volume_summary) or nil
end

-- "Ask the AI": the lexicon knows nothing about a name the reader looked up.
Prompt.LOOKUP_SYSTEM = [[
A reader of a novel looks up a word or name that their story notes do not explain. Tell them who or what it is in the story so far.

Use ONLY the chapter summaries and the passages from the book you are given; all of them come from before the reader's position. Never use outside knowledge of the book or its series, and never hint at anything later. If the passages leave something open, say it is open; if you are not sure about a detail, leave out that detail instead of guessing.

Return a single JSON object:
"found": true if it is a character, creature, place, object, group or term of the story; false if the passages and summaries do not say anything about it or it is just an ordinary word.
"name": the name as the book uses it.
"type": one of character, creature, place, object, group, term (same meaning as in story notes: creature = animals and monsters; term = skills, titles, concepts, everything else).
"facts": 1 to 4 short, self-contained sentences in the notes language: who or what it is, what it did or what happened there, how it relates to others, and where it stands now.
"relation_to_protagonist": one short phrase, or "".]]

Prompt.LOOKUP_SCHEMA = {
    type = "object",
    additionalProperties = false,
    properties = {
        found = { type = "boolean" },
        name = { type = "string" },
        type = { type = "string", enum = { "character", "creature", "place", "object", "group", "term" } },
        facts = { type = "array", items = { type = "string" } },
        relation_to_protagonist = { type = "string" },
    },
    required = { "found", "name", "type", "facts", "relation_to_protagonist" },
}

--- The request for "ask the AI".
-- @param ctx { book, notes_language, protagonist, query, chapters = { {index, title, summary} }, passages = { text, … } }
function Prompt.buildLookup(ctx)
    local lines = {}
    table.insert(lines, "Book: " .. (ctx.book.title or "?") .. (ctx.book.authors and (" by " .. ctx.book.authors) or ""))
    table.insert(lines, "Notes language: " .. (ctx.notes_language or ctx.book.language or "unknown"))
    if ctx.protagonist then table.insert(lines, "Protagonist: " .. ctx.protagonist) end
    table.insert(lines, "Looked up: " .. ctx.query)
    table.insert(lines, "")
    if #ctx.passages > 0 then
        table.insert(lines, "Passages from the book that mention it (oldest first):")
        for _, passage in ipairs(ctx.passages) do table.insert(lines, "- …" .. passage .. "…") end
        table.insert(lines, "")
    end
    table.insert(lines, "Summaries of the chapters read so far (in order):")
    for _, chapter in ipairs(ctx.chapters) do
        table.insert(lines, string.format("[%d] %s: %s", chapter.index, chapter.title or "", chapter.summary or ""))
    end
    return table.concat(lines, "\n")
end

local cleanList

--- Check the answer of buildLookup.
-- @return { found = true, name, type, facts, relation }, { found = false }, or nil if unusable
function Prompt.validateLookup(answer)
    if type(answer) ~= "table" then return nil end
    if answer.found == false then return { found = false } end
    local name = cleanString(answer.name)
    local facts = cleanList(answer.facts)
    if not name or #facts == 0 then return { found = false } end
    local entity_type = cleanString(answer.type)
    entity_type = entity_type and entity_type:lower()
    return {
        found = true,
        name = name,
        type = ENTITY_TYPES[entity_type] and entity_type or "term",
        facts = facts,
        relation = cleanString(answer.relation_to_protagonist),
    }
end

function cleanList(list)
    local result = {}
    if type(list) ~= "table" then return result end
    for _, item in ipairs(list) do
        local text = cleanString(item)
        if text then table.insert(result, text) end
    end
    return result
end

local function validateChapter(answer)
    if type(answer) ~= "table" then return nil end
    local summary = cleanString(answer.summary)
    -- A placeholder ("x") instead of a summary is no answer (Claude, 24.10.2026).
    if not summary or #summary < MIN_SUMMARY_CHARS then return nil end
    local result = {
        summary = summary,
        story_so_far = cleanString(answer.story_so_far),
        volume_summary = cleanString(answer.volume_summary),
        protagonist = cleanString(answer.protagonist),
        entities = {},
    }
    for _, entity in ipairs(type(answer.entities) == "table" and answer.entities or {}) do
        local name = type(entity) == "table" and cleanString(entity.name)
        if name then
            local entity_type = cleanString(entity.type)
            entity_type = entity_type and entity_type:lower()
            table.insert(result.entities, {
                name = name,
                type = ENTITY_TYPES[entity_type] and entity_type or "term",
                aliases = cleanList(entity.aliases),
                facts = cleanList(entity.facts),
                relation = cleanString(entity.relation_to_protagonist),
                status = cleanString(entity.status),
            })
        end
    end
    return result
end

--- Check and normalise a parsed answer for a batch.
-- @param batch the chapters that were sent
-- @param last_index index of the book's last chapter: only that one may carry a volume summary
-- @return { [chapter index] = note } (only chapters with a valid answer), or nil + reason
function Prompt.validate(answer, batch, last_index)
    if type(answer) ~= "table" then return nil, "not an object" end
    local entries = answer.chapters
    -- A model may answer a single chapter without the wrapper.
    if type(entries) ~= "table" and answer.summary then entries = { answer } end
    if type(entries) ~= "table" then return nil, "no chapters" end
    local expected = {}
    for _, chapter in ipairs(batch) do expected[chapter.index] = true end

    local notes, count = {}, 0
    for position, entry in ipairs(entries) do
        local index = type(entry) == "table" and tonumber(entry.index)
        -- Fall back to the position if the index is missing or off.
        if not index or not expected[index] then
            index = batch[position] and batch[position].index
        end
        local note = index and expected[index] and not notes[index] and validateChapter(entry)
        if note and index ~= last_index then
            -- Models sometimes add a volume summary to chapters in the middle.
            note.volume_summary = nil
        end
        if note then
            notes[index] = note
            count = count + 1
        end
    end
    if count == 0 then return nil, "no valid chapter" end
    return notes
end

return Prompt
