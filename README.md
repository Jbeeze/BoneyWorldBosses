# Boney World Bosses

A WoW Classic addon + companion bridge that automatically detects world boss activity (Kazzak and Doomwalker) and reports it to your Discord server. When you're near a boss fight, it picks up the action from your combat log and sends an alert to Discord within seconds. It can also report boss kills with layer and timing info, and keep your server updated on active layers.

Works with the [WorldBossTracker Discord bot](https://github.com/Jbeeze/WorldBossTrackerDiscordBot).

> **Architecture.** The addon ships via CurseForge (pure Lua) and stores all user config in WoW's SavedVariables. A small Python companion bridge reads those SavedVariables and forwards events to your Discord bot. The bridge is distributed separately via GitHub Releases — CurseForge rules forbid shipping executables inside an addon.

---

## Install the addon

**CurseForge:** search for *Boney World Bosses* and install. Done.

**Manual:** copy `BoneyWorldBosses.toc` and `BoneyWorldBosses.lua` into
`World of Warcraft/_anniversary_/Interface/AddOns/BoneyWorldBosses/`.

## Install the bridge

Grab the companion bridge for your OS from [GitHub Releases](https://github.com/Jbeeze/WorldBossAnnouncerAddon/releases):

- **Windows:** `bridge.exe` — double-click to run.
- **macOS:** `bridge` (Unix executable). First launch: right-click → **Open** → **Open** to bypass Gatekeeper (we don't notarize). After that it runs normally.
- **Python users:** `bridge.py` + `requirements.txt` — `pip install -r requirements.txt` then `python3 bridge.py`.

The bridge keeps a terminal window open while you play. Leave it running in the background.

On first launch it auto-detects your WoW install (checks the common macOS and Windows paths); if that fails, it prompts you for the folder.

## Configure in-game

Run `/bwb setup` in WoW. A three-step wizard asks for:

1. **Discord Guild ID** (17–19 digit snowflake). Right-click your server in Discord → **Copy Server ID** (enable Developer Mode in Discord Settings → Advanced if you don't see the option).
2. **Your Discord User ID** (17–19 digits). Right-click your name → **Copy User ID**.
3. **Bot API URL** (starts with `https://`). Ask the person who runs your guild's WorldBossTracker bot.

The wizard reloads your UI on completion. The bridge picks up the new config on its next poll (~5 seconds).

Prefer individual commands? `/bwb guild <id>`, `/bwb discord <id>`, `/bwb api <url>`. Each nags you to `/reload` afterward so the bridge sees the change.

## Verify it works

Run `/combatlog` in WoW once to start combat logging. Then:

1. Make sure the bridge terminal window is open and reports `[KILL] Found SavedVariables`.
2. `/bwb status` in WoW — all three config values should show (with Discord IDs masked).
3. `/bwb test kill` → kill any creature → click **Report Kill** → your bot gets a test alert in Discord.

## Slash commands

| Command | Purpose |
|---------|---------|
| `/bwb setup` | Guided setup wizard |
| `/bwb guild <id>` | Set Discord guild id |
| `/bwb discord <id>` | Set your Discord user id |
| `/bwb api <url>` | Set bot API URL |
| `/bwb status` | Show config + mode status |
| `/bwb scout on\|off` | Toggle real-time combat detection |
| `/bwb reporter on\|off` | Toggle kill reporting |
| `/bwb layers` | Send layer snapshot to Discord |
| `/bwb callout` | Post `@everyone` boss callout |
| `/bwb test kill` | Arm test mode (next kill = test report) |
| `/bwb log status\|clear\|update` | Manage pending kill reports |
| `/bwb options` | Open settings panel |

## Troubleshooting

**Bridge prints `[WAIT] In-game setup not complete`**
Run `/bwb setup` in WoW, then `/reload`. The bridge will pick up the config on its next poll. SavedVariables only flush on `/reload` or logout — that's a WoW engine limitation.

**Bridge can't find your WoW install**
It prompts for a path on first run. Paste the folder containing `Logs/` and `WTF/` (usually `_anniversary_` under your WoW install). The path is cached in `bridge_config.json` next to the bridge.

**No alerts in Discord**
- Bridge terminal reports errors? Read them — they're usually explicit (e.g. "Bot API returned 401").
- Combat logging on? Run `/combatlog` once.
- Advanced Combat Logging enabled? **Esc → System → Network**.
- Within ~50 yards of the boss fight? That's the combat-log range.

**macOS says the binary is damaged / unverified**
Right-click the `bridge` binary → **Open** → click **Open** in the dialog. macOS will remember your choice. We don't notarize builds.

---

## For developers

Lua addon code lives in `BoneyWorldBosses.lua`. Python bridge is `bridge.py`.

The bridge is a **dumb forwarder** — it reads boss NPC IDs, display names, and user config from SavedVariables every ~5 seconds and passes opaque payloads (including the addon's `meta.addonVersion` / `meta.schemaVersion` breadcrumb) to the bot API. Adding a new boss is addon-only; bridge doesn't need updates.

CurseForge packaging is controlled by `.pkgmeta` — everything except `.toc` / `.lua` / `README.md` is excluded from the shipped zip.

Bridge releases are built via `.github/workflows/release-bridge.yml` on version tags. PyInstaller produces one-file binaries per platform.
