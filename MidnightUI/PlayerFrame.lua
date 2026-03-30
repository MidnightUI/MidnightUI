-- =============================================================================
-- FILE PURPOSE:     Custom player unit frame. Replaces Blizzard's PlayerFrame with
--                   a dark health/power bar pair, optional class-colored gradient,
--                   movable buff and debuff icon rows, and a dead-status skull icon.
-- LOAD ORDER:       Loads after ConditionBorder.lua. PlayerFrameManager handles
--                   ADDON_LOADED and PLAYER_LOGIN to build the frame after settings load.
-- DEFINES:          PlayerFrameManager (event frame), frame ref at _G.MidnightUI_PlayerFrame.
--                   Global refresh: MidnightUI_ApplyPlayerSettings().
-- READS:            MidnightUISettings.PlayerFrame.{enabled, width, height, scale, alpha,
--                   position, auras.*, debuffs.*}. MidnightUISettings.General.*
-- WRITES:           MidnightUISettings.PlayerFrame.position (on drag stop).
--                   Blizzard PlayerFrame: SetAlpha(0), EnableMouse(false) to suppress default.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor — for health bar and border coloring.
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua) — bar style.
--                   ConditionBorder (MidnightUI_ConditionBorder) — hazard tint on health bar.
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes settings controls),
--                   ConditionBorder.lua (drives hazard tint on _G.MidnightUI_PlayerFrame).
-- KEY FLOWS:
--   ADDON_LOADED → InitializeAuraSettings() → BuildPlayerFrame() → first UpdateAll()
--   UNIT_HEALTH / UNIT_MAXHEALTH → UpdateHealth(frame)
--   UNIT_POWER_UPDATE → UpdatePower(frame)
--   UNIT_AURA → RefreshAuras(frame), RefreshDebuffs(frame)
--   PLAYER_DEAD / PLAYER_ALIVE → shows/hides skull icon
-- GOTCHAS:
--   ApplyHealthBarStyle uses a two-layer texture gradient (ApplyPolishedGradient).
--   GetStatusBarColor() can return secret values; the function uses a fallback RGB
--   stored in healthBar._muiStyleFallback{R,G,B}.
--   AllowSecretHealthPercent() gates display of raw UnitHealthPercent (opt-in setting).
--   InitializeAuraSettings() duplicates default-fill logic that also exists in Settings.lua
--   DEFAULTS — both paths must stay in sync or per-character saves will drift.
-- NAVIGATION:
--   config{}                  — layout defaults (line ~42)
--   GetPlayerAuraOverlaySize()— computes drag-overlay size from perRow/maxShown settings
--   InitializeAuraSettings()  — ensures MidnightUISettings.PlayerFrame.auras/debuffs exist
--   BuildPlayerFrame()        — constructs all sub-frames (search "function BuildPlayerFrame")
--   UpdateAll()               — dispatches all sub-update calls (search "function UpdateAll")
--   ApplyHealthBarStyle()     — polished gradient + texture layering on the health bar
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local PlayerFrameManager = CreateFrame("Frame")

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

local config = {
    width = 380, height = 66, healthHeight = 42, powerHeight = 16, spacing = 1,
    position = {"BOTTOM", "UIParent", "BOTTOM", -288.33353, 264.00021},
    auras = {
        enabled = true,
        scale = 100,
        alpha = 1.0,
        position = {"CENTER", "CENTER", -377.05408, -267.33368},
        alignment = "Right",
        maxShown = 32,
        perRow = 16,
    },
    debuffs = {
        enabled = true,
        scale = 80,
        alpha = 1.0,
        position = {"BOTTOM", "BOTTOM", -328.55701, 269.46029},
        alignment = "Right",
        maxShown = 16,
        perRow = 8,
    },
}

-- Compute overlay size dynamically from current perRow and maxShown settings.
-- Uses inline stride values (35h, 45v) since the constants are defined later in the file.
local function GetPlayerAuraOverlaySize(auraKey)
    local s = MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame[auraKey]
    local maxLimit = auraKey == "auras" and 32 or 16
    local maxShown = (s and s.maxShown) or config[auraKey].maxShown or maxLimit
    local perRow = (s and s.perRow) or config[auraKey].perRow or 16
    if maxShown > maxLimit then maxShown = maxLimit end
    if perRow < 1 then perRow = 1 end
    local cols = math.min(perRow, maxShown)
    local rows = math.ceil(maxShown / perRow)
    local w = (cols * 35) - 5 + 4
    local h = (rows * 45) - 5 + 4
    return math.max(w, 40), math.max(h, 20)
end

-- Initialize aura settings from saved variables
local function InitializeAuraSettings()
    if not MidnightUISettings then
        MidnightUISettings = {}
    end
    if not MidnightUISettings.PlayerFrame then
        MidnightUISettings.PlayerFrame = {}
    end
    
    -- Initialize buffs (auras) settings
    if not MidnightUISettings.PlayerFrame.auras then
        MidnightUISettings.PlayerFrame.auras = {
            enabled = true,
            scale = 100,
            alpha = 1.0,
            position = {"CENTER", "CENTER", -377.05408, -267.33368},
            alignment = "Right",
            maxShown = 32,
        }
    end
    -- Ensure all aura settings have default values if missing
    if MidnightUISettings.PlayerFrame.auras.enabled == nil then
        MidnightUISettings.PlayerFrame.auras.enabled = true
    end
    if not MidnightUISettings.PlayerFrame.auras.scale then
        MidnightUISettings.PlayerFrame.auras.scale = 100
    end
    if not MidnightUISettings.PlayerFrame.auras.alpha then
        MidnightUISettings.PlayerFrame.auras.alpha = 1.0
    end
    if not MidnightUISettings.PlayerFrame.auras.alignment then
        MidnightUISettings.PlayerFrame.auras.alignment = "Right"
    end
    if MidnightUISettings.PlayerFrame.auras.maxShown == nil then
        MidnightUISettings.PlayerFrame.auras.maxShown = 32
    end
    
    -- Initialize debuffs settings
    if not MidnightUISettings.PlayerFrame.debuffs then
        MidnightUISettings.PlayerFrame.debuffs = {
            enabled = true,
            scale = 80,
            alpha = 1.0,
            position = {"BOTTOM", "BOTTOM", -328.55701, 269.46029},
            alignment = "Right",
            maxShown = 16,
            perRow = 8,
        }
    end
    -- Ensure all debuff settings have default values if missing
    if MidnightUISettings.PlayerFrame.debuffs.enabled == nil then
        MidnightUISettings.PlayerFrame.debuffs.enabled = true
    end
    if not MidnightUISettings.PlayerFrame.debuffs.scale then
        MidnightUISettings.PlayerFrame.debuffs.scale = 100
    end
    if not MidnightUISettings.PlayerFrame.debuffs.alpha then
        MidnightUISettings.PlayerFrame.debuffs.alpha = 1.0
    end
    if not MidnightUISettings.PlayerFrame.debuffs.alignment then
        MidnightUISettings.PlayerFrame.debuffs.alignment = "Right"
    end
    if MidnightUISettings.PlayerFrame.debuffs.maxShown == nil then
        MidnightUISettings.PlayerFrame.debuffs.maxShown = 16
    end
end


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
    end
    return DEFAULT_UNIT_COLOR_R, DEFAULT_UNIT_COLOR_G, DEFAULT_UNIT_COLOR_B
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

local function CreateBlackBorder(parent, thickness, alpha)
    thickness = thickness or 1
    alpha = alpha or 1
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(thickness); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT"); border.top:SetColorTexture(0,0,0,alpha)
    border.bottom = border:CreateTexture(nil, "OVERLAY"); border.bottom:SetHeight(thickness); border.bottom:SetPoint("BOTTOMLEFT"); border.bottom:SetPoint("BOTTOMRIGHT"); border.bottom:SetColorTexture(0,0,0,alpha)
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(thickness); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT"); border.left:SetColorTexture(0,0,0,alpha)
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(thickness); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT"); border.right:SetColorTexture(0,0,0,alpha)
    -- Gradual inner highlight (top) and shadow (bottom) for depth
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

local function SetBorderColor(border, r, g, b, a)
    if not border then return end
    local alpha = a or 1
    if border.top then border.top:SetColorTexture(r, g, b, alpha) end
    if border.bottom then border.bottom:SetColorTexture(r, g, b, alpha) end
    if border.left then border.left:SetColorTexture(r, g, b, alpha) end
    if border.right then border.right:SetColorTexture(r, g, b, alpha) end
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

local function ApplyHealthBarStyle(healthBar)
    if not healthBar then return end
    local function ApplyPolishedGradient(tex, topDarkA, centerLightA, bottomDarkA)
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

-- Shared bar style applier used by other unit frames that should match player visuals.
_G.MidnightUI_ApplySharedUnitBarStyle = ApplyHealthBarStyle

local function ApplyFrameTextStyle(frame)
    if not frame or not frame.nameText then return end

    local sharedText = _G.MidnightUI_ApplySharedUnitTextStyle
    if type(sharedText) == "function" then
        sharedText(frame, {
            nameFont = "Fonts\\FRIZQT__.TTF",
            nameSize = 14,
            healthFont = "Fonts\\ARIALN.TTF",
            healthSize = 14,
            levelFont = "Fonts\\FRIZQT__.TTF",
            levelSize = 11,
            powerFont = "Fonts\\FRIZQT__.TTF",
            powerSize = 11,
            nameShadowAlpha = 1,
            healthShadowAlpha = 1,
            levelShadowAlpha = 1,
            powerShadowAlpha = 1,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\ARIALN.TTF", 14, "OUTLINE")
    SetFontSafe(frame.levelText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    SetFontSafe(frame.powerText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    frame.nameText:SetShadowOffset(1, -1); frame.nameText:SetShadowColor(0, 0, 0, 1)
    frame.healthText:SetShadowOffset(2, -2); frame.healthText:SetShadowColor(0, 0, 0, 1)
    frame.levelText:SetShadowOffset(1, -1); frame.levelText:SetShadowColor(0, 0, 0, 1)
    frame.powerText:SetShadowOffset(1, -1); frame.powerText:SetShadowColor(0, 0, 0, 0.9)
end

local function ApplyFrameLayout(frame)
    if not frame or not frame.healthContainer or not frame.powerContainer then return end
    frame.healthContainer:SetHeight(config.healthHeight)
    frame.powerContainer:ClearAllPoints()
    frame.powerContainer:SetPoint("TOPLEFT", frame.healthContainer, "BOTTOMLEFT", 0, -config.spacing)
    frame.powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    if frame.powerSep then frame.powerSep:Show() end
    if frame.healthBg then frame.healthBg:SetColorTexture(0.1, 0.1, 0.1, 1) end
    if frame.powerBg then frame.powerBg:SetColorTexture(0, 0, 0, 0.5) end
end

-- =========================================================================
--  MAIN PLAYER FRAME
-- =========================================================================

local function CreatePlayerFrame()
    local frame = CreateFrame("Button", "MidnightUI_PlayerFrame", UIParent, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(config.width, config.height)
    frame:SetAttribute("unit", "player")
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")
    RegisterUnitWatch(frame)

    local savedScale = 1.0
    if MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.scale then
        savedScale = MidnightUISettings.PlayerFrame.scale / 100
    end
    frame:SetScale(savedScale)

    local pos = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.position)
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
    frame:SetAlpha(0.95)

    frame:SetScript("OnEnter", function(self)
        local useCustom = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.customTooltip ~= false)
        if frame.dragOverlay and frame.dragOverlay:IsShown() and not useCustom then
            return
        end
        if useCustom and _G.MidnightUI_PlayerTooltips and _G.MidnightUI_PlayerTooltips.Show then
            _G.MidnightUI_PlayerTooltips:Show(self, "player", "ANCHOR_BOTTOMLEFT")
        else
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
            GameTooltip:SetUnit("player")
            GameTooltip:Show()
        end
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

    -- Dedicated overlay border for debuff alerts on the existing player frame.
    local debuffBorder = CreateBlackBorder(frame, 1, 1)
    debuffBorder:SetFrameLevel(frame:GetFrameLevel() + 30)
    debuffBorder:Hide()
    frame.debuffBorder = debuffBorder

    -- Backdrop outline fallback (similar overlay style used by other unitframe addons).
    local debuffOutline = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    debuffOutline:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    debuffOutline:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    debuffOutline:SetFrameLevel(frame:GetFrameLevel() + 31)
    debuffOutline:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    debuffOutline:SetBackdropBorderColor(0, 0, 0, 1)
    debuffOutline:Hide()
    frame.debuffOutline = debuffOutline

    -- Condition glow border — built and managed by ConditionBorder module.
    local CB = _G.MidnightUI_ConditionBorder
    if CB and CB.BuildCondBorder then
        frame.conditionBorder = CB.BuildCondBorder(frame)
        CB.Init(frame)
    end

    -- HEALTH
    local healthContainer = CreateFrame("Frame", nil, frame)
    healthContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    healthContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    healthContainer:SetHeight(config.healthHeight)
    frame.healthContainer = healthContainer

    local healthBg = healthContainer:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints()
    healthBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.healthBg = healthBg
    frame.healthBg = healthBg

    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetPoint("TOPLEFT", 0, 0)
    healthBar:SetPoint("BOTTOMRIGHT", 0, 0)
    ApplyHealthBarStyle(healthBar)
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
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    nameText:SetPoint("CENTER", textOverlay, "CENTER", 0, 2)
    nameText:SetTextColor(1, 1, 1, 1); nameText:SetShadowOffset(1, -1); nameText:SetShadowColor(0, 0, 0, 1)
    frame.nameText = nameText

    local healthText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(healthText, "Fonts\\ARIALN.TTF", 14, "OUTLINE")
    healthText:SetPoint("RIGHT", textOverlay, "RIGHT", -10, 0)
    healthText:SetTextColor(1, 1, 1, 1); healthText:SetShadowOffset(2, -2); healthText:SetShadowColor(0, 0, 0, 1)
    frame.healthText = healthText

    local levelText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(levelText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    levelText:SetPoint("LEFT", textOverlay, "LEFT", 10, 0)
    levelText:SetTextColor(0.9, 0.9, 0.9, 1)
    frame.levelText = levelText

    -- RESURRECTION ICON (hidden by default)
    local resIcon = textOverlay:CreateTexture(nil, "OVERLAY")
    resIcon:SetSize(28, 28)
    resIcon:SetPoint("CENTER", healthContainer, "CENTER", 0, 0)
    resIcon:SetTexture("Interface\\RaidFrame\\Raid-Icon-Rez")
    resIcon:SetVertexColor(1, 1, 1, 1)
    resIcon:Hide()
    frame.resIcon = resIcon

    local deadIcon = textOverlay:CreateTexture(nil, "OVERLAY")
    deadIcon:SetSize(32, 32)
    deadIcon:SetPoint("RIGHT", healthContainer, "RIGHT", -28, 0)
    EnsureDeadIconTexture(deadIcon)
    deadIcon:SetVertexColor(1, 1, 1, 1)
    deadIcon:SetDrawLayer("OVERLAY", 7)
    deadIcon:SetAlpha(1)
    deadIcon:Hide()
    frame.deadIcon = deadIcon
    
    local resGlow = textOverlay:CreateTexture(nil, "ARTWORK")
    resGlow:SetSize(50, 50)
    resGlow:SetPoint("CENTER", resIcon, "CENTER")
    resGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    resGlow:SetVertexColor(1, 0.85, 0.3, 0)
    resGlow:SetBlendMode("ADD")
    resGlow:Hide()
    frame.resGlow = resGlow

    -- POWER
    local powerContainer = CreateFrame("Frame", nil, frame)
    powerContainer:SetPoint("TOPLEFT", healthContainer, "BOTTOMLEFT", 0, -config.spacing)
    powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
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
    SetFontSafe(powerText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    powerText:SetPoint("CENTER", powerOverlay, "CENTER", 0, 0)
    powerText:SetTextColor(1, 1, 1, 1); powerText:SetShadowOffset(1, -1); powerText:SetShadowColor(0, 0, 0, 0.9)
    frame.powerText = powerText

    -- Debuff alert icon attached to this frame (not a separate player frame).
    local debuffAlert = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    debuffAlert:SetSize(18, 18)
    debuffAlert:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, 2)
    debuffAlert:SetFrameLevel(frame:GetFrameLevel() + 12)
    debuffAlert:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    debuffAlert:SetBackdropColor(0, 0, 0, 0.15)
    debuffAlert:SetBackdropBorderColor(0, 0, 0, 1)
    debuffAlert:Hide()
    frame.debuffAlert = debuffAlert

    local debuffAlertIcon = debuffAlert:CreateTexture(nil, "ARTWORK")
    debuffAlertIcon:SetPoint("TOPLEFT", debuffAlert, "TOPLEFT", 1, -1)
    debuffAlertIcon:SetPoint("BOTTOMRIGHT", debuffAlert, "BOTTOMRIGHT", -1, 1)
    debuffAlertIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    frame.debuffAlertIcon = debuffAlertIcon

    frame:Hide()
    return frame
end

local function ApplyPlayerFrameBarStyle()
    local frame = _G.MidnightUI_PlayerFrame
    if frame and frame.healthBar then
        ApplyHealthBarStyle(frame.healthBar)
    end
    if frame and frame.powerBar then
        ApplyHealthBarStyle(frame.powerBar)
    end
    ApplyFrameTextStyle(frame)
    ApplyFrameLayout(frame)
end
_G.MidnightUI_ApplyPlayerFrameBarStyle = ApplyPlayerFrameBarStyle

-- =========================================================================
--  UPDATED HEALTH (SECRET SAFE)
-- =========================================================================

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local lastAllowSecretState = nil
local lastPlayerDebugTime = 0

local function IsPlayerDebugEnabled()
    return _G.MidnightUI_Debug
        and MidnightUISettings
        and MidnightUISettings.PlayerFrame
        and MidnightUISettings.PlayerFrame.debug == true
end

local function IsCondTintDebugEnabled()
    if not _G.MidnightUI_Debug then return false end
    local s = MidnightUISettings
    if not s or not s.PlayerFrame then return false end
    return s.PlayerFrame.condBorderDebug == true or s.PlayerFrame.debug == true
end

local function IsPlayerCondTintDiagConsoleEnabled()
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

local function EmitPlayerCondTintDiag(msg)
    local text = tostring(msg or "")
    local src = "PlayerCondTint"
    if IsPlayerCondTintDiagConsoleEnabled() then
        pcall(_G.MidnightUI_Diagnostics.LogDebugSource, src, text)
        return
    end
    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. text)
end

local function CondTintLog(msg)
    if not IsCondTintDebugEnabled() then return end
    EmitPlayerCondTintDiag(msg)
end

local function IsCondTintVerboseEnabled()
    local s = MidnightUISettings
    if not s or not s.PlayerFrame then return false end
    return s.PlayerFrame.condBorderDebugVerbose == true
end

local function CondTintVerboseLog(msg)
    if not IsCondTintVerboseEnabled() then return end
    CondTintLog(msg)
end

local function PlayerSafeToString(value)
    if value == nil then return "nil" end
    if value == false then return "false" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return table.concat({ s }, "") end)
    if not ok2 then return "[Restricted]" end
    return s
end

local function PlayerLogDebug(message)
    return
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

local function Clamp01Number(v)
    if type(v) ~= "number" then return nil end
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- Keep numeric and secret tint paths visually aligned.
local COND_TINT_DARKEN_MUL = 0.42
local COND_TINT_DARKEN_SHADE_ALPHA = 1 - COND_TINT_DARKEN_MUL

local function GetConditionTintBarColor(frame, fallbackR, fallbackG, fallbackB)
    if not frame or frame._muiCondTintActive ~= true then
        return fallbackR, fallbackG, fallbackB, false
    end
    if frame._muiCondTintHasColor ~= true then
        return fallbackR, fallbackG, fallbackB, true
    end

    if frame._muiCondTintSecret == true then
        -- Secret color payload: use direct color; darkening is done via shade layer.
        return frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB, true
    end

    local r = Clamp01Number(CoerceNumber(frame._muiCondTintR))
    local g = Clamp01Number(CoerceNumber(frame._muiCondTintG))
    local b = Clamp01Number(CoerceNumber(frame._muiCondTintB))
    if not r or not g or not b then
        return fallbackR, fallbackG, fallbackB, true
    end

    -- True bar recolor using a darker variant of the debuff color.
    return r * COND_TINT_DARKEN_MUL, g * COND_TINT_DARKEN_MUL, b * COND_TINT_DARKEN_MUL, true
end

local function EnsureCondTintShade(bar)
    if not bar then return nil end
    if not bar._muiCondTintShade then
        local shade = bar:CreateTexture(nil, "OVERLAY", nil, 6)
        shade:SetTexture("Interface\\Buttons\\WHITE8X8")
        shade:SetBlendMode("BLEND")
        shade:Hide()
        bar._muiCondTintShade = shade
    end
    local anchor = (bar.GetStatusBarTexture and bar:GetStatusBarTexture()) or bar
    bar._muiCondTintShade:ClearAllPoints()
    bar._muiCondTintShade:SetAllPoints(anchor)
    return bar._muiCondTintShade
end

local function SetCondTintShadeVisible(bar, visible, frame)
    local shade = EnsureCondTintShade(bar)
    if not shade then return end

    if not visible or not frame then
        shade:Hide()
        return
    end

    if frame._muiCondTintHasColor == true then
        if frame._muiCondTintSecret == true then
            -- Secret colors can't be darkened with arithmetic safely.
            -- Use black shade equivalent to numeric darkening multiplier.
            shade:SetVertexColor(0, 0, 0, COND_TINT_DARKEN_SHADE_ALPHA)
            shade:Show()
            return
        end
        -- Numeric recolor path is already darkened in SetStatusBarColor.
        shade:Hide()
        return
    end

    -- Unknown-color fallback uses same darkening profile to avoid visible shade jumps.
    shade:SetVertexColor(0, 0, 0, COND_TINT_DARKEN_SHADE_ALPHA)
    shade:Show()
end

local function SetBarVisualPolishSuppressed(bar, suppressed)
    if not bar then return end
    if suppressed == true then
        -- For Gradient style: keep the highlight/shade layers but switch them to ADD blend
        -- mode so they create an additive "lighter in center" shape over the secret-tinted
        -- texture without covering the tint color. Edges add nothing (black); center adds
        -- a subtle brightness lift. All values are plain Lua numbers — no secret math.
        local style = (MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
        if style == "Balanced" then style = "Gradient" end
        if style == "Gradient" then
            if bar._muiTopHighlight then
                bar._muiTopHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
                bar._muiTopHighlight:SetBlendMode("ADD")
                -- VERTICAL: minColor=bottom (bar center side), maxColor=top (bar top edge)
                -- Center side gets a slight white lift; top edge gets none.
                bar._muiTopHighlight:SetGradient("VERTICAL",
                    CreateColor(0.09, 0.09, 0.09, 1),
                    CreateColor(0.00, 0.00, 0.00, 1))
                bar._muiTopHighlight:Show()
            end
            if bar._muiBottomShade then
                bar._muiBottomShade:SetTexture("Interface\\Buttons\\WHITE8X8")
                bar._muiBottomShade:SetBlendMode("ADD")
                -- VERTICAL: minColor=bottom (bar bottom edge), maxColor=top (bar center side)
                -- Bottom edge adds nothing; center side gets the same slight lift.
                bar._muiBottomShade:SetGradient("VERTICAL",
                    CreateColor(0.00, 0.00, 0.00, 1),
                    CreateColor(0.09, 0.09, 0.09, 1))
                bar._muiBottomShade:Show()
            end
            -- Specular is already ADD; keep it as-is.
            if bar._muiSpecular then bar._muiSpecular:Show() end
            if bar._muiFlatGradient then bar._muiFlatGradient:Hide() end
            bar._muiCondTintSecretPolishOff = false
            bar._muiCondTintGradientShapeActive = true
            return
        end
        if bar._muiTopHighlight then bar._muiTopHighlight:Hide() end
        if bar._muiBottomShade then bar._muiBottomShade:Hide() end
        if bar._muiSpecular then bar._muiSpecular:Hide() end
        if bar._muiFlatGradient then bar._muiFlatGradient:Hide() end
        bar._muiCondTintSecretPolishOff = true
        bar._muiCondTintGradientShapeActive = false
        return
    end
    if bar._muiCondTintSecretPolishOff == true then
        bar._muiCondTintSecretPolishOff = false
    end
    if bar._muiCondTintGradientShapeActive == true then
        bar._muiCondTintGradientShapeActive = false
        -- Restore normal blend modes by re-running the full style apply.
        ApplyHealthBarStyle(bar)
    end
end

local function ApplyNumericColorToStatusBar(bar, r, g, b)
    if not bar then return end
    local nr = Clamp01Number(CoerceNumber(r)) or 0
    local ng = Clamp01Number(CoerceNumber(g)) or 0
    local nb = Clamp01Number(CoerceNumber(b)) or 0

    bar._muiStyleFallbackR = nr
    bar._muiStyleFallbackG = ng
    bar._muiStyleFallbackB = nb

    bar:SetStatusBarColor(nr, ng, nb, 1.0)
    ApplyHealthBarStyle(bar)

    -- Force texture vertex color to numeric target so any prior secret tint cannot persist.
    local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if tex then
        tex:SetVertexColor(nr, ng, nb, 1.0)
    end
end

local function ApplyConditionTintToStatusBar(bar, tintR, tintG, tintB, fallbackR, fallbackG, fallbackB, isTinted, useSecretTint, logTarget)
    if not bar then return end

    if isTinted and useSecretTint then
        -- Keep a numeric base color for style math, then apply secret payload directly to the status texture.
        ApplyNumericColorToStatusBar(bar, fallbackR, fallbackG, fallbackB)
        SetBarVisualPolishSuppressed(bar, true)

        local tex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
        if tex then
            tex:SetVertexColor(tintR, tintG, tintB, 1.0)
            if bar._muiCondTintSecretApplied ~= true then
                bar._muiCondTintSecretApplied = true
                CondTintVerboseLog("apply=SECRET_TEX target=" .. tostring(logTarget or "bar"))
            end
        else
            if bar._muiCondTintSecretApplied ~= false then
                bar._muiCondTintSecretApplied = false
                CondTintVerboseLog("apply=SECRET_TEX_MISSING target=" .. tostring(logTarget or "bar"))
            end
        end
        return
    end

    ApplyNumericColorToStatusBar(bar, tintR, tintG, tintB)
    SetBarVisualPolishSuppressed(bar, false)

    if bar._muiCondTintSecretApplied == true then
        bar._muiCondTintSecretApplied = false
        CondTintVerboseLog("apply=NUMERIC target=" .. tostring(logTarget or "bar"))
    end
end

local function DescribeTintRGBForLog(r, g, b)
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) then
        return "secret"
    end
    local rn, gn, bn = tonumber(r), tonumber(g), tonumber(b)
    if rn and gn and bn then
        return string.format("%.3f,%.3f,%.3f", rn, gn, bn)
    end
    return tostring(r) .. "," .. tostring(g) .. "," .. tostring(b)
end

local function ForceRestoreBaseBarColors(frame)
    if not frame then return end

    if frame.healthBar then
        local classR, classG, classB = GetUnitColor("player")
        ApplyNumericColorToStatusBar(frame.healthBar, classR, classG, classB)
        SetBarVisualPolishSuppressed(frame.healthBar, false)
        frame.healthBar._muiCondTintSecretApplied = false
        if frame.healthBar._muiCondTintShade then
            frame.healthBar._muiCondTintShade:Hide()
        end
        CondTintVerboseLog("restore=HEALTH rgb=" .. string.format("%.3f,%.3f,%.3f", classR or 0, classG or 0, classB or 0))
    end

    if frame.powerBar then
        local powerType, powerToken = UnitPowerType("player")
        local token = powerToken or "MANA"
        local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR
        ApplyNumericColorToStatusBar(frame.powerBar, color[1], color[2], color[3])
        SetBarVisualPolishSuppressed(frame.powerBar, false)
        frame.powerBar._muiCondTintSecretApplied = false
        if frame.powerBar._muiCondTintShade then
            frame.powerBar._muiCondTintShade:Hide()
        end
        CondTintVerboseLog("restore=POWER token=" .. tostring(token) .. " rgb=" .. string.format("%.3f,%.3f,%.3f", color[1] or 0, color[2] or 0, color[3] or 0))
    end
end

local function ResolveTintColorPayload(r, g, b)
    if r == nil or g == nil or b == nil then
        return nil, nil, nil, false, false
    end
    if IsSecretValue(r) or IsSecretValue(g) or IsSecretValue(b) then
        return r, g, b, true, true
    end
    local rn = Clamp01Number(CoerceNumber(r))
    local gn = Clamp01Number(CoerceNumber(g))
    local bn = Clamp01Number(CoerceNumber(b))
    if not rn or not gn or not bn then
        return nil, nil, nil, false, false
    end
    return rn, gn, bn, true, false
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

local function UpdateHealth(frame)
    if not UnitExists("player") then return end
    local allowSecret = AllowSecretHealthPercent()
    if lastAllowSecretState == nil or lastAllowSecretState ~= allowSecret then
        lastAllowSecretState = allowSecret
        PlayerLogDebug("AllowProtectedHealth%=" .. tostring(allowSecret))
    end

    local classR, classG, classB = GetUnitColor("player")
    local healthR, healthG, healthB, healthTinted = GetConditionTintBarColor(frame, classR, classG, classB)
    local useSecretHealthTint = frame._muiCondTintActive == true
        and frame._muiCondTintHasColor == true
        and frame._muiCondTintSecret == true
    ApplyConditionTintToStatusBar(
        frame.healthBar,
        healthR, healthG, healthB,
        classR, classG, classB,
        healthTinted,
        useSecretHealthTint,
        "health"
    )
    SetCondTintShadeVisible(frame.healthBar, healthTinted, frame)
    frame.nameText:SetTextColor(classR, classG, classB, 1)
    frame.nameText:SetText(UnitName("player"))

    local hasIncomingRes = UnitHasIncomingResurrection("player")
    local isDead = IsUnitActuallyDead("player")

    local level = UnitLevel("player")
    if level == -1 then level = "??" end
    frame.levelText:SetText(level)

    local current = UnitHealth("player")
    local max = UnitHealthMax("player")
    if not isDead and not hasIncomingRes then
        local okZero, isZero = pcall(function() return current <= 0 end)
        local okMaxPos, maxPos = pcall(function() return max > 0 end)
        if okZero and isZero and okMaxPos and maxPos then
            isDead = true
        end
    end

    -- Background Logic (Dynamic Coloring)
    if frame.healthBg then
        local bgR, bgG, bgB, bgAlpha = classR * 0.15, classG * 0.15, classB * 0.15, 0.6
        frame.healthBg:SetColorTexture(bgR, bgG, bgB, bgAlpha)
    end

    pcall(function()
        frame.healthBar:SetMinMaxValues(0, max)
        frame.healthBar:SetValue(current)
    end)

    local renderedText = nil
    local pct = GetDisplayHealthPercent("player")
    if pct ~= nil then
        -- Format the protected value directly in pcall (same strategy as TargetFrame).
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
            -- Keep fixed size to avoid arithmetic on protected/secret font metrics.
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

    -- Resurrection icon (keep frame fully visible while pending)
    if frame.resIcon then
        if hasIncomingRes then
            frame.resIcon:Show()
            if frame.resGlow then
                frame.resGlow:Show()
                frame.resGlow:SetAlpha(0.6)
            end
            local alpha = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.alpha) or 0.95
            frame:SetAlpha(alpha)
        else
            frame.resIcon:Hide()
            if frame.resGlow then frame.resGlow:Hide() end
        end
    end

    PlayerLogDebug("pctType=" .. PlayerSafeToString(type(pct))
        .. " curType=" .. PlayerSafeToString(type(current))
        .. " maxType=" .. PlayerSafeToString(type(max))
        .. " isDead=" .. PlayerSafeToString(isDead)
        .. " incomingRes=" .. PlayerSafeToString(hasIncomingRes)
        .. " iconShown=" .. PlayerSafeToString(frame.deadIcon and frame.deadIcon:IsShown())
        .. " atlasReady=" .. PlayerSafeToString(C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(DEAD_STATUS_ATLAS) ~= nil)
        .. " rendered=" .. PlayerSafeToString(renderedText)
        .. " shown=" .. PlayerSafeToString(frame.healthText and frame.healthText:GetText()))
end

-- =========================================================================
--  UPDATED POWER (SECRET SAFE)
-- =========================================================================

local function UpdatePower(frame)
    if not UnitExists("player") then return end

    local powerType, powerToken = UnitPowerType("player")
    local token = powerToken or "MANA"
    local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR

    local powerR, powerG, powerB, powerTinted = GetConditionTintBarColor(frame, color[1], color[2], color[3])
    local useSecretPowerTint = frame._muiCondTintActive == true
        and frame._muiCondTintHasColor == true
        and frame._muiCondTintSecret == true
    ApplyConditionTintToStatusBar(
        frame.powerBar,
        powerR, powerG, powerB,
        color[1], color[2], color[3],
        powerTinted,
        useSecretPowerTint,
        "power"
    )
    SetCondTintShadeVisible(frame.powerBar, powerTinted, frame)

    local current = UnitPower("player", powerType)
    local max = UnitPowerMax("player", powerType)

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

local function IsWeakConditionTintSource(source)
    if type(source) ~= "string" then
        return false
    end
    return source == "PRIMARY_OVERLAY" or source == "SECRET_UNKNOWN"
end

local function IsStrongConditionTintSource(source)
    if type(source) ~= "string" then
        return false
    end
    if IsWeakConditionTintSource(source) then
        return false
    end
    if source:match("^PRIMARY_") then return true end
    if source:match("^SECRET_") then return true end
    if source:match("^RGB_") then return true end
    return false
end

local function GetCondTintNow()
    if GetTimePreciseSec then
        return GetTimePreciseSec()
    end
    if GetTime then
        return GetTime()
    end
    return 0
end

local WEAK_TINT_APPLY_DELAY_SEC = 0.12
local SECRET_UNKNOWN_APPLY_DELAY_SEC = 0.22
local SECRET_TINT_RESYNC_SEC = 0.10

local function SetPlayerFrameConditionTintState(isActive, r, g, b, source)
    local frame = _G["MidnightUI_PlayerFrame"]
    if not frame then
        return false
    end

    local wasActive = frame._muiCondTintActive == true
    local nextActive = isActive == true
    local nr, ng, nb, hasColor, isSecret = nil, nil, nil, false, false

    if nextActive then
        nr, ng, nb, hasColor, isSecret = ResolveTintColorPayload(r, g, b)
        if r == nil or g == nil or b == nil then
            nextActive = false
        end

        -- Weak/unknown sources can briefly appear before typed sources.
        -- Hold them for a short window to reduce visible flash without losing combat tint.
        if IsWeakConditionTintSource(source) then
            if frame._muiCondTintActive == true and IsStrongConditionTintSource(frame._muiCondTintSource) then
                return false
            end
            local delay = WEAK_TINT_APPLY_DELAY_SEC
            if source == "SECRET_UNKNOWN" then
                -- Unknown secret payload can create a brief bright flash before typed tint resolves.
                -- Use a short hold so typed sources can win first without adding visible bar lag.
                delay = SECRET_UNKNOWN_APPLY_DELAY_SEC
            end
            local now = GetCondTintNow()
            local pendingAt = frame._muiCondTintWeakPendingAt
            local pendingSrc = frame._muiCondTintWeakPendingSource
            if not pendingAt or pendingSrc ~= source then
                frame._muiCondTintWeakPendingAt = now
                frame._muiCondTintWeakPendingSource = source
                return false
            end
            if now > 0 and (now - pendingAt) < delay then
                return false
            end
        else
            frame._muiCondTintWeakPendingAt = nil
            frame._muiCondTintWeakPendingSource = nil
        end

        -- Do not let weak/unknown sources override an existing strong typed tint.
        if frame._muiCondTintActive == true
            and IsStrongConditionTintSource(frame._muiCondTintSource)
            and IsWeakConditionTintSource(source) then
            return false
        end
    else
        frame._muiCondTintWeakPendingAt = nil
        frame._muiCondTintWeakPendingSource = nil
    end

    local changed = (frame._muiCondTintActive == true) ~= nextActive
    if nextActive and not changed then
        changed = (frame._muiCondTintSource or "") ~= (source or "")
            or ((frame._muiCondTintHasColor == true) ~= (hasColor == true))
            or ((frame._muiCondTintSecret == true) ~= (isSecret == true))
            or (hasColor == true and isSecret ~= true and (
                math.abs((frame._muiCondTintR or 0) - (nr or 0)) > 0.001
                or math.abs((frame._muiCondTintG or 0) - (ng or 0)) > 0.001
                or math.abs((frame._muiCondTintB or 0) - (nb or 0)) > 0.001
            ))
    end

    local forceSecretResync = false

    if nextActive then
        frame._muiCondTintActive = true
        frame._muiCondTintHasColor = hasColor == true
        frame._muiCondTintSecret = isSecret == true
        frame._muiCondTintWeakPendingAt = nil
        frame._muiCondTintWeakPendingSource = nil
        if hasColor == true then
            frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB = nr, ng, nb
        else
            frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB = nil, nil, nil
        end
        frame._muiCondTintSource = source
        -- Secret payloads can update without a detectable "changed" state.
        -- Force periodic full bar resync so health/power never diverge.
        if hasColor == true and isSecret == true and not changed then
            local now = GetCondTintNow()
            local lastSyncAt = frame._muiCondTintSecretSyncAt or 0
            if now <= 0 or (now - lastSyncAt) >= SECRET_TINT_RESYNC_SEC then
                forceSecretResync = true
                frame._muiCondTintSecretSyncAt = now
                CondTintVerboseLog("refresh=SECRET_SYNC src=" .. tostring(source or "unknown"))
            end
        else
            frame._muiCondTintSecretSyncAt = nil
        end
    else
        frame._muiCondTintActive = false
        frame._muiCondTintHasColor = false
        frame._muiCondTintSecret = false
        frame._muiCondTintR, frame._muiCondTintG, frame._muiCondTintB = nil, nil, nil
        frame._muiCondTintSource = nil
        frame._muiCondTintWeakPendingAt = nil
        frame._muiCondTintWeakPendingSource = nil
        frame._muiCondTintSecretSyncAt = nil
        if wasActive then
            ForceRestoreBaseBarColors(frame)
        end
    end

    if not changed and not forceSecretResync then
        return false
    end

    if frame:IsShown() then
        UpdateHealth(frame)
        UpdatePower(frame)
    end
    return changed
end

_G.MidnightUI_SetPlayerFrameConditionTint = function(isActive, r, g, b, source)
    local ok, changedOrErr = pcall(SetPlayerFrameConditionTintState, isActive, r, g, b, source)
    if not ok then
        return false
    end
    return changedOrErr == true
end

local function UpdateAbsorbs(frame)
    if not UnitExists("player") then return end
    frame.absorbBar:Hide()
end

local function UpdateAll(frame)
    UpdateHealth(frame)
    UpdatePower(frame)
    UpdateAbsorbs(frame)
end

-- =========================================================================
--  DRAG & LOCKING
-- =========================================================================

function MidnightUI_SetPlayerFrameLocked(locked)
    local frame = _G["MidnightUI_PlayerFrame"]
    if not frame then return end
    if locked then
        frame:EnableMouse(true)
        if frame.dragOverlay then frame.dragOverlay:Hide() end
        if not UnitExists("player") then frame:Hide() end
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
            label:SetPoint("CENTER"); label:SetText("PLAYER FRAME"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) frame:StartMoving() end)

            overlay:SetScript("OnDragStop", function(self)
                frame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint()
                local s = frame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if MidnightUISettings.PlayerFrame then
                    MidnightUISettings.PlayerFrame.position = { point, relativePoint, xOfs, yOfs }
                end
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
                _G.MidnightUI_AttachOverlaySettings(overlay, "PlayerFrame")
            end
            frame.dragOverlay = overlay
        end
        frame.dragOverlay:Show()
    end
end

-- =========================================================================
--  BUFF/DEBUFF FRAME ALIGNMENT
-- =========================================================================

-- Helper function to apply alignment to buff/debuff frames
local function ApplyAuraFrameAlignment(frame, alignment)
    if not frame then return end

    -- Modern WoW uses AuraContainer within BuffFrame/DebuffFrame
    local container = frame.AuraContainer
    if not container then return end

    -- Map legacy values to new simplified alignment
    local mapped = alignment
    if alignment == "TOPRIGHT" or alignment == "BOTTOMRIGHT" then mapped = "Right" end
    if alignment == "TOPLEFT" or alignment == "BOTTOMLEFT" then mapped = "Left" end
    if alignment == "CENTER" then mapped = "Center" end

    -- Store the alignment so we can reapply it
    frame.midnightAlignment = mapped
    container.midnightAlignment = mapped

    -- Clear any existing points on the container
    container:ClearAllPoints()

    -- Apply alignment like text alignment: Left/Center/Right
    if mapped == "Left" then
        container:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
    elseif mapped == "Center" then
        container:SetPoint("TOP", frame, "TOP", 0, 0)
    else -- "Right" (default)
        container:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
    end

    -- Hook into layout updates to maintain alignment
    if not container.midnightAlignmentHooked then
        if container.LayoutChildren then
            hooksecurefunc(container, "LayoutChildren", function(self)
                if self.midnightAlignment and self:GetParent().midnightAlignment == self.midnightAlignment then
                    C_Timer.After(0, function()
                        if self:GetParent() then
                            ApplyAuraFrameAlignment(self:GetParent(), self.midnightAlignment)
                        end
                    end)
                end
            end)
        end
        container.midnightAlignmentHooked = true
    end

    -- Force a layout update
    if container.LayoutChildren then
        container:LayoutChildren()
    elseif container.Layout then
        container:Layout()
    end
end

local function ClampPlayerAuraMaxShown(value, fallback)
    local n = tonumber(value)
    if not n then
        n = tonumber(fallback) or 16
    end
    n = math.floor(n + 0.5)
    if n < 1 then n = 1 end
    if n > 32 then n = 32 end
    return n
end

local function SetPlayerAuraLimitCVar(cvarName, value)
    local text = tostring(value)
    if C_CVar and C_CVar.SetCVar then
        pcall(C_CVar.SetCVar, cvarName, text)
        return
    end
    if SetCVar then
        pcall(SetCVar, cvarName, text)
    end
end

local function RefreshDefaultAuraLayouts()
    local function RefreshFrameLayout(frame)
        if not frame then return end
        local container = frame.AuraContainer
        if container and container.LayoutChildren then
            pcall(container.LayoutChildren, container)
        elseif container and container.Layout then
            pcall(container.Layout, container)
        end
    end
    RefreshFrameLayout(BuffFrame)
    RefreshFrameLayout(DebuffFrame)
end

-- Hook Blizzard's aura layout to re-enforce max shown after every update
local function HookAuraContainerLayout(frame, settingsKey)
    if not frame or not frame.AuraContainer then return end
    local container = frame.AuraContainer
    if container._muiMaxShownHooked then return end
    container._muiMaxShownHooked = true
    local function ReEnforce()
        local s = MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame[settingsKey]
        local maxLimit = settingsKey == "auras" and 32 or 16
        local maxShown = (s and s.maxShown) or config[settingsKey].maxShown or maxLimit
        maxShown = ClampPlayerAuraMaxShown(maxShown, maxLimit)
        EnforceAuraMaxShown(frame, maxShown)
    end
    if container.LayoutChildren then
        hooksecurefunc(container, "LayoutChildren", function()
            C_Timer.After(0, ReEnforce)
        end)
    end
    if container.Layout then
        hooksecurefunc(container, "Layout", function()
            C_Timer.After(0, ReEnforce)
        end)
    end
end

local function EnforceAuraMaxShown(frame, maxShown)
    if not frame or not frame.AuraContainer or not frame.AuraContainer.GetChildren then return end
    local container = frame.AuraContainer
    local visibleCount = 0
    for _, child in ipairs({container:GetChildren()}) do
        if child and child:IsShown() then
            visibleCount = visibleCount + 1
            if visibleCount > maxShown then
                child:Hide()
            end
        end
    end
end

local function ApplyPlayerAuraDisplayLimits()
    local auraSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.auras) or config.auras
    local debuffSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.debuffs) or config.debuffs
    local buffMax = ClampPlayerAuraMaxShown(auraSettings and auraSettings.maxShown, config.auras and config.auras.maxShown or 32)
    local debuffMax = ClampPlayerAuraMaxShown(debuffSettings and debuffSettings.maxShown, config.debuffs and config.debuffs.maxShown or 16)
    SetPlayerAuraLimitCVar("buffFrameMaxBuffs", buffMax)
    SetPlayerAuraLimitCVar("buffFrameMaxDebuffs", debuffMax)
    RefreshDefaultAuraLayouts()
    -- Directly hide excess aura buttons (CVars may not work in TWW)
    EnforceAuraMaxShown(BuffFrame, buffMax)
    EnforceAuraMaxShown(DebuffFrame, debuffMax)
    -- Hook layout so the limit persists after Blizzard re-layouts
    HookAuraContainerLayout(BuffFrame, "auras")
    HookAuraContainerLayout(DebuffFrame, "debuffs")
end

-- Global function to apply aura settings
function MidnightUI_ApplyPlayerAuraSettings()
    if not BuffFrame then return end
    
    local auraSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.auras) or config.auras
    BuffFrame:SetSize(GetPlayerAuraOverlaySize("auras"))
    
    -- Apply visibility
    if auraSettings.enabled == false then
        BuffFrame:Hide()
    else
        BuffFrame:Show()
    end
    
    -- Apply scale and alpha
    BuffFrame:SetScale((auraSettings.scale or 100) / 100)
    BuffFrame:SetAlpha(auraSettings.alpha or 1.0)
    ApplyPlayerAuraDisplayLimits()
    
    -- Apply alignment
    ApplyAuraFrameAlignment(BuffFrame, auraSettings.alignment or "Right")
    
    -- Apply position if saved
    if auraSettings.position and #auraSettings.position >= 4 then
        local pos = auraSettings.position
        if #pos >= 5 then
            pos = { pos[1], pos[3], pos[4], pos[5] }
        end
        BuffFrame:ClearAllPoints()
        local s = BuffFrame:GetScale()
        if not s or s == 0 then s = 1.0 end
        local xOfs = tonumber(pos[3]) or 0
        local yOfs = tonumber(pos[4]) or 0
        BuffFrame:SetPoint(pos[1], UIParent, pos[2], xOfs * s, yOfs * s)
    end
end

-- Blizzard aura button layout constants (measured from live debug data)
local AURA_BTN_W = 30        -- full button width
local AURA_BTN_H = 40        -- full button height (icon + duration text)
local AURA_ICON_SIZE = 30    -- icon-only square size (top portion of button)
local AURA_H_STRIDE = 35     -- horizontal stride (30 + 5 spacing)
local AURA_V_STRIDE = 45     -- vertical stride (40 + 5 spacing)

local function GetAuraPerRow(auraKey)
    local s = MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame[auraKey]
    return (s and s.perRow) or config[auraKey].perRow or 16
end

local function EnsureAuraEditPreview(overlay)
    if overlay._muiPreviewIcons then return overlay._muiPreviewIcons end
    overlay._muiPreviewIcons = {}
    for i = 1, 32 do
        local holder = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        holder:SetSize(AURA_ICON_SIZE, AURA_ICON_SIZE)
        holder:SetBackdrop({ edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
        holder:SetBackdropBorderColor(0.2, 0.2, 0.2, 0.9)
        local icon = holder:CreateTexture(nil, "ARTWORK")
        icon:SetAllPoints()
        icon:SetTexture(134400)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        holder.icon = icon
        holder:Hide()
        overlay._muiPreviewIcons[i] = holder
    end
    return overlay._muiPreviewIcons
end

local function UpdateAuraEditPreview(overlay, maxShown)
    if not overlay then return end
    local icons = EnsureAuraEditPreview(overlay)
    local parent = overlay:GetParent()
    local auraKey = parent == BuffFrame and "auras" or "debuffs"
    local maxLimit = auraKey == "auras" and 32 or 16
    local count = tonumber(maxShown) or maxLimit
    if count < 1 then count = 1 end
    if count > maxLimit then count = maxLimit end

    -- Use same sizing logic as Target Aura/Debuff preview
    local size = AURA_ICON_SIZE
    local spacing = 5
    local stride = size + spacing

    -- Read perRow and alignment from saved settings
    local s = MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame[auraKey]
    local perRow = (s and s.perRow) or config[auraKey].perRow or 16
    local alignment = (s and s.alignment) or config[auraKey].alignment or "Right"

    -- Resize the container to fit the grid tightly (matches Target approach)
    local cols = math.min(perRow, count)
    local rows = math.ceil(count / perRow)
    local gridW = (cols * stride) - spacing + 4
    local gridH = (rows * stride) - spacing + 4
    if parent and parent.SetSize then
        parent:SetSize(gridW, gridH)
    end

    -- Overlay fills the container
    overlay:ClearAllPoints()
    overlay:SetAllPoints(parent)

    -- Position placeholders in a computed grid (same as UpdateTargetAuraEditPreview)
    local useRight = (alignment == "Right")
    local useLeft = (alignment == "Left")
    for i, holder in ipairs(icons) do
        holder:SetSize(size, size)
        if i <= count then
            holder:ClearAllPoints()
            local row = math.floor((i - 1) / perRow)
            local col = (i - 1) % perRow
            if useRight then
                holder:SetPoint("TOPRIGHT", overlay, "TOPRIGHT", -2 - (col * stride), -2 - (row * stride))
            elseif useLeft then
                holder:SetPoint("TOPLEFT", overlay, "TOPLEFT", 2 + (col * stride), -2 - (row * stride))
            else -- Center
                local totalW = cols * stride - (stride - size)
                local startX = -totalW / 2 + (col * stride)
                holder:SetPoint("TOP", overlay, "TOP", startX, -2 - (row * stride))
            end
            holder:Show()
        else
            holder:Hide()
        end
    end
end

-- Global function to set aura bar locked/unlocked state (same pattern as Player Frame)
function MidnightUI_SetAuraBarLocked(locked)
    if not BuffFrame then return end
    
    local auraSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.auras) or config.auras
    BuffFrame:SetSize(GetPlayerAuraOverlaySize("auras"))
    
    -- Don't show drag overlay if auras are disabled
    if auraSettings.enabled == false then
        if BuffFrame.dragOverlay then BuffFrame.dragOverlay:Hide() end
        return
    end
    
    if locked then
        if BuffFrame.dragOverlay then BuffFrame.dragOverlay:Hide() end
    else
        BuffFrame:Show()
        if not BuffFrame.dragOverlay then
            local overlay = CreateFrame("Frame", nil, BuffFrame, "BackdropTemplate")
            overlay:SetAllPoints(); overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30); overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "auras") end

            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER"); label:SetText("AURA BAR"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) BuffFrame:StartMoving() end)

            overlay:SetScript("OnDragStop", function(self)
                BuffFrame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = BuffFrame:GetPoint()
                local s = BuffFrame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if not MidnightUISettings.PlayerFrame.auras then
                    MidnightUISettings.PlayerFrame.auras = {}
                end
                MidnightUISettings.PlayerFrame.auras.position = { point, relativePoint, xOfs, yOfs }
                -- Saved silently to avoid debug spam
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "PlayerAuras")
            end
            BuffFrame.dragOverlay = overlay
        end
        UpdateAuraEditPreview(BuffFrame.dragOverlay, auraSettings.maxShown)
        BuffFrame.dragOverlay:Show()
    end
end

-- Global function to set aura bar locked/unlocked state
local function InitBuffFrame(playerFrame)
    if not BuffFrame then return end
    
    -- Get aura settings from saved variables or use defaults
    local auraSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.auras) or config.auras
    
    -- Make BuffFrame movable (like Player Frame)
    BuffFrame:SetMovable(true)
    BuffFrame:SetClampedToScreen(true)
    BuffFrame:SetSize(GetPlayerAuraOverlaySize("auras"))
    
    -- Hide the collapse/expand arrow button
    if BuffFrame.CollapseAndExpandButton then
        BuffFrame.CollapseAndExpandButton:SetAlpha(0)
        BuffFrame.CollapseAndExpandButton:EnableMouse(false)
    end
    
    -- Apply scale and alpha from settings
    BuffFrame:SetScale((auraSettings.scale or 100) / 100)
    BuffFrame:SetAlpha(auraSettings.alpha or 1.0)
    ApplyPlayerAuraDisplayLimits()
    
    -- Apply alignment
    ApplyAuraFrameAlignment(BuffFrame, auraSettings.alignment or "Right")
    
    -- Function to apply saved position
    local function NormalizePosition(pos)
        if not pos or type(pos) ~= "table" then return nil end
        -- Support both {point, relativePoint, xOfs, yOfs} and {point, relativeTo, relativePoint, xOfs, yOfs}
        if #pos >= 5 then
            return { pos[1], pos[3], pos[4], pos[5] }
        end
        if #pos >= 4 then
            return { pos[1], pos[2], pos[3], pos[4] }
        end
        return nil
    end

    local function ApplyPosition()
        local pos = NormalizePosition(auraSettings.position)
        if pos then
            BuffFrame:ClearAllPoints()
            local s = BuffFrame:GetScale()
            if not s or s == 0 then s = 1.0 end
            local xOfs = tonumber(pos[3]) or 0
            local yOfs = tonumber(pos[4]) or 0
            BuffFrame:SetPoint(pos[1], UIParent, pos[2], xOfs * s, yOfs * s)
        end
    end
    
    -- Apply saved position if available
    if auraSettings.position and #auraSettings.position >= 4 then
        ApplyPosition()
        -- Loaded silently to avoid debug spam
        
        -- Reapply after slight delays to override any Blizzard repositioning
        C_Timer.After(0.1, ApplyPosition)
        C_Timer.After(0.5, ApplyPosition)
    else
        -- Capture current default position once to avoid repeated "no saved position" logs.
        local point, _, relativePoint, xOfs, yOfs = BuffFrame:GetPoint()
        if point and relativePoint and MidnightUISettings and MidnightUISettings.PlayerFrame then
            local s = BuffFrame:GetScale()
            if not s or s == 0 then s = 1.0 end
            MidnightUISettings.PlayerFrame.auras.position = { point, relativePoint, xOfs / s, yOfs / s }
        end
    end
    
    -- Apply visibility
    if auraSettings.enabled == false then
        BuffFrame:Hide()
    else
        BuffFrame:Show()
    end
end


-- =========================================================================
--  DEBUFF FRAME MANAGEMENT
-- =========================================================================

-- Global function to apply debuff settings
function MidnightUI_ApplyPlayerDebuffSettings()
    if not DebuffFrame then return end
    
    local debuffSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.debuffs) or config.debuffs
    DebuffFrame:SetSize(GetPlayerAuraOverlaySize("debuffs"))
    
    -- Apply visibility
    if debuffSettings.enabled == false then
        DebuffFrame:Hide()
    else
        DebuffFrame:Show()
    end
    
    -- Apply scale and alpha
    DebuffFrame:SetScale((debuffSettings.scale or 100) / 100)
    DebuffFrame:SetAlpha(debuffSettings.alpha or 1.0)
    ApplyPlayerAuraDisplayLimits()
    
    -- Apply alignment
    ApplyAuraFrameAlignment(DebuffFrame, debuffSettings.alignment or "Right")
    
    -- Apply position if saved
    if debuffSettings.position and #debuffSettings.position >= 4 then
        local pos = debuffSettings.position
        if #pos >= 5 then
            pos = { pos[1], pos[3], pos[4], pos[5] }
        end
        DebuffFrame:ClearAllPoints()
        local s = DebuffFrame:GetScale()
        if not s or s == 0 then s = 1.0 end
        local xOfs = tonumber(pos[3]) or 0
        local yOfs = tonumber(pos[4]) or 0
        DebuffFrame:SetPoint(pos[1], UIParent, pos[2], xOfs * s, yOfs * s)
    end
end

if _G.MidnightUI_RegisterDiagnostic then
    _G.MidnightUI_RegisterDiagnostic("Player Aura", function()
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
    end)
    _G.MidnightUI_RegisterDiagnostic("Player Debuff", function()
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
    end)
    _G.MidnightUI_RegisterDiagnostic("Cond Border", function()
        local CB = _G.MidnightUI_ConditionBorder
        local frame = _G.MidnightUI_PlayerFrame
        local lines = CB and CB.GetDiagLines and CB.GetDiagLines(frame)
            or { "[MUI CondBorder] module not loaded" }
        for _, l in ipairs(lines) do
            if _G.MidnightUI_Debug then _G.MidnightUI_Debug(l) end
        end
    end)
elseif _G.MidnightUI_DiagnosticsPending then
    table.insert(_G.MidnightUI_DiagnosticsPending, {
        name = "Player Aura",
        fn = function()
            if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        end
    })
    table.insert(_G.MidnightUI_DiagnosticsPending, {
        name = "Player Debuff",
        fn = function()
            if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        end
    })
end

-- Global function to set debuff bar locked/unlocked state
function MidnightUI_SetDebuffBarLocked(locked)
    if not DebuffFrame then return end
    
    local debuffSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.debuffs) or config.debuffs
    DebuffFrame:SetSize(GetPlayerAuraOverlaySize("debuffs"))
    
    -- Don't show drag overlay if debuffs are disabled
    if debuffSettings.enabled == false then
        if DebuffFrame.dragOverlay then DebuffFrame.dragOverlay:Hide() end
        return
    end
    
    if locked then
        if DebuffFrame.dragOverlay then DebuffFrame.dragOverlay:Hide() end
    else
        DebuffFrame:Show()
        if not DebuffFrame.dragOverlay then
            local overlay = CreateFrame("Frame", nil, DebuffFrame, "BackdropTemplate")
            overlay:SetAllPoints(); overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30); overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "auras") end

            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER"); label:SetText("DEBUFF BAR"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) DebuffFrame:StartMoving() end)

            overlay:SetScript("OnDragStop", function(self)
                DebuffFrame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = DebuffFrame:GetPoint()
                local s = DebuffFrame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if not MidnightUISettings.PlayerFrame.debuffs then
                    MidnightUISettings.PlayerFrame.debuffs = {}
                end
                MidnightUISettings.PlayerFrame.debuffs.position = { point, relativePoint, xOfs, yOfs }
                -- Saved silently to avoid debug spam
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "PlayerDebuffs")
            end
            DebuffFrame.dragOverlay = overlay
        end
        UpdateAuraEditPreview(DebuffFrame.dragOverlay, debuffSettings.maxShown)
        DebuffFrame.dragOverlay:Show()
    end
end

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function EnsurePlayerCombatDebuffSettings()
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
    if combat.debuffOverlayPlayerEnabled == nil then
        combat.debuffOverlayPlayerEnabled = true
    end
    return combat
end

local function IsPlayerDebuffOverlayEnabled()
    local combat = EnsurePlayerCombatDebuffSettings()
    if combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    if combat.debuffOverlayPlayerEnabled == false then
        return false
    end
    return true
end

local function RefreshPlayerDebuffOverlayVisuals()
    local frame = _G.MidnightUI_PlayerFrame
    if _G.MidnightUI_ConditionBorder and _G.MidnightUI_ConditionBorder.Update and frame then
        _G.MidnightUI_ConditionBorder.Update(frame)
    end
end

local function RefreshOverlayByKey(key)
    if _G.MidnightUI_GetOverlayHandle then
        local o = _G.MidnightUI_GetOverlayHandle(key)
        if o and o.SetAllPoints then
            o:SetAllPoints()
        end
    end
end

local function BuildPlayerFrameOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.PlayerFrame) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Frame")
    b:Checkbox("Enable Player Frame", s.enabled ~= false, function(v)
        MidnightUISettings.PlayerFrame.enabled = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPlayerSettings then
            _G.MidnightUI_Settings.ApplyPlayerSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Checkbox("Player Debuff Overlay", IsPlayerDebuffOverlayEnabled(), function(v)
        local combat = EnsurePlayerCombatDebuffSettings()
        combat.debuffOverlayPlayerEnabled = v and true or false
        RefreshPlayerDebuffOverlayVisuals()
    end)
    b:Checkbox("Custom Tooltip", s.customTooltip ~= false, function(v)
        MidnightUISettings.PlayerFrame.customTooltip = v
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.PlayerFrame.scale = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPlayerSettings then
            _G.MidnightUI_Settings.ApplyPlayerSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Width", 200, 600, 5, s.width or 380, function(v)
        MidnightUISettings.PlayerFrame.width = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPlayerSettings then
            _G.MidnightUI_Settings.ApplyPlayerSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Height", 50, 150, 2, s.height or 66, function(v)
        MidnightUISettings.PlayerFrame.height = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPlayerSettings then
            _G.MidnightUI_Settings.ApplyPlayerSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 0.95, function(v)
        MidnightUISettings.PlayerFrame.alpha = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyPlayerSettings then
            _G.MidnightUI_Settings.ApplyPlayerSettings()
        end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

local function BuildPlayerAurasOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.auras) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Auras")
    b:Checkbox("Show Buff Bar", s.enabled ~= false, function(v)
        MidnightUISettings.PlayerFrame.auras.enabled = v
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.PlayerFrame.auras.scale = math.floor(v)
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        MidnightUISettings.PlayerFrame.auras.alpha = v
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Max Shown", 1, 32, 1, s.maxShown or 32, function(v)
        MidnightUISettings.PlayerFrame.auras.maxShown = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        if BuffFrame and BuffFrame.dragOverlay then
            UpdateAuraEditPreview(BuffFrame.dragOverlay, math.floor(v + 0.5))
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Icons Per Row", 1, 32, 1, s.perRow or 16, function(v)
        MidnightUISettings.PlayerFrame.auras.perRow = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        if BuffFrame and BuffFrame.dragOverlay then
            UpdateAuraEditPreview(BuffFrame.dragOverlay, MidnightUISettings.PlayerFrame.auras.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    b:Dropdown("Alignment", {"Left", "Center", "Right"}, s.alignment or "Right", function(v)
        MidnightUISettings.PlayerFrame.auras.alignment = v
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        if BuffFrame and BuffFrame.dragOverlay then
            UpdateAuraEditPreview(BuffFrame.dragOverlay, MidnightUISettings.PlayerFrame.auras.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

local function BuildPlayerDebuffsOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.debuffs) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Debuffs")
    b:Checkbox("Show Debuff Bar", s.enabled ~= false, function(v)
        MidnightUISettings.PlayerFrame.debuffs.enabled = v
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.PlayerFrame.debuffs.scale = math.floor(v)
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        MidnightUISettings.PlayerFrame.debuffs.alpha = v
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Max Shown", 1, 16, 1, s.maxShown or 16, function(v)
        MidnightUISettings.PlayerFrame.debuffs.maxShown = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        if DebuffFrame and DebuffFrame.dragOverlay then
            UpdateAuraEditPreview(DebuffFrame.dragOverlay, math.floor(v + 0.5))
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Icons Per Row", 1, 16, 1, s.perRow or 16, function(v)
        MidnightUISettings.PlayerFrame.debuffs.perRow = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        if DebuffFrame and DebuffFrame.dragOverlay then
            UpdateAuraEditPreview(DebuffFrame.dragOverlay, MidnightUISettings.PlayerFrame.debuffs.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    b:Dropdown("Alignment", {"Left", "Center", "Right"}, s.alignment or "Right", function(v)
        MidnightUISettings.PlayerFrame.debuffs.alignment = v
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        if DebuffFrame and DebuffFrame.dragOverlay then
            UpdateAuraEditPreview(DebuffFrame.dragOverlay, MidnightUISettings.PlayerFrame.debuffs.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("PlayerFrame", { title = "Player Frame", build = BuildPlayerFrameOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("PlayerAuras", { title = "Player Auras", build = BuildPlayerAurasOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("PlayerDebuffs", { title = "Player Debuffs", build = BuildPlayerDebuffsOverlaySettings })
end

-- Initialize DebuffFrame
local function InitDebuffFrame(playerFrame)
    if not DebuffFrame then return end

    -- Get debuff settings from saved variables or use defaults
    local debuffSettings = (MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.debuffs) or config.debuffs
    
    -- Make DebuffFrame movable (like BuffFrame)
    DebuffFrame:SetMovable(true)
    DebuffFrame:SetClampedToScreen(true)
    DebuffFrame:SetSize(GetPlayerAuraOverlaySize("debuffs"))
    
    -- Apply scale and alpha from settings
    DebuffFrame:SetScale((debuffSettings.scale or 100) / 100)
    DebuffFrame:SetAlpha(debuffSettings.alpha or 1.0)
    ApplyPlayerAuraDisplayLimits()
    
    -- Apply alignment
    ApplyAuraFrameAlignment(DebuffFrame, debuffSettings.alignment or "Right")
    
    -- Function to apply saved position
    local function ApplyPosition()
        if debuffSettings.position and #debuffSettings.position >= 4 then
            local pos = debuffSettings.position
            if #pos >= 5 then
                pos = { pos[1], pos[3], pos[4], pos[5] }
            end
            DebuffFrame:ClearAllPoints()
            local s = DebuffFrame:GetScale()
            if not s or s == 0 then s = 1.0 end
            local xOfs = tonumber(pos[3]) or 0
            local yOfs = tonumber(pos[4]) or 0
            DebuffFrame:SetPoint(pos[1], UIParent, pos[2], xOfs * s, yOfs * s)
        end
    end
    
    -- Apply saved position if available
    if debuffSettings.position and #debuffSettings.position >= 4 then
        ApplyPosition()
        -- Loaded silently to avoid debug spam
        
        -- Reapply after slight delays to override any Blizzard repositioning
        C_Timer.After(0.1, ApplyPosition)
        C_Timer.After(0.5, ApplyPosition)
    else
        -- Capture current default position once to avoid repeated "no saved position" logs.
        local point, _, relativePoint, xOfs, yOfs = DebuffFrame:GetPoint()
        if point and relativePoint and MidnightUISettings and MidnightUISettings.PlayerFrame then
            local s = DebuffFrame:GetScale()
            if not s or s == 0 then s = 1.0 end
            MidnightUISettings.PlayerFrame.debuffs.position = { point, relativePoint, xOfs / s, yOfs / s }
        end
    end
    
    -- Apply visibility
    if debuffSettings.enabled == false then
        DebuffFrame:Hide()
    else
        DebuffFrame:Show()
    end

end

-- =========================================================================
--  CONDITION BORDER — thin shim; logic lives in ConditionBorder.lua
-- =========================================================================

local function UpdateConditionBorder(frame)
    local CB = _G.MidnightUI_ConditionBorder
    if CB and CB.Update then CB.Update(frame) end
end

-- =========================================================================
--  DEBUFF ALERT VISUAL UPDATE
-- =========================================================================

local function UpdatePlayerDebuffAlertVisual()
    local frame = playerFrame or _G["MidnightUI_PlayerFrame"]
    if not frame then return end

    local iconFrame = frame.debuffAlert
    local border = frame.debuffBorder
    local outline = frame.debuffOutline
    if border then border:Hide() end
    if outline then outline:Hide() end
    if iconFrame then iconFrame:Hide() end
    if frame.SetBackdropBorderColor then
        frame:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- Drive the condition (debuff glow) border.
    UpdateConditionBorder(frame)
end

-- =========================================================================
--  EVENTS
-- =========================================================================

local playerFrame
local debuffCombatTicker

local function IsPlayerEventUnit(unitToken)
    if type(unitToken) ~= "string" then
        return false
    end
    if issecretvalue and issecretvalue(unitToken) then
        return false
    end
    return unitToken == "player"
end

function MidnightUI_RefreshPlayerFrame()
    local frame = playerFrame or _G["MidnightUI_PlayerFrame"]
    if frame and frame:IsShown() then
        UpdateAll(frame)
        UpdatePlayerDebuffAlertVisual()
    end
end

local function StartDebuffCombatRefresh()
    if debuffCombatTicker then return end
    if not C_Timer or not C_Timer.NewTicker then return end
    debuffCombatTicker = C_Timer.NewTicker(0.15, function()
        local frame = playerFrame or _G["MidnightUI_PlayerFrame"]
        if frame and frame:IsShown() then
            UpdatePlayerDebuffAlertVisual()
        end
    end)
end

local function StopDebuffCombatRefresh()
    if not debuffCombatTicker then return end
    debuffCombatTicker:Cancel()
    debuffCombatTicker = nil
end

PlayerFrameManager:RegisterEvent("ADDON_LOADED")
PlayerFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
PlayerFrameManager:RegisterUnitEvent("UNIT_AURA", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_HEALTH", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_MAXHEALTH", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_POWER_UPDATE", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_MAXPOWER", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_DISPLAYPOWER", "player")
PlayerFrameManager:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", "player")
PlayerFrameManager:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
PlayerFrameManager:RegisterEvent("INCOMING_RESURRECT_CHANGED")
PlayerFrameManager:RegisterEvent("PLAYER_DEAD")
PlayerFrameManager:RegisterEvent("PLAYER_ALIVE")
PlayerFrameManager:RegisterEvent("PLAYER_UNGHOST")
PlayerFrameManager:RegisterEvent("PLAYER_REGEN_DISABLED")
PlayerFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")

PlayerFrameManager:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...

    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            if PlayerFrame then
                PlayerFrame:SetAlpha(0)
                PlayerFrame:EnableMouse(false)
                if not PlayerFrame._muiSoftHidden then
                    PlayerFrame._muiSoftHidden = true
                    PlayerFrame:HookScript("OnShow", function(self)
                        self:SetAlpha(0)
                        self:EnableMouse(false)
                    end)
                end
            end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize aura settings from saved variables
        InitializeAuraSettings()
        
        if not playerFrame then
            playerFrame = CreatePlayerFrame()
        end

        if MidnightUISettings and MidnightUISettings.PlayerFrame and MidnightUISettings.PlayerFrame.enabled == false then
            playerFrame:Hide()
            playerFrame:SetAlpha(0)
            return
        end

        playerFrame:Show()
        UpdateAll(playerFrame)
        UpdatePlayerDebuffAlertVisual()
        if InCombatLockdown and InCombatLockdown() then
            StartDebuffCombatRefresh()
        else
            StopDebuffCombatRefresh()
        end
        if _G.MidnightUI_AttachPlayerCastBar then
            _G.MidnightUI_AttachPlayerCastBar(playerFrame)
        end
        InitBuffFrame(playerFrame)
        InitDebuffFrame(playerFrame)

    elseif event == "UNIT_AURA" then
        if playerFrame and playerFrame:IsShown() then
            UpdatePlayerDebuffAlertVisual()
        end

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        if playerFrame and playerFrame:IsShown() then
            UpdateHealth(playerFrame)
            UpdateAbsorbs(playerFrame)
        end

    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        if playerFrame and playerFrame:IsShown() then
            UpdatePower(playerFrame)
        end

    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        if playerFrame and playerFrame:IsShown() then
            UpdateAbsorbs(playerFrame)
        end
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" then
        if playerFrame and playerFrame:IsShown() then
            UpdatePlayerDebuffAlertVisual()
        end

    elseif event == "INCOMING_RESURRECT_CHANGED" or event == "PLAYER_DEAD" or event == "PLAYER_ALIVE" or event == "PLAYER_UNGHOST" then
        if playerFrame and playerFrame:IsShown() then
            if not arg1 or IsPlayerEventUnit(arg1) then
                UpdateAll(playerFrame)
                UpdatePlayerDebuffAlertVisual()
            end
        end
    elseif event == "PLAYER_REGEN_DISABLED" then
        StartDebuffCombatRefresh()
        if playerFrame and playerFrame:IsShown() then
            UpdatePlayerDebuffAlertVisual()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        StopDebuffCombatRefresh()
        if playerFrame and playerFrame:IsShown() then
            UpdatePlayerDebuffAlertVisual()
        end
    end
end)
