-- "Geschichte bisher neu schreiben" ohne KOReader (25.10.2026): Aufteilung in Drittel/Viertel
-- nach Kapitelzahl, Saetze pro Teil wachsen mit dem Lesestand, Anfrage mit Teil-Ueberschriften.
local here = (arg and arg[0] or ""):match("^(.*)[/\\][^/\\]*$") or "."
package.path = here .. "/../storyrecall.koplugin/?.lua;" .. package.path
package.loaded["util"] = {}
local Prompt = require("storyrecall/prompt")
local function ok(n, c) print(c and "PASS" or "FAIL", n) end

local function ranges(plan)
    local t = {}
    for _, r in ipairs(plan.ranges) do t[#t + 1] = r[1] .. "-" .. r[2] end
    return table.concat(t, " ")
end

local p = Prompt.recapPlan(3)
ok("3 Kapitel: ein Teil, 3-5 Saetze", p.parts == 1 and p.min == 3 and p.max == 5 and ranges(p) == "1-3")
p = Prompt.recapPlan(5)
ok("5 Kapitel: noch ein Teil", p.parts == 1)
p = Prompt.recapPlan(6)
ok("6 Kapitel: Drittel 1-2 3-4 5-6, je 2-3", p.parts == 3 and ranges(p) == "1-2 3-4 5-6" and p.min == 2 and p.max == 3)
p = Prompt.recapPlan(20)
ok("20 Kapitel: je 2-3", p.min == 2 and p.max == 3 and ranges(p) == "1-7 8-13 14-20")
p = Prompt.recapPlan(30)
ok("30 Kapitel: 1-10 11-20 21-30, je etwa 3", ranges(p) == "1-10 11-20 21-30" and p.min == 3 and p.max == 3)
p = Prompt.recapPlan(72)
ok("72 Kapitel: 1-24 25-48 49-72, je 4-5", ranges(p) == "1-24 25-48 49-72" and p.min == 4 and p.max == 5)
p = Prompt.recapPlan(100)
ok("100 Kapitel: je 5-7", p.parts == 3 and p.min == 5 and p.max == 7 and ranges(p) == "1-33 34-67 68-100")
p = Prompt.recapPlan(121)
ok("121 Kapitel: Viertel, je 5-7", p.parts == 4 and p.min == 5 and p.max == 7 and ranges(p) == "1-30 31-61 62-91 92-121")
p = Prompt.recapPlan(500)
ok("500 Kapitel: luckenlos bis 500", p.parts == 4 and p.ranges[4][2] == 500)

-- Anfrage: Teile mit echten Kapitelnummern (auch wenn die Zaehlung nicht bei 1 beginnt)
local chapters = {}
for i = 1, 30 do chapters[i] = { index = i + 2, title = "K" .. i, summary = "S" .. i .. "." } end
local msg = Prompt.buildRecap{ book = { title = "B" }, notes_language = "de", chapters = chapters }
ok("Anfrage nennt Aufbau", msg:find("Write 3 plot paragraphs, one per part and in order, each about 3 sentences", 1, true) ~= nil)
ok("Anfrage: 4 Absaetze insgesamt", msg:find("4 paragraphs in total", 1, true) ~= nil)
ok("Teil 1: Kapitel 3 bis 12", msg:find("Part 1 of 3 (chapters 3 to 12)", 1, true) ~= nil)
ok("Teil 3: Kapitel 23 bis 32", msg:find("Part 3 of 3 (chapters 23 to 32)", 1, true) ~= nil)
ok("alle Zusammenfassungen dabei, in Reihenfolge", msg:find("[3] K1: S1.", 1, true) < msg:find("[32] K30: S30.", 1, true))
local count = 0
for _ in msg:gmatch("%[%d+%] K") do count = count + 1 end
ok("jede Zusammenfassung genau einmal", count == 30)

msg = Prompt.buildRecap{ book = { title = "B" }, notes_language = "de", chapters = { chapters[1], chapters[2], chapters[3] } }
ok("kurz: ein Absatz Handlung, keine Teile", msg:find("one plot paragraph of 3 to 5 sentences", 1, true) ~= nil and not msg:find("Part 1", 1, true))
ok("Systemtext: lieber kuerzer als aufgefuellt", Prompt.RECAP_SYSTEM:find("rather shorter than padded", 1, true) ~= nil)
ok("Systemtext: keine Teil-Ueberschriften", Prompt.RECAP_SYSTEM:find("no part labels", 1, true) ~= nil)
-- Stil-Regeln (25.10. abends), fuer alle Genres und Sprachen
ok("Systemtext: erzaehlen statt aufzaehlen", Prompt.RECAP_SYSTEM:find("cause and consequence", 1, true) ~= nil)
ok("Systemtext: Figuren beim ersten Auftreten einordnen", Prompt.RECAP_SYSTEM:find("When a character first appears", 1, true) ~= nil)
ok("Systemtext: Verdacht bleibt Verdacht, nichts erfinden", Prompt.RECAP_SYSTEM:find("a suspicion stays a suspicion", 1, true) ~= nil)
ok("Systemtext: Praesens, Sprache der Notizen, Begriffe des Buchs bleiben", Prompt.RECAP_SYSTEM:find("present tense", 1, true) ~= nil
    and Prompt.RECAP_SYSTEM:find("the book's own terms stay", 1, true) ~= nil)
-- Kuerzung (28.10.): "Zuletzt" 2-3 Saetze, 72 Kapitel je 4-5
ok("Zuletzt 2-3 Saetze", msg:find("(2 to 3 sentences)", 1, true) ~= nil and Prompt.RECAP_SYSTEM:find("2 to 3 sentences", 1, true) ~= nil)
local c72 = {}
for i = 1, 72 do c72[i] = { index = i, title = "K", summary = "S." } end
ok("72 Kapitel: Anfrage je 4 bis 5 Saetze", Prompt.buildRecap{ book = { title = "B" }, chapters = c72 }:find("each 4 to 5 sentences", 1, true) ~= nil)
