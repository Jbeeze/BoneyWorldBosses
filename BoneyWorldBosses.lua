-- BoneyWorldBosses: Boney World Bosses for Discord (v3.2)
-- Target: TBC Anniversary (Interface 20504)
-- Features:
--   Scout Mode: Combat logging for real-time boss detection
--   Reporter Mode: Kill detection and reporting to Discord
--   Layer Updates: NWB layer data reporting to Discord

local ADDON_NAME = "BoneyWorldBosses"
local VERSION = "3.4.1"
local SCHEMA_VERSION = 1

-- Create AceAddon (NWB bundles LibStub + AceAddon-3.0)
local BWB = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME)

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

-- Map zone names to boss keys (for scout report auto-detection)
local ZONE_TO_BOSS = {
    ["Hellfire Peninsula"] = "kazzak",
    ["Shadowmoon Valley"] = "doomwalker",
}

-- =============================================================================
-- SAVED VARIABLES
-- =============================================================================

-- Default saved variables structure
local DB_DEFAULTS = {
    config = {
        scoutEnabled = true,    -- Combat log detection (existing)
        reporterEnabled = true, -- Kill reporting (new)
        guildId = "",           -- Discord guild/server ID (set via /bwb setup)
        discordId = "",         -- User's Discord ID (set via /bwb setup)
        botApiUrl = "",         -- Bot API URL (set via /bwb setup)
    },
    pendingKills = {},
    -- pendingKills format:
    -- { boss = "kazzak", time = "11:35am", layer = "2", layerId = "31401", timestamp = 1711043445 }
    layerSnapshot = nil,
    -- layerSnapshot format:
    -- { timestamp = 1711043445, trigger = "login", zones = { ["1944"] = { ["1"] = "106045" } } }
    scoutReport = nil,
    -- scoutReport format:
    -- { action = "on", boss = "doomwalker", layer = "3", layerId = "11640", characterName = "Name", timestamp = 1711043445 }
    scoutingActive = false,
    scoutingContext = nil,
    -- scoutingContext format (saved when scout-on is sent, used for scout-off):
    -- { boss = "doomwalker", layer = "3", layerId = "11640" }
    calloutReport = nil,
    -- calloutReport format:
    -- { boss = "kazzak", layer = "2", layerId = "31401", characterName = "Name", timestamp = 1711043445 }
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

-- Discord IDs (snowflakes) are 17-19 decimal digits.
local function IsValidSnowflake(s)
    return type(s) == "string" and s:match("^%d+$") ~= nil and #s >= 17 and #s <= 19
end

local function IsValidHttpsUrl(s)
    return type(s) == "string" and s:match("^https://[%w%.%-_]+") ~= nil
end

local function IsConfigComplete(d)
    if not d or not d.config then return false end
    return IsValidSnowflake(d.config.guildId)
        and IsValidSnowflake(d.config.discordId)
        and IsValidHttpsUrl(d.config.botApiUrl)
end

-- Returns a comma-separated list of missing-or-invalid config field names.
local function MissingConfigFields(d)
    local missing = {}
    if not d or not d.config then
        return "guild id, discord id, bot api url"
    end
    if not IsValidSnowflake(d.config.guildId) then table.insert(missing, "guild id") end
    if not IsValidSnowflake(d.config.discordId) then table.insert(missing, "discord id") end
    if not IsValidHttpsUrl(d.config.botApiUrl) then table.insert(missing, "bot api url") end
    return table.concat(missing, ", ")
end

-- Masks a Discord snowflake for display (first 3 + "..." + last 2 + digit count).
local function MaskSnowflake(s)
    if type(s) ~= "string" or #s < 6 then return s or "" end
    return s:sub(1, 3) .. "..." .. s:sub(-2) .. " (" .. #s .. " digits)"
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

-- Format current date as "YYYY-MM-DD"
local function FormatDateServerTime()
    local dateInfo = C_DateAndTime.GetCurrentCalendarTime()
    return string.format("%04d-%02d-%02d", dateInfo.year, dateInfo.month, dateInfo.monthDay)
end

-- Get the NWB addon reference (must be defined before GetCurrentLayer)
local function GetNWB()
    return LibStub("AceAddon-3.0"):GetAddon("NovaWorldBuffs", true)
end

-- Get layer from NWB addon if available, otherwise "?"
-- Debug flag for verbose layer lookup output
local debugLayerLookup = false

local function GetCurrentLayer(layerId)
    local nwb = GetNWB()
    if not nwb then
        if debugLayerLookup then
            print("[WBA Debug] NWB addon not loaded")
        end
        return "?"
    end

    -- Try multiple ways to get layer from NWB

    -- Method 1: Direct currentLayer (most reliable when player is on a known layer)
    if nwb.currentLayer and nwb.currentLayer > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.currentLayer: " .. tostring(nwb.currentLayer))
        end
        return tostring(nwb.currentLayer)
    end

    -- Method 2: currentLayerShared (shared layer info)
    if nwb.currentLayerShared and nwb.currentLayerShared > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.currentLayerShared: " .. tostring(nwb.currentLayerShared))
        end
        return tostring(nwb.currentLayerShared)
    end

    -- Method 3: Look up layer by instance ID in NWB's layer map
    if layerId and nwb.data and nwb.data.layers then
        if debugLayerLookup then
            print("[WBA Debug] Searching NWB.data.layers for instanceId: " .. tostring(layerId))
        end
        for layerNum, layerData in pairs(nwb.data.layers) do
            if layerData then
                if tostring(layerNum) == tostring(layerId) then
                    if debugLayerLookup then
                        print("[WBA Debug] Layer key matches instanceId, checking for layerNum field")
                    end
                    if layerData.layerNum then
                        return tostring(layerData.layerNum)
                    end
                end

                if layerData.GUID and tostring(layerData.GUID) == tostring(layerId) then
                    if debugLayerLookup then
                        print("[WBA Debug] Found via GUID match in layer " .. tostring(layerNum))
                    end
                    return tostring(layerNum)
                end

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
    if layerId and nwb.data and nwb.data.layers and nwb.data.layers[tonumber(layerId)] then
        local layerData = nwb.data.layers[tonumber(layerId)]
        if layerData and layerData.layerNum then
            if debugLayerLookup then
                print("[WBA Debug] Found via direct instanceId key lookup: " .. tostring(layerData.layerNum))
            end
            return tostring(layerData.layerNum)
        end
    end

    -- Method 5: Try NWB's lastKnownLayer
    if nwb.lastKnownLayer and nwb.lastKnownLayer > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.lastKnownLayer: " .. tostring(nwb.lastKnownLayer))
        end
        return tostring(nwb.lastKnownLayer)
    end

    -- Method 6: Try lastKnownLayerNum
    if nwb.lastKnownLayerNum and nwb.lastKnownLayerNum > 0 then
        if debugLayerLookup then
            print("[WBA Debug] Found via NWB.lastKnownLayerNum: " .. tostring(nwb.lastKnownLayerNum))
        end
        return tostring(nwb.lastKnownLayerNum)
    end

    -- Method 7: Try lastKnownLayerID and match it
    if nwb.lastKnownLayerID and tostring(nwb.lastKnownLayerID) == tostring(layerId) then
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

-- Get the boss key for the player's current zone, or nil if not in a boss zone
local function GetPlayerZoneBoss()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil, nil end
    local mapInfo = C_Map.GetMapInfo(mapID)
    if not mapInfo or not mapInfo.name then return nil, nil end
    return ZONE_TO_BOSS[mapInfo.name], mapInfo.name
end

-- Get current layer number and instance ID without needing a creature GUID
-- Returns layerNumber, layerId (both as strings)
local function GetCurrentLayerInfo()
    local nwb = GetNWB()
    if not nwb then
        return "?", "?"
    end

    -- Get layer number from NWB
    local layerNum = nil
    if nwb.currentLayer and nwb.currentLayer > 0 then
        layerNum = nwb.currentLayer
    elseif nwb.currentLayerShared and nwb.currentLayerShared > 0 then
        layerNum = nwb.currentLayerShared
    elseif nwb.lastKnownLayer and nwb.lastKnownLayer > 0 then
        layerNum = nwb.lastKnownLayer
    elseif nwb.lastKnownLayerNum and nwb.lastKnownLayerNum > 0 then
        layerNum = nwb.lastKnownLayerNum
    end

    if not layerNum then
        return "?", "?"
    end

    -- Get instance ID by reverse-looking up the player's zone in NWB layer data
    local layerId = "?"
    if nwb.data and nwb.data.layers then
        local count = 0
        for layerKey, layerData in pairsByKeys(nwb.data.layers) do
            count = count + 1
            if count == layerNum and layerData and layerData.layerMap then
                local mapID = C_Map.GetBestMapForUnit("player")
                if mapID then
                    for zoneInstId, uiMapId in pairs(layerData.layerMap) do
                        if type(uiMapId) == "number" and uiMapId == mapID then
                            layerId = tostring(zoneInstId)
                            break
                        end
                    end
                    -- Fallback: use any instance ID from this layer
                    if layerId == "?" then
                        for zoneInstId, uiMapId in pairs(layerData.layerMap) do
                            if type(uiMapId) == "number" then
                                layerId = tostring(zoneInstId)
                                break
                            end
                        end
                    end
                end
                break
            end
        end
    end

    -- Secondary fallback
    if layerId == "?" and nwb.lastKnownLayerID then
        layerId = tostring(nwb.lastKnownLayerID)
    end

    return tostring(layerNum), layerId
end

local function BuildLayerSnapshot(trigger)
    local nwb = GetNWB()
    if not nwb then
        print("|cffff8800[BoneyWorldBosses]|r NWB addon not found.")
        return nil
    end
    if not nwb.data then
        print("|cffff8800[BoneyWorldBosses]|r NWB data not initialized yet. Try again in a few seconds.")
        return nil
    end
    if not nwb.data.layers then
        print("|cffff8800[BoneyWorldBosses]|r NWB has no layer data. Visit a capital city to populate layers.")
        return nil
    end

    -- zones[uiMapId][layerNum] = zoneInstanceId
    local zones = {}
    local layerCount = 0

    for layerKey, layerData in pairsByKeys(nwb.data.layers) do
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
        characterName = UnitName("player"),
    }
end

local function WriteLayerSnapshot(trigger)
    if not db then return false end

    local snapshot = BuildLayerSnapshot(trigger)
    if not snapshot then
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
    print("|cff00ff00[BoneyWorldBosses]|r Layer snapshot saved (" .. trigger .. "): " .. zoneCount .. " zone(s), " .. totalMappings .. " mapping(s)")
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

-- Flag to distinguish scout ReloadUI from real logout (not persisted)
local intentionalReload = false

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
            print("|cff00ff00[BoneyWorldBosses]|r Test mode: waiting for creature death (not player)")
            testKillModeActive = true  -- Re-enable, this wasn't a valid target
            return
        end

        bossKey = "test"
        bossDisplayName = destName or "Unknown Creature"  -- Use actual creature name
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
    local killDate = FormatDateServerTime()
    local layerId = ExtractLayerIdFromGuid(destGuid) or "?"
    local layer = GetCurrentLayer(layerId)
    local timestamp = time()

    -- Create kill record
    local killRecord = {
        boss = bossKey,
        time = killTime,
        date = killDate,
        layer = layer,
        layerId = layerId,
        timestamp = timestamp,
        characterName = UnitName("player"),
    }

    -- Mark as test if applicable
    if isTestKill then
        killRecord.isTest = true
        killRecord.testTargetName = destName or "Unknown"
        killRecord.testNpcId = npcId and tostring(npcId) or "?"
    end

    -- Add to pending kills
    table.insert(db.pendingKills, killRecord)

    print("|cff00ff00[BoneyWorldBosses]|r Kill detected: " .. bossDisplayName)
    if isTestKill then
        print("|cff00ff00[BoneyWorldBosses]|r NPC ID: " .. (npcId or "?") .. " | Time: " .. killTime .. " ST | Layer: " .. layer .. " | LayerId: " .. layerId)
        print("|cffff8800[BoneyWorldBosses]|r TEST MODE completed - this is a test report")
    else
        print("|cff00ff00[BoneyWorldBosses]|r Time: " .. killTime .. " ST | Layer: " .. layer .. " | LayerId: " .. layerId)
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
        print("|cff00ff00[BoneyWorldBosses]|r Reloading UI to flush kill report...")
        intentionalReload = true
        ReloadUI()
    end,
    OnCancel = function()
        print("|cff00ff00[BoneyWorldBosses]|r Kill report saved. Type /reload when ready to report.")
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
            print("|cff00ff00[BoneyWorldBosses]|r Reloading UI to flush layer snapshot...")
            intentionalReload = true
            ReloadUI()
        end
    end,
    OnCancel = function()
        print("|cff00ff00[BoneyWorldBosses]|r Layer snapshot cancelled.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WBA_CONFIRM_SCOUT_ON"] = {
    text = "Start Scouting\n\n%s on Layer %s\n\n|cffff8800Warning:|r This will reload your UI",
    button1 = "Start Scouting",
    button2 = "Cancel",
    OnAccept = function()
        print("|cff00ff00[BoneyWorldBosses]|r Reloading UI to send scout report...")
        intentionalReload = true
        ReloadUI()
    end,
    OnCancel = function()
        print("|cff00ff00[BoneyWorldBosses]|r Scout report cancelled.")
        if db then
            db.scoutReport = nil
            db.scoutingActive = false
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WBA_CONFIRM_CALLOUT"] = {
    text = "Boss Callout\n\nThis will post an @everyone callout for %s L%s.\nPlayers will be told to whisper you for invite.\n\n|cffff8800Warning:|r This will reload your UI.",
    button1 = "Send Callout",
    button2 = "Cancel",
    OnAccept = function()
        print("|cff00ff00[BoneyWorldBosses]|r Reloading UI to send callout...")
        intentionalReload = true
        ReloadUI()
    end,
    OnCancel = function()
        print("|cff00ff00[BoneyWorldBosses]|r Callout cancelled.")
        if db then
            db.calloutReport = nil
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

StaticPopupDialogs["WBA_CONFIRM_SCOUT_OFF"] = {
    text = "Stop Scouting\n\n%s on Layer %s\n\n|cffff8800Warning:|r This will reload your UI",
    button1 = "Stop Scouting",
    button2 = "Cancel",
    OnAccept = function()
        print("|cff00ff00[BoneyWorldBosses]|r Reloading UI to send scout-off report...")
        intentionalReload = true
        ReloadUI()
    end,
    OnCancel = function()
        print("|cff00ff00[BoneyWorldBosses]|r Scout-off cancelled.")
        if db then
            db.scoutReport = nil
        end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- =============================================================================
-- SETUP WIZARD
-- =============================================================================

-- Chained StaticPopup dialogs: Server -> User -> Bot API URL -> ReloadUI.
-- button1 is live-enabled via EditBoxOnTextChanged so invalid input can't be submitted.

-- Classic Era 1.15 doesn't always populate dialog.button1 / dialog.editBox as
-- direct fields — fall back to the global-name lookup that has always worked.
local function PopupButton1(popup)
    return popup.button1 or _G[popup:GetName() .. "Button1"]
end

local function PopupEditBox(popup)
    return popup.editBox or _G[popup:GetName() .. "EditBox"]
end

local function BuildSetupPopup(fieldLabel, validator, maxLetters, onAccept)
    return {
        text = fieldLabel,
        button1 = "Next",
        button2 = "Cancel",
        hasEditBox = true,
        maxLetters = maxLetters,
        editBoxWidth = 260,
        OnShow = function(self, data)
            local editBox = PopupEditBox(self)
            local button1 = PopupButton1(self)
            editBox:SetText(data or "")
            editBox:HighlightText()
            editBox:SetFocus()
            if validator(editBox:GetText()) then
                button1:Enable()
            else
                button1:Disable()
            end
        end,
        EditBoxOnTextChanged = function(self)
            local button1 = PopupButton1(self:GetParent())
            if validator(self:GetText()) then
                button1:Enable()
            else
                button1:Disable()
            end
        end,
        EditBoxOnEnterPressed = function(self)
            local button1 = PopupButton1(self:GetParent())
            if button1:IsEnabled() then
                button1:Click()
            end
        end,
        EditBoxOnEscapePressed = function(self)
            self:GetParent():Hide()
        end,
        OnAccept = function(self)
            onAccept(PopupEditBox(self):GetText())
        end,
        OnCancel = function()
            print("|cff00ff00[BoneyWorldBosses]|r Setup cancelled. Run |cffffff00/bwb setup|r to resume.")
        end,
        timeout = 0,
        whileDead = true,
        hideOnEscape = true,
        preferredIndex = 3,
    }
end

StaticPopupDialogs["WBA_SETUP_GUILD"] = BuildSetupPopup(
    "Boney World Bosses Setup (1/3)\n\nEnter your |cffffff00Discord ID|r (17-19 digit snowflake):",
    IsValidSnowflake,
    19,
    function(value)
        db.config.guildId = value
        print("|cff00ff00[BoneyWorldBosses]|r Discord ID saved.")
        StaticPopup_Show("WBA_SETUP_DISCORD", nil, nil, db.config.discordId)
    end
)

StaticPopupDialogs["WBA_SETUP_DISCORD"] = BuildSetupPopup(
    "Boney World Bosses Setup (2/3)\n\nEnter your personal |cffffff00Discord User ID|r (17-19 digit snowflake):",
    IsValidSnowflake,
    19,
    function(value)
        db.config.discordId = value
        print("|cff00ff00[BoneyWorldBosses]|r Discord User ID saved.")
        StaticPopup_Show("WBA_SETUP_API", nil, nil, db.config.botApiUrl)
    end
)

StaticPopupDialogs["WBA_SETUP_API"] = BuildSetupPopup(
    "Boney World Bosses Setup (3/3)\n\nEnter your |cffffff00Bot API URL|r (must start with https://):",
    IsValidHttpsUrl,
    256,
    function(value)
        db.config.botApiUrl = value
        print("|cff00ff00[BoneyWorldBosses]|r Bot API URL saved. Reloading UI so the bridge can pick up your config...")
        intentionalReload = true
        ReloadUI()
    end
)

local function StartSetupWizard()
    StaticPopup_Show("WBA_SETUP_GUILD", nil, nil, db.config.guildId)
end

-- =============================================================================
-- INTERFACE OPTIONS PANEL
-- =============================================================================

local function CreateOptionsPanel()
    -- Create the options panel
    local panel = CreateFrame("Frame")
    panel.name = "BoneyWorldBosses"

    -- Setup-incomplete banner (shown only when config is missing)
    local banner = panel:CreateFontString("WBABanner", "ARTWORK", "GameFontNormal")
    banner:SetPoint("TOPLEFT", 16, -16)
    banner:SetJustifyH("LEFT")
    banner:Hide()

    -- Title (anchored to banner's height, leaving room when banner is visible)
    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -40)
    title:SetText("Boney World Bosses v" .. VERSION)

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
            print("|cff00ff00[BoneyWorldBosses]|r Scout mode |cff00ff00ENABLED|r - Combat logging ON")
        else
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[BoneyWorldBosses]|r Scout mode |cffff0000DISABLED|r - Combat logging OFF")
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
            print("|cff00ff00[BoneyWorldBosses]|r Reporter mode |cff00ff00ENABLED|r")
        else
            print("|cff00ff00[BoneyWorldBosses]|r Reporter mode |cffff0000DISABLED|r")
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
        print("|cff00ff00[BoneyWorldBosses]|r Pending kill reports cleared.")
    end)

    -- Refresh function
    panel.refresh = function()
        scoutCheckbox:SetChecked(db.config.scoutEnabled)
        reporterCheckbox:SetChecked(db.config.reporterEnabled)
        local count = db.pendingKills and #db.pendingKills or 0
        pendingCount:SetText(count .. " pending kill" .. (count ~= 1 and "s" or ""))
        if IsConfigComplete(db) then
            banner:Hide()
        else
            banner:SetText("|cffff0000Setup incomplete:|r missing " .. MissingConfigFields(db) .. ". Run /bwb setup.")
            banner:Show()
        end
    end

    -- Register with Interface Options (modern Settings API, fallback to legacy)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        local category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
        category.ID = panel.name
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end

    return panel
end

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

local optionsPanel = nil

local function InitializeSavedVariables()
    -- Initialize saved variables with defaults if needed
    if not BoneyWorldBossesDB then
        BoneyWorldBossesDB = {}
    end

    if not BoneyWorldBossesDB.config then
        BoneyWorldBossesDB.config = {}
    end

    -- Apply defaults
    for key, value in pairs(DB_DEFAULTS.config) do
        if BoneyWorldBossesDB.config[key] == nil then
            BoneyWorldBossesDB.config[key] = value
        end
    end

    if not BoneyWorldBossesDB.pendingKills then
        BoneyWorldBossesDB.pendingKills = {}
    end

    if BoneyWorldBossesDB.scoutingActive == nil then
        BoneyWorldBossesDB.scoutingActive = false
    end

    -- Set local reference
    db = BoneyWorldBossesDB
end

-- Writes version + schema breadcrumb that the bridge forwards to the bot API.
local function WriteMeta()
    db.meta = {
        addonVersion = VERSION,
        schemaVersion = SCHEMA_VERSION,
    }
end

-- Writes boss watch tables into SavedVariables so the bridge reads them from
-- there instead of carrying hardcoded constants of its own. Stringified keys
-- match the bridge's string NPC-id capture from GUIDs.
local function WriteStaticWatchTables()
    local watched = {}
    for npcId, bossKey in pairs(BOSS_NPC_IDS) do
        watched[tostring(npcId)] = bossKey
    end
    db.watchedNpcIds = watched

    local names = {}
    for bossKey, displayName in pairs(BOSS_DISPLAY_NAMES) do
        names[bossKey] = displayName
    end
    db.bossDisplayNames = names
end

-- AceAddon callback: called at ADDON_LOADED time
function BWB:OnInitialize()
    -- Initialize saved variables
    InitializeSavedVariables()

    -- Publish version + watch tables for the external bridge to consume.
    WriteMeta()
    WriteStaticWatchTables()

    -- Create options panel
    optionsPanel = CreateOptionsPanel()

    -- Print load messages
    print("|cff00ff00[BoneyWorldBosses]|r v" .. VERSION .. " loaded.")
end

-- AceAddon callback: called at PLAYER_LOGIN time (after all addons initialized)
function BWB:OnEnable()
    -- Save character name for bridge to include in webhooks
    db.characterName = UnitName("player")

    -- Auto-enable combat logging if scout mode is on
    if db.config.scoutEnabled then
        LoggingCombat(true)
        isLoggingEnabled = true
    end

    -- Register for combat log events if reporter mode is on
    if db.config.reporterEnabled then
        frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    end

    -- Register for logout (SavedVariables auto-flush)
    frame:RegisterEvent("PLAYER_LOGOUT")

    local scoutStatus = db.config.scoutEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    local reporterStatus = db.config.reporterEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
    print("|cff00ff00[BoneyWorldBosses]|r Scout: " .. scoutStatus .. " | Reporter: " .. reporterStatus)

    -- Show pending kills count
    local pendingCount = #db.pendingKills
    if pendingCount > 0 then
        print("|cff00ff00[BoneyWorldBosses]|r " .. pendingCount .. " pending kill report(s). Type /reload to send.")
    end

    print("|cff00ff00[BoneyWorldBosses]|r Type /bwb for commands. ESC > Interface > AddOns for settings.")

    -- Nag until setup is complete. Missing config means the bridge cannot reach
    -- Discord at all, so this is worth repeating on every login.
    if not IsConfigComplete(db) then
        print("|cffff0000[BoneyWorldBosses] Not configured.|r Run |cffffff00/bwb setup|r to enter Discord IDs and bot URL.")
    end

    -- Send layer snapshot on login (NWB.data is now guaranteed available)
    C_Timer.After(5, function()
        WriteLayerSnapshot("login")
    end)
end

-- =============================================================================
-- SLASH COMMANDS
-- =============================================================================

local function SlashHandler(msg)
    local args = {}
    local rawArgs = {}
    for word in string.gmatch(msg, "%S+") do
        table.insert(args, string.lower(word))
        table.insert(rawArgs, word)
    end

    local cmd = args[1]

    if cmd == "scout" then
        local setting = args[2]
        if setting == "on" then
            -- Validate zone before enabling anything
            local bossKey, zoneName = GetPlayerZoneBoss()
            if not bossKey then
                local zoneMsg = zoneName and (" (current zone: " .. zoneName .. ")") or ""
                print("|cffff0000[BoneyWorldBosses]|r Not in a boss zone" .. zoneMsg .. " - scout report not sent")
                print("|cffff0000[BoneyWorldBosses]|r Must be in Hellfire Peninsula or Shadowmoon Valley to report")
                return
            end
            local layer, layerId = GetCurrentLayerInfo()
            if layer == "?" or layerId == "?" then
                print("|cffff0000[BoneyWorldBosses]|r Layer not detected. Hover over an NPC and wait a few seconds, then try again.")
                return
            end
            -- Enable combat logging
            db.config.scoutEnabled = true
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[BoneyWorldBosses]|r Scout mode |cff00ff00ENABLED|r - Combat logging ON")
            local displayName = BOSS_DISPLAY_NAMES[bossKey]
            db.scoutReport = {
                action = "on",
                boss = bossKey,
                layer = layer,
                layerId = layerId,
                characterName = UnitName("player"),
                        timestamp = time(),
            }
            db.scoutingActive = true
            db.scoutingContext = { boss = bossKey, layer = layer, layerId = layerId }
            StaticPopup_Show("WBA_CONFIRM_SCOUT_ON", displayName, layer)
        elseif setting == "off" then
            -- Disable combat logging
            db.config.scoutEnabled = false
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[BoneyWorldBosses]|r Scout mode |cffff0000DISABLED|r - Combat logging OFF")
            -- Send scout-off report to Discord (detect boss/layer fresh from current zone)
            local offBoss = ""
            local offLayer = "?"
            local offLayerId = "?"
            local bossKey, _ = GetPlayerZoneBoss()
            if bossKey then
                offBoss = bossKey
                offLayer, offLayerId = GetCurrentLayerInfo()
            elseif db.scoutingContext then
                -- Fallback to saved context if player left the boss zone
                offBoss = db.scoutingContext.boss or ""
                offLayer = db.scoutingContext.layer or "?"
                offLayerId = db.scoutingContext.layerId or "?"
            end
            local offDisplayName = BOSS_DISPLAY_NAMES[offBoss] or "Unknown"
            db.scoutReport = {
                action = "off",
                boss = offBoss,
                layer = offLayer,
                layerId = offLayerId,
                characterName = UnitName("player"),
                        timestamp = time(),
            }
            db.scoutingActive = false
            db.scoutingContext = nil
            StaticPopup_Show("WBA_CONFIRM_SCOUT_OFF", offDisplayName, offLayer)
        else
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb scout on|off")
        end

    elseif cmd == "callout" then
        -- Validate zone before doing anything
        local bossKey, zoneName = GetPlayerZoneBoss()
        if not bossKey then
            local zoneMsg = zoneName and (" (current zone: " .. zoneName .. ")") or ""
            print("|cffff0000[BoneyWorldBosses]|r Not in a boss zone" .. zoneMsg)
            print("|cffff0000[BoneyWorldBosses]|r Must be in Hellfire Peninsula or Shadowmoon Valley to callout")
            return
        end
        local layer, layerId = GetCurrentLayerInfo()
        if layer == "?" or layerId == "?" then
            print("|cffff0000[BoneyWorldBosses]|r Layer not detected. Hover over an NPC and wait a few seconds, then try again.")
            return
        end
        local displayName = BOSS_DISPLAY_NAMES[bossKey]
        local characterName = UnitName("player")
        db.calloutReport = {
            boss = bossKey,
            layer = layer,
            layerId = layerId,
            characterName = characterName,
            timestamp = time(),
        }
        StaticPopup_Show("WBA_CONFIRM_CALLOUT", displayName, layer)

    elseif cmd == "reporter" then
        local setting = args[2]
        if setting == "on" then
            db.config.reporterEnabled = true
            frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            print("|cff00ff00[BoneyWorldBosses]|r Reporter mode |cff00ff00ENABLED|r")
        elseif setting == "off" then
            db.config.reporterEnabled = false
            frame:UnregisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
            print("|cff00ff00[BoneyWorldBosses]|r Reporter mode |cffff0000DISABLED|r")
        else
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb reporter on/off")
        end

    -- Legacy support for old "logging" command
    elseif cmd == "logging" then
        local setting = args[2]
        if setting == "on" then
            db.config.scoutEnabled = true
            LoggingCombat(true)
            isLoggingEnabled = true
            print("|cff00ff00[BoneyWorldBosses]|r Combat logging |cff00ff00ENABLED|r")
        elseif setting == "off" then
            db.config.scoutEnabled = false
            LoggingCombat(false)
            isLoggingEnabled = false
            print("|cff00ff00[BoneyWorldBosses]|r Combat logging |cffff0000DISABLED|r")
        else
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb logging on/off")
        end

    elseif cmd == "status" then
        print("|cff00ff00[BoneyWorldBosses]|r Status:")
        local scoutStatus = db.config.scoutEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        local reporterStatus = db.config.reporterEnabled and "|cff00ff00ON|r" or "|cffff0000OFF|r"
        local loggingStatus = isLoggingEnabled and "|cff00ff00ACTIVE|r" or "|cffff0000INACTIVE|r"
        local testStatus = testKillModeActive and "|cffff8800ARMED|r" or "off"
        print("  Scout (combat logging): " .. scoutStatus)
        print("  Reporter (kill reports): " .. reporterStatus)
        print("  Combat logging: " .. loggingStatus .. " (required for Scout/Test)")
        local scoutingReportStatus = db.scoutingActive and "|cff00ff00ACTIVE|r" or "off"
        print("  Test kill mode: " .. testStatus)
        print("  Scouting report: " .. scoutingReportStatus)
        print("  Pending kills: " .. #db.pendingKills)
        print("  Log file: WoW/_anniversary_/Logs/WoWCombatLog.txt")
        print("|cff00ff00[BoneyWorldBosses]|r Bridge config:")
        local guildDisplay = IsValidSnowflake(db.config.guildId) and MaskSnowflake(db.config.guildId) or "|cffff0000not set|r"
        local discordDisplay = IsValidSnowflake(db.config.discordId) and MaskSnowflake(db.config.discordId) or "|cffff0000not set|r"
        local apiDisplay = IsValidHttpsUrl(db.config.botApiUrl) and db.config.botApiUrl or "|cffff0000not set|r"
        print("  Guild ID: " .. guildDisplay)
        print("  Discord ID: " .. discordDisplay)
        print("  Bot API URL: " .. apiDisplay)
        if not IsConfigComplete(db) then
            print("|cffffcc00[BoneyWorldBosses]|r Run |cffffff00/bwb setup|r to complete configuration.")
        end

    elseif cmd == "pending" then
        -- Legacy alias for /bwb log status
        print("|cff00ff00[BoneyWorldBosses]|r Use /bwb log status instead.")
        -- Fall through to show status anyway
        if #db.pendingKills == 0 then
            print("|cff00ff00[BoneyWorldBosses]|r No kill reports.")
        else
            print("|cff00ff00[BoneyWorldBosses]|r Kill reports:")
            for i, kill in ipairs(db.pendingKills) do
                local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss
                local status = kill.sent and "|cff00ff00sent|r" or "|cffffcc00pending|r"
                print(string.format("  %d. [%s] %s - %s ST - Layer %s (%s)",
                    i, status, displayName, kill.time, kill.layer, kill.layerId))
            end
        end

    elseif cmd == "clear" then
        -- Legacy alias for /bwb log clear
        db.pendingKills = {}
        print("|cff00ff00[BoneyWorldBosses]|r Pending kill reports cleared.")

    elseif cmd == "log" then
        local subcmd = args[2]
        if subcmd == "status" then
            if #db.pendingKills == 0 then
                print("|cff00ff00[BoneyWorldBosses]|r No kill reports.")
            else
                print("|cff00ff00[BoneyWorldBosses]|r Kill reports:")
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
                print("|cff00ff00[BoneyWorldBosses]|r Total: " .. pendingCount .. " pending, " .. sentCount .. " sent")
                if pendingCount > 0 then
                    print("|cff00ff00[BoneyWorldBosses]|r Type /reload to send pending reports.")
                end
            end

        elseif subcmd == "clear" then
            local range = args[3]
            if not range then
                -- Clear all
                local count = #db.pendingKills
                db.pendingKills = {}
                print("|cff00ff00[BoneyWorldBosses]|r Cleared all " .. count .. " kill report(s).")
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
                    print("|cff00ff00[BoneyWorldBosses]|r Invalid range. Use: /bwb log clear [N] or /bwb log clear [N-M]")
                    return
                end

                -- Validate range
                local total = #db.pendingKills
                if startIdx < 1 or endIdx > total or startIdx > endIdx then
                    print("|cff00ff00[BoneyWorldBosses]|r Invalid range. You have " .. total .. " kill report(s).")
                    return
                end

                -- Remove from end to start to preserve indices
                local removed = 0
                for i = endIdx, startIdx, -1 do
                    table.remove(db.pendingKills, i)
                    removed = removed + 1
                end
                print("|cff00ff00[BoneyWorldBosses]|r Cleared " .. removed .. " kill report(s). " .. #db.pendingKills .. " remaining.")
            end

        elseif subcmd == "update" then
            local idx = tonumber(args[3])
            local field = args[4] and string.lower(args[4]) or nil
            local value = args[5]

            if not idx then
                print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb log update <#> <field> <value>")
                print("  Fields: layer, layerid, time, boss, status")
                print("  Example: /bwb log update 1 layer 3")
                print("  Example: /bwb log update 2 time 11:35am")
                print("  Example: /bwb log update 1 status sent")
                return
            end

            if idx < 1 or idx > #db.pendingKills then
                print("|cff00ff00[BoneyWorldBosses]|r Invalid index. You have " .. #db.pendingKills .. " kill report(s).")
                return
            end

            local kill = db.pendingKills[idx]
            local displayName = BOSS_DISPLAY_NAMES[kill.boss] or kill.boss

            if not field or not value then
                -- Show usage
                print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb log update " .. idx .. " <field> <value>")
                print("  Fields: layer, layerid, time, boss, status")
                return
            end

            -- Update the field
            if field == "layer" then
                local oldValue = kill.layer
                kill.layer = value
                print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " layer: " .. tostring(oldValue) .. " -> " .. value)
            elseif field == "layerid" then
                local oldValue = kill.layerId
                kill.layerId = value
                print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " layerId: " .. tostring(oldValue) .. " -> " .. value)
            elseif field == "time" then
                local oldValue = kill.time
                kill.time = value
                print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " time: " .. tostring(oldValue) .. " -> " .. value)
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
                print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " boss: " .. tostring(oldValue) .. " -> " .. bossKey)
            elseif field == "status" then
                local oldStatus = kill.sent and "sent" or "pending"
                local newValue = string.lower(value)
                if newValue == "sent" or newValue == "s" then
                    kill.sent = true
                    print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " status: " .. oldStatus .. " -> sent")
                elseif newValue == "pending" or newValue == "p" then
                    kill.sent = nil
                    print("|cff00ff00[BoneyWorldBosses]|r Updated kill #" .. idx .. " status: " .. oldStatus .. " -> pending")
                else
                    print("|cff00ff00[BoneyWorldBosses]|r Invalid status. Use: sent, pending")
                end
            else
                print("|cff00ff00[BoneyWorldBosses]|r Unknown field: " .. field)
                print("  Valid fields: layer, layerid, time, boss, status")
            end

        else
            print("|cff00ff00[BoneyWorldBosses]|r Log commands:")
            print("  /bwb log status      - Show all kill reports with status")
            print("  /bwb log clear       - Clear all kill reports")
            print("  /bwb log clear N     - Clear kill report #N")
            print("  /bwb log clear N-M   - Clear kill reports #N through #M")
            print("  /bwb log update # <field> <value> - Update a field")
            print("    Fields: layer, layerid, time, boss, status")
            print("    Example: /bwb log update 1 layer 3")
        end

    elseif cmd == "options" or cmd == "config" or cmd == "settings" then
        InterfaceOptionsFrame_OpenToCategory("BoneyWorldBosses")
        InterfaceOptionsFrame_OpenToCategory("BoneyWorldBosses")  -- Called twice due to WoW bug

    elseif cmd == "setup" then
        StartSetupWizard()

    elseif cmd == "guild" then
        local value = rawArgs[2]
        if not value then
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb guild <17-19 digit Discord guild id>")
            return
        end
        if not IsValidSnowflake(value) then
            print("|cffff0000[BoneyWorldBosses]|r Invalid guild id. Expected 17-19 digit snowflake.")
            return
        end
        db.config.guildId = value
        print("|cff00ff00[BoneyWorldBosses]|r Guild ID saved. Run |cffffff00/reload|r for the bridge to pick up this change.")

    elseif cmd == "discord" then
        local value = rawArgs[2]
        if not value then
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb discord <17-19 digit Discord user id>")
            return
        end
        if not IsValidSnowflake(value) then
            print("|cffff0000[BoneyWorldBosses]|r Invalid discord id. Expected 17-19 digit snowflake.")
            return
        end
        db.config.discordId = value
        print("|cff00ff00[BoneyWorldBosses]|r Discord ID saved. Run |cffffff00/reload|r for the bridge to pick up this change.")

    elseif cmd == "api" then
        local value = rawArgs[2]
        if not value then
            print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb api <https://your-bot-url>")
            return
        end
        if not IsValidHttpsUrl(value) then
            print("|cffff0000[BoneyWorldBosses]|r Invalid url. Must start with https://")
            return
        end
        db.config.botApiUrl = value
        print("|cff00ff00[BoneyWorldBosses]|r Bot API URL saved. Run |cffffff00/reload|r for the bridge to pick up this change.")

    elseif cmd == "nwb" then
        -- Debug: show NWB layer info
        local nwb = GetNWB()
        print("|cff00ff00[BoneyWorldBosses]|r NWB Debug Info:")
        if not nwb then
            print("  NWB addon: |cffff0000NOT LOADED|r")
        else
            print("  NWB addon: |cff00ff00LOADED|r")
            print("  NWB.currentLayer: " .. tostring(nwb.currentLayer or "nil"))
            print("  NWB.lastKnownLayer: " .. tostring(nwb.lastKnownLayer or "nil"))
            print("  NWB.lastKnownLayerNum: " .. tostring(nwb.lastKnownLayerNum or "nil"))
            if nwb.currentLayerShared then
                print("  NWB.currentLayerShared: " .. tostring(nwb.currentLayerShared))
            end
            if nwb.lastKnownLayerID then
                print("  NWB.lastKnownLayerID: " .. tostring(nwb.lastKnownLayerID))
            end
            if nwb.data and nwb.data.layers then
                print("  NWB.data.layers:")
                local layerCount = 0
                for layerNum, layerData in pairs(nwb.data.layers) do
                    layerCount = layerCount + 1
                    print("    Layer " .. tostring(layerNum) .. ":")
                    if layerData then
                        if layerData.GUID then
                            print("      GUID: " .. tostring(layerData.GUID))
                        end
                        if layerData.layerMap then
                            print("      layerMap:")
                            local mapCount = 0
                            for zoneId, instId in pairs(layerData.layerMap) do
                                mapCount = mapCount + 1
                                if mapCount <= 5 then
                                    print("        zone " .. tostring(zoneId) .. " -> instId " .. tostring(instId))
                                end
                            end
                            if mapCount > 5 then
                                print("        ... and " .. (mapCount - 5) .. " more zones")
                            end
                        end
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
            if nwb.data and nwb.data.layerMap then
                print("  NWB.data.layerMap (direct):")
                local count = 0
                for k, v in pairs(nwb.data.layerMap) do
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
            print("|cff00ff00[BoneyWorldBosses]|r Layer lookup debug: " .. (debugLayerLookup and "|cff00ff00ON|r" or "|cffff0000OFF|r"))
        elseif subcmd == "lookup" then
            -- Test layer lookup with a specific instanceId
            local testId = args[3]
            if testId then
                debugLayerLookup = true  -- Temporarily enable debug
                print("|cff00ff00[BoneyWorldBosses]|r Testing layer lookup for instanceId: " .. testId)
                local result = GetCurrentLayer(testId)
                print("|cff00ff00[BoneyWorldBosses]|r Result: Layer " .. result)
                debugLayerLookup = false  -- Disable debug
            else
                print("|cff00ff00[BoneyWorldBosses]|r Usage: /bwb debug lookup <instanceId>")
                print("  Example: /bwb debug lookup 79466")
            end
        else
            print("|cff00ff00[BoneyWorldBosses]|r Debug commands:")
            print("  /bwb debug layer - Toggle verbose layer lookup debugging")
            print("  /bwb debug lookup <id> - Test layer lookup for specific instanceId")
        end

    elseif cmd == "layers" then
        StaticPopup_Show("WBA_CONFIRM_LAYER_SNAPSHOT")

    elseif cmd == "test" then
        local subcmd = args[2]
        if subcmd == "kill" then
            if testKillModeActive then
                print("|cff00ff00[BoneyWorldBosses]|r Test kill mode already active. Kill any creature to trigger.")
            else
                testKillModeActive = true
                -- Ensure we're listening for combat log events
                frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
                -- Ensure combat logging is enabled (required for events to fire)
                if not isLoggingEnabled then
                    LoggingCombat(true)
                    isLoggingEnabled = true
                    print("|cffff8800[BoneyWorldBosses]|r Combat logging enabled for test")
                end
                print("|cffff8800[BoneyWorldBosses]|r TEST KILL MODE ACTIVE")
                print("|cffff8800[BoneyWorldBosses]|r Kill any creature to generate a test kill report.")
                print("|cffff8800[BoneyWorldBosses]|r Mode will auto-disable after one kill.")
            end
        else
            print("|cff00ff00[BoneyWorldBosses]|r Test commands:")
            print("  /bwb test kill - Arm test mode (next creature kill = test report)")
        end

    else
        print("|cff00ff00[BoneyWorldBosses]|r v" .. VERSION .. " - Boney World Bosses")
        print("  /bwb setup            - Configure Discord IDs and Bot API URL (guided)")
        print("  /bwb guild <id>       - Set Discord guild id (17-19 digits)")
        print("  /bwb discord <id>     - Set your Discord user id (17-19 digits)")
        print("  /bwb api <url>        - Set Bot API URL (https://...)")
        print("  /bwb scout on|off     - Toggle scouting (combat log + Discord report)")
        print("  /bwb reporter on|off  - Toggle Reporter mode (kill reports)")
        print("  /bwb status           - Show current status and config")
        print("  /bwb log              - Kill report management (status/clear/update)")
        print("  /bwb options          - Open settings panel")
        print("  /bwb test kill        - Test mode (next creature kill = test report)")
        print("  /bwb layers           - Send layer update to Discord (reloads UI)")
        print("  /bwb callout          - Post @everyone boss callout to Discord (reloads UI)")
        print("")
        print("  Log commands:")
        print("    /bwb log status    - Show all kill reports with status")
        print("    /bwb log clear     - Clear all (or /bwb log clear N or N-M)")
        print("    /bwb log update # <field> <value> - Update kill field")
        print("")
        print("  Settings: ESC > Interface > AddOns > BoneyWorldBosses")
    end
end

-- Register slash commands
SLASH_WORLDBOSSANNOUNCER1 = "/boneyworldbosses"
SLASH_WORLDBOSSANNOUNCER2 = "/bwb"
SlashCmdList["WORLDBOSSANNOUNCER"] = SlashHandler

-- =============================================================================
-- EVENT HANDLING
-- =============================================================================

-- Frame events for combat log and logout (AceAddon handles ADDON_LOADED + PLAYER_LOGIN)
frame:SetScript("OnEvent", function(self, event, ...)
    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        OnCombatLogEvent()
    elseif event == "PLAYER_LOGOUT" then
        -- Only write the "logout" snapshot on a real logout. Intentional reloads
        -- (scout on/off, /bwb layers, /bwb callout, kill-report popup) would
        -- otherwise clobber a trigger="manual" snapshot with trigger="logout".
        if not intentionalReload then
            WriteLayerSnapshot("logout")
        end
        -- Auto scout-off on logout/exit (skip if there's already a pending report,
        -- e.g. a scout-on that triggered this ReloadUI)
        -- NOTE: Do NOT call C_Map or other world APIs here — they can error during
        -- PLAYER_LOGOUT and abort the handler. Use only persisted context data.
        if db and db.scoutingActive and not intentionalReload then
            local ctx = db.scoutingContext or {}
            db.scoutReport = {
                action = "off",
                boss = ctx.boss or "",
                layer = ctx.layer or "?",
                layerId = ctx.layerId or "?",
                characterName = UnitName("player"),
                        timestamp = time(),
            }
            db.scoutingActive = false
            db.scoutingContext = nil
        end
    end
end)
