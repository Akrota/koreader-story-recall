--[[--
Summaries of earlier volumes from the internet, for volumes that were never
on the device (e.g. read on paper). Only on the reader's request, once per
series; the result goes into the series archive and is clearly marked.

Uses the provider's own web search: Gemini (Interactions API with Google
Search), Claude (web search tool), OpenAI (Responses API) and OpenRouter
(web plugin). Other providers have no web search.
--]]

local AI = require("storyrecall/ai")

local WebSummary = {}

local SUPPORTED = { gemini = true, anthropic = true, openai = true, openrouter = true }
local MAX_SOURCES = 6
local MAX_CONTINUATIONS = 3

function WebSummary.supported(provider_id)
    return SUPPORTED[provider_id] == true
end

--- The question for the AI.
-- @param book { title, authors, series, series_index }
-- @param language notes language code, e.g. "de"
function WebSummary.prompt(book, language)
    local index = tonumber(book.series_index) or 2
    local last = math.floor(index - 1 + 0.5)
    return table.concat({
        string.format("Search the web for the book series \"%s\"%s.", book.series or "?",
            book.authors and (" by " .. book.authors:gsub("\n", ", ")) or ""),
        string.format("The reader is about to start volume %s (\"%s\") and has not read it yet. Summarise volumes 1 to %d for them, one after the other, so they remember the story.",
            tostring(book.series_index), book.title or "?", last),
        "",
        "Rules:",
        string.format("- ONLY events of volumes 1 to %d. Nothing from volume %s or later: no hints, no outcomes, no character fates that are revealed later. Fan wikis often mix in later events; leave out anything you cannot place in these volumes.", last, tostring(book.series_index)),
        "- Prefer the publisher's descriptions, reviews and summaries of single volumes. Do not invent anything; if you found little about a volume, write less and say so.",
        "- For each volume 5 to 8 sentences: the main events, the important characters and what became of them, and where things stand at the end of the volume.",
        string.format("- Write in this language: %s. Keep names as they are used in that language's edition if you know them.", language or "en"),
        "- Format: start each volume with a line \"### Volume N: Title\" (N = number), followed by the summary. No other headings, no list of sources (they are collected separately).",
    }, "\n")
end

-- Walk a decoded JSON answer: collect the answer text and cited sources.
-- Text comes from blocks of type "text"/"output_text" (Gemini, Claude,
-- OpenAI) or from choices[1].message.content (OpenRouter).
-- Blocks that mark a search step.
local SEARCH_STEPS = { server_tool_use = true, web_search_tool_result = true, web_search_call = true,
    google_search_call = true, google_search_result = true }

local function collect(node, out, seen)
    if type(node) ~= "table" then return end
    -- A search step ends a line: a preamble before it stays apart from the
    -- next heading, and text written between two searches is kept.
    if SEARCH_STEPS[node.type] then table.insert(out.texts, "\n") end
    if node.type == "url_citation" or node.type == "web_search_result_location" then
        local cite = type(node.url_citation) == "table" and node.url_citation or node
        local url, title = cite.url or cite.uri, cite.title
        local label = title and title ~= "" and title or (url and url:match("^https?://([^/]+)"))
        if label and not seen[label] then
            seen[label] = true
            table.insert(out.sources, label)
        end
    end
    if (node.type == "text" or node.type == "output_text") and type(node.text) == "string" then
        table.insert(out.texts, node.text)
    end
    for _, child in ipairs(node) do collect(child, out, seen) end
    for key, child in pairs(node) do
        if type(key) ~= "number" and type(child) == "table" then collect(child, out, seen) end
    end
end

function WebSummary.extract(answer)
    local out = { texts = {}, sources = {} }
    collect(answer, out, {})
    -- Blocks are joined as they come (Claude splits sentences at citations),
    -- but a heading always starts on its own line.
    local text = ""
    for _i, piece in ipairs(out.texts) do
        if piece:match("^%s*#") and text ~= "" and not text:match("\n$") then text = text .. "\n" end
        text = text .. piece
    end
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    local choice = type(answer.choices) == "table" and answer.choices[1]
    if text == "" and type(choice) == "table" and type(choice.message) == "table" then
        text = choice.message.content or ""
    end
    while #out.sources > MAX_SOURCES do table.remove(out.sources) end
    return text, out.sources
end

local function request(cfg, prompt)
    local provider = AI.getProvider(cfg.provider)
    if cfg.provider == "gemini" then
        return AI.post("https://generativelanguage.googleapis.com/v1beta/interactions",
            { ["x-goog-api-key"] = cfg.key },
            { model = cfg.model, input = prompt, tools = { { type = "google_search" } } })
    elseif cfg.provider == "anthropic" then
        local headers = function() return { ["x-api-key"] = cfg.key, ["anthropic-version"] = "2023-06-01" } end
        local messages = { { role = "user", content = prompt } }
        local tool_type = "web_search_20260209"
        local answer, err
        local all_content = {} -- a paused turn continues in a new answer: keep every part
        for _ = 0, MAX_CONTINUATIONS do
            answer, err = AI.post("https://api.anthropic.com/v1/messages", headers(), {
                model = cfg.model, max_tokens = 8000, messages = messages,
                tools = { { type = tool_type, name = "web_search" } },
            })
            if not answer and err and err.code == 400 and tool_type == "web_search_20260209" then
                -- Older models only know the basic version of the tool.
                tool_type = "web_search_20250305"
                answer, err = AI.post("https://api.anthropic.com/v1/messages", headers(), {
                    model = cfg.model, max_tokens = 8000, messages = messages,
                    tools = { { type = tool_type, name = "web_search" } },
                })
            end
            if answer then
                for _, block in ipairs(answer.content or {}) do table.insert(all_content, block) end
            end
            -- The server pauses long search loops; resend to let it continue.
            if not answer or answer.stop_reason ~= "pause_turn" then break end
            messages = { messages[1], { role = "assistant", content = all_content } }
        end
        if answer then answer = { stop_reason = answer.stop_reason, content = all_content } end
        return answer, err
    elseif cfg.provider == "openai" then
        return AI.post((provider.base_url or "https://api.openai.com/v1") .. "/responses",
            { ["Authorization"] = "Bearer " .. cfg.key },
            { model = cfg.model, input = prompt, tools = { { type = "web_search" } } })
    elseif cfg.provider == "openrouter" then
        return AI.post(provider.base_url .. "/chat/completions",
            { ["Authorization"] = "Bearer " .. cfg.key },
            { model = cfg.model, messages = { { role = "user", content = prompt } }, plugins = { { id = "web" } } })
    end
    return nil, { kind = "config", message = "no web search for this provider" }
end

--- Split the answer into volumes ("### Volume N: Title").
-- @return list of { series_index, title, text }
function WebSummary.split(text, fallback_index)
    local volumes = {}
    local current
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local number, title = line:match("^#+%s*%a*%s*(%d+)(.-)%s*$")
        if number then
            -- "Volume 2: Title", "Band 2 – Title", "Volume 2 - Title"
            title = title:gsub("^%s*:%s*", ""):gsub("^%s*%-+%s*", ""):gsub("^%s*–%s*", ""):gsub("^%s*—%s*", "")
            current = { series_index = tonumber(number), title = title ~= "" and title or nil, lines = {} }
            table.insert(volumes, current)
        elseif current then
            table.insert(current.lines, line)
        elseif line:match("%S") then
            current = { series_index = fallback_index, lines = { line }, unheaded = true }
            table.insert(volumes, current)
        end
    end
    -- Text before the first heading is a preamble ("I'll search…") when headings follow.
    if #volumes > 1 and volumes[1].unheaded then table.remove(volumes, 1) end
    local result = {}
    for _, volume in ipairs(volumes) do
        local body = table.concat(volume.lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
        if body ~= "" then
            table.insert(result, { series_index = volume.series_index, title = volume.title, text = body })
        end
    end
    return result
end

--- Ask the AI. Runs synchronously (call it from a subprocess on e-readers).
-- @return list of volumes, sources | nil, error
function WebSummary.run(cfg, book, language)
    if not WebSummary.supported(cfg.provider) then
        return nil, { kind = "config", message = "no web search for this provider" }
    end
    local answer, err = request(cfg, WebSummary.prompt(book, language))
    if not answer then return nil, err end
    local text, sources = WebSummary.extract(answer)
    local index = tonumber(book.series_index) or 2
    local volumes = WebSummary.split(text or "", math.floor(index - 1 + 0.5))
    -- Never keep anything for the current volume or later.
    for i = #volumes, 1, -1 do
        if not volumes[i].series_index or volumes[i].series_index >= index then table.remove(volumes, i) end
    end
    if #volumes == 0 then return nil, { kind = "format", message = "no summary in the answer" } end
    return volumes, sources
end

return WebSummary
