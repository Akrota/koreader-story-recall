-- Reihen-Lexikon ohne KOReader: Band 1 wird im Lexikon von Band 2 weitergefuehrt (Stufe 1),
-- Eintraege aus Band 1 gehen nur mit, wenn der gesendete Text sie nennt (Stufe 2).
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../storyrecall.koplugin/?.lua;" .. package.path
for _, m in ipairs({ "docsettings", "luasettings", "libs/libkoreader-lfs", "datastorage" }) do package.loaded[m] = {} end
package.loaded["util"] = { fixUtf8 = function(s) return s end }
package.loaded["logger"] = { dbg = function() end, warn = function() end, info = function() end }
local Store = require("storyrecall/store")
local Series = require("storyrecall/series")
local Prompt = require("storyrecall/prompt")
local failed = 0
local function ok(n, c, extra)
    print(c and "PASS" or "FAIL", n, c and "" or tostring(extra or ""))
    if not c then failed = failed + 1 end
end

-- Band 1: gelesen bis Kapitel 3 (abgeschlossen), Kapitel 4 nicht gelesen
local band1 = {
    furthest_chapter = 3,
    chapters = { k3 = { completed_at = 1 } },
    ai_chapters = {
        k1 = { key = "k1", index = 1, title = "Anfang", summary = "x", entities = {
            { name = "Carl", type = "character", aliases = {}, facts = { "Carl ist ein Mann aus Seattle." } },
            { name = "Prinzessin Donut", type = "character", aliases = { "Donut" }, facts = { "Donut ist eine Katze." } },
            { name = "Mongo", type = "creature", aliases = {}, facts = { "Ein Dinosaurier." } },
        } },
        k2 = { key = "k2", index = 2, title = "Dungeon", summary = "x", entities = {
            { name = "Donut", type = "character", aliases = {}, facts = { "Donut kann sprechen." }, status = "verletzt" },
            { name = "Mordecai", type = "character", aliases = {}, facts = { "Mordecai ist ihr Betreuer." } },
        } },
        k3 = { key = "k3", index = 3, title = "Ende", summary = "x", entities = {
            { name = "Carl", type = "character", aliases = {}, facts = { "Carl verliert seine Hose." } },
        } },
        k4 = { key = "k4", index = 4, title = "Ungelesen", summary = "x", entities = {
            { name = "Geheimnis", type = "character", aliases = {}, facts = { "Spoiler!" } },
        } },
    },
}
local lex1 = Series.volumeLexicon(band1)
ok("Band 1: nur gelesene Kapitel (1-3)", #lex1 == 3 and lex1[3].index == 3, #lex1)
local spoiler = false
for _, n in ipairs(lex1) do for _, e in ipairs(n.entities) do if e.name == "Geheimnis" then spoiler = true end end end
ok("Band 1: ungelesenes Kapitel kommt nicht ins Lexikon", not spoiler)

-- Als "beendet" markiert (z. B. woanders gelesen): ganzer Band zaehlt
local lex_done = Series.volumeLexicon(Series.asFinished(band1))
ok("Beendet markiert: alle 4 Kapitel", #lex_done == 4, #lex_done)
ok("Beendet markiert: Original-Daten unveraendert", band1.marked_finished == nil)
ok("Beendet markiert: Band-Zusammenfassung sieht das Ende",
    Series.noteVisible(Series.asFinished(band1), band1.ai_chapters.k4) and not Series.noteVisible(band1, band1.ai_chapters.k4))

local earlier = { { series_index = 1, title = "Band eins", notes = lex1 } }

-- Band 2 mit eigenen Notizen
local band2 = { ai_chapters = {
    m1 = { key = "m1", index = 1, title = "Neu", summary = "Donut schläft.", entities = {
        { name = "Prinzessin Donut", type = "character", aliases = {}, facts = { "Donut ist wieder gesund." }, status = "gesund" },
        { name = "Katia", type = "character", aliases = {}, facts = { "Katia ist neu." } },
    } },
} }
local store = setmetatable({ data = band2 }, Store)
local profiles = store:getEntityProfiles(1, earlier)
local by = {}
for _, p in ipairs(profiles) do by[p.name] = p end
local donut = by["Prinzessin Donut"]
ok("Ein Eintrag fuer Donut ueber beide Baende", donut ~= nil and by["Donut"] == nil)
ok("Donuts Fakten sammeln sich an (2 aus Band 1, 1 aus Band 2)", donut and #donut.facts == 3, donut and #donut.facts)
ok("Erster Fakt aus Band 1", donut and donut.facts[1].volume == 1 and donut.facts[3].volume == nil)
ok("Zuerst gesehen in Band 1", donut and donut.first_volume == 1 and donut.first_index == 1)
ok("Neuester Zustand aus Band 2", donut and donut.status and donut.status.text == "gesund" and donut.status.volume == nil)
ok("Zuletzt gesehen in Band 2", donut and donut.last_volume == nil and donut.last_index == 1)
ok("Carl nur aus Band 1 bleibt im Lexikon", by["Carl"] and by["Carl"].last_volume == 1 and #by["Carl"].facts == 2)
ok("Neue Figur aus Band 2", by["Katia"] and by["Katia"].first_volume == nil)
ok("Reihenfolge 'zuletzt' ueber Baende: Donut nach Carl", donut.last_order > by["Carl"].last_order)
ok("Ohne fruehere Baende wie bisher", #store:getEntityProfiles(1) == 2)
ok("Gespeicherte Notizen unveraendert", band1.ai_chapters.k2.entities[1].name == "Donut" and lex1[1].entities[1].volume == nil)

-- Stufe 2: nur genannte Eintraege aus Band 1
local known = store:getKnownEntities(1)
local text = "Carls Hose ist weg. Die Prinzessin schnurrt. Mordecais Zimmer ist leer. Mongolei liegt fern."
local mentioned = Store.earlierMentioned(earlier, known, text)
local names = {}
for _, e in ipairs(mentioned) do names[e.name] = e end
ok("Carl genannt (Genitiv 'Carls')", names["Carl"] ~= nil)
ok("Mordecai genannt (Genitiv 'Mordecais')", names["Mordecai"] ~= nil)
ok("Donut kennt Band 2 schon -> nicht doppelt", names["Prinzessin Donut"] == nil)
ok("Mongo nicht durch 'Mongolei'", names["Mongo"] == nil)
ok("Band und letzter Fakt dabei", names["Carl"] and names["Carl"].volume == 1 and names["Carl"].last_fact == "Carl verliert seine Hose.")
ok("Nichts genannt -> nichts mitgeschickt", #Store.earlierMentioned(earlier, known, "Ein ganz anderes Kapitel.") == 0)
ok("Ohne fruehere Baende -> nichts", #Store.earlierMentioned({}, known, text) == 0)

-- Prompt: Markierung nur, wenn Eintraege aus frueheren Baenden dabei sind
local all = {}
for _, e in ipairs(known) do table.insert(all, e) end
for _, e in ipairs(mentioned) do table.insert(all, e) end
local msg = Prompt.build{ book = { title = "B2" }, chapters = { { index = 2, title = "T", text = text } },
    previous = {}, known = all }
ok("Prompt: Hinweis auf fruehere Baende", msg:find("earlier volume of the series", 1, true) ~= nil)
ok("Prompt: Carl mit Band", msg:find("- Carl (character): [vol. 1, ch. 3] Carl verliert seine Hose.", 1, true) ~= nil)
ok("Prompt: Katia wie bisher", msg:find("- Katia (character): [1] Katia ist neu.", 1, true) ~= nil)
local plain = Prompt.build{ book = { title = "B2" }, chapters = { { index = 2, title = "T", text = text } },
    previous = {}, known = known }
ok("Prompt ohne fruehere Baende: kein Hinweis", plain:find("earlier volume of the series", 1, true) == nil)

print(failed == 0 and "ALLE BESTANDEN" or ("FEHLGESCHLAGEN: " .. failed))
os.exit(failed == 0 and 0 or 1)
