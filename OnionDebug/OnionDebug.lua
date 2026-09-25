--[[
    OnionDebug - core

    Owns everything that is not a widget: SavedVariables (init, migration,
    validation), context snapshots, the event ring buffer, the incident store,
    the shared text formatting used by HUD/detail/export, and slash commands.
    OnionDebugUI.lua renders this model and never keeps its own copy of it.
]]

local ADDON_NAME, ns = ...

local format, floor, min, max = string.format, math.floor, math.min, math.max
local concat, remove, sort = table.concat, table.remove, table.sort
local IsSecret = issecretvalue -- 12.x-engine clients only; nil elsewhere

------------------------------------------------------------------------
-- Constants
------------------------------------------------------------------------

local SCHEMA_VERSION = 3

local DATE_FORMAT = "%Y-%m-%d %H:%M:%S"
local CLOCK_FORMAT = "%H:%M:%S"
local SESSION_ID_FORMAT = "%Y%m%d-%H%M%S"

local EVENT_INFO_MAX_LENGTH = 160
local LUA_ERROR_MAX_LENGTH = 300
local EVENT_COALESCE_SECONDS = 2 -- identical consecutive events closer than this are merged (xN)
local PERF_SAMPLE_INTERVAL = 1
local PERF_WINDOW_SAMPLES = 30
local OTHER_FIELDS_MAX_DEPTH = 8 -- only guards against pathological nesting
local NA = "N/A"

ns.SCHEMA_VERSION = SCHEMA_VERSION
ns.TITLE_MAX_LETTERS = 120
ns.NOTES_MAX_LETTERS = 4000

ns.SEVERITIES = { "Low", "Medium", "High", "Critical" }
ns.DEFAULT_SEVERITY = "Medium"
ns.SEVERITY_COLORS = { Low = "8fbf8f", Medium = "e6c84d", High = "ff9933", Critical = "ff4d4d" }

ns.CATEGORY_COLORS = {
    session = "66b3ff",
    zone = "66d98c",
    target = "ffd966",
    combat = "ff6659",
    player = "e6e6e6",
    spell = "c299ff",
    system = "a6a6a6",
    error = "ff8c40",
    taint = "ff66cc",
    lua = "ff4040",
}

ns.REPORT_COLORS = { reported = "66d98c", ["local"] = "a6a6a6" }
ns.COLOR_LABEL = "999999"
ns.COLOR_MUTED = "808080"
ns.COLOR_WARNING = "ff9933"

-- Settings are declared once: defaults, validation, /od set and /od config all read this list.
local SETTINGS = {
    { key = "hudVisible", type = "boolean", default = true, help = "Show the HUD" },
    { key = "hudMinimized", type = "boolean", default = false, help = "Collapse the HUD to title and buttons" },
    { key = "captureEvents", type = "boolean", default = true, help = "Record tracked events in the ring buffer" },
    { key = "printEventsToChat", type = "boolean", default = false, help = "Echo each new tracked event to chat" },
    { key = "maxEvents", type = "number", default = 200, min = 20, max = 1000, help = "Ring buffer capacity" },
    { key = "incidentEvents", type = "number", default = 40, min = 5, max = 200, help = "Recent events copied into each incident" },
    { key = "captureLuaErrors", type = "boolean", default = false, help = "Record Lua errors as events (chains the error handler)" },
}

local SETTINGS_BY_KEY = {}
for _, spec in ipairs(SETTINGS) do
    SETTINGS_BY_KEY[spec.key:lower()] = spec
end

local SEVERITY_SET = {}
for _, severity in ipairs(ns.SEVERITIES) do
    SEVERITY_SET[severity] = true
end

-- Field name -> expected type. Anything else found on an incident (legacy data)
-- is shown and exported under "Other fields" instead of being dropped.
local KNOWN_INCIDENT_FIELDS = {
    id = "number", title = "string", notes = "string", severity = "string",
    createdAt = "number", createdAtText = "string",
    client = "table", character = "table", location = "table", performance = "table",
    player = "table", target = "table", lastEvent = "table", recentEvents = "table",
    metadata = "table", report = "table",
}

-- Expected field types inside each snapshot block ("scalar" = string or number).
-- The detail/export view only reads values of the expected type; anything else
-- inside a block (legacy data) is listed under "Other fields" as block.key.
local SECTION_FIELDS = {
    client = { version = "scalar", build = "scalar", buildDate = "scalar", tocVersion = "scalar", locale = "scalar" },
    character = { name = "scalar", realm = "scalar", class = "scalar", classToken = "scalar", race = "scalar",
        level = "number", faction = "scalar" },
    location = { zone = "scalar", subZone = "scalar", mapID = "scalar", mapName = "scalar", x = "number", y = "number",
        instanceType = "scalar", instanceName = "scalar", difficulty = "scalar", instanceMapID = "scalar",
        worldX = "number", worldY = "number" },
    performance = { fps = "scalar", fpsMin = "scalar", fpsAvg = "scalar", fpsWindow = "scalar", homeLatency = "scalar",
        worldLatency = "scalar", luaMemoryKB = "number" },
    player = { combat = "boolean", combatLockdown = "boolean", mounted = "boolean", deadOrGhost = "boolean",
        swimming = "boolean", resting = "boolean" },
    target = { exists = "boolean", name = "scalar", level = "number", guid = "scalar", guidType = "scalar",
        npcId = "scalar", objectId = "scalar", classification = "scalar", isPlayer = "boolean", reaction = "number",
        creatureType = "scalar", dead = "boolean" },
    metadata = { addonVersion = "scalar", schemaVersion = "scalar", sessionId = "scalar", sessionUptime = "number",
        serverTime = "number", addOns = "table", restrictedValues = "number", migratedFromSchema = "scalar",
        originalId = "scalar" },
    -- mutable report-tracking metadata; everything above is the frozen snapshot
    report = { status = "string", provider = "scalar", method = "scalar", reportedAt = "number", history = "table",
        legacyStatus = "scalar" },
}
local SECTION_ORDER = { "client", "character", "location", "performance", "player", "target", "metadata", "report" }
local REPORT_HISTORY_FIELDS = { status = "string", method = "scalar", at = "number" }
local EVENT_FIELDS = { time = "number", offset = "number", event = "scalar", category = "scalar", info = "scalar", count = "number" }

local VALID_POINTS = {
    TOP = true, BOTTOM = true, LEFT = true, RIGHT = true, CENTER = true,
    TOPLEFT = true, TOPRIGHT = true, BOTTOMLEFT = true, BOTTOMRIGHT = true,
}

local REACTION_LABELS = { "Hated", "Hostile", "Unfriendly", "Neutral", "Friendly", "Honored", "Revered", "Exalted" }

-- GUID types whose 6th field is a template ID worth surfacing.
local GUID_ID_KINDS = { Creature = "npc", Vehicle = "npc", Pet = "npc", GameObject = "object" }

-- Read-only shared stand-in for missing sub-tables of legacy/partial incidents.
local EMPTY = setmetatable({}, { __newindex = function() error("OnionDebug: EMPTY is read-only", 2) end })

------------------------------------------------------------------------
-- Small utilities
------------------------------------------------------------------------

local restrictedCount = 0

-- Secret values (12.x engine) cannot be compared, concatenated or stored.
-- Treat them as unavailable and count them so snapshots can say so.
local function Readable(value)
    if value ~= nil and IsSecret and IsSecret(value) then
        restrictedCount = restrictedCount + 1
        return nil
    end
    return value
end

local function Flag(value)
    value = Readable(value)
    if value == nil then
        return nil
    end
    return value and true or false
end

local function CallFlag(fn, ...)
    if type(fn) ~= "function" then
        return nil
    end
    local value = fn(...)
    if value ~= nil and IsSecret and IsSecret(value) then
        restrictedCount = restrictedCount + 1
        return nil
    end
    return value and true or false
end

local function NonEmpty(value)
    value = Readable(value)
    if value == "" then
        return nil
    end
    return value
end

local function Round(value, decimals)
    if type(value) ~= "number" then
        return nil
    end
    local factor = 10 ^ (decimals or 0)
    return floor(value * factor + 0.5) / factor
end

local function Sub(tbl, key)
    local value = type(tbl) == "table" and tbl[key] or nil
    return type(value) == "table" and value or EMPTY
end

function ns.Trim(text)
    if type(text) ~= "string" then
        return ""
    end
    return (text:match("^%s*(.-)%s*$"))
end

-- Byte-length truncation that never splits a UTF-8 sequence.
local function Truncate(text, maxLength)
    if #text <= maxLength then
        return text
    end
    local cut = maxLength - 3
    while cut > 0 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then
            break
        end
        cut = cut - 1
    end
    return text:sub(1, cut) .. "..."
end
ns.Truncate = Truncate

-- Byte index of the letter after the one starting at `index`, counting letters
-- the way EditBox:SetMaxLetters does (UTF-8 characters; the escaped pipe "||"
-- typed by the user is one letter).
local function NextLetter(text, index)
    local byte = text:byte(index)
    if byte == 124 and text:byte(index + 1) == 124 then
        return index + 2
    elseif byte >= 0xF0 then
        return index + 4
    elseif byte >= 0xE0 then
        return index + 3
    elseif byte >= 0xC0 then
        return index + 2
    end
    return index + 1
end

-- Byte index just past the first `count` letters; nil if the text is not longer.
local function LetterBoundary(text, count)
    local index, letters = 1, 0
    while index <= #text do
        if letters == count then
            return index - 1
        end
        index = NextLetter(text, index)
        letters = letters + 1
    end
    return nil
end

local function LetterCount(text)
    local index, letters = 1, 0
    while index <= #text do
        index = NextLetter(text, index)
        letters = letters + 1
    end
    return letters
end
ns.LetterCount = LetterCount

-- Letter-based truncation for user-typed text, so a title or note that the
-- form accepted is never cut on save.
local function TruncateLetters(text, maxLetters)
    if not LetterBoundary(text, maxLetters) then
        return text
    end
    return text:sub(1, LetterBoundary(text, maxLetters - 3)) .. "..."
end

-- Game-provided text (chat, errors) may carry color codes, links and icons.
-- Store it as plain single-line text so HUD, detail and export stay clean.
local function CleanText(text, maxLength)
    if type(text) == "number" then
        text = tostring(text)
    elseif type(text) ~= "string" then
        return nil
    end
    text = text:gsub("|c%x%x%x%x%x%x%x%x", "")
        :gsub("|r", "")
        :gsub("|H.-|h(.-)|h", "%1")
        :gsub("|T.-|t", "")
        :gsub("|A.-|a", "")
        :gsub("|n", " ")
        :gsub("[\r\n\t]+", " ")
        :gsub("|", "/")
    text = ns.Trim(text)
    if text == "" then
        return nil
    end
    return Truncate(text, maxLength or EVENT_INFO_MAX_LENGTH)
end

local function Display(value)
    if value == nil or value == "" then
        return NA
    elseif value == true then
        return "Yes"
    elseif value == false then
        return "No"
    end
    return tostring(value)
end
ns.Display = Display

local function Scalar(value)
    local kind = type(value)
    if kind == "string" or kind == "number" then
        return value
    end
    return nil
end

local function Colorize(hex, text)
    return "|cff" .. hex .. text .. "|r"
end
ns.Colorize = Colorize

function ns.Print(message)
    local chat = DEFAULT_CHAT_FRAME
    local line = "|cff33ff99OnionDebug|r: " .. tostring(message)
    if chat then
        chat:AddMessage(line)
    else
        print(line)
    end
end

local function PositiveInteger(value)
    value = tonumber(value)
    if value and value >= 1 and value < 2 ^ 31 and value == floor(value) then
        return value
    end
    return nil
end

local function NotifyUI(topic)
    local ui = ns.UI
    if ui and ui.OnModelChanged then
        ui.OnModelChanged(topic)
    end
end
ns.NotifyUI = NotifyUI

------------------------------------------------------------------------
-- Static client / addon information (cached once)
------------------------------------------------------------------------

local function ReadAddonVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local version = getMetadata and getMetadata(ADDON_NAME, "Version")
    if type(version) == "string" and version ~= "" then
        return version
    end
    return "dev"
end

local function ReadClientInfo()
    local version, build, buildDate, tocVersion = GetBuildInfo()
    return {
        version = version,
        build = build,
        buildDate = buildDate,
        tocVersion = tocVersion,
        locale = GetLocale and GetLocale() or nil,
    }
end

ns.VERSION = ReadAddonVersion()
ns.client = ReadClientInfo()

-- "1.60.1.70009" from a snapshot's client table (or the live client).
function ns.FormatBuild(client)
    if type(client) ~= "table" then
        return nil
    end
    local version, build = client.version, client.build
    version = (type(version) == "string" or type(version) == "number") and tostring(version) or nil
    build = (type(build) == "string" or type(build) == "number") and tostring(build) or nil
    if version and build then
        return version .. "." .. build
    end
    return version
end

ns.CURRENT_BUILD = ns.FormatBuild(ns.client)

------------------------------------------------------------------------
-- GUID parsing
------------------------------------------------------------------------

-- Returns guidType, entityId, idKind ("npc"/"object") for any GUID string.
-- Player GUIDs and unknown types return only the type.
function ns.ParseGUID(guid)
    if type(guid) ~= "string" or guid == "" then
        return nil
    end
    local guidType, _, _, _, _, entityId = strsplit("-", guid)
    local idKind = GUID_ID_KINDS[guidType]
    if not idKind then
        return guidType
    end
    return guidType, tonumber(entityId), idKind
end

------------------------------------------------------------------------
-- Context collectors
-- Each fills the given table (reused by the HUD, fresh for snapshots) and
-- degrades to nil fields when an API is missing, restricted or returns nil.
------------------------------------------------------------------------

local function CollectCharacter()
    local className, classToken = UnitClass("player")
    return {
        name = NonEmpty(UnitName("player")),
        realm = NonEmpty(GetRealmName and GetRealmName()),
        class = NonEmpty(className),
        classToken = NonEmpty(classToken),
        race = NonEmpty((UnitRace("player"))),
        level = Readable(UnitLevel("player")),
        faction = NonEmpty((UnitFactionGroup("player"))),
    }
end

-- `detailed` adds map name, instance and world position (snapshots only;
-- the HUD refresh skips them to keep its tick cheap).
local function CollectLocation(out, detailed)
    out.zone = NonEmpty(GetRealZoneText and GetRealZoneText())
    out.subZone = NonEmpty(GetSubZoneText and GetSubZoneText())

    local mapID, mapName, x, y
    if C_Map and C_Map.GetBestMapForUnit then
        mapID = Readable(C_Map.GetBestMapForUnit("player"))
    end
    if mapID then
        if detailed and C_Map.GetMapInfo then
            local info = C_Map.GetMapInfo(mapID)
            mapName = type(info) == "table" and NonEmpty(info.name) or nil
        end
        if C_Map.GetPlayerMapPosition then
            -- nil inside instances and on maps without player coordinates
            local position = C_Map.GetPlayerMapPosition(mapID, "player")
            if position and position.GetXY then
                local px, py = position:GetXY()
                px, py = Readable(px), Readable(py)
                if type(px) == "number" and type(py) == "number" then
                    x, y = Round(px * 100, 2), Round(py * 100, 2)
                end
            end
        end
    end
    out.mapID, out.mapName, out.x, out.y = mapID, mapName, x, y
    if not detailed then
        return out
    end

    local instanceType, instanceName, difficulty, instanceMapID
    if GetInstanceInfo then
        local name, kind, _, difficultyName, _, _, _, mapId = GetInstanceInfo()
        instanceType = NonEmpty(kind)
        if instanceType and instanceType ~= "none" then
            instanceName = NonEmpty(name)
            difficulty = NonEmpty(difficultyName)
        end
        instanceMapID = Readable(mapId)
    end
    out.instanceType, out.instanceName, out.difficulty, out.instanceMapID = instanceType, instanceName, difficulty, instanceMapID

    local worldX, worldY
    if UnitPosition then
        -- restricted (nil) inside instances
        local px, py = UnitPosition("player")
        px, py = Readable(px), Readable(py)
        if type(px) == "number" and type(py) == "number" then
            worldX, worldY = Round(px, 1), Round(py, 1)
        end
    end
    out.worldX, out.worldY = worldX, worldY
    return out
end

local function CollectPerformance(out)
    out.fps = GetFramerate and Round(Readable(GetFramerate()), 0) or nil
    local home, world
    if GetNetStats then
        local _, _, latencyHome, latencyWorld = GetNetStats()
        home, world = Readable(latencyHome), Readable(latencyWorld)
    end
    out.homeLatency = type(home) == "number" and home or nil
    out.worldLatency = type(world) == "number" and world or nil
    return out
end

local function CollectPlayerState(out)
    out.combat = CallFlag(UnitAffectingCombat, "player")
    out.combatLockdown = CallFlag(InCombatLockdown)
    out.mounted = CallFlag(IsMounted)
    out.deadOrGhost = CallFlag(UnitIsDeadOrGhost, "player")
    out.swimming = CallFlag(IsSwimming)
    out.resting = CallFlag(IsResting)
    return out
end

local function CollectTarget(out)
    wipe(out)
    local exists = CallFlag(UnitExists, "target")
    out.exists = exists
    if not exists then
        return out
    end
    local name, realm = UnitName("target")
    name, realm = NonEmpty(name), NonEmpty(realm)
    out.name = (name and realm) and (name .. "-" .. realm) or name
    out.level = Readable(UnitLevel("target"))
    out.guid = NonEmpty(UnitGUID("target"))
    local guidType, entityId, idKind = ns.ParseGUID(out.guid)
    out.guidType = guidType
    if idKind == "npc" then
        out.npcId = entityId
    elseif idKind == "object" then
        out.objectId = entityId
    end
    out.classification = NonEmpty(UnitClassification("target"))
    out.isPlayer = CallFlag(UnitIsPlayer, "target")
    out.reaction = Readable(UnitReaction("player", "target"))
    out.creatureType = NonEmpty(UnitCreatureType("target"))
    out.dead = CallFlag(UnitIsDead, "target")
    return out
end

local function CollectLoadedAddOns()
    local getCount = (C_AddOns and C_AddOns.GetNumAddOns) or GetNumAddOns
    local getInfo = (C_AddOns and C_AddOns.GetAddOnInfo) or GetAddOnInfo
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if not (getCount and getInfo and isLoaded) then
        return nil
    end
    local names = {}
    for index = 1, getCount() do
        local name = getInfo(index)
        if type(name) == "string" and not name:find("^Blizzard_") and isLoaded(index) then
            names[#names + 1] = name
        end
    end
    sort(names)
    return names
end

-- Fills a reusable { location, performance, player, target } table for the HUD.
function ns.CollectLive(state)
    CollectLocation(state.location, false)
    CollectPerformance(state.performance)
    CollectPlayerState(state.player)
    CollectTarget(state.target)
    return state
end

------------------------------------------------------------------------
-- Session
-- One session per game login; /reload keeps it (persisted in the DB).
------------------------------------------------------------------------

local function ResolveSession(isInitialLogin)
    local db = ns.db
    local session = db.session
    if isInitialLogin or type(session) ~= "table" then
        local now = time()
        session = { id = date(SESSION_ID_FORMAT, now), startedAt = now }
        db.session = session
    end
    ns.session = session
end

function ns.GetSessionUptime()
    local session = ns.session
    if not session then
        return nil
    end
    return max(0, time() - session.startedAt)
end

function ns.CountSessionIncidents()
    local sessionId = ns.session and ns.session.id
    if not sessionId or not ns.db then
        return 0
    end
    local count = 0
    for _, incident in ipairs(ns.db.incidents) do
        if Sub(incident, "metadata").sessionId == sessionId then
            count = count + 1
        end
    end
    return count
end

------------------------------------------------------------------------
-- Event ring buffer
-- Fixed capacity; slot tables are reused once the buffer is full, so a
-- steady stream of events does not allocate.
------------------------------------------------------------------------

-- `version` changes on every push, coalesce, clear or resize, so readers
-- (the HUD) can skip re-rendering when nothing happened.
local ring = { entries = {}, head = 0, size = 0, capacity = 200, recorded = 0, version = 0 }

-- index 1 = newest
function ns.GetEvent(index)
    if index < 1 or index > ring.size then
        return nil
    end
    return ring.entries[(ring.head - index) % ring.capacity + 1]
end

function ns.GetEventStats()
    return ring.size, ring.capacity, ring.recorded
end

function ns.GetEventVersion()
    return ring.version
end

local function ResizeEventBuffer(capacity)
    local keep = min(ring.size, capacity)
    local entries = {}
    for index = keep, 1, -1 do
        entries[keep - index + 1] = ns.GetEvent(index)
    end
    ring.entries, ring.capacity, ring.size, ring.head = entries, capacity, keep, keep
    ring.version = ring.version + 1
end

local function PushEvent(event, category, info)
    local now = GetTime()
    local newest = ns.GetEvent(1)
    if newest and newest.event == event and newest.info == info and now - newest.uptime <= EVENT_COALESCE_SECONDS then
        newest.count = newest.count + 1
        newest.time, newest.uptime = time(), now
        ring.version = ring.version + 1
        return newest, false
    end
    local slot = ring.head % ring.capacity + 1
    local entry = ring.entries[slot]
    if not entry then
        entry = {}
        ring.entries[slot] = entry
    end
    entry.time, entry.uptime, entry.event, entry.category, entry.info, entry.count = time(), now, event, category, info, 1
    ring.head = slot
    if ring.size < ring.capacity then
        ring.size = ring.size + 1
    end
    ring.recorded = ring.recorded + 1
    ring.version = ring.version + 1
    return entry, true
end

function ns.RecordEvent(event, category, info, maxLength)
    local entry, isNew = PushEvent(event, category, CleanText(info, maxLength))
    if isNew and ns.db and ns.db.settings.printEventsToChat then
        ns.Print(ns.FormatEventLine(entry, true, false))
    end
    NotifyUI("events")
end

function ns.ClearEvents()
    wipe(ring.entries)
    ring.head, ring.size = 0, 0
    ring.version = ring.version + 1
    NotifyUI("events")
end

------------------------------------------------------------------------
-- Tracked events
------------------------------------------------------------------------

local function FirstString(a1, a2)
    if type(a1) == "string" then
        return a1
    elseif type(a2) == "string" then
        return a2
    end
    return nil
end

local function ZoneInfo()
    local zone = NonEmpty(GetRealZoneText and GetRealZoneText())
    local subZone = NonEmpty(GetSubZoneText and GetSubZoneText())
    if subZone and subZone ~= zone then
        return (zone or "?") .. " / " .. subZone
    end
    return zone
end

local function TargetInfo()
    if not CallFlag(UnitExists, "target") then
        return "no target"
    end
    local name = NonEmpty((UnitName("target"))) or "Unknown"
    local _, entityId, idKind = ns.ParseGUID(NonEmpty(UnitGUID("target")))
    if idKind == "npc" and entityId then
        return format("%s (NPC %d)", name, entityId)
    end
    return name
end

function ns.DescribeSpell(spellID)
    if type(spellID) ~= "number" then
        return nil
    end
    local name
    if C_Spell and C_Spell.GetSpellName then
        name = C_Spell.GetSpellName(spellID)
    elseif GetSpellInfo then
        name = GetSpellInfo(spellID)
    end
    name = NonEmpty(name)
    return name and format("%s (%d)", name, spellID) or tostring(spellID)
end

local function SpellInfo(_, _, spellID)
    return ns.DescribeSpell(spellID)
end

local function ActionInfo(addonName, functionName)
    return format("%s -> %s", tostring(addonName or "?"), tostring(functionName or "?"))
end

-- Deliberately excludes high-frequency events (UNIT_AURA, CLEU, UNIT_POWER_*).
local TRACKED_EVENTS = {
    { event = "PLAYER_LOGIN", category = "session" },
    { event = "PLAYER_ENTERING_WORLD", category = "session", info = function(isInitialLogin, isReloadingUi)
        return isInitialLogin and "login" or isReloadingUi and "reload" or "loading screen"
    end },
    { event = "PLAYER_LEAVING_WORLD", category = "session" },
    { event = "ZONE_CHANGED", category = "zone", info = ZoneInfo },
    { event = "ZONE_CHANGED_INDOORS", category = "zone", info = ZoneInfo },
    { event = "ZONE_CHANGED_NEW_AREA", category = "zone", info = ZoneInfo },
    { event = "PLAYER_TARGET_CHANGED", category = "target", info = TargetInfo },
    { event = "PLAYER_REGEN_DISABLED", category = "combat", info = function() return "entered combat" end },
    { event = "PLAYER_REGEN_ENABLED", category = "combat", info = function() return "left combat" end },
    { event = "PLAYER_LEVEL_UP", category = "player", info = function(level) return level and ("level " .. tostring(level)) end },
    { event = "PLAYER_DEAD", category = "player" },
    { event = "PLAYER_ALIVE", category = "player" },
    { event = "PLAYER_UNGHOST", category = "player" },
    { event = "BAG_UPDATE_DELAYED", category = "player" },
    { event = "QUEST_LOG_UPDATE", category = "player" },
    { event = "UNIT_SPELLCAST_START", category = "spell", unit = "player", info = SpellInfo },
    { event = "UNIT_SPELLCAST_SUCCEEDED", category = "spell", unit = "player", info = SpellInfo },
    { event = "UNIT_SPELLCAST_FAILED", category = "spell", unit = "player", info = SpellInfo },
    { event = "CHAT_MSG_SYSTEM", category = "system", info = FirstString },
    { event = "UI_ERROR_MESSAGE", category = "error", info = FirstString },
    { event = "LUA_WARNING", category = "lua", info = FirstString },
    { event = "ADDON_ACTION_BLOCKED", category = "taint", info = ActionInfo },
    { event = "ADDON_ACTION_FORBIDDEN", category = "taint", info = ActionInfo },
}

local TRACKED_BY_EVENT = {}
for _, spec in ipairs(TRACKED_EVENTS) do
    TRACKED_BY_EVENT[spec.event] = spec
end

local tracker = CreateFrame("Frame")
local trackerState = { registered = 0, unavailable = {} }

tracker:SetScript("OnEvent", function(_, event, a1, a2, a3, a4)
    local spec = TRACKED_BY_EVENT[event]
    if not spec then
        return
    end
    -- Payloads can be secret (chat lockdown, restricted spell casts).
    a1, a2, a3, a4 = Readable(a1), Readable(a2), Readable(a3), Readable(a4)
    if spec.unit and a1 ~= spec.unit then
        return
    end
    ns.RecordEvent(event, spec.category, spec.info and spec.info(a1, a2, a3, a4))
end)

local function IsEventKnown(event)
    if C_EventUtils and C_EventUtils.IsEventValid then
        return C_EventUtils.IsEventValid(event)
    end
    return true
end

local function RegisterTrackedEvents()
    local registered, unavailable = 0, trackerState.unavailable
    wipe(unavailable)
    for _, spec in ipairs(TRACKED_EVENTS) do
        local ok = IsEventKnown(spec.event)
        if ok then
            -- Registering an event the client does not know raises an error.
            if spec.unit and tracker.RegisterUnitEvent then
                ok = pcall(tracker.RegisterUnitEvent, tracker, spec.event, spec.unit)
            else
                ok = pcall(tracker.RegisterEvent, tracker, spec.event)
            end
        end
        if ok then
            registered = registered + 1
        else
            unavailable[#unavailable + 1] = spec.event
        end
    end
    trackerState.registered = registered
end

local function UpdateEventRegistration()
    tracker:UnregisterAllEvents()
    trackerState.registered = 0
    wipe(trackerState.unavailable)
    if ns.db.settings.captureEvents then
        RegisterTrackedEvents()
    end
end

------------------------------------------------------------------------
-- Performance sampling (FPS has no event; one cheap sample per second)
------------------------------------------------------------------------

local perf = { samples = {}, head = 0, count = 0, elapsed = 0 }

local function SamplePerformance()
    local fps = GetFramerate and Readable(GetFramerate())
    if type(fps) ~= "number" then
        return
    end
    perf.head = perf.head % PERF_WINDOW_SAMPLES + 1
    perf.samples[perf.head] = fps
    if perf.count < PERF_WINDOW_SAMPLES then
        perf.count = perf.count + 1
    end
end

local function PerformanceWindow()
    if perf.count == 0 then
        return nil
    end
    local lowest, sum = math.huge, 0
    for index = 1, perf.count do
        local fps = perf.samples[index]
        if fps < lowest then
            lowest = fps
        end
        sum = sum + fps
    end
    return Round(lowest, 0), Round(sum / perf.count, 0), perf.count * PERF_SAMPLE_INTERVAL
end

local function OnPerformanceUpdate(_, elapsed)
    perf.elapsed = perf.elapsed + elapsed
    if perf.elapsed >= PERF_SAMPLE_INTERVAL then
        perf.elapsed = 0
        SamplePerformance()
    end
end

------------------------------------------------------------------------
-- Optional Lua error capture
-- Off by default. Chains to the previous handler (Blizzard or BugGrabber)
-- so error display keeps working; it only adds a LUA_ERROR event.
------------------------------------------------------------------------

local luaCapture = { handler = nil, state = "off" }

local function RecordLuaError(message)
    message = Readable(message)
    ns.RecordEvent("LUA_ERROR", "lua", message ~= nil and tostring(message) or "(restricted message)", LUA_ERROR_MAX_LENGTH)
end

local function InstallLuaErrorCapture()
    if luaCapture.handler then
        return
    end
    if not (geterrorhandler and seterrorhandler) then
        luaCapture.state = "unavailable"
        return
    end
    local previous = geterrorhandler()
    local function handler(message, ...)
        if ns.db and ns.db.settings.captureLuaErrors then
            pcall(RecordLuaError, message) -- an error handler must never raise
        end
        if previous then
            return previous(message, ...)
        end
    end
    seterrorhandler(handler)
    if geterrorhandler() == handler then
        luaCapture.handler, luaCapture.state = handler, "active"
    else
        luaCapture.state = "blocked" -- another addon locks the handler
    end
end

function ns.GetLuaCaptureState()
    if not (ns.db and ns.db.settings.captureLuaErrors) then
        return "off"
    end
    return luaCapture.state
end

------------------------------------------------------------------------
-- Snapshots
------------------------------------------------------------------------

local function CopyTable(source)
    local copy = {}
    for key, value in pairs(source) do
        copy[key] = value
    end
    return copy
end

local function CopyEvent(entry, now)
    if not entry then
        return nil
    end
    return {
        time = entry.time,
        offset = Round(entry.uptime - now, 1),
        event = entry.event,
        category = entry.category,
        info = entry.info,
        count = entry.count > 1 and entry.count or nil,
    }
end

-- Freezes the full technical context right now. The result is never
-- recomputed: saving an incident only adds the human fields to it.
function ns.CaptureSnapshot()
    restrictedCount = 0
    local now, uptime = time(), GetTime()

    local performance = CollectPerformance({})
    performance.fpsMin, performance.fpsAvg, performance.fpsWindow = PerformanceWindow()
    performance.luaMemoryKB = Round(collectgarbage("count"), 0)

    local recentEvents = {}
    for index = 1, min(ns.db.settings.incidentEvents, ring.size) do
        recentEvents[index] = CopyEvent(ns.GetEvent(index), uptime)
    end

    local snapshot = {
        createdAt = now,
        createdAtText = date(DATE_FORMAT, now),
        client = CopyTable(ns.client),
        character = CollectCharacter(),
        location = CollectLocation({}, true),
        performance = performance,
        player = CollectPlayerState({}),
        target = CollectTarget({}),
        lastEvent = CopyEvent(ns.GetEvent(1), uptime),
        recentEvents = recentEvents,
        metadata = {
            addonVersion = ns.VERSION,
            schemaVersion = SCHEMA_VERSION,
            sessionId = ns.session and ns.session.id or nil,
            sessionUptime = ns.GetSessionUptime(),
            serverTime = GetServerTime and Readable(GetServerTime()) or nil,
            addOns = CollectLoadedAddOns(),
        },
    }
    snapshot.metadata.restrictedValues = restrictedCount > 0 and restrictedCount or nil
    return snapshot
end

------------------------------------------------------------------------
-- Incident store
-- db.incidents is an array sorted by ascending id. IDs come from
-- db.nextIncidentId, which only ever grows: deleted IDs are never reused.
------------------------------------------------------------------------

function ns.GetIncidents()
    return ns.db.incidents
end

function ns.FindIncident(id)
    for index, incident in ipairs(ns.db.incidents) do
        if incident.id == id then
            return incident, index
        end
    end
    return nil
end

function ns.GetLatestIncident()
    local incidents = ns.db.incidents
    return incidents[#incidents]
end

-- Mark Bug: capture immediately; the form only adds title/notes/severity later.
-- Returns the pending draft and whether it was created by this call.
function ns.MarkBug()
    if ns.draft then
        return ns.draft, false
    end
    ns.draft = ns.CaptureSnapshot()
    NotifyUI("draft")
    return ns.draft, true
end

function ns.DiscardDraft()
    if ns.draft then
        ns.draft = nil
        NotifyUI("draft")
    end
end

function ns.SaveIncident(snapshot, title, notes, severity)
    if ns.readOnlyReason then
        return nil, ns.readOnlyReason
    end
    if type(snapshot) ~= "table" then
        return nil, "There is no captured context to save."
    end
    if snapshot.id then
        return nil, format("Incident %s is already saved.", ns.FormatId(snapshot.id))
    end
    title = ns.Trim(title)
    if title == "" then
        return nil, "A title is required."
    end
    notes = ns.Trim(notes)

    local db = ns.db
    snapshot.id = db.nextIncidentId
    db.nextIncidentId = snapshot.id + 1
    snapshot.title = TruncateLetters(title, ns.TITLE_MAX_LETTERS)
    snapshot.notes = notes ~= "" and TruncateLetters(notes, ns.NOTES_MAX_LETTERS) or nil
    snapshot.severity = SEVERITY_SET[severity] and severity or ns.DEFAULT_SEVERITY
    snapshot.report = ns.NewReportState()
    db.incidents[#db.incidents + 1] = snapshot

    if ns.draft == snapshot then
        ns.draft = nil
        NotifyUI("draft")
    end
    NotifyUI("incidents")
    ns.Print(format("Incident %s saved: %s", ns.FormatId(snapshot.id), snapshot.title))
    return snapshot
end

-- /od mark <title>: snapshot and save in one step, independent of any open draft.
function ns.QuickMark(title)
    return ns.SaveIncident(ns.CaptureSnapshot(), title, nil, ns.DEFAULT_SEVERITY)
end

-- Returns true, or false plus a reason.
function ns.DeleteIncident(id)
    if ns.readOnlyReason then
        return false, ns.readOnlyReason
    end
    local incident, index = ns.FindIncident(id)
    if not incident then
        return false, format("Incident %s not found.", ns.FormatId(id))
    end
    remove(ns.db.incidents, index)
    NotifyUI("incidents")
    return true
end

function ns.IncidentZone(incident)
    return Scalar(Sub(incident, "location").zone) or Scalar(incident.zone) -- second: legacy flat field
end

function ns.IncidentMatches(incident, needle)
    local location, target = Sub(incident, "location"), Sub(incident, "target")
    local haystack = concat({
        ns.FormatId(incident.id),
        tostring(Scalar(incident.title) or ""),
        tostring(Scalar(incident.notes) or ""),
        tostring(Scalar(incident.severity) or ""),
        tostring(ns.IncidentZone(incident) or ""),
        tostring(Scalar(location.subZone) or ""),
        tostring(Scalar(target.name) or ""),
        tostring(Scalar(target.npcId) or ""),
        tostring(ns.FormatBuild(Sub(incident, "client")) or ""),
        ns.IsReported(incident) and "reported" or "local",
        ns.ReportRef(incident),
    }, "\n"):lower()
    return haystack:find(needle, 1, true) ~= nil
end

------------------------------------------------------------------------
-- Report tracking
-- incident.report is mutable metadata about the transport to Blizzard. It is
-- kept apart from the frozen snapshot: changing it never touches other fields.
--   status     "local" | "reported"
--   provider   "blizzard"
--   method     "detected" (Issue Reporter submission carried the incident
--              reference) | "manual" (user confirmed); only while reported
--   reportedAt epoch of the current "reported" mark
--   history    bounded log of status changes { status, method, at }
------------------------------------------------------------------------

local REPORT_LOCAL, REPORT_REPORTED = "local", "reported"
local REPORT_HISTORY_MAX = 20
ns.REPORT_METHOD_LABELS = {
    detected = "detected: Issue Reporter submission contained the incident reference",
    manual = "marked manually",
}

function ns.NewReportState()
    return { status = REPORT_LOCAL, provider = "blizzard" }
end

function ns.IsReported(incident)
    local report = incident.report
    return type(report) == "table" and report.status == REPORT_REPORTED
end

-- Unique token placed at the start of the Blizzard report text. Finding it in
-- a submitted bug report identifies exactly which incident was sent.
function ns.ReportRef(incident)
    local created = incident.createdAt
    if type(created) ~= "number" or created ~= created or created < 0 or created >= 2 ^ 31 then
        created = 0
    end
    return format("OD-%04d-%d", tonumber(incident.id) or 0, floor(created))
end

local function SetReportStatus(incident, status, method)
    if ns.readOnlyReason then
        return false, ns.readOnlyReason
    end
    local report = incident.report
    if type(report) ~= "table" then
        return false, format("Incident %s has no report metadata.", ns.FormatId(incident.id))
    end
    if report.status == status then
        return false, format("Incident %s is already %s.", ns.FormatId(incident.id),
            status == REPORT_REPORTED and "marked as reported" or "not reported")
    end
    local now = time()
    report.status, report.provider = status, "blizzard"
    if status == REPORT_REPORTED then
        report.reportedAt, report.method = now, method
    else
        report.reportedAt, report.method = nil, nil -- the previous mark stays in history
    end
    if type(report.history) ~= "table" then
        report.history = {}
    end
    local history = report.history
    history[#history + 1] = { status = status, method = method, at = now }
    while #history > REPORT_HISTORY_MAX do
        remove(history, 1)
    end
    NotifyUI("incidents")
    return true
end

-- Explicit user confirmation that the incident was sent to Blizzard.
function ns.MarkReported(id)
    local incident = ns.FindIncident(id)
    if not incident then
        return false, format("Incident %s not found.", ns.FormatId(id))
    end
    return SetReportStatus(incident, REPORT_REPORTED, "manual")
end

-- Undo a mark (e.g. set by mistake). The snapshot and the history are kept.
function ns.MarkNotReported(id)
    local incident = ns.FindIncident(id)
    if not incident then
        return false, format("Incident %s not found.", ns.FormatId(id))
    end
    return SetReportStatus(incident, REPORT_LOCAL, nil)
end

function ns.CountUnreported()
    local count = 0
    for _, incident in ipairs(ns.db.incidents) do
        if not ns.IsReported(incident) then
            count = count + 1
        end
    end
    return count
end

------------------------------------------------------------------------
-- Blizzard Issue Reporter (transport)
-- The official reporter is Blizzard's Blizzard_PTRFeedback addon (Beta/PTR
-- only). It has no public API to open it or pre-fill text, so OnionDebug never
-- calls its internals. Every bug it sends goes through the documented
-- C_UserFeedback.SubmitBug(bugInfo); a post-hook (hooksecurefunc, no taint on
-- Blizzard's path) reads the submitted text, and an incident is marked
-- reported only when that text contains its unique reference.
------------------------------------------------------------------------

local BlizzardReporter = { hooked = false }
ns.BlizzardReporter = BlizzardReporter

function BlizzardReporter.IsAvailable()
    local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or IsAddOnLoaded
    if isLoaded and isLoaded("Blizzard_PTRFeedback") then
        return true
    end
    return type(PTR_IssueReporter) == "table"
end

function BlizzardReporter.CanDetectSubmission()
    return BlizzardReporter.hooked
end

local function OnBugSubmitted(bugInfo)
    if (IsSecret and IsSecret(bugInfo)) or type(bugInfo) ~= "string" or not ns.db or ns.readOnlyReason then
        return
    end
    for idText, createdText in bugInfo:gmatch("OD%-(%d+)%-(%d+)") do
        local incident = ns.FindIncident(tonumber(idText))
        if incident and not ns.IsReported(incident) and ns.ReportRef(incident) == ("OD-" .. idText .. "-" .. createdText) then
            if SetReportStatus(incident, REPORT_REPORTED, "detected") then
                ns.Print(format("Incident %s marked as reported: the Issue Reporter submission contained %s.",
                    ns.FormatId(incident.id), ns.ReportRef(incident)))
            end
        end
    end
end

function BlizzardReporter.InstallSubmitHook()
    if BlizzardReporter.hooked or type(hooksecurefunc) ~= "function"
        or type(C_UserFeedback) ~= "table" or type(C_UserFeedback.SubmitBug) ~= "function" then
        return
    end
    hooksecurefunc(C_UserFeedback, "SubmitBug", function(bugInfo)
        -- An error here must not abort Blizzard's submit handler; report it instead.
        local ok, err = pcall(OnBugSubmitted, bugInfo)
        if not ok and geterrorhandler then
            geterrorhandler()(err)
        end
    end)
    BlizzardReporter.hooked = true
end

------------------------------------------------------------------------
-- Shared formatting (HUD, form, history, detail and export all use these)
------------------------------------------------------------------------

function ns.FormatId(id)
    if type(id) == "number" then
        return format("#%04d", id)
    end
    return "#????"
end

function ns.FormatClock(epoch)
    return type(epoch) == "number" and date(CLOCK_FORMAT, epoch) or "--:--:--"
end

function ns.FormatDateTime(epoch)
    return type(epoch) == "number" and date(DATE_FORMAT, epoch) or nil
end

function ns.FormatDuration(seconds)
    if type(seconds) ~= "number" then
        return NA
    end
    seconds = floor(seconds)
    return format("%02d:%02d:%02d", floor(seconds / 3600), floor(seconds / 60) % 60, seconds % 60)
end

function ns.FormatCoords(x, y)
    if type(x) == "number" and type(y) == "number" then
        return format("%.2f / %.2f", x, y)
    end
    return NA
end

function ns.FormatLatency(home, world)
    if home == nil and world == nil then
        return NA
    end
    return format("%s / %s ms", home or "?", world or "?")
end

function ns.FormatReaction(reaction)
    if type(reaction) ~= "number" then
        return nil
    end
    return format("%s (%d)", REACTION_LABELS[reaction] or "?", reaction)
end

function ns.FormatLevel(level)
    if type(level) ~= "number" then
        return nil
    end
    return level < 0 and "??" or tostring(level)
end

-- "Guard Thomas (55 elite)"
function ns.FormatTargetName(target)
    if type(target) ~= "table" or not target.exists then
        return "None"
    end
    local details = {}
    details[#details + 1] = ns.FormatLevel(target.level)
    if target.classification and target.classification ~= "normal" then
        details[#details + 1] = target.classification
    end
    local name = target.name or "Unknown"
    if #details > 0 then
        return format("%s (%s)", name, concat(details, " "))
    end
    return name
end

-- NPC ID / Object ID / "Player" for the target of a snapshot or the live HUD.
function ns.FormatTargetId(target)
    if type(target) ~= "table" or not target.exists then
        return NA
    end
    if target.npcId then
        return tostring(target.npcId)
    elseif target.objectId then
        return "object " .. target.objectId
    elseif target.guidType then
        return target.guidType
    end
    return NA
end

function ns.FormatZone(location)
    if type(location) ~= "table" then
        return NA
    end
    if location.subZone and location.subZone ~= location.zone then
        return format("%s / %s", location.zone or "?", location.subZone)
    end
    return Display(location.zone)
end

function ns.FormatRow(label, value, useColor)
    if useColor then
        return Colorize(ns.COLOR_LABEL, label .. ":") .. " " .. value
    end
    return label .. ": " .. value
end

-- Text-first (not colour-only) report state: "REPORTED" / "LOCAL".
function ns.ReportTag(incident, useColor)
    if ns.IsReported(incident) then
        return useColor and Colorize(ns.REPORT_COLORS.reported, "REPORTED") or "REPORTED"
    end
    return useColor and Colorize(ns.REPORT_COLORS["local"], "LOCAL") or "LOCAL"
end

function ns.FormatReportStatus(incident, useColor)
    local text = ns.IsReported(incident) and "Reported to Blizzard" or "Local only (not reported)"
    if useColor then
        return Colorize(ns.IsReported(incident) and ns.REPORT_COLORS.reported or ns.REPORT_COLORS["local"], text)
    end
    return text
end

function ns.FormatReportHistoryEntry(entry)
    local action = entry.status == "reported" and "marked reported" or entry.status == "local" and "marked not reported"
        or ("status " .. Display(Scalar(entry.status)))
    local method = Scalar(entry.method)
    return format("%s %s%s", ns.FormatDateTime(entry.at) or NA, action, method and (" (" .. method .. ")") or "")
end

function ns.FormatSeverity(severity, useColor)
    local text = Display(severity)
    local color = ns.SEVERITY_COLORS[severity]
    if useColor and color then
        return Colorize(color, text)
    end
    return text
end

-- "09:41:21 (-1.2s) PLAYER_TARGET_CHANGED  Guard Thomas (NPC 1423) (x3)"
function ns.FormatEventLine(entry, useColor, showOffset)
    local line = ns.FormatClock(entry.time)
    if showOffset and type(entry.offset) == "number" then
        line = line .. format(" (%+.1fs)", entry.offset)
    end
    local name = tostring(Scalar(entry.event) or "?")
    if useColor then
        name = Colorize(ns.CATEGORY_COLORS[entry.category] or "ffffff", name)
    end
    line = line .. " " .. name
    if Scalar(entry.info) ~= nil then
        line = line .. "  " .. tostring(entry.info)
    end
    if type(entry.count) == "number" and entry.count > 1 then
        line = line .. format(" (x%d)", entry.count)
    end
    return line
end

-- One-line history subtitle: date, zone, build (build highlighted if it differs from the running client).
function ns.FormatIncidentMeta(incident, useColor)
    local parts = {}
    parts[#parts + 1] = type(incident.createdAtText) == "string" and incident.createdAtText or "unknown date"
    local zone = ns.IncidentZone(incident)
    if zone then
        parts[#parts + 1] = tostring(zone)
    end
    local build = ns.FormatBuild(Sub(incident, "client"))
    if build then
        if useColor and build ~= ns.CURRENT_BUILD then
            build = Colorize(ns.COLOR_WARNING, build)
        end
        parts[#parts + 1] = build
    end
    return concat(parts, useColor and "  ·  " or " - ")
end

-- Short frozen-context summary shown in the NEW INCIDENT form.
function ns.FormatContextSummary(snapshot, useColor)
    local location, target = Sub(snapshot, "location"), Sub(snapshot, "target")
    local player, performance = Sub(snapshot, "player"), Sub(snapshot, "performance")
    local lines = {
        ns.FormatRow("Time", Display(snapshot.createdAtText), useColor),
        ns.FormatRow("Build", Display(ns.FormatBuild(Sub(snapshot, "client"))), useColor),
        ns.FormatRow("Zone", ns.FormatZone(location), useColor),
        ns.FormatRow("Map", format("%s   Pos %s", Display(location.mapID), ns.FormatCoords(location.x, location.y)), useColor),
        ns.FormatRow("Target", format("%s   ID %s", ns.FormatTargetName(target), ns.FormatTargetId(target)), useColor),
        ns.FormatRow("State", format("Combat %s   FPS %s   Ping %s", Display(player.combat), Display(performance.fps),
            ns.FormatLatency(performance.homeLatency, performance.worldLatency)), useColor),
    }
    return concat(lines, "\n")
end

local function MatchesType(expected, value)
    local actual = type(value)
    if expected == "scalar" then
        return actual == "string" or actual == "number"
    end
    return actual == expected
end

-- Copy of one snapshot block holding only fields of the expected type.
local function TypedSection(incident, section)
    local source = incident[section]
    if type(source) ~= "table" then
        return EMPTY
    end
    local spec, view = SECTION_FIELDS[section], {}
    for key, expected in pairs(spec) do
        if MatchesType(expected, source[key]) then
            view[key] = source[key]
        end
    end
    return view
end

-- Numbers first (numerically), then everything else by text.
local function KeyOrder(a, b)
    local numberA, numberB = type(a) == "number", type(b) == "number"
    if numberA and numberB then
        return a < b
    elseif numberA ~= numberB then
        return numberA
    end
    return tostring(a) < tostring(b)
end

local function SortedKeys(tbl)
    local keys = {}
    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end
    sort(keys, KeyOrder)
    return keys
end

local function FlattenValue(rows, label, value, depth)
    if type(value) ~= "table" then
        rows[#rows + 1] = { label, Display(value) }
        return
    end
    if depth >= OTHER_FIELDS_MAX_DEPTH then
        rows[#rows + 1] = { label, "{...}" }
        return
    end
    local keys = SortedKeys(value)
    if #keys == 0 then
        rows[#rows + 1] = { label, "{}" }
        return
    end
    for _, key in ipairs(keys) do
        FlattenValue(rows, label .. "." .. tostring(key), value[key], depth + 1)
    end
end

-- Flattens every key of `block` that is not in `spec` or has another type.
local function AppendLeftovers(rows, label, block, spec, depth)
    for _, key in ipairs(SortedKeys(block)) do
        local value = block[key]
        if not (spec[key] and MatchesType(spec[key], value)) then
            FlattenValue(rows, label .. "." .. tostring(key), value, depth)
        end
    end
end

local function ListLength(list)
    local length = 0
    for index in ipairs(list) do
        length = index
    end
    return length
end

-- For list-shaped fields (recentEvents, addOns): flattens non-list keys and list
-- entries that the rendered rows cannot show; `entrySpec` checks table entries.
local function AppendListLeftovers(rows, label, list, isShown, entrySpec, depth)
    local length = ListLength(list)
    for _, key in ipairs(SortedKeys(list)) do
        local value = list[key]
        local inList = type(key) == "number" and key >= 1 and key <= length and key % 1 == 0
        if not inList then
            FlattenValue(rows, label .. "." .. tostring(key), value, depth)
        elseif type(value) == "table" and entrySpec then
            AppendLeftovers(rows, format("%s[%d]", label, key), value, entrySpec, depth + 1)
        elseif not isShown(value) then
            FlattenValue(rows, format("%s[%d]", label, key), value, depth + 1)
        end
    end
end

local function PairText(first, second, pattern)
    if type(first) == "number" and type(second) == "number" then
        return format(pattern, first, second)
    elseif first ~= nil or second ~= nil then
        return Display(first) .. " / " .. Display(second)
    end
    return nil
end

-- Structured, ordered description of an incident (or an unsaved snapshot).
-- Rows are either { label, value } pairs or plain strings.
-- This is the single source for both the detail window and the export text.
function ns.DescribeIncident(incident, useColor)
    local sections = {}
    local function Section(title)
        local rows = {}
        sections[#sections + 1] = { title = title, rows = rows }
        return rows
    end
    local function Row(rows, label, value)
        rows[#rows + 1] = { label, Display(value) }
    end

    local client, character = TypedSection(incident, "client"), TypedSection(incident, "character")
    local location, player = TypedSection(incident, "location"), TypedSection(incident, "player")
    local target, performance = TypedSection(incident, "target"), TypedSection(incident, "performance")
    local metadata = TypedSection(incident, "metadata")

    local report = TypedSection(incident, "report")
    local reportHistory = Sub(report, "history")
    if incident.id then
        Section("Title")[1] = Display(incident.title)
        local summary = Section(nil)
        Row(summary, "Incident", format("%s (ref %s)", ns.FormatId(incident.id), ns.ReportRef(incident)))
        summary[#summary + 1] = { "Severity", ns.FormatSeverity(type(incident.severity) == "string" and incident.severity or nil, useColor) }
        Row(summary, "Created", type(incident.createdAtText) == "string" and incident.createdAtText or ns.FormatDateTime(incident.createdAt))
        summary[#summary + 1] = { "Report status", ns.FormatReportStatus(incident, useColor) }
        if report.status == REPORT_REPORTED or report.reportedAt then
            Row(summary, "Reported at", ns.FormatDateTime(report.reportedAt))
        end
        if report.method ~= nil then
            Row(summary, "Report method", ns.REPORT_METHOD_LABELS[report.method] or report.method)
        end
        if report.provider ~= nil and report.provider ~= "blizzard" then
            Row(summary, "Report provider", report.provider)
        end
        if report.legacyStatus ~= nil then
            Row(summary, "Previous report status", report.legacyStatus)
        end
        local notes = Section("Notes")
        notes[1] = (type(incident.notes) == "string" and incident.notes ~= "") and incident.notes or "(none)"
        if ListLength(reportHistory) > 0 then
            local historyRows = Section("Report history")
            for _, entry in ipairs(reportHistory) do
                historyRows[#historyRows + 1] = type(entry) == "table" and ns.FormatReportHistoryEntry(entry) or Display(entry)
            end
        end
    else
        Row(Section(nil), "Captured", type(incident.createdAtText) == "string" and incident.createdAtText or nil)
    end

    local rows = Section("Client")
    Row(rows, "Version", client.version)
    Row(rows, "Build", client.build)
    Row(rows, "Build date", client.buildDate)
    Row(rows, "TOC", client.tocVersion)
    Row(rows, "Locale", client.locale)

    -- Every typed field below is shown whenever it is present, even if a
    -- related field is missing; nothing stored may be hidden.
    rows = Section("Character")
    Row(rows, "Name", (character.name or character.realm)
        and (tostring(character.name or "?") .. (character.realm and ("-" .. character.realm) or "")) or nil)
    Row(rows, "Level", ns.FormatLevel(character.level))
    Row(rows, "Race", character.race)
    Row(rows, "Class", character.classToken and format("%s (%s)", character.class or "?", character.classToken) or character.class)
    Row(rows, "Faction", character.faction)

    rows = Section("Location")
    Row(rows, "Zone", location.zone)
    Row(rows, "Subzone", location.subZone)
    Row(rows, "Map", (location.mapID or location.mapName)
        and format("%s (%s)", Display(location.mapID), location.mapName or "?") or nil)
    Row(rows, "Position", PairText(location.x, location.y, "%.2f / %.2f"))
    local instance = location.instanceType or location.instanceName or location.difficulty
    if instance then
        instance = format("%s%s%s", location.instanceName and (location.instanceName .. " - ") or "",
            Display(location.instanceType), location.difficulty and (", " .. location.difficulty) or "")
    end
    Row(rows, "Instance", instance)
    Row(rows, "Instance ID", location.instanceMapID)
    Row(rows, "World", PairText(location.worldX, location.worldY, "%.1f, %.1f"))

    rows = Section("Player")
    Row(rows, "Combat", player.combat)
    Row(rows, "Combat lockdown", player.combatLockdown)
    Row(rows, "Mounted", player.mounted)
    Row(rows, "Dead or ghost", player.deadOrGhost)
    Row(rows, "Swimming", player.swimming)
    Row(rows, "Resting", player.resting)

    rows = Section("Target")
    local hasTargetData = false
    for key in pairs(target) do
        if key ~= "exists" then
            hasTargetData = true
        end
    end
    if target.exists or hasTargetData then
        if target.exists == false then
            Row(rows, "Exists", false) -- legacy data: target fields stored without a target
        end
        Row(rows, "Name", target.name)
        Row(rows, "Level", ns.FormatLevel(target.level))
        Row(rows, "Classification", target.classification)
        local kind = target.guidType
        if target.isPlayer == true then
            kind = (kind and kind ~= "Player") and ("Player / " .. kind) or "Player"
        elseif target.isPlayer == false and not kind then
            kind = "Not a player" -- GUID restricted (secret): the only hint left
        end
        Row(rows, "Kind", kind)
        Row(rows, "Reaction", ns.FormatReaction(target.reaction))
        Row(rows, "Creature type", target.creatureType)
        Row(rows, "Dead", target.dead)
        Row(rows, "GUID", target.guid)
        if target.objectId then
            Row(rows, "Object ID", target.objectId)
        end
        if target.npcId or not target.objectId then
            Row(rows, "NPC ID", target.npcId)
        end
    else
        rows[1] = target.exists == false and "No target" or NA
    end

    rows = Section("Performance")
    Row(rows, "FPS", performance.fps)
    if performance.fpsMin or performance.fpsAvg or performance.fpsWindow then
        Row(rows, "FPS window", format("min %s / avg %s (last %ss)", Display(performance.fpsMin),
            Display(performance.fpsAvg), Display(performance.fpsWindow)))
    end
    Row(rows, "Home latency", performance.homeLatency and (performance.homeLatency .. " ms") or nil)
    Row(rows, "World latency", performance.worldLatency and (performance.worldLatency .. " ms") or nil)
    Row(rows, "Lua memory", performance.luaMemoryKB and format("%.1f MB", performance.luaMemoryKB / 1024) or nil)

    rows = Section("Session")
    Row(rows, "Session ID", metadata.sessionId)
    Row(rows, "Session uptime", metadata.sessionUptime and ns.FormatDuration(metadata.sessionUptime) or nil)
    Row(rows, "Server time", ns.FormatDateTime(metadata.serverTime))
    Row(rows, "OnionDebug", (metadata.addonVersion or metadata.schemaVersion)
        and format("%s (schema %s)", Display(metadata.addonVersion), Display(metadata.schemaVersion)) or nil)
    local addOnList, addOns = Sub(metadata, "addOns"), {}
    for _, name in ipairs(addOnList) do
        if Scalar(name) ~= nil then
            addOns[#addOns + 1] = tostring(name)
        end
    end
    Row(rows, "AddOns", format("%d loaded%s", #addOns, #addOns > 0 and (": " .. concat(addOns, ", ")) or ""))
    if metadata.restrictedValues then
        Row(rows, "Restricted values", format("%d value(s) were secret at capture time", metadata.restrictedValues))
    end
    if metadata.migratedFromSchema then
        Row(rows, "Migrated from schema", metadata.migratedFromSchema)
    end
    if metadata.originalId ~= nil then
        local original = type(metadata.originalId) == "number" and ns.FormatId(metadata.originalId) or tostring(metadata.originalId)
        Row(rows, "Original ID", original .. " (renumbered: duplicate or invalid ID)")
    end

    rows = Section("Last event")
    local lastEvent = incident.lastEvent
    rows[1] = type(lastEvent) == "table" and ns.FormatEventLine(lastEvent, useColor, true) or "(none)"

    local recentEvents = Sub(incident, "recentEvents")
    rows = Section(format("Recent events (%d, newest first)", ListLength(recentEvents)))
    for _, entry in ipairs(recentEvents) do
        rows[#rows + 1] = type(entry) == "table" and ns.FormatEventLine(entry, useColor, true) or Display(entry)
    end
    if #rows == 0 then
        rows[1] = "(none)"
    end

    -- Everything stored that the rows above cannot show (unknown keys, wrong
    -- types, legacy data) is listed here and exported, so nothing is hidden.
    local other = {}
    for _, key in ipairs(SortedKeys(incident)) do
        if KNOWN_INCIDENT_FIELDS[key] ~= type(incident[key]) then
            FlattenValue(other, tostring(key), incident[key], 1)
        end
    end
    for _, section in ipairs(SECTION_ORDER) do
        if type(incident[section]) == "table" then
            AppendLeftovers(other, section, incident[section], SECTION_FIELDS[section], 2)
        end
    end
    AppendListLeftovers(other, "metadata.addOns", addOnList, function(value) return Scalar(value) ~= nil end, nil, 3)
    if type(lastEvent) == "table" then
        AppendLeftovers(other, "lastEvent", lastEvent, EVENT_FIELDS, 2)
    end
    AppendListLeftovers(other, "recentEvents", recentEvents, function() return true end, EVENT_FIELDS, 2)
    AppendListLeftovers(other, "report.history", reportHistory, function() return true end, REPORT_HISTORY_FIELDS, 3)
    if #other > 0 then
        rows = Section("Other fields")
        for index, row in ipairs(other) do
            rows[index] = row
        end
    end

    return sections
end

function ns.FormatIncidentText(incident)
    local lines = {}
    if incident.id then
        lines[1] = format("=== Onion Debug Incident %s ===", ns.FormatId(incident.id))
    else
        lines[1] = "=== Onion Debug Context Snapshot ==="
    end
    for _, section in ipairs(ns.DescribeIncident(incident, false)) do
        lines[#lines + 1] = ""
        if section.title then
            lines[#lines + 1] = section.title .. ":"
        end
        for _, row in ipairs(section.rows) do
            lines[#lines + 1] = type(row) == "string" and row or ns.FormatRow(row[1], row[2], false)
        end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== End ==="
    return concat(lines, "\n")
end

function ns.FormatIncidentsText(incidents)
    local parts = {
        format("=== Onion Debug Export: %d incident(s) - %s - OnionDebug %s ===",
            #incidents, date(DATE_FORMAT), ns.VERSION),
    }
    for _, incident in ipairs(incidents) do
        parts[#parts + 1] = ns.FormatIncidentText(incident)
    end
    return concat(parts, "\n\n")
end

------------------------------------------------------------------------
-- Blizzard report text
-- What gets pasted into the Issue Reporter's description box. That box is an
-- EditBox limited to 255 letters (AttachStandaloneQuestion default in
-- Blizzard_PTRFeedback) and the reporter turns commas into spaces, so the text
-- is compact, comma-free and starts with the incident reference (which is what
-- submission detection looks for). The reporter already attaches character
-- level/race/class/faction and map ID itself, so those are not repeated.
-- Privacy: no character name/realm, other players' names, GUIDs, addon list
-- or session data here; the full export keeps everything locally.
------------------------------------------------------------------------

ns.REPORT_MAX_LETTERS = 255
local REPORT_TITLE_MAX_LETTERS = 90
local REPORT_NOTES_MIN_LETTERS = 80 -- optional context lines are dropped before notes shrink below this
local REPORT_EVENT_INFO_MAX_LETTERS = 60
local REPORT_USEFUL_CATEGORIES = { error = true, lua = true, taint = true }
local REPORT_NOISE_EVENTS = {
    PLAYER_LOGIN = true, PLAYER_ENTERING_WORLD = true, PLAYER_LEAVING_WORLD = true,
    BAG_UPDATE_DELAYED = true, QUEST_LOG_UPDATE = true,
}

local function ReportSafe(text)
    return (tostring(text):gsub(",", ";"):gsub("[\r\n]+", " "))
end

-- Most useful recent event: newest error/Lua/taint event, else newest non-noise event.
local function ReportEvent(incident)
    local fallback
    local candidates = Sub(incident, "recentEvents")
    if ListLength(candidates) == 0 and type(incident.lastEvent) == "table" then
        candidates = { incident.lastEvent }
    end
    for _, entry in ipairs(candidates) do
        local event = type(entry) == "table" and Scalar(entry.event)
        if event then
            if REPORT_USEFUL_CATEGORIES[entry.category] then
                return entry
            end
            if not fallback and not REPORT_NOISE_EVENTS[event] then
                fallback = entry
            end
        end
    end
    return fallback
end

local function ReportContextLines(incident)
    local location, target = TypedSection(incident, "location"), TypedSection(incident, "target")
    local performance = TypedSection(incident, "performance")
    local lines = {}

    local where = {}
    where[#where + 1] = ns.FormatBuild(TypedSection(incident, "client"))
    if location.zone or location.subZone then
        where[#where + 1] = ns.FormatZone(location)
    end
    if location.instanceName then
        where[#where + 1] = format("%s (%s)", location.instanceName, Display(location.difficulty))
    end
    if location.x and location.y then
        where[#where + 1] = format("at %.2f %.2f", location.x, location.y) -- the reporter adds the map ID itself
    end
    if #where > 0 then
        lines[#lines + 1] = concat(where, "; ")
    end

    if target.exists or target.name or target.npcId or target.objectId then
        local who
        if target.isPlayer then
            who = "a player" -- other players' names stay local
        elseif target.npcId then
            who = format("%s (NPC %s)", Display(target.name), target.npcId)
        elseif target.objectId then
            who = format("%s (object %s)", Display(target.name), target.objectId)
        else
            who = Display(target.name)
        end
        lines[#lines + 1] = "Target: " .. who
    end

    local entry = ReportEvent(incident)
    if entry then
        local info = Scalar(entry.info)
        lines[#lines + 1] = format("Event: %s%s%s%s", entry.event,
            info and (" " .. TruncateLetters(tostring(info), REPORT_EVENT_INFO_MAX_LETTERS)) or "",
            (type(entry.count) == "number" and entry.count > 1) and format(" x%d", entry.count) or "",
            type(entry.offset) == "number" and format(" %+.1fs", entry.offset) or "")
    end

    local perf = {}
    if performance.fps then
        perf[#perf + 1] = format("FPS %s%s", performance.fps,
            performance.fpsMin and (" (min " .. performance.fpsMin .. ")") or "")
    end
    if performance.homeLatency or performance.worldLatency then
        perf[#perf + 1] = format("ping %s/%sms", Display(performance.homeLatency), Display(performance.worldLatency))
    end
    if #perf > 0 then
        lines[#lines + 1] = concat(perf, "; ")
    end

    for index, line in ipairs(lines) do
        lines[index] = ReportSafe(line)
    end
    return lines
end

-- Returns the report text and its letter count (always <= REPORT_MAX_LETTERS).
function ns.FormatBlizzardReport(incident)
    local budget = ns.REPORT_MAX_LETTERS
    local severity = SEVERITY_SET[incident.severity] and incident.severity ~= ns.DEFAULT_SEVERITY and incident.severity
    local title = ReportSafe(TruncateLetters(ns.Trim(Scalar(incident.title) or "Untitled incident"), REPORT_TITLE_MAX_LETTERS))
    local head = format("[%s]%s %s", ns.ReportRef(incident), severity and ("[" .. severity .. "]") or "", title)
    local notes = ns.Trim(Scalar(incident.notes) or ""):gsub(",", ";")
    local context = ReportContextLines(incident)

    local function Length(lines)
        local total = LetterCount(head)
        for _, line in ipairs(lines) do
            total = total + 1 + LetterCount(line) -- newline + line
        end
        return total
    end

    -- Drop the least important context lines while they squeeze the notes too much.
    local room = budget - Length(context) - 1
    while #context > 0 and notes ~= "" and LetterCount(notes) > room and room < REPORT_NOTES_MIN_LETTERS + 3 do -- + "..."
        context[#context] = nil
        room = budget - Length(context) - 1
    end

    local lines = { head }
    if notes ~= "" and room > 3 then
        lines[#lines + 1] = TruncateLetters(notes, room)
    end
    for _, line in ipairs(context) do
        lines[#lines + 1] = line
    end
    local text = concat(lines, "\n")
    if LetterCount(text) > budget then
        text = TruncateLetters(text, budget) -- the reference stays: it comes first
    end
    return text, LetterCount(text)
end

------------------------------------------------------------------------
-- Settings
------------------------------------------------------------------------

local function ValidateSettingValue(spec, value)
    if spec.type == "boolean" then
        if type(value) == "boolean" then
            return value
        end
        return spec.default
    end
    value = tonumber(value)
    if not value then
        return spec.default
    end
    return max(spec.min, min(spec.max, floor(value)))
end

local SETTING_APPLIERS = {
    maxEvents = function(value) ResizeEventBuffer(value) end,
    captureEvents = function() UpdateEventRegistration() end,
    captureLuaErrors = function(value)
        if value then
            InstallLuaErrorCapture()
        end
    end,
    hudVisible = function() NotifyUI("layout") end,
    hudMinimized = function() NotifyUI("layout") end,
}

local BOOLEAN_WORDS = {
    ["on"] = true, ["true"] = true, ["yes"] = true, ["1"] = true, ["enable"] = true,
    ["off"] = false, ["false"] = false, ["no"] = false, ["0"] = false, ["disable"] = false,
}

-- Accepts typed values (from the UI) or strings (from /od set).
-- Returns true, value or false, errorMessage.
function ns.SetSetting(key, value)
    local spec = type(key) == "string" and SETTINGS_BY_KEY[key:lower()]
    if not spec then
        return false, format("Unknown setting '%s'. Type /od config to list settings.", tostring(key))
    end
    if spec.type == "boolean" then
        if type(value) == "string" then
            value = BOOLEAN_WORDS[value:lower()]
        end
        if type(value) ~= "boolean" then
            return false, format("%s expects on or off.", spec.key)
        end
    else
        local number = tonumber(value)
        if not number or number ~= floor(number) or number < spec.min or number > spec.max then
            return false, format("%s must be a whole number between %d and %d.", spec.key, spec.min, spec.max)
        end
        value = number
    end
    ns.db.settings[spec.key] = value
    local apply = SETTING_APPLIERS[spec.key]
    if apply then
        apply(value)
    end
    return true, value
end

------------------------------------------------------------------------
-- SavedVariables: initialize, migrate, validate
------------------------------------------------------------------------

-- Accepts the current { point, relativePoint, x, y } form and plausible legacy shapes.
function ns.NormalizePosition(position)
    if type(position) ~= "table" then
        return nil
    end
    local point = position.point or position[1]
    local relativePoint = position.relativePoint or position.relPoint
    if relativePoint == nil then
        relativePoint = (type(position[3]) == "string" and position[3]) or (type(position[2]) == "string" and position[2]) or point
    end
    local x, y = position.x or position.xOfs, position.y or position.yOfs
    if x == nil and y == nil then
        if point == nil and type(position.left) == "number" and type(position.top) == "number" then
            point, relativePoint, x, y = "TOPLEFT", "BOTTOMLEFT", position.left, position.top
        else
            local numbers = {}
            for index = 1, 5 do
                if type(position[index]) == "number" then
                    numbers[#numbers + 1] = position[index]
                end
            end
            x, y = numbers[1], numbers[2]
        end
    end
    if VALID_POINTS[point] and VALID_POINTS[relativePoint] and type(x) == "number" and type(y) == "number" then
        return { point = point, relativePoint = relativePoint, x = x, y = y }
    end
    return nil
end

local function NormalizeSettings(db)
    if type(db.settings) ~= "table" then
        db.settings = {}
    end
    local settings = db.settings
    for _, spec in ipairs(SETTINGS) do
        settings[spec.key] = ValidateSettingValue(spec, settings[spec.key])
    end
end

-- Stores a value that has to make room without losing it: key, key2, key3...
local function PreserveValue(tbl, key, value)
    local slot, suffix = key, 1
    while tbl[slot] ~= nil do
        suffix = suffix + 1
        slot = key .. suffix
    end
    tbl[slot] = value
end

-- Every incident carries report metadata (schema 3). Missing -> "local";
-- anything unusable is preserved (legacyReport / report.legacyStatus), never dropped.
local function NormalizeReport(incident)
    local report = incident.report
    if type(report) ~= "table" then
        if report ~= nil then
            PreserveValue(incident, "legacyReport", report)
        end
        incident.report = ns.NewReportState()
    else
        if report.status ~= REPORT_LOCAL and report.status ~= REPORT_REPORTED then
            if report.status ~= nil then
                PreserveValue(report, "legacyStatus", report.status)
            end
            report.status = REPORT_LOCAL
        end
        if report.history ~= nil and type(report.history) ~= "table" then
            PreserveValue(report, "legacyHistory", report.history)
            report.history = nil
        end
    end
end

local function NormalizeIncident(incident)
    NormalizeReport(incident)
    if type(incident.title) ~= "string" or ns.Trim(incident.title) == "" then
        local fallback = incident.name or incident.summary
        incident.title = (type(fallback) == "string" and ns.Trim(fallback) ~= "") and fallback or "Untitled incident"
    end
    if type(incident.createdAt) ~= "number" then
        local epoch = tonumber(incident.timestamp) or tonumber(incident.time)
        if epoch and epoch > 1e9 then
            incident.createdAt = epoch
        end
    end
    if type(incident.createdAtText) ~= "string" then
        if type(incident.createdAt) == "number" then
            incident.createdAtText = date(DATE_FORMAT, incident.createdAt)
        elseif type(incident.date) == "string" then
            incident.createdAtText = incident.date
        end
    end
end

local function IncidentOrder(a, b)
    local idA, idB = PositiveInteger(a.id), PositiveInteger(b.id)
    if idA and idB then
        if idA ~= idB then
            return idA < idB
        end
    elseif idA or idB then
        return idA ~= nil -- incidents with an id first
    end
    local timeA, timeB = tonumber(a.createdAt) or 0, tonumber(b.createdAt) or 0
    if timeA ~= timeB then
        return timeA < timeB
    end
    return tostring(a.title) < tostring(b.title)
end

-- Keeps a replaced legacy id visible: metadata.originalId, or a top-level
-- legacyId (listed under "Other fields") when metadata is not a table.
local function RememberOriginalId(incident, rawId)
    if rawId == nil then
        return
    end
    if incident.metadata == nil then
        incident.metadata = {}
    end
    if type(incident.metadata) == "table" then
        if incident.metadata.originalId == nil then
            incident.metadata.originalId = rawId
        end
    elseif incident.legacyId == nil then
        incident.legacyId = rawId
    end
end

-- Rebuilds db.incidents as a clean ascending array with unique ids.
-- Never drops data: non-table entries are moved to db.quarantine, and
-- incidents with a missing, invalid or duplicate id get a fresh id (in
-- chronological order) while the old value is kept via RememberOriginalId.
-- Returns the number of entries quarantined.
local function NormalizeIncidentList(db)
    local list, quarantined = {}, 0
    if type(db.incidents) == "table" then
        for key, incident in pairs(db.incidents) do
            if type(incident) == "table" then
                NormalizeIncident(incident) -- derives createdAt before sorting
                list[#list + 1] = incident
            else
                db.quarantine = type(db.quarantine) == "table" and db.quarantine or {}
                db.quarantine[#db.quarantine + 1] = { reason = "incident entry is not a table", key = key, value = incident }
                quarantined = quarantined + 1
            end
        end
    elseif db.incidents ~= nil then
        db.quarantine = type(db.quarantine) == "table" and db.quarantine or {}
        db.quarantine[#db.quarantine + 1] = { reason = "incidents was not a table", value = db.incidents }
        quarantined = quarantined + 1
    end

    sort(list, IncidentOrder)

    local seen, maxId, pending = {}, 0, {}
    for _, incident in ipairs(list) do
        local rawId = incident.id
        local id = PositiveInteger(rawId)
        if id and seen[id] then
            id = nil -- duplicate: the older incident (sorted first) keeps it
        end
        if id then
            seen[id] = true
            incident.id = id
            maxId = max(maxId, id)
        else
            RememberOriginalId(incident, rawId)
            pending[#pending + 1] = incident
        end
    end

    -- new ids follow creation time, so "last" and newest-first stay chronological
    sort(pending, function(a, b)
        local timeA, timeB = tonumber(a.createdAt) or 0, tonumber(b.createdAt) or 0
        if timeA ~= timeB then
            return timeA < timeB
        end
        return tostring(a.title) < tostring(b.title)
    end)
    local nextId = max(PositiveInteger(db.nextIncidentId) or 1, maxId + 1)
    for _, incident in ipairs(pending) do
        incident.id = nextId
        nextId = nextId + 1
    end
    if #pending > 0 then
        sort(list, IncidentOrder)
    end

    db.incidents = list
    db.nextIncidentId = nextId
    return quarantined
end

-- Schema 1 (first OnionDebug release): incidents, nextIncidentId and the HUD
-- anchor in db.position; no schemaVersion. Incident contents are kept as-is.
local function MigrateV1ToV2(db)
    db.ui = type(db.ui) == "table" and db.ui or {}
    local position = ns.NormalizePosition(db.position)
    if position then
        db.ui.hud = db.ui.hud or position
        db.position = nil
    end
    db.settings = type(db.settings) == "table" and db.settings or {}
    for _, spec in ipairs(SETTINGS) do
        if db[spec.key] ~= nil and db.settings[spec.key] == nil then
            db.settings[spec.key] = db[spec.key]
            db[spec.key] = nil
        end
    end
    if type(db.incidents) == "table" then
        for _, incident in pairs(db.incidents) do
            if type(incident) == "table" then
                if incident.metadata == nil then
                    incident.metadata = {}
                end
                if type(incident.metadata) == "table" then
                    incident.metadata.migratedFromSchema = 1
                end
            end
        end
    end
end

-- Schema 3 adds incident.report (report tracking). The default state is applied
-- by NormalizeReport, which ValidateDatabase runs for every incident on every
-- load, so this step has nothing else to change and is trivially idempotent.
local function MigrateV2ToV3()
end

local MIGRATIONS = {
    [1] = MigrateV1ToV2,
    [2] = MigrateV2ToV3,
}

-- Returns the schema version the data was migrated from, or nil.
-- Newer schemas never reach this function (see InitializeDatabase).
local function MigrateDatabase(db)
    local version = PositiveInteger(db.schemaVersion) or 1
    local from = version
    while version < SCHEMA_VERSION do
        MIGRATIONS[version](db)
        version = version + 1
    end
    db.schemaVersion = version
    return from < version and from or nil
end

local function ValidateDatabase(db)
    NormalizeSettings(db)
    if type(db.ui) ~= "table" then
        db.ui = {}
    end
    if db.session ~= nil and (type(db.session) ~= "table" or type(db.session.id) ~= "string" or type(db.session.startedAt) ~= "number") then
        db.session = nil
    end
    return NormalizeIncidentList(db)
end

local function InitializeDatabase()
    ns.startupWarnings = {}
    local stored = OnionDebugDB
    ns.dbLoadedFromDisk = stored ~= nil
    if type(stored) ~= "table" then
        OnionDebugDB = { schemaVersion = SCHEMA_VERSION, createdAt = time() }
        if stored ~= nil then
            OnionDebugDB.quarantine = { { reason = "database was not a table", value = stored } }
            ns.startupWarnings[#ns.startupWarnings + 1] = "Saved data was not a table; it was kept in OnionDebugDB.quarantine."
        end
    end
    local storedVersion = PositiveInteger(OnionDebugDB.schemaVersion)
    if storedVersion and storedVersion > SCHEMA_VERSION then
        -- Written by a newer OnionDebug: leave it byte-for-byte untouched and run
        -- this session on an in-memory database that is never saved.
        ns.readOnlyReason = format("Saved data belongs to a newer OnionDebug (schema %d, this version knows %d). "
            .. "Your data is untouched but nothing is saved this session - update the addon.", storedVersion, SCHEMA_VERSION)
        ns.db = { schemaVersion = SCHEMA_VERSION }
        ValidateDatabase(ns.db)
        return
    end
    local db = OnionDebugDB
    ns.db = db
    ns.migratedFrom = MigrateDatabase(db)
    local quarantined = ValidateDatabase(db)
    if quarantined > 0 then
        ns.startupWarnings[#ns.startupWarnings + 1] = format(
            "%d invalid incident entr%s moved to OnionDebugDB.quarantine.", quarantined, quarantined == 1 and "y" or "ies")
    end
end

local function AnnounceDatabase()
    local count = #ns.db.incidents
    if ns.readOnlyReason then
        ns.Print(Colorize(ns.COLOR_WARNING, ns.readOnlyReason))
    elseif not ns.dbLoadedFromDisk then
        ns.Print(format("v%s loaded - new database created. Type /od help for commands.", ns.VERSION))
        ns.Print(Colorize(ns.COLOR_WARNING, "If you already had incidents, the client did not load SavedVariables: back up "
            .. "WTF\\Account\\<account>\\SavedVariables\\OnionDebug.lua (and .bak) before logging out, "
            .. "because the next save overwrites it."))
    else
        ns.Print(format("v%s loaded - %d incident%s stored, next ID %s. /od help", ns.VERSION, count,
            count == 1 and "" or "s", ns.FormatId(ns.db.nextIncidentId)))
    end
    if ns.migratedFrom then
        ns.Print(format("Saved data migrated from schema %d to %d (%d incident%s kept).",
            ns.migratedFrom, SCHEMA_VERSION, count, count == 1 and "" or "s"))
    end
    for _, warning in ipairs(ns.startupWarnings) do
        ns.Print(Colorize(ns.COLOR_WARNING, warning))
    end
end

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

local function ResolveIncident(argument, usage)
    argument = ns.Trim(argument)
    if argument == "" then
        return nil, "Usage: " .. usage
    end
    if argument:lower() == "last" then
        local latest = ns.GetLatestIncident()
        if latest then
            return latest
        end
        return nil, "No incidents recorded yet."
    end
    local id = PositiveInteger((argument:gsub("^#", "")))
    if not id then
        return nil, format("Invalid incident ID '%s'. Usage: %s", argument, usage)
    end
    local incident = ns.FindIncident(id)
    if not incident then
        return nil, format("Incident %s not found.", ns.FormatId(id))
    end
    return incident
end

local function NewestFirst(incidents)
    local list = {}
    for index = #incidents, 1, -1 do
        list[#list + 1] = incidents[index]
    end
    return list
end

local function PrintStatus()
    local db = ns.db
    local size, capacity, recorded = ns.GetEventStats()
    local client = ns.client
    ns.Print(format("OnionDebug %s - schema %d", ns.VERSION, db.schemaVersion))
    ns.Print(format("Client: %s (TOC %s, %s)", Display(ns.CURRENT_BUILD), Display(client.tocVersion), Display(client.locale)))
    ns.Print(format("Incidents: %d stored, next ID %s, %d this session%s", #db.incidents, ns.FormatId(db.nextIncidentId),
        ns.CountSessionIncidents(), ns.draft and ", draft pending" or ""))
    ns.Print(format("Session: %s, uptime %s", Display(ns.session and ns.session.id), ns.FormatDuration(ns.GetSessionUptime())))
    ns.Print(format("Events: %d/%d buffered, %d recorded, capture %s, chat echo %s", size, capacity, recorded,
        db.settings.captureEvents and "on" or "off", db.settings.printEventsToChat and "on" or "off"))
    if db.settings.captureEvents then
        local unavailable = trackerState.unavailable
        ns.Print(format("Tracking %d/%d events%s", trackerState.registered, #TRACKED_EVENTS,
            #unavailable > 0 and (" (unavailable: " .. concat(unavailable, ", ") .. ")") or ""))
    end
    ns.Print(format("Lua error capture: %s", ns.GetLuaCaptureState()))
    ns.Print(format("Blizzard Issue Reporter: %s; submission detection %s; %d incident%s not reported",
        BlizzardReporter.IsAvailable() and "available" or "not found",
        BlizzardReporter.CanDetectSubmission() and "active" or "unavailable",
        ns.CountUnreported(), ns.CountUnreported() == 1 and "" or "s"))
    ns.Print(format("SavedVariables: %s", ns.readOnlyReason and "newer schema on disk - read-only session, nothing is saved"
        or ns.dbLoadedFromDisk and "loaded from disk" or "new database this session"))
    if type(db.quarantine) == "table" and #db.quarantine > 0 then
        ns.Print(Colorize(ns.COLOR_WARNING, format("Quarantined entries: %d (OnionDebugDB.quarantine)", #db.quarantine)))
    end
end

local function PrintSettings()
    ns.Print("Settings (change with /od set <setting> <value>):")
    for _, spec in ipairs(SETTINGS) do
        local range = spec.type == "number" and format(" [%d-%d]", spec.min, spec.max) or " [on/off]"
        local value = ns.db.settings[spec.key]
        if type(value) == "boolean" then
            value = value and "on" or "off"
        end
        ns.Print(format("  %s = %s%s - %s", spec.key, tostring(value), range, spec.help))
    end
end

local COMMANDS
local function PrintHelp()
    ns.Print("Commands (/od or /onion):")
    for _, command in ipairs(COMMANDS) do
        ns.Print(format("  /od %s%s - %s", command.name, command.args and (" " .. command.args) or "", command.help))
    end
end

COMMANDS = {
    { name = "show", help = "Show the HUD", run = function() ns.SetSetting("hudVisible", true) end },
    { name = "hide", help = "Hide the HUD", run = function() ns.SetSetting("hudVisible", false) end },
    { name = "toggle", help = "Toggle the HUD (also /od alone)", run = function()
        ns.SetSetting("hudVisible", not ns.db.settings.hudVisible)
    end },
    { name = "mark", args = "[title]", help = "Capture the context now; with a title it is saved immediately", run = function(argument)
        if ns.Trim(argument) == "" then
            ns.UI.BeginIncident()
            return
        end
        local _, err = ns.QuickMark(argument)
        if err then
            ns.Print(err)
        end
    end },
    { name = "history", args = "[search]", help = "Open the incident history", run = function(argument)
        ns.UI.ShowHistory(ns.Trim(argument))
    end },
    { name = "incident", args = "<id|last>", help = "Show incident details", run = function(argument)
        local incident, err = ResolveIncident(argument, "/od incident <id|last>")
        if not incident then
            ns.Print(err)
            return
        end
        ns.UI.ShowDetail(incident.id)
    end },
    { name = "export", args = "<id|last|all>", help = "Open copyable export text", run = function(argument)
        if ns.Trim(argument):lower() == "all" then
            local incidents = ns.db.incidents
            if #incidents == 0 then
                ns.Print("No incidents to export.")
                return
            end
            ns.UI.ShowExport(ns.FormatIncidentsText(NewestFirst(incidents)), format("Export - all incidents (%d)", #incidents))
            return
        end
        local incident, err = ResolveIncident(argument, "/od export <id|last|all>")
        if not incident then
            ns.Print(err)
            return
        end
        ns.UI.ShowExport(ns.FormatIncidentText(incident), "Export - Incident " .. ns.FormatId(incident.id))
    end },
    { name = "delete", args = "<id|last>", help = "Delete an incident (asks for confirmation)", run = function(argument)
        local incident, err = ResolveIncident(argument, "/od delete <id|last>")
        if not incident then
            ns.Print(err)
            return
        end
        ns.UI.ConfirmDelete(incident.id)
    end },
    { name = "report", args = "<id|last>", help = "Prepare the Blizzard Issue Reporter text for an incident", run = function(argument)
        local incident, err = ResolveIncident(argument, "/od report <id|last>")
        if not incident then
            ns.Print(err)
            return
        end
        ns.UI.ShowReport(incident.id)
    end },
    { name = "reported", args = "<id|last>", help = "Mark an incident as reported to Blizzard", run = function(argument)
        local incident, err = ResolveIncident(argument, "/od reported <id|last>")
        if incident then
            local ok
            ok, err = ns.MarkReported(incident.id)
            if ok then
                err = format("Incident %s marked as reported.", ns.FormatId(incident.id))
            end
        end
        ns.Print(err)
    end },
    { name = "unreported", args = "<id|last>", help = "Undo a reported mark (history is kept)", run = function(argument)
        local incident, err = ResolveIncident(argument, "/od unreported <id|last>")
        if incident then
            local ok
            ok, err = ns.MarkNotReported(incident.id)
            if ok then
                err = format("Incident %s marked as not reported.", ns.FormatId(incident.id))
            end
        end
        ns.Print(err)
    end },
    { name = "status", help = "Print diagnostics", run = PrintStatus },
    { name = "clear-events", aliases = { "clearevents" }, help = "Empty the event buffer", run = function()
        ns.ClearEvents()
        ns.Print("Event buffer cleared.")
    end },
    { name = "reset", help = "Reset window positions and show the HUD", run = function()
        ns.UI.ResetLayout()
        ns.Print("Window positions reset.")
    end },
    { name = "config", aliases = { "settings" }, help = "List settings", run = PrintSettings },
    { name = "set", args = "<setting> <value>", help = "Change a setting", run = function(argument)
        local key, value = ns.Trim(argument):match("^(%S+)%s+(%S+)$")
        if not key then
            ns.Print("Usage: /od set <setting> <value>. Type /od config to list settings.")
            return
        end
        local ok, result = ns.SetSetting(key, value)
        if not ok then
            ns.Print(result)
            return
        end
        if type(result) == "boolean" then
            result = result and "on" or "off"
        end
        ns.Print(format("%s = %s", SETTINGS_BY_KEY[key:lower()].key, tostring(result)))
    end },
    { name = "version", help = "Print addon and client versions", run = function()
        ns.Print(format("OnionDebug %s (schema %d) - WoW %s, TOC %s, %s", ns.VERSION, SCHEMA_VERSION,
            Display(ns.CURRENT_BUILD), Display(ns.client.tocVersion), Display(ns.client.buildDate)))
    end },
    { name = "help", aliases = { "?" }, help = "Show this help", run = PrintHelp },
}

local COMMAND_LOOKUP = {}
for _, command in ipairs(COMMANDS) do
    COMMAND_LOOKUP[command.name] = command
    for _, alias in ipairs(command.aliases or {}) do
        COMMAND_LOOKUP[alias] = command
    end
end

local function HandleSlashCommand(message)
    if not ns.db then
        ns.Print("Still loading, try again in a moment.")
        return
    end
    local name, argument = (message or ""):match("^%s*(%S*)%s*(.-)%s*$")
    name = name:lower()
    if name == "" then
        name = "toggle"
    end
    local command = COMMAND_LOOKUP[name]
    if not command then
        ns.Print(format("Unknown command '%s'. Type /od help.", name))
        return
    end
    command.run(argument)
end

SLASH_ONIONDEBUG1 = "/od"
SLASH_ONIONDEBUG2 = "/onion"
SLASH_ONIONDEBUG3 = "/oniondebug"
SlashCmdList.ONIONDEBUG = HandleSlashCommand

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

local lifecycle = CreateFrame("Frame")
lifecycle:RegisterEvent("ADDON_LOADED")
lifecycle:RegisterEvent("PLAYER_LOGIN")
lifecycle:RegisterEvent("PLAYER_ENTERING_WORLD")

local function OnAddonLoaded()
    InitializeDatabase()
    local settings = ns.db.settings
    ResizeEventBuffer(settings.maxEvents)
    UpdateEventRegistration()
    if settings.captureLuaErrors then
        InstallLuaErrorCapture()
    end
    BlizzardReporter.InstallSubmitHook()
    lifecycle:SetScript("OnUpdate", OnPerformanceUpdate)
    AnnounceDatabase()
end

lifecycle:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            self:UnregisterEvent("ADDON_LOADED")
            OnAddonLoaded()
        end
    elseif event == "PLAYER_LOGIN" then
        if ns.UI and ns.UI.Initialize then
            ns.UI.Initialize()
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        if not ns.session and ns.db then
            ResolveSession(arg1)
            NotifyUI("session")
        end
    end
end)
