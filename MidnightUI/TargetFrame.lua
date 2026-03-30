-- =============================================================================
-- FILE PURPOSE:     Custom target unit frame. Replaces Blizzard's TargetFrame.
--                   Shows health/power bars, reaction-colored health, elite/boss
--                   class icons, buff/debuff rows, cast bar hookup, target-of-target
--                   sub-frame, and a range ticker for out-of-range fading.
-- LOAD ORDER:       Loads after ConditionBorder.lua. TargetFrameManager handles
--                   ADDON_LOADED and PLAYER_TARGET_CHANGED to build/update the frame.
-- DEFINES:          TargetFrameManager (event frame), targetFrame, targetOfTargetFrame.
--                   Global refresh: MidnightUI_RefreshTargetFrame(), MidnightUI_ApplyTargetSettings().
-- READS:            MidnightUISettings.TargetFrame.{enabled, width, height, scale, alpha,
--                   position, rangeSpell, showTargetOfTarget, targetOfTarget.*, auras.*, debuffs.*}
-- WRITES:           MidnightUISettings.TargetFrame.position (on drag stop).
--                   Blizzard TargetFrame: SetAlpha(0) + deferred EnableMouse(false) to suppress.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor — player target health bar coloring.
--                   MidnightUI_ApplySharedUnitFrameAppearance (Settings.lua).
--                   ConditionBorder (MidnightUI_ConditionBorder) — not directly; target
--                   debuff display handled internally.
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua, CastBar.lua (reads targetFrame for cast bar hookup).
-- KEY FLOWS:
--   PLAYER_TARGET_CHANGED → UpdateAll(frame) — full refresh on target switch
--   UNIT_HEALTH / UNIT_MAXHEALTH target → UpdateHealth(frame)
--   UNIT_AURA target → RefreshAuras(frame), RefreshDebuffs(frame)
--   TargetRangeTicker (C_Timer.NewTicker) → fades frame when target out of range
-- GOTCHAS:
--   SoftHideBlizzardTargetFrame: defers EnableMouse(false) to PLAYER_REGEN_ENABLED
--   because EnableMouse on a SecureFrame is combat-protected.
--   SafeFrameShown / SafeUnitIsUnit / SafeInCombatLockdown wrap taint-risk API booleans
--   in pcall + numeric relay (returns 0/1 not true/false) to avoid branch-on-secret.
--   IsUnitActuallyDead checks UnitIsDeadOrGhost → UnitIsDead → UnitIsGhost → UnitIsCorpse
--   → UnitHealth<=0 in sequence because each can fail in different contexts.
--   REACTION_COLORS maps UnitReaction() 1-8 to RGB for non-player health bar coloring.
--   ELITE_COLORS drives gold/silver/cyan/red border tints for elite/rare/worldboss.
-- NAVIGATION:
--   REACTION_COLORS, ELITE_COLORS  — color maps (line ~113-125)
--   GetTargetAuraOverlaySize()     — computes drag-overlay size from settings
--   BuildTargetFrame()             — constructs all sub-frames
--   UpdateAll()                    — dispatches sub-update calls on target change
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local TargetFrameManager = CreateFrame("Frame")
local targetFrame
local targetOfTargetFrame

function MidnightUI_RefreshTargetFrame()
    local frame = targetFrame or _G["MidnightUI_TargetFrame"]
    if frame and frame:IsShown() then
        UpdateAll(frame)
    end
end
local TargetRangeTicker
local pendingTargetFrameLock = nil
local pendingBlizzardTargetMouseDisable = false

-- Frame:IsShown() can return tainted boolean. Return 1 if shown, 0 else; never branch on API boolean.
local function SafeFrameShown(frame)
    if not frame or not frame.IsShown then return 0 end
    local n = 0
    pcall(function()
        local ok, v = pcall(frame.IsShown, frame)
        if ok then pcall(function() if v then n = 1 end end) end
    end)
    return n
end

-- UnitIsUnit() can return a secret boolean. Return 1 if match, 0 otherwise.
local function SafeUnitIsUnit(a, b)
    local n = 0
    pcall(function()
        local ok, v = pcall(UnitIsUnit, a, b)
        if ok then pcall(function() if v then n = 1 end end) end
    end)
    return n
end

-- Never test InCombatLockdown() return directly - it can be tainted. Use pcall + numeric relay so we return literal boolean.
local function SafeInCombatLockdown()
    if not InCombatLockdown then return false end
    local ok, val = pcall(InCombatLockdown)
    if not ok then return true end
    local ok2, num = pcall(function()
        if val == true then return 1 end
        return 0
    end)
    if not ok2 then return true end
    return num == 1
end

local function SoftHideBlizzardTargetFrame(frame)
    if not frame then return end
    frame:SetAlpha(0)
    if SafeInCombatLockdown() then
        pendingBlizzardTargetMouseDisable = true
        return
    end
    if frame.EnableMouse then
        frame:EnableMouse(false)
    end
    pendingBlizzardTargetMouseDisable = false
end

local function DetachContainerToUIParent(container, settingsTable)
    if not container then return end
    local x, y = container:GetCenter()
    if not x or not y then return end
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "BOTTOMLEFT", x, y)
    if settingsTable then
        settingsTable.position = { "CENTER", "BOTTOMLEFT", x, y }
    end
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

-- Elite Classification Colors
local ELITE_COLORS = {
    ["elite"] = {1.0, 0.84, 0.0, 1.0},       -- Gold
    ["rare"] = {0.6, 0.8, 1.0, 1.0},         -- Silver/Blue
    ["rareelite"] = {0.0, 1.0, 1.0, 1.0},    -- Cyan
    ["worldboss"] = {1.0, 0.0, 0.3, 1.0},    -- Red
}

local config = {
    width = 380, height = 66, healthHeight = 42, powerHeight = 16, spacing = 1,
    position = {"BOTTOM", "UIParent", "BOTTOM", 286.66653, 263.44479},
    auras = {
        enabled = true,
        size = 32,
        spacing = 4,
        perRow = 29,
        yOffset = 20, -- Distance from top of frame
        scale = 100,
        alpha = 1.0,
        position = {"CENTER", "CENTER", 188.11072, -251.22168},
        alignment = "Right",
        maxShown = 16,
    },
    debuffs = {
        enabled = true,
        size = 32,
        spacing = 4,
        perRow = 8,
        yOffset = 20,
        scale = 80,
        alpha = 1.0,
        position = {"BOTTOM", "BOTTOM", 561.58172, 267.56939},
        alignment = "Right",
        -- Filter mode: "AUTO" (player-only in group/raid), "PLAYER", or "ALL"
        filterMode = "AUTO",
        maxShown = 16,
    }
}

-- Compute overlay size dynamically from current perRow and maxShown settings.
local function GetTargetAuraOverlaySize(settingsKey)
    local s = MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame[settingsKey]
    local maxLimit = settingsKey == "auras" and 32 or 16
    local maxShown = (s and s.maxShown) or config[settingsKey].maxShown or maxLimit
    local perRow = (s and s.perRow) or config[settingsKey].perRow or 16
    if maxShown > maxLimit then maxShown = maxLimit end
    if perRow < 1 then perRow = 1 end
    local size = config.auras.size
    local spacing = config.auras.spacing
    local stride = size + spacing
    local cols = math.min(perRow, maxShown)
    local rows = math.ceil(maxShown / perRow)
    local w = (cols * stride) - spacing + 4
    local h = (rows * stride) - spacing + 4
    return math.max(w, 40), math.max(h, 20)
end

-- =========================================================================
--  DEBUG HELPER
-- =========================================================================

local function IsTargetDebugEnabled()
    return _G.MidnightUI_Debug
        and MidnightUISettings
        and MidnightUISettings.TargetFrame
        and MidnightUISettings.TargetFrame.debug == true
end

local function LogDebug(text)
    return
end

local function SafeToString(value)
    if value == nil then return "nil" end
    if value == false then return "false" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return table.concat({ s }, "") end)
    if not ok2 then return "[Restricted]" end
    return s
end

local function IsSecretValue(val)
    if type(issecretvalue) ~= "function" then return false end
    local ok, res = pcall(issecretvalue, val)
    return ok and res == true
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

-- Helper functions to show/hide shadow tables
local function ShowShadows(shadows)
    if not shadows then return end
    for _, shadow in ipairs(shadows) do
        if shadow.Show then
            shadow:Show()
        end
    end
end

local function HideShadows(shadows)
    if not shadows then return end
    for _, shadow in ipairs(shadows) do
        if shadow.Hide then
            shadow:Hide()
        end
    end
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

-- NEW: Create Elite Border with animated effects
local function CreateEliteBorder(parent)
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border:Hide()
    
    -- Outer border (thicker for elite)
    local thickness = 3
    border.top = border:CreateTexture(nil, "OVERLAY", nil, 7)
    border.top:SetHeight(thickness)
    border.top:SetPoint("TOPLEFT", parent, "TOPLEFT", -thickness, thickness)
    border.top:SetPoint("TOPRIGHT", parent, "TOPRIGHT", thickness, thickness)
    
    border.bottom = border:CreateTexture(nil, "OVERLAY", nil, 7)
    border.bottom:SetHeight(thickness)
    border.bottom:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -thickness, -thickness)
    border.bottom:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", thickness, -thickness)
    
    border.left = border:CreateTexture(nil, "OVERLAY", nil, 7)
    border.left:SetWidth(thickness)
    border.left:SetPoint("TOPLEFT", parent, "TOPLEFT", -thickness, thickness)
    border.left:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", -thickness, -thickness)
    
    border.right = border:CreateTexture(nil, "OVERLAY", nil, 7)
    border.right:SetWidth(thickness)
    border.right:SetPoint("TOPRIGHT", parent, "TOPRIGHT", thickness, thickness)
    border.right:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", thickness, -thickness)
    
    -- Inner glow effect
    border.glow = CreateFrame("Frame", nil, border)
    border.glow:SetPoint("TOPLEFT", parent, "TOPLEFT", -6, 6)
    border.glow:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 6, -6)
    border.glow.tex = border.glow:CreateTexture(nil, "BACKGROUND")
    border.glow.tex:SetAllPoints()
    border.glow.tex:SetColorTexture(1, 1, 1, 0.2)
    border.glow.tex:SetBlendMode("ADD")
    
    -- Animation timer
    border.pulseTimer = 0
    border.pulseDirection = 1
    border.pulseAlpha = 0.8
    
    return border
end

local lastRangeDebugTime = 0
local function DebugRange(msg)
    return
end

local CLASS_RANGE_SPELLS = {
    DEATHKNIGHT = { 49576, 47541, 49184 }, -- Death Grip, Death Coil, Howling Blast
    DEMONHUNTER = { 185123 }, -- Throw Glaive
    DRUID = { 8921, 5176, 194153 }, -- Moonfire, Wrath, Starfire
    EVOKER = { 361469 }, -- Living Flame
    HUNTER = { 185358, 56641, 19434 }, -- Arcane Shot, Steady Shot, Aimed Shot
    MAGE = { 133, 116 }, -- Fireball, Frostbolt
    MONK = { 117952 }, -- Crackling Jade Lightning
    PALADIN = { 20271 }, -- Judgment
    PRIEST = { 585 }, -- Smite
    ROGUE = { 185763, 114014, 185565 }, -- Pistol Shot, Shuriken Toss, Poisoned Knife
    SHAMAN = { 188196 }, -- Lightning Bolt
    WARLOCK = { 686 }, -- Shadow Bolt
    WARRIOR = { 57755, 355, 202168 }, -- Heroic Throw, Taunt, Impending Victory
}

local function GetConfiguredRangeSpell()
    local tf = MidnightUISettings and MidnightUISettings.TargetFrame
    local override = tf and tf.rangeSpell
    if type(override) == "string" then
        override = override:gsub("^%s+", ""):gsub("%s+$", "")
        if override == "" then return nil end
        local num = tonumber(override)
        if num then return num end
        return override
    elseif type(override) == "number" then
        return override
    end
    return nil
end

local function GetDefaultRangeSpell()
    local _, class = UnitClass("player")
    local list = class and CLASS_RANGE_SPELLS[class]
    if not list then return nil end
    for _, spellID in ipairs(list) do
        if (C_Spell and C_Spell.IsSpellKnown and C_Spell.IsSpellKnown(spellID)) or (IsSpellKnown and IsSpellKnown(spellID)) then
            return spellID
        end
    end
    return list[1]
end

local function IsTargetInRange()
    if not UnitExists("target") then return true end
    if UnitIsDeadOrGhost("target") then return true end
    if UnitInParty("target") or UnitInRaid("target") then
        local ok, inRange = pcall(UnitInRange, "target")
        if ok and not IsSecretValue(inRange) and (inRange == true or inRange == false) then
            DebugRange("[TargetFrame] range UnitInRange=" .. tostring(inRange))
            return inRange
        end
    end
    if UnitCanAttack and UnitCanAttack("player", "target") then
        local spell = GetConfiguredRangeSpell() or GetDefaultRangeSpell()
        if spell then
            if C_Spell and C_Spell.IsSpellInRange then
                local okSpell, spellCheck = pcall(C_Spell.IsSpellInRange, spell, "target")
                if okSpell then
                    DebugRange("[TargetFrame] range C_Spell.IsSpellInRange(" .. tostring(spell) .. ")=" .. tostring(spellCheck))
                    if not IsSecretValue(spellCheck) and spellCheck ~= nil then return spellCheck end
                else
                    DebugRange("[TargetFrame] range C_Spell.IsSpellInRange err")
                end
            end
            if IsSpellInRange and GetSpellInfo then
                local spellName = type(spell) == "number" and GetSpellInfo(spell) or spell
                if spellName then
                    local okLegacy, spellCheck = pcall(IsSpellInRange, spellName, "target")
                    if okLegacy then
                        DebugRange("[TargetFrame] range IsSpellInRange(\"" .. tostring(spellName) .. "\")=" .. tostring(spellCheck))
                        if not IsSecretValue(spellCheck) and spellCheck ~= nil then return spellCheck == 1 end
                    else
                        DebugRange("[TargetFrame] range IsSpellInRange err")
                    end
                end
            end
        else
            DebugRange("[TargetFrame] range no spell available")
        end
    end
    if UnitIsVisible("target") then
        DebugRange("[TargetFrame] range UnitIsVisible=true (fallback)")
        return true
    end
    DebugRange("[TargetFrame] range default true (no signal)")
    return true
end

-- Added: prevents "Font not set" if a font path fails for any reason
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

-- =========================================================================
--  AURA HANDLING (Target Buffs/Debuffs) - FIXED COLORS
-- =========================================================================

-- Local fallback for debuff colors to prevent nil errors
local DEBUFF_COLORS = {
    ["Magic"]   = { r = 0.20, g = 0.60, b = 1.00 },
    ["Curse"]   = { r = 0.60, g = 0.00, b = 1.00 },
    ["Disease"] = { r = 0.60, g = 0.40, b = 0.00 },
    ["Poison"]  = { r = 0.00, g = 0.60, b = 0.00 },
    ["Bleed"]   = { r = 0.78, g = 0.15, b = 0.15 },
    ["none"]    = { r = 0.80, g = 0.00, b = 0.00 } -- Red for physical/typeless
}

local buffButtons = {}
local debuffButtons = {}

-- =========================================================================
--  DISPEL DETECTION (Target Buffs/Debuffs)
-- =========================================================================
-- TEST MODE: show any dispellable aura regardless of player capabilities.
-- Set to false to use class-based dispel checks.
local SHOW_ALL_DISPELLABLE_AURAS = true

local DISPEL_TYPE_PRIORITY = {
    ["Immunity"] = 1,
    ["Enrage"] = 2,
    ["Magic"] = 3,
    ["Curse"] = 4,
    ["Disease"] = 5,
    ["Poison"] = 6,
    ["Bleed"] = 7,
}

local DISPEL_RULES = {
    -- Demon Hunter
    { name = "Reverse Magic", mode = "defensive", types = { Magic = true } },
    { name = "Consume Magic", mode = "offensive", types = { Magic = true } },
    -- Druid
    { name = "Nature's Cure", mode = "defensive", types = { Magic = true } },
    { name = "Improved Nature's Cure", mode = "defensive", types = { Curse = true, Poison = true } },
    { name = "Remove Corruption", mode = "defensive", types = { Curse = true, Poison = true } },
    -- Evoker
    { name = "Cauterizing Flame", mode = "defensive", types = { Bleed = true, Curse = true, Disease = true, Poison = true } },
    { name = "Expunge", mode = "defensive", types = { Poison = true } },
    { name = "Naturalize", mode = "defensive", types = { Magic = true, Poison = true } },
    { name = "Oppressing Roar", mode = "offensive", types = { Enrage = true } },
    -- Hunter
    { name = "Tranquilizing Shot", mode = "offensive", types = { Magic = true, Enrage = true } },
    { name = "Mending Bandage", mode = "defensive", types = { Disease = true, Poison = true } },
    -- Mage
    { name = "Remove Curse", mode = "defensive", types = { Curse = true } },
    { name = "Spellsteal", mode = "offensive", types = { Magic = true } },
    -- Monk
    { name = "Detox", mode = "defensive", types = { Disease = true, Poison = true, Magic = true } },
    { name = "Improved Detox", mode = "defensive", types = { Disease = true, Poison = true } },
    { name = "Revival", mode = "defensive", types = { Disease = true, Magic = true, Poison = true } },
    -- Paladin
    { name = "Cleanse", mode = "defensive", types = { Magic = true } },
    { name = "Improved Cleanse", mode = "defensive", types = { Disease = true, Poison = true } },
    { name = "Cleanse Toxins", mode = "defensive", types = { Disease = true, Poison = true } },
    -- Priest
    { name = "Purify", mode = "defensive", types = { Magic = true } },
    { name = "Improved Purify", mode = "defensive", types = { Disease = true } },
    { name = "Purify Disease", mode = "defensive", types = { Disease = true } },
    { name = "Dispel Magic", mode = "offensive", types = { Magic = true } },
    { name = "Mass Dispel", mode = "offensive", types = { Magic = true, Immunity = true } },
    -- Rogue
    { name = "Shiv", mode = "offensive", types = { Enrage = true } },
    -- Shaman
    { name = "Cleanse Spirit", mode = "defensive", types = { Curse = true } },
    { name = "Poison Cleansing Totem", mode = "defensive", types = { Poison = true } },
    { name = "Purify Spirit", mode = "defensive", types = { Magic = true } },
    { name = "Improved Purify Spirit", mode = "defensive", types = { Curse = true } },
    { name = "Purge", mode = "offensive", types = { Magic = true } },
    -- Warlock (Pet)
    { name = "Singe Magic", mode = "defensive", types = { Magic = true }, isPet = true },
    { name = "Devour Magic", mode = "offensive", types = { Magic = true }, isPet = true },
    -- Warrior
    { name = "Shattering Throw", mode = "offensive", types = { Immunity = true } },
}

local dispelCache
local dispelCacheDirty = true

local function MarkDispelCacheDirty()
    dispelCacheDirty = true
end

local function ApplyHealthBarStyle(healthBar)
    if not healthBar then return end

    local sharedStyle = _G.MidnightUI_ApplySharedUnitBarStyle
    if type(sharedStyle) == "function" and sharedStyle ~= ApplyHealthBarStyle then
        sharedStyle(healthBar)
        return
    end

    local function ApplyPolishedGradient(tex, topDarkA, centerLightA, bottomDarkA)
        local anchor = tex or healthBar
        local baseR, baseG, baseB = healthBar:GetStatusBarColor()
        local function CoerceGradientChannel(val, fallback)
            if IsSecretValue(val) then
                return fallback
            end
            local okNum, num = pcall(function() return val + 0 end)
            if not okNum or type(num) ~= "number" then
                return fallback
            end
            if num < 0 then num = 0 end
            if num > 1 then num = 1 end
            return num
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
        local function Clamp01(v)
            if v < 0 then return 0 end
            if v > 1 then return 1 end
            return v
        end
        -- Match PlayerFrame toning by default, then clamp only very bright bars
        -- (yellow/white) to prevent center overexposure.
        local luminance = Clamp01((baseR * 0.2126) + (baseG * 0.7152) + (baseB * 0.0722))
        local brightBias = Clamp01((luminance - 0.84) / 0.16)
        -- Extra clamp for yellow-toned bars where center highlight can read as white.
        local yellowBias = Clamp01((math.min(baseR, baseG) - baseB - 0.08) / 0.28) * Clamp01((luminance - 0.55) / 0.45)
        local edgeFactor = 0.74 + (0.10 * brightBias)
        local midLiftAmt = math.max(0.02, 0.10 - (0.08 * brightBias))
        local specAlpha = math.max(0.02, 0.06 - (0.04 * brightBias))
        midLiftAmt = math.max(0.012, midLiftAmt * (1 - (0.48 * yellowBias)))
        specAlpha = math.max(0.005, specAlpha * (1 - (0.75 * yellowBias)))
        local edgeR, edgeG, edgeB = Darken(baseR, edgeFactor), Darken(baseG, edgeFactor), Darken(baseB, edgeFactor)
        local midR, midG, midB = Lift(baseR, midLiftAmt), Lift(baseG, midLiftAmt), Lift(baseB, midLiftAmt)
        if brightBias > 0 then
            -- Pull the brightest centers slightly back toward edge tone only
            -- when luminance is very high.
            local blend = (0.28 * brightBias) + (0.22 * yellowBias)
            midR = midR + (edgeR - midR) * blend
            midG = midG + (edgeG - midG) * blend
            midB = midB + (edgeB - midB) * blend
        end
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
        local h = CoerceGradientChannel(rawH, 2)
        local topH = math.max(1, h * 0.43)
        local botH = math.max(1, h * 0.57)
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
            CreateColor(1, 1, 1, specAlpha))
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
            levelSize = 12,
            powerFont = "Fonts\\FRIZQT__.TTF",
            powerSize = 11,
            nameShadowAlpha = 1,
            healthShadowAlpha = 1,
            levelShadowAlpha = 0.9,
            powerShadowAlpha = 0.9,
        })
        return
    end

    SetFontSafe(frame.nameText, "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
    SetFontSafe(frame.healthText, "Fonts\\ARIALN.TTF", 14, "OUTLINE")
    SetFontSafe(frame.levelText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
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

local function GetSpellIdByName(spellName)
    if not spellName then return nil end
    if C_Spell and C_Spell.GetSpellInfo then
        local info = C_Spell.GetSpellInfo(spellName)
        if info and info.spellID then return info.spellID end
    end
    if GetSpellInfo then
        local _, _, _, _, _, _, spellId = GetSpellInfo(spellName)
        return spellId
    end
    return nil
end

local function IsSpellKnownSafe(spellId, isPet)
    if not spellId then return false end
    if C_Spell and C_Spell.IsSpellKnown then
        local ok, known = pcall(C_Spell.IsSpellKnown, spellId, isPet)
        if ok and known then return true end
    end
    if IsSpellKnown then
        local ok, known = pcall(IsSpellKnown, spellId, isPet)
        if ok and known then return true end
    end
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, spellId)
        if ok and known then return true end
    end
    return false
end

local function IsSpellKnownByName(spellName, isPet)
    local spellId = GetSpellIdByName(spellName)
    return IsSpellKnownSafe(spellId, isPet)
end

local function BuildDispelCapabilities()
    local caps = { defensive = {}, offensive = {} }
    for _, rule in ipairs(DISPEL_RULES) do
        if IsSpellKnownByName(rule.name, rule.isPet) then
            local bucket = rule.mode == "offensive" and caps.offensive or caps.defensive
            for dispelType, enabled in pairs(rule.types) do
                if enabled then bucket[dispelType] = true end
            end
        end
    end
    return caps
end

local function GetPlayerDispelCapabilities()
    if dispelCacheDirty or not dispelCache then
        dispelCache = BuildDispelCapabilities()
        dispelCacheDirty = false
    end
    return dispelCache
end

local function NormalizeDispelType(typeKey)
    if not typeKey then return nil end
    local ok, s = pcall(tostring, typeKey)
    if not ok then return nil end
    if type(issecretvalue) == "function" then
        local okSecret, isSecret = pcall(issecretvalue, s)
        if okSecret and isSecret then return nil end
    end
    local okEmpty, isEmpty = pcall(function() return s == "" end)
    if okEmpty and isEmpty then return nil end
    local okCompare, isMatch = pcall(function()
        return s == "Magic" or s == "Curse" or s == "Disease" or s == "Poison" or s == "Bleed" or s == "Enrage" or s == "Immunity"
    end)
    if okCompare and isMatch then return s end
    return nil
end

local function CanPlayerDispelType(typeKey, isOffensive)
    if not typeKey then return false end
    local caps = GetPlayerDispelCapabilities()
    if not caps then return false end
    local bucket = isOffensive and caps.offensive or caps.defensive
    return bucket and bucket[typeKey]
end

local function GetAuraDetails(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, index, filter)
        if ok then return aura end
        return nil
    end
    local name, icon, count, debuffType, duration, expirationTime = (filter == "HELPFUL") and UnitBuff(unit, index) or UnitDebuff(unit, index)
    if not name then return nil end
    return {
        name = name,
        icon = icon,
        dispelName = debuffType,
        duration = duration,
        expirationTime = expirationTime,
    }
end

local function SafeAuraBool(aura, field)
    if not aura or not field then return false end
    local ok, value = pcall(function() return aura[field] end)
    if not ok then return false end
    if type(issecretvalue) == "function" then
        local okSecret, isSecret = pcall(issecretvalue, value)
        if okSecret and isSecret then return false end
    end
    local okCompare, isTrue = pcall(function() return value == true end)
    if okCompare and isTrue then return true end
    return false
end

local function SafeBoolCall(func, ...)
    local ok, result = pcall(func, ...)
    if ok and result == true then return true end
    return false
end

local function UpdateTargetDispelIndicator(frame)
    if not frame or not frame.dispelIndicator then return end
    -- Dispel detection disabled (Blizzard secret values).
    frame.dispelIndicator:Hide()
    if frame.dispelIndicator.glowAnim then frame.dispelIndicator.glowAnim:Stop() end
    frame.dispelIndicator._muiLastKey = nil
end

local function GetSafeAuraCountText(count)
    local ok, show = pcall(function()
        return count and count > 1
    end)
    if ok and show then
        local ok2, s = pcall(tostring, count)
        if ok2 then
            return s
        end
    end
    return ""
end

local function UpdateTargetRange(frame)
    if not frame or not frame:IsShown() then return end
    if UnitExists("target") then
        local inRange = IsTargetInRange()
        local alpha = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.alpha) or 0.95
        if inRange then
            frame:SetAlpha(alpha)
        else
            frame:SetAlpha(0.3)
        end
        DebugRange("[TargetFrame] range result inRange=" .. tostring(inRange) .. " alpha=" .. tostring(frame:GetAlpha()))
    end
end

local function EnsureTargetRangeTicker(frame)
    if TargetRangeTicker then return end
    TargetRangeTicker = C_Timer.NewTicker(0.2, function()
        UpdateTargetRange(frame)
    end)
end

local function ElitePulseOnUpdate(self, elapsed)
    if not self.eliteBorder or not self.eliteBorder:IsShown() then return end
    self.eliteBorder.pulseTimer = (self.eliteBorder.pulseTimer or 0) + elapsed
    if self.eliteBorder.pulseTimer > 2 then
        self.eliteBorder.pulseTimer = self.eliteBorder.pulseTimer - 2
    end

    if self.currentClassification == "rare" or self.currentClassification == "rareelite" or self.currentClassification == "worldboss" then
        local progress = self.eliteBorder.pulseTimer / 2
        local alpha = 0.6 + (math.sin(progress * math.pi * 2) * 0.3)
        if self.eliteBorder.glow and self.eliteBorder.glow.tex then
            self.eliteBorder.glow.tex:SetAlpha(alpha * 0.4)
        end
    end
end

local function UpdateElitePulseState(frame, classification)
    local needsPulse = classification == "rare" or classification == "rareelite" or classification == "worldboss"
    if needsPulse then
        if not frame.pulseActive then
            frame.pulseActive = true
            if frame.eliteBorder then frame.eliteBorder.pulseTimer = 0 end
            frame:SetScript("OnUpdate", ElitePulseOnUpdate)
        end
    else
        if frame.pulseActive then
            frame.pulseActive = false
            frame:SetScript("OnUpdate", nil)
            if frame.eliteBorder and frame.eliteBorder.glow and frame.eliteBorder.glow.tex then
                frame.eliteBorder.glow.tex:SetAlpha(0)
            end
        end
    end
end

local function ApplyAuraCooldown(btn, duration, expirationTime)
    local show = false
    local start

    if duration and expirationTime then
        local ok = pcall(function()
            if duration > 0 then
                start = expirationTime - duration
                show = true
            end
        end)
        if not ok then
            show = false
        end
    end

    if show then
        btn.cd:SetCooldown(start, duration)
        btn.cd:Show()
    else
        btn.cd:Hide()
    end
end

local function GetSafeDebuffTypeKey(debuffType)
    local key = "none"
    if debuffType ~= nil then
        local ok, s = pcall(tostring, debuffType)
        if ok then
            local ok2, isMagic = pcall(function() return s == "Magic" end)
            if ok2 and isMagic then return "Magic" end
            local ok3, isCurse = pcall(function() return s == "Curse" end)
            if ok3 and isCurse then return "Curse" end
            local ok4, isDisease = pcall(function() return s == "Disease" end)
            if ok4 and isDisease then return "Disease" end
            local ok5, isPoison = pcall(function() return s == "Poison" end)
            if ok5 and isPoison then return "Poison" end
            local ok6, isBleed = pcall(function() return s == "Bleed" end)
            if ok6 and isBleed then return "Bleed" end
        end
    end
    return key
end

local function CreateAuraButton(parent, isBuff)
    local btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    btn:SetSize(config.auras.size, config.auras.size)
    
    btn.icon = btn:CreateTexture(nil, "BACKGROUND")
    btn.icon:SetAllPoints()
    btn.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    
    btn.cd = CreateFrame("Cooldown", nil, btn, "CooldownFrameTemplate")
    btn.cd:SetAllPoints()
    btn.cd:SetHideCountdownNumbers(false)
    
    btn.border = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    btn.border:SetAllPoints()
    btn.border:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1})
    btn.border:SetBackdropBorderColor(0, 0, 0, 1)
    
    -- Text layer above cooldown for stack counts
    local textFrame = CreateFrame("Frame", nil, btn)
    textFrame:SetAllPoints(btn)
    textFrame:SetFrameLevel(btn.cd:GetFrameLevel() + 1)

    btn.count = textFrame:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    btn.count:SetPoint("BOTTOMRIGHT", textFrame, "BOTTOMRIGHT", -1, 0)
    
    btn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPRIGHT")
        if self.auraInstanceID then
            if self.isBuff then
                GameTooltip:SetUnitBuffByAuraInstanceID("target", self.auraInstanceID)
            else
                GameTooltip:SetUnitDebuffByAuraInstanceID("target", self.auraInstanceID)
            end
        else
            if self.isBuff then GameTooltip:SetUnitBuff("target", self.index)
            else GameTooltip:SetUnitDebuff("target", self.index) end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return btn
end


local GetAuraApplicationDisplayCount = C_UnitAuras and C_UnitAuras.GetAuraApplicationDisplayCount
local issecretvalue = issecretvalue

-- Set stack count text. Out of combat uses the value directly.
-- In combat, the UNIT_AURA handler below updates counts via the display-safe API.
local function SetAuraCount(countFS, unit, applications, auraInstanceID)
    if issecretvalue and issecretvalue(applications) then return end
    local hideCount = not applications or applications < 2
    countFS:SetText(hideCount and '' or applications)
end

-- Stack count updater: must run in UNIT_AURA event context for the
-- combat-safe display API to produce renderable values.
local auraCountUpdater = CreateFrame("Frame")
auraCountUpdater:RegisterUnitEvent("UNIT_AURA", "target")
auraCountUpdater:SetScript("OnEvent", function(self, event, unit)
    if unit ~= "target" or not GetAuraApplicationDisplayCount then return end
    for _, btn in ipairs(debuffButtons) do
        if btn:IsShown() and btn.count and btn.auraInstanceID then
            btn.count:SetText(GetAuraApplicationDisplayCount("target", btn.auraInstanceID, 2, 999))
        end
    end
    for _, btn in ipairs(buffButtons) do
        if btn:IsShown() and btn.count and btn.auraInstanceID then
            btn.count:SetText(GetAuraApplicationDisplayCount("target", btn.auraInstanceID, 2, 999))
        end
    end
end)

local function GetAuraData(unit, index, filter)
    if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
        local aura = C_UnitAuras.GetAuraDataByIndex(unit, index, filter)
        if not aura then return nil end
        return aura.name, aura.icon, aura.applications, aura.dispelName, aura.duration, aura.expirationTime, aura.auraInstanceID
    end
    return nil
end

local function UpdateTargetAuras(frame)
    if not frame or not frame.auraContainer or not frame.debuffContainer then return end

    local auraSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.auras) or config.auras
    local debuffSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.debuffs) or config.debuffs

    if not UnitExists("target") then
        for _, b in pairs(buffButtons) do b:Hide() end
        for _, b in pairs(debuffButtons) do b:Hide() end
        UpdateTargetDispelIndicator(frame)
        return
    end

    local size = config.auras.size
    local spacing = config.auras.spacing
    local perRow = (auraSettings and auraSettings.perRow) or config.auras.perRow

    -- Update Buffs
    if auraSettings.enabled then
        frame.auraContainer:Show()
        local buffIndex = 1
        local maxBuffsShown = auraSettings.maxShown or config.auras.maxShown or 16
        for i = 1, 40 do
            if buffIndex > maxBuffsShown then break end
            local name, icon, count, debuffType, duration, expirationTime, auraInstanceID = GetAuraData("target", i, "HELPFUL")
            if not name then break end

            if not buffButtons[buffIndex] then
                buffButtons[buffIndex] = CreateAuraButton(frame.auraContainer, true)
            end
            local btn = buffButtons[buffIndex]
            btn:SetParent(frame.auraContainer)
            btn:Show()
            btn.icon:SetTexture(icon)
            SetAuraCount(btn.count, "target", count, auraInstanceID)
            btn.index = i; btn.isBuff = true; btn.auraInstanceID = auraInstanceID
            ApplyAuraCooldown(btn, duration, expirationTime)
            btn.border:SetBackdropBorderColor(0, 0, 0, 1)

            btn:ClearAllPoints()
            local row = math.floor((buffIndex - 1) / perRow)
            local col = (buffIndex - 1) % perRow
            local buffAlignment = (auraSettings and auraSettings.alignment) or config.auras.alignment or "Right"
            if buffAlignment == "Left" then
                btn:SetPoint("TOPLEFT", frame.auraContainer, "TOPLEFT", col * (size + spacing), -(row * (size + spacing)))
            elseif buffAlignment == "Center" then
                local rowCount = math.min(perRow, maxBuffsShown - (row * perRow))
                local totalW = rowCount * (size + spacing) - spacing
                local startX = (frame.auraContainer:GetWidth() - totalW) / 2
                btn:SetPoint("TOPLEFT", frame.auraContainer, "TOPLEFT", startX + col * (size + spacing), -(row * (size + spacing)))
            else
                btn:SetPoint("TOPRIGHT", frame.auraContainer, "TOPRIGHT", -(col * (size + spacing)), -(row * (size + spacing)))
            end
            buffIndex = buffIndex + 1
        end
        for i = buffIndex, #buffButtons do buffButtons[i]:Hide() end
    else
        frame.auraContainer:Hide()
        for _, b in pairs(buffButtons) do b:Hide() end
    end

    -- Update Debuffs
    local debuffPerRow = (debuffSettings and debuffSettings.perRow) or config.debuffs.perRow
    if debuffSettings.enabled then
        frame.debuffContainer:Show()
        local debuffIndex = 1
        local maxShown = debuffSettings.maxShown or config.debuffs.maxShown or 16
        local filterMode = debuffSettings.filterMode or config.debuffs.filterMode or "AUTO"
        local filter = "HARMFUL"
        if filterMode == "PLAYER" then
            filter = "HARMFUL|PLAYER"
        elseif filterMode == "AUTO" then
            if IsInRaid() or IsInGroup() then
                filter = "HARMFUL|PLAYER"
            end
        end

        for i = 1, 40 do
            if debuffIndex > maxShown then break end
            local name, icon, count, debuffType, duration, expirationTime, auraInstanceID = GetAuraData("target", i, filter)
            if not name then break end

            if not debuffButtons[debuffIndex] then
                debuffButtons[debuffIndex] = CreateAuraButton(frame.debuffContainer, false)
            end
            local btn = debuffButtons[debuffIndex]
            btn:SetParent(frame.debuffContainer)
            btn:Show()
            btn.icon:SetTexture(icon)
            SetAuraCount(btn.count, "target", count, auraInstanceID)
            btn.index = i; btn.isBuff = false; btn.auraInstanceID = auraInstanceID
            ApplyAuraCooldown(btn, duration, expirationTime)

            local typeKey = GetSafeDebuffTypeKey(debuffType)
            local color = DEBUFF_COLORS[typeKey] or DEBUFF_COLORS["none"]
            btn.border:SetBackdropBorderColor(color.r, color.g, color.b, 1)

            btn:ClearAllPoints()
            local row = math.floor((debuffIndex - 1) / debuffPerRow)
            local col = (debuffIndex - 1) % debuffPerRow
            local debuffAlignment = (debuffSettings and debuffSettings.alignment) or config.debuffs.alignment or "Right"
            if debuffAlignment == "Left" then
                btn:SetPoint("TOPLEFT", frame.debuffContainer, "TOPLEFT", col * (size + spacing), -(row * (size + spacing)))
            elseif debuffAlignment == "Center" then
                local rowCount = math.min(debuffPerRow, maxShown - (row * debuffPerRow))
                local totalW = rowCount * (size + spacing) - spacing
                local startX = (frame.debuffContainer:GetWidth() - totalW) / 2
                btn:SetPoint("TOPLEFT", frame.debuffContainer, "TOPLEFT", startX + col * (size + spacing), -(row * (size + spacing)))
            else
                btn:SetPoint("TOPRIGHT", frame.debuffContainer, "TOPRIGHT", -(col * (size + spacing)), -(row * (size + spacing)))
            end
            debuffIndex = debuffIndex + 1
        end
        for i = debuffIndex, #debuffButtons do debuffButtons[i]:Hide() end
    else
        frame.debuffContainer:Hide()
        for _, b in pairs(debuffButtons) do b:Hide() end
    end

    UpdateTargetDispelIndicator(frame)
end

-- Initialize aura settings from saved variables
local function InitializeTargetAuraSettings()
    if not MidnightUISettings then
        MidnightUISettings = {}
    end
    if not MidnightUISettings.TargetFrame then
        MidnightUISettings.TargetFrame = {}
    end
    
    -- Initialize buffs (auras) settings
    if not MidnightUISettings.TargetFrame.auras then
        MidnightUISettings.TargetFrame.auras = {
            enabled = true,
            scale = 100,
            alpha = 1.0,
            position = {"CENTER", "CENTER", 188.11072, -251.22168},
            alignment = "Right",
            maxShown = 16,
            perRow = 29,
        }
    end
    -- Ensure all aura settings have default values if missing
    if MidnightUISettings.TargetFrame.auras.enabled == nil then
        MidnightUISettings.TargetFrame.auras.enabled = true
    end
    if not MidnightUISettings.TargetFrame.auras.scale then
        MidnightUISettings.TargetFrame.auras.scale = 100
    end
    if not MidnightUISettings.TargetFrame.auras.alpha then
        MidnightUISettings.TargetFrame.auras.alpha = 1.0
    end
    if not MidnightUISettings.TargetFrame.auras.alignment then
        MidnightUISettings.TargetFrame.auras.alignment = "Right"
    end
    if MidnightUISettings.TargetFrame.auras.maxShown == nil then
        MidnightUISettings.TargetFrame.auras.maxShown = 16
    end
    
    -- Initialize debuffs settings
    if not MidnightUISettings.TargetFrame.debuffs then
        MidnightUISettings.TargetFrame.debuffs = {
            enabled = true,
            scale = 80,
            alpha = 1.0,
            position = {"BOTTOM", "BOTTOM", 561.58172, 267.56939},
            alignment = "Right",
            filterMode = "AUTO",
            maxShown = 16,
        }
    end
    -- Ensure all debuff settings have default values if missing
    if MidnightUISettings.TargetFrame.debuffs.enabled == nil then
        MidnightUISettings.TargetFrame.debuffs.enabled = true
    end
    if not MidnightUISettings.TargetFrame.debuffs.scale then
        MidnightUISettings.TargetFrame.debuffs.scale = 100
    end
    if not MidnightUISettings.TargetFrame.debuffs.alpha then
        MidnightUISettings.TargetFrame.debuffs.alpha = 1.0
    end
    if not MidnightUISettings.TargetFrame.debuffs.alignment then
        MidnightUISettings.TargetFrame.debuffs.alignment = "Right"
    end
    if not MidnightUISettings.TargetFrame.debuffs.filterMode then
        MidnightUISettings.TargetFrame.debuffs.filterMode = "AUTO"
    end
    if not MidnightUISettings.TargetFrame.debuffs.maxShown then
        MidnightUISettings.TargetFrame.debuffs.maxShown = 16
    end
end

-- Apply alignment to aura frame
local function ApplyAuraFrameAlignment(auraFrame, alignment)
    if not auraFrame or not auraFrame.parentFrame then return end
    local parentFrame = auraFrame.parentFrame

    -- Map legacy values
    local mapped = alignment
    if alignment == "TOPRIGHT" or alignment == "BOTTOMRIGHT" then mapped = "Right" end
    if alignment == "TOPLEFT" or alignment == "BOTTOMLEFT" then mapped = "Left" end
    if alignment == "CENTER" or alignment == "TOP" or alignment == "BOTTOM" then mapped = "Center" end

    auraFrame:ClearAllPoints()
    if mapped == "Left" then
        auraFrame:SetPoint("BOTTOMLEFT", parentFrame, "TOPLEFT", 0, 20)
    elseif mapped == "Center" then
        auraFrame:SetPoint("BOTTOM", parentFrame, "TOP", 0, 20)
    else -- "Right"
        auraFrame:SetPoint("BOTTOMRIGHT", parentFrame, "TOPRIGHT", 0, 20)
    end
end

-- Global function to apply aura settings
function MidnightUI_ApplyTargetAuraSettings()
    if not targetFrame or not targetFrame.auraContainer then return end
    
    local auraSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.auras) or config.auras
    
    -- Apply visibility
    if auraSettings.enabled == false then
        targetFrame.auraContainer:Hide()
    else
        targetFrame.auraContainer:Show()
    end
    
    -- Apply scale and alpha
    targetFrame.auraContainer:SetScale((auraSettings.scale or 100) / 100)
    targetFrame.auraContainer:SetAlpha(auraSettings.alpha or 1.0)
    
    -- Apply alignment
    ApplyAuraFrameAlignment(targetFrame.auraContainer, auraSettings.alignment or "Right")
    
    -- Apply position if saved
    if auraSettings.position and #auraSettings.position >= 4 then
        targetFrame.auraContainer:ClearAllPoints()
        local s = targetFrame.auraContainer:GetScale()
        if not s or s == 0 then s = 1.0 end
        local xOfs = auraSettings.position[3] * s
        local yOfs = auraSettings.position[4] * s
        targetFrame.auraContainer:SetPoint(auraSettings.position[1], UIParent, auraSettings.position[2], xOfs, yOfs)
    end
    
    UpdateTargetAuras(targetFrame)
end

local function EnsureTargetAuraEditPreview(overlay)
    if overlay._muiPreviewIcons then return overlay._muiPreviewIcons end
    overlay._muiPreviewIcons = {}
    local size = config.auras.size
    for i = 1, 32 do
        local holder = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        holder:SetSize(size, size)
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

local function UpdateTargetAuraEditPreview(overlay, maxShown)
    if not overlay then return end
    local icons = EnsureTargetAuraEditPreview(overlay)
    local container = overlay:GetParent()
    local isDebuff = container == (targetFrame and targetFrame.debuffContainer)
    local settingsKey = isDebuff and "debuffs" or "auras"
    local maxLimit = isDebuff and 16 or 32
    local count = tonumber(maxShown) or maxLimit
    if count < 1 then count = 1 end
    if count > maxLimit then count = maxLimit end
    local size = config.auras.size
    local spacing = config.auras.spacing
    -- Read perRow from saved settings, fallback to config
    local settings = MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame[settingsKey]
    local perRow = (settings and settings.perRow) or config[settingsKey].perRow or 16
    local stride = size + spacing
    -- Resize the overlay container to fit the grid tightly
    local cols = math.min(perRow, count)
    local rows = math.ceil(count / perRow)
    local gridW = (cols * stride) - spacing + 4
    local gridH = (rows * stride) - spacing + 4
    if container and container.SetSize then
        container:SetSize(gridW, gridH)
    end
    local alignment = (settings and settings.alignment) or config[settingsKey].alignment or "Right"
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
                local totalW = math.min(perRow, count) * stride - (stride - size)
                local startX = -totalW / 2 + (col * stride)
                holder:SetPoint("TOP", overlay, "TOP", startX, -2 - (row * stride))
            end
            holder:Show()
        else
            holder:Hide()
        end
    end
end

-- Global function to set aura bar locked/unlocked state
function MidnightUI_SetTargetAuraBarLocked(locked)
    -- Ensure targetFrame exists
    if not targetFrame then
        targetFrame = CreateTargetFrame()
    end
    
    if not targetFrame or not targetFrame.auraContainer then return end
    
    local auraSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.auras) or config.auras
    
    if locked then
        if targetFrame.auraContainer.dragOverlay then targetFrame.auraContainer.dragOverlay:Hide() end
    else
        -- Always show when unlocked, even if disabled
        targetFrame.auraContainer:Show()
        
        if not targetFrame.auraContainer.dragOverlay then
            local overlay = CreateFrame("Frame", nil, targetFrame.auraContainer, "BackdropTemplate")
            overlay:SetAllPoints()
            overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ 
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", 
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", 
                tile = true, tileSize = 16, edgeSize = 16, 
                insets = { left = 4, right = 4, top = 4, bottom = 4 } 
            })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
            overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "auras") end


            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER")
            label:SetText("TARGET AURA BAR")
            label:SetTextColor(1, 1, 1)
            
            overlay:EnableMouse(true)
            overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) 
                targetFrame.auraContainer:StartMoving() 
            end)

            overlay:SetScript("OnDragStop", function(self)
                targetFrame.auraContainer:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = targetFrame.auraContainer:GetPoint()
                local s = targetFrame.auraContainer:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if not MidnightUISettings.TargetFrame.auras then
                    MidnightUISettings.TargetFrame.auras = {}
                end
                MidnightUISettings.TargetFrame.auras.position = { point, relativePoint, xOfs, yOfs }
                print("|cff45ff75Target Aura Bar SAVED:|r " .. point .. " to " .. relativePoint .. " at (" .. string.format("%.1f, %.1f", xOfs, yOfs) .. ")")
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "TargetAuras")
            end
            targetFrame.auraContainer.dragOverlay = overlay
        end
        UpdateTargetAuraEditPreview(targetFrame.auraContainer.dragOverlay, auraSettings.maxShown)
        targetFrame.auraContainer.dragOverlay:Show()
    end
end

-- Global function to apply debuff settings
function MidnightUI_ApplyTargetDebuffSettings()
    if not targetFrame or not targetFrame.debuffContainer then return end
    
    local debuffSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.debuffs) or config.debuffs
    
    -- Apply visibility
    if debuffSettings.enabled == false then
        targetFrame.debuffContainer:Hide()
    else
        targetFrame.debuffContainer:Show()
    end
    
    -- Apply scale and alpha
    targetFrame.debuffContainer:SetScale((debuffSettings.scale or 100) / 100)
    targetFrame.debuffContainer:SetAlpha(debuffSettings.alpha or 1.0)
    
    -- Apply alignment
    ApplyAuraFrameAlignment(targetFrame.debuffContainer, debuffSettings.alignment or "Right")
    
    -- Apply position if saved
    if debuffSettings.position and #debuffSettings.position >= 4 then
        targetFrame.debuffContainer:ClearAllPoints()
        local s = targetFrame.debuffContainer:GetScale()
        if not s or s == 0 then s = 1.0 end
        local xOfs = debuffSettings.position[3] * s
        local yOfs = debuffSettings.position[4] * s
        targetFrame.debuffContainer:SetPoint(debuffSettings.position[1], UIParent, debuffSettings.position[2], xOfs, yOfs)
    end
    
    UpdateTargetAuras(targetFrame)
end

if _G.MidnightUI_RegisterDiagnostic then
    _G.MidnightUI_RegisterDiagnostic("Target Aura", function()
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
    end)
    _G.MidnightUI_RegisterDiagnostic("Target Debuff", function()
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
    end)
elseif _G.MidnightUI_DiagnosticsPending then
    table.insert(_G.MidnightUI_DiagnosticsPending, {
        name = "Target Aura",
        fn = function()
            if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        end
    })
    table.insert(_G.MidnightUI_DiagnosticsPending, {
        name = "Target Debuff",
        fn = function()
            if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        end
    })
end

-- Global function to set debuff bar locked/unlocked state
function MidnightUI_SetTargetDebuffBarLocked(locked)
    -- Ensure targetFrame exists
    if not targetFrame then
        targetFrame = CreateTargetFrame()
    end
    
    if not targetFrame or not targetFrame.debuffContainer then return end
    
    local debuffSettings = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.debuffs) or config.debuffs
    
    if locked then
        if targetFrame.debuffContainer.dragOverlay then targetFrame.debuffContainer.dragOverlay:Hide() end
    else
        -- Always show when unlocked, even if disabled
        targetFrame.debuffContainer:Show()
        
        if not targetFrame.debuffContainer.dragOverlay then
            local overlay = CreateFrame("Frame", nil, targetFrame.debuffContainer, "BackdropTemplate")
            overlay:SetAllPoints()
            overlay:SetFrameStrata("DIALOG")
            overlay:SetBackdrop({ 
                bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", 
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", 
                tile = true, tileSize = 16, edgeSize = 16, 
                insets = { left = 4, right = 4, top = 4, bottom = 4 } 
            })
            overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
            overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
            if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "auras") end


            local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER")
            label:SetText("TARGET DEBUFF BAR")
            label:SetTextColor(1, 1, 1)
            
            overlay:EnableMouse(true)
            overlay:RegisterForDrag("LeftButton")

            overlay:SetScript("OnDragStart", function(self) 
                targetFrame.debuffContainer:StartMoving() 
            end)

            overlay:SetScript("OnDragStop", function(self)
                targetFrame.debuffContainer:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = targetFrame.debuffContainer:GetPoint()
                local s = targetFrame.debuffContainer:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if not MidnightUISettings.TargetFrame.debuffs then
                    MidnightUISettings.TargetFrame.debuffs = {}
                end
                MidnightUISettings.TargetFrame.debuffs.position = { point, relativePoint, xOfs, yOfs }
                print("|cffff4499Target Debuff Bar SAVED:|r " .. point .. " to " .. relativePoint .. " at (" .. string.format("%.1f, %.1f", xOfs, yOfs) .. ")")
            end)
            if _G.MidnightUI_AttachOverlaySettings then
                _G.MidnightUI_AttachOverlaySettings(overlay, "TargetDebuffs")
            end
            targetFrame.debuffContainer.dragOverlay = overlay
        end
        UpdateTargetAuraEditPreview(targetFrame.debuffContainer.dragOverlay, debuffSettings.maxShown)
        targetFrame.debuffContainer.dragOverlay:Show()
    end
end

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function RefreshOverlayByKey(key)
    if _G.MidnightUI_GetOverlayHandle then
        local o = _G.MidnightUI_GetOverlayHandle(key)
        if o and o.SetAllPoints then
            o:SetAllPoints()
        end
    end
end

local function BuildTargetFrameOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.TargetFrame) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Frame")
    b:Checkbox("Enable Target Frame", s.enabled ~= false, function(v)
        MidnightUISettings.TargetFrame.enabled = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
            _G.MidnightUI_Settings.ApplyTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Checkbox("Custom Tooltip", s.customTooltip ~= false, function(v)
        MidnightUISettings.TargetFrame.customTooltip = v
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.TargetFrame.scale = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
            _G.MidnightUI_Settings.ApplyTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Width", 200, 600, 5, s.width or 380, function(v)
        MidnightUISettings.TargetFrame.width = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
            _G.MidnightUI_Settings.ApplyTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Height", 50, 150, 2, s.height or 66, function(v)
        MidnightUISettings.TargetFrame.height = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
            _G.MidnightUI_Settings.ApplyTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 0.95, function(v)
        MidnightUISettings.TargetFrame.alpha = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
            _G.MidnightUI_Settings.ApplyTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Checkbox("Show Target of Target", s.showTargetOfTarget == true, function(v)
        MidnightUISettings.TargetFrame.showTargetOfTarget = v and true or false
        if _G.MidnightUI_ApplyTargetOfTargetSettings then
            _G.MidnightUI_ApplyTargetOfTargetSettings()
        end
    end)
    return b:Height()
end

local function BuildTargetAurasOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.auras) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Auras")
    b:Checkbox("Show Target Buff Bar", s.enabled ~= false, function(v)
        MidnightUISettings.TargetFrame.auras.enabled = v
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.TargetFrame.auras.scale = math.floor(v)
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        MidnightUISettings.TargetFrame.auras.alpha = v
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Max Shown", 1, 32, 1, s.maxShown or 32, function(v)
        MidnightUISettings.TargetFrame.auras.maxShown = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        if targetFrame and targetFrame.auraContainer and targetFrame.auraContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.auraContainer.dragOverlay, math.floor(v + 0.5))
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Icons Per Row", 1, 32, 1, s.perRow or 16, function(v)
        MidnightUISettings.TargetFrame.auras.perRow = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        if targetFrame and targetFrame.auraContainer and targetFrame.auraContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.auraContainer.dragOverlay, MidnightUISettings.TargetFrame.auras.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    b:Dropdown("Alignment", {"Left", "Center", "Right"}, s.alignment or "Right", function(v)
        MidnightUISettings.TargetFrame.auras.alignment = v
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
        if targetFrame and targetFrame.auraContainer and targetFrame.auraContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.auraContainer.dragOverlay, MidnightUISettings.TargetFrame.auras.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

local function BuildTargetDebuffsOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.debuffs) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Debuffs")
    b:Checkbox("Show Target Debuff Bar", s.enabled ~= false, function(v)
        MidnightUISettings.TargetFrame.debuffs.enabled = v
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        MidnightUISettings.TargetFrame.debuffs.scale = math.floor(v)
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        MidnightUISettings.TargetFrame.debuffs.alpha = v
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Max Shown", 1, 16, 1, s.maxShown or 16, function(v)
        MidnightUISettings.TargetFrame.debuffs.maxShown = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        if targetFrame and targetFrame.debuffContainer and targetFrame.debuffContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.debuffContainer.dragOverlay, math.floor(v + 0.5))
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Icons Per Row", 1, 16, 1, s.perRow or 16, function(v)
        MidnightUISettings.TargetFrame.debuffs.perRow = math.floor(v + 0.5)
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        if targetFrame and targetFrame.debuffContainer and targetFrame.debuffContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.debuffContainer.dragOverlay, MidnightUISettings.TargetFrame.debuffs.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    b:Dropdown("Alignment", {"Left", "Center", "Right"}, s.alignment or "Right", function(v)
        MidnightUISettings.TargetFrame.debuffs.alignment = v
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        if targetFrame and targetFrame.debuffContainer and targetFrame.debuffContainer.dragOverlay then
            UpdateTargetAuraEditPreview(targetFrame.debuffContainer.dragOverlay, MidnightUISettings.TargetFrame.debuffs.maxShown)
        end
        RefreshOverlayByKey(key)
    end)
    b:Dropdown("Filter Mode", {"AUTO", "PLAYER", "ALL"}, s.filterMode or "AUTO", function(v)
        MidnightUISettings.TargetFrame.debuffs.filterMode = v
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

local function EnsureTargetOfTargetSettings()
    if not MidnightUISettings then return {} end
    if not MidnightUISettings.TargetFrame then MidnightUISettings.TargetFrame = {} end
    if not MidnightUISettings.TargetFrame.targetOfTarget then
        MidnightUISettings.TargetFrame.targetOfTarget = { scale = 100, alpha = 0.95, position = nil }
    end
    return MidnightUISettings.TargetFrame.targetOfTarget
end

local function EnsureTargetOfTargetCombatDebuffSettings()
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
    if combat.debuffOverlayTargetOfTargetEnabled == nil then
        combat.debuffOverlayTargetOfTargetEnabled = true
    end
    return combat
end

local function IsTargetOfTargetDebuffOverlayEnabled()
    local combat = EnsureTargetOfTargetCombatDebuffSettings()
    if combat.debuffOverlayGlobalEnabled == false then
        return false
    end
    if combat.debuffOverlayTargetOfTargetEnabled == false then
        return false
    end
    return true
end

local function BuildTargetOfTargetOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local totS = EnsureTargetOfTargetSettings()
    local ts = (MidnightUISettings and MidnightUISettings.TargetFrame) or {}
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Target of Target")
    b:Checkbox("Show Target of Target", ts.showTargetOfTarget == true, function(v)
        MidnightUISettings.TargetFrame.showTargetOfTarget = v and true or false
        -- Handle visibility even in move mode - hide overlay when unchecked
        if targetOfTargetFrame then
            if v then
                -- Show the overlay (in move mode, show for positioning)
                local inMoveMode = MidnightUISettings and MidnightUISettings.Messenger
                    and MidnightUISettings.Messenger.locked == false
                if inMoveMode then
                    targetOfTargetFrame:Show()
                end
            else
                -- Always hide when unchecked, even in move mode
                targetOfTargetFrame:Hide()
            end
        end
        if _G.MidnightUI_ApplyTargetOfTargetSettings then
            _G.MidnightUI_ApplyTargetOfTargetSettings()
        end
    end)
    b:Checkbox("Target of Target Debuff Overlay", IsTargetOfTargetDebuffOverlayEnabled(), function(v)
        local combat = EnsureTargetOfTargetCombatDebuffSettings()
        combat.debuffOverlayTargetOfTargetEnabled = v and true or false
        if _G.MidnightUI_RefreshTargetOfTargetDebuffOverlay then
            _G.MidnightUI_RefreshTargetOfTargetDebuffOverlay()
        end
    end)
    b:Slider("Scale %", 50, 200, 5, totS.scale or 100, function(v)
        totS.scale = math.floor(v)
        if _G.MidnightUI_ApplyTargetOfTargetSettings then
            _G.MidnightUI_ApplyTargetOfTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, totS.alpha or 0.95, function(v)
        totS.alpha = v
        if _G.MidnightUI_ApplyTargetOfTargetSettings then
            _G.MidnightUI_ApplyTargetOfTargetSettings()
        end
        RefreshOverlayByKey(key)
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("TargetFrame", { title = "Target Frame", build = BuildTargetFrameOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("TargetAuras", { title = "Target Auras", build = BuildTargetAurasOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("TargetDebuffs", { title = "Target Debuffs", build = BuildTargetDebuffsOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("TargetOfTarget", { title = "Target of Target", build = BuildTargetOfTargetOverlaySettings })
end

-- =========================================================================
--  MAIN TARGET FRAME
-- =========================================================================

local function CreateTargetFrame()
    local frame = CreateFrame("Button", "MidnightUI_TargetFrame", UIParent, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(config.width, config.height)
    frame:SetAttribute("unit", "target")
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")
    RegisterUnitWatch(frame)
    
    local savedScale = 1.0
    if MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.scale then
        savedScale = MidnightUISettings.TargetFrame.scale / 100
    end
    frame:SetScale(savedScale)
    
    local pos = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.position)
    if pos and #pos == 4 then
        if pos[5] then frame:SetPoint(pos[1], UIParent, pos[3], pos[4], pos[5])
        else frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4]) end
    else
        frame:SetPoint(unpack(config.position))
    end

    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(10)
    frame:SetMovable(true)
    -- Keep ToT freely placeable to avoid top-edge auto-clamp drift on macOS notch displays.
    frame:SetClampedToScreen(false)
    frame:EnableMouse(true)
    frame:SetAlpha(0.95) 
    
    frame:SetScript("OnEnter", function(self)
        local useCustom = (MidnightUISettings and MidnightUISettings.TargetFrame and MidnightUISettings.TargetFrame.customTooltip ~= false)
        if frame.dragOverlay and frame.dragOverlay:IsShown() and not useCustom then
            return
        end
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if UnitExists("target") then
            GameTooltip:SetUnit("target")
        elseif useCustom then
            GameTooltip:SetText("Target Tooltip (Preview)", 1, 0.82, 0)
            GameTooltip:AddLine("No target selected.", 0.9, 0.9, 0.9, true)
            GameTooltip:AddLine("This is a preview only.", 0.7, 0.7, 0.7, true)
        else
            return
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Clean 1px Border & Background (avoid SetBackdrop on secure frame to reduce taint)
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
    frame.border = CreateBlackBorder(frame, 1, 1)

    frame.shadows = CreateDropShadow(frame, 3)
    
    -- NEW: Elite Border (created early so it's behind everything)
    frame.eliteBorder = CreateEliteBorder(frame)
    
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
    SetFontSafe(levelText, "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")  -- Slightly larger for visibility
    levelText:SetPoint("LEFT", textOverlay, "LEFT", 10, 0)  -- Back to original position
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

    -- DISPEL INDICATOR (above health bar)
    local dispelIndicator = CreateFrame("Frame", nil, healthContainer)
    dispelIndicator:SetSize(24, 24)
    dispelIndicator:SetPoint("BOTTOM", healthContainer, "TOP", 0, 6)
    dispelIndicator:SetFrameStrata("HIGH")
    dispelIndicator:SetFrameLevel(healthContainer:GetFrameLevel() + 20)
    dispelIndicator:Hide()

    dispelIndicator.icon = dispelIndicator:CreateTexture(nil, "ARTWORK")
    dispelIndicator.icon:SetAllPoints()
    dispelIndicator.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    dispelIndicator.border = CreateBlackBorder(dispelIndicator, 1, 1)

    dispelIndicator.glow = dispelIndicator:CreateTexture(nil, "OVERLAY")
    dispelIndicator.glow:SetTexture("Interface\\Buttons\\UI-ActionButton-Border")
    dispelIndicator.glow:SetBlendMode("ADD")
    dispelIndicator.glow:SetPoint("CENTER")
    dispelIndicator.glow:SetSize(44, 44)
    dispelIndicator.glow:SetAlpha(0)

    dispelIndicator.glowAnim = dispelIndicator.glow:CreateAnimationGroup()
    local glowIn = dispelIndicator.glowAnim:CreateAnimation("Alpha")
    glowIn:SetFromAlpha(0.25); glowIn:SetToAlpha(0.85)
    glowIn:SetDuration(0.6); glowIn:SetSmoothing("IN_OUT")
    local glowOut = dispelIndicator.glowAnim:CreateAnimation("Alpha")
    glowOut:SetFromAlpha(0.85); glowOut:SetToAlpha(0.25)
    glowOut:SetDuration(0.6); glowOut:SetSmoothing("IN_OUT")
    glowOut:SetOrder(2)
    dispelIndicator.glowAnim:SetLooping("REPEAT")

    frame.dispelIndicator = dispelIndicator
    -- Debug logging removed.
    
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
    
    EnsureTargetRangeTicker(frame)
    
    -- Create Aura Container (Buffs)
    frame.auraContainer = CreateFrame("Frame", "MidnightUI_TargetAuraFrame", UIParent)
    frame.auraContainer:SetSize(GetTargetAuraOverlaySize("auras"))
    frame.auraContainer:SetFrameStrata("MEDIUM")
    frame.auraContainer:SetFrameLevel(15)
    frame.auraContainer:SetMovable(true)
    frame.auraContainer:SetClampedToScreen(true)
    frame.auraContainer.parentFrame = frame
    -- Set initial position relative to target frame
    frame.auraContainer:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 20)
    
    -- Create Debuff Container
    frame.debuffContainer = CreateFrame("Frame", "MidnightUI_TargetDebuffFrame", UIParent)
    frame.debuffContainer:SetSize(GetTargetAuraOverlaySize("debuffs"))
    frame.debuffContainer:SetFrameStrata("MEDIUM")
    frame.debuffContainer:SetFrameLevel(15)
    frame.debuffContainer:SetMovable(true)
    frame.debuffContainer:SetClampedToScreen(true)
    frame.debuffContainer.parentFrame = frame
    -- Set initial position relative to target frame
    frame.debuffContainer:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 20)
    
    frame:Hide()
    return frame
end

-- =========================================================================
--  TARGET OF TARGET FRAME
-- =========================================================================

local totConfig = {
    width = 200,
    height = 36,
    healthHeight = 22,
    powerHeight = 10,
    spacing = 1,
}

local TOT_HAZARD_ENUM = {
    None = 0,
    Magic = 1,
    Curse = 2,
    Disease = 3,
    Poison = 4,
    Enrage = 9,
    Bleed = 11,
    Unknown = 99,
}
local TOT_HAZARD_LABELS = {
    [TOT_HAZARD_ENUM.None] = "NONE",
    [TOT_HAZARD_ENUM.Magic] = "MAGIC",
    [TOT_HAZARD_ENUM.Curse] = "CURSE",
    [TOT_HAZARD_ENUM.Disease] = "DISEASE",
    [TOT_HAZARD_ENUM.Poison] = "POISON",
    [TOT_HAZARD_ENUM.Bleed] = "BLEED",
    [TOT_HAZARD_ENUM.Unknown] = "UNKNOWN",
}
local TOT_HAZARD_COLORS = {
    [TOT_HAZARD_ENUM.Magic] = { 0.15, 0.55, 0.95 },
    [TOT_HAZARD_ENUM.Curse] = { 0.70, 0.20, 0.95 },
    [TOT_HAZARD_ENUM.Disease] = { 0.80, 0.50, 0.10 },
    [TOT_HAZARD_ENUM.Poison] = { 0.15, 0.65, 0.20 },
    [TOT_HAZARD_ENUM.Bleed] = { 0.95, 0.15, 0.15 },
    [TOT_HAZARD_ENUM.Unknown] = { 0.64, 0.19, 0.79 },
}
-- Keep debuff tint at full strength so target-of-target bars visibly switch to
-- the debuff color instead of appearing as a darkened overlay.
local TOT_DEBUFF_TINT_BASE_MUL = 1.00
local TOT_HAZARD_STICKY_SEC = 8
local TOT_DEBUFF_PREVIEW = {
    iconSize = 12,
    maxIcons = 2,
    offsetY = 0,
    placeholderIcon = 134400,
}

local TOT_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS = {
    [57723] = true,  -- Exhaustion
    [57724] = true,  -- Sated
    [80354] = true,  -- Temporal Displacement
    [95809] = true,  -- Insanity
    [264689] = true, -- Fatigued
    [209258] = true, -- Last Resort
    [209261] = true, -- Last Resort (cooldown lockout variant)
}

local TOT_IGNORED_LOCKOUT_DEBUFF_NAMES = {
    ["exhaustion"] = true,
    ["sated"] = true,
    ["temporal displacement"] = true,
    ["insanity"] = true,
    ["fatigued"] = true,
    ["last resort"] = true,
}

local function IsToTDiagConsoleEnabled()
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

local function IsToTPreviewDiagEnabled()
    if not IsTargetDebugEnabled() then
        return false
    end
    local s = MidnightUISettings
    -- Keep ToT preview diagnostics opt-in only so TargetFrame debug can remain
    -- available without TargetOfTargetDebuffPreview spam.
    return s
        and s.TargetFrame
        and s.TargetFrame.targetOfTargetDebuffPreviewDebug == true
end

local function ToTDiag(msg)
    if not IsToTPreviewDiagEnabled() then
        return
    end
    local text = SafeToString(msg or "")
    local src = "TargetOfTargetDebuffPreview"
    if IsToTDiagConsoleEnabled() then
        pcall(_G.MidnightUI_Diagnostics.LogDebugSource, src, text)
        return
    end
    _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
    table.insert(_G.MidnightUI_DiagnosticsQueue, "[" .. src .. "] " .. text)
end

local function CoerceToTTintChannel(val)
    if IsSecretValue(val) then
        return nil
    end
    local okNum, num = pcall(function() return val + 0 end)
    if not okNum or type(num) ~= "number" then
        return nil
    end
    if num < 0 then num = 0 end
    if num > 1 then num = 1 end
    return num
end

local function CloneToTColor(color)
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

local function IsToTSecretColor(color)
    return type(color) == "table" and color.secret == true
end

local function ParseToTRGBText(text)
    if type(text) ~= "string" then
        return nil, nil, nil
    end
    if IsSecretValue(text) then
        return nil, nil, nil
    end
    local lower = string.lower(text)
    if string.find(lower, "secret", 1, true) then
        return nil, nil, nil
    end
    local r, g, b = string.match(text, "([%d%.%-]+)%s*,%s*([%d%.%-]+)%s*,%s*([%d%.%-]+)")
    r = CoerceToTTintChannel(r)
    g = CoerceToTTintChannel(g)
    b = CoerceToTTintChannel(b)
    if r == nil or g == nil or b == nil then
        return nil, nil, nil
    end
    return r, g, b
end

local function NormalizeToTHazardEnum(value)
    if value == nil then
        return nil
    end
    if IsSecretValue(value) then
        return TOT_HAZARD_ENUM.Unknown
    end
    if type(value) == "number" then
        if TOT_HAZARD_LABELS[value] then
            return value
        end
        return nil
    end
    if type(value) ~= "string" then
        return nil
    end
    local upper = string.upper(value)
    if upper == "MAGIC" then return TOT_HAZARD_ENUM.Magic end
    if upper == "CURSE" then return TOT_HAZARD_ENUM.Curse end
    if upper == "DISEASE" then return TOT_HAZARD_ENUM.Disease end
    if upper == "POISON" then return TOT_HAZARD_ENUM.Poison end
    if upper == "BLEED" then return TOT_HAZARD_ENUM.Bleed end
    if upper == "ENRAGE" then return TOT_HAZARD_ENUM.Enrage end
    if upper == "UNKNOWN" or upper == "SECRET" then return TOT_HAZARD_ENUM.Unknown end
    return nil
end

local function GetToTHazardLabel(enum)
    return TOT_HAZARD_LABELS[NormalizeToTHazardEnum(enum) or TOT_HAZARD_ENUM.None] or "NONE"
end

local function GetToTHazardColor(enum)
    return TOT_HAZARD_COLORS[NormalizeToTHazardEnum(enum) or TOT_HAZARD_ENUM.Unknown]
end

local function NormalizeToTLockoutName(name)
    if type(name) ~= "string" or IsSecretValue(name) then
        return nil
    end
    local okLower, lower = pcall(string.lower, name)
    if not okLower or type(lower) ~= "string" then
        return nil
    end
    return lower
end

local function ResolveToTLockoutSpellID(value)
    if value == nil or IsSecretValue(value) then
        return nil
    end
    local okNum, num = pcall(tonumber, value)
    if not okNum or type(num) ~= "number" or num <= 0 then
        return nil
    end
    return num
end

local function ShouldIgnoreToTLockoutDebuff(aura)
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

    local spellID = ResolveToTLockoutSpellID(aura.spellId)
        or ResolveToTLockoutSpellID(aura.spellID)
        or ResolveToTLockoutSpellID(aura.id)
    if spellID and TOT_IGNORED_LOCKOUT_DEBUFF_SPELL_IDS[spellID] then
        return true
    end

    local nameKey = NormalizeToTLockoutName(aura.name)
        or NormalizeToTLockoutName(aura.auraName)
        or NormalizeToTLockoutName(aura.spellName)
    if nameKey and TOT_IGNORED_LOCKOUT_DEBUFF_NAMES[nameKey] then
        return true
    end
    return false
end

local function IsToTQuestionMarkToken(iconToken)
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

local function CanUseToTIconToken(iconToken)
    if iconToken == nil then
        return false
    end
    if IsSecretValue(iconToken) then
        return true
    end
    local tokenType = type(iconToken)
    if tokenType == "number" then
        if iconToken == TOT_DEBUFF_PREVIEW.placeholderIcon then
            return false
        end
        return iconToken > 0
    end
    if tokenType == "string" then
        if iconToken == "" or IsToTQuestionMarkToken(iconToken) then
            return false
        end
        return true
    end
    return false
end

local function NormalizeToTAuraStackCount(value)
    if value == nil or IsSecretValue(value) then
        return ""
    end
    local number = tonumber(value)
    if type(number) ~= "number" or IsSecretValue(number) then
        return ""
    end
    number = math.floor(number + 0.5)
    if number <= 1 then
        return ""
    end
    return tostring(number)
end

local function GetToTHazardIconAtlas(enum)
    local normalized = NormalizeToTHazardEnum(enum)
    if normalized == TOT_HAZARD_ENUM.Magic then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Magic"
    elseif normalized == TOT_HAZARD_ENUM.Curse then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Curse"
    elseif normalized == TOT_HAZARD_ENUM.Disease then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Disease"
    elseif normalized == TOT_HAZARD_ENUM.Poison then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Poison"
    elseif normalized == TOT_HAZARD_ENUM.Bleed then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Bleed"
    elseif normalized == TOT_HAZARD_ENUM.Unknown then
        return "UI-HUD-UnitFrame-Player-PortraitOn-Bar-Dispel-Magic"
    end
    return nil
end

local function SetToTIconTexCoord(texture, usingAtlas)
    if not texture or not texture.SetTexCoord then
        return
    end
    if usingAtlas then
        texture:SetTexCoord(0, 1, 0, 1)
    else
        texture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local function IsToTUnitPlayer(unit)
    if unit == "player" then
        return true
    end
    if type(unit) ~= "string" or type(UnitIsUnit) ~= "function" then
        return false
    end
    local ok, same = pcall(UnitIsUnit, unit, "player")
    return ok and same == true
end

local function GetToTHintFromPlayerFrameCondTint(unit)
    if not IsToTUnitPlayer(unit) then
        return nil, nil, "non-player-unit"
    end
    local pf = _G.MidnightUI_PlayerFrame
    if not pf or pf._muiCondTintActive ~= true then
        return nil, nil, "playerframe-condtint-off"
    end
    local enum = NormalizeToTHazardEnum(pf._muiCondTintSource)
    local secretColor = nil
    if pf._muiCondTintSecret == true and pf._muiCondTintHasColor == true then
        local sr, sg, sb = pf._muiCondTintR, pf._muiCondTintG, pf._muiCondTintB
        if sr ~= nil and sg ~= nil and sb ~= nil then
            secretColor = { sr, sg, sb, secret = true }
        end
    end
    if enum and enum ~= TOT_HAZARD_ENUM.Unknown then
        if secretColor then
            return enum, secretColor, "playerframe-condtint-enum-secret"
        end
        local r = CoerceToTTintChannel(pf._muiCondTintR)
        local g = CoerceToTTintChannel(pf._muiCondTintG)
        local b = CoerceToTTintChannel(pf._muiCondTintB)
        if r ~= nil and g ~= nil and b ~= nil then
            return enum, { r, g, b }, "playerframe-condtint-enum"
        end
        return enum, GetToTHazardColor(enum), "playerframe-condtint-enum-fallback"
    end
    if secretColor then
        return TOT_HAZARD_ENUM.Unknown, secretColor, "playerframe-condtint-secret"
    end
    local r = CoerceToTTintChannel(pf._muiCondTintR)
    local g = CoerceToTTintChannel(pf._muiCondTintG)
    local b = CoerceToTTintChannel(pf._muiCondTintB)
    if r ~= nil and g ~= nil and b ~= nil then
        return TOT_HAZARD_ENUM.Unknown, { r, g, b }, "playerframe-condtint-unknown"
    end
    return nil, nil, "playerframe-condtint-none"
end

local function GetToTSecondaryHintFromConditionBorder(unit)
    if not IsToTUnitPlayer(unit) then
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
    local enum = NormalizeToTHazardEnum(state.overlapSecondaryEnum)
        or NormalizeToTHazardEnum(state.activeSecondaryEnum)
        or NormalizeToTHazardEnum(state.typeBoxEnum)
    local color = nil
    if state.typeBoxR ~= nil and state.typeBoxG ~= nil and state.typeBoxB ~= nil then
        if IsSecretValue(state.typeBoxR) or IsSecretValue(state.typeBoxG) or IsSecretValue(state.typeBoxB) then
            color = { state.typeBoxR, state.typeBoxG, state.typeBoxB, secret = true }
        else
            local r = CoerceToTTintChannel(state.typeBoxR)
            local g = CoerceToTTintChannel(state.typeBoxG)
            local b = CoerceToTTintChannel(state.typeBoxB)
            if r ~= nil and g ~= nil and b ~= nil then
                color = { r, g, b }
            end
        end
    end
    if not color then
        local r, g, b = ParseToTRGBText(state.typeBoxRGB)
        if r ~= nil and g ~= nil and b ~= nil then
            color = { r, g, b }
        end
    end
    return enum, color, "condborder-secondary"
end

local function ShouldAllowToTUnknownPrimaryTint(unit)
    if not IsToTUnitPlayer(unit) then
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

    local enum = NormalizeToTHazardEnum(state.primaryEnum)
        or NormalizeToTHazardEnum(state.activePrimaryEnum)
        or NormalizeToTHazardEnum(state.curvePrimaryEnum)
        or NormalizeToTHazardEnum(state.overlapPrimaryEnum)
        or NormalizeToTHazardEnum(state.hookPrimaryEnum)
        or NormalizeToTHazardEnum(state.barTintEnum)
    if enum and enum ~= TOT_HAZARD_ENUM.Unknown then
        return true, "condborder-primary-enum"
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

local function EnsureTargetOfTargetDebuffPreviewWidgets(frame)
    if not frame then
        return nil
    end
    if frame._muiTargetOfTargetDebuffPreview then
        return frame._muiTargetOfTargetDebuffPreview
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
    local B_LEN = 10
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
    sweepFx:SetSize(48, 88)
    sweepFx:SetPoint("CENTER", sweep, "LEFT", -48, 0)

    local function CreateSweepBand(isReverse)
        local tex = sweepFx:CreateTexture(nil, "OVERLAY")
        tex:SetPoint("TOP", sweepFx, "TOP", 0, 0)
        tex:SetPoint("BOTTOM", sweepFx, "BOTTOM", 0, 0)
        tex:SetWidth(12)
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
    sweepMoveAnim:SetOffset(140, 0)
    sweepMoveAnim:SetDuration(1.12)
    sweepMoveAnim:SetSmoothing("IN_OUT")

    local iconHolder = CreateFrame("Frame", nil, frame)
    iconHolder:SetFrameStrata(frame:GetFrameStrata())
    iconHolder:SetFrameLevel(frame:GetFrameLevel() + 30)
    iconHolder:SetPoint("RIGHT", frame, "RIGHT", -2, TOT_DEBUFF_PREVIEW.offsetY)
    iconHolder:SetSize((TOT_DEBUFF_PREVIEW.iconSize + 2) * TOT_DEBUFF_PREVIEW.maxIcons, TOT_DEBUFF_PREVIEW.iconSize + 2)
    iconHolder:Hide()

    local function CreateIconButton(index)
        local btn = CreateFrame("Frame", nil, iconHolder, "BackdropTemplate")
        btn:SetSize(TOT_DEBUFF_PREVIEW.iconSize, TOT_DEBUFF_PREVIEW.iconSize)
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
        SetToTIconTexCoord(icon, false)
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
    for i = 1, TOT_DEBUFF_PREVIEW.maxIcons do
        local btn = CreateIconButton(i)
        btn:SetPoint("RIGHT", iconHolder, "RIGHT", -((i - 1) * (TOT_DEBUFF_PREVIEW.iconSize + 2)), 0)
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
    frame._muiTargetOfTargetDebuffPreview = preview
    return preview
end

local function SetToTHPTextInset(frame, inset)
    if not frame or not frame.healthText then
        return
    end
    local right = -6 - (tonumber(inset) or 0)
    frame.healthText:ClearAllPoints()
    frame.healthText:SetPoint("RIGHT", frame.healthContainer or frame, "RIGHT", right, 0)
end

local function RestoreToTBaseBarTint(frame)
    if not frame or not UnitExists("targettarget") then
        return
    end

    local hr, hg, hb = GetUnitColor("targettarget")
    if frame.healthBar then
        frame.healthBar:SetStatusBarColor(hr, hg, hb, 1.0)
        local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
        if hTex and hTex.SetVertexColor then
            hTex:SetVertexColor(hr, hg, hb, 1.0)
        end
    end
    if frame.healthBg and frame.healthBg.SetColorTexture then
        frame.healthBg:SetColorTexture(hr * 0.15, hg * 0.15, hb * 0.15, 0.6)
    end

    if frame.powerBar then
        local powerType, powerToken = UnitPowerType("targettarget")
        local token = powerToken or "MANA"
        local powerColor = POWER_COLORS[token] or DEFAULT_POWER_COLOR
        frame.powerBar:SetStatusBarColor(powerColor[1], powerColor[2], powerColor[3], 1.0)
        local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
        if pTex and pTex.SetVertexColor then
            pTex:SetVertexColor(powerColor[1], powerColor[2], powerColor[3], 1.0)
        end
    end

    if frame.border and frame.border.SetBackdropBorderColor then
        frame.border:SetBackdropBorderColor(0, 0, 0, 1)
    end
end

local function ClearTargetOfTargetDebuffPreview(frame)
    if not frame or not frame._muiTargetOfTargetDebuffPreview then
        return
    end
    local preview = frame._muiTargetOfTargetDebuffPreview
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
    SetToTHPTextInset(frame, 0)
    frame._muiToTDebuffStickyAt = nil
    frame._muiToTDebuffStickyPrimary = nil
    frame._muiToTDebuffStickyColor = nil
    RestoreToTBaseBarTint(frame)
end

local function LayoutTargetOfTargetDebuffSweep(preview, frame)
    if not preview or not frame or not preview.sweep or not preview.sweepFx then
        return
    end
    preview.sweep:ClearAllPoints()
    preview.sweep:SetAllPoints(preview.overlay or frame)

    local width = tonumber(frame:GetWidth()) or tonumber(totConfig.width) or 200
    local height = tonumber(frame:GetHeight()) or tonumber(totConfig.height) or 36
    local beamW = math.max(math.floor(width * 0.30 + 0.5), 40)
    local beamH = math.max(math.floor(height * 2.2 + 0.5), 72)
    local moveDistance = width + (beamW * 2.7)
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
        math.max(math.floor(beamW * 1.12 + 0.5), 20),
        beamW,
        math.max(math.floor(beamW * 0.84 + 0.5), 16),
        math.max(math.floor(beamW * 0.68 + 0.5), 12),
        math.max(math.floor(beamW * 0.54 + 0.5), 10),
        math.max(math.floor(beamW * 0.40 + 0.5), 8),
        math.max(math.floor(beamW * 0.28 + 0.5), 6),
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
        preview.sweepMoveAnim:SetDuration(1.12)
        preview.sweepMoveAnim:SetSmoothing("IN_OUT")
    end
    if preview.sweepMoveGroup and preview.sweepMoveGroup:IsPlaying() then
        preview.sweepMoveGroup:Stop()
        preview.sweepMoveGroup:Play()
    end
end

local function SetTargetOfTargetDebuffSweepColor(preview, enum, overrideColor)
    if not preview or not preview.sweepBands then
        return
    end
    local color = overrideColor
    if type(color) ~= "table" then
        color = GetToTHazardColor(enum) or TOT_HAZARD_COLORS[TOT_HAZARD_ENUM.Unknown]
    end
    if not color then
        return
    end
    local normalized = NormalizeToTHazardEnum(enum)
    local bandAlpha = { 0.022, 0.036, 0.052, 0.074, 0.104, 0.142, 0.188 }
    if IsToTSecretColor(color) then
        bandAlpha = { 0.018, 0.030, 0.044, 0.062, 0.086, 0.118, 0.156 }
    elseif normalized == TOT_HAZARD_ENUM.Unknown then
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

local function SetTargetOfTargetDebuffSweepVisible(preview, isVisible)
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

local function CollectTargetOfTargetDebuffPreviewState(unit)
    local state = {
        unit = SafeToString(unit or "nil"),
        inRestricted = (InCombatLockdown and InCombatLockdown()) and "YES" or "NO",
        primary = nil,
        secondary = nil,
        entries = {},
        scanned = 0,
        typed = 0,
        ignored = 0,
        totalDebuffs = 0,
        sweep = "OFF",
        sweepSource = "none",
        sweepRGB = "none",
    }
    local typedOrder = {}
    local typedSeen = {}

    local function AddEntry(iconToken, enum, auraIID, auraIndex, stackCount)
        local hasIcon = CanUseToTIconToken(iconToken)
        if (#state.entries < TOT_DEBUFF_PREVIEW.maxIcons) and (hasIcon or enum) then
            state.entries[#state.entries + 1] = {
                icon = hasIcon and iconToken or nil,
                enum = NormalizeToTHazardEnum(enum),
                auraInstanceID = auraIID,
                auraIndex = auraIndex,
                stackCount = stackCount,
            }
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
        if ShouldIgnoreToTLockoutDebuff(aura) then
            state.ignored = state.ignored + 1
        else
            state.totalDebuffs = state.totalDebuffs + 1
            local enum = NormalizeToTHazardEnum(aura.debuffType)
                or NormalizeToTHazardEnum(aura.dispelName)
                or NormalizeToTHazardEnum(aura.dispelType)
                or NormalizeToTHazardEnum(aura.type)
            if enum and enum ~= TOT_HAZARD_ENUM.Unknown then
                state.typed = state.typed + 1
                if not typedSeen[enum] then
                    typedSeen[enum] = true
                    typedOrder[#typedOrder + 1] = enum
                end
            end
            AddEntry(
                aura.icon,
                enum,
                aura.auraInstanceID,
                i,
                aura.applications or aura.stackCount or aura.count
            )
        end
    end

    if #typedOrder >= 1 then
        state.primary = typedOrder[1]
    elseif state.totalDebuffs > 0 then
        state.primary = TOT_HAZARD_ENUM.Unknown
    end
    if #typedOrder >= 2 then
        state.secondary = typedOrder[2]
    elseif state.totalDebuffs > 1 then
        state.secondary = TOT_HAZARD_ENUM.Unknown
    end
    return state
end

local function ApplyToTDebuffStickyFallback(frame, primaryEnum, primaryColor, inRestricted)
    local now = (GetTime and GetTime()) or 0
    local normalized = NormalizeToTHazardEnum(primaryEnum)
    if normalized and normalized ~= TOT_HAZARD_ENUM.Unknown and type(primaryColor) == "table" then
        frame._muiToTDebuffStickyAt = now
        frame._muiToTDebuffStickyPrimary = normalized
        frame._muiToTDebuffStickyColor = CloneToTColor(primaryColor)
        return normalized, primaryColor, false
    end
    if inRestricted ~= "YES" then
        return normalized, primaryColor, false
    end
    local stickyAt = tonumber(frame._muiToTDebuffStickyAt) or 0
    local stickyPrimary = NormalizeToTHazardEnum(frame._muiToTDebuffStickyPrimary)
    local stickyColor = CloneToTColor(frame._muiToTDebuffStickyColor)
    if stickyPrimary and stickyColor and stickyAt > 0 and (now - stickyAt) <= TOT_HAZARD_STICKY_SEC then
        return stickyPrimary, stickyColor, true
    end
    return normalized, primaryColor, false
end

local function FormatToTColorForDiag(color)
    if type(color) ~= "table" then
        return "none"
    end
    if IsToTSecretColor(color) then
        return "secret"
    end
    local r = CoerceToTTintChannel(color[1])
    local g = CoerceToTTintChannel(color[2])
    local b = CoerceToTTintChannel(color[3])
    if r == nil or g == nil or b == nil then
        return "none"
    end
    return string.format("%.3f,%.3f,%.3f", r, g, b)
end

local function BuildToTLiveDiagMessage(state, source)
    return table.concat({
        "live unit=" .. tostring(state and state.unit or "nil"),
        "restricted=" .. tostring(state and state.inRestricted or "NO"),
        "primary=" .. GetToTHazardLabel(state and state.primary),
        "primarySrc=" .. tostring((state and state.primarySource) or "none"),
        "primaryRGB=" .. tostring((state and state.primaryRGB) or "none"),
        "secondary=" .. GetToTHazardLabel(state and state.secondary),
        "scanned=" .. tostring((state and state.scanned) or 0),
        "typed=" .. tostring((state and state.typed) or 0),
        "ignored=" .. tostring((state and state.ignored) or 0),
        "totalDebuffs=" .. tostring((state and state.totalDebuffs) or 0),
        "icons=" .. tostring((state and state.entries and #state.entries) or 0),
        "sweep=" .. tostring((state and state.sweep) or "OFF"),
        "sweepSrc=" .. tostring((state and state.sweepSource) or "none"),
        "sweepRGB=" .. tostring((state and state.sweepRGB) or "none"),
        "src=" .. SafeToString(source or "unknown"),
    }, " ")
end

local function ApplyTargetOfTargetDebuffPreviewState(frame, state)
    local preview = EnsureTargetOfTargetDebuffPreviewWidgets(frame)
    if not preview then
        return
    end

    local unit = "targettarget"
    if not UnitExists(unit) then
        ClearTargetOfTargetDebuffPreview(frame)
        return
    end

    local totalDebuffs = (state and state.totalDebuffs) or 0
    local typedDebuffs = (state and state.typed) or 0
    if totalDebuffs <= 0 then
        ClearTargetOfTargetDebuffPreview(frame)
        return
    end

    local primary = state and state.primary
    local secondary = state and state.secondary
    local inRestricted = state and state.inRestricted or "NO"

    local primaryColor = nil
    local primarySource = "PRIMARY_ENUM"
    if primary then
        primaryColor = GetToTHazardColor(primary)
    end
    if inRestricted == "YES"
        and typedDebuffs == 0
        and totalDebuffs > 0
        and NormalizeToTHazardEnum(primary) == TOT_HAZARD_ENUM.Unknown then
        local allowUnknown, allowSource = ShouldAllowToTUnknownPrimaryTint(unit)
        if not allowUnknown then
            state.primary = nil
            state.secondary = nil
            state.primarySource = SafeToString(allowSource or "condborder-no-primary")
            state.primaryRGB = "none"
            state.sweep = "OFF"
            state.sweepSource = "none"
            state.sweepRGB = "none"
            ClearTargetOfTargetDebuffPreview(frame)
            return
        end
    end
    if inRestricted == "YES"
        and (state and (state.typed or 0) == 0)
        and (state and (state.totalDebuffs or 0) > 0)
        and (
            not primaryColor
            or NormalizeToTHazardEnum(primary) == TOT_HAZARD_ENUM.Unknown
        ) then
        local hintedPrimary, hintedColor, hintSource = GetToTHintFromPlayerFrameCondTint(unit)
        if hintedColor then
            primary = NormalizeToTHazardEnum(hintedPrimary) or primary or TOT_HAZARD_ENUM.Unknown
            primaryColor = hintedColor
            primarySource = SafeToString(hintSource or "playerframe-condtint")
        end
    end
    if not primaryColor and (state and (state.totalDebuffs or 0) > 0) then
        primary = TOT_HAZARD_ENUM.Unknown
        primaryColor = GetToTHazardColor(TOT_HAZARD_ENUM.Unknown)
        primarySource = "UNKNOWN_FALLBACK"
    end

    local stickyApplied
    primary, primaryColor, stickyApplied = ApplyToTDebuffStickyFallback(frame, primary, primaryColor, inRestricted)
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
        ClearTargetOfTargetDebuffPreview(frame)
        return
    end

    local hasOverlap = (totalDebuffs > 1) or (secondary ~= nil and secondary ~= primary)
    local secondaryColor = nil
    if hasOverlap then
        secondaryColor = GetToTHazardColor(secondary)
        if (not secondaryColor) or NormalizeToTHazardEnum(secondary) == TOT_HAZARD_ENUM.Unknown then
            local _, hintSecondaryColor = GetToTSecondaryHintFromConditionBorder(unit)
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

    LayoutTargetOfTargetDebuffSweep(preview, frame)
    if hasOverlap and secondaryColor then
        SetTargetOfTargetDebuffSweepColor(preview, secondary or primary, secondaryColor)
        SetTargetOfTargetDebuffSweepVisible(preview, true)
        state.sweep = "ON"
        if secondary and NormalizeToTHazardEnum(secondary) ~= TOT_HAZARD_ENUM.Unknown then
            state.sweepSource = "SECONDARY_ENUM"
        elseif IsToTSecretColor(secondaryColor) then
            state.sweepSource = "SECRET_FALLBACK"
        else
            state.sweepSource = "PRIMARY_FALLBACK"
        end
        state.sweepRGB = FormatToTColorForDiag(secondaryColor)
    else
        SetTargetOfTargetDebuffSweepVisible(preview, false)
        state.sweep = "OFF"
        state.sweepSource = "none"
        state.sweepRGB = "none"
    end

    local entries = (state and state.entries) or {}
    local shownIcons = 0
    local totalEntries = (type(entries) == "table") and #entries or 0
    local frameWidth = tonumber(frame.GetWidth and frame:GetWidth()) or tonumber(totConfig.width) or 200
    local iconSize = TOT_DEBUFF_PREVIEW.iconSize
    local maxVisibleIcons = TOT_DEBUFF_PREVIEW.maxIcons
    if frameWidth <= 170 then
        iconSize = 11
        maxVisibleIcons = 1
    elseif frameWidth <= 210 then
        iconSize = 12
        maxVisibleIcons = 2
    end
    if maxVisibleIcons > TOT_DEBUFF_PREVIEW.maxIcons then
        maxVisibleIcons = TOT_DEBUFF_PREVIEW.maxIcons
    end
    local iconsToShow = math.min(totalEntries, maxVisibleIcons, TOT_DEBUFF_PREVIEW.maxIcons)
    local overflowCount = math.max(0, totalEntries - iconsToShow)

    if preview.iconButtons then
        for i = 1, TOT_DEBUFF_PREVIEW.maxIcons do
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
                    local stackText = NormalizeToTAuraStackCount(entry.stackCount)
                    if overflowCount > 0 and i == iconsToShow then
                        stackText = "+" .. tostring(overflowCount)
                    end
                    btn.countText:SetText(stackText)
                end

                local appliedAtlas = false
                local iconToken = entry.icon
                if CanUseToTIconToken(iconToken) then
                    if btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(iconToken)
                        SetToTIconTexCoord(btn.icon, false)
                    end
                else
                    local atlas = GetToTHazardIconAtlas(entry.enum or primary)
                    if atlas and btn.icon and btn.icon.SetAtlas then
                        local okAtlas = pcall(btn.icon.SetAtlas, btn.icon, atlas, false)
                        if okAtlas then
                            SetToTIconTexCoord(btn.icon, true)
                            appliedAtlas = true
                        end
                    end
                    if not appliedAtlas and btn.icon and btn.icon.SetTexture then
                        btn.icon:SetTexture(TOT_DEBUFF_PREVIEW.placeholderIcon)
                        SetToTIconTexCoord(btn.icon, false)
                    end
                end

                local iconColor = GetToTHazardColor(entry.enum or primary)
                if IsToTSecretColor(primaryColor) then
                    local entryEnum = NormalizeToTHazardEnum(entry.enum)
                    if (not entryEnum) or entryEnum == TOT_HAZARD_ENUM.Unknown then
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
            SetToTHPTextInset(frame, stripWidth + 2)
        else
            preview.iconHolder:Hide()
            SetToTHPTextInset(frame, 0)
        end
    end

    if frame.healthBar and frame.powerBar then
        if IsToTSecretColor(primaryColor) then
            frame.healthBar:SetStatusBarColor(TOT_DEBUFF_TINT_BASE_MUL, TOT_DEBUFF_TINT_BASE_MUL, TOT_DEBUFF_TINT_BASE_MUL, 1.0)
            frame.powerBar:SetStatusBarColor(TOT_DEBUFF_TINT_BASE_MUL, TOT_DEBUFF_TINT_BASE_MUL, TOT_DEBUFF_TINT_BASE_MUL, 1.0)
            local hTex = frame.healthBar.GetStatusBarTexture and frame.healthBar:GetStatusBarTexture()
            local pTex = frame.powerBar.GetStatusBarTexture and frame.powerBar:GetStatusBarTexture()
            if hTex and hTex.SetVertexColor then
                hTex:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 1.0)
            end
            if pTex and pTex.SetVertexColor then
                pTex:SetVertexColor(primaryColor[1], primaryColor[2], primaryColor[3], 1.0)
            end
            if frame.healthBg and frame.healthBg.SetColorTexture then
                -- Secret colors cannot be safely arithmetic'd; use neutral dark base.
                frame.healthBg:SetColorTexture(0.08, 0.08, 0.08, 0.6)
            end
        else
            local hr = primaryColor[1] * TOT_DEBUFF_TINT_BASE_MUL
            local hg = primaryColor[2] * TOT_DEBUFF_TINT_BASE_MUL
            local hb = primaryColor[3] * TOT_DEBUFF_TINT_BASE_MUL
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
            if frame.healthBg and frame.healthBg.SetColorTexture then
                frame.healthBg:SetColorTexture(primaryColor[1] * 0.12, primaryColor[2] * 0.12, primaryColor[3] * 0.12, 0.6)
            end
        end
    end

    state.primary = primary
    state.secondary = secondary
    state.primarySource = primarySource
    state.primaryRGB = FormatToTColorForDiag(primaryColor)
end

local function UpdateTargetOfTargetDebuffPreview(frame, source)
    if not frame then
        return
    end
    if not IsTargetOfTargetDebuffOverlayEnabled() then
        ClearTargetOfTargetDebuffPreview(frame)
        frame._muiToTDebuffLiveSig = nil
        return
    end
    if not UnitExists("targettarget") then
        ClearTargetOfTargetDebuffPreview(frame)
        frame._muiToTDebuffLiveSig = nil
        return
    end

    local okCollect, state = pcall(CollectTargetOfTargetDebuffPreviewState, "targettarget")
    if not okCollect then
        ToTDiag("collectError unit=targettarget src=" .. SafeToString(source or "unknown") .. " err=" .. SafeToString(state))
        return
    end
    local okApply, applyErr = pcall(ApplyTargetOfTargetDebuffPreviewState, frame, state)
    if not okApply then
        ToTDiag("applyError unit=targettarget src=" .. SafeToString(source or "unknown") .. " err=" .. SafeToString(applyErr))
        return
    end

    local msg = BuildToTLiveDiagMessage(state, source)
    if frame._muiToTDebuffLiveSig ~= msg then
        frame._muiToTDebuffLiveSig = msg
        ToTDiag(msg)
    end
end

local function CreateTargetOfTargetFrame()
    local totS = EnsureTargetOfTargetSettings()
    local frame = CreateFrame("Button", "MidnightUI_TargetOfTargetFrame", UIParent, "SecureUnitButtonTemplate, BackdropTemplate")
    frame:SetSize(totConfig.width, totConfig.height)
    frame:SetAttribute("unit", "targettarget")
    frame:SetAttribute("type1", "target")
    frame:SetAttribute("*type2", "togglemenu")
    frame:RegisterForClicks("AnyUp")
    -- Prevent SecureUnitButtonTemplate hover/pushed highlights from adding a colored ring.
    if frame.SetHighlightTexture and frame.GetHighlightTexture then
        frame:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
        local ht = frame:GetHighlightTexture()
        if ht then
            ht:SetVertexColor(0, 0, 0, 0)
            ht:SetAlpha(0)
        end
    end
    if frame.SetPushedTexture and frame.GetPushedTexture then
        frame:SetPushedTexture("Interface\\Buttons\\WHITE8X8")
        local pt = frame:GetPushedTexture()
        if pt then
            pt:SetVertexColor(0, 0, 0, 0)
            pt:SetAlpha(0)
        end
    end

    -- Use RegisterUnitWatch so the game engine handles visibility during combat
    -- This allows the frame to show/hide automatically based on unit existence
    RegisterUnitWatch(frame)

    frame:SetFrameStrata("MEDIUM")
    frame:SetFrameLevel(8)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    local scaleVal = (totS.scale or 100) / 100
    if scaleVal <= 0 then scaleVal = 1 end
    frame:SetScale(scaleVal)
    frame:SetAlpha(totS.alpha or 0.95)
    
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        if UnitExists("targettarget") then
            GameTooltip:SetUnit("targettarget")
        end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function(self) GameTooltip:Hide() end)
    
    -- Background and Border
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
    local border = CreateFrame("Frame", nil, frame, "BackdropTemplate")
    border:SetAllPoints()
    border:SetFrameStrata(frame:GetFrameStrata())
    border:SetFrameLevel(frame:GetFrameLevel() + 2)
    border:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 },
    })
    border:SetBackdropBorderColor(0, 0, 0, 1)
    frame.border = border
    frame.shadows = CreateDropShadow(frame, 2)
    
    -- HEALTH
    local healthContainer = CreateFrame("Frame", nil, frame)
    healthContainer:SetPoint("TOPLEFT", frame, "TOPLEFT", 1, -1)
    healthContainer:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -1, -1)
    healthContainer:SetHeight(totConfig.healthHeight)
    frame.healthContainer = healthContainer
    
    local healthBg = healthContainer:CreateTexture(nil, "BACKGROUND")
    healthBg:SetAllPoints()
    healthBg:SetColorTexture(0.1, 0.1, 0.1, 1)
    frame.healthBg = healthBg
    
    local healthBar = CreateFrame("StatusBar", nil, healthContainer)
    healthBar:SetPoint("TOPLEFT", 0, 0)
    healthBar:SetPoint("BOTTOMRIGHT", 0, 0)
    ApplyHealthBarStyle(healthBar)
    healthBar:SetStatusBarColor(0.5, 0.5, 0.5, 1.0)
    healthBar:SetMinMaxValues(0, 1)
    healthBar:SetValue(1)
    frame.healthBar = healthBar
    
    -- TEXT OVERLAY
    local textOverlay = CreateFrame("Frame", nil, healthContainer)
    textOverlay:SetAllPoints()
    textOverlay:SetFrameStrata("MEDIUM")
    textOverlay:SetFrameLevel(healthContainer:GetFrameLevel() + 5)
    
    local nameText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(nameText, "Fonts\\FRIZQT__.TTF", 11, "OUTLINE")
    nameText:SetPoint("CENTER", textOverlay, "CENTER", 0, 0)
    nameText:SetTextColor(1, 1, 1, 1)
    nameText:SetShadowOffset(1, -1)
    nameText:SetShadowColor(0, 0, 0, 1)
    frame.nameText = nameText
    
    local healthText = textOverlay:CreateFontString(nil, "OVERLAY")
    SetFontSafe(healthText, "Fonts\\ARIALN.TTF", 10, "OUTLINE")
    healthText:SetPoint("RIGHT", textOverlay, "RIGHT", -6, 0)
    healthText:SetTextColor(1, 1, 1, 1)
    healthText:SetShadowOffset(1, -1)
    healthText:SetShadowColor(0, 0, 0, 1)
    frame.healthText = healthText
    
    -- POWER
    local powerContainer = CreateFrame("Frame", nil, frame)
    powerContainer:SetPoint("TOPLEFT", healthContainer, "BOTTOMLEFT", 0, -totConfig.spacing)
    powerContainer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -1, 1)
    frame.powerContainer = powerContainer
    
    local powerBg = powerContainer:CreateTexture(nil, "BACKGROUND")
    powerBg:SetAllPoints()
    powerBg:SetColorTexture(0, 0, 0, 0.5)
    frame.powerBg = powerBg
    
    local powerBar = CreateFrame("StatusBar", nil, powerContainer)
    powerBar:SetPoint("TOPLEFT", 0, 0)
    powerBar:SetPoint("BOTTOMRIGHT", 0, 0)
    powerBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    powerBar:GetStatusBarTexture():SetHorizTile(false)
    powerBar:GetStatusBarTexture():SetVertTile(false)
    powerBar:SetStatusBarColor(0.0, 0.5, 1.0, 1.0)
    powerBar:SetMinMaxValues(0, 100)
    powerBar:SetValue(0)
    powerBar:SetFrameLevel(powerContainer:GetFrameLevel() + 2)
    frame.powerBar = powerBar
    
    frame:Hide()
    return frame
end

local function UpdateTargetOfTargetHealth(frame)
    if not frame or not UnitExists("targettarget") then
        if frame then
            frame.healthBar:SetMinMaxValues(0, 1)
            frame.healthBar:SetValue(0)
            frame.nameText:SetText("")
            if frame.healthText then frame.healthText:SetText("") end
        end
        return
    end
    
    local classR, classG, classB = GetUnitColor("targettarget")
    frame.healthBar:SetStatusBarColor(classR, classG, classB, 1.0)
    ApplyHealthBarStyle(frame.healthBar)
    frame.nameText:SetTextColor(classR, classG, classB, 1)
    frame.nameText:SetText(UnitName("targettarget") or "")
    
    if frame.healthBg then
        frame.healthBg:SetColorTexture(classR * 0.15, classG * 0.15, classB * 0.15, 0.6)
    end
    
    local current = UnitHealth("targettarget")
    local max = UnitHealthMax("targettarget")
    
    pcall(function()
        frame.healthBar:SetMinMaxValues(0, max)
        frame.healthBar:SetValue(current)
    end)
    
    -- Display health percentage (inline logic matching PlayerFrame pattern,
    -- since the local helper functions are declared later in this file)
    if frame.healthText then
        local renderedText = nil
        local allowSecret = not _G.MidnightUI_ForceHideHealthPct
            and MidnightUISettings and MidnightUISettings.General
            and MidnightUISettings.General.allowSecretHealthPercent == true

        -- Try UnitHealthPercent first (may return secret values)
        if allowSecret and UnitHealthPercent then
            local scaleTo100 = CurveConstants and CurveConstants.ScaleTo100 or nil
            local ok, pct = pcall(UnitHealthPercent, "targettarget", true, scaleTo100)
            if ok and pct ~= nil then
                local okFmt, text = pcall(function()
                    return string.format("%.0f%%", pct)
                end)
                if okFmt and text then
                    renderedText = text
                end
            end
        end

        -- Fallback: compute from current/max
        if not renderedText then
            local okPct, fallbackPct = pcall(function()
                return (current / max) * 100
            end)
            if okPct and type(fallbackPct) == "number" then
                local okFmt, text = pcall(function()
                    return string.format("%.0f%%", fallbackPct)
                end)
                if okFmt and text then
                    renderedText = text
                end
            end
        end

        if renderedText then
            frame.healthText:SetText(renderedText)
        else
            frame.healthText:SetText("")
        end
    end
end

local function UpdateTargetOfTargetPower(frame)
    if not frame or not UnitExists("targettarget") then
        if frame then
            frame.powerBar:SetMinMaxValues(0, 1)
            frame.powerBar:SetValue(0)
        end
        return
    end
    
    local powerType, powerToken = UnitPowerType("targettarget")
    local token = powerToken or "MANA"
    local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR
    
    frame.powerBar:SetStatusBarColor(color[1], color[2], color[3], 1.0)
    
    local current = UnitPower("targettarget", powerType)
    local max = UnitPowerMax("targettarget", powerType)
    
    pcall(function()
        frame.powerBar:SetMinMaxValues(0, max)
        frame.powerBar:SetValue(current)
    end)
end

local function UpdateTargetOfTargetAll(frame)
    UpdateTargetOfTargetHealth(frame)
    UpdateTargetOfTargetPower(frame)
    UpdateTargetOfTargetDebuffPreview(frame, "UpdateTargetOfTargetAll")
end

local function UpdateTargetOfTargetVisibility()
    if not targetOfTargetFrame then
        targetOfTargetFrame = CreateTargetOfTargetFrame()
        if not targetOfTargetFrame then return end
    end

    local showTot = MidnightUISettings and
                    MidnightUISettings.TargetFrame and
                    MidnightUISettings.TargetFrame.showTargetOfTarget == true

    if not showTot then
        if not SafeInCombatLockdown() then
            UnregisterUnitWatch(targetOfTargetFrame)
            targetOfTargetFrame:Hide()
        end
        ClearTargetOfTargetDebuffPreview(targetOfTargetFrame)
        targetOfTargetFrame._muiToTDebuffLiveSig = nil
        return
    else
        if not SafeInCombatLockdown() then
            RegisterUnitWatch(targetOfTargetFrame)
        end
    end

    if UnitExists("targettarget") then
        UpdateTargetOfTargetAll(targetOfTargetFrame)
    else
        ClearTargetOfTargetDebuffPreview(targetOfTargetFrame)
        targetOfTargetFrame._muiToTDebuffLiveSig = nil
    end

    if not SafeInCombatLockdown() then
        local totS = EnsureTargetOfTargetSettings()
        local pos = totS.position
        if pos and #pos >= 4 then
            local scaleVal = targetOfTargetFrame:GetScale()
            if not scaleVal or scaleVal == 0 then scaleVal = 1 end
            targetOfTargetFrame:ClearAllPoints()
            targetOfTargetFrame:SetPoint(pos[1], UIParent, pos[2], pos[3] * scaleVal, pos[4] * scaleVal)
        elseif targetFrame then
            targetOfTargetFrame:ClearAllPoints()
            targetOfTargetFrame:SetPoint("TOPLEFT", targetFrame, "TOPRIGHT", 10, 0)
        end
    end
end

local function RefreshTargetOfTargetDebuffOverlayVisuals(source)
    if not targetOfTargetFrame then
        return
    end
    if IsTargetOfTargetDebuffOverlayEnabled() then
        UpdateTargetOfTargetDebuffPreview(targetOfTargetFrame, source or "manual")
    else
        ClearTargetOfTargetDebuffPreview(targetOfTargetFrame)
        targetOfTargetFrame._muiToTDebuffLiveSig = nil
    end
end
_G.MidnightUI_RefreshTargetOfTargetDebuffOverlay = RefreshTargetOfTargetDebuffOverlayVisuals

function MidnightUI_ApplyTargetOfTargetSettings()
    if not targetOfTargetFrame then
        targetOfTargetFrame = CreateTargetOfTargetFrame()
    end
    local totS = EnsureTargetOfTargetSettings()
    local scaleVal = (totS.scale or 100) / 100
    if scaleVal <= 0 then scaleVal = 1 end
    targetOfTargetFrame:SetScale(scaleVal)
    targetOfTargetFrame:SetAlpha(totS.alpha or 0.95)
    -- Skip visibility changes during movement mode (frame is force-shown for dragging)
    local inMoveMode = MidnightUISettings and MidnightUISettings.Messenger
        and MidnightUISettings.Messenger.locked == false
    if not inMoveMode then
        UpdateTargetOfTargetVisibility()
    end
    RefreshTargetOfTargetDebuffOverlayVisuals("ApplyTargetOfTargetSettings")
end

local function ApplyTargetFrameBarStyle()
    local frame = _G.MidnightUI_TargetFrame
    if frame and frame.healthBar then
        ApplyHealthBarStyle(frame.healthBar)
    end
    if frame and frame.powerBar then
        ApplyHealthBarStyle(frame.powerBar)
    end
    ApplyFrameTextStyle(frame)
    ApplyFrameLayout(frame)
end
_G.MidnightUI_ApplyTargetFrameBarStyle = ApplyTargetFrameBarStyle

-- =========================================================================
--  DIAGNOSTIC: Test FontString method to extract values
-- =========================================================================

local hasLoggedDiagnostics = false

local function RunDiagnostics(frame, unit)
    if hasLoggedDiagnostics then return end
    hasLoggedDiagnostics = true
    
    LogDebug("=== DIAGNOSTICS V2 ===")
    
    local isFriendly = UnitIsFriend("player", unit)
    local isPlayer = UnitIsPlayer(unit)
    local reaction = UnitReaction(unit, "player")
    local canAttack = UnitCanAttack("player", unit)
    
    LogDebug("Friendly: " .. SafeToString(isFriendly) .. ", Player: " .. SafeToString(isPlayer) .. ", Reaction: " .. SafeToString(reaction) .. ", CanAttack: " .. SafeToString(canAttack))
    
    -- Get the values
    local current = UnitHealth(unit)
    local max = UnitHealthMax(unit)
    local pct = UnitHealthPercent and UnitHealthPercent(unit) or nil
    
    LogDebug("UnitHealth: type=" .. SafeToString(type(current)) .. " value=" .. SafeToString(current))
    LogDebug("UnitHealthMax: type=" .. SafeToString(type(max)) .. " value=" .. SafeToString(max))
    if pct then
        LogDebug("UnitHealthPercent: type=" .. SafeToString(type(pct)) .. " value=" .. SafeToString(pct))
    end
    
    -- Try to display them in a FontString
    local testFS = frame:CreateFontString(nil, "OVERLAY")
    testFS:SetFont("Fonts\\ARIALN.TTF", 12, "OUTLINE")
    testFS:SetPoint("CENTER", frame, "CENTER", 0, -50)
    testFS:SetTextColor(1, 1, 1, 1)
    
    local ok1 = pcall(function() testFS:SetFormattedText("%.2f", pct or 0) end)
    local text1 = testFS:GetText() or "nil"
    LogDebug("Test1 SetFormattedText: ok=" .. SafeToString(ok1) .. " result=" .. SafeToString(text1))
    
    local ok2, result2 = pcall(function() return string.format("%s / %s", current, max) end)
    LogDebug("Test2 string.format: ok=" .. SafeToString(ok2) .. " result=" .. SafeToString(result2))
    testFS:Hide()
    
    -- Try StatusBar
    local testBar = CreateFrame("StatusBar", nil, frame)
    testBar:SetPoint("CENTER")
    testBar:SetSize(100, 20)
    testBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    testBar:SetMinMaxValues(0, max)
    testBar:SetValue(current)
    local barValue = testBar:GetValue()
    local barType = type(barValue)
    LogDebug("Test3 StatusBar GetValue: type=" .. SafeToString(barType) .. " value=" .. SafeToString(barValue))
    testBar:Hide()
    
    -- Test 4: What about getting the texture width ratio?
    -- The health bar fills proportionally, maybe we can measure that
    
    -- Test 5: Target yourself (player) for comparison
    LogDebug("=== Player self-test ===")
    local playerHealth = UnitHealth("player")
    local playerMax = UnitHealthMax("player")
    local playerPct = UnitHealthPercent and UnitHealthPercent("player") or nil
    
    LogDebug("Player health: type=" .. SafeToString(type(playerHealth)) .. " value=" .. SafeToString(playerHealth))
    LogDebug("Player max: type=" .. SafeToString(type(playerMax)) .. " value=" .. SafeToString(playerMax))
    if playerPct then
        LogDebug("Player pct: type=" .. SafeToString(type(playerPct)) .. " value=" .. SafeToString(playerPct))
    end
    
    LogDebug("=== END DIAGNOSTICS V2 ===")
end

-- =========================================================================
--  UPDATED HEALTH (SECRET SAFE) - WITH ELITE DETECTION
-- =========================================================================

local lastPctDebugGuid, lastPctDebugTime = nil, 0
local lastAllowSecretState = nil

local function AllowSecretHealthPercent()
    if _G.MidnightUI_ForceHideHealthPct then return false end
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true
end

local function DebugPct(unit, msg)
    if not IsTargetDebugEnabled() then return end
    local guid = (UnitGUID and UnitGUID(unit)) or "noguid"
    local now = (GetTime and GetTime()) or 0
    if IsSecretValue(guid) then
        if (now - lastPctDebugTime) < 1.0 then return end
        lastPctDebugTime = now
        lastPctDebugGuid = nil
        LogDebug(msg)
        return
    end
    if guid == lastPctDebugGuid and (now - lastPctDebugTime) < 1.0 then
        return
    end
    lastPctDebugGuid, lastPctDebugTime = guid, now
    LogDebug(msg)
end

local function GetSafeHealthPercent(unit)
    if not unit then return nil end
    local allowSecret = AllowSecretHealthPercent()
    if not allowSecret then
        return nil
    end

    if UnitHealthPercent then
        local scaleTo100 = CurveConstants and CurveConstants.ScaleTo100 or nil
        local ok, pct = pcall(UnitHealthPercent, unit, true, scaleTo100)
        if ok and pct ~= nil then
            if IsSecretValue(pct) then
                DebugPct(unit, "HealthPct OK (UnitHealthPercent secret) type=" .. SafeToString(type(pct)))
                return pct
            end
            DebugPct(unit, "HealthPct OK (UnitHealthPercent) type=" .. SafeToString(type(pct)))
            return pct
        else
            DebugPct(unit, "HealthPct nil/err (UnitHealthPercent) ok=" .. SafeToString(ok) .. " type=" .. SafeToString(type(pct)))
        end
    end

    local okCur, cur = pcall(UnitHealth, unit)
    local okMax, max = pcall(UnitHealthMax, unit)
    if not okCur or not okMax or max == nil then
        DebugPct(unit, "HealthPct fallback failed (UnitHealth/Max) okCur=" .. SafeToString(okCur) .. " okMax=" .. SafeToString(okMax) .. " maxType=" .. SafeToString(type(max)))
        return nil
    end
    if IsSecretValue(cur) or IsSecretValue(max) then
        DebugPct(unit, "HealthPct fallback blocked (UnitHealth/Max secret)")
        return nil
    end
    if type(max) ~= "number" or type(cur) ~= "number" then
        DebugPct(unit, "HealthPct fallback non-numeric (UnitHealth/Max) curType=" .. SafeToString(type(cur)) .. " maxType=" .. SafeToString(type(max)))
        return nil
    end
    if max <= 0 then
        DebugPct(unit, "HealthPct fallback invalid max (UnitHealth/Max) max=" .. SafeToString(max))
        return nil
    end

    return (cur / max) * 100
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
    if not UnitExists("target") then return end
    local allowSecret = AllowSecretHealthPercent()
    if lastAllowSecretState == nil or lastAllowSecretState ~= allowSecret then
        lastAllowSecretState = allowSecret
        LogDebug("AllowProtectedHealth% = " .. tostring(allowSecret))
    end

    -- Default colors
    local classR, classG, classB = GetUnitColor("target")
    frame.healthBar:SetStatusBarColor(classR, classG, classB, 1.0)
    ApplyHealthBarStyle(frame.healthBar)
    frame.nameText:SetTextColor(classR, classG, classB, 1)
    frame.nameText:SetText(UnitName("target"))
    local isDead = IsUnitActuallyDead("target")

    if frame.healthBg then
        frame.healthBg:SetColorTexture(classR * 0.15, classG * 0.15, classB * 0.15, 0.6)
    end

    -- NEW: Elite Classification Detection
    local classification = UnitClassification("target")
    frame.currentClassification = classification
    
    local level = UnitLevel("target")
    local levelStr = ""
    local levelR, levelG, levelB = 0.9, 0.9, 0.9
    
    -- Handle level display
    if level == -1 then 
        levelStr = "??"
        levelR, levelG, levelB = 1.0, 0.2, 0.2  -- Red for skull level
    else
        levelStr = tostring(level)
        
        -- Color code by level difference
        local playerLevel = UnitLevel("player")
        if playerLevel then
            local diff = level - playerLevel
            if diff >= 5 then
                levelR, levelG, levelB = 1.0, 0.2, 0.2  -- Red (much higher)
            elseif diff >= 3 then
                levelR, levelG, levelB = 1.0, 0.5, 0.0  -- Orange (higher)
            elseif diff >= -2 then
                levelR, levelG, levelB = 1.0, 1.0, 0.0  -- Yellow (similar)
            else
                levelR, levelG, levelB = 0.5, 0.5, 0.5  -- Gray (much lower)
            end
        end
    end
    
    -- NEW: Handle Elite Classification Visuals
    if classification and classification ~= "normal" and classification ~= "trivial" and classification ~= "minus" then
        local eliteColor = ELITE_COLORS[classification]
        
        if eliteColor then
            -- Show elite border with appropriate color
            frame.eliteBorder:Show()
            frame.eliteBorder.top:SetColorTexture(eliteColor[1], eliteColor[2], eliteColor[3], eliteColor[4])
            frame.eliteBorder.bottom:SetColorTexture(eliteColor[1], eliteColor[2], eliteColor[3], eliteColor[4])
            frame.eliteBorder.left:SetColorTexture(eliteColor[1], eliteColor[2], eliteColor[3], eliteColor[4])
            frame.eliteBorder.right:SetColorTexture(eliteColor[1], eliteColor[2], eliteColor[3], eliteColor[4])
            
            -- Set glow color for border
            if frame.eliteBorder.glow and frame.eliteBorder.glow.tex then
                frame.eliteBorder.glow.tex:SetColorTexture(eliteColor[1], eliteColor[2], eliteColor[3], 0.2)
            end
            
            -- Add "+" suffix to level for elites
            levelStr = levelStr .. "+"
            
            -- Use elite color for level text
            levelR, levelG, levelB = eliteColor[1], eliteColor[2], eliteColor[3]
            
        end
    else
        -- Hide elite indicators for normal mobs
        frame.eliteBorder:Hide()
    end

    UpdateElitePulseState(frame, classification)
    
    -- Set level text with color
    frame.levelText:SetText(levelStr)
    frame.levelText:SetTextColor(levelR, levelG, levelB, 1)

    local current = UnitHealth("target")
    local max = UnitHealthMax("target")
    local hasIncomingRes = UnitHasIncomingResurrection and UnitHasIncomingResurrection("target") or false
    if not isDead and not hasIncomingRes then
        local okZero, isZero = pcall(function() return current <= 0 end)
        local okMaxPos, maxPos = pcall(function() return max > 0 end)
        if okZero and isZero and okMaxPos and maxPos then
            isDead = true
        end
    end

    -- Visual update (StatusBar accepts secret values)
    pcall(function()
        frame.healthBar:SetMinMaxValues(0, max)
        frame.healthBar:SetValue(current)
    end)

    -- Display health as a safe percentage (taint-safe).
    local pct = GetSafeHealthPercent("target")
    local renderedText = nil
    if AllowSecretHealthPercent() then
        local guid = UnitGUID and UnitGUID("target") or nil
        if IsSecretValue(guid) then guid = nil end
        local cachedPct = guid and _G.MidnightUI_GetNameplateHealthPct and _G.MidnightUI_GetNameplateHealthPct(guid) or nil

        if pct ~= nil then
            local ok, text = pcall(function()
                return string.format("%.0f%%", pct)
            end)
            if ok and text then
                renderedText = text
            end
        elseif cachedPct and type(cachedPct) == "number" then
            local ok, text = pcall(function()
                return string.format("%.0f%%", cachedPct)
            end)
            if ok and text then
                renderedText = text
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

end

-- =========================================================================
--  UPDATED POWER (SECRET SAFE)
-- =========================================================================

local function UpdatePower(frame)
    if not UnitExists("target") then return end

    local powerType, powerToken = UnitPowerType("target")
    local token = powerToken or "MANA"
    local color = POWER_COLORS[token] or DEFAULT_POWER_COLOR

    frame.powerBar:SetStatusBarColor(color[1], color[2], color[3], 1.0)
    ApplyHealthBarStyle(frame.powerBar)

    local current = UnitPower("target", powerType)
    local max = UnitPowerMax("target", powerType)

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

local function UpdateAbsorbs(frame)
    if not UnitExists("target") then return end
    frame.absorbBar:Hide()
end

local function UpdateAll(frame)
    UpdateHealth(frame)
    UpdatePower(frame)
    UpdateAbsorbs(frame)
end

local function ApplyTargetPlaceholder(frame)
    if not frame then return end
    if frame.nameText then frame.nameText:SetText("") end
    if frame.levelText then frame.levelText:SetText("") end
    if frame.healthText then frame.healthText:SetText("") end
    if frame.powerText then frame.powerText:SetText("") end
    if frame.eliteBorder then frame.eliteBorder:Hide() end
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
    if frame.dispelIndicator then
        frame.dispelIndicator:Hide()
        if frame.dispelIndicator.glowAnim then frame.dispelIndicator.glowAnim:Stop() end
    end
    if frame.deadIcon then frame.deadIcon:Hide() end
end

-- =========================================================================
--  DRAG & LOCKING
-- =========================================================================

function MidnightUI_SetTargetFrameLocked(locked)
    local frame = _G["MidnightUI_TargetFrame"]
    if not frame then
        -- Avoid creating frames in combat (can taint protected UI).
        if SafeInCombatLockdown() then
            pendingTargetFrameLock = locked
            return
        end
        -- Ensure the frame exists so the move overlay can be shown even without a target.
        frame = targetFrame or CreateTargetFrame()
        targetFrame = frame
    end
    
    if locked then
        frame:EnableMouse(true)
        if frame.dragOverlay then frame.dragOverlay:Hide() end

        -- Hide Target of Target overlay and restore visual content
        if targetOfTargetFrame then
            if targetOfTargetFrame.dragOverlay then targetOfTargetFrame.dragOverlay:Hide() end
            if targetOfTargetFrame.healthContainer then targetOfTargetFrame.healthContainer:Show() end
            if targetOfTargetFrame.powerContainer then targetOfTargetFrame.powerContainer:Show() end
            if targetOfTargetFrame.border then targetOfTargetFrame.border:Show() end
            if targetOfTargetFrame.shadows then ShowShadows(targetOfTargetFrame.shadows) end
        end

        -- [FIX] Combat Safe RegisterUnitWatch
        if not SafeInCombatLockdown() then
            if RegisterUnitWatch then RegisterUnitWatch(frame) end
            -- If we are locking, let UnitWatch decide visibility.
            -- We don't manually Hide() here to avoid taint; UnitWatch will hide it if no target.
            -- Re-apply ToT visibility (restores UnitWatch if enabled)
            UpdateTargetOfTargetVisibility()
        else
            -- If in combat, we can't touch protected frames. Queue or ignore.
            pendingTargetFrameLock = true
        end
    else
        -- UNLOCKED (Move Mode)
        frame:EnableMouse(true)
        
        -- [FIX] Combat Safe UnregisterUnitWatch + Show
        if not SafeInCombatLockdown() then
            if UnregisterUnitWatch then UnregisterUnitWatch(frame) end
            frame:Show() -- Safe to show manually only when unlocked and out of combat
            
            if UnitExists("target") then
                UpdateAll(frame)
            else
                ApplyTargetPlaceholder(frame)
            end
        else
            pendingTargetFrameLock = false
            return
        end

        if not frame.dragOverlay then
            local overlay = CreateFrame("Frame", nil, frame, "BackdropTemplate")
            overlay:SetAllPoints(); overlay:SetFrameStrata("DIALOG")
              overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
              overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30); overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
              if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "unit") end
              local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
            label:SetPoint("CENTER"); label:SetText("TARGET FRAME"); label:SetTextColor(1, 1, 1)
            overlay:EnableMouse(true); overlay:RegisterForDrag("LeftButton")
            
            overlay:SetScript("OnDragStart", function(self) frame:StartMoving() end)
            
            overlay:SetScript("OnDragStop", function(self)
                frame:StopMovingOrSizing()
                local point, relativeTo, relativePoint, xOfs, yOfs = frame:GetPoint()
                local s = frame:GetScale()
                if not s or s == 0 then s = 1.0 end
                xOfs = xOfs / s
                yOfs = yOfs / s
                if MidnightUISettings.TargetFrame then
                    MidnightUISettings.TargetFrame.position = { point, relativePoint, xOfs, yOfs }
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
                _G.MidnightUI_AttachOverlaySettings(overlay, "TargetFrame")
            end
            frame.dragOverlay = overlay
        end
        if frame.dragOverlay then frame.dragOverlay:Show() end

        -- Target of Target overlay handle (always shown in movement mode so users can position it)
        if not targetOfTargetFrame then
            targetOfTargetFrame = CreateTargetOfTargetFrame()
        end
        if targetOfTargetFrame then
            UnregisterUnitWatch(targetOfTargetFrame)
            targetOfTargetFrame:Show()

            if not targetOfTargetFrame.dragOverlay then
                local totOverlay = CreateFrame("Frame", nil, targetOfTargetFrame, "BackdropTemplate")
                totOverlay:SetAllPoints(); totOverlay:SetFrameStrata("DIALOG"); totOverlay:SetFrameLevel(100)
                if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(totOverlay, "Target of Target", "GameFontNormalSmall", "unit") end
                totOverlay:EnableMouse(true); totOverlay:RegisterForDrag("LeftButton")

                totOverlay:SetScript("OnDragStart", function() targetOfTargetFrame:StartMoving() end)
                totOverlay:SetScript("OnDragStop", function()
                    targetOfTargetFrame:StopMovingOrSizing()
                    local totS = EnsureTargetOfTargetSettings()
                    local s = targetOfTargetFrame:GetScale()
                    if not s or s == 0 then s = 1 end
                    local cx, cy = targetOfTargetFrame:GetCenter()
                    if cx and cy then
                        -- Store in screen-space center coordinates to avoid anchor/edge drift.
                        totS.position = { "CENTER", "BOTTOMLEFT", cx / s, cy / s }
                    else
                        local point, _, relativePoint, xOfs, yOfs = targetOfTargetFrame:GetPoint()
                        totS.position = { point, relativePoint, xOfs / s, yOfs / s }
                    end
                end)
                if _G.MidnightUI_AttachOverlaySettings then
                    _G.MidnightUI_AttachOverlaySettings(totOverlay, "TargetOfTarget")
                end
                targetOfTargetFrame.dragOverlay = totOverlay
            end
            if targetOfTargetFrame.dragOverlay then targetOfTargetFrame.dragOverlay:Show() end
            -- Hide visual content so it doesn't bleed through the overlay
            if targetOfTargetFrame.healthContainer then targetOfTargetFrame.healthContainer:Hide() end
            if targetOfTargetFrame.powerContainer then targetOfTargetFrame.powerContainer:Hide() end
            if targetOfTargetFrame.border then targetOfTargetFrame.border:Hide() end
            if targetOfTargetFrame.shadows then HideShadows(targetOfTargetFrame.shadows) end
        end

        -- Detach aura/debuff containers from the target frame so dragging doesn't move them.
        if MidnightUISettings and MidnightUISettings.TargetFrame then
            if frame.auraContainer then
                local _, relativeTo = frame.auraContainer:GetPoint()
                if relativeTo == frame then
                    DetachContainerToUIParent(frame.auraContainer, MidnightUISettings.TargetFrame.auras)
                end
            end
            if frame.debuffContainer then
                local _, relativeTo = frame.debuffContainer:GetPoint()
                if relativeTo == frame then
                    DetachContainerToUIParent(frame.debuffContainer, MidnightUISettings.TargetFrame.debuffs)
                end
            end
        end
    end
end

-- =========================================================================
--  EVENTS
-- =========================================================================

TargetFrameManager:RegisterEvent("ADDON_LOADED")
TargetFrameManager:RegisterEvent("PLAYER_ENTERING_WORLD")
TargetFrameManager:RegisterEvent("PLAYER_TARGET_CHANGED")
TargetFrameManager:RegisterUnitEvent("UNIT_HEALTH", "target")
TargetFrameManager:RegisterUnitEvent("UNIT_MAXHEALTH", "target")
TargetFrameManager:RegisterUnitEvent("UNIT_POWER_UPDATE", "target")
TargetFrameManager:RegisterUnitEvent("UNIT_MAXPOWER", "target")
TargetFrameManager:RegisterUnitEvent("UNIT_DISPLAYPOWER", "target")
TargetFrameManager:RegisterUnitEvent("UNIT_ABSORB_AMOUNT_CHANGED", "target")
-- UNIT_AURA removed: fires during UseAction, taints C_Timer callbacks. Use poll ticker instead.
TargetFrameManager:RegisterEvent("SPELLS_CHANGED")
TargetFrameManager:RegisterEvent("PLAYER_TALENT_UPDATE")
TargetFrameManager:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
TargetFrameManager:RegisterEvent("UNIT_PET")
TargetFrameManager:RegisterEvent("PLAYER_REGEN_ENABLED")
TargetFrameManager:RegisterEvent("UNIT_TARGET") -- For Target of Target updates

TargetFrameManager:SetScript("OnEvent", function(self, event, ...)
    local arg1 = ...

    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            if TargetFrame then
                SoftHideBlizzardTargetFrame(TargetFrame)
                if not TargetFrame._muiSoftHidden then
                    TargetFrame._muiSoftHidden = true
                    TargetFrame:HookScript("OnShow", function(self)
                        SoftHideBlizzardTargetFrame(self)
                    end)
                end
            end
            if ComboFrame then ComboFrame:Hide() end
        end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Initialize aura settings from saved variables
        InitializeTargetAuraSettings()
        MarkDispelCacheDirty()
        
        local overlaysUnlocked = (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false)

        -- Ensure target frame exists in move mode so the overlay is visible even without a target.
        if overlaysUnlocked and not targetFrame then
            targetFrame = CreateTargetFrame()
            if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
                _G.MidnightUI_Settings.ApplyTargetSettings()
            end
            ApplyTargetPlaceholder(targetFrame)
            if _G.MidnightUI_AttachTargetCastBar then
                _G.MidnightUI_AttachTargetCastBar(targetFrame)
            end
        end

        -- Apply aura and debuff settings if targetFrame exists
        if targetFrame then
            C_Timer.After(0.5, function()
                MidnightUI_ApplyTargetAuraSettings()
                MidnightUI_ApplyTargetDebuffSettings()
            end)
        end
        -- Poll ticker: updates only. No Show(), RegisterUnitWatch, or boolean tests (taint causes ADDON_ACTION_BLOCKED / secret boolean).
        if not TargetFrameManager._pollTicker then
            TargetFrameManager._pollTicker = C_Timer.NewTicker(0.5, function()
                if not targetFrame then return end
                local hasTarget = 0
                pcall(function()
                    local ok, v = pcall(UnitExists, "target")
                    if ok then pcall(function() if v then hasTarget = 1 end end) end
                end)
                if hasTarget == 1 then
                    UpdateAll(targetFrame)
                    UpdateTargetAuras(targetFrame)
                    if _G.MidnightUI_AttachTargetCastBar then _G.MidnightUI_AttachTargetCastBar(targetFrame) end
                else
                    UpdateTargetAuras(targetFrame)
                    UpdateElitePulseState(targetFrame, nil)
                    if _G.MidnightUI_AttachTargetCastBar then _G.MidnightUI_AttachTargetCastBar(targetFrame) end
                end
                UpdateTargetOfTargetVisibility()
            end)
        end
        elseif event == "PLAYER_TARGET_CHANGED" then
            if not targetFrame then
                targetFrame = CreateTargetFrame()
                if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyTargetSettings then
                    _G.MidnightUI_Settings.ApplyTargetSettings()
                end
                MidnightUI_ApplyTargetAuraSettings()
                MidnightUI_ApplyTargetDebuffSettings()
            end
            -- Immediate refresh on target swap to prevent one-frame stale NPC data.
            if targetFrame then
                local hasTarget = 0
                pcall(function()
                    local ok, v = pcall(UnitExists, "target")
                    if ok then pcall(function() if v then hasTarget = 1 end end) end
                end)
                if hasTarget == 1 then
                    UpdateAll(targetFrame)
                else
                    ApplyTargetPlaceholder(targetFrame)
                    UpdateElitePulseState(targetFrame, nil)
                end
                UpdateTargetAuras(targetFrame)
                if _G.MidnightUI_AttachTargetCastBar then _G.MidnightUI_AttachTargetCastBar(targetFrame) end
            end
            UpdateTargetOfTargetVisibility()

    elseif event == "UNIT_HEALTH" or event == "UNIT_MAXHEALTH" then
        -- RegisterUnitEvent filters to "target" only; targettarget covered by poll ticker
        if targetFrame and SafeFrameShown(targetFrame) == 1 then
            UpdateHealth(targetFrame)
            UpdateAbsorbs(targetFrame)
        end

    elseif event == "UNIT_POWER_UPDATE" or event == "UNIT_MAXPOWER" or event == "UNIT_DISPLAYPOWER" then
        if targetFrame and SafeFrameShown(targetFrame) == 1 then
            UpdatePower(targetFrame)
        end

    elseif event == "UNIT_ABSORB_AMOUNT_CHANGED" then
        if targetFrame and SafeFrameShown(targetFrame) == 1 then
            UpdateAbsorbs(targetFrame)
        end

    elseif event == "SPELLS_CHANGED" or event == "PLAYER_TALENT_UPDATE" or event == "PLAYER_SPECIALIZATION_CHANGED" or event == "UNIT_PET" then
        if event ~= "UNIT_PET" or (arg1 and SafeUnitIsUnit(arg1, "player") == 1) then
            MarkDispelCacheDirty()
            if targetFrame and SafeFrameShown(targetFrame) == 1 then
                UpdateTargetDispelIndicator(targetFrame)
            end
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingBlizzardTargetMouseDisable and TargetFrame then
            SoftHideBlizzardTargetFrame(TargetFrame)
        end
        if pendingTargetFrameLock ~= nil then
            local pending = pendingTargetFrameLock
            pendingTargetFrameLock = nil
            MidnightUI_SetTargetFrameLocked(pending)
        end
        if targetOfTargetFrame and SafeFrameShown(targetOfTargetFrame) == 1 then
            UpdateTargetOfTargetDebuffPreview(targetOfTargetFrame, event)
        end
    
    elseif event == "UNIT_TARGET" then
        if arg1 and SafeUnitIsUnit(arg1, "target") == 1 then
            UpdateTargetOfTargetVisibility()
        end
    end
end)
