#!/usr/bin/env python3
"""
World Boss Announcer - Discord Bridge
Polls WoW SavedVariables for Kazzak/Doomwalker alerts and posts to Discord bot.
Target: TBC Anniversary addon (DiscordBridge)
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
    # Render: https://your-app-name.onrender.com
    "BOT_API_URL": "http://localhost:3000",

    # Path to SavedVariables file (required)
    # Example: /path/to/WoW/_classic_/WTF/Account/ACCOUNTNAME/SavedVariables/DiscordBridge.lua
    "SV_PATH": "",

    # Seconds between polling checks
    "POLL_INTERVAL": 5,

    # Filter which channels to forward (empty list = all)
    # Options: boss_yell, general, announce, test
    "CHANNEL_FILTER": ["boss_yell", "general", "announce", "test"],
}

# State file path (same directory as this script)
STATE_FILE = Path(__file__).parent / "bridge_state.json"


# =============================================================================
# LUA PARSER - Regex-based parser for SavedVariables
# =============================================================================

def parse_lua_value(content: str, pos: int) -> tuple:
    """Parse a Lua value starting at position pos. Returns (value, new_pos)."""
    # Skip whitespace
    while pos < len(content) and content[pos] in ' \t\n\r':
        pos += 1

    if pos >= len(content):
        return None, pos

    char = content[pos]

    # String (double quote)
    if char == '"':
        end = pos + 1
        while end < len(content):
            if content[end] == '\\' and end + 1 < len(content):
                end += 2
                continue
            if content[end] == '"':
                break
            end += 1
        # Decode escape sequences
        raw = content[pos + 1:end]
        try:
            value = raw.encode().decode('unicode_escape')
        except:
            value = raw
        return value, end + 1

    # String (single quote)
    if char == "'":
        end = pos + 1
        while end < len(content):
            if content[end] == '\\' and end + 1 < len(content):
                end += 2
                continue
            if content[end] == "'":
                break
            end += 1
        raw = content[pos + 1:end]
        try:
            value = raw.encode().decode('unicode_escape')
        except:
            value = raw
        return value, end + 1

    # Table
    if char == '{':
        return parse_lua_table(content, pos)

    # Boolean/nil
    if content[pos:pos+4] == 'true':
        return True, pos + 4
    if content[pos:pos+5] == 'false':
        return False, pos + 5
    if content[pos:pos+3] == 'nil':
        return None, pos + 3

    # Number
    num_match = re.match(r'-?\d+\.?\d*', content[pos:])
    if num_match:
        num_str = num_match.group()
        if '.' in num_str:
            return float(num_str), pos + len(num_str)
        return int(num_str), pos + len(num_str)

    return None, pos


def parse_lua_table(content: str, pos: int) -> tuple:
    """Parse a Lua table starting at position pos. Returns (table_dict, new_pos)."""
    if content[pos] != '{':
        return None, pos

    pos += 1
    result = {}
    array_index = 1

    while pos < len(content):
        # Skip whitespace and commas
        while pos < len(content) and content[pos] in ' \t\n\r,':
            pos += 1

        if pos >= len(content):
            break

        # End of table
        if content[pos] == '}':
            return result, pos + 1

        # Check for key assignment
        # [key] = value or key = value
        if content[pos] == '[':
            # Bracketed key
            end_bracket = content.find(']', pos)
            if end_bracket == -1:
                break
            key_content = content[pos + 1:end_bracket].strip()
            if key_content.startswith('"') or key_content.startswith("'"):
                key = key_content[1:-1]
            else:
                try:
                    key = int(key_content)
                except:
                    key = key_content
            pos = end_bracket + 1
            # Skip whitespace and =
            while pos < len(content) and content[pos] in ' \t\n\r':
                pos += 1
            if pos < len(content) and content[pos] == '=':
                pos += 1
            value, pos = parse_lua_value(content, pos)
            result[key] = value
        elif re.match(r'[a-zA-Z_]', content[pos:pos+1]):
            # Named key
            key_match = re.match(r'([a-zA-Z_][a-zA-Z0-9_]*)', content[pos:])
            if key_match:
                key = key_match.group(1)
                pos += len(key)
                # Skip whitespace
                while pos < len(content) and content[pos] in ' \t\n\r':
                    pos += 1
                if pos < len(content) and content[pos] == '=':
                    pos += 1
                    value, pos = parse_lua_value(content, pos)
                    result[key] = value
                else:
                    # It's an array value that happens to look like a key
                    result[array_index] = key
                    array_index += 1
        else:
            # Array value
            value, pos = parse_lua_value(content, pos)
            if value is not None:
                result[array_index] = value
                array_index += 1

    return result, pos


def parse_lua_savedvars(filepath: str) -> dict:
    """Parse a WoW SavedVariables Lua file and return as Python dict."""
    with open(filepath, 'r', encoding='utf-8') as f:
        content = f.read()

    result = {}

    # Find all top-level assignments like: VariableName = { ... }
    pattern = r'([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*'

    pos = 0
    while pos < len(content):
        match = re.search(pattern, content[pos:])
        if not match:
            break

        var_name = match.group(1)
        value_start = pos + match.end()

        value, new_pos = parse_lua_value(content, value_start)
        if value is not None:
            result[var_name] = value

        pos = new_pos if new_pos > pos else pos + match.end()

    return result


# =============================================================================
# STATE MANAGEMENT
# =============================================================================

def load_state() -> dict:
    """Load the bridge state from file."""
    if STATE_FILE.exists():
        try:
            with open(STATE_FILE, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            pass
    return {"last_sent_id": 0}


def save_state(state: dict) -> None:
    """Save the bridge state to file."""
    with open(STATE_FILE, 'w') as f:
        json.dump(state, f, indent=2)


# =============================================================================
# BOT API
# =============================================================================

def post_to_bot(entries: list) -> bool:
    """Post entries to bot API. Returns True on success."""
    if not CONFIG["BOT_API_URL"]:
        print("[ERROR] No bot API URL configured!")
        return False

    if not entries:
        return True

    api_url = CONFIG["BOT_API_URL"].rstrip("/") + "/webhook/alert"

    # Process each entry
    for entry in entries:
        # Build payload matching what the bot expects
        payload = {
            "alertType": entry.get("alertType", ""),
            "author": entry.get("author", "Unknown"),
            "msg": entry.get("msg", ""),
            "channel": entry.get("channel", ""),
            "zone": entry.get("zone", ""),
            "subzone": entry.get("subzone", ""),
            "keyword": entry.get("keyword", ""),
            "boss": entry.get("boss", ""),
            "layer": entry.get("layer", ""),
        }

        try:
            response = requests.post(api_url, json=payload, timeout=10)

            if response.status_code == 503:
                print("[ERROR] Bot not connected to Discord yet")
                return False

            if response.status_code not in (200, 201):
                print(f"[ERROR] Bot API returned {response.status_code}: {response.text}")
                return False

            result = response.json()
            print(f"[BOT] Alert sent to {result.get('channelsSent', 0)} channel(s)")

            # Small delay between messages
            time.sleep(0.3)

        except requests.RequestException as e:
            print(f"[ERROR] Network error: {e}")
            return False

    return True


# =============================================================================
# MAIN LOOP
# =============================================================================

def main_loop() -> None:
    """Main polling loop."""
    print(f"[WorldBossAnnouncer] Starting bridge...")
    print(f"  Bot API: {CONFIG['BOT_API_URL']}")
    print(f"  SavedVariables: {CONFIG['SV_PATH']}")
    print(f"  Poll interval: {CONFIG['POLL_INTERVAL']}s")
    print(f"  Watching for: Kazzak, Doomwalker")
    print()

    state = load_state()
    print(f"[STATE] Last sent ID: {state['last_sent_id']}")

    while True:
        try:
            # Check if file exists
            if not os.path.exists(CONFIG["SV_PATH"]):
                # Silent wait - file might not exist yet
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Parse SavedVariables
            try:
                data = parse_lua_savedvars(CONFIG["SV_PATH"])
            except Exception as e:
                print(f"[ERROR] Failed to parse SavedVariables: {e}")
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Get queue from parsed data
            db = data.get("DiscordBridgeDB", {})
            queue = db.get("queue", {})

            # Convert queue dict to sorted list (Lua arrays are 1-indexed dicts)
            if isinstance(queue, dict):
                queue_list = [queue[k] for k in sorted(queue.keys()) if isinstance(queue[k], dict)]
            else:
                queue_list = []

            if not queue_list:
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Filter new entries
            last_id = state["last_sent_id"]
            new_entries = [
                entry for entry in queue_list
                if entry.get("id", 0) > last_id
            ]

            # Apply channel filter
            if CONFIG["CHANNEL_FILTER"]:
                new_entries = [
                    entry for entry in new_entries
                    if entry.get("channel", "").lower() in CONFIG["CHANNEL_FILTER"]
                ]

            if not new_entries:
                time.sleep(CONFIG["POLL_INTERVAL"])
                continue

            # Sort by ID to ensure order
            new_entries.sort(key=lambda x: x.get("id", 0))

            # Log what we found
            for entry in new_entries:
                alert_type = entry.get("alertType", "UNKNOWN")
                author = entry.get("author", "?")
                print(f"[ALERT] {alert_type}: {author}")

            # Post to bot
            if post_to_bot(new_entries):
                # Update state with highest ID sent
                max_id = max(entry.get("id", 0) for entry in new_entries)
                state["last_sent_id"] = max_id
                save_state(state)
                print(f"[SENT] {len(new_entries)} alert(s), last ID: {max_id}")

        except KeyboardInterrupt:
            print("\n[SHUTDOWN] Received interrupt, exiting...")
            break
        except Exception as e:
            print(f"[ERROR] Unexpected error: {e}")

        time.sleep(CONFIG["POLL_INTERVAL"])


def validate_config() -> bool:
    """Validate configuration before starting."""
    errors = []

    if not CONFIG["BOT_API_URL"]:
        errors.append("BOT_API_URL is not set")

    if not CONFIG["SV_PATH"]:
        errors.append("SV_PATH is not set")

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
    print("  World Boss Announcer - Bridge v1.0")
    print("  Watches for Kazzak/Doomwalker alerts")
    print("  Posts to WorldBossTracker bot")
    print("=" * 60)
    print()

    if not validate_config():
        sys.exit(1)

    main_loop()
