--[[--
AI providers for Story Recall.

Three request styles cover all providers:
  * Gemini (Google)                       generateContent
  * OpenAI-compatible                     chat/completions (OpenAI, OpenRouter, Mistral, DeepSeek, custom)
  * Claude (Anthropic)                    messages

complete() blocks while the request runs, so the processor calls it from a
subprocess. API keys live in their own file in KOReader's settings folder
(`settings/story_recall_keys.lua`), never in the book data.
--]]

local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local http = require("socket.http")
local json = require("json")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")

local AI = {}

-- Seconds to wait for the first byte, and for the whole answer. Models may
-- think for a while before they send anything when given several chapters;
-- under load Gemini took up to 170 s (23.10.2026), so 180 s was too tight.
local BLOCK_TIMEOUT = 240
local TOTAL_TIMEOUT = 300

AI.PROVIDERS = {
    { id = "gemini", name = "Google Gemini", style = "gemini", free = true,
      default_model = "gemini-3.8-flash", fallback_model = "gemini-3.5-flash-lite",
      models = { "gemini-3.8-flash", "gemini-3.6-flash", "gemini-3.5-flash-lite" } },
    { id = "anthropic", name = "Claude (Anthropic)", style = "anthropic",
      default_model = "claude-sonnet-5-5", fallback_model = "claude-haiku-5-5",
      models = { "claude-sonnet-5-5", "claude-opus-5-5", "claude-haiku-5-5" } },
    { id = "openai", name = "OpenAI", style = "openai",
      base_url = "https://api.openai.com/v1" },
    { id = "openrouter", name = "OpenRouter", style = "openai",
      base_url = "https://openrouter.ai/api/v1",
      -- "openrouter/auto" picks an available model by itself.
      default_model = "openrouter/auto", fallback_model = "openrouter/auto" },
    { id = "mistral", name = "Mistral", style = "openai",
      base_url = "https://api.mistral.ai/v1", default_model = "mistral-small-latest" },
    { id = "deepseek", name = "DeepSeek", style = "openai",
      base_url = "https://api.deepseek.com/v1", default_model = "deepseek-chat" },
    { id = "custom", name = "Custom (OpenAI-compatible)", style = "openai" },
}

-- Claude models that accept server-side fallbacks on a safety decline.
local FALLBACK_MODELS = {
    ["claude-opus-5-5"] = true, ["claude-sonnet-5-5"] = true, ["claude-opus-5"] = true,
    ["claude-fable-5-1"] = true,
}

function AI.getProvider(id)
    for _, provider in ipairs(AI.PROVIDERS) do
        if provider.id == id then return provider end
    end
end

-- API keys

local function keysFile()
    return DataStorage:getSettingsDir() .. "/story_recall_keys.lua"
end

function AI.getKey(provider_id)
    local keys = LuaSettings:open(keysFile())
    local key = keys:readSetting(provider_id)
    if type(key) == "string" and key ~= "" then return key end
end

function AI.setKey(provider_id, key)
    local keys = LuaSettings:open(keysFile())
    -- API keys never contain spaces: a line break from copying would only cause "401".
    key = key and key:gsub("%s", "")
    if key and key ~= "" then
        keys:saveSetting(provider_id, key)
    else
        keys:delSetting(provider_id)
    end
    keys:flush()
    -- LuaSettings keeps the previous version as a backup; for keys that would
    -- keep a deleted or replaced key on the device.
    os.remove(keysFile() .. ".old")
end

AI.keysFile = keysFile

-- HTTP

local function parsed_or_nil(content)
    local ok, parsed = pcall(json.decode, content or "")
    return ok and type(parsed) == "table" and parsed or nil
end

--- "20s", "1.5s", "6m0s", "1h2m3s", "200ms" (Gemini retryDelay, OpenAI reset
-- headers) → whole seconds.
local UNIT_SECONDS = { h = 3600, m = 60, s = 1, ms = 0.001, [""] = 1 }
local function durationSeconds(text)
    if type(text) ~= "string" then return nil end
    local total, found = 0, false
    for value, unit in text:gmatch("([%d%.]+)%s*(%a*)") do
        local n, factor = tonumber(value), UNIT_SECONDS[unit:lower()]
        if n and factor then
            found = true
            total = total + n * factor
        end
    end
    return found and math.ceil(total) or nil
end

--- How long the provider wants us to wait after a 429, and whether it is a
-- daily limit. Works for every provider as far as they say it: the
-- Retry-After header (Claude, OpenAI, Mistral, DeepSeek, OpenRouter),
-- Gemini's RetryInfo and QuotaFailure, OpenAI's reset headers, and wording
-- like "try again in 20s" or "requests per day".
-- @return seconds or nil, daily (bool)
function AI.parseRateLimit(headers, parsed, lower_text)
    local wait
    local header = headers and (headers["retry-after"] or headers["Retry-After"])
    wait = tonumber(header)
    local daily = false
    local err = parsed and type(parsed.error) == "table" and parsed.error
    for _, detail in ipairs(err and type(err.details) == "table" and err.details or {}) do
        if type(detail) == "table" then
            wait = wait or durationSeconds(detail.retryDelay)
            for _, violation in ipairs(type(detail.violations) == "table" and detail.violations or {}) do
                local id = type(violation) == "table" and tostring(violation.quotaId or violation.quotaMetric or "") or ""
                if id:find("PerDay") then daily = true end
            end
        end
    end
    if headers and not wait then
        wait = durationSeconds(headers["x-ratelimit-reset-requests"])
    end
    lower_text = lower_text or ""
    if not wait then
        wait = durationSeconds(lower_text:match("try again in ([%d%.hms ]+)")
            or lower_text:match("retry in ([%d%.hms ]+)")
            or lower_text:match("retry after ([%d%.hms ]+)"))
    end
    if lower_text:find("per day", 1, true) or lower_text:find("perday", 1, true)
            or lower_text:find("daily", 1, true) then
        daily = true
    end
    -- Never wait longer than a day (a broken value must not stop everything).
    if wait and wait > 86400 then wait = 86400 end
    return wait, daily
end
AI.durationSeconds = durationSeconds

local function post(url, headers, body)
    local encoded = json.encode(body)
    headers["Content-Type"] = "application/json"
    headers["Content-Length"] = tostring(#encoded)
    local sink = {}
    socketutil:set_timeout(BLOCK_TIMEOUT, TOTAL_TIMEOUT)
    local code, resp_headers, status = socket.skip(1, http.request{
        url = url,
        method = "POST",
        headers = headers,
        source = ltn12.source.string(encoded),
        sink = socketutil.table_sink(sink),
    })
    socketutil:reset_timeout()
    local content = table.concat(sink)
    if resp_headers == nil then
        local reason = tostring(status or code)
        -- A connection that was made but got no (complete) answer in time.
        if reason:find("timeout") or reason:find("wantread") or reason:find("closed") then
            return nil, { kind = "timeout", message = reason }
        end
        return nil, { kind = "network", message = reason }
    end
    if code ~= 200 then
        local message = content
        local ok, parsed = pcall(json.decode, content)
        if ok and type(parsed) == "table" then
            local err = parsed.error
            if type(err) == "table" then message = err.message or message
            elseif type(err) == "string" then message = err end
        end
        local kind = "http"
        if code == 429 then kind = "rate_limit"
        elseif code == 401 or code == 403 then kind = "auth"
        elseif type(code) == "number" and code >= 500 then kind = "server" end
        -- Look at the whole answer: OpenAI puts "insufficient_quota" only in
        -- error.code/type, not in the message.
        local lower = (tostring(content) .. " " .. tostring(message)):lower()
        -- No credit or balance left (OpenAI, Anthropic, DeepSeek, OpenRouter word it differently).
        if code == 402 or lower:find("insufficient_quota", 1, true) or lower:find("credit balance", 1, true)
                or lower:find("insufficient balance", 1, true) or lower:find("insufficient credits", 1, true)
                or lower:find("billing_error", 1, true) then
            kind = "quota"
        end
        -- Gemini rejects a wrong key with 400 instead of 401.
        if code == 400 and (lower:find("api_key_invalid", 1, true) or lower:find("api key not valid", 1, true)) then
            kind = "auth"
        end
        -- Only some providers say a key has expired (Gemini: "API key expired").
        local expired = (kind == "auth" or code == 400) and lower:find("expired", 1, true) ~= nil
        if expired then kind = "auth" end
        local retry_after, daily
        if kind == "rate_limit" then
            retry_after, daily = AI.parseRateLimit(resp_headers, parsed_or_nil(content), lower)
        end
        return nil, { kind = kind, code = code, message = tostring(message):sub(1, 300),
            retry_after = retry_after, daily = daily, expired = expired or nil }
    end
    local ok, parsed = pcall(json.decode, content)
    if not ok or type(parsed) ~= "table" then
        return nil, { kind = "format", message = "invalid JSON from provider" }
    end
    return parsed
end

AI.post = post -- also used by the web summary

-- Request styles. Each returns the model's text answer, or nil + error.

local function geminiRequest(cfg, system, user)
    local url = "https://generativelanguage.googleapis.com/v1beta/models/" .. cfg.model .. ":generateContent"
    local result, err = post(url, { ["x-goog-api-key"] = cfg.key }, {
        systemInstruction = { parts = { { text = system } } },
        contents = { { role = "user", parts = { { text = user } } } },
        generationConfig = { responseMimeType = "application/json", temperature = 0.3, maxOutputTokens = 16384 },
        -- Novels contain fights, crimes and romance; the default filters would
        -- block whole chapters.
        safetySettings = {
            { category = "HARM_CATEGORY_HARASSMENT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_HATE_SPEECH", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_SEXUALLY_EXPLICIT", threshold = "BLOCK_NONE" },
            { category = "HARM_CATEGORY_DANGEROUS_CONTENT", threshold = "BLOCK_NONE" },
        },
    })
    if not result then return nil, err end
    local candidate = result.candidates and result.candidates[1]
    local parts = candidate and candidate.content and candidate.content.parts
    if candidate and candidate.finishReason == "MAX_TOKENS" then
        return nil, { kind = "too_long", message = "MAX_TOKENS" }
    end
    if not parts then
        local reason = candidate and candidate.finishReason
            or (result.promptFeedback and result.promptFeedback.blockReason) or "empty answer"
        return nil, { kind = "refused", message = tostring(reason) }
    end
    local texts = {}
    for _, part in ipairs(parts) do
        if part.text and not part.thought then table.insert(texts, part.text) end
    end
    return table.concat(texts)
end

local function openaiRequest(cfg, system, user)
    local base = (cfg.base_url or ""):gsub("/+$", "")
    local body = {
        model = cfg.model,
        messages = {
            { role = "system", content = system },
            { role = "user", content = user },
        },
        response_format = { type = "json_object" },
        -- OpenAI's reasoning models only accept the default temperature.
        temperature = cfg.provider ~= "openai" and 0.3 or nil,
    }
    local result, err = post(base .. "/chat/completions", { ["Authorization"] = "Bearer " .. cfg.key }, body)
    -- Some models reject response_format or temperature: retry without (once each).
    for _attempt = 1, 2 do
        local message = not result and err.kind == "http" and err.code == 400 and tostring(err.message):lower() or ""
        if message:find("response_format", 1, true) and body.response_format then
            body.response_format = nil
        elseif message:find("temperature", 1, true) and body.temperature then
            body.temperature = nil
        else
            break
        end
        result, err = post(base .. "/chat/completions", { ["Authorization"] = "Bearer " .. cfg.key }, body)
    end
    if not result then return nil, err end
    local choice = result.choices and result.choices[1]
    if choice and choice.finish_reason == "length" then
        return nil, { kind = "too_long", message = "length" }
    end
    local text = choice and choice.message and choice.message.content
    if type(text) ~= "string" or text == "" then
        return nil, { kind = "refused", message = tostring(choice and choice.finish_reason or "empty answer") }
    end
    return text
end

-- Claude only accepts a JSON schema where every object says
-- additionalProperties = false. Add it everywhere, on a copy.
local function closedSchema(schema)
    if type(schema) ~= "table" then return schema end
    local copy = {}
    for k, v in pairs(schema) do copy[k] = closedSchema(v) end
    if copy.type == "object" and copy.additionalProperties == nil then
        copy.additionalProperties = false
    end
    return copy
end
AI.closedSchema = closedSchema

local function anthropicRequest(cfg, system, user, schema)
    local headers = {
        ["x-api-key"] = cfg.key,
        ["anthropic-version"] = "2023-06-01",
    }
    local body = {
        model = cfg.model,
        max_tokens = 16000,
        system = system,
        messages = { { role = "user", content = user } },
        output_config = {
            effort = "medium",
            format = schema and { type = "json_schema", schema = closedSchema(schema) } or nil,
        },
    }
    -- Anthropic's own fallback to another model only when switching is allowed
    if cfg.switch_models and FALLBACK_MODELS[cfg.model] then
        headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        body.fallbacks = "default"
    end
    local result, err = post("https://api.anthropic.com/v1/messages", headers, body)
    if not result then return nil, err end
    if result.stop_reason == "refusal" then
        return nil, { kind = "refused", message = "refusal" }
    end
    if result.stop_reason == "max_tokens" then
        return nil, { kind = "too_long", message = "max_tokens" }
    end
    local texts = {}
    for _, block in ipairs(result.content or {}) do
        if block.type == "text" and block.text then table.insert(texts, block.text) end
    end
    if #texts == 0 then
        return nil, { kind = "refused", message = tostring(result.stop_reason or "empty answer") }
    end
    return table.concat(texts)
end

--- Send one request. Blocking; call it from a subprocess.
-- @param cfg { provider, model, key, base_url }
-- @return text or nil, { kind = "network"|"timeout"|"rate_limit"|"auth"|"server"|"http"|"format"|"refused"|"config", message, retry_after }
function AI.complete(cfg, system, user, schema)
    local provider = AI.getProvider(cfg.provider)
    if not provider then
        return nil, { kind = "config", message = "unknown provider" }
    end
    if not cfg.key then
        return nil, { kind = "config", message = "no API key" }
    end
    if not cfg.model or cfg.model == "" then
        return nil, { kind = "config", message = "no model" }
    end
    if provider.style == "gemini" then
        return geminiRequest(cfg, system, user)
    elseif provider.style == "anthropic" then
        return anthropicRequest(cfg, system, user, schema)
    end
    if not cfg.base_url or cfg.base_url == "" then
        return nil, { kind = "config", message = "no base URL" }
    end
    return openaiRequest(cfg, system, user)
end

--- Settings → request config, or nil + reason.
function AI.configFrom(settings)
    local provider = AI.getProvider(settings.ai_provider or "gemini")
    if not provider then return nil, "provider" end
    local fallback = (settings.ai_fallback_models or {})[provider.id]
    if fallback == nil then fallback = provider.fallback_model end
    local cfg = {
        provider = provider.id,
        model = (settings.ai_models or {})[provider.id] or provider.default_model,
        fallback_model = fallback ~= "" and fallback or nil,
        base_url = provider.base_url or settings.ai_custom_url,
        key = AI.getKey(provider.id),
        -- Setting "on overload": "wait" (default) stays with the chosen model,
        -- "switch" may try the provider's other models.
        switch_models = settings.ai_on_overload == "switch",
    }
    if not cfg.key then return nil, "key", cfg end
    if not cfg.model or cfg.model == "" then return nil, "model", cfg end
    if not cfg.base_url and provider.style == "openai" then return nil, "url", cfg end
    return cfg
end

-- Extract the JSON object from a model answer (tolerates ```json fences or stray text).
function AI.parseJSON(text)
    if type(text) ~= "string" then return nil end
    local ok, parsed = pcall(json.decode, text)
    if ok and type(parsed) == "table" then return parsed end
    local first, last = text:find("{", 1, true), nil
    for i = #text, 1, -1 do
        if text:sub(i, i) == "}" then last = i break end
    end
    if first and last and last > first then
        ok, parsed = pcall(json.decode, text:sub(first, last))
        if ok and type(parsed) == "table" then return parsed end
    end
    logger.warn("StoryRecall: could not parse AI answer")
end

return AI
