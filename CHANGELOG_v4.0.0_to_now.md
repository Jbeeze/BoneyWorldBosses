# Changelog — v4.0.0 → now

## v3.6.0 — 2026-04-25
**Add `/bwb profile` for per-character main + off-spec declaration**
- New popup chain: **Main Spec** → **Has off-spec?** → **Off-Spec** → **Confirm & Reload**. Run on each character that participates in boss reporting.
- Data shape: `db.config.characterRoles[name]` is now `{ main, offspec }` (previously a bare role string). Legacy string entries are migrated in-place at `PLAYER_LOGIN`.
- `BuildCharProfileSnapshot` pushes the new `{ main, offspec }` shape to the bridge — bot side will need a matching update to consume off-spec.
- `/bwb role` now reads/clears/lists the new shape; `/bwb role <spec>` is removed in favor of `/bwb profile` (which has explicit confirmation before reload).
- Esc is disabled on the spec-picker popups so it can't silently land on `Healer` (button2 = `OnCancel` by WoW convention).
- Bumped `BoneyWorldBosses.toc` / `.lua` to **3.6.0**.

## v3.4.1 — 2026-04-22 (`dc5582e`)
**Fix stuck Next button in setup wizard**
- On WoW Classic Era 1.15, `StaticPopup` dialogs didn't expose `button1` / `editBox` as direct fields, so `EditBoxOnTextChanged` silently failed to enable **Next** after a valid snowflake was typed.
- Added `PopupButton1` / `PopupEditBox` helpers that fall back to `_G[name .. "Button1"]` / `_G[name .. "EditBox"]`; all wizard popup-field access routed through them.
- Relabeled step 1 from "Discord Guild ID" → "Discord ID"; distinguished confirmation messages (`"Discord ID saved."` vs `"Discord User ID saved."`).
- Bumped `BoneyWorldBosses.toc` / `.lua` to **3.4.1**.

## README fix — 2026-04-22 (`413923a`)
**Fix bridge repo URL in README**
- Corrected three links from the placeholder `WorldBossAnnouncerBridge` to the actual repo `Jbeeze/BoneyWorldBoss-Bridge`.

## Repo split — 2026-04-22 (`688c336`)
**Move bridge to WorldBossAnnouncerBridge repo**
- Bridge source, launchers, and release pipeline moved out so the CurseForge addon page points at a clean Lua-only repo.
- Deleted `bridge.py`, `run_bridge.bat`, `run_bridge.command`, `requirements.txt`, and `.github/workflows/release-bridge.yml`.
- Trimmed `.pkgmeta` to drop ignores for files that no longer exist.
- README: redirected *Install-the-bridge*, *troubleshooting*, and *For-developers* sections to `Jbeeze/WorldBossAnnouncerBridge`. Addon install / slash commands / verification unchanged (comms still flow through SavedVariables).

## v4.0.0 baseline — 2026-04-22 (`29b752a`)
**Finalize bridge.py before relocation** — final in-repo snapshot of `bridge.py` preserved to seed the new bridge repo.
