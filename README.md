# onionaddon-wow

Personal World of Warcraft addon for QA, debugging and experimental utilities. Hobby project, not affiliated with Onion Support.

## OnionDebug

A small in-game incident tracker for testing the WoW Forever / Classic Beta (1.60.1, TOC `16001`).

When you notice a bug, press **MARK BUG**. The technical context is frozen at that moment. You then add a title and notes, and the incident is saved with a persistent ID (`#0001`, `#0002`, …). You can browse the history, open any incident, and copy a ready-to-paste bug report.

OnionDebug is a companion to Blizzard's official **Issue Reporter**, not a replacement. Bugs are still sent through Blizzard. OnionDebug keeps the local history and the technical evidence, and tracks which incidents you actually reported.

### Install

1. Copy the `OnionDebug/` folder into the Beta client's `Interface/AddOns/` directory (`OnionDebug/OnionDebug.toc` must end up directly inside `AddOns/OnionDebug/`).
2. Start the game or run `/reload`. The chat shows `OnionDebug: v2.1.0 loaded - …`.

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
| `/od report <id\|last>` | Prepare the Issue Reporter text for an incident (see below) |
| `/od reported <id\|last>` | Mark an incident as reported to Blizzard |
| `/od unreported <id\|last>` | Undo a mark set by mistake (the history is kept) |
| `/od status` | Diagnostics: DB, session, event buffer, unavailable events, Lua capture, Issue Reporter |
| `/od config`, `/od set <setting> <value>` | Settings: `hudVisible`, `hudMinimized`, `captureEvents`, `printEventsToChat`, `maxEvents`, `incidentEvents`, `captureLuaErrors` |
| `/od clear-events` | Empty the event buffer |
| `/od reset` | Reset window positions and show the HUD |
| `/od version`, `/od help` | Versions and help |

Tip: create a macro containing `/od mark` and put it on an action bar or key. It works in combat.

A draft is only discarded by **CANCEL**, the **X** button or **Esc** inside a field. If the game closes windows while you type (death, a loading screen, fear, Alt+Z, ESC with no field focused), the frozen snapshot and your text are kept. The HUD button then reads **DRAFT OPEN**; click it (or run `/od mark`) to finish the incident. Drafts are not kept across `/reload`.

### Reporting to Blizzard

Each incident has a report status, shown as a text tag in HISTORY (`LOCAL` or `REPORTED`) and in the detail view (status, date, method and history).

1. Open the incident (HISTORY, then click it) and press **REPORT TO BLIZZARD**, or run `/od report <id>`.
2. OnionDebug shows the report text, already selected: press **Ctrl+C**.
3. In Blizzard's Issue Reporter, click its **bug icon** ("Bug" tooltip), paste the text into the description (**Ctrl+V**) and press **Submit**.

The report text is built for the Issue Reporter's description box:

- It is at most 255 letters, which is that box's limit, and contains no commas, because the reporter turns them into spaces.
- It starts with a unique reference such as `[OD-0001-1790000000]`.
- It then has the title, notes, build, zone and position, target, the most useful recent event, and FPS/ping as far as space allows.
- It leaves out what Blizzard already attaches (level, race, class, faction, map ID) and personal data: your character name and realm, other players' names, GUIDs and your addon list.
- **FULL EXPORT** still contains everything, locally.

How "reported" is set:

- **Detected.** OnionDebug watches Blizzard's `C_UserFeedback.SubmitBug`, the call every Issue Reporter submission goes through, with a taint-free `hooksecurefunc`. An incident is marked reported only if the submitted text contains its reference. Opening or copying the report never marks anything.
- **Manual.** Press **MARK AS REPORTED** (detail or report window) or run `/od reported <id>`. Use it when the reference was removed, when you reported another way, or when the client has no Issue Reporter. **MARK NOT REPORTED** undoes it and the history keeps both entries.

What the client allows (verified against Blizzard's UI source for 1.60.1.70009):

- There is no public API to open the Issue Reporter or pre-fill its text. OnionDebug does not call its internal functions or touch its frames, so you click its bug icon yourself.
- There is no "report accepted" event, and a post-hook cannot see `SubmitBug`'s return value. "Detected" therefore means the submission was sent with that reference, not that Blizzard's server confirmed it.
- If the Issue Reporter or `C_UserFeedback` is missing (non-Beta client or a future change), capture, history and export keep working. The report window says so and the manual mark is used instead.

### Data

Everything is stored locally in `WTF/Account/<account>/SavedVariables/OnionDebug.lua` (`OnionDebugDB`, schema 3).

Each incident is the frozen snapshot plus its title, notes and severity, plus a separate `report` table: `status`, `provider`, `reportedAt`, `method` and a bounded `history`. The report table is the only part that changes after saving. Schema 2 databases are upgraded in place, with every incident starting as `LOCAL`. IDs are unchanged, and an existing value that does not fit is kept as `legacyReport` / `report.legacyStatus`. Databases from the first version (`incidents`, `nextIncidentId`, `position`) are migrated automatically:

- Fields the addon does not recognise, including nested ones, are kept and shown under "Other fields".
- Invalid entries are moved to `OnionDebugDB.quarantine` instead of being deleted.
- Incidents with a missing, invalid or duplicate ID are renumbered in creation-time order, and the old value is kept as "Original ID".

Data written by a *newer* OnionDebug is never modified. That session runs read-only: nothing is saved and `/od status` says so.

Early Forever Beta builds (69913) had a client bug where SavedVariables were written but never loaded back. If OnionDebug reports *new database created* while you already had incidents, back up `OnionDebug.lua` and `OnionDebug.lua.bak` before logging out. `/od export all` also works as a text backup.

### Files

```
OnionDebug/OnionDebug.toc   manifest
OnionDebug/OnionDebug.lua   core: SavedVariables, snapshots, event buffer, incidents, report tracking, Issue Reporter hook, formatting, slash commands
OnionDebug/OnionDebugUI.lua UI: HUD, incident form, history, detail, export/report window, confirm dialog
tests/                      offline tests (not part of the addon)
```

### Development

The tests load the real addon files against a strict WoW API mock and walk the validation checklist. The mock includes the Issue Reporter's submit path, and scenarios where it or `C_UserFeedback` is missing:

```
lua5.1 tests/run_tests.lua
```

### Smoke test in the client

1. Copy `OnionDebug/` into `Interface/AddOns/`, log in, `/reload`. Chat: `v2.1.0 loaded`.
2. Press **MARK BUG**, type a title, **SAVE INCIDENT**. Chat: `Incident #0001 saved`.
3. **HISTORY**: `#0001` is on top with the `LOCAL` tag. Search still filters.
4. Click the row. The detail view shows the ref, `Report status: Local only`, **REPORT TO BLIZZARD** and **MARK AS REPORTED**.
5. **REPORT TO BLIZZARD**: the text starts with `[OD-0001-…]` and the letter count is at most 255. **Ctrl+C**.
6. With the Issue Reporter: click its bug icon, **Ctrl+V**, **Submit**. Chat: `Incident #0001 marked as reported: the Issue Reporter submission contained OD-0001-…`. HISTORY shows `REPORTED`.
7. Without the Issue Reporter (or after editing the reference out): the report window says so. Press **MARK AS REPORTED**.
8. `/reload`. `#0001` is still `REPORTED` with the same "Reported at".
9. **FULL EXPORT** shows the report status, date, method and history.
10. **MARK NOT REPORTED**: back to `LOCAL`, and the history keeps both entries. `/od status` reports the Issue Reporter and the unreported count.
11. Regression checks:
    - a draft survives a loading screen and is reopened with DRAFT OPEN
    - delete asks for confirmation
    - `/od reset`
    - an old schema-2 `OnionDebug.lua` loads with every incident `LOCAL`
