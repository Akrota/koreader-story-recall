-- Comics bekommen kein Story Recall (Wunsch des Nutzers, 04.11.2026): Ein Band ist dort meist ein
-- Kapitel, die Rueckblick-Frage kaeme bei jedem Band. Gilt fuer alle Funktionen.
local Comic = {}

local EXT = { cbz = true, cbr = true, cb7 = true, cbt = true }

--- Ist die Datei ein Comic-Archiv?
function Comic.isComic(file)
    if type(file) ~= "string" then return false end
    local ext = (file:match("%.([^./]+)$") or ""):lower()
    return EXT[ext] == true
end

return Comic
