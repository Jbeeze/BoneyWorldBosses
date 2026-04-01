#!/usr/bin/env python3
"""
Boney World Bosses - Discord Bridge v3.1
Two detection modes:
  - Scout: Tails WoWCombatLog for real-time Kazzak/Doomwalker combat detection
  - Reporter: Reads SavedVariables for kill reports (requires /reload in-game)

Automatically finds the most recent combat log file.
"""

from __future__ import annotations

import glob
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

    # Discord guild/server ID (required)
    # e.g. "GUILD_ID": "1234567890123456789",
    "GUILD_ID": "",

    # Path to WoW Logs directory (NOT the specific file!)
    # macOS: /Applications/World of Warcraft/_anniversary_/Logs
    # Windows: C:/Program Files/World of Warcraft/_anniversary_/Logs
    "LOGS_DIR": "",

    # Seconds between checking for new log lines
    "POLL_INTERVAL": 1,

    # Deduplication window in seconds (avoid spam from continuous combat)
    "DEDUP_WINDOW": 30,

    # How often to check SavedVariables for kill reports (seconds)
    "KILL_REPORT_CHECK_INTERVAL": 5,
}

# State file path (same directory as this script)
SCRIPT_DIR = Path(__file__).parent
STATE_FILE = SCRIPT_DIR / "bridge_state.json"

# Cached character name (read from SavedVariables)
_cached_character_name = ""


def auto_detect_logs_dir() -> str:
    """
    Auto-detect WoW Logs directory from this script's location.
    Expects: WoW/_anniversary_/Interface/AddOns/<AddonName>/bridge.py
    Logs at: WoW/_anniversary_/Logs
    """
    # Go up from AddOns/<AddonName>/ to _anniversary_/
    wow_game_dir = SCRIPT_DIR.parent.parent.parent
    logs_dir = wow_game_dir / "Logs"
    if logs_dir.is_dir():
        return str(logs_dir)
    return ""

# =============================================================================
# BOSS NPC IDS
# =============================================================================

# World boss NPC IDs (extracted from combat log GUIDs)
BOSS_NPC_IDS = {
    "18728": "Doom Lord Kazzak",
    "17711": "Doomwalker",
}

# Boss key mapping (addon uses lowercase keys)
BOSS_KEY_TO_NAME = {
    "kazzak": "Doom Lord Kazzak",
    "doomwalker": "Doomwalker",
    "test": "TEST KILL",
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

# Max age (seconds) for a layer snapshot to be considered fresh
LAYER_STALENESS_WINDOW = 600  # 10 minutes

# =============================================================================
# COMBAT LOG PARSING
# =============================================================================

# Combat log format:
# M/D HH:MM:SS.mmm  SUBEVENT,sourceGUID,sourceName,...
# GUID format: Creature-0-server-zone-instance-NPCID-spawn
# Example: Creature-0-6257-530-104772-18463-0000495DFA
#          [0]=Creature, [1]=0, [2]=server, [3]=zone, [4]=instance, [5]=npcId, [6]=spawn

def extract_npc_id_from_guid(guid: str) -> str | None:
    """
    Extract NPC ID from a creature GUID.
    GUID format: Creature-0-server-zone-instance-NPCID-spawn
    Returns: NPC ID string or None (index 5, 0-based)
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
    alert["guildId"] = CONFIG["GUILD_ID"]

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
    return {"last_inode": 0, "last_pos": 0, "reported_kills": [], "last_layer_timestamp": 0, "last_scout_timestamp": 0}


def save_state(state: dict) -> None:
    """Save the bridge state to file."""
    with open(STATE_FILE, "w") as f:
        json.dump(state, f, indent=2)


# =============================================================================
# SAVEDVARIABLES PARSING
# =============================================================================

def find_savedvariables_file() -> str | None:
    """
    Auto-discover BoneyWorldBosses.lua in WTF folder.
    Returns the most recently modified file if multiple accounts exist.
    """
    logs_dir = CONFIG["LOGS_DIR"]
    if not logs_dir:
        return None

    # WTF folder is sibling to Logs folder: WoW/_anniversary_/WTF/Account/*/SavedVariables/
    wow_dir = Path(logs_dir).parent
    wtf_path = wow_dir / "WTF" / "Account"

    if not wtf_path.exists():
        return None

    # Search for BoneyWorldBosses.lua in any account folder
    pattern = str(wtf_path / "*" / "SavedVariables" / "BoneyWorldBosses.lua")
    files = glob.glob(pattern)

    if not files:
        return None

    # Return the most recently modified file
    return max(files, key=os.path.getmtime)


def read_character_name() -> str:
    """Read the top-level characterName from SavedVariables and cache it."""
    global _cached_character_name
    sv_file = find_savedvariables_file()
    if not sv_file:
        return _cached_character_name
    try:
        with open(sv_file, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
        match = re.search(r'\["characterName"\]\s*=\s*"([^"]*)"', content)
        if match:
            _cached_character_name = match.group(1)
    except IOError:
        pass
    return _cached_character_name


def parse_savedvariables(path: str, verbose: bool = False) -> dict:
    """
    Parse the BoneyWorldBosses.lua SavedVariables file.
    Returns a dict with pendingKills list.
    """
    result = {"pendingKills": []}

    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError as e:
        print(f"[KILL] Error reading SavedVariables: {e}")
        return result

    if verbose:
        print(f"[KILL] SavedVariables file size: {len(content)} bytes")

    # Find the pendingKills section by looking for it and extracting until ["config"]
    # or end of BoneyWorldBossesDB
    pending_start = content.find('["pendingKills"]')
    if pending_start == -1:
        if verbose:
            print("[KILL] Could not find pendingKills in SavedVariables")
        return result

    # Find where pendingKills data starts (after the = {)
    data_start = content.find('{', pending_start)
    if data_start == -1:
        return result

    # Find the end - look for },\n["config"] or },\n}
    # We need to find the matching closing brace
    brace_count = 0
    data_end = data_start
    for i in range(data_start, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                data_end = i
                break

    pending_content = content[data_start+1:data_end]

    if verbose:
        print(f"[KILL] pendingKills content length: {len(pending_content)} chars")

    # Find each kill entry by matching balanced braces
    i = 0
    while i < len(pending_content):
        # Find start of an entry
        entry_start = pending_content.find('{', i)
        if entry_start == -1:
            break

        # Find matching close brace
        brace_count = 0
        entry_end = entry_start
        for j in range(entry_start, len(pending_content)):
            if pending_content[j] == '{':
                brace_count += 1
            elif pending_content[j] == '}':
                brace_count -= 1
                if brace_count == 0:
                    entry_end = j
                    break

        kill_str = pending_content[entry_start+1:entry_end]
        i = entry_end + 1

        # Extract fields
        kill = {}

        # Match ["key"] = "value" or ["key"] = number or ["key"] = true/false
        field_pattern = re.compile(r'\["(\w+)"\]\s*=\s*(?:"([^"]*)"|([\d.]+)|(true|false|nil))')

        for field_match in field_pattern.finditer(kill_str):
            key = field_match.group(1)
            str_value = field_match.group(2)
            num_value = field_match.group(3)
            bool_value = field_match.group(4)

            if str_value is not None:
                kill[key] = str_value
            elif num_value is not None:
                # Keep as string for layerId, convert to int for timestamp
                if key == "timestamp":
                    kill[key] = int(float(num_value))
                else:
                    kill[key] = num_value
            elif bool_value is not None:
                if bool_value == "nil":
                    kill[key] = None
                else:
                    kill[key] = bool_value == "true"

        # Only add if we have required fields
        if "boss" in kill and "timestamp" in kill:
            result["pendingKills"].append(kill)
            if verbose:
                print(f"[KILL] Parsed kill: {kill.get('testTargetName', kill.get('boss'))} at {kill.get('time')}")
        elif kill:
            print(f"[KILL] Skipping incomplete kill record: {kill}")

    return result


# =============================================================================
# KILL REPORT HANDLING
# =============================================================================

def is_kill_already_reported(kill: dict, state: dict) -> bool:
    """Check if a kill has already been reported."""
    reported_kills = state.get("reported_kills", [])

    # Create a unique key for this kill
    kill_key = f"{kill.get('boss', '')}_{kill.get('timestamp', 0)}"

    return kill_key in reported_kills


def mark_kill_reported(kill: dict, state: dict) -> None:
    """Mark a kill as reported in state."""
    if "reported_kills" not in state:
        state["reported_kills"] = []

    kill_key = f"{kill.get('boss', '')}_{kill.get('timestamp', 0)}"
    state["reported_kills"].append(kill_key)

    # Keep only last 100 reported kills to prevent unbounded growth
    if len(state["reported_kills"]) > 100:
        state["reported_kills"] = state["reported_kills"][-100:]


def remove_kill_from_savedvariables(kill: dict) -> bool:
    """
    Remove a kill entry from pendingKills in the SavedVariables file.
    Returns True on success.
    """
    sv_file = find_savedvariables_file()
    if not sv_file:
        return False

    try:
        with open(sv_file, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError as e:
        print(f"[KILL] Error reading SavedVariables for removal: {e}")
        return False

    boss = kill.get("boss", "")
    timestamp = kill.get("timestamp", 0)

    pending_start = content.find('["pendingKills"]')
    if pending_start == -1:
        return False

    data_start = content.find('{', pending_start)
    if data_start == -1:
        return False

    # Find the end of pendingKills
    brace_count = 0
    data_end = data_start
    for i in range(data_start, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                data_end = i
                break

    pending_section = content[data_start:data_end + 1]

    # Find and remove the matching kill entry
    i = 0
    while i < len(pending_section):
        entry_start = pending_section.find('{', i)
        if entry_start == -1:
            break

        # Find matching close brace
        brace_count = 0
        entry_end = entry_start
        for j in range(entry_start, len(pending_section)):
            if pending_section[j] == '{':
                brace_count += 1
            elif pending_section[j] == '}':
                brace_count -= 1
                if brace_count == 0:
                    entry_end = j
                    break

        kill_block = pending_section[entry_start:entry_end + 1]

        boss_match = f'["boss"] = "{boss}"' in kill_block
        timestamp_match = f'["timestamp"] = {timestamp}' in kill_block

        if boss_match and timestamp_match:
            # Remove the entry and any surrounding whitespace/comma
            remove_start = entry_start
            remove_end = entry_end + 1
            # Consume trailing comma and whitespace
            while remove_end < len(pending_section) and pending_section[remove_end] in ' ,\t\n\r':
                remove_end += 1
            # Consume leading whitespace/index markers like [1] =
            while remove_start > 0 and pending_section[remove_start - 1] in ' \t':
                remove_start -= 1
            # Check for Lua array index like [1] = before the block
            prefix = pending_section[:remove_start].rstrip()
            idx_match = re.search(r'\[\d+\]\s*=\s*$', prefix)
            if idx_match:
                remove_start = len(prefix) - len(idx_match.group(0))
                # Also consume leading whitespace before index
                while remove_start > 0 and pending_section[remove_start - 1] in ' \t\n\r':
                    remove_start -= 1

            new_pending = pending_section[:remove_start] + pending_section[remove_end:]
            new_content = content[:data_start] + new_pending + content[data_end + 1:]

            try:
                with open(sv_file, "w", encoding="utf-8") as f:
                    f.write(new_content)
                print(f"[KILL] Removed kill from SavedVariables")
                return True
            except IOError as e:
                print(f"[KILL] Error writing SavedVariables: {e}")
                return False

        i = entry_end + 1

    return True  # Not found (already removed)


def post_kill_report(kill: dict) -> bool:
    """Post a kill report to the Discord bot."""
    boss_key = kill.get("boss", "unknown")
    is_test = kill.get("isTest", False)
    test_target = kill.get("testTargetName", "")

    if is_test:
        # For test kills, use the actual creature name
        boss_name = test_target if test_target else "Unknown Creature"
    else:
        boss_name = BOSS_KEY_TO_NAME.get(boss_key, boss_key)

    alert = {
        "alertType": "BOSS_KILLED",
        "boss": boss_key,
        "time": kill.get("time", "?"),
        "layer": kill.get("layer", "?"),
        "layerId": kill.get("layerId", "?"),
        "msg": f"{boss_name} was killed!",
        "characterName": kill.get("characterName", ""),
    }

    # Add test flag if this is a test kill
    if is_test:
        alert["isTest"] = True
        alert["testTargetName"] = test_target
        if kill.get("testNpcId"):
            alert["testNpcId"] = kill.get("testNpcId")

    log_prefix = "[TEST]" if is_test else "[KILL]"
    if is_test:
        npc_id = kill.get("testNpcId", "?")
        print(f"{log_prefix} Reporting: {boss_name} (NPC {npc_id}) at {kill.get('time', '?')} ST, Layer {kill.get('layer', '?')} ({kill.get('layerId', '?')})")
    else:
        print(f"{log_prefix} Reporting: {boss_name} at {kill.get('time', '?')} ST, Layer {kill.get('layer', '?')} ({kill.get('layerId', '?')})")

    return post_to_bot(alert)


_checking_kills = False  # Prevent re-entry

def check_pending_kills(state: dict, verbose: bool = False) -> None:
    """Check SavedVariables for pending kill reports and send them."""
    global _checking_kills

    # Prevent re-entry
    if _checking_kills:
        return
    _checking_kills = True

    # Refresh cached character name
    read_character_name()

    try:
        sv_file = find_savedvariables_file()

        if not sv_file:
            if verbose:
                print("[KILL] SavedVariables file not found")
            return

        if verbose:
            print(f"[KILL] Reading SavedVariables: {sv_file}")

        data = parse_savedvariables(sv_file, verbose=verbose)
        pending_kills = data.get("pendingKills", [])

        if verbose and not pending_kills:
            print("[KILL] No pending kills found in SavedVariables")

        if not pending_kills:
            return

        # Count unreported kills first
        unreported = [k for k in pending_kills if not is_kill_already_reported(k, state)]

        if not unreported:
            if verbose:
                print(f"[KILL] All {len(pending_kills)} kill(s) already reported")
            return

        # Log what we found
        print(f"[KILL] Found {len(unreported)} NEW kill(s) to report (of {len(pending_kills)} total)")
        for i, kill in enumerate(unreported, 1):
            is_test = kill.get("isTest", False)
            boss = kill.get("testTargetName", kill.get("boss", "unknown")) if is_test else kill.get("boss", "unknown")
            prefix = "[TEST] " if is_test else ""
            print(f"[KILL]   {i}. {prefix}{boss} - {kill.get('time', '?')} ST - Layer {kill.get('layer', '?')} ({kill.get('layerId', '?')})")

        for kill in unreported:
            if post_kill_report(kill):
                mark_kill_reported(kill, state)
                save_state(state)
                # Remove from SavedVariables so it won't be re-sent
                remove_kill_from_savedvariables(kill)
                print(f"[KILL] Successfully reported kill")
            else:
                print(f"[KILL] Failed to report kill, will retry later")

        print(f"[KILL] Finished processing pending kills")

    finally:
        _checking_kills = False


# =============================================================================
# LAYER SNAPSHOT HANDLING
# =============================================================================

def parse_layer_snapshot(path: str, verbose: bool = False) -> dict | None:
    """Parse layerSnapshot from SavedVariables. Returns dict or None."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError:
        return None

    # Find layerSnapshot section
    snap_start = content.find('["layerSnapshot"]')
    if snap_start == -1:
        return None

    # Find the opening brace of the snapshot table
    data_start = content.find('{', snap_start)
    if data_start == -1:
        return None

    # Find matching closing brace using brace counting
    brace_count = 0
    data_end = data_start
    for i in range(data_start, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                data_end = i
                break

    snapshot_str = content[data_start:data_end + 1]

    # Extract timestamp
    ts_match = re.search(r'\["timestamp"\]\s*=\s*(\d+)', snapshot_str)
    timestamp = int(ts_match.group(1)) if ts_match else 0

    # Extract trigger
    trigger_match = re.search(r'\["trigger"\]\s*=\s*"([^"]*)"', snapshot_str)
    trigger = trigger_match.group(1) if trigger_match else "unknown"

    # Extract characterName
    char_match = re.search(r'\["characterName"\]\s*=\s*"([^"]*)"', snapshot_str)
    character_name = char_match.group(1) if char_match else ""

    # Extract zones table
    zones_start = snapshot_str.find('["zones"]')
    if zones_start == -1:
        if verbose:
            print("[LAYER] No zones table in snapshot")
        return None

    # Find the zones table opening brace
    zones_brace = snapshot_str.find('{', zones_start)
    if zones_brace == -1:
        return None

    # Find matching closing brace for zones
    brace_count = 0
    zones_end = zones_brace
    for i in range(zones_brace, len(snapshot_str)):
        if snapshot_str[i] == '{':
            brace_count += 1
        elif snapshot_str[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                zones_end = i
                break

    zones_str = snapshot_str[zones_brace:zones_end + 1]

    # Parse each zone: ["mapId"] = { ["layerNum"] = "instanceId", ... }
    zones = {}
    zone_pattern = re.compile(r'\["(\d+)"\]\s*=\s*\{([^}]*)\}')
    for zone_match in zone_pattern.finditer(zones_str):
        map_id = zone_match.group(1)
        zone_content = zone_match.group(2)
        layers = {}
        for layer_match in re.finditer(r'\["(\d+)"\]\s*=\s*"(\d+)"', zone_content):
            layers[layer_match.group(1)] = layer_match.group(2)
        zones[map_id] = layers

    if verbose:
        print(f"[LAYER] Parsed snapshot: trigger={trigger}, timestamp={timestamp}, {len(zones)} zone(s)")

    return {
        "timestamp": timestamp,
        "trigger": trigger,
        "zones": zones,
        "characterName": character_name,
    }


_checking_layers = False


def check_layer_snapshot(state: dict, verbose: bool = False) -> None:
    """Check SavedVariables for new layer snapshot and send LAYER_UPDATE webhooks."""
    global _checking_layers
    if _checking_layers:
        return
    _checking_layers = True

    try:
        sv_file = find_savedvariables_file()
        if not sv_file:
            return

        snapshot = parse_layer_snapshot(sv_file, verbose=verbose)
        if not snapshot:
            if verbose:
                print("[LAYER] No layer snapshot found in SavedVariables")
            return

        last_ts = state.get("last_layer_timestamp", 0)
        if snapshot["timestamp"] <= last_ts:
            if verbose:
                print(f"[LAYER] Snapshot timestamp {snapshot['timestamp']} already sent (last: {last_ts})")
            return

        # Skip stale snapshots (e.g. bridge started before player logged in)
        age = time.time() - snapshot["timestamp"]
        if age > LAYER_STALENESS_WINDOW:
            print(f"[LAYER] Skipping stale snapshot ({int(age)}s old, threshold {LAYER_STALENESS_WINDOW}s)")
            return

        trigger = snapshot["trigger"]
        zones = snapshot["zones"]

        total_layers = sum(len(layers) for layers in zones.values())
        print(f"[LAYER] New layer snapshot detected (trigger: {trigger}, {len(zones)} zone(s), {total_layers} mapping(s))")

        for map_id, layers in sorted(zones.items()):
            layer_list = ", ".join(f"L{num}={inst}" for num, inst in sorted(layers.items()))
            print(f"[LAYER]   Zone {map_id}: {layer_list}")

        alert = {
            "alertType": "LAYER_UPDATE",
            "trigger": trigger,
            "zones": zones,
            "characterName": snapshot.get("characterName", ""),
        }

        print(f"[LAYER] Sending payload: {json.dumps(alert, indent=2)}")

        if post_to_bot(alert):
            state["last_layer_timestamp"] = snapshot["timestamp"]
            save_state(state)
            print(f"[LAYER] Successfully reported layer update (trigger: {trigger}, {len(zones)} zone(s), {total_layers} mapping(s))")
        else:
            print(f"[LAYER] Failed to send layer snapshot, will retry")

    finally:
        _checking_layers = False


# =============================================================================
# SCOUT REPORT HANDLING
# =============================================================================

def parse_scout_report(path: str, verbose: bool = False) -> dict | None:
    """Parse scoutReport from SavedVariables. Returns dict or None."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError:
        return None

    report_start = content.find('["scoutReport"]')
    if report_start == -1:
        return None

    # Check for nil value (cleared report)
    nil_check = content[report_start:report_start + 50]
    if re.search(r'\["scoutReport"\]\s*=\s*nil', nil_check):
        return None

    data_start = content.find('{', report_start)
    if data_start == -1:
        return None

    # Find matching closing brace
    brace_count = 0
    data_end = data_start
    for i in range(data_start, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                data_end = i
                break

    report_str = content[data_start:data_end + 1]

    # Extract fields using same regex as other parsers
    field_pattern = re.compile(r'\["(\w+)"\]\s*=\s*(?:"([^"]*)"|([\d.]+)|(true|false|nil))')
    report = {}
    for match in field_pattern.finditer(report_str):
        key = match.group(1)
        str_val = match.group(2)
        num_val = match.group(3)
        bool_val = match.group(4)
        if str_val is not None:
            report[key] = str_val
        elif num_val is not None:
            if key == "timestamp":
                report[key] = int(float(num_val))
            else:
                report[key] = num_val
        elif bool_val is not None:
            report[key] = bool_val == "true" if bool_val != "nil" else None

    if "action" not in report or "timestamp" not in report:
        if verbose:
            print("[SCOUT] Incomplete scout report, missing required fields")
        return None

    if verbose:
        print(f"[SCOUT] Parsed report: action={report.get('action')}, boss={report.get('boss', 'N/A')}, layer={report.get('layer', '?')}")

    return report


def clear_scout_report_from_savedvariables() -> bool:
    """Clear scoutReport from SavedVariables after successful POST."""
    sv_file = find_savedvariables_file()
    if not sv_file:
        return False

    try:
        with open(sv_file, "r", encoding="utf-8", errors="replace") as f:
            content = f.read()
    except IOError:
        return False

    report_start = content.find('["scoutReport"]')
    if report_start == -1:
        return True

    # Check if already nil
    nil_check = content[report_start:report_start + 50]
    if re.search(r'\["scoutReport"\]\s*=\s*nil', nil_check):
        return True

    data_start = content.find('{', report_start)
    if data_start == -1:
        return True

    # Find matching closing brace
    brace_count = 0
    data_end = data_start
    for i in range(data_start, len(content)):
        if content[i] == '{':
            brace_count += 1
        elif content[i] == '}':
            brace_count -= 1
            if brace_count == 0:
                data_end = i
                break

    # Replace the table with nil, consuming trailing comma if present
    after = content[data_end + 1:]
    after = after.lstrip(' \t')
    if after.startswith(','):
        after = after[1:]

    new_content = content[:report_start] + '["scoutReport"] = nil' + after

    try:
        with open(sv_file, "w", encoding="utf-8") as f:
            f.write(new_content)
        return True
    except IOError:
        return False


_checking_scout = False


def check_scout_report(state: dict, verbose: bool = False) -> None:
    """Check SavedVariables for new scout report and send SCOUT_REPORT webhook."""
    global _checking_scout
    if _checking_scout:
        return
    _checking_scout = True

    try:
        sv_file = find_savedvariables_file()
        if not sv_file:
            return

        report = parse_scout_report(sv_file, verbose=verbose)
        if not report:
            if verbose:
                print("[SCOUT] No scout report found in SavedVariables")
            return

        last_ts = state.get("last_scout_timestamp", 0)
        if report["timestamp"] <= last_ts:
            if verbose:
                print(f"[SCOUT] Report timestamp {report['timestamp']} already sent (last: {last_ts})")
            return

        action = report.get("action", "unknown")
        boss = report.get("boss", "")
        layer = report.get("layer", "?")
        layer_id = report.get("layerId", "?")
        character_name = report.get("characterName", "")

        if action == "on":
            boss_name = BOSS_KEY_TO_NAME.get(boss, boss)
            print(f"[SCOUT] New scout report: {character_name} scouting {boss_name} on Layer {layer} ({layer_id})")
        else:
            print(f"[SCOUT] Scout off report from {character_name}")

        alert = {
            "alertType": "SCOUT_REPORT",
            "action": action,
            "characterName": character_name,
        }

        if action == "on":
            alert["boss"] = boss
            alert["layer"] = layer
            alert["layerId"] = layer_id

        if post_to_bot(alert):
            state["last_scout_timestamp"] = report["timestamp"]
            save_state(state)
            clear_scout_report_from_savedvariables()
            print(f"[SCOUT] Successfully reported scout {action}")
        else:
            print(f"[SCOUT] Failed to send scout report, will retry")

    finally:
        _checking_scout = False


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


def tail_log_file(state: dict):
    """
    Generator that yields new lines from the combat log file.
    Automatically finds and switches to the latest combat log file.
    Handles file rotation (WoW creates new files with /combatlog).
    Also periodically checks for pending kill reports.
    """
    current_log_path = None
    last_inode = state.get("last_inode", 0)
    last_pos = state.get("last_pos", 0)
    last_log_file = state.get("last_log_file", "")

    file_handle = None
    last_kill_check = time.time()  # Don't check immediately, main_loop already did

    while True:
        try:
            # Periodically check for pending kill reports
            now = time.time()
            if now - last_kill_check >= CONFIG["KILL_REPORT_CHECK_INTERVAL"]:
                check_pending_kills(state, verbose=False)
                check_layer_snapshot(state, verbose=False)
                check_scout_report(state, verbose=False)
                last_kill_check = now

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
        "characterName": _cached_character_name,
    }
    post_to_bot(alert)


def main_loop() -> None:
    """Main processing loop."""
    print(f"[BoneyWorldBosses] Starting bridge v3.1 (combat log + kill reports)...")
    print(f"  Bot API: {CONFIG['BOT_API_URL']}")
    print(f"  Logs dir: {CONFIG['LOGS_DIR']}")
    print(f"  Poll interval: {CONFIG['POLL_INTERVAL']}s")
    print(f"  Dedup window: {CONFIG['DEDUP_WINDOW']}s")
    print(f"  Kill report check: every {CONFIG['KILL_REPORT_CHECK_INTERVAL']}s")
    print(f"  Watching for NPC IDs: {', '.join(BOSS_NPC_IDS.keys())}")
    print(f"  Boss names: {', '.join(BOSS_NPC_IDS.values())}")
    print()

    # Show current combat log file
    latest = find_latest_combat_log()
    if latest:
        print(f"[TAIL] Found combat log: {os.path.basename(latest)}")
    else:
        print(f"[TAIL] No combat log found yet. Run /combatlog in WoW to start one.")

    # Check for SavedVariables file
    sv_file = find_savedvariables_file()
    if sv_file:
        print(f"[KILL] Found SavedVariables: {os.path.basename(sv_file)}")
    else:
        print(f"[KILL] SavedVariables not found yet (will check after WoW login)")

    # Read cached character name from SavedVariables
    char_name = read_character_name()
    if char_name:
        print(f"[CONFIG] Character: {char_name}")
    print()

    # Load state
    state = load_state()

    # Do initial kill report check (verbose)
    print("[KILL] Checking for pending kill reports...")
    check_pending_kills(state, verbose=True)

    # Do initial layer snapshot check (verbose)
    print("[LAYER] Checking for layer snapshot...")
    check_layer_snapshot(state, verbose=True)

    # Do initial scout report check (verbose)
    print("[SCOUT] Checking for scout report...")
    check_scout_report(state, verbose=True)

    try:
        for line in tail_log_file(state):
            process_line(line)
    except KeyboardInterrupt:
        print("\n[SHUTDOWN] Received interrupt, exiting...")


def validate_config() -> bool:
    """Validate configuration before starting."""
    # Auto-detect LOGS_DIR if not manually set
    if not CONFIG["LOGS_DIR"]:
        detected = auto_detect_logs_dir()
        if detected:
            CONFIG["LOGS_DIR"] = detected
            print(f"[CONFIG] Auto-detected Logs directory: {detected}")

    errors = []

    if not CONFIG["BOT_API_URL"]:
        errors.append("BOT_API_URL is not set")

    if not CONFIG["GUILD_ID"]:
        errors.append("GUILD_ID is not set (set it to your Discord server ID in bridge.py)")

    if not CONFIG["LOGS_DIR"]:
        errors.append("LOGS_DIR is not set (could not auto-detect from script location)")
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
    print("  Boney World Bosses - Bridge v3.1")
    print("  Scout: Combat log detection (real-time)")
    print("  Reporter: Kill reports (after /reload)")
    print("  Watches for Kazzak/Doomwalker")
    print("=" * 60)
    print()

    if not validate_config():
        sys.exit(1)

    main_loop()
