-- Story-Lexikon ohne KOReader: Kreaturen, Fakten aus der Kapitel-Zusammenfassung
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../storyrecall.koplugin/?.lua;" .. package.path
for _, m in ipairs({ "docsettings", "luasettings", "libs/libkoreader-lfs", "util" }) do package.loaded[m] = {} end
local Store = require("storyrecall/store")
local function ok(n, c) print(c and "PASS" or "FAIL", n) end

local data = { ai_chapters = {
    a = { index = 1, title = "Eins", summary = "Mara trifft Tom im Lager. Sie jagen einen Raptor.",
        entities = {
            { name = "Mara", type = "character", aliases = {}, facts = { "Sie ist Jägerin." } },
            { name = "Tom", type = "character", aliases = { "Tommy" }, facts = { "Er ist Schmied." } },
            { name = "Raptor – Level 12", type = "character", aliases = {}, facts = { "Ein Raubtier." } },
            { name = "Raptor Level 14", type = "character", aliases = {}, facts = { "Noch einer." } },
            { name = "Wolf", type = "creature", aliases = {}, facts = { "Ein Wolf." } },
            { name = "Lager", type = "place", aliases = {}, facts = { "Hier wohnen alle." } },
        } },
    b = { index = 2, title = "Zwei", summary = "Mara übt allein. Tommy verschwindet nachts aus dem Lager! Niemand weiß, wohin Tom ging. Tomate gibt es zum Essen.",
        entities = {
            { name = "Mara", type = "character", aliases = {}, facts = { "Sie übt." } },
        } },
} }
-- getChapterNotes needs the real method; give it the data it reads.
local store = setmetatable({ data = data }, Store)
local profiles = store:getEntityProfiles(2)
local by = {}
for _, p in ipairs(profiles) do by[p.name] = p end

ok("Raptor mit Level wird Kreatur", by["Raptor"] and by["Raptor"].type == "creature")
ok("Raptor-Stufen zu einem Eintrag", by["Raptor"] and #by["Raptor"].facts == 2)
ok("Kreatur-Typ der KI bleibt", by["Wolf"] and by["Wolf"].type == "creature")
ok("Mara ohne Level bleibt Figur", by["Mara"].type == "character")
local tom = by["Tom"]
local from_summary = {}
for _, f in ipairs(tom.facts) do if f.from_summary then table.insert(from_summary, f.text) end end
ok("Tom bekommt Sätze aus Kapitel 2", #from_summary == 2)
ok("Satz über den Spitznamen", from_summary[1] == "Tommy verschwindet nachts aus dem Lager!")
ok("Satz über den Namen", from_summary[2] == "Niemand weiß, wohin Tom ging.")
ok("Tomate zählt nicht als Tom", not (from_summary[3]))
ok("Toms letztes Kapitel ist 2", tom.last_index == 2)
local mara_summary = 0
for _, f in ipairs(by["Mara"].facts) do if f.from_summary then mara_summary = mara_summary + 1 end end
ok("Mara (in Kapitel 2 gelistet) bekommt keine Zusatzsätze", mara_summary == 0)
local place_summary = 0
for _, f in ipairs(by["Lager"].facts) do if f.from_summary then place_summary = place_summary + 1 end end
ok("Orte bekommen keine Zusatzsätze", place_summary == 0)
ok("Gespeicherte Notizen unverändert", data.ai_chapters.a.entities[3].type == "character")

-- Kurzform als Zweitname ("Dungeon") darf verschiedene Orte nicht zusammenlegen
local data2 = { ai_chapters = {
    a = { index = 1, title = "Eins", summary = "", entities = {
        { name = "Challenge-Dungeon", type = "place", aliases = { "Dungeon" }, facts = { "Ein Prüfungsort." } },
        { name = "Jake Thayne", type = "character", aliases = { "Jake" }, facts = { "Held." } },
    } },
    b = { index = 2, title = "Zwei", summary = "", entities = {
        { name = "Dachsbau", type = "place", aliases = { "Dungeon" }, facts = { "Ein Bau voller Dachse." } },
        { name = "Jake", type = "character", aliases = {}, facts = { "Er jagt." } },
        { name = "Mr. Thayne", type = "character", aliases = { "Jake Thayne" }, facts = { "So nennt ihn sein Chef." } },
    } },
    c = { index = 3, title = "Drei", summary = "", entities = {
        { name = "Dachsbau-Dungeon", type = "place", aliases = { "Dachsbau" }, facts = { "Der Boss stirbt." } },
    } },
} }
local store2 = setmetatable({ data = data2 }, Store)
local p2 = {}
for _, p in ipairs(store2:getEntityProfiles(3)) do p2[p.name] = p end
ok("Dachsbau bleibt eigener Ort", p2["Dachsbau"] ~= nil and p2["Challenge-Dungeon"] ~= nil)
ok("Dachsbau-Dungeon über echten Zweitnamen zusammengelegt", p2["Dachsbau-Dungeon"] == nil and #p2["Dachsbau"].facts == 2)
ok("Name als Kurzform (Jake) findet weiter Jake Thayne", #p2["Jake Thayne"].facts == 3)
ok("Voller Name als Zweitname legt weiter zusammen", p2["Mr. Thayne"] == nil)
local known = store2:getKnownEntities(3)
local names = {}
for _, k in ipairs(known) do names[k.name] = true end
ok("Liste für die KI trennt die Orte auch", names["Dachsbau"] and names["Challenge-Dungeon"])
