-- Nachtest (Windows-Claude): Buch schliessen, waehrend ein Unterprozess laeuft.
-- MODE=web: Internet-Zusammenfassung (H3), MODE=ai: KI-Verarbeitung (M1, Abbruch).
-- Erwartung: kein Absturz, kein Zombie, Ruhemodus-Sperre wieder frei.
local UIManager = require("ui/uimanager")
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local MODE = os.getenv("ABBRUCH_MODE") or "web"
local f = io.open(OUT .. "/abbruch-" .. MODE .. "-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end
local function zombies()
    local h = io.popen("ps -eo stat= | grep -c '^Z'")
    local n = tonumber(h:read("*a")) or -1
    h:close()
    return n
end
local function children()
    local h = io.popen("ps -eo ppid=,pid=,stat=,cmd= | awk -v p=" .. require("ffi").C.getpid() .. " '$1 == p'")
    local s = h:read("*a"); h:close()
    return s
end

-- KOReader startet in der Bibliothek und oeffnet das Buch selbst. So kehrt es nach dem Schliessen
-- in die Bibliothek zurueck (wie auf dem Kobo), statt sich zu beenden.
local BOOK = os.getenv("ABBRUCH_BOOK")
UIManager:scheduleIn(3, function()
    if BOOK and not require("apps/reader/readerui").instance then
        require("apps/reader/readerui"):showReader(BOOK)
    end
end)

UIManager:scheduleIn(9, function()
    local ok, err = pcall(function()
        local ui = require("apps/reader/readerui").instance
        local p = ui and ui.storyrecall
        check("plugin geladen", p ~= nil)
        local standby_before = UIManager._prevent_standby_count or 0
        log("Ruhemodus-Sperren vorher:", standby_before, "Zombies vorher:", zombies())
        if MODE == "web" then
            -- Internet-Zusammenfassung, die im Unterprozess 5 s braucht
            require("storyrecall/websummary").run = function()
                os.execute("sleep 5")
                return { { series_index = 1, title = "Band 1", text = "Text" } }, {}
            end
            require("ui/network/manager").runWhenConnected = function(_self, cb) cb() end
            p:createWebSummary(p:getBookInfo(), {})
            check("Auftrag laeuft im Unterprozess", p.web_job ~= nil and p.web_job.pid ~= nil)
        else
            -- KI-Verarbeitung, deren Anfrage im Unterprozess 5 s braucht
            local AI = require("storyrecall/ai")
            AI.complete = function() os.execute("sleep 5"); return nil, { kind = "network", message = "test" } end
            AI.setKey("gemini", "test-key-not-real")
            p:setSetting("ai_provider", "gemini"); p:setSetting("ai_delay", 0)
            local started, reason = p.processor:start()
            log("Verarbeitung gestartet:", started, reason, p.processor.state)
        end
        UIManager:scheduleIn(2, function()
            log("Kindprozesse vor dem Schliessen:\n" .. children())
            check("Ruhemodus waehrend der Anfrage gesperrt", (UIManager._prevent_standby_count or 0) > standby_before)
            -- Wie "Startseite" auf dem Kobo: Buch schliessen und sofort die Bibliothek zeigen,
            -- sonst beendet sich KOReader, weil kein Fenster mehr offen ist.
            local job_pid = (p.web_job and p.web_job.pid) or (p.processor and p.processor.child and p.processor.child.pid)
            log("Auftrags-Prozess:", job_pid)
            ui:onClose()
            log("Buch geschlossen, Ruhemodus-Sperren direkt danach:", UIManager._prevent_standby_count)
            check("Ruhemodus-Sperre direkt nach dem Schliessen frei", (UIManager._prevent_standby_count or 0) == standby_before)
            require("apps/filemanager/filemanager"):showFiles(os.getenv("ABBRUCH_DIR") or (BOOK and BOOK:match("(.*)/")) or ".")
            UIManager:scheduleIn(10, function()
                local z = zombies()
                local rest = children()
                log("Kindprozesse 10 s nach dem Schliessen:\n" .. rest)
                check("KOReader laeuft noch (kein Absturz)", true)
                if job_pid then
                    local h = io.popen("ps -o stat= -p " .. job_pid); local st = h:read("*a"); h:close()
                    check("Auftrags-Prozess beendet und eingesammelt", st:gsub("%s", "") == "")
                else
                    check("Auftrags-Prozess bekannt", false)
                end
                log("(Weitere Zombies/Sperren nachher koennen von der Bibliothek stammen, z. B. Cover-Erzeugung)")
                log("Ruhemodus-Sperren nachher:", UIManager._prevent_standby_count, "Zombies:", z)
                if MODE == "ai" then require("storyrecall/ai").setKey("gemini", nil) end
                f:close()
                UIManager:quit()
            end)
        end)
    end)
    if not ok then log("ERROR", err); f:close(); UIManager:quit() end
end)
