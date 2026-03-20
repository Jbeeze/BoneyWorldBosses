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

-- Guild/whisper patterns: "Kazzak up L1", "Kazz up L2", "Doomwalker up L1", etc.
local GUILD_PATTERNS = {
    { pattern = "[Kk]azzak%s+up%s+[Ll](%d+)", boss = "Doom Lord Kazzak" },
    { pattern = "[Kk]azz%s+up%s+[Ll](%d+)", boss = "Doom Lord Kazzak" },
    { pattern = "[Dd]oomwalker%s+up%s+[Ll](%d+)", boss = "Doomwalker" },
}

-- Default configuration
local DEFAULT_CONFIG = {
    enabled = true,
    maxQueue = 200,
    autoReload = true,
    autoReloadInterval = 120,
    watchBossYells = true,
    watchGuildChat = true,
    watchWhispers = true,
}

-- Channel labels for each event type
local CHANNEL_LABELS = {
    CHAT_MSG_MONSTER_YELL = "boss_yell",
    CHAT_MSG_CHANNEL = "general",
}

-- Create hidden frame for event handling
local frame = CreateFrame("Frame")
local autoReloadTicker = nil

-- Popup dialog for reload confirmation (required for protected function)
StaticPopupDialogs["WORLDBOSSANNOUNCER_RELOAD"] = {
    text = "World Boss Announcer: Alert queued. Reload UI to send?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

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
            -- Try to get layer from TresLayerSwap WA or NovaWorldBuffs
            local layer = "?"
            if _G["TLS"] and _G["TLS"].layer and _G["TLS"].layer ~= 0 then
                layer = tostring(_G["TLS"].layer)
            elseif _G["NWB_CurrentLayer"] and _G["NWB_CurrentLayer"] ~= 0 then
                layer = tostring(_G["NWB_CurrentLayer"])
            elseif _G["TLSLayer"] and _G["TLSLayer"] ~= 0 then
                layer = tostring(_G["TLSLayer"])
            end

            QueueMessage(event, mobName, msg, "boss_yell", {
                alertType = "BOSS_YELL",
                boss = mobName,
                layer = layer,
            })

            -- Show reload popup immediately for boss yells
            StaticPopup_Show("WORLDBOSSANNOUNCER_RELOAD")
        end
        return
    end

    -- Guild chat - look for "Kazzak up L1", "Kazz up L2", "Doomwalker up L1", etc.
    if event == "CHAT_MSG_GUILD" then
        if not WorldBossAnnouncerDB.config.watchGuildChat then return end

        local msg, author = ...

        -- Check each pattern
        for _, patternInfo in ipairs(GUILD_PATTERNS) do
            local layer = string.match(msg, patternInfo.pattern)
            if layer then
                -- Strip realm name from author
                author = string.match(author, "([^-]+)") or author

                QueueMessage(event, author, patternInfo.boss .. " UP Layer " .. layer, "guild", {
                    alertType = "GUILD_REPORT",
                    boss = patternInfo.boss,
                    layer = layer,
                    reporter = author,
                })

                -- Show reload popup immediately for guild reports
                StaticPopup_Show("WORLDBOSSANNOUNCER_RELOAD")
                return
            end
        end
        return
    end

    -- Whispers - look for same patterns as guild chat
    -- Supports [TEST] prefix to test without pinging
    if event == "CHAT_MSG_WHISPER" then
        if not WorldBossAnnouncerDB.config.watchWhispers then return end

        local msg, author = ...

        -- Check for [TEST] prefix
        local isTest = string.match(msg, "^%[TEST%]") ~= nil
        local cleanMsg = isTest and string.gsub(msg, "^%[TEST%]%s*", "") or msg

        -- Check each pattern
        for _, patternInfo in ipairs(GUILD_PATTERNS) do
            local layer = string.match(cleanMsg, patternInfo.pattern)
            if layer then
                -- Strip realm name from author
                author = string.match(author, "([^-]+)") or author

                local alertType = isTest and "WHISPER_TEST" or "WHISPER_REPORT"
                local msgText = patternInfo.boss .. " UP Layer " .. layer
                if isTest then
                    msgText = "[TEST] " .. msgText
                end

                QueueMessage(event, author, msgText, "whisper", {
                    alertType = alertType,
                    boss = patternInfo.boss,
                    layer = layer,
                    reporter = author,
                })

                -- Show reload popup immediately for whisper reports
                StaticPopup_Show("WORLDBOSSANNOUNCER_RELOAD")
                return
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
        print("  Watch guild chat: " .. (WorldBossAnnouncerDB.config.watchGuildChat and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        print("  Watch whispers: " .. (WorldBossAnnouncerDB.config.watchWhispers and "|cff00ff00ON|r" or "|cffff0000OFF|r"))

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

    elseif cmd == "guild" then
        local setting = args[2]
        if setting == "on" then
            WorldBossAnnouncerDB.config.watchGuildChat = true
            print("|cff00ff00[WorldBossAnnouncer]|r Guild chat monitoring enabled.")
        elseif setting == "off" then
            WorldBossAnnouncerDB.config.watchGuildChat = false
            print("|cff00ff00[WorldBossAnnouncer]|r Guild chat monitoring disabled.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba guild on/off")
        end

    elseif cmd == "whisper" or cmd == "whispers" then
        local setting = args[2]
        if setting == "on" then
            WorldBossAnnouncerDB.config.watchWhispers = true
            print("|cff00ff00[WorldBossAnnouncer]|r Whisper monitoring enabled.")
        elseif setting == "off" then
            WorldBossAnnouncerDB.config.watchWhispers = false
            print("|cff00ff00[WorldBossAnnouncer]|r Whisper monitoring disabled.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba whisper on/off")
        end

    elseif cmd == "test" then
        -- Send a test alert (no @everyone ping)
        local playerName = UnitName("player")
        QueueMessage("TEST", playerName, "Test alert - Discord connection working!", "test", {
            alertType = "TEST",
        })
        print("|cff00ff00[WorldBossAnnouncer]|r Test alert queued.")
        StaticPopup_Show("WORLDBOSSANNOUNCER_RELOAD")

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
        StaticPopup_Show("WORLDBOSSANNOUNCER_RELOAD")

    else
        print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wba announce <boss> [layer] - Announce a boss sighting")
        print("  /wba status - Show status")
        print("  /wba flush - Clear message queue")
        print("  /wba autoreload on/off - Toggle auto-reload")
        print("  /wba interval <seconds> - Set auto-reload interval")
        print("  /wba bosses on/off - Toggle boss yell monitoring")
        print("  /wba guild on/off - Toggle guild chat monitoring")
        print("  /wba whisper on/off - Toggle whisper monitoring")
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
frame:RegisterEvent("CHAT_MSG_GUILD")          -- Guild chat
frame:RegisterEvent("CHAT_MSG_WHISPER")        -- Whispers

frame:SetScript("OnEvent", OnEvent)
