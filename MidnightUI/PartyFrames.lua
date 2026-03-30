-- =============================================================================
-- FILE PURPOSE:     Custom party frames for 4-player groups. Each member frame shows
--                   health/power bars with class-color health, debuff hazard tint
--                   (PARTY_HAZARD_ENUM), role icon, range-based alpha fading, and a
--                   dispel-tracking overlay. Supports Rendered/Simple/2D-portrait styles.
--                   Includes a live preview/test mode for tuning layouts out of combat.
-- LOAD ORDER:       Loads after ConditionBorder.lua. PartyFrameManager handles ADDON_LOADED,
--                   GROUP_ROSTER_UPDATE, and PLAYER_ENTERING_WORLD.
-- DEFINES:          PartyFrameManager (event frame), PartyFrames[] (4 member frames),
--                   PartyAnchor (drag container). Globals: MidnightUI_ApplyPartyFramesSettings(),
--                   MidnightUI_TogglePartyPreview().
-- READS:            MidnightUISettings.PartyFrames.{enabled, width, height, scale, alpha,
--                   position, layout, style, showAuras, auraSize, spacingX, spacingY}.
--                   MidnightUISettings.Combat.{debuffOverlayGlobalEnabled, debuffOverlayPartyEnabled}.
-- WRITES:           MidnightUISettings.PartyFrames.position (on drag stop).
--                   Blizzard CompactPartyFrame: reparented to hiddenParent to suppress default.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (health bar color per member class).
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua — bar gradient style).
--                   ConditionBorder.MidnightUI_ConditionBorder (feeds hazard tint data).
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua, ConditionBorder.lua (party frame hazard tint routing).
-- KEY FLOWS:
--   GROUP_ROSTER_UPDATE → EnsurePartyFrames() → shows/hides per member slot
--   UNIT_HEALTH partyN → UpdateHealth(PartyFrames[n])
--   UNIT_AURA partyN → hazard probe → PARTY_HAZARD_ENUM tint + debuff overlay icons
--   PartyRangeTicker → fades members out of range
--   Batch coalescing: _partyDirtyUnits filled on events; _partyBatchFrame:OnUpdate flushes
-- GOTCHAS:
--   _partyBatchFrame coalesces rapid UNIT_HEALTH/UNIT_AURA events into one render pass per frame.
--   PartyTestState: live preview injects synthetic member data; must be fully cleaned up
--   (StopPartyDebuffOverlayTest) before real roster events resume normal rendering.
--   CLASS_COLOR_OVERRIDES: party frames maintain a local copy of exact class colors
--   (same values as MidnightUI_Core.ClassColorsExact) to avoid a dependency on Core
--   being fully initialized before the first GROUP_ROSTER_UPDATE fires.
--   PARTY_HAZARD_STICKY_SEC = 0.45s (shorter than raid/focus 8s) — party frames
--   have tighter visual feedback cycle for healers.
--   hiddenParent:Hide() suppresses Blizzard's CompactPartyFrame without destroying it,
--   because destroying party frames can break other addons that reference them.
-- NAVIGATION:
--   PARTY_HAZARD_ENUM / COLORS / PRIORITY  — dispel type definitions (line ~66)
--   config{}                               — default layout dimensions (line ~113)
--   PARTY_TEST_MEMBERS[]                   — synthetic test roster for preview mode
--   InitPartyFrames()                      — builds all 4 member frames
--   UpdateHealth(), UpdatePower()          — per-frame stat refresh
--   RefreshPartyDispelTrackingOverlays()   — updates dispel icon strip below each frame
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local PartyFrameManager = CreateFrame("Frame")

-- =========================================================================
--  CONSTANTS & CONFIG
-- =========================================================================

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

local DEFAULT_CLASS_COLOR = {r=0.5, g=0.5, b=0.5}
local CLASS_COLOR_OVERRIDES = {
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 },
    DEMONHUNTER = { r = 0.64, g = 0.19, b = 0.79 },
    DRUID = { r = 1.00, g = 0.49, b = 0.04 },
    EVOKER = { r = 0.20, g = 0.58, b = 0.50 },
    HUNTER = { r = 0.67, g = 0.83, b = 0.45 },
    MAGE = { r = 0.25, g = 0.78, b = 0.92 },
    MONK = { r = 0.00, g = 1.00, b = 0.60 },
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 },
    PRIEST = { r = 1.00, g = 1.00, b = 1.00 },
    ROGUE = { r = 1.00, g = 0.96, b = 0.41 },
    SHAMAN = { r = 0.00, g = 0.44, b = 0.87 },
    WARLOCK = { r = 0.53, g = 0.53, b = 0.93 },
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },
}

-- Fallback debuff colors when DebuffTypeColor is unavailable
local DEBUFF_COLORS = {
    ["Magic"]   = { r = 0.20, g = 0.60, b = 1.00 },
    ["Curse"]   = { r = 0.60, g = 0.00, b = 1.00 },
    ["Disease"] = { r = 0.60, g = 0.40, b = 0.00 },
    ["Poison"]  = { r = 0.00, g = 0.60, b = 0.00 },
    ["none"]    = { r = 0.80, g = 0.00, b = 0.00 },
}

local PARTY_HAZARD_ENUM = {
    None = 0,
    Magic = 1,
    Curse = 2,
    Disease = 3,
    Poison = 4,
    Enrage = 9,
    Bleed = 11,
    Unknown = 99,
}

local PARTY_HAZARD_COLORS = {
    [PARTY_HAZARD_ENUM.Magic]   = { 0.15, 0.55, 0.95 },
    [PARTY_HAZARD_ENUM.Curse]   = { 0.70, 0.20, 0.95 },
    [PARTY_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [PARTY_HAZARD_ENUM.Poison]  = { 0.15, 0.65, 0.20 },
    [PARTY_HAZARD_ENUM.Bleed]   = { 0.95, 0.15, 0.15 },
    [PARTY_HAZARD_ENUM.Unknown] = { 0.00, 0.00, 0.00 },
}
local PARTY_UNKNOWN_SWEEP_COLOR = { 1.00, 1.00, 1.00 }

local PARTY_HAZARD_LABELS = {
    [PARTY_HAZARD_ENUM.Magic] = "MAGIC",
    [PARTY_HAZARD_ENUM.Curse] = "CURSE",
    [PARTY_HAZARD_ENUM.Disease] = "DISEASE",
    [PARTY_HAZARD_ENUM.Poison] = "POISON",
    [PARTY_HAZARD_ENUM.Bleed] = "BLEED",
    [PARTY_HAZARD_ENUM.Unknown] = "UNKNOWN",
}
local PARTY_HAZARD_PRIORITY = {
    PARTY_HAZARD_ENUM.Magic,
    PARTY_HAZARD_ENUM.Curse,
    PARTY_HAZARD_ENUM.Disease,
    PARTY_HAZARD_ENUM.Poison,
    PARTY_HAZARD_ENUM.Bleed,
}
local PARTY_HAZARD_STICKY_SEC = 0.45
local PARTY_HAZARD_CURVE_EPSILON = 0.02
local PARTY_SECRET_TINT_BASE_MUL = 0.42
local PARTY_RENDERED_TINT_MUL = 0.86
local PARTY_SIMPLE_TINT_MUL = 1.16
local _partyHazardProbeCurves = {}
local _partyHazardProbeMatchColors = {}
local _partyHazardZeroProbeCurve
local _partyBlizzAuraCache = {}
local _partyBlizzHookRegistered = false

local config = {
    width = 240, height = 58, healthHeight = 44, powerHeight = 14, spacing = 0,
    startPos = {"TOPLEFT", UIParent, "TOPLEFT", 0, 0},
    verticalOffset = -55,
    auraSize = 20,
    auraSpacing = 4,
    showAuras = false,
    layout = "Vertical",
    spacingX = 8,
    spacingY = 8,
    style = "Rendered",
    hide2DPortrait = false,
    diameter = 64,
}

local PartyFrames = {}

-- Batch coalescing: collect dirty party frame indices, flush on next render
local _partyDirtyUnits = {}
local _partyDirtyAll = false
local _partyBatchFrame = CreateFrame("Frame")
_partyBatchFrame:Hide()
local PartyRangeTicker
local PartyAnchor
local PartyPreviewBoxes = {}
local InitPartyFrames
local StopPartyDebuffOverlayTest
local ApplyRenderedBarStyle
local MakePartySecretColor
local RefreshPartyDispelTrackingOverlays
local UpdatePartyDispelTrackingOverlay
local NormalizePartyHazardEnum
local OVERLAY_PAD = {
    left = 20,
    right = 20,
    top = 20,
    bottom = 90,
}
local PARTY_DISPEL_TRACKING = {
    BASE_ICON_SIZE = 20,
    ICON_SCALE_MIN = 50,
    ICON_SCALE_MAX = 200,
    OFFSET_X = 8,
    OFFSET_Y = 0,
    PLACEHOLDER_ICON = 134400,
    DRAG_SIZE = 56,
    MAX_SHOWN_LIMIT = 40,
    DEFAULT_PER_ROW = 4,
}
local PartyDispelTrackingState = {
    dragOverlay = nil,
    locked = true,
}

-- HIDDEN PARENT FOR DEFAULT FRAMES
local hiddenParent = CreateFrame("Frame")
hiddenParent:Hide()
local pendingPartyVisibility = false
local PARTY_TEST_TICK_RATE = 0.15
local PARTY_TEST_LIVE_TICK_RATE = 0.12
local PARTY_TEST_MEMBERS = {
    { name = "Tanky", class = "WARRIOR", role = "TANK", power = "RAGE" },
    { name = "Heals", class = "DRUID", role = "HEALER", power = "MANA" },
    { name = "DPS-One", class = "MAGE", role = "DAMAGER", power = "MANA" },
    { name = "DPS-Two", class = "ROGUE", role = "DAMAGER", power = "ENERGY" },
}
local PARTY_TEST_DEBUFF_TYPES = {
    { label = "MAGIC", r = 0.15, g = 0.55, b = 0.95 },
    { label = "CURSE", r = 0.70, g = 0.20, b = 0.95 },
    { label = "DISEASE", r = 0.80, g = 0.50, b = 0.10 },
    { label = "POISON", r = 0.15, g = 0.65, b = 0.20 },
    { label = "BLEED", r = 0.95, g = 0.15, b = 0.15 },
}
local PartyTestState = {
    active = false,
    pendingStart = false,
    pendingMode = nil,
    pendingRestore = false,
    ticker = nil,
    mode = nil,
    lastDiagAt = 0,
    lastLiveTickKey = nil,
    prevPartyDebug = nil,
    prevCondDebug = nil,
}

-- =========================================================================
--  STYLE HELPERS
-- =========================================================================

local function CreateDropShadow(frame, intensity)
    intensity = intensity or 6
    local shadows = {}
    for i = 1, intensity do
        local shadowLayer = CreateFrame("Frame", nil, frame)
        shadowLayer:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 1.0
        local alpha = (0.25 - (i * 0.035)) * (intensity / 6)
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

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
    return ok
end

local function UpdatePortraitModel(portrait, unit)
    if not portrait or not unit then return end
    if SetPortraitTexture then
        SetPortraitTexture(portrait, unit)
    end
    if portrait.SetTexCoord then
        portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    portrait:SetAlpha(1)
end

local function ApplyHealthBarStyle(healthBar)
    if not healthBar then return end
    local function ApplyPolishedGradient(tex, topDarkA, centerLightA, bottomDarkA)
        local anchor = tex or healthBar
        local baseR, baseG, baseB = healthBar:GetStatusBarColor()
        if type(baseR) ~= "number" then
            baseR, baseG, baseB = 0.12, 0.85, 0.12
        end
        local function Scale(v, f)
            local n = (v or 0) * f
            if n < 0 then return 0 end
            if n > 1 then return 1 end
            return n
        end
        local edgeR, edgeG, edgeB = Scale(baseR, 0.54), Scale(baseG, 0.54), Scale(baseB, 0.54)
        local midR, midG, midB = Scale(baseR, 1.15), Scale(baseG, 1.15), Scale(baseB, 1.15)
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
        local topH = math.max(1, h * 0.43)
        local botH = math.max(1, h * 0.57)
        local specH = math.max(1, h * 0.35)
        healthBar._muiTopHighlight:ClearAllPoints()
        healthBar._muiTopHighlight:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
        healthBar._muiTopHighlight:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
        healthBar._muiTopHighlight:SetHeight(topH)
        healthBar._muiTopHighlight:SetGradient("VERTICAL",
            CreateColor(edgeR, edgeG, edgeB, 1),
            CreateColor(midR, midG, midB, 1))

        healthBar._muiBottomShade:ClearAllPoints()
        healthBar._muiBottomShade:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
        healthBar._muiBottomShade:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
        healthBar._muiBottomShade:SetHeight(botH)
        healthBar._muiBottomShade:SetGradient("VERTICAL",
            CreateColor(midR, midG, midB, 1),
            CreateColor(edgeR, edgeG, edgeB, 1))

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
        ApplyPolishedGradient(tex, 0.28, 0.035, 0.32)
        if healthBar._muiFlatGradient then healthBar._muiFlatGradient:Hide() end
        return
    end
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

local function GetPartyDebuffTintBaseMultiplier()
    local style = tostring(config and config.style or "Rendered")
    local mul = PARTY_SECRET_TINT_BASE_MUL
    if style == "Rendered" then
        mul = mul * PARTY_RENDERED_TINT_MUL
    elseif style == "Simple" then
        mul = mul * PARTY_SIMPLE_TINT_MUL
    end
    if mul < 0 then mul = 0 end
    if mul > 1 then mul = 1 end
    return mul
end

local function GetPartyDebuffBackgroundProfile()
    local style = tostring(config and config.style or "Rendered")
    if style == "Simple" then
        return 0.18, 0.14, 0.52, 0.40
    end
    return 0.25, 0.20, 0.62, 0.48
end

local function ApplyPartyDebuffBackgroundTint(frame, r, g, b)
    if not frame then
        return
    end
    local healthMul, powerMul, healthAlpha, powerAlpha = GetPartyDebuffBackgroundProfile()
    if frame.healthBg and frame.healthBg.SetColorTexture then
        frame.healthBg:SetColorTexture((r or 0) * healthMul, (g or 0) * healthMul, (b or 0) * healthMul, healthAlpha)
    end
    if frame.powerBg and frame.powerBg.SetColorTexture then
        frame.powerBg:SetColorTexture((r or 0) * powerMul, (g or 0) * powerMul, (b or 0) * powerMul, powerAlpha)
    end
end

local function Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

local function ApplyStatusBarGradient(bar, r, g, b, a, topAlpha, bottomAlpha)
    if not bar then return end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = bar:GetStatusBarTexture()
    if not tex then return end
    tex:SetHorizTile(false)
    tex:SetVertTile(false)
    bar:SetStatusBarColor(r, g, b, a or 1)
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
    local function Scale(v, f)
        local n = (v or 0) * f
        if n < 0 then return 0 end
        if n > 1 then return 1 end
        return n
    end
    local edgeR, edgeG, edgeB = Scale(r, 0.54), Scale(g, 0.54), Scale(b, 0.54)
    local midR, midG, midB = Scale(r, 1.15), Scale(g, 1.15), Scale(b, 1.15)
    local rawH = (bar.GetHeight and bar:GetHeight()) or 2
    local h = tonumber(tostring(rawH)) or 2
    local topH = math.max(1, h * 0.43)
    local botH = math.max(1, h * 0.57)
    local specH = math.max(1, h * 0.35)

    bar._muiTopHighlight:ClearAllPoints()
    bar._muiTopHighlight:SetPoint("TOPLEFT", tex, "TOPLEFT", 0, 0)
    bar._muiTopHighlight:SetPoint("TOPRIGHT", tex, "TOPRIGHT", 0, 0)
    bar._muiTopHighlight:SetHeight(topH)
    bar._muiTopHighlight:SetGradient("VERTICAL",
        CreateColor(edgeR, edgeG, edgeB, 1),
        CreateColor(midR, midG, midB, 1))

    bar._muiBottomShade:ClearAllPoints()
    bar._muiBottomShade:SetPoint("BOTTOMLEFT", tex, "BOTTOMLEFT", 0, 0)
    bar._muiBottomShade:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 0, 0)
    bar._muiBottomShade:SetHeight(botH)
    bar._muiBottomShade:SetGradient("VERTICAL",
        CreateColor(midR, midG, midB, 1),
        CreateColor(edgeR, edgeG, edgeB, 1))

    bar._muiSpecular:ClearAllPoints()
    bar._muiSpecular:SetPoint("TOPLEFT", tex, "TOPLEFT", 0, 0)
    bar._muiSpecular:SetPoint("TOPRIGHT", tex, "TOPRIGHT", 0, 0)
    bar._muiSpecular:SetHeight(specH)
    bar._muiSpecular:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0),
        CreateColor(1, 1, 1, 0.06))

    bar._muiTopHighlight:Show()
    bar._muiBottomShade:Show()
    bar._muiSpecular:Show()
    if bar._muiGradient then bar._muiGradient:Hide() end
    if bar._muiRenderedTop then bar._muiRenderedTop:Hide() end
    if bar._muiRenderedBottom then bar._muiRenderedBottom:Hide() end
    if bar._muiRenderedGloss then bar._muiRenderedGloss:Hide() end
end

local function ApplyPartyFlatStatusBarTint(bar, r, g, b, a)
    if not bar then return end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = bar:GetStatusBarTexture()
    if tex then
        tex:SetHorizTile(false)
        tex:SetVertTile(false)
    end
    bar:SetStatusBarColor(r or 0, g or 0, b or 0, a or 1)
    if tex and tex.SetVertexColor then
        tex:SetVertexColor(r or 0, g or 0, b or 0, a or 1)
    end
    if bar._muiGradient then bar._muiGradient:Hide() end
    if bar._muiFlatGradient then bar._muiFlatGradient:Hide() end
    if bar._muiTopHighlight then bar._muiTopHighlight:Hide() end
    if bar._muiBottomShade then bar._muiBottomShade:Hide() end
    if bar._muiSpecular then bar._muiSpecular:Hide() end
    if bar._muiRenderedTop then bar._muiRenderedTop:Hide() end
    if bar._muiRenderedBottom then bar._muiRenderedBottom:Hide() end
    if bar._muiRenderedGloss then bar._muiRenderedGloss:Hide() end
end

local function ClearBarOverlays(bar)
    if not bar then return end
    if bar._muiGradient then bar._muiGradient:Hide() end
    if bar._muiFlatGradient then bar._muiFlatGradient:Hide() end
    if bar._muiTopHighlight then bar._muiTopHighlight:Hide() end
    if bar._muiBottomShade then bar._muiBottomShade:Hide() end
    if bar._muiSpecular then bar._muiSpecular:Hide() end
    if bar._muiRenderedTop then bar._muiRenderedTop:Hide() end
    if bar._muiRenderedBottom then bar._muiRenderedBottom:Hide() end
    if bar._muiRenderedGloss then bar._muiRenderedGloss:Hide() end
end

local function PartyDebugEnabled()
    return false
end

local function IsPartySecretToken(value)
    if type(issecretvalue) ~= "function" then
        return false
    end
    local ok, secret = pcall(issecretvalue, value)
    return ok and secret == true
end

local function CoercePartyDiagToken(value)
    if value == nil then
        return "nil"
    end
    if IsPartySecretToken(value) then
        return "secret"
    end
    local t = type(value)
    if t == "string" then
        return value
    end
    if t == "number" then
        return tostring(value)
    end
    if t == "boolean" then
        return value and "true" or "false"
    end
    local ok, asString = pcall(tostring, value)
    if not ok or asString == nil then
        return "err"
    end
    if IsPartySecretToken(asString) then
        return "secret"
    end
    return asString
end

local function BuildPartyDiagKey(...)
    local count = select("#", ...)
    local safe = {}
    for i = 1, count do
        safe[i] = CoercePartyDiagToken(select(i, ...))
    end
    return table.concat(safe, "|")
end

local function PartyDebug(message)
end

local function PartyDebugVerbose(message)
end

local function PartyTestChat(message)
    local text = "|cff66ccffMidnightUI:|r " .. tostring(message)
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage(text)
    else
        print("MidnightUI: " .. tostring(message))
    end
end

NormalizePartyHazardEnum = function(value)
    local t = type(value)
    if t == "number" then
        if type(issecretvalue) == "function" then
            local ok, secret = pcall(issecretvalue, value)
            if ok and secret == true then
                return nil
            end
        end
        if value == PARTY_HAZARD_ENUM.Magic
            or value == PARTY_HAZARD_ENUM.Curse
            or value == PARTY_HAZARD_ENUM.Disease
            or value == PARTY_HAZARD_ENUM.Poison
            or value == PARTY_HAZARD_ENUM.Unknown then
            return value
        end
        if value == PARTY_HAZARD_ENUM.Enrage or value == PARTY_HAZARD_ENUM.Bleed then
            return PARTY_HAZARD_ENUM.Bleed
        end
        return nil
    end
    if t ~= "string" then
        return nil
    end
    if type(issecretvalue) == "function" then
        local okSecret, secret = pcall(issecretvalue, value)
        if okSecret and secret == true then
            return nil
        end
    end
    local okLower, lower = pcall(string.lower, value)
    if not okLower or type(lower) ~= "string" then
        return nil
    end
    if lower == "magic" then return PARTY_HAZARD_ENUM.Magic end
    if lower == "curse" then return PARTY_HAZARD_ENUM.Curse end
    if lower == "disease" then return PARTY_HAZARD_ENUM.Disease end
    if lower == "poison" then return PARTY_HAZARD_ENUM.Poison end
    if lower == "bleed" or lower == "enrage" then return PARTY_HAZARD_ENUM.Bleed end
    if lower == "unknown" then return PARTY_HAZARD_ENUM.Unknown end
    return nil
end

local function EnsurePartyCombatSettingsTable()
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
    if combat.debuffOverlayPartyEnabled == nil then
        combat.debuffOverlayPartyEnabled = true
    end
    if combat.partyDispelTrackingEnabled == nil then
        combat.partyDispelTrackingEnabled = true
    end
    if combat.partyDispelTrackingIconScale == nil then
        combat.partyDispelTrackingIconScale = 100
    end
    if combat.partyDispelTrackingAlpha == nil then
        combat.partyDispelTrackingAlpha = 1.0
    end
    if combat.partyDispelTrackingMaxShown == nil then
        combat.partyDispelTrackingMaxShown = 4
    end
    if combat.partyDispelTrackingPerRow == nil then
        combat.partyDispelTrackingPerRow = PARTY_DISPEL_TRACKING.DEFAULT_PER_ROW
    end
    if combat.partyDispelTrackingAutoLayoutMigrated ~= true then
        if combat.partyDispelTrackingOrientation ~= nil then
            combat.partyDispelTrackingOrientation = nil
            combat.partyDispelTrackingPosition = nil
        end
        combat.partyDispelTrackingAutoLayoutMigrated = true
    end
    return combat
end

local function IsPartyDebuffOverlayEnabled()
    local combat = EnsurePartyCombatSettingsTable()
    if combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    if combat.debuffOverlayPartyEnabled == false then
        return false
    end
    return true
end

local function ClampPartyDispelTrackingIconScale(value)
    local num = tonumber(value) or 100
    num = math.floor(num + 0.5)
    if num < PARTY_DISPEL_TRACKING.ICON_SCALE_MIN then
        num = PARTY_DISPEL_TRACKING.ICON_SCALE_MIN
    elseif num > PARTY_DISPEL_TRACKING.ICON_SCALE_MAX then
        num = PARTY_DISPEL_TRACKING.ICON_SCALE_MAX
    end
    return num
end

local function ClampPartyDispelTrackingAlpha(value)
    local num = tonumber(value) or 1.0
    if num < 0.1 then
        num = 0.1
    elseif num > 1.0 then
        num = 1.0
    end
    return num
end

local function GetPartyDispelTrackingIconSize(iconScale)
    local clamped = ClampPartyDispelTrackingIconScale(iconScale)
    return math.max(12, math.floor((PARTY_DISPEL_TRACKING.BASE_ICON_SIZE * clamped / 100) + 0.5))
end

local function IsPartyDispelMovementModeUnlocked()
    return MidnightUISettings
        and MidnightUISettings.Messenger
        and MidnightUISettings.Messenger.locked == false
end

local function NormalizePartyTrackerTypeCode(dt)
    local tokenType = type(dt)
    if tokenType == "number" then
        if dt == 1 then return PARTY_HAZARD_ENUM.Magic end
        if dt == 2 then return PARTY_HAZARD_ENUM.Curse end
        if dt == 3 then return PARTY_HAZARD_ENUM.Disease end
        if dt == 4 then return PARTY_HAZARD_ENUM.Poison end
        if dt == 6 then return PARTY_HAZARD_ENUM.Bleed end
        if dt == 9 then return PARTY_HAZARD_ENUM.Bleed end
        if dt == 11 then return PARTY_HAZARD_ENUM.Bleed end
    elseif tokenType == "string" then
        if type(issecretvalue) == "function" then
            local okSecret, secret = pcall(issecretvalue, dt)
            if okSecret and secret == true then
                return nil
            end
        end
        local okLower, lower = pcall(string.lower, dt)
        if not okLower or type(lower) ~= "string" then
            return nil
        end
        if lower == "magic" or lower == "type_magic" then return PARTY_HAZARD_ENUM.Magic end
        if lower == "curse" or lower == "type_curse" then return PARTY_HAZARD_ENUM.Curse end
        if lower == "disease" or lower == "type_disease" then return PARTY_HAZARD_ENUM.Disease end
        if lower == "poison" or lower == "type_poison" then return PARTY_HAZARD_ENUM.Poison end
        if lower == "bleed" or lower == "enrage" or lower == "type_bleed" or lower == "type_enrage" then
            return PARTY_HAZARD_ENUM.Bleed
        end
    end
    return NormalizePartyHazardEnum(dt)
end

local function PartyTruthyBoolOrCount(value)
    local vt = type(value)
    if vt == "boolean" then
        return value, true
    end
    if vt == "number" then
        if type(issecretvalue) == "function" then
            local okSecret, secret = pcall(issecretvalue, value)
            if okSecret and secret == true then
                return false, false
            end
        end
        return value > 0, true
    end
    return false, false
end

local function PartyTypeTableHasMatch(tbl, typeCode)
    if type(tbl) ~= "table" then
        return false
    end

    local wantedEnum = NormalizePartyTrackerTypeCode(typeCode)
    for key, direct in pairs(tbl) do
        local keyEnum = NormalizePartyTrackerTypeCode(key)
        if keyEnum and wantedEnum and keyEnum == wantedEnum then
            local b, used = PartyTruthyBoolOrCount(direct)
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
        local b, used = PartyTruthyBoolOrCount(v)
        if used then
            return b
        end
    end

    for key, v in pairs(tbl) do
        local keyEnum = NormalizePartyTrackerTypeCode(key)
        local valEnum = NormalizePartyTrackerTypeCode(v)
        if wantedEnum and ((keyEnum and keyEnum == wantedEnum) or (valEnum and valEnum == wantedEnum)) then
            return true
        end
    end
    return false
end

local function PartyTrackerHasTypeActive(unit, typeCode)
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
        local b, used = PartyTruthyBoolOrCount(result)
        if used then
            lastMethod = methodName
            return b
        end
        local wantedEnum = NormalizePartyTrackerTypeCode(typeCode)
        local resultEnum = NormalizePartyTrackerTypeCode(result)
        if wantedEnum and resultEnum and wantedEnum == resultEnum then
            lastMethod = methodName
            return true
        end
        if type(result) == "table" then
            lastMethod = methodName
            return PartyTypeTableHasMatch(result, typeCode)
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
            local wantedEnum = NormalizePartyTrackerTypeCode(typeCode)
            local topEnum = NormalizePartyTrackerTypeCode(topType)
            if wantedEnum and topEnum then
                return wantedEnum == topEnum, lastMethod
            end
            return topType == typeCode, lastMethod
        end
    end

    return false, lastMethod
end

local function ParsePartyHazardLabelText(text)
    if type(text) ~= "string" then
        return nil
    end
    local okUpper, upper = pcall(string.upper, text)
    if not okUpper or type(upper) ~= "string" then
        return nil
    end
    if upper:find("MAGIC", 1, true) then return PARTY_HAZARD_ENUM.Magic end
    if upper:find("CURSE", 1, true) then return PARTY_HAZARD_ENUM.Curse end
    if upper:find("DISEASE", 1, true) then return PARTY_HAZARD_ENUM.Disease end
    if upper:find("POISON", 1, true) then return PARTY_HAZARD_ENUM.Poison end
    if upper:find("BLEED", 1, true) or upper:find("ENRAGE", 1, true) then return PARTY_HAZARD_ENUM.Bleed end
    if upper:find("UNKNOWN", 1, true) then return PARTY_HAZARD_ENUM.Unknown end
    return nil
end

local function ParsePartyHazardSignatureText(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local primary, secondary
    for token in text:gmatch("[^%+]+") do
        local enum = ParsePartyHazardLabelText(token)
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

local function ParsePartyRGBText(text)
    if type(text) ~= "string" then
        return nil, nil, nil
    end
    local rText, gText, bText = text:match("([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)")
    if not rText then
        return nil, nil, nil
    end
    local r, g, b = tonumber(rText), tonumber(gText), tonumber(bText)
    if not r or not g or not b then
        return nil, nil, nil
    end
    local function Clamp01(v)
        if v < 0 then return 0 end
        if v > 1 then return 1 end
        return v
    end
    return Clamp01(r), Clamp01(g), Clamp01(b)
end

local function IsPartyBlizzTrackedUnit(unit)
    if type(unit) ~= "string" then
        return false
    end
    if unit == "player" then
        return true
    end
    return string.match(unit, "^party%d$") ~= nil
end

local function ResolvePartyHazardFromBlizzFrameDebuff(debuffFrame)
    if not debuffFrame then
        return nil
    end

    local dt = NormalizePartyHazardEnum(debuffFrame.debuffType)
    if not dt then
        dt = NormalizePartyHazardEnum(debuffFrame.dispelName)
    end
    if not dt then
        dt = NormalizePartyHazardEnum(debuffFrame.dispelType)
    end
    if not dt then
        dt = NormalizePartyHazardEnum(debuffFrame.type)
    end
    return dt
end

local function CountPartyBlizzAuraSet(tbl)
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
local _partySpellIDFields = { "spellID", "spellId", "auraSpellID", "auraSpellId" }

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
            stack = tonumber(df.count)
        elseif df.count.GetText then
            local okText, text = pcall(df.count.GetText, df.count)
            if okText and text ~= nil then
                if not IsPartySecretToken(text) then
                    local okNum, parsed = pcall(tonumber, text)
                    if okNum and type(parsed) == "number" then
                        stack = parsed
                    end
                end
            end
        end
    end
    if stack and stack > 1 then
        return math.floor(stack + 0.5)
    end
    return nil
end

local function ReadDebuffFrameSpellID(df)
    if not df then
        return nil
    end
    for _, field in ipairs(_partySpellIDFields) do
        local candidate = df[field]
        if candidate then
            local okSpellID, spellID = pcall(tonumber, candidate)
            if okSpellID and spellID and (not IsPartySecretValue(spellID)) and spellID > 0 then
                return spellID
            end
        end
    end
    return nil
end

local function StorePartyAura(entry, iid, isDispellable, dt, icon, stackCount, spellID)
    if not iid then
        return
    end
    entry.debuffs[iid] = true
    if isDispellable then
        entry.dispellable[iid] = true
    end
    if dt then
        entry.types[iid] = dt
    end
    if icon then
        entry.icons[iid] = icon
    end
    if stackCount and stackCount > 1 then
        entry.stacks[iid] = stackCount
    end
    local okSpellID, numericSpellID = pcall(tonumber, spellID)
    if okSpellID and numericSpellID and (not IsPartySecretValue(numericSpellID)) and numericSpellID > 0 then
        entry.spellIDs[iid] = numericSpellID
    end
end

local function CapturePartyHazardsFromBlizzFrame(blizzFrame)
    if not blizzFrame then
        return nil, nil
    end

    local unit = blizzFrame.unit
    if not IsPartyBlizzTrackedUnit(unit) then
        return nil, nil
    end
    if UnitExists and type(UnitExists) == "function" and not UnitExists(unit) then
        return nil, nil
    end

    local entry = _partyBlizzAuraCache[unit]
    if not entry then
        entry = { debuffs = {}, dispellable = {}, types = {}, icons = {}, stacks = {}, spellIDs = {} }
        _partyBlizzAuraCache[unit] = entry
    else
        if type(entry.icons) ~= "table" then
            entry.icons = {}
        end
        if type(entry.stacks) ~= "table" then
            entry.stacks = {}
        end
        if type(entry.spellIDs) ~= "table" then
            entry.spellIDs = {}
        end
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
                StorePartyAura(entry,
                    df.auraInstanceID,
                    false,
                    ResolvePartyHazardFromBlizzFrameDebuff(df),
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
                StorePartyAura(entry,
                    df.auraInstanceID,
                    true,
                    ResolvePartyHazardFromBlizzFrameDebuff(df),
                    ReadDebuffFrameIcon(df),
                    ReadDebuffFrameStack(df),
                    ReadDebuffFrameSpellID(df)
                )
            end
        end
    end

    return unit, entry
end

local function RefreshPartyFrameForUnitFromBlizzHook(unit)
    if not unit then
        return
    end
    if type(UpdatePartyUnit) ~= "function" then
        return
    end
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame and frame:IsShown() and frame.GetAttribute then
            local frameUnit = frame:GetAttribute("unit")
            if frameUnit == unit then
                pcall(UpdatePartyUnit, frame)
            end
        end
    end
end

local function PrimePartyBlizzAuraCache()
    local compactPlayerFrame = _G.CompactPlayerFrame
    if compactPlayerFrame and compactPlayerFrame.unit == "player" then
        CapturePartyHazardsFromBlizzFrame(compactPlayerFrame)
    end
    for i = 1, 5 do
        local compactParty = _G["CompactPartyFrameMember" .. tostring(i)]
        if compactParty and compactParty.unit then
            CapturePartyHazardsFromBlizzFrame(compactParty)
        end
    end
end

local function ResetPartyBlizzAuraCache()
    for unit, entry in pairs(_partyBlizzAuraCache) do
        if IsPartyBlizzTrackedUnit(unit) and type(entry) == "table" then
            wipe(entry.debuffs)
            wipe(entry.dispellable)
            wipe(entry.types)
            if type(entry.icons) == "table" then
                wipe(entry.icons)
            end
            if type(entry.stacks) == "table" then
                wipe(entry.stacks)
            end
            if type(entry.spellIDs) == "table" then
                wipe(entry.spellIDs)
            end
        end
    end
end

local function EnsurePartyBlizzAuraHook()
    if _partyBlizzHookRegistered then
        return
    end
    if type(hooksecurefunc) ~= "function" then
        return
    end

    local function OnBlizzAuraUpdate(blizzFrame)
        local unit = CapturePartyHazardsFromBlizzFrame(blizzFrame)
        if unit then
            RefreshPartyFrameForUnitFromBlizzHook(unit)
        end
    end

    if type(CompactUnitFrame_UpdateAuras) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateAuras", OnBlizzAuraUpdate)
        _partyBlizzHookRegistered = true
    end
    if type(CompactUnitFrame_UpdateDebuffs) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateDebuffs", OnBlizzAuraUpdate)
        _partyBlizzHookRegistered = true
    end

    if _partyBlizzHookRegistered then
        PrimePartyBlizzAuraCache()
    end
end

local function ShouldUsePartyTintOverride(enum, r, g, b)
    if r == nil or g == nil or b == nil then
        return false
    end
    local normalized = NormalizePartyHazardEnum(enum)
    if not normalized or normalized == PARTY_HAZARD_ENUM.Unknown then
        return false
    end

    -- Ignore transient black payloads that can appear during unknown->typed transitions.
    if r <= 0.02 and g <= 0.02 and b <= 0.02 then
        return false
    end

    local canonical = PARTY_HAZARD_COLORS[normalized]
    if not canonical then
        return false
    end
    local dr = r - (canonical[1] or 0)
    local dg = g - (canonical[2] or 0)
    local db = b - (canonical[3] or 0)
    local distSq = (dr * dr) + (dg * dg) + (db * db)
    return distSq <= 0.20
end

local function IsPartySecretValue(value)
    return IsPartySecretToken(value)
end

local function ClampPartyUnitColor(value)
    if value < 0 then return 0 end
    if value > 1 then return 1 end
    return value
end

MakePartySecretColor = function(r, g, b, source)
    if r == nil or g == nil or b == nil then
        return nil
    end
    return { r, g, b, secret = true, source = source }
end

local function CoercePartyTintChannel(value)
    if value == nil or IsPartySecretValue(value) then
        return nil
    end
    local number = tonumber(value)
    if type(number) ~= "number" then
        return nil
    end
    return ClampPartyUnitColor(number)
end

local function GetPartyHazardHintFromPlayerFrameCondTint()
    local frame = _G.MidnightUI_PlayerFrame
    if not frame then
        return nil, "playerframe-unavailable", nil, nil, nil
    end
    if frame._muiCondTintActive ~= true then
        return nil, "playerframe-condtint-off", nil, nil, nil
    end

    local source = type(frame._muiCondTintSource) == "string" and frame._muiCondTintSource or nil
    local enum = ParsePartyHazardLabelText(source)
    local r = CoercePartyTintChannel(frame._muiCondTintR)
    local g = CoercePartyTintChannel(frame._muiCondTintG)
    local b = CoercePartyTintChannel(frame._muiCondTintB)
    local hasNumericRGB = (r ~= nil and g ~= nil and b ~= nil)
    local hasColor = (frame._muiCondTintHasColor == true) or (frame._muiCondTintSecret == true) or hasNumericRGB

    if enum then
        if hasNumericRGB then
            return enum, "playerframe-condtint-enum-rgb", r, g, b
        end
        return enum, "playerframe-condtint-enum", nil, nil, nil
    end
    if hasColor then
        if hasNumericRGB then
            return PARTY_HAZARD_ENUM.Unknown, "playerframe-condtint-unknown-rgb", r, g, b
        end
        return PARTY_HAZARD_ENUM.Unknown, "playerframe-condtint-unknown", 0, 0, 0
    end
    return nil, "playerframe-condtint-none", nil, nil, nil
end

local function GetPartyHazardHintFromConditionBorder()
    local cb = _G.MidnightUI_ConditionBorder
    if cb and type(cb.GetStateSnapshot) == "function" then
        local okState, state = pcall(cb.GetStateSnapshot)
        if okState and type(state) == "table" then
            local source = "condborder-state-primary"
            local enum = NormalizePartyHazardEnum(state.primaryEnum)
            if not enum then
                enum = ParsePartyHazardLabelText(state.primaryLabel)
            end
            if not enum then
                enum = NormalizePartyHazardEnum(state.activePrimaryEnum)
                if enum then
                    source = "condborder-state-active-primary"
                end
            end
            if not enum then
                enum = NormalizePartyHazardEnum(state.curvePrimaryEnum)
                if enum then
                    source = "condborder-state-curve-primary"
                end
            end
            if not enum then
                enum = NormalizePartyHazardEnum(state.overlapPrimaryEnum)
                if enum then
                    source = "condborder-state-overlap-primary"
                end
            end
            if not enum then
                enum = NormalizePartyHazardEnum(state.hookPrimaryEnum)
                if enum then
                    source = "condborder-state-hook-primary"
                end
            end
            if not enum then
                enum = NormalizePartyHazardEnum(state.barTintEnum)
                if enum then
                    source = "condborder-state-bartint-enum"
                end
            end
            if not enum then
                enum = ParsePartyHazardLabelText(state.tintSource)
                if enum then
                    source = "condborder-state-tint-source"
                end
            end

            local stateActive = (state.active == true) or (state.tintActive == true)
            local stateRestricted = (state.inRestricted == true) or (tostring(state.inRestricted or "NO") == "YES")

            local activeSigPrimary, activeSigSecondary = ParsePartyHazardSignatureText(state.activeSignature)
            local hookSigPrimary, hookSigSecondary = ParsePartyHazardSignatureText(state.hookSignature)
            if not enum and activeSigPrimary then
                enum = activeSigPrimary
                source = "condborder-state-active-signature"
            end
            if not enum and hookSigPrimary then
                enum = hookSigPrimary
                source = "condborder-state-hook-signature"
            end

            local secondaryEnum = NormalizePartyHazardEnum(state.overlapSecondaryEnum)
            if not secondaryEnum then
                secondaryEnum = NormalizePartyHazardEnum(state.activeSecondaryEnum)
            end
            if not secondaryEnum then
                secondaryEnum = NormalizePartyHazardEnum(state.hookSecondaryEnum)
            end
            if not secondaryEnum then
                secondaryEnum = activeSigSecondary
            end
            if not secondaryEnum then
                secondaryEnum = hookSigSecondary
            end
            local typeBoxEnum = ParsePartyHazardLabelText(state.typeBoxEnum)
            if not secondaryEnum and typeBoxEnum and typeBoxEnum ~= PARTY_HAZARD_ENUM.Unknown then
                secondaryEnum = typeBoxEnum
            end
            local secondaryColor = nil
            local rawSecR, rawSecG, rawSecB = state.typeBoxR, state.typeBoxG, state.typeBoxB
            if rawSecR ~= nil and rawSecG ~= nil and rawSecB ~= nil then
                if IsPartySecretValue(rawSecR) or IsPartySecretValue(rawSecG) or IsPartySecretValue(rawSecB) then
                    secondaryColor = MakePartySecretColor(rawSecR, rawSecG, rawSecB, "condborder-state-typebox")
                else
                    local secR, secG, secB = tonumber(rawSecR), tonumber(rawSecG), tonumber(rawSecB)
                    if secR ~= nil and secG ~= nil and secB ~= nil then
                        secondaryColor = { secR, secG, secB }
                    end
                end
            end
            if not secondaryColor then
                local secR, secG, secB = ParsePartyRGBText(state.typeBoxRGB)
                if secR ~= nil and secG ~= nil and secB ~= nil then
                    secondaryColor = { secR, secG, secB }
                end
            end
            if secondaryEnum == PARTY_HAZARD_ENUM.Unknown then
                secondaryEnum = nil
            end

            local trackerBleed = (state.trackerBleed == true) or (tostring(state.trackerBleed) == "YES")
            if trackerBleed then
                if not enum then
                    enum = PARTY_HAZARD_ENUM.Bleed
                    source = "condborder-state-tracker-bleed-primary"
                elseif enum ~= PARTY_HAZARD_ENUM.Bleed and not secondaryEnum then
                    secondaryEnum = PARTY_HAZARD_ENUM.Bleed
                end
            end

            local r, g, b = ParsePartyRGBText(state.barTintRGB)
            if r == nil then
                r, g, b = ParsePartyRGBText(state.tintRGB)
            end
            local barTintOn = tostring(state.barTint or "OFF") == "ON"
            local active = (state.active == true) or (state.tintActive == true)

            if enum then
                return enum, source, r, g, b, secondaryEnum, stateActive, stateRestricted, secondaryColor
            end
            if barTintOn or active then
                local frameEnum, frameSource, frameR, frameG, frameB = GetPartyHazardHintFromPlayerFrameCondTint()
                if frameEnum and frameEnum ~= PARTY_HAZARD_ENUM.Unknown then
                    return frameEnum, "playerframe-fallback:" .. tostring(frameSource), frameR, frameG, frameB, secondaryEnum, true, stateRestricted, secondaryColor
                end
                if r ~= nil then
                    return PARTY_HAZARD_ENUM.Unknown, "condborder-state-unknown-rgb", r, g, b, secondaryEnum, true, stateRestricted, secondaryColor
                end
                return PARTY_HAZARD_ENUM.Unknown, "condborder-state-unknown", 0, 0, 0, secondaryEnum, true, stateRestricted, secondaryColor
            end
            return nil, "condborder-state-none", nil, nil, nil, secondaryEnum, stateActive, stateRestricted, secondaryColor
        end
    end

    local frameEnum, frameSource, frameR, frameG, frameB = GetPartyHazardHintFromPlayerFrameCondTint()
    if frameEnum then
        return frameEnum, frameSource, frameR, frameG, frameB, nil, true, false, nil
    end

    if not cb then
        return nil, "condborder-unavailable", nil, nil, nil, nil, false, false, nil
    end

    if type(cb.GetDiagLines) ~= "function" then
        return nil, "condborder-diag-unavailable", nil, nil, nil, nil, false, false, nil
    end

    local okLines, lines = pcall(cb.GetDiagLines, _G.MidnightUI_PlayerFrame)
    if not okLines or type(lines) ~= "table" then
        return nil, "condborder-diag-failed", nil, nil, nil, nil, false, false, nil
    end

    local primaryText, barTintText, borderStateText, barTintRGBText
    for _, line in ipairs(lines) do
        if type(line) == "string" then
            local p = line:match("^%s*primaryEnum%s*=%s*(.+)$")
            if p then
                primaryText = p
            end
            local b = line:match("^%s*barTint%s*=%s*(.+)$")
            if b then
                barTintText = b
            end
            local s = line:match("^%s*borderState%s*=%s*(.+)$")
            if s then
                borderStateText = s
            end
            local rgb = line:match("^%s*barTintRGB%s*=%s*(.+)$")
            if rgb then
                barTintRGBText = rgb
            end
        end
    end

    local enum = ParsePartyHazardLabelText(primaryText)
    local r, g, b = ParsePartyRGBText(barTintRGBText)
    if enum then
        return enum, "condborder-primary", r, g, b, nil, true, false, nil
    end
    enum = ParsePartyHazardLabelText(barTintText)
    if enum then
        return enum, "condborder-bartint", r, g, b, nil, true, false, nil
    end

    local barTintOn = type(barTintText) == "string" and string.find(barTintText, "ON", 1, true) ~= nil
    local borderVisible = type(borderStateText) == "string" and string.find(borderStateText, "VISIBLE", 1, true) ~= nil
    if barTintOn or borderVisible then
        if r ~= nil then
            return PARTY_HAZARD_ENUM.Unknown, "condborder-diag-unknown-rgb", r, g, b, nil, true, false, nil
        end
        return PARTY_HAZARD_ENUM.Unknown, "condborder-diag-unknown", 0, 0, 0, nil, true, false, nil
    end

    return nil, "condborder-none", nil, nil, nil, nil, false, false, nil
end

local function IsPartyCurveColorMatch(color, expected)
    if not color or not expected then
        return false
    end
    if type(color.GetRGBA) ~= "function" or type(expected.GetRGBA) ~= "function" then
        return false
    end
    local okA, ar, ag, ab, aa = pcall(color.GetRGBA, color)
    if not okA then
        return false
    end
    local okB, er, eg, eb, ea = pcall(expected.GetRGBA, expected)
    if not okB then
        return false
    end
    local vals = { ar, ag, ab, aa, er, eg, eb, ea }
    for i = 1, #vals do
        if type(issecretvalue) == "function" then
            local okSecret, secret = pcall(issecretvalue, vals[i])
            if okSecret and secret == true then
                return false
            end
        end
        if type(vals[i]) ~= "number" then
            return false
        end
    end
    if math.abs(ar - er) > PARTY_HAZARD_CURVE_EPSILON then return false end
    if math.abs(ag - eg) > PARTY_HAZARD_CURVE_EPSILON then return false end
    if math.abs(ab - eb) > PARTY_HAZARD_CURVE_EPSILON then return false end
    if math.abs(aa - ea) > PARTY_HAZARD_CURVE_EPSILON then return false end
    return true
end

local function IsPartyCurveColorDifferent(a, b)
    if not a or not b then
        return false
    end
    if type(a.GetRGBA) ~= "function" or type(b.GetRGBA) ~= "function" then
        return false
    end
    local okA, ar, ag, ab, aa = pcall(a.GetRGBA, a)
    if not okA then
        return false
    end
    local okB, br, bg, bb, ba = pcall(b.GetRGBA, b)
    if not okB then
        return false
    end
    local vals = { ar, ag, ab, aa, br, bg, bb, ba }
    for i = 1, #vals do
        if type(issecretvalue) == "function" then
            local okSecret, secret = pcall(issecretvalue, vals[i])
            if okSecret and secret == true then
                return false
            end
        end
        if type(vals[i]) ~= "number" then
            return false
        end
    end
    if math.abs(ar - br) > PARTY_HAZARD_CURVE_EPSILON then return true end
    if math.abs(ag - bg) > PARTY_HAZARD_CURVE_EPSILON then return true end
    if math.abs(ab - bb) > PARTY_HAZARD_CURVE_EPSILON then return true end
    if math.abs(aa - ba) > PARTY_HAZARD_CURVE_EPSILON then return true end
    return false
end

local function GetPartyHazardProbeCurve(targetEnum)
    local normalized = NormalizePartyHazardEnum(targetEnum)
    if not normalized then
        return nil
    end
    if _partyHazardProbeCurves[normalized] then
        return _partyHazardProbeCurves[normalized]
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
        local pointEnum = NormalizePartyHazardEnum(enumValue)
        local alpha = (pointEnum == normalized) and 1 or 0
        curve:AddPoint(enumValue, CreateColor(1, 1, 1, alpha))
    end

    Add(PARTY_HAZARD_ENUM.None)
    Add(PARTY_HAZARD_ENUM.Magic)
    Add(PARTY_HAZARD_ENUM.Curse)
    Add(PARTY_HAZARD_ENUM.Disease)
    Add(PARTY_HAZARD_ENUM.Poison)
    Add(PARTY_HAZARD_ENUM.Enrage)
    Add(PARTY_HAZARD_ENUM.Bleed)

    _partyHazardProbeCurves[normalized] = curve
    _partyHazardProbeMatchColors[normalized] = CreateColor(1, 1, 1, 1)
    return curve
end

local function GetPartyHazardZeroProbeCurve()
    if _partyHazardZeroProbeCurve then
        return _partyHazardZeroProbeCurve
    end
    if not C_CurveUtil or not C_CurveUtil.CreateColorCurve then
        return nil
    end
    if not Enum or not Enum.LuaCurveType then
        return nil
    end

    local curve = C_CurveUtil.CreateColorCurve()
    curve:SetType(Enum.LuaCurveType.Step)
    curve:AddPoint(PARTY_HAZARD_ENUM.None, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Magic, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Curse, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Disease, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Poison, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Enrage, CreateColor(1, 1, 1, 0))
    curve:AddPoint(PARTY_HAZARD_ENUM.Bleed, CreateColor(1, 1, 1, 0))
    _partyHazardZeroProbeCurve = curve
    return curve
end

local function ResolvePartyHazardEnumByCurve(unit, auraInstanceID)
    if not unit or not auraInstanceID then
        return nil
    end
    if not C_UnitAuras or type(C_UnitAuras.GetAuraDispelTypeColor) ~= "function" then
        return nil
    end

    local zeroCurve = GetPartyHazardZeroProbeCurve()
    for _, enum in ipairs(PARTY_HAZARD_PRIORITY) do
        local curve = GetPartyHazardProbeCurve(enum)
        if curve then
            local okColor, color = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, curve)
            if okColor and color then
                if zeroCurve then
                    local okZero, zeroColor = pcall(C_UnitAuras.GetAuraDispelTypeColor, unit, auraInstanceID, zeroCurve)
                    if okZero and IsPartyCurveColorDifferent(color, zeroColor) then
                        return enum
                    end
                end
                local expected = _partyHazardProbeMatchColors[NormalizePartyHazardEnum(enum)]
                if expected and IsPartyCurveColorMatch(color, expected) then
                    return enum
                end
            end
        end
    end

    return nil
end

local function ResolvePartyHazardFromAuraInstanceID(unit, auraInstanceID, typeHint)
    local dt = NormalizePartyHazardEnum(typeHint)
    if dt then
        return dt, "blizz:type"
    end
    dt = ResolvePartyHazardEnumByCurve(unit, auraInstanceID)
    if dt then
        return dt, "blizz:curve"
    end
    return nil, nil
end

local function ResolvePartyHazardFromAura(unit, aura)
    if not aura then
        return nil, nil
    end
    local dt = NormalizePartyHazardEnum(aura.dispelType)
    if dt then return dt, "field:dispelType" end
    dt = NormalizePartyHazardEnum(aura.dispelName)
    if dt then return dt, "field:dispelName" end
    dt = NormalizePartyHazardEnum(aura.debuffType)
    if dt then return dt, "field:debuffType" end
    dt = NormalizePartyHazardEnum(aura.type)
    if dt then return dt, "field:type" end
    if aura.auraInstanceID then
        dt = ResolvePartyHazardEnumByCurve(unit, aura.auraInstanceID)
        if dt then
            return dt, "curve"
        end
    end
    return nil, nil
end

local function CollectPartyHazardsForUnit(unit)
    local hazards = {}
    local seen = {}
    local trackerAvailable = (_G.MidnightUI_DebuffTracker ~= nil)
    local diag = {
        unit = tostring(unit or "nil"),
        inRestricted = (InCombatLockdown and InCombatLockdown()) and "YES" or "NO",
        scanned = 0,
        fieldHits = 0,
        curveHits = 0,
        blizzHits = 0,
        blizzDebuffs = 0,
        blizzDispellable = 0,
        trackerHits = 0,
        condHits = 0,
        blizzAvail = "NO",
        trackerAvail = trackerAvailable and "YES" or "NO",
        trackerMethod = "none",
        trackerTypes = "none",
        condSource = "none",
        condActive = "NO",
        condSecondary = "none",
        condSecondaryRGB = "none",
        condRGB = "none",
        condOverride = "NO",
        condSecret = "NO",
        customPrimaryColor = nil,
        customSecondaryColor = nil,
    }

    local function AddHazard(enum, source)
        if not enum or seen[enum] then
            return false
        end
        seen[enum] = true
        hazards[#hazards + 1] = enum
        if source == "curve" then
            diag.curveHits = diag.curveHits + 1
        elseif type(source) == "string" and source:match("^blizz:") then
            diag.blizzHits = diag.blizzHits + 1
            if source == "blizz:curve" then
                diag.curveHits = diag.curveHits + 1
            end
        elseif source == "tracker" then
            diag.trackerHits = diag.trackerHits + 1
        elseif source == "condborder" then
            diag.condHits = diag.condHits + 1
        elseif type(source) == "string" and source:match("^field:") then
            diag.fieldHits = diag.fieldHits + 1
        end
        return true
    end

    local condEnum, condSource, condR, condG, condB, condSecondaryEnum, condActive, condRestricted, condSecondaryColor
    if unit == "player" then
        condEnum, condSource, condR, condG, condB, condSecondaryEnum, condActive, condRestricted, condSecondaryColor = GetPartyHazardHintFromConditionBorder()
        diag.condSource = condSource or "none"
        diag.condActive = condActive and "YES" or "NO"
        diag.condSecondary = PARTY_HAZARD_LABELS[NormalizePartyHazardEnum(condSecondaryEnum)] or "none"
        if type(condSecondaryColor) == "table" then
            if condSecondaryColor.secret == true then
                local sr, sg, sb = condSecondaryColor[1], condSecondaryColor[2], condSecondaryColor[3]
                if sr ~= nil and sg ~= nil and sb ~= nil then
                    diag.condSecondaryRGB = "secret"
                    diag.customSecondaryColor = MakePartySecretColor(sr, sg, sb, condSecondaryColor.source or condSource)
                    if diag.condSecondary == "none" then
                        diag.condSecondary = "SECRET"
                    end
                end
            else
                local sr, sg, sb = tonumber(condSecondaryColor[1]), tonumber(condSecondaryColor[2]), tonumber(condSecondaryColor[3])
                if sr and sg and sb then
                    diag.condSecondaryRGB = string.format("%.3f,%.3f,%.3f", sr, sg, sb)
                    diag.customSecondaryColor = { sr, sg, sb }
                    if diag.condSecondary == "none" then
                        diag.condSecondary = "SECRET"
                    end
                end
            end
        end
        if condRestricted then
            diag.inRestricted = "YES"
        end
        if condR ~= nil and condG ~= nil and condB ~= nil then
            diag.condRGB = string.format("%.3f,%.3f,%.3f", condR, condG, condB)
            if ShouldUsePartyTintOverride(condEnum, condR, condG, condB) then
                local normalizedCondEnum = NormalizePartyHazardEnum(condEnum)
                local canonical = normalizedCondEnum and PARTY_HAZARD_COLORS[normalizedCondEnum] or nil
                if canonical then
                    diag.customPrimaryColor = { canonical[1], canonical[2], canonical[3] }
                else
                    diag.customPrimaryColor = { condR, condG, condB }
                end
                diag.condOverride = "YES"
            end
        end
        if not diag.customPrimaryColor then
            local playerFrame = _G.MidnightUI_PlayerFrame
            if playerFrame
                and playerFrame._muiCondTintActive == true
                and playerFrame._muiCondTintHasColor == true
                and playerFrame._muiCondTintSecret == true then
                local sr, sg, sb = playerFrame._muiCondTintR, playerFrame._muiCondTintG, playerFrame._muiCondTintB
                if sr ~= nil and sg ~= nil and sb ~= nil then
                    diag.customPrimaryColor = MakePartySecretColor(sr, sg, sb, playerFrame._muiCondTintSource)
                    diag.condOverride = "SECRET"
                    diag.condSecret = "YES"
                    diag.condRGB = "secret"
                    if type(diag.condSource) == "string" and diag.condSource ~= "none" then
                        diag.condSource = diag.condSource .. "+playerframe-secret"
                    else
                        diag.condSource = "playerframe-secret"
                    end
                end
            end
        end
        if diag.inRestricted == "YES" then
            if condEnum then
                AddHazard(condEnum, "condborder")
            end
            if condSecondaryEnum and #hazards < 2 then
                AddHazard(condSecondaryEnum, "condborder")
            end
        end
    end

    if #hazards < 2 then
        local blizzEntry = _partyBlizzAuraCache[unit]
        if type(blizzEntry) == "table" then
            diag.blizzAvail = "YES"
            diag.blizzDebuffs = CountPartyBlizzAuraSet(blizzEntry.debuffs)
            diag.blizzDispellable = CountPartyBlizzAuraSet(blizzEntry.dispellable)

            local function AddFromAuraSet(auraSet)
                if type(auraSet) ~= "table" or #hazards >= 2 then
                    return
                end

                local foundByEnum = {}
                for iid in pairs(auraSet) do
                    local hint = blizzEntry.types and blizzEntry.types[iid] or nil
                    local enum, source = ResolvePartyHazardFromAuraInstanceID(unit, iid, hint)
                    if enum and not foundByEnum[enum] then
                        foundByEnum[enum] = source or "blizz:type"
                    end
                end

                for _, enum in ipairs(PARTY_HAZARD_PRIORITY) do
                    if #hazards >= 2 then
                        break
                    end
                    local source = foundByEnum[enum]
                    if source then
                        AddHazard(enum, source)
                    end
                end
            end

            AddFromAuraSet(blizzEntry.dispellable)
            AddFromAuraSet(blizzEntry.debuffs)

        end
    end

    if #hazards < 2 and diag.inRestricted ~= "YES" then
        if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
            for i = 1, 40 do
                local okAura, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HARMFUL")
                if not okAura then
                    break
                end
                if not aura then
                    break
                end
                diag.scanned = diag.scanned + 1
                local enum, source = ResolvePartyHazardFromAura(unit, aura)
                AddHazard(enum, source)
                if #hazards >= 2 then
                    break
                end
            end
        elseif UnitDebuff then
            for i = 1, 40 do
                local _, _, _, debuffType = UnitDebuff(unit, i)
                if not debuffType then
                    break
                end
                diag.scanned = diag.scanned + 1
                AddHazard(NormalizePartyHazardEnum(debuffType), "field:legacyDebuffType")
                if #hazards >= 2 then
                    break
                end
            end
        end
    end

    if #hazards < 2 and trackerAvailable then
        local trackerLabels = {}
        local trackerMap = {
            { PARTY_HAZARD_ENUM.Magic,   { 1, "MAGIC", "type_magic" }, "MAGIC" },
            { PARTY_HAZARD_ENUM.Curse,   { 2, "CURSE", "type_curse" }, "CURSE" },
            { PARTY_HAZARD_ENUM.Disease, { 3, "DISEASE", "type_disease" }, "DISEASE" },
            { PARTY_HAZARD_ENUM.Poison,  { 4, "POISON", "type_poison" }, "POISON" },
            { PARTY_HAZARD_ENUM.Bleed,   { 6, 9, 11, "BLEED", "ENRAGE", "type_bleed", "type_enrage" }, "BLEED" },
        }
        for _, item in ipairs(trackerMap) do
            if #hazards >= 2 then
                break
            end
            local enum, codes, label = item[1], item[2], item[3]
            local matched = false
            for _, code in ipairs(codes) do
                local isActive, method = PartyTrackerHasTypeActive(unit, code)
                if method and method ~= "none" and diag.trackerMethod == "none" then
                    diag.trackerMethod = method
                end
                if isActive then
                    matched = true
                    break
                end
            end
            if matched then
                AddHazard(enum, "tracker")
                trackerLabels[#trackerLabels + 1] = label
            end
        end
        if #trackerLabels > 0 then
            diag.trackerTypes = table.concat(trackerLabels, "+")
        end
    end

    if unit == "player" then
        if not hazards[1] and condEnum then
            AddHazard(condEnum, "condborder")
        elseif hazards[1] == PARTY_HAZARD_ENUM.Unknown and condEnum and condEnum ~= PARTY_HAZARD_ENUM.Unknown then
            seen[PARTY_HAZARD_ENUM.Unknown] = nil
            hazards[1] = condEnum
            seen[condEnum] = true
            diag.condHits = diag.condHits + 1
        end
        if condSecondaryEnum and #hazards < 2 then
            AddHazard(condSecondaryEnum, "condborder")
        end
    end

    local resolvedPrimary = hazards[1]
    local resolvedSecondary = hazards[2]

    -- Restricted fallback: when we can count multiple debuffs but cannot resolve a
    -- second typed hazard/color, synthesize an unknown secondary so sweep can run.
    local unresolvedSecondaryByRestriction = (unit == "player")
        and (resolvedPrimary ~= nil)
        and (resolvedSecondary == nil)
        and (diag.inRestricted == "YES")
        and (diag.condSecondary == "none")
        and ((diag.blizzDebuffs or 0) >= 2 or (diag.scanned or 0) >= 2)
        and ((diag.blizzHits or 0) == 0)
        and ((diag.fieldHits or 0) == 0)
        and ((diag.trackerHits or 0) == 0)
    if unresolvedSecondaryByRestriction then
        resolvedSecondary = PARTY_HAZARD_ENUM.Unknown
        if type(diag.customSecondaryColor) ~= "table" then
            local unknownColor = PARTY_UNKNOWN_SWEEP_COLOR
            if type(unknownColor) == "table" then
                local r = tonumber(unknownColor[1])
                local g = tonumber(unknownColor[2])
                local b = tonumber(unknownColor[3])
                if r and g and b then
                    diag.customSecondaryColor = { r, g, b }
                end
            end
        end
        if diag.condSecondary == "none" then
            diag.condSecondary = "UNKNOWN"
        end
        if diag.condSecondaryRGB == "none" and type(diag.customSecondaryColor) == "table" then
            local sr = tonumber(diag.customSecondaryColor[1])
            local sg = tonumber(diag.customSecondaryColor[2])
            local sb = tonumber(diag.customSecondaryColor[3])
            if sr and sg and sb then
                diag.condSecondaryRGB = string.format("%.3f,%.3f,%.3f", sr, sg, sb)
            end
        end
    end

    diag.primary = PARTY_HAZARD_LABELS[resolvedPrimary] or "NONE"
    diag.secondary = PARTY_HAZARD_LABELS[resolvedSecondary] or "NONE"
    if not resolvedPrimary then
        if diag.scanned == 0 then
            diag.reason = "no-harmful-auras"
        elseif diag.trackerAvail == "NO" then
            diag.reason = "unresolved-no-tracker"
        else
            diag.reason = "unresolved-tracker-miss"
        end
    else
        diag.reason = "resolved"
    end
    diag.key = BuildPartyDiagKey(
        diag.primary,
        diag.secondary,
        diag.scanned,
        diag.fieldHits,
        diag.curveHits,
        diag.blizzHits,
        diag.blizzDebuffs,
        diag.blizzDispellable,
        diag.blizzAvail,
        diag.trackerHits,
        diag.condHits,
        diag.trackerAvail,
        diag.trackerMethod,
        diag.trackerTypes,
        diag.condSource,
        diag.condActive,
        diag.condSecondary,
        diag.condSecondaryRGB,
        diag.condRGB,
        diag.condOverride,
        diag.condSecret,
        diag.reason
    )

    return resolvedPrimary, resolvedSecondary, diag
end

local function BuildPartyDebuffOverlay(frame)
    if not frame or frame._muiDebuffOverlay then
        return frame and frame._muiDebuffOverlay
    end

    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetAllPoints(frame)
    overlay:SetFrameLevel(frame:GetFrameLevel() + 30)
    overlay:SetAlpha(0)
    overlay:Hide()

    local function MakeSolid(parent)
        local tex = parent:CreateTexture(nil, "OVERLAY")
        tex:SetTexture("Interface\\Buttons\\WHITE8X8")
        return tex
    end

    local bgFill = MakeSolid(overlay)
    bgFill:SetAllPoints(overlay)
    bgFill:SetBlendMode("ADD")
    bgFill:SetAlpha(0.12)
    overlay.bgFill = bgFill

    local fillPulse = bgFill:CreateAnimationGroup()
    fillPulse:SetLooping("BOUNCE")
    local fillAnim = fillPulse:CreateAnimation("Alpha")
    fillAnim:SetFromAlpha(0.12)
    fillAnim:SetToAlpha(0.13)
    fillAnim:SetDuration(1.80)
    fillAnim:SetSmoothing("IN_OUT")
    overlay.fillPulse = fillPulse

    local bracketFrame = CreateFrame("Frame", nil, overlay)
    bracketFrame:SetAllPoints(overlay)
    bracketFrame:SetAlpha(0.56)
    overlay.bracketFrame = bracketFrame

    local brackets = {}
    local bThick, bLen, offset = 2, 12, 2
    local function AddBracket(point, x, y, w, h)
        local tex = MakeSolid(bracketFrame)
        tex:SetPoint(point, x, y)
        tex:SetSize(w, h)
        brackets[#brackets + 1] = tex
    end
    AddBracket("TOPLEFT", -offset, offset, bLen, bThick)
    AddBracket("TOPLEFT", -offset, offset, bThick, bLen)
    AddBracket("TOPRIGHT", offset, offset, bLen, bThick)
    AddBracket("TOPRIGHT", offset, offset, bThick, bLen)
    AddBracket("BOTTOMLEFT", -offset, -offset, bLen, bThick)
    AddBracket("BOTTOMLEFT", -offset, -offset, bThick, bLen)
    AddBracket("BOTTOMRIGHT", offset, -offset, bLen, bThick)
    AddBracket("BOTTOMRIGHT", offset, -offset, bThick, bLen)
    overlay.brackets = brackets

    local bracketPulse = bracketFrame:CreateAnimationGroup()
    bracketPulse:SetLooping("BOUNCE")
    local bracketAnim = bracketPulse:CreateAnimation("Alpha")
    bracketAnim:SetFromAlpha(0.52)
    bracketAnim:SetToAlpha(0.62)
    bracketAnim:SetDuration(1.80)
    bracketAnim:SetSmoothing("IN_OUT")
    overlay.bracketPulse = bracketPulse

    local sweep = CreateFrame("Frame", nil, overlay)
    sweep:SetAllPoints(overlay)
    sweep:SetFrameLevel(overlay:GetFrameLevel() + 8)
    sweep:EnableMouse(false)
    sweep:SetClipsChildren(true)
    sweep:Hide()
    overlay.sweep = sweep

    local sweepFx = CreateFrame("Frame", nil, sweep)
    sweepFx:SetSize(72, 128)
    sweepFx:SetPoint("CENTER", sweep, "LEFT", -72, 0)
    overlay.sweepFx = sweepFx

    local function CreateSweepBand(isReverse)
        local tex = sweepFx:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("TOP", sweepFx, "TOP", 0, 0)
        tex:SetPoint("BOTTOM", sweepFx, "BOTTOM", 0, 0)
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
    for i = 1, 7 do
        bandPairs[i] = {
            a = CreateSweepBand(false),
            b = CreateSweepBand(true),
        }
    end
    overlay.sweepBands = bandPairs

    local moveGroup = sweepFx:CreateAnimationGroup()
    moveGroup:SetLooping("REPEAT")
    local moveAnim = moveGroup:CreateAnimation("Translation")
    moveAnim:SetOffset(420, 0)
    moveAnim:SetDuration(1.12)
    moveAnim:SetSmoothing("IN_OUT")
    overlay.sweepMoveGroup = moveGroup
    overlay.sweepMoveAnim = moveAnim
    overlay.sweepLayoutKey = nil
    overlay._muiOwnerFrame = frame
    overlay._muiSweepMotionKey = nil

    local fadeIn = overlay:CreateAnimationGroup()
    local inAnim = fadeIn:CreateAnimation("Alpha")
    inAnim:SetFromAlpha(0)
    inAnim:SetToAlpha(1)
    inAnim:SetDuration(0.40)
    inAnim:SetSmoothing("OUT")
    fadeIn:SetScript("OnPlay", function()
        overlay:SetAlpha(0)
        overlay:Show()
    end)
    fadeIn:SetScript("OnFinished", function(_, requested)
        if not requested then
            overlay:SetAlpha(1)
        end
    end)
    overlay.fadeIn = fadeIn

    local fadeOut = overlay:CreateAnimationGroup()
    local outAnim = fadeOut:CreateAnimation("Alpha")
    outAnim:SetFromAlpha(1)
    outAnim:SetToAlpha(0)
    outAnim:SetDuration(0.60)
    outAnim:SetSmoothing("OUT")
    fadeOut:SetScript("OnPlay", function()
        overlay:SetAlpha(1)
    end)
    fadeOut:SetScript("OnFinished", function(_, requested)
        if requested then
            return
        end
        overlay:SetAlpha(0)
        overlay:Hide()
        if overlay.fillPulse and overlay.fillPulse:IsPlaying() then
            overlay.fillPulse:Stop()
        end
        if overlay.bracketPulse and overlay.bracketPulse:IsPlaying() then
            overlay.bracketPulse:Stop()
        end
        if overlay.sweepMoveGroup and overlay.sweepMoveGroup:IsPlaying() then
            overlay.sweepMoveGroup:Stop()
        end
        if overlay.sweep then
            overlay.sweep:Hide()
        end
        if overlay.bgFill then
            overlay.bgFill:SetAlpha(0.12)
        end
        if overlay.bracketFrame then
            overlay.bracketFrame:SetAlpha(0.56)
        end
    end)
    overlay.fadeOut = fadeOut

    frame._muiDebuffOverlay = overlay
    return overlay
end

local function GetPartyDebuffOverlayDisplaySize(frame)
    local width = tonumber(frame and frame:GetWidth()) or 0
    local height = tonumber(frame and frame:GetHeight()) or 0
    if width <= 1 then width = tonumber(config.width) or 240 end
    if height <= 1 then height = tonumber(config.height) or 58 end

    if config.style == "Square" then
        local diameter = tonumber(config.diameter) or math.min(width, height)
        if diameter <= 1 then
            diameter = math.min(width, height)
        end
        width = math.max(1, math.min(width, height, diameter))
    end

    return width, height
end

local function LayoutPartyDebuffOverlay(overlay, frame)
    if not overlay or not frame then
        return
    end

    local overlayWidth = GetPartyDebuffOverlayDisplaySize(frame)

    overlay:ClearAllPoints()
    if config.style == "Square" then
        overlay:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        overlay:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        overlay:SetWidth(overlayWidth)
    else
        overlay:SetAllPoints(frame)
    end

    if overlay.bgFill then
        overlay.bgFill:ClearAllPoints()
        overlay.bgFill:SetAllPoints(overlay)
    end
    if overlay.bracketFrame then
        overlay.bracketFrame:ClearAllPoints()
        overlay.bracketFrame:SetAllPoints(overlay)
    end
    if overlay.sweep then
        overlay.sweep:ClearAllPoints()
        overlay.sweep:SetAllPoints(overlay)
    end
end

local function LayoutPartyDebuffSweep(overlay, frame)
    if not overlay or not frame then
        return
    end
    local width = tonumber(overlay:GetWidth()) or 0
    local height = tonumber(overlay:GetHeight()) or 0
    if width <= 1 then width = tonumber(frame:GetWidth()) or 0 end
    if height <= 1 then height = tonumber(frame:GetHeight()) or 0 end
    if width <= 1 then width = 240 end
    if height <= 1 then height = 58 end

    local beamW = math.max(math.floor(width * 0.32 + 0.5), 56)
    local beamH = math.max(math.floor(height * 2.55 + 0.5), 110)
    local moveDistance = width + (beamW * 2.95)
    local duration = 1.12
    local layoutKey = tostring(math.floor(width + 0.5))
        .. "x" .. tostring(math.floor(height + 0.5))
        .. ":" .. tostring(beamW)
        .. ":" .. tostring(beamH)
    if overlay.sweepLayoutKey == layoutKey then
        return
    end
    overlay.sweepLayoutKey = layoutKey

    if overlay.sweepFx then
        overlay.sweepFx:ClearAllPoints()
        overlay.sweepFx:SetSize(beamW, beamH)
        overlay.sweepFx:SetPoint("CENTER", overlay.sweep, "LEFT", -beamW, 0)
    end

    local bandWidths = {
        math.max(math.floor(beamW * 1.18 + 0.5), 30),
        beamW,
        math.max(math.floor(beamW * 0.84 + 0.5), 26),
        math.max(math.floor(beamW * 0.68 + 0.5), 20),
        math.max(math.floor(beamW * 0.54 + 0.5), 16),
        math.max(math.floor(beamW * 0.40 + 0.5), 12),
        math.max(math.floor(beamW * 0.28 + 0.5), 8),
    }
    if overlay.sweepBands then
        for i, pair in ipairs(overlay.sweepBands) do
            local w = bandWidths[i] or beamW
            if pair.a then
                pair.a:ClearAllPoints()
                pair.a:SetPoint("TOP", overlay.sweepFx, "TOP", 0, 0)
                pair.a:SetPoint("BOTTOM", overlay.sweepFx, "BOTTOM", 0, 0)
                pair.a:SetWidth(w)
            end
            if pair.b then
                pair.b:ClearAllPoints()
                pair.b:SetPoint("TOP", overlay.sweepFx, "TOP", 0, 0)
                pair.b:SetPoint("BOTTOM", overlay.sweepFx, "BOTTOM", 0, 0)
                pair.b:SetWidth(w)
            end
        end
    end

    if overlay.sweepMoveAnim then
        overlay.sweepMoveAnim:SetOffset(moveDistance, 0)
        overlay.sweepMoveAnim:SetDuration(duration)
        overlay.sweepMoveAnim:SetSmoothing("IN_OUT")
    end
    if overlay.sweepMoveGroup and overlay.sweepMoveGroup:IsPlaying() then
        overlay.sweepMoveGroup:Stop()
        overlay.sweepMoveGroup:Play()
    end
end

local function GetPartyUnknownFallbackColor(frame)
    local classColor = frame and frame._muiClassColor
    local r, g, b = nil, nil, nil
    if type(classColor) == "table" then
        r = tonumber(classColor.r or classColor[1])
        g = tonumber(classColor.g or classColor[2])
        b = tonumber(classColor.b or classColor[3])
    end
    if r == nil or g == nil or b == nil then
        r = DEFAULT_CLASS_COLOR.r or 0.5
        g = DEFAULT_CLASS_COLOR.g or 0.5
        b = DEFAULT_CLASS_COLOR.b or 0.5
    end
    return { ClampPartyUnitColor(r), ClampPartyUnitColor(g), ClampPartyUnitColor(b) }
end

local function ClonePartyColor(color)
    if type(color) ~= "table" then
        return nil
    end
    if color.secret == true then
        if color[1] == nil or color[2] == nil or color[3] == nil then
            return nil
        end
        return { color[1], color[2], color[3], secret = true, source = color.source }
    end
    local r = tonumber(color[1] or color.r)
    local g = tonumber(color[2] or color.g)
    local b = tonumber(color[3] or color.b)
    if not r or not g or not b then
        return nil
    end
    return { ClampPartyUnitColor(r), ClampPartyUnitColor(g), ClampPartyUnitColor(b) }
end

local function IsPartySecretColor(color)
    return type(color) == "table" and color.secret == true
end

local function IsPartyUnknownHazardSource(source)
    return type(source) == "string" and string.find(source, "unknown", 1, true) ~= nil
end

local function SetPartyRenderedSecretPolish(bar, suppressed)
    if not bar then
        return
    end
    if suppressed ~= true then
        bar._muiPartySecretRenderedPolish = false
        return
    end
    if bar._muiRenderedTop then
        pcall(bar._muiRenderedTop.SetBlendMode, bar._muiRenderedTop, "ADD")
        bar._muiRenderedTop:SetGradient("VERTICAL",
            CreateColor(0.09, 0.09, 0.09, 1),
            CreateColor(0.00, 0.00, 0.00, 1))
        bar._muiRenderedTop:Show()
    end
    if bar._muiRenderedBottom then
        pcall(bar._muiRenderedBottom.SetBlendMode, bar._muiRenderedBottom, "ADD")
        bar._muiRenderedBottom:SetGradient("VERTICAL",
            CreateColor(0.00, 0.00, 0.00, 1),
            CreateColor(0.09, 0.09, 0.09, 1))
        bar._muiRenderedBottom:Show()
    end
    if bar._muiRenderedGloss then
        bar._muiRenderedGloss:Hide()
    end
    bar._muiPartySecretRenderedPolish = true
end

local function SetPartyDebuffPrimaryColor(overlay, frame, enum, customColor)
    local color = customColor
    if not color then
        if enum == PARTY_HAZARD_ENUM.Unknown then
            color = GetPartyUnknownFallbackColor(frame)
        else
            color = PARTY_HAZARD_COLORS[enum]
        end
    end
    if IsPartySecretColor(color) then
        if overlay.bgFill then
            overlay.bgFill:SetVertexColor(color[1], color[2], color[3], 1)
        end
        if overlay.brackets then
            for _, bracket in ipairs(overlay.brackets) do
                bracket:SetVertexColor(color[1], color[2], color[3], 1)
            end
        end
        return
    end
    if not color then
        return
    end
    if overlay.bgFill then
        overlay.bgFill:SetVertexColor(color[1], color[2], color[3], 1)
    end
    if overlay.brackets then
        for _, bracket in ipairs(overlay.brackets) do
            bracket:SetVertexColor(color[1], color[2], color[3], 1)
        end
    end
end

local function SetPartyDebuffSecondaryColor(overlay, enum, customColor)
    if not overlay or not overlay.sweepBands then
        return
    end
    local color = customColor
    if IsPartySecretColor(color) then
        color = { color[1], color[2], color[3] }
    end
    if not color then
        if enum == PARTY_HAZARD_ENUM.Unknown then
            color = PARTY_UNKNOWN_SWEEP_COLOR
        else
            color = PARTY_HAZARD_COLORS[enum]
        end
    end
    if not color then
        return
    end
    local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
    if enum == PARTY_HAZARD_ENUM.Unknown then
        bandAlpha = { 0.014, 0.022, 0.032, 0.045, 0.062, 0.084, 0.112 }
    elseif type(customColor) == "table" and enum == nil then
        bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
    end
    for i, pair in ipairs(overlay.sweepBands) do
        local alpha = bandAlpha[i] or bandAlpha[#bandAlpha]
        if pair.a then
            pair.a:SetVertexColor(color[1], color[2], color[3], alpha)
        end
        if pair.b then
            pair.b:SetVertexColor(color[1], color[2], color[3], alpha)
        end
    end
end

local function SetPartyDebuffSweepVisible(overlay, isVisible)
    if not overlay or not overlay.sweep then
        return
    end
    local wasShown = (overlay.sweep.IsShown and overlay.sweep:IsShown()) and "YES" or "NO"
    local wasPlaying = (overlay.sweepMoveGroup and overlay.sweepMoveGroup.IsPlaying and overlay.sweepMoveGroup:IsPlaying()) and "YES" or "NO"

    if isVisible then
        overlay.sweep:Show()
        if overlay.sweepMoveGroup and not overlay.sweepMoveGroup:IsPlaying() then
            overlay.sweepMoveGroup:Play()
        end
    else
        if overlay.sweepMoveGroup and overlay.sweepMoveGroup:IsPlaying() then
            overlay.sweepMoveGroup:Stop()
        end
        overlay.sweep:Hide()
    end

end

local function ApplyPartyDebuffBarTint(frame, primaryEnum, isActive, customColor)
    if not frame then
        return
    end

    if not isActive then
        frame._muiDebuffBarTintActive = false
        frame._muiDebuffBarTintEnum = nil
        frame._muiDebuffBarTintRGB = nil
        frame._muiDebuffBarTintSecret = false
        SetPartyRenderedSecretPolish(frame.healthBar, false)
        SetPartyRenderedSecretPolish(frame.powerBar, false)
        if config.style == "Simple" then
            ClearBarOverlays(frame.healthBar)
            ClearBarOverlays(frame.powerBar)
        end
        return
    end

    local color = customColor
    if not color then
        if primaryEnum == PARTY_HAZARD_ENUM.Unknown then
            color = GetPartyUnknownFallbackColor(frame)
        else
            color = PARTY_HAZARD_COLORS[primaryEnum]
        end
    end

    if IsPartySecretColor(color) then
        local fallback = GetPartyUnknownFallbackColor(frame)
        if primaryEnum and primaryEnum ~= PARTY_HAZARD_ENUM.Unknown and PARTY_HAZARD_COLORS[primaryEnum] then
            fallback = PARTY_HAZARD_COLORS[primaryEnum]
        end
        local fr, fg, fb = fallback[1], fallback[2], fallback[3]
        local baseMul = GetPartyDebuffTintBaseMultiplier()

        frame._muiDebuffBarTintActive = true
        frame._muiDebuffBarTintEnum = primaryEnum
        frame._muiDebuffBarTintRGB = "secret"
        frame._muiDebuffBarTintSecret = true

        if frame.healthBar and frame.healthBar:IsShown() then
            if config.style == "Rendered" then
                ApplyRenderedBarStyle(frame.healthBar, baseMul, baseMul, baseMul, 1.0, 0.20, 0.34)
                SetPartyRenderedSecretPolish(frame.healthBar, true)
            elseif config.style == "Simple" then
                ApplyPartyFlatStatusBarTint(frame.healthBar, baseMul, baseMul, baseMul, 1.0)
                SetPartyRenderedSecretPolish(frame.healthBar, false)
            else
                ApplyStatusBarGradient(frame.healthBar, baseMul, baseMul, baseMul, 1.0, 0.20, 0.34)
            end
            local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            if hTex and hTex.SetVertexColor then
                hTex:SetVertexColor(color[1], color[2], color[3], 1.0)
            end
        end

        if frame.powerBar and frame.powerBar:IsShown() then
            if config.style == "Rendered" then
                ApplyRenderedBarStyle(frame.powerBar, baseMul, baseMul, baseMul, 1.0, 0.20, 0.32)
                SetPartyRenderedSecretPolish(frame.powerBar, true)
            elseif config.style == "Simple" then
                ApplyPartyFlatStatusBarTint(frame.powerBar, baseMul, baseMul, baseMul, 1.0)
                SetPartyRenderedSecretPolish(frame.powerBar, false)
            else
                ApplyStatusBarGradient(frame.powerBar, baseMul, baseMul, baseMul, 1.0, 0.16, 0.30)
            end
            local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
            if pTex and pTex.SetVertexColor then
                pTex:SetVertexColor(color[1], color[2], color[3], 1.0)
            end
        end

        ApplyPartyDebuffBackgroundTint(frame, fr, fg, fb)
        if frame.circle and frame.circle:IsShown() and frame.circle.fill then
            frame.circle.fill:SetStatusBarColor(color[1], color[2], color[3], 0.62)
        end
        return
    end

    if not color then
        return
    end

    local r, g, b = color[1], color[2], color[3]
    local darkMul = GetPartyDebuffTintBaseMultiplier()
    local dr, dg, db = r * darkMul, g * darkMul, b * darkMul
    frame._muiDebuffBarTintActive = true
    frame._muiDebuffBarTintEnum = primaryEnum
    frame._muiDebuffBarTintRGB = string.format("%.3f,%.3f,%.3f", r, g, b)
    frame._muiDebuffBarTintSecret = false

    if frame.healthBar and frame.healthBar:IsShown() then
        if config.style == "Rendered" then
            ApplyRenderedBarStyle(frame.healthBar, dr, dg, db, 1.0, 0.20, 0.34)
            SetPartyRenderedSecretPolish(frame.healthBar, false)
        elseif config.style == "Simple" then
            ApplyPartyFlatStatusBarTint(frame.healthBar, dr, dg, db, 1.0)
            SetPartyRenderedSecretPolish(frame.healthBar, false)
        else
            ApplyStatusBarGradient(frame.healthBar, dr, dg, db, 1.0, 0.20, 0.34)
        end
        local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
        if hTex and hTex.SetVertexColor then
            hTex:SetVertexColor(dr, dg, db, 1.0)
        end
    end

    if frame.powerBar and frame.powerBar:IsShown() then
        if config.style == "Rendered" then
            ApplyRenderedBarStyle(frame.powerBar, dr, dg, db, 1.0, 0.20, 0.32)
            SetPartyRenderedSecretPolish(frame.powerBar, false)
        elseif config.style == "Simple" then
            ApplyPartyFlatStatusBarTint(frame.powerBar, dr, dg, db, 1.0)
            SetPartyRenderedSecretPolish(frame.powerBar, false)
        else
            ApplyStatusBarGradient(frame.powerBar, dr, dg, db, 1.0, 0.16, 0.30)
        end
        local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
        if pTex and pTex.SetVertexColor then
            pTex:SetVertexColor(dr, dg, db, 1.0)
        end
    end

    ApplyPartyDebuffBackgroundTint(frame, r, g, b)

    if frame.circle and frame.circle:IsShown() and frame.circle.fill then
        frame.circle.fill:SetStatusBarColor(r, g, b, 0.62)
    end
end

local function GetPartyDebuffNow()
    if type(GetTime) == "function" then
        local okNow, now = pcall(GetTime)
        if okNow and type(now) == "number" then
            return now
        end
    end
    return 0
end

local function ApplyPartyStickyHazardFallback(frame, primaryEnum, secondaryEnum, primaryColor, collectDiag)
    local normalizedPrimary = NormalizePartyHazardEnum(primaryEnum)
    local normalizedSecondary = NormalizePartyHazardEnum(secondaryEnum)
    if normalizedSecondary == normalizedPrimary then
        normalizedSecondary = nil
    end

    local resolvedPrimaryColor = ClonePartyColor(primaryColor)
    local inRestricted = (collectDiag and collectDiag.inRestricted == "YES")
    local condActive = (collectDiag and collectDiag.condActive == "YES")
    local condUnknown = IsPartyUnknownHazardSource(collectDiag and collectDiag.condSource)
    local holdStickyForUnknown = condActive and condUnknown
    local now = GetPartyDebuffNow()

    if normalizedPrimary and normalizedPrimary ~= PARTY_HAZARD_ENUM.Unknown then
        frame._muiDebuffStickyPrimary = normalizedPrimary
        frame._muiDebuffStickySecondary = (normalizedSecondary and normalizedSecondary ~= PARTY_HAZARD_ENUM.Unknown) and normalizedSecondary or nil
        frame._muiDebuffStickyAt = now
        if not resolvedPrimaryColor then
            resolvedPrimaryColor = ClonePartyColor(PARTY_HAZARD_COLORS[normalizedPrimary])
        end
        frame._muiDebuffStickyPrimaryColor = ClonePartyColor(resolvedPrimaryColor)
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
    end

    local stickyPrimary = NormalizePartyHazardEnum(frame._muiDebuffStickyPrimary)
    local stickySecondary = NormalizePartyHazardEnum(frame._muiDebuffStickySecondary)
    local stickyColor = ClonePartyColor(frame._muiDebuffStickyPrimaryColor)
    local stickyAt = tonumber(frame._muiDebuffStickyAt) or 0
    local stickyFresh = stickyPrimary
        and now > 0
        and stickyAt > 0
        and (now - stickyAt) <= PARTY_HAZARD_STICKY_SEC

    if stickyPrimary and (stickyFresh or holdStickyForUnknown) then
        if not normalizedPrimary or normalizedPrimary == PARTY_HAZARD_ENUM.Unknown then
            normalizedPrimary = stickyPrimary
            resolvedPrimaryColor = stickyColor or resolvedPrimaryColor
        end
        if (not normalizedSecondary or normalizedSecondary == PARTY_HAZARD_ENUM.Unknown or normalizedSecondary == normalizedPrimary)
            and stickySecondary
            and stickySecondary ~= normalizedPrimary then
            normalizedSecondary = stickySecondary
        end
        return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, true
    end

    if (not inRestricted) and (not condActive) and (not normalizedPrimary or normalizedPrimary == PARTY_HAZARD_ENUM.Unknown) then
        frame._muiDebuffStickyPrimary = nil
        frame._muiDebuffStickySecondary = nil
        frame._muiDebuffStickyAt = nil
        frame._muiDebuffStickyPrimaryColor = nil
    end

    return normalizedPrimary, normalizedSecondary, resolvedPrimaryColor, false
end

local function SetPartyDebuffOverlayActive(overlay, isActive)
    if not overlay then
        return
    end
    if isActive then
        if overlay.fadeOut and overlay.fadeOut:IsPlaying() then
            overlay.fadeOut:Stop()
        end
        if not overlay:IsShown() then
            overlay:SetAlpha(0)
            overlay:Show()
        end
        if overlay.fadeIn and not overlay.fadeIn:IsPlaying() and overlay:GetAlpha() < 0.95 then
            overlay.fadeIn:Play()
        else
            overlay:SetAlpha(1)
        end
        if overlay.fillPulse and not overlay.fillPulse:IsPlaying() then
            overlay.fillPulse:Play()
        end
        if overlay.bracketPulse and not overlay.bracketPulse:IsPlaying() then
            overlay.bracketPulse:Play()
        end
    else
        if overlay.fadeIn and overlay.fadeIn:IsPlaying() then
            overlay.fadeIn:Stop()
        end
        SetPartyDebuffSweepVisible(overlay, false)
        if overlay:IsShown() then
            if overlay.fadeOut and not overlay.fadeOut:IsPlaying() then
                overlay.fadeOut:Play()
            end
        else
            overlay:SetAlpha(0)
            overlay:Hide()
        end
    end
end

local function UpdatePartyDebuffOverlay(frame, unit)
    if not frame or not unit then
        return
    end
    local overlay = BuildPartyDebuffOverlay(frame)
    if not overlay then
        return
    end

    LayoutPartyDebuffOverlay(overlay, frame)
    LayoutPartyDebuffSweep(overlay, frame)
    local primaryEnum, secondaryEnum, collectDiag = CollectPartyHazardsForUnit(unit)
    local primaryColorOverride = collectDiag and collectDiag.customPrimaryColor or nil
    local secondaryColorOverride = collectDiag and collectDiag.customSecondaryColor or nil
    local stickyApplied = false
    primaryEnum, secondaryEnum, primaryColorOverride, stickyApplied = ApplyPartyStickyHazardFallback(frame, primaryEnum, secondaryEnum, primaryColorOverride, collectDiag)
    if collectDiag then
        frame._muiDebuffCollectReason = collectDiag.reason
        frame._muiDebuffCollectPrimary = collectDiag.primary
        frame._muiDebuffCollectTracker = collectDiag.trackerTypes
        frame._muiDebuffCollectCond = collectDiag.condSource
        frame._muiDebuffCollectCondActive = collectDiag.condActive
        frame._muiDebuffCollectCondSecondary = collectDiag.condSecondary
        frame._muiDebuffCollectCondSecondaryRGB = collectDiag.condSecondaryRGB
        frame._muiDebuffCollectCondRGB = collectDiag.condRGB
        frame._muiDebuffCollectOverride = collectDiag.condOverride
        frame._muiDebuffCollectCondSecret = collectDiag.condSecret
        frame._muiDebuffCollectBlizzHits = collectDiag.blizzHits
        frame._muiDebuffCollectBlizzDebuffs = collectDiag.blizzDebuffs
        frame._muiDebuffCollectBlizzDispellable = collectDiag.blizzDispellable
        frame._muiDebuffCollectBlizzAvail = collectDiag.blizzAvail
        frame._muiDebuffCollectSticky = stickyApplied and "YES" or "NO"
    end
    local hasPrimary = primaryEnum ~= nil
    local hasSecondary = (secondaryEnum ~= nil and secondaryEnum ~= primaryEnum)
        or (type(secondaryColorOverride) == "table")
    local primaryRenderColor = primaryColorOverride
    if hasPrimary and IsPartySecretColor(primaryColorOverride) then
        local overlayShown = (overlay.IsShown and overlay:IsShown()) and true or false
        if not overlayShown then
            if primaryEnum and primaryEnum ~= PARTY_HAZARD_ENUM.Unknown and PARTY_HAZARD_COLORS[primaryEnum] then
                local canonical = PARTY_HAZARD_COLORS[primaryEnum]
                primaryRenderColor = { canonical[1], canonical[2], canonical[3] }
            else
                primaryRenderColor = GetPartyUnknownFallbackColor(frame)
            end
        end
    end

    if hasPrimary then
        SetPartyDebuffPrimaryColor(overlay, frame, primaryEnum, primaryRenderColor)
        SetPartyDebuffOverlayActive(overlay, true)
        ApplyPartyDebuffBarTint(frame, primaryEnum, true, primaryRenderColor)
    else
        SetPartyDebuffOverlayActive(overlay, false)
        ApplyPartyDebuffBarTint(frame, nil, false)
    end

    if hasPrimary and hasSecondary then
        SetPartyDebuffSecondaryColor(overlay, secondaryEnum, secondaryColorOverride)
        SetPartyDebuffSweepVisible(overlay, true)
    else
        SetPartyDebuffSweepVisible(overlay, false)
    end

    UpdatePartyDispelTrackingOverlay(
        frame,
        unit,
        primaryEnum,
        primaryRenderColor,
        collectDiag and collectDiag.inRestricted == "YES",
        false
    )

    local secondaryLabel = PARTY_HAZARD_LABELS[secondaryEnum]
        or ((type(secondaryColorOverride) == "table") and "SECRET")
        or "NONE"
    local signature = (PARTY_HAZARD_LABELS[primaryEnum] or "NONE")
        .. ">" .. secondaryLabel
    if frame._muiDebuffOverlaySig ~= signature then
        frame._muiDebuffOverlaySig = signature
    end
end

local function DarkenColor(r, g, b, factor)
    local f = factor or 0.4
    return (r or 0) * f, (g or 0) * f, (b or 0) * f
end

local function SafeSetBlendMode(tex, mode, label)
    if not tex or not tex.SetBlendMode then return end
    local targetMode = mode or "DISABLE"
    local ok = pcall(tex.SetBlendMode, tex, targetMode)
    if not ok then
        pcall(tex.SetBlendMode, tex, "DISABLE")
    end
end

local function EnsureRenderedOverlays(bar, tex)
    if not bar or not tex then return end
    if not bar._muiRenderedTop then
        bar._muiRenderedTop = bar:CreateTexture(nil, "OVERLAY", nil, 2)
        bar._muiRenderedTop:SetTexture("Interface\\Buttons\\WHITE8X8")
        bar._muiRenderedTop:SetAllPoints(tex)
        SafeSetBlendMode(bar._muiRenderedTop, "DISABLE", "top")
    end
    if not bar._muiRenderedBottom then
        bar._muiRenderedBottom = bar:CreateTexture(nil, "OVERLAY", nil, 1)
        bar._muiRenderedBottom:SetTexture("Interface\\Buttons\\WHITE8X8")
        bar._muiRenderedBottom:SetAllPoints(tex)
        SafeSetBlendMode(bar._muiRenderedBottom, "DISABLE", "bottom")
    end
    if not bar._muiRenderedGloss then
        bar._muiRenderedGloss = bar:CreateTexture(nil, "OVERLAY", nil, 0)
        bar._muiRenderedGloss:SetTexture("Interface\\Buttons\\WHITE8X8")
        bar._muiRenderedGloss:SetAllPoints(tex)
        SafeSetBlendMode(bar._muiRenderedGloss, "DISABLE", "gloss")
    end
end

ApplyRenderedBarStyle = function(bar, r, g, b, a, topAlpha, bottomAlpha)
    if not bar then return end
    bar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    local tex = bar:GetStatusBarTexture()
    if not tex then return end
    tex:SetHorizTile(false)
    tex:SetVertTile(false)
    bar:SetStatusBarColor(r, g, b, a or 1)
    EnsureRenderedOverlays(bar, tex)
    SafeSetBlendMode(bar._muiRenderedTop, "DISABLE", "top-reset")
    SafeSetBlendMode(bar._muiRenderedBottom, "DISABLE", "bottom-reset")
    SafeSetBlendMode(bar._muiRenderedGloss, "DISABLE", "gloss-reset")
    local function Scale(v, f)
        local n = (v or 0) * f
        if n < 0 then return 0 end
        if n > 1 then return 1 end
        return n
    end
    local edgeR, edgeG, edgeB = Scale(r, 0.54), Scale(g, 0.54), Scale(b, 0.54)
    local midR, midG, midB = Scale(r, 1.15), Scale(g, 1.15), Scale(b, 1.15)
    local rawH = (bar.GetHeight and bar:GetHeight()) or 2
    local h = tonumber(tostring(rawH)) or 2
    local topH = math.max(1, h * 0.43)
    local botH = math.max(1, h * 0.57)

    bar._muiRenderedTop:ClearAllPoints()
    bar._muiRenderedTop:SetPoint("TOPLEFT", tex, "TOPLEFT", 0, 0)
    bar._muiRenderedTop:SetPoint("TOPRIGHT", tex, "TOPRIGHT", 0, 0)
    bar._muiRenderedTop:SetHeight(topH)
    bar._muiRenderedTop:SetGradient("VERTICAL",
        CreateColor(edgeR, edgeG, edgeB, 1),
        CreateColor(midR, midG, midB, 1))

    bar._muiRenderedBottom:ClearAllPoints()
    bar._muiRenderedBottom:SetPoint("BOTTOMLEFT", tex, "BOTTOMLEFT", 0, 0)
    bar._muiRenderedBottom:SetPoint("BOTTOMRIGHT", tex, "BOTTOMRIGHT", 0, 0)
    bar._muiRenderedBottom:SetHeight(botH)
    bar._muiRenderedBottom:SetGradient("VERTICAL",
        CreateColor(midR, midG, midB, 1),
        CreateColor(edgeR, edgeG, edgeB, 1))
    bar._muiRenderedTop:Show()
    bar._muiRenderedBottom:Show()
    if bar._muiRenderedGloss then bar._muiRenderedGloss:Hide() end
    if bar._muiGradient then bar._muiGradient:Hide() end
    if bar._muiFlatGradient then bar._muiFlatGradient:Hide() end
    if bar._muiTopHighlight then bar._muiTopHighlight:Hide() end
    if bar._muiBottomShade then bar._muiBottomShade:Hide() end
    if bar._muiSpecular then bar._muiSpecular:Hide() end
    if PartyDebugEnabled() and _G.MidnightUI_Debug and not bar._muiRenderedLogged then
        bar._muiRenderedLogged = true
    end
end

local function DebugRenderedBar(bar, label)
    if not PartyDebugEnabled() or not _G.MidnightUI_Debug then return end
    if not bar then
        return
    end
    local tex = bar:GetStatusBarTexture()
    local tr, tg, tb, ta = 0, 0, 0, 0
    if tex and tex.GetVertexColor then tr, tg, tb, ta = tex:GetVertexColor() end
end

local function CreateAuraButton(parent)
    local btn = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    btn:SetSize(config.auraSize, config.auraSize)
    
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetAllPoints()
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    
    btn.cooldown = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.cooldown:SetAllPoints()
    btn.cooldown:SetHideCountdownNumbers(false)
    
    btn.border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    btn.border:SetAllPoints()
    btn.border:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    btn.border:SetBackdropBorderColor(0, 0, 0, 1)
    
    return btn
end

local function NormalizePartyAuraStackCount(value)
    if value == nil or IsPartySecretValue(value) then
        return ""
    end
    local n = tonumber(value)
    if not n or IsPartySecretValue(n) then
        return ""
    end
    n = math.floor(n + 0.5)
    if n <= 1 then
        return ""
    end
    return tostring(n)
end

local function SetPartyDispelTrackingIconBorderColor(btn, r, g, b, a)
    if not btn or not btn.SetBackdropBorderColor then
        return
    end
    local alpha = a or 1
    local ok = pcall(btn.SetBackdropBorderColor, btn, r, g, b, alpha)
    if ok then
        return
    end
    btn:SetBackdropBorderColor(0.70, 0.70, 0.70, alpha)
end

local function CollectPartyDispelTrackingAuraEntry(unit, inRestricted)
    if not unit then
        return nil
    end

    local blizzEntry = _partyBlizzAuraCache[unit]
    local function CanApplyIconToken(iconToken)
        if iconToken == nil then
            return false
        end
        if IsPartySecretValue(iconToken) then
            -- Restricted token: treat as opaque and pass through to SetTexture().
            return true
        end
        local tokenType = type(iconToken)
        if tokenType == "number" then
            if iconToken == PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON then
                return false
            end
            return iconToken > 0
        end
        if tokenType == "string" then
            if iconToken == "" then
                return false
            end
            local okLower, lower = pcall(string.lower, iconToken)
            if okLower and type(lower) == "string" then
                if lower:find("questionmark", 1, true) or lower:find("inv_misc_questionmark", 1, true) then
                    return false
                end
            end
            return true
        end
        return false
    end
    local function HazardRank(enum)
        local normalized = NormalizePartyHazardEnum(enum)
        if not normalized or normalized == PARTY_HAZARD_ENUM.Unknown then
            return 999
        end
        for i, candidate in ipairs(PARTY_HAZARD_PRIORITY) do
            if normalized == candidate then
                return i
            end
        end
        return 999
    end

    local bestEntry = nil
    local bestScore = math.huge
    local function ResolveIconFromSpellID(spellID)
        local okSpellID, numericSpellID = pcall(tonumber, spellID)
        if (not okSpellID) or (not numericSpellID) then
            return nil, nil
        end
        if IsPartySecretValue(numericSpellID) then
            return nil, nil
        end
        if numericSpellID <= 0 then
            return nil, nil
        end
        local icon = nil
        if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
            local okTex, tex = pcall(C_Spell.GetSpellTexture, numericSpellID)
            if okTex and tex and (not IsPartySecretValue(tex)) then
                icon = tex
            end
        end
        if (not icon) and type(GetSpellTexture) == "function" then
            local okLegacyTex, legacyTex = pcall(GetSpellTexture, numericSpellID)
            if okLegacyTex and legacyTex and (not IsPartySecretValue(legacyTex)) then
                icon = legacyTex
            end
        end
        return icon, numericSpellID
    end
    local function ConsiderEntry(icon, stackCount, auraInstanceID, auraIndex, enum, sourceScore, sourceLabel, spellID)
        local normalized = NormalizePartyHazardEnum(enum)
        local rank = HazardRank(normalized)
        if rank >= 999 then
            return
        end
        local okSpellID, resolvedSpellID = pcall(tonumber, spellID)
        if not okSpellID then
            resolvedSpellID = nil
        end
        if resolvedSpellID and IsPartySecretValue(resolvedSpellID) then
            resolvedSpellID = nil
        end
        if resolvedSpellID and resolvedSpellID <= 0 then
            resolvedSpellID = nil
        end
        if not CanApplyIconToken(icon) then
            icon = nil
        end
        if (not icon) and blizzEntry and type(blizzEntry.icons) == "table" and auraInstanceID then
            local cachedIcon = blizzEntry.icons[auraInstanceID]
            if CanApplyIconToken(cachedIcon) then
                icon = cachedIcon
            end
        end
        if (not resolvedSpellID) and blizzEntry and type(blizzEntry.spellIDs) == "table" and auraInstanceID then
            local okBlizzSpellID, blizzSpellID = pcall(tonumber, blizzEntry.spellIDs[auraInstanceID])
            if okBlizzSpellID and blizzSpellID and (not IsPartySecretValue(blizzSpellID)) and blizzSpellID > 0 then
                resolvedSpellID = blizzSpellID
            end
        end
        if (not CanApplyIconToken(icon)) and resolvedSpellID then
            local spellIcon, normalizedSpellID = ResolveIconFromSpellID(resolvedSpellID)
            if CanApplyIconToken(spellIcon) then
                icon = spellIcon
                resolvedSpellID = normalizedSpellID
            end
        end
        local usingPlaceholder = false
        if not CanApplyIconToken(icon) then
            icon = PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON
            usingPlaceholder = true
        end
        local score = (rank * 100) + ((usingPlaceholder and 1 or 0) * 10) + (tonumber(sourceScore) or 0)
        if score >= bestScore then
            return
        end
        bestScore = score
        bestEntry = {
            icon = icon,
            stackCount = stackCount,
            auraInstanceID = auraInstanceID,
            auraIndex = auraIndex,
            enum = normalized,
            source = sourceLabel or "UNKNOWN",
            sourceScore = tonumber(sourceScore) or 0,
            spellID = resolvedSpellID,
        }
    end

    local function ConsiderBlizzAuraSetByIID(auraSet, sourceScore)
        if type(auraSet) ~= "table" then
            return
        end
        for iid in pairs(auraSet) do
            local hint = blizzEntry and blizzEntry.types and blizzEntry.types[iid] or nil
            local enum = NormalizePartyHazardEnum(hint)
            if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) then
                enum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, iid, hint))
            end
            if enum and enum ~= PARTY_HAZARD_ENUM.Unknown then
                local icon = blizzEntry and blizzEntry.icons and blizzEntry.icons[iid] or nil
                local stacks = blizzEntry and blizzEntry.stacks and blizzEntry.stacks[iid] or nil
                local spellID = blizzEntry and blizzEntry.spellIDs and blizzEntry.spellIDs[iid] or nil
                ConsiderEntry(icon, stacks, iid, nil, enum, sourceScore,
                    sourceScore == 0 and "BLIZZ_IID_DISPELLABLE" or "BLIZZ_IID_DEBUFF",
                    spellID)
            end
        end
    end

    if inRestricted and type(blizzEntry) == "table" then
        ConsiderBlizzAuraSetByIID(blizzEntry.dispellable, 0)
        ConsiderBlizzAuraSetByIID(blizzEntry.debuffs, 1)
        if not bestEntry then
            local function BuildIconOnlyEntry(auraSet, sourceLabel, sourceScore)
                if type(auraSet) ~= "table" then
                    return false
                end
                for iid in pairs(auraSet) do
                    local icon = blizzEntry and blizzEntry.icons and blizzEntry.icons[iid] or nil
                    local stacks = blizzEntry and blizzEntry.stacks and blizzEntry.stacks[iid] or nil
                    local spellID = blizzEntry and blizzEntry.spellIDs and blizzEntry.spellIDs[iid] or nil
                    local hint = blizzEntry and blizzEntry.types and blizzEntry.types[iid] or nil
                    local enum = NormalizePartyHazardEnum(hint)
                    if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) then
                        enum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, iid, hint))
                    end
                    local iconToken = CanApplyIconToken(icon) and icon or PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON
                    bestEntry = {
                        icon = iconToken,
                        stackCount = stacks,
                        auraInstanceID = iid,
                        auraIndex = nil,
                        enum = enum,
                        source = sourceLabel,
                        sourceScore = sourceScore or 9,
                        spellID = spellID,
                    }
                    return true
                end
                return false
            end
        if not BuildIconOnlyEntry(blizzEntry.dispellable, "BLIZZ_ICON_ONLY_DISPELLABLE", 8) then
            BuildIconOnlyEntry(blizzEntry.debuffs, "BLIZZ_ICON_ONLY_DEBUFF", 9)
        end
    end
    if bestEntry and CanApplyIconToken(bestEntry.icon) then
        return bestEntry
    end
    end

    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local fallbackIIDs = nil
        if type(blizzEntry) == "table" then
            fallbackIIDs = {}
            if type(blizzEntry.dispellable) == "table" then
                for iid in pairs(blizzEntry.dispellable) do
                    fallbackIIDs[iid] = true
                end
            end
            if next(fallbackIIDs) == nil and type(blizzEntry.debuffs) == "table" then
                for iid in pairs(blizzEntry.debuffs) do
                    fallbackIIDs[iid] = true
                end
            end
            if next(fallbackIIDs) == nil then
                fallbackIIDs = nil
            end
        end

        for i = 1, 40 do
            local aura
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
            local enum = ResolvePartyHazardFromAura(unit, aura)
            local auraIID = aura.auraInstanceID
            local hint = blizzEntry and blizzEntry.types and auraIID and blizzEntry.types[auraIID] or nil
            if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) and auraIID then
                enum = NormalizePartyHazardEnum(hint)
            end
            if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) and auraIID then
                enum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, auraIID, hint))
            end

            if enum and enum ~= PARTY_HAZARD_ENUM.Unknown then
                local sourceScore = 2
                if blizzEntry and blizzEntry.dispellable and auraIID and blizzEntry.dispellable[auraIID] then
                    sourceScore = 0
                end
                ConsiderEntry(
                    aura.icon or aura.iconFileID,
                    aura.applications or aura.stackCount or aura.charges,
                    auraIID,
                    i,
                    enum,
                    sourceScore,
                    "AURA_SCAN_TYPED",
                    aura.spellId or aura.spellID
                )
            elseif fallbackIIDs and auraIID and fallbackIIDs[auraIID] then
                local fallbackEnum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, auraIID, hint))
                if fallbackEnum and fallbackEnum ~= PARTY_HAZARD_ENUM.Unknown then
                    ConsiderEntry(
                        aura.icon or aura.iconFileID,
                        aura.applications or aura.stackCount or aura.charges,
                        auraIID,
                        i,
                        fallbackEnum,
                        1,
                        "AURA_SCAN_FALLBACK_IID",
                        aura.spellId or aura.spellID
                    )
                end
            end

            if fallbackIIDs and auraIID then
                fallbackIIDs[auraIID] = nil
            end
        end

        if fallbackIIDs and C_UnitAuras.GetAuraDataByAuraInstanceID then
            for fallbackIID in pairs(fallbackIIDs) do
                local fallbackAura = nil
                if inRestricted then
                    local okAura, auraData = pcall(C_UnitAuras.GetAuraDataByAuraInstanceID, unit, fallbackIID)
                    if okAura then
                        fallbackAura = auraData
                    end
                else
                    fallbackAura = C_UnitAuras.GetAuraDataByAuraInstanceID(unit, fallbackIID)
                end

                local hint = blizzEntry and blizzEntry.types and blizzEntry.types[fallbackIID] or nil
                local enum = NormalizePartyHazardEnum(hint)
                if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) then
                    enum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, fallbackIID, hint))
                end
                if enum and enum ~= PARTY_HAZARD_ENUM.Unknown then
                    local icon = nil
                    local stacks = nil
                    local spellID = nil
                    if fallbackAura then
                        icon = fallbackAura.icon or fallbackAura.iconFileID
                        stacks = fallbackAura.applications or fallbackAura.stackCount or fallbackAura.charges
                        spellID = fallbackAura.spellId or fallbackAura.spellID
                    end
                    if (not icon) and blizzEntry and blizzEntry.icons then
                        icon = blizzEntry.icons[fallbackIID]
                    end
                    if (not stacks) and blizzEntry and blizzEntry.stacks then
                        stacks = blizzEntry.stacks[fallbackIID]
                    end
                    if (not spellID) and blizzEntry and blizzEntry.spellIDs then
                        spellID = blizzEntry.spellIDs[fallbackIID]
                    end
                    ConsiderEntry(icon, stacks, fallbackIID, nil, enum, 1, "AURA_IID_FALLBACK", spellID)
                end
            end
        end

        if bestEntry then
            return bestEntry
        end
        return nil
    end

    if type(UnitDebuff) ~= "function" then
        if bestEntry then
            return bestEntry
        end
        return nil
    end
    for i = 1, 40 do
        local name, icon, count, debuffType = UnitDebuff(unit, i)
        if not name then
            break
        end
        local enum = NormalizePartyHazardEnum(debuffType)
        if enum and enum ~= PARTY_HAZARD_ENUM.Unknown then
            ConsiderEntry(icon, count, nil, i, enum, 3, "LEGACY_UNITDEBUFF", nil)
        end
    end
    return bestEntry
end

local function EnsurePartyDispelTrackingOverlay(frame)
    if not frame then
        return nil
    end
    if frame._muiPartyDispelTrackingOverlay then
        return frame._muiPartyDispelTrackingOverlay
    end

    local overlay = CreateFrame("Frame", nil, frame)
    overlay:SetSize(PARTY_DISPEL_TRACKING.BASE_ICON_SIZE + 2, PARTY_DISPEL_TRACKING.BASE_ICON_SIZE + 2)
    overlay:SetPoint("LEFT", frame, "RIGHT", PARTY_DISPEL_TRACKING.OFFSET_X, PARTY_DISPEL_TRACKING.OFFSET_Y)
    overlay:SetFrameStrata("MEDIUM")
    overlay:SetFrameLevel(frame:GetFrameLevel() + 45)
    overlay:EnableMouse(false)
    overlay:Hide()

    local function CreateIconButton()
        local btn = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        btn:SetSize(PARTY_DISPEL_TRACKING.BASE_ICON_SIZE, PARTY_DISPEL_TRACKING.BASE_ICON_SIZE)
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
            local unitToken = self._muiUnit
            if type(unitToken) ~= "string" or (UnitExists and not UnitExists(unitToken)) then
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

    local btn = CreateIconButton()
    btn:SetPoint("CENTER")
    overlay.iconButton = btn
    overlay.iconButtons = { btn }
    overlay._muiCreateIconButton = CreateIconButton
    frame._muiPartyDispelTrackingOverlay = overlay
    return overlay
end

local function GetPartyDispelTrackingAnchorOwner()
    if PartyAnchor and PartyAnchor.dragOverlay and PartyAnchor.dragOverlay.IsShown and PartyAnchor.dragOverlay:IsShown() then
        local slot1 = PartyPreviewBoxes[1]
        if slot1 and slot1.IsShown and slot1:IsShown() then
            return slot1
        end
    end
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame and frame.IsShown and frame:IsShown() then
            return frame
        end
    end
    if PartyAnchor and PartyAnchor.IsShown and PartyAnchor:IsShown() then
        return PartyAnchor
    end
    if PartyFrames[1] then
        return PartyFrames[1]
    end
    return PartyAnchor
end

local function GetPartyDispelTrackingDefaultOffset(ownerFrame, iconSize)
    local ownerW = tonumber(ownerFrame and ownerFrame.GetWidth and ownerFrame:GetWidth()) or tonumber(config.width) or 240
    local ownerH = tonumber(ownerFrame and ownerFrame.GetHeight and ownerFrame:GetHeight()) or tonumber(config.height) or 58

    local horizontalLayout = (config.layout == "Horizontal")
    if horizontalLayout then
        local y = math.floor((ownerH / 2) + (iconSize / 2) + 4 + 0.5)
        return 0, y
    end

    local x = math.floor((ownerW / 2) + (iconSize / 2) + PARTY_DISPEL_TRACKING.OFFSET_X + 0.5)
    return x, PARTY_DISPEL_TRACKING.OFFSET_Y
end

local function ClampPartyDispelTrackingOffset(ownerFrame, iconSize, x, y)
    local ownerW = tonumber(ownerFrame and ownerFrame.GetWidth and ownerFrame:GetWidth()) or tonumber(config.width) or 240
    local ownerH = tonumber(ownerFrame and ownerFrame.GetHeight and ownerFrame:GetHeight()) or tonumber(config.height) or 58
    local halfW = math.max(1, ownerW * 0.5)
    local halfH = math.max(1, ownerH * 0.5)
    local minX, maxX, minY, maxY
    if config.layout == "Horizontal" then
        local pitchX = ownerW + (tonumber(config.spacingX) or 0)
        local primaryLimitX = math.max(18, math.floor((pitchX * 0.75) + 0.5))
        minX = -primaryLimitX
        maxX = primaryLimitX
        minY = -math.floor((halfH + iconSize + 6) + 0.5)
        maxY = math.floor((halfH + iconSize + 12) + 0.5)
    else
        local pitchY = ownerH + (tonumber(config.spacingY) or 0)
        local primaryLimitY = math.max(14, math.floor((pitchY * 0.75) + 0.5))
        minX = -math.floor((halfW + iconSize + PARTY_DISPEL_TRACKING.OFFSET_X + 24) + 0.5)
        maxX = math.floor((halfW + iconSize + PARTY_DISPEL_TRACKING.OFFSET_X + 24) + 0.5)
        minY = -primaryLimitY
        maxY = primaryLimitY
    end

    if x < minX then
        x = minX
    elseif x > maxX then
        x = maxX
    end
    if y < minY then
        y = minY
    elseif y > maxY then
        y = maxY
    end
    return x, y
end

local function GetPartyDispelTrackingRelativeOffset(ownerFrame, iconSize)
    local combat = EnsurePartyCombatSettingsTable()
    local pos = combat.partyDispelTrackingPosition
    local x, y
    if type(pos) == "table" and #pos >= 2 then
        x = tonumber(pos[1])
        y = tonumber(pos[2])
    end
    if not x or not y then
        x, y = GetPartyDispelTrackingDefaultOffset(ownerFrame, iconSize)
    end

    x, y = ClampPartyDispelTrackingOffset(ownerFrame, iconSize, x, y)

    if type(pos) == "table" and (tonumber(pos[1]) ~= x or tonumber(pos[2]) ~= y) then
        combat.partyDispelTrackingPosition = { x, y }
    end
    return x, y
end

local function SavePartyDispelTrackingRelativePosition(overlay, ownerFrame)
    if not overlay or not ownerFrame or not overlay.GetCenter or not ownerFrame.GetCenter then
        return
    end
    local fx, fy = overlay:GetCenter()
    local ox, oy = ownerFrame:GetCenter()
    if not fx or not fy or not ox or not oy then
        return
    end
    local combat = EnsurePartyCombatSettingsTable()
    combat.partyDispelTrackingPosition = { fx - ox, fy - oy }
    local iconSize = GetPartyDispelTrackingIconSize(combat.partyDispelTrackingIconScale)
    local clampedX, clampedY = GetPartyDispelTrackingRelativeOffset(ownerFrame, iconSize)
    combat.partyDispelTrackingPosition = { clampedX, clampedY }
end

local function EnsurePartyDispelTrackingDragOverlay()
    if PartyDispelTrackingState.dragOverlay then
        return PartyDispelTrackingState.dragOverlay
    end

    local overlay = CreateFrame("Frame", "MidnightUI_PartyDispelTrackingDragOverlay", UIParent, "BackdropTemplate")
    overlay:SetSize(PARTY_DISPEL_TRACKING.DRAG_SIZE, PARTY_DISPEL_TRACKING.DRAG_SIZE)
    overlay:SetFrameStrata("DIALOG")
    overlay:SetFrameLevel(70)
    overlay:SetMovable(true)
    overlay:SetClampedToScreen(true)
    if _G.MidnightUI_StyleOverlay then
        _G.MidnightUI_StyleOverlay(overlay, "PARTY DISPEL ICONS", nil, "auras")
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
        label:SetPoint("BOTTOM", overlay, "TOP", 0, 2)
        label:SetText("PARTY DISPEL ICONS")
        label:SetTextColor(1, 1, 1)
    end

    local preview = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
    preview:SetPoint("CENTER")
    preview:SetSize(PARTY_DISPEL_TRACKING.BASE_ICON_SIZE, PARTY_DISPEL_TRACKING.BASE_ICON_SIZE)
    preview:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    preview:SetBackdropColor(0, 0, 0, 0.75)
    preview:SetBackdropBorderColor(PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][1], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][2], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][3], 1)

    local icon = preview:CreateTexture(nil, "ARTWORK")
    icon:SetPoint("TOPLEFT", 1, -1)
    icon:SetPoint("BOTTOMRIGHT", -1, 1)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    icon:SetTexture(PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON)
    overlay.preview = preview
    overlay.previewIcon = icon
    overlay.previewIcons = {}

    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function(self)
        if InCombatLockdown and InCombatLockdown() then
            return
        end
        local owner = GetPartyDispelTrackingAnchorOwner()
        if not owner or not owner.GetCenter then
            return
        end
        local combat = EnsurePartyCombatSettingsTable()
        self._muiDragOwner = owner
        self._muiDragIconSize = GetPartyDispelTrackingIconSize(combat.partyDispelTrackingIconScale)
        self._muiDragging = true
        self:SetScript("OnUpdate", function(frame)
            if not frame._muiDragging then
                return
            end
            local dragOwner = frame._muiDragOwner
            if not dragOwner or not dragOwner.GetCenter then
                return
            end
            local ox, oy = dragOwner:GetCenter()
            if not ox or not oy then
                return
            end
            local cx, cy = GetCursorPosition()
            local scale = (UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale()) or 1
            if not scale or scale == 0 then
                scale = 1
            end
            cx = cx / scale
            cy = cy / scale
            local nx = cx - ox
            local ny = cy - oy
            nx, ny = ClampPartyDispelTrackingOffset(dragOwner, frame._muiDragIconSize or PARTY_DISPEL_TRACKING.BASE_ICON_SIZE, nx, ny)
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", dragOwner, "CENTER", nx, ny)
        end)
    end)
    overlay:SetScript("OnDragStop", function(self)
        self._muiDragging = false
        self:SetScript("OnUpdate", nil)
        local owner = self._muiDragOwner or GetPartyDispelTrackingAnchorOwner()
        self._muiDragOwner = nil
        self._muiDragIconSize = nil
        if owner then
            SavePartyDispelTrackingRelativePosition(self, owner)
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "PartyDispelTracking")
    end
    overlay:Hide()
    PartyDispelTrackingState.dragOverlay = overlay
    return overlay
end

local function UpdatePartyDispelTrackingDragOverlay()
    local overlay = EnsurePartyDispelTrackingDragOverlay()
    if not overlay then
        return
    end

    local combat = EnsurePartyCombatSettingsTable()
    local enabled = IsPartyDebuffOverlayEnabled() and (combat.partyDispelTrackingEnabled ~= false)
    local movementUnlocked = IsPartyDispelMovementModeUnlocked()
    if (not enabled) or (not movementUnlocked) or PartyDispelTrackingState.locked then
        overlay._muiDragging = false
        overlay._muiDragOwner = nil
        overlay._muiDragIconSize = nil
        overlay:SetScript("OnUpdate", nil)
        overlay:Hide()
        return
    end

    local iconSize = GetPartyDispelTrackingIconSize(combat.partyDispelTrackingIconScale)
    local owner = GetPartyDispelTrackingAnchorOwner()
    if not owner then
        overlay:Hide()
        return
    end

    local offsetX, offsetY = GetPartyDispelTrackingRelativeOffset(owner, iconSize)
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", owner, "CENTER", offsetX, offsetY)
    overlay:SetAlpha(ClampPartyDispelTrackingAlpha(combat.partyDispelTrackingAlpha))
    local usingPreviewSlots = false
    if PartyAnchor and PartyAnchor.dragOverlay and PartyAnchor.dragOverlay.IsShown and PartyAnchor.dragOverlay:IsShown() then
        for i = 1, 4 do
            local slot = PartyPreviewBoxes[i]
            if slot and slot.IsShown and slot:IsShown() then
                usingPreviewSlots = true
                break
            end
        end
    end

    -- Update the main preview to show a grid of maxShown placeholders
    local maxShown = math.max(1, math.floor((tonumber(combat.partyDispelTrackingMaxShown) or 4) + 0.5))
    if maxShown > PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT then maxShown = PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT end
    local perRow = math.max(1, combat.partyDispelTrackingPerRow or PARTY_DISPEL_TRACKING.DEFAULT_PER_ROW)
    local hSpacing = iconSize + 2
    local vSpacing = iconSize + 2
    local cols = math.min(perRow, maxShown)
    local rows = math.ceil(maxShown / perRow)
    local gridW = math.max(iconSize + 2, cols * hSpacing)
    local gridH = math.max(iconSize + 2, rows * vSpacing)
    overlay:SetSize(gridW, gridH)

    -- Hide the old single preview (replaced by grid)
    if overlay.preview then overlay.preview:Hide() end

    -- Ensure we have enough preview placeholder icons
    if not overlay._muiGridIcons then overlay._muiGridIcons = {} end
    local gridIcons = overlay._muiGridIcons
    for i = 1, maxShown do
        if not gridIcons[i] then
            local holder = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
            holder:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
            })
            holder:SetBackdropColor(0, 0, 0, 0.75)
            holder:SetBackdropBorderColor(PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][1], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][2], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][3], 1)
            local ico = holder:CreateTexture(nil, "ARTWORK")
            ico:SetPoint("TOPLEFT", 1, -1)
            ico:SetPoint("BOTTOMRIGHT", -1, 1)
            ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            ico:SetTexture(PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON)
            holder.icon = ico
            gridIcons[i] = holder
        end
        local holder = gridIcons[i]
        holder:SetSize(iconSize, iconSize)
        holder:ClearAllPoints()
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        holder:SetPoint("TOPLEFT", overlay, "TOPLEFT", col * hSpacing, -(row * vSpacing))
        if usingPreviewSlots then
            holder:Hide()
        else
            holder:Show()
        end
    end
    for i = maxShown + 1, #gridIcons do
        if gridIcons[i] then gridIcons[i]:Hide() end
    end

    local previewIcons = overlay.previewIcons
    if type(previewIcons) ~= "table" then
        previewIcons = {}
        overlay.previewIcons = previewIcons
    end

    -- Show ghost grids on each other party frame
    local ownerCenterX, ownerCenterY = owner:GetCenter()
    if (not ownerCenterX or not ownerCenterY) and PartyAnchor and PartyAnchor.GetCenter then
        ownerCenterX, ownerCenterY = PartyAnchor:GetCenter()
    end
    if not overlay._muiGhostGrids then overlay._muiGhostGrids = {} end
    local ghostGrids = overlay._muiGhostGrids
    for i = 1, 4 do
        -- Ensure a container frame for each party slot's ghost grid
        if not ghostGrids[i] then
            ghostGrids[i] = { container = nil, icons = {} }
        end
        local gg = ghostGrids[i]
        if not gg.container then
            gg.container = CreateFrame("Frame", nil, overlay)
            gg.container:SetSize(gridW, gridH)
        end

        local target = nil
        if usingPreviewSlots then
            local slot = PartyPreviewBoxes[i]
            if slot and slot.IsShown and slot:IsShown() and slot.GetCenter then
                target = slot
            end
        else
            local frame = PartyFrames[i]
            if frame and frame ~= owner and frame.IsShown and frame:IsShown() and frame.GetCenter then
                target = frame
            end
        end

        if target and ownerCenterX and ownerCenterY then
            local fx, fy = target:GetCenter()
            if fx and fy then
                gg.container:SetSize(gridW, gridH)
                gg.container:ClearAllPoints()
                gg.container:SetPoint("CENTER", overlay, "CENTER", fx - ownerCenterX, fy - ownerCenterY)
                -- Ensure icons in this ghost grid
                for j = 1, maxShown do
                    if not gg.icons[j] then
                        local holder = CreateFrame("Frame", nil, gg.container, "BackdropTemplate")
                        holder:SetBackdrop({
                            bgFile = "Interface\\Buttons\\WHITE8X8",
                            edgeFile = "Interface\\Buttons\\WHITE8X8",
                            edgeSize = 1,
                            insets = { left = 0, right = 0, top = 0, bottom = 0 },
                        })
                        holder:SetBackdropColor(0, 0, 0, 0.75)
                        holder:SetBackdropBorderColor(PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][1], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][2], PARTY_HAZARD_COLORS[PARTY_HAZARD_ENUM.Magic][3], 1)
                        local ico = holder:CreateTexture(nil, "ARTWORK")
                        ico:SetPoint("TOPLEFT", 1, -1)
                        ico:SetPoint("BOTTOMRIGHT", -1, 1)
                        ico:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                        ico:SetTexture(PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON)
                        holder.icon = ico
                        gg.icons[j] = holder
                    end
                    local holder = gg.icons[j]
                    holder:SetSize(iconSize, iconSize)
                    holder:ClearAllPoints()
                    local row = math.floor((j - 1) / perRow)
                    local col = (j - 1) % perRow
                    holder:SetPoint("TOPLEFT", gg.container, "TOPLEFT", col * hSpacing, -(row * vSpacing))
                    holder:Show()
                end
                for j = maxShown + 1, #gg.icons do
                    if gg.icons[j] then gg.icons[j]:Hide() end
                end
                gg.container:Show()
            else
                gg.container:Hide()
            end
        else
            if gg.container then gg.container:Hide() end
        end
    end
    -- Hide old single ghost icons if they exist
    for i = 1, #previewIcons do
        if previewIcons[i] then previewIcons[i]:Hide() end
    end
    overlay:Show()
end

UpdatePartyDispelTrackingOverlay = function(frame, unit, primaryEnum, primaryColorOverride, inRestricted, forceHide)
    local overlay = EnsurePartyDispelTrackingOverlay(frame)
    if not overlay then
        return
    end

    local combat = EnsurePartyCombatSettingsTable()
    local movementUnlocked = IsPartyDispelMovementModeUnlocked()
    local enabled = (forceHide ~= true) and IsPartyDebuffOverlayEnabled() and (combat.partyDispelTrackingEnabled ~= false)
    local ownerShown = frame and frame.IsShown and (frame:IsShown() == true) or false
    if not enabled then
        overlay:Hide()
        return
    end
    if (not ownerShown) and (not movementUnlocked) then
        overlay:Hide()
        return
    end

    local iconScale = ClampPartyDispelTrackingIconScale(combat.partyDispelTrackingIconScale)
    local overlayAlpha = ClampPartyDispelTrackingAlpha(combat.partyDispelTrackingAlpha)
    local iconSize = GetPartyDispelTrackingIconSize(iconScale)
    local maxShown = math.floor((tonumber(combat.partyDispelTrackingMaxShown) or 4) + 0.5)
    if maxShown < 1 then
        maxShown = 1
    elseif maxShown > PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT then
        maxShown = PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT
    end
    combat.partyDispelTrackingIconScale = iconScale
    combat.partyDispelTrackingAlpha = overlayAlpha
    combat.partyDispelTrackingMaxShown = maxShown

    local offsetX, offsetY = GetPartyDispelTrackingRelativeOffset(frame, iconSize)
    overlay:SetScale(1)
    overlay:SetAlpha(overlayAlpha)
    overlay:ClearAllPoints()
    overlay:SetPoint("CENTER", frame, "CENTER", offsetX, offsetY)
    overlay:SetFrameLevel(((frame and frame.GetFrameLevel and frame:GetFrameLevel()) or 1) + 45)
    overlay:SetFrameStrata("MEDIUM")
    overlay:SetSize((iconSize + 2) * maxShown, iconSize + 2)
    overlay:EnableMouse(false)

    local baseBtn = overlay.iconButton
    if not baseBtn then
        overlay:Hide()
        return
    end

    local iconButtons = overlay.iconButtons
    if type(iconButtons) ~= "table" then
        iconButtons = { baseBtn }
        overlay.iconButtons = iconButtons
    elseif iconButtons[1] ~= baseBtn then
        iconButtons[1] = baseBtn
    end

    local function EnsureIconButton(index)
        local btn = iconButtons[index]
        if btn then
            return btn
        end
        if type(overlay._muiCreateIconButton) == "function" then
            btn = overlay._muiCreateIconButton()
            iconButtons[index] = btn
            return btn
        end
        return nil
    end

    for i = 1, maxShown do
        local btn = EnsureIconButton(i)
        if btn then
            btn:EnableMouse(movementUnlocked ~= true)
            btn:SetSize(iconSize, iconSize)
            btn._muiUnit = unit
        end
    end
    for i = maxShown + 1, #iconButtons do
        local btn = iconButtons[i]
        if btn then
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            if btn.countText then
                btn.countText:SetText("")
            end
            btn:Hide()
        end
    end

    local normalizedPrimary = NormalizePartyHazardEnum(primaryEnum)
    local function CanApplyIconToken(iconToken)
        if iconToken == nil then
            return false
        end
        if IsPartySecretValue(iconToken) then
            -- Restricted token: treat as opaque and pass through to SetTexture().
            return true
        end
        local tokenType = type(iconToken)
        if tokenType == "number" then
            if iconToken == PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON then
                return false
            end
            return iconToken > 0
        end
        if tokenType == "string" then
            if iconToken == "" then
                return false
            end
            local okLower, lower = pcall(string.lower, iconToken)
            if okLower and type(lower) == "string" then
                if lower:find("questionmark", 1, true) or lower:find("inv_misc_questionmark", 1, true) then
                    return false
                end
            end
            return true
        end
        return false
    end
    local function SetIconTexCoord(targetBtn, usingAtlas)
        if not targetBtn or not targetBtn.icon or not targetBtn.icon.SetTexCoord then
            return
        end
        if usingAtlas then
            targetBtn.icon:SetTexCoord(0, 1, 0, 1)
        else
            targetBtn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end
    local function GetHazardIconAtlas(enum)
        if enum == PARTY_HAZARD_ENUM.Magic then
            return "RaidFrame-Icon-DebuffMagic"
        elseif enum == PARTY_HAZARD_ENUM.Curse then
            return "RaidFrame-Icon-DebuffCurse"
        elseif enum == PARTY_HAZARD_ENUM.Disease then
            return "RaidFrame-Icon-DebuffDisease"
        elseif enum == PARTY_HAZARD_ENUM.Poison then
            return "RaidFrame-Icon-DebuffPoison"
        elseif enum == PARTY_HAZARD_ENUM.Bleed then
            return "RaidFrame-Icon-DebuffBleed"
        end
        return nil
    end
    local function ResolveIconFromSpellID(spellID)
        local okSpellID, numericSpellID = pcall(tonumber, spellID)
        if (not okSpellID) or (not numericSpellID) then
            return nil
        end
        if IsPartySecretValue(numericSpellID) or numericSpellID <= 0 then
            return nil
        end
        local spellTexture = nil
        if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
            local okTex, tex = pcall(C_Spell.GetSpellTexture, numericSpellID)
            if okTex and tex then
                spellTexture = tex
            end
        end
        if (not spellTexture) and type(GetSpellTexture) == "function" then
            local okLegacyTex, legacyTex = pcall(GetSpellTexture, numericSpellID)
            if okLegacyTex and legacyTex then
                spellTexture = legacyTex
            end
        end
        if CanApplyIconToken(spellTexture) then
            return spellTexture
        end
        return nil
    end
    local function ApplyEntryToButton(targetBtn, entry)
        if not targetBtn or not entry then
            return false, "HIDE_NO_ENTRY"
        end
        local iconToken = entry.icon
        local iconSource = tostring(entry.source or "entry")
        local blizzEntry = _partyBlizzAuraCache[unit]
        if (not CanApplyIconToken(iconToken)) and blizzEntry and type(blizzEntry.icons) == "table" and entry.auraInstanceID then
            local cachedIcon = blizzEntry.icons[entry.auraInstanceID]
            if CanApplyIconToken(cachedIcon) then
                iconToken = cachedIcon
                iconSource = iconSource .. "+blizz-cache"
            end
        end
        local iconSpellID = entry.spellID
        if (not iconSpellID) and blizzEntry and type(blizzEntry.spellIDs) == "table" and entry.auraInstanceID then
            iconSpellID = blizzEntry.spellIDs[entry.auraInstanceID]
        end
        if (not CanApplyIconToken(iconToken)) and iconSpellID then
            local spellTexture = ResolveIconFromSpellID(iconSpellID)
            if CanApplyIconToken(spellTexture) then
                iconToken = spellTexture
                iconSource = iconSource .. "+spellID"
            end
        end

        local iconAppliedFromAtlas = false
        local atlasEnum = NormalizePartyHazardEnum(entry.enum) or normalizedPrimary
        if not CanApplyIconToken(iconToken) then
            local atlasName = GetHazardIconAtlas(atlasEnum)
            if atlasName and targetBtn.icon and targetBtn.icon.SetAtlas then
                local okAtlas = pcall(targetBtn.icon.SetAtlas, targetBtn.icon, atlasName, false)
                if okAtlas then
                    iconAppliedFromAtlas = true
                    iconSource = iconSource .. "+atlas"
                end
            end
            if not iconAppliedFromAtlas then
                if not movementUnlocked then
                    targetBtn.auraInstanceID = entry.auraInstanceID
                    targetBtn.auraIndex = entry.auraIndex
                    if targetBtn.countText then
                        targetBtn.countText:SetText("")
                    end
                    targetBtn:Hide()
                    return false, "HIDE_NO_USABLE_ICON"
                end
                iconToken = PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON
                iconSource = iconSource .. "+placeholder"
            end
        end

        local setTextureState = "SKIP"
        if iconAppliedFromAtlas then
            SetIconTexCoord(targetBtn, true)
            setTextureState = "OK_ATLAS:" .. iconSource
        else
            SetIconTexCoord(targetBtn, false)
            local okIcon = pcall(targetBtn.icon.SetTexture, targetBtn.icon, iconToken)
            if not okIcon then
                targetBtn.icon:SetTexture(PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON)
                SetIconTexCoord(targetBtn, false)
                setTextureState = "FALLBACK_PLACEHOLDER:" .. iconSource
            else
                setTextureState = "OK:" .. iconSource
            end
        end

        if targetBtn.countText then
            targetBtn.countText:SetText(NormalizePartyAuraStackCount(entry.stackCount))
        end
        targetBtn.auraInstanceID = entry.auraInstanceID
        targetBtn.auraIndex = entry.auraIndex
        return true, setTextureState
    end

    local entries = {}
    local primaryEntry = nil
    if enabled and unit and type(unit) == "string" then
        primaryEntry = CollectPartyDispelTrackingAuraEntry(unit, inRestricted)
    end
    if primaryEntry then
        entries[#entries + 1] = primaryEntry
    end

    if (#entries < maxShown) and unit and type(unit) == "string" then
        local blizzEntry = _partyBlizzAuraCache[unit]
        local usedIIDs = {}
        if primaryEntry and primaryEntry.auraInstanceID then
            usedIIDs[primaryEntry.auraInstanceID] = true
        end

        local function BuildSortedIIDList(auraSet)
            local list = {}
            if type(auraSet) ~= "table" then
                return list
            end
            for iid in pairs(auraSet) do
                list[#list + 1] = iid
            end
            table.sort(list, function(a, b)
                local na = tonumber(a) or 0
                local nb = tonumber(b) or 0
                return na < nb
            end)
            return list
        end

        local function AddFromAuraSet(auraSet, sourceLabel, sourceScore)
            if (#entries >= maxShown) or type(auraSet) ~= "table" then
                return
            end
            local orderedIIDs = BuildSortedIIDList(auraSet)
            for _, iid in ipairs(orderedIIDs) do
                if #entries >= maxShown then
                    break
                end
                if not usedIIDs[iid] then
                    local icon = blizzEntry and blizzEntry.icons and blizzEntry.icons[iid] or nil
                    local stacks = blizzEntry and blizzEntry.stacks and blizzEntry.stacks[iid] or nil
                    local spellID = blizzEntry and blizzEntry.spellIDs and blizzEntry.spellIDs[iid] or nil
                    local hint = blizzEntry and blizzEntry.types and blizzEntry.types[iid] or nil
                    local enum = NormalizePartyHazardEnum(hint)
                    if (not enum or enum == PARTY_HAZARD_ENUM.Unknown) then
                        enum = select(1, ResolvePartyHazardFromAuraInstanceID(unit, iid, hint))
                    end
                    local hasTrackedEnum = enum and enum ~= PARTY_HAZARD_ENUM.Unknown
                    local hasIcon = CanApplyIconToken(icon)
                    if hasTrackedEnum or (inRestricted and hasIcon) then
                        entries[#entries + 1] = {
                            icon = icon,
                            stackCount = stacks,
                            auraInstanceID = iid,
                            auraIndex = nil,
                            enum = enum,
                            source = sourceLabel,
                            sourceScore = sourceScore,
                            spellID = spellID,
                        }
                        usedIIDs[iid] = true
                    end
                end
            end
        end

        AddFromAuraSet(blizzEntry and blizzEntry.dispellable, "BLIZZ_EXTRA_DISPELLABLE", 8)
        AddFromAuraSet(blizzEntry and blizzEntry.debuffs, "BLIZZ_EXTRA_DEBUFF", 9)
    end

    local borderR, borderG, borderB = 0.70, 0.70, 0.70
    local hasBaseBorderColor = false
    if type(primaryColorOverride) == "table" and primaryColorOverride.secret ~= true then
        local r = tonumber(primaryColorOverride[1] or primaryColorOverride.r)
        local g = tonumber(primaryColorOverride[2] or primaryColorOverride.g)
        local b = tonumber(primaryColorOverride[3] or primaryColorOverride.b)
        if r and g and b then
            borderR, borderG, borderB = r, g, b
            hasBaseBorderColor = true
        end
    end
    if (not hasBaseBorderColor) and normalizedPrimary and PARTY_HAZARD_COLORS[normalizedPrimary] then
        local c = PARTY_HAZARD_COLORS[normalizedPrimary]
        borderR, borderG, borderB = c[1], c[2], c[3]
        hasBaseBorderColor = true
    end
    if (not hasBaseBorderColor) and frame and type(frame._muiClassColor) == "table" then
        local cr = tonumber(frame._muiClassColor.r or frame._muiClassColor[1])
        local cg = tonumber(frame._muiClassColor.g or frame._muiClassColor[2])
        local cb = tonumber(frame._muiClassColor.b or frame._muiClassColor[3])
        if cr and cg and cb then
            borderR, borderG, borderB = cr, cg, cb
            hasBaseBorderColor = true
        end
    end

    local activeButtons = {}
    local activeEntries = {}
    local setTextureState = "SKIP"
    local logEntry = nil

    if #entries > 0 then
        for i = 1, maxShown do
            local btn = EnsureIconButton(i)
            local entry = entries[i]
            if btn and entry then
                local shown, state = ApplyEntryToButton(btn, entry)
                if (not logEntry) and entry then
                    logEntry = entry
                    setTextureState = state
                end
                if shown then
                    activeButtons[#activeButtons + 1] = btn
                    activeEntries[#activeEntries + 1] = entry
                else
                    btn.auraInstanceID = nil
                    btn.auraIndex = nil
                    if btn.countText then
                        btn.countText:SetText("")
                    end
                    btn:Hide()
                end
            elseif btn then
                btn.auraInstanceID = nil
                btn.auraIndex = nil
                if btn.countText then
                    btn.countText:SetText("")
                end
                btn:Hide()
            end
        end
    elseif movementUnlocked or (normalizedPrimary and normalizedPrimary ~= PARTY_HAZARD_ENUM.Unknown) then
        local btn = EnsureIconButton(1)
        if btn then
            local appliedPrimaryAtlas = false
            local primaryAtlas = GetHazardIconAtlas(normalizedPrimary)
            if primaryAtlas and btn.icon and btn.icon.SetAtlas then
                local okAtlas = pcall(btn.icon.SetAtlas, btn.icon, primaryAtlas, false)
                if okAtlas then
                    SetIconTexCoord(btn, true)
                    appliedPrimaryAtlas = true
                end
            end
            if (not appliedPrimaryAtlas) and movementUnlocked then
                btn.icon:SetTexture(PARTY_DISPEL_TRACKING.PLACEHOLDER_ICON)
                SetIconTexCoord(btn, false)
            end
            if btn.countText then
                btn.countText:SetText("")
            end
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            if appliedPrimaryAtlas or movementUnlocked then
                activeButtons[1] = btn
                activeEntries[1] = nil
                setTextureState = appliedPrimaryAtlas and (movementUnlocked and "PREVIEW_ATLAS" or "PRIMARY_ATLAS")
                    or "PREVIEW_PLACEHOLDER"
            end
        end
    else
        for i = 1, #iconButtons do
            local btn = iconButtons[i]
            if btn then
                btn.auraInstanceID = nil
                btn.auraIndex = nil
                if btn.countText then
                    btn.countText:SetText("")
                end
                btn:Hide()
            end
        end
        overlay:Hide()
        return
    end

    if #activeButtons == 0 then
        for i = 1, #iconButtons do
            local btn = iconButtons[i]
            if btn then
                btn:Hide()
            end
        end
        overlay:Hide()
        return
    end

    if #activeButtons > 1 then
        setTextureState = setTextureState .. "+multi:" .. tostring(#activeButtons)
    end

    local combat2 = EnsurePartyCombatSettingsTable()
    local perRow = math.max(1, combat2.partyDispelTrackingPerRow or PARTY_DISPEL_TRACKING.DEFAULT_PER_ROW)
    local hSpacing = iconSize + 2
    local vSpacing = iconSize + 2
    local shownCount = #activeButtons
    local cols = math.min(perRow, shownCount)
    local rows = math.ceil(shownCount / perRow)
    local stripWidth = math.max(iconSize + 2, cols * hSpacing)
    local stripHeight = math.max(iconSize + 2, rows * vSpacing)
    overlay:SetSize(stripWidth, stripHeight)
    for i, btn in ipairs(activeButtons) do
        local entry = activeEntries[i]
        local r, g, b = borderR, borderG, borderB
        if entry and entry.enum and PARTY_HAZARD_COLORS[entry.enum] then
            local c = PARTY_HAZARD_COLORS[entry.enum]
            r, g, b = c[1], c[2], c[3]
        end
        SetPartyDispelTrackingIconBorderColor(btn, r, g, b, 1)
        btn:ClearAllPoints()
        local row = math.floor((i - 1) / perRow)
        local col = (i - 1) % perRow
        btn:SetPoint("TOPLEFT", overlay, "TOPLEFT", col * hSpacing, -(row * vSpacing))
        btn:Show()
    end
    for i = shownCount + 1, #iconButtons do
        local btn = iconButtons[i]
        if btn then
            btn.auraInstanceID = nil
            btn.auraIndex = nil
            if btn.countText then
                btn.countText:SetText("")
            end
            btn:Hide()
        end
    end
    overlay:Show()
end

RefreshPartyDispelTrackingOverlays = function(forceHide)
    local hide = forceHide == true
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            local unit = frame.GetAttribute and frame:GetAttribute("unit")
            local primaryEnum, secondaryEnum, collectDiag = nil, nil, nil
            local primaryColorOverride = nil
            local restricted = (InCombatLockdown and InCombatLockdown()) and true or false
            if (not hide) and unit and type(unit) == "string" and UnitExists and UnitExists(unit) then
                primaryEnum, secondaryEnum, collectDiag = CollectPartyHazardsForUnit(unit)
                primaryColorOverride = collectDiag and collectDiag.customPrimaryColor or nil
                primaryEnum, secondaryEnum, primaryColorOverride = ApplyPartyStickyHazardFallback(frame, primaryEnum, secondaryEnum, primaryColorOverride, collectDiag)
                if collectDiag and collectDiag.inRestricted == "YES" then
                    restricted = true
                end
            end
            UpdatePartyDispelTrackingOverlay(frame, unit, primaryEnum, primaryColorOverride, restricted, hide)
        end
    end
    if hide then
        if PartyDispelTrackingState.dragOverlay then
            PartyDispelTrackingState.dragOverlay:Hide()
        end
    else
        UpdatePartyDispelTrackingDragOverlay()
    end
end

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = 12,
            healthFont = "Fonts\\FRIZQT__.TTF",
            healthSize = 11,
            nameShadowAlpha = 0.9,
            healthShadowAlpha = 0.9,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    frame.nameText:SetShadowOffset(1, -1); frame.nameText:SetShadowColor(0, 0, 0, 0.9)
    frame.healthText:SetShadowOffset(1, -1); frame.healthText:SetShadowColor(0, 0, 0, 0.9)
end

local function ApplyCircleRingTexture(tex, color)
    if not tex then return end
    tex:SetTexture("Interface\\Buttons\\WHITE8X8")
    tex:SetBlendMode("DISABLE")
    if color then
        tex:SetVertexColor(color.r or 1, color.g or 1, color.b or 1, color.a or 1)
    end
end

local function SafeUnitValue(fn, unit)
    if type(fn) ~= "function" then return nil end
    local ok, val = pcall(fn, unit)
    if not ok then return nil end
    if type(issecretvalue) == "function" and issecretvalue(val) then return nil end
    return val
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

local function GetPartyUnitHealthValues(unit)
    local hp = SafeUnitValue(UnitHealth, unit)
    local maxHp = SafeUnitValue(UnitHealthMax, unit)
    if hp ~= nil and maxHp ~= nil and maxHp > 0 then
        return hp, maxHp, true
    end
    local isGroupUnit = false
    if UnitIsUnit and UnitIsUnit(unit, "player") then
        isGroupUnit = true
    elseif UnitInParty and UnitInParty(unit) then
        isGroupUnit = true
    elseif UnitInRaid and UnitInRaid(unit) then
        isGroupUnit = true
    end
    if not isGroupUnit then
        if UnitExists and UnitExists(unit) then
            local okHp, rawHp = pcall(UnitHealth, unit)
            local okMax, rawMax = pcall(UnitHealthMax, unit)
            if okHp and okMax then
                if type(issecretvalue) == "function" and (issecretvalue(rawHp) or issecretvalue(rawMax)) then
                    return nil, nil, false
                end
                local hpNum = CoerceNumber(rawHp)
                local maxNum = CoerceNumber(rawMax)
                if hpNum ~= nil and maxNum ~= nil and maxNum > 0 then
                    return hpNum, maxNum, false
                end
            end
        end
        return nil, nil, false
    end
    local okHp, rawHp = pcall(UnitHealth, unit)
    local okMax, rawMax = pcall(UnitHealthMax, unit)
    if okHp and okMax then
        local hpNum = CoerceNumber(rawHp)
        local maxNum = CoerceNumber(rawMax)
        if hpNum ~= nil and maxNum ~= nil and maxNum > 0 then
            return hpNum, maxNum, false
        end
    end
    return nil, nil, false
end

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local lastAllowSecretState = nil

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
            return pct
        end
    end
    return nil
end

local function GetDisplayHealthPercentWithText(unit)
    local pct = GetDisplayHealthPercent(unit)
    if pct == nil then
        return nil, nil
    end
    local ok, text = pcall(string.format, "%.0f%%", pct)
    if not ok or text == nil then
        return nil, nil
    end
    return pct, text
end


local function UpdatePartyRangeForFrame(frame)
    local unit = frame:GetAttribute("unit")
    if UnitExists(unit) then
        local inRange = true
        local ok, val = pcall(UnitInRange, unit)
        if ok and not IsSecretValue(val) and (val == true or val == false) then
            inRange = val
        end
        if not inRange and UnitIsUnit(unit, "player") then
            inRange = true
        end
        frame:SetAlpha(inRange and 1.0 or 0.35)
    else
        frame:SetAlpha(1.0)
    end
end

local function UpdatePartyRanges()
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame and frame:IsShown() then
            UpdatePartyRangeForFrame(frame)
        end
    end
end

local function EnsurePartyRangeTicker()
    if PartyRangeTicker then return end
    PartyRangeTicker = C_Timer.NewTicker(0.2, UpdatePartyRanges)
end

local function ShowUnitTooltip(owner, unit)
    if not owner or not unit then return end
    if not UnitExists or not UnitExists(unit) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetUnit(unit)
    GameTooltip:Show()
end

local function ShowDummyTooltip(owner, name, class, role)
    if not owner then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:ClearLines()
    local displayName = name or "Party Member"
    local classText = class or "Adventurer"
    local roleText = role or "DAMAGER"
    GameTooltip:AddLine(displayName, 1, 0.82, 0)
    local roleAtlas = nil
    if roleText == "TANK" then
        roleAtlas = "UI-LFG-RoleIcon-Tank"
    elseif roleText == "HEALER" then
        roleAtlas = "UI-LFG-RoleIcon-Healer"
    else
        roleAtlas = "UI-LFG-RoleIcon-DPS"
    end
    local roleIconMarkup = roleAtlas and ("|A:" .. roleAtlas .. ":16:16|a") or roleText
    GameTooltip:AddDoubleLine("Level 70 " .. classText, roleIconMarkup, 1, 1, 1, 1, 1, 1)
    GameTooltip:AddLine(" ", 1, 1, 1)
    GameTooltip:AddDoubleLine("Health", "128,430 / 146,200", 0.7, 1, 0.7, 0.9, 1, 0.9)
    GameTooltip:AddDoubleLine("Mana", "92,110 / 138,560", 0.6, 0.8, 1, 0.8, 0.9, 1)
    GameTooltip:Show()
end

local function EnsurePartyAnchor()
    if PartyAnchor then return end
    PartyAnchor = CreateFrame("Frame", "MidnightUI_PartyAnchor", UIParent)
    PartyAnchor:SetSize(config.width, config.height)
    PartyAnchor:SetMovable(true)
    PartyAnchor:SetClampedToScreen(true)
    local pos = MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.position
    if pos then
        if pos[2] == "UIParent" and pos[3] then
            PartyAnchor:SetPoint(pos[1], UIParent, pos[3], pos[4], pos[5])
        else
            PartyAnchor:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        end
    else
        PartyAnchor:SetPoint(unpack(config.startPos))
    end
end

local function ApplyPartyConfigFromSettings() end

local function UpdatePartyOverlayPreview()
    if not PartyAnchor or not PartyAnchor.dragOverlay then return end
    if not PartyAnchor.dragOverlay:IsShown() then return end
    local w = config.width
    local h = config.height
    local spacingX = config.spacingX or 8
    local spacingY = config.spacingY or 8
    local total = 4
    local isSquare = (config.style == "Square")
    if isSquare then
        w = config.diameter or math.min(w, h)
        h = w
    end

    -- Resize overlay to fit preview boxes
    local previewWidth
    local previewHeight
    if config.layout == "Horizontal" then
        previewWidth = (w * total) + (spacingX * (total - 1))
        previewHeight = h
    else
        previewWidth = w
        previewHeight = (h * total) + (spacingY * (total - 1))
    end
    PartyAnchor.dragOverlay:SetSize(previewWidth + OVERLAY_PAD.left + OVERLAY_PAD.right, previewHeight + OVERLAY_PAD.top + OVERLAY_PAD.bottom)

    for i = 1, total do
        local box = PartyPreviewBoxes[i]
        if not box then
            box = CreateFrame("Frame", nil, PartyAnchor.dragOverlay, "BackdropTemplate")
            box:SetBackdrop({
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            box:SetBackdropColor(0.15, 0.18, 0.24, 0.55)
            box:SetBackdropBorderColor(0.35, 0.75, 1.0, 0.95)
            local n = box:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            n:SetPoint("CENTER")
            n:SetText(tostring(i))
            n:SetTextColor(1, 0.9, 0.1)
            box.label = n
            local circle = CreateFrame("Frame", nil, box)
            circle:SetAllPoints()
            circle:Hide()
            box.circle = circle

            circle.mask = nil
            circle.bg = nil

            local squarePortrait = circle:CreateTexture(nil, "BACKGROUND")
            squarePortrait:SetAllPoints(circle)
            squarePortrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            circle.portrait = squarePortrait

            local squareBorder = CreateFrame("Frame", nil, circle, "BackdropTemplate")
            squareBorder:SetAllPoints(circle)
            squareBorder:SetFrameLevel(circle:GetFrameLevel() + 5)
            squareBorder:SetBackdrop({
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
                insets = { left = 0, right = 0, top = 0, bottom = 0 }
            })
            squareBorder:SetBackdropBorderColor(0, 0, 0, 1)
            circle.border = squareBorder

            local circleFill = CreateFrame("StatusBar", nil, circle)
            circleFill:SetPoint("TOPLEFT", circle, "TOPLEFT", 0, 0)
            circleFill:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", 0, 0)
            circleFill:SetFrameLevel(circle:GetFrameLevel() + 1)
            circleFill._muiInset = 0
            circleFill:SetOrientation("VERTICAL")
            circleFill:SetReverseFill(false)
            circleFill:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            circleFill:SetMinMaxValues(0, 1)
            circleFill:SetValue(1)
            circleFill:SetStatusBarColor(0, 1, 0, 0.5)
            circle.fill = circleFill

            circle.borderFrame = nil
            circle.borderOuter = nil

            local textFrame = CreateFrame("Frame", nil, circle)
            textFrame:SetAllPoints()
            textFrame:SetFrameLevel(circle:GetFrameLevel() + 10)
            circle.textFrame = textFrame

            local pctText = textFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            pctText:SetPoint("CENTER")
            pctText:SetTextColor(1, 1, 1, 1)
            pctText:SetDrawLayer("OVERLAY", 7)
            circle.pctText = pctText

            local roleIcon = circle:CreateTexture(nil, "OVERLAY", nil, 6)
            roleIcon:SetSize(22, 22)
            roleIcon:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", 2, -2)
            circle.roleIcon = roleIcon
            roleIcon:SetVertexColor(1, 1, 1, 1)
            roleIcon:SetAlpha(1)
            roleIcon:SetDrawLayer("OVERLAY", 7)

            roleIcon:EnableMouse(true)
            roleIcon:SetScript("OnEnter", function(self)
                if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.showTooltip == false then
                    return
                end
                ShowDummyTooltip(self, self._muiDummyName, self._muiDummyClass, self._muiDummyRole)
            end)
            roleIcon:SetScript("OnLeave", function()
                GameTooltip:Hide()
            end)

            PartyPreviewBoxes[i] = box
        end
        box:SetSize(w, h)
        box:ClearAllPoints()
        if config.layout == "Horizontal" then
            box:SetPoint("TOPLEFT", PartyAnchor, "TOPLEFT", (i - 1) * (w + spacingX), 0)
        else
            box:SetPoint("TOPLEFT", PartyAnchor, "TOPLEFT", 0, -((i - 1) * (h + spacingY)))
        end
        if isSquare and box.circle then
            box:SetBackdropColor(0, 0, 0, 0)
            box:SetBackdropBorderColor(0, 0, 0, 0)
            if box.label then box.label:Hide() end
            box.circle:Show()
            local pct = 1 - ((i - 1) * 0.15)
            pct = math.max(0.2, pct)
            local innerSize = math.max(1, h - 4)
            if box.circle.portrait then
                box.circle.portrait:SetTexture("Interface\\ICONS\\INV_Misc_QuestionMark")
            end
            if box.circle.fill then
                box.circle.fill:SetMinMaxValues(0, 1)
                box.circle.fill:SetValue(pct)
                local r, g
                if pct >= 0.5 then
                    local t = (pct - 0.5) / 0.5
                    r = 1 - t
                    g = 1
                else
                    local t = pct / 0.5
                    r = 1
                    g = t
                end
                box.circle.fill:SetStatusBarColor(r, g, 0, 0.5)
            end
            if box.circle.pctText then
                box.circle.pctText:SetText(string.format("%d", math.floor(pct * 100 + 0.5)))
            end
            if box.circle.roleIcon then
                local iconSize = math.max(12, math.floor(w * 0.32 + 0.5))
                box.circle.roleIcon:SetSize(iconSize, iconSize)
                box.circle.roleIcon:ClearAllPoints()
                box.circle.roleIcon:SetPoint("BOTTOMRIGHT", box.circle, "BOTTOMRIGHT", -2, 2)
                box.circle.roleIcon:SetVertexColor(1, 1, 1, 1)
                box.circle.roleIcon:SetAlpha(1)
                box.circle.roleIcon:SetDrawLayer("OVERLAY", 7)
                if w < 35 then
                    box.circle.roleIcon:Hide()
                elseif i == 1 then
                    box.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-Tank")
                    box.circle.roleIcon._muiDummyRole = "TANK"
                    box.circle.roleIcon._muiDummyClass = "Protection Warrior"
                    box.circle.roleIcon._muiDummyName = "Tanky"
                    box.circle.roleIcon:Show()
                elseif i == 2 then
                    box.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-Healer")
                    box.circle.roleIcon._muiDummyRole = "HEALER"
                    box.circle.roleIcon._muiDummyClass = "Restoration Druid"
                    box.circle.roleIcon._muiDummyName = "Heals"
                    box.circle.roleIcon:Show()
                else
                    box.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-DPS")
                    box.circle.roleIcon._muiDummyRole = "DAMAGER"
                    box.circle.roleIcon._muiDummyClass = "Damage Dealer"
                    box.circle.roleIcon._muiDummyName = "DPS"
                    box.circle.roleIcon:Show()
                end
            end
        else
            if box.circle then box.circle:Hide() end
            if box.label then box.label:Show() end
            box:SetBackdropColor(0.15, 0.18, 0.24, 0.55)
            box:SetBackdropBorderColor(0.35, 0.75, 1.0, 0.95)
        end
        box:Show()
    end

    for i = total + 1, #PartyPreviewBoxes do
        if PartyPreviewBoxes[i] then PartyPreviewBoxes[i]:Hide() end
    end
    if UpdatePartyDispelTrackingDragOverlay then
        UpdatePartyDispelTrackingDragOverlay()
    end
end

local pendingPartyLayout = false

local function LayoutPartyFrames()
    ApplyPartyConfigFromSettings()
    EnsurePartyAnchor()
    if not PartyAnchor then return end
    -- Party frames use SecureUnitButtonTemplate; SetSize/SetPoint/ClearAllPoints
    -- are blocked during combat lockdown.
    if InCombatLockdown and InCombatLockdown() then
        pendingPartyLayout = true
        return
    end
    pendingPartyLayout = false
    local w = config.width
    local h = config.height
    if config.style == "Square" then
        w = config.diameter or math.min(w, h)
        h = w
    end
    local hide2DPortrait = (config.style ~= "Square") and (config.hide2DPortrait == true)
    local spacingX = config.spacingX or 8
    local spacingY = config.spacingY or 8
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            frame:SetSize(w, h)
            frame:ClearAllPoints()
            if config.layout == "Horizontal" then
                frame:SetPoint("TOPLEFT", PartyAnchor, "TOPLEFT", (i - 1) * (w + spacingX), 0)
            else
                frame:SetPoint("TOPLEFT", PartyAnchor, "TOPLEFT", 0, -((i - 1) * (h + spacingY)))
            end
            if frame.portrait then
                local portraitSize = hide2DPortrait and 0 or (h - 2)
                frame.portrait:SetSize(portraitSize, portraitSize)
            end
            if frame.healthContainer then
                frame.healthContainer:ClearAllPoints()
                if hide2DPortrait then
                    frame.healthContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
                else
                    frame.healthContainer:SetPoint("TOPLEFT", frame.portrait, "TOPRIGHT", 0, 0)
                end
                frame.healthContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
                frame.healthContainer:SetHeight(h * 0.75)
            end
            if frame.powerContainer then
                frame.powerContainer:SetHeight(math.max(8, h - (h * 0.75) - 2))
            end
            if frame.roleIcon and frame.healthContainer then
                frame.roleIcon:ClearAllPoints()
                if hide2DPortrait then
                    frame.roleIcon:SetPoint("BOTTOMLEFT", frame.healthContainer, "BOTTOMLEFT", -2, 2)
                else
                    frame.roleIcon:SetPoint("BOTTOMRIGHT", frame.portrait, "BOTTOMRIGHT", 2, -2)
                end
            end
            if frame.leaderIcon and frame.healthContainer then
                frame.leaderIcon:ClearAllPoints()
                if hide2DPortrait then
                    frame.leaderIcon:SetPoint("TOPLEFT", frame.healthContainer, "TOPLEFT", -2, 2)
                else
                    frame.leaderIcon:SetPoint("TOPLEFT", frame.portrait, "TOPLEFT", -2, 2)
                end
            end
            if frame.phaseIcon and frame.healthContainer then
                frame.phaseIcon:ClearAllPoints()
                if hide2DPortrait then
                    frame.phaseIcon:SetPoint("CENTER", frame.healthContainer, "CENTER", 0, 0)
                else
                    frame.phaseIcon:SetPoint("CENTER", frame.portrait, "CENTER", 0, 0)
                end
            end
            if frame.auras then
                frame.auras:SetSize(w, config.auraSize or 20)
            end
        end
    end
    if config.layout == "Horizontal" then
        PartyAnchor:SetSize((w * 4) + (spacingX * 3), h)
    else
        PartyAnchor:SetSize(w, (h * 4) + (spacingY * 3))
    end
    UpdatePartyOverlayPreview()
end

function MidnightUI_ApplyPartyFramesLayout()
    ApplyPartyConfigFromSettings()
    LayoutPartyFrames()
    if _G.MidnightUI_Debug then
    end
    for i = 1, 4 do
        local f = PartyFrames[i]
        if f then UpdatePartyUnit(f) end
    end
end

function MidnightUI_SetPartyStyle(style)
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.style = style
    config.style = style
    MidnightUI_ApplyPartyFramesLayout()
end

function MidnightUI_SetPartyFramesLocked(locked)
    EnsurePartyAnchor()
    if not PartyAnchor then return end
    PartyDispelTrackingState.locked = (locked ~= false)
    if locked then
        if PartyAnchor.dragOverlay then PartyAnchor.dragOverlay:Hide() end
        if PartyDispelTrackingState.dragOverlay then
            PartyDispelTrackingState.dragOverlay:Hide()
        end
    else
        if not PartyAnchor.dragOverlay then
            local overlay = CreateFrame("Frame", nil, PartyAnchor, "BackdropTemplate")
            overlay:ClearAllPoints()
            overlay:SetPoint("TOPLEFT", -OVERLAY_PAD.left, OVERLAY_PAD.top)
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
            label:SetPoint("BOTTOM", overlay, "BOTTOM", 0, 22)
            label:SetText("PARTY FRAMES")
            label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true)
            overlay:RegisterForDrag("LeftButton")
            overlay:SetScript("OnDragStart", function() PartyAnchor:StartMoving() end)
            overlay:SetScript("OnDragStop", function()
                PartyAnchor:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = PartyAnchor:GetPoint()
                if MidnightUISettings and MidnightUISettings.PartyFrames then
                    MidnightUISettings.PartyFrames.position = { point, relativePoint, xOfs, yOfs }
                end
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "PartyFrames")
            end
            PartyAnchor.dragOverlay = overlay
        end
        PartyAnchor.dragOverlay:Show()
        UpdatePartyOverlayPreview()
        UpdatePartyDispelTrackingDragOverlay()
    end
    if RefreshPartyDispelTrackingOverlays then
        RefreshPartyDispelTrackingOverlays(false)
    end
end

local function SetPartyDispelTrackingLocked(locked)
    PartyDispelTrackingState.locked = (locked ~= false)
    if locked and PartyDispelTrackingState.dragOverlay then
        PartyDispelTrackingState.dragOverlay:Hide()
    end
    if RefreshPartyDispelTrackingOverlays then
        RefreshPartyDispelTrackingOverlays(false)
    end
end

-- =========================================================================
--  FRAME CREATION
-- =========================================================================

local function CreateSinglePartyFrame(index)
    local unit = "party"..index
    local frameName = "MidnightUI_PartyFrame"..index
    
    EnsurePartyAnchor()
    local frame = CreateFrame("Button", frameName, PartyAnchor, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(config.width, config.height)
    frame:SetAttribute("unit", unit)
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")
    
    frame:ClearAllPoints()

    RegisterUnitWatch(frame)

    frame:SetScript("OnEnter", function(self)
        if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.showTooltip == false then
            return
        end
        local u = self:GetAttribute("unit")
        ShowUnitTooltip(self, u)
    end)
    frame:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    frame:SetFrameStrata("MEDIUM"); frame:SetFrameLevel(10); frame:EnableMouse(true)
    
    -- Clean 1px Border & Background
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    frame._muiBackdropOrig = frame:GetBackdrop()
    frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
    frame:SetBackdropBorderColor(0, 0, 0, 1)

    -- Subtle Drop Shadow (Reduced intensity)
    frame.shadows = CreateDropShadow(frame, 3)

    -- PORTRAIT (Left Side)
    local portraitSize = config.height - 2
    local portrait = frame:CreateTexture(nil, "ARTWORK")
    portrait:SetSize(portraitSize, portraitSize)
    portrait:SetPoint("LEFT", frame, "LEFT", 1, 0)
    portrait:SetAlpha(1)
    
    -- Portrait Separator
    local portraitSep = frame:CreateTexture(nil, "OVERLAY")
    portraitSep:SetWidth(1)
    portraitSep:SetPoint("TOPRIGHT", portrait, "TOPRIGHT", 0, 0)
    portraitSep:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", 0, 0)
    portraitSep:SetColorTexture(0, 0, 0, 1)
    frame.portraitSep = portraitSep
    
    -- Portrait Background (fallback)
    local portraitBg = frame:CreateTexture(nil, "BACKGROUND")
    portraitBg:SetAllPoints(portrait)
    portraitBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.portraitBg = portraitBg
    frame.portrait = portrait

    -- HEALTH CONTAINER
    local healthContainer = CreateFrame("Frame", nil, frame)
    healthContainer:SetPoint("TOPLEFT", portrait, "TOPRIGHT", 0, 0)
    healthContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    healthContainer:SetHeight(config.height * 0.75)
    frame.healthContainer = healthContainer
    
    -- Health Background
    local healthBg = healthContainer:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints()
    healthBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.healthBg = healthBg

    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetAllPoints()
    ApplyHealthBarStyle(healthBar)
    healthBar:SetStatusBarColor(0.5, 0.5, 0.5, 0.92); healthBar:SetMinMaxValues(0, 1); healthBar:SetValue(1)
    frame.healthBar = healthBar
    
    -- Absorb Overlay
    local absorbBar = CreateFrame("StatusBar", nil, healthContainer)
    absorbBar:SetAllPoints()
    absorbBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    absorbBar:SetStatusBarColor(0.6, 0.9, 1, 0.35)
    absorbBar:SetMinMaxValues(0, 1); absorbBar:SetValue(0)
    frame.absorbBar = absorbBar

    -- TEXT OVERLAY FRAME (ensures text is above the health bar)
    local textFrame = CreateFrame("Frame", nil, healthContainer)
    textFrame:SetAllPoints()
    textFrame:SetFrameLevel(healthContainer:GetFrameLevel() + 5)

    -- POWER
    local powerContainer = CreateFrame("Frame", nil, frame)
    powerContainer:SetPoint("TOPLEFT", healthContainer, "BOTTOMLEFT", 0, -1)
    powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.powerContainer = powerContainer
    
    -- Power Separator
    local pSep = powerContainer:CreateTexture(nil, "OVERLAY", nil, 7)
    pSep:SetHeight(1); pSep:SetPoint("TOPLEFT"); pSep:SetPoint("TOPRIGHT")
    pSep:SetColorTexture(0, 0, 0, 1)
    
    -- Power background - darker for better contrast
    local powerBg = powerContainer:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints()
    powerBg:SetColorTexture(0.02, 0.02, 0.02, 1)
    frame.powerBg = powerBg

    local powerBar = CreateFrame("StatusBar", nil, powerContainer)
    powerBar:SetAllPoints()
    powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    powerBar:GetStatusBarTexture():SetHorizTile(false)
    powerBar:SetStatusBarColor(0, 0.5, 1, 0.95); powerBar:SetMinMaxValues(0, 1); powerBar:SetValue(1)
    frame.powerBar = powerBar

    -- TEXT
    local nameText = textFrame:CreateFontString(nil, "OVERLAY")
    nameText:SetPoint("LEFT", healthContainer, "LEFT", 6, 1)
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    nameText:SetTextColor(1, 1, 1, 1); nameText:SetShadowOffset(1, -1); nameText:SetShadowColor(0, 0, 0, 0.9)
    frame.nameText = nameText

    local healthText = textFrame:CreateFontString(nil, "OVERLAY")
    healthText:SetPoint("RIGHT", healthContainer, "RIGHT", -6, 1)
    SetFontSafe(healthText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    healthText:SetTextColor(1, 1, 1, 1); healthText:SetShadowOffset(1, -1); healthText:SetShadowColor(0, 0, 0, 0.9)
    frame.healthText = healthText

    -- SIMPLE MODE TEXT (anchored to health container for vertical centering)
    local simpleTextFrame = CreateFrame("Frame", nil, healthContainer)
    simpleTextFrame:SetAllPoints(healthContainer)
    simpleTextFrame:SetFrameLevel(healthContainer:GetFrameLevel() + 5)
    simpleTextFrame:Hide()
    frame.simpleTextFrame = simpleTextFrame

    local simpleNameText = simpleTextFrame:CreateFontString(nil, "OVERLAY")
    simpleNameText:SetPoint("LEFT", simpleTextFrame, "LEFT", 6, 0)
    simpleNameText:SetPoint("CENTER", simpleTextFrame, "CENTER", 0, 0)
    SetFontSafe(simpleNameText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    simpleNameText:SetTextColor(1, 1, 1, 1)
    simpleNameText:SetShadowOffset(1, -1)
    simpleNameText:SetShadowColor(0, 0, 0, 0.9)
    frame.simpleNameText = simpleNameText

    local simpleHealthText = simpleTextFrame:CreateFontString(nil, "OVERLAY")
    simpleHealthText:SetPoint("RIGHT", simpleTextFrame, "RIGHT", -6, 0)
    simpleHealthText:SetPoint("CENTER", simpleTextFrame, "CENTER", 0, 0)
    SetFontSafe(simpleHealthText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    simpleHealthText:SetTextColor(1, 1, 1, 1)
    simpleHealthText:SetShadowOffset(1, -1)
    simpleHealthText:SetShadowColor(0, 0, 0, 0.9)
    frame.simpleHealthText = simpleHealthText

    -- SQUARE MODE
    local circle = CreateFrame("Frame", nil, frame)
    circle:SetSize(config.height, config.height)
    circle:SetPoint("LEFT", frame, "LEFT", 0, 0)
    circle:Hide()
    frame.circle = circle
    frame.square = circle
  
    circle.mask = nil
    circle.bg = nil
  
    local squarePortrait = circle:CreateTexture(nil, "BACKGROUND")
    squarePortrait:SetAllPoints(circle)
    squarePortrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    circle.portrait = squarePortrait

    local squareBorder = CreateFrame("Frame", nil, circle, "BackdropTemplate")
    squareBorder:SetAllPoints(circle)
    squareBorder:SetFrameLevel(circle:GetFrameLevel() + 5)
    squareBorder:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    squareBorder:SetBackdropBorderColor(0, 0, 0, 1)
    circle.border = squareBorder
  
    local circleFill = CreateFrame("StatusBar", nil, circle)
    circleFill:SetPoint("TOPLEFT", circle, "TOPLEFT", 0, 0)
    circleFill:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", 0, 0)
    circleFill:SetFrameLevel(circle:GetFrameLevel() + 1)
    circleFill._muiInset = 0
    circleFill:SetOrientation("VERTICAL")
    circleFill:SetReverseFill(false)
    circleFill:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    circleFill:SetMinMaxValues(0, 1)
    circleFill:SetValue(1)
    circleFill:SetStatusBarColor(0, 1, 0, 0.5)
    circle.fill = circleFill
  
    circle.borderFrame = nil
    circle.borderOuter = nil
  
    circle.shadows = CreateDropShadow(circle, 2)
  
    local textFrame = CreateFrame("Frame", nil, circle)
    textFrame:SetAllPoints()
    textFrame:SetFrameLevel(circle:GetFrameLevel() + 10)
    circle.textFrame = textFrame

    local pctText = textFrame:CreateFontString(nil, "OVERLAY")
    pctText:SetPoint("CENTER")
    SetFontSafe(pctText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    pctText:SetTextColor(1, 1, 1, 1)
    pctText:SetShadowOffset(1, -1)
    pctText:SetShadowColor(0, 0, 0, 0.9)
    pctText:SetDrawLayer("OVERLAY", 7)
    circle.pctText = pctText

    local circleDeadIcon = textFrame:CreateTexture(nil, "OVERLAY", nil, 7)
    circleDeadIcon:SetSize(12, 12)
    circleDeadIcon:SetPoint("CENTER", pctText, "CENTER", 0, 0)
    EnsureDeadIconTexture(circleDeadIcon)
    circleDeadIcon:SetVertexColor(1, 1, 1, 1)
    circleDeadIcon:SetDrawLayer("OVERLAY", 7)
    circleDeadIcon:SetAlpha(1)
    circleDeadIcon:Hide()
    circle.deadIcon = circleDeadIcon

    local roleIcon = circle:CreateTexture(nil, "OVERLAY", nil, 6)
    roleIcon:SetSize(24, 24)
    roleIcon:SetPoint("BOTTOMRIGHT", circle, "BOTTOMRIGHT", 2, -2)
    circle.roleIcon = roleIcon
    roleIcon:SetVertexColor(1, 1, 1, 1)
    roleIcon:SetAlpha(1)
    roleIcon:SetDrawLayer("OVERLAY", 7)

    roleIcon:EnableMouse(true)
    roleIcon:SetScript("OnEnter", function(self)
        if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.showTooltip == false then
            return
        end
        local owner = self
        local unit = frame:GetAttribute("unit")
        ShowUnitTooltip(owner, unit)
    end)
    roleIcon:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    
    -- RESURRECTION ICON (centered, hidden by default) with enhanced styling
    local resIcon = textFrame:CreateTexture(nil, "OVERLAY")
    resIcon:SetSize(28, 28)
    resIcon:SetPoint("CENTER", healthContainer, "CENTER", 0, 0)
    resIcon:SetTexture("Interface\\RaidFrame\\Raid-Icon-Rez")
    resIcon:SetVertexColor(1, 1, 1, 1)
    resIcon:Hide()
    frame.resIcon = resIcon

    local deadIcon = textFrame:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(14, 14)
    deadIcon:SetPoint("CENTER", healthText, "CENTER", 0, 0)
    EnsureDeadIconTexture(deadIcon)
    deadIcon:SetVertexColor(1, 1, 1, 1)
    deadIcon:SetDrawLayer("OVERLAY", 7)
    deadIcon:SetAlpha(1)
    deadIcon:Hide()
    frame.deadIcon = deadIcon
    
    -- Resurrection icon glow effect - MUCH MORE VISIBLE
    local resGlow = textFrame:CreateTexture(nil, "ARTWORK")
    resGlow:SetSize(50, 50)
    resGlow:SetPoint("CENTER", resIcon, "CENTER")
    resGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    resGlow:SetVertexColor(1, 0.85, 0.3, 0)
    resGlow:SetBlendMode("ADD")
    resGlow:Hide()
    frame.resGlow = resGlow

    -- ROLE ICON
    local roleIcon = textFrame:CreateTexture(nil, "OVERLAY")
    roleIcon:SetSize(26, 26)
    roleIcon:SetPoint("BOTTOMRIGHT", portrait, "BOTTOMRIGHT", 2, -2)
    frame.roleIcon = roleIcon
    roleIcon:SetVertexColor(1, 1, 1, 1)

    -- LEADER ICON
    local leaderIcon = textFrame:CreateTexture(nil, "OVERLAY")
    leaderIcon:SetSize(14, 14)
    leaderIcon:SetPoint("TOPLEFT", portrait, "TOPLEFT", -2, 2)
    frame.leaderIcon = leaderIcon

    -- TARGET HIGHLIGHT
    local targetHl = frame:CreateTexture(nil, "OVERLAY")
    targetHl:SetAllPoints()
    targetHl:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
    targetHl:SetVertexColor(1, 1, 1, 0.2)
    targetHl:SetBlendMode("ADD")
    targetHl:Hide()
    frame.targetHighlight = targetHl

    -- READY CHECK ICON
    local rcIcon = healthContainer:CreateTexture(nil, "OVERLAY")
    rcIcon:SetSize(24, 24); rcIcon:SetPoint("CENTER"); rcIcon:Hide()
    frame.readyCheckIcon = rcIcon

    -- PHASE INDICATOR
    local phaseIcon = frame:CreateTexture(nil, "OVERLAY")
    phaseIcon:SetSize(24, 24)
    phaseIcon:SetPoint("CENTER", portrait, "CENTER", 0, 0)
    phaseIcon:SetTexture("Interface\\TargetingFrame\\UI-PhasingIcon")
    phaseIcon:Hide()
    frame.phaseIcon = phaseIcon

    -- AURAS CONTAINER
    frame.auras = CreateFrame("Frame", nil, frame); frame.auras:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, -4); frame.auras:SetSize(config.width, config.auraSize); frame.auraButtons = {}

    -- Dispel glow overlay (currently disabled; reserved for future aura alert logic)
    local dispelGlow = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    dispelGlow:SetPoint("TOPLEFT", -2, 2)
    dispelGlow:SetPoint("BOTTOMRIGHT", 2, -2)
    dispelGlow:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 2,
    })
    dispelGlow:SetBackdropBorderColor(0, 0, 0, 0)
    dispelGlow:SetFrameLevel(frame:GetFrameLevel() + 20)
    dispelGlow:EnableMouse(false)
    dispelGlow:Hide()
    frame.dispelGlow = dispelGlow

    EnsurePartyDispelTrackingOverlay(frame)

    return frame
end

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function BuildPartyOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    local s = MidnightUISettings.PartyFrames
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Dropdown("Party Layout", {"Vertical", "Horizontal"}, s.layout or "Vertical", function(v)
        s.layout = v
        if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        if _G.MidnightUI_ShowOverlaySettings then _G.MidnightUI_ShowOverlaySettings("PartyFrames") end
    end)
    b:Dropdown("Party Styling", {"Rendered", "Simple", "Square"}, s.style or "Rendered", function(v)
        if _G.MidnightUI_SetPartyStyle then
            _G.MidnightUI_SetPartyStyle(v)
        else
            s.style = v
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end
        if _G.MidnightUI_ShowOverlaySettings then _G.MidnightUI_ShowOverlaySettings("PartyFrames") end
    end)

    if (s.style or "Rendered") == "Square" then
        b:Slider("Diameter", 28, 140, 2, s.diameter or 64, function(v)
            s.diameter = math.floor(v)
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
    else
        b:Slider("Width", 120, 420, 2, s.width or 240, function(v)
            s.width = math.floor(v)
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
        b:Slider("Height", 24, 120, 2, s.height or 58, function(v)
            s.height = math.floor(v)
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
    end

    if (s.layout or "Vertical") == "Horizontal" then
        b:Slider("Horizontal Spacing", 0, 200, 1, s.spacingX or 8, function(v)
            s.spacingX = math.floor(v)
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
    else
        b:Slider("Vertical Spacing", 0, 200, 1, s.spacingY or 8, function(v)
            s.spacingY = math.floor(v)
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
    end

    if (s.style or "Rendered") ~= "Square" then
        b:Checkbox("Hide 2D Portrait", s.hide2DPortrait == true, function(v)
            s.hide2DPortrait = v and true or false
            if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
        end)
    end

    b:Checkbox("Show Tooltip", s.showTooltip ~= false, function(v)
        s.showTooltip = v and true or false
    end)

    b:Checkbox("Hide In Raid", s.hideInRaid == true, function(v)
        s.hideInRaid = v and true or false
        if _G.MidnightUI_UpdatePartyVisibility then _G.MidnightUI_UpdatePartyVisibility() end
    end)
    b:Checkbox("Party Debuff Overlay", IsPartyDebuffOverlayEnabled(), function(v)
        local combat = EnsurePartyCombatSettingsTable()
        combat.debuffOverlayPartyEnabled = v and true or false
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)

    return b:Height()
end

local function BuildPartyDispelTrackingOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then
        return
    end
    local combat = EnsurePartyCombatSettingsTable()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Party Dispel Icons")
    b:Checkbox("Party Debuff Overlay", IsPartyDebuffOverlayEnabled(), function(v)
        local combatSettings = EnsurePartyCombatSettingsTable()
        combatSettings.debuffOverlayPartyEnabled = v and true or false
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    b:Checkbox("Enable Party Dispel Icons", combat.partyDispelTrackingEnabled ~= false, function(v)
        combat.partyDispelTrackingEnabled = v and true or false
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    b:Slider("Icon Size %", PARTY_DISPEL_TRACKING.ICON_SCALE_MIN, PARTY_DISPEL_TRACKING.ICON_SCALE_MAX, 5, ClampPartyDispelTrackingIconScale(combat.partyDispelTrackingIconScale), function(v)
        combat.partyDispelTrackingIconScale = ClampPartyDispelTrackingIconScale(v)
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, ClampPartyDispelTrackingAlpha(combat.partyDispelTrackingAlpha), function(v)
        combat.partyDispelTrackingAlpha = ClampPartyDispelTrackingAlpha(v)
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    local maxShown = math.floor((tonumber(combat.partyDispelTrackingMaxShown) or 4) + 0.5)
    if maxShown < 1 then
        maxShown = 1
    elseif maxShown > PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT then
        maxShown = PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT
    end
    combat.partyDispelTrackingMaxShown = maxShown
    b:Slider("Max Icons", 1, PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT, 1, maxShown, function(v)
        local n = math.floor((tonumber(v) or 4) + 0.5)
        if n < 1 then
            n = 1
        elseif n > PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT then
            n = PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT
        end
        combat.partyDispelTrackingMaxShown = n
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    local perRow = math.max(1, combat.partyDispelTrackingPerRow or PARTY_DISPEL_TRACKING.DEFAULT_PER_ROW)
    b:Slider("Icons Per Row", 1, PARTY_DISPEL_TRACKING.MAX_SHOWN_LIMIT, 1, perRow, function(v)
        local n = math.floor((tonumber(v) or PARTY_DISPEL_TRACKING.DEFAULT_PER_ROW) + 0.5)
        if n < 1 then n = 1 end
        combat.partyDispelTrackingPerRow = n
        if RefreshPartyDispelTrackingOverlays then
            RefreshPartyDispelTrackingOverlays(false)
        end
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("PartyFrames", { title = "Party Frames", build = BuildPartyOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("PartyDispelTracking", { title = "Party Dispel Icons", build = BuildPartyDispelTrackingOverlaySettings })
end

local function ApplyPartyFramesBarStyle()
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame and frame.healthBar then
            if (config.style or "Rendered") ~= "Rendered" then
                ApplyHealthBarStyle(frame.healthBar)
            else
                ClearBarOverlays(frame.healthBar)
            end
        end
        if frame and frame.powerBar then
            if (config.style or "Rendered") ~= "Rendered" then
                frame.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
                local tex = frame.powerBar:GetStatusBarTexture()
                if tex then
                    tex:SetHorizTile(false)
                    tex:SetVertTile(false)
                end
            else
                ClearBarOverlays(frame.powerBar)
            end
        end
        ApplyFrameTextStyle(frame)
    end
end
_G.MidnightUI_ApplyPartyFramesBarStyle = ApplyPartyFramesBarStyle

-- =========================================================================
--  VISIBILITY (HIDE IN RAID)
-- =========================================================================

local function UpdatePartyVisibility()
    EnsurePartyAnchor()
    if not PartyAnchor then return end
    if InCombatLockdown and InCombatLockdown() then
        pendingPartyVisibility = true
        return
    end
    if PartyTestState.active then
        pendingPartyVisibility = false
        PartyAnchor:Show()
        for i = 1, 4 do
            local frame = PartyFrames[i]
            if frame then
                frame:Show()
                frame:SetAlpha(1)
            end
        end
        return
    end
    pendingPartyVisibility = false
    -- Check if PartyFrames are enabled
    if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.enabled == false then
        for i = 1, 4 do
            local f = PartyFrames[i]
            if f then f:Hide() end
        end
        PartyAnchor:Hide()
        return
    end
    local hideInRaid = MidnightUISettings
        and MidnightUISettings.PartyFrames
        and MidnightUISettings.PartyFrames.hideInRaid == true
    if hideInRaid then
        if RegisterStateDriver then
            RegisterStateDriver(PartyAnchor, "visibility", "[group:raid] hide; show")
        else
            if IsInRaid and IsInRaid() then PartyAnchor:Hide() else PartyAnchor:Show() end
        end
    else
        if RegisterStateDriver then
            -- Clear any prior visibility driver before forcing manual show.
            pcall(UnregisterStateDriver, PartyAnchor, "visibility")
        end
        if PartyAnchor.SetAttribute then PartyAnchor:SetAttribute("state-visibility", "show") end
        PartyAnchor:Show()
        for i = 1, 4 do
            local f = PartyFrames[i]
            if f then
                if UnitExists and UnitExists("party" .. i) then
                    f:Show()
                else
                    f:Hide()
                end
            end
        end
        if _G.MidnightUI_RefreshPartyFrames then _G.MidnightUI_RefreshPartyFrames() end
    end
end

_G.MidnightUI_UpdatePartyVisibility = UpdatePartyVisibility

-- =========================================================================
--  UPDATE FUNCTION
-- =========================================================================

local function UpdateTargetGlow(frame)
    if not frame then return end
    if frame.targetHighlight then frame.targetHighlight:Hide() end
    if frame.circle and frame.circle.border and frame.circle.border.SetBackdropBorderColor then
        frame.circle.border:SetBackdropBorderColor(0, 0, 0, 1)
    end
    if frame.shadows and frame.shadows[1] and frame.shadows[1].tex then
        frame.shadows[1].tex:SetColorTexture(0, 0, 0, 0.28)
    end
end

local function UpdateReadyCheck(frame)
    local unit = frame:GetAttribute("unit")
    local status = GetReadyCheckStatus(unit)
    if status == "ready" then
        frame.readyCheckIcon:SetTexture(READY_CHECK_READY_TEXTURE); frame.readyCheckIcon:Show()
    elseif status == "notready" then
        frame.readyCheckIcon:SetTexture(READY_CHECK_NOT_READY_TEXTURE); frame.readyCheckIcon:Show()
    elseif status == "waiting" then
        frame.readyCheckIcon:SetTexture(READY_CHECK_WAITING_TEXTURE); frame.readyCheckIcon:Show()
    else
        frame.readyCheckIcon:Hide()
    end
end

local function UpdatePhaseStatus(frame)
    local unit = frame:GetAttribute("unit")
    local reason = UnitPhaseReason(unit)
    if reason then
        frame.phaseIcon:Show()
    else
        frame.phaseIcon:Hide()
    end
end

local function UpdateAuras(frame)
    if not config.showAuras then
        if frame.auras then frame.auras:Hide() end
        for i = 1, #frame.auraButtons do frame.auraButtons[i]:Hide() end
        return
    end
    local unit = frame:GetAttribute("unit")
    local btnIdx = 1

    local function ApplyAuraCooldown(btn, aura)
        local show = false
        local start, duration

        if aura and aura.duration and aura.expirationTime then
            local ok = pcall(function()
                if aura.duration > 0 then
                    duration = aura.duration
                    start = aura.expirationTime - aura.duration
                    show = true
                end
            end)
            if not ok then
                show = false
            end
        end

        if show then
            btn.cooldown:SetCooldown(start, duration)
            btn.cooldown:Show()
        else
            btn.cooldown:Hide()
        end
    end

    local function GetSafeDispelKeyFromAura(aura)
        if not aura then return "none" end
        local ok, dispelName = pcall(function() return aura.dispelName end)
        if not ok or type(dispelName) ~= "string" then
            return "none"
        end
        if dispelName == "Magic" or dispelName == "Curse" or dispelName == "Disease" or dispelName == "Poison" then
            return dispelName
        end
        return "none"
    end

    -- 1. Debuffs (Priority)
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HARMFUL")
        if not aura then break end
        if btnIdx > 6 then break end
        
        local btn = frame.auraButtons[btnIdx] or CreateAuraButton(frame.auras)
        frame.auraButtons[btnIdx] = btn
        btn:SetPoint("LEFT", (btnIdx-1)*(config.auraSize+config.auraSpacing), 0)
        
        btn.icon:SetTexture(aura.icon)
        ApplyAuraCooldown(btn, aura)
        local dispelKey = GetSafeDispelKeyFromAura(aura)
        local color = DEBUFF_COLORS[dispelKey] or DEBUFF_COLORS["none"]
        btn.border:SetBackdropBorderColor(color.r, color.g, color.b, 1)
        btn:Show(); btnIdx = btnIdx + 1
    end
    
    -- 2. Buffs (Fill remaining)
    for i = 1, 40 do
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, i, "HELPFUL")
        if not aura then break end
        if btnIdx > 6 then break end
        local btn = frame.auraButtons[btnIdx] or CreateAuraButton(frame.auras); frame.auraButtons[btnIdx] = btn; btn:SetPoint("LEFT", (btnIdx-1)*(config.auraSize+config.auraSpacing), 0)
        btn.icon:SetTexture(aura.icon); ApplyAuraCooldown(btn, aura)
        btn.border:SetBackdropBorderColor(0, 0, 0, 1); btn:Show(); btnIdx = btnIdx + 1
    end
    for i = btnIdx, #frame.auraButtons do frame.auraButtons[i]:Hide() end
end

function UpdatePartyUnit(frame)
    local unit = frame:GetAttribute("unit")
    if not unit then return end
    if _G.MidnightUI_Debug and not frame._muiUpdateDebugged then
        frame._muiUpdateDebugged = true
    end
    local allowSecret = AllowSecretHealthPercent()
    if lastAllowSecretState == nil or lastAllowSecretState ~= allowSecret then
        lastAllowSecretState = allowSecret
        if PartyDebugEnabled() then
        end
    end

    ApplyPartyConfigFromSettings()

    -- 1. Identity (Class Color)
    local _, class = UnitClass(unit)

    local c = DEFAULT_CLASS_COLOR
    if class and CLASS_COLOR_OVERRIDES[class] then
        c = CLASS_COLOR_OVERRIDES[class]
    elseif _G.MidnightUI_Core and _G.MidnightUI_Core.ClassColorsExact and class and _G.MidnightUI_Core.ClassColorsExact[class] then
        c = _G.MidnightUI_Core.ClassColorsExact[class]
    elseif class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        c = RAID_CLASS_COLORS[class]
    end

    local classR, classG, classB = c.r, c.g, c.b
    frame._muiClassColor = c
    local isSimple = (config.style == "Simple")
    local isSquare = (config.style == "Square")
    local hide2DPortrait = (config.hide2DPortrait == true) and (not isSquare)
    local isRendered = (not isSimple and not isSquare)
    if _G.MidnightUI_Debug and not frame._muiStyleDebugged then
        frame._muiStyleDebugged = true
    end
    if isRendered and PartyDebugEnabled() and _G.MidnightUI_Debug and not frame._muiRenderedStyleDebugged then
        frame._muiRenderedStyleDebugged = true
    end
    if isSquare then
        if frame.healthContainer then frame.healthContainer:Hide() end
        if frame.powerContainer then frame.powerContainer:Hide() end
        if frame.portrait then frame.portrait:Hide() end
        if frame.portraitBg then frame.portraitBg:Hide() end
        if frame.portraitSep then frame.portraitSep:Hide() end
        if frame.roleIcon then frame.roleIcon:Hide() end
        if frame.healthBar then ClearBarOverlays(frame.healthBar) end
        if frame.powerBar then ClearBarOverlays(frame.powerBar) end
        if frame._muiBackdropOrig then
            frame:SetBackdrop(nil)
        end
        frame:SetBackdropColor(0, 0, 0, 0)
        frame:SetBackdropBorderColor(0, 0, 0, 0)
        if frame.shadows then
            for _, s in ipairs(frame.shadows) do s:Hide() end
        end
        if frame.resIcon then frame.resIcon:Hide() end
        if frame.resGlow then frame.resGlow:Hide() end
        if frame.deadIcon then frame.deadIcon:Hide() end
        if frame.circle then
            local frameW = tonumber(frame:GetWidth()) or 0
            local frameH = tonumber(frame:GetHeight()) or 0
            local size = tonumber(config.diameter) or math.min(frameW, frameH)
            if size <= 1 then
                size = math.min(frameW, frameH)
            end
            if size <= 1 then
                size = math.min(tonumber(config.width) or 64, tonumber(config.height) or 64)
            end
            if frameW ~= size or frameH ~= size then
                frame:SetSize(size, size)
            end
            frame.circle:SetSize(size, size)
            frame.circle:ClearAllPoints()
            frame.circle:SetPoint("LEFT", frame, "LEFT", 0, 0)
            frame.circle:Show()
            if frame.circle.borderOuter then
                frame.circle.borderOuter:Hide()
            end
            if frame.circle.portrait then
                UpdatePortraitModel(frame.circle.portrait, unit)
            end
            if frame.circle.deadIcon then frame.circle.deadIcon:Hide() end
        end
        if frame.nameText then frame.nameText:SetText("") end
        if frame.healthText then frame.healthText:SetText("") end
        if frame.simpleTextFrame then frame.simpleTextFrame:Hide() end
        if frame.simpleNameText then frame.simpleNameText:SetText("") end
    elseif isSimple then
        if frame.roleIcon then frame.roleIcon:Hide() end
        if frame.leaderIcon then frame.leaderIcon:Hide() end
        if frame._muiBackdropOrig then
            frame:SetBackdrop(frame._muiBackdropOrig)
        end
        if frame.healthContainer then frame.healthContainer:Show() end
        if frame.powerContainer then frame.powerContainer:Show() end
        if frame.powerBg then frame.powerBg:Show() end
        if frame.powerBar then frame.powerBar:Show() end
        if frame.portrait then
            if hide2DPortrait then
                frame.portrait:Hide()
            else
                frame.portrait:Show()
                UpdatePortraitModel(frame.portrait, unit)
                if _G.MidnightUI_Debug and not frame._muiPortraitDebugged then
                    frame._muiPortraitDebugged = true
                end
            end
        end
        if frame.portraitBg then
            if hide2DPortrait then frame.portraitBg:Hide() else frame.portraitBg:Show() end
        end
        if frame.portraitSep then
            if hide2DPortrait then frame.portraitSep:Hide() else frame.portraitSep:Show() end
        end
        if frame.circle then frame.circle:Hide() end
        if frame.shadows then
            for _, s in ipairs(frame.shadows) do s:Hide() end
        end
        if frame.healthBg then frame.healthBg:Show() end
        if frame.healthBar then frame.healthBar:Show() end
        if frame.absorbBar then frame.absorbBar:Hide() end
        if frame.healthBar then ClearBarOverlays(frame.healthBar) end
        if frame.powerBar then ClearBarOverlays(frame.powerBar) end
        frame:SetBackdropColor(0.06, 0.06, 0.06, 0.5)
        frame:SetBackdropBorderColor(0, 0, 0, 0.8)
        if frame.nameText then frame.nameText:SetText("") end
        if frame.healthText then frame.healthText:SetText("") end
        if frame.simpleTextFrame then frame.simpleTextFrame:Show() end
        if frame.simpleNameText then
            frame.simpleNameText:SetTextColor(1, 1, 1, 1)
            frame.simpleNameText:SetText(UnitName(unit) or "")
        end
        local isConnectedSimple = UnitIsConnected(unit)
        local hasIncomingResSimple = UnitHasIncomingResurrection(unit)
        if frame.simpleHealthText then
            if not isConnectedSimple then
                frame.simpleHealthText:SetText("OFFLINE")
                frame.simpleHealthText:SetTextColor(0.6, 0.6, 0.6, 1)
            elseif IsUnitActuallyDead(unit) and not hasIncomingResSimple then
                frame.simpleHealthText:SetText("")
                frame.simpleHealthText:SetTextColor(1, 1, 1, 1)
            elseif not AllowSecretHealthPercent() then
                frame.simpleHealthText:SetText("")
                frame.simpleHealthText:SetTextColor(1, 1, 1, 1)
            else
                local _, pctText = GetDisplayHealthPercentWithText(unit)
                if pctText then
                    frame.simpleHealthText:SetText(pctText)
                else
                    frame.simpleHealthText:SetText("")
                end
                frame.simpleHealthText:SetTextColor(1, 1, 1, 1)
            end
        end
        if frame.deadIcon then
            local isDeadSimpleIcon = IsUnitActuallyDead(unit) and not hasIncomingResSimple and isConnectedSimple
            if isDeadSimpleIcon then
                frame.deadIcon:SetSize(32, 32)
                frame.deadIcon:ClearAllPoints()
                frame.deadIcon:SetPoint("RIGHT", frame.healthContainer, "RIGHT", -28, 0)
                ApplyDeadIconVisualStyle(frame.deadIcon)
                frame.deadIcon:Show()
            else
                frame.deadIcon:Hide()
            end
        end
        if frame.healthBar then
            frame.healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            local tex = frame.healthBar:GetStatusBarTexture()
            if tex then
                tex:SetHorizTile(false)
                tex:SetVertTile(false)
            end
            if not isConnectedSimple then
                frame.healthBar:SetStatusBarColor(0.1, 0.1, 0.1, 0.5)
            else
                frame.healthBar:SetStatusBarColor(classR, classG, classB, 0.9)
            end
            local hp, maxHp = GetPartyUnitHealthValues(unit)
            if not isConnectedSimple then
                frame.healthBar:SetMinMaxValues(0, 1)
                frame.healthBar:SetValue(0)
            elseif hp and maxHp and maxHp > 0 then
                frame.healthBar:SetMinMaxValues(0, maxHp)
                frame.healthBar:SetValue(hp)
            else
                frame.healthBar:SetMinMaxValues(0, 1)
                frame.healthBar:SetValue(1)
            end
        end
        -- Power (Simple mode)
        local isDeadSimple = IsUnitActuallyDead(unit)
        if frame.powerBar then
            if not isDeadSimple and isConnectedSimple then
                local pp = UnitPower(unit)
                local maxPp = UnitPowerMax(unit)
                local _, pToken = UnitPowerType(unit)
                local pColor = POWER_COLORS[pToken] or DEFAULT_POWER_COLOR
                frame.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
                local tex = frame.powerBar:GetStatusBarTexture()
                if tex then
                    tex:SetHorizTile(false)
                    tex:SetVertTile(false)
                end
                frame.powerBar:SetStatusBarColor(pColor[1], pColor[2], pColor[3], 1)
                frame.powerBar:SetMinMaxValues(0, maxPp)
                frame.powerBar:SetValue(pp)
            else
                frame.powerBar:SetStatusBarColor(0.2, 0.2, 0.2, 0.5)
                frame.powerBar:SetValue(0)
            end
        end
        UpdatePartyDebuffOverlay(frame, unit)
        return
    else
        if frame.simpleTextFrame then frame.simpleTextFrame:Hide() end
        if frame.simpleNameText then frame.simpleNameText:SetText("") end
        if frame.simpleHealthText then frame.simpleHealthText:SetText("") end
        if frame.roleIcon then
            if hide2DPortrait then frame.roleIcon:Hide() else frame.roleIcon:Show() end
        end
        if frame._muiBackdropOrig then
            frame:SetBackdrop(frame._muiBackdropOrig)
        end
        if frame.healthContainer then frame.healthContainer:Show() end
        if frame.powerContainer then frame.powerContainer:Show() end
        if frame.portrait then
            if hide2DPortrait then frame.portrait:Hide() else frame.portrait:Show() end
        end
        if frame.portraitBg then
            if hide2DPortrait then frame.portraitBg:Hide() else frame.portraitBg:Show() end
        end
        if frame.portraitSep then
            if hide2DPortrait then frame.portraitSep:Hide() else frame.portraitSep:Show() end
        end
        if frame.circle then frame.circle:Hide() end
        if frame.shadows then
            for _, s in ipairs(frame.shadows) do s:Show() end
        end
        if frame.healthBg then frame.healthBg:Show() end
        if frame.healthBar then frame.healthBar:Show() end
        if frame.absorbBar then frame.absorbBar:Show() end
        if frame.powerBg then frame.powerBg:Show() end
        if frame.powerBar then frame.powerBar:Show() end
        if frame.healthBar then
            frame.healthBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            local tex = frame.healthBar:GetStatusBarTexture()
            if tex then tex:SetHorizTile(false); tex:SetVertTile(false) end
        end
        if frame.powerBar then
            frame.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
            local tex = frame.powerBar:GetStatusBarTexture()
            if tex then tex:SetHorizTile(false); tex:SetVertTile(false) end
        end
        frame:SetBackdropColor(0.1, 0.1, 0.1, 0.9)
        frame:SetBackdropBorderColor(0, 0, 0, 1)
        if frame.nameText and frame.healthContainer then
            frame.nameText:ClearAllPoints()
            frame.nameText:SetPoint("LEFT", frame.healthContainer, "LEFT", 6, 1)
            frame.nameText:SetTextColor(1, 1, 1, 1)
        end
        if frame.healthText and frame.healthContainer then
            frame.healthText:ClearAllPoints()
            frame.healthText:SetPoint("RIGHT", frame.healthContainer, "RIGHT", -6, 1)
        end
    end
    if frame.circle and frame.circle.deadIcon and not isSquare then
        frame.circle.deadIcon:Hide()
    end
    
      -- Update Portrait
    if frame.portrait and not isSquare and (not hide2DPortrait) then
        UpdatePortraitModel(frame.portrait, unit)
          if _G.MidnightUI_Debug and not frame._muiPortraitDebugged then
              frame._muiPortraitDebugged = true
          end
      elseif _G.MidnightUI_Debug and frame.portrait and not frame._muiPortraitDebugged then
          frame._muiPortraitDebugged = true
    end

    -- 2. Check Death and Resurrection States
    local isDead = IsUnitActuallyDead(unit)
    local isConnected = UnitIsConnected(unit)
    local hasIncomingRes = UnitHasIncomingResurrection(unit) -- Works for both combat and out-of-combat res
    
    -- 3. Defaults (Healthy State)
    -- Background: Dark Class Color (Blends with bar)
    local bgR, bgG, bgB, bgAlpha = classR * 0.15, classG * 0.15, classB * 0.15, 0.6
    -- Text: Pure White (stays white unless dead)
    local textR, textG, textB = 1, 1, 1
    local debugState = "HEALTHY"
    local statusText = nil -- Will override health text if set
    local showResIcon = false
    local showDeadIcon = isConnected and isDead and not hasIncomingRes

    local hp, maxHp = GetPartyUnitHealthValues(unit)
    local hasSafeHp = (hp ~= nil and maxHp ~= nil and maxHp > 0)
    if not hasSafeHp and allowSecret then
        local okHp, vHp = pcall(UnitHealth, unit)
        local okMax, vMax = pcall(UnitHealthMax, unit)
        if okHp and okMax and type(vHp) == "number" and type(vMax) == "number" and vMax > 0
            and not IsSecretValue(vHp) and not IsSecretValue(vMax) then
            hp, maxHp = vHp, vMax
            hasSafeHp = true
        end
    end

    if isSquare and frame.circle then
        local displayPct, displayPctText
        if AllowSecretHealthPercent() then
            displayPct, displayPctText = GetDisplayHealthPercentWithText(unit)
        end

        if frame.circle.fill then
            local fillA = 0.5
            local r, g, b = classR, classG, classB
            if not isConnected then
                r, g, b = 0.14, 0.14, 0.14
                fillA = 0.72
            end
            frame.circle.fill:SetStatusBarColor(r, g, b, fillA)
            if PartyDebugEnabled() and not frame._muiCircleColorDebugged then
                frame._muiCircleColorDebugged = true
            end
            if PartyDebugEnabled() and not frame._muiCircleFillDebugged then
                frame._muiCircleFillDebugged = true
                local minV, maxV = frame.circle.fill:GetMinMaxValues()
                local val = frame.circle.fill:GetValue()
                local tex = frame.circle.fill:GetStatusBarTexture()
                if tex and tex.GetVertexColor then
                    local tr, tg, tb, ta = tex:GetVertexColor()
                end
            end
            local appliedCircleValue = false
            if not isConnected then
                appliedCircleValue = pcall(function()
                    frame.circle.fill:SetMinMaxValues(0, 1)
                    frame.circle.fill:SetValue(1)
                end)
            elseif displayPct ~= nil then
                appliedCircleValue = pcall(function()
                    frame.circle.fill:SetMinMaxValues(0, 100)
                    frame.circle.fill:SetValue(displayPct)
                end)
            end
            if not appliedCircleValue then
                if PartyDebugEnabled() and not frame._muiCircleNoValueLogged then
                    frame._muiCircleNoValueLogged = true
                end
                pcall(function()
                    frame.circle.fill:SetMinMaxValues(0, 100)
                    frame.circle.fill:SetValue(0)
                end)
            else
                frame._muiCircleNoValueLogged = nil
            end
        end
        if frame.circle.pctText then
            if not isConnected then
                frame.circle.pctText:SetText("OFFLINE")
                frame.circle.pctText:SetTextColor(0.85, 0.85, 0.85, 1)
                frame.circle.pctText:Show()
            elseif showDeadIcon then
                frame.circle.pctText:SetText("")
                frame.circle.pctText:SetTextColor(1, 1, 1, 1)
            elseif displayPctText then
                frame.circle.pctText:SetText(displayPctText)
                frame.circle.pctText:SetTextColor(1, 1, 1, 1)
                frame.circle.pctText:Show()
            else
                frame.circle.pctText:SetText("")
                frame.circle.pctText:SetTextColor(1, 1, 1, 1)
            end
            if PartyDebugEnabled() and _G.MidnightUI_Debug then
                local ptText = frame.circle.pctText:GetText()
                local shown = frame.circle.pctText:IsShown()
                local alpha = frame.circle.pctText:GetAlpha()
                local p1, rel, p2, x, y = frame.circle.pctText:GetPoint(1)
            end
        end
        if frame.circle.deadIcon then
            if showDeadIcon and isConnected and not hasIncomingRes then
                frame.circle.deadIcon:SetSize(12, 12)
                frame.circle.deadIcon:ClearAllPoints()
                frame.circle.deadIcon:SetPoint("CENTER", frame.circle.pctText, "CENTER", 0, 0)
                ApplyDeadIconVisualStyle(frame.circle.deadIcon)
                frame.circle.deadIcon:Show()
            else
                frame.circle.deadIcon:Hide()
            end
        end

        if frame.circle.roleIcon then
            local iconSize = math.max(12, math.floor((frame.circle:GetWidth() or 0) * 0.32 + 0.5))
            frame.circle.roleIcon:SetSize(iconSize, iconSize)
            frame.circle.roleIcon:ClearAllPoints()
            frame.circle.roleIcon:SetPoint("BOTTOMRIGHT", frame.circle, "BOTTOMRIGHT", -2, 2)
            frame.circle.roleIcon:SetVertexColor(1, 1, 1, 1)
            frame.circle.roleIcon:SetAlpha(1)
            frame.circle.roleIcon:SetDrawLayer("OVERLAY", 7)
            local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit) or nil
            if (frame.circle:GetWidth() or 0) < 35 then
                frame.circle.roleIcon:Hide()
            elseif role == "HEALER" then
                frame.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-Healer")
                frame.circle.roleIcon:Show()
            elseif role == "TANK" then
                  frame.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-Tank")
                  frame.circle.roleIcon:Show()
              elseif role == "DAMAGER" then
                  frame.circle.roleIcon:SetAtlas("UI-LFG-RoleIcon-DPS")
                  frame.circle.roleIcon:Show()
              else
                  frame.circle.roleIcon:Hide()
              end
        end
    end
    

    if not isConnected then
        statusText = "OFFLINE"
        textR, textG, textB = 0.5, 0.5, 0.5
        bgR, bgG, bgB, bgAlpha = 0.1, 0.1, 0.1, 0.8
        frame.healthBar:SetStatusBarColor(0.2, 0.2, 0.2, 0.5)
    else
    -- 4. Handle Resurrection State (Higher priority than death)
    if hasIncomingRes then
        -- RESURRECTION PENDING: Hopeful, radiant aesthetic
        -- Background: Warm golden glow
        bgR, bgG, bgB, bgAlpha = 0.3, 0.25, 0.05, 0.6
        -- Text: Bright yellow-gold
        textR, textG, textB = 1.0, 0.95, 0.5
        showResIcon = true
        debugState = "RESURRECTION PENDING"
        
    -- 5. Handle Death State (if not being resurrected)
    elseif isDead then
        -- DEATH: Dramatic but tasteful
        -- Background: Very dark, nearly black with hint of red
        bgR, bgG, bgB, bgAlpha = 0.1, 0.0, 0.0, 0.9
        -- Text: Red to signal death
        textR, textG, textB = 1.0, 0.2, 0.2
        statusText = nil
        showDeadIcon = true
        debugState = "DEAD"
        
    end
    end

    -- 7. Apply Visuals
    
    -- Bar: Rendered gradient class color
    local hbR, hbG, hbB, hbA = classR, classG, classB, 0.92
    local hbTopA, hbBotA = 0.20, 0.34
    if hasIncomingRes then
        hbR, hbG, hbB, hbA = classR * 1.2, classG * 1.2, classB * 1.2, 0.95
        hbTopA, hbBotA = 0.24, 0.36
    elseif isDead or not isConnected then
        hbR, hbG, hbB, hbA = classR * 0.25, classG * 0.25, classB * 0.25, 0.7
        hbTopA, hbBotA = 0.12, 0.24
    end
    if not isConnected then
        hbR, hbG, hbB, hbA = 0.1, 0.1, 0.1, 0.5
        hbTopA, hbBotA = 0.08, 0.18
    end
    if isRendered then
        ApplyRenderedBarStyle(frame.healthBar, hbR, hbG, hbB, hbA, hbTopA, hbBotA)
        DebugRenderedBar(frame.healthBar, "HealthBar")
    else
        ApplyStatusBarGradient(frame.healthBar, hbR, hbG, hbB, hbA, hbTopA, hbBotA)
    end
    
    -- Background: Subtle atmospheric tint with variable alpha
    frame.healthBg:SetColorTexture(bgR, bgG, bgB, bgAlpha)
    
    -- Resurrection Icon: Show/Hide with glow effect
    if frame.resIcon then
        if showResIcon then
            frame.resIcon:Show()
            if frame.resGlow then
                frame.resGlow:Show()
                -- Strong pulsing glow animation
                frame.resGlow:SetAlpha(0.6)
            end
        else
            frame.resIcon:Hide()
            if frame.resGlow then frame.resGlow:Hide() end
        end
    end
    if frame.deadIcon then
        if showDeadIcon and not isSquare then
            frame.deadIcon:SetSize(32, 32)
            frame.deadIcon:ClearAllPoints()
            frame.deadIcon:SetPoint("RIGHT", frame.healthContainer, "RIGHT", -28, 0)
            ApplyDeadIconVisualStyle(frame.deadIcon)
            frame.deadIcon:Show()
        else
            frame.deadIcon:Hide()
        end
    end
    
    -- Text: Updates based on state
    frame.nameText:SetText(UnitName(unit)) 
    frame.nameText:SetTextColor(textR, textG, textB)

    -- 8. Set Values (Protected)
    if hasSafeHp then
        pcall(function()
            frame.healthBar:SetMinMaxValues(0, maxHp)
            if hasIncomingRes then
                -- Show current HP even when being resurrected
                frame.healthBar:SetValue(hp)
            else
                frame.healthBar:SetValue(isDead and 0 or hp)
            end
        end)
    else
        local pctValue = GetDisplayHealthPercent(unit)
        if type(pctValue) == "number" then
            pcall(function()
                frame.healthBar:SetMinMaxValues(0, 100)
                frame.healthBar:SetValue(pctValue)
            end)
        else
            pcall(function()
                frame.healthBar:SetMinMaxValues(0, 1)
                frame.healthBar:SetValue(0)
            end)
        end
    end
    
    -- Absorb Bar Update
    local absorbs = SafeUnitValue(UnitGetTotalAbsorbs, unit) or 0
    if hasSafeHp then
        frame.absorbBar:SetMinMaxValues(0, maxHp)
        frame.absorbBar:SetValue(absorbs)
    else
        frame.absorbBar:SetMinMaxValues(0, 1)
        frame.absorbBar:SetValue(0)
    end

    local allowSecret = AllowSecretHealthPercent()
    -- Health Text: Hide when resurrection icon is showing, otherwise show status or HP
    local textSuccess, textString
    if showResIcon then
        -- Hide health text when showing resurrection icon
        textString = ""
    elseif showDeadIcon then
        textString = ""
    elseif statusText then
        textString = statusText
    elseif not allowSecret then
        textString = ""
    elseif not hasSafeHp and not isSquare then
        textString = ""
    elseif isSquare then
        local _, displayPctText = GetDisplayHealthPercentWithText(unit)
        textString = displayPctText or ""
    else
        local _, pctText = GetDisplayHealthPercentWithText(unit)
        textString = pctText or ""
    end
    
    frame.healthText:SetText(textString)
    frame.healthText:SetTextColor(textR, textG, textB)

    -- 9. Power (skip if dead, desaturate if being resurrected)
    if not isDead then
        local pp = UnitPower(unit)
        local maxPp = UnitPowerMax(unit)
        local _, pToken = UnitPowerType(unit)
        local pColor = POWER_COLORS[pToken] or DEFAULT_POWER_COLOR

        frame.powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        local tex = frame.powerBar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
        end
        
        local skipPowerUpdate = false
        if not isConnected and isRendered then
            ApplyRenderedBarStyle(frame.powerBar, 0.2, 0.2, 0.2, 0.5, 0.12, 0.22)
            frame.powerBar:SetMinMaxValues(0, 1)
            frame.powerBar:SetValue(0)
            skipPowerUpdate = true
        end
         
        if not skipPowerUpdate and hasIncomingRes then
            if isRendered then
                ApplyRenderedBarStyle(frame.powerBar, pColor[1] * 1.15, pColor[2] * 1.15, pColor[3] * 1.15, 0.85, 0.22, 0.34)
            else
                ApplyStatusBarGradient(frame.powerBar, pColor[1] * 1.15, pColor[2] * 1.15, pColor[3] * 1.15, 0.85, 0.20, 0.32)
            end
        elseif not skipPowerUpdate then
            if isRendered then
                ApplyRenderedBarStyle(frame.powerBar, pColor[1], pColor[2], pColor[3], 1, 0.20, 0.32)
            else
                ApplyStatusBarGradient(frame.powerBar, pColor[1], pColor[2], pColor[3], 1, 0.16, 0.30)
            end
        end
        if isRendered then DebugRenderedBar(frame.powerBar, "PowerBar") end
        if not skipPowerUpdate then
            frame.powerBar:SetMinMaxValues(0, maxPp)
            frame.powerBar:SetValue(pp)
        end
    elseif isDead then
        -- Desaturate power bar when dead
        if isRendered then
            ApplyRenderedBarStyle(frame.powerBar, 0.2, 0.2, 0.2, 0.5, 0.12, 0.22)
        else
            ApplyStatusBarGradient(frame.powerBar, 0.2, 0.2, 0.2, 0.5, 0.10, 0.22)
        end
        frame.powerBar:SetValue(0)
    end

    -- 10. Role & Leader Icons
    local role = UnitGroupRolesAssigned(unit)
    if isSquare or hide2DPortrait then
        frame.roleIcon:Hide()
    elseif role == "TANK" then
        frame.roleIcon:SetTexture("Interface\\AddOns\\MidnightUI\\Media\\TankIcon") -- Fallback if custom media missing
        if not frame.roleIcon:GetTexture() then frame.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"); frame.roleIcon:SetTexCoord(0, 19/64, 22/64, 41/64) end
        frame.roleIcon:SetVertexColor(1, 1, 1, 1)
        frame.roleIcon:SetAlpha(1)
        frame.roleIcon:Show()
    elseif role == "HEALER" then
        frame.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"); frame.roleIcon:SetTexCoord(20/64, 39/64, 1/64, 20/64)
        frame.roleIcon:SetVertexColor(1, 1, 1, 1)
        frame.roleIcon:SetAlpha(1)
        frame.roleIcon:Show()
    elseif role == "DAMAGER" then
        frame.roleIcon:SetTexture("Interface\\LFGFrame\\UI-LFG-ICON-PORTRAITROLES"); frame.roleIcon:SetTexCoord(20/64, 39/64, 22/64, 41/64)
        frame.roleIcon:SetVertexColor(1, 1, 1, 1)
        frame.roleIcon:SetAlpha(1)
        frame.roleIcon:Show()
    else
        frame.roleIcon:Hide()
    end

    if hide2DPortrait then
        frame.leaderIcon:Hide()
    elseif UnitIsGroupLeader(unit) then
        frame.leaderIcon:SetTexture("Interface\\GroupFrame\\UI-Group-LeaderIcon")
        frame.leaderIcon:Show()
    else
        frame.leaderIcon:Hide()
    end

    UpdateAuras(frame)
    UpdateReadyCheck(frame)
    UpdateTargetGlow(frame)
    UpdatePhaseStatus(frame)
    UpdatePartyDebuffOverlay(frame, unit)
end

-- Batch flush: process all dirty party units once per rendered frame
_partyBatchFrame:SetScript("OnUpdate", function(self)
    if _partyDirtyAll then
        _partyDirtyAll = false
        for i = 1, 4 do
            local f = PartyFrames[i]
            if f and f:IsShown() then UpdatePartyUnit(f) end
        end
    else
        for i in pairs(_partyDirtyUnits) do
            local f = PartyFrames[i]
            if f and f:IsShown() then UpdatePartyUnit(f) end
        end
    end
    wipe(_partyDirtyUnits)
    self:Hide()
end)

local function EnsurePartyTestDebugSettings()
    if not MidnightUISettings then
        MidnightUISettings = {}
    end
    if not MidnightUISettings.PartyFrames then
        MidnightUISettings.PartyFrames = {}
    end
    if not MidnightUISettings.PlayerFrame then
        MidnightUISettings.PlayerFrame = {}
    end
    if PartyTestState.prevPartyDebug == nil then
        PartyTestState.prevPartyDebug = MidnightUISettings.PartyFrames.debug
    end
    if PartyTestState.prevCondDebug == nil then
        PartyTestState.prevCondDebug = MidnightUISettings.PlayerFrame.condBorderDebug
    end
    MidnightUISettings.PartyFrames.debug = true
    if MidnightUISettings.PartyFrames.debugVerbose == true then
        MidnightUISettings.PlayerFrame.condBorderDebug = true
    end
end

local function RestorePartyTestDebugSettings()
    if MidnightUISettings and MidnightUISettings.PartyFrames and PartyTestState.prevPartyDebug ~= nil then
        MidnightUISettings.PartyFrames.debug = PartyTestState.prevPartyDebug
    end
    if MidnightUISettings and MidnightUISettings.PlayerFrame and PartyTestState.prevCondDebug ~= nil then
        MidnightUISettings.PlayerFrame.condBorderDebug = PartyTestState.prevCondDebug
    end
    PartyTestState.prevPartyDebug = nil
    PartyTestState.prevCondDebug = nil
end

local function EnsurePartyTestOverlay(frame)
    if not frame then
        return
    end
    if not frame.dispelGlow then
        local dispelGlow = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        dispelGlow:SetPoint("TOPLEFT", -2, 2)
        dispelGlow:SetPoint("BOTTOMRIGHT", 2, -2)
        dispelGlow:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 2,
        })
        dispelGlow:SetBackdropBorderColor(0, 0, 0, 0)
        dispelGlow:SetFrameLevel(frame:GetFrameLevel() + 20)
        dispelGlow:EnableMouse(false)
        dispelGlow:Hide()
        frame.dispelGlow = dispelGlow
    end
    if not frame.dispelGlowSecondary then
        local secondary = CreateFrame("Frame", nil, frame, "BackdropTemplate")
        secondary:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        secondary:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        secondary:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        secondary:SetBackdropBorderColor(0, 0, 0, 0)
        secondary:SetFrameLevel(frame:GetFrameLevel() + 21)
        secondary:EnableMouse(false)
        secondary:Hide()
        frame.dispelGlowSecondary = secondary
    end
    if not frame.dispelGlowFill then
        local fill = frame:CreateTexture(nil, "OVERLAY", nil, 7)
        fill:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
        fill:SetTexture("Interface\\Buttons\\WHITE8X8")
        fill:SetBlendMode("ADD")
        fill:SetVertexColor(0, 0, 0, 0)
        fill:Hide()
        frame.dispelGlowFill = fill
    end
end

local function HidePartyTestOverlay(frame)
    if not frame then
        return
    end
    if frame.dispelGlow then
        frame.dispelGlow:SetBackdropBorderColor(0, 0, 0, 0)
        frame.dispelGlow:Hide()
    end
    if frame.dispelGlowSecondary then
        frame.dispelGlowSecondary:SetBackdropBorderColor(0, 0, 0, 0)
        frame.dispelGlowSecondary:Hide()
    end
    if frame.dispelGlowFill then
        frame.dispelGlowFill:SetVertexColor(0, 0, 0, 0)
        frame.dispelGlowFill:Hide()
    end
end

local function PrepareForcedPreviewFrame(frame, index, preferPartyUnit)
    if not frame then
        return
    end
    EnsurePartyTestOverlay(frame)

    if frame.SetAttribute then
        if not frame._muiPartyTestOriginalUnit then
            frame._muiPartyTestOriginalUnit = frame:GetAttribute("unit")
        end
        local targetUnit = "player"
        if preferPartyUnit == true then
            local partyToken = "party" .. tostring(index)
            if UnitExists and UnitExists(partyToken) then
                targetUnit = partyToken
            end
        end
        pcall(frame.SetAttribute, frame, "unit", targetUnit)
    end

    if type(UnregisterUnitWatch) == "function" and frame._muiPartyTestUnitWatchDisabled ~= true then
        local ok = pcall(UnregisterUnitWatch, frame)
        if ok then
            frame._muiPartyTestUnitWatchDisabled = true
        end
    end
    frame:Show()
    frame:SetAlpha(1)
end

local function SetPartyTestRoleIcon(icon, role)
    if not icon then
        return
    end
    if role == "TANK" then
        icon:SetAtlas("UI-LFG-RoleIcon-Tank")
        icon:Show()
    elseif role == "HEALER" then
        icon:SetAtlas("UI-LFG-RoleIcon-Healer")
        icon:Show()
    elseif role == "DAMAGER" then
        icon:SetAtlas("UI-LFG-RoleIcon-DPS")
        icon:Show()
    else
        icon:Hide()
    end
    icon:SetVertexColor(1, 1, 1, 1)
    icon:SetAlpha(1)
end

local function EnsurePartyTestAnchorOnScreen()
    if not PartyAnchor then
        return
    end
    local left, right = PartyAnchor:GetLeft(), PartyAnchor:GetRight()
    local top, bottom = PartyAnchor:GetTop(), PartyAnchor:GetBottom()
    local screenW = GetScreenWidth and GetScreenWidth() or nil
    local screenH = GetScreenHeight and GetScreenHeight() or nil

    local offScreen = false
    if not left or not right or not top or not bottom then
        offScreen = true
    elseif screenW and screenH then
        if right < 0 or left > screenW or top < 0 or bottom > screenH then
            offScreen = true
        end
    end

    if offScreen then
        PartyAnchor:ClearAllPoints()
        PartyAnchor:SetPoint("CENTER", UIParent, "CENTER", -420, -60)
    end
end

local function GetPartyTestMember(index)
    local size = #PARTY_TEST_MEMBERS
    if size < 1 then
        return PARTY_TEST_MEMBERS[1]
    end
    return PARTY_TEST_MEMBERS[((index - 1) % size) + 1]
end

local function GetPartyTestDebuffPair(index, now)
    local count = #PARTY_TEST_DEBUFF_TYPES
    if count < 2 then
        local fallback = PARTY_TEST_DEBUFF_TYPES[1]
        return fallback, fallback
    end
    local step = math.floor((now or 0) * 0.8)
    local primaryIndex = ((step + index - 1) % count) + 1
    local secondaryIndex = ((primaryIndex + index) % count) + 1
    if secondaryIndex == primaryIndex then
        secondaryIndex = (secondaryIndex % count) + 1
    end
    return PARTY_TEST_DEBUFF_TYPES[primaryIndex], PARTY_TEST_DEBUFF_TYPES[secondaryIndex]
end

local function ApplyPartyTestFrameMotion(frame, index, now)
    if not frame then
        return
    end
    local member = GetPartyTestMember(index)
    if not member then
        return
    end

    local isSquare = (config.style == "Square")
    local classColor = CLASS_COLOR_OVERRIDES[member.class] or DEFAULT_CLASS_COLOR
    local classR, classG, classB = classColor.r, classColor.g, classColor.b

    local healthPct = math.floor(55 + (math.sin((now * 1.35) + index) * 40) + 0.5)
    if healthPct < 5 then
        healthPct = 5
    elseif healthPct > 100 then
        healthPct = 100
    end
    local powerPct = math.floor(50 + (math.sin((now * 1.85) + (index * 0.8)) * 45) + 0.5)
    if powerPct < 0 then
        powerPct = 0
    elseif powerPct > 100 then
        powerPct = 100
    end

    local primaryDebuff, secondaryDebuff = GetPartyTestDebuffPair(index, now)
    local pulseAlpha = 0.10 + ((math.sin((now * 3.5) + (index * 0.9)) + 1) * 0.08)

    frame:Show()
    frame:SetAlpha(1)
    if frame.healthContainer then frame.healthContainer:Show() end
    if frame.powerContainer then frame.powerContainer:Show() end
    if frame.healthBg then frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.9) end
    if frame.powerBg then frame.powerBg:SetColorTexture(0, 0, 0, 0.5) end
    if frame.resIcon then frame.resIcon:Hide() end
    if frame.resGlow then frame.resGlow:Hide() end
    if frame.deadIcon then frame.deadIcon:Hide() end

    if frame.nameText then
        frame.nameText:SetText(member.name)
        frame.nameText:SetTextColor(1, 1, 1, 1)
    end
    if frame.healthText then
        frame.healthText:SetText(healthPct .. "%")
        frame.healthText:SetTextColor(1, 1, 1, 1)
    end
    if frame.simpleNameText then
        frame.simpleNameText:SetText(member.name)
        frame.simpleNameText:SetTextColor(1, 1, 1, 1)
    end
    if frame.simpleHealthText then
        frame.simpleHealthText:SetText(healthPct .. "%")
        frame.simpleHealthText:SetTextColor(1, 1, 1, 1)
    end

    if frame.portrait then
        frame.portrait:SetTexture("Interface\\ICONS\\INV_Misc_QuestionMark")
        if frame.portrait.SetTexCoord then
            frame.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        end
    end

    SetPartyTestRoleIcon(frame.roleIcon, member.role)

    if isSquare and frame.circle then
        frame.circle:Show()
        if frame.circle.fill then
            frame.circle.fill:SetMinMaxValues(0, 100)
            frame.circle.fill:SetValue(healthPct)
            frame.circle.fill:SetStatusBarColor(classR, classG, classB, 0.62)
        end
        if frame.circle.portrait then
            frame.circle.portrait:SetTexture("Interface\\ICONS\\INV_Misc_QuestionMark")
            if frame.circle.portrait.SetTexCoord then
                frame.circle.portrait:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            end
        end
        if frame.circle.pctText then
            frame.circle.pctText:SetText(healthPct .. "%")
            frame.circle.pctText:SetTextColor(1, 1, 1, 1)
            frame.circle.pctText:Show()
        end
        SetPartyTestRoleIcon(frame.circle.roleIcon, member.role)
    else
        if frame.circle then frame.circle:Hide() end
        if frame.healthBar then
            if (config.style == "Rendered") then
                ApplyRenderedBarStyle(frame.healthBar, classR, classG, classB, 0.92, 0.20, 0.34)
            else
                ApplyStatusBarGradient(frame.healthBar, classR, classG, classB, 0.92, 0.20, 0.34)
            end
            frame.healthBar:SetMinMaxValues(0, 100)
            frame.healthBar:SetValue(healthPct)
        end
        if frame.powerBar then
            local powerColor = POWER_COLORS[member.power] or DEFAULT_POWER_COLOR
            if (config.style == "Rendered") then
                ApplyRenderedBarStyle(frame.powerBar, powerColor[1], powerColor[2], powerColor[3], 1, 0.20, 0.32)
            else
                ApplyStatusBarGradient(frame.powerBar, powerColor[1], powerColor[2], powerColor[3], 1, 0.16, 0.30)
            end
            frame.powerBar:SetMinMaxValues(0, 100)
            frame.powerBar:SetValue(powerPct)
        end
    end

    EnsurePartyTestOverlay(frame)
    if frame.dispelGlow then
        frame.dispelGlow:SetBackdropBorderColor(primaryDebuff.r, primaryDebuff.g, primaryDebuff.b, 1.0)
        frame.dispelGlow:Show()
    end
    if frame.dispelGlowSecondary then
        frame.dispelGlowSecondary:SetBackdropBorderColor(secondaryDebuff.r, secondaryDebuff.g, secondaryDebuff.b, 0.95)
        frame.dispelGlowSecondary:Show()
    end
    if frame.dispelGlowFill then
        frame.dispelGlowFill:SetVertexColor(secondaryDebuff.r, secondaryDebuff.g, secondaryDebuff.b, pulseAlpha)
        frame.dispelGlowFill:Show()
    end

    frame._muiPartyTestHealth = healthPct
    frame._muiPartyTestPower = powerPct
    frame._muiPartyTestPrimary = primaryDebuff.label
    frame._muiPartyTestSecondary = secondaryDebuff.label
end

local function RestorePartyTestFrames(reason)
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            if frame._muiPartyTestOriginalUnit and frame.SetAttribute then
                local okSet, errSet = pcall(frame.SetAttribute, frame, "unit", frame._muiPartyTestOriginalUnit)
                if not okSet then
                end
            end
            frame._muiPartyTestOriginalUnit = nil
            HidePartyTestOverlay(frame)
            if frame._muiPartyTestUnitWatchDisabled and type(RegisterUnitWatch) == "function" then
                pcall(RegisterUnitWatch, frame)
            end
            frame._muiPartyTestUnitWatchDisabled = nil
            frame._muiPartyTestHealth = nil
            frame._muiPartyTestPower = nil
            frame._muiPartyTestPrimary = nil
            frame._muiPartyTestSecondary = nil
        end
    end
    PartyTestState.pendingRestore = false
    PartyTestState.mode = nil
    PartyTestState.pendingMode = nil
    RestorePartyTestDebugSettings()
    UpdatePartyVisibility()
    if _G.MidnightUI_RefreshPartyFrames then
        _G.MidnightUI_RefreshPartyFrames()
    end
end

local function TickPartyTestFrames()
    if not PartyTestState.active then
        return
    end
    local now = (GetTime and GetTime()) or 0
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            ApplyPartyTestFrameMotion(frame, i, now)
        end
    end
end

local function TickPartyLivePreviewFrames()
    if not PartyTestState.active or PartyTestState.mode ~= "live" then
        return
    end

    local now = (GetTime and GetTime()) or 0
    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame and frame:IsShown() then
            pcall(UpdatePartyUnit, frame)
        end
    end
end

local function StartPartyDebuffOverlayTest()
    if PartyTestState.active then
        PartyTestChat("Party overlay test is already running.")
        return true
    end
    if InCombatLockdown and InCombatLockdown() then
        PartyTestState.pendingStart = true
        PartyTestState.pendingMode = "synthetic"
        PartyTestChat("Cannot start party overlay test in combat. Start queued for after combat.")
        return false
    end

    InitPartyFrames()
    LayoutPartyFrames()
    if PartyAnchor then
        PartyAnchor:Show()
    end
    EnsurePartyTestAnchorOnScreen()
    EnsurePartyTestDebugSettings()

    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            PrepareForcedPreviewFrame(frame, i, false)
        end
    end

    PartyTestState.active = true
    PartyTestState.pendingStart = false
    PartyTestState.pendingMode = nil
    PartyTestState.pendingRestore = false
    PartyTestState.mode = "synthetic"
    PartyTestState.lastDiagAt = 0
    PartyTestState.lastLiveTickKey = nil

    if PartyTestState.ticker then
        PartyTestState.ticker:Cancel()
        PartyTestState.ticker = nil
    end

    pcall(TickPartyTestFrames)
    if C_Timer and C_Timer.NewTicker then
        PartyTestState.ticker = C_Timer.NewTicker(PARTY_TEST_TICK_RATE, function()
            pcall(TickPartyTestFrames)
        end)
    end

    PartyTestChat("Party overlay test started.")
    return true
end

local function StartPartyDebuffOverlayLivePreview()
    if PartyTestState.active and PartyTestState.mode == "live" then
        PartyTestChat("Party debuff live preview is already active.")
        return true
    end

    if PartyTestState.active and PartyTestState.mode == "synthetic" then
        StopPartyDebuffOverlayTest("switch-to-live")
    end

    if InCombatLockdown and InCombatLockdown() then
        PartyTestState.pendingStart = true
        PartyTestState.pendingMode = "live"
        PartyTestChat("Cannot start live preview in combat. Start queued for after combat.")
        return false
    end

    InitPartyFrames()
    LayoutPartyFrames()
    if PartyAnchor then
        PartyAnchor:Show()
    end
    EnsurePartyTestAnchorOnScreen()
    EnsurePartyTestDebugSettings()

    for i = 1, 4 do
        local frame = PartyFrames[i]
        if frame then
            PrepareForcedPreviewFrame(frame, i, true)
            UpdatePartyUnit(frame)
        end
    end

    PartyTestState.active = true
    PartyTestState.pendingStart = false
    PartyTestState.pendingMode = nil
    PartyTestState.pendingRestore = false
    PartyTestState.mode = "live"
    PartyTestState.lastDiagAt = 0
    PartyTestState.lastLiveTickKey = nil

    if PartyTestState.ticker then
        PartyTestState.ticker:Cancel()
        PartyTestState.ticker = nil
    end

    pcall(TickPartyLivePreviewFrames)
    if C_Timer and C_Timer.NewTicker then
        PartyTestState.ticker = C_Timer.NewTicker(PARTY_TEST_LIVE_TICK_RATE, function()
            pcall(TickPartyLivePreviewFrames)
        end)
    end

    PartyTestChat("Party debuff live preview started.")
    return true
end

StopPartyDebuffOverlayTest = function(reason)
    if not PartyTestState.active and not PartyTestState.pendingStart and not PartyTestState.pendingRestore then
        PartyTestChat("Party overlay test is not running.")
        return false
    end

    PartyTestState.pendingStart = false
    PartyTestState.pendingMode = nil
    PartyTestState.active = false
    PartyTestState.lastLiveTickKey = nil

    if PartyTestState.ticker then
        PartyTestState.ticker:Cancel()
        PartyTestState.ticker = nil
    end

    if InCombatLockdown and InCombatLockdown() then
        PartyTestState.pendingRestore = true
        PartyTestChat("Stop queued until combat ends.")
        return true
    end

    RestorePartyTestFrames(reason or "manual")
    PartyTestChat("Party overlay test stopped.")
    return true
end

-- =========================================================================
--  INIT & EVENTS
-- =========================================================================

local function HideBlizzardFrames()
    if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.useDefaultFrames then
        return
    end
    local function SuppressFrame(frame)
        if not frame or frame.MidnightUISuppressed then return end
        frame.MidnightUISuppressed = true
        if frame.SetAlpha then frame:SetAlpha(0) end
        if frame.SetScale then frame:SetScale(0.001) end
        if frame.EnableMouse then frame:EnableMouse(false) end
    end

    if _G.PartyFrame then
        SuppressFrame(_G.PartyFrame)
        for i = 1, 5 do
            local member = _G.PartyFrame["MemberFrame"..i]
            SuppressFrame(member)
        end
    end
    for i = 1, 4 do
        local f = _G["PartyMemberFrame"..i]
        SuppressFrame(f)
    end
    if _G.CompactPartyFrame then
        SuppressFrame(_G.CompactPartyFrame)
    end
end

function MidnightUI_RefreshPartyFrames()
    for i = 1, 4 do
        local f = PartyFrames[i]
        if f and f:IsShown() then
            UpdatePartyUnit(f)
        end
    end
end

_G.MidnightUI_RefreshPartyDispelTrackingOverlay = function(forceHide)
    if RefreshPartyDispelTrackingOverlays then
        RefreshPartyDispelTrackingOverlays(forceHide == true)
    end
end

_G.MidnightUI_SetPartyDispelTrackingLocked = function(locked)
    SetPartyDispelTrackingLocked(locked)
end

InitPartyFrames = function()
    if MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.useDefaultFrames then
        -- Hide any existing custom frames when using default Blizzard frames
        for i = 1, 4 do
            if PartyFrames[i] then PartyFrames[i]:Hide() end
        end
        if PartyAnchor then PartyAnchor:Hide() end
        return
    end
    EnsurePartyCombatSettingsTable()
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
        PartyDispelTrackingState.locked = (MidnightUISettings.Messenger.locked ~= false)
    end
    EnsurePartyBlizzAuraHook()
    HideBlizzardFrames()
    if PartyFrames[1] then return end
    -- Defer frame creation until player is actually in a group (saves ~500 KB when solo)
    if not IsInGroup() then return end
    EnsurePartyAnchor()
    for i = 1, 4 do
        PartyFrames[i] = CreateSinglePartyFrame(i)
    end
    LayoutPartyFrames()
    UpdatePartyVisibility()
    EnsurePartyRangeTicker()
    for i = 1, 4 do
        local f = PartyFrames[i]
        if f and f.dispelGlow then
            f.dispelGlow:Hide()
        end
    end
    if RefreshPartyDispelTrackingOverlays then
        RefreshPartyDispelTrackingOverlays(false)
    end
end

-- =========================================================================
--  PARTY DISPEL GLOW UPDATE
-- =========================================================================

PartyFrameManager:RegisterEvent("ADDON_LOADED")
PartyFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
PartyFrameManager:RegisterEvent("GROUP_ROSTER_UPDATE")
PartyFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")
PartyFrameManager:RegisterEvent("UNIT_HEALTH")
PartyFrameManager:RegisterEvent("UNIT_POWER_UPDATE")
PartyFrameManager:RegisterEvent("UNIT_MAXHEALTH")
PartyFrameManager:RegisterEvent("UNIT_MODEL_CHANGED")
PartyFrameManager:RegisterEvent("UNIT_AURA")
PartyFrameManager:RegisterEvent("PLAYER_TARGET_CHANGED")
PartyFrameManager:RegisterEvent("READY_CHECK")
PartyFrameManager:RegisterEvent("READY_CHECK_CONFIRM")
PartyFrameManager:RegisterEvent("READY_CHECK_FINISHED")
PartyFrameManager:RegisterEvent("UNIT_PHASE")
PartyFrameManager:RegisterEvent("UNIT_ABSORB_AMOUNT_CHANGED")

PartyFrameManager:SetScript("OnEvent", function(self, event, ...)
    local arg1, arg2 = ...
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        InitPartyFrames()
    elseif event == "PLAYER_ENTERING_WORLD" then
        InitPartyFrames()
        ResetPartyBlizzAuraCache()
        PrimePartyBlizzAuraCache()
        UpdatePartyVisibility()
        for i = 1, 4 do if PartyFrames[i] then UpdatePartyUnit(PartyFrames[i]) end end
    elseif event == "GROUP_ROSTER_UPDATE" then
        InitPartyFrames()
        ResetPartyBlizzAuraCache()
        PrimePartyBlizzAuraCache()
        UpdatePartyVisibility()
        for i = 1, 4 do if PartyFrames[i] then UpdatePartyUnit(PartyFrames[i]) end end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if PartyTestState.pendingStart then
            if PartyTestState.pendingMode == "live" then
                StartPartyDebuffOverlayLivePreview()
            else
                StartPartyDebuffOverlayTest()
            end
        elseif PartyTestState.pendingRestore then
            RestorePartyTestFrames("PLAYER_REGEN_ENABLED")
            PartyTestChat("Party overlay test stopped.")
        end
        if pendingPartyLayout then
            LayoutPartyFrames()
        end
        if pendingPartyVisibility then
            UpdatePartyVisibility()
        end
    elseif event == "PLAYER_TARGET_CHANGED" or event == "READY_CHECK" or event == "READY_CHECK_FINISHED" then
        _partyDirtyAll = true
        _partyBatchFrame:Show()
    elseif event == "UNIT_HEALTH" or event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXHEALTH" or event == "UNIT_MODEL_CHANGED" or event == "UNIT_AURA" or event == "READY_CHECK_CONFIRM" or event == "UNIT_PHASE" or event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        local argIsSafeUnit = type(arg1) == "string"
        if argIsSafeUnit and type(issecretvalue) == "function" then
            local okSecret, isSecret = pcall(issecretvalue, arg1)
            if okSecret and isSecret == true then
                argIsSafeUnit = false
            end
        end

        if PartyTestState.active and PartyTestState.mode == "live" and not argIsSafeUnit then
            _partyDirtyAll = true
            _partyBatchFrame:Show()
            return
        end

        for i = 1, 4 do
            local f = PartyFrames[i]
            if f and f:IsShown() and argIsSafeUnit then
                local unit = f:GetAttribute("unit")
                if unit and arg1 == unit then
                    _partyDirtyUnits[i] = true
                    _partyBatchFrame:Show()
                elseif PartyTestState.active and PartyTestState.mode == "live" and arg1 == "player" and unit == "player" then
                    _partyDirtyUnits[i] = true
                    _partyBatchFrame:Show()
                end
            end
        end
    end
end)
ApplyPartyConfigFromSettings = function()
    if not MidnightUISettings or not MidnightUISettings.PartyFrames then return end
    EnsurePartyCombatSettingsTable()
    local s = MidnightUISettings.PartyFrames
    if s.width then config.width = s.width end
    if s.height then config.height = s.height end
    if s.layout then config.layout = s.layout end
    if s.spacingX then config.spacingX = s.spacingX end
    if s.spacingY then config.spacingY = s.spacingY end
    if s.style then
        if s.style == "Circular" then
            config.style = "Square"
            s.style = "Square"
        else
            config.style = s.style
        end
    end
    config.hide2DPortrait = (s.hide2DPortrait == true)
    if s.diameter then config.diameter = s.diameter end
end

