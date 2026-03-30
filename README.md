# Boney World Bosses

A WoW Classic addon + companion app that automatically detects world boss activity (Kazzak and Doomwalker) and reports it to your Discord server. When you're near a boss fight, it picks up the action from your combat log and sends an alert to Discord within seconds. It can also report boss kills with layer and timing info, and keep your server updated on active layers.

Works with the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot).

---

## Installation

### Step 1: Install the WoW Addon

Download or clone this repo into your WoW AddOns folder:

```
World of Warcraft/_anniversary_/Interface/AddOns/BoneyWorldBosses/
```

You should end up with these files inside that folder:
- `BoneyWorldBosses.toc`
- `BoneyWorldBosses.lua`

### Step 2: Install Python

The bridge is a small Python script that runs on your computer alongside WoW. You need Python 3 installed.

- Download from [python.org](https://www.python.org/downloads/)
- **Windows users**: make sure to check **"Add Python to PATH"** during installation

### Step 3: Set Your Discord Server ID

Open `bridge.py` in any text editor (Notepad, TextEdit, etc.) and find this section near the top:

```python
# Discord guild/server ID (required)
# e.g. "GUILD_ID": "1234567890123456789",
"GUILD_ID": "",
```

Replace the empty quotes with your Discord server ID:

1. Open Discord
2. Right-click your server name in the sidebar
3. Click **Copy Server ID** (if you don't see this, go to Settings > Advanced > turn on **Developer Mode**)
4. Paste the ID between the quotes

It should look like:
```python
"GUILD_ID": "1234567890123456789",
```

Save the file.

### Step 4: Create a Desktop Shortcut

The repo includes launcher files you can double-click to start the bridge:

**macOS:**
1. Find `run_bridge.command` in the addon folder
2. Right-click it and drag to your Desktop, then choose **Make Alias** (or Option-drag to copy)
3. If macOS blocks it the first time: right-click > **Open**, then click **Open** in the dialog

**Windows:**
1. Find `run_bridge.bat` in the addon folder
2. Right-click it > **Send to** > **Desktop (create shortcut)**

### Step 5: Run the Bridge

Double-click the shortcut you just created. A terminal window will open showing the bridge status. It will:
- Automatically install the `requests` package if needed
- Auto-detect your WoW Logs folder
- Start watching for boss activity

The bridge needs to stay running while you play. Just leave the terminal window open in the background.

> **Note**: If the bridge can't find your Logs folder automatically, open `bridge.py` and set `LOGS_DIR` to the path manually (e.g., `C:/Program Files/World of Warcraft/_anniversary_/Logs`).

---

## In-Game Setup

### Enable Advanced Combat Logging

This is required for the addon to detect boss fights. You only need to do this once:

1. Open WoW and log into a character
2. Press **Escape** > **System** > **Network**
3. Check **Advanced Combat Logging**

### Start Combat Logging

Type `/combatlog` in the chat window. You should see:

> Combat being logged to Logs/WoWCombatLog.txt

The addon's Scout mode does this automatically when you log in, but running it manually the first time ensures the log file is created.

---

## Testing

### Verify Everything Is Working

1. Make sure the bridge is running (double-click your shortcut)
2. Log into WoW
3. Type `/bwb status` to check the addon is active -- you should see Scout and Reporter both **enabled**

### Quick Test (No Boss Required)

You can test the full reporting flow without finding an actual world boss:

1. Type `/bwb test kill` in chat -- this arms test mode
2. Kill any creature (a boar, a critter, anything)
3. A popup appears with the test kill details
4. Click **Report Kill** (this triggers a /reload)
5. The bridge picks it up and sends a test alert to Discord (marked as a test)

### Commands

| Command | What it does |
|---------|-------------|
| `/bwb` | Show help |
| `/bwb status` | Check if Scout and Reporter modes are on |
| `/bwb scout on` or `off` | Toggle real-time boss detection |
| `/bwb reporter on` or `off` | Toggle kill reporting |
| `/bwb layers` | Send current layer info to Discord |
| `/bwb test kill` | Test mode -- next kill triggers a test report |
| `/bwb log status` | See pending kill reports |
| `/bwb options` | Open addon settings panel |

---

## Troubleshooting

**Bridge says "GUILD_ID is not set"**
Open `bridge.py` and add your Discord server ID (see Step 3 above).

**No alerts in Discord**
- Is the bridge running? Check the terminal window for errors.
- Is combat logging on? Type `/combatlog` in WoW.
- Is Advanced Combat Logging enabled? Check Escape > System > Network.
- Are you close enough? You need to be within ~50 yards of the boss fight.

**Bridge can't find the log file**
Run `/combatlog` in WoW to create the file, then restart the bridge.

**"Python is not installed" error**
Install Python 3 from [python.org](https://www.python.org/downloads/). Windows users: make sure "Add Python to PATH" is checked.
