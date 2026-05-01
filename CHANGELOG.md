# Changelog

## v3.5.1 — unreleased
**Fix `GetActorList` nil error during Details! capture**

### Fixed
- **`Details/classes/class_combat.lua:893: attempt to index field '?' (a nil value)`** — `ReadTopDpsFromCombat` / `ReadTopHpsFromCombat` were calling `container:GetActorList()` on the actor container returned by `combat:GetContainer(n)`. `GetActorList` is a method on the **combat** object, not the container, and it expects an attribute index argument. Calling it on the container with no args resolved (via metatable inheritance) to `combat.GetActorList(container, nil)`, which evaluates `self[nil]._ActorTable` — `self[nil]` is `nil`, hence the index crash.
  - Switched both readers to the documented API: `combat:GetActorList(1)` for damage and `combat:GetActorList(2)` for healing. No `GetContainer` round-trip.
  - Added a guard for `combat[attr]` being nil (segment with no damage / healing data) and wrapped the call in `pcall` so any future internal Details! errors degrade to "no stats captured" instead of bubbling up an `xpcall` from Details!'s event dispatcher.

## v3.5.0 — unreleased
**Profile popup, DBM stats sync, Details! top-3, scout-off heartbeat handoff**

### Added
- **`/bwb profile` — per-character main spec declaration** ([1a7dfca](../../commit/1a7dfca)) — Single popup picker. Clicking **Tank**, **Healer**, or **DPS** writes `db.config.characterRoles[currentChar]` and reloads immediately. Run on each character that participates in boss reporting.
  - Storage: `db.config.characterRoles[name] = "tank"|"healer"|"dps"` (bare role string).
  - `BuildCharProfileSnapshot` pushes `snapshot.roles[name] = role` to the bridge as `alertType=CHAR_PROFILE`.
  - Subcommands: `/bwb profile` (open popup), `/bwb profile clear`, `/bwb profile list`.
  - Esc disabled on the spec popup so it can't silently land on **Healer** (button2 = `OnCancel` by WoW convention).
- **DBM kill-stats sync** ([cd5f8be](../../commit/cd5f8be)) — Reads Victories / Wipes / Best Victory for **Kazzak** and **Doomwalker** out of `DBM_AllSavedStats` and stages a snapshot in `db.dbmStats` for the bridge to forward as `alertType=DBM_STATS`.
  - Soft-fails silently if DBM isn't installed (`## OptionalDeps: DBM-Core`).
  - Hardcoded encounter ids fall back to a runtime mod-scan keyed on NPC id, so a DBM renumbering doesn't silently break us.
  - Pushed on `PLAYER_LOGIN` (5s after, after DBM finishes `ADDON_LOADED`), 2s after each Kazzak / Doomwalker kill (covers undefined `COMBAT_LOG` handler ordering between addons), and on manual `/bwb dbm sync`.
  - SavedVariables flush on `/reload`, so `/bwb dbm sync` nags for `/reload` like the rest of the setup-wizard UX.
  - New `/bwb dbm` subcommands: `status`, `sync`, `on`, `off`, `dump` (raw stats row print for debugging encounter id mismatches). `/bwb status` surfaces DBM detection state.
- **Details! top-3 DPS / HPS in kill reports** ([4bd645e](../../commit/4bd645e)) — Pulls top 3 DPS and top 3 effective HPS from the Details! Damage Meter combat segment that corresponds to a world boss kill, and embeds them on the kill record itself (`db.pendingKills[i].detailsStats`). The bridge forwards the new field through to the bot transparently.
  - Capture is event-driven via Details!'s `COMBAT_PLAYER_LEAVE` listener — `ENCOUNTER_END` does not fire for outdoor TBC world bosses, so a Details! listener is the right hook rather than a `C_Timer.After()` guess.
  - Once the listener fires, the most-recent un-enriched kill within a 60s window is located, the segment is validated to actually contain the boss as an enemy (with a 5-segment backward walk for trash-interference cases), and top-3 by `actor.last_dps` / `actor.last_hps` is attached.
  - Like DBM, Details! is **optional**: if it isn't loaded, the listener never registers and kill records simply omit the `detailsStats` field.
  - New slash surface: `/bwb details {status|sync|on|off|dump}`.

### Changed
- **`SCHEMA_VERSION`** bumped 1 → 2 (DBM stats shape) → 3 (Details! `detailsStats` field on `pendingKills`). Bot does not gate on it.
- **`OptionalDeps: DBM-Core, Details`** added to `.toc`.

### Fixed
- **No more spurious scout-off on plain `/reload`** ([03c4e34](../../commit/03c4e34)) — The `PLAYER_LOGOUT` handler used a non-persistent Lua local (`intentionalReload`) to skip a `layerSnapshot` + `scoutReport(off)` write when the addon's own popups initiated the reload. A bare `/reload` never enters that code path, so the flag stayed false and the handler emitted a phantom `LAYER_UPDATE` followed by `SCOUT_REPORT(off)` even though the user was still actively scouting.
  - Dropped the auto-`LAYER_UPDATE` on logout and the auto-scout-off entirely. Scout state (`db.scoutingActive` / `db.scoutingContext`) now persists indefinitely until `/bwb scout off`.
  - Detection of "player truly quit while scouting" moved to the bridge, which uses combat-log file `mtime` as a heartbeat (see Bridge v4.1.0).
  - Removed: `intentionalReload` local + all six producer assignments (kill / layer / scout-on / scout-off / callout popups + setup wizard). `PLAYER_LOGOUT` branch is now intentionally empty.

### Internal milestones (not publicly released, rolled into v3.5.0)
- `v3.5.0-int` ([cd5f8be](../../commit/cd5f8be)) — DBM kill-stats sync, original `/bwb role` setter.
- `v3.6.0-int` ([68c2bcd](../../commit/68c2bcd)) — `/bwb profile` popup chain with main + off-spec + confirm step. Replaced direct `/bwb role <spec>` setter (view/clear/list only). Migrated `characterRoles` entries to `{ main, offspec }` tables in-place at `PLAYER_LOGIN`.
- `v3.7.0-int` ([4bd645e](../../commit/4bd645e)) — Details! top-3 capture as described above.
- v3.5.0 release ultimately simplifies the profile flow back to main-spec only ([1a7dfca](../../commit/1a7dfca)) — off-spec popup chain dropped, storage flattens back to a bare role string per character, `/bwb role` consolidated into `/bwb profile {clear,list}`.

---

## v3.4.2 — 2026-04-22
**Use server time for webhook timestamps** ([20514a9](../../commit/20514a9))
- Replaced `time()` (OS local epoch, depends on the user's machine clock) with `GetServerTime()` (realm Unix epoch) in the six payload sites that write to `BoneyWorldBossesDB`: layer snapshot, kill record, scout on/off, callout, and the (now-removed) `PLAYER_LOGOUT` auto scout-off.
- The bridge enforces a freshness check against realm now, so users with skewed system clocks were having layer / scout / callout / kill updates silently rejected as stale (e.g. *"timestamp -179min off"*). `GetServerTime()` is independent of the user's machine clock and matches what the bridge expects.
- Display fields (`time`, `date`) unchanged — they already use `GetGameTime()` / `C_DateAndTime`, which are server-time.
- Follow-up ([bb70ce3](../../commit/bb70ce3)) — Bumped the runtime `VERSION` constant in `BoneyWorldBosses.lua` to match the `.toc` (it had been left at `3.4.1`, so `db.meta.addonVersion` and the bridge log misreported until `/reload`).

---

## v3.4.1 — 2026-04-22
**Fix stuck Next button in setup wizard** ([dc5582e](../../commit/dc5582e))
- On WoW Classic Era 1.15, `StaticPopup` dialogs didn't expose `button1` / `editBox` as direct fields, so `EditBoxOnTextChanged` silently failed to enable **Next** after a valid snowflake was typed.
- Added `PopupButton1` / `PopupEditBox` helpers that fall back to `_G[name .. "Button1"]` / `_G[name .. "EditBox"]`; all wizard popup-field access routed through them.
- Relabeled step 1 from *"Discord Guild ID"* → *"Discord ID"*; distinguished confirmation messages (`"Discord ID saved."` vs `"Discord User ID saved."`).

---

## v3.4.0 — 2026-04-22
**Move config in-game; decouple bridge for CurseForge** ([104d044](../../commit/104d044), [688c336](../../commit/688c336), [413923a](../../commit/413923a))
- Bridge source, launchers, and release pipeline moved out of this repo so the CurseForge addon page points at a clean Lua-only repo. Bridge now lives at [Jbeeze/BoneyWorldBoss-Bridge](https://github.com/Jbeeze/BoneyWorldBoss-Bridge); seeded from `29b752a` as bridge `v4.0.0`.
- Deleted from this repo: `bridge.py`, `run_bridge.bat`, `run_bridge.command`, `requirements.txt`, `.github/workflows/release-bridge.yml`. Trimmed `.pkgmeta` to drop ignores for files that no longer exist.
- Config moved in-game: guild id, Discord id, and bot URL come from `/bwb setup` (SavedVariables); the bridge reads them from `BoneyWorldBossesDB` rather than its own config file.
- README redirected *Install-the-bridge* / *troubleshooting* / *For-developers* sections to the new bridge repo. Addon install / slash commands / verification unchanged (comms still flow through SavedVariables).
- Follow-up README fix ([413923a](../../commit/413923a)) — corrected three placeholder bridge-repo links from `WorldBossAnnouncerBridge` → `Jbeeze/BoneyWorldBoss-Bridge`.
