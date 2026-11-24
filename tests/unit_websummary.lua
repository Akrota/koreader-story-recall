-- Unit check of split/extract without KOReader (stubs AI module).
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../storyrecall.koplugin/?.lua;" .. package.path
package.loaded["storyrecall/ai"] = { getProvider = function() return {} end }
local W = require("storyrecall/websummary")
local ok = true
local function check(n, c) print(c and "PASS" or "FAIL", n); ok = ok and c end
local text = "Ich suche...\n### Band 1: Der Anfang\nErster Text.\nNoch mehr.\n\n### Band 2 – Weiter\nZweiter Text.\n### Band 3: Spoiler\nDarf nicht."
local v = W.split(text, 2)
check("three headed volumes, preamble dropped", #v == 3 and v[1].series_index == 1 and v[1].title == "Der Anfang" and v[2].title == "Weiter")
check("body kept", v[1].text == "Erster Text.\nNoch mehr.")
local plain = W.split("Nur ein Absatz ohne Überschrift.", 2)
check("no headings -> fallback index", #plain == 1 and plain[1].series_index == 2)
-- extract: Claude-like
local t, s = W.extract({ content = { { type = "text", text = "### Band 1: A\n" }, { type = "server_tool_use" }, { type = "text", text = "Text", citations = { { type = "web_search_result_location", url = "https://de.wikipedia.org/x", title = "Wikipedia" } } } } })
check("claude extract", t:gsub("\n+", "\n") == "### Band 1: A\nText" and s[1] == "Wikipedia")
-- OpenAI-like
t, s = W.extract({ output = { { type = "web_search_call" }, { type = "message", content = { { type = "output_text", text = "Hallo", annotations = { { type = "url_citation", url = "https://verlag.de/a", title = "" } } } } } } })
check("openai extract", t == "Hallo" and s[1] == "verlag.de")
-- OpenRouter-like
t, s = W.extract({ choices = { { message = { content = "Antwort", annotations = { { type = "url_citation", url_citation = { url = "https://x.org", title = "X" } } } } } } })
check("openrouter extract", t == "Antwort" and s[1] == "X")
-- Gemini interactions-like
t, s = W.extract({ steps = { { type = "google_search_call" }, { type = "model_output", content = { { type = "text", text = "G", annotations = { { type = "url_citation", url = "u", title = "uefa.com" } } } } } } })
check("gemini extract", t == "G" and s[1] == "uefa.com")
-- M10: preamble without newline, then search, then headed text in two blocks
t = W.extract({ content = { { type = "text", text = "I'll search for this." }, { type = "server_tool_use" }, { type = "web_search_tool_result" },
    { type = "text", text = "### Band 1: A\nErster" }, { type = "text", text = " Satz." }, { type = "text", text = "### Band 2: B\nZwei." } } })
local v2 = W.split(t, 2)
check("M10: preamble dropped, both volumes found", #v2 == 2 and v2[1].text == "Erster Satz." and v2[2].series_index == 2)
-- Searching between two volumes keeps volume 1
t = W.extract({ content = { { type = "text", text = "### Band 1: A\nEins." }, { type = "server_tool_use" }, { type = "web_search_tool_result" },
    { type = "text", text = "### Band 2: B\nZwei." } } })
local v3 = W.split(t, 2)
check("search between volumes keeps both", #v3 == 2 and v3[1].text == "Eins." and v3[2].text == "Zwei.")
print(W.prompt({ series = "Primal Hunter", authors = "Zogarth", series_index = 3, title = "Primal Hunter 3" }, "de"))
os.exit(ok and 0 or 1)
