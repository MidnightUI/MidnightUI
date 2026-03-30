-- =============================================================================
-- FILE PURPOSE:     Full nameplate replacement. Hides Blizzard default nameplates
--                   and builds custom health bars, cast bars, and threat indicators
--                   for every visible enemy/NPC unit frame.
-- LOAD ORDER:       Loads after Core.lua and Settings.lua. Reads MidnightUISettings.
--                   Nameplates on first event, not at file execution time.
-- DEFINES:          NameplateManager (event frame), local plates[] (nameplate entries),
--                   local threatCache[], groupThreatCache[]
-- READS:            MidnightUISettings.Nameplates.{enabled, scale, healthBar, threatBar,
--                   castBar, target.*} — every visual attribute is settings-driven.
-- WRITES:           plates[unitToken] — one entry per active nameplate, holds all frame refs.
--                   threatCache[], groupThreatCache[] — TTL-bounded threat state caches.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (optional, falls back to RAID_CLASS_COLORS).
--                   MidnightUISettings.Nameplates (read after ADDON_LOADED).
-- USED BY:          Nothing — self-contained. Settings_UI.lua exposes settings controls.
-- KEY FLOWS:
--   NAME_PLATE_UNIT_ADDED   → BuildNameplate(unitToken) — creates all sub-frames
--   NAME_PLATE_UNIT_REMOVED → hides/pools entry
--   OnUpdate (per plate)    → UpdateNameplate: health, health %, threat, target glow
--   UNIT_SPELLCAST_*        → UpdateCastBar: fills/animates cast bar for the unit
--   PLAYER_TARGET_CHANGED   → marks isTarget on every plate, triggers target glow
-- GOTCHAS:
--   Hot-path (OnUpdate per nameplate) uses file-scope pcall helpers to avoid
--   closure allocation per tick. Never call error-throwing APIs in the tick path.
--   Target glow (UpdateTargetGlow) is forward-declared; defined later in the file.
--   IsNameplatesEnabled() short-circuits everything when the feature is toggled off.
-- NAVIGATION:
--   config{}          — all default dimensions/sizes (line ~19)
--   plates{}          — active nameplate state map (line ~245)
--   BuildNameplate()  — frame construction for a new unit (search "function BuildNameplate")
--   UpdateNameplate() — per-frame health+threat tick (search "function UpdateNameplate")
--   UpdateCastBar()   — cast bar fill/animation (search "function UpdateCastBar")
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local NameplateManager = CreateFrame("Frame")

-- Localized globals for hot-path performance (nameplate updates run frequently)
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitThreatSituation = UnitThreatSituation
local UnitExists = UnitExists
local UnitIsUnit = UnitIsUnit
local GetTime = GetTime
local pairs = pairs
local type = type
local string_match = string.match

local config = {
    width = 200,
    height = 20,
    threatHeight = 5,
    spacing = 3,
    namePadding = 6,
    nameFontSize = 10,
    healthPctFontSize = 9,
    nameAlign = "LEFT",
    healthPctDisplay = "RIGHT",
    borderAlpha = 0.7,
    castWidth = 200,
    castHeight = 16,
    castAlpha = 1.0,
    castFontSize = 12,
    castIconPadding = 4,
    updateInterval = 0.2,
}

local PARTY_THREAT_MARKER_SIZE = 14
local PARTY_THREAT_MARKER_Y_OFFSET = 2
local PARTY_THREAT_MARKER_TEXTURE = "Interface\\Buttons\\Arrow-Up"
local PARTY_THREAT_MARKER_ATLAS = "ui-frame-genericplayerchoice-portrait-qualitywhite-01"
local PARTY_THREAT_MARKER_ROTATION = math.rad(-90)
local PARTY_THREAT_TANK_ATLAS = "brewfest-shield_4"
local PARTY_THREAT_TANK_ROTATION = 0
local PARTY_THREAT_MARKER_SAT_BOOST = 1.0
local PARTY_THREAT_MARKER_BRIGHT_BOOST = 1.0

local function IsNameplatesEnabled()
    local s = MidnightUISettings and MidnightUISettings.Nameplates
    if s and s.enabled == false then return false end
    return true
end

local CAST_COLORS = {
    NORMAL = {1.0, 0.8, 0.0},
    CHANNEL = {0.0, 1.0, 0.0},
    UNINTERRUPTIBLE = {0.55, 0.55, 0.55},
    FAILED = {1.0, 0.0, 0.0},
}

-- File-scope pcall helpers (avoids closure allocation per nameplate tick)
local function _SafeEquals(a, b) return a == b end
local function _TestEqualsTrue(value) return value == true end
local function _TestUnitIsUnit(a, b)
    if UnitIsUnit(a, b) then return true end
    return false
end
local function _SetBorderColorInner(border, r, g, b, a)
    if border.top then border.top:SetColorTexture(r, g, b, a) end
    if border.bottom then border.bottom:SetColorTexture(r, g, b, a) end
    if border.left then border.left:SetColorTexture(r, g, b, a) end
    if border.right then border.right:SetColorTexture(r, g, b, a) end
end
local function _SetBorderThicknessInner(border, t)
    if border.top then border.top:SetHeight(t) end
    if border.bottom then border.bottom:SetHeight(t) end
    if border.left then border.left:SetWidth(t) end
    if border.right then border.right:SetWidth(t) end
end
local function _CalcClampedPercent(threatPct)
    return Clamp01((threatPct or 0) / 100)
end
local function _CalcHealthPct(curVal, maxVal)
    return (curVal / maxVal) * 100
end
local function _UpdateHealthBar(bar, max, current)
    bar:SetMinMaxValues(0, max)
    bar:SetValue(current)
end
local function _SetFormattedPct(fontString, pct)
    fontString:SetFormattedText("%.0f%%", pct)
end
local function _GetFromCache(cache, key)
    return cache[key]
end

local function IsTargetUnit(unit)
    if not unit or not UnitExists("target") then return false end
    local okIsUnit, isUnit = pcall(UnitIsUnit, unit, "target")
    if okIsUnit and isUnit then return true end
    local guid = UnitGUID(unit)
    local targetGuid = UnitGUID("target")
    if guid and targetGuid then
        local okGuid, match = pcall(_SafeEquals, guid, targetGuid)
        if okGuid and match then return true end
    end
    return false
end

local function GetNameplateHealthConfig(isTarget)
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    local health = settings and settings.healthBar
    local target = settings and settings.target and settings.target.healthBar
    local width = (health and health.width) or config.width
    local height = (health and health.height) or config.height
    local alpha = (health and health.alpha) or 1.0
    local nonTargetAlpha = (health and health.nonTargetAlpha) or alpha
    local nameFontSize = (health and health.nameFontSize) or config.nameFontSize
    local healthPctFontSize = (health and health.healthPctFontSize) or config.healthPctFontSize
    local nameAlign = (health and health.nameAlign) or config.nameAlign
    local healthPctDisplay = (health and health.healthPctDisplay) or config.healthPctDisplay
    if isTarget and target then
        width = target.width or width
        height = target.height or height
        nameFontSize = target.nameFontSize or nameFontSize
        healthPctFontSize = target.healthPctFontSize or healthPctFontSize
    else
        alpha = nonTargetAlpha
    end
    return width, height, alpha, nameFontSize, healthPctFontSize, nameAlign, healthPctDisplay
end

local function GetNameplateScale(isTarget)
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    local scale = settings and settings.scale
    local targetScale = settings and settings.target and settings.target.scale
    if isTarget and type(targetScale) == "number" then
        scale = targetScale
    end
    if type(scale) ~= "number" then return 1.0 end
    if scale > 5 then
        return math.max(0.5, math.min(scale / 100, 2.0))
    end
    return math.max(0.5, math.min(scale, 2.0))
end

local function ApplyNameplateTextLayout(entry, isTargetUnit)
    if not entry or not entry.healthBar then return end
    local _, _, _, _, _, nameAlign, pctDisplay = GetNameplateHealthConfig(isTargetUnit)
    local nameContainer = entry.nameContainer
    local nameText = entry.name
    local healthPct = entry.healthPct

    local leftPad = config.namePadding
    local rightPad = config.namePadding
    local pctGap = 4

    if healthPct then
        healthPct:ClearAllPoints()
        if pctDisplay == "HIDE" then
            healthPct:Hide()
        elseif pctDisplay == "LEFT" then
            healthPct:Show()
            healthPct:SetPoint("LEFT", entry.healthBar, "LEFT", leftPad, 0)
        else
            healthPct:Show()
            healthPct:SetPoint("RIGHT", entry.healthBar, "RIGHT", -rightPad, 0)
        end
    end

    if nameContainer then
        nameContainer:ClearAllPoints()
        if pctDisplay == "LEFT" and healthPct and healthPct:IsShown() then
            nameContainer:SetPoint("TOPLEFT", entry.healthBar, "TOPLEFT", leftPad, -1)
            nameContainer:SetPoint("BOTTOMLEFT", entry.healthBar, "BOTTOMLEFT", leftPad, 1)
            nameContainer:SetPoint("LEFT", healthPct, "RIGHT", pctGap, 0)
            nameContainer:SetPoint("RIGHT", entry.healthBar, "RIGHT", -rightPad, 0)
        elseif pctDisplay == "RIGHT" and healthPct and healthPct:IsShown() then
            nameContainer:SetPoint("TOPLEFT", entry.healthBar, "TOPLEFT", leftPad, -1)
            nameContainer:SetPoint("BOTTOMLEFT", entry.healthBar, "BOTTOMLEFT", leftPad, 1)
            nameContainer:SetPoint("RIGHT", healthPct, "LEFT", -pctGap, 0)
        else
            nameContainer:SetPoint("TOPLEFT", entry.healthBar, "TOPLEFT", leftPad, -1)
            nameContainer:SetPoint("BOTTOMRIGHT", entry.healthBar, "BOTTOMRIGHT", -rightPad, 1)
        end
    end

    if nameText and nameContainer then
        nameText:ClearAllPoints()
        nameText:SetPoint("LEFT", nameContainer, "LEFT", 0, 0)
        nameText:SetPoint("RIGHT", nameContainer, "RIGHT", 0, 0)
        local align = (nameAlign == "CENTER" or nameAlign == "RIGHT") and nameAlign or "LEFT"
        nameText:SetJustifyH(align)
    end
end

local function GetNameplateThreatConfig(isTarget)
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    local threat = settings and settings.threatBar
    local target = settings and settings.target and settings.target.threatBar
    local enabled = true
    if threat and threat.enabled ~= nil then enabled = threat.enabled end
    local width = (threat and threat.width) or config.width
    local height = (threat and threat.height) or config.threatHeight
    local alpha = (threat and threat.alpha) or 1.0
    if isTarget and target then
        width = target.width or width
        height = target.height or height
    end
    return enabled, width, height, alpha
end

local function GetNameplateCastConfig(isTarget)
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    local cast = settings and settings.castBar
    local target = settings and settings.target and settings.target.castBar
    local width = (cast and cast.width) or config.castWidth or config.width
    local height = (cast and cast.height) or config.castHeight or config.height
    local alpha = (cast and cast.alpha) or config.castAlpha or 1.0
    local fontSize = (cast and cast.fontSize) or config.castFontSize or (config.nameFontSize + 2)
    if isTarget and target then
        width = target.width or width
        height = target.height or height
    end
    return width, height, alpha, fontSize
end

local THREAT_HEALTH_COLORS = {
    red = {0.90, 0.10, 0.10},
    yellow = {1.00, 0.90, 0.20},
    green = {0.10, 0.90, 0.20},
    gray = {0.55, 0.55, 0.55},
}

local THREAT_BAR_COLORS = {
    red = {0.90, 0.10, 0.10},
    yellow = {1.00, 0.90, 0.20},
    green = {0.10, 0.90, 0.20},
}

local THREAT_CACHE_TTL = 2.0
local THREAT_NO_DATA_DELAY = 0.3
local GROUP_THREAT_CACHE_TTL = 0.3

local plates = {}
local threatCache = {}
local groupThreatCache = {}
local UpdateTargetGlow

local function HideAllPlates()
    for _, entry in pairs(plates) do
        if entry then
            UpdateTargetGlow(entry, false)
            if entry.root then entry.root:Hide() end
            if entry.castBar then entry.castBar:Hide() end
            if entry.threatBar then entry.threatBar:Hide() end
            if entry.threatContainer then entry.threatContainer:Hide() end
            if entry.threatBar2 then entry.threatBar2:Hide() end
            if entry.threatContainer2 then entry.threatContainer2:Hide() end
            if entry.partyThreatMarkerContainer then entry.partyThreatMarkerContainer:Hide() end
        end
    end
end

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then
            fs:SetFont(fallback, size or 12, flags)
        end
    end
    return ok
end

local function ApplyNameplateFont(fs, fontPath, size, flags, label)
    SetFontSafe(fs, fontPath, size, flags)
end

local function GetUnitClassColor(unit)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
        return _G.MidnightUI_Core.GetClassColor(unit)
    end
    local _, class = UnitClass(unit)
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r, c.g, c.b
    end
    return 0.9, 0.9, 0.9
end

local function CreateBlackBorder(parent, alpha)
    local a = alpha or 1
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(1); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT"); border.top:SetColorTexture(0, 0, 0, a)
    border.bottom = border:CreateTexture(nil, "OVERLAY"); border.bottom:SetHeight(1); border.bottom:SetPoint("BOTTOMLEFT"); border.bottom:SetPoint("BOTTOMRIGHT"); border.bottom:SetColorTexture(0, 0, 0, a)
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(1); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT"); border.left:SetColorTexture(0, 0, 0, a)
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(1); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT"); border.right:SetColorTexture(0, 0, 0, a)
    border.innerHighlight = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerHighlight:SetHeight(3)
    border.innerHighlight:SetPoint("TOPLEFT", border.top, "BOTTOMLEFT", 1, 0)
    border.innerHighlight:SetPoint("TOPRIGHT", border.top, "BOTTOMRIGHT", -1, 0)
    border.innerHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerHighlight:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0),
        CreateColor(1, 1, 1, 0.07))
    border.innerShadow = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerShadow:SetHeight(3)
    border.innerShadow:SetPoint("BOTTOMLEFT", border.bottom, "TOPLEFT", 1, 0)
    border.innerShadow:SetPoint("BOTTOMRIGHT", border.bottom, "TOPRIGHT", -1, 0)
    border.innerShadow:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerShadow:SetGradient("VERTICAL",
        CreateColor(0, 0, 0, 0.25),
        CreateColor(0, 0, 0, 0))
    return border
end

local function EnsureCornerCut(frame, size, r, g, b, a)
    if not frame then return end
    local cut = math.max(1, math.floor(size or 2))
    local corners = frame._muiCornerCut
    if not corners then
        corners = {}
        corners.tl = frame:CreateTexture(nil, "OVERLAY")
        corners.tr = frame:CreateTexture(nil, "OVERLAY")
        corners.bl = frame:CreateTexture(nil, "OVERLAY")
        corners.br = frame:CreateTexture(nil, "OVERLAY")
        corners.tl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        corners.tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        corners.bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        corners.br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame._muiCornerCut = corners
    end
    corners.tl:SetSize(cut, cut)
    corners.tr:SetSize(cut, cut)
    corners.bl:SetSize(cut, cut)
    corners.br:SetSize(cut, cut)
    corners.tl:SetColorTexture(r, g, b, a)
    corners.tr:SetColorTexture(r, g, b, a)
    corners.bl:SetColorTexture(r, g, b, a)
    corners.br:SetColorTexture(r, g, b, a)
end

local function SetBorderColor(border, r, g, b, a)
    if not border then return end
    local ok = pcall(_SetBorderColorInner, border, r, g, b, a)
    if not ok then return end
end

local function SetBorderThickness(border, t)
    if not border or not t then return end
    local ok = pcall(_SetBorderThicknessInner, border, t)
    if not ok then return end
end

local FACTION_BORDER_COLORS = {
    Alliance = { 0.20, 0.45, 1.00, 1.0 },
    Horde = { 0.95, 0.15, 0.15, 1.0 },
}

local function GetFactionToken(unit)
    if not unit then return nil end
    local okFaction, factionA, factionB = pcall(UnitFactionGroup, unit)
    if okFaction then
        if FACTION_BORDER_COLORS[factionA] then return factionA end
        if FACTION_BORDER_COLORS[factionB] then return factionB end
    end

    local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
    if not okPlayer or not isPlayer then return nil end

    local okPlayerFaction, playerFactionA, playerFactionB = pcall(UnitFactionGroup, "player")
    if not okPlayerFaction then return nil end
    local playerFaction = FACTION_BORDER_COLORS[playerFactionA] and playerFactionA or playerFactionB
    if not FACTION_BORDER_COLORS[playerFaction] then return nil end

    local okFriend, isFriend = pcall(UnitIsFriend, "player", unit)
    if okFriend and isFriend then
        return playerFaction
    end
    if playerFaction == "Horde" then return "Alliance" end
    if playerFaction == "Alliance" then return "Horde" end
    return nil
end

local function GetPlayerFactionBorderColor(unit)
    if not unit then return nil end
    local okPlayer, isPlayer = pcall(UnitIsPlayer, unit)
    if not okPlayer or not isPlayer then return nil end
    local faction = GetFactionToken(unit)
    if not faction then return nil end
    return FACTION_BORDER_COLORS[faction]
end

local function ApplyHealthBorderStyle(entry, unit)
    if not entry or not entry.healthBorder then return end
    local showFactionBorder = true
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    if settings and settings.showFactionBorder == false then
        showFactionBorder = false
    end
    local factionColor = showFactionBorder and GetPlayerFactionBorderColor(unit) or nil
    if factionColor then
        SetBorderColor(entry.healthBorder, factionColor[1], factionColor[2], factionColor[3], factionColor[4])
    else
        SetBorderColor(entry.healthBorder, 0, 0, 0, config.borderAlpha)
    end
    SetBorderThickness(entry.healthBorder, 1)
end

local function UpdateTargetGlowPulse(pulseGlow, elapsed)
    if not pulseGlow or not pulseGlow._muiAnchor then return end
    local duration = 1.65
    local maxExpand = 8
    local t = (pulseGlow._muiPulseT or 0) + (elapsed or 0)
    if t > duration then
        t = t - duration
    end
    pulseGlow._muiPulseT = t
    local p = t / duration
    local expand = maxExpand * p
    pulseGlow:ClearAllPoints()
    pulseGlow:SetPoint("TOPLEFT", pulseGlow._muiAnchor, "TOPLEFT", -expand, expand)
    pulseGlow:SetPoint("BOTTOMRIGHT", pulseGlow._muiAnchor, "BOTTOMRIGHT", expand, -expand)
    pulseGlow:SetAlpha(0.62 * (1 - p))
end

UpdateTargetGlow = function(entry, isTargetUnit)
    if not entry then return end
    local baseGlow = entry.targetGlowBase
    local pulseGlow = entry.targetGlowPulse
    local settings = MidnightUISettings and MidnightUISettings.Nameplates
    local targetBorderEnabled = not (settings and settings.targetBorder == false)
    local targetPulseEnabled = not (settings and settings.targetPulse == false)
    if not baseGlow and not pulseGlow then return end
    if isTargetUnit then
        if baseGlow and targetBorderEnabled then
            baseGlow:SetAlpha(1.0)
            baseGlow:Show()
        elseif baseGlow then
            baseGlow:SetAlpha(0)
            baseGlow:Hide()
        end
        if pulseGlow and targetPulseEnabled then
            pulseGlow:Show()
            if not pulseGlow._muiPulseActive then
                pulseGlow._muiPulseActive = true
                pulseGlow._muiPulseT = 0
                pulseGlow:SetScript("OnUpdate", UpdateTargetGlowPulse)
            end
        elseif pulseGlow then
            pulseGlow._muiPulseActive = false
            pulseGlow:SetScript("OnUpdate", nil)
            pulseGlow._muiPulseT = 0
            pulseGlow:SetAlpha(0)
            if pulseGlow._muiAnchor then
                pulseGlow:ClearAllPoints()
                pulseGlow:SetPoint("TOPLEFT", pulseGlow._muiAnchor, "TOPLEFT", 0, 0)
                pulseGlow:SetPoint("BOTTOMRIGHT", pulseGlow._muiAnchor, "BOTTOMRIGHT", 0, 0)
            end
            pulseGlow:Hide()
        end
    else
        if pulseGlow then
            pulseGlow._muiPulseActive = false
            pulseGlow:SetScript("OnUpdate", nil)
            pulseGlow._muiPulseT = 0
            pulseGlow:SetAlpha(0)
            if pulseGlow._muiAnchor then
                pulseGlow:ClearAllPoints()
                pulseGlow:SetPoint("TOPLEFT", pulseGlow._muiAnchor, "TOPLEFT", 0, 0)
                pulseGlow:SetPoint("BOTTOMRIGHT", pulseGlow._muiAnchor, "BOTTOMRIGHT", 0, 0)
            end
            pulseGlow:Hide()
        end
        if baseGlow then
            baseGlow:SetAlpha(0)
            baseGlow:Hide()
        end
    end
end

local function Clamp01(value)
    if not value then return 0 end
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

-- =========================================================================
--  DISPEL DETECTION (Nameplates)
-- =========================================================================
local ENEMY_PLAYER_NAMEPLATE_CVARS = {
    "nameplateShowEnemies",
    "nameplateShowEnemyPlayers",
    "nameplateShowFriends",
    "nameplateShowFriendlyPlayers",
}

local function UpdateNameplateDispelIndicator(entry, unit)
    if not entry or not entry.dispelIndicator then return end
    -- Dispel detection disabled (Blizzard secret values).
    entry.dispelIndicator:Hide()
    if entry.dispelIndicator.glowAnim then entry.dispelIndicator.glowAnim:Stop() end
    entry.dispelIndicator._muiReasonKey = "disabled"
    entry.dispelIndicator._muiLastKey = nil
end


local function GetCVarBoolSafe(name)
    local ok, value = pcall(GetCVarBool, name)
    if ok and value ~= nil then return value end
    local v = GetCVar(name)
    if v == "1" then return true end
    if v == "0" then return false end
    return nil
end

local function EnsureEnemyPlayerNameplatesEnabled()
    if not SetCVar then return end
    for _, cvar in ipairs(ENEMY_PLAYER_NAMEPLATE_CVARS) do
        local current = GetCVarBoolSafe(cvar)
        if current ~= true then
            pcall(SetCVar, cvar, "1")
        end
    end
end

local function ShouldShowFriendlyNameplate(unit)
    if not UnitIsFriend("player", unit) then return true end

    local showFriends = GetCVarBoolSafe("nameplateShowFriends")
    if UnitIsPlayer(unit) then
        if showFriends == nil then return true end
        return showFriends
    end

    local showNPCs = GetCVarBoolSafe("nameplateShowFriendlyNPCs")
    local showPets = GetCVarBoolSafe("nameplateShowFriendlyPets")
    local showGuardians = GetCVarBoolSafe("nameplateShowFriendlyGuardians")
    local showMinions = GetCVarBoolSafe("nameplateShowFriendlyMinions")
    local showTotems = GetCVarBoolSafe("nameplateShowFriendlyTotems")

    local anyDefined = (showNPCs ~= nil) or (showPets ~= nil) or (showGuardians ~= nil)
        or (showMinions ~= nil) or (showTotems ~= nil)
    if anyDefined then
        return (showNPCs or showPets or showGuardians or showMinions or showTotems) and true or false
    end
    if showFriends ~= nil then return showFriends end
    return true
end

local function ShouldShowNameplate(unit)
    local showAll = GetCVarBoolSafe("nameplateShowAll")
    if showAll == false then return false end

    if UnitIsFriend("player", unit) then
        return ShouldShowFriendlyNameplate(unit)
    end

    local showEnemies = GetCVarBoolSafe("nameplateShowEnemies")
    if showEnemies == false then return false end
    return true
end

local function SafeGetSpellName(spellId)
    if spellId == nil then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellId)
        return info and info.name or nil
    end
    if GetSpellInfo then
        local ok, name = pcall(GetSpellInfo, spellId)
        if ok then return name end
    end
    return nil
end

local function IsSecretValue(val)
    if type(issecretvalue) ~= "function" then return false end
    local ok, res = pcall(issecretvalue, val)
    return ok and res == true
end

local function SanitizeCacheKey(value)
    if value == nil or IsSecretValue(value) then return nil end
    return value
end

local function GetSafeUnitGuid(unit)
    return SanitizeCacheKey(UnitGUID(unit))
end

local function NormalizeThreatStatus(value)
    if value == nil or IsSecretValue(value) then return nil end
    local n = tonumber(value)
    if not n then return nil end
    return n
end

local function IsStrictTrue(value)
    if IsSecretValue(value) then
        return false
    end
    local ok, result = pcall(_TestEqualsTrue, value)
    return ok and result == true
end

local function ColorGradient(perc, r1, g1, b1, r2, g2, b2, r3, g3, b3)
    if perc <= 0 then return r1, g1, b1 end
    if perc >= 1 then return r3, g3, b3 end
    if perc < 0.5 then
        local rel = perc * 2
        return r1 + (r2 - r1) * rel, g1 + (g2 - g1) * rel, b1 + (b2 - b1) * rel
    end
    local rel = (perc - 0.5) * 2
    return r2 + (r3 - r2) * rel, g2 + (g3 - g2) * rel, b2 + (b3 - b2) * rel
end

local function SafePercent(threatPct)
    local ok, result = pcall(_CalcClampedPercent, threatPct)
    if not ok or not result then return 0 end
    return result
end

local function NormalizeThreatPercent(scaledPct, rawPct, isTanking, status, fallbackStatus)
    local threatPct = NormalizeThreatStatus(scaledPct)
    local threatStatus = NormalizeThreatStatus(status)
    local tankingState = IsStrictTrue(isTanking)
    if threatStatus == nil then
        threatStatus = NormalizeThreatStatus(fallbackStatus)
    end
    local rawThreatPct = NormalizeThreatStatus(rawPct)
    if threatPct == nil and rawThreatPct ~= nil then
        if rawThreatPct > 100 then
            threatPct = (rawThreatPct / 255) * 100
        else
            threatPct = rawThreatPct
        end
    end
    if threatPct == nil then
        if tankingState then
            threatPct = 100
        elseif threatStatus then
            threatPct = threatStatus * 33
        else
            threatPct = 0
        end
    end
    if threatPct <= 1 then threatPct = threatPct * 100 end
    if threatPct > 100 then threatPct = 100 end
    return threatPct
end

local function IsUnitTargetingPlayer(unit)
    if not unit then return false end
    local unitTarget = unit .. "target"
    
    -- Safe check for UnitExists
    local okExists, exists = pcall(UnitExists, unitTarget)
    if not okExists or not exists then return false end

    -- Safe check for UnitIsUnit (Fixes "boolean test on secret value")
    local okTarget, isTargeting = pcall(_TestUnitIsUnit, unitTarget, "player")

    -- If the check crashed (was secret) or simply wasn't true, we return false
    if not okTarget then return false end

    return isTargeting
end

local function IsTargetTargetingPlayer()
    if UnitExists("targettarget") and UnitIsUnit("targettarget", "player") then
        return true
    end
    return false
end

local function GetThreatDataForUnit(unit)
    local isTanking, status, scaledPct, rawPct = UnitDetailedThreatSituation("player", unit)
    local simpleStatus = UnitThreatSituation("player", unit)

    -- Safe Check for Target Interaction
    if UnitExists("target") then
        local isTargetUnit = false
        
        -- Safe UnitIsUnit Check
        local okIsUnit, isUnitResult = pcall(UnitIsUnit, unit, "target")
        if okIsUnit and isUnitResult then
            isTargetUnit = true
        else
            -- Safe GUID Comparison Check
            local guid = UnitGUID(unit)
            local targetGuid = UnitGUID("target")
            if guid and targetGuid then
                local okGuid, guidMatch = pcall(_SafeEquals, guid, targetGuid)
                if okGuid and guidMatch then
                    isTargetUnit = true
                end
            end
        end

        if isTargetUnit then
            local tIsTanking, tStatus, tScaledPct, tRawPct = UnitDetailedThreatSituation("player", "target")
            local tSimpleStatus = UnitThreatSituation("player", "target")
            
            -- If we have no direct threat data, use target data as fallback
            if (isTanking == nil and status == nil and scaledPct == nil and rawPct == nil and simpleStatus == nil) then
                isTanking, status, scaledPct, rawPct, simpleStatus = tIsTanking, tStatus, tScaledPct, tRawPct, tSimpleStatus
            -- If target data exists, prioritize it (it's often more accurate for the active target)
            elseif (tIsTanking ~= nil or tStatus ~= nil or tScaledPct ~= nil or tRawPct ~= nil or tSimpleStatus ~= nil) then
                isTanking = tIsTanking
                status = tStatus
                scaledPct = tScaledPct
                rawPct = tRawPct
                simpleStatus = tSimpleStatus
            end
        end
    end

    return isTanking, status, scaledPct, rawPct, simpleStatus, unit
end

local function HideElement(element)
    if not element then return end
    if element.SetAlpha then element:SetAlpha(0) end
    if element.Hide then element:Hide() end
    if element.SetShown then element:SetShown(false) end
end

local function SuppressDefault(unitFrame)
    if not unitFrame then return end
    if unitFrame._muiSuppressed then return end
    unitFrame._muiSuppressed = true
    if unitFrame.SetAlpha then unitFrame:SetAlpha(0) end
    local hasCastBar = unitFrame.castBar or unitFrame.CastBar
    if not hasCastBar and unitFrame.Hide then unitFrame:Hide() end
    local elements = {
        unitFrame.border, unitFrame.Border,
        unitFrame.selectionHighlight, unitFrame.SelectionHighlight,
        unitFrame.threatGlow, unitFrame.ThreatGlow,
        unitFrame.deselectedOverlay, unitFrame.DeselectedOverlay,
        unitFrame.deselectedHighlight, unitFrame.DeselectedHighlight,
        unitFrame.HealthBarsContainer,
        unitFrame.healthBarsContainer, unitFrame.HealthBarsContainer,
        unitFrame.HealthBarsContainerFrame, unitFrame.HealthBarContainer,
        unitFrame.name, unitFrame.Name, unitFrame.nameText,
        unitFrame.healthBar, unitFrame.HealthBar, unitFrame.healthbar,
        unitFrame.healthBarBorder, unitFrame.HealthBarBorder,
    }
    for _, element in ipairs(elements) do
        HideElement(element)
    end
end

-- Hook Blizzard's CompactUnitFrame updaters to re-suppress default nameplate
-- elements after Blizzard refreshes them. Without this, Blizzard continuously
-- re-shows the default nameplate (name, health bar, borders) alongside ours.
do
    local function ReSuppressAfterUpdate(unitFrame)
        if not unitFrame or not unitFrame._muiSuppressed then return end
        -- Re-suppress: Blizzard just re-showed elements we already hid
        if unitFrame.SetAlpha then unitFrame:SetAlpha(0) end
        local elements = {
            unitFrame.border, unitFrame.Border,
            unitFrame.selectionHighlight, unitFrame.SelectionHighlight,
            unitFrame.threatGlow, unitFrame.ThreatGlow,
            unitFrame.deselectedOverlay, unitFrame.DeselectedOverlay,
            unitFrame.deselectedHighlight, unitFrame.DeselectedHighlight,
            unitFrame.HealthBarsContainer,
            unitFrame.healthBarsContainer, unitFrame.HealthBarsContainer,
            unitFrame.HealthBarsContainerFrame, unitFrame.HealthBarContainer,
            unitFrame.name, unitFrame.Name, unitFrame.nameText,
            unitFrame.healthBar, unitFrame.HealthBar, unitFrame.healthbar,
            unitFrame.healthBarBorder, unitFrame.HealthBarBorder,
        }
        for _, element in ipairs(elements) do
            HideElement(element)
        end
    end

    local blizzFuncs = {
        "CompactUnitFrame_UpdateAll",
        "CompactUnitFrame_UpdateName",
        "CompactUnitFrame_UpdateHealthColor",
        "CompactUnitFrame_UpdateHealth",
        "CompactUnitFrame_UpdateHealthBorder",
        "CompactUnitFrame_UpdateSelectionHighlight",
        "CompactUnitFrame_UpdateAggroHighlight",
    }
    for _, funcName in ipairs(blizzFuncs) do
        if type(_G[funcName]) == "function" then
            hooksecurefunc(funcName, function(frame)
                if frame and frame._muiSuppressed then
                    ReSuppressAfterUpdate(frame)
                end
            end)
        end
    end
end

local function StyleNameplateCastBar(entry, unit)
    if not entry or not entry.unitFrame or not entry.root then return end
    local castBar = entry.unitFrame.castBar or entry.unitFrame.CastBar
    if not castBar then return end

    entry.castBar = castBar
    entry.castShield = castBar.Shield or castBar.shield or castBar.BorderShield
    if castBar:GetParent() ~= entry.root then
        castBar:SetParent(entry.root)
        castBar:ClearAllPoints()
    end
    local isTargetUnit = IsTargetUnit(unit or entry.unit)
    local castWidth, castHeight, castAlpha, castFontSize = GetNameplateCastConfig(isTargetUnit)
    castBar:SetPoint("BOTTOM", entry.root, "TOP", 0, config.spacing + 2)
    castBar:SetSize(castWidth, castHeight)
    castBar:SetAlpha(castAlpha)
    if castBar.SetIgnoreParentScale then
        castBar:SetIgnoreParentScale(true)
        castBar:SetScale(1)
    end
    castBar:SetFrameLevel(entry.root:GetFrameLevel() + 6)
    castBar:SetFrameStrata(entry.root:GetFrameStrata() or "MEDIUM")
    castBar:SetClipsChildren(true)
    local nativeText = castBar.Text or castBar.text or castBar.Name or castBar.SpellName or castBar.spellName
    local text = nativeText or castBar._midnightText
    local timer = castBar._midnightTimer or castBar.Timer or castBar.Time or castBar.time
    local textSource = (castBar.Text and "Text")
        or (castBar.text and "text")
        or (castBar.Name and "Name")
        or (castBar.SpellName and "SpellName")
        or (castBar.spellName and "spellName")
        or "none"
    local createdFallbackText = false
    castBar._midnightText = text
    castBar._midnightTimer = timer
    castBar._midnightTextSource = textSource
    if castBar.GetStatusBarTexture then
        local tex = castBar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", castBar, "TOPLEFT", 1, -1)
            tex:SetPoint("BOTTOMRIGHT", castBar, "BOTTOMRIGHT", -1, 1)
        end
    end

    if not castBar.MidnightStyled then
        castBar.MidnightStyled = true

        if not castBar.bg then
            castBar.bg = castBar:CreateTexture(nil, "BACKGROUND")
            castBar.bg:ClearAllPoints()
            castBar.bg:SetPoint("TOPLEFT", castBar, "TOPLEFT", 1, -1)
            castBar.bg:SetPoint("BOTTOMRIGHT", castBar, "BOTTOMRIGHT", -1, 1)
            castBar.bg:SetColorTexture(0.05, 0.05, 0.05, 0.7)
        end
        EnsureCornerCut(castBar, 2, 0.05, 0.05, 0.05, 1)

        if not castBar.border then
            castBar.border = CreateBlackBorder(castBar, config.borderAlpha)
        end

        local icon = castBar.Icon or castBar.icon
        if icon then
            local iconSize = castHeight + 4
            icon:SetSize(iconSize, iconSize)
            icon:ClearAllPoints()
            icon:SetPoint("RIGHT", castBar, "LEFT", -config.castIconPadding, 0)
            icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)

            if not castBar.iconBorder then
                castBar.iconBorder = CreateFrame("Frame", nil, castBar)
                castBar.iconBorder:SetAllPoints(icon)
                castBar.iconBorderBorder = CreateBlackBorder(castBar.iconBorder, config.borderAlpha)
            end
        end

        local spark = castBar.Spark or castBar.spark
        if spark then
            spark:SetAlpha(0)
            spark:Hide()
        end

        local shield = castBar.Shield or castBar.shield
        if shield then shield:Hide() end

        local border = castBar.Border or castBar.borderArt or castBar.BorderShield
        if border and border.SetAlpha then border:SetAlpha(0) end
    end

    -- Keep shield visual from shrinking the bar; still allow detection via IsShown().
    if entry.castShield then
        entry.castShield:ClearAllPoints()
        entry.castShield:SetAllPoints(castBar)
        if entry.castShield.SetAlpha then entry.castShield:SetAlpha(0) end
    end
end

function _G.MidnightUI_ApplyNameplateCastStyleToBar(bar, isTargetUnit)
    if not bar then return end
    local castWidth, castHeight, castAlpha, castFontSize = GetNameplateCastConfig(isTargetUnit)
    bar:SetSize(castWidth, castHeight)
    bar:SetAlpha(castAlpha)
    if bar.SetClipsChildren then bar:SetClipsChildren(true) end
    if bar.GetStatusBarTexture then
        local tex = bar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
            tex:ClearAllPoints()
            tex:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
            tex:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        end
    end

    if not bar.bg then
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:ClearAllPoints()
        bar.bg:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        bar.bg:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        bar.bg:SetColorTexture(0.05, 0.05, 0.05, 0.7)
    end
    EnsureCornerCut(bar, 2, 0.05, 0.05, 0.05, 1)
    if not bar.border then
        bar.border = CreateBlackBorder(bar, config.borderAlpha)
    end

    local icon = bar.Icon or bar.icon
    if icon then
        local iconSize = castHeight + 4
        icon:SetSize(iconSize, iconSize)
        icon:ClearAllPoints()
        icon:SetPoint("RIGHT", bar, "LEFT", -config.castIconPadding, 0)
        icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
            if not bar.iconBorder then
                bar.iconBorder = CreateFrame("Frame", nil, bar)
                bar.iconBorder:SetAllPoints(icon)
                bar.iconBorderBorder = CreateBlackBorder(bar.iconBorder, config.borderAlpha)
            end
    end

    local text = bar.Text or bar.text or bar.Name
    if text then
        text:ClearAllPoints()
        text:SetPoint("CENTER", bar, "CENTER", 0, 0)
        ApplyNameplateFont(text, "Fonts\\FRIZQT__.TTF", castFontSize, "OUTLINE", "CastText")
        text:SetJustifyH("CENTER")
        text:SetTextColor(1, 1, 1, 1)
        text:SetShadowOffset(1, -1)
        text:SetShadowColor(0, 0, 0, 1)
    end

    local timer = bar.Timer or bar.Time or bar.time
    if timer then
        timer:ClearAllPoints()
        timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
        ApplyNameplateFont(timer, "Fonts\\ARIALN.TTF", config.healthPctFontSize + 2, "OUTLINE", "CastTimer")
        timer:SetJustifyH("RIGHT")
        timer:SetTextColor(1, 1, 1, 1)
        timer:SetShadowOffset(1, -1)
        timer:SetShadowColor(0, 0, 0, 1)
    end

    local spark = bar.Spark or bar.spark
    if spark then
        spark:SetAlpha(0)
        spark:Hide()
    end

    local shield = bar.Shield or bar.shield or bar.BorderShield
    if shield then shield:Hide() end

    local border = bar.Border or bar.borderArt or bar.BorderShield
    if border and border.SetAlpha then border:SetAlpha(0) end
end

local function BoostMarkerColor(r, g, b)
    if not r then return 1, 1, 1 end
    return r, g, b
end

local function ApplyMarkerAtlas(tex, atlas, fallbackTexture, rotation)
    if not tex then return end
    if tex.SetAtlas then
        tex:SetAtlas(atlas, true)
    end
    if not tex:GetTexture() then
        tex:SetTexture(fallbackTexture)
    end
    if tex.SetRotation then
        tex:SetRotation(rotation or 0)
    end
end

local function GetPartyMarkerClassColor(unit)
    local _, class = UnitClass(unit)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.ClassColorsExact and class and _G.MidnightUI_Core.ClassColorsExact[class] then
        local c = _G.MidnightUI_Core.ClassColorsExact[class]
        return c.r, c.g, c.b, true
    end
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
        return _G.MidnightUI_Core.GetClassColor(unit), false
    end
    return GetUnitClassColor(unit), false
end

local INTERRUPTIBLE_CAST_BORDER = { 0.18, 0.72, 0.28, 1 }
local DEFAULT_CAST_BORDER = { 0, 0, 0, 1 }
local INTERRUPTED_CAST_BORDER = { 0.92, 0.18, 0.18, 0.78 }
local NAMEPLATE_CAST_SUCCESS_ALPHA = 0.42
local NAMEPLATE_CAST_SUCCESS_DURATION = 0.48
local NAMEPLATE_CAST_SUCCESS_EXPAND = 10
local NAMEPLATE_CAST_INTERRUPT_ALPHA = 0.55
local NAMEPLATE_CAST_INTERRUPT_DURATION = 0.24

local function SetNameplateCastBorderColor(entry, color)
    if not entry or not entry.castBar then return end

    local border = entry.castBar.border
    local borderApplied = false
    if border then
        SetBorderColor(border, color[1], color[2], color[3], color[4])
        borderApplied = true
    end

    local iconBorder = entry.castBar.iconBorderBorder or entry.castBar.iconBorder
    local iconBorderApplied = false
    if iconBorder then
        SetBorderColor(iconBorder, color[1], color[2], color[3], color[4])
        iconBorderApplied = true
    end

end

local function SetNameplateCastBorderState(entry, isInterruptible)
    local color = isInterruptible and INTERRUPTIBLE_CAST_BORDER or DEFAULT_CAST_BORDER
    SetNameplateCastBorderColor(entry, color)
end

local function EnsureNameplateCastGlow(entry, key, r, g, b, alpha)
    if not entry or not entry.castBar or not entry.root then return nil end
    local overlay = entry[key]
    if overlay then return overlay end

    overlay = CreateFrame("Frame", nil, entry.root)
    overlay.tex = overlay:CreateTexture(nil, "ARTWORK")
    overlay.tex:SetAllPoints()
    overlay.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    overlay.tex:SetBlendMode("ADD")
    overlay.tex:SetVertexColor(r, g, b, alpha or 1)
    overlay:SetAlpha(0)
    overlay:Hide()
    overlay._muiAnchor = entry.castBar
    if overlay.SetFrameLevel and entry.castBar and entry.castBar.GetFrameLevel then
        overlay:SetFrameLevel(entry.castBar:GetFrameLevel() + 1)
    end
    entry[key] = overlay
    return overlay
end

local function ClearNameplateCastGlow(entry, key)
    local overlay = entry and entry[key]
    if not overlay then return end
    overlay._muiPulseActive = false
    overlay._muiPulseTicker = 0
    overlay:SetScript("OnUpdate", nil)
    overlay:SetAlpha(0)
    overlay:Hide()
    if overlay._muiAnchor then
        overlay:ClearAllPoints()
        overlay:SetPoint("TOPLEFT", overlay._muiAnchor, "TOPLEFT", -2, 2)
        overlay:SetPoint("BOTTOMRIGHT", overlay._muiAnchor, "BOTTOMRIGHT", 2, -2)
    end
end

local function PlayNameplateCastGlow(entry, key, r, g, b, alpha, duration, expand)
    local overlay = EnsureNameplateCastGlow(entry, key, r, g, b, alpha)
    if not overlay then return end

    overlay.tex:SetVertexColor(r, g, b, 1)
    overlay._muiPulseActive = true
    overlay._muiPulseTicker = 0
    overlay._muiPulseLoggedMid = false
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", overlay._muiAnchor, "TOPLEFT", -2, 2)
    overlay:SetPoint("BOTTOMRIGHT", overlay._muiAnchor, "BOTTOMRIGHT", 2, -2)
    overlay:SetAlpha(alpha)
    overlay:Show()
    overlay:SetScript("OnUpdate", function(self, elapsed)
        if not self._muiPulseActive or not self._muiAnchor then
            self:SetScript("OnUpdate", nil)
            return
        end

        local t = (self._muiPulseTicker or 0) + (elapsed or 0)
        self._muiPulseTicker = t
        local p = t / duration
        if p >= 1 then
            self._muiPulseActive = false
            self._muiPulseTicker = 0
            self:SetAlpha(0)
            self:Hide()
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", self._muiAnchor, "TOPLEFT", -2, 2)
            self:SetPoint("BOTTOMRIGHT", self._muiAnchor, "BOTTOMRIGHT", 2, -2)
            self:SetScript("OnUpdate", nil)
            return
        end

        local easedExpand = 1 - ((1 - p) * (1 - p))
        local easedFade = (1 - p) * (1 - p)
        local currentExpand = expand * easedExpand
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", self._muiAnchor, "TOPLEFT", -2 - currentExpand, 2 + currentExpand)
        self:SetPoint("BOTTOMRIGHT", self._muiAnchor, "BOTTOMRIGHT", 2 + currentExpand, -2 - currentExpand)
        self:SetAlpha(alpha * easedFade)
    end)
end

local function SetNameplateCastInterruptedState(entry, active)
    if not entry or not entry.castBar then return end
    entry.castBar._midnightInterruptedVisualActive = active and true or false

    if active then
        SetNameplateCastBorderColor(entry, INTERRUPTED_CAST_BORDER)
        ClearNameplateCastGlow(entry, "castSuccessGlow")
        PlayNameplateCastGlow(
            entry,
            "castInterruptGlow",
            INTERRUPTED_CAST_BORDER[1],
            INTERRUPTED_CAST_BORDER[2],
            INTERRUPTED_CAST_BORDER[3],
            NAMEPLATE_CAST_INTERRUPT_ALPHA,
            NAMEPLATE_CAST_INTERRUPT_DURATION,
            6
        )
        return
    end

    ClearNameplateCastGlow(entry, "castInterruptGlow")
end

local function PlayNameplateCastSuccessPulse(entry)
    if not entry or not entry.castBar then return end
    entry.castBar._midnightInterruptedVisualActive = false
    ClearNameplateCastGlow(entry, "castInterruptGlow")
    PlayNameplateCastGlow(
        entry,
        "castSuccessGlow",
        INTERRUPTIBLE_CAST_BORDER[1],
        INTERRUPTIBLE_CAST_BORDER[2],
        INTERRUPTIBLE_CAST_BORDER[3],
        NAMEPLATE_CAST_SUCCESS_ALPHA,
        NAMEPLATE_CAST_SUCCESS_DURATION,
        NAMEPLATE_CAST_SUCCESS_EXPAND
    )
end

local function EnsureNameplateCastTextReady(entry, unit)
    if not entry or not entry.castBar then return nil end
    local text = entry.castBar.Text or entry.castBar.text or entry.castBar.Name or entry.castBar.SpellName or entry.castBar.spellName or entry.castBar._midnightText
    if not text then return nil end

    local isTargetUnit = IsTargetUnit(unit or entry.unit)
    local castWidth, _, _, castFontSize = GetNameplateCastConfig(isTargetUnit)
    entry.castBar._midnightText = text
    text:ClearAllPoints()
    text:SetPoint("CENTER", entry.castBar, "CENTER", 0, 0)
    text:SetWidth(math.max(1, castWidth - 10))
    ApplyNameplateFont(text, "Fonts\\FRIZQT__.TTF", castFontSize, "OUTLINE", "CastText")
    text:SetJustifyH("CENTER")
    if text.SetJustifyV then text:SetJustifyV("MIDDLE") end
    text:SetTextColor(1, 1, 1, 1)
    text:SetShadowOffset(1, -1)
    text:SetShadowColor(0, 0, 0, 1)
    if text.SetWordWrap then text:SetWordWrap(false) end
    if text.SetMaxLines then text:SetMaxLines(1) end
    text:SetAlpha(1)
    if text.Show then text:Show() end
    return text
end

local function UpdateNameplateCastBarState(entry, unit)
    if not entry or not entry.castBar or not unit then return end
    if entry.castBar._midnightForceFailedOnce then
        SetNameplateCastInterruptedState(entry, true)
        entry.castBar:SetMinMaxValues(0, 1)
        entry.castBar:SetValue(1)
        local failedText = EnsureNameplateCastTextReady(entry, unit)
        if entry.castBar._midnightFailText and failedText then
            failedText:SetText(entry.castBar._midnightFailText)
        end
        entry.castBar._midnightForceFailedOnce = false
        return
    end

    -- NOTE: Avoid reading cast bar text; it can be a secret value and cause taint/errors.
    local name, _, _, _, _, _, _, notInterruptible = UnitCastingInfo(unit)
    local isChannel = false
    if not name then
        name, _, _, _, _, _, _, notInterruptible = UnitChannelInfo(unit)
        isChannel = true
    end
    if not name then
        if entry.castBar._midnightInterruptedVisualActive and entry.castBar.IsShown and entry.castBar:IsShown() then
            SetNameplateCastBorderColor(entry, INTERRUPTED_CAST_BORDER)
            return
        end
        entry.castBar._midnightInterruptedVisualActive = false
        ClearNameplateCastGlow(entry, "castInterruptGlow")
        SetNameplateCastBorderState(entry, false)
        EnsureNameplateCastTextReady(entry, unit)
        return
    end

    entry.castBar._midnightInterruptedVisualActive = false
    ClearNameplateCastGlow(entry, "castInterruptGlow")
    local isSecret = (type(issecretvalue) == "function" and issecretvalue(notInterruptible)) and true or false
    local isUninterruptible = (not isSecret) and notInterruptible == true
    SetNameplateCastBorderState(entry, not isUninterruptible)
    EnsureNameplateCastTextReady(entry, unit)
end

local function MarkNameplateCastFailed(entry, interrupterName)
    if not entry or not entry.castBar then return end
    entry.castBar._midnightForceFailedOnce = true
    entry.castBar._midnightFailText = "Interrupted"
    SetNameplateCastInterruptedState(entry, true)
    entry.castBar:SetMinMaxValues(0, 1)
    entry.castBar:SetValue(1)

end

local function TrimTextToWidth(fs, text, maxWidth)
    if not fs then return end
    if not text then fs:SetText(""); return end
    
    fs:SetText(text)

    local function SafeCheckWidth()
        local w = fs:GetStringWidth()
        if type(issecretvalue) == "function" then
            if issecretvalue(w) or issecretvalue(maxWidth) then
                return true
            end
        end
        -- If w or maxWidth are restricted/secret, this comparison triggers the error
        if w <= maxWidth then return true end
        return false
    end

    -- Run the check inside pcall to catch the "compare a secret value" error
    local ok, fits = pcall(SafeCheckWidth)

    if not ok then return end

    if fits then return end

    -- Iterate to trim text if it didn't fit and wasn't secret
    local len = #text
    while len > 0 do
        local candidate = string.sub(text, 1, len) .. "..."
        fs:SetText(candidate)
        
        -- We must pcall inside the loop too, just in case
        local loopOk, loopFits = pcall(SafeCheckWidth)
        
        if not loopOk then return end -- Abort on error
        if loopFits then return end
        
        len = len - 1
    end
    fs:SetText("")
end

local function GetBarPercent(bar)
    if not bar then return nil end
    local okMinMax, minVal, maxVal = pcall(bar.GetMinMaxValues, bar)
    local okVal, curVal = pcall(bar.GetValue, bar)
    if not okMinMax or not okVal or maxVal == nil then return nil end
    if type(maxVal) ~= "number" or type(curVal) ~= "number" then return nil end
    if maxVal <= 0 then return nil end
    if type(issecretvalue) == "function" then
        local okSecretMax, isSecretMax = pcall(issecretvalue, maxVal)
        local okSecretCur, isSecretCur = pcall(issecretvalue, curVal)
        if (okSecretMax and isSecretMax) or (okSecretCur and isSecretCur) then
            return nil
        end
    end
    local okPct, pct = pcall(_CalcHealthPct, curVal, maxVal)
    if not okPct then return nil end
    return pct
end

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local lastAllowSecretState = nil
local NameplateHealthPctCache = {}

_G.MidnightUI_GetNameplateHealthPct = function(guid)
    guid = SanitizeCacheKey(guid)
    if not guid then return nil end
    return NameplateHealthPctCache[guid]
end

local function GetDisplayHealthPercent(unit, bar)
    if not unit then return nil end
    local allowSecret = AllowSecretHealthPercent()
    if not allowSecret then
        return nil
    end
    if UnitHealthPercent then
        local scaleTo100 = CurveConstants and CurveConstants.ScaleTo100 or nil
        local ok, pct = pcall(UnitHealthPercent, unit, true, scaleTo100)
        if ok and pct ~= nil then
            if allowSecret or not IsSecretValue(pct) then
                return pct
            end
        end
    end
    return GetBarPercent(bar)
end

local function IsPlayerTank()
    local role = UnitGroupRolesAssigned("player")
    if role == "TANK" then return true end
    if GetSpecializationRole and GetSpecialization then
        local specIndex = GetSpecialization()
        local specRole = specIndex and GetSpecializationRole(specIndex) or nil
        if specRole == "TANK" then return true end
    end
    return false
end

local function UseTankThreatColors()
    if IsPlayerTank() then return true end
    if not IsInGroup() and not IsInRaid() then return true end
    -- NPC followers (quest companions, bodyguards) can trigger IsInGroup()
    -- but GetNumGroupMembers() returns 1 when no real players are in the group
    if IsInGroup() and not IsInRaid() and GetNumGroupMembers() <= 1 then return true end
    return false
end


local function GroupHasTank()
    if IsPlayerTank() then return true end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "TANK" then
                return true
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local unit = "party" .. i
            if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "TANK" then
                return true
            end
        end
    end
    return false
end

local function ClearGroupThreatCache()
    for k in pairs(groupThreatCache) do
        groupThreatCache[k] = nil
    end
end

local function GetGroupRelativeThreatState(unit, playerThreatPct)
    if (not IsInGroup() and not IsInRaid()) then return nil end
    if IsPlayerTank() then return nil end
    if GroupHasTank() then return nil end
    if not playerThreatPct or playerThreatPct <= 0 then return nil end

    local guid = GetSafeUnitGuid(unit)
    local now = GetTime()
    if guid then
        local cached = groupThreatCache[guid]
        if cached and (now - cached.time) <= GROUP_THREAT_CACHE_TTL then
            return cached.state
        end
    end

    local topPct = playerThreatPct

    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local member = "raid" .. i
            if not UnitIsUnit(member, "player") and UnitExists(member) then
                local isTanking, mStatus, scaledPct, rawPct = UnitDetailedThreatSituation(member, unit)
                if not (isTanking == nil and mStatus == nil and scaledPct == nil and rawPct == nil) then
                    local pct = NormalizeThreatPercent(scaledPct, rawPct, isTanking, mStatus)
                    if pct and pct > topPct then
                        topPct = pct
                    end
                end
            end
        end
    elseif IsInGroup() then
        for i = 1, GetNumSubgroupMembers() do
            local member = "party" .. i
            if UnitExists(member) then
                local isTanking, mStatus, scaledPct, rawPct = UnitDetailedThreatSituation(member, unit)
                if not (isTanking == nil and mStatus == nil and scaledPct == nil and rawPct == nil) then
                    local pct = NormalizeThreatPercent(scaledPct, rawPct, isTanking, mStatus)
                    if pct and pct > topPct then
                        topPct = pct
                    end
                end
            end
        end
    end

    if topPct <= 0 then return nil end

    local ratio = playerThreatPct / topPct
    local state
    if ratio >= 1 then
        state = "top"
    elseif ratio >= 0.8 then
        state = "close"
    else
        state = "low"
    end

    if guid then
        groupThreatCache[guid] = { time = now, state = state }
    end

    return state
end

local function GetReactionColor(unit)
    if UnitIsTapDenied(unit) then
        return THREAT_HEALTH_COLORS.gray
    end
    if UnitIsPlayer(unit) and UnitIsFriend("player", unit) then
        local r, g, b = GetUnitClassColor(unit)
        return { r, g, b }
    end
    local reaction = UnitReaction(unit, "player")
    if reaction == 4 then
        return THREAT_HEALTH_COLORS.yellow
    end
    if reaction and reaction >= 5 then
        return THREAT_HEALTH_COLORS.green
    end
    return THREAT_HEALTH_COLORS.red
end

local function GetHealthBarColor(unit)
    if not unit or IsSecretValue(unit) or not UnitExists(unit) then return nil end

    local isPlayerTank = UseTankThreatColors()
    local inCombat = UnitAffectingCombat(unit)
    local isTanking, status = UnitDetailedThreatSituation("player", unit)
    local simpleStatus = UnitThreatSituation("player", unit)
    local threatStatus = NormalizeThreatStatus(status)
    if threatStatus == nil then
        threatStatus = NormalizeThreatStatus(simpleStatus)
    end

    if inCombat and threatStatus ~= nil then
        if isPlayerTank then
            if threatStatus >= 3 then
                return THREAT_HEALTH_COLORS.green
            elseif threatStatus == 2 then
                return THREAT_HEALTH_COLORS.yellow
            end
            return THREAT_HEALTH_COLORS.red
        else
            if threatStatus >= 3 then
                return THREAT_HEALTH_COLORS.red
            elseif threatStatus == 2 then
                return THREAT_HEALTH_COLORS.yellow
            end
            return THREAT_HEALTH_COLORS.green
        end
    end

    return GetReactionColor(unit)
end

local function GetThreatBarColor(threatPct, isTank)
    local perc = SafePercent(threatPct)
    if isTank then
        return ColorGradient(
            perc,
            THREAT_BAR_COLORS.red[1], THREAT_BAR_COLORS.red[2], THREAT_BAR_COLORS.red[3],
            THREAT_BAR_COLORS.yellow[1], THREAT_BAR_COLORS.yellow[2], THREAT_BAR_COLORS.yellow[3],
            THREAT_BAR_COLORS.green[1], THREAT_BAR_COLORS.green[2], THREAT_BAR_COLORS.green[3]
        )
    end
    return ColorGradient(
        perc,
        THREAT_BAR_COLORS.green[1], THREAT_BAR_COLORS.green[2], THREAT_BAR_COLORS.green[3],
        THREAT_BAR_COLORS.yellow[1], THREAT_BAR_COLORS.yellow[2], THREAT_BAR_COLORS.yellow[3],
        THREAT_BAR_COLORS.red[1], THREAT_BAR_COLORS.red[2], THREAT_BAR_COLORS.red[3]
    )
end

local function UpdateThreatMarker(marker, container, pct, glow)
    if not marker or not container or not pct then
        if container then container:Hide() end
        return
    end
    local width = container:GetWidth()
    if not width or width <= 0 then
        if container then container:Hide() end
        return
    end
    local clamped = math.max(0, math.min(100, pct))
    local offset = (width - 4) * (clamped / 100)
    container:Show()
    marker:ClearAllPoints()
    marker:SetPoint("LEFT", container, "LEFT", offset, 0)
    marker:SetPoint("TOP")
    marker:SetPoint("BOTTOM")
    if glow then
        glow:ClearAllPoints()
        glow:SetPoint("LEFT", container, "LEFT", offset - 3, 0)
        glow:SetPoint("TOP")
        glow:SetPoint("BOTTOM")
    end
end

local function GetPartyUnits()
    local units = {}
    for i = 1, 4 do
        local unit = "party" .. i
        if UnitExists(unit) then
            units[#units + 1] = unit
        end
    end
    return units
end

local function GetPartyMemberThreatPercent(memberUnit, targetUnit)
    if not memberUnit or not UnitExists(memberUnit) then return nil end
    if not targetUnit or not UnitExists(targetUnit) then return nil end
    local ok, isTanking, status, scaledPct, rawPct = pcall(UnitDetailedThreatSituation, memberUnit, targetUnit)
    if not ok then return nil end
    local simpleStatus = nil
    local okSimple, simple = pcall(UnitThreatSituation, memberUnit, targetUnit)
    if okSimple then simpleStatus = simple end
    return NormalizeThreatPercent(scaledPct, rawPct, isTanking, status, simpleStatus)
end

local function UpdatePartyThreatMarkers(entry, unit, threatWidth, threatEnabled, engagedCombat)
    if not entry or not entry.partyThreatMarkerContainer or not entry.partyThreatMarkers then return end
    local inInstance, instanceType = IsInInstance()
    if not inInstance or instanceType ~= "party" then
        entry.partyThreatMarkerContainer:Hide()
        for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
        return
    end
    if not threatEnabled or not IsInGroup() or IsInRaid() then
        entry.partyThreatMarkerContainer:Hide()
        for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
        return
    end
    if not engagedCombat then
        local unitCombat = UnitAffectingCombat(unit)
        local playerCombat = UnitAffectingCombat("player")
        if not unitCombat and not playerCombat then
            entry.partyThreatMarkerContainer:Hide()
            for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
            return
        end
    end
    if not unit or not UnitExists(unit) then
        entry.partyThreatMarkerContainer:Hide()
        for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
        return
    end
    if UnitIsFriend("player", unit) or not UnitCanAttack("player", unit) then
        entry.partyThreatMarkerContainer:Hide()
        for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
        return
    end
    if not threatWidth or threatWidth <= 0 then
        entry.partyThreatMarkerContainer:Hide()
        for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
        return
    end

    entry.partyThreatMarkerContainer:SetSize(threatWidth, PARTY_THREAT_MARKER_SIZE)
    entry.partyThreatMarkerContainer:Show()

    local members = GetPartyUnits()
    local width = threatWidth
    local maxMarkers = #entry.partyThreatMarkers
    for i = 1, maxMarkers do
        local marker = entry.partyThreatMarkers[i]
        local memberUnit = members[i]
        if marker and memberUnit then
            local pct = GetPartyMemberThreatPercent(memberUnit, unit)
            if pct then
                local clamped = math.max(0, math.min(100, pct))
                local offset = (width - PARTY_THREAT_MARKER_SIZE) * (clamped / 100)
                marker:ClearAllPoints()
                marker:SetPoint("LEFT", entry.partyThreatMarkerContainer, "LEFT", offset, 0)
                marker:SetPoint("BOTTOM", entry.partyThreatMarkerContainer, "BOTTOM", 0, 0)
                local useTankIcon = (not IsPlayerTank()) and UnitGroupRolesAssigned(memberUnit) == "TANK"
                if useTankIcon then
                    ApplyMarkerAtlas(marker.shadow, PARTY_THREAT_TANK_ATLAS, PARTY_THREAT_MARKER_TEXTURE, PARTY_THREAT_TANK_ROTATION)
                    ApplyMarkerAtlas(marker.tex, PARTY_THREAT_TANK_ATLAS, PARTY_THREAT_MARKER_TEXTURE, PARTY_THREAT_TANK_ROTATION)
                else
                    ApplyMarkerAtlas(marker.shadow, marker.defaultAtlas, PARTY_THREAT_MARKER_TEXTURE, marker.defaultRotation)
                    ApplyMarkerAtlas(marker.tex, marker.defaultAtlas, PARTY_THREAT_MARKER_TEXTURE, marker.defaultRotation)
                end
                local r, g, b, isExact = GetPartyMarkerClassColor(memberUnit)
                if not isExact then
                    r, g, b = BoostMarkerColor(r, g, b)
                end
                if marker.tex then
                    marker.tex:SetVertexColor(r, g, b, 1)
                end
                marker:Show()
            else
                marker:Hide()
            end
        elseif marker then
            marker:Hide()
        end
    end
end

local function GetTankUnitsInRaid()
    if not IsInRaid() then return nil, nil end
    local tanks = {}
    for i = 1, GetNumGroupMembers() do
        local unit = "raid" .. i
        if UnitExists(unit) and UnitGroupRolesAssigned(unit) == "TANK" then
            tanks[#tanks + 1] = unit
        end
    end
    if IsPlayerTank() then
        local other = nil
        for _, unit in ipairs(tanks) do
            if not UnitIsUnit(unit, "player") then
                other = unit
                break
            end
        end
        return "player", other
    end
    return tanks[1], tanks[2]
end

local function GetTankThreatPercent(tankUnit, targetUnit)
    if not tankUnit or not UnitExists(tankUnit) then return nil end
    local threatUnit = targetUnit
    if UnitIsUnit(targetUnit, "target") then
        threatUnit = "target"
    end
    local isTanking, status, scaledPct, rawPct = UnitDetailedThreatSituation(tankUnit, threatUnit)
    return NormalizeThreatPercent(scaledPct, rawPct, isTanking, status)
end

local function AdjustTankThreatColors(tank1, tank2, r1, g1, b1, r2, g2, b2)
    if not tank1 or not tank2 then return r1, g1, b1, r2, g2, b2 end
    local _, class1 = UnitClass(tank1)
    local _, class2 = UnitClass(tank2)
    if class1 and class2 and class1 == class2 then
        local t1IsPlayer = UnitIsUnit(tank1, "player")
        local t2IsPlayer = UnitIsUnit(tank2, "player")
        if t1IsPlayer and not t2IsPlayer then
            r1, g1, b1 = r1 * 1.15, g1 * 1.15, b1 * 1.15
            r2, g2, b2 = r2 * 0.7, g2 * 0.7, b2 * 0.7
        elseif t2IsPlayer and not t1IsPlayer then
            r2, g2, b2 = r2 * 1.15, g2 * 1.15, b2 * 1.15
            r1, g1, b1 = r1 * 0.7, g1 * 0.7, b1 * 0.7
        else
            r2, g2, b2 = r2 * 0.7, g2 * 0.7, b2 * 0.7
        end
    end
    return r1, g1, b1, r2, g2, b2
end

local function GetNameplate(unit)
    if not C_NamePlate or not C_NamePlate.GetNamePlateForUnit then return nil end
    return C_NamePlate.GetNamePlateForUnit(unit)
end

local function StyleNameplate(unit)
    if not IsNameplatesEnabled() then return nil end
    if not UnitExists(unit) then return nil end

    local plate = GetNameplate(unit)
    if not plate then return nil end

    local entry = plates[unit]
    if entry and entry.root and entry.root:IsShown() then return entry end

    local unitFrame = plate.UnitFrame or plate.unitFrame
    if unitFrame then SuppressDefault(unitFrame) end

    local root = plate.MidnightUIRoot
      if root and root.MidnightUIEntry then
          local entry = root.MidnightUIEntry
          entry.plate = plate
          entry.unit = unit
          entry.unitFrame = unitFrame
          plates[unit] = entry
          return entry
      end
    if root and not root.MidnightUIEntry then
        root:Hide()
        root:SetParent(nil)
        plate.MidnightUIRoot = nil
        root = nil
    end
      if not root then
          root = CreateFrame("Frame", nil, plate)
        root:SetSize(config.width, config.height)
        root:SetScale(GetNameplateScale(IsTargetUnit(unit)))
        root:SetPoint("CENTER", plate, "CENTER", 0, 0)
        root:SetFrameLevel((unitFrame and unitFrame:GetFrameLevel() or plate:GetFrameLevel()) + 5)
        plate.MidnightUIRoot = root

        -- Ensure entry table exists if we are creating root
          entry = {}
          root.MidnightUIEntry = entry

        local healthBar = CreateFrame("StatusBar", nil, root)
        healthBar:SetAllPoints()
        healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        healthBar:GetStatusBarTexture():SetHorizTile(false)
        healthBar:GetStatusBarTexture():SetVertTile(false)
        healthBar:SetMinMaxValues(0, 1)
        healthBar:SetValue(1)

        local healthBg = healthBar:CreateTexture(nil, "BACKGROUND")
        healthBg:SetAllPoints()
        healthBg:SetColorTexture(0.05, 0.05, 0.05, 0.6)

        local healthShadow = root:CreateTexture(nil, "BACKGROUND")
        healthShadow:SetPoint("TOPLEFT", healthBar, "TOPLEFT", -1, 1)
        healthShadow:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMRIGHT", 1, -1)
        healthShadow:SetColorTexture(0, 0, 0, 0.12)

        local healthBorder = CreateBlackBorder(healthBar, config.borderAlpha)

        local targetGlowBase = CreateBlackBorder(healthBar, 1.0)
        targetGlowBase:SetFrameLevel(healthBar:GetFrameLevel() + 16)
        SetBorderColor(targetGlowBase, 1.00, 0.84, 0.20, 0.85)
        SetBorderThickness(targetGlowBase, 2)
        targetGlowBase:SetAlpha(0)
        targetGlowBase:Hide()

        local targetGlowPulse = CreateFrame("Frame", nil, root)
        targetGlowPulse:SetPoint("TOPLEFT", healthBar, "TOPLEFT", 0, 0)
        targetGlowPulse:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMRIGHT", 0, 0)
        targetGlowPulse:SetFrameLevel(healthBar:GetFrameLevel() + 15)
        local targetGlowPulseBorder = CreateBlackBorder(targetGlowPulse, 1.0)
        SetBorderColor(targetGlowPulseBorder, 1.00, 0.90, 0.35, 0.65)
        SetBorderThickness(targetGlowPulseBorder, 2)
        targetGlowPulse._muiAnchor = healthBar
        targetGlowPulse._muiPulseActive = false
        targetGlowPulse._muiPulseT = 0
        targetGlowPulse:SetAlpha(0)
        targetGlowPulse:Hide()

        local nameContainer = CreateFrame("Frame", nil, healthBar)
        nameContainer:SetPoint("TOPLEFT", healthBar, "TOPLEFT", config.namePadding, -1)
        nameContainer:SetPoint("BOTTOMRIGHT", healthBar, "BOTTOMRIGHT", -config.namePadding, 1)
        nameContainer:SetClipsChildren(true)

        local nameText = healthBar:CreateFontString(nil, "OVERLAY")
        ApplyNameplateFont(nameText, "Fonts\\FRIZQT__.TTF", config.nameFontSize, "OUTLINE", "Name")
        nameText:SetParent(nameContainer)
        nameText:SetPoint("LEFT", nameContainer, "LEFT", 0, 0)
        nameText:SetPoint("RIGHT", nameContainer, "RIGHT", 0, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetWordWrap(false)
        nameText:SetTextColor(1, 1, 1, 1)
        nameText:SetShadowOffset(1, -1)
        nameText:SetShadowColor(0, 0, 0, 1)

        local healthPct = healthBar:CreateFontString(nil, "OVERLAY")
        ApplyNameplateFont(healthPct, "Fonts\\ARIALN.TTF", config.healthPctFontSize, "OUTLINE", "HealthPct")
        healthPct:SetPoint("RIGHT", healthBar, "RIGHT", -6, 0)
        healthPct:SetJustifyH("RIGHT")
        healthPct:SetTextColor(1, 1, 1, 0.9)
        healthPct:SetShadowOffset(1, -1)
        healthPct:SetShadowColor(0, 0, 0, 1)

        nameContainer:ClearAllPoints()
        nameContainer:SetPoint("TOPLEFT", healthBar, "TOPLEFT", config.namePadding, -1)
        nameContainer:SetPoint("BOTTOMLEFT", healthBar, "BOTTOMLEFT", config.namePadding, 1)
        nameContainer:SetPoint("RIGHT", healthPct, "LEFT", -4, 0)

        local dispelIndicator = CreateFrame("Frame", nil, healthBar)
        dispelIndicator:SetSize(18, 18)
        dispelIndicator:SetPoint("BOTTOM", healthBar, "TOP", 0, 6)
        dispelIndicator:SetFrameLevel(healthBar:GetFrameLevel() + 10)
        dispelIndicator:Hide()

        dispelIndicator.icon = dispelIndicator:CreateTexture(nil, "ARTWORK")
        dispelIndicator.icon:SetAllPoints()
        dispelIndicator.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        dispelIndicator.border = CreateFrame("Frame", nil, dispelIndicator, "BackdropTemplate")
        dispelIndicator.border:SetAllPoints()
        dispelIndicator.border:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        dispelIndicator.border:SetBackdropBorderColor(0, 0, 0, 1)

        dispelIndicator.glow = dispelIndicator:CreateTexture(nil, "OVERLAY")
        dispelIndicator.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
        dispelIndicator.glow:SetBlendMode("ADD")
        dispelIndicator.glow:SetPoint("CENTER")
        dispelIndicator.glow:SetSize(36, 36)
        dispelIndicator.glow:SetAlpha(0)

        dispelIndicator.glowAnim = dispelIndicator.glow:CreateAnimationGroup()
        local glowIn = dispelIndicator.glowAnim:CreateAnimation("Alpha")
        glowIn:SetFromAlpha(0.2); glowIn:SetToAlpha(0.85)
        glowIn:SetDuration(0.6); glowIn:SetSmoothing("IN_OUT")
        local glowOut = dispelIndicator.glowAnim:CreateAnimation("Alpha")
        glowOut:SetFromAlpha(0.85); glowOut:SetToAlpha(0.2)
        glowOut:SetDuration(0.6); glowOut:SetSmoothing("IN_OUT")
        glowOut:SetOrder(2)
        dispelIndicator.glowAnim:SetLooping("REPEAT")

        local threatContainer = CreateFrame("Frame", nil, root)
        threatContainer:SetSize(config.width, config.threatHeight)
        threatContainer:SetPoint("TOP", root, "BOTTOM", 0, -config.spacing)

        local threatBg = threatContainer:CreateTexture(nil, "BACKGROUND")
        threatBg:SetAllPoints()
        threatBg:SetColorTexture(0, 0, 0, 0.5)
        CreateBlackBorder(threatContainer, config.borderAlpha)

        local threatBar = CreateFrame("StatusBar", nil, threatContainer)
        threatBar:SetPoint("TOPLEFT", 1, -1)
        threatBar:SetPoint("BOTTOMRIGHT", -1, 1)
        threatBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        threatBar:GetStatusBarTexture():SetHorizTile(false)
        threatBar:GetStatusBarTexture():SetVertTile(false)
        threatBar:SetMinMaxValues(0, 100)
        threatBar:SetValue(0)

        local threatContainer2 = CreateFrame("Frame", nil, root)
        threatContainer2:SetSize(config.width, config.threatHeight)
        threatContainer2:SetPoint("TOP", threatContainer, "BOTTOM", 0, -config.spacing)
        threatContainer2:Hide()

        local threatBg2 = threatContainer2:CreateTexture(nil, "BACKGROUND")
        threatBg2:SetAllPoints()
        threatBg2:SetColorTexture(0, 0, 0, 0.5)
        CreateBlackBorder(threatContainer2, config.borderAlpha)

        local threatBar2 = CreateFrame("StatusBar", nil, threatContainer2)
        threatBar2:SetPoint("TOPLEFT", 1, -1)
        threatBar2:SetPoint("BOTTOMRIGHT", -1, 1)
        threatBar2:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        threatBar2:GetStatusBarTexture():SetHorizTile(false)
        threatBar2:GetStatusBarTexture():SetVertTile(false)
        threatBar2:SetMinMaxValues(0, 100)
        threatBar2:SetValue(0)

        local threatMarkerStack = CreateFrame("Frame", nil, root)
        threatMarkerStack:SetPoint("TOP", threatContainer, "TOP", 0, 0)
        threatMarkerStack:SetSize(config.width, (config.threatHeight * 2) + config.spacing)
        threatMarkerStack:SetFrameLevel(threatContainer:GetFrameLevel() + 10)
        threatMarkerStack:Hide()

        local threatMarkerLine = threatMarkerStack:CreateTexture(nil, "OVERLAY")
        threatMarkerLine:SetColorTexture(1, 1, 1, 1)
        threatMarkerLine:SetWidth(6)
        threatMarkerLine:SetPoint("TOP")
        threatMarkerLine:SetPoint("BOTTOM")

        local threatMarkerGlow = threatMarkerStack:CreateTexture(nil, "OVERLAY")
        threatMarkerGlow:SetColorTexture(1, 1, 1, 0.5)
        threatMarkerGlow:SetWidth(16)
        threatMarkerGlow:SetPoint("TOP")
        threatMarkerGlow:SetPoint("BOTTOM")

        local partyThreatMarkerContainer = CreateFrame("Frame", nil, root)
        partyThreatMarkerContainer:SetSize(config.width, PARTY_THREAT_MARKER_SIZE)
        partyThreatMarkerContainer:SetPoint("TOP", threatContainer, "BOTTOM", 0, -PARTY_THREAT_MARKER_Y_OFFSET)
        partyThreatMarkerContainer:SetFrameStrata(threatContainer:GetFrameStrata())
        partyThreatMarkerContainer:SetFrameLevel(threatContainer:GetFrameLevel() + 20)
        partyThreatMarkerContainer:Hide()

        local partyThreatMarkers = {}
        for i = 1, 4 do
            local marker = CreateFrame("Frame", nil, partyThreatMarkerContainer)
            marker:SetSize(PARTY_THREAT_MARKER_SIZE, PARTY_THREAT_MARKER_SIZE)
            marker:SetPoint("BOTTOM")
            marker:Hide()

            local shadow = marker:CreateTexture(nil, "OVERLAY")
            ApplyMarkerAtlas(shadow, PARTY_THREAT_MARKER_ATLAS, PARTY_THREAT_MARKER_TEXTURE, PARTY_THREAT_MARKER_ROTATION)
            shadow:SetAllPoints()
            shadow:SetVertexColor(0, 0, 0, 0.6)
            shadow:SetBlendMode("BLEND")

            local tex = marker:CreateTexture(nil, "OVERLAY")
            ApplyMarkerAtlas(tex, PARTY_THREAT_MARKER_ATLAS, PARTY_THREAT_MARKER_TEXTURE, PARTY_THREAT_MARKER_ROTATION)
            tex:SetAllPoints()
            tex:SetBlendMode("BLEND")

            marker.shadow = shadow
            marker.tex = tex
            marker.defaultAtlas = PARTY_THREAT_MARKER_ATLAS
            marker.defaultRotation = PARTY_THREAT_MARKER_ROTATION
            partyThreatMarkers[i] = marker
        end

        entry.plate = plate
        entry.unit = unit
        entry.unitFrame = unitFrame
        entry.root = root
        entry.healthBar = healthBar
        entry.healthBorder = healthBorder
        entry.healthBg = healthBg
        entry.targetGlowBase = targetGlowBase
        entry.targetGlowPulse = targetGlowPulse
        entry.name = nameText
        entry.nameContainer = nameContainer
        entry.healthPct = healthPct
        entry.dispelIndicator = dispelIndicator
        -- Debug logging removed.
        entry.threatBar = threatBar
        entry.threatContainer = threatContainer
        entry.threatBar2 = threatBar2
        entry.threatContainer2 = threatContainer2
        entry.threatMarkerStack = threatMarkerStack
        entry.threatMarkerLine = threatMarkerLine
        entry.threatMarkerGlow = threatMarkerGlow
        entry.partyThreatMarkerContainer = partyThreatMarkerContainer
        entry.partyThreatMarkers = partyThreatMarkers
          
          plates[unit] = entry
      end

      if entry then
          ApplyNameplateTextLayout(entry, IsTargetUnit(unit))
          StyleNameplateCastBar(entry, unit)
      end
  
      return entry
  end

local function UpdatePlate(unit)
    if not UnitExists(unit) then return end

    if not IsNameplatesEnabled() then
        local entry = plates[unit]
        if entry then
            UpdateTargetGlow(entry, false)
            if entry.root then entry.root:Hide() end
        end
        return
    end

    local entry = plates[unit] or StyleNameplate(unit)
    if not entry or not entry.healthBar then return end

    if entry.unitFrame then SuppressDefault(entry.unitFrame) end
    if entry then
        StyleNameplateCastBar(entry, unit)
        UpdateNameplateCastBarState(entry, unit)
        UpdateNameplateDispelIndicator(entry, unit)
    end

    if not ShouldShowNameplate(unit) then
        UpdateTargetGlow(entry, false)
        if entry.root then entry.root:Hide() end
        return
    elseif entry.root and not entry.root:IsShown() then
        entry.root:Show()
    end

    local isTargetUnit = IsTargetUnit(unit)
    local healthWidth, healthHeight, healthAlpha, nameFontSize, healthPctFontSize = GetNameplateHealthConfig(isTargetUnit)
    if entry.root then entry.root:SetSize(healthWidth, healthHeight) end
    if entry.root then entry.root:SetScale(GetNameplateScale(isTargetUnit)) end
    UpdateTargetGlow(entry, isTargetUnit)
    if entry.healthBar then entry.healthBar:SetAlpha(healthAlpha) end
    if entry.name then ApplyNameplateFont(entry.name, "Fonts\\FRIZQT__.TTF", nameFontSize, "OUTLINE", "Name") end
    if entry.healthPct then ApplyNameplateFont(entry.healthPct, "Fonts\\ARIALN.TTF", healthPctFontSize, "OUTLINE", "HealthPct") end
    ApplyNameplateTextLayout(entry, isTargetUnit)

    local threatEnabled, threatWidth, threatHeight, threatAlpha = GetNameplateThreatConfig(isTargetUnit)
    if entry.threatContainer then
        entry.threatContainer:SetSize(threatWidth, threatHeight)
        entry.threatContainer:SetAlpha(threatAlpha)
    end
    if entry.threatContainer2 then
        entry.threatContainer2:SetSize(threatWidth, threatHeight)
        entry.threatContainer2:SetAlpha(threatAlpha)
    end
    if not threatEnabled then
        if entry.threatBar then entry.threatBar:SetValue(0); entry.threatBar:Hide() end
        if entry.threatContainer then entry.threatContainer:Hide() end
        if entry.threatBar2 then entry.threatBar2:SetValue(0); entry.threatBar2:Hide() end
        if entry.threatContainer2 then entry.threatContainer2:Hide() end
        if entry.partyThreatMarkerContainer then
            entry.partyThreatMarkerContainer:Hide()
            if entry.partyThreatMarkers then
                for _, marker in ipairs(entry.partyThreatMarkers) do marker:Hide() end
            end
        end
    elseif entry.threatContainer then
        entry.threatContainer:Show()
    end

-- [FIX] Safe Boolean Helper with Block Counter
    local function SafeBoolean(func, ...)
        local function runner(...)
            return func(...)
        end

        local ok, result = pcall(runner, ...)

        if ok then
            local checkOk, isTrue = pcall(_TestEqualsTrue, result)

            if checkOk and isTrue then
                return true
            end
        end
        return false
    end

    local name = UnitName(unit) or ""
    if entry.name and entry.nameContainer then
        TrimTextToWidth(entry.name, name, entry.nameContainer:GetWidth())
    end

    local current = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    
    -- Update Main Bar (Protected)
    pcall(_UpdateHealthBar, entry.healthBar, max, current)
    
    if entry.healthPct then
        local allowSecret = AllowSecretHealthPercent()
        if lastAllowSecretState == nil or lastAllowSecretState ~= allowSecret then
            lastAllowSecretState = allowSecret
        end
        local pct = GetDisplayHealthPercent(unit, entry.healthBar)
        if UnitGUID then
            local guid = GetSafeUnitGuid(unit)
            local cachePct = nil
            if type(pct) == "number" then
                cachePct = pct
            else
                cachePct = GetBarPercent(entry.healthBar)
            end
            if guid and cachePct and type(cachePct) == "number" and not IsSecretValue(cachePct) then
                NameplateHealthPctCache[guid] = cachePct
            end
        end
        local hasDisplay = false
        if pct then
            local ok = pcall(_SetFormattedPct, entry.healthPct, pct)
            if ok then hasDisplay = true end
        end
        if not hasDisplay then
            entry.healthPct:SetText("")
        end
    end

    local color = GetHealthBarColor(unit)
    if color then
        entry.healthBar:SetStatusBarColor(color[1], color[2], color[3], 1.0)
        if entry.healthBg then
            entry.healthBg:SetColorTexture(color[1] * 0.15, color[2] * 0.15, color[3] * 0.15, 0.6)
        end
    end
    ApplyHealthBorderStyle(entry, unit)

    UpdateNameplateDispelIndicator(entry, unit)

    if entry.threatBar and threatEnabled then
        local isTanking, status, scaledPct, rawPct, simpleStatus
        local playerCombat = UnitAffectingCombat("player")
        local unitCombat = UnitAffectingCombat(unit)
        local hasThreatData = false
        local isTargetingPlayer = IsUnitTargetingPlayer(unit)
        local isTargetGuidMatch = false
        
        -- Safe Target GUID Check
        if UnitExists("target") then
            local guid = UnitGUID(unit)
            local targetGuid = UnitGUID("target")
            if guid and targetGuid then
                local ok, match = pcall(_SafeEquals, guid, targetGuid)
                if ok and match then isTargetGuidMatch = true end
            end
        end

        -- Safe UnitIsUnit check using SafeBoolean
        local isTargetUnit = SafeBoolean(UnitIsUnit, unit, "target") or isTargetGuidMatch
        
        local engagedCombat = unitCombat or isTargetingPlayer or (isTargetUnit and playerCombat)
        local inCombat = (playerCombat or unitCombat)
        
        -- Safe UnitGUID Handling
        local unitGuid = UnitGUID(unit)
        local guidChanged = true
        if unitGuid and entry.unitGuid then
            local ok, match = pcall(_SafeEquals, entry.unitGuid, unitGuid)
            if ok and match then guidChanged = false end
        elseif unitGuid == nil and entry.unitGuid == nil then
            guidChanged = false
        end

        if guidChanged then
            entry.unitGuid = unitGuid
            entry.noDataSince = nil
        end

        local now = GetTime()
        local cached = nil
        if unitGuid then
            local ok, val = pcall(_GetFromCache, threatCache, unitGuid)
            if ok then cached = val end
        end
        local cacheAge = cached and (now - cached.time) or nil
        local hasThreatDataEffective = false
        local delayActive = false

        -- Wrapped all conditional checks in SafeBoolean
        if SafeBoolean(UnitIsDeadOrGhost, unit) then
            entry.threatBar:SetValue(0)
            entry.threatBar:Hide()
            if entry.threatBar2 then entry.threatBar2:SetValue(0); entry.threatBar2:Hide() end
            if entry.threatContainer2 then entry.threatContainer2:Hide() end
            entry.noDataSince = nil
        elseif SafeBoolean(UnitIsFriend, "player", unit) or (not SafeBoolean(UnitCanAttack, "player", unit) and not inCombat and not isTargetUnit) then
            entry.threatBar:SetValue(0)
            entry.threatBar:Hide()
            if entry.threatBar2 then entry.threatBar2:SetValue(0); entry.threatBar2:Hide() end
            if entry.threatContainer2 then entry.threatContainer2:Hide() end
            entry.noDataSince = nil
        elseif not engagedCombat then
            local tank1, tank2 = GetTankUnitsInRaid()
            if IsInRaid() and tank1 and isTargetUnit then
                entry.threatBar:Show()
                entry.threatBar:SetValue(1)
                entry.threatBar:SetAlpha(0.35)
                local r1, g1, b1 = GetUnitClassColor(tank1)
                entry.threatBar:SetStatusBarColor(r1, g1, b1, 1.0)
                if entry.threatContainer2 and entry.threatBar2 and tank2 then
                    entry.threatContainer2:Show()
                    entry.threatBar2:Show()
                    entry.threatBar2:SetValue(1)
                    entry.threatBar2:SetAlpha(0.35)
                    local r2, g2, b2 = GetUnitClassColor(tank2)
                    r1, g1, b1, r2, g2, b2 = AdjustTankThreatColors(tank1, tank2, r1, g1, b1, r2, g2, b2)
                    entry.threatBar:SetStatusBarColor(r1, g1, b1, 1.0)
                    entry.threatBar2:SetStatusBarColor(r2, g2, b2, 1.0)
                elseif entry.threatContainer2 and entry.threatBar2 then
                    entry.threatContainer2:Hide()
                    entry.threatBar2:Hide()
                end
                UpdateThreatMarker(entry.threatMarkerLine, entry.threatMarkerStack, nil, entry.threatMarkerGlow, entry.threatMarkerLabel)
            else
                entry.threatBar:SetValue(0)
                entry.threatBar:Hide()
                if entry.threatBar2 then entry.threatBar2:SetValue(0); entry.threatBar2:Hide() end
                if entry.threatContainer2 then entry.threatContainer2:Hide() end
                entry.noDataSince = nil
            end
        else
            isTanking, status, scaledPct, rawPct, simpleStatus = GetThreatDataForUnit(unit)
            hasThreatData = (isTanking ~= nil) or (status ~= nil) or (scaledPct ~= nil) or (rawPct ~= nil) or (simpleStatus ~= nil)
            hasThreatDataEffective = hasThreatData
            if not hasThreatData then
                if not entry.noDataSince then entry.noDataSince = now end
                hasThreatDataEffective = false
            elseif entry.noDataSince then
                if (now - entry.noDataSince) < THREAT_NO_DATA_DELAY then
                    delayActive = true
                    hasThreatDataEffective = false
                else
                    entry.noDataSince = nil
                end
            end
            local tank1, tank2 = GetTankUnitsInRaid()
            if IsInRaid() and tank1 then
                local playerThreatPct = nil
                if UnitIsDeadOrGhost("player") then
                    playerThreatPct = 0
                    entry.lastPlayerThreatPct = 0
                elseif not IsPlayerTank() then
                    playerThreatPct = NormalizeThreatPercent(scaledPct, rawPct, isTanking, status, simpleStatus)
                end
                local source = "live"
                if playerThreatPct ~= nil then
                    entry.lastPlayerThreatPct = playerThreatPct
                else
                    playerThreatPct = entry.lastPlayerThreatPct
                    source = "cache"
                end
                local pct1 = GetTankThreatPercent(tank1, unit)
                entry.threatBar:Show()
                local v1 = (pct1 and pct1 > 0) and pct1 or 1
                local a1 = (pct1 and pct1 > 0) and 1.0 or 0.4
                entry.threatBar:SetValue(v1)
                entry.threatBar:SetAlpha(a1)
                local r1, g1, b1 = GetUnitClassColor(tank1)
                if entry.threatContainer2 and entry.threatBar2 and tank2 then
                    entry.threatContainer2:Show()
                    local pct2 = GetTankThreatPercent(tank2, unit)
                    entry.threatBar2:Show()
                    local v2 = (pct2 and pct2 > 0) and pct2 or 1
                    local a2 = (pct2 and pct2 > 0) and 1.0 or 0.4
                    entry.threatBar2:SetValue(v2)
                    entry.threatBar2:SetAlpha(a2)
                    local r2, g2, b2 = GetUnitClassColor(tank2)
                    r1, g1, b1, r2, g2, b2 = AdjustTankThreatColors(tank1, tank2, r1, g1, b1, r2, g2, b2)
                    entry.threatBar:SetStatusBarColor(r1, g1, b1, 1.0)
                    entry.threatBar2:SetStatusBarColor(r2, g2, b2, 1.0)
                    entry.lastMarkerPct = playerThreatPct
                    UpdateThreatMarker(entry.threatMarkerLine, entry.threatMarkerStack, playerThreatPct, entry.threatMarkerGlow)
                elseif entry.threatContainer2 and entry.threatBar2 then
                    entry.threatContainer2:Hide()
                    entry.threatBar2:Hide()
                    entry.threatBar:SetStatusBarColor(r1, g1, b1, 1.0)
                    entry.lastMarkerPct = playerThreatPct
                    UpdateThreatMarker(entry.threatMarkerLine, entry.threatMarkerStack, playerThreatPct, entry.threatMarkerGlow)
                end

                -- Threat steal highlight: only in group (non-solo), non-tank players, and only if target is selected or targeting player.
                local highlight = false
                if IsInGroup() and not IsPlayerTank() and (isTargetUnit or isTargetingPlayer) then
                    local threatStatus = NormalizeThreatStatus(status)
                    if threatStatus == nil then
                        threatStatus = NormalizeThreatStatus(simpleStatus)
                    end
                    if threatStatus == nil then
                        local okTs, ts = pcall(UnitThreatSituation, "player", unit)
                        if okTs then threatStatus = NormalizeThreatStatus(ts) end
                    end
                    if IsStrictTrue(isTanking) or (threatStatus and threatStatus >= 3) then
                        highlight = true
                    end
                end
                if entry.healthBorder then
                    local isPlayer = false
                    local okIsPlayer, value = pcall(UnitIsPlayer, unit)
                    if okIsPlayer and value then isPlayer = true end
                    if highlight and not isPlayer then
                        SetBorderColor(entry.healthBorder, 1, 0.85, 0.1, 1)
                        SetBorderThickness(entry.healthBorder, 2)
                    else
                        ApplyHealthBorderStyle(entry, unit)
                    end
                end
        else
            entry.threatBar:Show()
            if entry.threatContainer2 then entry.threatContainer2:Hide() end
            if entry.threatBar2 then entry.threatBar2:Hide() end
            UpdateThreatMarker(entry.threatMarkerLine, entry.threatMarkerStack, nil, entry.threatMarkerGlow)

                ApplyHealthBorderStyle(entry, unit)
                local threatPct = NormalizeThreatPercent(scaledPct, rawPct, isTanking, status, simpleStatus)
                if (not hasThreatData or threatPct == 0) and isTargetingPlayer then
                    threatPct = 100
                end
                if hasThreatData and unitGuid then
                    threatCache[unitGuid] = { pct = threatPct, time = now, status = status, simpleStatus = simpleStatus }
                end
                local cacheUsed = false
                local cacheReason = nil
                local fallbackApplied = false
                if engagedCombat and not SafeBoolean(UnitIsFriend, "player", unit) and not hasThreatDataEffective then
                    local unitTarget = unit .. "target"
                    if UnitExists(unitTarget) then
                        if SafeBoolean(UnitIsUnit, unitTarget, "player") then
                            threatPct = 50
                            cacheReason = delayActive and "DATA_DELAY_TARGET_PLAYER_YELLOW" or "NO_DATA_TARGET_PLAYER_YELLOW"
                        else
                            threatPct = 0
                            cacheReason = delayActive and "DATA_DELAY_TARGET_OTHER_RED" or "NO_DATA_TARGET_OTHER_RED"
                        end
                    else
                        threatPct = 50
                        cacheReason = delayActive and "DATA_DELAY_NO_TARGET_YELLOW" or "NO_DATA_NO_TARGET_YELLOW"
                    end
                    fallbackApplied = true
                end
                entry.threatBar:SetValue(threatPct)
                local r, g, b = GetThreatBarColor(threatPct, UseTankThreatColors())
                entry.threatBar:SetStatusBarColor(r, g, b, 1.0)
                if hasThreatData and not delayActive then
                    local groupState = GetGroupRelativeThreatState(unit, threatPct)
                    if groupState then
                        local hc
                        local tc
                        local useTankColors = UseTankThreatColors()
                        if groupState == "top" then
                            if useTankColors then
                                hc = THREAT_HEALTH_COLORS.green
                                tc = THREAT_BAR_COLORS.green
                            else
                                hc = THREAT_HEALTH_COLORS.red
                                tc = THREAT_BAR_COLORS.red
                            end
                        elseif groupState == "close" then
                            hc = THREAT_HEALTH_COLORS.yellow
                            tc = THREAT_BAR_COLORS.yellow
                        else
                            if useTankColors then
                                hc = THREAT_HEALTH_COLORS.red
                                tc = THREAT_BAR_COLORS.red
                            else
                                hc = THREAT_HEALTH_COLORS.green
                                tc = THREAT_BAR_COLORS.green
                            end
                        end
                        entry.healthBar:SetStatusBarColor(hc[1], hc[2], hc[3], 1.0)
                        entry.threatBar:SetStatusBarColor(tc[1], tc[2], tc[3], 1.0)
                    end
                end
            end
        end
    end

    UpdatePartyThreatMarkers(entry, unit, threatWidth, threatEnabled, engagedCombat)
end

local function OnNameplateAdded(unit)
    StyleNameplate(unit)
    UpdatePlate(unit)
    -- Restart ticker if it was auto-stopped due to empty plates
    -- (uses NameplateManager field since StartNameplateTicker is defined later)
    if not NameplateManager.updateTicker and NameplateManager._startTicker then
        NameplateManager._startTicker()
    end
end

local function OnNameplateRemoved(unit)
    local entry = plates[unit]
    if entry then UpdateTargetGlow(entry, false) end
    if entry and entry.threatBar then entry.threatBar:Hide() end
    plates[unit] = nil
end

local function UpdateAllPlates()
    if not IsNameplatesEnabled() then
        HideAllPlates()
        return
    end
    for unit, _ in pairs(plates) do
        if UnitExists(unit) then
            UpdatePlate(unit)
        else
            plates[unit] = nil
        end
    end

    if text then
        text:ClearAllPoints()
        text:SetPoint("CENTER", castBar, "CENTER", 0, 0)
        text:SetWidth(math.max(1, castWidth - 10))
        ApplyNameplateFont(text, "Fonts\\FRIZQT__.TTF", castFontSize, "OUTLINE", "CastText")
        text:SetJustifyH("CENTER")
        text:SetJustifyV("MIDDLE")
        text:SetTextColor(1, 1, 1, 1)
        text:SetShadowOffset(1, -1)
        text:SetShadowColor(0, 0, 0, 1)
        if text.SetWordWrap then text:SetWordWrap(false) end
        if text.SetMaxLines then text:SetMaxLines(1) end
        text:SetAlpha(1)
        if text.Show then text:Show() end
    end

    if timer then
        timer:ClearAllPoints()
        timer:SetPoint("RIGHT", castBar, "RIGHT", -5, 0)
        ApplyNameplateFont(timer, "Fonts\\ARIALN.TTF", config.healthPctFontSize + 2, "OUTLINE", "CastTimer")
        timer:SetJustifyH("RIGHT")
        timer:SetTextColor(1, 1, 1, 1)
        timer:SetShadowOffset(1, -1)
        timer:SetShadowColor(0, 0, 0, 1)
        timer:SetAlpha(1)
        if timer.Show then timer:Show() end
    end

    local debugUnit = unit
    if debugUnit == nil and entry then
        debugUnit = entry.unit
    end
    local barName = nil
    if castBar and castBar.GetName then
        local ok, name = pcall(castBar.GetName, castBar)
        if ok then
            barName = name
        end
    end
    local textShown = nil
    if text and text.IsShown then
        local ok, shown = pcall(text.IsShown, text)
        if ok then
            textShown = shown
        end
    end
    local textAlpha = nil
    if text and text.GetAlpha then
        local ok, alpha = pcall(text.GetAlpha, text)
        if ok then
            textAlpha = alpha
        end
    end
    local textParent = nil
    if text and text.GetParent then
        local ok, parent = pcall(text.GetParent, text)
        if ok then
            textParent = parent
        end
    end
    local textParentName = nil
    if textParent and textParent.GetName then
        local ok, name = pcall(textParent.GetName, textParent)
        if ok then
            textParentName = name
        end
    end
end

function MidnightUI_RefreshNameplates()
    if not IsNameplatesEnabled() then
        HideAllPlates()
        return
    end
    UpdateAllPlates()
end

NameplateManager:RegisterEvent("ADDON_LOADED")
NameplateManager:RegisterEvent("NAME_PLATE_UNIT_ADDED")
NameplateManager:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
NameplateManager:RegisterEvent("UNIT_THREAT_SITUATION_UPDATE")
NameplateManager:RegisterEvent("UNIT_THREAT_LIST_UPDATE")
NameplateManager:RegisterEvent("PLAYER_ROLES_ASSIGNED")
NameplateManager:RegisterEvent("GROUP_ROSTER_UPDATE")
NameplateManager:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
NameplateManager:RegisterEvent("UNIT_HEALTH")
NameplateManager:RegisterEvent("UNIT_MAXHEALTH")
NameplateManager:RegisterEvent("PLAYER_TARGET_CHANGED")
NameplateManager:RegisterEvent("UNIT_TARGET")
NameplateManager:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
NameplateManager:RegisterEvent("UNIT_SPELLCAST_CHANNEL_STOP")
NameplateManager:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
NameplateManager:RegisterEvent("UNIT_SPELLCAST_FAILED")
NameplateManager:RegisterEvent("PLAYER_REGEN_DISABLED")
NameplateManager:RegisterEvent("PLAYER_REGEN_ENABLED")
NameplateManager:RegisterEvent("CVAR_UPDATE")
NameplateManager:RegisterEvent("SPELLS_CHANGED")
NameplateManager:RegisterEvent("PLAYER_TALENT_UPDATE")
NameplateManager:RegisterEvent("UNIT_PET")

NameplateManager:SetScript("OnEvent", function(self, event, ...)
    if not IsNameplatesEnabled() then
        HideAllPlates()
        return
    end
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end
        EnsureEnemyPlayerNameplatesEnabled()
        UpdateAllPlates()
        return
    end

    if event == "NAME_PLATE_UNIT_ADDED" then
        OnNameplateAdded(...)
    elseif event == "NAME_PLATE_UNIT_REMOVED" then
        OnNameplateRemoved(...)
    elseif event == "UNIT_THREAT_SITUATION_UPDATE" or event == "UNIT_THREAT_LIST_UPDATE" then
        local unit = ...
        if unit and plates[unit] then UpdatePlate(unit) end
    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        local unit = ...
        if unit and plates[unit] then UpdatePlate(unit) end
elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_CHANNEL_STOP" then
        local unit = ...
        if unit and plates[unit] then
            MarkNameplateCastFailed(plates[unit], nil)
            UpdatePlate(unit)
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit, _, spellId = ...
        if unit and plates[unit] then
            PlayNameplateCastSuccessPulse(plates[unit])
        end
    elseif event == "UNIT_SPELLCAST_FAILED" then
        local unit, _, spellId = ...
        if unit and plates[unit] then
            MarkNameplateCastFailed(plates[unit], nil)
            UpdatePlate(unit)
        end
        
    -- [FIX] Delay Specialization Updates to prevent Blizzard_CooldownViewer crash
    elseif event == "PLAYER_ROLES_ASSIGNED" or event == "GROUP_ROSTER_UPDATE" then
        ClearGroupThreatCache()
        UpdateAllPlates()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        -- We delay this update slightly. Blizzard's CooldownViewer runs its save/serialize 
        -- logic immediately on this event. If we try to access/modify UI states 
        -- simultaneously, it can cause the "keys must be numbers" serialization error.
        C_Timer.After(0.5, function()
            ClearGroupThreatCache()
            UpdateAllPlates()
        end)
        
    elseif event == "PLAYER_TARGET_CHANGED" or event == "UNIT_TARGET" or event == "CVAR_UPDATE" then
        UpdateAllPlates()
        
    elseif event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "UNIT_PET" then
        UpdateAllPlates()

    -- [SILENT] Combat Error Protection
    elseif event == "PLAYER_REGEN_DISABLED" then
        UpdateAllPlates()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- We do not print the report anymore, but the errors were still blocked safely.
        UpdateAllPlates()
    end
end)

local function StopNameplateTicker()
    if not NameplateManager.updateTicker then return end
    NameplateManager.updateTicker:Cancel()
    NameplateManager.updateTicker = nil
end

local function StartNameplateTicker()
    if NameplateManager.updateTicker then return end
    NameplateManager.updateTicker = C_Timer.NewTicker(config.updateInterval, function()
        if not IsNameplatesEnabled() then return end
        -- Auto-stop when no plates are active (saves CPU out of combat)
        if not next(plates) then
            StopNameplateTicker()
            return
        end
        UpdateAllPlates()
    end)
end

StartNameplateTicker()
NameplateManager._startTicker = StartNameplateTicker

function _G.MidnightUI_GetNameplateCastBar(unit)
    if not unit then return nil end
    local entry = plates[unit]
    if entry and entry.castBar then
        return entry.castBar
    end
    if C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local ok, plate = pcall(C_NamePlate.GetNamePlateForUnit, unit)
        if ok and plate then
            local unitFrame = plate.UnitFrame or plate.unitFrame
            if unitFrame then
                return unitFrame.castBar or unitFrame.CastBar
            end
        end
    end
    return nil
end


