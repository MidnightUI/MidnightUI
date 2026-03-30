-- =============================================================================
-- FILE PURPOSE:     Tracks active consumable buffs (flask, combat potion, health potion,
--                   weapon buff, augment rune, well-fed food) and displays a compact
--                   vertical bar stack with countdown timers, color-coded urgency, and
--                   icon badges. Shows/hides per-slot bars based on whether each
--                   consumable buff is currently active.
-- LOAD ORDER:       Loads after Settings.lua. ConsumableBarManager handles ADDON_LOADED
--                   and PLAYER_ENTERING_WORLD to begin aura scanning.
-- DEFINES:          ConsumableBarManager (event frame), container (the drag parent),
--                   bars[] (one StatusBar per SLOT_DEFS entry), slotStates[], cooldownStates[].
--                   Global refresh: MidnightUI_ApplyConsumableBarSettings().
-- READS:            MidnightUISettings.ConsumableBars.{enabled, width, height, spacing, scale,
--                   hideInactive, showInInstancesOnly, position, spellIds}.
-- WRITES:           MidnightUISettings.ConsumableBars.position (on drag stop).
--                   slotStates[key] — active aura state per consumable slot.
--                   cooldownStates[key] — cooldown tracking for health potion specifically.
-- DEPENDS ON:       MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes consumable bar settings controls).
-- KEY FLOWS:
--   ADDON_LOADED → EnsureConsumableSettings() → CreateConsumableContainer() → layout
--   UNIT_AURA player → scan SLOT_DEFS patterns against buff names → update slotStates
--   SPELL_CAST_SUCCESS (health potion) → SetHealthPotionCooldown → start countdown
--   ConsumableManager_OnUpdate (0.1s tick) → update bar fill, timer text, color urgency
-- GOTCHAS:
--   SLOT_DEFS defines all tracked consumable types; add new entries here to track new buffs.
--   Pattern matching is case-insensitive substring: "flask" matches any buff containing it.
--   Health potion cooldown is tracked separately via SPELL_CAST_SUCCESS because the buff
--   disappears immediately after use — the bar shows the 5-min cooldown, not the buff.
--   IsInDungeonOrRaid() gates "showInInstancesOnly" to hide bars in open world.
--   DebugPrint and DebugPrintVerbose are no-ops in release builds (return immediately).
--   cooldownStates uses GetTime() epoch for expiration math; slotStates uses aura duration/expiration.
-- NAVIGATION:
--   SLOT_DEFS[]               — consumable slot definitions: key, label, icon, patterns (line ~44)
--   EnsureConsumableSettings()— settings accessor with default fill
--   CreateConsumableContainer()— builds the drag parent frame (line ~254)
--   CreateConsumableBar()     — builds one StatusBar + icon + border + badge (line ~268)
--   ApplyBarColor()           — sets green/yellow/red urgency color by remaining fraction
--   ConsumableManager_OnUpdate— per-tick countdown timer + bar fill refresh
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local ConsumableBarManager = CreateFrame("Frame")
local ConsumableManager_OnUpdate
local ConsumableManager_OnEvent
local eventsRegistered
local pendingInit
local pendingRegister

-- Localized globals for hot-path performance (OnUpdate runs every 0.1s)
local GetTime = GetTime
local math_max = math.max
local string_format = string.format
local ipairs = ipairs
local tostring = tostring

-- =========================================================================
--  CONFIG
-- =========================================================================

local COLORS = {
    GREEN = {0.15, 0.9, 0.2},
    YELLOW = {1.0, 0.85, 0.2},
    RED = {1.0, 0.2, 0.2},
    GREY = {0.45, 0.45, 0.45},
}

local config = {
    width = 220,
    height = 10,
    spacing = 4,
    scale = 100,
    texture = "Interface\\Buttons\\WHITE8X8",
    font = "Fonts\\FRIZQT__.TTF",
    fontTime = "Fonts\\ARIALN.TTF",
    bgColor = {0.08, 0.08, 0.08, 0.75},
    iconGap = 10,
    overlayPadding = 8,
}

local SLOT_DEFS = {
    { key = "flask", label = "Flask/Phial", icon = "Interface\\Icons\\INV_Alchemy_70_Flask01",
      patterns = { "flask", "phial" } },
    { key = "combat_potion", label = "Combat Potion", icon = "Interface\\Icons\\INV_Potion_107",
      patterns = { "potion" } },
    { key = "health_potion", label = "Health Potion", icon = "Interface\\Icons\\INV_Potion_54",
      patterns = { "health potion", "healing potion" } },
    { key = "weapon_buff", label = "Weapon Buff", icon = "Interface\\Icons\\INV_Weapon_Shortblade_20",
      patterns = { "oil", "sharpening", "weightstone", "whetstone" } },
    { key = "augment_rune", label = "Augment Rune", icon = "Interface\\Icons\\INV_Misc_Rune_06",
      patterns = { "augment", "augmentation", "rune" } },
    { key = "food", label = "Well Fed", icon = "Interface\\Icons\\INV_Misc_Food_73CinnamonRoll",
      patterns = { "well fed", "food" } },
}

-- =========================================================================
--  HELPERS
-- =========================================================================

local function CreateDropShadow(frame, intensity)
    intensity = intensity or 4
    local shadows = {}
    for i = 1, intensity do
        local shadowLayer = CreateFrame("Frame", nil, frame)
        shadowLayer:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 0.6
        local alpha = (0.18 - (i * 0.03)) * (intensity / 4)
        shadowLayer:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        shadowLayer:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        local shadowTex = shadowLayer:CreateTexture(nil, "BACKGROUND")
        shadowTex:SetAllPoints()
        shadowTex:SetColorTexture(0, 0, 0, alpha)
        table.insert(shadows, shadowLayer)
    end
    return shadows
end

local function AttachConsumableManagerScripts()
    if not ConsumableBarManager then return end
    if type(ConsumableManager_OnUpdate) == "function" then
        ConsumableBarManager:SetScript("OnUpdate", ConsumableManager_OnUpdate)
    end
    if type(ConsumableManager_OnEvent) == "function" then
        ConsumableBarManager:SetScript("OnEvent", ConsumableManager_OnEvent)
    end
end

local function GetSpellIconSafe(spellId)
    if not spellId then return nil end
    if type(GetSpellTexture) == "function" then
        return GetSpellTexture(spellId)
    end
    if C_Spell and type(C_Spell.GetSpellTexture) == "function" then
        return C_Spell.GetSpellTexture(spellId)
    end
    return nil
end

local function GetWeaponItemIcon(slotId)
    if type(GetInventoryItemTexture) ~= "function" then return nil end
    return GetInventoryItemTexture("player", slotId)
end

local function IsInDungeonOrRaid()
    if type(IsInInstance) ~= "function" then return false end
    local _, instanceType = IsInInstance()
    return instanceType == "party" or instanceType == "raid"
end

local function GetHealthPotionCooldownDefaults()
    return 300
end

local function IsHealthPotionSpell(spellName)
    if not spellName then return false end
    local lower = string.lower(spellName)
    return string.find(lower, "health potion", 1, true) or string.find(lower, "healing potion", 1, true)
end

local function SetHealthPotionCooldown(spellId, spellName)
    local start, duration
    if type(GetSpellCooldown) == "function" and spellId then
        start, duration = GetSpellCooldown(spellId)
    end
    if not duration or duration <= 0 then
        duration = GetHealthPotionCooldownDefaults()
        start = GetTime()
    end
    cooldownStates.health_potion = {
        start = start,
        duration = duration,
        expiration = start + duration,
        icon = GetSpellIconSafe(spellId),
        name = spellName or "Health Potion",
    }
    DebugPrint("SetHealthPotionCooldown: name=" .. tostring(spellName) .. " id=" .. tostring(spellId)
        .. " start=" .. tostring(start) .. " duration=" .. tostring(duration))
end

local function CreateBlackBorder(parent)
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(1); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT"); border.top:SetColorTexture(0,0,0,1)
    border.bottom = border:CreateTexture(nil, "OVERLAY"); border.bottom:SetHeight(1); border.bottom:SetPoint("BOTTOMLEFT"); border.bottom:SetPoint("BOTTOMRIGHT"); border.bottom:SetColorTexture(0,0,0,1)
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(1); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT"); border.left:SetColorTexture(0,0,0,1)
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(1); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT"); border.right:SetColorTexture(0,0,0,1)
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

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
end

local function EnsureConsumableSettings()
    if not MidnightUISettings then return nil end
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    local s = MidnightUISettings.ConsumableBars
    if s.enabled == nil then s.enabled = true end
    if s.width == nil then s.width = config.width end
    if s.height == nil then s.height = config.height end
    if s.spacing == nil then s.spacing = config.spacing end
    if s.scale == nil then s.scale = config.scale end
    if s.hideInactive == nil then s.hideInactive = false end
    if s.showInInstancesOnly == nil then s.showInInstancesOnly = false end
    if s.debug == nil then s.debug = false end
    if s.debugVerbose == nil then s.debugVerbose = false end
    return s
end

local function IsConsumableEnabled()
    local s = EnsureConsumableSettings()
    if not s then return true end
    return s.enabled ~= false
end

local function IsConsumableAura(name, spellId, patterns)
    if not name then return false end
    local settings = EnsureConsumableSettings()
    if settings and settings.spellIds and spellId and settings.spellIds[spellId] then
        return true
    end
    local lower = string.lower(name)
    for _, pattern in ipairs(patterns or {}) do
        if string.find(lower, pattern, 1, true) then
            return true
        end
    end
    return false
end

local function IsPlayerSource(sourceUnit, auraInfo)
    if auraInfo and auraInfo.isFromPlayerOrPlayerPet ~= nil then
        return auraInfo.isFromPlayerOrPlayerPet
    end
    if not sourceUnit then return true end
    return sourceUnit == "player" or sourceUnit == "pet" or sourceUnit == "vehicle"
end

local function IsConsumableDebugEnabled()
    local s = EnsureConsumableSettings()
    return s and s.debug == true
end

local function IsConsumableVerboseEnabled()
    local s = EnsureConsumableSettings()
    return s and s.debugVerbose == true
end

local function DebugPrint(msg)
    return
end

local function DebugPrintVerbose(msg)
    return
end

-- =========================================================================
--  BAR CREATION
-- =========================================================================

local container = nil
local bars = {}
local activeAuras = {}
local lastLockedState = nil
local FormatTime
local ApplyBarColor
local slotStates = {}
local cooldownStates = {}
local suppressConsumableDebug = false

local function CreateConsumableContainer()
    if container then return container end
    local frame = CreateFrame("Frame", "MidnightUI_ConsumableBars", UIParent)
    frame:SetSize(config.width, config.height)
    frame:SetFrameStrata("HIGH")
    frame:SetFrameLevel(40)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(false)
    frame:Hide()
    container = frame
    return frame
end

local function CreateConsumableBar(index)
    local bar = CreateFrame("StatusBar", nil, container)
    bar:SetStatusBarTexture(config.texture)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)

    bar.bg = bar:CreateTexture(nil, "BACKGROUND")
    bar.bg:SetAllPoints()
    bar.bg:SetColorTexture(unpack(config.bgColor))

    CreateBlackBorder(bar)
    CreateDropShadow(bar, 3)

    local icon = bar:CreateTexture(nil, "ARTWORK")
    icon:SetSize(config.height + 4, config.height + 4)
    icon:SetPoint("RIGHT", bar, "LEFT", -config.iconGap, 0)
    icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    bar.icon = icon

    local iconBorder = CreateFrame("Frame", nil, bar)
    iconBorder:SetAllPoints(icon)
    CreateBlackBorder(iconBorder)

    local badgeFrame = CreateFrame("Frame", nil, bar)
    badgeFrame:SetFrameLevel(bar:GetFrameLevel() + 6)
    badgeFrame:SetSize(14, 14)
    badgeFrame:SetPoint("TOPRIGHT", icon, "TOPRIGHT", 3, 3)
    badgeFrame:Hide()
    bar.iconBadgeFrame = badgeFrame

    local iconBadge = badgeFrame:CreateTexture(nil, "OVERLAY")
    iconBadge:SetAllPoints(badgeFrame)
    iconBadge:SetColorTexture(0.2, 0.6, 1.0, 1)
    bar.iconBadge = iconBadge

    local iconBadgeBorder = CreateFrame("Frame", nil, badgeFrame)
    iconBadgeBorder:SetAllPoints(badgeFrame)
    CreateBlackBorder(iconBadgeBorder)
    bar.iconBadgeBorder = iconBadgeBorder

    local iconBadgeText = badgeFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    iconBadgeText:SetPoint("CENTER", badgeFrame, "CENTER", 0, 0)
    iconBadgeText:SetTextColor(1, 1, 1)
    bar.iconBadgeText = iconBadgeText

    local nameText = bar:CreateFontString(nil, "OVERLAY")
    SetFontSafe(nameText, config.font, 10, "OUTLINE")
    nameText:SetPoint("LEFT", bar, "LEFT", 4, 0)
    nameText:SetJustifyH("LEFT")
    nameText:SetTextColor(1, 1, 1)
    bar.nameText = nameText

    local timeText = bar:CreateFontString(nil, "OVERLAY")
    SetFontSafe(timeText, config.fontTime, 10, "OUTLINE")
    timeText:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    timeText:SetJustifyH("RIGHT")
    timeText:SetTextColor(1, 1, 1)
    bar.timeText = timeText

    bar:Hide()
    return bar
end

local function EnsureBar(index)
    if not bars[index] then
        bars[index] = CreateConsumableBar(index)
    end
    return bars[index]
end

local function ApplyBarSizing()
    if not container then return end
    local s = EnsureConsumableSettings()
    if not s then return end
    local height = s.height or config.height
    local iconSize = height + 4
    local totalWidth = (s.width or config.width) + iconSize + config.iconGap
    local pad = (container.forceShow and config.overlayPadding) or 0
    container:SetWidth(totalWidth + (pad * 2))
    container:SetScale((s.scale or config.scale) / 100)
    for _, bar in ipairs(bars) do
        bar:SetWidth(s.width or config.width)
        bar:SetHeight(height)
        if bar.nameText then
            bar.nameText:SetWidth((s.width or config.width) * 0.7)
        end
        if bar.icon then
            bar.icon:SetSize(iconSize, iconSize)
            bar.icon:SetPoint("RIGHT", bar, "LEFT", -config.iconGap, 0)
        end
    end
end

local function ApplyBarLayout(visibleCount)
    if not container then return end
    local s = EnsureConsumableSettings()
    if not s then return end
    local height = s.height or config.height
    local spacing = s.spacing or config.spacing
    local iconSize = height + 4
    local rowStep = math.max(height, iconSize) + spacing
    local pad = (container.forceShow and config.overlayPadding) or 0
    visibleCount = visibleCount or #SLOT_DEFS
    for i = 1, #bars do
        local bar = bars[i]
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", pad, -(pad + (i - 1) * rowStep))
        bar:SetPoint("TOPRIGHT", container, "TOPRIGHT", -pad, -(pad + (i - 1) * rowStep))
        if i > visibleCount then
            bar:Hide()
        end
    end
    if visibleCount > 0 then
        container:SetHeight((visibleCount * rowStep) - spacing + (pad * 2))
    else
        container:SetHeight(height + (pad * 2))
    end
end

local function ApplyContainerPosition()
    if not container then return end
    local s = EnsureConsumableSettings()
    if s and s.position and #s.position >= 4 then
        -- Support both {point, relativePoint, x, y} and {point, relativeFrame, relativePoint, x, y}.
        local point = s.position[1]
        local relativePoint = s.position[2]
        local xOfs = s.position[3]
        local yOfs = s.position[4]
        if #s.position >= 5 then
            relativePoint = s.position[3]
            xOfs = s.position[4]
            yOfs = s.position[5]
        end
        container:ClearAllPoints()
        container:SetPoint(point, UIParent, relativePoint, xOfs, yOfs)
    else
        container:ClearAllPoints()
        container:SetPoint("CENTER", UIParent, "CENTER", 0, -180)
    end
end

local function ShowPlaceholderBars()
    ApplyBarSizing()
    ApplyBarLayout()
    for i, def in ipairs(SLOT_DEFS) do
        local bar = EnsureBar(i)
        if bar.icon then bar.icon:SetTexture(def.icon or "Interface\\Icons\\INV_Misc_QuestionMark") end
        if bar.nameText then bar.nameText:SetText(def.label or "") end
        ApplyInactiveStyle(bar)
        bar:Show()
    end
    container:Show()
end

-- =========================================================================
--  AURA COLLECTION
-- =========================================================================

local function CollectConsumableAuras()
    local out = {}
    local settings = EnsureConsumableSettings()
    local debug = settings and settings.debug == true and not suppressConsumableDebug
    local verbose = settings and settings.debugVerbose == true and not suppressConsumableDebug
    if debug then
        DebugPrint("Scanning player auras for consumables...")
    end

    local function HandleAura(name, icon, count, dispelType, duration, expirationTime, sourceUnit, isStealable, nameplateShowPersonal, spellId, canApplyAura, isBossAura, isCastByPlayer, nameplateShowAll, timeMod, auraInfo)
        if verbose then
            local src = sourceUnit or (auraInfo and auraInfo.sourceUnit) or "nil"
            local fromPlayer = (auraInfo and auraInfo.isFromPlayerOrPlayerPet ~= nil) and tostring(auraInfo.isFromPlayerOrPlayerPet) or "n/a"
            DebugPrint(string.format("Aura: %s id=%s dur=%s exp=%s src=%s fromPlayer=%s",
                tostring(name), tostring(spellId), tostring(duration), tostring(expirationTime), tostring(src), tostring(fromPlayer)))
        end
        local safeDuration = duration
        if type(issecretvalue) == "function" and issecretvalue(duration) then
            safeDuration = nil
        end
        if not name or not safeDuration or safeDuration <= 0 then
            if debug and name then
                DebugPrint("Skip aura (no duration): " .. name .. (spellId and (" [ID " .. spellId .. "]") or ""))
            end
            return
        end
        local safeExpiration = expirationTime
        if type(issecretvalue) == "function" and issecretvalue(expirationTime) then
            safeExpiration = nil
        end
        if not safeExpiration or safeExpiration <= 0 then
            if debug then
                DebugPrint("Skip aura (no expiration): " .. name)
            end
            return
        end
        if isBossAura then
            if debug then
                DebugPrint("Skip aura (boss): " .. name)
            end
            return
        end
        -- We'll match by slot patterns later.
        if false then
            if debug then
                DebugPrint("Skip aura (no match): " .. name .. (spellId and (" [ID " .. spellId .. "]") or ""))
            end
            return
        end
        if not IsPlayerSource(sourceUnit, auraInfo) then
            if debug then
                DebugPrint("Skip aura (not player source): " .. name)
            end
            return
        end
        table.insert(out, {
            name = name,
            icon = icon,
            duration = safeDuration,
            expirationTime = safeExpiration,
            spellId = spellId,
            sourceUnit = sourceUnit,
            count = count,
        })
        if debug then
            DebugPrint("Collected aura: " .. name .. " (duration " .. string.format("%.0f", duration) .. "s)")
        end
    end

    if AuraUtil and AuraUtil.ForEachAura then
        AuraUtil.ForEachAura("player", "HELPFUL", nil, function(...)
            local auraInfo = ...
            if type(auraInfo) == "table" then
                HandleAura(
                    auraInfo.name,
                    auraInfo.icon,
                    auraInfo.applications,
                    auraInfo.dispelName,
                    auraInfo.duration,
                    auraInfo.expirationTime,
                    auraInfo.sourceUnit,
                    auraInfo.isStealable,
                    auraInfo.nameplateShowPersonal,
                    auraInfo.spellId,
                    auraInfo.canApplyAura,
                    auraInfo.isBossAura,
                    auraInfo.isFromPlayerOrPlayerPet,
                    auraInfo.nameplateShowAll,
                    auraInfo.timeMod,
                    auraInfo
                )
            else
                HandleAura(...)
            end
        end, true)
    else
        local i = 1
        while true do
            local name, icon, count, dispelType, duration, expirationTime, sourceUnit, isStealable, nameplateShowPersonal, spellId, canApplyAura, isBossAura, isCastByPlayer, nameplateShowAll, timeMod = UnitAura("player", i, "HELPFUL")
            if not name then break end
            HandleAura(name, icon, count, dispelType, duration, expirationTime, sourceUnit, isStealable, nameplateShowPersonal, spellId, canApplyAura, isBossAura, isCastByPlayer, nameplateShowAll, timeMod)
            i = i + 1
        end
    end

    -- Weapon enchants (oils/weightstones/etc)
    local hasMain, mainExp, _, mainEnchantId, hasOff, offExp, _, offEnchantId = GetWeaponEnchantInfo()
    if debug then
        DebugPrint("WeaponEnchantInfo: hasMain=" .. tostring(hasMain) .. " mainExp=" .. tostring(mainExp) .. " hasOff=" .. tostring(hasOff) .. " offExp=" .. tostring(offExp) .. " mainEnchantId=" .. tostring(mainEnchantId) .. " offEnchantId=" .. tostring(offEnchantId))
    end
    if hasMain and type(mainExp) == "number" and mainExp > 0 then
        local mainIcon = (type(mainEnchantId) == "number" and GetSpellIconSafe(mainEnchantId)) or nil
        if not mainIcon then
            mainIcon = GetWeaponItemIcon(16)
        end
        table.insert(out, {
            name = "Mainhand Weapon Buff",
            duration = mainExp / 1000,
            expirationTime = GetTime() + (mainExp / 1000),
            spellId = nil,
            isWeapon = true,
            weaponSlot = "main",
            enchantId = mainEnchantId,
            icon = mainIcon,
        })
        if debug then
            DebugPrint("Matched weapon enchant: Mainhand (" .. string.format("%.0f", mainExp / 1000) .. "s) enchantId=" .. tostring(mainEnchantId) .. " icon=" .. tostring(mainIcon))
        end
    elseif debug then
        DebugPrint("No mainhand weapon enchant detected.")
    end

    if hasOff and type(offExp) == "number" and offExp > 0 then
        local offIcon = (type(offEnchantId) == "number" and GetSpellIconSafe(offEnchantId)) or nil
        if not offIcon then
            offIcon = GetWeaponItemIcon(17)
        end
        table.insert(out, {
            name = "Offhand Weapon Buff",
            duration = offExp / 1000,
            expirationTime = GetTime() + (offExp / 1000),
            spellId = nil,
            isWeapon = true,
            weaponSlot = "off",
            enchantId = offEnchantId,
            icon = offIcon,
        })
        if debug then
            DebugPrint("Matched weapon enchant: Offhand (" .. string.format("%.0f", offExp / 1000) .. "s) enchantId=" .. tostring(offEnchantId) .. " icon=" .. tostring(offIcon))
        end
    elseif debug then
        DebugPrint("No offhand weapon enchant detected.")
    end

    table.sort(out, function(a, b)
        return (a.expirationTime or 0) < (b.expirationTime or 0)
    end)

    if debug and #out == 0 then
        DebugPrint("No consumable auras matched.")
    end

    return out
end

local function DumpAuraLine(name, spellId, duration, expirationTime, sourceUnit, isBossAura, isStealable, auraInfo)
    local fromPlayer = auraInfo and auraInfo.isFromPlayerOrPlayerPet
    if fromPlayer == nil and sourceUnit then
        fromPlayer = (sourceUnit == "player" or sourceUnit == "pet" or sourceUnit == "vehicle")
    end
    local secretDur = (type(issecretvalue) == "function") and issecretvalue(duration) or false
    local secretExp = (type(issecretvalue) == "function") and issecretvalue(expirationTime) or false
    DebugPrint("AuraDump: name=" .. tostring(name)
        .. " id=" .. tostring(spellId)
        .. " dur=" .. tostring(duration)
        .. " exp=" .. tostring(expirationTime)
        .. " secretDur=" .. tostring(secretDur)
        .. " secretExp=" .. tostring(secretExp)
        .. " src=" .. tostring(sourceUnit)
        .. " fromPlayer=" .. tostring(fromPlayer)
        .. " boss=" .. tostring(isBossAura)
        .. " steal=" .. tostring(isStealable))
end

function _G.MidnightUI_Consumables_DumpAuras(maxCount)
    if not IsConsumableDebugEnabled() then
        DebugPrint("DumpAuras: debug is OFF. Use /mui cdebug on")
        return
    end
    maxCount = tonumber(maxCount) or 40
    DebugPrint("DumpAuras: start max=" .. tostring(maxCount))
    local count = 0
    if AuraUtil and AuraUtil.ForEachAura then
        AuraUtil.ForEachAura("player", "HELPFUL", nil, function(...)
            local auraInfo = ...
            if count >= maxCount then return end
            if type(auraInfo) == "table" then
                DumpAuraLine(
                    auraInfo.name,
                    auraInfo.spellId,
                    auraInfo.duration,
                    auraInfo.expirationTime,
                    auraInfo.sourceUnit,
                    auraInfo.isBossAura,
                    auraInfo.isStealable,
                    auraInfo
                )
            else
                local name, _, _, _, duration, expirationTime, sourceUnit, isStealable, _, spellId, _, isBossAura, _, _ = ...
                DumpAuraLine(name, spellId, duration, expirationTime, sourceUnit, isBossAura, isStealable, nil)
            end
            count = count + 1
        end, true)
    else
        local i = 1
        while count < maxCount do
            local name, _, _, _, duration, expirationTime, sourceUnit, isStealable, _, spellId, _, isBossAura = UnitAura("player", i, "HELPFUL")
            if not name then break end
            DumpAuraLine(name, spellId, duration, expirationTime, sourceUnit, isBossAura, isStealable, nil)
            count = count + 1
            i = i + 1
        end
    end
    DebugPrint("DumpAuras: end count=" .. tostring(count))
end

function _G.MidnightUI_Consumables_DebugStatus()
    if not IsConsumableDebugEnabled() then
        DebugPrint("DebugStatus: debug is OFF. Use /mui cdebug on")
        return
    end
    local hasContainer = container ~= nil
    local onUpdate = container and container:GetScript("OnUpdate") ~= nil
    local managerUpdate = ConsumableBarManager and ConsumableBarManager:GetScript("OnUpdate") ~= nil
    local managerEvent = ConsumableBarManager and ConsumableBarManager:GetScript("OnEvent") ~= nil
    DebugPrint("DebugStatus: container=" .. tostring(hasContainer)
        .. " containerOnUpdate=" .. tostring(onUpdate)
        .. " managerOnUpdate=" .. tostring(managerUpdate)
        .. " managerOnEvent=" .. tostring(managerEvent)
        .. " eventsRegistered=" .. tostring(eventsRegistered)
        .. " pendingInit=" .. tostring(pendingInit)
        .. " pendingRegister=" .. tostring(pendingRegister))
    local s = EnsureConsumableSettings()
    DebugPrint("DebugStatus: enabled=" .. tostring(s and s.enabled)
        .. " hideInactive=" .. tostring(s and s.hideInactive)
        .. " showInInstancesOnly=" .. tostring(s and s.showInInstancesOnly))
end

-- =========================================================================
--  DISPLAY + UPDATES
-- =========================================================================

ApplyBarColor = function(bar, remaining, duration)
    if not bar or not duration or duration <= 0 then return end
    local pct = remaining / duration
    if pct <= 0.1 then
        bar:SetStatusBarColor(unpack(COLORS.RED))
    elseif pct <= 0.5 then
        bar:SetStatusBarColor(unpack(COLORS.YELLOW))
    else
        bar:SetStatusBarColor(unpack(COLORS.GREEN))
    end
end

local function ApplyInactiveStyle(bar)
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(1)
    bar:SetStatusBarColor(unpack(COLORS.GREY))
    if bar.icon then
        bar.icon:SetDesaturated(true)
        bar.icon:SetVertexColor(0.6, 0.6, 0.6)
    end
    if bar.iconBadgeFrame then bar.iconBadgeFrame:Hide() end
    if bar.timeText then bar.timeText:SetText("") end
end

FormatTime = function(remaining)
    if not remaining then return "" end
    if remaining >= 3600 then
        local hours = math.floor(remaining / 3600)
        local mins = math.floor((remaining % 3600) / 60)
        return string.format("%dh %dm", hours, mins)
    elseif remaining >= 60 then
        local mins = math.floor(remaining / 60)
        local secs = math.floor(remaining % 60)
        return string.format("%d:%02d", mins, secs)
    else
        return string.format("%d", math.floor(remaining))
    end
end

local function UpdateBarsFromAuras()
    if not container then
        DebugPrint("UpdateBarsFromAuras: no container")
        return
    end
    local settings = EnsureConsumableSettings()
    if not IsConsumableEnabled() then
        DebugPrint("UpdateBarsFromAuras: disabled -> hide")
        container:Hide()
        return
    end
    activeAuras = CollectConsumableAuras()

    -- Instance-only mode: hide when outside dungeons/raids, but only if there
    -- are no active consumable auras. Active consumables always show regardless
    -- of location so the player can track remaining duration.
    if settings and settings.showInInstancesOnly == true and not container.forceShow then
        if not IsInDungeonOrRaid() and #activeAuras == 0 then
            DebugPrint("UpdateBarsFromAuras: not in instance, no active auras -> hide")
            container:Hide()
            return
        end
    end
    if settings and settings.debug == true and not suppressConsumableDebug then
        DebugPrint("UpdateBarsFromAuras: matched=" .. tostring(#activeAuras))
    end
    if (not suppressConsumableDebug) and IsConsumableVerboseEnabled() and #activeAuras > 0 then
        for i, aura in ipairs(activeAuras) do
            local remaining = (aura.expirationTime or 0) - GetTime()
            DebugPrintVerbose("ActiveAura[" .. tostring(i) .. "] name=" .. tostring(aura.name)
                .. " id=" .. tostring(aura.spellId) .. " dur=" .. tostring(aura.duration)
                .. " exp=" .. tostring(aura.expirationTime) .. " remain=" .. string.format("%.1f", remaining))
        end
    end

    ApplyBarSizing()

    slotStates = {}
    for i, def in ipairs(SLOT_DEFS) do
        slotStates[i] = { def = def, active = false }
    end

    local function AssignAuraToSlot(aura)
        local name = aura.name or ""
        local spellId = aura.spellId
        -- Weapon enchants explicitly map to weapon slot
        if aura.isWeapon then
            for i, state in ipairs(slotStates) do
                if state.def.key == "weapon_buff" and not state.active then
                    state.active = true
                    state.aura = aura
                    return true
                end
            end
        end
        for i, state in ipairs(slotStates) do
            if not state.active and IsConsumableAura(name, spellId, state.def.patterns) then
                -- Avoid matching health potion into combat potion slot when specific match exists.
                if state.def.key == "combat_potion" then
                    local lower = string.lower(name)
                    if string.find(lower, "health", 1, true) or string.find(lower, "healing", 1, true) then
                        return false
                    end
                end
                state.active = true
                state.aura = aura
                return true
            end
        end
        return false
    end

    for _, aura in ipairs(activeAuras) do
        AssignAuraToSlot(aura)
    end

    -- If both weapon enchants are active, use the longest remaining and show count 2.
    local weaponCount = 0
    local weaponBest = nil
    for _, aura in ipairs(activeAuras) do
        if aura.isWeapon then
            weaponCount = weaponCount + 1
            if not weaponBest or (aura.expirationTime or 0) > (weaponBest.expirationTime or 0) then
                weaponBest = aura
            end
        end
    end
    local wHasMain, wMainExp, _, _, wHasOff, wOffExp = GetWeaponEnchantInfo()
    local weaponCountInfo = 0
    if wHasMain and type(wMainExp) == "number" and wMainExp > 0 then weaponCountInfo = weaponCountInfo + 1 end
    if wHasOff and type(wOffExp) == "number" and wOffExp > 0 then weaponCountInfo = weaponCountInfo + 1 end
    if weaponCountInfo > weaponCount then
        weaponCount = weaponCountInfo
    end
    if weaponBest and weaponCount > 0 then
        for _, state in ipairs(slotStates) do
            if state.def.key == "weapon_buff" then
                state.active = true
                state.aura = weaponBest
                state.countOverride = weaponCount
                break
            end
        end
    end

    -- Apply health potion cooldown (no aura)
    if cooldownStates.health_potion then
        local cd = cooldownStates.health_potion
        local remaining = (cd.expiration or 0) - GetTime()
        if remaining > 0 then
            for _, state in ipairs(slotStates) do
                if state.def.key == "health_potion" then
                    state.active = true
                    state.aura = {
                        name = cd.name or "Health Potion",
                        duration = cd.duration,
                        expirationTime = cd.expiration,
                        spellId = nil,
                        icon = cd.icon,
                    }
                    break
                end
            end
        else
            cooldownStates.health_potion = nil
        end
    end
    if settings and settings.debug and not suppressConsumableDebug then
        DebugPrint("Weapon buff count=" .. tostring(weaponCount) .. " best=" .. tostring(weaponBest and weaponBest.weaponSlot or "nil"))
    end
    if (not suppressConsumableDebug) and IsConsumableVerboseEnabled() then
        for _, state in ipairs(slotStates) do
            local aura = state.aura
            DebugPrintVerbose("SlotState key=" .. tostring(state.def and state.def.key)
                .. " active=" .. tostring(state.active)
                .. " aura=" .. tostring(aura and aura.name)
                .. " id=" .. tostring(aura and aura.spellId)
                .. " exp=" .. tostring(aura and aura.expirationTime))
        end
    end
    local settings = EnsureConsumableSettings()
    local hideInactive = settings and settings.hideInactive == true
    local visibleStates = {}
    if hideInactive and not container.forceShow then
        for _, state in ipairs(slotStates) do
            if state.active then
                table.insert(visibleStates, state)
            end
        end
    else
        for _, state in ipairs(slotStates) do
            table.insert(visibleStates, state)
        end
    end

    if #visibleStates == 0 then
        if container.forceShow then
            visibleStates = slotStates
        else
            container:Hide()
            return
        end
    end

    ApplyBarLayout(#visibleStates)

    for i, state in ipairs(visibleStates) do
        local bar = EnsureBar(i)
        local def = state.def
        if bar.icon then
            bar.icon:SetTexture(def.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
        end
        if state.active and state.aura then
            local aura = state.aura
            local activeIcon = aura.icon
                or (aura.spellId and GetSpellIconSafe(aura.spellId))
                or (aura.enchantId and GetSpellIconSafe(aura.enchantId))
                or (aura.isWeapon and (GetWeaponItemIcon(16) or GetWeaponItemIcon(17)))
                or nil
            if activeIcon and bar.icon then bar.icon:SetTexture(activeIcon) end
            if bar.icon then
                bar.icon:SetDesaturated(false)
                bar.icon:SetVertexColor(1, 1, 1)
            end
            if bar.iconBadgeFrame and bar.iconBadgeText then
                local count = state.countOverride or aura.count or 0
                if count and count > 1 then
                    bar.iconBadgeText:SetText(tostring(count))
                    local w = bar.iconBadgeText:GetStringWidth() + 6
                    local width = math.max(12, w)
                    bar.iconBadgeFrame:SetWidth(width)
                    bar.iconBadgeFrame:Show()
                else
                    bar.iconBadgeFrame:Hide()
                end
            end
            if settings and settings.debug and not suppressConsumableDebug then
                DebugPrint("Slot " .. tostring(def.key) .. " active icon=" .. tostring(activeIcon) .. " count=" .. tostring(state.countOverride or aura.count or 0))
            end
            bar:SetMinMaxValues(0, aura.duration or 1)
            local remaining = math.max(0, (aura.expirationTime or 0) - GetTime())
            bar:SetValue(remaining)
            if bar.nameText then bar.nameText:SetText(def.label or aura.name or "") end
            if bar.timeText then bar.timeText:SetText(FormatTime(remaining)) end
            ApplyBarColor(bar, remaining, aura.duration or 1)
        else
            if bar.nameText then bar.nameText:SetText(def.label or "") end
            ApplyInactiveStyle(bar)
        end
        bar:Show()
    end

    for i = #visibleStates + 1, #bars do
        if bars[i] then bars[i]:Hide() end
    end

    container:Show()
end

local function OnUpdate(self, elapsed)
    self._muiElapsed = (self._muiElapsed or 0) + elapsed
    if self._muiElapsed < 0.1 then return end
    self._muiElapsed = 0

    if not slotStates or #slotStates == 0 then return end
    if not container or not container:IsShown() then return end

    local now = GetTime()
    local needsRefresh = false
    local settings = EnsureConsumableSettings()
    local hideInactive = settings and settings.hideInactive == true
    if IsConsumableVerboseEnabled() then
        self._muiDebugElapsed = (self._muiDebugElapsed or 0) + 0.1
        if self._muiDebugElapsed >= 1.0 then
            self._muiDebugElapsed = 0
            DebugPrintVerbose("OnUpdate tick: now=" .. string_format("%.2f", now)
                .. " hideInactive=" .. tostring(hideInactive))
        end
    end
    local idx = 0
    for _, state in ipairs(slotStates) do
        local showState = (not hideInactive) or container.forceShow or state.active
        if showState then
            idx = idx + 1
            local bar = bars[idx]
            if bar and state and state.active and state.aura then
                local aura = state.aura
                local remaining = math_max(0, (aura.expirationTime or 0) - now)
                bar:SetValue(remaining)
                if bar.timeText then bar.timeText:SetText(FormatTime(remaining)) end
                ApplyBarColor(bar, remaining, aura.duration or 1)
                if remaining <= 0 then
                    needsRefresh = true
                end
            end
        end
    end

    if needsRefresh then
        DebugPrint("OnUpdate: remaining <= 0 -> refresh")
        UpdateBarsFromAuras()
    end
end

-- =========================================================================
--  OVERLAY (MOVE MODE)
-- =========================================================================

local function EnsureConsumableOverlay()
    if not container or container.dragOverlay then return end
    local overlay = CreateFrame("Frame", nil, container, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("DIALOG")
    overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
    if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "bars") end
    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER")
    label:SetText("CONSUMABLES")
    label:SetTextColor(1, 1, 1)
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function() container:StartMoving() end)
    overlay:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        local point, relativeTo, relativePoint, xOfs, yOfs = container:GetPoint()
        local s = container:GetScale()
        if not s or s == 0 then s = 1.0 end
        xOfs = xOfs / s
        yOfs = yOfs / s
        local settings = EnsureConsumableSettings()
        if settings then
            settings.position = { point, relativePoint, xOfs, yOfs }
        end
    end)
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "ConsumableBars")
    end
    container.dragOverlay = overlay
end

local function ApplyConsumableLockState(locked)
    if not container then return end
    if not IsConsumableEnabled() then
        container.forceShow = false
        if container.dragOverlay then container.dragOverlay:Hide() end
        container:Hide()
        return
    end

    container.forceShow = not locked
    ApplyBarSizing()
    ApplyContainerPosition()

    if locked then
        if container.dragOverlay then container.dragOverlay:Hide() end
        container:EnableMouse(false)
        UpdateBarsFromAuras()
    else
        EnsureConsumableOverlay()
        if container.dragOverlay then container.dragOverlay:Show() end
        container:EnableMouse(true)
        UpdateBarsFromAuras()
    end
end

function _G.MidnightUI_SetConsumableBarsLocked(locked)
    CreateConsumableContainer()
    ApplyConsumableLockState(locked)
end

function _G.MidnightUI_ForceShowConsumableOverlay()
    CreateConsumableContainer()
    EnsureConsumableOverlay()
    container.forceShow = true
    container:EnableMouse(true)
    if container.dragOverlay then container.dragOverlay:Show() end
    ShowPlaceholderBars()
end

function _G.MidnightUI_ResetConsumablePosition()
    local s = EnsureConsumableSettings()
    if s then s.position = nil end
    CreateConsumableContainer()
    ApplyContainerPosition()
end

function _G.MidnightUI_ApplyConsumableBarsSettings()
    local locked = true
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
        locked = MidnightUISettings.Messenger.locked
    end
    CreateConsumableContainer()
    lastLockedState = locked
    ApplyConsumableLockState(locked)
    UpdateBarsFromAuras()
end

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function BuildConsumableOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureConsumableSettings()
    if not s then return end
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Consumables")
    b:Checkbox("Enable", s.enabled ~= false, function(v)
        s.enabled = v
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Checkbox("Hide Inactive Bars", s.hideInactive == true, function(v)
        s.hideInactive = v
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Checkbox("Show in Dungeon/Raid Only", s.showInInstancesOnly == true, function(v)
        s.showInInstancesOnly = v
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Width", 120, 400, 5, s.width or config.width, function(v)
        s.width = math.floor(v)
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Height", 6, 24, 1, s.height or config.height, function(v)
        s.height = math.floor(v)
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Spacing", 0, 12, 1, s.spacing or config.spacing, function(v)
        s.spacing = math.floor(v)
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or config.scale, function(v)
        s.scale = math.floor(v)
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle(key)
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("ConsumableBars", { title = "Consumables", build = BuildConsumableOverlaySettings })
end

-- =========================================================================
--  EVENTS
-- =========================================================================

eventsRegistered = false
local auraRefreshRetryPending = false

local function ScheduleAuraRefreshRetry()
    if auraRefreshRetryPending then return end
    auraRefreshRetryPending = true
    C_Timer.After(0.2, function()
        auraRefreshRetryPending = false
        UpdateBarsFromAuras()
    end)
end

local function RegisterConsumableEventsOnce()
    if eventsRegistered then return end
    -- Poll mode intentionally avoids RegisterEvent/RegisterUnitEvent to prevent
    -- ADDON_ACTION_FORBIDDEN: Frame:RegisterEvent() on reload.
    eventsRegistered = true
    DebugPrint("Event registration disabled (poll mode).")
end

local function InitConsumableBars()
    -- Defer container creation until consumables are enabled and player has auras
    if not IsConsumableEnabled() then return end
    CreateConsumableContainer()
    ApplyContainerPosition()
    if container then
        container:SetScript("OnUpdate", OnUpdate)
    end
    if MidnightUISettings and MidnightUISettings.Messenger then
        lastLockedState = MidnightUISettings.Messenger.locked
        ApplyConsumableLockState(lastLockedState)
    end
    UpdateBarsFromAuras()
end

ConsumableManager_OnUpdate = function(self, elapsed)
    if not self._muiInitialized then
        InitConsumableBars()
        self._muiInitialized = true
    end

    self._muiAuraPollElapsed = (self._muiAuraPollElapsed or 0) + elapsed
    if self._muiAuraPollElapsed >= 0.25 then
        self._muiAuraPollElapsed = 0
        suppressConsumableDebug = true
        local ok, err = pcall(UpdateBarsFromAuras)
        suppressConsumableDebug = false
        if not ok then
            if type(geterrorhandler) == "function" and geterrorhandler() then
                geterrorhandler()(err)
            end
        end
    end

    self._muiElapsed = (self._muiElapsed or 0) + elapsed
    if self._muiElapsed < 0.5 then return end
    self._muiElapsed = 0
    if not MidnightUISettings or not MidnightUISettings.Messenger then return end
    if lastLockedState == nil then
        lastLockedState = MidnightUISettings.Messenger.locked
        return
    end
    if MidnightUISettings.Messenger.locked ~= lastLockedState then
        lastLockedState = MidnightUISettings.Messenger.locked
        CreateConsumableContainer()
        ApplyConsumableLockState(lastLockedState)
    end
end
ConsumableManager_OnEvent = function(self, event, ...)
    local s = EnsureConsumableSettings()
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end
        InitConsumableBars()
        self:UnregisterEvent("ADDON_LOADED")
        if s and s.debug then
            DebugPrint("ADDON_LOADED: init complete (logger=" .. tostring(_G.MidnightUI_LogDebug ~= nil or _G.MidnightUI_Debug ~= nil) .. ")")
        end
        DebugPrint("ADDON_LOADED for " .. tostring(addonName))
        if MidnightUISettings and MidnightUISettings.Messenger then
            lastLockedState = MidnightUISettings.Messenger.locked
            ApplyConsumableLockState(lastLockedState)
        end
        C_Timer.After(0.2, UpdateBarsFromAuras)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        CreateConsumableContainer()
        ApplyContainerPosition()
        if s and s.debug then
            DebugPrint("PLAYER_ENTERING_WORLD: refreshing")
        end
        DebugPrint("PLAYER_ENTERING_WORLD")
        if MidnightUISettings and MidnightUISettings.Messenger then
            lastLockedState = MidnightUISettings.Messenger.locked
            ApplyConsumableLockState(lastLockedState)
        end
        UpdateBarsFromAuras()
        C_Timer.After(0.5, UpdateBarsFromAuras)
        C_Timer.After(2.0, UpdateBarsFromAuras)
        return
    end

    if event == "UNIT_AURA" then
        local unit = ...
        if unit ~= "player" then return end
        if s and s.debug then
            DebugPrint("UNIT_AURA: player")
        end
        DebugPrint("UNIT_AURA: player")
        UpdateBarsFromAuras()
        ScheduleAuraRefreshRetry()
        return
    end

    if event == "UNIT_INVENTORY_CHANGED" then
        local unit = ...
        if unit ~= "player" then return end
        if s and s.debug then
            DebugPrint("UNIT_INVENTORY_CHANGED: player")
        end
        DebugPrint("UNIT_INVENTORY_CHANGED: player")
        UpdateBarsFromAuras()
        return
    end

    if event == "PLAYER_EQUIPMENT_CHANGED" then
        if s and s.debug then
            DebugPrint("PLAYER_EQUIPMENT_CHANGED")
        end
        DebugPrint("PLAYER_EQUIPMENT_CHANGED")
        UpdateBarsFromAuras()
        return
    end

    if event == "COMBAT_LOG_EVENT_UNFILTERED" then
        local _, subEvent, _, sourceGUID, sourceName, _, _, destGUID, _, _, _, spellId, spellName = CombatLogGetCurrentEventInfo()
        if sourceGUID == UnitGUID("player") then
            DebugPrint("COMBAT_LOG: " .. tostring(subEvent) .. " spell=" .. tostring(spellName)
                .. " id=" .. tostring(spellId) .. " source=" .. tostring(sourceName))
        end
        if destGUID == UnitGUID("player")
            and (subEvent == "SPELL_AURA_APPLIED" or subEvent == "SPELL_AURA_REFRESH" or subEvent == "SPELL_AURA_REMOVED") then
            ScheduleAuraRefreshRetry()
        end
        if subEvent == "SPELL_CAST_SUCCESS" and sourceGUID == UnitGUID("player") then
            if IsHealthPotionSpell(spellName) then
                SetHealthPotionCooldown(spellId, spellName)
                if s and s.debug then
                    DebugPrint("Health potion used: " .. tostring(spellName) .. " id=" .. tostring(spellId))
                end
                UpdateBarsFromAuras()
            end
        end
    end
end

AttachConsumableManagerScripts()
RegisterConsumableEventsOnce()
