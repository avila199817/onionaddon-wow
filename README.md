# onionaddon-wow

Personal World of Warcraft addon for QA, debugging and experimental utilities. Hobby project, not affiliated with Onion Support.

## OnionDebug

A small in-game incident tracker for testing the WoW Forever / Classic Beta (1.60.1, TOC `16001`).

When you notice a bug, press **MARK BUG**. The technical context is frozen at that moment. You then add a title and notes, and the incident is saved with a persistent ID (`#0001`, `#0002`, …). You can browse the history, open any incident, and copy a ready-to-paste bug report.

### Install

1. Copy the `OnionDebug/` folder into the Beta client's `Interface/AddOns/` directory (`OnionDebug/OnionDebug.toc` must end up directly inside `AddOns/OnionDebug/`).
2. Start the game or run `/reload`. The chat shows `OnionDebug: v2.0.0 loaded - …`.

If the addon is listed as *out of date* after a Beta patch, check the client's interface number with `/dump select(4, GetBuildInfo())` and update `## Interface:` in `OnionDebug.toc`.

### What it captures

When you press MARK BUG, and not when you press Save, OnionDebug copies the following into an immutable snapshot:

| Block | Contents |
| --- | --- |
| Client | version, build, build date, TOC, locale |
| Character | name-realm, level, race, class (plus class token), faction |
| Location | zone, subzone, map ID and name, map position, instance, world coordinates |
| Player | combat, combat lockdown, mounted, dead/ghost, swimming, resting |
| Target | name, level, classification, kind, reaction, creature type, raw GUID, NPC ID or object ID |
| Performance | FPS, FPS min/avg over the last 30 s, home and world latency, Lua memory |
| Session | session ID, uptime, server time, addon version, loaded addons, count of secret (restricted) values |
| Events | last event plus the last 40 tracked events, each with its time and offset from the mark |

The following events feed a ring buffer capped at `maxEvents` (default 200). Identical consecutive events within 2 s are merged into one entry with an `(xN)` counter:

- login, entering and leaving the world
- zone changes
- target changes
- combat enter and leave, level up, death and resurrection
- bag and quest updates
- the player's spell casts
- system messages, UI errors, blocked and forbidden addon actions, Lua warnings
- optionally, Lua errors

High-frequency events such as `UNIT_AURA` and the combat log are never tracked.

### Commands (`/od`, `/onion`)

| Command | Action |
| --- | --- |
| `/od` / `toggle` / `show` / `hide` | HUD visibility |
| `/od mark` | Mark a bug (snapshot plus form) |
| `/od mark <title>` | Snapshot and save immediately |
| `/od history [search]` | Incident history (newest first, searchable) |
| `/od incident <id\|last>` | Incident detail |
| `/od export <id\|last\|all>` | Copyable text (Ctrl+C) |
| `/od delete <id\|last>` | Delete, with confirmation. IDs are never reused |
| `/od status` | Diagnostics: DB, session, event buffer, unavailable events, Lua capture |
| `/od config`, `/od set <setting> <value>` | Settings: `hudVisible`, `hudMinimized`, `captureEvents`, `printEventsToChat`, `maxEvents`, `incidentEvents`, `captureLuaErrors` |
| `/od clear-events` | Empty the event buffer |
| `/od reset` | Reset window positions and show the HUD |
| `/od version`, `/od help` | Versions and help |

Tip: create a macro containing `/od mark` and put it on an action bar or key. It works in combat.

### Data

Everything is stored locally in `WTF/Account/<account>/SavedVariables/OnionDebug.lua` (`OnionDebugDB`, schema 2). Databases from the first version (`incidents`, `nextIncidentId`, `position`) are migrated automatically. Fields the addon does not recognise are kept and shown under "Other fields", and invalid entries are moved to `OnionDebugDB.quarantine` instead of being deleted.

Early Forever Beta builds (69913) had a client bug where SavedVariables were written but never loaded back. If OnionDebug reports *new database created* while you already had incidents, back up `OnionDebug.lua` and `OnionDebug.lua.bak` before logging out. `/od export all` also works as a text backup.

### Files

```
OnionDebug/OnionDebug.toc   manifest
OnionDebug/OnionDebug.lua   core: SavedVariables, snapshots, event buffer, incidents, formatting, slash commands
OnionDebug/OnionDebugUI.lua UI: HUD, incident form, history, detail, export, confirm dialog
tests/                      offline tests (not part of the addon)
```

### Development

The tests load the real addon files against a strict WoW API mock and walk the validation checklist:

```
lua5.1 tests/run_tests.lua
```
