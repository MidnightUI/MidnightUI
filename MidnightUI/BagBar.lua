-- =============================================================================
-- FILE PURPOSE:     Full bag window replacement. Renders all character bag slots in a
--                   single consolidated grid window (or per-bag separate windows).
--                   Supports smart inventory sorting, quality-color borders, item search/
--                   filter, cooldown overlays, item-count badges, and a drag dock for
--                   repositioning. Integrates with open merchant/AH/bank events to
--                   auto-open/close the bag window.
-- LOAD ORDER:       Loads after ConsumableBars.lua, before InterfaceMenu.lua. MidnightBags handles PLAYER_LOGIN
--                   to build the initial window; bag refresh events are coalesced via
--                   BAG_UPDATE_DELAYED to reduce per-update work.
-- DEFINES:          MidnightBags (Frame, "MidnightBags"), itemFrames[] (slot widgets),
--                   separateBagWindows[] (per-bag windows when enabled).
--                   Global refresh: MidnightUI_ApplyInventorySettings().
-- READS:            MidnightUISettings.Inventory.{enabled, dockScale, bagSlotSize,
--                   bagColumns, bagSpacing, separateBags, consolidatedColumns, position}.
-- WRITES:           MidnightUISettings.Inventory.position (on drag stop).
-- DEPENDS ON:       C_Container.GetContainerItemInfo (item data per slot).
--                   MidnightUI_Core.GetClassColorTable (class-color accent in bag chrome).
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes inventory settings controls).
-- KEY FLOWS:
--   PLAYER_LOGIN → BuildBagWindow() → creates consolidated slot grid
--   BAG_UPDATE_DELAYED → bagRefreshTimerActive guard → RefreshBagSlots() (debounced)
--   Slot click → UseContainerItem / PickupContainerItem (secure action, no SecureFrame needed)
--   Smart sort: SmartInventorySort() — multi-pass iterative sort with SMART_SORT_STEP_DELAY
--   Filter: activeFilter key → hides/shows slots by item type category
--   MERCHANT_SHOW → open bag; MERCHANT_CLOSED → close (OPEN_BAG_EVENTS / CLOSE_BAG_EVENTS)
-- GOTCHAS:
--   All protected bag show/hide/point operations must be deferred out of combat.
--   pendingInventoryStateApply / pendingBagVisibility flags queue these for post-combat.
--   Smart sort uses C_Container.SortBags() as a first pass, then a custom iterative
--   swap algorithm (SMART_SORT_MAX_PASSES=3) for category grouping.
--   BAG_REFRESH_THROTTLE (0.05s): rapid BAG_UPDATE events are collapsed into one refresh.
--   Slot buttons cache _muiLastItemID/_muiLastCount so unchanged slots skip texture work.
--   GetColumns() vs GetConsolidatedColumns(): consolidated mode (all bags in one window)
--   defaults to 16 cols vs 12 for separate-bag mode to keep the window short and wide.
-- NAVIGATION:
--   C{}                        — visual config: colors, font, slot size (line ~43)
--   OPEN_BAG_EVENTS / CLOSE_BAG_EVENTS — auto-open trigger events (line ~129)
--   GetBagSettings()           — safe accessor for MidnightUISettings.Inventory
--   BuildBagWindow()           — constructs the consolidated slot grid
--   RefreshBagSlots()          — per-slot data refresh (texture, count, quality border)
--   SmartInventorySort()       — custom iterative sort algorithm
--   EnsureBagSettings()        — initializes subtable with defaults
-- =============================================================================

local addonName, ns = ...

local _G = _G
local C_Container = C_Container
local C_Timer = C_Timer
local ClearOverrideBindings = ClearOverrideBindings
local CooldownFrame_Set = CooldownFrame_Set
local CreateFrame = CreateFrame
local GameTooltip = GameTooltip
local GetInventoryItemTexture = GetInventoryItemTexture
local GetItemInfo = GetItemInfo
local GetItemQualityColor = GetItemQualityColor
local GetTime = GetTime
local GetTimePreciseSec = GetTimePreciseSec
local InCombatLockdown = InCombatLockdown
local IsModifiedClick = IsModifiedClick
local SetOverrideBindingClick = SetOverrideBindingClick
local UIParent = UIParent
local ipairs = ipairs
local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local pairs = pairs
local select = select
local table_concat = table.concat
local table_sort = table.sort
local tonumber = tonumber
local tostring = tostring
local type = type
local unpack = unpack

-- =========================================================================
--  MIDNIGHT UI: BAG BAR (Native Secure Implementation)
-- =========================================================================

-- :: CONFIGURATION :: --
local C = {
    font = "Fonts\\FRIZQT__.TTF",
    windowBg = {0.03, 0.03, 0.05, 0.90}, 
    slotEmpty = {1, 1, 1, 0.05}, 
    classColor = (_G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable and _G.MidnightUI_Core.GetClassColorTable("player"))
        or C_ClassColor.GetClassColor(select(2, UnitClass("player"))),
    slotSize = 40,
    spacing = 6,
    cols = 12,
}

-- Get settings from MidnightUISettings
local function GetBagSettings()
    if _G.MidnightUISettings and _G.MidnightUISettings.Inventory then
        return _G.MidnightUISettings.Inventory
    end
    return {}
end

local function EnsureBagSettings()
    if not _G.MidnightUISettings then _G.MidnightUISettings = {} end
    if not _G.MidnightUISettings.Inventory then _G.MidnightUISettings.Inventory = {} end
    if _G.MidnightUISettings.Inventory.dockScale == nil then
        _G.MidnightUISettings.Inventory.dockScale = 100
    end
    return _G.MidnightUISettings.Inventory
end

local function IsInventoryEnabled()
    return GetBagSettings().enabled ~= false
end

-- Get slot size from settings
local function GetSlotSize()
    local settings = GetBagSettings()
    return settings.bagSlotSize or 40
end

-- Get columns from settings
local function GetColumns()
    local settings = GetBagSettings()
    return settings.bagColumns or 12
end

-- Get columns for consolidated bag (uses more columns to be wider/shorter)
local function GetConsolidatedColumns()
    local settings = GetBagSettings()
    -- If user has set consolidated columns, use that
    if settings.consolidatedColumns then
        return settings.consolidatedColumns
    end
    -- Otherwise auto-calculate: use more columns for consolidated to make it wider
    -- Default to 16 columns for consolidated (vs 12 for separate)
    return 16
end

-- Get spacing from settings
local function GetSpacing()
    local settings = GetBagSettings()
    return settings.bagSpacing or 6
end

-- :: STATE :: --
local activeFilter = nil 
local footerButtons = {}
local itemFrames = {} 
local hasLoaded = false
local overflowMenu = nil
local overflowButton = nil
local separateBagWindows = {} -- Stores individual bag windows when separateBags is enabled
local separateLayoutColsOverride = nil
local dockFrameRef = nil
local pendingInventoryStateApply = false
local pendingInventorySort = false
local pendingBagRefresh = false
local pendingBagVisibility = nil
local smartInventoryArrangeEnabled = false
local smartSortOpQueue = nil
local smartSortRunning = false
local smartSortPass = 0
local lastBroomSortStateHash = nil
local bagRefreshTimerActive = false
local BAG_REFRESH_THROTTLE = 0.05
local SMART_SORT_STEP_DELAY = 0.08
local SMART_SORT_LOCK_RETRY_DELAY = 0.15
local SMART_SORT_MAX_PASSES = 3
local OPEN_BAG_EVENTS = {"MERCHANT_SHOW", "AUCTION_HOUSE_SHOW", "MAIL_SHOW", "BANKFRAME_OPENED", "TRADE_SHOW", "GUILDBANKFRAME_OPENED"}
local CLOSE_BAG_EVENTS = {"MERCHANT_CLOSED", "AUCTION_HOUSE_CLOSED", "MAIL_CLOSED", "BANKFRAME_CLOSED", "TRADE_CLOSED", "GUILDBANKFRAME_CLOSED"}

local MidnightBags = CreateFrame("Frame", "MidnightBags", UIParent)
MidnightBags:RegisterEvent("PLAYER_LOGIN")

-- =========================================================================
--  1. UTILITIES
-- =========================================================================

local function CreateGlassBackdrop(f)
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

local function BuildAllBagsStateHash()
    if not C_Container or not C_Container.GetContainerNumSlots or not C_Container.GetContainerItemInfo then
        return "no_container_api"
    end
    local parts = {}
    for bagID = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bagID) or 0
        parts[#parts + 1] = "b" .. bagID .. ":" .. numSlots
        for slotID = 1, numSlots do
            local info = C_Container.GetContainerItemInfo(bagID, slotID)
            if info then
                parts[#parts + 1] = ("%d,%d,%d,%d"):format(
                    bagID,
                    slotID,
                    tonumber(info.itemID) or 0,
                    tonumber(info.stackCount) or 0
                )
            else
                parts[#parts + 1] = ("%d,%d,0,0"):format(bagID, slotID)
            end
        end
    end
    return table_concat(parts, ";")
end

local CURRENCY_INTEREST_GROUPS = {
    { key = "COFFER", tokenSets = {{"coffer", "key"}}, color = {0.95, 0.80, 0.30} },
    { key = "UNDERCOIN", tokenSets = {{"undercoin"}}, color = {0.65, 0.85, 1.00} },
    { key = "VALORSTONE", tokenSets = {{"valorstone"}}, color = {0.85, 0.75, 1.00} },
    { key = "CREST", tokenSets = {{"crest"}}, color = {0.85, 0.85, 0.95} },
}

local function StringContainsAllTokens(nameLower, tokens)
    if not nameLower or not tokens then return false end
    for _, token in ipairs(tokens) do
        if not nameLower:find(token, 1, true) then
            return false
        end
    end
    return true
end

local function StringMatchesTokenSets(textLower, tokenSets)
    if not textLower or not tokenSets then return false end
    for _, tokenSet in ipairs(tokenSets) do
        if StringContainsAllTokens(textLower, tokenSet) then
            return true
        end
    end
    return false
end

local function GetCurrencyListEntries()
    local entries = {}
    if not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyListSize or not C_CurrencyInfo.GetCurrencyListInfo then
        return entries
    end

    local size = C_CurrencyInfo.GetCurrencyListSize()
    for i = 1, size do
        local info = C_CurrencyInfo.GetCurrencyListInfo(i)
        if info and not info.isHeader and not info.isTypeUnused and info.name then
            entries[#entries + 1] = {
                name = info.name,
                quantity = tonumber(info.quantity) or 0,
                iconFileID = info.iconFileID,
                currencyID = info.currencyTypesID or info.currencyID,
            }
        end
    end
    return entries
end

local function GetCurrencyDetailsByID(currencyID)
    if not currencyID or not C_CurrencyInfo or not C_CurrencyInfo.GetCurrencyInfo then
        return nil
    end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if ok then
        return info
    end
    return nil
end

local function ExtractSeasonNumbers(textLower)
    local out = {}
    if not textLower or textLower == "" then return out end
    for value in textLower:gmatch("season%s*(%d+)") do
        local seasonNumber = tonumber(value)
        if seasonNumber then
            out[#out + 1] = seasonNumber
        end
    end
    return out
end

local function DetectCurrentSeasonNumber(entries)
    local counts = {}
    local bestSeason, bestCount = nil, 0

    for _, entry in ipairs(entries) do
        local nameLower = (entry.name or ""):lower()
        local details = GetCurrencyDetailsByID(entry.currencyID)
        local descLower = details and details.description and details.description:lower() or ""
        local combined = nameLower .. " " .. descLower

        local isInteresting = false
        for _, group in ipairs(CURRENCY_INTEREST_GROUPS) do
            if StringMatchesTokenSets(combined, group.tokenSets) then
                isInteresting = true
                break
            end
        end

        if isInteresting then
            for _, seasonNum in ipairs(ExtractSeasonNumbers(combined)) do
                counts[seasonNum] = (counts[seasonNum] or 0) + 1
                if counts[seasonNum] > bestCount or (counts[seasonNum] == bestCount and (not bestSeason or seasonNum > bestSeason)) then
                    bestSeason = seasonNum
                    bestCount = counts[seasonNum]
                end
            end
        end
    end

    if bestSeason then return bestSeason, "currency" end

    if C_MythicPlus and C_MythicPlus.GetCurrentSeason then
        local ok, mpSeason = pcall(C_MythicPlus.GetCurrentSeason)
        if ok and type(mpSeason) == "number" and mpSeason > 0 then
            return mpSeason, "api"
        end
    end
    return nil, nil
end

local function GetCurrencyGroup(entryNameLower)
    for idx, group in ipairs(CURRENCY_INTEREST_GROUPS) do
        if StringMatchesTokenSets(entryNameLower, group.tokenSets) then
            return idx, group
        end
    end
    return nil, nil
end

local function GetCrestColor(entryNameLower, fallback)
    if entryNameLower:find("weathered", 1, true) then
        return 0.60, 0.90, 0.65
    elseif entryNameLower:find("carved", 1, true) then
        return 0.60, 0.75, 1.00
    elseif entryNameLower:find("runed", 1, true) then
        return 0.80, 0.65, 1.00
    elseif entryNameLower:find("gilded", 1, true) then
        return 1.00, 0.82, 0.45
    end
    return unpack(fallback)
end

local function BuildTrackedSeasonalCurrencyRows()
    local rows, seenByCurrencyID = {}, {}
    local entries = GetCurrencyListEntries()
    local currentSeason, currentSeasonSource = DetectCurrentSeasonNumber(entries)

    for _, entry in ipairs(entries) do
        local entryNameLower = (entry.name or ""):lower()
        local groupIndex, group = GetCurrencyGroup(entryNameLower)
        if groupIndex and group then
            local details = GetCurrencyDetailsByID(entry.currencyID)
            local descLower = details and details.description and details.description:lower() or ""
            local combined = entryNameLower .. " " .. descLower
            local seasonMatches = false
            local containsAnySeasonTag = false

            for _, seasonNum in ipairs(ExtractSeasonNumbers(combined)) do
                containsAnySeasonTag = true
                if currentSeason and seasonNum == currentSeason then
                    seasonMatches = true
                end
            end

            local include = true
            if currentSeason and currentSeasonSource == "currency" and containsAnySeasonTag and not seasonMatches then
                include = false
            end

            if include and entry.currencyID and not seenByCurrencyID[entry.currencyID] then
                seenByCurrencyID[entry.currencyID] = true

                local r, g, b = unpack(group.color)
                if group.key == "CREST" then
                    r, g, b = GetCrestColor(entryNameLower, group.color)
                end

                rows[#rows + 1] = {
                    label = entry.name,
                    quantity = entry.quantity,
                    iconFileID = entry.iconFileID,
                    found = true,
                    color = {r, g, b},
                    groupOrder = groupIndex,
                }
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.groupOrder ~= b.groupOrder then
            return a.groupOrder < b.groupOrder
        end
        return (a.label or "") < (b.label or "")
    end)

    return rows, currentSeason
end

local function ShowCurrencySummaryTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Currency Information", 1.00, 0.82, 0.20)
    GameTooltip:AddDoubleLine("Gold", GetCoinTextureString(GetMoney()), 1.00, 0.90, 0.30, 1, 1, 1)
    GameTooltip:AddLine(" ")
    local rows, currentSeason = BuildTrackedSeasonalCurrencyRows()
    if currentSeason then
        GameTooltip:AddLine(string.format("Current Season Currency (Season %d)", currentSeason), 0.75, 0.85, 1.00)
    else
        GameTooltip:AddLine("Current Season Currency", 0.75, 0.85, 1.00)
    end

    if #rows == 0 then
        GameTooltip:AddDoubleLine("No seasonal currencies detected", "--", 0.55, 0.55, 0.62, 0.55, 0.55, 0.62)
    end
    for _, row in ipairs(rows) do
        local lr, lg, lb = unpack(row.color)
        local rr, rg, rb = lr, lg, lb
        local valueText = BreakUpLargeNumbers(row.quantity or 0)
        if row.iconFileID then
            valueText = valueText .. string.format(" |T%d:14:14:0:0:64:64:4:60:4:60|t", row.iconFileID)
        end
        GameTooltip:AddDoubleLine(row.label, valueText, lr, lg, lb, rr, rg, rb)
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Values are read dynamically from your Currency tab.", 0.55, 0.55, 0.62)
    GameTooltip:Show()
end

local function AttachCurrencySummaryTooltip(frame)
    if not frame then return end
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", function(self) ShowCurrencySummaryTooltip(self) end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- =========================================================================
--  2. DISABLE DEFAULT BAGS
-- =========================================================================

-- Recursion guard for bag suppression (prevents C stack overflow)
local _suppressingBags = false

-- Force-hide all known Blizzard bag frames
local function SuppressAllBlizzardBags()
    if _suppressingBags or not IsInventoryEnabled() then return end
    _suppressingBags = true
    if _G.ContainerFrameCombinedBags and _G.ContainerFrameCombinedBags:IsShown() then
        _G.ContainerFrameCombinedBags:Hide()
    end
    for i = 1, 13 do
        local cf = _G["ContainerFrame" .. i]
        if cf and cf:IsShown() then cf:Hide() end
    end
    if _G.BagsBar and _G.BagsBar:IsShown() then
        _G.BagsBar:Hide()
    end
    _suppressingBags = false
end

local function OverrideBagToggles()
    if MidnightBags._toggleOverride then return end
    MidnightBags._toggleOverride = true

    -- Store originals for use when inventory module is disabled.
    _G.MidnightUI_Orig_ToggleAllBags = _G.MidnightUI_Orig_ToggleAllBags or _G.ToggleAllBags
    _G.MidnightUI_Orig_ToggleBackpack = _G.MidnightUI_Orig_ToggleBackpack or _G.ToggleBackpack
    _G.MidnightUI_Orig_OpenAllBags = _G.MidnightUI_Orig_OpenAllBags or _G.OpenAllBags
    _G.MidnightUI_Orig_OpenBackpack = _G.MidnightUI_Orig_OpenBackpack or _G.OpenBackpack
    _G.MidnightUI_Orig_OpenBag = _G.MidnightUI_Orig_OpenBag or _G.OpenBag
    _G.MidnightUI_Orig_ToggleBag = _G.MidnightUI_Orig_ToggleBag or _G.ToggleBag

    -- Use hooksecurefunc so the original secure functions run first, preserving
    -- the secure execution chain. This prevents ADDON_ACTION_FORBIDDEN taint
    -- when Blizzard UI (e.g. item upgrade) calls bag functions internally.
    --
    -- We simply mirror Blizzard's toggle: if MUI bags are visible, close them.
    -- If they're not visible, open them. The HideDefaultBags() Show-hook
    -- already suppresses Blizzard's combined bag frame.
    -- Debounce: Blizzard's bag functions call each other in a chain
    -- (ToggleAllBags → ToggleBackpack → ToggleBag → OpenBag×5)
    -- Only act on the FIRST hook in the chain, ignore the rest this frame.
    local bagHookActive = false

    hooksecurefunc("ToggleAllBags", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Toggle()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
    hooksecurefunc("ToggleBackpack", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Toggle()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
    hooksecurefunc("OpenAllBags", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Open()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
    hooksecurefunc("OpenBackpack", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Open()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
    hooksecurefunc("OpenBag", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Open()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
    hooksecurefunc("ToggleBag", function()
        if not IsInventoryEnabled() or bagHookActive then return end
        bagHookActive = true
        SuppressAllBlizzardBags()
        MidnightBags:Toggle()
        C_Timer.After(0, function() bagHookActive = false end)
    end)
end

local function HideDefaultBags()
    SuppressAllBlizzardBags()

    if _G.ContainerFrameCombinedBags and not MidnightBags._combinedBagsHooked then
        MidnightBags._combinedBagsHooked = true
        hooksecurefunc(_G.ContainerFrameCombinedBags, "Show", function(self)
            if not _suppressingBags and IsInventoryEnabled() then
                _suppressingBags = true
                self:Hide()
                _suppressingBags = false
            end
        end)
    end

    -- Hook individual container frames
    if not MidnightBags._containerFramesHooked then
        MidnightBags._containerFramesHooked = true
        for i = 1, 13 do
            local cf = _G["ContainerFrame" .. i]
            if cf then
                hooksecurefunc(cf, "Show", function(self)
                    if not _suppressingBags and IsInventoryEnabled() then
                        _suppressingBags = true
                        self:Hide()
                        _suppressingBags = false
                    end
                end)
            end
        end
    end

    if _G.BagsBar and not MidnightBags._bagsBarHooked then
        MidnightBags._bagsBarHooked = true
        hooksecurefunc(_G.BagsBar, "Show", function(self)
            if not _suppressingBags and IsInventoryEnabled() then
                _suppressingBags = true
                self:Hide()
                _suppressingBags = false
            end
        end)
    end
end

local function ShowDefaultBags()
    if _G.BagsBar and _G.BagsBar.Show then
        _G.BagsBar:Show()
    end
end

-- =========================================================================
--  3. CUSTOM SECURE ITEM BUTTONS
-- =========================================================================

-- Lazy-create helpers: avoid allocating heavy child frames for all 376 bag slots upfront
local function EnsureCooldown(btn)
    if btn.Cooldown then return btn.Cooldown end
    local name = btn:GetName() or "MidnightBagItemAnon"
    btn.Cooldown = CreateFrame("Cooldown", name .. "Cooldown", btn, "CooldownFrameTemplate")
    btn.Cooldown:SetAllPoints()
    return btn.Cooldown
end

local function EnsureJunkIcon(btn)
    if btn.JunkIcon then return btn.JunkIcon end
    btn.JunkIcon = btn:CreateTexture(nil, "OVERLAY")
    btn.JunkIcon:SetTexture("Interface\\Buttons\\UI-GroupLoot-Coin-Up")
    btn.JunkIcon:SetPoint("TOPLEFT", 2, -2)
    btn.JunkIcon:SetSize(14, 14)
    btn.JunkIcon:Hide()
    return btn.JunkIcon
end

local function ConstructBagButton(id, parent)
    local name = "MidnightBagItem" .. id
    
    -- INHERIT: SecureActionButtonTemplate (Functionality) + BackdropTemplate (Visuals)
    -- We do NOT inherit ContainerFrameItemButtonTemplate to avoid taint/script conflicts.
    local btn = CreateFrame("Button", name, parent, "SecureActionButtonTemplate, BackdropTemplate")
    btn:SetSize(C.slotSize, C.slotSize)
    btn._mui_lastPickupStamp = 0
    btn._mui_assignedBag = nil
    btn._mui_assignedSlot = nil
    btn._mui_anchorParent = nil
    btn._mui_pointX = nil
    btn._mui_pointY = nil
    btn._mui_size = nil
    btn._mui_hasItem = false
    btn._mui_iconFileID = nil
    btn._mui_stackCount = 0
    btn._mui_quality = nil
    btn._mui_qualityR = nil
    btn._mui_qualityG = nil
    btn._mui_qualityB = nil
    btn._mui_isJunk = false

    local function TryPickupBagItem(self)
        if not self.bagID or not self.slotID then
            return
        end
        -- Manual pickup should cancel any queued auto-sort operations.
        if smartSortRunning then
            smartSortRunning = false
            smartSortOpQueue = nil
            pendingInventorySort = false
            smartInventoryArrangeEnabled = false
        end
        lastBroomSortStateHash = nil
        local now = (GetTimePreciseSec and GetTimePreciseSec()) or (GetTime and GetTime()) or 0
        if now > 0 and (now - (self._mui_lastPickupStamp or 0)) < 0.04 then
            return
        end
        self._mui_lastPickupStamp = now
        C_Container.PickupContainerItem(self.bagID, self.slotID)
    end
    
    local function IsUseKeyDownEnabled()
        if type(_G.GetCVarBool) == "function" then
            return _G.GetCVarBool("ActionButtonUseKeyDown")
        end
        local cvar = (type(_G.GetCVar) == "function" and _G.GetCVar("ActionButtonUseKeyDown")) or "0"
        return cvar == "1"
    end

    -- [[ 1. SECURE CONFIGURATION ]]
    -- Register both phases so secure right-click use works whether WoW is
    -- configured for key-down or key-up action button activation.
    btn:RegisterForClicks("AnyDown", "AnyUp")
    btn:RegisterForDrag("LeftButton")
    
    -- Right Click = Use Item (Handled by WoW C++ Engine)
    btn:SetAttribute("type2", "macro")
    
    -- Left Click = Pickup (Handled by Lua PreClick)
    -- We use PreClick because "type1=nil" allows the click to pass through, but we want explicit control.
    btn:SetScript("PreClick", function(self, button, down)
        if button ~= "LeftButton" or IsModifiedClick() then
            return
        end

        -- Run manual pickup only on the active click phase to avoid double-pickup.
        local useKeyDown = IsUseKeyDownEnabled()
        if useKeyDown then
            if down ~= true then return end
        else
            if down == true then return end
        end

        TryPickupBagItem(self)
    end)
    
    -- Drag & Drop
    btn:SetScript("OnDragStart", function(self)
        -- Only pick up if PreClick hasn't already put an item on the cursor.
        if not GetCursorInfo() then
            TryPickupBagItem(self)
        end
    end)
    btn:SetScript("OnReceiveDrag", function(self)
        TryPickupBagItem(self)
    end)

    -- Tooltips
    btn:SetScript("OnEnter", function(self)
        if self.bagID and self.slotID then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            local info = C_Container.GetContainerItemInfo(self.bagID, self.slotID)
            if info then
                GameTooltip:SetBagItem(self.bagID, self.slotID)
                GameTooltip:Show()
                self:SetBackdropBorderColor(1, 1, 1, 1)
                
                -- Support for the "New Item" flash
                if self.NewItemTexture then self.NewItemTexture:Hide() end
            end
        end
    end)
    
    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        -- Reset border is handled by UpdateLayout usually, but safe reset here:
        if self._mui_qualityR then
            self:SetBackdropBorderColor(self._mui_qualityR, self._mui_qualityG, self._mui_qualityB, 1)
        else
            self:SetBackdropBorderColor(0, 0, 0, 1)
        end
    end)

    -- [[ 2. VISUAL ELEMENTS ]]
    
    -- A. Backdrop (Border/Bg)
    btn:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    btn:SetBackdropColor(unpack(C.slotEmpty))
    btn:SetBackdropBorderColor(0, 0, 0, 1)

    -- B. Icon
    btn.icon = btn:CreateTexture(nil, "ARTWORK")
    btn.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    btn.icon:SetPoint("TOPLEFT", 1, -1)
    btn.icon:SetPoint("BOTTOMRIGHT", -1, 1)
    
    -- C. Count
    btn.Count = btn:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
    btn.Count:SetPoint("BOTTOMRIGHT", -2, 2)
    
    -- D. Cooldown (lazy-created on first use to save memory — CooldownFrameTemplate is heavy)
    -- btn.Cooldown created on demand via EnsureCooldown()

    -- E. Junk Icon (lazy-created on first use — most slots are not junk)
    -- btn.JunkIcon created on demand via EnsureJunkIcon()
    
    -- F. Highlight
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    btn:SetHighlightTexture(hl)

    -- G. Equipped Indicator — small green pip in the bottom-left corner
    local eqDot = btn:CreateTexture(nil, "OVERLAY", nil, 2)
    eqDot:SetSize(8, 8)
    eqDot:SetPoint("BOTTOMLEFT", 2, 2)
    eqDot:SetColorTexture(0.1, 0.9, 0.2, 0.9)
    eqDot:Hide()
    btn._mui_equippedDot = eqDot
    btn._mui_isEquipped = false

    -- H. Equip Flash — brief white flash for visual feedback on equip/unequip
    local flash = btn:CreateTexture(nil, "OVERLAY", nil, 1)
    flash:SetAllPoints(btn.icon)
    flash:SetColorTexture(1, 1, 1, 1)
    flash:SetAlpha(0)
    flash:Hide()
    btn._mui_equipFlash = flash

    local flashAG = flash:CreateAnimationGroup()
    local fadeIn = flashAG:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0)
    fadeIn:SetToAlpha(0.5)
    fadeIn:SetDuration(0.08)
    fadeIn:SetOrder(1)
    local fadeOut = flashAG:CreateAnimation("Alpha")
    fadeOut:SetFromAlpha(0.5)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(0.35)
    fadeOut:SetOrder(2)
    flashAG:SetScript("OnPlay", function()
        flash:SetAlpha(1)
        flash:Show()
    end)
    flashAG:SetScript("OnFinished", function()
        flash:SetAlpha(0)
        flash:Hide()
    end)
    btn._mui_equipFlashAG = flashAG

    return btn
end

local function SetBagButtonAssignment(btn, bagID, slotID)
    btn.bagID = bagID
    btn.slotID = slotID

    if InCombatLockdown and InCombatLockdown() then
        return
    end

    if btn._mui_assignedBag ~= bagID or btn._mui_assignedSlot ~= slotID then
        btn:SetAttribute("bag", bagID)
        btn:SetAttribute("slot", slotID)
        btn:SetID(slotID)
        btn:SetAttribute("macrotext2", "/use " .. bagID .. " " .. slotID)
        btn._mui_assignedBag = bagID
        btn._mui_assignedSlot = slotID
    end
end

local function ResetBagButtonVisuals(btn)
    if btn.icon:IsShown() then btn.icon:Hide() end
    if btn.Count:IsShown() then btn.Count:Hide() end
    if btn.Cooldown and btn.Cooldown:IsShown() then btn.Cooldown:Hide() end
    if btn.JunkIcon and btn.JunkIcon:IsShown() then btn.JunkIcon:Hide() end
    if btn._mui_equippedDot and btn._mui_equippedDot:IsShown() then btn._mui_equippedDot:Hide() end

    btn._mui_hasItem = false
    btn._mui_iconFileID = nil
    btn._mui_stackCount = 0
    btn._mui_quality = nil
    btn._mui_qualityR = nil
    btn._mui_qualityG = nil
    btn._mui_qualityB = nil
    btn._mui_isJunk = false
    btn._mui_isEquipped = false

    btn:SetBackdropColor(unpack(C.slotEmpty))
    btn:SetBackdropBorderColor(0, 0, 0, 1)
end

local function UpdateBagButtonVisuals(btn, bagID, slotID)
    local info = C_Container.GetContainerItemInfo(bagID, slotID)
    if not info then
        ResetBagButtonVisuals(btn)
        return
    end

    if btn._mui_iconFileID ~= info.iconFileID then
        btn.icon:SetTexture(info.iconFileID)
        btn._mui_iconFileID = info.iconFileID
    end
    if not btn.icon:IsShown() then
        btn.icon:Show()
    end

    local stackCount = tonumber(info.stackCount) or 0
    if stackCount > 1 then
        if btn._mui_stackCount ~= stackCount then
            btn.Count:SetText(stackCount)
            btn._mui_stackCount = stackCount
        end
        if not btn.Count:IsShown() then
            btn.Count:Show()
        end
    else
        btn._mui_stackCount = 0
        if btn.Count:IsShown() then
            btn.Count:Hide()
        end
    end

    local start, duration, enable = C_Container.GetContainerItemCooldown(bagID, slotID)
    if start and start > 0 and duration and duration > 0 then
        CooldownFrame_Set(EnsureCooldown(btn), start, duration, enable)
    elseif btn.Cooldown and btn.Cooldown:IsShown() then
        btn.Cooldown:Hide()
    end

    if info.isJunk then
        local junk = EnsureJunkIcon(btn)
        if not junk:IsShown() then junk:Show() end
    elseif btn.JunkIcon then
        if btn.JunkIcon:IsShown() then btn.JunkIcon:Hide() end
    end
    btn._mui_isJunk = not not info.isJunk

    if not btn._mui_hasItem then
        btn:SetBackdropColor(0, 0, 0, 0.8)
        btn._mui_hasItem = true
    end

    local quality = tonumber(info.quality)
    if quality and quality > 1 then
        if btn._mui_quality ~= quality then
            local r, g, b = GetItemQualityColor(quality)
            btn._mui_quality = quality
            btn._mui_qualityR = r
            btn._mui_qualityG = g
            btn._mui_qualityB = b
        end
        btn:SetBackdropBorderColor(btn._mui_qualityR, btn._mui_qualityG, btn._mui_qualityB, 1)
    else
        btn._mui_quality = nil
        btn._mui_qualityR = nil
        btn._mui_qualityG = nil
        btn._mui_qualityB = nil
        btn:SetBackdropBorderColor(0, 0, 0, 1)
    end

    -- Equipped indicator — check if this exact item ID is currently worn in any equipment slot
    local isEquipped = false
    local itemID = info.itemID
    if itemID then
        for eqSlot = 1, 19 do
            local eqLink = GetInventoryItemLink("player", eqSlot)
            if eqLink then
                local eqID = GetItemInfoInstant(eqLink)
                if eqID == itemID then
                    isEquipped = true
                    break
                end
            end
        end
    end
    btn._mui_isEquipped = isEquipped
    if isEquipped then
        if not btn._mui_equippedDot:IsShown() then btn._mui_equippedDot:Show() end
    else
        if btn._mui_equippedDot:IsShown() then btn._mui_equippedDot:Hide() end
    end
end

local function SetBagButtonPosition(btn, parent, x, y, size, spacing)
    if InCombatLockdown and InCombatLockdown() then
        return
    end

    local pointX = x * (size + spacing)
    local pointY = -(y * (size + spacing))
    if btn._mui_anchorParent ~= parent or btn._mui_pointX ~= pointX or btn._mui_pointY ~= pointY or btn._mui_size ~= size then
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", pointX, pointY)
        btn:SetSize(size, size)
        btn._mui_anchorParent = parent
        btn._mui_pointX = pointX
        btn._mui_pointY = pointY
        btn._mui_size = size
    end

    if not btn:IsShown() then
        btn:Show()
    end
end

local function HideBagButton(btn)
    if not btn or (InCombatLockdown and InCombatLockdown()) then
        return
    end
    if btn:IsShown() then
        btn:Hide()
    end
end

-- =========================================================================
--  4. THE DOCK
-- =========================================================================

local function CreateDock()
    if dockFrameRef then return dockFrameRef end
    local settings = EnsureBagSettings()
    local dockFrame = CreateFrame("Button", "MidnightDockMain", UIParent)
    dockFrame:SetSize(46, 46)
    dockFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 40)
    dockFrame:SetMovable(true)
    dockFrame:EnableMouse(true)
    dockFrame:RegisterForDrag("LeftButton")
    dockFrame:SetClampedToScreen(true)
    
    dockFrame:SetScript("OnDragStart", dockFrame.StartMoving)
    dockFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    dockFrame:SetScript("OnClick", function(self, button)
        if button == "LeftButton" then
            MidnightBags:Toggle()
        end
    end)

    local bgFrame = CreateFrame("Frame", nil, dockFrame, "BackdropTemplate")
    bgFrame:SetAllPoints()
    bgFrame:SetFrameLevel(dockFrame:GetFrameLevel())
    bgFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    bgFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    bgFrame:SetBackdropBorderColor(0, 0, 0, 1)
    
    local icon = dockFrame:CreateTexture(nil, "OVERLAY")
    icon:SetSize(28, 28)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\inv_misc_bag_08")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local drawer = CreateFrame("Frame", "MidnightDockDrawer", dockFrame, "BackdropTemplate")
    -- Note: The -4 creates a gap, but the timer logic handles this smoothly
    drawer:SetPoint("RIGHT", dockFrame, "LEFT", -4, 0)
    drawer:SetSize(1, 46)
    drawer:SetFrameStrata("HIGH")
    drawer:SetFrameLevel(50)
    drawer:SetClipsChildren(true)
    
    drawer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8", 
        edgeSize = 1,
    })
    drawer:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
    drawer:SetBackdropBorderColor(0, 0, 0, 1)
    drawer:SetAlpha(0)

    -- 1. Standard Bag Buttons
    for i = 0, 4 do 
        local b = CreateFrame("Button", nil, drawer)
        b:SetSize(30, 30)
        b:SetPoint("RIGHT", drawer, "RIGHT", -8 - (i*36), 0)
        
        -- :: ADDED HIGHLIGHT TEXTURE ::
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8x8")
        hl:SetVertexColor(1, 1, 1, 0.2)
        hl:SetBlendMode("ADD")
        b:SetHighlightTexture(hl)
        
        local bIcon = b:CreateTexture(nil, "ARTWORK")
        bIcon:SetAllPoints()
        bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) 
        
        local function UpdateBagIcon()
            local invID = C_Container.ContainerIDToInventoryID(i+1)
            if i == 0 then
                bIcon:SetTexture("Interface\\Buttons\\Button-Backpack-Up")
            else
                local texture = GetInventoryItemTexture("player", invID)
                if texture then
                    bIcon:SetTexture(texture); bIcon:SetDesaturated(false)
                else
                    bIcon:SetTexture("Interface\\PaperDoll\\UI-PaperDoll-Slot-Bag"); bIcon:SetDesaturated(true)
                end
            end
        end
        UpdateBagIcon()
        b:SetScript("OnShow", UpdateBagIcon)
        b:SetScript("OnClick", function() MidnightBags:Toggle() end)
    end
    
    -- 2. Reagent Bag Button
    local rBtn = CreateFrame("Button", nil, drawer)
    rBtn:SetSize(30, 30)
    rBtn:SetPoint("RIGHT", drawer, "RIGHT", -8 - (5*36) - 10, 0)
    
    -- :: ADDED HIGHLIGHT TEXTURE ::
    local rHl = rBtn:CreateTexture(nil, "HIGHLIGHT")
    rHl:SetAllPoints()
    rHl:SetTexture("Interface\\Buttons\\WHITE8x8")
    rHl:SetVertexColor(1, 1, 1, 0.2)
    rHl:SetBlendMode("ADD")
    rBtn:SetHighlightTexture(rHl)

    local rIcon = rBtn:CreateTexture(nil, "ARTWORK")
    rIcon:SetAllPoints(); rIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    rIcon:SetTexture("Interface\\Icons\\inv_misc_bag_27")
    
    -- :: ANIMATION & STATE LOGIC ::
    drawer.targetWidth = 1
    drawer.targetAlpha = 0
    local hoverTimer = 0 -- Timer to bridge the gap between frames
    
    local function UpdateSlide(self, elapsed)
        -- 1. Check if Mouse is valid (IsMouseOver handles children automatically)
        if self:IsMouseOver() or dockFrame:IsMouseOver() then
            hoverTimer = 0 -- Reset timer if mouse is detected
            self.targetWidth = 260
            self.targetAlpha = 1
        else
            hoverTimer = hoverTimer + elapsed
        end
        
        -- 2. Only close if mouse has been gone for > 0.2 seconds
        if hoverTimer > 0.2 then
            self.targetWidth = 1
            self.targetAlpha = 0
        end

        -- 3. Animation Physics
        local speed = 12 * elapsed
        local curW = self:GetWidth()
        local diffW = self.targetWidth - curW
        if math.abs(diffW) < 0.5 then 
            self:SetWidth(self.targetWidth) 
        else 
            self:SetWidth(curW + (diffW * speed)) 
        end
        
        local curA = self:GetAlpha()
        local diffA = self.targetAlpha - curA
        if math.abs(diffA) < 0.01 then 
            self:SetAlpha(self.targetAlpha) 
            if self.targetAlpha == 0 and self.targetWidth == 1 then self:Hide() end
        else 
            self:SetAlpha(curA + (diffA * speed)) 
        end
    end
    drawer:SetScript("OnUpdate", UpdateSlide)

    dockFrame:SetScript("OnEnter", function() drawer:Show() end)
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(dockFrame, "Inventory")
    end
    local dockScale = tonumber(settings.dockScale) or 100
    if dockScale < 50 then dockScale = 50 end
    if dockScale > 200 then dockScale = 200 end
    dockFrame:SetScale(dockScale / 100)
    dockFrameRef = dockFrame
    return dockFrame
end

local function ApplyInventoryEnabledState()
    if not IsInventoryEnabled() then
        MidnightBags:Close()
    end
    if InCombatLockdown and InCombatLockdown() then
        pendingInventoryStateApply = true
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingInventoryStateApply = false
    MidnightBags:UnregisterEvent("PLAYER_REGEN_ENABLED")

    if not IsInventoryEnabled() then
        if dockFrameRef then dockFrameRef:Hide() end
        ShowDefaultBags()
        return
    end
    if _G.CloseAllBags then
        _G.CloseAllBags()
    end
    if dockFrameRef then
        local settings = EnsureBagSettings()
        local dockScale = tonumber(settings.dockScale) or 100
        if dockScale < 50 then dockScale = 50 end
        if dockScale > 200 then dockScale = 200 end
        dockFrameRef:SetScale(dockScale / 100)
        dockFrameRef:Show()
    end
    HideDefaultBags()
end
_G.MidnightUI_ApplyInventorySettings = ApplyInventoryEnabledState

local SMART_HEARTHSTONE_ITEM_IDS = {
    [6948] = true,    -- Hearthstone
    [110560] = true,  -- Garrison Hearthstone
    [140192] = true,  -- Dalaran Hearthstone
    [64488] = true,   -- The Innkeeper's Daughter
    [93672] = true,   -- Dark Portal
    [142542] = true,  -- Tome of Town Portal
}

local SMART_MYTHIC_KEY_ITEM_IDS = {
    [180653] = true, -- Mythic Keystone
}

local function IsSmartHearthstoneLike(itemID, itemNameLower)
    if itemID and SMART_HEARTHSTONE_ITEM_IDS[itemID] then
        return true
    end
    if itemNameLower and itemNameLower ~= "" then
        if itemNameLower:find("hearthstone", 1, true) then
            return true
        end
        if itemNameLower:find("town portal", 1, true) then
            return true
        end
    end
    return false
end

local function IsSmartMythicKeystone(itemID, itemNameLower)
    if itemID and SMART_MYTHIC_KEY_ITEM_IDS[itemID] then
        return true
    end
    if itemNameLower and itemNameLower ~= "" and itemNameLower:find("keystone", 1, true) then
        return true
    end
    return false
end

local function BuildSmartSortEntry(bagID, slotID)
    local info = C_Container.GetContainerItemInfo(bagID, slotID)
    if not info then
        return {
            bagID = bagID,
            slotID = slotID,
            hasItem = false,
            bucket = 1000,
            classID = 999,
            subClassID = 999,
            quality = -1,
            itemLevel = 0,
            stackCount = 0,
            itemID = 0,
            itemGUID = "",
            nameLower = "",
            itemFamily = 0,
            isTradeGoods = false,
        }
    end

    local itemID = info.itemID
    local itemName = ""
    local itemLink = info.hyperlink
    if info.hyperlink then
        itemName = C_Item.GetItemInfo(info.hyperlink) or ""
    end
    if itemName == "" and itemID and C_Item.GetItemNameByID then
        itemName = C_Item.GetItemNameByID(itemID) or ""
    end
    local itemNameLower = itemName ~= "" and itemName:lower() or ""

    local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(itemID or 0)

    local bucket = 100
    if info.isJunk then
        bucket = 900
    elseif IsSmartHearthstoneLike(itemID, itemNameLower) then
        bucket = 10
    elseif IsSmartMythicKeystone(itemID, itemNameLower) then
        bucket = 20
    elseif classID == 2 or classID == 4 then
        bucket = 30
    elseif classID == 0 then
        bucket = 40
    elseif classID == 12 then
        bucket = 50
    elseif bagID == 5 or classID == 7 then
        bucket = 60
    elseif classID == 15 and subClassID == 5 then
        bucket = 70
    end

    local itemLevel = 0
    if (classID == 2 or classID == 4) and C_Item and C_Item.GetDetailedItemLevelInfo and info.hyperlink then
        local detailedItemLevel = C_Item.GetDetailedItemLevelInfo(info.hyperlink)
        itemLevel = tonumber(detailedItemLevel) or 0
    end

    local itemFamily = 0
    if GetItemFamily then
        if not itemLink and itemID and C_Item and C_Item.GetItemInfo then
            local _, fetchedLink = C_Item.GetItemInfo(itemID)
            itemLink = fetchedLink
        end
        if itemLink then
            itemFamily = tonumber(GetItemFamily(itemLink)) or 0
        end
    end

    return {
        bagID = bagID,
        slotID = slotID,
        hasItem = true,
        bucket = bucket,
        classID = tonumber(classID) or -1,
        subClassID = tonumber(subClassID) or -1,
        quality = tonumber(info.quality) or -1,
        itemLevel = itemLevel,
        stackCount = tonumber(info.stackCount) or 0,
        itemID = tonumber(itemID) or 0,
        itemGUID = tostring(info.itemGUID or ""),
        nameLower = itemNameLower,
        itemFamily = itemFamily,
        isTradeGoods = (classID == 7),
    }
end

local function SmartSortEntryLess(a, b)
    if a.hasItem ~= b.hasItem then
        return a.hasItem
    end
    if a.bucket ~= b.bucket then
        return a.bucket < b.bucket
    end
    if a.classID ~= b.classID then
        return a.classID < b.classID
    end
    if a.subClassID ~= b.subClassID then
        return a.subClassID < b.subClassID
    end
    if a.quality ~= b.quality then
        return a.quality > b.quality
    end
    if a.itemLevel ~= b.itemLevel then
        return a.itemLevel > b.itemLevel
    end
    if a.itemID ~= b.itemID then
        return a.itemID < b.itemID
    end
    if a.itemGUID ~= b.itemGUID then
        if a.itemGUID == "" then
            return false
        end
        if b.itemGUID == "" then
            return true
        end
        return a.itemGUID < b.itemGUID
    end
    if a.stackCount ~= b.stackCount then
        return a.stackCount > b.stackCount
    end
    if a.nameLower ~= b.nameLower then
        return a.nameLower < b.nameLower
    end
    if a.bagID ~= b.bagID then
        return a.bagID < b.bagID
    end
    return a.slotID < b.slotID
end

local function BuildSmartOrderedSlotsForBag(bagID)
    local entries = {}
    local numSlots = C_Container.GetContainerNumSlots(bagID)
    for slotID = 1, numSlots do
        entries[#entries + 1] = BuildSmartSortEntry(bagID, slotID)
    end
    table.sort(entries, SmartSortEntryLess)
    return entries
end

local function BitwiseAnd(a, b)
    local x = tonumber(a) or 0
    local y = tonumber(b) or 0
    if x <= 0 or y <= 0 then
        return 0
    end
    if bit and bit.band then
        return bit.band(x, y)
    end
    if bit32 and bit32.band then
        return bit32.band(x, y)
    end
    local result = 0
    local bitValue = 1
    while x > 0 and y > 0 do
        local xOdd = x % 2
        local yOdd = y % 2
        if xOdd == 1 and yOdd == 1 then
            result = result + bitValue
        end
        x = math.floor(x / 2)
        y = math.floor(y / 2)
        bitValue = bitValue * 2
    end
    return result
end

local function GetBagFamilyMask(bagID)
    if not C_Container or not C_Container.GetContainerNumFreeSlots then
        return 0
    end
    local _, family = C_Container.GetContainerNumFreeSlots(bagID)
    return tonumber(family) or 0
end

local function EntryFitsBag(entry, bagFamilyMask, bagID)
    if not entry or not entry.hasItem then
        return true
    end

    -- Reagent bag (bag 5) must be strict: only trade goods should target it.
    -- Relying on family masks alone allows false positives on some clients/items.
    if bagID == 5 then
        return entry.isTradeGoods == true
    end

    local familyMask = tonumber(bagFamilyMask) or 0
    if familyMask == 0 then
        return true
    end
    local itemFamily = tonumber(entry.itemFamily) or 0
    if itemFamily == 0 then
        return false
    end
    return BitwiseAnd(itemFamily, familyMask) ~= 0
end

local function BuildSmartGlobalSwapOps(sourceBagStart, sourceBagEnd, targetBagStart, targetBagEnd)
    local ops = {}
    local physicalSlots = {}
    local ordered = {}
    local used = {}
    local firstUnused = 1
    local sourceStart = tonumber(sourceBagStart) or 0
    local sourceEnd = tonumber(sourceBagEnd) or 5
    local targetStart = tonumber(targetBagStart)
    local targetEnd = tonumber(targetBagEnd)
    if targetStart == nil then targetStart = sourceStart end
    if targetEnd == nil then targetEnd = sourceEnd end

    for bagID = sourceStart, sourceEnd do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        for slotID = 1, numSlots do
            ordered[#ordered + 1] = BuildSmartSortEntry(bagID, slotID)
        end
    end
    table.sort(ordered, SmartSortEntryLess)

    for bagID = targetStart, targetEnd do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        local bagFamilyMask = GetBagFamilyMask(bagID)
        for slotID = 1, numSlots do
            physicalSlots[#physicalSlots + 1] = {
                bagID = bagID,
                slotID = slotID,
                bagFamilyMask = bagFamilyMask
            }
        end
    end

    local assigned = {}
    local total = #physicalSlots
    for targetIndex = 1, total do
        local target = physicalSlots[targetIndex]
        local chosenIndex = nil
        for candidateIndex = firstUnused, #ordered do
            if not used[candidateIndex] then
                local entry = ordered[candidateIndex]
                if not entry or not entry.hasItem then
                    break
                end
                if EntryFitsBag(entry, target.bagFamilyMask, target.bagID) then
                    chosenIndex = candidateIndex
                    break
                end
            end
        end

        if chosenIndex then
            used[chosenIndex] = true
            assigned[targetIndex] = ordered[chosenIndex]
            while firstUnused <= #ordered and used[firstUnused] do
                firstUnused = firstUnused + 1
            end
        else
            assigned[targetIndex] = nil
        end
    end

    for targetIndex = 1, total do
        local desired = assigned[targetIndex]
        local target = physicalSlots[targetIndex]
        if desired and desired.hasItem and (desired.bagID ~= target.bagID or desired.slotID ~= target.slotID) then
            local sourceBagID = desired.bagID
            local sourceSlotID = desired.slotID
            ops[#ops + 1] = {
                fromBagID = sourceBagID,
                fromSlot = sourceSlotID,
                toBagID = target.bagID,
                toSlot = target.slotID
            }

            for scan = targetIndex + 1, total do
                local candidate = assigned[scan]
                if candidate and candidate.bagID == target.bagID and candidate.slotID == target.slotID then
                    candidate.bagID = sourceBagID
                    candidate.slotID = sourceSlotID
                    break
                end
            end

            desired.bagID = target.bagID
            desired.slotID = target.slotID
        end
    end

    return ops
end

local function BuildSmartAllBagSwapOps()
    local ops = {}

    local reagentSlots = C_Container.GetContainerNumSlots(5) or 0
    if reagentSlots > 0 then
        local reagentOps = BuildSmartGlobalSwapOps(0, 5, 5, 5)
        for i = 1, #reagentOps do
            ops[#ops + 1] = reagentOps[i]
        end
    end

    local inventoryOps = BuildSmartGlobalSwapOps(0, 4, 0, 4)
    for i = 1, #inventoryOps do
        ops[#ops + 1] = inventoryOps[i]
    end
    return ops
end

local function RunNextSmartSortOperation()
    if not smartSortRunning then
        return
    end

    if InCombatLockdown and InCombatLockdown() then
        pendingInventorySort = true
        smartSortRunning = false
        smartSortOpQueue = nil
        smartSortPass = 0
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    if not smartSortOpQueue or #smartSortOpQueue == 0 then
        if smartSortPass < SMART_SORT_MAX_PASSES then
            local nextPass = smartSortPass + 1
            local function QueueNextPassAfterSettle()
                if not smartSortRunning then
                    return
                end
                local nextQueue = BuildSmartAllBagSwapOps()
                local nextOps = nextQueue and #nextQueue or 0
                if nextOps > 0 then
                    smartSortPass = nextPass
                    smartSortOpQueue = nextQueue
                    RunNextSmartSortOperation()
                    return
                end
                smartSortPass = SMART_SORT_MAX_PASSES
                RunNextSmartSortOperation()
            end
            if C_Timer and C_Timer.After then
                C_Timer.After(SMART_SORT_STEP_DELAY, QueueNextPassAfterSettle)
            else
                QueueNextPassAfterSettle()
            end
            return
        end

        smartSortRunning = false
        smartSortOpQueue = nil
        lastBroomSortStateHash = BuildAllBagsStateHash()
        smartSortPass = 0
        if MidnightBags and MidnightBags.UpdateLayout then
            MidnightBags:UpdateLayout()
        end
        return
    end

    local op = table.remove(smartSortOpQueue, 1)
    local fromBagID = tonumber(op.fromBagID or op.bagID) or 0
    local toBagID = tonumber(op.toBagID or op.bagID) or fromBagID
    local fromInfo = C_Container.GetContainerItemInfo(fromBagID, op.fromSlot)
    local toInfo = C_Container.GetContainerItemInfo(toBagID, op.toSlot)
    local cursorBusy = CursorHasItem and CursorHasItem()

    if cursorBusy or (fromInfo and fromInfo.isLocked) or (toInfo and toInfo.isLocked) then
        op.retryCount = (op.retryCount or 0) + 1
        table.insert(smartSortOpQueue, 1, op)
        local retryDelay = SMART_SORT_LOCK_RETRY_DELAY
        if op.retryCount > 1 then
            retryDelay = math.min(SMART_SORT_LOCK_RETRY_DELAY + ((op.retryCount - 1) * 0.05), 0.45)
        end
        if C_Timer and C_Timer.After then
            C_Timer.After(retryDelay, RunNextSmartSortOperation)
        else
            RunNextSmartSortOperation()
        end
        return
    end

    if fromInfo then
        C_Container.PickupContainerItem(fromBagID, op.fromSlot)
        C_Container.PickupContainerItem(toBagID, op.toSlot)
    else
        smartSortOpQueue = BuildSmartAllBagSwapOps()
        local replanOps = smartSortOpQueue and #smartSortOpQueue or 0
        if replanOps > 0 then
            if C_Timer and C_Timer.After then
                C_Timer.After(SMART_SORT_STEP_DELAY, RunNextSmartSortOperation)
            else
                RunNextSmartSortOperation()
            end
            return
        end
    end

    if C_Timer and C_Timer.After then
        C_Timer.After(SMART_SORT_STEP_DELAY, RunNextSmartSortOperation)
    else
        RunNextSmartSortOperation()
    end
end

local function StartSmartPhysicalSortPass()
    if smartSortRunning then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        pendingInventorySort = true
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    smartSortPass = 1

    smartSortOpQueue = BuildSmartAllBagSwapOps()
    if not smartSortOpQueue or #smartSortOpQueue == 0 then
        smartSortOpQueue = nil
        smartInventoryArrangeEnabled = false
        lastBroomSortStateHash = BuildAllBagsStateHash()
        smartSortPass = 0
        if MidnightBags and MidnightBags.UpdateLayout then
            MidnightBags:UpdateLayout()
        end
        return
    end

    smartSortRunning = true
    RunNextSmartSortOperation()
end

local function SortInventoryNow()
    -- Deterministic one-pass Midnight sort. Avoid Blizzard sort APIs here,
    -- because repeated API sort calls can reshuffle equal-priority ties.
    StartSmartPhysicalSortPass()
end

local function RequestInventorySort()
    -- One-shot smart physical sort; keep normal slot interaction behavior afterward.
    smartInventoryArrangeEnabled = false
    if smartSortRunning then
        return
    end
    local stateHash = BuildAllBagsStateHash()
    if lastBroomSortStateHash and stateHash == lastBroomSortStateHash and not smartSortRunning then
        return
    end

    -- Bag sorting can be blocked during combat, so queue it for regen safely.
    if InCombatLockdown and InCombatLockdown() then
        pendingInventorySort = true
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    pendingInventorySort = false
    SortInventoryNow()
end

local function ShowInventorySortTooltip(owner)
    if not owner or not GameTooltip then
        return
    end
    GameTooltip:SetOwner(owner, "ANCHOR_TOP")
    GameTooltip:ClearLines()
    GameTooltip:AddLine("Sort Inventory", 1.00, 0.82, 0.20)
    GameTooltip:AddLine("Smart organize by category, quality, and gear level.", 0.90, 0.90, 0.90, true)
    GameTooltip:AddLine("Applies to backpack, equipped bags, and reagent bag.", 0.75, 0.82, 0.90, true)
    GameTooltip:AddLine("Order: Hearthstones, Keys, Gear, Consumables, Reagents, Misc, Junk.", 0.75, 0.82, 0.90, true)
    if pendingInventorySort then
        GameTooltip:AddLine("Queued until combat ends.", 1.00, 0.35, 0.35, true)
    end
    GameTooltip:Show()
end

local function ConfigureSortButton(button, iconTexture)
    if not button or not iconTexture then
        return
    end

    iconTexture:SetAllPoints()
    if iconTexture.SetAtlas then
        iconTexture:SetAtlas("crosshair_ui-cursor-broom_48", false)
    else
        iconTexture:SetTexture("Interface\\Icons\\inv_misc_broom")
        iconTexture:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end
    iconTexture:SetDesaturated(true)

    button:SetScript("OnEnter", function(self)
        iconTexture:SetDesaturated(false)
        ShowInventorySortTooltip(self)
    end)
    button:SetScript("OnLeave", function()
        iconTexture:SetDesaturated(true)
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    button:SetScript("OnClick", RequestInventorySort)
end

local function GetCompactBagMarker(bagID)
    if bagID == 5 then
        return "R"
    end
    if type(bagID) == "number" and bagID > 0 then
        return tostring(bagID)
    end
    return "B"
end

local function GetSeparateBagLabel(bagID)
    if bagID == 5 then
        return "Reagent Bag"
    end
    if type(bagID) == "number" and bagID > 0 then
        return "Bag " .. bagID
    end
    return "Backpack"
end

local function AttachSeparateBagIdentityBadge(window, bagID)
    if not window then
        return
    end

    local badge = CreateFrame("Button", nil, window)
    badge:SetSize(18, 18)
    -- Keep the round badge centered with the search/sort/close header controls.
    badge:SetPoint("CENTER", window, "TOPLEFT", 19, -20)

    -- Use circular masks so bag badges read as compact round chips, not squares.
    local badgeBorder = badge:CreateTexture(nil, "BACKGROUND")
    badgeBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
    badgeBorder:SetVertexColor(0.18, 0.22, 0.30, 1.0)
    badgeBorder:SetAllPoints()
    local badgeBorderMask = badge:CreateMaskTexture()
    badgeBorderMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    badgeBorderMask:SetAllPoints(badgeBorder)
    badgeBorder:AddMaskTexture(badgeBorderMask)

    local badgeBg = badge:CreateTexture(nil, "ARTWORK")
    badgeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    badgeBg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    badgeBg:SetPoint("TOPLEFT", 1, -1)
    badgeBg:SetPoint("BOTTOMRIGHT", -1, 1)
    local badgeBgMask = badge:CreateMaskTexture()
    badgeBgMask:SetTexture("Interface\\CHARACTERFRAME\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    badgeBgMask:SetAllPoints(badgeBg)
    badgeBg:AddMaskTexture(badgeBgMask)

    local badgeText = badge:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    badgeText:SetPoint("CENTER", 0, 0)
    badgeText:SetText(GetCompactBagMarker(bagID))
    badgeText:SetTextColor(C.classColor.r, C.classColor.g, C.classColor.b)

    window._muiBadge = badge

    badge:SetScript("OnEnter", function(self)
        if not GameTooltip then
            return
        end

        local displayLabel = GetSeparateBagLabel(bagID)
        local equippedBagName = (C_Container and C_Container.GetBagName and C_Container.GetBagName(bagID)) or nil
        local slotCount = (C_Container and C_Container.GetContainerNumSlots and C_Container.GetContainerNumSlots(bagID)) or 0

        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(displayLabel, 1.00, 0.82, 0.20)
        if equippedBagName and equippedBagName ~= "" and equippedBagName ~= displayLabel then
            GameTooltip:AddLine(equippedBagName, 0.90, 0.90, 0.90, true)
        end
        if slotCount and slotCount > 0 then
            GameTooltip:AddLine("Slots: " .. slotCount, 0.70, 0.78, 0.88)
        end
        GameTooltip:Show()
    end)
    badge:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
end

-- =========================================================================
--  5. MAIN BAG WINDOW
-- =========================================================================

local BagWindow = CreateFrame("Frame", "MidnightBagWindow", UIParent, "BackdropTemplate")
BagWindow:SetSize(500, 400)
BagWindow:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -100, 100)
BagWindow:SetFrameStrata("HIGH")
BagWindow:SetToplevel(true)
BagWindow:EnableMouse(true)
BagWindow:SetMovable(true)
BagWindow:RegisterForDrag("LeftButton")
BagWindow:SetScript("OnDragStart", BagWindow.StartMoving)
BagWindow:SetScript("OnDragStop", BagWindow.StopMovingOrSizing)
BagWindow:Hide()

CreateGlassBackdrop(BagWindow)

local title = BagWindow:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 12, -12)
title:SetText("Inventory") 
title:SetTextColor(C.classColor.r, C.classColor.g, C.classColor.b)

local closeBtn = CreateFrame("Button", nil, BagWindow, "BackdropTemplate")
closeBtn:SetSize(24, 24)
closeBtn:SetPoint("TOPRIGHT", -8, -8)
closeBtn:SetText("X")
closeBtn:SetNormalFontObject("GameFontNormalSmall")
-- Custom button styling (matching Diagnostics panel)
local closeBorder = closeBtn:CreateTexture(nil, "BACKGROUND")
closeBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
closeBorder:SetVertexColor(0.18, 0.22, 0.30, 1.0)
closeBorder:SetPoint("TOPLEFT", 0, 0)
closeBorder:SetPoint("BOTTOMRIGHT", 0, 0)
local closeBg = closeBtn:CreateTexture(nil, "BACKGROUND")
closeBg:SetTexture("Interface\\Buttons\\WHITE8X8")
closeBg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
closeBg:SetPoint("TOPLEFT", 2, -2)
closeBg:SetPoint("BOTTOMRIGHT", -2, 2)
local closeSheen = closeBtn:CreateTexture(nil, "ARTWORK")
closeSheen:SetTexture("Interface\\Buttons\\WHITE8X8")
closeSheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
closeSheen:SetPoint("TOPLEFT", 3, -3)
closeSheen:SetPoint("BOTTOMRIGHT", -3, 12)
local closeHover = closeBtn:CreateTexture(nil, "HIGHLIGHT")
closeHover:SetTexture("Interface\\Buttons\\WHITE8X8")
closeHover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
closeHover:SetPoint("TOPLEFT", 2, -2)
closeHover:SetPoint("BOTTOMRIGHT", -2, 2)
closeBtn:SetNormalTexture("")
closeBtn:SetHighlightTexture(closeHover)
closeBtn:SetPushedTexture("")
closeBtn:SetScript("OnClick", function() MidnightBags:Close() end)

-- Hidden button for Escape key binding (legacy, kept for compat)
local escapeBtn = CreateFrame("Button", "MidnightBagCloseButton", BagWindow)
escapeBtn:SetScript("OnClick", function() MidnightBags:Close() end)

-- ESC to close (via UISpecialFrames)
table.insert(UISpecialFrames, "MidnightBagWindow")

local sortBtn = CreateFrame("Button", nil, BagWindow)
sortBtn:SetSize(18, 18)
sortBtn:SetPoint("RIGHT", closeBtn, "LEFT", -10, 0)
local sortIcon = sortBtn:CreateTexture(nil, "ARTWORK")
ConfigureSortButton(sortBtn, sortIcon)

local searchBox = CreateFrame("EditBox", "MidnightBagSearch", BagWindow, "BackdropTemplate")
searchBox:SetSize(160, 24)
searchBox:SetPoint("RIGHT", sortBtn, "LEFT", -15, 0)
searchBox:SetFont(C.font, 12, "")
searchBox:SetAutoFocus(false)
searchBox:SetTextInsets(6, 0, 0, 0)
CreateGlassBackdrop(searchBox)
searchBox:SetBackdropColor(0, 0, 0, 0.5)

local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
placeholder:SetPoint("LEFT", 6, 0)
placeholder:SetText("Search...")
placeholder:SetTextColor(0.5, 0.5, 0.5)

searchBox:SetScript("OnEditFocusGained", function(self) placeholder:Hide() end)
searchBox:SetScript("OnEditFocusLost", function(self) if self:GetText()=="" then placeholder:Show() end end)
searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local itemContainer = CreateFrame("Frame", nil, BagWindow)
itemContainer:SetPoint("TOPLEFT", 10, -50)
itemContainer:SetPoint("BOTTOMRIGHT", -10, 40)

local reagentDivider = CreateFrame("Frame", nil, itemContainer)
reagentDivider:SetHeight(30)
reagentDivider:Hide()
local rText = reagentDivider:CreateFontString(nil, "OVERLAY", "GameFontNormal")
rText:SetPoint("LEFT", 0, 0); rText:SetText("Reagents"); rText:SetTextColor(0.6, 0.6, 0.6)
local rLine = reagentDivider:CreateTexture(nil, "ARTWORK")
rLine:SetHeight(1); rLine:SetPoint("LEFT", rText, "RIGHT", 10, 0); rLine:SetPoint("RIGHT", 0, 0)
rLine:SetColorTexture(1, 1, 1, 0.2)

local Footer = CreateFrame("Frame", nil, BagWindow)
Footer:SetPoint("BOTTOMLEFT", 0, 0)
Footer:SetPoint("BOTTOMRIGHT", 0, 0)
Footer:SetHeight(35)
local moneyText = Footer:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
moneyText:SetPoint("RIGHT", -12, 0)
if C and C.font then
    moneyText:SetFont(C.font, 11, "")
end

local moneyHoverConsolidated = CreateFrame("Frame", nil, Footer)
moneyHoverConsolidated:SetFrameLevel(Footer:GetFrameLevel() + 10)
AttachCurrencySummaryTooltip(moneyHoverConsolidated)

local function UpdateConsolidatedMoneyDisplay()
    moneyText:SetText(GetMoneyString(GetMoney(), true))
    local width = math.max(22, (moneyText:GetStringWidth() or 0) + 8)
    moneyHoverConsolidated:ClearAllPoints()
    moneyHoverConsolidated:SetPoint("RIGHT", moneyText, "RIGHT", 2, 0)
    moneyHoverConsolidated:SetPoint("TOP", moneyText, "TOP", 0, 4)
    moneyHoverConsolidated:SetPoint("BOTTOM", moneyText, "BOTTOM", 0, -4)
    moneyHoverConsolidated:SetWidth(width)
end

-- =========================================================================
--  6. LAYOUT & FILTER ENGINE
-- =========================================================================

local function ApplyFilters()
    local query = searchBox:GetText():lower()
    
    for _, btn in pairs(itemFrames) do
        if btn:IsShown() and btn.bagID and btn.slotID then
            local info = C_Container.GetContainerItemInfo(btn.bagID, btn.slotID)
            local matches = true
            
            if query ~= "" then
                if info then
                    local name = C_Item.GetItemInfo(info.hyperlink) or ""
                    if not name:lower():find(query) then matches = false end
                else
                    matches = false
                end
            end
            
            if matches and activeFilter and info then
                local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(info.itemID)
                
                if activeFilter.type == "QUALITY" then 
                    if info.quality ~= activeFilter.arg then matches = false end
                    
                elseif activeFilter.type == "CLASS" then
                    if classID ~= activeFilter.arg then matches = false end
                    
                elseif activeFilter.type == "EQUIPMENT" then
                    if not (classID == 2 or classID == 4) then matches = false end
                    
                elseif activeFilter.type == "CONSUMABLE" then
                    if classID ~= 0 then matches = false end -- Consumables class
                    
                elseif activeFilter.type == "JUNK" then
                    if not info.isJunk then matches = false end
                    
                elseif activeFilter.type == "TRADEGOODS" then
                    if classID ~= 7 then matches = false end -- Trade Goods class
                    
                elseif activeFilter.type == "COSMETIC" then
                    -- Toys (subclass 5 of Miscellaneous), Cosmetics, Tabards
                    if not (classID == 15 or (classID == 4 and subClassID == 4)) then matches = false end
                    
                elseif activeFilter.type == "RECENT" then
                    -- Check if item is marked as new (has the new item glow)
                    if not C_NewItems.IsNewItem(btn.bagID, btn.slotID) then matches = false end
                    
                elseif activeFilter.type == "REAGENT" then
                    -- Show all reagents: items in reagent bag (5) or Trade Goods class (7)
                    -- or items with reagent quality
                    local isReagent = false
                    if btn.bagID == 5 then
                        -- Item is in the reagent bag
                        isReagent = true
                    elseif classID == 7 then
                        -- Item is Trade Goods class
                        isReagent = true
                    else
                        -- Check item quality for reagent quality (if applicable)
                        local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                        if itemLink then
                            local itemQuality = info.quality
                            -- Some reagents have quality 1 (Common) and are consumable or misc
                            if (classID == 0 or classID == 15) and itemQuality and itemQuality <= 1 then
                                isReagent = true
                            end
                        end
                    end
                    if not isReagent then matches = false end
                    
                elseif activeFilter.type == "BOE" then
                    -- Check if item is Bind on Equip
                    local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                    local isBOE = false
                    if tooltipData and tooltipData.lines then
                        for _, line in ipairs(tooltipData.lines) do
                            if line.leftText and (line.leftText:find("Bind") or line.leftText:find("Equip")) then
                                if line.leftText:find("Binds when equipped") then
                                    isBOE = true
                                    break
                                end
                            end
                        end
                    end
                    if not isBOE then matches = false end
                    
                elseif activeFilter.type == "WARBOUND" then
                    -- Check for Warbound/BoA items
                    local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                    local isWarbound = false
                    if tooltipData and tooltipData.lines then
                        for _, line in ipairs(tooltipData.lines) do
                            if line.leftText then
                                local text = line.leftText
                                if text:find("Warbound") or text:find("Account") or 
                                   text:find("Binds to account") or text:find("Binds to Battle") then
                                    isWarbound = true
                                    break
                                end
                            end
                        end
                    end
                    if not isWarbound then matches = false end
                    
                elseif activeFilter.type == "HEARTHSTONE" then
                    -- Check for Hearthstone items
                    local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                    local isHearthstone = false
                    if itemLink then
                        local itemName = C_Item.GetItemInfo(itemLink)
                        local spellName, spellID = C_Container.GetContainerItemInfo(btn.bagID, btn.slotID)
                        -- Check if item name contains "Hearthstone" or has hearthstone-like spell
                        if itemName and (itemName:find("Hearthstone") or itemName:find("Dalaran Hearthstone") or 
                           itemName:find("Garrison Hearthstone") or itemName:find("Tome of Town Portal")) then
                            isHearthstone = true
                        end
                        -- Also check tooltip for "hearthstone" ability text
                        local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                        if tooltipData and tooltipData.lines then
                            for _, line in ipairs(tooltipData.lines) do
                                if line.leftText then
                                    local text = line.leftText:lower()
                                    if text:find("return") and text:find("home") or 
                                       text:find("teleport") and text:find("home") or
                                       text:find("hearthstone") then
                                        isHearthstone = true
                                        break
                                    end
                                end
                            end
                        end
                    end
                    if not isHearthstone then matches = false end
                    
                elseif activeFilter.type == "MYTHICKEY" then
                    -- Check for Mythic Keystone
                    local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                    local isMythicKey = false
                    if itemLink then
                        local itemName = C_Item.GetItemInfo(itemLink)
                        local itemID = info.itemID
                        -- Mythic Keystone item ID is 158923 (base), but check name too
                        if itemID == 158923 or (itemName and itemName:find("Keystone")) then
                            isMythicKey = true
                        end
                        -- Also check if it's a keystone by class (15 = Miscellaneous, subclass 1 = Junk might vary)
                        -- Better to check the tooltip
                        if not isMythicKey then
                            local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                            if tooltipData and tooltipData.lines then
                                for _, line in ipairs(tooltipData.lines) do
                                    if line.leftText then
                                        local text = line.leftText
                                        if text:find("Mythic Keystone") or text:find("Keystone Level") then
                                            isMythicKey = true
                                            break
                                        end
                                    end
                                end
                            end
                        end
                    end
                    if not isMythicKey then matches = false end
                end
                
            elseif matches and activeFilter and not info then
                matches = false 
            end

            if matches then
                btn:SetAlpha(1)
                -- We only disable clicks if hidden to prevent accidental usage of filtered items
                if not btn:IsEnabled() then btn:Enable() end
            else
                btn:SetAlpha(0.1)
                if btn:IsEnabled() then btn:Disable() end
            end
            
            if info and info.quality and info.quality > 1 then
                local r, g, b = GetItemQualityColor(info.quality)
                btn._mui_quality = info.quality
                btn._mui_qualityR = r
                btn._mui_qualityG = g
                btn._mui_qualityB = b
                btn:SetBackdropBorderColor(r, g, b, 1)
            else
                btn._mui_quality = nil
                btn._mui_qualityR = nil
                btn._mui_qualityG = nil
                btn._mui_qualityB = nil
                btn:SetBackdropBorderColor(0, 0, 0, 1)
            end
        end
    end
end

local function UpdateLayout()
    -- Get settings
    local P = GetSpacing()
    local S = GetSlotSize()
    -- Use more columns for consolidated bag to make it wider/shorter
    local cols = GetConsolidatedColumns()
    local x, y = 0, 0
    local idx = 0
    
    local function PlaceButton(btn)
        if not InCombatLockdown() then
            btn:ClearAllPoints()
            btn:SetPoint("TOPLEFT", (x * (S + P)), -(y * (S + P)))
            btn:SetSize(S, S)
            btn:Show()
        end
        x = x + 1
        SetBagButtonPosition(btn, itemContainer, x, y, S, P)
        x = x + 1
        if x >= cols then x = 0; y = y + 1 end
    end

    local function ConfigureButton(btn, bagID, slotID)
        SetBagButtonAssignment(btn, bagID, slotID)
        UpdateBagButtonVisuals(btn, bagID, slotID)
    end

    if smartInventoryArrangeEnabled then
        local inventorySlots = {}
        for bagID = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slotID = 1, numSlots do
                inventorySlots[#inventorySlots + 1] = BuildSmartSortEntry(bagID, slotID)
            end
        end
        table_sort(inventorySlots, SmartSortEntryLess)

        for _, slotEntry in ipairs(inventorySlots) do
            idx = idx + 1
            local btn = itemFrames[idx]
            if not btn then
                if InCombatLockdown() then return end -- Cannot create secure frames in combat
                btn = ConstructBagButton(idx, itemContainer)
                itemFrames[idx] = btn
            end

            ConfigureButton(btn, slotEntry.bagID, slotEntry.slotID)
            PlaceButton(btn)
        end

        local reagentSlots = BuildSmartOrderedSlotsForBag(5)
        if #reagentSlots > 0 then
            if x > 0 then x = 0; y = y + 1 end
            reagentDivider:ClearAllPoints()
            reagentDivider:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 0, -(y * (S + P)) + 5)
            reagentDivider:SetPoint("RIGHT", 0, 0)
            reagentDivider:Show()
            y = y + 0.8

            for _, slotEntry in ipairs(reagentSlots) do
                idx = idx + 1
                local btn = itemFrames[idx]
                if not btn then
                    if InCombatLockdown() then return end
                    btn = ConstructBagButton(idx, itemContainer)
                    itemFrames[idx] = btn
                end

                ConfigureButton(btn, slotEntry.bagID, slotEntry.slotID)
                PlaceButton(btn)
            end
        else
            reagentDivider:Hide()
        end
    else
        -- 1. Standard Bags (0-4)
        for bagID = 0, 4 do
            local numSlots = C_Container.GetContainerNumSlots(bagID)
            for slotID = 1, numSlots do
                idx = idx + 1
                local btn = itemFrames[idx]
                if not btn then
                    if InCombatLockdown() then return end -- Cannot create secure frames in combat
                    btn = ConstructBagButton(idx, itemContainer)
                    itemFrames[idx] = btn
                end
                
                ConfigureButton(btn, bagID, slotID)
                PlaceButton(btn)
            end
        end
        
        -- 2. Reagents (Bag 5)
        local rSlots = C_Container.GetContainerNumSlots(5)
        if rSlots > 0 then
            if x > 0 then x = 0; y = y + 1 end
            reagentDivider:ClearAllPoints()
            reagentDivider:SetPoint("TOPLEFT", itemContainer, "TOPLEFT", 0, -(y * (S + P)) + 5)
            reagentDivider:SetPoint("RIGHT", 0, 0)
            reagentDivider:Show()
            y = y + 0.8 
            
            for slotID = 1, rSlots do
                idx = idx + 1
                local btn = itemFrames[idx]
                if not btn then
                    if InCombatLockdown() then return end
                    btn = ConstructBagButton(idx, itemContainer)
                    itemFrames[idx] = btn
                end
                
                ConfigureButton(btn, 5, slotID)
                PlaceButton(btn)
            end
        else
            reagentDivider:Hide()
        end
    end
    
    for i = idx + 1, #itemFrames do 
        HideBagButton(itemFrames[i])
    end
    
    local totalHeight = (y + 1) * (S + P) + 90
    local totalWidth = (cols * (S + P)) + 20
    BagWindow:SetSize(totalWidth, totalHeight)
    
    ApplyFilters()
end

searchBox:SetScript("OnTextChanged", ApplyFilters)

-- =========================================================================
--  7. FILTER BUTTONS
-- =========================================================================

local function CreateFilterButton(parent, icon, color, filterType, filterArg, tooltipText)
    local btn = CreateFrame("Button", nil, parent) 
    btn:SetSize(22, 22)
    local content = btn:CreateTexture(nil, "ARTWORK")
    content:SetSize(14, 14); content:SetPoint("CENTER")
    
    if color then
        content:SetTexture("Interface\\Buttons\\WHITE8x8"); content:SetVertexColor(unpack(color))
    elseif icon then
        content:SetTexture(icon); content:SetTexCoord(0.1, 0.9, 0.1, 0.9)
    end
    
    btn.glow = btn:CreateTexture(nil, "BACKGROUND")
    btn.glow:SetPoint("CENTER"); btn.glow:SetSize(26, 26)
    btn.glow:SetTexture("Interface\\Buttons\\UI-Ellipse-Browser-Stuff")
    btn.glow:SetVertexColor(1, 1, 1, 0.5); btn.glow:SetBlendMode("ADD"); btn.glow:Hide()
    
    btn:SetScript("OnClick", function()
        if activeFilter and activeFilter.arg == filterArg and activeFilter.type == filterType then 
            activeFilter = nil 
        else 
            activeFilter = { type = filterType, arg = filterArg } 
        end
        
        for _, b in pairs(footerButtons) do 
            local isActive = false
            if activeFilter then
                if activeFilter.arg == b.arg and activeFilter.type == b.filterType then
                    isActive = true
                elseif activeFilter.arg == nil and b.arg == nil and activeFilter.type == b.filterType then
                    isActive = true
                end
            end
            if b.glow then
                if isActive then b.glow:Show() else b.glow:Hide() end
            end
        end
        ApplyFilters()
    end)
    
    btn:SetScript("OnEnter", function(self)
        if tooltipText then
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(tooltipText, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    
    btn:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    
    btn.arg = filterArg
    btn.filterType = filterType
    table.insert(footerButtons, btn)
    return btn
end

local function InitFilters()
    local startX = 10
    local spacing = 5
    local maxVisibleButtons = 10 -- Increased to fit Hearthstone and Mythic+ Key filters
    
    -- Define all filters (primary filters shown first, overflow filters at end)
    local allFilters = {
        -- Primary Filters (always visible)
        {icon = nil, color = {0.6, 0.6, 0.6}, type = "QUALITY", arg = 0, tooltip = "Poor", primary = true},
        {icon = nil, color = {0.1, 1, 0.1}, type = "QUALITY", arg = 2, tooltip = "Uncommon", primary = true},
        {icon = nil, color = {0, 0.4, 1}, type = "QUALITY", arg = 3, tooltip = "Rare", primary = true},
        {icon = nil, color = {0.6, 0.2, 1}, type = "QUALITY", arg = 4, tooltip = "Epic", primary = true},
        {icon = "Interface\\Icons\\inv_misc_questionmark", color = nil, type = "CLASS", arg = 12, tooltip = "Quest", primary = true},
        {icon = "Interface\\Icons\\inv_chest_chain_04", color = nil, type = "EQUIPMENT", arg = nil, tooltip = "Equipment", primary = true},
        {icon = "Interface\\Icons\\inv_potion_93", color = nil, type = "CONSUMABLE", arg = nil, tooltip = "Consumables", primary = true},
        {icon = "Interface\\Icons\\inv_misc_coin_01", color = nil, type = "JUNK", arg = nil, tooltip = "Junk Items", primary = true},
        {icon = "Interface\\Icons\\inv_misc_rune_01", color = nil, type = "HEARTHSTONE", arg = nil, tooltip = "Hearthstones", primary = true},
        {icon = "Interface\\Icons\\inv_relics_hourglass", color = nil, type = "MYTHICKEY", arg = nil, tooltip = "Mythic+ Keys", primary = true},
        
        -- Overflow Filters
        {icon = "Interface\\Icons\\trade_engineering", color = nil, type = "TRADEGOODS", arg = nil, tooltip = "Trade Goods", primary = false},
        {icon = "Interface\\Icons\\inv_misc_toy_10", color = nil, type = "COSMETIC", arg = nil, tooltip = "Toys & Cosmetics", primary = false},
        {icon = "Interface\\Icons\\ability_spy", color = nil, type = "RECENT", arg = nil, tooltip = "Recent Items", primary = false},
        {icon = "Interface\\Icons\\inv_misc_bag_satchelofcenarius", color = nil, type = "REAGENT", arg = nil, tooltip = "All Reagents", primary = false},
        {icon = "Interface\\Icons\\inv_misc_enggizmos_17", color = nil, type = "BOE", arg = nil, tooltip = "Bind on Equip", primary = false},
        {icon = "Interface\\Icons\\achievement_guildperk_honorablemention_rank2", color = nil, type = "WARBOUND", arg = nil, tooltip = "Warbound/BoA", primary = false},
    }
    
    -- Create visible buttons
    local buttonCount = 0
    local lastButton = nil
    
    for i, filter in ipairs(allFilters) do
        if filter.primary and buttonCount < maxVisibleButtons then
            local btn = CreateFilterButton(Footer, filter.icon, filter.color, filter.type, filter.arg, filter.tooltip)
            if buttonCount == 0 then
                btn:SetPoint("LEFT", startX, 0)
            else
                btn:SetPoint("LEFT", lastButton, "RIGHT", spacing, 0)
            end
            lastButton = btn
            buttonCount = buttonCount + 1
        end
    end
    
    -- Create overflow button (...)
    overflowButton = CreateFrame("Button", nil, Footer)
    overflowButton:SetSize(22, 22)
    overflowButton:SetPoint("LEFT", lastButton, "RIGHT", spacing, 0)
    
    local overflowText = overflowButton:CreateFontString(nil, "OVERLAY")
    overflowText:SetFont(C.font, 14, "OUTLINE")
    overflowText:SetText("...")
    overflowText:SetPoint("CENTER", 0, -2)
    overflowText:SetTextColor(0.7, 0.7, 0.7)
    
    -- Create overflow menu
    overflowMenu = CreateFrame("Frame", nil, Footer, "BackdropTemplate")
    overflowMenu:SetSize(180, 200)
    overflowMenu:SetPoint("BOTTOM", overflowButton, "TOP", 0, 5)
    overflowMenu:SetFrameStrata("DIALOG")
    overflowMenu:SetFrameLevel(100)
    overflowMenu:EnableMouse(true)
    overflowMenu:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    overflowMenu:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
    overflowMenu:SetBackdropBorderColor(0, 0, 0, 1)
    overflowMenu:Hide()
    
    -- Add overflow filter buttons to menu
    local yOffset = -10
    for i, filter in ipairs(allFilters) do
        if not filter.primary then
            local menuBtn = CreateFrame("Button", nil, overflowMenu)
            menuBtn:SetSize(160, 28)
            menuBtn:SetPoint("TOP", 0, yOffset)
            menuBtn:SetFrameLevel(overflowMenu:GetFrameLevel() + 10)
            menuBtn:EnableMouse(true)
            menuBtn:RegisterForClicks("AnyUp")
            
            local icon = menuBtn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(20, 20)
            icon:SetPoint("LEFT", 8, 0)
            if filter.color then
                icon:SetTexture("Interface\\Buttons\\WHITE8x8")
                icon:SetVertexColor(unpack(filter.color))
            elseif filter.icon then
                icon:SetTexture(filter.icon)
                icon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
            end
            
            local label = menuBtn:CreateFontString(nil, "OVERLAY")
            label:SetFont(C.font, 11)
            label:SetPoint("LEFT", icon, "RIGHT", 8, 0)
            label:SetText(filter.tooltip)
            label:SetTextColor(0.9, 0.9, 0.9)
            
            menuBtn.glow = menuBtn:CreateTexture(nil, "BACKGROUND")
            menuBtn.glow:SetAllPoints()
            menuBtn.glow:SetTexture("Interface\\Buttons\\WHITE8x8")
            menuBtn.glow:SetVertexColor(1, 1, 1, 0.1)
            menuBtn.glow:Hide()
            
            menuBtn:SetScript("OnEnter", function(self)
                self.glow:Show()
            end)
            menuBtn:SetScript("OnLeave", function(self)
                if not (activeFilter and activeFilter.arg == filter.arg and activeFilter.type == filter.type) then
                    self.glow:Hide()
                end
            end)
            
            menuBtn:SetScript("OnClick", function(self)
                -- Toggle filter on/off
                if activeFilter and activeFilter.arg == filter.arg and activeFilter.type == filter.type then
                    activeFilter = nil
                elseif activeFilter and filter.arg == nil and activeFilter.type == filter.type then
                    -- Special case for filters with no arg (like EQUIPMENT, CONSUMABLE, etc)
                    activeFilter = nil
                else
                    activeFilter = { type = filter.type, arg = filter.arg }
                end
                
                -- Update all button glows (both primary and overflow)
                for _, b in pairs(footerButtons) do
                    local bActive = false
                    if activeFilter then
                        -- Match by both type and arg
                        if b.filterType == activeFilter.type then
                            if (b.arg == activeFilter.arg) or (b.arg == nil and activeFilter.arg == nil) then
                                bActive = true
                            end
                        end
                    end
                    
                    if b.glow then
                        if bActive then b.glow:Show() else b.glow:Hide() end
                    end
                end
                
                ApplyFilters()
                overflowMenu:Hide()
            end)
            
            menuBtn.arg = filter.arg
            menuBtn.filterType = filter.type
            table.insert(footerButtons, menuBtn)
            
            yOffset = yOffset - 32
        end
    end
    
    -- Size overflow menu to content
    overflowMenu:SetHeight(math.abs(yOffset) + 10)
    
    -- Toggle overflow menu
    overflowButton:SetScript("OnClick", function()
        if overflowMenu:IsShown() then
            overflowMenu:Hide()
        else
            overflowMenu:Show()
        end
    end)
    
    overflowButton:SetScript("OnEnter", function(self)
        overflowText:SetTextColor(1, 1, 1)
    end)
    overflowButton:SetScript("OnLeave", function(self)
        overflowText:SetTextColor(0.7, 0.7, 0.7)
    end)
    
    -- Hide overflow menu when clicking elsewhere
    overflowMenu:SetScript("OnShow", function()
        -- Use a global hook instead of a blocking frame
        if not overflowMenu.globalClickHandler then
            overflowMenu.globalClickHandler = CreateFrame("Frame")
            overflowMenu.globalClickHandler:SetScript("OnUpdate", function(self)
                if IsMouseButtonDown() then
                    if not self.wasDown then
                        self.wasDown = true
                        -- Check if click is inside the overflow menu
                        local x, y = GetCursorPosition()
                        local scale = overflowMenu:GetEffectiveScale()
                        x = x / scale
                        y = y / scale
                        
                        local left = overflowMenu:GetLeft()
                        local right = overflowMenu:GetRight()
                        local top = overflowMenu:GetTop()
                        local bottom = overflowMenu:GetBottom()
                        
                        -- Hide if click is outside the menu
                        if left and right and top and bottom then
                            if x < left or x > right or y < bottom or y > top then
                                overflowMenu:Hide()
                            end
                        end
                    end
                else
                    self.wasDown = false
                end
            end)
        end
        overflowMenu.globalClickHandler:Show()
    end)
    
    overflowMenu:SetScript("OnHide", function()
        if overflowMenu.globalClickHandler then
            overflowMenu.globalClickHandler:Hide()
        end
    end)
end

-- =========================================================================
--  8. MAIN CONTROL
-- =========================================================================

-- Check if separate bags mode is enabled
local function IsSeparateBagsEnabled()
    return _G.MidnightUISettings and 
           _G.MidnightUISettings.Inventory and 
           _G.MidnightUISettings.Inventory.separateBags == true
end

-- Create or get a separate bag window for a specific bag ID
local function GetOrCreateSeparateBagWindow(bagID)
    if separateBagWindows[bagID] then
        return separateBagWindows[bagID]
    end

    local window = CreateFrame("Frame", "MidnightBagWindow" .. bagID, UIParent, "BackdropTemplate")
    window:SetSize(200, 300)
    window:SetFrameStrata("HIGH")
    window:SetToplevel(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:Hide()
    
    CreateGlassBackdrop(window)
    AttachSeparateBagIdentityBadge(window, bagID)
    
    local windowCloseBtn = CreateFrame("Button", nil, window, "BackdropTemplate")
    windowCloseBtn:SetSize(24, 24)
    windowCloseBtn:SetPoint("TOPRIGHT", -8, -8)
    windowCloseBtn:SetText("X")
    windowCloseBtn:SetNormalFontObject("GameFontNormalSmall")
    -- Custom button styling (matching Diagnostics panel)
    local wcbBorder = windowCloseBtn:CreateTexture(nil, "BACKGROUND")
    wcbBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
    wcbBorder:SetVertexColor(0.18, 0.22, 0.30, 1.0)
    wcbBorder:SetPoint("TOPLEFT", 0, 0)
    wcbBorder:SetPoint("BOTTOMRIGHT", 0, 0)
    local wcbBg = windowCloseBtn:CreateTexture(nil, "BACKGROUND")
    wcbBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    wcbBg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    wcbBg:SetPoint("TOPLEFT", 2, -2)
    wcbBg:SetPoint("BOTTOMRIGHT", -2, 2)
    local wcbSheen = windowCloseBtn:CreateTexture(nil, "ARTWORK")
    wcbSheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    wcbSheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    wcbSheen:SetPoint("TOPLEFT", 3, -3)
    wcbSheen:SetPoint("BOTTOMRIGHT", -3, 12)
    local wcbHover = windowCloseBtn:CreateTexture(nil, "HIGHLIGHT")
    wcbHover:SetTexture("Interface\\Buttons\\WHITE8X8")
    wcbHover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    wcbHover:SetPoint("TOPLEFT", 2, -2)
    wcbHover:SetPoint("BOTTOMRIGHT", -2, 2)
    windowCloseBtn:SetNormalTexture("")
    windowCloseBtn:SetHighlightTexture(wcbHover)
    windowCloseBtn:SetPushedTexture("")
    windowCloseBtn:SetScript("OnClick", function()
        window:Hide()
        -- If no separate bag windows remain visible, also hide the invisible
        -- BagWindow so it doesn't eat the next Escape press.
        local anyVisible = false
        for _, w in pairs(separateBagWindows) do
            if w and w:IsShown() then anyVisible = true; break end
        end
        if not anyVisible then
            MidnightBags:Close()
        end
    end)

    local windowSortBtn = CreateFrame("Button", nil, window)
    windowSortBtn:SetSize(18, 18)
    windowSortBtn:SetPoint("RIGHT", windowCloseBtn, "LEFT", -10, 0)
    local windowSortIcon = windowSortBtn:CreateTexture(nil, "ARTWORK")
    ConfigureSortButton(windowSortBtn, windowSortIcon)
    
    -- Create item container for this bag
    window.itemContainer = CreateFrame("Frame", nil, window)
    window.itemContainer:SetPoint("TOPLEFT", 10, -34)
    window.itemContainer:SetPoint("BOTTOMRIGHT", -10, 40)
    
    -- Store item buttons for this bag
    window.itemButtons = {}
    
    separateBagWindows[bagID] = window
    return window
end

-- Forward declaration for ApplyFiltersSeparate (defined later)
local ApplyFiltersSeparate

-- Create the Backpack window with filters at the bottom
local function GetOrCreateBackpackWindow()
    if separateBagWindows[0] then
        return separateBagWindows[0]
    end
    
    local window = CreateFrame("Frame", "MidnightBagWindow0", UIParent, "BackdropTemplate")
    window:SetSize(200, 300)
    window:SetFrameStrata("HIGH")
    window:SetToplevel(true)
    window:EnableMouse(true)
    window:SetMovable(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:Hide()
    
    CreateGlassBackdrop(window)
    AttachSeparateBagIdentityBadge(window, 0)

    -- Search box in header
    local search = CreateFrame("EditBox", "MidnightSeparateBagSearch", window, "BackdropTemplate")
    search:SetSize(120, 20)
    search:SetPoint("TOPLEFT", 34, -10)
    search:SetFont(C.font, 10, "")
    search:SetAutoFocus(false)
    search:SetTextInsets(6, 0, 0, 0)
    CreateGlassBackdrop(search)
    search:SetBackdropColor(0, 0, 0, 0.5)
    
    local searchPlaceholder = search:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchPlaceholder:SetPoint("LEFT", 6, 0)
    searchPlaceholder:SetText("Search...")
    searchPlaceholder:SetTextColor(0.5, 0.5, 0.5)
    
    search:SetScript("OnEditFocusGained", function(self) searchPlaceholder:Hide() end)
    search:SetScript("OnEditFocusLost", function(self) if self:GetText()=="" then searchPlaceholder:Show() end end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnTextChanged", function(self)
        searchBox:SetText(self:GetText())
        if ApplyFiltersSeparate then ApplyFiltersSeparate() end
    end)
    
    window.searchBox = search
    
    local windowCloseBtn = CreateFrame("Button", nil, window, "BackdropTemplate")
    windowCloseBtn:SetSize(24, 24)
    windowCloseBtn:SetPoint("TOPRIGHT", -8, -8)
    windowCloseBtn:SetText("X")
    windowCloseBtn:SetNormalFontObject("GameFontNormalSmall")
    -- Custom button styling (matching Diagnostics panel)
    local bpbBorder = windowCloseBtn:CreateTexture(nil, "BACKGROUND")
    bpbBorder:SetTexture("Interface\\Buttons\\WHITE8X8")
    bpbBorder:SetVertexColor(0.18, 0.22, 0.30, 1.0)
    bpbBorder:SetPoint("TOPLEFT", 0, 0)
    bpbBorder:SetPoint("BOTTOMRIGHT", 0, 0)
    local bpbBg = windowCloseBtn:CreateTexture(nil, "BACKGROUND")
    bpbBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bpbBg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    bpbBg:SetPoint("TOPLEFT", 2, -2)
    bpbBg:SetPoint("BOTTOMRIGHT", -2, 2)
    local bpbSheen = windowCloseBtn:CreateTexture(nil, "ARTWORK")
    bpbSheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    bpbSheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    bpbSheen:SetPoint("TOPLEFT", 3, -3)
    bpbSheen:SetPoint("BOTTOMRIGHT", -3, 12)
    local bpbHover = windowCloseBtn:CreateTexture(nil, "HIGHLIGHT")
    bpbHover:SetTexture("Interface\\Buttons\\WHITE8X8")
    bpbHover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    bpbHover:SetPoint("TOPLEFT", 2, -2)
    bpbHover:SetPoint("BOTTOMRIGHT", -2, 2)
    windowCloseBtn:SetNormalTexture("")
    windowCloseBtn:SetHighlightTexture(bpbHover)
    windowCloseBtn:SetPushedTexture("")
    windowCloseBtn:SetScript("OnClick", function() MidnightBags:Close() end)

    local windowSortBtn = CreateFrame("Button", nil, window)
    windowSortBtn:SetSize(18, 18)
    windowSortBtn:SetPoint("RIGHT", windowCloseBtn, "LEFT", -10, 0)
    local windowSortIcon = windowSortBtn:CreateTexture(nil, "ARTWORK")
    ConfigureSortButton(windowSortBtn, windowSortIcon)

    search:ClearAllPoints()
    search:SetPoint("RIGHT", windowSortBtn, "LEFT", -8, 0)
    search:SetWidth(112)
    
    -- Create item container for this bag (with space for filter bar)
    window.itemContainer = CreateFrame("Frame", nil, window)
    window.itemContainer:SetPoint("TOPLEFT", 10, -34)
    window.itemContainer:SetPoint("BOTTOMRIGHT", -10, 45)  -- Space for filter bar
    
    -- Store item buttons for this bag
    window.itemButtons = {}
    
    -- Create filter footer for backpack (single row)
    local filterFooter = CreateFrame("Frame", nil, window)
    filterFooter:SetPoint("BOTTOMLEFT", 0, 0)
    filterFooter:SetPoint("BOTTOMRIGHT", 0, 0)
    filterFooter:SetHeight(40)

    local moneyTextSeparate = filterFooter:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    moneyTextSeparate:SetPoint("RIGHT", -10, 0)
    moneyTextSeparate:SetJustifyH("RIGHT")
    if C and C.font then
        moneyTextSeparate:SetFont(C.font, 11, "")
    end
    moneyTextSeparate:Hide()

    local moneyHoverSeparate = CreateFrame("Frame", nil, filterFooter)
    moneyHoverSeparate:SetFrameLevel(filterFooter:GetFrameLevel() + 10)
    AttachCurrencySummaryTooltip(moneyHoverSeparate)
    moneyHoverSeparate:Hide()

    local moneyIconSeparate = CreateFrame("Button", nil, filterFooter)
    moneyIconSeparate:SetSize(16, 16)
    moneyIconSeparate:SetPoint("RIGHT", filterFooter, "RIGHT", -10, 0)
    local moneyIconTexture = moneyIconSeparate:CreateTexture(nil, "ARTWORK")
    moneyIconTexture:SetAllPoints()
    moneyIconTexture:SetTexture("Interface\\MoneyFrame\\UI-GoldIcon")
    moneyIconSeparate:Hide()
    AttachCurrencySummaryTooltip(moneyIconSeparate)

    local filterButtons = {}
    local overflowButtons = {}
    local allFilters = {
        {icon = nil, color = {0.6, 0.6, 0.6}, type = "QUALITY", arg = 0, tooltip = "Poor"},
        {icon = nil, color = {0.1, 1, 0.1}, type = "QUALITY", arg = 2, tooltip = "Uncommon"},
        {icon = nil, color = {0, 0.4, 1}, type = "QUALITY", arg = 3, tooltip = "Rare"},
        {icon = nil, color = {0.6, 0.2, 1}, type = "QUALITY", arg = 4, tooltip = "Epic"},
        {icon = "Interface\\Icons\\inv_misc_questionmark", color = nil, type = "CLASS", arg = 12, tooltip = "Quest"},
        {icon = "Interface\\Icons\\inv_chest_chain_04", color = nil, type = "EQUIPMENT", arg = nil, tooltip = "Equipment"},
        {icon = "Interface\\Icons\\inv_potion_93", color = nil, type = "CONSUMABLE", arg = nil, tooltip = "Consumables"},
        {icon = "Interface\\Icons\\inv_misc_coin_01", color = nil, type = "JUNK", arg = nil, tooltip = "Junk"},
        {icon = "Interface\\Icons\\inv_misc_rune_01", color = nil, type = "HEARTHSTONE", arg = nil, tooltip = "Hearthstones"},
        {icon = "Interface\\Icons\\inv_relics_hourglass", color = nil, type = "MYTHICKEY", arg = nil, tooltip = "Mythic+ Keys"},
    }

    local overflowButtonSeparate = CreateFrame("Button", nil, filterFooter)
    overflowButtonSeparate:SetSize(22, 22)
    local overflowTextSeparate = overflowButtonSeparate:CreateFontString(nil, "OVERLAY")
    overflowTextSeparate:SetFont(C.font, 14, "OUTLINE")
    overflowTextSeparate:SetText("...")
    overflowTextSeparate:SetPoint("CENTER", 0, -2)
    overflowTextSeparate:SetTextColor(0.7, 0.7, 0.7)
    overflowButtonSeparate:Hide()

    local overflowMenuSeparate = CreateFrame("Frame", nil, filterFooter, "BackdropTemplate")
    overflowMenuSeparate:SetSize(180, 200)
    overflowMenuSeparate:SetPoint("BOTTOMLEFT", overflowButtonSeparate, "TOPLEFT", 0, 5)
    overflowMenuSeparate:SetFrameStrata("DIALOG")
    overflowMenuSeparate:SetFrameLevel(100)
    overflowMenuSeparate:EnableMouse(true)
    overflowMenuSeparate:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    overflowMenuSeparate:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
    overflowMenuSeparate:SetBackdropBorderColor(0, 0, 0, 1)
    overflowMenuSeparate:Hide()
    overflowMenuSeparate:SetScript("OnShow", function()
        if not overflowMenuSeparate.globalClickHandler then
            overflowMenuSeparate.globalClickHandler = CreateFrame("Frame")
            overflowMenuSeparate.globalClickHandler:SetScript("OnUpdate", function(self)
                if IsMouseButtonDown() then
                    if not self.wasDown then
                        self.wasDown = true
                        local x, y = GetCursorPosition()
                        local scale = overflowMenuSeparate:GetEffectiveScale()
                        x = x / scale
                        y = y / scale

                        local left = overflowMenuSeparate:GetLeft()
                        local right = overflowMenuSeparate:GetRight()
                        local top = overflowMenuSeparate:GetTop()
                        local bottom = overflowMenuSeparate:GetBottom()

                        if left and right and top and bottom then
                            if x < left or x > right or y < bottom or y > top then
                                overflowMenuSeparate:Hide()
                            end
                        end
                    end
                else
                    self.wasDown = false
                end
            end)
        end
        overflowMenuSeparate.globalClickHandler:Show()
    end)
    overflowMenuSeparate:SetScript("OnHide", function()
        if overflowMenuSeparate.globalClickHandler then
            overflowMenuSeparate.globalClickHandler:Hide()
        end
    end)

    local function IsButtonActive(btn)
        if not activeFilter then return false end
        if activeFilter.type ~= btn.filterType then return false end
        if activeFilter.arg == btn.arg then return true end
        return activeFilter.arg == nil and btn.arg == nil
    end

    local function UpdateFilterGlows()
        for _, b in ipairs(filterButtons) do
            if b.glow then
                if IsButtonActive(b) then b.glow:Show() else b.glow:Hide() end
            end
        end

        for _, b in pairs(footerButtons) do
            local isActive = false
            if activeFilter then
                if activeFilter.arg == b.arg and activeFilter.type == b.filterType then
                    isActive = true
                elseif activeFilter.arg == nil and b.arg == nil and activeFilter.type == b.filterType then
                    isActive = true
                end
            end
            if b.glow then
                if isActive then b.glow:Show() else b.glow:Hide() end
            end
        end

        local hiddenActive = false
        for _, b in ipairs(filterButtons) do
            if b._hiddenByLayout and IsButtonActive(b) then
                hiddenActive = true
                break
            end
        end
        if hiddenActive then
            overflowTextSeparate:SetTextColor(1, 1, 1)
        else
            overflowTextSeparate:SetTextColor(0.7, 0.7, 0.7)
        end
    end

    local function ToggleFilterSelection(filterType, filterArg, tooltip)
        if activeFilter and activeFilter.arg == filterArg and activeFilter.type == filterType then
            activeFilter = nil
        else
            activeFilter = { type = filterType, arg = filterArg }
        end
        UpdateFilterGlows()
        if ApplyFiltersSeparate then ApplyFiltersSeparate() end
    end

    for _, filter in ipairs(allFilters) do
        local btn = CreateFrame("Button", nil, filterFooter)
        btn:SetSize(22, 22)

        local content = btn:CreateTexture(nil, "ARTWORK")
        content:SetSize(14, 14)
        content:SetPoint("CENTER")

        if filter.color then
            content:SetTexture("Interface\\Buttons\\WHITE8x8")
            content:SetVertexColor(unpack(filter.color))
        elseif filter.icon then
            content:SetTexture(filter.icon)
            content:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        end

        btn.glow = btn:CreateTexture(nil, "BACKGROUND")
        btn.glow:SetPoint("CENTER")
        btn.glow:SetSize(28, 28)
        btn.glow:SetTexture("Interface\\Buttons\\UI-Ellipse-Browser-Stuff")
        btn.glow:SetVertexColor(1, 1, 1, 0.5)
        btn.glow:SetBlendMode("ADD")
        btn.glow:Hide()

        btn:SetScript("OnClick", function()
            ToggleFilterSelection(filter.type, filter.arg, filter.tooltip)
        end)

        btn:SetScript("OnEnter", function(self)
            if filter.tooltip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(filter.tooltip, 1, 1, 1)
                GameTooltip:Show()
            end
        end)

        btn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        btn.arg = filter.arg
        btn.filterType = filter.type
        table.insert(filterButtons, btn)

        local menuBtn = CreateFrame("Button", nil, overflowMenuSeparate)
        menuBtn:SetSize(160, 28)
        menuBtn:SetFrameLevel(overflowMenuSeparate:GetFrameLevel() + 10)
        menuBtn:EnableMouse(true)
        menuBtn:RegisterForClicks("AnyUp")

        local menuIcon = menuBtn:CreateTexture(nil, "ARTWORK")
        menuIcon:SetSize(20, 20)
        menuIcon:SetPoint("LEFT", 8, 0)
        if filter.color then
            menuIcon:SetTexture("Interface\\Buttons\\WHITE8x8")
            menuIcon:SetVertexColor(unpack(filter.color))
        elseif filter.icon then
            menuIcon:SetTexture(filter.icon)
            menuIcon:SetTexCoord(0.1, 0.9, 0.1, 0.9)
        end

        local menuLabel = menuBtn:CreateFontString(nil, "OVERLAY")
        menuLabel:SetFont(C.font, 11)
        menuLabel:SetPoint("LEFT", menuIcon, "RIGHT", 8, 0)
        menuLabel:SetText(filter.tooltip)
        menuLabel:SetTextColor(0.9, 0.9, 0.9)

        menuBtn.glow = menuBtn:CreateTexture(nil, "BACKGROUND")
        menuBtn.glow:SetAllPoints()
        menuBtn.glow:SetTexture("Interface\\Buttons\\WHITE8x8")
        menuBtn.glow:SetVertexColor(1, 1, 1, 0.1)
        menuBtn.glow:Hide()

        menuBtn:SetScript("OnEnter", function(self)
            self.glow:Show()
        end)
        menuBtn:SetScript("OnLeave", function(self)
            if not IsButtonActive(self) then
                self.glow:Hide()
            end
        end)
        menuBtn:SetScript("OnClick", function()
            ToggleFilterSelection(filter.type, filter.arg, filter.tooltip)
            overflowMenuSeparate:Hide()
        end)

        menuBtn.arg = filter.arg
        menuBtn.filterType = filter.type
        table.insert(overflowButtons, menuBtn)
    end

    local function GetVisibleFilterCountForReserve(footerWidth, rightReserveWidth, buttonSize, spacing, leftPadding, totalFilters)
        local available = math.max(0, footerWidth - leftPadding - rightReserveWidth)
        local slotWidth = buttonSize + spacing
        local maxSlots = math.floor((available + spacing) / slotWidth)
        local showOverflow = maxSlots < totalFilters
        local visibleCount = totalFilters
        if showOverflow then
            visibleCount = math.max(0, maxSlots - 1)
        else
            visibleCount = math.min(totalFilters, maxSlots)
        end
        return visibleCount, showOverflow, slotWidth
    end

    local function UpdateFooterLayout()
        local buttonSize = 22
        local spacing = 4
        local leftPadding = 10
        local rightPadding = 10
        local gapBeforeMoney = 12
        local footerWidth = filterFooter:GetWidth() or 0
        local totalFilters = #filterButtons

        if footerWidth <= 0 then
            return
        end

        local money = window._moneyValue or GetMoney()
        moneyTextSeparate:SetText(GetMoneyString(money, true))
        local fullMoneyWidth = moneyTextSeparate:GetStringWidth() or 0
        local iconWidth = moneyIconSeparate:GetWidth() or 16

        local reserveForText = rightPadding + fullMoneyWidth + gapBeforeMoney
        local reserveForIcon = rightPadding + iconWidth + gapBeforeMoney
        local minFiltersForTextMode = 3

        local visibleWithText = GetVisibleFilterCountForReserve(footerWidth, reserveForText, buttonSize, spacing, leftPadding, totalFilters)
        local useTextMode = visibleWithText >= minFiltersForTextMode

        local rightReserve = useTextMode and reserveForText or reserveForIcon
        local visibleCount, showOverflow, slotWidth = GetVisibleFilterCountForReserve(
            footerWidth,
            rightReserve,
            buttonSize,
            spacing,
            leftPadding,
            totalFilters
        )

        if useTextMode then
            moneyTextSeparate:Show()
            moneyIconSeparate:Hide()

            local hoverWidth = math.max(22, fullMoneyWidth + 8)
            moneyHoverSeparate:ClearAllPoints()
            moneyHoverSeparate:SetPoint("RIGHT", moneyTextSeparate, "RIGHT", 2, 0)
            moneyHoverSeparate:SetPoint("TOP", moneyTextSeparate, "TOP", 0, 4)
            moneyHoverSeparate:SetPoint("BOTTOM", moneyTextSeparate, "BOTTOM", 0, -4)
            moneyHoverSeparate:SetWidth(hoverWidth)
            moneyHoverSeparate:Show()
        else
            moneyTextSeparate:Hide()
            moneyHoverSeparate:Hide()
            moneyIconSeparate:Show()
            moneyIconSeparate:ClearAllPoints()
            moneyIconSeparate:SetPoint("RIGHT", filterFooter, "RIGHT", -10, 0)
        end

        local x = leftPadding
        for i, btn in ipairs(filterButtons) do
            btn:ClearAllPoints()
            if i <= visibleCount then
                btn:SetPoint("LEFT", filterFooter, "LEFT", x, 0)
                btn:Show()
                btn._hiddenByLayout = false
                x = x + slotWidth
            else
                btn:Hide()
                btn._hiddenByLayout = true
            end
        end

        local hiddenIndex = 0
        for i, menuBtn in ipairs(overflowButtons) do
            menuBtn:ClearAllPoints()
            if filterButtons[i] and filterButtons[i]._hiddenByLayout then
                hiddenIndex = hiddenIndex + 1
                menuBtn:SetPoint("TOP", 0, -10 - ((hiddenIndex - 1) * 32))
                menuBtn:Show()
                if IsButtonActive(menuBtn) then
                    menuBtn.glow:Show()
                else
                    menuBtn.glow:Hide()
                end
            else
                menuBtn:Hide()
                menuBtn.glow:Hide()
            end
        end

        if showOverflow and hiddenIndex > 0 then
            local rightAnchor = useTextMode and moneyTextSeparate or moneyIconSeparate
            overflowButtonSeparate:ClearAllPoints()
            if visibleCount > 0 then
                overflowButtonSeparate:SetPoint("LEFT", filterFooter, "LEFT", x, 0)
            else
                overflowButtonSeparate:SetPoint("RIGHT", rightAnchor, "LEFT", -6, 0)
            end
            overflowButtonSeparate:Show()
            overflowButtonSeparate._hiddenCount = hiddenIndex
            overflowMenuSeparate:SetHeight((hiddenIndex * 32) + 12)
        else
            overflowButtonSeparate:Hide()
            overflowButtonSeparate._hiddenCount = 0
            overflowMenuSeparate:Hide()
        end

        UpdateFilterGlows()
    end

    overflowButtonSeparate:SetScript("OnClick", function(self)
        if not self._hiddenCount or self._hiddenCount <= 0 then
            overflowMenuSeparate:Hide()
            return
        end
        if overflowMenuSeparate:IsShown() then
            overflowMenuSeparate:Hide()
        else
            overflowMenuSeparate:Show()
        end
    end)
    overflowButtonSeparate:SetScript("OnEnter", function()
        overflowTextSeparate:SetTextColor(1, 1, 1)
    end)
    overflowButtonSeparate:SetScript("OnLeave", function()
        UpdateFilterGlows()
    end)

    window:SetScript("OnSizeChanged", function(self)
        if self._muiBadge then
            if self:GetWidth() < 220 then
                self._muiBadge:Hide()
            else
                self._muiBadge:Show()
            end
        end
        if self.UpdateFooterLayout then
            self:UpdateFooterLayout()
        end
    end)

    window.filterButtons = filterButtons
    window.filterOverflowButtons = overflowButtons
    window.footerMoneyText = moneyTextSeparate
    window.UpdateFooterLayout = UpdateFooterLayout
    window.UpdateMoney = function(self)
        self._moneyValue = GetMoney()
        if self.UpdateFooterLayout then
            self:UpdateFooterLayout()
        end
    end
    window:UpdateMoney()
    separateBagWindows[0] = window
    return window
end

-- Apply filters to separate bag windows
ApplyFiltersSeparate = function()
    local query = searchBox:GetText():lower()
    
    
    local totalButtons = 0
    local matchedButtons = 0
    local filteredButtons = 0
    
    for bagID = 0, 5 do
        local window = separateBagWindows[bagID]
        if window and window.itemButtons then
            
            for slotID, btn in pairs(window.itemButtons) do
                if btn:IsShown() and btn.bagID and btn.slotID then
                    totalButtons = totalButtons + 1
                    local info = C_Container.GetContainerItemInfo(btn.bagID, btn.slotID)
                    local matches = true
                    
                    if query ~= "" then
                        if info then
                            local name = C_Item.GetItemInfo(info.hyperlink) or ""
                            if not name:lower():find(query) then matches = false end
                        else
                            matches = false
                        end
                    end
                    
                    if matches and activeFilter and info then
                        local _, _, _, _, _, classID, subClassID = C_Item.GetItemInfoInstant(info.itemID)
                        
                        if activeFilter.type == "QUALITY" then 
                            if info.quality ~= activeFilter.arg then matches = false end
                        elseif activeFilter.type == "CLASS" then
                            if classID ~= activeFilter.arg then matches = false end
                        elseif activeFilter.type == "EQUIPMENT" then
                            if not (classID == 2 or classID == 4) then matches = false end
                        elseif activeFilter.type == "CONSUMABLE" then
                            if classID ~= 0 then matches = false end
                        elseif activeFilter.type == "JUNK" then
                            if not info.isJunk then matches = false end
                        elseif activeFilter.type == "TRADEGOODS" then
                            if classID ~= 7 then matches = false end
                        elseif activeFilter.type == "COSMETIC" then
                            if not (classID == 15 or (classID == 4 and subClassID == 4)) then matches = false end
                        elseif activeFilter.type == "RECENT" then
                            if not C_NewItems.IsNewItem(btn.bagID, btn.slotID) then matches = false end
                        elseif activeFilter.type == "REAGENT" then
                            local isReagent = false
                            if btn.bagID == 5 then
                                isReagent = true
                            elseif classID == 7 then
                                isReagent = true
                            else
                                local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                                if itemLink then
                                    local itemQuality = info.quality
                                    if (classID == 0 or classID == 15) and itemQuality and itemQuality <= 1 then
                                        isReagent = true
                                    end
                                end
                            end
                            if not isReagent then matches = false end
                        elseif activeFilter.type == "BOE" then
                            local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                            local isBOE = false
                            if tooltipData and tooltipData.lines then
                                for _, line in ipairs(tooltipData.lines) do
                                    if line.leftText and (line.leftText:find("Bind") or line.leftText:find("Equip")) then
                                        if line.leftText:find("Binds when equipped") then
                                            isBOE = true
                                            break
                                        end
                                    end
                                end
                            end
                            if not isBOE then matches = false end
                        elseif activeFilter.type == "WARBOUND" then
                            local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                            local isWarbound = false
                            if tooltipData and tooltipData.lines then
                                for _, line in ipairs(tooltipData.lines) do
                                    if line.leftText then
                                        local text = line.leftText
                                        if text:find("Warbound") or text:find("Account") or 
                                           text:find("Binds to account") or text:find("Binds to Battle") then
                                            isWarbound = true
                                            break
                                        end
                                    end
                                end
                            end
                            if not isWarbound then matches = false end
                        elseif activeFilter.type == "HEARTHSTONE" then
                            local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                            local isHearthstone = false
                            if itemLink then
                                local itemName = C_Item.GetItemInfo(itemLink)
                                if itemName and (itemName:find("Hearthstone") or itemName:find("Dalaran Hearthstone") or 
                                   itemName:find("Garrison Hearthstone") or itemName:find("Tome of Town Portal")) then
                                    isHearthstone = true
                                end
                                local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                                if tooltipData and tooltipData.lines then
                                    for _, line in ipairs(tooltipData.lines) do
                                        if line.leftText then
                                            local text = line.leftText:lower()
                                            if text:find("return") and text:find("home") or 
                                               text:find("teleport") and text:find("home") or
                                               text:find("hearthstone") then
                                                isHearthstone = true
                                                break
                                            end
                                        end
                                    end
                                end
                            end
                            if not isHearthstone then matches = false end
                        elseif activeFilter.type == "MYTHICKEY" then
                            local itemLink = C_Container.GetContainerItemLink(btn.bagID, btn.slotID)
                            local isMythicKey = false
                            if itemLink then
                                local itemName = C_Item.GetItemInfo(itemLink)
                                local itemID = info.itemID
                                if itemID == 158923 or (itemName and itemName:find("Keystone")) then
                                    isMythicKey = true
                                end
                                if not isMythicKey then
                                    local tooltipData = C_TooltipInfo.GetBagItem(btn.bagID, btn.slotID)
                                    if tooltipData and tooltipData.lines then
                                        for _, line in ipairs(tooltipData.lines) do
                                            if line.leftText then
                                                local text = line.leftText
                                                if text:find("Mythic Keystone") or text:find("Keystone Level") then
                                                    isMythicKey = true
                                                    break
                                                end
                                            end
                                        end
                                    end
                                end
                            end
                            if not isMythicKey then matches = false end
                        end
                    elseif matches and activeFilter and not info then
                        matches = false 
                    end

                    if matches then
                        btn:SetAlpha(1)
                        if not btn:IsEnabled() then btn:Enable() end
                        matchedButtons = matchedButtons + 1
                    else
                        btn:SetAlpha(0.1)
                        if btn:IsEnabled() then btn:Disable() end
                        filteredButtons = filteredButtons + 1
                    end
                    
                    if info and info.quality and info.quality > 1 then
                        local r, g, b = GetItemQualityColor(info.quality)
                        btn:SetBackdropBorderColor(r, g, b, 1)
                    else
                        btn:SetBackdropBorderColor(0, 0, 0, 1)
                    end
                end
            end
        end
    end
    
end

-- Update layout for separate bag windows
local function UpdateSeparateBagsLayout()
    -- Get settings
    local P = GetSpacing()
    local S = GetSlotSize()
    local cols = separateLayoutColsOverride or GetColumns()
    cols = math_max(1, math_floor(cols or 1))
    
    -- Process each bag separately
    for bagID = 0, 5 do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots > 0 then
            -- Use special Backpack window for bag 0 (with filter bar)
            local window
            if bagID == 0 then
                window = GetOrCreateBackpackWindow()
            else
                window = GetOrCreateSeparateBagWindow(bagID)
            end
            
            local x, y = 0, 0
            local usedButtons = 0
            if smartInventoryArrangeEnabled then
                local orderedSlots = BuildSmartOrderedSlotsForBag(bagID)

                for visualIndex, slotEntry in ipairs(orderedSlots) do
                    local btn = window.itemButtons[visualIndex]
                    if not btn then
                        if InCombatLockdown() then return end
                        btn = ConstructBagButton(bagID * 100 + visualIndex, window.itemContainer)
                        window.itemButtons[visualIndex] = btn
                    end

                    SetBagButtonAssignment(btn, bagID, slotEntry.slotID)
                    UpdateBagButtonVisuals(btn, bagID, slotEntry.slotID)
                    SetBagButtonPosition(btn, window.itemContainer, x, y, S, P)

                    usedButtons = visualIndex
                    x = x + 1
                    if x >= cols then x = 0; y = y + 1 end
                end
            else
                for slotID = 1, numSlots do
                    usedButtons = usedButtons + 1
                    local btn = window.itemButtons[usedButtons]
                    if not btn then
                        if InCombatLockdown() then return end
                        btn = ConstructBagButton(bagID * 100 + usedButtons, window.itemContainer)
                        window.itemButtons[usedButtons] = btn
                    end

                    SetBagButtonAssignment(btn, bagID, slotID)
                    UpdateBagButtonVisuals(btn, bagID, slotID)
                    SetBagButtonPosition(btn, window.itemContainer, x, y, S, P)

                    x = x + 1
                    if x >= cols then x = 0; y = y + 1 end
                end
            end
            
            -- Hide unused buttons
            for i = usedButtons + 1, #window.itemButtons do
                HideBagButton(window.itemButtons[i])
            end
            
            -- Size the window (Backpack has extra height for filter bar)
            local rows = math_ceil(usedButtons / cols)
            local totalHeight = (rows * (S + P)) + (bagID == 0 and 95 or 60)
            local totalWidth = (cols * (S + P)) + 20
            window:SetSize(totalWidth, totalHeight)
            if bagID == 0 and window.UpdateFooterLayout then
                window:UpdateFooterLayout()
            end
        else
            local window = separateBagWindows[bagID]
            if window then
                window:Hide()
            end
        end
    end
end

-- Close all separate bag windows
local function CloseSeparateBagWindows()
    for bagID, window in pairs(separateBagWindows) do
        if window then
            window:Hide()
        end
    end
    separateLayoutColsOverride = nil
end

local function AnySeparateWindowVisible()
    for bagID = 0, 5 do
        local window = separateBagWindows[bagID]
        if window and window:IsShown() then
            return true
        end
    end
    return false
end

local function SyncBackpackFilterBarState()
    local backpackWindow = separateBagWindows[0]
    if not backpackWindow then return end

    if backpackWindow.searchBox then
        local query = searchBox:GetText() or ""
        if backpackWindow.searchBox:GetText() ~= query then
            backpackWindow.searchBox:SetText(query)
        end
    end

    if backpackWindow.filterButtons then
        for _, b in ipairs(backpackWindow.filterButtons) do
            local isActive = false
            if activeFilter then
                if activeFilter.arg == b.arg and activeFilter.type == b.filterType then
                    isActive = true
                elseif activeFilter.arg == nil and b.arg == nil and activeFilter.type == b.filterType then
                    isActive = true
                end
            end
            if b.glow then
                if isActive then b.glow:Show() else b.glow:Hide() end
            end
        end
    end
end

local function BuildSeparateLayoutPlan(cols, S, P, requestedWindowColumns)
    local rightMargin = 20
    local leftMargin = 20
    local bottomMargin = 100
    local topMargin = 40
    local columnGap = 20
    local rowGap = 10
    local orderedBags = {0, 2, 3, 4, 5, 1}

    local screenW = UIParent:GetWidth() or 1920
    local screenH = UIParent:GetHeight() or 1080
    local availableW = math.max(100, screenW - leftMargin - rightMargin)
    local availableH = math.max(100, screenH - bottomMargin - topMargin)
    local cell = math.max(1, S + P)
    local windowWidth = (cols * cell) + 20

    if windowWidth > availableW then
        return nil
    end

    local maxWindowColumns = math.max(1, math.floor((availableW + columnGap) / (windowWidth + columnGap)))
    local windowColumns = math.max(1, math.min(requestedWindowColumns or maxWindowColumns, maxWindowColumns))
    local columnHeights = {}
    local bagCounts = {}
    for c = 1, windowColumns do
        columnHeights[c] = 0
        bagCounts[c] = 0
    end

    local placements = {}
    local overflow = 0

    local function PickColumnForHeight(windowHeight, forcedColumn)
        if forcedColumn then
            local c = math.max(1, math.min(forcedColumn, windowColumns))
            local gap = columnHeights[c] > 0 and rowGap or 0
            local projected = columnHeights[c] + gap + windowHeight
            return c, projected
        end

        local bestFitColumn, bestFitProjected = nil, nil
        local bestAnyColumn, bestAnyProjected = nil, nil

        for c = 1, windowColumns do
            local gap = columnHeights[c] > 0 and rowGap or 0
            local projected = columnHeights[c] + gap + windowHeight

            if (not bestAnyProjected) or projected < bestAnyProjected or (projected == bestAnyProjected and c < bestAnyColumn) then
                bestAnyColumn = c
                bestAnyProjected = projected
            end

            if projected <= availableH then
                if (not bestFitProjected) or projected < bestFitProjected or (projected == bestFitProjected and c < bestFitColumn) then
                    bestFitColumn = c
                    bestFitProjected = projected
                end
            end
        end

        if bestFitColumn then
            return bestFitColumn, bestFitProjected
        end
        return bestAnyColumn, bestAnyProjected
    end

    for _, bagID in ipairs(orderedBags) do
        local numSlots = C_Container.GetContainerNumSlots(bagID)
        if numSlots > 0 then
            local rows = math.ceil(numSlots / cols)
            local windowHeight = (rows * cell) + (bagID == 0 and 95 or 60)
            local forcedColumn = (bagID == 0) and 1 or nil
            local column, projectedHeight = PickColumnForHeight(windowHeight, forcedColumn)
            local gap = columnHeights[column] > 0 and rowGap or 0

            if projectedHeight > availableH then
                overflow = math.max(overflow, projectedHeight - availableH)
            end

            placements[bagID] = {
                column = column,
                yOffset = bottomMargin + columnHeights[column] + gap,
                height = windowHeight,
            }

            columnHeights[column] = projectedHeight
            bagCounts[column] = (bagCounts[column] or 0) + 1
        end
    end

    local usedColumns = 1
    local minHeight, maxHeight = nil, nil
    local singleBagColumns = 0
    for c = 1, windowColumns do
        if (bagCounts[c] or 0) > 0 then
            usedColumns = math.max(usedColumns, c)
            if bagCounts[c] == 1 then
                singleBagColumns = singleBagColumns + 1
            end
            local h = columnHeights[c]
            if not minHeight or h < minHeight then minHeight = h end
            if not maxHeight or h > maxHeight then maxHeight = h end
        end
    end
    local heightSpread = 0
    if minHeight and maxHeight then
        heightSpread = maxHeight - minHeight
    end

    for c = windowColumns, 1, -1 do
        if (bagCounts[c] or 0) > 0 then
            usedColumns = c
            break
        end
    end

    return {
        cols = cols,
        placements = placements,
        windowWidth = windowWidth,
        rightMargin = rightMargin,
        bottomMargin = bottomMargin,
        topMargin = topMargin,
        columnGap = columnGap,
        screenH = screenH,
        overflow = overflow,
        heightSpread = heightSpread,
        singleBagColumns = singleBagColumns,
        bagCounts = bagCounts,
        windowColumns = windowColumns,
        maxWindowColumns = maxWindowColumns,
        usedColumns = usedColumns,
    }
end

local function BuildBestSeparateLayoutPlan(S, P)
    local rightMargin = 20
    local leftMargin = 20
    local screenW = UIParent:GetWidth() or 1920
    local availableW = math.max(100, screenW - leftMargin - rightMargin)
    local cell = math.max(1, S + P)
    local maxColsByWidth = math.max(1, math.floor((availableW - 20) / cell))

    local desiredCols = math.max(1, math.floor(GetColumns() or 1))
    desiredCols = math.min(desiredCols, maxColsByWidth)

    -- Keep bag slot columns aligned with the user's setting (width preference).
    -- Prefer the configured width, but probe alternates so tall windows can fit on-screen.
    local candidates, seen = {}, {}
    local function AddCandidate(v)
        if v and v >= 1 and v <= maxColsByWidth and not seen[v] then
            seen[v] = true
            candidates[#candidates + 1] = v
        end
    end
    AddCandidate(desiredCols)
    for v = desiredCols + 1, maxColsByWidth do AddCandidate(v) end
    for v = desiredCols - 1, 1, -1 do AddCandidate(v) end

    local bestPlan = nil
    local bestScore = nil
    for _, candidateCols in ipairs(candidates) do
        local probePlan = BuildSeparateLayoutPlan(candidateCols, S, P)
        if probePlan then
            local maxWindowColumns = probePlan.maxWindowColumns or 1
            for windowColumns = 1, maxWindowColumns do
                local plan = BuildSeparateLayoutPlan(candidateCols, S, P, windowColumns)
                if plan then
                    local overflowPenalty = math.max(0, plan.overflow or 0) * 1000000
                    local spreadPenalty = (plan.heightSpread or 0) * 100
                    local usedColumnsPenalty = math.max(0, (plan.usedColumns or 1) - 1) * 50
                    local sparsePenalty = (plan.singleBagColumns or 0) * 35
                    local preferencePenalty = math.abs(candidateCols - desiredCols) * 30
                    local score = overflowPenalty + spreadPenalty + usedColumnsPenalty + sparsePenalty + preferencePenalty

                    if (not bestScore) or score < bestScore then
                        bestScore = score
                        bestPlan = plan
                    end
                end
            end
        end
    end

    return bestPlan
end

local function ApplySeparateLayoutPlan(plan)
    if not plan then return end

    for bagID = 0, 5 do
        local window = separateBagWindows[bagID]
        local placement = plan.placements[bagID]
        if window then
            if placement then
                local x = -plan.rightMargin - ((placement.column - 1) * (plan.windowWidth + plan.columnGap))
                local y = placement.yOffset
                local maxY = plan.screenH - plan.topMargin - placement.height
                local minY = plan.bottomMargin

                if maxY < minY then
                    y = math.max(0, maxY)
                else
                    if y > maxY then y = maxY end
                    if y < minY then y = minY end
                end

                if not InCombatLockdown() then
                    window:ClearAllPoints()
                    window:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", x, y)
                end
                window:Show()
            else
                window:Hide()
            end
        end
    end
end

local function RefreshSeparateBagWindows()
    local S = GetSlotSize()
    local P = GetSpacing()
    local plan = BuildBestSeparateLayoutPlan(S, P)

    if plan and plan.cols then
        separateLayoutColsOverride = plan.cols
    else
        separateLayoutColsOverride = GetColumns()
    end

    UpdateSeparateBagsLayout()
    ApplySeparateLayoutPlan(plan)
    SyncBackpackFilterBarState()

    local backpackWindow = separateBagWindows[0]
    if backpackWindow and backpackWindow.UpdateMoney then
        backpackWindow:UpdateMoney()
    end
end

local function RefreshVisibleBagWindows()
    if IsSeparateBagsEnabled() then
        if AnySeparateWindowVisible() then
            RefreshSeparateBagWindows()
            if ApplyFiltersSeparate then ApplyFiltersSeparate() end
        end
    else
        if BagWindow:IsShown() then
            UpdateLayout()
        end
    end
end

local function QueueVisibleBagRefresh()
    if MidnightBags._queuedBagRefresh then return end
    MidnightBags._queuedBagRefresh = true
    local timerAPI = C_Timer and C_Timer.After

    local function IsCursorHoldingBagItem()
        if CursorHasItem and CursorHasItem() then
            return true
        end
        if GetCursorInfo then
            local cursorType = GetCursorInfo()
            if cursorType == "item" then
                return true
            end
        end
        return false
    end

    local function RunRefresh(clearQueue)
        -- Do not remap bag buttons while dragging/carrying an item on cursor.
        -- Mid-drag remaps can make drop targets point at different slots.
        if IsCursorHoldingBagItem() then
            if timerAPI then
                timerAPI(0.05, function() RunRefresh(clearQueue) end)
            elseif clearQueue then
                MidnightBags._queuedBagRefresh = false
            end
            return
        end

        RefreshVisibleBagWindows()
        if clearQueue then
            MidnightBags._queuedBagRefresh = false
        end
    end
    if timerAPI then
        -- Two-pass refresh captures delayed container updates (mail loot, slot swaps).
        timerAPI(0, function() RunRefresh(false) end)
        timerAPI(0.05, function() RunRefresh(true) end)
    else
        RunRefresh(true)
    end
end

function MidnightBags:Toggle()
    if not IsInventoryEnabled() then
        if type(_G.MidnightUI_Orig_ToggleAllBags) == "function" then
            return _G.MidnightUI_Orig_ToggleAllBags()
        end
        return
    end
    if IsSeparateBagsEnabled() then
        -- In separate mode, toggle all bag windows
        local anyVisible = false
        for bagID = 0, 5 do
            local window = separateBagWindows[bagID]
            if window and window:IsShown() then
                anyVisible = true
                break
            end
        end
        if anyVisible then
            MidnightBags:Close()
        else
            MidnightBags:Open()
        end
    else
        if BagWindow:IsShown() then MidnightBags:Close() else MidnightBags:Open() end
    end
end

local function HasVisibleBagWindows()
    if BagWindow and BagWindow.IsShown and BagWindow:IsShown() then
        return true
    end

    for bagID = 0, 5 do
        local window = separateBagWindows[bagID]
        if window and window.IsShown and window:IsShown() then
            return true
        end
    end

    return false
end

local function ApplyPendingBagRefresh()
    bagRefreshTimerActive = false

    if not pendingBagRefresh or not IsInventoryEnabled() then
        pendingBagRefresh = false
        return
    end

    if InCombatLockdown and InCombatLockdown() then
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    pendingBagRefresh = false
    if not HasVisibleBagWindows() then
        return
    end

    MidnightBags:UpdateLayout()
end

local function RequestVisibleBagRefresh()
    if not IsInventoryEnabled() then
        pendingBagRefresh = false
        return
    end

    if InCombatLockdown and InCombatLockdown() then
        pendingBagRefresh = true
        MidnightBags:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    if not HasVisibleBagWindows() then
        pendingBagRefresh = false
        return
    end

    pendingBagRefresh = true
    if bagRefreshTimerActive then
        return
    end

    bagRefreshTimerActive = true
    if C_Timer and C_Timer.After then
        C_Timer.After(BAG_REFRESH_THROTTLE, ApplyPendingBagRefresh)
    else
        ApplyPendingBagRefresh()
    end
end

function MidnightBags:Open()
    if not IsInventoryEnabled() then
        if type(_G.MidnightUI_Orig_OpenAllBags) == "function" then
            return _G.MidnightUI_Orig_OpenAllBags()
        end
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        pendingBagVisibility = "open"
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingBagVisibility = nil
    pendingBagRefresh = false
    bagRefreshTimerActive = false
    if IsSeparateBagsEnabled() then
        RefreshSeparateBagWindows()
        if ApplyFiltersSeparate then
            ApplyFiltersSeparate()
        end
        local backpackWindow = separateBagWindows[0]
        if backpackWindow and backpackWindow.UpdateMoney then
            backpackWindow:UpdateMoney()
        end
        -- Show a lightweight sentinel so UISpecialFrames can close separate bags on Escape
        -- (BagWindow itself stays hidden to avoid consuming Escape when no bags are visible)
        if not BagWindow._separateSentinel then
            local sentinel = CreateFrame("Frame", "MidnightBagSentinel", UIParent)
            sentinel:SetSize(1, 1)
            sentinel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -100, 100)
            sentinel:EnableMouse(false)
            sentinel:SetScript("OnHide", function()
                if InCombatLockdown and InCombatLockdown() then return end
                CloseSeparateBagWindows()
            end)
            table.insert(UISpecialFrames, "MidnightBagSentinel")
            BagWindow._separateSentinel = sentinel
        end
        BagWindow._separateSentinel:Show()
    else
        self:UpdateLayout()
        BagWindow:EnableMouse(true)
        BagWindow:SetAlpha(1)
        BagWindow:Show()
        if moneyText then UpdateConsolidatedMoneyDisplay() end
    end
end

function MidnightBags:Close()
    if InCombatLockdown and InCombatLockdown() then
        pendingBagVisibility = "close"
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingBagVisibility = nil
    pendingBagRefresh = false
    bagRefreshTimerActive = false
    ClearOverrideBindings(BagWindow)
    BagWindow:EnableMouse(true)
    BagWindow:SetAlpha(1)
    BagWindow:Hide()
    if BagWindow._separateSentinel then BagWindow._separateSentinel:Hide() end
    CloseSeparateBagWindows()
end

-- When BagWindow hides (consolidated mode Escape or explicit close), clean up
BagWindow:SetScript("OnHide", function()
    if InCombatLockdown and InCombatLockdown() then return end
    pendingBagVisibility = nil
    pendingBagRefresh = false
    bagRefreshTimerActive = false
    ClearOverrideBindings(BagWindow)
    if BagWindow._separateSentinel then BagWindow._separateSentinel:Hide() end
    CloseSeparateBagWindows()
    BagWindow:EnableMouse(true)
    BagWindow:SetAlpha(1)
end)

-- UpdateLayout wrapper that checks the setting
function MidnightBags:UpdateLayout()
    if not IsInventoryEnabled() then return end
    if InCombatLockdown and InCombatLockdown() then
        pendingBagRefresh = true
        self:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end
    pendingBagRefresh = false
    bagRefreshTimerActive = false
    if IsSeparateBagsEnabled() then
        if AnySeparateWindowVisible() then
            RefreshSeparateBagWindows()
            if ApplyFiltersSeparate then
                ApplyFiltersSeparate()
            end
        else
            UpdateSeparateBagsLayout()
        end
    else
        UpdateLayout()
    end
end

MidnightBags:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        CreateDock()
        OverrideBagToggles()
        HideDefaultBags()
        ApplyInventoryEnabledState()
        InitFilters()
        self:UpdateLayout() -- Pre-load buttons before combat
        
        self:RegisterEvent("ADDON_LOADED")
        self:RegisterEvent("BAG_UPDATE")
        self:RegisterEvent("BAG_UPDATE_DELAYED")
        self:RegisterEvent("ITEM_LOCK_CHANGED")
        self:RegisterEvent("BAG_SLOT_FLAGS_UPDATED")
        self:RegisterEvent("MAIL_INBOX_UPDATE")
        self:RegisterEvent("PLAYERBANKSLOTS_CHANGED")
        self:RegisterEvent("DISPLAY_SIZE_CHANGED")
        self:RegisterEvent("UI_SCALE_CHANGED")
        self:RegisterEvent("PLAYER_MONEY")
        self:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
        for _, e in ipairs(OPEN_BAG_EVENTS) do self:RegisterEvent(e) end
        for _, e in ipairs(CLOSE_BAG_EVENTS) do self:RegisterEvent(e) end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if pendingInventoryStateApply then
            ApplyInventoryEnabledState()
        end
        if pendingBagVisibility then
            local action = pendingBagVisibility
            pendingBagVisibility = nil
            pendingBagRefresh = false
            bagRefreshTimerActive = false
            if action == "open" then
                self:Open()
            else
                self:Close()
            end
        elseif pendingBagRefresh then
            ApplyPendingBagRefresh()
        end
        if pendingInventorySort then
            RequestInventorySort()
        end
        if not pendingInventoryStateApply and not pendingInventorySort and not pendingBagRefresh and not pendingBagVisibility then
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
    elseif event == "BAG_UPDATE" then
        if not IsInventoryEnabled() then return end
        pendingBagRefresh = HasVisibleBagWindows()
    elseif event == "BAG_UPDATE_DELAYED" or event == "ITEM_LOCK_CHANGED" or event == "BAG_SLOT_FLAGS_UPDATED" or event == "MAIL_INBOX_UPDATE" or event == "PLAYERBANKSLOTS_CHANGED" or event == "DISPLAY_SIZE_CHANGED" or event == "UI_SCALE_CHANGED" then
        if not IsInventoryEnabled() then return end
        if event ~= "BAG_UPDATE_DELAYED" or pendingBagRefresh then
            RequestVisibleBagRefresh()
        end
    elseif event == "PLAYER_MONEY" then
        if not IsInventoryEnabled() then return end
        if BagWindow:IsShown() then
            UpdateConsolidatedMoneyDisplay()
        end
        local backpackWindow = separateBagWindows[0]
        if backpackWindow and backpackWindow:IsShown() and backpackWindow.UpdateMoney then
            backpackWindow:UpdateMoney()
        end
    elseif event == "PLAYER_EQUIPMENT_CHANGED" then
        if not IsInventoryEnabled() then return end
        -- Flash the hovered bag button and live-refresh its tooltip
        local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
        if owner and owner.bagID and owner.slotID and owner._mui_equippedDot then
            if owner._mui_equipFlashAG then
                owner._mui_equipFlashAG:Stop()
                owner._mui_equipFlashAG:Play()
            end
            GameTooltip:SetBagItem(owner.bagID, owner.slotID)
            GameTooltip:Show()
        end
        -- Refresh bag visuals so equipped indicators update
        RequestVisibleBagRefresh()
    elseif event == "ADDON_LOADED" then
        HideDefaultBags()
        ApplyInventoryEnabledState()
    elseif string.find(event, "_SHOW") or event == "BANKFRAME_OPENED" then
        if IsInventoryEnabled() then
            MidnightBags:Open()
        end
    elseif string.find(event, "_CLOSED") or event == "BANKFRAME_CLOSED" then
        if IsInventoryEnabled() then
            MidnightBags:Close()
        end
    end
end)

local function BuildInventoryOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureBagSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Header("Inventory")
    b:Checkbox("Enable MidnightUI Inventory", s.enabled ~= false, function(v)
        s.enabled = (v and true or false)
        ApplyInventoryEnabledState()
    end)
    b:Checkbox("Separate Inventory Bags", s.separateBags == true, function(v)
        s.separateBags = (v and true or false)
        if s.enabled ~= false then
            MidnightBags:Close()
            MidnightBags:Open()
        end
    end)
    b:Slider("Bag Bar Scale %", 50, 200, 5, tonumber(s.dockScale) or 100, function(v)
        s.dockScale = math.floor(v)
        ApplyInventoryEnabledState()
    end)
    b:Slider("Slot Size", 24, 64, 2, tonumber(s.bagSlotSize) or 40, function(v)
        s.bagSlotSize = math.floor(v)
        if s.enabled ~= false then MidnightBags:UpdateLayout() end
    end)
    b:Slider("Columns", 6, 24, 1, tonumber(s.bagColumns) or 12, function(v)
        s.bagColumns = math.floor(v)
        if s.enabled ~= false then MidnightBags:UpdateLayout() end
    end)
    b:Slider("Spacing", 0, 12, 1, tonumber(s.bagSpacing) or 6, function(v)
        s.bagSpacing = math.floor(v)
        if s.enabled ~= false then MidnightBags:UpdateLayout() end
    end)

    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("Inventory", { title = "Inventory", build = BuildInventoryOverlaySettings })
end
