#!/usr/bin/env python3
"""
World Boss Announcer - Discord Bridge v3
Tails WoWCombatLog for Kazzak/Doomwalker detection and posts to Discord bot.
Automatically finds the most recent combat log file.
Real-time alerts with no /reload required!
"""

import glob
import json
import os
import sys
import time
from pathlib import Path

import requests

# =============================================================================
# CONFIGURATION - Edit these values
# =============================================================================
CONFIG = {
    # Bot API URL (your WorldBossTracker bot)
    # Local: http://localhost:3000
    # Render: https://worldbosstrackerdiscordbot.onrender.com
    "BOT_API_URL": "https://worldbosstrackerdiscordbot.onrender.com",

    # Path to WoW Logs directory (NOT the specific file!)
    # macOS: /Applications/World of Warcraft/_anniversary_/Logs
    # Windows: C:\Program Files\World of Warcraft\_anniversary_\Logs
    "LOGS_DIR": "",

    # Seconds between checking for new log lines
    "POLL_INTERVAL": 1,

    # Deduplication window in seconds (avoid spam from continuous combat)
    "DEDUP_WINDOW": 30,
}

# State file path (same directory as this script)
STATE_FILE = Path(__file__).parent / "bridge_state.json"

# =============================================================================
# BOSS NPC IDS
# =============================================================================

# World boss NPC IDs (extracted from combat log GUIDs)
BOSS_NPC_IDS = {
    "18728": "Doom Lord Kazzak",
    "17711": "Doomwalker",
}

# Combat events that indicate boss activity
COMBAT_EVENTS = {
    "SPELL_CAST_START",
    "SPELL_CAST_SUCCESS",
    "SPELL_DAMAGE",
    "SWING_DAMAGE",
    "RANGE_DAMAGE",
    "SPELL_AURA_APPLIED",
}

# =============================================================================
# COMBAT LOG PARSING
# =============================================================================

# Combat log format:
# M/D HH:MM:SS.mmm  SUBEVENT,sourceGUID,sourceName,...
# GUID format: Creature-0-server-instance-zone-NPCID-spawn
# Example: Creature-0-5571-530-31401-18728-00005F3A2B

def extract_npc_id_from_guid(guid: str) -> str | None:
    """
    Extract NPC ID from a creature GUID.
    GUID format: Creature-0-server-instance-zone-NPCID-spawn
    Returns: NPC ID string or None
    """
    if not guid or not guid.startswith("Creature-"):
        return None

    parts = guid.split("-")
    if len(parts) >= 6:
        return parts[5]  # NPC ID is at index 5
    return None


def parse_combat_line(line: str) -> dict | None:
    """
    Parse a combat log line and return structured data if it contains a boss.
    Returns: {"boss_name": str, "event": str, "source_name": str} or None
    """
    line = line.strip()
    if not line:
        return None

    # Split timestamp from event data
    # Format: "M/D HH:MM:SS.mmm  EVENT,..."
    parts = line.split("  ", 1)  # Two spaces separate timestamp from data
    if len(parts) != 2:
        return None

    event_data = parts[1]
    if not event_data:
        return None

    # Split the CSV event data
    fields = event_data.split(",")
    if len(fields) < 3:
        return None

    event_type = fields[0]

    # Only process relevant combat events
    if event_type not in COMBAT_EVENTS:
        return None

    # Extract source GUID (field index 1) and source name (field index 2)
    source_guid = fields[1]
    source_name = fields[2].strip('"') if len(fields) > 2 else ""

    # Check if source is a boss
    npc_id = extract_npc_id_from_guid(source_guid)
    if npc_id and npc_id in BOSS_NPC_IDS:
        return {
            "boss_name": BOSS_NPC_IDS[npc_id],
            "npc_id": npc_id,
            "event": event_type,
            "source_name": source_name,
        }

    # Also check dest GUID for damage events (player attacking boss)
    if len(fields) >= 6:
        dest_guid = fields[4]
        dest_name = fields[5].strip('"') if len(fields) > 5 else ""

        npc_id = extract_npc_id_from_guid(dest_guid)
        if npc_id and npc_id in BOSS_NPC_IDS:
            return {
                "boss_name": BOSS_NPC_IDS[npc_id],
                "npc_id": npc_id,
                "event": event_type,
                "source_name": dest_name,
            }

    return None


# =============================================================================
# DEDUPLICATION
# =============================================================================

# Track last alert time per boss to avoid spam
_last_alert_times: dict[str, float] = {}


def should_alert(boss_name: str) -> bool:
    """Check if we should send an alert for this boss (deduplication)."""
    now = time.time()
    last_time = _last_alert_times.get(boss_name, 0)

    if now - last_time >= CONFIG["DEDUP_WINDOW"]:
        _last_alert_times[boss_name] = now
        return True

    return False


# =============================================================================
# BOT API
# =============================================================================

def post_to_bot(alert: dict) -> bool:
    """Post alert to bot API. Returns True on success."""
    if not CONFIG["BOT_API_URL"]:
        print("[ERROR] No bot API URL configured!")
        return False

    api_url = CONFIG["BOT_API_URL"].rstrip("/") + "/webhook/alert"

    try:
        response = requests.post(api_url, json=alert, timeout=10)

        if response.status_code == 503:
            print("[ERROR] Bot not connected to Discord yet")
            return False

        if response.status_code not in (200, 201):
            print(f"[ERROR] Bot API returned {response.status_code}: {response.text}")
            return False

        result = response.json()
        print(f"[BOT] Alert sent to {result.get('channelsSent', 0)} channel(s)")
        return True

    except requests.RequestException as e:
        print(f"[ERROR] Network error: {e}")
        return False


# =============================================================================
# STATE MANAGEMENT
# =============================================================================

def load_state() -> dict:
    """Load the bridge state from file."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {"last_inode": 0, "last_pos": 0}


def save_state(state: dict) -> None:
    """Save the bridge state to file."""
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


# =============================================================================
# FILE TAILING
# =============================================================================

def find_latest_combat_log() -> str | None:
    """
    Find the most recent combat log file in the Logs directory.
    Combat logs are named: WoWCombatLog-MMDDYY_HHMMSS.txt
    Returns: Full path to the most recent file, or None if not found.
    """
    logs_dir = CONFIG["LOGS_DIR"]
    if not logs_dir or not os.path.isdir(logs_dir):
        return None

    # Find all combat log files
    pattern = os.path.join(logs_dir, "WoWCombatLog*.txt")
    log_files = glob.glob(pattern)

    if not log_files:
        return None

    # Return the most recently modified file
    return max(log_files, key=os.path.getmtime)


def get_file_info(path: str) -> tuple:
    """Get inode and size of file. Returns (inode, size) or (0, 0) if not found."""
    try:
        stat = os.stat(path)
        return (stat.st_ino, stat.st_size)
    except OSError:
        return (0, 0)


def tail_log_file():
    """
    Generator that yields new lines from the combat log file.
    Automatically finds and switches to the latest combat log file.
    Handles file rotation (WoW creates new files with /combatlog).
    """
    state = load_state()

    current_log_path = None
    last_inode = state.get("last_inode", 0)
    last_pos = state.get("last_pos", 0)
    last_log_file = state.get("last_log_file", "")

    file_handle = None

    while True:
        try:
            # Find the latest combat log file
            latest_log = find_latest_combat_log()

            if not latest_log:
                if file_handle:
                    file_handle.close()
                    file_handle = None
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Check if we switched to a new log file
            if latest_log != current_log_path:
                if current_log_path is not None:
                    print(f"[TAIL] New combat log detected!")
                    print(f"[TAIL]   Old: {os.path.basename(current_log_path)}")
                    print(f"[TAIL]   New: {os.path.basename(latest_log)}")

                current_log_path = latest_log

                # If this is a different file than last session, start fresh
                if current_log_path != last_log_file:
                    last_inode = 0
                    last_pos = 0

                if file_handle:
                    file_handle.close()
                    file_handle = None

            # Get current file info
            current_inode, current_size = get_file_info(current_log_path)

            # Detect file rotation (inode changed or file shrunk)
            file_rotated = False
            if current_inode != last_inode:
                if last_inode != 0:
                    print(f"[TAIL] File rotated (inode changed: {last_inode} -> {current_inode})")
                file_rotated = True
            elif current_size < last_pos:
                print(f"[TAIL] File rotated (size shrunk: {last_pos} -> {current_size})")
                file_rotated = True

            # Reopen file if rotated or not open
            if file_rotated or file_handle is None:
                if file_handle:
                    file_handle.close()

                file_handle = open(current_log_path, "r", encoding="utf-8", errors="replace")

                if file_rotated and last_inode != 0:
                    # Start from end to ignore history on rotation
                    file_handle.seek(0, 2)
                    last_pos = file_handle.tell()
                    print(f"[TAIL] Starting from end of file (pos {last_pos})")
                elif last_pos > 0:
                    # Resume from last known position
                    file_handle.seek(last_pos)
                    print(f"[TAIL] Resumed from position {last_pos}")
                else:
                    # New file, start from end
                    file_handle.seek(0, 2)
                    last_pos = file_handle.tell()
                    print(f"[TAIL] Watching: {os.path.basename(current_log_path)}")
                    print(f"[TAIL] Starting from end (pos {last_pos})")

                last_inode = current_inode

                # Save state
                state["last_inode"] = last_inode
                state["last_pos"] = last_pos
                state["last_log_file"] = current_log_path
                save_state(state)

            # Read new lines
            while True:
                line = file_handle.readline()
                if line:
                    last_pos = file_handle.tell()
                    yield line
                else:
                    break

            # Save position periodically
            state["last_pos"] = last_pos
            save_state(state)

            time.sleep(CONFIG["POLL_INTERVAL"])

        except KeyboardInterrupt:
            raise
        except Exception as e:
            print(f"[ERROR] Tail error: {e}")
            if file_handle:
                file_handle.close()
                file_handle = None
            time.sleep(CONFIG["POLL_INTERVAL"])


# =============================================================================
# MAIN LOOP
# =============================================================================

def process_line(line: str) -> None:
    """Process a single log line and send alerts if needed."""
    result = parse_combat_line(line)
    if not result:
        return

    boss_name = result["boss_name"]

    # Check deduplication
    if not should_alert(boss_name):
        return

    print(f"[ALERT] COMBAT_DETECTED: {boss_name} (NPC {result['npc_id']}) - {result['event']}")

    alert = {
        "alertType": "COMBAT_DETECTED",
        "boss": boss_name,
        "npcId": result["npc_id"],
        "event": result["event"],
        "msg": f"{boss_name} detected in combat!",
        "channel": "combat_log",
    }
    post_to_bot(alert)


def main_loop() -> None:
    """Main processing loop."""
    print(f"[WorldBossAnnouncer] Starting bridge v3 (combat log)...")
    print(f"  Bot API: {CONFIG['BOT_API_URL']}")
    print(f"  Logs dir: {CONFIG['LOGS_DIR']}")
    print(f"  Poll interval: {CONFIG['POLL_INTERVAL']}s")
    print(f"  Dedup window: {CONFIG['DEDUP_WINDOW']}s")
    print(f"  Watching for NPC IDs: {', '.join(BOSS_NPC_IDS.keys())}")
    print(f"  Boss names: {', '.join(BOSS_NPC_IDS.values())}")
    print()

    # Show current combat log file
    latest = find_latest_combat_log()
    if latest:
        print(f"[TAIL] Found combat log: {os.path.basename(latest)}")
    else:
        print(f"[TAIL] No combat log found yet. Run /combatlog in WoW to start one.")
    print()

    try:
        for line in tail_log_file():
            process_line(line)
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Received interrupt, exiting...")


def validate_config() -> bool:
    """Validate configuration before starting."""
    errors = []

    if not CONFIG["BOT_API_URL"]:
        errors.append("BOT_API_URL is not set")

    if not CONFIG["LOGS_DIR"]:
        errors.append("LOGS_DIR is not set")
    elif not os.path.isdir(CONFIG["LOGS_DIR"]):
        errors.append(f"LOGS_DIR does not exist: {CONFIG['LOGS_DIR']}")

    if errors:
        print("[CONFIG ERROR] Please fix the following issues:")
        for error in errors:
            print(f"  - {error}")
        print()
        print("Edit the CONFIG section at the top of this script.")
        return False

    return True


if __name__ == "__main__":
    print("=" * 60)
    print("  World Boss Announcer - Bridge v3.0")
    print("  Combat log detection (real-time!)")
    print("  Watches for Kazzak/Doomwalker NPC IDs")
    print("=" * 60)
    print()

    if not validate_config():
        sys.exit(1)

    main_loop()
