# World Boss Announcer v3.1

A WoW Classic TBC Anniversary addon that detects world boss activity and reports kills to Discord via the [WorldBossTracker](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) bot.

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
- **Persistent Queue**: Kills saved to SavedVariables survive logouts

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
WoW/_anniversary_/Interface/AddOns/WorldBossAnnouncer/
├── WorldBossAnnouncer.toc
└── WorldBossAnnouncer.lua
```

Or clone directly:
```bash
cd "/path/to/WoW/_anniversary_/Interface/AddOns"
git clone https://github.com/Jbeeze/WorldBossAnnouncer.git WorldBossAnnouncer
```

### 3. Configure the Python Bridge

Install dependencies:
```bash
pip install -r requirements.txt
```

Edit `bridge.py` and set your configuration:
```python
CONFIG = {
    # Your WorldBossTracker bot URL
    "BOT_API_URL": "https://worldbosstrackerdiscordbot.onrender.com",

    # Path to WoW Logs directory (NOT the specific file!)
    # macOS: /Applications/World of Warcraft/_anniversary_/Logs
    # Windows: C:\Program Files\World of Warcraft\_anniversary_\Logs
    "LOGS_DIR": "/path/to/WoW/_anniversary_/Logs",

    # How often to check for new lines (seconds)
    "POLL_INTERVAL": 1,

    # Deduplication window (seconds) - prevents spam during combat
    "DEDUP_WINDOW": 30,

    # How often to check for kill reports (seconds)
    "KILL_REPORT_CHECK_INTERVAL": 5,
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

Access settings via: **ESC → Interface → AddOns → WorldBossAnnouncer**

- **Enable Scout Mode**: Controls combat logging for real-time boss detection
- **Enable Kill Reporter**: Detects boss kills and queues them for Discord
- **Pending Kill Reports**: Shows count of unreported kills
- **Clear Pending Kills**: Removes all queued kill reports

### Slash Commands

| Command | Description |
|---------|-------------|
| `/wba` | Show help |
| `/wba scout on\|off` | Toggle Scout mode |
| `/wba reporter on\|off` | Toggle Reporter mode |
| `/wba status` | Show current status |
| `/wba pending` | List pending kill reports |
| `/wba clear` | Clear pending kill reports |
| `/wba options` | Open settings panel |
| `/wba test kill` | Test mode (next creature kill = test report) |
| `/wba logging on\|off` | Legacy command (same as scout) |

Both Scout and Reporter modes are **enabled by default**.

## Alert Types

| Source | Alert Type | Example Message |
|--------|------------|-----------------|
| Scout (combat detected) | `COMBAT_DETECTED` | `@tbc WORLD BOSS: Doom Lord Kazzak detected in combat!` |
| Reporter (boss killed) | `BOSS_KILLED` | `Doom Lord Kazzak killed at 11:35am ST on Layer 2` |

## Kill Reporting Flow

1. **Kill Detected**: When a world boss dies within 50 yards, addon detects UNIT_DIED
2. **Data Captured**: Boss name, kill time (Server Time), layer, and layerId from GUID
3. **Popup Shown**: Confirmation dialog with kill details
4. **Report Kill**: Click to trigger /reload, flushing SavedVariables to disk
5. **Bridge Reads**: bridge.py polls SavedVariables every 5 seconds
6. **Alert Sent**: BOSS_KILLED alert posted to Discord bot

**Note**: The /reload is required because WoW only writes SavedVariables to disk on logout/reload.

## Combat Log Format

The bridge parses WoW's combat log format:

```
M/D HH:MM:SS.mmm  SUBEVENT,sourceGUID,sourceName,...
```

GUID format for creatures:
```
Creature-0-server-zone-instance-NPCID-spawn
```

Example GUID: `Creature-0-6257-530-104772-18463-0000495DFA`
- Position 0: `Creature` (type)
- Position 1: `0` (marker)
- Position 2: `6257` (server ID)
- Position 3: `530` (zone ID - Outland)
- Position 4: `104772` (instance/layer ID)
- Position 5: `18463` (NPC ID)
- Position 6: `0000495DFA` (spawn ID)

Example UNIT_DIED line:
```
3/29 13:37:49.892  UNIT_DIED,0000000000000000,nil,0x80000000,0x80000000,Creature-0-6257-530-104772-18463-0000495DFA,"Dampscale Devourer",0x10a48,0x80000000,0
```

## Requirements

- Must be within ~50 yards of boss combat to receive combat log events
- Someone must be actively fighting the boss for events to appear
- Combat logging must be enabled (addon does this automatically when Scout mode is on)
- NWB addon recommended for accurate layer info (optional)

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

1. Type `/wba test kill` to arm test mode
2. Kill any creature (boar, critter, etc.)
3. Popup appears with test kill details
4. Click "Report Kill" (triggers /reload)
5. Bridge sends test alert (marked as `isTest: true`)
6. Test mode auto-disables after one kill

### Edge Cases
- Log out without clicking popup → kill saved, report on next login after /reload
- Multiple kills before reload → all queued and reported
- NWB not installed → layer shows "?" but layerId still captured from GUID

## Bot Setup

This addon requires the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) to be running.

The bot needs to handle two alert types:
- `COMBAT_DETECTED` - Real-time boss activity alerts
- `BOSS_KILLED` - Kill reports with time/layer info

## Troubleshooting

### Alerts not appearing in Discord

1. Check that `bridge.py` is running
2. Verify `LOGS_DIR` points to the correct Logs directory
3. Ensure combat logging is enabled (`/wba status`)
4. Ensure the bot is running and connected to Discord
5. Check the bridge console for errors
6. Verify you're within 50 yards of the combat

### Kill reports not sending

1. Ensure Reporter mode is enabled (`/wba status`)
2. Check `/wba pending` to see if kills are queued
3. Type `/reload` to flush SavedVariables
4. Check bridge console for "[KILL]" messages
5. Verify SavedVariables file exists in WTF folder

### Log file not found

1. Run `/combatlog` in WoW to create a combat log file
2. Verify `WoWCombatLog-*.txt` files exist in `_anniversary_/Logs/`
3. Make sure `LOGS_DIR` in `bridge.py` points to the Logs directory

### Bridge restarts reading old messages

The bridge saves its position in `bridge_state.json`. On restart, it resumes from where it left off. If you want to start fresh, delete `bridge_state.json`.

## File Structure

```
WorldBossAnnouncer/
├── WorldBossAnnouncer.toc    # Addon metadata (Interface 20504)
├── WorldBossAnnouncer.lua    # Main addon code
├── bridge.py                 # Python bridge script
├── run_bridge.command        # macOS launcher (double-click)
├── run_bridge.bat            # Windows launcher (double-click)
├── requirements.txt          # Python dependencies
├── bridge_state.json         # Bridge position + reported kills (auto-created)
└── README.md
```

## SavedVariables

The addon stores data in:
```
WoW/_anniversary_/WTF/Account/<ACCOUNT>/SavedVariables/WorldBossAnnouncer.lua
```

Structure:
```lua
WorldBossAnnouncerDB = {
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
}
```

## Version History

| Version | Changes |
|---------|---------|
| v3.1 | Added Reporter mode (kill detection + reporting) |
| v3.0 | Combat log tailing, NPC ID matching, real-time alerts |
| v2.0 | Chat log tailing, pattern matching |
| v1.0 | SavedVariables, required /reload |

## License

MIT
