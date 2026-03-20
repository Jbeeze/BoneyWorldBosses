-- WorldBossAnnouncer: World Boss Announcer for Discord (v2)
-- Target: TBC Anniversary (Interface 20504)
-- Uses WoW's built-in chat logging for real-time alerts

local ADDON_NAME = "WorldBossAnnouncer"
local VERSION = "2.0.0"

-- Create hidden frame for event handling
local frame = CreateFrame("Frame")

-- Track logging state (LoggingChat() doesn't have a getter)
local isLoggingEnabled = false

-- Initialize on addon load
local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then return end

    -- Auto-enable chat logging
    LoggingChat(true)
    isLoggingEnabled = true

    print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " loaded.")
    print("|cff00ff00[WorldBossAnnouncer]|r Chat logging |cff00ff00ENABLED|r (auto)")
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
            LoggingChat(true)
            isLoggingEnabled = true
            print("|cff00ff00[WorldBossAnnouncer]|r Chat logging |cff00ff00ENABLED|r")
            print("|cff00ff00[WorldBossAnnouncer]|r Logs written to: WoW/_classic_/Logs/WoWChatLog.txt")
        elseif setting == "off" then
            LoggingChat(false)
            isLoggingEnabled = false
            print("|cff00ff00[WorldBossAnnouncer]|r Chat logging |cffff0000DISABLED|r")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba logging on/off")
        end

    elseif cmd == "status" then
        print("|cff00ff00[WorldBossAnnouncer]|r Status:")
        print("  Chat logging: " .. (isLoggingEnabled and "|cff00ff00ENABLED|r" or "|cffff0000DISABLED|r"))
        print("  Log file: WoW/_classic_/Logs/WoWChatLog.txt")

    else
        print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wba logging on  - Enable chat logging")
        print("  /wba logging off - Disable chat logging")
        print("  /wba status      - Show logging status")
        print("")
        print("  How it works:")
        print("  1. Addon enables WoW's chat logging (writes to WoWChatLog.txt)")
        print("  2. bridge.py tails the log file and detects boss alerts")
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
