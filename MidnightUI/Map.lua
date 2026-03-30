-- =============================================================================
-- FILE PURPOSE:     World map reskin and quest log integration hub. Hooks into
--                   WorldMapFrame to replace the default chrome with a custom dark
--                   header, nav breadcrumb bar, floor dropdown, filter/pin/faction/
--                   quest-log control buttons, and a tab row (Quests/Events/MapLegend).
--                   Also owns the quest pin rendering pipeline and coordinates the
--                   QuestLog_Panel slide-in/out via Addon.Panel.
-- LOAD ORDER:       Loads after QuestLog_Panel.lua, before QuestInterface.lua. Fails
--                   gracefully if Addon.MapConfig (C) is absent — returns immediately.
--                   Contains the same early-exit guard as the rest of the map subsystem.
-- DEFINES:          Runtime{} — the single authoritative state table for all map state
--                   (initialized, layout, controls, annotation, debug, session tracking).
--                   Util{} — pure helpers (math, string, safe coercions, diagnostics).
--                   UI{} — frame manipulation, skinning, layout, color application.
--                   QEngine{} — quest list factories, data collection, bucketing bridge.
--                   (Three namespaces used to stay within Lua 5.1's 200-local limit.)
-- READS:            Addon.MapConfig (C) — all layout constants, SCROLL_PROBE_METHODS,
--                   GetThemeColor, MAP_THEME_COLORS. Required; file returns if absent.
--                   MidnightUISettings.General.{useBlizzardQuestingInterface,
--                   mapQuestStructureProbe} — feature gates.
--                   Addon.QuestData — reads via QEngine for quest pin data.
--                   Addon.Panel — calls Panel.Open/Close/Refresh for the quest log panel.
-- WRITES:           Runtime.{initialized, hooksInstalled, layout, controls, questLogPanelOpen,
--                   focusedQuestID, pendingLayout, sessionId} — all map runtime state.
-- DEPENDS ON:       Addon.MapConfig — required (early return if absent).
--                   Addon.QuestData, Addon.Panel (QuestLog_Panel) — read at call time.
--                   WorldMapFrame (Blizzard) — hooks installed at PLAYER_LOGIN.
-- USED BY:          QuestInterface.lua — reads Runtime to determine map state.
--                   Nothing else depends on Map.lua exports directly.
-- KEY FLOWS:
--   PLAYER_LOGIN → ApplyLayout() → skin WorldMapFrame chrome, build header + nav bar
--   WorldMapFrame OnShow → RunLayout, commit → sync panel/header positions
--   Quest log button click → Addon.Panel.Open/Close (toggle)
--   WORLD_MAP_CLOSED → Runtime.questLogPanelOpen = false → Panel.Close()
--   Zoom/scroll API probe: iterate SCROLL_PROBE_METHODS to find working canvas API
-- GOTCHAS:
--   Runtime table is the single source of truth — never duplicate state into locals.
--   Runtime.mapVisibilityHold = true at init prevents the map from showing prematurely
--   during the settle phase after hooks install; cleared after first layout commit.
--   SCROLL_PROBE_METHODS: iterated in order; the first method that exists on the canvas
--   is adopted. Covers WoW 9.x through 12.x API surface changes.
--   Runtime.debug sub-table is kept lightweight so legacy debug call-sites don't fault.
--   Rapid open/close spam can cause a settle-token race; headerSettleToken guards this.
-- NAVIGATION:
--   Runtime{}         — all map state (line ~18)
--   Util{}            — pure helpers (line ~95)
--   UI{}              — frame/skin helpers (search "local UI = {}")
--   QEngine{}         — quest pipeline bridge (search "local QEngine = {}")
--   ApplyLayout()     — main layout entry point (search "ApplyLayout")
-- =============================================================================
local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then
    ADDON_NAME = "MidnightUI"
end
if type(Addon) ~= "table" then
    Addon = {}
end

local C = Addon.MapConfig
if type(C) ~= "table" then
    return
end

local Runtime = {
    initialized = false,
    hooksInstalled = false,
    questLogCompatInstalled = false,
    questLogCompatOriginal = nil,
    questLogCompatGuard = false,
    pendingLayout = false,
    pendingQuestLogToggle = false,
    questLogPanelOpen = false,
    focusedQuestID = nil,
    headerAnchorSyncQueued = false,
    headerAnchorSyncReason = nil,
    headerSettleToken = 0,
    baseSkinApplied = false,
    relayoutInProgress = false,
    commitInProgress = false,
    postLayoutSyncQueued = false,
    mapCenterSyncQueued = false,
    mapVisibilityHold = true,
    mapVisibilityHoldReason = "init",
    mapVisibilityHoldClampGuard = false,
    mapCloseCenterSettleToken = 0,
    pendingMapCloseCenterSettle = false,
    pendingMapCloseCenterReason = nil,
    currentLayoutReason = nil,
    sessionId = 0,
    lastPanTargetX = nil,
    lastPanTargetY = nil,
    lastPanTargetSource = nil,
    lastPanTargetAt = 0,
    interactionCounts = {},
    layout = nil,
    controls = {
        navBar = nil,
        floorDropdown = nil,
        filterButton = nil,
        pinButton = nil,
        factionButton = nil,
        questLogButton = nil,
        annotationToolButton = nil,
    },
    annotation = {
        active = false,
        captureActive = false,
        pending = nil,
        lastZoomClickAt = 0,
        contextMenuOpen = false,
    },
    -- Compatibility shim: legacy debug/probe call-sites still read Runtime.debug.
    -- Keep this table lightweight so map layout paths never fault on nil-index.
    debug = {
        lastLogTimes = {},
        anchorAuditSeq = 0,
        anchorStats = nil,
        questTabArtToken = 0,
        questTabArtSeq = 0,
        questTabArtLastMode = nil,
        questTabArtSeenByMode = {},
        mapGeometryTraceToken = 0,
        mapGeometryTraceReason = nil,
        mapGeometryTraceStartedAt = 0,
        mapGeometryTraceExpiresAt = 0,
        mapGeometryTraceForce = false,
        lastMapGeometryMutation = nil,
        mapMutationProbeToken = 0,
        mapMutationProbe = nil,
        mapVisibilityProbeToken = 0,
        mapVisibilityProbe = nil,
    },
}

local ApplyLayout

-- Namespace tables to stay within Lua 5.1's 200-local limit.
-- Util  = pure helpers (math, string, debug, diagnostics)
-- UI    = frame manipulation, skinning, layout, color
-- QEngine = quest list factories, data collection, bucketing
local Util = {}
local UI = {}
local QEngine = {}

function Util.FormatNumber(value)
    return type(value) == "number" and string.format("%.2f", value) or "nil"
end

function Util.FormatNumberPrecise(value)
    return type(value) == "number" and string.format("%.4f", value) or "nil"
end

function Util.Clamp(value, minValue, maxValue)
    if type(value) ~= "number" then return minValue end
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

function Util.SafeToString(value)
    if value == nil then return "nil" end
    local ok, text = pcall(tostring, value)
    return ok and text or "[Restricted]"
end

function Util.ShouldShowQuestObjectivesInLog()
    if type(GetCVarBool) == "function" then
        local ok, value = pcall(GetCVarBool, "showQuestObjectivesInLog")
        if ok and type(value) == "boolean" then
            return value
        end
    end
    return true
end

function Util.EnsureMapNavDebugSettings()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    _G.MidnightUISettings.General = _G.MidnightUISettings.General or {}
    local general = _G.MidnightUISettings.General
    if general.useBlizzardQuestingInterface == nil then general.useBlizzardQuestingInterface = false end
    if general.mapQuestStructureProbe == nil then general.mapQuestStructureProbe = false end
    return general
end

function Util.IsCustomQuestingInterfaceEnabled()
    local settings = Util.EnsureMapNavDebugSettings()
    return settings.useBlizzardQuestingInterface ~= true
end

function Util.IsMapNavDebugEnabled()
    return false
end

function Util.IsMapNavDebugWatchEnabled()
    return false
end

function Util.IsMapQuestArtAutoCaptureEnabled()
    return false
end

function Util.IsQuestStructureProbeEnabled()
    return false
end

function Util.FormatColor(r, g, b, a)
    if type(r) ~= "number" then return "nil" end
    local alpha = type(a) == "number" and a or 1
    return string.format("(%.2f,%.2f,%.2f,%.2f)", r, g, b, alpha)
end

function Util.IsMapAnnotationInputDebugEnabled()
    local settings = Util.EnsureMapNavDebugSettings()
    if settings.mapAnnotationInputDebug == nil then
        settings.mapAnnotationInputDebug = false
    end
    if settings.mapAnnotationInputDebug == true then
        return true
    end

    local diagnostics = _G.MidnightUI_Diagnostics
    if diagnostics and type(diagnostics.IsEnabled) == "function" then
        local ok, enabled = pcall(diagnostics.IsEnabled)
        if ok and enabled == true then
            return true
        end
    end
    return false
end

function Util.MapAnnotationInputLog(phase, message, force)
    local _ = phase
    local __ = message
    local ___ = force
end

function Util.IsMapAnnotationRenderDebugEnabled()
    local settings = Util.EnsureMapNavDebugSettings()
    if settings.mapAnnotationRenderDebug == nil then
        settings.mapAnnotationRenderDebug = false
    end
    return (settings.mapAnnotationRenderDebug == true) or Util.IsMapAnnotationInputDebugEnabled()
end

function Util.MapAnnotationRenderLog(phase, message, force)
    local _ = phase
    local __ = message
    local ___ = force
end

function Util.IsMapAnnotationBandingDebugEnabled()
    return false
end

function Util.GetMapAnnotationBandingABMode()
    local settings = Util.EnsureMapNavDebugSettings()
    if settings.mapAnnotationBandingAutoMode == nil then
        settings.mapAnnotationBandingAutoMode = true
    end
    if settings.mapAnnotationBandingAutoMode == true then
        return "ALT"
    end
    if type(settings.mapAnnotationBandingABMode) ~= "string" then
        settings.mapAnnotationBandingABMode = "ALT"
    end
    local mode = string.upper(settings.mapAnnotationBandingABMode or "ALT")
    if mode ~= "ALT" and mode ~= "A" and mode ~= "B" and mode ~= "OFF" then
        mode = "ALT"
    end
    return mode
end

function Util.CreateMapAnnotationDebugTraceKey(mapID)
    Runtime.annotation = Runtime.annotation or {}
    Runtime.annotation.debugTraceSeq = (Runtime.annotation.debugTraceSeq or 0) + 1
    return string.format("trace:%s:%s", Util.SafeToString(mapID), Util.SafeToString(Runtime.annotation.debugTraceSeq))
end

function Util.GetFrameDebugIdentity(frame)
    if not frame then
        return "nil"
    end
    local name = type(frame.GetName) == "function" and frame:GetName() or nil
    if type(name) == "string" and name ~= "" then
        return name
    end
    return Util.SafeToString(frame)
end

function Util.MapAnnotationBandingLog(phase, message, force)
    if not Util.IsMapAnnotationBandingDebugEnabled() then
        return
    end

    Runtime.annotation = Runtime.annotation or {}
    Runtime.annotation.bandingSeq = (Runtime.annotation.bandingSeq or 0) + 1
    local text = string.format(
        "map_note_fill seq=%s phase=%s %s",
        Util.SafeToString(Runtime.annotation.bandingSeq),
        Util.SafeToString(phase or "unknown"),
        Util.SafeToString(message or "")
    )
    local diagnostics = _G.MidnightUI_Diagnostics
    if diagnostics and type(diagnostics.LogDebugSource) == "function" then
        pcall(diagnostics.LogDebugSource, "Map/AnnotationBanding", text)
    end
    if type(_G.MidnightUI_Debug) == "function" then
        pcall(_G.MidnightUI_Debug, "[Map/AnnotationBanding] " .. text)
    end
end

function Util.MapQuestStructureLog(level, message, force)
    local _ = level
    local __ = message
    local ___ = force
end

function UI.GetAccentColor()
    return C.GetThemeColor("accent")
end

function UI.HideTexture(texture)
    if texture then
        if texture.SetAlpha then texture:SetAlpha(0) end
        if texture.Hide then texture:Hide() end
    end
end

function UI.HideFrameRegions(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
            UI.HideTexture(region)
        end
    end
end

function UI.HideTextureRegions(frame, keepA, keepB, keepC, keepD)
    if not frame or type(frame.GetRegions) ~= "function" then return end
    local keep = {}
    if keepA then keep[keepA] = true end
    if keepB then keep[keepB] = true end
    if keepC then keep[keepC] = true end
    if keepD then keep[keepD] = true end

    for _, region in ipairs({ frame:GetRegions() }) do
        if not keep[region] and region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
            UI.HideTexture(region)
        end
    end
end

function UI.SuppressControlHighlight(control)
    if not control then return end

    if type(control.GetHighlightTexture) == "function" then
        local ok, highlightTexture = pcall(control.GetHighlightTexture, control)
        if ok then
            UI.HideTexture(highlightTexture)
        end
        if type(control.SetHighlightTexture) == "function" then
            pcall(control.SetHighlightTexture, control, nil)
        end
    end

    UI.HideTexture(control.Highlight)
    UI.HideTexture(control.HighlightTexture)
    UI.HideTexture(control.MouseOverHighlight)
end

function UI.SuppressButtonArt(button)
    if not button then return end

    if type(button.GetNormalTexture) == "function" then
        local ok, normalTexture = pcall(button.GetNormalTexture, button)
        if ok then UI.HideTexture(normalTexture) end
    end
    if type(button.GetPushedTexture) == "function" then
        local ok, pushedTexture = pcall(button.GetPushedTexture, button)
        if ok then UI.HideTexture(pushedTexture) end
    end
    if type(button.GetDisabledTexture) == "function" then
        local ok, disabledTexture = pcall(button.GetDisabledTexture, button)
        if ok then UI.HideTexture(disabledTexture) end
    end

    UI.HideTexture(button.NormalTexture)
    UI.HideTexture(button.PushedTexture)
    UI.HideTexture(button.DisabledTexture)
    UI.SuppressControlHighlight(button)
end

function UI.EnforceArrowButtonArt(button, artRegion)
    if not button then return end
    UI.SuppressButtonArt(button)
    if artRegion then
        UI.HideTexture(artRegion)
        if type(artRegion.GetRegions) == "function" then
            UI.HideFrameRegions(artRegion)
        end
    end
end

function UI.QueueArrowButtonArtRefresh(button, artRegion)
    if not button or button._muiMapArrowArtRefreshQueued then return end
    button._muiMapArrowArtRefreshQueued = true

    local function run()
        button._muiMapArrowArtRefreshQueued = false
        UI.EnforceArrowButtonArt(button, artRegion)
    end

    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, run)
    else
        run()
    end
end

function UI.SuppressNavButtonArt(button)
    if not button then return end
    -- Hide only Blizzard art textures (backgrounds/borders), NOT the button frame itself
    UI.HideTexture(button:GetNormalTexture())
    UI.HideTexture(button:GetPushedTexture())
    UI.HideTexture(button:GetHighlightTexture())
    UI.HideTexture(button.arrowUp)
    UI.HideTexture(button.arrowDown)
    UI.HideTexture(button.selected)
    UI.SuppressControlHighlight(button)
    UI.HideTextureRegions(button, button._muiMapSimpleHover, button._muiMapSimpleActiveLine)
    -- Ensure the button frame itself stays visible and interactive
    button:Show()
    button:SetAlpha(1)
    if type(button.EnableMouse) == "function" then button:EnableMouse(true) end
end

function UI.GetReadableHoverTextColorForAccent(r, g, b)
    local luminance = (0.2126 * r) + (0.7152 * g) + (0.0722 * b)
    if luminance >= 0.78 then
        local inkR, inkG, inkB = C.GetThemeColor("ink")
        return inkR, inkG, inkB, 1
    end
    local textR, textG, textB = C.GetThemeColor("textPrimary")
    return textR, textG, textB, 1
end

function UI.ApplyChevronColor(arrowFrame, r, g, b, a)
    if not arrowFrame then return end
    local alpha = type(a) == "number" and a or 1
    if arrowFrame.left then arrowFrame.left:SetVertexColor(r, g, b, alpha) end
    if arrowFrame.right then arrowFrame.right:SetVertexColor(r, g, b, alpha) end
end

function UI.GetNavButtonTextObject(button)
    if not button then return nil end

    if button._muiMapNavText and type(button._muiMapNavText.SetTextColor) == "function" then
        return button._muiMapNavText
    end

    local textObject = button.text or button.Text
    if not textObject and type(button.GetName) == "function" then
        local buttonName = button:GetName()
        if type(buttonName) == "string" and buttonName ~= "" then
            textObject = _G[buttonName .. "Text"]
        end
    end
    if not textObject and type(button.GetFontString) == "function" then
        textObject = button:GetFontString()
    end

    if textObject and type(textObject.SetTextColor) == "function" then
        button._muiMapNavText = textObject
        return textObject
    end

    return nil
end

function UI.ApplyNavButtonTextColor(button, isHovered)
    local textObject = UI.GetNavButtonTextObject(button)
    if not textObject and type(button.GetRegions) ~= "function" then return end

    local r, g, b, a
    if isHovered then
        local accentR, accentG, accentB = UI.GetAccentColor()
        r, g, b, a = UI.GetReadableHoverTextColorForAccent(accentR, accentG, accentB)
    elseif button:IsEnabled() then
        r, g, b = C.GetThemeColor("textSecondary")
        a = 1
    else
        r, g, b = C.GetThemeColor("textPrimary")
        a = 1
    end

    if textObject then
        textObject:SetTextColor(r, g, b, a or 1)
    end

    -- Some nav buttons can use secondary font strings for label state.
    if type(button.GetRegions) == "function" then
        for _, region in ipairs({ button:GetRegions() }) do
            if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "FontString"
                and type(region.SetTextColor) == "function" then
                region:SetTextColor(r, g, b, a or 1)
            end
        end
    end
end

function UI.ApplyNavMenuArrowColor(button, isHovered)
    if not button or not button.MenuArrowButton then return end
    local arrowFrame = button.MenuArrowButton._muiMapNavMenuArrow
    if not arrowFrame then return end

    local r, g, b = UI.GetAccentColor()
    if isHovered then
        local fr, fg, fb = UI.GetReadableHoverTextColorForAccent(r, g, b)
        UI.ApplyChevronColor(arrowFrame, fr, fg, fb, 1)
    else
        UI.ApplyChevronColor(arrowFrame, r, g, b, 0.95)
    end
end

function Util.GetFrameDebugName(frame)
    if not frame then return "nil" end
    if frame.GetName then
        local name = frame:GetName()
        if type(name) == "string" and name ~= "" then
            return name
        end
    end
    return Util.SafeToString(frame)
end

function Util.IsForbiddenRegion(frame)
    if not frame or type(frame.IsForbidden) ~= "function" then
        return false
    end
    local ok, forbidden = pcall(frame.IsForbidden, frame)
    return ok and forbidden == true
end

function Util.SafeGetPoint(frame, pointIndex)
    if not frame or type(frame.GetPoint) ~= "function" then
        return nil
    end
    if Util.IsForbiddenRegion(frame) then
        return nil
    end

    local ok, point, relativeTo, relativePoint, x, y = pcall(frame.GetPoint, frame, pointIndex)
    if not ok then
        return nil
    end
    if relativeTo and Util.IsForbiddenRegion(relativeTo) then
        relativeTo = nil
    end
    return point, relativeTo, relativePoint, x, y
end

function Util.BuildAnchorSummary(frame)
    if not frame or type(frame.GetNumPoints) ~= "function" then return "anchors=nil" end
    if Util.IsForbiddenRegion(frame) then return "anchors=restricted" end
    local count = frame:GetNumPoints() or 0
    if count <= 0 then return "anchors=none" end

    local parts = {}
    for i = 1, count do
        local point, relativeTo, relativePoint, x, y = Util.SafeGetPoint(frame, i)
        if point then
            parts[#parts + 1] = string.format(
                "%s->%s.%s(%s,%s)",
                Util.SafeToString(point),
                Util.GetFrameDebugName(relativeTo),
                Util.SafeToString(relativePoint),
                Util.FormatNumber(x),
                Util.FormatNumber(y)
            )
        end
    end
    return table.concat(parts, " | ")
end

function Util.SafeMethodRead(target, methodName)
    if not target then return nil end
    local method = target[methodName]
    if type(method) ~= "function" then return nil end
    local ok, value = pcall(method, target)
    if not ok then return nil end
    return value
end

function Util.SafeGetUIPanelAttribute(frame, attribute)
    if not frame or type(GetUIPanelAttribute) ~= "function" then return nil end
    local ok, value = pcall(GetUIPanelAttribute, frame, attribute)
    if not ok then return nil end
    return value
end

function Util.GetCallsiteLine(stackStart, stackDepth)
    if type(debugstack) ~= "function" then return "debugstack=nil" end

    local startAt = (type(stackStart) == "number" and stackStart > 0) and stackStart or 3
    local depth = (type(stackDepth) == "number" and stackDepth > 0) and stackDepth or 8
    local ok, stack = pcall(debugstack, startAt, depth, depth)
    if not ok or type(stack) ~= "string" or stack == "" then return "unknown" end

    local first = nil
    for line in stack:gmatch("[^\n]+") do
        local trimmed = tostring(line):gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            if not first then first = trimmed end
            if string.find(trimmed, "Interface/AddOns/", 1, true) or string.find(trimmed, "Interface\\AddOns\\", 1, true) then
                return trimmed
            end
        end
    end

    return first or "unknown"
end

function Util.FormatDebugValue(value)
    local t = type(value)
    if t == "number" then return Util.FormatNumber(value) end
    if t == "boolean" then return value and "true" or "false" end
    if value == nil then return "nil" end
    return Util.SafeToString(value)
end

function Util.BuildArgsSummary(...)
    local count = select("#", ...)
    if count <= 0 then return "none" end

    local out = {}
    local maxCount = count
    if maxCount > 4 then maxCount = 4 end

    for i = 1, maxCount do
        out[#out + 1] = Util.FormatDebugValue(select(i, ...))
    end

    if count > maxCount then
        out[#out + 1] = "...+" .. Util.SafeToString(count - maxCount)
    end
    return table.concat(out, ",")
end

function Util.RememberPanTarget(x, y, source)
    if type(x) == "number" then
        Runtime.lastPanTargetX = Util.Clamp(x, 0, 1)
    end
    if type(y) == "number" then
        Runtime.lastPanTargetY = Util.Clamp(y, 0, 1)
    end
    Runtime.lastPanTargetSource = Util.SafeToString(source or "SetPanTarget")
    Runtime.lastPanTargetAt = (GetTime and GetTime()) or 0
end

function Util.ResolvePanTargetX(scroll)
    local panX = nil
    local panY = nil
    local source = "unknown"

    -- Prefer live pan coordinates from the scroll container when available.
    if scroll and type(scroll.GetPanTarget) == "function" then
        local ok, x, y = pcall(scroll.GetPanTarget, scroll)
        if ok and type(x) == "number" then
            panX = Util.Clamp(x, 0, 1)
            if type(y) == "number" then
                panY = Util.Clamp(y, 0, 1)
            end
            source = "GetPanTarget"
            Runtime.lastPanTargetX = panX
            if type(panY) == "number" then
                Runtime.lastPanTargetY = panY
            end
            Runtime.lastPanTargetSource = source
            Runtime.lastPanTargetAt = (GetTime and GetTime()) or Runtime.lastPanTargetAt
        end
    end

    if type(panX) ~= "number" then
        panX = Runtime.lastPanTargetX
        panY = Runtime.lastPanTargetY
        source = Runtime.lastPanTargetSource or "runtime"
    end

    if type(panX) ~= "number" then
        panX = 0.5
        source = "default"
    end
    panX = Util.Clamp(panX, 0, 1)
    if type(panY) == "number" then
        panY = Util.Clamp(panY, 0, 1)
    end
    return panX, panY, source
end

function Util.ComputeFrameCenter(frame)
    local left = frame and frame.GetLeft and frame:GetLeft() or nil
    local right = frame and frame.GetRight and frame:GetRight() or nil
    if type(left) ~= "number" or type(right) ~= "number" then return nil end
    return (left + right) * 0.5
end

function Util.ComputeFrameMiddleY(frame)
    local top = frame and frame.GetTop and frame:GetTop() or nil
    local bottom = frame and frame.GetBottom and frame:GetBottom() or nil
    if type(top) ~= "number" or type(bottom) ~= "number" then return nil end
    return (top + bottom) * 0.5
end

function Util.ComputeCenterDelta(leftFrame, rightFrame)
    local leftCenter = Util.ComputeFrameCenter(leftFrame)
    local rightCenter = Util.ComputeFrameCenter(rightFrame)
    if type(leftCenter) ~= "number" or type(rightCenter) ~= "number" then return "nil" end
    return Util.FormatNumber(leftCenter - rightCenter)
end

function Util.ComputeVisibleEdgeRange(scroll, leftInset, rightInset)
    local scrollLeft = scroll and scroll.GetLeft and scroll:GetLeft() or nil
    local scrollRight = scroll and scroll.GetRight and scroll:GetRight() or nil
    if type(scrollLeft) ~= "number" or type(scrollRight) ~= "number" then
        return nil, nil, nil
    end
    local insetLeft = type(leftInset) == "number" and leftInset or 0
    local insetRight = type(rightInset) == "number" and rightInset or 0
    local left = scrollLeft + insetLeft
    local right = scrollRight + insetRight
    return left, right, (right - left)
end

function Util.ComputeFrameEdgeMetrics(frame, expectedLeft, expectedRight)
    local left = frame and frame.GetLeft and frame:GetLeft() or nil
    local right = frame and frame.GetRight and frame:GetRight() or nil
    if type(left) ~= "number" or type(right) ~= "number" then
        return nil, nil, nil, nil, nil, nil
    end

    local width = right - left
    local center = (left + right) * 0.5
    local leftError = nil
    local rightError = nil
    local centerError = nil

    if type(expectedLeft) == "number" then
        leftError = left - expectedLeft
    end
    if type(expectedRight) == "number" then
        rightError = right - expectedRight
    end
    if type(expectedLeft) == "number" and type(expectedRight) == "number" then
        centerError = center - ((expectedLeft + expectedRight) * 0.5)
    end

    return left, right, width, leftError, rightError, centerError
end

function Util.ComputeNudgeSuggestion(centerError)
    if type(centerError) ~= "number" then return "nil" end
    return Util.FormatNumber(-centerError)
end

function Util.ShouldEmitDebugToken(token, minInterval)
    local now = (GetTime and GetTime()) or 0
    local last = Runtime.debug.lastLogTimes[token] or 0
    if (now - last) < (minInterval or 0.05) then return false end
    Runtime.debug.lastLogTimes[token] = now
    return true
end

function Util.GetAnchorDebugStats()
    if type(Runtime.debug.anchorStats) ~= "table" then
        Runtime.debug.anchorStats = {
            samples = 0,
            maxRootCenterErr = nil,
            maxRootCenterErrAbs = -1,
            maxId = nil,
            maxPhase = nil,
            maxReason = nil,
            lastId = nil,
            lastPhase = nil,
            lastReason = nil,
            lastRootCenterErr = nil,
            lastNavRowCenterErr = nil,
            mutations = {},
        }
    end
    if type(Runtime.debug.anchorStats.mutations) ~= "table" then
        Runtime.debug.anchorStats.mutations = {}
    end
    return Runtime.debug.anchorStats
end

function Util.LogAnchorAuditSummary(reason, force)
    local stats = Runtime.debug.anchorStats
    if type(stats) ~= "table" then
        return
    end

    local mutationSummary = {}
    for key, value in pairs(stats.mutations or {}) do
        mutationSummary[#mutationSummary + 1] = Util.SafeToString(key) .. "=" .. Util.SafeToString(value)
    end
    table.sort(mutationSummary)

    local mutationText = "none"
    if #mutationSummary > 0 then
        local maxShown = 4
        if #mutationSummary <= maxShown then
            mutationText = table.concat(mutationSummary, ",")
        else
            local picked = {}
            for i = 1, maxShown do
                picked[#picked + 1] = mutationSummary[i]
            end
            picked[#picked + 1] = "...+" .. Util.SafeToString(#mutationSummary - maxShown)
            mutationText = table.concat(picked, ",")
        end
    end

end

function Util.LogAnchorAuditSnapshot(record, phase)
    if not Util.IsMapNavDebugWatchEnabled() then return end
    if type(record) ~= "table" then return end

    local map = _G.WorldMapFrame
    local layout = Runtime.layout
    local root = layout and layout.root or nil
    local navRow = layout and layout.navRow or nil
    local navHost = layout and layout.navHost or nil
    local navBar = Runtime.controls.navBar or (map and map.NavBar) or nil
    local controlsHost = layout and layout.controlsHost or nil
    local scroll = map and map.ScrollContainer or nil

    local expectedLeft = record.expectedLeft
    local expectedRight = record.expectedRight
    local rootLeft, rootRight, _, rootLeftErr, rootRightErr, rootCenterErr = Util.ComputeFrameEdgeMetrics(root, expectedLeft, expectedRight)
    local navRowLeft, navRowRight, _, navRowLeftErr, navRowRightErr, navRowCenterErr = Util.ComputeFrameEdgeMetrics(navRow, expectedLeft, expectedRight)
    local navHostLeft, navHostRight = Util.ComputeFrameEdgeMetrics(navHost, expectedLeft, expectedRight)
    local navBarLeft, navBarRight = Util.ComputeFrameEdgeMetrics(navBar, expectedLeft, expectedRight)
    local controlsLeft, controlsRight = Util.ComputeFrameEdgeMetrics(controlsHost, expectedLeft, expectedRight)

    local stats = Util.GetAnchorDebugStats()
    stats.samples = (stats.samples or 0) + 1
    stats.lastId = record.id
    stats.lastPhase = phase
    stats.lastReason = record.reason
    stats.lastRootCenterErr = rootCenterErr
    stats.lastNavRowCenterErr = navRowCenterErr
    if type(rootCenterErr) == "number" then
        local absErr = math.abs(rootCenterErr)
        if absErr > (stats.maxRootCenterErrAbs or -1) then
            stats.maxRootCenterErrAbs = absErr
            stats.maxRootCenterErr = rootCenterErr
            stats.maxId = record.id
            stats.maxPhase = phase
            stats.maxReason = record.reason
        end
    end

    if phase == "apply" or phase == "post+0.20" then
    end
end

function Util.BuildFrameMetricsLine(label, frame)
    if not frame then
        return Util.SafeToString(label) .. "=nil"
    end
    local shown = (frame.IsShown and frame:IsShown()) and "true" or "false"
    local visible = (frame.IsVisible and frame:IsVisible()) and "true" or "false"
    local alpha = Util.SafeMethodRead(frame, "GetAlpha")
    local parent = Util.SafeMethodRead(frame, "GetParent")
    local parentShown = (parent and parent.IsShown and parent:IsShown()) and "true" or "false"
    local parentVisible = (parent and parent.IsVisible and parent:IsVisible()) and "true" or "false"
    local strata = Util.SafeMethodRead(frame, "GetFrameStrata")
    local level = Util.SafeMethodRead(frame, "GetFrameLevel")
    local parentLevel = Util.SafeMethodRead(parent, "GetFrameLevel")
    local scale = Util.SafeMethodRead(frame, "GetScale")
    local effectiveScale = Util.SafeMethodRead(frame, "GetEffectiveScale")
    local width = frame.GetWidth and frame:GetWidth() or nil
    local height = frame.GetHeight and frame:GetHeight() or nil
    local pixelWidth = (type(width) == "number" and type(effectiveScale) == "number") and (width * effectiveScale) or nil
    local pixelHeight = (type(height) == "number" and type(effectiveScale) == "number") and (height * effectiveScale) or nil
    return string.format(
        "%s=%s shown=%s visible=%s alpha=%s strata=%s level=%s parent=%s parentShown=%s parentVisible=%s parentLevel=%s L=%s R=%s T=%s B=%s W=%s H=%s scale=%s eScale=%s pixelW=%s pixelH=%s",
        Util.SafeToString(label),
        Util.GetFrameDebugName(frame),
        shown,
        visible,
        Util.FormatNumber(alpha),
        Util.SafeToString(strata),
        Util.SafeToString(level),
        Util.GetFrameDebugName(parent),
        parentShown,
        parentVisible,
        Util.SafeToString(parentLevel),
        Util.FormatNumber(frame.GetLeft and frame:GetLeft() or nil),
        Util.FormatNumber(frame.GetRight and frame:GetRight() or nil),
        Util.FormatNumber(frame.GetTop and frame:GetTop() or nil),
        Util.FormatNumber(frame.GetBottom and frame:GetBottom() or nil),
        Util.FormatNumber(width),
        Util.FormatNumber(height),
        Util.FormatNumber(scale),
        Util.FormatNumber(effectiveScale),
        Util.FormatNumber(pixelWidth),
        Util.FormatNumber(pixelHeight)
    )
end

function Util.ComputeFrameWidthDelta(leftFrame, rightFrame)
    local leftWidth = leftFrame and leftFrame.GetWidth and leftFrame:GetWidth() or nil
    local rightWidth = rightFrame and rightFrame.GetWidth and rightFrame:GetWidth() or nil
    if type(leftWidth) ~= "number" or type(rightWidth) ~= "number" then return "nil" end
    return Util.FormatNumber(leftWidth - rightWidth)
end

function Util.ComputeFramePixelWidthDelta(leftFrame, rightFrame)
    local leftWidth = leftFrame and leftFrame.GetWidth and leftFrame:GetWidth() or nil
    local rightWidth = rightFrame and rightFrame.GetWidth and rightFrame:GetWidth() or nil
    local leftScale = Util.SafeMethodRead(leftFrame, "GetEffectiveScale")
    local rightScale = Util.SafeMethodRead(rightFrame, "GetEffectiveScale")
    if type(leftWidth) ~= "number" or type(rightWidth) ~= "number" then return "nil" end
    if type(leftScale) ~= "number" or type(rightScale) ~= "number" then return "nil" end
    return Util.FormatNumber((leftWidth * leftScale) - (rightWidth * rightScale))
end

function Util.ComputeVisibleCanvasWidthInScrollUnits(scroll, canvas)
    local scrollWidth = scroll and scroll.GetWidth and scroll:GetWidth() or nil
    local canvasWidth = canvas and canvas.GetWidth and canvas:GetWidth() or nil
    local canvasScale = Util.SafeMethodRead(scroll, "GetCanvasScale")
    local panX, panY, panSource = Util.ResolvePanTargetX(scroll)
    local scrollLeft = scroll and scroll.GetLeft and scroll:GetLeft() or nil
    local scrollRight = scroll and scroll.GetRight and scroll:GetRight() or nil
    local canvasLeft = canvas and canvas.GetLeft and canvas:GetLeft() or nil
    local canvasRight = canvas and canvas.GetRight and canvas:GetRight() or nil
    local scrollScale = Util.SafeMethodRead(scroll, "GetEffectiveScale")
    local canvasEffectiveScale = Util.SafeMethodRead(canvas, "GetEffectiveScale")

    if type(scrollScale) ~= "number" or scrollScale <= 0 then
        scrollScale = 1
    end
    if type(canvasEffectiveScale) ~= "number" or canvasEffectiveScale <= 0 then
        local canvasScaleFallback = canvas and canvas.GetScale and canvas:GetScale() or nil
        if type(canvasScaleFallback) == "number" and canvasScaleFallback > 0 then
            canvasEffectiveScale = scrollScale * canvasScaleFallback
        else
            canvasEffectiveScale = nil
        end
    end
    if type(canvasScale) ~= "number" or canvasScale <= 0 then
        if type(canvasEffectiveScale) == "number" and canvasEffectiveScale > 0 and scrollScale > 0 then
            canvasScale = canvasEffectiveScale / scrollScale
        else
            canvasScale = canvas and canvas.GetScale and canvas:GetScale() or nil
        end
    end
    if type(scrollWidth) ~= "number" or scrollWidth <= 0 then
        return nil, nil, nil, nil, 0, 0, "invalid", panX, nil, panSource, panY
    end

    if type(canvasWidth) ~= "number" or canvasWidth <= 0 then
        return scrollWidth, nil, scrollWidth, 0, 0, 0, "scroll", panX, 0, panSource, panY
    end
    if type(canvasScale) ~= "number" or canvasScale <= 0 then
        return scrollWidth, nil, scrollWidth, 0, 0, 0, "scroll", panX, 0, panSource, panY
    end

    local projected = canvasWidth * canvasScale
    if type(canvasEffectiveScale) == "number" and canvasEffectiveScale > 0 and scrollScale > 0 then
        projected = canvasWidth * (canvasEffectiveScale / scrollScale)
    end

    local scrollWidthPixels = scrollWidth * scrollScale
    if type(scrollLeft) == "number" and type(scrollRight) == "number"
        and type(canvasLeft) == "number" and type(canvasRight) == "number"
        and scrollRight > scrollLeft and canvasRight > canvasLeft then
        local scrollLeftPixels = scrollLeft * scrollScale
        local scrollRightPixels = scrollRight * scrollScale
        if type(canvasEffectiveScale) == "number" and canvasEffectiveScale > 0 then
            local canvasLeftPixels = canvasLeft * canvasEffectiveScale
            local canvasRightPixels = canvasRight * canvasEffectiveScale

            if canvasRightPixels > canvasLeftPixels and scrollRightPixels > scrollLeftPixels then
                local visibleLeftPixels = scrollLeftPixels
                local visibleRightPixels = scrollRightPixels
                if canvasLeftPixels > visibleLeftPixels then visibleLeftPixels = canvasLeftPixels end
                if canvasRightPixels < visibleRightPixels then visibleRightPixels = canvasRightPixels end

                local visiblePixels = visibleRightPixels - visibleLeftPixels
                if visiblePixels < 0 then visiblePixels = 0 end
                if visiblePixels > scrollWidthPixels then visiblePixels = scrollWidthPixels end

                local projectedPixels = projected * scrollScale
                local expectedPixels = projectedPixels
                if expectedPixels > scrollWidthPixels then expectedPixels = scrollWidthPixels end

                -- Canvas edge coordinates can momentarily lag behind zoom/pan updates.
                -- If intersection and projected fit diverge too far, trust projected this frame.
                local diffPixels = math.abs(visiblePixels - expectedPixels)
                local diffTolerance = math.max(4, scrollWidthPixels * 0.08)
                if diffPixels <= diffTolerance then
                    local visible = visiblePixels / scrollScale
                    local gap = scrollWidth - visible
                    if gap < 0 then gap = 0 end
                    local sideGap = gap * 0.5
                    if sideGap < 0 then sideGap = 0 end

                    local leftInset = (visibleLeftPixels - scrollLeftPixels) / scrollScale
                    local rightInset = (visibleRightPixels - scrollRightPixels) / scrollScale
                    if gap <= 0.001 then
                        leftInset = 0
                        rightInset = 0
                    end

                    return scrollWidth, projected, visible, sideGap, leftInset, rightInset, "intersection:scaled", panX, gap, panSource, panY
                end
            end
        end
    end

    local visible = projected
    if visible > scrollWidth then visible = scrollWidth end
    if visible < 0 then visible = 0 end
    local gap = scrollWidth - visible
    if gap < 0 then gap = 0 end

    -- When the projected canvas is narrower than the viewport (fully zoomed out
    -- or near it), keep the header centered over the visible map width.
    -- This avoids subtle left/right drift caused by transient pan targets.
    local leftInset = gap * 0.5
    local rightInset = -leftInset
    local fitMode = "projected:centered"
    if gap <= 0.001 then
        leftInset = 0
        rightInset = 0
    end

    local sideGap = gap * 0.5
    if sideGap < 0 then sideGap = 0 end
    return scrollWidth, projected, visible, sideGap, leftInset, rightInset, fitMode, panX, gap, panSource, panY
end

function Util.BuildScrollZoomSummary(scroll)
    if not scroll then return "zoom[scroll=nil]" end
    local normalized = Util.SafeMethodRead(scroll, "GetNormalizedZoom")
    local current = Util.SafeMethodRead(scroll, "GetCurrentZoom")
    local minZoom = Util.SafeMethodRead(scroll, "GetMinZoom")
    local maxZoom = Util.SafeMethodRead(scroll, "GetMaxZoom")
    local canvasScale = Util.SafeMethodRead(scroll, "GetCanvasScale")
    local zoomTarget = Util.SafeMethodRead(scroll, "GetZoomTarget")
    return string.format(
        "zoom[norm=%s curr=%s min=%s max=%s canvasScale=%s target=%s]",
        Util.FormatDebugValue(normalized),
        Util.FormatDebugValue(current),
        Util.FormatDebugValue(minZoom),
        Util.FormatDebugValue(maxZoom),
        Util.FormatDebugValue(canvasScale),
        Util.FormatDebugValue(zoomTarget)
    )
end

function Util.GetOrderedNavButtons(navBar)
    local ordered = {}
    if not navBar then return ordered end
    local seen = {}

    local home = navBar.home or navBar.homeButton
    if home and type(home.IsShown) == "function" and home:IsShown() then
        ordered[#ordered + 1] = home
        seen[home] = true
    end

    if type(navBar.navList) == "table" then
        for i = 1, #navBar.navList do
            local button = navBar.navList[i]
            if button and (not seen[button]) and type(button.IsShown) == "function" and button:IsShown() then
                ordered[#ordered + 1] = button
                seen[button] = true
            end
        end
    end
    return ordered
end

function Util.ComputeTabOverlap(leftButton, rightButton)
    if not leftButton or not rightButton then return nil end
    local leftRight = leftButton.GetRight and leftButton:GetRight()
    local rightLeft = rightButton.GetLeft and rightButton:GetLeft()
    if type(leftRight) ~= "number" or type(rightLeft) ~= "number" then return nil end
    local overlap = leftRight - rightLeft
    if overlap > 0.25 then return overlap end
    return nil
end

function Util.BuildNavButtonStateLine(button)
    if not button then return "button=nil" end

    local textObject = UI.GetNavButtonTextObject(button)
    local textValue = textObject and textObject.GetText and textObject:GetText() or nil
    local tr, tg, tb, ta = nil, nil, nil, nil
    if textObject and textObject.GetTextColor then
        tr, tg, tb, ta = textObject:GetTextColor()
    end

    local hr, hg, hb, ha = nil, nil, nil, nil
    local hoverAlpha = nil
    if button._muiMapSimpleHover then
        if button._muiMapSimpleHover.GetVertexColor then
            hr, hg, hb, ha = button._muiMapSimpleHover:GetVertexColor()
        end
        if button._muiMapSimpleHover.GetAlpha then
            hoverAlpha = button._muiMapSimpleHover:GetAlpha()
        end
    end

    local ir, ig, ib, ia = nil, nil, nil, nil
    if button.MenuArrowButton and button.MenuArrowButton._muiMapNavMenuArrow
        and button.MenuArrowButton._muiMapNavMenuArrow.left
        and button.MenuArrowButton._muiMapNavMenuArrow.left.GetVertexColor then
        ir, ig, ib, ia = button.MenuArrowButton._muiMapNavMenuArrow.left:GetVertexColor()
    end

    local role = button._muiMapNavRole or "crumb"
    local indexText = Util.SafeToString(button._muiMapNavIndex)
    local enabled = (button.IsEnabled and button:IsEnabled()) and "true" or "false"
    local shown = (button.IsShown and button:IsShown()) and "true" or "false"

    return string.format(
        "%s role=%s idx=%s shown=%s enabled=%s text=\"%s\" geom[L=%s R=%s W=%s] textColor=%s hoverColor=%s hoverAlpha=%s iconColor=%s",
        Util.GetFrameDebugName(button),
        Util.SafeToString(role),
        indexText,
        shown,
        enabled,
        Util.SafeToString(textValue),
        Util.FormatNumber(button.GetLeft and button:GetLeft() or nil),
        Util.FormatNumber(button.GetRight and button:GetRight() or nil),
        Util.FormatNumber(button.GetWidth and button:GetWidth() or nil),
        Util.FormatColor(tr, tg, tb, ta),
        Util.FormatColor(hr, hg, hb, ha),
        Util.FormatNumber(hoverAlpha),
        Util.FormatColor(ir, ig, ib, ia)
    )
end

function UI.EnsureDropdownArrow(dropdown)
    if not dropdown then return nil end
    if dropdown._muiMapDropdownArrow then return dropdown._muiMapDropdownArrow end

    local r, g, b = UI.GetAccentColor()
    local arrow = CreateFrame("Frame", nil, dropdown)
    arrow:SetSize(C.ARROW_WIDTH, C.ARROW_HEIGHT)
    arrow:EnableMouse(false)
    arrow:SetFrameStrata("HIGH")
    arrow:SetFrameLevel(dropdown:GetFrameLevel() + 10)

    local shadowLeft = arrow:CreateTexture(nil, "OVERLAY", nil, 4)
    shadowLeft:SetTexture(C.WHITE8X8)
    shadowLeft:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    shadowLeft:SetPoint("CENTER", arrow, "CENTER", -C.ARROW_STROKE_X_OFFSET, -1)
    shadowLeft:SetRotation(-C.ARROW_ROTATION)
    shadowLeft:SetVertexColor(0, 0, 0, 0.6)
    arrow.shadowLeft = shadowLeft

    local shadowRight = arrow:CreateTexture(nil, "OVERLAY", nil, 4)
    shadowRight:SetTexture(C.WHITE8X8)
    shadowRight:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    shadowRight:SetPoint("CENTER", arrow, "CENTER", C.ARROW_STROKE_X_OFFSET, -1)
    shadowRight:SetRotation(C.ARROW_ROTATION)
    shadowRight:SetVertexColor(0, 0, 0, 0.6)
    arrow.shadowRight = shadowRight

    local left = arrow:CreateTexture(nil, "OVERLAY", nil, 5)
    left:SetTexture(C.WHITE8X8)
    left:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    left:SetPoint("CENTER", arrow, "CENTER", -C.ARROW_STROKE_X_OFFSET, 0)
    left:SetRotation(-C.ARROW_ROTATION)
    left:SetVertexColor(r, g, b, 0.95)
    arrow.left = left

    local right = arrow:CreateTexture(nil, "OVERLAY", nil, 5)
    right:SetTexture(C.WHITE8X8)
    right:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    right:SetPoint("CENTER", arrow, "CENTER", C.ARROW_STROKE_X_OFFSET, 0)
    right:SetRotation(C.ARROW_ROTATION)
    right:SetVertexColor(r, g, b, 0.95)
    arrow.right = right

    dropdown._muiMapDropdownArrow = arrow
    return arrow
end

function UI.EnsureNavMenuArrow(menuButton)
    if not menuButton then return nil end
    if menuButton._muiMapNavMenuArrow then return menuButton._muiMapNavMenuArrow end

    local r, g, b = UI.GetAccentColor()
    local arrow = CreateFrame("Frame", nil, menuButton)
    arrow:SetSize(C.ARROW_WIDTH, C.ARROW_HEIGHT)
    arrow:EnableMouse(false)
    arrow:SetFrameStrata("HIGH")
    arrow:SetFrameLevel(menuButton:GetFrameLevel() + 10)

    local shadowLeft = arrow:CreateTexture(nil, "OVERLAY", nil, 4)
    shadowLeft:SetTexture(C.WHITE8X8)
    shadowLeft:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    shadowLeft:SetPoint("CENTER", arrow, "CENTER", -C.ARROW_STROKE_X_OFFSET, -1)
    shadowLeft:SetRotation(-C.ARROW_ROTATION)
    shadowLeft:SetVertexColor(0, 0, 0, 0.6)
    arrow.shadowLeft = shadowLeft

    local shadowRight = arrow:CreateTexture(nil, "OVERLAY", nil, 4)
    shadowRight:SetTexture(C.WHITE8X8)
    shadowRight:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    shadowRight:SetPoint("CENTER", arrow, "CENTER", C.ARROW_STROKE_X_OFFSET, -1)
    shadowRight:SetRotation(C.ARROW_ROTATION)
    shadowRight:SetVertexColor(0, 0, 0, 0.6)
    arrow.shadowRight = shadowRight

    local left = arrow:CreateTexture(nil, "OVERLAY", nil, 5)
    left:SetTexture(C.WHITE8X8)
    left:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    left:SetPoint("CENTER", arrow, "CENTER", -C.ARROW_STROKE_X_OFFSET, 0)
    left:SetRotation(-C.ARROW_ROTATION)
    left:SetVertexColor(r, g, b, 0.95)
    arrow.left = left

    local right = arrow:CreateTexture(nil, "OVERLAY", nil, 5)
    right:SetTexture(C.WHITE8X8)
    right:SetSize(C.ARROW_STROKE_LENGTH, C.ARROW_STROKE_THICKNESS)
    right:SetPoint("CENTER", arrow, "CENTER", C.ARROW_STROKE_X_OFFSET, 0)
    right:SetRotation(C.ARROW_ROTATION)
    right:SetVertexColor(r, g, b, 0.95)
    arrow.right = right

    menuButton._muiMapNavMenuArrow = arrow
    return arrow
end

function UI.SetVerticalGradient(texture, r1, g1, b1, a1, r2, g2, b2, a2)
    if not texture then return end
    if type(texture.SetGradientAlpha) == "function" then
        texture:SetGradientAlpha("VERTICAL", r1, g1, b1, a1, r2, g2, b2, a2)
    elseif type(texture.SetGradient) == "function" and type(CreateColor) == "function" then
        texture:SetGradient("VERTICAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    end
end

function UI.SetHorizontalGradient(texture, r1, g1, b1, a1, r2, g2, b2, a2)
    if not texture then return end
    if type(texture.SetGradientAlpha) == "function" then
        texture:SetGradientAlpha("HORIZONTAL", r1, g1, b1, a1, r2, g2, b2, a2)
    elseif type(texture.SetGradient) == "function" and type(CreateColor) == "function" then
        texture:SetGradient("HORIZONTAL", CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    end
end

-- ============================================================================
-- MODERN FLAT CHROME REDESIGN
-- ============================================================================
function UI.EnsureControlChrome(control)
    if control._muiMapChrome then return control._muiMapChrome end

    local r, g, b = UI.GetAccentColor()
    local chrome = {}

    UI.SuppressControlHighlight(control)

    -- Flat Background
    local bg = control:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    local bgR, bgG, bgB = C.GetThemeColor("bgPanelRaised")
    bg:SetVertexColor(bgR, bgG, bgB, 0.95)
    chrome.bg = bg

    -- Sleek unified border (darker than background for inset look)
    local border = control:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetTexture(C.WHITE8X8)
    local borderR, borderG, borderB = C.GetThemeColor("border")
    border:SetVertexColor(borderR, borderG, borderB, 0.86)
    chrome.border = border

    -- Warm accent underline indicator (defaults to alpha 0)
    local accent = control:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("BOTTOMLEFT", 0, 0)
    accent:SetPoint("BOTTOMRIGHT", 0, 0)
    accent:SetHeight(2)
    accent:SetTexture(C.WHITE8X8)
    accent:SetVertexColor(r, g, b, 1)
    accent:SetAlpha(0)
    chrome.accent = accent

    -- Soft Hover Overlay
    local hover = control:CreateTexture(nil, "BACKGROUND", nil, -2)
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetVertexColor(r, g, b, 0.18)
    hover:SetAlpha(0)
    chrome.hover = hover

    if not control._muiMapChromeHooked and type(control.HookScript) == "function" then
        control:HookScript("OnEnter", function(self)
            UI.SuppressControlHighlight(self)
            if self._muiMapChrome then
                self._muiMapChrome.hover:SetAlpha(1)
                self._muiMapChrome.accent:SetAlpha(1)
            end
        end)
        control:HookScript("OnLeave", function(self)
            if self._muiMapChrome then
                self._muiMapChrome.hover:SetAlpha(0)
                if not self.isActive then -- pin logic
                    self._muiMapChrome.accent:SetAlpha(0)
                end
            end
        end)
        control:HookScript("OnMouseDown", function(self)
            if self._muiMapChrome then
                local darkR, darkG, darkB = C.GetThemeColor("accentDark")
                self._muiMapChrome.hover:SetVertexColor(darkR, darkG, darkB, 0.26)
            end
        end)
        control:HookScript("OnMouseUp", function(self)
            if self._muiMapChrome then
                self._muiMapChrome.hover:SetVertexColor(r, g, b, 0.18)
            end
        end)
        control._muiMapChromeHooked = true
    end

    control._muiMapChrome = chrome
    return chrome
end

function UI.GetControlIconColor(isHovered)
    if isHovered then
        local r, g, b = UI.GetAccentColor()
        return UI.GetReadableHoverTextColorForAccent(r, g, b)
    end
    local textR, textG, textB = C.GetThemeColor("textPrimary")
    return textR, textG, textB, 1
end

function UI.ApplyControlIconColor(button, isHovered)
    if not button or not button.Icon then return end
    local r, g, b, a = UI.GetControlIconColor(isHovered)
    if type(button.Icon.Show) == "function" then
        button.Icon:Show()
    end
    if type(button.Icon.SetAlpha) == "function" then
        button.Icon:SetAlpha(1)
    end
    if type(button.Icon.SetVertexColor) == "function" then
        button.Icon:SetVertexColor(r, g, b, a or 1)
    end
end

function UI.EnsureControlIconHooks(button)
    if not button or button._muiMapControlIconHooks or type(button.HookScript) ~= "function" then return end
    button:HookScript("OnShow", function(self)
        UI.ApplyControlIconColor(self, type(self.IsMouseOver) == "function" and self:IsMouseOver())
    end)
    button:HookScript("OnEnter", function(self)
        UI.ApplyControlIconColor(self, true)
    end)
    button:HookScript("OnLeave", function(self)
        UI.ApplyControlIconColor(self, false)
    end)
    button._muiMapControlIconHooks = true
end

function UI.ApplyQuestPanelMinimizeButtonVisual(button, isHovered)
    if not button then return end
    local borderR, borderG, borderB = C.GetThemeColor("borderStrong")
    local bgR, bgG, bgB = C.GetThemeColor("bgPanelRaised")
    local accentR, accentG, accentB = UI.GetAccentColor()

    if button._muiMinimizeBg and type(button._muiMinimizeBg.SetVertexColor) == "function" then
        if isHovered then
            button._muiMinimizeBg:SetVertexColor(bgR, bgG, bgB, 0.88)
        else
            button._muiMinimizeBg:SetVertexColor(bgR, bgG, bgB, 0.66)
        end
    end
    if button._muiMinimizeBorder and type(button._muiMinimizeBorder.SetVertexColor) == "function" then
        if isHovered then
            button._muiMinimizeBorder:SetVertexColor(accentR, accentG, accentB, 0.92)
        else
            button._muiMinimizeBorder:SetVertexColor(borderR, borderG, borderB, 0.84)
        end
    end

    UI.ApplyControlIconColor(button, isHovered == true)
end

function UI.GetQuestPanelAnchorTarget(map)
    -- Anchor to WorldMapFrame directly so the quest panel is not subject to
    -- ScrollContainer visibility/ordering transitions.
    if map then
        return map
    end
    return map
end

function UI.GetQuestPanelOpenOffset()
    return 0
end

function UI.GetQuestPanelClosedOffset()
    return 0
end

function UI.GetQuestPanelSlideDistance()
    return 0
end

function UI.GetQuestPanelShownOffset()
    return 0
end

function UI.GetQuestPanelHiddenOffset()
    return 0
end

function UI.GetQuestPanelWidth()
    -- Return the actual new panel width (no scale multiplier)
    if Addon.QuestLogConfig and type(Addon.QuestLogConfig.PANEL_WIDTH) == "number" then
        return Addon.QuestLogConfig.PANEL_WIDTH
    end
    return type(C.QUEST_LOG_PANEL_WIDTH) == "number" and C.QUEST_LOG_PANEL_WIDTH or 380
end

function UI.GetQuestPanelHorizontalCorrection(map)
    if not map then return 0 end
    local scroll = map.ScrollContainer

    local mapRight = type(map.GetRight) == "function" and map:GetRight() or nil
    if type(mapRight) ~= "number" then
        return 0
    end

    local visualRight = nil
    if map.BorderFrame and type(map.BorderFrame.GetRight) == "function" then
        visualRight = map.BorderFrame:GetRight()
    end
    if type(visualRight) ~= "number" and scroll and type(scroll.GetRight) == "function" then
        visualRight = scroll:GetRight()
    end
    if type(visualRight) ~= "number" then
        return 0
    end

    -- Keep panel spacing constant across zoom states by correcting against a
    -- stable frame edge (border/scroll), not dynamic zoom-fit insets.
    local correction = visualRight - mapRight
    return Util.Clamp(correction, -320, 80)
end

function UI.SetQuestPanelAnchors(panel, map, xOffset)
    if not panel or not map then return end
    local target = UI.GetQuestPanelAnchorTarget(map)
    if not target then return end

    local offset = type(xOffset) == "number" and xOffset or UI.GetQuestPanelShownOffset()
    local correction = UI.GetQuestPanelHorizontalCorrection(map)
    local hiddenOffset = UI.GetQuestPanelHiddenOffset()
    local minOutsideGap = type(C.QUEST_LOG_PANEL_MIN_OUTSIDE_GAP) == "number" and C.QUEST_LOG_PANEL_MIN_OUTSIDE_GAP or 2
    if minOutsideGap < 0 then
        minOutsideGap = 0
    end

    -- Guardrail: never allow correction to pull the panel inside the map frame.
    local minCorrection = minOutsideGap - hiddenOffset
    if correction < minCorrection then
        correction = minCorrection
    end

    local correctedOffset = offset + correction
    local panelWidth = UI.GetQuestPanelWidth()
    -- Anchor quest panel to the scroll container so it matches the canvas
    -- height exactly, regardless of header height rounding.
    local scroll = map.ScrollContainer
    local anchorFrame = scroll or target

    -- Diff check: skip ClearAllPoints if anchor is already correct
    local needsUpdate = true
    if panel:GetNumPoints() == 2 then
        local pt1, rel1, relPt1, x1, y1 = panel:GetPoint(1)
        local pt2, rel2, relPt2, x2, y2 = panel:GetPoint(2)
        if pt1 == "TOPLEFT" and rel1 == anchorFrame and relPt1 == "TOPRIGHT"
            and pt2 == "BOTTOMLEFT" and rel2 == anchorFrame and relPt2 == "BOTTOMRIGHT"
            and math.abs((x1 or 0) - correctedOffset) < 0.5
            and math.abs((x2 or 0) - correctedOffset) < 0.5
            and math.abs(panel:GetWidth() - panelWidth) < 0.5 then
            needsUpdate = false
        end
    end

    if needsUpdate then
        panel:ClearAllPoints()
        panel:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", correctedOffset, 0)
        panel:SetPoint("BOTTOMLEFT", anchorFrame, "BOTTOMRIGHT", correctedOffset, 0)
        panel:SetWidth(panelWidth)
    end

end

function UI.QueueQuestPanelAnchorSettle(map, reason)
    local worldMap = map or _G.WorldMapFrame
    if not worldMap then return end
    if not C_Timer or type(C_Timer.After) ~= "function" then return end

    Runtime.questPanelAnchorSyncToken = (Runtime.questPanelAnchorSyncToken or 0) + 1
    local token = Runtime.questPanelAnchorSyncToken
    local baseReason = Util.SafeToString(reason or "unknown")

    local function Apply(tag)
        if Runtime.questPanelAnchorSyncToken ~= token then return end
        if not worldMap or not worldMap.IsShown or not worldMap:IsShown() then return end
        local panel = worldMap._muiQuestLogPanel
        if not panel then return end
        if panel._muiQuestPanelAnimating then return end

        local isOpen = (Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function" and Addon.QuestLogPanel.IsOpen())
            or (Runtime.questLogPanelOpen == true) or (panel._muiQuestPanelDesiredOpen == true)
        UI.SetQuestPanelAnchors(panel, worldMap, isOpen and UI.GetQuestPanelShownOffset() or UI.GetQuestPanelHiddenOffset())

        if Util.IsMapNavDebugEnabled() and Util.ShouldEmitDebugToken("questPanelAnchorSettle:" .. baseReason, 0.10) then
        end
    end

    C_Timer.After(0, function() Apply("t+0.00") end)
    C_Timer.After(0.25, function() Apply("t+0.25") end)
end

function UI.RefreshQuestLogButtonState()
    local button = Runtime.controls and Runtime.controls.questLogButton or nil
    if not button then
        local map = _G.WorldMapFrame
        button = map and map._muiQuestLogButton or nil
    end
    if not button then return end

    local isOpen = (Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function") and Addon.QuestLogPanel.IsOpen() or false
    Runtime.questLogPanelOpen = isOpen
    local isOver = type(button.IsMouseOver) == "function" and button:IsMouseOver() or false
    button.isActive = isOpen
    if button._muiMapChrome and button._muiMapChrome.accent then
        button._muiMapChrome.accent:SetAlpha((button.isActive or isOver) and 1 or 0)
    end
    UI.ApplyControlIconColor(button, isOver)
end

function UI.GetQuestDisplayModeValue(modeKey)
    if type(_G.QuestLogDisplayMode) ~= "table" then return nil end
    return _G.QuestLogDisplayMode[modeKey]
end

function UI.GetQuestPanelTabLabel(modeKey)
    if modeKey == "Events" then
        return _G.EVENT_SCHEDULER_FRAME_LABEL or "Events"
    elseif modeKey == "MapLegend" then
        return _G.MAP_LEGEND_FRAME_LABEL or "Map Legend"
    end
    return _G.QUESTS_LABEL or "Quests"
end

function UI.GetQuestPanelModeSubtitle(modeKey)
    if modeKey == "Events" then
        return "Live event activity and objectives"
    elseif modeKey == "MapLegend" then
        return "Map symbols, hubs, and points of interest"
    end
    return "Tracked quests and objective progress"
end

Addon._MapQuestPanelModeStyles = Addon._MapQuestPanelModeStyles or {
    Quests = {
        accent = { 0.7765, 0.6706, 0.4549 },
        bannerLabel = "Quest Flow",
        bannerHint = "Tracked storylines and active objective chains",
    },
    Events = {
        accent = { 0.8392, 0.5882, 0.3333 },
        bannerLabel = "Event Flow",
        bannerHint = "Live activities, schedules, and rotating objectives",
    },
    MapLegend = {
        accent = { 0.6824, 0.6275, 0.4941 },
        bannerLabel = "Legend Flow",
        bannerHint = "Map symbols, hubs, and icon reference guide",
    },
}

function Addon.GetMapQuestPanelModeStyle(modeKey)
    local style = Addon._MapQuestPanelModeStyles and Addon._MapQuestPanelModeStyles[modeKey]
    if style and type(style.accent) == "table" then
        return style
    end
    return Addon._MapQuestPanelModeStyles and Addon._MapQuestPanelModeStyles.Quests or {
        accent = { 0.7569, 0.6667, 0.4627 },
        bannerLabel = "Quest Flow",
        bannerHint = "Tracked quests and objective progress",
    }
end

function UI.ApplyQuestPanelHeaderState(panel, modeKey)
    if not panel then return end

    local modeStyle = Addon.GetMapQuestPanelModeStyle(modeKey)
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]

    if panel._muiHeaderModeBadge and panel._muiHeader
        and type(panel._muiHeaderModeBadge.ClearAllPoints) == "function"
        and type(panel._muiHeaderModeBadge.SetPoint) == "function"
        and type(panel._muiHeaderModeBadge.SetSize) == "function" then
        panel._muiHeaderModeBadge:ClearAllPoints()
        panel._muiHeaderModeBadge:SetPoint("TOPRIGHT", panel._muiHeader, "TOPRIGHT", -10, -7)
        panel._muiHeaderModeBadge:SetSize(22, 22)
    end
    if panel._muiHeaderMinimizeButton and panel._muiHeaderModeBadge
        and type(panel._muiHeaderMinimizeButton.ClearAllPoints) == "function"
        and type(panel._muiHeaderMinimizeButton.SetPoint) == "function" then
        panel._muiHeaderMinimizeButton:ClearAllPoints()
        panel._muiHeaderMinimizeButton:SetPoint("RIGHT", panel._muiHeaderModeBadge, "LEFT", -4, 0)
        if type(panel._muiHeaderMinimizeButton.SetFrameLevel) == "function" and type(panel._muiHeaderModeBadge.GetFrameLevel) == "function" then
            panel._muiHeaderMinimizeButton:SetFrameLevel(panel._muiHeaderModeBadge:GetFrameLevel() + 2)
        end
    end

    if panel._muiHeaderModeText and type(panel._muiHeaderModeText.SetText) == "function" then
        panel._muiHeaderModeText:SetText("")
        if type(panel._muiHeaderModeText.Hide) == "function" then
            panel._muiHeaderModeText:Hide()
        end
    end
    if panel._muiHeaderSubTitle and type(panel._muiHeaderSubTitle.SetText) == "function" then
        panel._muiHeaderSubTitle:SetText("")
        if type(panel._muiHeaderSubTitle.Hide) == "function" then
            panel._muiHeaderSubTitle:Hide()
        end
    end

    if panel._muiHeaderModeBg then
        if type(panel._muiHeaderModeBg.SetVertexColor) == "function" then
            panel._muiHeaderModeBg:SetVertexColor(0, 0, 0, 0)
        end
        if type(panel._muiHeaderModeBg.Hide) == "function" then
            panel._muiHeaderModeBg:Hide()
        end
    end
    if panel._muiHeaderModeBorder then
        if type(panel._muiHeaderModeBorder.SetVertexColor) == "function" then
            panel._muiHeaderModeBorder:SetVertexColor(0, 0, 0, 0)
        end
        if type(panel._muiHeaderModeBorder.Hide) == "function" then
            panel._muiHeaderModeBorder:Hide()
        end
    end
    if panel._muiHeaderModeText and type(panel._muiHeaderModeText.SetTextColor) == "function" then
        panel._muiHeaderModeText:SetTextColor(accentR, accentG, accentB, 1)
    end

    -- The content banner now hosts the campaign progress card.
    -- Remove legacy flow labels/accents from all tab modes.
    if panel._muiContentBannerLabel and type(panel._muiContentBannerLabel.SetText) == "function" then
        panel._muiContentBannerLabel:SetText("")
        if type(panel._muiContentBannerLabel.Hide) == "function" then
            panel._muiContentBannerLabel:Hide()
        end
    end
    if panel._muiContentBannerHint and type(panel._muiContentBannerHint.SetText) == "function" then
        panel._muiContentBannerHint:SetText("")
        if type(panel._muiContentBannerHint.Hide) == "function" then
            panel._muiContentBannerHint:Hide()
        end
    end
    if panel._muiContentBannerAccent then
        if type(panel._muiContentBannerAccent.SetVertexColor) == "function" then
            panel._muiContentBannerAccent:SetVertexColor(accentR, accentG, accentB, 0)
        end
        if type(panel._muiContentBannerAccent.SetAlpha) == "function" then
            panel._muiContentBannerAccent:SetAlpha(0)
        end
    end
    if panel._muiContentBannerEdge then
        if type(panel._muiContentBannerEdge.SetVertexColor) == "function" then
            panel._muiContentBannerEdge:SetVertexColor(accentR, accentG, accentB, 0)
        end
        if type(panel._muiContentBannerEdge.SetAlpha) == "function" then
            panel._muiContentBannerEdge:SetAlpha(0)
        end
    end
    if panel._muiContentInnerBorder and type(panel._muiContentInnerBorder.SetVertexColor) == "function" then
        panel._muiContentInnerBorder:SetVertexColor(accentR, accentG, accentB, 0.45)
    end
    if panel._muiContentInnerGlow and type(panel._muiContentInnerGlow.SetGradientAlpha) == "function" then
        panel._muiContentInnerGlow:SetGradientAlpha("VERTICAL", accentR, accentG, accentB, 0.22, accentR, accentG, accentB, 0.02)
    elseif panel._muiContentInnerGlow and type(panel._muiContentInnerGlow.SetVertexColor) == "function" then
        panel._muiContentInnerGlow:SetVertexColor(accentR, accentG, accentB, 0.10)
    end
end


function UI.ResolveQuestDisplayModeKey(questFrame, panel)
    if not questFrame then return "Unknown" end

    local displayMode = questFrame.displayMode
    for i = 1, #C.QUEST_TAB_MODE_KEYS do
        local key = C.QUEST_TAB_MODE_KEYS[i]
        local modeValue = key and UI.GetQuestDisplayModeValue(key) or nil
        if modeValue ~= nil and modeValue == displayMode then
            return key
        end
    end

    if panel and type(panel._muiTabOrder) == "table" then
        for i = 1, #panel._muiTabOrder do
            local tab = panel._muiTabOrder[i]
            if tab and tab._muiTabActive == true and type(tab._muiModeKey) == "string" then
                return tab._muiModeKey
            end
        end
    end
    return "Unknown"
end

function UI.IsQuestPanelDetailsActive(panel)
    return panel and panel._muiQuestDetailsActive == true
end

function UI.SetQuestPanelDetailsActive(panel, questID, sourceTag, titleHint)
    if not panel then return end
    panel._muiQuestDetailsActive = true
    panel._muiQuestDetailsQuestID = questID
    panel._muiQuestDetailsSource = sourceTag
    panel._muiQuestDetailsTitleHint = titleHint
end

function UI.ClearQuestPanelDetailsState(panel, sourceTag)
    if not panel then return end
    panel._muiQuestDetailsActive = false
    panel._muiQuestDetailsQuestID = nil
    panel._muiQuestDetailsSource = sourceTag
    panel._muiQuestDetailsTitleHint = nil
end

function Util.SafeGetObjectType(object)
    if not object or type(object.GetObjectType) ~= "function" then return nil end
    local ok, value = pcall(object.GetObjectType, object)
    if not ok then return nil end
    return value
end

function Util.SafeGetObjectName(object)
    if not object or type(object.GetName) ~= "function" then return nil end
    local ok, value = pcall(object.GetName, object)
    if not ok or type(value) ~= "string" or value == "" then return nil end
    return value
end

function Util.SafeGetDrawLayer(texture)
    if not texture or type(texture.GetDrawLayer) ~= "function" then return nil, nil end
    local ok, layer, subLevel = pcall(texture.GetDrawLayer, texture)
    if not ok then return nil, nil end
    return layer, subLevel
end

function Util.BuildQuestTabArtToken(atlas, textureValue)
    local atlasText = (type(atlas) == "string" and atlas ~= "") and atlas or nil
    local textureText = (type(textureValue) == "string" and textureValue ~= "") and textureValue or nil
    if atlasText and textureText then
        return "atlas:" .. atlasText .. "|tex:" .. textureText
    end
    if atlasText then return "atlas:" .. atlasText end
    if textureText then return "tex:" .. textureText end
    return "tex:nil"
end

function UI.GetQuestTabRootFrames(questFrame, modeKey)
    local roots = {}
    local seen = {}

    local function Add(frame)
        if not frame or seen[frame] then return end
        seen[frame] = true
        roots[#roots + 1] = frame
    end

    if modeKey == "Quests" then
        Add(questFrame.QuestsFrame)
        Add(questFrame.QuestsFrame and questFrame.QuestsFrame.ScrollFrame or nil)
        Add(_G.QuestScrollFrame)
    elseif modeKey == "Events" then
        Add(questFrame.EventsFrame)
        Add(questFrame.EventsFrame and questFrame.EventsFrame.ScrollBox or nil)
        Add(questFrame.EventsFrame and questFrame.EventsFrame.ScrollBox and questFrame.EventsFrame.ScrollBox.ScrollTarget or nil)
    elseif modeKey == "MapLegend" then
        Add(questFrame.MapLegend)
        Add(questFrame.MapLegend and questFrame.MapLegend.ScrollFrame or nil)
        Add(_G.MapLegendScrollFrame)
    end

    if #roots == 0 then
        Add(questFrame)
    end
    return roots
end

function UI.ApplyQuestPanelTabVisual(button, isHovered)
    if not button then return end
    local active = button._muiTabActive == true
    local disabled = button._muiTabDisabled == true
    local hovered = (isHovered == true) or (type(button.IsMouseOver) == "function" and button:IsMouseOver())
    local modeStyle = Addon.GetMapQuestPanelModeStyle(button._muiModeKey)
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]

    if disabled then
        hovered = false
    end

    -- Background: transparent normally, subtle fill on active/hover
    if button._muiTabBg then
        if disabled then
            button._muiTabBg:SetVertexColor(0, 0, 0, 0)
        elseif active then
            button._muiTabBg:SetVertexColor(0.12, 0.10, 0.06, 0.60)
        elseif hovered then
            button._muiTabBg:SetVertexColor(0.12, 0.10, 0.06, 0.35)
        else
            button._muiTabBg:SetVertexColor(0, 0, 0, 0)
        end
    end
    -- Border: invisible — tabs use underline, not boxes
    if button._muiTabBorder then
        button._muiTabBorder:SetVertexColor(0, 0, 0, 0)
    end
    -- Hover overlay
    if button._muiTabHover then
        button._muiTabHover:SetVertexColor(accentR, accentG, accentB, 0.10)
        button._muiTabHover:SetAlpha((hovered and not active and not disabled) and 1 or 0)
    end
    -- Bottom accent underline — the primary active indicator
    if button._muiTabAccent then
        button._muiTabAccent:SetVertexColor(accentR, accentG, accentB, 0.90)
        button._muiTabAccent:SetAlpha((active and not disabled) and 1 or 0)
    end
    -- Text
    if button._muiTabText and type(button._muiTabText.SetTextColor) == "function" then
        if disabled then
            button._muiTabText:SetTextColor(0.40, 0.36, 0.28, 0.60)
        elseif active then
            button._muiTabText:SetTextColor(0.94, 0.89, 0.78, 1)
        elseif hovered then
            button._muiTabText:SetTextColor(accentR, accentG, accentB, 0.95)
        else
            button._muiTabText:SetTextColor(0.58, 0.52, 0.40, 0.85)
        end
    end
    -- Glyph: hidden in redesign
    if button._muiTabGlyph then
        button._muiTabGlyph:SetAlpha(0)
    end
end

function UI.LayoutQuestPanelTabs(panel)
    if not panel or not panel._muiTabsHost or type(panel._muiTabOrder) ~= "table" then return end

    local visibleTabs = {}
    for i = 1, #panel._muiTabOrder do
        local tab = panel._muiTabOrder[i]
        if tab and tab:IsShown() then
            visibleTabs[#visibleTabs + 1] = tab
        end
    end
    if #visibleTabs == 0 then return end

    local hostWidth = panel._muiTabsHost:GetWidth()
    if type(hostWidth) ~= "number" or hostWidth <= 0 then
        hostWidth = UI.GetQuestPanelWidth() - (C.QUEST_LOG_PANEL_CONTENT_INSET * 2)
    end
    local tabCount = #visibleTabs
    local totalGap = (tabCount - 1) * C.QUEST_LOG_PANEL_TAB_GAP
    local availableWidth = hostWidth - totalGap
    local computedTabWidth = math.floor(availableWidth / tabCount)
    local tabWidth = Util.Clamp(computedTabWidth, C.QUEST_LOG_PANEL_TAB_MIN_WIDTH, C.QUEST_LOG_PANEL_TAB_MAX_WIDTH)
    local totalWidth = (tabCount * tabWidth) + totalGap
    local startX = math.floor((hostWidth - totalWidth) * 0.5)
    if startX < 0 then startX = 0 end

    local anchor = nil
    for i = 1, #visibleTabs do
        local tab = visibleTabs[i]
        tab:SetWidth(tabWidth)
        tab:ClearAllPoints()
        if not anchor then
            tab:SetPoint("LEFT", panel._muiTabsHost, "LEFT", startX, 0)
        else
            tab:SetPoint("LEFT", anchor, "RIGHT", C.QUEST_LOG_PANEL_TAB_GAP, 0)
        end
        anchor = tab
    end
end

function UI.RefreshQuestPanelTabs(panel)
    if not panel or type(panel._muiTabOrder) ~= "table" then return end
    local questFrame = panel._muiQuestOverlayFrame
    if not questFrame then return end

    local activeMode = questFrame.displayMode
    local canShowEvents = true
    if C_EventScheduler and type(C_EventScheduler.CanShowEvents) == "function" then
        canShowEvents = (C_EventScheduler.CanShowEvents() == true)
    end

    local questsMode = UI.GetQuestDisplayModeValue("Quests")
    local eventsMode = UI.GetQuestDisplayModeValue("Events")
    if not canShowEvents and eventsMode ~= nil and activeMode == eventsMode and questsMode ~= nil and type(questFrame.SetDisplayMode) == "function" and not panel._muiDisplayModeSyncing then
        panel._muiDisplayModeSyncing = true
        questFrame:SetDisplayMode(questsMode)
        panel._muiDisplayModeSyncing = false
        activeMode = questFrame.displayMode
    end

    for i = 1, #panel._muiTabOrder do
        local tab = panel._muiTabOrder[i]
        if tab then
            tab._muiDisplayMode = UI.GetQuestDisplayModeValue(tab._muiModeKey)
            if tab._muiTabText then
                tab._muiTabText:SetText(UI.GetQuestPanelTabLabel(tab._muiModeKey))
            end

            if tab._muiModeKey == "Events" and not canShowEvents then
                tab:Show()
                tab._muiTabDisabled = true
                if type(tab.SetEnabled) == "function" then
                    tab:SetEnabled(false)
                end
                tab._muiTabActive = false
                UI.ApplyQuestPanelTabVisual(tab, false)
            else
                tab:Show()
                tab._muiTabDisabled = false
                if type(tab.SetEnabled) == "function" then
                    tab:SetEnabled(true)
                end
                tab._muiTabActive = (tab._muiDisplayMode ~= nil and activeMode == tab._muiDisplayMode)
                UI.ApplyQuestPanelTabVisual(tab, false)
            end
        end
    end

    local activeModeKey = UI.ResolveQuestDisplayModeKey(questFrame, panel)
    UI.ApplyQuestPanelHeaderState(panel, activeModeKey)
    Addon.MapStyleQuestPanelModeContent(questFrame, activeModeKey)
    UI.LayoutQuestPanelTabs(panel)
end

-- Forward declaration; assigned to the real implementation after the panel widgets are created.
local RebuildQuestListLayout = function()
    -- Noop until EnsureQuestLogOverlayPanel wires the real layout function.
end

function UI.SetQuestPanelDisplayMode(panel, modeKey)
    if not panel then return end

    local questListScroll = panel._muiQuestListScroll
    local questFrame = panel._muiQuestOverlayFrame
    local detailsSurface = UI.EnsureQuestDetailsSurface(panel)
    local resolvedMode = modeKey
    if resolvedMode ~= "Quests" and resolvedMode ~= "Events" and resolvedMode ~= "MapLegend" then
        resolvedMode = questFrame and UI.ResolveQuestDisplayModeKey(questFrame, panel) or "Quests"
    end
    if resolvedMode ~= "Quests" and resolvedMode ~= "Events" and resolvedMode ~= "MapLegend" then
        resolvedMode = "Quests"
    end
    modeKey = resolvedMode

    if modeKey ~= "Quests" then
        UI.ClearQuestPanelDetailsState(panel, "DisplayMode:" .. Util.SafeToString(modeKey))
    end

    local showQuestDetails = (modeKey == "Quests" and UI.IsQuestPanelDetailsActive(panel))

    -- Quests tab can render either our custom list or our custom details surface.
    if modeKey == "Quests" then
        if questListScroll then
            if showQuestDetails then
                questListScroll:Hide()
            else
                questListScroll:Show()
                RebuildQuestListLayout()
            end
        end
        if detailsSurface then
            if showQuestDetails then
                UI.RenderQuestDetailsSurface(panel)
                detailsSurface:Show()
            else
                detailsSurface:Hide()
                UI.HideQuestDetailsAbandonDialog(panel)
            end
        end
        if questFrame then
            if type(questFrame.Hide) == "function" then
                questFrame:Hide()
            end
        end
    else
        if questListScroll then
            questListScroll:Hide()
        end
        if detailsSurface and type(detailsSurface.Hide) == "function" then
            detailsSurface:Hide()
        end
        UI.HideQuestDetailsAbandonDialog(panel)
        if questFrame and type(questFrame.Show) == "function" then
            questFrame:Show()
            Addon.MapStyleQuestPanelModeContent(questFrame, modeKey)
        end
    end

    -- For Events/MapLegend, delegate to Blizzard's display mode if available
    if questFrame and type(questFrame.SetDisplayMode) == "function" then
        local resolvedMode = modeKey
        if modeKey == "Events" and C_EventScheduler and type(C_EventScheduler.CanShowEvents) == "function" then
            if C_EventScheduler.CanShowEvents() ~= true then
                resolvedMode = "Quests"
            end
        end
        local displayMode = UI.GetQuestDisplayModeValue(resolvedMode)
        if displayMode ~= nil then
            questFrame:SetDisplayMode(displayMode)
        end
    end
    if modeKey == "Quests" and questFrame and type(questFrame.Hide) == "function" then
        questFrame:Hide()
    end

    UI.RefreshQuestPanelTabs(panel)
end

function UI.ShowQuestDetailsInQuestPanel(panel, questID, sourceTag, titleHint)
    if not panel then return end
    UI.SetQuestPanelDetailsActive(panel, questID, sourceTag or "questRowClick", titleHint)
    UI.SetQuestPanelDisplayMode(panel, "Quests")
    if type(UI.RenderQuestDetailsSurface) == "function" then
        UI.RenderQuestDetailsSurface(panel)
    end
end

function UI.RestoreQuestListInQuestPanel(panel, sourceTag)
    if not panel then return end
    UI.HideQuestDetailsAbandonDialog(panel)
    UI.ClearQuestPanelDetailsState(panel, sourceTag or "detailsReturn")
    UI.SetQuestPanelDisplayMode(panel, "Quests")
end

function UI.EnsureQuestDetailsLifecycleHooks(panel, questFrame)
    if not panel or not questFrame then return end

    local detailsFrame = questFrame.DetailsFrame
    if not detailsFrame and questFrame.QuestsFrame then
        detailsFrame = questFrame.QuestsFrame.DetailsFrame or questFrame.QuestsFrame.QuestDetailsFrame
    end
    if not detailsFrame then
        detailsFrame = _G.QuestMapDetailsScrollFrame
    end
    if not detailsFrame or type(detailsFrame.HookScript) ~= "function" or detailsFrame._muiQuestDetailsLifecycleHook then
        return
    end

    detailsFrame:HookScript("OnHide", function()
        local worldMap = _G.WorldMapFrame
        local worldMapPanel = worldMap and worldMap._muiQuestLogPanel or nil
        local mapShown = (worldMap and type(worldMap.IsShown) == "function" and worldMap:IsShown()) or false
        if worldMapPanel and worldMapPanel._muiQuestDetailsActive and Runtime.questLogPanelOpen
            and type(worldMapPanel.IsShown) == "function" and worldMapPanel:IsShown() and mapShown then
            UI.RestoreQuestListInQuestPanel(worldMapPanel, "QuestDetailsFrame:OnHide")
        end
    end)
    detailsFrame._muiQuestDetailsLifecycleHook = true
end

function UI.ResolveQuestLogIndexForQuestID(questID)
    if type(questID) ~= "number" or questID <= 0 then return nil end

    if type(C_QuestLog) == "table" and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local okIndex, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        if okIndex and type(index) == "number" and index > 0 then
            return index
        end
    end
    return nil
end

function UI.FormatQuestRewardMoney(copper)
    if type(copper) ~= "number" or copper <= 0 then
        return nil
    end

    local gold = math.floor(copper / (100 * 100))
    local silver = math.floor((copper % (100 * 100)) / 100)
    local copperOnly = math.floor(copper % 100)
    return string.format("%dg %ds %dc", gold, silver, copperOnly)
end

function UI.BuildQuestDetailsPayload(panel)
    if not panel then return nil end
    local questID = panel._muiQuestDetailsQuestID
    if type(questID) ~= "number" or questID <= 0 then return nil end

    local payload = {
        questID = questID,
        title = panel._muiQuestDetailsTitleHint or nil,
        description = nil,
        objectiveText = nil,
        objectives = {},
        rewards = {},
        rewardMoney = 0,
        rewardXP = 0,
        isWatched = false,
        isFocused = false,
        isSuperTracked = false,
        isTracked = false,
        canShare = false,
    }

    local questLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)

    if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
        pcall(C_QuestLog.SetSelectedQuest, questID)
    end
    if questLogIndex and type(SelectQuestLogEntry) == "function" then
        pcall(SelectQuestLogEntry, questLogIndex)
    end
    payload.canShare = UI.EvaluateQuestShareable(questID, questLogIndex)

    if type(C_QuestLog) == "table" and type(C_QuestLog.GetTitleForQuestID) == "function" then
        local okTitle, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if okTitle and type(title) == "string" and title ~= "" then
            payload.title = title
        end
    end
    if (not payload.title or payload.title == "") and questLogIndex and type(C_QuestLog) == "table" and type(C_QuestLog.GetInfo) == "function" then
        local okInfo, info = pcall(C_QuestLog.GetInfo, questLogIndex)
        if okInfo and type(info) == "table" and type(info.title) == "string" and info.title ~= "" then
            payload.title = info.title
        end
    end
    if not payload.title or payload.title == "" then
        payload.title = _G.QUESTS_LABEL or "Quest"
    end

    if type(GetQuestLogQuestText) == "function" then
        local okText, questDescription, questObjectiveText = false, nil, nil
        if questLogIndex then
            okText, questDescription, questObjectiveText = pcall(GetQuestLogQuestText, questLogIndex)
        end
        if not okText then
            okText, questDescription, questObjectiveText = pcall(GetQuestLogQuestText)
        end
        if okText then
            if type(questDescription) == "string" and questDescription ~= "" then
                payload.description = questDescription
            end
            if type(questObjectiveText) == "string" and questObjectiveText ~= "" then
                payload.objectiveText = questObjectiveText
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestObjectives) == "function" then
        local okObjectives, objectives = pcall(C_QuestLog.GetQuestObjectives, questID)
        if (not okObjectives or type(objectives) ~= "table") and questLogIndex then
            okObjectives, objectives = pcall(C_QuestLog.GetQuestObjectives, questLogIndex)
        end
        if okObjectives and type(objectives) == "table" then
            for i = 1, #objectives do
                local objective = objectives[i]
                if type(objective) == "table" then
                    local objectiveText = objective.text
                    if (not objectiveText or objectiveText == "")
                        and type(objective.numFulfilled) == "number" and type(objective.numRequired) == "number" then
                        objectiveText = string.format("%d/%d", objective.numFulfilled, objective.numRequired)
                    end
                    if type(objectiveText) == "string" and objectiveText ~= "" then
                        payload.objectives[#payload.objectives + 1] = {
                            text = objectiveText,
                            finished = (objective.finished == true),
                        }
                    end
                end
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestWatched) == "function" then
        local okWatched, isWatched = pcall(C_QuestLog.IsQuestWatched, questID)
        payload.isWatched = (okWatched and isWatched == true)
    end
    payload.isFocused = (Runtime.focusedQuestID == questID)
    if type(C_SuperTrack) == "table" and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" then
        local okSuper, superQuestID = pcall(C_SuperTrack.GetSuperTrackedQuestID)
        payload.isSuperTracked = (okSuper and type(superQuestID) == "number" and superQuestID == questID)
    end
    payload.isTracked = (payload.isFocused == true) or (payload.isWatched == true) or (payload.isSuperTracked == true)

    if type(GetQuestLogRewardMoney) == "function" then
        local okMoney, money = pcall(GetQuestLogRewardMoney)
        if okMoney and type(money) == "number" then
            payload.rewardMoney = money
        end
    end
    if type(GetQuestLogRewardXP) == "function" then
        local okXP, xp = pcall(GetQuestLogRewardXP)
        if okXP and type(xp) == "number" then
            payload.rewardXP = xp
        end
    end

    local numRewards = 0
    if type(GetNumQuestLogRewards) == "function" then
        local okRewards, count = pcall(GetNumQuestLogRewards, questID)
        if (not okRewards) or type(count) ~= "number" then
            okRewards, count = pcall(GetNumQuestLogRewards)
        end
        if okRewards and type(count) == "number" and count > 0 then
            numRewards = count
        end
    end
    for i = 1, numRewards do
        if type(GetQuestLogRewardInfo) == "function" then
            local okReward, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogRewardInfo, i, questID)
            if (not okReward) or ((not name or name == "") and (not texture)) then
                okReward, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogRewardInfo, i)
            end
            if okReward and ((type(name) == "string" and name ~= "") or texture) then
                payload.rewards[#payload.rewards + 1] = {
                    name = name,
                    texture = texture,
                    count = count,
                    quality = quality,
                    isUsable = isUsable,
                    itemID = itemID,
                    isChoice = false,
                }
            end
        end
    end

    local numChoices = 0
    if type(GetNumQuestLogChoices) == "function" then
        local okChoices, count = pcall(GetNumQuestLogChoices, questID)
        if (not okChoices) or type(count) ~= "number" then
            okChoices, count = pcall(GetNumQuestLogChoices)
        end
        if okChoices and type(count) == "number" and count > 0 then
            numChoices = count
        end
    end
    for i = 1, numChoices do
        if type(GetQuestLogChoiceInfo) == "function" then
            local okChoice, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogChoiceInfo, i, questID)
            if (not okChoice) or ((not name or name == "") and (not texture)) then
                okChoice, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogChoiceInfo, i)
            end
            if okChoice and ((type(name) == "string" and name ~= "") or texture) then
                payload.rewards[#payload.rewards + 1] = {
                    name = name,
                    texture = texture,
                    count = count,
                    quality = quality,
                    isUsable = isUsable,
                    itemID = itemID,
                    isChoice = true,
                }
            end
        end
    end

    return payload
end

function UI.StyleQuestDetailsSurfaceActionButton(button)
    if not button then return end

    if not button._muiQuestDetailsButtonStyled then
        if button.Left then button.Left:Hide() end
        if button.Middle then button.Middle:Hide() end
        if button.Right then button.Right:Hide() end
        UI.SuppressButtonArt(button)

        local border = button:CreateTexture(nil, "BACKGROUND", nil, -6)
        border:SetAllPoints()
        border:SetTexture(C.WHITE8X8)
        button._muiQuestDetailsButtonBorder = border

        local bg = button:CreateTexture(nil, "BACKGROUND", nil, -5)
        bg:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        bg:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        bg:SetTexture(C.WHITE8X8)
        button._muiQuestDetailsButtonBg = bg

        local sheen = button:CreateTexture(nil, "ARTWORK", nil, -4)
        sheen:SetPoint("TOPLEFT", button, "TOPLEFT", 2, -2)
        sheen:SetPoint("TOPRIGHT", button, "TOPRIGHT", -2, -2)
        sheen:SetHeight(8)
        sheen:SetTexture(C.WHITE8X8)
        button._muiQuestDetailsButtonSheen = sheen

        local hover = button:CreateTexture(nil, "HIGHLIGHT", nil, 1)
        hover:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        hover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        hover:SetTexture(C.WHITE8X8)
        hover:SetAlpha(0)
        button._muiQuestDetailsButtonHover = hover

        button._muiQuestDetailsButtonStyled = true
        if type(button.HookScript) == "function" and not button._muiQuestDetailsButtonHoverHooks then
            button:HookScript("OnEnter", function(self)
                if self._muiQuestDetailsButtonHover then
                    self._muiQuestDetailsButtonHover:SetAlpha(1)
                end
            end)
            button:HookScript("OnLeave", function(self)
                if self._muiQuestDetailsButtonHover then
                    self._muiQuestDetailsButtonHover:SetAlpha(0)
                end
            end)
            button._muiQuestDetailsButtonHoverHooks = true
        end
    end

    local accentR, accentG, accentB = UI.GetAccentColor()
    local borderR, borderG, borderB = C.GetThemeColor("borderStrong")
    local bgR, bgG, bgB = C.GetThemeColor("bgPanelRaised")
    local enabled = type(button.IsEnabled) ~= "function" or button:IsEnabled()

    if button._muiQuestDetailsButtonBorder then
        if enabled then
            button._muiQuestDetailsButtonBorder:SetVertexColor(borderR, borderG, borderB, 0.92)
        else
            button._muiQuestDetailsButtonBorder:SetVertexColor(0.28, 0.32, 0.38, 0.82)
        end
    end
    if button._muiQuestDetailsButtonBg then
        if enabled then
            button._muiQuestDetailsButtonBg:SetVertexColor(bgR, bgG, bgB, 0.96)
        else
            button._muiQuestDetailsButtonBg:SetVertexColor(0.13, 0.15, 0.19, 0.94)
        end
    end
    if button._muiQuestDetailsButtonSheen then
        if enabled then
            button._muiQuestDetailsButtonSheen:SetVertexColor(0.18, 0.22, 0.28, 0.32)
        else
            button._muiQuestDetailsButtonSheen:SetVertexColor(0.11, 0.13, 0.16, 0.20)
        end
    end
    if button._muiQuestDetailsButtonHover then
        if enabled then
            button._muiQuestDetailsButtonHover:SetVertexColor(accentR, accentG, accentB, 0.18)
        else
            button._muiQuestDetailsButtonHover:SetVertexColor(0, 0, 0, 0)
            button._muiQuestDetailsButtonHover:SetAlpha(0)
        end
    end

    local label = button.Text
    if not label and type(button.GetFontString) == "function" then
        local okFont, fontString = pcall(button.GetFontString, button)
        if okFont then label = fontString end
    end
    if label and type(label.SetTextColor) == "function" then
        local textR, textG, textB = C.GetThemeColor("textPrimary")
        label:SetTextColor(textR, textG, textB, enabled and 1 or 0.45)
        if type(label.SetWordWrap) == "function" then
            label:SetWordWrap(false)
        end
        if type(label.SetJustifyH) == "function" then
            label:SetJustifyH("CENTER")
        end
    end
end

function UI.EvaluateQuestAbandonable(questID, questLogIndex)
    local sawResult = false
    local canAbandon = false
    local function Consider(value)
        if type(value) == "boolean" then
            sawResult = true
            if value == true then
                canAbandon = true
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.CanAbandonQuest) == "function" then
        local ok, value = pcall(C_QuestLog.CanAbandonQuest, questID)
        if ok then
            Consider(value)
        end
        if type(questLogIndex) == "number" then
            ok, value = pcall(C_QuestLog.CanAbandonQuest, questLogIndex)
            if ok then
                Consider(value)
            end
        end
        ok, value = pcall(C_QuestLog.CanAbandonQuest)
        if ok then
            Consider(value)
        end
    end
    if not sawResult then
        return true
    end
    return canAbandon == true
end

function UI.EvaluateQuestShareable(questID, questLogIndex)
    local inShareGroup = false
    if type(IsInGroup) == "function" then
        local function ConsiderGroup(value)
            if value == true then
                inShareGroup = true
            end
        end

        if type(LE_PARTY_CATEGORY_HOME) == "number" then
            local okHome, valueHome = pcall(IsInGroup, LE_PARTY_CATEGORY_HOME)
            if okHome then
                ConsiderGroup(valueHome)
            end
        end
        if not inShareGroup and type(LE_PARTY_CATEGORY_INSTANCE) == "number" then
            local okInstance, valueInstance = pcall(IsInGroup, LE_PARTY_CATEGORY_INSTANCE)
            if okInstance then
                ConsiderGroup(valueInstance)
            end
        end
        if not inShareGroup then
            local okGeneric, valueGeneric = pcall(IsInGroup)
            if okGeneric then
                ConsiderGroup(valueGeneric)
            end
        end
    end
    if not inShareGroup and type(IsInRaid) == "function" then
        local okRaid, valueRaid = pcall(IsInRaid)
        if okRaid and valueRaid == true then
            inShareGroup = true
        end
    end
    if not inShareGroup then
        return false
    end

    local sawResult = false
    local canShare = false
    local function Consider(value)
        if type(value) == "boolean" then
            sawResult = true
            if value == true then
                canShare = true
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.IsPushableQuest) == "function" then
        local ok, value = pcall(C_QuestLog.IsPushableQuest, questID)
        if ok then
            Consider(value)
        end
        if type(questLogIndex) == "number" then
            ok, value = pcall(C_QuestLog.IsPushableQuest, questLogIndex)
            if ok then
                Consider(value)
            end
        end
        ok, value = pcall(C_QuestLog.IsPushableQuest)
        if ok then
            Consider(value)
        end
    end
    if not sawResult then
        return false
    end
    return canShare == true
end

function UI.ExecuteQuestAbandonForDetails(panel, questID)
    if type(questID) ~= "number" or questID <= 0 then return false end

    local questLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)
    if type(questLogIndex) == "number" and type(SelectQuestLogEntry) == "function" then
        pcall(SelectQuestLogEntry, questLogIndex)
    end
    if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
        pcall(C_QuestLog.SetSelectedQuest, questID)
    end

    local armed = false
    local armPath = "none"
    local function TryArm(func, ...)
        if type(func) ~= "function" then return false end
        local ok = pcall(func, ...)
        return ok == true
    end

    if not armed and type(C_QuestLog) == "table" and type(C_QuestLog.SetAbandonQuest) == "function" then
        armed = TryArm(C_QuestLog.SetAbandonQuest, questID)
        if armed then armPath = "C_QuestLog.SetAbandonQuest(questID)" end
        if not armed and type(questLogIndex) == "number" then
            armed = TryArm(C_QuestLog.SetAbandonQuest, questLogIndex)
            if armed then armPath = "C_QuestLog.SetAbandonQuest(logIndex)" end
        end
        if not armed then
            armed = TryArm(C_QuestLog.SetAbandonQuest)
            if armed then armPath = "C_QuestLog.SetAbandonQuest()" end
        end
    end

    if not armed and type(C_QuestLog) == "table" and type(C_QuestLog.SetAbandon) == "function" then
        armed = TryArm(C_QuestLog.SetAbandon, questID)
        if armed then armPath = "C_QuestLog.SetAbandon(questID)" end
        if not armed and type(questLogIndex) == "number" then
            armed = TryArm(C_QuestLog.SetAbandon, questLogIndex)
            if armed then armPath = "C_QuestLog.SetAbandon(logIndex)" end
        end
        if not armed then
            armed = TryArm(C_QuestLog.SetAbandon)
            if armed then armPath = "C_QuestLog.SetAbandon()" end
        end
    end

    if not armed and type(SetAbandonQuest) == "function" then
        armed = TryArm(SetAbandonQuest)
        if armed then armPath = "SetAbandonQuest()" end
    end

    local abandoned = false
    local abandonPath = "none"
    if type(C_QuestLog) == "table" and type(C_QuestLog.AbandonQuest) == "function" then
        local okAbandon = pcall(C_QuestLog.AbandonQuest)
        abandoned = (okAbandon == true)
        if abandoned then
            abandonPath = "C_QuestLog.AbandonQuest()"
        end
    end
    if not abandoned and type(AbandonQuest) == "function" then
        local okLegacyAbandon = pcall(AbandonQuest)
        abandoned = (okLegacyAbandon == true)
        if abandoned then
            abandonPath = "AbandonQuest()"
        end
    end

    if abandoned then
        if Runtime.focusedQuestID == questID then
            UI.ClearFocusedQuest("DetailsSurface:Abandon", true)
        end
        if type(C_SuperTrack) == "table" and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" then
            local okSuper, superQuestID = pcall(C_SuperTrack.GetSuperTrackedQuestID)
            if okSuper and type(superQuestID) == "number" and superQuestID == questID
                and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
                local okClear = pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
                if not okClear then
                    pcall(C_SuperTrack.SetSuperTrackedQuestID, nil)
                end
            end
        end
        if panel and panel._muiQuestDetailsQuestID == questID then
            UI.RestoreQuestListInQuestPanel(panel, "DetailsSurface:AbandonConfirmed")
        end
        RebuildQuestListLayout()
    end

    return abandoned == true
end

function UI.HideQuestDetailsAbandonDialog(panel)
    if not panel then return end
    local dialog = panel._muiQuestDetailsAbandonDialog
    if dialog and type(dialog.Hide) == "function" then
        dialog:Hide()
    end
    local scrim = panel._muiQuestDetailsAbandonScrim
    if scrim and type(scrim.Hide) == "function" then
        scrim:Hide()
    end
end

function UI.EnsureQuestDetailsAbandonDialog(panel)
    if not panel then return nil end
    if panel._muiQuestDetailsAbandonDialog then
        return panel._muiQuestDetailsAbandonDialog
    end

    local popupVisuals = {
        bg = { 0.04, 0.06, 0.09, 0.95 },
        border = { 0.21, 0.30, 0.39, 0.92 },
        header = { 0.08, 0.14, 0.22, 0.96 },
        accent = { 0.22, 0.54, 0.72, 0.72 },
        inset = { 0.03, 0.07, 0.11, 0.68 },
        title = { 0.94, 0.97, 1.00, 1.00 },
        text = { 0.73, 0.80, 0.88, 1.00 },
        danger = { 0.95, 0.42, 0.36, 1.00 },
    }

    local function StylePopupButton(button)
        if not button then return end
        if type(_G.MidnightUI_StyleButton) == "function" then
            _G.MidnightUI_StyleButton(button)
            return
        end
        UI.StyleQuestDetailsSurfaceActionButton(button)
    end

    local scrim = CreateFrame("Frame", nil, UIParent)
    scrim:SetAllPoints(UIParent)
    scrim:SetFrameStrata("FULLSCREEN_DIALOG")
    scrim:SetFrameLevel(200)
    scrim:EnableMouse(true)
    scrim:SetClampedToScreen(true)
    scrim:SetScript("OnMouseDown", function()
        UI.HideQuestDetailsAbandonDialog(panel)
    end)
    scrim:Hide()
    local scrimBg = scrim:CreateTexture(nil, "BACKGROUND")
    scrimBg:SetAllPoints()
    scrimBg:SetTexture(C.WHITE8X8)
    scrimBg:SetVertexColor(0, 0, 0, 0.58)
    panel._muiQuestDetailsAbandonScrim = scrim

    local dialog = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    dialog:SetSize(436, 176)
    dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 8)
    dialog:SetFrameStrata("FULLSCREEN_DIALOG")
    dialog:SetFrameLevel(220)
    dialog:EnableMouse(true)
    dialog:SetClampedToScreen(true)
    dialog:SetBackdrop({
        bgFile = C.WHITE8X8,
        edgeFile = C.WHITE8X8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    dialog:SetBackdropColor(popupVisuals.bg[1], popupVisuals.bg[2], popupVisuals.bg[3], popupVisuals.bg[4])
    dialog:SetBackdropBorderColor(popupVisuals.border[1], popupVisuals.border[2], popupVisuals.border[3], popupVisuals.border[4])
    dialog:Hide()

    -- ESC to close
    dialog:EnableKeyboard(true)
    dialog:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            UI.HideQuestDetailsAbandonDialog(panel)
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    panel._muiQuestDetailsAbandonDialog = dialog

    local headerBg = dialog:CreateTexture(nil, "ARTWORK", nil, -1)
    headerBg:SetPoint("TOPLEFT", dialog, "TOPLEFT", 1, -1)
    headerBg:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -1, -1)
    headerBg:SetHeight(38)
    headerBg:SetTexture(C.WHITE8X8)
    headerBg:SetVertexColor(popupVisuals.header[1], popupVisuals.header[2], popupVisuals.header[3], popupVisuals.header[4])

    local headerAccent = dialog:CreateTexture(nil, "ARTWORK")
    headerAccent:SetPoint("TOPLEFT", dialog, "TOPLEFT", 1, -1)
    headerAccent:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -1, -1)
    headerAccent:SetHeight(2)
    headerAccent:SetTexture(C.WHITE8X8)
    headerAccent:SetVertexColor(popupVisuals.accent[1], popupVisuals.accent[2], popupVisuals.accent[3], popupVisuals.accent[4])

    local bodyInset = dialog:CreateTexture(nil, "BACKGROUND")
    bodyInset:SetPoint("TOPLEFT", dialog, "TOPLEFT", 10, -48)
    bodyInset:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -10, 44)
    bodyInset:SetTexture(C.WHITE8X8)
    bodyInset:SetVertexColor(popupVisuals.inset[1], popupVisuals.inset[2], popupVisuals.inset[3], popupVisuals.inset[4])

    local title = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("CENTER", headerBg, "CENTER", 0, -1)
    title:SetJustifyH("CENTER")
    title:SetTextColor(popupVisuals.title[1], popupVisuals.title[2], popupVisuals.title[3], popupVisuals.title[4])
    title:SetText("Abandon Quest?")
    dialog._muiTitle = title

    local questLabel = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    questLabel:SetPoint("TOPLEFT", dialog, "TOPLEFT", 16, -58)
    questLabel:SetPoint("TOPRIGHT", dialog, "TOPRIGHT", -16, -58)
    questLabel:SetJustifyH("CENTER")
    if type(questLabel.SetWordWrap) == "function" then
        questLabel:SetWordWrap(false)
    end
    questLabel:SetTextColor(1.00, 0.96, 0.86, 1.00)
    questLabel:SetText("")
    dialog._muiQuestLabel = questLabel

    local message = dialog:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    message:SetPoint("TOPLEFT", questLabel, "BOTTOMLEFT", 0, -8)
    message:SetPoint("TOPRIGHT", questLabel, "BOTTOMRIGHT", 0, -8)
    message:SetJustifyH("CENTER")
    if type(message.SetWordWrap) == "function" then
        message:SetWordWrap(true)
    end
    message:SetTextColor(popupVisuals.text[1], popupVisuals.text[2], popupVisuals.text[3], popupVisuals.text[4])
    dialog._muiMessage = message

    local warning = dialog:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    warning:SetPoint("TOPLEFT", message, "BOTTOMLEFT", 0, -5)
    warning:SetPoint("TOPRIGHT", message, "BOTTOMRIGHT", 0, -5)
    warning:SetJustifyH("CENTER")
    warning:SetTextColor(popupVisuals.danger[1], popupVisuals.danger[2], popupVisuals.danger[3], popupVisuals.danger[4])
    warning:SetText("This action cannot be undone.")
    dialog._muiWarning = warning

    local actionsDivider = dialog:CreateTexture(nil, "ARTWORK")
    actionsDivider:SetPoint("BOTTOMLEFT", dialog, "BOTTOMLEFT", 12, 42)
    actionsDivider:SetPoint("BOTTOMRIGHT", dialog, "BOTTOMRIGHT", -12, 42)
    actionsDivider:SetHeight(1)
    actionsDivider:SetTexture(C.WHITE8X8)
    actionsDivider:SetVertexColor(popupVisuals.border[1], popupVisuals.border[2], popupVisuals.border[3], 0.75)

    local cancelButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    cancelButton:SetSize(192, 28)
    cancelButton:SetPoint("BOTTOMLEFT", dialog, "BOTTOMLEFT", 16, 10)
    cancelButton:SetText(_G.CANCEL or "Cancel")
    StylePopupButton(cancelButton)
    dialog._muiCancelButton = cancelButton

    local confirmButton = CreateFrame("Button", nil, dialog, "UIPanelButtonTemplate")
    confirmButton:SetSize(192, 28)
    confirmButton:SetPoint("LEFT", cancelButton, "RIGHT", 12, 0)
    confirmButton:SetText("Abandon Quest")
    StylePopupButton(confirmButton)
    dialog._muiConfirmButton = confirmButton

    cancelButton:SetScript("OnClick", function()
        UI.HideQuestDetailsAbandonDialog(panel)
    end)
    confirmButton:SetScript("OnClick", function()
        local confirmQuestID = dialog._muiQuestID
        UI.HideQuestDetailsAbandonDialog(panel)
        UI.ExecuteQuestAbandonForDetails(panel, confirmQuestID)
    end)

    return dialog
end

function UI.ShowQuestDetailsAbandonDialog(panel, questID, questTitle)
    if not panel or type(questID) ~= "number" or questID <= 0 then return end
    local dialog = UI.EnsureQuestDetailsAbandonDialog(panel)
    if not dialog then return end

    local questName = Addon.MapSafeQuestTextSnippet(questTitle, 60)
    if (not questName or questName == "") and type(C_QuestLog) == "table" and type(C_QuestLog.GetTitleForQuestID) == "function" then
        local okTitle, title = pcall(C_QuestLog.GetTitleForQuestID, questID)
        if okTitle and type(title) == "string" and title ~= "" then
            questName = Addon.MapSafeQuestTextSnippet(title, 60)
        end
    end
    if not questName or questName == "" then
        questName = "this quest"
    end

    dialog._muiQuestID = questID
    if dialog._muiQuestLabel and type(dialog._muiQuestLabel.SetText) == "function" then
        dialog._muiQuestLabel:SetText(string.format("\"%s\"", questName))
    end
    if dialog._muiMessage and type(dialog._muiMessage.SetText) == "function" then
        dialog._muiMessage:SetText("You're about to abandon this quest.")
    end
    if dialog._muiConfirmButton and type(dialog._muiConfirmButton.SetEnabled) == "function" then
        dialog._muiConfirmButton:SetEnabled(true)
    end
    if dialog._muiConfirmButton then
        if type(_G.MidnightUI_StyleButton) == "function" then
            _G.MidnightUI_StyleButton(dialog._muiConfirmButton)
        else
            UI.StyleQuestDetailsSurfaceActionButton(dialog._muiConfirmButton)
        end
    end
    if dialog._muiCancelButton then
        if type(_G.MidnightUI_StyleButton) == "function" then
            _G.MidnightUI_StyleButton(dialog._muiCancelButton)
        else
            UI.StyleQuestDetailsSurfaceActionButton(dialog._muiCancelButton)
        end
    end

    local scrim = panel._muiQuestDetailsAbandonScrim
    if scrim and type(scrim.Show) == "function" then
        scrim:Show()
    end
    if type(dialog.Show) == "function" then
        dialog:ClearAllPoints()
        dialog:SetPoint("CENTER", UIParent, "CENTER", 0, 8)
        dialog:Show()
    end
end

function UI.EnsureQuestDetailsSurface(panel)
    if not panel then return nil end
    if panel._muiQuestDetailsSurface then return panel._muiQuestDetailsSurface end
    local parent = panel._muiContentInner or panel._muiContentHost
    if not parent then return nil end

    local surface = CreateFrame("Frame", nil, parent)
    surface:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    surface:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
    surface:Hide()
    panel._muiQuestDetailsSurface = surface

    local bg = surface:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(QUEST_LIST_VISUALS.contentInnerBg.r, QUEST_LIST_VISUALS.contentInnerBg.g, QUEST_LIST_VISUALS.contentInnerBg.b, 0.98)

    local border = surface:CreateTexture(nil, "BORDER", nil, -6)
    border:SetPoint("TOPLEFT", surface, "TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", surface, "BOTTOMRIGHT", 0, 0)
    border:SetTexture(C.WHITE8X8)
    local borderR, borderG, borderB = C.GetThemeColor("borderStrong")
    border:SetVertexColor(borderR, borderG, borderB, 0.78)

    local title = surface:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", surface, "TOPLEFT", 12, -8)
    title:SetPoint("TOPRIGHT", surface, "TOPRIGHT", -12, -8)
    title:SetJustifyH("LEFT")
    title:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 1)
    surface._muiTitle = title

    local subtitle = surface:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -2)
    subtitle:SetPoint("TOPRIGHT", surface, "TOPRIGHT", -12, -24)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 0.95)
    surface._muiSubtitle = subtitle

    local divider = surface:CreateTexture(nil, "ARTWORK")
    divider:SetPoint("TOPLEFT", surface, "TOPLEFT", 12, -42)
    divider:SetPoint("TOPRIGHT", surface, "TOPRIGHT", -12, -42)
    divider:SetHeight(1)
    divider:SetTexture(C.WHITE8X8)
    divider:SetVertexColor(QUEST_LIST_VISUALS.divider.r, QUEST_LIST_VISUALS.divider.g, QUEST_LIST_VISUALS.divider.b, 0.72)

    local actionBar = CreateFrame("Frame", nil, surface)
    actionBar:SetPoint("BOTTOMLEFT", surface, "BOTTOMLEFT", 0, 0)
    actionBar:SetPoint("BOTTOMRIGHT", surface, "BOTTOMRIGHT", 0, 0)
    actionBar:SetHeight(42)
    surface._muiActionBar = actionBar

    local actionBarBg = actionBar:CreateTexture(nil, "BACKGROUND", nil, -4)
    actionBarBg:SetAllPoints()
    actionBarBg:SetTexture(C.WHITE8X8)
    actionBarBg:SetVertexColor(QUEST_LIST_VISUALS.headerBg.r, QUEST_LIST_VISUALS.headerBg.g, QUEST_LIST_VISUALS.headerBg.b, 0.95)

    local actionTopLine = actionBar:CreateTexture(nil, "ARTWORK")
    actionTopLine:SetPoint("TOPLEFT", actionBar, "TOPLEFT", 0, 0)
    actionTopLine:SetPoint("TOPRIGHT", actionBar, "TOPRIGHT", 0, 0)
    actionTopLine:SetHeight(1)
    actionTopLine:SetTexture(C.WHITE8X8)
    actionTopLine:SetVertexColor(QUEST_LIST_VISUALS.divider.r, QUEST_LIST_VISUALS.divider.g, QUEST_LIST_VISUALS.divider.b, 0.70)

    local scroll = CreateFrame("ScrollFrame", nil, surface, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", surface, "TOPLEFT", 10, -50)
    scroll:SetPoint("BOTTOMRIGHT", actionBar, "TOPRIGHT", -24, 6)
    surface._muiScroll = scroll

    local scrollChild = CreateFrame("Frame", nil, scroll)
    scrollChild:SetWidth(1)
    scrollChild:SetHeight(1)
    scroll:SetScrollChild(scrollChild)
    surface._muiScrollChild = scrollChild
    surface._muiSectionPool = {}
    surface._muiActiveSections = {}

    scroll:HookScript("OnSizeChanged", function(self, width)
        local child = self._muiScrollChild or scrollChild
        if child and type(width) == "number" and width > 0 then
            child:SetWidth(math.max(1, width - 8))
        end
    end)
    scroll._muiScrollChild = scrollChild
    Addon.MapEnsureQuestScrollbarStyle(scroll, "Quests")

    local function CreateActionButton(name, text)
        local button = CreateFrame("Button", nil, actionBar, "UIPanelButtonTemplate")
        button:SetHeight(26)
        button:SetText(text)
        UI.StyleQuestDetailsSurfaceActionButton(button)
        if type(button.HookScript) == "function" and not button._muiQuestDetailsActionHooked then
            button:HookScript("OnEnable", UI.StyleQuestDetailsSurfaceActionButton)
            button:HookScript("OnDisable", UI.StyleQuestDetailsSurfaceActionButton)
            button:HookScript("OnShow", UI.StyleQuestDetailsSurfaceActionButton)
            button._muiQuestDetailsActionHooked = true
        end
        surface["_mui" .. name .. "Button"] = button
        return button
    end

    local backButton = CreateActionButton("Back", "Back")
    local abandonButton = CreateActionButton("Abandon", "Abandon")
    local shareButton = CreateActionButton("Share", "Share")
    local trackButton = CreateActionButton("Track", "Track")

    local function LayoutActionButtons()
        local actionButtons = { backButton, abandonButton, shareButton, trackButton }
        local width = actionBar:GetWidth()
        if type(width) ~= "number" or width <= 0 then return end

        local pad = 10
        local gap = 6
        local oneRowWidth = math.floor((width - (pad * 2) - (gap * 3)) / 4)

        for i = 1, #actionButtons do
            local btn = actionButtons[i]
            btn:ClearAllPoints()
        end

        if oneRowWidth >= 72 then
            actionBar:SetHeight(42)
            for i = 1, #actionButtons do
                local btn = actionButtons[i]
                btn:SetWidth(oneRowWidth)
                btn:SetHeight(26)
                if i == 1 then
                    btn:SetPoint("LEFT", actionBar, "LEFT", pad, 0)
                else
                    btn:SetPoint("LEFT", actionButtons[i - 1], "RIGHT", gap, 0)
                end
            end
        else
            local twoColWidth = math.floor((width - (pad * 2) - gap) / 2)
            if twoColWidth < 82 then
                twoColWidth = 82
            end
            actionBar:SetHeight(70)
            for i = 1, #actionButtons do
                local btn = actionButtons[i]
                btn:SetWidth(twoColWidth)
                btn:SetHeight(24)
            end
            backButton:SetPoint("TOPLEFT", actionBar, "TOPLEFT", pad, -6)
            abandonButton:SetPoint("TOPLEFT", backButton, "TOPRIGHT", gap, 0)
            shareButton:SetPoint("TOPLEFT", backButton, "BOTTOMLEFT", 0, -6)
            trackButton:SetPoint("TOPLEFT", shareButton, "TOPRIGHT", gap, 0)
        end
    end
    actionBar._muiLayoutActionButtons = LayoutActionButtons
    if type(actionBar.HookScript) == "function" then
        actionBar:HookScript("OnSizeChanged", function()
            LayoutActionButtons()
        end)
    end

    backButton:SetScript("OnClick", function()
        UI.RestoreQuestListInQuestPanel(panel, "DetailsSurface:Back")
    end)
    trackButton:SetScript("OnClick", function()
        local questID = panel._muiQuestDetailsQuestID
        if type(questID) ~= "number" or questID <= 0 then return end
        local isFocused = (Runtime.focusedQuestID == questID)
        local watched = false
        local isSuperTracked = false
        if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end
        if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestWatched) == "function" then
            local okWatched, value = pcall(C_QuestLog.IsQuestWatched, questID)
            watched = (okWatched and value == true)
        end
        if type(C_SuperTrack) == "table" and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" then
            local okSuper, superQuestID = pcall(C_SuperTrack.GetSuperTrackedQuestID)
            isSuperTracked = (okSuper and type(superQuestID) == "number" and superQuestID == questID)
        end

        local shouldUntrack = (isFocused == true) or (watched == true) or (isSuperTracked == true)
        if shouldUntrack then
            if Runtime.focusedQuestID == questID then
                UI.ClearFocusedQuest("DetailsSurface:Untrack", true)
            end
            if type(C_QuestLog) == "table" and type(C_QuestLog.RemoveQuestWatch) == "function" then
                pcall(C_QuestLog.RemoveQuestWatch, questID)
            end
            if isSuperTracked and type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
                local okClear = pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
                if not okClear then
                    pcall(C_SuperTrack.SetSuperTrackedQuestID, nil)
                end
            end
            local mapFrame = _G.WorldMapFrame
            if mapFrame and type(mapFrame.ClearFocusedQuestID) == "function" then
                pcall(mapFrame.ClearFocusedQuestID, mapFrame)
            end
        else
            UI.SetFocusedQuest(questID, "DetailsSurface:Track", true)
            if type(C_QuestLog) == "table" and type(C_QuestLog.AddQuestWatch) == "function" then
                pcall(C_QuestLog.AddQuestWatch, questID)
            end
            if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
                pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
            end
            local mapFrame = _G.WorldMapFrame
            if mapFrame and type(mapFrame.SetFocusedQuestID) == "function" then
                pcall(mapFrame.SetFocusedQuestID, mapFrame, questID)
            end
        end
        RebuildQuestListLayout()
        UI.RenderQuestDetailsSurface(panel)
    end)
    shareButton:SetScript("OnClick", function()
        local questID = panel._muiQuestDetailsQuestID
        if type(questID) ~= "number" or questID <= 0 then return end
        local questLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)
        if type(questLogIndex) == "number" and type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, questLogIndex)
        end
        if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end
        local canShare = UI.EvaluateQuestShareable(questID, questLogIndex)
        if not canShare then
            if type(shareButton.SetEnabled) == "function" then
                shareButton:SetEnabled(false)
            end
            UI.StyleQuestDetailsSurfaceActionButton(shareButton)
            return
        end
        local shared = false
        if type(QuestMapQuestOptions_ShareQuest) == "function" then
            local okShare = pcall(QuestMapQuestOptions_ShareQuest, questID)
            shared = (okShare == true)
        end
        if not shared and type(QuestLogPushQuest) == "function" then
            local okPush = pcall(QuestLogPushQuest)
            shared = (okPush == true)
        end
        if not shared and type(C_QuestLog) == "table" and type(C_QuestLog.ShareQuest) == "function" then
            local okNative = pcall(C_QuestLog.ShareQuest, questID)
            shared = (okNative == true)
        end
    end)
    abandonButton:SetScript("OnClick", function()
        local questID = panel._muiQuestDetailsQuestID
        if type(questID) ~= "number" or questID <= 0 then return end
        UI.ShowQuestDetailsAbandonDialog(panel, questID, panel._muiQuestDetailsTitleHint)
    end)

    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, LayoutActionButtons)
    else
        LayoutActionButtons()
    end

    return surface
end

function UI.RenderQuestDetailsSurface(panel)
    if not panel then return end
    local surface = UI.EnsureQuestDetailsSurface(panel)
    if not surface then return end

    local payload = UI.BuildQuestDetailsPayload(panel)
    if not payload then
        UI.RestoreQuestListInQuestPanel(panel, "DetailsSurface:MissingPayload")
        return
    end

    if surface._muiTitle and type(surface._muiTitle.SetText) == "function" then
        surface._muiTitle:SetText(payload.title or (_G.QUESTS_LABEL or "Quest"))
    end
    if surface._muiSubtitle and type(surface._muiSubtitle.SetText) == "function" then
        local statusParts = { "Quest Details" }
        if payload.isFocused then
            statusParts[#statusParts + 1] = "Focused"
        end
        if payload.isSuperTracked then
            statusParts[#statusParts + 1] = "Supertracked"
        end
        if payload.isWatched then
            statusParts[#statusParts + 1] = "Watched"
        end
        local subtitleText = table.concat(statusParts, "  |  ")
        surface._muiSubtitle:SetText(subtitleText)
    end

    local scroll = surface._muiScroll
    local scrollChild = surface._muiScrollChild
    if not scroll or not scrollChild then return end

    local childWidth = scroll:GetWidth()
    if type(childWidth) ~= "number" or childWidth <= 0 then
        childWidth = UI.GetQuestPanelWidth() - 80
    end
    childWidth = math.max(220, childWidth - 8)
    scrollChild:SetWidth(childWidth)

    local sectionPool = surface._muiSectionPool or {}
    local activeSections = surface._muiActiveSections or {}
    surface._muiSectionPool = sectionPool
    surface._muiActiveSections = activeSections
    wipe(activeSections)

    local function AcquireSection(index, headerText)
        local section = sectionPool[index]
        if not section then
            section = CreateFrame("Frame", nil, scrollChild)
            section._headerHeight = 22

            local sectionBg = section:CreateTexture(nil, "BACKGROUND", nil, -3)
            sectionBg:SetAllPoints()
            sectionBg:SetTexture(C.WHITE8X8)
            section._muiBg = sectionBg

            local sectionBorder = section:CreateTexture(nil, "BORDER", nil, -2)
            sectionBorder:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)
            sectionBorder:SetPoint("BOTTOMRIGHT", section, "BOTTOMRIGHT", 0, 0)
            sectionBorder:SetTexture(C.WHITE8X8)
            section._muiBorder = sectionBorder

            local headerBg = section:CreateTexture(nil, "ARTWORK", nil, -1)
            headerBg:SetPoint("TOPLEFT", section, "TOPLEFT", 1, -1)
            headerBg:SetPoint("TOPRIGHT", section, "TOPRIGHT", -1, -1)
            headerBg:SetHeight(section._headerHeight)
            headerBg:SetTexture(C.WHITE8X8)
            section._muiHeaderBg = headerBg

            local header = section:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            header:SetPoint("LEFT", headerBg, "LEFT", 8, 0)
            header:SetPoint("RIGHT", headerBg, "RIGHT", -8, 0)
            header:SetJustifyH("LEFT")
            section._muiHeader = header

            local content = CreateFrame("Frame", nil, section)
            content:SetPoint("TOPLEFT", section, "TOPLEFT", 8, -(section._headerHeight + 6))
            content:SetPoint("TOPRIGHT", section, "TOPRIGHT", -8, -(section._headerHeight + 6))
            content:SetHeight(1)
            section.Content = content

            section._muiTextPool = {}
            section._muiActiveText = {}
            section._muiRewardPool = {}
            section._muiActiveRewards = {}
            sectionPool[index] = section
        end

        section:SetWidth(childWidth)
        section._muiBg:SetVertexColor(1, 1, 1, 0.03)
        section._muiBorder:SetVertexColor(QUEST_LIST_VISUALS.divider.r, QUEST_LIST_VISUALS.divider.g, QUEST_LIST_VISUALS.divider.b, 0.58)
        section._muiHeaderBg:SetVertexColor(QUEST_LIST_VISUALS.headerBg.r, QUEST_LIST_VISUALS.headerBg.g, QUEST_LIST_VISUALS.headerBg.b, 0.88)
        section._muiHeader:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 1)
        section._muiHeader:SetText(headerText or "")

        local textPool = section._muiTextPool
        local activeText = section._muiActiveText
        for i = 1, #activeText do
            local fs = activeText[i]
            if fs then
                fs:Hide()
                fs:ClearAllPoints()
                textPool[#textPool + 1] = fs
            end
        end
        wipe(activeText)

        local rewardPool = section._muiRewardPool
        local activeRewards = section._muiActiveRewards
        for i = 1, #activeRewards do
            local row = activeRewards[i]
            if row then
                row:Hide()
                row:ClearAllPoints()
                rewardPool[#rewardPool + 1] = row
            end
        end
        wipe(activeRewards)

        section._muiCursorY = -2
        section:Show()
        activeSections[#activeSections + 1] = section
        return section
    end

    local function AddSectionText(section, text, fontObject, color)
        if not section or type(text) ~= "string" or text == "" then return end
        local textPool = section._muiTextPool
        local activeText = section._muiActiveText
        local fs = table.remove(textPool)
        if not fs then
            fs = section.Content:CreateFontString(nil, "OVERLAY", fontObject or "GameFontHighlight")
        elseif fontObject and type(fs.SetFontObject) == "function" then
            fs:SetFontObject(fontObject)
        end
        fs:SetWidth(math.max(160, childWidth - 18))
        fs:SetJustifyH("LEFT")
        if type(fs.SetWordWrap) == "function" then
            fs:SetWordWrap(true)
        end
        if color and type(fs.SetTextColor) == "function" then
            fs:SetTextColor(color.r or 1, color.g or 1, color.b or 1, 1)
        end
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", section.Content, "TOPLEFT", 0, section._muiCursorY)
        fs:SetText(text)
        fs:Show()
        section._muiCursorY = section._muiCursorY - fs:GetStringHeight() - 8
        activeText[#activeText + 1] = fs
    end

    local function AddSectionReward(section, reward)
        if not section or not reward then return end
        local rewardPool = section._muiRewardPool
        local activeRewards = section._muiActiveRewards
        local row = table.remove(rewardPool)
        if not row then
            row = CreateFrame("Frame", nil, section.Content)
            row:SetHeight(22)
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetPoint("TOPLEFT", row, "TOPLEFT", 0, -2)
            icon:SetSize(18, 18)
            row.Icon = icon
            local text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            text:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, 0)
            text:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            text:SetJustifyH("LEFT")
            row.Text = text
            local subText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            subText:SetPoint("TOPLEFT", text, "BOTTOMLEFT", 0, -2)
            subText:SetPoint("RIGHT", row, "RIGHT", 0, 0)
            subText:SetJustifyH("LEFT")
            row.SubText = subText
        end
        row:SetWidth(math.max(160, childWidth - 18))
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", section.Content, "TOPLEFT", 0, section._muiCursorY)
        if row.Icon then
            if type(reward.texture) == "number" or type(reward.texture) == "string" then
                row.Icon:SetTexture(reward.texture)
                row.Icon:SetVertexColor(1, 1, 1, 1)
            else
                row.Icon:SetTexture(C.WHITE8X8)
                row.Icon:SetVertexColor(QUEST_LIST_VISUALS.rowDivider.r, QUEST_LIST_VISUALS.rowDivider.g, QUEST_LIST_VISUALS.rowDivider.b, 1)
            end
        end
        -- Strip trailing " x 10" from the name if the API baked the count into it
        local rawName = Util.SafeToString(reward.name or "Reward")
        local displayName, embeddedCount = rawName:match("^(.-)%s+x%s*(%d[%d,]*)%s*$")
        if not displayName or displayName == "" then
            displayName = rawName
        end
        local label = (reward.isChoice and "[Choice] " or "") .. displayName
        row.Text:SetText(label)
        row.Text:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 1)

        -- Determine count: prefer the explicit count field, fall back to embedded count from name
        local displayCount = nil
        if type(reward.count) == "number" and reward.count > 1 then
            displayCount = reward.count
        elseif embeddedCount then
            local parsed = tonumber((embeddedCount:gsub(",", "")))
            if parsed and parsed > 1 then displayCount = parsed end
        end
        if displayCount then
            -- Show count as a badge on the bottom-right of the icon (standard WoW style)
            if not row.CountText then
                local ct = row:CreateFontString(nil, "OVERLAY")
                ct:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
                ct:SetPoint("BOTTOMRIGHT", row.Icon, "BOTTOMRIGHT", 2, -1)
                ct:SetJustifyH("RIGHT")
                row.CountText = ct
            end
            local countStr = (type(BreakUpLargeNumbers) == "function") and BreakUpLargeNumbers(displayCount) or tostring(displayCount)
            row.CountText:SetText(countStr)
            row.CountText:SetTextColor(1, 1, 1, 1)
            row.CountText:Show()
        else
            if row.CountText then
                row.CountText:SetText("")
                row.CountText:Hide()
            end
        end
        if row.SubText then
            row.SubText:SetText("")
            row.SubText:Hide()
        end
        row:SetHeight(22)

        row:Show()
        section._muiCursorY = section._muiCursorY - row:GetHeight() - 4
        activeRewards[#activeRewards + 1] = row
    end

    local function FinalizeSection(section)
        local contentHeight = math.max(16, math.floor(-section._muiCursorY + 2))
        section.Content:SetHeight(contentHeight)
        section:SetHeight(section._headerHeight + 8 + contentHeight + 8)
    end

    local objectivesSection = AcquireSection(1, _G.OBJECTIVES_LABEL or "Objectives")
    if type(payload.objectiveText) == "string" and payload.objectiveText ~= "" then
        AddSectionText(objectivesSection, payload.objectiveText, "GameFontHighlight", QUEST_LIST_VISUALS.textPrimary)
    end
    if #payload.objectives > 0 then
        for i = 1, #payload.objectives do
            local objective = payload.objectives[i]
            local objectiveText = objective.finished and ("Done: " .. objective.text) or objective.text
            local objectiveColor = objective.finished and QUEST_LIST_VISUALS.success or QUEST_LIST_VISUALS.textSecondary
            AddSectionText(objectivesSection, objectiveText, "GameFontHighlight", objectiveColor)
        end
    else
        AddSectionText(objectivesSection, "No objective list available.", "GameFontHighlightSmall", QUEST_LIST_VISUALS.textMuted)
    end
    FinalizeSection(objectivesSection)

    local descriptionSection = AcquireSection(2, _G.DESCRIPTION or "Description")
    if type(payload.description) == "string" and payload.description ~= "" then
        AddSectionText(descriptionSection, payload.description, "GameFontHighlight", QUEST_LIST_VISUALS.textPrimary)
    else
        AddSectionText(descriptionSection, "No quest description available.", "GameFontHighlightSmall", QUEST_LIST_VISUALS.textMuted)
    end
    FinalizeSection(descriptionSection)

    local rewardsSection = AcquireSection(3, _G.REWARDS or "Rewards")
    local hasRewardInfo = false
    if type(payload.rewardMoney) == "number" and payload.rewardMoney > 0 then
        AddSectionText(rewardsSection, "Money: " .. (UI.FormatQuestRewardMoney(payload.rewardMoney) or tostring(payload.rewardMoney)), "GameFontHighlight", QUEST_LIST_VISUALS.textSecondary)
        hasRewardInfo = true
    end
    if type(payload.rewardXP) == "number" and payload.rewardXP > 0 then
        local xpText = (type(BreakUpLargeNumbers) == "function") and BreakUpLargeNumbers(payload.rewardXP) or tostring(payload.rewardXP)
        AddSectionText(rewardsSection, "Experience: " .. xpText, "GameFontHighlight", QUEST_LIST_VISUALS.textSecondary)
        hasRewardInfo = true
    end
    if #payload.rewards > 0 then
        for i = 1, #payload.rewards do
            AddSectionReward(rewardsSection, payload.rewards[i])
        end
        hasRewardInfo = true
    end
    if not hasRewardInfo then
        AddSectionText(rewardsSection, "No explicit rewards.", "GameFontHighlightSmall", QUEST_LIST_VISUALS.textMuted)
    end
    FinalizeSection(rewardsSection)

    local yOffset = -4
    for i = 1, #activeSections do
        local section = activeSections[i]
        section:ClearAllPoints()
        section:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, yOffset)
        yOffset = yOffset - section:GetHeight() - 10
    end
    for i = (#activeSections + 1), #sectionPool do
        local extra = sectionPool[i]
        if extra then
            extra:Hide()
        end
    end

    local finalHeight = math.max(1, math.floor(-yOffset + 2))
    scrollChild:SetHeight(finalHeight)

    if type(scroll.SetVerticalScroll) == "function" then
        scroll:SetVerticalScroll(0)
    end

    if surface._muiTrackButton and type(surface._muiTrackButton.SetText) == "function" then
        if payload.isTracked then
            surface._muiTrackButton:SetText("Untrack")
        else
            surface._muiTrackButton:SetText("Track")
        end
        UI.StyleQuestDetailsSurfaceActionButton(surface._muiTrackButton)
    end
    if surface._muiBackButton then
        if type(surface._muiBackButton.SetEnabled) == "function" then
            surface._muiBackButton:SetEnabled(true)
        end
        UI.StyleQuestDetailsSurfaceActionButton(surface._muiBackButton)
    end
    if surface._muiAbandonButton then
        if type(surface._muiAbandonButton.SetEnabled) == "function" then
            surface._muiAbandonButton:SetEnabled(true)
        end
        UI.StyleQuestDetailsSurfaceActionButton(surface._muiAbandonButton)
    end
    if surface._muiShareButton then
        local canShare = (payload.canShare == true)
        if type(surface._muiShareButton.SetEnabled) == "function" then
            surface._muiShareButton:SetEnabled(canShare)
        end
        UI.StyleQuestDetailsSurfaceActionButton(surface._muiShareButton)
    end
end

function UI.EnsureQuestPanelTabButton(panel, modeKey)
    if not panel or not panel._muiTabsHost then return nil end
    panel._muiTabByKey = panel._muiTabByKey or {}
    panel._muiTabOrder = panel._muiTabOrder or {}
    if panel._muiTabByKey[modeKey] then return panel._muiTabByKey[modeKey] end

    local button = CreateFrame("Button", nil, panel._muiTabsHost)
    button:SetSize(C.QUEST_LOG_PANEL_TAB_WIDTH, C.QUEST_LOG_PANEL_TAB_HEIGHT)
    if type(button.SetHitRectInsets) == "function" then
        button:SetHitRectInsets(-2, -2, -2, -2)
    end
    button:RegisterForClicks("LeftButtonUp")
    button._muiModeKey = modeKey
    button._muiTabActive = false

    -- Tab background — transparent by default, subtle fill on active
    local bg = button:CreateTexture(nil, "BACKGROUND", nil, -5)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    button._muiTabBg = bg

    -- No heavy border — just bottom accent line
    local border = button:CreateTexture(nil, "BORDER")
    border:SetPoint("TOPLEFT", -1, 1)
    border:SetPoint("BOTTOMRIGHT", 1, -1)
    border:SetTexture(C.WHITE8X8)
    button._muiTabBorder = border

    local hover = button:CreateTexture(nil, "BACKGROUND", nil, -2)
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetAlpha(0)
    button._muiTabHover = hover

    -- Bottom accent indicator — the primary active state signal
    local accent = button:CreateTexture(nil, "ARTWORK")
    accent:SetPoint("BOTTOMLEFT", 4, 0)
    accent:SetPoint("BOTTOMRIGHT", -4, 0)
    accent:SetHeight(2)
    accent:SetTexture(C.WHITE8X8)
    accent:SetAlpha(0)
    button._muiTabAccent = accent

    -- Tiny dot indicator instead of 5x5 square — or hide entirely for cleanliness
    local glyph = button:CreateTexture(nil, "OVERLAY")
    glyph:SetSize(0, 0)
    glyph:SetPoint("LEFT", button, "LEFT", 9, 0)
    glyph:SetTexture(C.WHITE8X8)
    glyph:SetAlpha(0)
    button._muiTabGlyph = glyph

    -- Tab text — centered, clean
    local text = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("LEFT", button, "LEFT", 8, 0)
    text:SetPoint("RIGHT", button, "RIGHT", -8, 0)
    text:SetJustifyH("CENTER")
    if type(text.SetWordWrap) == "function" then
        text:SetWordWrap(false)
    end
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 0.50)
    text:SetText(UI.GetQuestPanelTabLabel(modeKey))
    button._muiTabText = text

    button:SetScript("OnClick", function(self)
        if self._muiTabDisabled == true then return end
        UI.SetQuestPanelDisplayMode(panel, self._muiModeKey)
    end)
    button:SetScript("OnEnter", function(self)
        UI.ApplyQuestPanelTabVisual(self, true)
    end)
    button:SetScript("OnLeave", function(self)
        UI.ApplyQuestPanelTabVisual(self, false)
    end)

    panel._muiTabByKey[modeKey] = button
    panel._muiTabOrder[#panel._muiTabOrder + 1] = button
    return button
end

Addon._MapQuestDecorativeAtlases = Addon._MapQuestDecorativeAtlases or {
    ["Options_List_Active"] = true,
    ["QuestLog-frame"] = true,
}

Addon._MapQuestDecorativeTextureIDs = Addon._MapQuestDecorativeTextureIDs or {
    [136788] = true,
    [1318750] = true,
    [5684767] = true,
}

function Addon.MapIsLikelyQuestDataIcon(texture)
    if not texture then return false end
    local atlas = type(texture.GetAtlas) == "function" and texture:GetAtlas() or nil
    if type(atlas) == "string" and atlas ~= "" then
        if atlas == "poi-hub" or atlas == "Raid" then return true end
        if atlas:find("^Quest") or atlas:find("^UI%-QuestPoi") or atlas:find("^Vignette") then
            return true
        end
        if atlas:find("^TaxiNode") or atlas:find("^CaveUnderground") then
            return true
        end
    end

    local width = Util.SafeMethodRead(texture, "GetWidth")
    local height = Util.SafeMethodRead(texture, "GetHeight")
    if type(width) == "number" and type(height) == "number" and width <= 32 and height <= 32 then
        return true
    end
    return false
end

function Addon.MapForceHideQuestDecorTexture(texture)
    if not texture or texture._muiQuestKeepArt then return end
    UI.HideTexture(texture)
    if type(texture.HookScript) == "function" and not texture._muiQuestDecorHideHook then
        texture:HookScript("OnShow", function(self)
            if self._muiQuestKeepArt then return end
            self:SetAlpha(0)
            self:Hide()
        end)
        texture._muiQuestDecorHideHook = true
    end
end

function Addon.MapShouldSuppressQuestDecorTexture(texture, ownerFrame)
    if not texture or texture._muiQuestKeepArt then return false end

    local atlas = type(texture.GetAtlas) == "function" and texture:GetAtlas() or nil
    local textureValue = type(texture.GetTexture) == "function" and texture:GetTexture() or nil
    local drawLayer = Util.SafeMethodRead(texture, "GetDrawLayer")
    local name = Util.SafeGetObjectName(texture) or ""
    local isIcon = Addon.MapIsLikelyQuestDataIcon(texture)
    local ownerIsButton = ownerFrame
        and type(ownerFrame.GetObjectType) == "function"
        and ownerFrame:GetObjectType() == "Button"

    if type(atlas) == "string" and Addon._MapQuestDecorativeAtlases and Addon._MapQuestDecorativeAtlases[atlas] then
        return true
    end
    if type(textureValue) == "number" and Addon._MapQuestDecorativeTextureIDs and Addon._MapQuestDecorativeTextureIDs[textureValue] and not isIcon then
        return true
    end
    if type(name) == "string" and name:find("Highlight") and not isIcon then
        if not ownerIsButton then
            return true
        end
    end
    if not isIcon and drawLayer == "BACKGROUND" then
        return true
    end
    if not isIcon and drawLayer == "HIGHLIGHT" and not ownerIsButton then
        return true
    end
    return false
end

function Addon.MapSuppressQuestDecorativeRegions(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
            if Addon.MapShouldSuppressQuestDecorTexture(region, frame) then
                if Util.IsQuestStructureProbeEnabled() and Util.ShouldEmitDebugToken("questStructure:decorSuppress:" .. Util.SafeToString(region), 0.20) then
                    local atlas = type(region.GetAtlas) == "function" and region:GetAtlas() or nil
                    local textureValue = type(region.GetTexture) == "function" and region:GetTexture() or nil
                    local drawLayer = Util.SafeMethodRead(region, "GetDrawLayer")
                    local reason = "unknown"
                    if type(atlas) == "string" and Addon._MapQuestDecorativeAtlases and Addon._MapQuestDecorativeAtlases[atlas] then
                        reason = "atlas"
                    elseif type(textureValue) == "number" and Addon._MapQuestDecorativeTextureIDs and Addon._MapQuestDecorativeTextureIDs[textureValue] then
                        reason = "textureID"
                    elseif type(drawLayer) == "string" and (drawLayer == "BACKGROUND" or drawLayer == "HIGHLIGHT") then
                        reason = "drawLayer"
                    end
                    Util.MapQuestStructureLog("debug", string.format(
                        "decorSuppress frame=%s region=%s reason=%s atlas=%s texture=%s layer=%s isIcon=%s",
                        Util.GetFrameDebugName(frame),
                        Util.GetFrameDebugName(region),
                        Util.SafeToString(reason),
                        Util.SafeToString(atlas),
                        Util.SafeToString(textureValue),
                        Util.SafeToString(drawLayer),
                        Addon.MapIsLikelyQuestDataIcon(region) and "true" or "false"
                    ), true)
                end
                Addon.MapForceHideQuestDecorTexture(region)
            end
        end
    end
end

function Addon.MapSuppressQuestDecorativeAnimations(frame, depth, visited)
    if not frame then return end
    depth = depth or 0
    if depth > 8 then return end
    visited = visited or {}
    if visited[frame] then return end
    visited[frame] = true

    if type(frame.GetAnimationGroups) == "function" then
        for _, group in ipairs({ frame:GetAnimationGroups() }) do
            if group and not group._muiQuestAnimSuppressed then
                if type(group.Stop) == "function" then
                    pcall(group.Stop, group)
                end
                if type(group.HookScript) == "function" then
                    group:HookScript("OnPlay", function(self)
                        if type(self.Stop) == "function" then
                            self:Stop()
                        end
                    end)
                end
                group._muiQuestAnimSuppressed = true
            end
        end
    end

    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            Addon.MapSuppressQuestDecorativeAnimations(child, depth + 1, visited)
        end
    end
end

function Addon.MapEnsureQuestEntryButtonStyle(button, modeKey)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if not button or type(button.GetObjectType) ~= "function" or button:GetObjectType() ~= "Button" then return end
    local width = Util.SafeMethodRead(button, "GetWidth")
    local height = Util.SafeMethodRead(button, "GetHeight")
    if type(width) ~= "number" or type(height) ~= "number" then return end
    if width < 120 or height < 16 or height > 64 then return end

    local modeStyle = Addon.GetMapQuestPanelModeStyle(modeKey)
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]
    local borderR, borderG, borderB = C.GetThemeColor("borderStrong")

    if not button._muiQuestEntryChrome then
        local edge = button:CreateTexture(nil, "BORDER", nil, -4)
        edge:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        edge:SetPoint("BOTTOMLEFT", button, "BOTTOMLEFT", 0, 0)
        edge:SetWidth(1)
        edge:SetTexture(C.WHITE8X8)
        edge._muiQuestKeepArt = true
        button._muiQuestEntryEdge = edge

        local hover = button:CreateTexture(nil, "HIGHLIGHT", nil, 1)
        hover:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        hover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        hover:SetTexture(C.WHITE8X8)
        hover:SetAlpha(0)
        hover._muiQuestKeepArt = true
        button._muiQuestEntryHover = hover

        button._muiQuestEntryChrome = true

        if type(button.HookScript) == "function" and not button._muiQuestEntryHooks then
            button:HookScript("OnEnter", function(self)
                if self._muiQuestEntryHover then self._muiQuestEntryHover:SetAlpha(1) end
                if self._muiQuestEntryEdge then self._muiQuestEntryEdge:SetAlpha(1) end
            end)
            button:HookScript("OnLeave", function(self)
                if self._muiQuestEntryHover then self._muiQuestEntryHover:SetAlpha(0) end
                if self._muiQuestEntryEdge then self._muiQuestEntryEdge:SetAlpha(0.55) end
            end)
            button:HookScript("OnMouseDown", function(self)
                if self._muiQuestEntryHover then self._muiQuestEntryHover:SetAlpha(0.45) end
            end)
            button:HookScript("OnMouseUp", function(self)
                if self._muiQuestEntryHover then
                    self._muiQuestEntryHover:SetAlpha(type(self.IsMouseOver) == "function" and self:IsMouseOver() and 1 or 0)
                end
            end)
            button:HookScript("OnShow", function(self)
                Addon.MapSuppressQuestDecorativeRegions(self)
            end)
            button._muiQuestEntryHooks = true
        end
    end

    if button._muiQuestEntryEdge then
        if type(button.IsMouseOver) == "function" and button:IsMouseOver() then
            button._muiQuestEntryEdge:SetVertexColor(accentR, accentG, accentB, 0.92)
            button._muiQuestEntryEdge:SetAlpha(1)
        else
            button._muiQuestEntryEdge:SetVertexColor(borderR, borderG, borderB, 0.36)
            button._muiQuestEntryEdge:SetAlpha(0.55)
        end
    end
    if button._muiQuestEntryHover then
        button._muiQuestEntryHover:SetVertexColor(accentR, accentG, accentB, 0.08)
    end

    if button._muiQuestEntryBg then
        button._muiQuestEntryBg:SetAlpha(0)
    end
    if button._muiQuestEntryBorder then
        button._muiQuestEntryBorder:SetAlpha(0)
    end
    if button._muiQuestEntryAccent then
        button._muiQuestEntryAccent:SetAlpha(0)
    end

    Addon.MapSuppressQuestDecorativeRegions(button)
end

function Addon.MapResolveQuestDetailsActionButtonKind(button)
    if not button then return nil end

    local name = Util.SafeGetObjectName(button)
    local nameLower = type(name) == "string" and string.lower(name) or nil
    if nameLower then
        if string.find(nameLower, "backbutton", 1, true) then return "back" end
        if string.find(nameLower, "trackbutton", 1, true) then return "track" end
        if string.find(nameLower, "sharebutton", 1, true) then return "share" end
        if string.find(nameLower, "abandonbutton", 1, true) then return "abandon" end
    end

    local labelText = nil
    if type(button.GetText) == "function" then
        local ok, value = pcall(button.GetText, button)
        if ok and type(value) == "string" and value ~= "" then
            labelText = value
        end
    end
    if (not labelText or labelText == "") and button.Text and type(button.Text.GetText) == "function" then
        local ok, value = pcall(button.Text.GetText, button.Text)
        if ok and type(value) == "string" and value ~= "" then
            labelText = value
        end
    end
    if not labelText or labelText == "" then
        return nil
    end

    local textLower = string.lower(labelText)
    local backText = _G.BACK and string.lower(_G.BACK) or "back"
    local trackText = _G.TRACK_QUEST and string.lower(_G.TRACK_QUEST) or "track"
    local shareText = _G.SHARE_QUEST and string.lower(_G.SHARE_QUEST) or "share"
    local abandonText = _G.ABANDON_QUEST and string.lower(_G.ABANDON_QUEST) or "abandon"
    if textLower == backText or string.find(textLower, "back", 1, true) then return "back" end
    if textLower == trackText or string.find(textLower, "track", 1, true) then return "track" end
    if textLower == shareText or string.find(textLower, "share", 1, true) then return "share" end
    if textLower == abandonText or string.find(textLower, "abandon", 1, true) then return "abandon" end
    return nil
end

function Addon.MapApplyQuestDetailsActionButtonVisual(button)
    if not button or not button._muiQuestDetailsActionKind then return end

    local modeStyle = Addon.GetMapQuestPanelModeStyle(button._muiQuestModeKey or "Quests")
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]
    local bgR, bgG, bgB = C.GetThemeColor("bgPanelRaised")
    local borderR, borderG, borderB = C.GetThemeColor("borderStrong")
    local textR, textG, textB = C.GetThemeColor("textPrimary")

    if button._muiQuestDetailsActionBg then
        button._muiQuestDetailsActionBg:SetVertexColor(bgR, bgG, bgB, 0.94)
    end
    if button._muiQuestDetailsActionBorder then
        local alpha = (button._muiQuestDetailsActionKind == "track" or button._muiQuestDetailsActionKind == "share") and 0.82 or 0.62
        button._muiQuestDetailsActionBorder:SetVertexColor(borderR, borderG, borderB, alpha)
    end
    if button._muiQuestDetailsActionHover then
        button._muiQuestDetailsActionHover:SetVertexColor(accentR, accentG, accentB, 0.12)
        if type(button.IsMouseOver) == "function" and button:IsMouseOver() then
            button._muiQuestDetailsActionHover:SetAlpha(1)
        else
            button._muiQuestDetailsActionHover:SetAlpha(0)
        end
    end

    local label = button.Text
    if not label and type(button.GetFontString) == "function" then
        local ok, fontString = pcall(button.GetFontString, button)
        if ok then
            label = fontString
        end
    end
    if label and type(label.SetTextColor) == "function" then
        local isDisabled = type(button.IsEnabled) == "function" and not button:IsEnabled()
        if isDisabled then
            label:SetTextColor(textR, textG, textB, 0.45)
        else
            label:SetTextColor(textR, textG, textB, 1)
        end
    end
end

function Addon.MapEnsureQuestDetailsActionButtonStyle(button, modeKey)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if not button or type(button.GetObjectType) ~= "function" or button:GetObjectType() ~= "Button" then return end

    local kind = Addon.MapResolveQuestDetailsActionButtonKind(button)
    if not kind then return end

    button._muiQuestModeKey = modeKey or "Quests"
    button._muiQuestDetailsActionKind = kind
    UI.SuppressButtonArt(button)
    Addon.MapSuppressQuestDecorativeRegions(button)

    if not button._muiQuestDetailsActionChrome then
        local bg = button:CreateTexture(nil, "BACKGROUND", nil, -5)
        bg:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        bg:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        bg:SetTexture(C.WHITE8X8)
        bg._muiQuestKeepArt = true
        button._muiQuestDetailsActionBg = bg

        local border = button:CreateTexture(nil, "BORDER", nil, -4)
        border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
        border:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", 0, 0)
        border:SetTexture(C.WHITE8X8)
        border._muiQuestKeepArt = true
        button._muiQuestDetailsActionBorder = border

        local hover = button:CreateTexture(nil, "HIGHLIGHT", nil, 1)
        hover:SetPoint("TOPLEFT", button, "TOPLEFT", 1, -1)
        hover:SetPoint("BOTTOMRIGHT", button, "BOTTOMRIGHT", -1, 1)
        hover:SetTexture(C.WHITE8X8)
        hover._muiQuestKeepArt = true
        button._muiQuestDetailsActionHover = hover

        button._muiQuestDetailsActionChrome = true
        if type(button.HookScript) == "function" and not button._muiQuestDetailsActionHooks then
            button:HookScript("OnEnter", Addon.MapApplyQuestDetailsActionButtonVisual)
            button:HookScript("OnLeave", Addon.MapApplyQuestDetailsActionButtonVisual)
            button:HookScript("OnMouseDown", function(self)
                if self._muiQuestDetailsActionHover then
                    self._muiQuestDetailsActionHover:SetAlpha(0.46)
                end
            end)
            button:HookScript("OnMouseUp", Addon.MapApplyQuestDetailsActionButtonVisual)
            button:HookScript("OnEnable", Addon.MapApplyQuestDetailsActionButtonVisual)
            button:HookScript("OnDisable", Addon.MapApplyQuestDetailsActionButtonVisual)
            button:HookScript("OnShow", Addon.MapApplyQuestDetailsActionButtonVisual)
            button._muiQuestDetailsActionHooks = true
        end
    end

    Addon.MapApplyQuestDetailsActionButtonVisual(button)
end

function Addon.MapFindQuestScrollBar(scrollContainer)
    if not scrollContainer then return nil end
    if scrollContainer.ScrollBar then return scrollContainer.ScrollBar end
    if scrollContainer.scrollBar then return scrollContainer.scrollBar end
    if scrollContainer.Scrollbar then return scrollContainer.Scrollbar end
    if type(scrollContainer.GetScrollBar) == "function" then
        local ok, scrollBar = pcall(scrollContainer.GetScrollBar, scrollContainer)
        if ok then return scrollBar end
    end
    return nil
end

function UI.UpdateQuestSearchPlaceholder(searchBox)
    if not searchBox then return end

    local placeholder = searchBox._muiQuestSearchPlaceholder
    local instructions = searchBox.Instructions
    if not placeholder and not instructions then return end

    local textValue = type(searchBox.GetText) == "function" and searchBox:GetText() or nil
    local hasText = type(textValue) == "string" and textValue ~= ""
    local focused = type(searchBox.HasFocus) == "function" and searchBox:HasFocus() or false
    local shouldShow = (not hasText) and (not focused)

    if instructions then
        if type(instructions.SetText) == "function" then
            instructions:SetText(_G.SEARCH_QUEST_LOG or "Search Quest Log")
        end
        if shouldShow then
            if type(instructions.Show) == "function" then instructions:Show() end
        else
            if type(instructions.Hide) == "function" then instructions:Hide() end
        end
    end

    if placeholder and placeholder ~= instructions then
        if shouldShow then
            if type(placeholder.Show) == "function" then placeholder:Show() end
        else
            if type(placeholder.Hide) == "function" then placeholder:Hide() end
        end
    end
end

function Addon.MapApplyQuestSearchBoxVisual(searchBox)
    if not searchBox then return end
    local modeStyle = Addon.GetMapQuestPanelModeStyle(searchBox._muiQuestModeKey)
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]
    local focus = type(searchBox.HasFocus) == "function" and searchBox:HasFocus() or false
    local hovered = type(searchBox.IsMouseOver) == "function" and searchBox:IsMouseOver() or false

    -- Background — dark, subtle
    if searchBox._muiQuestSearchBg then
        searchBox._muiQuestSearchBg:SetVertexColor(0.06, 0.05, 0.03, focus and 0.70 or 0.50)
    end
    -- Border — thin, barely visible unless focused
    if searchBox._muiQuestSearchBorder then
        if focus then
            searchBox._muiQuestSearchBorder:SetVertexColor(accentR, accentG, accentB, 0.55)
        elseif hovered then
            searchBox._muiQuestSearchBorder:SetVertexColor(0.42, 0.36, 0.24, 0.35)
        else
            searchBox._muiQuestSearchBorder:SetVertexColor(0.42, 0.36, 0.24, 0.20)
        end
    end
    -- Inner glow — very subtle
    if searchBox._muiQuestSearchGlow then
        searchBox._muiQuestSearchGlow:SetVertexColor(accentR, accentG, accentB, focus and 0.08 or 0.00)
    end
    -- Search icon
    if searchBox._muiQuestSearchIcon and type(searchBox._muiQuestSearchIcon.SetVertexColor) == "function" then
        searchBox._muiQuestSearchIcon:SetVertexColor(0.52, 0.46, 0.34, focus and 0.80 or 0.50)
        if type(searchBox._muiQuestSearchIcon.SetAlpha) == "function" then
            searchBox._muiQuestSearchIcon:SetAlpha(1)
        end
        if type(searchBox._muiQuestSearchIcon.Show) == "function" then
            searchBox._muiQuestSearchIcon:Show()
        end
    end
    local defaultSearchIcon = searchBox.SearchIcon or searchBox.searchIcon or searchBox.Icon
    if defaultSearchIcon and type(defaultSearchIcon.SetVertexColor) == "function" then
        defaultSearchIcon:SetVertexColor(0.52, 0.46, 0.34, focus and 0.80 or 0.50)
        if type(defaultSearchIcon.SetAlpha) == "function" then
            defaultSearchIcon:SetAlpha(1)
        end
        if type(defaultSearchIcon.Show) == "function" then
            defaultSearchIcon:Show()
        end
    end
    -- Placeholder text
    if searchBox._muiQuestSearchPlaceholder and type(searchBox._muiQuestSearchPlaceholder.SetTextColor) == "function" then
        searchBox._muiQuestSearchPlaceholder:SetTextColor(0.42, 0.38, 0.28, 0.55)
    end
    if searchBox.Instructions and type(searchBox.Instructions.SetTextColor) == "function" then
        searchBox.Instructions:SetTextColor(0.42, 0.38, 0.28, 0.55)
        if type(searchBox.Instructions.SetText) == "function" then
            searchBox.Instructions:SetText(_G.SEARCH_QUEST_LOG or "Search Quest Log")
        end
    end
    -- Input text
    if type(searchBox.SetTextColor) == "function" then
        searchBox:SetTextColor(0.94, 0.89, 0.78, 1)
    end
    if type(searchBox.SetAlpha) == "function" then
        searchBox:SetAlpha(1)
    end
    if type(searchBox.Show) == "function" then
        searchBox:Show()
    end

    UI.UpdateQuestSearchPlaceholder(searchBox)
end

function Addon.MapEnsureQuestSearchBoxStyle(scrollFrame, modeKey, questPanel)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if not scrollFrame then return end
    local searchBox = scrollFrame.SearchBox or scrollFrame.searchBox
    if not searchBox then return end

    searchBox._muiQuestModeKey = modeKey

    -- Store reference for quest list rebuild to read search text
    if questPanel then
        questPanel._muiQuestSearchBox = searchBox
    end

    if type(searchBox.GetRegions) == "function" then
        for _, region in ipairs({ searchBox:GetRegions() }) do
            if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
                if not region._muiQuestKeepArt then
                    Addon.MapForceHideQuestDecorTexture(region)
                end
            end
        end
    end

    local scrollBar = Addon.MapFindQuestScrollBar(scrollFrame)
    local searchHost = (questPanel and (questPanel._muiQuestSearchHost or questPanel._muiContentBanner)) or scrollFrame
    searchBox._muiQuestSearchHost = searchHost
    if type(searchBox.GetParent) == "function" and type(searchBox.SetParent) == "function" then
        local parent = searchBox:GetParent()
        if parent ~= searchHost then
            searchBox:SetParent(searchHost)
        end
    end

    if type(searchBox.ClearAllPoints) == "function" then
        searchBox:ClearAllPoints()
        if searchHost == scrollFrame then
            searchBox:SetPoint("TOPLEFT", scrollFrame, "TOPLEFT", 8, -12)
            searchBox:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", scrollBar and -30 or -8, -12)
        elseif questPanel and searchHost == questPanel._muiQuestSearchHost then
            searchBox:SetPoint("TOPLEFT", searchHost, "TOPLEFT", 0, 0)
            searchBox:SetPoint("BOTTOMRIGHT", searchHost, "BOTTOMRIGHT", 0, 0)
        else
            searchBox:SetPoint("TOPLEFT", searchHost, "TOPLEFT", 8, -3)
            searchBox:SetPoint("BOTTOMRIGHT", searchHost, "BOTTOMRIGHT", -8, 3)
        end
    end
    if type(searchBox.SetHeight) == "function" then
        searchBox:SetHeight(24)
    end
    if type(searchBox.SetFrameLevel) == "function" and searchHost and type(searchHost.GetFrameLevel) == "function" then
        local baseLevel = searchHost:GetFrameLevel() or 0
        local desiredLevel = baseLevel + 8
        local currentLevel = type(searchBox.GetFrameLevel) == "function" and searchBox:GetFrameLevel() or 0
        if currentLevel < desiredLevel then
            searchBox:SetFrameLevel(desiredLevel)
        end
    end
    if type(searchBox.SetTextInsets) == "function" then
        searchBox:SetTextInsets(34, 20, 0, 0)
    end
    if type(searchBox.SetAutoFocus) == "function" then
        searchBox:SetAutoFocus(false)
    end
    if type(searchBox.SetAlpha) == "function" then
        searchBox:SetAlpha(1)
    end
    if type(searchBox.Show) == "function" then
        searchBox:Show()
    end
    if searchBox.Instructions and type(searchBox.Instructions.ClearAllPoints) == "function" then
        searchBox.Instructions:ClearAllPoints()
        searchBox.Instructions:SetPoint("LEFT", searchBox, "LEFT", 34, 0)
        searchBox.Instructions:SetPoint("RIGHT", searchBox, "RIGHT", -20, 0)
        if type(searchBox.Instructions.SetJustifyH) == "function" then
            searchBox.Instructions:SetJustifyH("LEFT")
        end
        if type(searchBox.Instructions.SetText) == "function" then
            searchBox.Instructions:SetText(_G.SEARCH_QUEST_LOG or "Search Quest Log")
        end
        if type(searchBox.Instructions.Show) == "function" then
            searchBox.Instructions:Show()
        end
    end

    if not searchBox._muiQuestSearchBg then
        local bg = searchBox:CreateTexture(nil, "BACKGROUND", nil, -4)
        bg:SetAllPoints()
        bg:SetTexture(C.WHITE8X8)
        bg._muiQuestKeepArt = true
        searchBox._muiQuestSearchBg = bg

        local border = searchBox:CreateTexture(nil, "BORDER", nil, -3)
        border:SetPoint("TOPLEFT", searchBox, "TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", searchBox, "BOTTOMRIGHT", 1, -1)
        border:SetTexture(C.WHITE8X8)
        border._muiQuestKeepArt = true
        searchBox._muiQuestSearchBorder = border

        local glow = searchBox:CreateTexture(nil, "ARTWORK", nil, -2)
        glow:SetPoint("TOPLEFT", searchBox, "TOPLEFT", 1, -1)
        glow:SetPoint("BOTTOMRIGHT", searchBox, "BOTTOMRIGHT", -1, 1)
        glow:SetTexture(C.WHITE8X8)
        glow._muiQuestKeepArt = true
        searchBox._muiQuestSearchGlow = glow
    end

    local defaultSearchIcon = searchBox.SearchIcon or searchBox.searchIcon or searchBox.Icon
    local icon = defaultSearchIcon or searchBox._muiQuestSearchIcon
    if not icon then
        icon = searchBox:CreateTexture(nil, "OVERLAY", nil, 5)
        icon:SetTexture("Interface\\Common\\UI-Searchbox-Icon")
        icon._muiQuestKeepArt = true
        searchBox._muiQuestSearchIcon = icon
    end
    if defaultSearchIcon and searchBox._muiQuestSearchIcon and searchBox._muiQuestSearchIcon ~= defaultSearchIcon then
        if type(searchBox._muiQuestSearchIcon.Hide) == "function" then
            searchBox._muiQuestSearchIcon:Hide()
        end
    end
    searchBox._muiQuestSearchIcon = icon
    icon._muiQuestKeepArt = true
    icon:ClearAllPoints()
    icon:SetPoint("LEFT", searchBox, "LEFT", 10, 0)
    icon:SetSize(14, 14)
    if type(icon.SetAlpha) == "function" then icon:SetAlpha(1) end
    if type(icon.Show) == "function" then icon:Show() end

    local placeholder = searchBox._muiQuestSearchPlaceholder
    if not placeholder then
        placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        placeholder._muiQuestKeepArt = true
        searchBox._muiQuestSearchPlaceholder = placeholder
    end
    placeholder:ClearAllPoints()
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 34, 0)
    placeholder:SetPoint("RIGHT", searchBox, "RIGHT", -20, 0)
    placeholder:SetJustifyH("LEFT")
    placeholder:SetText(_G.SEARCH_QUEST_LOG or "Search Quest Log")

    local clearButton = searchBox.ClearButton or searchBox.clearButton
    if clearButton then
        UI.SuppressButtonArt(clearButton)
        if type(clearButton.ClearAllPoints) == "function" then
            clearButton:ClearAllPoints()
            clearButton:SetPoint("RIGHT", searchBox, "RIGHT", -6, 0)
        end
        if type(clearButton.SetSize) == "function" then
            clearButton:SetSize(14, 14)
        end
        if not clearButton._muiQuestSearchClearBg then
            local clearBg = clearButton:CreateTexture(nil, "BACKGROUND")
            clearBg:SetPoint("TOPLEFT", clearButton, "TOPLEFT", 0, 0)
            clearBg:SetPoint("BOTTOMRIGHT", clearButton, "BOTTOMRIGHT", 0, 0)
            clearBg:SetTexture(C.WHITE8X8)
            clearBg._muiQuestKeepArt = true
            clearButton._muiQuestSearchClearBg = clearBg

            local clearLabel = clearButton:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            clearLabel:SetPoint("CENTER", clearButton, "CENTER", 0, 0)
            clearLabel:SetText("x")
            clearButton._muiQuestSearchClearLabel = clearLabel
        end
        local clearBgR, clearBgG, clearBgB = C.GetThemeColor("bgPanelAlt")
        clearButton._muiQuestSearchClearBg:SetVertexColor(clearBgR, clearBgG, clearBgB, 0.92)
        if clearButton._muiQuestSearchClearLabel and type(clearButton._muiQuestSearchClearLabel.SetTextColor) == "function" then
            local textR, textG, textB = C.GetThemeColor("textPrimary")
            clearButton._muiQuestSearchClearLabel:SetTextColor(textR, textG, textB, 1)
        end
    end

    if type(searchBox.HookScript) == "function" and not searchBox._muiQuestSearchHooks then
        searchBox:HookScript("OnEditFocusGained", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
        end)
        searchBox:HookScript("OnEditFocusLost", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
        end)
        searchBox:HookScript("OnEnter", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
        end)
        searchBox:HookScript("OnLeave", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
        end)
        searchBox:HookScript("OnTextChanged", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
            RebuildQuestListLayout()
        end)
        searchBox:HookScript("OnShow", function(self)
            Addon.MapApplyQuestSearchBoxVisual(self)
        end)
        searchBox:HookScript("OnHide", function(self)
            local map = _G.WorldMapFrame
            local panel = map and map._muiQuestLogPanel or nil
            local isMapShown = (map and type(map.IsShown) == "function" and map:IsShown()) or false

            if Runtime.questLogPanelOpen == true
                and isMapShown
                and panel and panel._muiQuestPanelAnimating ~= true
                and C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, function()
                    if not self or not map or not map:IsShown() then return end
                    if panel and panel._muiQuestPanelAnimating then return end
                    if type(self.Show) == "function" then
                        self:Show()
                    end
                    Addon.MapApplyQuestSearchBoxVisual(self)
                end)
            end
        end)
        searchBox._muiQuestSearchHooks = true
    end

    Addon.MapApplyQuestSearchBoxVisual(searchBox)

    if Util.IsQuestStructureProbeEnabled() and Util.ShouldEmitDebugToken("questStructure:SearchBoxStyle:" .. Util.SafeToString(modeKey), 0.08) then
    end
end

function Addon.MapApplyQuestSettingsDropdownVisual(settingsDropdown)
    if not settingsDropdown then return end

    local legendStyle = Addon.GetMapQuestPanelModeStyle("MapLegend")
    local modeStyle = Addon.GetMapQuestPanelModeStyle(settingsDropdown._muiQuestModeKey)
    local legendR, legendG, legendB = legendStyle.accent[1], legendStyle.accent[2], legendStyle.accent[3]
    local activeR, activeG, activeB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]
    local hovered = (settingsDropdown._muiQuestGearHovered == true)

    local tintR, tintG, tintB = legendR, legendG, legendB
    local iconAlpha = 0.90
    if hovered then
        tintR, tintG, tintB = activeR, activeG, activeB
        iconAlpha = 1.0
    end

    if settingsDropdown._muiQuestGearBg then
        if type(settingsDropdown._muiQuestGearBg.SetVertexColor) == "function" then
            settingsDropdown._muiQuestGearBg:SetVertexColor(0, 0, 0, 0)
        end
        if type(settingsDropdown._muiQuestGearBg.Hide) == "function" then
            settingsDropdown._muiQuestGearBg:Hide()
        end
    end
    if settingsDropdown._muiQuestGearBorder then
        if type(settingsDropdown._muiQuestGearBorder.SetVertexColor) == "function" then
            settingsDropdown._muiQuestGearBorder:SetVertexColor(0, 0, 0, 0)
        end
        if type(settingsDropdown._muiQuestGearBorder.Hide) == "function" then
            settingsDropdown._muiQuestGearBorder:Hide()
        end
    end
    if settingsDropdown._muiQuestSettingsIcon and type(settingsDropdown._muiQuestSettingsIcon.SetVertexColor) == "function" then
        settingsDropdown._muiQuestSettingsIcon:SetVertexColor(tintR, tintG, tintB, iconAlpha)
    end
end

function Addon.MapEnsureQuestSettingsDropdownStyle(scrollFrame, modeKey, questPanel)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if not scrollFrame then return end
    local gearButtonSize = 18

    local settingsDropdown = scrollFrame.SettingsDropdown or scrollFrame.settingsDropdown
    if not settingsDropdown and type(scrollFrame.GetChildren) == "function" then
        for _, child in ipairs({ scrollFrame:GetChildren() }) do
            local childName = Util.SafeGetObjectName(child) or ""
            if childName:find("SettingsDropdown") then
                settingsDropdown = child
                break
            end
        end
    end

    local modeText = questPanel and questPanel._muiHeaderModeText or nil
    local modeBadge = questPanel and questPanel._muiHeaderModeBadge or nil
    local minimizeButton = questPanel and questPanel._muiHeaderMinimizeButton or nil
    local useBadgeGear = (modeBadge ~= nil)
    if not settingsDropdown then
        if useBadgeGear and minimizeButton and type(minimizeButton.ClearAllPoints) == "function" and type(minimizeButton.SetPoint) == "function" then
            minimizeButton:ClearAllPoints()
            minimizeButton:SetPoint("RIGHT", modeBadge, "LEFT", -4, 0)
            if type(UI.ApplyQuestPanelMinimizeButtonVisual) == "function" then
                UI.ApplyQuestPanelMinimizeButtonVisual(minimizeButton, false)
            end
        end
        if useBadgeGear and modeText and type(modeText.SetText) == "function" then
            modeText:SetText(UI.GetQuestPanelTabLabel(modeKey))
            if type(modeText.Show) == "function" then
                modeText:Show()
            end
        end
        return
    end

    settingsDropdown._muiQuestKeepArt = true
    settingsDropdown._muiQuestModeKey = modeKey

    local icon = settingsDropdown.Icon or settingsDropdown.icon
    if not icon and type(settingsDropdown.GetRegions) == "function" then
        for _, region in ipairs({ settingsDropdown:GetRegions() }) do
            if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
                local atlas = type(region.GetAtlas) == "function" and region:GetAtlas() or nil
                local regionName = Util.SafeGetObjectName(region) or ""
                if (type(atlas) == "string" and atlas:find("Options"))
                    or (regionName ~= "" and regionName:find("Icon")) then
                    icon = region
                    break
                end
            end
        end
    end

    if useBadgeGear and modeText and type(modeText.SetText) == "function" then
        if icon then
            modeText:SetText("")
            if type(modeText.Hide) == "function" then
                modeText:Hide()
            end
        else
            modeText:SetText(UI.GetQuestPanelTabLabel(modeKey))
            if type(modeText.Show) == "function" then
                modeText:Show()
            end
            if type(settingsDropdown.Show) == "function" then
                settingsDropdown:Show()
            end

            if not settingsDropdown._muiQuestGearIconRetryQueued and C_Timer and type(C_Timer.After) == "function" then
                settingsDropdown._muiQuestGearIconRetryQueued = true
                local retryMode = Util.SafeToString(modeKey or "Quests")
                C_Timer.After(0, function()
                    if not settingsDropdown then return end
                    settingsDropdown._muiQuestGearIconRetryQueued = nil
                    Addon.MapEnsureQuestSettingsDropdownStyle(scrollFrame, retryMode, questPanel)
                end)
            end
            return
        end
    end

    settingsDropdown._muiQuestSettingsIcon = icon

    if icon then
        icon._muiQuestKeepArt = true
        if type(icon.ClearAllPoints) == "function" then
            icon:ClearAllPoints()
            icon:SetPoint("CENTER", settingsDropdown, "CENTER", 0, 0)
        end
        if type(icon.SetSize) == "function" then
            icon:SetSize(14, 14)
        end
        if type(icon.SetDrawLayer) == "function" then
            icon:SetDrawLayer("OVERLAY", 6)
        end
        if type(icon.Show) == "function" then
            icon:Show()
        end
    end

    UI.HideTextureRegions(settingsDropdown, icon)
    UI.SuppressControlHighlight(settingsDropdown)
    if settingsDropdown.Text and type(settingsDropdown.Text.Hide) == "function" then
        settingsDropdown.Text:Hide()
    end

    if useBadgeGear then
        if settingsDropdown:GetParent() ~= modeBadge then
            settingsDropdown:SetParent(modeBadge)
        end
        if type(settingsDropdown.SetFrameStrata) == "function" and questPanel then
            settingsDropdown:SetFrameStrata(questPanel:GetFrameStrata())
        end
        if type(settingsDropdown.SetFrameLevel) == "function" then
            settingsDropdown:SetFrameLevel(modeBadge:GetFrameLevel() + 6)
        end
        if type(settingsDropdown.ClearAllPoints) == "function" then
            settingsDropdown:ClearAllPoints()
            settingsDropdown:SetPoint("CENTER", modeBadge, "CENTER", -1, 0)
        end
        if type(settingsDropdown.SetSize) == "function" then
            settingsDropdown:SetSize(gearButtonSize, gearButtonSize)
        end
        if type(settingsDropdown.SetHitRectInsets) == "function" then
            settingsDropdown:SetHitRectInsets(0, 0, 0, 0)
        end
        if type(settingsDropdown.SetClipsChildren) == "function" then
            settingsDropdown:SetClipsChildren(true)
        end

        local clickTargets = {}
        if settingsDropdown.DropDownButton then
            clickTargets[#clickTargets + 1] = settingsDropdown.DropDownButton
        end
        if settingsDropdown.ArrowButton then
            clickTargets[#clickTargets + 1] = settingsDropdown.ArrowButton
        end
        if settingsDropdown.Button then
            clickTargets[#clickTargets + 1] = settingsDropdown.Button
        end
        for i = 1, #clickTargets do
            local target = clickTargets[i]
            UI.SuppressButtonArt(target)
            if type(target.ClearAllPoints) == "function" then
                target:ClearAllPoints()
                target:SetPoint("TOPLEFT", settingsDropdown, "TOPLEFT", 0, 0)
                target:SetPoint("BOTTOMRIGHT", settingsDropdown, "BOTTOMRIGHT", 0, 0)
            end
            if type(target.SetSize) == "function" then
                target:SetSize(gearButtonSize, gearButtonSize)
            end
            if type(target.SetHitRectInsets) == "function" then
                target:SetHitRectInsets(0, 0, 0, 0)
            end
            if type(target.EnableMouse) == "function" then
                target:EnableMouse(true)
            end
            if type(target.Show) == "function" then
                target:Show()
            end
            if type(target.HookScript) == "function" and not target._muiQuestGearHoverHook then
                target:HookScript("OnEnter", function()
                    settingsDropdown._muiQuestGearHovered = true
                    Addon.MapApplyQuestSettingsDropdownVisual(settingsDropdown)
                end)
                target:HookScript("OnLeave", function()
                    settingsDropdown._muiQuestGearHovered = false
                    Addon.MapApplyQuestSettingsDropdownVisual(settingsDropdown)
                end)
                target._muiQuestGearHoverHook = true
            end
        end
        if type(settingsDropdown.EnableMouse) == "function" then
            settingsDropdown:EnableMouse(true)
        end
        if type(settingsDropdown.Show) == "function" then
            settingsDropdown:Show()
        end
        if type(settingsDropdown.HookScript) == "function" and not settingsDropdown._muiQuestGearHoverHooks then
            settingsDropdown:HookScript("OnEnter", function(self)
                self._muiQuestGearHovered = true
                Addon.MapApplyQuestSettingsDropdownVisual(self)
            end)
            settingsDropdown:HookScript("OnLeave", function(self)
                self._muiQuestGearHovered = false
                Addon.MapApplyQuestSettingsDropdownVisual(self)
            end)
            settingsDropdown:HookScript("OnShow", function(self)
                Addon.MapApplyQuestSettingsDropdownVisual(self)
            end)
            settingsDropdown._muiQuestGearHoverHooks = true
        end
        settingsDropdown._muiQuestGearHovered = false
        Addon.MapApplyQuestSettingsDropdownVisual(settingsDropdown)
        if minimizeButton and type(minimizeButton.ClearAllPoints) == "function" and type(minimizeButton.SetPoint) == "function" then
            minimizeButton:ClearAllPoints()
            minimizeButton:SetPoint("RIGHT", settingsDropdown, "LEFT", -4, 0)
            if type(UI.ApplyQuestPanelMinimizeButtonVisual) == "function" then
                UI.ApplyQuestPanelMinimizeButtonVisual(minimizeButton, false)
            end
        end
    else
        if settingsDropdown:GetParent() ~= scrollFrame then
            settingsDropdown:SetParent(scrollFrame)
        end
        if type(settingsDropdown.ClearAllPoints) == "function" then
            local scrollBar = Addon.MapFindQuestScrollBar(scrollFrame)
            settingsDropdown:ClearAllPoints()
            settingsDropdown:SetPoint("TOPRIGHT", scrollFrame, "TOPRIGHT", scrollBar and -30 or -8, -40)
        end
        if type(settingsDropdown.Hide) == "function" then
            settingsDropdown:Hide()
        end
    end
end

function Addon.MapUpdateQuestScrollbarVisibility(scrollContainer, scrollBar)
    if not scrollBar then return end

    local minValue, maxValue = nil, nil
    if type(scrollBar.GetMinMaxValues) == "function" then
        local ok, minV, maxV = pcall(scrollBar.GetMinMaxValues, scrollBar)
        if ok then
            minValue = minV
            maxValue = maxV
        end
    end

    local range = 0
    if type(minValue) == "number" and type(maxValue) == "number" then
        range = math.abs(maxValue - minValue)
    end
    if range <= 0 and scrollContainer and type(scrollContainer.GetVerticalScrollRange) == "function" then
        local ok, value = pcall(scrollContainer.GetVerticalScrollRange, scrollContainer)
        if ok and type(value) == "number" then
            range = math.abs(value)
        end
    end

    local shouldShow = range > 1
    if shouldShow then
        if type(scrollBar.SetAlpha) == "function" then scrollBar:SetAlpha(1) end
        if type(scrollBar.EnableMouse) == "function" then scrollBar:EnableMouse(true) end
    else
        if type(scrollBar.SetAlpha) == "function" then scrollBar:SetAlpha(0) end
        if type(scrollBar.EnableMouse) == "function" then scrollBar:EnableMouse(false) end
    end
end

function Addon.MapEnsureQuestScrollbarStyle(scrollContainer, modeKey)
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end
    if not scrollContainer then return end
    local scrollBar = Addon.MapFindQuestScrollBar(scrollContainer)
    if not scrollBar then return end

    scrollBar._muiQuestModeKey = modeKey
    scrollBar._muiQuestOwnerScroll = scrollContainer

    local upButton = scrollBar.ScrollUpButton or scrollBar.UpButton or scrollBar.DecrementButton
    local downButton = scrollBar.ScrollDownButton or scrollBar.DownButton or scrollBar.IncrementButton
    local function HideArrowButton(button)
        if not button then return end
        UI.SuppressButtonArt(button)
        if type(button.EnableMouse) == "function" then button:EnableMouse(false) end
        if type(button.SetAlpha) == "function" then button:SetAlpha(0) end
        if type(button.Hide) == "function" then button:Hide() end
        if type(button.HookScript) == "function" and not button._muiQuestHideHook then
            button:HookScript("OnShow", function(self)
                if type(self.SetAlpha) == "function" then self:SetAlpha(0) end
                if type(self.Hide) == "function" then self:Hide() end
            end)
            button._muiQuestHideHook = true
        end
    end
    HideArrowButton(upButton)
    HideArrowButton(downButton)

    if type(scrollBar.GetRegions) == "function" then
        for _, region in ipairs({ scrollBar:GetRegions() }) do
            if region and type(region.GetObjectType) == "function" and region:GetObjectType() == "Texture" then
                if not region._muiQuestKeepArt then
                    Addon.MapForceHideQuestDecorTexture(region)
                end
            end
        end
    end

    if not scrollBar._muiQuestScrollTrack then
        local track = scrollBar:CreateTexture(nil, "BACKGROUND", nil, -2)
        track:SetPoint("TOPLEFT", scrollBar, "TOPLEFT", 2, -2)
        track:SetPoint("BOTTOMRIGHT", scrollBar, "BOTTOMRIGHT", -2, 2)
        track:SetTexture(C.WHITE8X8)
        track._muiQuestKeepArt = true
        scrollBar._muiQuestScrollTrack = track
    end

    if not scrollBar._muiQuestScrollThumb then
        local thumb = scrollBar:CreateTexture(nil, "ARTWORK", nil, 3)
        thumb:SetTexture(C.WHITE8X8)
        thumb:SetSize(6, 28)
        thumb._muiQuestKeepArt = true
        scrollBar._muiQuestScrollThumb = thumb
        if type(scrollBar.SetThumbTexture) == "function" then
            scrollBar:SetThumbTexture(thumb)
        end
    elseif type(scrollBar.SetThumbTexture) == "function" then
        scrollBar:SetThumbTexture(scrollBar._muiQuestScrollThumb)
    end

    if type(scrollBar.SetWidth) == "function" then
        scrollBar:SetWidth(10)
    end

    local modeStyle = Addon.GetMapQuestPanelModeStyle(modeKey)
    local accentR, accentG, accentB = modeStyle.accent[1], modeStyle.accent[2], modeStyle.accent[3]
    if scrollBar._muiQuestScrollTrack then
        local trackR, trackG, trackB = C.GetThemeColor("bgPanelRaised")
        scrollBar._muiQuestScrollTrack:SetVertexColor(trackR, trackG, trackB, 0.74)
    end
    if scrollBar._muiQuestScrollThumb then
        scrollBar._muiQuestScrollThumb:SetVertexColor(accentR, accentG, accentB, 0.92)
    end

    if type(scrollBar.HookScript) == "function" and not scrollBar._muiQuestScrollShowHook then
        scrollBar:HookScript("OnShow", function(self)
            Addon.MapUpdateQuestScrollbarVisibility(self._muiQuestOwnerScroll, self)
        end)
        scrollBar._muiQuestScrollShowHook = true
    end

    if not scrollBar._muiQuestScrollValueHook then
        local hookedValueWatcher = false
        if type(scrollBar.HasScript) == "function" and type(scrollBar.HookScript) == "function" then
            local hasScriptOk, hasScript = pcall(scrollBar.HasScript, scrollBar, "OnValueChanged")
            if hasScriptOk and hasScript then
                local hookOk = pcall(scrollBar.HookScript, scrollBar, "OnValueChanged", function(self)
                    Addon.MapUpdateQuestScrollbarVisibility(self._muiQuestOwnerScroll, self)
                end)
                hookedValueWatcher = (hookOk == true)
            end
        end
        if not hookedValueWatcher and type(scrollBar.SetValue) == "function" then
            local hookOk = pcall(hooksecurefunc, scrollBar, "SetValue", function(self)
                Addon.MapUpdateQuestScrollbarVisibility(self._muiQuestOwnerScroll, self)
            end)
            hookedValueWatcher = (hookOk == true)
        end
        scrollBar._muiQuestScrollValueHook = hookedValueWatcher and true or "none"
    end
    if type(scrollBar.SetMinMaxValues) == "function" and not scrollBar._muiQuestScrollRangeHook then
        hooksecurefunc(scrollBar, "SetMinMaxValues", function(self)
            Addon.MapUpdateQuestScrollbarVisibility(self._muiQuestOwnerScroll, self)
        end)
        scrollBar._muiQuestScrollRangeHook = true
    end
    if type(scrollContainer.HookScript) == "function" and not scrollContainer._muiQuestScrollOwnerHooks then
        scrollContainer:HookScript("OnShow", function(self)
            Addon.MapUpdateQuestScrollbarVisibility(self, Addon.MapFindQuestScrollBar(self))
        end)
        scrollContainer:HookScript("OnSizeChanged", function(self)
            Addon.MapUpdateQuestScrollbarVisibility(self, Addon.MapFindQuestScrollBar(self))
        end)
        scrollContainer._muiQuestScrollOwnerHooks = true
    end

    local scrollChild = scrollContainer.ScrollChild
    if not scrollChild and type(scrollContainer.GetScrollChild) == "function" then
        local ok, child = pcall(scrollContainer.GetScrollChild, scrollContainer)
        if ok then scrollChild = child end
    end
    if scrollChild and type(scrollChild.HookScript) == "function" and not scrollChild._muiQuestScrollChildHook then
        scrollChild:HookScript("OnSizeChanged", function()
            Addon.MapUpdateQuestScrollbarVisibility(scrollContainer, scrollBar)
            local map = _G.WorldMapFrame
            local panel = map and map._muiQuestLogPanel or nil
            local questFrame = (panel and panel._muiQuestOverlayFrame) or _G.QuestMapFrame
            if questFrame then
                local modeKey = UI.ResolveQuestDisplayModeKey(questFrame, panel)
                Addon.MapApplyQuestCampaignRowSpacing(questFrame, modeKey)
            end
        end)
        scrollChild._muiQuestScrollChildHook = true
    end

    Addon.MapUpdateQuestScrollbarVisibility(scrollContainer, scrollBar)
end

function Addon.MapNormalizeQuestOverlayContent(questFrame, questPanel)
    if not questFrame then return end

    local function AnchorFill(frame, target)
        if not frame or not target then return end
        if type(frame.ClearAllPoints) ~= "function" or type(frame.SetPoint) ~= "function" then return end
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", target, "TOPLEFT", 0, 0)
        frame:SetPoint("BOTTOMRIGHT", target, "BOTTOMRIGHT", 0, 0)
    end

    local host = questPanel and (questPanel._muiContentInner or questPanel._muiContentHost) or nil
    local rootTarget = host or questFrame
    local contentsAnchor = questFrame.ContentsAnchor
    local questsFrame = questFrame.QuestsFrame
    local eventsFrame = questFrame.EventsFrame
    local legendFrame = questFrame.MapLegend
    local contentTarget = contentsAnchor or rootTarget

    if type(questFrame.SetClipsChildren) == "function" then
        questFrame:SetClipsChildren(true)
    end

    -- Rebuild Blizzard quest content anchors inside MidnightUI's content region.
    if contentsAnchor then
        AnchorFill(contentsAnchor, rootTarget)
        if type(contentsAnchor.SetClipsChildren) == "function" then
            contentsAnchor:SetClipsChildren(true)
        end
        contentTarget = contentsAnchor
    end

    if questsFrame then
        AnchorFill(questsFrame, contentTarget)
        if type(questsFrame.SetClipsChildren) == "function" then
            questsFrame:SetClipsChildren(true)
        end
    end
    if eventsFrame then
        AnchorFill(eventsFrame, contentTarget)
        if type(eventsFrame.SetClipsChildren) == "function" then
            eventsFrame:SetClipsChildren(true)
        end
    end
    if legendFrame then
        AnchorFill(legendFrame, contentTarget)
        if type(legendFrame.SetClipsChildren) == "function" then
            legendFrame:SetClipsChildren(true)
        end
    end

    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    if questScrollFrame and questsFrame then
        AnchorFill(questScrollFrame, questsFrame)
        if type(questScrollFrame.SetClipsChildren) == "function" then
            questScrollFrame:SetClipsChildren(true)
        end
    end
end

function Addon.MapEnsureQuestOverlayRenderOrder(questPanel, questFrame)
    if not questPanel then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end

    local panelLevel = Util.SafeMethodRead(questPanel, "GetFrameLevel") or 0
    local panelStrata = Util.SafeMethodRead(questPanel, "GetFrameStrata") or C.QUEST_LOG_PANEL_STRATA or "DIALOG"

    local function SetFrameZ(frame, level, force)
        if not frame then return end
        if type(frame.SetFrameStrata) == "function" then
            frame:SetFrameStrata(panelStrata)
        end
        if type(level) == "number" and type(frame.SetFrameLevel) == "function" then
            local current = Util.SafeMethodRead(frame, "GetFrameLevel")
            if force == true or type(current) ~= "number" or current < level then
                frame:SetFrameLevel(level)
            end
        end
    end

    local function PromoteTree(frame, level, depth, visited)
        if not frame or depth > 3 then return end
        visited = visited or {}
        if visited[frame] then return end
        visited[frame] = true

        SetFrameZ(frame, level, false)
        if type(frame.GetChildren) == "function" then
            for _, child in ipairs({ frame:GetChildren() }) do
                PromoteTree(child, level + 1, depth + 1, visited)
            end
        end
    end

    SetFrameZ(questPanel._muiHeader, panelLevel + 8, true)
    SetFrameZ(questPanel._muiHeaderModeBadge, panelLevel + 12, true)
    SetFrameZ(questPanel._muiTabsHost, panelLevel + 10, true)
    SetFrameZ(questPanel._muiContentHost, panelLevel + 5, true)
    SetFrameZ(questPanel._muiContentBanner, panelLevel + 7, true)
    SetFrameZ(questPanel._muiContentInner, panelLevel + 9, true)
    SetFrameZ(questPanel._muiQuestSearchHost, panelLevel + 11, true)

    local overlay = questFrame or questPanel._muiQuestOverlayFrame
    if not overlay then return end

    SetFrameZ(overlay, panelLevel + 20, true)
    SetFrameZ(overlay.ContentsAnchor, panelLevel + 21, true)

    local questsFrame = overlay.QuestsFrame
    local eventsFrame = overlay.EventsFrame
    local legendFrame = overlay.MapLegend
    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    local eventsScrollBox = eventsFrame and eventsFrame.ScrollBox or nil
    local eventsScrollTarget = eventsScrollBox and eventsScrollBox.ScrollTarget or nil
    local legendScrollFrame = (legendFrame and legendFrame.ScrollFrame) or _G.MapLegendScrollFrame
    local searchBox = questScrollFrame and (questScrollFrame.SearchBox or questScrollFrame.searchBox) or nil
    local questScrollChild = (type(Addon.MapResolveQuestScrollChild) == "function") and Addon.MapResolveQuestScrollChild(questScrollFrame) or nil
    local legendScrollChild = (type(Addon.MapResolveQuestScrollChild) == "function") and Addon.MapResolveQuestScrollChild(legendScrollFrame) or nil

    SetFrameZ(questsFrame, panelLevel + 22, true)
    SetFrameZ(eventsFrame, panelLevel + 22, true)
    SetFrameZ(legendFrame, panelLevel + 22, true)
    SetFrameZ(questScrollFrame, panelLevel + 23, true)
    SetFrameZ(eventsScrollBox, panelLevel + 23, true)
    SetFrameZ(eventsScrollTarget, panelLevel + 24, true)
    SetFrameZ(legendScrollFrame, panelLevel + 23, true)
    SetFrameZ(questScrollChild, panelLevel + 24, true)
    SetFrameZ(legendScrollChild, panelLevel + 24, true)
    SetFrameZ(searchBox, panelLevel + 26, true)

    PromoteTree(questScrollChild, panelLevel + 25, 0)
    PromoteTree(eventsScrollTarget, panelLevel + 25, 0)
    PromoteTree(legendScrollChild, panelLevel + 25, 0)
end

function Addon.MapEnsureQuestModeFrameVisibility(questFrame, modeKey, questPanel)
    if not questFrame then return end

    local resolvedMode = modeKey
    if resolvedMode ~= "Quests" and resolvedMode ~= "Events" and resolvedMode ~= "MapLegend" then
        resolvedMode = UI.ResolveQuestDisplayModeKey(questFrame, questPanel)
    end
    if resolvedMode ~= "Quests" and resolvedMode ~= "Events" and resolvedMode ~= "MapLegend" then
        resolvedMode = "Quests"
    end

    local questsFrame = questFrame.QuestsFrame
    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    local eventsFrame = questFrame.EventsFrame
    local eventsScrollBox = eventsFrame and eventsFrame.ScrollBox or nil
    local eventsScrollTarget = eventsScrollBox and eventsScrollBox.ScrollTarget or nil
    local legendFrame = questFrame.MapLegend
    local legendScrollFrame = (legendFrame and legendFrame.ScrollFrame) or _G.MapLegendScrollFrame

    local function SetFrameShown(frame, wantShown)
        if not frame then return end
        if wantShown then
            if type(frame.Show) == "function" then
                frame:Show()
            end
            if type(frame.SetAlpha) == "function" then
                frame:SetAlpha(1)
            end
        else
            if type(frame.Hide) == "function" then
                frame:Hide()
            end
        end
    end

    local showQuests = (resolvedMode == "Quests")
    local showEvents = (resolvedMode == "Events")
    local showLegend = (resolvedMode == "MapLegend")

    SetFrameShown(questsFrame, showQuests)
    SetFrameShown(questScrollFrame, showQuests)
    SetFrameShown(eventsFrame, showEvents)
    SetFrameShown(eventsScrollBox, showEvents)
    SetFrameShown(eventsScrollTarget, showEvents)
    SetFrameShown(legendFrame, showLegend)
    SetFrameShown(legendScrollFrame, showLegend)
end

function Addon.MapStyleQuestPanelModeContent(questFrame, modeKey)
    if not questFrame then return end

    -- MidnightUI owns Quests mode rendering (list + custom details surface).
    if modeKey == "Quests" then return end

    local questPanel = nil
    local map = _G.WorldMapFrame
    if map and map._muiQuestLogPanel and map._muiQuestLogPanel._muiQuestOverlayFrame == questFrame then
        questPanel = map._muiQuestLogPanel
    end

    local targets = {}
    local seen = {}
    local function Add(frame)
        if frame and not seen[frame] then
            seen[frame] = true
            targets[#targets + 1] = frame
        end
    end

    local questsFrame = questFrame.QuestsFrame
    local eventsFrame = questFrame.EventsFrame
    local legendFrame = questFrame.MapLegend
    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    local legendScrollFrame = (legendFrame and legendFrame.ScrollFrame) or _G.MapLegendScrollFrame

    Addon.MapNormalizeQuestOverlayContent(questFrame, questPanel)
    Addon.MapEnsureQuestOverlayRenderOrder(questPanel, questFrame)
    Addon.MapEnsureQuestModeFrameVisibility(questFrame, modeKey, questPanel)
    Addon.MapEnsureQuestOverlayRenderOrder(questPanel, questFrame)
    questsFrame = questFrame.QuestsFrame
    eventsFrame = questFrame.EventsFrame
    legendFrame = questFrame.MapLegend
    questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    legendScrollFrame = (legendFrame and legendFrame.ScrollFrame) or _G.MapLegendScrollFrame

    Addon.MapEnsureQuestSearchBoxStyle(questScrollFrame, modeKey, questPanel)
    Addon.MapEnsureQuestSettingsDropdownStyle(questScrollFrame, modeKey, questPanel)
    Addon.MapEnsureQuestScrollbarStyle(questScrollFrame, modeKey)
    Addon.MapEnsureQuestScrollbarStyle(eventsFrame and eventsFrame.ScrollBox or nil, modeKey)
    Addon.MapEnsureQuestScrollbarStyle(legendScrollFrame, modeKey)
    Addon.MapApplyQuestCampaignRowSpacing(questFrame, modeKey)

    Add(questFrame)
    Add(questScrollFrame)
    Add(questScrollFrame and questScrollFrame.ScrollChild or nil)
    Add(eventsFrame and eventsFrame.ScrollBox or nil)
    Add(eventsFrame and eventsFrame.ScrollBox and eventsFrame.ScrollBox.ScrollTarget or nil)
    Add(legendScrollFrame)
    Add(legendScrollFrame and legendScrollFrame.ScrollChild or nil)
    Add(_G.MapLegendScrollFrame)

    local function Walk(frame, depth)
        if not frame or depth > 5 then return end
        Addon.MapSuppressQuestDecorativeRegions(frame)

        if type(frame.GetObjectType) == "function" and frame:GetObjectType() == "Button" then
            Addon.MapEnsureQuestEntryButtonStyle(frame, modeKey)
            if modeKey == "Quests" then
                Addon.MapEnsureQuestDetailsActionButtonStyle(frame, modeKey)
            end
        end

        if type(frame.GetChildren) == "function" then
            for _, child in ipairs({ frame:GetChildren() }) do
                Walk(child, depth + 1)
            end
        end
    end

    for i = 1, #targets do
        Walk(targets[i], 0)
    end

    -- Remove default decorative anims from content panes while preserving data widgets.
    if modeKey == "Events" or modeKey == "MapLegend" then
        for i = 1, #targets do
            Addon.MapSuppressQuestDecorativeAnimations(targets[i], 0)
        end
    end

    if modeKey == "Quests" and Util.IsQuestStructureProbeEnabled()
        and Util.ShouldEmitDebugToken("questStructure:stylePass:" .. Util.SafeToString(modeKey), 0.08) then
    end
end

function UI.SuppressQuestFrameDefaultTabs(questFrame)
    if not questFrame then return end

    local function ForceHideTab(tab)
        if not tab then return end
        if type(tab.EnableMouse) == "function" then tab:EnableMouse(false) end
        if type(tab.SetAlpha) == "function" then tab:SetAlpha(0) end
        if type(tab.Hide) == "function" then tab:Hide() end
        if type(tab.HookScript) == "function" and not tab._muiQuestTabHideHook then
            tab:HookScript("OnShow", function(self)
                self:SetAlpha(0)
                self:Hide()
            end)
            tab._muiQuestTabHideHook = true
        end
    end

    ForceHideTab(questFrame.QuestsTab)
    ForceHideTab(questFrame.EventsTab)
    ForceHideTab(questFrame.MapLegendTab)
end

function UI.SuppressQuestFrameDefaultArtwork(questFrame)
    if not questFrame then return end

    local function SuppressTextureNode(texture)
        if not texture then return end
        UI.HideTexture(texture)
        if type(texture.HookScript) == "function" and not texture._muiQuestArtHideHook then
            texture:HookScript("OnShow", function(self)
                self:SetAlpha(0)
                self:Hide()
            end)
            texture._muiQuestArtHideHook = true
        end
    end

    local function SuppressFrameArt(frame, hideFrame)
        if not frame then return end
        UI.HideFrameRegions(frame)
        UI.HideTextureRegions(frame)
        SuppressTextureNode(frame.Background)
        SuppressTextureNode(frame.Background2)
        SuppressTextureNode(frame.Bg)
        SuppressTextureNode(frame.Border)
        SuppressTextureNode(frame.TopDetail)
        SuppressTextureNode(frame.Shadow)
        SuppressTextureNode(frame.Highlight)
        if frame.NineSlice then
            UI.HideFrameRegions(frame.NineSlice)
            UI.HideTextureRegions(frame.NineSlice)
            SuppressTextureNode(frame.NineSlice)
        end
        if hideFrame then
            if type(frame.EnableMouse) == "function" then frame:EnableMouse(false) end
        end
        if type(frame.HookScript) == "function" and not frame._muiQuestArtHideHook then
            frame:HookScript("OnShow", function(self)
                UI.HideFrameRegions(self)
                UI.HideTextureRegions(self)
                SuppressTextureNode(self.Background)
                SuppressTextureNode(self.Background2)
                SuppressTextureNode(self.Bg)
                SuppressTextureNode(self.Border)
                SuppressTextureNode(self.TopDetail)
                SuppressTextureNode(self.Shadow)
                SuppressTextureNode(self.Highlight)
                if self.NineSlice then
                    UI.HideFrameRegions(self.NineSlice)
                    UI.HideTextureRegions(self.NineSlice)
                    SuppressTextureNode(self.NineSlice)
                end
                if hideFrame then
                    if type(self.EnableMouse) == "function" then self:EnableMouse(false) end
                end
            end)
            frame._muiQuestArtHideHook = true
        end
    end

    local function HideFrameChrome(frame)
        if not frame then return end
        SuppressTextureNode(frame.Background)
        SuppressTextureNode(frame.Bg)
        SuppressTextureNode(frame.TitleText)
        if frame.NineSlice then
            UI.HideFrameRegions(frame.NineSlice)
            UI.HideTextureRegions(frame.NineSlice)
            SuppressTextureNode(frame.NineSlice)
        end
    end

    UI.SuppressQuestFrameDefaultTabs(questFrame)
    HideFrameChrome(questFrame)
    SuppressTextureNode(questFrame.VerticalSeparator)

    local questsFrame = questFrame.QuestsFrame
    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    if questsFrame then
        HideFrameChrome(questsFrame)
    end
    if questsFrame and questsFrame.ScrollFrame then
        SuppressTextureNode(questsFrame.ScrollFrame.Background)
        SuppressTextureNode(questsFrame.ScrollFrame.Edge)
    end
    if questsFrame and questsFrame.BorderFrame then
        SuppressFrameArt(questsFrame.BorderFrame, true)
    end
    if questScrollFrame then
        SuppressTextureNode(questScrollFrame.Background)
        SuppressTextureNode(questScrollFrame.Edge)
        if questScrollFrame.BorderFrame then
            SuppressFrameArt(questScrollFrame.BorderFrame, true)
            SuppressTextureNode(questScrollFrame.BorderFrame.Border)
            SuppressTextureNode(questScrollFrame.BorderFrame.TopDetail)
            SuppressTextureNode(questScrollFrame.BorderFrame.Shadow)
        end
    end

    local eventsFrame = questFrame.EventsFrame
    if eventsFrame then
        HideFrameChrome(eventsFrame)
        SuppressTextureNode(eventsFrame.TitleText)
        if eventsFrame.BorderFrame then
            SuppressFrameArt(eventsFrame.BorderFrame, true)
            SuppressTextureNode(eventsFrame.BorderFrame.Border)
            SuppressTextureNode(eventsFrame.BorderFrame.TopDetail)
            SuppressTextureNode(eventsFrame.BorderFrame.Shadow)
        end
        if eventsFrame.ScrollBox then
            SuppressTextureNode(eventsFrame.ScrollBox.Background)
            SuppressTextureNode(eventsFrame.ScrollBox.Shadows)
            if eventsFrame.ScrollBox.ScrollTarget then
                SuppressTextureNode(eventsFrame.ScrollBox.ScrollTarget.Background)
                SuppressTextureNode(eventsFrame.ScrollBox.ScrollTarget.Background2)
                SuppressTextureNode(eventsFrame.ScrollBox.ScrollTarget.Highlight)
            end
        end
    end

    local legendFrame = questFrame.MapLegend
    local legendScrollFrame = (legendFrame and legendFrame.ScrollFrame) or _G.MapLegendScrollFrame
    if legendFrame then
        HideFrameChrome(legendFrame)
        SuppressTextureNode(legendFrame.TitleText)
        if legendFrame.BorderFrame then
            SuppressFrameArt(legendFrame.BorderFrame, true)
            SuppressTextureNode(legendFrame.BorderFrame.Border)
            SuppressTextureNode(legendFrame.BorderFrame.TopDetail)
            SuppressTextureNode(legendFrame.BorderFrame.Shadow)
        end
        if legendFrame.ScrollFrame then
            SuppressTextureNode(legendFrame.ScrollFrame.Background)
            SuppressTextureNode(legendFrame.ScrollFrame.Edge)
        end
    end
    if legendScrollFrame and legendScrollFrame.BorderFrame then
        SuppressFrameArt(legendScrollFrame.BorderFrame, true)
        SuppressTextureNode(legendScrollFrame.BorderFrame.Border)
        SuppressTextureNode(legendScrollFrame.BorderFrame.TopDetail)
        SuppressTextureNode(legendScrollFrame.BorderFrame.Shadow)
    end

    local activeModeKey = UI.ResolveQuestDisplayModeKey(questFrame, nil)
    Addon.MapStyleQuestPanelModeContent(questFrame, activeModeKey)
end

function UI.ResolveQuestOverlayFrame(map)
    local candidates = {
        _G.QuestMapFrame,
        map and map.QuestLogFrame and map.QuestLogFrame.ContentsFrame or nil,
        map and map.QuestLogFrame or nil,
        map and map.QuestsFrame or nil,
        _G.WorldMapFrameQuestLogFrame,
        _G.QuestLogFrame,
    }

    for i = 1, #candidates do
        local frame = candidates[i]
        if frame and type(frame.SetParent) == "function" and type(frame.ClearAllPoints) == "function" then
            return frame
        end
    end
    return nil
end

function Addon.MapSafeQuestTextSnippet(value, maxLength)
    if type(value) ~= "string" then return "nil" end
    local text = value:gsub("\r", "\\r"):gsub("\n", "\\n")
    if text == "" then return "<empty>" end
    local limit = type(maxLength) == "number" and maxLength or 64
    if #text > limit then
        return text:sub(1, limit) .. "..."
    end
    return text
end

function Addon.MapBuildQuestObjectStateLine(label, object)
    if not object then
        return Util.SafeToString(label) .. "=nil"
    end

    local objectType = Util.SafeGetObjectType(object) or "Unknown"
    local name = Util.SafeGetObjectName(object) or Util.SafeToString(object)
    local shown = (object.IsShown and object:IsShown()) and "true" or "false"
    local parent = Util.SafeMethodRead(object, "GetParent")
    local alpha = Util.SafeMethodRead(object, "GetAlpha")
    local left = Util.SafeMethodRead(object, "GetLeft")
    local right = Util.SafeMethodRead(object, "GetRight")
    local top = Util.SafeMethodRead(object, "GetTop")
    local bottom = Util.SafeMethodRead(object, "GetBottom")
    local width = Util.SafeMethodRead(object, "GetWidth")
    local height = Util.SafeMethodRead(object, "GetHeight")
    local keepArt = (object._muiQuestKeepArt == true) and "true" or "false"
    local textNote = ""

    if objectType == "FontString" and type(object.GetText) == "function" then
        local ok, text = pcall(object.GetText, object)
        if ok then
            textNote = " text=" .. Util.SafeToString(Addon.MapSafeQuestTextSnippet(text, 80))
        end
    end

    return string.format(
        "%s type=%s name=%s shown=%s alpha=%s parent=%s keepArt=%s L=%s R=%s T=%s B=%s W=%s H=%s%s",
        Util.SafeToString(label),
        Util.SafeToString(objectType),
        Util.SafeToString(name),
        shown,
        Util.FormatNumber(alpha),
        Util.GetFrameDebugName(parent),
        keepArt,
        Util.FormatNumber(left),
        Util.FormatNumber(right),
        Util.FormatNumber(top),
        Util.FormatNumber(bottom),
        Util.FormatNumber(width),
        Util.FormatNumber(height),
        textNote
    )
end

function Addon.MapResolveQuestScrollChild(scrollFrame)
    if not scrollFrame then return nil end
    local child = scrollFrame.ScrollChild or scrollFrame.scrollChild or scrollFrame.Child
    if child then return child end
    if type(scrollFrame.GetScrollChild) == "function" then
        local ok, resolved = pcall(scrollFrame.GetScrollChild, scrollFrame)
        if ok then return resolved end
    end
    return nil
end

-- ============================================================================
-- CUSTOM QUEST LIST SYSTEM (Modern Card & Fill Redesign)
-- ============================================================================

local questListCollapseState = {} -- { ["Zone Header Title"] = true/false }
local bucketCollapseState = { now = false, next = false, later = false }

local questListPools = {
    headers = {},
    quests = {},
    objectives = {},
    empty = {},
    bucketHeaders = {},
    focusHeaders = {},
    zoneBanners = {},
    zoneSubHeaders = {},
    comboBoxes = {},
    abandonButtons = {},
}

local questRowContextMenuFrame = nil

local function StopQuestListAnimationGroup(animGroup)
    if not animGroup or type(animGroup.IsPlaying) ~= "function" or type(animGroup.Stop) ~= "function" then
        return
    end
    local okPlaying, isPlaying = pcall(animGroup.IsPlaying, animGroup)
    if okPlaying and isPlaying then
        pcall(animGroup.Stop, animGroup)
    end
end

local function ResetQuestListPooledRow(row)
    if not row then
        return
    end

    StopQuestListAnimationGroup(row._pulseGroup)
    StopQuestListAnimationGroup(row._upgradePulse)

    if type(row.SetAlpha) == "function" then
        row:SetAlpha(1)
    end
    if type(row.ClearAllPoints) == "function" then
        row:ClearAllPoints()
    end
    if type(row.Hide) == "function" then
        row:Hide()
    end
end

function QEngine.QuestListAcquireFromPool(poolKey, createFunc, parent)
    local pool = questListPools[poolKey]
    if type(pool) ~= "table" then
        pool = {}
        questListPools[poolKey] = pool
    end

    for i = 1, #pool do
        local row = pool[i]
        if row and not row._muiQuestListInUse then
            row._muiQuestListInUse = true
            if parent and type(row.SetParent) == "function" then
                local currentParent = (type(row.GetParent) == "function") and row:GetParent() or nil
                if currentParent ~= parent then
                    row:SetParent(parent)
                end
            end
            if type(row.SetAlpha) == "function" then
                row:SetAlpha(1)
            end
            if type(row.Show) == "function" then
                row:Show()
            end
            return row
        end
    end

    if type(createFunc) ~= "function" then
        return nil
    end

    local okCreate, row = pcall(createFunc, parent)
    if not okCreate or not row then
        return nil
    end

    row._muiQuestListPoolKey = poolKey
    row._muiQuestListInUse = true
    pool[#pool + 1] = row

    if type(row.SetAlpha) == "function" then
        row:SetAlpha(1)
    end
    if type(row.Show) == "function" then
        row:Show()
    end

    return row
end

function QEngine.QuestListReleaseAllInPool(poolKey)
    local pool = questListPools[poolKey]
    if type(pool) ~= "table" then
        return
    end

    for i = 1, #pool do
        local row = pool[i]
        if row then
            row._muiQuestListInUse = false
            ResetQuestListPooledRow(row)
        end
    end
end

-- ============================================================================
-- SMART QUEST ENGINE â€" Bucket Colors & Constants
-- ============================================================================
local BUCKET_COLORS = {
    now   = { r = 0.98, g = 0.60, b = 0.22, hex = "FA9938" },
    next  = { r = 0.45, g = 0.72, b = 0.92, hex = "73B8EB" },
    later = { r = 0.58, g = 0.52, b = 0.43, hex = "94856E" },
}
local BUCKET_LABELS = { now = "NOW", next = "NEXT", later = "LATER" }
local BUCKET_ORDER  = { "now", "next", "later" }
local FOCUS_LABEL = "FOCUS"
local FOCUS_COLOR = { r = 1.00, g = 0.84, b = 0.30 }

function UI.SetFocusedQuest(questID, reason, suppressRebuild)
    local normalizedQuestID = nil
    if type(questID) == "number" and questID > 0 then
        normalizedQuestID = questID
    end

    local previousQuestID = Runtime.focusedQuestID
    Runtime.focusedQuestID = normalizedQuestID

    if previousQuestID ~= normalizedQuestID then
    end

    if suppressRebuild ~= true and type(RebuildQuestListLayout) == "function" then
        RebuildQuestListLayout()
    end
end

function UI.ClearFocusedQuest(reason, suppressRebuild)
    UI.SetFocusedQuest(nil, reason or "clear", suppressRebuild)
end

function QEngine.ExtractFocusedQuestFromBuckets(listData)
    local focusedQuestID = Runtime.focusedQuestID
    if type(focusedQuestID) ~= "number" or type(listData) ~= "table" or type(listData.buckets) ~= "table" then
        return nil, nil
    end

    for i = 1, #BUCKET_ORDER do
        local bucketKey = BUCKET_ORDER[i]
        local quests = listData.buckets[bucketKey]
        if type(quests) == "table" then
            for questIndex = 1, #quests do
                local questData = quests[questIndex]
                if type(questData) == "table" and questData.questID == focusedQuestID then
                    table.remove(quests, questIndex)
                    return questData, bucketKey
                end
            end
        end
    end

    if type(C_QuestLog) == "table" and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local okIndex, questLogIndex = pcall(C_QuestLog.GetLogIndexForQuestID, focusedQuestID)
        if okIndex and type(questLogIndex) == "number" and questLogIndex > 0 then
            return nil, nil
        end
    end

    Runtime.focusedQuestID = nil
    return nil, nil
end

function UI.OpenQuestRowContextMenu(anchorFrame, questID, questTitle)
    if type(questID) ~= "number" or questID <= 0 then
        return
    end

    local isFocused = (Runtime.focusedQuestID == questID)
    local focusActionText = isFocused and "Unfocus Quest" or "Focus Quest"
    local titleText = Addon.MapSafeQuestTextSnippet(questTitle, 56)
    local initialQuestLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)
    local canShareNow = UI.EvaluateQuestShareable(questID, initialQuestLogIndex)
    local canAbandonNow = UI.EvaluateQuestAbandonable(questID, initialQuestLogIndex)
    local shareActionText = "Share Quest"
    local abandonActionText = canAbandonNow and "Abandon Quest" or "Abandon Quest (Unavailable)"

    local function HandleFocusAction()
        if Runtime.focusedQuestID == questID then
            UI.ClearFocusedQuest("QuestRowContext:Unfocus")
        else
            UI.SetFocusedQuest(questID, "QuestRowContext:Focus")
        end
    end

    local function HandleShareAction()
        local questLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)
        if type(questLogIndex) == "number" and type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, questLogIndex)
        end
        if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end

        if not UI.EvaluateQuestShareable(questID, questLogIndex) then
            return
        end

        local shared = false
        if type(QuestMapQuestOptions_ShareQuest) == "function" then
            local okShare = pcall(QuestMapQuestOptions_ShareQuest, questID)
            shared = (okShare == true)
        end
        if not shared and type(QuestLogPushQuest) == "function" then
            local okPush = pcall(QuestLogPushQuest)
            shared = (okPush == true)
        end
        if not shared and type(C_QuestLog) == "table" and type(C_QuestLog.ShareQuest) == "function" then
            local okNative = pcall(C_QuestLog.ShareQuest, questID)
            shared = (okNative == true)
        end
    end

    local function HandleAbandonAction()
        local questLogIndex = UI.ResolveQuestLogIndexForQuestID(questID)
        if not UI.EvaluateQuestAbandonable(questID, questLogIndex) then
            return
        end

        local worldMap = _G.WorldMapFrame
        local panel = worldMap and worldMap._muiQuestLogPanel or nil
        if panel and type(UI.ShowQuestDetailsAbandonDialog) == "function" then
            UI.ShowQuestDetailsAbandonDialog(panel, questID, titleText)
            return
        end

        if type(UI.ExecuteQuestAbandonForDetails) == "function" then
            UI.ExecuteQuestAbandonForDetails(panel, questID)
        end
    end

    if type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) == "function" then
        local okMenu = pcall(MenuUtil.CreateContextMenu, anchorFrame, function(_, rootDescription)
            if not rootDescription or type(rootDescription.CreateButton) ~= "function" then
                return
            end
            rootDescription:CreateButton(focusActionText, HandleFocusAction)
            local shareButtonDesc = rootDescription:CreateButton(shareActionText, HandleShareAction)
            if shareButtonDesc and type(shareButtonDesc.SetEnabled) == "function" then
                shareButtonDesc:SetEnabled(canShareNow)
            end
            rootDescription:CreateButton(abandonActionText, HandleAbandonAction)
            if Runtime.focusedQuestID and Runtime.focusedQuestID ~= questID then
                rootDescription:CreateButton("Clear Focus", function()
                    UI.ClearFocusedQuest("QuestRowContext:Clear")
                end)
            end
        end)
        if okMenu then
            return
        end
    end

    if type(EasyMenu) == "function" then
        if not questRowContextMenuFrame then
            questRowContextMenuFrame = CreateFrame("Frame", nil, UIParent, "UIDropDownMenuTemplate")
        end

        local menu = {
            {
                text = Util.SafeToString(titleText),
                isTitle = true,
                notCheckable = true,
            },
            {
                text = focusActionText,
                notCheckable = true,
                func = HandleFocusAction,
            },
            {
                text = shareActionText,
                notCheckable = true,
                disabled = not canShareNow,
                func = HandleShareAction,
            },
            {
                text = abandonActionText,
                notCheckable = true,
                disabled = not canAbandonNow,
                func = HandleAbandonAction,
            },
        }

        if Runtime.focusedQuestID and Runtime.focusedQuestID ~= questID then
            menu[#menu + 1] = {
                text = "Clear Focus",
                notCheckable = true,
                func = function()
                    UI.ClearFocusedQuest("QuestRowContext:Clear")
                end,
            }
        end

        if type(CloseDropDownMenus) == "function" then
            CloseDropDownMenus()
        end
        EasyMenu(menu, questRowContextMenuFrame, "cursor", 0, 0, "MENU", 2)
        return
    end

    HandleFocusAction()
end

-- Native WoW Quest Difficulty Colors
local DIFFICULTY_COLORS = {
    trivial    = { r = 0.50, g = 0.50, b = 0.50 },  -- Grey
    standard   = { r = 0.25, g = 0.75, b = 0.25 },  -- Green
    difficult  = { r = 1.00, g = 0.82, b = 0.00 },  -- Yellow
    veryhard   = { r = 1.00, g = 0.50, b = 0.25 },  -- Orange
    impossible = { r = 1.00, g = 0.10, b = 0.10 },  -- Red
}

local COMBO_PURPLE = { r = 0.58, g = 0.42, b = 0.78 }
local NEARLY_COMPLETE_THRESHOLD = 0.80

QUEST_LIST_VISUALS = {
    -- Backgrounds: transparent — negative space defines layout
    contentInnerBg = { r = 0, g = 0, b = 0, a = 0 },
    zoneBannerBg = { r = 0, g = 0, b = 0, a = 0 },
    headerBg = { r = 0, g = 0, b = 0, a = 0 },
    headerCutout = { r = 0, g = 0, b = 0, a = 0 },
    divider = { r = 0, g = 0, b = 0, a = 0 },
    -- Quest rows: NO backgrounds — clean list style
    rowBg = { r = 0, g = 0, b = 0, a = 0 },
    rowBgHover = { r = 0, g = 0, b = 0, a = 0 },
    rowDivider = { r = 0, g = 0, b = 0, a = 0 },
    -- Progress tracks
    progressTrack = { r = 0.20, g = 0.17, b = 0.12, a = 0.20 },
    progressTrackBg = { r = 0.04, g = 0.03, b = 0.02, a = 0.30 },
    -- Typography: aggressive contrast hierarchy
    textPrimary = { r = 0.94, g = 0.90, b = 0.80 },
    textSecondary = { r = 0.62, g = 0.56, b = 0.44 },
    textMuted = { r = 0.42, g = 0.38, b = 0.28 },
    textBright = { r = 1.00, g = 0.97, b = 0.90 },
    -- Semantic
    success = { r = 0.34, g = 0.82, b = 0.46 },
    successDim = { r = 0.28, g = 0.68, b = 0.38, a = 0.06 },
    story = { r = 1.00, g = 0.84, b = 0.28 },
    warning = { r = 1.00, g = 0.52, b = 0.20 },
    nearlyComplete = { r = 0.34, g = 0.82, b = 0.46, a = 0 },
    glassHighlight = { r = 0, g = 0, b = 0, a = 0 },
    glassShadow = { r = 0, g = 0, b = 0, a = 0 },
    glassReflection = { r = 0, g = 0, b = 0, a = 0 },
}

QEngine._metaCache = {}

function QEngine.GetQuestDifficultyColorMuted(questLevel, playerLevel)
    if type(questLevel) ~= "number" or questLevel <= 0 then
        return DIFFICULTY_COLORS.standard
    end
    if type(playerLevel) ~= "number" or playerLevel <= 0 then
        playerLevel = UnitLevel("player") or 1
    end
    local greenRange = type(GetQuestGreenRange) == "function" and GetQuestGreenRange() or 8
    local diff = questLevel - playerLevel
    if diff >= 5 then
        return DIFFICULTY_COLORS.impossible
    elseif diff >= 3 then
        return DIFFICULTY_COLORS.veryhard
    elseif diff >= -2 then
        return DIFFICULTY_COLORS.difficult
    elseif diff >= -greenRange - 1 then
        return DIFFICULTY_COLORS.standard
    else
        return DIFFICULTY_COLORS.trivial
    end
end

-- ============================================================================
-- SMART QUEST ENGINE â€" Data Collection & Bucketing
-- ============================================================================

-- Gather raw quest data from C_QuestLog
function QEngine.CollectRawQuestEntries(searchFilter)
    local entries = {}
    if type(C_QuestLog) ~= "table" or type(C_QuestLog.GetNumQuestLogEntries) ~= "function"
        or type(C_QuestLog.GetInfo) ~= "function" then
        return entries
    end

    local okNum, numEntries = pcall(C_QuestLog.GetNumQuestLogEntries)
    if not okNum or type(numEntries) ~= "number" then
        return entries
    end

    local lowerFilter = nil
    if type(searchFilter) == "string" and searchFilter ~= "" then
        lowerFilter = searchFilter:lower()
    end

    local currentHeaderTitle = nil
    for i = 1, numEntries do
        local okInfo, info = pcall(C_QuestLog.GetInfo, i)
        if okInfo and type(info) == "table" and not info.isHidden and not info.isInternalOnly then
            if info.isHeader then
                currentHeaderTitle = info.title or ""
            elseif currentHeaderTitle and info.questID then
                local passesFilter = true
                if lowerFilter then
                    passesFilter = info.title and info.title:lower():find(lowerFilter, 1, true)
                end
                if passesFilter then
                    local objectives = {}
                    if type(C_QuestLog.GetQuestObjectives) == "function" then
                        local okObj, objs = pcall(C_QuestLog.GetQuestObjectives, info.questID)
                        if (not okObj or type(objs) ~= "table") and type(i) == "number" then
                            local okObjByIndex, objsByIndex = pcall(C_QuestLog.GetQuestObjectives, i)
                            if okObjByIndex and type(objsByIndex) == "table" then
                                okObj = true
                                objs = objsByIndex
                            end
                        end
                        if okObj and type(objs) == "table" then
                            objectives = objs
                        end
                    end

                    -- Gather quest tag for group/elite detection
                    local questTagInfo = nil
                    if type(C_QuestLog.GetQuestTagInfo) == "function" then
                        local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, info.questID)
                        if okTag and type(tag) == "table" then
                            questTagInfo = tag
                        end
                    end

                    -- Determine if quest is on the same map as the player
                    local questMapID = nil
                    if type(C_QuestLog.GetQuestAdditionalHighlights) == "function" then
                        -- not available on all builds; skip
                    end
                    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
                        -- we store the player map separately
                    end

                    -- Check if quest is shared in party
                    local isSharedInParty = false
                    if type(C_QuestLog.IsQuestSharedWithPlayerByPlayerName) == "function" then
                        -- This API doesn't exist; we use a different approach below
                    end

                    entries[#entries + 1] = {
                        title = info.title or "",
                        questID = info.questID,
                        questLogIndex = i,
                        level = info.level,
                        isComplete = info.isComplete,
                        frequency = info.frequency,
                        objectives = objectives,
                        headerTitle = currentHeaderTitle,
                        suggestedGroup = info.suggestedGroup,
                        isAutoComplete = info.isAutoComplete,
                        questTagInfo = questTagInfo,
                    }
                end
            end
        end
    end
    return entries
end

-- Determine the player's current zone and relevant context
function QEngine.GetPlayerQuestContext()
    local ctx = {
        playerLevel = UnitLevel("player") or 1,
        zoneName = GetZoneText() or "",
        subZone = GetSubZoneText() or "",
        mapID = nil,
        continentID = nil,
        isInInstance = false,
        instanceName = nil,
        instanceID = nil,
        isInGroup = false,
        groupSize = 0,
        partyQuestIDs = {},
        maxQuests = 35,
        playerX = nil,
        playerY = nil,
        equippedIlvl = QEngine.GetPlayerEquippedIlvl(),
    }

    -- Instance detection
    local inInstance, instanceType = IsInInstance()
    ctx.isInInstance = (inInstance == true or inInstance == 1)
    if ctx.isInInstance then
        local name, _, _, _, _, _, _, instID = GetInstanceInfo()
        ctx.instanceName = name
        ctx.instanceID = instID
    end

    -- Current map
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        local okMap, mapID = pcall(C_Map.GetBestMapForUnit, "player")
        if okMap and type(mapID) == "number" then
            ctx.mapID = mapID
            -- Get continent
            if type(C_Map.GetMapInfo) == "function" then
                local okInfo, mapInfo = pcall(C_Map.GetMapInfo, mapID)
                if okInfo and type(mapInfo) == "table" then
                    ctx.continentID = mapInfo.parentMapID
                end
            end
            -- Get player position
            if type(C_Map.GetPlayerMapPosition) == "function" then
                local okPos, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
                if okPos and pos and type(pos.GetXY) == "function" then
                    ctx.playerX, ctx.playerY = pos:GetXY()
                end
            end
        end
    end

    -- Group info
    local numGroup = GetNumGroupMembers()
    if type(numGroup) == "number" and numGroup > 0 then
        ctx.isInGroup = true
        ctx.groupSize = numGroup
        -- Collect party members' quest IDs for co-op detection
        if type(C_QuestLog) == "table" and type(C_QuestLog.IsQuestFlaggedCompleted) == "function" then
            for i = 1, numGroup - 1 do
                local unit = (IsInRaid() and ("raid" .. i)) or ("party" .. i)
                if UnitExists(unit) then
                    -- We can only detect shared quests via quest log flags
                end
            end
        end
    end

    -- Max quest capacity
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetMaxNumQuestsCanAccept) == "function" then
        local okMax, maxQ = pcall(C_QuestLog.GetMaxNumQuestsCanAccept)
        if okMax and type(maxQ) == "number" and maxQ > 0 then
            ctx.maxQuests = maxQ
        end
    elseif type(MAX_QUESTS) == "number" then
        ctx.maxQuests = MAX_QUESTS
    end

    return ctx
end

-- Check if a quest is for the current zone/instance
function QEngine.IsQuestInCurrentZone(quest, ctx)
    if not quest or not ctx then return false end
    -- Header title often matches zone name
    if type(quest.headerTitle) == "string" and type(ctx.zoneName) == "string" then
        if quest.headerTitle == ctx.zoneName then return true end
    end
    -- Check quest map ID if available
    if ctx.mapID and type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestAdditionalHighlights) ~= "function" then
        -- Fallback: check if quest has waypoint on current map
        if type(C_QuestLog.IsOnMap) == "function" then
            local okOnMap, onMap = pcall(C_QuestLog.IsOnMap, quest.questID)
            if okOnMap and onMap then return true end
        end
    end
    return false
end

-- Check if quest is elite/group type
function QEngine.IsGroupOrEliteQuest(quest)
    if not quest then return false end
    local tag = quest.questTagInfo
    if type(tag) == "table" then
        if tag.isElite then return true end
        if type(tag.tagID) == "number" then
            -- Group quest tag IDs: 1=Group, 41=PvP, 62=Raid, 81=Dungeon, 82=WorldEvent
            if tag.tagID == 1 or tag.tagID == 62 or tag.tagID == 81 then
                return true
            end
        end
    end
    if type(quest.suggestedGroup) == "number" and quest.suggestedGroup > 1 then
        return true
    end
    return false
end

-- Check if a quest is trivial (grey) or impossibly hard (red/skull)
function QEngine.IsQuestOutleveled(quest, playerLevel)
    if type(quest.level) ~= "number" or quest.level <= 0 then return false end
    local diff = quest.level - playerLevel
    local greenRange = type(GetQuestGreenRange) == "function" and GetQuestGreenRange() or 8
    if diff < -(greenRange + 1) then return true, "trivial" end
    if diff >= 10 then return true, "impossible" end
    return false
end

-- Calculate quest proximity score (lower = closer) using map coordinates
function QEngine.GetQuestProximityScore(quest, ctx)
    -- If we can get quest waypoints, compute distance
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetNextWaypointForMap) == "function"
        and ctx.mapID and ctx.playerX and ctx.playerY then
        local okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.mapID)
        if okWP and type(wpX) == "number" and type(wpY) == "number" then
            local dx = wpX - ctx.playerX
            local dy = wpY - ctx.playerY
            return math.sqrt(dx * dx + dy * dy)
        end
    end
    -- Fallback: if quest is in current zone it's "close", otherwise far
    if QEngine.IsQuestInCurrentZone(quest, ctx) then
        return 0.5
    end
    return 100
end

-- Detect quests targeting the same NPC/keyword (Synergy Engine)
function QEngine.FindSynergyGroups(quests)
    -- Extract target keywords from objective text
    local keywordMap = {}  -- keyword -> { questIndices }
    for idx, quest in ipairs(quests) do
        if type(quest.objectives) == "table" then
            for _, obj in ipairs(quest.objectives) do
                if type(obj) == "table" and type(obj.text) == "string" then
                    -- Extract "Kill X" or "Slay X" target names
                    local target = obj.text:match("[Kk]ill%s+%d*%s*(.+)")
                        or obj.text:match("[Ss]lay%s+%d*%s*(.+)")
                        or obj.text:match("[Dd]efeat%s+%d*%s*(.+)")
                    if target then
                        target = target:gsub("%s*%d+/%d+%s*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
                        if target ~= "" then
                            local key = target:lower()
                            if not keywordMap[key] then
                                keywordMap[key] = { keyword = target, questIndices = {} }
                            end
                            local indices = keywordMap[key].questIndices
                            -- Avoid duplicates
                            local found = false
                            for _, existing in ipairs(indices) do
                                if existing == idx then found = true; break end
                            end
                            if not found then
                                indices[#indices + 1] = idx
                            end
                        end
                    end
                end
            end
        end
    end

    -- Only keep groups with 2+ quests
    local groups = {}
    for _, data in pairs(keywordMap) do
        if #data.questIndices >= 2 then
            groups[#groups + 1] = data
        end
    end
    return groups
end

-- Check if party members share this quest (Co-Op Sync)
function QEngine.IsQuestSharedWithParty(quest, ctx)
    if not ctx.isInGroup then return false end
    -- Check if any party member is on the same quest
    if type(C_QuestLog) == "table" and type(C_QuestLog.IsUnitOnQuest) == "function" then
        for i = 1, ctx.groupSize - 1 do
            local unit = (IsInRaid() and ("raid" .. i)) or ("party" .. i)
            if UnitExists(unit) then
                local okOnQ, onQuest = pcall(C_QuestLog.IsUnitOnQuest, unit, quest.questID)
                if okOnQ and onQuest then return true end
            end
        end
    end
    return false
end

-- ============================================================================
-- METADATA FILTER 1: Campaign vs. Side-Quest Detection
-- Uses C_CampaignInfo.GetCampaignID(questID) â€" returns campaignID or nil/0.
-- Campaign quests get pinned above side-quests in the NEXT bucket.
-- ============================================================================
function QEngine.IsCampaignQuest(questID)
    if type(questID) ~= "number" then return false end
    -- Primary: C_CampaignInfo.GetCampaignID (TWW+)
    if type(C_CampaignInfo) == "table" and type(C_CampaignInfo.GetCampaignID) == "function" then
        local okCamp, campID = pcall(C_CampaignInfo.GetCampaignID, questID)
        if okCamp and type(campID) == "number" and campID > 0 then
            return true
        end
    end
    -- Fallback: check quest tag for "Story" classification (tagID 270 = Story in TWW)
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestTagInfo) == "function" then
        local okTag, tag = pcall(C_QuestLog.GetQuestTagInfo, questID)
        if okTag and type(tag) == "table" and type(tag.tagID) == "number" then
            -- 270 = Important/Story, 271 = Legendary
            if tag.tagID == 270 or tag.tagID == 271 then
                return true
            end
        end
    end
    return false
end

-- ============================================================================
-- METADATA FILTER 2: Reward iLvl Scanning
-- Compares quest reward item levels against the player's equipped average.
-- Returns (isUpgrade, maxRewardIlvl) where isUpgrade is true if any
-- reward item exceeds the player's current equipped ilvl for that slot.
-- ============================================================================
function QEngine.GetPlayerEquippedIlvl()
    if type(GetAverageItemLevel) == "function" then
        local okIlvl, avgEquipped = pcall(GetAverageItemLevel)
        if okIlvl and type(avgEquipped) == "number" and avgEquipped > 0 then
            return avgEquipped
        end
    end
    return 0
end

function QEngine.ScanQuestRewardUpgrade(questID, questLogIndex, equippedIlvl)
    if type(equippedIlvl) ~= "number" or equippedIlvl <= 0 then return false, 0 end

    if not QEngine._metaCache[questID] then QEngine._metaCache[questID] = {} end
    local cache = QEngine._metaCache[questID]
    if cache.upgradeScan and cache.equippedIlvl == equippedIlvl then
        return cache.isUpgrade, cache.maxRewardIlvl
    end

    local maxRewardIlvl = 0
    local isUpgrade = false

    local numRewards = 0
    if type(GetNumQuestLogRewards) == "function" then
        local okNum, n = pcall(GetNumQuestLogRewards, questID)
        if okNum and type(n) == "number" then numRewards = n end
    end

    for i = 1, numRewards do
        if type(GetQuestLogRewardInfo) == "function" then
            local okR, name, _, _, quality, _, itemID = pcall(GetQuestLogRewardInfo, i, questID)
            if okR and type(itemID) == "number" and itemID > 0 then
                if type(C_Item) == "table" and type(C_Item.GetDetailedItemLevelInfo) == "function" then
                    local okLvl, effectiveIlvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
                    if okLvl and type(effectiveIlvl) == "number" and effectiveIlvl > 0 then
                        if effectiveIlvl > maxRewardIlvl then maxRewardIlvl = effectiveIlvl end
                        if effectiveIlvl > equippedIlvl then isUpgrade = true end
                    end
                end
            end
        end
    end

    local numChoices = 0
    if type(GetNumQuestLogChoices) == "function" then
        local okC, c = pcall(GetNumQuestLogChoices, questID)
        if okC and type(c) == "number" then numChoices = c end
    end

    for i = 1, numChoices do
        if type(GetQuestLogChoiceInfo) == "function" then
            local okC, name, _, _, quality, _, itemID = pcall(GetQuestLogChoiceInfo, i, questID)
            if okC and type(itemID) == "number" and itemID > 0 then
                if type(C_Item) == "table" and type(C_Item.GetDetailedItemLevelInfo) == "function" then
                    local okLvl, effectiveIlvl = pcall(C_Item.GetDetailedItemLevelInfo, itemID)
                    if okLvl and type(effectiveIlvl) == "number" and effectiveIlvl > 0 then
                        if effectiveIlvl > maxRewardIlvl then maxRewardIlvl = effectiveIlvl end
                        if effectiveIlvl > equippedIlvl then isUpgrade = true end
                    end
                end
            end
        end
    end

    cache.upgradeScan = true
    cache.equippedIlvl = equippedIlvl
    cache.isUpgrade = isUpgrade
    cache.maxRewardIlvl = maxRewardIlvl
    return isUpgrade, maxRewardIlvl
end

-- ============================================================================
-- METADATA FILTER 3: Time-Sensitive Priority Detection
-- Checks quest tag for time-limited flags (World Quests, Bonus Objectives,
-- Calling/Emissary quests, Threat quests) and quest expiration timers.
-- Returns a priority multiplier: 1.0 = normal, >1.0 = time-sensitive.
-- ============================================================================
local TIME_SENSITIVE_TAG_IDS = {
    [109] = true,   -- World Quest
    [111] = true,   -- World Quest (Epic)
    [112] = true,   -- World Quest (PvP)
    [113] = true,   -- World Quest (Petbattle)
    [136] = true,   -- World Quest (Dungeon)
    [137] = true,   -- World Quest (Invasion)
    [141] = true,   -- World Quest (Profession)
    [151] = true,   -- Threat Quest (BfA)
    [259] = true,   -- Threat (Shadowlands)
    [266] = true,   -- Bonus Objective (Dragonflight)
    [282] = true,   -- World Quest (TWW-era)
}

function QEngine.GetTimeSensitivePriority(quest)
    local multiplier = 1.0
    local tag = quest.questTagInfo

    -- Check for known time-limited tag IDs
    if type(tag) == "table" and type(tag.tagID) == "number" then
        if TIME_SENSITIVE_TAG_IDS[tag.tagID] then
            multiplier = 2.0
        end
    end

    -- Check daily/weekly frequency (mild boost)
    if type(quest.frequency) == "number" then
        local daily = _G.LE_QUEST_FREQUENCY_DAILY
        local weekly = _G.LE_QUEST_FREQUENCY_WEEKLY
        if quest.frequency == daily then
            multiplier = math.max(multiplier, 1.5)
        elseif quest.frequency == weekly then
            multiplier = math.max(multiplier, 1.3)
        end
    end

    -- Check for quest expiration timer via C_TaskQuest (bonus/world quests)
    if type(C_TaskQuest) == "table" and type(C_TaskQuest.GetQuestTimeLeftSeconds) == "function" then
        local okTime, timeLeft = pcall(C_TaskQuest.GetQuestTimeLeftSeconds, quest.questID)
        if okTime and type(timeLeft) == "number" and timeLeft > 0 then
            quest._expiresInSeconds = timeLeft
            -- Expiring within 2 hours = urgent
            if timeLeft <= 7200 then
                multiplier = math.max(multiplier, 3.0)
                quest._isExpiringSoon = true
            -- Expiring within 8 hours = elevated
            elseif timeLeft <= 28800 then
                multiplier = math.max(multiplier, 2.0)
            end
        end
    end

    -- Check QuestLog timer (timed quests with embedded countdown)
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetTimeAllowed) == "function" then
        local okTA, totalTime, elapsedTime = pcall(C_QuestLog.GetTimeAllowed, quest.questID)
        if okTA and type(totalTime) == "number" and totalTime > 0
            and type(elapsedTime) == "number" then
            local remaining = totalTime - elapsedTime
            if remaining > 0 then
                quest._expiresInSeconds = quest._expiresInSeconds
                    and math.min(quest._expiresInSeconds, remaining) or remaining
                if remaining <= 600 then  -- <10 min
                    multiplier = math.max(multiplier, 4.0)
                    quest._isExpiringSoon = true
                elseif remaining <= 3600 then  -- <1 hr
                    multiplier = math.max(multiplier, 2.5)
                    quest._isExpiringSoon = true
                end
            end
        end
    end

    return multiplier
end

-- ============================================================================
-- METADATA FILTER 4: Flight Path Cluster Detection (NEXT Bucket)
-- Groups quests near discovered, connected taxi nodes so the player has a
-- logical travel route. Quests sharing a nearest flight node cluster together.
-- ============================================================================
function QEngine.GetNearestFlightNodeForQuest(quest, ctx)
    if not ctx.mapID or not ctx.continentID then return nil end
    if type(C_TaxiMap) ~= "table" or type(C_TaxiMap.GetAllTaxiNodes) ~= "function" then
        return nil
    end

    if not QEngine._metaCache[quest.questID] then QEngine._metaCache[quest.questID] = {} end
    if QEngine._metaCache[quest.questID].flightNodeScanned then
        return QEngine._metaCache[quest.questID].flightNode
    end

    local questX, questY = nil, nil
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetNextWaypointForMap) == "function" then
        local okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.continentID)
        if okWP and type(wpX) == "number" and type(wpY) == "number" then
            questX, questY = wpX, wpY
        end
        if not questX then
            okWP, wpX, wpY = pcall(C_QuestLog.GetNextWaypointForMap, quest.questID, ctx.mapID)
            if okWP and type(wpX) == "number" and type(wpY) == "number" then
                questX, questY = wpX, wpY
            end
        end
    end

    if not questX or not questY then return nil end

    local okNodes, nodes = pcall(C_TaxiMap.GetAllTaxiNodes, ctx.continentID)
    if not okNodes or type(nodes) ~= "table" then return nil end

    local bestNode = nil
    local bestDist = math.huge

    for _, node in ipairs(nodes) do
        if type(node) == "table" and node.position
            and (node.state == Enum.FlightPathState.Reachable or node.state == _G.TAXISTATE_CURRENT or node.state == 2 or node.state == 1) then
            local nx = node.position.x or 0
            local ny = node.position.y or 0
            local dx = nx - questX
            local dy = ny - questY
            local dist = dx * dx + dy * dy
            if dist < bestDist then
                bestDist = dist
                bestNode = {
                    nodeID = node.nodeID,
                    name = node.name or "Flight Point",
                    distance = math.sqrt(dist),
                }
            end
        end
    end

    QEngine._metaCache[quest.questID].flightNodeScanned = true
    QEngine._metaCache[quest.questID].flightNode = bestNode
    return bestNode
end

-- Master bucketing function: sorts all quests into now/next/later
function QEngine.CollectQuestListData(searchFilter)
    local data = {
        campaign = nil,
        headers = {},  -- Legacy compat (kept for campaign fallback)
        zoneName = "",
        zoneQuestCount = 0,
        buckets = { now = {}, next = {}, later = {} },
        synergyGroups = {},
        totalQuestCount = 0,
        maxQuests = 35,
    }

    -- Campaign progress (unchanged)
    if type(C_CampaignInfo) == "table" then
        local getCurrent = C_CampaignInfo.GetCurrentCampaignID
        if type(getCurrent) == "function" then
            local okCid, campaignID = pcall(getCurrent)
            if okCid and type(campaignID) == "number" and campaignID > 0 then
                local okInfo, info = pcall(C_CampaignInfo.GetCampaignInfo, campaignID)
                if okInfo and type(info) == "table" and info.name then
                    local completed = 0
                    local total = 0
                    local currentChapter = nil
                    if type(C_CampaignInfo.GetCampaignChapterInfo) == "function" then
                        local okCh, chapters = pcall(C_CampaignInfo.GetCampaignChapterInfo, campaignID)
                        if okCh and type(chapters) == "table" then
                            total = #chapters
                            for _, ch in ipairs(chapters) do
                                if ch.completed then
                                    completed = completed + 1
                                elseif not currentChapter and ch.name then
                                    currentChapter = ch.name
                                end
                            end
                        end
                    end
                    local campaignTotal = total
                    if campaignTotal < 1 then campaignTotal = 1 end
                    local campaignProgress = completed
                    if campaignProgress < 0 then campaignProgress = 0
                    elseif campaignProgress > campaignTotal then campaignProgress = campaignTotal end
                    data.campaign = {
                        name = info.name,
                        progress = campaignProgress,
                        total = campaignTotal,
                        chapterName = currentChapter,
                    }
                end
            end
        end
    end

    -- Gather raw entries
    local rawEntries = QEngine.CollectRawQuestEntries(searchFilter)
    local ctx = QEngine.GetPlayerQuestContext()
    data.zoneName = ctx.zoneName
    data.maxQuests = ctx.maxQuests
    data.totalQuestCount = #rawEntries

    -- Build legacy headers for campaign fallback
    local headerMap = {}
    for _, entry in ipairs(rawEntries) do
        local ht = entry.headerTitle or "Quests"
        if not headerMap[ht] then
            headerMap[ht] = { title = ht, quests = {} }
            data.headers[#data.headers + 1] = headerMap[ht]
        end
        headerMap[ht].quests[#headerMap[ht].quests + 1] = entry
    end

    -- Smart bucketing pass
    local nowQuests = {}
    local nextQuests = {}
    local laterQuests = {}
    local zoneQuestCount = 0

    for _, quest in ipairs(rawEntries) do
        local _, _, pct = QEngine.ResolveQuestObjectiveProgress(quest)
        quest._progressPct = pct or 0
        quest._isInCurrentZone = QEngine.IsQuestInCurrentZone(quest, ctx)
        quest._isGroupElite = QEngine.IsGroupOrEliteQuest(quest)
        quest._isSharedParty = QEngine.IsQuestSharedWithParty(quest, ctx)
        quest._proximityScore = QEngine.GetQuestProximityScore(quest, ctx)
        quest._difficultyColor = QEngine.GetQuestDifficultyColorMuted(quest.level, ctx.playerLevel)

        -- METADATA FILTER: Campaign detection
        quest._isCampaignQuest = QEngine.IsCampaignQuest(quest.questID)

        -- METADATA FILTER: Reward ilvl upgrade scanning
        quest._isUpgrade = false
        quest._rewardIlvl = 0
        if ctx.equippedIlvl > 0 then
            local isUp, maxIlvl = QEngine.ScanQuestRewardUpgrade(quest.questID, quest.questLogIndex, ctx.equippedIlvl)
            quest._isUpgrade = isUp
            quest._rewardIlvl = maxIlvl
        end

        -- METADATA FILTER: Time-sensitive priority multiplier
        quest._timePriority = QEngine.GetTimeSensitivePriority(quest)

        -- METADATA FILTER: Flight path cluster (computed for non-current-zone quests)
        quest._nearestFlightNode = nil
        if not quest._isInCurrentZone then
            quest._nearestFlightNode = QEngine.GetNearestFlightNodeForQuest(quest, ctx)
        end

        if quest._isInCurrentZone then
            zoneQuestCount = zoneQuestCount + 1
        end

        local bucket = nil

        -- LATER bucket checks (demote first)
        local outleveled, outlevelReason = QEngine.IsQuestOutleveled(quest, ctx.playerLevel)
        if outleveled then
            quest._laterReason = outlevelReason == "trivial" and "Outleveled (Trivial)" or "Outleveled (Too Hard)"
            bucket = "later"
        elseif quest._isGroupElite and not ctx.isInGroup then
            quest._laterReason = "Elite/Group (Solo)"
            bucket = "later"
        end

        -- NOW bucket: instance override
        if not bucket and ctx.isInInstance then
            -- Inside an instance: only quests for this instance go to NOW
            if quest._isInCurrentZone then
                bucket = "now"
            else
                bucket = "later"
                quest._laterReason = "Outside Instance"
            end
        end

        -- NOW bucket: completed quests ready for turn-in
        if not bucket and quest.isComplete then
            bucket = "now"
            quest._nowReason = "Ready for Turn-in"
        end

        -- NOW bucket: "One Kill Away" (>80% complete)
        if not bucket and quest._progressPct >= NEARLY_COMPLETE_THRESHOLD and quest._isInCurrentZone then
            bucket = "now"
            quest._nowReason = "Almost Done"
            quest._isNearlyComplete = true
        end

        -- NOW bucket: active in current zone
        if not bucket and quest._isInCurrentZone then
            bucket = "now"
        end

        -- NEXT bucket: everything else on this continent or nearby
        if not bucket then
            -- Completed quests not in current zone go to NEXT (turn-in elsewhere)
            if quest.isComplete then
                bucket = "next"
                quest._nextReason = "Turn-in Elsewhere"
            else
                bucket = "next"
            end
        end

        -- Co-Op bump: shared quests get priority boost within their bucket
        if quest._isSharedParty then
            quest._coopBump = true
        end

        if bucket == "now" then
            nowQuests[#nowQuests + 1] = quest
        elseif bucket == "next" then
            nextQuests[#nextQuests + 1] = quest
        else
            laterQuests[#laterQuests + 1] = quest
        end
    end

    -- Sort NOW bucket: time-sensitive â†' upgrades â†' nearly-complete â†' completed â†' co-op â†' campaign â†' progress
    table.sort(nowQuests, function(a, b)
        -- Time-sensitive global override (invisible multiplier-based priority)
        local aTP = a._timePriority or 1
        local bTP = b._timePriority or 1
        if aTP ~= bTP then return aTP > bTP end
        -- Upgrade rewards pin to top of their tier
        if a._isUpgrade and not b._isUpgrade then return true end
        if not a._isUpgrade and b._isUpgrade then return false end
        -- Nearly complete pins to top
        if a._isNearlyComplete and not b._isNearlyComplete then return true end
        if not a._isNearlyComplete and b._isNearlyComplete then return false end
        -- Completed next
        if a.isComplete and not b.isComplete then return true end
        if not a.isComplete and b.isComplete then return false end
        -- Co-op bump
        if a._coopBump and not b._coopBump then return true end
        if not a._coopBump and b._coopBump then return false end
        -- Campaign quests above side-quests
        if a._isCampaignQuest and not b._isCampaignQuest then return true end
        if not a._isCampaignQuest and b._isCampaignQuest then return false end
        -- Higher progress first
        return (a._progressPct or 0) > (b._progressPct or 0)
    end)

    -- Sort NEXT bucket: time-sensitive â†' upgrades â†' completed â†' co-op â†' campaign â†' flight cluster â†' proximity
    -- Group quests by nearest flight node for logical travel routing
    table.sort(nextQuests, function(a, b)
        -- Time-sensitive global override
        local aTP = a._timePriority or 1
        local bTP = b._timePriority or 1
        if aTP ~= bTP then return aTP > bTP end
        -- Upgrade rewards pin to top of their tier
        if a._isUpgrade and not b._isUpgrade then return true end
        if not a._isUpgrade and b._isUpgrade then return false end
        -- Completed (turn-in) first
        if a.isComplete and not b.isComplete then return true end
        if not a.isComplete and b.isComplete then return false end
        -- Co-op bump
        if a._coopBump and not b._coopBump then return true end
        if not a._coopBump and b._coopBump then return false end
        -- Campaign quests above side-quests in same zone
        if a._isCampaignQuest and not b._isCampaignQuest then return true end
        if not a._isCampaignQuest and b._isCampaignQuest then return false end
        -- Flight path cluster grouping: quests near the same flight node sort together
        local aNode = a._nearestFlightNode and a._nearestFlightNode.nodeID or 0
        local bNode = b._nearestFlightNode and b._nearestFlightNode.nodeID or 0
        if aNode ~= bNode then
            -- Sort by node ID to cluster, but prefer closer nodes first
            local aDist = a._nearestFlightNode and a._nearestFlightNode.distance or 999
            local bDist = b._nearestFlightNode and b._nearestFlightNode.distance or 999
            if math.abs(aDist - bDist) > 0.01 then return aDist < bDist end
            return aNode < bNode
        end
        -- Within same flight cluster: proximity to player
        return (a._proximityScore or 100) < (b._proximityScore or 100)
    end)

    -- Sort LATER bucket: outleveled last, elite/group next
    table.sort(laterQuests, function(a, b)
        -- Trivial always last
        local aT = (a._laterReason == "Outleveled (Trivial)") and 1 or 0
        local bT = (b._laterReason == "Outleveled (Trivial)") and 1 or 0
        if aT ~= bT then return aT < bT end
        return (a._progressPct or 0) > (b._progressPct or 0)
    end)

    -- Detect synergy groups in NOW bucket
    data.synergyGroups = QEngine.FindSynergyGroups(nowQuests)

    -- Mark synergy quests
    for _, group in ipairs(data.synergyGroups) do
        for _, idx in ipairs(group.questIndices) do
            if nowQuests[idx] then
                nowQuests[idx]._synergyKeyword = group.keyword
            end
        end
    end

    data.buckets.now = nowQuests
    data.buckets.next = nextQuests
    data.buckets.later = laterQuests
    data.zoneQuestCount = zoneQuestCount

    return data
end

function QEngine.ResolveCampaignCardFallback(headers)
    if type(headers) ~= "table" then
        return nil
    end

    local firstHeaderTitle = nil
    local totalQuests = 0
    local completedQuests = 0
    for _, header in ipairs(headers) do
        if type(header) == "table" and type(header.quests) == "table" then
            if not firstHeaderTitle and type(header.title) == "string" and header.title ~= "" then
                firstHeaderTitle = header.title
            end
            for _, quest in ipairs(header.quests) do
                totalQuests = totalQuests + 1
                if type(quest) == "table" and quest.isComplete then
                    completedQuests = completedQuests + 1
                end
            end
        end
    end

    if totalQuests < 1 then
        return nil
    end

    local name = firstHeaderTitle or "Campaign"
    local chapterName = string.format("%d Active Quests", totalQuests)
    return {
        name = name,
        chapterName = chapterName,
        progress = completedQuests,
        total = totalQuests,
    }
end

local QUEST_LIST_REDESIGN_CAMPAIGN_HEIGHT = 62
local QUEST_LIST_REDESIGN_HEADER_HEIGHT = 28
local QUEST_LIST_REDESIGN_QUEST_HEIGHT = 48
local QUEST_LIST_REDESIGN_PADDING = 4
local QUEST_LIST_REDESIGN_ROW_GAP = 1
local QUEST_LIST_REDESIGN_ZONE_HEADER_HEIGHT = 22
local QUEST_LIST_REDESIGN_BUCKET_HEADER_HEIGHT = 42
local QUEST_LIST_REDESIGN_MAX_OBJECTIVE_ROWS = 3
local QUEST_LIST_REDESIGN_OBJECTIVE_HEIGHT = type(C.QUEST_LIST_OBJECTIVE_ROW_HEIGHT) == "number" and C.QUEST_LIST_OBJECTIVE_ROW_HEIGHT or 18
local QUEST_LIST_REDESIGN_OBJECTIVE_MIN_HEIGHT = math.max(20, QUEST_LIST_REDESIGN_OBJECTIVE_HEIGHT + 2)
local QUEST_LIST_REDESIGN_OBJECTIVE_CHECKBOX_SIZE = 8

function QEngine.CreateCampaignProgressWidget(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(QUEST_LIST_REDESIGN_CAMPAIGN_HEIGHT)

    -- Gradient background — subtle glass
    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    if type(bg.SetGradientAlpha) == "function" then
        bg:SetGradientAlpha("VERTICAL", 0.10, 0.08, 0.05, 0.50, 0.06, 0.05, 0.03, 0.30)
    else
        bg:SetVertexColor(0.08, 0.065, 0.04, 0.40)
    end

    local accentR, accentG, accentB = C.GetThemeColor("accent")

    -- Left accent stripe — full height, bold
    local edge = frame:CreateTexture(nil, "ARTWORK")
    edge:SetPoint("TOPLEFT", 6, 0)
    edge:SetPoint("BOTTOMLEFT", 6, 0)
    edge:SetWidth(4)
    edge:SetTexture(C.WHITE8X8)
    edge:SetVertexColor(accentR, accentG, accentB, 0.85)

    -- Bottom progress bar track
    local bottomLine = frame:CreateTexture(nil, "BORDER")
    bottomLine:SetPoint("BOTTOMLEFT", 6, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", -6, 0)
    bottomLine:SetHeight(2)
    bottomLine:SetTexture(C.WHITE8X8)
    bottomLine:SetVertexColor(0.20, 0.17, 0.12, 0.20)
    frame._progressTrack = bottomLine

    -- Bottom progress bar fill
    local progressFill = frame:CreateTexture(nil, "ARTWORK")
    progressFill:SetPoint("BOTTOMLEFT", bottomLine, "BOTTOMLEFT", 0, 0)
    progressFill:SetPoint("TOPLEFT", bottomLine, "TOPLEFT", 0, 0)
    progressFill:SetWidth(1)
    progressFill:SetTexture(C.WHITE8X8)
    progressFill:SetVertexColor(accentR, accentG, accentB, 0.60)
    frame._progressFill = progressFill

    -- Campaign name
    frame.Title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    frame.Title:SetPoint("TOPLEFT", 18, -14)
    frame.Title:SetTextColor(0.94, 0.90, 0.80, 1)

    -- Chapter info
    frame.Chapter = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    frame.Chapter:SetPoint("BOTTOMLEFT", 18, 14)
    frame.Chapter:SetTextColor(0.42, 0.38, 0.28, 0.65)

    -- Progress counter
    frame.ProgressText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    frame.ProgressText:SetPoint("RIGHT", -16, 0)
    frame.ProgressText:SetTextColor(accentR, accentG, accentB, 0.70)

    function frame:SetCampaignData(campaignData)
        if not campaignData then
            self:Hide()
            return
        end
        local total = campaignData.total or 1
        if total < 1 then total = 1 end
        local progress = campaignData.progress or 0
        self.Title:SetText(campaignData.name or "Campaign")
        self.Chapter:SetText(campaignData.chapterName or "Active Chapter")
        self.ProgressText:SetText(string.format("%d / %d", progress, total))
        -- Update bottom progress bar
        if self._progressTrack and self._progressFill then
            local trackWidth = self._progressTrack:GetWidth()
            if type(trackWidth) == "number" and trackWidth > 0 then
                local pct = progress / total
                if pct < 0 then pct = 0 end
                if pct > 1 then pct = 1 end
                self._progressFill:SetWidth(math.max(1, math.floor(trackWidth * pct)))
            end
        end
        self:Show()
    end

    return frame
end

-- ============================================================================
-- Zone Banner Factory â€" "Current Zone: [Name]" with pulse animation
-- ============================================================================
function QEngine.CreateZoneBannerRow(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(36)

    -- Subtle dark background
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(QUEST_LIST_VISUALS.zoneBannerBg.r, QUEST_LIST_VISUALS.zoneBannerBg.g, QUEST_LIST_VISUALS.zoneBannerBg.b, QUEST_LIST_VISUALS.zoneBannerBg.a)

    -- Bottom separator
    local bottomLine = frame:CreateTexture(nil, "BORDER", nil, -1)
    bottomLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 0)
    bottomLine:SetHeight(1)
    bottomLine:SetTexture(C.WHITE8X8)
    bottomLine:SetVertexColor(0.72, 0.62, 0.42, 0.08)

    local zoneLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    zoneLabel:SetPoint("LEFT", 16, 0)
    zoneLabel:SetPoint("RIGHT", -16, 0)
    zoneLabel:SetJustifyH("LEFT")
    zoneLabel:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 0.90)
    frame._zoneLabel = zoneLabel

    -- No pulse animation — keep it calm and professional
    local pulseGroup = frame:CreateAnimationGroup()
    pulseGroup:SetLooping("NONE")
    local pulseAlpha = pulseGroup:CreateAnimation("Alpha")
    pulseAlpha:SetOrder(1)
    pulseAlpha:SetDuration(0.01)
    pulseAlpha:SetFromAlpha(1.0)
    pulseAlpha:SetToAlpha(1.0)
    pulseAlpha:SetSmoothing("NONE")
    frame._pulseGroup = pulseGroup

    function frame:SetZoneData(zoneName, questCount)
        local name = (type(zoneName) == "string" and zoneName ~= "") and zoneName or "Unknown"
        if type(questCount) == "number" and questCount > 0 then
            self._zoneLabel:SetText(name)
            self._zoneLabel:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 0.90)
        else
            self._zoneLabel:SetText(name)
            self._zoneLabel:SetTextColor(QUEST_LIST_VISUALS.textMuted.r, QUEST_LIST_VISUALS.textMuted.g, QUEST_LIST_VISUALS.textMuted.b, 0.70)
        end
        self:SetAlpha(1)
    end

    return frame
end

-- ============================================================================
-- Bucket Section Header Factory â€" Collapsible "NOW" / "NEXT" / "LATER"
-- ============================================================================
function QEngine.CreateBucketHeaderRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QUEST_LIST_REDESIGN_BUCKET_HEADER_HEIGHT)
    btn:RegisterForClicks("LeftButtonUp")

    -- No background
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(0, 0, 0, 0)

    -- Bold left accent bar — full height, 4px wide
    local bottomGlow = btn:CreateTexture(nil, "ARTWORK", nil, -1)
    bottomGlow:SetPoint("TOPLEFT", 6, 0)
    bottomGlow:SetPoint("BOTTOMLEFT", 6, 0)
    bottomGlow:SetWidth(4)
    bottomGlow:SetTexture(C.WHITE8X8)
    btn._bottomGlow = bottomGlow

    -- Extending divider line from count to right edge
    local dividerLine = btn:CreateTexture(nil, "ARTWORK", nil, -2)
    dividerLine:SetPoint("RIGHT", btn, "RIGHT", -8, 0)
    dividerLine:SetHeight(1)
    dividerLine:SetTexture(C.WHITE8X8)
    btn._dividerLine = dividerLine

    -- Count pill background
    local countPill = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    countPill:SetHeight(18)
    countPill:SetTexture(C.WHITE8X8)
    btn._countPill = countPill

    -- Bucket label — LARGE, letter-spaced
    btn.Title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.Title:SetPoint("LEFT", 18, 0)

    -- Quest count inside pill
    btn.Count = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    btn.Count:SetPoint("LEFT", btn.Title, "RIGHT", 10, 0)

    -- Collapse indicator
    btn.CollapseIcon = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.CollapseIcon:SetPoint("RIGHT", -14, 0)

    -- Hover — visible
    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetVertexColor(0.72, 0.62, 0.42, 0.10)

    btn:SetScript("OnClick", function(self)
        local key = self._bucketKey
        if key then
            bucketCollapseState[key] = not bucketCollapseState[key]
            if type(RebuildQuestListLayout) == "function" then
                RebuildQuestListLayout()
            end
        end
    end)

    function btn:SetBucketData(bucketKey, questCount, isCollapsed)
        self._bucketKey = bucketKey
        local color = BUCKET_COLORS[bucketKey] or BUCKET_COLORS.later
        local label = BUCKET_LABELS[bucketKey] or "QUESTS"

        self.Title:SetText(label)
        self.Title:SetTextColor(color.r, color.g, color.b, 0.95)

        -- Left accent bar
        self._bottomGlow:SetVertexColor(color.r, color.g, color.b, 0.90)

        -- Count pill
        self.Count:SetText(tostring(questCount))
        self.Count:SetTextColor(color.r, color.g, color.b, 0.70)
        self._countPill:SetVertexColor(color.r, color.g, color.b, 0.12)
        -- Position pill around count text
        self._countPill:ClearAllPoints()
        self._countPill:SetPoint("LEFT", self.Count, "LEFT", -6, 0)
        self._countPill:SetPoint("RIGHT", self.Count, "RIGHT", 6, 0)

        -- Divider line from pill to right edge
        self._dividerLine:ClearAllPoints()
        self._dividerLine:SetPoint("LEFT", self._countPill, "RIGHT", 6, 0)
        self._dividerLine:SetPoint("RIGHT", self, "RIGHT", -8, 0)
        self._dividerLine:SetHeight(1)
        self._dividerLine:SetVertexColor(color.r, color.g, color.b, 0.08)

        self.CollapseIcon:SetText(isCollapsed and "+" or "-")
        self.CollapseIcon:SetTextColor(color.r, color.g, color.b, 0.40)
    end

    return btn
end

-- ============================================================================
-- Zone Sub-Header Row — lightweight zone label within a bucket
-- ============================================================================
function QEngine.CreateZoneSubHeaderRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QUEST_LIST_REDESIGN_ZONE_HEADER_HEIGHT)
    btn:RegisterForClicks("LeftButtonUp")

    -- No full background
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(0, 0, 0, 0)
    btn._bg = bg

    -- Badge pill background behind zone name
    local badgeBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    badgeBg:SetHeight(18)
    badgeBg:SetTexture(C.WHITE8X8)
    btn._badgeBg = badgeBg

    -- Zone name — small but readable
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 18, 0)
    label:SetJustifyH("LEFT")
    btn._label = label

    -- Thin divider extending from badge to right edge
    local zoneDivider = btn:CreateTexture(nil, "ARTWORK", nil, -2)
    zoneDivider:SetHeight(1)
    zoneDivider:SetTexture(C.WHITE8X8)
    zoneDivider:SetVertexColor(0.42, 0.34, 0.24, 0.10)
    btn._zoneDivider = zoneDivider

    -- Quest count — right side
    local count = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    count:SetPoint("RIGHT", btn, "RIGHT", -28, 0)
    count:SetJustifyH("RIGHT")
    btn._count = count

    -- Collapse icon
    local collapseIcon = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    collapseIcon:SetPoint("RIGHT", -12, 0)
    btn._collapseIcon = collapseIcon

    -- Hover
    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetVertexColor(0.72, 0.62, 0.42, 0.08)

    btn:SetScript("OnClick", function(self)
        local key = self._zoneKey
        if key then
            questListCollapseState[key] = not questListCollapseState[key]
            if type(RebuildQuestListLayout) == "function" then
                RebuildQuestListLayout()
            end
        end
    end)

    function btn:SetZoneHeaderData(zoneName, questCount, isCurrentZone, isCollapsed)
        self._zoneKey = zoneName
        self._label:SetText(zoneName or "Unknown")
        self._count:SetText(tostring(questCount or 0))
        self._collapseIcon:SetText(isCollapsed and "+" or "-")

        -- Position badge pill around zone name
        self._badgeBg:ClearAllPoints()
        self._badgeBg:SetPoint("LEFT", self._label, "LEFT", -6, 0)
        self._badgeBg:SetPoint("RIGHT", self._label, "RIGHT", 6, 0)

        -- Position divider from badge to right edge
        self._zoneDivider:ClearAllPoints()
        self._zoneDivider:SetPoint("LEFT", self._badgeBg, "RIGHT", 6, 0)
        self._zoneDivider:SetPoint("RIGHT", self, "RIGHT", -12, 0)

        if isCurrentZone then
            self._label:SetTextColor(0.94, 0.90, 0.80, 0.90)
            self._badgeBg:SetVertexColor(0.82, 0.68, 0.38, 0.18)
            self._count:SetTextColor(0.82, 0.68, 0.38, 0.60)
            self._collapseIcon:SetTextColor(0.82, 0.68, 0.38, 0.50)
        else
            self._label:SetTextColor(0.74, 0.66, 0.52, 0.80)
            self._badgeBg:SetVertexColor(0.42, 0.34, 0.24, 0.15)
            self._count:SetTextColor(0.52, 0.46, 0.34, 0.50)
            self._collapseIcon:SetTextColor(0.52, 0.46, 0.34, 0.40)
        end
    end

    return btn
end

-- ============================================================================
-- Focus Header Row
-- ============================================================================
function QEngine.CreateFocusHeaderRow(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(32)

    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(QUEST_LIST_VISUALS.headerBg.r, QUEST_LIST_VISUALS.headerBg.g, QUEST_LIST_VISUALS.headerBg.b, QUEST_LIST_VISUALS.headerBg.a)

    local accentBar = frame:CreateTexture(nil, "ARTWORK")
    accentBar:SetPoint("TOPLEFT", 0, 0)
    accentBar:SetPoint("BOTTOMLEFT", 0, 0)
    accentBar:SetWidth(5)
    accentBar:SetTexture(C.WHITE8X8)
    accentBar:SetVertexColor(FOCUS_COLOR.r, FOCUS_COLOR.g, FOCUS_COLOR.b, 1)

    -- Top highlight for glass effect
    local topShine = frame:CreateTexture(nil, "ARTWORK", nil, -1)
    topShine:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    topShine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    topShine:SetHeight(1)
    topShine:SetTexture(C.WHITE8X8)
    topShine:SetVertexColor(1, 0.96, 0.88, 0.06)

    local divider = frame:CreateTexture(nil, "BORDER")
    divider:SetPoint("BOTTOMLEFT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", 0, 0)
    divider:SetHeight(1)
    divider:SetTexture(C.WHITE8X8)
    divider:SetVertexColor(QUEST_LIST_VISUALS.divider.r, QUEST_LIST_VISUALS.divider.g, QUEST_LIST_VISUALS.divider.b, QUEST_LIST_VISUALS.divider.a)

    frame.Title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    frame.Title:SetPoint("LEFT", 14, 0)
    frame.Title:SetTextColor(FOCUS_COLOR.r, FOCUS_COLOR.g, FOCUS_COLOR.b, 1)
    frame.Title:SetText(FOCUS_LABEL)

    frame.Quest = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    frame.Quest:SetPoint("LEFT", frame.Title, "RIGHT", 12, 0)
    frame.Quest:SetPoint("RIGHT", frame, "RIGHT", -12, 0)
    frame.Quest:SetJustifyH("LEFT")
    frame.Quest:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 1)

    function frame:SetFocusData(questData)
        local questTitle = (type(questData) == "table" and type(questData.title) == "string" and questData.title ~= "")
            and questData.title or "Focused quest"
        self.Quest:SetText(Addon.MapSafeQuestTextSnippet(questTitle, 78))
    end

    return frame
end

function QEngine.CreateQuestListHeaderRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QUEST_LIST_REDESIGN_HEADER_HEIGHT)
    btn:RegisterForClicks("LeftButtonUp")

    local line = btn:CreateTexture(nil, "BACKGROUND")
    line:SetPoint("LEFT", 0, 0)
    line:SetPoint("RIGHT", 0, 0)
    line:SetHeight(1)
    line:SetTexture(C.WHITE8X8)
    line:SetVertexColor(QUEST_LIST_VISUALS.divider.r, QUEST_LIST_VISUALS.divider.g, QUEST_LIST_VISUALS.divider.b, 0.50)

    local titleBg = btn:CreateTexture(nil, "ARTWORK")
    titleBg:SetTexture(C.WHITE8X8)
    titleBg:SetVertexColor(QUEST_LIST_VISUALS.headerCutout.r, QUEST_LIST_VISUALS.headerCutout.g, QUEST_LIST_VISUALS.headerCutout.b, QUEST_LIST_VISUALS.headerCutout.a)
    titleBg:SetPoint("LEFT", 13, 0)

    btn.Title = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.Title:SetPoint("LEFT", 18, 0)
    btn.Title:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 1)

    local function UpdateTitleCutout(self)
        titleBg:SetSize(self:GetStringWidth() + 12, 18)
    end

    btn.Count = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.Count:SetPoint("RIGHT", -12, 0)
    btn.Count:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 0.95)

    btn:SetScript("OnClick", function(self)
        if self._headerTitle then
            questListCollapseState[self._headerTitle] = not questListCollapseState[self._headerTitle]
            if type(RebuildQuestListLayout) == "function" then
                RebuildQuestListLayout()
            end
        end
    end)

    function btn:SetHeaderData(headerData)
        local title = (headerData and headerData.title) or "Quests"
        self._headerTitle = title
        self.Title:SetText(string.upper(title))
        UpdateTitleCutout(self.Title)
        self.Count:SetText(headerData and headerData.isCollapsed and "+" or "-")
    end

    return btn
end

-- ============================================================================
-- Synergy "Combo Box" visual â€" groups quests targeting the same NPC
-- ============================================================================
function QEngine.CreateSynergyComboRow(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(26)

    -- Purple left border (wider)
    local edge = frame:CreateTexture(nil, "ARTWORK")
    edge:SetPoint("TOPLEFT", 0, 0)
    edge:SetPoint("BOTTOMLEFT", 0, 0)
    edge:SetWidth(4)
    edge:SetTexture(C.WHITE8X8)
    edge:SetVertexColor(COMBO_PURPLE.r, COMBO_PURPLE.g, COMBO_PURPLE.b, 0.85)

    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(COMBO_PURPLE.r, COMBO_PURPLE.g, COMBO_PURPLE.b, 0.12)

    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetPoint("LEFT", 14, 0)
    label:SetPoint("RIGHT", -10, 0)
    label:SetJustifyH("LEFT")
    label:SetTextColor(COMBO_PURPLE.r, COMBO_PURPLE.g, COMBO_PURPLE.b, 0.90)
    frame._label = label

    function frame:SetSynergyData(keyword, questCount)
        self._label:SetText(string.format("COMBO: %s (%d quests share this target)", keyword, questCount))
    end

    return frame
end

-- ============================================================================
-- Abandon Quick-Action Button (for Later bucket / Log Janitor)
-- ============================================================================
function QEngine.CreateAbandonButtonRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(24)
    btn:RegisterForClicks("LeftButtonUp")

    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(0.55, 0.18, 0.18, 0.20)

    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetVertexColor(0.75, 0.22, 0.22, 0.20)

    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetTextColor(0.85, 0.35, 0.35, 0.90)
    label:SetText("Abandon Quest")
    btn._label = label

    btn:SetScript("OnClick", function(self)
        local questID = self._questID
        if questID and type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function"
            and type(C_QuestLog.SetAbandon) == "function" and type(C_QuestLog.AbandonQuest) == "function" then
            -- Use StaticPopup for confirmation
            pcall(C_QuestLog.SetSelectedQuest, questID)
            pcall(C_QuestLog.SetAbandon, questID)
            if type(StaticPopup_Show) == "function" then
                StaticPopup_Show("ABANDON_QUEST")
            end
        end
    end)

    function btn:SetAbandonData(questID, questTitle)
        self._questID = questID
        self._label:SetText("Abandon: " .. (questTitle or "Quest"))
    end

    return btn
end

function Util.CoerceObjectiveFlag(value)
    local valueType = type(value)
    if valueType == "boolean" then
        return value
    end
    if valueType == "number" then
        return value ~= 0
    end
    if valueType == "string" then
        local lowered = value:lower()
        if lowered == "1" or lowered == "true" or lowered == "yes" then
            return true
        end
        if lowered == "0" or lowered == "false" or lowered == "no" then
            return false
        end
    end
    return nil
end

function Util.NormalizeQuestObjectiveText(text)
    if type(text) ~= "string" then return nil end
    local compact = text:gsub("\r", " "):gsub("\n", " ")
    compact = compact:gsub("%s+", " ")
    compact = compact:gsub("^%s+", ""):gsub("%s+$", "")
    if compact == "" then
        return nil
    end
    return compact
end

function Util.ParseObjectiveFractionFromText(text)
    if type(text) ~= "string" then
        return nil, nil
    end

    local lhs, rhs = text:match("([%d,]+)%s*/%s*([%d,]+)")
    if lhs and rhs then
        local fulfilled = tonumber((lhs:gsub(",", "")))
        local required = tonumber((rhs:gsub(",", "")))
        if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
            return fulfilled, required
        end
    end

    lhs, rhs = text:match("([%d,]+)%s+[oO][fF]%s+([%d,]+)")
    if lhs and rhs then
        local fulfilled = tonumber((lhs:gsub(",", "")))
        local required = tonumber((rhs:gsub(",", "")))
        if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
            return fulfilled, required
        end
    end

    return nil, nil
end

function Util.ResolveSingleObjectiveProgress(objective)
    if type(objective) ~= "table" then
        return nil
    end

    local done = Util.CoerceObjectiveFlag(objective.finished)
    if done == nil then
        done = Util.CoerceObjectiveFlag(objective.isCompleted)
    end
    if done == nil then
        done = Util.CoerceObjectiveFlag(objective.completed)
    end
    if done == nil then
        done = Util.CoerceObjectiveFlag(objective.isFinished)
    end

    local text = Util.NormalizeQuestObjectiveText(objective.text)
    local fulfilled = objective.numFulfilled
    local required = objective.numRequired
    if type(fulfilled) ~= "number" then
        fulfilled = objective.fulfilled
    end
    if type(required) ~= "number" then
        required = objective.required
    end
    if type(required) ~= "number" then
        required = objective.numNeeded
    end

    if type(fulfilled) ~= "number" or type(required) ~= "number" or required <= 0 then
        local parsedFulfilled, parsedRequired = Util.ParseObjectiveFractionFromText(text)
        if type(parsedFulfilled) == "number" and type(parsedRequired) == "number" and parsedRequired > 0 then
            fulfilled = parsedFulfilled
            required = parsedRequired
        else
            fulfilled = nil
            required = nil
        end
    end

    local fraction = nil
    if type(fulfilled) == "number" and type(required) == "number" and required > 0 then
        fraction = fulfilled / required
        if fraction < 0 then
            fraction = 0
        elseif fraction > 1 then
            fraction = 1
        end
        if done == nil then
            done = fulfilled >= required
        end
    elseif done ~= nil then
        fraction = done and 1 or 0
    end

    local normalizedText = text
    if not normalizedText and type(fulfilled) == "number" and type(required) == "number" and required > 0 then
        normalizedText = "Objective"
    end

    -- Force 100% fill when objective is marked complete
    if done == true then
        fraction = 1
    end

    if done == nil and fraction == nil and not normalizedText then
        return nil
    end

    return {
        done = done,
        fraction = fraction,
        text = normalizedText,
        fulfilled = fulfilled,
        required = required,
    }
end

function QEngine.BuildQuestObjectiveDisplayRows(questData)
    local rows = {}
    local objectives = questData and questData.objectives
    if type(objectives) ~= "table" then
        return rows
    end

    for _, objective in ipairs(objectives) do
        local state = Util.ResolveSingleObjectiveProgress(objective)
        if state and state.text then
            local progressText = nil
            if type(state.fulfilled) == "number" and type(state.required) == "number" and state.required > 0 then
                local displayFulfilled = state.fulfilled
                if displayFulfilled < 0 then
                    displayFulfilled = 0
                elseif displayFulfilled > state.required then
                    displayFulfilled = state.required
                end
                local hasInlineProgress = Util.ParseObjectiveFractionFromText(state.text)
                if hasInlineProgress == nil then
                    progressText = string.format("%d/%d", displayFulfilled, state.required)
                end
            end
            rows[#rows + 1] = {
                text = state.text,
                finished = (state.done == true),
                progressText = progressText,
            }
        end
    end

    return rows
end

function QEngine.ResolveQuestObjectiveProgress(questData)
    -- Short-circuit: quest flagged complete â†' 100%
    if questData and questData.isComplete then
        return 1, 1, 1.0
    end

    local objectives = questData and questData.objectives
    if type(objectives) ~= "table" or #objectives == 0 then
        return 0, 1, 0.0
    end

    local completed = 0
    local total = 0
    local summedFraction = 0.0

    for _, objective in ipairs(objectives) do
        local state = Util.ResolveSingleObjectiveProgress(objective)
        if state then
            total = total + 1
            local f = 0.0
            if state.done == true then
                completed = completed + 1
                f = 1.0
            elseif type(state.fraction) == "number" then
                f = state.fraction
                if f < 0 then f = 0 end
                if f > 1 then f = 1 end
            end
            summedFraction = summedFraction + f
        end
    end

    if total < 1 then
        return 0, 1, 0.0
    end

    local progressPct = summedFraction / total
    if progressPct < 0 then progressPct = 0.0 end
    if progressPct > 1 then progressPct = 1.0 end

    return completed, total, progressPct
end

function QEngine.CreateQuestListQuestRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QUEST_LIST_REDESIGN_QUEST_HEIGHT)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- NO card background — transparent, floating on panel
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(0, 0, 0, 0)
    btn._muiBg = bg

    -- NO bottom divider — spacing creates separation
    local divider = btn:CreateTexture(nil, "BORDER", nil, -1)
    divider:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", 0, 0)
    divider:SetHeight(1)
    divider:SetTexture(C.WHITE8X8)
    divider:SetVertexColor(0, 0, 0, 0)
    btn._muiDivider = divider

    -- Left status edge — full height, 2px, the KEY visual element
    local statusEdge = btn:CreateTexture(nil, "ARTWORK")
    statusEdge:SetPoint("TOPLEFT", 6, 0)
    statusEdge:SetPoint("BOTTOMLEFT", 6, 0)
    statusEdge:SetWidth(2)
    statusEdge:SetTexture(C.WHITE8X8)
    btn.StatusEdge = statusEdge

    -- Progress track — thin 2px bar at bottom
    local progressTrack = btn:CreateTexture(nil, "ARTWORK", nil, -1)
    progressTrack:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 18, 1)
    progressTrack:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -12, 1)
    progressTrack:SetHeight(2)
    progressTrack:SetTexture(C.WHITE8X8)
    progressTrack:SetVertexColor(QUEST_LIST_VISUALS.progressTrackBg.r, QUEST_LIST_VISUALS.progressTrackBg.g, QUEST_LIST_VISUALS.progressTrackBg.b, QUEST_LIST_VISUALS.progressTrackBg.a)
    btn.ProgressTrack = progressTrack

    local progressFill = btn:CreateTexture(nil, "ARTWORK")
    progressFill:SetPoint("TOPLEFT", progressTrack, "TOPLEFT", 0, 0)
    progressFill:SetPoint("BOTTOMLEFT", progressTrack, "BOTTOMLEFT", 0, 0)
    progressFill:SetTexture(C.WHITE8X8)
    progressFill:SetWidth(0)
    progressFill:Hide()
    btn.ProgressFill = progressFill

    -- Combo synergy edge
    local comboEdge = btn:CreateTexture(nil, "ARTWORK", nil, 2)
    comboEdge:SetPoint("TOPLEFT", 6, 0)
    comboEdge:SetPoint("BOTTOMLEFT", 6, 0)
    comboEdge:SetWidth(2)
    comboEdge:SetTexture(C.WHITE8X8)
    comboEdge:SetVertexColor(COMBO_PURPLE.r, COMBO_PURPLE.g, COMBO_PURPLE.b, 0.70)
    comboEdge:Hide()
    btn._comboEdge = comboEdge

    -- No combo glow background
    local comboGlow = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    comboGlow:SetAllPoints()
    comboGlow:SetTexture(C.WHITE8X8)
    comboGlow:SetVertexColor(0, 0, 0, 0)
    comboGlow:Hide()
    btn._comboGlow = comboGlow

    -- No nearly-complete background tint
    local nearlyCompleteBg = btn:CreateTexture(nil, "BACKGROUND", nil, -1)
    nearlyCompleteBg:SetAllPoints()
    nearlyCompleteBg:SetTexture(C.WHITE8X8)
    nearlyCompleteBg:SetVertexColor(0, 0, 0, 0)
    nearlyCompleteBg:Hide()
    btn._nearlyCompleteBg = nearlyCompleteBg

    -- Upgrade indicator edge
    local upgradeEdge = btn:CreateTexture(nil, "ARTWORK", nil, 3)
    upgradeEdge:SetPoint("TOPLEFT", 6, 0)
    upgradeEdge:SetPoint("BOTTOMLEFT", 6, 0)
    upgradeEdge:SetWidth(2)
    upgradeEdge:SetTexture(C.WHITE8X8)
    upgradeEdge:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.70)
    upgradeEdge:Hide()
    btn._upgradeGlow = { upgradeEdge }

    local upgradePulse = btn:CreateAnimationGroup()
    upgradePulse:SetLooping("BOUNCE")
    local upgradeFade = upgradePulse:CreateAnimation("Alpha")
    upgradeFade:SetOrder(1)
    upgradeFade:SetDuration(3.0)
    upgradeFade:SetFromAlpha(0.70)
    upgradeFade:SetToAlpha(0.20)
    upgradeFade:SetSmoothing("IN_OUT")
    btn._upgradePulse = upgradePulse

    -- Hover — visible warm highlight across full row
    local hover = btn:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetTexture(C.WHITE8X8)
    hover:SetVertexColor(0.82, 0.68, 0.38, 0.12)

    -- Quest title
    btn.Title = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    btn.Title:SetPoint("TOPLEFT", 18, -8)
    btn.Title:SetPoint("RIGHT", -56, 0)
    btn.Title:SetJustifyH("LEFT")
    if type(btn.Title.SetWordWrap) == "function" then
        btn.Title:SetWordWrap(false)
    end

    -- Objective summary — smaller font, very muted
    btn.ObjectiveText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    btn.ObjectiveText:SetPoint("TOPLEFT", btn.Title, "BOTTOMLEFT", 0, -3)
    btn.ObjectiveText:SetPoint("RIGHT", btn, "RIGHT", -56, 0)
    btn.ObjectiveText:SetJustifyH("LEFT")
    if type(btn.ObjectiveText.SetWordWrap) == "function" then
        btn.ObjectiveText:SetWordWrap(false)
    end

    -- Progress percentage — right-aligned, muted
    btn.ProgressCount = btn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    btn.ProgressCount:SetPoint("RIGHT", btn, "RIGHT", -14, 0)
    btn.ProgressCount:SetJustifyH("RIGHT")

    -- State label above progress (EXPIRING, UPGRADE)
    btn.StateText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    btn.StateText:SetPoint("BOTTOMRIGHT", btn.ProgressCount, "TOPRIGHT", 0, 2)
    btn.StateText:SetJustifyH("RIGHT")

    -- Badge below progress (DAILY, STORY)
    btn.BadgeText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    btn.BadgeText:SetPoint("TOPRIGHT", btn.ProgressCount, "BOTTOMRIGHT", 0, -2)
    btn.BadgeText:SetJustifyH("RIGHT")
    btn.BadgeText:Hide()

    function btn:UpdateProgressWidth(pct)
        local trackWidth = self.ProgressTrack and self.ProgressTrack:GetWidth() or nil
        if type(trackWidth) ~= "number" or trackWidth <= 0 then
            trackWidth = UI.GetQuestPanelWidth() - 36
        end
        if trackWidth < 6 then trackWidth = 6 end

        local normalizedPct = type(pct) == "number" and pct or 0
        if normalizedPct < 0 then normalizedPct = 0 end
        if normalizedPct > 1 then normalizedPct = 1 end

        if normalizedPct <= 0 then
            self.ProgressFill:SetWidth(1)
            self.ProgressFill:Hide()
            return
        end

        local width
        if normalizedPct >= 1.0 then
            -- Full bar: exact track width, no rounding gap
            width = trackWidth
        else
            width = math.floor((trackWidth * normalizedPct) + 0.5)
            if width < 4 then width = 4 end
            if width >= trackWidth then width = trackWidth - 1 end
        end

        self.ProgressFill:SetWidth(width)
        self.ProgressFill:Show()
    end

    btn:SetScript("OnSizeChanged", function(self)
        self:UpdateProgressWidth(self._objectivePercent)
    end)

    btn:SetScript("OnClick", function(self, mouseButton)
        local questID = self._questID
        if mouseButton == "RightButton" then
            UI.OpenQuestRowContextMenu(self, questID, self._questTitle)
            return
        end
        if questID and type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end
        local map = _G.WorldMapFrame
        local panel = map and map._muiQuestLogPanel or nil
        if panel and questID then
            UI.ShowQuestDetailsInQuestPanel(panel, questID, "questRowClick", self._questTitle)
        end
    end)

    function btn:SetQuestData(data)
        if not data then return end

        self._questID = data.questID
        self._questTitle = data.title

        local diffColor = data._difficultyColor or DIFFICULTY_COLORS.standard
        local levelPrefix = (type(data.level) == "number" and data.level > 0) and ("[" .. data.level .. "] ") or ""
        self.Title:SetText(levelPrefix .. (data.title or ""))
        self.Title:SetTextColor(diffColor.r, diffColor.g, diffColor.b, 1)

        if data._isSharedParty or data._synergyKeyword then
            self._comboEdge:Show()
            self._comboGlow:Show()
        else
            self._comboEdge:Hide()
            self._comboGlow:Hide()
        end

        if data._isNearlyComplete then
            self._nearlyCompleteBg:Show()
        else
            self._nearlyCompleteBg:Hide()
        end

        if data._isUpgrade then
            for _, tex in ipairs(self._upgradeGlow) do tex:Show() end
            if not self._upgradePulse:IsPlaying() then
                self._upgradePulse:Play()
            end
        else
            for _, tex in ipairs(self._upgradeGlow) do tex:Hide() end
            if self._upgradePulse:IsPlaying() then
                self._upgradePulse:Stop()
            end
        end

        local objectiveRows = QEngine.BuildQuestObjectiveDisplayRows(data)
        local showObjectives = Util.ShouldShowQuestObjectivesInLog()
        local objectiveSummary = nil
        local objectiveRowDone = 0
        local objectiveRowTotal = #objectiveRows
        if showObjectives and #objectiveRows > 0 then
            objectiveSummary = objectiveRows[1].text
            if #objectiveRows > 1 then
                objectiveSummary = string.format("%s (+%d more)", objectiveSummary, #objectiveRows - 1)
            end
            for _, row in ipairs(objectiveRows) do
                if row and row.finished then
                    objectiveRowDone = objectiveRowDone + 1
                end
            end
        else
            objectiveRows = {}
            objectiveRowTotal = 0
            objectiveRowDone = 0
        end

        local done, total, pct = QEngine.ResolveQuestObjectiveProgress(data)

        if type(done) ~= "number" and type(data.objectiveDone) == "number" then done = data.objectiveDone end
        if type(total) ~= "number" and type(data.objectiveTotal) == "number" then total = data.objectiveTotal end
        if type(pct) ~= "number" and type(data.objectivePercent) == "number" then pct = data.objectivePercent end

        if type(done) ~= "number" then done = 0 end
        if type(total) ~= "number" or total < 1 then total = 1 end
        if type(pct) ~= "number" then pct = 0 end
        if pct < 0 then pct = 0 end
        if pct > 1 then pct = 1 end
        if done < 0 then done = 0 end
        if objectiveRowTotal > 0 then
            if done < objectiveRowDone then done = objectiveRowDone end
            if total < objectiveRowTotal then total = objectiveRowTotal end
            local rowPct = objectiveRowDone / objectiveRowTotal
            if pct < rowPct then pct = rowPct end
        end
        if done > total then done = total end
        local objectivesFulfilled = (total > 0 and done >= total)
        if data.isComplete then
            done = total
            pct = 1
        elseif objectivesFulfilled and pct < 1 then
            pct = 1
        end
        if done < total and pct >= 1 then
            local consistentPct = done / total
            if consistentPct < 1 then
                pct = consistentPct
            end
        end
        self._objectivePercent = pct
        self:UpdateProgressWidth(pct)

        if data.isComplete then
            -- Completed: green tint background + bright green accents
            self._muiBg:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.10)
            self.StatusEdge:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.90)
            self.ProgressTrack:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.30)
            self.ProgressFill:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.90)
            self.ObjectiveText:SetText("Ready for turn-in")
            self.ObjectiveText:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.85)
            self.StateText:SetText("")
            self.ProgressCount:SetText("DONE")
            self.ProgressCount:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 1.0)
        elseif objectivesFulfilled then
            self._muiBg:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.07)
            self.StatusEdge:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.80)
            self.ProgressTrack:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.25)
            self.ProgressFill:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.85)
            self.ObjectiveText:SetText("Objectives complete")
            self.ObjectiveText:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.70)
            self.StateText:SetText("")
            self.ProgressCount:SetText("100%")
            self.ProgressCount:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.85)
        else
            -- In progress: subtle warm background, bucket-colored edge
            self._muiBg:SetVertexColor(0.10, 0.08, 0.05, 0.25)
            self.StatusEdge:SetVertexColor(BUCKET_COLORS.next.r, BUCKET_COLORS.next.g, BUCKET_COLORS.next.b, 0.65)
            self.ProgressTrack:SetVertexColor(QUEST_LIST_VISUALS.progressTrackBg.r, QUEST_LIST_VISUALS.progressTrackBg.g, QUEST_LIST_VISUALS.progressTrackBg.b, QUEST_LIST_VISUALS.progressTrackBg.a)
            self.ProgressFill:SetVertexColor(BUCKET_COLORS.next.r, BUCKET_COLORS.next.g, BUCKET_COLORS.next.b, 0.80)
            if objectiveSummary then
                self.ObjectiveText:SetText(objectiveSummary)
            else
                self.ObjectiveText:SetText(string.format("%d / %d objectives", done, total))
            end
            self.ObjectiveText:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 0.80)
            self.StateText:SetText("")
            local pctDisplay = math.floor(pct * 100)
            self.ProgressCount:SetText(pctDisplay .. "%")
            self.ProgressCount:SetTextColor(QUEST_LIST_VISUALS.textMuted.r, QUEST_LIST_VISUALS.textMuted.g, QUEST_LIST_VISUALS.textMuted.b, 0.90)
        end

        if showObjectives then
            if type(self.ObjectiveText.Show) == "function" then
                self.ObjectiveText:Show()
            end
            if type(self.ProgressTrack.Show) == "function" then
                self.ProgressTrack:Show()
            end
            if type(self.ProgressCount.Show) == "function" then
                self.ProgressCount:Show()
            end
        else
            self.ObjectiveText:SetText("")
            if type(self.ObjectiveText.Hide) == "function" then
                self.ObjectiveText:Hide()
            end
            self.ProgressCount:SetText("")
            if type(self.ProgressCount.Hide) == "function" then
                self.ProgressCount:Hide()
            end
            if type(self.ProgressTrack.Hide) == "function" then
                self.ProgressTrack:Hide()
            end
            self.ProgressFill:Hide()
        end

        if data.frequency == _G.LE_QUEST_FREQUENCY_DAILY then
            self.BadgeText:SetText("DAILY")
            self.BadgeText:Show()
        elseif data.frequency == _G.LE_QUEST_FREQUENCY_WEEKLY then
            self.BadgeText:SetText("WEEKLY")
            self.BadgeText:Show()
        else
            self.BadgeText:SetText("")
            self.BadgeText:Hide()
        end

        if self.BadgeText:IsShown() then
            self.BadgeText:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 1)
        end

        if data._laterReason then
            self.BadgeText:SetText(data._laterReason)
            self.BadgeText:SetTextColor(BUCKET_COLORS.later.r, BUCKET_COLORS.later.g, BUCKET_COLORS.later.b, 0.95)
            self.BadgeText:Show()
        end

        if data._isCampaignQuest and not data._laterReason then
            local existing = self.BadgeText:GetText() or ""
            if existing ~= "" then
                self.BadgeText:SetText("STORY  " .. existing)
            else
                self.BadgeText:SetText("STORY")
            end
            self.BadgeText:SetTextColor(QUEST_LIST_VISUALS.story.r, QUEST_LIST_VISUALS.story.g, QUEST_LIST_VISUALS.story.b, 0.95)
            self.BadgeText:Show()
        end

        if data._isExpiringSoon then
            local timeStr = ""
            if type(data._expiresInSeconds) == "number" and data._expiresInSeconds > 0 then
                local mins = math.floor(data._expiresInSeconds / 60)
                if mins >= 60 then
                    timeStr = string.format(" (%dh %dm)", math.floor(mins / 60), mins % 60)
                else
                    timeStr = string.format(" (%dm)", mins)
                end
            end
            self.StateText:SetText("EXPIRING" .. timeStr)
            self.StateText:SetTextColor(QUEST_LIST_VISUALS.warning.r, QUEST_LIST_VISUALS.warning.g, QUEST_LIST_VISUALS.warning.b, 1)
        end

        if data._isUpgrade and type(data._rewardIlvl) == "number" and data._rewardIlvl > 0 then
            local upgradeText = string.format("UPGRADE ilvl %d", data._rewardIlvl)
            if not data._isExpiringSoon then
                self.StateText:SetText(upgradeText)
                self.StateText:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 1)
            end
        end

        if data._nearestFlightNode and type(data._nearestFlightNode.name) == "string" then
            local existing = self.ObjectiveText:GetText() or ""
            if existing ~= "" then
                self.ObjectiveText:SetText(existing .. "  |  " .. data._nearestFlightNode.name)
            end
        end
    end

    return btn
end

function QEngine.CreateQuestListEmptyStateRow(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(64)

    local bg = frame:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    bg:SetVertexColor(QUEST_LIST_VISUALS.headerBg.r, QUEST_LIST_VISUALS.headerBg.g, QUEST_LIST_VISUALS.headerBg.b, 0.60)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", frame, "TOP", 0, -16)
    title:SetTextColor(QUEST_LIST_VISUALS.textPrimary.r, QUEST_LIST_VISUALS.textPrimary.g, QUEST_LIST_VISUALS.textPrimary.b, 1)
    frame._title = title

    local hint = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    hint:SetPoint("TOP", title, "BOTTOM", 0, -5)
    hint:SetPoint("LEFT", frame, "LEFT", 16, 0)
    hint:SetPoint("RIGHT", frame, "RIGHT", -16, 0)
    hint:SetJustifyH("CENTER")
    hint:SetTextColor(QUEST_LIST_VISUALS.textSecondary.r, QUEST_LIST_VISUALS.textSecondary.g, QUEST_LIST_VISUALS.textSecondary.b, 1)
    frame._hint = hint

    function frame:SetState(searchText)
        if type(searchText) == "string" and searchText ~= "" then
            self._title:SetText("No matching quests")
            self._hint:SetText("Change the search text to see more quests.")
        else
            self._title:SetText("Quest log is clear")
            self._hint:SetText("Pick up quests, then reopen the map to see them here.")
        end
    end

    return frame
end

function QEngine.CreateQuestListObjectiveRow(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(QUEST_LIST_REDESIGN_OBJECTIVE_MIN_HEIGHT)

    -- No background
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -2)
    bg:SetAllPoints()
    bg:SetTexture(C.WHITE8X8)
    frame._bg = bg

    -- Status dot — 4x4 indicator, not a checkbox
    local checkbox = CreateFrame("Frame", nil, frame)
    checkbox:SetSize(4, 4)
    checkbox:SetPoint("LEFT", frame, "LEFT", 26, 0)
    frame._checkbox = checkbox

    -- Dot border (the dot itself when incomplete)
    local checkboxBorder = checkbox:CreateTexture(nil, "ARTWORK")
    checkboxBorder:SetAllPoints()
    checkboxBorder:SetTexture(C.WHITE8X8)
    frame._checkboxBorder = checkboxBorder

    -- Dot fill (brighter when complete)
    local checkboxFill = checkbox:CreateTexture(nil, "ARTWORK", nil, 1)
    checkboxFill:SetAllPoints()
    checkboxFill:SetTexture(C.WHITE8X8)
    checkboxFill:Hide()
    frame._checkboxFill = checkboxFill

    -- No text mark needed for a dot
    local checkboxMark = checkbox:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    checkboxMark:SetPoint("CENTER", checkbox, "CENTER", 0, 0)
    checkboxMark:SetText("")
    checkboxMark:Hide()
    frame._checkboxMark = checkboxMark

    -- Objective text — aligned to consistent grid (36px from left)
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("TOPLEFT", frame, "TOPLEFT", 36, -2)
    text:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -60, 2)
    text:SetJustifyH("LEFT")
    text:SetJustifyV("TOP")
    if type(text.SetWordWrap) == "function" then
        text:SetWordWrap(true)
    end
    frame._text = text

    -- Progress count — right aligned
    local progressText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    progressText:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    progressText:SetJustifyH("RIGHT")
    progressText:Hide()
    frame._progressText = progressText

    -- Done tag
    local doneTag = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    doneTag:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    doneTag:SetJustifyH("RIGHT")
    doneTag:SetText("DONE")
    doneTag:Hide()
    frame._doneTag = doneTag

    local function UpdateObjectiveRowHeight(self)
        local labelHeight = self._text and self._text:GetStringHeight() or 0
        local targetHeight = math.max(QUEST_LIST_REDESIGN_OBJECTIVE_MIN_HEIGHT, math.ceil(labelHeight + 6))
        local currentHeight = self:GetHeight() or 0
        if math.abs(currentHeight - targetHeight) > 0.5 then
            self:SetHeight(targetHeight)
        end
    end

    function frame:SetObjectiveData(obj)
        self._objectiveData = obj or {}

        local objective = self._objectiveData
        local isMeta = (objective.isMeta == true)
        local isFinished = (objective.finished == true)
        local label = objective.text or ""
        local objectiveProgress = objective.progressText

        local accentR, accentG, accentB = C.GetThemeColor("accent")
        local accentMidR, accentMidG, accentMidB = C.GetThemeColor("accentMid")
        local panelR, panelG, panelB = C.GetThemeColor("bgPanelRaised")
        local borderR, borderG, borderB = C.GetThemeColor("borderStrong")
        local textSecondaryR, textSecondaryG, textSecondaryB = C.GetThemeColor("textSecondary")
        local textMutedR, textMutedG, textMutedB = C.GetThemeColor("textMuted")
        local textDisabledR, textDisabledG, textDisabledB = C.GetThemeColor("textDisabled")
        local inkR, inkG, inkB = C.GetThemeColor("ink")

        if isMeta then
            -- Meta: no dot, just indented text
            self._bg:SetVertexColor(0, 0, 0, 0)
            self._checkbox:Hide()
            self._checkboxFill:Hide()
            self._checkboxBorder:Hide()
            self._checkboxMark:Hide()
            self._doneTag:Hide()
            self._progressText:Hide()
            self._text:SetTextColor(textMutedR, textMutedG, textMutedB, 0.70)
            self._text:ClearAllPoints()
            self._text:SetPoint("TOPLEFT", self, "TOPLEFT", 36, -2)
            self._text:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -14, 2)
        else
            self._checkbox:Show()
            self._checkboxBorder:Show()
            self._checkboxMark:Hide()
            self._doneTag:Hide()

            if isFinished then
                -- Completed: bright green dot + DONE label
                self._bg:SetVertexColor(0, 0, 0, 0)
                self._checkboxBorder:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.90)
                self._checkboxFill:SetVertexColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.90)
                self._checkboxFill:Show()
                self._text:SetTextColor(0.52, 0.46, 0.34, 0.55)
                self._progressText:Hide()
                self._doneTag:SetTextColor(QUEST_LIST_VISUALS.success.r, QUEST_LIST_VISUALS.success.g, QUEST_LIST_VISUALS.success.b, 0.85)
                self._doneTag:Show()
                self._text:ClearAllPoints()
                self._text:SetPoint("TOPLEFT", self, "TOPLEFT", 36, -2)
                self._text:SetPoint("BOTTOMRIGHT", self._doneTag, "BOTTOMLEFT", -6, 2)
            else
                -- In progress: muted dot
                self._bg:SetVertexColor(0, 0, 0, 0)
                self._checkboxFill:Hide()
                self._checkboxBorder:SetVertexColor(textMutedR, textMutedG, textMutedB, 0.45)
                self._text:SetTextColor(textSecondaryR, textSecondaryG, textSecondaryB, 0.85)
                if type(objectiveProgress) == "string" and objectiveProgress ~= "" then
                    self._progressText:SetText(objectiveProgress)
                    self._progressText:SetTextColor(accentMidR, accentMidG, accentMidB, 0.80)
                    self._progressText:Show()
                    self._text:ClearAllPoints()
                    self._text:SetPoint("TOPLEFT", self, "TOPLEFT", 36, -2)
                    self._text:SetPoint("BOTTOMRIGHT", self._progressText, "BOTTOMLEFT", -6, 2)
                else
                    self._progressText:Hide()
                    self._text:ClearAllPoints()
                    self._text:SetPoint("TOPLEFT", self, "TOPLEFT", 36, -2)
                    self._text:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", -14, 2)
                end
            end
        end

        self._text:SetText(label)
        UpdateObjectiveRowHeight(self)
    end

    frame:SetScript("OnSizeChanged", function(self)
        if self._muiObjectiveResizeGuard then return end
        if not self._objectiveData then return end
        self._muiObjectiveResizeGuard = true
        UpdateObjectiveRowHeight(self)
        self._muiObjectiveResizeGuard = false
    end)

    return frame
end

-- ============================================================================
-- END CUSTOM QUEST LIST SYSTEM (widget factories)
-- ============================================================================

function Addon.MapCollectVisibleQuestScrollRows(scrollChild, maxCount)
    local rows = {}
    if not scrollChild or type(scrollChild.GetChildren) ~= "function" then
        return rows
    end

    local clipParent = Util.SafeMethodRead(scrollChild, "GetParent")
    local clipTop = Util.SafeMethodRead(clipParent, "GetTop")
    local clipBottom = Util.SafeMethodRead(clipParent, "GetBottom")
    local hasClipBounds = type(clipTop) == "number" and type(clipBottom) == "number"

    for _, child in ipairs({ scrollChild:GetChildren() }) do
        if child and child.IsShown and child:IsShown() then
            local top = child.GetTop and child:GetTop() or nil
            local bottom = child.GetBottom and child:GetBottom() or nil
            if type(top) == "number" and type(bottom) == "number" then
                if hasClipBounds then
                    local intersects = (bottom < clipTop) and (top > clipBottom)
                    if not intersects then
                        top = nil
                    end
                end
            end
            if type(top) == "number" and type(bottom) == "number" then
                rows[#rows + 1] = {
                    frame = child,
                    top = top,
                    bottom = bottom,
                    height = child.GetHeight and child:GetHeight() or nil,
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.top == b.top then
            return Util.SafeToString(a.frame) < Util.SafeToString(b.frame)
        end
        return a.top > b.top
    end)

    local limit = type(maxCount) == "number" and maxCount or 8
    if #rows > limit then
        for i = #rows, limit + 1, -1 do
            rows[i] = nil
        end
    end
    return rows
end

function Util.RowTextMatchesCampaignProgress(text)
    if type(text) ~= "string" or text == "" then
        return false
    end
    local trimmed = text:gsub("^%s+", ""):gsub("%s+$", "")
    if trimmed == "" then
        return false
    end

    local lower = string.lower(trimmed)
    local hasCampaign = lower:find("campaign", 1, true) ~= nil
    if not hasCampaign then
        return false
    end

    local hasChapter = lower:find("chapter", 1, true) ~= nil
    local hasFraction = trimmed:match("%d+%s*/%s*%d+") ~= nil
    if not hasChapter and not hasFraction then
        return false
    end
    return true
end

function Util.FrameHasCampaignProgressText(frame, depth)
    if not frame then return false end
    depth = depth or 0
    if depth > 1 then return false end

    if type(frame.GetRegions) == "function" then
        for _, region in ipairs({ frame:GetRegions() }) do
            if region and Util.SafeGetObjectType(region) == "FontString" and type(region.GetText) == "function" then
                local ok, text = pcall(region.GetText, region)
                if ok and Util.RowTextMatchesCampaignProgress(text) then
                    return true
                end
            end
        end
    end

    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            if Util.FrameHasCampaignProgressText(child, depth + 1) then
                return true
            end
        end
    end
    return false
end

function Util.ResolveFrameVisualBottom(frame, depth, visited)
    if not frame then return nil end
    depth = depth or 0
    if depth > 2 then return nil end
    visited = visited or {}
    if visited[frame] then return nil end
    visited[frame] = true

    local visualBottom = nil
    local function AbsorbBottom(value)
        if type(value) ~= "number" then return end
        if not visualBottom or value < visualBottom then
            visualBottom = value
        end
    end

    AbsorbBottom(Util.SafeMethodRead(frame, "GetBottom"))

    if type(frame.GetRegions) == "function" then
        for _, region in ipairs({ frame:GetRegions() }) do
            local shown = (region.IsShown and region:IsShown()) or (region.IsVisible and region:IsVisible())
            if shown then
                AbsorbBottom(Util.SafeMethodRead(region, "GetBottom"))
            end
        end
    end

    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            local shown = (child.IsShown and child:IsShown()) or (child.IsVisible and child:IsVisible())
            if shown then
                local childBottom = Util.ResolveFrameVisualBottom(child, depth + 1, visited)
                AbsorbBottom(childBottom)
            end
        end
    end

    return visualBottom
end

function Util.ResolveFrameVisualTop(frame, depth, visited)
    if not frame then return nil end
    depth = depth or 0
    if depth > 2 then return nil end
    visited = visited or {}
    if visited[frame] then return nil end
    visited[frame] = true

    local visualTop = nil
    local function AbsorbTop(value)
        if type(value) ~= "number" then return end
        if not visualTop or value > visualTop then
            visualTop = value
        end
    end

    AbsorbTop(Util.SafeMethodRead(frame, "GetTop"))

    if type(frame.GetRegions) == "function" then
        for _, region in ipairs({ frame:GetRegions() }) do
            local shown = (region.IsShown and region:IsShown()) or (region.IsVisible and region:IsVisible())
            if shown then
                AbsorbTop(Util.SafeMethodRead(region, "GetTop"))
            end
        end
    end

    if type(frame.GetChildren) == "function" then
        for _, child in ipairs({ frame:GetChildren() }) do
            local shown = (child.IsShown and child:IsShown()) or (child.IsVisible and child:IsVisible())
            if shown then
                local childTop = Util.ResolveFrameVisualTop(child, depth + 1, visited)
                AbsorbTop(childTop)
            end
        end
    end

    return visualTop
end

function Util.CaptureFramePoints(frame)
    if not frame or type(frame.GetNumPoints) ~= "function" or type(frame.GetPoint) ~= "function" then
        return nil
    end
    if Util.IsForbiddenRegion(frame) then
        return nil
    end
    local points = {}
    local pointCount = frame:GetNumPoints() or 0
    for i = 1, pointCount do
        local p, relativeTo, relativePoint, x, y = Util.SafeGetPoint(frame, i)
        if p then
            points[#points + 1] = {
                point = p,
                relativeTo = relativeTo,
                relativePoint = relativePoint,
                x = x,
                y = y,
            }
        end
    end
    if #points == 0 then
        return nil
    end
    return points
end

function Util.RestoreFramePoints(frame, points, yOffset)
    if not frame or type(frame.ClearAllPoints) ~= "function" or type(frame.SetPoint) ~= "function" then
        return
    end
    if type(points) ~= "table" or #points == 0 then return end
    local offset = type(yOffset) == "number" and yOffset or 0

    frame:ClearAllPoints()
    for i = 1, #points do
        local anchor = points[i]
        local x = type(anchor.x) == "number" and anchor.x or 0
        local y = type(anchor.y) == "number" and anchor.y or 0
        frame:SetPoint(anchor.point, anchor.relativeTo, anchor.relativePoint, x, y - offset)
    end
end

function Util.AreFramePointsEquivalent(lhs, rhs, tolerance)
    if type(lhs) ~= "table" or type(rhs) ~= "table" then
        return false
    end
    if #lhs ~= #rhs then
        return false
    end
    local tol = type(tolerance) == "number" and tolerance or 0.5
    for i = 1, #lhs do
        local a = lhs[i]
        local b = rhs[i]
        if type(a) ~= "table" or type(b) ~= "table" then
            return false
        end
        if a.point ~= b.point or a.relativeTo ~= b.relativeTo or a.relativePoint ~= b.relativePoint then
            return false
        end
        local ax = type(a.x) == "number" and a.x or 0
        local ay = type(a.y) == "number" and a.y or 0
        local bx = type(b.x) == "number" and b.x or 0
        local by = type(b.y) == "number" and b.y or 0
        if math.abs(ax - bx) > tol or math.abs(ay - by) > tol then
            return false
        end
    end
    return true
end

function Util.ResolveQuestRowTop(frame)
    local top = Util.SafeMethodRead(frame, "GetTop")
    local visualTop = Util.ResolveFrameVisualTop(frame, 0, nil)
    if type(visualTop) == "number" and (type(top) ~= "number" or visualTop > top) then
        top = visualTop
    end
    return top
end

function Util.ResolveQuestRowBottom(frame)
    local bottom = Util.SafeMethodRead(frame, "GetBottom")
    local visualBottom = Util.ResolveFrameVisualBottom(frame, 0, nil)
    if type(visualBottom) == "number" and (type(bottom) ~= "number" or visualBottom < bottom) then
        bottom = visualBottom
    end
    return bottom
end

function Addon.MapApplyQuestCampaignRowSpacing(questFrame, modeKey)
    if not questFrame then return end
    local questsFrame = questFrame.QuestsFrame
    local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
    local scrollChild = Addon.MapResolveQuestScrollChild(questScrollFrame)
    if not questScrollFrame or not scrollChild then return end

    local priorScrollShift = type(scrollChild._muiCampaignShiftApplied) == "number" and scrollChild._muiCampaignShiftApplied or 0
    local priorScrollBasePoints = scrollChild._muiCampaignBasePoints
    if type(priorScrollBasePoints) == "table" and #priorScrollBasePoints > 0 then
        -- Legacy cleanup: restore any historic full-scroll offset if present.
        Util.RestoreFramePoints(scrollChild, priorScrollBasePoints, 0)
    end
    scrollChild._muiCampaignBasePoints = nil
    scrollChild._muiCampaignShiftApplied = nil

    local adjustedRows = scrollChild._muiCampaignAdjustedRows
    if type(adjustedRows) == "table" then
        for rowFrame in pairs(adjustedRows) do
            if rowFrame and rowFrame._muiCampaignBasePoints then
                -- Deterministic reset: always revert any row we shifted in a previous pass.
                Util.RestoreFramePoints(rowFrame, rowFrame._muiCampaignBasePoints, 0)
            end
            if rowFrame then
                rowFrame._muiCampaignBasePoints = nil
                rowFrame._muiCampaignAdjustedPoints = nil
            end
        end
    end
    scrollChild._muiCampaignAdjustedRows = {}
    questScrollFrame._muiCampaignSpacingOffset = 0
    questScrollFrame._muiCampaignSpacingRows = 0
    questScrollFrame._muiCampaignSpacingCandidate = nil

    if C.QUEST_ROW_STACK_REBUILD_ENABLED == false then return end
    if modeKey ~= "Quests" then return end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then return end

    local rows = Addon.MapCollectVisibleQuestScrollRows(scrollChild, 120)
    if #rows < 2 then return end

    local function IsLikelyObjectiveRow(row)
        if not row or not row.frame then
            return true
        end
        local hintText = Addon.MapBuildQuestFrameTextHint(row.frame)
        if type(hintText) == "string" then
            local trimmed = hintText:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                if trimmed:find("^%-") then
                    return true
                end
                if trimmed:find("^%d+%s*/%s*%d+") then
                    return true
                end
                if trimmed:find("^%d+%%") then
                    return true
                end
            end
        end
        local rowHeight = type(row.height) == "number" and row.height or Util.SafeMethodRead(row.frame, "GetHeight")
        if type(rowHeight) == "number" and rowHeight < 19 then
            return true
        end
        return false
    end

    local function IsCampaignRow(row)
        if not row or not row.frame then return false end
        local hintText = Addon.MapBuildQuestFrameTextHint(row.frame)
        if Util.RowTextMatchesCampaignProgress(hintText) or Util.FrameHasCampaignProgressText(row.frame, 0) then
            if hintText and questScrollFrame then
                questScrollFrame._muiCampaignSpacingCandidate = hintText
            end
            return true
        end
        return false
    end

    local function IsLikelyHeaderRow(row)
        if not row or not row.frame then return false end
        if IsLikelyObjectiveRow(row) then return false end

        local identity = (type(Addon.MapResolveQuestButtonIdentity) == "function")
            and Addon.MapResolveQuestButtonIdentity(row.frame) or nil
        if identity and identity.isHeader ~= nil then
            return identity.isHeader == true
        end
        return true
    end

    local campaignIndex = nil
    local scanRowsLimit = type(C.QUEST_CAMPAIGN_TRACKER_SCAN_ROWS) == "number" and C.QUEST_CAMPAIGN_TRACKER_SCAN_ROWS or 12
    local scanTopDelta = type(C.QUEST_CAMPAIGN_TRACKER_MAX_TOP_DELTA) == "number" and C.QUEST_CAMPAIGN_TRACKER_MAX_TOP_DELTA or 240
    local anchorTop = rows[1] and rows[1].top or nil
    local maxIndex = math.min(#rows, math.max(1, scanRowsLimit))
    for i = 1, maxIndex do
        if type(anchorTop) == "number" and type(rows[i].top) == "number" and (anchorTop - rows[i].top) > scanTopDelta then
            break
        end
        if IsCampaignRow(rows[i]) then
            campaignIndex = i
            break
        end
    end
    if not campaignIndex then return end

    local rowRoleByIndex = {}
    local defaultGap = type(C.QUEST_ROW_STACK_DEFAULT_GAP) == "number" and C.QUEST_ROW_STACK_DEFAULT_GAP or -4
    local headerGap = type(C.QUEST_ROW_STACK_HEADER_GAP) == "number" and C.QUEST_ROW_STACK_HEADER_GAP or -6
    local objectiveGap = type(C.QUEST_ROW_STACK_OBJECTIVE_GAP) == "number" and C.QUEST_ROW_STACK_OBJECTIVE_GAP or -2
    local campaignGap = type(C.QUEST_CAMPAIGN_FIRST_HEADER_GAP) == "number" and C.QUEST_CAMPAIGN_FIRST_HEADER_GAP or -14
    local maxShift = type(C.QUEST_ROW_STACK_MAX_SHIFT) == "number" and C.QUEST_ROW_STACK_MAX_SHIFT or 520

    for i = 1, #rows do
        local row = rows[i]
        if i == campaignIndex then
            rowRoleByIndex[i] = "campaign"
        elseif IsLikelyObjectiveRow(row) then
            rowRoleByIndex[i] = "objective"
        elseif IsLikelyHeaderRow(row) then
            rowRoleByIndex[i] = "header"
        else
            rowRoleByIndex[i] = "quest"
        end
    end

    local rowOffsets = {}
    local adjustedCount = 0
    local totalOffsetApplied = 0

    local function DesiredGap(prevIndex, currIndex)
        local prevRole = rowRoleByIndex[prevIndex]
        local currRole = rowRoleByIndex[currIndex]
        if prevRole == "campaign" and currRole ~= "objective" then
            return campaignGap
        end
        if prevRole == "header" and currRole == "objective" then
            return objectiveGap
        end
        if prevRole == "objective" and currRole == "objective" then
            return objectiveGap
        end
        if prevRole == "header" and (currRole == "header" or currRole == "quest") then
            return headerGap
        end
        return defaultGap
    end

    local function ApplyRowOffset(rowFrame, offsetDelta)
        if not rowFrame or type(offsetDelta) ~= "number" or math.abs(offsetDelta) <= 0.5 then return false end

        local previousOffset = rowOffsets[rowFrame] or 0
        local nextOffset = previousOffset + offsetDelta
        if nextOffset > maxShift then nextOffset = maxShift end
        if nextOffset < -maxShift then nextOffset = -maxShift end
        if math.abs(nextOffset - previousOffset) <= 0.05 then return false end

        local basePoints = rowFrame._muiCampaignBasePoints
        if type(basePoints) ~= "table" or #basePoints == 0 then
            basePoints = Util.CaptureFramePoints(rowFrame)
            if type(basePoints) ~= "table" or #basePoints == 0 then return false end
            rowFrame._muiCampaignBasePoints = basePoints
        end

        rowOffsets[rowFrame] = nextOffset
        Util.RestoreFramePoints(rowFrame, basePoints, nextOffset)
        rowFrame._muiCampaignAdjustedPoints = Util.CaptureFramePoints(rowFrame)

        if not scrollChild._muiCampaignAdjustedRows[rowFrame] then
            scrollChild._muiCampaignAdjustedRows[rowFrame] = true
            adjustedCount = adjustedCount + 1
        end

        totalOffsetApplied = totalOffsetApplied + (nextOffset - previousOffset)
        return true
    end

    for pass = 1, 4 do
        local changed = false
        for i = 2, #rows do
            local prevFrame = rows[i - 1] and rows[i - 1].frame or nil
            local currFrame = rows[i] and rows[i].frame or nil
            if prevFrame and currFrame then
                local prevVisualBottom = Util.ResolveQuestRowBottom(prevFrame)
                local currTop = Util.ResolveQuestRowTop(currFrame)
                if type(prevVisualBottom) == "number" and type(currTop) == "number" then
                    local gap = currTop - prevVisualBottom
                    local desired = DesiredGap(i - 1, i)
                    local delta = gap - desired
                    if math.abs(delta) > 0.25 then
                        if ApplyRowOffset(currFrame, delta) then changed = true end
                    end
                end
            end
        end
        if not changed then break end
    end

    questScrollFrame._muiCampaignSpacingOffset = totalOffsetApplied
    questScrollFrame._muiCampaignSpacingRows = adjustedCount

    if Util.IsQuestStructureProbeEnabled() and Util.ShouldEmitDebugToken("questStructure:campaignStackRebuild", 0.08) then
        Util.MapQuestStructureLog("info", string.format(
            "campaignStackRebuild rows=%d campaignIndex=%s adjustedRows=%d totalOffset=%s candidate=%s priorScrollShift=%s",
            #rows,
            Util.SafeToString(campaignIndex),
            adjustedCount,
            Util.FormatNumber(totalOffsetApplied),
            Util.SafeToString(Addon.MapSafeQuestTextSnippet(questScrollFrame._muiCampaignSpacingCandidate, 64)),
            Util.FormatNumber(priorScrollShift)
        ), true)
    end
end

function Addon.MapBuildQuestFrameTextHint(frame)
    if not frame or type(frame.GetRegions) ~= "function" then return nil end
    for _, region in ipairs({ frame:GetRegions() }) do
        if region and Util.SafeGetObjectType(region) == "FontString" and type(region.GetText) == "function" then
            local ok, text = pcall(region.GetText, region)
            if ok and type(text) == "string" and text ~= "" then
                return text
            end
        end
    end
    return nil
end

function Addon.MapCollectQuestTreeStats(root, maxDepth, maxNodes)
    local stats = {
        nodes = 0,
        shown = 0,
        visible = 0,
        alphaZero = 0,
        frames = 0,
        buttons = 0,
        textures = 0,
        fontStrings = 0,
        textNodes = 0,
        textVisible = 0,
        truncated = false,
        hiddenSamples = {},
        textSamples = {},
    }
    if not root then
        return stats
    end

    local depthLimit = type(maxDepth) == "number" and maxDepth or 5
    local nodeLimit = type(maxNodes) == "number" and maxNodes or 240
    local visited = {}
    local stack = {
        { node = root, depth = 0 },
    }

    local function AddSample(target, sample, maxCount)
        if #target >= maxCount then return end
        target[#target + 1] = sample
    end

    while #stack > 0 and stats.nodes < nodeLimit do
        local entry = table.remove(stack)
        local node = entry and entry.node or nil
        local depth = entry and entry.depth or 0
        if node and not visited[node] then
            visited[node] = true
            stats.nodes = stats.nodes + 1

            local objectType = Util.SafeGetObjectType(node) or "Unknown"
            if objectType == "Texture" then
                stats.textures = stats.textures + 1
            elseif objectType == "FontString" then
                stats.fontStrings = stats.fontStrings + 1
            elseif objectType == "Button" then
                stats.buttons = stats.buttons + 1
            else
                stats.frames = stats.frames + 1
            end

            local shown = (node.IsShown and node:IsShown()) and true or false
            local visible = (node.IsVisible and node:IsVisible()) and true or false
            local alpha = Util.SafeMethodRead(node, "GetAlpha")
            local alphaZero = (type(alpha) == "number" and alpha <= 0.02)
            if shown then stats.shown = stats.shown + 1 end
            if visible then stats.visible = stats.visible + 1 end
            if alphaZero then stats.alphaZero = stats.alphaZero + 1 end

            if not shown or alphaZero then
                AddSample(stats.hiddenSamples, string.format(
                    "%s[%s] shown=%s visible=%s alpha=%s",
                    Util.GetFrameDebugName(node),
                    Util.SafeToString(objectType),
                    shown and "true" or "false",
                    visible and "true" or "false",
                    Util.FormatNumber(alpha)
                ), 6)
            end

            if objectType == "FontString" and type(node.GetText) == "function" then
                local ok, text = pcall(node.GetText, node)
                if ok and type(text) == "string" and text ~= "" then
                    stats.textNodes = stats.textNodes + 1
                    if visible then
                        stats.textVisible = stats.textVisible + 1
                    end
                    AddSample(stats.textSamples, string.format(
                        "%s text=%s visible=%s alpha=%s",
                        Util.GetFrameDebugName(node),
                        Util.SafeToString(Addon.MapSafeQuestTextSnippet(text, 64)),
                        visible and "true" or "false",
                        Util.FormatNumber(alpha)
                    ), 4)
                end
            end

            if depth < depthLimit then
                if type(node.GetChildren) == "function" then
                    for _, child in ipairs({ node:GetChildren() }) do
                        if child and not visited[child] then
                            stack[#stack + 1] = { node = child, depth = depth + 1 }
                        end
                    end
                end
                if type(node.GetRegions) == "function" then
                    for _, region in ipairs({ node:GetRegions() }) do
                        if region and not visited[region] then
                            stack[#stack + 1] = { node = region, depth = depth + 1 }
                        end
                    end
                end
            end
        end
    end

    if #stack > 0 then
        stats.truncated = true
    end
    return stats
end

function Addon.MapBuildQuestTreeStatsLine(label, stats)
    if not stats then
        return Util.SafeToString(label) .. "=nil"
    end
    return string.format(
        "%s nodes=%d shown=%d visible=%d alphaZero=%d frames=%d buttons=%d textures=%d fontStrings=%d textNodes=%d textVisible=%d truncated=%s",
        Util.SafeToString(label),
        stats.nodes or 0,
        stats.shown or 0,
        stats.visible or 0,
        stats.alphaZero or 0,
        stats.frames or 0,
        stats.buttons or 0,
        stats.textures or 0,
        stats.fontStrings or 0,
        stats.textNodes or 0,
        stats.textVisible or 0,
        stats.truncated and "true" or "false"
    )
end

function Util.CollectQuestRowTextDetails(frame)
    local details = {
        header = nil,
        objectiveCount = 0,
        objectiveSampleA = nil,
        objectiveSampleB = nil,
        headerTop = nil,
        headerBottom = nil,
        objectiveTop = nil,
        objectiveBottom = nil,
    }
    if not frame then
        return details
    end

    local seen = {}
    local entries = {}

    local function AddText(node, text)
        if type(text) ~= "string" then return end
        local compact = text:gsub("\r", " "):gsub("\n", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
        if compact == "" or seen[compact] then return end
        seen[compact] = true
        entries[#entries + 1] = {
            text = compact,
            top = Util.SafeMethodRead(node, "GetTop"),
            bottom = Util.SafeMethodRead(node, "GetBottom"),
        }
    end

    local function Walk(node, depth)
        if not node or depth > 2 then return end
        if Util.SafeGetObjectType(node) == "FontString" and type(node.GetText) == "function" then
            local shown = (node.IsShown and node:IsShown()) and true or false
            local visible = (node.IsVisible and node:IsVisible()) and true or false
            if shown or visible then
                local ok, text = pcall(node.GetText, node)
                if ok then
                    AddText(node, text)
                end
            end
            return
        end

        if type(node.GetRegions) == "function" then
            for _, region in ipairs({ node:GetRegions() }) do
                Walk(region, depth + 1)
            end
        end
        if type(node.GetChildren) == "function" then
            for _, child in ipairs({ node:GetChildren() }) do
                Walk(child, depth + 1)
            end
        end
    end

    Walk(frame, 0)
    local headerEntry = entries[1]
    if headerEntry then
        details.header = headerEntry.text
        details.headerTop = headerEntry.top
        details.headerBottom = headerEntry.bottom
    end
    if #entries > 1 then
        details.objectiveCount = #entries - 1
        details.objectiveSampleA = entries[2] and entries[2].text or nil
        details.objectiveSampleB = entries[3] and entries[3].text or nil
        local objectiveTop, objectiveBottom = nil, nil
        for i = 2, #entries do
            local entry = entries[i]
            local top = entry and entry.top or nil
            local bottom = entry and entry.bottom or nil
            if type(top) == "number" and (not objectiveTop or top > objectiveTop) then
                objectiveTop = top
            end
            if type(bottom) == "number" and (not objectiveBottom or bottom < objectiveBottom) then
                objectiveBottom = bottom
            end
        end
        details.objectiveTop = objectiveTop
        details.objectiveBottom = objectiveBottom
    end
    return details
end

function Addon.MapResolveQuestButtonIdentity(button)
    local identity = {
        questID = nil,
        questLogIndex = nil,
        isHeader = nil,
    }
    if not button then
        return identity
    end

    local questID = button.questID or button.questId
    local questLogIndex = button.questLogIndex or button.logIndex or button.index
    local isHeader = button.isHeader
    local elementData = button.elementData

    if type(button.GetElementData) == "function" then
        local okElementData, value = pcall(button.GetElementData, button)
        if okElementData and type(value) == "table" then
            elementData = value
        end
    end

    if type(elementData) == "table" then
        if type(questID) ~= "number" then
            local value = elementData.questID or elementData.questId
            if type(value) == "number" then
                questID = value
            end
        end

        if type(questLogIndex) ~= "number" then
            local value = elementData.questLogIndex or elementData.logIndex or elementData.index
            if type(value) == "number" then
                questLogIndex = value
            end
        end

        if isHeader == nil then
            if elementData.isHeader ~= nil then
                isHeader = elementData.isHeader and true or false
            elseif elementData.isCampaignHeader ~= nil then
                isHeader = elementData.isCampaignHeader and true or false
            elseif elementData.isCategoryHeader ~= nil then
                isHeader = elementData.isCategoryHeader and true or false
            end
        end
    end

    if type(questID) ~= "number" and type(button.GetQuestID) == "function" then
        local okQuestID, value = pcall(button.GetQuestID, button)
        if okQuestID and type(value) == "number" then
            questID = value
        end
    end

    if type(questLogIndex) ~= "number" and type(button.GetQuestLogIndex) == "function" then
        local okLogIndex, value = pcall(button.GetQuestLogIndex, button)
        if okLogIndex and type(value) == "number" then
            questLogIndex = value
        end
    end

    if type(questLogIndex) ~= "number" and type(button.GetID) == "function" then
        local okID, value = pcall(button.GetID, button)
        if okID and type(value) == "number" then
            questLogIndex = value
        end
    end

    if type(questID) ~= "number"
        and type(questLogIndex) == "number"
        and type(C_QuestLog) == "table"
        and type(C_QuestLog.GetQuestIDForLogIndex) == "function" then
        local okFromLog, questFromLog = pcall(C_QuestLog.GetQuestIDForLogIndex, questLogIndex)
        if okFromLog and type(questFromLog) == "number" then
            questID = questFromLog
        end
    end

    if isHeader == nil then
        local buttonName = Util.SafeGetObjectName(button)
        if type(buttonName) == "string" and buttonName:find("Title", 1, true) then
            isHeader = true
        end
    end

    identity.questID = questID
    identity.questLogIndex = questLogIndex
    identity.isHeader = isHeader
    return identity
end

function Addon.MapFindQuestHeaderClickProxy(button)
    if not button then return nil end

    local function IsHeaderCandidate(candidate)
        if not candidate or candidate == button then return false end
        if type(candidate.GetObjectType) ~= "function" or candidate:GetObjectType() ~= "Button" then
            return false
        end
        local info = (type(Addon.MapResolveQuestButtonIdentity) == "function")
            and Addon.MapResolveQuestButtonIdentity(candidate) or nil
        if not info then return false end
        local hasQuestData = (type(info.questID) == "number" and info.questID > 0)
            or (type(info.questLogIndex) == "number" and info.questLogIndex > 0)
        return hasQuestData or (info.isHeader == true)
    end

    local targetTop = Util.SafeMethodRead(button, "GetTop")
    local targetBottom = Util.SafeMethodRead(button, "GetBottom")
    local function ScoreCandidate(candidate)
        local candidateTop = Util.SafeMethodRead(candidate, "GetTop")
        local candidateBottom = Util.SafeMethodRead(candidate, "GetBottom")
        if type(targetTop) ~= "number" or type(targetBottom) ~= "number"
            or type(candidateTop) ~= "number" or type(candidateBottom) ~= "number" then
            return -1000000
        end

        local targetCenter = (targetTop + targetBottom) * 0.5
        local candidateCenter = (candidateTop + candidateBottom) * 0.5
        local overlap = math.min(targetTop, candidateTop) - math.max(targetBottom, candidateBottom)
        local score = -(math.abs(candidateCenter - targetCenter))
        if overlap >= -2 then
            score = score + 1000
        end
        return score
    end

    local parent = (type(button.GetParent) == "function") and button:GetParent() or nil
    local depth = 0
    while parent and depth < 6 do
        if IsHeaderCandidate(parent) then
            return parent
        end

        if type(parent.GetChildren) == "function" then
            local bestCandidate = nil
            local bestScore = nil
            for _, sibling in ipairs({ parent:GetChildren() }) do
                if IsHeaderCandidate(sibling) then
                    local score = ScoreCandidate(sibling)
                    if not bestCandidate or score > bestScore then
                        bestCandidate = sibling
                        bestScore = score
                    end
                end
            end
            if bestCandidate then
                return bestCandidate
            end
        end

        parent = (type(parent.GetParent) == "function") and parent:GetParent() or nil
        depth = depth + 1
    end

    return nil
end
function UI.EnsureQuestLogOverlayPanel(map)
    -- Short-circuit: new quest log panel module handles all quest UI.
    -- Return nil so old panel code never builds.
    if Addon.QuestLogPanel and type(Addon.QuestLogPanel.EnsurePanel) == "function" then
        return nil
    end
    if not map then return nil end
    local parentTarget = UI.GetQuestPanelAnchorTarget(map) or map
    local panel = map._muiQuestLogPanel

    if not panel then
        panel = CreateFrame("Frame", nil, parentTarget)
        panel:SetFrameStrata(C.QUEST_LOG_PANEL_STRATA)
        panel:SetFrameLevel(map:GetFrameLevel() + 26)
        panel:SetClipsChildren(true)
        panel:SetAlpha(1)

        -- Deep near-black warm background — the single dark canvas
        local bg = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetAllPoints()
        bg:SetTexture(C.WHITE8X8)
        bg:SetVertexColor(0.04, 0.03, 0.02, 0.96)
        panel._muiBg = bg

        -- Subtle warm gradient at top — glass highlight
        local bgTopGlow = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
        bgTopGlow:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
        bgTopGlow:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
        bgTopGlow:SetHeight(140)
        bgTopGlow:SetTexture(C.WHITE8X8)
        if type(bgTopGlow.SetGradientAlpha) == "function" then
            bgTopGlow:SetGradientAlpha("VERTICAL", 0.72, 0.62, 0.42, 0.00, 0.72, 0.62, 0.42, 0.04)
        else
            bgTopGlow:SetVertexColor(0.72, 0.62, 0.42, 0.02)
        end
        panel._muiBgTopGlow = bgTopGlow

        -- Deeper shadow at bottom for grounding
        local bgBottomShade = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
        bgBottomShade:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 0, 0)
        bgBottomShade:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
        bgBottomShade:SetHeight(60)
        bgBottomShade:SetTexture(C.WHITE8X8)
        if type(bgBottomShade.SetGradientAlpha) == "function" then
            bgBottomShade:SetGradientAlpha("VERTICAL", 0, 0, 0, 0.22, 0, 0, 0, 0.00)
        else
            bgBottomShade:SetVertexColor(0, 0, 0, 0.11)
        end
        panel._muiBgBottomShade = bgBottomShade

        -- Left shadow — wider, softer for depth separation from map
        local leftShadow = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
        leftShadow:SetPoint("TOPRIGHT", panel, "TOPLEFT", 0, 0)
        leftShadow:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 0, 0)
        leftShadow:SetWidth(20)
        leftShadow:SetTexture(C.WHITE8X8)
        if type(leftShadow.SetGradientAlpha) == "function" then
            leftShadow:SetGradientAlpha("HORIZONTAL", 0, 0, 0, 0.00, 0, 0, 0, 0.45)
        else
            leftShadow:SetVertexColor(0, 0, 0, 0.22)
        end
        panel._muiLeftShadow = leftShadow

        -- Single subtle outer border — warm gold at low opacity
        local border = panel:CreateTexture(nil, "BORDER")
        border:SetPoint("TOPLEFT", -1, 1)
        border:SetPoint("BOTTOMRIGHT", 1, -1)
        border:SetTexture(C.WHITE8X8)
        border:SetVertexColor(0.42, 0.34, 0.22, 0.45)
        panel._muiBorder = border

        -- Inner edge highlight — just the top edge for glass feel
        local innerBorder = panel:CreateTexture(nil, "ARTWORK", nil, 1)
        innerBorder:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
        innerBorder:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 1)
        innerBorder:SetTexture(C.WHITE8X8)
        innerBorder:SetVertexColor(0.72, 0.62, 0.42, 0.06)
        panel._muiInnerBorder = innerBorder

        -- Top highlight — refined thin gold line
        local topHighlight = panel:CreateTexture(nil, "ARTWORK", nil, 2)
        topHighlight:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
        topHighlight:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
        topHighlight:SetHeight(1)
        topHighlight:SetTexture(C.WHITE8X8)
        topHighlight:SetVertexColor(0.72, 0.62, 0.42, 0.30)
        panel._muiTopHighlight = topHighlight

        -- Left accent stripe — thinner, more refined
        -- Bold left accent stripe — signature design element
        local accentR, accentG, accentB = UI.GetAccentColor()
        local accent = panel:CreateTexture(nil, "ARTWORK")
        accent:SetPoint("TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", 0, 0)
        accent:SetWidth(3)
        accent:SetTexture(C.WHITE8X8)
        accent:SetVertexColor(accentR, accentG, accentB, 0.85)
        panel._muiAccent = accent

        local header = CreateFrame("Frame", nil, panel)
        header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
        header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
        header:SetHeight(C.QUEST_LOG_PANEL_HEADER_HEIGHT)
        panel._muiHeader = header

        -- Header background — just barely distinguishable from panel
        local headerBg = header:CreateTexture(nil, "BACKGROUND", nil, -6)
        headerBg:SetAllPoints()
        headerBg:SetTexture(C.WHITE8X8)
        headerBg:SetVertexColor(0.06, 0.05, 0.03, 0.98)
        panel._muiHeaderBg = headerBg

        -- No top line — clean edge
        local headerTopLine = header:CreateTexture(nil, "ARTWORK")
        headerTopLine:SetTexture(C.WHITE8X8)
        headerTopLine:SetPoint("TOPLEFT", header, "TOPLEFT", 0, 0)
        headerTopLine:SetPoint("TOPRIGHT", header, "TOPRIGHT", 0, 0)
        headerTopLine:SetHeight(1)
        headerTopLine:SetVertexColor(0, 0, 0, 0)
        panel._muiHeaderTopLine = headerTopLine

        -- Bottom divider — gradient that fades from left to right (open edge)
        local headerDivider = header:CreateTexture(nil, "BORDER")
        headerDivider:SetTexture(C.WHITE8X8)
        headerDivider:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 6, 0)
        headerDivider:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
        headerDivider:SetHeight(1)
        if type(headerDivider.SetGradientAlpha) == "function" then
            headerDivider:SetGradientAlpha("HORIZONTAL", 0.82, 0.68, 0.38, 0.25, 0.82, 0.68, 0.38, 0.00)
        else
            headerDivider:SetVertexColor(0.82, 0.68, 0.38, 0.12)
        end
        panel._muiHeaderDivider = headerDivider

        -- Title — larger font, clean positioning
        local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOPLEFT", header, "TOPLEFT", 16, -12)
        title:SetTextColor(0.94, 0.89, 0.78, 1)
        title:SetText(_G.MAP_AND_QUEST_LOG or _G.QUESTS_LABEL or "Quest Log")
        panel._muiHeaderTitle = title

        -- Subtitle — muted, secondary info
        local subtitle = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 1, -3)
        subtitle:SetPoint("TOPRIGHT", header, "TOPRIGHT", -50, -28)
        subtitle:SetJustifyH("LEFT")
        subtitle:SetTextColor(0.52, 0.46, 0.34, 0.80)
        subtitle:SetText(UI.GetQuestPanelModeSubtitle("Quests"))
        panel._muiHeaderSubTitle = subtitle

        -- Mode badge — smaller, more subtle pill shape
        local modeBadge = CreateFrame("Frame", nil, header)
        modeBadge:SetSize(0, 0)
        modeBadge:SetPoint("TOPRIGHT", header, "TOPRIGHT", -14, -12)
        panel._muiHeaderModeBadge = modeBadge

        local modeBg = modeBadge:CreateTexture(nil, "BACKGROUND")
        modeBg:SetAllPoints()
        modeBg:SetTexture(C.WHITE8X8)
        modeBg:SetVertexColor(0, 0, 0, 0)
        panel._muiHeaderModeBg = modeBg

        local modeBorder = modeBadge:CreateTexture(nil, "BORDER")
        modeBorder:SetPoint("TOPLEFT", -1, 1)
        modeBorder:SetPoint("BOTTOMRIGHT", 1, -1)
        modeBorder:SetTexture(C.WHITE8X8)
        modeBorder:SetVertexColor(0, 0, 0, 0)
        panel._muiHeaderModeBorder = modeBorder

        local modeText = modeBadge:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        modeText:SetPoint("CENTER", modeBadge, "CENTER", 0, 0)
        modeText:SetTextColor(0, 0, 0, 0)
        modeText:SetText("")
        panel._muiHeaderModeText = modeText

        -- Minimize/close button — clean, right-aligned
        local minimizeButton = CreateFrame("Button", nil, header)
        minimizeButton:SetSize(22, 22)
        minimizeButton:SetPoint("TOPRIGHT", header, "TOPRIGHT", -12, -12)
        minimizeButton:RegisterForClicks("LeftButtonUp")
        UI.SuppressButtonArt(minimizeButton)
        if type(minimizeButton.SetHitRectInsets) == "function" then
            minimizeButton:SetHitRectInsets(-4, -4, -4, -4)
        end
        if type(minimizeButton.SetFrameStrata) == "function" then
            minimizeButton:SetFrameStrata(panel:GetFrameStrata())
        end
        if type(minimizeButton.SetFrameLevel) == "function" then
            minimizeButton:SetFrameLevel(header:GetFrameLevel() + 4)
        end

        local minimizeBg = minimizeButton:CreateTexture(nil, "BACKGROUND", nil, -2)
        minimizeBg:SetAllPoints()
        minimizeBg:SetTexture(C.WHITE8X8)
        minimizeButton._muiMinimizeBg = minimizeBg

        local minimizeBorder = minimizeButton:CreateTexture(nil, "BORDER", nil, -1)
        minimizeBorder:SetPoint("TOPLEFT", minimizeButton, "TOPLEFT", 0, 0)
        minimizeBorder:SetPoint("BOTTOMRIGHT", minimizeButton, "BOTTOMRIGHT", 0, 0)
        minimizeBorder:SetTexture(C.WHITE8X8)
        minimizeButton._muiMinimizeBorder = minimizeBorder

        -- X icon instead of a dash — cleaner close affordance
        local minimizeIcon = minimizeButton:CreateTexture(nil, "OVERLAY", nil, 4)
        minimizeIcon:SetTexture(C.WHITE8X8)
        minimizeIcon:SetSize(10, 2)
        minimizeIcon:SetPoint("CENTER", minimizeButton, "CENTER", 0, 0)
        minimizeButton.Icon = minimizeIcon

        minimizeButton:SetScript("OnClick", function()
            local ownerMap = panel._muiOwnerMap or _G.WorldMapFrame
            UI.HideQuestLogPanel(ownerMap)
        end)
        minimizeButton:SetScript("OnEnter", function(self)
            UI.ApplyQuestPanelMinimizeButtonVisual(self, true)
            if GameTooltip and type(GameTooltip.SetOwner) == "function" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText("Minimize", 1, 1, 1)
                GameTooltip:Show()
            end
        end)
        minimizeButton:SetScript("OnLeave", function(self)
            UI.ApplyQuestPanelMinimizeButtonVisual(self, false)
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        minimizeButton:SetScript("OnShow", function(self)
            UI.ApplyQuestPanelMinimizeButtonVisual(self, type(self.IsMouseOver) == "function" and self:IsMouseOver())
        end)
        UI.ApplyQuestPanelMinimizeButtonVisual(minimizeButton, false)
        panel._muiHeaderMinimizeButton = minimizeButton

        local tabsHost = CreateFrame("Frame", nil, header)
        tabsHost:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", C.QUEST_LOG_PANEL_CONTENT_INSET, 7)
        tabsHost:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", -C.QUEST_LOG_PANEL_CONTENT_INSET, 7)
        tabsHost:SetHeight(C.QUEST_LOG_PANEL_TAB_HEIGHT)
        panel._muiTabsHost = tabsHost

        UI.EnsureQuestPanelTabButton(panel, "Quests")
        UI.EnsureQuestPanelTabButton(panel, "Events")
        UI.EnsureQuestPanelTabButton(panel, "MapLegend")

        local content = CreateFrame("Frame", nil, panel)
        content:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
        content:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
        panel._muiContentHost = content

        -- Content background — seamless with panel, no separate border
        local contentBg = content:CreateTexture(nil, "BACKGROUND", nil, -6)
        contentBg:SetAllPoints()
        contentBg:SetTexture(C.WHITE8X8)
        contentBg:SetVertexColor(0, 0, 0, 0)
        panel._muiContentBg = contentBg

        -- No top shade — clean transition from header
        local contentShade = content:CreateTexture(nil, "BACKGROUND", nil, -5)
        contentShade:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        contentShade:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, 0)
        contentShade:SetHeight(1)
        contentShade:SetTexture(C.WHITE8X8)
        contentShade:SetVertexColor(0, 0, 0, 0)
        panel._muiContentShade = contentShade

        -- No content border — seamless panel
        local contentBorder = content:CreateTexture(nil, "BORDER")
        contentBorder:SetPoint("TOPLEFT", -1, 1)
        contentBorder:SetPoint("BOTTOMRIGHT", 1, -1)
        contentBorder:SetTexture(C.WHITE8X8)
        contentBorder:SetVertexColor(0, 0, 0, 0)
        panel._muiContentBorder = contentBorder

        local questSearchHost = CreateFrame("Frame", nil, content)
        questSearchHost:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -2)
        questSearchHost:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -2)
        questSearchHost:SetHeight(24)
        panel._muiQuestSearchHost = questSearchHost

        local contentBanner = CreateFrame("Frame", nil, content)
        contentBanner:SetPoint("TOPLEFT", questSearchHost, "BOTTOMLEFT", 0, -4)
        contentBanner:SetPoint("TOPRIGHT", questSearchHost, "BOTTOMRIGHT", 0, -4)
        contentBanner:SetHeight(QUEST_LIST_REDESIGN_CAMPAIGN_HEIGHT)
        panel._muiContentBanner = contentBanner

        local bannerBg = contentBanner:CreateTexture(nil, "BACKGROUND", nil, -2)
        bannerBg:SetAllPoints()
        bannerBg:SetTexture(C.WHITE8X8)
        bannerBg:SetVertexColor(0, 0, 0, 0)
        panel._muiContentBannerBg = bannerBg

        local bannerAccent = contentBanner:CreateTexture(nil, "ARTWORK")
        bannerAccent:SetPoint("TOPLEFT", contentBanner, "TOPLEFT", 8, -8)
        bannerAccent:SetPoint("BOTTOMLEFT", contentBanner, "BOTTOMLEFT", 8, 8)
        bannerAccent:SetWidth(3)
        bannerAccent:SetTexture(C.WHITE8X8)
        panel._muiContentBannerAccent = bannerAccent

        local bannerEdge = contentBanner:CreateTexture(nil, "BORDER")
        bannerEdge:SetPoint("BOTTOMLEFT", contentBanner, "BOTTOMLEFT", 0, 0)
        bannerEdge:SetPoint("BOTTOMRIGHT", contentBanner, "BOTTOMRIGHT", 0, 0)
        bannerEdge:SetHeight(1)
        bannerEdge:SetTexture(C.WHITE8X8)
        panel._muiContentBannerEdge = bannerEdge

        local bannerLabel = contentBanner:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        bannerLabel:SetPoint("LEFT", contentBanner, "LEFT", 14, 0)
        bannerLabel:SetJustifyH("LEFT")
        panel._muiContentBannerLabel = bannerLabel

        local bannerHint = contentBanner:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        bannerHint:SetPoint("LEFT", bannerLabel, "RIGHT", 10, 0)
        bannerHint:SetPoint("RIGHT", contentBanner, "RIGHT", -10, 0)
        bannerHint:SetJustifyH("RIGHT")
        if type(bannerHint.SetWordWrap) == "function" then
            bannerHint:SetWordWrap(false)
        end
        panel._muiContentBannerHint = bannerHint

        local campaignWidget = QEngine.CreateCampaignProgressWidget(contentBanner)
        campaignWidget:SetPoint("TOPLEFT", contentBanner, "TOPLEFT", 0, 0)
        campaignWidget:SetPoint("BOTTOMRIGHT", contentBanner, "BOTTOMRIGHT", 0, 0)
        campaignWidget:Hide()
        panel._muiCampaignWidget = campaignWidget
        contentBanner:Hide()

        local contentInner = CreateFrame("Frame", nil, content)
        contentInner:SetPoint("TOPLEFT", questSearchHost, "BOTTOMLEFT", 0, -2)
        contentInner:SetPoint("BOTTOMRIGHT", content, "BOTTOMRIGHT", 0, 0)
        contentInner:SetClipsChildren(true)
        panel._muiContentInner = contentInner

        -- Inner background — transparent, content flows over panel bg
        local contentInnerBg = contentInner:CreateTexture(nil, "BACKGROUND", nil, -7)
        contentInnerBg:SetAllPoints()
        contentInnerBg:SetTexture(C.WHITE8X8)
        contentInnerBg:SetVertexColor(0, 0, 0, 0)
        panel._muiContentInnerBg = contentInnerBg

        local contentInnerGlow = contentInner:CreateTexture(nil, "BACKGROUND", nil, -6)
        contentInnerGlow:SetPoint("TOPLEFT", contentInner, "TOPLEFT", 0, 0)
        contentInnerGlow:SetPoint("TOPRIGHT", contentInner, "TOPRIGHT", 0, 0)
        contentInnerGlow:SetHeight(1)
        contentInnerGlow:SetTexture(C.WHITE8X8)
        panel._muiContentInnerGlow = contentInnerGlow

        -- No inner border
        local contentInnerBorder = contentInner:CreateTexture(nil, "BORDER")
        contentInnerBorder:SetPoint("TOPLEFT", contentInner, "TOPLEFT", -1, 1)
        contentInnerBorder:SetPoint("BOTTOMRIGHT", contentInner, "BOTTOMRIGHT", 1, -1)
        contentInnerBorder:SetTexture(C.WHITE8X8)
        contentInnerBorder:SetVertexColor(0, 0, 0, 0)
        panel._muiContentInnerBorder = contentInnerBorder

        -- Scroll frame
        local questListScroll = CreateFrame("ScrollFrame", nil, contentInner, "UIPanelScrollFrameTemplate")
        questListScroll:SetPoint("TOPLEFT", contentInner, "TOPLEFT", 0, 0)
        questListScroll:SetPoint("BOTTOMRIGHT", contentInner, "BOTTOMRIGHT", 0, 0)
        panel._muiQuestListScroll = questListScroll

        local questListScrollChild = CreateFrame("Frame", nil, questListScroll)
        local scrollChildWidth = (UI.GetQuestPanelWidth() - 16 - 14)
        questListScrollChild:SetWidth(math.max(1, scrollChildWidth))
        questListScrollChild:SetHeight(1)
        questListScroll:SetScrollChild(questListScrollChild)
        panel._muiQuestListScrollChild = questListScrollChild

        questListScroll:HookScript("OnSizeChanged", function(self, w)
            if questListScrollChild and type(w) == "number" and w > 0 then
                questListScrollChild:SetWidth(math.max(1, w - 14))
            end
        end)

        -- Thin scrollbar
        local scrollBar = questListScroll.ScrollBar
        if scrollBar then
            if type(scrollBar.SetWidth) == "function" then
                scrollBar:SetWidth(4)
            end
        end

        UI.EnsureQuestDetailsSurface(panel)

        -- Wire up the real RebuildQuestListLayout now that the panel exists
        -- ================================================================
        -- Helper: render a list of quests within a bucket section
        -- ================================================================
        -- Helper: render a single quest row + its objectives/abandon button
        local function RenderSingleQuest(questData, scrollChild, totalHeight, pad, gap, showAbandon)
            local questRow = QEngine.QuestListAcquireFromPool("quests", QEngine.CreateQuestListQuestRow, scrollChild)
            questRow:SetQuestData(questData)
            questRow:ClearAllPoints()
            questRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad, -totalHeight)
            questRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad, 0)
            totalHeight = totalHeight + QUEST_LIST_REDESIGN_QUEST_HEIGHT + gap

            local showObjectives = Util.ShouldShowQuestObjectivesInLog()
            local objectiveRows = showObjectives and QEngine.BuildQuestObjectiveDisplayRows(questData) or {}
            if showObjectives and #objectiveRows > 0 then
                local shownObjectives = math.min(#objectiveRows, QUEST_LIST_REDESIGN_MAX_OBJECTIVE_ROWS)
                for objectiveIndex = 1, shownObjectives do
                    local objectiveRow = QEngine.QuestListAcquireFromPool("objectives", QEngine.CreateQuestListObjectiveRow, scrollChild)
                    objectiveRow:ClearAllPoints()
                    objectiveRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad + 12, -totalHeight)
                    objectiveRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad - 4, 0)
                    objectiveRow:SetObjectiveData(objectiveRows[objectiveIndex])
                    local objH = objectiveRow:GetHeight() or QUEST_LIST_REDESIGN_OBJECTIVE_MIN_HEIGHT
                    totalHeight = totalHeight + objH + gap
                end
                if #objectiveRows > shownObjectives then
                    local remaining = #objectiveRows - shownObjectives
                    local overflowRow = QEngine.QuestListAcquireFromPool("objectives", QEngine.CreateQuestListObjectiveRow, scrollChild)
                    overflowRow:ClearAllPoints()
                    overflowRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad + 12, -totalHeight)
                    overflowRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad - 4, 0)
                    overflowRow:SetObjectiveData({
                        text = string.format("+%d more...", remaining),
                        finished = false,
                        isMeta = true,
                    })
                    local overflowH = overflowRow:GetHeight() or QUEST_LIST_REDESIGN_OBJECTIVE_MIN_HEIGHT
                    totalHeight = totalHeight + overflowH + gap
                end
            end

            if showAbandon and questData.questID then
                local abandonRow = QEngine.QuestListAcquireFromPool("abandonButtons", QEngine.CreateAbandonButtonRow, scrollChild)
                abandonRow:SetAbandonData(questData.questID, questData.title)
                abandonRow:ClearAllPoints()
                abandonRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad + 12, -totalHeight)
                abandonRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad - 4, 0)
                totalHeight = totalHeight + 24 + gap
            end
            return totalHeight
        end

        local function RenderQuestRows(quests, scrollChild, totalHeight, bucketKey, showAbandon, listData)
            local pad = QUEST_LIST_REDESIGN_PADDING
            local gap = QUEST_LIST_REDESIGN_ROW_GAP

            -- Synergy combo boxes for NOW bucket
            if bucketKey == "now" and listData.synergyGroups and #listData.synergyGroups > 0 then
                for _, group in ipairs(listData.synergyGroups) do
                    local comboRow = QEngine.QuestListAcquireFromPool("comboBoxes", QEngine.CreateSynergyComboRow, scrollChild)
                    comboRow:SetSynergyData(group.keyword, #group.questIndices)
                    comboRow:ClearAllPoints()
                    comboRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad, -totalHeight)
                    comboRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad, 0)
                    totalHeight = totalHeight + 26 + gap
                end
            end

            -- ── Group quests by zone (headerTitle) ──────────────────────
            local zoneOrder = {}   -- ordered unique zone names
            local zoneQuests = {}  -- zoneName -> { quest, quest, ... }
            local currentZoneName = listData.zoneName or ""

            for _, questData in ipairs(quests) do
                local zone = questData.headerTitle or "Miscellaneous"
                if not zoneQuests[zone] then
                    zoneQuests[zone] = {}
                    zoneOrder[#zoneOrder + 1] = zone
                end
                zoneQuests[zone][#zoneQuests[zone] + 1] = questData
            end

            -- Sort zone order: current zone first, then alphabetically
            table.sort(zoneOrder, function(a, b)
                local aIsCurrent = (a == currentZoneName)
                local bIsCurrent = (b == currentZoneName)
                if aIsCurrent ~= bIsCurrent then return aIsCurrent end
                return a < b
            end)

            -- Only show zone sub-headers when there are 2+ zones in this bucket
            local showZoneHeaders = (#zoneOrder > 1)

            for _, zoneName in ipairs(zoneOrder) do
                local zoneQuestList = zoneQuests[zoneName]
                local isZoneCollapsed = questListCollapseState[zoneName] == true

                if showZoneHeaders then
                    local isCurrentZone = (zoneName == currentZoneName)
                    local zoneHeader = QEngine.QuestListAcquireFromPool("zoneSubHeaders", QEngine.CreateZoneSubHeaderRow, scrollChild)
                    zoneHeader:SetZoneHeaderData(zoneName, #zoneQuestList, isCurrentZone, isZoneCollapsed)
                    zoneHeader:ClearAllPoints()
                    zoneHeader:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad, -totalHeight)
                    zoneHeader:SetPoint("RIGHT", scrollChild, "RIGHT", -pad, 0)
                    totalHeight = totalHeight + QUEST_LIST_REDESIGN_ZONE_HEADER_HEIGHT + gap
                end

                if not isZoneCollapsed then
                    for _, questData in ipairs(zoneQuestList) do
                        totalHeight = RenderSingleQuest(questData, scrollChild, totalHeight, pad, gap, showAbandon)
                    end
                end
            end
            return totalHeight
        end

        RebuildQuestListLayout = function()
            if not panel or not panel._muiQuestListScrollChild then
                return
            end
            if not Runtime.questLogPanelOpen then
                return
            end

            -- Reparent/style search box
            local questOverlay = panel._muiQuestOverlayFrame or _G.QuestMapFrame
            local questsFrame = questOverlay and questOverlay.QuestsFrame or nil
            local questScrollFrame = (questsFrame and questsFrame.ScrollFrame) or _G.QuestScrollFrame
            if questScrollFrame then
                Addon.MapEnsureQuestSearchBoxStyle(questScrollFrame, "Quests", panel)
                Addon.MapEnsureQuestSettingsDropdownStyle(questScrollFrame, "Quests", panel)
            end

            local searchText = nil
            local searchBox = panel._muiQuestSearchBox
            if searchBox and type(searchBox.GetText) == "function" then
                local text = searchBox:GetText()
                if type(text) == "string" and text ~= "" then
                    searchText = text
                end
            end

            local listData = QEngine.CollectQuestListData(searchText)

            -- Release all pools
            for poolKey in pairs(questListPools) do
                QEngine.QuestListReleaseAllInPool(poolKey)
            end

            local scrollChild = panel._muiQuestListScrollChild
            local cw = panel._muiCampaignWidget
            local contentBanner = panel._muiContentBanner
            local contentInner = panel._muiContentInner
            local contentHost = panel._muiContentHost
            local searchHost = panel._muiQuestSearchHost
            local campaignCardData = listData.campaign or QEngine.ResolveCampaignCardFallback(listData.headers)

            -- Campaign card positioning (unchanged)
            if campaignCardData and cw and contentBanner then
                cw:SetCampaignData(campaignCardData)
                if contentBanner and type(contentBanner.Show) == "function" then
                    contentBanner:Show()
                end
                if contentInner and contentHost
                    and type(contentInner.ClearAllPoints) == "function"
                    and type(contentInner.SetPoint) == "function" then
                    contentInner:ClearAllPoints()
                    contentInner:SetPoint("TOPLEFT", contentBanner, "BOTTOMLEFT", 0, -2)
                    contentInner:SetPoint("BOTTOMRIGHT", contentHost, "BOTTOMRIGHT", 0, 0)
                end
            else
                if cw and type(cw.Hide) == "function" then cw:Hide() end
                if contentBanner and type(contentBanner.Hide) == "function" then contentBanner:Hide() end
                if contentInner and contentHost
                    and type(contentInner.ClearAllPoints) == "function"
                    and type(contentInner.SetPoint) == "function" then
                    contentInner:ClearAllPoints()
                    if searchHost then
                        contentInner:SetPoint("TOPLEFT", searchHost, "BOTTOMLEFT", 0, -2)
                    else
                        contentInner:SetPoint("TOPLEFT", contentHost, "TOPLEFT", 0, -2)
                    end
                    contentInner:SetPoint("BOTTOMRIGHT", contentHost, "BOTTOMRIGHT", 0, 0)
                end
            end

            local totalHeight = 0
            local pad = QUEST_LIST_REDESIGN_PADDING
            local gap = QUEST_LIST_REDESIGN_ROW_GAP

            local focusedQuest = nil
            focusedQuest = (select(1, QEngine.ExtractFocusedQuestFromBuckets(listData)))

            if focusedQuest then
                local focusHeader = QEngine.QuestListAcquireFromPool("focusHeaders", QEngine.CreateFocusHeaderRow, scrollChild)
                focusHeader:SetFocusData(focusedQuest)
                focusHeader:ClearAllPoints()
                focusHeader:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -totalHeight)
                focusHeader:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
                totalHeight = totalHeight + 32 + gap

                totalHeight = RenderQuestRows({ focusedQuest }, scrollChild, totalHeight, "focus", false, listData)
                totalHeight = totalHeight + pad
            end

            -- ========== Bucket Sections: NOW / NEXT / LATER ==========
            local isAtMaxQuests = (listData.totalQuestCount >= listData.maxQuests)

            for _, bucketKey in ipairs(BUCKET_ORDER) do
                local quests = listData.buckets[bucketKey]
                if #quests > 0 then
                    local isCollapsed = bucketCollapseState[bucketKey] == true

                    -- Bucket header
                    local bucketHeader = QEngine.QuestListAcquireFromPool("bucketHeaders", QEngine.CreateBucketHeaderRow, scrollChild)
                    bucketHeader:SetBucketData(bucketKey, #quests, isCollapsed)
                    bucketHeader:ClearAllPoints()
                    bucketHeader:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -totalHeight)
                    bucketHeader:SetPoint("RIGHT", scrollChild, "RIGHT", 0, 0)
                    totalHeight = totalHeight + QUEST_LIST_REDESIGN_BUCKET_HEADER_HEIGHT + gap

                    if not isCollapsed then
                        -- Show abandon buttons in Later bucket when quest log is near capacity
                        local showAbandon = (bucketKey == "later" and isAtMaxQuests)
                        totalHeight = RenderQuestRows(quests, scrollChild, totalHeight, bucketKey, showAbandon, listData)
                        totalHeight = totalHeight + pad
                    end
                end
            end

            -- Empty state
            local totalQuestCount = #listData.buckets.now + #listData.buckets.next + #listData.buckets.later
            if focusedQuest then
                totalQuestCount = totalQuestCount + 1
            end
            if totalQuestCount == 0 then
                local emptyRow = QEngine.QuestListAcquireFromPool("empty", QEngine.CreateQuestListEmptyStateRow, scrollChild)
                emptyRow:SetState(searchText)
                emptyRow:ClearAllPoints()
                emptyRow:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", pad, -totalHeight)
                emptyRow:SetPoint("RIGHT", scrollChild, "RIGHT", -pad, 0)
                totalHeight = totalHeight + 64 + pad
            end

            scrollChild:SetHeight(math.max(totalHeight, 1))

            local function RefreshQuestRowProgressFill(targetScrollChild, reasonTag)
                if not targetScrollChild or type(targetScrollChild.GetChildren) ~= "function" then
                    return
                end

                local refreshed = 0
                for _, row in ipairs({ targetScrollChild:GetChildren() }) do
                    if row and type(row.UpdateProgressWidth) == "function" then
                        row:UpdateProgressWidth(row._objectivePercent)
                        refreshed = refreshed + 1
                    end
                end

            end

            RefreshQuestRowProgressFill(scrollChild, "RebuildQuestListLayout:t+0.00")

            if C_Timer and type(C_Timer.After) == "function" then
                local deferredScrollChild = scrollChild
                C_Timer.After(0, function()
                    RefreshQuestRowProgressFill(deferredScrollChild, "RebuildQuestListLayout:t+0.00-next")
                end)
                C_Timer.After(0.05, function()
                    RefreshQuestRowProgressFill(deferredScrollChild, "RebuildQuestListLayout:t+0.05")
                end)
            end
        end

        UI.ApplyQuestPanelHeaderState(panel, "Quests")

        local slideIn = panel:CreateAnimationGroup()
        local inMove = slideIn:CreateAnimation("Translation")
        inMove:SetOrder(1)
        inMove:SetDuration(C.QUEST_LOG_SLIDE_DURATION)
        inMove:SetOffset(UI.GetQuestPanelSlideDistance(), 0)
        inMove:SetSmoothing("OUT")

        local inFade = slideIn:CreateAnimation("Alpha")
        inFade:SetOrder(1)
        inFade:SetDuration(C.QUEST_LOG_SLIDE_DURATION)
        inFade:SetFromAlpha(0.00)
        inFade:SetToAlpha(1.0)
        inFade:SetSmoothing("OUT")

        slideIn:SetScript("OnPlay", function(group)
            local owner = group:GetParent()
            owner._muiQuestPanelAnimating = true
        end)
        slideIn:SetScript("OnFinished", function(group)
            local owner = group:GetParent()
            if owner._muiSuppressSlideInFinish then
                owner._muiSuppressSlideInFinish = false
                owner._muiQuestPanelAnimating = false
                return
            end
            if owner._muiQuestPanelDesiredOpen ~= true then
                owner._muiQuestPanelAnimating = false
                return
            end
            UI.SetQuestPanelAnchors(owner, owner._muiOwnerMap, UI.GetQuestPanelShownOffset())
            owner:SetAlpha(1)
            owner._muiQuestPanelAnimating = false
            Runtime.questLogPanelOpen = true
            UI.RefreshQuestLogButtonState()
            UI.RefreshQuestPanelTabs(owner)
            RebuildQuestListLayout()
        end)

        local slideOut = panel:CreateAnimationGroup()
        local outMove = slideOut:CreateAnimation("Translation")
        outMove:SetOrder(1)
        outMove:SetDuration(0.22)
        outMove:SetOffset(-UI.GetQuestPanelSlideDistance(), 0)
        outMove:SetSmoothing("IN")

        local outFade = slideOut:CreateAnimation("Alpha")
        outFade:SetOrder(1)
        outFade:SetDuration(0.22)
        outFade:SetFromAlpha(1.0)
        outFade:SetToAlpha(0.00)
        outFade:SetSmoothing("IN")

        slideOut:SetScript("OnPlay", function(group)
            local owner = group:GetParent()
            owner._muiQuestPanelAnimating = true
        end)
        slideOut:SetScript("OnFinished", function(group)
            local owner = group:GetParent()
            if owner._muiSuppressSlideOutFinish then
                owner._muiSuppressSlideOutFinish = false
                owner._muiQuestPanelAnimating = false
                return
            end
            if owner._muiQuestPanelDesiredOpen == true then
                UI.SetQuestPanelAnchors(owner, owner._muiOwnerMap, UI.GetQuestPanelShownOffset())
                owner:SetAlpha(1)
                owner._muiQuestPanelAnimating = false
                Runtime.questLogPanelOpen = true
                UI.RefreshQuestLogButtonState()
                return
            end
            owner._muiQuestPanelAnimating = false
            Runtime.questLogPanelOpen = false
            owner:Hide()
            owner:SetAlpha(1)
            UI.SetQuestPanelAnchors(owner, owner._muiOwnerMap, UI.GetQuestPanelHiddenOffset())
            UI.RefreshQuestLogButtonState()
        end)

        panel._muiSlideIn = slideIn
        panel._muiSlideOut = slideOut
        panel._muiOwnerMap = map
        panel._muiQuestPanelDesiredOpen = false
        panel._muiSuppressSlideInFinish = false
        panel._muiSuppressSlideOutFinish = false
        map._muiQuestLogPanel = panel
        panel:Hide()
    end

    if panel:GetParent() ~= parentTarget then
        panel:SetParent(parentTarget)
    end
    panel._muiOwnerMap = map
    panel:SetFrameStrata(C.QUEST_LOG_PANEL_STRATA)
    panel:SetFrameLevel(map:GetFrameLevel() + 26)
    panel:SetWidth(UI.GetQuestPanelWidth())

    local accentR, accentG, accentB = UI.GetAccentColor()
    if panel._muiAccent and type(panel._muiAccent.SetVertexColor) == "function" then
        panel._muiAccent:SetVertexColor(accentR, accentG, accentB, 1)
    end
    if panel._muiHeaderModeBg and type(panel._muiHeaderModeBg.SetVertexColor) == "function" then
        panel._muiHeaderModeBg:SetVertexColor(accentR, accentG, accentB, 0.22)
    end
    if panel._muiHeaderModeBorder and type(panel._muiHeaderModeBorder.SetVertexColor) == "function" then
        panel._muiHeaderModeBorder:SetVertexColor(accentR, accentG, accentB, 0.52)
    end

    if panel._muiTabsHost and type(panel._muiTabsHost.HookScript) == "function" and not panel._muiTabsLayoutHook then
        panel._muiTabsHost:HookScript("OnSizeChanged", function()
            UI.LayoutQuestPanelTabs(panel)
        end)
        panel._muiTabsLayoutHook = true
    end
    local shouldBeOpen = (Runtime.questLogPanelOpen == true) or (panel._muiQuestPanelDesiredOpen == true)
    if not panel._muiQuestPanelAnimating then
        UI.SetQuestPanelAnchors(panel, map, shouldBeOpen and UI.GetQuestPanelShownOffset() or UI.GetQuestPanelHiddenOffset())
    end
    UI.LayoutQuestPanelTabs(panel)
    return panel
end

function Addon.MapEnsureQuestOverlayMapProxy(host, map)
    if not host then return end
    host._muiQuestProxyMap = map or _G.WorldMapFrame

    if host._muiQuestProxyReady then
        return
    end

    if type(host.GetMap) ~= "function" then
        function host:GetMap()
            return self._muiQuestProxyMap or _G.WorldMapFrame
        end
    end

    if type(host.GetMapID) ~= "function" then
        function host:GetMapID()
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.GetMapID) == "function" then
                return mapFrame:GetMapID()
            end
            return nil
        end
    end

    if type(host.GetFocusedQuestID) ~= "function" then
        function host:GetFocusedQuestID()
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.GetFocusedQuestID) == "function" then
                return mapFrame:GetFocusedQuestID()
            end
            return nil
        end
    end

    if type(host.SetFocusedQuestID) ~= "function" then
        function host:SetFocusedQuestID(...)
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.SetFocusedQuestID) == "function" then
                return mapFrame:SetFocusedQuestID(...)
            end
            return nil
        end
    end

    if type(host.ClearFocusedQuestID) ~= "function" then
        function host:ClearFocusedQuestID(...)
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.ClearFocusedQuestID) == "function" then
                return mapFrame:ClearFocusedQuestID(...)
            end
            return nil
        end
    end

    if type(host.GetHighlightedQuestID) ~= "function" then
        function host:GetHighlightedQuestID()
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.GetHighlightedQuestID) == "function" then
                return mapFrame:GetHighlightedQuestID()
            end
            return self._muiHighlightedQuestID
        end
    end

    if type(host.SetHighlightedQuestID) ~= "function" then
        function host:SetHighlightedQuestID(questID)
            self._muiHighlightedQuestID = questID
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.SetHighlightedQuestID) == "function" then
                return mapFrame:SetHighlightedQuestID(questID)
            end
            return nil
        end
    end

    if type(host.ClearHighlightedQuestID) ~= "function" then
        function host:ClearHighlightedQuestID()
            self._muiHighlightedQuestID = nil
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.ClearHighlightedQuestID) == "function" then
                return mapFrame:ClearHighlightedQuestID()
            end
            return nil
        end
    end

    if type(host.OnQuestLogUpdate) ~= "function" then
        function host:OnQuestLogUpdate(...)
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.OnQuestLogUpdate) == "function" then
                return mapFrame:OnQuestLogUpdate(...)
            end
            return nil
        end
    end

    if type(host.OnMapChanged) ~= "function" then
        function host:OnMapChanged(...)
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.OnMapChanged) == "function" then
                return mapFrame:OnMapChanged(...)
            end
            return nil
        end
    end

    if type(host.RefreshOverlayFrames) ~= "function" then
        function host:RefreshOverlayFrames(...)
            local mapFrame = self:GetMap()
            if mapFrame and type(mapFrame.RefreshOverlayFrames) == "function" then
                return mapFrame:RefreshOverlayFrames(...)
            end
            return nil
        end
    end

    host._muiQuestProxyReady = true
end

function UI.AttachQuestOverlayFrame(panel, map)
    if not panel or not map then return false end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        return panel._muiQuestOverlayFrame ~= nil
    end

    local questFrame = UI.ResolveQuestOverlayFrame(map)
    if not questFrame then return false end
    local host = panel._muiContentInner or panel._muiContentHost
    if not host then return false end

    Addon.MapEnsureQuestOverlayMapProxy(panel, map)
    Addon.MapEnsureQuestOverlayMapProxy(host, map)
    Addon.MapEnsureQuestOverlayMapProxy(questFrame, map)

    -- Parent to the panel host so any transient Blizzard re-anchors are clipped
    -- inside the quest container and do not flash outside on first open.
    if questFrame:GetParent() ~= host then
        questFrame:SetParent(host)
    end
    questFrame:SetFrameStrata(panel:GetFrameStrata())
    questFrame:SetFrameLevel(panel:GetFrameLevel() + 2)
    questFrame:ClearAllPoints()
    questFrame:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    questFrame:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", 0, 0)
    Addon.MapNormalizeQuestOverlayContent(questFrame, panel)
    Addon.MapEnsureQuestOverlayRenderOrder(panel, questFrame)
    Addon.MapEnsureQuestModeFrameVisibility(questFrame, UI.ResolveQuestDisplayModeKey(questFrame, panel), panel)

    UI.SuppressQuestFrameDefaultArtwork(questFrame)
    if type(questFrame.ValidateTabs) == "function" then
        questFrame:ValidateTabs()
    end

    if not questFrame._muiQuestPanelHooks then
        if type(questFrame.HookScript) == "function" then
            questFrame:HookScript("OnShow", function(self)
                local hostFrame = panel and (panel._muiContentInner or panel._muiContentHost) or nil
                if hostFrame then
                    if self:GetParent() ~= hostFrame then
                        self:SetParent(hostFrame)
                    end
                    self:ClearAllPoints()
                    self:SetPoint("TOPLEFT", hostFrame, "TOPLEFT", 0, 0)
                    self:SetPoint("BOTTOMRIGHT", hostFrame, "BOTTOMRIGHT", 0, 0)
                end
                Addon.MapNormalizeQuestOverlayContent(self, panel)
                Addon.MapEnsureQuestOverlayRenderOrder(panel, self)
                Addon.MapEnsureQuestModeFrameVisibility(self, UI.ResolveQuestDisplayModeKey(self, panel), panel)
                UI.SuppressQuestFrameDefaultArtwork(self)
                UI.RefreshQuestPanelTabs(panel)
            end)
        end
        if type(questFrame.SetDisplayMode) == "function" then
            hooksecurefunc(questFrame, "SetDisplayMode", function(self)
                if panel._muiQuestOverlayFrame == self then
                    UI.SuppressQuestFrameDefaultArtwork(self)
                    UI.RefreshQuestPanelTabs(panel)
                end
            end)
        end
        if type(questFrame.ValidateTabs) == "function" then
            hooksecurefunc(questFrame, "ValidateTabs", function(self)
                if panel._muiQuestOverlayFrame == self then
                    UI.SuppressQuestFrameDefaultArtwork(self)
                    UI.RefreshQuestPanelTabs(panel)
                end
            end)
        end
        questFrame._muiQuestPanelHooks = true
    end

    if not Runtime.questDetailsReturnHook and type(hooksecurefunc) == "function"
        and type(_G.QuestMapFrame_ReturnFromQuestDetails) == "function" then
        hooksecurefunc("QuestMapFrame_ReturnFromQuestDetails", function()
            local worldMap = _G.WorldMapFrame
            local worldMapPanel = worldMap and worldMap._muiQuestLogPanel or nil
            if worldMapPanel and worldMapPanel._muiQuestOverlayFrame then
                UI.RestoreQuestListInQuestPanel(worldMapPanel, "QuestMapFrame_ReturnFromQuestDetails")
            end
        end)
        Runtime.questDetailsReturnHook = true
    end
    UI.EnsureQuestDetailsLifecycleHooks(panel, questFrame)

    if not questFrame._muiQuestOverlayLayoutHooks and type(questFrame.HookScript) == "function" then
        questFrame:HookScript("OnShow", function()
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, function()
                    if type(ApplyLayout) == "function" then
                        ApplyLayout("QuestOverlay:OnShow")
                    end
                end)
            elseif type(ApplyLayout) == "function" then
                ApplyLayout("QuestOverlay:OnShow")
            end
        end)
        questFrame:HookScript("OnHide", function()
            Runtime.debug.questTabArtLastMode = nil
            Runtime.debug.questTabArtToken = (Runtime.debug.questTabArtToken or 0) + 1
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, function()
                    if type(ApplyLayout) == "function" then
                        ApplyLayout("QuestOverlay:OnHide")
                    end
                end)
            elseif type(ApplyLayout) == "function" then
                ApplyLayout("QuestOverlay:OnHide")
            end
        end)
        questFrame._muiQuestOverlayLayoutHooks = true
    end
    panel._muiQuestOverlayFrame = questFrame
    UI.RefreshQuestPanelTabs(panel)
    return true
end

-- Quest list event frame for automatic refresh
local QuestListEventFrame = CreateFrame("Frame")
QuestListEventFrame:RegisterEvent("QUEST_LOG_UPDATE")
QuestListEventFrame:RegisterEvent("QUEST_ACCEPTED")
QuestListEventFrame:RegisterEvent("QUEST_REMOVED")
QuestListEventFrame:RegisterEvent("QUEST_TURNED_IN")
QuestListEventFrame:RegisterEvent("QUEST_WATCH_LIST_CHANGED")
QuestListEventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
QuestListEventFrame:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
QuestListEventFrame:RegisterEvent("TASK_PROGRESS_UPDATE")
QuestListEventFrame:RegisterEvent("QUEST_DATA_LOAD_RESULT")
QuestListEventFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
QuestListEventFrame:SetScript("OnEvent", function(self, eventName)
    if not Runtime.questLogPanelOpen then return end
    
    if self._muiDebounceTimer then
        self._muiDebounceTimer:Cancel()
    end
    
    if C_Timer and C_Timer.NewTimer then
        self._muiDebounceTimer = C_Timer.NewTimer(0.15, function()
            self._muiDebounceTimer = nil
            RebuildQuestListLayout()
            local worldMap = _G.WorldMapFrame
            local panel = worldMap and worldMap._muiQuestLogPanel
            if panel and panel._muiQuestDetailsActive and type(UI.RenderQuestDetailsSurface) == "function" then
                UI.RenderQuestDetailsSurface(panel)
            end
        end)
    else
        if not self._muiPendingRefresh then
            self._muiPendingRefresh = true
            C_Timer.After(0.15, function()
                self._muiPendingRefresh = false
                RebuildQuestListLayout()
                local worldMap = _G.WorldMapFrame
                local panel = worldMap and worldMap._muiQuestLogPanel
                if panel and panel._muiQuestDetailsActive and type(UI.RenderQuestDetailsSurface) == "function" then
                    UI.RenderQuestDetailsSurface(panel)
                end
            end)
        end
    end
end)

function UI.ShowQuestLogPanel(map)
    local worldMap = map or _G.WorldMapFrame
    if not worldMap then return false end
    -- Delegate to new quest log panel module
    if Addon.QuestLogPanel and type(Addon.QuestLogPanel.Show) == "function" then
        Addon.QuestLogPanel.Show(worldMap)
        Runtime.questLogPanelOpen = Addon.QuestLogPanel.IsOpen()
        UI.QueueCenteredMapAnchor(worldMap, worldMap:GetParent() or UIParent, "ShowQuestLogPanel")
        UI.RefreshQuestLogButtonState()
        return true
    end
    return false
end

function UI.HideQuestLogPanel(map)
    local worldMap = map or _G.WorldMapFrame
    -- Delegate to new quest log panel module
    if Addon.QuestLogPanel and type(Addon.QuestLogPanel.Hide) == "function" then
        Addon.QuestLogPanel.Hide()
        Runtime.questLogPanelOpen = false
        if worldMap then
            UI.QueueCenteredMapAnchor(worldMap, worldMap:GetParent() or UIParent, "HideQuestLogPanel")
        end
        UI.RefreshQuestLogButtonState()
    end
    return true
end

function UI.QueueQuestLogOverlayToggle()
    Runtime.pendingQuestLogToggle = not (Runtime.pendingQuestLogToggle == true)
end

function UI.RequestQuestLogOverlay()
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        UI.QueueQuestLogOverlayToggle()
        return
    end

    Runtime.pendingQuestLogToggle = false
    local map = _G.WorldMapFrame
    if not map or not map.IsShown or not map:IsShown() then
        return
    end

    if Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function" and Addon.QuestLogPanel.IsOpen() then
        UI.HideQuestLogPanel(map)
    else
        UI.ShowQuestLogPanel(map)
    end
end

function UI.ToggleWorldMapPaneCompatFromQuestLogBinding()
    local map = _G.WorldMapFrame
    local mapShown = map and map.IsShown and map:IsShown() or false

    -- If the map is already open, close both the quest panel and the map.
    if mapShown then
        if Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function" and Addon.QuestLogPanel.IsOpen() then
            UI.HideQuestLogPanel(map)
        end
        if map.HandleUserActionToggleSelf then
            pcall(map.HandleUserActionToggleSelf, map)
        elseif map.Close then
            pcall(map.Close, map)
        elseif map.Hide then
            pcall(map.Hide, map)
        end
        return true
    end

    -- Map is closed — open it and show the quest panel.
    local openedMap = false
    if type(_G.ToggleWorldMap) == "function" then
        local ok = pcall(_G.ToggleWorldMap)
        openedMap = (ok == true)
    elseif map and type(_G.ToggleFrame) == "function" then
        local ok = pcall(_G.ToggleFrame, map)
        openedMap = (ok == true)
    end
    if not openedMap then
        return false
    end

    map = _G.WorldMapFrame
    local isShown = map and map.IsShown and map:IsShown() or false
    if not isShown then
        return false
    end

    ApplyLayout("ToggleQuestLogCompat")
    UI.QueueQuestPanelAnchorSettle(map, "ToggleQuestLogCompat")
    if Runtime.questLogPanelOpen then
        UI.RefreshQuestLogButtonState()
        return true
    end

    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        Runtime.pendingQuestLogToggle = true
        return true
    end

    local opened = UI.ShowQuestLogPanel(map)
    return true
end

function UI.InstallQuestLogToggleCompat()
    if Runtime.questLogCompatInstalled then return end
    if type(_G.ToggleQuestLog) ~= "function" then return end

    Runtime.questLogCompatOriginal = Runtime.questLogCompatOriginal or _G.ToggleQuestLog
    local originalToggleQuestLog = Runtime.questLogCompatOriginal

    -- Keep the binding command name (TOGGLEQUESTLOG) but route behavior to
    -- an "open map + open quest panel" flow when custom map mode is active.
    _G.ToggleQuestLog = function(...)
        if Runtime.questLogCompatGuard then
            return originalToggleQuestLog(...)
        end

        if Util.IsCustomQuestingInterfaceEnabled() then
            Runtime.questLogCompatGuard = true
            local handled = UI.ToggleWorldMapPaneCompatFromQuestLogBinding()
            Runtime.questLogCompatGuard = false
            if handled then
                return
            end
        end
        return originalToggleQuestLog(...)
    end

    Runtime.questLogCompatInstalled = true
end

function UI.SyncQuestLogPanelLayout(map)
    if not map then return end

    -- Delegate to new quest log panel module when present
    if Addon.QuestLogPanel and type(Addon.QuestLogPanel.EnsurePanel) == "function" then
        local shouldBeOpen = (Runtime.questLogPanelOpen == true)
        if shouldBeOpen then
            if not Addon.QuestLogPanel.IsOpen() then
                UI.ShowQuestLogPanel(map)
            else
                Addon.QuestLogPanel.Rebuild()
            end
        end
        UI.QueueCenteredMapAnchor(map, map:GetParent() or UIParent, "SyncQuestLogPanelLayout")
        UI.QueueQuestPanelAnchorSettle(map, "SyncQuestLogPanelLayout")
        UI.RefreshQuestLogButtonState()
        return
    end

    local panel = UI.EnsureQuestLogOverlayPanel(map)
    if not panel or panel._muiQuestPanelAnimating then return end

    local shouldBeOpen = (Runtime.questLogPanelOpen == true) or (panel._muiQuestPanelDesiredOpen == true)
    if shouldBeOpen then
        UI.AttachQuestOverlayFrame(panel, map)
        UI.SetQuestPanelAnchors(panel, map, UI.GetQuestPanelShownOffset())
        panel:Show()
        RebuildQuestListLayout()
        local questFrame = panel._muiQuestOverlayFrame
        if questFrame then
            local activeMode = UI.ResolveQuestDisplayModeKey(questFrame, panel)
            UI.SetQuestPanelDisplayMode(panel, activeMode)
        end
    else
        UI.SetQuestPanelAnchors(panel, map, UI.GetQuestPanelHiddenOffset())
        UI.ClearQuestPanelDetailsState(panel, "SyncQuestLogPanelLayout:hidden")
        panel:Hide()
        if panel._muiQuestOverlayFrame and type(panel._muiQuestOverlayFrame.Hide) == "function" then
            panel._muiQuestOverlayFrame:Hide()
        end
    end
    UI.QueueCenteredMapAnchor(map, map:GetParent() or UIParent, "SyncQuestLogPanelLayout")
    UI.QueueQuestPanelAnchorSettle(map, "SyncQuestLogPanelLayout")
    UI.RefreshQuestLogButtonState()
end

function UI.ApplyFactionButtonColor(button, isHovered)
    if not button or not button.Icon then return end
    local r, g, b = C.GetThemeColor("textPrimary")
    if isHovered then
        r, g, b = UI.GetAccentColor()
    end

    if type(button.Icon.Show) == "function" then
        button.Icon:Show()
    end
    if type(button.Icon.SetAlpha) == "function" then
        button.Icon:SetAlpha(1)
    end
    if type(button.Icon.SetVertexColor) == "function" then
        button.Icon:SetVertexColor(r, g, b, 1)
    end
end

function UI.ApplyFactionButtonAtlas(button)
    if not button then return end
    if button.Background then
        button.Background:SetSize(16, 16)
        button.Background:ClearAllPoints()
        button.Background:SetPoint("CENTER", button, "CENTER", 0, 0)
    end
    if not button.Icon then return end

    if type(button.Icon.SetAtlas) == "function" then
        button.Icon:SetAtlas(C.FACTION_ICON_ATLAS, false)
    end
    button.Icon:SetSize(C.FACTION_ICON_WIDTH, C.FACTION_ICON_HEIGHT)
    button.Icon:ClearAllPoints()
    button.Icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    if type(button.Icon.SetDrawLayer) == "function" then
        button.Icon:SetDrawLayer("OVERLAY", 6)
    end
end

function UI.SuppressFactionDropdownArt(button)
    if not button or not button.BountyDropdown then return end
    local dropdown = button.BountyDropdown

    UI.HideTexture(dropdown.Background)
    UI.HideTexture(dropdown.Arrow)
    UI.HideTexture(dropdown.Icon)
    UI.HideTexture(dropdown.IconBorder)

    UI.HideTextureRegions(dropdown)

    if type(dropdown.GetChildren) == "function" then
        for _, child in ipairs({ dropdown:GetChildren() }) do
            if child and type(child.GetObjectType) == "function" then
                local objectType = child:GetObjectType()
                if objectType == "Button" then
                    local normalTexture = type(child.GetNormalTexture) == "function" and child:GetNormalTexture() or nil
                    local pushedTexture = type(child.GetPushedTexture) == "function" and child:GetPushedTexture() or nil
                    local highlightTexture = type(child.GetHighlightTexture) == "function" and child:GetHighlightTexture() or nil
                    UI.HideTexture(normalTexture)
                    UI.HideTexture(pushedTexture)
                    UI.HideTexture(highlightTexture)
                    UI.HideTextureRegions(child)
                elseif objectType == "Texture" then
                    UI.HideTexture(child)
                elseif objectType == "Frame" then
                    UI.HideTextureRegions(child)
                end
            end
        end
    end
end

function UI.ClickFactionDropdown(button)
    if not button or not button.BountyDropdown then return end
    local dropdown = button.BountyDropdown

    local function TryCall(target, methodName)
        if not target then return false end
        local method = target[methodName]
        if type(method) ~= "function" then return false end
        method(target)
        return true
    end

    -- Prefer native dropdown methods before synthetic child clicks.
    if TryCall(dropdown, "OpenMenu") then return end
    if TryCall(dropdown, "ToggleMenu") then return end
    if TryCall(dropdown, "ShowMenu") then return end
    if type(dropdown.RefreshMenu) == "function" and type(dropdown.SetupMenu) == "function" then
        dropdown:RefreshMenu()
        if TryCall(dropdown, "OpenMenu") then return end
    end

    local function TryClick(target)
        if not target or type(target.Click) ~= "function" then return false end
        if type(target.IsEnabled) == "function" and not target:IsEnabled() then return false end
        target:Click()
        return true
    end

    if TryClick(dropdown.DropDownButton) then return end
    if TryClick(dropdown.ArrowButton) then return end
    if TryClick(dropdown.Button) then return end

    if type(dropdown.GetChildren) == "function" then
        for _, child in ipairs({ dropdown:GetChildren() }) do
            if child and type(child.GetObjectType) == "function" and child:GetObjectType() == "Button" then
                if TryClick(child) then return end
            end
        end
    end

    TryClick(dropdown)
end

-- ============================================================================
-- UNIFIED MIDNIGHT HEADER STRUCTURAL OVERHAUL
-- ============================================================================
function UI.EnsureHeaderLayout(map)
    if Runtime.layout and Runtime.layout.root and Runtime.layout.owner == map then
        return Runtime.layout
    end

    local r, g, b = UI.GetAccentColor()

    local root = CreateFrame("Frame", nil, map)
    root:SetFrameStrata("HIGH")
    root:SetFrameLevel(map:GetFrameLevel() + 140)
    root:EnableMouse(false)

    -- Primary Background (Clean, completely unified, flat dark panel)
    local rootBg = root:CreateTexture(nil, "BACKGROUND", nil, -5)
    rootBg:SetAllPoints()
    rootBg:SetTexture(C.WHITE8X8)
    local headerBgR, headerBgG, headerBgB = C.GetThemeColor("bgPanel")
    rootBg:SetVertexColor(headerBgR, headerBgG, headerBgB, 0.96)

    -- Top Edge Accent (2px, matching quest log panel top line)
    local borderTop = root:CreateTexture(nil, "BORDER")
    borderTop:SetPoint("TOPLEFT")
    borderTop:SetPoint("TOPRIGHT")
    borderTop:SetHeight(2)
    borderTop:SetTexture(C.WHITE8X8)
    borderTop:SetVertexColor(r, g, b, 0.85)

    -- Keep the bottom shading inside the header so it does not intrude into the map canvas.
    local dropShadow = root:CreateTexture(nil, "BACKGROUND", nil, -6)
    dropShadow:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
    dropShadow:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", 0, 0)
    dropShadow:SetHeight(8)
    dropShadow:SetTexture(C.WHITE8X8)
    UI.SetVerticalGradient(dropShadow, 0, 0, 0, 0, 0, 0, 0, 0.28)

    -- Top Row (Title Area)
    local topRow = CreateFrame("Frame", nil, root)
    topRow:SetPoint("TOPLEFT")
    topRow:SetPoint("TOPRIGHT")
    topRow:SetHeight(C.HEADER_TOP_HEIGHT)

    -- Left Accent Bar (Visual flair)
    local titleTag = topRow:CreateTexture(nil, "ARTWORK")
    titleTag:SetPoint("LEFT", topRow, "LEFT", C.HEADER_HORIZONTAL_PADDING, 0)
    titleTag:SetSize(4, 18)
    titleTag:SetTexture(C.WHITE8X8)
    local accentMidR, accentMidG, accentMidB = C.GetThemeColor("accentMid")
    titleTag:SetVertexColor(accentMidR, accentMidG, accentMidB, 0.86)

    local title = topRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", titleTag, "RIGHT", 10, 0)
    local titleTextR, titleTextG, titleTextB = C.GetThemeColor("textPrimary")
    title:SetTextColor(titleTextR, titleTextG, titleTextB, 1)
    title:SetText(WORLD_MAP)

    local mapNameDivider = topRow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mapNameDivider:SetPoint("LEFT", title, "RIGHT", 10, 0)
    local dividerTextR, dividerTextG, dividerTextB = C.GetThemeColor("textMuted")
    mapNameDivider:SetTextColor(dividerTextR, dividerTextG, dividerTextB, 1)
    mapNameDivider:SetText(">")

    local mapName = topRow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mapName:SetPoint("LEFT", mapNameDivider, "RIGHT", 10, 0)
    local mapNameR, mapNameG, mapNameB = C.GetThemeColor("textSecondary")
    mapName:SetTextColor(mapNameR, mapNameG, mapNameB, 1)
    mapName:SetText("")

    -- Divider between TopRow and NavRow
    local laneDivider = root:CreateTexture(nil, "BORDER")
    laneDivider:SetPoint("BOTTOMLEFT", topRow, "BOTTOMLEFT", C.HEADER_HORIZONTAL_PADDING, 0)
    laneDivider:SetPoint("BOTTOMRIGHT", topRow, "BOTTOMRIGHT", -C.HEADER_HORIZONTAL_PADDING, 0)
    laneDivider:SetHeight(1)
    laneDivider:SetTexture(C.WHITE8X8)
    local laneDividerR, laneDividerG, laneDividerB = C.GetThemeColor("border")
    laneDivider:SetVertexColor(laneDividerR, laneDividerG, laneDividerB, 0.45)

    -- Nav Row
    local navRow = CreateFrame("Frame", nil, root)
    navRow:SetPoint("TOPLEFT", topRow, "BOTTOMLEFT", 0, 0)
    navRow:SetPoint("TOPRIGHT", topRow, "BOTTOMRIGHT", 0, 0)
    navRow:SetHeight(C.HEADER_NAV_HEIGHT)

    local controlsHost = CreateFrame("Frame", nil, navRow)
    controlsHost:SetPoint("TOPRIGHT", navRow, "TOPRIGHT", -C.HEADER_HORIZONTAL_PADDING, 0)
    controlsHost:SetPoint("BOTTOMRIGHT", navRow, "BOTTOMRIGHT", -C.HEADER_HORIZONTAL_PADDING, 0)
    controlsHost:SetWidth(1)

    local navHost = CreateFrame("Frame", nil, navRow)
    navHost:SetPoint("TOPLEFT", navRow, "TOPLEFT", C.HEADER_HORIZONTAL_PADDING, 0)
    navHost:SetPoint("BOTTOMLEFT", navRow, "BOTTOMLEFT", C.HEADER_HORIZONTAL_PADDING, 0)
    navHost:SetPoint("RIGHT", controlsHost, "LEFT", -C.HEADER_HORIZONTAL_PADDING, 0)

    Runtime.layout = {
        owner = map,
        root = root,
        topRow = topRow,
        title = title,
        mapName = mapName,
        navRow = navRow,
        navHost = navHost,
        controlsHost = controlsHost,
    }

    return Runtime.layout
end

function UI.AnchorHeaderToCanvas(map, layout, reason)
    if not map or not layout or not layout.root then return end

    local spacerHeight = C.HEADER_TOP_HEIGHT + C.HEADER_NAV_HEIGHT
    local scroll = map.ScrollContainer

    -- Anchor header to the map frame itself, not the scroll container.
    -- This decouples the header from scroll container size changes (zoom,
    -- Blizzard reflows) so it never flickers or jumps during layout.
    local root = layout.root
    local needsReanchor = true
    if root:GetNumPoints() == 2 then
        local pt1, rel1, relPt1, x1, y1 = root:GetPoint(1)
        local pt2, rel2, relPt2, x2, y2 = root:GetPoint(2)
        if pt1 == "TOPLEFT" and rel1 == map and relPt1 == "TOPLEFT"
            and pt2 == "TOPRIGHT" and rel2 == map and relPt2 == "TOPRIGHT"
            and math.abs(x1 or 0) < 0.5 and math.abs(y1 or 0) < 0.5
            and math.abs(x2 or 0) < 0.5 and math.abs(y2 or 0) < 0.5 then
            needsReanchor = false
        end
    end
    if needsReanchor then
        root:ClearAllPoints()
        root:SetPoint("TOPLEFT", map, "TOPLEFT", 0, 0)
        root:SetPoint("TOPRIGHT", map, "TOPRIGHT", 0, 0)
    end
    root:SetHeight(spacerHeight)

    -- Canvas BG still tracks the scroll container since it fills the map area
    if scroll then
        local bg = map._muiCanvasBg
        if bg then
            bg:ClearAllPoints()
            bg:SetPoint("TOPLEFT", scroll, "TOPLEFT", 0, 0)
            bg:SetPoint("BOTTOMRIGHT", scroll, "BOTTOMRIGHT", 0, 0)
        end
    end

    if Util.IsMapNavDebugWatchEnabled() then
        Runtime.debug.anchorAuditSeq = (Runtime.debug.anchorAuditSeq or 0) + 1
    end
end

-- ============================================================================
-- SMOOTH CINEMATIC MAP TRANSITIONS (Subtle & Easy on the eyes)
-- ============================================================================

function UI.SmoothFadeCanvas()
    local map = _G.WorldMapFrame
    if not map or not map.ScrollContainer then return end
    
    local canvas = map.ScrollContainer.Child or map.ScrollContainer
    if not canvas then return end

    if type(UIFrameFadeRemoveFrame) == "function" then
        pcall(UIFrameFadeRemoveFrame, canvas)
    end

    -- Drop alpha instantly to hide the structural size "snap"
    canvas:SetAlpha(0.0)

    -- Fade back in gracefully over a short duration
    if type(UIFrameFade) == "function" then
        UIFrameFade(canvas, {
            mode = "IN",
            timeToFade = C.MAP_TRANSITION_FADE_DUR,
            startAlpha = 0.0,
            endAlpha = 1.0,
        })
    else
        canvas:SetAlpha(1.0)
    end
end

function UI.UpdateHeaderTitle(map)
    local layout = Runtime.layout
    if not layout then return end
    local mapNameText = WORLD_MAP
    if map and type(map.GetMapID) == "function" then
        local mapID = map:GetMapID()
        if mapID and C_Map and C_Map.GetMapInfo then
            local info = C_Map.GetMapInfo(mapID)
            if info and info.name then mapNameText = info.name end
        end
    end
    layout.mapName:SetText(mapNameText or WORLD_MAP)
end

-- ============================================================================
-- CONTROL STYLING
-- ============================================================================
function UI.StyleFloorDropdown(dropdown, desiredWidth)
    if not dropdown then return end
    local width = Util.Clamp(desiredWidth or C.FLOOR_DROPDOWN_WIDTH, C.FLOOR_DROPDOWN_MIN_WIDTH, C.FLOOR_DROPDOWN_MAX_WIDTH)
    dropdown:SetSize(width, C.CONTROL_BUTTON_SIZE)
    UI.HideTexture(dropdown.Background)
    UI.SuppressControlHighlight(dropdown)
    UI.SuppressButtonArt(dropdown.DropDownButton)
    UI.SuppressButtonArt(dropdown.ArrowButton)
    UI.SuppressButtonArt(dropdown.Button)

    if dropdown.Arrow then
        UI.EnforceArrowButtonArt(dropdown.Arrow, dropdown.Arrow.Art)
        UI.QueueArrowButtonArtRefresh(dropdown.Arrow, dropdown.Arrow.Art)
        if dropdown.Arrow.SetTexture then
            UI.HideTexture(dropdown.Arrow)
        elseif type(dropdown.Arrow.GetRegions) == "function" then
            UI.HideFrameRegions(dropdown.Arrow)
        end
        if not dropdown.Arrow._muiMapArrowArtHooks and dropdown.Arrow.HookScript then
            dropdown.Arrow:HookScript("OnShow", function(self)
                UI.EnforceArrowButtonArt(self, self.Art)
                UI.QueueArrowButtonArtRefresh(self, self.Art)
            end)
            dropdown.Arrow:HookScript("OnEnter", function(self)
                UI.EnforceArrowButtonArt(self, self.Art)
            end)
            dropdown.Arrow._muiMapArrowArtHooks = true
        end
        if dropdown.Arrow.Art and not dropdown.Arrow.Art._muiMapHideHook and type(dropdown.Arrow.Art.HookScript) == "function" then
            dropdown.Arrow.Art._muiMapHideHook = true
            dropdown.Arrow.Art:HookScript("OnShow", function(self) self:Hide() end)
        end
    end
    if dropdown.Icon then
        UI.HideTexture(dropdown.Icon)
    end

    if dropdown.Text then
        dropdown.Text:SetFontObject(GameFontHighlightSmall)
        dropdown.Text:SetJustifyH("LEFT")
        local textR, textG, textB = C.GetThemeColor("textPrimary")
        dropdown.Text:SetTextColor(textR, textG, textB, 1)
        dropdown.Text:ClearAllPoints()
        dropdown.Text:SetPoint("LEFT", dropdown, "LEFT", 10, 0)
        dropdown.Text:SetPoint("RIGHT", dropdown, "RIGHT", -24, 0)
    end

    local customArrow = UI.EnsureDropdownArrow(dropdown)
    if customArrow then
        local r, g, b = UI.GetAccentColor()
        if customArrow.left then customArrow.left:SetVertexColor(r, g, b, 0.95) end
        if customArrow.right then customArrow.right:SetVertexColor(r, g, b, 0.95) end
        customArrow:ClearAllPoints()
        customArrow:SetPoint("RIGHT", dropdown, "RIGHT", -9, 0)
        customArrow:Show()
    end
    UI.EnsureControlChrome(dropdown)
end

function UI.ShowQuestLogButtonTooltip(button)
    if not button or not _G.GameTooltip or type(_G.GameTooltip.SetOwner) ~= "function" then return end
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT", 0, 8)
    local titleR, titleG, titleB = C.GetThemeColor("textPrimary")
    tooltip:SetText(_G.QUEST_LOG or "Quest Log", titleR, titleG, titleB)

    local bindingKey = type(_G.GetBindingKey) == "function" and _G.GetBindingKey("TOGGLEQUESTLOG") or nil
    if bindingKey and type(_G.GetBindingText) == "function" then
        local bindingLabel = _G.GetBindingText(bindingKey, "KEY_")
        if type(bindingLabel) == "string" and bindingLabel ~= "" then
            local keyBindingLabel = _G.KEY_BINDING or "Key Binding"
            local tipR, tipG, tipB = C.GetThemeColor("textSecondary")
            tooltip:AddLine(keyBindingLabel .. ": " .. bindingLabel, tipR, tipG, tipB, true)
        end
    end
    tooltip:Show()
end

function UI.ShowFactionButtonTooltip(button)
    if not button or not _G.GameTooltip or type(_G.GameTooltip.SetOwner) ~= "function" then return end
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT", 0, 8)
    local titleR, titleG, titleB = C.GetThemeColor("textPrimary")
    local bodyR, bodyG, bodyB = C.GetThemeColor("textSecondary")
    local mutedR, mutedG, mutedB = C.GetThemeColor("textMuted")

    local titleText = (type(button.tooltipText) == "string" and button.tooltipText ~= "" and button.tooltipText)
        or (_G.TRACKING or "Tracking")
    tooltip:SetText(titleText, titleR, titleG, titleB)

    local factionNames = {}
    local seenNames = {}
    local function AddFactionName(value)
        if type(value) ~= "string" then return end
        local name = value:gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" or seenNames[name] then return end
        seenNames[name] = true
        factionNames[#factionNames + 1] = name
    end

    local dropdown = button.BountyDropdown
    if dropdown and dropdown.Text and type(dropdown.Text.GetText) == "function" then
        AddFactionName(dropdown.Text:GetText())
    end

    if type(C_MajorFactions) == "table"
        and type(C_MajorFactions.GetMajorFactionIDs) == "function"
        and type(C_MajorFactions.GetMajorFactionData) == "function" then
        local okIDs, factionIDs = pcall(C_MajorFactions.GetMajorFactionIDs)
        if okIDs and type(factionIDs) == "table" then
            for i = 1, #factionIDs do
                local okData, factionData = pcall(C_MajorFactions.GetMajorFactionData, factionIDs[i])
                if okData and type(factionData) == "table" then
                    AddFactionName(factionData.name)
                end
            end
        end
    end

    if #factionNames == 0 then
        AddFactionName("Council of Dornogal")
        AddFactionName("Hallowfall Arathi")
        AddFactionName("The Assembly of the Deeps")
        AddFactionName("The Severed Threads")
    end

    if #factionNames > 0 then
        tooltip:AddLine(_G.FACTION or "Factions", bodyR, bodyG, bodyB, true)
        local maxLines = math.min(#factionNames, 6)
        for i = 1, maxLines do
            tooltip:AddLine("- " .. factionNames[i], bodyR, bodyG, bodyB, true)
        end
        if #factionNames > maxLines then
            tooltip:AddLine("+" .. tostring(#factionNames - maxLines) .. " more", mutedR, mutedG, mutedB, true)
        end
    end

    tooltip:AddLine("Left click: open faction/activity menu", bodyR, bodyG, bodyB, true)
    tooltip:Show()
end

function UI.StyleQuestLogButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    if type(button.EnableMouse) == "function" then
        button:EnableMouse(true)
    end
    UI.SuppressControlHighlight(button)
    UI.HideTexture(button:GetNormalTexture())
    UI.HideTexture(button:GetPushedTexture())
    UI.HideTexture(button:GetHighlightTexture())

    if button.Icon then
        button.Icon:SetTexture(C.QUEST_LOG_ICON_TEXTURE)
        button.Icon:SetTexCoord(0, 1, 0, 1)
        button.Icon:SetSize(16, 16)
        button.Icon:ClearAllPoints()
        button.Icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        if type(button.Icon.SetDrawLayer) == "function" then
            button.Icon:SetDrawLayer("OVERLAY", 6)
        end
    end

    UI.EnsureControlChrome(button)
    UI.EnsureControlIconHooks(button)
    UI.ApplyControlIconColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
    UI.RefreshQuestLogButtonState()
end

function UI.EnsureQuestLogButton(map)
    if not map then return nil end

    local button = map._muiQuestLogButton
    if not button then
        button = CreateFrame("Button", nil, map)
        button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
        button:RegisterForClicks("LeftButtonUp")

        local icon = button:CreateTexture(nil, "OVERLAY", nil, 6)
        icon:SetSize(16, 16)
        icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.Icon = icon

        button:SetScript("OnClick", function()
            UI.RequestQuestLogOverlay()
        end)

        if type(button.HookScript) == "function" then
            button:HookScript("OnEnter", function(self)
                UI.ShowQuestLogButtonTooltip(self)
            end)
            button:HookScript("OnLeave", function()
                if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                    _G.GameTooltip:Hide()
                end
            end)
        end

        map._muiQuestLogButton = button
    elseif button:GetParent() ~= map then
        button:SetParent(map)
    end

    button:Show()
    UI.StyleQuestLogButton(button)
    return button
end

function UI.GetMapAnnotationStore()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    local settings = _G.MidnightUISettings
    settings.Map = settings.Map or {}
    settings.Map.annotations = settings.Map.annotations or {
        nextId = 1,
        entries = {},
    }

    local store = settings.Map.annotations
    if type(store.entries) ~= "table" then
        store.entries = {}
    end
    if type(store.nextId) ~= "number" or store.nextId < 1 then
        store.nextId = 1
    end
    return store
end

function UI.GetMapAnnotationDefaultColor()
    return 0.98, 0.82, 0.24, 0.42
end

function UI.GetActiveMapID(map)
    if map and type(map.GetMapID) == "function" then
        local mapID = map:GetMapID()
        if type(mapID) == "number" and mapID > 0 then
            return mapID
        end
    end
    if type(C_Map) == "table" and type(C_Map.GetBestMapForUnit) == "function" then
        local mapID = C_Map.GetBestMapForUnit("player")
        if type(mapID) == "number" and mapID > 0 then
            return mapID
        end
    end
    return nil
end

function UI.CopyMapAnnotationPoints(points)
    local out = {}
    if type(points) ~= "table" then return out end
    for i = 1, #points do
        local p = points[i]
        if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
            out[#out + 1] = {
                x = Util.Clamp(p.x, 0, 1),
                y = Util.Clamp(p.y, 0, 1),
            }
        end
    end
    return out
end

function UI.ComputeMapAnnotationCentroid(points)
    if type(points) ~= "table" or #points == 0 then
        return 0.5, 0.5
    end
    local sx, sy = 0, 0
    for i = 1, #points do
        local p = points[i]
        sx = sx + (p.x or 0)
        sy = sy + (p.y or 0)
    end
    return Util.Clamp(sx / #points, 0, 1), Util.Clamp(sy / #points, 0, 1)
end

function UI.AcquireMapAnnotationLine(layer, parent)
    if not layer or not parent or type(parent.CreateLine) ~= "function" then return nil end
    layer._muiLinePool = layer._muiLinePool or {}
    layer._muiActiveLines = layer._muiActiveLines or {}

    local line = table.remove(layer._muiLinePool)
    if not line then
        line = parent:CreateLine(nil, "ARTWORK", nil, 3)
        line:SetThickness(4)
    end
    line:Show()
    layer._muiActiveLines[#layer._muiActiveLines + 1] = line
    return line
end

function UI.AcquireMapAnnotationDot(layer, parent)
    if not layer or not parent then return nil end
    layer._muiDotPool = layer._muiDotPool or {}
    layer._muiActiveDots = layer._muiActiveDots or {}

    local dot = table.remove(layer._muiDotPool)
    if not dot then
        dot = parent:CreateTexture(nil, "ARTWORK", nil, 4)
        dot:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
    end
    dot:Show()
    layer._muiActiveDots[#layer._muiActiveDots + 1] = dot
    return dot
end

function UI.AcquireMapAnnotationStrokeTexture(layer, parent)
    if not layer or not parent then return nil end
    layer._muiStrokePool = layer._muiStrokePool or {}
    layer._muiActiveStrokes = layer._muiActiveStrokes or {}

    local stroke = table.remove(layer._muiStrokePool)
    if not stroke then
        stroke = parent:CreateTexture(nil, "OVERLAY", nil, 5)
        stroke:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
        if type(stroke.SetBlendMode) == "function" then
            stroke:SetBlendMode("BLEND")
        end
    end

    stroke:Show()
    layer._muiActiveStrokes[#layer._muiActiveStrokes + 1] = stroke
    return stroke
end

function UI.DrawMapAnnotationStrokeFallback(layer, host, p1, p2, r, g, b, a, thickness)
    if not layer or not host or not p1 or not p2 then return end
    local width = host:GetWidth()
    local height = host:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 1 or height <= 1 then return end

    local x1 = (p1.x or 0) * width
    local y1 = (p1.y or 0) * height
    local x2 = (p2.x or 0) * width
    local y2 = (p2.y or 0) * height
    local dx = x2 - x1
    local dy = y2 - y1
    local segLen = math.sqrt((dx * dx) + (dy * dy))
    if segLen < 0.20 then return end

    local stroke = UI.AcquireMapAnnotationStrokeTexture(layer, host)
    if not stroke then return end

    if type(stroke.SetBlendMode) == "function" then
        pcall(stroke.SetBlendMode, stroke, "BLEND")
    end
    if type(stroke.SetSnapToPixelGrid) == "function" then
        pcall(stroke.SetSnapToPixelGrid, stroke, false)
    end
    if type(stroke.SetTexelSnappingBias) == "function" then
        pcall(stroke.SetTexelSnappingBias, stroke, 0)
    end

    local lineThickness = type(thickness) == "number" and thickness or 2
    if lineThickness < 1 then lineThickness = 1 end
    local alpha = math.min(0.96, (type(a) == "number" and a or 0.42) + 0.34)
    stroke:ClearAllPoints()
    stroke:SetSize(segLen, lineThickness + 1)
    stroke:SetPoint("CENTER", host, "TOPLEFT", (x1 + x2) * 0.5, -((y1 + y2) * 0.5))
    if type(stroke.SetRotation) == "function" then
        stroke:SetRotation(math.atan2(-dy, dx))
    end
    stroke:SetVertexColor(r, g, b, alpha)
end

function UI.AcquireMapAnnotationHitButton(layer, parent)
    if not layer or not parent then return nil end
    layer._muiHitButtonPool = layer._muiHitButtonPool or {}
    layer._muiActiveHitButtons = layer._muiActiveHitButtons or {}

    local button = table.remove(layer._muiHitButtonPool)
    if not button then
        button = CreateFrame("Button", nil, parent)
        button:EnableMouse(true)
        button:RegisterForClicks("RightButtonUp", "LeftButtonUp")
        local icon = button:CreateTexture(nil, "ARTWORK", nil, 6)
        icon:SetSize(33, 33)
        icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        if type(icon.SetAtlas) == "function" then
            pcall(icon.SetAtlas, icon, "CovenantSanctum-Resevoir-Full-Kyrian")
        end
        icon:Hide()
        button._muiPointIcon = icon
        button:SetScript("OnClick", function(self, mouseButton)
            Util.MapAnnotationInputLog(
                "hitButton:click",
                string.format(
                    "mouse=%s hasNote=%s noteId=%s",
                    Util.SafeToString(mouseButton),
                    Util.SafeToString(self._muiAnnotationNote ~= nil),
                    Util.SafeToString(self._muiAnnotationNote and self._muiAnnotationNote.id)
                ),
                true
            )
            if mouseButton ~= "RightButton" then return end
            if self._muiAnnotationNote then
                Util.MapAnnotationInputLog("hitButton:menu", "invokingContextMenu=true", true)
                UI.ShowMapAnnotationContextMenu(self, self._muiAnnotationNote)
            else
                Util.MapAnnotationInputLog("hitButton:menu", "invokingContextMenu=false reason=noNote", true)
            end
        end)
        button:SetScript("OnEnter", function(self)
            if self._muiAnnotationNote then
                UI.ShowMapAnnotationTooltip(self, self._muiAnnotationNote)
            end
        end)
        button:SetScript("OnLeave", function()
            if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                _G.GameTooltip:Hide()
            end
        end)
    end
    if button._muiPointIcon then
        button._muiPointIcon:Hide()
    end
    button:Show()
    layer._muiActiveHitButtons[#layer._muiActiveHitButtons + 1] = button
    return button
end

function UI.ReleaseMapAnnotationVisuals(layer)
    if not layer then return end
    local beforeLines = (type(layer._muiActiveLines) == "table") and #layer._muiActiveLines or 0
    local beforeDots = (type(layer._muiActiveDots) == "table") and #layer._muiActiveDots or 0
    local beforeHits = (type(layer._muiActiveHitButtons) == "table") and #layer._muiActiveHitButtons or 0
    local beforeStrokes = (type(layer._muiActiveStrokes) == "table") and #layer._muiActiveStrokes or 0

    if type(layer._muiActiveLines) == "table" then
        for i = 1, #layer._muiActiveLines do
            local line = layer._muiActiveLines[i]
            if line then
                line:Hide()
                line:ClearAllPoints()
                layer._muiLinePool = layer._muiLinePool or {}
                layer._muiLinePool[#layer._muiLinePool + 1] = line
                layer._muiActiveLines[i] = nil
            end
        end
    end

    if type(layer._muiActiveDots) == "table" then
        for i = 1, #layer._muiActiveDots do
            local dot = layer._muiActiveDots[i]
            if dot then
                dot:Hide()
                dot:ClearAllPoints()
                layer._muiDotPool = layer._muiDotPool or {}
                layer._muiDotPool[#layer._muiDotPool + 1] = dot
                layer._muiActiveDots[i] = nil
            end
        end
    end

    if type(layer._muiActiveHitButtons) == "table" then
        for i = 1, #layer._muiActiveHitButtons do
            local button = layer._muiActiveHitButtons[i]
            if button then
                button:Hide()
                button:ClearAllPoints()
                button._muiAnnotationNote = nil
                layer._muiHitButtonPool = layer._muiHitButtonPool or {}
                layer._muiHitButtonPool[#layer._muiHitButtonPool + 1] = button
                layer._muiActiveHitButtons[i] = nil
            end
        end
    end

    if type(layer._muiActiveStrokes) == "table" then
        for i = 1, #layer._muiActiveStrokes do
            local stroke = layer._muiActiveStrokes[i]
            if stroke then
                stroke:Hide()
                stroke:ClearAllPoints()
                if type(stroke.SetRotation) == "function" then
                    stroke:SetRotation(0)
                end
                layer._muiStrokePool = layer._muiStrokePool or {}
                layer._muiStrokePool[#layer._muiStrokePool + 1] = stroke
                layer._muiActiveStrokes[i] = nil
            end
        end
    end

    if (beforeLines + beforeDots + beforeHits + beforeStrokes) > 0 and Util.ShouldEmitDebugToken("mapNoteRender:releaseVisuals", 0.06) then
        Util.MapAnnotationRenderLog(
            "releaseVisuals",
            string.format("before lines=%s dots=%s hits=%s strokes=%s pools lines=%s dots=%s hits=%s strokes=%s",
                Util.SafeToString(beforeLines),
                Util.SafeToString(beforeDots),
                Util.SafeToString(beforeHits),
                Util.SafeToString(beforeStrokes),
                Util.SafeToString(type(layer._muiLinePool) == "table" and #layer._muiLinePool or 0),
                Util.SafeToString(type(layer._muiDotPool) == "table" and #layer._muiDotPool or 0),
                Util.SafeToString(type(layer._muiHitButtonPool) == "table" and #layer._muiHitButtonPool or 0),
                Util.SafeToString(type(layer._muiStrokePool) == "table" and #layer._muiStrokePool or 0)
            ),
            false
        )
    end
end

function UI.EnsureMapAnnotationLayer(map)
    if not map then return nil end
    local scroll = map.ScrollContainer
    if not scroll then return nil end
    local canvas = scroll.Child or scroll.child or scroll.Canvas
    if not canvas then return nil end

    local layer = map._muiAnnotationLayer
    if not layer then
        layer = CreateFrame("Frame", nil, canvas)
        layer:SetAllPoints(canvas)
        layer:SetFrameStrata("HIGH")
        layer:SetFrameLevel((canvas:GetFrameLevel() or 1) + 22)
        layer:EnableMouse(false)
        map._muiAnnotationLayer = layer

        local pendingHost = CreateFrame("Frame", nil, layer)
        pendingHost:SetAllPoints(layer)
        pendingHost:SetFrameLevel(layer:GetFrameLevel() + 2)
        layer._muiPendingHost = pendingHost

        local savedHost = CreateFrame("Frame", nil, layer)
        savedHost:SetAllPoints(layer)
        savedHost:SetFrameLevel(layer:GetFrameLevel() + 6)
        layer._muiSavedHost = savedHost
        Util.MapAnnotationRenderLog(
            "layer:create",
            string.format("mapID=%s layerLevel=%s canvasLevel=%s canvasSize=(%s,%s)",
                Util.SafeToString(UI.GetActiveMapID(map)),
                Util.SafeToString(layer:GetFrameLevel()),
                Util.SafeToString(canvas:GetFrameLevel()),
                Util.FormatNumberPrecise(canvas:GetWidth()),
                Util.FormatNumberPrecise(canvas:GetHeight())
            ),
            true
        )
    elseif layer:GetParent() ~= canvas then
        layer:SetParent(canvas)
        layer:ClearAllPoints()
        layer:SetAllPoints(canvas)
        layer:SetFrameLevel((canvas:GetFrameLevel() or 1) + 22)
        if layer._muiPendingHost then
            layer._muiPendingHost:SetFrameLevel(layer:GetFrameLevel() + 2)
        end
        if layer._muiSavedHost then
            layer._muiSavedHost:SetFrameLevel(layer:GetFrameLevel() + 6)
        end
        Util.MapAnnotationRenderLog(
            "layer:reparent",
            string.format("mapID=%s layerLevel=%s canvasLevel=%s canvasSize=(%s,%s)",
                Util.SafeToString(UI.GetActiveMapID(map)),
                Util.SafeToString(layer:GetFrameLevel()),
                Util.SafeToString(canvas:GetFrameLevel()),
                Util.FormatNumberPrecise(canvas:GetWidth()),
                Util.FormatNumberPrecise(canvas:GetHeight())
            ),
            true
        )
    end

    return layer
end

function UI.GetNormalizedCursorOnMap(map)
    local scroll = map and map.ScrollContainer
    if not scroll then return nil, nil end

    if type(scroll.GetNormalizedCursorPosition) == "function" then
        local ok, x, y = pcall(scroll.GetNormalizedCursorPosition, scroll)
        if ok and type(x) == "number" and type(y) == "number" then
            return Util.Clamp(x, 0, 1), Util.Clamp(y, 0, 1)
        end
    end

    local canvas = scroll.Child or scroll.child or scroll.Canvas
    if not canvas or type(GetCursorPosition) ~= "function" then return nil, nil end

    local left = canvas:GetLeft()
    local bottom = canvas:GetBottom()
    local width = canvas:GetWidth()
    local height = canvas:GetHeight()
    if type(left) ~= "number" or type(bottom) ~= "number" or type(width) ~= "number" or type(height) ~= "number" or width <= 0 or height <= 0 then
        return nil, nil
    end

    local scale = canvas:GetEffectiveScale() or 1
    local cursorX, cursorY = GetCursorPosition()
    local x = (cursorX / scale - left) / width
    local y = ((bottom + height) - (cursorY / scale)) / height
    return Util.Clamp(x, 0, 1), Util.Clamp(y, 0, 1)
end

function UI.ExtractMapAnnotationPOIName(frame)
    local function ReadText(widget)
        if widget and type(widget.GetText) == "function" then
            local value = widget:GetText()
            if type(value) == "string" and value ~= "" then
                return value
            end
        end
        return nil
    end

    local probe = frame
    for _ = 1, 5 do
        if not probe then break end

        if type(probe) == "table" then
            if probe.poiInfo and type(probe.poiInfo.name) == "string" and probe.poiInfo.name ~= "" then
                return probe.poiInfo.name
            end
            if probe.areaPoiInfo and type(probe.areaPoiInfo.name) == "string" and probe.areaPoiInfo.name ~= "" then
                return probe.areaPoiInfo.name
            end
            local maybeName = ReadText(probe.name) or ReadText(probe.Name) or ReadText(probe.Label) or ReadText(probe.label)
            if maybeName then return maybeName end
        end

        probe = type(probe.GetParent) == "function" and probe:GetParent() or nil
    end

    return nil
end

function UI.ExtractPinName(pin)
    if type(pin) ~= "table" then return nil end

    -- poiInfo (AreaPOI pins â€" world bosses, events, etc.)
    if pin.poiInfo and type(pin.poiInfo.name) == "string" and pin.poiInfo.name ~= "" then
        return pin.poiInfo.name
    end
    -- areaPoiInfo (area POI pins)
    if pin.areaPoiInfo and type(pin.areaPoiInfo.name) == "string" and pin.areaPoiInfo.name ~= "" then
        return pin.areaPoiInfo.name
    end
    -- Dungeon / Raid entrance pins (EncounterJournal data provider)
    if pin.journalInstanceID and type(EJ_GetInstanceInfo) == "function" then
        local ok, name = pcall(EJ_GetInstanceInfo, pin.journalInstanceID)
        if ok and type(name) == "string" and name ~= "" then
            return name
        end
    end
    -- MapLink pins (dungeon/raid portals) â€" name comes from mapInfo of the linked map
    if pin.linkedMap and type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function" then
        local ok, info = pcall(C_Map.GetMapInfo, pin.linkedMap)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then
            return info.name
        end
    end
    -- Vignette pins (rare spawns, treasures)
    if pin.vignetteInfo and type(pin.vignetteInfo.name) == "string" and pin.vignetteInfo.name ~= "" then
        return pin.vignetteInfo.name
    end
    -- FlightPoint / TaxiNode pins
    if pin.taxiNodeData and type(pin.taxiNodeData.name) == "string" and pin.taxiNodeData.name ~= "" then
        return pin.taxiNodeData.name
    end
    -- Delve pins
    if pin.delveInfo and type(pin.delveInfo.name) == "string" and pin.delveInfo.name ~= "" then
        return pin.delveInfo.name
    end
    -- Generic: check pin.name as a direct string (some custom pins)
    if type(pin.name) == "string" and pin.name ~= "" then
        return pin.name
    end
    -- Generic: check for a label FontString
    if pin.Label and type(pin.Label.GetText) == "function" then
        local t = pin.Label:GetText()
        if type(t) == "string" and t ~= "" then return t end
    end
    if pin.Name and type(pin.Name.GetText) == "function" then
        local t = pin.Name:GetText()
        if type(t) == "string" and t ~= "" then return t end
    end

    return nil
end

function UI.ResolveMapAnnotationLocationLabel(map, x, y)
    local resultLabel = nil

    -- 1) Try GetMouseFoci
    pcall(function()
        if type(GetMouseFoci) ~= "function" then return end
        local foci = { GetMouseFoci() }
        for i = 1, #foci do
            local focus = foci[i]
            if focus and focus ~= map and focus ~= (map and map._muiAnnotationCaptureOverlay) then
                local eOk, eName = pcall(UI.ExtractMapAnnotationPOIName, focus)
                if eOk and eName then
                    resultLabel = eName
                    return
                end
            end
        end
    end)
    if resultLabel then return resultLabel, true end

    -- 2) Enumerate map pins via pinPools fallback
    pcall(function()
        local wmf = _G.WorldMapFrame
        local pinHost = nil
        if wmf and type(wmf.EnumerateAllPins) == "function" then
            pinHost = wmf
        elseif map and type(map.EnumerateAllPins) == "function" then
            pinHost = map
        end

        local usePinPools = false
        local pinPoolsTable = nil
        if not pinHost then
            pcall(function()
                if wmf and type(wmf.pinPools) == "table" then
                    pinPoolsTable = wmf.pinPools
                    usePinPools = true
                elseif map and type(map.pinPools) == "table" then
                    pinPoolsTable = map.pinPools
                    usePinPools = true
                end
            end)
        end

        if not pinHost and not usePinPools then return end

        local hitR = 0.030
        local bestName, bestDist = nil, hitR

        local function ProcessPin(pin)
            local nm = nil
            pcall(function() nm = UI.ExtractPinName(pin) end)
            if not nm then return end
            local px, py = nil, nil
            pcall(function()
                if type(pin.GetPosition) == "function" then
                    px, py = pin:GetPosition()
                end
            end)
            if type(px) == "number" and type(py) == "number" then
                local d = math.sqrt((px - (x or 0))^2 + (py - (y or 0))^2)
                if d < bestDist then
                    bestDist = d
                    bestName = nm
                end
            end
        end

        if pinHost then
            for pin in pinHost:EnumerateAllPins() do
                ProcessPin(pin)
            end
        elseif usePinPools and pinPoolsTable then
            for template, pool in pairs(pinPoolsTable) do
                if type(pool) == "table" and type(pool.EnumerateActive) == "function" then
                    for pin in pool:EnumerateActive() do
                        ProcessPin(pin)
                    end
                end
            end
        end

        if bestName then
            resultLabel = bestName
        end
    end)

    if resultLabel then
        return resultLabel, true
    end
    return string.format("%.1f, %.1f", (x or 0) * 100, (y or 0) * 100), false
end

function UI.BuildMapAnnotationChatLine(note)
    if type(note) ~= "table" then
        return "[Map Note]"
    end

    local mapName = nil
    if type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function" and type(note.mapID) == "number" then
        local info = C_Map.GetMapInfo(note.mapID)
        mapName = info and info.name or nil
    end

    local title = (type(note.title) == "string" and note.title ~= "") and note.title or (type(note.locationLabel) == "string" and note.locationLabel ~= "" and note.locationLabel or "Map Note")
    local coordText = string.format("%.1f, %.1f", (note.x or 0) * 100, (note.y or 0) * 100)
    local head = string.format("[Map Note] %s (%s)", title, coordText)
    if type(mapName) == "string" and mapName ~= "" then
        head = head .. " - " .. mapName
    end
    if type(note.noteType) == "string" and note.noteType ~= "" then
        head = head .. " [" .. note.noteType .. "]"
    end
    if type(note.description) == "string" and note.description ~= "" then
        head = head .. " :: " .. note.description
    end
    return head
end

function UI.GetMapAnnotationBounds(note)
    if type(note) ~= "table" or type(note.points) ~= "table" or #note.points < 1 then
        return nil
    end

    local minX, maxX = 1, 0
    local minY, maxY = 1, 0
    for i = 1, #note.points do
        local p = note.points[i]
        local x = type(p) == "table" and p.x or nil
        local y = type(p) == "table" and p.y or nil
        if type(x) == "number" and type(y) == "number" then
            if x < minX then minX = x end
            if x > maxX then maxX = x end
            if y < minY then minY = y end
            if y > maxY then maxY = y end
        end
    end
    return minX, maxX, minY, maxY
end

function UI.FindMapAnnotationUnderCursor(map)
    if not map then return nil end
    local mapID = UI.GetActiveMapID(map)
    if type(mapID) ~= "number" then return nil end

    local cx, cy = UI.GetNormalizedCursorOnMap(map)
    if type(cx) ~= "number" or type(cy) ~= "number" then return nil end

    local store = UI.GetMapAnnotationStore()
    if type(store.entries) ~= "table" then return nil end

    for i = #store.entries, 1, -1 do
        local note = store.entries[i]
        if type(note) == "table" and note.hidden ~= true and note.mapID == mapID then
            local minX, maxX, minY, maxY = UI.GetMapAnnotationBounds(note)
            if minX then
                local pad = 0.010
                if #note.points <= 2 then pad = 0.016 end
                if cx >= (minX - pad) and cx <= (maxX + pad) and cy >= (minY - pad) and cy <= (maxY + pad) then
                    return note
                end
            end
        end
    end
    return nil
end

function UI.ShowMapAnnotationTooltip(owner, note)
    if not owner or type(note) ~= "table" then return end
    if not _G.GameTooltip or type(_G.GameTooltip.SetOwner) ~= "function" then return end
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(owner, "ANCHOR_CURSOR")

    local title = (type(note.title) == "string" and note.title ~= "") and note.title
        or ((type(note.locationLabel) == "string" and note.locationLabel ~= "") and note.locationLabel or "Map Note")
    tooltip:SetText(title, 1, 0.92, 0.65)

    if type(note.noteType) == "string" and note.noteType ~= "" then
        tooltip:AddLine((_G.TYPE or "Type") .. ": " .. note.noteType, 0.75, 0.82, 0.90, true)
    end

    if type(note.description) == "string" and note.description ~= "" then
        tooltip:AddLine(note.description, 0.86, 0.90, 0.96, true)
    end

    local coordText = string.format("%.1f, %.1f", (note.x or 0) * 100, (note.y or 0) * 100)
    tooltip:AddLine(coordText, 0.66, 0.72, 0.80, true)
    tooltip:Show()
end

function UI.SendMapAnnotationToChat(note, channel)
    if type(channel) ~= "string" or channel == "" then return end
    if type(SendChatMessage) ~= "function" then return end
    local text = UI.BuildMapAnnotationChatLine(note)
    if text and text ~= "" then
        pcall(SendChatMessage, text, channel)
    end
end

function UI.SuperTrackMapAnnotation(note)
    if type(note) ~= "table" then return end
    if type(note.mapID) ~= "number" or type(note.x) ~= "number" or type(note.y) ~= "number" then return end
    if type(C_Map) ~= "table" or type(UiMapPoint) ~= "table" then return end

    local point = UiMapPoint.CreateFromCoordinates(note.mapID, note.x, note.y)
    if point and type(C_Map.SetUserWaypoint) == "function" then
        pcall(C_Map.SetUserWaypoint, point)
    end
    if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedUserWaypoint) == "function" then
        pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true)
    end
end

function UI.RemoveMapAnnotation(note)
    if type(note) ~= "table" then return false end
    local store = UI.GetMapAnnotationStore()
    if type(store.entries) ~= "table" then return false end

    local removed = false
    for i = #store.entries, 1, -1 do
        local entry = store.entries[i]
        if entry == note or (type(note.id) == "number" and type(entry) == "table" and entry.id == note.id) then
            table.remove(store.entries, i)
            removed = true
            break
        end
    end

    if removed then
        UI.RenderMapAnnotations(_G.WorldMapFrame)
    end
    return removed
end

function UI.GetMapHiddenAnnotationCount(mapID)
    local store = UI.GetMapAnnotationStore()
    if type(store.entries) ~= "table" then return 0 end
    local count = 0
    for i = 1, #store.entries do
        local entry = store.entries[i]
        if type(entry) == "table" and entry.hidden == true
            and (type(mapID) ~= "number" or entry.mapID == mapID) then
            count = count + 1
        end
    end
    return count
end

function UI.UnhideAllMapAnnotations(mapID)
    local store = UI.GetMapAnnotationStore()
    if type(store.entries) ~= "table" then return 0 end
    local changed = 0
    for i = 1, #store.entries do
        local entry = store.entries[i]
        if type(entry) == "table" and entry.hidden == true
            and (type(mapID) ~= "number" or entry.mapID == mapID) then
            entry.hidden = false
            changed = changed + 1
        end
    end
    if changed > 0 then
        UI.RenderMapAnnotations(_G.WorldMapFrame)
    end
    return changed
end

function UI.DeleteHiddenMapAnnotations(mapID)
    local store = UI.GetMapAnnotationStore()
    if type(store.entries) ~= "table" then return 0 end
    local removed = 0
    for i = #store.entries, 1, -1 do
        local entry = store.entries[i]
        if type(entry) == "table" and entry.hidden == true
            and (type(mapID) ~= "number" or entry.mapID == mapID) then
            table.remove(store.entries, i)
            removed = removed + 1
        end
    end
    if removed > 0 then
        UI.RenderMapAnnotations(_G.WorldMapFrame)
    end
    return removed
end

function UI.HideMapAnnotationFallbackMenu()
    local menu = Runtime.annotation and Runtime.annotation._fallbackMenu or nil
    if menu and menu:IsShown() then
        UI.HideMapAnnotationFallbackSubMenu(menu)
        menu:Hide()
    end
    if Runtime.annotation then
        Runtime.annotation.contextMenuOpen = false
    end
end

function UI.EnsureMapAnnotationFallbackMenu()
    if Runtime.annotation and Runtime.annotation._fallbackMenu then
        return Runtime.annotation._fallbackMenu
    end

    local menu = CreateFrame("Frame", "MidnightUI_MapAnnotationFallbackMenu", UIParent, "BackdropTemplate")
    menu:SetFrameStrata("DIALOG")
    menu:SetFrameLevel(220)
    menu:SetClampedToScreen(true)
    menu:EnableMouse(true)
    menu:Hide()
    if type(menu.SetBackdrop) == "function" then
        menu:SetBackdrop({
            bgFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        menu:SetBackdropColor(0.04, 0.06, 0.10, 0.96)
        menu:SetBackdropBorderColor(0.42, 0.47, 0.55, 0.94)
    end
    menu._muiButtons = {}
    menu._muiSubButtons = {}
    menu._muiButtonHeight = 20
    menu._muiButtonSpacing = 2
    menu._muiWidth = 236
    menu:SetWidth(menu._muiWidth)

    menu:SetScript("OnHide", function()
        if Runtime.annotation then
            Runtime.annotation.contextMenuOpen = false
        end
    end)

    Runtime.annotation = Runtime.annotation or {}
    Runtime.annotation._fallbackMenu = menu
    return menu
end

function UI.HideMapAnnotationFallbackSubMenu(menu)
    if not menu then return end
    local subMenu = menu._muiSubMenu
    if subMenu and subMenu:IsShown() then
        subMenu:Hide()
    end
end

function UI.ShowMapAnnotationFallbackSubMenu(menu, anchorButton, submenuRows)
    if not menu or not anchorButton or type(submenuRows) ~= "table" or #submenuRows == 0 then return end
    local subMenu = menu._muiSubMenu
    if not subMenu then
        subMenu = CreateFrame("Frame", nil, menu, "BackdropTemplate")
        subMenu:SetFrameStrata("DIALOG")
        subMenu:SetFrameLevel(menu:GetFrameLevel() + 3)
        if type(subMenu.SetBackdrop) == "function" then
            subMenu:SetBackdrop({
                bgFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
                edgeFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            subMenu:SetBackdropColor(0.03, 0.05, 0.09, 0.97)
            subMenu:SetBackdropBorderColor(0.45, 0.50, 0.58, 0.95)
        end
        subMenu._muiButtons = {}
        menu._muiSubMenu = subMenu
    end

    local buttonHeight = menu._muiButtonHeight or 20
    local spacing = menu._muiButtonSpacing or 2
    local y = -8
    for i = 1, #submenuRows do
        local row = submenuRows[i]
        local button = subMenu._muiButtons[i]
        if not button then
            button = CreateFrame("Button", nil, subMenu)
            button:SetHeight(buttonHeight)
            button._label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            button._label:SetPoint("LEFT", button, "LEFT", 8, 0)
            button._label:SetPoint("RIGHT", button, "RIGHT", -8, 0)
            button._label:SetJustifyH("LEFT")
            local highlight = button:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints(button)
            highlight:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
            highlight:SetVertexColor(1, 1, 1, 0.10)
            subMenu._muiButtons[i] = button
        end
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", subMenu, "TOPLEFT", 8, y)
        button:SetPoint("TOPRIGHT", subMenu, "TOPRIGHT", -8, y)
        button._label:SetText(row.text or "")
        button._label:SetTextColor(0.88, 0.92, 0.98, 1)
        button._muiFunc = row.func
        button:SetScript("OnClick", function(self)
            if self._muiFunc then
                self._muiFunc()
            end
            UI.HideMapAnnotationFallbackMenu()
        end)
        button:Show()
        y = y - (buttonHeight + spacing)
    end
    for i = #submenuRows + 1, #subMenu._muiButtons do
        local button = subMenu._muiButtons[i]
        if button then
            button:Hide()
            button._muiFunc = nil
        end
    end

    subMenu:SetWidth(190)
    subMenu:SetHeight(16 + (#submenuRows * (buttonHeight + spacing)))
    subMenu:ClearAllPoints()
    subMenu:SetPoint("TOPLEFT", anchorButton, "TOPRIGHT", 4, 0)
    subMenu:Show()
end

function UI.PopulateMapAnnotationFallbackMenu(menu, rows)
    if not menu or type(rows) ~= "table" then return 0 end

    UI.HideMapAnnotationFallbackSubMenu(menu)
    local y = -8
    for i = 1, #rows do
        local row = rows[i]
        local button = menu._muiButtons[i]
        if not button then
            button = CreateFrame("Button", nil, menu)
            button:SetHeight(menu._muiButtonHeight)
            button:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, y)
            button:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, y)
            button._label = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            button._label:SetPoint("LEFT", button, "LEFT", 8, 0)
            button._label:SetPoint("RIGHT", button, "RIGHT", -8, 0)
            button._label:SetJustifyH("LEFT")
            local highlight = button:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints(button)
            highlight:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
            highlight:SetVertexColor(1, 1, 1, 0.10)
            menu._muiButtons[i] = button
        else
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, y)
            button:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -8, y)
        end

        button._muiFunc = row.func
        button._muiSubmenuRows = row.submenuRows
        button._label:SetText(row.text or "")
        if row.isTitle then
            button:EnableMouse(false)
            button._label:SetTextColor(1.0, 0.92, 0.65, 1)
        else
            button:EnableMouse(true)
            button._label:SetTextColor(0.88, 0.92, 0.98, 1)
        end

        button:SetScript("OnClick", function(self)
            if self._muiFunc then
                self._muiFunc()
            end
            UI.HideMapAnnotationFallbackMenu()
        end)
        button:SetScript("OnEnter", function(self)
            if type(self._muiSubmenuRows) == "table" and #self._muiSubmenuRows > 0 then
                UI.ShowMapAnnotationFallbackSubMenu(menu, self, self._muiSubmenuRows)
            else
                UI.HideMapAnnotationFallbackSubMenu(menu)
            end
        end)

        button:Show()
        y = y - (menu._muiButtonHeight + menu._muiButtonSpacing)
    end

    for i = #rows + 1, #menu._muiButtons do
        local button = menu._muiButtons[i]
        if button then
            button:Hide()
            button._muiFunc = nil
            button._muiSubmenuRows = nil
        end
    end

    local totalHeight = 16 + (#rows * (menu._muiButtonHeight + menu._muiButtonSpacing))
    menu:SetHeight(totalHeight)
    return #rows
end

function UI.ShowMapAnnotationFallbackMenu(owner, rows, logTag)
    if not owner or type(rows) ~= "table" then
        Util.MapAnnotationInputLog("contextMenu:fallback", "blocked reason=invalidOwnerOrNote", true)
        return
    end

    local menu = UI.EnsureMapAnnotationFallbackMenu()
    local rowCount = UI.PopulateMapAnnotationFallbackMenu(menu, rows)
    if rowCount <= 0 then
        Util.MapAnnotationInputLog("contextMenu:fallback", "blocked reason=noRows", true)
        return
    end

    local x, y = 0, 0
    if type(GetCursorPosition) == "function" then
        local cx, cy = GetCursorPosition()
        local scale = (UIParent and UIParent:GetEffectiveScale()) or 1
        x = (cx / scale) + 12
        y = (cy / scale) - 12
    end
    local maxX = (UIParent:GetWidth() or 0) - menu:GetWidth() - 8
    local minY = menu:GetHeight() + 8
    if x > maxX then x = maxX end
    if x < 8 then x = 8 end
    if y < minY then y = minY end

    menu:ClearAllPoints()
    menu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    Runtime.annotation.contextMenuOpen = true
    menu:Show()
    Util.MapAnnotationInputLog(
        "contextMenu:fallback:" .. Util.SafeToString(logTag or "menu"),
        string.format("shown=true rows=%s x=%s y=%s", Util.SafeToString(rowCount), Util.FormatNumberPrecise(x), Util.FormatNumberPrecise(y)),
        true
    )
end

function UI.RefreshMapAnnotationToolButtonState()
    local button = Runtime.controls and Runtime.controls.annotationToolButton or nil
    if not button then return end
    button.isActive = (Runtime.annotation and Runtime.annotation.active == true)
    if button._muiMapChrome and button._muiMapChrome.accent then
        button._muiMapChrome.accent:SetAlpha(button.isActive and 1 or 0)
    end
    UI.ApplyControlIconColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
end

function UI.ShowMapAnnotationContextMenu(owner, note)
    if not owner or type(note) ~= "table" then
        Util.MapAnnotationInputLog("contextMenu:open", "blocked reason=invalidOwnerOrNote", true)
        return
    end
    if type(EasyMenu) ~= "function" then
        local loaded = false
        if type(C_AddOns) == "table" and type(C_AddOns.LoadAddOn) == "function" then
            local ok = pcall(C_AddOns.LoadAddOn, "Blizzard_UIDropDownMenu")
            loaded = (ok and type(EasyMenu) == "function")
        elseif type(LoadAddOn) == "function" then
            local ok = pcall(LoadAddOn, "Blizzard_UIDropDownMenu")
            loaded = (ok and type(EasyMenu) == "function")
        end

        if loaded then
            Util.MapAnnotationInputLog("contextMenu:open", "easyMenuLoaded=true", true)
        else
            Util.MapAnnotationInputLog("contextMenu:open", "easyMenuMissing=true usingFallback=true", true)
            local fallbackRows = {
                { text = (note.title and note.title ~= "") and note.title or "Map Note", isTitle = true },
                { text = "SuperTrack", func = function() UI.SuperTrackMapAnnotation(note) end },
                { text = "Hide", func = function() note.hidden = true; UI.RenderMapAnnotations(_G.WorldMapFrame) end },
                { text = _G.DELETE or "Remove", func = function() UI.RemoveMapAnnotation(note) end },
                {
                    text = "Link in Chat >",
                    submenuRows = {
                        { text = _G.SAY or "Say", func = function() UI.SendMapAnnotationToChat(note, "SAY") end },
                        { text = _G.PARTY or "Party", func = function() UI.SendMapAnnotationToChat(note, "PARTY") end },
                        { text = _G.RAID or "Raid", func = function() UI.SendMapAnnotationToChat(note, "RAID") end },
                        { text = _G.GUILD or "Guild", func = function() UI.SendMapAnnotationToChat(note, "GUILD") end },
                        { text = "Instance", func = function() UI.SendMapAnnotationToChat(note, "INSTANCE_CHAT") end },
                    },
                },
                { text = _G.CLOSE or "Close", func = function() end },
            }
            UI.ShowMapAnnotationFallbackMenu(owner, fallbackRows, "note")
            return
        end
    end

    Util.MapAnnotationInputLog(
        "contextMenu:open",
        string.format(
            "noteId=%s title=%s owner=%s",
            Util.SafeToString(note.id),
            Util.SafeToString(note.title),
            Util.SafeToString(owner.GetName and owner:GetName() or owner)
        ),
        true
    )
    Runtime.annotation.contextMenuOpen = true
    local menuFrame = Runtime.annotation._menuFrame
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "MidnightUI_MapAnnotationContextMenu", UIParent, "UIDropDownMenuTemplate")
        Runtime.annotation._menuFrame = menuFrame
    end

    local menu = {
        { text = (note.title and note.title ~= "") and note.title or "Map Note", isTitle = true, notCheckable = true },
        { text = "SuperTrack", notCheckable = true, func = function() UI.SuperTrackMapAnnotation(note) end },
        { text = "Hide", notCheckable = true, func = function()
            note.hidden = true
            UI.RenderMapAnnotations(_G.WorldMapFrame)
        end },
        { text = _G.DELETE or "Remove", notCheckable = true, func = function()
            UI.RemoveMapAnnotation(note)
        end },
        {
            text = "Link in Chat",
            hasArrow = true,
            notCheckable = true,
            menuList = {
                { text = _G.SAY or "Say", notCheckable = true, func = function() UI.SendMapAnnotationToChat(note, "SAY") end },
                { text = _G.PARTY or "Party", notCheckable = true, func = function() UI.SendMapAnnotationToChat(note, "PARTY") end },
                { text = _G.RAID or "Raid", notCheckable = true, func = function() UI.SendMapAnnotationToChat(note, "RAID") end },
                { text = _G.GUILD or "Guild", notCheckable = true, func = function() UI.SendMapAnnotationToChat(note, "GUILD") end },
                { text = "Instance", notCheckable = true, func = function() UI.SendMapAnnotationToChat(note, "INSTANCE_CHAT") end },
            },
        },
    }

    EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    Util.MapAnnotationInputLog("contextMenu:open", "easyMenuInvoked=true", true)
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0.20, function()
            Runtime.annotation.contextMenuOpen = false
            Util.MapAnnotationInputLog("contextMenu:state", "open=false viaTimer", false)
        end)
    else
        Runtime.annotation.contextMenuOpen = false
        Util.MapAnnotationInputLog("contextMenu:state", "open=false immediate", false)
    end
end

function UI.ShowMapAnnotationHiddenNotesMenu(owner, map)
    if not owner or not map then return end
    local mapID = UI.GetActiveMapID(map)
    local hiddenCount = UI.GetMapHiddenAnnotationCount(mapID)
    if hiddenCount <= 0 then
        Util.MapAnnotationInputLog("hiddenMenu:open", "blocked reason=noHiddenNotes", true)
        return
    end

    if type(EasyMenu) ~= "function" then
        local loaded = false
        if type(C_AddOns) == "table" and type(C_AddOns.LoadAddOn) == "function" then
            local ok = pcall(C_AddOns.LoadAddOn, "Blizzard_UIDropDownMenu")
            loaded = (ok and type(EasyMenu) == "function")
        elseif type(LoadAddOn) == "function" then
            local ok = pcall(LoadAddOn, "Blizzard_UIDropDownMenu")
            loaded = (ok and type(EasyMenu) == "function")
        end
        if not loaded then
            local rows = {
                { text = "Hidden Notes (" .. hiddenCount .. ")", isTitle = true },
                { text = "Unhide All", func = function() UI.UnhideAllMapAnnotations(mapID) end },
                { text = (_G.DELETE or "Delete") .. " Hidden", func = function() UI.DeleteHiddenMapAnnotations(mapID) end },
                { text = _G.CLOSE or "Close", func = function() end },
            }
            UI.ShowMapAnnotationFallbackMenu(owner, rows, "hidden")
            return
        end
    end

    Runtime.annotation.contextMenuOpen = true
    local menuFrame = Runtime.annotation._menuFrame
    if not menuFrame then
        menuFrame = CreateFrame("Frame", "MidnightUI_MapAnnotationContextMenu", UIParent, "UIDropDownMenuTemplate")
        Runtime.annotation._menuFrame = menuFrame
    end

    local menu = {
        { text = "Hidden Notes (" .. hiddenCount .. ")", isTitle = true, notCheckable = true },
        { text = "Unhide All", notCheckable = true, func = function() UI.UnhideAllMapAnnotations(mapID) end },
        { text = (_G.DELETE or "Delete") .. " Hidden", notCheckable = true, func = function() UI.DeleteHiddenMapAnnotations(mapID) end },
    }
    EasyMenu(menu, menuFrame, "cursor", 0, 0, "MENU")
    Util.MapAnnotationInputLog("hiddenMenu:open", "easyMenuInvoked=true hiddenCount=" .. Util.SafeToString(hiddenCount), true)
    if C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0.20, function()
            Runtime.annotation.contextMenuOpen = false
        end)
    else
        Runtime.annotation.contextMenuOpen = false
    end
end

function UI.ReportMapAnnotationError(message)
    local text = type(message) == "string" and message or "You have to draw a connecting shape."
    if _G.UIErrorsFrame and type(_G.UIErrorsFrame.AddMessage) == "function" then
        _G.UIErrorsFrame:AddMessage(text, 1.0, 0.22, 0.22, 1.0)
    elseif _G.DEFAULT_CHAT_FRAME and type(_G.DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cffff5555MidnightUI:|r " .. text)
    end
end

function UI.GetMapAnnotationPathLength(points)
    if type(points) ~= "table" or #points < 2 then return 0 end
    local length = 0
    for i = 2, #points do
        local p1 = points[i - 1]
        local p2 = points[i]
        local dx = (p2.x or 0) - (p1.x or 0)
        local dy = (p2.y or 0) - (p1.y or 0)
        length = length + math.sqrt((dx * dx) + (dy * dy))
    end
    return length
end

function UI.GetMapAnnotationPolygonArea(points)
    if type(points) ~= "table" or #points < 4 then return 0 end
    local area2 = 0
    for i = 1, #points - 1 do
        local p1 = points[i]
        local p2 = points[i + 1]
        local x1 = (type(p1) == "table" and type(p1.x) == "number") and p1.x or 0
        local y1 = (type(p1) == "table" and type(p1.y) == "number") and p1.y or 0
        local x2 = (type(p2) == "table" and type(p2.x) == "number") and p2.x or 0
        local y2 = (type(p2) == "table" and type(p2.y) == "number") and p2.y or 0
        area2 = area2 + ((x1 * y2) - (x2 * y1))
    end
    return math.abs(area2) * 0.5
end

function UI.IsMapAnnotationClosedShape(points)
    if type(points) ~= "table" or #points < 4 then
        return false, nil
    end
    local first = points[1]
    local last = points[#points]
    if not first or not last then
        return false, nil
    end
    local dx = (last.x or 0) - (first.x or 0)
    local dy = (last.y or 0) - (first.y or 0)
    local distSq = (dx * dx) + (dy * dy)
    local snapRadius = 0.045
    return distSq <= (snapRadius * snapRadius), distSq
end

function UI.BuildMapAnnotationRenderPoints(points, forceClosed)
    if type(points) ~= "table" then
        return nil
    end

    local renderPoints = {}
    for i = 1, #points do
        local p = points[i]
        if type(p) == "table" and type(p.x) == "number" and type(p.y) == "number" then
            renderPoints[#renderPoints + 1] = { x = p.x, y = p.y }
        end
    end

    if forceClosed and #renderPoints >= 3 then
        local first = renderPoints[1]
        local last = renderPoints[#renderPoints]
        local dx = (last.x or 0) - (first.x or 0)
        local dy = (last.y or 0) - (first.y or 0)
        if ((dx * dx) + (dy * dy)) > (0.0001 * 0.0001) then
            renderPoints[#renderPoints + 1] = { x = first.x, y = first.y }
        end
    end

    return renderPoints
end

function UI.DrawMapAnnotationFill(layer, host, points, r, g, b, a, debugMeta)
    local fillPoints = UI.BuildMapAnnotationRenderPoints(points, true)
    if type(fillPoints) ~= "table" or #fillPoints < 4 then return false end

    local width = host:GetWidth()
    local height = host:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 1 or height <= 1 then
        return false
    end

    local px = {}
    local py = {}
    local minX = width
    local maxX = 0
    local minY = height
    local maxY = 0
    for i = 1, #fillPoints do
        local x = Util.Clamp(fillPoints[i].x or 0, 0, 1) * width
        local y = Util.Clamp(fillPoints[i].y or 0, 0, 1) * height
        px[i] = x
        py[i] = y
        if x < minX then minX = x end
        if x > maxX then maxX = x end
        if y < minY then minY = y end
        if y > maxY then maxY = y end
    end

    if maxY <= minY or maxX <= minX then return false end
    local hostScale = type(host.GetEffectiveScale) == "function" and host:GetEffectiveScale() or 1
    local uiScale = (UIParent and type(UIParent.GetEffectiveScale) == "function") and UIParent:GetEffectiveScale() or 1
    local pixelScale = (uiScale > 0) and (hostScale / uiScale) or 1
    if type(pixelScale) ~= "number" or pixelScale <= 0 then
        pixelScale = 1
    end
    local minScreenThickness = 1.15
    local rasterThickness = math.max(2, math.ceil(minScreenThickness / math.max(0.001, pixelScale)))
    if rasterThickness > 10 then
        rasterThickness = 10
    end
    local step = rasterThickness + 1
    local pitchScreenPx = step * pixelScale
    local pitchScreenFinal = pitchScreenPx
    local thicknessScreenPx = rasterThickness * pixelScale
    local inputAlpha = type(a) == "number" and a or 0.32
    local fillAlpha = math.min(0.34, math.max(0.28, inputAlpha))
    local noteKey = (type(debugMeta) == "table" and debugMeta.noteKey) or ("anon:" .. tostring(#fillPoints))
    local lifecycleKey = (type(debugMeta) == "table" and debugMeta.lifecycleKey) or noteKey
    local isPendingPass = (type(debugMeta) == "table" and debugMeta.isPending == true)
    local abMode = Util.GetMapAnnotationBandingABMode()
    local abAuto = (Util.EnsureMapNavDebugSettings().mapAnnotationBandingAutoMode == true)

    Runtime.annotation = Runtime.annotation or {}
    Runtime.annotation.fillABState = Runtime.annotation.fillABState or {}
    local abState = Runtime.annotation.fillABState
    local fillVariant = "A"
    local lifecycleLock = "none"
    local lockReleased = false
    local now = (type(GetTimePreciseSec) == "function" and GetTimePreciseSec()) or GetTime()
    if abMode == "A" or abMode == "B" then
        fillVariant = abMode
        lifecycleLock = "manual"
    elseif abMode == "ALT" then
        abState.locks = abState.locks or {}
        local lock = abState.locks[lifecycleKey]
        if type(lock) ~= "table" then
            local previousVariant = abState._lastVariant
            if previousVariant == "A" then
                fillVariant = "B"
            else
                fillVariant = "A"
            end
            abState._lastVariant = fillVariant
            lock = {
                variant = fillVariant,
                pendingSeen = false,
                savedSeen = false,
                createdAt = now,
            }
            abState.locks[lifecycleKey] = lock
            lifecycleLock = "created"
        else
            fillVariant = lock.variant or "A"
            lifecycleLock = "reused"
        end

        if isPendingPass then
            lock.pendingSeen = true
        else
            if lock.pendingSeen == true and lock.savedSeen ~= true then
                lock.savedSeen = true
                lifecycleLock = "releasedAfterSaved"
                lockReleased = true
                abState.locks[lifecycleKey] = nil
            elseif lock.pendingSeen ~= true then
                lifecycleLock = "savedWithoutPending"
            end
        end
    else
        fillVariant = "A"
        lifecycleLock = "fallbackA"
    end

    local fillOrientation = "VERTICAL"
    local fillBlendMode = "BLEND"
    local fillSnapToPixel = true
    local fillTexelBias = 0
    local fillRowOffset = 0
    local aliasRisk = (pitchScreenFinal > 1.00) or (thicknessScreenPx < (pitchScreenFinal * 1.00))
    local debandPassEnabled = false
    local totalPasses = 1
    local useLineFill = false
    local fillPrimitive = "TEXTURE_SOLID"
    local rowCoverageSamples = {}
    local fillSegments = 0
    local lineFillSegments = 0
    local textureFillSegments = 0
    local overlayTextureSegments = 0
    local overlayTextureAlpha = fillAlpha
    local debandSegments = 0
    local debandScans = 0
    local debandStep = nil
    local debandThickness = nil
    local debandAlpha = nil
    local scannedRows = 0
    local paintedRows = 0
    local oddIntersectionRows = 0
    local dedupeRemoved = 0
    local totalPairs = 0
    local maxPairsPerRow = 0
    local largeCoverageJumpRows = 0
    local alternatingDeltaRows = 0
    local paintedGapRows = 0
    local firstPaintedY = nil
    local lastPaintedY = nil
    local minCoverage = nil
    local maxCoverage = nil
    local totalCoverage = 0
    local previousCoverage = nil
    local previousDelta = nil
    local previousPaintedY = nil
    local startY = math.floor(minX)
    local endY = math.ceil(maxX)

    local function ProbeHorizontalRows()
        if maxY <= minY then
            return {
                scannedRows = 0,
                paintedRows = 0,
                oddRows = 0,
                maxPairs = 0,
                avgPairs = 0,
                gapRows = 0,
                covMean = 0,
                covRange = 0,
                sampleSig = "none",
            }
        end

        local scannedRows = 0
        local paintedRows = 0
        local oddRows = 0
        local maxPairs = 0
        local totalPairsRows = 0
        local gapRows = 0
        local totalCoverageRows = 0
        local minCoverageRow = nil
        local maxCoverageRow = nil
        local previousPaintedY = nil
        local sampleRows = {}

        for scanY = math.floor(minY), math.ceil(maxY), step do
            scannedRows = scannedRows + 1
            local intersections = {}
            for i = 1, #fillPoints - 1 do
                local y1 = py[i]
                local y2 = py[i + 1]
                if (y1 <= scanY and y2 > scanY) or (y2 <= scanY and y1 > scanY) then
                    local x1 = px[i]
                    local x2 = px[i + 1]
                    local t = (scanY - y1) / (y2 - y1)
                    intersections[#intersections + 1] = x1 + (t * (x2 - x1))
                end
            end

            table.sort(intersections)
            local deduped = {}
            for idx = 1, #intersections do
                local x = intersections[idx]
                local prev = deduped[#deduped]
                if type(prev) ~= "number" or math.abs(x - prev) > 0.10 then
                    deduped[#deduped + 1] = x
                end
            end
            intersections = deduped
            if (#intersections % 2) ~= 0 then
                oddRows = oddRows + 1
                intersections[#intersections] = nil
            end

            local j = 1
            local rowPairs = 0
            local rowCoverage = 0
            while j < #intersections do
                local xStart = intersections[j]
                local xEnd = intersections[j + 1]
                if type(xStart) == "number" and type(xEnd) == "number" and xEnd > xStart then
                    rowPairs = rowPairs + 1
                    rowCoverage = rowCoverage + (xEnd - xStart)
                end
                j = j + 2
            end

            if rowPairs > 0 then
                paintedRows = paintedRows + 1
                if type(previousPaintedY) == "number" and scanY > (previousPaintedY + step) then
                    gapRows = gapRows + (scanY - previousPaintedY - step)
                end
                previousPaintedY = scanY
                totalPairsRows = totalPairsRows + rowPairs
                totalCoverageRows = totalCoverageRows + rowCoverage
                if rowPairs > maxPairs then
                    maxPairs = rowPairs
                end
                if minCoverageRow == nil or rowCoverage < minCoverageRow then
                    minCoverageRow = rowCoverage
                end
                if maxCoverageRow == nil or rowCoverage > maxCoverageRow then
                    maxCoverageRow = rowCoverage
                end
                if #sampleRows < 12 then
                    sampleRows[#sampleRows + 1] = string.format("%.0f", rowCoverage)
                end
            end
        end

        local avgPairs = paintedRows > 0 and (totalPairsRows / paintedRows) or 0
        local covMean = paintedRows > 0 and (totalCoverageRows / paintedRows) or 0
        local covRange = (type(maxCoverageRow) == "number" and type(minCoverageRow) == "number") and (maxCoverageRow - minCoverageRow) or 0

        return {
            scannedRows = scannedRows,
            paintedRows = paintedRows,
            oddRows = oddRows,
            maxPairs = maxPairs,
            avgPairs = avgPairs,
            gapRows = gapRows,
            covMean = covMean,
            covRange = covRange,
            sampleSig = (#sampleRows > 0 and table.concat(sampleRows, ",")) or "none",
        }
    end
    for scanY = startY, endY, step do
        scannedRows = scannedRows + 1
        local intersections = {}
        for i = 1, #fillPoints - 1 do
            local x1 = px[i]
            local x2 = px[i + 1]
            if (x1 <= scanY and x2 > scanY) or (x2 <= scanY and x1 > scanY) then
                local y1 = py[i]
                local y2 = py[i + 1]
                local t = (scanY - x1) / (x2 - x1)
                intersections[#intersections + 1] = y1 + (t * (y2 - y1))
            end
        end

        table.sort(intersections)
        local originalIntersections = #intersections
        local deduped = {}
        for idx = 1, #intersections do
            local x = intersections[idx]
            local prev = deduped[#deduped]
            if type(prev) ~= "number" or math.abs(x - prev) > 0.10 then
                deduped[#deduped + 1] = x
            end
        end
        intersections = deduped
        dedupeRemoved = dedupeRemoved + math.max(0, originalIntersections - #intersections)
        if (#intersections % 2) ~= 0 then
            oddIntersectionRows = oddIntersectionRows + 1
            intersections[#intersections] = nil
        end
        local j = 1
        local rowPairs = 0
        local rowCoverage = 0
        while j < #intersections do
            local yStart = intersections[j]
            local yEnd = intersections[j + 1]
            if type(yStart) == "number" and type(yEnd) == "number" and yEnd > yStart then
                rowPairs = rowPairs + 1
                rowCoverage = rowCoverage + (yEnd - yStart)
                local painted = false
                local fillStroke = UI.AcquireMapAnnotationStrokeTexture(layer, host)
                if fillStroke then
                    fillStroke:ClearAllPoints()
                    if type(fillStroke.SetBlendMode) == "function" then
                        pcall(fillStroke.SetBlendMode, fillStroke, fillBlendMode)
                    end
                    if type(fillStroke.SetSnapToPixelGrid) == "function" then
                        pcall(fillStroke.SetSnapToPixelGrid, fillStroke, fillSnapToPixel)
                    end
                    if type(fillStroke.SetTexelSnappingBias) == "function" then
                        pcall(fillStroke.SetTexelSnappingBias, fillStroke, fillTexelBias)
                    end
                    fillStroke:SetSize(step, yEnd - yStart)
                    fillStroke:SetPoint("TOPLEFT", host, "TOPLEFT", (scanY + fillRowOffset), -(yStart))
                    if type(fillStroke.SetRotation) == "function" then
                        fillStroke:SetRotation(0)
                    end
                    fillStroke:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
                    fillStroke:SetVertexColor(r, g, b, fillAlpha)
                    painted = true
                    textureFillSegments = textureFillSegments + 1
                end

                if painted then
                    fillSegments = fillSegments + 1
                end
            end
            j = j + 2
        end

        if rowPairs > 0 then
            paintedRows = paintedRows + 1
            if #rowCoverageSamples < 12 then
                rowCoverageSamples[#rowCoverageSamples + 1] = string.format("%.0f", rowCoverage)
            end
            if not firstPaintedY then
                firstPaintedY = scanY
            end
            if type(previousPaintedY) == "number" and scanY > (previousPaintedY + step) then
                paintedGapRows = paintedGapRows + (scanY - previousPaintedY - step)
            end
            previousPaintedY = scanY
            lastPaintedY = scanY
            totalPairs = totalPairs + rowPairs
            if rowPairs > maxPairsPerRow then
                maxPairsPerRow = rowPairs
            end
            if minCoverage == nil or rowCoverage < minCoverage then
                minCoverage = rowCoverage
            end
            if maxCoverage == nil or rowCoverage > maxCoverage then
                maxCoverage = rowCoverage
            end
            totalCoverage = totalCoverage + rowCoverage
            if previousCoverage and math.abs(rowCoverage - previousCoverage) > (width * 0.16) then
                largeCoverageJumpRows = largeCoverageJumpRows + 1
            end
            if previousCoverage then
                local delta = rowCoverage - previousCoverage
                if previousDelta and (delta * previousDelta) < 0 and math.abs(delta) > 1.5 and math.abs(previousDelta) > 1.5 then
                    alternatingDeltaRows = alternatingDeltaRows + 1
                end
                previousDelta = delta
            end
            previousCoverage = rowCoverage
        end
    end

    if debandPassEnabled then
        debandStep = math.max(1, math.floor(step * 0.5))
        if debandStep >= step then
            debandStep = math.max(1, step - 1)
        end
        debandThickness = math.max(2, math.ceil(rasterThickness * 0.72))
        debandAlpha = fillAlpha * 0.42
        local debandOffset = debandStep * 0.5

        for scanY = math.floor(minY), math.ceil(maxY), debandStep do
            debandScans = debandScans + 1
            local intersections = {}
            for i = 1, #fillPoints - 1 do
                local y1 = py[i]
                local y2 = py[i + 1]
                if (y1 <= scanY and y2 > scanY) or (y2 <= scanY and y1 > scanY) then
                    local x1 = px[i]
                    local x2 = px[i + 1]
                    local t = (scanY - y1) / (y2 - y1)
                    intersections[#intersections + 1] = x1 + (t * (x2 - x1))
                end
            end

            table.sort(intersections)
            local deduped = {}
            for idx = 1, #intersections do
                local x = intersections[idx]
                local prev = deduped[#deduped]
                if type(prev) ~= "number" or math.abs(x - prev) > 0.10 then
                    deduped[#deduped + 1] = x
                end
            end
            intersections = deduped
            if (#intersections % 2) ~= 0 then
                intersections[#intersections] = nil
            end

            local j = 1
            while j < #intersections do
                local xStart = intersections[j]
                local xEnd = intersections[j + 1]
                if type(xStart) == "number" and type(xEnd) == "number" and xEnd > xStart then
                    local fillStroke = UI.AcquireMapAnnotationStrokeTexture(layer, host)
                    if fillStroke then
                        fillStroke:ClearAllPoints()
                        if type(fillStroke.SetBlendMode) == "function" then
                            pcall(fillStroke.SetBlendMode, fillStroke, "BLEND")
                        end
                        if type(fillStroke.SetSnapToPixelGrid) == "function" then
                            pcall(fillStroke.SetSnapToPixelGrid, fillStroke, true)
                        end
                        if type(fillStroke.SetTexelSnappingBias) == "function" then
                            pcall(fillStroke.SetTexelSnappingBias, fillStroke, 0)
                        end
                        fillStroke:SetSize(xEnd - xStart, debandThickness)
                        fillStroke:SetPoint("CENTER", host, "TOPLEFT", ((xStart + xEnd) * 0.5), -(scanY + debandOffset))
                        if type(fillStroke.SetRotation) == "function" then
                            fillStroke:SetRotation(0)
                        end
                        if type(fillStroke.SetColorTexture) == "function" then
                            fillStroke:SetColorTexture(r, g, b, debandAlpha)
                        else
                            fillStroke:SetVertexColor(r, g, b, debandAlpha)
                        end
                        debandSegments = debandSegments + 1
                    end
                end
                j = j + 2
            end
        end
    end

    if Util.ShouldEmitDebugToken("mapNoteFill:banding:" .. tostring(#fillPoints), 0.35) then
        local avgPairs = paintedRows > 0 and (totalPairs / paintedRows) or 0
        local jumpRatio = paintedRows > 0 and (largeCoverageJumpRows / paintedRows) or 0
        local altRatio = paintedRows > 0 and (alternatingDeltaRows / paintedRows) or 0
        local meanCoverage = paintedRows > 0 and (totalCoverage / paintedRows) or 0
        local coverageRange = (type(maxCoverage) == "number" and type(minCoverage) == "number") and (maxCoverage - minCoverage) or 0
        local coverageSpan = height > 0 and (meanCoverage / height) or 0
        local rowSig = (#rowCoverageSamples > 0 and table.concat(rowCoverageSamples, ",")) or "none"
        local horizontalProbe = ProbeHorizontalRows()
        local bandRisk = (oddIntersectionRows > 0) or (dedupeRemoved > 0) or (maxPairsPerRow > 2) or (jumpRatio > 0.10) or (aliasRisk == true)

        Runtime.annotation.fillPassState = Runtime.annotation.fillPassState or {}
        local passState = Runtime.annotation.fillPassState[noteKey]
        local passBurst = 1
        if type(passState) == "table" and type(passState.lastAt) == "number" and (now - passState.lastAt) <= 0.08 then
            passBurst = (passState.burst or 1) + 1
        end
        Runtime.annotation.fillPassState[noteKey] = {
            lastAt = now,
            burst = passBurst,
            lastAlpha = fillAlpha,
            lastWidth = width,
            lastHeight = height,
            lastPending = (type(debugMeta) == "table" and debugMeta.isPending == true) or false,
        }

        Util.MapAnnotationBandingLog(
            "fill:bandCheck",
            string.format(
                "axis=%s scans=%s painted=%s segments=%s odd=%s dedupeRemoved=%s maxPairs=%s avgPairs=%.2f jumpRows=%s jumpRatio=%.3f altRows=%s altRatio=%.3f scanRange=%s..%s gapScans=%s covMean=%.2f covRange=%.2f covSpan=%.3f secAxis=%s secScans=%s secPainted=%s secOdd=%s secMaxPairs=%s secAvgPairs=%.2f secGaps=%s secCovMean=%.2f secCovRange=%.2f host=(%s,%s) hostScale=%.4f uiScale=%.4f pixelScale=%.4f step=%s thickness=%s pitchScreen=%.3f pitchScreenFinal=%.3f thickScreen=%.3f aliasRisk=%s passes=%s debandEnabled=%s debandStep=%s debandThickness=%s debandAlpha=%s debandScans=%s debandSegments=%s primitive=%s lineSeg=%s texSeg=%s hybrid=%s overlayTexSeg=%s overlayTexAlpha=%s alpha=%s variant=%s abMode=%s abAuto=%s blend=%s snap=%s bias=%s rowOffset=%s lifecycle=%s lock=%s released=%s rowSig=%s secSig=%s hostId=%s hostLvl=%s layerId=%s layerLvl=%s noteId=%s pending=%s passBurst=%s bandRisk=%s",
                Util.SafeToString(fillOrientation),
                Util.SafeToString(scannedRows),
                Util.SafeToString(paintedRows),
                Util.SafeToString(fillSegments),
                Util.SafeToString(oddIntersectionRows),
                Util.SafeToString(dedupeRemoved),
                Util.SafeToString(maxPairsPerRow),
                avgPairs,
                Util.SafeToString(largeCoverageJumpRows),
                jumpRatio,
                Util.SafeToString(alternatingDeltaRows),
                altRatio,
                Util.SafeToString(firstPaintedY),
                Util.SafeToString(lastPaintedY),
                Util.SafeToString(paintedGapRows),
                meanCoverage,
                coverageRange,
                coverageSpan,
                "HORIZONTAL",
                Util.SafeToString(horizontalProbe.scannedRows),
                Util.SafeToString(horizontalProbe.paintedRows),
                Util.SafeToString(horizontalProbe.oddRows),
                Util.SafeToString(horizontalProbe.maxPairs),
                horizontalProbe.avgPairs,
                Util.SafeToString(horizontalProbe.gapRows),
                horizontalProbe.covMean,
                horizontalProbe.covRange,
                Util.FormatNumberPrecise(width),
                Util.FormatNumberPrecise(height),
                hostScale,
                uiScale,
                pixelScale,
                Util.SafeToString(step),
                Util.SafeToString(rasterThickness),
                pitchScreenPx,
                pitchScreenFinal,
                thicknessScreenPx,
                Util.SafeToString(aliasRisk),
                Util.SafeToString(totalPasses),
                Util.SafeToString(debandPassEnabled),
                Util.SafeToString(debandStep),
                Util.SafeToString(debandThickness),
                Util.FormatNumberPrecise(debandAlpha),
                Util.SafeToString(debandScans),
                Util.SafeToString(debandSegments),
                Util.SafeToString(fillPrimitive),
                Util.SafeToString(lineFillSegments),
                Util.SafeToString(textureFillSegments),
                Util.SafeToString(useLineFill and aliasRisk),
                Util.SafeToString(overlayTextureSegments),
                Util.FormatNumberPrecise(overlayTextureAlpha),
                Util.FormatNumberPrecise(fillAlpha),
                Util.SafeToString(fillVariant),
                Util.SafeToString(abMode),
                Util.SafeToString(abAuto),
                Util.SafeToString(fillBlendMode),
                Util.SafeToString(fillSnapToPixel),
                Util.SafeToString(fillTexelBias),
                Util.FormatNumberPrecise(fillRowOffset),
                Util.SafeToString(lifecycleKey),
                Util.SafeToString(lifecycleLock),
                Util.SafeToString(lockReleased),
                Util.SafeToString(rowSig),
                Util.SafeToString(horizontalProbe.sampleSig),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.hostId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.hostLevel or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.layerId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.layerLevel or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                Util.SafeToString(passBurst),
                Util.SafeToString(bandRisk)
            ),
            true
        )

        Util.MapAnnotationBandingLog(
            "fill:autoSummary",
            string.format(
                "noteId=%s pending=%s variant=%s auto=%s axis=%s lifecycle=%s lock=%s released=%s hostId=%s layerId=%s primitive=%s lineSeg=%s texSeg=%s hybrid=%s overlayTexSeg=%s overlayTexAlpha=%s step=%s thickness=%s pitchScreen=%.3f pitchScreenFinal=%.3f aliasRisk=%s passes=%s debandEnabled=%s debandStep=%s debandThickness=%s debandScans=%s debandSegments=%s primaryPairs=%s/%.2f primaryGaps=%s secondaryPairs=%s/%.2f secondaryGaps=%s passBurst=%s",
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                Util.SafeToString(fillVariant),
                Util.SafeToString(abAuto),
                Util.SafeToString(fillOrientation),
                Util.SafeToString(lifecycleKey),
                Util.SafeToString(lifecycleLock),
                Util.SafeToString(lockReleased),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.hostId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.layerId or nil),
                Util.SafeToString(fillPrimitive),
                Util.SafeToString(lineFillSegments),
                Util.SafeToString(textureFillSegments),
                Util.SafeToString(useLineFill and aliasRisk),
                Util.SafeToString(overlayTextureSegments),
                Util.FormatNumberPrecise(overlayTextureAlpha),
                Util.SafeToString(step),
                Util.SafeToString(rasterThickness),
                pitchScreenPx,
                pitchScreenFinal,
                Util.SafeToString(aliasRisk),
                Util.SafeToString(totalPasses),
                Util.SafeToString(debandPassEnabled),
                Util.SafeToString(debandStep),
                Util.SafeToString(debandThickness),
                Util.SafeToString(debandScans),
                Util.SafeToString(debandSegments),
                Util.SafeToString(maxPairsPerRow),
                avgPairs,
                Util.SafeToString(paintedGapRows),
                Util.SafeToString(horizontalProbe.maxPairs),
                horizontalProbe.avgPairs,
                Util.SafeToString(horizontalProbe.gapRows),
                Util.SafeToString(passBurst)
            ),
            true
        )

        Util.MapAnnotationBandingLog(
            "fill:residualAction",
            string.format(
                "noteId=%s pending=%s axis=%s variant=%s primitive=%s lineSeg=%s texSeg=%s hybrid=%s overlayTexSeg=%s overlayTexAlpha=%s blend=%s snap=%s bias=%s pixelScale=%.4f step=%s thickness=%s pitchScreen=%.3f pitchScreenFinal=%.3f thickScreen=%.3f aliasRisk=%s passes=%s debandEnabled=%s debandStep=%s debandThickness=%s debandScans=%s debandSegments=%s primaryPairs=%s/%.2f primaryGaps=%s secondaryPairs=%s/%.2f secondaryGaps=%s suggest=%s nextDebug=%s",
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                Util.SafeToString(fillOrientation),
                Util.SafeToString(fillVariant),
                Util.SafeToString(fillPrimitive),
                Util.SafeToString(lineFillSegments),
                Util.SafeToString(textureFillSegments),
                Util.SafeToString(useLineFill and aliasRisk),
                Util.SafeToString(overlayTextureSegments),
                Util.FormatNumberPrecise(overlayTextureAlpha),
                Util.SafeToString(fillBlendMode),
                Util.SafeToString(fillSnapToPixel),
                Util.SafeToString(fillTexelBias),
                pixelScale,
                Util.SafeToString(step),
                Util.SafeToString(rasterThickness),
                pitchScreenPx,
                pitchScreenFinal,
                thicknessScreenPx,
                Util.SafeToString(aliasRisk),
                Util.SafeToString(totalPasses),
                Util.SafeToString(debandPassEnabled),
                Util.SafeToString(debandStep),
                Util.SafeToString(debandThickness),
                Util.SafeToString(debandScans),
                Util.SafeToString(debandSegments),
                Util.SafeToString(maxPairsPerRow),
                avgPairs,
                Util.SafeToString(paintedGapRows),
                Util.SafeToString(horizontalProbe.maxPairs),
                horizontalProbe.avgPairs,
                Util.SafeToString(horizontalProbe.gapRows),
                ((maxPairsPerRow <= 1 and paintedGapRows == 0 and horizontalProbe.maxPairs <= 1 and horizontalProbe.gapRows == 0 and aliasRisk == false) and "compositor_path_only" or "scan_fragmentation_or_alias"),
                ((textureFillSegments <= 0) and "verify_texture_pool_and_host_size" or "if_still_striped_try_blend_ADD_then_compare")
            ),
            true
        )

        Util.MapAnnotationBandingLog(
                "fill:debugPlan",
                string.format(
                "noteId=%s pending=%s axis=%s variant=%s plan=1)confirm_primitive=TEXTURE_SOLID and lineSeg=0 2)confirm_texSeg_tracks_segments 3)if_texSeg_low verify host/layer size > 1 4)if_still_striped compare blend=BLEND vs ADD",
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                Util.SafeToString(fillOrientation),
                Util.SafeToString(fillVariant)
            ),
            true
        )

        if fillSegments <= 0 or textureFillSegments <= 0 then
            Util.MapAnnotationBandingLog(
                "fill:coverageGuard",
                string.format(
                    "noteId=%s pending=%s primitive=%s scans=%s paintedRows=%s segments=%s texSeg=%s lineSeg=%s host=(%s,%s) pixelScale=%.4f step=%s thickness=%s",
                    Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                    Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                    Util.SafeToString(fillPrimitive),
                    Util.SafeToString(scannedRows),
                    Util.SafeToString(paintedRows),
                    Util.SafeToString(fillSegments),
                    Util.SafeToString(textureFillSegments),
                    Util.SafeToString(lineFillSegments),
                    Util.FormatNumberPrecise(width),
                    Util.FormatNumberPrecise(height),
                    pixelScale,
                    Util.SafeToString(step),
                    Util.SafeToString(rasterThickness)
                ),
                true
            )
        end

        Runtime.annotation.fillVariantCompare = Runtime.annotation.fillVariantCompare or {}
        local compareStore = Runtime.annotation.fillVariantCompare
        local comparePrev = compareStore[noteKey]
        local currentProfile = {
            at = now,
            variant = fillVariant,
            pMax = maxPairsPerRow,
            pAvg = avgPairs,
            pGaps = paintedGapRows,
            sMax = horizontalProbe.maxPairs,
            sAvg = horizontalProbe.avgPairs,
            sGaps = horizontalProbe.gapRows,
            passBurst = passBurst,
        }
        if type(comparePrev) == "table" and comparePrev.variant ~= fillVariant and type(comparePrev.at) == "number" and (now - comparePrev.at) <= 1.20 then
            Util.MapAnnotationBandingLog(
                "fill:autoABCompare",
                string.format(
                    "noteId=%s pending=%s %s(primary=%s/%.2f gaps=%s secondary=%s/%.2f gaps=%s) vs %s(primary=%s/%.2f gaps=%s secondary=%s/%.2f gaps=%s) burst=%s->%s dt=%.3f",
                    Util.SafeToString(type(debugMeta) == "table" and debugMeta.noteId or nil),
                    Util.SafeToString(type(debugMeta) == "table" and debugMeta.isPending == true),
                    Util.SafeToString(comparePrev.variant),
                    Util.SafeToString(comparePrev.pMax),
                    comparePrev.pAvg or 0,
                    Util.SafeToString(comparePrev.pGaps),
                    Util.SafeToString(comparePrev.sMax),
                    comparePrev.sAvg or 0,
                    Util.SafeToString(comparePrev.sGaps),
                    Util.SafeToString(currentProfile.variant),
                    Util.SafeToString(currentProfile.pMax),
                    currentProfile.pAvg,
                    Util.SafeToString(currentProfile.pGaps),
                    Util.SafeToString(currentProfile.sMax),
                    currentProfile.sAvg,
                    Util.SafeToString(currentProfile.sGaps),
                    Util.SafeToString(comparePrev.passBurst),
                    Util.SafeToString(currentProfile.passBurst),
                    now - comparePrev.at
                ),
                true
            )
            compareStore[noteKey] = nil
        else
            compareStore[noteKey] = currentProfile
        end
    end
    return fillSegments > 0
end

function UI.DrawMapAnnotation(layer, host, note, isPending)
    if not layer or not host or type(note) ~= "table" then return end
    if type(note.points) ~= "table" or #note.points == 0 then return end
    local linesBefore = (type(layer._muiActiveLines) == "table") and #layer._muiActiveLines or 0
    local dotsBefore = (type(layer._muiActiveDots) == "table") and #layer._muiActiveDots or 0
    local hitsBefore = (type(layer._muiActiveHitButtons) == "table") and #layer._muiActiveHitButtons or 0
    local strokesBefore = (type(layer._muiActiveStrokes) == "table") and #layer._muiActiveStrokes or 0

    local width = host:GetWidth()
    local height = host:GetHeight()
    if type(width) ~= "number" or type(height) ~= "number" or width <= 1 or height <= 1 then
        Util.MapAnnotationRenderLog(
            "draw:skipHostSize",
            string.format("pending=%s points=%s hostSize=(%s,%s) host=%s",
                Util.SafeToString(isPending == true),
                Util.SafeToString(#note.points),
                Util.FormatNumberPrecise(width),
                Util.FormatNumberPrecise(height),
                Util.SafeToString(host:GetName())
            ),
            true
        )
        return
    end

    local color = note.color
    local r = type(color) == "table" and color[1] or 0.98
    local g = type(color) == "table" and color[2] or 0.82
    local b = type(color) == "table" and color[3] or 0.24
    local baseAlpha = type(color) == "table" and color[4] or 0.42
    local a = baseAlpha
    if isPending then
        a = math.max(0.25, baseAlpha + 0.18)
    end
    local isClosedShape = (note.isClosedShape == true)

    if #note.points == 1 then
        -- Icon-only; the atlas icon is rendered on the hit button below
    else
        local renderPoints = note.points
        if isClosedShape then
            renderPoints = UI.BuildMapAnnotationRenderPoints(note.points, true) or note.points
        end

        for i = 2, #renderPoints do
            local p1 = renderPoints[i - 1]
            local p2 = renderPoints[i]
            local line = UI.AcquireMapAnnotationLine(layer, host)
            if line then
                line:SetStartPoint("TOPLEFT", host, "TOPLEFT", p1.x * width, -(p1.y * height))
                line:SetEndPoint("TOPLEFT", host, "TOPLEFT", p2.x * width, -(p2.y * height))
                line:SetColorTexture(r, g, b, math.min(0.96, a + 0.34))
                line:SetThickness(4)
            end
            if not isClosedShape then
                UI.DrawMapAnnotationStrokeFallback(layer, host, p1, p2, r, g, b, a, 5)
            end
        end

        local first = renderPoints[1]
        local last = renderPoints[#renderPoints]
        local firstDot = UI.AcquireMapAnnotationDot(layer, host)
        if firstDot then
            firstDot:SetSize(5, 5)
            firstDot:SetPoint("CENTER", host, "TOPLEFT", first.x * width, -(first.y * height))
            firstDot:SetVertexColor(r, g, b, math.min(0.88, a + 0.28))
        end
        local lastDot = UI.AcquireMapAnnotationDot(layer, host)
        if lastDot then
            lastDot:SetSize(6, 6)
            lastDot:SetPoint("CENTER", host, "TOPLEFT", last.x * width, -(last.y * height))
            lastDot:SetVertexColor(r, g, b, math.min(0.90, a + 0.30))
        end

        if isClosedShape then
            local stableFillAlpha = math.min(0.34, math.max(0.28, baseAlpha * 0.78))
            local debugTraceKey = note._muiDebugTraceKey
            if type(debugTraceKey) ~= "string" or debugTraceKey == "" then
                debugTraceKey = string.format("trace:%s:%s", Util.SafeToString(note.mapID), Util.SafeToString(note.id or "pending"))
            end
            local fillOk = UI.DrawMapAnnotationFill(layer, host, renderPoints, r, g, b, stableFillAlpha, {
                noteId = note.id,
                isPending = (isPending == true),
                noteKey = string.format("%s:%s", Util.SafeToString(note.mapID), Util.SafeToString(debugTraceKey)),
                lifecycleKey = debugTraceKey,
                hostId = Util.GetFrameDebugIdentity(host),
                hostLevel = host and type(host.GetFrameLevel) == "function" and host:GetFrameLevel() or nil,
                layerId = Util.GetFrameDebugIdentity(layer),
                layerLevel = layer and type(layer.GetFrameLevel) == "function" and layer:GetFrameLevel() or nil,
            })
            if not fillOk and isPending and note._muiFillFailureNotified ~= true then
                note._muiFillFailureNotified = true
                UI.ReportMapAnnotationError("Couldn't complete the connection for your shape.")
            end
        end
    end

    if not isPending then
        local minX, maxX = 1, 0
        local minY, maxY = 1, 0
        for i = 1, #note.points do
            local p = note.points[i]
            if p.x < minX then minX = p.x end
            if p.x > maxX then maxX = p.x end
            if p.y < minY then minY = p.y end
            if p.y > maxY then maxY = p.y end
        end
        note._muiBounds = { minX = minX, maxX = maxX, minY = minY, maxY = maxY }

        local button = UI.AcquireMapAnnotationHitButton(layer, host)
        if button then
            button:ClearAllPoints()
            if #note.points == 1 then
                local point = note.points[1]
                button:SetPoint("CENTER", host, "TOPLEFT", point.x * width, -(point.y * height))
                button:SetSize(144, 144)
                if button._muiPointIcon then
                    if type(button._muiPointIcon.SetAtlas) == "function" then
                        pcall(button._muiPointIcon.SetAtlas, button._muiPointIcon, "CovenantSanctum-Resevoir-Full-Kyrian")
                    end
                    button._muiPointIcon:SetSize(114, 114)
                    button._muiPointIcon:Show()
                end
            else
                local left = minX * width - 12
                local top = minY * height - 12
                local regionW = math.max(24, (maxX - minX) * width + 24)
                local regionH = math.max(24, (maxY - minY) * height + 24)
                button:SetPoint("TOPLEFT", host, "TOPLEFT", left, -top)
                button:SetSize(regionW, regionH)
                if button._muiPointIcon then
                    button._muiPointIcon:Hide()
                end
            end
            button._muiAnnotationNote = note
        end
    end

    if Util.ShouldEmitDebugToken("mapNoteRender:draw:" .. Util.SafeToString(isPending == true), 0.08) then
        local linesAfter = (type(layer._muiActiveLines) == "table") and #layer._muiActiveLines or 0
        local dotsAfter = (type(layer._muiActiveDots) == "table") and #layer._muiActiveDots or 0
        local hitsAfter = (type(layer._muiActiveHitButtons) == "table") and #layer._muiActiveHitButtons or 0
        local strokesAfter = (type(layer._muiActiveStrokes) == "table") and #layer._muiActiveStrokes or 0
        Util.MapAnnotationRenderLog(
            "draw:done",
            string.format(
                "pending=%s noteId=%s points=%s closed=%s host=%s hostSize=(%s,%s) +lines=%s +dots=%s +hits=%s +strokes=%s totals lines=%s dots=%s hits=%s strokes=%s",
                Util.SafeToString(isPending == true),
                Util.SafeToString(note.id),
                Util.SafeToString(#note.points),
                Util.SafeToString(note.isClosedShape == true),
                Util.SafeToString(host:GetName()),
                Util.FormatNumberPrecise(width),
                Util.FormatNumberPrecise(height),
                Util.SafeToString(linesAfter - linesBefore),
                Util.SafeToString(dotsAfter - dotsBefore),
                Util.SafeToString(hitsAfter - hitsBefore),
                Util.SafeToString(strokesAfter - strokesBefore),
                Util.SafeToString(linesAfter),
                Util.SafeToString(dotsAfter),
                Util.SafeToString(hitsAfter),
                Util.SafeToString(strokesAfter)
            ),
            false
        )
    end
end

local function BuildMapAnnotationRenderSignature(note)
    if type(note) ~= "table" or type(note.points) ~= "table" or #note.points < 1 then
        return nil
    end

    local first = note.points[1]
    local last = note.points[#note.points]
    if type(first) ~= "table" or type(last) ~= "table" then
        return nil
    end

    local cx, cy = UI.ComputeMapAnnotationCentroid(note.points)
    return string.format(
        "map=%s|count=%s|first=%.4f,%.4f|last=%.4f,%.4f|center=%.4f,%.4f|closed=%s",
        Util.SafeToString(note.mapID),
        Util.SafeToString(#note.points),
        Util.Clamp(first.x or 0, 0, 1),
        Util.Clamp(first.y or 0, 0, 1),
        Util.Clamp(last.x or 0, 0, 1),
        Util.Clamp(last.y or 0, 0, 1),
        Util.Clamp(cx or 0, 0, 1),
        Util.Clamp(cy or 0, 0, 1),
        Util.SafeToString(note.isClosedShape == true)
    )
end

function UI.RenderMapAnnotations(map)
    if not map then return end
    local layer = UI.EnsureMapAnnotationLayer(map)
    if not layer then return end

    UI.ReleaseMapAnnotationVisuals(layer)

    local mapID = UI.GetActiveMapID(map)
    local store = UI.GetMapAnnotationStore()
    local renderedSavedCount = 0
    local renderedSignatures = {}
    if type(store.entries) == "table" and type(mapID) == "number" then
        for i = 1, #store.entries do
            local note = store.entries[i]
            if type(note) == "table" and note.hidden ~= true and note.mapID == mapID then
                UI.DrawMapAnnotation(layer, layer._muiSavedHost or layer, note, false)
                renderedSavedCount = renderedSavedCount + 1

                if type(note._muiDebugTraceKey) == "string" and note._muiDebugTraceKey ~= "" then
                    renderedSignatures["trace:" .. note._muiDebugTraceKey] = true
                end
                local savedSignature = BuildMapAnnotationRenderSignature(note)
                if type(savedSignature) == "string" and savedSignature ~= "" then
                    renderedSignatures["sig:" .. savedSignature] = true
                end
            end
        end
    end

    local renderedPending = false
    local pending = Runtime.annotation and Runtime.annotation.pending or nil
    if type(pending) == "table" and pending.mapID == mapID and type(pending.points) == "table" and #pending.points > 0 then
        local pendingIsDuplicate = false
        if type(pending._muiDebugTraceKey) == "string" and pending._muiDebugTraceKey ~= "" and renderedSignatures["trace:" .. pending._muiDebugTraceKey] then
            pendingIsDuplicate = true
        end
        if not pendingIsDuplicate then
            local pendingSignature = BuildMapAnnotationRenderSignature(pending)
            if type(pendingSignature) == "string" and pendingSignature ~= "" and renderedSignatures["sig:" .. pendingSignature] then
                pendingIsDuplicate = true
            end
        end

        if pendingIsDuplicate then
            Util.MapAnnotationBandingLog(
                "render:pendingDeduped",
                string.format(
                    "mapID=%s pendingTrace=%s pendingSig=%s reason=matchesSaved",
                    Util.SafeToString(mapID),
                    Util.SafeToString(pending._muiDebugTraceKey),
                    Util.SafeToString(BuildMapAnnotationRenderSignature(pending))
                ),
                true
            )
        else
            UI.DrawMapAnnotation(layer, layer._muiPendingHost or layer, pending, true)
            renderedPending = true
        end
    end

    if Util.ShouldEmitDebugToken("mapNoteRender:frame", 0.08) then
        local pendingHost = layer._muiPendingHost or layer
        local savedHost = layer._muiSavedHost or layer
        local totalEntries = type(store.entries) == "table" and #store.entries or 0
        local activeLines = (type(layer._muiActiveLines) == "table") and #layer._muiActiveLines or 0
        local activeDots = (type(layer._muiActiveDots) == "table") and #layer._muiActiveDots or 0
        local activeHits = (type(layer._muiActiveHitButtons) == "table") and #layer._muiActiveHitButtons or 0
        local activeStrokes = (type(layer._muiActiveStrokes) == "table") and #layer._muiActiveStrokes or 0
        Util.MapAnnotationRenderLog(
            "render:summary",
            string.format(
                "mapID=%s totalEntries=%s savedRendered=%s pendingRendered=%s pendingPoints=%s layerLevel=%s canvasSize=(%s,%s) pendingHostSize=(%s,%s) savedHostSize=(%s,%s) active lines=%s dots=%s hits=%s strokes=%s",
                Util.SafeToString(mapID),
                Util.SafeToString(totalEntries),
                Util.SafeToString(renderedSavedCount),
                Util.SafeToString(renderedPending),
                Util.SafeToString(type(pending) == "table" and type(pending.points) == "table" and #pending.points or 0),
                Util.SafeToString(layer:GetFrameLevel()),
                Util.FormatNumberPrecise(layer:GetWidth()),
                Util.FormatNumberPrecise(layer:GetHeight()),
                Util.FormatNumberPrecise(pendingHost:GetWidth()),
                Util.FormatNumberPrecise(pendingHost:GetHeight()),
                Util.FormatNumberPrecise(savedHost:GetWidth()),
                Util.FormatNumberPrecise(savedHost:GetHeight()),
                Util.SafeToString(activeLines),
                Util.SafeToString(activeDots),
                Util.SafeToString(activeHits),
                Util.SafeToString(activeStrokes)
            ),
            false
        )
    end
end

function UI.CancelPendingMapAnnotation(map, reason)
    if Runtime.annotation then
        local pending = Runtime.annotation.pending
        if type(pending) == "table" and type(pending._muiDebugTraceKey) == "string" then
            local locks = Runtime.annotation.fillABState and Runtime.annotation.fillABState.locks
            if type(locks) == "table" then
                locks[pending._muiDebugTraceKey] = nil
            end
        end
        Runtime.annotation.pending = nil
        Runtime.annotation.captureActive = false
    end

    local editor = map and map._muiAnnotationEditor or nil
    if editor and editor:IsShown() then
        editor:Hide()
    end

    UI.RenderMapAnnotations(map or _G.WorldMapFrame)
end

function UI.CommitPendingMapAnnotation(map)
    local pending = Runtime.annotation and Runtime.annotation.pending or nil
    if type(pending) ~= "table" or type(pending.points) ~= "table" or #pending.points < 1 then
        UI.CancelPendingMapAnnotation(map, "commitMissingPending")
        return
    end

    local editor = map and map._muiAnnotationEditor or nil
    local title = ""
    local description = ""
    local pickedColor = nil
    local noteType = nil
    if editor then
        if editor._muiHeaderInput and type(editor._muiHeaderInput.GetText) == "function" then
            title = editor._muiHeaderInput:GetText() or ""
        end
        if editor._muiDescriptionInput and type(editor._muiDescriptionInput.GetText) == "function" then
            description = editor._muiDescriptionInput:GetText() or ""
        end
        if type(editor._muiGetSelectedNoteType) == "function" then
            noteType = editor._muiGetSelectedNoteType()
        end
        pickedColor = editor._muiPendingColor
    end
    if type(noteType) ~= "string" or noteType == "" then
        noteType = _G.GENERAL or "General"
    end

    local points = UI.CopyMapAnnotationPoints(pending.points)
    local centerX, centerY = UI.ComputeMapAnnotationCentroid(points)
    local color = pickedColor or pending.color or { UI.GetMapAnnotationDefaultColor() }
    local store = UI.GetMapAnnotationStore()
    local id = store.nextId
    store.nextId = store.nextId + 1

    store.entries[#store.entries + 1] = {
        id = id,
        mapID = pending.mapID,
        x = centerX,
        y = centerY,
        points = points,
        isPath = (#points > 1),
        isClosedShape = (pending.isClosedShape == true),
        color = { color[1] or 0.98, color[2] or 0.82, color[3] or 0.24, color[4] or 0.42 },
        title = title,
        description = description,
        noteType = noteType,
        locationLabel = pending.locationLabel,
        hidden = false,
        _muiDebugTraceKey = pending._muiDebugTraceKey,
    }

    Runtime.annotation.pending = nil
    Runtime.annotation.captureActive = false
    if editor then editor:Hide() end
    UI.RenderMapAnnotations(map or _G.WorldMapFrame)
end

local MAP_NOTE_TYPE_OPTIONS = {
    _G.GENERAL or "General",
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.ALCHEMY or "Alchemy"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.BLACKSMITHING or "Blacksmithing"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.ENCHANTING or "Enchanting"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.ENGINEERING or "Engineering"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.HERBALISM or "Herbalism"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.INSCRIPTION or "Inscription"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.JEWELCRAFTING or "Jewelcrafting"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.LEATHERWORKING or "Leatherworking"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.MINING or "Mining"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.SKINNING or "Skinning"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.TAILORING or "Tailoring"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.COOKING or "Cooking"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.FISHING or "Fishing"),
    string.format("%s - %s", _G.PROFESSIONS or "Professions", _G.ARCHAEOLOGY or "Archaeology"),
    _G.WORLD_QUESTS or "World Quests",
    (_G.RARE or "Rare") .. " " .. (_G.SPAWNS or "Spawns"),
    _G.TREASURES or "Treasures",
    (_G.WEEKLY or "Weekly") .. " " .. (_G.QUESTS_LABEL or "Objectives"),
    (_G.PVP or "PvP") .. " " .. (_G.OBJECTIVES_TRACKER_LABEL or "Objectives"),
    _G.CALENDAR_FILTER_EVENTS or "Event Spawn",
    "World Boss",
    "Weekly Event Objective",
    "Reputation Grind Spot",
    "Dungeon/Scenario Entrance",
    "Rare Elite Patrol",
    "Treasure Puzzle",
    "Mount/Pet Spawn",
    "Transmog Farm",
    "Achievement Objective",
    "Quest Chain Step",
    "Portal/Teleport Point",
    "War Supply Crate (PvP)",
    "Summon Stone / Group Spot",
    "Safe Logout / Hearth Hub",
    "Farm Route",
    "Group Meetup",
}

local function NormalizeMapNoteType(value)
    if type(value) ~= "string" or value == "" then
        return MAP_NOTE_TYPE_OPTIONS[1]
    end
    return value
end

function UI.EnsureMapAnnotationEditor(map)
    if not map then return nil end
    local frame = map._muiAnnotationEditor
    if frame then return frame end

    frame = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    frame:SetSize(340, 352)
    frame:SetFrameStrata("DIALOG")
    frame:SetFrameLevel(220)
    frame:EnableMouse(true)
    frame:SetMovable(false)
    if type(frame.SetBackdrop) == "function" then
        frame:SetBackdrop({
            bgFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        frame:SetBackdropColor(0.05, 0.07, 0.10, 0.96)
        frame:SetBackdropBorderColor(0.42, 0.47, 0.55, 0.90)
    end
    frame:Hide()

    -- ESC to close
    frame:EnableKeyboard(true)
    frame:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -10)
    title:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -10)
    title:SetJustifyH("LEFT")
    title:SetText("Place Note")
    frame._muiHeader = title

    local colorLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    colorLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -34)
    colorLabel:SetText("Color")
    frame._muiColorLabel = colorLabel

    local colorSwatch = CreateFrame("Button", nil, frame, "BackdropTemplate")
    colorSwatch:SetSize(24, 18)
    colorSwatch:SetPoint("LEFT", colorLabel, "RIGHT", 8, 0)
    if type(colorSwatch.SetBackdrop) == "function" then
        colorSwatch:SetBackdrop({
            bgFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        colorSwatch:SetBackdropBorderColor(0.8, 0.8, 0.8, 0.85)
    end
    frame._muiColorSwatch = colorSwatch
    local swatchFill = colorSwatch:CreateTexture(nil, "ARTWORK")
    swatchFill:SetPoint("TOPLEFT", colorSwatch, "TOPLEFT", 1, -1)
    swatchFill:SetPoint("BOTTOMRIGHT", colorSwatch, "BOTTOMRIGHT", -1, 1)
    swatchFill:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
    frame._muiColorFill = swatchFill

    local headerLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    headerLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -58)
    headerLabel:SetText("Header")
    frame._muiHeaderLabel = headerLabel

    local headerInput = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    headerInput:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -74)
    headerInput:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -74)
    headerInput:SetHeight(22)
    headerInput:SetAutoFocus(false)
    headerInput:SetMaxLetters(96)
    headerInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    frame._muiHeaderInput = headerInput

    local noteTypeLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    noteTypeLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -104)
    noteTypeLabel:SetText(_G.TYPE or "Type")
    frame._muiNoteTypeLabel = noteTypeLabel

    if type(_G.UIDropDownMenu_Initialize) ~= "function" and not InCombatLockdown() then
        if type(C_AddOns) == "table" and type(C_AddOns.LoadAddOn) == "function" then
            pcall(C_AddOns.LoadAddOn, "Blizzard_UIDropDownMenu")
        elseif type(_G.LoadAddOn) == "function" then
            pcall(_G.LoadAddOn, "Blizzard_UIDropDownMenu")
        end
    end

    local selectedNoteType = MAP_NOTE_TYPE_OPTIONS[1]
    local noteTypeDropdown = nil
    if type(_G.UIDropDownMenu_Initialize) == "function"
        and type(_G.UIDropDownMenu_CreateInfo) == "function"
        and type(_G.UIDropDownMenu_AddButton) == "function"
        and type(_G.UIDropDownMenu_SetWidth) == "function"
        and type(_G.UIDropDownMenu_SetText) == "function" then
        noteTypeDropdown = CreateFrame("Frame", nil, frame, "UIDropDownMenuTemplate")
        noteTypeDropdown:SetPoint("TOPLEFT", frame, "TOPLEFT", -4, -116)
        _G.UIDropDownMenu_SetWidth(noteTypeDropdown, 288)
        _G.UIDropDownMenu_SetText(noteTypeDropdown, selectedNoteType)
        _G.UIDropDownMenu_Initialize(noteTypeDropdown, function(_, level)
            for i = 1, #MAP_NOTE_TYPE_OPTIONS do
                local option = MAP_NOTE_TYPE_OPTIONS[i]
                local optionValue = option
                local info = _G.UIDropDownMenu_CreateInfo()
                info.text = optionValue
                info.checked = (selectedNoteType == optionValue)
                info.func = function()
                    selectedNoteType = optionValue
                    _G.UIDropDownMenu_SetText(noteTypeDropdown, selectedNoteType)
                end
                info.notCheckable = false
                _G.UIDropDownMenu_AddButton(info, level)
            end
        end)
    end
    frame._muiNoteTypeDropdown = noteTypeDropdown

    frame._muiSetSelectedNoteType = function(value)
        selectedNoteType = NormalizeMapNoteType(value)
        if noteTypeDropdown and type(_G.UIDropDownMenu_SetText) == "function" then
            _G.UIDropDownMenu_SetText(noteTypeDropdown, selectedNoteType)
        end
    end
    frame._muiGetSelectedNoteType = function()
        return NormalizeMapNoteType(selectedNoteType)
    end

    local descriptionLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    descriptionLabel:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -144)
    descriptionLabel:SetText(_G.DESCRIPTION or "Description")
    frame._muiDescriptionLabel = descriptionLabel

    local descriptionBox = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    descriptionBox:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -160)
    descriptionBox:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -12, -160)
    descriptionBox:SetHeight(140)
    if type(descriptionBox.SetBackdrop) == "function" then
        descriptionBox:SetBackdrop({
            bgFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeFile = C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        descriptionBox:SetBackdropColor(0.02, 0.03, 0.05, 0.86)
        descriptionBox:SetBackdropBorderColor(0.36, 0.41, 0.48, 0.90)
    end
    frame._muiDescriptionBox = descriptionBox

    local descriptionScroll = CreateFrame("ScrollFrame", nil, descriptionBox, "UIPanelScrollFrameTemplate")
    descriptionScroll:SetPoint("TOPLEFT", descriptionBox, "TOPLEFT", 4, -4)
    descriptionScroll:SetPoint("BOTTOMRIGHT", descriptionBox, "BOTTOMRIGHT", -26, 4)
    descriptionScroll:EnableMouseWheel(true)
    frame._muiDescriptionScroll = descriptionScroll

    local descriptionInput = CreateFrame("EditBox", nil, descriptionScroll)
    descriptionInput:SetPoint("TOPLEFT", descriptionScroll, "TOPLEFT", 0, 0)
    descriptionInput:SetWidth(220)
    descriptionInput:SetHeight(128)
    descriptionInput:EnableMouse(true)
    descriptionInput:SetMultiLine(true)
    descriptionInput:SetAutoFocus(false)
    descriptionInput:SetMaxLetters(1024)
    descriptionInput:SetFontObject(GameFontHighlightSmall)
    descriptionInput:SetJustifyH("LEFT")
    descriptionInput:SetJustifyV("TOP")
    descriptionInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    descriptionInput:SetScript("OnEnterPressed", function(self) self:Insert("\n") end)
    descriptionInput:SetScript("OnMouseDown", function(self)
        self:SetFocus()
    end)
    descriptionInput:SetScript("OnTextChanged", function(self)
        local textHeight = (self.GetStringHeight and self:GetStringHeight() or 0) + 18
        if textHeight < 128 then textHeight = 128 end
        if textHeight > 4096 then textHeight = 4096 end
        self:SetHeight(textHeight)
    end)
    descriptionInput:SetScript("OnCursorChanged", function(self, _, y, _, height)
        local scroll = self._muiParentScroll
        if not scroll then return end
        local cursorTop = -y
        local current = scroll:GetVerticalScroll() or 0
        local visibleBottom = current + (scroll:GetHeight() or 0)
        local cursorBottom = cursorTop + (height or 0)
        if cursorTop < current then
            scroll:SetVerticalScroll(cursorTop)
        elseif cursorBottom > visibleBottom then
            scroll:SetVerticalScroll(cursorBottom - (scroll:GetHeight() or 0))
        end
    end)
    descriptionInput._muiParentScroll = descriptionScroll
    descriptionScroll:SetScrollChild(descriptionInput)
    descriptionScroll:SetScript("OnSizeChanged", function(self, width)
        local targetWidth = (type(width) == "number" and width or self:GetWidth() or 220)
        if targetWidth < 120 then targetWidth = 120 end
        descriptionInput:SetWidth(targetWidth)
    end)
    descriptionBox:SetScript("OnMouseDown", function()
        if descriptionInput and type(descriptionInput.SetFocus) == "function" then
            descriptionInput:SetFocus()
        end
    end)
    descriptionScroll:SetScript("OnMouseWheel", function(self, delta)
        local step = 20
        local current = self:GetVerticalScroll() or 0
        local maxScroll = math.max(0, (descriptionInput:GetHeight() or 0) - (self:GetHeight() or 0))
        if delta > 0 then
            self:SetVerticalScroll(math.max(0, current - step))
        else
            self:SetVerticalScroll(math.min(maxScroll, current + step))
        end
    end)
    if type(descriptionScroll.GetWidth) == "function" then
        local initialWidth = descriptionScroll:GetWidth() or 220
        if initialWidth < 120 then initialWidth = 120 end
        descriptionInput:SetWidth(initialWidth)
    end
    frame._muiDescriptionInput = descriptionInput

    local function StyleAnnotationButton(b)
        if not b then return end
        if b.Left then b.Left:Hide() end
        if b.Middle then b.Middle:Hide() end
        if b.Right then b.Right:Hide() end
        local border = b:CreateTexture(nil, "BACKGROUND")
        border:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
        border:SetVertexColor(0.42, 0.47, 0.55, 1.0)
        border:SetPoint("TOPLEFT", 0, 0)
        border:SetPoint("BOTTOMRIGHT", 0, 0)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
        bg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
        bg:SetPoint("TOPLEFT", 2, -2)
        bg:SetPoint("BOTTOMRIGHT", -2, 2)
        local sheen = b:CreateTexture(nil, "ARTWORK")
        sheen:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
        sheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
        sheen:SetPoint("TOPLEFT", 3, -3)
        sheen:SetPoint("BOTTOMRIGHT", -3, 12)
        local hover = b:CreateTexture(nil, "HIGHLIGHT")
        hover:SetTexture(C.WHITE8X8 or "Interface\\Buttons\\WHITE8X8")
        hover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
        hover:SetPoint("TOPLEFT", 2, -2)
        hover:SetPoint("BOTTOMRIGHT", -2, 2)
    end

    local cancelButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    cancelButton:SetPoint("BOTTOM", frame, "BOTTOM", -68, 12)
    cancelButton:SetSize(124, 28)
    cancelButton:SetText(_G.CANCEL or "Cancel")
    cancelButton:SetScript("OnClick", function()
        UI.CancelPendingMapAnnotation(frame._muiOwnerMap or _G.WorldMapFrame, "editorCancel")
    end)
    StyleAnnotationButton(cancelButton)

    local saveButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    saveButton:SetPoint("BOTTOM", frame, "BOTTOM", 68, 12)
    saveButton:SetSize(124, 28)
    saveButton:SetText(_G.SAVE or "Save")
    saveButton:SetScript("OnClick", function()
        UI.CommitPendingMapAnnotation(frame._muiOwnerMap or _G.WorldMapFrame)
    end)
    StyleAnnotationButton(saveButton)

    local function ApplyColorSwatch(r, g, b, a)
        local alpha = (type(a) == "number") and a or 0.42
        frame._muiPendingColor = { r, g, b, alpha }
        swatchFill:SetVertexColor(r, g, b, math.min(0.92, alpha + 0.25))
    end

    colorSwatch:SetScript("OnClick", function()
        local current = frame._muiPendingColor or { UI.GetMapAnnotationDefaultColor() }
        if ColorPickerFrame and type(ColorPickerFrame.SetupColorPickerAndShow) == "function" then
            local info = {
                r = current[1],
                g = current[2],
                b = current[3],
                hasOpacity = false,
                swatchFunc = function()
                    local r, g, b = ColorPickerFrame:GetColorRGB()
                    ApplyColorSwatch(r, g, b, current[4])
                end,
                cancelFunc = function(previousValues)
                    if type(previousValues) == "table" then
                        ApplyColorSwatch(previousValues.r, previousValues.g, previousValues.b, current[4])
                    end
                end,
            }
            ColorPickerFrame:SetupColorPickerAndShow(info)
            return
        end

        if not ColorPickerFrame or type(ColorPickerFrame.SetColorRGB) ~= "function" then
            return
        end

        ColorPickerFrame.func = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            ApplyColorSwatch(r, g, b, current[4])
        end
        ColorPickerFrame.cancelFunc = function(previousValues)
            if type(previousValues) == "table" then
                ApplyColorSwatch(previousValues.r, previousValues.g, previousValues.b, current[4])
            end
        end
        ColorPickerFrame.previousValues = { r = current[1], g = current[2], b = current[3] }
        ColorPickerFrame.hasOpacity = false
        ColorPickerFrame.opacity = 0
        ColorPickerFrame:SetColorRGB(current[1], current[2], current[3])
        ColorPickerFrame:Hide()
        ColorPickerFrame:Show()
    end)

    frame._muiApplyColorSwatch = ApplyColorSwatch
    frame._muiOwnerMap = map
    map._muiAnnotationEditor = frame
    return frame
end

function UI.ShowMapAnnotationEditor(map, pending)
    if not map or type(pending) ~= "table" then return end
    local editor = UI.EnsureMapAnnotationEditor(map)
    if not editor then return end
    editor._muiOwnerMap = map

    local locationText = pending.locationLabel or string.format("%.1f, %.1f", (pending.x or 0) * 100, (pending.y or 0) * 100)
    if editor._muiHeader and type(editor._muiHeader.SetText) == "function" then
        editor._muiHeader:SetText("Place Note at " .. locationText)
    end

    if editor._muiHeaderInput and type(editor._muiHeaderInput.SetText) == "function" then
        editor._muiHeaderInput:SetText("")
    end
    if editor._muiDescriptionInput and type(editor._muiDescriptionInput.SetText) == "function" then
        editor._muiDescriptionInput:SetText("")
    end
    if editor._muiDescriptionScroll and type(editor._muiDescriptionScroll.SetVerticalScroll) == "function" then
        editor._muiDescriptionScroll:SetVerticalScroll(0)
    end
    if type(editor._muiSetSelectedNoteType) == "function" then
        editor._muiSetSelectedNoteType(pending.noteType)
    end

    local isSingleClick = type(pending.points) == "table" and #pending.points == 1
    local colorYOffset = 0
    if isSingleClick then
        if editor._muiColorLabel then editor._muiColorLabel:Hide() end
        if editor._muiColorSwatch then editor._muiColorSwatch:Hide() end
        colorYOffset = 24
        editor:SetHeight(352 - colorYOffset)
    else
        if editor._muiColorLabel then editor._muiColorLabel:Show() end
        if editor._muiColorSwatch then editor._muiColorSwatch:Show() end
        editor:SetHeight(352)
    end

    if editor._muiHeaderLabel then
        editor._muiHeaderLabel:ClearAllPoints()
        editor._muiHeaderLabel:SetPoint("TOPLEFT", editor, "TOPLEFT", 12, -58 + colorYOffset)
    end
    if editor._muiHeaderInput then
        editor._muiHeaderInput:ClearAllPoints()
        editor._muiHeaderInput:SetPoint("TOPLEFT", editor, "TOPLEFT", 12, -74 + colorYOffset)
        editor._muiHeaderInput:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -12, -74 + colorYOffset)
    end
    if editor._muiNoteTypeLabel then
        editor._muiNoteTypeLabel:ClearAllPoints()
        editor._muiNoteTypeLabel:SetPoint("TOPLEFT", editor, "TOPLEFT", 12, -104 + colorYOffset)
    end
    if editor._muiNoteTypeDropdown then
        editor._muiNoteTypeDropdown:ClearAllPoints()
        editor._muiNoteTypeDropdown:SetPoint("TOPLEFT", editor, "TOPLEFT", -4, -116 + colorYOffset)
    end
    if editor._muiDescriptionLabel then
        editor._muiDescriptionLabel:ClearAllPoints()
        editor._muiDescriptionLabel:SetPoint("TOPLEFT", editor, "TOPLEFT", 12, -144 + colorYOffset)
    end
    if editor._muiDescriptionBox then
        editor._muiDescriptionBox:ClearAllPoints()
        editor._muiDescriptionBox:SetPoint("TOPLEFT", editor, "TOPLEFT", 12, -160 + colorYOffset)
        editor._muiDescriptionBox:SetPoint("TOPRIGHT", editor, "TOPRIGHT", -12, -160 + colorYOffset)
    end
    local color = pending.color or { UI.GetMapAnnotationDefaultColor() }
    if editor._muiApplyColorSwatch then
        editor._muiApplyColorSwatch(color[1] or 0.98, color[2] or 0.82, color[3] or 0.24, color[4] or 0.42)
    end

    if type(GetCursorPosition) == "function" and UIParent and type(UIParent.GetEffectiveScale) == "function" then
        local x, y = GetCursorPosition()
        local scale = UIParent:GetEffectiveScale() or 1
        local uiX = x / scale + 12
        local uiY = y / scale + 12
        local maxX = (UIParent:GetWidth() or 0) - editor:GetWidth() - 10
        if type(maxX) == "number" and uiX > maxX then uiX = maxX end
        if uiX < 10 then uiX = 10 end
        if uiY < editor:GetHeight() + 10 then uiY = editor:GetHeight() + 10 end
        editor:ClearAllPoints()
        editor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", uiX, uiY)
    else
        editor:ClearAllPoints()
        editor:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end

    editor:Show()
    if editor._muiHeaderInput and type(editor._muiHeaderInput.SetFocus) == "function" then
        editor._muiHeaderInput:SetFocus()
    end
end

function UI.UpdatePendingMapAnnotationSample(map, force)
    if not map or not Runtime.annotation or Runtime.annotation.captureActive ~= true then return end
    local pending = Runtime.annotation.pending
    if type(pending) ~= "table" then return end

    local x, y = UI.GetNormalizedCursorOnMap(map)
    if type(x) ~= "number" or type(y) ~= "number" then
        Util.MapAnnotationInputLog("sample:cursorInvalid", "x=nil y=nil", false)
        return
    end

    pending.points = pending.points or {}
    local count = #pending.points
    local last = count > 0 and pending.points[count] or nil
    if not last then
        pending.points[1] = { x = x, y = y }
        pending.x = x
        pending.y = y
        Util.MapAnnotationInputLog("sample:firstPoint", string.format("x=%s y=%s", Util.FormatNumberPrecise(x), Util.FormatNumberPrecise(y)), false)
        UI.RenderMapAnnotations(map)
        return
    end

    local dx = x - last.x
    local dy = y - last.y
    local minStep = 0.0009
    if force == true or (dx * dx + dy * dy) >= (minStep * minStep) then
        pending.points[#pending.points + 1] = { x = x, y = y }
        pending.x = x
        pending.y = y
        local shouldLog = (force == true) or (#pending.points <= 3) or ((#pending.points % 8) == 0)
        if shouldLog then
            Util.MapAnnotationInputLog(
                "sample:commit",
                string.format(
                    "force=%s points=%s x=%s y=%s step=%s",
                    Util.SafeToString(force == true),
                    Util.SafeToString(#pending.points),
                    Util.FormatNumberPrecise(x),
                    Util.FormatNumberPrecise(y),
                    Util.FormatNumberPrecise(math.sqrt((dx * dx) + (dy * dy)))
                ),
                false
            )
        end
        UI.RenderMapAnnotations(map)
    end
end

function UI.BeginPendingMapAnnotation(map)
    if not map or not Runtime.annotation or Runtime.annotation.active ~= true then return end
    if Runtime.annotation.captureActive == true then
        Util.MapAnnotationInputLog("capture:beginIgnored", "alreadyActive=true", false)
        return
    end
    local x, y = UI.GetNormalizedCursorOnMap(map)
    if type(x) ~= "number" or type(y) ~= "number" then
        Util.MapAnnotationInputLog("capture:beginFailed", "cursorUnavailable=true", true)
        return
    end

    local mapID = UI.GetActiveMapID(map)
    if type(mapID) ~= "number" then
        Util.MapAnnotationInputLog("capture:beginFailed", "mapID=nil", true)
        return
    end

    local r, g, b, a = UI.GetMapAnnotationDefaultColor()
    Runtime.annotation.captureActive = true
    Runtime.annotation.pending = {
        mapID = mapID,
        points = { { x = x, y = y } },
        x = x,
        y = y,
        color = { r, g, b, a },
        locationLabel = nil,
        isClosedShape = false,
        _muiDebugTraceKey = Util.CreateMapAnnotationDebugTraceKey(mapID),
    }

    Util.MapAnnotationInputLog(
        "capture:begin",
        string.format("mapID=%s x=%s y=%s", Util.SafeToString(mapID), Util.FormatNumberPrecise(x), Util.FormatNumberPrecise(y)),
        true
    )
    UI.RenderMapAnnotations(map)
end

function UI.FinishPendingMapAnnotation(map, canceled)
    if not Runtime.annotation or Runtime.annotation.captureActive ~= true then return end
    Runtime.annotation.captureActive = false

    if canceled == true then
        Util.MapAnnotationInputLog("capture:finish", "canceled=true", true)
        UI.CancelPendingMapAnnotation(map, "captureCanceled")
        return
    end

    local pending = Runtime.annotation.pending
    if type(pending) ~= "table" or type(pending.points) ~= "table" or #pending.points == 0 then
        Util.MapAnnotationInputLog("capture:finish", "pendingMissing=true", true)
        UI.CancelPendingMapAnnotation(map, "captureEmpty")
        return
    end

    UI.UpdatePendingMapAnnotationSample(map, true)
    local points = pending.points
    local isDrawAttempt = (#points >= 4) or (UI.GetMapAnnotationPathLength(points) >= 0.020)
    Util.MapAnnotationInputLog(
        "capture:finishEvaluate",
        string.format("points=%s drawAttempt=%s", Util.SafeToString(#points), Util.SafeToString(isDrawAttempt)),
        true
    )
    if isDrawAttempt then
        local isClosed, closeDist = UI.IsMapAnnotationClosedShape(points)
        Util.MapAnnotationInputLog("capture:shapeCheck", string.format("isClosed=%s closeDist=%.6f", Util.SafeToString(isClosed), closeDist or 0), true)
        if not isClosed then
            UI.ReportMapAnnotationError("You have to draw a connecting shape.")
            UI.CancelPendingMapAnnotation(map, "openShapeRejected")
            return
        end

        local first = points[1]
        local last = points[#points]
        -- Snap the last drawn point onto the first point for a clean join
        last.x = first.x
        last.y = first.y
        -- Append explicit closing vertex if the path doesn't already end at start
        if math.abs((first.x or 0) - (last.x or 0)) > 0.0001 or math.abs((first.y or 0) - (last.y or 0)) > 0.0001 then
            points[#points + 1] = { x = first.x, y = first.y }
        end
        local area = UI.GetMapAnnotationPolygonArea(points)
        if area < 0.00008 then
            UI.ReportMapAnnotationError("Couldn't complete the connection for your shape.")
            UI.CancelPendingMapAnnotation(map, "fillAreaTooSmall")
            return
        end
        pending.isClosedShape = true
    else
        pending.points = { points[1] }
        pending.isClosedShape = false
    end

    local centerX, centerY = UI.ComputeMapAnnotationCentroid(pending.points)
    pending.x, pending.y = centerX, centerY
    pending.locationLabel = UI.ResolveMapAnnotationLocationLabel(map, centerX, centerY)
    Util.MapAnnotationInputLog(
        "capture:finishAccepted",
        string.format("points=%s closed=%s center=(%s,%s)", Util.SafeToString(#pending.points), Util.SafeToString(pending.isClosedShape == true), Util.FormatNumberPrecise(centerX), Util.FormatNumberPrecise(centerY)),
        true
    )

    UI.ShowMapAnnotationEditor(map, pending)
    UI.RenderMapAnnotations(map)
end

function UI.SetMapAnnotationCursor(active, map)
    local targetMap = map or _G.WorldMapFrame
    local overlay = targetMap and targetMap._muiAnnotationCaptureOverlay or nil
    if overlay and type(overlay.SetCursor) == "function" then
        if active then
            local ok = pcall(overlay.SetCursor, overlay, "CAST_CURSOR")
            if not ok then
                pcall(overlay.SetCursor, overlay, "INTERACT_CURSOR")
            end
        else
            pcall(overlay.SetCursor, overlay, nil)
        end
        return
    end

    if active and type(SetCursor) == "function" then
        local ok = pcall(SetCursor, "CAST_CURSOR")
        if not ok then
            pcall(SetCursor, "INTERACT_CURSOR")
        end
    elseif not active and type(ResetCursor) == "function" then
        pcall(ResetCursor)
    end
end

function UI.TryZoomOutMapOneLevel(map, sourceTag)
    if not map then return false end
    local now = (type(GetTime) == "function") and GetTime() or 0
    local lastClick = Runtime.annotation and Runtime.annotation.lastZoomClickAt or 0
    if (now - lastClick) < 0.04 then return false end
    Runtime.annotation.lastZoomClickAt = now

    if type(map.NavigateUp) == "function" then
        local ok = pcall(map.NavigateUp, map)
        if ok then
            return true
        end
    end

    local currentMapID = UI.GetActiveMapID(map)
    if type(currentMapID) == "number" and type(C_Map) == "table" and type(C_Map.GetMapInfo) == "function" and type(map.SetMapID) == "function" then
        local info = C_Map.GetMapInfo(currentMapID)
        local parentMapID = info and info.parentMapID or nil
        if type(parentMapID) == "number" and parentMapID > 0 then
            if type(InCombatLockdown) == "function" and InCombatLockdown() then
                return false
            end
            local ok = pcall(map.SetMapID, map, parentMapID)
            if ok then
                return true
            end
        end
    end

    if map.ScrollContainer and type(map.ScrollContainer.ZoomOut) == "function" then
        local ok = pcall(map.ScrollContainer.ZoomOut, map.ScrollContainer)
        if ok then
            return true
        end
    end
    return false
end

function UI.EnsureMapAnnotationCaptureOverlay(map)
    if not map then return nil end
    local layer = UI.EnsureMapAnnotationLayer(map)
    if not layer then return nil end

    local overlay = map._muiAnnotationCaptureOverlay
    if not overlay then
        overlay = CreateFrame("Button", nil, layer)
        overlay:SetAllPoints(layer)
        overlay:SetFrameStrata("HIGH")
        overlay:SetFrameLevel(layer:GetFrameLevel() + 4)
        overlay:EnableMouse(true)
        overlay:RegisterForClicks("LeftButtonDown", "LeftButtonUp", "RightButtonUp")
        overlay:RegisterForDrag("LeftButton")
        if type(overlay.SetPropagateMouseClicks) == "function" then
            overlay:SetPropagateMouseClicks(false)
        end
        if type(overlay.SetPropagateMouseMotion) == "function" then
            overlay:SetPropagateMouseMotion(true)
        end
        overlay._muiOwnerMap = map
        overlay._muiSampleAccum = 0
        overlay._muiLeftCapture = false
        overlay._muiLastUpdateInputLogAt = 0
        overlay._muiHoverAccum = 0
        overlay._muiHoverNote = nil

        overlay:SetScript("OnMouseDown", function(self, mouseButton)
            if mouseButton ~= "LeftButton" then return end
            Util.MapAnnotationInputLog(
                "mouseDown",
                string.format("btn=%s active=%s capture=%s", Util.SafeToString(mouseButton), Util.SafeToString(Runtime.annotation and Runtime.annotation.active == true), Util.SafeToString(Runtime.annotation and Runtime.annotation.captureActive == true)),
                true
            )
            if Runtime.annotation and Runtime.annotation.active == true then
                self._muiLeftCapture = true
                UI.BeginPendingMapAnnotation(self._muiOwnerMap)
            end
        end)

        overlay:SetScript("OnMouseUp", function(self, mouseButton)
            if mouseButton == "LeftButton" then
                Util.MapAnnotationInputLog(
                    "mouseUp",
                    string.format("btn=%s capture=%s points=%s", Util.SafeToString(mouseButton), Util.SafeToString(Runtime.annotation and Runtime.annotation.captureActive == true), Util.SafeToString(Runtime.annotation and Runtime.annotation.pending and Runtime.annotation.pending.points and #Runtime.annotation.pending.points or 0)),
                    true
                )
                self._muiLeftCapture = false
                if Runtime.annotation and Runtime.annotation.captureActive then
                    UI.FinishPendingMapAnnotation(self._muiOwnerMap, false)
                end
            elseif mouseButton == "RightButton" then
                Util.MapAnnotationInputLog("mouseUp", "btn=RightButton zoomOutAttempt=true", true)
                local hoveredNote = UI.FindMapAnnotationUnderCursor(self._muiOwnerMap)
                Util.MapAnnotationInputLog(
                    "rightClick:overlay",
                    string.format("hoveredNote=%s noteId=%s", Util.SafeToString(hoveredNote ~= nil), Util.SafeToString(hoveredNote and hoveredNote.id)),
                    true
                )
                if hoveredNote then
                    Util.MapAnnotationInputLog("rightClick:overlay", "action=contextMenu", true)
                    UI.ShowMapAnnotationContextMenu(self, hoveredNote)
                    return
                end
                if UI.GetMapHiddenAnnotationCount(UI.GetActiveMapID(self._muiOwnerMap)) > 0 then
                    Util.MapAnnotationInputLog("rightClick:overlay", "action=hiddenMenu", true)
                    UI.ShowMapAnnotationHiddenNotesMenu(self, self._muiOwnerMap)
                    return
                end
                if not (Runtime.annotation and Runtime.annotation.contextMenuOpen == true) then
                    Util.MapAnnotationInputLog("rightClick:overlay", "action=zoomOut", true)
                    UI.TryZoomOutMapOneLevel(self._muiOwnerMap, "annotationOverlay")
                else
                    Util.MapAnnotationInputLog("rightClick:overlay", "action=none reason=contextMenuAlreadyOpen", true)
                end
            end
        end)

        overlay:SetScript("OnDragStart", function(self)
            self._muiLeftCapture = true
            Util.MapAnnotationInputLog(
                "dragStart",
                string.format("active=%s capture=%s", Util.SafeToString(Runtime.annotation and Runtime.annotation.active == true), Util.SafeToString(Runtime.annotation and Runtime.annotation.captureActive == true)),
                true
            )
            if Runtime.annotation and Runtime.annotation.active == true and not Runtime.annotation.captureActive then
                UI.BeginPendingMapAnnotation(self._muiOwnerMap)
            end
        end)

        overlay:SetScript("OnDragStop", function(self)
            self._muiLeftCapture = false
            Util.MapAnnotationInputLog(
                "dragStop",
                string.format("capture=%s points=%s", Util.SafeToString(Runtime.annotation and Runtime.annotation.captureActive == true), Util.SafeToString(Runtime.annotation and Runtime.annotation.pending and Runtime.annotation.pending.points and #Runtime.annotation.pending.points or 0)),
                true
            )
            if Runtime.annotation and Runtime.annotation.captureActive then
                UI.FinishPendingMapAnnotation(self._muiOwnerMap, false)
            end
        end)

        overlay:SetScript("OnUpdate", function(self, elapsed)
            if Runtime.annotation and Runtime.annotation.captureActive == true then
                self._muiSampleAccum = (self._muiSampleAccum or 0) + (elapsed or 0)
                if self._muiSampleAccum >= 0.015 then
                    self._muiSampleAccum = 0
                    local now = (type(GetTime) == "function") and GetTime() or 0
                    if (now - (self._muiLastUpdateInputLogAt or 0)) >= 0.20 then
                        self._muiLastUpdateInputLogAt = now
                        Util.MapAnnotationInputLog(
                            "update",
                            string.format(
                                "leftDown=%s points=%s",
                                Util.SafeToString(type(IsMouseButtonDown) == "function" and IsMouseButtonDown("LeftButton")),
                                Util.SafeToString(Runtime.annotation and Runtime.annotation.pending and Runtime.annotation.pending.points and #Runtime.annotation.pending.points or 0)
                            ),
                            false
                        )
                    end
                    if type(IsMouseButtonDown) == "function" and not IsMouseButtonDown("LeftButton") then
                        self._muiLeftCapture = false
                        Util.MapAnnotationInputLog("update:autoFinish", "leftDown=false", true)
                        UI.FinishPendingMapAnnotation(self._muiOwnerMap, false)
                    else
                        UI.UpdatePendingMapAnnotationSample(self._muiOwnerMap, false)
                    end
                end
            end

            -- Hover fallback while tool is active so tooltip works even when this
            -- capture overlay sits on top of note hit buttons.
            if Runtime.annotation and Runtime.annotation.active == true and Runtime.annotation.captureActive ~= true then
                self._muiHoverAccum = (self._muiHoverAccum or 0) + (elapsed or 0)
                if self._muiHoverAccum >= 0.10 then
                    self._muiHoverAccum = 0
                    local hoverNote = UI.FindMapAnnotationUnderCursor(self._muiOwnerMap)
                    if hoverNote ~= self._muiHoverNote then
                        self._muiHoverNote = hoverNote
                        if hoverNote then
                            UI.ShowMapAnnotationTooltip(self, hoverNote)
                        elseif _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                            _G.GameTooltip:Hide()
                        end
                    end
                end
            elseif self._muiHoverNote then
                self._muiHoverNote = nil
                if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                    _G.GameTooltip:Hide()
                end
            end
        end)

        overlay:SetScript("OnHide", function(self)
            self._muiLeftCapture = false
            self._muiHoverNote = nil
            Util.MapAnnotationInputLog(
                "overlayHide",
                "capture=" .. Util.SafeToString(Runtime.annotation and Runtime.annotation.captureActive == true),
                true
            )
            if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                _G.GameTooltip:Hide()
            end
            UI.HideMapAnnotationFallbackMenu()
            if Runtime.annotation and Runtime.annotation.captureActive then
                UI.FinishPendingMapAnnotation(self._muiOwnerMap, true)
            end
        end)

        map._muiAnnotationCaptureOverlay = overlay
    elseif overlay:GetParent() ~= layer then
        overlay:SetParent(layer)
        overlay:ClearAllPoints()
        overlay:SetAllPoints(layer)
        overlay:SetFrameLevel(layer:GetFrameLevel() + 4)
        overlay._muiOwnerMap = map
    end

    if Runtime.annotation and Runtime.annotation.active == true then
        overlay:Show()
    else
        overlay:Hide()
    end

    if not map._muiAnnotationOnHideHook and type(map.HookScript) == "function" then
        map:HookScript("OnHide", function()
            UI.SetMapAnnotationCursor(false, map)
        end)
        map._muiAnnotationOnHideHook = true
    end

    return overlay
end

function UI.SetMapAnnotationToolActive(map, isActive, sourceTag)
    local worldMap = map or _G.WorldMapFrame
    if not worldMap then return end
    local shouldEnable = (isActive == true)
    Util.MapAnnotationInputLog(
        "toolToggle:request",
        string.format("requested=%s source=%s", Util.SafeToString(shouldEnable), Util.SafeToString(sourceTag or "unknown")),
        true
    )

    Runtime.annotation.active = shouldEnable
    if not shouldEnable then
        if Runtime.annotation.captureActive then
            UI.FinishPendingMapAnnotation(worldMap, true)
        end
    end

    UI.EnsureMapAnnotationCaptureOverlay(worldMap)
    if worldMap._muiAnnotationCaptureOverlay then
        if shouldEnable then
            worldMap._muiAnnotationCaptureOverlay:Show()
        else
            worldMap._muiAnnotationCaptureOverlay:Hide()
        end
    end

    UI.SetMapAnnotationCursor(shouldEnable, worldMap)
    UI.RefreshMapAnnotationToolButtonState()
    UI.RenderMapAnnotations(worldMap)
    Util.MapAnnotationInputLog(
        "toolToggle:applied",
        string.format("active=%s overlayShown=%s mapID=%s", Util.SafeToString(Runtime.annotation.active == true), Util.SafeToString(worldMap._muiAnnotationCaptureOverlay and worldMap._muiAnnotationCaptureOverlay:IsShown()), Util.SafeToString(UI.GetActiveMapID(worldMap))),
        true
    )
end

function UI.ShowMapAnnotationToolTooltip(button)
    if not button or not _G.GameTooltip or type(_G.GameTooltip.SetOwner) ~= "function" then return end
    local tooltip = _G.GameTooltip
    tooltip:SetOwner(button, "ANCHOR_BOTTOMRIGHT", 0, 8)
    local titleR, titleG, titleB = C.GetThemeColor("textPrimary")
    local bodyR, bodyG, bodyB = C.GetThemeColor("textSecondary")
    tooltip:SetText("Map Annotation Tool", titleR, titleG, titleB)
    tooltip:AddLine("Left click: place a point", bodyR, bodyG, bodyB, true)
    tooltip:AddLine("Left drag: draw a path", bodyR, bodyG, bodyB, true)
    tooltip:AddLine("Right click map: zoom out one level", bodyR, bodyG, bodyB, true)
    tooltip:Show()
end

function UI.StyleMapAnnotationToolButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    if type(button.EnableMouse) == "function" then
        button:EnableMouse(true)
    end
    UI.SuppressControlHighlight(button)
    UI.HideTexture(button:GetNormalTexture())
    UI.HideTexture(button:GetPushedTexture())
    UI.HideTexture(button:GetHighlightTexture())

    if button.Icon then
        local atlasApplied = false
        if type(button.Icon.SetAtlas) == "function" then
            atlasApplied = pcall(button.Icon.SetAtlas, button.Icon, "Cursor_OpenHand_48")
        end
        if not atlasApplied then
            button.Icon:SetTexture("Interface\\Minimap\\Tracking\\POI")
            button.Icon:SetTexCoord(0, 1, 0, 1)
        end
        local iconSize = math.max(12, (C.CONTROL_BUTTON_SIZE or 20) - 6)
        button.Icon:SetSize(iconSize, iconSize)
        button.Icon:ClearAllPoints()
        button.Icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        if type(button.Icon.SetDrawLayer) == "function" then
            button.Icon:SetDrawLayer("OVERLAY", 6)
        end
    end

    UI.EnsureControlChrome(button)
    UI.EnsureControlIconHooks(button)
    UI.RefreshMapAnnotationToolButtonState()
end

function UI.EnsureMapAnnotationToolButton(map)
    if not map then return nil end

    local button = map._muiAnnotationToolButton
    if not button then
        button = CreateFrame("Button", nil, map)
        button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
        button:RegisterForClicks("LeftButtonUp")

        local icon = button:CreateTexture(nil, "OVERLAY", nil, 6)
        icon:SetSize(16, 16)
        icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        button.Icon = icon

        button:SetScript("OnClick", function(self)
            local ownerMap = self:GetParent() == map and map or _G.WorldMapFrame
            Util.MapAnnotationInputLog(
                "toolButton:click",
                string.format("activeBefore=%s mapID=%s", Util.SafeToString(Runtime.annotation and Runtime.annotation.active == true), Util.SafeToString(UI.GetActiveMapID(ownerMap))),
                true
            )
            UI.SetMapAnnotationToolActive(ownerMap, not (Runtime.annotation and Runtime.annotation.active == true), "toolbarButton")
        end)

        if type(button.HookScript) == "function" then
            button:HookScript("OnEnter", function(self)
                UI.ShowMapAnnotationToolTooltip(self)
            end)
            button:HookScript("OnLeave", function()
                if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                    _G.GameTooltip:Hide()
                end
            end)
        end

        map._muiAnnotationToolButton = button
    elseif button:GetParent() ~= map then
        button:SetParent(map)
    end

    button:Show()
    UI.StyleMapAnnotationToolButton(button)
    return button
end

function UI.StyleTrackingFilterButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    UI.HideTexture(button.Background)
    UI.HideTexture(button.Border)
    UI.HideTexture(button.FilterCounterBanner)
    UI.SuppressControlHighlight(button)
    if button.ResetButton then button.ResetButton:Hide() end

    if button.Icon then
        button.Icon:SetSize(16, 16)
        button.Icon:ClearAllPoints()
        button.Icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        if type(button.Icon.SetDrawLayer) == "function" then
            button.Icon:SetDrawLayer("OVERLAY", 6)
        end
    end

    if button.FilterCounter then
        button.FilterCounter:SetParent(button)
        button.FilterCounter:ClearAllPoints()
        button.FilterCounter:SetPoint("TOPRIGHT", button, "TOPRIGHT", 4, 4)
    end
    UI.EnsureControlChrome(button)
    UI.EnsureControlIconHooks(button)
    UI.ApplyControlIconColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
end

function UI.StyleTrackingPinButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    UI.HideTexture(button.Background)
    UI.HideTexture(button.Border)
    UI.SuppressControlHighlight(button)
    if button.ActiveTexture then button.ActiveTexture:SetAlpha(0) end

    if button.Icon then
        button.Icon:SetSize(16, 16)
        button.Icon:ClearAllPoints()
        button.Icon:SetPoint("CENTER", button, "CENTER", 0, 0)
        if type(button.Icon.SetDrawLayer) == "function" then
            button.Icon:SetDrawLayer("OVERLAY", 6)
        end
    end

    UI.EnsureControlChrome(button)
    UI.EnsureControlIconHooks(button)
    UI.ApplyControlIconColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
    if not button._muiMapPinStateHooked then
        hooksecurefunc(button, "SetActive", function(self, isActive)
            self.isActive = isActive
            if self._muiMapChrome and self._muiMapChrome.accent then
                self._muiMapChrome.accent:SetAlpha(isActive and 1 or 0)
            end
            UI.ApplyControlIconColor(self, type(self.IsMouseOver) == "function" and self:IsMouseOver())
        end)
        button._muiMapPinStateHooked = true
    end
end

function UI.StyleFactionButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    if type(button.EnableMouse) == "function" then
        button:EnableMouse(true)
    end
    if type(button.SetHitRectInsets) == "function" then
        button:SetHitRectInsets(0, 0, 0, 0)
    end
    if type(button.RegisterForClicks) == "function" then
        button:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
    end
    UI.HideTexture(button.IconBorder)
    UI.HideTexture(button.Highlight)
    UI.SuppressControlHighlight(button)
    UI.ApplyFactionButtonAtlas(button)
    UI.SuppressFactionDropdownArt(button)
    UI.EnsureControlChrome(button)
    UI.ApplyFactionButtonColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())

    if not button._muiMapFactionHooks and type(button.HookScript) == "function" then
        button:HookScript("OnShow", function(self)
            UI.ApplyFactionButtonAtlas(self)
            UI.SuppressFactionDropdownArt(self)
            UI.ApplyFactionButtonColor(self, type(self.IsMouseOver) == "function" and self:IsMouseOver())
        end)
        button:HookScript("OnEnter", function(self)
            UI.ApplyFactionButtonColor(self, true)
            UI.ShowFactionButtonTooltip(self)
        end)
        button:HookScript("OnLeave", function(self)
            UI.ApplyFactionButtonColor(self, false)
            if _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                _G.GameTooltip:Hide()
            end
        end)
        button:HookScript("OnMouseUp", function(self, mouseButton)
            if mouseButton == "LeftButton" then
                UI.ClickFactionDropdown(self)
            end
        end)
        button._muiMapFactionHooks = true
    end

    local dropdown = button.BountyDropdown
    if dropdown and not dropdown._muiMapFactionHoverHooks and type(dropdown.HookScript) == "function" then
        dropdown:HookScript("OnEnter", function()
            if button._muiMapChrome and button._muiMapChrome.hover then
                button._muiMapChrome.hover:SetAlpha(1)
            end
            if button._muiMapChrome and button._muiMapChrome.accent then
                button._muiMapChrome.accent:SetAlpha(1)
            end
            UI.ApplyFactionButtonColor(button, true)
            UI.ShowFactionButtonTooltip(button)
        end)
        dropdown:HookScript("OnLeave", function()
            local isOver = type(button.IsMouseOver) == "function" and button:IsMouseOver()
            if button._muiMapChrome and button._muiMapChrome.hover then
                button._muiMapChrome.hover:SetAlpha(isOver and 1 or 0)
            end
            if button._muiMapChrome and button._muiMapChrome.accent then
                button._muiMapChrome.accent:SetAlpha(isOver and 1 or 0)
            end
            UI.ApplyFactionButtonColor(button, isOver)
            if isOver then
                UI.ShowFactionButtonTooltip(button)
            elseif _G.GameTooltip and type(_G.GameTooltip.Hide) == "function" then
                _G.GameTooltip:Hide()
            end
        end)
        dropdown._muiMapFactionHoverHooks = true
    end
end

function UI.StyleNavOverflowButton(button)
    if not button then return end
    button:SetSize(C.CONTROL_BUTTON_SIZE, C.CONTROL_BUTTON_SIZE)
    UI.HideTexture(button:GetNormalTexture())
    UI.HideTexture(button:GetPushedTexture())
    UI.HideTexture(button:GetHighlightTexture())

    -- Aggressively hide all Blizzard textures (the parchment square)
    local function SuppressOverflowArt()
        for _, region in pairs({ button:GetRegions() }) do
            if region and region.GetObjectType and region:GetObjectType() == "Texture" then
                if not region._muiMapCreated then
                    UI.HideTexture(region)
                end
            end
        end
    end
    SuppressOverflowArt()

    if not button._muiMapOverflowText then
        local fs = button:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("CENTER", button, "CENTER", 0, -1)
        fs:SetText("...")
        fs._muiMapCreated = true
        button._muiMapOverflowText = fs
    end
    UI.EnsureControlChrome(button)

    -- Hide the overflow button entirely — breadcrumbs have enough room
    button:Hide()
    button:SetAlpha(0)
    button:SetWidth(1)
    if button._muiMapOverflowText then
        button._muiMapOverflowText:Hide()
    end

    -- Keep it hidden when Blizzard tries to re-show it
    if not button._muiOverflowHideHook then
        button._muiOverflowHideHook = true
        button:HookScript("OnShow", function(self)
            SuppressOverflowArt()
            self:Hide()
        end)
    end
end

-- Modern Tab/Pill style for Navigation nodes
function UI.StyleNavButton(button)
    if not button then return end
    button:SetHeight(C.HEADER_NAV_HEIGHT - 4)

    UI.SuppressNavButtonArt(button)

    local textObject = UI.GetNavButtonTextObject(button)
    if textObject then
        textObject:SetFontObject(GameFontHighlightSmall)
        if textObject.SetDrawLayer then
            textObject:SetDrawLayer("OVERLAY", 7)
        end
        if textObject.SetShadowOffset then
            textObject:SetShadowOffset(1, -1)
        end
        if textObject.SetShadowColor then
            textObject:SetShadowColor(0, 0, 0, 0.9)
        end
    end

    if button.MenuArrowButton then
        button.MenuArrowButton:SetSize(14, 14)
        button.MenuArrowButton:ClearAllPoints()
        button.MenuArrowButton:SetPoint("RIGHT", button, "RIGHT", -2, 0)
        UI.EnforceArrowButtonArt(button.MenuArrowButton, button.MenuArrowButton.Art)
        UI.QueueArrowButtonArtRefresh(button.MenuArrowButton, button.MenuArrowButton.Art)

        local navMenuArrow = UI.EnsureNavMenuArrow(button.MenuArrowButton)
        if navMenuArrow then
            navMenuArrow:ClearAllPoints()
            navMenuArrow:SetPoint("CENTER", button.MenuArrowButton, "CENTER", 0, 0)
            navMenuArrow:Show()
        end
        UI.ApplyNavMenuArrowColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())

        if not button.MenuArrowButton._muiMapNavMenuHooks and button.MenuArrowButton.HookScript then
            button.MenuArrowButton:HookScript("OnShow", function(self)
                UI.EnforceArrowButtonArt(self, self.Art)
                UI.QueueArrowButtonArtRefresh(self, self.Art)
                UI.ApplyNavMenuArrowColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
            end)
            button.MenuArrowButton:HookScript("OnEnter", function(self)
                UI.EnforceArrowButtonArt(self, self.Art)
                UI.ApplyNavMenuArrowColor(button, true)
            end)
            button.MenuArrowButton:HookScript("OnLeave", function(self)
                UI.EnforceArrowButtonArt(self, self.Art)
                UI.ApplyNavMenuArrowColor(button, type(button.IsMouseOver) == "function" and button:IsMouseOver())
            end)
            button.MenuArrowButton._muiMapNavMenuHooks = true
        end
        if button.MenuArrowButton.Art and not button.MenuArrowButton.Art._muiMapHideHook and type(button.MenuArrowButton.Art.HookScript) == "function" then
            button.MenuArrowButton.Art._muiMapHideHook = true
            button.MenuArrowButton.Art:HookScript("OnShow", function(self) self:Hide() end)
        end
    end

    local r, g, b = UI.GetAccentColor()
    if not button._muiMapSimpleHover then
        local hover = button:CreateTexture(nil, "BACKGROUND", nil, -1)
        hover:SetPoint("TOPLEFT", 1, -1)
        hover:SetPoint("BOTTOMRIGHT", -1, 1)
        hover:SetTexture(C.WHITE8X8)
        hover:SetVertexColor(r, g, b, 0.16)
        hover:SetAlpha(0)
        button._muiMapSimpleHover = hover
        
        local activeLine = button:CreateTexture(nil, "ARTWORK")
        activeLine:SetPoint("BOTTOMLEFT", 4, 2)
        activeLine:SetPoint("BOTTOMRIGHT", -4, 2)
        activeLine:SetHeight(2)
        activeLine:SetTexture(C.WHITE8X8)
        activeLine:SetVertexColor(r, g, b, 1)
        activeLine:SetAlpha(0)
        button._muiMapSimpleActiveLine = activeLine
    end

    if button._muiMapSimpleHover then
        button._muiMapSimpleHover:SetVertexColor(r, g, b, 0.16)
    end
    if button._muiMapSimpleActiveLine then
        button._muiMapSimpleActiveLine:SetVertexColor(r, g, b, 1)
    end
    UI.SuppressNavButtonArt(button)

    if not button._muiMapSimpleHooks and button.HookScript then
        button:HookScript("OnShow", function(self)
            UI.SuppressNavButtonArt(self)
            if self._muiMapSimpleHover then
                self._muiMapSimpleHover:SetAlpha(0)
            end
            UI.ApplyNavButtonTextColor(self, false)
            UI.ApplyNavMenuArrowColor(self, false)
        end)
        button:HookScript("OnEnter", function(self)
            UI.SuppressNavButtonArt(self)
            if self._muiMapSimpleHover then self._muiMapSimpleHover:SetAlpha(1) end
            if self:IsEnabled() and self._muiMapSimpleActiveLine then 
                self._muiMapSimpleActiveLine:SetAlpha(0.5) 
            end
            UI.ApplyNavButtonTextColor(self, true)
            UI.ApplyNavMenuArrowColor(self, true)
        end)
        button:HookScript("OnLeave", function(self)
            UI.SuppressNavButtonArt(self)
            if self._muiMapSimpleHover then self._muiMapSimpleHover:SetAlpha(0) end
            if self:IsEnabled() and self._muiMapSimpleActiveLine then 
                self._muiMapSimpleActiveLine:SetAlpha(0) 
            end
            UI.ApplyNavButtonTextColor(self, false)
            UI.ApplyNavMenuArrowColor(self, false)
        end)
        button._muiMapSimpleHooks = true
    end

    local isMouseOver = type(button.IsMouseOver) == "function" and button:IsMouseOver()
    if button._muiMapSimpleHover then
        button._muiMapSimpleHover:SetAlpha(isMouseOver and 1 or 0)
    end
    if button:IsEnabled() then
        if button._muiMapSimpleActiveLine then button._muiMapSimpleActiveLine:SetAlpha(0) end
    else
        if button._muiMapSimpleActiveLine then button._muiMapSimpleActiveLine:SetAlpha(1) end
    end
    UI.ApplyNavButtonTextColor(button, isMouseOver)
    UI.ApplyNavMenuArrowColor(button, isMouseOver)
    -- Ensure the nav button stays visible and interactive
    button:Show()
    button:SetAlpha(1)
    if type(button.EnableMouse) == "function" then button:EnableMouse(true) end
end

function UI.NormalizeHomeToFirstBreadcrumbGap(navBar)
    if not navBar or type(navBar.navList) ~= "table" then return end
    local homeButton = navBar.home or navBar.homeButton
    if not homeButton then return end

    -- Chain ALL breadcrumb buttons in sequence: home → crumb1 → crumb2 → ...
    -- Without this, subsequent buttons may retain stale anchors to the hidden
    -- overflow button or to positions from a previous zone/character.
    local prevButton = homeButton
    for i = 1, #navBar.navList do
        local crumbButton = navBar.navList[i]
        if crumbButton and crumbButton ~= homeButton and crumbButton.ClearAllPoints then
            crumbButton:ClearAllPoints()
            crumbButton:SetPoint("LEFT", prevButton, "RIGHT", C.NAV_HOME_TO_FIRST_GAP, 0)
            prevButton = crumbButton
        end
    end
end

function UI.StyleNavBar(navBar)
    if not navBar then return end
    navBar:SetHeight(C.HEADER_NAV_HEIGHT)
    UI.HideFrameRegions(navBar)
    UI.HideFrameRegions(navBar.overlay)
    UI.HideTexture(navBar.InsetBorderBottomLeft)
    UI.HideTexture(navBar.InsetBorderBottomRight)
    UI.HideTexture(navBar.InsetBorderBottom)
    UI.HideTexture(navBar.InsetBorderLeft)
    UI.HideTexture(navBar.InsetBorderRight)

    local homeButton = navBar.home or navBar.homeButton
    if homeButton then
        homeButton._muiMapNavRole = "home"
        homeButton._muiMapNavIndex = 0
        UI.StyleNavButton(homeButton)

        -- Aggressively hide all Blizzard textures on the home button
        local function SuppressHomeArt()
            for _, region in pairs({ homeButton:GetRegions() }) do
                if region and region.GetObjectType and region:GetObjectType() == "Texture" then
                    if not region._muiMapCreated then
                        UI.HideTexture(region)
                    end
                end
            end
        end
        SuppressHomeArt()

        -- Re-suppress on show since Blizzard re-creates art on reload/nav changes
        if not homeButton._muiHomeArtHook then
            homeButton._muiHomeArtHook = true
            homeButton:HookScript("OnShow", SuppressHomeArt)
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, SuppressHomeArt)
                C_Timer.After(0.2, SuppressHomeArt)
                C_Timer.After(1.0, SuppressHomeArt)
            end
        end
    end

    local overflowButton = navBar.overflowButton or navBar.overflow
    UI.StyleNavOverflowButton(overflowButton)

    if type(navBar.navList) == "table" then
        local crumbIndex = 0
        for i = 1, #navBar.navList do
            local crumbButton = navBar.navList[i]
            if crumbButton and crumbButton ~= homeButton then
                crumbIndex = crumbIndex + 1
                crumbButton._muiMapNavRole = "crumb"
                crumbButton._muiMapNavIndex = crumbIndex
                UI.StyleNavButton(crumbButton)
            end
        end
    end

    UI.NormalizeHomeToFirstBreadcrumbGap(navBar)
end

-- ============================================================================
-- LAYOUT ASSEMBLY
-- ============================================================================
function UI.ClearControlReferences()
    Runtime.controls.navBar = nil
    Runtime.controls.floorDropdown = nil
    Runtime.controls.filterButton = nil
    Runtime.controls.pinButton = nil
    Runtime.controls.factionButton = nil
    Runtime.controls.questLogButton = nil
    Runtime.controls.annotationToolButton = nil
end

function UI.ApplyHeaderAnchorSync(reason)
    local map = _G.WorldMapFrame
    local layout = Runtime.layout
    if not map or not layout or layout.owner ~= map then return end
    if not map.IsShown or not map:IsShown() then return end

    UI.AnchorHeaderToCanvas(map, layout, "sync:" .. Util.SafeToString(reason))
end

function UI.QueueHeaderAnchorSync(reason)
    Runtime.headerAnchorSyncReason = Util.SafeToString(reason or "unknown")
    if Runtime.headerAnchorSyncQueued then return end

    local function FlushHeaderAnchorSync()
        Runtime.headerAnchorSyncQueued = false
        local queuedReason = Runtime.headerAnchorSyncReason
        Runtime.headerAnchorSyncReason = nil
        UI.ApplyHeaderAnchorSync(queuedReason)
    end

    Runtime.headerAnchorSyncQueued = true
    if not C_Timer or type(C_Timer.After) ~= "function" then
        FlushHeaderAnchorSync()
        return
    end
    C_Timer.After(0, FlushHeaderAnchorSync)
end

function UI.QueueHeaderAnchorSettle(reason)
    if not C_Timer or type(C_Timer.After) ~= "function" then return end
    Runtime.headerSettleToken = (Runtime.headerSettleToken or 0) + 1
    local token = Runtime.headerSettleToken
    local baseReason = Util.SafeToString(reason or "settle")

    C_Timer.After(0.05, function()
        if Runtime.headerSettleToken ~= token then return end
        UI.QueueHeaderAnchorSync(baseReason .. ":settle+0.05")
    end)
    C_Timer.After(0.20, function()
        if Runtime.headerSettleToken ~= token then return end
        UI.QueueHeaderAnchorSync(baseReason .. ":settle+0.20")
    end)
end

function UI.EnsureScrollAnchorSyncHooks(map)
    if not map then return end
    local scroll = map.ScrollContainer
    if not scroll or scroll._muiMapHeaderSyncHooks then return end

    if type(scroll.HookScript) == "function" then
        scroll:HookScript("OnShow", function()
            UI.QueueHeaderAnchorSync("ScrollContainer:OnShow")
            UI.QueueQuestPanelAnchorSettle(map, "ScrollContainer:OnShow")
        end)
        scroll:HookScript("OnSizeChanged", function()
            if Runtime.commitInProgress then return end
            UI.QueueHeaderAnchorSync("ScrollContainer:OnSizeChanged")
            UI.QueueQuestPanelAnchorSettle(map, "ScrollContainer:OnSizeChanged")
        end)
    end

    local canvas = scroll.Child or scroll.child or scroll.Canvas
    if canvas and type(canvas.HookScript) == "function" then
        canvas:HookScript("OnShow", function()
            if Runtime.commitInProgress then return end
            UI.QueueHeaderAnchorSync("ScrollCanvas:OnShow")
            UI.QueueQuestPanelAnchorSettle(map, "ScrollCanvas:OnShow")
        end)
        canvas:HookScript("OnSizeChanged", function()
            if Runtime.commitInProgress then return end
            UI.QueueHeaderAnchorSync("ScrollCanvas:OnSizeChanged")
            UI.QueueQuestPanelAnchorSettle(map, "ScrollCanvas:OnSizeChanged")
        end)
    end

    for i = 1, #C.SCROLL_PROBE_METHODS do
        local methodName = C.SCROLL_PROBE_METHODS[i]
        if type(methodName) == "string" and type(scroll[methodName]) == "function" then
            pcall(hooksecurefunc, scroll, methodName, function(_, ...)
                if Runtime.commitInProgress then return end
                if methodName == "SetPanTarget" then
                    local panX, panY = ...
                    Util.RememberPanTarget(panX, panY, "HeaderSync:" .. methodName)
                end
                UI.QueueHeaderAnchorSync("ScrollContainer:" .. methodName)
                if methodName == "SetPanTarget" or methodName == "SetCanvasScale"
                    or methodName == "PanAndZoomTo" or methodName == "PanAndZoomToNormalized" then
                    UI.QueueHeaderAnchorSettle("ScrollContainer:" .. methodName)
                    UI.QueueQuestPanelAnchorSettle(map, "ScrollContainer:" .. methodName)
                end
            end)
        end
    end

    scroll._muiMapHeaderSyncHooks = true
end

function UI.QueuePostLayoutSync()
    if Runtime.postLayoutSyncQueued then return end
    if not C_Timer or type(C_Timer.After) ~= "function" then
        if type(ApplyLayout) == "function" then ApplyLayout("PostLayoutSync") end
        return
    end
    Runtime.postLayoutSyncQueued = true
    C_Timer.After(0, function()
        Runtime.postLayoutSyncQueued = false
        local map = _G.WorldMapFrame
        if map and map:IsShown() and type(ApplyLayout) == "function" then
            ApplyLayout("PostLayoutSync")
        end
    end)
end

function UI.EnsureControlRelayoutHooks(frame)
    if not frame or frame._muiMapRelayoutHooks or type(frame.HookScript) ~= "function" then return end
    frame:HookScript("OnShow", UI.QueuePostLayoutSync)
    frame:HookScript("OnHide", UI.QueuePostLayoutSync)
    frame._muiMapRelayoutHooks = true
end

function UI.CollectWorldMapControls(map)
    UI.ClearControlReferences()
    if map.NavBar then Runtime.controls.navBar = map.NavBar end
    Runtime.controls.questLogButton = UI.EnsureQuestLogButton(map)
    Runtime.controls.annotationToolButton = UI.EnsureMapAnnotationToolButton(map)

    local overlays = map.overlayFrames
    if type(overlays) == "table" then
        for _, frame in ipairs(overlays) do
            if frame then
                if not Runtime.controls.floorDropdown and type(frame.RefreshMenu) == "function" and type(frame.SetupMenu) == "function" then
                    Runtime.controls.floorDropdown = frame
                elseif not Runtime.controls.filterButton and frame.FilterCounterBanner and frame.FilterCounter and frame.Icon then
                    Runtime.controls.filterButton = frame
                elseif not Runtime.controls.pinButton and frame.ActiveTexture and frame.IconOverlay and frame.Icon then
                    Runtime.controls.pinButton = frame
                elseif not Runtime.controls.factionButton and frame.BountyDropdown and frame.IconBorder and frame.Icon then
                    Runtime.controls.factionButton = frame
                elseif not Runtime.controls.navBar and frame.home and frame.overflow then
                    Runtime.controls.navBar = frame
                end
            end
        end
    end

    UI.EnsureControlRelayoutHooks(Runtime.controls.navBar)
    UI.EnsureControlRelayoutHooks(Runtime.controls.floorDropdown)
    UI.EnsureControlRelayoutHooks(Runtime.controls.filterButton)
    UI.EnsureControlRelayoutHooks(Runtime.controls.pinButton)
    UI.EnsureControlRelayoutHooks(Runtime.controls.factionButton)
    UI.EnsureControlRelayoutHooks(Runtime.controls.questLogButton)
    UI.EnsureControlRelayoutHooks(Runtime.controls.annotationToolButton)
end

function UI.AnchorControlRight(control, map, parent, rightAnchor, width)
    control:SetParent(map)
    control:SetFrameStrata("HIGH")
    control:SetFrameLevel(parent:GetFrameLevel() + 8)
    control:SetSize(width, C.CONTROL_BUTTON_SIZE)
    control:ClearAllPoints()

    if rightAnchor then
        control:SetPoint("RIGHT", rightAnchor, "LEFT", -C.CONTROL_SPACING, 0)
    else
        control:SetPoint("RIGHT", parent, "RIGHT", 0, 0)
    end
end

function UI.LayoutRightControls(layout)
    local map = _G.WorldMapFrame
    if not map then return end

    local availableWidth = layout.root and layout.root:GetWidth() or 0
    local railMaxWidth = C.FLOOR_DROPDOWN_MAX_WIDTH + (C.CONTROL_BUTTON_SIZE * 5) + (C.CONTROL_SPACING * 5)
    if type(availableWidth) == "number" and availableWidth > 0 then
        local byRatio = math.floor(availableWidth * C.CONTROL_RAIL_MAX_WIDTH_FACTOR)
        local byMinBreadcrumb = math.floor(availableWidth - C.NAV_MIN_BREADCRUMB_WIDTH)
        railMaxWidth = math.max(C.CONTROL_BUTTON_SIZE * 2, math.min(railMaxWidth, byRatio, byMinBreadcrumb))
    end

    local hasFilter = Runtime.controls.filterButton and Runtime.controls.filterButton:IsShown()
    local hasPin = Runtime.controls.pinButton and Runtime.controls.pinButton:IsShown()
    local hasFaction = Runtime.controls.factionButton and Runtime.controls.factionButton:IsShown()
    local hasQuestLog = Runtime.controls.questLogButton and Runtime.controls.questLogButton:IsShown()
    local hasDropdown = Runtime.controls.floorDropdown and Runtime.controls.floorDropdown:IsShown()
    local hasAnnotationTool = Runtime.controls.annotationToolButton and Runtime.controls.annotationToolButton:IsShown()

    local iconCount = 0
    if hasFilter then iconCount = iconCount + 1 end
    if hasPin then iconCount = iconCount + 1 end
    if hasFaction then iconCount = iconCount + 1 end
    if hasQuestLog then iconCount = iconCount + 1 end
    if hasAnnotationTool then iconCount = iconCount + 1 end

    local iconWidth = (iconCount * C.CONTROL_BUTTON_SIZE)
    if iconCount > 1 then iconWidth = iconWidth + ((iconCount - 1) * C.CONTROL_SPACING) end

    local dropdownWidth = C.FLOOR_DROPDOWN_WIDTH
    if hasDropdown then
        local maxForDropdown = railMaxWidth - iconWidth
        if iconCount > 0 then maxForDropdown = maxForDropdown - C.CONTROL_SPACING end
        dropdownWidth = Util.Clamp(maxForDropdown, C.FLOOR_DROPDOWN_MIN_WIDTH, C.FLOOR_DROPDOWN_MAX_WIDTH)
    end

    local rightMost = nil
    local totalWidth = 0
    local visibleCount = 0

    local ordered = {
        { frame = Runtime.controls.filterButton, width = C.CONTROL_BUTTON_SIZE, style = UI.StyleTrackingFilterButton },
        { frame = Runtime.controls.pinButton, width = C.CONTROL_BUTTON_SIZE, style = UI.StyleTrackingPinButton },
        { frame = Runtime.controls.questLogButton, width = C.CONTROL_BUTTON_SIZE, style = UI.StyleQuestLogButton },
        { frame = Runtime.controls.annotationToolButton, width = C.CONTROL_BUTTON_SIZE, style = UI.StyleMapAnnotationToolButton },
        { frame = Runtime.controls.factionButton, width = C.CONTROL_BUTTON_SIZE, style = UI.StyleFactionButton },
        { frame = Runtime.controls.floorDropdown, width = dropdownWidth, style = UI.StyleFloorDropdown },
    }

    for _, entry in ipairs(ordered) do
        local frame = entry.frame
        if frame and frame:IsShown() then
            if frame == Runtime.controls.floorDropdown then
                entry.style(frame, entry.width)
            else
                entry.style(frame)
            end
            UI.AnchorControlRight(frame, map, layout.controlsHost, rightMost, entry.width)
            rightMost = frame
            if visibleCount > 0 then totalWidth = totalWidth + C.CONTROL_SPACING end
            totalWidth = totalWidth + entry.width
            visibleCount = visibleCount + 1
        end
    end
    layout.controlsHost:SetWidth(totalWidth > 0 and totalWidth or 1)
end

function UI.LayoutNavBar(layout)
    local map = _G.WorldMapFrame
    if not map then return end
    if not map:IsShown() then return end
    local navBar = Runtime.controls.navBar
    if not navBar then return end
    if not layout then return end
    if not layout.navHost then return end

    navBar:SetParent(map)
    navBar:SetFrameStrata("HIGH")
    navBar:SetFrameLevel(layout.navHost:GetFrameLevel() + 5)
    navBar:SetClipsChildren(true)
    navBar:ClearAllPoints()
    navBar:SetPoint("TOPLEFT", layout.navHost, "TOPLEFT", -4, 0)
    navBar:SetPoint("BOTTOMRIGHT", layout.navHost, "BOTTOMRIGHT", 0, 0)
    UI.StyleNavBar(navBar)

end

function UI.EnsureMapContainerShadow(map)
    if not map then return end
    local parent = map:GetParent() or UIParent
    local shadow = map._muiContainerShadow
    local size = C.MAP_CONTAINER_SHADOW_SIZE
    local hasAllParts = shadow
        and shadow._muiTop and shadow._muiBottom
        and shadow._muiLeft and shadow._muiRight
        and shadow._muiTL and shadow._muiTR and shadow._muiBL and shadow._muiBR
        and shadow._muiSoft

    if not shadow or shadow:GetParent() ~= parent or not hasAllParts then
        if shadow then shadow:Hide() end
        shadow = CreateFrame("Frame", nil, parent)
        shadow:EnableMouse(false)

        local soft = shadow:CreateTexture(nil, "BACKGROUND", nil, -8)
        soft:SetTexture(C.MAP_CONTAINER_SHADOW_SOFT_TEXTURE)
        soft:SetBlendMode("BLEND")
        soft:SetPoint("TOPLEFT", shadow, "TOPLEFT", -C.MAP_CONTAINER_SHADOW_SOFT_PAD, C.MAP_CONTAINER_SHADOW_SOFT_PAD)
        soft:SetPoint("BOTTOMRIGHT", shadow, "BOTTOMRIGHT", C.MAP_CONTAINER_SHADOW_SOFT_PAD, -C.MAP_CONTAINER_SHADOW_SOFT_PAD)

        local top = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        top:SetTexture(C.WHITE8X8)
        top:SetPoint("TOPLEFT", shadow, "TOPLEFT", size, 0)
        top:SetPoint("TOPRIGHT", shadow, "TOPRIGHT", -size, 0)
        top:SetHeight(size)

        local bottom = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        bottom:SetTexture(C.WHITE8X8)
        bottom:SetPoint("BOTTOMLEFT", shadow, "BOTTOMLEFT", size, 0)
        bottom:SetPoint("BOTTOMRIGHT", shadow, "BOTTOMRIGHT", -size, 0)
        bottom:SetHeight(size)

        local left = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        left:SetTexture(C.WHITE8X8)
        left:SetPoint("TOPLEFT", shadow, "TOPLEFT", 0, -size)
        left:SetPoint("BOTTOMLEFT", shadow, "BOTTOMLEFT", 0, size)
        left:SetWidth(size)

        local right = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        right:SetTexture(C.WHITE8X8)
        right:SetPoint("TOPRIGHT", shadow, "TOPRIGHT", 0, -size)
        right:SetPoint("BOTTOMRIGHT", shadow, "BOTTOMRIGHT", 0, size)
        right:SetWidth(size)

        local tl = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        tl:SetTexture(C.WHITE8X8)
        tl:SetPoint("TOPLEFT", shadow, "TOPLEFT", 0, 0)
        tl:SetSize(size, size)

        local tr = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        tr:SetTexture(C.WHITE8X8)
        tr:SetPoint("TOPRIGHT", shadow, "TOPRIGHT", 0, 0)
        tr:SetSize(size, size)

        local bl = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        bl:SetTexture(C.WHITE8X8)
        bl:SetPoint("BOTTOMLEFT", shadow, "BOTTOMLEFT", 0, 0)
        bl:SetSize(size, size)

        local br = shadow:CreateTexture(nil, "BACKGROUND", nil, -7)
        br:SetTexture(C.WHITE8X8)
        br:SetPoint("BOTTOMRIGHT", shadow, "BOTTOMRIGHT", 0, 0)
        br:SetSize(size, size)

        shadow._muiSoft = soft
        shadow._muiTop = top
        shadow._muiBottom = bottom
        shadow._muiLeft = left
        shadow._muiRight = right
        shadow._muiTL = tl
        shadow._muiTR = tr
        shadow._muiBL = bl
        shadow._muiBR = br
        map._muiContainerShadow = shadow
    end

    shadow:ClearAllPoints()
    shadow:SetPoint("TOPLEFT", map, "TOPLEFT", -size, size)
    shadow:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", size, -size)
    shadow:SetFrameStrata(map:GetFrameStrata() or "HIGH")
    local frameLevel = map:GetFrameLevel() or 0
    frameLevel = frameLevel - 1
    if frameLevel < 0 then frameLevel = 0 end
    shadow:SetFrameLevel(frameLevel)

    shadow._muiSoft:SetVertexColor(0, 0, 0, C.MAP_CONTAINER_SHADOW_SOFT_ALPHA)
    UI.SetVerticalGradient(shadow._muiTop, 0, 0, 0, 0, 0, 0, 0, C.MAP_CONTAINER_SHADOW_ALPHA)
    UI.SetVerticalGradient(shadow._muiBottom, 0, 0, 0, C.MAP_CONTAINER_SHADOW_ALPHA, 0, 0, 0, 0)
    UI.SetHorizontalGradient(shadow._muiLeft, 0, 0, 0, 0, 0, 0, 0, C.MAP_CONTAINER_SHADOW_ALPHA)
    UI.SetHorizontalGradient(shadow._muiRight, 0, 0, 0, C.MAP_CONTAINER_SHADOW_ALPHA, 0, 0, 0, 0)

    shadow._muiTL:SetVertexColor(0, 0, 0, C.MAP_CONTAINER_SHADOW_CORNER_ALPHA)
    shadow._muiTR:SetVertexColor(0, 0, 0, C.MAP_CONTAINER_SHADOW_CORNER_ALPHA)
    shadow._muiBL:SetVertexColor(0, 0, 0, C.MAP_CONTAINER_SHADOW_CORNER_ALPHA)
    shadow._muiBR:SetVertexColor(0, 0, 0, C.MAP_CONTAINER_SHADOW_CORNER_ALPHA)

    if map.IsShown and map:IsShown() then shadow:Show()
    else shadow:Hide() end

    if type(map.HookScript) == "function" and not map._muiContainerShadowHooks then
        map:HookScript("OnShow", function(self)
            local s = self._muiContainerShadow
            if s then s:Show() end
        end)
        map:HookScript("OnHide", function(self)
            local s = self._muiContainerShadow
            if s then s:Hide() end
        end)
        map._muiContainerShadowHooks = true
    end
end

function UI.TryEnsureMapContainerShadow(map)
    if not map then return end
    -- Shadow container intentionally disabled per layout preference.
    if map._muiContainerShadow and type(map._muiContainerShadow.Hide) == "function" then
        map._muiContainerShadow:Hide()
    end
end

function UI.ApplyMapBaseSkin(map)
    local firstPass = not Runtime.baseSkinApplied
    Runtime.baseSkinApplied = true

    -- Solid dark background behind the canvas so the map is never
    -- see-through while tile textures are loading.
    -- Anchors are refined by AnchorHeaderToCanvas using the same visible-
    -- canvas insets as the header/nav bar, so the bg never bleeds outside
    -- the canvas bounds at any zoom level.
    if not map._muiCanvasBg then
        local host = map.ScrollContainer or map
        local bg = host:CreateTexture(nil, "BACKGROUND", nil, -8)
        bg:SetTexture(C.WHITE8X8)
        bg:SetAllPoints(host)
        bg:SetVertexColor(0.04, 0.04, 0.06, 1)
        map._muiCanvasBg = bg
    end
    map._muiCanvasBg:Show()

    UI.TryEnsureMapContainerShadow(map)

    if map.BlackoutFrame then
        map.BlackoutFrame:EnableMouse(false)
        map.BlackoutFrame:SetAlpha(0)
        if map.BlackoutFrame.Blackout then
            map.BlackoutFrame.Blackout:SetAlpha(0)
            map.BlackoutFrame.Blackout:Hide()
        end
        map.BlackoutFrame:Hide()
        if firstPass and not map.BlackoutFrame._muiMapHideHook then
            map.BlackoutFrame._muiMapHideHook = true
            map.BlackoutFrame:HookScript("OnShow", function(self) self:Hide() end)
        end
    end

    if _G.WorldMapFrameBg then UI.HideTexture(_G.WorldMapFrameBg) end

    if map.BorderFrame then
        map.BorderFrame:SetAlpha(0)
        map.BorderFrame:EnableMouse(false)
        UI.HideFrameRegions(map.BorderFrame)
        UI.HideTexture(map.BorderFrame.NineSlice)
        UI.HideTexture(map.BorderFrame.Bg)
        UI.HideTexture(map.BorderFrame.TopTileStreaks)
        UI.HideTexture(map.BorderFrame.InsetBorderTop)

        if map.BorderFrame.PortraitContainer then map.BorderFrame.PortraitContainer:Hide() end
        if map.BorderFrame.TitleContainer then map.BorderFrame.TitleContainer:Hide() end
        if map.BorderFrame.Tutorial then map.BorderFrame.Tutorial:Hide() end
        if map.BorderFrame.CloseButton then map.BorderFrame.CloseButton:Hide() end
        if map.BorderFrame.MaximizeMinimizeFrame then map.BorderFrame.MaximizeMinimizeFrame:Hide() end

        if firstPass and not map.BorderFrame._muiMapHideHook then
            map.BorderFrame._muiMapHideHook = true
            map.BorderFrame:HookScript("OnShow", function(self) self:SetAlpha(0) end)
        end
        if firstPass and map.BorderFrame.Bg and not map.BorderFrame.Bg._muiMapHideHook then
            map.BorderFrame.Bg._muiMapHideHook = true
            map.BorderFrame.Bg:HookScript("OnShow", function(self) self:Hide() end)
        end
    end

    local sidePanelToggle = map.SidePanelToggle
    local sidePanelOpenButton = sidePanelToggle and sidePanelToggle.OpenButton or nil
    if sidePanelOpenButton then
        sidePanelOpenButton:SetAlpha(0)
        if type(sidePanelOpenButton.EnableMouse) == "function" then
            sidePanelOpenButton:EnableMouse(false)
        end
        if type(sidePanelOpenButton.SetMouseClickEnabled) == "function" then
            pcall(sidePanelOpenButton.SetMouseClickEnabled, sidePanelOpenButton, false)
        end
        if type(sidePanelOpenButton.SetMouseMotionEnabled) == "function" then
            pcall(sidePanelOpenButton.SetMouseMotionEnabled, sidePanelOpenButton, false)
        end
        UI.HideFrameRegions(sidePanelOpenButton)
        if type(sidePanelOpenButton.Hide) == "function" then
            sidePanelOpenButton:Hide()
        end

        if firstPass and not sidePanelOpenButton._muiMapHideHook and type(sidePanelOpenButton.HookScript) == "function" then
            sidePanelOpenButton._muiMapHideHook = true
            sidePanelOpenButton:HookScript("OnShow", function(self)
                self:SetAlpha(0)
                if type(self.EnableMouse) == "function" then
                    self:EnableMouse(false)
                end
                if type(self.SetMouseClickEnabled) == "function" then
                    pcall(self.SetMouseClickEnabled, self, false)
                end
                if type(self.SetMouseMotionEnabled) == "function" then
                    pcall(self.SetMouseMotionEnabled, self, false)
                end
                if type(self.Hide) == "function" then
                    self:Hide()
                end
            end)
        end
    end

    if _G.WorldMapFrameTitleText then _G.WorldMapFrameTitleText:Hide() end

    -- Re-anchor ScrollContainer to fill the map frame with symmetric horizontal
    -- insets below the header. Blizzard's defaults leave asymmetric left/right
    -- padding for border chrome we hid, shifting the canvas right.
    local scroll = map.ScrollContainer
    if scroll and firstPass then
        local spacerH = C.HEADER_TOP_HEIGHT + C.HEADER_NAV_HEIGHT
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", map, "TOPLEFT", 0, -spacerH)
        scroll:SetPoint("BOTTOMRIGHT", map, "BOTTOMRIGHT", 0, 0)
        -- Ensure the header draws above the scroll container
        scroll:SetFrameLevel(map:GetFrameLevel() + 1)
    end
end

local _centeredAnchorDepth = 0
function UI.ApplyCenteredMapAnchor(map, parent)
    if not map then return end
    if _centeredAnchorDepth > 1 then return end
    _centeredAnchorDepth = _centeredAnchorDepth + 1
    local anchorParent = parent or map:GetParent() or UIParent
    if not anchorParent then _centeredAnchorDepth = _centeredAnchorDepth - 1 return end

    local centerOffsetX = 0
    local panelOpen = (Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function" and Addon.QuestLogPanel.IsOpen())
        or (Runtime.questLogPanelOpen == true)
    local panel = map._muiQuestLogPanel
    if panel then
        local panelRequestedOpen = (panel._muiQuestPanelDesiredOpen == true)
        panelOpen = panelOpen or panelRequestedOpen
    end
    if panelOpen then
        local reservation = UI.GetQuestPanelWidth() + UI.GetQuestPanelShownOffset()
        centerOffsetX = -math.floor((reservation * 0.5) + 0.5)
    end

    -- Only re-anchor if the offset actually changed to avoid per-frame flicker
    local needsUpdate = true
    if map:GetNumPoints() == 1 then
        local pt, rel, relPt, curX, curY = map:GetPoint(1)
        if pt == "CENTER" and rel == anchorParent and relPt == "CENTER"
            and math.abs((curX or 0) - centerOffsetX) < 0.5 and math.abs(curY or 0) < 0.5 then
            needsUpdate = false
        end
    end
    if needsUpdate then
        map:ClearAllPoints()
        map:SetPoint("CENTER", anchorParent, "CENTER", centerOffsetX, 0)
    end
    _centeredAnchorDepth = _centeredAnchorDepth - 1
end

function UI.QueueCenteredMapAnchor(map, parent, reason)
    if not map then return end
    local anchorParent = parent or map:GetParent() or UIParent
    UI.ApplyCenteredMapAnchor(map, anchorParent)

    if Runtime.mapCenterSyncQueued then return end
    if not C_Timer or type(C_Timer.After) ~= "function" then return end

    Runtime.mapCenterSyncQueued = true
    C_Timer.After(0, function()
        Runtime.mapCenterSyncQueued = false
        if not map or not map:IsShown() then return end
        UI.ApplyCenteredMapAnchor(map, anchorParent)

        if Util.IsMapNavDebugEnabled() and Util.ShouldEmitDebugToken("mapCenterSync:" .. Util.SafeToString(reason), 0.10) then
        end
    end)
end

function UI.QueueHiddenMapCenterSettle(map, parent, reason)
    if not map then return end
    local anchorParent = parent or map:GetParent() or UIParent
    if not anchorParent then return end

    local token = (Runtime.mapCloseCenterSettleToken or 0) + 1
    Runtime.mapCloseCenterSettleToken = token
    local baseReason = Util.SafeToString(reason or "unknown")

    local function Reassert(tag)
        if Runtime.mapCloseCenterSettleToken ~= token then return end
        if not map then return end
        if Util.IsInLockdown() then
            Runtime.pendingMapCloseCenterSettle = true
            Runtime.pendingMapCloseCenterReason = baseReason .. ":" .. Util.SafeToString(tag or "unknown")
            return
        end
        UI.ApplyCenteredMapAnchor(map, anchorParent)
    end

    Reassert("t+0.00")
    if not C_Timer or type(C_Timer.After) ~= "function" then return end

    C_Timer.After(0, function() Reassert("t+0.00") end)
    C_Timer.After(0.20, function() Reassert("t+0.20") end)
end

function UI.EnsureMapCanvasInput(map)
    if not map then return end
    local scroll = map.ScrollContainer
    if not scroll then return end

    if type(scroll.EnableMouse) == "function" then
        scroll:EnableMouse(true)
    end
    if type(scroll.EnableMouseWheel) == "function" then
        scroll:EnableMouseWheel(true)
    end
    if type(scroll.SetMouseClickEnabled) == "function" then
        pcall(scroll.SetMouseClickEnabled, scroll, true)
    end
    if type(scroll.SetMouseMotionEnabled) == "function" then
        pcall(scroll.SetMouseMotionEnabled, scroll, true)
    end

    local canvas = scroll.Child or scroll.child or scroll.Canvas
    if not canvas then return end
    UI.EnsureMapAnnotationCaptureOverlay(map)
    UI.SetMapAnnotationCursor(Runtime.annotation and Runtime.annotation.active == true, map)
    UI.RenderMapAnnotations(map)
    if type(canvas.EnableMouse) == "function" then
        canvas:EnableMouse(true)
    end
    if type(canvas.EnableMouseWheel) == "function" then
        canvas:EnableMouseWheel(true)
    end

    if type(scroll.RegisterForDrag) == "function" then
        pcall(scroll.RegisterForDrag, scroll, "LeftButton")
    end
    if type(canvas.RegisterForDrag) == "function" then
        pcall(canvas.RegisterForDrag, canvas, "LeftButton")
    end

    if not scroll._muiMapPanHooks and type(scroll.HookScript) == "function" then
        local function TryPanStart()
            if Runtime.annotation and Runtime.annotation.active == true then
                return
            end
            if type(scroll.StartPan) == "function" then
                local ok = pcall(scroll.StartPan, scroll)
                if ok then return end
            end
            if type(scroll.OnMouseDown) == "function" then
                local ok = pcall(scroll.OnMouseDown, scroll, "LeftButton")
                if ok then return end
            end
            if type(canvas.StartPan) == "function" then
                local ok = pcall(canvas.StartPan, canvas)
                if ok then return end
            end
            if type(canvas.OnMouseDown) == "function" then
                pcall(canvas.OnMouseDown, canvas, "LeftButton")
            end
        end

        local function TryPanStop()
            if Runtime.annotation and Runtime.annotation.active == true then
                return
            end
            if type(scroll.StopPan) == "function" then
                local ok = pcall(scroll.StopPan, scroll)
                if ok then return end
            end
            if type(scroll.OnMouseUp) == "function" then
                local ok = pcall(scroll.OnMouseUp, scroll, "LeftButton")
                if ok then return end
            end
            if type(canvas.StopPan) == "function" then
                local ok = pcall(canvas.StopPan, canvas)
                if ok then return end
            end
            if type(canvas.OnMouseUp) == "function" then
                pcall(canvas.OnMouseUp, canvas, "LeftButton")
            end
        end

        scroll:HookScript("OnMouseDown", function(_, button)
            if button == "LeftButton" then
                TryPanStart()
            end
        end)
        scroll:HookScript("OnMouseUp", function(_, button)
            if button == "LeftButton" then
                TryPanStop()
            end
        end)
        scroll:HookScript("OnDragStart", function(_, button)
            if not button or button == "LeftButton" then
                TryPanStart()
            end
        end)
        scroll:HookScript("OnDragStop", function(_, button)
            if not button or button == "LeftButton" then
                TryPanStop()
            end
        end)
        if type(canvas.HookScript) == "function" then
            canvas:HookScript("OnMouseDown", function(_, button)
                if button == "LeftButton" then
                    TryPanStart()
                end
            end)
            canvas:HookScript("OnMouseUp", function(_, button)
                if button == "LeftButton" then
                    TryPanStop()
                end
            end)
            canvas:HookScript("OnDragStart", function(_, button)
                if not button or button == "LeftButton" then
                    TryPanStart()
                end
            end)
            canvas:HookScript("OnDragStop", function(_, button)
                if not button or button == "LeftButton" then
                    TryPanStop()
                end
            end)
        end
        scroll._muiMapPanHooks = true
    end

    if not scroll._muiMapRightClickZoomHook and type(scroll.HookScript) == "function" then
        local function HandleRightClickZoom(button)
            if button ~= "RightButton" then return end
            if Runtime.annotation and Runtime.annotation.contextMenuOpen == true then return end
            local hoveredNote = UI.FindMapAnnotationUnderCursor(map)
            Util.MapAnnotationInputLog(
                "rightClick:canvas",
                string.format("hoveredNote=%s noteId=%s", Util.SafeToString(hoveredNote ~= nil), Util.SafeToString(hoveredNote and hoveredNote.id)),
                true
            )
            if hoveredNote then
                Util.MapAnnotationInputLog("rightClick:canvas", "action=contextMenu", true)
                UI.ShowMapAnnotationContextMenu(scroll, hoveredNote)
                return
            end
            if UI.GetMapHiddenAnnotationCount(UI.GetActiveMapID(map)) > 0 then
                Util.MapAnnotationInputLog("rightClick:canvas", "action=hiddenMenu", true)
                UI.ShowMapAnnotationHiddenNotesMenu(scroll, map)
                return
            end
            Util.MapAnnotationInputLog("rightClick:canvas", "action=zoomOut", true)
            UI.TryZoomOutMapOneLevel(map, "canvasRightClick")
        end

        scroll:HookScript("OnMouseUp", function(_, button)
            HandleRightClickZoom(button)
        end)
        if type(canvas.HookScript) == "function" then
            canvas:HookScript("OnMouseUp", function(_, button)
                HandleRightClickZoom(button)
            end)
        end
        scroll._muiMapRightClickZoomHook = true
    end
end

function UI.IsMapGeometryTraceActive()
    local dbg = Runtime.debug or nil
    if type(dbg) ~= "table" then return false end

    local token = dbg.mapGeometryTraceToken
    if type(token) ~= "number" or token <= 0 then return false end

    local expiresAt = dbg.mapGeometryTraceExpiresAt
    if type(GetTime) == "function" and type(expiresAt) == "number" and expiresAt > 0 and GetTime() > expiresAt then
        dbg.mapGeometryTraceToken = 0
        return false
    end

    return true
end

function UI.BuildMapGeometryMutationSummary(mutation)
    if type(mutation) ~= "table" then
        return "lastMutation=nil"
    end

    return string.format(
        "lastMutation[token=%s kind=%s t+%s caller=%s details=%s]",
        Util.FormatDebugValue(mutation.token),
        Util.SafeToString(mutation.kind),
        Util.FormatDebugValue(mutation.since),
        Util.SafeToString(mutation.caller),
        Util.SafeToString(mutation.details)
    )
end

function UI.IsMapMutationProbeActive()
    local probe = Runtime.debug and Runtime.debug.mapMutationProbe or nil
    if type(probe) ~= "table" or probe.active ~= true then return false end

    local expiresAt = probe.expiresAt
    if type(GetTime) == "function" and type(expiresAt) == "number" and expiresAt > 0 and GetTime() > expiresAt then
        Runtime.debug.mapMutationProbe = nil
        return false
    end
    return true
end

function UI.IsMapVisibilityProbeActive()
    local probe = Runtime.debug and Runtime.debug.mapVisibilityProbe or nil
    if type(probe) ~= "table" or probe.active ~= true then return false end

    local expiresAt = probe.expiresAt
    if type(GetTime) == "function" and type(expiresAt) == "number" and expiresAt > 0 and GetTime() > expiresAt then
        Runtime.debug.mapVisibilityProbe = nil
        return false
    end
    return true
end

function UI.SetMapVisibilityHold(enabled, reason, source)
    local nextState = (enabled == true)
    local prevState = (Runtime.mapVisibilityHold == true)
    local prevReason = Util.SafeToString(Runtime.mapVisibilityHoldReason)

    Runtime.mapVisibilityHold = nextState
    Runtime.mapVisibilityHoldReason = nextState and Util.SafeToString(reason or "unspecified") or nil

    local map = _G.WorldMapFrame
    local mapShown = (map and map.IsShown and map:IsShown()) and "true" or "false"
    local mapAlpha = map and Util.FormatNumber(Util.SafeMethodRead(map, "GetAlpha")) or "nil"
    if UI.IsMapVisibilityProbeActive() then
    end
end

function UI.InstallMapGeometryMutationHooks(map)
    if not map or map._muiMapGeometryHooksInstalled then return end
    map._muiMapGeometryHooksInstalled = true

    if type(map.ClearAllPoints) == "function" then
        hooksecurefunc(map, "ClearAllPoints", function(self)
            if self ~= map then return end
            local details = "map:ClearAllPoints()"
        end)
    end

    if type(map.SetPoint) == "function" then
        local _setPointDepth = 0
        hooksecurefunc(map, "SetPoint", function(self, point, relativeTo, relativePoint, x, y)
            if self ~= map then return end
            local details = string.format(
                "%s->%s.%s(%s,%s)",
                Util.SafeToString(point),
                Util.GetFrameDebugName(relativeTo),
                Util.SafeToString(relativePoint),
                Util.FormatNumber(x),
                Util.FormatNumber(y)
            )
            -- Correct any non-CENTER anchor (e.g. TOP from Blizzard's UIPanel
            -- manager) back to CENTER immediately so the map never renders at
            -- the wrong position, even for a single frame.
            if not Runtime.mapAnchorCorrectGuard and not Runtime.commitInProgress then
                local p = type(point) == "string" and point:upper() or ""
                if p ~= "" and p ~= "CENTER" then
                    if _setPointDepth > 0 then return end
                    _setPointDepth = _setPointDepth + 1
                    Runtime.mapAnchorCorrectGuard = true
                    local ok, err = pcall(UI.ApplyCenteredMapAnchor, self, self:GetParent() or UIParent)
                    Runtime.mapAnchorCorrectGuard = false
                    _setPointDepth = _setPointDepth - 1
                end
            end
        end)
    end

    if type(map.SetSize) == "function" then
        hooksecurefunc(map, "SetSize", function(self, width, height)
            if self ~= map then return end
            local details = string.format("w=%s h=%s", Util.FormatNumber(width), Util.FormatNumber(height))
        end)
    end

    if type(map.SetScale) == "function" then
        hooksecurefunc(map, "SetScale", function(self, scale)
            if self ~= map then return end
            local details = "scale=" .. Util.FormatNumber(scale)
        end)
    end

    if type(map.SetAlpha) == "function" then
        local _setAlphaDepth = 0
        hooksecurefunc(map, "SetAlpha", function(self, alpha)
            if self ~= map then return end
            local details = "alpha=" .. Util.FormatNumber(alpha)
            if Runtime.mapVisibilityHold == true and not Runtime.mapVisibilityHoldClampGuard then
                local requested = tonumber(alpha) or 0
                if requested > 0 then
                    if _setAlphaDepth > 0 then return end
                    _setAlphaDepth = _setAlphaDepth + 1
                    Runtime.mapVisibilityHoldClampGuard = true
                    local ok, err = pcall(self.SetAlpha, self, 0)
                    Runtime.mapVisibilityHoldClampGuard = false
                    _setAlphaDepth = _setAlphaDepth - 1
                end
            end
            if Runtime.mapVisibilityHold ~= true then
                local requested = tonumber(alpha) or 0
                if requested > 0 and self.IsShown and not self:IsShown() then
                end
            end
        end)
    end

    if type(SetUIPanelAttribute) == "function" then
        hooksecurefunc("SetUIPanelAttribute", function(frame, attribute, value)
            if frame ~= map then return end
            if attribute ~= "area"
                and attribute ~= "xoffset"
                and attribute ~= "yoffset"
                and attribute ~= "leftClamp"
                and attribute ~= "rightClamp"
                and attribute ~= "bottomClampOverride" then
                return
            end
            local details = string.format("attr=%s value=%s", Util.SafeToString(attribute), Util.FormatDebugValue(value))
        end)
    end

    if type(UpdateUIPanelPositions) == "function" then
        hooksecurefunc("UpdateUIPanelPositions", function(frame)
            if frame and frame ~= map then return end
            local details = "frame=" .. Util.GetFrameDebugName(frame)
        end)
    end
end

function UI.ApplyMaximizedInsets(map, reason)
    local mapContainerScale = tonumber(C.MAP_CONTAINER_SCALE)
    if type(mapContainerScale) ~= "number" then
        mapContainerScale = 0.65
    end
    -- Scale boost based on available screen width so the map does not
    -- overflow smaller displays.  Full 1.30× at 1920+, down to 1.00× at 1280.
    local boostFactor = 1.30
    local parent0 = (map and map:GetParent()) or UIParent
    local pw0 = parent0 and parent0.GetWidth and parent0:GetWidth() or 1920
    if type(pw0) == "number" and pw0 < 1920 then
        boostFactor = Util.Clamp(1.00 + 0.30 * ((pw0 - 1280) / (1920 - 1280)), 1.00, 1.30)
    end
    mapContainerScale = mapContainerScale * boostFactor
    mapContainerScale = Util.Clamp(mapContainerScale, 0.45, 1.00)

    local decision = {
        reason = Util.SafeToString(reason or Runtime.currentLayoutReason or "unknown"),
        mapScaleCfg = C.MAP_MAXIMIZED_SCALE,
        mapContainerScale = mapContainerScale,
    }

    if not map then
        decision.status = "skip:no-map"
        return
    end

    decision.isMaximized = (map.IsMaximized and map:IsMaximized()) and true or false

    local parent = map:GetParent() or UIParent
    decision.parentName = Util.GetFrameDebugName(parent)
    local parentWidth, parentHeight = parent:GetSize()
    decision.parentWidth = parentWidth
    decision.parentHeight = parentHeight
    if type(parentWidth) ~= "number" or type(parentHeight) ~= "number" or parentWidth <= 0 or parentHeight <= 0 then
        decision.status = "skip:invalid-parent-size"
        return
    end

    local topInset = C.MAP_MAXIMIZED_TOP_INSET
    local bottomInset = C.MAP_MAXIMIZED_BOTTOM_INSET
    local usableHeight = parentHeight - (topInset + bottomInset)
    if usableHeight < 380 then usableHeight = 380 end
    decision.usableHeight = usableHeight

    local spacerHeight = C.HEADER_TOP_HEIGHT + C.HEADER_NAV_HEIGHT
    local minimizedWidth = map.minimizedWidth or 702
    local minimizedHeight = map.minimizedHeight or 534
    local denominator = minimizedHeight - spacerHeight
    decision.minimizedWidth = minimizedWidth
    decision.minimizedHeight = minimizedHeight
    decision.denominator = denominator
    if denominator <= 0 then
        decision.status = "skip:invalid-denominator"
        return
    end

    local usableWidth = parentWidth - C.MAP_DEFAULT_SCREEN_BORDER
    local unclampedWidth = ((usableHeight - spacerHeight) * minimizedWidth) / denominator
    decision.usableWidth = usableWidth
    decision.unclampedWidth = unclampedWidth
    if unclampedWidth <= 0 then
        decision.status = "skip:invalid-unclamped-width"
        return
    end

    local clampedWidth = math.min(usableWidth, unclampedWidth)
    local clampedHeight = ((usableHeight - spacerHeight) * (clampedWidth / unclampedWidth)) + spacerHeight
    local scaledWidth = clampedWidth * C.MAP_MAXIMIZED_SCALE * mapContainerScale
    local scaledHeight = clampedHeight * C.MAP_MAXIMIZED_SCALE * mapContainerScale
    local finalWidth = math.max(480, math.floor(scaledWidth))
    local finalHeight = math.max(360, math.floor(scaledHeight))

    -- Ensure map + quest panel fits within the screen width.  Without this
    -- guard the height-driven width can exceed available horizontal space on
    -- narrow or 4:3 displays, pushing the quest panel off-screen.
    -- Only reserve space when the quest panel is actually open; otherwise
    -- the map shrinks unnecessarily, leaving a dark gap.
    local questReservation = 0
    local questPanelOpen = (Addon.QuestLogPanel and type(Addon.QuestLogPanel.IsOpen) == "function" and Addon.QuestLogPanel.IsOpen())
        or (Runtime.questLogPanelOpen == true)
    if questPanelOpen then
        pcall(function()
            questReservation = UI.GetQuestPanelWidth() + UI.GetQuestPanelShownOffset()
        end)
    end
    local maxFitWidth = parentWidth - questReservation - C.MAP_DEFAULT_SCREEN_BORDER
    if maxFitWidth > 0 and finalWidth > maxFitWidth then
        local shrinkRatio = maxFitWidth / finalWidth
        finalWidth = math.max(480, math.floor(maxFitWidth))
        finalHeight = math.max(360, math.floor(finalHeight * shrinkRatio))
    end

    decision.clampedWidth = clampedWidth
    decision.clampedHeight = clampedHeight
    decision.scaledWidth = scaledWidth
    decision.scaledHeight = scaledHeight
    decision.finalWidth = finalWidth
    decision.finalHeight = finalHeight

    -- Emit insets decision to Map Diagnostics if active
    local mapDiag = _G.MidnightUI_MapDiag
    if mapDiag and mapDiag.IsEnabled and mapDiag.IsEnabled() then
        pcall(function()
            local log = mapDiag.GetLog and mapDiag.GetLog()
            if log then
                local prevW = map.GetWidth and map:GetWidth() or 0
                local prevH = map.GetHeight and map:GetHeight() or 0
                local detail = string.format(
                    "reason=%s final=%.0fx%.0f prev=%.0fx%.0f scale=%.3f boost=%.3f parent=%.0fx%.0f usable=%.0fx%.0f",
                    Util.SafeToString(decision.reason),
                    finalWidth, finalHeight, prevW, prevH,
                    mapContainerScale, boostFactor,
                    parentWidth, parentHeight,
                    usableWidth, usableHeight)
                local extra = ""
                if math.abs(prevW - finalWidth) > 0.5 or math.abs(prevH - finalHeight) > 0.5 then
                    extra = string.format("SIZE CHANGED: %.1fx%.1f -> %.1fx%.1f (delta w=%.1f h=%.1f)",
                        prevW, prevH, finalWidth, finalHeight,
                        finalWidth - prevW, finalHeight - prevH)
                end
                log[#log + 1] = { at = GetTime(), seq = 0, kind = "ApplyMaxInsets", details = detail, extra = extra }
                if #log > 200 then table.remove(log, 1) end
            end
        end)
    end

    -- Store baseline for zoom-responsive container resizing, then apply the
    -- zoom-adjusted width inline so every ApplyLayout pass respects min zoom.
    map._muiBaselineWidth = finalWidth
    map._muiBaselineHeight = finalHeight

    local effectiveWidth = finalWidth

    -- Primary: honour the persistent override set by AdjustContainerForZoom.
    -- This survives Blizzard callbacks (UpdateUIPanelPositions, deferred
    -- layout passes) that would otherwise widen the frame back to baseline.
    if map._muiZoomAdjustedWidth and map._muiZoomAdjustedWidth < finalWidth then
        effectiveWidth = map._muiZoomAdjustedWidth
    else
        -- Fallback: compute inline (covers first open before Adjust has run).
        local scroll = map.ScrollContainer
        if scroll then
            local canvas = scroll.Child or scroll.child or scroll.Canvas
            if canvas then
                local canvasW = canvas:GetWidth()
                local canvasScale = Util.SafeMethodRead(scroll, "GetCanvasScale")
                if type(canvasW) == "number" and type(canvasScale) == "number"
                    and canvasW > 0 and canvasScale > 0 then
                    local scrollW = scroll:GetWidth()
                    local padding = map:GetWidth() - scrollW
                    if type(padding) ~= "number" or padding < 0 then padding = 0 end
                    local baseScrollW = finalWidth - padding
                    local projectedW = canvasW * canvasScale
                    if projectedW < baseScrollW then
                        effectiveWidth = math.floor(projectedW + padding)
                    end
                end
            end
        end
    end

    Runtime.commitInProgress = true
    local commitOk, commitErr = pcall(function()
        -- Only call SetSize if the dimensions actually changed
        local curW, curH = map:GetSize()
        if math.abs(curW - effectiveWidth) > 0.5 or math.abs(curH - finalHeight) > 0.5 then
            map:SetSize(effectiveWidth, finalHeight)
        end

        local bottomClampOverride = (usableHeight - clampedHeight) / 2
        decision.bottomClampOverride = bottomClampOverride
        if type(SetUIPanelAttribute) == "function" then
            SetUIPanelAttribute(map, "bottomClampOverride", bottomClampOverride)
        end

        decision.panelPositionUpdated = false
        if type(UpdateUIPanelPositions) == "function" then
            UpdateUIPanelPositions(map)
            decision.panelPositionUpdated = true
        end

        -- UpdateUIPanelPositions can reset the frame width to baseline AND revert
        -- the maximized state.  Re-maximize and re-apply the adjusted width.
        if not Util.IsInLockdown() and type(map.Maximize) == "function" then
            if not map.IsMaximized or not map:IsMaximized() then
                pcall(map.Maximize, map)
            end
        end
        if effectiveWidth < finalWidth then
            local curW2, curH2 = map:GetSize()
            if math.abs(curW2 - effectiveWidth) > 0.5 or math.abs(curH2 - finalHeight) > 0.5 then
                map:SetSize(effectiveWidth, finalHeight)
            end
        end
    end)
    Runtime.commitInProgress = false

    -- Reassert center anchoring after UIPanel manager layout, which can shift
    -- the map left when the effective map size/scale is very small.
    UI.QueueCenteredMapAnchor(map, parent, "ApplyMaximizedInsets")
    decision.centerReassertQueued = true
    decision.status = "applied"
end

-- =========================================================================
-- Zoom-responsive container resize
-- When the canvas doesn't fill the viewport width at min zoom (canvasScale
-- 0.29), shrink the map frame to match so there is no visible dark gap.
-- Restore the baseline size when zooming back in (0.41+).
-- =========================================================================

local ZOOM_RESIZE_DURATION = 0.20  -- seconds, matches Blizzard zoom anim


-- Apply a single frame of the container resize: SetSize, re-center, and
-- re-anchor header / BG.  Shared by both instant and animated paths.
local function ApplyContainerWidth(map, w, baseH)
    -- Skip if size is already at target (prevents unnecessary reflows)
    local curW, curH = map:GetSize()
    if math.abs(curW - w) <= 0.5 and math.abs(curH - baseH) <= 0.5 then return end

    Runtime.zoomResizeInProgress = true
    Runtime.commitInProgress = true
    local ok, err = pcall(function()
        map:SetSize(w, baseH)
        UI.ApplyCenteredMapAnchor(map, map:GetParent() or UIParent)
    end)
    Runtime.commitInProgress = false
    Runtime.zoomResizeInProgress = false
end

-- Lazy-created hidden frame that drives the OnUpdate resize animation.
local function GetResizeAnimDriver()
    if UI._zoomResizeDriver then return UI._zoomResizeDriver end
    local f = CreateFrame("Frame")
    f:Hide()
    f:SetScript("OnUpdate", function(self)
        local d = self._animData
        if not d then self:Hide(); return end
        local map = d.map
        if not map or not (map.IsShown and map:IsShown()) then
            self:Hide(); self._animData = nil; return
        end

        local progress = (GetTime() - d.startTime) / d.duration
        if progress >= 1 then progress = 1 end

        -- Ease-out cubic: fast start, gentle settle
        local t = 1 - (1 - progress) ^ 3
        local w = math.floor(d.fromW + (d.toW - d.fromW) * t + 0.5)
        ApplyContainerWidth(map, w, d.baseH)

        if progress >= 1 then
            self:Hide()
            self._animData = nil
            UI.QueueQuestPanelAnchorSettle(map, "ZoomResizeAnimDone")
        end
    end)
    UI._zoomResizeDriver = f
    return f
end

-- Returns true if a zoom resize animation is running toward targetW.
local function IsAnimatingToward(targetW)
    local driver = UI._zoomResizeDriver
    return driver and driver._animData and driver:IsShown()
        and driver._animData.toW == targetW
end

-- Compute the needed map width for the current zoom level.
-- Returns neededMapW, baseW, baseH, scroll, isShrinking  or nil on bail-out.
local function ComputeZoomWidth()
    local map = _G.WorldMapFrame
    if not map or not (map.IsShown and map:IsShown()) then return end

    local baseW = map._muiBaselineWidth
    local baseH = map._muiBaselineHeight
    if type(baseW) ~= "number" or type(baseH) ~= "number" then return end

    local scroll = map.ScrollContainer
    if not scroll then return end
    local canvas = scroll.Child or scroll.child or scroll.Canvas
    if not canvas then return end

    local canvasW = canvas:GetWidth()
    local canvasScale = Util.SafeMethodRead(scroll, "GetCanvasScale")
    if type(canvasW) ~= "number" or type(canvasScale) ~= "number"
        or canvasW <= 0 or canvasScale <= 0 then return end

    local currentMapW = map:GetWidth()
    local currentMapH = map:GetHeight()
    local scrollW = scroll:GetWidth()
    local scrollH = scroll:GetHeight()
    local padding = currentMapW - scrollW
    if type(padding) ~= "number" or padding < 0 then padding = 0 end
    local baseScrollW = baseW - padding
    local projectedW = canvasW * canvasScale

    local neededMapW
    if projectedW >= baseScrollW then
        neededMapW = baseW
        map._muiZoomAdjustedWidth = nil
    else
        neededMapW = math.floor(projectedW + padding)
        map._muiZoomAdjustedWidth = neededMapW
    end
    if neededMapW > baseW then neededMapW = baseW end

    return neededMapW, baseW, baseH, scroll, (neededMapW < baseW)
end

-- Animated entry point — disabled to prevent per-frame SetSize flicker.
-- Container resize now happens only via the instant AdjustContainerForZoom path.
function UI.AnimateContainerForZoom()
    -- No-op: animated resize caused visual flicker because Blizzard's scroll
    -- container reflows on every SetSize, producing black-frame artifacts.
    -- The staggered C_Timer calls to AdjustContainerForZoom handle the resize
    -- after Blizzard's zoom animation settles.
    return
end

-- NOTE: Blizzard's World Map only supports discrete zoom levels (0.29,
-- 0.41, 0.53 …).  SetNormalizedZoom and SetCanvasScale both snap to the
-- nearest valid level — intermediate values are ignored.  Continuous zoom
-- interpolation is not possible through the scroll controller API.

-- Instant entry point — safety-net for staggered timers and ApplyLayout.
function UI.AdjustContainerForZoom()
    if Runtime.zoomResizeInProgress then return end
    if Runtime.relayoutInProgress then return end

    local neededMapW, baseW, baseH, scroll, isShrinking = ComputeZoomWidth()
    if not neededMapW then return end
    -- Don't interrupt an in-progress animation toward the correct target.
    if IsAnimatingToward(neededMapW) then return end

    local map = _G.WorldMapFrame
    local currentW = math.floor(map:GetWidth() + 0.5)
    if math.abs(currentW - neededMapW) <= 1 then return end

    -- Recenter canvas when shrinking.
    if isShrinking and type(scroll.SetPanTarget) == "function" then
        pcall(scroll.SetPanTarget, scroll, 0.5, 0.5)
    end

    ApplyContainerWidth(map, neededMapW, baseH)
    UI.QueueQuestPanelAnchorSettle(map, "ZoomContainerResize")
end

function Util.IsInLockdown()
    return type(InCombatLockdown) == "function" and InCombatLockdown() == true
end

ApplyLayout = function(reason)
    if Runtime.relayoutInProgress then return end
    local map = _G.WorldMapFrame
    if not map then return end

    if Util.IsInLockdown() then
        Runtime.pendingLayout = true
        return
    end

    Runtime.relayoutInProgress = true
    Runtime.pendingLayout = false
    Runtime.currentLayoutReason = Util.SafeToString(reason or "unknown")

    -- Emit to Map Diagnostics if active
    local mapDiag = _G.MidnightUI_MapDiag
    if mapDiag and mapDiag.IsEnabled and mapDiag.IsEnabled() then
        local prevW = map.GetWidth and map:GetWidth() or 0
        local prevH = map.GetHeight and map:GetHeight() or 0
        local scroll = map.ScrollContainer
        local zoomStr = ""
        if scroll then
            local nz = scroll.GetNormalizedZoom and scroll:GetNormalizedZoom() or 0
            local cs = scroll.GetCanvasScale and scroll:GetCanvasScale() or 0
            zoomStr = string.format(" zoom=%.4f canvasScale=%.4f", nz, cs)
        end
        pcall(function()
            local logFn = mapDiag.GetLog and function(kind, detail, extra)
                local log = mapDiag.GetLog()
                if log then
                    log[#log + 1] = { at = GetTime(), seq = 0, kind = kind, details = detail, extra = extra or "" }
                    if #log > 200 then table.remove(log, 1) end
                end
            end
            if logFn then
                logFn("ApplyLayout", string.format("reason=%s preSize=%.1fx%.1f%s",
                    Runtime.currentLayoutReason, prevW, prevH, zoomStr), "")
            end
        end)
    end

    pcall(function()
        -- Always suppress Blizzard's built-in QuestMapFrame when the custom
        -- questing interface is active.  Without this, QuestMapFrame stays
        -- visible on characters where it was previously shown, stealing 330px
        -- from the scroll container and showing the default quest log.
        local qmf = _G.QuestMapFrame
        if qmf then
            if qmf.IsShown and qmf:IsShown() then
                pcall(function() qmf:Hide() end)
            end
            -- Keep it hidden when Blizzard re-shows it during navigation
            if not qmf._muiMapLayoutHideHook then
                qmf._muiMapLayoutHideHook = true
                pcall(function()
                    qmf:HookScript("OnShow", function(self)
                        if Util.IsCustomQuestingInterfaceEnabled() then
                            self:Hide()
                        end
                    end)
                end)
            end
        end

        UI.ApplyMapBaseSkin(map)
        UI.EnsureMapCanvasInput(map)
        UI.RenderMapAnnotations(map)
        UI.ApplyMaximizedInsets(map, Runtime.currentLayoutReason)
        UI.QueueCenteredMapAnchor(map, map:GetParent() or UIParent, "ApplyLayout:post-inset")
        UI.CollectWorldMapControls(map)

        local layout = UI.EnsureHeaderLayout(map)
        UI.EnsureScrollAnchorSyncHooks(map)
        UI.AnchorHeaderToCanvas(map, layout, "ApplyLayout:" .. Util.SafeToString(reason))
        UI.UpdateHeaderTitle(map)
        UI.LayoutRightControls(layout)
        UI.LayoutNavBar(layout)

        UI.SyncQuestLogPanelLayout(map)
        UI.QueueQuestPanelAnchorSettle(map, "ApplyLayout:" .. Util.SafeToString(reason))

        if PlayerMovementFrameFader and type(PlayerMovementFrameFader.RemoveFrame) == "function" then
            pcall(PlayerMovementFrameFader.RemoveFrame, map)
        end
        if map.IsShown and map:IsShown() then
            -- Force center anchor immediately before reveal so any deferred
            -- Blizzard UIPanel repositioning (TOP anchor) is overridden before
            -- the map becomes visible.
            UI.ApplyCenteredMapAnchor(map, map:GetParent() or UIParent)
            if Runtime.mapVisibilityHold == true then
                UI.SetMapVisibilityHold(false, nil, "ApplyLayout:reveal")
            end
            map:SetAlpha(1)
        else
        end
    end)

    if map and (map.IsShown and map:IsShown()) and Runtime.mapVisibilityHold == true then
        UI.SetMapVisibilityHold(false, nil, "ApplyLayout:pcall-fallback")
        map:SetAlpha(1)
    end
    
    Runtime.currentLayoutReason = nil
    Runtime.relayoutInProgress = false
    -- Re-apply zoom-responsive container resize after layout settles so the
    -- map frame matches the projected canvas width at min zoom.
    if UI.AdjustContainerForZoom and C_Timer and type(C_Timer.After) == "function" then
        C_Timer.After(0, UI.AdjustContainerForZoom)
    end
    if reason ~= "PostLayoutSync" then UI.QueuePostLayoutSync() end
end

function UI.InstallHooks()
    if Runtime.hooksInstalled then return end
    local map = _G.WorldMapFrame
    if not map then return end

    UI.InstallMapGeometryMutationHooks(map)

    -- Hook zoom operations to trigger container resize via UI.AdjustContainerForZoom
    -- (defined above ApplyLayout).  Fire after zoom animations settle via C_Timer.
    local scroll = map.ScrollContainer
    if scroll then
        local function QueueAdjust()
            UI.AnimateContainerForZoom()
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0.05, UI.AdjustContainerForZoom)
                C_Timer.After(0.25, UI.AdjustContainerForZoom)
                C_Timer.After(0.50, UI.AdjustContainerForZoom)
            end
        end
        scroll:HookScript("OnMouseWheel", QueueAdjust)
        local zoomMethods = { "ZoomIn", "ZoomOut", "SetCanvasScale", "SetZoomTarget",
            "SetNormalizedZoom", "PanAndZoomTo", "PanAndZoomToNormalized" }
        for _, methodName in ipairs(zoomMethods) do
            if type(scroll[methodName]) == "function" then
                pcall(hooksecurefunc, scroll, methodName, QueueAdjust)
            end
        end

        -- NOTE: Blizzard's World Map uses discrete zoom levels.  Do not
        -- override SetMouseWheelZoomMode or SetShouldZoomInstantly — it
        -- causes jumpy, unresponsive zoom behavior.
    end

    map:HookScript("OnShow", function(self)
        if Util.IsInLockdown() then
            UI.SetMapVisibilityHold(false, nil, "OnShow:bypass_combat")
            -- In combat we cannot run full relayout; keep map visible.
            self:SetAlpha(1)
        else
            UI.SetMapVisibilityHold(true, "WorldMap:OnShow", "OnShow:hold_open")
            -- Hide first show frame so transient TOP/TOPLEFT anchors are not visible.
            self:SetAlpha(0)
        end
        -- Force maximize BEFORE layout pass.  Blizzard saves maximized/minimized
        -- state per-character; characters whose map was previously windowed will
        -- open in minimized mode, causing the scroll container to use wrong insets.
        -- Maximizing here ensures IsMaximized() returns true when ApplyLayout runs.
        if not Util.IsInLockdown() and type(self.Maximize) == "function" then
            if not self.IsMaximized or not self:IsMaximized() then
                pcall(self.Maximize, self)
            end
        end
        Runtime.sessionId = Runtime.sessionId + 1
        -- Invalidate any stale settle timers from the previous map close so
        -- they do not fight with the fresh OnShow layout pass.
        Runtime.mapCloseCenterSettleToken = (Runtime.mapCloseCenterSettleToken or 0) + 1
        ApplyLayout("OnShow")
        UI.QueueQuestPanelAnchorSettle(self, "WorldMap:OnShow")
        -- Queue zoom-responsive container resize at staggered intervals so it
        -- fires once the canvas scale is available after Blizzard finishes
        -- initializing the scroll container.  The immediate C_Timer.After(0)
        -- from ApplyLayout may run before GetCanvasScale returns a valid value,
        -- and PostLayoutSync can override it in the same frame.
        if UI.AdjustContainerForZoom and C_Timer and type(C_Timer.After) == "function" then
            C_Timer.After(0.05, UI.AdjustContainerForZoom)
            C_Timer.After(0.20, UI.AdjustContainerForZoom)
            C_Timer.After(0.50, UI.AdjustContainerForZoom)
        end

    end)

    map:HookScript("OnHide", function(self)
        UI.SetMapVisibilityHold(true, "WorldMap:OnHide", "OnHide:hold_closed")
        -- Keep hidden map at alpha 0 so next open starts from a fully hidden state.
        self:SetAlpha(0)
        UI.QueueHiddenMapCenterSettle(self, self:GetParent() or UIParent, "WorldMap:OnHide")

        -- Clean up new quest log panel module state on map close
        if Addon.QuestLogPanel and type(Addon.QuestLogPanel.Hide) == "function" then
            if Addon.QuestLogPanel.IsOpen and Addon.QuestLogPanel.IsOpen() then
                Addon.QuestLogPanel.Hide()
            end
            Runtime.questLogPanelOpen = false
            UI.RefreshQuestLogButtonState()
        end

        local panel = self._muiQuestLogPanel
        if not panel then return end
        if panel._muiSlideIn and type(panel._muiSlideIn.IsPlaying) == "function" and panel._muiSlideIn:IsPlaying() then
            panel._muiSlideIn:Stop()
        end
        if panel._muiSlideOut and type(panel._muiSlideOut.IsPlaying) == "function" and panel._muiSlideOut:IsPlaying() then
            panel._muiSlideOut:Stop()
        end
        panel._muiQuestPanelAnimating = false
        Runtime.questLogPanelOpen = false
        panel._muiQuestPanelDesiredOpen = false
        UI.ClearQuestPanelDetailsState(panel, "WorldMap:OnHide")

        -- Reset Blizzard quest frame mode to Quests on close so MapLegend/Event
        -- mode does not leak spacer/anchor state into the next map open.
        local questFrame = panel._muiQuestOverlayFrame
        if questFrame then
            local questsModeValue = UI.GetQuestDisplayModeValue("Quests")
            if questsModeValue ~= nil and type(questFrame.SetDisplayMode) == "function" then
                pcall(questFrame.SetDisplayMode, questFrame, questsModeValue)
            end
            if type(Addon.MapEnsureQuestModeFrameVisibility) == "function" then
                Addon.MapEnsureQuestModeFrameVisibility(questFrame, "Quests", panel)
            end
        end

        UI.SetQuestPanelAnchors(panel, self, UI.GetQuestPanelHiddenOffset())
        panel:Hide()
        if panel._muiQuestOverlayFrame and type(panel._muiQuestOverlayFrame.Hide) == "function" then
            panel._muiQuestOverlayFrame:Hide()
        end
        UI.RefreshQuestLogButtonState()
    end)

    map:HookScript("OnSizeChanged", function()
        if Runtime.zoomResizeInProgress then return end
        ApplyLayout("OnSizeChanged")
    end)

    hooksecurefunc(map, "RefreshOverlayFrames", function() ApplyLayout("RefreshOverlayFrames") end)

    if type(map.UpdateSpacerFrameAnchoring) == "function" then
        hooksecurefunc(map, "UpdateSpacerFrameAnchoring", function() ApplyLayout("UpdateSpacerFrameAnchoring") end)
    end

    if type(_G.QuestLogQuests_Update) == "function" then
        hooksecurefunc("QuestLogQuests_Update", function()
            local worldMap = _G.WorldMapFrame
            local panel = worldMap and worldMap._muiQuestLogPanel or nil
            local questFrame = panel and panel._muiQuestOverlayFrame or nil
            local activeMode = UI.ResolveQuestDisplayModeKey(questFrame, panel)
            if panel and Runtime.questLogPanelOpen and activeMode == "Quests" then
                RebuildQuestListLayout()
            end
        end)
    end

    -- Core Hook to smooth out size-difference structural snaps during transitions 
    if map.RegisterCallback then
        map:RegisterCallback("WorldMapOnMapChanged", function()
            UI.SmoothFadeCanvas()
            ApplyLayout("WorldMapOnMapChanged")
        end)
    elseif type(map.SetMapID) == "function" then
        hooksecurefunc(map, "SetMapID", function()
            UI.SmoothFadeCanvas()
            ApplyLayout("SetMapID")
        end)
    end

    if type(map.Maximize) == "function" then
        hooksecurefunc(map, "Maximize", function()
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, function()
                    ApplyLayout("Maximize")
                end)
            else
                ApplyLayout("Maximize")
            end
        end)
    end

    if type(map.Minimize) == "function" then
        hooksecurefunc(map, "Minimize", function()
            -- MidnightUI requires maximized mode; re-maximize immediately.
            if C_Timer and type(C_Timer.After) == "function" then
                C_Timer.After(0, function()
                    if type(map.Maximize) == "function" and (not map.IsMaximized or not map:IsMaximized()) then
                        pcall(map.Maximize, map)
                    end
                    ApplyLayout("Minimize:re-maximize")
                end)
            else
                if type(map.Maximize) == "function" then
                    pcall(map.Maximize, map)
                end
                ApplyLayout("Minimize:re-maximize")
            end
        end)
    end

    Runtime.hooksInstalled = true
end

function UI.TryInitialize()
    if not Util.IsCustomQuestingInterfaceEnabled() then
        Runtime.pendingLayout = false
        Runtime.pendingQuestLogToggle = false
        return
    end

    if not _G.WorldMapFrame then
        if type(UIParentLoadAddOn) == "function" then pcall(UIParentLoadAddOn, "Blizzard_WorldMap") end
    end
    if not _G.WorldMapFrame then return end

    UI.InstallQuestLogToggleCompat()
    UI.InstallHooks()

    -- Force the map to maximized mode.  WoW saves maximized/minimized state
    -- per-character; if a character previously used the windowed map, the
    -- MidnightUI layout won't fill the screen correctly.
    local map = _G.WorldMapFrame
    if map and type(map.Maximize) == "function" then
        if not map.IsMaximized or not map:IsMaximized() then
            pcall(map.Maximize, map)
        end
    end

    ApplyLayout("Initialize")
    Runtime.initialized = true
end

function UI.ApplyQuestingInterfaceMode(reason)
    if Util.IsCustomQuestingInterfaceEnabled() then
        UI.TryInitialize()
        if Runtime.initialized and type(ApplyLayout) == "function" then
            ApplyLayout(reason or "ApplyQuestingInterfaceMode:enabled")
        end
    else
        Runtime.pendingLayout = false
        Runtime.pendingQuestLogToggle = false
    end
end
_G.MidnightUI_ApplyQuestingInterfaceMode = UI.ApplyQuestingInterfaceMode

local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("PLAYER_LOGIN")
EventFrame:RegisterEvent("ADDON_LOADED")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:SetScript("OnEvent", function(_, event, loadedAddon)
    if event == "PLAYER_LOGIN" then UI.TryInitialize()
    elseif event == "ADDON_LOADED" and loadedAddon == "Blizzard_WorldMap" then UI.TryInitialize()
    elseif event == "PLAYER_REGEN_ENABLED" then
        if not Util.IsCustomQuestingInterfaceEnabled() then
            Runtime.pendingLayout = false
            Runtime.pendingQuestLogToggle = false
            Runtime.pendingMapCloseCenterSettle = false
            Runtime.pendingMapCloseCenterReason = nil
            return
        end
        if Runtime.pendingMapCloseCenterSettle then
            Runtime.pendingMapCloseCenterSettle = false
            local map = _G.WorldMapFrame
            if map then
                UI.QueueHiddenMapCenterSettle(map, map:GetParent() or UIParent, "PLAYER_REGEN_ENABLED:" .. Util.SafeToString(Runtime.pendingMapCloseCenterReason))
            end
            Runtime.pendingMapCloseCenterReason = nil
        end
        if Runtime.pendingLayout then
            ApplyLayout("PLAYER_REGEN_ENABLED")
        end
        if Runtime.pendingQuestLogToggle then
            UI.RequestQuestLogOverlay()
        end
    end
end)



