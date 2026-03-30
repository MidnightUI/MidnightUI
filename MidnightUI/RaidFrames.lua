-- =============================================================================
-- FILE PURPOSE:     Custom raid frames for groups up to 40 players. Displays compact
--                   health bars per member with class-color health, debuff hazard tint
--                   (RAID_HAZARD_ENUM), role-icon debuff preview strip, range-based alpha
--                   fading, and a live preview mode for layout tuning. Groups can be
--                   arranged in columns sorted by group number.
-- LOAD ORDER:       Loads after ConditionBorder.lua. RaidFrameManager handles ADDON_LOADED,
--                   GROUP_ROSTER_UPDATE, PLAYER_ENTERING_WORLD.
-- DEFINES:          RaidFrameManager (event frame), RaidFrames[] (up to 40 member frames),
--                   RaidAnchor (drag container). Globals: MidnightUI_ApplyRaidFramesSettings().
-- READS:            MidnightUISettings.RaidFrames.{enabled, width, height, scale, alpha,
--                   position, columns, spacingX, spacingY, groupBy, colorByGroup,
--                   showHealthPct, textSize, rangeAlpha, inRangeAlpha}.
--                   MidnightUISettings.General.{unitFrameBarStyle, allowSecretHealthPercent}.
-- WRITES:           MidnightUISettings.RaidFrames.position (on drag stop).
--                   Blizzard CompactRaidFrameContainer: reparented to hiddenParent.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (health bar per member class).
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua).
--                   ConditionBorder / hazard probe system — raid tint is self-contained copy.
-- USED BY:          Settings_UI.lua (exposes raid frame settings controls).
-- KEY FLOWS:
--   GROUP_ROSTER_UPDATE → EnsureRaidFrames() → builds/shows/hides per-slot frames
--   UNIT_HEALTH raidN → UpdateHealth(RaidFrames[n])
--   UNIT_AURA raidN → hazard probe → RAID_HAZARD_ENUM tint + debuff preview icons
--   _raidBatchFrame:OnUpdate → flushes _raidDirtyUnits in one render pass
--   RaidRangeTicker → fades out-of-range members to rangeAlpha
-- GOTCHAS:
--   config.colorByGroup: when true, each group of 5 gets a different health bar hue
--   rather than class color — intended for encounters where role/group identity matters.
--   RAID_DEBUFF_TINT_BASE_MUL = 0.60: tint is 60% strength — more subtle than party (86%).
--   ApplyDeadIconVisualStyle differs from other unit frames: in Gradient bar style it
--   desaturates + tints light grey; in other styles keeps the skull at full color.
--   GetRaidTextSizes(): text sizes are clamped 6-14px; derive name and health-pct sizes.
--   RaidLivePreviewState.bridgeMode: when true, dummy frames are shown for members that
--   don't exist in-game — used to test 20-member raids in a solo environment.
-- NAVIGATION:
--   config{}                    — default dimensions (line ~34)
--   RAID_HAZARD_ENUM / COLORS   — dispel type map (line ~54)
--   EnsureRaidSettings()        — ensures RaidFrames subtable exists with defaults
--   EnsureRaidFrames()          — builds/resizes the frame pool up to current group size
--   UpdateHealth(), UpdatePower()— per-frame stat refresh
--   _raidBatchFrame:OnUpdate    — batch flush of dirty unit indices
-- =============================================================================

local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then
    ADDON_NAME = "MidnightUI"
end
if type(Addon) ~= "table" then
    Addon = {}
end
local RaidFrameManager = CreateFrame("Frame")

-- Localized globals for hot-path performance
local UnitHealth = UnitHealth
local UnitHealthMax = UnitHealthMax
local UnitExists = UnitExists
local UnitIsConnected = UnitIsConnected
local UnitClass = UnitClass
local UnitName = UnitName
local GetTime = GetTime
local pairs = pairs
local type = type
local wipe = wipe
local string_match = string.match
local string_format = string.format
local pcall = pcall
local tonumber = tonumber

-- =========================================================================
--  CONFIG
-- =========================================================================

local config = {
    width = 92,
    height = 24,
    columns = 5,
    spacingX = 6,
    spacingY = 4,
    maxFrames = 40,
    startPos = {"LEFT", UIParent, "LEFT", 0, 155.77786},
    rangeAlpha = 0.35,
    inRangeAlpha = 1.0,
    groupBy = true,
    colorByGroup = true,
}

-- Batch coalescing: collect dirty raid unit indices in one frame, flush on next render
local _raidDirtyUnits = {}
local _raidDirtyAll = false
local _raidBatchFrame = CreateFrame("Frame")
_raidBatchFrame:Hide()
local DEAD_STATUS_ATLAS = "icons_64x64_deadly"
local RAID_HAZARD_ENUM = {
    None = 0,
    Magic = 1,
    Curse = 2,
    Disease = 3,
    Poison = 4,
    Enrage = 9,
    Bleed = 11,
    Unknown = 99,
}
local RAID_HAZARD_LABELS = {
    [RAID_HAZARD_ENUM.None] = "NONE",
    [RAID_HAZARD_ENUM.Magic] = "MAGIC",
    [RAID_HAZARD_ENUM.Curse] = "CURSE",
    [RAID_HAZARD_ENUM.Disease] = "DISEASE",
    [RAID_HAZARD_ENUM.Poison] = "POISON",
    [RAID_HAZARD_ENUM.Bleed] = "BLEED",
    [RAID_HAZARD_ENUM.Unknown] = "UNKNOWN",
}
local RAID_HAZARD_COLORS = {
    [RAID_HAZARD_ENUM.Magic] = { 0.15, 0.55, 0.95 },
    [RAID_HAZARD_ENUM.Curse] = { 0.70, 0.20, 0.95 },
    [RAID_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [RAID_HAZARD_ENUM.Poison] = { 0.15, 0.65, 0.20 },
    [RAID_HAZARD_ENUM.Bleed] = { 0.95, 0.15, 0.15 },
    [RAID_HAZARD_ENUM.Unknown] = { 0.64, 0.19, 0.79 },
}
local RAID_HAZARD_PRIORITY = {
    RAID_HAZARD_ENUM.Magic,
    RAID_HAZARD_ENUM.Curse,
    RAID_HAZARD_ENUM.Disease,
    RAID_HAZARD_ENUM.Poison,
    RAID_HAZARD_ENUM.Bleed,
}
local RAID_HAZARD_CURVE_EPSILON = 0.02
local RAID_HAZARD_STICKY_SEC = 8
local RAID_DEBUFF_PREVIEW = {
    iconSize = 16,
    maxIcons = 3,
    offsetX = 8,
    offsetY = 0,
    placeholderIcon = 134400,
}
local RAID_DEBUFF_TINT_BASE_MUL = 0.60

local function ApplyDeadIconVisualStyle(icon)
    if not icon then return end
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Gradient" then
        if icon.SetDesaturated then icon:SetDesaturated(true) end
        icon:SetVertexColor(0.86, 0.89, 0.93, 1)
        icon:SetAlpha(0.92)
    else
        if icon.SetDesaturated then icon:SetDesaturated(false) end
        icon:SetVertexColor(1, 1, 1, 1)
        icon:SetAlpha(1)
    end
end

local RaidFrames = {}
local RaidRangeTicker
local RaidAnchor
local UpdateRaidVisibility
local EnsureRaidFrames
local RaidLivePreviewState = {
    active = false,
    pendingStart = false,
    pendingRestore = false,
    bridgeMode = false,
    bridgeFrameCount = 20,
    lastTickSig = nil,
}
local _raidHazardProbeCurves = {}
local _raidHazardProbeMatchColors = {}
local _raidHazardZeroProbeCurve = nil
local _raidBlizzAuraCache = {}
local _raidBlizzHookRegistered = false
local function EnsureRaidSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
    local s = MidnightUISettings.RaidFrames
    if s.showHealthPct == nil then s.showHealthPct = true end
    if s.textSize == nil then s.textSize = 9 end
    return s
end

-- HIDDEN PARENT FOR DEFAULT FRAMES
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
local pendingRaidLayout = false
local pendingRaidVisibility = false

-- =========================================================================
--  HELPERS
-- =========================================================================

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
    return ok
end

local function GetRaidTextSizes()
    local s = MidnightUISettings and MidnightUISettings.RaidFrames
    local base = (s and tonumber(s.textSize)) or 9
    if base < 6 then base = 6 end
    if base > 14 then base = 14 end
    local hpSize = math.max(6, base - 1)
    return base, hpSize
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

local function IsRaidDiagEnabled()
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

local function RaidDiag(msg)
    local text = tostring(msg or "")
    local src = "RaidLivePreview"
    if IsRaidDiagEnabled() then
        pcall(_G.MidnightUI_Diagnostics.LogDebugSource, src, text)
        return
    end
    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. text)
end

if type(Addon.Diag) ~= "function" then
    function Addon:Diag(message)
        RaidDiag(message)
    end
end

if type(Addon.DiagTrace) ~= "function" then
    function Addon:DiagTrace(eventName, ...)
        local args = {}
        for i = 1, select("#", ...) do
            args[#args + 1] = tostring(select(i, ...))
        end
        local suffix = (#args > 0) and (" " .. table.concat(args, " ")) or ""
        RaidDiag("trace event=" .. tostring(eventName or "nil") .. suffix)
    end
end

if type(Addon.DiagDump) ~= "function" then
    function Addon:DiagDump(label, value)
        RaidDiag("dump " .. tostring(label or "value") .. "=" .. tostring(value))
    end
end

local function NormalizeRaidHazardEnum(value)
    if value == nil then
        return nil
    end
    local valueType = type(value)
    if valueType == "number" then
        if IsSecretValue(value) then
            return nil
        end
        if value == RAID_HAZARD_ENUM.Magic or value == RAID_HAZARD_ENUM.Curse or value == RAID_HAZARD_ENUM.Disease
            or value == RAID_HAZARD_ENUM.Poison or value == RAID_HAZARD_ENUM.Bleed
            or value == RAID_HAZARD_ENUM.Unknown then
            return value
        end
        if value == RAID_HAZARD_ENUM.Enrage then
            return RAID_HAZARD_ENUM.Bleed
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
        return RAID_HAZARD_ENUM.Magic
    elseif upper:find("CURSE", 1, true) then
        return RAID_HAZARD_ENUM.Curse
    elseif upper:find("DISEASE", 1, true) then
        return RAID_HAZARD_ENUM.Disease
    elseif upper:find("POISON", 1, true) then
        return RAID_HAZARD_ENUM.Poison
    elseif upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then
        return RAID_HAZARD_ENUM.Bleed
    elseif upper:find("UNKNOWN", 1, true) then
        return RAID_HAZARD_ENUM.Unknown
    end
    return nil
end

local function GetRaidHazardLabel(enum)
    local normalized = NormalizeRaidHazardEnum(enum)
    if not normalized then
        return "NONE"
    end
    return RAID_HAZARD_LABELS[normalized] or "NONE"
end

local function GetRaidHazardColor(enum)
    local normalized = NormalizeRaidHazardEnum(enum)
    if not normalized then
        return nil
    end
    return RAID_HAZARD_COLORS[normalized]
end

local function IsRaidSecretColor(color)
    if type(color) ~= "table" then
        return false
    end
    if color.secret == true then
        return true
    end
    return IsSecretValue(color[1]) or IsSecretValue(color[2]) or IsSecretValue(color[3])
end

local function FormatRaidColorForDiag(color)
    if type(color) ~= "table" then
        return "none"
    end
    if IsRaidSecretColor(color) then
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

local function IsRaidCurveColorMatch(a, b)
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
        if value == nil then
            return nil
        end
        if IsSecretValue(value) then
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
    local eps = RAID_HAZARD_CURVE_EPSILON
    if math.abs(ar - br) > eps then return false end
    if math.abs(ag - bg) > eps then return false end
    if math.abs(ab - bb) > eps then return false end
    if math.abs(aa - ba) > eps then return false end
    return true
end

local function IsRaidCurveColorDifferent(a, b)
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
        if value == nil then
            return nil
        end
        if IsSecretValue(value) then
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
    local eps = RAID_HAZARD_CURVE_EPSILON
    if math.abs(ar - br) > eps then return true end
    if math.abs(ag - bg) > eps then return true end
    if math.abs(ab - bb) > eps then return true end
    if math.abs(aa - ba) > eps then return true end
    return false
end

local function GetRaidHazardProbeCurve(targetEnum)
    local normalized = NormalizeRaidHazardEnum(targetEnum)
    if not normalized then
        return nil
    end
    if _raidHazardProbeCurves[normalized] then
        return _raidHazardProbeCurves[normalized]
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
        local pointEnum = NormalizeRaidHazardEnum(enumValue) or enumValue
        local alpha = (pointEnum == normalized) and 1 or 0
        curve:AddPoint(enumValue, CreateColor(1, 1, 1, alpha))
    end
    Add(RAID_HAZARD_ENUM.None)
    Add(RAID_HAZARD_ENUM.Magic)
    Add(RAID_HAZARD_ENUM.Curse)
    Add(RAID_HAZARD_ENUM.Disease)
    Add(RAID_HAZARD_ENUM.Poison)
    Add(RAID_HAZARD_ENUM.Enrage)
    Add(RAID_HAZARD_ENUM.Bleed)
    _raidHazardProbeCurves[normalized] = curve
    _raidHazardProbeMatchColors[normalized] = CreateColor(1, 1, 1, 1)
    return curve
end

local function GetRaidHazardZeroProbeCurve()
    if _raidHazardZeroProbeCurve then
        return _raidHazardZeroProbeCurve
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
        return nil
    end
    if not Enum or not Enum.LuaCurveType then
        return nil
    end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(RAID_HAZARD_ENUM.None, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Magic, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Curse, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Poison, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Enrage, CreateColor(1, 1, 1, 0))
    curve:AddPoint(RAID_HAZARD_ENUM.Bleed, CreateColor(1, 1, 1, 0))
    _raidHazardZeroProbeCurve = curve
    return curve
end

local function ResolveRaidHazardEnumByCurve(unit, auraInstanceID)
    if not unit or not auraInstanceID then
        return nil
    end
    if not C_UnitAuras or type(C_UnitAuras.GetAuraDispelTypeColor) ~= "function" then
        return nil
    end
    local zeroCurve = GetRaidHazardZeroProbeCurve()
    for _, enum in ipairs(RAID_HAZARD_PRIORITY) do
        local curve = GetRaidHazardProbeCurve(enum)
        if curve then
            local okColor, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
            if okColor and color then
                if zeroCurve then
                    local okZero, zeroColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, zeroCurve)
                    if okZero and IsRaidCurveColorDifferent(color, zeroColor) then
                        return enum
                    end
                end
                local expected = _raidHazardProbeMatchColors[NormalizeRaidHazardEnum(enum)]
                if expected and IsRaidCurveColorMatch(color, expected) then
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

local function ResolveRaidHazardFromAura(unit, aura)
    if type(aura) ~= "table" then
        return nil, nil
    end
    local dt = NormalizeRaidHazardEnum(aura.dispelType)
    if dt then return dt, "field:dispelType" end
    dt = NormalizeRaidHazardEnum(aura.dispelName)
    if dt then return dt, "field:dispelName" end
    dt = NormalizeRaidHazardEnum(aura.debuffType)
    if dt then return dt, "field:debuffType" end
    dt = NormalizeRaidHazardEnum(aura.type)
    if dt then return dt, "field:type" end
    local auraInstanceID = aura.auraInstanceID
    if auraInstanceID then
        dt = ResolveRaidHazardEnumByCurve(unit, auraInstanceID)
        if dt then
            return dt, "curve"
        end
    end
    return nil, nil
end

local function IsRaidBlizzTrackedUnit(unit)
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

local function ResolveRaidHazardFromBlizzFrameDebuff(debuffFrame)
    if not debuffFrame then
        return nil
    end
    local dt = NormalizeRaidHazardEnum(debuffFrame.debuffType)
    if not dt then
        dt = NormalizeRaidHazardEnum(debuffFrame.dispelName)
    end
    if not dt then
        dt = NormalizeRaidHazardEnum(debuffFrame.dispelType)
    end
    if not dt then
        dt = NormalizeRaidHazardEnum(debuffFrame.type)
    end
    return dt
end

local function CountRaidBlizzAuraSet(tbl)
    if type(tbl) ~= "table" then
        return 0
    end
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

local function ResolveRaidHazardFromAuraInstanceID(unit, auraInstanceID, typeHint)
    local dt = NormalizeRaidHazardEnum(typeHint)
    if dt and dt ~= RAID_HAZARD_ENUM.Unknown then
        return dt, "blizz:type"
    end
    dt = ResolveRaidHazardEnumByCurve(unit, auraInstanceID)
    if dt then
        return dt, "blizz:curve"
    end
    return nil, nil
end

-- File-scope aura helpers (avoids closure allocation per CompactUnitFrame_UpdateAuras hook call)
local _raidSpellIDFields = { "spellID", "spellId", "auraSpellID", "auraSpellId" }

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
    if not icon then
        icon = ReadTextureToken(df.Icon)
    end
    if not icon then
        icon = ReadTextureToken(df.iconTexture)
    end
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

local function ReadDebuffFrameSpellID(df)
    if not df then
        return nil
    end
    for _, field in ipairs(_raidSpellIDFields) do
        local candidate = df[field]
        if candidate then
            local okSpellID, spellID = pcall(tonumber, candidate)
            if okSpellID and spellID and (not IsSecretValue(spellID)) and spellID > 0 then
                return spellID
            end
        end
    end
    return nil
end

local function StoreRaidAura(entry, iid, isDispellable, dt, icon, stackCount, spellID)
    if not iid then
        return
    end
    entry.debuffs[iid] = true
    if isDispellable then
        entry.dispellable[iid] = true
    end
    if dt and dt ~= RAID_HAZARD_ENUM.Unknown then
        entry.types[iid] = dt
    end
    if icon then
        entry.icons[iid] = icon
    end
    if stackCount and stackCount > 1 then
        entry.stacks[iid] = stackCount
    end
    local okSpellID, numericSpellID = pcall(tonumber, spellID)
    if okSpellID and numericSpellID and (not IsSecretValue(numericSpellID)) and numericSpellID > 0 then
        entry.spellIDs[iid] = numericSpellID
    end
end

local function CaptureRaidHazardsFromBlizzFrame(blizzFrame)
    if not blizzFrame then
        return nil, nil
    end
    local unit = blizzFrame.unit
    if not IsRaidBlizzTrackedUnit(unit) then
        return nil, nil
    end
    if UnitExists and type(UnitExists) == "function" and not UnitExists(unit) then
        return nil, nil
    end

    local entry = _raidBlizzAuraCache[unit]
    if not entry then
        entry = { debuffs = {}, dispellable = {}, types = {}, icons = {}, stacks = {}, spellIDs = {} }
        _raidBlizzAuraCache[unit] = entry
    else
        if type(entry.icons) ~= "table" then entry.icons = {} end
        if type(entry.stacks) ~= "table" then entry.stacks = {} end
        if type(entry.spellIDs) ~= "table" then entry.spellIDs = {} end
        wipe(entry.debuffs)
        wipe(entry.dispellable)
        wipe(entry.types)
        wipe(entry.icons)
        wipe(entry.stacks)
        wipe(entry.spellIDs)
    end

    if type(blizzFrame.debuffFrames) == "table" then
        for _, df in pairs(blizzFrame.debuffFrames) do
            local shown = (not df) and false or (not df.IsShown) or df:IsShown()
            if df and df.auraInstanceID and shown then
                StoreRaidAura(entry,
                    df.auraInstanceID,
                    false,
                    ResolveRaidHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df),
                    ReadDebuffFrameSpellID(df)
                )
            end
        end
    end

    if type(blizzFrame.dispelDebuffFrames) == "table" then
        for _, df in pairs(blizzFrame.dispelDebuffFrames) do
            local shown = (not df) and false or (not df.IsShown) or df:IsShown()
            if df and df.auraInstanceID and shown then
                StoreRaidAura(entry,
                    df.auraInstanceID,
                    true,
                    ResolveRaidHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df),
                    ReadDebuffFrameSpellID(df)
                )
            end
        end
    end

    return unit, entry
end

local function PrimeRaidBlizzAuraCache()
    local compactPlayerFrame = _G.CompactPlayerFrame
    if compactPlayerFrame and compactPlayerFrame.unit == "player" then
        CaptureRaidHazardsFromBlizzFrame(compactPlayerFrame)
    end

    for i = 1, 5 do
        local compactParty = _G["CompactPartyFrameMember" .. tostring(i)]
        if compactParty and compactParty.unit then
            CaptureRaidHazardsFromBlizzFrame(compactParty)
        end
    end

    for i = 1, 40 do
        local compactRaid = _G["CompactRaidFrame" .. tostring(i)]
        if compactRaid and compactRaid.unit then
            CaptureRaidHazardsFromBlizzFrame(compactRaid)
        end
    end

    for g = 1, 8 do
        for m = 1, 5 do
            local compactMember = _G["CompactRaidGroup" .. tostring(g) .. "Member" .. tostring(m)]
            if compactMember and compactMember.unit then
                CaptureRaidHazardsFromBlizzFrame(compactMember)
            end
        end
    end
end

local function EnsureRaidBlizzAuraHook()
    if _raidBlizzHookRegistered then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end

    local function OnBlizzAuraUpdate(blizzFrame)
        CaptureRaidHazardsFromBlizzFrame(blizzFrame)
    end

    if type(CompactUnitFrame_UpdateAuras) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", OnBlizzAuraUpdate)
        _raidBlizzHookRegistered = true
    end
    if type(CompactUnitFrame_UpdateDebuffs) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", OnBlizzAuraUpdate)
        _raidBlizzHookRegistered = true
    end

    if _raidBlizzHookRegistered then
        PrimeRaidBlizzAuraCache()
    end
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

local function CanUseRaidIconToken(iconToken)
    if iconToken == nil then
        return false
    end
    if IsSecretValue(iconToken) then
        return true
    end
    local tokenType = type(iconToken)
    if tokenType == "number" then
        if iconToken == RAID_DEBUFF_PREVIEW.placeholderIcon then
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

local function NormalizeRaidAuraStackCount(value)
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

local function CoerceRaidTintChannel(value)
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

local function ParseRaidRGBText(text)
    if type(text) ~= "string" or IsSecretValue(text) then
        return nil, nil, nil
    end
    local r, g, b = text:match("([%-%d%.]+)%s*,%s*([%-%d%.]+)%s*,%s*([%-%d%.]+)")
    if not r then
        return nil, nil, nil
    end
    return CoerceRaidTintChannel(r), CoerceRaidTintChannel(g), CoerceRaidTintChannel(b)
end

local function CloneRaidColor(color)
    if type(color) ~= "table" then
        return nil
    end
    if color.secret == true then
        if color[1] == nil or color[2] == nil or color[3] == nil then
            return nil
        end
        return { color[1], color[2], color[3], secret = true, source = color.source }
    end
    local r = CoerceRaidTintChannel(color[1] or color.r)
    local g = CoerceRaidTintChannel(color[2] or color.g)
    local b = CoerceRaidTintChannel(color[3] or color.b)
    if r == nil or g == nil or b == nil then
        return nil
    end
    return { r, g, b }
end

local function GetRaidHazardHintFromPlayerFrameCondTint()
    local frame = _G.MidnightUI_PlayerFrame
    if not frame then
        return nil, nil, nil, nil, "playerframe-unavailable", nil
    end
    if frame._muiCondTintActive ~= true then
        return nil, nil, nil, nil, "playerframe-condtint-off", nil
    end

    local enum = NormalizeRaidHazardEnum(frame._muiCondTintSource)
    local r = CoerceRaidTintChannel(frame._muiCondTintR)
    local g = CoerceRaidTintChannel(frame._muiCondTintG)
    local b = CoerceRaidTintChannel(frame._muiCondTintB)
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
            return RAID_HAZARD_ENUM.Unknown, nil, nil, nil, "playerframe-condtint-secret", secretColor
        end
        return RAID_HAZARD_ENUM.Unknown, r, g, b, "playerframe-condtint-unknown", nil
    end
    return nil, nil, nil, nil, "playerframe-condtint-none", nil
end

local function GetRaidHazardHintFromConditionBorder(unit)
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
            local enum = NormalizeRaidHazardEnum(state.primaryEnum)
                or NormalizeRaidHazardEnum(state.activePrimaryEnum)
                or NormalizeRaidHazardEnum(state.curvePrimaryEnum)
                or NormalizeRaidHazardEnum(state.overlapPrimaryEnum)
                or NormalizeRaidHazardEnum(state.hookPrimaryEnum)
                or NormalizeRaidHazardEnum(state.barTintEnum)
                or NormalizeRaidHazardEnum(state.primaryLabel)
                or NormalizeRaidHazardEnum(state.tintSource)

            local secondaryEnum = NormalizeRaidHazardEnum(state.overlapSecondaryEnum)
                or NormalizeRaidHazardEnum(state.activeSecondaryEnum)
                or NormalizeRaidHazardEnum(state.hookSecondaryEnum)
            local typeBoxEnum = NormalizeRaidHazardEnum(state.typeBoxEnum)
            if (not secondaryEnum) and typeBoxEnum and typeBoxEnum ~= RAID_HAZARD_ENUM.Unknown then
                secondaryEnum = typeBoxEnum
            end

            local secondaryColor = nil
            local rawSecR, rawSecG, rawSecB = state.typeBoxR, state.typeBoxG, state.typeBoxB
            if rawSecR ~= nil and rawSecG ~= nil and rawSecB ~= nil then
                if IsSecretValue(rawSecR) or IsSecretValue(rawSecG) or IsSecretValue(rawSecB) then
                    secondaryColor = { rawSecR, rawSecG, rawSecB, secret = true, source = "condborder-state-typebox" }
                else
                    local secR = CoerceRaidTintChannel(rawSecR)
                    local secG = CoerceRaidTintChannel(rawSecG)
                    local secB = CoerceRaidTintChannel(rawSecB)
                    if secR ~= nil and secG ~= nil and secB ~= nil then
                        secondaryColor = { secR, secG, secB }
                    end
                end
            end
            if not secondaryColor then
                local secR, secG, secB = ParseRaidRGBText(state.typeBoxRGB)
                if secR ~= nil and secG ~= nil and secB ~= nil then
                    secondaryColor = { secR, secG, secB }
                end
            end

            local r, g, b = ParseRaidRGBText(state.barTintRGB)
            if r == nil then
                r, g, b = ParseRaidRGBText(state.tintRGB)
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
                local frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor = GetRaidHazardHintFromPlayerFrameCondTint()
                if frameEnum and frameEnum ~= RAID_HAZARD_ENUM.Unknown then
                    return frameEnum, frameR, frameG, frameB, "playerframe-fallback:" .. tostring(frameSource), frameSecretColor, secondaryEnum, secondaryColor
                end
                if type(frameSecretColor) == "table" and frameSecretColor.secret == true then
                    return RAID_HAZARD_ENUM.Unknown, nil, nil, nil, "playerframe-fallback-secret", frameSecretColor, secondaryEnum, secondaryColor
                end
                if r ~= nil and g ~= nil and b ~= nil then
                    return RAID_HAZARD_ENUM.Unknown, r, g, b, "condborder-state-unknown-rgb", nil, secondaryEnum, secondaryColor
                end
                if frameEnum == RAID_HAZARD_ENUM.Unknown then
                    return RAID_HAZARD_ENUM.Unknown, frameR, frameG, frameB, "playerframe-fallback-unknown", nil, secondaryEnum, secondaryColor
                end
                return RAID_HAZARD_ENUM.Unknown, nil, nil, nil, "condborder-state-unknown", nil, secondaryEnum, secondaryColor
            end
        end
    end

    local frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor = GetRaidHazardHintFromPlayerFrameCondTint()
    return frameEnum, frameR, frameG, frameB, frameSource, frameSecretColor, nil, nil
end

local function GetRaidHazardIconAtlas(enum)
    local normalized = NormalizeRaidHazardEnum(enum)
    if normalized == RAID_HAZARD_ENUM.Magic then
        return "RaidFrame-Icon-DebuffMagic"
    elseif normalized == RAID_HAZARD_ENUM.Curse then
        return "RaidFrame-Icon-DebuffCurse"
    elseif normalized == RAID_HAZARD_ENUM.Disease then
        return "RaidFrame-Icon-DebuffDisease"
    elseif normalized == RAID_HAZARD_ENUM.Poison then
        return "RaidFrame-Icon-DebuffPoison"
    elseif normalized == RAID_HAZARD_ENUM.Bleed then
        return "RaidFrame-Icon-DebuffBleed"
    end
    return nil
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

local GROUP_COLORS = {
    { r = 0.90, g = 0.20, b = 0.20 }, -- 1
    { r = 0.90, g = 0.55, b = 0.15 }, -- 2
    { r = 0.85, g = 0.85, b = 0.20 }, -- 3
    { r = 0.20, g = 0.80, b = 0.30 }, -- 4
    { r = 0.20, g = 0.65, b = 0.90 }, -- 5
    { r = 0.45, g = 0.35, b = 0.90 }, -- 6
    { r = 0.80, g = 0.30, b = 0.80 }, -- 7
    { r = 0.60, g = 0.60, b = 0.60 }, -- 8
}

local function GetEffectiveRaidFrameSize(perRow)
    local uiW = (UIParent and UIParent:GetWidth()) or 1920
    local uiH = (UIParent and UIParent:GetHeight()) or 1080
    local margin = 80
    local cols = math.max(1, perRow or config.columns or 5)
    local visibleCount = 30
    if IsInRaid() and GetNumGroupMembers then
        local n = GetNumGroupMembers()
        if n and n > 0 then visibleCount = n end
    end

    -- Scale is applied via SetScale on the anchor, so account for it when
    -- computing the screen-space budget available for frame dimensions.
    local scale = (config.scale or 100) / 100
    if scale <= 0 then scale = 1 end
    local availW = math.max(200, (uiW - margin) / scale)
    local availH = math.max(200, (uiH - margin) / scale)

    local rows, maxW, maxH
    if config.verticalFill then
        -- Vertical fill: cols = number of columns, perCol = units per column
        local perCol = cols
        local numCols = math.max(1, math.ceil(visibleCount / perCol))
        rows = perCol
        maxW = (availW - (config.spacingX * (numCols - 1))) / numCols
        maxH = (availH - (config.spacingY * (rows - 1))) / rows
    else
        rows = math.max(1, math.ceil(visibleCount / cols))
        maxW = (availW - (config.spacingX * (cols - 1))) / cols
        maxH = (availH - (config.spacingY * (rows - 1))) / rows
    end

    local baseW = config.width or 92
    local baseH = config.height or 24
    local w = math.max(40, math.min(baseW, math.floor(maxW)))
    local h = math.max(16, math.min(baseH, math.floor(maxH)))
    return w, h
end

local ResolveRaidColumns

local function GetMaxColumnsAllowed()
    local uiW = (UIParent and UIParent:GetWidth()) or 1920
    local margin = 80
    local scale = (config.scale or 100) / 100
    if scale <= 0 then scale = 1 end
    local availW = math.max(200, (uiW - margin) / scale)
    local baseW = config.width or 92
    local maxCols = math.max(1, math.floor((availW + config.spacingX) / (baseW + config.spacingX)))
    return maxCols
end

local function GetMaxHeightAllowed()
    local uiH = (UIParent and UIParent:GetHeight()) or 1080
    local margin = 80
    local scale = (config.scale or 100) / 100
    if scale <= 0 then scale = 1 end
    local availH = math.max(200, (uiH - margin) / scale)
    local cols = math.max(1, config.columns or 5)
    local visibleCount = 30
    if IsInRaid() and GetNumGroupMembers then
        local n = GetNumGroupMembers()
        if n and n > 0 then visibleCount = n end
    end
    local rows = math.max(1, math.ceil(visibleCount / cols))
    local groupBreaks = 0
    local maxH = (availH - (config.spacingY * (rows - 1))) / rows
    return math.max(16, math.floor(maxH))
end

_G.MidnightUI_GetRaidMaxHeight = function()
    return GetMaxHeightAllowed()
end

ResolveRaidColumns = function(requested)
    local minW = 60
    local uiW = (UIParent and UIParent:GetWidth()) or 1920
    local margin = 80
    local availW = math.max(200, uiW - margin)
    local maxColsByWidth = math.max(1, math.floor((availW + config.spacingX) / (minW + config.spacingX)))

    local cols = math.max(1, requested or config.columns or 5)
    cols = math.min(cols, maxColsByWidth)

    return cols
end

_G.MidnightUI_GetRaidMaxColumns = function()
    return GetMaxColumnsAllowed()
end

local function ClampRaidAnchorToScreen()
    if not RaidAnchor then return end
    local uiW = (UIParent and UIParent:GetWidth()) or 1920
    local uiH = (UIParent and UIParent:GetHeight()) or 1080
    local left = RaidAnchor:GetLeft()
    local right = RaidAnchor:GetRight()
    local top = RaidAnchor:GetTop()
    local bottom = RaidAnchor:GetBottom()
    if not (left and right and top and bottom) then return end
    local dx = 0
    local dy = 0
    if left < 0 then dx = -left end
    if right > uiW then dx = dx - (right - uiW) end
    if top > uiH then dy = dy - (top - uiH) end
    if bottom < 0 then dy = dy - bottom end
    if dx ~= 0 or dy ~= 0 then
        local point, _, relativePoint, xOfs, yOfs = RaidAnchor:GetPoint()
        if not point then point, relativePoint, xOfs, yOfs = "TOPLEFT", "TOPLEFT", 0, 0 end
        RaidAnchor:ClearAllPoints()
        RaidAnchor:SetPoint(point, UIParent, relativePoint, (xOfs or 0) + dx, (yOfs or 0) + dy)
        if MidnightUISettings and MidnightUISettings.RaidFrames then
            MidnightUISettings.RaidFrames.position = { point, relativePoint, (xOfs or 0) + dx, (yOfs or 0) + dy }
        end
    end
end

local function ApplyRaidConfigFromSettings()
    if not MidnightUISettings or not MidnightUISettings.RaidFrames then return end
    local s = MidnightUISettings.RaidFrames
    if s.width then config.width = s.width end
    if s.height then config.height = s.height end
    if s.columns then config.columns = s.columns end
    if s.spacingX then config.spacingX = s.spacingX end
    if s.spacingY then config.spacingY = s.spacingY end
    if s.groupBy ~= nil then config.groupBy = s.groupBy end
    if s.colorByGroup ~= nil then config.colorByGroup = s.colorByGroup end
    if s.groupBrackets ~= nil then config.groupBrackets = s.groupBrackets end
    if s.verticalFill ~= nil then config.verticalFill = s.verticalFill end
    if s.scale then config.scale = s.scale end
    local maxColsCurrent = GetMaxColumnsAllowed()
    if config.columns > maxColsCurrent then
        config.columns = maxColsCurrent
        MidnightUISettings.RaidFrames.columns = maxColsCurrent
    end
    local maxHCurrent = GetMaxHeightAllowed()
    if config.height > maxHCurrent then
        config.height = maxHCurrent
        MidnightUISettings.RaidFrames.height = maxHCurrent
    end
end

local function GetRaidGroupIndex(unit)
    if not unit then return nil end
    local idx = tonumber(string.match(unit, "raid(%d+)$"))
    if not idx then return nil end
    local ok, _, _, group = pcall(GetRaidRosterInfo, idx)
    if ok and group then return group end
    return nil
end

local function GetCachedRaidBarColor(healthBar)
    if not healthBar then
        return nil, nil, nil
    end
    local r = CoerceRaidTintChannel(healthBar._muiLastSafeColorR)
    local g = CoerceRaidTintChannel(healthBar._muiLastSafeColorG)
    local b = CoerceRaidTintChannel(healthBar._muiLastSafeColorB)
    if r == nil or g == nil or b == nil then
        return nil, nil, nil
    end
    return r, g, b
end

local function SetRaidHealthBarColor(healthBar, r, g, b, a)
    if not healthBar or type(healthBar.SetStatusBarColor) ~= "function" then
        return
    end
    healthBar:SetStatusBarColor(r, g, b, a)
    local safeR = CoerceRaidTintChannel(r)
    local safeG = CoerceRaidTintChannel(g)
    local safeB = CoerceRaidTintChannel(b)
    if safeR ~= nil and safeG ~= nil and safeB ~= nil then
        healthBar._muiLastSafeColorR = safeR
        healthBar._muiLastSafeColorG = safeG
        healthBar._muiLastSafeColorB = safeB
    end
end

local function SetRaidRenderedSecretPolish(healthBar, suppressed)
    if not healthBar then
        return
    end
    if suppressed ~= true then
        healthBar._muiRaidSecretRenderedPolish = false
        return
    end
    if healthBar._muiTopHighlight then
        pcall(healthBar._muiTopHighlight.SetBlendMode, healthBar._muiTopHighlight, "ADD")
        healthBar._muiTopHighlight:SetGradient("VERTICAL",
            CreateColor(0.09, 0.09, 0.09, 1),
            CreateColor(0.00, 0.00, 0.00, 1))
        healthBar._muiTopHighlight:Show()
    end
    if healthBar._muiBottomShade then
        pcall(healthBar._muiBottomShade.SetBlendMode, healthBar._muiBottomShade, "ADD")
        healthBar._muiBottomShade:SetGradient("VERTICAL",
            CreateColor(0.00, 0.00, 0.00, 1),
            CreateColor(0.09, 0.09, 0.09, 1))
        healthBar._muiBottomShade:Show()
    end
    if healthBar._muiSpecular then
        healthBar._muiSpecular:Hide()
    end
    healthBar._muiRaidSecretRenderedPolish = true
end

-- =========================================================================
-- RAID BAR STYLING — rebuilt from scratch, mirroring PlayerFrame.lua
-- =========================================================================

local function ApplyHealthBarStyle(healthBar)
    if not healthBar then return end

    -- ── Inner: polished barrel gradient (identical to PlayerFrame) ────
    local function ApplyPolishedGradient(tex)
        local anchor = tex or healthBar
        local baseR, baseG, baseB = healthBar:GetStatusBarColor()
        local baseIsSecret = false
        if type(issecretvalue) == "function" then
            local okR, secR = pcall(issecretvalue, baseR)
            local okG, secG = pcall(issecretvalue, baseG)
            local okB, secB = pcall(issecretvalue, baseB)
            baseIsSecret = (okR and secR == true) or (okG and secG == true) or (okB and secB == true)
        end
        if type(baseR) ~= "number" or baseIsSecret then
            local fr = tonumber(healthBar._muiStyleFallbackR)
            local fg = tonumber(healthBar._muiStyleFallbackG)
            local fb = tonumber(healthBar._muiStyleFallbackB)
            if fr and fg and fb then
                if fr < 0 then fr = 0 elseif fr > 1 then fr = 1 end
                if fg < 0 then fg = 0 elseif fg > 1 then fg = 1 end
                if fb < 0 then fb = 0 elseif fb > 1 then fb = 1 end
                baseR, baseG, baseB = fr, fg, fb
            else
                baseR, baseG, baseB = 0.5, 0.5, 0.5
            end
        end
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
        if not healthBar._muiTopHighlight then
            healthBar._muiTopHighlight = healthBar:CreateTexture(nil, "ARTWORK", nil, 2)
        end
        healthBar._muiTopHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
        healthBar._muiTopHighlight:SetBlendMode("DISABLE")
        if not healthBar._muiBottomShade then
            healthBar._muiBottomShade = healthBar:CreateTexture(nil, "ARTWORK", nil, 1)
        end
        healthBar._muiBottomShade:SetTexture("Interface\\Buttons\\WHITE8X8")
        healthBar._muiBottomShade:SetBlendMode("DISABLE")
        if not healthBar._muiSpecular then
            healthBar._muiSpecular = healthBar:CreateTexture(nil, "ARTWORK", nil, 3)
        end
        healthBar._muiSpecular:SetTexture("Interface\\Buttons\\WHITE8X8")
        healthBar._muiSpecular:SetBlendMode("ADD")
        local rawH = (healthBar.GetHeight and healthBar:GetHeight()) or 2
        local h = tonumber(tostring(rawH)) or 2
        local topH = math.max(1, h * 0.45)
        local botH = math.max(1, h * 0.58)
        local specH = math.max(1, h * 0.35)
        healthBar._muiTopHighlight:ClearAllPoints()
        healthBar._muiTopHighlight:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
        healthBar._muiTopHighlight:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        healthBar._muiTopHighlight:SetHeight(topH)
        healthBar._muiTopHighlight:SetGradient("VERTICAL",
            CreateColor(midR, midG, midB, 1),
            CreateColor(edgeR, edgeG, edgeB, 1))
        healthBar._muiBottomShade:ClearAllPoints()
        healthBar._muiBottomShade:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
        healthBar._muiBottomShade:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        healthBar._muiBottomShade:SetHeight(botH)
        healthBar._muiBottomShade:SetGradient("VERTICAL",
            CreateColor(edgeR, edgeG, edgeB, 1),
            CreateColor(midR, midG, midB, 1))
        healthBar._muiSpecular:ClearAllPoints()
        healthBar._muiSpecular:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
        healthBar._muiSpecular:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        healthBar._muiSpecular:SetHeight(specH)
        healthBar._muiSpecular:SetGradient("VERTICAL",
            CreateColor(1, 1, 1, 0),
            CreateColor(1, 1, 1, 0.06))
        healthBar._muiTopHighlight:Show()
        healthBar._muiBottomShade:Show()
        healthBar._muiSpecular:Show()
    end

    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    if style == "Gradient" then
        healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local tex = healthBar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
        end
        ApplyPolishedGradient(tex)
        if healthBar._muiFlatGradient then healthBar._muiFlatGradient:Hide() end
        return
    end
    -- Simple / flat style
    healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = healthBar:GetStatusBarTexture()
    if tex then
        tex:SetHorizTile(false)
        tex:SetVertTile(false)
    end
    if not healthBar._muiFlatGradient then
        healthBar._muiFlatGradient = healthBar:CreateTexture(nil, "ARTWORK")
        healthBar._muiFlatGradient:SetAllPoints(tex or healthBar)
        healthBar._muiFlatGradient:SetBlendMode("DISABLE")
    end
    healthBar._muiFlatGradient:SetGradient("VERTICAL", CreateColor(1, 1, 1, 0.06), CreateColor(0, 0, 0, 0.12))
    healthBar._muiFlatGradient:Show()
    if healthBar._muiTopHighlight then healthBar._muiTopHighlight:Hide() end
    if healthBar._muiBottomShade then healthBar._muiBottomShade:Hide() end
    if healthBar._muiSpecular then healthBar._muiSpecular:Hide() end
end

-- Atomic color + style application (mirrors PlayerFrame.ApplyNumericColorToStatusBar)
local function ApplyRaidBarColor(healthBar, r, g, b)
    if not healthBar then return end
    local nr = (type(r) == "number" and r) or 0
    local ng = (type(g) == "number" and g) or 0
    local nb = (type(b) == "number" and b) or 0
    if nr < 0 then nr = 0 elseif nr > 1 then nr = 1 end
    if ng < 0 then ng = 0 elseif ng > 1 then ng = 1 end
    if nb < 0 then nb = 0 elseif nb > 1 then nb = 1 end
    -- Store fallback for gradient to read when StatusBar color is restricted
    healthBar._muiStyleFallbackR = nr
    healthBar._muiStyleFallbackG = ng
    healthBar._muiStyleFallbackB = nb
    healthBar:SetStatusBarColor(nr, ng, nb, 1.0)
    ApplyHealthBarStyle(healthBar)
    -- Neutralize vertex color to white (SetVertexColor multiplies with SetStatusBarColor)
    local tex = healthBar.GetStatusBarTexture and healthBar:GetStatusBarTexture()
    if tex then
        tex:SetVertexColor(1, 1, 1, 1)
    end
end

local function TruncateName(name, maxChars)
    if not name then return "" end
    if #name <= maxChars then return name end
    return string.sub(name, 1, maxChars)
end

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        local raidTextSize = math.max(6, math.floor(((MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.textSize) or 9) + 0.5))
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = raidTextSize,
            healthFont = "Fonts\\FRIZQT__.TTF",
            healthSize = raidTextSize,
            nameShadowAlpha = 0.9,
            healthShadowAlpha = 0.9,
        })
        return
    end

    local nameSize, hpSize = GetRaidTextSizes()
    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", nameSize, "OUTLINE")
    SetFontSafe(frame.hpText, "Fonts\\FRIZQT__.TTF", hpSize, "OUTLINE")
    frame.nameText:SetShadowOffset(0, 0); frame.nameText:SetShadowColor(0, 0, 0, 0)
    frame.hpText:SetShadowOffset(0, 0); frame.hpText:SetShadowColor(0, 0, 0, 0)
end

local function UpdateRaidRangeForFrame(frame)
    local unit = frame:GetAttribute("unit")
    if UnitExists(unit) then
        local inRange = true
        local ok, val = pcall(UnitInRange, unit)
        if ok then
            local okBool = pcall(function()
                if val == true then inRange = true elseif val == false then inRange = false else error("non-bool") end
            end)
            if not okBool then ok = false end
        end
        if not ok then
            local ok2, distOk = pcall(CheckInteractDistance, unit, 4)
            if ok2 then
                pcall(function()
                    if distOk == true then inRange = true elseif distOk == false then inRange = false end
                end)
            end
        end
        if not inRange and UnitIsUnit(unit, "player") then
            inRange = true
        end
        frame:SetAlpha(inRange and config.inRangeAlpha or config.rangeAlpha)
    else
        frame:SetAlpha(config.inRangeAlpha)
    end
end

local function UpdateRaidRanges()
    if InCombatLockdown and InCombatLockdown() then return end
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame and frame:IsShown() then
            UpdateRaidRangeForFrame(frame)
        end
    end
end

local function EnsureRaidRangeTicker()
    if RaidRangeTicker then return end
    RaidRangeTicker = C_Timer.NewTicker(0.2, UpdateRaidRanges)
end

local function StopRaidRangeTicker()
    if not RaidRangeTicker then return end
    RaidRangeTicker:Cancel()
    RaidRangeTicker = nil
end

-- =========================================================================
--  RAID LIVE DEBUFF PREVIEW
-- =========================================================================

local function RaidPreviewChat(msg)
    local text = "|cff66ccffMidnightUI RaidLive:|r " .. tostring(msg or "")
    if DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
        DEFAULT_CHAT_FRAME:AddMessage(text)
    else
        print(text)
    end
end

local function EnsureRaidCombatDebuffSettings()
    if not MidnightUISettings then
        MidnightUISettings = {}
    end
    if not MidnightUISettings.Combat then
        MidnightUISettings.Combat = {}
    end
    local combat = MidnightUISettings.Combat
    if combat.debuffOverlayGlobalEnabled == nil then
        combat.debuffOverlayGlobalEnabled = true
    end
    if combat.debuffOverlayRaidEnabled == nil then
        combat.debuffOverlayRaidEnabled = true
    end
    return combat
end

local function IsRaidDebuffOverlayEnabled()
    local combat = EnsureRaidCombatDebuffSettings()
    if combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    if combat.debuffOverlayRaidEnabled == false then
        return false
    end
    return true
end

local function IsRaidDebuffVisualsEnabled()
    if not IsRaidDebuffOverlayEnabled() then
        return false
    end
    if IsInRaid and IsInRaid() then
        return true
    end
    return RaidLivePreviewState.active == true
end

local function RaidIconKind(iconToken)
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

local function SetRaidIconTexCoord(texture, usingAtlas)
    if not texture or not texture.SetTexCoord then
        return
    end
    if usingAtlas then
        texture:SetTexCoord(0, 1, 0, 1)
    else
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function EnsureRaidDebuffPreviewWidgets(frame)
    if not frame then
        return nil
    end
    if frame._muiRaidDebuffPreview then
        return frame._muiRaidDebuffPreview
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
    iconHolder:SetPoint("RIGHT", frame, "RIGHT", -2, RAID_DEBUFF_PREVIEW.offsetY)
    iconHolder:SetSize((RAID_DEBUFF_PREVIEW.iconSize + 2) * RAID_DEBUFF_PREVIEW.maxIcons, RAID_DEBUFF_PREVIEW.iconSize + 2)
    iconHolder:Hide()

    local function CreateIconButton(index)
        local btn = CreateFrame("Frame", nil, iconHolder, "BackdropTemplate")
        btn:SetSize(RAID_DEBUFF_PREVIEW.iconSize, RAID_DEBUFF_PREVIEW.iconSize)
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
        SetRaidIconTexCoord(icon, false)
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
    for i = 1, RAID_DEBUFF_PREVIEW.maxIcons do
        local btn = CreateIconButton(i)
        btn:SetPoint("RIGHT", iconHolder, "RIGHT", -((i - 1) * (RAID_DEBUFF_PREVIEW.iconSize + 2)), 0)
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
    frame._muiRaidDebuffPreview = preview
    return preview
end

local function SetRaidHPTextInset(frame, inset)
    if not frame or not frame.hpText then
        return
    end
    local value = tonumber(inset) or 0
    if value < 0 then
        value = 0
    end
    value = math.floor(value + 0.5)
    if frame._muiRaidHpTextInset == value then
        return
    end
    frame._muiRaidHpTextInset = value
    local owner = frame.barFrame or frame
    frame.hpText:ClearAllPoints()
    frame.hpText:SetPoint("RIGHT", owner, "RIGHT", -4 - value, 0)
end

local function GetRaidFrameClassColor(frame, unit)
    if frame and type(frame._muiClassColor) == "table" then
        local r = CoerceRaidTintChannel(frame._muiClassColor.r or frame._muiClassColor[1])
        local g = CoerceRaidTintChannel(frame._muiClassColor.g or frame._muiClassColor[2])
        local b = CoerceRaidTintChannel(frame._muiClassColor.b or frame._muiClassColor[3])
        if r ~= nil and g ~= nil and b ~= nil then
            return r, g, b
        end
    end

    local _, class = UnitClass(unit)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.ClassColorsExact and class and _G.MidnightUI_Core.ClassColorsExact[class] then
        local c = _G.MidnightUI_Core.ClassColorsExact[class]
        return CoerceRaidTintChannel(c.r) or 0.5, CoerceRaidTintChannel(c.g) or 0.5, CoerceRaidTintChannel(c.b) or 0.5
    elseif class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return CoerceRaidTintChannel(c.r) or 0.5, CoerceRaidTintChannel(c.g) or 0.5, CoerceRaidTintChannel(c.b) or 0.5
    end
    return 0.5, 0.5, 0.5
end

local function RestoreRaidHealthBarBaseState(frame, unit)
    if not frame or not frame.healthBar or not frame.healthBar:IsShown() then
        return
    end

    local classR, classG, classB = GetRaidFrameClassColor(frame, unit)
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
        barR, barG, barB, alpha = classR, classG, classB, 1
        if frame.healthBg and frame.healthBg.SetColorTexture then
            local bgR = classR
            local bgG = classG
            local bgB = classB
            if incomingRes then
                bgR, bgG, bgB = bgR / 1.2, bgG / 1.2, bgB / 1.2
            end
            frame.healthBg:SetColorTexture(bgR * 0.25, bgG * 0.25, bgB * 0.25, 0.90)
        end
    end

    ApplyRaidBarColor(frame.healthBar, barR, barG, barB)
    SetRaidRenderedSecretPolish(frame.healthBar, false)
end

local function ClearRaidDebuffPreviewForFrame(frame)
    if not frame or not frame._muiRaidDebuffPreview then
        return
    end
    local preview = frame._muiRaidDebuffPreview
    if preview.overlay then
        preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
        if preview.overlay.fill then
            preview.overlay.fill:SetVertexColor(0, 0, 0, 0)
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
    SetRaidHPTextInset(frame, 0)
end

local function LayoutRaidDebuffSweep(preview, frame)
    if not preview or not frame or not preview.sweep or not preview.sweepFx then
        return
    end
    preview.sweep:ClearAllPoints()
    preview.sweep:SetAllPoints(preview.overlay or frame)

    local width = tonumber(frame:GetWidth()) or 0
    local height = tonumber(frame:GetHeight()) or 0
    if width <= 1 then
        width = tonumber(config.width) or 92
    end
    if height <= 1 then
        height = tonumber(config.height) or 24
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

local function SetRaidDebuffSweepColor(preview, enum, overrideColor)
    if not preview or not preview.sweepBands then
        return
    end
    local color = overrideColor
    if type(color) ~= "table" then
        color = GetRaidHazardColor(enum) or RAID_HAZARD_COLORS[RAID_HAZARD_ENUM.Unknown]
    end
    if not color then
        return
    end
    local normalized = NormalizeRaidHazardEnum(enum)
    local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
    if IsRaidSecretColor(color) then
        bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
    elseif normalized == RAID_HAZARD_ENUM.Unknown then
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

local function SetRaidDebuffSweepVisible(preview, isVisible)
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

local function GetRaidLiveBridgeBaseUnits()
    local units = {}
    if UnitExists("player") then
        units[#units + 1] = "player"
    end
    for i = 1, 4 do
        local token = "party" .. tostring(i)
        if UnitExists(token) then
            units[#units + 1] = token
        end
    end
    return units
end

local function GetRaidLiveBridgeUnits(expandToCount)
    local baseUnits = GetRaidLiveBridgeBaseUnits()
    local baseCount = #baseUnits
    if baseCount < 1 then
        return {}, 0
    end
    local wanted = tonumber(expandToCount) or baseCount
    wanted = math.floor(wanted + 0.5)
    if wanted < baseCount then
        wanted = baseCount
    end
    if wanted > (config.maxFrames or 40) then
        wanted = config.maxFrames or 40
    end
    local units = {}
    for i = 1, wanted do
        units[i] = baseUnits[((i - 1) % baseCount) + 1]
    end
    return units, baseCount
end

local function ApplyRaidLiveBridgeUnitBindings()
    if InCombatLockdown and InCombatLockdown() then
        return false, 0
    end
    EnsureRaidFrames(RaidLivePreviewState.bridgeFrameCount)
    local bridgeUnits, baseCount = GetRaidLiveBridgeUnits(RaidLivePreviewState.bridgeFrameCount)
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame and frame.SetAttribute then
            if frame._muiRaidOriginalUnit == nil then
                frame._muiRaidOriginalUnit = frame:GetAttribute("unit")
            end
            local desiredUnit = bridgeUnits[i]
            if not desiredUnit then
                desiredUnit = frame._muiRaidOriginalUnit or ("raid" .. tostring(i))
            end
            local currentUnit = frame:GetAttribute("unit")
            if currentUnit ~= desiredUnit then
                local okSet, errSet = pcall(frame.SetAttribute, frame, "unit", desiredUnit)
                if not okSet then
                    RaidDiag("bridgeSetAttrFail frame=" .. tostring(i) .. " unit=" .. tostring(desiredUnit) .. " err=" .. tostring(errSet))
                end
            end
        end
    end
    return true, #bridgeUnits, baseCount
end

local function RestoreRaidLiveUnitBindings()
    if InCombatLockdown and InCombatLockdown() then
        RaidLivePreviewState.pendingRestore = true
        RaidDiag("state=PENDING_RESTORE")
        return false
    end
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame and frame.SetAttribute and frame._muiRaidOriginalUnit then
            local desiredUnit = frame._muiRaidOriginalUnit
            local currentUnit = frame:GetAttribute("unit")
            if currentUnit ~= desiredUnit then
                local okSet, errSet = pcall(frame.SetAttribute, frame, "unit", desiredUnit)
                if not okSet then
                    RaidDiag("restoreSetAttrFail frame=" .. tostring(i) .. " unit=" .. tostring(desiredUnit) .. " err=" .. tostring(errSet))
                end
            end
        end
        if frame then
            frame._muiRaidLiveLastSig = nil
        end
    end
    RaidLivePreviewState.pendingRestore = false
    return true
end

local function CollectRaidDebuffPreviewState(unit)
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

    local blizzEntry = _raidBlizzAuraCache[unit]
    if type(blizzEntry) == "table" then
        if type(blizzEntry.debuffs) ~= "table" then blizzEntry.debuffs = {} end
        if type(blizzEntry.dispellable) ~= "table" then blizzEntry.dispellable = {} end
        if type(blizzEntry.types) ~= "table" then blizzEntry.types = {} end
        if type(blizzEntry.icons) ~= "table" then blizzEntry.icons = {} end
        if type(blizzEntry.stacks) ~= "table" then blizzEntry.stacks = {} end
        state.blizzAvail = "YES"
        state.blizzDebuffs = CountRaidBlizzAuraSet(blizzEntry.debuffs)
        state.blizzDispellable = CountRaidBlizzAuraSet(blizzEntry.dispellable)
    else
        blizzEntry = nil
    end

    local function AddHazard(enum)
        local normalized = NormalizeRaidHazardEnum(enum)
        if not normalized or normalized == RAID_HAZARD_ENUM.Unknown then
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
        local hasIcon = CanUseRaidIconToken(iconToken)
        if hasIcon then
            state.iconHits = state.iconHits + 1
        end
        if (#state.entries < RAID_DEBUFF_PREVIEW.maxIcons) and (hasIcon or enum) then
            state.entries[#state.entries + 1] = {
                icon = hasIcon and iconToken or nil,
                enum = NormalizeRaidHazardEnum(enum),
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
        return ResolveRaidHazardFromAuraInstanceID(unit, auraIID, hint)
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
            local enum, source = ResolveRaidHazardFromAura(unit, aura)
            if (not enum or enum == RAID_HAZARD_ENUM.Unknown) and auraIID then
                enum, source = ResolveAuraTypeFromCache(auraIID)
            end
            if enum and enum ~= RAID_HAZARD_ENUM.Unknown then
                RecordTyped(source)
                AddHazard(enum)
            end

            local iconToken = aura.icon or aura.iconFileID
            local hasIcon = CanUseRaidIconToken(iconToken)
            local stackCount = aura.applications or aura.stackCount or aura.charges
            if (stackCount == nil) and blizzEntry and auraIID then
                stackCount = blizzEntry.stacks and blizzEntry.stacks[auraIID] or nil
            end

            if (not hasIcon) and blizzEntry and auraIID then
                local cachedIcon = blizzEntry.icons and blizzEntry.icons[auraIID] or nil
                if CanUseRaidIconToken(cachedIcon) then
                    iconToken = cachedIcon
                    hasIcon = true
                end
            end
            if (not hasIcon) and auraIID and C_UnitAuras and C_UnitAuras.GetAuraDataByAuraInstanceID then
                local fallbackAura = ReadAuraByIID(auraIID)
                if fallbackAura then
                    iconToken = fallbackAura.icon or fallbackAura.iconFileID
                    hasIcon = CanUseRaidIconToken(iconToken)
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
                    if enum and enum ~= RAID_HAZARD_ENUM.Unknown then
                        RecordTyped(source)
                        AddHazard(enum)
                    end

                    local iconToken = blizzEntry.icons and blizzEntry.icons[auraIID] or nil
                    local stackCount = blizzEntry.stacks and blizzEntry.stacks[auraIID] or nil
                    if (not CanUseRaidIconToken(iconToken)) then
                        local fallbackAura = ReadAuraByIID(auraIID)
                        if fallbackAura then
                            iconToken = fallbackAura.icon or fallbackAura.iconFileID
                            if stackCount == nil then
                                stackCount = fallbackAura.applications or fallbackAura.stackCount or fallbackAura.charges
                            end
                        end
                    end

                    AddEntry(iconToken, enum, auraIID, nil, stackCount)
                    if #state.entries >= RAID_DEBUFF_PREVIEW.maxIcons and state.primary and state.secondary then
                        -- Keep collecting hazards, but avoid excessive fallback reads once preview is saturated.
                        -- (No break here to preserve deterministic hazard promotion for remaining cached entries.)
                    end
                end
            end
        end
        AddFromAuraSet(blizzEntry.dispellable)
        AddFromAuraSet(blizzEntry.debuffs)
    end

    if not state.primary and #state.entries > 0 then
        for _, entry in ipairs(state.entries) do
            if entry.enum and entry.enum ~= RAID_HAZARD_ENUM.Unknown then
                state.primary = entry.enum
                break
            end
        end
    end
    if not state.primary and #state.entries > 0 then
        state.primary = RAID_HAZARD_ENUM.Unknown
    end
    if not state.secondary and #state.entries > 1 then
        state.secondary = RAID_HAZARD_ENUM.Unknown
    end
    return state
end

local function GetRaidDebuffNow()
    if type(GetTime) == "function" then
        local okNow, now = pcall(GetTime)
        if okNow and type(now) == "number" then
            return now
        end
    end
    return 0
end

local function ApplyRaidStickyHazardFallback(frame, primaryEnum, secondaryEnum, primaryColor, inRestricted, holdStickyForUnknown)
    local normalizedPrimary = NormalizeRaidHazardEnum(primaryEnum)
    local normalizedSecondary = NormalizeRaidHazardEnum(secondaryEnum)
    if normalizedSecondary == normalizedPrimary then
        normalizedSecondary = nil
    end

    local resolvedPrimaryColor = CloneRaidColor(primaryColor)
    local now = GetRaidDebuffNow()

    if normalizedPrimary and normalizedPrimary ~= RAID_HAZARD_ENUM.Unknown then
        frame._muiRaidStickyPrimary = normalizedPrimary
        frame._muiRaidStickySecondary = (normalizedSecondary and normalizedSecondary ~= RAID_HAZARD_ENUM.Unknown) and normalizedSecondary or nil
        frame._muiRaidStickyAt = now
        if not resolvedPrimaryColor then
            resolvedPrimaryColor = CloneRaidColor(RAID_HAZARD_COLORS[normalizedPrimary])
        end
        frame._muiRaidStickyPrimaryColor = CloneRaidColor(resolvedPrimaryColor)
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
    end

    local stickyPrimary = NormalizeRaidHazardEnum(frame._muiRaidStickyPrimary)
    local stickySecondary = NormalizeRaidHazardEnum(frame._muiRaidStickySecondary)
    local stickyColor = CloneRaidColor(frame._muiRaidStickyPrimaryColor)
    local stickyAt = tonumber(frame._muiRaidStickyAt) or 0
    local stickyFresh = stickyPrimary
        and now > 0
        and stickyAt > 0
        and (now - stickyAt) <= RAID_HAZARD_STICKY_SEC

    if stickyPrimary and (stickyFresh or holdStickyForUnknown) then
        if (not normalizedPrimary) or normalizedPrimary == RAID_HAZARD_ENUM.Unknown then
            normalizedPrimary = stickyPrimary
            resolvedPrimaryColor = stickyColor or resolvedPrimaryColor
        end
        if (not normalizedSecondary or normalizedSecondary == RAID_HAZARD_ENUM.Unknown or normalizedSecondary == normalizedPrimary)
            and stickySecondary
            and stickySecondary ~= normalizedPrimary then
            normalizedSecondary = stickySecondary
        end
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, true
    end

    if (not inRestricted) and (not holdStickyForUnknown) and ((not normalizedPrimary) or normalizedPrimary == RAID_HAZARD_ENUM.Unknown) then
        frame._muiRaidStickyPrimary = nil
        frame._muiRaidStickySecondary = nil
        frame._muiRaidStickyAt = nil
        frame._muiRaidStickyPrimaryColor = nil
    end

    return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
end

local function ApplyRaidDebuffPreviewState(frame, state)
    if not frame then
        return
    end
    local preview = EnsureRaidDebuffPreviewWidgets(frame)
    if not preview then
        return
    end
    local unit = frame:GetAttribute("unit")
    if type(unit) ~= "string" or not UnitExists(unit) then
        ClearRaidDebuffPreviewForFrame(frame)
        return
    end

    local primary = state and state.primary or nil
    local secondary = state and state.secondary or nil
    local entries = (state and type(state.entries) == "table") and state.entries or nil
    local overlapCount = (type(entries) == "table") and #entries or 0
    local hasOverlap = false
    local promotedSource = nil
    local promotedR, promotedG, promotedB = nil, nil, nil
    local promotedSecretColor = nil
    local promotedSecondaryColor = nil

    if not primary and overlapCount > 0 then
        primary = RAID_HAZARD_ENUM.Unknown
        promotedSource = "icon-only-entry"
    end
    if (not secondary) and overlapCount > 1 and (not promotedSource) then
        promotedSource = "icon-only-overlap"
    end
    if (not primary) or primary == RAID_HAZARD_ENUM.Unknown then
        local hintEnum, hintR, hintG, hintB, hintSource, hintSecretColor, hintSecondaryEnum, hintSecondaryColor = GetRaidHazardHintFromConditionBorder(unit)
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
            promotedSecondaryColor = CloneRaidColor(hintSecondaryColor) or hintSecondaryColor
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
    elseif primary and primary ~= RAID_HAZARD_ENUM.Unknown then
        stickySeedColor = GetRaidHazardColor(primary)
    end
    local stickyColor = nil
    local stickyApplied = false
    primary, secondary, stickyColor, stickyApplied = ApplyRaidStickyHazardFallback(
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
        secondary = RAID_HAZARD_ENUM.Unknown
        if type(state) == "table" then
            state.secondary = secondary
        end
    end

    hasOverlap = (overlapCount > 1) or ((secondary ~= nil)
        and (secondary ~= primary)
        and (NormalizeRaidHazardEnum(secondary) ~= RAID_HAZARD_ENUM.Unknown))

    local primaryColor = nil
    local primarySecretColor = nil
    local primaryDisplayColor = nil
    if type(promotedSecretColor) == "table" and promotedSecretColor.secret == true then
        primarySecretColor = promotedSecretColor
    end
    if promotedR ~= nil and promotedG ~= nil and promotedB ~= nil then
        primaryColor = { promotedR, promotedG, promotedB }
    elseif not primarySecretColor then
        primaryColor = GetRaidHazardColor(primary)
    end
    if primarySecretColor then
        primaryDisplayColor = { primarySecretColor[1], primarySecretColor[2], primarySecretColor[3] }
    else
        primaryDisplayColor = primaryColor
    end

    if primaryDisplayColor and preview.overlay then
        preview.overlay:SetBackdropBorderColor(primaryDisplayColor[1], primaryDisplayColor[2], primaryDisplayColor[3], 0.95)
        if preview.overlay.fill then
            preview.overlay.fill:SetVertexColor(primaryDisplayColor[1], primaryDisplayColor[2], primaryDisplayColor[3], 0.14)
        end
        preview.overlay:Show()
    else
        if preview.overlay then
            preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
            if preview.overlay.fill then
                preview.overlay.fill:SetVertexColor(0, 0, 0, 0)
            end
            preview.overlay:Hide()
        end
    end

    if primaryDisplayColor and frame.healthBar and frame.healthBar:IsShown() then
        local connected = UnitIsConnected(unit)
        local dead = IsUnitActuallyDead(unit)
        local incomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection(unit)
        if connected and ((not dead) or incomingRes) then
            -- When debuff tinting is active, hide raid health % text for clarity.
            if frame.hpText and frame.hpText.SetText then
                frame.hpText:SetText("")
            end
            local tex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            if primarySecretColor then
                local base = RAID_DEBUFF_TINT_BASE_MUL
                SetRaidHealthBarColor(frame.healthBar, base, base, base, 0.92)
                if tex and tex.SetVertexColor then
                    tex:SetVertexColor(primarySecretColor[1], primarySecretColor[2], primarySecretColor[3], 1.0)
                end
                if frame.healthBg and frame.healthBg.SetColorTexture then
                    frame.healthBg:SetColorTexture(0.10, 0.10, 0.10, 0.65)
                end
            else
                local hr = primaryColor[1] * RAID_DEBUFF_TINT_BASE_MUL
                local hg = primaryColor[2] * RAID_DEBUFF_TINT_BASE_MUL
                local hb = primaryColor[3] * RAID_DEBUFF_TINT_BASE_MUL
                SetRaidHealthBarColor(frame.healthBar, hr, hg, hb, 0.95)
                if tex and tex.SetVertexColor then
                    tex:SetVertexColor(hr, hg, hb, 1.0)
                end
                if frame.healthBg and frame.healthBg.SetColorTexture then
                    frame.healthBg:SetColorTexture(primaryColor[1] * 0.25, primaryColor[2] * 0.25, primaryColor[3] * 0.25, 0.65)
                end
            end
            -- Keep raid bar highlights in-sync with debuff tint (avoids class-color sheen).
            ApplyHealthBarStyle(frame.healthBar)
            SetRaidRenderedSecretPolish(frame.healthBar, primarySecretColor ~= nil)
        end
    else
        RestoreRaidHealthBarBaseState(frame, unit)
    end

    local normalizedSecondary = NormalizeRaidHazardEnum(secondary)
    local secondaryColor = nil
    if hasOverlap and type(promotedSecondaryColor) == "table" then
        secondaryColor = promotedSecondaryColor
    else
        secondaryColor = GetRaidHazardColor(secondary)
        -- In restricted overlap, secondary often resolves as UNKNOWN; prefer the active display tint.
        if hasOverlap and normalizedSecondary == RAID_HAZARD_ENUM.Unknown and type(primaryDisplayColor) == "table" then
            secondaryColor = primaryDisplayColor
        elseif hasOverlap and (not secondaryColor) then
            secondaryColor = primaryDisplayColor or RAID_HAZARD_COLORS[RAID_HAZARD_ENUM.Unknown]
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
        sweepRGB = FormatRaidColorForDiag(secondaryColor)
        if type(promotedSecondaryColor) == "table" and secondaryColor == promotedSecondaryColor then
            sweepSource = "CONDBORDER_SECONDARY"
        elseif normalizedSecondary == RAID_HAZARD_ENUM.Unknown then
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
    LayoutRaidDebuffSweep(preview, frame)
    if hasOverlap and secondaryColor then
        local sweepEnum = secondary
        if (not sweepEnum) and (type(promotedSecondaryColor) ~= "table") then
            sweepEnum = primary or RAID_HAZARD_ENUM.Unknown
        end
        SetRaidDebuffSweepColor(preview, sweepEnum, secondaryColor)
        SetRaidDebuffSweepVisible(preview, true)
    else
        SetRaidDebuffSweepVisible(preview, false)
    end
    frame._muiRaidPromoteSig = nil

    local shownIcons = 0
    local totalEntries = (type(entries) == "table") and #entries or 0
    local frameWidth = tonumber(frame.GetWidth and frame:GetWidth()) or tonumber(config.width) or 92
    local iconSize = RAID_DEBUFF_PREVIEW.iconSize
    local maxVisibleIcons = RAID_DEBUFF_PREVIEW.maxIcons
    if frameWidth <= 84 then
        iconSize = 12
        maxVisibleIcons = 1
    elseif frameWidth <= 108 then
        iconSize = 14
        maxVisibleIcons = 2
    end
    if maxVisibleIcons > RAID_DEBUFF_PREVIEW.maxIcons then
        maxVisibleIcons = RAID_DEBUFF_PREVIEW.maxIcons
    end
    local iconsToShow = math.min(totalEntries, maxVisibleIcons, RAID_DEBUFF_PREVIEW.maxIcons)
    local overflowCount = math.max(0, totalEntries - iconsToShow)

    if preview.iconButtons then
        for i = 1, RAID_DEBUFF_PREVIEW.maxIcons do
            local btn = preview.iconButtons[i]
            if btn then
                btn:SetSize(iconSize, iconSize)
                btn:ClearAllPoints()
                btn:SetPoint("RIGHT", preview.iconHolder, "RIGHT", -((i - 1) * (iconSize + 2)), 0)
            end

            local entry = (entries and i <= iconsToShow) and entries[i] or nil
            if btn and entry then
                btn._muiUnit = unit
                btn.auraInstanceID = entry.auraInstanceID
                btn.auraIndex = entry.auraIndex
                if btn.countText then
                    local stackText = NormalizeRaidAuraStackCount(entry.stackCount)
                    if overflowCount > 0 and i == iconsToShow then
                        stackText = "+" .. tostring(overflowCount)
                    end
                    btn.countText:SetText(stackText)
                end

                local appliedAtlas = false
                local iconToken = entry.icon
                if CanUseRaidIconToken(iconToken) then
                    if btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(iconToken)
                        SetRaidIconTexCoord(btn.icon, false)
                    end
                else
                    local atlas = GetRaidHazardIconAtlas(entry.enum or primary)
                    if atlas and btn.icon and btn.icon.SetAtlas then
                        local okAtlas = pcall(btn.icon.SetAtlas, btn.icon, atlas, false)
                        if okAtlas then
                            SetRaidIconTexCoord(btn.icon, true)
                            appliedAtlas = true
                        end
                    end
                    if not appliedAtlas and btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(RAID_DEBUFF_PREVIEW.placeholderIcon)
                        SetRaidIconTexCoord(btn.icon, false)
                    end
                end

                local iconColor = GetRaidHazardColor(entry.enum or primary)
                if primarySecretColor then
                    local entryEnum = NormalizeRaidHazardEnum(entry.enum)
                    if (not entryEnum) or entryEnum == RAID_HAZARD_ENUM.Unknown then
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
            SetRaidHPTextInset(frame, stripWidth + 2)
        else
            preview.iconHolder:Hide()
            SetRaidHPTextInset(frame, 0)
        end
    end
end

local function UpdateRaidLivePreviewForFrame(frame, source)
    if not frame then
        return
    end
    if not IsRaidDebuffVisualsEnabled() then
        ClearRaidDebuffPreviewForFrame(frame)
        return
    end
    local unit = frame:GetAttribute("unit")
    if type(unit) ~= "string" or not UnitExists(unit) then
        ClearRaidDebuffPreviewForFrame(frame)
        return
    end

    local okCollect, state = pcall(CollectRaidDebuffPreviewState, unit)
    if not okCollect then
        RaidDiag("collectError unit=" .. tostring(unit) .. " src=" .. tostring(source or "unknown") .. " err=" .. tostring(state))
        return
    end
    local okApply, applyErr = pcall(ApplyRaidDebuffPreviewState, frame, state)
    if not okApply then
        RaidDiag("applyError unit=" .. tostring(unit) .. " src=" .. tostring(source or "unknown") .. " err=" .. tostring(applyErr))
        return
    end
    frame._muiRaidLiveLastSig = nil
end

local function RefreshRaidLivePreview(source, targetUnit)
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame and frame:IsShown() then
            local unit = frame:GetAttribute("unit")
            local matches = (targetUnit == nil)
            if not matches then
                matches = (unit == targetUnit)
                if (not matches) and UnitIsUnit and type(unit) == "string" and type(targetUnit) == "string" then
                    local okMatch, sameUnit = pcall(UnitIsUnit, unit, targetUnit)
                    matches = okMatch and sameUnit == true
                end
            end
            if matches then
                UpdateRaidLivePreviewForFrame(frame, source)
            end
        end
    end
end

local function StartRaidDebuffLivePreview(source)
    if RaidLivePreviewState.active then
        RaidPreviewChat("Live preview is already active.")
        return true
    end
    if InCombatLockdown and InCombatLockdown() then
        RaidLivePreviewState.pendingStart = true
        RaidDiag("state=PENDING_START src=" .. tostring(source or "manual"))
        RaidPreviewChat("Cannot start in combat. Start queued for after combat.")
        return false
    end
    RaidLivePreviewState.pendingStart = false
    RaidLivePreviewState.pendingRestore = false
    RaidLivePreviewState.bridgeMode = (not IsInRaid())
    if type(RaidLivePreviewState.bridgeFrameCount) ~= "number" then
        RaidLivePreviewState.bridgeFrameCount = 20
    end
    if RaidLivePreviewState.bridgeFrameCount < 1 then
        RaidLivePreviewState.bridgeFrameCount = 1
    elseif RaidLivePreviewState.bridgeFrameCount > (config.maxFrames or 40) then
        RaidLivePreviewState.bridgeFrameCount = config.maxFrames or 40
    end
    RaidLivePreviewState.active = true
    EnsureRaidBlizzAuraHook()
    EnsureRaidFrames(RaidLivePreviewState.bridgeFrameCount)
    UpdateRaidVisibility()
    RefreshRaidLivePreview("start:" .. tostring(source or "manual"))
    RaidDiag(
        "state=ON src=" .. tostring(source or "manual")
        .. " inRaid=" .. tostring(IsInRaid() == true)
        .. " mode=" .. (RaidLivePreviewState.bridgeMode and "bridge" or "raid")
        .. " bridgeFrames=" .. tostring(RaidLivePreviewState.bridgeFrameCount)
    )
    RaidPreviewChat("Live preview enabled. Check Diagnostics source: RaidLivePreview.")
    return true
end

local function StopRaidDebuffLivePreview(source)
    if not RaidLivePreviewState.active then
        RaidLivePreviewState.pendingStart = false
        RaidLivePreviewState.pendingRestore = false
        RaidPreviewChat("Live preview is already stopped.")
        return false
    end
    RaidLivePreviewState.pendingStart = false
    RaidLivePreviewState.pendingRestore = false
    RaidLivePreviewState.active = false
    for i = 1, config.maxFrames do
        ClearRaidDebuffPreviewForFrame(RaidFrames[i])
        if RaidFrames[i] then
            RaidFrames[i]._muiRaidLiveLastSig = nil
        end
    end
    if not RestoreRaidLiveUnitBindings() then
        RaidLivePreviewState.pendingRestore = true
    else
        RaidLivePreviewState.bridgeMode = false
    end
    UpdateRaidVisibility()
    RaidDiag("state=OFF src=" .. tostring(source or "manual"))
    RaidPreviewChat("Live preview disabled.")
    return true
end

local function ToggleRaidDebuffLivePreview(source)
    if RaidLivePreviewState.active then
        return StopRaidDebuffLivePreview(source or "toggle")
    end
    return StartRaidDebuffLivePreview(source or "toggle")
end

-- =========================================================================
--  FRAME CREATION
-- =========================================================================

local function GetDefaultAnchorPosition()
    return config.startPos[1], config.startPos[2], config.startPos[3], config.startPos[4], config.startPos[5]
end

local function ApplyRaidAnchorPosition()
    if not RaidAnchor then return end
    RaidAnchor:ClearAllPoints()
    local pos = (MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.position)
    if pos and #pos >= 4 then
        if pos[5] then
            RaidAnchor:SetPoint(pos[1], UIParent, pos[3], pos[4], pos[5])
        else
            RaidAnchor:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        end
    else
        local p1, p2, p3, p4, p5 = GetDefaultAnchorPosition()
        RaidAnchor:SetPoint(p1, p2, p3, p4, p5)
    end
end

local function EnsureRaidAnchor()
    if RaidAnchor then return end
    RaidAnchor = CreateFrame("Frame", "MidnightUI_RaidAnchor", UIParent, "BackdropTemplate")
    RaidAnchor:SetFrameStrata("MEDIUM")
    RaidAnchor:SetFrameLevel(5)
    RaidAnchor:SetMovable(true)
    RaidAnchor:SetClampedToScreen(true)
    ApplyRaidAnchorPosition()
end

local function CreateSingleRaidFrame(index)
    local unit = "raid" .. index
    local frameName = "MidnightUI_RaidFrame" .. index

    EnsureRaidAnchor()

    local frame = CreateFrame("Button", frameName, RaidAnchor, "SecureUnitButtonTemplate, BackdropTemplate")
    local effW, effH = GetEffectiveRaidFrameSize(config.columns or 5)
    frame:SetSize(effW, effH)
    frame:SetAttribute("unit", unit)
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")

    RegisterUnitWatch(frame)

    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:EnableMouse(true)

    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame:SetBackdropColor(0.14, 0.14, 0.14, 0.92)
    frame:SetBackdropBorderColor(0, 0, 0, 1)

    local groupStripe = frame:CreateTexture(nil, "ARTWORK")
    groupStripe:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    groupStripe:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    groupStripe:SetWidth(3)
    groupStripe:SetColorTexture(0, 0, 0, 0)
    frame.groupStripe = groupStripe
    local groupStripeRight = frame:CreateTexture(nil, "ARTWORK")
    groupStripeRight:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    groupStripeRight:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    groupStripeRight:SetWidth(3)
    groupStripeRight:SetColorTexture(0, 0, 0, 0)
    frame.groupStripeRight = groupStripeRight

    -- PORTRAIT (3D)
    local portraitSize = effH - 2
    local portrait = CreateFrame("PlayerModel", nil, frame)
    portrait:SetSize(portraitSize, portraitSize)
    portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
    portrait:SetFrameStrata(frame:GetFrameStrata())
    portrait:SetFrameLevel(frame:GetFrameLevel() + 2)
    portrait:SetAlpha(1)
    portrait:Hide()
    frame.portrait = portrait

    portrait.sep = frame:CreateTexture(nil, "OVERLAY")
    portrait.sep:SetWidth(1)
    portrait.sep:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 0, 0)
    portrait.sep:SetPoint("BOTTOMLEFT", portrait, "BOTTOMRIGHT", 0, 0)
    portrait.sep:SetColorTexture(0, 0, 0, 1)

    local barFrame = CreateFrame("Frame", nil, frame)
    barFrame:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 1, -1)
    barFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.barFrame = barFrame

    local healthBg = barFrame:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints(barFrame)
    healthBg:SetColorTexture(0.16, 0.16, 0.16, 0.85)
    frame.healthBg = healthBg

    local healthBar = CreateFrame("StatusBar", nil, barFrame)
    healthBar:SetAllPoints(barFrame)
    ApplyHealthBarStyle(healthBar)
    SetRaidHealthBarColor(healthBar, 0.5, 0.5, 0.5, 0.92)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(1)
    frame.healthBar = healthBar

    local textFrame = CreateFrame("Frame", nil, barFrame)
    textFrame:SetAllPoints(barFrame)
    textFrame:SetFrameLevel(barFrame:GetFrameLevel() + 5)

    local nameText = textFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetPoint("LEFT", barFrame, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    local nameSize, hpSize = GetRaidTextSizes()
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", nameSize, "OUTLINE")
    nameText:SetTextColor(1, 1, 1)
    frame.nameText = nameText

    local hpText = textFrame:CreateFontString(nil, "OVERLAY")
    hpText:SetPoint("RIGHT", barFrame, "RIGHT", -4, 0)
    hpText:SetJustifyH("RIGHT")
    SetFontSafe(hpText, "Fonts\\FRIZQT__.TTF", hpSize, "OUTLINE")
    hpText:SetTextColor(0.9, 0.9, 0.9)
    frame.hpText = hpText

    local deadIcon = textFrame:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(12, 12)
    deadIcon:SetPoint("CENTER", hpText, "CENTER", 0, 0)
    if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(DEAD_STATUS_ATLAS) then
        deadIcon:SetAtlas(DEAD_STATUS_ATLAS, false)
    else
        deadIcon:SetTexture("Interface\\TargetingFrame\\UI-TargetingFrame-Skull")
    end
    deadIcon:SetVertexColor(1, 1, 1, 1)
    deadIcon:SetDrawLayer("OVERLAY", 7)
    deadIcon:SetAlpha(1)
    deadIcon:Hide()
    frame.deadIcon = deadIcon

    return frame
end

local function LayoutRaidFrames()
    ApplyRaidConfigFromSettings()
    EnsureRaidAnchor()
    if not RaidAnchor then return end
    if InCombatLockdown and InCombatLockdown() then
        pendingRaidLayout = true
        return
    end

    local perRow = math.max(1, math.min(config.columns or 5, config.maxFrames))
    local effW, effH = GetEffectiveRaidFrameSize(perRow)
    -- Group lock is a 5-player organization mode. Wider row counts should honor
    -- explicit custom columnization requests instead of forcing 5xN behavior.
    local groupBy = (config.groupBy == true) and perRow <= 5
    local groupGap = 0

    local entries = {}
    local bridgeModeActive = (RaidLivePreviewState.active and RaidLivePreviewState.bridgeMode and (not IsInRaid()))
    if bridgeModeActive then
        local bridgeUnits = GetRaidLiveBridgeUnits(RaidLivePreviewState.bridgeFrameCount)
        for i = 1, #bridgeUnits do
            entries[#entries + 1] = { index = i, group = 1, unit = bridgeUnits[i] }
        end
    else
        for i = 1, config.maxFrames do
            local unit = "raid" .. i
            if UnitExists(unit) then
                local group = GetRaidGroupIndex(unit) or 9
                entries[#entries + 1] = { index = i, group = group, unit = unit }
            end
        end
    end

    local ordered = {}
    if groupBy then
        for g = 1, 8 do
            for i = 1, #entries do
                if entries[i].group == g then ordered[#ordered + 1] = entries[i] end
            end
        end
        for i = 1, #entries do
            if entries[i].group == 9 then ordered[#ordered + 1] = entries[i] end
        end
    else
        ordered = entries
    end

    local useVerticalFill = (config.verticalFill == true)

    local col = 0
    local row = 0
    local groupBreaks = 0
    local lastGroup = ordered[1] and ordered[1].group or nil
    local maxRow = 0
    local maxCol = 0

    if useVerticalFill then
        -- Column-major layout: fill each column top-to-bottom, then move right.
        -- With groupBy, each group gets its own column.
        local perCol = math.max(1, perRow) -- reuse "columns" setting as rows-per-column
        if groupBy then
            -- Each group fills its own column(s) vertically.
            local groups = {}
            local groupOrder = {}
            for _, entry in ipairs(ordered) do
                local g = entry.group
                if not groups[g] then
                    groups[g] = {}
                    groupOrder[#groupOrder + 1] = g
                end
                groups[g][#groups[g] + 1] = entry
            end
            local currentCol = 0
            for _, g in ipairs(groupOrder) do
                local members = groups[g]
                for mi, entry in ipairs(members) do
                    local frame = RaidFrames[entry.index]
                    if frame then
                        local r = mi - 1
                        local x = currentCol * (effW + config.spacingX)
                        local y = r * (effH + config.spacingY)
                        frame:ClearAllPoints()
                        frame:SetPoint("TOPLEFT", RaidAnchor, "TOPLEFT", x, -y)
                        frame:SetSize(effW, effH)
                        if frame.portrait then
                            local ps = effH - 2
                            frame.portrait:SetSize(ps, ps)
                            frame.portrait:ClearAllPoints()
                            frame.portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
                            if frame.portrait.sep then
                                frame.portrait.sep:ClearAllPoints()
                                frame.portrait.sep:SetPoint("TOPLEFT", frame.portrait, "TOPRIGHT", 0, 0)
                                frame.portrait.sep:SetPoint("BOTTOMLEFT", frame.portrait, "BOTTOMRIGHT", 0, 0)
                            end
                        end
                        if r > maxRow then maxRow = r end
                    end
                end
                currentCol = currentCol + 1
                if currentCol > maxCol then maxCol = currentCol end
            end
            local totalCols = math.max(1, currentCol)
            local totalRows = math.max(1, maxRow + 1)
            local w = (totalCols * effW) + ((totalCols - 1) * config.spacingX)
            local h = (totalRows * effH) + ((totalRows - 1) * config.spacingY)
            RaidAnchor:SetSize(w, h)
        else
            -- No groupBy: fill perCol rows per column, then wrap to next column.
            for idx, entry in ipairs(ordered) do
                local frame = RaidFrames[entry.index]
                if frame then
                    local x = col * (effW + config.spacingX)
                    local y = row * (effH + config.spacingY)
                    frame:ClearAllPoints()
                    frame:SetPoint("TOPLEFT", RaidAnchor, "TOPLEFT", x, -y)
                    frame:SetSize(effW, effH)
                    if frame.portrait then
                        local ps = effH - 2
                        frame.portrait:SetSize(ps, ps)
                        frame.portrait:ClearAllPoints()
                        frame.portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
                        if frame.portrait.sep then
                            frame.portrait.sep:ClearAllPoints()
                            frame.portrait.sep:SetPoint("TOPLEFT", frame.portrait, "TOPRIGHT", 0, 0)
                            frame.portrait.sep:SetPoint("BOTTOMLEFT", frame.portrait, "BOTTOMRIGHT", 0, 0)
                        end
                    end
                    if row > maxRow then maxRow = row end
                    if col > maxCol then maxCol = col end
                    row = row + 1
                    if row >= perCol then
                        row = 0
                        col = col + 1
                    end
                end
            end
            local totalCols = math.max(1, maxCol + 1)
            local totalRows = math.max(1, maxRow + 1)
            local w = (totalCols * effW) + ((totalCols - 1) * config.spacingX)
            local h = (totalRows * effH) + ((totalRows - 1) * config.spacingY)
            RaidAnchor:SetSize(w, h)
        end
    else
        -- Row-major layout (default): fill each row left-to-right, then wrap down.
        for _, entry in ipairs(ordered) do
            local frame = RaidFrames[entry.index]
            if frame then
                if groupBy and lastGroup and entry.group ~= lastGroup then
                    groupBreaks = groupBreaks + 1
                    if col ~= 0 then
                        row = row + 1
                        col = 0
                    end
                    lastGroup = entry.group
                end

                local x = col * (effW + config.spacingX)
                local y = row * (effH + config.spacingY) + (groupBreaks * groupGap)
                frame:ClearAllPoints()
                frame:SetPoint("TOPLEFT", RaidAnchor, "TOPLEFT", x, -y)
                frame:SetSize(effW, effH)
                if frame.portrait then
                    local ps = effH - 2
                    frame.portrait:SetSize(ps, ps)
                    frame.portrait:ClearAllPoints()
                    frame.portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
                    if frame.portrait.sep then
                        frame.portrait.sep:ClearAllPoints()
                        frame.portrait.sep:SetPoint("TOPLEFT", frame.portrait, "TOPRIGHT", 0, 0)
                        frame.portrait.sep:SetPoint("BOTTOMLEFT", frame.portrait, "BOTTOMRIGHT", 0, 0)
                    end
                end

                col = col + 1
                if col >= perRow then
                    col = 0
                    row = row + 1
                end
                if row > maxRow then maxRow = row end
            end
        end

        local rows = math.max(1, maxRow + (col > 0 and 1 or 0))
        local w = (perRow * effW) + ((perRow - 1) * config.spacingX)
        local h = (rows * effH) + ((rows - 1) * config.spacingY) + (groupBreaks * groupGap)
        RaidAnchor:SetSize(w, h)
    end
    local scale = (config.scale or 100) / 100
    if scale <= 0 then scale = 1 end
    RaidAnchor:SetScale(scale)
    ClampRaidAnchorToScreen()
end

function MidnightUI_ApplyRaidFramesLayout()
    if InCombatLockdown and InCombatLockdown() then
        pendingRaidLayout = true
        return
    end
    ApplyRaidConfigFromSettings()
    LayoutRaidFrames()
    if _G.MidnightUI_UpdateRaidVisibility then
        _G.MidnightUI_UpdateRaidVisibility()
    elseif UpdateRaidVisibility then
        UpdateRaidVisibility()
    end
    if RaidAnchor and RaidAnchor.dragOverlay and RaidAnchor.dragOverlay:IsShown() then
        if RaidAnchor.dragOverlay._muiUpdateLayout then
            RaidAnchor.dragOverlay:_muiUpdateLayout()
        end
    end
end

local function ApplyRaidFramesBarStyle()
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame and frame.healthBar then
            ApplyHealthBarStyle(frame.healthBar)
        end
        ApplyFrameTextStyle(frame)
        if frame and frame:IsShown() then
            UpdateRaidUnit(frame)
        end
    end
end
_G.MidnightUI_ApplyRaidFramesBarStyle = ApplyRaidFramesBarStyle

-- =========================================================================
--  UPDATE LOGIC
-- =========================================================================

local function UpdateRaidUnit(frame)
    local unit = frame:GetAttribute("unit")
    if not unit or not UnitExists(unit) then
        ClearRaidDebuffPreviewForFrame(frame)
        return
    end

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
    -- If health is secret/restricted but unit is alive, default to full bar
    -- so the class-colored fill is visible instead of an empty bar showing the dark bg.
    if hp == 0 and maxHp > 0 and UnitIsConnected(unit) and not IsUnitActuallyDead(unit) then
        hp = maxHp
    end
    local isDead = IsUnitActuallyDead(unit)
    local isConnected = UnitIsConnected(unit)
    local hasIncomingRes = UnitHasIncomingResurrection(unit)

    local name = TruncateName(UnitName(unit), 9)
    frame.nameText:SetText(name)

    local isSimple = MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.layoutStyle == "Simple"
    local showPortrait = false
    if frame.portrait and frame.barFrame then
        if showPortrait then
            frame.portrait:Show()
            if frame.portrait.sep then frame.portrait.sep:Show() end
            frame.portrait:ClearModel()
            frame.portrait:SetUnit(unit)
            frame.portrait:SetCamera(0)
            frame.barFrame:ClearAllPoints()
            frame.barFrame:SetPoint("TOPLEFT", frame.portrait, "TOPRIGHT", 1, -1)
            frame.barFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        else
            frame.portrait:Hide()
            if frame.portrait.sep then frame.portrait.sep:Hide() end
            frame.barFrame:ClearAllPoints()
            frame.barFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
            frame.barFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        end
    end
    if frame.groupStripe then
        if config.colorByGroup and not isSimple then
            local grp = GetRaidGroupIndex(unit)
            local cgrp = grp and GROUP_COLORS[grp]
            if cgrp then
                frame.groupStripe:SetColorTexture(cgrp.r, cgrp.g, cgrp.b, 0.9)
                if frame.groupStripeRight then
                    frame.groupStripeRight:SetColorTexture(cgrp.r, cgrp.g, cgrp.b, 0.9)
                end
            else
                frame.groupStripe:SetColorTexture(0, 0, 0, 0)
                if frame.groupStripeRight then
                    frame.groupStripeRight:SetColorTexture(0, 0, 0, 0)
                end
            end
        else
            frame.groupStripe:SetColorTexture(0, 0, 0, 0)
            if frame.groupStripeRight then
                frame.groupStripeRight:SetColorTexture(0, 0, 0, 0)
            end
        end
    end

    if isSimple then
        frame.healthBar:Hide()
        frame.healthBg:Hide()
        if frame.deadIcon then frame.deadIcon:Hide() end
        frame:SetBackdropColor(c.r, c.g, c.b, 0.9)
        if frame.nameText then
            frame.nameText:ClearAllPoints()
            if frame.barFrame then
                frame.nameText:SetPoint("CENTER", frame.barFrame, "CENTER", 0, 0)
            else
                frame.nameText:SetPoint("CENTER", frame, "CENTER", 0, 0)
            end
            frame.nameText:SetTextColor(1, 1, 1)
        end
        frame.hpText:SetText("")
        return
    end

    frame.healthBar:Show()
    frame.healthBg:Show()
    if frame.nameText then
        frame.nameText:ClearAllPoints()
        if frame.barFrame then
            frame.nameText:SetPoint("LEFT", frame.barFrame, "LEFT", 4, 0)
        else
            frame.nameText:SetPoint("LEFT", frame, "LEFT", 4, 0)
        end
        frame.nameText:SetTextColor(1, 1, 1)
    end

    if not isConnected then
        SetRaidHealthBarColor(frame.healthBar, 0.15, 0.15, 0.15, 0.6)
        frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.9)
        frame.hpText:SetText("OFF")
        frame.hpText:SetTextColor(0.6, 0.6, 0.6)
        if frame.deadIcon then frame.deadIcon:Hide() end
    elseif isDead and not hasIncomingRes then
        SetRaidHealthBarColor(frame.healthBar, c.r * 0.2, c.g * 0.2, c.b * 0.2, 0.7)
        frame.healthBg:SetColorTexture(0.1, 0.02, 0.02, 0.9)
        frame.hpText:SetText("")
        frame.hpText:SetTextColor(1, 0.25, 0.25)
        if frame.deadIcon then
            local rawTextH = (frame.hpText and frame.hpText.GetStringHeight and frame.hpText:GetStringHeight()) or nil
            local textH = (type(rawTextH) == "number" and rawTextH) or 10
            local rawBarH = (frame.barFrame and frame.barFrame.GetHeight and frame.barFrame:GetHeight()) or nil
            local barH = (type(rawBarH) == "number" and rawBarH) or 18
            local size = math.max(7, math.min(barH - 8, textH + 2, 12))
            frame.deadIcon:SetSize(size, size)
            frame.deadIcon:ClearAllPoints()
            frame.deadIcon:SetPoint("RIGHT", frame.barFrame, "RIGHT", -6, 0)
            ApplyDeadIconVisualStyle(frame.deadIcon)
            frame.deadIcon:Show()
        end
    else
        local barR, barG, barB = c.r, c.g, c.b
        if hasIncomingRes then
            barR, barG, barB = barR * 1.2, barG * 1.2, barB * 1.2
        end
        SetRaidHealthBarColor(frame.healthBar, barR, barG, barB, 1)
        frame.healthBg:SetColorTexture(c.r * 0.25, c.g * 0.25, c.b * 0.25, 0.90)

        local showPct = MidnightUISettings
            and MidnightUISettings.RaidFrames
            and MidnightUISettings.RaidFrames.showHealthPct ~= false
        if showPct then
            local pct = GetDisplayHealthPercent(unit)
            if pct ~= nil then
                local ok, text = pcall(function()
                    return string.format("%.0f%%", pct)
                end)
                if ok and text then
                    frame.hpText:SetText(text)
                else
                    frame.hpText:SetText("")
                end
            else
                frame.hpText:SetText("")
            end
        else
            frame.hpText:SetText("")
        end
        frame.hpText:SetTextColor(0.9, 0.9, 0.9)
        if frame.deadIcon then frame.deadIcon:Hide() end
    end

    pcall(function()
        frame.healthBar:SetMinMaxValues(0, maxHp)
        if isDead and not hasIncomingRes then
            frame.healthBar:SetValue(0)
        else
            frame.healthBar:SetValue(hp)
        end
    end)

    if IsRaidDebuffVisualsEnabled() then
        UpdateRaidLivePreviewForFrame(frame, "UpdateRaidUnit")
    else
        ClearRaidDebuffPreviewForFrame(frame)
    end

    -- Atomic color+style+texture as the absolute last step (mirrors PlayerFrame pattern).
    -- This runs AFTER SetValue and AFTER debuff preview so nothing can wipe it.
    local finalR, finalG, finalB = c.r, c.g, c.b
    if not isConnected then
        finalR, finalG, finalB = 0.15, 0.15, 0.15
    elseif isDead and not hasIncomingRes then
        finalR, finalG, finalB = c.r * 0.2, c.g * 0.2, c.b * 0.2
    elseif hasIncomingRes then
        finalR, finalG, finalB = c.r * 1.2, c.g * 1.2, c.b * 1.2
    end
    ApplyRaidBarColor(frame.healthBar, finalR, finalG, finalB)
    SetRaidRenderedSecretPolish(frame.healthBar, false)

end

-- Batch flush: process all dirty units once per rendered frame
_raidBatchFrame:SetScript("OnUpdate", function(self)
    if _raidDirtyAll then
        _raidDirtyAll = false
        for i = 1, config.maxFrames do
            local f = RaidFrames[i]
            if f and f:IsShown() then UpdateRaidUnit(f) end
        end
    else
        for idx in pairs(_raidDirtyUnits) do
            local f = RaidFrames[idx]
            if f and f:IsShown() then UpdateRaidUnit(f) end
        end
    end
    wipe(_raidDirtyUnits)
    self:Hide()
end)

-- =========================================================================
--  INIT & EVENTS
-- =========================================================================

function MidnightUI_SetRaidFramesLocked(locked)
    EnsureRaidAnchor()
    if not RaidAnchor then return end
    if locked then
        if RaidAnchor.dragOverlay then RaidAnchor.dragOverlay:Hide() end
    else
        RaidAnchor:Show()
        if not RaidAnchor.dragOverlay then
            local overlay = CreateFrame("Frame", nil, RaidAnchor, "BackdropTemplate")
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", RaidAnchor, "TOPLEFT", -10, 10)
            overlay:SetPoint("BOTTOMRIGHT", RaidAnchor, "BOTTOMRIGHT", 10, -10)
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
            overlay:SetAlpha(1)

            overlay.groupBrackets = {}
            overlay.previewBoxes = {}
            overlay.previewLabels = {}
            overlay.bracketLayer = CreateFrame("Frame", nil, overlay)
            overlay.bracketLayer:SetAllPoints()
            overlay.bracketLayer:SetFrameLevel(overlay:GetFrameLevel() + 5)
            overlay.bottomPad = 0
            overlay.titleText = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            overlay.titleText:SetText("RAID FRAMES")
            overlay.titleText:SetTextColor(0.85, 0.85, 0.85)

            function overlay:_muiUpdateLayout()
                ApplyRaidConfigFromSettings()
                LayoutRaidFrames()
                overlay:ClearAllPoints()

                local perRow = math.max(1, math.min(config.columns or 5, config.maxFrames))
                local inset = 6
                overlay.bottomPad = 26
                local effW, effH = GetEffectiveRaidFrameSize(perRow)
                local maxPreview = 30
                local entries = {}
                for i = 1, maxPreview do
                    local group = math.floor((i - 1) / 5) + 1
                    local occupied = true
                    if IsInRaid() then
                        occupied = UnitExists("raid" .. i)
                    end
                    entries[#entries + 1] = { index = i, group = group, occupied = occupied }
                end
                for g = 1, 8 do
                    local bracket = overlay.groupBrackets[g]
                    if bracket then
                        if bracket.left then bracket.left:Hide() end
                        if bracket.right then bracket.right:Hide() end
                    end
                end

                local col = 0
                local row = 0
                local lastGroup = nil
                local groupBy = (config.groupBy == true) and perRow <= 5
                local groupBreaks = 0
                local groupRows = {}
                local bounds = { minX = 999999, minY = 999999, maxX = -999999, maxY = -999999 }
                local useVertFill = (config.verticalFill == true)

                -- Helper: ensure a preview box exists for index i
                local function EnsurePreviewBox(i)
                    local box = overlay.previewBoxes[i]
                    if not box then
                        box = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
                        box:SetBackdrop({
                            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                            tile = true, tileSize = 16, edgeSize = 10,
                            insets = { left = 1, right = 1, top = 1, bottom = 1 }
                        })
                        box:SetBackdropColor(0.12, 0.16, 0.22, 0.78)
                        box:SetBackdropBorderColor(0.30, 0.46, 0.62, 0.86)
                        local stripe = box:CreateTexture(nil, "ARTWORK")
                        stripe:SetPoint("LEFT", 0, 0)
                        stripe:SetSize(4, config.height)
                        box._stripe = stripe
                        box:EnableMouse(false)
                        local inner = box:CreateTexture(nil, "BORDER")
                        inner:SetPoint("TOPLEFT", 2, -2)
                        inner:SetPoint("BOTTOMRIGHT", -2, 2)
                        inner:SetColorTexture(1, 1, 1, 0.04)
                        box._inner = inner
                        local plabel = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
                        plabel:SetPoint("CENTER")
                        overlay.previewLabels[i] = plabel
                        overlay.previewBoxes[i] = box
                    end
                    return box
                end

                -- Helper: place a box, update bounds/groupRows
                local function PlaceBox(i, entry, bx, by)
                    local box = EnsurePreviewBox(i)
                    local x = inset + bx
                    local y = inset + by
                    box:SetSize(effW, effH)
                    box:ClearAllPoints()
                    box:SetPoint("TOPLEFT", overlay, "TOPLEFT", x, -y)
                    box:Show()
                    if x < bounds.minX then bounds.minX = x end
                    if y < bounds.minY then bounds.minY = y end
                    if (x + effW) > bounds.maxX then bounds.maxX = x + effW end
                    if (y + effH) > bounds.maxY then bounds.maxY = y + effH end
                    if entry.occupied then
                        box:SetBackdropColor(0.12, 0.16, 0.22, 0.78)
                        box:SetBackdropBorderColor(0.30, 0.46, 0.62, 0.86)
                    else
                        box:SetBackdropColor(0.06, 0.06, 0.08, 0.5)
                        box:SetBackdropBorderColor(0.18, 0.20, 0.24, 0.6)
                    end
                    if box._stripe then box._stripe:Hide() end
                    local plabel = overlay.previewLabels[i]
                    if plabel then
                        plabel:SetText(tostring(entry.index))
                        if entry.occupied then
                            plabel:SetTextColor(1, 0.85, 0.2)
                        else
                            plabel:SetTextColor(0.6, 0.6, 0.6)
                        end
                    end
                    if entry.occupied then
                        groupRows[entry.group] = groupRows[entry.group] or { minY = y, maxY = y + effH, minX = x, maxX = x + effW }
                        if y < groupRows[entry.group].minY then groupRows[entry.group].minY = y end
                        if (y + effH) > groupRows[entry.group].maxY then groupRows[entry.group].maxY = y + effH end
                        if x < groupRows[entry.group].minX then groupRows[entry.group].minX = x end
                        if (x + effW) > groupRows[entry.group].maxX then groupRows[entry.group].maxX = x + effW end
                    end
                end

                if useVertFill then
                    if groupBy then
                        -- Each group gets its own column, members stack vertically
                        local groups = {}
                        local groupOrder = {}
                        for _, entry in ipairs(entries) do
                            local g = entry.group
                            if not groups[g] then
                                groups[g] = {}
                                groupOrder[#groupOrder + 1] = g
                            end
                            groups[g][#groups[g] + 1] = entry
                        end
                        local currentCol = 0
                        for _, g in ipairs(groupOrder) do
                            local members = groups[g]
                            for mi, entry in ipairs(members) do
                                local r = mi - 1
                                PlaceBox(entry.index, entry, currentCol * (effW + config.spacingX), r * (effH + config.spacingY))
                            end
                            currentCol = currentCol + 1
                        end
                    else
                        -- Fill perRow rows per column, then wrap to next column
                        local perCol = math.max(1, perRow)
                        local vc = 0
                        local vr = 0
                        for _, entry in ipairs(entries) do
                            PlaceBox(entry.index, entry, vc * (effW + config.spacingX), vr * (effH + config.spacingY))
                            vr = vr + 1
                            if vr >= perCol then
                                vr = 0
                                vc = vc + 1
                            end
                        end
                    end
                else
                    -- Default row-major layout
                    for i = 1, #entries do
                        local entry = entries[i]
                        if groupBy and lastGroup and entry.group ~= lastGroup then
                            groupBreaks = groupBreaks + 1
                            if col ~= 0 then
                                row = row + 1
                                col = 0
                            end
                        end
                        PlaceBox(i, entry, col * (effW + config.spacingX), row * (effH + config.spacingY))
                        col = col + 1
                        if col >= perRow then
                            col = 0
                            row = row + 1
                        end
                        lastGroup = entry.group
                    end
                end
                for i = #entries + 1, #overlay.previewBoxes do
                    if overlay.previewBoxes[i] then overlay.previewBoxes[i]:Hide() end
                end

                -- Compute overlay and anchor size from placed bounds
                local fallbackW = (perRow * config.width) + ((perRow - 1) * config.spacingX)
                local fallbackRows = row + (col > 0 and 1 or 0)
                local fallbackH = (fallbackRows * config.height) + ((fallbackRows - 1) * config.spacingY)
                if bounds.minX == 999999 then
                    bounds.minX, bounds.minY = inset, inset
                    bounds.maxX, bounds.maxY = inset + fallbackW, inset + fallbackH
                end
                overlay._muiBounds = bounds

                local minX = bounds.minX or inset
                local minY = bounds.minY or inset
                local maxX = bounds.maxX or (inset + fallbackW)
                local maxY = bounds.maxY or (inset + fallbackH)
                local contentW = maxX - minX
                local contentH = maxY - minY
                overlay:ClearAllPoints()
                overlay:SetPoint("TOPLEFT", RaidAnchor, "TOPLEFT", -inset, inset)
                overlay:SetSize(contentW + (inset * 2), contentH + (inset * 2) + overlay.bottomPad)
                overlay.titleText:ClearAllPoints()
                overlay.titleText:SetPoint("BOTTOM", overlay, "BOTTOM", 0, 8)
                if not IsInRaid() then
                    RaidAnchor:SetSize(math.max(1, contentW), math.max(1, contentH))
                    RaidAnchor:Show()
                end

                if config.groupBrackets ~= false then
                    local xLeft = minX
                    local xRight = maxX
                    local groupOrder = {}
                    for g = 1, 8 do
                        if groupRows[g] then groupOrder[#groupOrder + 1] = g end
                    end
                    for idx = 1, #groupOrder do
                        local g = groupOrder[idx]
                        local info = groupRows[g]
                        if info then
                            local bracket = overlay.groupBrackets[g]
                            if not bracket then
                                bracket = {}
                                bracket.left = overlay.bracketLayer:CreateTexture(nil, "OVERLAY")
                                bracket.right = overlay.bracketLayer:CreateTexture(nil, "OVERLAY")
                                overlay.groupBrackets[g] = bracket
                            end
                            local c = GROUP_COLORS[g] or { r = 1, g = 1, b = 1 }
                            if not config.colorByGroup then
                                c = { r = 0.45, g = 0.75, b = 1.0 }
                            end
                            local yStart = info.minY
                            local yEnd = info.maxY
                            local thickness = 2
                            bracket.left:SetColorTexture(c.r, c.g, c.b, 0.85)
                            bracket.left:ClearAllPoints()
                            bracket.left:SetPoint("TOPLEFT", overlay, "TOPLEFT", info.minX, -yStart)
                            bracket.left:SetPoint("BOTTOMLEFT", overlay, "TOPLEFT", info.minX, -yEnd)
                            bracket.left:SetWidth(thickness)
                            bracket.left:Show()

                            bracket.right:SetColorTexture(c.r, c.g, c.b, 0.85)
                            bracket.right:ClearAllPoints()
                            bracket.right:SetPoint("TOPLEFT", overlay, "TOPLEFT", info.maxX, -yStart)
                            bracket.right:SetPoint("BOTTOMLEFT", overlay, "TOPLEFT", info.maxX, -yEnd)
                            bracket.right:SetWidth(thickness)
                            bracket.right:Show()

                            if bracket.top then bracket.top:Hide() end
                            if bracket.bottom then bracket.bottom:Hide() end
                        end
                    end
                else
                    for g = 1, 8 do
                        local bracket = overlay.groupBrackets[g]
                        if bracket then
                            bracket.left:Hide()
                            bracket.right:Hide()
                            if bracket.top then bracket.top:Hide() end
                            if bracket.bottom then bracket.bottom:Hide() end
                        end
                    end
                end
            end

            overlay:EnableMouse(true)
            overlay:RegisterForDrag("LeftButton")
            overlay:SetScript("OnDragStart", function()
                if RaidAnchor and RaidAnchor.SetMovable then
                    RaidAnchor:SetMovable(true)
                    RaidAnchor:EnableMouse(true)
                end
                RaidAnchor:StartMoving()
            end)
            overlay:SetScript("OnDragStop", function()
                RaidAnchor:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = RaidAnchor:GetPoint()
                if MidnightUISettings and MidnightUISettings.RaidFrames then
                    MidnightUISettings.RaidFrames.position = { point, relativePoint, xOfs, yOfs }
                end
                ClampRaidAnchorToScreen()
            end)
            overlay:SetScript("OnMouseUp", function(self, button)
                if button == "RightButton" then
                    if _G.MidnightUI_ShowOverlaySettings then
                        _G.MidnightUI_ShowOverlaySettings("RaidFrames")
                    end
                end
            end)
            RaidAnchor.dragOverlay = overlay
        end
        RaidAnchor.dragOverlay:Show()
        if RaidAnchor.dragOverlay._muiUpdateLayout then
            RaidAnchor.dragOverlay:_muiUpdateLayout()
        end
    end
end

local function HideBlizzardRaidFrames()
    if MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.useDefaultFrames then
        return
    end
    if _G.CompactRaidFrameManager then
        _G.CompactRaidFrameManager:UnregisterAllEvents()
        _G.CompactRaidFrameManager:Hide()
        _G.CompactRaidFrameManager:SetParent(hiddenParent)
    end
    if _G.CompactRaidFrameContainer then
        _G.CompactRaidFrameContainer:UnregisterAllEvents()
        _G.CompactRaidFrameContainer:Hide()
        _G.CompactRaidFrameContainer:SetParent(hiddenParent)
    end
end

EnsureRaidFrames = function(neededCount)
    if MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.useDefaultFrames then
        return
    end
    EnsureRaidAnchor()
    -- Only create frames for the number of raid members actually needed
    -- (defaults to current raid size, or all 40 if explicitly requested)
    local count = neededCount or GetNumGroupMembers() or 0
    if count < 1 then count = 1 end
    if count > config.maxFrames then count = config.maxFrames end
    for i = 1, count do
        if not RaidFrames[i] then
            RaidFrames[i] = CreateSingleRaidFrame(i)
        end
    end
    LayoutRaidFrames()
end

UpdateRaidVisibility = function()
    if InCombatLockdown and InCombatLockdown() then
        pendingRaidVisibility = true
        return
    end
    pendingRaidVisibility = false
    -- When using default Blizzard raid frames, hide all custom frames
    if MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.useDefaultFrames then
        for i = 1, config.maxFrames do
            local f = RaidFrames[i]
            if f then f:Hide() end
        end
        if RaidAnchor then RaidAnchor:Hide() end
        StopRaidRangeTicker()
        return
    end
    -- Check if RaidFrames are enabled
    if MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.enabled == false then
        for i = 1, config.maxFrames do
            local f = RaidFrames[i]
            if f then
                ClearRaidDebuffPreviewForFrame(f)
                f:Hide()
            end
        end
        if RaidAnchor then RaidAnchor:Hide() end
        StopRaidRangeTicker()
        return
    end

    local inRaidNow = IsInRaid()
    local useBridgeMode = (RaidLivePreviewState.active and (not inRaidNow))

    if (not useBridgeMode) and RaidLivePreviewState.bridgeMode then
        if not RestoreRaidLiveUnitBindings() then
            pendingRaidVisibility = true
            return
        end
        RaidLivePreviewState.bridgeMode = false
    elseif useBridgeMode then
        RaidLivePreviewState.bridgeMode = true
    end

    if inRaidNow or useBridgeMode then
        EnsureRaidBlizzAuraHook()
        EnsureRaidFrames()
        local bridgeUnits = nil
        local bridgeBaseCount = 0
        if useBridgeMode then
            local okBridge, boundCount, baseCount = ApplyRaidLiveBridgeUnitBindings()
            if not okBridge then
                pendingRaidVisibility = true
                return
            end
            bridgeUnits = GetRaidLiveBridgeUnits(RaidLivePreviewState.bridgeFrameCount)
            bridgeBaseCount = tonumber(baseCount) or 0
        end

        LayoutRaidFrames()
        for i = 1, config.maxFrames do
            local f = RaidFrames[i]
            local shouldShow = false
            if f then
                if useBridgeMode then
                    local mappedUnit = bridgeUnits and bridgeUnits[i] or nil
                    shouldShow = (type(mappedUnit) == "string" and UnitExists(mappedUnit))
                else
                    local unit = f:GetAttribute("unit")
                    shouldShow = (type(unit) == "string" and UnitExists(unit))
                end
            end
            if f and shouldShow then
                f:Show()
                UpdateRaidUnit(f)
            elseif f then
                ClearRaidDebuffPreviewForFrame(f)
                f:Hide()
            end
        end
        EnsureRaidRangeTicker()
    else
        for i = 1, config.maxFrames do
            local f = RaidFrames[i]
            if f then
                ClearRaidDebuffPreviewForFrame(f)
                f:Hide()
            end
        end
        StopRaidRangeTicker()
    end
end

RaidFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
RaidFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")
RaidFrameManager:RegisterEvent("GROUP_ROSTER_UPDATE")
RaidFrameManager:RegisterEvent("UNIT_HEALTH")
RaidFrameManager:RegisterEvent("UNIT_MAXHEALTH")
RaidFrameManager:RegisterEvent("UNIT_CONNECTION")
RaidFrameManager:RegisterEvent("UNIT_NAME_UPDATE")
RaidFrameManager:RegisterEvent("UNIT_FLAGS")
RaidFrameManager:RegisterEvent("UNIT_AURA")
RaidFrameManager:RegisterEvent("READY_CHECK_CONFIRM")

RaidFrameManager:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_ENTERING_WORLD" then
        EnsureRaidBlizzAuraHook()
        HideBlizzardRaidFrames()
        UpdateRaidVisibility()
        if IsRaidDebuffVisualsEnabled() then
            RefreshRaidLivePreview("PLAYER_ENTERING_WORLD")
        end
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if RaidLivePreviewState.pendingStart then
            StartRaidDebuffLivePreview("PLAYER_REGEN_ENABLED")
        end
        if RaidLivePreviewState.pendingRestore then
            local restored = RestoreRaidLiveUnitBindings()
            if restored then
                RaidLivePreviewState.pendingRestore = false
                RaidLivePreviewState.bridgeMode = false
                UpdateRaidVisibility()
            end
        end
        if pendingRaidLayout then
            pendingRaidLayout = false
            LayoutRaidFrames()
            if _G.MidnightUI_UpdateRaidVisibility then
                _G.MidnightUI_UpdateRaidVisibility()
            elseif UpdateRaidVisibility then
                UpdateRaidVisibility()
            end
        end
        if pendingRaidVisibility then
            pendingRaidVisibility = false
            UpdateRaidVisibility()
        end
        if IsRaidDebuffVisualsEnabled() then
            RefreshRaidLivePreview("PLAYER_REGEN_ENABLED")
        end
        return
    end

    if event == "GROUP_ROSTER_UPDATE" then
        UpdateRaidVisibility()
        if IsRaidDebuffVisualsEnabled() then
            RefreshRaidLivePreview("GROUP_ROSTER_UPDATE")
        end
        return
    end

    local unit = ...
    if type(unit) == "string" and string_match(unit, "^raid%d+$") then
        local idx = tonumber(string_match(unit, "raid(%d+)$"))
        if idx and RaidFrames[idx] and RaidFrames[idx]:IsShown() then
            _raidDirtyUnits[idx] = true
            _raidBatchFrame:Show()
        end
    elseif event == "UNIT_AURA" and IsRaidDebuffVisualsEnabled() and type(unit) == "string" and unit ~= "" then
        RefreshRaidLivePreview("UNIT_AURA_FALLBACK", unit)
    else
        _raidDirtyAll = true
        _raidBatchFrame:Show()
    end
end)

HideBlizzardRaidFrames()
EnsureRaidBlizzAuraHook()
UpdateRaidVisibility()

if MidnightUISettings and MidnightUISettings.Messenger then
    MidnightUI_SetRaidFramesLocked(MidnightUISettings.Messenger.locked)
end
_G.MidnightUI_UpdateRaidVisibility = UpdateRaidVisibility

local function RefreshRaidDebuffOverlayVisuals(source)
    for i = 1, config.maxFrames do
        local frame = RaidFrames[i]
        if frame then
            if IsRaidDebuffVisualsEnabled() then
                UpdateRaidLivePreviewForFrame(frame, source or "manual")
            else
                ClearRaidDebuffPreviewForFrame(frame)
            end
        end
    end
end
_G.MidnightUI_RefreshRaidDebuffOverlay = RefreshRaidDebuffOverlayVisuals

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function ApplyRaidOverlaySettings()
    if _G.MidnightUI_ApplyRaidFramesLayout then
        _G.MidnightUI_ApplyRaidFramesLayout()
    end
end

local function BuildRaidOverlaySettings(content)
    local s = EnsureRaidSettings()
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Header("Layout")
    local slCols  -- forward-declare so the groupBy checkbox can reference it
    b:Checkbox("Raid Debuff Overlay", IsRaidDebuffOverlayEnabled(), function(v)
        local combat = EnsureRaidCombatDebuffSettings()
        combat.debuffOverlayRaidEnabled = v and true or false
        RefreshRaidDebuffOverlayVisuals("overlay-settings")
    end)
    b:Checkbox("Lock To 5-Player Groups", s.groupBy == true, function(v)
        s.groupBy = v
        if slCols then
            local maxCols = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
            if v then maxCols = math.min(maxCols, 5) end
            slCols:SetMinMaxValues(1, maxCols)
            if (s.columns or 5) > maxCols then
                s.columns = maxCols
                slCols:SetValue(maxCols)
            end
        end
        ApplyRaidOverlaySettings()
    end)

    b:Checkbox("Vertical Fill (Groups as Columns)", s.verticalFill == true, function(v)
        s.verticalFill = v
        ApplyRaidOverlaySettings()
    end)

    b:Checkbox("Colorize Frame Edges By Group", s.colorByGroup ~= false, function(v)
        s.colorByGroup = v
        ApplyRaidOverlaySettings()
    end)

    b:Checkbox("Show Group Brackets (Overlay)", s.groupBrackets ~= false, function(v)
        s.groupBrackets = v
        ApplyRaidOverlaySettings()
    end)

    local colSliderLabel = (s.verticalFill == true) and "Units Per Column" or "Units Per Row"
    slCols = b:Slider(colSliderLabel, 1, 40, 1, s.columns or 5, function(v)
        s.columns = math.max(1, math.floor(v))
        ApplyRaidOverlaySettings()
    end)
    if slCols then
        local maxCols = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
        if s.groupBy then maxCols = math.min(maxCols, 5) end
        slCols:SetMinMaxValues(1, maxCols)
        local innerSlider = slCols._muiSlider or (slCols.slider)
        if innerSlider then
            local old = innerSlider:GetScript("OnValueChanged")
            innerSlider:SetScript("OnValueChanged", function(self, v)
                local m = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
                if s.groupBy then m = math.min(m, 5) end
                slCols:SetMinMaxValues(1, m)
                if v > m then
                    if not self._muiClamping then
                        self._muiClamping = true
                        self:SetValue(m)
                        self._muiClamping = false
                    end
                    return
                end
                if old then old(self, v) end
            end)
        end
    end

    b:Dropdown("Styling:", {"Rendered", "Simple"}, (s.layoutStyle == "Simple") and "Simple" or "Rendered", function(v)
        s.layoutStyle = (v == "Simple") and "Simple" or "Detailed"
        ApplyRaidOverlaySettings()
    end)
    
    b:Checkbox("Show Health %", s.showHealthPct ~= false, function(v)
        s.showHealthPct = v
        ApplyRaidOverlaySettings()
        if _G.MidnightUI_ApplyRaidFramesBarStyle then _G.MidnightUI_ApplyRaidFramesBarStyle() end
    end)
    
    b:Slider("Text Size", 6, 14, 1, s.textSize or 9, function(v)
        s.textSize = math.floor(v)
        ApplyRaidOverlaySettings()
        if _G.MidnightUI_ApplyRaidFramesBarStyle then _G.MidnightUI_ApplyRaidFramesBarStyle() end
    end)

    b:Slider("Raid Frame Width", 60, 220, 1, s.width or 92, function(v)
        s.width = math.floor(v)
        ApplyRaidOverlaySettings()
    end)

    b:Slider("Raid Frame Height", 16, 80, 1, s.height or 24, function(v)
        s.height = math.floor(v)
        ApplyRaidOverlaySettings()
    end)

    b:Slider("Horizontal Spacing", 0, 20, 1, s.spacingX or 6, function(v)
        s.spacingX = math.floor(v)
        ApplyRaidOverlaySettings()
    end)

    b:Slider("Vertical Spacing", 0, 20, 1, s.spacingY or 4, function(v)
        s.spacingY = math.floor(v)
        ApplyRaidOverlaySettings()
    end)

    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        s.scale = math.floor(v)
        ApplyRaidOverlaySettings()
    end)

    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("RaidFrames", {
        title = "Raid Frames",
        build = BuildRaidOverlaySettings,
    })
end
