# World Boss Announcer v3

A WoW Classic TBC Anniversary addon that detects world boss activity via combat log and forwards alerts to Discord via the [WorldBossTracker](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) bot.

**Real-time alerts with no /reload required!**

## How It Works

```
┌─────────────────┐     ┌────────────────────┐     ┌─────────────────┐     ┌─────────┐
│  WoW Combat Log │ ──► │  WoWCombatLog.txt  │ ──► │  bridge.py      │ ──► │  Bot    │ ──► Discord
│  (live logging) │     │  (real-time)       │     │  (tail -f)      │     │ (Render)│
└─────────────────┘     └────────────────────┘     └─────────────────┘     └─────────┘
```

1. **WoW Engine** writes combat events to log file when logging is enabled
2. **Addon** controls `LoggingCombat(true/false)` - auto-enabled on load
3. **bridge.py** tails the log file, detects boss NPC IDs in GUIDs, POSTs to bot API
4. **Bot** sends formatted messages to Discord

## Features

- **Real-Time Alerts**: No more `/reload` required - alerts within ~1 second
- **Combat Log Detection**: Detects boss NPC IDs (18728 = Kazzak, 17711 = Doomwalker)
- **Auto Log Discovery**: Automatically finds the latest `WoWCombatLog-*.txt` file
- **GUID Parsing**: Extracts NPC ID from creature GUIDs in combat log
- **Deduplication**: 30-second window prevents spam during continuous combat
- **Simple Addon**: Just enables/disables WoW's built-in combat logging

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
    # The bridge automatically finds the latest WoWCombatLog-*.txt file
    # macOS: /Applications/World of Warcraft/_anniversary_/Logs
    # Windows: C:\Program Files\World of Warcraft\_anniversary_\Logs
    "LOGS_DIR": "/path/to/WoW/_anniversary_/Logs",

    # How often to check for new lines (seconds)
    "POLL_INTERVAL": 1,

    # Deduplication window (seconds) - prevents spam during combat
    "DEDUP_WINDOW": 30,
}
```

The bridge automatically detects the most recent combat log file (e.g., `WoWCombatLog-032126_151059.txt`) and switches to new ones when created.

### 4. Run the Bridge

**Easy way:** Double-click the launcher:
- **macOS**: `run_bridge.command`
- **Windows**: `run_bridge.bat`

**Or via command line:**
```bash
python bridge.py
```

The bridge must run on the same machine as WoW since it reads local log files.

## In-Game Commands

| Command | Description |
|---------|-------------|
| `/wba` | Show help |
| `/wba logging on` | Enable combat logging |
| `/wba logging off` | Disable combat logging |
| `/wba status` | Show logging status |

The addon auto-enables logging when you log in, so you typically don't need to run any commands.

## Alert Type

| Source | Alert Type | Discord Message |
|--------|------------|-----------------|
| Combat log (boss NPC detected) | `COMBAT_DETECTED` | `@tbc WORLD BOSS: Doom Lord Kazzak detected in combat!` |

## Combat Log Format

The bridge parses WoW's combat log format:

```
M/D HH:MM:SS.mmm  SUBEVENT,sourceGUID,sourceName,...
```

GUID format for creatures:
```
Creature-0-server-instance-zone-NPCID-spawn
```

Example line:
```
3/23 14:30:45.123  SPELL_DAMAGE,Creature-0-5571-530-31401-18728-00005F3A2B,"Doom Lord Kazzak",...
```

The bridge extracts `18728` from position 5 of the GUID and matches it against known boss IDs.

## Relevant Combat Events

The bridge watches for these combat events:
- `SPELL_CAST_START`, `SPELL_CAST_SUCCESS`
- `SPELL_DAMAGE`, `SWING_DAMAGE`, `RANGE_DAMAGE`
- `SPELL_AURA_APPLIED`

## Requirements

- Must be within ~50 yards of boss combat to receive combat log events
- Someone must be actively fighting the boss for events to appear
- Combat logging must be enabled (addon does this automatically)

## Testing

1. Login to WoW - addon auto-enables combat logging
2. Start `python bridge.py`
3. Engage or stand near a world boss fight (within 50 yards)
4. Verify alert appears in Discord within ~1 second

## Bot Setup

This addon requires the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) to be running. The bot provides the `/webhook/alert` endpoint that receives alerts from bridge.py.

Make sure your bot has the `CHANNEL_IDS` environment variable set to the Discord channel(s) where alerts should be posted.

## Troubleshooting

### Alerts not appearing in Discord

1. Check that `bridge.py` is running
2. Verify `LOGS_DIR` points to the correct Logs directory
3. Ensure combat logging is enabled (`/wba status`)
4. Ensure the bot is running and connected to Discord
5. Check the bridge console for errors
6. Verify you're within 50 yards of the combat

### Log file not found

1. Run `/combatlog` in WoW to create a combat log file
2. Verify `WoWCombatLog-*.txt` files exist in `_anniversary_/Logs/`
3. Make sure `LOGS_DIR` in `bridge.py` points to the Logs directory

### Bridge restarts reading old messages

The bridge saves its position in `bridge_state.json`. On restart, it resumes from where it left off. If you want to start fresh, delete `bridge_state.json`.

### No alerts during boss fight

- Ensure you're within 50 yards of the combat
- The boss must be actively fighting (not just spawned)
- Check that combat logging is enabled with `/wba status`

## File Structure

```
WorldBossAnnouncer/
├── WorldBossAnnouncer.toc    # Addon metadata (Interface 20504)
├── WorldBossAnnouncer.lua    # Main addon code
├── bridge.py                 # Python bridge script
├── run_bridge.command        # macOS launcher (double-click)
├── run_bridge.bat            # Windows launcher (double-click)
├── requirements.txt          # Python dependencies
├── bridge_state.json         # Bridge position state (auto-created)
└── README.md
```

## Version History

| Version | Detection Method | Notes |
|---------|------------------|-------|
| v1 | SavedVariables | Required /reload |
| v2 | Chat log tailing | Real-time, pattern matching |
| v3 | Combat log tailing | Real-time, NPC ID matching |

## License

MIT
