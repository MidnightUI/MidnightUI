-- =============================================================================
-- FILE PURPOSE:     Loot distribution window with gear comparison. On LOOT_READY fires,
--                   shows a panel with each loot item's icon, name, ilvl, type, and a
--                   group upgrade comparison that inspects every group member's equipped
--                   gear in the matching slot — with fallback to addon-message gear caches
--                   and a retry-with-backoff inspect system.
-- LOAD ORDER:       Loads after Settings.lua. LootWindow is created at file scope;
--                   event registration happens immediately (no ADDON_LOADED gate).
-- DEFINES:          LootWindow (Frame, "MidnightLootWindow"), activeRows[], gearCommCache[],
--                   UpdateGroupWindow (function ref). Globals: SafeToString, MidnightUI_SafeToString.
-- READS:            MidnightUISettings.LootWindow.debugVerbose — verbose debug gate.
--                   GetInventoryItemLink(unit, slot), GetDetailedItemLevelInfo(link),
--                   CanInspect(unit), NotifyInspect(unit) — gear resolution chain.
-- WRITES:           gearCommCache[guid][slot] — caches gear links from inspect/addon messages.
--                   inspectCooldown[unit] — epoch time of last inspect request.
--                   pendingAddonRequests[key] — throttles addon gear request broadcasts.
-- DEPENDS ON:       MidnightUI_Core.GetClassColorTable (row accent colors per class).
--                   C_ChatInfo.SendAddonMessage (COMM_PREFIX="MUI_GEAR") — peer gear exchange.
-- USED BY:          Nothing external — self-contained loot event handler.
-- KEY FLOWS:
--   LOOT_READY → UpdateGroupWindow(nil) → iterates loot slots → builds item rows
--   Per row: GetBestEquippedLink() → compare vs loot ilvl → show upgrade delta
--   INSPECT_READY → CacheInspectGear(unit, guid) → refresh group window
--   CHAT_MSG_ADDON MUI_GEAR/REQ → SendGearResponse — respond to peer gear requests
--   CHAT_MSG_ADDON MUI_GEAR/RES → store in gearCommCache → refresh window
--   GROUP_ROSTER_UPDATE → BroadcastGroupGearCache() — proactively share own gear
-- GOTCHAS:
--   Inspect system has two cooldown layers: INSPECT_COOLDOWN (5s between requests per unit)
--   and INSPECT_GRACE (4s window after request to wait for INSPECT_READY). QueueInspectRetry
--   implements exponential backoff with INSPECT_RETRY_MAX = 8 total attempts.
--   GetBestEquippedLink(): for multi-slot items (rings, trinkets, weapons) checks all
--   candidate slots and picks the lowest-ilvl equipped to compute the largest upgrade.
--   SLOT_MAP + ARMOR_TYPES + WEAPON_TYPES + HOLDABLE_CLASSES: used to filter which loot
--   items are equippable by each class before showing upgrade comparison.
--   BroadcastRaidGearCache is throttled (5s) and staggers slot sends 50ms apart to avoid
--   flooding the addon message channel.
--   addonName, ns = ... pattern: LootWindow uses the WoW vararg but assigns SafeToString
--   to both _G.SafeToString and _G.MidnightUI_SafeToString as compatibility shims.
-- NAVIGATION:
--   C{}                     — visual config: colors, font, dimensions (line ~3)
--   SLOT_MAP{}              — INVTYPE_* → inventory slot number (line ~334)
--   ARMOR_TYPES / WEAPON_TYPES — class equippability lookup (line ~344-373)
--   RequestInspect()        — sends NotifyInspect with cooldown + grace tracking
--   QueueInspectRetry()     — retry-with-backoff for failed inspects
--   GetBestEquippedLink()   — multi-slot best-equipped ilvl resolver
--   UpdateGroupWindow()     — full window rebuild from current loot + cached gear
-- =============================================================================

local addonName, ns = ...

-- :: CONFIGURATION :: --
local C = {
    font = "Fonts\\FRIZQT__.TTF",
    windowBg = {0.03, 0.03, 0.05, 0.98}, 
    rowBg = {0.06, 0.06, 0.08, 0.65},
    rowHover = {0.15, 0.15, 0.2, 0.5},
    text = {0.9, 0.9, 0.9, 1},
    subText = {0.7, 0.7, 0.7, 1},
    accent = (_G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable and _G.MidnightUI_Core.GetClassColorTable("player"))
        or C_ClassColor.GetClassColor(select(2, UnitClass("player"))),
    width = 440,
    rowHeight = 52,
    iconSize = 38,
    headerHeight = 36,
    padding = 10,
}

local activeRows = {}
local groupDebugCache = {}
local lootDebugCache = {}
local inspectCooldown = {}
local inspectGrace = {}
local inspectGraceTimers = {}
local pendingInspect = {}
local pendingInspectTries = {}
local gearCommCache = {}
local pendingAddonRequests = {}
local addonWaitUntil = {}
local COMM_PREFIX = "MUI_GEAR"
local ADDON_REQ_COOLDOWN = 3
local lastBossCacheTime = 0
local lastGroupCacheTime = 0
local UpdateGroupWindow
local INSPECT_COOLDOWN = 5
local INSPECT_GRACE = 4
local INSPECT_RETRY_BASE = 0.8
local INSPECT_RETRY_MAX = 8
local ADDON_WAIT_GRACE = 0.6
local SLOT_MAP

local function GetExactClassColorTable(classFile)
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable then
        return _G.MidnightUI_Core.GetClassColorTable(classFile)
    end
    if C_ClassColor and C_ClassColor.GetClassColor then
        return C_ClassColor.GetClassColor(classFile)
    end
    return { r = 1, g = 1, b = 1 }
end

local function SafeToStringLocal(v)
    if v == nil then return "nil" end
    if v == false then return "false" end
    local ok, s = pcall(tostring, v)
    if not ok then return "[Restricted]" end
    return s
end
_G.SafeToString = _G.SafeToString or SafeToStringLocal
_G.MidnightUI_SafeToString = _G.MidnightUI_SafeToString or SafeToStringLocal

local function LootDebugVerboseEnabled()
    return MidnightUISettings
        and MidnightUISettings.LootWindow
        and MidnightUISettings.LootWindow.debugVerbose == true
end

local function LootDebugVerbose(msg)
    if LootDebugVerboseEnabled() and _G.MidnightUI_Debug then
        _G.MidnightUI_Debug(msg)
    end
end

local function LogGroupDebug(msg)
    LootDebugVerbose("LOOT: GroupCompare " .. SafeToStringLocal(msg))
end

local INSPECT_SLOTS = {1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 13, 15, 16, 17}

local function FindUnitByGuid(guid)
    if not guid then return nil end
    if UnitGUID("player") == guid then return "player" end
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local unit = "raid" .. i
            if UnitGUID(unit) == guid then return unit end
        end
    else
        for i = 1, GetNumGroupMembers() do
            local unit = "party" .. i
            if UnitGUID(unit) == guid then return unit end
        end
    end
    return nil
end

local function CacheInspectGear(unit, guid)
    if not unit or not guid then return end
    gearCommCache[guid] = gearCommCache[guid] or {}
    local cached = 0
    for _, slot in ipairs(INSPECT_SLOTS) do
        local link = GetInventoryItemLink(unit, slot)
        if link then
            gearCommCache[guid][slot] = link
            cached = cached + 1
        end
    end
    LogGroupDebug("[GroupCompare] inspect cache guid=" .. SafeToStringLocal(guid) .. " unit=" .. SafeToStringLocal(unit) .. " links=" .. SafeToStringLocal(cached))
end

local function GetInspectCooldownRemaining(unit)
    local now = GetTime()
    local last = inspectCooldown[unit] or 0
    local remaining = INSPECT_COOLDOWN - (now - last)
    if remaining < 0 then remaining = 0 end
    return remaining
end

local function GetCandidateSlots(lootEquipLoc)
    if lootEquipLoc == "INVTYPE_FINGER" then
        return {11, 12}
    elseif lootEquipLoc == "INVTYPE_TRINKET" then
        return {13, 14}
    elseif lootEquipLoc == "INVTYPE_WEAPON" then
        return {16, 17}
    elseif lootEquipLoc == "INVTYPE_2HWEAPON" then
        return {16}
    elseif lootEquipLoc == "INVTYPE_WEAPONMAINHAND" then
        return {16}
    elseif lootEquipLoc == "INVTYPE_WEAPONOFFHAND" or lootEquipLoc == "INVTYPE_SHIELD" or lootEquipLoc == "INVTYPE_HOLDABLE" then
        return {17}
    end
    local slot = SLOT_MAP[lootEquipLoc]
    if slot then return {slot} end
    return nil
end

local function GetUnitKey(unit)
    local guid = UnitGUID(unit)
    if guid then return guid end
    local name, realm = UnitName(unit)
    if not name then return nil end
    if realm and realm ~= "" then
        return name .. "-" .. realm
    end
    return name .. "-" .. GetRealmName()
end

local function GetUnitCacheKey(unit)
    local key = GetUnitKey(unit)
    if not key then
        LogGroupDebug("[GroupCompare] unit key missing unit=" .. SafeToStringLocal(unit))
    end
    return key
end

local function ResolveEquippedLink(unit, slot, unitKey)
    local link = GetInventoryItemLink(unit, slot)
    if link then
        return link, "inventory"
    end
    local cached = unitKey and gearCommCache[unitKey] and gearCommCache[unitKey][slot] or nil
    if cached == false then
        return nil, "cache_miss"
    end
    if cached then
        return cached, "cache_hit"
    end
    return nil, "no_cache"
end

local function GetBestEquippedLink(unit, candidateSlots)
    local unitKey = GetUnitCacheKey(unit)
    local best = nil
    local bestSlot = nil
    local bestSource = nil
    local bestILvl = -1
    local anyCacheMiss = false
    local anyNoCache = false

    for _, slot in ipairs(candidateSlots) do
        local link, source = ResolveEquippedLink(unit, slot, unitKey)
        if source == "cache_miss" then anyCacheMiss = true end
        if source == "no_cache" then anyNoCache = true end
        LogGroupDebug("[GroupCompare] slot probe unit=" .. SafeToStringLocal(unit) .. " slot=" .. SafeToStringLocal(slot) .. " source=" .. SafeToStringLocal(source) .. " link=" .. SafeToStringLocal(link))
        if link then
            local ilvl = GetDetailedItemLevelInfo(link) or select(4, GetItemInfo(link)) or 0
            if ilvl > bestILvl then
                best = link
                bestSlot = slot
                bestSource = source
                bestILvl = ilvl
            end
        end
    end

    return best, bestSlot, bestSource, bestILvl, anyCacheMiss, anyNoCache
end

local function GetGroupChannel()
    if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    if IsInRaid() then return "RAID" end
    return "PARTY"
end

local function SendGearRequest(unit, slot)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    local guid = GetUnitKey(unit)
    if not guid then return end
    local msg = "REQ|" .. guid .. "|" .. tostring(slot)
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, GetGroupChannel())
    LogGroupDebug("[GroupCompare] addon REQ guid=" .. SafeToStringLocal(guid) .. " unit=" .. SafeToStringLocal(unit) .. " slot=" .. SafeToStringLocal(slot))
end

local function MaybeSendAddonRequest(unit, slot, reason)
    if not unit or not slot then return end
    if IsInRaid() then return end
    local guid = GetUnitKey(unit)
    if not guid then return end
    local key = guid .. ":" .. tostring(slot)
    local now = GetTime()
    local last = pendingAddonRequests[key] or 0
    if now - last < ADDON_REQ_COOLDOWN then
        return
    end
    pendingAddonRequests[key] = now
    LogGroupDebug("[GroupCompare] addon REQ schedule unit=" .. SafeToStringLocal(unit) .. " slot=" .. SafeToStringLocal(slot) .. " reason=" .. SafeToStringLocal(reason))
    SendGearRequest(unit, slot)
end

local function SendGearResponse(slot)
    if not C_ChatInfo or not C_ChatInfo.SendAddonMessage then return end
    local guid = GetUnitKey("player")
    if not guid then return end
    local link = GetInventoryItemLink("player", slot)
    local payload = link or "NONE"
    local msg = "RES|" .. guid .. "|" .. tostring(slot) .. "|" .. payload
    C_ChatInfo.SendAddonMessage(COMM_PREFIX, msg, GetGroupChannel())
    LogGroupDebug("[GroupCompare] addon RES guid=" .. SafeToStringLocal(guid) .. " slot=" .. SafeToStringLocal(slot) .. " payload=" .. SafeToStringLocal(payload))
end

local function BroadcastRaidGearCache()
    if not IsInRaid() then return end
    local now = GetTime()
    if (now - lastBossCacheTime) < 5 then return end
    lastBossCacheTime = now
    local delay = 0
    for slot = 1, 17 do
        C_Timer.After(delay, function()
            SendGearResponse(slot)
        end)
        delay = delay + 0.05
    end
end

local function BroadcastGroupGearCache(reason)
    if not IsInGroup() or IsInRaid() then return end
    local now = GetTime()
    if (now - lastGroupCacheTime) < 10 then
        LogGroupDebug("[GroupCompare] addon cache skip reason=" .. SafeToStringLocal(reason) .. " since=" .. SafeToStringLocal(now - lastGroupCacheTime))
        return
    end
    lastGroupCacheTime = now
    LogGroupDebug("[GroupCompare] addon cache broadcast reason=" .. SafeToStringLocal(reason))
    local delay = 0
    for slot = 1, 17 do
        C_Timer.After(delay, function()
            SendGearResponse(slot)
        end)
        delay = delay + 0.03
    end
end

local function RequestInspect(unit)
    if not CanInspect(unit) then
        LogGroupDebug("[GroupCompare] inspect blocked unit=" .. SafeToStringLocal(unit) .. " reason=CanInspect=false")
        return false, "caninspect", 0
    end
    local remaining = GetInspectCooldownRemaining(unit)
    if remaining > 0 then
        LogGroupDebug("[GroupCompare] inspect blocked unit=" .. SafeToStringLocal(unit) .. " reason=cooldown remaining=" .. SafeToStringLocal(remaining))
        return false, "cooldown", remaining
    end
    local now = GetTime()
    inspectCooldown[unit] = now
    inspectGrace[unit] = now + INSPECT_GRACE
    pcall(NotifyInspect, unit)
    LogGroupDebug("[GroupCompare] inspect request unit=" .. SafeToStringLocal(unit))
    return true, "sent", 0
end

local function QueueInspectRetry(key, unit, lootLink, delay)
    local tries = pendingInspectTries[key] or 0
    local graceUntil = inspectGrace[unit] or 0
    local now = GetTime()
    if tries >= 3 and now >= graceUntil then
        pendingInspectTries[key] = nil
        pendingInspect[key] = nil
        LogGroupDebug("[GroupCompare] inspect retry stop unit=" .. SafeToStringLocal(unit) .. " key=" .. SafeToStringLocal(key) .. " tries=" .. SafeToStringLocal(tries) .. " graceUntil=" .. SafeToStringLocal(graceUntil))
        return
    end
    if tries >= INSPECT_RETRY_MAX then
        pendingInspectTries[key] = nil
        pendingInspect[key] = nil
        LogGroupDebug("[GroupCompare] inspect retry stop unit=" .. SafeToStringLocal(unit) .. " key=" .. SafeToStringLocal(key) .. " tries=" .. SafeToStringLocal(tries) .. " reason=max_tries")
        return
    end
    local retryDelay = delay or INSPECT_RETRY_BASE
    pendingInspectTries[key] = tries + 1
    LogGroupDebug("[GroupCompare] inspect retry schedule unit=" .. SafeToStringLocal(unit) .. " key=" .. SafeToStringLocal(key) .. " try=" .. SafeToStringLocal(pendingInspectTries[key]) .. " delay=" .. SafeToStringLocal(retryDelay))
    pendingInspect[key] = true
    C_Timer.After(retryDelay, function()
        if not UnitExists(unit) then
            pendingInspectTries[key] = nil
            pendingInspect[key] = nil
            LogGroupDebug("[GroupCompare] inspect retry cancel unit=" .. SafeToStringLocal(unit) .. " reason=unit_missing")
            return
        end
        local ok, reason, remaining = RequestInspect(unit)
        if ok then
            pendingInspect[key] = true
            LogGroupDebug("[GroupCompare] inspect retry sent unit=" .. SafeToStringLocal(unit) .. " key=" .. SafeToStringLocal(key))
        elseif reason == "cooldown" and remaining and remaining > 0 then
            LogGroupDebug("[GroupCompare] inspect retry wait unit=" .. SafeToStringLocal(unit) .. " key=" .. SafeToStringLocal(key) .. " remaining=" .. SafeToStringLocal(remaining))
            QueueInspectRetry(key, unit, lootLink, math.max(remaining + 0.1, INSPECT_RETRY_BASE))
        end
        UpdateGroupWindow(lootLink)
    end)
end

-- :: CONSTANTS & LOOKUP TABLES :: --
-- Moved outside functions for performance optimization
SLOT_MAP = {
    ["INVTYPE_HEAD"] = 1, ["INVTYPE_NECK"] = 2, ["INVTYPE_SHOULDER"] = 3,
    ["INVTYPE_BODY"] = 4, ["INVTYPE_CHEST"] = 5, ["INVTYPE_ROBE"] = 5,
    ["INVTYPE_WAIST"] = 6, ["INVTYPE_LEGS"] = 7, ["INVTYPE_FEET"] = 8,
    ["INVTYPE_WRIST"] = 9, ["INVTYPE_HAND"] = 10, ["INVTYPE_FINGER"] = 11,
    ["INVTYPE_TRINKET"] = 13, ["INVTYPE_CLOAK"] = 15, ["INVTYPE_WEAPON"] = 16,
    ["INVTYPE_SHIELD"] = 17, ["INVTYPE_2HWEAPON"] = 16, ["INVTYPE_WEAPONMAINHAND"] = 16,
    ["INVTYPE_WEAPONOFFHAND"] = 17, ["INVTYPE_HOLDABLE"] = 17,
}

local ARMOR_TYPES = {
    ["Plate"]   = {WARRIOR=true, PALADIN=true, DEATHKNIGHT=true},
    ["Mail"]    = {HUNTER=true, SHAMAN=true, EVOKER=true},
    ["Leather"] = {ROGUE=true, DRUID=true, MONK=true, DEMONHUNTER=true},
    ["Cloth"]   = {MAGE=true, PRIEST=true, WARLOCK=true}
}

local WEAPON_TYPES = {
    ["One-Handed Axes"]   = {WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true, SHAMAN=true, MONK=true, DEMONHUNTER=true, DEATHKNIGHT=true, EVOKER=true},
    ["Two-Handed Axes"]   = {WARRIOR=true, PALADIN=true, HUNTER=true, SHAMAN=true, DEATHKNIGHT=true},
    ["One-Handed Maces"]  = {WARRIOR=true, PALADIN=true, ROGUE=true, PRIEST=true, SHAMAN=true, MONK=true, DRUID=true, DEATHKNIGHT=true, EVOKER=true},
    ["Two-Handed Maces"]  = {WARRIOR=true, PALADIN=true, SHAMAN=true, DRUID=true, DEATHKNIGHT=true},
    ["One-Handed Swords"] = {WARRIOR=true, PALADIN=true, HUNTER=true, ROGUE=true, MAGE=true, WARLOCK=true, MONK=true, DEMONHUNTER=true, DEATHKNIGHT=true, EVOKER=true},
    ["Two-Handed Swords"] = {WARRIOR=true, PALADIN=true, HUNTER=true, DEATHKNIGHT=true},
    ["Daggers"]           = {ROGUE=true, PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true, SHAMAN=true, HUNTER=true, EVOKER=true},
    ["Staves"]            = {PRIEST=true, MAGE=true, WARLOCK=true, DRUID=true, SHAMAN=true, HUNTER=true, MONK=true, EVOKER=true},
    ["Polearms"]          = {WARRIOR=true, PALADIN=true, HUNTER=true, MONK=true, DRUID=true, DEATHKNIGHT=true},
    ["Fist Weapons"]      = {ROGUE=true, SHAMAN=true, MONK=true, DRUID=true, DEMONHUNTER=true, WARRIOR=true, HUNTER=true, EVOKER=true},
    ["Wands"]             = {PRIEST=true, MAGE=true, WARLOCK=true},
    ["Bows"]              = {HUNTER=true, WARRIOR=true, ROGUE=true},
    ["Guns"]              = {HUNTER=true, WARRIOR=true, ROGUE=true},
    ["Crossbows"]         = {HUNTER=true, WARRIOR=true, ROGUE=true},
    ["Warglaives"]        = {DEMONHUNTER=true},
    ["Shields"]           = {WARRIOR=true, PALADIN=true, SHAMAN=true}
}

local HOLDABLE_CLASSES = {
    MAGE=true, PRIEST=true, WARLOCK=true, DRUID=true, SHAMAN=true, EVOKER=true
}

-- :: DEBUG HELPER :: --
local function DebugLog(...)
    if LootDebugVerboseEnabled() and _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("LOOT:", ...)
    end
end

-- :: FRAME SETUP :: --
local LootWindow = CreateFrame("Frame", "MidnightLootWindow", UIParent, "BackdropTemplate")
LootWindow:SetSize(C.width, 100)
LootWindow:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
LootWindow:SetFrameStrata("HIGH")
LootWindow:SetToplevel(true)
LootWindow:SetMovable(true)
LootWindow:SetClampedToScreen(true)
LootWindow:EnableMouse(true)
LootWindow:RegisterForDrag("LeftButton")
LootWindow:Hide()

LootWindow:SetScript("OnDragStart", LootWindow.StartMoving)
LootWindow:SetScript("OnDragStop", LootWindow.StopMovingOrSizing)

-- :: ANIMATION SETUP :: --
LootWindow.FadeGroup = LootWindow:CreateAnimationGroup()
local fadeIn = LootWindow.FadeGroup:CreateAnimation("Alpha")
fadeIn:SetFromAlpha(0)
fadeIn:SetToAlpha(1)
fadeIn:SetDuration(0.25)
fadeIn:SetSmoothing("OUT")

LootWindow.FadeGroup:SetScript("OnPlay", function() end)
LootWindow.FadeGroup:SetScript("OnFinished", function() 
    LootWindow:SetAlpha(1) 
end)

table.insert(UISpecialFrames, "MidnightLootWindow")

-- :: HELPER FUNCTIONS :: --
local function CreateBackdrop(f)
    if not f.SetBackdrop then Mixin(f, BackdropTemplateMixin) end
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        tile = false, tileSize = 0, edgeSize = 1,
        insets = { left = 0, right = 0, top = 0, bottom = 0 }
    })
    f:SetBackdropColor(unpack(C.windowBg))
    f:SetBackdropBorderColor(0, 0, 0, 1)
end

CreateBackdrop(LootWindow)

local function SetFont(fs, size, style)
    if not fs:SetFont(C.font, size, style) then
        fs:SetFont(STANDARD_TEXT_FONT, size, style)
    end
end

local function GetReagentQualityAtlas(link)
    if not link then return nil end
    local tier = link:match("Professions%-ChatIcon%-Quality%-Tier(%d)")
    if tier then
        return "Professions-Icon-Quality-Tier"..tier.."-Small"
    end
    return nil
end

-- :: UNIFIED TOOLTIP WRAPPER :: --

-- 1. Create the Custom Tooltip (The Data Container)
local CustomTooltip = CreateFrame("GameTooltip", "MidnightLootTooltip", UIParent, "GameTooltipTemplate")
CustomTooltip.shoppingTooltips = { ShoppingTooltip1, ShoppingTooltip2 } 
CustomTooltip:SetFrameStrata("TOOLTIP")
CustomTooltip:SetClampedToScreen(true)
Mixin(CustomTooltip, BackdropTemplateMixin)

-- 2. Create the Visual Wrapper (The "One Big Window")
local TooltipWrapper = CreateFrame("Frame", nil, CustomTooltip, "BackdropTemplate")
TooltipWrapper:SetFrameStrata("TOOLTIP")
TooltipWrapper:SetFrameLevel(CustomTooltip:GetFrameLevel() - 1)
TooltipWrapper:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile = false, tileSize = 0, edgeSize = 1, 
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
    shadowFile = "Interface\\DialogFrame\\UI-DialogBox-Shadow",
    shadowSize = 16,
    shadowInsets = { left = 5, right = 5, top = 5, bottom = 5 }
})
TooltipWrapper:SetBackdropColor(unpack(C.windowBg))
TooltipWrapper:SetBackdropBorderColor(0, 0, 0, 1)

-- Wrapper Components
TooltipWrapper.HeaderStrip = TooltipWrapper:CreateTexture(nil, "ARTWORK")
TooltipWrapper.HeaderStrip:SetHeight(2)
TooltipWrapper.HeaderStrip:SetPoint("TOPLEFT", 2, -2)
TooltipWrapper.HeaderStrip:SetPoint("TOPRIGHT", -2, -2)
TooltipWrapper.HeaderStrip:SetColorTexture(0.5, 0.5, 0.5, 1)

TooltipWrapper.VerticalDivider = TooltipWrapper:CreateTexture(nil, "OVERLAY")
TooltipWrapper.VerticalDivider:SetWidth(1)
TooltipWrapper.VerticalDivider:SetColorTexture(0.25, 0.25, 0.25, 1) 
TooltipWrapper.VerticalDivider:Hide()

-- Headers
TooltipWrapper.LootLabel = TooltipWrapper:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
TooltipWrapper.LootLabel:SetText("LOOTED ITEM")
TooltipWrapper.LootLabel:SetTextColor(0.6, 0.6, 0.6)

TooltipWrapper.EquipLabel = TooltipWrapper:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
TooltipWrapper.EquipLabel:SetText("CURRENTLY EQUIPPED")
TooltipWrapper.EquipLabel:SetTextColor(0.6, 0.6, 0.6)
TooltipWrapper.EquipLabel:Hide()

-- Helper to strip borders from tooltips
local function StripTooltip(tooltip)
    if not tooltip then return end
    if not tooltip.MidnightStripped then
        Mixin(tooltip, BackdropTemplateMixin)
        tooltip.MidnightStripped = true
    end
    tooltip:SetBackdrop(nil)
    if tooltip.NineSlice then tooltip.NineSlice:Hide() end
end

-- Helper to Restore tooltips
local function RestoreTooltip(tooltip)
    if not tooltip then return end
    if tooltip.SetBackdrop then
        tooltip:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 }
        })
        tooltip:SetBackdropColor(0, 0, 0, 1)
        tooltip:SetBackdropBorderColor(1, 1, 1, 1)
    end
    if tooltip.NineSlice then tooltip.NineSlice:Show() end
end

-- :: HEADER UI :: --
-- Separator: accent color on the left fading into shadow on the right
local accent = LootWindow:CreateTexture(nil, "OVERLAY", nil, 1)
accent:SetHeight(2)
accent:SetPoint("TOPLEFT", 8, -C.headerHeight)
accent:SetPoint("TOPRIGHT", -8, -C.headerHeight)
accent:SetTexture("Interface\\Buttons\\WHITE8X8")
accent:SetGradient("HORIZONTAL",
    CreateColor(C.accent.r, C.accent.g, C.accent.b, 0.7),
    CreateColor(0.03, 0.03, 0.05, 0.1))

-- Soft shadow underneath for depth
local accentShadow = LootWindow:CreateTexture(nil, "ARTWORK")
accentShadow:SetHeight(3)
accentShadow:SetPoint("TOPLEFT", accent, "BOTTOMLEFT", 0, 0)
accentShadow:SetPoint("TOPRIGHT", accent, "BOTTOMRIGHT", 0, 0)
accentShadow:SetTexture("Interface\\Buttons\\WHITE8X8")
accentShadow:SetGradient("HORIZONTAL",
    CreateColor(0, 0, 0, 0.3),
    CreateColor(0, 0, 0, 0))

local title = LootWindow:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("LEFT", LootWindow, "TOPLEFT", 12, -(C.headerHeight / 2))
title:SetText("LOOT")
SetFont(title, 14, "OUTLINE")
title:SetTextColor(C.accent.r, C.accent.g, C.accent.b)

-- Shared button styler (matches Diagnostics / Settings panels)
local function StyleLootButton(b)
    if not b or b._styled then return end
    b._styled = true
    if b.Left then b.Left:Hide() end
    if b.Middle then b.Middle:Hide() end
    if b.Right then b.Right:Hide() end
    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(0.45, 0.45, 0.50, 0.6)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)
    local bg = b:CreateTexture(nil, "BACKGROUND", nil, 1)
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)
    local sheen = b:CreateTexture(nil, "ARTWORK")
    sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    sheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    sheen:SetPoint("TOPLEFT", 2, -2)
    sheen:SetPoint("BOTTOMRIGHT", -2, 10)
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetTexture("Interface\\Buttons\\WHITE8X8")
    hover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    hover:SetPoint("TOPLEFT", 1, -1)
    hover:SetPoint("BOTTOMRIGHT", -1, 1)
    b:SetNormalTexture("")
    b:SetHighlightTexture(hover)
    b:SetPushedTexture("")
end

local closeBtn = CreateFrame("Button", nil, LootWindow, "BackdropTemplate")
closeBtn:SetSize(22, 22)
closeBtn:SetPoint("RIGHT", LootWindow, "TOPRIGHT", -8, -(C.headerHeight / 2))
local closeBtnText = closeBtn:CreateFontString(nil, "OVERLAY")
SetFont(closeBtnText, 13, "OUTLINE")
closeBtnText:SetPoint("CENTER", 0, 0)
closeBtnText:SetText("X")
closeBtnText:SetTextColor(C.text[1], C.text[2], C.text[3])
StyleLootButton(closeBtn)
closeBtn:SetScript("OnClick", function() CloseLoot() end)

local lootAllBtn = CreateFrame("Button", nil, LootWindow, "UIPanelButtonTemplate")
lootAllBtn:SetSize(80, 22)
lootAllBtn:SetPoint("RIGHT", closeBtn, "LEFT", -5, 0)
lootAllBtn:SetText("Loot All")
StyleLootButton(lootAllBtn)

lootAllBtn:SetScript("OnClick", function()
    local num = GetNumLootItems()
    if num == 0 then return end
    local delay = 0
    for i = num, 1, -1 do
        C_Timer.After(delay, function()
            if GetLootSlotInfo(i) then LootSlot(i) end
        end)
        delay = delay + 0.15
    end
end)

local content = CreateFrame("Frame", nil, LootWindow)
content:SetPoint("TOPLEFT", C.padding, -C.headerHeight - 6)
content:SetPoint("TOPRIGHT", -C.padding, -C.headerHeight - 6)

-- :: GROUP COMPARISON WINDOW :: --

local GroupWindow = CreateFrame("Frame", "MidnightGroupWindow", UIParent, "BackdropTemplate")
GroupWindow:SetFrameStrata("TOOLTIP")
GroupWindow:SetClampedToScreen(true)
GroupWindow:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8",
    tile = false, tileSize = 0, edgeSize = 1,
    insets = { left = 2, right = 2, top = 2, bottom = 2 },
    shadowFile = "Interface\\DialogFrame\\UI-DialogBox-Shadow",
    shadowSize = 16,
    shadowInsets = { left = 5, right = 5, top = 5, bottom = 5 }
})
GroupWindow:SetBackdropColor(unpack(C.windowBg))
GroupWindow:SetBackdropBorderColor(0, 0, 0, 1)
GroupWindow:Hide()

-- Header
GroupWindow.Header = GroupWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
GroupWindow.Header:SetText("GROUP COMPARISONS")
GroupWindow.Header:SetTextColor(0.6, 0.6, 0.6)
GroupWindow.Header:SetPoint("TOPLEFT", 10, -8)

-- Helper: Scan for "Track" (Hero, Champion, etc.)
local scanner = CreateFrame("GameTooltip", "MidnightTrackScanner", nil, "GameTooltipTemplate")
scanner:SetOwner(WorldFrame, "ANCHOR_NONE")

local function GetItemTrack(link)
    if not link then return "" end
    scanner:ClearLines()
    scanner:SetHyperlink(link)
    for i = 2, scanner:NumLines() do 
        local line = _G["MidnightTrackScannerTextLeft"..i]
        if line then
            local text = line:GetText()
            if text then
                if text:find("Explorer") then return "|cffbfbfbfExplorer|r" end
                if text:find("Adventurer") then return "|cff1eff00Adventurer|r" end
                if text:find("Veteran") then return "|cff0070ddVeteran|r" end
                if text:find("Champion") then return "|cffa335eeChampion|r" end
                if text:find("Hero") then return "|cffff8000Hero|r" end
                if text:find("Myth") then return "|cffe6cc80Myth|r" end
            end
        end
    end
    return ""
end

-- Row Management
local groupRows = {}
local pendingGroupUpdates = {}

local function GetGroupRow(i)
    if not groupRows[i] then
        local row = CreateFrame("Frame", nil, GroupWindow)
        row:SetHeight(20)
        
        -- 1. Track (Far Right)
        row.track = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.track:SetPoint("RIGHT", row, "RIGHT", -10, 0)
        row.track:SetWidth(70)
        row.track:SetJustifyH("RIGHT")

        -- 2. Diff (Left of Track)
        row.diff = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.diff:SetPoint("RIGHT", row.track, "LEFT", -5, 0)
        row.diff:SetWidth(40)
        row.diff:SetJustifyH("RIGHT")

        -- 3. Name (Far Left)
        row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        row.name:SetPoint("LEFT", row, "LEFT", 10, 0)
        row.name:SetWidth(80)
        row.name:SetJustifyH("LEFT")
        
        -- 4. Gear Name (Fills the space between Name and Diff)
        row.gear = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        row.gear:SetPoint("LEFT", row.name, "RIGHT", 5, 0)
        row.gear:SetPoint("RIGHT", row.diff, "LEFT", -10, 0)
        row.gear:SetJustifyH("LEFT")
        row.gear:SetWordWrap(false) 
        
        groupRows[i] = row
    end
    return groupRows[i]
end

UpdateGroupWindow = function(lootLink)
    local wasShown = GroupWindow:IsShown()
    GroupWindow:Hide()
    if not lootLink then return end
    GroupWindow.lastLootLink = lootLink
    
    local itemName, _, _, baseILvl, _, _, itemSubType, _, lootEquipLoc, _, _, classID = GetItemInfo(lootLink)
    if (not itemName or not classID or not lootEquipLoc) then
        if not pendingGroupUpdates[lootLink] then
            pendingGroupUpdates[lootLink] = true
            local item = Item:CreateFromItemLink(lootLink)
            if item and not item:IsItemEmpty() then
                item:ContinueOnItemLoad(function()
                    pendingGroupUpdates[lootLink] = nil
                    UpdateGroupWindow(lootLink)
                end)
            else
                pendingGroupUpdates[lootLink] = nil
            end
        end
        local dbgKey = "pending:" .. SafeToStringLocal(lootLink)
        if not groupDebugCache[dbgKey] then
            groupDebugCache[dbgKey] = true
            LogGroupDebug("[GroupCompare] pending item info link=" .. SafeToStringLocal(lootLink) .. " name=" .. SafeToStringLocal(itemName) .. " classID=" .. SafeToStringLocal(classID) .. " equipLoc=" .. SafeToStringLocal(lootEquipLoc))
        end
        return
    end
    do
        local dbgKey = "start:" .. SafeToStringLocal(lootLink)
        if not groupDebugCache[dbgKey] then
            groupDebugCache[dbgKey] = true
            LogGroupDebug("[GroupCompare] start link=" .. SafeToStringLocal(lootLink) .. " name=" .. SafeToStringLocal(itemName) .. " baseILvl=" .. SafeToStringLocal(baseILvl) .. " subtype=" .. SafeToStringLocal(itemSubType) .. " equipLoc=" .. SafeToStringLocal(lootEquipLoc) .. " classID=" .. SafeToStringLocal(classID))
        end
    end
    
    -- [1] Get Accurate Item Level
    local trueILvl = GetDetailedItemLevelInfo(lootLink)
    
    -- Fallback: Scan Tooltip for "Item Level <Number>"
    if not trueILvl or trueILvl == baseILvl then
        for i = 2, 5 do 
            local line = _G["MidnightLootTooltipTextLeft"..i]
            if line then
                local text = line:GetText()
                if text and text:find("Item Level") then
                    local foundLvl = text:match("(%d+)")
                    if foundLvl then
                        local num = tonumber(foundLvl)
                        if num and baseILvl and num > baseILvl then
                            trueILvl = num
                            break
                        end
                    end
                end
            end
        end
    end
    
    trueILvl = trueILvl or baseILvl or 0

    local candidateSlots = GetCandidateSlots(lootEquipLoc)
    if not lootEquipLoc or not candidateSlots or #candidateSlots == 0 then
        LogGroupDebug("[GroupCompare] skip non-equip lootEquipLoc=" .. SafeToStringLocal(lootEquipLoc) .. " classID=" .. SafeToStringLocal(classID) .. " subtype=" .. SafeToStringLocal(itemSubType))
        return
    end
    LogGroupDebug("[GroupCompare] slot map equipLoc=" .. SafeToStringLocal(lootEquipLoc) .. " slots=" .. SafeToStringLocal(table.concat(candidateSlots, ",")) .. " trueILvl=" .. SafeToStringLocal(trueILvl))
    
    -- [2] Identify Eligible Classes
    local eligibleClasses = nil
    if classID == 2 then -- Weapon
        eligibleClasses = WEAPON_TYPES[itemSubType]
        if not eligibleClasses and itemSubType then
             local singular = itemSubType:gsub("s$", "")
             eligibleClasses = WEAPON_TYPES[singular]
        end
        if not eligibleClasses and lootEquipLoc == "INVTYPE_HOLDABLE" then
            eligibleClasses = HOLDABLE_CLASSES
        end
    elseif classID == 4 then -- Armor
        eligibleClasses = ARMOR_TYPES[itemSubType]
        if not eligibleClasses and itemSubType == "Shields" then
            eligibleClasses = WEAPON_TYPES["Shields"]
        end
    end
    if not eligibleClasses then
        LogGroupDebug("[GroupCompare] no eligible class table for subtype=" .. SafeToStringLocal(itemSubType) .. " classID=" .. SafeToStringLocal(classID))
    end

    local function IsEligible(c)
        if lootEquipLoc == "INVTYPE_CLOAK" or lootEquipLoc == "INVTYPE_FINGER" or lootEquipLoc == "INVTYPE_NECK" or lootEquipLoc == "INVTYPE_TRINKET" then
            return true
        end
        if not eligibleClasses then return false end
        return eligibleClasses[c]
    end

    local upgrades = {}
    local notCachedCount = 0

    -- [3] Scan Group Members
    if IsInGroup() then
        local members = GetNumGroupMembers()
        local prefix = IsInRaid() and "raid" or "party"
        LogGroupDebug("[GroupCompare] group scan inGroup=true raid=" .. SafeToStringLocal(IsInRaid()) .. " members=" .. SafeToStringLocal(members))
        for i = 1, members do
            local unit = IsInRaid() and "raid"..i or ("party"..i)
            if unit == "party0" then unit = "player" end 
            if not IsInRaid() and i == members then unit = "player" end 

            if UnitExists(unit) and not UnitIsUnit(unit, "player") then
                local _, classFile = UnitClass(unit)
                if IsEligible(classFile) then
                    LogGroupDebug("[GroupCompare] eligible unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)) .. " class=" .. SafeToStringLocal(classFile))
                    if not UnitIsConnected(unit) then
                        LogGroupDebug("[GroupCompare] offline unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)))
                        local cColor = GetExactClassColorTable(classFile)
                        table.insert(upgrades, {
                            name = UnitName(unit),
                            color = cColor,
                            gearName = "Offline",
                            gearColor = "ffffffff",
                            ilvl = 0,
                            diff = nil,
                            track = ""
                        })
                    else
                        local canInspect = CanInspect(unit)
                        local inRange = nil
                        local okRange, rangeVal = pcall(CheckInteractDistance, unit, 1)
                        if okRange then
                            if rangeVal == true then
                                inRange = true
                            elseif rangeVal == false then
                                inRange = false
                            end
                        end
                        if not canInspect then
                            local status = (inRange == false) and "Out of Range" or "Inspect Cooldown"
                            LogGroupDebug("[GroupCompare] " .. status .. " unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)))
                            for _, slot in ipairs(candidateSlots) do
                                MaybeSendAddonRequest(unit, slot, "inspect_blocked")
                            end
                            local cColor = GetExactClassColorTable(classFile)
                            table.insert(upgrades, {
                                name = UnitName(unit),
                                color = cColor,
                                gearName = status,
                                gearColor = "ffffffff",
                                ilvl = 0,
                                diff = nil,
                                track = ""
                            })
                        else
                            local link, selectedSlot, source, selectedILvl, anyCacheMiss, anyNoCache = GetBestEquippedLink(unit, candidateSlots)
                            do
                                local dbgKey = "cache:" .. SafeToStringLocal(lootLink) .. ":" .. SafeToStringLocal(unit) .. ":" .. SafeToStringLocal(table.concat(candidateSlots, ","))
                                if not groupDebugCache[dbgKey] then
                                    groupDebugCache[dbgKey] = true
                                    LogGroupDebug("[GroupCompare] cache state=" .. SafeToStringLocal(source) .. " unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)) .. " slot=" .. SafeToStringLocal(selectedSlot) .. " link=" .. SafeToStringLocal(link))
                                end
                            end
                            if link then
                                local iName, _, iQuality, iLvl = GetItemInfo(link)
                                local realEquippedILvl = selectedILvl or GetDetailedItemLevelInfo(link) or iLvl or 0
                                local diff = (realEquippedILvl and realEquippedILvl > 0) and ((trueILvl or 0) - realEquippedILvl) or nil
                                local cColor = GetExactClassColorTable(classFile)
                                local _, _, _, hex = GetItemQualityColor(iQuality or 1)
                                LogGroupDebug("[GroupCompare] gear link=" .. SafeToStringLocal(link) .. " gearName=" .. SafeToStringLocal(iName) .. " ilvl=" .. SafeToStringLocal(realEquippedILvl) .. " diff=" .. SafeToStringLocal(diff) .. " slot=" .. SafeToStringLocal(selectedSlot))
                                
                                table.insert(upgrades, {
                                    name = UnitName(unit),
                                    color = cColor,
                                    gearName = iName or "Unknown",
                                    gearColor = hex or "ffffffff",
                                    ilvl = realEquippedILvl or 0,
                                    diff = diff,
                                    track = GetItemTrack(link) 
                                })
                            else
                                LogGroupDebug("[GroupCompare] gear link missing unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)) .. " slot=" .. SafeToStringLocal(selectedSlot))
                                if IsInRaid() then
                                    notCachedCount = notCachedCount + 1
                                    local cColor = GetExactClassColorTable(classFile)
                                    table.insert(upgrades, {
                                        name = UnitName(unit),
                                        color = cColor,
                                        gearName = "MidnightUI Not Installed",
                                        gearColor = "ffffffff",
                                        ilvl = 0,
                                        diff = nil,
                                        track = ""
                                    })
                                else
                                    local status = "Not Cached"
                                    local key = SafeToStringLocal(lootLink) .. ":" .. unit .. ":" .. SafeToStringLocal(table.concat(candidateSlots, ","))
                                    local now = GetTime()
                                    local graceUntil = inspectGrace[unit] or 0
                                    local cooldownRemaining = GetInspectCooldownRemaining(unit)
                                    if inRange == false then
                                        status = "Out of Range"
                                    else
                                        local addonWaitActive = false
                                        if anyNoCache or anyCacheMiss then
                                            for _, slot in ipairs(candidateSlots) do
                                                MaybeSendAddonRequest(unit, slot, anyCacheMiss and "cache_miss" or "no_cache")
                                            end
                                            local unitKey = GetUnitCacheKey(unit)
                                            local waitKey = SafeToStringLocal(unitKey) .. ":" .. SafeToStringLocal(table.concat(candidateSlots, ","))
                                            local waitUntil = addonWaitUntil[waitKey] or 0
                                            if now < waitUntil then
                                                addonWaitActive = true
                                            else
                                                addonWaitUntil[waitKey] = now + ADDON_WAIT_GRACE
                                                LogGroupDebug("[GroupCompare] addon wait schedule unit=" .. SafeToStringLocal(unit) .. " until=" .. SafeToStringLocal(addonWaitUntil[waitKey]))
                                                C_Timer.After(ADDON_WAIT_GRACE, function()
                                                    if GroupWindow and GroupWindow:IsShown() and GroupWindow.lastLootLink then
                                                        LogGroupDebug("[GroupCompare] addon wait refresh unit=" .. SafeToStringLocal(unit))
                                                        UpdateGroupWindow(GroupWindow.lastLootLink)
                                                    end
                                                end)
                                                addonWaitActive = true
                                            end
                                        end
                                        if addonWaitActive then
                                            status = "Waiting for Addon"
                                        elseif now < graceUntil then
                                            status = "Inspecting..."
                                        elseif cooldownRemaining > 0 then
                                            status = "Inspect Cooldown"
                                            if not pendingInspect[key] then
                                                LogGroupDebug("[GroupCompare] inspect cooldown schedule unit=" .. SafeToStringLocal(unit) .. " remaining=" .. SafeToStringLocal(cooldownRemaining))
                                                QueueInspectRetry(key, unit, lootLink, math.max(cooldownRemaining + 0.1, INSPECT_RETRY_BASE))
                                            end
                                        elseif not pendingInspect[key] then
                                            local ok = RequestInspect(unit)
                                            if ok then
                                                pendingInspect[key] = true
                                                pendingInspectTries[key] = 1
                                                status = "Inspecting..."
                                                QueueInspectRetry(key, unit, lootLink, INSPECT_RETRY_BASE)
                                            else
                                                status = "Inspect Cooldown"
                                                QueueInspectRetry(key, unit, lootLink, INSPECT_RETRY_BASE)
                                            end
                                        end
                                    end
                                    LogGroupDebug("[GroupCompare] status unit=" .. SafeToStringLocal(unit) .. " slots=" .. SafeToStringLocal(table.concat(candidateSlots, ",")) .. " status=" .. SafeToStringLocal(status) .. " graceUntil=" .. SafeToStringLocal(graceUntil) .. " canInspect=" .. SafeToStringLocal(canInspect) .. " inRange=" .. SafeToStringLocal(inRange) .. " pending=" .. SafeToStringLocal(pendingInspect[key]) .. " tries=" .. SafeToStringLocal(pendingInspectTries[key]))
                                    if inRange ~= false and graceUntil > now and not inspectGraceTimers[unit] then
                                        local delay = math.max(0.1, graceUntil - now + 0.1)
                                        inspectGraceTimers[unit] = true
                                        C_Timer.After(delay, function()
                                            inspectGraceTimers[unit] = nil
                                            if GroupWindow and GroupWindow:IsShown() and GroupWindow.lastLootLink then
                                                LogGroupDebug("[GroupCompare] grace refresh unit=" .. SafeToStringLocal(unit))
                                                UpdateGroupWindow(GroupWindow.lastLootLink)
                                            else
                                                LogGroupDebug("[GroupCompare] grace refresh skipped unit=" .. SafeToStringLocal(unit) .. " shown=" .. SafeToStringLocal(GroupWindow and GroupWindow:IsShown()) .. " link=" .. SafeToStringLocal(GroupWindow and GroupWindow.lastLootLink))
                                            end
                                        end)
                                    end
                                    local cColor = GetExactClassColorTable(classFile)
                                    table.insert(upgrades, {
                                        name = UnitName(unit),
                                        color = cColor,
                                        gearName = status,
                                        gearColor = "ffffffff",
                                        ilvl = 0,
                                        diff = nil,
                                        track = ""
                                    })
                                end
                            end
                        end
                    end
                else
                    LogGroupDebug("[GroupCompare] ineligible unit=" .. SafeToStringLocal(unit) .. " name=" .. SafeToStringLocal(UnitName(unit)) .. " class=" .. SafeToStringLocal(classFile))
                end
            elseif UnitIsUnit(unit, "player") then
                LogGroupDebug("[GroupCompare] skip player unit=" .. SafeToStringLocal(unit))
            elseif not UnitExists(unit) then
                LogGroupDebug("[GroupCompare] missing unit=" .. SafeToStringLocal(unit))
            end
        end
    else
        LogGroupDebug("[GroupCompare] group scan inGroup=false")
    end

    -- [4] Build UI
    if not GroupWindow.EmptyMessage then
        GroupWindow.EmptyMessage = GroupWindow:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        GroupWindow.EmptyMessage:SetPoint("CENTER", 0, -10)
        GroupWindow.EmptyMessage:SetText("No Eligible Members")
        GroupWindow.EmptyMessage:SetTextColor(0.5, 0.5, 0.5)
    end

    if #upgrades > 0 then
        LogGroupDebug("[GroupCompare] build rows count=" .. SafeToStringLocal(#upgrades))
        GroupWindow.EmptyMessage:Hide()
        for i, row in ipairs(groupRows) do row:Hide() end
        
        local yOffset = -35 
        
        for i, data in ipairs(upgrades) do
            local row = GetGroupRow(i)
            row:Show()
            row:SetPoint("TOPLEFT", 10, yOffset)
            row:SetPoint("RIGHT", -10, 0) 
            
            row.name:SetText(data.name)
            row.name:SetTextColor(data.color.r, data.color.g, data.color.b)
            
            if data.gearName == "Out of Range" or data.gearName == "Offline" or data.gearName == "Inspect Cooldown" or data.gearName == "Not Cached" or data.gearName == "Inspecting..." or data.gearName == "Waiting for Addon" or data.gearName == "MidnightUI Not Installed" then
                row.gear:SetText(data.gearName)
                row.gear:SetPoint("LEFT", row.name, "RIGHT", 40, 0)
                row.gear:SetTextColor(0.8, 0.8, 0.8)
            else
                row.gear:SetText(string.format("%s (%d)", data.gearName, data.ilvl))
                row.gear:SetPoint("LEFT", row.name, "RIGHT", 5, 0)
                row.gear:SetTextColor(
                     tonumber("0x" .. string.sub(data.gearColor, 3, 4)) / 255,
                     tonumber("0x" .. string.sub(data.gearColor, 5, 6)) / 255,
                     tonumber("0x" .. string.sub(data.gearColor, 7, 8)) / 255
                )
            end
            
            if data.gearName == "Out of Range" or data.gearName == "Offline" or data.gearName == "Inspect Cooldown" or data.gearName == "Not Cached" or data.gearName == "Inspecting..." or data.gearName == "Waiting for Addon" or data.gearName == "MidnightUI Not Installed" then
                row.track:SetText("")
            else
                row.track:SetText(data.track)
            end
            
            local diffText = ""
            if data.gearName == "Out of Range" or data.gearName == "Offline" or data.gearName == "Inspect Cooldown" or data.gearName == "Not Cached" or data.gearName == "Inspecting..." or data.gearName == "Waiting for Addon" or data.gearName == "MidnightUI Not Installed" then
                diffText = ""
            elseif data.diff == nil then
                diffText = "|cffaaaaaa?|r"
            elseif data.diff > 0 then
                diffText = "|cff40ff40+"..data.diff.."|r"
            elseif data.diff < 0 then
                diffText = "|cffff4040"..data.diff.."|r"
            else
                diffText = "|cffffd1000|r"
            end
            row.diff:SetText(diffText)
            
            yOffset = yOffset - 20
        end
        
        GroupWindow:SetHeight(math.abs(yOffset) + 10)
    else
        LogGroupDebug("[GroupCompare] no upgrades found (empty list)")
        for i, row in ipairs(groupRows) do row:Hide() end
        if IsInRaid() and notCachedCount > 0 then
            GroupWindow.EmptyMessage:SetText("Inspect data unavailable in raid. Target a player to compare.")
        else
            GroupWindow.EmptyMessage:SetText("No Eligible Members")
        end
        GroupWindow.EmptyMessage:Show()
        GroupWindow:SetHeight(60) 
    end

    if TooltipWrapper.activeR then
        GroupWindow:SetBackdropBorderColor(TooltipWrapper.activeR, TooltipWrapper.activeG, TooltipWrapper.activeB, 1)
        GroupWindow:SetBackdropColor(TooltipWrapper.activeR * 0.1, TooltipWrapper.activeG * 0.1, TooltipWrapper.activeB * 0.1, 0.95)
    else
        GroupWindow:SetBackdropBorderColor(0, 0, 0, 1)
        GroupWindow:SetBackdropColor(unpack(C.windowBg))
    end
    
    if not wasShown then
        LogGroupDebug("[GroupCompare] show link=" .. SafeToStringLocal(lootLink) .. " upgrades=" .. SafeToStringLocal(#upgrades) .. " notCached=" .. SafeToStringLocal(notCachedCount))
    end
    GroupWindow:Show()
end

-- :: ROW LOGIC :: --

local function OnRowClick(self, button)
    if not self.index then return end
    if IsModifiedClick("CHATLINK") then
        local link = GetLootSlotLink(self.index)
        if link then ChatEdit_InsertLink(link) end
        return
    end
    if button == "RightButton" and IsMasterLooter() then
        if GroupLootDropDown then
            UIDropDownMenu_Initialize(GroupLootDropDown, GroupLootDropDown_Initialize)
            ToggleDropDownMenu(1, nil, GroupLootDropDown, self, 0, 0)
        end
        return
    end
    LootSlot(self.index)
end

local function OnRowEnter(self)
    if self.rarityColor then
        local r, g, b = unpack(self.rarityColor)
        self.bg:SetColorTexture(r, g, b, 0.3)
    else
        self.bg:SetColorTexture(unpack(C.rowHover))
    end
    
    local tooltip = MidnightLootTooltip
    tooltip:ClearLines()
    tooltip:SetOwner(self, "ANCHOR_RIGHT", 40, 0)
    
    if self.index and GetLootSlotInfo(self.index) then
        local link = GetLootSlotLink(self.index)
        
        if not link then
            self.bg:SetColorTexture(unpack(C.rowBg))
            ResetCursor()
            return
        end
        
        StripTooltip(tooltip)
        tooltip:SetLootItem(self.index)
        do
            local dbgKey = "hover:" .. SafeToStringLocal(self.index) .. ":" .. SafeToStringLocal(link)
            if not lootDebugCache[dbgKey] then
                lootDebugCache[dbgKey] = true
                DebugLog("LootHover index=" .. SafeToStringLocal(self.index) .. " link=" .. SafeToStringLocal(link))
            end
        end
        
        local _, _, quality = GetItemInfo(link)
        if quality then
            local r, g, b = GetItemQualityColor(quality)
            TooltipWrapper:SetBackdropColor(r * 0.1, g * 0.1, b * 0.1, 0.95)
            TooltipWrapper:SetBackdropBorderColor(r, g, b, 1)
            TooltipWrapper.activeR = r
            TooltipWrapper.activeG = g
            TooltipWrapper.activeB = b
        else
            TooltipWrapper:SetBackdropColor(unpack(C.windowBg))
            TooltipWrapper:SetBackdropBorderColor(0, 0, 0, 1)
            TooltipWrapper.activeR = 0.5
            TooltipWrapper.activeG = 0.5
            TooltipWrapper.activeB = 0.5
        end

        TooltipWrapper.HeaderStrip:Hide()
        tooltip:Show()
        GameTooltip_ShowCompareItem(tooltip)

        local shopping = _G["ShoppingTooltip1"]
        local padding = 25 
        local headerHeight = 30 
        
        TooltipWrapper.LootLabel:ClearAllPoints()
        TooltipWrapper.EquipLabel:ClearAllPoints()
        
        if shopping and shopping:IsShown() then
            StripTooltip(shopping) 
            if shopping.CompareHeader then shopping.CompareHeader:Hide() end
            
            shopping:ClearAllPoints()
            shopping:SetPoint("TOPLEFT", tooltip, "TOPRIGHT", padding, 0)
            
            TooltipWrapper.VerticalDivider:ClearAllPoints()
            TooltipWrapper.VerticalDivider:SetPoint("TOPLEFT", tooltip, "TOPRIGHT", padding/2, headerHeight - 10) 
            TooltipWrapper.VerticalDivider:SetPoint("BOTTOMLEFT", tooltip, "BOTTOMRIGHT", padding/2, 0)
            TooltipWrapper.VerticalDivider:SetColorTexture(TooltipWrapper.activeR, TooltipWrapper.activeG, TooltipWrapper.activeB, 0.5)
            TooltipWrapper.VerticalDivider:Show()
            
            TooltipWrapper.LootLabel:SetPoint("TOPLEFT", TooltipWrapper, "TOPLEFT", 10, -8)
            TooltipWrapper.EquipLabel:SetPoint("TOPLEFT", shopping, "TOPLEFT", 0, headerHeight - 8)
            TooltipWrapper.EquipLabel:Show()
            
            local width1, height1 = tooltip:GetSize()
            local width2, height2 = shopping:GetSize()
            local maxHeight = math.max(height1, height2)
            
            TooltipWrapper:ClearAllPoints()
            TooltipWrapper:SetPoint("TOPLEFT", tooltip, "TOPLEFT", -6, headerHeight) 
            TooltipWrapper:SetWidth(width1 + width2 + padding + 12)
            TooltipWrapper:SetHeight(maxHeight + headerHeight + 6) 
            TooltipWrapper:Show()
        else
            TooltipWrapper.VerticalDivider:Hide()
            TooltipWrapper.EquipLabel:Hide()
            
            TooltipWrapper.LootLabel:SetPoint("TOPLEFT", TooltipWrapper, "TOPLEFT", 10, -8)

            TooltipWrapper:ClearAllPoints()
            TooltipWrapper:SetPoint("TOPLEFT", tooltip, "TOPLEFT", -6, headerHeight)
            TooltipWrapper:SetPoint("BOTTOMRIGHT", tooltip, "BOTTOMRIGHT", 6, -6)
            TooltipWrapper:Show()
        end
        
        do
            local dbgKey = "hover_compare:" .. SafeToStringLocal(self.index) .. ":" .. SafeToStringLocal(link)
            if not lootDebugCache[dbgKey] then
                lootDebugCache[dbgKey] = true
                DebugLog("GroupCompare update from hover index=" .. SafeToStringLocal(self.index) .. " link=" .. SafeToStringLocal(link))
            end
        end
        UpdateGroupWindow(link)
        
        if GroupWindow:IsShown() then
            GroupWindow:ClearAllPoints()
            GroupWindow:SetPoint("TOPLEFT", TooltipWrapper, "BOTTOMLEFT", 0, -6)
            GroupWindow:SetWidth(TooltipWrapper:GetWidth())
        end
        
        CursorUpdate(self)
    end
end

local function OnRowLeave(self)
    self.bg:SetColorTexture(unpack(C.rowBg))
    
    MidnightLootTooltip:Hide()
    TooltipWrapper:Hide()
    
    if ShoppingTooltip1 then 
        ShoppingTooltip1:Hide() 
        RestoreTooltip(ShoppingTooltip1)
    end

    MidnightGroupWindow:Hide()
    ResetCursor()
end

local function CreateRow(parent, i)
    local row = CreateFrame("Button", nil, parent)
    row:SetHeight(C.rowHeight)
    row:SetWidth(C.width - (C.padding * 2))
    row:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    row.bg = row:CreateTexture(nil, "BACKGROUND")
    row.bg:SetAllPoints()
    row.bg:SetColorTexture(unpack(C.rowBg))

    row.iconBorder = row:CreateTexture(nil, "BORDER")
    row.iconBorder:SetSize(C.iconSize + 2, C.iconSize + 2)
    row.iconBorder:SetColorTexture(0,0,0,1) 

    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(C.iconSize, C.iconSize)
    row.icon:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    
    row.iconBorder:SetPoint("CENTER", row.icon, "CENTER")

    row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    SetFont(row.name, 13, "")
    row.name:SetPoint("TOPLEFT", row.icon, "TOPRIGHT", 10, -4)
    row.name:SetPoint("RIGHT", row, "RIGHT", -100, 0)
    row.name:SetJustifyH("LEFT")

    row.info = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetFont(row.info, 10, "")
    row.info:SetPoint("BOTTOMLEFT", row.icon, "BOTTOMRIGHT", 10, 4)
    row.info:SetTextColor(unpack(C.subText))

    row.count = row:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    row.count:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -1, 1)

    row.extra = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    SetFont(row.extra, 10, "")
    row.extra:SetPoint("RIGHT", row, "RIGHT", -10, -5)
    row.extra:SetJustifyH("RIGHT")

    row.sellLabel = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    SetFont(row.sellLabel, 9, "")
    row.sellLabel:SetPoint("BOTTOMRIGHT", row.extra, "TOPRIGHT", 0, 2)
    row.sellLabel:SetText("Sale Amount:")
    row.sellLabel:SetTextColor(0.6, 0.6, 0.6)
    row.sellLabel:Hide()

    row.tierIcon = row:CreateTexture(nil, "OVERLAY")
    row.tierIcon:SetSize(20, 20)
    row.tierIcon:SetPoint("RIGHT", row.extra, "LEFT", -12, 0)

    row:SetScript("OnClick", OnRowClick)
    row:SetScript("OnEnter", OnRowEnter)
    row:SetScript("OnLeave", OnRowLeave)

    return row
end

-- :: DATA POPULATION :: --

local function UpdateRowVisuals(row, data)
    row.index = data.index
    row.icon:SetTexture(data.texture)
    
    if data.quantity > 1 then
        row.count:SetText(data.quantity)
    else
        row.count:SetText("")
    end

    local r, g, b = GetItemQualityColor(data.quality)
    row.name:SetText(data.name)
    row.name:SetTextColor(r, g, b)
    
    row.iconBorder:SetColorTexture(r, g, b, 1)
    row.bg:SetColorTexture(unpack(C.rowBg))

    if data.quality and data.quality > 1 then
        row.rarityColor = {r, g, b} 
    else
        row.rarityColor = nil
    end

    local tierAtlas = nil
    if data.link then
        tierAtlas = GetReagentQualityAtlas(data.link)
    end
    
    if tierAtlas then
        row.tierIcon:SetAtlas(tierAtlas)
        row.tierIcon:Show()
    else
        row.tierIcon:Hide()
    end

    row.sellLabel:Hide()

    if data.isMoney then
        row.info:SetText("Coins")
        row.extra:SetText("")
    elseif data.isCurrency then
        row.info:SetText("Currency")
        row.extra:SetText("")
    else
        row.info:SetText(data.typeStr or "")
        
        if data.sellPrice and data.sellPrice > 0 then
            local totalPrice = data.sellPrice * data.quantity
            row.extra:SetText(GetCoinTextureString(totalPrice))
            
            if data.isGear then 
                row.sellLabel:Show()
            end
        else
            row.extra:SetText("")
        end
    end
end

local function RefreshLoot()
    local numItems = GetNumLootItems()
    
    if numItems == 0 then
        LootWindow:Hide()
        CloseLoot() 
        return
    end

    local totalHeight = (math.max(numItems, 1) * (C.rowHeight + 2))
    content:SetHeight(totalHeight)
    LootWindow:SetHeight(C.headerHeight + totalHeight + (C.padding * 2))

    for i = 1, numItems do
        if not activeRows[i] then
            activeRows[i] = CreateRow(content, i)
        end
        local row = activeRows[i]
        row:ClearAllPoints()
        if i == 1 then
            row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
        else
            row:SetPoint("TOPLEFT", activeRows[i-1], "BOTTOMLEFT", 0, -2)
        end

        local texture, name, quantity, currencyID, quality = GetLootSlotInfo(i)
        
        if not texture then
            row:Hide()
        else
            row:Show()
            local link = GetLootSlotLink(i)
            local slotType = GetLootSlotType(i)

            local data = {
                index = i,
                texture = texture,
                name = name or "",
                quantity = quantity or 1,
                quality = quality or 1,
                link = link,
                isMoney = (slotType == LOOT_SLOT_MONEY),
                isCurrency = (slotType == LOOT_SLOT_CURRENCY),
                typeStr = "",
                sellPrice = 0,
                isGear = false
            }

            if data.link then
                local item = Item:CreateFromItemLink(data.link)
                if not item:IsItemEmpty() then
                    item:ContinueOnItemLoad(function()
                        local iName, _, iQuality, _, _, iType, iSubType, _, iEquipLoc, _, iPrice = GetItemInfo(data.link)
                        data.name = iName or data.name
                        data.quality = iQuality or data.quality
                        
                        local parts = {}
                        if iType and iType ~= "" then table.insert(parts, iType) end
                        if iSubType and iSubType ~= "" then table.insert(parts, iSubType) end

                        local slotName = iEquipLoc and _G[iEquipLoc]
                        if slotName and slotName ~= "" then
                            table.insert(parts, slotName)
                            data.isGear = true
                        else
                            data.isGear = false
                        end

                        data.typeStr = table.concat(parts, " - ")

                        data.sellPrice = iPrice or 0
                        
                        if row:IsVisible() and row.index == i then
                            UpdateRowVisuals(row, data)
                        end
                    end)
                end
            elseif data.isMoney then
                data.name = name:gsub("\n", " ")
            end
            UpdateRowVisuals(row, data)
        end
    end

    for i = numItems + 1, #activeRows do
        activeRows[i]:Hide()
    end
end

-- :: EVENT HANDLER :: --
local EventHandler = CreateFrame("Frame")
EventHandler:RegisterEvent("LOOT_OPENED")
EventHandler:RegisterEvent("LOOT_SLOT_CLEARED")
EventHandler:RegisterEvent("LOOT_CLOSED")
EventHandler:RegisterEvent("OPEN_MASTER_LOOT_LIST")
EventHandler:RegisterEvent("UPDATE_MASTER_LOOT_LIST")
EventHandler:RegisterEvent("PLAYER_ENTERING_WORLD")
EventHandler:RegisterEvent("GROUP_ROSTER_UPDATE")
EventHandler:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
EventHandler:RegisterEvent("ADDON_LOADED")
EventHandler:RegisterEvent("CHAT_MSG_ADDON")
EventHandler:RegisterEvent("ENCOUNTER_END")
EventHandler:RegisterEvent("INSPECT_READY")

EventHandler:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local name = ...
        if name == "MidnightUI" and C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
            C_ChatInfo.RegisterAddonMessagePrefix(COMM_PREFIX)
        end
    elseif event == "CHAT_MSG_ADDON" then
        local prefix, msg, channel, sender = ...
        if prefix ~= COMM_PREFIX or not msg then return end
        local cmd, guid, slot, payload = strsplit("|", msg)
        if cmd == "REQ" then
            if guid and GetUnitKey("player") == guid then
                local slotNum = tonumber(slot)
                if slotNum then
                    LogGroupDebug("[GroupCompare] addon recv REQ from=" .. SafeToStringLocal(sender) .. " guid=" .. SafeToStringLocal(guid) .. " slot=" .. SafeToStringLocal(slotNum))
                    SendGearResponse(slotNum)
                end
            end
        elseif cmd == "RES" then
            local slotNum = tonumber(slot)
            if guid and slotNum then
                LogGroupDebug("[GroupCompare] addon recv RES from=" .. SafeToStringLocal(sender) .. " guid=" .. SafeToStringLocal(guid) .. " slot=" .. SafeToStringLocal(slotNum) .. " payload=" .. SafeToStringLocal(payload))
                gearCommCache[guid] = gearCommCache[guid] or {}
                if payload and payload ~= "NONE" then
                    gearCommCache[guid][slotNum] = payload
                else
                    gearCommCache[guid][slotNum] = false
                end
                if GroupWindow and GroupWindow:IsShown() and GroupWindow.lastLootLink then
                    UpdateGroupWindow(GroupWindow.lastLootLink)
                end
            end
        end
    elseif event == "ENCOUNTER_END" then
        local _, _, _, _, success = ...
        if success == 1 and IsInRaid() then
            BroadcastRaidGearCache()
        end
    elseif event == "GROUP_ROSTER_UPDATE" then
        BroadcastGroupGearCache("roster_update")
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        local slot = ...
        if slot then
            LogGroupDebug("[GroupCompare] addon cache slot change slot=" .. SafeToStringLocal(slot))
            SendGearResponse(slot)
        end
    elseif event == "INSPECT_READY" then
        local guid = ...
        local unit = FindUnitByGuid(guid)
        LogGroupDebug("[GroupCompare] inspect ready guid=" .. SafeToStringLocal(guid) .. " unit=" .. SafeToStringLocal(unit))
        if unit and not UnitIsUnit(unit, "player") then
            CacheInspectGear(unit, guid)
            C_Timer.After(0.2, function() CacheInspectGear(unit, guid) end)
            C_Timer.After(0.6, function() CacheInspectGear(unit, guid) end)
            for key in pairs(pendingInspect) do
                if type(key) == "string" and key:find(":" .. unit .. ":", 1, true) then
                    pendingInspect[key] = nil
                    pendingInspectTries[key] = nil
                end
            end
        end
        if GroupWindow and GroupWindow:IsShown() and GroupWindow.lastLootLink then
            UpdateGroupWindow(GroupWindow.lastLootLink)
        end
        if ClearInspectPlayer then
            pcall(ClearInspectPlayer)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        LootFrame:UnregisterEvent("LOOT_OPENED")
        LootFrame:UnregisterEvent("LOOT_CLOSED")
        BroadcastGroupGearCache("enter_world")
    elseif event == "LOOT_OPENED" then
        if LootFrame:IsShown() then LootFrame:Hide() end
        
        LootWindow:Show()
        LootWindow:SetAlpha(0)
        LootWindow.FadeGroup:Play()
        
        DebugLog("LootWindow opened items=" .. SafeToStringLocal(GetNumLootItems()))
        RefreshLoot()
    elseif event == "LOOT_SLOT_CLEARED" then
        if LootWindow:IsShown() then 
            RefreshLoot() 
        end
    elseif event == "LOOT_CLOSED" then
        LootWindow:Hide()
        StaticPopup_Hide("LOOT_BIND")
        DebugLog("LootWindow closed")
    end
end)
