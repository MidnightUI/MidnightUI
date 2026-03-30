-- =============================================================================
-- FILE PURPOSE:     Custom focus unit frame. Replaces Blizzard's FocusFrame.
--                   Shows health/power bars with debuff-type hazard tint (FOCUS_HAZARD_ENUM),
--                   a mini debuff preview strip, reaction-colored health, and a sticky
--                   hazard color that lingers for FOCUS_HAZARD_STICKY_SEC after the debuff expires.
-- LOAD ORDER:       Loads after ConditionBorder.lua. FocusFrameManager handles ADDON_LOADED
--                   and PLAYER_FOCUS_CHANGED to build/update the frame.
-- DEFINES:          FocusFrameManager (event frame), focusFrame (_G.MidnightUI_FocusFrame).
--                   Global refresh: MidnightUI_ApplyFocusSettings().
-- READS:            MidnightUISettings.FocusFrame.{enabled, width, height, scale, alpha, position}.
--                   MidnightUISettings.Combat.{debuffOverlayGlobalEnabled, debuffOverlayFocusEnabled}.
--                   MidnightUISettings.General.allowSecretHealthPercent.
-- WRITES:           MidnightUISettings.FocusFrame.position (on drag stop).
--                   Blizzard FocusFrame: SetAlpha(0), deferred EnableMouse(false).
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (player-class focus health bar coloring).
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua).
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua, CastBar.lua (focus cast bar hookup).
-- KEY FLOWS:
--   PLAYER_FOCUS_CHANGED → UpdateAll(frame) — rebuilds on new focus target
--   UNIT_AURA focus → hazard probe cycle: sample aura colors, map to FOCUS_HAZARD_ENUM,
--                     apply health bar tint + debuff preview icons
--   UNIT_HEALTH focus → UpdateHealth(frame)
-- GOTCHAS:
--   Hazard detection uses a probe-curve system (_focusHazardProbeCurves) that samples
--   aura border colors via ColorProbe textures before and after each aura update,
--   matching against known debuff-type RGB signatures within FOCUS_HAZARD_CURVE_EPSILON.
--   This is required because aura.dispelType is a secret value in combat.
--   FOCUS_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS / NAMES: Bloodlust-family exhaustion and
--   Last Resort debuffs must never drive the tint or they permanently color the bar.
--   FOCUS_HAZARD_STICKY_SEC (8s): hazard color lingers after debuff falls off so the
--   healer still sees it in the brief window before re-application.
--   AllowSecretHealthPercent() is opt-in — disabled by default to avoid taint risk.
-- NAVIGATION:
--   FOCUS_HAZARD_ENUM / COLORS / PRIORITY  — dispel type definitions (line ~70)
--   FOCUS_IGNORED_LOCKOUT_DEBUFF_*         — IDs and names that skip tint (line ~122)
--   IsFocusDebuffOverlayEnabled()          — checks both global + focus-specific toggle
--   BuildFocusFrame()                      — constructs all sub-frames
--   UpdateHazardTint(frame)                — applies/clears hazard color on health bar
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local FocusFrameManager = CreateFrame("Frame")
local focusFrame
local pendingFocusFrameLock = nil
local pendingBlizzardFocusMouseDisable = false

local function SoftHideBlizzardFocusFrame(frame)
    if not frame then return end
    frame:SetAlpha(0)
    if InCombatLockdown and InCombatLockdown() then
        pendingBlizzardFocusMouseDisable = true
        return
    end
    if frame.EnableMouse then
        frame:EnableMouse(false)
    end
    pendingBlizzardFocusMouseDisable = false
end

-- =========================================================================
--  CONSTANTS & COLORS
-- =========================================================================


local POWER_COLORS = {
    ["MANA"] = {0.00, 0.50, 1.00}, ["RAGE"] = {0.90, 0.10, 0.10}, ["FOCUS"] = {1.00, 0.50, 0.25},
    ["ENERGY"] = {1.00, 1.00, 0.35}, ["COMBO_POINTS"] = {1.00, 0.96, 0.41}, ["RUNES"] = {0.50, 0.50, 0.50},
    ["RUNIC_POWER"] = {0.00, 0.82, 1.00}, ["SOUL_SHARDS"] = {0.50, 0.32, 0.55}, ["LUNAR_POWER"] = {0.30, 0.52, 0.90},
    ["HOLY_POWER"] = {0.95, 0.90, 0.60}, ["MAELSTROM"] = {0.00, 0.50, 1.00}, ["CHI"] = {0.71, 1.00, 0.92},
    ["INSANITY"] = {0.40, 0.00, 0.80}, ["ARCANE_CHARGES"] = {0.10, 0.10, 0.98}, ["FURY"] = {0.79, 0.26, 0.99},
    ["PAIN"] = {1.00, 0.61, 0.00}, ["ESSENCE"] = {0.20, 0.88, 0.66},
}
local DEFAULT_UNIT_COLOR_R, DEFAULT_UNIT_COLOR_G, DEFAULT_UNIT_COLOR_B = 0.5, 0.5, 0.5
local DEFAULT_HOSTILE_COLOR_R, DEFAULT_HOSTILE_COLOR_G, DEFAULT_HOSTILE_COLOR_B = 0.9, 0.1, 0.1
local DEFAULT_POWER_COLOR = {0.0, 0.5, 1.0}
local DEAD_STATUS_ATLAS = "icons_64x64_deadly"

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

local REACTION_COLORS = {
    [1] = {0.9, 0.1, 0.1}, [2] = {0.9, 0.1, 0.1}, [3] = {0.9, 0.1, 0.1},
    [4] = {1.0, 1.0, 0.0}, [5] = {0.1, 0.9, 0.1}, [6] = {0.1, 0.9, 0.1},
    [7] = {0.1, 0.9, 0.1}, [8] = {0.1, 0.9, 0.1},
}

local config = {
    width = 320, height = 58, spacing = 1,
    position = {"CENTER", "UIParent", "CENTER", 32.171521, -496.92577},
}

local FOCUS_HAZARD_ENUM = {
    None = 0,
    Magic = 1,
    Curse = 2,
    Disease = 3,
    Poison = 4,
    Enrage = 9,
    Bleed = 11,
    Unknown = 99,
}
local FOCUS_HAZARD_LABELS = {
    [FOCUS_HAZARD_ENUM.None] = "NONE",
    [FOCUS_HAZARD_ENUM.Magic] = "MAGIC",
    [FOCUS_HAZARD_ENUM.Curse] = "CURSE",
    [FOCUS_HAZARD_ENUM.Disease] = "DISEASE",
    [FOCUS_HAZARD_ENUM.Poison] = "POISON",
    [FOCUS_HAZARD_ENUM.Bleed] = "BLEED",
    [FOCUS_HAZARD_ENUM.Unknown] = "UNKNOWN",
}
local FOCUS_HAZARD_COLORS = {
    [FOCUS_HAZARD_ENUM.Magic] = { 0.15, 0.55, 0.95 },
    [FOCUS_HAZARD_ENUM.Curse] = { 0.70, 0.20, 0.95 },
    [FOCUS_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [FOCUS_HAZARD_ENUM.Poison] = { 0.15, 0.65, 0.20 },
    [FOCUS_HAZARD_ENUM.Bleed] = { 0.95, 0.15, 0.15 },
    [FOCUS_HAZARD_ENUM.Unknown] = { 0.64, 0.19, 0.79 },
}
local FOCUS_HAZARD_PRIORITY = {
    FOCUS_HAZARD_ENUM.Magic,
    FOCUS_HAZARD_ENUM.Curse,
    FOCUS_HAZARD_ENUM.Disease,
    FOCUS_HAZARD_ENUM.Poison,
    FOCUS_HAZARD_ENUM.Bleed,
}
local FOCUS_HAZARD_CURVE_EPSILON = 0.02
local _focusHazardProbeCurves = {}
local _focusHazardProbeMatchColors = {}
local _focusHazardZeroProbeCurve
local _focusBlizzAuraCache = {}
local _focusBlizzHookRegistered = false
local _focusPrecombatNonTypedIIDs = {}
-- Keep debuff tint at full strength so focus bars visibly switch to the debuff color
-- instead of appearing as a mostly dark mask.
local FOCUS_DEBUFF_TINT_BASE_MUL = 1.00
local FOCUS_HAZARD_STICKY_SEC = 8
local FOCUS_DEBUFF_PREVIEW = {
    iconSize = 16,
    maxIcons = 2,
    offsetY = 0,
    placeholderIcon = 134400,
}

local FOCUS_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS = {
    [57723] = true,  -- Exhaustion
    [57724] = true,  -- Sated
    [80354] = true,  -- Temporal Displacement
    [95809] = true,  -- Insanity
    [264689] = true, -- Fatigued
    [209258] = true, -- Last Resort
    [209261] = true, -- Last Resort (cooldown lockout variant)
}

local FOCUS_IGNORED_LOCKOUT_DEBUFF_NAMES = {
    ["exhaustion"] = true,
    ["sated"] = true,
    ["temporal displacement"] = true,
    ["insanity"] = true,
    ["fatigued"] = true,
    ["last resort"] = true,
}

-- =========================================================================
--  HELPER FUNCTIONS
-- =========================================================================

local function GetUnitColor(unit)
    if UnitIsPlayer(unit) then
        if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
            local r, g, b = _G.MidnightUI_Core.GetClassColor(unit)
            if type(r) == "number" and type(g) == "number" and type(b) == "number" then
                return r, g, b
            end
        end
        local _, class = UnitClass(unit)
        if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
            local c = RAID_CLASS_COLORS[class]
            if type(c.r) == "number" and type(c.g) == "number" and type(c.b) == "number" then
                return c.r, c.g, c.b
            end
        end
        return DEFAULT_UNIT_COLOR_R, DEFAULT_UNIT_COLOR_G, DEFAULT_UNIT_COLOR_B
    elseif UnitIsTapDenied(unit) then
        return DEFAULT_UNIT_COLOR_R, DEFAULT_UNIT_COLOR_G, DEFAULT_UNIT_COLOR_B
    else
        local reaction = UnitReaction(unit, "player")
        local reactionColor = reaction and REACTION_COLORS[reaction]
        if reactionColor then return reactionColor[1], reactionColor[2], reactionColor[3] end
        return DEFAULT_HOSTILE_COLOR_R, DEFAULT_HOSTILE_COLOR_G, DEFAULT_HOSTILE_COLOR_B
    end
end

local function CreateDropShadow(frame, intensity)
    intensity = intensity or 6
    local shadows = {}
    for i = 1, intensity do
        local shadowLayer = CreateFrame("Frame", nil, frame)
        shadowLayer:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 0.8
        local alpha = (0.18 - (i * 0.025)) * (intensity / 6)
        shadowLayer:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        shadowLayer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        local shadowTex = shadowLayer:CreateTexture(nil, "BACKGROUND")
        shadowTex:SetAllPoints()
        shadowTex:SetColorTexture(0, 0, 0, alpha)
        table.insert(shadows, shadowLayer)
    end
    return shadows
end

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
    return ok
end

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local function EnsureFocusCombatDebuffSettings()
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
    if combat.debuffOverlayFocusEnabled == nil then
        combat.debuffOverlayFocusEnabled = true
    end
    return combat
end

local function IsFocusDebuffOverlayEnabled()
    local combat = EnsureFocusCombatDebuffSettings()
    if combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    if combat.debuffOverlayFocusEnabled == false then
        return false
    end
    return true
end

local lastFocusDebugTime = 0

local function IsFocusDebugEnabled()
    return _G.MidnightUI_Debug
        and MidnightUISettings
        and MidnightUISettings.FocusFrame
        and MidnightUISettings.FocusFrame.debug == true
end

local function FocusSafeToString(value)
    if value == nil then return "nil" end
    if value == false then return "false" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return table.concat({ s }, "") end)
    if not ok2 then return "[Restricted]" end
    return s
end

local function FocusLogDebug(message)
    if not IsFocusDebugEnabled() then return end
    local now = (GetTime and GetTime()) or 0
    if (now - lastFocusDebugTime) < 0.5 then return end
    lastFocusDebugTime = now
    _G.MidnightUI_Debug("[FocusFrame] " .. FocusSafeToString(message))
end

local function IsFocusDiagConsoleEnabled()
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

local function IsFocusDebuffPreviewDiagEnabled()
    if not _G.MidnightUI_Debug then
        return false
    end
    local s = MidnightUISettings
    if not s then
        return false
    end
    -- Keep FocusDebuffPreview diagnostics opt-in only so FocusFrame debug can stay
    -- enabled without flooding the diagnostics console.
    if s.FocusFrame and s.FocusFrame.debuffPreviewDebug == true then
        return true
    end
    return false
end

local function FocusDiag(msg)
    if not IsFocusDebuffPreviewDiagEnabled() then
        return
    end
    local text = FocusSafeToString(msg or "")
    local src = "FocusDebuffPreview"
    if IsFocusDiagConsoleEnabled() then
        pcall(_G.MidnightUI_Diagnostics.LogDebugSource, src, text)
        return
    end
    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. text)
end

local function IsSecretValue(val)
    if type(issecretvalue) ~= "function" then return false end
    local ok, res = pcall(issecretvalue, val)
    return ok and res == true
end

local function CoerceNumber(val)
    local okNum, num = pcall(function() return val + 0 end)
    if okNum and type(num) == "number" then
        return num
    end
    if type(val) == "string" then
        local n = tonumber(val)
        if n then return n end
    end
    return nil
end

local function SafeSetFontStringText(fs, value)
    if not fs then return end
    if value == nil then
        fs:SetText("")
        return
    end
    local okDirect = pcall(fs.SetText, fs, value)
    if okDirect then
        return
    end
    local text = value
    if type(value) ~= "string" then
        local ok, s = pcall(tostring, value)
        text = (ok and s) or ""
    end
    pcall(fs.SetText, fs, text)
end

local function IsUnitActuallyDead(unit)
    if not unit or not UnitExists(unit) then return false end

    local okDeadOrGhost, deadOrGhost = pcall(UnitIsDeadOrGhost, unit)
    if okDeadOrGhost then
        local okState, isDeadOrGhost = pcall(function()
            return deadOrGhost == true
        end)
        if okState and isDeadOrGhost then
            return true
        end
    end

    local okDead, dead = pcall(UnitIsDead, unit)
    if okDead then
        local okIsDead, isDead = pcall(function()
            return dead == true
        end)
        if okIsDead and isDead then
            return true
        end
    end

    local okGhost, ghost = pcall(UnitIsGhost, unit)
    if okGhost then
        local okIsGhost, isGhost = pcall(function()
            return ghost == true
        end)
        if okIsGhost and isGhost then
            return true
        end
    end

    local okCorpse, corpse = pcall(UnitIsCorpse, unit)
    if okCorpse then
        local okIsCorpse, isCorpse = pcall(function()
            return corpse == true
        end)
        if okIsCorpse and isCorpse then
            return true
        end
    end

    local okHp, hp = pcall(UnitHealth, unit)
    if okHp and hp ~= nil then
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

local function GetSafeFallbackPercent(cur, max)
    local okPct, pct = pcall(function()
        return (cur / max) * 100
    end)
    if okPct and type(pct) == "number" then
        return pct
    end
    local curNum = CoerceNumber(cur)
    local maxNum = CoerceNumber(max)
    if type(curNum) == "number" and type(maxNum) == "number" and maxNum > 0 then
        return (curNum / maxNum) * 100
    end
    return nil
end

local function CreateBlackBorder(parent, thickness, alpha)
    thickness = thickness or 1
    alpha = alpha or 1
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(thickness); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT"); border.top:SetColorTexture(0,0,0,alpha)
    border.bottom = border:CreateTexture(nil, "OVERLAY"); border.bottom:SetHeight(thickness); border.bottom:SetPoint("BOTTOMLEFT"); border.bottom:SetPoint("BOTTOMRIGHT"); border.bottom:SetColorTexture(0,0,0,alpha)
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(thickness); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT"); border.left:SetColorTexture(0,0,0,alpha)
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(thickness); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT"); border.right:SetColorTexture(0,0,0,alpha)
    border.innerHighlight = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerHighlight:SetHeight(3)
    border.innerHighlight:SetPoint("TOPLEFT", border.top, "BOTTOMLEFT", thickness, 0)
    border.innerHighlight:SetPoint("TOPRIGHT", border.top, "BOTTOMRIGHT", -thickness, 0)
    border.innerHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerHighlight:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0),
        CreateColor(1, 1, 1, 0.07))
    border.innerShadow = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerShadow:SetHeight(3)
    border.innerShadow:SetPoint("BOTTOMLEFT", border.bottom, "TOPLEFT", thickness, 0)
    border.innerShadow:SetPoint("BOTTOMRIGHT", border.bottom, "TOPRIGHT", -thickness, 0)
    border.innerShadow:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerShadow:SetGradient("VERTICAL",
        CreateColor(0, 0, 0, 0.25),
        CreateColor(0, 0, 0, 0))
    return border
end

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = 13,
            healthFont = "Fonts\\ARIALN.TTF",
            healthSize = 12,
            levelFont = "Fonts\\FRIZQT__.TTF",
            levelSize = 11,
            powerFont = "Fonts\\FRIZQT__.TTF",
            powerSize = 11,
            nameShadowAlpha = 1,
            healthShadowAlpha = 1,
            levelShadowAlpha = 0.9,
            powerShadowAlpha = 0.9,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\ARIALN.TTF", 12, "OUTLINE")
    SetFontSafe(frame.levelText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    SetFontSafe(frame.powerText, "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    frame.nameText:SetShadowOffset(1, -1); frame.nameText:SetShadowColor(0, 0, 0, 1)
    frame.healthText:SetShadowOffset(2, -2); frame.healthText:SetShadowColor(0, 0, 0, 1)
    frame.levelText:SetShadowOffset(1, -1); frame.levelText:SetShadowColor(0, 0, 0, 1)
    frame.powerText:SetShadowOffset(1, -1); frame.powerText:SetShadowColor(0, 0, 0, 0.9)
end

local function ApplyFrameLayout(frame)
    if not frame or not frame.healthContainer or not frame.powerContainer then return end
    local baseHealth = frame._muiBaseHealthHeight or (config.height * 0.64)
    local basePower = frame._muiBasePowerHeight or (config.height * 0.25)
    frame.healthContainer:SetHeight(baseHealth)
    frame.powerContainer:ClearAllPoints()
    frame.powerContainer:SetPoint("TOPLEFT", frame.healthContainer, "BOTTOMLEFT", 0, -config.spacing)
    frame.powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.powerContainer:SetHeight(basePower)
    if frame.powerSep then frame.powerSep:Show() end
    if frame.healthBg then frame.healthBg:SetColorTexture(0.1, 0.1, 0.1, 1) end
    if frame.powerBg then frame.powerBg:SetColorTexture(0, 0, 0, 0.5) end
end

local function GetFocusSettings()
    return (MidnightUISettings and MidnightUISettings.FocusFrame) or {}
end

-- =========================================================================
--  MAIN FOCUS FRAME
-- =========================================================================

local ApplyFocusFrameBarStyle

local function ApplyPolishedGradientToBar(bar, tex, topDarkA, centerLightA, bottomDarkA, forcedBaseR, forcedBaseG, forcedBaseB)
    if not bar then return end
    local anchor = tex or bar
    local baseR, baseG, baseB
    if forcedBaseR ~= nil and forcedBaseG ~= nil and forcedBaseB ~= nil
        and not IsSecretValue(forcedBaseR) and not IsSecretValue(forcedBaseG) and not IsSecretValue(forcedBaseB) then
        baseR, baseG, baseB = forcedBaseR, forcedBaseG, forcedBaseB
    elseif bar.GetStatusBarColor then
        baseR, baseG, baseB = bar:GetStatusBarColor()
    end
    local function CoerceGradientChannel(val, fallback)
        if IsSecretValue(val) then
            return fallback
        end
        local n = CoerceNumber(val)
        if type(n) ~= "number" then
            return fallback
        end
        if n < 0 then n = 0 end
        if n > 1 then n = 1 end
        return n
    end
    baseR = CoerceGradientChannel(baseR, 0.12)
    baseG = CoerceGradientChannel(baseG, 0.85)
    baseB = CoerceGradientChannel(baseB, 0.12)
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
        bar._muiTopHighlight = bar:CreateTexture(nil, "OVERLAY", nil, 2)
    end
    bar._muiTopHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiTopHighlight:SetBlendMode("DISABLE")
    if not bar._muiBottomShade then
        bar._muiBottomShade = bar:CreateTexture(nil, "OVERLAY", nil, 1)
    end
    bar._muiBottomShade:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiBottomShade:SetBlendMode("DISABLE")
    if not bar._muiSpecular then
        bar._muiSpecular = bar:CreateTexture(nil, "OVERLAY", nil, 3)
    end
    bar._muiSpecular:SetTexture("Interface\\Buttons\\WHITE8X8")
    bar._muiSpecular:SetBlendMode("ADD")
    local rawH = (bar.GetHeight and bar:GetHeight()) or 2
    local h = CoerceNumber(rawH)
    if IsSecretValue(rawH) or type(h) ~= "number" then
        h = 2
    end
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

local function CreateFocusFrame()
    local settings = GetFocusSettings()
    local width = settings.width or config.width
    local height = settings.height or config.height
    local healthHeight = height * 0.64
    local powerHeight = height * 0.25

    local frame = CreateFrame("Button", "MidnightUI_FocusFrame", UIParent, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(width, height)
    frame._muiBaseHealthHeight = healthHeight
    frame._muiBasePowerHeight = powerHeight
    frame:SetAttribute("unit", "focus")
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")
    RegisterUnitWatch(frame)

    local savedScale = 1.0
    if settings.scale then savedScale = settings.scale / 100 end
    frame:SetScale(savedScale)

    local pos = settings.position
    if pos and #pos == 4 then
        if pos[5] then frame:SetPoint(pos[1], UIParent, pos[3], pos[4], pos[5])
        else frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) end
    else
        frame:SetPoint(unpack(config.position))
    end

    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetAlpha(settings.alpha or 0.95)

    frame:SetScript("OnEnter", function(self)
        local useCustom = (MidnightUISettings and MidnightUISettings.FocusFrame and MidnightUISettings.FocusFrame.customTooltip ~= false)
        if frame.dragOverlay and frame.dragOverlay:IsShown() and not useCustom then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if UnitExists("focus") then
            GameTooltip:SetUnit("focus")
        elseif useCustom then
            GameTooltip:SetText("Focus Tooltip (Preview)", 1, 0.82, 0)
            GameTooltip:AddLine("No focus set.", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine("This is a preview only.", 0.7, 0.7, 0.7, true)
        else
            return
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

    -- Clean 1px Border & Background
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame:SetBackdropBorderColor(0, 0, 0, 1)

    frame.shadows = CreateDropShadow(frame, 3)

    -- HEALTH
    local healthContainer = CreateFrame("Frame", nil, frame)
    healthContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    healthContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    healthContainer:SetHeight(healthHeight)
    frame.healthContainer = healthContainer

    local healthBg = healthContainer:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints()
    healthBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.healthBg = healthBg
    frame.healthBg = healthBg

    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetPoint("TOPLEFT", 0, 0)
    healthBar:SetPoint("BOTTOMRIGHT", 0, 0)
    healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    healthBar:GetStatusBarTexture():SetHorizTile(false)
    healthBar:SetStatusBarColor(0.5, 0.5, 0.5, 1.0)
    healthBar:SetMinMaxValues(0, 1); healthBar:SetValue(1)
    frame.healthBar = healthBar

    local absorbBar = CreateFrame("StatusBar", nil, healthContainer)
    absorbBar:SetPoint("TOPLEFT", healthBar:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    absorbBar:SetPoint("BOTTOMLEFT", healthBar:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    absorbBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    absorbBar:SetMinMaxValues(0, 1); absorbBar:SetValue(0); absorbBar:Hide()
    frame.absorbBar = absorbBar

    absorbBar.overlay = absorbBar:CreateTexture(nil, "ARTWORK")
    absorbBar.overlay:SetAllPoints(absorbBar:GetStatusBarTexture())
    absorbBar.overlay:SetTexture("Interface\\Buttons\\WHITE8X8")
    absorbBar.overlay:SetBlendMode("DISABLE")
    absorbBar.overlay:SetGradient("VERTICAL", CreateColor(0.5, 0.7, 1.0, 0.8), CreateColor(0.3, 0.5, 0.9, 0.8))

    absorbBar.edgeFade = healthContainer:CreateTexture(nil, "OVERLAY")
    absorbBar.edgeFade:SetPoint("TOPLEFT", absorbBar:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    absorbBar.edgeFade:SetPoint("BOTTOMLEFT", absorbBar:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    absorbBar.edgeFade:SetWidth(15)
    absorbBar.edgeFade:SetTexture("Interface\\Buttons\\WHITE8X8")
    absorbBar.edgeFade:SetBlendMode("DISABLE")
    absorbBar.edgeFade:SetGradient("HORIZONTAL", CreateColor(0.5, 0.7, 1.0, 0.6), CreateColor(0.5, 0.7, 1.0, 0))

    local incomingHeal = CreateFrame("StatusBar", nil, healthContainer)
    incomingHeal:SetPoint("TOPLEFT", healthBar:GetStatusBarTexture(), "TOPRIGHT", 0, 0)
    incomingHeal:SetPoint("BOTTOMLEFT", healthBar:GetStatusBarTexture(), "BOTTOMRIGHT", 0, 0)
    incomingHeal:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    incomingHeal:SetStatusBarColor(0.2, 1.0, 0.3, 0.5)
    incomingHeal:SetMinMaxValues(0, 1); incomingHeal:SetValue(0); incomingHeal:Hide()
    frame.incomingHeal = incomingHeal

    -- TEXT OVERLAY
    local textOverlay = CreateFrame("Frame", nil, healthContainer)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameStrata("MEDIUM")
    textOverlay:SetFrameLevel(healthContainer:GetFrameLevel() + 5)

    local nameText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 13, "OUTLINE")
    nameText:SetPoint("CENTER", textOverlay, "CENTER", 0, 2)
    nameText:SetTextColor(1, 1, 1, 1); nameText:SetShadowOffset(1, -1); nameText:SetShadowColor(0, 0, 0, 1)
    frame.nameText = nameText

    local healthText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(healthText, "Fonts\\ARIALN.TTF", 12, "OUTLINE")
    healthText:SetPoint("RIGHT", textOverlay, "RIGHT", -10, 0)
    healthText:SetTextColor(1, 1, 1, 1); healthText:SetShadowOffset(2, -2); healthText:SetShadowColor(0, 0, 0, 1)
    frame.healthText = healthText

    local levelText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(levelText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    levelText:SetPoint("LEFT", textOverlay, "LEFT", 10, 0)
    levelText:SetTextColor(0.9, 0.9, 0.9, 1)
    frame.levelText = levelText

    local deadIcon = textOverlay:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(32, 32)
    deadIcon:SetPoint("RIGHT", healthContainer, "RIGHT", -28, 0)
    EnsureDeadIconTexture(deadIcon)
    deadIcon:SetVertexColor(1, 1, 1, 1)
    deadIcon:SetDrawLayer("OVERLAY", 7)
    deadIcon:SetAlpha(1)
    deadIcon:Hide()
    frame.deadIcon = deadIcon

    -- POWER
    local powerContainer = CreateFrame("Frame", nil, frame)
    powerContainer:SetPoint("TOPLEFT", healthContainer, "BOTTOMLEFT", 0, -config.spacing)
    powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    powerContainer:SetHeight(powerHeight)
    frame.powerContainer = powerContainer

    -- Power Separator
    local pSep = powerContainer:CreateTexture(nil, "OVERLAY", nil, 7)
    pSep:SetHeight(1); pSep:SetPoint("TOPLEFT"); pSep:SetPoint("TOPRIGHT")
    pSep:SetColorTexture(0, 0, 0, 1)
    frame.powerSep = pSep

    local powerBg = powerContainer:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints(); powerBg:SetColorTexture(0, 0, 0, 0.5)
    frame.powerBg = powerBg

    local powerBar = CreateFrame("StatusBar", nil, powerContainer)
    powerBar:SetPoint("TOPLEFT", 0, 0); powerBar:SetPoint("BOTTOMRIGHT", 0, 0)
    powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    powerBar:GetStatusBarTexture():SetHorizTile(false); powerBar:GetStatusBarTexture():SetVertTile(false)
    powerBar:SetStatusBarColor(0.0, 0.5, 1.0, 1.0)
    powerBar:SetMinMaxValues(0, 100); powerBar:SetValue(0)
    powerBar:SetFrameLevel(powerContainer:GetFrameLevel() + 2)
    frame.powerBar = powerBar

    local powerOverlay = CreateFrame("Frame", nil, powerContainer)
    powerOverlay:SetAllPoints()
    powerOverlay:SetFrameLevel(powerBar:GetFrameLevel() + 10)

    local powerText = powerOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(powerText, "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    powerText:SetPoint("CENTER", powerOverlay, "CENTER", 0, 0)
    powerText:SetTextColor(1, 1, 1, 1); powerText:SetShadowOffset(1, -1); powerText:SetShadowColor(0, 0, 0, 0.9)
    frame.powerText = powerText

    frame:Hide()
    if ApplyFocusFrameBarStyle then ApplyFocusFrameBarStyle() end
    return frame
end

ApplyFocusFrameBarStyle = function()
    local frame = _G.MidnightUI_FocusFrame
    if not frame then return end
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    local isGradient = (style == "Gradient")

    if frame.healthBar then
        frame.healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
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
    end

    if frame.powerBar then
        frame.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
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
    ApplyFrameLayout(frame)
end
_G.MidnightUI_ApplyFocusFrameBarStyle = ApplyFocusFrameBarStyle

-- =========================================================================
--  DEBUFF PREVIEW (FOCUS / RESTRICTED SAFE)
-- =========================================================================

local function CoerceFocusTintChannel(val)
    if IsSecretValue(val) then
        return nil
    end
    local num = CoerceNumber(val)
    if type(num) ~= "number" then
        return nil
    end
    if num < 0 then num = 0 end
    if num > 1 then num = 1 end
    return num
end

local function CloneFocusColor(color)
    if type(color) ~= "table" then
        return nil
    end
    local r, g, b = color[1], color[2], color[3]
    if r == nil or g == nil or b == nil then
        return nil
    end
    local out = { r, g, b }
    if color.secret == true then
        out.secret = true
    end
    return out
end

local function IsFocusSecretColor(color)
    return type(color) == "table" and color.secret == true
end

local function ParseFocusRGBText(text)
    if type(text) ~= "string" then
        return nil, nil, nil
    end
    if IsSecretValue(text) then
        return nil, nil, nil
    end
    local cleaned = string.lower(text)
    if string.find(cleaned, "secret", 1, true) then
        return nil, nil, nil
    end
    local r, g, b = string.match(text, "([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)")
    r = CoerceFocusTintChannel(r)
    g = CoerceFocusTintChannel(g)
    b = CoerceFocusTintChannel(b)
    if r == nil or g == nil or b == nil then
        return nil, nil, nil
    end
    return r, g, b
end

local function NormalizeFocusHazardEnum(value)
    if value == nil then
        return nil
    end
    if IsSecretValue(value) then
        return FOCUS_HAZARD_ENUM.Unknown
    end
    if type(value) == "number" then
        if value == FOCUS_HAZARD_ENUM.Enrage then
            return FOCUS_HAZARD_ENUM.Bleed
        end
        if FOCUS_HAZARD_LABELS[value] then
            return value
        end
        return nil
    end
    if type(value) ~= "string" then
        return nil
    end
    local upper = string.upper(value)
    if upper:find("MAGIC", 1, true) then return FOCUS_HAZARD_ENUM.Magic end
    if upper:find("CURSE", 1, true) then return FOCUS_HAZARD_ENUM.Curse end
    if upper:find("DISEASE", 1, true) then return FOCUS_HAZARD_ENUM.Disease end
    if upper:find("POISON", 1, true) then return FOCUS_HAZARD_ENUM.Poison end
    if upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then
        return FOCUS_HAZARD_ENUM.Bleed
    end
    if upper:find("UNKNOWN", 1, true) or upper:find("SECRET", 1, true) then
        return FOCUS_HAZARD_ENUM.Unknown
    end
    return nil
end

local function ParseFocusHazardLabelText(text)
    if type(text) ~= "string" then
        return nil
    end
    local okUpper, upper = pcall(string.upper, text)
    if not okUpper or type(upper) ~= "string" then
        return nil
    end
    if upper:find("MAGIC", 1, true) then return FOCUS_HAZARD_ENUM.Magic end
    if upper:find("CURSE", 1, true) then return FOCUS_HAZARD_ENUM.Curse end
    if upper:find("DISEASE", 1, true) then return FOCUS_HAZARD_ENUM.Disease end
    if upper:find("POISON", 1, true) then return FOCUS_HAZARD_ENUM.Poison end
    if upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then return FOCUS_HAZARD_ENUM.Bleed end
    if upper:find("UNKNOWN", 1, true) then return FOCUS_HAZARD_ENUM.Unknown end
    return nil
end

local function ParseFocusHazardSignatureText(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local primary, secondary
    for token in text:gmatch("[^%+]+") do
        local enum = ParseFocusHazardLabelText(token)
        if enum then
            if not primary then
                primary = enum
            elseif not secondary and enum ~= primary then
                secondary = enum
                break
            end
        end
    end
    return primary, secondary
end

local function NormalizeFocusTrackerTypeCode(dt)
    local tokenType = type(dt)
    if tokenType == "number" then
        if dt == 1 then return FOCUS_HAZARD_ENUM.Magic end
        if dt == 2 then return FOCUS_HAZARD_ENUM.Curse end
        if dt == 3 then return FOCUS_HAZARD_ENUM.Disease end
        if dt == 4 then return FOCUS_HAZARD_ENUM.Poison end
        if dt == 6 then return FOCUS_HAZARD_ENUM.Bleed end
        if dt == 9 then return FOCUS_HAZARD_ENUM.Bleed end
        if dt == 11 then return FOCUS_HAZARD_ENUM.Bleed end
    elseif tokenType == "string" then
        if IsSecretValue(dt) then
            return nil
        end
        local okLower, lower = pcall(string.lower, dt)
        if not okLower or type(lower) ~= "string" then
            return nil
        end
        if lower == "magic" or lower == "type_magic" then return FOCUS_HAZARD_ENUM.Magic end
        if lower == "curse" or lower == "type_curse" then return FOCUS_HAZARD_ENUM.Curse end
        if lower == "disease" or lower == "type_disease" then return FOCUS_HAZARD_ENUM.Disease end
        if lower == "poison" or lower == "type_poison" then return FOCUS_HAZARD_ENUM.Poison end
        if lower == "bleed" or lower == "enrage" or lower == "type_bleed" or lower == "type_enrage" then
            return FOCUS_HAZARD_ENUM.Bleed
        end
    end
    return NormalizeFocusHazardEnum(dt)
end

local function FocusTruthyBoolOrCount(value)
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

local function FocusTypeTableHasMatch(tbl, typeCode)
    if type(tbl) ~= "table" then
        return false
    end
    local wantedEnum = NormalizeFocusTrackerTypeCode(typeCode)
    for key, direct in pairs(tbl) do
        local keyEnum = NormalizeFocusTrackerTypeCode(key)
        if keyEnum and wantedEnum and keyEnum == wantedEnum then
            local b, used = FocusTruthyBoolOrCount(direct)
            if used then
                return b
            end
            if direct == true then
                return true
            end
        end
    end

    local keys = {
        "MAGIC", "magic", "Magic", "TYPE_MAGIC", "type_magic",
        "CURSE", "curse", "Curse", "TYPE_CURSE", "type_curse",
        "DISEASE", "disease", "Disease", "TYPE_DISEASE", "type_disease",
        "POISON", "poison", "Poison", "TYPE_POISON", "type_poison",
        "BLEED", "bleed", "Bleed", "TYPE_BLEED", "type_bleed",
        "ENRAGE", "enrage", "Enrage", "TYPE_ENRAGE", "type_enrage",
    }
    for _, k in ipairs(keys) do
        local v = tbl[k]
        local b, used = FocusTruthyBoolOrCount(v)
        if used then
            return b
        end
    end

    for key, v in pairs(tbl) do
        local keyEnum = NormalizeFocusTrackerTypeCode(key)
        local valEnum = NormalizeFocusTrackerTypeCode(v)
        if wantedEnum and ((keyEnum and keyEnum == wantedEnum) or (valEnum and valEnum == wantedEnum)) then
            return true
        end
    end
    return false
end

local function FocusTrackerHasTypeActive(unit, typeCode)
    local tracker = _G.MidnightUI_DebuffTracker
    if not tracker then
        return false, "none"
    end

    local lastMethod = "none"
    local function TryMethod(methodName, ...)
        local fn = tracker[methodName]
        if type(fn) ~= "function" then
            return nil
        end
        local ok, result = pcall(fn, tracker, ...)
        if not ok then
            return nil
        end
        local b, used = FocusTruthyBoolOrCount(result)
        if used then
            lastMethod = methodName
            return b
        end
        local wantedEnum = NormalizeFocusTrackerTypeCode(typeCode)
        local resultEnum = NormalizeFocusTrackerTypeCode(result)
        if wantedEnum and resultEnum and wantedEnum == resultEnum then
            lastMethod = methodName
            return true
        end
        if type(result) == "table" then
            lastMethod = methodName
            return FocusTypeTableHasMatch(result, typeCode)
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
            return value, lastMethod
        end
    end

    local active = TryMethod("GetActiveTypes", unit)
    if active ~= nil then
        return active, lastMethod
    end

    if type(tracker.GetHighestPriority) == "function" then
        local ok, topType = pcall(tracker.GetHighestPriority, tracker, unit)
        if ok then
            lastMethod = "GetHighestPriority"
            local wantedEnum = NormalizeFocusTrackerTypeCode(typeCode)
            local topEnum = NormalizeFocusTrackerTypeCode(topType)
            if wantedEnum and topEnum then
                return wantedEnum == topEnum, lastMethod
            end
            return topType == typeCode, lastMethod
        end
    end

    return false, lastMethod
end

local function IsFocusCurveColorMatch(actual, expected)
    if not actual or not expected then
        return false
    end
    if type(actual.GetRGBA) ~= "function" or type(expected.GetRGBA) ~= "function" then
        return false
    end
    local okA, ar, ag, ab, aa = pcall(actual.GetRGBA, actual)
    if not okA then
        return false
    end
    local okE, er, eg, eb, ea = pcall(expected.GetRGBA, expected)
    if not okE then
        return false
    end
    local vals = { ar, ag, ab, aa, er, eg, eb, ea }
    for i = 1, #vals do
        if IsSecretValue(vals[i]) then
            return false
        end
        if type(vals[i]) ~= "number" then
            return false
        end
    end
    if math.abs(ar - er) > FOCUS_HAZARD_CURVE_EPSILON then return false end
    if math.abs(ag - eg) > FOCUS_HAZARD_CURVE_EPSILON then return false end
    if math.abs(ab - eb) > FOCUS_HAZARD_CURVE_EPSILON then return false end
    if math.abs(aa - ea) > FOCUS_HAZARD_CURVE_EPSILON then return false end
    return true
end

local function IsFocusCurveColorDifferent(colorA, colorB)
    if not colorA or not colorB then
        return false
    end
    if type(colorA.GetRGBA) ~= "function" or type(colorB.GetRGBA) ~= "function" then
        return false
    end
    local okA, ar, ag, ab, aa = pcall(colorA.GetRGBA, colorA)
    if not okA then
        return false
    end
    local okB, br, bg, bb, ba = pcall(colorB.GetRGBA, colorB)
    if not okB then
        return false
    end
    local vals = { ar, ag, ab, aa, br, bg, bb, ba }
    for i = 1, #vals do
        if IsSecretValue(vals[i]) then
            return false
        end
        if type(vals[i]) ~= "number" then
            return false
        end
    end
    if math.abs(ar - br) > FOCUS_HAZARD_CURVE_EPSILON then return true end
    if math.abs(ag - bg) > FOCUS_HAZARD_CURVE_EPSILON then return true end
    if math.abs(ab - bb) > FOCUS_HAZARD_CURVE_EPSILON then return true end
    if math.abs(aa - ba) > FOCUS_HAZARD_CURVE_EPSILON then return true end
    return false
end

local function GetFocusHazardProbeCurve(targetEnum)
    local normalized = NormalizeFocusHazardEnum(targetEnum)
    if not normalized then
        return nil
    end
    if _focusHazardProbeCurves[normalized] then
        return _focusHazardProbeCurves[normalized]
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
        local pointEnum = NormalizeFocusHazardEnum(enumValue)
        local alpha = (pointEnum == normalized) and 1 or 0
        curve:AddPoint(enumValue, CreateColor(1, 1, 1, alpha))
    end

    Add(FOCUS_HAZARD_ENUM.None)
    Add(FOCUS_HAZARD_ENUM.Magic)
    Add(FOCUS_HAZARD_ENUM.Curse)
    Add(FOCUS_HAZARD_ENUM.Disease)
    Add(FOCUS_HAZARD_ENUM.Poison)
    Add(FOCUS_HAZARD_ENUM.Enrage)
    Add(FOCUS_HAZARD_ENUM.Bleed)

    _focusHazardProbeCurves[normalized] = curve
    _focusHazardProbeMatchColors[normalized] = CreateColor(1, 1, 1, 1)
    return curve
end

local function GetFocusHazardZeroProbeCurve()
    if _focusHazardZeroProbeCurve then
        return _focusHazardZeroProbeCurve
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
        return nil
    end
    if not Enum or not Enum.LuaCurveType then
        return nil
    end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(FOCUS_HAZARD_ENUM.None, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Magic, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Curse, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Poison, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Enrage, CreateColor(1, 1, 1, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Bleed, CreateColor(1, 1, 1, 0))
    _focusHazardZeroProbeCurve = curve
    return curve
end

local function ResolveFocusHazardEnumByCurve(unit, auraInstanceID)
    if not unit or not auraInstanceID then
        return nil
    end
    if not C_UnitAuras or type(C_UnitAuras.GetAuraDispelTypeColor) ~= "function" then
        return nil
    end

    local zeroCurve = GetFocusHazardZeroProbeCurve()
    for _, enum in ipairs(FOCUS_HAZARD_PRIORITY) do
        local curve = GetFocusHazardProbeCurve(enum)
        if curve then
            local okColor, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
            if okColor and color then
                if zeroCurve then
                    local okZero, zeroColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, zeroCurve)
                    if okZero and IsFocusCurveColorDifferent(color, zeroColor) then
                        return enum
                    end
                end
                local expected = _focusHazardProbeMatchColors[NormalizeFocusHazardEnum(enum)]
                if expected and IsFocusCurveColorMatch(color, expected) then
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

local _focusHazardMainColorCurve = nil
local function GetFocusHazardMainColorCurve()
    if _focusHazardMainColorCurve then return _focusHazardMainColorCurve end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then return nil end
    if not Enum or not Enum.LuaCurveType then return nil end
    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    local c = FOCUS_HAZARD_COLORS
    curve:AddPoint(FOCUS_HAZARD_ENUM.None,    CreateColor(0, 0, 0, 0))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Magic,   CreateColor(c[FOCUS_HAZARD_ENUM.Magic][1],   c[FOCUS_HAZARD_ENUM.Magic][2],   c[FOCUS_HAZARD_ENUM.Magic][3],   0.90))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Curse,   CreateColor(c[FOCUS_HAZARD_ENUM.Curse][1],   c[FOCUS_HAZARD_ENUM.Curse][2],   c[FOCUS_HAZARD_ENUM.Curse][3],   0.90))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Disease, CreateColor(c[FOCUS_HAZARD_ENUM.Disease][1], c[FOCUS_HAZARD_ENUM.Disease][2], c[FOCUS_HAZARD_ENUM.Disease][3], 0.90))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Poison,  CreateColor(c[FOCUS_HAZARD_ENUM.Poison][1],  c[FOCUS_HAZARD_ENUM.Poison][2],  c[FOCUS_HAZARD_ENUM.Poison][3],  0.90))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Enrage,  CreateColor(c[FOCUS_HAZARD_ENUM.Bleed][1],   c[FOCUS_HAZARD_ENUM.Bleed][2],   c[FOCUS_HAZARD_ENUM.Bleed][3],   0.90))
    curve:AddPoint(FOCUS_HAZARD_ENUM.Bleed,   CreateColor(c[FOCUS_HAZARD_ENUM.Bleed][1],   c[FOCUS_HAZARD_ENUM.Bleed][2],   c[FOCUS_HAZARD_ENUM.Bleed][3],   0.90))
    _focusHazardMainColorCurve = curve
    return curve
end

local function RefreshFocusPrecombatNonTypedCache(unit)
    wipe(_focusPrecombatNonTypedIIDs)
    if not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then return end
    for i = 1, 40 do
        local okAura, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
        if not okAura or not aura then break end
        local iid = aura.auraInstanceID
        if iid then
            local enum = select(1, ResolveFocusHazardFromAura(unit, aura))
            if not enum or enum == FOCUS_HAZARD_ENUM.Unknown or enum == FOCUS_HAZARD_ENUM.None then
                _focusPrecombatNonTypedIIDs[iid] = true
            end
        end
    end
end

local function IsFocusKnownNonTypedIID(auraInstanceID)
    return _focusPrecombatNonTypedIIDs[auraInstanceID] == true
end

local function ResolveFocusHazardFromAuraInstanceID(unit, auraInstanceID, typeHint)
    local dt = NormalizeFocusHazardEnum(typeHint)
    if dt and dt ~= FOCUS_HAZARD_ENUM.Unknown then
        return dt, "blizz:type"
    end
    dt = ResolveFocusHazardEnumByCurve(unit, auraInstanceID)
    if dt then
        return dt, "blizz:curve"
    end
    return nil, nil
end

local function ResolveFocusHazardFromAura(unit, aura)
    if type(aura) ~= "table" then
        return nil, nil
    end
    local dt = NormalizeFocusHazardEnum(aura.dispelType)
    if dt then return dt, "field:dispelType" end
    dt = NormalizeFocusHazardEnum(aura.dispelName)
    if dt then return dt, "field:dispelName" end
    dt = NormalizeFocusHazardEnum(aura.debuffType)
    if dt then return dt, "field:debuffType" end
    dt = NormalizeFocusHazardEnum(aura.type)
    if dt then return dt, "field:type" end
    local auraInstanceID = aura.auraInstanceID
    if auraInstanceID then
        dt = ResolveFocusHazardEnumByCurve(unit, auraInstanceID)
        if dt then
            return dt, "curve"
        end
    end
    return nil, nil
end

local function IsFocusBlizzTrackedUnit(unit)
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

local function ResolveFocusHazardFromBlizzFrameDebuff(debuffFrame)
    if type(debuffFrame) ~= "table" then
        return nil
    end
    local dt = NormalizeFocusHazardEnum(debuffFrame.debuffType)
    if not dt then dt = NormalizeFocusHazardEnum(debuffFrame.dispelName) end
    if not dt then dt = NormalizeFocusHazardEnum(debuffFrame.dispelType) end
    if not dt then dt = NormalizeFocusHazardEnum(debuffFrame.type) end
    return dt
end

local function CountFocusBlizzAuraSet(tbl)
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
local _focusSpellIDFields = { "spellID", "spellId", "auraSpellID", "auraSpellId" }

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

local function ReadDebuffFrameSpellID(df)
    if not df then
        return nil
    end
    for _, field in ipairs(_focusSpellIDFields) do
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

local function StoreFocusAura(entry, iid, isDispellable, dt, icon, stackCount, spellID)
    if not iid then
        return
    end
    entry.debuffs[iid] = true
    if isDispellable then
        entry.dispellable[iid] = true
    end
    if dt and dt ~= FOCUS_HAZARD_ENUM.Unknown then
        entry.types[iid] = dt
    end
    if icon then
        entry.icons[iid] = icon
    end
    if stackCount and stackCount > 1 then
        entry.stacks[iid] = stackCount
    end
    if spellID and spellID > 0 then
        entry.spellIDs[iid] = spellID
    end
end

local function CaptureFocusHazardsFromBlizzFrame(blizzFrame)
    if not blizzFrame then
        return nil, nil
    end

    local unit = blizzFrame.unit
    if not IsFocusBlizzTrackedUnit(unit) then
        return nil, nil
    end
    if UnitExists and type(UnitExists) == "function" and not UnitExists(unit) then
        return nil, nil
    end

    local entry = _focusBlizzAuraCache[unit]
    if not entry then
        entry = { debuffs = {}, dispellable = {}, types = {}, icons = {}, stacks = {}, spellIDs = {} }
        _focusBlizzAuraCache[unit] = entry
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
                StoreFocusAura(entry,
                    df.auraInstanceID,
                    false,
                    ResolveFocusHazardFromBlizzFrameDebuff(df),
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
                StoreFocusAura(entry,
                    df.auraInstanceID,
                    true,
                    ResolveFocusHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df),
                    ReadDebuffFrameSpellID(df)
                )
            end
        end
    end

    return unit, entry
end

local function PrimeFocusBlizzAuraCache()
    local compactPlayerFrame = _G.CompactPlayerFrame
    if compactPlayerFrame and compactPlayerFrame.unit == "player" then
        CaptureFocusHazardsFromBlizzFrame(compactPlayerFrame)
    end

    for i = 1, 5 do
        local compactParty = _G["CompactPartyFrameMember" .. tostring(i)]
        if compactParty and compactParty.unit then
            CaptureFocusHazardsFromBlizzFrame(compactParty)
        end
    end

    for i = 1, 40 do
        local compactRaid = _G["CompactRaidFrame" .. tostring(i)]
        if compactRaid and compactRaid.unit then
            CaptureFocusHazardsFromBlizzFrame(compactRaid)
        end
    end
end

local function ResolveFocusCacheUnitToken(unit)
    if type(unit) ~= "string" or type(UnitIsUnit) ~= "function" then
        return nil
    end
    local function IsSame(candidate)
        local ok, same = pcall(UnitIsUnit, unit, candidate)
        return ok and same == true
    end
    if IsSame("player") then
        return "player"
    end
    for i = 1, 4 do
        local token = "party" .. tostring(i)
        if IsSame(token) then
            return token
        end
    end
    for i = 1, 40 do
        local token = "raid" .. tostring(i)
        if IsSame(token) then
            return token
        end
    end
    return nil
end

local function EnsureFocusBlizzAuraHook()
    if _focusBlizzHookRegistered then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end

    local function OnBlizzAuraUpdate(blizzFrame)
        CaptureFocusHazardsFromBlizzFrame(blizzFrame)
    end

    if type(CompactUnitFrame_UpdateAuras) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", OnBlizzAuraUpdate)
        _focusBlizzHookRegistered = true
    end
    if type(CompactUnitFrame_UpdateDebuffs) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", OnBlizzAuraUpdate)
        _focusBlizzHookRegistered = true
    end

    if _focusBlizzHookRegistered then
        PrimeFocusBlizzAuraCache()
        FocusDiag("blizzHook=ON")
    end
end

local function GetFocusHazardLabel(enum)
    return FOCUS_HAZARD_LABELS[NormalizeFocusHazardEnum(enum) or FOCUS_HAZARD_ENUM.None] or "NONE"
end

local function GetFocusHazardColor(enum)
    return FOCUS_HAZARD_COLORS[NormalizeFocusHazardEnum(enum) or FOCUS_HAZARD_ENUM.Unknown]
end

local function NormalizeFocusLockoutName(name)
    if type(name) ~= "string" or IsSecretValue(name) then
        return nil
    end
    local okLower, lower = pcall(string.lower, name)
    if not okLower or type(lower) ~= "string" then
        return nil
    end
    return lower
end

local function ResolveFocusLockoutSpellID(value)
    if value == nil or IsSecretValue(value) then
        return nil
    end
    local okNum, num = pcall(tonumber, value)
    if not okNum or type(num) ~= "number" or num <= 0 then
        return nil
    end
    return num
end

local function ShouldIgnoreFocusLockoutDebuff(aura)
    if type(aura) ~= "table" then
        return false
    end
    local cb = _G.MidnightUI_ConditionBorder
    if cb and type(cb.ShouldIgnoreLockoutDebuff) == "function" then
        local okIgnore, ignore = pcall(cb.ShouldIgnoreLockoutDebuff, aura)
        if okIgnore and ignore == true then
            return true
        end
    end

    local spellID = ResolveFocusLockoutSpellID(aura.spellId)
        or ResolveFocusLockoutSpellID(aura.spellID)
        or ResolveFocusLockoutSpellID(aura.id)
    if spellID and FOCUS_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS[spellID] then
        return true
    end

    local nameKey = NormalizeFocusLockoutName(aura.name)
        or NormalizeFocusLockoutName(aura.auraName)
        or NormalizeFocusLockoutName(aura.spellName)
    if nameKey and FOCUS_IGNORED_LOCKOUT_DEBUFF_NAMES[nameKey] then
        return true
    end
    return false
end

local function IsFocusQuestionMarkToken(iconToken)
    if type(iconToken) ~= "string" then
        return false
    end
    if IsSecretValue(iconToken) then
        return false
    end
    local okLower, lower = pcall(string.lower, iconToken)
    if not okLower or type(lower) ~= "string" then
        return false
    end
    return lower:find("questionmark", 1, true) ~= nil
        or lower:find("inv_misc_questionmark", 1, true) ~= nil
end

local function CanUseFocusIconToken(iconToken)
    if iconToken == nil then
        return false
    end
    if IsSecretValue(iconToken) then
        return true
    end
    local tokenType = type(iconToken)
    if tokenType == "number" then
        if iconToken == FOCUS_DEBUFF_PREVIEW.placeholderIcon then
            return false
        end
        return iconToken > 0
    end
    if tokenType == "string" then
        if iconToken == "" or IsFocusQuestionMarkToken(iconToken) then
            return false
        end
        return true
    end
    return false
end

local function NormalizeFocusAuraStackCount(value)
    if value == nil or IsSecretValue(value) then
        return ""
    end
    local number = CoerceNumber(value)
    if type(number) ~= "number" or IsSecretValue(number) then
        return ""
    end
    number = math.floor(number + 0.5)
    if number <= 1 then
        return ""
    end
    return tostring(number)
end

local function GetFocusHazardIconAtlas(enum)
    local normalized = NormalizeFocusHazardEnum(enum)
    if normalized == FOCUS_HAZARD_ENUM.Magic then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Magic"
    elseif normalized == FOCUS_HAZARD_ENUM.Curse then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Curse"
    elseif normalized == FOCUS_HAZARD_ENUM.Disease then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Disease"
    elseif normalized == FOCUS_HAZARD_ENUM.Poison then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Poison"
    elseif normalized == FOCUS_HAZARD_ENUM.Bleed then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Bleed"
    elseif normalized == FOCUS_HAZARD_ENUM.Unknown then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Magic"
    end
    return nil
end

local function SetFocusIconTexCoord(texture, usingAtlas)
    if not texture or not texture.SetTexCoord then
        return
    end
    if usingAtlas then
        texture:SetTexCoord(0, 1, 0, 1)
    else
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function IsFocusUnitPlayer(unit)
    if unit == "player" then
        return true
    end
    if type(unit) ~= "string" or type(UnitIsUnit) ~= "function" then
        return false
    end
    local ok, same = pcall(UnitIsUnit, unit, "player")
    return ok and same == true
end

local function GetFocusHintFromPlayerFrameCondTint(unit)
    if not IsFocusUnitPlayer(unit) then
        return nil, nil, "non-player-unit"
    end
    local pf = _G.MidnightUI_PlayerFrame
    if not pf or pf._muiCondTintActive ~= true then
        return nil, nil, "playerframe-condtint-off"
    end

    local enum = NormalizeFocusHazardEnum(pf._muiCondTintSource)
    local secretColor = nil
    if pf._muiCondTintSecret == true and pf._muiCondTintHasColor == true then
        local sr, sg, sb = pf._muiCondTintR, pf._muiCondTintG, pf._muiCondTintB
        if sr ~= nil and sg ~= nil and sb ~= nil then
            secretColor = { sr, sg, sb, secret = true }
        end
    end
    if enum and enum ~= FOCUS_HAZARD_ENUM.Unknown then
        if secretColor then
            return enum, secretColor, "playerframe-condtint-enum-secret"
        end
        local r = CoerceFocusTintChannel(pf._muiCondTintR)
        local g = CoerceFocusTintChannel(pf._muiCondTintG)
        local b = CoerceFocusTintChannel(pf._muiCondTintB)
        if r ~= nil and g ~= nil and b ~= nil then
            return enum, { r, g, b }, "playerframe-condtint-enum"
        end
        return enum, GetFocusHazardColor(enum), "playerframe-condtint-enum-fallback"
    end
    if secretColor then
        return FOCUS_HAZARD_ENUM.Unknown, secretColor, "playerframe-condtint-secret"
    end
    local r = CoerceFocusTintChannel(pf._muiCondTintR)
    local g = CoerceFocusTintChannel(pf._muiCondTintG)
    local b = CoerceFocusTintChannel(pf._muiCondTintB)
    if r ~= nil and g ~= nil and b ~= nil then
        return FOCUS_HAZARD_ENUM.Unknown, { r, g, b }, "playerframe-condtint-unknown"
    end
    return nil, nil, "playerframe-condtint-none"
end

local function GetFocusSecondaryHintFromConditionBorder(unit)
    if not IsFocusUnitPlayer(unit) then
        return nil, nil, "non-player-unit"
    end
    local cb = _G.MidnightUI_ConditionBorder
    if not cb or type(cb.GetStateSnapshot) ~= "function" then
        return nil, nil, "condborder-unavailable"
    end
    local ok, state = pcall(cb.GetStateSnapshot)
    if not ok or type(state) ~= "table" then
        return nil, nil, "condborder-state-missing"
    end
    local enum = NormalizeFocusHazardEnum(state.overlapSecondaryEnum)
        or NormalizeFocusHazardEnum(state.activeSecondaryEnum)
        or NormalizeFocusHazardEnum(state.typeBoxEnum)
    local color = nil
    if state.typeBoxR ~= nil and state.typeBoxG ~= nil and state.typeBoxB ~= nil then
        if IsSecretValue(state.typeBoxR) or IsSecretValue(state.typeBoxG) or IsSecretValue(state.typeBoxB) then
            color = { state.typeBoxR, state.typeBoxG, state.typeBoxB, secret = true }
        else
            local r = CoerceFocusTintChannel(state.typeBoxR)
            local g = CoerceFocusTintChannel(state.typeBoxG)
            local b = CoerceFocusTintChannel(state.typeBoxB)
            if r ~= nil and g ~= nil and b ~= nil then
                color = { r, g, b }
            end
        end
    end
    if not color then
        local r, g, b = ParseFocusRGBText(state.typeBoxRGB)
        if r ~= nil and g ~= nil and b ~= nil then
            color = { r, g, b }
        end
    end
    return enum, color, "condborder-secondary"
end

local function GetFocusHazardHintFromConditionBorder(unit)
    if not IsFocusUnitPlayer(unit) then
        return nil, nil, "non-player-unit", nil, nil
    end
    local trackerUnit = ResolveFocusCacheUnitToken(unit) or unit

    local cb = _G.MidnightUI_ConditionBorder
    if cb and type(cb.GetStateSnapshot) == "function" then
        local okState, state = pcall(cb.GetStateSnapshot)
        if okState and type(state) == "table" then
            local source = "condborder-state-primary"
            local enum = NormalizeFocusHazardEnum(state.primaryEnum)
            if not enum then
                enum = NormalizeFocusHazardEnum(state.activePrimaryEnum)
                if enum then
                    source = "condborder-state-active-primary"
                end
            end
            if not enum then
                enum = NormalizeFocusHazardEnum(state.curvePrimaryEnum)
                if enum then
                    source = "condborder-state-curve-primary"
                end
            end
            if not enum then
                enum = NormalizeFocusHazardEnum(state.overlapPrimaryEnum)
                if enum then
                    source = "condborder-state-overlap-primary"
                end
            end
            if not enum then
                enum = NormalizeFocusHazardEnum(state.hookPrimaryEnum)
                if enum then
                    source = "condborder-state-hook-primary"
                end
            end
            if not enum then
                enum = NormalizeFocusHazardEnum(state.barTintEnum)
                if enum then
                    source = "condborder-state-bartint-enum"
                end
            end
            if not enum then
                enum = ParseFocusHazardLabelText(state.primaryLabel)
                if enum then
                    source = "condborder-state-primary-label"
                end
            end
            if not enum then
                enum = ParseFocusHazardLabelText(state.tintSource)
                if enum then
                    source = "condborder-state-tint-source"
                end
            end

            local activeSigPrimary, activeSigSecondary = ParseFocusHazardSignatureText(state.activeSignature)
            local hookSigPrimary, hookSigSecondary = ParseFocusHazardSignatureText(state.hookSignature)
            if not enum and activeSigPrimary then
                enum = activeSigPrimary
                source = "condborder-state-active-signature"
            end
            if not enum and hookSigPrimary then
                enum = hookSigPrimary
                source = "condborder-state-hook-signature"
            end

            local secondaryEnum = NormalizeFocusHazardEnum(state.overlapSecondaryEnum)
                or NormalizeFocusHazardEnum(state.activeSecondaryEnum)
                or NormalizeFocusHazardEnum(state.hookSecondaryEnum)
            if not secondaryEnum then
                secondaryEnum = activeSigSecondary
            end
            if not secondaryEnum then
                secondaryEnum = hookSigSecondary
            end
            local typeBoxEnum = NormalizeFocusHazardEnum(state.typeBoxEnum)
            if not secondaryEnum and typeBoxEnum and typeBoxEnum ~= FOCUS_HAZARD_ENUM.Unknown then
                secondaryEnum = typeBoxEnum
            end
            if secondaryEnum == FOCUS_HAZARD_ENUM.Unknown then
                secondaryEnum = nil
            end

            local secondaryColor = nil
            local rawSecR, rawSecG, rawSecB = state.typeBoxR, state.typeBoxG, state.typeBoxB
            if rawSecR ~= nil and rawSecG ~= nil and rawSecB ~= nil then
                if IsSecretValue(rawSecR) or IsSecretValue(rawSecG) or IsSecretValue(rawSecB) then
                    secondaryColor = { rawSecR, rawSecG, rawSecB, secret = true, source = "condborder-state-typebox" }
                else
                    local secR = CoerceFocusTintChannel(rawSecR)
                    local secG = CoerceFocusTintChannel(rawSecG)
                    local secB = CoerceFocusTintChannel(rawSecB)
                    if secR ~= nil and secG ~= nil and secB ~= nil then
                        secondaryColor = { secR, secG, secB }
                    end
                end
            end
            if not secondaryColor then
                local secR, secG, secB = ParseFocusRGBText(state.typeBoxRGB)
                if secR ~= nil and secG ~= nil and secB ~= nil then
                    secondaryColor = { secR, secG, secB }
                end
            end

            local tintColor = nil
            local tr, tg, tb = ParseFocusRGBText(state.barTintRGB)
            if tr == nil then
                tr, tg, tb = ParseFocusRGBText(state.tintRGB)
            end
            if tr ~= nil and tg ~= nil and tb ~= nil then
                tintColor = { tr, tg, tb }
            end

            local active = (state.active == true) or (state.tintActive == true)
            local barTintOn = false
            if type(state.barTint) == "string" and not IsSecretValue(state.barTint) then
                local okFind, found = pcall(string.find, state.barTint, "ON", 1, true)
                barTintOn = okFind and found ~= nil
            end

            local trackerMethod = "none"
            local usedTracker = false
            if (not enum) or enum == FOCUS_HAZARD_ENUM.Unknown then
                local trackerMap = {
                    { FOCUS_HAZARD_ENUM.Magic,   { 1, "MAGIC", "type_magic" } },
                    { FOCUS_HAZARD_ENUM.Curse,   { 2, "CURSE", "type_curse" } },
                    { FOCUS_HAZARD_ENUM.Disease, { 3, "DISEASE", "type_disease" } },
                    { FOCUS_HAZARD_ENUM.Poison,  { 4, "POISON", "type_poison" } },
                    { FOCUS_HAZARD_ENUM.Bleed,   { 6, 9, 11, "BLEED", "ENRAGE", "type_bleed", "type_enrage" } },
                }
                for _, item in ipairs(trackerMap) do
                    if enum and enum ~= FOCUS_HAZARD_ENUM.Unknown then
                        break
                    end
                    local targetEnum, codes = item[1], item[2]
                    local matched = false
                    for _, code in ipairs(codes) do
                        local isActive, method = FocusTrackerHasTypeActive(trackerUnit, code)
                        if method and method ~= "none" and trackerMethod == "none" then
                            trackerMethod = method
                        end
                        if isActive then
                            matched = true
                            break
                        end
                    end
                    if matched then
                        enum = targetEnum
                        usedTracker = true
                    end
                end
            end
            local trackerBleed = (state.trackerBleed == true) or (tostring(state.trackerBleed) == "YES")
            if (not enum) and trackerBleed then
                enum = FOCUS_HAZARD_ENUM.Bleed
                usedTracker = true
                if trackerMethod == "none" then
                    trackerMethod = "condborder:trackerBleed"
                end
            end

            if enum and enum ~= FOCUS_HAZARD_ENUM.Unknown then
                local resolvedSource = source or "condborder-state-enum"
                if usedTracker then
                    if trackerMethod ~= "none" then
                        resolvedSource = "tracker:" .. tostring(trackerMethod)
                    else
                        resolvedSource = "tracker"
                    end
                end
                if state.primaryEnum == nil and state.activePrimaryEnum == nil and state.curvePrimaryEnum == nil
                    and state.overlapPrimaryEnum == nil and state.hookPrimaryEnum == nil and state.barTintEnum == nil then
                    resolvedSource = resolvedSource .. "+fallback"
                end
                return enum, tintColor, resolvedSource, secondaryEnum, secondaryColor
            end

            if active or barTintOn then
                local frameEnum, frameColor, frameSource = GetFocusHintFromPlayerFrameCondTint(unit)
                if frameEnum and frameEnum ~= FOCUS_HAZARD_ENUM.Unknown then
                    return frameEnum, frameColor, "playerframe-fallback:" .. tostring(frameSource), secondaryEnum, secondaryColor
                end
                if type(frameColor) == "table" and frameColor.secret == true then
                    return FOCUS_HAZARD_ENUM.Unknown, frameColor, "playerframe-fallback-secret", secondaryEnum, secondaryColor
                end
                if tintColor then
                    return FOCUS_HAZARD_ENUM.Unknown, tintColor, "condborder-state-unknown-rgb", secondaryEnum, secondaryColor
                end
                if frameEnum == FOCUS_HAZARD_ENUM.Unknown and type(frameColor) == "table" then
                    return FOCUS_HAZARD_ENUM.Unknown, frameColor, "playerframe-fallback-unknown", secondaryEnum, secondaryColor
                end
                return FOCUS_HAZARD_ENUM.Unknown, nil, "condborder-state-unknown", secondaryEnum, secondaryColor
            end
        end
    end

    local frameEnum, frameColor, frameSource = GetFocusHintFromPlayerFrameCondTint(unit)
    return frameEnum, frameColor, frameSource, nil, nil
end

local function ShouldAllowFocusUnknownPrimaryTint(unit)
    if not IsFocusUnitPlayer(unit) then
        return true, "non-player-unit"
    end
    local cb = _G.MidnightUI_ConditionBorder
    if not cb or type(cb.GetStateSnapshot) ~= "function" then
        return true, "condborder-unavailable"
    end
    local ok, state = pcall(cb.GetStateSnapshot)
    if not ok or type(state) ~= "table" then
        return true, "condborder-state-missing"
    end

    local enum = NormalizeFocusHazardEnum(state.primaryEnum)
        or NormalizeFocusHazardEnum(state.activePrimaryEnum)
        or NormalizeFocusHazardEnum(state.curvePrimaryEnum)
        or NormalizeFocusHazardEnum(state.overlapPrimaryEnum)
        or NormalizeFocusHazardEnum(state.hookPrimaryEnum)
        or NormalizeFocusHazardEnum(state.barTintEnum)
    if not enum then
        enum = ParseFocusHazardLabelText(state.primaryLabel)
            or ParseFocusHazardLabelText(state.tintSource)
    end
    if not enum then
        local activeSigPrimary = select(1, ParseFocusHazardSignatureText(state.activeSignature))
        local hookSigPrimary = select(1, ParseFocusHazardSignatureText(state.hookSignature))
        enum = activeSigPrimary or hookSigPrimary
    end
    if enum and enum ~= FOCUS_HAZARD_ENUM.Unknown then
        return true, "condborder-primary-enum"
    end

    local trackerBleed = (state.trackerBleed == true) or (tostring(state.trackerBleed) == "YES")
    if trackerBleed then
        return true, "condborder-tracker-bleed"
    end

    local barTintOn = false
    if type(state.barTint) == "string" then
        local okFind, found = pcall(string.find, state.barTint, "ON", 1, true)
        barTintOn = okFind and found ~= nil
    end
    if barTintOn then
        return true, "condborder-bartint-on"
    end

    if state.active == true and state.tintActive == true then
        return true, "condborder-tint-active"
    end

    return false, "condborder-no-primary"
end

local function EnsureFocusDebuffPreviewWidgets(frame)
    if not frame then
        return nil
    end
    if frame._muiFocusDebuffPreview then
        return frame._muiFocusDebuffPreview
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
    iconHolder:SetPoint(
        "TOPRIGHT",
        frame.healthContainer or frame,
        "TOPRIGHT",
        -2,
        -2 + (FOCUS_DEBUFF_PREVIEW.offsetY or 0)
    )
    iconHolder:SetSize((FOCUS_DEBUFF_PREVIEW.iconSize + 2) * FOCUS_DEBUFF_PREVIEW.maxIcons, FOCUS_DEBUFF_PREVIEW.iconSize + 2)
    iconHolder:Hide()

    local function CreateIconButton(index)
        local btn = CreateFrame("Frame", nil, iconHolder, "BackdropTemplate")
        btn:SetSize(FOCUS_DEBUFF_PREVIEW.iconSize, FOCUS_DEBUFF_PREVIEW.iconSize)
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
        SetFocusIconTexCoord(icon, false)
        btn.icon = icon

        local count = btn:CreateFontString(nil, "OVERLAY")
        count:SetFont("Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
        count:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -1, 2)
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
    for i = 1, FOCUS_DEBUFF_PREVIEW.maxIcons do
        local btn = CreateIconButton(i)
        btn:SetPoint("RIGHT", iconHolder, "RIGHT", -((i - 1) * (FOCUS_DEBUFF_PREVIEW.iconSize + 2)), 0)
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

    frame._muiFocusDebuffPreview = preview
    return preview
end

local function SetFocusHPTextInset(frame, inset)
    if not frame or not frame.healthText then
        return
    end
    local right = -10 - (tonumber(inset) or 0)
    frame.healthText:ClearAllPoints()
    frame.healthText:SetPoint("RIGHT", frame.healthContainer or frame, "RIGHT", right, 0)
end

local function FormatFocusDiagRGBA(r, g, b, a)
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) or IsSecretValue(a) then
        return "secret"
    end
    local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)
    local an = tonumber(a)
    if rn and gn and bn then
        if an then
            return string.format("%.3f,%.3f,%.3f,%.3f", rn, gn, bn, an)
        end
        return string.format("%.3f,%.3f,%.3f", rn, gn, bn)
    end
    return table.concat({
        FocusSafeToString(r),
        FocusSafeToString(g),
        FocusSafeToString(b),
        FocusSafeToString(a),
    }, ",")
end

local function CaptureFocusMiniBarDiag(bar)
    if not bar then
        return "missing"
    end
    local sb = "none"
    local tex = "none"
    local grad = "0/0/0"
    if bar.GetStatusBarColor then
        local okSB, sr, sg, sbc, sa = pcall(bar.GetStatusBarColor, bar)
        if okSB then
            sb = FormatFocusDiagRGBA(sr, sg, sbc, sa)
        else
            sb = "error"
        end
    end
    local t = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if t and t.GetVertexColor then
        local okTex, tr, tg, tb, ta = pcall(t.GetVertexColor, t)
        if okTex then
            tex = FormatFocusDiagRGBA(tr, tg, tb, ta)
        else
            tex = "error"
        end
    else
        tex = "none"
    end
    local topShown = (bar._muiTopHighlight and bar._muiTopHighlight.IsShown and bar._muiTopHighlight:IsShown()) and "1" or "0"
    local botShown = (bar._muiBottomShade and bar._muiBottomShade.IsShown and bar._muiBottomShade:IsShown()) and "1" or "0"
    local specShown = (bar._muiSpecular and bar._muiSpecular.IsShown and bar._muiSpecular:IsShown()) and "1" or "0"
    grad = table.concat({ topShown, botShown, specShown }, "/")
    return "sb=" .. sb .. " tex=" .. tex .. " grad=" .. grad
end

local function FocusBarDiagHasSecret(diagText)
    if type(diagText) ~= "string" then
        return false
    end
    local okFind, found = pcall(string.find, diagText, "secret", 1, true)
    return okFind and found ~= nil
end

local function ApplyFocusBaseColorToBar(bar, r, g, b, style, topDarkA, centerLightA, bottomDarkA)
    if not bar then
        return
    end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if tex then
        if tex.SetHorizTile then tex:SetHorizTile(false) end
        if tex.SetVertTile then tex:SetVertTile(false) end
        if tex.SetVertexColor then
            -- Clear any lingering secret payload tint first.
            tex:SetVertexColor(1, 1, 1, 1)
        end
    end
    bar:SetStatusBarColor(r, g, b, 1.0)
    if tex and tex.SetVertexColor then
        tex:SetVertexColor(r, g, b, 1.0)
    end
    if style == "Gradient" then
        ApplyPolishedGradientToBar(bar, tex, topDarkA, centerLightA, bottomDarkA, r, g, b)
    else
        HidePolishedGradientOnBar(bar)
    end
end

local function GetFocusIdentityDiag()
    local exists = UnitExists("focus") and "YES" or "NO"
    if exists ~= "YES" then
        return "focusExists=NO"
    end
    local unitIsPlayer = UnitIsPlayer("focus") and "YES" or "NO"
    local sameAsPlayer = UnitIsUnit("focus", "player") and "YES" or "NO"
    local reaction = FocusSafeToString(UnitReaction("focus", "player") or "nil")
    local _, classToken = UnitClass("focus")
    return table.concat({
        "focusExists=YES",
        "focusIsPlayer=" .. unitIsPlayer,
        "focusIsSelf=" .. sameAsPlayer,
        "focusClass=" .. FocusSafeToString(classToken or "nil"),
        "focusReaction=" .. reaction,
    }, " ")
end

local function GetPlayerTintQuickDiag()
    local pf = _G.MidnightUI_PlayerFrame
    if not pf then
        return "playerTint=OFF playerSrc=none playerRGB=none"
    end
    local active = (pf._muiCondTintActive == true) and "ON" or "OFF"
    local src = FocusSafeToString(pf._muiCondTintSource or "none")
    local rgb = "none"
    if pf._muiCondTintSecret == true and pf._muiCondTintHasColor == true then
        rgb = "secret"
    elseif pf._muiCondTintHasColor == true then
        rgb = FormatFocusDiagRGBA(pf._muiCondTintR, pf._muiCondTintG, pf._muiCondTintB, 1)
    end
    return "playerTint=" .. active .. " playerSrc=" .. src .. " playerRGB=" .. rgb
end

local function EmitFocusTransitionDiag(frame, key, message)
    if not IsFocusDebuffPreviewDiagEnabled() then
        return
    end
    local tag = "_muiFocusDiagSig_" .. tostring(key or "generic")
    if frame and frame[tag] == message then
        return
    end
    if frame then
        frame[tag] = message
    end
    FocusDiag(message)
end

local function RestoreFocusBaseBarTint(frame, reason, source)
    if not frame then
        return
    end
    local reasonText = FocusSafeToString(reason or "none")
    local sourceText = FocusSafeToString(source or "unknown")
    if not UnitExists("focus") then
        EmitFocusTransitionDiag(frame, "RESTORE",
            table.concat({
                "restore result=SKIP_NO_UNIT",
                "reason=" .. reasonText,
                "src=" .. sourceText,
                GetFocusIdentityDiag(),
                GetPlayerTintQuickDiag(),
            }, " "))
        return
    end

    local hr, hg, hb = GetUnitColor("focus")
    local hbBefore = CaptureFocusMiniBarDiag(frame.healthBar)
    local pbBefore = CaptureFocusMiniBarDiag(frame.powerBar)
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then
        style = "Gradient"
    end

    if frame.healthBar then
        ApplyFocusBaseColorToBar(frame.healthBar, hr, hg, hb, style, 0.28, 0.035, 0.32)
    end

    if frame.healthBg and frame.healthBg.SetColorTexture then
        frame.healthBg:SetColorTexture(hr * 0.15, hg * 0.15, hb * 0.15, 0.6)
    end

    if frame.powerBar then
        local powerType, powerToken = UnitPowerType("focus")
        local token = powerToken or "MANA"
        local powerColor = POWER_COLORS[token] or DEFAULT_POWER_COLOR
        ApplyFocusBaseColorToBar(frame.powerBar, powerColor[1], powerColor[2], powerColor[3], style, 0.24, 0.03, 0.28)
    end

    local hbAfter = CaptureFocusMiniBarDiag(frame.healthBar)
    local pbAfter = CaptureFocusMiniBarDiag(frame.powerBar)
    local playerTint = GetPlayerCondTintSnapshotForFocusDiag()
    local secretStillPresent = FocusBarDiagHasSecret(hbAfter) or FocusBarDiagHasSecret(pbAfter)
    if secretStillPresent
        and frame._muiFocusDebuffPreviewActive ~= true
        and (not playerTint or playerTint.active ~= true)
        and C_Timer and type(C_Timer.After) == "function" then
        frame._muiFocusRestoreRetryCount = tonumber(frame._muiFocusRestoreRetryCount) or 0
        if frame._muiFocusRestoreRetryCount < 3 then
            frame._muiFocusRestoreRetryCount = frame._muiFocusRestoreRetryCount + 1
            local retryNo = frame._muiFocusRestoreRetryCount
            local retrySource = sourceText
            local retryReason = "DEFERRED_RETRY#" .. tostring(retryNo) .. ":" .. reasonText
            EmitFocusTransitionDiag(frame, "RESTORE_RETRY",
                table.concat({
                    "restoreRetry=SCHEDULED",
                    "reason=" .. retryReason,
                    "src=" .. retrySource,
                    "hbAfter={" .. hbAfter .. "}",
                    "pbAfter={" .. pbAfter .. "}",
                }, " "))
            C_Timer.After(0, function()
                if frame and frame:IsShown() and UnitExists("focus") and frame._muiFocusDebuffPreviewActive ~= true then
                    RestoreFocusBaseBarTint(frame, retryReason, retrySource)
                end
            end)
        end
    else
        frame._muiFocusRestoreRetryCount = 0
    end
    EmitFocusTransitionDiag(frame, "RESTORE",
        table.concat({
            "restore result=APPLY",
            "reason=" .. reasonText,
            "src=" .. sourceText,
            "style=" .. FocusSafeToString(style),
            "healthRGB=" .. FormatFocusDiagRGBA(hr, hg, hb, 1),
            GetFocusIdentityDiag(),
            GetPlayerTintQuickDiag(),
            "hbBefore={" .. hbBefore .. "}",
            "hbAfter={" .. hbAfter .. "}",
            "pbBefore={" .. pbBefore .. "}",
            "pbAfter={" .. pbAfter .. "}",
        }, " "))
end

local function ClearFocusDebuffPreview(frame, reason, source)
    if not frame then
        return
    end
    local reasonText = FocusSafeToString(reason or "none")
    local sourceText = FocusSafeToString(source or "unknown")
    local hbBefore = CaptureFocusMiniBarDiag(frame.healthBar)
    local pbBefore = CaptureFocusMiniBarDiag(frame.powerBar)
    local preview = frame._muiFocusDebuffPreview
    if preview and preview.overlay then
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
    if preview and preview.secondary then
        preview.secondary:SetBackdropBorderColor(0, 0, 0, 0)
        preview.secondary:Hide()
    end
    if preview and preview.sweepMoveGroup and preview.sweepMoveGroup:IsPlaying() then
        preview.sweepMoveGroup:Stop()
    end
    if preview and preview.sweep then
        preview.sweep:Hide()
    end
    if preview and preview.iconButtons then
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
    if preview and preview.iconHolder then
        preview.iconHolder:Hide()
    end
    SetFocusHPTextInset(frame, 0)
    frame._muiFocusDebuffStickyAt = nil
    frame._muiFocusDebuffStickyPrimary = nil
    frame._muiFocusDebuffStickyColor = nil
    frame._muiFocusDebuffPreviewActive = false
    frame._muiFocusDebuffPrimaryLast = nil
    frame._muiFocusDebuffSourceLast = nil
    frame._muiFocusDebuffRGBLast = nil
    frame._muiFocusRestoreRetryCount = 0
    RestoreFocusBaseBarTint(frame, reasonText, sourceText)
    local hbAfter = CaptureFocusMiniBarDiag(frame.healthBar)
    local pbAfter = CaptureFocusMiniBarDiag(frame.powerBar)
    EmitFocusTransitionDiag(frame, "CLEAR",
        table.concat({
            "clear reason=" .. reasonText,
            "src=" .. sourceText,
            "preview=OFF",
            GetFocusIdentityDiag(),
            GetPlayerTintQuickDiag(),
            "hbBefore={" .. hbBefore .. "}",
            "hbAfter={" .. hbAfter .. "}",
            "pbBefore={" .. pbBefore .. "}",
            "pbAfter={" .. pbAfter .. "}",
        }, " "))
end

local function LayoutFocusDebuffSweep(preview, frame)
    if not preview or not frame or not preview.sweep or not preview.sweepFx then
        return
    end
    preview.sweep:ClearAllPoints()
    preview.sweep:SetAllPoints(preview.overlay or frame)

    local width = tonumber(frame:GetWidth()) or 0
    local height = tonumber(frame:GetHeight()) or 0
    if width <= 1 then
        width = tonumber(config.width) or 320
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
    for i, pair in ipairs(preview.sweepBands or {}) do
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

local function SetFocusDebuffSweepColor(preview, enum, overrideColor)
    if not preview or not preview.sweepBands then
        return
    end
    local color = overrideColor
    if type(color) ~= "table" then
        color = GetFocusHazardColor(enum) or FOCUS_HAZARD_COLORS[FOCUS_HAZARD_ENUM.Unknown]
    end
    if not color then
        return
    end
    local normalized = NormalizeFocusHazardEnum(enum)
    local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
    if IsFocusSecretColor(color) then
        bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
    elseif normalized == FOCUS_HAZARD_ENUM.Unknown then
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

local function SetFocusDebuffSweepVisible(preview, isVisible)
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

local function CollectFocusDebuffPreviewState(unit)
    local state = {
        unit = FocusSafeToString(unit or "nil"),
        inRestricted = (InCombatLockdown and InCombatLockdown()) and "YES" or "NO",
        primary = nil,
        secondary = nil,
        entries = {},
        scanned = 0,
        typed = 0,
        ignored = 0,
        totalDebuffs = 0,
        blizzToken = "none",
        blizzDebuffs = 0,
        blizzDispellable = 0,
        trackerMethod = "none",
        trackerTypes = "none",
        condHintSource = "none",
        condHintTypes = "none",
        sweep = "OFF",
        sweepSource = "none",
        sweepRGB = "none",
    }
    local typedOrder = {}
    local typedSeen = {}
    local entrySeenByIID = {}
    local cacheToken = ResolveFocusCacheUnitToken(unit)
    local resolveUnit = cacheToken or unit
    local blizzEntry = cacheToken and _focusBlizzAuraCache[cacheToken] or nil

    if cacheToken then
        state.blizzToken = cacheToken
    end
    if blizzEntry then
        state.blizzDebuffs = CountFocusBlizzAuraSet(blizzEntry.debuffs)
        state.blizzDispellable = CountFocusBlizzAuraSet(blizzEntry.dispellable)
    end

    local function AddTyped(enum)
        local normalized = NormalizeFocusHazardEnum(enum)
        if normalized and normalized ~= FOCUS_HAZARD_ENUM.Unknown then
            state.typed = state.typed + 1
            if not typedSeen[normalized] then
                typedSeen[normalized] = true
                typedOrder[#typedOrder + 1] = normalized
            end
        end
        return normalized
    end

    local function AddEntry(iconToken, enum, auraIID, auraIndex, stackCount)
        if auraIID and entrySeenByIID[auraIID] then
            return
        end
        local hasIcon = CanUseFocusIconToken(iconToken)
        if (#state.entries < FOCUS_DEBUFF_PREVIEW.maxIcons) and (hasIcon or enum) then
            state.entries[#state.entries + 1] = {
                icon = hasIcon and iconToken or nil,
                enum = NormalizeFocusHazardEnum(enum),
                auraInstanceID = auraIID,
                auraIndex = auraIndex,
                stackCount = stackCount,
            }
            if auraIID then
                entrySeenByIID[auraIID] = true
            end
        end
    end

    for i = 1, 40 do
        local aura = nil
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local okAura, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
            if not okAura then
                break
            end
            aura = data
        else
            local name, icon, count, debuffType, _, _, _, _, _, spellID = UnitDebuff(unit, i)
            if not name then
                break
            end
            aura = {
                name = name,
                icon = icon,
                applications = count,
                debuffType = debuffType,
                dispelName = debuffType,
                spellId = spellID,
                spellID = spellID,
            }
        end
        if not aura then
            break
        end

        state.scanned = state.scanned + 1
        if ShouldIgnoreFocusLockoutDebuff(aura) then
            state.ignored = state.ignored + 1
        else
            state.totalDebuffs = state.totalDebuffs + 1
            local auraIID = aura.auraInstanceID
            local enum = nil

            enum = select(1, ResolveFocusHazardFromAura(resolveUnit, aura))
            if (not enum or enum == FOCUS_HAZARD_ENUM.Unknown) and auraIID then
                local hint = blizzEntry and blizzEntry.types and blizzEntry.types[auraIID] or nil
                enum = select(1, ResolveFocusHazardFromAuraInstanceID(resolveUnit, auraIID, hint))
                    or enum
            end

            -- In combat, when type resolution fails, extract the secret color
            -- from the main color curve. The apply phase can render secret RGBA
            -- values via SetVertexColor even when we can't determine the enum.
            if (not enum or enum == FOCUS_HAZARD_ENUM.Unknown)
                and auraIID
                and state.inRestricted == "YES"
                and not state.secretPrimaryColor
                and not IsFocusKnownNonTypedIID(auraIID) then
                local mainCurve = GetFocusHazardMainColorCurve()
                if mainCurve and C_UnitAuras and C_UnitAuras.GetAuraDispelTypeColor then
                    local okColor, borderColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, resolveUnit, auraIID, mainCurve)
                    if okColor and borderColor and borderColor.GetRGBA then
                        local okRGBA, sr, sg, sb = pcall(borderColor.GetRGBA, borderColor)
                        if okRGBA and sr ~= nil and sg ~= nil and sb ~= nil then
                            state.secretPrimaryColor = { sr, sg, sb, secret = true }
                        end
                    end
                end
            end

            AddTyped(enum)

            local iconToken = aura.icon
            if (not CanUseFocusIconToken(iconToken)) and auraIID and blizzEntry and blizzEntry.icons then
                iconToken = blizzEntry.icons[auraIID]
            end
            local stackCount = aura.applications or aura.stackCount or aura.count
            if (not stackCount) and auraIID and blizzEntry and blizzEntry.stacks then
                stackCount = blizzEntry.stacks[auraIID]
            end

            AddEntry(
                iconToken,
                enum,
                auraIID,
                i,
                stackCount
            )
        end
    end

    if blizzEntry then
        local blizzTyped = {}
        local blizzCount = 0
        local blizzSeenByIID = {}

        local function AddFromAuraSet(auraSet)
            if type(auraSet) ~= "table" then
                return
            end
            for iid in pairs(auraSet) do
                if not blizzSeenByIID[iid] then
                    blizzSeenByIID[iid] = true
                    local spellID = blizzEntry.spellIDs and blizzEntry.spellIDs[iid] or nil
                    if not (spellID and FOCUS_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS[spellID]) then
                        blizzCount = blizzCount + 1
                        local hint = blizzEntry.types and blizzEntry.types[iid] or nil
                        local enum = select(1, ResolveFocusHazardFromAuraInstanceID(resolveUnit, iid, hint))
                        if enum and enum ~= FOCUS_HAZARD_ENUM.Unknown then
                            blizzTyped[enum] = true
                        end
                        local iconToken = blizzEntry.icons and blizzEntry.icons[iid] or nil
                        local stackCount = blizzEntry.stacks and blizzEntry.stacks[iid] or nil
                        AddEntry(iconToken, enum, iid, nil, stackCount)
                    end
                end
            end
        end

        AddFromAuraSet(blizzEntry.dispellable)
        AddFromAuraSet(blizzEntry.debuffs)

        if blizzCount > state.totalDebuffs then
            state.totalDebuffs = blizzCount
        end

        if #typedOrder < 2 then
            for _, enum in ipairs(FOCUS_HAZARD_PRIORITY) do
                if blizzTyped[enum] and not typedSeen[enum] then
                    typedSeen[enum] = true
                    typedOrder[#typedOrder + 1] = enum
                end
            end
        end
    end

    if #typedOrder < 2 and IsFocusUnitPlayer(unit) then
        local condPrimary, _, condSource, condSecondary = GetFocusHazardHintFromConditionBorder(unit)
        local condLabels = {}
        local function AddCondHint(enum)
            local normalized = NormalizeFocusHazardEnum(enum)
            if normalized and normalized ~= FOCUS_HAZARD_ENUM.Unknown then
                if not typedSeen[normalized] then
                    typedSeen[normalized] = true
                    typedOrder[#typedOrder + 1] = normalized
                end
                condLabels[#condLabels + 1] = FOCUS_HAZARD_LABELS[normalized] or tostring(normalized)
            end
        end
        AddCondHint(condPrimary)
        if #typedOrder < 2 then
            AddCondHint(condSecondary)
        end
        if #condLabels > 0 then
            state.condHintSource = FocusSafeToString(condSource or "condborder")
            state.condHintTypes = table.concat(condLabels, "+")
        end
    end

    if #typedOrder < 2 then
        local trackerLabels = {}
        local trackerMethod = "none"
        local trackerMap = {
            { FOCUS_HAZARD_ENUM.Magic,   { 1, "MAGIC", "type_magic" }, "MAGIC" },
            { FOCUS_HAZARD_ENUM.Curse,   { 2, "CURSE", "type_curse" }, "CURSE" },
            { FOCUS_HAZARD_ENUM.Disease, { 3, "DISEASE", "type_disease" }, "DISEASE" },
            { FOCUS_HAZARD_ENUM.Poison,  { 4, "POISON", "type_poison" }, "POISON" },
            { FOCUS_HAZARD_ENUM.Bleed,   { 6, 9, 11, "BLEED", "ENRAGE", "type_bleed", "type_enrage" }, "BLEED" },
        }
        for _, item in ipairs(trackerMap) do
            if #typedOrder >= 2 then
                break
            end
            local enum, codes, label = item[1], item[2], item[3]
            local matched = false
            for _, code in ipairs(codes) do
                local isActive, method = FocusTrackerHasTypeActive(resolveUnit, code)
                if method and method ~= "none" and trackerMethod == "none" then
                    trackerMethod = method
                end
                if isActive then
                    matched = true
                    break
                end
            end
            if matched then
                if not typedSeen[enum] then
                    typedSeen[enum] = true
                    typedOrder[#typedOrder + 1] = enum
                end
                trackerLabels[#trackerLabels + 1] = label
            end
        end
        if #trackerLabels > 0 then
            state.trackerTypes = table.concat(trackerLabels, "+")
            state.trackerMethod = trackerMethod
        end
    end

    if state.typed == 0 and #typedOrder > 0 then
        state.typed = #typedOrder
    end

    if #typedOrder >= 1 then
        state.primary = typedOrder[1]
    elseif state.totalDebuffs > 0 then
        state.primary = FOCUS_HAZARD_ENUM.Unknown
    end
    if #typedOrder >= 2 then
        state.secondary = typedOrder[2]
    elseif state.totalDebuffs > 1 then
        state.secondary = FOCUS_HAZARD_ENUM.Unknown
    end

    if state.inRestricted == "NO" then
        RefreshFocusPrecombatNonTypedCache(resolveUnit)
    end

    return state
end

local function ApplyFocusDebuffStickyFallback(frame, primaryEnum, primaryColor, inRestricted)
    local now = (GetTime and GetTime()) or 0
    local normalized = NormalizeFocusHazardEnum(primaryEnum)
    if normalized and normalized ~= FOCUS_HAZARD_ENUM.Unknown and type(primaryColor) == "table" then
        frame._muiFocusDebuffStickyAt = now
        frame._muiFocusDebuffStickyPrimary = normalized
        frame._muiFocusDebuffStickyColor = CloneFocusColor(primaryColor)
        return normalized, primaryColor, false
    end
    if inRestricted ~= "YES" then
        return normalized, primaryColor, false
    end
    local stickyAt = tonumber(frame._muiFocusDebuffStickyAt) or 0
    local stickyPrimary = NormalizeFocusHazardEnum(frame._muiFocusDebuffStickyPrimary)
    local stickyColor = CloneFocusColor(frame._muiFocusDebuffStickyColor)
    if stickyPrimary and stickyColor and stickyAt > 0 and (now - stickyAt) <= FOCUS_HAZARD_STICKY_SEC then
        return stickyPrimary, stickyColor, true
    end
    return normalized, primaryColor, false
end

local function FormatFocusColorForDiag(color)
    if type(color) ~= "table" then
        return "none"
    end
    if IsFocusSecretColor(color) then
        return "secret"
    end
    local r = CoerceFocusTintChannel(color[1])
    local g = CoerceFocusTintChannel(color[2])
    local b = CoerceFocusTintChannel(color[3])
    if r == nil or g == nil or b == nil then
        return "none"
    end
    return string.format("%.3f,%.3f,%.3f", r, g, b)
end

local function GetPlayerCondTintSnapshotForFocusDiag()
    local snap = {
        active = false,
        enum = nil,
        label = "NONE",
        source = "none",
        rgb = "none",
    }
    local frame = _G.MidnightUI_PlayerFrame
    if not frame then
        snap.source = "playerframe-unavailable"
        return snap
    end

    snap.active = (frame._muiCondTintActive == true)
    snap.source = FocusSafeToString(frame._muiCondTintSource or "none")
    snap.enum = NormalizeFocusHazardEnum(frame._muiCondTintSource)
    snap.label = GetFocusHazardLabel(snap.enum)

    if frame._muiCondTintSecret == true and frame._muiCondTintHasColor == true then
        snap.rgb = "secret"
        return snap
    end

    local r = CoerceFocusTintChannel(frame._muiCondTintR)
    local g = CoerceFocusTintChannel(frame._muiCondTintG)
    local b = CoerceFocusTintChannel(frame._muiCondTintB)
    if r ~= nil and g ~= nil and b ~= nil then
        snap.rgb = string.format("%.3f,%.3f,%.3f", r, g, b)
    end
    return snap
end

local function IsFocusDiagInterestingState(state, playerTint)
    local focusPrimary = NormalizeFocusHazardEnum(state and state.primary)
    local playerPrimary = NormalizeFocusHazardEnum(playerTint and playerTint.enum)

    if focusPrimary == FOCUS_HAZARD_ENUM.Poison or focusPrimary == FOCUS_HAZARD_ENUM.Bleed or focusPrimary == FOCUS_HAZARD_ENUM.Unknown then
        return true
    end
    if playerPrimary == FOCUS_HAZARD_ENUM.Poison or playerPrimary == FOCUS_HAZARD_ENUM.Bleed or playerPrimary == FOCUS_HAZARD_ENUM.Unknown then
        return true
    end
    if (state and ((state.totalDebuffs or 0) > 0 or (state.blizzDebuffs or 0) > 0 or (state.typed or 0) > 0)) then
        return true
    end
    if playerTint and playerTint.active == true then
        return true
    end
    return false
end

local function BuildFocusTraceSignature(state, playerTint)
    return table.concat({
        tostring((state and state.inRestricted) or "NO"),
        GetFocusHazardLabel(state and state.primary),
        tostring((state and state.primarySource) or "none"),
        tostring((state and state.primaryRGB) or "none"),
        GetFocusHazardLabel(state and state.secondary),
        tostring((state and state.typed) or 0),
        tostring((state and state.totalDebuffs) or 0),
        tostring((state and state.blizzDebuffs) or 0),
        tostring((state and state.condHintTypes) or "none"),
        tostring((playerTint and playerTint.active) and "ON" or "OFF"),
        tostring((playerTint and playerTint.label) or "NONE"),
        tostring((playerTint and playerTint.source) or "none"),
        tostring((playerTint and playerTint.rgb) or "none"),
    }, "|")
end

local function BuildFocusCompactDiagMessage(state, source, playerTint)
    local compare = "N/A"
    local focusEnum = NormalizeFocusHazardEnum(state and state.primary)
    local playerEnum = NormalizeFocusHazardEnum(playerTint and playerTint.enum)
    if playerTint and playerTint.active == true and playerEnum and playerEnum ~= FOCUS_HAZARD_ENUM.Unknown then
        if focusEnum == playerEnum then
            compare = "MATCH"
        elseif (not focusEnum) or focusEnum == FOCUS_HAZARD_ENUM.Unknown then
            compare = "FOCUS_UNTYPED"
        else
            compare = "MISMATCH"
        end
    end

    return table.concat({
        "trace src=" .. FocusSafeToString(source or "unknown"),
        "focusPrimary=" .. GetFocusHazardLabel(state and state.primary),
        "focusSrc=" .. tostring((state and state.primarySource) or "none"),
        "focusRGB=" .. tostring((state and state.primaryRGB) or "none"),
        "focusTyped=" .. tostring((state and state.typed) or 0) .. "/" .. tostring((state and state.totalDebuffs) or 0),
        "focusHints=" .. tostring((state and state.condHintTypes) or "none"),
        "playerTint=" .. tostring((playerTint and playerTint.active) and "ON" or "OFF"),
        "playerType=" .. tostring((playerTint and playerTint.label) or "NONE"),
        "playerSrc=" .. tostring((playerTint and playerTint.source) or "none"),
        "playerRGB=" .. tostring((playerTint and playerTint.rgb) or "none"),
        "compare=" .. compare,
        "restricted=" .. tostring((state and state.inRestricted) or "NO"),
    }, " ")
end

local function BuildFocusLiveDiagMessage(state, source)
    return table.concat({
        "live unit=" .. tostring(state and state.unit or "nil"),
        "restricted=" .. tostring(state and state.inRestricted or "NO"),
        "primary=" .. GetFocusHazardLabel(state and state.primary),
        "primarySrc=" .. tostring((state and state.primarySource) or "none"),
        "primaryRGB=" .. tostring((state and state.primaryRGB) or "none"),
        "secondary=" .. GetFocusHazardLabel(state and state.secondary),
        "scanned=" .. tostring((state and state.scanned) or 0),
        "typed=" .. tostring((state and state.typed) or 0),
        "ignored=" .. tostring((state and state.ignored) or 0),
        "totalDebuffs=" .. tostring((state and state.totalDebuffs) or 0),
        "blizzToken=" .. tostring((state and state.blizzToken) or "none"),
        "blizzDebuffs=" .. tostring((state and state.blizzDebuffs) or 0),
        "blizzDispellable=" .. tostring((state and state.blizzDispellable) or 0),
        "trackerMethod=" .. tostring((state and state.trackerMethod) or "none"),
        "trackerTypes=" .. tostring((state and state.trackerTypes) or "none"),
        "condHintSrc=" .. tostring((state and state.condHintSource) or "none"),
        "condHintTypes=" .. tostring((state and state.condHintTypes) or "none"),
        "icons=" .. tostring((state and state.entries and #state.entries) or 0),
        "sweep=" .. tostring((state and state.sweep) or "OFF"),
        "sweepSrc=" .. tostring((state and state.sweepSource) or "none"),
        "sweepRGB=" .. tostring((state and state.sweepRGB) or "none"),
        "src=" .. FocusSafeToString(source or "unknown"),
    }, " ")
end

local function FormatFocusRenderRGBA(r, g, b, a)
    if r == nil and g == nil and b == nil and a == nil then
        return "none"
    end
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) or IsSecretValue(a) then
        return "secret"
    end
    local rn = CoerceFocusTintChannel(r)
    local gn = CoerceFocusTintChannel(g)
    local bn = CoerceFocusTintChannel(b)
    local an = CoerceFocusTintChannel(a)
    if rn ~= nil and gn ~= nil and bn ~= nil then
        if an ~= nil then
            return string.format("%.3f,%.3f,%.3f,%.3f", rn, gn, bn, an)
        end
        return string.format("%.3f,%.3f,%.3f", rn, gn, bn)
    end
    return table.concat({
        FocusSafeToString(r),
        FocusSafeToString(g),
        FocusSafeToString(b),
        FocusSafeToString(a),
    }, ",")
end

local function GetFocusBarRenderSnapshot(bar)
    local snap = {
        sb = "none",
        tex = "none",
        grad = "0/0/0",
    }
    if not bar then
        return snap
    end

    if bar.GetStatusBarColor then
        local okSB, sr, sg, sb, sa = pcall(bar.GetStatusBarColor, bar)
        if okSB then
            snap.sb = FormatFocusRenderRGBA(sr, sg, sb, sa)
        else
            snap.sb = "error"
        end
    end

    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if tex and tex.GetVertexColor then
        local okTex, tr, tg, tb, ta = pcall(tex.GetVertexColor, tex)
        if okTex then
            snap.tex = FormatFocusRenderRGBA(tr, tg, tb, ta)
        else
            snap.tex = "error"
        end
    else
        snap.tex = "missing"
    end

    local topShown = (bar._muiTopHighlight and bar._muiTopHighlight.IsShown and bar._muiTopHighlight:IsShown()) and "1" or "0"
    local botShown = (bar._muiBottomShade and bar._muiBottomShade.IsShown and bar._muiBottomShade:IsShown()) and "1" or "0"
    local specShown = (bar._muiSpecular and bar._muiSpecular.IsShown and bar._muiSpecular:IsShown()) and "1" or "0"
    snap.grad = table.concat({ topShown, botShown, specShown }, "/")

    return snap
end

local function EmitFocusRenderDiag(frame, stage, state, source)
    if not IsFocusDebuffPreviewDiagEnabled() then
        return
    end
    if not frame then
        return
    end

    local playerTint = GetPlayerCondTintSnapshotForFocusDiag()
    local primaryEnum = (state and state.primary) or frame._muiFocusDebuffPrimaryLast
    local primarySrc = (state and state.primarySource) or frame._muiFocusDebuffSourceLast or "none"
    local primaryRGB = (state and state.primaryRGB) or frame._muiFocusDebuffRGBLast or "none"
    local hb = GetFocusBarRenderSnapshot(frame.healthBar)
    local pb = GetFocusBarRenderSnapshot(frame.powerBar)
    local previewState = (frame._muiFocusDebuffPreviewActive == true) and "ON" or "OFF"
    local msg = table.concat({
        "render stage=" .. tostring(stage or "unknown"),
        "src=" .. FocusSafeToString(source or "unknown"),
        "preview=" .. previewState,
        "focusPrimary=" .. GetFocusHazardLabel(primaryEnum),
        "focusSrc=" .. FocusSafeToString(primarySrc),
        "focusRGB=" .. FocusSafeToString(primaryRGB),
        "playerTint=" .. tostring((playerTint and playerTint.active) and "ON" or "OFF"),
        "playerSrc=" .. tostring((playerTint and playerTint.source) or "none"),
        "playerRGB=" .. tostring((playerTint and playerTint.rgb) or "none"),
        "hbSB=" .. hb.sb,
        "hbTex=" .. hb.tex,
        "hbGrad=" .. hb.grad,
        "pbSB=" .. pb.sb,
        "pbTex=" .. pb.tex,
        "pbGrad=" .. pb.grad,
    }, " ")
    local sig = table.concat({
        tostring(stage or "unknown"),
        tostring(source or "unknown"),
        previewState,
        GetFocusHazardLabel(primaryEnum),
        FocusSafeToString(primarySrc),
        FocusSafeToString(primaryRGB),
        tostring((playerTint and playerTint.active) and "ON" or "OFF"),
        tostring((playerTint and playerTint.source) or "none"),
        tostring((playerTint and playerTint.rgb) or "none"),
        hb.sb,
        hb.tex,
        hb.grad,
        pb.sb,
        pb.tex,
        pb.grad,
    }, "|")
    if frame._muiFocusRenderSig == sig then
        return
    end
    frame._muiFocusRenderSig = sig
    FocusDiag(msg)
end

local function ApplyFocusDebuffPreviewState(frame, state)
    local preview = EnsureFocusDebuffPreviewWidgets(frame)
    if not preview then
        return
    end

    local unit = "focus"
    if not UnitExists(unit) then
        ClearFocusDebuffPreview(frame, "NO_FOCUS_UNIT", state and state._source or "unknown")
        return
    end

    local totalDebuffs = (state and state.totalDebuffs) or 0
    local typedDebuffs = (state and state.typed) or 0
    local entries = (state and state.entries) or {}
    local totalEntries = (type(entries) == "table") and #entries or 0

    local primary = state and state.primary
    local secondary = state and state.secondary
    local inRestricted = state and state.inRestricted or "NO"

    if (not primary) and totalEntries > 0 then
        primary = FOCUS_HAZARD_ENUM.Unknown
    end
    if (not secondary) and totalEntries > 1 then
        secondary = FOCUS_HAZARD_ENUM.Unknown
    end

    local primaryColor = nil
    local primarySource = "PRIMARY_ENUM"
    if primary then
        primaryColor = GetFocusHazardColor(primary)
    end

    local hintedPrimary, hintedColor, hintSource, hintedSecondary, hintedSecondaryColor
    if (not primary)
        or NormalizeFocusHazardEnum(primary) == FOCUS_HAZARD_ENUM.Unknown
        or totalDebuffs <= 0 then
        hintedPrimary, hintedColor, hintSource, hintedSecondary, hintedSecondaryColor = GetFocusHazardHintFromConditionBorder(unit)
        if hintedPrimary then
            primary = NormalizeFocusHazardEnum(hintedPrimary) or primary or FOCUS_HAZARD_ENUM.Unknown
            if hintSource then
                primarySource = FocusSafeToString(hintSource)
            end
        end
        if type(hintedColor) == "table" then
            primaryColor = CloneFocusColor(hintedColor) or hintedColor
        end
        if (not secondary) and hintedSecondary then
            secondary = NormalizeFocusHazardEnum(hintedSecondary)
        end
    end

    -- When primary is Unknown but we have a secret color from the curve,
    -- use the secret color instead of the static purple Unknown color.
    -- The apply phase at line 3577 detects secret colors via IsFocusSecretColor().
    if NormalizeFocusHazardEnum(primary) == FOCUS_HAZARD_ENUM.Unknown
        and state and type(state.secretPrimaryColor) == "table"
        and state.inRestricted == "YES" then
        primaryColor = state.secretPrimaryColor
        primarySource = "SECRET_CURVE_COLOR"
    end

    if inRestricted == "YES"
        and typedDebuffs == 0
        and (totalDebuffs > 0 or primary ~= nil)
        and NormalizeFocusHazardEnum(primary) == FOCUS_HAZARD_ENUM.Unknown then
        local allowUnknown, allowSource = ShouldAllowFocusUnknownPrimaryTint(unit)
        if not allowUnknown then
            EmitFocusTransitionDiag(frame, "ALLOW_UNKNOWN",
                table.concat({
                    "allowUnknown=NO",
                    "reason=" .. FocusSafeToString(allowSource or "condborder-no-primary"),
                    "src=" .. FocusSafeToString(state and state._source or "unknown"),
                    "typed=" .. tostring(typedDebuffs),
                    "totalDebuffs=" .. tostring(totalDebuffs),
                    "entries=" .. tostring(totalEntries),
                    "primary=" .. GetFocusHazardLabel(primary),
                    GetFocusIdentityDiag(),
                    GetPlayerTintQuickDiag(),
                }, " "))
            state.primary = nil
            state.secondary = nil
            state.primarySource = FocusSafeToString(allowSource or "condborder-no-primary")
            state.primaryRGB = "none"
            state.sweep = "OFF"
            state.sweepSource = "none"
            state.sweepRGB = "none"
            ClearFocusDebuffPreview(frame, "ALLOW_UNKNOWN_FALSE:" .. FocusSafeToString(allowSource or "condborder-no-primary"), state and state._source or "unknown")
            return
        end
    end

    if (not primaryColor) and primary and NormalizeFocusHazardEnum(primary) ~= FOCUS_HAZARD_ENUM.Unknown then
        primaryColor = GetFocusHazardColor(primary)
    end

    if (not primaryColor) and IsFocusUnitPlayer(unit) then
        -- CondBorder can briefly report NO_PRIMARY while Player CondTint is still ON (RGB_OVERLAY).
        -- Mirror PlayerFrame behavior by honoring the live player tint as a last fallback.
        local frameEnum, frameColor, frameSource = GetFocusHintFromPlayerFrameCondTint(unit)
        if type(frameColor) == "table" then
            primary = NormalizeFocusHazardEnum(frameEnum) or FOCUS_HAZARD_ENUM.Unknown
            primaryColor = CloneFocusColor(frameColor) or frameColor
            primarySource = "playerframe-direct-fallback:" .. FocusSafeToString(frameSource or "unknown")
        end
    end

    if not primaryColor and (totalDebuffs > 0 or totalEntries > 0 or primary ~= nil) then
        primary = primary or FOCUS_HAZARD_ENUM.Unknown
        primaryColor = GetFocusHazardColor(FOCUS_HAZARD_ENUM.Unknown)
        if primarySource == "PRIMARY_ENUM" then
            primarySource = "UNKNOWN_FALLBACK"
        end
    end

    local normalizedPrimary = NormalizeFocusHazardEnum(primary)
    if normalizedPrimary and normalizedPrimary ~= FOCUS_HAZARD_ENUM.Unknown then
        if (not primaryColor) or IsFocusSecretColor(primaryColor) then
            local canonical = GetFocusHazardColor(normalizedPrimary)
            if type(canonical) == "table" then
                primaryColor = { canonical[1], canonical[2], canonical[3] }
                if type(primarySource) == "string" and string.find(primarySource, "fallback", 1, true) then
                    primarySource = primarySource .. "+typed-canonical"
                end
            end
        end
    end

    if not primaryColor then
        ClearFocusDebuffPreview(frame, "NO_PRIMARY_COLOR", state and state._source or "unknown")
        return
    end

    local stickyApplied
    primary, primaryColor, stickyApplied = ApplyFocusDebuffStickyFallback(frame, primary, primaryColor, inRestricted)
    if stickyApplied then
        primarySource = "STICKY"
    end

    if primaryColor and preview.overlay then
        preview.overlay:SetBackdropBorderColor(0, 0, 0, 0)
        if preview.overlay.fill then
            preview.overlay.fill:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 0.14)
        end
        if preview.overlay.brackets then
            for _, bracket in ipairs(preview.overlay.brackets) do
                bracket:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 1)
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
        ClearFocusDebuffPreview(frame, "NO_OVERLAY_COLOR", state and state._source or "unknown")
        return
    end

    local hasOverlap = (totalDebuffs > 1) or (totalEntries > 1) or (secondary ~= nil and secondary ~= primary)
    local secondaryColor = nil
    if hasOverlap then
        if type(hintedSecondaryColor) == "table" then
            secondaryColor = CloneFocusColor(hintedSecondaryColor) or hintedSecondaryColor
        else
            secondaryColor = GetFocusHazardColor(secondary)
        end
        if (not secondaryColor) or NormalizeFocusHazardEnum(secondary) == FOCUS_HAZARD_ENUM.Unknown then
            local _, hintSecondaryColor = GetFocusSecondaryHintFromConditionBorder(unit)
            if hintSecondaryColor then
                secondaryColor = hintSecondaryColor
            end
        end
        if not secondaryColor then
            secondaryColor = primaryColor
        end
    end

    if secondaryColor and preview.secondary then
        preview.secondary:SetBackdropBorderColor(secondaryColor[1], secondaryColor[2], secondaryColor[3], 0.95)
        preview.secondary:Show()
    elseif preview.secondary then
        preview.secondary:SetBackdropBorderColor(0, 0, 0, 0)
        preview.secondary:Hide()
    end

    LayoutFocusDebuffSweep(preview, frame)
    if hasOverlap and secondaryColor then
        SetFocusDebuffSweepColor(preview, secondary or primary, secondaryColor)
        SetFocusDebuffSweepVisible(preview, true)
        state.sweep = "ON"
        if secondary and NormalizeFocusHazardEnum(secondary) ~= FOCUS_HAZARD_ENUM.Unknown then
            state.sweepSource = "SECONDARY_ENUM"
        elseif IsFocusSecretColor(secondaryColor) then
            state.sweepSource = "SECRET_FALLBACK"
        else
            state.sweepSource = "PRIMARY_FALLBACK"
        end
        state.sweepRGB = FormatFocusColorForDiag(secondaryColor)
    else
        SetFocusDebuffSweepVisible(preview, false)
        state.sweep = "OFF"
        state.sweepSource = "none"
        state.sweepRGB = "none"
    end

    local shownIcons = 0
    local iconEntryCount = (type(entries) == "table") and #entries or 0
    local frameWidth = tonumber(frame.GetWidth and frame:GetWidth()) or tonumber(config.width) or 320
    local iconSize = FOCUS_DEBUFF_PREVIEW.iconSize
    local maxVisibleIcons = FOCUS_DEBUFF_PREVIEW.maxIcons
    if frameWidth <= 220 then
        iconSize = 13
        maxVisibleIcons = 1
    elseif frameWidth <= 280 then
        iconSize = 15
        maxVisibleIcons = 2
    end
    if maxVisibleIcons > FOCUS_DEBUFF_PREVIEW.maxIcons then
        maxVisibleIcons = FOCUS_DEBUFF_PREVIEW.maxIcons
    end
    local iconsToShow = math.min(iconEntryCount, maxVisibleIcons, FOCUS_DEBUFF_PREVIEW.maxIcons)
    local overflowCount = math.max(0, iconEntryCount - iconsToShow)

    if preview.iconButtons then
        for i = 1, FOCUS_DEBUFF_PREVIEW.maxIcons do
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
                    local stackText = NormalizeFocusAuraStackCount(entry.stackCount)
                    if overflowCount > 0 and i == iconsToShow then
                        stackText = "+" .. tostring(overflowCount)
                    end
                    btn.countText:SetText(stackText)
                end

                local appliedAtlas = false
                local iconToken = entry.icon
                if CanUseFocusIconToken(iconToken) then
                    if btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(iconToken)
                        SetFocusIconTexCoord(btn.icon, false)
                    end
                else
                    local atlas = GetFocusHazardIconAtlas(entry.enum or primary)
                    if atlas and btn.icon and btn.icon.SetAtlas then
                        local okAtlas = pcall(btn.icon.SetAtlas, btn.icon, atlas, false)
                        if okAtlas then
                            SetFocusIconTexCoord(btn.icon, true)
                            appliedAtlas = true
                        end
                    end
                    if not appliedAtlas and btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(FOCUS_DEBUFF_PREVIEW.placeholderIcon)
                        SetFocusIconTexCoord(btn.icon, false)
                    end
                end

                local iconColor = GetFocusHazardColor(entry.enum or primary)
                if IsFocusSecretColor(primaryColor) then
                    local entryEnum = NormalizeFocusHazardEnum(entry.enum)
                    if (not entryEnum) or entryEnum == FOCUS_HAZARD_ENUM.Unknown then
                        iconColor = { primaryColor[1], primaryColor[2], primaryColor[3] }
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
            SetFocusHPTextInset(frame, stripWidth + 4)
        else
            preview.iconHolder:Hide()
            SetFocusHPTextInset(frame, 0)
        end
    end

    if frame.healthBar and frame.powerBar then
        local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
        if style == "Balanced" then style = "Gradient" end
        if IsFocusSecretColor(primaryColor) then
            -- Mirror the proven ToT secret-tint path: neutral base + secret payload on bar textures.
            -- This avoids class/resource base colors (e.g. DH green) dominating the visible tint.
            frame.healthBar:SetStatusBarColor(FOCUS_DEBUFF_TINT_BASE_MUL, FOCUS_DEBUFF_TINT_BASE_MUL, FOCUS_DEBUFF_TINT_BASE_MUL, 1.0)
            frame.powerBar:SetStatusBarColor(FOCUS_DEBUFF_TINT_BASE_MUL, FOCUS_DEBUFF_TINT_BASE_MUL, FOCUS_DEBUFF_TINT_BASE_MUL, 1.0)

            local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
            if hTex and hTex.SetVertexColor then
                hTex:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 1.0)
            end
            if pTex and pTex.SetVertexColor then
                pTex:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 1.0)
            end
            -- Secret payloads can leave previous gradient polish visible as green/yellow.
            -- Keep bars in raw tint mode while unknown/secret is active.
            HidePolishedGradientOnBar(frame.healthBar)
            HidePolishedGradientOnBar(frame.powerBar)
        else
            local hr = primaryColor[1] * FOCUS_DEBUFF_TINT_BASE_MUL
            local hg = primaryColor[2] * FOCUS_DEBUFF_TINT_BASE_MUL
            local hb = primaryColor[3] * FOCUS_DEBUFF_TINT_BASE_MUL
            frame.healthBar:SetStatusBarColor(hr, hg, hb, 1.0)
            frame.powerBar:SetStatusBarColor(hr, hg, hb, 1.0)
            local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
            if hTex and hTex.SetVertexColor then
                hTex:SetVertexColor(hr, hg, hb, 1.0)
            end
            if pTex and pTex.SetVertexColor then
                pTex:SetVertexColor(hr, hg, hb, 1.0)
            end
            if style == "Gradient" then
                ApplyPolishedGradientToBar(frame.healthBar, hTex, 0.28, 0.035, 0.32, hr, hg, hb)
                ApplyPolishedGradientToBar(frame.powerBar, pTex, 0.24, 0.03, 0.28, hr, hg, hb)
            end
        end
        if frame.healthBg and frame.healthBg.SetColorTexture then
            if IsFocusSecretColor(primaryColor) then
                -- Secret payload cannot be safely arithmetic'd; keep a neutral dark base.
                frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
            else
                frame.healthBg:SetColorTexture(primaryColor[1] * 0.12, primaryColor[2] * 0.12, primaryColor[3] * 0.12, 0.6)
            end
        end
    end

    frame._muiFocusDebuffPreviewActive = true
    frame._muiFocusDebuffPrimaryLast = primary
    frame._muiFocusDebuffSourceLast = primarySource
    state.primary = primary
    state.secondary = secondary
    state.primarySource = primarySource
    state.primaryRGB = FormatFocusColorForDiag(primaryColor)
    frame._muiFocusDebuffRGBLast = state.primaryRGB
    EmitFocusRenderDiag(frame, "APPLY", state, state and state._source or "unknown")
end

local function UpdateFocusDebuffPreview(frame, source)
    if not frame then
        return
    end
    if not IsFocusDebuffOverlayEnabled() then
        ClearFocusDebuffPreview(frame, "DISABLED_SETTING", source)
        frame._muiFocusDebuffLiveSig = nil
        return
    end
    if not UnitExists("focus") then
        ClearFocusDebuffPreview(frame, "NO_UNIT_EXISTS", source)
        frame._muiFocusDebuffLiveSig = nil
        return
    end

    local okCollect, state = pcall(CollectFocusDebuffPreviewState, "focus")
    if not okCollect then
        FocusDiag("collectError unit=focus src=" .. FocusSafeToString(source or "unknown") .. " err=" .. FocusSafeToString(state))
        return
    end

    if type(state) == "table" then
        state._source = source or "unknown"
    end
    local okApply, applyErr = pcall(ApplyFocusDebuffPreviewState, frame, state)
    if not okApply then
        FocusDiag("applyError unit=focus src=" .. FocusSafeToString(source or "unknown") .. " err=" .. FocusSafeToString(applyErr))
        return
    end

    local playerTint = GetPlayerCondTintSnapshotForFocusDiag()
    local traceSig = BuildFocusTraceSignature(state, playerTint)
    if IsFocusDiagInterestingState(state, playerTint) then
        if frame._muiFocusDebuffLiveSig ~= traceSig then
            frame._muiFocusDebuffLiveSig = traceSig
            FocusDiag(BuildFocusCompactDiagMessage(state, source, playerTint))
        end
    else
        local idleSig = "idle|" .. tostring((playerTint and playerTint.active) and "ON" or "OFF")
        if frame._muiFocusDebuffLiveSig ~= idleSig then
            frame._muiFocusDebuffLiveSig = idleSig
            FocusDiag(BuildFocusCompactDiagMessage(state, source, playerTint))
        end
    end
end

-- =========================================================================
--  UPDATES
-- =========================================================================

local function UpdateHealth(frame, source)
    if not UnitExists("focus") then return end
    FocusLogDebug("AllowProtectedHealth%=" .. tostring(AllowSecretHealthPercent()))

    local playerTint = GetPlayerCondTintSnapshotForFocusDiag()
    local holdBaseTint = IsFocusUnitPlayer("focus") and playerTint and playerTint.active == true
    frame._muiFocusHoldBaseTint = holdBaseTint == true
    EmitFocusTransitionDiag(frame, "GATE_HEALTH",
        table.concat({
            "gate stage=BASE_HEALTH",
            "src=" .. FocusSafeToString(source or "unknown"),
            "holdBaseTint=" .. ((holdBaseTint and "YES") or "NO"),
            "preview=" .. ((frame._muiFocusDebuffPreviewActive == true) and "ON" or "OFF"),
            "focusPrimaryLast=" .. GetFocusHazardLabel(frame._muiFocusDebuffPrimaryLast),
            "focusSrcLast=" .. FocusSafeToString(frame._muiFocusDebuffSourceLast or "none"),
            "focusRGBLast=" .. FocusSafeToString(frame._muiFocusDebuffRGBLast or "none"),
            GetFocusIdentityDiag(),
            GetPlayerTintQuickDiag(),
        }, " "))

    local r, g, b = GetUnitColor("focus")
    local isDead = IsUnitActuallyDead("focus")
    local hasIncomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection("focus") or false
    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    if not holdBaseTint then
        ApplyFocusBaseColorToBar(frame.healthBar, r, g, b, style, 0.28, 0.035, 0.32)
    end
    frame.nameText:SetTextColor(r, g, b, 1)
    SafeSetFontStringText(frame.nameText, UnitName("focus") or "")

    local level = UnitLevel("focus")
    local levelNum = CoerceNumber(level)
    if levelNum == -1 then
        SafeSetFontStringText(frame.levelText, "??")
    elseif levelNum ~= nil then
        SafeSetFontStringText(frame.levelText, levelNum)
    else
        SafeSetFontStringText(frame.levelText, "")
    end

    local current = UnitHealth("focus")
    local max = UnitHealthMax("focus")
    if not isDead and not hasIncomingRes then
        local okZero, isZero = pcall(function() return current <= 0 end)
        local okMaxPos, maxPos = pcall(function() return max > 0 end)
        if okZero and isZero and okMaxPos and maxPos then
            isDead = true
        end
    end

    if frame.healthBg and not holdBaseTint then
        frame.healthBg:SetColorTexture(r * 0.15, g * 0.15, b * 0.15, 0.6)
    end

    pcall(function()
        frame.healthBar:SetMinMaxValues(0, max)
        frame.healthBar:SetValue(current)
    end)

    local renderedText = nil
    local pct = GetDisplayHealthPercent("focus")
    if pct ~= nil then
        local ok, text = pcall(function()
            return string.format("%.0f%%", pct)
        end)
        if ok and text then
            renderedText = text
        else
            local pctNum = CoerceNumber(pct)
            if type(pctNum) == "number" then
                local okNum, textNum = pcall(function()
                    return string.format("%.0f%%", pctNum)
                end)
                if okNum and textNum then
                    renderedText = textNum
                end
            end
        end
    end
    if not renderedText then
        local fallbackPct = GetSafeFallbackPercent(current, max)
        if type(fallbackPct) == "number" then
            local ok, text = pcall(function()
                return string.format("%.0f%%", fallbackPct)
            end)
            if ok and text then
                renderedText = text
            end
        end
    end
    if renderedText then
        frame.healthText:SetText(renderedText)
    else
        frame.healthText:SetText("")
    end

    if frame.deadIcon then
        if isDead and not hasIncomingRes then
            frame.deadIcon:SetSize(32, 32)
            frame.deadIcon:ClearAllPoints()
            frame.deadIcon:SetPoint("RIGHT", frame.healthContainer, "RIGHT", -28, 0)
            ApplyDeadIconVisualStyle(frame.deadIcon)
            frame.deadIcon:Show()
            frame.healthText:SetText("")
        else
            frame.deadIcon:Hide()
        end
    end

    FocusLogDebug("pctType=" .. FocusSafeToString(type(pct))
        .. " curType=" .. FocusSafeToString(type(current))
        .. " maxType=" .. FocusSafeToString(type(max))
        .. " isDead=" .. FocusSafeToString(isDead)
        .. " incomingRes=" .. FocusSafeToString(hasIncomingRes)
        .. " iconShown=" .. FocusSafeToString(frame.deadIcon and frame.deadIcon:IsShown())
        .. " atlasReady=" .. FocusSafeToString(C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(DEAD_STATUS_ATLAS) ~= nil)
        .. " rendered=" .. FocusSafeToString(renderedText)
        .. " shown=" .. FocusSafeToString(frame.healthText and frame.healthText:GetText()))

    if frame._muiFocusDebuffPreviewActive == true or (playerTint and playerTint.active == true) then
        EmitFocusRenderDiag(frame, "BASE_HEALTH", nil, source or "unknown")
    end

end

local function UpdatePower(frame, source)
    if not UnitExists("focus") then return end

    local playerTint = GetPlayerCondTintSnapshotForFocusDiag()
    local holdBaseTint = IsFocusUnitPlayer("focus") and playerTint and playerTint.active == true
    frame._muiFocusHoldBaseTint = holdBaseTint == true
    EmitFocusTransitionDiag(frame, "GATE_POWER",
        table.concat({
            "gate stage=BASE_POWER",
            "src=" .. FocusSafeToString(source or "unknown"),
            "holdBaseTint=" .. ((holdBaseTint and "YES") or "NO"),
            "preview=" .. ((frame._muiFocusDebuffPreviewActive == true) and "ON" or "OFF"),
            "focusPrimaryLast=" .. GetFocusHazardLabel(frame._muiFocusDebuffPrimaryLast),
            "focusSrcLast=" .. FocusSafeToString(frame._muiFocusDebuffSourceLast or "none"),
            "focusRGBLast=" .. FocusSafeToString(frame._muiFocusDebuffRGBLast or "none"),
            GetFocusIdentityDiag(),
            GetPlayerTintQuickDiag(),
        }, " "))

    local powerType, powerToken = UnitPowerType("focus")
    local token = powerToken or "MANA"
    local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR

    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    if not holdBaseTint then
        ApplyFocusBaseColorToBar(frame.powerBar, color[1], color[2], color[3], style, 0.24, 0.03, 0.28)
    end

    local current = UnitPower("focus", powerType)
    local max = UnitPowerMax("focus", powerType)

    pcall(function()
        frame.powerBar:SetMinMaxValues(0, max)
        frame.powerBar:SetValue(current)
    end)

    local ok, txt = pcall(function()
        return string.format("%s / %s", current, max)
    end)

    if ok and txt then
        frame.powerText:SetText(txt)
    else
        frame.powerText:SetText("")
    end

    if frame._muiFocusDebuffPreviewActive == true or (playerTint and playerTint.active == true) then
        EmitFocusRenderDiag(frame, "BASE_POWER", nil, source or "unknown")
    end
end

local function UpdateAbsorbs(frame)
    if not UnitExists("focus") then return end
    frame.absorbBar:Hide()
end

local function UpdateAll(frame)
    UpdateHealth(frame, "UpdateAll")
    UpdatePower(frame, "UpdateAll")
    UpdateAbsorbs(frame)
    UpdateFocusDebuffPreview(frame, "UpdateAll")
end

local function EnsureFocusDebuffPollTicker()
    if FocusFrameManager._focusDebuffPollTicker then
        return
    end
    if not C_Timer or type(C_Timer.NewTicker) ~= "function" then
        return
    end
    FocusFrameManager._focusDebuffPollTicker = C_Timer.NewTicker(0.5, function()
        if not focusFrame or not focusFrame:IsShown() then
            return
        end
        local okExists, hasFocus = pcall(UnitExists, "focus")
        if not okExists then
            return
        end
        if hasFocus then
            UpdateFocusDebuffPreview(focusFrame, "POLL")
        else
            ClearFocusDebuffPreview(focusFrame, "POLL_NO_FOCUS", "POLL")
            focusFrame._muiFocusDebuffLiveSig = nil
        end
    end)
end

function MidnightUI_RefreshFocusFrame()
    local frame = _G.MidnightUI_FocusFrame
    if frame and frame:IsShown() then
        UpdateAll(frame)
    end
end

local function ApplyFocusPlaceholder(frame)
    if not frame then return end
    if frame.nameText then frame.nameText:SetText("") end
    if frame.levelText then frame.levelText:SetText("") end
    if frame.healthText then frame.healthText:SetText("") end
    if frame.powerText then frame.powerText:SetText("") end
    if frame.healthBar then
        frame.healthBar:SetStatusBarColor(0.3, 0.3, 0.3, 0.6)
        frame.healthBar:SetMinMaxValues(0, 1)
        frame.healthBar:SetValue(0)
    end
    if frame.powerBar then
        frame.powerBar:SetStatusBarColor(0.2, 0.2, 0.2, 0.5)
        frame.powerBar:SetMinMaxValues(0, 1)
        frame.powerBar:SetValue(0)
    end
    if frame.absorbBar then frame.absorbBar:Hide() end
    if frame.deadIcon then frame.deadIcon:Hide() end
    ClearFocusDebuffPreview(frame, "APPLY_PLACEHOLDER", "ApplyFocusPlaceholder")
    frame._muiFocusDebuffLiveSig = nil
end

-- =========================================================================
--  DRAG & LOCKING
-- =========================================================================

function MidnightUI_SetFocusFrameLocked(locked)
    local frame = _G["MidnightUI_FocusFrame"]
    if not frame then
        frame = focusFrame or CreateFocusFrame()
        focusFrame = frame
    end

    if locked then
        frame:EnableMouse(true)
        if frame.dragOverlay then frame.dragOverlay:Hide() end

        if not InCombatLockdown() then
            if RegisterUnitWatch then RegisterUnitWatch(frame) end
        else
            pendingFocusFrameLock = true
        end
    else
        frame:EnableMouse(true)

        if not InCombatLockdown() then
            if UnregisterUnitWatch then UnregisterUnitWatch(frame) end
            frame:Show()

            if UnitExists("focus") then
                UpdateAll(frame)
            else
                ApplyFocusPlaceholder(frame)
            end
        else
            pendingFocusFrameLock = false
        end

        if not frame.dragOverlay then
            local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            overlay:SetAllPoints(); overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30); overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "unit") end
            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER"); label:SetText("FOCUS FRAME"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) frame:StartMoving() end)

            overlay:SetScript("OnDragStop", function(self)
                frame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint()
                local s = frame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                MidnightUISettings.FocusFrame = MidnightUISettings.FocusFrame or {}
                MidnightUISettings.FocusFrame.position = { point, relativePoint, xOfs, yOfs }
            end)
            overlay:SetScript("OnEnter", function()
                local onEnter = frame:GetScript("OnEnter")
                if onEnter then onEnter(frame) end
            end)
            overlay:SetScript("OnLeave", function()
                local onLeave = frame:GetScript("OnLeave")
                if onLeave then onLeave(frame) end
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "FocusFrame")
            end
            frame.dragOverlay = overlay
        end
        if frame.dragOverlay then frame.dragOverlay:Show() end
    end
end

-- =========================================================================
--  EVENTS
-- =========================================================================

FocusFrameManager:RegisterEvent("ADDON_LOADED")
FocusFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
FocusFrameManager:RegisterEvent("PLAYER_FOCUS_CHANGED")
FocusFrameManager:RegisterUnitEvent("UNIT_HEALTH", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_MAXHEALTH", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_POWER_UPDATE", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_MAXPOWER", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_DISPLAYPOWER", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", "focus")
FocusFrameManager:RegisterUnitEvent("UNIT_AURA", "focus")

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function BuildFocusFrameOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.FocusFrame) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Frame")
    b:Checkbox("Enable Focus Frame", s.enabled ~= false, function(v)
        MidnightUISettings.FocusFrame.enabled = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyFocusSettings then
            _G.MidnightUI_Settings.ApplyFocusSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("FocusFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Checkbox("Focus Debuff Overlay", IsFocusDebuffOverlayEnabled(), function(v)
        local combat = EnsureFocusCombatDebuffSettings()
        combat.debuffOverlayFocusEnabled = v and true or false
        if type(MidnightUI_RefreshFocusFrame) == "function" then
            MidnightUI_RefreshFocusFrame()
        end
    end)
    b:Checkbox("Custom Tooltip", s.customTooltip ~= false, function(v)
        MidnightUISettings.FocusFrame.customTooltip = v
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.FocusFrame.scale = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyFocusSettings then
            _G.MidnightUI_Settings.ApplyFocusSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("FocusFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Width", 200, 600, 5, s.width or 380, function(v)
        MidnightUISettings.FocusFrame.width = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyFocusSettings then
            _G.MidnightUI_Settings.ApplyFocusSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("FocusFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Height", 50, 150, 2, s.height or 66, function(v)
        MidnightUISettings.FocusFrame.height = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyFocusSettings then
            _G.MidnightUI_Settings.ApplyFocusSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("FocusFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 0.95, function(v)
        MidnightUISettings.FocusFrame.alpha = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyFocusSettings then
            _G.MidnightUI_Settings.ApplyFocusSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("FocusFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("FocusFrame", { title = "Focus Frame", build = BuildFocusFrameOverlaySettings })
end
FocusFrameManager:RegisterEvent("UNIT_NAME_UPDATE")
FocusFrameManager:RegisterEvent("UNIT_LEVEL")
FocusFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")

FocusFrameManager:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...

    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            if FocusFrame then
                SoftHideBlizzardFocusFrame(FocusFrame)
                if not FocusFrame._muiSoftHidden then
                    FocusFrame._muiSoftHidden = true
                    FocusFrame:HookScript("OnShow", function(self)
                        SoftHideBlizzardFocusFrame(self)
                    end)
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not focusFrame then
            focusFrame = CreateFocusFrame()
        end
        EnsureFocusBlizzAuraHook()
        EnsureFocusDebuffPollTicker()
        if _G.MidnightUI_AttachFocusCastBar then
            _G.MidnightUI_AttachFocusCastBar(focusFrame)
        end

        if MidnightUISettings and MidnightUISettings.FocusFrame and MidnightUISettings.FocusFrame.enabled == false then
            focusFrame:Hide()
            focusFrame:SetAlpha(0)
            return
        end

        if UnitExists("focus") then
            UpdateAll(focusFrame)
            focusFrame:Show()
            focusFrame:SetAlpha((MidnightUISettings and MidnightUISettings.FocusFrame and MidnightUISettings.FocusFrame.alpha) or 0.95)
        end

    elseif event == "PLAYER_FOCUS_CHANGED" then
        if not focusFrame then
            focusFrame = CreateFocusFrame()
        end
        EnsureFocusBlizzAuraHook()

        if MidnightUISettings and MidnightUISettings.FocusFrame and MidnightUISettings.FocusFrame.enabled == false then
            if not InCombatLockdown() then
                if UnregisterUnitWatch then UnregisterUnitWatch(focusFrame) end
                focusFrame:Hide()
            end
            return
        end

        if UnitExists("focus") then
            UpdateAll(focusFrame)
            if not InCombatLockdown() then
                if RegisterUnitWatch then RegisterUnitWatch(focusFrame) end
                focusFrame:Show()
                focusFrame:SetAlpha((MidnightUISettings and MidnightUISettings.FocusFrame and MidnightUISettings.FocusFrame.alpha) or 0.95)
            end
        else
            ApplyFocusPlaceholder(focusFrame)
        end

        local isUnlocked = (focusFrame.dragOverlay and focusFrame.dragOverlay:IsShown())
        if isUnlocked and not InCombatLockdown() then
            focusFrame:Show()
            if not UnitExists("focus") then ApplyFocusPlaceholder(focusFrame) end
        end

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if focusFrame and focusFrame:IsShown() then
            UpdateHealth(focusFrame, event)
            UpdateAbsorbs(focusFrame)
            UpdateFocusDebuffPreview(focusFrame, event)
        end

    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        if focusFrame and focusFrame:IsShown() then
            UpdatePower(focusFrame, event)
            UpdateFocusDebuffPreview(focusFrame, event)
        end

    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        if focusFrame and focusFrame:IsShown() then
            UpdateAbsorbs(focusFrame)
        end

    elseif event == "UNIT_AURA" then
        if focusFrame and focusFrame:IsShown() then
            UpdateFocusDebuffPreview(focusFrame, event)
        end

    elseif event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" then
        if focusFrame and focusFrame:IsShown() and arg1 and UnitIsUnit(arg1, "focus") then
            UpdateHealth(focusFrame, event)
            UpdateFocusDebuffPreview(focusFrame, event)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingBlizzardFocusMouseDisable and FocusFrame then
            SoftHideBlizzardFocusFrame(FocusFrame)
        end
        if pendingFocusFrameLock ~= nil then
            local pending = pendingFocusFrameLock
            pendingFocusFrameLock = nil
            MidnightUI_SetFocusFrameLocked(pending)
        end
        if focusFrame and focusFrame:IsShown() then
            UpdateFocusDebuffPreview(focusFrame, event)
        end
    end
end)
