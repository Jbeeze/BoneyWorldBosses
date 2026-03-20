# World Boss Announcer

A WoW Classic TBC Anniversary addon that detects world boss activity and forwards alerts to Discord via the [WorldBossTracker](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) bot.

## How It Works

```
┌─────────────────┐     ┌──────────────────┐     ┌─────────────────┐     ┌─────────┐
│  WoW Addon      │ ──► │  SavedVariables  │ ──► │  bridge.py      │ ──► │  Bot    │ ──► Discord
│  (in-game)      │     │  (local file)    │     │  (local script) │     │ (Render)│
└─────────────────┘     └──────────────────┘     └─────────────────┘     └─────────┘
```

1. **WoW Addon** captures boss yells and general chat mentions, stores them in SavedVariables
2. **bridge.py** polls the SavedVariables file every 5 seconds
3. New alerts are POSTed to the **WorldBossTracker bot** API
4. Bot posts formatted messages to your **Discord** channel

## Features

- **Boss Yell Detection**: Automatically detects when Doom Lord Kazzak or Doomwalker yells (spawns)
- **General Chat Monitoring**: Watches for players mentioning "kazzak" or "doomwalker" in General chat
- **Manual Announcements**: Use `/wba announce` to report a boss sighting
- **Auto-Reload**: Periodically reloads UI to flush alerts (configurable)

## Installation

### 1. Install the WoW Addon

Copy the addon files to your WoW Classic AddOns folder:

```
WoW/_classic_/Interface/AddOns/DiscordBridge/
├── DiscordBridge.toc
└── DiscordBridge.lua
```

Or clone directly:
```bash
cd "/path/to/WoW/_classic_/Interface/AddOns"
git clone https://github.com/Jbeeze/WorldBossAnnouncer.git DiscordBridge
```

### 2. Configure the Python Bridge

Install dependencies:
```bash
pip install -r requirements.txt
```

Edit `bridge.py` and set your configuration:
```python
CONFIG = {
    # Your WorldBossTracker bot URL
    "BOT_API_URL": "https://worldbosstrackerdiscordbot.onrender.com",

    # Path to SavedVariables file
    # macOS: /Applications/World of Warcraft/_classic_/WTF/Account/ACCOUNTNAME/SavedVariables/DiscordBridge.lua
    # Windows: C:\Program Files\World of Warcraft\_classic_\WTF\Account\ACCOUNTNAME\SavedVariables\DiscordBridge.lua
    "SV_PATH": "/path/to/WTF/Account/ACCOUNTNAME/SavedVariables/DiscordBridge.lua",

    # How often to check for new alerts (seconds)
    "POLL_INTERVAL": 5,
}
```

### 3. Run the Bridge

Run while playing WoW:
```bash
python bridge.py
```

The bridge must run on the same machine as WoW since it reads local SavedVariables.

## In-Game Commands

| Command | Description |
|---------|-------------|
| `/wba` | Show help |
| `/wba announce <boss> [layer]` | Announce a boss sighting (auto-reloads UI) |
| `/wba status` | Show queue and config status |
| `/wba test` | Send a test alert |
| `/wba flush` | Clear the message queue |
| `/wba autoreload on/off` | Toggle auto-reload (default: on) |
| `/wba interval <seconds>` | Set auto-reload interval (default: 120s) |
| `/wba bosses on/off` | Toggle boss yell monitoring |
| `/wba general on/off` | Toggle general chat monitoring |
| `/wba enable/disable` | Enable or disable the addon |

### Examples

```
/wba announce kazzak 1      -- Announce Kazzak on Layer 1
/wba announce doomwalker 2  -- Announce Doomwalker on Layer 2
/wba status                 -- Check how many alerts are queued
```

## Alert Types

| Type | Trigger | Discord Message |
|------|---------|-----------------|
| **BOSS_YELL** | Boss yells in-game | `@everyone 🚨 WORLD BOSS SPOTTED: Doom Lord Kazzak` |
| **PLAYER_ANNOUNCE** | `/wba announce` command | `@everyone 🚨 WORLD BOSS UP: Doom Lord Kazzak - Layer 1` |
| **PLAYER_REPORT** | "kazzak" mentioned in General | `👀 Player Report (KAZZAK)` |

## Bot Setup

This addon requires the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot) to be running. The bot provides the `/webhook/alert` endpoint that receives alerts from bridge.py.

Make sure your bot has the `CHANNEL_IDS` environment variable set to the Discord channel(s) where alerts should be posted.

## Troubleshooting

### Alerts not appearing in Discord

1. Check that `bridge.py` is running
2. Verify the `SV_PATH` points to the correct SavedVariables file
3. Ensure the bot is running and connected to Discord
4. Check the bridge console for errors

### SavedVariables file not found

The SavedVariables file is only created after:
1. Logging into a character with the addon enabled
2. Running `/reload` or logging out

### Testing the connection

1. In-game: `/wba test` then `/reload`
2. Check bridge.py console for `[ALERT] TEST`
3. Verify message appears in Discord

## File Structure

```
WorldBossAnnouncer/
├── DiscordBridge.toc    # Addon metadata (Interface 20504)
├── DiscordBridge.lua    # Main addon code
├── bridge.py            # Python bridge script
├── requirements.txt     # Python dependencies
└── README.md
```

## License

MIT
