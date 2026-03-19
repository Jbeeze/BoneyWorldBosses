-- DiscordBridge: World Boss Announcer for Discord
-- Target: TBC Anniversary (Interface 20504)
-- Detects Doom Lord Kazzak activity and forwards to Discord

local ADDON_NAME = "DiscordBridge"
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
    if not DiscordBridgeDB then
        DiscordBridgeDB = {}
    end

    if not DiscordBridgeDB.config then
        DiscordBridgeDB.config = CopyTable(DEFAULT_CONFIG)
    end

    if not DiscordBridgeDB.queue then
        DiscordBridgeDB.queue = {}
    end

    if not DiscordBridgeDB.meta then
        DiscordBridgeDB.meta = {
            lastId = 0,
            playerName = UnitName("player"),
            realmName = GetRealmName(),
        }
    end

    -- Update player info on each login
    DiscordBridgeDB.meta.playerName = UnitName("player")
    DiscordBridgeDB.meta.realmName = GetRealmName()
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
    if not DiscordBridgeDB.config.enabled then return end

    -- Increment ID
    DiscordBridgeDB.meta.lastId = DiscordBridgeDB.meta.lastId + 1

    -- Create queue entry
    local entry = {
        id = DiscordBridgeDB.meta.lastId,
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
    table.insert(DiscordBridgeDB.queue, entry)

    -- Trim queue if over max
    while #DiscordBridgeDB.queue > DiscordBridgeDB.config.maxQueue do
        table.remove(DiscordBridgeDB.queue, 1)
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
            print("|cff00ff00[DiscordBridge]|r World Boss Announcer loaded.")
            print("|cff00ff00[DiscordBridge]|r Watching for: Doom Lord Kazzak, Doomwalker")
            print("|cff00ff00[DiscordBridge]|r Type /discordbridge for commands.")
        end
        return
    end

    -- Monster yell (world boss speaking)
    if event == "CHAT_MSG_MONSTER_YELL" then
        if not DiscordBridgeDB.config.watchBossYells then return end

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
        if not DiscordBridgeDB.config.watchGeneralChat then return end

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

    if not DiscordBridgeDB.config.autoReload then return end

    local interval = DiscordBridgeDB.config.autoReloadInterval or 120

    autoReloadTicker = C_Timer.NewTicker(interval, function()
        -- Only reload if there are pending messages
        if #DiscordBridgeDB.queue > 0 then
            print("|cff00ff00[DiscordBridge]|r Auto-reloading to flush " .. #DiscordBridgeDB.queue .. " alert(s)...")
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
        print("|cff00ff00[DiscordBridge]|r Status:")
        print("  Enabled: " .. (DiscordBridgeDB.config.enabled and "|cff00ff00YES|r" or "|cffff0000NO|r"))
        print("  Queue: " .. #DiscordBridgeDB.queue .. " / " .. DiscordBridgeDB.config.maxQueue)
        print("  Last ID: " .. DiscordBridgeDB.meta.lastId)
        print("  Auto-reload: " .. (DiscordBridgeDB.config.autoReload and "ON" or "OFF") ..
              " (" .. DiscordBridgeDB.config.autoReloadInterval .. "s)")
        print("  Watch boss yells: " .. (DiscordBridgeDB.config.watchBossYells and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        print("  Watch general chat: " .. (DiscordBridgeDB.config.watchGeneralChat and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

    elseif cmd == "flush" then
        local count = #DiscordBridgeDB.queue
        DiscordBridgeDB.queue = {}
        print("|cff00ff00[DiscordBridge]|r Flushed " .. count .. " messages from queue.")

    elseif cmd == "autoreload" then
        local setting = args[2]
        if setting == "on" then
            DiscordBridgeDB.config.autoReload = true
            SetupAutoReload()
            print("|cff00ff00[DiscordBridge]|r Auto-reload enabled.")
        elseif setting == "off" then
            DiscordBridgeDB.config.autoReload = false
            SetupAutoReload()
            print("|cff00ff00[DiscordBridge]|r Auto-reload disabled.")
        else
            print("|cff00ff00[DiscordBridge]|r Usage: /discordbridge autoreload on/off")
        end

    elseif cmd == "interval" then
        local seconds = tonumber(args[2])
        if seconds and seconds >= 30 then
            DiscordBridgeDB.config.autoReloadInterval = seconds
            SetupAutoReload()
            print("|cff00ff00[DiscordBridge]|r Auto-reload interval set to " .. seconds .. " seconds.")
        else
            print("|cff00ff00[DiscordBridge]|r Usage: /discordbridge interval <seconds> (minimum 30)")
        end

    elseif cmd == "enable" then
        DiscordBridgeDB.config.enabled = true
        print("|cff00ff00[DiscordBridge]|r Enabled.")

    elseif cmd == "disable" then
        DiscordBridgeDB.config.enabled = false
        print("|cff00ff00[DiscordBridge]|r Disabled.")

    elseif cmd == "bosses" then
        local setting = args[2]
        if setting == "on" then
            DiscordBridgeDB.config.watchBossYells = true
            print("|cff00ff00[DiscordBridge]|r Boss yell monitoring enabled.")
        elseif setting == "off" then
            DiscordBridgeDB.config.watchBossYells = false
            print("|cff00ff00[DiscordBridge]|r Boss yell monitoring disabled.")
        else
            print("|cff00ff00[DiscordBridge]|r Usage: /discordbridge bosses on/off")
        end

    elseif cmd == "general" then
        local setting = args[2]
        if setting == "on" then
            DiscordBridgeDB.config.watchGeneralChat = true
            print("|cff00ff00[DiscordBridge]|r General chat monitoring enabled.")
        elseif setting == "off" then
            DiscordBridgeDB.config.watchGeneralChat = false
            print("|cff00ff00[DiscordBridge]|r General chat monitoring disabled.")
        else
            print("|cff00ff00[DiscordBridge]|r Usage: /discordbridge general on/off")
        end

    elseif cmd == "test" then
        -- Send a test alert
        QueueMessage("TEST", "TestPlayer", "Test alert - Kazzak spotted!", "test", {
            alertType = "TEST",
        })
        print("|cff00ff00[DiscordBridge]|r Test alert queued. Run /reload to flush.")

    elseif cmd == "announce" then
        -- Manual announcement: /wb announce <boss> [layer]
        local bossName = args[2]
        local layer = args[3] or "1"

        if not bossName then
            print("|cff00ff00[DiscordBridge]|r Usage: /wb announce <boss> [layer]")
            print("  Example: /wb announce kazzak 1")
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
            print("|cff00ff00[DiscordBridge]|r Unknown boss: " .. bossName)
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
        print("|cff00ff00[DiscordBridge]|r Alert queued. Run /reload to flush immediately.")
        PlaySound(8959) -- RAID_WARNING sound

    else
        print("|cff00ff00[DiscordBridge]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wb announce <boss> [layer] - Announce a boss sighting")
        print("  /wb status - Show status")
        print("  /wb flush - Clear message queue")
        print("  /wb autoreload on/off - Toggle auto-reload")
        print("  /wb interval <seconds> - Set auto-reload interval")
        print("  /wb bosses on/off - Toggle boss yell monitoring")
        print("  /wb general on/off - Toggle general chat monitoring")
        print("  /wb test - Send a test alert")
        print("  /wb enable/disable - Enable or disable addon")
    end
end

-- Register slash commands
SLASH_DISCORDBRIDGE1 = "/discordbridge"
SLASH_DISCORDBRIDGE2 = "/wb"
SLASH_DISCORDBRIDGE3 = "/wba"  -- World Boss Announcer
SlashCmdList["DISCORDBRIDGE"] = SlashHandler

-- Register events
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("CHAT_MSG_MONSTER_YELL")  -- Boss yells
frame:RegisterEvent("CHAT_MSG_CHANNEL")        -- General chat

frame:SetScript("OnEvent", OnEvent)
