#!/usr/bin/env python3
"""
World Boss Announcer - Discord Bridge v2
Tails WoWChatLog.txt for Kazzak/Doomwalker alerts and posts to Discord bot.
Real-time alerts with no /reload required!
"""

import json
import os
import re
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

    # Path to WoWChatLog.txt
    # macOS: /Applications/World of Warcraft/_classic_/Logs/WoWChatLog.txt
    # Windows: C:\Program Files\World of Warcraft\_classic_\Logs\WoWChatLog.txt
    "CHAT_LOG_PATH": "",

    # Seconds between checking for new log lines
    "POLL_INTERVAL": 1,

    # Which chat channels to watch (lowercase)
    # Options: guild, whisper, yell, say, party, raid
    "CHANNEL_FILTER": ["guild", "whisper", "yell"],
}

# State file path (same directory as this script)
STATE_FILE = Path(__file__).parent / "bridge_state.json"

# =============================================================================
# BOSS DETECTION PATTERNS
# =============================================================================

# World bosses we care about
WORLD_BOSSES = {
    "Doom Lord Kazzak": ["doom lord kazzak", "kazzak"],
    "Doomwalker": ["doomwalker"],
}

# Guild/whisper patterns: "Kazzak up L1", "Kazz up L2", "Doomwalker up L1", etc.
# Returns (boss_name, layer) if matched
BOSS_PATTERNS = [
    (re.compile(r"[Kk]azzak\s+up\s+[Ll](\d+)", re.IGNORECASE), "Doom Lord Kazzak"),
    (re.compile(r"[Kk]azz\s+up\s+[Ll](\d+)", re.IGNORECASE), "Doom Lord Kazzak"),
    (re.compile(r"[Dd]oomwalker\s+up\s+[Ll](\d+)", re.IGNORECASE), "Doomwalker"),
]

# =============================================================================
# CHAT LOG PARSING
# =============================================================================

# Chat log line format:
# 11/5 20:34:12.442  [Guild] Thrall: Kazzak up L1
# 11/5 20:34:18.330  Sylvanas whispers: Doomwalker up L2
# 11/5 20:34:25.100  [Yell] Doom Lord Kazzak: <boss yell text>

LOG_LINE_PATTERNS = {
    # [Guild] PlayerName: message
    "guild": re.compile(r"^\d+/\d+\s+[\d:.]+\s+\[Guild\]\s+([^:]+):\s+(.+)$"),
    # PlayerName whispers: message
    "whisper": re.compile(r"^\d+/\d+\s+[\d:.]+\s+([^\s]+)\s+whispers:\s+(.+)$"),
    # [Yell] PlayerName: message (or boss name)
    "yell": re.compile(r"^\d+/\d+\s+[\d:.]+\s+\[Yell\]\s+([^:]+):\s+(.+)$"),
    # [Say] PlayerName: message
    "say": re.compile(r"^\d+/\d+\s+[\d:.]+\s+\[Say\]\s+([^:]+):\s+(.+)$"),
    # [Party] PlayerName: message
    "party": re.compile(r"^\d+/\d+\s+[\d:.]+\s+\[Party\]\s+([^:]+):\s+(.+)$"),
    # [Raid] PlayerName: message
    "raid": re.compile(r"^\d+/\d+\s+[\d:.]+\s+\[Raid\]\s+([^:]+):\s+(.+)$"),
}


def parse_log_line(line: str) -> dict | None:
    """
    Parse a chat log line and return structured data if it matches a watched channel.
    Returns: {"channel": str, "author": str, "message": str} or None
    """
    line = line.strip()
    if not line:
        return None

    for channel, pattern in LOG_LINE_PATTERNS.items():
        match = pattern.match(line)
        if match:
            return {
                "channel": channel,
                "author": match.group(1).strip(),
                "message": match.group(2).strip(),
            }

    return None


def check_boss_pattern(message: str) -> tuple | None:
    """
    Check if message matches a boss announcement pattern.
    Returns: (boss_name, layer) or None
    """
    for pattern, boss_name in BOSS_PATTERNS:
        match = pattern.search(message)
        if match:
            layer = match.group(1)
            return (boss_name, layer)
    return None


def check_boss_yell(author: str) -> str | None:
    """
    Check if the author is a world boss (for yell detection).
    Returns: boss_name or None
    """
    author_lower = author.lower()
    for boss_name, aliases in WORLD_BOSSES.items():
        for alias in aliases:
            if alias in author_lower:
                return boss_name
    return None


def is_test_message(message: str) -> bool:
    """Check if message has [TEST] prefix."""
    return message.strip().upper().startswith("[TEST]")


def clean_test_prefix(message: str) -> str:
    """Remove [TEST] prefix from message."""
    return re.sub(r"^\[TEST\]\s*", "", message, flags=re.IGNORECASE)


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

def get_file_info(path: str) -> tuple:
    """Get inode and size of file. Returns (inode, size) or (0, 0) if not found."""
    try:
        stat = os.stat(path)
        return (stat.st_ino, stat.st_size)
    except OSError:
        return (0, 0)


def tail_log_file():
    """
    Generator that yields new lines from the chat log file.
    Handles file rotation (WoW recreates file on reload/relog).
    """
    log_path = CONFIG["CHAT_LOG_PATH"]
    state = load_state()

    last_inode = state.get("last_inode", 0)
    last_pos = state.get("last_pos", 0)

    print(f"[TAIL] Starting from position {last_pos}")

    file_handle = None

    while True:
        try:
            # Check if file exists
            if not os.path.exists(log_path):
                if file_handle:
                    file_handle.close()
                    file_handle = None
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Get current file info
            current_inode, current_size = get_file_info(log_path)

            # Detect file rotation (inode changed or file shrunk)
            file_rotated = False
            if current_inode != last_inode:
                print(f"[TAIL] File rotated (inode changed: {last_inode} -> {current_inode})")
                file_rotated = True
            elif current_size < last_pos:
                print(f"[TAIL] File rotated (size shrunk: {last_pos} -> {current_size})")
                file_rotated = True

            # Reopen file if rotated or not open
            if file_rotated or file_handle is None:
                if file_handle:
                    file_handle.close()

                file_handle = open(log_path, "r", encoding="utf-8", errors="replace")

                if file_rotated:
                    # Start from beginning of new file, but skip to end to ignore history
                    file_handle.seek(0, 2)  # Seek to end
                    last_pos = file_handle.tell()
                    print(f"[TAIL] Reopened file, starting from end (pos {last_pos})")
                else:
                    # Resume from last known position
                    file_handle.seek(last_pos)
                    print(f"[TAIL] Resumed from position {last_pos}")

                last_inode = current_inode

                # Save state
                state["last_inode"] = last_inode
                state["last_pos"] = last_pos
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
    parsed = parse_log_line(line)
    if not parsed:
        return

    channel = parsed["channel"]
    author = parsed["author"]
    message = parsed["message"]

    # Check channel filter
    if CONFIG["CHANNEL_FILTER"] and channel not in CONFIG["CHANNEL_FILTER"]:
        return

    # Check for test message
    is_test = is_test_message(message)
    if is_test:
        message = clean_test_prefix(message)

    # Check for boss yell (boss speaking)
    if channel == "yell":
        boss_name = check_boss_yell(author)
        if boss_name:
            print(f"[ALERT] BOSS_YELL: {boss_name} yelled!")
            alert = {
                "alertType": "BOSS_YELL",
                "author": author,
                "msg": message,
                "channel": "boss_yell",
                "boss": boss_name,
                "layer": "?",
            }
            post_to_bot(alert)
            return

    # Check for boss announcement patterns in guild/whisper/yell
    result = check_boss_pattern(message)
    if result:
        boss_name, layer = result

        alert_type = "WHISPER_TEST" if is_test and channel == "whisper" else (
            "WHISPER_REPORT" if channel == "whisper" else "GUILD_REPORT"
        )

        formatted_msg = f"{boss_name} UP Layer {layer}"
        if is_test:
            formatted_msg = f"[TEST] {formatted_msg}"

        print(f"[ALERT] {alert_type}: {author} reports {boss_name} L{layer}")

        alert = {
            "alertType": alert_type,
            "author": author,
            "msg": formatted_msg,
            "channel": channel,
            "boss": boss_name,
            "layer": layer,
            "reporter": author,
        }
        post_to_bot(alert)


def main_loop() -> None:
    """Main processing loop."""
    print(f"[WorldBossAnnouncer] Starting bridge v2 (log tailing)...")
    print(f"  Bot API: {CONFIG['BOT_API_URL']}")
    print(f"  Chat log: {CONFIG['CHAT_LOG_PATH']}")
    print(f"  Poll interval: {CONFIG['POLL_INTERVAL']}s")
    print(f"  Watching channels: {', '.join(CONFIG['CHANNEL_FILTER'])}")
    print(f"  Watching for: Kazzak, Doomwalker")
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

    if not CONFIG["CHAT_LOG_PATH"]:
        errors.append("CHAT_LOG_PATH is not set")

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
    print("  World Boss Announcer - Bridge v2.0")
    print("  Real-time log tailing (no /reload needed!)")
    print("  Watches for Kazzak/Doomwalker alerts")
    print("=" * 60)
    print()

    if not validate_config():
        sys.exit(1)

    main_loop()
