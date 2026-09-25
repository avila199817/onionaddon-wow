--[[
    Offline tests for OnionDebug. Run from the repository root:

        lua5.1 tests/run_tests.lua

    Each scenario boots the addon against tests/mock_wow.lua and walks one
    item of the manual validation checklist (fresh install, reload, legacy
    migration, Mark Bug snapshot timing, IDs, history, detail, export,
    deletion, targets, missing APIs, event spam, slash command errors...).
]]

package.path = "./tests/?.lua;" .. package.path
local Mock = require("mock_wow")
local ROOT = "OnionDebug"

local passed, failed = 0, 0
local current = "?"

local function Check(condition, message)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print(("  FAIL [%s] %s"):format(current, message))
    end
end

-- Deterministic dump used to prove saved data was not modified.
local function Serialize(value)
    if type(value) ~= "table" then
        return type(value) .. ":" .. tostring(value)
    end
    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = key
    end
    table.sort(keys, function(a, b) return Serialize(a) < Serialize(b) end)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = Serialize(key) .. "=" .. Serialize(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

local function FindHUD()
    for _, frame in ipairs(Mock.state.frames) do
        if frame.layoutKey == "hud" then
            return frame
        end
    end
end

local function Contains(haystack, needle)
    return type(haystack) == "string" and haystack:find(needle, 1, true) ~= nil
end

local function Scenario(name, fn)
    current = name
    local ok, err = xpcall(fn, debug.traceback)
    if not ok then
        failed = failed + 1
        print(("  ERROR [%s] %s"):format(name, err))
    end
end

local NPC_TARGET = { name = "Guard Thomas", level = 55, classification = "elite", reaction = 5,
    creatureType = "Humanoid", guid = "Creature-0-3134-0-11-1423-000012ABCD" }
local PLAYER_TARGET = { name = "Otherguy", realm = "Forever", level = 10, isPlayer = true, reaction = 5,
    guid = "Player-3674-0B1C2D3E" }

-- Types a title and presses SAVE INCIDENT in the open form.
local function SaveOpenForm(title, notes)
    local form = _G.OnionDebugIncidentForm
    form.titleBox:SetText(title)
    if notes then
        form.notes.edit:SetText(notes)
    end
    form.saveButton:Click()
end

------------------------------------------------------------------------

Scenario("fresh install", function()
    local ns = Mock.Boot(ROOT)
    local db = _G.OnionDebugDB
    Check(type(db) == "table" and db.schemaVersion == 2, "database created with schema 2")
    Check(db.nextIncidentId == 1 and #db.incidents == 0, "empty incident store starting at #0001")
    Check(db.settings.hudVisible == true and db.settings.printEventsToChat == false
        and db.settings.captureEvents == true and db.settings.maxEvents == 200, "default settings")
    Check(Contains(Mock.ChatSince(0), "new database created"), "fresh database announced")
    Check(ns.session and ns.session.id, "session started")
    local size = ns.GetEventStats()
    Check(size >= 2, "PLAYER_LOGIN / PLAYER_ENTERING_WORLD recorded")
end)

Scenario("mark bug freezes the snapshot; save keeps it", function()
    local ns = Mock.Boot(ROOT)
    Mock.state.target = NPC_TARGET
    Mock.FireEvent("PLAYER_TARGET_CHANGED")
    local markTime = Mock.state.now
    ns.UI.BeginIncident()
    Check(ns.draft ~= nil, "draft created")
    local form = _G.OnionDebugIncidentForm
    Check(form:IsShown(), "form shown")
    Check(Contains(form.contextText:GetText(), "Stormwind City"), "context summary shows zone")
    Check(not form.saveButton:IsEnabled(), "save disabled without title")

    -- 40 seconds of typing while the world changes
    Mock.Advance(40)
    Mock.state.zone, Mock.state.subZone, Mock.state.target = "Elwynn Forest", "Goldshire", nil
    Mock.FireEvent("ZONE_CHANGED_NEW_AREA")

    SaveOpenForm("Minimap disappears", "Line one\nLine two")
    local incident = ns.FindIncident(1)
    Check(incident ~= nil, "incident #0001 saved")
    Check(incident.createdAt == markTime, "createdAt is the mark time, not the save time")
    Check(incident.location.zone == "Stormwind City", "location frozen at mark time")
    Check(incident.target.npcId == 1423 and incident.target.guid == NPC_TARGET.guid, "target frozen with NPC ID and raw GUID")
    Check(incident.notes == "Line one\nLine two", "notes kept")
    Check(incident.severity == "Medium", "default severity")
    Check(ns.draft == nil and not form:IsShown(), "draft cleared and form closed")
    Check(_G.OnionDebugDB.nextIncidentId == 2, "next ID advanced")
    Check(incident.lastEvent and incident.lastEvent.event == "PLAYER_TARGET_CHANGED", "last event captured")
end)

Scenario("cancel does not create an incident or consume an ID", function()
    local ns = Mock.Boot(ROOT)
    ns.UI.BeginIncident()
    local form = _G.OnionDebugIncidentForm
    form.titleBox:SetText("Will be cancelled")
    Mock.RunScript(form.titleBox, "OnEscapePressed") -- Esc in the title box
    Check(not form:IsShown(), "form closed on Esc")
    Check(ns.draft == nil, "draft discarded")
    Check(#_G.OnionDebugDB.incidents == 0 and _G.OnionDebugDB.nextIncidentId == 1, "no incident, ID not consumed")

    ns.UI.BeginIncident()
    form.closeButton:Click() -- X button
    Check(ns.draft == nil and not form:IsShown(), "X button cancels and discards")

    ns.UI.BeginIncident()
    Mock.RunScript(form.notes.edit, "OnEscapePressed") -- Esc in the notes box
    Check(ns.draft == nil and not form:IsShown(), "Esc in notes cancels")

    ns.UI.BeginIncident()
    local first = ns.draft
    local before = #Mock.state.chat
    ns.UI.BeginIncident()
    Check(ns.draft == first, "second Mark Bug keeps the pending draft")
    Check(Contains(Mock.ChatSince(before), "already open"), "user told a draft is pending")
    Check(form.titleBox:GetText() == "", "form not reset while the same draft is open")
    SaveOpenForm("   ")
    Check(ns.draft == first and form:IsShown(), "blank title does not save")
    SaveOpenForm("Real title")
    Check(ns.FindIncident(1) ~= nil, "then saves as #0001")
end)

Scenario("IDs persist across reload and are never reused", function()
    local ns = Mock.Boot(ROOT)
    ns.QuickMark("first")
    ns.QuickMark("second")
    ns.QuickMark("third")
    ns = Mock.Reload(ROOT)
    Check(#_G.OnionDebugDB.incidents == 3 and _G.OnionDebugDB.nextIncidentId == 4, "reload keeps incidents and next ID")
    Check(Contains(Mock.ChatSince(0), "3 incidents stored"), "load line reports the count")

    ns.UI.ConfirmDelete(3)
    Check(_G.OnionDebugConfirm:IsShown(), "delete asks for confirmation")
    _G.OnionDebugConfirm.acceptButton:Click()
    Check(ns.FindIncident(3) == nil, "#0003 deleted")
    local incident = ns.QuickMark("fourth")
    Check(incident.id == 4, "deleted ID is not reused")

    ns.UI.ConfirmDelete(1)
    _G.OnionDebugConfirm:Hide() -- cancel
    Check(ns.FindIncident(1) ~= nil, "cancelled delete keeps the incident")

    ns = Mock.Reload(ROOT)
    Check(_G.OnionDebugDB.nextIncidentId == 5, "next ID survives another reload")
    Check(ns.session.id == ns.session.id and _G.OnionDebugDB.session ~= nil, "session persisted")
end)

Scenario("session survives reload, restarts on login", function()
    local ns = Mock.Boot(ROOT)
    local sessionId = ns.session.id
    ns.QuickMark("in session")
    Mock.Advance(10)
    ns = Mock.Reload(ROOT)
    Check(ns.session.id == sessionId, "reload keeps the session")
    Check(ns.CountSessionIncidents() == 1, "session incident count")
    Mock.Advance(3600)
    ns = Mock.Reload(ROOT, { reload = false })
    Check(ns.session.id ~= sessionId, "fresh login starts a new session")
    Check(ns.CountSessionIncidents() == 0, "new session has no incidents yet")
end)

Scenario("legacy schema 1 database migrates without data loss", function()
    local legacy = {
        nextIncidentId = 7,
        position = { point = "CENTER", relativePoint = "CENTER", x = 10, y = 20 },
        incidents = {
            { id = 1, title = "Old bug", zone = "Elwynn", time = 1780000000, extra = { a = 1, b = { c = "deep" } } },
            { id = 3, title = "Other" },
            { title = "No id" },
            { id = 3, title = "Duplicate id" },
            [5] = "garbage",
        },
    }
    local ns = Mock.Boot(ROOT, { db = legacy })
    local db = _G.OnionDebugDB
    Check(db.schemaVersion == 2, "schema bumped to 2")
    Check(db.position == nil and db.ui.hud and db.ui.hud.x == 10, "position moved to ui.hud")
    Check(#db.incidents == 4, "all four table incidents kept")
    local ids = {}
    for i, incident in ipairs(db.incidents) do
        ids[i] = incident.id
    end
    Check(table.concat(ids, ",") == "1,3,7,8", "ids unique and sorted, new ids start at old nextIncidentId (" .. table.concat(ids, ",") .. ")")
    Check(db.nextIncidentId == 9, "nextIncidentId after reassigned ids")
    Check(type(db.quarantine) == "table" and db.quarantine[1].value == "garbage", "non-table entry quarantined, not deleted")
    local old = ns.FindIncident(1)
    Check(old.createdAt == 1780000000 and old.createdAtText ~= nil, "legacy time field used for createdAt")
    Check(old.metadata.migratedFromSchema == 1, "migration marked")
    local text = ns.FormatIncidentText(old)
    Check(Contains(text, "Other fields:") and Contains(text, "zone: Elwynn") and Contains(text, "extra.b.c: deep"),
        "unknown legacy fields exported")
    local renumbered = 0
    for _, incident in ipairs(db.incidents) do
        if incident.metadata.originalId == 3 and incident.id ~= 3
            and (incident.title == "Other" or incident.title == "Duplicate id") then
            renumbered = renumbered + 1
        end
    end
    Check(renumbered == 1, "exactly one duplicate renumbered, original id kept in metadata")
    Check(Contains(Mock.ChatSince(0), "migrated from schema 1"), "migration announced")
    ns.UI.ShowHistory()
    ns.UI.ShowDetail(1)
    Check(_G.OnionDebugDetail:IsShown(), "legacy incident renders in detail")
end)

Scenario("database from a newer schema is left untouched", function()
    local future = {
        schemaVersion = 99, nextIncidentId = 5, futureField = true, settings = { maxEvents = 5000, hudVisible = "auto" },
        incidents = { ["S1-0010"] = { title = "" }, "packed|string" }, session = { id = 7 },
    }
    local before = Serialize(future)
    local ns = Mock.Boot(ROOT, { db = future })
    Check(Contains(Mock.ChatSince(0), "newer OnionDebug") and Contains(Mock.ChatSince(0), "update the addon"), "warning shown")
    local incident, err = ns.QuickMark("should not persist")
    Check(incident == nil and Contains(err, "nothing is saved"), "saving refused with a clear reason")
    Mock.Slash("set maxEvents 300")
    Mock.Slash("hide")
    Mock.Tick(0.3, 2)
    Check(Serialize(_G.OnionDebugDB) == before, "saved data byte-for-byte unchanged")
    local chat = #Mock.state.chat
    Mock.Slash("status")
    Check(Contains(Mock.ChatSince(chat), "read-only session"), "status reports read-only mode")
end)

Scenario("draft survives windows closed by the game", function()
    local ns = Mock.Boot(ROOT)
    Mock.state.target = NPC_TARGET
    ns.UI.BeginIncident()
    local draft = ns.draft
    local form = _G.OnionDebugIncidentForm
    form.titleBox:SetText("Died while typing")
    form.notes.edit:SetText("half written")
    form.severityButton:Click()
    Check(FindHUD().markButton:GetText():find("DRAFT OPEN", 1, true) ~= nil, "HUD shows the pending draft")

    -- Blizzard's CloseSpecialWindows: death, loading screen, fear, ESC with no focus
    local chat = #Mock.state.chat
    for _, name in ipairs(_G.UISpecialFrames) do
        local frame = _G[name]
        if frame and frame:IsShown() then
            frame:Hide()
        end
    end
    Check(not form:IsShown() and ns.draft == draft, "draft kept when the game closes windows")
    Check(Contains(Mock.ChatSince(chat), "draft kept"), "user told how to resume")
    Check(Mock.state.focus == nil, "keyboard released")

    Mock.state.target, Mock.state.zone = nil, "Elwynn Forest"
    Mock.Advance(30)
    ns.UI.BeginIncident() -- DRAFT OPEN
    Check(form:IsShown() and ns.draft == draft, "MARK BUG reopens the same draft")
    Check(form.titleBox:GetText() == "Died while typing" and form.notes.edit:GetText() == "half written",
        "typed text kept")
    form.saveButton:Click()
    local incident = ns.FindIncident(1)
    Check(incident and incident.target.npcId == 1423 and incident.location.zone == "Stormwind City",
        "saved with the original snapshot")
    Check(incident.severity == "High", "severity choice kept")
    Check(ns.draft == nil and FindHUD().markButton:GetText():find("MARK BUG", 1, true) ~= nil, "draft cleared after save")
end)

Scenario("letter limits match the EditBox (UTF-8, escaped pipes)", function()
    local ns = Mock.Boot(ROOT)
    local title = string.rep("\195\177", 120) -- 120 x "n with tilde", 240 bytes
    local notes = string.rep("\195\169", 4000)
    local incident = ns.SaveIncident(ns.CaptureSnapshot(), title, notes)
    Check(incident.title == title, "120 accented letters kept whole")
    Check(incident.notes == notes, "4000 accented letters kept whole")
    local piped = ns.SaveIncident(ns.CaptureSnapshot(), string.rep("||", 120))
    Check(piped.title == string.rep("||", 120), "escaped pipes count as one letter")
    local long = ns.QuickMark(string.rep("\208\182", 130)) -- Cyrillic
    Check(long.title == string.rep("\208\182", 117) .. "...", "over-long slash title cut on a letter boundary")
end)

Scenario("legacy nested fields are shown and never break formatting", function()
    local legacy = {
        nextIncidentId = 2,
        incidents = {
            {
                id = 1, title = "Nested", createdAtText = 12,
                target = { exists = true, name = "Guard", npcID = 1423, level = "55" },
                location = { zone = "Elwynn", coords = "32.1, 45.6", mapID = { uiMapID = 1429 } },
                performance = { fps = 60, latency = "27/31" },
                client = { version = 1.12, build = 5875 },
                metadata = { addOns = { "A", 5, true } },
                recentEvents = { "09:41 ZONE_CHANGED", { event = "X", info = { 1 } } },
            },
        },
    }
    local ns = Mock.Boot(ROOT, { db = legacy })
    local incident = ns.FindIncident(1)
    local ok, text = pcall(ns.FormatIncidentText, incident)
    Check(ok, "export does not crash: " .. tostring(not ok and text or ""))
    text = ok and text or ""
    Check(Contains(text, "target.npcID: 1423") and Contains(text, "target.level: 55"), "unknown/mistyped target fields exported")
    Check(Contains(text, "location.coords: 32.1, 45.6") and Contains(text, "location.mapID.uiMapID: 1429"), "nested location fields exported")
    Check(Contains(text, "performance.latency: 27/31") and Contains(text, "createdAtText: 12"), "other mistyped fields exported")
    Check(Contains(text, "Name: Guard") and Contains(text, "Zone: Elwynn") and Contains(text, "Version: 1.12"), "valid fields still rendered")
    Check(Contains(text, "09:41 ZONE_CHANGED") and Contains(text, "2 loaded: A, 5")
        and Contains(text, "metadata.addOns[3]: Yes"), "legacy events and addon list rendered")
    Check(Contains(text, "recentEvents[2].info.1: 1"), "mistyped event info exported")
    Check(pcall(ns.FormatIncidentsText, { incident }), "export all works")
    Check(pcall(ns.FormatIncidentMeta, incident, true) and pcall(ns.IncidentMatches, incident, "x"), "history row and search work")
    ns.UI.ShowHistory()
    ns.UI.ShowDetail(1)
    Check(_G.OnionDebugDetail:IsShown(), "detail renders")
end)

Scenario("every stored field reaches the export (completeness)", function()
    local ns = Mock.Boot(ROOT)
    -- Each field gets a unique sentinel; each must appear somewhere in the text.
    local incident = {
        id = 7, title = "T_title", notes = "T_notes", severity = "High", createdAt = 1780000000, createdAtText = "T_created",
        client = { version = "C_version", build = "C_build", buildDate = "C_date", tocVersion = 910001, locale = "C_locale" },
        character = { realm = "CH_realm", class = "CH_class", classToken = "CH_token", race = "CH_race", level = 910002,
            faction = "CH_faction" }, -- no name: realm must still show
        location = { zone = "L_zone", subZone = "L_sub", mapName = "L_mapName", x = 910003, y = 910004,
            instanceType = "L_type", difficulty = "L_diff", instanceMapID = 910005, worldX = 910006 }, -- no mapID, no instanceName, no worldY
        performance = { fps = 910007, fpsAvg = 910008, fpsWindow = 910009, homeLatency = 910010,
            worldLatency = 910011, luaMemoryKB = 1024 * 910012 }, -- no fpsMin
        player = { combat = true },
        target = { level = 910013, classification = "TG_class", guidType = "TG_type", reaction = 910014,
            creatureType = "TG_ctype", guid = "TG_guid", npcId = 910015, objectId = 910016, name = "TG_name" }, -- no exists
        metadata = { addonVersion = "M_ver", schemaVersion = 910017, sessionId = "M_session", sessionUptime = 3723,
            serverTime = 1780000000, addOns = { "M_addon", extra = "M_map" }, restrictedValues = 910018,
            migratedFromSchema = 910019, originalId = "M_orig", unknown = "M_unknown" },
        lastEvent = { time = 1780000000, event = "E_last", info = "E_info", payload = "E_payload" },
        recentEvents = { { event = "E_recent", args = { "E_arg" } }, "E_string", n = "E_n" },
        topLevel = "X_top",
    }
    local text = ns.FormatIncidentText(incident)
    local expected = {
        "T_title", "T_notes", "High", "T_created", "C_version", "C_build", "C_date", "910001", "C_locale",
        "CH_realm", "CH_class", "CH_token", "CH_race", "910002", "CH_faction",
        "L_zone", "L_sub", "L_mapName", "910003", "910004", "L_type", "L_diff", "910005", "910006",
        "910007", "910008", "910009", "910010", "910011", "910012.0 MB",
        "910013", "TG_class", "TG_type", "910014", "TG_ctype", "TG_guid", "910015", "910016", "TG_name",
        "M_ver", "910017", "M_session", "01:02:03", os.date("%Y-%m-%d", 1780000000), "M_addon", "M_map", "910018",
        "910019", "M_orig", "M_unknown", "E_last", "E_info", "E_payload", "E_recent", "E_arg", "E_string", "E_n", "X_top",
    }
    local missing = {}
    for _, needle in ipairs(expected) do
        if not Contains(text, needle) then
            missing[#missing + 1] = needle
        end
    end
    Check(#missing == 0, "all stored values exported (missing: " .. table.concat(missing, ", ") .. ")")

    local instance = ns.CaptureSnapshot()
    instance.location.worldX, instance.location.worldY, instance.location.instanceMapID = nil, nil, 36
    Check(Contains(ns.FormatIncidentText(instance), "Instance ID: 36"), "instance ID shown without world coordinates")

    local zoneTable = { id = 1, title = "z", location = { zone = { name = "Elwynn" } } }
    Check(not Contains(ns.FormatIncidentMeta(zoneTable, false), "table:") and not ns.IncidentMatches(zoneTable, "table"),
        "non-scalar zone never rendered as a table address")
end)

Scenario("legacy ids renumbered chronologically, originals kept", function()
    local legacy = {
        incidents = {
            { id = 2, title = "Zone text wrong", time = 1780000000 },
            { id = 2, title = "Anchor broken", time = 1780009000 },
            { title = "Weapon glow", time = 1780001000 },
            { title = "Bag slot", time = 1780008000 },
            { id = "#0004", title = "Four", time = 1780002000 },
            { id = 0, title = "Zero", time = 1780003000 },
            { id = 2, title = "Dup meta", time = 1780004000, metadata = "v1" },
        },
    }
    local ns = Mock.Boot(ROOT, { db = legacy })
    local byTitle = {}
    for _, incident in ipairs(_G.OnionDebugDB.incidents) do
        byTitle[incident.title] = incident
    end
    Check(byTitle["Zone text wrong"].id == 2, "oldest duplicate keeps the shared id")
    local order = { "Weapon glow", "Four", "Zero", "Dup meta", "Bag slot", "Anchor broken" }
    local chronological = true
    for index = 2, #order do
        if byTitle[order[index]].id <= byTitle[order[index - 1]].id then
            chronological = false
        end
    end
    Check(chronological, "renumbered incidents follow creation time")
    Check(ns.GetLatestIncident().title == "Anchor broken", "'last' is the newest incident")
    Check(byTitle["Anchor broken"].metadata.originalId == 2, "duplicate keeps original id")
    Check(byTitle["Four"].metadata.originalId == "#0004" and byTitle["Zero"].metadata.originalId == 0, "invalid ids kept")
    Check(byTitle["Dup meta"].legacyId == 2 and byTitle["Dup meta"].metadata == "v1", "non-table metadata untouched, id kept as legacyId")
    Check(Contains(ns.FormatIncidentText(byTitle["Four"]), "Original ID: #0004"), "original id exported")
    Check(Contains(ns.FormatIncidentText(byTitle["Dup meta"]), "legacyId: 2"), "legacyId exported")
    Mock.Reload(ROOT)
    local ids = {}
    for index, incident in ipairs(_G.OnionDebugDB.incidents) do
        ids[index] = incident.id
    end
    Mock.Reload(ROOT)
    local stable = true
    for index, incident in ipairs(_G.OnionDebugDB.incidents) do
        stable = stable and ids[index] == incident.id
    end
    Check(stable, "normalization is stable across reloads")
end)

Scenario("windows stack in opening order; HUD throttle respected", function()
    local ns = Mock.Boot(ROOT)
    ns.UI.ShowExport(ns.FormatIncidentText(ns.CaptureSnapshot()), "Current context") -- HUD COPY
    Mock.Slash("history")
    ns.UI.BeginIncident()
    Check(_G.OnionDebugIncidentForm.strata == _G.OnionDebugExport.strata
        and _G.OnionDebugHistory.strata == _G.OnionDebugExport.strata, "form, history and export share a strata")
    Check(Mock.state.focus == _G.OnionDebugIncidentForm.titleBox, "focus on the visible form")
    Check(_G.OnionDebugConfirm == nil or _G.OnionDebugConfirm.strata == "FULLSCREEN_DIALOG", "confirm stays on top")

    local mapCalls, infoCalls = 0, 0
    local getBest, getInfo = C_Map.GetBestMapForUnit, C_Map.GetMapInfo
    C_Map.GetBestMapForUnit = function(...) mapCalls = mapCalls + 1 return getBest(...) end
    C_Map.GetMapInfo = function(...) infoCalls = infoCalls + 1 return getInfo(...) end
    for _ = 1, 60 do -- one second at 60 fps with an event every frame
        Mock.FireEvent("QUEST_LOG_UPDATE")
        Mock.Tick(1 / 60)
    end
    Check(mapCalls <= 5, "HUD refreshes at most every 0.25 s under event spam (" .. mapCalls .. " in 1 s)")
    Check(infoCalls == 0, "HUD tick skips map-info allocation")
    Mock.Tick(0.3) -- next throttled refresh
    local hud = FindHUD()
    local lines = hud.eventLines[1]:GetText()
    Check(Contains(lines, "QUEST_LOG_UPDATE") and Contains(lines, "(x60)"), "coalesced event rendered")
    C_Map.GetBestMapForUnit, C_Map.GetMapInfo = getBest, getInfo
end)

Scenario("non-table saved data is quarantined", function()
    Mock.Boot(ROOT, { db = "corrupt" })
    local db = _G.OnionDebugDB
    Check(type(db) == "table" and db.quarantine[1].value == "corrupt", "raw value preserved")
end)

Scenario("targets: player, NPC, none, secret", function()
    local ns = Mock.Boot(ROOT)
    Mock.state.target = PLAYER_TARGET
    local snapshot = ns.CaptureSnapshot()
    Check(snapshot.target.guidType == "Player" and snapshot.target.npcId == nil, "player target has no NPC ID")
    Check(snapshot.target.name == "Otherguy-Forever", "cross-realm name")

    Mock.state.target = nil
    snapshot = ns.CaptureSnapshot()
    Check(snapshot.target.exists == false, "no target")
    Check(Contains(ns.FormatIncidentText(snapshot), "No target"), "export says no target")

    Mock.state.target = { name = "Pet", guid = "Pet-0-3134-0-11-1860-0101A2B3C4" }
    Check(ns.CaptureSnapshot().target.npcId == 1860, "pet GUID yields creature ID")
    Mock.state.target = { name = "Box", guid = "GameObject-0-3134-0-11-2843-00001" }
    snapshot = ns.CaptureSnapshot()
    Check(snapshot.target.objectId == 2843 and snapshot.target.npcId == nil, "game object ID kept separately")
    Mock.state.target = { name = "Weird", guid = "Vignette" }
    Check(ns.CaptureSnapshot().target.npcId == nil, "short/unknown GUID does not break parsing")

    Mock.state.target = NPC_TARGET
    Mock.state.secrets = { guid = true, name = true, creatureType = true }
    snapshot = ns.CaptureSnapshot()
    Check(snapshot.target.guid == nil and snapshot.target.name == nil, "secret values dropped")
    Check(snapshot.metadata.restrictedValues == 3, "restricted values counted")
    Mock.FireEvent("PLAYER_TARGET_CHANGED")
    Check(ns.GetEvent(1).event == "PLAYER_TARGET_CHANGED", "secret target does not break event recording")
    Mock.Tick(0.5)
end)

Scenario("missing or nil APIs degrade", function()
    local ns = Mock.Boot(ROOT, { noMapApi = true, nilNetStats = true, missingEvents = { "LUA_WARNING" }, noSecretApi = true })
    local snapshot = ns.CaptureSnapshot()
    Check(snapshot.location.mapID == nil and snapshot.location.x == nil, "no map data without C_Map")
    Check(snapshot.performance.homeLatency == nil, "nil GetNetStats handled")
    local text = ns.FormatIncidentText(snapshot)
    Check(Contains(text, "Position: N/A") and Contains(text, "Home latency: N/A"), "N/A in export")
    Mock.Tick(0.5)
    local before = #Mock.state.chat
    Mock.Slash("status")
    Check(Contains(Mock.ChatSince(before), "unavailable: LUA_WARNING"), "unknown event reported, not fatal")

    ns = Mock.Boot(ROOT, { noPosition = true })
    Check(ns.CaptureSnapshot().location.x == nil, "no coordinates inside instances")
end)

Scenario("ring buffer bounded, spam coalesced", function()
    local ns = Mock.Boot(ROOT)
    for i = 1, 500 do
        Mock.FireEvent("CHAT_MSG_SYSTEM", "message " .. i)
    end
    local size, capacity, recorded = ns.GetEventStats()
    Check(size == 200 and capacity == 200, "buffer capped at 200")
    Check(recorded >= 500, "all events counted")
    Check(ns.GetEvent(1).info == "message 500" and ns.GetEvent(200).info == "message 301", "newest kept, oldest dropped")

    for _ = 1, 1000 do
        Mock.FireEvent("QUEST_LOG_UPDATE")
    end
    size = ns.GetEventStats()
    Check(ns.GetEvent(1).count == 1000 and ns.GetEvent(2).info == "message 500", "spam merged into one entry")
    Mock.Advance(5)
    Mock.FireEvent("QUEST_LOG_UPDATE")
    Check(ns.GetEvent(1).count == 1, "coalescing window expires")

    local snapshot = ns.CaptureSnapshot()
    Check(#snapshot.recentEvents == 40, "incident copies incidentEvents (40) events")
    Check(snapshot.recentEvents[2].count == 1000, "coalesced count copied")
    snapshot.recentEvents[1].info = "mutated"
    Check(ns.GetEvent(1).info ~= "mutated", "snapshot events are copies")

    Mock.Slash("set maxEvents 50")
    size, capacity = ns.GetEventStats()
    Check(size == 50 and capacity == 50 and ns.GetEvent(1).event == "QUEST_LOG_UPDATE", "resize keeps newest")
    Mock.FireEvent("PLAYER_DEAD")
    Check(ns.GetEvent(1).event == "PLAYER_DEAD" and ns.GetEvent(2).event == "QUEST_LOG_UPDATE", "buffer keeps working after resize")

    Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 133)
    Check(ns.GetEvent(1).info == "Fireball (133)", "player spell recorded with name")
    Mock.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "target", "Cast-2", 133)
    Check(ns.GetEvent(1).count == 1, "other units ignored")
    Mock.FireEvent("CHAT_MSG_SYSTEM", "|cffff0000Red|r |Hitem:1|h[Sword]|h\nnext")
    Check(ns.GetEvent(1).info == "Red [Sword] next", "chat text cleaned to plain single line")

    Mock.Slash("clear-events")
    Check(ns.GetEventStats() == 0, "clear-events empties the buffer")

    Mock.Slash("set captureEvents off")
    Mock.FireEvent("PLAYER_DEAD")
    Check(ns.GetEventStats() == 0, "capture off stops recording")
end)

Scenario("combat, zone change and HUD refresh", function()
    local ns = Mock.Boot(ROOT)
    Mock.state.combat = true
    Mock.FireEvent("PLAYER_REGEN_DISABLED")
    Mock.Tick(0.35, 3)
    ns.UI.BeginIncident() -- non-protected UI works in combat
    SaveOpenForm("Combat bug")
    local incident = ns.FindIncident(1)
    Check(incident.player.combat == true and incident.player.combatLockdown == true, "combat captured")
    Mock.state.combat = false
    Mock.FireEvent("PLAYER_REGEN_ENABLED")
    Mock.state.subZone = "Cathedral Square"
    Mock.FireEvent("ZONE_CHANGED")
    Check(ns.GetEvent(1).info == "Stormwind City / Cathedral Square", "zone change info")
    Mock.Tick(0.35, 3)

    Mock.Slash("hide")
    Check(not _G.OnionDebugDB.settings.hudVisible, "hide stores setting")
    Mock.Slash("toggle")
    Check(_G.OnionDebugDB.settings.hudVisible, "toggle shows again")
    Mock.Slash("")
    Check(not _G.OnionDebugDB.settings.hudVisible, "bare /od toggles")
    Mock.Slash("show")
    ns.SetSetting("hudMinimized", true)
    Mock.Tick(0.35, 2)
    ns.SetSetting("hudMinimized", false)
    Mock.Tick(0.35, 2)
end)

Scenario("HUD position persists; reset restores defaults", function()
    local ns = Mock.Boot(ROOT)
    local hudFrame
    for _, frame in ipairs(Mock.state.frames) do
        if frame.layoutKey == "hud" then
            hudFrame = frame
        end
    end
    Check(hudFrame ~= nil, "HUD created at login")
    hudFrame.scripts.OnDragStop(hudFrame)
    local saved = _G.OnionDebugDB.ui.hud
    Check(saved and saved.point == "TOPLEFT" and saved.x == 100 and saved.y == 700, "drag stores TOPLEFT position")
    Mock.Reload(ROOT)
    for _, frame in ipairs(Mock.state.frames) do
        if frame.layoutKey == "hud" then
            hudFrame = frame
        end
    end
    Check(hudFrame.points[1][1] == "TOPLEFT" and hudFrame.points[1][4] == 100, "position restored after reload")
    Mock.Slash("reset")
    Check(next(_G.OnionDebugDB.ui) == nil and hudFrame.points[1][1] == "TOPRIGHT", "reset returns to default anchor")
end)

Scenario("history, search, detail and export", function()
    local ns = Mock.Boot(ROOT)
    Mock.state.target = NPC_TARGET
    ns.QuickMark("Nameplate overlap")
    Mock.Advance(60)
    ns.QuickMark("Minimap disappears")
    Mock.Advance(60)
    ns.QuickMark("NPC wrong mining icon")

    Mock.Slash("history")
    local history = _G.OnionDebugHistory
    Check(history:IsShown(), "history open")
    Check(history.rows[1].incidentId == 3 and history.rows[3].incidentId == 1, "newest first")
    Check(not history.rows[4]:IsShown(), "unused rows hidden")
    history.searchBox:SetText("minimap")
    Check(history.rows[1].incidentId == 2 and not history.rows[2]:IsShown(), "search filters")
    Check(Contains(history.summary:GetText(), "1 of 3"), "search summary")
    history.searchBox:SetText("zzz")
    Check(history.emptyText:IsShown() and not history.exportButton:IsEnabled(), "empty search state")
    history.searchBox:SetText("")

    history.rows[2]:Click()
    local detail = _G.OnionDebugDetail
    Check(detail:IsShown() and detail.incidentId == 2, "row click opens detail")
    Check(history.rows[2].selected:IsShown(), "selected row highlighted")
    local rendered = {}
    for _, block in ipairs(detail.blocks) do
        rendered[#rendered + 1] = block.header:GetText() .. "\n" .. block.body:GetText()
    end
    rendered = table.concat(rendered, "\n")
    Check(Contains(rendered, "Minimap disappears") and Contains(rendered, "1423"), "detail shows title and NPC ID")

    Mock.Slash("export 2")
    local export = _G.OnionDebugExport
    local text = export.area.edit:GetText()
    Check(export:IsShown() and export.area.edit.highlighted, "export open and highlighted")
    Check(Contains(text, "=== Onion Debug Incident #0002 ===") and Contains(text, "=== End ==="), "export header/footer")
    Check(Contains(text, "Build: 70009") and Contains(text, "TOC: 16001") and Contains(text, "Locale: esES"), "client block")
    Check(Contains(text, "Position: 62.14 / 73.82") and Contains(text, "NPC ID: 1423"), "location and target block")
    Check(Contains(text, "Recent events"), "recent events block")
    Check(not text:find("|c", 1, true), "export has no color codes")
    export.area.edit.text = "tampered"
    Mock.RunScript(export.area.edit, "OnTextChanged", true)
    Check(export.area.edit:GetText() == text, "export text is read-only")

    Mock.Slash("export all")
    Check(Contains(export.area.edit:GetText(), "3 incident(s)"), "export all")
    history.exportButton:Click()
    Check(Contains(export.area.edit:GetText(), "#0003"), "export list from history")

    detail.scripts.OnHide = detail.scripts.OnHide -- keep reference
    ns.UI.ShowDetail(2)
    _G.OnionDebugConfirm = _G.OnionDebugConfirm
    ns.UI.ConfirmDelete(2)
    _G.OnionDebugConfirm.acceptButton:Click()
    Check(not detail:IsShown(), "detail closes when its incident is deleted")
    Check(history.rows[1].incidentId == 3 and history.rows[2].incidentId == 1, "history refreshed after delete")

    local copyBefore = #Mock.state.frames
    ns.UI.ShowExport(ns.FormatIncidentText(ns.CaptureSnapshot()), "Current context")
    Check(Contains(export.area.edit:GetText(), "Context Snapshot"), "HUD COPY exports live snapshot")
    Check(#Mock.state.frames == copyBefore, "reopening windows creates no new frames")
    export:Hide()
    Check(export.area.edit:GetText() == "" and Mock.state.focus ~= export.area.edit, "export releases text and focus")
end)

Scenario("slash command parsing and errors", function()
    local ns = Mock.Boot(ROOT)
    local function Run(text)
        local before = #Mock.state.chat
        Mock.Slash(text)
        return Mock.ChatSince(before)
    end
    Check(Contains(Run("incident 9999"), "Incident #9999 not found."), "missing incident")
    Check(Contains(Run("incident"), "Usage: /od incident"), "missing argument")
    Check(Contains(Run("export abc"), "Invalid incident ID 'abc'"), "invalid export ID")
    Check(Contains(Run("export 1.5"), "Invalid incident ID"), "fractional ID rejected")
    Check(Contains(Run("export last"), "No incidents recorded yet."), "export last without incidents")
    Check(Contains(Run("frobnicate"), "Unknown command 'frobnicate'"), "unknown command")
    Check(Contains(Run("mark   Quick title  "), "Incident #0001 saved: Quick title"), "mark <title> saves immediately")
    Check(ns.FindIncident(1).title == "Quick title", "title trimmed")
    Check(Contains(Run("MARK Second"), "#0002"), "command names are case-insensitive")
    Run("incident #0001")
    Check(_G.OnionDebugDetail:IsShown() and _G.OnionDebugDetail.incidentId == 1, "#0001 form accepted")
    Check(Contains(Run("delete 2"), "") and _G.OnionDebugConfirm:IsShown(), "delete opens confirmation")
    Check(Contains(Run("set maxEvents 5"), "between 20 and 1000"), "range validated")
    Check(Contains(Run("set printEventsToChat maybe"), "expects on or off"), "boolean validated")
    Check(Contains(Run("set nothing on"), "Unknown setting"), "unknown setting")
    Check(Contains(Run("set printeventstochat on"), "printEventsToChat = on"), "case-insensitive setting")
    Check(Contains(Run("clear-events"), "cleared"), "event echo does not break clear")
    Check(Contains(Run("help"), "/od export <id|last|all>"), "help lists commands")
    Check(Contains(Run("status"), "Incidents: 2 stored, next ID #0003"), "status")
    Check(Contains(Run("config"), "maxEvents = 200"), "config")
    Check(Contains(Run("version"), "OnionDebug 2.0.0"), "version")
    Check(Contains(Run("history minimap"), ""), "history with search")
end)

Scenario("optional Lua error capture chains the previous handler", function()
    local ns = Mock.Boot(ROOT)
    Check(ns.GetLuaCaptureState() == "off", "off by default")
    Mock.Slash("set captureLuaErrors on")
    Check(ns.GetLuaCaptureState() == "active", "installed on demand")
    local handler = _G.geterrorhandler()
    handler("Interface/AddOns/Foo/foo.lua:12: attempt to index nil")
    Check(ns.GetEvent(1).event == "LUA_ERROR", "error recorded as event")
    Check(#Mock.state.displayedErrors == 1, "previous handler still called")
    Mock.Slash("set captureLuaErrors off")
    handler("second error")
    Check(ns.GetEvent(1).info ~= "second error" and #Mock.state.displayedErrors == 2, "disabled = pass-through only")
end)

Scenario("event echo to chat is opt-in", function()
    local ns = Mock.Boot(ROOT)
    local before = #Mock.state.chat
    Mock.FireEvent("PLAYER_DEAD")
    Check(#Mock.state.chat == before, "no chat spam by default")
    Mock.Slash("set printEventsToChat on")
    before = #Mock.state.chat
    Mock.FireEvent("PLAYER_ALIVE")
    Mock.FireEvent("PLAYER_ALIVE")
    Check(#Mock.state.chat == before + 1, "one chat line per new entry (coalesced repeats are silent)")
    Check(ns.GetEvent(1).count == 2, "repeat coalesced")
end)

print(("%d checks passed, %d failed"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
