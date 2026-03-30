-- =============================================================================
-- FILE PURPOSE:     Full character panel replacing Blizzard's PaperDollFrame.
--                   The player 3D model is center stage, surrounded by floating
--                   glass panels for equipped gear slots (left/right columns),
--                   stat readouts (ilvl, primary stats, secondary stats), and
--                   enhancement slots. Two slide-in tab overlays: Reputation and
--                   Currency views. Supports parchment/midnight/twilight themes.
-- LOAD ORDER:       Loads after AchievementsPanel.lua, before GuildPanel.lua.
--                   Standalone file — no Addon vararg namespace, no early-exit guard.
-- DEFINES:          "MidnightCharacterPanel" frame (global via hooksecurefunc hook on
--                   CharacterFrame:Show). THEMES{} (parchment/midnight/twilight palettes).
--                   SafeCall(), TrySetFont(), FormatNumber() — local safe wrappers.
-- READS:            MidnightUISettings.General.characterPanelTheme — active theme key.
--                   Gear: GetInventoryItemTexture, GetInventoryItemLink, GetInventorySlotInfo.
--                   Stats: GetCritChance, GetHaste, GetMasteryEffect, GetVersatilityBonus,
--                   UnitStat, UnitArmor, UnitAttackPower, GetSpellBonusDamage, etc.
--                   Spec: GetSpecialization, GetSpecializationInfo.
--                   Titles: GetCurrentTitle, GetTitleName.
-- WRITES:           MidnightUISettings.General.characterPanelTheme (on theme switch via UI).
--                   Blizzard CharacterFrame: hidden (SetAlpha 0) when custom panel opens.
-- DEPENDS ON:       Blizzard's stat API (GetCritChance etc.) — all wrapped in SafeCall.
--                   GetItemInfo, GetItemQualityColor — for gear slot quality borders.
-- USED BY:          Nothing external — hooks CharacterFrame:Show via hooksecurefunc.
-- KEY FLOWS:
--   CharacterFrame:Show hook → open custom panel → load player model → RefreshGear()
--   RefreshGear() → iterate SLOT_IDS → GetInventoryItemTexture → update slot icons
--   RefreshStats() → call each stat API via SafeCall → populate stat text labels
--   Tab click (Reputation/Currency) → slide in overlay panel, populate rows
--   Theme button → update THEMES[key] → re-apply all colors to live frames
-- GOTCHAS:
--   All stat API calls use SafeCall() (pcall wrapper) — some stats return nil or taint
--   in certain contexts (e.g., during some loading screen phases).
--   FormatNumber(): applies comma-grouping to large numbers (e.g., 1,234,567 HP).
--   No Addon vararg: this file uses ADDON_NAME as a plain local string, not the TOC vararg.
--   PaperDollFrame is NOT replaced in memory — it is hidden behind the custom panel.
-- NAVIGATION:
--   THEMES{}           — color palettes for all themes (line ~61)
--   SafeCall()         — pcall wrapper for API (line ~34)
--   RefreshGear()      — gear slot update (search "function RefreshGear")
--   RefreshStats()     — stat panel update (search "function RefreshStats")
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local W8 = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local BODY_FONT  = "Fonts\\FRIZQT__.TTF"

-- ============================================================================
-- S1  UPVALUES
-- ============================================================================
local pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber =
      pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local UnitName, UnitClass, UnitLevel, UnitRace, UnitStat =
      UnitName, UnitClass, UnitLevel, UnitRace, UnitStat
local GetSpecialization, GetSpecializationInfo = GetSpecialization, GetSpecializationInfo
local GetCurrentTitle, GetTitleName = GetCurrentTitle, GetTitleName
local GetInventoryItemTexture, GetInventoryItemLink = GetInventoryItemTexture, GetInventoryItemLink
local GetInventorySlotInfo, GetAverageItemLevel = GetInventorySlotInfo, GetAverageItemLevel
local GetCritChance, GetHaste, GetMasteryEffect = GetCritChance, GetHaste, GetMasteryEffect
local GetCombatRating, GetCombatRatingBonus, GetVersatilityBonus = GetCombatRating, GetCombatRatingBonus, GetVersatilityBonus
local GetSpellBonusDamage, GetSpellCritChance, GetDodgeChance = GetSpellBonusDamage, GetSpellCritChance, GetDodgeChance
local UnitHealthMax, UnitAttackPower, UnitArmor = UnitHealthMax, UnitAttackPower, UnitArmor
local GetItemInfo, GetItemQualityColor = GetItemInfo, GetItemQualityColor
local hooksecurefunc = hooksecurefunc

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4, r5 = pcall(fn, ...)
    if not ok then return nil end
    return r1, r2, r3, r4, r5
end

local function TrySetFont(fs, fontPath, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, fontPath or TITLE_FONT, size or 12, flags or "")
end

local function FormatNumber(n)
    if not n or type(n) ~= "number" then return "0" end
    n = math.floor(n + 0.5)
    local formatted = tostring(n)
    while true do
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

-- ============================================================================
-- S2  COLOR THEMES
-- ============================================================================
local THEMES = {
    parchment = {
        key         = "parchment",
        frameBg     = { 0.04, 0.035, 0.025, 0.97 },
        modelBg     = { 0.03, 0.03, 0.04, 1.0 },
        headerBg    = { 0.05, 0.04, 0.025, 0.95 },
        glassBg     = { 0.04, 0.04, 0.06, 0.70 },
        glassBorder = { 1, 1, 1, 0.08 },
        accent      = { 0.72, 0.62, 0.42 },
        titleText   = { 0.96, 0.87, 0.58 },
        bodyText    = { 0.94, 0.90, 0.80 },
        mutedText   = { 0.71, 0.62, 0.44 },
        divider     = { 0.60, 0.52, 0.35 },
        tabActive   = { 0.96, 0.87, 0.58 },
        tabInactive = { 0.52, 0.46, 0.34 },
    },
    midnight = {
        key         = "midnight",
        frameBg     = { 0.03, 0.04, 0.07, 0.97 },
        modelBg     = { 0.02, 0.025, 0.04, 1.0 },
        headerBg    = { 0.025, 0.03, 0.06, 0.95 },
        glassBg     = { 0.03, 0.04, 0.08, 0.70 },
        glassBorder = { 1, 1, 1, 0.06 },
        accent      = { 0.00, 0.78, 1.00 },
        titleText   = { 0.92, 0.93, 0.96 },
        bodyText    = { 0.82, 0.84, 0.88 },
        mutedText   = { 0.58, 0.60, 0.65 },
        divider     = { 0.35, 0.40, 0.50 },
        tabActive   = { 0.92, 0.93, 0.96 },
        tabInactive = { 0.45, 0.48, 0.55 },
    },
    class = {
        key         = "class",
        frameBg     = { 0.04, 0.035, 0.025, 0.97 },
        modelBg     = { 0.03, 0.03, 0.04, 1.0 },
        headerBg    = { 0.05, 0.04, 0.025, 0.95 },
        glassBg     = { 0.04, 0.04, 0.06, 0.70 },
        glassBorder = { 1, 1, 1, 0.08 },
        accent      = { 0.72, 0.62, 0.42 }, -- overridden at runtime
        titleText   = { 0.94, 0.92, 0.88 },
        bodyText    = { 0.92, 0.90, 0.85 },
        mutedText   = { 0.65, 0.62, 0.55 },
        divider     = { 0.50, 0.48, 0.40 },
        tabActive   = { 0.94, 0.92, 0.88 },
        tabInactive = { 0.50, 0.48, 0.42 },
    },
}

local activeTheme = THEMES.parchment

local function GetActiveTheme()
    local s = _G.MidnightUISettings
    local key = (s and s.General and s.General.characterPanelTheme) or "parchment"
    local t = THEMES[key] or THEMES.parchment
    if key == "class" then
        local cc = _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable
            and _G.MidnightUI_Core.GetClassColorTable("player")
        if cc then
            t.accent = { cc.r or cc[1] or 0.72, cc.g or cc[2] or 0.62, cc.b or cc[3] or 0.42 }
        end
    end
    activeTheme = t
    return t
end

local function TC(key)
    local c = activeTheme[key]
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end

-- ============================================================================
-- S3  CONFIGURATION
-- ============================================================================
local CFG = {
    WIDTH           = 1060,
    HEIGHT          = 780,
    HEADER_H        = 44,
    TAB_BAR_H       = 32,

    LEFT_GLASS_W    = 220,
    RIGHT_GLASS_W   = 200,
    GLASS_PAD       = 10,
    GLASS_MARGIN    = 8,

    SLOT_SIZE       = 34,
    SLOT_GAP        = 4,

    IDENTITY_H      = 70,

    STRATA          = "HIGH",

    modelLight = { true, false, -0.4, 0.8, -0.5, 0.95, 0.82, 0.72, 0.58, 0.7, 1.0, 0.94, 0.84 },

    REP_ROW_H       = 38,
    CURRENCY_ROW_H  = 32,
    HEADER_ROW_H    = 28,
}

-- ============================================================================
-- S4  HELPERS
-- ============================================================================
local function CreateDropShadow(frame, intensity)
    intensity = intensity or 6
    local shadows = {}
    for i = 1, intensity do
        local s = CreateFrame("Frame", nil, frame)
        s:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 0.8
        local alpha = (0.18 - (i * 0.025)) * (intensity / 6)
        s:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        s:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        local t = s:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0, 0, 0, alpha)
        shadows[#shadows + 1] = s
    end
    return shadows
end

local function CreateGlassPanel(parent, width)
    local glass = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    glass:SetWidth(width)
    glass:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    glass:SetBackdropColor(TC("glassBg"))
    glass:SetBackdropBorderColor(TC("glassBorder"))

    -- Frost line at top
    local frost = glass:CreateTexture(nil, "OVERLAY", nil, 3)
    frost:SetHeight(1)
    frost:SetPoint("TOPLEFT", glass, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", glass, "TOPRIGHT", -1, -1)
    frost:SetColorTexture(1, 1, 1, 0.10)
    glass._frost = frost

    -- Inner gradient (top-to-bottom darkening)
    local grad = glass:CreateTexture(nil, "BACKGROUND", nil, 1)
    grad:SetPoint("TOPLEFT", 1, -1)
    grad:SetPoint("BOTTOMRIGHT", -1, 1)
    grad:SetTexture(W8)
    if grad.SetGradient and CreateColor then
        grad:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0.15),
            CreateColor(0, 0, 0, 0))
    end
    glass._grad = grad

    function glass:ApplyTheme()
        self:SetBackdropColor(TC("glassBg"))
        self:SetBackdropBorderColor(TC("glassBorder"))
    end

    return glass
end

-- Quality color from item quality index
local function GetQualityColorRGB(quality)
    if not quality or quality < 0 then return 0.65, 0.65, 0.65 end
    local r, g, b = GetItemQualityColor(quality)
    if r then return r, g, b end
    return 0.65, 0.65, 0.65
end

-- ============================================================================
-- S5  PANEL STATE
-- ============================================================================
local Panel = {}
Panel._state = {
    initialized  = false,
    panelOpen    = false,
    activeTab    = "character",
    modelFacing  = 0.4,
    modelZoom    = 1.0,
    isDragging   = false,
    dragStartX   = 0,
    dragStartFacing = 0,
}
Panel._refs = {} -- UI element references

-- ============================================================================
-- S6  DATA: CHARACTER STATS
-- ============================================================================
local function GetPrimaryStatIndex()
    local specIndex = SafeCall(GetSpecialization)
    if not specIndex then return 4 end -- default Int
    local _, _, _, _, _, primaryStat = SafeCall(GetSpecializationInfo, specIndex)
    -- LE_UNIT_STAT: 1=Str, 2=Agi, 4=Int
    if primaryStat == 1 then return 1
    elseif primaryStat == 2 then return 2
    elseif primaryStat == 4 then return 4
    else return 4 end
end

local STAT_NAMES = { [1] = "Strength", [2] = "Agility", [3] = "Stamina", [4] = "Intellect" }

local function GetPrimaryStats()
    local primary = GetPrimaryStatIndex()
    local stats = {}
    -- Primary stat, then stamina, then armor
    local order = { primary, 3 }
    if primary == 3 then order = { 3 } end
    for _, idx in ipairs(order) do
        local base, stat = SafeCall(UnitStat, "player", idx)
        local value = stat or base or 0
        local subs = {}
        if idx == 1 then -- Strength
            local aBase, aPos, aNeg = SafeCall(UnitAttackPower, "player")
            subs[#subs + 1] = { label = "Attack Power", value = FormatNumber((aBase or 0) + (aPos or 0) + (aNeg or 0)) }
            subs[#subs + 1] = { label = "Critical Strike", value = string.format("%.1f%%", SafeCall(GetCritChance) or 0) }
        elseif idx == 2 then -- Agility
            local aBase, aPos, aNeg = SafeCall(UnitAttackPower, "player")
            subs[#subs + 1] = { label = "Attack Power", value = FormatNumber((aBase or 0) + (aPos or 0) + (aNeg or 0)) }
            subs[#subs + 1] = { label = "Critical Strike", value = string.format("%.1f%%", SafeCall(GetCritChance) or 0) }
            local dodge = SafeCall(GetDodgeChance) or 0
            if dodge > 0 then subs[#subs + 1] = { label = "Dodge", value = string.format("%.1f%%", dodge) } end
        elseif idx == 4 then -- Intellect
            local sp = SafeCall(GetSpellBonusDamage, 2) or 0
            subs[#subs + 1] = { label = "Spell Power", value = FormatNumber(sp) }
            subs[#subs + 1] = { label = "Spell Critical", value = string.format("%.1f%%", SafeCall(GetSpellCritChance, 2) or 0) }
        elseif idx == 3 then -- Stamina
            subs[#subs + 1] = { label = "Max Health", value = FormatNumber(SafeCall(UnitHealthMax, "player") or 0) }
        end
        stats[#stats + 1] = { name = STAT_NAMES[idx] or "?", value = value, subs = subs }
    end
    -- Armor as a separate stat card
    local armorBase, armorEffective = SafeCall(UnitArmor, "player")
    local armor = armorEffective or armorBase or 0
    local armorSubs = {}
    if C_PaperDollInfo and C_PaperDollInfo.GetArmorReduction then
        local reduction = SafeCall(C_PaperDollInfo.GetArmorReduction, armor, UnitLevel("player") or 80) or 0
        armorSubs[#armorSubs + 1] = { label = "Damage Reduction", value = string.format("%.1f%%", reduction) }
    end
    stats[#stats + 1] = { name = "Armor", value = armor, subs = armorSubs }
    return stats
end

local ENHANCEMENT_DESCS = {
    ["Critical Strike"] = "Increases damage and healing from critical hits",
    ["Haste"]           = "Increases attack speed, casting speed, and regeneration",
    ["Mastery"]         = "Increases the effectiveness of your Mastery",
    ["Versatility"]     = "Increases damage done and reduces damage taken",
}

local function GetEnhancementStats()
    local stats = {}
    local crit = SafeCall(GetCritChance) or 0
    local critRating = CR_CRIT_MELEE and (SafeCall(GetCombatRating, CR_CRIT_MELEE) or 0) or 0
    local haste = SafeCall(GetHaste) or 0
    local hasteRating = CR_HASTE_MELEE and (SafeCall(GetCombatRating, CR_HASTE_MELEE) or 0) or 0
    local mastery = SafeCall(GetMasteryEffect) or 0
    local masteryRating = CR_MASTERY and (SafeCall(GetCombatRating, CR_MASTERY) or 0) or 0
    local vers = 0
    local versRating = 0
    if CR_VERSATILITY_DAMAGE_DONE then
        local bonus = SafeCall(GetCombatRatingBonus, CR_VERSATILITY_DAMAGE_DONE) or 0
        local vBonus = SafeCall(GetVersatilityBonus, CR_VERSATILITY_DAMAGE_DONE) or 0
        vers = bonus + vBonus
        versRating = SafeCall(GetCombatRating, CR_VERSATILITY_DAMAGE_DONE) or 0
    end
    local avoid = CR_AVOIDANCE and (SafeCall(GetCombatRatingBonus, CR_AVOIDANCE) or 0) or 0
    local avoidRating = CR_AVOIDANCE and (SafeCall(GetCombatRating, CR_AVOIDANCE) or 0) or 0
    local leech = CR_LIFESTEAL and (SafeCall(GetCombatRatingBonus, CR_LIFESTEAL) or 0) or 0
    local leechRating = CR_LIFESTEAL and (SafeCall(GetCombatRating, CR_LIFESTEAL) or 0) or 0
    local speed = CR_SPEED and (SafeCall(GetCombatRatingBonus, CR_SPEED) or 0) or 0
    local speedRating = CR_SPEED and (SafeCall(GetCombatRating, CR_SPEED) or 0) or 0

    stats[#stats + 1] = { label = "Critical Strike", value = crit, rating = critRating, desc = ENHANCEMENT_DESCS["Critical Strike"], detailed = true }
    stats[#stats + 1] = { label = "Haste",           value = haste, rating = hasteRating, desc = ENHANCEMENT_DESCS["Haste"], detailed = true }
    stats[#stats + 1] = { label = "Mastery",         value = mastery, rating = masteryRating, desc = ENHANCEMENT_DESCS["Mastery"], detailed = true }
    stats[#stats + 1] = { label = "Versatility",     value = vers, rating = versRating, desc = ENHANCEMENT_DESCS["Versatility"], detailed = true }
    stats[#stats + 1] = { label = "Avoidance",       value = avoid, rating = avoidRating, detailed = false, desc = "Reduces area of effect damage taken" }
    stats[#stats + 1] = { label = "Leech",           value = leech, rating = leechRating, detailed = false, desc = "Heals you for a percentage of damage and healing done" }
    stats[#stats + 1] = { label = "Speed",           value = speed, rating = speedRating, detailed = false, desc = "Increases movement speed" }
    return stats
end

-- ============================================================================
-- S7  DATA: REPUTATION
-- ============================================================================
local STANDING_COLORS = {
    [1] = { 0.80, 0.20, 0.20 }, -- Hated
    [2] = { 0.80, 0.30, 0.22 }, -- Hostile
    [3] = { 0.75, 0.55, 0.20 }, -- Unfriendly
    [4] = { 0.85, 0.77, 0.36 }, -- Neutral
    [5] = { 0.40, 0.75, 0.35 }, -- Friendly
    [6] = { 0.35, 0.70, 0.45 }, -- Honored
    [7] = { 0.30, 0.60, 0.80 }, -- Revered
    [8] = { 0.60, 0.50, 0.90 }, -- Exalted
}

local STANDING_NAMES = {
    [1] = "Hated", [2] = "Hostile", [3] = "Unfriendly", [4] = "Neutral",
    [5] = "Friendly", [6] = "Honored", [7] = "Revered", [8] = "Exalted",
}

local function CollectReputations()
    local groups = {}
    local currentGroup = nil
    if not C_Reputation or not C_Reputation.GetNumFactions then return groups end

    -- First, expand all collapsed headers so we can see all factions
    -- We iterate backwards to avoid index shifting issues
    local function ExpandAllHeaders()
        local changed = true
        while changed do
            changed = false
            local n = SafeCall(C_Reputation.GetNumFactions) or 0
            for i = 1, n do
                local data = SafeCall(C_Reputation.GetFactionDataByIndex, i)
                if data and (data.isHeader or data.isHeaderWithRep) and data.isCollapsed then
                    if C_Reputation.ExpandFactionHeader then
                        pcall(C_Reputation.ExpandFactionHeader, i)
                        changed = true
                        break -- restart since indices shifted
                    elseif ExpandFactionHeader then
                        pcall(ExpandFactionHeader, i)
                        changed = true
                        break
                    end
                end
            end
        end
    end
    ExpandAllHeaders()

    local numFactions = SafeCall(C_Reputation.GetNumFactions) or 0
    local headerStack = {} -- track nested headers

    for i = 1, numFactions do
        local data = SafeCall(C_Reputation.GetFactionDataByIndex, i)
        if data then
            if data.isHeader or data.isHeaderWithRep then
                currentGroup = {
                    name = data.name or "Unknown",
                    factions = {},
                }
                -- If header itself has rep, add it as a faction too
                if data.isHeaderWithRep and data.name and data.name ~= "" then
                    local standing = data.reaction or 4
                    local min = data.currentReactionThreshold or 0
                    local max = data.nextReactionThreshold or 1
                    local cur = data.currentStanding or 0
                    local progress = 0
                    if max > min then progress = (cur - min) / (max - min) end
                    currentGroup.factions[#currentGroup.factions + 1] = {
                        name = data.name,
                        standingID = standing,
                        standingName = STANDING_NAMES[standing] or "Neutral",
                        standingColor = STANDING_COLORS[standing] or { 0.85, 0.77, 0.36 },
                        progress = math.max(0, math.min(1, progress)),
                        currentRep = cur - min,
                        maxRep = max - min,
                        factionID = data.factionID,
                        factionIndex = i,
                    }
                end
                groups[#groups + 1] = currentGroup
            elseif data.name and data.name ~= "" and currentGroup then
                local standing = data.reaction or 4
                local min = data.currentReactionThreshold or 0
                local max = data.nextReactionThreshold or 1
                local cur = data.currentStanding or 0
                local progress = 0
                if max > min then progress = (cur - min) / (max - min) end
                currentGroup.factions[#currentGroup.factions + 1] = {
                    name = data.name,
                    standingID = standing,
                    standingName = STANDING_NAMES[standing] or "Neutral",
                    standingColor = STANDING_COLORS[standing] or { 0.85, 0.77, 0.36 },
                    progress = math.max(0, math.min(1, progress)),
                    currentRep = cur - min,
                    maxRep = max - min,
                    factionID = data.factionID,
                    factionIndex = i,
                }
            end
        end
    end

    -- Filter out empty groups
    local filtered = {}
    for _, g in ipairs(groups) do
        if #g.factions > 0 then
            filtered[#filtered + 1] = g
        end
    end
    return filtered
end

-- ============================================================================
-- S8  DATA: CURRENCY
-- ============================================================================
local function CollectCurrencies()
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize then return {} end

    -- Expand all collapsed currency headers so we see everything
    if C_CurrencyInfo.ExpandCurrencyList then
        local safety = 0
        local expanded = true
        while expanded and safety < 50 do
            expanded = false
            safety = safety + 1
            local n = SafeCall(C_CurrencyInfo.GetCurrencyListSize) or 0
            for i = 1, n do
                local info = SafeCall(C_CurrencyInfo.GetCurrencyListInfo, i)
                if info and info.isHeader then
                    -- Try expanding regardless — if already expanded, it's a no-op
                    local prevSize = n
                    pcall(C_CurrencyInfo.ExpandCurrencyList, i, true)
                    local newSize = SafeCall(C_CurrencyInfo.GetCurrencyListSize) or 0
                    if newSize > prevSize then
                        expanded = true
                        break -- indices shifted, restart
                    end
                end
            end
        end
    end

    -- Collect into groups (header + currencies underneath)
    local groups = {}
    local currentGroup = nil
    local count = SafeCall(C_CurrencyInfo.GetCurrencyListSize) or 0
    for i = 1, count do
        local info = SafeCall(C_CurrencyInfo.GetCurrencyListInfo, i)
        if info and info.name and info.name ~= "" then
            if info.isHeader then
                currentGroup = {
                    isHeader = true,
                    name = info.name,
                    currencies = {},
                }
                groups[#groups + 1] = currentGroup
            elseif currentGroup then
                currentGroup.currencies[#currentGroup.currencies + 1] = {
                    name = info.name,
                    quantity = info.quantity or 0,
                    iconFileID = info.iconFileID,
                    maxQuantity = info.maxQuantity or 0,
                    currencyID = info.currencyTypesID,
                }
            else
                -- Currency without a header group — create an "Other" group
                if not currentGroup then
                    currentGroup = { isHeader = true, name = "Other", currencies = {} }
                    groups[#groups + 1] = currentGroup
                end
                currentGroup.currencies[#currentGroup.currencies + 1] = {
                    name = info.name,
                    quantity = info.quantity or 0,
                    iconFileID = info.iconFileID,
                    maxQuantity = info.maxQuantity or 0,
                    currencyID = info.currencyTypesID,
                }
            end
        end
    end

    -- Filter out empty groups
    local filtered = {}
    for _, g in ipairs(groups) do
        if #g.currencies > 0 then
            filtered[#filtered + 1] = g
        end
    end
    return filtered
end

-- ============================================================================
-- S9  GEAR SLOT DEFINITIONS
-- ============================================================================
local SLOT_LAYOUT = {
    { id = 1,  name = "HeadSlot",          label = "Head",       blizz = "CharacterHeadSlot" },
    { id = 2,  name = "NeckSlot",          label = "Neck",       blizz = "CharacterNeckSlot" },
    { id = 3,  name = "ShoulderSlot",      label = "Shoulders",  blizz = "CharacterShoulderSlot" },
    { id = 15, name = "BackSlot",          label = "Back",       blizz = "CharacterBackSlot" },
    { id = 5,  name = "ChestSlot",         label = "Chest",      blizz = "CharacterChestSlot" },
    { id = 9,  name = "WristSlot",         label = "Wrists",     blizz = "CharacterWristSlot" },
    { id = 10, name = "HandsSlot",         label = "Hands",      blizz = "CharacterHandsSlot" },
    { id = 6,  name = "WaistSlot",         label = "Waist",      blizz = "CharacterWaistSlot" },
    { id = 7,  name = "LegsSlot",          label = "Legs",       blizz = "CharacterLegsSlot" },
    { id = 8,  name = "FeetSlot",          label = "Feet",       blizz = "CharacterFeetSlot" },
    { id = 11, name = "Finger0Slot",       label = "Ring 1",     blizz = "CharacterFinger0Slot" },
    { id = 12, name = "Finger1Slot",       label = "Ring 2",     blizz = "CharacterFinger1Slot" },
    { id = 13, name = "Trinket0Slot",      label = "Trinket 1",  blizz = "CharacterTrinket0Slot" },
    { id = 14, name = "Trinket1Slot",      label = "Trinket 2",  blizz = "CharacterTrinket1Slot" },
    { id = 16, name = "MainHandSlot",      label = "Main Hand",  blizz = "CharacterMainHandSlot" },
    { id = 17, name = "SecondaryHandSlot", label = "Off Hand",   blizz = "CharacterSecondaryHandSlot" },
}

-- Attach Blizzard's secure slot buttons invisibly on top of MidnightUI's gear slots.
-- Called after Blizzard_CharacterUI loads. The Blizzard buttons handle PickupInventoryItem
-- securely without taint, enabling weapon oil / enchant / gem application.
local function AttachBlizzardSlotButtons()
    if not Panel._refs or not Panel._refs.gearSlots then return end
    local gearSlots = Panel._refs.gearSlots
    for _, slotDef in ipairs(SLOT_LAYOUT) do
        local muiBtn = gearSlots[slotDef.id]
        if muiBtn and slotDef.blizz and not muiBtn._blizzAttached then
            local blizzBtn = _G[slotDef.blizz]
            if blizzBtn then
                muiBtn._blizzAttached = true
                -- Reparent to our button
                blizzBtn:SetParent(muiBtn)
                blizzBtn:ClearAllPoints()
                blizzBtn:SetAllPoints(muiBtn)
                blizzBtn:SetFrameLevel(muiBtn:GetFrameLevel() + 10)
                blizzBtn:Show()
                -- Hide ALL visual elements but keep the button frame clickable
                -- Regions: icon, border, glow textures, fontstrings
                if blizzBtn.GetRegions then
                    for _, region in ipairs({blizzBtn:GetRegions()}) do
                        region:SetAlpha(0)
                        if region.Hide then region:Hide() end
                    end
                end
                -- Children: cooldown, highlight frames, etc.
                if blizzBtn.GetChildren then
                    for _, child in ipairs({blizzBtn:GetChildren()}) do
                        child:SetAlpha(0)
                        if child.Hide then child:Hide() end
                    end
                end
                -- Ensure the button itself is mouse-enabled and clickable
                blizzBtn:EnableMouse(true)
                blizzBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            end
        end
    end
end

-- ============================================================================
-- S10  PANEL CREATION
-- ============================================================================
function Panel.EnsurePanel()
    if Panel._state.initialized then return Panel._refs.panel end
    Panel._state.initialized = true
    GetActiveTheme()

    local R = Panel._refs

    -- ── 10a  Main frame ────────────────────────────────────────────────
    local p = CreateFrame("Frame", "MidnightUI_CharacterPanel", UIParent, "BackdropTemplate")
    p:SetSize(CFG.WIDTH, CFG.HEIGHT)
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    p:SetFrameStrata(CFG.STRATA)
    p:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    p:SetBackdropColor(TC("frameBg"))
    p:SetBackdropBorderColor(TC("accent"))
    p:Hide()
    R.panel = p

    CreateDropShadow(p, 5)

    -- ── 10b  Header ────────────────────────────────────────────────────
    local hdr = CreateFrame("Frame", nil, p)
    hdr:SetHeight(CFG.HEADER_H)
    hdr:SetPoint("TOPLEFT", p, "TOPLEFT", 0, 0)
    hdr:SetPoint("TOPRIGHT", p, "TOPRIGHT", 0, 0)
    local hdrBg = hdr:CreateTexture(nil, "BACKGROUND")
    hdrBg:SetAllPoints()
    hdrBg:SetColorTexture(TC("headerBg"))
    R.header = hdr
    R.hdrBg = hdrBg

    -- Header accent line
    local hdrAccent = hdr:CreateTexture(nil, "OVERLAY")
    hdrAccent:SetHeight(2)
    hdrAccent:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
    hdrAccent:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
    hdrAccent:SetTexture(W8)
    if hdrAccent.SetGradient and CreateColor then
        hdrAccent:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.6),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.0))
    end
    R.hdrAccent = hdrAccent

    -- Title
    local titleFS = hdr:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 16, "OUTLINE")
    titleFS:SetPoint("LEFT", hdr, "LEFT", 16, 0)
    titleFS:SetText("Character")
    titleFS:SetTextColor(TC("titleText"))
    R.titleFS = titleFS

    -- Close button
    local closeBtn = CreateFrame("Button", nil, hdr)
    closeBtn:SetSize(28, 28)
    closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE")
    closeTx:SetPoint("CENTER")
    closeTx:SetText("X")
    closeTx:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(TC("titleText")) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70) end)
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)

    -- Equipment Manager button
    local equipMgrBtn = CreateFrame("Button", nil, hdr)
    equipMgrBtn:SetSize(24, 24)
    equipMgrBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    local equipMgrIcon = equipMgrBtn:CreateTexture(nil, "OVERLAY")
    equipMgrIcon:SetAllPoints()
    equipMgrIcon:SetTexture("Interface\\Icons\\INV_Chest_Cloth_17")
    equipMgrIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    equipMgrIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    equipMgrBtn:SetScript("OnEnter", function(self)
        equipMgrIcon:SetVertexColor(TC("titleText"))
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Equipment Manager", 1, 1, 1)
        GameTooltip:Show()
    end)
    equipMgrBtn:SetScript("OnLeave", function()
        equipMgrIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
        GameTooltip:Hide()
    end)
    equipMgrBtn:SetScript("OnClick", function()
        Panel.ToggleEquipmentManager()
    end)

    -- Settings gear button
    local gearBtn = CreateFrame("Button", nil, hdr)
    gearBtn:SetSize(24, 24)
    gearBtn:SetPoint("RIGHT", equipMgrBtn, "LEFT", -6, 0)
    local gearIcon = gearBtn:CreateTexture(nil, "OVERLAY")
    gearIcon:SetAllPoints()
    gearIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
    gearIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    gearIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    gearBtn:SetScript("OnEnter", function() gearIcon:SetVertexColor(TC("titleText")) end)
    gearBtn:SetScript("OnLeave", function()
        gearIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    end)
    gearBtn:SetScript("OnClick", function()
        if R.settingsPopup and R.settingsPopup:IsShown() then
            R.settingsPopup:Hide()
        else
            Panel.ShowSettingsPopup()
        end
    end)
    R.gearBtn = gearBtn

    -- Draggable via header
    p:EnableMouse(true); p:SetMovable(true)
    hdr:EnableMouse(true); hdr:RegisterForDrag("LeftButton")
    hdr:SetScript("OnDragStart", function() p:StartMoving() end)
    hdr:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)

    -- ── 10c  Character Model (Center Hero) ─────────────────────────────
    local modelArea = CreateFrame("Frame", nil, p)
    modelArea:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    modelArea:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, CFG.TAB_BAR_H)
    R.modelArea = modelArea

    -- Dark base behind atlas
    local modelBgBase = modelArea:CreateTexture(nil, "BACKGROUND", nil, -8)
    modelBgBase:SetAllPoints()
    modelBgBase:SetColorTexture(0.02, 0.02, 0.03, 1)

    -- Hero atlas background
    local modelBg = modelArea:CreateTexture(nil, "BACKGROUND", nil, -7)
    modelBg:SetAllPoints()
    local atlasOk = pcall(modelBg.SetAtlas, modelBg, "completiondialog-midnightcampaign-background", false)
    if not atlasOk then
        modelBg:SetColorTexture(TC("modelBg"))
    end
    modelBg:SetAlpha(0.7)
    R.modelBg = modelBg

    -- Subtle vignette overlay (darkens edges, makes model pop)
    local vigTop = modelArea:CreateTexture(nil, "BACKGROUND", nil, -5)
    vigTop:SetHeight(120)
    vigTop:SetPoint("TOPLEFT", modelArea, "TOPLEFT", 0, 0)
    vigTop:SetPoint("TOPRIGHT", modelArea, "TOPRIGHT", 0, 0)
    vigTop:SetTexture(W8)
    if vigTop.SetGradient and CreateColor then
        vigTop:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0), CreateColor(0, 0, 0, 0.6))
    end
    local vigBot = modelArea:CreateTexture(nil, "BACKGROUND", nil, -5)
    vigBot:SetHeight(100)
    vigBot:SetPoint("BOTTOMLEFT", modelArea, "BOTTOMLEFT", 0, 0)
    vigBot:SetPoint("BOTTOMRIGHT", modelArea, "BOTTOMRIGHT", 0, 0)
    vigBot:SetTexture(W8)
    if vigBot.SetGradient and CreateColor then
        vigBot:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.7), CreateColor(0, 0, 0, 0))
    end

    local charModel = CreateFrame("PlayerModel", nil, modelArea)
    charModel:SetPoint("TOPLEFT", modelArea, "TOPLEFT", 0, 0)
    charModel:SetPoint("BOTTOMRIGHT", modelArea, "BOTTOMRIGHT", 0, 0)
    charModel:SetFrameLevel(modelArea:GetFrameLevel() + 2)
    R.charModel = charModel

    -- Model rotation (click-drag)
    charModel:EnableMouse(true)
    charModel:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            Panel._state.isDragging = true
            Panel._state.dragStartX = GetCursorPosition()
            Panel._state.dragStartFacing = Panel._state.modelFacing
        end
    end)
    charModel:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then
            Panel._state.isDragging = false
        end
    end)
    charModel:SetScript("OnUpdate", function(self)
        if Panel._state.isDragging then
            local cx = GetCursorPosition()
            local delta = (cx - Panel._state.dragStartX) * 0.01
            Panel._state.modelFacing = Panel._state.dragStartFacing + delta
            pcall(self.SetFacing, self, Panel._state.modelFacing)
        end
    end)

    -- Model zoom (mouse wheel)
    charModel:EnableMouseWheel(true)
    charModel:SetScript("OnMouseWheel", function(self, delta)
        local zoom = Panel._state.modelZoom - (delta * 0.1)
        zoom = math.max(0.5, math.min(2.0, zoom))
        Panel._state.modelZoom = zoom
        pcall(self.SetCamDistanceScale, self, zoom)
    end)

    -- ── 10d  Identity Strip (overlaid on model bottom) ─────────────────
    local identityBar = CreateFrame("Frame", nil, modelArea, "BackdropTemplate")
    identityBar:SetHeight(CFG.IDENTITY_H)
    identityBar:SetPoint("BOTTOMLEFT", modelArea, "BOTTOMLEFT", CFG.LEFT_GLASS_W + CFG.GLASS_MARGIN, 0)
    identityBar:SetPoint("BOTTOMRIGHT", modelArea, "BOTTOMRIGHT", -(CFG.RIGHT_GLASS_W + CFG.GLASS_MARGIN), 0)
    identityBar:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    identityBar:SetBackdropColor(0, 0, 0, 0.55)
    identityBar:SetBackdropBorderColor(1, 1, 1, 0.05)
    identityBar:SetFrameLevel(charModel:GetFrameLevel() + 5)
    R.identityBar = identityBar

    local nameFS = identityBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(nameFS, TITLE_FONT, 18, "OUTLINE")
    nameFS:SetPoint("TOP", identityBar, "TOP", 0, -10)
    nameFS:SetTextColor(TC("titleText"))
    nameFS:SetShadowColor(0, 0, 0, 0.9)
    nameFS:SetShadowOffset(2, -2)
    R.nameFS = nameFS

    -- Clickable overlay on name for title selection
    local nameBtn = CreateFrame("Button", nil, identityBar)
    nameBtn:SetPoint("TOPLEFT", nameFS, "TOPLEFT", -4, 4)
    nameBtn:SetPoint("BOTTOMRIGHT", nameFS, "BOTTOMRIGHT", 4, -4)
    nameBtn:SetFrameLevel(identityBar:GetFrameLevel() + 2)
    nameBtn:RegisterForClicks("RightButtonUp")
    nameBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("|cffaaaaaaRight Click:|r Change Title", 1, 1, 1)
        GameTooltip:Show()
    end)
    nameBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    nameBtn:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            Panel.ToggleTitlePicker()
        end
    end)

    local specFS = identityBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(specFS, BODY_FONT, 11, "")
    specFS:SetPoint("TOP", nameFS, "BOTTOM", 0, -4)
    specFS:SetTextColor(TC("bodyText"))
    specFS:SetShadowColor(0, 0, 0, 0.8)
    specFS:SetShadowOffset(1, -1)
    R.specFS = specFS

    -- ── 10e  Left Glass Panel (EQUIPMENT) ─────────────────────────────
    local leftGlass = CreateGlassPanel(modelArea, CFG.LEFT_GLASS_W)
    leftGlass:SetPoint("TOPLEFT", modelArea, "TOPLEFT", CFG.GLASS_MARGIN, -CFG.GLASS_MARGIN)
    leftGlass:SetPoint("BOTTOMLEFT", modelArea, "BOTTOMLEFT", CFG.GLASS_MARGIN, CFG.GLASS_MARGIN)
    leftGlass:SetFrameLevel(charModel:GetFrameLevel() + 3)
    R.leftGlass = leftGlass

    local gearLabel = leftGlass:CreateFontString(nil, "OVERLAY")
    TrySetFont(gearLabel, BODY_FONT, 10, "OUTLINE")
    gearLabel:SetPoint("TOPLEFT", leftGlass, "TOPLEFT", CFG.GLASS_PAD, -CFG.GLASS_PAD)
    gearLabel:SetText("EQUIPMENT")
    gearLabel:SetTextColor(TC("mutedText"))
    R.gearLabel = gearLabel

    local gearSlots = {}
    local GEAR_ROW_H = 36
    local GEAR_ROW_GAP = 2
    local GEAR_ICON_SIZE = 32

    for i, slotDef in ipairs(SLOT_LAYOUT) do
        local slotID = slotDef.id
        local slotName = slotDef.name

        local btn = CreateFrame("Button", nil, leftGlass)
        btn:SetHeight(GEAR_ROW_H)
        local yOfs = -(CFG.GLASS_PAD + 16 + (i - 1) * (GEAR_ROW_H + GEAR_ROW_GAP))
        btn:SetPoint("TOPLEFT", leftGlass, "TOPLEFT", 0, yOfs)
        btn:SetPoint("TOPRIGHT", leftGlass, "TOPRIGHT", 0, yOfs)

        -- Hover highlight
        local hoverBg = btn:CreateTexture(nil, "BACKGROUND")
        hoverBg:SetAllPoints()
        hoverBg:SetColorTexture(1, 1, 1, 0.05)
        hoverBg:Hide()
        btn._hoverBg = hoverBg

        -- Icon (32x32)
        local icon = btn:CreateTexture(nil, "ARTWORK")
        icon:SetSize(GEAR_ICON_SIZE, GEAR_ICON_SIZE)
        icon:SetPoint("LEFT", btn, "LEFT", CFG.GLASS_PAD, 0)
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
        btn._icon = icon

        -- Quality border (1px around icon)
        local bTop = btn:CreateTexture(nil, "OVERLAY"); bTop:SetHeight(1)
        bTop:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1); bTop:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 1, 1)
        bTop:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        local bBot = btn:CreateTexture(nil, "OVERLAY"); bBot:SetHeight(1)
        bBot:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -1, -1); bBot:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        bBot:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        local bLeft = btn:CreateTexture(nil, "OVERLAY"); bLeft:SetWidth(1)
        bLeft:SetPoint("TOPLEFT", icon, "TOPLEFT", -1, 1); bLeft:SetPoint("BOTTOMLEFT", icon, "BOTTOMLEFT", -1, -1)
        bLeft:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        local bRight = btn:CreateTexture(nil, "OVERLAY"); bRight:SetWidth(1)
        bRight:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 1, 1); bRight:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 1, -1)
        bRight:SetColorTexture(0.3, 0.3, 0.3, 0.5)
        btn._borderParts = { bTop, bBot, bLeft, bRight }

        -- Slot name (muted, small) — top line beside icon
        local slotLabelFS = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(slotLabelFS, BODY_FONT, 10, "")
        slotLabelFS:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -1)
        slotLabelFS:SetText(slotDef.label)
        slotLabelFS:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.6)
        btn._slotLabel = slotLabelFS

        -- Item name (quality colored) — bottom line beside icon, truncated
        local itemNameFS = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(itemNameFS, BODY_FONT, 10, "")
        itemNameFS:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 2)
        itemNameFS:SetPoint("RIGHT", btn, "RIGHT", -CFG.GLASS_PAD, 0)
        itemNameFS:SetJustifyH("LEFT")
        itemNameFS:SetWordWrap(false)
        itemNameFS:SetTextColor(TC("bodyText"))
        btn._itemName = itemNameFS

        -- iLvl (bottom-right corner of icon)
        local ilvlFS = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(ilvlFS, BODY_FONT, 9, "OUTLINE")
        ilvlFS:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", -1, 1)
        ilvlFS:SetJustifyH("RIGHT")
        ilvlFS:SetTextColor(1, 1, 1, 0.9)
        btn._ilvl = ilvlFS

        btn._slotID = slotID
        btn._slotName = slotName

        btn:SetScript("OnEnter", function(self)
            self._hoverBg:Show()
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            pcall(GameTooltip.SetInventoryItem, GameTooltip, "player", self._slotID)
            GameTooltip:Show()
        end)
        btn:SetScript("OnLeave", function(self) self._hoverBg:Hide(); GameTooltip:Hide() end)

        -- Overlay Blizzard's secure slot button (invisible) for item application.
        -- Deferred until Blizzard_CharacterUI is loaded.
        btn._muiSlotDef = slotDef

        gearSlots[slotID] = btn
    end
    R.gearSlots = gearSlots

    -- ── 10f  Right Glass Panel (ITEM LEVEL + ATTRIBUTES + ENHANCEMENTS) ─
    local rightGlass = CreateGlassPanel(modelArea, CFG.RIGHT_GLASS_W)
    rightGlass:SetPoint("TOPRIGHT", modelArea, "TOPRIGHT", -CFG.GLASS_MARGIN, -CFG.GLASS_MARGIN)
    rightGlass:SetPoint("BOTTOMRIGHT", modelArea, "BOTTOMRIGHT", -CFG.GLASS_MARGIN, CFG.GLASS_MARGIN)
    rightGlass:SetFrameLevel(charModel:GetFrameLevel() + 3)
    R.rightGlass = rightGlass

    -- ── Section 1: ITEM LEVEL ──────────────────────────────────────────
    local ilvlLabel = rightGlass:CreateFontString(nil, "OVERLAY")
    TrySetFont(ilvlLabel, BODY_FONT, 10, "OUTLINE")
    ilvlLabel:SetPoint("TOP", rightGlass, "TOP", 0, -18)
    ilvlLabel:SetText("ITEM LEVEL")
    ilvlLabel:SetTextColor(TC("mutedText"))
    R.ilvlLabel = ilvlLabel

    local ilvlValue = rightGlass:CreateFontString(nil, "OVERLAY")
    TrySetFont(ilvlValue, TITLE_FONT, 28, "OUTLINE")
    ilvlValue:SetPoint("TOP", ilvlLabel, "BOTTOM", 0, -4)
    ilvlValue:SetTextColor(TC("titleText"))
    ilvlValue:SetShadowColor(0, 0, 0, 0.8)
    ilvlValue:SetShadowOffset(2, -2)
    R.ilvlValue = ilvlValue

    local ilvlSep = rightGlass:CreateTexture(nil, "OVERLAY")
    ilvlSep:SetHeight(1)
    ilvlSep:SetPoint("LEFT", rightGlass, "LEFT", CFG.GLASS_PAD, 0)
    ilvlSep:SetPoint("RIGHT", rightGlass, "RIGHT", -CFG.GLASS_PAD, 0)
    ilvlSep:SetPoint("TOP", ilvlValue, "BOTTOM", 0, -16)
    ilvlSep:SetTexture(W8)
    if ilvlSep.SetGradient and CreateColor then
        ilvlSep:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.4))
    end

    -- ── Section 2: ATTRIBUTES ──────────────────────────────────────────
    local attrLabel = rightGlass:CreateFontString(nil, "OVERLAY")
    TrySetFont(attrLabel, BODY_FONT, 10, "OUTLINE")
    attrLabel:SetPoint("TOPLEFT", ilvlSep, "BOTTOMLEFT", 0, -10)
    attrLabel:SetText("ATTRIBUTES")
    attrLabel:SetTextColor(TC("mutedText"))
    R.attrLabel = attrLabel

    -- Up to 3 attribute cards (primary + stamina + armor)
    local MAX_ATTR = 3
    local MAX_SUBS = 3
    local attrRows = {}
    for i = 1, MAX_ATTR do
        -- Stat name in accent color
        local nameFS2 = rightGlass:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFS2, BODY_FONT, 11, "OUTLINE")
        nameFS2:SetTextColor(TC("accent"))
        nameFS2:SetJustifyH("LEFT")
        -- Stat value in title color
        local valFS = rightGlass:CreateFontString(nil, "OVERLAY")
        TrySetFont(valFS, BODY_FONT, 11, "")
        valFS:SetTextColor(TC("titleText"))
        valFS:SetJustifyH("RIGHT")

        if i == 1 then
            nameFS2:SetPoint("TOPLEFT", attrLabel, "BOTTOMLEFT", 0, -8)
        end
        nameFS2:SetPoint("LEFT", rightGlass, "LEFT", CFG.GLASS_PAD, 0)
        valFS:SetPoint("RIGHT", rightGlass, "RIGHT", -CFG.GLASS_PAD, 0)
        valFS:SetPoint("TOP", nameFS2, "TOP", 0, 0)

        -- Sub-stat lines: label in body text, value in green-ish highlight
        local subLines = {}
        for j = 1, MAX_SUBS do
            local subName = rightGlass:CreateFontString(nil, "OVERLAY")
            TrySetFont(subName, BODY_FONT, 10, "")
            subName:SetTextColor(TC("bodyText"))
            subName:SetJustifyH("LEFT")
            local subVal = rightGlass:CreateFontString(nil, "OVERLAY")
            TrySetFont(subVal, BODY_FONT, 10, "")
            subVal:SetTextColor(0.55, 0.85, 0.55, 0.9) -- green tint for derived values
            subVal:SetJustifyH("RIGHT")

            subName:SetPoint("LEFT", rightGlass, "LEFT", CFG.GLASS_PAD + 6, 0)
            subVal:SetPoint("RIGHT", rightGlass, "RIGHT", -CFG.GLASS_PAD, 0)
            subName:Hide(); subVal:Hide()

            subLines[j] = { name = subName, value = subVal }
        end

        nameFS2:Hide(); valFS:Hide()
        attrRows[i] = { name = nameFS2, value = valFS, subs = subLines }
    end
    R.attrRows = attrRows

    -- Separator between attributes and enhancements
    local attrEnhSep = rightGlass:CreateTexture(nil, "OVERLAY")
    attrEnhSep:SetHeight(1)
    attrEnhSep:SetPoint("LEFT", rightGlass, "LEFT", CFG.GLASS_PAD, 0)
    attrEnhSep:SetPoint("RIGHT", rightGlass, "RIGHT", -CFG.GLASS_PAD, 0)
    attrEnhSep:SetTexture(W8)
    if attrEnhSep.SetGradient and CreateColor then
        attrEnhSep:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.3),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0))
    end
    attrEnhSep:Hide()
    R.attrEnhSep = attrEnhSep

    -- ── Section 3: ENHANCEMENTS ────────────────────────────────────────
    local enhLabel = rightGlass:CreateFontString(nil, "OVERLAY")
    TrySetFont(enhLabel, BODY_FONT, 10, "OUTLINE")
    enhLabel:SetText("ENHANCEMENTS")
    enhLabel:SetTextColor(TC("mutedText"))
    enhLabel:Hide()
    R.enhLabel = enhLabel

    -- 7 enhancement rows (as buttons for tooltip support)
    local enhRows = {}
    for i = 1, 7 do
        local rowBtn = CreateFrame("Button", nil, rightGlass)
        rowBtn:SetHeight(20)
        rowBtn:SetPoint("LEFT", rightGlass, "LEFT", 0, 0)
        rowBtn:SetPoint("RIGHT", rightGlass, "RIGHT", 0, 0)

        local lbl = rowBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 11, "")
        lbl:SetJustifyH("LEFT")
        lbl:SetPoint("LEFT", rowBtn, "LEFT", CFG.GLASS_PAD, 0)

        local val = rowBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(val, BODY_FONT, 11, "")
        val:SetJustifyH("RIGHT")
        val:SetPoint("RIGHT", rowBtn, "RIGHT", -CFG.GLASS_PAD, 0)

        -- Rating (below label)
        local ratingFS = rowBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(ratingFS, BODY_FONT, 10, "")
        ratingFS:SetJustifyH("LEFT")
        ratingFS:SetTextColor(0.55, 0.85, 0.55, 0.7)

        rowBtn:Hide()
        enhRows[i] = { btn = rowBtn, label = lbl, value = val, rating = ratingFS }
    end
    R.enhRows = enhRows

    -- ── 10g  Tab Bar (bottom) ──────────────────────────────────────────
    local tabBar = CreateFrame("Frame", nil, p)
    tabBar:SetHeight(CFG.TAB_BAR_H)
    tabBar:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
    local tabBg = tabBar:CreateTexture(nil, "BACKGROUND")
    tabBg:SetAllPoints()
    tabBg:SetColorTexture(TC("headerBg"))
    R.tabBar = tabBar
    R.tabBg = tabBg

    -- Tab accent line at top of tab bar
    local tabAccent = tabBar:CreateTexture(nil, "OVERLAY")
    tabAccent:SetHeight(1)
    tabAccent:SetPoint("TOPLEFT", tabBar, "TOPLEFT", 0, 0)
    tabAccent:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", 0, 0)
    tabAccent:SetColorTexture(activeTheme.divider[1], activeTheme.divider[2], activeTheme.divider[3], 0.3)
    R.tabAccent = tabAccent

    local TAB_DEFS = {
        { key = "character",  label = "CHARACTER" },
        { key = "reputation", label = "REPUTATION" },
        { key = "currency",   label = "CURRENCY" },
    }
    local tabButtons = {}
    local tabWidth = CFG.WIDTH / #TAB_DEFS
    for i, def in ipairs(TAB_DEFS) do
        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetSize(tabWidth, CFG.TAB_BAR_H)
        btn:SetPoint("BOTTOMLEFT", tabBar, "BOTTOMLEFT", (i - 1) * tabWidth, 0)

        local label = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(label, BODY_FONT, 11, "OUTLINE")
        label:SetPoint("CENTER", btn, "CENTER", 0, 0)
        label:SetText(def.label)
        btn._label = label
        btn._key = def.key

        -- Active underline
        local underline = btn:CreateTexture(nil, "OVERLAY")
        underline:SetHeight(2)
        underline:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 20, 0)
        underline:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -20, 0)
        underline:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 1)
        underline:Hide()
        btn._underline = underline

        btn:SetScript("OnClick", function()
            Panel.SetActiveTab(def.key)
        end)
        btn:SetScript("OnEnter", function(self)
            if Panel._state.activeTab ~= self._key then
                self._label:SetTextColor(TC("bodyText"))
            end
        end)
        btn:SetScript("OnLeave", function(self)
            if Panel._state.activeTab ~= self._key then
                self._label:SetTextColor(TC("tabInactive"))
            end
        end)

        tabButtons[def.key] = btn
    end
    R.tabButtons = tabButtons

    -- ── 10h  Reputation Slide-In Overlay ───────────────────────────────
    local repOverlay = CreateFrame("Frame", nil, p, "BackdropTemplate")
    repOverlay:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    repOverlay:SetPoint("BOTTOMRIGHT", tabBar, "TOPRIGHT", 0, 0)
    repOverlay:SetBackdrop({ bgFile = W8 })
    repOverlay:SetBackdropColor(TC("frameBg"))
    repOverlay:SetFrameLevel(charModel:GetFrameLevel() + 10)
    repOverlay:EnableMouse(true)
    repOverlay:Hide()
    R.repOverlay = repOverlay

    -- Back button
    local repBack = CreateFrame("Button", nil, repOverlay)
    repBack:SetSize(80, 24)
    repBack:SetPoint("TOPLEFT", repOverlay, "TOPLEFT", 12, -10)
    local repBackFS = repBack:CreateFontString(nil, "OVERLAY")
    TrySetFont(repBackFS, BODY_FONT, 11, "OUTLINE")
    repBackFS:SetPoint("LEFT")
    repBackFS:SetText("< Back")
    repBackFS:SetTextColor(TC("accent"))
    repBack:SetScript("OnClick", function() Panel.SetActiveTab("character") end)
    repBack:SetScript("OnEnter", function() repBackFS:SetTextColor(TC("titleText")) end)
    repBack:SetScript("OnLeave", function() repBackFS:SetTextColor(TC("accent")) end)

    local repTitle = repOverlay:CreateFontString(nil, "OVERLAY")
    TrySetFont(repTitle, TITLE_FONT, 16, "OUTLINE")
    repTitle:SetPoint("TOP", repOverlay, "TOP", 0, -12)
    repTitle:SetText("Reputation")
    repTitle:SetTextColor(TC("titleText"))

    -- Reputation scroll frame
    local repScroll = CreateFrame("ScrollFrame", nil, repOverlay, "UIPanelScrollFrameTemplate")
    repScroll:SetPoint("TOPLEFT", repOverlay, "TOPLEFT", 10, -42)
    repScroll:SetPoint("BOTTOMRIGHT", repOverlay, "BOTTOMRIGHT", -28, 10)
    local repContent = CreateFrame("Frame", nil, repScroll)
    repContent:SetWidth(1)
    repScroll:SetScrollChild(repContent)
    repScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then repContent:SetWidth(w) end end)
    -- Style scrollbar
    if repScroll.ScrollBar then
        local sb = repScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.30); sb.ThumbTexture:SetWidth(4) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    R.repScroll = repScroll
    R.repContent = repContent

    -- ── 10i  Currency Slide-In Overlay ─────────────────────────────────
    local curOverlay = CreateFrame("Frame", nil, p, "BackdropTemplate")
    curOverlay:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    curOverlay:SetPoint("BOTTOMRIGHT", tabBar, "TOPRIGHT", 0, 0)
    curOverlay:SetBackdrop({ bgFile = W8 })
    curOverlay:SetBackdropColor(TC("frameBg"))
    curOverlay:SetFrameLevel(charModel:GetFrameLevel() + 10)
    curOverlay:EnableMouse(true)
    curOverlay:Hide()
    R.curOverlay = curOverlay

    local curBack = CreateFrame("Button", nil, curOverlay)
    curBack:SetSize(80, 24)
    curBack:SetPoint("TOPLEFT", curOverlay, "TOPLEFT", 12, -10)
    local curBackFS = curBack:CreateFontString(nil, "OVERLAY")
    TrySetFont(curBackFS, BODY_FONT, 11, "OUTLINE")
    curBackFS:SetPoint("LEFT")
    curBackFS:SetText("< Back")
    curBackFS:SetTextColor(TC("accent"))
    curBack:SetScript("OnClick", function() Panel.SetActiveTab("character") end)
    curBack:SetScript("OnEnter", function() curBackFS:SetTextColor(TC("titleText")) end)
    curBack:SetScript("OnLeave", function() curBackFS:SetTextColor(TC("accent")) end)

    local curTitle = curOverlay:CreateFontString(nil, "OVERLAY")
    TrySetFont(curTitle, TITLE_FONT, 16, "OUTLINE")
    curTitle:SetPoint("TOP", curOverlay, "TOP", 0, -12)
    curTitle:SetText("Currency")
    curTitle:SetTextColor(TC("titleText"))

    local curScroll = CreateFrame("ScrollFrame", nil, curOverlay, "UIPanelScrollFrameTemplate")
    curScroll:SetPoint("TOPLEFT", curOverlay, "TOPLEFT", 10, -42)
    curScroll:SetPoint("BOTTOMRIGHT", curOverlay, "BOTTOMRIGHT", -28, 10)
    local curContent = CreateFrame("Frame", nil, curScroll)
    curContent:SetWidth(1)
    curScroll:SetScrollChild(curContent)
    curScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then curContent:SetWidth(w) end end)
    if curScroll.ScrollBar then
        local sb = curScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.30); sb.ThumbTexture:SetWidth(4) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    R.curScroll = curScroll
    R.curContent = curContent

    -- ── 10j  Settings Popup ────────────────────────────────────────────
    local settingsPopup = CreateFrame("Frame", nil, p, "BackdropTemplate")
    settingsPopup:SetSize(180, 120)
    settingsPopup:SetPoint("TOPRIGHT", gearBtn, "BOTTOMRIGHT", 0, -4)
    settingsPopup:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    settingsPopup:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    settingsPopup:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.5)
    settingsPopup:SetFrameLevel(p:GetFrameLevel() + 20)
    settingsPopup:Hide()
    R.settingsPopup = settingsPopup

    local popupTitle = settingsPopup:CreateFontString(nil, "OVERLAY")
    TrySetFont(popupTitle, BODY_FONT, 10, "OUTLINE")
    popupTitle:SetPoint("TOP", settingsPopup, "TOP", 0, -8)
    popupTitle:SetText("Theme")
    popupTitle:SetTextColor(TC("mutedText"))

    local themeOptions = {
        { key = "parchment", label = "Warm Parchment" },
        { key = "midnight",  label = "Cool Midnight" },
        { key = "class",     label = "Class Color" },
    }
    for i, opt in ipairs(themeOptions) do
        local btn = CreateFrame("Button", nil, settingsPopup)
        btn:SetSize(160, 24)
        btn:SetPoint("TOP", settingsPopup, "TOP", 0, -24 - (i - 1) * 28)
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 11, "")
        lbl:SetPoint("CENTER")
        lbl:SetText(opt.label)
        lbl:SetTextColor(TC("bodyText"))
        btn:SetScript("OnClick", function()
            local s = _G.MidnightUISettings
            if s and s.General then
                s.General.characterPanelTheme = opt.key
            end
            Panel.ApplyTheme()
            settingsPopup:Hide()
        end)
        btn:SetScript("OnEnter", function() lbl:SetTextColor(TC("titleText")) end)
        btn:SetScript("OnLeave", function() lbl:SetTextColor(TC("bodyText")) end)
    end

    -- ESC to close
    p:SetScript("OnShow", function()
        local found = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "MidnightUI_CharacterPanel" then found = true; break end
        end
        if not found then table.insert(UISpecialFrames, "MidnightUI_CharacterPanel") end
    end)
    p:SetScript("OnHide", function()
        Panel._state.panelOpen = false
        if R.settingsPopup then R.settingsPopup:Hide() end
    end)

    -- Fade animations
    local fadeIn = p:CreateAnimationGroup()
    local fadeInAnim = fadeIn:CreateAnimation("Alpha")
    fadeInAnim:SetFromAlpha(0); fadeInAnim:SetToAlpha(1); fadeInAnim:SetDuration(0.20); fadeInAnim:SetSmoothing("OUT")
    p._fadeIn = fadeIn

    local fadeOut = p:CreateAnimationGroup()
    local fadeOutAnim = fadeOut:CreateAnimation("Alpha")
    fadeOutAnim:SetFromAlpha(1); fadeOutAnim:SetToAlpha(0); fadeOutAnim:SetDuration(0.15); fadeOutAnim:SetSmoothing("IN")
    fadeOut:SetScript("OnFinished", function() p:Hide(); p:SetAlpha(1) end)
    p._fadeOut = fadeOut

    return p
end

-- ============================================================================
-- S11  UPDATE FUNCTIONS
-- ============================================================================
function Panel.UpdateModel()
    local R = Panel._refs
    if not R.charModel then return end
    R.charModel:ClearModel()
    R.charModel:SetUnit("player")
    pcall(R.charModel.SetPortraitZoom, R.charModel, 0)
    pcall(R.charModel.SetFacing, R.charModel, Panel._state.modelFacing)
    pcall(R.charModel.SetPosition, R.charModel, 0, 0, -0.15)
    pcall(R.charModel.SetCamDistanceScale, R.charModel, Panel._state.modelZoom)
    local L = CFG.modelLight
    pcall(R.charModel.SetLight, R.charModel,
        L[1], L[2], L[3], L[4], L[5], L[6], L[7], L[8], L[9], L[10], L[11], L[12], L[13])
end

function Panel.UpdateIdentity()
    local R = Panel._refs
    if not R.nameFS then return end

    local name = SafeCall(UnitName, "player") or "Unknown"
    local titleID = SafeCall(GetCurrentTitle) or 0
    if titleID > 0 and GetTitleName then
        local raw = SafeCall(GetTitleName, titleID) or ""
        raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
        if raw ~= "" then
            if raw:sub(1,1) == raw:sub(1,1):lower() then
                R.nameFS:SetText(name .. " " .. raw)
            else
                R.nameFS:SetText(raw .. " " .. name)
            end
        else
            R.nameFS:SetText(name)
        end
    else
        R.nameFS:SetText(name)
    end

    local specName, className = "", ""
    local specIdx = SafeCall(GetSpecialization)
    if specIdx then
        local _, sName = SafeCall(GetSpecializationInfo, specIdx)
        specName = sName or ""
    end
    local _, classToken = SafeCall(UnitClass, "player")
    className = classToken and classToken:sub(1,1) .. classToken:sub(2):lower() or ""
    -- Use localized class name
    local localizedClass = SafeCall(UnitClass, "player") or className

    local level = SafeCall(UnitLevel, "player") or 0
    R.specFS:SetText(specName .. "  " .. localizedClass .. "  \194\183  Level " .. level)
end

function Panel.UpdateGearSlots()
    local R = Panel._refs
    if not R.gearSlots then return end
    for slotID, btn in pairs(R.gearSlots) do
        local tex = SafeCall(GetInventoryItemTexture, "player", slotID)
        if tex then
            btn._icon:SetTexture(tex)
            btn._icon:SetVertexColor(1, 1, 1, 1)
            local link = SafeCall(GetInventoryItemLink, "player", slotID)
            if link then
                local itemName, _, quality = SafeCall(GetItemInfo, link)
                local r, g, b = GetQualityColorRGB(quality or 1)
                -- Quality border on icon
                for _, part in ipairs(btn._borderParts) do
                    part:SetColorTexture(r, g, b, 0.8)
                end
                -- Item name colored by quality
                if btn._itemName then
                    btn._itemName:SetText(itemName or "")
                    btn._itemName:SetTextColor(r, g, b)
                end
                -- Slot label stays muted
                if btn._slotLabel then
                    btn._slotLabel:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.7)
                end
                -- Individual ilvl
                local ilvl = nil
                if C_Item and C_Item.GetDetailedItemLevelInfo then
                    ilvl = SafeCall(C_Item.GetDetailedItemLevelInfo, link)
                end
                btn._ilvl:SetText(ilvl and tostring(ilvl) or "")
                btn._ilvl:SetTextColor(TC("mutedText"))
            end
        else
            -- Empty slot — show a dim question mark, no item name
            btn._icon:SetTexture("Interface\\PaperDoll\\UI-Backpack-EmptySlot")
            btn._icon:SetVertexColor(1, 1, 1, 0.15)
            btn._icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            for _, part in ipairs(btn._borderParts) do
                part:SetColorTexture(0.3, 0.3, 0.3, 0.1)
            end
            if btn._itemName then
                btn._itemName:SetText("Empty")
                btn._itemName:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.3)
            end
            if btn._slotLabel then
                btn._slotLabel:SetTextColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.4)
            end
            btn._ilvl:SetText("")
        end
    end
end

function Panel.UpdateItemLevel()
    local R = Panel._refs
    if not R.ilvlValue then return end
    local equipped, overall = SafeCall(GetAverageItemLevel)
    R.ilvlValue:SetText(tostring(math.floor((equipped or 0) + 0.5)))
end

function Panel.UpdatePrimaryStats()
    local R = Panel._refs
    if not R.attrRows then return end
    local stats = GetPrimaryStats()
    local PAD = CFG.GLASS_PAD
    local SUB_INDENT = 12

    -- Hide all first
    for i = 1, #R.attrRows do
        R.attrRows[i].name:Hide(); R.attrRows[i].value:Hide()
        for j = 1, #R.attrRows[i].subs do
            R.attrRows[i].subs[j].name:Hide(); R.attrRows[i].subs[j].value:Hide()
        end
    end

    local lastAnchor = R.attrLabel
    for i, data in ipairs(stats) do
        local row = R.attrRows[i]
        if not row then break end

        row.name:SetText(data.name)
        row.value:SetText(FormatNumber(data.value))
        row.name:ClearAllPoints()
        row.name:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, (i == 1) and -8 or -12)
        row.name:SetPoint("LEFT", R.rightGlass, "LEFT", PAD, 0)
        row.value:ClearAllPoints()
        row.value:SetPoint("RIGHT", R.rightGlass, "RIGHT", -PAD, 0)
        row.value:SetPoint("TOP", row.name, "TOP", 0, 0)
        row.name:Show(); row.value:Show()

        local subAnchor = row.name
        for j, sub in ipairs(data.subs or {}) do
            local subRow = row.subs[j]
            if not subRow then break end
            subRow.name:SetText(sub.label)
            subRow.value:SetText(sub.value)
            subRow.name:ClearAllPoints()
            subRow.name:SetPoint("TOPLEFT", subAnchor, "BOTTOMLEFT", 0, -3)
            subRow.name:SetPoint("LEFT", R.rightGlass, "LEFT", PAD + SUB_INDENT, 0)
            subRow.value:ClearAllPoints()
            subRow.value:SetPoint("RIGHT", R.rightGlass, "RIGHT", -PAD, 0)
            subRow.value:SetPoint("TOP", subRow.name, "TOP", 0, 0)
            subRow.name:Show(); subRow.value:Show()
            subAnchor = subRow.name
        end

        lastAnchor = subAnchor
    end

    -- Position the separator and enhancements label below the last attribute
    if R.attrEnhSep then
        R.attrEnhSep:ClearAllPoints()
        R.attrEnhSep:SetPoint("LEFT", R.rightGlass, "LEFT", PAD, 0)
        R.attrEnhSep:SetPoint("RIGHT", R.rightGlass, "RIGHT", -PAD, 0)
        R.attrEnhSep:SetPoint("TOP", lastAnchor, "BOTTOM", 0, -14)
        R.attrEnhSep:Show()
    end
    if R.enhLabel then
        R.enhLabel:ClearAllPoints()
        R.enhLabel:SetPoint("TOPLEFT", R.attrEnhSep, "BOTTOMLEFT", 0, -10)
        R.enhLabel:Show()
    end
end

function Panel.UpdateEnhancements()
    local R = Panel._refs
    if not R.enhRows or not R.enhLabel then return end
    local stats = GetEnhancementStats()
    local PAD = CFG.GLASS_PAD

    -- Hide all first
    for i = 1, #R.enhRows do
        R.enhRows[i].btn:Hide()
        R.enhRows[i].rating:Hide()
    end

    local lastAnchor = R.enhLabel
    local compactSepPlaced = false
    for i, data in ipairs(stats) do
        local row = R.enhRows[i]
        if not row then break end

        row.label:SetText(data.label)
        row.value:SetText(string.format("%.1f%%", data.value or 0))

        -- Gap: 8px between detailed, 14px before compact group, 6px between compact
        local topGap = -8
        if not data.detailed then
            if not compactSepPlaced then
                compactSepPlaced = true
                topGap = -14
            else
                topGap = -6
            end
        end

        if data.detailed then
            row.label:SetTextColor(TC("accent"))
            row.value:SetTextColor(TC("titleText"))
        else
            row.label:SetTextColor(0.60, 0.75, 0.85)  -- cool blue-grey for tertiary stats
            row.value:SetTextColor(0.60, 0.75, 0.85)
        end

        row.btn:ClearAllPoints()
        row.btn:SetPoint("TOPLEFT", lastAnchor, "BOTTOMLEFT", 0, topGap)
        row.btn:SetPoint("LEFT", R.rightGlass, "LEFT", 0, 0)
        row.btn:SetPoint("RIGHT", R.rightGlass, "RIGHT", 0, 0)
        row.btn:Show()

        lastAnchor = row.btn

        if data.detailed then
            local rating = data.rating or 0
            if rating > 0 then
                row.rating:SetText(FormatNumber(rating) .. " rating")
                row.rating:ClearAllPoints()
                row.rating:SetPoint("TOPLEFT", row.label, "BOTTOMLEFT", 0, -2)
                row.rating:Show()
                -- Increase button height to fit rating line
                row.btn:SetHeight(32)
                lastAnchor = row.btn
            else
                row.btn:SetHeight(20)
            end

            -- Tooltip with description
            local tipTitle = data.label
            local tipPct = string.format("%.1f%%", data.value or 0)
            local tipRating = rating > 0 and (FormatNumber(rating) .. " rating") or nil
            local tipDesc = data.desc
            row.btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText(tipTitle, activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3])
                GameTooltip:AddLine(tipPct, 1, 1, 1)
                if tipRating then
                    GameTooltip:AddLine(tipRating, 0.55, 0.85, 0.55)
                end
                if tipDesc then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(tipDesc, TC("bodyText"))
                end
                GameTooltip:Show()
            end)
            row.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        else
            row.btn:SetHeight(20)
            local tipTitle = data.label
            local tipPct = string.format("%.1f%%", data.value or 0)
            local tipRating = (data.rating or 0) > 0 and (FormatNumber(data.rating) .. " rating") or nil
            local tipDesc = data.desc
            row.btn:SetScript("OnEnter", function(self)
                GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                GameTooltip:SetText(tipTitle, activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3])
                GameTooltip:AddLine(tipPct, 1, 1, 1)
                if tipRating then
                    GameTooltip:AddLine(tipRating, 0.55, 0.85, 0.55)
                end
                if tipDesc then
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine(tipDesc, TC("bodyText"))
                end
                GameTooltip:Show()
            end)
            row.btn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        end
    end
end

-- Track which reputation groups are expanded
local repExpandedState = {}

-- Custom right-click context menu for reputation rows (built once, reused)
local repCtxMenu, repCtxOverlay

local function EnsureRepContextMenu()
    if repCtxMenu then return end
    local R = Panel._refs
    local parent = R.panel

    repCtxMenu = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    repCtxMenu:SetSize(170, 36)
    repCtxMenu:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    repCtxMenu:SetBackdropColor(TC("headerBg"))
    repCtxMenu:SetBackdropBorderColor(TC("accent"))
    repCtxMenu:SetFrameLevel(parent:GetFrameLevel() + 30)
    repCtxMenu:Hide()

    -- Single action button
    local btn = CreateFrame("Button", nil, repCtxMenu)
    btn:SetHeight(24)
    btn:SetPoint("TOPLEFT", repCtxMenu, "TOPLEFT", 1, -6)
    btn:SetPoint("TOPRIGHT", repCtxMenu, "TOPRIGHT", -1, -6)
    local hv = btn:CreateTexture(nil, "BACKGROUND")
    hv:SetAllPoints()
    hv:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.08)
    hv:Hide()
    local fs = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(fs, BODY_FONT, 11, "")
    fs:SetPoint("LEFT", btn, "LEFT", 10, 0)
    fs:SetTextColor(TC("bodyText"))
    btn:SetScript("OnEnter", function() hv:Show() end)
    btn:SetScript("OnLeave", function() hv:Hide() end)
    repCtxMenu._actionBtn = btn
    repCtxMenu._actionFS = fs

    -- Click-catcher overlay to dismiss when clicking elsewhere
    repCtxOverlay = CreateFrame("Button", nil, parent)
    repCtxOverlay:SetAllPoints(UIParent)
    repCtxOverlay:SetFrameLevel(repCtxMenu:GetFrameLevel() - 1)
    repCtxOverlay:RegisterForClicks("AnyUp")
    repCtxOverlay:SetScript("OnClick", function()
        repCtxMenu:Hide(); repCtxOverlay:Hide()
    end)
    repCtxOverlay:Hide()

    repCtxMenu:HookScript("OnShow", function() repCtxOverlay:Show() end)
    repCtxMenu:HookScript("OnHide", function() repCtxOverlay:Hide() end)
end

function Panel.OpenRepContextMenu(anchorFrame, factionID, factionIndex, isWatched)
    if not factionIndex then return end
    EnsureRepContextMenu()

    local label = isWatched and "Stop Tracking" or "Track Reputation"
    repCtxMenu._actionFS:SetText(label)
    repCtxMenu._actionBtn:SetScript("OnClick", function()
        repCtxMenu:Hide()
        if C_Reputation and C_Reputation.SetWatchedFactionByIndex then
            if isWatched then
                pcall(C_Reputation.SetWatchedFactionByIndex, 0)
            else
                pcall(C_Reputation.SetWatchedFactionByIndex, factionIndex)
            end
            Panel.UpdateReputation()
        end
    end)

    repCtxMenu:ClearAllPoints()
    local cx, cy = GetCursorPosition()
    local scale = UIParent:GetEffectiveScale()
    repCtxMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
    repCtxMenu:Show()
end

function Panel.UpdateReputation()
    local R = Panel._refs
    if not R.repContent then return end

    -- Clear existing content
    local children = { R.repContent:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { R.repContent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local groups = CollectReputations()
    local PAD = 12
    local HDR_H = 32
    local ROW_H = 44
    local yOfs = 4

    -- Determine currently watched faction for tracking indicator
    local watchedFactionID
    if C_Reputation and C_Reputation.GetWatchedFactionData then
        local wd = C_Reputation.GetWatchedFactionData()
        if wd then watchedFactionID = wd.factionID end
    end

    for gi, group in ipairs(groups) do
        local groupKey = group.name
        if repExpandedState[groupKey] == nil then repExpandedState[groupKey] = false end
        local isExpanded = repExpandedState[groupKey]

        -- ── Group header (clickable, collapsible) ──
        local hdrBtn = CreateFrame("Button", nil, R.repContent)
        hdrBtn:EnableMouse(true)
        hdrBtn:RegisterForClicks("LeftButtonUp")
        hdrBtn:SetHeight(HDR_H)
        hdrBtn:SetPoint("TOPLEFT", R.repContent, "TOPLEFT", 0, -yOfs)
        hdrBtn:SetPoint("TOPRIGHT", R.repContent, "TOPRIGHT", 0, -yOfs)

        -- Header background (neutral warm)
        local hdrBg = hdrBtn:CreateTexture(nil, "BACKGROUND")
        hdrBg:SetAllPoints()
        hdrBg:SetColorTexture(0.12, 0.10, 0.08, 0.35)

        -- Chevron
        local chevron = hdrBtn:CreateTexture(nil, "OVERLAY")
        chevron:SetSize(10, 10)
        chevron:SetPoint("LEFT", hdrBtn, "LEFT", PAD, 0)
        chevron:SetAtlas("common-dropdown-icon-back")
        if isExpanded then
            chevron:SetRotation(-math.pi / 2) -- pointing down
        else
            chevron:SetRotation(math.pi)       -- pointing right
        end
        chevron:SetVertexColor(0.30, 0.85, 0.40)

        -- Group name
        local hdrName = hdrBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(hdrName, BODY_FONT, 11, "OUTLINE")
        hdrName:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
        hdrName:SetText(group.name)
        hdrName:SetTextColor(TC("accent"))

        -- Faction count
        local countFS = hdrBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(countFS, BODY_FONT, 10, "")
        countFS:SetPoint("RIGHT", hdrBtn, "RIGHT", -PAD, 0)
        countFS:SetText(#group.factions)
        countFS:SetTextColor(TC("mutedText"))

        -- Hover
        local hdrHover = hdrBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
        hdrHover:SetAllPoints()
        hdrHover:SetColorTexture(0.18, 0.15, 0.12, 0.3)
        hdrHover:Hide()
        hdrBtn:SetScript("OnEnter", function() hdrHover:Show() end)
        hdrBtn:SetScript("OnLeave", function() hdrHover:Hide() end)

        -- Bottom border
        local hdrSep = hdrBtn:CreateTexture(nil, "OVERLAY")
        hdrSep:SetHeight(1)
        hdrSep:SetPoint("BOTTOMLEFT", hdrBtn, "BOTTOMLEFT", PAD, 0)
        hdrSep:SetPoint("BOTTOMRIGHT", hdrBtn, "BOTTOMRIGHT", -PAD, 0)
        hdrSep:SetColorTexture(activeTheme.divider[1], activeTheme.divider[2], activeTheme.divider[3], 0.15)

        -- Click to toggle
        local capturedKey = groupKey
        hdrBtn:SetScript("OnClick", function()
            repExpandedState[capturedKey] = not repExpandedState[capturedKey]
            Panel.UpdateReputation()
        end)
        hdrBtn:Show()
        yOfs = yOfs + HDR_H

        -- ── Faction rows (only if expanded) ──
        if isExpanded then
            for fi, faction in ipairs(group.factions) do
                local isWatched = (faction.factionID and faction.factionID == watchedFactionID)

                local rowBtn = CreateFrame("Button", nil, R.repContent)
                rowBtn:EnableMouse(true)
                rowBtn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                rowBtn:SetHeight(ROW_H)
                rowBtn:SetPoint("TOPLEFT", R.repContent, "TOPLEFT", 0, -yOfs)
                rowBtn:SetPoint("TOPRIGHT", R.repContent, "TOPRIGHT", 0, -yOfs)

                -- Hover
                local rowHover = rowBtn:CreateTexture(nil, "BACKGROUND")
                rowHover:SetAllPoints()
                rowHover:SetColorTexture(1, 1, 1, 0.03)
                rowHover:Hide()

                -- Watched-faction highlight (subtle tint behind the row)
                if isWatched then
                    local watchedBg = rowBtn:CreateTexture(nil, "BACKGROUND", nil, -1)
                    watchedBg:SetAllPoints()
                    watchedBg:SetColorTexture(faction.standingColor[1], faction.standingColor[2], faction.standingColor[3], 0.06)
                end

                -- Standing color accent bar (left edge)
                local accentBar = rowBtn:CreateTexture(nil, "OVERLAY")
                accentBar:SetWidth(3)
                accentBar:SetPoint("TOPLEFT", rowBtn, "TOPLEFT", 0, -4)
                accentBar:SetPoint("BOTTOMLEFT", rowBtn, "BOTTOMLEFT", 0, 4)
                accentBar:SetColorTexture(faction.standingColor[1], faction.standingColor[2], faction.standingColor[3], isWatched and 1 or 0.7)

                -- Faction name
                local nameFS = rowBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(nameFS, BODY_FONT, 11, "")
                nameFS:SetPoint("TOPLEFT", rowBtn, "TOPLEFT", PAD + 8, -6)
                nameFS:SetPoint("RIGHT", rowBtn, "RIGHT", -80, 0)
                nameFS:SetJustifyH("LEFT")
                nameFS:SetWordWrap(false)
                nameFS:SetText(faction.name)
                nameFS:SetTextColor(TC("bodyText"))

                -- Standing name (right)
                local standingFS = rowBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(standingFS, BODY_FONT, 10, "")
                standingFS:SetPoint("TOPRIGHT", rowBtn, "TOPRIGHT", -PAD, -6)
                standingFS:SetText(faction.standingName)
                standingFS:SetTextColor(faction.standingColor[1], faction.standingColor[2], faction.standingColor[3])

                -- Rep progress text (below name)
                local repTextFS = rowBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(repTextFS, BODY_FONT, 10, "")
                repTextFS:SetPoint("BOTTOMLEFT", rowBtn, "BOTTOMLEFT", PAD + 8, 10)
                local repText = FormatNumber(faction.currentRep) .. " / " .. FormatNumber(faction.maxRep)
                repTextFS:SetText(repText)
                repTextFS:SetTextColor(TC("mutedText"))

                -- Progress bar
                local track = rowBtn:CreateTexture(nil, "ARTWORK")
                track:SetHeight(3)
                track:SetPoint("BOTTOMLEFT", rowBtn, "BOTTOMLEFT", PAD + 8, 4)
                track:SetPoint("BOTTOMRIGHT", rowBtn, "BOTTOMRIGHT", -PAD, 4)
                track:SetColorTexture(0.12, 0.12, 0.14, 0.6)

                local fill = rowBtn:CreateTexture(nil, "ARTWORK", nil, 1)
                fill:SetHeight(3)
                fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
                fill:SetWidth(math.max(1, 1))
                fill:SetColorTexture(faction.standingColor[1], faction.standingColor[2], faction.standingColor[3], 0.8)

                -- Deferred width for progress bar
                local capturedProgress = faction.progress
                rowBtn:SetScript("OnSizeChanged", function()
                    local w = track:GetWidth()
                    if w > 0 then fill:SetWidth(math.max(1, w * capturedProgress)) end
                end)

                -- Right-click opens context menu
                local capturedFactionIndex = faction.factionIndex
                local capturedFactionID = faction.factionID
                rowBtn:SetScript("OnClick", function(self, btn)
                    if btn == "RightButton" and capturedFactionIndex then
                        Panel.OpenRepContextMenu(self, capturedFactionID, capturedFactionIndex, isWatched)
                    end
                end)

                rowBtn:SetScript("OnEnter", function() rowHover:Show() end)
                rowBtn:SetScript("OnLeave", function() rowHover:Hide() end)

                rowBtn:Show()
                yOfs = yOfs + ROW_H
            end
        end
    end

    R.repContent:SetHeight(math.max(yOfs + 20, 1))
end

-- Track which currency groups are expanded
local curExpandedState = {}

function Panel.UpdateCurrency()
    local R = Panel._refs
    if not R.curContent then return end

    local children = { R.curContent:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { R.curContent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local groups = CollectCurrencies()
    local PAD = 12
    local HDR_H = 32
    local ROW_H = 32
    local yOfs = 4

    for _, group in ipairs(groups) do
        local groupKey = group.name
        if curExpandedState[groupKey] == nil then curExpandedState[groupKey] = false end
        local isExpanded = curExpandedState[groupKey]

        -- ── Category header (collapsible) ──
        local hdrBtn = CreateFrame("Button", nil, R.curContent)
        hdrBtn:EnableMouse(true)
        hdrBtn:RegisterForClicks("LeftButtonUp")
        hdrBtn:SetHeight(HDR_H)
        hdrBtn:SetPoint("TOPLEFT", R.curContent, "TOPLEFT", 0, -yOfs)
        hdrBtn:SetPoint("TOPRIGHT", R.curContent, "TOPRIGHT", 0, -yOfs)

        local hdrBg = hdrBtn:CreateTexture(nil, "BACKGROUND")
        hdrBg:SetAllPoints()
        hdrBg:SetColorTexture(0.12, 0.10, 0.08, 0.35)

        local chevron = hdrBtn:CreateTexture(nil, "OVERLAY")
        chevron:SetSize(10, 10)
        chevron:SetPoint("LEFT", hdrBtn, "LEFT", PAD, 0)
        chevron:SetAtlas("common-dropdown-icon-back")
        if isExpanded then
            chevron:SetRotation(-math.pi / 2)
        else
            chevron:SetRotation(math.pi)
        end
        chevron:SetVertexColor(0.30, 0.85, 0.40)

        local hdrName = hdrBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(hdrName, BODY_FONT, 11, "OUTLINE")
        hdrName:SetPoint("LEFT", chevron, "RIGHT", 6, 0)
        hdrName:SetText(group.name)
        hdrName:SetTextColor(TC("accent"))

        local countFS = hdrBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(countFS, BODY_FONT, 10, "")
        countFS:SetPoint("RIGHT", hdrBtn, "RIGHT", -PAD, 0)
        countFS:SetText(#group.currencies)
        countFS:SetTextColor(TC("mutedText"))

        local hdrHover = hdrBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
        hdrHover:SetAllPoints()
        hdrHover:SetColorTexture(0.18, 0.15, 0.12, 0.3)
        hdrHover:Hide()
        hdrBtn:SetScript("OnEnter", function() hdrHover:Show() end)
        hdrBtn:SetScript("OnLeave", function() hdrHover:Hide() end)

        local hdrSep = hdrBtn:CreateTexture(nil, "OVERLAY")
        hdrSep:SetHeight(1)
        hdrSep:SetPoint("BOTTOMLEFT", hdrBtn, "BOTTOMLEFT", PAD, 0)
        hdrSep:SetPoint("BOTTOMRIGHT", hdrBtn, "BOTTOMRIGHT", -PAD, 0)
        hdrSep:SetColorTexture(activeTheme.divider[1], activeTheme.divider[2], activeTheme.divider[3], 0.15)

        local capturedKey = groupKey
        hdrBtn:SetScript("OnClick", function()
            curExpandedState[capturedKey] = not curExpandedState[capturedKey]
            Panel.UpdateCurrency()
        end)
        hdrBtn:Show()
        yOfs = yOfs + HDR_H

        -- ── Currency rows (only if expanded) ──
        if isExpanded then
            for _, cur in ipairs(group.currencies) do
                local rowBtn = CreateFrame("Button", nil, R.curContent)
                rowBtn:SetHeight(ROW_H)
                rowBtn:SetPoint("TOPLEFT", R.curContent, "TOPLEFT", 0, -yOfs)
                rowBtn:SetPoint("TOPRIGHT", R.curContent, "TOPRIGHT", 0, -yOfs)

                local rowHover = rowBtn:CreateTexture(nil, "BACKGROUND")
                rowHover:SetAllPoints()
                rowHover:SetColorTexture(1, 1, 1, 0.03)
                rowHover:Hide()

                -- Icon
                if cur.iconFileID then
                    local icon = rowBtn:CreateTexture(nil, "ARTWORK")
                    icon:SetSize(20, 20)
                    icon:SetPoint("LEFT", rowBtn, "LEFT", PAD + 8, 0)
                    icon:SetTexture(cur.iconFileID)
                    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
                end

                local nameFS = rowBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(nameFS, BODY_FONT, 11, "")
                nameFS:SetPoint("LEFT", rowBtn, "LEFT", PAD + 34, 0)
                nameFS:SetPoint("RIGHT", rowBtn, "RIGHT", -80, 0)
                nameFS:SetJustifyH("LEFT")
                nameFS:SetWordWrap(false)
                nameFS:SetText(cur.name)
                nameFS:SetTextColor(TC("bodyText"))

                local qtyFS = rowBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(qtyFS, BODY_FONT, 11, "")
                qtyFS:SetPoint("RIGHT", rowBtn, "RIGHT", -PAD, 0)
                qtyFS:SetJustifyH("RIGHT")
                local qtyText = FormatNumber(cur.quantity)
                if cur.maxQuantity and cur.maxQuantity > 0 then
                    qtyText = qtyText .. " / " .. FormatNumber(cur.maxQuantity)
                end
                qtyFS:SetText(qtyText)
                qtyFS:SetTextColor(TC("titleText"))

                -- Tooltip with currency details
                local capturedCurID = cur.currencyID
                rowBtn:SetScript("OnEnter", function(self)
                    rowHover:Show()
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    if capturedCurID and GameTooltip.SetCurrencyByID then
                        pcall(GameTooltip.SetCurrencyByID, GameTooltip, capturedCurID)
                    else
                        GameTooltip:SetText(cur.name, 1, 1, 1)
                        GameTooltip:AddLine(qtyText, TC("titleText"))
                    end
                    GameTooltip:Show()
                end)
                rowBtn:SetScript("OnLeave", function() rowHover:Hide(); GameTooltip:Hide() end)

                rowBtn:Show()
                yOfs = yOfs + ROW_H
            end
        end
    end

    R.curContent:SetHeight(math.max(yOfs + 20, 1))
end

-- ============================================================================
-- S12  TAB SWITCHING
-- ============================================================================
function Panel.SetActiveTab(key)
    Panel._state.activeTab = key
    local R = Panel._refs
    if not R.tabButtons then return end

    -- Update tab button visuals
    for k, btn in pairs(R.tabButtons) do
        if k == key then
            btn._label:SetTextColor(TC("tabActive"))
            btn._underline:Show()
        else
            btn._label:SetTextColor(TC("tabInactive"))
            btn._underline:Hide()
        end
    end

    -- Show/hide content
    if R.repOverlay then R.repOverlay:Hide() end
    if R.curOverlay then R.curOverlay:Hide() end

    -- Hide character tab elements when on other tabs so nothing bleeds through
    local showChar = (key == "character")
    if R.modelArea then R.modelArea:SetShown(showChar) end
    if R.leftGlass then R.leftGlass:SetShown(showChar) end
    if R.rightGlass then R.rightGlass:SetShown(showChar) end
    if R.identityBar then R.identityBar:SetShown(showChar) end

    if key == "character" then
        -- Character view shown above
    elseif key == "reputation" then
        Panel.UpdateReputation()
        R.repOverlay:Show()
    elseif key == "currency" then
        Panel.UpdateCurrency()
        R.curOverlay:Show()
    end
end

-- ============================================================================
-- S13  SHOW / HIDE / TOGGLE
-- ============================================================================
function Panel.Show(tab)
    local p = Panel.EnsurePanel()
    if not p then return end

    -- Close other MidnightUI panels to prevent overlap
    local gfHide = _G.MidnightUI_GroupFinder_Hide
    if gfHide then gfHide() end
    local guildFrame = _G["MidnightUI_GuildPanel"]
    if guildFrame and guildFrame:IsShown() then guildFrame:Hide() end

    GetActiveTheme()
    Panel._state.panelOpen = true
    p:Show()
    if p._fadeIn then p._fadeIn:Play() end

    -- Ensure Blizzard's secure slot buttons are attached for item application
    AttachBlizzardSlotButtons()

    Panel.UpdateModel()
    Panel.UpdateIdentity()
    Panel.UpdateGearSlots()
    Panel.UpdateItemLevel()
    Panel.UpdatePrimaryStats()
    Panel.UpdateEnhancements()
    Panel.SetActiveTab(tab or "character")
end

function Panel.Hide()
    local R = Panel._refs
    if not R.panel then return end
    if R.panel._fadeOut then
        R.panel._fadeOut:Play()
    else
        R.panel:Hide()
    end
    Panel._state.panelOpen = false
end

function Panel.Toggle(tab)
    if Panel._state.panelOpen then
        -- If already open and clicking same tab, close. Otherwise switch tab.
        if tab and tab ~= Panel._state.activeTab then
            Panel.SetActiveTab(tab)
        else
            Panel.Hide()
        end
    else
        Panel.Show(tab)
    end
end

function Panel.IsOpen()
    return Panel._state.panelOpen
end

-- ============================================================================
-- S14  THEME APPLICATION
-- ============================================================================
-- ============================================================================
-- S14c  EQUIPMENT MANAGER DROPDOWN
-- ============================================================================
local equipDropdown = nil

function Panel.ToggleEquipmentManager()
    local R = Panel._refs
    if not R.panel then return end

    if equipDropdown and equipDropdown:IsShown() then
        equipDropdown:Hide()
        return
    end

    -- Create shell on first use
    if not equipDropdown then
        local dd = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
        dd:SetWidth(280)
        dd:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        dd:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        dd:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.35)
        dd:SetFrameLevel(R.panel:GetFrameLevel() + 25)
        dd:Hide()

        -- Drop shadow
        for i = 1, 4 do
            local s = dd:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 1.2
            local a = 0.12 - (i * 0.025)
            s:SetColorTexture(0, 0, 0, a)
            s:SetPoint("TOPLEFT", dd, "TOPLEFT", -off, off)
            s:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", off, -off)
        end

        -- Top frost line
        local frost = dd:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", dd, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -1, -1)
        frost:SetColorTexture(1, 1, 1, 0.08)

        -- Top accent gradient
        local topGrad = dd:CreateTexture(nil, "BACKGROUND", nil, 1)
        topGrad:SetHeight(30)
        topGrad:SetPoint("TOPLEFT", dd, "TOPLEFT", 1, -1)
        topGrad:SetPoint("TOPRIGHT", dd, "TOPRIGHT", -1, -1)
        topGrad:SetTexture(W8)
        if topGrad.SetGradient and CreateColor then
            topGrad:SetGradient("VERTICAL",
                CreateColor(0, 0, 0, 0),
                CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.06))
        end

        equipDropdown = dd
    end

    -- Position below the equipment manager header button
    equipDropdown:ClearAllPoints()
    equipDropdown:SetPoint("TOPRIGHT", R.panel, "TOPRIGHT", -10, -(CFG.HEADER_H + 4))

    -- Clear old dynamic content
    local oldChildren = { equipDropdown:GetChildren() }
    for _, child in ipairs(oldChildren) do child:Hide() end
    local oldRegions = { equipDropdown:GetRegions() }
    for _, region in ipairs(oldRegions) do
        -- Keep the backdrop textures, frost, gradient — hide dynamic fontstrings/textures
        if region._dynamic then region:Hide() end
    end

    local PAD = 12
    local ROW_H = 34
    local yOfs = PAD

    -- Title
    local ddTitle = equipDropdown:CreateFontString(nil, "OVERLAY")
    ddTitle._dynamic = true
    TrySetFont(ddTitle, BODY_FONT, 10, "OUTLINE")
    ddTitle:SetPoint("TOPLEFT", equipDropdown, "TOPLEFT", PAD, -yOfs)
    ddTitle:SetText("EQUIPMENT SETS")
    ddTitle:SetTextColor(TC("mutedText"))
    ddTitle:Show()
    yOfs = yOfs + 18

    -- Gather sets
    local setIDs = {}
    if C_EquipmentSet and C_EquipmentSet.GetEquipmentSetIDs then
        setIDs = SafeCall(C_EquipmentSet.GetEquipmentSetIDs) or {}
    end

    if #setIDs == 0 then
        local emptyFS = equipDropdown:CreateFontString(nil, "OVERLAY")
        emptyFS._dynamic = true
        TrySetFont(emptyFS, BODY_FONT, 11, "")
        emptyFS:SetPoint("TOP", equipDropdown, "TOP", 0, -(yOfs + 16))
        emptyFS:SetText("No equipment sets saved")
        emptyFS:SetTextColor(TC("mutedText"))
        emptyFS:Show()
        yOfs = yOfs + 44
    else
        for _, setID in ipairs(setIDs) do
            local info = SafeCall(C_EquipmentSet.GetEquipmentSetInfo, setID)
            if info then
                local btn = CreateFrame("Button", nil, equipDropdown)
                btn:SetHeight(ROW_H)
                btn:SetPoint("TOPLEFT", equipDropdown, "TOPLEFT", 1, -yOfs)
                btn:SetPoint("TOPRIGHT", equipDropdown, "TOPRIGHT", -1, -yOfs)

                -- Hover highlight
                local hoverBg = btn:CreateTexture(nil, "BACKGROUND")
                hoverBg:SetAllPoints()
                hoverBg:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.08)
                hoverBg:Hide()

                -- Equipped accent bar (left edge)
                if info.isEquipped then
                    local accentBar = btn:CreateTexture(nil, "OVERLAY")
                    accentBar:SetWidth(2)
                    accentBar:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -4)
                    accentBar:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 4)
                    accentBar:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.9)
                end

                -- Icon (24x24)
                local icon = btn:CreateTexture(nil, "ARTWORK")
                icon:SetSize(24, 24)
                icon:SetPoint("LEFT", btn, "LEFT", PAD, 0)
                icon:SetTexture(info.iconFileID or 134400)
                icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

                -- 1px border on icon
                local ib = {}
                ib[1] = btn:CreateTexture(nil, "OVERLAY"); ib[1]:SetHeight(1)
                ib[1]:SetPoint("TOPLEFT", icon, -1, 1); ib[1]:SetPoint("TOPRIGHT", icon, 1, 1)
                ib[2] = btn:CreateTexture(nil, "OVERLAY"); ib[2]:SetHeight(1)
                ib[2]:SetPoint("BOTTOMLEFT", icon, -1, -1); ib[2]:SetPoint("BOTTOMRIGHT", icon, 1, -1)
                ib[3] = btn:CreateTexture(nil, "OVERLAY"); ib[3]:SetWidth(1)
                ib[3]:SetPoint("TOPLEFT", icon, -1, 1); ib[3]:SetPoint("BOTTOMLEFT", icon, -1, -1)
                ib[4] = btn:CreateTexture(nil, "OVERLAY"); ib[4]:SetWidth(1)
                ib[4]:SetPoint("TOPRIGHT", icon, 1, 1); ib[4]:SetPoint("BOTTOMRIGHT", icon, 1, -1)
                for _, b in ipairs(ib) do
                    if info.isEquipped then
                        b:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.6)
                    else
                        b:SetColorTexture(0.4, 0.4, 0.4, 0.3)
                    end
                end

                -- Set name
                local nameFS = btn:CreateFontString(nil, "OVERLAY")
                TrySetFont(nameFS, BODY_FONT, 11, "")
                nameFS:SetPoint("LEFT", icon, "RIGHT", 8, 0)
                nameFS:SetPoint("RIGHT", btn, "RIGHT", -PAD, 0)
                nameFS:SetJustifyH("LEFT")
                nameFS:SetWordWrap(false)
                nameFS:SetText(info.name or "Unknown")
                if info.isEquipped then
                    nameFS:SetTextColor(TC("accent"))
                else
                    nameFS:SetTextColor(TC("bodyText"))
                end

                -- Delete X button (far right)
                local delBtn = CreateFrame("Button", nil, btn)
                delBtn:SetSize(16, 16)
                delBtn:SetPoint("RIGHT", btn, "RIGHT", -PAD, 0)
                local delFS = delBtn:CreateFontString(nil, "OVERLAY")
                TrySetFont(delFS, BODY_FONT, 10, "OUTLINE")
                delFS:SetPoint("CENTER")
                delFS:SetText("X")
                delFS:SetTextColor(0.7, 0.25, 0.25, 0.6)
                local capturedDelID = setID
                delBtn:SetScript("OnEnter", function()
                    delFS:SetTextColor(1, 0.3, 0.3, 1)
                    GameTooltip:SetOwner(delBtn, "ANCHOR_TOP")
                    GameTooltip:SetText("Delete Set", 1, 0.3, 0.3)
                    GameTooltip:Show()
                end)
                delBtn:SetScript("OnLeave", function()
                    delFS:SetTextColor(0.7, 0.25, 0.25, 0.6)
                    GameTooltip:Hide()
                end)
                delBtn:SetScript("OnClick", function()
                    if C_EquipmentSet and C_EquipmentSet.DeleteEquipmentSet then
                        pcall(C_EquipmentSet.DeleteEquipmentSet, capturedDelID)
                        -- Rebuild dropdown in place without closing
                        C_Timer.After(0.2, function()
                            if equipDropdown and equipDropdown:IsShown() then
                                equipDropdown:Hide()
                                Panel.ToggleEquipmentManager()
                            end
                        end)
                    end
                end)

                -- Checkmark for equipped
                local rightAnchor = delBtn
                if info.isEquipped then
                    local check = btn:CreateFontString(nil, "OVERLAY")
                    TrySetFont(check, BODY_FONT, 11, "")
                    check:SetPoint("RIGHT", delBtn, "LEFT", -4, 0)
                    check:SetText("|cff55ff55\226\156\147|r")
                    rightAnchor = check
                end
                nameFS:SetPoint("RIGHT", rightAnchor, "LEFT", -4, 0)

                btn:SetScript("OnEnter", function()
                    hoverBg:Show()
                    GameTooltip:SetOwner(btn, "ANCHOR_LEFT")
                    GameTooltip:SetText(info.name or "", 1, 1, 1)
                    local itemLine = (info.numEquipped or 0) .. "/" .. (info.numItems or 0) .. " items equipped"
                    GameTooltip:AddLine(itemLine, TC("mutedText"))
                    if (info.numLost or 0) > 0 then
                        GameTooltip:AddLine(info.numLost .. " items missing", 1, 0.3, 0.3)
                    end
                    GameTooltip:AddLine(" ")
                    GameTooltip:AddLine("|cffaaaaaaLeft Click:|r Equip this set", 1, 1, 1)
                    GameTooltip:Show()
                end)
                btn:SetScript("OnLeave", function() hoverBg:Hide(); GameTooltip:Hide() end)

                local capturedSetID = setID
                btn:SetScript("OnClick", function()
                    if C_EquipmentSet and C_EquipmentSet.UseEquipmentSet then
                        pcall(C_EquipmentSet.UseEquipmentSet, capturedSetID)
                        equipDropdown:Hide()
                        C_Timer.After(0.5, function()
                            Panel.UpdateGearSlots()
                            Panel.UpdateItemLevel()
                        end)
                    end
                end)

                btn:Show()
                yOfs = yOfs + ROW_H
            end
        end
    end

    -- Separator
    local sep = equipDropdown:CreateTexture(nil, "OVERLAY")
    sep._dynamic = true
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", equipDropdown, "TOPLEFT", PAD, -(yOfs + 2))
    sep:SetPoint("TOPRIGHT", equipDropdown, "TOPRIGHT", -PAD, -(yOfs + 2))
    sep:SetTexture(W8)
    if sep.SetGradient and CreateColor then
        sep:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.3),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0))
    end
    sep:Show()
    yOfs = yOfs + 6

    -- "+ Save New Set" row with ">" arrow
    local newBtn = CreateFrame("Button", nil, equipDropdown)
    newBtn:SetHeight(ROW_H)
    newBtn:SetPoint("TOPLEFT", equipDropdown, "TOPLEFT", 1, -yOfs)
    newBtn:SetPoint("TOPRIGHT", equipDropdown, "TOPRIGHT", -1, -yOfs)
    local newHover = newBtn:CreateTexture(nil, "BACKGROUND")
    newHover:SetAllPoints()
    newHover:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.06)
    newHover:Hide()
    local newIcon = newBtn:CreateTexture(nil, "ARTWORK")
    newIcon:SetSize(24, 24)
    newIcon:SetPoint("LEFT", newBtn, "LEFT", PAD, 0)
    newIcon:SetTexture("Interface\\Icons\\Spell_ChargePositive")
    newIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    newIcon:SetVertexColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.7)
    local newFS = newBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(newFS, BODY_FONT, 11, "")
    newFS:SetPoint("LEFT", newIcon, "RIGHT", 8, 0)
    newFS:SetText("Save New Set")
    newFS:SetTextColor(TC("accent"))
    local arrowTex = newBtn:CreateTexture(nil, "OVERLAY")
    arrowTex:SetSize(12, 12)
    arrowTex:SetPoint("RIGHT", newBtn, "RIGHT", -PAD, 0)
    arrowTex:SetAtlas("common-dropdown-icon-back")
    arrowTex:SetRotation(-math.pi)
    arrowTex:SetVertexColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.8)
    newBtn:SetScript("OnEnter", function() newHover:Show() end)
    newBtn:SetScript("OnLeave", function() newHover:Hide() end)
    newBtn:SetScript("OnClick", function()
        Panel.ShowNewSetFlyout(equipDropdown)
    end)
    newBtn:Show()
    yOfs = yOfs + ROW_H + PAD

    equipDropdown:SetHeight(yOfs)
    equipDropdown:Show()
end

-- ============================================================================
-- S14d  NEW EQUIPMENT SET FLYOUT
-- ============================================================================
local newSetFlyout = nil
local selectedSetIcon = 134400 -- default

-- Common equipment set icons
local SET_ICON_OPTIONS = {
    -- Helmets
    "Interface\\Icons\\INV_Helmet_04",
    "Interface\\Icons\\INV_Helmet_06",
    "Interface\\Icons\\INV_Helmet_15",
    "Interface\\Icons\\INV_Crown_01",
    -- Shoulders
    "Interface\\Icons\\INV_Shoulder_02",
    "Interface\\Icons\\INV_Shoulder_22",
    -- Chest
    "Interface\\Icons\\INV_Chest_Chain_04",
    "Interface\\Icons\\INV_Chest_Plate01",
    "Interface\\Icons\\INV_Chest_Cloth_17",
    "Interface\\Icons\\INV_Chest_Leather_09",
    -- Gloves / Boots / Belt / Legs
    "Interface\\Icons\\INV_Gauntlets_04",
    "Interface\\Icons\\INV_Boots_Chain_01",
    "Interface\\Icons\\INV_Belt_03",
    "Interface\\Icons\\INV_Pants_06",
    "Interface\\Icons\\INV_Bracer_07",
    -- Cloaks
    "Interface\\Icons\\INV_Misc_Cape_02",
    -- Shields
    "Interface\\Icons\\INV_Shield_04",
    "Interface\\Icons\\INV_Shield_06",
    -- Swords
    "Interface\\Icons\\INV_Sword_04",
    "Interface\\Icons\\INV_Sword_39",
    -- Axes / Maces
    "Interface\\Icons\\INV_Axe_01",
    "Interface\\Icons\\INV_Mace_01",
    -- Staves / Polearms
    "Interface\\Icons\\INV_Staff_08",
    "Interface\\Icons\\INV_Spear_04",
    -- Bows / Guns / Wands
    "Interface\\Icons\\INV_Weapon_Bow_07",
    "Interface\\Icons\\INV_Weapon_Rifle_01",
    "Interface\\Icons\\INV_Wand_01",
    -- Daggers / Fists
    "Interface\\Icons\\INV_Weapon_ShortBlade_02",
    "Interface\\Icons\\INV_Gauntlets_04",
    -- Rings / Trinkets / Neck
    "Interface\\Icons\\INV_Jewelry_Ring_03",
    "Interface\\Icons\\INV_Jewelry_Trinket_04",
    "Interface\\Icons\\INV_Jewelry_Necklace_01",
}

function Panel.ShowNewSetFlyout(anchorFrame)
    if newSetFlyout and newSetFlyout:IsShown() then
        newSetFlyout:Hide()
        return
    end

    selectedSetIcon = SET_ICON_OPTIONS[1]
    local flyPAD = 14
    local ICON_SIZE = 28
    local ICON_GAP = 3
    local ICONS_PER_ROW = 8
    local gridRows = math.ceil(#SET_ICON_OPTIONS / ICONS_PER_ROW)
    local gridW = ICONS_PER_ROW * (ICON_SIZE + ICON_GAP) - ICON_GAP
    local gridH = gridRows * (ICON_SIZE + ICON_GAP) - ICON_GAP
    local flyW = gridW + (flyPAD * 2)
    local flyH = flyPAD + 18 + 10 + 28 + 14 + 14 + 6 + gridH + 16 + 30 + flyPAD

    if not newSetFlyout then
        local fly = CreateFrame("Frame", nil, anchorFrame:GetParent(), "BackdropTemplate")
        fly:SetSize(flyW, flyH)
        fly:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        fly:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        fly:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.25)
        fly:SetFrameLevel(anchorFrame:GetFrameLevel() + 2)
        fly:Hide()

        -- Drop shadow
        for i = 1, 4 do
            local s = fly:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 1.2
            s:SetColorTexture(0, 0, 0, 0.12 - (i * 0.025))
            s:SetPoint("TOPLEFT", -off, off)
            s:SetPoint("BOTTOMRIGHT", off, -off)
        end

        -- Frost line
        local frost = fly:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", fly, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", fly, "TOPRIGHT", -1, -1)
        frost:SetColorTexture(1, 1, 1, 0.06)

        -- Top accent wash
        local topWash = fly:CreateTexture(nil, "BACKGROUND", nil, 1)
        topWash:SetHeight(40)
        topWash:SetPoint("TOPLEFT", fly, "TOPLEFT", 1, -1)
        topWash:SetPoint("TOPRIGHT", fly, "TOPRIGHT", -1, -1)
        topWash:SetTexture(W8)
        if topWash.SetGradient and CreateColor then
            topWash:SetGradient("VERTICAL",
                CreateColor(0, 0, 0, 0),
                CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.05))
        end

        -- ── Title ──
        local titleFS = fly:CreateFontString(nil, "OVERLAY")
        TrySetFont(titleFS, BODY_FONT, 10, "OUTLINE")
        titleFS:SetPoint("TOPLEFT", fly, "TOPLEFT", flyPAD, -flyPAD)
        titleFS:SetText("NEW EQUIPMENT SET")
        titleFS:SetTextColor(TC("mutedText"))

        -- ── Name input with integrated label ──
        local nameInput = CreateFrame("EditBox", nil, fly, "BackdropTemplate")
        nameInput:SetHeight(28)
        nameInput:SetPoint("TOPLEFT", titleFS, "BOTTOMLEFT", 0, -10)
        nameInput:SetPoint("RIGHT", fly, "RIGHT", -flyPAD, 0)
        nameInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 8, right = 8, top = 4, bottom = 4 } })
        nameInput:SetBackdropColor(0.06, 0.06, 0.08, 0.9)
        nameInput:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.2)
        TrySetFont(nameInput, BODY_FONT, 11, "")
        nameInput:SetTextColor(TC("titleText"))
        nameInput:SetAutoFocus(false)
        nameInput:SetText("New Set")
        nameInput:SetCursorPosition(0)
        nameInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        nameInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        nameInput:SetScript("OnEditFocusGained", function(self)
            self:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.5)
        end)
        nameInput:SetScript("OnEditFocusLost", function(self)
            self:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.2)
        end)
        fly._nameInput = nameInput

        -- ── Icon section ──
        local iconLbl = fly:CreateFontString(nil, "OVERLAY")
        TrySetFont(iconLbl, BODY_FONT, 10, "")
        iconLbl:SetPoint("TOPLEFT", nameInput, "BOTTOMLEFT", 0, -14)
        iconLbl:SetText("Choose Icon")
        iconLbl:SetTextColor(TC("mutedText"))

        -- Icon grid
        local iconGrid = CreateFrame("Frame", nil, fly)
        iconGrid:SetPoint("TOPLEFT", iconLbl, "BOTTOMLEFT", 0, -6)
        iconGrid:SetSize(gridW, gridH)

        local iconButtons = {}
        for i, iconPath in ipairs(SET_ICON_OPTIONS) do
            local row = math.floor((i - 1) / ICONS_PER_ROW)
            local col = (i - 1) % ICONS_PER_ROW
            local ib = CreateFrame("Button", nil, iconGrid)
            ib:SetSize(ICON_SIZE, ICON_SIZE)
            ib:SetPoint("TOPLEFT", iconGrid, "TOPLEFT",
                col * (ICON_SIZE + ICON_GAP), -(row * (ICON_SIZE + ICON_GAP)))

            local tex = ib:CreateTexture(nil, "ARTWORK")
            tex:SetPoint("TOPLEFT", 2, -2)
            tex:SetPoint("BOTTOMRIGHT", -2, 2)
            tex:SetTexture(iconPath)
            tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
            ib._tex = tex

            -- Dark background behind icon
            local ibBg = ib:CreateTexture(nil, "BACKGROUND")
            ibBg:SetAllPoints()
            ibBg:SetColorTexture(0.08, 0.08, 0.10, 0.8)

            -- Selection border (2px, hidden by default)
            local sel = ib:CreateTexture(nil, "OVERLAY")
            sel:SetPoint("TOPLEFT", -1, 1)
            sel:SetPoint("BOTTOMRIGHT", 1, -1)
            sel:SetColorTexture(0, 0, 0, 0) -- invisible
            ib._sel = sel

            -- Accent border pieces (shown on selection)
            local selParts = {}
            selParts[1] = ib:CreateTexture(nil, "OVERLAY", nil, 2); selParts[1]:SetHeight(2)
            selParts[1]:SetPoint("TOPLEFT", -1, 1); selParts[1]:SetPoint("TOPRIGHT", 1, 1)
            selParts[2] = ib:CreateTexture(nil, "OVERLAY", nil, 2); selParts[2]:SetHeight(2)
            selParts[2]:SetPoint("BOTTOMLEFT", -1, -1); selParts[2]:SetPoint("BOTTOMRIGHT", 1, -1)
            selParts[3] = ib:CreateTexture(nil, "OVERLAY", nil, 2); selParts[3]:SetWidth(2)
            selParts[3]:SetPoint("TOPLEFT", -1, 1); selParts[3]:SetPoint("BOTTOMLEFT", -1, -1)
            selParts[4] = ib:CreateTexture(nil, "OVERLAY", nil, 2); selParts[4]:SetWidth(2)
            selParts[4]:SetPoint("TOPRIGHT", 1, 1); selParts[4]:SetPoint("BOTTOMRIGHT", 1, -1)
            for _, p in ipairs(selParts) do p:SetColorTexture(0, 0, 0, 0) end
            ib._selParts = selParts

            local capturedPath = iconPath
            ib:SetScript("OnEnter", function()
                if selectedSetIcon ~= capturedPath then
                    for _, p in ipairs(selParts) do
                        p:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.4)
                    end
                end
            end)
            ib:SetScript("OnLeave", function()
                if selectedSetIcon ~= capturedPath then
                    for _, p in ipairs(selParts) do p:SetColorTexture(0, 0, 0, 0) end
                end
            end)
            ib:SetScript("OnClick", function()
                selectedSetIcon = capturedPath
                for _, ob in ipairs(iconButtons) do
                    for _, p in ipairs(ob._selParts) do p:SetColorTexture(0, 0, 0, 0) end
                    ob._tex:SetVertexColor(1, 1, 1, 0.7)
                end
                for _, p in ipairs(selParts) do
                    p:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.9)
                end
                tex:SetVertexColor(1, 1, 1, 1)
            end)

            -- Dim unselected icons slightly
            tex:SetVertexColor(1, 1, 1, 0.7)

            iconButtons[#iconButtons + 1] = ib
        end
        fly._iconButtons = iconButtons

        -- ── Bottom button bar ──
        local btnBar = CreateFrame("Frame", nil, fly)
        btnBar:SetHeight(30)
        btnBar:SetPoint("BOTTOMLEFT", fly, "BOTTOMLEFT", flyPAD, flyPAD)
        btnBar:SetPoint("BOTTOMRIGHT", fly, "BOTTOMRIGHT", -flyPAD, flyPAD)

        -- Save button (right, accent styled)
        local saveBtn = CreateFrame("Button", nil, btnBar)
        saveBtn:SetSize(90, 28)
        saveBtn:SetPoint("RIGHT", btnBar, "RIGHT", 0, 0)
        local saveBg = saveBtn:CreateTexture(nil, "BACKGROUND")
        saveBg:SetAllPoints()
        saveBg:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.2)
        local saveFS = saveBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(saveFS, BODY_FONT, 11, "")
        saveFS:SetPoint("CENTER")
        saveFS:SetText("Save Set")
        saveFS:SetTextColor(TC("accent"))
        -- 1px accent border
        local function MakeBtnBorder(parent, r, g, b, a)
            local t = parent:CreateTexture(nil, "OVERLAY"); t:SetHeight(1)
            t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetColorTexture(r, g, b, a)
            local b2 = parent:CreateTexture(nil, "OVERLAY"); b2:SetHeight(1)
            b2:SetPoint("BOTTOMLEFT"); b2:SetPoint("BOTTOMRIGHT"); b2:SetColorTexture(r, g, b, a)
            local l = parent:CreateTexture(nil, "OVERLAY"); l:SetWidth(1)
            l:SetPoint("TOPLEFT"); l:SetPoint("BOTTOMLEFT"); l:SetColorTexture(r, g, b, a)
            local rv = parent:CreateTexture(nil, "OVERLAY"); rv:SetWidth(1)
            rv:SetPoint("TOPRIGHT"); rv:SetPoint("BOTTOMRIGHT"); rv:SetColorTexture(r, g, b, a)
        end
        MakeBtnBorder(saveBtn, activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.3)

        saveBtn:SetScript("OnEnter", function()
            saveBg:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.35)
        end)
        saveBtn:SetScript("OnLeave", function()
            saveBg:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.2)
        end)
        saveBtn:SetScript("OnClick", function()
            local setName = fly._nameInput:GetText() or "New Set"
            if setName == "" then setName = "New Set" end
            if C_EquipmentSet and C_EquipmentSet.CreateEquipmentSet then
                pcall(C_EquipmentSet.CreateEquipmentSet, setName, selectedSetIcon)
                fly:Hide()
                if equipDropdown then equipDropdown:Hide() end
                C_Timer.After(0.3, function() Panel.ToggleEquipmentManager() end)
            end
        end)

        -- Cancel button (left, text only)
        local cancelBtn = CreateFrame("Button", nil, btnBar)
        cancelBtn:SetSize(60, 28)
        cancelBtn:SetPoint("LEFT", btnBar, "LEFT", 0, 0)
        local cancelFS = cancelBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(cancelFS, BODY_FONT, 11, "")
        cancelFS:SetPoint("CENTER")
        cancelFS:SetText("Cancel")
        cancelFS:SetTextColor(TC("mutedText"))
        cancelBtn:SetScript("OnEnter", function() cancelFS:SetTextColor(TC("bodyText")) end)
        cancelBtn:SetScript("OnLeave", function() cancelFS:SetTextColor(TC("mutedText")) end)
        cancelBtn:SetScript("OnClick", function() fly:Hide() end)

        newSetFlyout = fly
    end

    -- Reset state
    newSetFlyout:SetSize(flyW, flyH)
    newSetFlyout._nameInput:SetText("New Set")
    newSetFlyout._nameInput:SetCursorPosition(0)
    newSetFlyout._nameInput:HighlightText()
    selectedSetIcon = SET_ICON_OPTIONS[1]
    -- Reset icon visuals — dim all, highlight first
    for _, ob in ipairs(newSetFlyout._iconButtons) do
        for _, p in ipairs(ob._selParts) do p:SetColorTexture(0, 0, 0, 0) end
        ob._tex:SetVertexColor(1, 1, 1, 0.7)
    end
    if newSetFlyout._iconButtons[1] then
        for _, p in ipairs(newSetFlyout._iconButtons[1]._selParts) do
            p:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.9)
        end
        newSetFlyout._iconButtons[1]._tex:SetVertexColor(1, 1, 1, 1)
    end

    -- Position to the right of the dropdown
    newSetFlyout:ClearAllPoints()
    newSetFlyout:SetPoint("TOPLEFT", anchorFrame, "TOPRIGHT", 4, 0)
    newSetFlyout:Show()
end

function Panel.ApplyTheme()
    GetActiveTheme()
    local R = Panel._refs
    if not R.panel then return end

    R.panel:SetBackdropColor(TC("frameBg"))
    R.panel:SetBackdropBorderColor(TC("accent"))
    R.hdrBg:SetColorTexture(TC("headerBg"))
    -- modelBg is an atlas texture — don't overwrite it with SetColorTexture
    R.titleFS:SetTextColor(TC("titleText"))
    R.nameFS:SetTextColor(TC("titleText"))
    R.specFS:SetTextColor(TC("bodyText"))
    R.ilvlLabel:SetTextColor(TC("mutedText"))
    R.ilvlValue:SetTextColor(TC("titleText"))
    if R.enhLabel then R.enhLabel:SetTextColor(TC("mutedText")) end
    if R.attrLabel then R.attrLabel:SetTextColor(TC("mutedText")) end
    R.tabBg:SetColorTexture(TC("headerBg"))

    if R.gearLabel then R.gearLabel:SetTextColor(TC("mutedText")) end
    if R.leftGlass then R.leftGlass:ApplyTheme() end
    if R.rightGlass then R.rightGlass:ApplyTheme() end

    -- Re-apply header accent gradient
    if R.hdrAccent and R.hdrAccent.SetGradient and CreateColor then
        R.hdrAccent:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.6),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.0))
    end

    -- Refresh tab visuals
    Panel.SetActiveTab(Panel._state.activeTab)

    -- Refresh stats display
    Panel.UpdatePrimaryStats()
    Panel.UpdateEnhancements()
end

function Panel.ShowSettingsPopup()
    local R = Panel._refs
    if R.settingsPopup then R.settingsPopup:Show() end
end

-- ============================================================================
-- S14b  TITLE PICKER
-- ============================================================================
local titlePickerFrame = nil

function Panel.ToggleTitlePicker()
    if titlePickerFrame and titlePickerFrame:IsShown() then
        titlePickerFrame:Hide()
        return
    end

    local R = Panel._refs
    if not R.panel or not R.identityBar then return end

    -- Create on first use
    if not titlePickerFrame then
        titlePickerFrame = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
        titlePickerFrame:SetSize(480, 320)
        titlePickerFrame:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        titlePickerFrame:SetBackdropColor(0.05, 0.05, 0.07, 0.95)
        titlePickerFrame:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.5)
        titlePickerFrame:SetFrameLevel(R.panel:GetFrameLevel() + 25)

        local tpTitle = titlePickerFrame:CreateFontString(nil, "OVERLAY")
        TrySetFont(tpTitle, BODY_FONT, 10, "OUTLINE")
        tpTitle:SetPoint("TOP", titlePickerFrame, "TOP", 0, -8)
        tpTitle:SetText("SELECT TITLE")
        tpTitle:SetTextColor(TC("mutedText"))

        local scrollFrame = CreateFrame("ScrollFrame", nil, titlePickerFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", titlePickerFrame, "TOPLEFT", 6, -24)
        scrollFrame:SetPoint("BOTTOMRIGHT", titlePickerFrame, "BOTTOMRIGHT", -24, 6)
        local scrollContent = CreateFrame("Frame", nil, scrollFrame)
        scrollContent:SetWidth(1)
        scrollFrame:SetScrollChild(scrollContent)
        scrollFrame:SetScript("OnSizeChanged", function(self, w) if w > 0 then scrollContent:SetWidth(w) end end)
        if scrollFrame.ScrollBar then
            local sb = scrollFrame.ScrollBar
            if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.30); sb.ThumbTexture:SetWidth(4) end
            if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
            if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
        end

        titlePickerFrame._scrollContent = scrollContent
        titlePickerFrame._scrollFrame = scrollFrame
    end

    -- Position above the identity bar
    titlePickerFrame:ClearAllPoints()
    titlePickerFrame:SetPoint("BOTTOM", R.identityBar, "TOP", 0, 4)

    -- Populate titles
    local content = titlePickerFrame._scrollContent
    -- Clear old rows
    local oldChildren = { content:GetChildren() }
    for _, child in ipairs(oldChildren) do child:Hide() end

    local ROW_H = 22
    local COL_COUNT = 2
    local currentTitle = SafeCall(GetCurrentTitle) or 0
    local playerName = SafeCall(UnitName, "player") or ""

    -- Collect all known titles first
    local titleList = {}
    titleList[#titleList + 1] = { id = 0, display = playerName .. "  |cff888888(No Title)|r" }
    local numTitles = SafeCall(GetNumTitles) or 0
    for titleID = 1, numTitles do
        local known = SafeCall(IsTitleKnown, titleID)
        if known then
            local rawName = SafeCall(GetTitleName, titleID)
            if rawName and rawName ~= "" then
                local displayName = rawName:gsub("%%s", playerName):gsub("^%s+", ""):gsub("%s+$", "")
                titleList[#titleList + 1] = { id = titleID, display = displayName }
            end
        end
    end

    -- Lay out in two columns
    local contentW = content:GetWidth()
    if contentW < 10 then contentW = 440 end
    local colW = math.floor(contentW / COL_COUNT)
    local col = 0
    local yOfs = 0

    for _, entry in ipairs(titleList) do
        local btn = CreateFrame("Button", nil, content)
        btn:SetSize(colW, ROW_H)
        btn:SetPoint("TOPLEFT", content, "TOPLEFT", col * colW, -yOfs)

        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 11, "")
        fs:SetPoint("LEFT", btn, "LEFT", 8, 0)
        fs:SetPoint("RIGHT", btn, "RIGHT", -4, 0)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        fs:SetText(entry.display)
        if entry.id == currentTitle then
            fs:SetTextColor(TC("accent"))
        else
            fs:SetTextColor(TC("bodyText"))
        end

        local hoverBg = btn:CreateTexture(nil, "BACKGROUND")
        hoverBg:SetAllPoints(); hoverBg:SetColorTexture(1, 1, 1, 0.05); hoverBg:Hide()
        btn:SetScript("OnEnter", function() hoverBg:Show() end)
        btn:SetScript("OnLeave", function() hoverBg:Hide() end)
        local capturedID = entry.id
        btn:SetScript("OnClick", function()
            pcall(SetCurrentTitle, capturedID)
            titlePickerFrame:Hide()
            local R = Panel._refs
            if R.nameFS then
                local pName = SafeCall(UnitName, "player") or "Unknown"
                if capturedID == 0 then
                    R.nameFS:SetText(pName)
                else
                    local raw = SafeCall(GetTitleName, capturedID) or ""
                    raw = raw:gsub("^%s+", ""):gsub("%s+$", "")
                    -- GetTitleName returns just the title text (e.g. "the Exalted")
                    -- without %s — we need to figure out where the name goes
                    if raw:sub(1,1) == raw:sub(1,1):lower() then
                        -- Lowercase start = suffix title: "Mesden the Exalted"
                        R.nameFS:SetText(pName .. " " .. raw)
                    else
                        -- Uppercase start = prefix title: "Ambassador Mesden"
                        R.nameFS:SetText(raw .. " " .. pName)
                    end
                end
            end
        end)
        btn:Show()

        col = col + 1
        if col >= COL_COUNT then
            col = 0
            yOfs = yOfs + ROW_H
        end
    end
    -- Account for last incomplete row
    if col > 0 then yOfs = yOfs + ROW_H end

    content:SetHeight(math.max(yOfs + 4, 1))
    titlePickerFrame:Show()
end

-- ============================================================================
-- S15  EVENTS
-- ============================================================================
local evf = CreateFrame("Frame")
local function SafeReg(event)
    pcall(evf.RegisterEvent, evf, event)
end

SafeReg("ADDON_LOADED")
SafeReg("PLAYER_LOGIN")
SafeReg("UNIT_INVENTORY_CHANGED")
SafeReg("PLAYER_EQUIPMENT_CHANGED")
SafeReg("PLAYER_AVG_ITEM_LEVEL_UPDATE")
SafeReg("UNIT_STATS")
SafeReg("COMBAT_RATING_UPDATE")
SafeReg("MASTERY_UPDATE")
SafeReg("PLAYER_SPECIALIZATION_CHANGED")
SafeReg("ACTIVE_TALENT_GROUP_CHANGED")
SafeReg("PLAYER_LEVEL_UP")
SafeReg("PLAYER_TITLE_CHANGED")
SafeReg("UNIT_MODEL_CHANGED")
SafeReg("UPDATE_FACTION")
SafeReg("CURRENCY_DISPLAY_UPDATE")
SafeReg("PLAYER_ENTERING_WORLD")

local pendingUpdate = false
local function DeferUpdate()
    if pendingUpdate then return end
    pendingUpdate = true
    C_Timer.After(0.1, function()
        pendingUpdate = false
        if Panel.IsOpen() and Panel._state.activeTab == "character" then
            Panel.UpdateGearSlots()
            Panel.UpdateItemLevel()
            Panel.UpdatePrimaryStats()
            Panel.UpdateEnhancements()
        end
    end)
end

evf:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Initialize settings default
        local s = _G.MidnightUISettings
        if s and s.General and s.General.characterPanelTheme == nil then
            s.General.characterPanelTheme = "parchment"
        end
    elseif event == "UNIT_INVENTORY_CHANGED" or event == "PLAYER_EQUIPMENT_CHANGED"
        or event == "PLAYER_AVG_ITEM_LEVEL_UPDATE" then
        DeferUpdate()
    elseif event == "UNIT_STATS" or event == "COMBAT_RATING_UPDATE" or event == "MASTERY_UPDATE" then
        DeferUpdate()
    elseif event == "PLAYER_SPECIALIZATION_CHANGED" or event == "ACTIVE_TALENT_GROUP_CHANGED" then
        if Panel.IsOpen() then
            Panel.UpdateModel()
            Panel.UpdateIdentity()
            DeferUpdate()
        end
    elseif event == "PLAYER_LEVEL_UP" or event == "PLAYER_TITLE_CHANGED" then
        if Panel.IsOpen() then Panel.UpdateIdentity() end
    elseif event == "UNIT_MODEL_CHANGED" then
        if Panel.IsOpen() then Panel.UpdateModel() end
    elseif event == "UPDATE_FACTION" then
        if Panel.IsOpen() and Panel._state.activeTab == "reputation" then
            Panel.UpdateReputation()
        end
    elseif event == "CURRENCY_DISPLAY_UPDATE" then
        if Panel.IsOpen() and Panel._state.activeTab == "currency" then
            Panel.UpdateCurrency()
        end
    end
end)

-- ============================================================================
-- S16  HOOK: ToggleCharacter Interception
-- ============================================================================
local hookGuard = false
local hookInstalled = false

local function InstallToggleHook()
    if hookInstalled then return end
    if type(ToggleCharacter) ~= "function" then return end
    hookInstalled = true

    hooksecurefunc("ToggleCharacter", function(tab)
        if hookGuard then return end
        hookGuard = true

        -- Suppress Blizzard's CharacterFrame and deregister it from the UI
        -- panel system so ESC isn't consumed by a phantom panel entry.
        if CharacterFrame and CharacterFrame:IsShown() then
            HideUIPanel(CharacterFrame)
        end

        -- Route to our panel
        local targetTab = "character"
        if tab == "TokenFrame" then
            targetTab = "currency"
        elseif tab == "ReputationFrame" then
            targetTab = "reputation"
        end
        -- If panel is already open and an item is being targeted (oil/enchant/gem),
        -- don't close the panel — just ensure the right tab is active.
        local isTargeting = SpellIsTargeting and SpellIsTargeting()
        if Panel._state.panelOpen and isTargeting then
            Panel.SetActiveTab(targetTab)
        else
            Panel.Toggle(targetTab)
        end

        C_Timer.After(0, function() hookGuard = false end)
    end)

    -- Also suppress CharacterFrame if it opens for any reason (unless cursor has an item)
    if CharacterFrame and not CharacterFrame._muiSuppressHooked then
        CharacterFrame._muiSuppressHooked = true
        local _charHideDepth = 0
        CharacterFrame:HookScript("OnShow", function(self)
            if not hookGuard then
                if _charHideDepth > 0 then return end
                _charHideDepth = _charHideDepth + 1
                HideUIPanel(self)
                _charHideDepth = _charHideDepth - 1
            end
        end)
    end
end

-- ============================================================================
-- GLOBAL EXPORTS
-- ============================================================================
_G.MidnightUI_CharacterPanel_Toggle = function(tab) Panel.Toggle(tab) end
_G.MidnightUI_CharacterPanel_Show   = function(tab) Panel.Show(tab) end
_G.MidnightUI_CharacterPanel_Hide   = function() Panel.Hide() end

-- Try immediately in case Blizzard_CharacterUI is already loaded
InstallToggleHook()

-- Listen for Blizzard_CharacterUI loading (demand-loaded addon)
local hookEvf = CreateFrame("Frame")
hookEvf:RegisterEvent("ADDON_LOADED")
hookEvf:SetScript("OnEvent", function(_, event, addon)
    if addon == "Blizzard_CharacterUI" or addon == "Blizzard_CharacterCustomize" then
        InstallToggleHook()
        -- On the very first load, Blizzard's frame opens before our hook.
        -- Immediately close it and open ours instead.
        if CharacterFrame and CharacterFrame:IsShown() then
            CharacterFrame:Hide()
            Panel.Show("character")
        end
        -- Attach secure slot buttons now that Blizzard's UI is loaded
        C_Timer.After(0.5, AttachBlizzardSlotButtons)
    end
end)

