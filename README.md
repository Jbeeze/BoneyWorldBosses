# Boney World Bosses v3.2

A WoW Classic TBC Anniversary addon that detects world boss activity, reports kills, and tracks server layer information to Discord via the [WorldBossTracker](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) bot.

## Features

### Scout Mode (Real-Time)
- **Real-Time Combat Alerts**: Detects boss combat via combat log within ~1 second
- **NPC ID Detection**: Identifies Kazzak (18728) and Doomwalker (17711) by GUID
- **Auto Log Discovery**: Automatically finds the latest `WoWCombatLog-*.txt` file
- **Deduplication**: 30-second window prevents spam during continuous combat

### Reporter Mode (Kill Reports)
- **Kill Detection**: Detects boss deaths via UNIT_DIED combat event
- **Layer Information**: Captures layer from NWB addon and layerId from GUID
- **Server Time**: Records kill time in Server Time format
- **Confirmation Popup**: Shows kill details before reporting
- **Auto-Cleanup**: Reported kills are automatically removed from the pending queue

### Layer Updates
- **NWB Layer Snapshots**: Reports active server layers with instance IDs for all tracked zones
- **Auto on Login/Logout**: Sends layer data to Discord on login (5s delay for NWB sync) and logout
- **Manual Command**: `/bwb layers` sends a layer update with confirmation before UI reload
- **Per-Zone Reporting**: Sends a `LAYER_UPDATE` webhook for each zone NWB has mapped

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              SCOUT MODE                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│  WoW Combat Log ──► WoWCombatLog.txt ──► bridge.py ──► Bot ──► Discord     │
│  (real-time)        (auto-detected)      (tail -f)                          │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                             REPORTER MODE                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  UNIT_DIED ──► pendingKills[] ──► /reload ──► SavedVariables ──► bridge.py │
│  (in-game)     (queued)           (flush)     (on disk)          (polls)   │
│                                                        │                    │
│                                                        └──► Bot ──► Discord │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                             LAYER UPDATES                                   │
├─────────────────────────────────────────────────────────────────────────────┤
│  NWB Data ──► layerSnapshot ──► /reload or logout ──► bridge.py ──► Bot    │
│  (in-game)    (SavedVariables)   (flush to disk)       (polls)     Discord │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Boss NPC IDs

| Boss | NPC ID |
|------|--------|
| Doom Lord Kazzak | 18728 |
| Doomwalker | 17711 |

## Installation

### 1. Initial Setup (One Time)

Before the addon can work, you need to initialize the combat log file:

1. Open WoW
2. Type `/combatlog` in the chat window
3. You should see: "Combat being logged to Logs\WoWCombatLog.txt"

This creates the log file that the bridge will tail. You only need to do this once.

### 2. Install the WoW Addon

Copy the addon files to your WoW Classic AddOns folder:

```
WoW/_anniversary_/Interface/AddOns/BoneyWorldBosses/
├── BoneyWorldBosses.toc
└── BoneyWorldBosses.lua
```

Or clone directly:
```bash
cd "/path/to/WoW/_anniversary_/Interface/AddOns"
git clone https://github.com/Jbeeze/Boney-World-Bosses.git BoneyWorldBosses
```

### 3. Configure the Python Bridge

Install dependencies:
```bash
pip install -r requirements.txt
```

The bridge **auto-detects** the WoW Logs directory when run from the addon folder. No manual configuration needed.

If auto-detection fails, edit `bridge.py` and set `LOGS_DIR` manually:
```python
CONFIG = {
    "BOT_API_URL": "https://worldbosstrackerdiscordbot.onrender.com",
    "LOGS_DIR": "/path/to/WoW/_anniversary_/Logs",
}
```

### 4. Run the Bridge

**Easy way:** Double-click the launcher:
- **macOS**: `run_bridge.command`
- **Windows**: `run_bridge.bat`

**Or via command line:**
```bash
python bridge.py
```

The bridge must run on the same machine as WoW since it reads local files.

## In-Game Settings

### Interface Options Panel

Access settings via: **ESC → Interface → AddOns → BoneyWorldBosses**

- **Enable Scout Mode**: Controls combat logging for real-time boss detection
- **Enable Kill Reporter**: Detects boss kills and queues them for Discord
- **Pending Kill Reports**: Shows count of unreported kills
- **Clear Pending Kills**: Removes all queued kill reports

### Slash Commands

| Command | Description |
|---------|-------------|
| `/bwb` | Show help |
| `/bwb scout on\|off` | Toggle Scout mode |
| `/bwb reporter on\|off` | Toggle Reporter mode |
| `/bwb status` | Show current status |
| `/bwb layers` | Send layer update to Discord (reloads UI) |
| `/bwb log status` | Show all kill reports with status |
| `/bwb log clear` | Clear pending kill reports |
| `/bwb log update # <field> <value>` | Update a kill report field |
| `/bwb options` | Open settings panel |
| `/bwb test kill` | Test mode (next creature kill = test report) |
| `/bwb nwb` | Debug NWB layer info |
| `/bwb debug layer` | Toggle verbose layer lookup debugging |

Both Scout and Reporter modes are **enabled by default**.

## Alert Types

| Source | Alert Type | Description |
|--------|------------|-------------|
| Scout | `COMBAT_DETECTED` | Real-time boss combat detection |
| Reporter | `BOSS_KILLED` | Kill report with time, layer, and instance ID |
| Layer Update | `LAYER_UPDATE` | Active server layers per zone with instance IDs |

### LAYER_UPDATE Payload

Single bulk request with all zones:

```json
{
  "alertType": "LAYER_UPDATE",
  "trigger": "login",
  "zones": {
    "1944": { "1": "106045", "2": "112071" },
    "1948": { "1": "106048", "2": "112074" },
    "1951": { "1": "106050", "2": "112076" }
  }
}
```

- `zones`: object keyed by UIMapID (e.g., `"1944"` = Hellfire Peninsula)
  - Each zone maps layer number (string) → zone instance ID (string)
- `trigger`: `"login"`, `"logout"`, or `"manual"`

## Kill Reporting Flow

1. **Kill Detected**: When a world boss dies within 50 yards, addon detects UNIT_DIED
2. **Data Captured**: Boss name, kill time (Server Time), layer, and layerId from GUID
3. **Popup Shown**: Confirmation dialog with kill details
4. **Report Kill**: Click to trigger /reload, flushing SavedVariables to disk
5. **Bridge Reads**: bridge.py polls SavedVariables every 5 seconds
6. **Alert Sent**: BOSS_KILLED alert posted to Discord bot
7. **Cleanup**: Kill entry removed from SavedVariables after successful report

**Note**: The /reload is required because WoW only writes SavedVariables to disk on logout/reload.

## Requirements

- [NovaWorldBuffs](https://www.curseforge.com/wow/addons/nova-world-buffs) addon (optional, recommended for layer info)
- Python 3 with `requests` module for the bridge
- Must be within ~50 yards of boss combat to receive combat log events
- Combat logging must be enabled (addon does this automatically when Scout mode is on)

## Testing

### Scout Mode
1. Login to WoW - addon auto-enables combat logging
2. Start `python bridge.py`
3. Engage or stand near a world boss fight (within 50 yards)
4. Verify alert appears in Discord within ~1 second

### Reporter Mode
1. Login to WoW with Reporter mode enabled
2. Be within 50 yards when a world boss dies
3. Popup appears with kill details
4. Click "Report Kill" (triggers /reload)
5. Check bridge console for kill report
6. Verify kill recorded in Discord

### Test Kill Mode
Test the kill reporting flow without waiting for a world boss:

1. Type `/bwb test kill` to arm test mode
2. Kill any creature (boar, critter, etc.)
3. Popup appears with test kill details
4. Click "Report Kill" (triggers /reload)
5. Bridge sends test alert (marked as `isTest: true`)
6. Test mode auto-disables after one kill

### Layer Updates
1. Login to WoW with NWB installed
2. Layer snapshot auto-sends 5 seconds after login
3. Or type `/bwb layers` for a manual update
4. Check bridge console for `[LAYER]` messages

### Edge Cases
- Log out without clicking popup → kill saved, report on next login after /reload
- Multiple kills before reload → all queued and reported
- NWB not installed → layer shows "?" but layerId still captured from GUID
- Bridge restart → reported kills tracked in `bridge_state.json`, no duplicates

## Bot Setup

This addon requires the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) to be running.

The bot needs to handle three alert types:
- `COMBAT_DETECTED` - Real-time boss activity alerts
- `BOSS_KILLED` - Kill reports with time/layer info
- `LAYER_UPDATE` - Server layer status per zone

## Troubleshooting

### Alerts not appearing in Discord

1. Check that `bridge.py` is running
2. Verify `LOGS_DIR` is auto-detected or set correctly
3. Ensure combat logging is enabled (`/bwb status`)
4. Ensure the bot is running and connected to Discord
5. Check the bridge console for errors
6. Verify you're within 50 yards of the combat

### Kill reports not sending

1. Ensure Reporter mode is enabled (`/bwb status`)
2. Check `/bwb log status` to see if kills are queued
3. Type `/reload` to flush SavedVariables
4. Check bridge console for `[KILL]` messages
5. Verify SavedVariables file exists in WTF folder

### Log file not found

1. Run `/combatlog` in WoW to create a combat log file
2. Verify `WoWCombatLog-*.txt` files exist in `_anniversary_/Logs/`
3. If auto-detection fails, set `LOGS_DIR` manually in `bridge.py`

### Bridge restarts reading old messages

The bridge saves its position in `bridge_state.json`. On restart, it resumes from where it left off. If you want to start fresh, delete `bridge_state.json`.

## File Structure

```
BoneyWorldBosses/
├── BoneyWorldBosses.toc       # Addon metadata (Interface 20504)
├── BoneyWorldBosses.lua       # Main addon code
├── bridge.py                  # Python bridge script
├── run_bridge.command         # macOS launcher (double-click)
├── run_bridge.bat             # Windows launcher (double-click)
├── requirements.txt           # Python dependencies
├── bridge_state.json          # Bridge state (auto-created at runtime)
└── README.md
```

## SavedVariables

The addon stores data in:
```
WoW/_anniversary_/WTF/Account/<ACCOUNT>/SavedVariables/BoneyWorldBosses.lua
```

Structure:
```lua
BoneyWorldBossesDB = {
    ["config"] = {
        ["scoutEnabled"] = true,
        ["reporterEnabled"] = true,
    },
    ["pendingKills"] = {
        {
            ["boss"] = "kazzak",
            ["time"] = "11:35am",
            ["layer"] = "2",
            ["layerId"] = "31401",
            ["timestamp"] = 1711043445,
        },
    },
    ["layerSnapshot"] = {
        ["timestamp"] = 1711043445,
        ["trigger"] = "login",
        ["zones"] = {
            ["1944"] = {
                ["1"] = "106045",
                ["2"] = "112071",
            },
        },
    },
}
```

## Version History

| Version | Changes |
|---------|---------|
| v3.2 | Layer updates (NWB integration), auto-detect Logs dir, rename to Boney World Bosses |
| v3.1 | Added Reporter mode (kill detection + reporting) |
| v3.0 | Combat log tailing, NPC ID matching, real-time alerts |
| v2.0 | Chat log tailing, pattern matching |
| v1.0 | SavedVariables, required /reload |

## License

MIT
