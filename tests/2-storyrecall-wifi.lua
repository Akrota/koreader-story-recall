-- Test (25.10.2026): WLAN bleibt an, solange die KI arbeitet. KOReaders Inaktivitaets-Pruefung
-- (NetworkListener:_scheduleActivityCheck) wird mit nachgestellten Paketzahlen durchgespielt:
-- ohne KI-Arbeit schaltet sie das WLAN ab, waehrend KI-Notizen, "Geschichte bisher neu schreiben"
-- oder "KI fragen" laufen nicht. Danach gilt wieder die normale Regel.
local UIManager = require("ui/uimanager")
local NetworkMgr = require("ui/network/manager")
-- Der Emulator hat kein WLAN-Schalten, dann laedt KOReader die Pruefung gar nicht: fuer den Test
-- mit WLAN-Schalter neu laden (wie auf dem Kobo).
local Device = require("device")
local had_toggle = Device.hasWifiToggle
Device.hasWifiToggle = function() return true end
package.loaded["ui/network/networklistener"] = nil
local NetworkListener = require("ui/network/networklistener")
Device.hasWifiToggle = had_toggle
local OUT = os.getenv("STORYRECALL_TEST_OUT") or "."
local f = io.open(OUT .. "/wifi-results.txt", "w")
local function log(...) local p = {} for i = 1, select("#", ...) do p[#p+1] = tostring(select(i, ...)) end f:write(table.concat(p, " ") .. "\n"); f:flush() end
local function check(n, ok) log(ok and "PASS" or "FAIL", n) end

-- Vor dem Plugin: gleichbleibende Paketzahl (= keine Aktivitaet), Abschalten nur mitzaehlen
local stub = function() return 40 end
NetworkListener._getTxPackets = stub
local disabled = 0
NetworkMgr.disableWifi = function() disabled = disabled + 1 end

local function round(last)
    NetworkListener._last_tx_packets = last
    NetworkListener._activity_check_delay_seconds = nil
    NetworkListener:_scheduleActivityCheck()
    UIManager:unschedule(NetworkListener._scheduleActivityCheck)
end

UIManager:scheduleIn(4, function()
  local ok, e = pcall(function()
    local ui = require("apps/reader/readerui").instance
    local p = ui.storyrecall
    local processor = p.processor
    processor:stop("idle")
    check("Story Recall haengt sich in die Pruefung ein", NetworkListener._getTxPackets ~= stub)

    round(40)
    check("ohne KI-Arbeit: WLAN wird abgeschaltet", disabled == 1)

    processor.state = "running"
    round(40)
    check("KI-Notizen laufen: WLAN bleibt an", disabled == 1)
    check("Pruefung uebersprungen (keine Messung)", NetworkListener._last_tx_packets == nil)
    processor.state = "waiting_retry"
    round(40)
    check("Pause vor neuem Versuch: WLAN bleibt an", disabled == 1)
    processor.state = "idle"

    p.recap_job = { cancel = function() end }
    round(40)
    check("Geschichte bisher neu schreiben: WLAN bleibt an", disabled == 1)
    p.recap_job = nil
    p.lookup_job = { cancel = function() end }
    round(40)
    check("KI fragen: WLAN bleibt an", disabled == 1)
    p.lookup_job = nil

    -- Danach normale Regel: erste Runde misst nur (vorher keine Messung), zweite schaltet ab
    round(nil)
    check("nach der KI-Arbeit: erste Runde misst nur", disabled == 1 and NetworkListener._last_tx_packets == 40)
    round(40)
    check("nach der KI-Arbeit: wieder normal abgeschaltet", disabled == 2)

    -- Einschlafen: waehrend die KI arbeitet pausiert, sonst normal
    local PluginShare = require("pluginshare")
    processor:setState("running")
    check("KI arbeitet: Einschlafen pausiert", PluginShare.pause_auto_suspend == true)
    processor:setState("waiting_retry", "server")
    check("Pause vor neuem Versuch: Einschlafen normal", not PluginShare.pause_auto_suspend)
    processor:setState("running")
    processor:stop("stopped")
    check("gestoppt: Einschlafen normal", not PluginShare.pause_auto_suspend)
    PluginShare.pause_auto_suspend = true
    processor:setState("running")
    processor:setState("idle")
    check("fremde Pause bleibt stehen", PluginShare.pause_auto_suspend == true)
    PluginShare.pause_auto_suspend = false

    -- Buch zu: Story Recall haelt nichts mehr fest
    local WifiHold = require("storyrecall/wifihold")
    processor.state = "running"
    check("haelt vor dem Schliessen", WifiHold.isHeld())
    p:onCloseDocument()
    check("nach dem Schliessen haelt nichts mehr", not WifiHold.isHeld())
  end)
  if not ok then log("ERROR", e) end
  f:close()
  UIManager:quit()
end)
