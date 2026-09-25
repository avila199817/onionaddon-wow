--[[
    Minimal World of Warcraft API mock for running OnionDebug outside the game
    (plain Lua 5.1, same language version as the client).

    It is intentionally strict: widgets only implement the methods OnionDebug
    is expected to use, and an unknown method raises an error, so typos or
    calls to non-existent widget APIs fail the tests instead of passing silently.
]]

local Mock = {}

Mock.state = {}
Mock.clock = { now = 1790000000, uptime = 1000 } -- survives reloads, like real time

------------------------------------------------------------------------
-- Widgets
------------------------------------------------------------------------

local Widget = {}

local function RunScript(self, name, ...)
    local handler = self.scripts[name]
    if handler then
        handler(self, ...)
    end
    for _, hook in ipairs(self.hooks[name] or {}) do
        hook(self, ...)
    end
end
Mock.RunScript = RunScript

local METHODS = {}

-- Region / Frame basics ----------------------------------------------------
function METHODS.SetSize(self, w, h) self.width, self.height = w, h end
function METHODS.SetWidth(self, w) local old = self.width; self.width = w; if old ~= w then RunScript(self, "OnSizeChanged", w, self.height) end end
function METHODS.SetHeight(self, h) self.height = h end
function METHODS.GetWidth(self) return self.width or 300 end -- anchored frames count as laid out
function METHODS.GetHeight(self) return self.height or 0 end
function METHODS.SetPoint(self, point, ...) self.points[#self.points + 1] = { point, ... } end
function METHODS.ClearAllPoints(self) self.points = {} end
function METHODS.SetAllPoints(self) self.points = { { "ALL" } } end
function METHODS.GetPoint(self) local p = self.points[1]; if p then return unpack(p) end end
function METHODS.GetLeft(self) return 100 end
function METHODS.GetTop(self) return 700 end
function METHODS.SetFrameStrata(self, strata) self.strata = strata end
function METHODS.SetToplevel(self) end
function METHODS.Raise(self) end
function METHODS.Show(self) if not self.shown then self.shown = true; RunScript(self, "OnShow") end end
function METHODS.Hide(self) if self.shown then self.shown = false; RunScript(self, "OnHide") end end
function METHODS.IsShown(self) return self.shown end
function METHODS.SetShown(self, shown) if shown then self:Show() else self:Hide() end end
function METHODS.SetScript(self, name, fn) self.scripts[name] = fn end
function METHODS.GetScript(self, name) return self.scripts[name] end
function METHODS.HookScript(self, name, fn) self.hooks[name] = self.hooks[name] or {}; table.insert(self.hooks[name], fn) end
function METHODS.SetClampedToScreen(self) end
function METHODS.SetMovable(self) end
function METHODS.EnableMouse(self) end
function METHODS.EnableMouseWheel(self) end
function METHODS.RegisterForDrag(self) end
function METHODS.SetDontSavePosition(self) end
function METHODS.StartMoving(self) end
function METHODS.StopMovingOrSizing(self) end
function METHODS.SetBackdrop(self) end
function METHODS.SetBackdropColor(self) end
function METHODS.SetBackdropBorderColor(self) end
function METHODS.CreateTexture(self) return Mock.NewWidget("Texture", self) end
function METHODS.CreateFontString(self, _, _, font) local fs = Mock.NewWidget("FontString", self); fs.font = font; return fs end

-- Events --------------------------------------------------------------------
function METHODS.RegisterEvent(self, event)
    if not Mock.state.validEvents[event] then
        error("Attempt to register unknown event \"" .. event .. "\"", 2)
    end
    self.events[event] = true
end
function METHODS.RegisterUnitEvent(self, event, unit)
    METHODS.RegisterEvent(self, event)
    self.unitEvents[event] = unit
end
function METHODS.UnregisterEvent(self, event) self.events[event] = nil end
function METHODS.UnregisterAllEvents(self) self.events = {}; self.unitEvents = {} end

-- Text ------------------------------------------------------------------------
function METHODS.SetText(self, text)
    text = text == nil and "" or tostring(text)
    self.text = text
    if self.kind == "EditBox" then
        RunScript(self, "OnTextChanged", false)
    end
end
function METHODS.GetText(self) return self.text or "" end
function METHODS.SetJustifyH(self) end
function METHODS.SetJustifyV(self) end
function METHODS.SetWordWrap(self) end
function METHODS.SetSpacing(self) end
function METHODS.GetStringHeight(self)
    local _, lines = (self.text or ""):gsub("\n", "\n")
    return (lines + 1) * 12
end
function METHODS.SetColorTexture(self) end
function METHODS.SetFontObject(self) end

-- Button ------------------------------------------------------------------------
function METHODS.SetEnabled(self, enabled) self.enabled = enabled and true or false end
function METHODS.IsEnabled(self) return self.enabled end
function METHODS.Click(self) if self.enabled ~= false then RunScript(self, "OnClick", "LeftButton") end end

-- EditBox ------------------------------------------------------------------------
function METHODS.SetMultiLine(self) end
function METHODS.SetAutoFocus(self) end
function METHODS.SetMaxLetters(self, n) self.maxLetters = n end
function METHODS.SetTextInsets(self) end
function METHODS.SetFocus(self) Mock.state.focus = self end
function METHODS.ClearFocus(self) if Mock.state.focus == self then Mock.state.focus = nil end end
function METHODS.HighlightText(self) self.highlighted = true end
function METHODS.SetCursorPosition(self, pos) self.cursor = pos end

-- ScrollFrame ------------------------------------------------------------------------
function METHODS.SetScrollChild(self, child) self.child = child end
function METHODS.GetVerticalScrollRange(self) return self.range or 0 end
function METHODS.GetVerticalScroll(self) return self.scroll or 0 end
function METHODS.SetVerticalScroll(self, value) self.scroll = value; RunScript(self, "OnVerticalScroll", value) end
function METHODS.UpdateScrollChildRect(self) end

-- Slider ------------------------------------------------------------------------
function METHODS.SetOrientation(self) end
function METHODS.SetThumbTexture(self) end
function METHODS.SetMinMaxValues(self, lo, hi) self.minValue, self.maxValue = lo, hi end
function METHODS.SetValue(self, value)
    local old = self.value
    self.value = value
    if old ~= value then
        RunScript(self, "OnValueChanged", value, false)
    end
end
function METHODS.GetValue(self) return self.value end
function METHODS.SetValueStep(self) end
function METHODS.SetObeyStepOnDrag(self) end

-- Widget API methods are CamelCase; custom addon fields start lowercase and may be nil.
Widget.__index = function(_, key)
    local method = METHODS[key]
    if method then
        return method
    end
    if type(key) == "string" and key:find("^%u") then
        error("Mock widget has no method '" .. key .. "'", 2)
    end
    return nil
end

function Mock.NewWidget(kind, parent, name)
    local widget = setmetatable({
        kind = kind, parent = parent, name = name, shown = true,
        scripts = {}, hooks = {}, events = {}, unitEvents = {}, points = {},
    }, Widget)
    rawset(widget, "__widget", true)
    return widget
end

------------------------------------------------------------------------
-- Environment
------------------------------------------------------------------------

local TEMPLATES = {
    BackdropTemplate = true, UIPanelButtonTemplate = true, InputBoxTemplate = true, UIPanelCloseButton = true,
}

local VALID_EVENTS = {
    "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD",
    "ZONE_CHANGED", "ZONE_CHANGED_INDOORS", "ZONE_CHANGED_NEW_AREA", "PLAYER_TARGET_CHANGED",
    "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_LEVEL_UP", "BAG_UPDATE_DELAYED",
    "QUEST_LOG_UPDATE", "PLAYER_DEAD", "PLAYER_ALIVE", "PLAYER_UNGHOST", "UNIT_SPELLCAST_START",
    "UNIT_SPELLCAST_SUCCEEDED", "UNIT_SPELLCAST_FAILED", "CHAT_MSG_SYSTEM", "UI_ERROR_MESSAGE",
    "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "LUA_WARNING",
}

Mock.SECRET = setmetatable({}, { __tostring = function() error("secret value used as string", 2) end })

local function Secretable(value)
    return value
end

-- Resets every global the addon reads. `options` tweaks the world.
function Mock.Install(options)
    options = options or {}
    local state = {
        frames = {}, chat = {}, focus = nil, now = Mock.clock.now, uptime = Mock.clock.uptime,
        validEvents = {}, target = options.target, secrets = options.secrets or {},
        errorHandler = function(message) Mock.state.displayedErrors[#Mock.state.displayedErrors + 1] = message end,
        displayedErrors = {},
    }
    for _, event in ipairs(VALID_EVENTS) do
        state.validEvents[event] = true
    end
    for _, event in ipairs(options.missingEvents or {}) do
        state.validEvents[event] = nil
    end
    Mock.state = state

    local function secret(key, value)
        if state.secrets[key] then
            return Mock.SECRET
        end
        return value
    end

    _G.issecretvalue = options.noSecretApi and nil or function(value) return value == Mock.SECRET end
    _G.CreateFrame = function(kind, name, parent, template)
        if template then
            for templateName in tostring(template):gmatch("[^,%s]+") do
                assert(TEMPLATES[templateName], "unknown template " .. templateName)
            end
        end
        local frame = Mock.NewWidget(kind, parent, name)
        if name then
            _G[name] = frame
        end
        state.frames[#state.frames + 1] = frame
        return frame
    end
    _G.UIParent = Mock.NewWidget("Frame")
    _G.UISpecialFrames = {}
    _G.BackdropTemplateMixin = {}
    _G.ChatFontNormal = {}
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, text) state.chat[#state.chat + 1] = text end }
    _G.SlashCmdList = {}
    _G.WOW_PROJECT_ID = 2
    _G.GetBuildInfo = function() return "1.60.1", "70009", "Sep 24 2026", 16001, "1.60.1", "Release" end
    _G.GetLocale = function() return "esES" end
    _G.C_AddOns = {
        GetAddOnMetadata = function(name, field) if name == "OnionDebug" and field == "Version" then return "2.0.0" end end,
        GetNumAddOns = function() return 3 end,
        GetAddOnInfo = function(i) return ({ "OnionDebug", "BugSack", "Disabled" })[i] end,
        IsAddOnLoaded = function(i) return i ~= 3, i ~= 3 end,
    }
    _G.C_EventUtils = { IsEventValid = function(event) return state.validEvents[event] == true end }
    if options.noMapApi then
        _G.C_Map = nil
    else
        _G.C_Map = {
            GetBestMapForUnit = function() return options.mapID == nil and 1453 or options.mapID or nil end,
            GetMapInfo = function(id) return { name = "Stormwind City", mapID = id } end,
            GetPlayerMapPosition = function()
                if options.noPosition then return nil end
                return { GetXY = function() return 0.62137, 0.73821 end }
            end,
        }
    end
    _G.C_Spell = { GetSpellName = function(id) return id == 133 and "Fireball" or nil end }
    _G.GetSpellInfo = nil
    _G.GetFramerate = function() return 143.7 end
    _G.GetNetStats = options.nilNetStats and function() return nil end or function() return 1, 2, 27, 31 end
    _G.GetRealZoneText = function() return state.zone or "Stormwind City" end
    _G.GetSubZoneText = function() return state.subZone or "Trade District" end
    _G.GetInstanceInfo = function() return "Eastern Kingdoms", "none", 0, "", 5, 0, false, 0, 0, nil, false end
    _G.UnitPosition = function() return -8913.23, 554.63, 0, 0 end
    _G.GetRealmName = function() return "Forever" end
    _G.GetServerTime = function() return state.now end
    _G.GetTime = function() return state.uptime end
    _G.time = function() return state.now end
    _G.date = function(fmt, t) return os.date(fmt, t or state.now) end
    _G.UnitAffectingCombat = function() return state.combat or false end
    _G.InCombatLockdown = function() return state.combat or false end
    _G.IsMounted = function() return false end
    _G.IsSwimming = function() return false end
    _G.IsResting = function() return true end
    _G.UnitIsDeadOrGhost = function() return false end
    _G.UnitClass = function() return "Guerrero", "WARRIOR", 1 end
    _G.UnitRace = function() return "Humano", "Human", 1 end
    _G.UnitFactionGroup = function() return "Alliance", "Alianza" end

    local function T() return state.target end
    _G.UnitExists = function(unit)
        if unit == "player" then return true end
        return T() ~= nil
    end
    _G.UnitName = function(unit)
        if unit == "player" then return "Onion", nil end
        local target = T()
        if not target then return nil end
        return secret("name", target.name), target.realm
    end
    _G.UnitGUID = function(unit)
        if unit == "player" then return "Player-1-0000AAAA" end
        local target = T()
        return target and secret("guid", target.guid) or nil
    end
    _G.UnitLevel = function(unit)
        if unit == "player" then return 12 end
        return T() and T().level
    end
    _G.UnitClassification = function() return T() and (T().classification or "normal") end
    _G.UnitIsPlayer = function() return T() and T().isPlayer or false end
    _G.UnitReaction = function() return T() and T().reaction end
    _G.UnitCreatureType = function() return T() and secret("creatureType", T().creatureType) end
    _G.UnitIsDead = function() return false end

    _G.strsplit = function(sep, text)
        local parts = {}
        for part in (text .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do
            parts[#parts + 1] = part
        end
        return unpack(parts)
    end
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.tinsert = table.insert
    _G.geterrorhandler = function() return state.errorHandler end
    _G.seterrorhandler = function(fn) state.errorHandler = fn end
    _G.OnionDebugDB = options.db
    _G.SLASH_ONIONDEBUG1, _G.SLASH_ONIONDEBUG2, _G.SLASH_ONIONDEBUG3 = nil, nil, nil
    for _, name in ipairs({ "OnionDebugIncidentForm", "OnionDebugHistory", "OnionDebugDetail", "OnionDebugExport", "OnionDebugConfirm" }) do
        _G[name] = nil
    end
    return state
end

-- Loads the addon files into a fresh namespace, like the client does.
function Mock.LoadAddon(root)
    local ns = {}
    for _, file in ipairs({ "OnionDebug.lua", "OnionDebugUI.lua" }) do
        local chunk = assert(loadfile(root .. "/" .. file))
        chunk("OnionDebug", ns)
    end
    Mock.ns = ns
    return ns
end

function Mock.FireEvent(event, ...)
    for _, frame in ipairs(Mock.state.frames) do
        if frame.events[event] then
            local unit = frame.unitEvents[event]
            if not unit or unit == (...) then
                RunScript(frame, "OnEvent", event, ...)
            end
        end
    end
end

-- Runs every OnUpdate script `frames` times with the given elapsed time.
function Mock.Tick(elapsed, frames)
    for _ = 1, frames or 1 do
        Mock.state.uptime = Mock.state.uptime + elapsed
        for _, frame in ipairs(Mock.state.frames) do
            if frame.scripts.OnUpdate and frame.shown then
                frame.scripts.OnUpdate(frame, elapsed)
            end
        end
    end
end

function Mock.Advance(seconds)
    Mock.state.now = Mock.state.now + seconds
    Mock.state.uptime = Mock.state.uptime + seconds
    Mock.clock.now, Mock.clock.uptime = Mock.state.now, Mock.state.uptime
end

function Mock.Slash(text)
    _G.SlashCmdList.ONIONDEBUG(text)
end

function Mock.ChatSince(index)
    local lines = {}
    for i = index + 1, #Mock.state.chat do
        lines[#lines + 1] = Mock.state.chat[i]
    end
    return table.concat(lines, "\n")
end

-- Full client start: file load, ADDON_LOADED, PLAYER_LOGIN, PLAYER_ENTERING_WORLD.
function Mock.Boot(root, options)
    Mock.Install(options)
    local ns = Mock.LoadAddon(root)
    Mock.FireEvent("ADDON_LOADED", "OnionDebug", false)
    Mock.FireEvent("PLAYER_LOGIN")
    Mock.FireEvent("PLAYER_ENTERING_WORLD", not (options and options.reload), options and options.reload or false)
    return ns
end

-- Simulates /reload or relog: SavedVariables round-trip through a deep copy.
function Mock.Reload(root, options)
    local function DeepCopy(value)
        if type(value) ~= "table" then
            return value
        end
        local copy = {}
        for k, v in pairs(value) do
            copy[DeepCopy(k)] = DeepCopy(v)
        end
        return copy
    end
    options = options or {}
    options.db = DeepCopy(_G.OnionDebugDB)
    if options.reload == nil then
        options.reload = true
    end
    return Mock.Boot(root, options)
end

return Mock
