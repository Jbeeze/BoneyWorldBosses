-- WorldBossAnnouncer: World Boss Announcer for Discord
-- Target: TBC Anniversary (Interface 20504)
-- Detects Doom Lord Kazzak activity and forwards to Discord

local ADDON_NAME = "WorldBossAnnouncer"
local VERSION = "1.0.0"

-- World boss configuration
local WORLD_BOSSES = {
    ["Doom Lord Kazzak"] = true,
    ["Doomwalker"] = true,  -- Can add more world bosses
}

-- Keywords to watch for in general chat (case-insensitive)
local KEYWORDS = {
    "kazzak",
    "doomwalker",
}

-- Default configuration
local DEFAULT_CONFIG = {
    enabled = true,
    maxQueue = 200,
    autoReload = true,
    autoReloadInterval = 120,
    watchBossYells = true,
    watchGeneralChat = true,
}

-- Channel labels for each event type
local CHANNEL_LABELS = {
    CHAT_MSG_MONSTER_YELL = "boss_yell",
    CHAT_MSG_CHANNEL = "general",
}

-- Create hidden frame for event handling
local frame = CreateFrame("Frame")
local autoReloadTicker = nil

-- Initialize saved variables
local function InitializeDB()
    if not WorldBossAnnouncerDB then
        WorldBossAnnouncerDB = {}
    end

    if not WorldBossAnnouncerDB.config then
        WorldBossAnnouncerDB.config = CopyTable(DEFAULT_CONFIG)
    end

    if not WorldBossAnnouncerDB.queue then
        WorldBossAnnouncerDB.queue = {}
    end

    if not WorldBossAnnouncerDB.meta then
        WorldBossAnnouncerDB.meta = {
            lastId = 0,
            playerName = UnitName("player"),
            realmName = GetRealmName(),
        }
    end

    -- Update player info on each login
    WorldBossAnnouncerDB.meta.playerName = UnitName("player")
    WorldBossAnnouncerDB.meta.realmName = GetRealmName()
end

-- Check if message contains any watched keywords
local function ContainsKeyword(msg)
    local lowerMsg = string.lower(msg)
    for _, keyword in ipairs(KEYWORDS) do
        if string.find(lowerMsg, keyword, 1, true) then
            return keyword
        end
    end
    return nil
end

-- Add message to queue
local function QueueMessage(event, author, msg, channel, extra)
    if not WorldBossAnnouncerDB.config.enabled then return end

    -- Increment ID
    WorldBossAnnouncerDB.meta.lastId = WorldBossAnnouncerDB.meta.lastId + 1

    -- Create queue entry
    local entry = {
        id = WorldBossAnnouncerDB.meta.lastId,
        t = time(),
        event = event,
        author = author or "Unknown",
        msg = msg or "",
        channel = channel or "unknown",
        zone = GetZoneText(),
        subzone = GetSubZoneText(),
    }

    -- Add extra data if provided
    if extra then
        for k, v in pairs(extra) do
            entry[k] = v
        end
    end

    -- Add to queue
    table.insert(WorldBossAnnouncerDB.queue, entry)

    -- Trim queue if over max
    while #WorldBossAnnouncerDB.queue > WorldBossAnnouncerDB.config.maxQueue do
        table.remove(WorldBossAnnouncerDB.queue, 1)
    end

    -- Alert the player
    print("|cffff0000[WORLD BOSS ALERT]|r " .. author .. ": " .. msg)
    PlaySound(8959) -- RAID_WARNING sound
end

-- Event handler
local function OnEvent(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName == ADDON_NAME then
            InitializeDB()
            SetupAutoReload()
            print("|cff00ff00[WorldBossAnnouncer]|r World Boss Announcer loaded.")
            print("|cff00ff00[WorldBossAnnouncer]|r Watching for: Doom Lord Kazzak, Doomwalker")
            print("|cff00ff00[WorldBossAnnouncer]|r Type /discordbridge for commands.")
        end
        return
    end

    -- Monster yell (world boss speaking)
    if event == "CHAT_MSG_MONSTER_YELL" then
        if not WorldBossAnnouncerDB.config.watchBossYells then return end

        local msg, mobName = ...

        if WORLD_BOSSES[mobName] then
            QueueMessage(event, mobName, msg, "boss_yell", {
                alertType = "BOSS_YELL",
                boss = mobName,
            })
        end
        return
    end

    -- General chat (channel chat)
    if event == "CHAT_MSG_CHANNEL" then
        if not WorldBossAnnouncerDB.config.watchGeneralChat then return end

        local msg, author, _, _, _, _, _, channelIndex, channelName = ...

        -- Check if it's General chat (channel names like "General - Hellfire Peninsula")
        local isGeneral = string.find(string.lower(channelName or ""), "general", 1, true)

        if isGeneral then
            local keyword = ContainsKeyword(msg)
            if keyword then
                -- Strip realm name from author
                author = string.match(author, "([^-]+)") or author

                QueueMessage(event, author, msg, "general", {
                    alertType = "PLAYER_REPORT",
                    keyword = keyword,
                    channelName = channelName,
                })
            end
        end
        return
    end
end

-- Auto-reload functionality
function SetupAutoReload()
    -- Cancel existing ticker if any
    if autoReloadTicker then
        autoReloadTicker:Cancel()
        autoReloadTicker = nil
    end

    if not WorldBossAnnouncerDB.config.autoReload then return end

    local interval = WorldBossAnnouncerDB.config.autoReloadInterval or 120

    autoReloadTicker = C_Timer.NewTicker(interval, function()
        -- Only reload if there are pending messages
        if #WorldBossAnnouncerDB.queue > 0 then
            print("|cff00ff00[WorldBossAnnouncer]|r Auto-reloading to flush " .. #WorldBossAnnouncerDB.queue .. " alert(s)...")
            C_Timer.After(1, function()
                ReloadUI()
            end)
        end
    end)
end

-- Slash command handler
local function SlashHandler(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, string.lower(word))
    end

    local cmd = args[1]

    if cmd == "status" then
        print("|cff00ff00[WorldBossAnnouncer]|r Status:")
        print("  Enabled: " .. (WorldBossAnnouncerDB.config.enabled and "|cff00ff00YES|r" or "|cffff0000NO|r"))
        print("  Queue: " .. #WorldBossAnnouncerDB.queue .. " / " .. WorldBossAnnouncerDB.config.maxQueue)
        print("  Last ID: " .. WorldBossAnnouncerDB.meta.lastId)
        print("  Auto-reload: " .. (WorldBossAnnouncerDB.config.autoReload and "ON" or "OFF") ..
              " (" .. WorldBossAnnouncerDB.config.autoReloadInterval .. "s)")
        print("  Watch boss yells: " .. (WorldBossAnnouncerDB.config.watchBossYells and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        print("  Watch general chat: " .. (WorldBossAnnouncerDB.config.watchGeneralChat and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

    elseif cmd == "flush" then
        local count = #WorldBossAnnouncerDB.queue
        WorldBossAnnouncerDB.queue = {}
        print("|cff00ff00[WorldBossAnnouncer]|r Flushed " .. count .. " messages from queue.")

    elseif cmd == "autoreload" then
        local setting = args[2]
        if setting == "on" then
            WorldBossAnnouncerDB.config.autoReload = true
            SetupAutoReload()
            print("|cff00ff00[WorldBossAnnouncer]|r Auto-reload enabled.")
        elseif setting == "off" then
            WorldBossAnnouncerDB.config.autoReload = false
            SetupAutoReload()
            print("|cff00ff00[WorldBossAnnouncer]|r Auto-reload disabled.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /discordbridge autoreload on/off")
        end

    elseif cmd == "interval" then
        local seconds = tonumber(args[2])
        if seconds and seconds >= 30 then
            WorldBossAnnouncerDB.config.autoReloadInterval = seconds
            SetupAutoReload()
            print("|cff00ff00[WorldBossAnnouncer]|r Auto-reload interval set to " .. seconds .. " seconds.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /discordbridge interval <seconds> (minimum 30)")
        end

    elseif cmd == "enable" then
        WorldBossAnnouncerDB.config.enabled = true
        print("|cff00ff00[WorldBossAnnouncer]|r Enabled.")

    elseif cmd == "disable" then
        WorldBossAnnouncerDB.config.enabled = false
        print("|cff00ff00[WorldBossAnnouncer]|r Disabled.")

    elseif cmd == "bosses" then
        local setting = args[2]
        if setting == "on" then
            WorldBossAnnouncerDB.config.watchBossYells = true
            print("|cff00ff00[WorldBossAnnouncer]|r Boss yell monitoring enabled.")
        elseif setting == "off" then
            WorldBossAnnouncerDB.config.watchBossYells = false
            print("|cff00ff00[WorldBossAnnouncer]|r Boss yell monitoring disabled.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /discordbridge bosses on/off")
        end

    elseif cmd == "general" then
        local setting = args[2]
        if setting == "on" then
            WorldBossAnnouncerDB.config.watchGeneralChat = true
            print("|cff00ff00[WorldBossAnnouncer]|r General chat monitoring enabled.")
        elseif setting == "off" then
            WorldBossAnnouncerDB.config.watchGeneralChat = false
            print("|cff00ff00[WorldBossAnnouncer]|r General chat monitoring disabled.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /discordbridge general on/off")
        end

    elseif cmd == "test" then
        -- Send a test alert (no @everyone ping)
        local playerName = UnitName("player")
        QueueMessage("TEST", playerName, "Test alert - Discord connection working!", "test", {
            alertType = "TEST",
        })
        print("|cff00ff00[WorldBossAnnouncer]|r Testing Discord connection...")

        -- Reload UI to send the test immediately (if not in combat)
        if InCombatLockdown() then
            print("|cffff0000[WorldBossAnnouncer]|r In combat - will reload after combat ends.")
            local combatFrame = CreateFrame("Frame")
            combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
            combatFrame:SetScript("OnEvent", function(self)
                self:UnregisterAllEvents()
                print("|cff00ff00[WorldBossAnnouncer]|r Combat ended, reloading...")
                C_Timer.After(1, ReloadUI)
            end)
        else
            C_Timer.After(1, ReloadUI)
        end

    elseif cmd == "announce" then
        -- Manual announcement: /wba announce <boss> [layer]
        local bossName = args[2]
        local layer = args[3] or "1"

        if not bossName then
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba announce <boss> [layer]")
            print("  Example: /wba announce kazzak 1")
            print("  Bosses: kazzak, doomwalker")
            return
        end

        -- Normalize boss name
        local bosses = {
            kazzak = "Doom Lord Kazzak",
            doomwalker = "Doomwalker",
        }

        local fullBossName = bosses[string.lower(bossName)]
        if not fullBossName then
            print("|cff00ff00[WorldBossAnnouncer]|r Unknown boss: " .. bossName)
            print("  Valid bosses: kazzak, doomwalker")
            return
        end

        local playerName = UnitName("player")
        local zone = GetZoneText()
        local subzone = GetSubZoneText()

        QueueMessage("ANNOUNCE", playerName, fullBossName .. " spotted on Layer " .. layer .. "!", "announce", {
            alertType = "PLAYER_ANNOUNCE",
            boss = fullBossName,
            layer = layer,
            reporter = playerName,
        })

        print("|cffff0000[WORLD BOSS]|r Announced: " .. fullBossName .. " Layer " .. layer)
        PlaySound(8959) -- RAID_WARNING sound

        -- Reload UI to send the alert (if not in combat)
        if InCombatLockdown() then
            print("|cffff0000[WorldBossAnnouncer]|r In combat - will reload after combat ends.")
            local combatFrame = CreateFrame("Frame")
            combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
            combatFrame:SetScript("OnEvent", function(self)
                self:UnregisterAllEvents()
                print("|cff00ff00[WorldBossAnnouncer]|r Combat ended, reloading...")
                C_Timer.After(1, ReloadUI)
            end)
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Reloading UI to send alert...")
            C_Timer.After(1, ReloadUI)
        end

    else
        print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wba announce <boss> [layer] - Announce a boss sighting")
        print("  /wba status - Show status")
        print("  /wba flush - Clear message queue")
        print("  /wba autoreload on/off - Toggle auto-reload")
        print("  /wba interval <seconds> - Set auto-reload interval")
        print("  /wba bosses on/off - Toggle boss yell monitoring")
        print("  /wba general on/off - Toggle general chat monitoring")
        print("  /wba test - Send a test alert")
        print("  /wba enable/disable - Enable or disable addon")
    end
end

-- Register slash commands
SLASH_WORLDBOSSANNOUNCER1 = "/worldbossannouncer"
SLASH_WORLDBOSSANNOUNCER2 = "/wba"
SlashCmdList["WORLDBOSSANNOUNCER"] = SlashHandler

-- Register events
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_MONSTER_YELL")  -- Boss yells
frame:RegisterEvent("CHAT_MSG_CHANNEL")        -- General chat

frame:SetScript("OnEvent", OnEvent)
