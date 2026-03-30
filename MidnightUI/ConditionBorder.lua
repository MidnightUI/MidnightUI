-- =============================================================================
-- FILE PURPOSE:     Debuff hazard detection and visual tinting system for unit frames.
--                   Monitors the player's debuffs and drives a health-bar color tint +
--                   corner-bracket overlay on the PlayerFrame (and optionally party/raid
--                   frames). Classifies debuffs into DISPEL_ENUM categories: Magic, Curse,
--                   Disease, Poison, Bleed, Enrage. Surfaces a secondary hazard indicator
--                   when multiple debuff types are active simultaneously.
-- LOAD ORDER:       Loads after TargetPlayerTooltips.lua, before PlayerFrame.lua.
--                   PlayerFrame.lua, PartyFrames.lua, RaidFrames.lua, FocusFrame.lua,
--                   and PetFrame.lua all read from _G.MidnightUI_ConditionBorder.
-- DEFINES:          _G.MidnightUI_ConditionBorder (table M).
--                   M.Update(unit) — main entry point called by PlayerFrame on UNIT_AURA.
--                   M.Clear() — resets all tint state.
--                   M.RegisterDispelTrackingSettings() — registers the dispel overlay with Core.
-- READS:            MidnightUISettings.Combat.{debuffOverlayGlobalEnabled,
--                   debuffOverlayPlayerEnabled, condBorderDebug, dispelTracking.*}.
--                   MidnightUISettings.General.unitFrameBarStyle.
--                   Aura instance data via C_UnitAuras.GetAuraDataByAuraInstanceID.
-- WRITES:           _lastCondBorder* — 30+ state tracking variables for debuff lifecycle.
--                   _precombatNonTypedIIDs{} — pre-combat cache of non-dispellable aura IIDs.
--                   _dispelTrackButtons{} — dispel tracking overlay icon widgets.
-- DEPENDS ON:       MidnightUI_PlayerFrame (reads PlayerFrame.healthBar to apply tint).
--                   MidnightUI_Core (debug logging, overlay settings).
-- USED BY:          PlayerFrame.lua — UNIT_AURA calls M.Update("player").
--                   PartyFrames.lua, RaidFrames.lua, FocusFrame.lua, PetFrame.lua —
--                   each maintains its own copy of the hazard probe pipeline but may
--                   call ConditionBorder helpers for shared detection logic.
-- KEY FLOWS:
--   UNIT_AURA player → M.Update("player") → probe cycle:
--     1. Enumerate aura instances via AuraUtil.ForEachAura
--     2. Check each aura's dispelType (can be secret in combat)
--     3. For typed auras: use _condBorderTypeProbeCurves (color-probe matching)
--     4. For untyped auras: query _blizzDispelCache (pre-combat aura name→type map)
--     5. Select primary + secondary hazard by PRIORITY order
--     6. Apply tint to PlayerFrame.healthBar, pulse corner brackets, show secondary box
--   DEACTIVATE_GRACE_SEC (0.35s): hazard lingers this long after last debuff falls off.
-- GOTCHAS:
--   Color-probe system: aura.borderColor (and dispelType) is a secret value in combat.
--   The probe-curve system samples textures placed over the aura icon and compares their
--   sampled color against known debuff-type RGB signatures within HAZARD_CURVE_EPSILON.
--   This indirection is required to safely read "what kind of debuff is this?" in combat.
--   IGNORED_LOCKOUT_DEBUFF_SPELL_IDS: Bloodlust-family exhaustion and Last Resort MUST
--   be excluded — they are Magic-typed but must never drive the health bar tint color.
--   _precombatNonTypedIIDs: populated out-of-combat for permanent debuffs (Exhaustion etc.)
--   so in-combat code can skip them without reading their secret dispelType.
--   _secondaryDebuffBox: the small colored square in the frame corner indicating the
--   second-highest-priority debuff type when two types are active simultaneously.
--   STEP_LOG_THROTTLE_SEC / ERROR_LOG_THROTTLE_SEC: diagnostic log messages are throttled
--   per-key so combat spam doesn't flood the diagnostics console.
-- NAVIGATION:
--   DISPEL_ENUM / COND_BORDER_COLORS  — type→enum and type→RGB maps (line ~26)
--   IGNORED_LOCKOUT_DEBUFF_SPELL_IDS  — must-skip debuffs (line ~85)
--   PRIMARY_HAZARD_PRIORITY            — Magic>Curse>Disease>Poison>Bleed priority (line ~75)
--   _condBorderTypeProbeCurves         — per-type color-probe animation groups (line ~111)
--   M.Update(unit)                     — main hazard detection + tint entry point
--   M.Clear()                          — resets all state to inactive
--   EnsureDispelTrackingFrame()        — lazily builds the dispel icon strip overlay
-- =============================================================================

local M = {}
_G.MidnightUI_ConditionBorder = M

-- =========================================================================
--  CONSTANTS & COLORS
-- =========================================================================

local DISPEL_ENUM = {
    None    = 0,
    Magic   = 1,
    Curse   = 2,
    Disease = 3,
    Poison  = 4,
    Enrage  = 9,
    Bleed   = 11,
}

local COND_BORDER_COLORS = {
    Bleed   = { 0.95, 0.15, 0.15 }, -- Crimson Red
    Magic   = { 0.15, 0.55, 0.95 }, -- Azure Blue
    Curse   = { 0.70, 0.20, 0.95 }, -- Deep Purple
    Disease = { 0.80, 0.50, 0.10 }, -- Amber/Brown
    Poison  = { 0.15, 0.65, 0.20 }, -- True Forest Green (Not Lime)
}

local NEUTRAL_SHIMMER_COLOR = { 0.70, 0.70, 0.70 }

local HAZARD_COLOR_BY_ENUM = {
    [DISPEL_ENUM.Magic]   = COND_BORDER_COLORS.Magic,
    [DISPEL_ENUM.Curse]   = COND_BORDER_COLORS.Curse,
    [DISPEL_ENUM.Disease] = COND_BORDER_COLORS.Disease,
    [DISPEL_ENUM.Poison]  = COND_BORDER_COLORS.Poison,
    [DISPEL_ENUM.Enrage]  = COND_BORDER_COLORS.Bleed,
    [DISPEL_ENUM.Bleed]   = COND_BORDER_COLORS.Bleed,
}

local HAZARD_LABEL_BY_ENUM = {
    [DISPEL_ENUM.Magic]   = "MAGIC",
    [DISPEL_ENUM.Curse]   = "CURSE",
    [DISPEL_ENUM.Disease] = "DISEASE",
    [DISPEL_ENUM.Poison]  = "POISON",
    [DISPEL_ENUM.Enrage]  = "ENRAGE",
    [DISPEL_ENUM.Bleed]   = "BLEED",
}

local UNKNOWN_SECONDARY_TOKEN = "UNKNOWN"
local SECRET_SECONDARY_TOKEN = "SECRET"

local SECONDARY_HAZARD_PRIORITY = {
    DISPEL_ENUM.Bleed,
    DISPEL_ENUM.Magic,
    DISPEL_ENUM.Curse,
    DISPEL_ENUM.Disease,
    DISPEL_ENUM.Poison,
}

local PRIMARY_HAZARD_PRIORITY = {
    DISPEL_ENUM.Magic,
    DISPEL_ENUM.Curse,
    DISPEL_ENUM.Disease,
    DISPEL_ENUM.Poison,
    DISPEL_ENUM.Bleed,
}

-- Debuffs that should never drive the hazard tint overlay. These are lockout
-- auras (Bloodlust-family exhaustion and Last Resort cooldown lockout).
local IGNORED_LOCKOUT_DEBUFF_SPELL_IDS = {
    [57723] = true,  -- Exhaustion
    [57724] = true,  -- Sated
    [80354] = true,  -- Temporal Displacement
    [95809] = true,  -- Insanity
    [264689] = true, -- Fatigued
    [209258] = true, -- Last Resort
    [209261] = true, -- Last Resort (cooldown lockout variant)
}

local IGNORED_LOCKOUT_DEBUFF_NAMES = {
    ["exhaustion"] = true,
    ["sated"] = true,
    ["temporal displacement"] = true,
    ["insanity"] = true,
    ["fatigued"] = true,
    ["last resort"] = true,
}

-- =========================================================================
--  STATE
-- =========================================================================

local _condBorderCurve = nil
local _condBorderBleedOnlyCurve = nil
local _condBorderZeroProbeCurve = nil
local _condBorderTypeProbeCurves = {}
local _condBorderTypeProbeMatchColors = {}
local _condBorderBleedOnlyMatchColor = nil
local _blizzDispelCache = {}
local _blizzHookRegistered = false

-- Pre-combat cache: aura instance IDs known to have no tracked dispel type.
-- Populated while outside combat (when aura fields are readable); consulted
-- during combat to skip permanent debuffs like Exhaustion/Sated whose secret
-- borderColor would otherwise produce a black health bar tint.
local _precombatNonTypedIIDs = {}

local _secondaryDebuffBox = nil
local _secondaryDebuffBoxVisible = false
local _secondaryDebuffBoxEnum = nil
local _secondaryDebuffBoxRGB = nil
local _secondaryDebuffBoxLastDecisionKey = nil

local _condBorderActive = false
local _lastCondBorderType = nil
local _lastCondBorderIID  = nil
local _lastCondBorderPrimaryEnum = nil
local _lastCondBorderAccentType = nil
local _lastCondBorderExtraType = nil
local _lastCondBorderStep = "INIT"
local _lastCondBorderStepDetail = nil
local _lastCondBorderError = nil
local _lastCondBorderErrorCount = 0
local _lastCondBorderUpdateSeq = 0
local _lastCondBorderTrackerBleedMethod = nil
local _lastCondBorderBarTint = "OFF"
local _lastCondBorderBarTintRGB = nil
local _lastCondBorderBarTintEnum = nil
local _lastCondBorderLoggedStepKey = nil
local _lastCondBorderStepLogAt = 0
local _lastCondBorderSignalStepLogByKey = {}
local _lastCondBorderErrorLogByKey = {}
local _playerFrame = nil
local _lastCondBorderDetectedAt = 0
local _lastCondBorderOverlapSignature = "none"
local _lastCondBorderOverlapPrimaryEnum = nil
local _lastCondBorderOverlapSecondaryEnum = nil
local _lastCondBorderTypeBoxState = "OFF"
local _lastCondBorderTypeBoxEnum = nil
local _lastCondBorderTypeBoxRGB = nil
local _lastCondBorderTypeBoxR = nil
local _lastCondBorderTypeBoxG = nil
local _lastCondBorderTypeBoxB = nil
local _lastCondBorderBleedCurveIID = nil
local _lastCondBorderBleedCurveCandidates = 0
local _lastCondBorderAuraEnumLogKey = nil
local _lastCondBorderActiveCollectLogKey = nil
local _lastCondBorderSecondaryCandidateLogKey = nil
local _lastCondBorderSecretActivateLogKey = nil
local _lastCondBorderSecretOverlayFillLogKey = nil
local _lastCondBorderSweepTraceKey = nil
local _reloadDungeonDiagSession = 0
local _reloadDungeonDiagActiveKey = nil
local _reloadDungeonDiagLastPhase = nil
local _reloadDungeonDiagLastSummary = nil
local _dispelTrackFrame = nil
local _dispelTrackButtons = {}
local _dispelTrackSettingsRegistered = false
local _dispelTrackLocked = true

local STEP_LOG_THROTTLE_SEC = 2.0
local SIGNAL_STEP_LOG_THROTTLE_SEC = 2.0
local ERROR_LOG_THROTTLE_SEC = 1.25
local DEACTIVATE_GRACE_SEC = 0.35
local DISPEL_TRACKING_BASE_ICON_SIZE = 20
local DISPEL_TRACKING_BASE_ICON_GAP = 4
local DISPEL_TRACKING_DEFAULT_MAX = 8
local DISPEL_TRACKING_MIN = 1
local DISPEL_TRACKING_MAX = 20
local DISPEL_TRACKING_MIN_LONG_AXIS = 240
local DISPEL_TRACKING_MIN_SHORT_AXIS = 36
local DISPEL_TRACKING_ICON_SCALE_MIN = 50
local DISPEL_TRACKING_ICON_SCALE_MAX = 200
local DISPEL_TRACKING_ORIENTATION_HORIZONTAL = "HORIZONTAL"
local DISPEL_TRACKING_ORIENTATION_VERTICAL = "VERTICAL"

local EnsureSecondaryDebuffBox
local EnsureDispelTrackingFrame
local EnsureDispelTrackingDragOverlay
local RefreshDispelTrackingOverlay
local RegisterDispelTrackingOverlaySettings

-- =========================================================================
--  SETTINGS & LOGGING
-- =========================================================================

local function IsSecretValue(value)
    if type(issecretvalue) ~= "function" then
        return false
    end
    local ok, result = pcall(issecretvalue, value)
    return ok and result == true
end

local function NormalizeIgnoredAuraName(name)
    if type(name) ~= "string" or IsSecretValue(name) then
        return nil
    end
    local okLower, lower = pcall(string.lower, name)
    if not okLower or type(lower) ~= "string" then
        return nil
    end
    return lower
end

local function CoerceIgnoredSpellID(value)
    if value == nil or IsSecretValue(value) then
        return nil
    end
    local okNum, num = pcall(tonumber, value)
    if not okNum or type(num) ~= "number" or num <= 0 then
        return nil
    end
    return num
end

local function ResolveIgnoredAuraSpellID(aura)
    if type(aura) ~= "table" then
        return nil
    end
    local spellID = CoerceIgnoredSpellID(aura.spellId)
    if spellID then
        return spellID
    end
    spellID = CoerceIgnoredSpellID(aura.spellID)
    if spellID then
        return spellID
    end
    return CoerceIgnoredSpellID(aura.id)
end

local function ResolveIgnoredAuraName(aura)
    if type(aura) ~= "table" then
        return nil
    end
    local nameKey = NormalizeIgnoredAuraName(aura.name)
    if nameKey then
        return nameKey
    end
    nameKey = NormalizeIgnoredAuraName(aura.auraName)
    if nameKey then
        return nameKey
    end
    return NormalizeIgnoredAuraName(aura.spellName)
end

local function ShouldIgnoreLockoutDebuffAura(aura)
    if type(aura) ~= "table" then
        return false
    end
    local spellID = ResolveIgnoredAuraSpellID(aura)
    if spellID and IGNORED_LOCKOUT_DEBUFF_SPELL_IDS[spellID] then
        return true
    end
    local nameKey = ResolveIgnoredAuraName(aura)
    if nameKey and IGNORED_LOCKOUT_DEBUFF_NAMES[nameKey] then
        return true
    end
    return false
end

local function ShouldIgnoreLockoutDebuffByIID(unit, auraInstanceID, inRestricted)
    if not unit or not auraInstanceID then
        return false
    end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByAuraInstanceID then
        return false
    end
    local aura = nil
    if inRestricted then
        local okAura, result = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, auraInstanceID)
        if okAura then
            aura = result
        end
    else
        aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
    end
    if not aura then
        return false
    end
    return ShouldIgnoreLockoutDebuffAura(aura)
end

local function SafeToString(value)
    if value == nil then
        return "nil"
    end
    if IsSecretValue(value) then
        return "[secret]"
    end
    local ok, s = pcall(tostring, value)
    if ok then
        return s
    end
    return "<unprintable>"
end

local function IsEnabled()
    local s = MidnightUISettings
    if s and s.Combat then
        if s.Combat.debuffBorderEnabled == false then
            return false
        end
        if s.Combat.debuffOverlayGlobalEnabled == false then
            return false
        end
        if s.Combat.debuffOverlayPlayerEnabled == false then
            return false
        end
    end
    return true
end

local function IsDebuffOverlayGloballyEnabled()
    local s = MidnightUISettings
    if s and s.Combat and s.Combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    return true
end

local function EnsureCombatSettingsTable()
    if not MidnightUISettings then
        MidnightUISettings = {}
    end
    if not MidnightUISettings.Combat then
        MidnightUISettings.Combat = {}
    end
    local combat = MidnightUISettings.Combat
    if combat.debuffBorderEnabled == nil then
        combat.debuffBorderEnabled = true
    end
    if combat.debuffOverlayGlobalEnabled == nil then
        combat.debuffOverlayGlobalEnabled = true
    end
    if combat.debuffOverlayPlayerEnabled == nil then
        combat.debuffOverlayPlayerEnabled = true
    end
    if combat.debuffOverlayFocusEnabled == nil then
        combat.debuffOverlayFocusEnabled = true
    end
    if combat.debuffOverlayPartyEnabled == nil then
        combat.debuffOverlayPartyEnabled = true
    end
    if combat.debuffOverlayRaidEnabled == nil then
        combat.debuffOverlayRaidEnabled = true
    end
    if combat.debuffOverlayTargetOfTargetEnabled == nil then
        combat.debuffOverlayTargetOfTargetEnabled = true
    end
    if combat.dispelTrackingEnabled == nil then
        combat.dispelTrackingEnabled = true
    end
    if combat.dispelTrackingMaxShown == nil then
        combat.dispelTrackingMaxShown = DISPEL_TRACKING_DEFAULT_MAX
    end
    if combat.dispelTrackingIconScale == nil then
        combat.dispelTrackingIconScale = 100
    end
    if combat.dispelTrackingOrientation == nil then
        combat.dispelTrackingOrientation = DISPEL_TRACKING_ORIENTATION_HORIZONTAL
    end
    if combat.dispelTrackingAlpha == nil then
        combat.dispelTrackingAlpha = 1.0
    end
    return combat
end

local function ClampDispelTrackingCount(value)
    local num = tonumber(value) or DISPEL_TRACKING_DEFAULT_MAX
    num = math.floor(num + 0.5)
    if num < DISPEL_TRACKING_MIN then
        num = DISPEL_TRACKING_MIN
    elseif num > DISPEL_TRACKING_MAX then
        num = DISPEL_TRACKING_MAX
    end
    return num
end

local function ClampDispelTrackingIconScale(value)
    local num = tonumber(value) or 100
    num = math.floor(num + 0.5)
    if num < DISPEL_TRACKING_ICON_SCALE_MIN then
        num = DISPEL_TRACKING_ICON_SCALE_MIN
    elseif num > DISPEL_TRACKING_ICON_SCALE_MAX then
        num = DISPEL_TRACKING_ICON_SCALE_MAX
    end
    return num
end

local function GetDispelTrackingIconMetrics(iconScale)
    local clampedScale = ClampDispelTrackingIconScale(iconScale)
    local iconSize = math.max(12, math.floor((DISPEL_TRACKING_BASE_ICON_SIZE * clampedScale / 100) + 0.5))
    local iconGap = math.max(2, math.floor((DISPEL_TRACKING_BASE_ICON_GAP * clampedScale / 100) + 0.5))
    return iconSize, iconGap
end

local function NormalizeDispelTrackingOrientation(value)
    if type(value) == "string" then
        local upper = string.upper(value)
        if upper == DISPEL_TRACKING_ORIENTATION_VERTICAL then
            return DISPEL_TRACKING_ORIENTATION_VERTICAL
        end
    end
    return DISPEL_TRACKING_ORIENTATION_HORIZONTAL
end

local function GetDispelTrackingStripLength(maxShown, iconScale)
    local shown = ClampDispelTrackingCount(maxShown)
    local iconSize, iconGap = GetDispelTrackingIconMetrics(iconScale)
    return (shown * iconSize) + ((shown - 1) * iconGap)
end

local function GetDispelTrackingLayout(maxShown, iconScale, orientation)
    local normalized = NormalizeDispelTrackingOrientation(orientation)
    local stripLength = GetDispelTrackingStripLength(maxShown, iconScale)
    local iconSize, iconGap = GetDispelTrackingIconMetrics(iconScale)
    local width, height, iconStartX, iconStartY, strideX, strideY
    if normalized == DISPEL_TRACKING_ORIENTATION_VERTICAL then
        width = math.max(iconSize, DISPEL_TRACKING_MIN_SHORT_AXIS)
        height = math.max(stripLength, DISPEL_TRACKING_MIN_LONG_AXIS)
        iconStartX = 0
        iconStartY = math.floor(((height - stripLength) / 2) + 0.5)
        strideX = 0
        strideY = iconSize + iconGap
    else
        width = math.max(stripLength, DISPEL_TRACKING_MIN_LONG_AXIS)
        height = math.max(iconSize, DISPEL_TRACKING_MIN_SHORT_AXIS)
        iconStartX = math.floor(((width - stripLength) / 2) + 0.5)
        iconStartY = 0
        strideX = iconSize + iconGap
        strideY = 0
    end
    return {
        orientation = normalized,
        width = width,
        height = height,
        iconSize = iconSize,
        iconGap = iconGap,
        iconStartX = iconStartX,
        iconStartY = iconStartY,
        strideX = strideX,
        strideY = strideY,
    }
end

local function IsMovementModeUnlocked()
    local s = MidnightUISettings
    if s and s.Messenger and s.Messenger.locked ~= nil then
        _dispelTrackLocked = (s.Messenger.locked ~= false)
    end
    return _dispelTrackLocked == false
end

local function IsDispelTrackingEnabled()
    local combat = EnsureCombatSettingsTable()
    if combat.dispelTrackingEnabled == false then
        return false
    end
    if not IsDebuffOverlayGloballyEnabled() then
        return false
    end
    return IsEnabled()
end

local function IsDiagnosticsEnabled()
    local diag = _G.MidnightUI_Diagnostics
    if not diag then
        return false
    end
    if type(diag.IsEnabled) == "function" then
        local ok, enabled = pcall(diag.IsEnabled)
        return ok and enabled == true
    end
    return true
end

local function IsCondBorderDebugEnabled()
    local s = MidnightUISettings
    return s and s.PlayerFrame and s.PlayerFrame.condBorderDebug == true
end

local function EmitDiagnosticsLogWithSource(source, message)
    local src = SafeToString(source or "ConditionBorder")
    local msg = SafeToString(message)
    if msg == "" then
        return
    end

    local diag = _G.MidnightUI_Diagnostics
    if diag and type(diag.LogDebugSource) == "function" and IsDiagnosticsEnabled() then
        pcall(diag.LogDebugSource, src, msg)
        return
    end

    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. msg)
end

local function EmitDiagnosticsLog(message)
    EmitDiagnosticsLogWithSource("ConditionBorder", message)
end

local function IsCondBorderVerboseEnabled()
    local s = MidnightUISettings
    return s and s.PlayerFrame and s.PlayerFrame.condBorderDebugVerbose == true
end

local function CondBorderLog(msg)
    if not IsCondBorderDebugEnabled() then
        return
    end
    if not IsCondBorderVerboseEnabled() then
        if type(msg) ~= "string" then
            return
        end
        -- Keep concise player-tint transitions in normal debug mode; hide the rest as noise.
        if string.find(msg, "barTint=", 1, true) == nil then
            return
        end
    end
    EmitDiagnosticsLog(msg)
end

local function CondBorderSweepLog(msg)
    if not IsCondBorderDebugEnabled() then
        return
    end
    if not IsCondBorderVerboseEnabled() then
        return
    end
    EmitDiagnosticsLogWithSource("ConditionBorderSweep", msg)
end

local function CondBorderReloadLog(msg)
    if not IsCondBorderDebugEnabled() then
        return
    end
    if not IsCondBorderVerboseEnabled() then
        return
    end
    EmitDiagnosticsLog("reloadDiag " .. SafeToString(msg))
end

local function GetDebugNow()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    if GetTime then
        return GetTime()
    end
    return 0
end

local function GetRestrictionState()
    local inRestricted = false
    if type(InCombatLockdown) == "function" then
        local ok, result = pcall(InCombatLockdown)
        inRestricted = ok and (result == true)
    end
    if (not inRestricted) and type(UnitAffectingCombat) == "function" then
        local ok, result = pcall(UnitAffectingCombat, "player")
        inRestricted = ok and (result == true)
    end
    return inRestricted
end

local function GetInstanceContext()
    local inInstance, instanceType = false, "none"
    if type(IsInInstance) == "function" then
        local ok, inInst, instType = pcall(IsInInstance)
        if ok then
            inInstance = inInst == true
            if type(instType) == "string" and instType ~= "" then
                instanceType = instType
            end
        end
    end

    local name, infoType, difficultyID, difficultyName, _, _, _, mapID
    if type(GetInstanceInfo) == "function" then
        local ok, n, t, dID, dName, _, _, _, mID = pcall(GetInstanceInfo)
        if ok then
            name = n
            infoType = t
            difficultyID = dID
            difficultyName = dName
            mapID = mID
        end
    end

    if type(infoType) == "string" and infoType ~= "" then
        instanceType = infoType
    end

    return inInstance, instanceType, name, difficultyID, difficultyName, mapID
end

local function IsDungeonInstanceType(instanceType)
    return instanceType == "party" or instanceType == "scenario"
end

local function IsSignalStep(step)
    local s = SafeToString(step)
    return s == "OVERLAY_PULSE_ON"
        or s == "OVERLAY_PULSE_OFF"
end

local function ShouldEmitStep(step)
    return IsSignalStep(step)
end

local function MarkStep(step, detail)
    _lastCondBorderStep = step
    _lastCondBorderStepDetail = detail

    if not ShouldEmitStep(step) then
        return
    end
    if not IsCondBorderVerboseEnabled() then
        return
    end

    local key
    if step == "UPDATE_BEGIN" then
        key = SafeToString(step)
    else
        key = SafeToString(step) .. "|" .. SafeToString(detail)
    end

    local now = GetDebugNow()
    local signal = IsSignalStep(step)

    if signal then
        local lastAt = _lastCondBorderSignalStepLogByKey[key] or 0
        if now > 0 and (now - lastAt) < SIGNAL_STEP_LOG_THROTTLE_SEC then
            return
        end
        _lastCondBorderSignalStepLogByKey[key] = now
    else
        if key == _lastCondBorderLoggedStepKey then
            return
        end
        if now > 0 and (now - _lastCondBorderStepLogAt) < STEP_LOG_THROTTLE_SEC then
            return
        end
        _lastCondBorderLoggedStepKey = key
        _lastCondBorderStepLogAt = now
    end

    if detail ~= nil then
        CondBorderLog("step=" .. SafeToString(step) .. " | " .. SafeToString(detail))
    else
        CondBorderLog("step=" .. SafeToString(step))
    end
end

local function MarkError(step, err)
    _lastCondBorderErrorCount = _lastCondBorderErrorCount + 1
    _lastCondBorderError = SafeToString(err)
    _lastCondBorderStep = step
    _lastCondBorderStepDetail = _lastCondBorderError

    local now = GetDebugNow()
    local key = SafeToString(step) .. "|" .. SafeToString(_lastCondBorderError)
    local lastAt = _lastCondBorderErrorLogByKey[key] or 0
    if now > 0 and (now - lastAt) < ERROR_LOG_THROTTLE_SEC then
        return
    end
    _lastCondBorderErrorLogByKey[key] = now

    CondBorderLog("ERROR step=" .. SafeToString(step) .. " :: " .. SafeToString(_lastCondBorderError))
end

local function ResolveHazardEnumFromTintSource(source)
    if type(source) ~= "string" then
        return nil
    end
    local upper = string.upper(source)
    if upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then return DISPEL_ENUM.Bleed end
    if upper:find("MAGIC", 1, true) then return DISPEL_ENUM.Magic end
    if upper:find("CURSE", 1, true) then return DISPEL_ENUM.Curse end
    if upper:find("DISEASE", 1, true) then return DISPEL_ENUM.Disease end
    if upper:find("POISON", 1, true) then return DISPEL_ENUM.Poison end
    return nil
end

local function NormalizeTintHazardEnum(dt)
    if dt == DISPEL_ENUM.Enrage then
        return DISPEL_ENUM.Bleed
    end
    if dt == DISPEL_ENUM.Magic
        or dt == DISPEL_ENUM.Curse
        or dt == DISPEL_ENUM.Disease
        or dt == DISPEL_ENUM.Poison
        or dt == DISPEL_ENUM.Bleed then
        return dt
    end
    return nil
end

local function ResolveHazardEnumFromTintColor(r, g, b)
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) then
        return nil
    end
    local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)
    if not rn or not gn or not bn then
        return nil
    end
    if IsSecretValue(rn) or IsSecretValue(gn) or IsSecretValue(bn) then
        return nil
    end
    local bestEnum = nil
    local bestDist = nil
    for enum, color in pairs(HAZARD_COLOR_BY_ENUM) do
        local normalizedEnum = NormalizeTintHazardEnum(enum)
        if normalizedEnum and color then
            local dr = rn - (color[1] or 0)
            local dg = gn - (color[2] or 0)
            local db = bn - (color[3] or 0)
            local dist = (dr * dr) + (dg * dg) + (db * db)
            if bestDist == nil or dist < bestDist then
                bestDist = dist
                bestEnum = normalizedEnum
            end
        end
    end
    if bestDist and bestDist <= 0.08 then
        return bestEnum
    end
    return nil
end

local function SyncPlayerFrameBarTint(isActive, r, g, b, source)
    local fn = _G.MidnightUI_SetPlayerFrameConditionTint
    if type(fn) ~= "function" then
        return
    end

    local ok, changedOrErr = pcall(fn, isActive == true, r, g, b, source)
    if not ok then
        MarkError("BAR_TINT_SYNC", changedOrErr)
        return
    end
    if changedOrErr ~= true then
        return
    end

    if isActive == true then
        _lastCondBorderBarTint = "ON"
        local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)
        local resolvedEnum = NormalizeTintHazardEnum(ResolveHazardEnumFromTintSource(source))
        if not resolvedEnum then
            resolvedEnum = ResolveHazardEnumFromTintColor(rn, gn, bn)
        end
        _lastCondBorderBarTintEnum = resolvedEnum
        if rn and gn and bn and not IsSecretValue(rn) and not IsSecretValue(gn) and not IsSecretValue(bn) then
            _lastCondBorderBarTintRGB = string.format("%.3f,%.3f,%.3f", rn, gn, bn)
        else
            _lastCondBorderBarTintRGB = "secret"
        end
    else
        _lastCondBorderBarTint = "OFF"
        _lastCondBorderBarTintRGB = nil
        _lastCondBorderBarTintEnum = nil
    end
end

local function FormatRGBForLog(r, g, b)
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) then
        return "secret"
    end
    local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)
    if rn and gn and bn then
        return string.format("%.3f,%.3f,%.3f", rn, gn, bn)
    end
    return SafeToString(r) .. "," .. SafeToString(g) .. "," .. SafeToString(b)
end

local function IsCurveColorMatch(color, expected)
    if not color or not expected then
        return false
    end

    if color.IsEqualTo then
        local okEq, matched = pcall(color.IsEqualTo, color, expected)
        if okEq and matched == true then
            return true
        end
    end

    if not color.GetRGBA or not expected.GetRGBA then
        return false
    end
    local okColor, r, g, b, a = pcall(color.GetRGBA, color)
    local okExpected, er, eg, eb, ea = pcall(expected.GetRGBA, expected)
    if not okColor or not okExpected then
        return false
    end
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) or IsSecretValue(a) then
        return false
    end
    if IsSecretValue(er) or IsSecretValue(eg) or IsSecretValue(eb) or IsSecretValue(ea) then
        return false
    end

    local rn, gn, bn, an = tonumber(r), tonumber(g), tonumber(b), tonumber(a)
    local ern, egn, ebn, ean = tonumber(er), tonumber(eg), tonumber(eb), tonumber(ea)
    if not (rn and gn and bn and an and ern and egn and ebn and ean) then
        return false
    end

    local eps = 0.001
    return math.abs(rn - ern) <= eps
        and math.abs(gn - egn) <= eps
        and math.abs(bn - ebn) <= eps
        and math.abs(an - ean) <= eps
end

local function IsCurveColorDifferent(colorA, colorB)
    if not colorA or not colorB then
        return false
    end

    if colorA.IsEqualTo then
        local okEq, same = pcall(colorA.IsEqualTo, colorA, colorB)
        if okEq then
            return same ~= true
        end
    end

    if not colorA.GetRGBA or not colorB.GetRGBA then
        return false
    end
    local okA, ar, ag, ab, aa = pcall(colorA.GetRGBA, colorA)
    local okB, br, bg, bb, ba = pcall(colorB.GetRGBA, colorB)
    if not okA or not okB then
        return false
    end
    if IsSecretValue(ar) or IsSecretValue(ag) or IsSecretValue(ab) or IsSecretValue(aa) then
        return false
    end
    if IsSecretValue(br) or IsSecretValue(bg) or IsSecretValue(bb) or IsSecretValue(ba) then
        return false
    end

    local arn, agn, abn, aan = tonumber(ar), tonumber(ag), tonumber(ab), tonumber(aa)
    local brn, bgn, bbn, ban = tonumber(br), tonumber(bg), tonumber(bb), tonumber(ba)
    if not (arn and agn and abn and aan and brn and bgn and bbn and ban) then
        return false
    end

    local eps = 0.001
    return math.abs(arn - brn) > eps
        or math.abs(agn - bgn) > eps
        or math.abs(abn - bbn) > eps
        or math.abs(aan - ban) > eps
end

local function LogAuraEnum(source, auraInstanceID, enumValue, inRestricted)
    if not IsCondBorderVerboseEnabled() then
        return
    end
    local enumLabel = "NONE"
    if enumValue ~= nil then
        local normalized = enumValue
        if normalized == DISPEL_ENUM.Enrage then
            normalized = DISPEL_ENUM.Bleed
        end
        enumLabel = HAZARD_LABEL_BY_ENUM[normalized] or SafeToString(normalized)
    end
    local key = SafeToString(source)
        .. "|" .. SafeToString(auraInstanceID)
        .. "|" .. enumLabel
        .. "|" .. (inRestricted and "1" or "0")
    if _lastCondBorderAuraEnumLogKey == key then
        return
    end
    _lastCondBorderAuraEnumLogKey = key
    CondBorderLog("auraEnum src=" .. SafeToString(source)
        .. " iid=" .. SafeToString(auraInstanceID)
        .. " enum=" .. enumLabel
        .. " restricted=" .. (inRestricted and "YES" or "NO"))
end

-- =========================================================================
--  COLOUR CURVE
-- =========================================================================

local function GetCondBorderCurve()
    if _condBorderCurve then return _condBorderCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)

    local c = COND_BORDER_COLORS
    -- 0.9 Alpha ensures a rich color payload is delivered
    curve:AddPoint(DISPEL_ENUM.None,    CreateColor(0,          0,          0,          0   ))
    curve:AddPoint(DISPEL_ENUM.Magic,   CreateColor(c.Magic[1],   c.Magic[2],   c.Magic[3],   0.90))
    curve:AddPoint(DISPEL_ENUM.Curse,   CreateColor(c.Curse[1],   c.Curse[2],   c.Curse[3],   0.90))
    curve:AddPoint(DISPEL_ENUM.Disease, CreateColor(c.Disease[1], c.Disease[2], c.Disease[3], 0.90))
    curve:AddPoint(DISPEL_ENUM.Poison,  CreateColor(c.Poison[1],  c.Poison[2],  c.Poison[3],  0.90))
    curve:AddPoint(DISPEL_ENUM.Enrage,  CreateColor(c.Bleed[1],   c.Bleed[2],   c.Bleed[3],   0.90))
    curve:AddPoint(DISPEL_ENUM.Bleed,   CreateColor(c.Bleed[1],   c.Bleed[2],   c.Bleed[3],   0.90))

    _condBorderCurve = curve
    return curve
end

local function GetCondBorderBleedOnlyCurve()
    if _condBorderBleedOnlyCurve then return _condBorderBleedOnlyCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(DISPEL_ENUM.None,    CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Magic,   CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Curse,   CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Poison,  CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Enrage,  CreateColor(1, 1, 1, 1))
    curve:AddPoint(DISPEL_ENUM.Bleed,   CreateColor(1, 1, 1, 1))

    _condBorderBleedOnlyCurve = curve
    _condBorderBleedOnlyMatchColor = CreateColor(1, 1, 1, 1)
    return curve
end

local function GetCondBorderZeroProbeCurve()
    if _condBorderZeroProbeCurve then
        return _condBorderZeroProbeCurve
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(DISPEL_ENUM.None,    CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Magic,   CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Curse,   CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Poison,  CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Enrage,  CreateColor(1, 1, 1, 0))
    curve:AddPoint(DISPEL_ENUM.Bleed,   CreateColor(1, 1, 1, 0))

    _condBorderZeroProbeCurve = curve
    return curve
end

-- =========================================================================
--  FRAME CONSTRUCTION: SUBTLE OVERHAUL
-- =========================================================================

function M.BuildCondBorder(frame)
    local condBorderLevel = frame:GetFrameLevel() + 30
    local B_THICK = 2
    local B_LEN = 12
    local OFFSET = 2

    local condBorder = CreateFrame("Frame", nil, frame)
    condBorder:SetAllPoints(frame)
    condBorder:SetFrameLevel(condBorderLevel)
    condBorder:SetAlpha(0)
    condBorder:Hide()

    local function MakeSolid(parent)
        local t = parent:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        return t
    end

    -- 1. Inner Core Fill (very subtle translucent tint)
    local bgFill = MakeSolid(condBorder)
    bgFill:SetAllPoints(frame)
    bgFill:SetBlendMode("ADD")
    bgFill:SetAlpha(0.12)
    condBorder.bgFill = bgFill

    -- Main pulse on the primary overlay (pulse-only mode, no moving sweep bar).
    local fillPulse = bgFill:CreateAnimationGroup()
    fillPulse:SetLooping("BOUNCE")
    local fillFade = fillPulse:CreateAnimation("Alpha")
    -- Keep pulse centered around base alpha to avoid first-frame brightness pop on activation.
    fillFade:SetFromAlpha(0.12)
    fillFade:SetToAlpha(0.13)
    fillFade:SetDuration(1.80)
    fillFade:SetSmoothing("IN_OUT")
    condBorder.fillPulse = fillPulse
    CondBorderLog("overlayAnim fillAlpha=0.12->0.13 dur=1.80")

    -- 2. Tactical Corner Brackets
    local bracketFrame = CreateFrame("Frame", nil, condBorder)
    bracketFrame:SetAllPoints(frame)
    bracketFrame:SetAlpha(0.56)
    
    local brackets = {}
    local function AddBracket(point, x, y, w, h)
        local t = MakeSolid(bracketFrame)
        t:SetPoint(point, x, y)
        t:SetSize(w, h)
        table.insert(brackets, t)
    end

    AddBracket("TOPLEFT", -OFFSET, OFFSET, B_LEN, B_THICK)
    AddBracket("TOPLEFT", -OFFSET, OFFSET, B_THICK, B_LEN)
    AddBracket("TOPRIGHT", OFFSET, OFFSET, B_LEN, B_THICK)
    AddBracket("TOPRIGHT", OFFSET, OFFSET, B_THICK, B_LEN)
    AddBracket("BOTTOMLEFT", -OFFSET, -OFFSET, B_LEN, B_THICK)
    AddBracket("BOTTOMLEFT", -OFFSET, -OFFSET, B_THICK, B_LEN)
    AddBracket("BOTTOMRIGHT", OFFSET, -OFFSET, B_LEN, B_THICK)
    AddBracket("BOTTOMRIGHT", OFFSET, -OFFSET, B_THICK, B_LEN)

    condBorder.brackets = brackets
    condBorder.bracketFrame = bracketFrame

    -- Soft Bracket Breathing Animation
    local bracketGroup = bracketFrame:CreateAnimationGroup()
    bracketGroup:SetLooping("BOUNCE")
    local bAlpha = bracketGroup:CreateAnimation("Alpha")
    -- Subtle range prevents first-frame brightness pop on activation.
    bAlpha:SetFromAlpha(0.52)
    bAlpha:SetToAlpha(0.62)
    bAlpha:SetDuration(1.80)
    bAlpha:SetSmoothing("IN_OUT")
    condBorder.bracketGroup = bracketGroup
    CondBorderLog("overlayAnim bracketAlpha=0.52->0.62 dur=1.80")

    -- Moving overlap sweep removed for pulse-only mode.
    condBorder.overlapAlert = nil
    CondBorderLog("visualMode=PULSE_ONLY + SECONDARY_FRAME_SWEEP")
    condBorder.shimmer = nil
    condBorder.shimmerExtra = nil
    condBorder.scanGroup = nil
    condBorder.scanGroupExtra = nil

    -- Secondary debuff sweep is managed independently from the main overlay.
    EnsureSecondaryDebuffBox(frame)

    -- 4. Smooth Fade-In / Fade-Out Controllers
    local fadeIn = condBorder:CreateAnimationGroup()
    local fInAnim = fadeIn:CreateAnimation("Alpha")
    fInAnim:SetFromAlpha(0)
    fInAnim:SetToAlpha(1)
    fInAnim:SetDuration(0.4)
    fInAnim:SetSmoothing("OUT")
    fadeIn:SetScript("OnPlay", function() 
        condBorder:SetAlpha(0)
        condBorder:Show() 
    end)
    fadeIn:SetScript("OnFinished", function(self, requested)
        if not requested then condBorder:SetAlpha(1) end
    end)
    condBorder.fadeIn = fadeIn

    local fadeOut = condBorder:CreateAnimationGroup()
    local fOutAnim = fadeOut:CreateAnimation("Alpha")
    fOutAnim:SetFromAlpha(1)
    fOutAnim:SetToAlpha(0)
    fOutAnim:SetDuration(0.6)
    fOutAnim:SetSmoothing("OUT")
    fadeOut:SetScript("OnPlay", function() 
        condBorder:SetAlpha(1) 
    end)
    fadeOut:SetScript("OnFinished", function(self, requested)
        if not requested then
            condBorder:SetAlpha(0)
            condBorder:Hide()
            if condBorder.bracketGroup then condBorder.bracketGroup:Stop() end
            if condBorder.bracketFrame then
                condBorder.bracketFrame:SetAlpha(0.56)
            end
            if condBorder.fillPulse and condBorder.fillPulse:IsPlaying() then
                condBorder.fillPulse:Stop()
            end
            if condBorder.bgFill then
                condBorder.bgFill:SetAlpha(0.12)
            end
            if condBorder._muiPendingBarTintOff == true then
                condBorder._muiPendingBarTintOff = false
                SyncPlayerFrameBarTint(false, nil, nil, nil, "DEACTIVATE_FADE_DONE")
            end
        end
    end)
    condBorder.fadeOut = fadeOut

    return condBorder
end

-- =========================================================================
--  COLOR & ANIMATION HELPERS
-- =========================================================================

local TrackerSaysBleedActive
local ScanForBleedAuraID
local TrackerHasTypeActive

local function NormalizeDispelToken(dt)
    local t = type(dt)
    if t == "number" then
        if IsSecretValue(dt) then
            return nil
        end
        return dt
    end
    if t ~= "string" then
        return nil
    end

    if IsSecretValue(dt) then
        return nil
    end

    local s = string.lower(dt)
    if s == "magic" then return DISPEL_ENUM.Magic end
    if s == "curse" then return DISPEL_ENUM.Curse end
    if s == "disease" then return DISPEL_ENUM.Disease end
    if s == "poison" then return DISPEL_ENUM.Poison end
    if s == "bleed" then return DISPEL_ENUM.Bleed end
    if s == "enrage" then return DISPEL_ENUM.Enrage end
    if s == "none" then return DISPEL_ENUM.None end
    return nil
end

local function NormalizeHazardEnum(dt)
    local e = NormalizeDispelToken(dt)
    if e == DISPEL_ENUM.Enrage then
        return DISPEL_ENUM.Bleed
    end
    return e
end

local function NormalizeBleedLikeEnum(dt)
    local e = NormalizeDispelToken(dt)
    if e == DISPEL_ENUM.Enrage or e == DISPEL_ENUM.Bleed then
        return e
    end
    return nil
end

local function GetHazardRGB(enum)
    local c = HAZARD_COLOR_BY_ENUM[enum]
    if c then
        return c[1], c[2], c[3]
    end
    return 1, 1, 1
end

local function IsTrackedHazardEnum(dt)
    return dt == DISPEL_ENUM.Magic
        or dt == DISPEL_ENUM.Curse
        or dt == DISPEL_ENUM.Disease
        or dt == DISPEL_ENUM.Poison
        or dt == DISPEL_ENUM.Bleed
end

local function GetCondBorderTypeProbeCurve(targetEnum)
    local normalizedTarget = NormalizeHazardEnum(targetEnum)
    if not IsTrackedHazardEnum(normalizedTarget) then
        return nil
    end
    if _condBorderTypeProbeCurves[normalizedTarget] then
        return _condBorderTypeProbeCurves[normalizedTarget]
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)

    local function Add(enumVal)
        local normalized = NormalizeHazardEnum(enumVal)
        local alpha = (normalized == normalizedTarget) and 1 or 0
        curve:AddPoint(enumVal, CreateColor(1, 1, 1, alpha))
    end

    Add(DISPEL_ENUM.None)
    Add(DISPEL_ENUM.Magic)
    Add(DISPEL_ENUM.Curse)
    Add(DISPEL_ENUM.Disease)
    Add(DISPEL_ENUM.Poison)
    Add(DISPEL_ENUM.Enrage)
    Add(DISPEL_ENUM.Bleed)

    _condBorderTypeProbeCurves[normalizedTarget] = curve
    _condBorderTypeProbeMatchColors[normalizedTarget] = CreateColor(1, 1, 1, 1)
    return curve
end

local function ResolveHazardEnumByCurve(unit, auraInstanceID, inRestricted)
    if not unit or not auraInstanceID then
        return nil, nil
    end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDispelTypeColor then
        return nil, nil
    end

    local function MatchesCurve(hazardEnum)
        local normalizedHazard = NormalizeHazardEnum(hazardEnum)
        local curve = GetCondBorderTypeProbeCurve(normalizedHazard)
        local zeroCurve = GetCondBorderZeroProbeCurve()
        if not curve then
            return false, nil
        end
        local color = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve)
        if not color or not color.GetRGBA then
            return false, nil
        end
        if zeroCurve then
            local zeroColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, zeroCurve)
            if zeroColor and IsCurveColorDifferent(color, zeroColor) then
                return true, "DELTA"
            end
        end

        local expected = _condBorderTypeProbeMatchColors[normalizedHazard]
        if IsCurveColorMatch(color, expected) then
            return true, "EQ"
        end

        local _, _, _, a = color:GetRGBA()
        if IsSecretValue(a) then
            return false, nil
        end
        local alpha = tonumber(a)
        if alpha and alpha > 0.05 then
            return true, "ALPHA"
        end
        return false, nil
    end

    for _, enum in ipairs(PRIMARY_HAZARD_PRIORITY) do
        local ok, matched, mode = pcall(MatchesCurve, enum)
        if ok then
            if matched then
                return enum, mode
            end
        else
            MarkError("AURA_ENUM_CURVE", matched)
        end
    end
    return nil, nil
end

local function CountMapEntries(map)
    local n = 0
    if type(map) ~= "table" then
        return n
    end
    for _ in pairs(map) do
        n = n + 1
    end
    return n
end

local function LogReloadDungeonSnapshot(frame, phase, source, inRestricted, inInstance, instanceType, instanceName, difficultyID, difficultyName, mapID)
    local entry = _blizzDispelCache["player"]
    local cachedDebuffs = entry and CountMapEntries(entry.debuffs) or 0
    local cachedDispel = entry and CountMapEntries(entry.dispellable) or 0
    local cachedTypes = entry and CountMapEntries(entry.types) or 0
    local frameReady = (frame and frame.conditionBorder) and "YES" or "NO"
    local sweepReady = (_secondaryDebuffBox and _secondaryDebuffBox.frame) and "YES" or "NO"
    local sweepShown = _secondaryDebuffBoxVisible and "YES" or "NO"
    local state = _condBorderActive and "ACTIVE" or "IDLE"
    local hook = _blizzHookRegistered and "YES" or "NO"
    local curve = (_condBorderCurve ~= nil) and "YES" or "NO"
    local enabled = IsEnabled() and "YES" or "NO"
    local restrictedText = inRestricted and "YES" or "NO"
    local diffID = tonumber(difficultyID) or 0
    local mapIDNum = tonumber(mapID) or 0
    local instanceNameText = SafeToString(instanceName or "unknown")
    local difficultyNameText = SafeToString(difficultyName or "unknown")

    local summary = "phase=" .. SafeToString(phase)
        .. " src=" .. SafeToString(source)
        .. " instance=" .. SafeToString(instanceType) .. ":" .. instanceNameText
        .. " diff=" .. difficultyNameText .. "(" .. tostring(diffID) .. ")"
        .. " mapID=" .. tostring(mapIDNum)
        .. " enabled=" .. enabled
        .. " inRestricted=" .. restrictedText
        .. " hook=" .. hook
        .. " curve=" .. curve
        .. " frameReady=" .. frameReady
        .. " secondarySweepReady=" .. sweepReady
        .. " secondarySweepShown=" .. sweepShown
        .. " state=" .. state
        .. " cachedDebuffs=" .. tostring(cachedDebuffs)
        .. " cachedDispel=" .. tostring(cachedDispel)
        .. " cachedTypes=" .. tostring(cachedTypes)
        .. " lastStep=" .. SafeToString(_lastCondBorderStep)
        .. " errCount=" .. tostring(_lastCondBorderErrorCount)
        .. " lastError=" .. SafeToString(_lastCondBorderError)

    _reloadDungeonDiagLastPhase = SafeToString(phase)
    _reloadDungeonDiagLastSummary = summary
    CondBorderReloadLog(summary)
end

local function MaybeRunReloadDungeonDiagnostics(frame, source, inRestricted)
    local inInstance, instanceType, instanceName, difficultyID, difficultyName, mapID = GetInstanceContext()
    if not (inInstance and IsDungeonInstanceType(instanceType)) then
        _reloadDungeonDiagActiveKey = nil
        return
    end

    local key = SafeToString(instanceType) .. "|"
        .. SafeToString(instanceName) .. "|"
        .. SafeToString(difficultyID) .. "|"
        .. SafeToString(mapID)

    if _reloadDungeonDiagActiveKey == key then
        return
    end
    _reloadDungeonDiagActiveKey = key
    _reloadDungeonDiagSession = _reloadDungeonDiagSession + 1
    local session = _reloadDungeonDiagSession

    LogReloadDungeonSnapshot(frame, "BOOT", source, inRestricted, inInstance, instanceType, instanceName, difficultyID, difficultyName, mapID)

    if not (C_Timer and C_Timer.After) then
        CondBorderReloadLog("phase=TIMER_UNAVAILABLE src=" .. SafeToString(source))
        return
    end

    local function DelayedSnapshot(phaseLabel)
        if _reloadDungeonDiagSession ~= session then
            return
        end
        local activeFrame = frame or _playerFrame or _G.MidnightUI_PlayerFrame
        local restrictedNow = GetRestrictionState()
        local nowInInstance, nowType, nowName, nowDifficultyID, nowDifficultyName, nowMapID = GetInstanceContext()
        if not (nowInInstance and IsDungeonInstanceType(nowType)) then
            return
        end
        LogReloadDungeonSnapshot(activeFrame, phaseLabel, source, restrictedNow, nowInInstance, nowType, nowName, nowDifficultyID, nowDifficultyName, nowMapID)
    end

    C_Timer.After(0.25, function()
        DelayedSnapshot("T+0.25")
    end)
    C_Timer.After(1.00, function()
        DelayedSnapshot("T+1.00")
    end)
    C_Timer.After(2.00, function()
        DelayedSnapshot("T+2.00")
    end)
end

local function CountDebuffsByScan(unit, inRestricted)
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
        return nil, false
    end

    local function Scan()
        local n = 0
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            if not ShouldIgnoreLockoutDebuffAura(aura) then
                n = n + 1
            end
        end
        return n
    end

    if inRestricted then
        local ok, n = pcall(Scan)
        if ok then
            return n or 0, true
        end
        return nil, false
    end
    return Scan(), true
end

local function NormalizeTrackerTypeCode(dt)
    local tokenType = type(dt)
    if tokenType == "number" then
        if dt == 1 then return DISPEL_ENUM.Magic end
        if dt == 2 then return DISPEL_ENUM.Curse end
        if dt == 3 then return DISPEL_ENUM.Disease end
        if dt == 4 then return DISPEL_ENUM.Poison end
        if dt == 6 then return DISPEL_ENUM.Bleed end
        if dt == 9 then return DISPEL_ENUM.Bleed end
        if dt == 11 then return DISPEL_ENUM.Bleed end
    elseif tokenType == "string" then
        local lower = string.lower(dt)
        if lower == "magic" or lower == "type_magic" then return DISPEL_ENUM.Magic end
        if lower == "curse" or lower == "type_curse" then return DISPEL_ENUM.Curse end
        if lower == "disease" or lower == "type_disease" then return DISPEL_ENUM.Disease end
        if lower == "poison" or lower == "type_poison" then return DISPEL_ENUM.Poison end
        if lower == "bleed" or lower == "enrage" or lower == "type_bleed" or lower == "type_enrage" then
            return DISPEL_ENUM.Bleed
        end
    end
    return NormalizeHazardEnum(dt)
end

local function CountActiveDebuffs(unit, inRestricted)
    local scanCount, scanOk = CountDebuffsByScan(unit, inRestricted)
    local entry = _blizzDispelCache[unit]
    local cacheCount = entry and CountMapEntries(entry.debuffs) or 0

    if scanOk then
        local n = scanCount or 0
        if cacheCount > n then
            return cacheCount
        end
        return n
    end

    return cacheCount
end

local function DescribeDispelToken(dt)
    if dt == nil then
        return "nil"
    end

    local tokenType = type(dt)
    if IsSecretValue(dt) then
        return "secret_" .. tokenType
    end

    if tokenType == "number" then
        local label = HAZARD_LABEL_BY_ENUM[dt]
        if label then
            return "num_" .. label
        end
        return "num_" .. SafeToString(dt)
    end

    if tokenType == "string" then
        local normalized = NormalizeHazardEnum(dt)
        if IsTrackedHazardEnum(normalized) then
            return "str_" .. (HAZARD_LABEL_BY_ENUM[normalized] or "KNOWN")
        end
        return "str_other"
    end

    return tokenType
end

local function BuildAuraFieldSignature(aura)
    if not aura then
        return "aura=nil"
    end
    return "dt=" .. DescribeDispelToken(aura.dispelType)
        .. ",dn=" .. DescribeDispelToken(aura.dispelName)
        .. ",db=" .. DescribeDispelToken(aura.debuffType)
        .. ",tp=" .. DescribeDispelToken(aura.type)
end

local function BuildActiveHazardSignature(activeHazards)
    if type(activeHazards) ~= "table" then
        return "none"
    end
    local labels = {}
    for _, enum in ipairs(PRIMARY_HAZARD_PRIORITY) do
        if activeHazards[enum] then
            labels[#labels + 1] = HAZARD_LABEL_BY_ENUM[enum] or SafeToString(enum)
        end
    end
    if #labels == 0 then
        return "none"
    end
    return table.concat(labels, "+")
end

local function ResolveHazardEnumFromAuraData(aura)
    if not aura then
        return nil
    end

    local dt = NormalizeHazardEnum(aura.dispelType)
    if not IsTrackedHazardEnum(dt) then
        dt = NormalizeHazardEnum(aura.dispelName)
    end
    if not IsTrackedHazardEnum(dt) then
        dt = NormalizeHazardEnum(aura.debuffType)
    end
    if not IsTrackedHazardEnum(dt) then
        dt = NormalizeHazardEnum(aura.type)
    end
    if IsTrackedHazardEnum(dt) then
        return dt
    end
    return nil
end

-- Scan all player HARMFUL auras and cache IIDs that have no tracked dispel type.
-- Must only be called outside combat (inRestricted=false) when fields are readable.
local function RefreshPrecombatNonTypedCache(unit)
    wipe(_precombatNonTypedIIDs)
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
        if not aura then break end
        local iid = aura.auraInstanceID
        if iid then
            if ShouldIgnoreLockoutDebuffAura(aura) or not IsTrackedHazardEnum(ResolveHazardEnumFromAuraData(aura)) then
                _precombatNonTypedIIDs[iid] = true
            end
        end
    end
end

local function IsKnownNonTypedIID(auraInstanceID)
    return _precombatNonTypedIIDs[auraInstanceID] == true
end

local function CollectActiveHazardTypesLegacy(unit)
    local active = {}
    if type(UnitDebuff) ~= "function" then
        return active
    end

    for i = 1, 40 do
        local auraName, _, _, debuffType = UnitDebuff(unit, i)
        if not auraName then break end
        local dt = NormalizeHazardEnum(debuffType)
        if IsTrackedHazardEnum(dt) then
            active[dt] = true
        end
    end
    return active
end

local function GetPrimaryHazardEnumFromActive(active)
    if type(active) ~= "table" then
        return nil
    end
    for _, enum in ipairs(PRIMARY_HAZARD_PRIORITY) do
        if active[enum] then
            return enum
        end
    end
    return nil
end

local function ResolveHazardEnumForAuraID(unit, auraInstanceID, inRestricted)
    if not auraInstanceID then return nil end
    if not C_UnitAuras then return nil end
    MarkStep("AURA_ENUM_RESOLVE")

    local entry = _blizzDispelCache[unit]
    if entry and entry.types then
        local cached = entry.types[auraInstanceID]
        if IsTrackedHazardEnum(cached) then
            MarkStep("AURA_ENUM_CACHE", HAZARD_LABEL_BY_ENUM[cached])
            LogAuraEnum("CACHE", auraInstanceID, cached, inRestricted)
            return cached
        end
    end

    local curveEnum, curveMode = ResolveHazardEnumByCurve(unit, auraInstanceID, inRestricted)
    if IsTrackedHazardEnum(curveEnum) then
        if entry and entry.types then
            entry.types[auraInstanceID] = curveEnum
        end
        MarkStep("AURA_ENUM_CURVE_MATCH", HAZARD_LABEL_BY_ENUM[curveEnum])
        local curveSource = "CURVE"
        if curveMode == "DELTA" then
            curveSource = "CURVE_DELTA"
        elseif curveMode == "EQ" then
            curveSource = "CURVE_EQ"
        elseif curveMode == "ALPHA" then
            curveSource = "CURVE_ALPHA"
        end
        LogAuraEnum(curveSource, auraInstanceID, curveEnum, inRestricted)
        return curveEnum
    end

    local function ResolveByAuraInstanceID()
        if not C_UnitAuras.GetAuraDataByAuraInstanceID then
            return nil, nil
        end
        local aura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, auraInstanceID)
        if not aura then
            return nil, nil
        end
        return ResolveHazardEnumFromAuraData(aura), aura
    end

    local function ScanByIndex()
        if not C_UnitAuras.GetAuraDataByIndex then
            return nil
        end
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            if aura.auraInstanceID == auraInstanceID then
                local dt = ResolveHazardEnumFromAuraData(aura)
                if IsTrackedHazardEnum(dt) then
                    MarkStep("AURA_ENUM_MATCH", HAZARD_LABEL_BY_ENUM[dt])
                    return dt
                end
                MarkStep("AURA_ENUM_UNTRACKED")
                MarkStep("AURA_ENUM_UNTRACKED_FIELDS", BuildAuraFieldSignature(aura))
                return nil
            end
        end
        MarkStep("AURA_ENUM_MISS")
        return nil
    end

    if inRestricted then
        local okID, dtID, aura = pcall(ResolveByAuraInstanceID)
        if okID then
            if IsTrackedHazardEnum(dtID) then
                if entry and entry.types then
                    entry.types[auraInstanceID] = dtID
                end
                MarkStep("AURA_ENUM_MATCH", HAZARD_LABEL_BY_ENUM[dtID])
                LogAuraEnum("AURA_DATA_COMBAT", auraInstanceID, dtID, inRestricted)
                return dtID
            end
            if aura then
                MarkStep("AURA_ENUM_UNTRACKED")
                MarkStep("AURA_ENUM_UNTRACKED_FIELDS", BuildAuraFieldSignature(aura))
            end
        else
            MarkError("AURA_ENUM_RESOLVE_COMBAT", dtID)
        end

        local okScan, dtScan = pcall(ScanByIndex)
        if okScan then
            if IsTrackedHazardEnum(dtScan) then
                if entry and entry.types then
                    entry.types[auraInstanceID] = dtScan
                end
                LogAuraEnum("INDEX_COMBAT", auraInstanceID, dtScan, inRestricted)
                return dtScan
            end
        else
            MarkError("AURA_ENUM_SCAN_COMBAT", dtScan)
        end

        MarkStep("AURA_ENUM_RESTRICTED_MISS")
        LogAuraEnum("RESTRICTED_MISS", auraInstanceID, nil, inRestricted)
        return nil
    end

    local dtID, aura = ResolveByAuraInstanceID()
    if IsTrackedHazardEnum(dtID) then
        if entry and entry.types then
            entry.types[auraInstanceID] = dtID
        end
        MarkStep("AURA_ENUM_MATCH", HAZARD_LABEL_BY_ENUM[dtID])
        LogAuraEnum("AURA_DATA", auraInstanceID, dtID, inRestricted)
        return dtID
    end
    if aura then
        MarkStep("AURA_ENUM_UNTRACKED")
        MarkStep("AURA_ENUM_UNTRACKED_FIELDS", BuildAuraFieldSignature(aura))
    end

    local resolved = ScanByIndex()
    if IsTrackedHazardEnum(resolved) then
        return resolved
    end

    local legacyActive = CollectActiveHazardTypesLegacy(unit)
    local legacyPrimary = GetPrimaryHazardEnumFromActive(legacyActive)
    if IsTrackedHazardEnum(legacyPrimary) then
        MarkStep("AURA_ENUM_LEGACY", HAZARD_LABEL_BY_ENUM[legacyPrimary])
        LogAuraEnum("LEGACY", auraInstanceID, legacyPrimary, inRestricted)
        return legacyPrimary
    end

    LogAuraEnum("MISS", auraInstanceID, nil, inRestricted)
    return nil
end

local function SetPrimaryFillRGB(condBorder, r, g, b, a)
    condBorder.bgFill:SetVertexColor(r, g, b, a or 1)
    condBorder.primaryR = r
    condBorder.primaryG = g
    condBorder.primaryB = b
end

local function SetPrimaryFillFromSecretColor(condBorder, borderColor)
    local r, g, b, a = borderColor:GetRGBA()
    SetPrimaryFillRGB(condBorder, r, g, b, a)
end

local function SetBracketColorsRGB(condBorder, r, g, b)
    for _, bracket in ipairs(condBorder.brackets) do
        bracket:SetVertexColor(r, g, b)
    end
end

local function SetPrimaryShimmerRGB(condBorder, r, g, b)
    -- Shimmer sweep removed during overlap-debug simplification.
    return
end

local function SetMainPulseState(condBorder, isVisible, detail)
    if not condBorder then return end
    local pulse = condBorder.fillPulse

    if isVisible then
        if pulse and not pulse:IsPlaying() then
            pulse:Play()
        end
        MarkStep("OVERLAY_PULSE_ON", detail or "ACTIVE")
    else
        if pulse and pulse:IsPlaying() then
            pulse:Stop()
        end
        if condBorder.bgFill then
            condBorder.bgFill:SetAlpha(0.12)
        end
        MarkStep("OVERLAY_PULSE_OFF", detail or "INACTIVE")
    end
end

local function ResolveSecondarySweepOwner(anchorOwner)
    local owner = anchorOwner
    if owner and owner.bgFill and owner.GetParent then
        owner = owner:GetParent()
    end
    if not owner then
        owner = _playerFrame or _G.MidnightUI_PlayerFrame
    end
    if not owner then
        owner = UIParent
    end
    return owner
end

local function LayoutSecondarySweep(box)
    if not box or not box.frame or not box.owner then
        return
    end

    local owner = box.owner
    local width = tonumber(owner:GetWidth()) or 0
    local height = tonumber(owner:GetHeight()) or 0
    if width <= 1 then width = 260 end
    if height <= 1 then height = 72 end

    local beamW = math.max(math.floor(width * 0.32 + 0.5), 56)
    local beamH = math.max(math.floor(height * 2.55 + 0.5), 110)
    local moveDistance = width + (beamW * 2.95)
    local duration = 1.12 -- target cadence: ~1 pass/sec, slightly slower than prior sweep

    local layoutKey = tostring(math.floor(width + 0.5))
        .. "x" .. tostring(math.floor(height + 0.5))
        .. ":" .. tostring(beamW)
        .. ":" .. tostring(beamH)
    if box.layoutKey == layoutKey then
        return
    end
    box.layoutKey = layoutKey

    local fx = box.fx
    fx:ClearAllPoints()
    fx:SetSize(beamW, beamH)
    fx:SetPoint("CENTER", box.frame, "LEFT", -beamW, 0)
    if box.bandPairs then
        local bandWidths = {
            math.max(math.floor(beamW * 1.18 + 0.5), 30),
            beamW,
            math.max(math.floor(beamW * 0.84 + 0.5), 26),
            math.max(math.floor(beamW * 0.68 + 0.5), 20),
            math.max(math.floor(beamW * 0.54 + 0.5), 16),
            math.max(math.floor(beamW * 0.40 + 0.5), 12),
            math.max(math.floor(beamW * 0.28 + 0.5), 8),
        }
        for i, pair in ipairs(box.bandPairs) do
            local w = bandWidths[i] or beamW
            if pair and pair.a then
                pair.a:ClearAllPoints()
                pair.a:SetPoint("TOP", fx, "TOP", 0, 0)
                pair.a:SetPoint("BOTTOM", fx, "BOTTOM", 0, 0)
                pair.a:SetWidth(w)
            end
            if pair and pair.b then
                pair.b:ClearAllPoints()
                pair.b:SetPoint("TOP", fx, "TOP", 0, 0)
                pair.b:SetPoint("BOTTOM", fx, "BOTTOM", 0, 0)
                pair.b:SetWidth(w)
            end
        end
    end

    if box.moveAnim then
        box.moveAnim:SetOffset(moveDistance, 0)
        box.moveAnim:SetDuration(duration)
        box.moveAnim:SetSmoothing("IN_OUT")
    end

    if box.moveGroup and box.moveGroup:IsPlaying() then
        box.moveGroup:Stop()
        box.moveGroup:Play()
    end

    CondBorderLog("secondarySweep=LAYOUT owner=" .. SafeToString(owner:GetName())
        .. " size=" .. tostring(math.floor(width + 0.5)) .. "x" .. tostring(math.floor(height + 0.5))
        .. " beam=" .. tostring(beamW) .. "x" .. tostring(beamH)
        .. " passSec=" .. string.format("%.2f", duration))
end

EnsureSecondaryDebuffBox = function(anchorOwner)
    local owner = ResolveSecondarySweepOwner(anchorOwner)
    if _secondaryDebuffBox and _secondaryDebuffBox.frame then
        if _secondaryDebuffBox.owner ~= owner then
            _secondaryDebuffBox.owner = owner
            _secondaryDebuffBox.frame:SetParent(owner)
            _secondaryDebuffBox.frame:ClearAllPoints()
            _secondaryDebuffBox.frame:SetAllPoints(owner)
            _secondaryDebuffBox.frame:SetFrameStrata(owner:GetFrameStrata() or "MEDIUM")
            _secondaryDebuffBox.frame:SetFrameLevel((owner:GetFrameLevel() or 1) + 38)
            _secondaryDebuffBox.layoutKey = nil
            CondBorderLog("secondarySweep=REPARENT owner=" .. SafeToString(owner:GetName()))
        end
        LayoutSecondarySweep(_secondaryDebuffBox)
        return _secondaryDebuffBox
    end

    local frame = CreateFrame("Frame", nil, owner)
    frame:SetAllPoints(owner)
    frame:SetFrameStrata(owner:GetFrameStrata() or "MEDIUM")
    frame:SetFrameLevel((owner:GetFrameLevel() or 1) + 38)
    frame:EnableMouse(false)
    frame:SetClipsChildren(true)
    frame:SetAlpha(1)
    frame:Hide()

    local fx = CreateFrame("Frame", nil, frame)
    fx:SetSize(72, 128)
    fx:SetPoint("CENTER", frame, "LEFT", -72, 0)

    local function CreateSweepBand(isReverse)
        local tex = fx:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("TOP", fx, "TOP", 0, 0)
        tex:SetPoint("BOTTOM", fx, "BOTTOM", 0, 0)
        tex:SetWidth(24)
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

    local bandPairs = {}
    for i = 0, 6 do
        bandPairs[#bandPairs + 1] = {
            a = CreateSweepBand(false),
            b = CreateSweepBand(true),
        }
    end

    local moveGroup = fx:CreateAnimationGroup()
    moveGroup:SetLooping("REPEAT")
    local move = moveGroup:CreateAnimation("Translation")
    move:SetOffset(420, 0)
    move:SetDuration(1.12)
    move:SetSmoothing("IN_OUT")

    _secondaryDebuffBox = {
        frame = frame,
        fx = fx,
        bandPairs = bandPairs,
        owner = owner,
        layoutKey = nil,
        moveGroup = moveGroup,
        moveAnim = move,
    }
    _secondaryDebuffBoxVisible = false
    _secondaryDebuffBoxEnum = nil
    _secondaryDebuffBoxRGB = nil
    _secondaryDebuffBoxLastDecisionKey = nil
    _lastCondBorderTypeBoxState = "OFF"
    _lastCondBorderTypeBoxEnum = nil
    _lastCondBorderTypeBoxRGB = nil
    _lastCondBorderTypeBoxR = nil
    _lastCondBorderTypeBoxG = nil
    _lastCondBorderTypeBoxB = nil

    LayoutSecondarySweep(_secondaryDebuffBox)
    CondBorderLog("secondarySweep=CREATE owner=" .. SafeToString(owner:GetName()) .. " layer=OVERLAY subLevel=AUTO")
    return _secondaryDebuffBox
end

local function HideSecondaryTypeBox(condBorder, reason)
    local box = _secondaryDebuffBox
    local wasVisible = _secondaryDebuffBoxVisible == true

    if box and box.moveGroup and box.moveGroup:IsPlaying() then
        box.moveGroup:Stop()
    end
    if box and box.frame then
        box.frame:Hide()
    end

    _secondaryDebuffBoxVisible = false
    _secondaryDebuffBoxEnum = nil
    _secondaryDebuffBoxRGB = nil
    _secondaryDebuffBoxLastDecisionKey = nil
    _lastCondBorderTypeBoxState = "OFF"
    _lastCondBorderTypeBoxEnum = nil
    _lastCondBorderTypeBoxRGB = nil
    _lastCondBorderTypeBoxR = nil
    _lastCondBorderTypeBoxG = nil
    _lastCondBorderTypeBoxB = nil
    if wasVisible then
        CondBorderLog("secondarySweep=OFF reason=" .. SafeToString(reason or "STATE_CLEAR"))
    end
end

local function ShowSecondaryTypeBoxWithRGB(condBorder, token, r, g, b, labelText)
    local box = EnsureSecondaryDebuffBox(condBorder)
    if not box then
        return
    end

    LayoutSecondarySweep(box)
    local wasVisible = _secondaryDebuffBoxVisible == true
    local currentToken = _secondaryDebuffBoxEnum
    local nextRGB = FormatRGBForLog(r, g, b)
    local needsRefresh = (currentToken ~= token) or (_secondaryDebuffBoxRGB ~= nextRGB)
    local sweepLabel = SafeToString(labelText or token)

    if needsRefresh then
        local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
        if token == UNKNOWN_SECONDARY_TOKEN then
            bandAlpha = { 0.014, 0.022, 0.032, 0.045, 0.062, 0.084, 0.112 }
        end
        if token == SECRET_SECONDARY_TOKEN then
            bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
        end
        if box.bandPairs then
            for i, pair in ipairs(box.bandPairs) do
                local a = bandAlpha[i] or bandAlpha[#bandAlpha]
                if pair and pair.a then
                    pair.a:SetVertexColor(r, g, b, a)
                end
                if pair and pair.b then
                    pair.b:SetVertexColor(r, g, b, a)
                end
            end
        end
        _secondaryDebuffBoxEnum = token
        _secondaryDebuffBoxRGB = nextRGB
    end

    if box.frame and not box.frame:IsShown() then
        box.frame:Show()
    end
    if box.moveGroup and not box.moveGroup:IsPlaying() then
        box.moveGroup:Play()
    end

    _lastCondBorderTypeBoxState = "ON"
    _lastCondBorderTypeBoxEnum = token
    _lastCondBorderTypeBoxRGB = _secondaryDebuffBoxRGB
    _lastCondBorderTypeBoxR = r
    _lastCondBorderTypeBoxG = g
    _lastCondBorderTypeBoxB = b
    if (not wasVisible) or needsRefresh then
        CondBorderLog("secondarySweep=ON type=" .. SafeToString(token)
            .. " label=" .. sweepLabel
            .. " rgb=" .. _secondaryDebuffBoxRGB)
    end
    _secondaryDebuffBoxVisible = true
end

local function ShowSecondaryTypeBoxFromSecretColor(condBorder, borderColor)
    if not borderColor or not borderColor.GetRGBA then
        HideSecondaryTypeBox(condBorder, "NO_SECONDARY_SECRET_COLOR")
        return
    end

    local ok, r, g, b = pcall(function()
        local rr, gg, bb = borderColor:GetRGB()
        return rr, gg, bb
    end)
    if not ok then
        local okRGBA, rr, gg, bb = pcall(function()
            local r1, g1, b1 = borderColor:GetRGBA()
            return r1, g1, b1
        end)
        if not okRGBA then
            HideSecondaryTypeBox(condBorder, "SECONDARY_SECRET_RGB_FAIL")
            return
        end
        r, g, b = rr, gg, bb
    end

    ShowSecondaryTypeBoxWithRGB(condBorder, SECRET_SECONDARY_TOKEN, r, g, b, SECRET_SECONDARY_TOKEN)
end

local function ShowSecondaryTypeBox(condBorder, secondaryEnum)
    local isUnknown = (secondaryEnum == UNKNOWN_SECONDARY_TOKEN)
    if (not isUnknown) and (not IsTrackedHazardEnum(secondaryEnum)) then
        HideSecondaryTypeBox(condBorder, "UNTRACKED")
        return
    end

    local r, g, b = 1, 1, 1
    if not isUnknown then
        r, g, b = GetHazardRGB(secondaryEnum)
    end
    local token = isUnknown and UNKNOWN_SECONDARY_TOKEN or SafeToString(HAZARD_LABEL_BY_ENUM[secondaryEnum] or secondaryEnum)
    local label = isUnknown and UNKNOWN_SECONDARY_TOKEN or (HAZARD_LABEL_BY_ENUM[secondaryEnum] or UNKNOWN_SECONDARY_TOKEN)
    ShowSecondaryTypeBoxWithRGB(condBorder, token, r, g, b, label)
end

local function ShouldForceTypeBoxDebug()
    local s = MidnightUISettings
    return s and s.PlayerFrame and s.PlayerFrame.condBorderDebug == true
end

local function LogTypeBoxDecision(condBorder, reason, primaryEnum, secondaryEnum, hasOverlap, activeSignature, context)
    if not ShouldForceTypeBoxDebug() then
        return
    end
    if not condBorder then
        return
    end
    local primaryLabel = (primaryEnum == nil) and "NONE" or (HAZARD_LABEL_BY_ENUM[primaryEnum] or SafeToString(primaryEnum))
    local secondaryLabel = (secondaryEnum == nil) and "NONE" or (HAZARD_LABEL_BY_ENUM[secondaryEnum] or SafeToString(secondaryEnum))
    local shown = "NO"
    local visible = "NO"
    local playing = "NO"
    local centerText = "nil"
    local typeBox = _secondaryDebuffBox and _secondaryDebuffBox.frame
    local moveGroup = _secondaryDebuffBox and _secondaryDebuffBox.moveGroup
    if typeBox and typeBox.IsShown and typeBox:IsShown() then
        shown = "YES"
    end
    if moveGroup and moveGroup.IsPlaying and moveGroup:IsPlaying() then
        playing = "YES"
    end
    if _secondaryDebuffBoxVisible == true then
        visible = "YES"
    end
    if typeBox and typeBox.GetCenter then
        local cx, cy = typeBox:GetCenter()
        local xn, yn = tonumber(cx), tonumber(cy)
        if xn and yn then
            centerText = string.format("%.1f,%.1f", xn, yn)
        end
    end
    local key = SafeToString(reason)
        .. "|" .. primaryLabel
        .. "|" .. secondaryLabel
        .. "|" .. (hasOverlap and "1" or "0")
        .. "|" .. SafeToString(activeSignature)
        .. "|" .. shown
        .. "|" .. visible
        .. "|" .. playing
        .. "|" .. centerText
    if _secondaryDebuffBoxLastDecisionKey == key then
        return
    end
    _secondaryDebuffBoxLastDecisionKey = key
    if IsCondBorderVerboseEnabled() then
        CondBorderLog("secondaryBoxDecision reason=" .. SafeToString(reason)
            .. " primary=" .. primaryLabel
            .. " secondary=" .. secondaryLabel
            .. " overlap=" .. (hasOverlap and "YES" or "NO")
            .. " active=" .. SafeToString(activeSignature)
            .. " shown=" .. shown
            .. " visibleFlag=" .. visible
            .. " playing=" .. playing
            .. " center=" .. centerText)
    end

    local trackedCount = context and context.trackedCount or "nil"
    local totalDebuffs = context and context.totalDebuffs or "nil"
    local secondaryIID = context and context.secondaryIID or nil
    local typedSecondary = context and context.typedSecondary == true
    local secretSecondary = context and context.secretSecondary == true
    local unknownSecondary = context and context.unknownSecondary == true
    local inRestricted = context and context.inRestricted == true
    local pulseMode = SafeToString(_lastCondBorderExtraType or "PULSE_ONLY")
    local typeBoxState = SafeToString(_lastCondBorderTypeBoxState)
    local typeBoxEnum = SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderTypeBoxEnum] or _lastCondBorderTypeBoxEnum or "NONE")
    local typeBoxRGB = SafeToString(_lastCondBorderTypeBoxRGB or "none")
    local sweepKey = key
        .. "|" .. SafeToString(trackedCount)
        .. "|" .. SafeToString(totalDebuffs)
        .. "|" .. SafeToString(secondaryIID)
        .. "|" .. (typedSecondary and "1" or "0")
        .. "|" .. (secretSecondary and "1" or "0")
        .. "|" .. (unknownSecondary and "1" or "0")
        .. "|" .. (inRestricted and "1" or "0")
        .. "|" .. pulseMode
        .. "|" .. typeBoxState
        .. "|" .. typeBoxEnum
        .. "|" .. typeBoxRGB
    if _lastCondBorderSweepTraceKey ~= sweepKey then
        _lastCondBorderSweepTraceKey = sweepKey
        CondBorderSweepLog("sweepTrace reason=" .. SafeToString(reason)
            .. " primary=" .. primaryLabel
            .. " secondary=" .. secondaryLabel
            .. " overlap=" .. (hasOverlap and "YES" or "NO")
            .. " typed=" .. (typedSecondary and "YES" or "NO")
            .. " secret=" .. (secretSecondary and "YES" or "NO")
            .. " unknown=" .. (unknownSecondary and "YES" or "NO")
            .. " tracked=" .. SafeToString(trackedCount)
            .. " totalDebuffs=" .. SafeToString(totalDebuffs)
            .. " restricted=" .. (inRestricted and "YES" or "NO")
            .. " secondaryIID=" .. SafeToString(secondaryIID)
            .. " active=" .. SafeToString(activeSignature)
            .. " boxShown=" .. shown
            .. " boxVisible=" .. visible
            .. " boxPlaying=" .. playing
            .. " boxState=" .. typeBoxState
            .. " boxEnum=" .. typeBoxEnum
            .. " boxRGB=" .. typeBoxRGB
            .. " pulse=" .. pulseMode)
    end
end

local function SetExtraShimmerState(condBorder, isVisible, r, g, b)
    if not isVisible then
        HideSecondaryTypeBox(condBorder, "PULSE_OFF")
    end
    SetMainPulseState(condBorder, isVisible, isVisible and "PULSE_ONLY" or "OFF")
end

local function BuildAuraInstanceIDCandidateSet(unit, inRestricted)
    local ids = {}
    local function AddID(iid)
        if iid == nil then
            return
        end
        ids[iid] = true
    end

    local entry = _blizzDispelCache[unit]
    if entry then
        if entry.debuffs then
            for iid in pairs(entry.debuffs) do
                AddID(iid)
            end
        end
        if entry.dispellable then
            for iid in pairs(entry.dispellable) do
                AddID(iid)
            end
        end
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local function ScanByIndex()
            for i = 1, 40 do
                local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
                if not aura then
                    break
                end
                AddID(aura.auraInstanceID)
            end
        end
        if inRestricted then
            local ok, err = pcall(ScanByIndex)
            if not ok then
                MarkError("AURA_ID_SET_INDEX", err)
            end
        else
            ScanByIndex()
        end
    end

    return ids
end

local function BuildOrderedAuraInstanceIDs(unit, inRestricted)
    local ordered = {}
    local seen = {}

    local function AddID(iid)
        if iid == nil then
            return
        end
        if seen[iid] then
            return
        end
        seen[iid] = true
        ordered[#ordered + 1] = iid
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local function ScanByIndex()
            for i = 1, 40 do
                local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
                if not aura then
                    break
                end
                AddID(aura.auraInstanceID)
            end
        end
        if inRestricted then
            local ok, err = pcall(ScanByIndex)
            if not ok then
                MarkError("AURA_ORDER_INDEX", err)
            end
        else
            ScanByIndex()
        end
    end

    local entry = _blizzDispelCache[unit]
    if entry then
        if entry.debuffs then
            for iid in pairs(entry.debuffs) do
                AddID(iid)
            end
        end
        if entry.dispellable then
            for iid in pairs(entry.dispellable) do
                AddID(iid)
            end
        end
    end

    return ordered
end

local function LogSecondaryCandidate(primaryIID, primaryEnum, secondaryIID, secondaryEnum, source, slotIndex)
    if not ShouldForceTypeBoxDebug() or not IsCondBorderVerboseEnabled() then
        return
    end
    local primaryLabel = (primaryEnum == nil) and "NONE" or (HAZARD_LABEL_BY_ENUM[primaryEnum] or SafeToString(primaryEnum))
    local secondaryLabel = (secondaryEnum == nil) and "NONE" or (HAZARD_LABEL_BY_ENUM[secondaryEnum] or SafeToString(secondaryEnum))
    local key = SafeToString(primaryIID)
        .. "|" .. primaryLabel
        .. "|" .. SafeToString(secondaryIID)
        .. "|" .. secondaryLabel
        .. "|" .. SafeToString(source)
        .. "|" .. SafeToString(slotIndex)
    if _lastCondBorderSecondaryCandidateLogKey == key then
        return
    end
    _lastCondBorderSecondaryCandidateLogKey = key
    CondBorderLog("secondaryCandidate src=" .. SafeToString(source)
        .. " primaryIID=" .. SafeToString(primaryIID)
        .. " primary=" .. primaryLabel
        .. " secondaryIID=" .. SafeToString(secondaryIID)
        .. " secondary=" .. secondaryLabel
        .. " slot=" .. SafeToString(slotIndex))
end

local function ResolveSecondaryAuraCandidate(unit, inRestricted, primaryIID, primaryEnum)
    local ids = BuildOrderedAuraInstanceIDs(unit, inRestricted)
    if #ids == 0 then
        LogSecondaryCandidate(primaryIID, primaryEnum, nil, nil, "NONE", nil)
        return nil, nil, nil, "NONE", nil
    end

    local startIndex = 1
    if primaryIID == nil and IsTrackedHazardEnum(primaryEnum) then
        -- If we know the primary type but not its auraInstanceID, treat index 1 as primary bias.
        startIndex = 2
    end

    local curve = GetCondBorderCurve()
    local secretFallbackIID, secretFallbackColor, secretFallbackSlot = nil, nil, nil
    for slotIndex = startIndex, #ids do
        local iid = ids[slotIndex]
        if iid and iid ~= primaryIID then
            local enum = ResolveHazardEnumForAuraID(unit, iid, inRestricted)
            if IsTrackedHazardEnum(enum) and enum ~= primaryEnum then
                LogSecondaryCandidate(primaryIID, primaryEnum, iid, enum, "ENUM", slotIndex)
                return iid, enum, nil, "ENUM", slotIndex
            end

            if (not secretFallbackColor) and curve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
                local okColor, borderColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, iid, curve)
                if okColor and borderColor then
                    secretFallbackIID = iid
                    secretFallbackColor = borderColor
                    secretFallbackSlot = slotIndex
                elseif not okColor then
                    MarkError("SECONDARY_COLOR_QUERY", borderColor)
                end
            end
        end
    end

    if secretFallbackColor then
        LogSecondaryCandidate(primaryIID, primaryEnum, secretFallbackIID, nil, "SECRET_COLOR", secretFallbackSlot)
        return secretFallbackIID, nil, secretFallbackColor, "SECRET_COLOR", secretFallbackSlot
    end

    LogSecondaryCandidate(primaryIID, primaryEnum, nil, nil, "NONE", nil)
    return nil, nil, nil, "NONE", nil
end

local function IsBleedAuraIDByCurve(unit, auraInstanceID, inRestricted)
    if not unit or not auraInstanceID then
        return false
    end
    if not C_UnitAuras or not C_UnitAuras.GetAuraDispelTypeColor then
        return false
    end

    local curve = GetCondBorderBleedOnlyCurve()
    if not curve then
        return false
    end

    local function Query()
        local color = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, curve)
        if not color or not color.GetRGBA then
            return false
        end
        local zeroCurve = GetCondBorderZeroProbeCurve()
        if zeroCurve then
            local zeroColor = C_UnitAuras.GetAuraDispelTypeColor(unit, auraInstanceID, zeroCurve)
            if zeroColor and IsCurveColorDifferent(color, zeroColor) then
                return true
            end
        end
        if IsCurveColorMatch(color, _condBorderBleedOnlyMatchColor) then
            return true
        end
        local _, _, _, a = color:GetRGBA()
        if IsSecretValue(a) then
            return false
        end
        local alpha = tonumber(a)
        return alpha and alpha > 0.05
    end

    local ok, isBleed = pcall(Query)
    if not ok then
        MarkError("BLEED_CURVE_QUERY", isBleed)
        return false
    end
    return isBleed == true
end

local function ScanForBleedAuraIDByCurve(unit, inRestricted)
    local ids = BuildAuraInstanceIDCandidateSet(unit, inRestricted)
    _lastCondBorderBleedCurveCandidates = CountMapEntries(ids)
    for iid in pairs(ids) do
        if IsBleedAuraIDByCurve(unit, iid, inRestricted) then
            _lastCondBorderBleedCurveIID = iid
            return iid, DISPEL_ENUM.Bleed
        end
    end
    _lastCondBorderBleedCurveIID = nil
    return nil
end

local function CollectActiveHazardTypes(unit, inRestricted)
    local active = {}
    MarkStep("COLLECT_ACTIVE_BEGIN")
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
        if TrackerSaysBleedActive() then
            active[DISPEL_ENUM.Bleed] = true
            MarkStep("COLLECT_ACTIVE_BLEED_TRACKER", _lastCondBorderTrackerBleedMethod or "unknown")
        end
        MarkStep("COLLECT_ACTIVE_NO_API")
        return active
    end

    local function AddHazard(dt)
        if IsTrackedHazardEnum(dt) then
            active[dt] = true
            return true
        end
        return false
    end

    local function ScanHookCache()
        local entry = _blizzDispelCache[unit]
        if not entry or not entry.debuffs then
            return
        end
        for iid in pairs(entry.debuffs) do
            local dt = nil
            if entry.types then
                dt = entry.types[iid]
            end
            if not IsTrackedHazardEnum(dt) then
                dt = ResolveHazardEnumForAuraID(unit, iid, inRestricted)
            end
            AddHazard(dt)
        end
    end

    local function ScanByIndex()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            AddHazard(ResolveHazardEnumFromAuraData(aura))
        end
    end

    local function RunScan(label, fn)
        if inRestricted then
            local ok, err = pcall(fn)
            if not ok then
                MarkError(label, err)
            end
            return
        end
        fn()
    end

    RunScan("COLLECT_ACTIVE_HOOK", ScanHookCache)
    RunScan("COLLECT_ACTIVE_INDEX", ScanByIndex)

    if not inRestricted then
        local legacy = CollectActiveHazardTypesLegacy(unit)
        if next(legacy) then
            for dt in pairs(legacy) do
                active[dt] = true
            end
            MarkStep("COLLECT_ACTIVE_LEGACY", BuildActiveHazardSignature(legacy))
        end
    end

    if TrackerHasTypeActive then
        local trackerMap = {
            { DISPEL_ENUM.Magic,   { 1, "MAGIC", "type_magic" }, "MAGIC" },
            { DISPEL_ENUM.Curse,   { 2, "CURSE", "type_curse" }, "CURSE" },
            { DISPEL_ENUM.Disease, { 3, "DISEASE", "type_disease" }, "DISEASE" },
            { DISPEL_ENUM.Poison,  { 4, "POISON", "type_poison" }, "POISON" },
            { DISPEL_ENUM.Bleed,   { 6, 9, 11, "BLEED", "ENRAGE", "type_bleed", "type_enrage" }, "BLEED" },
        }
        for _, item in ipairs(trackerMap) do
            local enum, codes, label = item[1], item[2], item[3]
            local matched = false
            for _, code in ipairs(codes) do
                if TrackerHasTypeActive(unit, code) then
                    matched = true
                    break
                end
            end
            if matched then
                if not active[enum] then
                    MarkStep("COLLECT_ACTIVE_TRACKER_MATCH", label)
                end
                active[enum] = true
            end
        end
    end

    if not active[DISPEL_ENUM.Bleed] then
        local okCurve, bleedIID = pcall(ScanForBleedAuraIDByCurve, unit, inRestricted)
        if okCurve and bleedIID then
            active[DISPEL_ENUM.Bleed] = true
            MarkStep(inRestricted and "COLLECT_ACTIVE_BLEED_CURVE_COMBAT" or "COLLECT_ACTIVE_BLEED_CURVE", SafeToString(bleedIID))
        elseif not okCurve then
            MarkError("COLLECT_ACTIVE_BLEED_CURVE", bleedIID)
        end
    end

    if not active[DISPEL_ENUM.Bleed] and ScanForBleedAuraID then
        if inRestricted then
            local ok, bleedIID = pcall(ScanForBleedAuraID, unit, true)
            if ok and bleedIID then
                active[DISPEL_ENUM.Bleed] = true
                MarkStep("COLLECT_ACTIVE_BLEED_SCAN_COMBAT")
            elseif not ok then
                MarkError("COLLECT_ACTIVE_BLEED_SCAN_COMBAT", bleedIID)
            end
        else
            local bleedIID = ScanForBleedAuraID(unit, false)
            if bleedIID then
                active[DISPEL_ENUM.Bleed] = true
                MarkStep("COLLECT_ACTIVE_BLEED_SCAN")
            end
        end
    end

    if not active[DISPEL_ENUM.Bleed] and TrackerSaysBleedActive() then
        active[DISPEL_ENUM.Bleed] = true
        MarkStep("COLLECT_ACTIVE_BLEED_TRACKER", _lastCondBorderTrackerBleedMethod or "unknown")
    end
    if active[DISPEL_ENUM.Bleed] then
        MarkStep("COLLECT_ACTIVE_BLEED_PRESENT")
    end
    local activeSig = BuildActiveHazardSignature(active)
    MarkStep("COLLECT_ACTIVE_DONE", activeSig)
    if ShouldForceTypeBoxDebug() and IsCondBorderVerboseEnabled() then
        local debugKey = (inRestricted and "1" or "0")
            .. "|" .. activeSig
            .. "|" .. SafeToString(_lastCondBorderBleedCurveIID)
            .. "|" .. SafeToString(_lastCondBorderBleedCurveCandidates)
        if _lastCondBorderActiveCollectLogKey ~= debugKey then
            _lastCondBorderActiveCollectLogKey = debugKey
            CondBorderLog("activeHazards sig=" .. activeSig
                .. " restricted=" .. (inRestricted and "YES" or "NO")
                .. " bleedCurveIID=" .. SafeToString(_lastCondBorderBleedCurveIID)
                .. " bleedCurveIDs=" .. SafeToString(_lastCondBorderBleedCurveCandidates))
        end
    end
    return active
end

local function PickSecondaryHazards(activeHazards, primaryEnum)
    local secondaryEnum, tertiaryEnum
    for _, enum in ipairs(SECONDARY_HAZARD_PRIORITY) do
        if activeHazards[enum] and enum ~= primaryEnum then
            if not secondaryEnum then
                secondaryEnum = enum
            elseif not tertiaryEnum then
                tertiaryEnum = enum
                break
            end
        end
    end
    return secondaryEnum, tertiaryEnum
end

local function ApplySecondaryShimmerState(condBorder, primaryEnum, inRestricted, primaryIID)
    if not condBorder then return end

    -- Consume the new-IID flag set by ActivateHazardSecret. When true this is the
    -- very first shimmer pass for a brand-new secret IID; the raw GetRGBA() values
    -- stored in primaryR/G/B on that tick can cause a brightness flash if pushed to
    -- the bar immediately. Clear it now so subsequent ticks are unaffected.
    local isFirstNewIIDTick = condBorder._muiSecretOverlayNewIID == true
    condBorder._muiSecretOverlayNewIID = false

    local primaryR = condBorder.primaryR or 1
    local primaryG = condBorder.primaryG or 1
    local primaryB = condBorder.primaryB or 1
    local normalizedPrimary = NormalizeHazardEnum(primaryEnum)
    local activeHazards = CollectActiveHazardTypes("player", inRestricted)
    local activeSignature = BuildActiveHazardSignature(activeHazards)
    local primaryLabel = HAZARD_LABEL_BY_ENUM[normalizedPrimary]

    local stickyPrimary = condBorder._muiStickyPrimaryEnum
    if IsTrackedHazardEnum(stickyPrimary) and activeHazards[stickyPrimary] then
        normalizedPrimary = stickyPrimary
    end

    if not normalizedPrimary and IsTrackedHazardEnum(_lastCondBorderPrimaryEnum) then
        if activeHazards[_lastCondBorderPrimaryEnum] then
            normalizedPrimary = _lastCondBorderPrimaryEnum
        end
    end

    if not normalizedPrimary then
        for _, enum in ipairs(PRIMARY_HAZARD_PRIORITY) do
            if activeHazards[enum] then
                normalizedPrimary = enum
                break
            end
        end
    end

    if not normalizedPrimary then
        local trackedCount = CountMapEntries(activeHazards)
        local totalDebuffs = CountActiveDebuffs("player", inRestricted)
        local hasUnknownSecondary = (totalDebuffs >= 2) and (trackedCount < totalDebuffs)
        local hasOverlap = (trackedCount >= 2) or hasUnknownSecondary
        local secondaryIID, secondaryEnum, secondaryColor = ResolveSecondaryAuraCandidate("player", inRestricted, primaryIID, normalizedPrimary)
        local hasTypedSecondary = IsTrackedHazardEnum(secondaryEnum)
        local hasSecretSecondary = (secondaryColor ~= nil) and (not hasTypedSecondary)
        local hasEffectiveOverlap = hasOverlap or hasTypedSecondary or hasSecretSecondary
        local overlapSecondaryToken = nil
        if hasTypedSecondary then
            overlapSecondaryToken = secondaryEnum
        elseif hasSecretSecondary then
            overlapSecondaryToken = SECRET_SECONDARY_TOKEN
        elseif hasUnknownSecondary then
            overlapSecondaryToken = UNKNOWN_SECONDARY_TOKEN
        end
        _lastCondBorderOverlapSignature = activeSignature
        _lastCondBorderOverlapPrimaryEnum = nil
        _lastCondBorderOverlapSecondaryEnum = overlapSecondaryToken
        SetBracketColorsRGB(condBorder, primaryR, primaryG, primaryB)
        SetPrimaryShimmerRGB(condBorder, NEUTRAL_SHIMMER_COLOR[1], NEUTRAL_SHIMMER_COLOR[2], NEUTRAL_SHIMMER_COLOR[3])
        SetMainPulseState(condBorder, true, hasEffectiveOverlap and "GENERIC_OVERLAP" or "PRIMARY")
        if hasTypedSecondary then
            ShowSecondaryTypeBox(condBorder, secondaryEnum)
        elseif hasSecretSecondary then
            ShowSecondaryTypeBoxFromSecretColor(condBorder, secondaryColor)
        elseif hasUnknownSecondary then
            ShowSecondaryTypeBox(condBorder, UNKNOWN_SECONDARY_TOKEN)
        else
            HideSecondaryTypeBox(condBorder, "NO_PRIMARY")
        end
        condBorder._muiStickyPrimaryEnum = nil
        local overlapSecondaryLabel = HAZARD_LABEL_BY_ENUM[secondaryEnum]
            or (hasSecretSecondary and SECRET_SECONDARY_TOKEN)
            or (hasUnknownSecondary and UNKNOWN_SECONDARY_TOKEN)
            or "NONE"
        local overlapKey = "NONE|" .. overlapSecondaryLabel .. "|" .. (hasEffectiveOverlap and "1" or "0")
            .. "|" .. activeSignature
        if condBorder._muiLastOverlapLogKey ~= overlapKey then
            condBorder._muiLastOverlapLogKey = overlapKey
            CondBorderLog("overlap primary=NONE secondary=" .. overlapSecondaryLabel
                .. " hasOverlap=" .. (hasEffectiveOverlap and "YES" or "NO")
                .. " active=" .. activeSignature
                .. " secondaryIID=" .. SafeToString(secondaryIID))
        end
        local reason = "NO_PRIMARY"
        if hasTypedSecondary then
            reason = "NO_PRIMARY_TYPED"
        elseif hasSecretSecondary then
            reason = "NO_PRIMARY_SECRET"
        elseif hasUnknownSecondary then
            reason = "NO_PRIMARY_UNKNOWN"
        end
        LogTypeBoxDecision(condBorder, reason, nil, overlapSecondaryToken, hasEffectiveOverlap, activeSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = hasTypedSecondary,
            secretSecondary = hasSecretSecondary,
            unknownSecondary = hasUnknownSecondary,
            inRestricted = inRestricted == true,
        })
        -- No resolved type, but overlay already has a concrete payload.
        -- Keep bars synced from that payload using a strong source.
        -- Skip on the very first tick of a new secret IID: the raw GetRGBA() values
        -- haven't settled yet and pushing them immediately causes a brightness flash.
        -- isFirstNewIIDTick is cleared on every subsequent tick so normal tinting resumes.
        if primaryR ~= nil and primaryG ~= nil and primaryB ~= nil and not isFirstNewIIDTick then
            SyncPlayerFrameBarTint(true, primaryR, primaryG, primaryB, "RGB_OVERLAY")
        end
        _lastCondBorderAccentType = hasTypedSecondary and (HAZARD_LABEL_BY_ENUM[secondaryEnum] or "GENERIC")
            or (hasSecretSecondary and SECRET_SECONDARY_TOKEN)
            or (hasUnknownSecondary and UNKNOWN_SECONDARY_TOKEN)
            or (hasEffectiveOverlap and "GENERIC" or "NEUTRAL")
        _lastCondBorderExtraType = "PULSE_ONLY"
        return
    end

    condBorder._muiStickyPrimaryEnum = normalizedPrimary
    primaryLabel = HAZARD_LABEL_BY_ENUM[normalizedPrimary] or "UNKNOWN"
    local pr, pg, pb = GetHazardRGB(normalizedPrimary)
    SetPrimaryFillRGB(condBorder, pr, pg, pb, 1)
    primaryR, primaryG, primaryB = pr, pg, pb
    local fillLockKey = SafeToString(primaryLabel) .. "|" .. FormatRGBForLog(pr, pg, pb)
    if condBorder._muiPrimaryFillLockKey ~= fillLockKey then
        condBorder._muiPrimaryFillLockKey = fillLockKey
        CondBorderLog("overlayFill src=PRIMARY_LOCK tint=" .. SafeToString(primaryLabel)
            .. " rgb=" .. FormatRGBForLog(pr, pg, pb))
    end
    SyncPlayerFrameBarTint(true, pr, pg, pb, "PRIMARY_" .. primaryLabel)

    activeHazards[normalizedPrimary] = true
    local trackedCount = CountMapEntries(activeHazards)
    local totalDebuffs = CountActiveDebuffs("player", inRestricted)
    local hasOverlap = trackedCount >= 2
    local hasUnknownSecondary = (not hasOverlap) and (totalDebuffs >= 2) and (trackedCount < totalDebuffs)
    local secondaryEnum = PickSecondaryHazards(activeHazards, normalizedPrimary)
    local secondaryIID, candidateSecondaryEnum, secondaryColor = ResolveSecondaryAuraCandidate("player", inRestricted, primaryIID, normalizedPrimary)
    if (not IsTrackedHazardEnum(secondaryEnum)) and IsTrackedHazardEnum(candidateSecondaryEnum) and candidateSecondaryEnum ~= normalizedPrimary then
        secondaryEnum = candidateSecondaryEnum
    end
    local hasTypedSecondary = IsTrackedHazardEnum(secondaryEnum)
    local hasSecretSecondary = (secondaryColor ~= nil) and (not hasTypedSecondary)
    local hasEffectiveOverlap = hasOverlap or hasUnknownSecondary or hasTypedSecondary or hasSecretSecondary
    local overlapSecondaryToken = nil
    if hasTypedSecondary then
        overlapSecondaryToken = secondaryEnum
    elseif hasSecretSecondary then
        overlapSecondaryToken = SECRET_SECONDARY_TOKEN
    elseif hasUnknownSecondary then
        overlapSecondaryToken = UNKNOWN_SECONDARY_TOKEN
    end
    local resolvedSignature = BuildActiveHazardSignature(activeHazards)
    _lastCondBorderOverlapSignature = resolvedSignature
    _lastCondBorderOverlapPrimaryEnum = normalizedPrimary
    _lastCondBorderOverlapSecondaryEnum = overlapSecondaryToken
    local overlapPrimaryLabel = HAZARD_LABEL_BY_ENUM[normalizedPrimary] or SafeToString(normalizedPrimary)
    local overlapSecondaryLabel = HAZARD_LABEL_BY_ENUM[secondaryEnum]
        or (hasSecretSecondary and SECRET_SECONDARY_TOKEN)
        or (hasUnknownSecondary and UNKNOWN_SECONDARY_TOKEN)
        or "NONE"
    local overlapKey = overlapPrimaryLabel .. "|" .. overlapSecondaryLabel .. "|" .. (hasEffectiveOverlap and "1" or "0")
        .. "|" .. resolvedSignature
    if condBorder._muiLastOverlapLogKey ~= overlapKey then
        condBorder._muiLastOverlapLogKey = overlapKey
        CondBorderLog("overlap primary=" .. overlapPrimaryLabel
            .. " secondary=" .. overlapSecondaryLabel
            .. " hasOverlap=" .. (hasEffectiveOverlap and "YES" or "NO")
            .. " active=" .. resolvedSignature
            .. " secondaryIID=" .. SafeToString(secondaryIID))
    end

    -- Keep primary visuals owned by the primary debuff.
    SetBracketColorsRGB(condBorder, primaryR, primaryG, primaryB)
    SetPrimaryShimmerRGB(condBorder, NEUTRAL_SHIMMER_COLOR[1], NEUTRAL_SHIMMER_COLOR[2], NEUTRAL_SHIMMER_COLOR[3])

    if hasTypedSecondary then
        SetMainPulseState(condBorder, true, "PRIMARY_PLUS_SECONDARY")
        ShowSecondaryTypeBox(condBorder, secondaryEnum)
        LogTypeBoxDecision(condBorder, "OVERLAP_SECONDARY", normalizedPrimary, secondaryEnum, hasEffectiveOverlap, resolvedSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = true,
            secretSecondary = false,
            unknownSecondary = false,
            inRestricted = inRestricted == true,
        })
        _lastCondBorderAccentType = HAZARD_LABEL_BY_ENUM[secondaryEnum]
        _lastCondBorderExtraType = "PULSE_ONLY"
    elseif hasSecretSecondary then
        SetMainPulseState(condBorder, true, "PRIMARY_PLUS_SECRET")
        ShowSecondaryTypeBoxFromSecretColor(condBorder, secondaryColor)
        LogTypeBoxDecision(condBorder, "OVERLAP_SECRET", normalizedPrimary, SECRET_SECONDARY_TOKEN, hasEffectiveOverlap, resolvedSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = false,
            secretSecondary = true,
            unknownSecondary = false,
            inRestricted = inRestricted == true,
        })
        _lastCondBorderAccentType = SECRET_SECONDARY_TOKEN
        _lastCondBorderExtraType = "PULSE_ONLY"
    elseif hasUnknownSecondary then
        SetMainPulseState(condBorder, true, "PRIMARY_PLUS_UNKNOWN")
        ShowSecondaryTypeBox(condBorder, UNKNOWN_SECONDARY_TOKEN)
        LogTypeBoxDecision(condBorder, "OVERLAP_UNKNOWN", normalizedPrimary, UNKNOWN_SECONDARY_TOKEN, hasEffectiveOverlap, resolvedSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = false,
            secretSecondary = false,
            unknownSecondary = true,
            inRestricted = inRestricted == true,
        })
        _lastCondBorderAccentType = UNKNOWN_SECONDARY_TOKEN
        _lastCondBorderExtraType = "PULSE_ONLY"
    elseif hasEffectiveOverlap then
        SetMainPulseState(condBorder, true, "GENERIC_OVERLAP")
        HideSecondaryTypeBox(condBorder, "OVERLAP_NO_SECONDARY")
        LogTypeBoxDecision(condBorder, "OVERLAP_HIDE", normalizedPrimary, nil, hasEffectiveOverlap, resolvedSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = false,
            secretSecondary = false,
            unknownSecondary = hasUnknownSecondary,
            inRestricted = inRestricted == true,
        })
        _lastCondBorderAccentType = "GENERIC"
        _lastCondBorderExtraType = "PULSE_ONLY"
    else
        SetMainPulseState(condBorder, true, "PRIMARY_ONLY")
        HideSecondaryTypeBox(condBorder, "PRIMARY_ONLY")
        LogTypeBoxDecision(condBorder, "PRIMARY_HIDE", normalizedPrimary, nil, hasEffectiveOverlap, resolvedSignature, {
            trackedCount = trackedCount,
            totalDebuffs = totalDebuffs,
            secondaryIID = secondaryIID,
            typedSecondary = false,
            secretSecondary = false,
            unknownSecondary = false,
            inRestricted = inRestricted == true,
        })
        _lastCondBorderAccentType = "NEUTRAL"
        _lastCondBorderExtraType = "PULSE_ONLY"
    end
end

local function ApplySecondaryShimmerStateSafe(condBorder, primaryEnum, inRestricted, sourceStep, primaryIID)
    local ok, err = pcall(ApplySecondaryShimmerState, condBorder, primaryEnum, inRestricted, primaryIID)
    if ok then
        return
    end

    MarkError(sourceStep or "ACCENT_SAFE", err)
    local primaryR = condBorder.primaryR or 1
    local primaryG = condBorder.primaryG or 1
    local primaryB = condBorder.primaryB or 1
    SetBracketColorsRGB(condBorder, primaryR, primaryG, primaryB)
    SetPrimaryShimmerRGB(condBorder, NEUTRAL_SHIMMER_COLOR[1], NEUTRAL_SHIMMER_COLOR[2], NEUTRAL_SHIMMER_COLOR[3])
    SetMainPulseState(condBorder, true, "ACCENT_SAFE")
    HideSecondaryTypeBox(condBorder, "SAFE_FALLBACK")
    local normalizedPrimary = NormalizeHazardEnum(primaryEnum)
    _lastCondBorderOverlapSignature = "SAFE_FALLBACK"
    _lastCondBorderOverlapPrimaryEnum = normalizedPrimary
    _lastCondBorderOverlapSecondaryEnum = nil
    if condBorder then
        condBorder._muiLastOverlapLogKey = nil
    end
    if IsTrackedHazardEnum(normalizedPrimary) then
        local pr, pg, pb = GetHazardRGB(normalizedPrimary)
        SyncPlayerFrameBarTint(true, pr, pg, pb, "PRIMARY_SAFE")
    elseif primaryR ~= nil and primaryG ~= nil and primaryB ~= nil then
        SyncPlayerFrameBarTint(true, primaryR, primaryG, primaryB, "RGB_OVERLAY_SAFE")
    end
    _lastCondBorderAccentType = "NEUTRAL"
    _lastCondBorderExtraType = "PULSE_ONLY"
end

-- =========================================================================
--  ACTIVATION CONTROLLERS
-- =========================================================================

local function PlayActivationAnimations(condBorder)
    condBorder._muiPendingBarTintOff = false
    if condBorder.fadeOut:IsPlaying() then 
        condBorder.fadeOut:Stop() 
    end
    
    if condBorder:GetAlpha() < 1 and not condBorder.fadeIn:IsPlaying() then
        condBorder.fadeIn:Play()
    end

    if condBorder.bracketFrame then
        condBorder.bracketFrame:SetAlpha(0.56)
    end
    if condBorder.bracketGroup and not condBorder.bracketGroup:IsPlaying() then
        condBorder.bracketGroup:Play()
    end

    if condBorder.fillPulse and not condBorder.fillPulse:IsPlaying() then
        condBorder.fillPulse:Play()
        MarkStep("OVERLAY_PULSE_ON", "ACTIVATE")
    end
end

local function ActivateHazardSecret(condBorder, borderColor, iid, tintEnum)
    if not condBorder or not borderColor or not borderColor.GetRGBA then return false end

    local r, g, b
    if IsTrackedHazardEnum(tintEnum) then
        -- Prevent first-frame hue flash: for tracked types, lock overlay fill to canonical palette.
        r, g, b = GetHazardRGB(tintEnum)
        SetPrimaryFillRGB(condBorder, r, g, b, 1)
        condBorder._muiSecretOverlayIID = nil
        condBorder._muiSecretOverlayR = nil
        condBorder._muiSecretOverlayG = nil
        condBorder._muiSecretOverlayB = nil
        condBorder._muiSecretOverlayA = nil
        condBorder._muiSecretOverlayLogKey = nil
    else
        local isNewIID = condBorder._muiSecretOverlayIID ~= iid
        if isNewIID then
            local sr, sg, sb, sa = borderColor:GetRGBA()
            condBorder._muiSecretOverlayIID = iid
            condBorder._muiSecretOverlayR = sr
            condBorder._muiSecretOverlayG = sg
            condBorder._muiSecretOverlayB = sb
            condBorder._muiSecretOverlayA = sa
        end

        local sr = condBorder._muiSecretOverlayR
        local sg = condBorder._muiSecretOverlayG
        local sb = condBorder._muiSecretOverlayB
        local sa = condBorder._muiSecretOverlayA
        if sr == nil or sg == nil or sb == nil then
            -- Fallback: cache not yet populated. Skip SetPrimaryFillRGB on this tick to
            -- avoid a first-frame brightness flash from raw GetRGBA() secret values.
            -- primaryR/G/B retain whatever they were; next tick will have cached values.
            r, g, b = condBorder.primaryR or 1, condBorder.primaryG or 1, condBorder.primaryB or 1
        elseif isNewIID then
            -- First tick for this IID: cache was just populated from GetRGBA().
            -- Do NOT push those raw secret values to the fill texture yet — they produce
            -- a brightness flash on the first rendered frame. Hold existing fill color
            -- for this one tick; the REUSE path will apply the cached values next tick.
            r, g, b = condBorder.primaryR or 1, condBorder.primaryG or 1, condBorder.primaryB or 1
        else
            SetPrimaryFillRGB(condBorder, sr, sg, sb, sa or 1)
            r, g, b = sr, sg, sb
        end

        -- Flag the first tick of a new IID so ApplySecondaryShimmerState can suppress
        -- the bar tint call on that tick only (prevents the first-frame brightness flash).
        condBorder._muiSecretOverlayNewIID = isNewIID or false

        local lockState = isNewIID and "NEW" or "REUSE"
        local lockKey = SafeToString(iid) .. "|" .. lockState
        if condBorder._muiSecretOverlayLogKey ~= lockKey then
            condBorder._muiSecretOverlayLogKey = lockKey
            CondBorderLog("overlayFillLock iid=" .. SafeToString(iid) .. " state=" .. lockState .. " rgb=secret")
        end
    end

    local tintSource = "SECRET_UNKNOWN"
    if IsTrackedHazardEnum(tintEnum) then
        tintSource = "SECRET_" .. SafeToString(HAZARD_LABEL_BY_ENUM[tintEnum])
        SyncPlayerFrameBarTint(true, r, g, b, tintSource)
    else
        -- Avoid pushing weak/unknown bar tint first.
        -- The resolved typed pass (ApplySecondaryShimmerState) writes the stable bar tint.
    end
    local tintLabel = HAZARD_LABEL_BY_ENUM[NormalizeHazardEnum(tintEnum)] or "UNKNOWN"
    local rgbLog = IsTrackedHazardEnum(tintEnum) and FormatRGBForLog(r, g, b) or "secret"
    local activateLogKey = SafeToString(iid) .. "|" .. SafeToString(tintLabel) .. "|" .. SafeToString(rgbLog)
    if _lastCondBorderSecretActivateLogKey ~= activateLogKey then
        _lastCondBorderSecretActivateLogKey = activateLogKey
        CondBorderLog("activate=SECRET iid=" .. SafeToString(iid) .. " tint=" .. SafeToString(tintLabel) .. " rgb=" .. rgbLog)
    end
    local overlayFillSrc = IsTrackedHazardEnum(tintEnum) and "CANONICAL" or "SECRET"
    local overlayFillRGB = FormatRGBForLog(r, g, b)
    local overlayFillLogKey = overlayFillSrc .. "|" .. SafeToString(iid) .. "|" .. SafeToString(tintLabel) .. "|" .. SafeToString(overlayFillRGB)
    if _lastCondBorderSecretOverlayFillLogKey ~= overlayFillLogKey then
        _lastCondBorderSecretOverlayFillLogKey = overlayFillLogKey
        CondBorderLog("overlayFill src=" .. overlayFillSrc
            .. " iid=" .. SafeToString(iid)
            .. " tint=" .. SafeToString(tintLabel)
            .. " rgb=" .. overlayFillRGB)
    end

    if not _condBorderActive then
        PlayActivationAnimations(condBorder)
        _condBorderActive = true
    end
    _lastCondBorderDetectedAt = GetDebugNow()
    return true
end

local function ActivateHazardRGB(condBorder, r, g, b, tintEnum)
    if not condBorder then return false end
    
    SetPrimaryFillRGB(condBorder, r, g, b, 1)
    local src = "RGB_CUSTOM"
    if IsTrackedHazardEnum(tintEnum) then
        src = "RGB_" .. SafeToString(HAZARD_LABEL_BY_ENUM[tintEnum])
    end
    SyncPlayerFrameBarTint(true, r, g, b, src)
    CondBorderLog("activate=RGB rgb=" .. FormatRGBForLog(r or 1, g or 1, b or 1))

    if not _condBorderActive then
        PlayActivationAnimations(condBorder)
        _condBorderActive = true
    end
    _lastCondBorderDetectedAt = GetDebugNow()
    return true
end

local function DeactivateHazard(condBorder)
    if not condBorder then return end
    if not _condBorderActive then
        if condBorder.fadeOut and condBorder.fadeOut:IsPlaying() then
            return
        end
        condBorder._muiSecretOverlayIID = nil
        condBorder._muiSecretOverlayR = nil
        condBorder._muiSecretOverlayG = nil
        condBorder._muiSecretOverlayB = nil
        condBorder._muiSecretOverlayA = nil
        condBorder._muiSecretOverlayLogKey = nil
        condBorder._muiStickyPrimaryEnum = nil
        condBorder._muiLastOverlapLogKey = nil
        HideSecondaryTypeBox(condBorder, "DEACTIVATE_IDLE")
        condBorder._muiPendingBarTintOff = false
        _lastCondBorderOverlapSignature = "none"
        _lastCondBorderOverlapPrimaryEnum = nil
        _lastCondBorderOverlapSecondaryEnum = nil
        _lastCondBorderBleedCurveIID = nil
        _lastCondBorderBleedCurveCandidates = 0
        _lastCondBorderAuraEnumLogKey = nil
        _lastCondBorderActiveCollectLogKey = nil
        _lastCondBorderSecondaryCandidateLogKey = nil
        SyncPlayerFrameBarTint(false, nil, nil, nil, "DEACTIVATE_IDLE")
        return
    end

    if condBorder.fadeIn:IsPlaying() then
        condBorder.fadeIn:Stop()
    end
    condBorder._muiSecretOverlayIID = nil
    condBorder._muiSecretOverlayR = nil
    condBorder._muiSecretOverlayG = nil
    condBorder._muiSecretOverlayB = nil
    condBorder._muiSecretOverlayA = nil
    condBorder._muiSecretOverlayLogKey = nil
    condBorder._muiStickyPrimaryEnum = nil
    condBorder._muiLastOverlapLogKey = nil
    HideSecondaryTypeBox(condBorder, "DEACTIVATE")
    _lastCondBorderOverlapSignature = "none"
    _lastCondBorderOverlapPrimaryEnum = nil
    _lastCondBorderOverlapSecondaryEnum = nil
    _lastCondBorderBleedCurveIID = nil
    _lastCondBorderBleedCurveCandidates = 0
    _lastCondBorderAuraEnumLogKey = nil
    _lastCondBorderActiveCollectLogKey = nil
    _lastCondBorderSecondaryCandidateLogKey = nil
    SetMainPulseState(condBorder, false, "DEACTIVATE")
    condBorder._muiPendingBarTintOff = true
    condBorder.fadeOut:Play()
    _condBorderActive = false
end

-- =========================================================================
--  BLIZZARD HOOK
-- =========================================================================

local function EnsureBlizzHook()
    if _blizzHookRegistered then return end

    local function ResolveFrameDebuffType(df)
        if not df then
            return nil
        end

        local dt = NormalizeHazardEnum(df.debuffType)
        if not IsTrackedHazardEnum(dt) then
            dt = NormalizeHazardEnum(df.dispelName)
        end
        if not IsTrackedHazardEnum(dt) then
            dt = NormalizeHazardEnum(df.dispelType)
        end
        if not IsTrackedHazardEnum(dt) then
            dt = NormalizeHazardEnum(df.type)
        end
        if IsTrackedHazardEnum(dt) then
            return dt
        end
        return nil
    end

    local function CaptureFromBlizzFrame(blizzFrame)
        if not blizzFrame or not blizzFrame.unit then return end
        local unit = blizzFrame.unit
        if type(unit) ~= "string" then return end
        if unit ~= "player" then return end

        local entry = _blizzDispelCache[unit]
        if not entry then
            entry = { debuffs = {}, dispellable = {}, types = {} }
            _blizzDispelCache[unit] = entry
        else
            wipe(entry.debuffs)
            wipe(entry.dispellable)
            wipe(entry.types)
        end

        local function StoreType(iid, dt)
            if IsTrackedHazardEnum(dt) then
                entry.types[iid] = dt
            end
        end

        if blizzFrame.debuffFrames then
            for _, df in ipairs(blizzFrame.debuffFrames) do
                local shown = (not df) and false or (not df.IsShown) or df:IsShown()
                if df and df.auraInstanceID and shown then
                    if not ShouldIgnoreLockoutDebuffAura(df) then
                        local iid = df.auraInstanceID
                        entry.debuffs[iid] = true
                        StoreType(iid, ResolveFrameDebuffType(df))
                    end
                end
            end
        end
        if blizzFrame.dispelDebuffFrames then
            for _, df in ipairs(blizzFrame.dispelDebuffFrames) do
                local shown = (not df) and false or (not df.IsShown) or df:IsShown()
                if df and df.auraInstanceID and shown then
                    if not ShouldIgnoreLockoutDebuffAura(df) then
                        local iid = df.auraInstanceID
                        entry.debuffs[iid] = true
                        entry.dispellable[iid] = true
                        StoreType(iid, ResolveFrameDebuffType(df))
                    end
                end
            end
        end

    end

    hooksecurefunc("CompactUnitFrame_UpdateAuras", CaptureFromBlizzFrame)
    if CompactUnitFrame_UpdateDebuffs then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", CaptureFromBlizzFrame)
    end
    _blizzHookRegistered = true
    CondBorderLog("Blizzard frame hook registered")
end

-- =========================================================================
--  BLEED DETECTION
-- =========================================================================

ScanForBleedAuraID = function(unit, inRestricted)
    local curveIID = ScanForBleedAuraIDByCurve(unit, inRestricted)
    if curveIID then
        return curveIID, DISPEL_ENUM.Bleed
    end

    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return nil end
    local function ScanByIndex()
        for i = 1, 40 do
            local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            if not aura then break end
            local dt = NormalizeBleedLikeEnum(aura.dispelType)
            if not dt then
                dt = NormalizeBleedLikeEnum(aura.dispelName)
            end
            if not dt then
                dt = NormalizeBleedLikeEnum(aura.debuffType)
            end
            if not dt then
                dt = NormalizeBleedLikeEnum(aura.type)
            end
            if dt then
                return aura.auraInstanceID, dt
            end
        end
        return nil
    end

    if inRestricted then
        local ok, iid, dt = pcall(ScanByIndex)
        if ok then
            return iid, dt
        end
        MarkError("BLEED_SCAN_COMBAT", iid)
        return nil
    end

    return ScanByIndex()
end

local function TruthyBoolOrCount(value)
    local vt = type(value)
    if vt == "boolean" then
        return value, true
    end
    if vt == "number" then
        if IsSecretValue(value) then
            return false, false
        end
        return value > 0, true
    end
    return false, false
end

local function HasBleedInTypeTable(tbl, typeCode)
    if type(tbl) ~= "table" then
        return false
    end

    local requestedEnum = NormalizeTrackerTypeCode(typeCode)
    for key, direct in pairs(tbl) do
        local keyEnum = NormalizeTrackerTypeCode(key)
        if keyEnum and requestedEnum and keyEnum == requestedEnum then
            local b, used = TruthyBoolOrCount(direct)
            if used then
                return b
            end
            if direct == true then
                return true
            end
        end
    end

    local keys = { "BLEED", "bleed", "Bleed", "TYPE_BLEED", "type_bleed" }
    for _, k in ipairs(keys) do
        local v = tbl[k]
        local b, used = TruthyBoolOrCount(v)
        if used then
            return b
        end
    end

    for key, v in pairs(tbl) do
        local keyEnum = NormalizeTrackerTypeCode(key)
        local valEnum = NormalizeTrackerTypeCode(v)
        if requestedEnum and ((keyEnum and keyEnum == requestedEnum) or (valEnum and valEnum == requestedEnum)) then
            return true
        end
        if v == typeCode or v == "BLEED" or v == "bleed" or v == "Bleed" then
            return true
        end
    end
    return false
end

TrackerHasTypeActive = function(unit, typeCode)
    local tracker = _G.MidnightUI_DebuffTracker
    if not tracker then
        return false
    end

    local function TryMethod(methodName, ...)
        local fn = tracker[methodName]
        if type(fn) ~= "function" then
            return nil
        end
        local ok, result = pcall(fn, tracker, ...)
        if not ok then
            return nil
        end
        local b, used = TruthyBoolOrCount(result)
        if used then
            _lastCondBorderTrackerBleedMethod = methodName
            return b
        end
        local wantedEnum = NormalizeTrackerTypeCode(typeCode)
        local resultEnum = NormalizeTrackerTypeCode(result)
        if wantedEnum and resultEnum and wantedEnum == resultEnum then
            _lastCondBorderTrackerBleedMethod = methodName
            return true
        end
        if type(result) == "table" then
            _lastCondBorderTrackerBleedMethod = methodName
            return HasBleedInTypeTable(result, typeCode)
        end
        return nil
    end

    local callShapes = {
        { "HasType", unit, typeCode },
        { "HasType", typeCode, unit },
        { "HasDebuffType", unit, typeCode },
        { "HasDebuffType", typeCode, unit },
        { "HasActiveType", unit, typeCode },
        { "HasActiveType", typeCode, unit },
        { "IsTypeActive", unit, typeCode },
        { "IsTypeActive", typeCode, unit },
        { "IsDebuffTypeActive", unit, typeCode },
        { "IsDebuffTypeActive", typeCode, unit },
        { "GetTypeCount", unit, typeCode },
        { "GetTypeCount", typeCode, unit },
    }
    for _, shape in ipairs(callShapes) do
        local value = TryMethod(shape[1], shape[2], shape[3])
        if value ~= nil then
            return value
        end
    end

    local active = TryMethod("GetActiveTypes", unit)
    if active ~= nil then
        return active
    end

    if type(tracker.GetHighestPriority) == "function" then
        local ok, topType = pcall(tracker.GetHighestPriority, tracker, unit)
        if ok then
            _lastCondBorderTrackerBleedMethod = "GetHighestPriority"
            local wantedEnum = NormalizeTrackerTypeCode(typeCode)
            local topEnum = NormalizeTrackerTypeCode(topType)
            if wantedEnum and topEnum then
                return wantedEnum == topEnum
            end
            return topType == typeCode
        end
    end
    return false
end

TrackerSaysBleedActive = function()
    return TrackerHasTypeActive("player", 6)   -- legacy TYPE_BLEED
        or TrackerHasTypeActive("player", 9)   -- Enrage alias
        or TrackerHasTypeActive("player", 11)  -- Aura dispelType alias
        or TrackerHasTypeActive("player", "BLEED")
        or TrackerHasTypeActive("player", "ENRAGE")
end

-- =========================================================================
--  DISPEL TRACKING OVERLAY
-- =========================================================================

local function NormalizeAuraStackCount(value)
    if value == nil or IsSecretValue(value) then
        return ""
    end
    local n = tonumber(value)
    if not n or IsSecretValue(n) then
        return ""
    end
    n = math.floor(n + 0.5)
    if n <= 1 then
        return ""
    end
    return tostring(n)
end

local function ApplyDispelTrackingAnchor(frame, ownerFrame)
    if not frame then
        return
    end
    local combat = EnsureCombatSettingsTable()
    local pos = combat.dispelTrackingPosition
    local point, relativePoint, xOfs, yOfs
    if type(pos) == "table" then
        if #pos >= 5 then
            point, relativePoint, xOfs, yOfs = pos[1], pos[3], pos[4], pos[5]
        elseif #pos >= 4 then
            point, relativePoint, xOfs, yOfs = pos[1], pos[2], pos[3], pos[4]
        end
    end

    frame:ClearAllPoints()
    if point and relativePoint then
        local scale = frame:GetScale()
        if not scale or scale == 0 then
            scale = 1
        end
        frame:SetPoint(point, UIParent, relativePoint, (tonumber(xOfs) or 0) * scale, (tonumber(yOfs) or 0) * scale)
        return
    end

    if ownerFrame then
        frame:SetPoint("BOTTOM", ownerFrame, "TOP", 0, 14)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

local function SetDispelTrackingIconBorderColor(btn, r, g, b, a)
    if not btn or not btn.SetBackdropBorderColor then
        return
    end
    local alpha = a or 1
    local ok = pcall(btn.SetBackdropBorderColor, btn, r, g, b, alpha)
    if ok then
        return
    end
    btn:SetBackdropBorderColor(NEUTRAL_SHIMMER_COLOR[1], NEUTRAL_SHIMMER_COLOR[2], NEUTRAL_SHIMMER_COLOR[3], alpha)
end

local function EnsureDispelTrackingIconButton(parent, index)
    local btn = _dispelTrackButtons[index]
    if btn then
        return btn
    end

    btn = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    btn:SetSize(DISPEL_TRACKING_BASE_ICON_SIZE, DISPEL_TRACKING_BASE_ICON_SIZE)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    btn:SetBackdropColor(0, 0, 0, 0.75)
    btn:SetBackdropBorderColor(0, 0, 0, 1)

    local icon = btn:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon = icon

    local count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 1)
    count:SetJustifyH("RIGHT")
    count:SetTextColor(1, 1, 1, 1)
    btn.countText = count

    btn:EnableMouse(true)
    btn:SetScript("OnEnter", function(self)
        if not GameTooltip then
            return
        end
        if not self.auraIndex and not self.auraInstanceID then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local shown = false
        if self.auraInstanceID and GameTooltip.SetUnitDebuffByAuraInstanceID then
            local ok, result = pcall(GameTooltip.SetUnitDebuffByAuraInstanceID, GameTooltip, "player", self.auraInstanceID)
            shown = ok and result
        end
        if (not shown) and self.auraIndex and GameTooltip.SetUnitDebuff then
            local ok, result = pcall(GameTooltip.SetUnitDebuff, GameTooltip, "player", self.auraIndex)
            shown = ok and result
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

    _dispelTrackButtons[index] = btn
    return btn
end

EnsureDispelTrackingFrame = function(ownerFrame)
    if _dispelTrackFrame then
        return _dispelTrackFrame
    end

    local frame = CreateFrame("Frame", "MidnightUI_DispelTrackingFrame", UIParent)
    local layout = GetDispelTrackingLayout(DISPEL_TRACKING_DEFAULT_MAX, 100, DISPEL_TRACKING_ORIENTATION_HORIZONTAL)
    frame:SetSize(layout.width, layout.height)
    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(((ownerFrame and ownerFrame.GetFrameLevel and ownerFrame:GetFrameLevel()) or 10) + 30)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)
    frame:Hide()
    _dispelTrackFrame = frame
    return frame
end

EnsureDispelTrackingDragOverlay = function(ownerFrame)
    local frame = EnsureDispelTrackingFrame(ownerFrame)
    if not frame then
        return nil
    end
    if frame.dragOverlay then
        frame.dragOverlay:SetAllPoints()
        return frame.dragOverlay
    end

    local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("DIALOG")
    if _G.MidnightUI_StyleOverlay then
        _G.MidnightUI_StyleOverlay(overlay, "DISPEL TRACKING", nil, "auras")
    else
        overlay:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true,
            tileSize = 16,
            edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
        overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
        local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        label:SetPoint("CENTER")
        label:SetText("DISPEL TRACKING")
        label:SetTextColor(1, 1, 1)
    end
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function()
        frame:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        frame:StopMovingOrSizing()
        local point, _, relativePoint, xOfs, yOfs = frame:GetPoint()
        if not point or not relativePoint then
            return
        end
        local scale = frame:GetScale()
        if not scale or scale == 0 then
            scale = 1
        end
        local combat = EnsureCombatSettingsTable()
        combat.dispelTrackingPosition = {
            point,
            relativePoint,
            (tonumber(xOfs) or 0) / scale,
            (tonumber(yOfs) or 0) / scale,
        }
    end)
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "DispelTracking")
    end
    frame.dragOverlay = overlay
    return overlay
end

local function CollectTrackedDebuffAuras(unit, inRestricted, maxShown)
    local entries = {}
    if not unit then
        return entries
    end

    local secretFallbackIIDs = nil
    if inRestricted and unit == "player" then
        secretFallbackIIDs = {}
        if _lastCondBorderIID then
            secretFallbackIIDs[_lastCondBorderIID] = true
        end
        local entry = _blizzDispelCache[unit]
        if entry and entry.debuffs then
            for iid in pairs(entry.debuffs) do
                secretFallbackIIDs[iid] = true
            end
        end
        if next(secretFallbackIIDs) == nil then
            secretFallbackIIDs = nil
        end
    end

    local function AddAuraEntry(aura, auraIndex, enumValue, allowUnknownType)
        if not aura then
            return
        end
        local tracked = IsTrackedHazardEnum(enumValue)
        if (not tracked) and (allowUnknownType ~= true) then
            return
        end
        local icon = aura.icon or aura.iconFileID or 134400
        entries[#entries + 1] = {
            icon = icon,
            stackCount = aura.applications or aura.stackCount or aura.charges,
            auraInstanceID = aura.auraInstanceID,
            auraIndex = auraIndex,
            enumValue = tracked and enumValue or nil,
            unknownType = (not tracked),
            source = (allowUnknownType == true) and "SECRET_FALLBACK" or "TRACKED_TYPE",
        }
        return true
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        for i = 1, 40 do
            if #entries >= maxShown then
                break
            end
            local aura = nil
            if inRestricted then
                local ok, result = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
                if not ok then
                    break
                end
                aura = result
            else
                aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
            end
            if not aura then
                break
            end
            if not ShouldIgnoreLockoutDebuffAura(aura) then
                local enumValue = ResolveHazardEnumFromAuraData(aura)
                if not IsTrackedHazardEnum(enumValue) and aura.auraInstanceID then
                    enumValue = ResolveHazardEnumForAuraID(unit, aura.auraInstanceID, inRestricted)
                end
                local allowUnknownType = false
                if (not IsTrackedHazardEnum(enumValue))
                    and secretFallbackIIDs
                    and aura.auraInstanceID
                    and secretFallbackIIDs[aura.auraInstanceID] then
                    allowUnknownType = true
                end
                local added = AddAuraEntry(aura, i, enumValue, allowUnknownType)
                if added and secretFallbackIIDs and aura.auraInstanceID then
                    secretFallbackIIDs[aura.auraInstanceID] = nil
                end
            end
        end

        if (#entries < maxShown) and secretFallbackIIDs and C_UnitAuras.GetAuraDataByAuraInstanceID then
            for fallbackIID in pairs(secretFallbackIIDs) do
                if #entries >= maxShown then
                    break
                end
                local fallbackAura = nil
                if inRestricted then
                    local ok, aura = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, fallbackIID)
                    if ok then
                        fallbackAura = aura
                    end
                else
                    fallbackAura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, fallbackIID)
                end
                if fallbackAura and (not ShouldIgnoreLockoutDebuffAura(fallbackAura)) then
                    AddAuraEntry(fallbackAura, nil, nil, true)
                end
            end
        end
        return entries
    end

    if type(UnitDebuff) ~= "function" then
        return entries
    end
    for i = 1, 40 do
        if #entries >= maxShown then
            break
        end
        local name, icon, count, debuffType, _, _, _, _, _, spellID = UnitDebuff(unit, i)
        if not name then
            break
        end
        if not ShouldIgnoreLockoutDebuffAura({
            name = name,
            spellId = spellID,
            spellID = spellID,
            debuffType = debuffType,
            dispelName = debuffType,
        }) then
            local enumValue = NormalizeHazardEnum(debuffType)
            if IsTrackedHazardEnum(enumValue) then
                entries[#entries + 1] = {
                    icon = icon,
                    stackCount = count,
                    auraIndex = i,
                    enumValue = enumValue,
                }
            end
        end
    end
    return entries
end

local function BuildDispelTrackingOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then
        return
    end
    local combat = EnsureCombatSettingsTable()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Dispel Tracking")
    b:Checkbox("Enable Dispel Tracking", combat.dispelTrackingEnabled ~= false, function(v)
        combat.dispelTrackingEnabled = v and true or false
        RefreshDispelTrackingOverlay(_playerFrame or _G.MidnightUI_PlayerFrame, GetRestrictionState(), false)
    end)
    b:Slider("Max Shown", DISPEL_TRACKING_MIN, DISPEL_TRACKING_MAX, 1, ClampDispelTrackingCount(combat.dispelTrackingMaxShown), function(v)
        combat.dispelTrackingMaxShown = ClampDispelTrackingCount(v)
        RefreshDispelTrackingOverlay(_playerFrame or _G.MidnightUI_PlayerFrame, GetRestrictionState(), false)
        if _G.MidnightUI_GetOverlayHandle then
            local handle = _G.MidnightUI_GetOverlayHandle(key)
            if handle and handle.SetAllPoints then
                handle:SetAllPoints()
            end
        end
    end)
    b:Slider("Icon Size %", DISPEL_TRACKING_ICON_SCALE_MIN, DISPEL_TRACKING_ICON_SCALE_MAX, 5, ClampDispelTrackingIconScale(combat.dispelTrackingIconScale), function(v)
        combat.dispelTrackingIconScale = ClampDispelTrackingIconScale(v)
        RefreshDispelTrackingOverlay(_playerFrame or _G.MidnightUI_PlayerFrame, GetRestrictionState(), false)
        if _G.MidnightUI_GetOverlayHandle then
            local handle = _G.MidnightUI_GetOverlayHandle(key)
            if handle and handle.SetAllPoints then
                handle:SetAllPoints()
            end
        end
    end)
    b:Dropdown("Orientation", { "Horizontal", "Vertical" }, (NormalizeDispelTrackingOrientation(combat.dispelTrackingOrientation) == DISPEL_TRACKING_ORIENTATION_VERTICAL) and "Vertical" or "Horizontal", function(v)
        if v == "Vertical" then
            combat.dispelTrackingOrientation = DISPEL_TRACKING_ORIENTATION_VERTICAL
        else
            combat.dispelTrackingOrientation = DISPEL_TRACKING_ORIENTATION_HORIZONTAL
        end
        RefreshDispelTrackingOverlay(_playerFrame or _G.MidnightUI_PlayerFrame, GetRestrictionState(), false)
        if _G.MidnightUI_GetOverlayHandle then
            local handle = _G.MidnightUI_GetOverlayHandle(key)
            if handle and handle.SetAllPoints then
                handle:SetAllPoints()
            end
        end
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, combat.dispelTrackingAlpha or 1.0, function(v)
        combat.dispelTrackingAlpha = v
        RefreshDispelTrackingOverlay(_playerFrame or _G.MidnightUI_PlayerFrame, GetRestrictionState(), false)
    end)
    return b:Height()
end

RegisterDispelTrackingOverlaySettings = function()
    if _dispelTrackSettingsRegistered then
        return
    end
    if not _G.MidnightUI_RegisterOverlaySettings then
        return
    end
    _G.MidnightUI_RegisterOverlaySettings("DispelTracking", {
        title = "Dispel Tracking",
        build = BuildDispelTrackingOverlaySettings,
    })
    _dispelTrackSettingsRegistered = true
end

RefreshDispelTrackingOverlay = function(ownerFrame, inRestricted, forceHide)
    local frame = EnsureDispelTrackingFrame(ownerFrame)
    if not frame then
        return
    end

    local combat = EnsureCombatSettingsTable()
    local enabled = (forceHide ~= true) and IsDispelTrackingEnabled()
    local maxShown = ClampDispelTrackingCount(combat.dispelTrackingMaxShown)
    combat.dispelTrackingMaxShown = maxShown
    local iconScale = ClampDispelTrackingIconScale(combat.dispelTrackingIconScale)
    combat.dispelTrackingIconScale = iconScale
    local orientation = NormalizeDispelTrackingOrientation(combat.dispelTrackingOrientation)
    combat.dispelTrackingOrientation = orientation
    local layout = GetDispelTrackingLayout(maxShown, iconScale, orientation)

    frame:SetScale(1)
    frame:SetAlpha(combat.dispelTrackingAlpha or 1.0)
    frame:SetFrameLevel(((ownerFrame and ownerFrame.GetFrameLevel and ownerFrame:GetFrameLevel()) or frame:GetFrameLevel() or 1) + 30)
    local overlayPrimaryR, overlayPrimaryG, overlayPrimaryB = nil, nil, nil
    if _condBorderActive and ownerFrame and ownerFrame.conditionBorder then
        overlayPrimaryR = ownerFrame.conditionBorder.primaryR
        overlayPrimaryG = ownerFrame.conditionBorder.primaryG
        overlayPrimaryB = ownerFrame.conditionBorder.primaryB
    end
    frame:SetSize(layout.width, layout.height)
    ApplyDispelTrackingAnchor(frame, ownerFrame)

    if not enabled then
        for _, btn in ipairs(_dispelTrackButtons) do
            btn:Hide()
        end
        if frame.dragOverlay then
            frame.dragOverlay:Hide()
        end
        frame:Hide()
        return
    end

    local ownerShown = false
    local movementUnlocked = IsMovementModeUnlocked()
    if ownerFrame and ownerFrame.IsShown then
        ownerShown = ownerFrame:IsShown() == true
    end
    if (not ownerShown) and (not movementUnlocked) then
        for _, btn in ipairs(_dispelTrackButtons) do
            btn:Hide()
        end
        if frame.dragOverlay then
            frame.dragOverlay:Hide()
        end
        frame:Hide()
        return
    end

    local tracked = CollectTrackedDebuffAuras("player", inRestricted, maxShown)
    local showPreviewIcons = movementUnlocked and (tracked[1] == nil)
    local shownCount = 0
    for i = 1, maxShown do
        local btn = EnsureDispelTrackingIconButton(frame, i)
        btn:SetSize(layout.iconSize, layout.iconSize)
        local entry = tracked[i]
        if entry or showPreviewIcons then
            local r, g, b
            if entry and IsTrackedHazardEnum(entry.enumValue) then
                r, g, b = GetHazardRGB(entry.enumValue)
            elseif overlayPrimaryR ~= nil and overlayPrimaryG ~= nil and overlayPrimaryB ~= nil then
                r, g, b = overlayPrimaryR, overlayPrimaryG, overlayPrimaryB
            else
                r, g, b = NEUTRAL_SHIMMER_COLOR[1], NEUTRAL_SHIMMER_COLOR[2], NEUTRAL_SHIMMER_COLOR[3]
            end
            SetDispelTrackingIconBorderColor(btn, r, g, b, 1)
            btn.icon:SetTexture((entry and entry.icon) or 134400)
            btn.countText:SetText(entry and NormalizeAuraStackCount(entry.stackCount) or "")
            btn.auraInstanceID = entry and entry.auraInstanceID or nil
            btn.auraIndex = entry and entry.auraIndex or nil
            btn:ClearAllPoints()
            if layout.orientation == DISPEL_TRACKING_ORIENTATION_VERTICAL then
                btn:SetPoint("BOTTOM", frame, "BOTTOM", 0, layout.iconStartY + ((i - 1) * layout.strideY))
            else
                btn:SetPoint("LEFT", frame, "LEFT", layout.iconStartX + ((i - 1) * layout.strideX), 0)
            end
            btn:Show()
            shownCount = shownCount + 1
        else
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            btn:Hide()
        end
    end
    for i = maxShown + 1, #_dispelTrackButtons do
        local btn = _dispelTrackButtons[i]
        if btn then
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            btn.countText:SetText("")
            btn:Hide()
        end
    end

    if movementUnlocked then
        EnsureDispelTrackingDragOverlay(ownerFrame)
        if frame.dragOverlay then
            frame.dragOverlay:Show()
        end
        frame:Show()
    else
        if frame.dragOverlay then
            frame.dragOverlay:Hide()
        end
        if shownCount > 0 then
            frame:Show()
        else
            frame:Hide()
        end
    end
end

function M.SetDispelTrackingLocked(locked)
    RegisterDispelTrackingOverlaySettings()
    _dispelTrackLocked = (locked ~= false)
    local owner = _playerFrame or _G.MidnightUI_PlayerFrame
    RefreshDispelTrackingOverlay(owner, GetRestrictionState(), false)
end

function M.RefreshDispelTracking(frame)
    RegisterDispelTrackingOverlaySettings()
    local owner = frame or _playerFrame or _G.MidnightUI_PlayerFrame
    RefreshDispelTrackingOverlay(owner, GetRestrictionState(), false)
end

-- =========================================================================
--  MAIN UPDATE
-- =========================================================================

function M.Update(frame)
    _lastCondBorderUpdateSeq = _lastCondBorderUpdateSeq + 1
    MarkStep("UPDATE_BEGIN")

    if not frame then
        MarkStep("UPDATE_NO_FRAME")
        return
    end
    local condBorder = frame.conditionBorder
    if not condBorder then
        MarkStep("UPDATE_NO_BORDER")
        return
    end
    local inRestricted = GetRestrictionState()
    MaybeRunReloadDungeonDiagnostics(frame, "UPDATE_BEGIN", inRestricted)

    if not IsEnabled() then
        MarkStep("UPDATE_DISABLED")
        DeactivateHazard(condBorder)
        condBorder._muiSecretOverlayIID = nil
        condBorder._muiSecretOverlayR = nil
        condBorder._muiSecretOverlayG = nil
        condBorder._muiSecretOverlayB = nil
        condBorder._muiSecretOverlayA = nil
        condBorder._muiSecretOverlayLogKey = nil
        condBorder._muiStickyPrimaryEnum = nil
        condBorder._muiLastOverlapLogKey = nil
        HideSecondaryTypeBox(condBorder, "DISABLED")
        SyncPlayerFrameBarTint(false, nil, nil, nil, "DISABLED")
        SetExtraShimmerState(condBorder, false)
        _lastCondBorderType = nil
        _lastCondBorderIID  = nil
        _lastCondBorderPrimaryEnum = nil
        _lastCondBorderAccentType = nil
        _lastCondBorderExtraType = nil
        _lastCondBorderDetectedAt = 0
        _lastCondBorderOverlapSignature = "none"
        _lastCondBorderOverlapPrimaryEnum = nil
        _lastCondBorderOverlapSecondaryEnum = nil
        _lastCondBorderBleedCurveIID = nil
        _lastCondBorderBleedCurveCandidates = 0
        _lastCondBorderAuraEnumLogKey = nil
        _lastCondBorderActiveCollectLogKey = nil
        _lastCondBorderSecondaryCandidateLogKey = nil
        _lastCondBorderSecretActivateLogKey = nil
        _lastCondBorderSecretOverlayFillLogKey = nil
        RefreshDispelTrackingOverlay(frame, inRestricted, true)
        return
    end

    RefreshDispelTrackingOverlay(frame, inRestricted, false)

    -- Keep the non-typed IID cache fresh while outside combat so it's
    -- ready the moment combat starts.
    if not inRestricted then
        RefreshPrecombatNonTypedCache("player")
    end

    MarkStep("HOOK_ENSURE")
    EnsureBlizzHook()

    -- ---- Step 1: Typed debuffs (Poison / Magic / Curse / Disease) -----------
    local curve = GetCondBorderCurve()
    if curve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
        MarkStep("STEP1_TYPED_BEGIN")

        -- Source A: Blizzard hook cache (group content)
        local playerEntry = _blizzDispelCache["player"]
        local hookSet = nil
        if playerEntry then
            if playerEntry.debuffs and next(playerEntry.debuffs) then
                hookSet = playerEntry.debuffs
            elseif playerEntry.dispellable and next(playerEntry.dispellable) then
                hookSet = playerEntry.dispellable
            end
        end
        if hookSet then
            MarkStep("STEP1A_HOOK_SCAN")
            local fallbackIID, fallbackColor, fallbackPrimary = nil, nil, nil
            for iid in pairs(hookSet) do
                if ShouldIgnoreLockoutDebuffByIID("player", iid, inRestricted) then
                    MarkStep("STEP1A_HOOK_SKIP_LOCKOUT", "iid=" .. SafeToString(iid))
                else
                    local borderColor = C_UnitAuras.GetAuraDispelTypeColor("player", iid, curve)
                    if borderColor then
                        local primaryEnum = ResolveHazardEnumForAuraID("player", iid, inRestricted)
                        if IsTrackedHazardEnum(primaryEnum) then
                            MarkStep("STEP1A_HOOK_MATCH")
                            ActivateHazardSecret(condBorder, borderColor, iid, primaryEnum)
                            ApplySecondaryShimmerStateSafe(condBorder, primaryEnum, inRestricted, "STEP1A_ACCENT", iid)
                            _lastCondBorderType = "TYPED_DEBUFF_HOOK"
                            _lastCondBorderIID  = iid
                            _lastCondBorderPrimaryEnum = primaryEnum
                            MarkStep("STEP1A_HOOK_DONE")
                            return
                        end

                        if not fallbackIID and not IsKnownNonTypedIID(iid) then
                            fallbackIID = iid
                            fallbackColor = borderColor
                            fallbackPrimary = primaryEnum
                        end
                        MarkStep("STEP1A_HOOK_SKIP_UNTRACKED", "iid=" .. SafeToString(iid))
                    end
                end
            end
            if fallbackIID then
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    local activePrimary = GetPrimaryHazardEnumFromActive(CollectActiveHazardTypes("player", inRestricted))
                    if IsTrackedHazardEnum(activePrimary) then
                        fallbackPrimary = activePrimary
                        MarkStep("STEP1A_HOOK_ACTIVE_PRIMARY", HAZARD_LABEL_BY_ENUM[fallbackPrimary])
                    end
                end
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    if not inRestricted then
                        local legacyActive = CollectActiveHazardTypesLegacy("player")
                        fallbackPrimary = GetPrimaryHazardEnumFromActive(legacyActive)
                        if IsTrackedHazardEnum(fallbackPrimary) then
                            MarkStep("STEP1A_HOOK_LEGACY_PRIMARY", HAZARD_LABEL_BY_ENUM[fallbackPrimary])
                        end
                    end
                end
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    if inRestricted and fallbackColor and not IsKnownNonTypedIID(fallbackIID) then
                        -- In combat, aura fields are secret but the border color curve
                        -- confirmed this IS a typed debuff. Activate with the secret color.
                        MarkStep("STEP1A_HOOK_COMBAT_ACTIVATE")
                        ActivateHazardSecret(condBorder, fallbackColor, fallbackIID, fallbackPrimary)
                        ApplySecondaryShimmerStateSafe(condBorder, fallbackPrimary, inRestricted, "STEP1A_COMBAT_ACCENT", fallbackIID)
                        _lastCondBorderType = "TYPED_DEBUFF_HOOK_COMBAT"
                        _lastCondBorderIID  = fallbackIID
                        _lastCondBorderPrimaryEnum = fallbackPrimary
                        MarkStep("STEP1A_HOOK_COMBAT_DONE")
                        return
                    end
                    MarkStep("STEP1A_HOOK_SKIP_UNTYPED")
                else
                    MarkStep("STEP1A_HOOK_FALLBACK")
                    ActivateHazardSecret(condBorder, fallbackColor, fallbackIID, fallbackPrimary)
                    ApplySecondaryShimmerStateSafe(condBorder, fallbackPrimary, inRestricted, "STEP1A_ACCENT", fallbackIID)
                    _lastCondBorderType = "TYPED_DEBUFF_HOOK"
                    _lastCondBorderIID  = fallbackIID
                    _lastCondBorderPrimaryEnum = fallbackPrimary
                    MarkStep("STEP1A_HOOK_DONE")
                    return
                end
            end
        end

        -- Source B: Direct scan (solo / hook cold-start)
        if C_UnitAuras.GetAuraDataByIndex then
            MarkStep("STEP1B_DIRECT_SCAN")
            local fallbackIID, fallbackColor, fallbackPrimary = nil, nil, nil
            for i = 1, 40 do
                local aura
                if inRestricted then
                    local ok, result = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HARMFUL")
                    if not ok then
                        MarkError("STEP1B_SCAN_COMBAT", result)
                        break
                    end
                    aura = result
                else
                    aura = C_UnitAuras.GetAuraDataByIndex("player", i, "HARMFUL")
                end
                if not aura then break end
                if ShouldIgnoreLockoutDebuffAura(aura) then
                    MarkStep("STEP1B_SCAN_SKIP_LOCKOUT", "idx=" .. SafeToString(i))
                else
                    local iid = aura.auraInstanceID
                    if iid then
                        local borderColor = C_UnitAuras.GetAuraDispelTypeColor("player", iid, curve)
                        if borderColor then
                            local primaryEnum = ResolveHazardEnumForAuraID("player", iid, inRestricted)
                            if IsTrackedHazardEnum(primaryEnum) then
                                MarkStep("STEP1B_SCAN_MATCH")
                                ActivateHazardSecret(condBorder, borderColor, iid, primaryEnum)
                                ApplySecondaryShimmerStateSafe(condBorder, primaryEnum, inRestricted, "STEP1B_ACCENT", iid)
                                _lastCondBorderType = "TYPED_DEBUFF_SCAN"
                                _lastCondBorderIID  = iid
                                _lastCondBorderPrimaryEnum = primaryEnum
                                MarkStep("STEP1B_SCAN_DONE")
                                return
                            end

                            if not fallbackIID and not IsKnownNonTypedIID(iid) then
                                fallbackIID = iid
                                fallbackColor = borderColor
                                fallbackPrimary = primaryEnum
                            end
                            MarkStep("STEP1B_SCAN_SKIP_UNTRACKED", "iid=" .. SafeToString(iid))
                        end
                    end
                end
            end
            if fallbackIID then
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    local activePrimary = GetPrimaryHazardEnumFromActive(CollectActiveHazardTypes("player", inRestricted))
                    if IsTrackedHazardEnum(activePrimary) then
                        fallbackPrimary = activePrimary
                        MarkStep("STEP1B_SCAN_ACTIVE_PRIMARY", HAZARD_LABEL_BY_ENUM[fallbackPrimary])
                    end
                end
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    if not inRestricted then
                        local legacyActive = CollectActiveHazardTypesLegacy("player")
                        fallbackPrimary = GetPrimaryHazardEnumFromActive(legacyActive)
                        if IsTrackedHazardEnum(fallbackPrimary) then
                            MarkStep("STEP1B_SCAN_LEGACY_PRIMARY", HAZARD_LABEL_BY_ENUM[fallbackPrimary])
                        end
                    end
                end
                if not IsTrackedHazardEnum(fallbackPrimary) then
                    if inRestricted and fallbackColor and not IsKnownNonTypedIID(fallbackIID) then
                        -- In combat, aura fields are secret but the border color curve
                        -- confirmed this IS a typed debuff. Activate with the secret color.
                        MarkStep("STEP1B_SCAN_COMBAT_ACTIVATE")
                        ActivateHazardSecret(condBorder, fallbackColor, fallbackIID, fallbackPrimary)
                        ApplySecondaryShimmerStateSafe(condBorder, fallbackPrimary, inRestricted, "STEP1B_COMBAT_ACCENT", fallbackIID)
                        _lastCondBorderType = "TYPED_DEBUFF_SCAN_COMBAT"
                        _lastCondBorderIID  = fallbackIID
                        _lastCondBorderPrimaryEnum = fallbackPrimary
                        MarkStep("STEP1B_SCAN_COMBAT_DONE")
                        return
                    end
                    MarkStep("STEP1B_SCAN_SKIP_UNTYPED")
                else
                    MarkStep("STEP1B_SCAN_FALLBACK")
                    ActivateHazardSecret(condBorder, fallbackColor, fallbackIID, fallbackPrimary)
                    ApplySecondaryShimmerStateSafe(condBorder, fallbackPrimary, inRestricted, "STEP1B_ACCENT", fallbackIID)
                    _lastCondBorderType = "TYPED_DEBUFF_SCAN"
                    _lastCondBorderIID  = fallbackIID
                    _lastCondBorderPrimaryEnum = fallbackPrimary
                    MarkStep("STEP1B_SCAN_DONE")
                    return
                end
            end
        end
    else
        MarkStep("STEP1_TYPED_UNAVAILABLE")
    end

    -- ---- Step 2: Bleeds (dispelType 11) - invisible to GetAuraDispelTypeColor
    local c = COND_BORDER_COLORS.Bleed
    MarkStep("STEP2_BLEED_BEGIN", inRestricted and "COMBAT" or "NORMAL")

    if not inRestricted then
        local bleedIID, bleedDT = ScanForBleedAuraID("player", false)
        if bleedIID then
            MarkStep("STEP2_BLEED_MATCH")
            ActivateHazardRGB(condBorder, c[1], c[2], c[3], DISPEL_ENUM.Bleed)
            ApplySecondaryShimmerStateSafe(condBorder, DISPEL_ENUM.Bleed, inRestricted, "STEP2_ACCENT", bleedIID)
            _lastCondBorderType = (bleedDT == DISPEL_ENUM.Enrage) and "ENRAGE" or "BLEED"
            _lastCondBorderIID  = bleedIID
            _lastCondBorderPrimaryEnum = DISPEL_ENUM.Bleed
            MarkStep("STEP2_BLEED_DONE")
            return
        end
    else
        if TrackerSaysBleedActive() then
            MarkStep("STEP2_TRACKER_MATCH")
            ActivateHazardRGB(condBorder, c[1], c[2], c[3], DISPEL_ENUM.Bleed)
            ApplySecondaryShimmerStateSafe(condBorder, DISPEL_ENUM.Bleed, inRestricted, "STEP2_TRACKER_ACCENT", nil)
            _lastCondBorderType = "BLEED_TRACKER"
            _lastCondBorderIID  = nil
            _lastCondBorderPrimaryEnum = DISPEL_ENUM.Bleed
            MarkStep("STEP2_TRACKER_DONE")
            return
        end
        local ok, bleedIID, bleedDT = pcall(ScanForBleedAuraID, "player", true)
        if ok and bleedIID then
            MarkStep("STEP2_COMBAT_SCAN_MATCH")
            ActivateHazardRGB(condBorder, c[1], c[2], c[3], DISPEL_ENUM.Bleed)
            ApplySecondaryShimmerStateSafe(condBorder, DISPEL_ENUM.Bleed, inRestricted, "STEP2_COMBAT_ACCENT", bleedIID)
            _lastCondBorderType = "BLEED_DIRECT_COMBAT"
            _lastCondBorderIID  = bleedIID
            _lastCondBorderPrimaryEnum = DISPEL_ENUM.Bleed
            MarkStep("STEP2_COMBAT_SCAN_DONE")
            return
        elseif not ok then
            MarkError("STEP2_COMBAT_SCAN_ERROR", bleedIID)
        end
    end

    -- ---- Step 3: Nothing active - fade out and sleep (with short grace to avoid flicker).
    local now = GetDebugNow()
    if _condBorderActive and now > 0 and _lastCondBorderDetectedAt > 0 and (now - _lastCondBorderDetectedAt) < DEACTIVATE_GRACE_SEC then
        MarkStep("STEP3_GRACE_HOLD")
        return
    end
    MarkStep("STEP3_DEACTIVATE")
    DeactivateHazard(condBorder)
    _lastCondBorderType = nil
    _lastCondBorderIID  = nil
    _lastCondBorderPrimaryEnum = nil
    _lastCondBorderAccentType = nil
    _lastCondBorderExtraType = nil
    _lastCondBorderDetectedAt = 0
    _lastCondBorderOverlapSignature = "none"
    _lastCondBorderOverlapPrimaryEnum = nil
    _lastCondBorderOverlapSecondaryEnum = nil
    _lastCondBorderBleedCurveIID = nil
    _lastCondBorderBleedCurveCandidates = 0
    _lastCondBorderAuraEnumLogKey = nil
    _lastCondBorderActiveCollectLogKey = nil
    _lastCondBorderSecondaryCandidateLogKey = nil
    _lastCondBorderSecretActivateLogKey = nil
    _lastCondBorderSecretOverlayFillLogKey = nil
end

-- =========================================================================
--  INITIALISE
-- =========================================================================

function M.Init(frame)
    _playerFrame = frame
    EnsureCombatSettingsTable()
    RegisterDispelTrackingOverlaySettings()
    local locked = true
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
        locked = MidnightUISettings.Messenger.locked ~= false
    end
    M.SetDispelTrackingLocked(locked)
    local inInstance, instanceType = GetInstanceContext()
    if not (inInstance and IsDungeonInstanceType(instanceType)) then
        return
    end
    local frameReady = (frame and frame.conditionBorder) and "YES" or "NO"
    local sweepReady = (_secondaryDebuffBox and _secondaryDebuffBox.frame) and "YES" or "NO"
    CondBorderReloadLog("phase=INIT frameReady=" .. frameReady .. " secondarySweepReady=" .. sweepReady)
end

-- =========================================================================
--  DIAGNOSTICS
-- =========================================================================

function M.GetDiagLines(frame)
    local hookOK     = _blizzHookRegistered and "YES" or "NO"
    local curveOK    = (_condBorderCurve ~= nil) and "YES" or "NO"
    local debuffCount, dispelCount, typedCount = 0, 0, 0
    local typedEnums = {}
    local pe = _blizzDispelCache["player"]
    if pe then
        if pe.debuffs     then for _ in pairs(pe.debuffs)     do debuffCount = debuffCount + 1 end end
        if pe.dispellable then for _ in pairs(pe.dispellable) do dispelCount = dispelCount + 1 end end
        if pe.types then
            for _, dt in pairs(pe.types) do
                typedCount = typedCount + 1
                if IsTrackedHazardEnum(dt) then
                    typedEnums[dt] = true
                end
            end
        end
    end
    local trackerBleed = TrackerSaysBleedActive() and "YES" or "NO"
    local borderVis = _condBorderActive and "VISIBLE" or "HIDDEN"
    local inRestricted = (InCombatLockdown and InCombatLockdown()) and "YES" or "NO"
    local enabled = IsEnabled() and "YES" or "NO"
    local typeBoxShown = "NO"
    if _secondaryDebuffBox and _secondaryDebuffBox.frame and _secondaryDebuffBox.frame.IsShown then
        typeBoxShown = _secondaryDebuffBox.frame:IsShown() and "YES" or "NO"
    end
    return {
        "[MUI CondBorder Diag]",
        "  enabled        = " .. enabled,
        "  hookRegistered = " .. hookOK,
        "  curveBuilt     = " .. curveOK,
        "  cachedDebuffs  = " .. debuffCount,
        "  cachedDispel   = " .. dispelCount,
        "  cachedTypes    = " .. typedCount,
        "  hookTypes      = " .. BuildActiveHazardSignature(typedEnums),
        "  inRestricted   = " .. inRestricted,
        "  trackerBleed   = " .. trackerBleed,
        "  borderState    = " .. borderVis,
        "  lastType       = " .. SafeToString(_lastCondBorderType),
        "  lastIID        = " .. SafeToString(_lastCondBorderIID),
        "  primaryEnum    = " .. SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderPrimaryEnum] or _lastCondBorderPrimaryEnum),
        "  accentType     = " .. SafeToString(_lastCondBorderAccentType),
        "  pulseMode      = " .. SafeToString(_lastCondBorderExtraType),
        "  overlapSig     = " .. SafeToString(_lastCondBorderOverlapSignature),
        "  overlapPrimary = " .. SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderOverlapPrimaryEnum] or _lastCondBorderOverlapPrimaryEnum),
        "  overlapSecond  = " .. SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderOverlapSecondaryEnum] or _lastCondBorderOverlapSecondaryEnum),
        "  typeBoxState   = " .. SafeToString(_lastCondBorderTypeBoxState),
        "  typeBoxEnum    = " .. SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderTypeBoxEnum] or _lastCondBorderTypeBoxEnum),
        "  typeBoxRGB     = " .. SafeToString(_lastCondBorderTypeBoxRGB),
        "  typeBoxShown   = " .. typeBoxShown,
        "  bleedCurveIID  = " .. SafeToString(_lastCondBorderBleedCurveIID),
        "  bleedCurveIDs  = " .. SafeToString(_lastCondBorderBleedCurveCandidates),
        "  barTint        = " .. SafeToString(_lastCondBorderBarTint),
        "  barTintEnum    = " .. SafeToString(HAZARD_LABEL_BY_ENUM[_lastCondBorderBarTintEnum] or _lastCondBorderBarTintEnum),
        "  barTintRGB     = " .. SafeToString(_lastCondBorderBarTintRGB),
        "  updateSeq      = " .. SafeToString(_lastCondBorderUpdateSeq),
        "  reloadDiagSess = " .. SafeToString(_reloadDungeonDiagSession),
        "  reloadDiagKey  = " .. SafeToString(_reloadDungeonDiagActiveKey),
        "  reloadDiagLast = " .. SafeToString(_reloadDungeonDiagLastPhase),
        "  reloadDiagInfo = " .. SafeToString(_reloadDungeonDiagLastSummary),
        "  lastStep       = " .. SafeToString(_lastCondBorderStep),
        "  stepDetail     = " .. SafeToString(_lastCondBorderStepDetail),
        "  errorCount     = " .. SafeToString(_lastCondBorderErrorCount),
        "  lastError      = " .. SafeToString(_lastCondBorderError),
        "  trackerMethod  = " .. SafeToString(_lastCondBorderTrackerBleedMethod),
    }
end

function M.GetStateSnapshot()
    local frame = _playerFrame or _G.MidnightUI_PlayerFrame
    local tintActive = false
    local tintSource = nil
    local tintHasColor = false
    local tintSecret = false
    local tintRGB = nil
    if frame then
        tintActive = (frame._muiCondTintActive == true)
        tintSource = frame._muiCondTintSource
        tintHasColor = (frame._muiCondTintHasColor == true)
        tintSecret = (frame._muiCondTintSecret == true)
        if tintSecret then
            tintRGB = "secret"
        else
            local tr, tg, tb = frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB
            if not IsSecretValue(tr) and not IsSecretValue(tg) and not IsSecretValue(tb) then
                local rn, gn, bn = tonumber(tr), tonumber(tg), tonumber(tb)
                if rn and gn and bn then
                    tintRGB = string.format("%.3f,%.3f,%.3f", rn, gn, bn)
                end
            end
        end
    end

    local inRestricted = GetRestrictionState()

    local hookActive = {}
    local hookPrimaryEnum = nil
    local hookSecondaryEnum = nil
    local hookSignature = "none"
    do
        local entry = _blizzDispelCache["player"]
        if entry and entry.types then
            for _, dt in pairs(entry.types) do
                if IsTrackedHazardEnum(dt) then
                    hookActive[dt] = true
                end
            end
        end
        hookSignature = BuildActiveHazardSignature(hookActive)
        hookPrimaryEnum = GetPrimaryHazardEnumFromActive(hookActive)
        hookSecondaryEnum = PickSecondaryHazards(hookActive, hookPrimaryEnum)
    end

    local trackerBleed = TrackerSaysBleedActive() == true

    local curvePrimaryEnum = nil
    local needCurveResolve = (not IsTrackedHazardEnum(_lastCondBorderPrimaryEnum))
        and (not IsTrackedHazardEnum(_lastCondBorderOverlapPrimaryEnum))
        and (not IsTrackedHazardEnum(hookPrimaryEnum))
    if needCurveResolve and _lastCondBorderIID then
        local okCurve, resolved = pcall(ResolveHazardEnumForAuraID, "player", _lastCondBorderIID, inRestricted)
        if okCurve and IsTrackedHazardEnum(resolved) then
            curvePrimaryEnum = resolved
        end
    end

    local activeHazards = {}
    for enum in pairs(hookActive) do
        activeHazards[enum] = true
    end
    if IsTrackedHazardEnum(_lastCondBorderPrimaryEnum) then
        activeHazards[_lastCondBorderPrimaryEnum] = true
    end
    if IsTrackedHazardEnum(_lastCondBorderOverlapPrimaryEnum) then
        activeHazards[_lastCondBorderOverlapPrimaryEnum] = true
    end
    if IsTrackedHazardEnum(_lastCondBorderOverlapSecondaryEnum) then
        activeHazards[_lastCondBorderOverlapSecondaryEnum] = true
    end
    if IsTrackedHazardEnum(curvePrimaryEnum) then
        activeHazards[curvePrimaryEnum] = true
    end
    if trackerBleed then
        activeHazards[DISPEL_ENUM.Bleed] = true
    end
    local activeSignature = BuildActiveHazardSignature(activeHazards)
    local activePrimaryEnum = GetPrimaryHazardEnumFromActive(activeHazards)
    local activeSecondaryEnum = PickSecondaryHazards(activeHazards, activePrimaryEnum)

    return {
        active = (_condBorderActive == true) or tintActive,
        inRestricted = inRestricted,
        primaryEnum = _lastCondBorderPrimaryEnum,
        primaryLabel = HAZARD_LABEL_BY_ENUM[_lastCondBorderPrimaryEnum],
        barTint = _lastCondBorderBarTint,
        barTintEnum = _lastCondBorderBarTintEnum,
        barTintRGB = _lastCondBorderBarTintRGB,
        lastType = _lastCondBorderType,
        lastIID = _lastCondBorderIID,
        curvePrimaryEnum = curvePrimaryEnum,
        overlapPrimaryEnum = _lastCondBorderOverlapPrimaryEnum,
        overlapSecondaryEnum = _lastCondBorderOverlapSecondaryEnum,
        hookSignature = hookSignature,
        hookPrimaryEnum = hookPrimaryEnum,
        hookSecondaryEnum = hookSecondaryEnum,
        activeSignature = activeSignature,
        activePrimaryEnum = activePrimaryEnum,
        activeSecondaryEnum = activeSecondaryEnum,
        trackerBleed = trackerBleed,
        typeBoxState = _lastCondBorderTypeBoxState,
        typeBoxEnum = _lastCondBorderTypeBoxEnum,
        typeBoxRGB = _lastCondBorderTypeBoxRGB,
        typeBoxR = _lastCondBorderTypeBoxR,
        typeBoxG = _lastCondBorderTypeBoxG,
        typeBoxB = _lastCondBorderTypeBoxB,
        typeBoxShown = (_secondaryDebuffBoxVisible == true),
        tintActive = tintActive,
        tintSource = tintSource,
        tintHasColor = tintHasColor,
        tintSecret = tintSecret,
        tintRGB = tintRGB,
    }
end

function M.ShouldIgnoreLockoutDebuff(aura)
    return ShouldIgnoreLockoutDebuffAura(aura)
end

_G.MidnightUI_SetDispelTrackingLocked = function(locked)
    if _G.MidnightUI_ConditionBorder and _G.MidnightUI_ConditionBorder.SetDispelTrackingLocked then
        _G.MidnightUI_ConditionBorder.SetDispelTrackingLocked(locked)
    end
end

_G.MidnightUI_RefreshDispelTrackingOverlay = function(frame)
    if _G.MidnightUI_ConditionBorder and _G.MidnightUI_ConditionBorder.RefreshDispelTracking then
        _G.MidnightUI_ConditionBorder.RefreshDispelTracking(frame)
    end
end
