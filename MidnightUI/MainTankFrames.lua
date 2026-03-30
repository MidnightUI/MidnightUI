-- =============================================================================
-- FILE PURPOSE:     Custom main tank frames. Monitors the MT roster (players assigned
--                   the MAIN_TANK role) and shows one compact frame per tank with
--                   health/power bars, debuff hazard tint (MAIN_TANK_HAZARD_ENUM),
--                   and a debuff preview icon strip. Dynamically appears/disappears
--                   as tanks enter/leave the roster.
-- LOAD ORDER:       Loads after ConditionBorder.lua. MainTankManager handles ADDON_LOADED,
--                   GROUP_ROSTER_UPDATE, and PLAYER_ENTERING_WORLD.
-- DEFINES:          MainTankManager (event frame), MainTankFrames[] (per-tank entries),
--                   MainTankAnchor (drag container). Global: MidnightUI_ApplyMainTankSettings().
-- READS:            MidnightUISettings.MainTankFrames.{enabled, width, height, scale, alpha,
--                   position, spacing, debuffMaxShown, debuffIconSize, debuffPerRow}.
--                   MidnightUISettings.General.unitFrameBarStyle.
-- WRITES:           MidnightUISettings.MainTankFrames.position (on drag stop).
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (tank health bar by class).
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua).
-- USED BY:          Settings_UI.lua (exposes main tank settings controls).
-- KEY FLOWS:
--   GROUP_ROSTER_UPDATE → RebuildMainTankFrames() → queries UnitGroupRolesAssigned for
--                         MAIN_TANK role, builds/shows one frame per qualifying member.
--   UNIT_HEALTH/UNIT_POWER tankN → UpdateHealth/Power per frame
--   UNIT_AURA tankN → MAIN_TANK_HAZARD_ENUM probe → tint + debuff preview strip
-- GOTCHAS:
--   ComputeMainTankBarHeights(): health and power sub-bars are computed from total frame
--   height using a 72%/28% split (with minimum floors). All layout code must call this
--   instead of using config.healthHeight/powerHeight directly, since height is settable.
--   MAIN_TANK_HAZARD_STICKY_SEC = 8s: longer than party (0.45s) because tank debuffs
--   in raid context are higher stakes and healers need more reaction time.
--   GetMainTankDebuffSettings(): reads debuff icon count/size/perRow from settings with
--   hard clamps (1-40 icons, 8-40px size) to prevent layout overflow.
--   isUnlocked flag: frame is locked/draggable through the overlay manager, not directly.
-- NAVIGATION:
--   ComputeMainTankBarHeights()  — dynamic health/power sub-bar height split (line ~31)
--   LayoutMainTankBarContainers()— applies computed heights to frame children (line ~58)
--   MAIN_TANK_HAZARD_ENUM / COLORS — dispel type definitions (line ~102)
--   GetMainTankDebuffSettings()  — settings accessor for debuff preview (line ~148)
--   RebuildMainTankFrames()      — roster query → frame pool management
--   UpdateMainTankLivePreviewForFrame() — test mode preview injector
-- =============================================================================

local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then
    ADDON_NAME = "MidnightUI"
end
if type(Addon) ~= "table" then
    Addon = {}
end
local MainTankManager = CreateFrame("Frame")

-- =========================================================================
--  CONFIG
-- =========================================================================

local config = {
    width = 260,
    height = 58,
    healthHeight = 42,
    powerHeight = 14,
    spacing = 6,
    scale = 1.0,
    startPos = {"TOPLEFT", UIParent, "TOPLEFT", 20, -620},
}

local MAIN_TANK_BAR_SPLIT_SPACING = 1
local MAIN_TANK_BAR_DIVIDER_THICKNESS = 1

local function ComputeMainTankBarHeights(frameHeight)
    local h = tonumber(frameHeight) or config.height or 58
    h = math.max(16, math.floor(h + 0.5))
    -- barFrame is inset by 1px on top and bottom, so use interior height.
    local interior = math.max(16, h - 2)
    local available = math.max(12, interior - MAIN_TANK_BAR_SPLIT_SPACING)
    local health = math.floor((h * 0.72) + 0.5)
    if health < 10 then
        health = 10
    end
    if health > (available - 6) then
        health = available - 6
    end
    local power = available - health
    if power < 6 then
        power = 6
        health = available - power
    end
    return health, power
end

do
    local hh, ph = ComputeMainTankBarHeights(config.height)
    config.healthHeight = hh
    config.powerHeight = ph
end

local function LayoutMainTankBarContainers(frame)
    if not frame then
        return
    end
    local hh, ph = ComputeMainTankBarHeights(config.height)
    config.healthHeight = hh
    config.powerHeight = ph

    local barFrame = frame.barFrame
    if barFrame then
        if frame.healthContainer then
            frame.healthContainer:ClearAllPoints()
            frame.healthContainer:SetPoint("TOPLEFT", barFrame, "TOPLEFT", 0, 0)
            frame.healthContainer:SetPoint("TOPRIGHT", barFrame, "TOPRIGHT", 0, 0)
            frame.healthContainer:SetHeight(config.healthHeight)
        end
        if frame.powerContainer and frame.healthContainer then
            frame.powerContainer:ClearAllPoints()
            frame.powerContainer:SetPoint("TOPLEFT", frame.healthContainer, "BOTTOMLEFT", 0, -MAIN_TANK_BAR_SPLIT_SPACING)
            frame.powerContainer:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
        elseif frame.powerContainer then
            frame.powerContainer:ClearAllPoints()
            frame.powerContainer:SetPoint("BOTTOMLEFT", barFrame, "BOTTOMLEFT", 0, 0)
            frame.powerContainer:SetPoint("BOTTOMRIGHT", barFrame, "BOTTOMRIGHT", 0, 0)
            frame.powerContainer:SetHeight(config.powerHeight)
        end
    end

    if frame.healthBg then frame.healthBg:SetHeight(config.healthHeight) end
    if frame.healthBar then frame.healthBar:SetHeight(config.healthHeight) end
    if frame.powerBg then frame.powerBg:SetHeight(config.powerHeight) end
    if frame.powerBar then frame.powerBar:SetHeight(config.powerHeight) end
end

local POWER_COLORS = {
    ["MANA"] = {0.00, 0.50, 1.00}, ["RAGE"] = {0.90, 0.10, 0.10}, ["FOCUS"] = {1.00, 0.50, 0.25},
    ["ENERGY"] = {1.00, 1.00, 0.35}, ["COMBO_POINTS"] = {1.00, 0.96, 0.41}, ["RUNES"] = {0.50, 0.50, 0.50},
    ["RUNIC_POWER"] = {0.00, 0.82, 1.00}, ["SOUL_SHARDS"] = {0.50, 0.32, 0.55}, ["LUNAR_POWER"] = {0.30, 0.52, 0.90},
    ["HOLY_POWER"] = {0.95, 0.90, 0.60}, ["MAELSTROM"] = {0.00, 0.50, 1.00}, ["CHI"] = {0.71, 1.00, 0.92},
    ["INSANITY"] = {0.40, 0.00, 0.80}, ["ARCANE_CHARGES"] = {0.10, 0.10, 0.98}, ["FURY"] = {0.79, 0.26, 0.99},
    ["PAIN"] = {1.00, 0.61, 0.00}, ["ESSENCE"] = {0.20, 0.88, 0.66},
}
local DEFAULT_POWER_COLOR = {0.0, 0.5, 1.0}
local DEAD_STATUS_ATLAS = "icons_64x64_deadly"
local MAIN_TANK_HAZARD_ENUM = {
    None = 0,
    Magic = 1,
    Curse = 2,
    Disease = 3,
    Poison = 4,
    Enrage = 9,
    Bleed = 11,
    Unknown = 99,
}
local MAIN_TANK_HAZARD_LABELS = {
    [MAIN_TANK_HAZARD_ENUM.None] = "NONE",
    [MAIN_TANK_HAZARD_ENUM.Magic] = "MAGIC",
    [MAIN_TANK_HAZARD_ENUM.Curse] = "CURSE",
    [MAIN_TANK_HAZARD_ENUM.Disease] = "DISEASE",
    [MAIN_TANK_HAZARD_ENUM.Poison] = "POISON",
    [MAIN_TANK_HAZARD_ENUM.Bleed] = "BLEED",
    [MAIN_TANK_HAZARD_ENUM.Unknown] = "UNKNOWN",
}
local MAIN_TANK_HAZARD_COLORS = {
    [MAIN_TANK_HAZARD_ENUM.Magic] = { 0.15, 0.55, 0.95 },
    [MAIN_TANK_HAZARD_ENUM.Curse] = { 0.70, 0.20, 0.95 },
    [MAIN_TANK_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [MAIN_TANK_HAZARD_ENUM.Poison] = { 0.15, 0.65, 0.20 },
    [MAIN_TANK_HAZARD_ENUM.Bleed] = { 0.95, 0.15, 0.15 },
    [MAIN_TANK_HAZARD_ENUM.Unknown] = { 0.64, 0.19, 0.79 },
}
local MAIN_TANK_HAZARD_PRIORITY = {
    MAIN_TANK_HAZARD_ENUM.Magic,
    MAIN_TANK_HAZARD_ENUM.Curse,
    MAIN_TANK_HAZARD_ENUM.Disease,
    MAIN_TANK_HAZARD_ENUM.Poison,
    MAIN_TANK_HAZARD_ENUM.Bleed,
}
local MAIN_TANK_HAZARD_CURVE_EPSILON = 0.02
local MAIN_TANK_HAZARD_STICKY_SEC = 8
local MAIN_TANK_DEBUFF_TINT_BASE_MUL = 0.60
local MAIN_TANK_DEBUFF_PREVIEW = {
    iconSize = 16,
    maxIcons = 3,
    maxIconsLimit = 40,
    defaultPerRow = 4,
    offsetY = 0,
    placeholderIcon = 134400,
}

local function GetMainTankDebuffSettings()
    local s = MidnightUISettings and MidnightUISettings.MainTankFrames
    local maxIcons = (s and s.debuffMaxShown) or MAIN_TANK_DEBUFF_PREVIEW.maxIcons
    local iconSize = (s and s.debuffIconSize) or MAIN_TANK_DEBUFF_PREVIEW.iconSize
    local perRow = (s and s.debuffPerRow) or MAIN_TANK_DEBUFF_PREVIEW.defaultPerRow
    if maxIcons < 1 then maxIcons = 1 end
    if maxIcons > MAIN_TANK_DEBUFF_PREVIEW.maxIconsLimit then maxIcons = MAIN_TANK_DEBUFF_PREVIEW.maxIconsLimit end
    if perRow < 1 then perRow = 1 end
    if iconSize < 8 then iconSize = 8 end
    if iconSize > 40 then iconSize = 40 end
    return maxIcons, iconSize, perRow
end

local MainTankFrames = {}
local MainTankAnchor
local pendingLockState
local pendingRosterUpdate
local isUnlocked = false
local _mtHazardProbeCurves = {}
local _mtHazardProbeMatchColors = {}
local _mtHazardZeroProbeCurve = nil
local _mainTankBlizzAuraCache = {}
local _mainTankBlizzHookRegistered = false
local UpdateMainTankLivePreviewForFrame
local ClearMainTankDebuffPreviewForFrame
local IsMainTankDebuffVisualsEnabled

local function IsMainTankDiagEnabled()
    local diag = _G.MidnightUI_Diagnostics
    if not diag or type(diag.LogDebugSource) ~= "function" then
        return false
    end
    if type(diag.IsEnabled) == "function" then
        local okEnabled, enabled = pcall(diag.IsEnabled)
        return okEnabled and enabled == true
    end
    return true
end

local function IsMainTankPreviewDiagEnabled()
    if not _G.MidnightUI_Debug then
        return false
    end
    local s = MidnightUISettings
    return s
        and s.MainTankFrames
        and s.MainTankFrames.debuffPreviewDebug == true
end

local function MainTankDiag(msg)
    if not IsMainTankPreviewDiagEnabled() then
        return
    end
    local text = tostring(msg or "")
    local src = "MainTankDebuffPreview"
    if IsMainTankDiagEnabled() then
        pcall(_G.MidnightUI_Diagnostics.LogDebugSource, src, text)
        return
    end
    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. text)
end

local function DebugMT(msg)
    MainTankDiag(msg)
end

local function EnsureDeadIconTexture(icon)
    if not icon then return end
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(DEAD_STATUS_ATLAS) then
        icon:SetAtlas(DEAD_STATUS_ATLAS, false)
    else
        icon:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    end
end

local function ApplyDeadIconVisualStyle(icon)
    if not icon then return end
    EnsureDeadIconTexture(icon)
    if icon.SetDesaturated then icon:SetDesaturated(false) end
    icon:SetVertexColor(1, 0.2, 0.2, 1)
    icon:SetAlpha(1)
end

-- =========================================================================
--  HELPERS
-- =========================================================================

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
end

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = 11,
            healthFont = "Fonts\\FRIZQT__.TTF",
            healthSize = 10,
            nameShadowAlpha = 0.9,
            healthShadowAlpha = 0.9,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    frame.nameText:SetShadowOffset(1, -1); frame.nameText:SetShadowColor(0, 0, 0, 1)
    frame.healthText:SetShadowOffset(1, -1); frame.healthText:SetShadowColor(0, 0, 0, 1)
end

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local function IsSecretValue(val)
    if type(issecretvalue) ~= "function" then return false end
    local ok, res = pcall(issecretvalue, val)
    return ok and res == true
end

local function IsUnitActuallyDead(unit)
    if not unit or not UnitExists(unit) then return false end

    local okDead, dead = pcall(UnitIsDead, unit)
    if okDead and type(dead) == "boolean" and dead then
        return true
    end

    local okGhost, ghost = pcall(UnitIsGhost, unit)
    if okGhost and type(ghost) == "boolean" and ghost then
        return true
    end

    local okHp, hp = pcall(UnitHealth, unit)
    if okHp and type(hp) == "number" then
        local okCmp, isZeroOrLess = pcall(function()
            return hp <= 0
        end)
        if okCmp and isZeroOrLess then
            return true
        end
    end

    return false
end

local function GetDisplayHealthPercent(unit)
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
    return nil
end

local function CreateDropShadow(frame, intensity)
    intensity = intensity or 3
    local shadows = {}
    for i = 1, intensity do
        local shadowLayer = CreateFrame("Frame", nil, frame)
        shadowLayer:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 1.0
        local alpha = (0.25 - (i * 0.04)) * (intensity / 4)
        shadowLayer:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        shadowLayer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        local shadowTex = shadowLayer:CreateTexture(nil, "BACKGROUND")
        shadowTex:SetAllPoints()
        shadowTex:SetColorTexture(0, 0, 0, alpha)
        shadowLayer.tex = shadowTex
        table.insert(shadows, shadowLayer)
    end
    return shadows
end

local function IsSameUnitToken(unitA, unitB)
    if not unitA or not unitB then return false end
    if type(unitA) ~= "string" or type(unitB) ~= "string" then return false end
    return unitA == unitB
end

local function NormalizeMainTankHazardEnum(value)
    if value == nil then
        return nil
    end
    local valueType = type(value)
    if valueType == "number" then
        if IsSecretValue(value) then
            return nil
        end
        if value == MAIN_TANK_HAZARD_ENUM.Magic or value == MAIN_TANK_HAZARD_ENUM.Curse
            or value == MAIN_TANK_HAZARD_ENUM.Disease or value == MAIN_TANK_HAZARD_ENUM.Poison
            or value == MAIN_TANK_HAZARD_ENUM.Bleed or value == MAIN_TANK_HAZARD_ENUM.Unknown then
            return value
        end
        if value == MAIN_TANK_HAZARD_ENUM.Enrage then
            return MAIN_TANK_HAZARD_ENUM.Bleed
        end
        return nil
    end
    if valueType ~= "string" then
        return nil
    end
    if IsSecretValue(value) then
        return nil
    end
    local okUpper, upper = pcall(string.upper, value)
    if not okUpper or type(upper) ~= "string" then
        return nil
    end
    if upper:find("MAGIC", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Magic
    elseif upper:find("CURSE", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Curse
    elseif upper:find("DISEASE", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Disease
    elseif upper:find("POISON", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Poison
    elseif upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Bleed
    elseif upper:find("UNKNOWN", 1, true) then
        return MAIN_TANK_HAZARD_ENUM.Unknown
    end
    return nil
end

local function GetMainTankHazardLabel(enum)
    local normalized = NormalizeMainTankHazardEnum(enum)
    if not normalized then
        return "NONE"
    end
    return MAIN_TANK_HAZARD_LABELS[normalized] or "NONE"
end

local function GetMainTankHazardColor(enum)
    local normalized = NormalizeMainTankHazardEnum(enum)
    if not normalized then
        return nil
    end
    return MAIN_TANK_HAZARD_COLORS[normalized]
end

local function IsMainTankSecretColor(color)
    if type(color) ~= "table" then
        return false
    end
    if color.secret == true then
        return true
    end
    return IsSecretValue(color[1]) or IsSecretValue(color[2]) or IsSecretValue(color[3])
end

local function FormatMainTankColorForDiag(color)
    if type(color) ~= "table" then
        return "none"
    end
    if IsMainTankSecretColor(color) then
        return "secret"
    end
    local r = tonumber(color[1])
    local g = tonumber(color[2])
    local b = tonumber(color[3])
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then
        return "invalid"
    end
    return string.format("%.3f,%.3f,%.3f", r, g, b)
end

local function CoerceMainTankTintChannel(value)
    if value == nil or IsSecretValue(value) then
        return nil
    end
    local number = tonumber(value)
    if type(number) ~= "number" then
        return nil
    end
    if number < 0 then
        number = 0
    elseif number > 1 then
        number = 1
    end
    return number
end

local function ParseMainTankRGBText(text)
    if type(text) ~= "string" or IsSecretValue(text) then
        return nil, nil, nil
    end
    local r, g, b = text:match("([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")
    if not r then
        return nil, nil, nil
    end
    return CoerceMainTankTintChannel(r), CoerceMainTankTintChannel(g), CoerceMainTankTintChannel(b)
end

local function CloneMainTankColor(color)
    if type(color) ~= "table" then
        return nil
    end
    if color.secret == true then
        if color[1] == nil or color[2] == nil or color[3] == nil then
            return nil
        end
        return { color[1], color[2], color[3], secret = true, source = color.source }
    end
    local r = CoerceMainTankTintChannel(color[1] or color.r)
    local g = CoerceMainTankTintChannel(color[2] or color.g)
    local b = CoerceMainTankTintChannel(color[3] or color.b)
    if r == nil or g == nil or b == nil then
        return nil
    end
    return { r, g, b }
end

local function IsQuestionMarkToken(iconToken)
    if type(iconToken) ~= "string" then
        return false
    end
    local okLower, lower = pcall(string.lower, iconToken)
    if not okLower or type(lower) ~= "string" then
        return false
    end
    return lower:find("questionmark", 1, true) ~= nil
        or lower:find("inv_misc_questionmark", 1, true) ~= nil
end

local function CanUseMainTankIconToken(iconToken)
    if iconToken == nil then
        return false
    end
    if IsSecretValue(iconToken) then
        return true
    end
    local tokenType = type(iconToken)
    if tokenType == "number" then
        if iconToken == MAIN_TANK_DEBUFF_PREVIEW.placeholderIcon then
            return false
        end
        return iconToken > 0
    end
    if tokenType == "string" then
        if iconToken == "" then
            return false
        end
        if IsQuestionMarkToken(iconToken) then
            return false
        end
        return true
    end
    return false
end

local function MainTankIconKind(iconToken)
    if iconToken == nil then
        return "nil"
    end
    local tokenType = type(iconToken)
    if IsSecretValue(iconToken) then
        return "secret:" .. tokenType
    end
    if tokenType == "string" and IsQuestionMarkToken(iconToken) then
        return "placeholder"
    end
    return tokenType
end

local function NormalizeMainTankAuraStackCount(value)
    if value == nil or IsSecretValue(value) then
        return ""
    end
    local number = tonumber(value)
    if (not number) or IsSecretValue(number) then
        return ""
    end
    number = math.floor(number + 0.5)
    if number <= 1 then
        return ""
    end
    return tostring(number)
end

local function IsMainTankCurveColorMatch(a, b)
    if not a or not b then
        return false
    end
    if a.IsEqualTo then
        local okEq, matched = pcall(a.IsEqualTo, a, b)
        if okEq and matched == true then
            return true
        end
    end
    local okA, ar, ag, ab, aa = pcall(a.GetRGBA, a)
    local okB, br, bg, bb, ba = pcall(b.GetRGBA, b)
    if not okA or not okB then
        return false
    end
    local function SafeChannel(value)
        if value == nil or IsSecretValue(value) then
            return nil
        end
        local number = tonumber(value)
        if type(number) ~= "number" then
            return nil
        end
        return number
    end
    ar, ag, ab, aa = SafeChannel(ar), SafeChannel(ag), SafeChannel(ab), SafeChannel(aa)
    br, bg, bb, ba = SafeChannel(br), SafeChannel(bg), SafeChannel(bb), SafeChannel(ba)
    if (not ar) or (not ag) or (not ab) or (not aa) or (not br) or (not bg) or (not bb) or (not ba) then
        return false
    end
    local eps = MAIN_TANK_HAZARD_CURVE_EPSILON
    if math.abs(ar - br) > eps then return false end
    if math.abs(ag - bg) > eps then return false end
    if math.abs(ab - bb) > eps then return false end
    if math.abs(aa - ba) > eps then return false end
    return true
end

local function IsMainTankCurveColorDifferent(a, b)
    if not a or not b then
        return false
    end
    if a.IsEqualTo then
        local okEq, same = pcall(a.IsEqualTo, a, b)
        if okEq then
            return same ~= true
        end
    end
    local okA, ar, ag, ab, aa = pcall(a.GetRGBA, a)
    local okB, br, bg, bb, ba = pcall(b.GetRGBA, b)
    if not okA or not okB then
        return false
    end
    local function SafeChannel(value)
        if value == nil or IsSecretValue(value) then
            return nil
        end
        local number = tonumber(value)
        if type(number) ~= "number" then
            return nil
        end
        return number
    end
    ar, ag, ab, aa = SafeChannel(ar), SafeChannel(ag), SafeChannel(ab), SafeChannel(aa)
    br, bg, bb, ba = SafeChannel(br), SafeChannel(bg), SafeChannel(bb), SafeChannel(ba)
    if (not ar) or (not ag) or (not ab) or (not aa) or (not br) or (not bg) or (not bb) or (not ba) then
        return false
    end
    local eps = MAIN_TANK_HAZARD_CURVE_EPSILON
    if math.abs(ar - br) > eps then return true end
    if math.abs(ag - bg) > eps then return true end
    if math.abs(ab - bb) > eps then return true end
    if math.abs(aa - ba) > eps then return true end
    return false
end

local function GetMainTankHazardProbeCurve(targetEnum)
    local normalized = NormalizeMainTankHazardEnum(targetEnum)
    if not normalized then
        return nil
    end
    if _mtHazardProbeCurves[normalized] then
        return _mtHazardProbeCurves[normalized]
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
        return nil
    end
    if not Enum or not Enum.LuaCurveType then
        return nil
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    local function Add(enumValue)
        local pointEnum = NormalizeMainTankHazardEnum(enumValue) or enumValue
        local alpha = (pointEnum == normalized) and 1 or 0
        curve:AddPoint(enumValue, CreateColor(1, 1, 1, alpha))
    end
    Add(MAIN_TANK_HAZARD_ENUM.None)
    Add(MAIN_TANK_HAZARD_ENUM.Magic)
    Add(MAIN_TANK_HAZARD_ENUM.Curse)
    Add(MAIN_TANK_HAZARD_ENUM.Disease)
    Add(MAIN_TANK_HAZARD_ENUM.Poison)
    Add(MAIN_TANK_HAZARD_ENUM.Enrage)
    Add(MAIN_TANK_HAZARD_ENUM.Bleed)
    _mtHazardProbeCurves[normalized] = curve
    _mtHazardProbeMatchColors[normalized] = CreateColor(1, 1, 1, 1)
    return curve
end

local function GetMainTankHazardZeroProbeCurve()
    if _mtHazardZeroProbeCurve then
        return _mtHazardZeroProbeCurve
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
        return nil
    end
    if not Enum or not Enum.LuaCurveType then
        return nil
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.None, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Magic, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Curse, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Poison, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Enrage, CreateColor(1, 1, 1, 0))
    curve:AddPoint(MAIN_TANK_HAZARD_ENUM.Bleed, CreateColor(1, 1, 1, 0))
    _mtHazardZeroProbeCurve = curve
    return curve
end

local function ResolveMainTankHazardEnumByCurve(unit, auraInstanceID)
    if not unit or not auraInstanceID then
        return nil
    end
    if not C_UnitAuras or type(C_UnitAuras.GetAuraDispelTypeColor) ~= "function" then
        return nil
    end
    local zeroCurve = GetMainTankHazardZeroProbeCurve()
    for _, enum in ipairs(MAIN_TANK_HAZARD_PRIORITY) do
        local curve = GetMainTankHazardProbeCurve(enum)
        if curve then
            local okColor, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
            if okColor and color then
                if zeroCurve then
                    local okZero, zeroColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, zeroCurve)
                    if okZero and IsMainTankCurveColorDifferent(color, zeroColor) then
                        return enum
                    end
                end
                local expected = _mtHazardProbeMatchColors[NormalizeMainTankHazardEnum(enum)]
                if expected and IsMainTankCurveColorMatch(color, expected) then
                    return enum
                end
                if color.GetRGBA then
                    local okAlpha, _, _, _, a = pcall(color.GetRGBA, color)
                    if okAlpha and (not IsSecretValue(a)) then
                        local alpha = tonumber(a)
                        if alpha and alpha > 0.05 then
                            return enum
                        end
                    end
                end
            end
        end
    end
    return nil
end

local function ResolveMainTankHazardFromAura(unit, aura)
    if type(aura) ~= "table" then
        return nil, nil
    end
    local dt = NormalizeMainTankHazardEnum(aura.dispelType)
    if dt then return dt, "field:dispelType" end
    dt = NormalizeMainTankHazardEnum(aura.dispelName)
    if dt then return dt, "field:dispelName" end
    dt = NormalizeMainTankHazardEnum(aura.debuffType)
    if dt then return dt, "field:debuffType" end
    dt = NormalizeMainTankHazardEnum(aura.type)
    if dt then return dt, "field:type" end
    local auraInstanceID = aura.auraInstanceID
    if auraInstanceID then
        dt = ResolveMainTankHazardEnumByCurve(unit, auraInstanceID)
        if dt then
            return dt, "curve"
        end
    end
    return nil, nil
end

local function ResolveMainTankHazardFromAuraInstanceID(unit, auraInstanceID, typeHint)
    local dt = NormalizeMainTankHazardEnum(typeHint)
    if dt and dt ~= MAIN_TANK_HAZARD_ENUM.Unknown then
        return dt, "blizz:type"
    end
    dt = ResolveMainTankHazardEnumByCurve(unit, auraInstanceID)
    if dt then
        return dt, "blizz:curve"
    end
    return nil, nil
end

local function IsMainTankBlizzTrackedUnit(unit)
    if type(unit) ~= "string" then
        return false
    end
    if unit == "player" then
        return true
    end
    if string.match(unit, "^party%d$") then
        return true
    end
    return string.match(unit, "^raid%d+$") ~= nil
end

local function ResolveMainTankHazardFromBlizzFrameDebuff(debuffFrame)
    if not debuffFrame then
        return nil
    end
    local dt = NormalizeMainTankHazardEnum(debuffFrame.debuffType)
    if not dt then dt = NormalizeMainTankHazardEnum(debuffFrame.dispelName) end
    if not dt then dt = NormalizeMainTankHazardEnum(debuffFrame.dispelType) end
    if not dt then dt = NormalizeMainTankHazardEnum(debuffFrame.type) end
    return dt
end

local function CountMainTankBlizzAuraSet(tbl)
    if type(tbl) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- File-scope aura helpers (avoids closure allocation per CompactUnitFrame_UpdateAuras hook call)
local function ReadTextureToken(texObj)
    if not texObj then
        return nil
    end
    if texObj.GetTextureFileID then
        local okID, texID = pcall(texObj.GetTextureFileID, texObj)
        if okID and texID ~= nil then
            return texID
        end
    end
    if texObj.GetTexture then
        local okTex, tex = pcall(texObj.GetTexture, texObj)
        if okTex and tex ~= nil then
            return tex
        end
    end
    return nil
end

local function ReadDebuffFrameIcon(df)
    if not df then
        return nil
    end
    local icon = ReadTextureToken(df.icon)
    if not icon then icon = ReadTextureToken(df.Icon) end
    if not icon then icon = ReadTextureToken(df.iconTexture) end
    if (not icon) and (type(df.icon) == "number" or type(df.icon) == "string") then
        icon = df.icon
    end
    return icon
end

local function ReadDebuffFrameStack(df)
    if not df then
        return nil
    end
    local stack = tonumber(df.applications or df.stackCount)
    if (not stack) and df.count then
        if type(df.count) == "number" then
            if not IsSecretValue(df.count) then
                stack = tonumber(df.count)
            end
        elseif df.count.GetText then
            local okText, text = pcall(df.count.GetText, df.count)
            if okText and text ~= nil and (not IsSecretValue(text)) then
                local okNum, parsed = pcall(tonumber, text)
                if okNum and type(parsed) == "number" and (not IsSecretValue(parsed)) then
                    stack = parsed
                end
            end
        end
    end
    if stack and (not IsSecretValue(stack)) and stack > 1 then
        return math.floor(stack + 0.5)
    end
    return nil
end

local function StoreMainTankAura(entry, iid, isDispellable, dt, icon, stackCount)
    if not iid then
        return
    end
    entry.debuffs[iid] = true
    if isDispellable then
        entry.dispellable[iid] = true
    end
    if dt and dt ~= MAIN_TANK_HAZARD_ENUM.Unknown then
        entry.types[iid] = dt
    end
    if icon then
        entry.icons[iid] = icon
    end
    if stackCount and stackCount > 1 then
        entry.stacks[iid] = stackCount
    end
end

local function CaptureMainTankHazardsFromBlizzFrame(blizzFrame)
    if not blizzFrame then
        return nil, nil
    end
    local unit = blizzFrame.unit
    if not IsMainTankBlizzTrackedUnit(unit) then
        return nil, nil
    end
    if UnitExists and type(UnitExists) == "function" and not UnitExists(unit) then
        return nil, nil
    end

    local entry = _mainTankBlizzAuraCache[unit]
    if not entry then
        entry = { debuffs = {}, dispellable = {}, types = {}, icons = {}, stacks = {} }
        _mainTankBlizzAuraCache[unit] = entry
    else
        if type(entry.icons) ~= "table" then entry.icons = {} end
        if type(entry.stacks) ~= "table" then entry.stacks = {} end
        wipe(entry.debuffs)
        wipe(entry.dispellable)
        wipe(entry.types)
        wipe(entry.icons)
        wipe(entry.stacks)
    end

    if type(blizzFrame.debuffFrames) == "table" then
        for _, df in pairs(blizzFrame.debuffFrames) do
            local shown = (not df) and false or (not df.IsShown) or df:IsShown()
            if df and df.auraInstanceID and shown then
                StoreMainTankAura(entry,
                    df.auraInstanceID,
                    false,
                    ResolveMainTankHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df)
                )
            end
        end
    end

    if type(blizzFrame.dispelDebuffFrames) == "table" then
        for _, df in pairs(blizzFrame.dispelDebuffFrames) do
            local shown = (not df) and false or (not df.IsShown) or df:IsShown()
            if df and df.auraInstanceID and shown then
                StoreMainTankAura(entry,
                    df.auraInstanceID,
                    true,
                    ResolveMainTankHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df)
                )
            end
        end
    end

    return unit, entry
end

local function PrimeMainTankBlizzAuraCache()
    local compactPlayerFrame = _G.CompactPlayerFrame
    if compactPlayerFrame and compactPlayerFrame.unit == "player" then
        CaptureMainTankHazardsFromBlizzFrame(compactPlayerFrame)
    end

    for i = 1, 5 do
        local compactParty = _G["CompactPartyFrameMember" .. tostring(i)]
        if compactParty and compactParty.unit then
            CaptureMainTankHazardsFromBlizzFrame(compactParty)
        end
    end

    for i = 1, 40 do
        local compactRaid = _G["CompactRaidFrame" .. tostring(i)]
        if compactRaid and compactRaid.unit then
            CaptureMainTankHazardsFromBlizzFrame(compactRaid)
        end
    end
end

local function EnsureMainTankBlizzAuraHook()
    if _mainTankBlizzHookRegistered then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end

    local function OnBlizzAuraUpdate(blizzFrame)
        CaptureMainTankHazardsFromBlizzFrame(blizzFrame)
    end

    if type(CompactUnitFrame_UpdateAuras) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", OnBlizzAuraUpdate)
        _mainTankBlizzHookRegistered = true
    end
    if type(CompactUnitFrame_UpdateDebuffs) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", OnBlizzAuraUpdate)
        _mainTankBlizzHookRegistered = true
    end

    if _mainTankBlizzHookRegistered then
        PrimeMainTankBlizzAuraCache()
        DebugMT("blizzHook=ON")
    end
end

local function GetMainTankHazardHintFromPlayerFrameCondTint()
    local frame = _G.MidnightUI_PlayerFrame
    if not frame then
        return nil, nil, nil, nil, "playerframe-unavailable", nil
    end
    if frame._muiCondTintActive ~= true then
        return nil, nil, nil, nil, "playerframe-condtint-off", nil
    end

    local enum = NormalizeMainTankHazardEnum(frame._muiCondTintSource)
    local r = CoerceMainTankTintChannel(frame._muiCondTintR)
    local g = CoerceMainTankTintChannel(frame._muiCondTintG)
    local b = CoerceMainTankTintChannel(frame._muiCondTintB)
    local hasRGB = (r ~= nil and g ~= nil and b ~= nil)
    local hasColor = (frame._muiCondTintHasColor == true) or (frame._muiCondTintSecret == true) or hasRGB
    local secretColor = nil
    if frame._muiCondTintSecret == true and frame._muiCondTintHasColor == true then
        local sr, sg, sb = frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB
        if sr ~= nil and sg ~= nil and sb ~= nil then
            secretColor = { sr, sg, sb, secret = true, source = frame._muiCondTintSource }
        end
    end

    if enum then
        return enum, r, g, b, "playerframe-condtint-enum", secretColor
    end
    if hasColor then
        if secretColor then
            return MAIN_TANK_HAZARD_ENUM.Unknown, nil, nil, nil, "playerframe-condtint-secret", secretColor
        end
        return MAIN_TANK_HAZARD_ENUM.Unknown, r, g, b, "playerframe-condtint-unknown", nil
    end
    return nil, nil, nil, nil, "playerframe-condtint-none", nil
end

local function GetMainTankHazardHintFromConditionBorder(unit)
    local isPlayer = (unit == "player")
    if (not isPlayer) and UnitIsUnit and type(unit) == "string" then
        local okIsUnit, sameUnit = pcall(UnitIsUnit, unit, "player")
        isPlayer = okIsUnit and sameUnit == true
    end
    if not isPlayer then
        return nil, nil, nil, nil, "non-player-unit", nil, nil, nil
    end

    local cb = _G.MidnightUI_ConditionBorder
    if cb and type(cb.GetStateSnapshot) == "function" then
        local okState, state = pcall(cb.GetStateSnapshot)
        if okState and type(state) == "table" then
            local enum = NormalizeMainTankHazardEnum(state.primaryEnum)
                or NormalizeMainTankHazardEnum(state.activePrimaryEnum)
                or NormalizeMainTankHazardEnum(state.curvePrimaryEnum)
                or NormalizeMainTankHazardEnum(state.overlapPrimaryEnum)
                or NormalizeMainTankHazardEnum(state.hookPrimaryEnum)
                or NormalizeMainTankHazardEnum(state.barTintEnum)
                or NormalizeMainTankHazardEnum(state.primaryLabel)
                or NormalizeMainTankHazardEnum(state.tintSource)

            local secondaryEnum = NormalizeMainTankHazardEnum(state.overlapSecondaryEnum)
                or NormalizeMainTankHazardEnum(state.activeSecondaryEnum)
                or NormalizeMainTankHazardEnum(state.hookSecondaryEnum)
            local typeBoxEnum = NormalizeMainTankHazardEnum(state.typeBoxEnum)
            if (not secondaryEnum) and typeBoxEnum and typeBoxEnum ~= MAIN_TANK_HAZARD_ENUM.Unknown then
                secondaryEnum = typeBoxEnum
            end

            local secondaryColor = nil
            local rawSecR, rawSecG, rawSecB = state.typeBoxR, state.typeBoxG, state.typeBoxB
            if rawSecR ~= nil and rawSecG ~= nil and rawSecB ~= nil then
                if IsSecretValue(rawSecR) or IsSecretValue(rawSecG) or IsSecretValue(rawSecB) then
                    secondaryColor = { rawSecR, rawSecG, rawSecB, secret = true, source = "condborder-state-typebox" }
                else
                    local secR = CoerceMainTankTintChannel(rawSecR)
                    local secG = CoerceMainTankTintChannel(rawSecG)
                    local secB = CoerceMainTankTintChannel(rawSecB)
                    if secR ~= nil and secG ~= nil and secB ~= nil then
                        secondaryColor = { secR, secG, secB }
                    end
                end
            end
            if not secondaryColor then
                local secR, secG, secB = ParseMainTankRGBText(state.typeBoxRGB)
                if secR ~= nil and secG ~= nil and secB ~= nil then
                    secondaryColor = { secR, secG, secB }
                end
            end

            local r, g, b = ParseMainTankRGBText(state.barTintRGB)
            if r == nil then
                r, g, b = ParseMainTankRGBText(state.tintRGB)
            end

            local active = (state.active == true) or (state.tintActive == true)
            local barTintOn = false
            if type(state.barTint) == "string" and not IsSecretValue(state.barTint) then
                local okFind, found = pcall(string.find, state.barTint, "ON", 1, true)
                barTintOn = okFind and found ~= nil
            end

            if enum then
                return enum, r, g, b, "condborder-state-enum", nil, secondaryEnum, secondaryColor
            end
            if active or barTintOn then
                local frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor = GetMainTankHazardHintFromPlayerFrameCondTint()
                if frameEnum and frameEnum ~= MAIN_TANK_HAZARD_ENUM.Unknown then
                    return frameEnum, frameR, frameG, frameB, "playerframe-fallback:" .. tostring(frameSource), frameSecretColor, secondaryEnum, secondaryColor
                end
                if type(frameSecretColor) == "table" and frameSecretColor.secret == true then
                    return MAIN_TANK_HAZARD_ENUM.Unknown, nil, nil, nil, "playerframe-fallback-secret", frameSecretColor, secondaryEnum, secondaryColor
                end
                if r ~= nil and g ~= nil and b ~= nil then
                    return MAIN_TANK_HAZARD_ENUM.Unknown, r, g, b, "condborder-state-unknown-rgb", nil, secondaryEnum, secondaryColor
                end
                if frameEnum == MAIN_TANK_HAZARD_ENUM.Unknown then
                    return MAIN_TANK_HAZARD_ENUM.Unknown, frameR, frameG, frameB, "playerframe-fallback-unknown", nil, secondaryEnum, secondaryColor
                end
                return MAIN_TANK_HAZARD_ENUM.Unknown, nil, nil, nil, "condborder-state-unknown", nil, secondaryEnum, secondaryColor
            end
        end
    end

    local frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor = GetMainTankHazardHintFromPlayerFrameCondTint()
    return frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor, nil, nil
end

local function GetMainTankHazardIconAtlas(enum)
    local normalized = NormalizeMainTankHazardEnum(enum)
    if normalized == MAIN_TANK_HAZARD_ENUM.Magic then
        return "RaidFrame-Icon-DebuffMagic"
    elseif normalized == MAIN_TANK_HAZARD_ENUM.Curse then
        return "RaidFrame-Icon-DebuffCurse"
    elseif normalized == MAIN_TANK_HAZARD_ENUM.Disease then
        return "RaidFrame-Icon-DebuffDisease"
    elseif normalized == MAIN_TANK_HAZARD_ENUM.Poison then
        return "RaidFrame-Icon-DebuffPoison"
    elseif normalized == MAIN_TANK_HAZARD_ENUM.Bleed then
        return "RaidFrame-Icon-DebuffBleed"
    end
    return nil
end

local function GetCachedMainTankBarColor(bar)
    if not bar then
        return nil, nil, nil
    end
    local r = CoerceMainTankTintChannel(bar._muiLastSafeColorR)
    local g = CoerceMainTankTintChannel(bar._muiLastSafeColorG)
    local b = CoerceMainTankTintChannel(bar._muiLastSafeColorB)
    if r == nil or g == nil or b == nil then
        return nil, nil, nil
    end
    return r, g, b
end

local function SetMainTankBarColor(bar, r, g, b, a)
    if not bar or type(bar.SetStatusBarColor) ~= "function" then
        return
    end
    bar:SetStatusBarColor(r, g, b, a)
    local safeR = CoerceMainTankTintChannel(r)
    local safeG = CoerceMainTankTintChannel(g)
    local safeB = CoerceMainTankTintChannel(b)
    if safeR ~= nil and safeG ~= nil and safeB ~= nil then
        bar._muiLastSafeColorR = safeR
        bar._muiLastSafeColorG = safeG
        bar._muiLastSafeColorB = safeB
    end
end

local function SetMainTankRenderedSecretPolish(bar, suppressed)
    if not bar then
        return
    end
    if suppressed ~= true then
        bar._muiMainTankSecretRenderedPolish = false
        return
    end
    if bar._muiTopHighlight then
        pcall(bar._muiTopHighlight.SetBlendMode, bar._muiTopHighlight, "ADD")
        bar._muiTopHighlight:SetGradient("VERTICAL",
            CreateColor(0.09, 0.09, 0.09, 1),
            CreateColor(0.00, 0.00, 0.00, 1))
        bar._muiTopHighlight:Show()
    end
    if bar._muiBottomShade then
        pcall(bar._muiBottomShade.SetBlendMode, bar._muiBottomShade, "ADD")
        bar._muiBottomShade:SetGradient("VERTICAL",
            CreateColor(0.00, 0.00, 0.00, 1),
            CreateColor(0.09, 0.09, 0.09, 1))
        bar._muiBottomShade:Show()
    end
    if bar._muiSpecular then
        bar._muiSpecular:Hide()
    end
    bar._muiMainTankSecretRenderedPolish = true
end

local function ApplyPolishedGradientToBar(bar, tex, topDarkA, centerLightA, bottomDarkA)
    if not bar then return end
    local anchor = tex or bar
    local baseR, baseG, baseB = bar:GetStatusBarColor()
    baseR = CoerceMainTankTintChannel(baseR)
    baseG = CoerceMainTankTintChannel(baseG)
    baseB = CoerceMainTankTintChannel(baseB)
    local cachedR, cachedG, cachedB = GetCachedMainTankBarColor(bar)
    -- Restricted values can be secret; prefer last known safe color to keep polish stable.
    if baseR == nil then baseR = cachedR or 0.5 end
    if baseG == nil then baseG = cachedG or 0.5 end
    if baseB == nil then baseB = cachedB or 0.5 end
    local function Darken(v, f)
        local n = (v or 0) * f
        if n < 0 then return 0 end
        if n > 1 then return 1 end
        return n
    end
    local function Lift(v, a)
        local b = v or 0
        local n = b + (1 - b) * (a or 0.035)
        if n < 0 then return 0 end
        if n > 1 then return 1 end
        return n
    end
    local edgeR, edgeG, edgeB = Darken(baseR, 0.74), Darken(baseG, 0.74), Darken(baseB, 0.74)
    local midR, midG, midB = Lift(baseR, 0.10), Lift(baseG, 0.10), Lift(baseB, 0.10)
    if not bar._muiTopHighlight then
        bar._muiTopHighlight = bar:CreateTexture(nil, "ARTWORK", nil, 2)
    end
    bar._muiTopHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiTopHighlight:SetBlendMode("DISABLE")
    if not bar._muiBottomShade then
        bar._muiBottomShade = bar:CreateTexture(nil, "ARTWORK", nil, 1)
    end
    bar._muiBottomShade:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiBottomShade:SetBlendMode("DISABLE")
    if not bar._muiSpecular then
        bar._muiSpecular = bar:CreateTexture(nil, "ARTWORK", nil, 3)
    end
    bar._muiSpecular:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiSpecular:SetBlendMode("ADD")
    local rawH = (bar.GetHeight and bar:GetHeight()) or 2
    local h = tonumber(tostring(rawH)) or 2
    local topH = math.max(1, h * 0.43)
    local botH = math.max(1, h * 0.57)
    local specH = math.max(1, h * 0.35)
    bar._muiTopHighlight:ClearAllPoints()
    bar._muiTopHighlight:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    bar._muiTopHighlight:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
    bar._muiTopHighlight:SetHeight(topH)
    bar._muiTopHighlight:SetGradient("VERTICAL",
        CreateColor(midR, midG, midB, 1),
        CreateColor(edgeR, edgeG, edgeB, 1))

    bar._muiBottomShade:ClearAllPoints()
    bar._muiBottomShade:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
    bar._muiBottomShade:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
    bar._muiBottomShade:SetHeight(botH)
    bar._muiBottomShade:SetGradient("VERTICAL",
        CreateColor(edgeR, edgeG, edgeB, 1),
        CreateColor(midR, midG, midB, 1))

    bar._muiSpecular:ClearAllPoints()
    bar._muiSpecular:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    bar._muiSpecular:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
    bar._muiSpecular:SetHeight(specH)
    bar._muiSpecular:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0),
        CreateColor(1, 1, 1, 0.06))

    bar._muiTopHighlight:Show()
    bar._muiBottomShade:Show()
    bar._muiSpecular:Show()
end

local function HidePolishedGradientOnBar(bar)
    if not bar then return end
    if bar._muiTopHighlight then bar._muiTopHighlight:Hide() end
    if bar._muiBottomShade then bar._muiBottomShade:Hide() end
    if bar._muiSpecular then bar._muiSpecular:Hide() end
end

local function ApplyMainTankBarStyle(frame)
    if not frame then return end
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    local isGradient = (style == "Gradient")
    local texPath = "Interface\\Buttons\\WHITE8X8"
    if frame.healthBar then
        frame.healthBar:SetStatusBarTexture(texPath)
        local tex = frame.healthBar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
        end
        if isGradient then
            ApplyPolishedGradientToBar(frame.healthBar, tex, 0.28, 0.035, 0.32)
        else
            HidePolishedGradientOnBar(frame.healthBar)
        end
        SetMainTankRenderedSecretPolish(frame.healthBar, false)
    end
    if frame.powerBar then
        frame.powerBar:SetStatusBarTexture(texPath)
        local tex = frame.powerBar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
        end
        if isGradient then
            ApplyPolishedGradientToBar(frame.powerBar, tex, 0.24, 0.03, 0.28)
        else
            HidePolishedGradientOnBar(frame.powerBar)
        end
    end
    ApplyFrameTextStyle(frame)
    if frame.healthBg then frame.healthBg:SetColorTexture(0.1, 0.1, 0.1, 1) end
    if frame.powerBg then frame.powerBg:SetColorTexture(0.08, 0.08, 0.08, 1) end
end

local function ApplyMainTankFramesBarStyle()
    for _, frame in ipairs(MainTankFrames) do
        ApplyMainTankBarStyle(frame)
    end
end
_G.MidnightUI_ApplyMainTankFramesBarStyle = ApplyMainTankFramesBarStyle

local function ApplyMainTankPlaceholder(frame, index)
    frame.nameText:SetText("MAIN TANK " .. index)
    frame.nameText:SetTextColor(0.9, 0.9, 0.9)
    frame.healthText:SetText("--")
    if frame.deadIcon then frame.deadIcon:Hide() end
    SetMainTankBarColor(frame.healthBar, 0.3, 0.3, 0.3, 0.8)
    frame.healthBar:SetMinMaxValues(0, 1)
    frame.healthBar:SetValue(1)
    SetMainTankRenderedSecretPolish(frame.healthBar, false)
    frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
    SetMainTankBarColor(frame.powerBar, 0.2, 0.2, 0.2, 0.6)
    frame.powerBar:SetMinMaxValues(0, 1)
    frame.powerBar:SetValue(0)
    if frame.roleIcon then
        frame.roleIcon:SetTexture("Interface\\AddOns\\MidnightUI\\Media\\TankIcon")
        if not frame.roleIcon:GetTexture() then
            frame.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
            frame.roleIcon:SetTexCoord(0, 19/64, 22/64, 41/64)
        end
        frame.roleIcon:Show()
    end
    if frame.portrait then
        frame.portrait:SetTexture("Interface\\CharacterFrame\\TempPortrait")
        frame.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    if ClearMainTankDebuffPreviewForFrame then
        ClearMainTankDebuffPreviewForFrame(frame)
    end
    frame._muiMainTankLiveLastSig = nil
end

local function GetDefaultAnchorPosition()
    return config.startPos[1], config.startPos[2], config.startPos[3], config.startPos[4], config.startPos[5]
end

local function ApplyMainTankAnchorPosition()
    if not MainTankAnchor then return end
    MainTankAnchor:ClearAllPoints()
    local pos = (MidnightUISettings and MidnightUISettings.MainTankFrames and MidnightUISettings.MainTankFrames.position)
    if pos and #pos >= 4 then
        if pos[5] then
            MainTankAnchor:SetPoint(pos[1], UIParent, pos[3], pos[4], pos[5])
        else
            MainTankAnchor:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        end
    else
        local p1, p2, p3, p4, p5 = GetDefaultAnchorPosition()
        MainTankAnchor:SetPoint(p1, p2, p3, p4, p5)
    end
end

local function EnsureMainTankAnchor()
    if MainTankAnchor then return end
    MainTankAnchor = CreateFrame("Frame", "MidnightUI_MainTankAnchor", UIParent, "BackdropTemplate")
    MainTankAnchor:SetFrameStrata("MEDIUM")
    MainTankAnchor:SetFrameLevel(5)
    MainTankAnchor:SetClampedToScreen(true)
    MainTankAnchor:SetSize(config.width, (config.height * 2) + config.spacing)
    ApplyMainTankAnchorPosition()
end

local function EnsureMainTankSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
    if not MidnightUISettings.MainTankFrames.frames then
        MidnightUISettings.MainTankFrames.frames = {}
    end
    if MidnightUISettings.MainTankFrames.width == nil then MidnightUISettings.MainTankFrames.width = config.width end
    if MidnightUISettings.MainTankFrames.height == nil then MidnightUISettings.MainTankFrames.height = config.height end
    if MidnightUISettings.MainTankFrames.spacing == nil then MidnightUISettings.MainTankFrames.spacing = config.spacing end
    if MidnightUISettings.MainTankFrames.scale == nil then MidnightUISettings.MainTankFrames.scale = config.scale end
end

local function ApplyMainTankFramePosition(frame, index)
    if not frame then return end
    EnsureMainTankSettings()
    local saved = MidnightUISettings.MainTankFrames.frames[index]
    if saved and saved.position and #saved.position >= 4 then
        frame:ClearAllPoints()
        frame:SetPoint(saved.position[1], UIParent, saved.position[2], saved.position[3], saved.position[4])
        return
    end
    -- Default layout uses anchor stacking.
    frame:ClearAllPoints()
    if index == 1 then
        frame:SetPoint("TOPLEFT", MainTankAnchor, "TOPLEFT", 0, 0)
    else
        frame:SetPoint("TOPLEFT", MainTankFrames[index - 1], "BOTTOMLEFT", 0, -config.spacing)
    end
end

local function ApplyMainTankSettings()
    EnsureMainTankSettings()
    local s = MidnightUISettings.MainTankFrames
    config.width = s.width or config.width
    config.height = s.height or config.height
    config.spacing = s.spacing or config.spacing
    config.scale = s.scale or config.scale
    config.healthHeight, config.powerHeight = ComputeMainTankBarHeights(config.height)

    if MainTankAnchor then
        MainTankAnchor:SetSize(config.width, (config.height * 2) + config.spacing)
        MainTankAnchor:SetScale(config.scale or 1.0)
    end

    for i = 1, 2 do
        local frame = MainTankFrames[i]
        if frame then
            frame:SetSize(config.width, config.height)
            if frame.portrait then
                local ps = config.height - 2
                frame.portrait:SetSize(ps, ps)
            end
            LayoutMainTankBarContainers(frame)
            ApplyMainTankFramePosition(frame, i)
        end
    end
end
_G.MidnightUI_ApplyMainTankSettings = ApplyMainTankSettings

local function CreateSingleMainTankFrame(index)
    EnsureMainTankAnchor()
    local frameName = "MidnightUI_MainTankFrame" .. index
    local frame = CreateFrame("Button", frameName, MainTankAnchor, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(config.width, config.height)
    frame:SetAttribute("unit", "none")
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")

    RegisterUnitWatch(frame)

    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame:SetBackdropBorderColor(0, 0, 0, 1)

    frame.shadows = CreateDropShadow(frame, 3)

    local portraitSize = config.height - 2
    local portrait = frame:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(portraitSize, portraitSize)
    portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
    portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.portrait = portrait

    portrait.sep = frame:CreateTexture(nil, "OVERLAY")
    portrait.sep:SetWidth(1)
    portrait.sep:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 0, 0)
    portrait.sep:SetPoint("BOTTOMLEFT", portrait, "BOTTOMRIGHT", 0, 0)
    portrait.sep:SetColorTexture(0, 0, 0, 1)

    local barFrame = CreateFrame("Frame", nil, frame)
    barFrame:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 1, -1)
    barFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    barFrame:SetClipsChildren(true)
    frame.barFrame = barFrame

    local healthContainer = CreateFrame("Frame", nil, barFrame)
    frame.healthContainer = healthContainer

    local powerContainer = CreateFrame("Frame", nil, barFrame)
    frame.powerContainer = powerContainer
    LayoutMainTankBarContainers(frame)

    local pSep = powerContainer:CreateTexture(nil, "OVERLAY", nil, 7)
    pSep:SetHeight(MAIN_TANK_BAR_DIVIDER_THICKNESS)
    pSep:SetPoint("TOPLEFT")
    pSep:SetPoint("TOPRIGHT")
    pSep:SetColorTexture(0, 0, 0, 1)
    frame.powerSep = pSep

    local healthBg = healthContainer:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints(healthContainer)
    healthBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.healthBg = healthBg

    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetAllPoints(healthContainer)
    healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    SetMainTankBarColor(healthBar, 0.5, 0.5, 0.5, 0.92)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(1)
    frame.healthBar = healthBar

    local powerBg = powerContainer:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints(powerContainer)
    powerBg:SetColorTexture(0.08, 0.08, 0.08, 1)
    frame.powerBg = powerBg

    local powerBar = CreateFrame("StatusBar", nil, powerContainer)
    powerBar:SetAllPoints(powerContainer)
    powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    SetMainTankBarColor(powerBar, 0.2, 0.2, 0.2, 0.8)
    powerBar:SetMinMaxValues(0, 1)
    powerBar:SetValue(0)
    frame.powerBar = powerBar

    local textFrame = CreateFrame("Frame", nil, frame)
    textFrame:SetAllPoints(healthBar)
    textFrame:SetFrameLevel(frame:GetFrameLevel() + 5)

    local nameText = textFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetPoint("LEFT", healthBar, "LEFT", 6, 0)
    nameText:SetJustifyH("LEFT")
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    nameText:SetTextColor(1, 1, 1)
    frame.nameText = nameText

    local healthText = textFrame:CreateFontString(nil, "OVERLAY")
    healthText:SetPoint("RIGHT", healthBar, "RIGHT", -6, 0)
    healthText:SetJustifyH("RIGHT")
    SetFontSafe(healthText, "Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    healthText:SetTextColor(0.9, 0.9, 0.9)
    frame.healthText = healthText

    local deadIcon = textFrame:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(32, 32)
    deadIcon:SetPoint("RIGHT", healthBar, "RIGHT", -28, 0)
    EnsureDeadIconTexture(deadIcon)
    deadIcon:SetVertexColor(1, 0.2, 0.2, 1)
    deadIcon:SetDrawLayer("OVERLAY", 7)
    deadIcon:SetAlpha(1)
    deadIcon:Hide()
    frame.deadIcon = deadIcon

    local roleIcon = frame:CreateTexture(nil, "OVERLAY")
    roleIcon:SetSize(20, 20)
    roleIcon:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", 2, -2)
    frame.roleIcon = roleIcon

    ApplyMainTankPlaceholder(frame, index)
    ApplyMainTankBarStyle(frame)

    ApplyMainTankFramePosition(frame, index)

    return frame
end

IsMainTankDebuffVisualsEnabled = function()
    return IsInRaid and IsInRaid()
end

local function SetMainTankIconTexCoord(texture, usingAtlas)
    if not texture or not texture.SetTexCoord then
        return
    end
    if usingAtlas then
        texture:SetTexCoord(0, 1, 0, 1)
    else
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function EnsureMainTankDebuffPreviewWidgets(frame)
    if not frame then
        return nil
    end
    if frame._muiMainTankDebuffPreview then
        return frame._muiMainTankDebuffPreview
    end

    local preview = {}

    local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", -1, 1)
    overlay:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 1, -1)
    overlay:SetFrameStrata(frame:GetFrameStrata())
    overlay:SetFrameLevel(frame:GetFrameLevel() + 25)
    overlay:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    overlay:SetBackdropBorderColor(0, 0, 0, 0)
    overlay:EnableMouse(false)
    overlay:Hide()

    local fill = overlay:CreateTexture(nil, "BACKGROUND", nil, 1)
    fill:SetAllPoints(overlay)
    fill:SetTexture("Interface\\Buttons\\WHITE8X8")
    fill:SetVertexColor(0, 0, 0, 0)
    overlay.fill = fill

    -- Match PlayerFrame active-debuff border styling: tactical corner brackets.
    local bracketFrame = CreateFrame("Frame", nil, overlay)
    bracketFrame:SetAllPoints(overlay)
    bracketFrame:SetFrameLevel(overlay:GetFrameLevel() + 2)
    bracketFrame:SetAlpha(0.56)
    bracketFrame:Hide()

    local brackets = {}
    local B_THICK = 2
    local B_LEN = 12
    local OFFSET = 2
    local function AddBracket(point, x, y, w, h)
        local t = bracketFrame:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        t:SetPoint(point, x, y)
        t:SetSize(w, h)
        brackets[#brackets + 1] = t
    end
    AddBracket("TOPLEFT", -OFFSET, OFFSET, B_LEN, B_THICK)
    AddBracket("TOPLEFT", -OFFSET, OFFSET, B_THICK, B_LEN)
    AddBracket("TOPRIGHT", OFFSET, OFFSET, B_LEN, B_THICK)
    AddBracket("TOPRIGHT", OFFSET, OFFSET, B_THICK, B_LEN)
    AddBracket("BOTTOMLEFT", -OFFSET, -OFFSET, B_LEN, B_THICK)
    AddBracket("BOTTOMLEFT", -OFFSET, -OFFSET, B_THICK, B_LEN)
    AddBracket("BOTTOMRIGHT", OFFSET, -OFFSET, B_LEN, B_THICK)
    AddBracket("BOTTOMRIGHT", OFFSET, -OFFSET, B_THICK, B_LEN)
    overlay.brackets = brackets
    overlay.bracketFrame = bracketFrame

    local bracketPulse = bracketFrame:CreateAnimationGroup()
    bracketPulse:SetLooping("BOUNCE")
    local bAlpha = bracketPulse:CreateAnimation("Alpha")
    bAlpha:SetFromAlpha(0.52)
    bAlpha:SetToAlpha(0.62)
    bAlpha:SetDuration(1.80)
    bAlpha:SetSmoothing("IN_OUT")
    overlay.bracketPulse = bracketPulse

    local secondary = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    secondary:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    secondary:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    secondary:SetFrameStrata(frame:GetFrameStrata())
    secondary:SetFrameLevel(frame:GetFrameLevel() + 26)
    secondary:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    secondary:SetBackdropBorderColor(0, 0, 0, 0)
    secondary:EnableMouse(false)
    secondary:Hide()

    local sweep = CreateFrame("Frame", nil, overlay)
    sweep:SetAllPoints(overlay)
    sweep:SetFrameLevel(overlay:GetFrameLevel() + 6)
    sweep:EnableMouse(false)
    sweep:SetClipsChildren(true)
    sweep:Hide()

    local sweepFx = CreateFrame("Frame", nil, sweep)
    sweepFx:SetSize(72, 128)
    sweepFx:SetPoint("CENTER", sweep, "LEFT", -72, 0)

    local function CreateSweepBand(isReverse)
        local tex = sweepFx:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("TOP", sweepFx, "TOP", 0, 0)
        tex:SetPoint("BOTTOM", sweepFx, "BOTTOM", 0, 0)
        tex:SetWidth(18)
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        tex:SetBlendMode("ADD")
        if tex.SetGradientAlpha then
            if isReverse then
                tex:SetGradientAlpha("HORIZONTAL", 1, 1, 1, 1.00, 1, 1, 1, 0.00)
            else
                tex:SetGradientAlpha("HORIZONTAL", 1, 1, 1, 0.00, 1, 1, 1, 1.00)
            end
        end
        if tex.SetRotation then
            tex:SetRotation(-0.33)
        end
        return tex
    end

    local sweepBands = {}
    for i = 1, 7 do
        sweepBands[i] = {
            a = CreateSweepBand(false),
            b = CreateSweepBand(true),
        }
    end

    local sweepMoveGroup = sweepFx:CreateAnimationGroup()
    sweepMoveGroup:SetLooping("REPEAT")
    local sweepMoveAnim = sweepMoveGroup:CreateAnimation("Translation")
    sweepMoveAnim:SetOffset(180, 0)
    sweepMoveAnim:SetDuration(1.12)
    sweepMoveAnim:SetSmoothing("IN_OUT")

    local iconHolder = CreateFrame("Frame", nil, frame)
    iconHolder:SetFrameStrata(frame:GetFrameStrata())
    iconHolder:SetFrameLevel(frame:GetFrameLevel() + 30)
    iconHolder:SetPoint("RIGHT", frame, "RIGHT", -2, MAIN_TANK_DEBUFF_PREVIEW.offsetY)
    iconHolder:SetSize((MAIN_TANK_DEBUFF_PREVIEW.iconSize + 2) * MAIN_TANK_DEBUFF_PREVIEW.maxIcons, MAIN_TANK_DEBUFF_PREVIEW.iconSize + 2)
    iconHolder:Hide()

    local function CreateIconButton(index)
        local btn = CreateFrame("Frame", nil, iconHolder, "BackdropTemplate")
        btn:SetSize(MAIN_TANK_DEBUFF_PREVIEW.iconSize, MAIN_TANK_DEBUFF_PREVIEW.iconSize)
        btn:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 0, right = 0, top = 0, bottom = 0 },
        })
        btn:SetBackdropColor(0, 0, 0, 0.75)
        btn:SetBackdropBorderColor(0.70, 0.70, 0.70, 1)

        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetPoint("TOPLEFT", 1, -1)
        icon:SetPoint("BOTTOMRIGHT", -1, 1)
        SetMainTankIconTexCoord(icon, false)
        btn.icon = icon

        local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
        count:SetJustifyH("RIGHT")
        count:SetTextColor(1, 1, 1, 1)
        btn.countText = count
        btn._muiIndex = index

        btn:EnableMouse(true)
        btn:SetScript("OnEnter", function(self)
            if not GameTooltip then
                return
            end
            local unitToken = self._muiUnit
            if type(unitToken) ~= "string" or not UnitExists(unitToken) then
                return
            end
            if not self.auraInstanceID and not self.auraIndex then
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if GameTooltip.ClearLines then
                GameTooltip:ClearLines()
            end

            local shown = false
            local function TooltipHasLines()
                if not GameTooltip or type(GameTooltip.NumLines) ~= "function" then
                    return false
                end
                local okLines, lines = pcall(GameTooltip.NumLines, GameTooltip)
                return okLines and type(lines) == "number" and lines > 0
            end
            local function MarkShown(okCall, result)
                if not okCall then
                    return false
                end
                if result ~= nil then
                    return result and true or false
                end
                return TooltipHasLines()
            end

            if self.auraInstanceID and GameTooltip.SetUnitDebuffByAuraInstanceID then
                local okAura, result = pcall(GameTooltip.SetUnitDebuffByAuraInstanceID, GameTooltip, unitToken, self.auraInstanceID)
                shown = MarkShown(okAura, result)
            end
            if (not shown) and self.auraInstanceID and GameTooltip.SetUnitAuraByAuraInstanceID then
                local okAura, result = pcall(GameTooltip.SetUnitAuraByAuraInstanceID, GameTooltip, unitToken, self.auraInstanceID)
                shown = MarkShown(okAura, result)
            end
            if (not shown) and self.auraIndex and GameTooltip.SetUnitAura then
                local okAura, result = pcall(GameTooltip.SetUnitAura, GameTooltip, unitToken, self.auraIndex, "HARMFUL")
                shown = MarkShown(okAura, result)
            end
            if (not shown) and self.auraIndex and GameTooltip.SetUnitDebuff then
                local okLegacy, result = pcall(GameTooltip.SetUnitDebuff, GameTooltip, unitToken, self.auraIndex)
                shown = MarkShown(okLegacy, result)
            end
            if shown then
                GameTooltip:Show()
            else
                GameTooltip:Hide()
            end
        end)
        btn:SetScript("OnLeave", function()
            if GameTooltip then
                GameTooltip:Hide()
            end
        end)
        return btn
    end

    local iconButtons = {}
    for i = 1, MAIN_TANK_DEBUFF_PREVIEW.maxIcons do
        local btn = CreateIconButton(i)
        btn:SetPoint("RIGHT", iconHolder, "RIGHT", -((i - 1) * (MAIN_TANK_DEBUFF_PREVIEW.iconSize + 2)), 0)
        btn:Hide()
        iconButtons[i] = btn
    end

    preview.overlay = overlay
    preview.secondary = secondary
    preview.sweep = sweep
    preview.sweepFx = sweepFx
    preview.sweepBands = sweepBands
    preview.sweepMoveGroup = sweepMoveGroup
    preview.sweepMoveAnim = sweepMoveAnim
    preview.sweepLayoutKey = nil
    preview.iconHolder = iconHolder
    preview.iconButtons = iconButtons
    preview._muiCreateIconButton = CreateIconButton
    frame._muiMainTankDebuffPreview = preview
    return preview
end

local function SetMainTankHPTextInset(frame, inset)
    if not frame or not frame.healthText then
        return
    end
    local value = tonumber(inset) or 0
    if value < 0 then
        value = 0
    end
    value = math.floor(value + 0.5)
    if frame._muiMainTankHpTextInset == value then
        return
    end
    frame._muiMainTankHpTextInset = value
    frame.healthText:ClearAllPoints()
    frame.healthText:SetPoint("RIGHT", frame.healthBar, "RIGHT", -6 - value, 0)
end

local function GetMainTankFrameClassColor(frame, unit)
    if frame and type(frame._muiClassColor) == "table" then
        local r = CoerceMainTankTintChannel(frame._muiClassColor.r or frame._muiClassColor[1])
        local g = CoerceMainTankTintChannel(frame._muiClassColor.g or frame._muiClassColor[2])
        local b = CoerceMainTankTintChannel(frame._muiClassColor.b or frame._muiClassColor[3])
        if r ~= nil and g ~= nil and b ~= nil then
            return r, g, b
        end
    end

    local _, class = UnitClass(unit)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.ClassColorsExact and class and _G.MidnightUI_Core.ClassColorsExact[class] then
        local c = _G.MidnightUI_Core.ClassColorsExact[class]
        return CoerceMainTankTintChannel(c.r) or 0.5, CoerceMainTankTintChannel(c.g) or 0.5, CoerceMainTankTintChannel(c.b) or 0.5
    elseif class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return CoerceMainTankTintChannel(c.r) or 0.5, CoerceMainTankTintChannel(c.g) or 0.5, CoerceMainTankTintChannel(c.b) or 0.5
    end
    return 0.5, 0.5, 0.5
end

local function RestoreMainTankHealthBarBaseState(frame, unit)
    if not frame or not frame.healthBar or not frame.healthBar:IsShown() then
        return
    end

    local classR, classG, classB = GetMainTankFrameClassColor(frame, unit)
    local connected = UnitIsConnected(unit)
    local dead = IsUnitActuallyDead(unit)
    local incomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit)
    local barR, barG, barB, alpha

    if not connected then
        barR, barG, barB, alpha = 0.15, 0.15, 0.15, 0.6
        if frame.healthBg and frame.healthBg.SetColorTexture then
            frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
        end
    elseif dead and not incomingRes then
        barR, barG, barB, alpha = classR * 0.2, classG * 0.2, classB * 0.2, 0.7
        if frame.healthBg and frame.healthBg.SetColorTexture then
            frame.healthBg:SetColorTexture(0.1, 0.02, 0.02, 0.9)
        end
    else
        if incomingRes then
            classR, classG, classB = classR * 1.2, classG * 1.2, classB * 1.2
        end
        barR, barG, barB, alpha = classR, classG, classB, 0.92
        if frame.healthBg and frame.healthBg.SetColorTexture then
            local bgR, bgG, bgB = classR, classG, classB
            if incomingRes then
                bgR, bgG, bgB = bgR / 1.2, bgG / 1.2, bgB / 1.2
            end
            frame.healthBg:SetColorTexture(bgR * 0.12, bgG * 0.12, bgB * 0.12, 0.6)
        end
    end

    SetMainTankBarColor(frame.healthBar, barR, barG, barB, alpha)
    local tex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
    if tex and tex.SetVertexColor then
        tex:SetVertexColor(barR, barG, barB, 1.0)
    end
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    if style == "Gradient" then
        ApplyPolishedGradientToBar(frame.healthBar, tex, 0.28, 0.035, 0.32)
    else
        HidePolishedGradientOnBar(frame.healthBar)
    end
    SetMainTankRenderedSecretPolish(frame.healthBar, false)
end

local function RestoreMainTankPowerBarBaseState(frame, unit)
    if not frame or not frame.powerBar or not frame.powerBar:IsShown() then
        return
    end

    local dead = IsUnitActuallyDead(unit)
    local incomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit)
    local barR, barG, barB, alpha

    if not dead then
        local _, powerToken = UnitPowerType(unit)
        local pColor = POWER_COLORS[powerToken] or DEFAULT_POWER_COLOR
        if incomingRes then
            barR, barG, barB, alpha = pColor[1] * 1.2, pColor[2] * 1.2, pColor[3] * 1.2, 0.8
        else
            barR, barG, barB, alpha = pColor[1], pColor[2], pColor[3], 1.0
        end
    else
        barR, barG, barB, alpha = 0.2, 0.2, 0.2, 0.5
    end

    SetMainTankBarColor(frame.powerBar, barR, barG, barB, alpha)
    local tex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
    if tex and tex.SetVertexColor then
        tex:SetVertexColor(barR, barG, barB, 1.0)
    end

    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    if style == "Gradient" then
        ApplyPolishedGradientToBar(frame.powerBar, tex, 0.24, 0.03, 0.28)
    else
        HidePolishedGradientOnBar(frame.powerBar)
    end
    SetMainTankRenderedSecretPolish(frame.powerBar, false)
end

ClearMainTankDebuffPreviewForFrame = function(frame)
    if not frame or not frame._muiMainTankDebuffPreview then
        return
    end
    local preview = frame._muiMainTankDebuffPreview
    if preview.overlay then
        preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
        if preview.overlay.fill then
            preview.overlay.fill:SetVertexColor(0, 0, 0, 0)
        end
        if preview.overlay.bracketPulse and preview.overlay.bracketPulse.IsPlaying and preview.overlay.bracketPulse:IsPlaying() then
            preview.overlay.bracketPulse:Stop()
        end
        if preview.overlay.bracketFrame then
            preview.overlay.bracketFrame:SetAlpha(0.56)
            preview.overlay.bracketFrame:Hide()
        end
        preview.overlay:Hide()
    end
    if preview.secondary then
        preview.secondary:SetBackdropBorderColor(0, 0, 0, 0)
        preview.secondary:Hide()
    end
    if preview.sweepMoveGroup and preview.sweepMoveGroup:IsPlaying() then
        preview.sweepMoveGroup:Stop()
    end
    if preview.sweep then
        preview.sweep:Hide()
    end
    if preview.iconButtons then
        for _, btn in ipairs(preview.iconButtons) do
            btn._muiUnit = nil
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            if btn.countText then
                btn.countText:SetText("")
            end
            btn:Hide()
        end
    end
    if preview.iconHolder then
        preview.iconHolder:Hide()
    end
    SetMainTankHPTextInset(frame, 0)

    local unit = frame.GetAttribute and frame:GetAttribute("unit")
    if type(unit) == "string" and UnitExists(unit) then
        RestoreMainTankHealthBarBaseState(frame, unit)
        RestoreMainTankPowerBarBaseState(frame, unit)
    end
end

local function LayoutMainTankDebuffSweep(preview, frame)
    if not preview or not frame or not preview.sweep or not preview.sweepFx then
        return
    end
    preview.sweep:ClearAllPoints()
    preview.sweep:SetAllPoints(preview.overlay or frame)

    local width = tonumber(frame:GetWidth()) or 0
    local height = tonumber(frame:GetHeight()) or 0
    if width <= 1 then
        width = tonumber(config.width) or 260
    end
    if height <= 1 then
        height = tonumber(config.height) or 58
    end

    local beamW = math.max(math.floor(width * 0.32 + 0.5), 56)
    local beamH = math.max(math.floor(height * 2.55 + 0.5), 110)
    local moveDistance = width + (beamW * 2.95)
    local duration = 1.12
    local layoutKey = tostring(math.floor(width + 0.5))
        .. "x" .. tostring(math.floor(height + 0.5))
        .. ":" .. tostring(beamW)
        .. ":" .. tostring(beamH)
    if preview.sweepLayoutKey == layoutKey then
        return
    end
    preview.sweepLayoutKey = layoutKey

    preview.sweepFx:ClearAllPoints()
    preview.sweepFx:SetSize(beamW, beamH)
    preview.sweepFx:SetPoint("CENTER", preview.sweep, "LEFT", -beamW, 0)

    local bandWidths = {
        math.max(math.floor(beamW * 1.18 + 0.5), 30),
        beamW,
        math.max(math.floor(beamW * 0.84 + 0.5), 26),
        math.max(math.floor(beamW * 0.68 + 0.5), 20),
        math.max(math.floor(beamW * 0.54 + 0.5), 16),
        math.max(math.floor(beamW * 0.40 + 0.5), 12),
        math.max(math.floor(beamW * 0.28 + 0.5), 8),
    }
    if preview.sweepBands then
        for i, pair in ipairs(preview.sweepBands) do
            local w = bandWidths[i] or beamW
            if pair.a then
                pair.a:ClearAllPoints()
                pair.a:SetPoint("TOP", preview.sweepFx, "TOP", 0, 0)
                pair.a:SetPoint("BOTTOM", preview.sweepFx, "BOTTOM", 0, 0)
                pair.a:SetWidth(w)
            end
            if pair.b then
                pair.b:ClearAllPoints()
                pair.b:SetPoint("TOP", preview.sweepFx, "TOP", 0, 0)
                pair.b:SetPoint("BOTTOM", preview.sweepFx, "BOTTOM", 0, 0)
                pair.b:SetWidth(w)
            end
        end
    end

    if preview.sweepMoveAnim then
        preview.sweepMoveAnim:SetOffset(moveDistance, 0)
        preview.sweepMoveAnim:SetDuration(duration)
        preview.sweepMoveAnim:SetSmoothing("IN_OUT")
    end
    if preview.sweepMoveGroup and preview.sweepMoveGroup:IsPlaying() then
        preview.sweepMoveGroup:Stop()
        preview.sweepMoveGroup:Play()
    end
end

local function SetMainTankDebuffSweepColor(preview, enum, overrideColor)
    if not preview or not preview.sweepBands then
        return
    end
    local color = overrideColor
    if type(color) ~= "table" then
        color = GetMainTankHazardColor(enum) or MAIN_TANK_HAZARD_COLORS[MAIN_TANK_HAZARD_ENUM.Unknown]
    end
    if not color then
        return
    end
    local normalized = NormalizeMainTankHazardEnum(enum)
    local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
    if IsMainTankSecretColor(color) then
        bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
    elseif normalized == MAIN_TANK_HAZARD_ENUM.Unknown then
        bandAlpha = { 0.014, 0.022, 0.032, 0.045, 0.062, 0.084, 0.112 }
    end
    for i, pair in ipairs(preview.sweepBands) do
        local alpha = bandAlpha[i] or bandAlpha[#bandAlpha]
        if pair.a then
            pair.a:SetVertexColor(color[1], color[2], color[3], alpha)
        end
        if pair.b then
            pair.b:SetVertexColor(color[1], color[2], color[3], alpha)
        end
    end
end

local function SetMainTankDebuffSweepVisible(preview, isVisible)
    if not preview or not preview.sweep then
        return
    end
    if isVisible then
        preview.sweep:Show()
        if preview.sweepMoveGroup and not preview.sweepMoveGroup:IsPlaying() then
            preview.sweepMoveGroup:Play()
        end
    else
        if preview.sweepMoveGroup and preview.sweepMoveGroup:IsPlaying() then
            preview.sweepMoveGroup:Stop()
        end
        preview.sweep:Hide()
    end
end

local function CollectMainTankDebuffPreviewState(unit)
    local state = {
        unit = tostring(unit or "nil"),
        inRestricted = (InCombatLockdown and InCombatLockdown()) and "YES" or "NO",
        primary = nil,
        secondary = nil,
        entries = {},
        scanned = 0,
        typed = 0,
        curveHits = 0,
        iconHits = 0,
        placeholderHits = 0,
        blizzAvail = "NO",
        blizzDebuffs = 0,
        blizzDispellable = 0,
        sweep = "OFF",
        sweepSource = "none",
        sweepRGB = "none",
    }
    local inRestricted = (state.inRestricted == "YES")
    local seenHazards = {}
    local seenEntryByIID = {}

    local blizzEntry = _mainTankBlizzAuraCache[unit]
    if type(blizzEntry) == "table" then
        if type(blizzEntry.debuffs) ~= "table" then blizzEntry.debuffs = {} end
        if type(blizzEntry.dispellable) ~= "table" then blizzEntry.dispellable = {} end
        if type(blizzEntry.types) ~= "table" then blizzEntry.types = {} end
        if type(blizzEntry.icons) ~= "table" then blizzEntry.icons = {} end
        if type(blizzEntry.stacks) ~= "table" then blizzEntry.stacks = {} end
        state.blizzAvail = "YES"
        state.blizzDebuffs = CountMainTankBlizzAuraSet(blizzEntry.debuffs)
        state.blizzDispellable = CountMainTankBlizzAuraSet(blizzEntry.dispellable)
    else
        blizzEntry = nil
    end

    local function AddHazard(enum)
        local normalized = NormalizeMainTankHazardEnum(enum)
        if not normalized or normalized == MAIN_TANK_HAZARD_ENUM.Unknown then
            return
        end
        if seenHazards[normalized] then
            return
        end
        seenHazards[normalized] = true
        if not state.primary then
            state.primary = normalized
        elseif not state.secondary and normalized ~= state.primary then
            state.secondary = normalized
        end
    end

    local function RecordTyped(source)
        state.typed = state.typed + 1
        if source == "curve" or source == "blizz:curve" then
            state.curveHits = state.curveHits + 1
        end
    end

    local function ReadAuraByIID(auraIID)
        if not auraIID or not C_UnitAuras or not C_UnitAuras.GetAuraDataByAuraInstanceID then
            return nil
        end
        if inRestricted then
            local okAura, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraIID)
            if okAura then
                return auraData
            end
            return nil
        end
        return C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraIID)
    end

    local function AddEntry(iconToken, enum, auraIID, auraIndex, stackCount)
        local hasIcon = CanUseMainTankIconToken(iconToken)
        if hasIcon then
            state.iconHits = state.iconHits + 1
        end
        local dynMax = (GetMainTankDebuffSettings())
        if (#state.entries < dynMax) and (hasIcon or enum) then
            state.entries[#state.entries + 1] = {
                icon = hasIcon and iconToken or nil,
                enum = NormalizeMainTankHazardEnum(enum),
                auraInstanceID = auraIID,
                auraIndex = auraIndex,
                stackCount = stackCount,
            }
            if not hasIcon then
                state.placeholderHits = state.placeholderHits + 1
            end
        end
        if auraIID then
            seenEntryByIID[auraIID] = true
        end
    end

    local function ResolveAuraTypeFromCache(auraIID)
        if not auraIID or not blizzEntry then
            return nil, nil
        end
        local hint = blizzEntry.types and blizzEntry.types[auraIID] or nil
        return ResolveMainTankHazardFromAuraInstanceID(unit, auraIID, hint)
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            local aura = nil
            if inRestricted then
                local okAura, auraData = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
                if not okAura then
                    break
                end
                aura = auraData
            else
                aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            end
            if not aura then
                break
            end

            state.scanned = state.scanned + 1
            local auraIID = aura.auraInstanceID
            local enum, source = ResolveMainTankHazardFromAura(unit, aura)
            if (not enum or enum == MAIN_TANK_HAZARD_ENUM.Unknown) and auraIID then
                enum, source = ResolveAuraTypeFromCache(auraIID)
            end
            if enum and enum ~= MAIN_TANK_HAZARD_ENUM.Unknown then
                RecordTyped(source)
                AddHazard(enum)
            end

            local iconToken = aura.icon or aura.iconFileID
            local hasIcon = CanUseMainTankIconToken(iconToken)
            local stackCount = aura.applications or aura.stackCount or aura.charges
            if (stackCount == nil) and blizzEntry and auraIID then
                stackCount = blizzEntry.stacks and blizzEntry.stacks[auraIID] or nil
            end

            if (not hasIcon) and blizzEntry and auraIID then
                local cachedIcon = blizzEntry.icons and blizzEntry.icons[auraIID] or nil
                if CanUseMainTankIconToken(cachedIcon) then
                    iconToken = cachedIcon
                    hasIcon = true
                end
            end
            if (not hasIcon) and auraIID and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local fallbackAura = ReadAuraByIID(auraIID)
                if fallbackAura then
                    iconToken = fallbackAura.icon or fallbackAura.iconFileID
                    hasIcon = CanUseMainTankIconToken(iconToken)
                    if stackCount == nil then
                        stackCount = fallbackAura.applications or fallbackAura.stackCount or fallbackAura.charges
                    end
                end
            end

            AddEntry(iconToken, enum, auraIID, i, stackCount)
        end
    end

    if blizzEntry then
        local function AddFromAuraSet(auraSet)
            if type(auraSet) ~= "table" then
                return
            end
            for auraIID in pairs(auraSet) do
                if not seenEntryByIID[auraIID] then
                    local enum, source = ResolveAuraTypeFromCache(auraIID)
                    if enum and enum ~= MAIN_TANK_HAZARD_ENUM.Unknown then
                        RecordTyped(source)
                        AddHazard(enum)
                    end

                    local iconToken = blizzEntry.icons and blizzEntry.icons[auraIID] or nil
                    local stackCount = blizzEntry.stacks and blizzEntry.stacks[auraIID] or nil
                    if (not CanUseMainTankIconToken(iconToken)) then
                        local fallbackAura = ReadAuraByIID(auraIID)
                        if fallbackAura then
                            iconToken = fallbackAura.icon or fallbackAura.iconFileID
                            if stackCount == nil then
                                stackCount = fallbackAura.applications or fallbackAura.stackCount or fallbackAura.charges
                            end
                        end
                    end

                    AddEntry(iconToken, enum, auraIID, nil, stackCount)
                end
            end
        end
        AddFromAuraSet(blizzEntry.dispellable)
        AddFromAuraSet(blizzEntry.debuffs)
    end

    if not state.primary and #state.entries > 0 then
        for _, entry in ipairs(state.entries) do
            if entry.enum and entry.enum ~= MAIN_TANK_HAZARD_ENUM.Unknown then
                state.primary = entry.enum
                break
            end
        end
    end
    if not state.primary and #state.entries > 0 then
        state.primary = MAIN_TANK_HAZARD_ENUM.Unknown
    end
    if not state.secondary and #state.entries > 1 then
        state.secondary = MAIN_TANK_HAZARD_ENUM.Unknown
    end
    return state
end

local function GetMainTankDebuffNow()
    if type(GetTime) == "function" then
        local okNow, now = pcall(GetTime)
        if okNow and type(now) == "number" then
            return now
        end
    end
    return 0
end

local function ApplyMainTankStickyHazardFallback(frame, primaryEnum, secondaryEnum, primaryColor, inRestricted, holdStickyForUnknown)
    local normalizedPrimary = NormalizeMainTankHazardEnum(primaryEnum)
    local normalizedSecondary = NormalizeMainTankHazardEnum(secondaryEnum)
    if normalizedSecondary == normalizedPrimary then
        normalizedSecondary = nil
    end

    local resolvedPrimaryColor = CloneMainTankColor(primaryColor)
    local now = GetMainTankDebuffNow()

    if normalizedPrimary and normalizedPrimary ~= MAIN_TANK_HAZARD_ENUM.Unknown then
        frame._muiMainTankStickyPrimary = normalizedPrimary
        frame._muiMainTankStickySecondary = (normalizedSecondary and normalizedSecondary ~= MAIN_TANK_HAZARD_ENUM.Unknown) and normalizedSecondary or nil
        frame._muiMainTankStickyAt = now
        if not resolvedPrimaryColor then
            resolvedPrimaryColor = CloneMainTankColor(MAIN_TANK_HAZARD_COLORS[normalizedPrimary])
        end
        frame._muiMainTankStickyPrimaryColor = CloneMainTankColor(resolvedPrimaryColor)
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
    end

    local stickyPrimary = NormalizeMainTankHazardEnum(frame._muiMainTankStickyPrimary)
    local stickySecondary = NormalizeMainTankHazardEnum(frame._muiMainTankStickySecondary)
    local stickyColor = CloneMainTankColor(frame._muiMainTankStickyPrimaryColor)
    local stickyAt = tonumber(frame._muiMainTankStickyAt) or 0
    local stickyFresh = stickyPrimary
        and now > 0
        and stickyAt > 0
        and (now - stickyAt) <= MAIN_TANK_HAZARD_STICKY_SEC

    if stickyPrimary and (stickyFresh or holdStickyForUnknown) then
        if (not normalizedPrimary) or normalizedPrimary == MAIN_TANK_HAZARD_ENUM.Unknown then
            normalizedPrimary = stickyPrimary
            resolvedPrimaryColor = stickyColor or resolvedPrimaryColor
        end
        if (not normalizedSecondary or normalizedSecondary == MAIN_TANK_HAZARD_ENUM.Unknown or normalizedSecondary == normalizedPrimary)
            and stickySecondary
            and stickySecondary ~= normalizedPrimary then
            normalizedSecondary = stickySecondary
        end
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, true
    end

    if (not inRestricted) and (not holdStickyForUnknown) and ((not normalizedPrimary) or normalizedPrimary == MAIN_TANK_HAZARD_ENUM.Unknown) then
        frame._muiMainTankStickyPrimary = nil
        frame._muiMainTankStickySecondary = nil
        frame._muiMainTankStickyAt = nil
        frame._muiMainTankStickyPrimaryColor = nil
    end

    return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
end

local function FormatMainTankEntryForDiag(entry, index)
    if type(entry) ~= "table" then
        return nil
    end
    local enumLabel = GetMainTankHazardLabel(entry.enum)
    local iconKind = MainTankIconKind(entry.icon)
    local iid = entry.auraInstanceID
    local iidLabel = (iid ~= nil) and tostring(iid) or "nil"
    return "e" .. tostring(index) .. "=" .. enumLabel .. "/" .. iconKind .. "/iid=" .. iidLabel
end

local function BuildMainTankLiveDiagMessage(state, source)
    local parts = {
        "live unit=" .. tostring(state and state.unit or "nil"),
        "restricted=" .. tostring(state and state.inRestricted or "NO"),
        "primary=" .. GetMainTankHazardLabel(state and state.primary),
        "secondary=" .. GetMainTankHazardLabel(state and state.secondary),
        "scanned=" .. tostring((state and state.scanned) or 0),
        "typed=" .. tostring((state and state.typed) or 0),
        "curve=" .. tostring((state and state.curveHits) or 0),
        "blizz=" .. tostring((state and state.blizzAvail) or "NO"),
        "blizzDebuffs=" .. tostring((state and state.blizzDebuffs) or 0),
        "blizzDispellable=" .. tostring((state and state.blizzDispellable) or 0),
        "sweep=" .. tostring((state and state.sweep) or "OFF"),
        "sweepSrc=" .. tostring((state and state.sweepSource) or "none"),
        "sweepRGB=" .. tostring((state and state.sweepRGB) or "none"),
        "icons=" .. tostring((state and state.iconHits) or 0),
        "placeholder=" .. tostring((state and state.placeholderHits) or 0),
        "src=" .. tostring(source or "unknown"),
    }
    if state and type(state.entries) == "table" then
        for i = 1, math.min(#state.entries, 2) do
            local token = FormatMainTankEntryForDiag(state.entries[i], i)
            if token then
                parts[#parts + 1] = token
            end
        end
    end
    return table.concat(parts, " ")
end

local function ApplyMainTankDebuffPreviewState(frame, state)
    if not frame then
        return
    end
    local preview = EnsureMainTankDebuffPreviewWidgets(frame)
    if not preview then
        return
    end
    local unit = frame:GetAttribute("unit")
    if type(unit) ~= "string" or not UnitExists(unit) then
        ClearMainTankDebuffPreviewForFrame(frame)
        return
    end

    local primary = state and state.primary or nil
    local secondary = state and state.secondary or nil
    local entries = (state and type(state.entries) == "table") and state.entries or nil
    local overlapCount = (type(entries) == "table") and #entries or 0
    local promotedSource = nil
    local promotedR, promotedG, promotedB = nil, nil, nil
    local promotedSecretColor = nil
    local promotedSecondaryColor = nil

    if not primary and overlapCount > 0 then
        primary = MAIN_TANK_HAZARD_ENUM.Unknown
        promotedSource = "icon-only-entry"
    end
    if (not secondary) and overlapCount > 1 and (not promotedSource) then
        promotedSource = "icon-only-overlap"
    end
    if (not primary) or primary == MAIN_TANK_HAZARD_ENUM.Unknown then
        local hintEnum, hintR, hintG, hintB, hintSource, hintSecretColor, hintSecondaryEnum, hintSecondaryColor = GetMainTankHazardHintFromConditionBorder(unit)
        if hintEnum then
            primary = hintEnum
            promotedR, promotedG, promotedB = hintR, hintG, hintB
            promotedSecretColor = hintSecretColor
            promotedSource = hintSource or "condborder-fallback"
        end
        if (not secondary) and hintSecondaryEnum then
            secondary = hintSecondaryEnum
        end
        if type(hintSecondaryColor) == "table" then
            promotedSecondaryColor = CloneMainTankColor(hintSecondaryColor) or hintSecondaryColor
        end
    end

    local inRestricted = (type(state) == "table" and state.inRestricted == "YES")
    local holdStickyForUnknown = inRestricted
        and (type(promotedSource) == "string")
        and (string.find(promotedSource, "unknown", 1, true) ~= nil)
    local stickySeedColor = nil
    if type(promotedSecretColor) == "table" and promotedSecretColor.secret == true then
        stickySeedColor = promotedSecretColor
    elseif promotedR ~= nil and promotedG ~= nil and promotedB ~= nil then
        stickySeedColor = { promotedR, promotedG, promotedB }
    elseif primary and primary ~= MAIN_TANK_HAZARD_ENUM.Unknown then
        stickySeedColor = GetMainTankHazardColor(primary)
    end
    local stickyColor = nil
    local stickyApplied = false
    primary, secondary, stickyColor, stickyApplied = ApplyMainTankStickyHazardFallback(
        frame,
        primary,
        secondary,
        stickySeedColor,
        inRestricted,
        holdStickyForUnknown
    )
    if stickyApplied then
        if type(stickyColor) == "table" and stickyColor.secret == true then
            promotedSecretColor = stickyColor
            promotedR, promotedG, promotedB = nil, nil, nil
        elseif type(stickyColor) == "table" then
            promotedSecretColor = nil
            promotedR, promotedG, promotedB = stickyColor[1], stickyColor[2], stickyColor[3]
        end
        if promotedSource then
            promotedSource = promotedSource .. "+sticky"
        else
            promotedSource = "sticky"
        end
    end

    if type(state) == "table" then
        state.primary = primary
        state.secondary = secondary
        state.sticky = stickyApplied and "YES" or "NO"
    end

    if (not secondary) and overlapCount > 1 and (type(promotedSecondaryColor) ~= "table") then
        secondary = MAIN_TANK_HAZARD_ENUM.Unknown
        if type(state) == "table" then
            state.secondary = secondary
        end
    end

    local normalizedSecondary = NormalizeMainTankHazardEnum(secondary)
    local hasOverlap = (overlapCount > 1) or ((secondary ~= nil)
        and (secondary ~= primary)
        and (NormalizeMainTankHazardEnum(secondary) ~= MAIN_TANK_HAZARD_ENUM.Unknown))

    local primaryColor = nil
    local primarySecretColor = nil
    local primaryDisplayColor = nil
    if type(promotedSecretColor) == "table" and promotedSecretColor.secret == true then
        primarySecretColor = promotedSecretColor
    end
    if promotedR ~= nil and promotedG ~= nil and promotedB ~= nil then
        primaryColor = { promotedR, promotedG, promotedB }
    elseif not primarySecretColor then
        primaryColor = GetMainTankHazardColor(primary)
    end
    if primarySecretColor then
        primaryDisplayColor = { primarySecretColor[1], primarySecretColor[2], primarySecretColor[3] }
    else
        primaryDisplayColor = primaryColor
    end

    local promoteSig = tostring(unit) .. "|" .. tostring(promotedSource or "none")
        .. "|" .. GetMainTankHazardLabel(primary) .. "|" .. GetMainTankHazardLabel(secondary)
        .. "|" .. tostring(overlapCount)
    if promotedSource and frame._muiMainTankPromoteSig ~= promoteSig then
        frame._muiMainTankPromoteSig = promoteSig
        DebugMT("promote unit=" .. tostring(unit)
            .. " src=" .. tostring(promotedSource)
            .. " primary=" .. GetMainTankHazardLabel(primary)
            .. " secondary=" .. GetMainTankHazardLabel(secondary)
            .. " entries=" .. tostring(overlapCount))
    end

    if primaryDisplayColor and preview.overlay then
        -- Primary border uses PlayerFrame-like corner brackets instead of a full rectangle.
        preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
        if preview.overlay.fill then
            preview.overlay.fill:SetVertexColor(primaryDisplayColor[1], primaryDisplayColor[2], primaryDisplayColor[3], 0.14)
        end
        if preview.overlay.brackets then
            for _, bracket in ipairs(preview.overlay.brackets) do
                bracket:SetVertexColor(primaryDisplayColor[1], primaryDisplayColor[2], primaryDisplayColor[3], 1)
            end
        end
        if preview.overlay.bracketFrame then
            preview.overlay.bracketFrame:Show()
        end
        if preview.overlay.bracketPulse and preview.overlay.bracketPulse.IsPlaying and (not preview.overlay.bracketPulse:IsPlaying()) then
            preview.overlay.bracketPulse:Play()
        end
        preview.overlay:Show()
    else
        if preview.overlay then
            preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
            if preview.overlay.fill then
                preview.overlay.fill:SetVertexColor(0, 0, 0, 0)
            end
            if preview.overlay.bracketPulse and preview.overlay.bracketPulse.IsPlaying and preview.overlay.bracketPulse:IsPlaying() then
                preview.overlay.bracketPulse:Stop()
            end
            if preview.overlay.bracketFrame then
                preview.overlay.bracketFrame:SetAlpha(0.56)
                preview.overlay.bracketFrame:Hide()
            end
            preview.overlay:Hide()
        end
    end

    if primaryDisplayColor and frame.healthBar and frame.healthBar:IsShown() then
        local connected = UnitIsConnected(unit)
        local dead = IsUnitActuallyDead(unit)
        local incomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit)
        if connected and ((not dead) or incomingRes) then
            if frame.healthText and frame.healthText.SetText then
                frame.healthText:SetText("")
            end
            local tex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            if primarySecretColor then
                local base = MAIN_TANK_DEBUFF_TINT_BASE_MUL
                SetMainTankBarColor(frame.healthBar, base, base, base, 0.92)
                if tex and tex.SetVertexColor then
                    tex:SetVertexColor(primarySecretColor[1], primarySecretColor[2], primarySecretColor[3], 1.0)
                end
                if frame.healthBg and frame.healthBg.SetColorTexture then
                    frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
                end
            else
                local hr = primaryColor[1] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                local hg = primaryColor[2] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                local hb = primaryColor[3] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                SetMainTankBarColor(frame.healthBar, hr, hg, hb, 0.92)
                if tex and tex.SetVertexColor then
                    tex:SetVertexColor(hr, hg, hb, 1.0)
                end
                if frame.healthBg and frame.healthBg.SetColorTexture then
                    frame.healthBg:SetColorTexture(primaryColor[1] * 0.12, primaryColor[2] * 0.12, primaryColor[3] * 0.12, 0.6)
                end
            end
            local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
            if style == "Balanced" then style = "Gradient" end
            if style == "Gradient" then
                local hTex = frame.healthBar:GetStatusBarTexture()
                ApplyPolishedGradientToBar(frame.healthBar, hTex, 0.28, 0.035, 0.32)
            end
            SetMainTankRenderedSecretPolish(frame.healthBar, primarySecretColor ~= nil)
        end
    else
        RestoreMainTankHealthBarBaseState(frame, unit)
    end

    if primaryDisplayColor and frame.powerBar and frame.powerBar:IsShown() then
        local connected = UnitIsConnected(unit)
        local dead = IsUnitActuallyDead(unit)
        if connected and not dead then
            local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
            if primarySecretColor then
                local base = MAIN_TANK_DEBUFF_TINT_BASE_MUL
                SetMainTankBarColor(frame.powerBar, base, base, base, 1.0)
                if pTex and pTex.SetVertexColor then
                    pTex:SetVertexColor(primarySecretColor[1], primarySecretColor[2], primarySecretColor[3], 1.0)
                end
            else
                local pr = primaryColor[1] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                local pg = primaryColor[2] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                local pb = primaryColor[3] * MAIN_TANK_DEBUFF_TINT_BASE_MUL
                SetMainTankBarColor(frame.powerBar, pr, pg, pb, 1.0)
                if pTex and pTex.SetVertexColor then
                    pTex:SetVertexColor(pr, pg, pb, 1.0)
                end
            end

            local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
            if style == "Balanced" then style = "Gradient" end
            if style == "Gradient" then
                ApplyPolishedGradientToBar(frame.powerBar, pTex, 0.24, 0.03, 0.28)
            else
                HidePolishedGradientOnBar(frame.powerBar)
            end
            SetMainTankRenderedSecretPolish(frame.powerBar, primarySecretColor ~= nil)
        else
            RestoreMainTankPowerBarBaseState(frame, unit)
        end
    else
        RestoreMainTankPowerBarBaseState(frame, unit)
    end

    local secondaryColor = nil
    if hasOverlap and type(promotedSecondaryColor) == "table" then
        secondaryColor = promotedSecondaryColor
    else
        secondaryColor = GetMainTankHazardColor(secondary)
        if hasOverlap and normalizedSecondary == MAIN_TANK_HAZARD_ENUM.Unknown and type(primaryDisplayColor) == "table" then
            secondaryColor = primaryDisplayColor
        elseif hasOverlap and (not secondaryColor) then
            secondaryColor = primaryDisplayColor or MAIN_TANK_HAZARD_COLORS[MAIN_TANK_HAZARD_ENUM.Unknown]
        end
    end
    if secondaryColor and preview.secondary then
        preview.secondary:SetBackdropBorderColor(secondaryColor[1], secondaryColor[2], secondaryColor[3], 0.95)
        preview.secondary:Show()
    elseif preview.secondary then
        preview.secondary:SetBackdropBorderColor(0, 0, 0, 0)
        preview.secondary:Hide()
    end

    local sweepState = "OFF"
    local sweepSource = "none"
    local sweepRGB = "none"
    if hasOverlap and secondaryColor then
        sweepState = "ON"
        sweepRGB = FormatMainTankColorForDiag(secondaryColor)
        if type(promotedSecondaryColor) == "table" and secondaryColor == promotedSecondaryColor then
            sweepSource = "CONDBORDER_SECONDARY"
        elseif normalizedSecondary == MAIN_TANK_HAZARD_ENUM.Unknown then
            if type(primaryDisplayColor) == "table" and secondaryColor == primaryDisplayColor then
                sweepSource = "PRIMARY_DISPLAY"
            else
                sweepSource = "UNKNOWN_FALLBACK"
            end
        else
            sweepSource = "SECONDARY_ENUM"
        end
    end
    if type(state) == "table" then
        state.sweep = sweepState
        state.sweepSource = sweepSource
        state.sweepRGB = sweepRGB
    end

    LayoutMainTankDebuffSweep(preview, frame)
    if hasOverlap and secondaryColor then
        local sweepEnum = secondary
        if (not sweepEnum) and (type(promotedSecondaryColor) ~= "table") then
            sweepEnum = primary or MAIN_TANK_HAZARD_ENUM.Unknown
        end
        SetMainTankDebuffSweepColor(preview, sweepEnum, secondaryColor)
        SetMainTankDebuffSweepVisible(preview, true)
    else
        SetMainTankDebuffSweepVisible(preview, false)
    end

    local shownIcons = 0
    local totalEntries = (type(entries) == "table") and #entries or 0
    local settingsMax, settingsIconSize, settingsPerRow = GetMainTankDebuffSettings()
    local iconSize = settingsIconSize
    local maxVisibleIcons = settingsMax
    local iconsToShow = math.min(totalEntries, maxVisibleIcons)
    local overflowCount = math.max(0, totalEntries - iconsToShow)

    if preview.iconButtons then
        -- Ensure enough buttons exist
        for i = #preview.iconButtons + 1, maxVisibleIcons do
            if preview._muiCreateIconButton then
                preview.iconButtons[i] = preview._muiCreateIconButton()
            end
        end
        -- Resize icon holder to fit the grid
        local cols = math.min(settingsPerRow, maxVisibleIcons)
        local rows = math.ceil(maxVisibleIcons / settingsPerRow)
        local hSpacing = iconSize + 2
        local vSpacing = iconSize + 2
        if preview.iconHolder then
            preview.iconHolder:SetSize(cols * hSpacing, rows * vSpacing)
        end
        for i = 1, math.max(#preview.iconButtons, maxVisibleIcons) do
            local btn = preview.iconButtons[i]
            if btn then
                btn:SetSize(iconSize, iconSize)
                btn:ClearAllPoints()
                if i <= maxVisibleIcons then
                    local row = math.floor((i - 1) / settingsPerRow)
                    local col = (i - 1) % settingsPerRow
                    btn:SetPoint("TOPRIGHT", preview.iconHolder, "TOPRIGHT", -(col * hSpacing), -(row * vSpacing))
                end
            end
            local entry = (entries and i <= iconsToShow) and entries[i] or nil
            if btn and entry then
                btn._muiUnit = unit
                btn.auraInstanceID = entry.auraInstanceID
                btn.auraIndex = entry.auraIndex
                if btn.countText then
                    local stackText = NormalizeMainTankAuraStackCount(entry.stackCount)
                    if overflowCount > 0 and i == iconsToShow then
                        stackText = "+" .. tostring(overflowCount)
                    end
                    btn.countText:SetText(stackText)
                end

                local appliedAtlas = false
                local iconToken = entry.icon
                if CanUseMainTankIconToken(iconToken) then
                    if btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(iconToken)
                        SetMainTankIconTexCoord(btn.icon, false)
                    end
                else
                    local atlas = GetMainTankHazardIconAtlas(entry.enum or primary)
                    if atlas and btn.icon and btn.icon.SetAtlas then
                        local okAtlas = pcall(btn.icon.SetAtlas, btn.icon, atlas, false)
                        if okAtlas then
                            SetMainTankIconTexCoord(btn.icon, true)
                            appliedAtlas = true
                        end
                    end
                    if not appliedAtlas and btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(MAIN_TANK_DEBUFF_PREVIEW.placeholderIcon)
                        SetMainTankIconTexCoord(btn.icon, false)
                    end
                end

                local iconColor = GetMainTankHazardColor(entry.enum or primary)
                if primarySecretColor then
                    local entryEnum = NormalizeMainTankHazardEnum(entry.enum)
                    if (not entryEnum) or entryEnum == MAIN_TANK_HAZARD_ENUM.Unknown then
                        iconColor = { primarySecretColor[1], primarySecretColor[2], primarySecretColor[3] }
                    end
                end
                if iconColor and btn.SetBackdropBorderColor then
                    btn:SetBackdropBorderColor(iconColor[1], iconColor[2], iconColor[3], 1)
                else
                    btn:SetBackdropBorderColor(0.70, 0.70, 0.70, 1)
                end
                btn:Show()
                shownIcons = shownIcons + 1
            elseif btn then
                btn._muiUnit = nil
                btn.auraInstanceID = nil
                btn.auraIndex = nil
                if btn.countText then
                    btn.countText:SetText("")
                end
                btn:Hide()
            end
        end
    end

    if preview.iconHolder then
        if shownIcons > 0 then
            local stripWidth = (iconSize + 2) * shownIcons
            preview.iconHolder:SetSize(stripWidth, iconSize + 2)
            preview.iconHolder:Show()
            SetMainTankHPTextInset(frame, stripWidth + 2)
        else
            preview.iconHolder:Hide()
            SetMainTankHPTextInset(frame, 0)
        end
    end
end

UpdateMainTankLivePreviewForFrame = function(frame, source)
    if not frame then
        return
    end
    if not IsMainTankDebuffVisualsEnabled() then
        ClearMainTankDebuffPreviewForFrame(frame)
        frame._muiMainTankLiveLastSig = nil
        return
    end
    local unit = frame:GetAttribute("unit")
    if type(unit) ~= "string" or not UnitExists(unit) then
        ClearMainTankDebuffPreviewForFrame(frame)
        frame._muiMainTankLiveLastSig = nil
        return
    end

    local okCollect, state = pcall(CollectMainTankDebuffPreviewState, unit)
    if not okCollect then
        DebugMT("collectError unit=" .. tostring(unit) .. " src=" .. tostring(source or "unknown") .. " err=" .. tostring(state))
        return
    end
    local okApply, applyErr = pcall(ApplyMainTankDebuffPreviewState, frame, state)
    if not okApply then
        DebugMT("applyError unit=" .. tostring(unit) .. " src=" .. tostring(source or "unknown") .. " err=" .. tostring(applyErr))
        return
    end

    local liveMessage = BuildMainTankLiveDiagMessage(state, source)
    if frame._muiMainTankLiveLastSig ~= liveMessage then
        frame._muiMainTankLiveLastSig = liveMessage
        DebugMT(liveMessage)
    end
end

local function GetTankUnits()
    local tanks = {}
    if IsInRaid() then
        local num = GetNumGroupMembers()
        for i = 1, num do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local role = UnitGroupRolesAssigned(unit)
                if role == "TANK" then
                    tanks[#tanks + 1] = unit
                    if #tanks >= 2 then break end
                end
            end
        end
        return tanks, false, #tanks
    end
    return tanks, false, 0
end

local function UpdateMainTankUnit(frame)
    local unit = frame:GetAttribute("unit")
    if not unit or unit == "none" or not UnitExists(unit) then return end

    local _, class = UnitClass(unit)
    local c = { r = 0.5, g = 0.5, b = 0.5 }
    if _G.MidnightUI_Core and _G.MidnightUI_Core.ClassColorsExact and class and _G.MidnightUI_Core.ClassColorsExact[class] then
        c = _G.MidnightUI_Core.ClassColorsExact[class]
    elseif class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        c = RAID_CLASS_COLORS[class]
    end
    frame._muiClassColor = { r = c.r or 0.5, g = c.g or 0.5, b = c.b or 0.5 }

    local okHp, rawHp = pcall(UnitHealth, unit)
    local okMax, rawMax = pcall(UnitHealthMax, unit)
    local hp = (okHp and not IsSecretValue(rawHp) and type(rawHp) == "number") and rawHp or 0
    local maxHp = (okMax and not IsSecretValue(rawMax) and type(rawMax) == "number") and rawMax or 0
    local isDead = IsUnitActuallyDead(unit)
    local isConnected = UnitIsConnected(unit)
    local hasIncomingRes = UnitHasIncomingResurrection(unit)
    local barStyle = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if barStyle == "Balanced" then barStyle = "Gradient" end
    local isSimple = false
    if MidnightUISettings then
        if MidnightUISettings.MainTankFrames and MidnightUISettings.MainTankFrames.layoutStyle == "Simple" then
            isSimple = true
        elseif MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.layoutStyle == "Simple" then
            isSimple = true
        end
    end

    if frame.portrait then
        if isSimple then
            frame.portrait:Hide()
            if frame.portrait.sep then frame.portrait.sep:Hide() end
        else
            frame.portrait:Show()
            if frame.portrait.sep then frame.portrait.sep:Show() end
            SetPortraitTexture(frame.portrait, unit)
            frame.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end

    frame.nameText:SetText(UnitName(unit) or "")
    if isSimple then
        if frame.healthBar then frame.healthBar:Hide() end
        if frame.healthBg then frame.healthBg:Hide() end
        if frame.powerBar then frame.powerBar:Hide() end
        if frame.powerBg then frame.powerBg:Hide() end
        if frame.powerSep then frame.powerSep:Hide() end
        if frame.roleIcon then frame.roleIcon:Hide() end
        frame:SetBackdropColor(c.r, c.g, c.b, 0.9)
        frame.nameText:ClearAllPoints()
        frame.nameText:SetPoint("CENTER", frame, "CENTER", 0, 0)
        frame.nameText:SetTextColor(1, 1, 1)
        frame.healthText:SetText("")
        if frame.deadIcon then frame.deadIcon:Hide() end
        if ClearMainTankDebuffPreviewForFrame then
            ClearMainTankDebuffPreviewForFrame(frame)
        end
        frame._muiMainTankLiveLastSig = nil
        return
    end

    if frame.healthBar then frame.healthBar:Show() end
    if frame.healthBg then frame.healthBg:Show() end
    if frame.powerBar then frame.powerBar:Show() end
    if frame.powerBg then frame.powerBg:Show() end
    if frame.powerSep then frame.powerSep:Show() end
    if frame.roleIcon then frame.roleIcon:Show() end
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame.nameText:ClearAllPoints()
    frame.nameText:SetPoint("LEFT", frame.healthBar, "LEFT", 6, 0)
    frame.nameText:SetTextColor(1, 1, 1)

    if not isConnected then
        SetMainTankBarColor(frame.healthBar, 0.15, 0.15, 0.15, 0.6)
        frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
        frame.healthText:SetText("OFF")
        frame.healthText:SetTextColor(0.6, 0.6, 0.6)
        if frame.deadIcon then frame.deadIcon:Hide() end
    elseif isDead and not hasIncomingRes then
        SetMainTankBarColor(frame.healthBar, c.r * 0.2, c.g * 0.2, c.b * 0.2, 0.7)
        frame.healthBg:SetColorTexture(0.1, 0.02, 0.02, 0.9)
        frame.healthText:SetText("")
        frame.healthText:SetTextColor(1, 1, 1)
        if frame.deadIcon then
            frame.deadIcon:SetSize(32, 32)
            frame.deadIcon:ClearAllPoints()
            frame.deadIcon:SetPoint("RIGHT", frame.healthBar, "RIGHT", -28, 0)
            ApplyDeadIconVisualStyle(frame.deadIcon)
            frame.deadIcon:Show()
        end
    else
        local barR, barG, barB = c.r, c.g, c.b
        if hasIncomingRes then
            barR, barG, barB = barR * 1.2, barG * 1.2, barB * 1.2
        end
        SetMainTankBarColor(frame.healthBar, barR, barG, barB, 0.92)
        frame.healthBg:SetColorTexture(c.r * 0.12, c.g * 0.12, c.b * 0.12, 0.6)

        if not AllowSecretHealthPercent() then
            frame.healthText:SetText("")
        else
            local pct = GetDisplayHealthPercent(unit)
            if pct ~= nil then
                local ok, text = pcall(function()
                    return string.format("%.0f%%", pct)
                end)
                if ok and text then
                    frame.healthText:SetText(text)
                else
                    frame.healthText:SetText("")
                end
            else
                frame.healthText:SetText("")
            end
        end
        frame.healthText:SetTextColor(0.9, 0.9, 0.9)
        if frame.deadIcon then frame.deadIcon:Hide() end
    end

    if barStyle == "Gradient" then
        local hTex = frame.healthBar and frame.healthBar:GetStatusBarTexture()
        if hTex then
            hTex:SetHorizTile(false)
            hTex:SetVertTile(false)
        end
        ApplyPolishedGradientToBar(frame.healthBar, hTex, 0.28, 0.035, 0.32)
    else
        HidePolishedGradientOnBar(frame.healthBar)
    end
    SetMainTankRenderedSecretPolish(frame.healthBar, false)

    pcall(function()
        frame.healthBar:SetMinMaxValues(0, maxHp)
        if isDead and not hasIncomingRes then
            frame.healthBar:SetValue(0)
        else
            frame.healthBar:SetValue(hp)
        end
    end)

    if not isDead then
        local pp = UnitPower(unit)
        local maxPp = UnitPowerMax(unit)
        local _, pToken = UnitPowerType(unit)
        local pColor = POWER_COLORS[pToken] or DEFAULT_POWER_COLOR
        if hasIncomingRes then
            SetMainTankBarColor(frame.powerBar, pColor[1] * 1.2, pColor[2] * 1.2, pColor[3] * 1.2, 0.8)
        else
            SetMainTankBarColor(frame.powerBar, pColor[1], pColor[2], pColor[3], 1)
        end
        frame.powerBar:SetMinMaxValues(0, maxPp)
        frame.powerBar:SetValue(pp)
    else
        SetMainTankBarColor(frame.powerBar, 0.2, 0.2, 0.2, 0.5)
        frame.powerBar:SetValue(0)
    end

    if barStyle == "Gradient" then
        local pTex = frame.powerBar and frame.powerBar:GetStatusBarTexture()
        if pTex then
            pTex:SetHorizTile(false)
            pTex:SetVertTile(false)
        end
        ApplyPolishedGradientToBar(frame.powerBar, pTex, 0.24, 0.03, 0.28)
    else
        HidePolishedGradientOnBar(frame.powerBar)
    end

    local role = UnitGroupRolesAssigned(unit)
    if role == "TANK" then
        frame.roleIcon:SetTexture("Interface\\AddOns\\MidnightUI\\Media\\TankIcon")
        if not frame.roleIcon:GetTexture() then
            frame.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES")
            frame.roleIcon:SetTexCoord(0, 19/64, 22/64, 41/64)
        end
        frame.roleIcon:Show()
    else
        frame.roleIcon:Hide()
    end

    if IsMainTankDebuffVisualsEnabled and IsMainTankDebuffVisualsEnabled() then
        UpdateMainTankLivePreviewForFrame(frame, "UpdateMainTankUnit")
    elseif ClearMainTankDebuffPreviewForFrame then
        ClearMainTankDebuffPreviewForFrame(frame)
        frame._muiMainTankLiveLastSig = nil
    end
end

local function EnsureMainTankFrames()
    EnsureMainTankAnchor()
    ApplyMainTankSettings()
    for i = 1, 2 do
        if not MainTankFrames[i] then
            MainTankFrames[i] = CreateSingleMainTankFrame(i)
        end
        if not isUnlocked then
            if MainTankFrames[i].dragOverlay then MainTankFrames[i].dragOverlay:Hide() end
            MainTankFrames[i]:EnableMouse(false)
            MainTankFrames[i]:SetMovable(false)
        end
    end
end

local function ApplyAssignments()
    EnsureMainTankFrames()
    if InCombatLockdown() then
        pendingRosterUpdate = true
        return
    end

    local tanks = GetTankUnits()
    for i = 1, 2 do
        local frame = MainTankFrames[i]
        local unit = tanks[i]
        if unit then
            frame:SetAttribute("unit", unit)
            frame.unit = unit
            UpdateMainTankUnit(frame)
            frame:Show()
        else
            frame:SetAttribute("unit", "none")
            frame.unit = nil
            if ClearMainTankDebuffPreviewForFrame then
                ClearMainTankDebuffPreviewForFrame(frame)
            end
            frame._muiMainTankLiveLastSig = nil
            if isUnlocked then
                frame:Show()
                ApplyMainTankPlaceholder(frame, i)
            else
                frame:Hide()
            end
        end
    end
end

local function UpdateMainTankVisibility()
    if InCombatLockdown() then
        pendingRosterUpdate = true
        return
    end
    -- Check if MainTankFrames are enabled
    if MidnightUISettings and MidnightUISettings.MainTankFrames and MidnightUISettings.MainTankFrames.enabled == false then
        for i = 1, 2 do
            if MainTankFrames[i] then
                if ClearMainTankDebuffPreviewForFrame then
                    ClearMainTankDebuffPreviewForFrame(MainTankFrames[i])
                end
                MainTankFrames[i]._muiMainTankLiveLastSig = nil
                MainTankFrames[i]:Hide()
                if MainTankFrames[i].dragOverlay then MainTankFrames[i].dragOverlay:Hide() end
            end
        end
        if MainTankAnchor then MainTankAnchor:Hide() end
        return
    end
    if not IsInRaid() and not isUnlocked then
        for i = 1, 2 do
            if MainTankFrames[i] then
                if ClearMainTankDebuffPreviewForFrame then
                    ClearMainTankDebuffPreviewForFrame(MainTankFrames[i])
                end
                MainTankFrames[i]._muiMainTankLiveLastSig = nil
                MainTankFrames[i]:Hide()
                if MainTankFrames[i].dragOverlay then MainTankFrames[i].dragOverlay:Hide() end
                MainTankFrames[i]:EnableMouse(false)
                MainTankFrames[i]:SetMovable(false)
            end
        end
        DebugMT("Visibility: hidden (not in raid, locked).")
        return
    end
    ApplyAssignments()
end

function MidnightUI_RefreshMainTankFrames()
    for _, frame in ipairs(MainTankFrames) do
        if frame and frame:IsShown() then
            UpdateMainTankUnit(frame)
        end
    end
end

-- =========================================================================
--  DRAG & LOCKING
-- =========================================================================

function MidnightUI_SetMainTankFramesLocked(locked)
    EnsureMainTankFrames()
    if InCombatLockdown() then
        pendingLockState = locked
        return
    end

    isUnlocked = not locked
    DebugMT("Lock state changed. locked=" .. tostring(locked) .. " unlocked=" .. tostring(isUnlocked))

    for i = 1, 2 do
        local frame = MainTankFrames[i]
            if locked then
                if RegisterUnitWatch then RegisterUnitWatch(frame) end
                frame:EnableMouse(false)
                frame:SetMovable(false)
            else
                if UnregisterUnitWatch then UnregisterUnitWatch(frame) end
                frame:Show()
                frame:EnableMouse(true)
                frame:SetMovable(true)
            end
        end

    for i = 1, 2 do
        local frame = MainTankFrames[i]
        if frame then
            if locked then
                if frame.dragOverlay then frame.dragOverlay:Hide() end
                if frame.dragOverlay and frame.dragOverlay:IsShown() then
                    DebugMT("Overlay still shown while locked on frame " .. i)
                end
            else
                if not frame.dragOverlay then
                    local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
                    overlay:SetAllPoints()
                    overlay:SetFrameStrata("DIALOG")
                    overlay:SetBackdrop({
                        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true,
                        tileSize = 16,
                        edgeSize = 16,
                        insets = { left = 4, right = 4, top = 4, bottom = 4 }
                    })
                    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
                    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
                    if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "unit") end
                    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                    label:SetPoint("CENTER")
                    label:SetText("MAIN TANK " .. i)
                    label:SetTextColor(1, 1, 1)
                    overlay:EnableMouse(true)
                    overlay:RegisterForDrag("LeftButton")
                    overlay:SetScript("OnDragStart", function() frame:StartMoving() end)
                    overlay:SetScript("OnDragStop", function()
                        frame:StopMovingOrSizing()
                        local point, _, relativePoint, xOfs, yOfs = frame:GetPoint()
                        EnsureMainTankSettings()
                        MidnightUISettings.MainTankFrames.frames[i] = MidnightUISettings.MainTankFrames.frames[i] or {}
                        MidnightUISettings.MainTankFrames.frames[i].position = { point, relativePoint, xOfs, yOfs }
                    end)
                    if _G.MidnightUI_AttachOverlaySettings then
                        _G.MidnightUI_AttachOverlaySettings(overlay, "MainTankFrames")
                    end
                    frame.dragOverlay = overlay
                end
                frame.dragOverlay:Show()
                -- Add debuff placeholder grid to the drag overlay
                local maxIcons, iconSize, perRow = GetMainTankDebuffSettings()
                local hSpacing = iconSize + 2
                local vSpacing = iconSize + 2
                local cols = math.min(perRow, maxIcons)
                local rows = math.ceil(maxIcons / perRow)
                local overlay = frame.dragOverlay
                if not overlay._muiDebuffPlaceholders then overlay._muiDebuffPlaceholders = {} end
                local placeholders = overlay._muiDebuffPlaceholders
                for pi = 1, maxIcons do
                    if not placeholders[pi] then
                        local holder = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
                        holder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
                        holder:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.9)
                        local ico = holder:CreateTexture(nil, "ARTWORK")
                        ico:SetAllPoints()
                        ico:SetTexture(MAIN_TANK_DEBUFF_PREVIEW.placeholderIcon)
                        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        holder.icon = ico
                        placeholders[pi] = holder
                    end
                    local holder = placeholders[pi]
                    holder:SetSize(iconSize, iconSize)
                    holder:ClearAllPoints()
                    local row = math.floor((pi - 1) / perRow)
                    local col = (pi - 1) % perRow
                    holder:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -2 - (col * hSpacing), -2 - (row * vSpacing))
                    holder:Show()
                end
                for pi = maxIcons + 1, #placeholders do
                    if placeholders[pi] then placeholders[pi]:Hide() end
                end
            end
        end
    end

UpdateMainTankVisibility()
end

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function BuildMainTankOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    EnsureMainTankSettings()
    local s = MidnightUISettings.MainTankFrames
    b:Header("Main Tank Frames")
    b:Slider("Width", 160, 420, 2, s.width or config.width, function(v)
        s.width = math.floor(v)
        ApplyMainTankSettings()
    end)
    b:Slider("Height", 36, 120, 2, s.height or config.height, function(v)
        s.height = math.floor(v)
        ApplyMainTankSettings()
    end)
    b:Slider("Spacing", 0, 20, 1, s.spacing or config.spacing, function(v)
        s.spacing = math.floor(v)
        ApplyMainTankSettings()
    end)
    b:Slider("Scale %", 50, 150, 5, (s.scale or config.scale) * 100, function(v)
        s.scale = math.floor(v) / 100
        ApplyMainTankSettings()
    end)
    b:Header("Debuff Icons")
    b:Slider("Max Debuff Icons", 1, MAIN_TANK_DEBUFF_PREVIEW.maxIconsLimit, 1, s.debuffMaxShown or MAIN_TANK_DEBUFF_PREVIEW.maxIcons, function(v)
        s.debuffMaxShown = math.floor(v + 0.5)
        ApplyMainTankSettings()
    end)
    b:Slider("Debuff Icon Size", 8, 40, 1, s.debuffIconSize or MAIN_TANK_DEBUFF_PREVIEW.iconSize, function(v)
        s.debuffIconSize = math.floor(v + 0.5)
        ApplyMainTankSettings()
    end)
    b:Slider("Icons Per Row", 1, MAIN_TANK_DEBUFF_PREVIEW.maxIconsLimit, 1, s.debuffPerRow or MAIN_TANK_DEBUFF_PREVIEW.defaultPerRow, function(v)
        s.debuffPerRow = math.floor(v + 0.5)
        ApplyMainTankSettings()
    end)
    b:Note("Drag the overlay to move.")
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("MainTankFrames", { title = "Main Tank Frames", build = BuildMainTankOverlaySettings })
end

-- =========================================================================
--  EVENTS
-- =========================================================================

MainTankManager:RegisterEvent("PLAYER_ENTERING_WORLD")
MainTankManager:RegisterEvent("GROUP_ROSTER_UPDATE")
MainTankManager:RegisterEvent("PLAYER_ROLES_ASSIGNED")
MainTankManager:RegisterEvent("UNIT_HEALTH")
MainTankManager:RegisterEvent("UNIT_MAXHEALTH")
MainTankManager:RegisterEvent("UNIT_CONNECTION")
MainTankManager:RegisterEvent("UNIT_NAME_UPDATE")
MainTankManager:RegisterEvent("UNIT_FLAGS")
MainTankManager:RegisterEvent("UNIT_POWER_UPDATE")
MainTankManager:RegisterEvent("UNIT_DISPLAYPOWER")
MainTankManager:RegisterEvent("UNIT_PORTRAIT_UPDATE")
MainTankManager:RegisterEvent("UNIT_AURA")
MainTankManager:RegisterEvent("PLAYER_REGEN_ENABLED")

MainTankManager:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        EnsureMainTankBlizzAuraHook()
        EnsureMainTankFrames()
        UpdateMainTankVisibility()
        return
    end

    if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_ROLES_ASSIGNED" then
        EnsureMainTankBlizzAuraHook()
        UpdateMainTankVisibility()
        return
    end

    if event == "PLAYER_REGEN_ENABLED" then
        if pendingLockState ~= nil then
            local pending = pendingLockState
            pendingLockState = nil
            MidnightUI_SetMainTankFramesLocked(pending)
        end
        if pendingRosterUpdate then
            pendingRosterUpdate = nil
            UpdateMainTankVisibility()
        end
        return
    end

    local unit = ...
    if not unit then return end
    for i = 1, 2 do
        local frame = MainTankFrames[i]
        if frame and frame.unit and IsSameUnitToken(unit, frame.unit) then
            UpdateMainTankUnit(frame)
        end
    end
end)

if MidnightUISettings and MidnightUISettings.Messenger then
    MidnightUI_SetMainTankFramesLocked(MidnightUISettings.Messenger.locked)
end
