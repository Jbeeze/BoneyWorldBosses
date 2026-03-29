-- WorldBossAnnouncer: World Boss Announcer for Discord (v3.1)
-- Target: TBC Anniversary (Interface 20504)
-- Features:
--   Scout Mode: Combat logging for real-time boss detection
--   Reporter Mode: Kill detection and reporting to Discord

local ADDON_NAME = "WorldBossAnnouncer"
local VERSION = "3.1.0"

-- =============================================================================
-- BOSS DATA
-- =============================================================================

local BOSS_NPC_IDS = {
    [18728] = "kazzak",    -- Doom Lord Kazzak
    [17711] = "doomwalker", -- Doomwalker
}

local BOSS_DISPLAY_NAMES = {
    kazzak = "Doom Lord Kazzak",
    doomwalker = "Doomwalker",
}

-- =============================================================================
-- SAVED VARIABLES
-- =============================================================================

-- Default saved variables structure
local DB_DEFAULTS = {
    config = {
        scoutEnabled = true,    -- Combat log detection (existing)
        reporterEnabled = true, -- Kill reporting (new)
    },
    pendingKills = {},
    -- pendingKills format:
    -- { boss = "kazzak", time = "11:35am", layer = "2", layerId = "31401", timestamp = 1711043445 }
}

-- Reference to saved variables (set on ADDON_LOADED)
local db = nil

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

-- Extract NPC ID from a creature GUID
-- GUID format: Creature-0-server-zone-instance-NPCID-spawn
-- Example: Creature-0-6257-530-104772-18463-0000495DFA
--          parts[1]=Creature, [2]=0, [3]=server, [4]=zone, [5]=instance, [6]=npcId, [7]=spawn
local function ExtractNpcIdFromGuid(guid)
    if not guid or not string.find(guid, "Creature-") then
        return nil
    end

    local parts = {strsplit("-", guid)}
    if #parts >= 6 then
        return tonumber(parts[6])  -- NPC ID
    end
    return nil
end

-- Extract instance ID (layerId) from a creature GUID
-- GUID format: Creature-0-server-zone-instance-NPCID-spawn
-- Example: Creature-0-6257-530-104772-18463-0000495DFA
--          parts[1]=Creature, [2]=0, [3]=server, [4]=zone, [5]=instance, [6]=npcId, [7]=spawn
local function ExtractLayerIdFromGuid(guid)
    if not guid or not string.find(guid, "Creature-") then
        return nil
    end

    local parts = {strsplit("-", guid)}
    if #parts >= 5 then
        return parts[5]  -- instance ID (layer ID)
    end
    return nil
end

-- Format current time as "H:MMam/pm" (Server Time)
local function FormatTimeServerTime()
    local hour, minute = GetGameTime()
    local ampm = "am"

    if hour >= 12 then
        ampm = "pm"
        if hour > 12 then
            hour = hour - 12
        end
    elseif hour == 0 then
        hour = 12
    end

    return string.format("%d:%02d%s", hour, minute, ampm)
end

-- Get layer from NWB addon if available, otherwise "?"
local function GetCurrentLayer()
    if NWB and NWB.currentLayer then
        return tostring(NWB.currentLayer)
    end
    return "?"
end

-- =============================================================================
-- FRAMES
-- =============================================================================

-- Create hidden frame for event handling
local frame = CreateFrame("Frame")

-- Track logging state (LoggingCombat() doesn't have a getter)
local isLoggingEnabled = false

-- Test kill mode: next UNIT_DIED triggers a test kill report
local testKillModeActive = false

-- =============================================================================
-- KILL DETECTION
-- =============================================================================

-- Handle UNIT_DIED combat log event
local function OnUnitDied(destGuid, destName)
    -- Check if Reporter mode is enabled (or test mode is active)
    if not db then
        return
    end

    local isTestKill = testKillModeActive
    local npcId = ExtractNpcIdFromGuid(destGuid)
    local bossKey = nil
    local bossDisplayName = nil

    -- In test mode, treat any creature as a "test" boss
    if isTestKill then
        -- Disable test mode immediately (one-shot)
        testKillModeActive = false

        -- Only accept creatures (not players)
        if not destGuid or not string.find(destGuid, "Creature-") then
            print("|cff00ff00[WorldBossAnnouncer]|r Test mode: waiting for creature death (not player)")
            testKillModeActive = true  -- Re-enable, this wasn't a valid target
            return
        end

        bossKey = "test"
        bossDisplayName = destName or "Unknown Creature"  -- Use actual creature name
        layer = "0"  -- Test kills always use layer 0
    else
        -- Normal mode: check if Reporter is enabled and this is a boss
        if not db.config.reporterEnabled then
            return
        end

        if not npcId or not BOSS_NPC_IDS[npcId] then
            return
        end

        bossKey = BOSS_NPC_IDS[npcId]
        bossDisplayName = BOSS_DISPLAY_NAMES[bossKey]
    end

    local killTime = FormatTimeServerTime()
    local layer = GetCurrentLayer()
    local layerId = ExtractLayerIdFromGuid(destGuid) or "?"
    local timestamp = time()

    -- Create kill record
    local killRecord = {
        boss = bossKey,
        time = killTime,
        layer = layer,
        layerId = layerId,
        timestamp = timestamp,
    }

    -- Mark as test if applicable
    if isTestKill then
        killRecord.isTest = true
        killRecord.testTargetName = destName or "Unknown"
        killRecord.testNpcId = npcId and tostring(npcId) or "?"
    end

    -- Add to pending kills
    table.insert(db.pendingKills, killRecord)

    print("|cff00ff00[WorldBossAnnouncer]|r Kill detected: " .. bossDisplayName)
    if isTestKill then
        print("|cff00ff00[WorldBossAnnouncer]|r NPC ID: " .. (npcId or "?") .. " | Time: " .. killTime .. " ST | Layer: " .. layer .. " | LayerId: " .. layerId)
        print("|cffff8800[WorldBossAnnouncer]|r TEST MODE completed - this is a test report")
    else
        print("|cff00ff00[WorldBossAnnouncer]|r Time: " .. killTime .. " ST | Layer: " .. layer .. " | LayerId: " .. layerId)
    end

    -- Show confirmation popup (StaticPopup_Show only accepts 2 text args)
    local popupDetails = "Time: " .. killTime .. " ST | Layer: " .. layer
    StaticPopup_Show("WBA_CONFIRM_KILL_REPORT", bossDisplayName, popupDetails)
end

-- Handle combat log events
local function OnCombatLogEvent()
    local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags,
          destGUID, destName, destFlags, destRaidFlags = CombatLogGetCurrentEventInfo()

    -- UNIT_DIED fires for solo kills, PARTY_KILL fires when in a party/raid
    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        OnUnitDied(destGUID, destName)
    end
end

-- =============================================================================
-- CONFIRMATION POPUP
-- =============================================================================

StaticPopupDialogs["WBA_CONFIRM_KILL_REPORT"] = {
    text = "World Boss Kill Detected!\n\n%s\n%s\n\n|cffff8800Warning:|r Reporting will reload your UI",
    button1 = "Report Kill",
    button2 = "Cancel",
    OnAccept = function()
        print("|cff00ff00[WorldBossAnnouncer]|r Reloading UI to flush kill report...")
        ReloadUI()
    end,
    OnCancel = function()
        print("|cff00ff00[WorldBossAnnouncer]|r Kill report saved. Type /reload when ready to report.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = false,
    preferredIndex = 3,
}

-- =============================================================================
-- INTERFACE OPTIONS PANEL
-- =============================================================================

local function CreateOptionsPanel()
    -- Create the options panel
    local panel = CreateFrame("Frame")
    panel.name = "WorldBossAnnouncer"

    -- Title
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("World Boss Announcer v" .. VERSION)

    -- Description
    local desc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
    desc:SetText("Configure Scout and Reporter modes for Discord alerts.")

    -- Scout Mode Checkbox
    local scoutCheckbox = CreateFrame("CheckButton", "WBAScoutCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
    scoutCheckbox:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -20)
    scoutCheckbox.Text:SetText("Enable Scout Mode (combat detection)")
    scoutCheckbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        db.config.scoutEnabled = checked
        if checked then
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[WorldBossAnnouncer]|r Scout mode |cff00ff00ENABLED|r - Combat logging ON")
        else
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[WorldBossAnnouncer]|r Scout mode |cffff0000DISABLED|r - Combat logging OFF")
        end
    end)

    -- Scout description
    local scoutDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    scoutDesc:SetPoint("TOPLEFT", scoutCheckbox, "BOTTOMLEFT", 26, 2)
    scoutDesc:SetText("Writes combat to WoWCombatLog.txt for bridge.py to detect boss activity")

    -- Reporter Mode Checkbox
    local reporterCheckbox = CreateFrame("CheckButton", "WBAReporterCheckbox", panel, "InterfaceOptionsCheckButtonTemplate")
    reporterCheckbox:SetPoint("TOPLEFT", scoutDesc, "BOTTOMLEFT", -26, -16)
    reporterCheckbox.Text:SetText("Enable Kill Reporter")
    reporterCheckbox:SetScript("OnClick", function(self)
        local checked = self:GetChecked()
        db.config.reporterEnabled = checked
        if checked then
            print("|cff00ff00[WorldBossAnnouncer]|r Reporter mode |cff00ff00ENABLED|r")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Reporter mode |cffff0000DISABLED|r")
        end
    end)

    -- Reporter description
    local reporterDesc = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    reporterDesc:SetPoint("TOPLEFT", reporterCheckbox, "BOTTOMLEFT", 26, 2)
    reporterDesc:SetText("Detects boss kills and reports them to Discord (requires /reload)")

    -- Pending kills info
    local pendingLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    pendingLabel:SetPoint("TOPLEFT", reporterDesc, "BOTTOMLEFT", -26, -24)
    pendingLabel:SetText("Pending Kill Reports:")

    local pendingCount = panel:CreateFontString("WBAPendingCount", "ARTWORK", "GameFontHighlight")
    pendingCount:SetPoint("TOPLEFT", pendingLabel, "BOTTOMLEFT", 0, -4)

    -- Clear pending kills button
    local clearButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    clearButton:SetPoint("TOPLEFT", pendingCount, "BOTTOMLEFT", 0, -8)
    clearButton:SetSize(140, 24)
    clearButton:SetText("Clear Pending Kills")
    clearButton:SetScript("OnClick", function()
        db.pendingKills = {}
        pendingCount:SetText("0 pending kills")
        print("|cff00ff00[WorldBossAnnouncer]|r Pending kill reports cleared.")
    end)

    -- Refresh function
    panel.refresh = function()
        scoutCheckbox:SetChecked(db.config.scoutEnabled)
        reporterCheckbox:SetChecked(db.config.reporterEnabled)
        local count = db.pendingKills and #db.pendingKills or 0
        pendingCount:SetText(count .. " pending kill" .. (count ~= 1 and "s" or ""))
    end

    -- Register with Interface Options
    InterfaceOptions_AddCategory(panel)

    return panel
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

local optionsPanel = nil

local function InitializeSavedVariables()
    -- Initialize saved variables with defaults if needed
    if not WorldBossAnnouncerDB then
        WorldBossAnnouncerDB = {}
    end

    if not WorldBossAnnouncerDB.config then
        WorldBossAnnouncerDB.config = {}
    end

    -- Apply defaults
    for key, value in pairs(DB_DEFAULTS.config) do
        if WorldBossAnnouncerDB.config[key] == nil then
            WorldBossAnnouncerDB.config[key] = value
        end
    end

    if not WorldBossAnnouncerDB.pendingKills then
        WorldBossAnnouncerDB.pendingKills = {}
    end

    -- Set local reference
    db = WorldBossAnnouncerDB
end

local function OnAddonLoaded(addonName)
    if addonName ~= ADDON_NAME then return end

    -- Initialize saved variables
    InitializeSavedVariables()

    -- Auto-enable combat logging if scout mode is on
    if db.config.scoutEnabled then
        LoggingCombat(true)
        isLoggingEnabled = true
    end

    -- Register for combat log events if reporter mode is on
    if db.config.reporterEnabled then
        frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end

    -- Create options panel
    optionsPanel = CreateOptionsPanel()

    -- Print load messages
    print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " loaded.")

    local scoutStatus = db.config.scoutEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local reporterStatus = db.config.reporterEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    print("|cff00ff00[WorldBossAnnouncer]|r Scout: " .. scoutStatus .. " | Reporter: " .. reporterStatus)

    -- Show pending kills count
    local pendingCount = #db.pendingKills
    if pendingCount > 0 then
        print("|cff00ff00[WorldBossAnnouncer]|r " .. pendingCount .. " pending kill report(s). Type /reload to send.")
    end

    print("|cff00ff00[WorldBossAnnouncer]|r Type /wba for commands. ESC > Interface > AddOns for settings.")
end

-- =============================================================================
-- SLASH COMMANDS
-- =============================================================================

local function SlashHandler(msg)
    local args = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, string.lower(word))
    end

    local cmd = args[1]

    if cmd == "scout" then
        local setting = args[2]
        if setting == "on" then
            db.config.scoutEnabled = true
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[WorldBossAnnouncer]|r Scout mode |cff00ff00ENABLED|r - Combat logging ON")
        elseif setting == "off" then
            db.config.scoutEnabled = false
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[WorldBossAnnouncer]|r Scout mode |cffff0000DISABLED|r - Combat logging OFF")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba scout on/off")
        end

    elseif cmd == "reporter" then
        local setting = args[2]
        if setting == "on" then
            db.config.reporterEnabled = true
            frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            print("|cff00ff00[WorldBossAnnouncer]|r Reporter mode |cff00ff00ENABLED|r")
        elseif setting == "off" then
            db.config.reporterEnabled = false
            frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            print("|cff00ff00[WorldBossAnnouncer]|r Reporter mode |cffff0000DISABLED|r")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba reporter on/off")
        end

    -- Legacy support for old "logging" command
    elseif cmd == "logging" then
        local setting = args[2]
        if setting == "on" then
            db.config.scoutEnabled = true
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[WorldBossAnnouncer]|r Combat logging |cff00ff00ENABLED|r")
        elseif setting == "off" then
            db.config.scoutEnabled = false
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[WorldBossAnnouncer]|r Combat logging |cffff0000DISABLED|r")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba logging on/off")
        end

    elseif cmd == "status" then
        print("|cff00ff00[WorldBossAnnouncer]|r Status:")
        local scoutStatus = db.config.scoutEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        local reporterStatus = db.config.reporterEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        local loggingStatus = isLoggingEnabled and "|cff00ff00ACTIVE|r" or "|cffff0000INACTIVE|r"
        local testStatus = testKillModeActive and "|cffff8800ARMED|r" or "off"
        print("  Scout (combat logging): " .. scoutStatus)
        print("  Reporter (kill reports): " .. reporterStatus)
        print("  Combat logging: " .. loggingStatus .. " (required for Scout/Test)")
        print("  Test kill mode: " .. testStatus)
        print("  Pending kills: " .. #db.pendingKills)
        print("  Log file: WoW/_anniversary_/Logs/WoWCombatLog.txt")

    elseif cmd == "pending" then
        if #db.pendingKills == 0 then
            print("|cff00ff00[WorldBossAnnouncer]|r No pending kill reports.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Pending kill reports:")
            for i, kill in ipairs(db.pendingKills) do
                local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss
                print(string.format("  %d. %s - %s ST - Layer %s (%s)",
                    i, displayName, kill.time, kill.layer, kill.layerId))
            end
            print("|cff00ff00[WorldBossAnnouncer]|r Type /reload to send these reports.")
        end

    elseif cmd == "clear" then
        db.pendingKills = {}
        print("|cff00ff00[WorldBossAnnouncer]|r Pending kill reports cleared.")

    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        InterfaceOptionsFrame_OpenToCategory("WorldBossAnnouncer")
        InterfaceOptionsFrame_OpenToCategory("WorldBossAnnouncer")  -- Called twice due to WoW bug

    elseif cmd == "test" then
        local subcmd = args[2]
        if subcmd == "kill" then
            if testKillModeActive then
                print("|cff00ff00[WorldBossAnnouncer]|r Test kill mode already active. Kill any creature to trigger.")
            else
                testKillModeActive = true
                -- Ensure we're listening for combat log events
                frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
                -- Ensure combat logging is enabled (required for events to fire)
                if not isLoggingEnabled then
                    LoggingCombat(true)
                    isLoggingEnabled = true
                    print("|cffff8800[WorldBossAnnouncer]|r Combat logging enabled for test")
                end
                print("|cffff8800[WorldBossAnnouncer]|r TEST KILL MODE ACTIVE")
                print("|cffff8800[WorldBossAnnouncer]|r Kill any creature to generate a test kill report.")
                print("|cffff8800[WorldBossAnnouncer]|r Mode will auto-disable after one kill.")
            end
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Test commands:")
            print("  /wba test kill - Arm test mode (next creature kill = test report)")
        end

    else
        print("|cff00ff00[WorldBossAnnouncer]|r v" .. VERSION .. " - World Boss Announcer")
        print("  /wba scout on|off    - Toggle Scout mode (combat logging)")
        print("  /wba reporter on|off - Toggle Reporter mode (kill reports)")
        print("  /wba status          - Show current status")
        print("  /wba pending         - List pending kill reports")
        print("  /wba clear           - Clear pending kill reports")
        print("  /wba options         - Open settings panel")
        print("  /wba test kill       - Test mode (next creature kill = test report)")
        print("")
        print("  Scout Mode: Enables combat logging for real-time boss detection")
        print("  Reporter Mode: Detects boss kills and queues them for Discord")
        print("")
        print("  Settings: ESC > Interface > AddOns > WorldBossAnnouncer")
    end
end

-- Register slash commands
SLASH_WORLDBOSSANNOUNCER1 = "/worldbossannouncer"
SLASH_WORLDBOSSANNOUNCER2 = "/wba"
SlashCmdList["WORLDBOSSANNOUNCER"] = SlashHandler

-- =============================================================================
-- EVENT HANDLING
-- =============================================================================

frame:RegisterEvent("ADDON_LOADED")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(...)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
    end
end)
