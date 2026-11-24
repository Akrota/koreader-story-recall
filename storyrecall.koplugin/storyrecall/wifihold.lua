--[[--
Keeps KOReader from turning Wi-Fi off for inactivity while the AI works.

KOReader checks every few minutes how many packets were sent
(NetworkListener:_getTxPackets) and turns Wi-Fi off when hardly any were.
While waiting 1–3 minutes for an AI answer almost nothing is sent, so Wi-Fi
went off in the middle of a request. While a holder says so, the check gets
"no reading" and is skipped; afterwards KOReader's normal rule applies again.
If a KOReader update removes that function, nothing is hooked in.
--]]

local logger = require("logger")

local WifiHold = {}

local holders = {}
local hook_ok -- nil: not tried yet

function WifiHold.isHeld()
    for _, fn in pairs(holders) do
        local ok, yes = pcall(fn)
        if ok and yes then return true end
    end
    return false
end

--- Hook into KOReader's inactivity check (once).
-- @return true if the hook is in place
function WifiHold.install()
    if hook_ok ~= nil then return hook_ok end
    local ok, NetworkListener = pcall(require, "ui/network/networklistener")
    if not ok or type(NetworkListener) ~= "table" or type(NetworkListener._getTxPackets) ~= "function" then
        logger.info("StoryRecall: KOReader's Wi-Fi activity check not found, not hooking in")
        hook_ok = false
        return false
    end
    local orig = NetworkListener._getTxPackets
    NetworkListener._getTxPackets = function(...)
        if WifiHold.isHeld() then
            logger.dbg("StoryRecall: AI at work, skipping the Wi-Fi inactivity check")
            return nil
        end
        return orig(...)
    end
    hook_ok = true
    return true
end

--- Keep Wi-Fi on while fn() returns true; nil removes the holder.
function WifiHold.set(key, fn)
    holders[key] = fn
end

return WifiHold
