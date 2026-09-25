--[[
    OnionDebug - UI

    HUD, NEW INCIDENT form, history, incident detail, export and confirm
    windows. Pure Lua, no XML, no protected frames, no hooks on Blizzard UI.
    The HUD is built at login; every other window on first use. All data
    comes from the core model (OnionDebug.lua); nothing is cached here
    beyond what is on screen.
]]

local _, ns = ...
local UI = {}
ns.UI = UI

local format, floor, min, max = string.format, math.floor, math.min, math.max
local concat = table.concat

------------------------------------------------------------------------
-- Layout constants
------------------------------------------------------------------------

local PADDING = 10
local CONTENT_TOP = 32 -- first content line below a window title
local BUTTON_HEIGHT = 22
local BUTTON_GAP = 6
local SCROLLBAR_WIDTH = 8
local SCROLL_WHEEL_STEP = 40

local HUD_WIDTH = 300
local HUD_TITLE_HEIGHT = 26
local HUD_LABEL_WIDTH = 64
local HUD_ROW_HEIGHT = 14
local HUD_EVENT_LINES = 6
local HUD_EVENT_HEIGHT = 13
local HUD_REFRESH_INTERVAL = 0.25

local FPS_WARN, FPS_BAD = 40, 20
local LATENCY_WARN, LATENCY_BAD = 200, 400
local COLOR_GOOD, COLOR_WARN, COLOR_BAD = "66d98c", "ffd100", "ff4d4d"

local HISTORY_WIDTH = 480
local HISTORY_ROWS = 10
local HISTORY_ROW_HEIGHT = 34

local MARK_TEXT = "|cffff5a4dMARK BUG|r"
local DRAFT_OPEN_TEXT = "|cffffd100DRAFT OPEN|r"

local BACKDROP_TEMPLATE = BackdropTemplateMixin and "BackdropTemplate" or nil
local BACKDROP = {
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 14,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
}

------------------------------------------------------------------------
-- Widget helpers
------------------------------------------------------------------------

local movableFrames = {}

local function ApplyBackdrop(frame, alpha)
    if frame.SetBackdrop then
        frame:SetBackdrop(BACKDROP)
        frame:SetBackdropColor(0.05, 0.05, 0.07, alpha)
        frame:SetBackdropBorderColor(0.35, 0.35, 0.4, 1)
    else
        local background = frame:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetColorTexture(0.05, 0.05, 0.07, alpha)
    end
end

-- Positions are stored as TOPLEFT offsets so resizing (HUD minimize) keeps the top edge still.
local function SavePosition(frame)
    local left, top = frame:GetLeft(), frame:GetTop()
    if not (left and top) then
        return
    end
    left, top = floor(left + 0.5), floor(top + 0.5)
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    ns.db.ui[frame.layoutKey] = { point = "TOPLEFT", relativePoint = "BOTTOMLEFT", x = left, y = top }
end

local function RestorePosition(frame)
    local position = ns.NormalizePosition(ns.db.ui[frame.layoutKey]) or frame.defaultPosition
    frame:ClearAllPoints()
    frame:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
end

local function MakeMovable(frame, layoutKey, defaultPosition)
    frame.layoutKey, frame.defaultPosition = layoutKey, defaultPosition
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    if frame.SetDontSavePosition then
        frame:SetDontSavePosition(true) -- we persist positions ourselves
    end
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    RestorePosition(frame)
    movableFrames[#movableFrames + 1] = frame
end

local function CreateText(parent, fontObject, justify)
    local text = parent:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlightSmall")
    text:SetJustifyH(justify or "LEFT")
    return text
end

local function CreateButton(parent, text, width, onClick)
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, BUTTON_HEIGHT)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

-- Named windows are registered in UISpecialFrames so the game's ESC handling closes them.
local function CreateWindow(spec)
    local frame = CreateFrame("Frame", spec.name, UIParent, BACKDROP_TEMPLATE)
    frame:SetSize(spec.width, spec.height)
    frame:SetFrameStrata(spec.strata or "DIALOG")
    frame:SetToplevel(true)
    frame:Hide()
    ApplyBackdrop(frame, 0.94)
    MakeMovable(frame, spec.layoutKey, spec.defaultPosition)

    frame.titleText = CreateText(frame, "GameFontNormal")
    frame.titleText:SetPoint("TOPLEFT", PADDING + 2, -10)
    frame.titleText:SetPoint("TOPRIGHT", -34, -10)
    frame.titleText:SetWordWrap(false)
    frame.titleText:SetText(spec.title)

    local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() frame:Hide() end)
    frame.closeButton = close

    tinsert(UISpecialFrames, spec.name)
    return frame
end

-- All windows share one strata; the most recently opened one goes on top.
local function ShowWindow(frame)
    frame:Show()
    frame:Raise()
end

local function CreateScrollBar(parent)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(SCROLLBAR_WIDTH)
    bar:EnableMouse(true)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(1, 1, 1, 0.06)
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(0.8, 0.8, 0.85, 0.5)
    thumb:SetSize(SCROLLBAR_WIDTH, 28)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    return bar
end

-- Template-free scroll area: a ScrollFrame plus a slim slider, mouse wheel and
-- range sync. `area.child` (if set) is kept as wide as the visible region.
local function CreateScrollArea(parent, withBackground)
    local area = CreateFrame("Frame", nil, parent, withBackground and BACKDROP_TEMPLATE or nil)
    local inset = 0
    if withBackground then
        ApplyBackdrop(area, 0.55)
        inset = 5
    end

    local scroll = CreateFrame("ScrollFrame", nil, area)
    scroll:SetPoint("TOPLEFT", inset, -inset)
    scroll:SetPoint("BOTTOMRIGHT", -(inset + SCROLLBAR_WIDTH + 4), inset)
    local bar = CreateScrollBar(area)
    bar:SetPoint("TOPRIGHT", -inset, -inset)
    bar:SetPoint("BOTTOMRIGHT", -inset, inset)
    area.scroll, area.bar = scroll, bar

    local syncing = false
    local function Sync()
        local range = scroll:GetVerticalScrollRange()
        syncing = true
        bar:SetMinMaxValues(0, range)
        bar:SetValue(min(scroll:GetVerticalScroll(), range))
        syncing = false
        bar:SetShown(range > 0)
    end

    scroll:SetScript("OnScrollRangeChanged", function(self)
        local range = self:GetVerticalScrollRange()
        if self:GetVerticalScroll() > range then
            self:SetVerticalScroll(range)
        end
        Sync()
    end)
    scroll:SetScript("OnVerticalScroll", Sync)
    bar:SetScript("OnValueChanged", function(_, value)
        if not syncing then
            scroll:SetVerticalScroll(value)
        end
    end)
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local target = self:GetVerticalScroll() - delta * SCROLL_WHEEL_STEP
        self:SetVerticalScroll(max(0, min(target, self:GetVerticalScrollRange())))
    end)
    scroll:SetScript("OnSizeChanged", function(_, width)
        if area.child then
            area.child:SetWidth(width)
        end
        if area.onResize then
            area.onResize(width)
        end
    end)
    Sync()
    return area
end

-- Keeps the caret visible while typing. Deferred one frame (like Blizzard's
-- ScrollingEdit) because the scroll range updates after the text does.
local function FollowCursor(scroll, cursorY, cursorHeight)
    local height, range = scroll:GetHeight(), scroll:GetVerticalScrollRange()
    if height <= 0 then
        return
    end
    local offset, top = scroll:GetVerticalScroll(), -cursorY
    if top < offset then
        scroll:SetVerticalScroll(max(0, top))
    elseif top + cursorHeight > offset + height then
        scroll:SetVerticalScroll(min(range, top + cursorHeight - height))
    end
end

local function CreateTextArea(parent, maxLetters)
    local area = CreateScrollArea(parent, true)
    local edit = CreateFrame("EditBox", nil, area.scroll)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFontObject(ChatFontNormal)
    edit:SetMaxLetters(maxLetters or 0) -- 0 = unlimited
    edit:SetTextInsets(2, 2, 2, 2)
    -- Same as Blizzard's InputScrollFrameTemplate: a 1px-high multi-line EditBox
    -- grows with its text; the real width arrives through OnSizeChanged.
    edit:SetSize(100, 1)
    area.scroll:SetScrollChild(edit)
    area.child, area.edit = edit, edit

    edit:SetScript("OnEscapePressed", edit.ClearFocus)
    edit:SetScript("OnCursorChanged", function(self, _, y, _, height)
        self.cursorY, self.cursorHeight, self.cursorPending = y, height, true
    end)
    edit:SetScript("OnUpdate", function(self)
        if self.cursorPending then
            self.cursorPending = false
            FollowCursor(area.scroll, self.cursorY, self.cursorHeight)
        end
    end)
    -- Clicking empty space below the text still focuses the box.
    area.scroll:EnableMouse(true)
    area.scroll:SetScript("OnMouseDown", function() edit:SetFocus() end)
    return area
end

-- Called before showing: covers clients where the first OnSizeChanged
-- fires before the window is shown.
local function FitTextArea(area)
    local width = area.scroll:GetWidth()
    if width and width > 0 then
        area.edit:SetWidth(width)
    end
end

------------------------------------------------------------------------
-- HUD
------------------------------------------------------------------------

local HUD_ROWS = {
    { key = "build", label = "Build" },
    { key = "zone", label = "Zone" },
    { key = "subZone", label = "Subzone" },
    { key = "map", label = "Map" },
    { key = "perf", label = "FPS" },
    { key = "combat", label = "Combat" },
    { key = "target", label = "Target" },
    { key = "npc", label = "NPC ID" },
    { key = "last", label = "Last" },
    { key = "incidents", label = "Incidents" },
}

local HUD_BODY_HEIGHT = #HUD_ROWS * HUD_ROW_HEIGHT + 10 + HUD_EVENT_LINES * HUD_EVENT_HEIGHT
local HUD_FULL_HEIGHT = HUD_TITLE_HEIGHT + HUD_BODY_HEIGHT + 8 + BUTTON_HEIGHT + PADDING
local HUD_MINIMIZED_HEIGHT = HUD_TITLE_HEIGHT + BUTTON_HEIGHT + PADDING

local hud
local live = { location = {}, performance = {}, player = {}, target = {} }
local incidentSummary = "0"

local function ColorValue(color, text)
    return ns.Colorize(color, text)
end

local function FormatFPS(fps)
    if type(fps) ~= "number" then
        return "N/A"
    end
    return ColorValue(fps < FPS_BAD and COLOR_BAD or fps < FPS_WARN and COLOR_WARN or COLOR_GOOD, tostring(fps))
end

local function FormatPing(home, world)
    local text = ns.FormatLatency(home, world)
    if home == nil and world == nil then
        return text
    end
    local worst = max(home or 0, world or 0)
    return ColorValue(worst >= LATENCY_BAD and COLOR_BAD or worst >= LATENCY_WARN and COLOR_WARN or COLOR_GOOD, text)
end

local function FormatCombat(player)
    if player.combat then
        return ColorValue(COLOR_BAD, "In combat")
    elseif player.combatLockdown then
        return ColorValue(COLOR_WARN, "Lockdown")
    elseif player.combat == nil then
        return "N/A"
    end
    return ColorValue(COLOR_GOOD, "No")
end

local function RefreshHUD()
    ns.CollectLive(live)
    local location, performance, player, target = live.location, live.performance, live.player, live.target
    local values = hud.values
    values.zone:SetText(ns.Display(location.zone))
    values.subZone:SetText(ns.Display(location.subZone))
    values.map:SetText(format("%s   Pos %s", ns.Display(location.mapID), ns.FormatCoords(location.x, location.y)))
    values.perf:SetText(format("%s   Ping %s", FormatFPS(performance.fps), FormatPing(performance.homeLatency, performance.worldLatency)))
    values.combat:SetText(FormatCombat(player))
    values.target:SetText(target.exists and ns.FormatTargetName(target) or ColorValue(ns.COLOR_MUTED, "None"))
    values.npc:SetText(ns.FormatTargetId(target))

    -- Event lines are rebuilt only when the ring buffer changed.
    local version = ns.GetEventVersion()
    if version ~= hud.eventVersion then
        hud.eventVersion = version
        local last = ns.GetEvent(1)
        values.last:SetText(last and ColorValue(ns.CATEGORY_COLORS[last.category] or "ffffff", last.event)
            or ColorValue(ns.COLOR_MUTED, "None"))
        for index, line in ipairs(hud.eventLines) do
            local entry = ns.GetEvent(index)
            line:SetText(entry and ns.FormatEventLine(entry, true, false) or "")
        end
    end
end

local function UpdateIncidentSummary()
    if not ns.db then
        return
    end
    incidentSummary = format("%d   (%d this session)", #ns.db.incidents, ns.CountSessionIncidents())
    if hud then
        hud.values.incidents:SetText(incidentSummary)
    end
end

local function UpdateMarkButton()
    if hud then
        hud.markButton:SetText(ns.draft and DRAFT_OPEN_TEXT or MARK_TEXT)
    end
end

local function ApplyHUDLayout()
    if not hud then
        return
    end
    local settings = ns.db.settings
    local minimized = settings.hudMinimized
    hud.body:SetShown(not minimized)
    hud:SetHeight(minimized and HUD_MINIMIZED_HEIGHT or HUD_FULL_HEIGHT)
    hud.minimizeButton.label:SetText(minimized and "+" or "-")
    hud:SetShown(settings.hudVisible)
    hud.eventVersion = nil -- force a full refresh on the next tick
    hud.elapsed = HUD_REFRESH_INTERVAL
end

local function CreateTitleBarButton(parent, text, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(18, 18)
    button.label = CreateText(button, "GameFontHighlight", "CENTER")
    button.label:SetPoint("CENTER", 0, 1)
    button.label:SetText(text)
    local highlight = button:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.12)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateHUD()
    hud = CreateFrame("Frame", nil, UIParent, BACKDROP_TEMPLATE)
    hud:SetSize(HUD_WIDTH, HUD_FULL_HEIGHT)
    hud:SetFrameStrata("MEDIUM")
    ApplyBackdrop(hud, 0.85)
    MakeMovable(hud, "hud", { point = "TOPRIGHT", relativePoint = "TOPRIGHT", x = -230, y = -200 })

    local title = CreateText(hud, "GameFontNormal")
    title:SetPoint("TOPLEFT", PADDING, -8)
    title:SetText("ONION DEBUG")
    local version = CreateText(hud, "GameFontDisableSmall")
    version:SetPoint("LEFT", title, "RIGHT", 6, 0)
    version:SetText("v" .. ns.VERSION)

    local close = CreateTitleBarButton(hud, "x", function()
        ns.SetSetting("hudVisible", false)
        ns.Print("HUD hidden. Type /od show to bring it back.")
    end)
    close:SetPoint("TOPRIGHT", -5, -5)
    hud.minimizeButton = CreateTitleBarButton(hud, "-", function()
        ns.SetSetting("hudMinimized", not ns.db.settings.hudMinimized)
    end)
    hud.minimizeButton:SetPoint("RIGHT", close, "LEFT", -2, 0)

    local body = CreateFrame("Frame", nil, hud)
    body:SetPoint("TOPLEFT", 0, -HUD_TITLE_HEIGHT)
    body:SetSize(HUD_WIDTH, HUD_BODY_HEIGHT)
    hud.body = body

    hud.values = {}
    local valueWidth = HUD_WIDTH - 2 * PADDING - HUD_LABEL_WIDTH
    for index, row in ipairs(HUD_ROWS) do
        local y = -(index - 1) * HUD_ROW_HEIGHT
        local label = CreateText(body, "GameFontDisableSmall")
        label:SetPoint("TOPLEFT", PADDING, y)
        label:SetSize(HUD_LABEL_WIDTH, HUD_ROW_HEIGHT)
        label:SetText(row.label)
        local value = CreateText(body, "GameFontHighlightSmall")
        value:SetPoint("TOPLEFT", PADDING + HUD_LABEL_WIDTH, y)
        value:SetSize(valueWidth, HUD_ROW_HEIGHT)
        value:SetWordWrap(false)
        hud.values[row.key] = value
    end
    hud.values.build:SetText(format("%s   TOC %s", ns.Display(ns.CURRENT_BUILD), ns.Display(ns.client.tocVersion)))

    local eventsTop = -(#HUD_ROWS * HUD_ROW_HEIGHT) - 5
    local separator = body:CreateTexture(nil, "ARTWORK")
    separator:SetColorTexture(1, 1, 1, 0.12)
    separator:SetPoint("TOPLEFT", PADDING, eventsTop)
    separator:SetSize(HUD_WIDTH - 2 * PADDING, 1)

    hud.eventLines = {}
    for index = 1, HUD_EVENT_LINES do
        local line = CreateText(body, "GameFontHighlightSmall")
        line:SetPoint("TOPLEFT", PADDING, eventsTop - 5 - (index - 1) * HUD_EVENT_HEIGHT)
        line:SetSize(HUD_WIDTH - 2 * PADDING, HUD_EVENT_HEIGHT)
        line:SetWordWrap(false)
        hud.eventLines[index] = line
    end

    hud.markButton = CreateButton(hud, MARK_TEXT, 104, function() UI.BeginIncident() end)
    hud.markButton:SetPoint("BOTTOMLEFT", PADDING, PADDING - 2)
    local historyButton = CreateButton(hud, "HISTORY", 84, function()
        if UI.IsHistoryShown() then
            UI.HideHistory()
        else
            UI.ShowHistory()
        end
    end)
    historyButton:SetPoint("LEFT", hud.markButton, "RIGHT", BUTTON_GAP, 0)
    local copyButton = CreateButton(hud, "COPY", 70, function()
        UI.ShowExport(ns.FormatIncidentText(ns.CaptureSnapshot()), "Current context")
    end)
    copyButton:SetPoint("LEFT", historyButton, "RIGHT", BUTTON_GAP, 0)

    hud.elapsed = HUD_REFRESH_INTERVAL
    hud:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = self.elapsed + elapsed
        if self.elapsed < HUD_REFRESH_INTERVAL then
            return
        end
        self.elapsed = 0
        if not ns.db.settings.hudMinimized then
            RefreshHUD()
        end
    end)
end

------------------------------------------------------------------------
-- NEW INCIDENT form
------------------------------------------------------------------------

local form

local function UpdateSaveButton()
    form.saveButton:SetEnabled(ns.Trim(form.titleBox:GetText()) ~= "")
end

local function UpdateSeverityButton()
    form.severityButton:SetText("Severity: " .. ns.FormatSeverity(form.severity, true))
end

local function CycleSeverity()
    local severities = ns.SEVERITIES
    local index = 1
    for position, severity in ipairs(severities) do
        if severity == form.severity then
            index = position
        end
    end
    form.severity = severities[index % #severities + 1]
    UpdateSeverityButton()
end

-- The draft lives until the user saves or explicitly cancels (CANCEL, X, Esc
-- in a field). Any other hide - the game closing windows on death, loading
-- screens, fear, Alt+Z or an ESC while no field has focus - keeps the frozen
-- snapshot and the typed text; MARK BUG ("DRAFT OPEN") brings the form back.
local function SubmitForm()
    if ns.Trim(form.titleBox:GetText()) == "" then
        form.titleBox:SetFocus()
        return
    end
    local incident, err = ns.SaveIncident(form.draft, form.titleBox:GetText(), form.notes.edit:GetText(), form.severity)
    if not incident then
        ns.Print(err)
        return
    end
    form.draft = nil
    form:Hide()
end

local function CancelForm()
    if form.draft then
        form.draft = nil
        ns.DiscardDraft()
        ns.Print("Incident discarded.")
    end
    form:Hide()
end

local function CreateIncidentForm()
    local width = 440
    form = CreateWindow({
        name = "OnionDebugIncidentForm", layoutKey = "form", title = "NEW INCIDENT",
        width = width, height = 420,
        defaultPosition = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 80 },
    })

    local titleLabel = CreateText(form, "GameFontNormalSmall")
    titleLabel:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP)
    titleLabel:SetText("Title (required)")

    local titleBox = CreateFrame("EditBox", nil, form, "InputBoxTemplate")
    titleBox:SetHeight(20)
    titleBox:SetPoint("TOPLEFT", PADDING + 8, -CONTENT_TOP - 16)
    titleBox:SetPoint("TOPRIGHT", -PADDING - 4, -CONTENT_TOP - 16)
    titleBox:SetAutoFocus(false)
    titleBox:SetMaxLetters(ns.TITLE_MAX_LETTERS)
    titleBox:HookScript("OnTextChanged", UpdateSaveButton)
    titleBox:SetScript("OnEnterPressed", SubmitForm)
    titleBox:SetScript("OnEscapePressed", CancelForm)
    form.titleBox = titleBox
    form.closeButton:SetScript("OnClick", CancelForm)

    form.severityButton = CreateButton(form, "", 170, CycleSeverity)
    form.severityButton:SetPoint("TOPLEFT", PADDING, -CONTENT_TOP - 44)

    local notesLabel = CreateText(form, "GameFontNormalSmall")
    notesLabel:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP - 76)
    notesLabel:SetText("Notes (optional)")

    local notes = CreateTextArea(form, ns.NOTES_MAX_LETTERS)
    notes:SetPoint("TOPLEFT", PADDING, -CONTENT_TOP - 92)
    notes:SetPoint("TOPRIGHT", -PADDING, -CONTENT_TOP - 92)
    notes:SetHeight(110)
    notes.edit:SetScript("OnEscapePressed", CancelForm)
    notes.edit:SetScript("OnTabPressed", function() titleBox:SetFocus() end)
    titleBox:SetScript("OnTabPressed", function() notes.edit:SetFocus() end)
    form.notes = notes

    form.contextLabel = CreateText(form, "GameFontNormalSmall")
    form.contextLabel:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP - 214)
    form.contextText = CreateText(form, "GameFontHighlightSmall")
    form.contextText:SetPoint("TOPLEFT", PADDING + 6, -CONTENT_TOP - 232)
    form.contextText:SetWidth(width - 2 * PADDING - 12)
    form.contextText:SetJustifyV("TOP")
    form.contextText:SetSpacing(2)

    form.saveButton = CreateButton(form, "SAVE INCIDENT", 120, SubmitForm)
    form.saveButton:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)
    local cancelButton = CreateButton(form, "CANCEL", 80, CancelForm)
    cancelButton:SetPoint("RIGHT", form.saveButton, "LEFT", -BUTTON_GAP, 0)

    local hint = CreateText(form, "GameFontDisableSmall")
    hint:SetPoint("BOTTOMLEFT", PADDING + 2, PADDING + 6)
    hint:SetWidth(width - 2 * PADDING - 120 - 80 - BUTTON_GAP - 12) -- stops before CANCEL
    hint:SetWordWrap(false)
    hint:SetText("Enter: save  ·  Esc: cancel")

    form:SetScript("OnHide", function(self)
        titleBox:ClearFocus()
        notes.edit:ClearFocus()
        -- IsShown() stays true when only a parent (UIParent) was hidden.
        if form.draft and not self:IsShown() then
            ns.Print("Incident draft kept - click DRAFT OPEN on the HUD or type /od mark to finish it.")
        end
    end)
end

function UI.ShowIncidentForm(draft)
    if not form then
        CreateIncidentForm()
    end
    if form.draft == draft then
        -- same pending draft: bring it back with whatever was typed
        ShowWindow(form)
        FitTextArea(form.notes)
        form.titleBox:SetFocus()
        return
    end
    form.draft = draft
    form.severity = ns.DEFAULT_SEVERITY
    form.titleBox:SetText("")
    form.notes.edit:SetText("")
    UpdateSeverityButton()
    UpdateSaveButton()
    form.contextLabel:SetText("Captured context  -  frozen at " .. ns.FormatClock(draft.createdAt))
    form.contextText:SetText(ns.FormatContextSummary(draft, true))
    ShowWindow(form)
    FitTextArea(form.notes)
    form.titleBox:SetFocus()
end

function UI.BeginIncident()
    local wasOpen = form ~= nil and form:IsShown()
    local draft, isNew = ns.MarkBug()
    if not isNew then
        ns.Print(wasOpen and "An incident draft is already open - save or cancel it first."
            or format("Reopened the pending incident draft (captured %s).", ns.FormatClock(draft.createdAt)))
    end
    UI.ShowIncidentForm(draft)
end

------------------------------------------------------------------------
-- History
------------------------------------------------------------------------

local history
local filtered = {} -- reused: incidents currently listed, newest first

local function RenderHistoryRows()
    local offset = history.offset
    local selectedId = UI.GetShownIncidentId()
    for index, row in ipairs(history.rows) do
        local incident = filtered[offset + index]
        if incident then
            row.incidentId = incident.id
            row.idText:SetText(ns.Colorize(ns.SEVERITY_COLORS[incident.severity] or "ffffff", ns.FormatId(incident.id)))
            row.titleText:SetText(tostring(incident.title))
            row.metaText:SetText(ns.FormatIncidentMeta(incident, true))
            row.selected:SetShown(incident.id == selectedId)
            row:Show()
        else
            row.incidentId = nil
            row:Hide()
        end
    end
    local maxOffset = max(0, #filtered - HISTORY_ROWS)
    history.syncing = true
    history.bar:SetMinMaxValues(0, maxOffset)
    history.bar:SetValue(offset)
    history.syncing = false
    history.bar:SetShown(maxOffset > 0)
end

local function SetHistoryOffset(offset)
    local maxOffset = max(0, #filtered - HISTORY_ROWS)
    history.offset = max(0, min(floor(offset + 0.5), maxOffset))
    RenderHistoryRows()
end

local function RefreshHistory()
    local needle = ns.Trim(history.searchBox:GetText()):lower()
    local incidents = ns.GetIncidents()
    wipe(filtered)
    for index = #incidents, 1, -1 do
        local incident = incidents[index]
        if needle == "" or ns.IncidentMatches(incident, needle) then
            filtered[#filtered + 1] = incident
        end
    end

    local total = #incidents
    local summary = format("%d incident%s  ·  %d this session", total, total == 1 and "" or "s", ns.CountSessionIncidents())
    if needle ~= "" then
        summary = format("%d of %d match", #filtered, total)
    end
    history.summary:SetText(summary)

    if #filtered == 0 then
        history.emptyText:SetText(total == 0 and "No incidents yet.\nPress MARK BUG when you spot a bug."
            or "No incidents match the search.")
        history.emptyText:Show()
    else
        history.emptyText:Hide()
    end
    history.exportButton:SetEnabled(#filtered > 0)
    SetHistoryOffset(history.offset or 0)
end

local function CreateHistoryRow(parent, width)
    local row = CreateFrame("Button", nil, parent)
    row:SetSize(width, HISTORY_ROW_HEIGHT)

    row.selected = row:CreateTexture(nil, "BACKGROUND")
    row.selected:SetAllPoints()
    row.selected:SetColorTexture(1, 0.82, 0, 0.12)
    row.selected:Hide()
    local highlight = row:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    row.idText = CreateText(row, "GameFontNormal")
    row.idText:SetPoint("TOPLEFT", 6, -3)
    row.idText:SetWidth(52)
    row.titleText = CreateText(row, "GameFontHighlight")
    row.titleText:SetPoint("TOPLEFT", 62, -3)
    row.titleText:SetPoint("TOPRIGHT", -6, -3)
    row.titleText:SetWordWrap(false)
    row.metaText = CreateText(row, "GameFontDisableSmall")
    row.metaText:SetPoint("TOPLEFT", 62, -19)
    row.metaText:SetPoint("TOPRIGHT", -6, -19)
    row.metaText:SetWordWrap(false)

    row:SetScript("OnClick", function(self)
        if self.incidentId then
            UI.ShowDetail(self.incidentId)
        end
    end)
    return row
end

local function CreateHistory()
    local listHeight = HISTORY_ROWS * HISTORY_ROW_HEIGHT
    history = CreateWindow({
        name = "OnionDebugHistory", layoutKey = "history", title = "INCIDENT HISTORY",
        width = HISTORY_WIDTH, height = CONTENT_TOP + 30 + listHeight + 12 + BUTTON_HEIGHT + PADDING,
        defaultPosition = { point = "CENTER", relativePoint = "CENTER", x = -250, y = 40 },
    })

    local searchLabel = CreateText(history, "GameFontNormalSmall")
    searchLabel:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP - 4)
    searchLabel:SetText("Search")
    local searchBox = CreateFrame("EditBox", nil, history, "InputBoxTemplate")
    searchBox:SetSize(190, 20)
    searchBox:SetPoint("LEFT", searchLabel, "RIGHT", 12, 0)
    searchBox:SetAutoFocus(false)
    searchBox:SetMaxLetters(60)
    searchBox:HookScript("OnTextChanged", function()
        history.offset = 0
        RefreshHistory()
    end)
    searchBox:SetScript("OnEnterPressed", searchBox.ClearFocus)
    history.searchBox = searchBox

    history.summary = CreateText(history, "GameFontDisableSmall", "RIGHT")
    history.summary:SetPoint("TOPRIGHT", -PADDING - 2, -CONTENT_TOP - 4)
    history.summary:SetWidth(HISTORY_WIDTH - 2 * PADDING - 260)
    history.summary:SetWordWrap(false)

    local list = CreateFrame("Frame", nil, history)
    list:SetPoint("TOPLEFT", PADDING, -CONTENT_TOP - 30)
    list:SetPoint("TOPRIGHT", -PADDING, -CONTENT_TOP - 30)
    list:SetHeight(listHeight)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        SetHistoryOffset(history.offset - delta)
    end)

    history.bar = CreateScrollBar(list)
    history.bar:SetPoint("TOPRIGHT")
    history.bar:SetPoint("BOTTOMRIGHT")
    history.bar:SetValueStep(1)
    if history.bar.SetObeyStepOnDrag then
        history.bar:SetObeyStepOnDrag(true)
    end
    history.bar:SetScript("OnValueChanged", function(_, value)
        if not history.syncing then
            SetHistoryOffset(value)
        end
    end)

    history.rows = {}
    local rowWidth = HISTORY_WIDTH - 2 * PADDING - SCROLLBAR_WIDTH - 4
    for index = 1, HISTORY_ROWS do
        local row = CreateHistoryRow(list, rowWidth)
        row:SetPoint("TOPLEFT", 0, -(index - 1) * HISTORY_ROW_HEIGHT)
        history.rows[index] = row
    end

    history.emptyText = CreateText(list, "GameFontDisable", "CENTER")
    history.emptyText:SetPoint("CENTER", list, "CENTER")

    history.exportButton = CreateButton(history, "EXPORT LIST", 110, function()
        if #filtered == 0 then
            return
        end
        UI.ShowExport(ns.FormatIncidentsText(filtered), format("Export - %d incident%s", #filtered, #filtered == 1 and "" or "s"))
    end)
    history.exportButton:SetPoint("BOTTOMLEFT", PADDING, PADDING)
    local closeButton = CreateButton(history, "CLOSE", 80, function() history:Hide() end)
    closeButton:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)

    history.offset = 0
    history:SetScript("OnHide", function() searchBox:ClearFocus() end)
end

function UI.ShowHistory(search)
    if not history then
        CreateHistory()
    end
    if search then
        history.searchBox:SetText(search)
    end
    ShowWindow(history)
    RefreshHistory()
end

function UI.HideHistory()
    if history then
        history:Hide()
    end
end

function UI.IsHistoryShown()
    return history ~= nil and history:IsShown()
end

------------------------------------------------------------------------
-- Incident detail
------------------------------------------------------------------------

local detail

local function RenderRows(rows)
    local lines = {}
    for index, row in ipairs(rows) do
        lines[index] = type(row) == "string" and row or ns.FormatRow(row[1], row[2], true)
    end
    return concat(lines, "\n")
end

local function AcquireDetailBlock(index)
    local block = detail.blocks[index]
    if not block then
        block = {
            header = CreateText(detail.content, "GameFontNormal"),
            body = CreateText(detail.content, "GameFontHighlightSmall"),
        }
        block.body:SetJustifyV("TOP")
        block.body:SetSpacing(2)
        detail.blocks[index] = block
    end
    return block
end

local function RenderDetail(resetScroll)
    local incident = detail.incidentId and ns.FindIncident(detail.incidentId)
    if not incident then
        detail:Hide() -- deleted while open
        return
    end
    detail.titleText:SetText("INCIDENT " .. ns.FormatId(incident.id))
    local width = detail.area.scroll:GetWidth()
    if not width or width <= 0 then
        return -- laid out later through onResize
    end

    local content, y = detail.content, 0
    content:SetWidth(width)
    local sections = ns.DescribeIncident(incident, true)
    for index, section in ipairs(sections) do
        local block = AcquireDetailBlock(index)
        local header, body = block.header, block.body
        header:ClearAllPoints()
        if section.title then
            header:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            header:SetText(section.title)
            header:Show()
            y = y + header:GetStringHeight() + 3
        else
            header:Hide()
        end
        body:ClearAllPoints()
        body:SetPoint("TOPLEFT", content, "TOPLEFT", 8, -y)
        body:SetWidth(width - 12)
        body:SetText(RenderRows(section.rows))
        body:Show()
        y = y + body:GetStringHeight() + 10
    end
    for index = #sections + 1, #detail.blocks do
        detail.blocks[index].header:Hide()
        detail.blocks[index].body:Hide()
    end
    content:SetHeight(max(1, y))
    if resetScroll then
        detail.area.scroll:SetVerticalScroll(0)
    end
end

local function CreateDetail()
    detail = CreateWindow({
        name = "OnionDebugDetail", layoutKey = "detail", title = "INCIDENT",
        width = 480, height = 520,
        defaultPosition = { point = "CENTER", relativePoint = "CENTER", x = 250, y = 40 },
    })

    detail.area = CreateScrollArea(detail, false)
    detail.area:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP)
    detail.area:SetPoint("BOTTOMRIGHT", -PADDING, PADDING + BUTTON_HEIGHT + 8)
    detail.content = CreateFrame("Frame", nil, detail.area.scroll)
    detail.content:SetSize(1, 1)
    detail.area.scroll:SetScrollChild(detail.content)
    detail.area.onResize = function()
        if detail:IsShown() then
            RenderDetail(false)
        end
    end
    detail.blocks = {}

    local exportButton = CreateButton(detail, "COPY / EXPORT", 120, function()
        local incident = ns.FindIncident(detail.incidentId)
        if incident then
            UI.ShowExport(ns.FormatIncidentText(incident), "Export - Incident " .. ns.FormatId(incident.id))
        end
    end)
    exportButton:SetPoint("BOTTOMLEFT", PADDING, PADDING)
    local deleteButton = CreateButton(detail, "DELETE", 80, function()
        UI.ConfirmDelete(detail.incidentId)
    end)
    deleteButton:SetPoint("LEFT", exportButton, "RIGHT", BUTTON_GAP, 0)
    local closeButton = CreateButton(detail, "CLOSE", 80, function() detail:Hide() end)
    closeButton:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)

    detail:SetScript("OnHide", function()
        detail.incidentId = nil
        if UI.IsHistoryShown() then
            RenderHistoryRows() -- clear the selection highlight
        end
    end)
end

function UI.ShowDetail(id)
    if not ns.FindIncident(id) then
        ns.Print(format("Incident %s not found.", ns.FormatId(id)))
        return
    end
    if not detail then
        CreateDetail()
    end
    detail.incidentId = id
    ShowWindow(detail)
    RenderDetail(true)
    if UI.IsHistoryShown() then
        RenderHistoryRows()
    end
end

function UI.GetShownIncidentId()
    return detail and detail:IsShown() and detail.incidentId or nil
end

------------------------------------------------------------------------
-- Export (read-only, selectable text; Ctrl+C copies)
------------------------------------------------------------------------

local exportFrame

local function CreateExport()
    exportFrame = CreateWindow({
        name = "OnionDebugExport", layoutKey = "export", title = "EXPORT",
        width = 540, height = 460,
        defaultPosition = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 20 },
    })

    local hint = CreateText(exportFrame, "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", PADDING + 2, -CONTENT_TOP)
    hint:SetText("Text is selected: press Ctrl+C to copy, Esc to close.")

    local area = CreateTextArea(exportFrame, 0)
    area:SetPoint("TOPLEFT", PADDING, -CONTENT_TOP - 18)
    area:SetPoint("BOTTOMRIGHT", -PADDING, PADDING + BUTTON_HEIGHT + 8)
    exportFrame.area = area

    local edit = area.edit
    edit:SetScript("OnEscapePressed", function() exportFrame:Hide() end)
    edit:SetScript("OnEditFocusGained", edit.HighlightText)
    -- Read-only: any user edit restores the export text.
    edit:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(exportFrame.text or "")
            self:HighlightText()
        end
    end)

    local selectButton = CreateButton(exportFrame, "SELECT ALL", 100, function()
        edit:SetFocus()
        edit:HighlightText()
    end)
    selectButton:SetPoint("BOTTOMLEFT", PADDING, PADDING)
    local closeButton = CreateButton(exportFrame, "CLOSE", 80, function() exportFrame:Hide() end)
    closeButton:SetPoint("BOTTOMRIGHT", -PADDING, PADDING)

    exportFrame:SetScript("OnHide", function()
        edit:ClearFocus()
        exportFrame.text = nil
        edit:SetText("") -- release large export strings
    end)
end

function UI.ShowExport(text, title)
    if not exportFrame then
        CreateExport()
    end
    exportFrame.titleText:SetText(title or "EXPORT")
    exportFrame.text = text
    local edit = exportFrame.area.edit
    edit:SetText(text)
    ShowWindow(exportFrame)
    FitTextArea(exportFrame.area)
    exportFrame.area.scroll:SetVerticalScroll(0)
    edit:SetFocus()
    edit:SetCursorPosition(0)
    edit:HighlightText()
end

------------------------------------------------------------------------
-- Confirmation dialog (own frame: StaticPopup is shared with secure Blizzard flows)
------------------------------------------------------------------------

local confirm

local function CreateConfirm()
    confirm = CreateWindow({
        name = "OnionDebugConfirm", layoutKey = "confirm", title = "CONFIRM",
        width = 360, height = 140, strata = "FULLSCREEN_DIALOG",
        defaultPosition = { point = "CENTER", relativePoint = "CENTER", x = 0, y = 120 },
    })
    confirm.message = CreateText(confirm, "GameFontHighlight", "CENTER")
    confirm.message:SetPoint("TOPLEFT", PADDING + 4, -CONTENT_TOP)
    confirm.message:SetPoint("TOPRIGHT", -PADDING - 4, -CONTENT_TOP)

    confirm.acceptButton = CreateButton(confirm, "OK", 110, function()
        local onAccept = confirm.onAccept
        confirm.onAccept = nil
        confirm:Hide()
        if onAccept then
            onAccept()
        end
    end)
    confirm.acceptButton:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -BUTTON_GAP / 2, PADDING)
    local cancelButton = CreateButton(confirm, "CANCEL", 110, function() confirm:Hide() end)
    cancelButton:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", BUTTON_GAP / 2, PADDING)

    confirm:SetScript("OnHide", function() confirm.onAccept = nil end)
end

function UI.Confirm(message, acceptLabel, onAccept)
    if not confirm then
        CreateConfirm()
    end
    confirm.message:SetText(message)
    confirm.acceptButton:SetText(acceptLabel)
    confirm.onAccept = onAccept
    ShowWindow(confirm)
end

function UI.ConfirmDelete(id)
    local incident = id and ns.FindIncident(id)
    if not incident then
        ns.Print(format("Incident %s not found.", ns.FormatId(id)))
        return
    end
    UI.Confirm(format("Delete incident %s?\n\"%s\"\n\nThis cannot be undone. The ID is never reused.",
        ns.FormatId(id), ns.Truncate(tostring(incident.title), 60)), "DELETE", function()
        local deleted, err = ns.DeleteIncident(id)
        ns.Print(deleted and format("Incident %s deleted.", ns.FormatId(id)) or err)
    end)
end

------------------------------------------------------------------------
-- Model notifications and entry points
------------------------------------------------------------------------

function UI.OnModelChanged(topic)
    if topic == "incidents" then
        UpdateIncidentSummary()
        if UI.IsHistoryShown() then
            RefreshHistory()
        end
        if detail and detail:IsShown() then
            RenderDetail(false)
        end
    elseif topic == "session" then
        UpdateIncidentSummary()
    elseif topic == "draft" then
        UpdateMarkButton()
    elseif topic == "layout" then
        ApplyHUDLayout()
    end
end

function UI.ResetLayout()
    wipe(ns.db.ui)
    for _, frame in ipairs(movableFrames) do
        RestorePosition(frame)
    end
    ns.SetSetting("hudMinimized", false)
    ns.SetSetting("hudVisible", true)
end

function UI.Initialize()
    if hud then
        return
    end
    CreateHUD()
    UpdateIncidentSummary()
    UpdateMarkButton()
    ApplyHUDLayout()
end
