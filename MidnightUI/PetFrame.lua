-- =============================================================================
-- FILE PURPOSE:     Custom pet unit frame. Replaces Blizzard's PetFrame.
--                   Shows health/power bars for the player's pet/minion with
--                   debuff hazard tint (PET_HAZARD_ENUM) and a health percentage display.
--                   Also re-anchors the hidden Blizzard PetFrame to the custom frame
--                   position so tutorial pointers stay relevant.
-- LOAD ORDER:       Loads after ConditionBorder.lua. PetFrameManager handles ADDON_LOADED
--                   and PET_UI_CLOSE / PET_UI_UPDATE to show/hide the frame.
-- DEFINES:          PetFrameManager (event frame), petFrame (_G.MidnightUI_PetFrame).
--                   Global refresh: MidnightUI_ApplyPetSettings().
-- READS:            MidnightUISettings.PetFrame (if present; falls back to config defaults).
--                   MidnightUISettings.General.allowSecretHealthPercent.
-- WRITES:           MidnightUISettings.PetFrame.position (on drag stop).
--                   Blizzard PetFrame: SetAlpha(0), EnableMouse(false) to suppress default.
--                   Blizzard PetFrame position: AnchorBlizzardPetFrameToCustom() mirrors
--                   the custom frame so Blizzard tutorial arrows still point correctly.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor, MidnightUI_ApplySharedUnitFrameAppearance,
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes pet frame settings controls).
-- KEY FLOWS:
--   PET_UI_UPDATE / UNIT_PET → show frame when pet exists; hide when pet is gone
--   UNIT_HEALTH pet → UpdateHealth(frame)
--   UNIT_AURA pet → hazard probe → apply PET_HAZARD_ENUM tint to health bar
-- GOTCHAS:
--   AnchorBlizzardPetFrameToCustom(): cannot run in combat (InCombatLockdown guard).
--   Blizzard PetFrame is a SecureFrame; EnableMouse changes are deferred to out-of-combat.
--   Hazard detection uses the same probe-curve system as FocusFrame — see FocusFrame.lua
--   GOTCHAS for a full explanation of the color-sampling approach.
--   PET_DEBUFF_TINT_MUL = 0.85: tint is slightly dimmer than on player/focus bars
--   so the pet bar reads as lower-priority visually.
-- NAVIGATION:
--   PET_HAZARD_ENUM / COLORS / PRIORITY — dispel type definitions (line ~79)
--   AnchorBlizzardPetFrameToCustom()    — keeps Blizzard tutorial pointers aligned
--   SoftHideBlizzardPetFrame()          — zeros alpha + defers mouse disable
--   BuildPetFrame()                     — constructs all sub-frames
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local PetFrameManager = CreateFrame("Frame")
local petFrame
local pendingPetFrameLock = nil

local function SoftHideBlizzardPetFrame(frame)
    if not frame then return end
    frame:SetAlpha(0)
    if InCombatLockdown and InCombatLockdown() then
        return
    end
    if frame.EnableMouse then
        frame:EnableMouse(false)
    end
end

-- Re-anchor the hidden Blizzard PetFrame to match our custom frame's position.
-- This keeps Blizzard tutorial pointers (New Player Experience / Exile's Reach)
-- anchored near our custom frame instead of pointing at the invisible default spot.
local function AnchorBlizzardPetFrameToCustom()
    local blizz = PetFrame
    local custom = _G.MidnightUI_PetFrame
    if not blizz or not custom then return end
    if InCombatLockdown and InCombatLockdown() then return end
    blizz:ClearAllPoints()
    blizz:SetPoint("TOPLEFT", custom, "TOPLEFT", 0, 0)
    blizz:SetPoint("BOTTOMRIGHT", custom, "BOTTOMRIGHT", 0, 0)
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
    width = 245, height = 48, spacing = 1,
    position = {"CENTER", "UIParent", "CENTER", 19.684318, -229.45317},
}

-- Pet debuff type detection
local PET_HAZARD_ENUM = {
    None = 0, Magic = 1, Curse = 2, Disease = 3, Poison = 4,
    Enrage = 9, Bleed = 11,
}
local PET_HAZARD_COLORS = {
    [PET_HAZARD_ENUM.Magic]   = { 0.15, 0.55, 0.95 },
    [PET_HAZARD_ENUM.Curse]   = { 0.70, 0.20, 0.95 },
    [PET_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [PET_HAZARD_ENUM.Poison]  = { 0.15, 0.65, 0.20 },
    [PET_HAZARD_ENUM.Bleed]   = { 0.95, 0.15, 0.15 },
}
local PET_HAZARD_PRIORITY = {
    PET_HAZARD_ENUM.Magic, PET_HAZARD_ENUM.Curse,
    PET_HAZARD_ENUM.Disease, PET_HAZARD_ENUM.Poison,
    PET_HAZARD_ENUM.Bleed,
}
local PET_DEBUFF_TINT_MUL = 0.85
local _petActiveDebuffEnum = nil
local _petActiveDebuffColor = nil

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
        return 0.1, 0.9, 0.1
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

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
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

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = 12,
            healthFont = "Fonts\\ARIALN.TTF",
            healthSize = 11,
            levelFont = "Fonts\\FRIZQT__.TTF",
            levelSize = 10,
            powerFont = "Fonts\\FRIZQT__.TTF",
            powerSize = 10,
            nameShadowAlpha = 1,
            healthShadowAlpha = 1,
            levelShadowAlpha = 0.9,
            powerShadowAlpha = 0.9,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\ARIALN.TTF", 11, "OUTLINE")
    SetFontSafe(frame.levelText, "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
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

local function GetPetSettings()
    return (MidnightUISettings and MidnightUISettings.PetFrame) or {}
end

-- =========================================================================
--  POLISHED GRADIENT BAR STYLE
-- =========================================================================

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
        if IsSecretValue(val) then return fallback end
        local n = CoerceNumber(val)
        if type(n) ~= "number" then return fallback end
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

local function ApplyPetBaseColorToBar(bar, r, g, b, style, topA, centerA, bottomA)
    if not bar then return end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetHorizTile(false)
        tex:SetVertTile(false)
    end
    bar:SetStatusBarColor(r, g, b, 1.0)
    if style == "Gradient" then
        ApplyPolishedGradientToBar(bar, tex, topA, centerA, bottomA, r, g, b)
    else
        HidePolishedGradientOnBar(bar)
    end
end

-- =========================================================================
--  MAIN PET FRAME
-- =========================================================================

local ApplyPetFrameBarStyle

local function CreatePetFrame()
    local settings = GetPetSettings()
    local width = settings.width or config.width
    local height = settings.height or config.height
    local healthHeight = height * 0.64
    local powerHeight = height * 0.25

    local frame = CreateFrame("Button", "MidnightUI_PetFrame", UIParent, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(width, height)
    frame._muiBaseHealthHeight = healthHeight
    frame._muiBasePowerHeight = powerHeight
    frame:SetAttribute("unit", "pet")
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
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if UnitExists("pet") then
            GameTooltip:SetUnit("pet")
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

    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetPoint("TOPLEFT", 1, -1)
    healthBar:SetPoint("BOTTOMRIGHT", -1, 1)
    healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    healthBar:GetStatusBarTexture():SetHorizTile(false)
    healthBar:SetStatusBarColor(0.5, 0.5, 0.5, 1.0)
    healthBar:SetMinMaxValues(0, 1); healthBar:SetValue(1)
    frame.healthBar = healthBar

    -- TEXT OVERLAY
    local textOverlay = CreateFrame("Frame", nil, healthContainer)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameStrata("MEDIUM")
    textOverlay:SetFrameLevel(healthContainer:GetFrameLevel() + 5)

    local nameText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    nameText:SetPoint("CENTER", textOverlay, "CENTER", 0, 2)
    nameText:SetTextColor(1, 1, 1, 1); nameText:SetShadowOffset(1, -1); nameText:SetShadowColor(0, 0, 0, 1)
    frame.nameText = nameText

    local healthText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(healthText, "Fonts\\ARIALN.TTF", 11, "OUTLINE")
    healthText:SetPoint("RIGHT", textOverlay, "RIGHT", -8, 0)
    healthText:SetTextColor(1, 1, 1, 1); healthText:SetShadowOffset(2, -2); healthText:SetShadowColor(0, 0, 0, 1)
    frame.healthText = healthText

    local levelText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(levelText, "Fonts\\FRIZQT__.TTF", 10, "OUTLINE")
    levelText:SetPoint("LEFT", textOverlay, "LEFT", 8, 0)
    levelText:SetTextColor(0.9, 0.9, 0.9, 1)
    frame.levelText = levelText

    local deadIcon = textOverlay:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(24, 24)
    deadIcon:SetPoint("RIGHT", healthContainer, "RIGHT", -20, 0)
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

    -- Pet happiness indicator (small colored dot next to name)
    local happyDot = textOverlay:CreateTexture(nil, "OVERLAY")
    happyDot:SetSize(8, 8)
    happyDot:SetPoint("RIGHT", nameText, "LEFT", -4, 0)
    happyDot:SetTexture("Interface\\Buttons\\WHITE8X8")
    happyDot:SetVertexColor(0.1, 0.9, 0.1, 0.8)
    happyDot:Hide()
    frame.happyDot = happyDot

    frame:Hide()
    if ApplyPetFrameBarStyle then ApplyPetFrameBarStyle() end
    return frame
end

ApplyPetFrameBarStyle = function()
    local frame = _G.MidnightUI_PetFrame
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
_G.MidnightUI_ApplyPetFrameBarStyle = ApplyPetFrameBarStyle

-- =========================================================================
--  PET DEBUFF DETECTION
-- =========================================================================

local function NormalizePetDispelType(dt)
    if type(dt) == "number" then
        if dt == 1 then return PET_HAZARD_ENUM.Magic end
        if dt == 2 then return PET_HAZARD_ENUM.Curse end
        if dt == 3 then return PET_HAZARD_ENUM.Disease end
        if dt == 4 then return PET_HAZARD_ENUM.Poison end
        if dt == 9 then return PET_HAZARD_ENUM.Enrage end
        if dt == 11 then return PET_HAZARD_ENUM.Bleed end
        return nil
    end
    if type(dt) ~= "string" then return nil end
    if type(issecretvalue) == "function" then
        local ok, sec = pcall(issecretvalue, dt)
        if ok and sec then return nil end
    end
    local s = string.lower(dt)
    if s == "magic" then return PET_HAZARD_ENUM.Magic end
    if s == "curse" then return PET_HAZARD_ENUM.Curse end
    if s == "disease" then return PET_HAZARD_ENUM.Disease end
    if s == "poison" then return PET_HAZARD_ENUM.Poison end
    if s == "bleed" then return PET_HAZARD_ENUM.Bleed end
    if s == "enrage" then return PET_HAZARD_ENUM.Enrage end
    return nil
end

local function ScanPetDebuffType(unit)
    _petActiveDebuffEnum = nil
    _petActiveDebuffColor = nil
    if not UnitExists(unit) then return end

    local bestEnum = nil
    local bestPriority = 999

    for i = 1, 40 do
        local aura = nil
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            local ok, data = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
            if not ok then break end
            aura = data
        end
        if not aura then
            -- Legacy fallback
            if type(UnitDebuff) == "function" then
                local name, _, _, debuffType = UnitDebuff(unit, i)
                if not name then break end
                aura = { dispelName = debuffType, dispelType = debuffType }
            else
                break
            end
        end
        if not aura then break end

        local enum = NormalizePetDispelType(aura.dispelType)
            or NormalizePetDispelType(aura.dispelName)
            or NormalizePetDispelType(aura.debuffType)
        if enum and enum ~= PET_HAZARD_ENUM.None then
            for pri, e in ipairs(PET_HAZARD_PRIORITY) do
                if e == enum and pri < bestPriority then
                    bestEnum = enum
                    bestPriority = pri
                    break
                end
            end
        end
    end

    if bestEnum then
        _petActiveDebuffEnum = bestEnum
        _petActiveDebuffColor = PET_HAZARD_COLORS[bestEnum]
    end
end

-- =========================================================================
--  UPDATE HEALTH
-- =========================================================================

local function UpdateHealth(frame)
    if not UnitExists("pet") then return end

    local r, g, b = GetUnitColor("pet")
    local isDead = IsUnitActuallyDead("pet")

    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    ApplyPetBaseColorToBar(frame.healthBar, r, g, b, style, 0.28, 0.035, 0.32)

    frame.nameText:SetTextColor(r, g, b, 1)
    SafeSetFontStringText(frame.nameText, UnitName("pet") or "")

    local level = UnitLevel("pet")
    local levelNum = CoerceNumber(level)
    if levelNum == -1 then
        SafeSetFontStringText(frame.levelText, "??")
    elseif levelNum ~= nil then
        SafeSetFontStringText(frame.levelText, levelNum)
    else
        SafeSetFontStringText(frame.levelText, "")
    end

    local current = UnitHealth("pet")
    local max = UnitHealthMax("pet")
    if not isDead then
        local okZero, isZero = pcall(function() return current <= 0 end)
        local okMaxPos, maxPos = pcall(function() return max > 0 end)
        if okZero and isZero and okMaxPos and maxPos then
            isDead = true
        end
    end

    if frame.healthBg then
        frame.healthBg:SetColorTexture(r * 0.15, g * 0.15, b * 0.15, 0.6)
    end

    pcall(function()
        frame.healthBar:SetMinMaxValues(0, max)
        frame.healthBar:SetValue(current)
    end)

    local renderedText = nil
    local pct = GetDisplayHealthPercent("pet")
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
        if isDead then
            frame.deadIcon:SetSize(24, 24)
            frame.deadIcon:ClearAllPoints()
            frame.deadIcon:SetPoint("RIGHT", frame.healthContainer, "RIGHT", -20, 0)
            ApplyDeadIconVisualStyle(frame.deadIcon)
            frame.deadIcon:Show()
            frame.healthText:SetText("")
        else
            frame.deadIcon:Hide()
        end
    end

    -- Debuff type tint
    if not isDead then
        ScanPetDebuffType("pet")
        if _petActiveDebuffColor then
            local dr = _petActiveDebuffColor[1] * PET_DEBUFF_TINT_MUL
            local dg = _petActiveDebuffColor[2] * PET_DEBUFF_TINT_MUL
            local db = _petActiveDebuffColor[3] * PET_DEBUFF_TINT_MUL
            frame.healthBar:SetStatusBarColor(dr, dg, db, 1.0)
            local tex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            if tex and tex.SetVertexColor then
                tex:SetVertexColor(dr, dg, db, 1.0)
            end
            if frame.healthBg and frame.healthBg.SetColorTexture then
                frame.healthBg:SetColorTexture(_petActiveDebuffColor[1] * 0.15, _petActiveDebuffColor[2] * 0.15, _petActiveDebuffColor[3] * 0.15, 0.6)
            end
        end
    end
end

-- =========================================================================
--  UPDATE POWER
-- =========================================================================

local function UpdatePower(frame)
    if not UnitExists("pet") then return end

    local powerType, powerToken = UnitPowerType("pet")
    local token = powerToken or "MANA"
    local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR

    local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
    if style == "Balanced" then style = "Gradient" end
    ApplyPetBaseColorToBar(frame.powerBar, color[1], color[2], color[3], style, 0.24, 0.03, 0.28)

    local current = UnitPower("pet", powerType)
    local max = UnitPowerMax("pet", powerType)

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
end

-- =========================================================================
--  UPDATE ALL
-- =========================================================================

local function UpdateAll(frame)
    UpdateHealth(frame)
    UpdatePower(frame)
end

local function ApplyPetPlaceholder(frame)
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
    if frame.deadIcon then frame.deadIcon:Hide() end
    if frame.happyDot then frame.happyDot:Hide() end
end

function MidnightUI_RefreshPetFrame()
    local frame = _G.MidnightUI_PetFrame
    if frame and frame:IsShown() then
        UpdateAll(frame)
    end
end

-- =========================================================================
--  DRAG & LOCKING
-- =========================================================================

function MidnightUI_SetPetFrameLocked(locked)
    local frame = _G["MidnightUI_PetFrame"]
    if not frame then return end
    if InCombatLockdown() then
        pendingPetFrameLock = locked
        return
    end
    if locked then
        frame:EnableMouse(true)
        if frame.dragOverlay then frame.dragOverlay:Hide() end
        if not UnitExists("pet") then frame:Hide() end
    else
        frame:Show()
        frame:EnableMouse(true)
        if not frame.dragOverlay then
            local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            overlay:SetAllPoints(); overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30); overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "unit") end
            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER"); label:SetText("PET FRAME"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) frame:StartMoving() end)

            overlay:SetScript("OnDragStop", function(self)
                frame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint()
                local s = frame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
                MidnightUISettings.PetFrame.position = { point, relativePoint, xOfs, yOfs }
                AnchorBlizzardPetFrameToCustom()
            end)
            overlay:SetScript("OnEnter", function()
                GameTooltip:SetOwner(overlay, "ANCHOR_BOTTOM")
                GameTooltip:SetText("Drag to move Pet Frame", 1, 0.82, 0)
                GameTooltip:Show()
            end)
            overlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
            frame.dragOverlay = overlay
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "PetFrame")
            end
        end
        frame.dragOverlay:Show()
        if not UnitExists("pet") then ApplyPetPlaceholder(frame) end
    end
end

-- =========================================================================
--  OVERLAY SETTINGS (for Settings_UI integration)
-- =========================================================================

local function BuildPetFrameOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    local s = MidnightUISettings.PetFrame
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Slider("Scale", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.PetFrame.scale = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPetSettings then
            _G.MidnightUI_Settings.ApplyPetSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("PetFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Width", 150, 400, 5, s.width or 220, function(v)
        MidnightUISettings.PetFrame.width = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPetSettings then
            _G.MidnightUI_Settings.ApplyPetSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("PetFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Height", 30, 100, 2, s.height or 46, function(v)
        MidnightUISettings.PetFrame.height = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPetSettings then
            _G.MidnightUI_Settings.ApplyPetSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("PetFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 0.95, function(v)
        MidnightUISettings.PetFrame.alpha = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPetSettings then
            _G.MidnightUI_Settings.ApplyPetSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("PetFrame")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("PetFrame", { title = "Pet Frame", build = BuildPetFrameOverlaySettings })
end

-- =========================================================================
--  EVENT REGISTRATION & HANDLING
-- =========================================================================

PetFrameManager:RegisterEvent("ADDON_LOADED")
PetFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
PetFrameManager:RegisterEvent("UNIT_PET")
PetFrameManager:RegisterEvent("PET_BAR_UPDATE")
PetFrameManager:RegisterUnitEvent("UNIT_HEALTH", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_MAXHEALTH", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_POWER_UPDATE", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_MAXPOWER", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_DISPLAYPOWER", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_NAME_UPDATE", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_LEVEL", "pet")
PetFrameManager:RegisterUnitEvent("UNIT_AURA", "pet")
PetFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")

PetFrameManager:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...

    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            -- Hide Blizzard pet frame
            if PetFrame then
                SoftHideBlizzardPetFrame(PetFrame)
                if not PetFrame._muiSoftHidden then
                    PetFrame._muiSoftHidden = true
                    PetFrame:HookScript("OnShow", function(self)
                        SoftHideBlizzardPetFrame(self)
                    end)
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        if not petFrame then
            petFrame = CreatePetFrame()
        end
        AnchorBlizzardPetFrameToCustom()

        if MidnightUISettings and MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.enabled == false then
            petFrame:Hide()
            petFrame:SetAlpha(0)
            return
        end

        if UnitExists("pet") then
            UpdateAll(petFrame)
            petFrame:Show()
            petFrame:SetAlpha((MidnightUISettings and MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.alpha) or 0.95)
        end

    elseif event == "UNIT_PET" or event == "PET_BAR_UPDATE" then
        if not petFrame then
            petFrame = CreatePetFrame()
        end
        AnchorBlizzardPetFrameToCustom()

        if MidnightUISettings and MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.enabled == false then
            if not InCombatLockdown() then
                petFrame:Hide()
            end
            return
        end

        if UnitExists("pet") then
            UpdateAll(petFrame)
            if not InCombatLockdown() then
                petFrame:Show()
                petFrame:SetAlpha((MidnightUISettings and MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.alpha) or 0.95)
            end
        else
            ApplyPetPlaceholder(petFrame)
        end

        local isUnlocked = (petFrame.dragOverlay and petFrame.dragOverlay:IsShown())
        if isUnlocked and not InCombatLockdown() then
            petFrame:Show()
            if not UnitExists("pet") then ApplyPetPlaceholder(petFrame) end
        end

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if petFrame and petFrame:IsShown() then
            UpdateHealth(petFrame)
        end

    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        if petFrame and petFrame:IsShown() then
            UpdatePower(petFrame)
        end

    elseif event == "UNIT_NAME_UPDATE" or event == "UNIT_LEVEL" then
        if petFrame and petFrame:IsShown() then
            UpdateHealth(petFrame)
        end

    elseif event == "UNIT_AURA" then
        if petFrame and petFrame:IsShown() then
            UpdateHealth(petFrame)
        end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingPetFrameLock ~= nil then
            local pending = pendingPetFrameLock
            pendingPetFrameLock = nil
            MidnightUI_SetPetFrameLocked(pending)
        end
    end
end)
