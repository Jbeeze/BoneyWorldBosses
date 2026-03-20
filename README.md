# World Boss Announcer v2

A WoW Classic TBC Anniversary addon that detects world boss activity and forwards alerts to Discord via the [WorldBossTracker](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) bot.

**Real-time alerts with no /reload required!**

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────┐
│  WoW Engine     │ ──► │  WoWChatLog.txt  │ ──► │  bridge.py      │ ──► │  Bot    │ ──► Discord
│  (live logging) │     │  (real-time)     │     │  (tail -f)      │     │ (Render)│
└─────────────────┘     └──────────────────┘     └─────────────────┘     └─────────┘
```

1. **WoW Engine** writes chat to log file when logging is enabled
2. **Addon** controls `LoggingChat(true/false)` - auto-enabled on load
3. **bridge.py** tails the log file, detects boss patterns, POSTs to bot API
4. **Bot** sends formatted messages to Discord

## Features

- **Real-Time Alerts**: No more `/reload` required - alerts within ~1 second
- **Boss Yell Detection**: Automatically detects when Doom Lord Kazzak or Doomwalker yells (spawns)
- **Guild Chat Monitoring**: Watches for "Kazzak up L1", "Kazz up L2", "Doomwalker up L1" patterns
- **Whisper Monitoring**: Same patterns via whisper, supports `[TEST]` prefix for no-ping testing
- **Simple Addon**: Just enables/disables WoW's built-in chat logging

## Installation

### 1. Initial Setup (One Time)

Before the addon can work, you need to initialize the chat log file:

1. Open WoW
2. Type `/chatlog` in the chat window
3. You should see: "Combat being logged to Logs\WoWChatLog.txt"

This creates the log file that the bridge will tail. You only need to do this once.

### 2. Install the WoW Addon

Copy the addon files to your WoW Classic AddOns folder:

```
WoW/_classic_/Interface/AddOns/WorldBossAnnouncer/
├── WorldBossAnnouncer.toc
└── WorldBossAnnouncer.lua
```

Or clone directly:
```bash
cd "/path/to/WoW/_classic_/Interface/AddOns"
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

    # Path to WoWChatLog.txt
    # macOS: /Applications/World of Warcraft/_classic_/Logs/WoWChatLog.txt
    # Windows: C:\Program Files\World of Warcraft\_classic_\Logs\WoWChatLog.txt
    "CHAT_LOG_PATH": "/path/to/WoW/_classic_/Logs/WoWChatLog.txt",

    # How often to check for new lines (seconds)
    "POLL_INTERVAL": 1,

    # Which chat channels to watch
    "CHANNEL_FILTER": ["guild", "whisper", "yell"],
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

The bridge must run on the same machine as WoW since it reads local log files.

## In-Game Commands

| Command | Description |
|---------|-------------|
| `/wba` | Show help |
| `/wba logging on` | Enable chat logging |
| `/wba logging off` | Disable chat logging |
| `/wba status` | Show logging status |

The addon auto-enables logging when you log in, so you typically don't need to run any commands.

## Alert Types

| Type | Trigger | Discord Message |
|------|---------|-----------------|
| **BOSS_YELL** | Boss yells in-game | `@everyone WORLD BOSS SPOTTED: Doom Lord Kazzak` |
| **GUILD_REPORT** | "kazzak up L1" in guild chat | `@everyone WORLD BOSS UP: Doom Lord Kazzak - Layer 1` |
| **WHISPER_REPORT** | "kazzak up L1" via whisper | Same as guild report |
| **WHISPER_TEST** | "[TEST] kazzak up L1" via whisper | Test alert (no @everyone ping) |

## Testing

1. Login to WoW - addon auto-enables logging
2. Start `python bridge.py`
3. Have someone type in guild chat: "Kazzak up L1"
4. Verify alert appears in Discord within ~1 second
5. Run `/wba logging off` and verify no more alerts
6. Run `/wba logging on` and verify alerts resume

To test without pinging everyone, whisper yourself with: `[TEST] Kazzak up L1`

## Bot Setup

This addon requires the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) to be running. The bot provides the `/webhook/alert` endpoint that receives alerts from bridge.py.

Make sure your bot has the `CHANNEL_IDS` environment variable set to the Discord channel(s) where alerts should be posted.

## Troubleshooting

### Alerts not appearing in Discord

1. Check that `bridge.py` is running
2. Verify `CHAT_LOG_PATH` points to the correct log file
3. Ensure chat logging is enabled (`/wba status`)
4. Ensure the bot is running and connected to Discord
5. Check the bridge console for errors

### Log file not found

1. Run `/chatlog` in WoW to initialize the file
2. Verify `WoWChatLog.txt` exists in `_classic_/Logs/`
3. Make sure the path in `bridge.py` is correct

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
├── bridge_state.json         # Bridge position state (auto-created)
└── README.md
```

## v1 vs v2 Comparison

| Aspect | v1 (SavedVariables) | v2 (Log Tailing) |
|--------|---------------------|------------------|
| Latency | Requires /reload | ~1 second |
| User Action | Click reload popup | None |
| Addon Complexity | Event capture + queue | Simple on/off |
| File Size | Queue capped at 200 | Log grows but bridge ignores history |

## License

MIT
