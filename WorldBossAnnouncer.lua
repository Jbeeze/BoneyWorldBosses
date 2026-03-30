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
    layerSnapshot = nil,
    -- layerSnapshot format:
    -- { timestamp = 1711043445, trigger = "login", zones = { ["1944"] = { ["1"] = "106045" } } }
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
-- Debug flag for verbose layer lookup output
local debugLayerLookup = false

local function GetCurrentLayer(layerId)
    if not NWB then
        if debugLayerLookup then
            print("[WBA Debug] NWB addon not loaded")
        end
        return "?"
    end

    -- Try multiple ways to get layer from NWB

    -- Method 1: Direct currentLayer (most reliable when player is on a known layer)
    if NWB.currentLayer and NWB.currentLayer > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.currentLayer: " .. tostring(NWB.currentLayer))
        end
        return tostring(NWB.currentLayer)
    end

    -- Method 2: currentLayerShared (shared layer info)
    if NWB.currentLayerShared and NWB.currentLayerShared > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.currentLayerShared: " .. tostring(NWB.currentLayerShared))
        end
        return tostring(NWB.currentLayerShared)
    end

    -- Method 3: Look up layer by instance ID in NWB's layer map
    if layerId and NWB.data and NWB.data.layers then
        if debugLayerLookup then
            print("[WBA Debug] Searching NWB.data.layers for instanceId: " .. tostring(layerId))
        end
        for layerNum, layerData in pairs(NWB.data.layers) do
            if layerData then
                -- Check if layer key itself matches the instanceId (some versions use this)
                if tostring(layerNum) == tostring(layerId) then
                    -- layerNum is the instanceId, need to find the actual layer number
                    -- In this case, we'd need to count layers or use a different method
                    if debugLayerLookup then
                        print("[WBA Debug] Layer key matches instanceId, checking for layerNum field")
                    end
                    if layerData.layerNum then
                        return tostring(layerData.layerNum)
                    end
                end

                -- Check GUID field
                if layerData.GUID and tostring(layerData.GUID) == tostring(layerId) then
                    if debugLayerLookup then
                        print("[WBA Debug] Found via GUID match in layer " .. tostring(layerNum))
                    end
                    return tostring(layerNum)
                end

                -- Check layerMap (zone -> instanceId mapping)
                if layerData.layerMap then
                    for zoneId, instId in pairs(layerData.layerMap) do
                        if tostring(instId) == tostring(layerId) then
                            if debugLayerLookup then
                                print("[WBA Debug] Found via layerMap match: zone " .. tostring(zoneId) .. " -> layer " .. tostring(layerNum))
                            end
                            return tostring(layerNum)
                        end
                    end
                end
            end
        end
    end

    -- Method 4: Check if NWB stores layers keyed by instanceId directly
    if layerId and NWB.data and NWB.data.layers and NWB.data.layers[tonumber(layerId)] then
        local layerData = NWB.data.layers[tonumber(layerId)]
        if layerData and layerData.layerNum then
            if debugLayerLookup then
                print("[WBA Debug] Found via direct instanceId key lookup: " .. tostring(layerData.layerNum))
            end
            return tostring(layerData.layerNum)
        end
    end

    -- Method 5: Try NWB's lastKnownLayer
    if NWB.lastKnownLayer and NWB.lastKnownLayer > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.lastKnownLayer: " .. tostring(NWB.lastKnownLayer))
        end
        return tostring(NWB.lastKnownLayer)
    end

    -- Method 6: Try lastKnownLayerNum
    if NWB.lastKnownLayerNum and NWB.lastKnownLayerNum > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.lastKnownLayerNum: " .. tostring(NWB.lastKnownLayerNum))
        end
        return tostring(NWB.lastKnownLayerNum)
    end

    -- Method 7: Try lastKnownLayerID and match it
    if NWB.lastKnownLayerID and tostring(NWB.lastKnownLayerID) == tostring(layerId) then
        -- We know the player was on this layer, but we need the layer number
        -- Fall through to check if there's a layerNum stored elsewhere
        if debugLayerLookup then
            print("[WBA Debug] lastKnownLayerID matches but no layer number found")
        end
    end

    if debugLayerLookup then
        print("[WBA Debug] No layer found, returning ?")
    end
    return "?"
end

-- =============================================================================
-- LAYER SNAPSHOT
-- =============================================================================

-- Sorted pairs iterator (matches NWB's layer numbering)
local function pairsByKeys(t)
    local keys = {}
    for k in pairs(t) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local i = 0
    return function()
        i = i + 1
        if keys[i] then
            return keys[i], t[keys[i]]
        end
    end
end

local function BuildLayerSnapshot(trigger)
    if not NWB or not NWB.data or not NWB.data.layers then
        return nil
    end

    -- zones[uiMapId][layerNum] = zoneInstanceId
    local zones = {}
    local layerCount = 0

    for layerKey, layerData in pairsByKeys(NWB.data.layers) do
        layerCount = layerCount + 1
        if layerData.layerMap then
            for zoneInstId, uiMapId in pairs(layerData.layerMap) do
                if type(uiMapId) == "number" then -- skip "created" key
                    local mapKey = tostring(uiMapId)
                    if not zones[mapKey] then
                        zones[mapKey] = {}
                    end
                    zones[mapKey][tostring(layerCount)] = tostring(zoneInstId)
                end
            end
        end
    end

    return {
        timestamp = time(),
        trigger = trigger,
        zones = zones,
    }
end

local function WriteLayerSnapshot(trigger)
    if not db then return false end

    local snapshot = BuildLayerSnapshot(trigger)
    if not snapshot then
        print("|cff00ff00[WorldBossAnnouncer]|r NWB layer data not available.")
        return false
    end

    db.layerSnapshot = snapshot

    -- Print summary
    local zoneCount = 0
    local totalMappings = 0
    for _, layers in pairs(snapshot.zones) do
        zoneCount = zoneCount + 1
        for _ in pairs(layers) do
            totalMappings = totalMappings + 1
        end
    end
    print("|cff00ff00[WorldBossAnnouncer]|r Layer snapshot saved (" .. trigger .. "): " .. zoneCount .. " zone(s), " .. totalMappings .. " mapping(s)")
    return true
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
    local layerId = ExtractLayerIdFromGuid(destGuid) or "?"
    local layer = GetCurrentLayer(layerId)
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

StaticPopupDialogs["WBA_CONFIRM_LAYER_SNAPSHOT"] = {
    text = "Layer Update\n\nThis will snapshot current NWB layer data and reload your UI to send it to Discord.\n\n|cffff8800Warning:|r This will reload your UI.",
    button1 = "Send Layer Update",
    button2 = "Cancel",
    OnAccept = function()
        if WriteLayerSnapshot("manual") then
            print("|cff00ff00[WorldBossAnnouncer]|r Reloading UI to flush layer snapshot...")
            ReloadUI()
        end
    end,
    OnCancel = function()
        print("|cff00ff00[WorldBossAnnouncer]|r Layer snapshot cancelled.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
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
        -- Legacy alias for /wba log status
        print("|cff00ff00[WorldBossAnnouncer]|r Use /wba log status instead.")
        -- Fall through to show status anyway
        if #db.pendingKills == 0 then
            print("|cff00ff00[WorldBossAnnouncer]|r No kill reports.")
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Kill reports:")
            for i, kill in ipairs(db.pendingKills) do
                local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss
                local status = kill.sent and "|cff00ff00sent|r" or "|cffffcc00pending|r"
                print(string.format("  %d. [%s] %s - %s ST - Layer %s (%s)",
                    i, status, displayName, kill.time, kill.layer, kill.layerId))
            end
        end

    elseif cmd == "clear" then
        -- Legacy alias for /wba log clear
        db.pendingKills = {}
        print("|cff00ff00[WorldBossAnnouncer]|r Pending kill reports cleared.")

    elseif cmd == "log" then
        local subcmd = args[2]
        if subcmd == "status" then
            if #db.pendingKills == 0 then
                print("|cff00ff00[WorldBossAnnouncer]|r No kill reports.")
            else
                print("|cff00ff00[WorldBossAnnouncer]|r Kill reports:")
                local pendingCount = 0
                local sentCount = 0
                for i, kill in ipairs(db.pendingKills) do
                    local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss
                    local status
                    if kill.sent then
                        status = "|cff00ff00sent|r"
                        sentCount = sentCount + 1
                    else
                        status = "|cffffcc00pending|r"
                        pendingCount = pendingCount + 1
                    end
                    print(string.format("  %d. [%s] %s - %s ST - Layer %s (%s)",
                        i, status, displayName, kill.time, kill.layer, kill.layerId))
                end
                print("|cff00ff00[WorldBossAnnouncer]|r Total: " .. pendingCount .. " pending, " .. sentCount .. " sent")
                if pendingCount > 0 then
                    print("|cff00ff00[WorldBossAnnouncer]|r Type /reload to send pending reports.")
                end
            end

        elseif subcmd == "clear" then
            local range = args[3]
            if not range then
                -- Clear all
                local count = #db.pendingKills
                db.pendingKills = {}
                print("|cff00ff00[WorldBossAnnouncer]|r Cleared all " .. count .. " kill report(s).")
            else
                -- Parse range like "1-3" or single number like "2"
                local startIdx, endIdx = string.match(range, "(%d+)-(%d+)")
                if startIdx and endIdx then
                    startIdx = tonumber(startIdx)
                    endIdx = tonumber(endIdx)
                else
                    -- Single number
                    startIdx = tonumber(range)
                    endIdx = startIdx
                end

                if not startIdx or not endIdx then
                    print("|cff00ff00[WorldBossAnnouncer]|r Invalid range. Use: /wba log clear [N] or /wba log clear [N-M]")
                    return
                end

                -- Validate range
                local total = #db.pendingKills
                if startIdx < 1 or endIdx > total or startIdx > endIdx then
                    print("|cff00ff00[WorldBossAnnouncer]|r Invalid range. You have " .. total .. " kill report(s).")
                    return
                end

                -- Remove from end to start to preserve indices
                local removed = 0
                for i = endIdx, startIdx, -1 do
                    table.remove(db.pendingKills, i)
                    removed = removed + 1
                end
                print("|cff00ff00[WorldBossAnnouncer]|r Cleared " .. removed .. " kill report(s). " .. #db.pendingKills .. " remaining.")
            end

        elseif subcmd == "update" then
            local idx = tonumber(args[3])
            local field = args[4] and string.lower(args[4]) or nil
            local value = args[5]

            if not idx then
                print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba log update <#> <field> <value>")
                print("  Fields: layer, layerid, time, boss, status")
                print("  Example: /wba log update 1 layer 3")
                print("  Example: /wba log update 2 time 11:35am")
                print("  Example: /wba log update 1 status sent")
                return
            end

            if idx < 1 or idx > #db.pendingKills then
                print("|cff00ff00[WorldBossAnnouncer]|r Invalid index. You have " .. #db.pendingKills .. " kill report(s).")
                return
            end

            local kill = db.pendingKills[idx]
            local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss

            if not field or not value then
                -- Show usage
                print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba log update " .. idx .. " <field> <value>")
                print("  Fields: layer, layerid, time, boss, status")
                return
            end

            -- Update the field
            if field == "layer" then
                local oldValue = kill.layer
                kill.layer = value
                print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " layer: " .. tostring(oldValue) .. " -> " .. value)
            elseif field == "layerid" then
                local oldValue = kill.layerId
                kill.layerId = value
                print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " layerId: " .. tostring(oldValue) .. " -> " .. value)
            elseif field == "time" then
                local oldValue = kill.time
                kill.time = value
                print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " time: " .. tostring(oldValue) .. " -> " .. value)
            elseif field == "boss" then
                local oldValue = kill.boss
                -- Accept common variations
                local bossKey = string.lower(value)
                if bossKey == "kazzak" or bossKey == "kaz" or bossKey == "dlk" then
                    bossKey = "kazzak"
                elseif bossKey == "doomwalker" or bossKey == "doom" or bossKey == "dw" then
                    bossKey = "doomwalker"
                end
                kill.boss = bossKey
                print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " boss: " .. tostring(oldValue) .. " -> " .. bossKey)
            elseif field == "status" then
                local oldStatus = kill.sent and "sent" or "pending"
                local newValue = string.lower(value)
                if newValue == "sent" or newValue == "s" then
                    kill.sent = true
                    print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " status: " .. oldStatus .. " -> sent")
                elseif newValue == "pending" or newValue == "p" then
                    kill.sent = nil
                    print("|cff00ff00[WorldBossAnnouncer]|r Updated kill #" .. idx .. " status: " .. oldStatus .. " -> pending")
                else
                    print("|cff00ff00[WorldBossAnnouncer]|r Invalid status. Use: sent, pending")
                end
            else
                print("|cff00ff00[WorldBossAnnouncer]|r Unknown field: " .. field)
                print("  Valid fields: layer, layerid, time, boss, status")
            end

        else
            print("|cff00ff00[WorldBossAnnouncer]|r Log commands:")
            print("  /wba log status      - Show all kill reports with status")
            print("  /wba log clear       - Clear all kill reports")
            print("  /wba log clear N     - Clear kill report #N")
            print("  /wba log clear N-M   - Clear kill reports #N through #M")
            print("  /wba log update # <field> <value> - Update a field")
            print("    Fields: layer, layerid, time, boss, status")
            print("    Example: /wba log update 1 layer 3")
        end

    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        InterfaceOptionsFrame_OpenToCategory("WorldBossAnnouncer")
        InterfaceOptionsFrame_OpenToCategory("WorldBossAnnouncer")  -- Called twice due to WoW bug

    elseif cmd == "nwb" then
        -- Debug: show NWB layer info
        print("|cff00ff00[WorldBossAnnouncer]|r NWB Debug Info:")
        if not NWB then
            print("  NWB addon: |cffff0000NOT LOADED|r")
        else
            print("  NWB addon: |cff00ff00LOADED|r")
            print("  NWB.currentLayer: " .. tostring(NWB.currentLayer or "nil"))
            print("  NWB.lastKnownLayer: " .. tostring(NWB.lastKnownLayer or "nil"))
            print("  NWB.lastKnownLayerNum: " .. tostring(NWB.lastKnownLayerNum or "nil"))
            -- Check for layer frame
            if NWB.currentLayerShared then
                print("  NWB.currentLayerShared: " .. tostring(NWB.currentLayerShared))
            end
            if NWB.lastKnownLayerID then
                print("  NWB.lastKnownLayerID: " .. tostring(NWB.lastKnownLayerID))
            end
            if NWB.data and NWB.data.layers then
                print("  NWB.data.layers:")
                local layerCount = 0
                for layerNum, layerData in pairs(NWB.data.layers) do
                    layerCount = layerCount + 1
                    print("    Layer " .. tostring(layerNum) .. ":")
                    if layerData then
                        -- Show GUID if present
                        if layerData.GUID then
                            print("      GUID: " .. tostring(layerData.GUID))
                        end
                        -- Show layerMap (zone -> instanceId mapping)
                        if layerData.layerMap then
                            print("      layerMap:")
                            local mapCount = 0
                            for zoneId, instId in pairs(layerData.layerMap) do
                                mapCount = mapCount + 1
                                if mapCount <= 5 then  -- Limit output
                                    print("        zone " .. tostring(zoneId) .. " -> instId " .. tostring(instId))
                                end
                            end
                            if mapCount > 5 then
                                print("        ... and " .. (mapCount - 5) .. " more zones")
                            end
                        end
                        -- Show created timestamp if present
                        if layerData.created then
                            print("      created: " .. tostring(layerData.created))
                        end
                    end
                end
                if layerCount == 0 then
                    print("    (empty)")
                end
            else
                print("  NWB.data.layers: nil")
            end
            -- Also check NWB.data.layerMap directly if it exists
            if NWB.data and NWB.data.layerMap then
                print("  NWB.data.layerMap (direct):")
                local count = 0
                for k, v in pairs(NWB.data.layerMap) do
                    count = count + 1
                    if count <= 3 then
                        print("    " .. tostring(k) .. " -> " .. tostring(v))
                    end
                end
                if count > 3 then
                    print("    ... and " .. (count - 3) .. " more")
                end
            end
        end

    elseif cmd == "debug" then
        local subcmd = args[2]
        if subcmd == "layer" then
            debugLayerLookup = not debugLayerLookup
            print("|cff00ff00[WorldBossAnnouncer]|r Layer lookup debug: " .. (debugLayerLookup and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        elseif subcmd == "lookup" then
            -- Test layer lookup with a specific instanceId
            local testId = args[3]
            if testId then
                debugLayerLookup = true  -- Temporarily enable debug
                print("|cff00ff00[WorldBossAnnouncer]|r Testing layer lookup for instanceId: " .. testId)
                local result = GetCurrentLayer(testId)
                print("|cff00ff00[WorldBossAnnouncer]|r Result: Layer " .. result)
                debugLayerLookup = false  -- Disable debug
            else
                print("|cff00ff00[WorldBossAnnouncer]|r Usage: /wba debug lookup <instanceId>")
                print("  Example: /wba debug lookup 79466")
            end
        else
            print("|cff00ff00[WorldBossAnnouncer]|r Debug commands:")
            print("  /wba debug layer - Toggle verbose layer lookup debugging")
            print("  /wba debug lookup <id> - Test layer lookup for specific instanceId")
        end

    elseif cmd == "layers" then
        StaticPopup_Show("WBA_CONFIRM_LAYER_SNAPSHOT")

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
        print("  /wba log             - Kill report management (status/clear/update)")
        print("  /wba options         - Open settings panel")
        print("  /wba test kill       - Test mode (next creature kill = test report)")
        print("  /wba layers          - Send layer update to Discord (reloads UI)")
        print("")
        print("  Log commands:")
        print("    /wba log status    - Show all kill reports with status")
        print("    /wba log clear     - Clear all (or /wba log clear N or N-M)")
        print("    /wba log update # <field> <value> - Update kill field")
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
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        OnAddonLoaded(...)
    elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
    elseif event == "PLAYER_LOGIN" then
        -- Delay to let NWB populate layer data from other players
        C_Timer.After(5, function()
            WriteLayerSnapshot("login")
        end)
    elseif event == "PLAYER_LOGOUT" then
        -- SavedVariables auto-flush on logout
        WriteLayerSnapshot("logout")
    end
end)
