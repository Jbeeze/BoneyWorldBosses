-- WorldBossAnnouncer: World Boss Announcer for Discord (v3)
-- Target: TBC Anniversary (Interface 20504)
-- Uses WoW's built-in combat logging for real-time boss detection

local ADDON_NAME = "WorldBossAnnouncer"
local VERSION = "3.0.0"

-- Create hidden frame for event handling
local frame = CreateFrame("Frame")

-- Track logging state (LoggingCombat() doesn't have a getter)
local isLoggingEnabled = false

-- Initialize on addon load
local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then return end

    -- Auto-enable combat logging
    LoggingCombat(true)
    isLoggingEnabled = true

    print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " loaded.")
    print("|cff00ff00[WorldBossAnnouncer]|r Combat logging |cff00ff00ENABLED|r (auto)")
    print("|cff00ff00[WorldBossAnnouncer]|r Type /wba for commands.")
end

-- Slash command handler
local function SlashHandler(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, string.lower(word))
    end

    local cmd = args[1]

    if cmd == "logging" then
        local setting = args[2]
        if setting == "on" then
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[WorldBossAnnouncer]|r Combat logging |cff00ff00ENABLED|r")
            print("|cff00ff00[WorldBossAnnouncer]|r Logs written to: WoW/_anniversary_/Logs/WoWCombatLog.txt")
        elseif setting == "off" then
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[WorldBossAnnouncer]|r Combat logging |cffff0000DISABLED|r")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba logging on/off")
        end

    elseif cmd == "status" then
        print("|cff00ff00[WorldBossAnnouncer]|r Status:")
        print("  Combat logging: " .. (isLoggingEnabled and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))
        print("  Log file: WoW/_anniversary_/Logs/WoWCombatLog.txt")

    else
        print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wba logging on  - Enable combat logging")
        print("  /wba logging off - Disable combat logging")
        print("  /wba status      - Show logging status")
        print("")
        print("  How it works:")
        print("  1. Addon enables WoW's combat logging (writes to WoWCombatLog.txt)")
        print("  2. bridge.py tails the log file and detects boss NPC IDs")
        print("  3. Alerts are sent to Discord in real-time (no /reload needed!)")
    end
end

-- Register slash commands
SLASH_WORLDBOSSANNOUNCER1 = "/worldbossannouncer"
SLASH_WORLDBOSSANNOUNCER2 = "/wba"
SlashCmdList["WORLDBOSSANNOUNCER"] = SlashHandler

-- Register events
frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(...)
    end
end)
