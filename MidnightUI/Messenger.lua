-- =============================================================================
-- FILE PURPOSE:     Full chat interface replacing WoW's default chat windows.
--                   Provides tabbed messaging with: Local (zone/defense/city channels),
--                   Direct Messages (whispers grouped by player), World (custom channel
--                   monitor), Group, and Market (fed by Market.lua keyword matches).
--                   Also resizes SuperTrackedFrame's crosshair/faction icon.
-- LOAD ORDER:       Loads after Diagnostics.lua, before Settings.lua. Messenger frame is created
--                   at file scope. ADDON_LOADED gates DB init and channel registration.
-- DEFINES:          Messenger (Frame, "MyMessengerFrame"), MessengerDB (SavedVariable).
--                   Globals: UpdateTabLayout(), MyMessenger_RefreshDisplay(),
--                   MidnightUI_ApplySuperTrackedIcon(), MidnightUI_ApplyMessengerSettings().
-- READS:            MessengerDB.{History, Tabs, Settings, MarketWatchList}.
--                   MidnightUISettings.Messenger.{locked, alpha, scale, width, height,
--                   fontSize, mainTabSpacing, showTimestamp, style, position,
--                   hideGlobal, hideLoginStates, showDefaultChatInterface, keepDebugHidden}.
-- WRITES:           MessengerDB.History[tabKey] — message history per tab.
--                   MessengerDB.Tabs — per-tab state (unread, filter, etc.).
--                   MidnightUISettings.Messenger.position (on drag stop).
--                   Blizzard default chat: show/hidden based on showDefaultChatInterface setting.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (player name colors in messages).
--                   Market.lua — writes into MessengerDB.History["Market"]; calls
--                   UpdateTabLayout() and MyMessenger_RefreshDisplay() cross-module.
-- USED BY:          Market.lua (cross-module calls above),
--                   Settings.lua (MidnightUI_ApplyMessengerSettings),
--                   Settings_UI.lua (exposes messenger settings controls).
-- KEY FLOWS:
--   ADDON_LOADED → InitMessengerDB() → register channels → build tabs → render history
--   CHAT_MSG_* events → RouteMessage(event, ...) → appends to MessengerDB.History[tab]
--   CHAT_MSG_WHISPER/WHISPER_INFORM → DM tab grouping by sender/recipient name
--   CHAT_MSG_CHANNEL_NOTICE → detects stale channels (areChannelsStale flag)
--   PLAYER_ENTERING_WORLD → re-joins channels, refreshes city filter
--   Tab click → ACTIVE_TAB = key → MyMessenger_RefreshDisplay() redraws message list
--   SuperTrackedFrame icon: hooks SuperTrackedFrame:Show() to apply faction/crosshair atlas
-- GOTCHAS:
--   MessengerDB.History["Market"] is written by Market.lua, not Messenger.lua.
--   areChannelsStale: set when a CHAT_MSG_CHANNEL_NOTICE indicates a channel left/changed;
--   triggers a re-join cycle on next PLAYER_ENTERING_WORLD.
--   lastCityMapId / lastCitySeenAt: city detection uses C_Map.GetBestMapForUnit("player")
--   and compares against a known city mapID list — locale-independent detection.
--   GROUP_HISTORY_MAX_AGE (3 days in seconds): group chat history older than this is
--   pruned from MessengerDB on load to prevent unbounded growth.
--   AllowDefaultChatTweaks() returns false — the Blizzard chat font/skin tweaks
--   are intentionally disabled in this release to avoid taint interactions.
-- NAVIGATION:
--   ACTIVE_TAB, ACTIVE_DM_FILTER   — current display state (line ~5)
--   MAX_HISTORY (200)               — per-tab message cap
--   Messenger frame setup           — "1. MAIN FRAME" section (line ~25)
--   InitMessengerDB()               — DB bootstrap and history pruning
--   RouteMessage()                  — event → tab routing logic
--   MyMessenger_RefreshDisplay()    — re-renders visible message list
--   UpdateTabLayout()               — recalculates tab badges and widths
--   ApplySuperTrackedIcon()         — resizes/re-textures the quest tracking crosshair
-- =============================================================================

local ACTIVE_TAB = "Local"
local ACTIVE_DM_FILTER = nil 
local ACTIVE_CHANNEL_ID = nil
local ACTIVE_WORLD_FILTER = "ALL"
local MAX_HISTORY = 200 
local GROUP_HISTORY_MAX_AGE = 3 * 24 * 60 * 60
local TabButtons = {}
local DMHeaderButtons = {}
local WorldHeaderButtons = {}
local WorldMenuButtons = {}

local areChannelsStale = false
local lastCityMapId = nil
local lastCitySeenAt = 0
local activeFadeGuard = nil
local function AllowDefaultChatTweaks()
    return false
end

-- 1. MAIN FRAME
local Messenger = CreateFrame("Frame", "MyMessengerFrame", UIParent, "BackdropTemplate")
Messenger:SetFrameStrata("LOW") 
Messenger:SetMovable(true)
Messenger:SetClampedToScreen(true)


-- =========================================================================
--  DEBUG (GLOBAL LOGGER)
-- =========================================================================
_G.MidnightUI_DebugQueue = _G.MidnightUI_DebugQueue or {}
_G.MidnightUI_SetDebugNotify = function() end

-- =========================================================================
--  2. LAYOUT & STYLING
-- =========================================================================

Messenger:SetSize(650, 400)
Messenger:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 20, 20)

local CHAT_BG = {0.09, 0.11, 0.18}
local TAB_BG = {0.07, 0.09, 0.16}
local SEPARATOR_COLOR = {0.16, 0.19, 0.25}
local INPUT_BG = {0.08, 0.1, 0.17}
local DEFAULT_TAB_BAR_COLOR = {0, 0.8, 1}
local currentChatTheme = nil

local function GetPlayerClassColor()
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
        return _G.MidnightUI_Core.GetClassColor("player")
    end
    return DEFAULT_TAB_BAR_COLOR[1], DEFAULT_TAB_BAR_COLOR[2], DEFAULT_TAB_BAR_COLOR[3]
end

local defaultSuperTrackedSize = nil
local function CaptureSuperTrackedDefaults(icon)
    if not icon then return end
    if not defaultSuperTrackedSize then
        local ok, w, h = pcall(icon.GetSize, icon)
        if ok and w and h then defaultSuperTrackedSize = { w, h } end
    end
end
local function GetSuperTrackedIcon()
    if _G.SuperTrackedFrameIcon then return _G.SuperTrackedFrameIcon end
    if _G.SuperTrackedFrame and _G.SuperTrackedFrame.Icon then return _G.SuperTrackedFrame.Icon end
    return nil
end

local function ApplySuperTrackedIcon()
    local icon = GetSuperTrackedIcon()
    if not icon then return end
    if icon._muiApplying then return end
    icon._muiApplying = true
    CaptureSuperTrackedDefaults(icon)
    local function PickClosestAtlasSize(target)
        local sizes = {32, 48, 64, 96, 128}
        local best = sizes[1]
        local bestDelta = math.abs(target - best)
        for i = 2, #sizes do
            local s = sizes[i]
            local d = math.abs(target - s)
            if d < bestDelta then
                best = s
                bestDelta = d
            end
        end
        return best
    end
    local function ApplyCrosshairAtlas(isUnable)
        local w = defaultSuperTrackedSize and defaultSuperTrackedSize[1]
        local h = defaultSuperTrackedSize and defaultSuperTrackedSize[2]
        if not w or not h then
            local ok, cw, ch = pcall(icon.GetSize, icon)
            if ok then w, h = cw, ch end
        end
        local target = math.max(tonumber(w) or 0, tonumber(h) or 0)
        if target <= 0 then target = 48 end
        local size = PickClosestAtlasSize(target)
        local atlas = (isUnable and "crosshair_unabletrack_" or "crosshair_track_") .. tostring(size)
        if icon.SetAtlas then icon:SetAtlas(atlas, true) end
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetSize(size, size)
    end
    local function IsUnableToTrack()
        if _G.SuperTrackedFrame and _G.SuperTrackedFrame.IsShown then
            local ok, shown = pcall(_G.SuperTrackedFrame.IsShown, _G.SuperTrackedFrame)
            if ok and not shown then return true end
        end
        if icon.IsShown then
            local ok, shown = pcall(icon.IsShown, icon)
            if ok and not shown then return true end
        end
        return false
    end
    local useDefault = false
    if MidnightUISettings and MidnightUISettings.General then
        useDefault = MidnightUISettings.General.useDefaultSuperTrackedIcon == true
    end
    if useDefault then
        ApplyCrosshairAtlas(IsUnableToTrack())
        icon:SetAlpha(1)
        if icon.Show then icon:Show() end
        icon._muiApplying = false
        return
    end
    local faction = UnitFactionGroup("player")
    if faction == "Alliance" then
        if icon.SetAtlas then icon:SetAtlas("charcreatetest-logo-alliance", true) end
    elseif faction == "Horde" then
        if icon.SetAtlas then icon:SetAtlas("charcreatetest-logo-horde", true) end
    else
        ApplyCrosshairAtlas(IsUnableToTrack())
    end
    icon:SetTexCoord(0, 1, 0, 1)
    if defaultSuperTrackedSize then
        local scale = 2.4
        local maxDim = math.max(defaultSuperTrackedSize[1], defaultSuperTrackedSize[2])
        icon:SetSize(maxDim * scale, maxDim * scale)
    end
    icon:SetAlpha(1)
    if icon.Show then icon:Show() end
    icon._muiApplying = false
end

_G.MidnightUI_ApplySuperTrackedIcon = ApplySuperTrackedIcon
local function HookSuperTrackedIcon()
    local icon = GetSuperTrackedIcon()
    if not icon or icon._muiHooked then return end
    icon._muiHooked = true
    if icon.SetAtlas then
        hooksecurefunc(icon, "SetAtlas", function()
            if icon._muiApplying then return end
            C_Timer.After(0, ApplySuperTrackedIcon)
        end)
    end
    if icon.SetTexture then
        hooksecurefunc(icon, "SetTexture", function()
            if icon._muiApplying then return end
            C_Timer.After(0, ApplySuperTrackedIcon)
        end)
    end
    if icon.HookScript then
        icon:HookScript("OnShow", function()
            C_Timer.After(0, ApplySuperTrackedIcon)
        end)
    end
end
local function ScheduleSuperTrackedIconApply()
    local attempts = 0
    local ticker
    ticker = C_Timer.NewTicker(0.5, function()
        attempts = attempts + 1
        HookSuperTrackedIcon()
        ApplySuperTrackedIcon()
        if attempts >= 8 then
            if ticker then ticker:Cancel() end
        end
    end)
end

local function GetChatTypeColorRGB(chatType, fallback)
    if ChatTypeInfo and chatType and ChatTypeInfo[chatType] then
        local info = ChatTypeInfo[chatType]
        return info.r or info[1] or 1, info.g or info[2] or 1, info.b or info[3] or 1
    end
    if fallback and #fallback == 3 then return fallback[1], fallback[2], fallback[3] end
    return 1, 1, 1
end

-- =========================================================================
--  PRINT OVERRIDE -> DEBUG TAB (SAFE, OPTIONAL)
-- =========================================================================
local function EnsurePrintOverride()
    if not _G.MidnightUI_OriginalPrint then
        _G.MidnightUI_OriginalPrint = _G.print
    end
    _G.print = function(...)
        local n = select("#", ...)
        local routedToDiagnostics = false
        if n > 0 then
            local parts = {}
            for i = 1, n do
                local v = select(i, ...)
                parts[#parts + 1] = tostring(v)
            end
            local msg = table.concat(parts, " ")
            if _G.MidnightUI_Debug then
                _G.MidnightUI_Debug(msg)
                routedToDiagnostics = true
            else
                _G.MidnightUI_DebugQueue = _G.MidnightUI_DebugQueue or {}
                table.insert(_G.MidnightUI_DebugQueue, msg)
                routedToDiagnostics = true
            end
        end
        -- Only send to chat if the message was NOT routed to the diagnostics
        -- system. This prevents MidnightUI debug messages from cluttering chat.
        if not routedToDiagnostics and _G.MidnightUI_OriginalPrint then
            _G.MidnightUI_OriginalPrint(...)
        end
    end
end
EnsurePrintOverride()

local function GetChatTheme(style)
    local cR, cG, cB = GetPlayerClassColor()
    local defaultAccent = {0, 0.8, 1}

    if style == "Class Color" then
        return {
            chatBg = {cR * 0.08, cG * 0.08, cB * 0.08},
            tabBg = {cR * 0.05, cG * 0.05, cB * 0.05},
            separator = {cR * 0.22, cG * 0.22, cB * 0.22},
            inputBg = {cR * 0.07, cG * 0.07, cB * 0.07},
            accent = {cR, cG, cB},
            tabBarColor = {cR, cG, cB},
        }
    elseif style == "Faithful" then
        return {
            chatBg = {0.16, 0.13, 0.10},
            tabBg = {0.11, 0.09, 0.07},
            separator = {0.28, 0.23, 0.18},
            inputBg = {0.14, 0.11, 0.09},
            accent = {0.78, 0.69, 0.52},
            tabBarColor = {0.78, 0.69, 0.52},
        }
    elseif style == "Minimal" then
        return {
            chatBg = {0.02, 0.02, 0.05},
            tabBg = {0.02, 0.02, 0.04},
            separator = {0.06, 0.06, 0.10},
            inputBg = {0.02, 0.02, 0.05},
            accent = {0.45, 0.55, 0.65},
            tabBarColor = {0.45, 0.55, 0.65},
            chatAlpha = 0.25,
            tabAlpha = 0.30,
            inputAlpha = 0.50,
            separatorAlpha = 0.12,
            borderAlpha = 0.15,
            textShadow = true,
        }
    elseif style == "Glass" then
        return {
            chatBg = {0.06, 0.08, 0.12},
            tabBg = {0.03, 0.04, 0.06},
            separator = {0.2, 0.25, 0.3},
            inputBg = {0.07, 0.09, 0.13},
            accent = {0.6, 0.8, 1},
            tabBarColor = {0.6, 0.8, 1},
        }
    end

    return {
        chatBg = {0.09, 0.11, 0.18},
        tabBg = {0.07, 0.09, 0.16},
        separator = {0.16, 0.19, 0.25},
        inputBg = {0.08, 0.1, 0.17},
        accent = defaultAccent,
        tabBarColor = {cR, cG, cB},
    }
end

Messenger.bg = Messenger:CreateTexture(nil, "BACKGROUND")
Messenger.bg:SetAllPoints()
Messenger.bg:SetColorTexture(CHAT_BG[1], CHAT_BG[2], CHAT_BG[3], 0.85)

local function CreateBorder(f, r, g, b, a)
    local border = CreateFrame("Frame", nil, f)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(1); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT")
    border.bot = border:CreateTexture(nil, "OVERLAY"); border.bot:SetHeight(1); border.bot:SetPoint("BOTTOMLEFT"); border.bot:SetPoint("BOTTOMRIGHT")
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(1); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT")
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(1); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT")
    local function SetColor(cr, cg, cb, ca)
        border.top:SetColorTexture(cr, cg, cb, ca)
        border.bot:SetColorTexture(cr, cg, cb, ca)
        border.left:SetColorTexture(cr, cg, cb, ca)
        border.right:SetColorTexture(cr, cg, cb, ca)
    end
    SetColor(r, g, b, a)
    border.SetColor = SetColor
    return border
end
local messengerBorder = CreateBorder(Messenger, 0, 0, 0, 1)

-- === DRAG OVERLAY ===
local dragOverlay = CreateFrame("Frame", nil, Messenger, "BackdropTemplate")
dragOverlay:SetAllPoints()
dragOverlay:SetFrameStrata("DIALOG") 
dragOverlay:SetBackdrop({bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16})
dragOverlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
dragOverlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(dragOverlay, nil, nil, "world") end
dragOverlay:EnableMouse(true)
dragOverlay:RegisterForDrag("LeftButton")
dragOverlay:Hide() 

local dragLabel = dragOverlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
dragLabel:SetPoint("CENTER")
dragLabel:SetText("MESSENGER FRAME\nDrag to Reposition")

dragLabel:SetShadowOffset(2, -2)
dragLabel:SetShadowColor(0, 0, 0, 1)
dragOverlay:SetScript("OnDragStart", function(self)
    Messenger:StartMoving()
end)

dragOverlay:SetScript("OnDragStop", function(self)
    Messenger:StopMovingOrSizing()
    local point, _, relativePoint, xOfs, yOfs = Messenger:GetPoint()
    if MidnightUI_SetMessengerSetting then
        MidnightUI_SetMessengerSetting("position", { point, relativePoint, xOfs, yOfs })
    end
end)
if _G.MidnightUI_AttachOverlaySettings then
    _G.MidnightUI_AttachOverlaySettings(dragOverlay, "Messenger")
end
Messenger.dragOverlay = dragOverlay

-- === SIDEBAR ===
local sidebar = Messenger:CreateTexture(nil, "ARTWORK")
sidebar:SetColorTexture(TAB_BG[1], TAB_BG[2], TAB_BG[3], 1)
sidebar:SetPoint("TOPLEFT", Messenger, "TOPLEFT")
sidebar:SetPoint("BOTTOMLEFT", Messenger, "BOTTOMLEFT")
sidebar:SetWidth(130)  -- Increased from 105 for better tab visibility

local sidebarSep = Messenger:CreateTexture(nil, "OVERLAY")
sidebarSep:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], 1)
sidebarSep:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT")
sidebarSep:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT")
sidebarSep:SetWidth(1)

local header = CreateFrame("Frame", nil, Messenger) 
header:SetPoint("TOPLEFT", sidebar, "TOPRIGHT")
header:SetPoint("TOPRIGHT", Messenger, "TOPRIGHT")
header:SetHeight(40)

local headerSep = header:CreateTexture(nil, "OVERLAY")
headerSep:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], 1)
headerSep:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT")
headerSep:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT")
headerSep:SetHeight(1)

local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
title:SetPoint("LEFT", header, "LEFT", 20, 0)
title:SetText("|cff00ccff#|r  Local") 
title:SetTextColor(1, 1, 1)

-- =========================================================================
--  HEADER BUTTONS (Debug & Market)
-- =========================================================================

-- 1. DEBUG COPY BUTTON
local debugCopyBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
debugCopyBtn:SetSize(60, 22)
debugCopyBtn:SetPoint("RIGHT", header, "RIGHT", -15, 0)
debugCopyBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
debugCopyBtn:SetBackdropColor(0.3, 0.1, 0.1, 0.9)
debugCopyBtn:SetBackdropBorderColor(0.8, 0.2, 0.2, 1)
debugCopyBtn.text = debugCopyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debugCopyBtn.text:SetPoint("CENTER")
debugCopyBtn.text:SetText("Copy")
debugCopyBtn.text:SetTextColor(1, 0.8, 0.8)
debugCopyBtn:Hide()

debugCopyBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.5, 0.15, 0.15, 1); self.text:SetTextColor(1, 1, 1) end)
debugCopyBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.3, 0.1, 0.1, 0.9); self.text:SetTextColor(1, 0.8, 0.8) end)
debugCopyBtn:SetScript("OnClick", function()
    if _G.MidnightUI_DebugBusy then return end
    _G.MidnightUI_DebugBusy = true
    if not MessengerDB or not MessengerDB.History["Debug"] then
        _G.MidnightUI_DebugBusy = false
        return
    end
    local messages = MessengerDB.History["Debug"].messages
    local function SafeToString(value, placeholder)
        if value == nil then return "" end
        local ok, str = pcall(tostring, value)
        if not ok then return placeholder or "[Restricted Message Hidden]" end
        local okConcat = pcall(function() return table.concat({ str }, "") end)
        if not okConcat then return placeholder or "[Restricted Message Hidden]" end
        return str
    end
    
    local output = {}
    local total = #messages
    local maxCopy = 200
    local startIndex = math.max(1, total - maxCopy + 1)
    table.insert(output, "=== DEBUG LOG (" .. total .. " messages) ===")
    for i = startIndex, total do
        local data = messages[i]
        local timestamp = SafeToString(data and data.timestamp, "[Restricted Message Hidden]")
        local msg = SafeToString(data and data.msg, "[Restricted Message Hidden]")
        local line = SafeToString("[" .. timestamp .. "] " .. msg, "[Restricted Message Hidden]")
        table.insert(output, line)
    end
    table.insert(output, "=== END DEBUG LOG ===")
    
    local fullText = ""
    local ok = pcall(function() fullText = table.concat(output, "\n") end)
    if not ok then
        fullText = "[Restricted Message Hidden]"
    end
    
    if not _G.MidnightUI_CopyFrame then
        local copyFrame = CreateFrame("Frame", "MidnightUI_CopyFrame", UIParent, "BackdropTemplate")
        copyFrame:SetSize(600, 400)
        copyFrame:SetPoint("CENTER"); copyFrame:SetFrameStrata("DIALOG")
        copyFrame:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 2 })
        copyFrame:SetBackdropColor(0.05, 0.05, 0.05, 0.95); copyFrame:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
        copyFrame:EnableMouse(true); copyFrame:SetMovable(true); copyFrame:RegisterForDrag("LeftButton")
        copyFrame:SetScript("OnDragStart", copyFrame.StartMoving); copyFrame:SetScript("OnDragStop", copyFrame.StopMovingOrSizing); copyFrame:Hide()
        
        local title = copyFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
        title:SetPoint("TOP", 0, -10); title:SetText("Debug Log - Press Ctrl+C to Copy"); title:SetTextColor(1, 0.8, 0.2)
        local scrollFrame = CreateFrame("ScrollFrame", nil, copyFrame, "UIPanelScrollFrameTemplate")
        scrollFrame:SetPoint("TOPLEFT", 10, -35); scrollFrame:SetPoint("BOTTOMRIGHT", -30, 40)
        local editBox = CreateFrame("EditBox", nil, scrollFrame)
        editBox:SetMultiLine(true); editBox:SetMaxLetters(0); editBox:SetFontObject(ChatFontNormal); editBox:SetWidth(560); editBox:SetAutoFocus(false)
        editBox:SetScript("OnEscapePressed", function() copyFrame:Hide() end)
        scrollFrame:SetScrollChild(editBox)
        copyFrame.editBox = editBox
        local closeBtn = CreateFrame("Button", nil, copyFrame, "UIPanelCloseButton"); closeBtn:SetPoint("TOPRIGHT", -5, -5); closeBtn:SetScript("OnClick", function() copyFrame:Hide() end)
        -- ESC to close (via UISpecialFrames)
        table.insert(UISpecialFrames, "MidnightUI_CopyFrame")
    end
    local copyFrame = _G.MidnightUI_CopyFrame
    local okSet = pcall(copyFrame.editBox.SetText, copyFrame.editBox, fullText)
    if not okSet then
        copyFrame.editBox:SetText("[Restricted Message Hidden]")
    end
    copyFrame.editBox:HighlightText(); copyFrame.editBox:SetFocus(); copyFrame:Show()
    _G.MidnightUI_DebugBusy = false
end)

-- 2. DEBUG CLEAR BUTTON (NEW)
local debugClearBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
debugClearBtn:SetSize(60, 22)
debugClearBtn:SetPoint("RIGHT", debugCopyBtn, "LEFT", -5, 0)
debugClearBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
debugClearBtn:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
debugClearBtn:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
debugClearBtn.text = debugClearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debugClearBtn.text:SetPoint("CENTER")
debugClearBtn.text:SetText("Clear")
debugClearBtn.text:SetTextColor(1, 0.8, 0.8)
debugClearBtn:Hide()

debugClearBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.3, 0.3, 0.3, 1); self.text:SetTextColor(1, 1, 1) end)
debugClearBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.2, 0.2, 0.2, 0.9); self.text:SetTextColor(1, 0.8, 0.8) end)
debugClearBtn:SetScript("OnClick", function()
    if _G.MidnightUI_DebugBusy then return end
    _G.MidnightUI_DebugBusy = true
    if MessengerDB and MessengerDB.History["Debug"] then
        MessengerDB.History["Debug"].messages = {}
        MessengerDB.History["Debug"].unread = 0
        if MyMessenger_RefreshDisplay then pcall(MyMessenger_RefreshDisplay) end
    end
    _G.MidnightUI_DebugBusy = false
end)

-- 2b. DEBUG DIAGNOSTICS BUTTON
local debugDiagBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
debugDiagBtn:SetSize(70, 22)
debugDiagBtn:SetPoint("RIGHT", debugClearBtn, "LEFT", -5, 0)
debugDiagBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
debugDiagBtn:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
debugDiagBtn:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
debugDiagBtn.text = debugDiagBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
debugDiagBtn.text:SetPoint("CENTER")
debugDiagBtn.text:SetText("Bugs")
debugDiagBtn.text:SetTextColor(1, 0.8, 0.8)
debugDiagBtn:Hide()

debugDiagBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.3, 0.3, 0.3, 1); self.text:SetTextColor(1, 1, 1) end)
debugDiagBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.2, 0.2, 0.2, 0.9); self.text:SetTextColor(1, 0.8, 0.8) end)
debugDiagBtn:SetScript("OnClick", function()
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.Open then
        local ok = _G.MidnightUI_Diagnostics.Open()
        if ok == false and _G.MidnightUI_ShowDiagnosticsStatus then
            _G.MidnightUI_ShowDiagnosticsStatus("Diagnostics failed to open")
        end
    elseif _G.MidnightUI_ShowDiagnosticsStatus then
        _G.MidnightUI_ShowDiagnosticsStatus("Diagnostics API missing")
    end
end)

-- 3. MARKET CLEAR BUTTON
local marketClearBtn = CreateFrame("Button", nil, header, "BackdropTemplate")
marketClearBtn:SetSize(60, 22)
marketClearBtn:SetPoint("RIGHT", header, "RIGHT", -15, 0)
marketClearBtn:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
marketClearBtn:SetBackdropColor(0.2, 0.2, 0.2, 0.9)
marketClearBtn:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
marketClearBtn.text = marketClearBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
marketClearBtn.text:SetPoint("CENTER")
marketClearBtn.text:SetText("Clear")
marketClearBtn.text:SetTextColor(1, 0.8, 0.8)
marketClearBtn:Hide()

marketClearBtn:SetScript("OnEnter", function(self) self:SetBackdropColor(0.5, 0.15, 0.15, 1); self.text:SetTextColor(1, 1, 1) end)
marketClearBtn:SetScript("OnLeave", function(self) self:SetBackdropColor(0.2, 0.2, 0.2, 0.9); self.text:SetTextColor(1, 0.8, 0.8) end)
marketClearBtn:SetScript("OnClick", function()
    if MessengerDB and MessengerDB.History["Market"] then
        MessengerDB.History["Market"].messages = {}
        MessengerDB.History["Market"].unread = 0
        MyMessenger_RefreshDisplay()
    end
end)

local dmHeader = CreateFrame("Frame", nil, header)
dmHeader:SetAllPoints()
dmHeader:Hide()

local worldHeader = CreateFrame("Frame", nil, header)
worldHeader:SetAllPoints()
worldHeader:Hide()

local function EnsureDiagnosticsStatusFrame()
    if _G.MidnightUI_DiagnosticsStatusFrame then return _G.MidnightUI_DiagnosticsStatusFrame end
    local f = CreateFrame("Frame", "MidnightUI_DiagnosticsStatusFrame", UIParent, "BackdropTemplate")
    f:SetSize(640, 260)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    f:SetBackdropColor(0.06, 0.07, 0.13, 0.98)
    f:SetBackdropBorderColor(0.18, 0.22, 0.30, 1.0)
    f:SetClampedToScreen(true)
    f:EnableMouse(true)
    f:SetMovable(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    t:SetPoint("TOPLEFT", 12, -12)
    t:SetText("MIDNIGHT UI DIAGNOSTICS")
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 12, -46)
    scroll:SetPoint("BOTTOMRIGHT", -32, 12)
    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("ChatFontNormal")
    edit:SetAutoFocus(false)
    edit:SetWidth(580)
    edit:EnableMouse(true)
    edit:SetText("Opening diagnostics...")
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    scroll:SetScrollChild(edit)
    local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", -6, -6)
    f.msg = edit
    _G.MidnightUI_DiagnosticsStatusFrame = f
    return f
end

local function ShowDiagnosticsStatus(errText)
    local status = EnsureDiagnosticsStatusFrame()
    local df = _G.MidnightUI_DiagnosticsFrame
    if df and df.IsShown and df:IsShown() then
        return
    end
    status:Show()
    status:Raise()
    local diag = _G.MidnightUI_Diagnostics
    local db = _G.MidnightUIDiagnosticsDB
    local debugCount = (MessengerDB and MessengerDB.History and MessengerDB.History["Debug"] and #MessengerDB.History["Debug"].messages) or 0
    local debugUnread = (MessengerDB and MessengerDB.History and MessengerDB.History["Debug"] and MessengerDB.History["Debug"].unread) or 0
    local q = (_G.MidnightUI_DebugQueue and #_G.MidnightUI_DebugQueue) or 0
    local diagCount = (db and db.errors and #db.errors) or 0
    local diagSession = (db and db.session) or 0
    local diagActive = tostring(_G.MidnightUI_DiagnosticsActive == true)
    local settingsEnabled = tostring(_G.MidnightUISettings and _G.MidnightUISettings.General and _G.MidnightUISettings.General.diagnosticsEnabled == true)
    local diagHas = tostring(_G.MidnightUI_DiagnosticsHasEntries and _G.MidnightUI_DiagnosticsHasEntries() or false)
    local dfShown = (df and df.IsShown and df:IsShown()) and "true" or "false"
    local dfRegions = (df and df.GetNumRegions and df:GetNumRegions()) or "n/a"
    local dfChildren = (df and df.GetNumChildren and df:GetNumChildren()) or "n/a"
    local hasDiag = tostring(diag ~= nil)
    local hasOpen = tostring(diag and type(diag.Open) == "function")
    local loadState = tostring(_G.MidnightUI_DiagnosticsLoadState or "unknown")
    local lines = {}
    lines[#lines + 1] = "Diagnostics Status"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Diagnostics Open: " .. tostring(dfShown == "true")
    lines[#lines + 1] = "Diagnostics Error: " .. tostring(errText or "none")
    lines[#lines + 1] = "Diagnostics Active: " .. diagActive
    lines[#lines + 1] = "Diagnostics Enabled (Settings): " .. settingsEnabled
    lines[#lines + 1] = "Diagnostics Table Present: " .. hasDiag
    lines[#lines + 1] = "Diagnostics Open Function: " .. hasOpen
    lines[#lines + 1] = "Diagnostics Load State: " .. loadState
    lines[#lines + 1] = "Diagnostics Has Entries: " .. diagHas
    lines[#lines + 1] = "Diagnostics DB Count: " .. tostring(diagCount)
    lines[#lines + 1] = "Diagnostics Session: " .. tostring(diagSession)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "DiagnosticsFrame Shown: " .. dfShown
    lines[#lines + 1] = "DiagnosticsFrame Regions: " .. tostring(dfRegions)
    lines[#lines + 1] = "DiagnosticsFrame Children: " .. tostring(dfChildren)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Messenger Debug Messages: " .. tostring(debugCount)
    lines[#lines + 1] = "Messenger Debug Unread: " .. tostring(debugUnread)
    lines[#lines + 1] = "Debug Queue (pre-DB): " .. tostring(q)
    status.msg:SetText(table.concat(lines, "\n"))
end

_G.MidnightUI_ShowDiagnosticsStatus = ShowDiagnosticsStatus

local HEADER_SYNC_DEBUG = false
local function DebugHeaderSync(context, extra)
    if not HEADER_SYNC_DEBUG then return end
    if type(LogDebug) ~= "function" then return end
    local titleShown = (title and title.IsShown and title:IsShown()) and "true" or "false"
    local worldShown = (worldHeader and worldHeader.IsShown and worldHeader:IsShown()) and "true" or "false"
    local dmShown = (dmHeader and dmHeader.IsShown and dmHeader:IsShown()) and "true" or "false"
    LogDebug(string.format(
        "[HeaderSync] %s tab=%s filter=%s titleShown=%s worldHeaderShown=%s dmHeaderShown=%s %s",
        tostring(context or "?"),
        tostring(ACTIVE_TAB),
        tostring(ACTIVE_WORLD_FILTER),
        titleShown,
        worldShown,
        dmShown,
        tostring(extra or "")
    ))
end

-- =========================================================================
--  3. DISPLAY AREA & CONTAINER
-- =========================================================================

local msgFrame = CreateFrame("ScrollingMessageFrame", nil, Messenger)
msgFrame:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 15, -15)
msgFrame:SetPoint("BOTTOMRIGHT", Messenger, "BOTTOMRIGHT", -15, 40) 

msgFrame:SetFontObject(ChatFontNormal)
msgFrame:SetJustifyH("LEFT")
msgFrame:SetFading(false)
msgFrame:SetMaxLines(500)
msgFrame:SetSpacing(4)
msgFrame:EnableMouseWheel(true)
msgFrame:SetHyperlinksEnabled(true)
_G.MyMessengerMessageFrame = msgFrame

local function GetMessengerFontSize()
    local s = MidnightUISettings and MidnightUISettings.Messenger
    local size = math.floor(tonumber(s and s.fontSize) or 14)
    if size < 8 then size = 8 end
    if size > 24 then size = 24 end
    return size
end

local function GetMessengerTabFontSize()
    local s = MidnightUISettings and MidnightUISettings.Messenger
    local size = math.floor(tonumber(s and s.tabFontSize) or 12)
    if size < 8 then size = 8 end
    if size > 18 then size = 18 end
    return size
end

local function ApplyTabFontSize(fontString, size)
    if not fontString or type(fontString.GetFont) ~= "function" then return end
    local fontPath, _, fontFlags = fontString:GetFont()
    if fontPath then
        fontString:SetFont(fontPath, size, fontFlags)
    end
end

local function GetMessengerMainTabSpacing()
    local s = MidnightUISettings and MidnightUISettings.Messenger
    local spacing = math.floor(tonumber(s and s.mainTabSpacing) or 40)
    if spacing < 28 then spacing = 28 end
    if spacing > 64 then spacing = 64 end
    return spacing
end

local function GetMessengerMainTabHeight()
    local spacing = GetMessengerMainTabSpacing()
    local h = spacing - 4
    if h < 26 then h = 26 end
    if h > 52 then h = 52 end
    return h
end

msgFrame:SetScript("OnMouseWheel", function(self, delta)
    if delta > 0 then self:ScrollUp() else self:ScrollDown() end
end)

local combatContainer = CreateFrame("Frame", nil, Messenger)
combatContainer:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 15, -35)
combatContainer:SetPoint("BOTTOMRIGHT", Messenger, "BOTTOMRIGHT", -15, 40)
combatContainer:Hide() 

local combatQuickBar = CreateFrame("Frame", nil, combatContainer, "BackdropTemplate")
combatQuickBar:SetPoint("TOPLEFT", combatContainer, "TOPLEFT", 0, 22)
combatQuickBar:SetPoint("TOPRIGHT", combatContainer, "TOPRIGHT", 0, 22)
combatQuickBar:SetHeight(28)
combatQuickBar:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets = { left = 0, right = 0, top = 0, bottom = 0 }
})
combatQuickBar:SetBackdropColor(0, 0, 0, 0.5)
combatQuickBar:SetBackdropBorderColor(0, 0, 0, 0.8)

-- =========================================================================
--  COLLAPSE BUTTON
-- =========================================================================

local isChatCollapsed = false
local isAnimating = false
local COLLAPSED_BUBBLE_SIZE = 46
local collapsedBubbleBtn
local collapsedBubbleBg
local collapsedUnread = {
    size = 6,
    spacing = 2,
    columns = 5,
    indicators = {},
    buckets = {},
    anchor = nil,
}

-- Create collapse button
-- Forward declaration (used by collapse expand handler before definition)
local EmbedBlizzardCombatLog
-- Forward declaration (used by default chat interface toggle)
local ApplyDefaultChatVisibility
local clickZone
local AddCollapsedUnreadIndicator
local ClearCollapsedUnreadBuckets
local RefreshCollapseToggleVisibility

local collapseBtn = CreateFrame("Button", nil, Messenger, "BackdropTemplate")
collapseBtn:SetSize(20, 60)
collapseBtn:SetPoint("RIGHT", Messenger, "RIGHT", 0, 0)

-- Keep the collapse button proportional to the messenger height.
local function UpdateCollapseBtnSize()
    local h = Messenger:GetHeight()
    -- 15% of messenger height, clamped between 24 and 60 px
    local btnH = math.floor(h * 0.15)
    if btnH < 24 then btnH = 24 end
    if btnH > 60 then btnH = 60 end
    collapseBtn:SetHeight(btnH)
end
collapseBtn:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1
})
collapseBtn:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], 0.9)
collapseBtn:SetBackdropBorderColor(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], 1)

collapsedBubbleBtn = CreateFrame("Button", "MidnightMessengerCollapsedBubble", UIParent, "BackdropTemplate")
collapsedBubbleBtn:SetSize(COLLAPSED_BUBBLE_SIZE, COLLAPSED_BUBBLE_SIZE)
collapsedBubbleBtn:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 40, 40)
collapsedBubbleBtn:SetFrameStrata("MEDIUM")
collapsedBubbleBg = CreateFrame("Frame", nil, collapsedBubbleBtn, "BackdropTemplate")
collapsedBubbleBg:SetAllPoints()
collapsedBubbleBg:SetFrameLevel(collapsedBubbleBtn:GetFrameLevel())
collapsedBubbleBg:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 2,
    insets = { left = 2, right = 2, top = 2, bottom = 2 }
})
collapsedBubbleBg:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], 0.9)
collapsedBubbleBg:SetBackdropBorderColor(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], 1)
collapsedBubbleBtn.bgFrame = collapsedBubbleBg

local bubbleIcon = collapsedBubbleBtn:CreateTexture(nil, "OVERLAY")
bubbleIcon:SetSize(36, 36)
bubbleIcon:SetPoint("CENTER")
bubbleIcon:SetVertexColor(1, 1, 1, 1)
do
    local atlasCandidates = {
        "communities-icon-chat",
        "communities-icon-chatbubble",
        "socialqueuing-icon-chat",
    }
    local atlasApplied = false
    if bubbleIcon.SetAtlas and C_Texture and C_Texture.GetAtlasInfo then
        for _, atlasName in ipairs(atlasCandidates) do
            if C_Texture.GetAtlasInfo(atlasName) then
                bubbleIcon:SetAtlas(atlasName, false)
                bubbleIcon:SetSize(36, 36)
                atlasApplied = true
                break
            end
        end
    end
    if not atlasApplied then
        bubbleIcon:SetTexture("Interface\\Icons\\INV_Misc_GroupLooking")
        bubbleIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
end

local collapsedBubbleHighlight = collapsedBubbleBtn:CreateTexture(nil, "HIGHLIGHT")
collapsedBubbleHighlight:SetPoint("TOPLEFT", 2, -2)
collapsedBubbleHighlight:SetPoint("BOTTOMRIGHT", -2, 2)
collapsedBubbleHighlight:SetTexture("Interface\\Buttons\\WHITE8x8")
collapsedBubbleHighlight:SetVertexColor(1, 1, 1, 0.08)
collapsedBubbleHighlight:SetBlendMode("ADD")

collapsedUnread.anchor = CreateFrame("Frame", nil, UIParent)
collapsedUnread.anchor:SetPoint("TOPLEFT", collapsedBubbleBtn, "BOTTOMLEFT", 6, -4)
collapsedUnread.anchor:SetFrameStrata("MEDIUM")
collapsedUnread.anchor:SetFrameLevel(collapsedBubbleBtn:GetFrameLevel() + 1)
collapsedUnread.anchor:EnableMouse(false)
collapsedUnread.anchor:Hide()

-- Arrow text
local collapseArrow = collapseBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
collapseArrow:SetPoint("CENTER")
collapseArrow:SetText("<")
collapseArrow:SetTextColor(0.7, 0.7, 0.7)

-- Hook messenger resize: scale collapse arrow font and refresh tab layout.
do
    local sizeChangedGuard = false
    Messenger:HookScript("OnSizeChanged", function()
        if sizeChangedGuard then return end
        sizeChangedGuard = true
        UpdateCollapseBtnSize()
        -- Scale the arrow font to match the button
        local btnH = collapseBtn:GetHeight()
        if btnH <= 32 then
            collapseArrow:SetFontObject("GameFontNormalSmall")
        elseif btnH <= 44 then
            collapseArrow:SetFontObject("GameFontNormal")
        else
            collapseArrow:SetFontObject("GameFontNormalLarge")
        end
        -- Tabs also need to reflow when the frame is resized
        if type(_G.UpdateTabLayout) == "function" then _G.UpdateTabLayout() end
        -- Sub-tab headers need to reflow too (world channels, DM contacts)
        if type(UpdateWorldHeader) == "function" then pcall(UpdateWorldHeader) end
        if type(UpdateDMHeader) == "function" then pcall(UpdateDMHeader) end
        sizeChangedGuard = false
    end)
end

local function IsDefaultChatModeEnabled()
    local settings = MidnightUISettings and MidnightUISettings.Messenger
    return settings and settings.showDefaultChatInterface == true
end

do
    local COLLAPSED_UNREAD_ORDER = {
        "WHISPER", "WHISPER_INFORM",
        "OFFICER", "GUILD",
        "PARTY", "RAID", "INSTANCE_CHAT",
        "COMMUNITIES_CHANNEL",
        "WORLD_GENERAL", "WORLD_DEFENSE", "WORLD"
    }

    local function GetChatTypeColorRGB(chatType, fallbackR, fallbackG, fallbackB)
        if ChatTypeInfo and chatType and ChatTypeInfo[chatType] then
            local info = ChatTypeInfo[chatType]
            local r = tonumber(info.r or info[1])
            local g = tonumber(info.g or info[2])
            local b = tonumber(info.b or info[3])
            if r and g and b then
                return r, g, b
            end
        end
        return fallbackR or 1, fallbackG or 1, fallbackB or 1
    end

    local function HexColorToRGB(hex)
        if type(hex) ~= "string" then return nil end
        local clean = string.match(hex, "(%x%x%x%x%x%x)$")
        if not clean then return nil end
        local r = tonumber(string.sub(clean, 1, 2), 16)
        local g = tonumber(string.sub(clean, 3, 4), 16)
        local b = tonumber(string.sub(clean, 5, 6), 16)
        if not r or not g or not b then return nil end
        return r / 255, g / 255, b / 255
    end

    local function GetCollapsedUnreadKeys()
        local keys = {}
        local seen = {}
        for _, key in ipairs(COLLAPSED_UNREAD_ORDER) do
            local entry = collapsedUnread.buckets[key]
            if entry and entry.count and entry.count > 0 then
                keys[#keys + 1] = key
                seen[key] = true
            end
        end
        local extra = {}
        for key, entry in pairs(collapsedUnread.buckets) do
            if entry and entry.count and entry.count > 0 and not seen[key] then
                extra[#extra + 1] = key
            end
        end
        table.sort(extra)
        for _, key in ipairs(extra) do
            keys[#keys + 1] = key
        end
        return keys
    end

    local function GetCollapsedUnreadIndicator(index)
        local indicator = collapsedUnread.indicators[index]
        if indicator then return indicator end
        indicator = CreateFrame("Frame", nil, collapsedUnread.anchor, "BackdropTemplate")
        indicator:SetSize(collapsedUnread.size, collapsedUnread.size)
        indicator:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1
        })
        indicator:SetBackdropBorderColor(0, 0, 0, 0.95)
        indicator:Hide()
        collapsedUnread.indicators[index] = indicator
        return indicator
    end

    local function RefreshCollapsedUnreadIndicators()
        if not collapsedUnread.anchor then return end
        if IsDefaultChatModeEnabled() or not isChatCollapsed then
            for i = 1, #collapsedUnread.indicators do
                collapsedUnread.indicators[i]:Hide()
            end
            collapsedUnread.anchor:Hide()
            return
        end

        local keys = GetCollapsedUnreadKeys()
        local maxVisible = collapsedUnread.columns * 3
        local shown = math.min(#keys, maxVisible)

        for i = 1, shown do
            local bucket = collapsedUnread.buckets[keys[i]]
            if bucket then
                local indicator = GetCollapsedUnreadIndicator(i)
                local row = math.floor((i - 1) / collapsedUnread.columns)
                local col = (i - 1) % collapsedUnread.columns
                indicator:ClearAllPoints()
                indicator:SetPoint(
                    "TOPLEFT",
                    collapsedUnread.anchor,
                    "TOPLEFT",
                    col * (collapsedUnread.size + collapsedUnread.spacing),
                    -row * (collapsedUnread.size + collapsedUnread.spacing)
                )
                indicator:SetBackdropColor(bucket.r or 1, bucket.g or 1, bucket.b or 1, 0.95)
                indicator:Show()
            end
        end

        for i = shown + 1, #collapsedUnread.indicators do
            collapsedUnread.indicators[i]:Hide()
        end

        if shown > 0 then
            local rows = math.floor((shown - 1) / collapsedUnread.columns) + 1
            local width = (collapsedUnread.columns * collapsedUnread.size) + ((collapsedUnread.columns - 1) * collapsedUnread.spacing)
            local height = (rows * collapsedUnread.size) + ((rows - 1) * collapsedUnread.spacing)
            collapsedUnread.anchor:SetSize(width, height)
            collapsedUnread.anchor:Show()
        else
            collapsedUnread.anchor:Hide()
        end
    end

    local function ResolveCollapsedUnreadBucketKey(event, category, worldFilterKey)
        if event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_WHISPER" then
            return "WHISPER"
        elseif event == "CHAT_MSG_BN_WHISPER_INFORM" or event == "CHAT_MSG_WHISPER_INFORM" then
            return "WHISPER_INFORM"
        elseif event == "CHAT_MSG_OFFICER" then
            return "OFFICER"
        elseif event == "CHAT_MSG_GUILD" or event == "CHAT_MSG_GUILD_ACHIEVEMENT" or event == "GUILD_MOTD" then
            return "GUILD"
        elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" then
            return "PARTY"
        elseif event == "CHAT_MSG_RAID" or event == "CHAT_MSG_RAID_LEADER" then
            return "RAID"
        elseif event == "CHAT_MSG_INSTANCE_CHAT" or event == "CHAT_MSG_INSTANCE_CHAT_LEADER" then
            return "INSTANCE_CHAT"
        elseif event == "CHAT_MSG_COMMUNITIES_CHANNEL" then
            return "COMMUNITIES_CHANNEL"
        elseif category == "World" then
            if worldFilterKey == "TRADE" or worldFilterKey == "SERVICES" then
                return nil
            elseif worldFilterKey == "GENERAL" then
                return "WORLD_GENERAL"
            elseif worldFilterKey == "DEFENSE" then
                return "WORLD_DEFENSE"
            end
            return "WORLD"
        end

        local chatType = type(event) == "string" and string.gsub(event, "^CHAT_MSG_", "") or nil
        return chatType
    end

    local function ResolveCollapsedUnreadColor(bucketKey, dataObject)
        if bucketKey == "WORLD_GENERAL" or bucketKey == "WORLD_DEFENSE" or bucketKey == "WORLD" then
            local r, g, b = HexColorToRGB(dataObject and dataObject.nameColorDefault)
            if r and g and b then return r, g, b end
            return GetChatTypeColorRGB("CHANNEL", 1, 0.82, 0)
        end
        return GetChatTypeColorRGB(bucketKey, 1, 1, 1)
    end

    ClearCollapsedUnreadBuckets = function()
        for key in pairs(collapsedUnread.buckets) do
            collapsedUnread.buckets[key] = nil
        end
    end

    AddCollapsedUnreadIndicator = function(event, category, dataObject, worldFilterKey)
        if IsDefaultChatModeEnabled() or not isChatCollapsed then
            return
        end
        local bucketKey = ResolveCollapsedUnreadBucketKey(event, category, worldFilterKey)
        if not bucketKey then return end

        local r, g, b = ResolveCollapsedUnreadColor(bucketKey, dataObject)
        local bucket = collapsedUnread.buckets[bucketKey]
        if not bucket then
            bucket = { count = 0, r = r, g = g, b = b }
            collapsedUnread.buckets[bucketKey] = bucket
        end
        bucket.count = (bucket.count or 0) + 1
        bucket.r, bucket.g, bucket.b = r, g, b
        RefreshCollapsedUnreadIndicators()
    end

    RefreshCollapseToggleVisibility = function()
        if IsDefaultChatModeEnabled() then
            collapseBtn:Hide()
            collapsedBubbleBtn:Hide()
            if collapsedUnread.anchor then collapsedUnread.anchor:Hide() end
            return
        end

        if isChatCollapsed then
            collapseBtn:Hide()
            collapsedBubbleBtn:Show()
        else
            collapseBtn:Show()
            collapsedBubbleBtn:Hide()
        end
        RefreshCollapsedUnreadIndicators()
    end
end

local function SetCollapseButtonHoverState(hovered)
    local a = currentChatTheme and currentChatTheme.tabAlpha or 0.9
    if hovered then
        collapseBtn:SetBackdropColor(TAB_BG[1] + 0.1, TAB_BG[2] + 0.1, TAB_BG[3] + 0.1, math.min(a + 0.15, 1))
        collapseArrow:SetTextColor(1, 1, 1)
    else
        collapseBtn:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], a)
        collapseArrow:SetTextColor(0.7, 0.7, 0.7)
    end
end

local function SetCollapsedBubbleHoverState(hovered)
    if not collapsedBubbleBg then return end
    local a = currentChatTheme and currentChatTheme.tabAlpha or 0.9
    if hovered then
        collapsedBubbleBg:SetBackdropColor(TAB_BG[1] + 0.1, TAB_BG[2] + 0.1, TAB_BG[3] + 0.1, math.min(a + 0.15, 1))
    else
        collapsedBubbleBg:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], a)
    end
end

-- Hover effects
collapseBtn:SetScript("OnEnter", function(self)
    SetCollapseButtonHoverState(true)
end)

collapseBtn:SetScript("OnLeave", function(self)
    SetCollapseButtonHoverState(false)
end)

collapsedBubbleBtn:SetScript("OnEnter", function()
    SetCollapsedBubbleHoverState(true)
end)

collapsedBubbleBtn:SetScript("OnLeave", function()
    SetCollapsedBubbleHoverState(false)
end)

local function SetMessengerCollapsed(collapsed)
    if isAnimating then return end
    isAnimating = true

    isChatCollapsed = collapsed == true

    if isChatCollapsed then
        collapseArrow:SetText(">")
        ClearCollapsedUnreadBuckets()
        header:Hide()
        msgFrame:Hide()
        combatContainer:Hide()
        local eb = _G["ChatFrame1EditBox"]
        if eb then eb:Hide() end
        if clickZone then clickZone:Hide() end
        Messenger:Hide()
    else
        collapseArrow:SetText("<")
        ClearCollapsedUnreadBuckets()
        if not IsDefaultChatModeEnabled() then
            Messenger:Show()
            header:Show()
            header:SetAlpha(1)
            if ACTIVE_TAB == "CombatLog" then
                msgFrame:Hide()
                combatContainer:Show()
                EmbedBlizzardCombatLog(true)
                EnsureCombatQuickButtons()
                ScheduleCombatQuickButtonsReassert()
            else
                combatContainer:Hide()
                EmbedBlizzardCombatLog(false)
                msgFrame:Show()
                msgFrame:SetAlpha(1)
            end
            if clickZone then clickZone:Show() end
        end
    end

    RefreshCollapseToggleVisibility()
    isAnimating = false
end

local function ExpandMessengerFromCollapsed()
    if isChatCollapsed and not isAnimating then
        SetMessengerCollapsed(false)
    end
end

-- Toggle collapse/expand
collapseBtn:SetScript("OnClick", function(self)
    if isAnimating then return end
    SetMessengerCollapsed(not isChatCollapsed)
end)

collapsedBubbleBtn:SetScript("OnClick", function()
    ExpandMessengerFromCollapsed()
end)

RefreshCollapseToggleVisibility()

-- =========================================================================
--  4. LOGIC FUNCTIONS
-- =========================================================================

-- Forward declaration to allow Logic to call Input functions later
local RefreshInputLabel 

local function FindTradeChannel()
    local channelList = {GetChannelList()}
    for i = 1, #channelList, 3 do
        local channelId = channelList[i]
        local channelName = channelList[i + 1]
        if channelName then
            local lowerName = string.lower(channelName)
            if string.find(lowerName, "trade", 1, true) and not string.find(lowerName, "services", 1, true) and not string.find(lowerName, "service", 1, true) then
                return channelId, channelName
            end
        end
    end
    return nil
end

local function FindServicesChannel()
    local channelList = {GetChannelList()}
    for i = 1, #channelList, 3 do
        local channelId = channelList[i]
        local channelName = channelList[i + 1]
        if channelName then
            local lowerName = string.lower(channelName)
            if string.find(lowerName, "services", 1, true) or (string.find(lowerName, "service", 1, true) and string.find(lowerName, "trade", 1, true)) then
                return channelId, channelName
            end
        end
    end
    return nil
end

local function GetMapInfoSafe(mapId)
    if not mapId or not C_Map or not C_Map.GetMapInfo then return nil end
    local ok, info = pcall(C_Map.GetMapInfo, mapId)
    if ok then return info end
    return nil
end

local function GetPlayerMapIds()
    local bestMapId = nil
    local posMapId = nil
    if C_Map and C_Map.GetBestMapForUnit then
        local ok, result = pcall(C_Map.GetBestMapForUnit, "player")
        if ok then bestMapId = result end
    end
    if bestMapId and C_Map and C_Map.GetPlayerMapPosition and C_Map.GetMapInfoAtPosition then
        local okPos, pos = pcall(C_Map.GetPlayerMapPosition, bestMapId, "player")
        if okPos and pos then
            local okInfo, mapInfo = pcall(C_Map.GetMapInfoAtPosition, bestMapId, pos)
            if okInfo and mapInfo and mapInfo.mapID then
                posMapId = mapInfo.mapID
            end
        end
    end
    return bestMapId, posMapId
end

local function FindCityMapId(mapId)
    if not mapId or not Enum or not Enum.UIMapType or not Enum.UIMapType.City then return nil end
    local seen = {}
    local current = mapId
    while current and not seen[current] do
        seen[current] = true
        local info = GetMapInfoSafe(current)
        if info and info.mapType == Enum.UIMapType.City then
            return current
        end
        current = info and info.parentMapID or nil
    end
    return nil
end

local function IsMapDescendant(mapId, ancestorId)
    if not mapId or not ancestorId then return false end
    local seen = {}
    local current = mapId
    while current and not seen[current] do
        if current == ancestorId then return true end
        seen[current] = true
        local info = GetMapInfoSafe(current)
        current = info and info.parentMapID or nil
    end
    return false
end

local function IsInMajorCityAdvanced(reason)
    local subzone = GetSubZoneText() or ""
    local zone = GetRealZoneText() or ""
    local isResting = IsResting and IsResting() or false
    local lowerSub = string.lower(subzone)
    local lowerZone = string.lower(zone)
    local hasCityName = string.find(lowerSub, "city", 1, true) or string.find(lowerZone, "city", 1, true)

    local bestMapId, posMapId = GetPlayerMapIds()
    local cityMapId = FindCityMapId(posMapId) or FindCityMapId(bestMapId)
    local cityByMap = cityMapId ~= nil

    local tradeId, tradeName = FindTradeChannel()
    local servicesId, servicesName = FindServicesChannel()
    local inInstance = IsInInstance and IsInInstance() or false
    local hasChannels = (tradeId ~= nil) or (servicesId ~= nil)
    local cityByChannels = hasChannels and not inInstance

    local sticky = false
    if lastCityMapId and not inInstance then
        local isDesc = IsMapDescendant(posMapId, lastCityMapId) or IsMapDescendant(bestMapId, lastCityMapId)
        local age = time() - (lastCitySeenAt or 0)
        -- Sticky only within a short window and only inside the city map ancestry.
        if isDesc and age <= 60 then
            sticky = true
        end
    end

    local cityByResting = (not inInstance) and isResting and (subzone ~= "" or zone ~= "")
    -- Channels alone are not enough; they persist outside cities.
    local citySignals = cityByMap or hasCityName or cityByResting
    local isCity = citySignals or (cityByChannels and (citySignals or sticky)) or sticky

    if isCity then
        if cityMapId then
            lastCityMapId = cityMapId
        end
        lastCitySeenAt = time()
    else
        -- If we're clearly out of the city, clear sticky state to avoid lingering channels.
        if not inInstance and lastCityMapId then
            local isDesc = IsMapDescendant(posMapId, lastCityMapId) or IsMapDescendant(bestMapId, lastCityMapId)
            if not isDesc then
                lastCityMapId = nil
                lastCitySeenAt = 0
            end
        end
    end

    return isCity
end

local function FindChannelByName(patterns)
    local channelList = {GetChannelList()}
    for i = 1, #channelList, 3 do
        local channelId = channelList[i]
        local channelName = channelList[i + 1]
        if channelName then
            local lowerName = string.lower(channelName)
            for _, pattern in ipairs(patterns) do
                if string.find(lowerName, pattern, 1, true) then
                    return channelId, channelName
                end
            end
        end
    end
    return nil
end

-- Moved UP to ensure it exists before Headers try to use it
local function SetActiveChannel(channelId, channelName)
    if not channelId then return end
    ACTIVE_CHANNEL_ID = channelId
    ACTIVE_DM_FILTER = nil
    
    if channelName then
        -- We can't access GetWorldFilterKeyFromChannel here easily without reordering everything,
        -- so we do a quick check to set the filter correctly.
        local lower = string.lower(channelName)
        if string.find(lower, "services", 1, true) then ACTIVE_WORLD_FILTER = "SERVICES"
        elseif string.find(lower, "trade", 1, true) then ACTIVE_WORLD_FILTER = "TRADE"
        elseif string.find(lower, "general", 1, true) then ACTIVE_WORLD_FILTER = "GENERAL"
        elseif string.find(lower, "defense", 1, true) then ACTIVE_WORLD_FILTER = "DEFENSE"
        else ACTIVE_WORLD_FILTER = "ALL" end

        if MessengerDB and MessengerDB.WorldUnread and ACTIVE_WORLD_FILTER then
            MessengerDB.WorldUnread[ACTIVE_WORLD_FILTER] = 0
        end
        
        -- Force tab switch
        ACTIVE_TAB = "World"
        if TabButtons and TabButtons["World"] then 
            -- Manually simulate click logic to avoid circular calls if possible, 
            -- or just rely on the button script.
            -- TabButtons["World"]:Click() -- Risk of loop, let's just set state
        end
    end
    
    if RefreshInputLabel then RefreshInputLabel() end
end

local SafeToString
local function DMToString(value)
    if value == nil then return "nil" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[DirectDM-Restricted]" end
    return s
end

local function DMPushDiagnostics(msg)
    return
end

local function DMTrace(msg, _)
    return
end

local function DMAutoDiag(key, msg, throttle)
    return
end

local function DMCompactText(value, maxLen)
    local s = DMToString(value):gsub("\n", "\\n")
    local n = tonumber(maxLen) or 80
    if #s > n then
        s = s:sub(1, n) .. "..."
    end
    return s
end

local function DMDescribeEditBoxState(eb)
    if not eb then
        return string.format("eb=nil activeTab=%s activeFilter=%s", DMToString(ACTIVE_TAB), DMToString(ACTIVE_DM_FILTER))
    end
    local name = eb.GetName and eb:GetName() or "editbox"
    local shown = eb.IsShown and eb:IsShown() or false
    local visible = eb.IsVisible and eb:IsVisible() or false
    local focus = eb.HasFocus and eb:HasFocus() or false
    local chatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
    local tellTarget = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
    local channelTarget = eb.GetAttribute and eb:GetAttribute("channelTarget") or nil
    local text = eb.GetText and eb:GetText() or ""
    return string.format(
        "name=%s shown=%s visible=%s focus=%s chatType=%s tellTarget=%s channelTarget=%s activeTab=%s activeFilter=%s text=%s",
        DMToString(name),
        DMToString(shown),
        DMToString(visible),
        DMToString(focus),
        DMToString(chatType),
        DMCompactText(tellTarget, 60),
        DMToString(channelTarget),
        DMToString(ACTIVE_TAB),
        DMToString(ACTIVE_DM_FILTER),
        DMCompactText(text, 60)
    )
end

local function DMDescribeHistoryEntry(data)
    if type(data) ~= "table" then
        return "entry=nil"
    end
    local directKey = data.directKey
    local author = data.author
    local text = data.message or data.msg or data.text or ""
    local epoch = data.epoch
    return string.format(
        "directKey=%s author=%s epoch=%s text=%s",
        DMToString(directKey),
        DMToString(author),
        DMToString(epoch),
        DMCompactText(text, 48)
    )
end

local function DMCountKeys(t)
    local count = 0
    if type(t) == "table" then
        for _ in pairs(t) do count = count + 1 end
    end
    return count
end

local function IsBNetAnonToken(value)
    -- In WoW 12.0+, |K...|k is Blizzard's encoded Real ID name (decoded by FontStrings).
    -- These are NOT anonymous tokens — they render as the friend's real name.
    -- Only treat truly empty/nil values as anonymous.
    return false
end

local function IsBNetFallbackLabel(value)
    return type(value) == "string" and string.match(value, "^BNet Whisper %(.+%)$") ~= nil
end

local function ExtractBNetTokenFragment(value)
    if type(value) ~= "string" then return nil end
    local fromToken = value:match("^|K(.-)|k$")
    if fromToken and fromToken ~= "" then return fromToken end
    local fromFallback = value:match("^BNet Whisper %((.+)%)$")
    if fromFallback and fromFallback ~= "" then return fromFallback end
    return nil
end

local function BuildBNetTokenKey(value)
    local token = ExtractBNetTokenFragment(value) or tostring(value or "")
    token = token:gsub("|", "")
    token = string.lower(token)
    if token == "" then token = "unknown" end
    return "bn_token:" .. token
end

local function BuildLegacyBNetTokenLabel(token)
    if type(token) ~= "string" then return "BNet Whisper" end
    local inner = ExtractBNetTokenFragment(token)
    if inner and inner ~= "" then
        return "BNet Whisper (" .. inner .. ")"
    end
    return "BNet Whisper"
end

Messenger._directKey = Messenger._directKey or {}

function Messenger._directKey.AutoDiag(diagKey, message, minInterval)
    -- Diagnostics disabled in production messenger path.
    return
end

function Messenger._directKey.ParseBNetIDKey(key)
    if type(key) ~= "string" then return nil end
    local id = key:match("^bn:(%d+)$")
    id = tonumber(id)
    if not id or id <= 0 then return nil end
    return id
end

function Messenger._directKey.ParseBNetTokenKey(key)
    if type(key) ~= "string" then return nil end
    local token = key:match("^bn_token:(.+)$")
    if type(token) ~= "string" or token == "" then return nil end
    token = token:gsub("|", "")
    token = string.lower(token)
    if token == "" then return nil end
    return token
end

function Messenger._directKey.NormalizeTokenFragment(value)
    local token = ExtractBNetTokenFragment(value)
    if type(token) ~= "string" or token == "" then return nil end
    token = token:gsub("|", "")
    token = string.lower(token)
    if token == "" then return nil end
    return token
end

function Messenger._directKey.EnsureTokenAliasMap()
    if not MessengerDB then return nil end
    if type(MessengerDB.DirectTokenMap) ~= "table" then
        MessengerDB.DirectTokenMap = {}
    end
    return MessengerDB.DirectTokenMap
end

function Messenger._directKey.LookupTokenAlias(tokenFragment)
    local normalized = Messenger._directKey.NormalizeTokenFragment(tokenFragment)
    if not normalized then return nil end
    local map = MessengerDB and MessengerDB.DirectTokenMap
    if type(map) ~= "table" then return nil end
    local id = tonumber(map[normalized])
    if not id or id <= 0 then return nil end
    return id
end

function Messenger._directKey.RememberTokenAlias(tokenFragment, bnetID, reason)
    local normalized = Messenger._directKey.NormalizeTokenFragment(tokenFragment)
    local id = tonumber(bnetID)
    if not normalized or not id or id <= 0 then return nil end
    local map = Messenger._directKey.EnsureTokenAliasMap()
    if type(map) ~= "table" then return nil end
    local prev = tonumber(map[normalized])
    if prev ~= id then
        map[normalized] = id
        Messenger._directKey.AutoDiag(
            "dm_token_alias_set:" .. tostring(normalized),
            string.format(
                "dm_token_alias_set token=%s bnetID=%s prev=%s reason=%s",
                DMToString(normalized),
                DMToString(id),
                DMToString(prev),
                DMToString(reason)
            ),
            0
        )
    end
    return id
end

function Messenger._directKey.ResolveBNetIDFromKnownToken(tokenFragment)
    local normalized = nil
    if type(tokenFragment) == "string" and tokenFragment ~= "" then
        normalized = tokenFragment:gsub("|", "")
        normalized = string.lower(normalized)
        if normalized == "" then
            normalized = nil
        end
    end
    if not normalized then
        normalized = Messenger._directKey.NormalizeTokenFragment(tokenFragment)
    end
    if not normalized or normalized == "" then return nil end

    local mapID = Messenger._directKey.LookupTokenAlias(normalized)
    if mapID then
        return mapID
    end

    if MessengerDB and type(MessengerDB.DirectContacts) == "table" then
        for key, meta in pairs(MessengerDB.DirectContacts) do
            local keyID = Messenger._directKey.ParseBNetIDKey(key)
            local keyToken = Messenger._directKey.ParseBNetTokenKey(key)
            local metaID = tonumber(meta and meta.bnetID)
            local resolvedID = metaID or keyID
            if resolvedID then
                if keyToken == normalized then
                    Messenger._directKey.RememberTokenAlias(normalized, resolvedID, "contacts:key")
                    return resolvedID
                end
                local tellToken = Messenger._directKey.NormalizeTokenFragment(meta and meta.tellTarget)
                local displayToken = Messenger._directKey.NormalizeTokenFragment(meta and meta.displayName)
                if tellToken == normalized or displayToken == normalized then
                    Messenger._directKey.RememberTokenAlias(normalized, resolvedID, "contacts:meta")
                    return resolvedID
                end
            end
        end
    end

    if type(BNet_GetBNetIDAccount) == "function" then
        local candidates = {
            "|K" .. normalized .. "|k",
            normalized,
            "BNet Whisper (" .. normalized .. ")",
        }
        for i = 1, #candidates do
            local candidate = candidates[i]
            local ok, rawID = pcall(BNet_GetBNetIDAccount, candidate)
            local resolvedID = ok and tonumber(rawID) or nil
            if resolvedID and resolvedID > 0 then
                Messenger._directKey.RememberTokenAlias(normalized, resolvedID, "api:BNet_GetBNetIDAccount")
                Messenger._directKey.AutoDiag(
                    "dm_token_resolve_api:" .. tostring(normalized),
                    string.format(
                        "dm_token_resolve_api token=%s candidate=%s bnetID=%s",
                        DMToString(normalized),
                        DMToString(candidate),
                        DMToString(resolvedID)
                    ),
                    0.5
                )
                return resolvedID
            end
        end
    end

    Messenger._directKey.AutoDiag(
        "dm_token_resolve_fail:" .. tostring(normalized),
        string.format("dm_token_resolve_fail token=%s", DMToString(normalized)),
        0.6
    )
    return nil
end

function Messenger._directKey.ResolveCanonicalKey(dmKey, displayName, tellTarget, bnetID)
    if type(dmKey) ~= "string" or dmKey == "" then
        return dmKey, tonumber(bnetID)
    end

    local directID = Messenger._directKey.ParseBNetIDKey(dmKey)
    if directID then
        return "bn:" .. tostring(directID), directID
    end

    local token = Messenger._directKey.ParseBNetTokenKey(dmKey)
    local resolvedID = tonumber(bnetID)
    if token and not resolvedID then
        resolvedID = Messenger._directKey.ResolveBNetIDFromKnownToken(token)
    end
    if token and not resolvedID then
        resolvedID = Messenger._directKey.ResolveBNetIDFromKnownToken(displayName)
    end
    if token and not resolvedID then
        resolvedID = Messenger._directKey.ResolveBNetIDFromKnownToken(tellTarget)
    end
    if token and resolvedID then
        Messenger._directKey.RememberTokenAlias(token, resolvedID, "canonical")
        return "bn:" .. tostring(resolvedID), resolvedID
    end

    return dmKey, resolvedID
end

local function ResolveBNetIDFromTarget(target)
    if not target or target == "" or type(BNet_GetBNetIDAccount) ~= "function" then return nil end
    local ok, id = pcall(BNet_GetBNetIDAccount, target)
    if ok then
        id = tonumber(id)
        if id and id > 0 then return id end
    end

    local function NormalizeLookupValue(value)
        if type(value) ~= "string" then return nil end
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        if value == "" then return nil end
        return string.lower(value)
    end

    local wanted = NormalizeLookupValue(target)
    if not wanted then return nil end

    local function MatchCandidate(value)
        return NormalizeLookupValue(value) == wanted
    end

    local function ResolveFromAccountInfo(info)
        if type(info) ~= "table" then return nil end
        local accountID = tonumber(info.bnetAccountID) or tonumber(info.accountID)
        if not accountID or accountID <= 0 then return nil end
        if MatchCandidate(info.accountName) or MatchCandidate(info.battleTag) then
            return accountID
        end
        local gai = info.gameAccountInfo
        if type(gai) == "table" then
            if MatchCandidate(gai.characterName) or MatchCandidate(gai.characterName and gai.realmName and (gai.characterName .. "-" .. gai.realmName) or nil) then
                return accountID
            end
        end
        local gas = info.gameAccountInfos
        if type(gas) == "table" then
            for i = 1, #gas do
                local g = gas[i]
                if type(g) == "table" then
                    if MatchCandidate(g.characterName) or MatchCandidate(g.characterName and g.realmName and (g.characterName .. "-" .. g.realmName) or nil) then
                        return accountID
                    end
                end
            end
        end
        return nil
    end

    if C_BattleNet and type(C_BattleNet.GetFriendAccountInfo) == "function" and type(BNGetNumFriends) == "function" then
        local okN, num = pcall(BNGetNumFriends)
        num = okN and tonumber(num) or 0
        if num and num > 0 then
            for i = 1, num do
                local okInfo, info = pcall(C_BattleNet.GetFriendAccountInfo, i)
                if okInfo then
                    local resolvedID = ResolveFromAccountInfo(info)
                    if resolvedID then
                        Messenger._directKey.RememberTokenAlias(target, resolvedID, "resolve_target:friend_account")
                        return resolvedID
                    end
                end
            end
        end
    end

    if type(BNGetFriendInfo) == "function" and type(BNGetNumFriends) == "function" then
        local okN, num = pcall(BNGetNumFriends)
        num = okN and tonumber(num) or 0
        if num and num > 0 then
            for i = 1, num do
                local okInfo, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 = pcall(BNGetFriendInfo, i)
                if okInfo then
                    local values = { r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 }
                    local maybeID = nil
                    for j = 1, #values do
                        local candidate = tonumber(values[j])
                        if candidate and candidate > 0 then
                            maybeID = candidate
                            break
                        end
                    end
                    if maybeID then
                        for j = 1, #values do
                            if MatchCandidate(values[j]) then
                                Messenger._directKey.RememberTokenAlias(target, maybeID, "resolve_target:friend_info")
                                return maybeID
                            end
                        end
                    end
                end
            end
        end
    end

    id = tonumber(id)
    if not id or id <= 0 then return nil end
    return id
end

local function ResolveBNetDisplayNameByID(bnetID)
    bnetID = tonumber(bnetID)
    if not bnetID then return nil end

    Messenger._directKey._nameCache = Messenger._directKey._nameCache or {}
    local cache = Messenger._directKey._nameCache
    local cached = cache[bnetID]
    if type(cached) == "table" and (not cached.expiresAt or (time and time() < cached.expiresAt)) then
        if type(cached.name) == "string" and cached.name ~= "" then
            Messenger._directKey.AutoDiag(
                "dm_name_cache_hit:" .. tostring(bnetID),
                string.format("dm_name_cache_hit bnetID=%s name=%s", DMToString(bnetID), DMToString(cached.name)),
                1.0
            )
            return cached.name
        end
        Messenger._directKey.AutoDiag(
            "dm_name_cache_miss:" .. tostring(bnetID),
            string.format("dm_name_cache_miss bnetID=%s", DMToString(bnetID)),
            1.0
        )
        return nil
    end

    local attemptedAccount = false
    local attemptedFriendAccount = false
    local attemptedByID = false
    local attemptedFriendList = false

    local function IsUsableName(value)
        if type(value) ~= "string" then return false end
        value = value:gsub("^%s+", ""):gsub("%s+$", "")
        if value == "" then return false end
        if IsBNetFallbackLabel(value) then return false end
        if value == "Unknown" then return false end
        if value:match("^BNet%s+%d+$") then return false end
        return true
    end

    local function CacheName(name, sourceTag)
        if not IsUsableName(name) then return nil end
        cache[bnetID] = { name = name, expiresAt = (time and (time() + 300)) or nil }
        Messenger._directKey.AutoDiag(
            "dm_name_resolve:" .. tostring(bnetID) .. ":" .. tostring(sourceTag or "?"),
            string.format("dm_name_resolve bnetID=%s source=%s name=%s", DMToString(bnetID), DMToString(sourceTag or "?"), DMToString(name)),
            0.2
        )
        return name
    end

    local function PickFromAccountInfo(info, sourceTag)
        if type(info) ~= "table" then return nil end

        local candidate = CacheName(info.accountName, (sourceTag or "?") .. ":accountName")
        if candidate then return candidate end

        candidate = CacheName(info.battleTag, (sourceTag or "?") .. ":battleTag")
        if candidate then return candidate end

        local gai = info.gameAccountInfo
        if type(gai) == "table" then
            candidate = CacheName(gai.characterName, (sourceTag or "?") .. ":gameAccountInfo.characterName")
            if candidate then return candidate end
            candidate = CacheName(gai.characterName and gai.realmName and (gai.characterName .. "-" .. gai.realmName) or nil, (sourceTag or "?") .. ":gameAccountInfo.fullName")
            if candidate then return candidate end
        end

        local gas = info.gameAccountInfos
        if type(gas) == "table" then
            for i = 1, #gas do
                local g = gas[i]
                if type(g) == "table" then
                    candidate = CacheName(g.characterName, (sourceTag or "?") .. ":gameAccountInfos.characterName")
                    if candidate then return candidate end
                    candidate = CacheName(g.characterName and g.realmName and (g.characterName .. "-" .. g.realmName) or nil, (sourceTag or "?") .. ":gameAccountInfos.fullName")
                    if candidate then return candidate end
                end
            end
        end
        return nil
    end

    attemptedAccount = true
    if C_BattleNet and type(C_BattleNet.GetAccountInfoByID) == "function" then
        local ok, info = pcall(C_BattleNet.GetAccountInfoByID, bnetID)
        if ok and type(info) == "table" then
            local picked = PickFromAccountInfo(info, "GetAccountInfoByID")
            if picked then return picked end
        end
    end

    attemptedFriendAccount = true
    if C_BattleNet and type(C_BattleNet.GetFriendAccountInfo) == "function" and type(BNGetNumFriends) == "function" then
        local okN, num = pcall(BNGetNumFriends)
        num = okN and tonumber(num) or 0
        if num and num > 0 then
            for i = 1, num do
                local okF, info = pcall(C_BattleNet.GetFriendAccountInfo, i)
                if okF and type(info) == "table" then
                    local accountID = tonumber(info.bnetAccountID) or tonumber(info.accountID)
                    if accountID == bnetID then
                        local picked = PickFromAccountInfo(info, "GetFriendAccountInfo")
                        if picked then return picked end
                    end
                end
            end
        end
    end

    attemptedByID = true
    if type(BNGetFriendInfoByID) == "function" then
        local ok, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 = pcall(BNGetFriendInfoByID, bnetID)
        if ok then
            local candidates = { r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 }
            for i = 1, #candidates do
                local picked = CacheName(candidates[i], "BNGetFriendInfoByID:return" .. tostring(i))
                if picked then return picked end
            end
        end
    end

    attemptedFriendList = true
    if type(BNGetFriendInfo) == "function" and type(BNGetNumFriends) == "function" then
        local okN, num = pcall(BNGetNumFriends)
        num = okN and tonumber(num) or 0
        if num and num > 0 then
            for i = 1, num do
                local ok, r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 = pcall(BNGetFriendInfo, i)
                if ok then
                    local values = { r1, r2, r3, r4, r5, r6, r7, r8, r9, r10, r11, r12 }
                    local matched = false
                    for j = 1, #values do
                        local maybeID = tonumber(values[j])
                        if maybeID == bnetID then
                            matched = true
                            break
                        end
                    end
                    if matched then
                        for j = 1, #values do
                            local picked = CacheName(values[j], "BNGetFriendInfo:return" .. tostring(j))
                            if picked then return picked end
                        end
                    end
                end
            end
        end
    end

    cache[bnetID] = { name = "", expiresAt = (time and (time() + 30)) or nil }
    Messenger._directKey.AutoDiag(
        "dm_name_resolve_miss:" .. tostring(bnetID),
        string.format(
            "dm_name_resolve_miss bnetID=%s attemptedAccount=%s attemptedFriendAccount=%s attemptedByID=%s attemptedFriendList=%s",
            DMToString(bnetID),
            DMToString(attemptedAccount),
            DMToString(attemptedFriendAccount),
            DMToString(attemptedByID),
            DMToString(attemptedFriendList)
        ),
        0.2
    )
    return nil
end

local function BuildDirectIdentityFromChatTarget(chatType, tellTarget)
    local rawTarget = tostring(tellTarget or "")
    if rawTarget == "" then return nil end
    DMTrace(string.format("BuildFromChatTarget enter chatType=%s tellTarget=%s", DMToString(chatType), DMCompactText(rawTarget, 100)))

    if chatType == "BN_WHISPER" then
        if IsBNetAnonToken(rawTarget) then
            local token = Messenger._directKey.NormalizeTokenFragment(rawTarget)
            local inferredID = Messenger._directKey.ResolveBNetIDFromKnownToken(token)
            if inferredID then
                local displayName = ResolveBNetDisplayNameByID(inferredID) or BuildLegacyBNetTokenLabel(rawTarget)
                local directTarget = ResolveBNetDisplayNameByID(inferredID) or rawTarget
                local dmKey = "bn:" .. tostring(inferredID)
                Messenger._directKey.RememberTokenAlias(token, inferredID, "chat_target")
                DMTrace(string.format("BuildFromChatTarget token-promote key=%s display=%s bnetID=%s", DMToString(dmKey), DMToString(displayName), DMToString(inferredID)))
                return dmKey, displayName, directTarget, true, inferredID
            end
            local dmKey = BuildBNetTokenKey(rawTarget)
            local displayName = BuildLegacyBNetTokenLabel(rawTarget)
            Messenger._directKey.AutoDiag(
                "dm_token_unresolved:chat_target:" .. tostring(token),
                string.format("dm_token_unresolved source=BuildFromChatTarget token=%s tellTarget=%s", DMToString(token), DMToString(rawTarget)),
                0.4
            )
            DMTrace(string.format("BuildFromChatTarget token-path key=%s display=%s", DMToString(dmKey), DMToString(displayName)))
            return dmKey, displayName, nil, true, nil
        end

        local bnetID = ResolveBNetIDFromTarget(rawTarget)
        local displayName = ResolveBNetDisplayNameByID(bnetID) or rawTarget
        if IsBNetAnonToken(displayName) then
            displayName = BuildLegacyBNetTokenLabel(displayName)
        end
        local directTarget = rawTarget
        if IsBNetAnonToken(directTarget) and type(displayName) == "string" and displayName ~= "" and not IsBNetAnonToken(displayName) then
            directTarget = displayName
        end
        local dmKey = bnetID and ("bn:" .. tostring(bnetID)) or BuildBNetTokenKey(rawTarget)
        dmKey, bnetID = Messenger._directKey.ResolveCanonicalKey(dmKey, displayName, directTarget, bnetID)
        DMTrace(string.format("BuildFromChatTarget bn-path key=%s display=%s tellTarget=%s bnetID=%s", DMToString(dmKey), DMToString(displayName), DMCompactText(directTarget, 80), DMToString(bnetID)))
        return dmKey, displayName, directTarget, true, bnetID
    end

    local fullName = rawTarget
    local displayName = fullName
    if strfind(fullName, "-") then
        local short = strsplit("-", fullName)
        if short and short ~= "" then displayName = short end
    end
    local dmKey = "char:" .. string.lower(fullName)
    DMTrace(string.format("BuildFromChatTarget char-path key=%s display=%s full=%s", DMToString(dmKey), DMToString(displayName), DMToString(fullName)))
    return dmKey, displayName, fullName, false, nil
end

local function BuildDirectIdentityFromLegacyName(legacyName)
    if type(legacyName) ~= "string" or legacyName == "" then return nil end

    local fullChar = legacyName:match("^char:(.+)$")
    if fullChar and fullChar ~= "" then
        local displayName = fullChar
        if strfind(displayName, "-") then
            local short = strsplit("-", displayName)
            if short and short ~= "" then displayName = short end
        end
        DMTrace(string.format("BuildFromLegacy char-key=%s display=%s full=%s", DMToString(legacyName), DMToString(displayName), DMToString(fullChar)))
        return legacyName, displayName, fullChar, false, nil
    end

    local bnID = tonumber(legacyName:match("^bn:(%d+)$"))
    if bnID then
        local displayName = ResolveBNetDisplayNameByID(bnID) or ("BNet " .. tostring(bnID))
        DMTrace(string.format("BuildFromLegacy bn-id key=%s display=%s bnetID=%s", DMToString(legacyName), DMToString(displayName), DMToString(bnID)))
        return legacyName, displayName, displayName, true, bnID
    end

    local tokenData = legacyName:match("^bn_token:(.+)$")
    if tokenData and tokenData ~= "" then
        local safeToken = tokenData:gsub("|", "")
        safeToken = string.lower(safeToken)
        local inferredID = Messenger._directKey.ResolveBNetIDFromKnownToken(safeToken)
        if inferredID then
            local hydrated = ResolveBNetDisplayNameByID(inferredID)
            local displayName = hydrated or ("BNet Whisper (" .. safeToken .. ")")
            local tellTarget = hydrated or ("|K" .. safeToken .. "|k")
            Messenger._directKey.RememberTokenAlias(safeToken, inferredID, "legacy-key")
            DMTrace(string.format("BuildFromLegacy token-promote legacy=%s key=%s display=%s bnetID=%s", DMToString(legacyName), DMToString("bn:" .. tostring(inferredID)), DMToString(displayName), DMToString(inferredID)))
            return "bn:" .. tostring(inferredID), displayName, tellTarget, true, inferredID
        end
        DMTrace(string.format("BuildFromLegacy bn-token key=%s token=%s", DMToString(legacyName), DMToString(safeToken)))
        return legacyName, ("BNet Whisper (" .. safeToken .. ")"), nil, true, nil
    end

    local bnName = legacyName:match("^bn_name:(.+)$")
    if bnName and bnName ~= "" then
        DMTrace(string.format("BuildFromLegacy bn-name key=%s name=%s", DMToString(legacyName), DMToString(bnName)))
        return legacyName, bnName, bnName, true, nil
    end

    if IsBNetAnonToken(legacyName) or IsBNetFallbackLabel(legacyName) then
        local dmKey = BuildBNetTokenKey(legacyName)
        local displayName = BuildLegacyBNetTokenLabel(legacyName)
        DMTrace(string.format("BuildFromLegacy token-remap legacy=%s key=%s display=%s", DMToString(legacyName), DMToString(dmKey), DMToString(displayName)))
        return dmKey, displayName, nil, true, nil
    end

    if strfind(legacyName, " ") then
        local key = "bn_name:" .. string.lower(legacyName)
        DMTrace(string.format("BuildFromLegacy spaced-name key=%s name=%s", DMToString(key), DMToString(legacyName)))
        return key, legacyName, legacyName, true, nil
    end

    if strfind(legacyName, "-") then
        local short = strsplit("-", legacyName)
        if short and short ~= "" then
            DMTrace(string.format("BuildFromLegacy char-full key=%s short=%s full=%s", DMToString("char:" .. string.lower(legacyName)), DMToString(short), DMToString(legacyName)))
            return "char:" .. string.lower(legacyName), short, legacyName, false, nil
        end
    end

    local displayName = legacyName
    DMTrace(string.format("BuildFromLegacy fallback-char key=%s display=%s", DMToString("char:" .. string.lower(legacyName)), DMToString(displayName)))
    return "char:" .. string.lower(legacyName), displayName, legacyName, false, nil
end

local function GetDirectEventBNetID(...)
    -- `select(11, ...)` can expose extra trailing event args; isolate the first value before coercion.
    local rawBnetID = select(11, ...)
    if type(rawBnetID) == "number" then
        return rawBnetID
    end
    if type(rawBnetID) == "string" then
        return tonumber(rawBnetID)
    end
    return nil
end

local function BuildDirectIdentityFromEvent(event, author, ...)
    local isBNet = (event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM")
    local rawAuthor = SafeToString(author)
    if rawAuthor == "nil" or rawAuthor == "[Restricted]" or rawAuthor == "[Restricted Message Hidden]" then
        rawAuthor = "Unknown"
    end
    DMTrace(string.format("BuildFromEvent enter event=%s rawAuthor=%s", DMToString(event), DMCompactText(rawAuthor, 100)))

    if isBNet then
        if IsBNetAnonToken(rawAuthor) then
            local bnetID = GetDirectEventBNetID(...)
            if not bnetID then
                bnetID = Messenger._directKey.ResolveBNetIDFromKnownToken(Messenger._directKey.NormalizeTokenFragment(rawAuthor))
            end
            if bnetID then
                local displayName = ResolveBNetDisplayNameByID(bnetID) or BuildLegacyBNetTokenLabel(rawAuthor)
                local tellTarget = ResolveBNetDisplayNameByID(bnetID) or rawAuthor
                local dmKey = "bn:" .. tostring(bnetID)
                Messenger._directKey.RememberTokenAlias(rawAuthor, bnetID, "chat_event")
                DMTrace(string.format("BuildFromEvent token-promote event=%s key=%s display=%s bnetID=%s", DMToString(event), DMToString(dmKey), DMToString(displayName), DMToString(bnetID)))
                return dmKey, displayName, tellTarget, true, bnetID
            end
            local dmKey = BuildBNetTokenKey(rawAuthor)
            local displayName = BuildLegacyBNetTokenLabel(rawAuthor)
            Messenger._directKey.AutoDiag(
                "dm_token_unresolved:event:" .. tostring(Messenger._directKey.NormalizeTokenFragment(rawAuthor)),
                string.format("dm_token_unresolved source=BuildFromEvent event=%s author=%s", DMToString(event), DMToString(rawAuthor)),
                0.4
            )
            DMTrace(string.format("BuildFromEvent token-path event=%s key=%s display=%s", DMToString(event), DMToString(dmKey), DMToString(displayName)))
            return dmKey, displayName, nil, true, nil
        end
        local bnetID = GetDirectEventBNetID(...)
        if not bnetID then
            bnetID = ResolveBNetIDFromTarget(rawAuthor)
        end
        local displayName = ResolveBNetDisplayNameByID(bnetID) or rawAuthor
        if IsBNetAnonToken(displayName) then
            displayName = BuildLegacyBNetTokenLabel(displayName)
        end
        local tellTarget = rawAuthor
        if IsBNetAnonToken(tellTarget) and type(displayName) == "string" and displayName ~= "" and not IsBNetAnonToken(displayName) then
            tellTarget = displayName
        end
        local dmKey = bnetID and ("bn:" .. tostring(bnetID)) or BuildBNetTokenKey(rawAuthor)
        dmKey, bnetID = Messenger._directKey.ResolveCanonicalKey(dmKey, displayName, tellTarget, bnetID)
        DMTrace(string.format("BuildFromEvent bn-path event=%s key=%s display=%s tellTarget=%s bnetID=%s", DMToString(event), DMToString(dmKey), DMToString(displayName), DMCompactText(tellTarget, 80), DMToString(bnetID)))
        return dmKey, displayName, tellTarget, true, bnetID
    end

    local fullName = rawAuthor
    local displayName = fullName
    if strfind(fullName, "-") then
        local short = strsplit("-", fullName)
        if short and short ~= "" then displayName = short end
    end
    local dmKey = "char:" .. string.lower(fullName)
    DMTrace(string.format("BuildFromEvent char-path event=%s key=%s display=%s full=%s", DMToString(event), DMToString(dmKey), DMToString(displayName), DMToString(fullName)))
    return dmKey, displayName, fullName, false, nil
end

local function EnsureDirectContactStore()
    if not MessengerDB then return end
    if type(MessengerDB.ActiveWhispers) ~= "table" then MessengerDB.ActiveWhispers = {} end
    if type(MessengerDB.DirectContacts) ~= "table" then MessengerDB.DirectContacts = {} end
    if type(MessengerDB.DirectTokenMap) ~= "table" then MessengerDB.DirectTokenMap = {} end
end

function Messenger._directKey.MergeContactMeta(dst, src)
    if type(dst) ~= "table" or type(src) ~= "table" then return end

    local srcDisplay = src.displayName
    local dstDisplay = dst.displayName
    local srcDisplayFallback = IsBNetAnonToken(srcDisplay) or IsBNetFallbackLabel(srcDisplay)
    local dstDisplayFallback = IsBNetAnonToken(dstDisplay) or IsBNetFallbackLabel(dstDisplay)
    if type(srcDisplay) == "string" and srcDisplay ~= "" then
        if (type(dstDisplay) ~= "string" or dstDisplay == "") or (dstDisplayFallback and not srcDisplayFallback) then
            dst.displayName = srcDisplay
        end
    end

    local srcTell = src.tellTarget
    local dstTell = dst.tellTarget
    local srcTellToken = IsBNetAnonToken(srcTell)
    local dstTellToken = IsBNetAnonToken(dstTell)
    if type(srcTell) == "string" and srcTell ~= "" then
        if (type(dstTell) ~= "string" or dstTell == "") or (dstTellToken and not srcTellToken) then
            dst.tellTarget = srcTell
        end
    end

    if src.isBNet == true then
        dst.isBNet = true
    end
    if src.bnetID and not dst.bnetID then
        dst.bnetID = tonumber(src.bnetID)
    end
end

function Messenger._directKey.RewriteKeyReferences(oldKey, newKey)
    if not MessengerDB or type(oldKey) ~= "string" or type(newKey) ~= "string" or oldKey == newKey then return end

    local activeChanged = 0
    local msgChanged = 0

    if type(MessengerDB.ActiveWhispers) == "table" then
        for i = 1, #MessengerDB.ActiveWhispers do
            if MessengerDB.ActiveWhispers[i] == oldKey then
                MessengerDB.ActiveWhispers[i] = newKey
                activeChanged = activeChanged + 1
            end
        end

        local dedup, seen = {}, {}
        for i = 1, #MessengerDB.ActiveWhispers do
            local key = MessengerDB.ActiveWhispers[i]
            if type(key) == "string" and key ~= "" and not seen[key] then
                seen[key] = true
                dedup[#dedup + 1] = key
            end
        end
        MessengerDB.ActiveWhispers = dedup
    end

    if type(MessengerDB.History) == "table" then
        local function RewriteBucket(bucketName)
            local bucket = MessengerDB.History[bucketName]
            if not bucket or type(bucket.messages) ~= "table" then return end
            for i = 1, #bucket.messages do
                local data = bucket.messages[i]
                if type(data) == "table" and data.directKey == oldKey then
                    data.directKey = newKey
                    msgChanged = msgChanged + 1
                end
            end
        end
        RewriteBucket("Direct")
        RewriteBucket("Global")
    end

    if activeChanged > 0 or msgChanged > 0 then
        DMTrace(string.format("RewriteDirectKey old=%s new=%s active=%d messages=%d", DMToString(oldKey), DMToString(newKey), activeChanged, msgChanged), true)
    end
end

function Messenger._directKey.BackfillTokenAliases(reason)
    if not MessengerDB then return end
    EnsureDirectContactStore()
    local mapped = 0
    local why = DMToString(reason or "unspecified")
    local function Remember(value, bnetID, source)
        local token = Messenger._directKey.NormalizeTokenFragment(value)
        local id = tonumber(bnetID)
        if not token or not id or id <= 0 then return end
        local prev = Messenger._directKey.LookupTokenAlias(token)
        local now = Messenger._directKey.RememberTokenAlias(token, id, source)
        if now and now ~= prev then
            mapped = mapped + 1
        end
    end

    if type(MessengerDB.DirectContacts) == "table" then
        for key, meta in pairs(MessengerDB.DirectContacts) do
            local id = tonumber(meta and meta.bnetID) or Messenger._directKey.ParseBNetIDKey(key)
            if id then
                Remember(Messenger._directKey.ParseBNetTokenKey(key), id, "backfill:contacts:key")
                if type(meta) == "table" then
                    Remember(meta.tellTarget, id, "backfill:contacts:tell")
                    Remember(meta.displayName, id, "backfill:contacts:display")
                end
            end
        end
    end

    local directBucket = MessengerDB.History and MessengerDB.History["Direct"]
    local messages = directBucket and directBucket.messages
    if type(messages) == "table" then
        for i = 1, #messages do
            local data = messages[i]
            if type(data) == "table" then
                local id = tonumber(data.bnetID) or Messenger._directKey.ParseBNetIDKey(data.directKey)
                if id then
                    local token = Messenger._directKey.ParseBNetTokenKey(data.directKey) or Messenger._directKey.NormalizeTokenFragment(data.author)
                    Remember(token, id, "backfill:history")
                end
            end
        end
    end

    if mapped > 0 then
        DMTrace(string.format("BackfillTokenAliases reason=%s mapped=%d", why, mapped), true)
    end
end

function Messenger._directKey.NormalizeContactKeys(reason)
    if not MessengerDB then return end
    EnsureDirectContactStore()
    if type(MessengerDB.DirectContacts) ~= "table" then return end
    Messenger._directKey.BackfillTokenAliases((reason or "normalize") .. ":pre")

    local rewrites = 0
    local hydrated = 0
    local keys = {}
    for key in pairs(MessengerDB.DirectContacts) do
        keys[#keys + 1] = key
    end

    for i = 1, #keys do
        local oldKey = keys[i]
        local meta = MessengerDB.DirectContacts[oldKey]
        local canonicalKey, canonicalID = Messenger._directKey.ResolveCanonicalKey(
            oldKey,
            meta and meta.displayName,
            meta and meta.tellTarget,
            meta and meta.bnetID
        )
        if canonicalID and type(meta) == "table" then
            meta.bnetID = canonicalID
        end
        if canonicalID then
            Messenger._directKey.RememberTokenAlias(Messenger._directKey.ParseBNetTokenKey(oldKey), canonicalID, "normalize:key")
            if type(meta) == "table" then
                Messenger._directKey.RememberTokenAlias(meta.tellTarget, canonicalID, "normalize:tell")
                Messenger._directKey.RememberTokenAlias(meta.displayName, canonicalID, "normalize:display")
            end
        end
        if canonicalKey and canonicalKey ~= oldKey then
            local dstMeta = MessengerDB.DirectContacts[canonicalKey]
            if type(dstMeta) ~= "table" then
                dstMeta = {}
                MessengerDB.DirectContacts[canonicalKey] = dstMeta
            end
            if type(meta) == "table" then
                Messenger._directKey.MergeContactMeta(dstMeta, meta)
            end
            MessengerDB.DirectContacts[oldKey] = nil
            Messenger._directKey.RewriteKeyReferences(oldKey, canonicalKey)
            rewrites = rewrites + 1
        end
    end

    for key, meta in pairs(MessengerDB.DirectContacts) do
        if type(meta) == "table" then
            local bnetID = tonumber(meta.bnetID) or Messenger._directKey.ParseBNetIDKey(key)
            local current = type(meta.displayName) == "string" and meta.displayName or nil
            local needsHydrate = (not current or current == "" or IsBNetAnonToken(current) or IsBNetFallbackLabel(current) or current:match("^BNet%s+%d+$"))
            if bnetID and needsHydrate then
                local resolved = ResolveBNetDisplayNameByID(bnetID)
                if type(resolved) == "string" and resolved ~= "" and not IsBNetAnonToken(resolved) and not IsBNetFallbackLabel(resolved) then
                    meta.displayName = resolved
                    meta.bnetID = bnetID
                    if type(meta.tellTarget) ~= "string" or meta.tellTarget == "" or IsBNetAnonToken(meta.tellTarget) or IsBNetFallbackLabel(meta.tellTarget) then
                        meta.tellTarget = resolved
                    end
                    hydrated = hydrated + 1
                end
            end
        end
    end

    if rewrites > 0 then
        DMTrace(string.format("NormalizeDirectContactKeys reason=%s rewrites=%d", DMToString(reason), rewrites), true)
    end
    if hydrated > 0 then
        DMTrace(string.format("NormalizeDirectContactKeys reason=%s hydrated=%d", DMToString(reason), hydrated), true)
    end
    if rewrites > 0 or hydrated > 0 then
        Messenger._directKey.BackfillTokenAliases((reason or "normalize") .. ":post")
    end
end

local function RegisterDirectContact(dmKey, displayName, tellTarget, isBNet, bnetID)
    if not MessengerDB or not dmKey or dmKey == "" then return false end
    EnsureDirectContactStore()

    local originalKey = dmKey
    local canonicalKey, canonicalBnetID = Messenger._directKey.ResolveCanonicalKey(dmKey, displayName, tellTarget, bnetID)
    if canonicalKey and canonicalKey ~= "" then
        dmKey = canonicalKey
    end
    if canonicalBnetID then
        bnetID = canonicalBnetID
    end

    if bnetID then
        Messenger._directKey.RememberTokenAlias(Messenger._directKey.ParseBNetTokenKey(originalKey), bnetID, "register:original_key")
        Messenger._directKey.RememberTokenAlias(Messenger._directKey.ParseBNetTokenKey(dmKey), bnetID, "register:key")
        Messenger._directKey.RememberTokenAlias(displayName, bnetID, "register:display")
        Messenger._directKey.RememberTokenAlias(tellTarget, bnetID, "register:tell")
    end

    if bnetID then
        local incomingFallback = IsBNetAnonToken(displayName) or IsBNetFallbackLabel(displayName)
        local tellFallback = IsBNetAnonToken(tellTarget) or IsBNetFallbackLabel(tellTarget)
        if incomingFallback or (type(displayName) ~= "string" or displayName == "") then
            local hydrated = ResolveBNetDisplayNameByID(bnetID)
            if type(hydrated) == "string" and hydrated ~= "" and not IsBNetAnonToken(hydrated) and not IsBNetFallbackLabel(hydrated) then
                displayName = hydrated
            end
        end
        if tellFallback or (type(tellTarget) ~= "string" or tellTarget == "") then
            local hydratedTell = ResolveBNetDisplayNameByID(bnetID)
            if type(hydratedTell) == "string" and hydratedTell ~= "" and not IsBNetAnonToken(hydratedTell) and not IsBNetFallbackLabel(hydratedTell) then
                tellTarget = hydratedTell
            end
        end
    end

    if originalKey ~= dmKey then
        local oldMeta = MessengerDB.DirectContacts and MessengerDB.DirectContacts[originalKey]
        if type(oldMeta) == "table" then
            local newMeta = MessengerDB.DirectContacts[dmKey]
            if type(newMeta) ~= "table" then
                newMeta = {}
                MessengerDB.DirectContacts[dmKey] = newMeta
            end
            Messenger._directKey.MergeContactMeta(newMeta, oldMeta)
            MessengerDB.DirectContacts[originalKey] = nil
        end
        Messenger._directKey.RewriteKeyReferences(originalKey, dmKey)
        DMTrace(string.format("RegisterContact canonicalize old=%s new=%s bnetID=%s", DMToString(originalKey), DMToString(dmKey), DMToString(bnetID)))
    end

    local meta = MessengerDB.DirectContacts[dmKey]
    local hadMeta = (type(meta) == "table")
    if type(meta) ~= "table" then
        meta = {}
        MessengerDB.DirectContacts[dmKey] = meta
    end
    local prevDisplay = meta.displayName
    local prevTell = meta.tellTarget
    local prevIsBNet = meta.isBNet
    local prevBNetID = meta.bnetID

    if type(displayName) == "string" and displayName ~= "" then
        local incomingFallback = IsBNetAnonToken(displayName) or IsBNetFallbackLabel(displayName)
        local current = meta.displayName
        local currentFallback = IsBNetAnonToken(current) or IsBNetFallbackLabel(current)
        if (not incomingFallback) or (not current or current == "") or currentFallback then
            meta.displayName = displayName
        end
    end
    if type(tellTarget) == "string" and tellTarget ~= "" then
        local currentTell = meta.tellTarget
        local incomingToken = IsBNetAnonToken(tellTarget)
        local currentToken = IsBNetAnonToken(currentTell)
        if (not currentTell or currentTell == "") or (currentToken and not incomingToken) then
            meta.tellTarget = tellTarget
        end
    end
    if isBNet == true then
        meta.isBNet = true
    elseif meta.isBNet == nil and isBNet ~= nil then
        meta.isBNet = false
    end
    if bnetID then
        meta.bnetID = tonumber(bnetID)
    end
    if meta.bnetID then
        Messenger._directKey.RememberTokenAlias(Messenger._directKey.ParseBNetTokenKey(dmKey), meta.bnetID, "register:meta_key")
        Messenger._directKey.RememberTokenAlias(meta.displayName, meta.bnetID, "register:meta_display")
        Messenger._directKey.RememberTokenAlias(meta.tellTarget, meta.bnetID, "register:meta_tell")
    end

    if Messenger._directKey.ParseBNetIDKey(dmKey) and (IsBNetFallbackLabel(meta.displayName) or IsBNetAnonToken(meta.displayName)) then
        Messenger._directKey.AutoDiag(
            "dm_contact_fallback:" .. tostring(dmKey),
            string.format(
                "dm_contact_fallback key=%s bnetID=%s display=%s tell=%s incomingDisplay=%s incomingTell=%s",
                DMToString(dmKey),
                DMToString(meta.bnetID),
                DMToString(meta.displayName),
                DMToString(meta.tellTarget),
                DMToString(displayName),
                DMToString(tellTarget)
            ),
            0.4
        )
    end

    local exists = false
    for _, key in ipairs(MessengerDB.ActiveWhispers) do
        if key == dmKey then
            exists = true
            break
        end
    end
    if not exists then
        table.insert(MessengerDB.ActiveWhispers, dmKey)
        DMTrace(string.format(
            "RegisterContact insert key=%s display=%s tell=%s isBNet=%s bnetID=%s hadMeta=%s prevDisplay=%s prevTell=%s",
            DMToString(dmKey),
            DMToString(meta.displayName),
            DMToString(meta.tellTarget),
            DMToString(meta.isBNet),
            DMToString(meta.bnetID),
            DMToString(hadMeta),
            DMToString(prevDisplay),
            DMToString(prevTell)
        ))
        return true, dmKey
    end
    if prevDisplay ~= meta.displayName or prevTell ~= meta.tellTarget or prevIsBNet ~= meta.isBNet or prevBNetID ~= meta.bnetID then
        DMTrace(string.format(
            "RegisterContact update key=%s display:%s->%s tell:%s->%s isBNet:%s->%s bnetID:%s->%s",
            DMToString(dmKey),
            DMToString(prevDisplay),
            DMToString(meta.displayName),
            DMToString(prevTell),
            DMToString(meta.tellTarget),
            DMToString(prevIsBNet),
            DMToString(meta.isBNet),
            DMToString(prevBNetID),
            DMToString(meta.bnetID)
        ))
    end
    return false, dmKey
end

local function GetDirectContactMeta(dmKey)
    if not MessengerDB or type(MessengerDB.DirectContacts) ~= "table" then return nil end
    local meta = MessengerDB.DirectContacts[dmKey]
    if type(meta) ~= "table" then return nil end
    return meta
end

local function GetDirectDisplayName(dmKey)
    local meta = GetDirectContactMeta(dmKey)
    if meta then
        local bnetID = tonumber(meta.bnetID) or Messenger._directKey.ParseBNetIDKey(dmKey)
        if not bnetID then
            local keyToken = Messenger._directKey.ParseBNetTokenKey(dmKey)
            if keyToken then
                local inferredID = Messenger._directKey.ResolveBNetIDFromKnownToken(keyToken)
                if inferredID then
                    bnetID = inferredID
                    meta.bnetID = inferredID
                    Messenger._directKey.AutoDiag(
                        "dm_label_token_promote:" .. tostring(dmKey),
                        string.format(
                            "dm_label_token_promote key=%s token=%s bnetID=%s",
                            DMToString(dmKey),
                            DMToString(keyToken),
                            DMToString(inferredID)
                        ),
                        0
                    )
                end
            end
        end
        local current = type(meta.displayName) == "string" and meta.displayName or nil
        local needsHydrate = (not current or current == "" or IsBNetAnonToken(current) or IsBNetFallbackLabel(current) or current:match("^BNet%s+%d+$"))
        if bnetID and needsHydrate then
            local hydrated = ResolveBNetDisplayNameByID(bnetID)
            if type(hydrated) == "string" and hydrated ~= "" and not IsBNetAnonToken(hydrated) and not IsBNetFallbackLabel(hydrated) then
                meta.displayName = hydrated
                meta.bnetID = bnetID
                if type(meta.tellTarget) ~= "string" or meta.tellTarget == "" or IsBNetAnonToken(meta.tellTarget) or IsBNetFallbackLabel(meta.tellTarget) then
                    meta.tellTarget = hydrated
                end
                Messenger._directKey.AutoDiag(
                    "dm_label_hydrate:" .. tostring(dmKey),
                    string.format(
                        "dm_label_hydrate key=%s bnetID=%s hydrated=%s prevDisplay=%s prevTell=%s",
                        DMToString(dmKey),
                        DMToString(bnetID),
                        DMToString(hydrated),
                        DMToString(current),
                        DMToString(meta.tellTarget)
                    ),
                    0
                )
                return hydrated
            else
                Messenger._directKey.AutoDiag(
                    "dm_label_hydrate_fail:" .. tostring(dmKey),
                    string.format(
                        "dm_label_hydrate_fail key=%s bnetID=%s current=%s tell=%s",
                        DMToString(dmKey),
                        DMToString(bnetID),
                        DMToString(current),
                        DMToString(meta.tellTarget)
                    ),
                    0.4
                )
            end
        end
        if current and current ~= "" then
            if IsBNetFallbackLabel(current) or IsBNetAnonToken(current) then
                Messenger._directKey.AutoDiag(
                    "dm_label_fallback_meta:" .. tostring(dmKey),
                    string.format(
                        "dm_label_fallback source=meta key=%s bnetID=%s display=%s tell=%s",
                        DMToString(dmKey),
                        DMToString(bnetID),
                        DMToString(current),
                        DMToString(meta.tellTarget)
                    ),
                    0.4
                )
            end
            return current
        end
    end
    if type(dmKey) == "string" and dmKey ~= "" then
        local fromToken = dmKey:match("^bn_token:(.+)$")
        if fromToken and fromToken ~= "" then
            Messenger._directKey.AutoDiag(
                "dm_label_fallback_tokenkey:" .. tostring(dmKey),
                string.format("dm_label_fallback source=token_key key=%s token=%s", DMToString(dmKey), DMToString(fromToken)),
                0.4
            )
            return "BNet Whisper (" .. fromToken .. ")"
        end
        local fromBNID = dmKey:match("^bn:(%d+)$")
        if fromBNID then
            local hydrated = ResolveBNetDisplayNameByID(tonumber(fromBNID))
            if type(hydrated) == "string" and hydrated ~= "" and not IsBNetAnonToken(hydrated) and not IsBNetFallbackLabel(hydrated) then
                return hydrated
            end
            Messenger._directKey.AutoDiag(
                "dm_label_fallback_bnid:" .. tostring(dmKey),
                string.format("dm_label_fallback source=bnid_unresolved key=%s bnetID=%s", DMToString(dmKey), DMToString(fromBNID)),
                0.4
            )
        end
        local fromLegacyName = dmKey:match("^bn_name:(.+)$")
        if fromLegacyName and fromLegacyName ~= "" then
            return fromLegacyName
        end
        local fromKey = dmKey:match("^char:(.+)$") or dmKey:match("^bn:(.+)$")
        if fromKey and fromKey ~= "" then return fromKey end
        return dmKey
    end
    return "Unknown"
end

local function DumpDirectState(reason, maxMessages)
    if not MessengerDB then
        DMTrace("DumpDirectState skipped (MessengerDB=nil)", true)
        return
    end
    local active = MessengerDB.ActiveWhispers or {}
    local contacts = MessengerDB.DirectContacts or {}
    local directBucket = MessengerDB.History and MessengerDB.History["Direct"]
    local messages = (directBucket and directBucket.messages) or {}
    local limit = tonumber(maxMessages) or 20
    if limit < 1 then limit = 1 end
    if limit > 200 then limit = 200 end

    DMTrace(string.format(
        "DumpDirectState reason=%s activeFilter=%s activeTab=%s activeWhispers=%d contacts=%d directMessages=%d unread=%s",
        DMToString(reason),
        DMToString(ACTIVE_DM_FILTER),
        DMToString(ACTIVE_TAB),
        #active,
        DMCountKeys(contacts),
        #messages,
        DMToString(directBucket and directBucket.unread)
    ), true)

    local contactLines = 0
    for idx, key in ipairs(active) do
        if idx > 60 then
            DMTrace("DumpDirectState active list truncated at 60 entries", true)
            break
        end
        local meta = contacts[key]
        DMTrace(string.format(
            "  active[%d] key=%s label=%s display=%s tell=%s isBNet=%s bnetID=%s",
            idx,
            DMToString(key),
            DMToString(GetDirectDisplayName(key)),
            DMToString(meta and meta.displayName),
            DMToString(meta and meta.tellTarget),
            DMToString(meta and meta.isBNet),
            DMToString(meta and meta.bnetID)
        ), true)
        contactLines = contactLines + 1
    end
    if contactLines == 0 then
        DMTrace("  active list empty", true)
    end

    local upper = math.min(#messages, limit)
    for i = 1, upper do
        local m = messages[i]
        DMTrace(string.format(
            "  msg[%d] ts=%s author=%s key=%s bnetID=%s text=%s",
            i,
            DMToString(m and m.timestamp),
            DMToString(m and m.author),
            DMToString(m and m.directKey),
            DMToString(m and m.bnetID),
            DMCompactText(m and m.msg, 100)
        ), true)
    end
    if #messages > upper then
        DMTrace(string.format("  message list truncated at %d of %d", upper, #messages), true)
    end
end

local function ResolveDirectMessageKey(data)
    if type(data) ~= "table" then return nil end
    if type(data.directKey) == "string" and data.directKey ~= "" then
        local existingBnetFromKey = Messenger._directKey.ParseBNetIDKey(data.directKey)
        local existingBnetID = existingBnetFromKey or tonumber(data.bnetID)
        if IsBNetAnonToken(data.author) or IsBNetFallbackLabel(data.author) then
            if existingBnetFromKey then
                -- Do not downgrade canonical BN-ID keys based on anonymous display labels.
                data.directKey = "bn:" .. tostring(existingBnetFromKey)
                if not data.bnetID then
                    data.bnetID = existingBnetFromKey
                end
            else
                local remapKey, remapName, remapTarget, remapIsBNet, remapBnetID = BuildDirectIdentityFromLegacyName(data.author)
                local preferredBnetID = remapBnetID or existingBnetID
                local canonicalKey, canonicalBnetID = Messenger._directKey.ResolveCanonicalKey(remapKey, remapName, remapTarget, preferredBnetID)
                if canonicalKey and canonicalKey ~= data.directKey then
                    DMTrace(string.format("ResolveDirectMessageKey remap oldKey=%s newKey=%s author=%s", DMToString(data.directKey), DMToString(canonicalKey), DMToString(data.author)))
                    data.directKey = canonicalKey
                end
                if canonicalBnetID and not data.bnetID then
                    data.bnetID = canonicalBnetID
                end
                if canonicalKey then
                    RegisterDirectContact(canonicalKey, remapName, remapTarget, remapIsBNet, canonicalBnetID or remapBnetID)
                end
            end
        end

        local meta = GetDirectContactMeta(data.directKey)
        if not meta then
            local _, displayName, tellTarget, isBNet, bnetID = BuildDirectIdentityFromLegacyName(data.directKey)
            local canonicalKey, canonicalBnetID = Messenger._directKey.ResolveCanonicalKey(data.directKey, displayName, tellTarget, bnetID or data.bnetID)
            if canonicalKey and canonicalKey ~= data.directKey then
                DMTrace(string.format("ResolveDirectMessageKey canonicalize oldKey=%s newKey=%s", DMToString(data.directKey), DMToString(canonicalKey)))
                data.directKey = canonicalKey
            end
            if canonicalBnetID and not data.bnetID then
                data.bnetID = canonicalBnetID
            end
            RegisterDirectContact(data.directKey, displayName, tellTarget, isBNet, canonicalBnetID or bnetID or data.bnetID)
            meta = GetDirectContactMeta(data.directKey)
        end
        if IsBNetAnonToken(data.author) or IsBNetFallbackLabel(data.author) then
            if meta and type(meta.displayName) == "string" and meta.displayName ~= "" then
                data.author = meta.displayName
            else
                data.author = BuildLegacyBNetTokenLabel(data.author)
            end
        elseif (not data.author or data.author == "") and meta and type(meta.displayName) == "string" and meta.displayName ~= "" then
            data.author = meta.displayName
        end
        if IsBNetFallbackLabel(data.author) or IsBNetAnonToken(data.author) then
            Messenger._directKey.AutoDiag(
                "dm_msg_author_fallback:" .. tostring(data.directKey),
                string.format(
                    "dm_msg_author_fallback key=%s bnetID=%s author=%s metaDisplay=%s metaTell=%s",
                    DMToString(data.directKey),
                    DMToString(data.bnetID),
                    DMToString(data.author),
                    DMToString(meta and meta.displayName),
                    DMToString(meta and meta.tellTarget)
                ),
                0.3
            )
        end
        return data.directKey
    end

    local key, displayName, tellTarget, isBNet, bnetID = BuildDirectIdentityFromLegacyName(data.author)
    if not key then return nil end
    key, bnetID = Messenger._directKey.ResolveCanonicalKey(key, displayName, tellTarget, bnetID or data.bnetID)
    DMTrace(string.format("ResolveDirectMessageKey assign key=%s author=%s display=%s", DMToString(key), DMToString(data.author), DMToString(displayName)))
    data.directKey = key
    if type(displayName) == "string" and displayName ~= "" then
        data.author = displayName
    end
    if bnetID then
        data.bnetID = bnetID
    end
    RegisterDirectContact(key, displayName, tellTarget, isBNet, bnetID)
    if IsBNetFallbackLabel(data.author) or IsBNetAnonToken(data.author) then
        Messenger._directKey.AutoDiag(
            "dm_msg_author_fallback_assign:" .. tostring(key),
            string.format(
                "dm_msg_author_fallback_assign key=%s bnetID=%s author=%s display=%s tell=%s",
                DMToString(key),
                DMToString(data.bnetID),
                DMToString(data.author),
                DMToString(displayName),
                DMToString(tellTarget)
            ),
            0.3
        )
    end
    return key
end

local function FormatMessage(data)
    if not data or not data.msg then return "" end
    
    local timestamp = ""
    if MidnightUI_GetMessengerSettings then
        local settings = MidnightUI_GetMessengerSettings()
        if settings and settings.showTimestamp then
            local timeStr = data.timestamp or "00:00"
            timestamp = string.format("|cff666666[%s]|r ", timeStr)
        end
    end
    
    local rawAuthor = data.author or "Unknown"
    if IsBNetAnonToken(rawAuthor) then
        rawAuthor = BuildLegacyBNetTokenLabel(rawAuthor)
    end
    local shortName = rawAuthor
    rawAuthor = rawAuthor:gsub("|", "") -- Sanitize pipes to prevent hyperlink breakage
    if string.find(shortName, "-") then shortName = strsplit("-", shortName) end

    local nameColor = data.nameColorDefault or "bbbbbb"
    local msgColor = data.msgColorDefault or "bbbbbb"
    local tag = data.tag or ""
    
    local classFile = MessengerDB.ContactClasses[shortName]
    if not classFile and data.guid then
        local _, cls = GetPlayerInfoByGUID(data.guid)
        if cls then 
            classFile = cls
            MessengerDB.ContactClasses[shortName] = cls 
        end
    end
    if classFile then
        local r, g, b
        if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
            r, g, b = _G.MidnightUI_Core.GetClassColor(classFile)
        elseif RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
            local c = RAID_CLASS_COLORS[classFile]
            r, g, b = c.r, c.g, c.b
        end
        if r and g and b then
            nameColor = string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
        end
    end

    local clickableName = string.format("|Hplayer:%s|h|cff%s%s|r|h", rawAuthor, nameColor, shortName)

    if tag == "" then
        return string.format("%s%s:  |cff%s%s|r", timestamp, clickableName, msgColor, data.msg)
    else
        return string.format("%s|cff888888%s|r  %s:  %s", timestamp, tag, clickableName, data.msg)
    end
end

local function GetChannelDisplayName(channelName)
    if not channelName or channelName == "" then return "Channel" end
    local lower = string.lower(channelName)
    if string.find(lower, "services", 1, true) or (string.find(lower, "service", 1, true) and string.find(lower, "trade", 1, true)) then return "Trade - Services" end
    if string.find(lower, "trade", 1, true) then return "Trade - City" end
    if string.find(lower, "general", 1, true) then return "General" end
    if string.find(lower, "localdefense", 1, true) or string.find(lower, "local defense", 1, true) then return "LocalDefense" end
    return channelName
end

local WorldFilterAllows

local function PruneHistoryList(category)
    if not MessengerDB or not MessengerDB.History or not MessengerDB.History[category] then return end
    local messages = MessengerDB.History[category].messages
    if not messages then return end
    
    -- Keep last 3 days
    local now = time()
    local pruned = {}
    for _, data in ipairs(messages) do
        local ts = data.epoch
        if ts and (now - ts) <= GROUP_HISTORY_MAX_AGE then
            pruned[#pruned + 1] = data
        end
    end
    
    -- Keep last 200 messages max
    if #pruned > MAX_HISTORY then
        local start = #pruned - MAX_HISTORY + 1
        local trimmed = {}
        for i = start, #pruned do trimmed[#trimmed + 1] = pruned[i] end
        pruned = trimmed
    end
    
    MessengerDB.History[category].messages = pruned
    if MessengerDB.History[category].unread then
        MessengerDB.History[category].unread = math.min(MessengerDB.History[category].unread, #pruned)
    end
end

local function PruneGroupHistory() PruneHistoryList("Group") end
local function PruneWorldHistory() PruneHistoryList("World") end

-- Prune ALL history channels on login to prevent unbounded growth
local function PruneAllHistory()
    if not MessengerDB or not MessengerDB.History then return end
    local channels = { "Local", "Group", "Guild", "Comm", "World", "Services",
                       "Direct", "Debug", "CombatLog", "Market", "Global" }
    for _, cat in ipairs(channels) do
        PruneHistoryList(cat)
    end
end

-- 1. Forward declaration so RefreshDisplay can see LogDebug
local LogDebug 

-- 2. Fixed typo: "llocal" -> "local"
local function RefreshDisplay()
    if not MessengerDB then return end
    msgFrame:Clear()
    PruneGroupHistory()
    PruneWorldHistory() 
    
    if ACTIVE_TAB == "Debug" and not MessengerDB.History["Debug"] then
        MessengerDB.History["Debug"] = { unread=0, messages={} }
    end
    if ACTIVE_TAB == "Market" and not MessengerDB.History["Market"] then
        MessengerDB.History["Market"] = { unread=0, messages={} }
    end

    local list = MessengerDB.History[ACTIVE_TAB].messages
    if ACTIVE_TAB == "World" and MessengerDB.History["World"] then
        list = MessengerDB.History["World"].messages
    elseif ACTIVE_TAB == "Global" and MessengerDB.History["Global"] then
        list = MessengerDB.History["Global"].messages
    end
    
    -- Optimize: Check channel status once per refresh
    local tradeActive = false
    local servicesActive = false
    if ACTIVE_TAB == "World" then
        tradeActive = FindTradeChannel()
        servicesActive = FindServicesChannel()
        if areChannelsStale then
            tradeActive = nil
            servicesActive = nil
        end
    end
    
    local now = time()
    local directShown = 0
    local directNoFilter = 0
    local directNilKey = 0
    local directMismatch = 0
    local directSamples = nil
    for _, data in ipairs(list) do
        local show = true
        if ACTIVE_TAB == "Direct" then
            if directSamples == nil then
                directSamples = {}
            end
            if not ACTIVE_DM_FILTER then 
                show = false
                directNoFilter = directNoFilter + 1
                if #directSamples < 3 then
                    directSamples[#directSamples + 1] = "no-filter " .. DMDescribeHistoryEntry(data)
                end
            else
                local messageKey = ResolveDirectMessageKey(data)
                if not messageKey or messageKey ~= ACTIVE_DM_FILTER then
                    show = false
                    if not messageKey then
                        directNilKey = directNilKey + 1
                    else
                        directMismatch = directMismatch + 1
                    end
                    if #directSamples < 3 then
                        directSamples[#directSamples + 1] = string.format(
                            "filter=%s key=%s %s",
                            DMToString(ACTIVE_DM_FILTER),
                            DMToString(messageKey),
                            DMDescribeHistoryEntry(data)
                        )
                    end
                end
            end
        elseif ACTIVE_TAB == "Group" then
            local ts = data.epoch
            if not ts or (now - ts) > GROUP_HISTORY_MAX_AGE then
                show = false
            end
        elseif ACTIVE_TAB == "World" then
            -- Pass the active states to the filter
            if not WorldFilterAllows(data, tradeActive, servicesActive) then
                show = false
            end
        end

        if show then
            local ok, finalString = pcall(FormatMessage, data)
            if ok and finalString and finalString ~= "" then
                msgFrame:AddMessage(finalString)
                if ACTIVE_TAB == "Direct" then
                    directShown = directShown + 1
                end
            elseif not ok then
                msgFrame:AddMessage("|cffff0000[Restricted Message Hidden]|r")
            end
        end
    end
    if ACTIVE_TAB == "Direct" then
        local sampleText = (directSamples and #directSamples > 0) and table.concat(directSamples, " || ") or "none"
        DMTrace(string.format(
            "RefreshDisplay direct activeFilter=%s listCount=%d shown=%d hiddenNoFilter=%d hiddenNilKey=%d hiddenMismatch=%d samples=%s",
            DMToString(ACTIVE_DM_FILTER),
            #list,
            directShown,
            directNoFilter,
            directNilKey,
            directMismatch,
            sampleText
        ))
    end
    msgFrame:ScrollToBottom()
end

_G.MyMessenger_RefreshDisplay = RefreshDisplay

-- Signal that Diagnostics has new entries so the Debug tab can appear.
_G.MidnightUI_SetDebugNotify = function()
    if _G.UpdateTabLayout then _G.UpdateTabLayout() end
end

local function FlushDebugQueue()
    if not MessengerDB or not _G.MidnightUI_DebugQueue or #_G.MidnightUI_DebugQueue == 0 then return end
    local q = _G.MidnightUI_DebugQueue
    _G.MidnightUI_DebugQueue = {}
    for _, msg in ipairs(q) do
        if _G.MidnightUI_Debug then
            _G.MidnightUI_Debug(msg)
        end
    end
end

local function ForceShowDebugMessage(msg)
    if not MessengerDB then return end
    local keepDebugHidden = MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.keepDebugHidden == true
    MessengerDB.History = MessengerDB.History or {}
    MessengerDB.History["Debug"] = MessengerDB.History["Debug"] or { unread = 0, messages = {} }
    table.insert(MessengerDB.History["Debug"].messages, {
        msg = msg,
        author = "Debug",
        nameColorDefault = "ffaa00",
        msgColorDefault = "ffffff",
        tag = "DBG",
        timestamp = date("%H:%M:%S"),
        epoch = time(),
    })
    if #MessengerDB.History["Debug"].messages > MAX_HISTORY then
        table.remove(MessengerDB.History["Debug"].messages, 1)
    end
    if ACTIVE_TAB ~= "Debug" then
        MessengerDB.History["Debug"].unread = (MessengerDB.History["Debug"].unread or 0) + 1
    end
    if _G.UpdateTabLayout then _G.UpdateTabLayout() end
    if keepDebugHidden then
        return
    end
    if TabButtons and TabButtons["Debug"] then
        TabButtons["Debug"]:Click()
    elseif _G.MyMessenger_RefreshDisplay then
        _G.MyMessenger_RefreshDisplay()
    end
end

_G.MidnightUI_ForceDebugMessage = ForceShowDebugMessage

_G.MidnightUI_Debug = function(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local val = select(i, ...)
        local ok, s = pcall(tostring, val)
        if ok then
            local ok2 = pcall(function() return table.concat({ s }, "") end)
            parts[#parts + 1] = ok2 and s or "[Restricted Message Hidden]"
        else
            parts[#parts + 1] = "[Restricted Message Hidden]"
        end
    end
    local msg = table.concat(parts, " ")
    if msg == "[Restricted Message Hidden]" or msg == "[Restricted]" or msg == "nil" then
        return
    end
    if msg:find("%[Restricted Message Hidden%]") then
        return
    end
    if msg:find("%[CombatTab%]") then
        local stack = ""
        if debugstack then
            local ok, ds = pcall(debugstack, 3, 8, 8)
            if ok and ds then stack = ds end
        end
        if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebug then
            _G.MidnightUI_Diagnostics.LogDebug("[CombatTabTrace] " .. msg .. " stack=" .. tostring(stack))
        else
            _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
            table.insert(_G.MidnightUI_DiagnosticsQueue, "[CombatTabTrace] " .. msg .. " stack=" .. tostring(stack))
        end
        return
    end
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebug then
        _G.MidnightUI_Diagnostics.LogDebug(msg)
    else
        _G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}
        table.insert(_G.MidnightUI_DiagnosticsQueue, msg)
    end
end

_G.MidnightUI_LogDebug = _G.MidnightUI_Debug

LogDebug = function(...)
    return _G.MidnightUI_Debug(...)
end

local SLASH_EMOTE_DEBUG = false

local function SlashTraceSnippet(text)
    return tostring(text or "")
end

local function ShouldTraceSlashPayload(_, _)
    return false
end

local function TraceSlashState(_, _, _)
    return
end

local function MidnightUI_EditBoxDeactivate(eb)
    DMTrace("EditBoxDeactivate begin " .. DMDescribeEditBoxState(eb))
    if type(ChatEdit_DeactivateChat) == "function" then
        pcall(ChatEdit_DeactivateChat, eb)
        DMTrace("EditBoxDeactivate after ChatEdit_DeactivateChat " .. DMDescribeEditBoxState(eb))
        return
    end
    if eb and eb.ClearFocus then eb:ClearFocus() end
    if eb and (eb.GetText and (eb:GetText() or "") == "") and eb.Hide then eb:Hide() end
    DMTrace("EditBoxDeactivate fallback " .. DMDescribeEditBoxState(eb))
end

local function MidnightUI_ClearEditBoxText(eb)
    if not eb then return end
    eb._midnightResetOnShow = true
    if eb.SetText then eb:SetText("") end
    if eb.HighlightText then eb:HighlightText(0, 0) end
end

local UpdateEditBoxLabel
local midnightWhisperSyncBusy = false
local function MidnightUI_IsAutoCompleteOpen()
    return _G.AutoCompleteBox and _G.AutoCompleteBox.IsShown and _G.AutoCompleteBox:IsShown()
end

local function GetSlashCommandToken(text)
    if type(text) ~= "string" then return nil end
    local cmd = text:match("^/(%S+)")
    if type(cmd) ~= "string" or cmd == "" then return nil end
    return string.lower(cmd)
end

local function IsWhisperSlashCommand(text)
    local cmd = GetSlashCommandToken(text)
    if not cmd then return false end
    return cmd == "w"
        or cmd == "whisper"
        or cmd == "tell"
        or cmd == "t"
        or cmd == "r"
        or cmd == "reply"
        or cmd == "bnw"
        or cmd == "bwhisper"
        or cmd == "bnet"
end

local function MidnightUI_SyncWhisperTarget(eb, forceTabSwitch)
    if midnightWhisperSyncBusy then return end
    if not eb or not MessengerDB then return end
    local chatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
    if chatType ~= "WHISPER" and chatType ~= "BN_WHISPER" then return end
    local tellTarget = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
    if not tellTarget or tellTarget == "" then return end

    DMTrace(string.format("SyncWhisperTarget enter chatType=%s tellTarget=%s forceTabSwitch=%s", DMToString(chatType), DMCompactText(tellTarget, 80), DMToString(forceTabSwitch)))
    local dmKey, displayName, directTarget, isBNet, bnetID = BuildDirectIdentityFromChatTarget(chatType, tellTarget)
    if not dmKey then return end

    if not bnetID then
        local activeBnetID = Messenger._directKey.ParseBNetIDKey(ACTIVE_DM_FILTER)
        if activeBnetID and chatType == "BN_WHISPER" and IsBNetAnonToken(tellTarget) then
            bnetID = activeBnetID
        end
    end

    local canonicalKey, canonicalBnetID = Messenger._directKey.ResolveCanonicalKey(dmKey, displayName, directTarget, bnetID)
    if canonicalKey and canonicalKey ~= "" then
        if canonicalKey ~= dmKey then
            DMTrace(string.format("SyncWhisperTarget canonicalize old=%s new=%s", DMToString(dmKey), DMToString(canonicalKey)))
        end
        dmKey = canonicalKey
    end
    if canonicalBnetID then
        bnetID = canonicalBnetID
    end

    local _, registeredKey = RegisterDirectContact(dmKey, displayName, directTarget, isBNet, bnetID)
    if type(registeredKey) == "string" and registeredKey ~= "" then
        dmKey = registeredKey
    end
    ACTIVE_DM_FILTER = dmKey
    DMTrace(string.format("SyncWhisperTarget resolved key=%s display=%s directTarget=%s isBNet=%s bnetID=%s", DMToString(dmKey), DMToString(displayName), DMToString(directTarget), DMToString(isBNet), DMToString(bnetID)))

    midnightWhisperSyncBusy = true
    local ok = pcall(function()
        if forceTabSwitch and not suppressTabMode and ACTIVE_TAB ~= "Direct" and ACTIVE_TAB ~= "Global" and TabButtons and TabButtons["Direct"] then
            ACTIVE_TAB = "Direct"
            TabButtons["Direct"]:Click()
        else
            UpdateTabLayout()
            if ACTIVE_TAB == "Direct" then
                if UpdateDMHeader then UpdateDMHeader() end
                RefreshDisplay()
            end
        end
    end)
    midnightWhisperSyncBusy = false
    if not ok then
        UpdateTabLayout()
    end
end

local function MidnightUI_PostKeyWhisperSync(eb)
    if not eb then return end
    C_Timer.After(0, function()
        if not eb then return end
        local pendingText = eb.GetText and eb:GetText() or ""
        if (pendingText == "" or pendingText == nil) and type(eb._midnightLastTextSnapshot) == "string" then
            pendingText = eb._midnightLastTextSnapshot
        end
        if type(pendingText) == "string" and pendingText:find("^/") and not IsWhisperSlashCommand(pendingText) then
            DMTrace(string.format("PostKeyWhisperSync skip slash text=%s", DMCompactText(pendingText, 40)))
            UpdateEditBoxLabel(eb)
            return
        end
        MidnightUI_SyncWhisperTarget(eb, not suppressTabMode)
        UpdateEditBoxLabel(eb)
    end)
end

local function MidnightUI_HandleAutoCompleteSelection(eb, action)
    if not eb or not MidnightUI_IsAutoCompleteOpen() then return false end
    local beforeText = eb.GetText and eb:GetText() or ""
    local beforeTell = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
    local beforeChatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
    local beforeShown = MidnightUI_IsAutoCompleteOpen()
    local fn = nil
    local fallbackFn = nil
    if action == "TAB" then
        fn = _G.AutoCompleteEditBox_OnTabPressed
        fallbackFn = _G.AutoCompleteEditBox_OnEnterPressed
    elseif action == "ENTER" then
        fn = _G.AutoCompleteEditBox_OnEnterPressed
    end
    if type(fn) ~= "function" then
        return false
    end
    local ok, result = pcall(fn, eb)
    local afterText = eb.GetText and eb:GetText() or ""
    local afterTell = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
    local afterChatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
    local afterShown = MidnightUI_IsAutoCompleteOpen()
    local changed = (beforeText ~= afterText) or (beforeTell ~= afterTell) or (beforeChatType ~= afterChatType)
    local consumed = changed or (beforeShown and not afterShown)
    if action == "TAB" then
        -- TAB can return true while only consuming the key without applying selection.
        -- Treat it as consumed only if it actually changed text/target/chatType or closed the popup.
        consumed = consumed
    else
        consumed = consumed or (ok and result == true)
    end
    if action == "TAB" and not consumed and type(fallbackFn) == "function" and MidnightUI_IsAutoCompleteOpen() then
        local ok2, result2 = pcall(fallbackFn, eb)
        local finalText = eb.GetText and eb:GetText() or ""
        local finalTell = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
        local finalChatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
        local finalShown = MidnightUI_IsAutoCompleteOpen()
        local fallbackChanged = (afterText ~= finalText) or (afterTell ~= finalTell) or (afterChatType ~= finalChatType)
        local fallbackConsumed = (ok2 and result2 == true) or fallbackChanged or (afterShown and not finalShown)
        consumed = fallbackConsumed
    end
    return consumed
end

local function MidnightUI_EditBoxOnTabPressed(eb)
    if not eb then return end
    if MidnightUI_HandleAutoCompleteSelection(eb, "TAB") then
        MidnightUI_PostKeyWhisperSync(eb)
        return
    end
    local handled = false
    if type(ChatEdit_OnTabPressed) == "function" then
        local ok, result = pcall(ChatEdit_OnTabPressed, eb)
        if ok and result then handled = true end
    end
    if not handled and type(ChatEdit_CustomTabPressed) == "function" then
        pcall(ChatEdit_CustomTabPressed, eb)
    end
    MidnightUI_PostKeyWhisperSync(eb)
end

local function MidnightUI_EditBoxOnEnterPressed(eb)
    if not eb then return end
    DMTrace("EditBoxEnter begin " .. DMDescribeEditBoxState(eb))
    DMAutoDiag("dm_editbox_enter", "dm_editbox_enter phase=begin " .. DMDescribeEditBoxState(eb), 0)
    local text = eb.GetText and eb:GetText() or ""
    local chatType = eb.GetAttribute and eb:GetAttribute("chatType") or nil
    local tellTarget = eb.GetAttribute and eb:GetAttribute("tellTarget") or nil
    local isSlashInput = (type(text) == "string" and text:sub(1, 1) == "/")
    if text ~= "" and not isSlashInput and chatType == "BN_WHISPER" and type(BNSendWhisper) == "function" then
        local directMeta = (ACTIVE_TAB == "Direct" and ACTIVE_DM_FILTER) and GetDirectContactMeta(ACTIVE_DM_FILTER) or nil
        local bnetID = tonumber(directMeta and directMeta.bnetID) or Messenger._directKey.ParseBNetIDKey(ACTIVE_DM_FILTER) or ResolveBNetIDFromTarget(tellTarget)
        if bnetID then
            local ok, err = pcall(BNSendWhisper, bnetID, text)
            DMTrace(string.format("EditBoxEnter BNSendWhisper ok=%s bnetID=%s tellTarget=%s err=%s", DMToString(ok), DMToString(bnetID), DMToString(tellTarget), DMToString(err)))
            DMAutoDiag(
                "dm_bnet_send",
                string.format("dm_bnet_send ok=%s bnetID=%s tellTarget=%s text=%s err=%s", DMToString(ok), DMToString(bnetID), DMToString(tellTarget), DMCompactText(text, 48), DMToString(err)),
                0
            )
            if ok then
                MidnightUI_PostKeyWhisperSync(eb)
                MidnightUI_ClearEditBoxText(eb)
                MidnightUI_EditBoxDeactivate(eb)
                return
            end
        else
            DMTrace(string.format("EditBoxEnter BNSendWhisper skip missing-bnet-id tellTarget=%s activeFilter=%s", DMToString(tellTarget), DMToString(ACTIVE_DM_FILTER)))
        end
    end
    if MidnightUI_HandleAutoCompleteSelection(eb, "ENTER") then
        MidnightUI_PostKeyWhisperSync(eb)
        DMTrace("EditBoxEnter autocomplete-consumed " .. DMDescribeEditBoxState(eb))
        DMAutoDiag("dm_editbox_enter", "dm_editbox_enter phase=autocomplete " .. DMDescribeEditBoxState(eb), 0)
        return
    end
    if type(ChatEdit_OnEnterPressed) == "function" then
        local ok = pcall(ChatEdit_OnEnterPressed, eb)
        if type(text) == "string" and text ~= "" and text:sub(1, 1) ~= "/" then
            MidnightUI_ClearEditBoxText(eb)
        end
        TraceSlashState("CompatEnter:ChatEdit_OnEnterPressed", eb, "ok=" .. tostring(ok))
        DMTrace(string.format("EditBoxEnter after ChatEdit_OnEnterPressed ok=%s %s", DMToString(ok), DMDescribeEditBoxState(eb)))
        DMAutoDiag("dm_editbox_enter", string.format("dm_editbox_enter phase=chat_send ok=%s %s", DMToString(ok), DMDescribeEditBoxState(eb)), 0)
        MidnightUI_PostKeyWhisperSync(eb)
        DMTrace("EditBoxEnter after PostKeyWhisperSync " .. DMDescribeEditBoxState(eb))
        DMAutoDiag("dm_editbox_enter", "dm_editbox_enter phase=post_sync " .. DMDescribeEditBoxState(eb), 0)
        return
    end
    TraceSlashState("CompatEnter:begin", eb)
    if text == "" then
        DMTrace("EditBoxEnter empty-deactivate " .. DMDescribeEditBoxState(eb))
        DMAutoDiag("dm_editbox_enter", "dm_editbox_enter phase=empty_deactivate " .. DMDescribeEditBoxState(eb), 0)
        MidnightUI_ClearEditBoxText(eb)
        MidnightUI_EditBoxDeactivate(eb)
        return
    end

    local parseHandled = false
    if type(ChatEdit_ParseText) == "function" then
        local ok, handled = pcall(ChatEdit_ParseText, eb, 1)
        local afterText = eb.GetText and eb:GetText() or ""
        -- In 12.x ParseText may return nil even when it processed slash commands.
        parseHandled = (ok and handled) and true or false
        if isSlashInput and ok then
            if afterText ~= text or afterText == "" then
                parseHandled = true
            end
        end
        TraceSlashState("CompatEnter:ChatEdit_ParseText", eb, "ok=" .. tostring(ok) .. " handled=" .. tostring(handled) .. " after='" .. SlashTraceSnippet(afterText) .. "'")
    else
        LogDebug("|cff66ccff[SlashTrace]|r CompatEnter missing ChatEdit_ParseText")
    end

    if not parseHandled then
        if isSlashInput then
            -- Never send raw slash commands as SAY/PARTY text if parse did not report handled.
            TraceSlashState("CompatEnter:SlashNotHandled", eb, "suppressing ChatEdit_SendText fallback")
            MidnightUI_ClearEditBoxText(eb)
            MidnightUI_EditBoxDeactivate(eb)
            return
        end
        if type(ChatEdit_SendText) == "function" then
            local ok = pcall(ChatEdit_SendText, eb, 1)
            TraceSlashState("CompatEnter:ChatEdit_SendText", eb, "ok=" .. tostring(ok))
        else
            LogDebug("|cff66ccff[SlashTrace]|r CompatEnter missing ChatEdit_SendText")
        end
    end

    MidnightUI_ClearEditBoxText(eb)
    MidnightUI_EditBoxDeactivate(eb)
end

local function MidnightUI_EditBoxOnEscapePressed(eb)
    TraceSlashState("CompatEscape", eb)
    -- Clear the text so it doesn't persist when the edit box reopens.
    if eb and eb.SetText then eb:SetText("") end
    MidnightUI_EditBoxDeactivate(eb)
end

local function HideDefaultChatArtAndCombatButtons()
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
        return
    end
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame"..i]
        if cf then
            cf:DisableDrawLayer("BACKGROUND")
            cf:DisableDrawLayer("BORDER")
            if cf.SetBackdrop then cf:SetBackdrop(nil) end
        end
        local bg = _G["ChatFrame"..i.."Background"]
        if bg then bg:Hide() end
        local tl = _G["ChatFrame"..i.."TopLeftTexture"]
        if tl then tl:Hide() end
        local bl = _G["ChatFrame"..i.."BottomLeftTexture"]
        if bl then bl:Hide() end
        local tr = _G["ChatFrame"..i.."TopRightTexture"]
        if tr then tr:Hide() end
        local br = _G["ChatFrame"..i.."BottomRightTexture"]
        if br then br:Hide() end
        local left = _G["ChatFrame"..i.."LeftTexture"]
        if left then left:Hide() end
        local right = _G["ChatFrame"..i.."RightTexture"]
        if right then right:Hide() end
        local top = _G["ChatFrame"..i.."TopTexture"]
        if top then top:Hide() end
        local bottom = _G["ChatFrame"..i.."BottomTexture"]
        if bottom then bottom:Hide() end
        local bf = _G["ChatFrame"..i.."ButtonFrame"]
        if bf then
            bf:Hide()
            bf:SetAlpha(0)
            bf:EnableMouse(false)
        end
        local resize = _G["ChatFrame"..i.."ResizeButton"]
        if resize then resize:Hide() end
        local click = _G["ChatFrame"..i.."ClickAnywhereButton"]
        if click then click:Hide() end
        local bfBg = _G["ChatFrame"..i.."ButtonFrameBackground"]
        if bfBg then bfBg:Hide() end
        local bfLeft = _G["ChatFrame"..i.."ButtonFrameLeftTexture"]
        if bfLeft then bfLeft:Hide() end
        local bfRight = _G["ChatFrame"..i.."ButtonFrameRightTexture"]
        if bfRight then bfRight:Hide() end
        local bfTop = _G["ChatFrame"..i.."ButtonFrameTopTexture"]
        if bfTop then bfTop:Hide() end
        local bfBottom = _G["ChatFrame"..i.."ButtonFrameBottomTexture"]
        if bfBottom then bfBottom:Hide() end
        local bfMin = _G["ChatFrame"..i.."ButtonFrameMinimizeButton"]
        if bfMin then bfMin:Hide() end
        local bfMin2 = _G["ChatFrame"..i.."ButtonFrameMinimizeButton2"]
        if bfMin2 then bfMin2:Hide() end
        local bfMin3 = _G["ChatFrame"..i.."ButtonFrameMinimizeButton3"]
        if bfMin3 then bfMin3:Hide() end
        local sb = _G["ChatFrame"..i.."ScrollBar"]
        if sb then sb:Hide(); sb:SetAlpha(0) end
        local sbTrack = _G["ChatFrame"..i.."ScrollBarTrack"]
        if sbTrack then sbTrack:Hide() end
        local sbThumb = _G["ChatFrame"..i.."ScrollBarThumbTexture"]
        if sbThumb then sbThumb:Hide() end
        local sbMid = _G["ChatFrame"..i.."ScrollBarTrackMiddle"]
        if sbMid then sbMid:Hide() end
        local sbTop = _G["ChatFrame"..i.."ScrollBarTrackTop"]
        if sbTop then sbTop:Hide() end
        local sbBottom = _G["ChatFrame"..i.."ScrollBarTrackBottom"]
        if sbBottom then sbBottom:Hide() end
        local toBottom = _G["ChatFrame"..i.."ScrollToBottomButton"]
        if toBottom then toBottom:Hide() end
    end

    local tab = _G["ChatFrame2Tab"]
    if tab then
        tab:SetAlpha(0)
        tab:Hide()
    end
    local tabGlow = _G["ChatFrame2TabGlow"]
    if tabGlow then tabGlow:Hide() end

    local qbf = _G["CombatLogQuickButtonFrame"]
    if qbf then
        qbf:Hide()
        qbf:SetAlpha(0)
    end
    local qbf1 = _G["CombatLogQuickButtonFrameButton1"]
    if qbf1 then qbf1:Hide() end
    local qbf2 = _G["CombatLogQuickButtonFrameButton2"]
    if qbf2 then qbf2:Hide() end
    local qbfCustom = _G["CombatLogQuickButtonFrame_Custom"]
    if qbfCustom then qbfCustom:Hide() end
end

local function UpdateDefaultModeCombatUI(tag)
    if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then return end
    if not AllowDefaultChatTweaks() then return end
    local cf2 = _G["ChatFrame2"]
    local selected = _G.SELECTED_CHAT_FRAME
    local showCombat = (selected == cf2)

    local qbf = _G["CombatLogQuickButtonFrame"]
    local qbf1 = _G["CombatLogQuickButtonFrameButton1"]
    local qbf2 = _G["CombatLogQuickButtonFrameButton2"]
    local qbfCustom = _G["CombatLogQuickButtonFrame_Custom"]
    local bf = _G["ChatFrame2ButtonFrame"]
    local bg = _G["ChatFrame2ButtonFrameBackground"]
    local left = _G["ChatFrame2ButtonFrameLeftTexture"]
    local right = _G["ChatFrame2ButtonFrameRightTexture"]
    local top = _G["ChatFrame2ButtonFrameTopTexture"]
    local bottom = _G["ChatFrame2ButtonFrameBottomTexture"]
    local bf1bg = _G["ChatFrame1ButtonFrameBackground"]
    local bf2bg = _G["ChatFrame2ButtonFrameBackground"]

    local function SetShown(obj, shown)
        if not obj then return end
        if shown then
            obj:SetAlpha(1)
            obj:Show()
        else
            obj:SetAlpha(0)
            obj:Hide()
        end
    end

    -- Keep Combat Log button-frame textures hidden to avoid darkening the dock bar.
    SetShown(bf, false)
    SetShown(bg, false)
    SetShown(left, false)
    SetShown(right, false)
    SetShown(top, false)
    SetShown(bottom, false)
    SetShown(qbf, showCombat)
    SetShown(qbf1, showCombat)
    SetShown(qbf2, showCombat)
    SetShown(qbfCustom, showCombat)

    -- Keep General button-frame background visibility in sync with Combat Log.
    if bf1bg and bf2bg then
        if bf2bg:IsShown() then
            bf1bg:SetAlpha(1)
            bf1bg:Show()
        else
            bf1bg:SetAlpha(0)
            bf1bg:Hide()
        end
    end


    -- Keep chat background visuals under Blizzard control in default mode.

    -- Re-apply once shortly after default UI switch to catch late Blizzard updates
    if tag == "ApplyDefaultChatInterfaceVisibility" then
        C_Timer.After(0.15, function()
            if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then return end
            UpdateDefaultModeCombatUI("PostDefaultSync0.15")
        end)
        C_Timer.After(0.5, function()
            if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then return end
            UpdateDefaultModeCombatUI("PostDefaultSync0.5")
        end)
    end

end

local function GetDesiredChatBackgroundAlpha(cf)
    local alpha = nil
    if cf and cf.oldAlpha then
        alpha = tonumber(cf.oldAlpha)
    end
    if not alpha and GetChatWindowInfo and cf and cf.GetID then
        local ok, name, _, _, _, _, a = pcall(GetChatWindowInfo, cf:GetID())
        if ok and name and a then alpha = tonumber(a) end
    end
    if not alpha and GetCVar then
        local ok, v = pcall(GetCVar, "chatBackgroundAlpha")
        if ok then alpha = tonumber(v) end
    end
    return alpha
end

local function ApplyChatBackgroundAlpha(cf, alpha)
    if not cf or not alpha then return end
    local bg = _G[cf:GetName() .. "Background"]
    if bg and bg.SetAlpha then
        bg:SetAlpha(alpha)
    end
end

local function GetChatWindowAlphaById(id)
    if not GetChatWindowInfo then return nil end
    local ok, name, _, _, _, _, alpha = pcall(GetChatWindowInfo, id)
    if ok and name and alpha then return tonumber(alpha) end
    return nil
end

-- Disable fading for chat frames when in default mode
local function DisableChatFrameFading()
    if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then
        return
    end
    local frames = { _G.ChatFrame1, _G.ChatFrame2 }
    for _, cf in ipairs(frames) do
        if cf then
            cf.shouldFadeAfterInactivity = false
            cf.hasBeenFaded = false
        end
    end
    -- Disable Blizzard's alternating row backgrounds in chat
    if SetCVar then
        pcall(SetCVar, "chatAlternatingBackgroundOpacity", 0)
    end
    for i = 1, 20 do
        local cf = _G["ChatFrame" .. i]
        if cf then
            if cf.SetAlternatingBackgroundEnabled then
                pcall(cf.SetAlternatingBackgroundEnabled, cf, false)
            end
        end
    end
end

local function ForceDefaultChatBackgroundAlpha(reason)
    if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then
        return
    end
    if not AllowDefaultChatTweaks() then return end

    local cf1 = _G.ChatFrame1
    local cf2 = _G.ChatFrame2

    local a1 = GetChatWindowAlphaById(1) or GetDesiredChatBackgroundAlpha(cf1)
    local a2 = GetChatWindowAlphaById(2) or GetDesiredChatBackgroundAlpha(cf2)

    if a1 then ApplyChatBackgroundAlpha(cf1, a1) end
    if a2 then ApplyChatBackgroundAlpha(cf2, a2) end

    if _G.UIFrameFadeRemoveFrame then
        local bg1 = _G.ChatFrame1Background
        local bg2 = _G.ChatFrame2Background
        if bg1 then
            pcall(_G.UIFrameFadeRemoveFrame, bg1)
            if _G.FADEFRAMES then _G.FADEFRAMES[bg1] = nil end
        end
        if bg2 then
            pcall(_G.UIFrameFadeRemoveFrame, bg2)
            if _G.FADEFRAMES then _G.FADEFRAMES[bg2] = nil end
        end
    end

    DisableChatFrameFading()

end

local function StartDefaultFadeAlphaGuard(reason)
    if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then
        return
    end
    if not AllowDefaultChatTweaks() then return end

    if activeFadeGuard then
        activeFadeGuard:Cancel()
        activeFadeGuard = nil
    end

    local cf1 = _G.ChatFrame1
    local cf2 = _G.ChatFrame2
    if not cf1 and not cf2 then return end

    local target1 = GetDesiredChatBackgroundAlpha(cf1)
    local target2 = GetDesiredChatBackgroundAlpha(cf2)

    local ticks = 0
    local maxTicks = 30

    activeFadeGuard = C_Timer.NewTicker(0.1, function()
        ticks = ticks + 1
        if not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface) then
            if activeFadeGuard then activeFadeGuard:Cancel() end
            activeFadeGuard = nil
            return
        end

        if target1 then
            ApplyChatBackgroundAlpha(cf1, target1)
            if _G.ChatFrame1Background and _G.FADEFRAMES then
                _G.FADEFRAMES[_G.ChatFrame1Background] = nil
            end
        end
        if target2 then
            ApplyChatBackgroundAlpha(cf2, target2)
            if _G.ChatFrame2Background and _G.FADEFRAMES then
                _G.FADEFRAMES[_G.ChatFrame2Background] = nil
            end
        end

        if ticks >= maxTicks then
            if activeFadeGuard then activeFadeGuard:Cancel() end
            activeFadeGuard = nil
        end
    end)

end

local function DebugDefaultReloadVisuals(tag)
    return
end

local function RestoreCombatLogTabDefaultMode(reason, forceClear)
    local cf2Tab = _G["ChatFrame2Tab"]
    if not cf2Tab then
        return
    end
    local cf2 = _G["ChatFrame2"]
    local cf1 = _G["ChatFrame1"]
    if cf2 and cf1 and FCF_DockFrame and cf2.isDocked == false then
        local ok = pcall(FCF_DockFrame, cf2, cf1)
    end
    if _G.GeneralDockManager then
        cf2Tab:SetParent(_G.GeneralDockManager)
    else
        cf2Tab:SetParent(cf2 or UIParent)
    end
    if forceClear then
        cf2Tab:ClearAllPoints()
    end
    cf2Tab:SetAlpha(1)
    cf2Tab:Show()
    if cf2Tab.SetShown then cf2Tab:SetShown(true) end
    if cf2Tab.GetNumPoints and cf2Tab:GetNumPoints() == 0 then
        local tab1 = _G["ChatFrame1Tab"]
        if tab1 then
            cf2Tab:SetPoint("LEFT", tab1, "RIGHT", 0, 0)
        else
            local dock = _G.GeneralDockManager or cf2 or UIParent
            cf2Tab:SetPoint("BOTTOMLEFT", dock, "BOTTOMLEFT", 0, 0)
        end
    end
    if _G.FCF_UpdateDocking then pcall(_G.FCF_UpdateDocking) end
    if _G.FloatingChatFrame_Update then pcall(_G.FloatingChatFrame_Update) end
    C_Timer.After(0, function()
        if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
            if _G.FCF_UpdateDocking then pcall(_G.FCF_UpdateDocking) end
            if _G.FloatingChatFrame_Update then pcall(_G.FloatingChatFrame_Update) end
        end
    end)
    C_Timer.After(0.2, function()
        if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
            if _G.FCF_UpdateDocking then pcall(_G.FCF_UpdateDocking) end
            if _G.FloatingChatFrame_Update then pcall(_G.FloatingChatFrame_Update) end
        end
    end)
end

EnsureCombatQuickButtons = function()
    if not combatContainer or not combatQuickBar then return end
    local qbf = _G["CombatLogQuickButtonFrame"]
    local qbf1 = _G["CombatLogQuickButtonFrameButton1"]
    local qbf2 = _G["CombatLogQuickButtonFrameButton2"]
    local qbfCustom = _G["CombatLogQuickButtonFrame_Custom"]
    if qbf then
        qbf:SetParent(combatQuickBar)
        qbf:ClearAllPoints()
        qbf:SetAllPoints(combatQuickBar)
        qbf:SetFrameStrata("DIALOG")
        qbf:SetFrameLevel(combatQuickBar:GetFrameLevel() + 1)
        qbf:SetScale(1)
        qbf:EnableMouse(true)
        qbf:SetAlpha(1)
        qbf:Show()
    end
    if qbfCustom then
        if qbf then
            qbfCustom:SetParent(qbf)
            qbfCustom:ClearAllPoints()
            qbfCustom:SetPoint("LEFT", qbf, "LEFT", 12, 0)
        end
        qbfCustom:SetFrameStrata("DIALOG")
        if qbf then qbfCustom:SetFrameLevel(qbf:GetFrameLevel() + 2) end
        qbfCustom:SetHeight(24)
        qbfCustom:DisableDrawLayer("BACKGROUND")
        qbfCustom:DisableDrawLayer("BORDER")
        if qbfCustom.SetBackdrop then qbfCustom:SetBackdrop(nil) end
        qbfCustom:EnableMouse(true)
        qbfCustom:SetAlpha(1)
        qbfCustom:Show()
    end
    if qbf1 then
        if qbfCustom and qbf1:GetParent() ~= qbfCustom then
            qbf1:SetParent(qbfCustom)
            qbf1:ClearAllPoints()
            qbf1:SetPoint("LEFT", qbfCustom, "LEFT", 3, 0)
        end
        qbf1:SetFrameStrata("DIALOG")
        if qbfCustom then qbf1:SetFrameLevel(qbfCustom:GetFrameLevel() + 1) end
        qbf1:EnableMouse(true)
        qbf1:SetAlpha(1)
        qbf1:Show()
    end
    if qbf2 then
        if qbfCustom and qbf2:GetParent() ~= qbfCustom then
            qbf2:SetParent(qbfCustom)
            qbf2:ClearAllPoints()
            qbf2:SetPoint("LEFT", qbf1 or qbfCustom, "RIGHT", 3, 0)
        end
        qbf2:SetFrameStrata("DIALOG")
        if qbfCustom then qbf2:SetFrameLevel(qbfCustom:GetFrameLevel() + 1) end
        qbf2:EnableMouse(true)
        qbf2:SetAlpha(1)
        qbf2:Show()
    end
end

local quickButtonsReassertQueued = false
ScheduleCombatQuickButtonsReassert = function()
    if quickButtonsReassertQueued then return end
    quickButtonsReassertQueued = true
    C_Timer.After(0.1, function()
        if _G.MidnightUI_CombatEmbedded then
            EnsureCombatQuickButtons()
        end
        C_Timer.After(0.5, function()
            if _G.MidnightUI_CombatEmbedded then
                EnsureCombatQuickButtons()
            end
            quickButtonsReassertQueued = false
        end)
    end)
end

combatContainer:HookScript("OnShow", function()
    if _G.MidnightUI_CombatEmbedded then
        EnsureCombatQuickButtons()
        ScheduleCombatQuickButtonsReassert()
    end
end)

local function IsDefaultChatEnabled()
    return MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface
end

local function RestoreDefaultEditBox()
    local eb = _G["ChatFrame1EditBox"]
    if not eb then return end

    -- Restore original textures if we hid them
    if eb._midnightRegions then
        for _, data in ipairs(eb._midnightRegions) do
            local r = data.r
            if r and r.SetTexture then
                r:SetTexture(data.tex)
                r:SetAlpha(data.alpha or 1)
                if data.shown then r:Show() else r:Hide() end
            end
        end
    end
    if eb.EnableDrawLayer then
        eb:EnableDrawLayer("BACKGROUND")
        eb:EnableDrawLayer("BORDER")
    end
    if eb.midnightBg then eb.midnightBg:Hide() end
    if eb.midnightBorder then eb.midnightBorder:Hide() end
    if eb.midnightLabel then eb.midnightLabel:Hide() end

    local origHeader = _G["ChatFrame1EditBoxHeader"]
    if origHeader then
        origHeader:Show()
        origHeader:SetAlpha(1)
        origHeader:ClearAllPoints()
        origHeader:SetPoint("LEFT", eb, "LEFT", 15, 0)
    end

    local cf1 = _G["ChatFrame1"]
    eb:SetParent(cf1 or UIParent)
    eb:ClearAllPoints()
    if cf1 then
        eb:SetPoint("TOPLEFT", cf1, "BOTTOMLEFT", -5, -2)
        local w = cf1:GetWidth()
        if w and w > 0 then
            eb:SetWidth(w + 10)
        end
    else
        eb:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", 30, 30)
        eb:SetWidth(585)
    end
    eb:SetHeight(32)
    eb:SetAlpha(1)
    eb:SetFrameStrata("DIALOG")
    if cf1 and cf1.GetFrameLevel then eb:SetFrameLevel(cf1:GetFrameLevel() + 1) end
    eb:SetFontObject(ChatFontNormal)
    if eb.SetJustifyV then eb:SetJustifyV("MIDDLE") end
    eb:SetTextInsets(43.3, 13.0, 0.0, 0.0)
    eb:EnableMouse(true)
    eb:Show()
    if ChatEdit_UpdateHeader then ChatEdit_UpdateHeader(eb) end
end

local StyleDefaultEditBox

local function ApplyDefaultChatInterfaceVisibility()
    local showDefault = MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface
    if showDefault then
        -- Debug snapshots are handled by the reload-specific tracker below.
        if Messenger then Messenger:Hide() end
        if combatContainer then combatContainer:Hide() end
        if clickZone then clickZone:Hide() end
        if _G.MessengerFocusTrigger then _G.MessengerFocusTrigger:Hide() end
        if _G.MessengerSlashTrigger then _G.MessengerSlashTrigger:Hide() end
        local inCombat = InCombatLockdown()
        if not inCombat and Messenger then
            ClearOverrideBindings(Messenger)
        end
        if _G.GeneralDockManager then _G.GeneralDockManager:Show() end

        -- Force the General tab (ChatFrame1) when switching to default mode.
        local cf1 = _G.ChatFrame1
        if cf1 and type(FCF_SelectDockFrame) == "function" then
            pcall(FCF_SelectDockFrame, cf1)
        end
        if cf1 and type(FCF_FadeInChatFrame) == "function" then
            pcall(FCF_FadeInChatFrame, cf1)
        end
        if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
            C_Timer.After(0.2, function()
                local cf = _G.ChatFrame1
                if cf and type(FCF_SelectDockFrame) == "function" then
                    pcall(FCF_SelectDockFrame, cf)
                end
            end)
            C_Timer.After(1.0, function()
                local cf = _G.ChatFrame1
                if cf and type(FCF_SelectDockFrame) == "function" then
                    pcall(FCF_SelectDockFrame, cf)
                end
            end)
        end

        _G.MidnightUI_CombatEmbedded = false
        RefreshCollapseToggleVisibility()
        return

    else
        if Messenger and not isChatCollapsed then Messenger:Show() end
        if _G.GeneralDockManager then _G.GeneralDockManager:Hide() end
        if _G.MessengerFocusTrigger then _G.MessengerFocusTrigger:Show() end
        if _G.MessengerSlashTrigger then _G.MessengerSlashTrigger:Show() end
        if not InCombatLockdown() and Messenger then
            SetOverrideBindingClick(Messenger, true, "/", "MessengerSlashTrigger")
        end
        if not isChatCollapsed then
            StyleDefaultEditBox()
            C_Timer.After(0.1, function()
                if not IsDefaultChatEnabled() and not isChatCollapsed then
                    StyleDefaultEditBox()
                end
            end)
            C_Timer.After(0.5, function()
                if not IsDefaultChatEnabled() and not isChatCollapsed then
                    StyleDefaultEditBox()
                end
            end)
        end
        HideDefaultChatArtAndCombatButtons()
        ApplyDefaultChatVisibility()
        if ACTIVE_TAB == "CombatLog" and not isChatCollapsed then
            EmbedBlizzardCombatLog(true)
        else
            EmbedBlizzardCombatLog(false)
        end
        if isChatCollapsed then
            if Messenger then Messenger:Hide() end
            if clickZone then clickZone:Hide() end
            local eb = _G["ChatFrame1EditBox"]
            if eb then eb:Hide() end
        else
            if clickZone then clickZone:Show() end
        end
        RefreshCollapseToggleVisibility()
    end
end

_G.MidnightUI_ApplyDefaultChatInterfaceVisibility = ApplyDefaultChatInterfaceVisibility

ApplyDefaultChatVisibility = function()
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
        return
    end
    for i = 1, NUM_CHAT_WINDOWS do
        local cf = _G["ChatFrame"..i]
        if cf then
            local shouldEmbedCombat = (i == 2 and combatContainer and (_G.MidnightUI_CombatEmbedded or cf:GetParent() == combatContainer))
            if shouldEmbedCombat then
                if cf:GetParent() ~= combatContainer then
                    cf:SetParent(combatContainer)
                    cf:ClearAllPoints()
                    cf:SetAllPoints(combatContainer)
                end
                cf:SetAlpha(1)
                cf:Show()
                cf:EnableMouse(true)
                EnsureCombatQuickButtons()
            else
                cf:SetAlpha(0)
                cf:Hide()
                cf:EnableMouse(false)
            end
        end
    end
end

EmbedBlizzardCombatLog = function(shouldShow)
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
        _G.MidnightUI_CombatEmbedded = false
        RestoreCombatLogTabDefaultMode("EmbedSkipDefault", true)
        return
    end
    local cf2 = _G["ChatFrame2"]
    local cf2Tab = _G["ChatFrame2Tab"]
    if not cf2 then return end
    local btnFrame = _G["ChatFrame2ButtonFrame"] 
    
    -- no debug spam here
    
    if shouldShow then
        _G.MidnightUI_CombatEmbedded = true
        combatContainer:Show()
        if FCF_UnDockFrame then
            local ok = pcall(FCF_UnDockFrame, cf2)
        end
        cf2:SetParent(combatContainer); cf2:ClearAllPoints()
        cf2:SetPoint("TOPLEFT", combatQuickBar, "BOTTOMLEFT", 0, -4)
        cf2:SetPoint("BOTTOMRIGHT", combatContainer, "BOTTOMRIGHT", 0, 0)
        cf2:Show(); cf2:SetAlpha(1); cf2:SetFrameStrata("LOW"); cf2:SetFrameLevel(combatContainer:GetFrameLevel() + 1)
        cf2:DisableDrawLayer("BACKGROUND"); cf2:DisableDrawLayer("BORDER")
        if cf2.SetBackdrop then cf2:SetBackdrop(nil) end
        local resize = _G["ChatFrame2ResizeButton"]
        if resize then resize:Hide() end
        local scroll = _G["ChatFrame2ScrollBar"]
        if scroll then scroll:SetAlpha(0) end
        if btnFrame then
            btnFrame:Hide()
            btnFrame:SetAlpha(0)
            btnFrame:EnableMouse(false)
        end
        if cf2Tab then
            cf2Tab:SetParent(UIParent); cf2Tab:ClearAllPoints(); cf2Tab:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -10000, -10000); cf2Tab:SetAlpha(0); cf2Tab:Hide()
        end
        cf2:SetFontObject(ChatFontNormal); cf2:SetJustifyH("LEFT"); cf2:SetClampedToScreen(false)
        if FCF_SetLocked then
            local ok = pcall(FCF_SetLocked, cf2, true)
        end
        -- no debug spam here
        HideDefaultChatArtAndCombatButtons()
        EnsureCombatQuickButtons()
        ScheduleCombatQuickButtonsReassert()
    else
        _G.MidnightUI_CombatEmbedded = false
        combatContainer:Hide()
        -- no debug spam here
        
        -- DON'T hide cf2 or its tab here - let the dock system manage it when not embedded
        -- Just clean up the button frame
        if btnFrame then 
            btnFrame:Hide() 
            btnFrame:SetAlpha(0)
            btnFrame:EnableMouse(false)
            -- no debug spam here
        end
        
        -- Redock the combat log if we undocked it for embed mode.
        if cf2 and cf2.isDocked == false then
            local dockTarget = _G["ChatFrame1"]
            if FCF_DockFrame and dockTarget then
                local ok = pcall(FCF_DockFrame, cf2, dockTarget)
            end
        end

        -- CRITICAL FIX: Don't move the tab off-screen or hide it when disabling embed
        -- The tab needs to be visible in the dock. Let the dock system manage it.
        if cf2Tab then
            -- Clear any custom positioning we set
            cf2Tab:SetParent(_G.GeneralDockManager or cf2)
            cf2Tab:ClearAllPoints()
            cf2Tab:SetAlpha(1)
            cf2Tab:Show()
            -- Don't hide it - the dock will manage visibility
            -- no debug spam here
        end
        
        -- no debug spam here
    end

      HideDefaultChatArtAndCombatButtons()
      ApplyDefaultChatVisibility()
  end

local chatHideHooked = false

if hooksecurefunc and not chatHideHooked then
    chatHideHooked = true
    if type(_G.FloatingChatFrame_Update) == "function" then
        hooksecurefunc("FloatingChatFrame_Update", function()
            HideDefaultChatArtAndCombatButtons()
            ApplyDefaultChatVisibility()
            UpdateDefaultModeCombatUI("FloatingChatFrame_Update")
        end)
    end
    if type(_G.FCF_UpdateButtonSide) == "function" then
        hooksecurefunc("FCF_UpdateButtonSide", function()
            HideDefaultChatArtAndCombatButtons()
            ApplyDefaultChatVisibility()
            UpdateDefaultModeCombatUI("FCF_UpdateButtonSide")
        end)
    end
    if type(_G.FCF_SelectDockFrame) == "function" then
        hooksecurefunc("FCF_SelectDockFrame", function()
            UpdateDefaultModeCombatUI("FCF_SelectDockFrame")
        end)
    end
    if type(_G.FCF_FadeInChatFrame) == "function" then
        hooksecurefunc("FCF_FadeInChatFrame", function(chatFrame)
            if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
                ForceDefaultChatBackgroundAlpha("FCF_FadeInChatFrame")
                C_Timer.After(0, function()
                    StartDefaultFadeAlphaGuard("FCF_FadeInChatFrame")
                end)
            end
        end)
    end
    if type(_G.FCF_FadeOutChatFrame) == "function" then
        hooksecurefunc("FCF_FadeOutChatFrame", function(chatFrame)
            if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface then
                ForceDefaultChatBackgroundAlpha("FCF_FadeOutChatFrame")
                C_Timer.After(0, function()
                    StartDefaultFadeAlphaGuard("FCF_FadeOutChatFrame")
                end)
            end
        end)
    end
    if type(_G.CombatLog_LoadUI) == "function" then
        hooksecurefunc("CombatLog_LoadUI", function()
            if _G.MidnightUI_CombatEmbedded then
                EnsureCombatQuickButtons()
            end
            C_Timer.After(0.1, function()
            end)
            ScheduleCombatQuickButtonsReassert()
        end)
    end
end

-- =========================================================================
--  5. HEADERS & TABS
-- =========================================================================

local function CreateHeaderButton(parent, text, onClick, onClose)
    local btn = CreateFrame("Button", nil, parent)
    btn.bg = btn:CreateTexture(nil, "BACKGROUND"); btn.bg:SetAllPoints(); btn.bg:SetColorTexture(1, 1, 1, 0.1); btn.bg:Hide()
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal"); btn.text:SetText(text)
    if onClose then
        btn.close = CreateFrame("Button", nil, btn)
        btn.close:SetSize(20, 20); btn.close:SetPoint("RIGHT", btn, "RIGHT", 0, 0)
        btn.close.label = btn.close:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); btn.close.label:SetText("×"); btn.close.label:SetPoint("CENTER", 0, 0); btn.close.label:SetTextColor(0.5, 0.5, 0.5)
        btn.close:SetScript("OnEnter", function(self) self.label:SetTextColor(1, 0.2, 0.2) end)
        btn.close:SetScript("OnLeave", function(self) self.label:SetTextColor(0.5, 0.5, 0.5) end)
        btn.close:SetScript("OnClick", function(self) if onClose then onClose() end end)
        btn:SetWidth(btn.text:GetStringWidth() + 40); btn:SetHeight(20); btn.text:SetPoint("CENTER", btn, "CENTER", -10, 0)
    else
        btn:SetWidth(btn.text:GetStringWidth() + 20); btn:SetHeight(20); btn.text:SetPoint("CENTER")
    end
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", onClick)
    return btn
end

local UpdateWorldHeader

local function UpdateDMHeader()
    if not MessengerDB then return end
    DMTrace(string.format("UpdateDMHeader start activeFilter=%s tabCount=%d", DMToString(ACTIVE_DM_FILTER), #MessengerDB.ActiveWhispers))
    Messenger._directKey.AutoDiag(
        "dm_header_start",
        string.format("dm_header_start activeFilter=%s tabCount=%d", DMToString(ACTIVE_DM_FILTER), #MessengerDB.ActiveWhispers),
        0.2
    )
    local hasTokenKey = false
    for i = 1, #MessengerDB.ActiveWhispers do
        if Messenger._directKey.ParseBNetTokenKey(MessengerDB.ActiveWhispers[i]) then
            hasTokenKey = true
            break
        end
    end
    if hasTokenKey then
        Messenger._directKey.NormalizeContactKeys("UpdateDMHeader token-pass")
    end
    for _, btn in pairs(DMHeaderButtons) do btn:Hide() end
    local prevBtn = nil
    for i, dmKey in ipairs(MessengerDB.ActiveWhispers) do
        local key = dmKey
        local displayName = GetDirectDisplayName(key)
        local meta = GetDirectContactMeta(key)
        local bnetID = tonumber(meta and meta.bnetID) or Messenger._directKey.ParseBNetIDKey(key)
        if IsBNetFallbackLabel(displayName) or IsBNetAnonToken(displayName) then
            Messenger._directKey.AutoDiag(
                "dm_header_label_fallback:" .. tostring(key),
                string.format(
                    "dm_header_label_fallback idx=%d key=%s label=%s bnetID=%s metaDisplay=%s metaTell=%s active=%s",
                    i,
                    DMToString(key),
                    DMToString(displayName),
                    DMToString(bnetID),
                    DMToString(meta and meta.displayName),
                    DMToString(meta and meta.tellTarget),
                    DMToString(ACTIVE_DM_FILTER == key)
                ),
                0.2
            )
        end
        if i > 1 then
            local sepName = "Sep"..i
            local sep = DMHeaderButtons[sepName]
            if not sep then sep = dmHeader:CreateFontString(nil, "OVERLAY", "GameFontNormal"); sep:SetText("|"); sep:SetTextColor(0.2, 0.2, 0.2); DMHeaderButtons[sepName] = sep end
            sep:ClearAllPoints(); sep:SetPoint("LEFT", prevBtn, "RIGHT", 5, 0); sep:Show(); prevBtn = sep 
        end
        local btn = DMHeaderButtons[key]
        if not btn then
            local closeFunc = function()
                for k, v in ipairs(MessengerDB.ActiveWhispers) do
                    if v == key then
                        table.remove(MessengerDB.ActiveWhispers, k)
                        break
                    end
                end
                if MessengerDB.History and MessengerDB.History["Direct"] then
                    local msgs = MessengerDB.History["Direct"].messages
                    for j = #msgs, 1, -1 do
                        local messageKey = ResolveDirectMessageKey(msgs[j])
                        if messageKey and messageKey == key then
                            table.remove(msgs, j)
                        end
                    end
                end
                if MessengerDB.DirectContacts then
                    MessengerDB.DirectContacts[key] = nil
                end
                if ACTIVE_DM_FILTER == key then ACTIVE_DM_FILTER = nil end
                RefreshDisplay(); UpdateDMHeader()
            end
            btn = CreateHeaderButton(dmHeader, displayName, function(self, button) 
                if button == "LeftButton" then 
                    -- Auto-expand if collapsed
                    if isChatCollapsed and not isAnimating then
                        ExpandMessengerFromCollapsed()
                    end
                    Messenger._directKey.AutoDiag(
                        "dm_header_tab_click:" .. tostring(key),
                        (function()
                            local clickMeta = GetDirectContactMeta(key)
                            local clickBnetID = tonumber(clickMeta and clickMeta.bnetID) or Messenger._directKey.ParseBNetIDKey(key)
                            return string.format(
                                "dm_header_tab_click key=%s label=%s prevFilter=%s bnetID=%s",
                                DMToString(key),
                                DMToString(GetDirectDisplayName(key)),
                                DMToString(ACTIVE_DM_FILTER),
                                DMToString(clickBnetID)
                            )
                        end)(),
                        0
                    )
                    ACTIVE_DM_FILTER = key; RefreshDisplay(); UpdateDMHeader() 
                end 
            end, closeFunc)
            DMHeaderButtons[key] = btn
        end
        btn.text:SetText(displayName)
        ApplyTabFontSize(btn.text, GetMessengerTabFontSize())
        -- Measure and cap button width so long names don't blow out the header
        local dmHeaderWidth = dmHeader:GetWidth() or 300
        local maxBtnWidth = math.floor(dmHeaderWidth * 0.40)
        if maxBtnWidth < 60 then maxBtnWidth = 60 end
        local textW = btn.text:GetStringWidth()
        if btn.close then
            btn:SetWidth(math.min(textW + 40, maxBtnWidth))
        else
            btn:SetWidth(math.min(textW + 20, maxBtnWidth))
        end
        btn:ClearAllPoints()
        if i == 1 then btn:SetPoint("LEFT", dmHeader, "LEFT", 15, 0) else btn:SetPoint("LEFT", prevBtn, "RIGHT", 5, 0) end
        -- Hide buttons that would overflow the header
        local btnRight = (btn._dmLayoutX or 15) + btn:GetWidth()
        if i == 1 then
            btn._dmLayoutX = 15
        elseif prevBtn then
            local prevRight = (prevBtn._dmLayoutX or 0) + (prevBtn:GetWidth() or 0) + 5
            btn._dmLayoutX = prevRight
            btnRight = prevRight + btn:GetWidth()
        end
        if btnRight > dmHeaderWidth - 10 then
            btn:Hide()
        else
            btn:Show()
        end
        local classFile = MessengerDB.ContactClasses[displayName]
        local r, g, b = 0.6, 0.6, 0.6
        if classFile then
            if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
                r, g, b = _G.MidnightUI_Core.GetClassColor(classFile)
            elseif RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
                local c = RAID_CLASS_COLORS[classFile]
                r, g, b = c.r, c.g, c.b
            end
        end
        btn.text:SetTextColor(r, g, b)
        if ACTIVE_DM_FILTER == key then btn.bg:Show(); btn:SetAlpha(1.0) else btn.bg:Hide(); btn:SetAlpha(0.6) end
        DMTrace(string.format("UpdateDMHeader tab[%d] key=%s label=%s active=%s", i, DMToString(key), DMToString(displayName), DMToString(ACTIVE_DM_FILTER == key)))
        prevBtn = btn
    end
end

local WORLD_FILTERS = {
    { key = "ALL", label = "All", short = "All" },
    { key = "GENERAL", label = "General", short = "Gen" },
    { key = "TRADE", label = "Trade - City", short = "Trade" },
    { key = "SERVICES", label = "Trade - Services", short = "Svc" },
    { key = "DEFENSE", label = "LocalDefense", short = "Def" },
}

local function GetWorldFilterKeyFromChannel(channelName)
    if not channelName or channelName == "" then return nil end
    local lower = string.lower(channelName)
    if string.find(lower, "services", 1, true) or (string.find(lower, "service", 1, true) and string.find(lower, "trade", 1, true)) then
        return "SERVICES"
    elseif string.find(lower, "trade", 1, true) then
        return "TRADE"
    elseif string.find(lower, "general", 1, true) then
        return "GENERAL"
    elseif string.find(lower, "localdefense", 1, true) or string.find(lower, "local defense", 1, true) then
        return "DEFENSE"
    end
    return nil
end

local function GetWorldFilterKeyFromTag(tag)
    if not tag or tag == "" then return nil end
    if tag == "Trade - Services" or tag == "Service" or tag == "Services" then return "SERVICES" end
    if tag == "Trade - City" or tag == "Trade" then return "TRADE" end
    if tag == "General" then return "GENERAL" end
    if tag == "LocalDefense" or tag == "Local Defense" or tag == "Defense" then return "DEFENSE" end
    return nil
end

local function ApplyWorldFilter(filterKey)
    ACTIVE_WORLD_FILTER = filterKey or "ALL"
    if MessengerDB then
        MessengerDB.WorldUnread = MessengerDB.WorldUnread or { ALL = 0, GENERAL = 0, TRADE = 0, SERVICES = 0, DEFENSE = 0 }
        if ACTIVE_WORLD_FILTER == "ALL" then
            MessengerDB.WorldUnread.ALL = 0
        else
            MessengerDB.WorldUnread[ACTIVE_WORLD_FILTER] = 0
        end
    end
    
    -- Now safe to call SetActiveChannel because it is defined above
    if filterKey == "TRADE" then
        local channelId, channelName = FindTradeChannel()
        if channelId then SetActiveChannel(channelId, channelName) end
    elseif filterKey == "SERVICES" then
        local channelId, channelName = FindServicesChannel()
        if channelId then SetActiveChannel(channelId, channelName) end
    elseif filterKey == "GENERAL" then
        local channelId, channelName = FindChannelByName({ "general" })
        if channelId then SetActiveChannel(channelId, channelName) end
    elseif filterKey == "DEFENSE" then
        local channelId, channelName = FindChannelByName({ "localdefense", "local defense" })
        if channelId then SetActiveChannel(channelId, channelName) end
    end
    RefreshDisplay()
    UpdateWorldHeader()
    if RefreshInputLabel then RefreshInputLabel() end
end

UpdateWorldHeader = function()
    -- Clear previous buttons
    for _, btn in pairs(WorldHeaderButtons) do btn:Hide() end

    -- Check Channel Status
    local tradeActive = FindTradeChannel()
    local servicesActive = FindServicesChannel()
    if areChannelsStale then
        tradeActive = nil
        servicesActive = nil
    end

    -- Auto-Switch safety: If we are on TRADE but lost the channel, switch to ALL
    if ACTIVE_WORLD_FILTER == "TRADE" and not tradeActive then
        ACTIVE_WORLD_FILTER = "ALL"
        ApplyWorldFilter("ALL")
        return
    elseif ACTIVE_WORLD_FILTER == "SERVICES" and not servicesActive then
        ACTIVE_WORLD_FILTER = "ALL"
        ApplyWorldFilter("ALL")
        return
    end

    -- Build list of visible buttons
    local visibleFilters = {}
    for _, def in ipairs(WORLD_FILTERS) do
        local show = true
        if def.key == "TRADE" and not tradeActive then show = false end
        if def.key == "SERVICES" and not servicesActive then show = false end
        if show then table.insert(visibleFilters, def) end
    end

    -- Measure available header width
    local headerWidth = worldHeader:GetWidth() or 300
    local pad = 10
    local btnGap = 8
    local availableWidth = headerWidth - (pad * 2)

    -- Determine if we need short labels: measure full labels first
    local fullTotalWidth = 0
    for i, def in ipairs(visibleFilters) do
        fullTotalWidth = fullTotalWidth + (def._cachedFullWidth or (string.len(def.label) * 7 + 20))
        if i > 1 then fullTotalWidth = fullTotalWidth + btnGap end
    end
    local useShort = (fullTotalWidth > availableWidth)

    -- Render buttons
    local currentX = pad

    for i, def in ipairs(visibleFilters) do
        local displayLabel = useShort and (def.short or def.label) or def.label
        local btn = WorldHeaderButtons[def.key]
        if not btn then
            btn = CreateHeaderButton(worldHeader, displayLabel, function()
                if isChatCollapsed and not isAnimating then
                    ExpandMessengerFromCollapsed()
                end
                ApplyWorldFilter(def.key)
            end)
            WorldHeaderButtons[def.key] = btn

            btn.badge = btn:CreateTexture(nil, "OVERLAY")
            btn.badge:SetColorTexture(0.8, 0.2, 0.2, 1)
            btn.badge:SetSize(16, 16)
            btn.badge:SetPoint("LEFT", btn, "RIGHT", 4, 0)
            btn.badge:Hide()

            btn.badgeText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            btn.badgeText:SetPoint("CENTER", btn.badge, "CENTER", 0, 0)
        end

        -- Update label, font size, and width for current mode
        btn.text:SetText(displayLabel)
        ApplyTabFontSize(btn.text, GetMessengerTabFontSize())
        btn:SetWidth(btn.text:GetStringWidth() + 16)

        -- Skip buttons that would overflow
        if currentX + btn:GetWidth() > headerWidth - pad then
            btn:Hide()
        else
            btn:ClearAllPoints()
            btn:SetPoint("LEFT", worldHeader, "LEFT", currentX, 0)
            btn:Show()

            if ACTIVE_WORLD_FILTER == def.key then
                btn.bg:Show()
                btn:SetAlpha(1.0)
            else
                btn.bg:Hide()
                btn:SetAlpha(0.6)
            end

            -- Handle Badge (Unread counts)
            local count = 0
            if MessengerDB and MessengerDB.WorldUnread then
                count = MessengerDB.WorldUnread[def.key] or 0
            end
            if def.key == "SERVICES" then count = 0 end

            local extraWidth = 0
            if count > 0 and def.key ~= ACTIVE_WORLD_FILTER then
                btn.badge:Show(); btn.badgeText:Show()
                if count > 99 then btn.badgeText:SetText("99+") else btn.badgeText:SetText(count) end
                local w = btn.badgeText:GetStringWidth() + 10
                btn.badge:SetWidth(math.max(16, w))
                extraWidth = math.max(16, w) + 4
            else
                btn.badge:Hide(); btn.badgeText:Hide()
            end

            currentX = currentX + btn:GetWidth() + btnGap + extraWidth
        end
    end
end

WorldFilterAllows = function(data, tradeActive, servicesActive)
    if not ACTIVE_WORLD_FILTER or ACTIVE_WORLD_FILTER == "ALL" then 
        -- If viewing "All", hide Trade/Services messages if we are not in those channels
        local tag = data.tag or ""
        if (tag == "Trade - City" or tag == "Trade") and not tradeActive then return false end
        if (tag == "Trade - Services" or tag == "Service" or tag == "Services") and not servicesActive then return false end
        return true 
    end
    
    local tag = data.tag or ""
    if ACTIVE_WORLD_FILTER == "GENERAL" then return tag == "General"
    elseif ACTIVE_WORLD_FILTER == "TRADE" then return tag == "Trade - City" or tag == "Trade"
    elseif ACTIVE_WORLD_FILTER == "SERVICES" then return tag == "Trade - Services" or tag == "Service" or tag == "Services"
    elseif ACTIVE_WORLD_FILTER == "DEFENSE" then return tag == "LocalDefense" or tag == "Local Defense" or tag == "Defense"
    end
    return true
end

local TAB_ORDER = { "Global", "Local", "Group", "Guild", "Comm", "World", "Direct", "Market", "Debug", "CombatLog" }

local function UpdateTabLayout()
    if not MessengerDB then return end
    local keepDebugHidden = MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.keepDebugHidden == true
    local userTabSpacing = GetMessengerMainTabSpacing()

    local hideGlobal = false
    if MidnightUI_GetMessengerSettings then
        local settings = MidnightUI_GetMessengerSettings()
        hideGlobal = settings and settings.hideGlobal == true
    end

    if hideGlobal and ACTIVE_TAB == "Global" then
        ACTIVE_TAB = "Local"
    end

    -- [NEW] Save the current tab so it persists through Loading Screens
    MessengerDB.LastActiveTab = ACTIVE_TAB

    if keepDebugHidden and ACTIVE_TAB == "Debug" then
        ACTIVE_TAB = "Local"
    end

    -- ── Pass 1: determine visibility for every tab ──────────────────────
    -- All tabs are now stacked from the top in order (no more bottom-pinned tabs).
    local visibleTabs = {}
    for _, cat in ipairs(TAB_ORDER) do
        local btn = TabButtons[cat]
        local shouldShow = false
        if cat == "Global" and hideGlobal then
            shouldShow = false
        elseif cat == "Debug" then
            if not keepDebugHidden then
                local hasDiag = (_G.MidnightUI_DiagnosticsHasEntries and _G.MidnightUI_DiagnosticsHasEntries()) or false
                local hasQueue = _G.MidnightUI_DiagnosticsQueue and #_G.MidnightUI_DiagnosticsQueue > 0
                if hasDiag or hasQueue then
                    shouldShow = true
                end
            end
        else
            if MessengerDB.History[cat] then
                local hasMsgs = (#MessengerDB.History[cat].messages > 0)
                if cat == "Global" or cat == "Local" or cat == "World" or cat == "CombatLog" or cat == "Market" then shouldShow = true
                elseif cat == "Direct" then shouldShow = (MessengerDB.ActiveWhispers and #MessengerDB.ActiveWhispers > 0)
                elseif cat == "Group" then shouldShow = IsInGroup() and GetNumGroupMembers() > 1
                elseif cat == "Guild" then shouldShow = IsInGuild() or hasMsgs
                else shouldShow = hasMsgs end
            end
        end
        if ACTIVE_TAB == cat then
            if cat == "Group" and not IsInGroup() then
                shouldShow = false
            elseif cat == "Debug" and keepDebugHidden then
                shouldShow = false
            else
                shouldShow = true
            end
        end

        if shouldShow and btn then
            visibleTabs[#visibleTabs + 1] = { cat = cat, btn = btn }
        elseif btn then
            btn:Hide()
        end
    end

    -- ── Pass 2: compute adaptive spacing ────────────────────────────────
    local messengerHeight = Messenger:GetHeight()
    local totalVisible = #visibleTabs
    local topPad = 10
    local bottomPad = 10
    local availableHeight = messengerHeight - topPad - bottomPad

    -- Distribute tabs evenly, capped by user preference
    local adaptiveSpacing = userTabSpacing
    if totalVisible > 0 then
        local idealSpacing = math.floor(availableHeight / totalVisible)
        adaptiveSpacing = math.min(userTabSpacing, idealSpacing)
    end
    local MIN_SPACING = 22
    if adaptiveSpacing < MIN_SPACING then adaptiveSpacing = MIN_SPACING end

    local adaptiveTabHeight = adaptiveSpacing - 2
    if adaptiveTabHeight < 18 then adaptiveTabHeight = 18 end
    if adaptiveTabHeight > 48 then adaptiveTabHeight = 48 end

    -- Badge sizing: scale down at narrower widths
    local messengerWidth = Messenger:GetWidth()
    local badgeHeight = 16
    local badgeFontObj = "GameFontHighlightSmall"
    if messengerWidth < 400 then
        badgeHeight = 12
        badgeFontObj = "GameFontHighlightExtraSmall"
    elseif messengerWidth < 500 then
        badgeHeight = 14
    end

    -- Tab font size: use the user setting, but shrink if tabs are very cramped
    local tabFontSize = GetMessengerTabFontSize()
    if adaptiveTabHeight < 24 and tabFontSize > 10 then
        tabFontSize = 10
    end

    -- ── Pass 3: position and style every visible tab ────────────────────
    local currentY = -topPad
    for _, entry in ipairs(visibleTabs) do
        local cat = entry.cat
        local btn = entry.btn

        btn:SetHeight(adaptiveTabHeight)
        if btn.bar then btn.bar:SetHeight(adaptiveTabHeight) end
        if btn.badge then
            btn.badge:SetHeight(badgeHeight)
            btn.badge:ClearAllPoints()
            btn.badge:SetPoint("RIGHT", btn, "RIGHT", -10, 0)
        end
        if btn.badgeText then
            btn.badgeText:SetFontObject(badgeFontObj)
        end

        if btn.text then
            local fullLabel = btn._muiFullLabel or btn.text:GetText() or cat
            -- Dynamic label for Group tab based on group type
            if cat == "Group" then
                if IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
                    fullLabel = "Battleground"
                elseif IsInRaid and IsInRaid() then
                    fullLabel = "Raid"
                end
            end
            btn.text:SetText(fullLabel)
            ApplyTabFontSize(btn.text, tabFontSize)
        end

        btn:Show()
        btn:ClearAllPoints()
        btn:SetPoint("TOPLEFT", Messenger, "TOPLEFT", 0, currentY)
        currentY = currentY - adaptiveSpacing

        -- Active state
        if cat == ACTIVE_TAB then
            btn.bar:Show(); btn.text:SetTextColor(1, 1, 1)
            -- Color the bar orange for BG mode
            if cat == "Group" and IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
                btn.bar:SetColorTexture(1.0, 0.5, 0.0, 1)
            end
        else btn.bar:Hide(); btn.text:SetTextColor(0.6, 0.6, 0.6) end

        -- Unread badge
        if MessengerDB.History[cat] then
            local count = MessengerDB.History[cat].unread
            if count > 0 and cat ~= ACTIVE_TAB and cat ~= "CombatLog" then
                btn.badge:Show(); btn.badgeText:Show()
                if count > 99 then btn.badgeText:SetText("99+") else btn.badgeText:SetText(count) end
                local w = btn.badgeText:GetStringWidth() + 12; btn.badge:SetWidth(math.max(badgeHeight, w))
            else
                btn.badge:Hide(); btn.badgeText:Hide()
            end
        end
    end
end

-- [CRITICAL FIX] Export the function globally so TargetFrame.lua can call it
_G.UpdateTabLayout = UpdateTabLayout 

msgFrame:SetScript("OnHyperlinkClick", function(self, link, text, button)
    local linkType, linkValue = strsplit(":", link)
    if (linkType == "player" or linkType == "BNplayer") and button == "LeftButton" then
        local name = linkValue
        if linkType == "BNplayer" then name = linkValue end
        if MessengerDB and name then
            local chatType = (linkType == "BNplayer") and "BN_WHISPER" or "WHISPER"
            local dmKey, displayName, tellTarget, isBNet, bnetID = BuildDirectIdentityFromChatTarget(chatType, name)
            if dmKey then
                local _, registeredKey = RegisterDirectContact(dmKey, displayName, tellTarget, isBNet, bnetID)
                if type(registeredKey) == "string" and registeredKey ~= "" then
                    dmKey = registeredKey
                end
                ACTIVE_TAB = "Direct"
                ACTIVE_DM_FILTER = dmKey
            end
            if TabButtons["Direct"] then TabButtons["Direct"]:Click() end 
            ChatFrame_OpenChat("/w " .. name .. " "); return
        end
    end
    SetItemRef(link, text, button, self)
end)

local suppressTabMode = false
local worldMenu

local function CreateTabButton(label, category)
    local mainTabHeight = GetMessengerMainTabHeight()
    local btn = CreateFrame("Button", nil, Messenger)
    btn.category = category
    btn._muiFullLabel = label  -- preserved for compact/normal mode switching
    btn:SetSize(130, mainTabHeight)  -- Match sidebar width
    btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btn.text:SetPoint("LEFT", btn, "LEFT", 20, 0)  -- Adjusted from 15 for wider tabs
    btn.text:SetText(label)
    btn.text:SetTextColor(0.6, 0.6, 0.6)
    local hl = btn:CreateTexture(nil, "HIGHLIGHT"); hl:SetAllPoints(); hl:SetColorTexture(1, 1, 1, 0.05)
    local barR, barG, barB = GetPlayerClassColor()
    if currentChatTheme and currentChatTheme.tabBarColor then
        barR, barG, barB = currentChatTheme.tabBarColor[1], currentChatTheme.tabBarColor[2], currentChatTheme.tabBarColor[3]
    end
    btn.bar = btn:CreateTexture(nil, "OVERLAY"); btn.bar:SetColorTexture(barR, barG, barB, 1); btn.bar:SetSize(3, mainTabHeight); btn.bar:SetPoint("LEFT", btn, "LEFT", 0, 0); btn.bar:Hide()
    btn.badge = btn:CreateTexture(nil, "OVERLAY"); btn.badge:SetColorTexture(0.8, 0.2, 0.2, 1); btn.badge:SetHeight(16); btn.badge:SetPoint("RIGHT", btn, "RIGHT", -10, 0); btn.badge:Hide()
    btn.badgeText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); btn.badgeText:SetPoint("CENTER", btn.badge, "CENTER", 0, 0)
    
    if category == "Debug" then
        local bg = btn:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.5, 0, 0, 0.4) 
        btn.bar:SetColorTexture(1, 0, 0, 1) 
    end
    
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    btn:SetScript("OnClick", function(self, mouseButton)
        -- Right-click on Guild tab opens the custom Guild Panel
        if mouseButton == "RightButton" and category == "Guild" then
            if _G.MidnightUI_GuildPanelAPI and _G.MidnightUI_GuildPanelAPI.Toggle then
                _G.MidnightUI_GuildPanelAPI.Toggle()
            elseif ToggleGuildFrame then
                pcall(ToggleGuildFrame)
            end
            return
        end

        DebugHeaderSync("TabClick:before", "category=" .. tostring(category))
        -- Auto-expand if collapsed
        if isChatCollapsed and not isAnimating then
            ExpandMessengerFromCollapsed()
        end
        
        ACTIVE_TAB = category
        if category == "Direct" then
            local activeCount = (MessengerDB and MessengerDB.ActiveWhispers and #MessengerDB.ActiveWhispers) or 0
            Messenger._directKey.AutoDiag(
                "dm_enter_direct",
                string.format("dm_enter_direct activeFilter=%s activeWhispers=%d", DMToString(ACTIVE_DM_FILTER), activeCount),
                0
            )
        end
        if category ~= "World" then
            ACTIVE_CHANNEL_ID = nil
        end
        if category ~= "Direct" then
            ACTIVE_DM_FILTER = nil
        end
        if MessengerDB and MessengerDB.History[category] then MessengerDB.History[category].unread = 0 end
        UpdateTabLayout()
        if RefreshInputLabel then RefreshInputLabel() end
        if dmHeader then dmHeader:Hide() end
        if worldHeader then worldHeader:Hide() end
        if worldMenu then worldMenu:Hide() end
        if title then title:Hide() end
        if debugCopyBtn then debugCopyBtn:Hide() end 
        if debugClearBtn then debugClearBtn:Hide() end
        if debugDiagBtn then debugDiagBtn:Hide() end
        if marketClearBtn then marketClearBtn:Hide() end 
        
          if category == "CombatLog" then
              msgFrame:Hide(); title:Show(); title:SetText("|cff00ccff#|r  Combat Log"); EmbedBlizzardCombatLog(true)
              EnsureCombatQuickButtons()
              ScheduleCombatQuickButtonsReassert()
        elseif category == "Debug" then
            EmbedBlizzardCombatLog(false)
            if debugCopyBtn then debugCopyBtn:Hide() end
            if debugClearBtn then debugClearBtn:Hide() end
            if debugDiagBtn then debugDiagBtn:Hide() end
              local function EnsureDiagFallbackFrame()
                  if _G.MidnightUI_DiagnosticsFallbackFrame then return _G.MidnightUI_DiagnosticsFallbackFrame end
                local f = CreateFrame("Frame", "MidnightUI_DiagnosticsFallbackFrame", UIParent, "BackdropTemplate")
                f:SetSize(900, 600)
                f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
                f:SetFrameStrata("FULLSCREEN_DIALOG")
                f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
                f:SetBackdropColor(0.06, 0.07, 0.13, 0.98)
                f:SetBackdropBorderColor(0.18, 0.22, 0.30, 1.0)
                f:SetClampedToScreen(true)
                f:EnableMouse(true)
                f:SetMovable(true)
                f:RegisterForDrag("LeftButton")
                f:SetScript("OnDragStart", f.StartMoving)
                f:SetScript("OnDragStop", f.StopMovingOrSizing)
                local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                t:SetPoint("TOPLEFT", 14, -12)
                t:SetText("MIDNIGHT UI DIAGNOSTICS (FALLBACK)")
                t:SetTextColor(1, 0.86, 0.2)
                local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                sub:SetPoint("TOPLEFT", 14, -36)
                sub:SetText("Diagnostics UI failed to load. This is a text-only export.")
                sub:SetTextColor(0.75, 0.8, 0.9)
                local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
                scroll:SetPoint("TOPLEFT", 12, -56)
                scroll:SetPoint("BOTTOMRIGHT", -32, 14)
                local edit = CreateFrame("EditBox", nil, scroll)
                edit:SetMultiLine(true)
                edit:SetFontObject("ChatFontNormal")
                edit:SetAutoFocus(false)
                edit:SetWidth(840)
                edit:EnableMouse(true)
                edit:SetScript("OnEscapePressed", function() f:Hide() end)
                scroll:SetScrollChild(edit)
                local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
                close:SetPoint("TOPRIGHT", -6, -6)
                f.edit = edit
                _G.MidnightUI_DiagnosticsFallbackFrame = f
                return f
            end

              local function BuildFallbackDump()
                  local db = _G.MidnightUIDiagnosticsDB
                  local lines = {}
                  lines[#lines + 1] = "=== MidnightUI Diagnostics (Fallback Export) ==="
                  lines[#lines + 1] = "Reason: Diagnostics API missing"
                lines[#lines + 1] = "Session: " .. tostring(db and db.session or 0)
                lines[#lines + 1] = "Entries: " .. tostring(db and db.errors and #db.errors or 0)
                lines[#lines + 1] = ""
                if db and db.errors then
                    for i = #db.errors, 1, -1 do
                        local e = db.errors[i]
                        if e then
                            lines[#lines + 1] = "----- Entry " .. tostring(i) .. " -----"
                            lines[#lines + 1] = "Type: " .. tostring(e.kind or "?")
                            lines[#lines + 1] = "Addon: " .. tostring(e.addon or "UNKNOWN")
                            lines[#lines + 1] = "Count: " .. tostring(e.count or 1)
                            if e.sig and e.sig ~= "" then lines[#lines + 1] = "Signature: " .. tostring(e.sig) end
                            if e.meta and e.meta ~= "" then lines[#lines + 1] = "Meta: " .. tostring(e.meta) end
                            if e.message and e.message ~= "" then
                                lines[#lines + 1] = "Message:"
                                lines[#lines + 1] = tostring(e.message)
                            end
                            if e.stack and e.stack ~= "" then
                                lines[#lines + 1] = "Stack:"
                                lines[#lines + 1] = tostring(e.stack)
                            end
                            lines[#lines + 1] = ""
                        end
                    end
                end
                return table.concat(lines, "\n")
            end

              local opened = false
              local errText = nil
              if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.Open then
                  local ok, err = _G.MidnightUI_Diagnostics.Open()
                  if ok == false then
                      errText = err
                  else
                      opened = true
                  end
              else
                  errText = "Diagnostics API missing"
              end
              if _G.MidnightUI_DiagnosticsLastError then
                  errText = _G.MidnightUI_DiagnosticsLastError
              elseif _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.lastError then
                  errText = _G.MidnightUI_Diagnostics.lastError
              end
              if opened then
                  if _G.MidnightUI_DiagnosticsStatusFrame and _G.MidnightUI_DiagnosticsStatusFrame.Hide then
                      _G.MidnightUI_DiagnosticsStatusFrame:Hide()
                  end
                  if _G.MidnightUI_DiagnosticsFallbackFrame and _G.MidnightUI_DiagnosticsFallbackFrame.Hide then
                      _G.MidnightUI_DiagnosticsFallbackFrame:Hide()
                  end
                  return
              end
              ShowDiagnosticsStatus(errText)
              local fallback = EnsureDiagFallbackFrame()
              fallback.edit:SetText(BuildFallbackDump())
              fallback.edit:HighlightText()
              fallback:Show()
              fallback:Raise()
              return
        elseif category == "Market" then
            EmbedBlizzardCombatLog(false); msgFrame:Show(); title:Show(); title:SetText("|cffFFD700#|r  Market")
            if marketClearBtn then marketClearBtn:Show() end
            RefreshDisplay()
        else
            EmbedBlizzardCombatLog(false); msgFrame:Show()
            if category == "World" then
                if worldHeader then worldHeader:Show() end
                UpdateWorldHeader()
            elseif category == "Direct" then
                if dmHeader then dmHeader:Show() end
                if not ACTIVE_DM_FILTER and #MessengerDB.ActiveWhispers > 0 then ACTIVE_DM_FILTER = MessengerDB.ActiveWhispers[#MessengerDB.ActiveWhispers] end
                UpdateDMHeader()
            else
                title:Show(); title:SetText("|cff00ccff#|r  "..label)
            end
            RefreshDisplay()
        end
        DebugHeaderSync("TabClick:after", "category=" .. tostring(category))
    end)
    TabButtons[category] = btn
    return btn
end

CreateTabButton("Global", "Global")
CreateTabButton("Local", "Local")
CreateTabButton("Group", "Group")
CreateTabButton("Guild", "Guild")
CreateTabButton("Comm",  "Comm")
CreateTabButton("World", "World")
CreateTabButton("DMs",   "Direct")
CreateTabButton("Market", "Market")
CreateTabButton("Combat", "CombatLog")
CreateTabButton("Debug", "Debug")

worldMenu = CreateFrame("Frame", nil, Messenger, "BackdropTemplate")
worldMenu:SetFrameStrata("DIALOG")
worldMenu:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
worldMenu:SetBackdropColor(CHAT_BG[1], CHAT_BG[2], CHAT_BG[3], 0.95)
worldMenu:SetBackdropBorderColor(0.2, 0.2, 0.2, 1)
worldMenu:EnableMouse(true)
worldMenu:Hide()

local function SetupWorldMenu()
    local worldBtn = TabButtons["World"]
    if not worldBtn then return end

    local menuWidth = 170
    local itemHeight = 22
    local padding = 8
    
    local function UpdateMenuButtons()
        local tradeActive = FindTradeChannel()
        local servicesActive = FindServicesChannel()
        if areChannelsStale then
            tradeActive = nil
            servicesActive = nil
        end

        local visibleItems = {}
        for _, def in ipairs(WORLD_FILTERS) do
            local show = true
            if def.key == "TRADE" and not tradeActive then show = false end
            if def.key == "SERVICES" and not servicesActive then show = false end
            if show then table.insert(visibleItems, def) end
        end

        worldMenu:SetSize(menuWidth, (#visibleItems * itemHeight) + (padding * 2))
        for _, btn in pairs(WorldMenuButtons) do btn:Hide() end
        
        local prev = nil
        for i, def in ipairs(visibleItems) do
            local btn = WorldMenuButtons[def.key]
            if not btn then
                btn = CreateFrame("Button", nil, worldMenu)
                btn:SetHeight(itemHeight)
                btn.text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                btn.text:SetPoint("LEFT", btn, "LEFT", 6, 0)
                btn.text:SetText(def.label)
                btn.bg = btn:CreateTexture(nil, "BACKGROUND"); btn.bg:SetAllPoints(); btn.bg:SetColorTexture(1, 1, 1, 0.08); btn.bg:Hide()
                btn.badge = btn:CreateTexture(nil, "OVERLAY"); btn.badge:SetColorTexture(0.8, 0.2, 0.2, 1); btn.badge:SetSize(16, 16); btn.badge:SetPoint("RIGHT", btn, "RIGHT", -2, 0); btn.badge:Hide()
                btn.badgeText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); btn.badgeText:SetPoint("CENTER", btn.badge, "CENTER", 0, 0)
                btn:SetScript("OnEnter", function(self) self.bg:Show() end)
                btn:SetScript("OnLeave", function(self) self.bg:Hide() end)
                btn:SetScript("OnClick", function()
                    if TabButtons["World"] then TabButtons["World"]:Click() end
                    ApplyWorldFilter(def.key)
                    worldMenu:Hide()
                end)
                WorldMenuButtons[def.key] = btn
            end

            btn:ClearAllPoints()
            btn:SetPoint("LEFT", worldMenu, "LEFT", padding, 0)
            btn:SetPoint("RIGHT", worldMenu, "RIGHT", -padding, 0)
            if i == 1 then btn:SetPoint("TOP", worldMenu, "TOP", 0, -padding) else btn:SetPoint("TOP", prev, "BOTTOM", 0, 0) end
            btn:Show()
            
            local count = 0
            if MessengerDB and MessengerDB.WorldUnread then count = MessengerDB.WorldUnread[def.key] or 0 end
            if def.key == "SERVICES" then count = 0 end
            if count > 0 and def.key ~= ACTIVE_WORLD_FILTER then
                btn.badge:Show(); btn.badgeText:Show()
                if count > 99 then btn.badgeText:SetText("99+") else btn.badgeText:SetText(count) end
                local mw = btn.badgeText:GetStringWidth() + 10; btn.badge:SetWidth(math.max(16, mw))
            else
                btn.badge:Hide(); btn.badgeText:Hide()
            end
            prev = btn
        end
    end

    worldMenu:ClearAllPoints()
    worldMenu:SetPoint("TOPLEFT", worldBtn, "TOPRIGHT", 6, 0)

    local function HideWorldMenuIfOutside()
        C_Timer.After(0.1, function()
            if not MouseIsOver(worldMenu) and not MouseIsOver(worldBtn) then worldMenu:Hide() end
        end)
    end

    worldBtn:SetScript("OnEnter", function() UpdateMenuButtons(); worldMenu:Show() end)
    worldBtn:SetScript("OnLeave", function() HideWorldMenuIfOutside() end)
    worldMenu:SetScript("OnEnter", function() worldMenu:Show() end)
    worldMenu:SetScript("OnLeave", function() HideWorldMenuIfOutside() end)
end

SetupWorldMenu()

-- =========================================================================
--  6. REAGENT & LAYOUT LOGIC (SECURE OVERLAY IMPLEMENTATION)
-- =========================================================================
-- [This section remains as is or empty depending on your file structure]

-- =========================================================================
--  7. EVENT HANDLERS
-- =========================================================================

SafeToString = function(value)
    if value == nil then return "nil" end
    if value == false then return "false" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    local ok2 = pcall(function() return table.concat({ s }, "") end)
    if not ok2 then return "[Restricted]" end
    return s
end

_G.MidnightUI_SafeToString = SafeToString
if not _G.SafeToString then
    _G.SafeToString = SafeToString
end

-- Guard tooltip money updates against restricted (secret) values.
if _G.SetTooltipMoney and not _G.MidnightUI_Orig_SetTooltipMoney then
    _G.MidnightUI_Orig_SetTooltipMoney = _G.SetTooltipMoney
    _G.SetTooltipMoney = function(tooltip, amount, ...)
        if type(amount) ~= "number" then return end
        local ok = pcall(_G.MidnightUI_Orig_SetTooltipMoney, tooltip, amount, ...)
        if not ok then return end
    end
end

if _G.MoneyFrame_Update and not _G.MidnightUI_Orig_MoneyFrame_Update then
    _G.MidnightUI_Orig_MoneyFrame_Update = _G.MoneyFrame_Update
    _G.MoneyFrame_Update = function(frame, money, ...)
        if type(money) ~= "number" then return end
        local ok = pcall(_G.MidnightUI_Orig_MoneyFrame_Update, frame, money, ...)
        if not ok then return end
    end
end

-- Prevent /reload in combat from triggering Blizzard UI errors.
if _G.ReloadUI and not _G.MidnightUI_Orig_ReloadUI then
    _G.MidnightUI_Orig_ReloadUI = _G.ReloadUI
    _G.ReloadUI = function(...)
        if InCombatLockdown and InCombatLockdown() then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat. Try again out of combat.")
            return
        end
        return _G.MidnightUI_Orig_ReloadUI(...)
    end
end

-- =========================================================================
--  LUA ERROR AGGREGATION (LOW-SPAM DEBUG LOGGING)
-- =========================================================================

function _G.MidnightUI_RegisterDiagnostic(name, fn)
    return
end

local function OnChatEvent(self, event, msg, author, ...)
    local safeMsg = SafeToString(msg)
    if safeMsg == "nil" or safeMsg == "[Restricted]" or safeMsg == "[Restricted Message Hidden]" then
        return
    end
    local shortName = "Unknown"
    local isBNetWhisperEvent = (event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM")
    local isSystem = (event == "CHAT_MSG_SYSTEM" or event == "GUILD_MOTD")
    if not isSystem then
        local s = SafeToString(author)
        if s == "nil" or s == "[Restricted]" or s == "[Restricted Message Hidden]" then
            return
        end
        if s ~= "nil" and s ~= "[Restricted]" then
            local ok2, hasDash = pcall(function() return strfind(s, "-") ~= nil end)
            if ok2 and hasDash and not isBNetWhisperEvent then
                local ok3, split = pcall(function() return strsplit("-", s) end)
                if ok3 and split then shortName = split else shortName = s end
            else
                shortName = s
            end
        end
    else
        shortName = "System"
    end
    local timestamp = date("%H:%M")
    local epoch = time()
    local category = "Local" 
    local nameColorDef, msgColorDef, tag = "bbbbbb", "bbbbbb", ""
    local guid = select(10, ...) 
    local isSilent = false
    local worldFilterKeyForEvent = nil
    local directWhisperListChanged = false
    local directKey = nil
    local directRefreshKey = nil
    local directDidFullRefresh = false

    local function ChatTypeColorHex(chatType, fallbackHex)
        if ChatTypeInfo and chatType and ChatTypeInfo[chatType] then
            local info = ChatTypeInfo[chatType]
            local r = info.r or info[1] or 1
            local g = info.g or info[2] or 1
            local b = info.b or info[3] or 1
            return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
        end
        return fallbackHex or "ffffff"
    end

    local function ChatTypeColorHexByEvent(chatEvent, fallbackHex)
        if not chatEvent then return fallbackHex or "ffffff" end
        local chatType = chatEvent:gsub("^CHAT_MSG_", "")
        return ChatTypeColorHex(chatType, fallbackHex)
    end

    local function ChannelColorHex(channelString, channelNumber, fallbackHex)
        local chanNum = channelNumber
        if not chanNum and type(channelString) == "string" then
            chanNum = tonumber(channelString:match("^(%d+)"))
        end
        if chanNum and ChatTypeInfo and ChatTypeInfo["CHANNEL" .. chanNum] then
            local info = ChatTypeInfo["CHANNEL" .. chanNum]
            local r = info.r or info[1] or 1
            local g = info.g or info[2] or 1
            local b = info.b or info[3] or 1
            return string.format("%02x%02x%02x", r * 255, g * 255, b * 255)
        end
        return ChatTypeColorHex("CHANNEL", fallbackHex)
    end
    
    if guid and MessengerDB then
        local _, cls = GetPlayerInfoByGUID(guid)
        if cls then MessengerDB.ContactClasses[shortName] = cls end
    end

    if event == "CHAT_MSG_WHISPER" or event == "CHAT_MSG_BN_WHISPER"
        or event == "CHAT_MSG_WHISPER_INFORM" or event == "CHAT_MSG_BN_WHISPER_INFORM" then
        category = "Direct"
        DMTrace(string.format("OnChatEvent direct event=%s author=%s", DMToString(event), DMCompactText(author, 80)))
        if event == "CHAT_MSG_BN_WHISPER" or event == "CHAT_MSG_BN_WHISPER_INFORM" then
            nameColorDef = ChatTypeColorHexByEvent(event, "00defa")
        else
            nameColorDef = ChatTypeColorHexByEvent(event, "ff80ff")
        end
        msgColorDef = nameColorDef

        local dmKey, dmDisplay, tellTarget, isBNet, bnetID = BuildDirectIdentityFromEvent(event, author, ...)
        if dmKey then
            directKey = dmKey
            shortName = dmDisplay or shortName
            DMTrace(string.format("OnChatEvent direct resolved event=%s key=%s display=%s tellTarget=%s isBNet=%s bnetID=%s", DMToString(event), DMToString(dmKey), DMToString(dmDisplay), DMToString(tellTarget), DMToString(isBNet), DMToString(bnetID)))
            if IsBNetFallbackLabel(dmDisplay) or IsBNetAnonToken(dmDisplay) then
                Messenger._directKey.AutoDiag(
                    "dm_event_display_fallback:" .. tostring(dmKey),
                    string.format(
                        "dm_event_display_fallback event=%s key=%s display=%s tellTarget=%s bnetID=%s author=%s",
                        DMToString(event),
                        DMToString(dmKey),
                        DMToString(dmDisplay),
                        DMToString(tellTarget),
                        DMToString(bnetID),
                        DMToString(author)
                    ),
                    0.2
                )
            end
            if MessengerDB then
                local inserted, registeredKey = RegisterDirectContact(dmKey, shortName, tellTarget, isBNet, bnetID)
                if type(registeredKey) == "string" and registeredKey ~= "" then
                    dmKey = registeredKey
                    directKey = registeredKey
                end
                DMTrace(string.format(
                    "OnChatEvent direct-register event=%s inserted=%s activeTab=%s activeFilter=%s key=%s entryAuthor=%s",
                    DMToString(event),
                    DMToString(inserted),
                    DMToString(ACTIVE_TAB),
                    DMToString(ACTIVE_DM_FILTER),
                    DMToString(dmKey),
                    DMToString(author)
                ))
                if inserted then
                    directWhisperListChanged = true
                    if ACTIVE_TAB == "Direct" and UpdateDMHeader then UpdateDMHeader() end
                end
                if event == "CHAT_MSG_WHISPER_INFORM" or event == "CHAT_MSG_BN_WHISPER_INFORM" then
                    ACTIVE_DM_FILTER = dmKey
                    if ACTIVE_TAB ~= "Direct" and ACTIVE_TAB ~= "Global" and TabButtons and TabButtons["Direct"] then
                        ACTIVE_TAB = "Direct"
                        TabButtons["Direct"]:Click()
                    end
                    DMTrace(string.format("OnChatEvent direct-refresh defer key=%s activeFilter=%s", DMToString(dmKey), DMToString(ACTIVE_DM_FILTER)))
                    DMAutoDiag(
                        "dm_direct_refresh",
                        string.format("dm_direct_refresh phase=defer event=%s key=%s activeFilter=%s", DMToString(event), DMToString(dmKey), DMToString(ACTIVE_DM_FILTER)),
                        0
                    )
                    directRefreshKey = dmKey
                end
            end
        end

    elseif event == "CHAT_MSG_GUILD" or event == "CHAT_MSG_OFFICER" then
        category = "Guild"; nameColorDef = ChatTypeColorHexByEvent(event, "40ff40"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        category = "Guild"; nameColorDef = ChatTypeColorHexByEvent(event, "40ff40"); msgColorDef = nameColorDef
        -- Some clients deliver guild achievement text with a leading "%s" token.
        -- We already show the author separately, so remove the placeholder.
        if type(safeMsg) == "string" then
            safeMsg = safeMsg:gsub("^%%s%s*", "")
        end
    elseif event == "GUILD_MOTD" then
        category = "Local"; nameColorDef = ChatTypeColorHex("GUILD", "40ff40"); msgColorDef = nameColorDef; shortName = "Guild"; safeMsg = "MOTD: " .. safeMsg
    elseif event == "CHAT_MSG_COMMUNITIES_CHANNEL" then
        category = "Comm"; nameColorDef = ChatTypeColorHexByEvent(event, "50c0ff"); msgColorDef = nameColorDef; tag = "[C]"
    elseif event == "CHAT_MSG_PARTY" or event == "CHAT_MSG_PARTY_LEADER" then
        category = "Group"; nameColorDef = ChatTypeColorHexByEvent(event, "aaaaff"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_RAID" then
        category = "Group"; nameColorDef = ChatTypeColorHexByEvent(event, "ff8000"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_RAID_LEADER" then
        category = "Group"; nameColorDef = ChatTypeColorHexByEvent(event, "ff4000"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_INSTANCE_CHAT" then
        category = "Group"; nameColorDef = ChatTypeColorHexByEvent(event, "ff8000"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_INSTANCE_CHAT_LEADER" then
        category = "Group"; nameColorDef = ChatTypeColorHexByEvent(event, "ff4000"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_SAY" then
        category = "Local"; nameColorDef = "ffffff"; msgColorDef = "ffffff"
    elseif event == "CHAT_MSG_YELL" then
        category = "Local"; nameColorDef = "ff4040"; msgColorDef = "ff4040"
    elseif event == "CHAT_MSG_TEXT_EMOTE" then
        category = "Local"; nameColorDef = ChatTypeColorHex("EMOTE", "ff8000"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_MONSTER_SAY" then
        category = "Local"; nameColorDef = ChatTypeColorHex("MONSTER_SAY", "ffff00"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_MONSTER_YELL" then
        category = "Local"; nameColorDef = ChatTypeColorHex("MONSTER_YELL", "ff4040"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_MONSTER_EMOTE" then
        category = "Local"; nameColorDef = ChatTypeColorHex("MONSTER_EMOTE", "ffccaa"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_RAID_BOSS_EMOTE" then
        category = "Local"; nameColorDef = ChatTypeColorHex("RAID_BOSS_EMOTE", "ffccaa"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_MONSTER_WHISPER" then
        category = "Local"; nameColorDef = ChatTypeColorHex("MONSTER_WHISPER", "ffccaa"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_RAID_BOSS_WHISPER" then
        category = "Local"; nameColorDef = ChatTypeColorHex("RAID_BOSS_WHISPER", "ffccaa"); msgColorDef = nameColorDef
    elseif event == "CHAT_MSG_SYSTEM" then
        category = "Local"; nameColorDef = ChatTypeColorHexByEvent(event, "ffff00"); msgColorDef = nameColorDef
        shortName = "System"
        if safeMsg and safeMsg ~= "nil" then
            local lower = string.lower(safeMsg)
            if string.find(lower, "guild")
                or string.find(lower, "has been promoted")
                or string.find(lower, "has been demoted")
                or string.find(lower, "you have been promoted")
                or string.find(lower, "you have been demoted")
            then
                category = "Guild"
            end
            if string.find(lower, "has come online") or string.find(lower, "has gone offline") then
                isSilent = true
                local settings = MidnightUI_GetMessengerSettings and MidnightUI_GetMessengerSettings()
                if settings and settings.hideLoginStates == true then
                    return
                end
            end
        end
    elseif event == "CHAT_MSG_LOOT" then
        category = "Local"; nameColorDef = "00aa00"; msgColorDef = "00aa00"
        shortName = ""
    elseif event == "CHAT_MSG_CHANNEL" then
        local channelBase = select(7, ...)
        local channelString = select(2, ...)
        local channelNumber = select(6, ...)
        local safeName = SafeToString(channelBase or channelString or "")
        local lowerSafe = string.lower(safeName)
        local chanColor = ChannelColorHex(channelString, channelNumber, "ffd700")
        if string.find(lowerSafe, "services", 1, true) or (string.find(lowerSafe, "service", 1, true) and string.find(lowerSafe, "trade", 1, true)) then
            category = "World"; nameColorDef = chanColor; msgColorDef = chanColor; tag = GetChannelDisplayName(safeName)
        else
            category = "World"
            if string.find(lowerSafe, "trade", 1, true) then nameColorDef = chanColor; msgColorDef = chanColor; tag = GetChannelDisplayName(safeName)
            elseif string.find(lowerSafe, "general", 1, true) then nameColorDef = chanColor; msgColorDef = chanColor; tag = "General"
            elseif string.find(lowerSafe, "localdefense", 1, true) or string.find(lowerSafe, "local defense", 1, true) then nameColorDef = chanColor; msgColorDef = chanColor; tag = "LocalDefense"
            else nameColorDef = chanColor; msgColorDef = chanColor; tag = "Channel" end
        end
        worldFilterKeyForEvent = GetWorldFilterKeyFromTag(tag) or GetWorldFilterKeyFromChannel(safeName) or "ALL"
    end

    local dataObject = {
        msg = safeMsg, author = shortName, guid = guid, timestamp = timestamp, epoch = epoch,
        nameColorDefault = nameColorDef, msgColorDefault = msgColorDef, tag = tag, directKey = directKey
    }
    
    if MessengerDB then
        local includeGlobal = (category == "Local" or category == "Group" or category == "Guild" or category == "Comm" or category == "World" or category == "Direct")
        if includeGlobal then
            if not MessengerDB.History["Global"] then MessengerDB.History["Global"] = {unread=0, messages={}} end
            table.insert(MessengerDB.History["Global"].messages, dataObject)
            if #MessengerDB.History["Global"].messages > MAX_HISTORY then table.remove(MessengerDB.History["Global"].messages, 1) end
        end

        if not MessengerDB.History[category] then MessengerDB.History[category] = {unread=0, messages={}} end
        table.insert(MessengerDB.History[category].messages, dataObject)
        if #MessengerDB.History[category].messages > MAX_HISTORY then table.remove(MessengerDB.History[category].messages, 1) end
        -- Stamp guild chat ownership so it clears on character switch
        if category == "Guild" and not MessengerDB.GuildChatOwner then
            local cn = UnitName("player") or ""
            local rn = GetRealmName() or ""
            MessengerDB.GuildChatOwner = cn .. "-" .. rn
        end
        if category == "Direct" then
            DMAutoDiag(
                "dm_direct_history",
                string.format(
                    "dm_direct_history event=%s key=%s activeFilter=%s directCount=%d directKey=%s author=%s msg=%s",
                    DMToString(event),
                    DMToString(directRefreshKey or directKey),
                    DMToString(ACTIVE_DM_FILTER),
                    #MessengerDB.History[category].messages,
                    DMToString(directKey),
                    DMToString(shortName),
                    DMCompactText(safeMsg, 48)
                ),
                0
            )
            if directRefreshKey and ACTIVE_TAB == "Direct" then
                ACTIVE_DM_FILTER = directRefreshKey
                if UpdateDMHeader then UpdateDMHeader() end
                RefreshDisplay()
                directDidFullRefresh = true
                DMTrace(string.format("OnChatEvent direct-refresh after-insert key=%s activeFilter=%s", DMToString(directRefreshKey), DMToString(ACTIVE_DM_FILTER)))
                DMAutoDiag(
                    "dm_direct_refresh",
                    string.format("dm_direct_refresh phase=after_insert key=%s activeFilter=%s directCount=%d", DMToString(directRefreshKey), DMToString(ACTIVE_DM_FILTER), #MessengerDB.History[category].messages),
                    0
                )
            end
        end
        if category == "Group" then PruneGroupHistory() end
        
        if category == "World" then
            MessengerDB.WorldUnread = MessengerDB.WorldUnread or { ALL = 0, GENERAL = 0, TRADE = 0, SERVICES = 0, DEFENSE = 0 }
            local filterKey = GetWorldFilterKeyFromTag(dataObject.tag)
            if filterKey then
                if not (ACTIVE_TAB == "World" and ACTIVE_WORLD_FILTER == filterKey) then
                    MessengerDB.WorldUnread[filterKey] = (MessengerDB.WorldUnread[filterKey] or 0) + 1
                end
            end
            if filterKey ~= "SERVICES" then
                if not (ACTIVE_TAB == "World" and ACTIVE_WORLD_FILTER == "ALL") then
                    MessengerDB.WorldUnread.ALL = (MessengerDB.WorldUnread.ALL or 0) + 1
                end
            end
            UpdateWorldHeader()
        end

        -- If the player sends to a world channel (e.g. /2 Trade), switch to World and matching filter.
        if category == "World" then
            local playerName = UnitName("player")
            if playerName and shortName and string.lower(shortName) == string.lower(playerName) then
                local desiredFilter = worldFilterKeyForEvent or "ALL"
                DebugHeaderSync("SelfWorldMsg:before", "tag=" .. tostring(tag) .. " desiredFilter=" .. tostring(desiredFilter))
                local needsWorldVisualSync = (ACTIVE_TAB ~= "World")
                if not needsWorldVisualSync and title and title.IsShown and title:IsShown() then
                    needsWorldVisualSync = true
                end
                if needsWorldVisualSync then
                    if TabButtons and TabButtons["World"] then
                        DebugHeaderSync("SelfWorldMsg:clickWorldTab", "needsWorldVisualSync=true")
                        TabButtons["World"]:Click()
                    else
                        DebugHeaderSync("SelfWorldMsg:fallbackVisualSync", "needsWorldVisualSync=true")
                        ACTIVE_TAB = "World"
                        UpdateTabLayout()
                        RefreshDisplay()
                        if UpdateWorldHeader then UpdateWorldHeader() end
                    end
                end
                if ApplyWorldFilter then
                    ApplyWorldFilter(desiredFilter)
                else
                    ACTIVE_WORLD_FILTER = desiredFilter
                end
                DebugHeaderSync("SelfWorldMsg:after", "tag=" .. tostring(tag) .. " desiredFilter=" .. tostring(desiredFilter))
            end
        end
        
        if category == "Direct" and (directWhisperListChanged or ACTIVE_TAB == "Global") then
            UpdateTabLayout()
        end

        if not isSilent and AddCollapsedUnreadIndicator then
            AddCollapsedUnreadIndicator(event, category, dataObject, worldFilterKeyForEvent)
        end

        if ACTIVE_TAB == "Global" and includeGlobal then
            local ok, finalString = pcall(FormatMessage, dataObject)
            if ok and finalString and finalString ~= "" then msgFrame:AddMessage(finalString) end
        elseif category == ACTIVE_TAB and not (category == "Direct" and directDidFullRefresh) then
            local shouldShow = true
            if ACTIVE_TAB == "World" and not WorldFilterAllows(dataObject) then shouldShow = false end
            if shouldShow then
                local ok, finalString = pcall(FormatMessage, dataObject)
                if ok and finalString and finalString ~= "" then msgFrame:AddMessage(finalString) end
            end
        elseif not isSilent then
            MessengerDB.History[category].unread = MessengerDB.History[category].unread + 1
            if includeGlobal and ACTIVE_TAB ~= "Global" then
                MessengerDB.History["Global"].unread = (MessengerDB.History["Global"].unread or 0) + 1
            end
            UpdateTabLayout() 
        end
    end
end

_G.MidnightUI_TestGuildAchievementEvent = function(customMsg)
    local player = UnitName("player") or "Player"
    local realm = GetRealmName() or ""
    local author = (realm ~= "" and (player .. "-" .. realm)) or player
    local msg = customMsg
    if not msg or msg == "" then
        msg = string.format("%s has earned the achievement [MidnightUI Guild Achievement Test].", player)
    end
    -- GUID is read from select(10, ...) inside OnChatEvent, so pass it as the 10th vararg.
    OnChatEvent(nil, "CHAT_MSG_GUILD_ACHIEVEMENT", msg, author,
        nil, nil, nil, nil, nil, nil, nil, nil, nil, UnitGUID("player"))
    if ACTIVE_TAB == "Guild" then RefreshDisplay() end
    LogDebug("[MessengerTest] Injected CHAT_MSG_GUILD_ACHIEVEMENT for " .. tostring(author))
end

-- =========================================================================
--  8. SETTINGS APPLICATION
-- =========================================================================

local function ApplyChatTheme(settings)
    local theme = GetChatTheme(settings and settings.style or "Default")
    currentChatTheme = theme
    CHAT_BG = theme.chatBg
    TAB_BG = theme.tabBg
    SEPARATOR_COLOR = theme.separator
    INPUT_BG = theme.inputBg

    local chatAlpha = theme.chatAlpha or settings.alpha
    local tabAlpha = theme.tabAlpha or settings.alpha
    local sepAlpha = theme.separatorAlpha or settings.alpha
    local borderAlpha = theme.borderAlpha or settings.alpha
    local inputAlpha = theme.inputAlpha or 1

    Messenger.bg:SetColorTexture(CHAT_BG[1], CHAT_BG[2], CHAT_BG[3], chatAlpha)
    sidebar:SetColorTexture(TAB_BG[1], TAB_BG[2], TAB_BG[3], tabAlpha)
    sidebarSep:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], sepAlpha)
    headerSep:SetColorTexture(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], sepAlpha)
    if messengerBorder and messengerBorder.SetColor then messengerBorder.SetColor(0, 0, 0, borderAlpha) end

    collapseBtn:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], tabAlpha)
    collapseBtn:SetBackdropBorderColor(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], sepAlpha)
    if collapsedBubbleBtn and collapsedBubbleBtn.bgFrame then
        collapsedBubbleBtn.bgFrame:SetBackdropColor(TAB_BG[1], TAB_BG[2], TAB_BG[3], tabAlpha)
        collapsedBubbleBtn.bgFrame:SetBackdropBorderColor(SEPARATOR_COLOR[1], SEPARATOR_COLOR[2], SEPARATOR_COLOR[3], sepAlpha)
    end

    if worldMenu then worldMenu:SetBackdropColor(CHAT_BG[1], CHAT_BG[2], CHAT_BG[3], chatAlpha) end

    local eb = _G["ChatFrame1EditBox"]
    if eb and eb.midnightBg then
        eb.midnightBg:SetColorTexture(INPUT_BG[1], INPUT_BG[2], INPUT_BG[3], inputAlpha)
    end
    if eb and eb.midnightBorder and theme.accent then
        eb.midnightBorder:SetColorTexture(theme.accent[1], theme.accent[2], theme.accent[3], 1)
    end

    -- Text shadows for transparent styles (Minimal)
    local sx, sy, sr, sg, sb, sa
    if theme.textShadow then
        sx, sy, sr, sg, sb, sa = 1, -1, 0, 0, 0, 1
    else
        sx, sy, sr, sg, sb, sa = 0, 0, 0, 0, 0, 0
    end
    msgFrame:SetShadowOffset(sx, sy)
    msgFrame:SetShadowColor(sr, sg, sb, sa)
    title:SetShadowOffset(sx, sy)
    title:SetShadowColor(sr, sg, sb, sa)
    collapseArrow:SetShadowOffset(sx, sy)
    collapseArrow:SetShadowColor(sr, sg, sb, sa)
    if eb and eb.midnightLabel then
        eb.midnightLabel:SetShadowOffset(sx, sy)
        eb.midnightLabel:SetShadowColor(sr, sg, sb, sa)
    end
    if TabButtons then
        for _, btn in pairs(TabButtons) do
            if btn and btn.text then
                btn.text:SetShadowOffset(sx, sy)
                btn.text:SetShadowColor(sr, sg, sb, sa)
            end
            if btn and btn.badgeText then
                btn.badgeText:SetShadowOffset(sx, sy)
                btn.badgeText:SetShadowColor(sr, sg, sb, sa)
            end
        end
    end

    if TabButtons then
        for _, btn in pairs(TabButtons) do
            if btn and btn.bar and btn.category ~= "Debug" and theme.tabBarColor then
                btn.bar:SetColorTexture(theme.tabBarColor[1], theme.tabBarColor[2], theme.tabBarColor[3], 1)
            end
        end
    end
end

local function ApplySettings()
    if not MidnightUI_GetMessengerSettings then C_Timer.After(0.5, ApplySettings) return end
    local settings = MidnightUI_GetMessengerSettings()
    if not settings then return end
    ApplyChatTheme(settings)
    local scale = tonumber(settings.scale) or 1.0
    Messenger:SetScale(scale)
    if settings.locked then dragOverlay:Hide() else dragOverlay:Show() end
    RefreshDisplay()
end

_G.MidnightUI_ApplyMessengerTheme = ApplySettings

-- =========================================================================
--  9. STARTUP & INPUT (SECURE NATIVE IMPLEMENTATION)
-- =========================================================================

local function MigrateLegacyDirectStorage()
    if not MessengerDB then return end
    EnsureDirectContactStore()
    local convertedMessages = 0
    local convertedWhispers = 0

    local oldWhispers = {}
    if type(MessengerDB.ActiveWhispers) == "table" then
        for _, value in ipairs(MessengerDB.ActiveWhispers) do
            if type(value) == "string" and value ~= "" then
                oldWhispers[#oldWhispers + 1] = value
            end
        end
    end

    MessengerDB.ActiveWhispers = {}

    for _, legacyName in ipairs(oldWhispers) do
        local key, displayName, tellTarget, isBNet, bnetID = BuildDirectIdentityFromLegacyName(legacyName)
        if key then
            if RegisterDirectContact(key, displayName, tellTarget, isBNet, bnetID) then
                convertedWhispers = convertedWhispers + 1
            end
        end
    end

    local directBucket = MessengerDB.History and MessengerDB.History["Direct"]
    if directBucket and type(directBucket.messages) == "table" then
        for _, data in ipairs(directBucket.messages) do
            local hadKey = (type(data) == "table" and type(data.directKey) == "string" and data.directKey ~= "")
            local key = ResolveDirectMessageKey(data)
            if key then
                local meta = GetDirectContactMeta(key)
                local displayName = (meta and meta.displayName) or data.author
                local tellTarget = (meta and meta.tellTarget) or nil
                local isBNet = meta and meta.isBNet or nil
                local bnetID = (meta and meta.bnetID) or data.bnetID
                RegisterDirectContact(key, displayName, tellTarget, isBNet, bnetID)
                if not hadKey then
                    convertedMessages = convertedMessages + 1
                end
            end
        end
    end

    DMTrace(string.format("MigrateLegacyDirectStorage convertedTabs=%d convertedMessages=%d", convertedWhispers, convertedMessages), true)
end

local function InitDB()
    local isSafe = true
    if not MessengerDB then isSafe = false 
    elseif not MessengerDB.History.CombatLog then isSafe = false end

    DMTrace("InitDB start", true)
    
    -- Ensure sub-tables exist
    if MessengerDB and not MessengerDB.History.Debug then MessengerDB.History.Debug = {unread=0, messages={}} end
    if MessengerDB and not MessengerDB.History.Market then MessengerDB.History.Market = {unread=0, messages={}} end
    if MessengerDB and not MessengerDB.History.Global then MessengerDB.History.Global = {unread=0, messages={}} end
    
    -- [NEW] Restore the previous tab if it exists
    if MessengerDB and MessengerDB.LastActiveTab then
        ACTIVE_TAB = MessengerDB.LastActiveTab
    end

    -- [NEW] Lock the tab switching logic for 3 seconds so 'Say' defaults don't override our restore
    suppressTabMode = true
    C_Timer.After(3, function() suppressTabMode = false end)
    
    -- Reset DB if unsafe
    if not isSafe then
        MessengerDB = { 
            History={
                Local={unread=0,messages={}}, Group={unread=0,messages={}}, Guild={unread=0,messages={}},
                Comm={unread=0,messages={}}, World={unread=0,messages={}}, Services={unread=0,messages={}},
                Direct={unread=0,messages={}}, Debug={unread=0,messages={}}, CombatLog={unread=0,messages={}},
                Market={unread=0,messages={}}
                ,Global={unread=0,messages={}}
            }, ActiveWhispers={}, DirectContacts={}, DirectTokenMap={}, ContactClasses={},
        }
    end

    if MessengerDB and not MessengerDB.WorldUnread then
        MessengerDB.WorldUnread = { ALL = 0, GENERAL = 0, TRADE = 0, SERVICES = 0, DEFENSE = 0 }
    end
    if MessengerDB and type(MessengerDB.ActiveWhispers) ~= "table" then
        MessengerDB.ActiveWhispers = {}
    end
    if MessengerDB and type(MessengerDB.DirectContacts) ~= "table" then
        MessengerDB.DirectContacts = {}
    end
    if MessengerDB and type(MessengerDB.DirectTokenMap) ~= "table" then
        MessengerDB.DirectTokenMap = {}
    end
    if MessengerDB and type(MessengerDB.ContactClasses) ~= "table" then
        MessengerDB.ContactClasses = {}
    end
    if MessengerDB and not MessengerDB.History.Services then MessengerDB.History.Services = {unread=0, messages={}} end
    if MessengerDB and not MessengerDB.History.Direct then MessengerDB.History.Direct = {unread=0, messages={}} end

    if MessengerDB then
        MigrateLegacyDirectStorage()
        Messenger._directKey.BackfillTokenAliases("InitDB pre-normalize")
        Messenger._directKey.NormalizeContactKeys("InitDB post-migrate")
        local activeCount = (type(MessengerDB.ActiveWhispers) == "table" and #MessengerDB.ActiveWhispers) or 0
        local contactsCount = (type(MessengerDB.DirectContacts) == "table" and DMCountKeys(MessengerDB.DirectContacts)) or 0
        local directCount = (MessengerDB.History and MessengerDB.History["Direct"] and MessengerDB.History["Direct"].messages and #MessengerDB.History["Direct"].messages) or 0
        Messenger._directKey.AutoDiag(
            "dm_init_summary",
            string.format(
                "dm_init_summary activeWhispers=%d contacts=%d directMessages=%d activeFilter=%s",
                activeCount,
                contactsCount,
                directCount,
                DMToString(ACTIVE_DM_FILTER)
            ),
            0
        )
    end
    
    -- Migrate old Services messages if needed
    if MessengerDB and MessengerDB.History.Services and MessengerDB.History.World then
        if #MessengerDB.History.Services.messages > 0 then
            for _, data in ipairs(MessengerDB.History.Services.messages) do
                table.insert(MessengerDB.History.World.messages, data)
            end
            MessengerDB.History.Services.messages = {}
            MessengerDB.History.Services.unread = 0
        end
    end

    -- Sanitize previously saved guild-achievement lines that were stored as
    -- "%s has earned..." while author is already rendered separately.
    local function SanitizeGuildAchievementHistoryBucket(bucket)
        if not bucket or type(bucket.messages) ~= "table" then return end
        for _, data in ipairs(bucket.messages) do
            if data and type(data.msg) == "string" then
                local lower = string.lower(data.msg)
                if (lower:find("has earned the achievement", 1, true) or lower:find("guild challenge completed", 1, true))
                    and data.msg:find("^%%s%s*") then
                    data.msg = data.msg:gsub("^%%s%s*", "")
                end
            end
        end
    end
    if MessengerDB and MessengerDB.History then
        SanitizeGuildAchievementHistoryBucket(MessengerDB.History.Guild)
        SanitizeGuildAchievementHistoryBucket(MessengerDB.History.Global)
    end
    
    if MidnightUI_GetMessengerSettings then
        local settings = MidnightUI_GetMessengerSettings()
        if settings and settings.position then
            local p = settings.position
            Messenger:ClearAllPoints(); Messenger:SetPoint(p[1], UIParent, p[2], p[3], p[4])
        end
    end
    FlushDebugQueue()
    EnsurePrintOverride()
    -- Prune all history channels on login (caps at MAX_HISTORY per channel, removes >3 day old messages)
    PruneAllHistory()

    -- Guild chat is account-wide SavedVariables — clear it when the character changes
    -- so one character's guild messages don't leak into another character's guild panel.
    local currentChar = UnitName("player") or ""
    local currentRealm = GetRealmName() or ""
    local charKey = currentChar .. "-" .. currentRealm
    if MessengerDB and MessengerDB.History and MessengerDB.History["Guild"] then
        if MessengerDB.GuildChatOwner ~= charKey then
            MessengerDB.History["Guild"].messages = {}
            MessengerDB.History["Guild"].unread = 0
            MessengerDB.GuildChatOwner = charKey
        end
    end

    ApplySettings(); UpdateTabLayout(); RefreshDisplay()
end

local function SyncEditBoxToTab(eb)
    if not eb then return end
    if ACTIVE_TAB == "Direct" and ACTIVE_DM_FILTER then
        local meta = GetDirectContactMeta(ACTIVE_DM_FILTER)
        local tellTarget = meta and meta.tellTarget or nil
        local isBNet = meta and meta.isBNet or false
        if not tellTarget or tellTarget == "" then
            tellTarget = meta and meta.displayName or nil
        end
        if (not tellTarget or tellTarget == "" or IsBNetFallbackLabel(tellTarget)) and meta and meta.bnetID then
            local resolved = ResolveBNetDisplayNameByID(meta.bnetID)
            if resolved and resolved ~= "" then
                tellTarget = resolved
            end
        end
        if (not tellTarget or tellTarget == "") and type(ACTIVE_DM_FILTER) == "string" then
            local fromCharKey = ACTIVE_DM_FILTER:match("^char:(.+)$")
            if fromCharKey and fromCharKey ~= "" then
                tellTarget = fromCharKey
            end
            local fromBName = ACTIVE_DM_FILTER:match("^bn_name:(.+)$")
            if (not tellTarget or tellTarget == "") and fromBName and fromBName ~= "" then
                tellTarget = fromBName
                isBNet = true
            end
        end
        if not isBNet and type(ACTIVE_DM_FILTER) == "string" and (ACTIVE_DM_FILTER:find("^bn:") or ACTIVE_DM_FILTER:find("^bn_token:")) then
            isBNet = true
        end
        if not isBNet and tellTarget and tellTarget ~= "" then
            local resolvedBNetID = ResolveBNetIDFromTarget(tellTarget)
            if resolvedBNetID then
                isBNet = true
                if meta then meta.bnetID = resolvedBNetID end
            end
        end
        if not tellTarget or tellTarget == "" then
            tellTarget = ACTIVE_DM_FILTER
        end
        DMTrace(string.format("SyncEditBoxToTab direct key=%s tellTarget=%s isBNet=%s metaDisplay=%s metaTell=%s metaBnetID=%s", DMToString(ACTIVE_DM_FILTER), DMToString(tellTarget), DMToString(isBNet), DMToString(meta and meta.displayName), DMToString(meta and meta.tellTarget), DMToString(meta and meta.bnetID)))
        if isBNet then
            eb:SetAttribute("chatType", "BN_WHISPER")
            eb:SetAttribute("tellTarget", tellTarget)
        else
            eb:SetAttribute("chatType", "WHISPER")
            eb:SetAttribute("tellTarget", tellTarget)
        end
        ChatEdit_UpdateHeader(eb)
    elseif ACTIVE_TAB == "Guild" then eb:SetAttribute("chatType", "GUILD"); eb:SetAttribute("tellTarget", nil); ChatEdit_UpdateHeader(eb)
    elseif ACTIVE_TAB == "Group" then
        if IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
            eb:SetAttribute("chatType", "INSTANCE_CHAT")
        elseif IsInRaid() then
            eb:SetAttribute("chatType", "RAID")
        else
            eb:SetAttribute("chatType", "PARTY")
        end
        eb:SetAttribute("tellTarget", nil); ChatEdit_UpdateHeader(eb)
    elseif ACTIVE_TAB == "World" and ACTIVE_CHANNEL_ID then
        eb:SetAttribute("chatType", "CHANNEL"); eb:SetAttribute("channelTarget", ACTIVE_CHANNEL_ID); eb:SetAttribute("tellTarget", nil); ChatEdit_UpdateHeader(eb)
    end
end

UpdateEditBoxLabel = function(eb)
    if IsDefaultChatEnabled() then return end
    if not eb or not eb.midnightLabel then return end
    local origHeader = _G[eb:GetName().."Header"]
    if origHeader then origHeader:Hide(); origHeader:SetText("") end
    local chatType = eb:GetAttribute("chatType")
    local tellTarget = eb:GetAttribute("tellTarget")
    local channelTarget = eb:GetAttribute("channelTarget")
    local editText = eb.GetText and eb:GetText() or ""
    local explicitSlash = (type(editText) == "string" and editText:find("^/") ~= nil)
    local slashCmd = explicitSlash and GetSlashCommandToken(editText) or nil
    if slashCmd then
        if slashCmd == "p" or slashCmd == "party" then
            chatType = "PARTY"
        elseif slashCmd == "i" or slashCmd == "instance" or slashCmd == "bg" or slashCmd == "raid" then
            chatType = "INSTANCE_CHAT"
        elseif slashCmd == "g" or slashCmd == "guild" then
            chatType = "GUILD"
        elseif slashCmd == "o" or slashCmd == "officer" then
            chatType = "OFFICER"
        elseif slashCmd == "s" or slashCmd == "say" then
            chatType = "SAY"
        elseif slashCmd == "y" or slashCmd == "yell" then
            chatType = "YELL"
        elseif slashCmd == "e" or slashCmd == "em" or slashCmd == "me" or slashCmd == "emote" then
            chatType = "EMOTE"
        elseif slashCmd:match("^%d+$") then
            chatType = "CHANNEL"
            channelTarget = tonumber(slashCmd)
        end
    end
    local directLocked = (ACTIVE_TAB == "Direct" and type(ACTIVE_DM_FILTER) == "string" and ACTIVE_DM_FILTER ~= "")
    local activeDirectIsBNet = directLocked and (ACTIVE_DM_FILTER:find("^bn:") or ACTIVE_DM_FILTER:find("^bn_token:") or ACTIVE_DM_FILTER:find("^bn_name:"))
    local directResyncReason = nil
    if directLocked and not explicitSlash and not eb._midnightDirectResync then
        if chatType ~= "WHISPER" and chatType ~= "BN_WHISPER" then
            directResyncReason = "mode"
        elseif not tellTarget or tellTarget == "" then
            directResyncReason = "missing_target"
        elseif activeDirectIsBNet and chatType ~= "BN_WHISPER" then
            directResyncReason = "bnet_mode"
        elseif activeDirectIsBNet and (IsBNetAnonToken(tellTarget) or IsBNetFallbackLabel(tellTarget)) then
            directResyncReason = "bnet_token"
        end
    end
    if directResyncReason then
        eb._midnightDirectResync = true
        SyncEditBoxToTab(eb)
        eb._midnightDirectResync = nil
        chatType = eb:GetAttribute("chatType")
        tellTarget = eb:GetAttribute("tellTarget")
        channelTarget = eb:GetAttribute("channelTarget")
        DMTrace(string.format("UpdateEditBoxLabel direct-resync reason=%s filter=%s chatType=%s tellTarget=%s", DMToString(directResyncReason), DMToString(ACTIVE_DM_FILTER), DMToString(chatType), DMToString(tellTarget)))
    end
    local labelText = "[Say]"
    local color = {0, 0.8, 1}
    local allowTabSwitch = (ACTIVE_TAB ~= "Global") and not suppressTabMode
    local allowDirectTabSwitch = not suppressTabMode and ACTIVE_TAB ~= "Global"
    local inGroup = IsInGroup() or IsInRaid()
    local inRaid = IsInRaid()
    local inInstanceGroup = IsInGroup and IsInGroup(LE_PARTY_CATEGORY_INSTANCE)
    
    if chatType == "BN_WHISPER" then
        labelText = "[To: " .. (tellTarget or "?") .. "]"
        color = {GetChatTypeColorRGB("BN_WHISPER", {0, 0.87, 0.98})}
        if not explicitSlash then
            MidnightUI_SyncWhisperTarget(eb, allowDirectTabSwitch)
            if allowDirectTabSwitch and ACTIVE_TAB ~= "Direct" then ACTIVE_TAB = "Direct"; if TabButtons["Direct"] then TabButtons["Direct"]:Click() end end
        else
            DMTrace(string.format("UpdateEditBoxLabel slash-override chatType=%s text=%s", DMToString(chatType), DMCompactText(editText, 40)))
        end
    elseif chatType == "WHISPER" then 
        labelText = "[To: " .. (tellTarget or "?") .. "]"
        color = {GetChatTypeColorRGB("WHISPER", {1, 0.5, 1})}
        if not explicitSlash then
            MidnightUI_SyncWhisperTarget(eb, allowDirectTabSwitch)
            if allowDirectTabSwitch and ACTIVE_TAB ~= "Direct" then ACTIVE_TAB = "Direct"; if TabButtons["Direct"] then TabButtons["Direct"]:Click() end end
        else
            DMTrace(string.format("UpdateEditBoxLabel slash-override chatType=%s text=%s", DMToString(chatType), DMCompactText(editText, 40)))
        end
    elseif chatType == "CHANNEL" then
        local arg1, arg2 = GetChannelName(channelTarget)
        local chanName = "Channel"
        if type(arg1) == "string" then chanName = arg1 elseif type(arg2) == "string" then chanName = arg2 end
        if type(channelTarget) == "number" and ChatTypeInfo and ChatTypeInfo["CHANNEL" .. channelTarget] then
            color = {GetChatTypeColorRGB("CHANNEL" .. channelTarget, {1, 0.82, 0.2})}
        else
            color = {GetChatTypeColorRGB("CHANNEL", {1, 0.82, 0.2})}
        end
        local filterKey = "ALL"
        if chanName:find("Trade - City") then filterKey = "TRADE"; labelText = "[Trade - City]"
        elseif chanName:find("Services") or chanName:find("Service") then filterKey = "SERVICES"; labelText = "[Trade - Services]"
        elseif chanName:find("General") then filterKey = "GENERAL"; local zone = GetRealZoneText() or ""; if zone ~= "" then labelText = "[General - " .. zone .. "]" else labelText = "[General]" end
        elseif chanName:find("LocalDefense") or chanName:find("Defense") then filterKey = "DEFENSE"; labelText = "[LocalDefense]"
        else labelText = "[" .. chanName .. "]" end
        if allowTabSwitch then
            local needUpdate = false
            if ACTIVE_TAB ~= "World" then ACTIVE_TAB = "World"; needUpdate = true end
            if ACTIVE_WORLD_FILTER ~= filterKey then
                if ApplyWorldFilter then ApplyWorldFilter(filterKey); needUpdate = false else ACTIVE_WORLD_FILTER = filterKey; needUpdate = true end
            end
            if needUpdate then UpdateTabLayout(); RefreshDisplay(); if UpdateWorldHeader then UpdateWorldHeader() end end
            -- Keep header visuals in sync when channel slash parsing switches chat mode.
            if title and title.IsShown and title:IsShown() then title:Hide() end
            if dmHeader and dmHeader.IsShown and dmHeader:IsShown() then dmHeader:Hide() end
            if worldHeader and worldHeader.Show then worldHeader:Show() end
            if UpdateWorldHeader then UpdateWorldHeader() end
        end
    elseif chatType == "GUILD" then labelText = "[Guild]"; color = {GetChatTypeColorRGB("GUILD", {0.25, 1, 0.25})}; if allowTabSwitch and ACTIVE_TAB ~= "Guild" then ACTIVE_TAB = "Guild"; if TabButtons["Guild"] then TabButtons["Guild"]:Click() end end
    elseif chatType == "OFFICER" then labelText = "[Officer]"; color = {GetChatTypeColorRGB("OFFICER", {0.25, 1, 0.25})}; if allowTabSwitch and ACTIVE_TAB ~= "Guild" then ACTIVE_TAB = "Guild"; if TabButtons["Guild"] then TabButtons["Guild"]:Click() end end
    elseif (chatType == "PARTY" or chatType == "PARTY_LEADER") and inGroup then labelText = "[Party]"; color = {GetChatTypeColorRGB("PARTY", {0.5, 0.5, 1})}; if allowTabSwitch and ACTIVE_TAB ~= "Group" then ACTIVE_TAB = "Group"; if TabButtons["Group"] then TabButtons["Group"]:Click() end end
    elseif (chatType == "INSTANCE_CHAT" or chatType == "INSTANCE_CHAT_LEADER") and inInstanceGroup then labelText = "[Instance]"; color = {GetChatTypeColorRGB("INSTANCE_CHAT", {1, 0.5, 0})}; if allowTabSwitch and ACTIVE_TAB ~= "Group" then ACTIVE_TAB = "Group"; if TabButtons["Group"] then TabButtons["Group"]:Click() end end
    elseif chatType == "RAID" and inRaid then labelText = "[Raid]"; color = {GetChatTypeColorRGB("RAID", {1, 0.5, 0})}; if allowTabSwitch and ACTIVE_TAB ~= "Group" then ACTIVE_TAB = "Group"; if TabButtons["Group"] then TabButtons["Group"]:Click() end end
    elseif chatType == "RAID_LEADER" and inRaid then labelText = "[Raid]"; color = {GetChatTypeColorRGB("RAID_LEADER", {1, 0.25, 0})}; if allowTabSwitch and ACTIVE_TAB ~= "Group" then ACTIVE_TAB = "Group"; if TabButtons["Group"] then TabButtons["Group"]:Click() end end
    elseif chatType == "RAID_WARNING" and inRaid then labelText = "[RW]"; color = {GetChatTypeColorRGB("RAID_WARNING", {1, 0.3, 0.1})}; if allowTabSwitch and ACTIVE_TAB ~= "Group" then ACTIVE_TAB = "Group"; if TabButtons["Group"] then TabButtons["Group"]:Click() end end
    elseif chatType == "YELL" then
        labelText = "[Yell]"; color = {GetChatTypeColorRGB("YELL", {1, 0.35, 0.35})}
        -- Do not yank the user out of World view after one-off channel sends (e.g. /2).
        if allowTabSwitch and (not directLocked or explicitSlash) and ACTIVE_TAB ~= "Local" and ACTIVE_TAB ~= "World" then
            ACTIVE_TAB = "Local"; if TabButtons["Local"] then TabButtons["Local"]:Click() end
        end
    elseif chatType == "SAY" then
        labelText = "[Say]"; color = {GetChatTypeColorRGB("SAY", {0, 0.8, 1})}
        -- Do not yank the user out of World view after one-off channel sends (e.g. /2).
        if allowTabSwitch and (not directLocked or explicitSlash) and ACTIVE_TAB ~= "Local" and ACTIVE_TAB ~= "World" then
            ACTIVE_TAB = "Local"; if TabButtons["Local"] then TabButtons["Local"]:Click() end
        end
    elseif chatType == "EMOTE" then labelText = "[Emote]"; color = {GetChatTypeColorRGB("EMOTE", {1, 0.5, 0})}
    end
    eb.midnightLabel:SetText(labelText); eb.midnightLabel:SetTextColor(unpack(color))
    eb:SetTextColor(unpack(color))
    local width = eb.midnightLabel:GetStringWidth(); eb:SetTextInsets(width + 15, 10, 0, 0)
end

local CHANNEL_SPACE_DEBUG = false
local function DebugChannelSpaceState(stage, eb)
    if not CHANNEL_SPACE_DEBUG then return end
    if type(LogDebug) ~= "function" then return end
    if not eb then return end
    local text = eb.GetText and eb:GetText() or ""
    local last = eb._midnightLastChannelTraceText or ""
    local chatType = eb.GetAttribute and eb:GetAttribute("chatType") or "?"
    local titleShown = (title and title.IsShown and title:IsShown()) and "true" or "false"
    local worldShown = (worldHeader and worldHeader.IsShown and worldHeader:IsShown()) and "true" or "false"
    local slashNow = (type(text) == "string" and text:sub(1, 1) == "/")
    local slashBefore = (type(last) == "string" and last:sub(1, 1) == "/")
    -- High sensitivity for slash input transitions and immediate follow-up state changes.
    if not slashNow and not slashBefore then return end
    if text == last and tostring(stage):find("OnTextChanged", 1, true) then return end
    eb._midnightLastChannelTraceText = text
    LogDebug(string.format(
        "[ChanSpace] %s text='%s' last='%s' chatType=%s activeTab=%s worldFilter=%s titleShown=%s worldHeaderShown=%s",
        tostring(stage or "?"),
        tostring(text),
        tostring(last),
        tostring(chatType),
        tostring(ACTIVE_TAB),
        tostring(ACTIVE_WORLD_FILTER),
        titleShown,
        worldShown
    ))
end

StyleDefaultEditBox = function()
    if IsDefaultChatEnabled() then
        RestoreDefaultEditBox()
        return
    end
    local eb = _G["ChatFrame1EditBox"]
    if not eb then return end
    local origHeader = _G["ChatFrame1EditBoxHeader"]
    if origHeader then origHeader:Hide(); origHeader:SetAlpha(0) end
    local regions = {eb:GetRegions()}
    if not eb._midnightRegions then
        eb._midnightRegions = {}
        for _, region in ipairs(regions) do
            if region:IsObjectType("Texture") then
                table.insert(eb._midnightRegions, { r = region, tex = region:GetTexture(), alpha = region:GetAlpha(), shown = region:IsShown() })
            end
        end
    end
    for _, region in ipairs(regions) do if region:IsObjectType("Texture") then region:SetAlpha(0); region:Hide() end end
    eb:DisableDrawLayer("BACKGROUND"); eb:DisableDrawLayer("BORDER")
    eb:SetAltArrowKeyMode(false)
    eb:SetParent(UIParent); eb:ClearAllPoints(); eb:SetPoint("BOTTOMLEFT", Messenger, "BOTTOMLEFT", 130, 0); eb:SetPoint("BOTTOMRIGHT", Messenger, "BOTTOMRIGHT", 0, 0); eb:SetHeight(30)
    eb:SetAlpha(1); eb:SetFrameStrata("DIALOG"); eb:SetFrameLevel(Messenger:GetFrameLevel() + 20)
    if not eb.midnightBg then
        local bg = eb:CreateTexture(nil, "BACKGROUND"); bg:SetColorTexture(INPUT_BG[1], INPUT_BG[2], INPUT_BG[3], 1); bg:SetAllPoints(); eb.midnightBg = bg
        local accentR, accentG, accentB = 0, 0.8, 1
        if currentChatTheme and currentChatTheme.accent then
            accentR, accentG, accentB = currentChatTheme.accent[1], currentChatTheme.accent[2], currentChatTheme.accent[3]
        end
        local border = eb:CreateTexture(nil, "OVERLAY"); border:SetColorTexture(accentR, accentG, accentB, 1); border:SetHeight(2); border:SetPoint("TOPLEFT", eb, "TOPLEFT"); border:SetPoint("TOPRIGHT", eb, "TOPRIGHT"); eb.midnightBorder = border
    end
    if not eb.midnightLabel then
        local lbl = eb:CreateFontString(nil, "OVERLAY", "GameFontNormal"); lbl:SetPoint("LEFT", eb, "LEFT", 10, 0); lbl:SetTextColor(0, 0.8, 1); lbl:SetText("[Say]"); eb.midnightLabel = lbl
    end
    eb:SetFontObject("ChatFontNormal")
    eb:SetAlpha(1)
    eb:EnableMouse(true)
    local enterScript = eb:GetScript("OnEnterPressed")
    if enterScript ~= MidnightUI_EditBoxOnEnterPressed then
        eb:SetScript("OnEnterPressed", MidnightUI_EditBoxOnEnterPressed)
        if SLASH_EMOTE_DEBUG then
            LogDebug("|cff66ccff[SlashTrace]|r Rebound EditBox OnEnterPressed to MidnightUI compatibility handler (was " .. tostring(enterScript) .. ")")
        end
    end
    local escapeScript = eb:GetScript("OnEscapePressed")
    if escapeScript ~= MidnightUI_EditBoxOnEscapePressed then
        eb:SetScript("OnEscapePressed", MidnightUI_EditBoxOnEscapePressed)
        if SLASH_EMOTE_DEBUG then
            LogDebug("|cff66ccff[SlashTrace]|r Rebound EditBox OnEscapePressed to MidnightUI compatibility handler (was " .. tostring(escapeScript) .. ")")
        end
    end
    local tabScript = eb:GetScript("OnTabPressed")
    if tabScript ~= MidnightUI_EditBoxOnTabPressed then
        eb:SetScript("OnTabPressed", MidnightUI_EditBoxOnTabPressed)
        if SLASH_EMOTE_DEBUG then
            LogDebug("|cff66ccff[SlashTrace]|r Rebound EditBox OnTabPressed to MidnightUI compatibility handler (was " .. tostring(tabScript) .. ")")
        end
    end

    -- Only show when actively typing; otherwise keep hidden in custom mode.
    local function EnsureCustomEditBoxVisibility()
        if IsDefaultChatEnabled() then return end
        local active = ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow()
        if active == eb then
            eb:Show()
            if eb.midnightLabel then eb.midnightLabel:Show() end
        else
            if (eb:GetText() or "") == "" then
                eb:Hide()
            end
            if eb.midnightLabel then eb.midnightLabel:Hide() end
        end
    end

    if not eb.midnightFocusHooked then
        eb:HookScript("OnEditFocusGained", function()
            if IsDefaultChatEnabled() then return end
            eb:Show()
            if eb.midnightLabel then eb.midnightLabel:Show() end
            SyncEditBoxToTab(eb)
            UpdateEditBoxLabel(eb)
        end)
        eb:HookScript("OnEditFocusLost", function()
            if IsDefaultChatEnabled() then return end
            if (eb:GetText() or "") == "" then
                eb:Hide()
            end
            if eb.midnightLabel then eb.midnightLabel:Hide() end
        end)
        eb.midnightFocusHooked = true
    end
    EnsureCustomEditBoxVisibility()
    local function ScheduleEditBoxLabelUpdate(self)
        if self.midnightLabelUpdateTimer then
            self.midnightLabelUpdateTimer:Cancel()
        end
        self.midnightLabelUpdateTimer = C_Timer.NewTimer(0.05, function()
            self.midnightLabelUpdateTimer = nil
            if self then UpdateEditBoxLabel(self) end
        end)
    end

    eb:HookScript("OnAttributeChanged", function(self, name, value)
        if name == "chatType" or name == "tellTarget" or name == "channelTarget" then
            DebugChannelSpaceState("OnAttributeChanged:" .. tostring(name), self)
            local chatType = self.GetAttribute and self:GetAttribute("chatType") or nil
            if ACTIVE_TAB == "Direct" or chatType == "WHISPER" or chatType == "BN_WHISPER" then
                DMTrace(string.format(
                    "EditBoxAttribute name=%s value=%s %s",
                    DMToString(name),
                    DMToString(value),
                    DMDescribeEditBoxState(self)
                ))
            end
            local currentText = self.GetText and self:GetText() or ""
            local slashMode = (type(currentText) == "string" and currentText:find("^/") ~= nil)
            if (name == "chatType" or name == "tellTarget") and not IsDefaultChatEnabled() then
                if slashMode and not IsWhisperSlashCommand(currentText) then
                    DMTrace(string.format("OnAttributeChanged skip sync name=%s text=%s", DMToString(name), DMCompactText(currentText, 40)))
                else
                    MidnightUI_SyncWhisperTarget(self, not suppressTabMode)
                end
            end
            UpdateEditBoxLabel(self)
        end
    end)
    eb:HookScript("OnTextChanged", function(self)
        self._midnightLastTextSnapshot = self.GetText and self:GetText() or ""
        DebugChannelSpaceState("OnTextChanged", self)
        ScheduleEditBoxLabelUpdate(self)
    end)
    -- Auto-expand chat when starting to type
    if not eb.midnightAutoExpandHooked then
        eb:HookScript("OnShow", function()
            if IsDefaultChatEnabled() then return end
            if isChatCollapsed and not isAnimating then
                ExpandMessengerFromCollapsed()
            end
        end)
        eb.midnightAutoExpandHooked = true
    end
    UpdateEditBoxLabel(eb)
end

hooksecurefunc("ChatEdit_UpdateHeader", function(eb)
    if eb == _G["ChatFrame1EditBox"] then
        if IsDefaultChatEnabled() then return end
        UpdateEditBoxLabel(eb)
    end
end)

-- Guard against nil tabs during Blizzard chat config refreshes
local function EnsureChatWindowIndexGuard()
    if _G.SetChatWindowIndex and not _G.MidnightUI_Orig_SetChatWindowIndex then
        _G.MidnightUI_Orig_SetChatWindowIndex = _G.SetChatWindowIndex
        _G.SetChatWindowIndex = function(index)
            local chatTab = _G["ChatFrame"..tostring(index).."Tab"]
            if not chatTab then return end
            return _G.MidnightUI_Orig_SetChatWindowIndex(index)
        end
    end
end

-- Guard Blizzard chat settings refresh from nil tab errors
local function EnsureChatConfigGuard()
    if _G.ChatConfig_UpdateChatSettings and not _G.MidnightUI_Orig_ChatConfig_UpdateChatSettings then
        _G.MidnightUI_Orig_ChatConfig_UpdateChatSettings = _G.ChatConfig_UpdateChatSettings
        _G.ChatConfig_UpdateChatSettings = function(...)
            local ok, err = pcall(_G.MidnightUI_Orig_ChatConfig_UpdateChatSettings, ...)
            if not ok then
                -- Swallow nil tab errors during chat config updates
                if type(err) == "string" then
                    if err:find("SetChatWindowIndex", 1, true)
                        or err:find("ChatConfigFrame.lua:2308", 1, true)
                        or err:find("chatTab", 1, true) then
                        return
                    end
                end
                return
            end
        end
    end
end

-- Apply immediately and again after Blizzard_ChatFrame loads
EnsureChatWindowIndexGuard()
EnsureChatConfigGuard()

local focusTrigger = CreateFrame("Button", "MessengerFocusTrigger", UIParent)
focusTrigger:SetScript("OnClick", function() 
    if IsDefaultChatEnabled() then return end
    if SLASH_EMOTE_DEBUG then LogDebug("|cff66ccff[SlashTrace]|r MessengerFocusTrigger clicked") end
    -- Auto-expand if collapsed
    if isChatCollapsed and not isAnimating then
        ExpandMessengerFromCollapsed()
    end
    if _G["ChatFrame1EditBox"] then
        DMTrace("EditBoxFocusTrigger before " .. DMDescribeEditBoxState(_G["ChatFrame1EditBox"]))
        SyncEditBoxToTab(_G["ChatFrame1EditBox"])
        _G["ChatFrame1EditBox"]:Show()
        _G["ChatFrame1EditBox"]:SetFocus()
        DMTrace("EditBoxFocusTrigger after " .. DMDescribeEditBoxState(_G["ChatFrame1EditBox"]))
    end 
end)
clickZone = CreateFrame("Button", nil, Messenger)
clickZone:SetPoint("BOTTOMLEFT", Messenger, "BOTTOMLEFT", 130, 0); clickZone:SetPoint("BOTTOMRIGHT", Messenger, "BOTTOMRIGHT", 0, 0); clickZone:SetHeight(30)
clickZone:SetScript("OnClick", function() 
    -- Auto-expand if collapsed
    if isChatCollapsed and not isAnimating then
        ExpandMessengerFromCollapsed()
    end
    if _G["ChatFrame1EditBox"] then
        DMTrace("EditBoxClickZone before " .. DMDescribeEditBoxState(_G["ChatFrame1EditBox"]))
        SyncEditBoxToTab(_G["ChatFrame1EditBox"])
        _G["ChatFrame1EditBox"]:Show()
        _G["ChatFrame1EditBox"]:SetFocus()
        DMTrace("EditBoxClickZone after " .. DMDescribeEditBoxState(_G["ChatFrame1EditBox"]))
    end 
end)
if _G["ChatFrame1EditBox"] then 
    _G["ChatFrame1EditBox"]:HookScript("OnShow", function() 
        local eb = _G["ChatFrame1EditBox"]
        if eb then
            if not IsDefaultChatEnabled() and eb._midnightResetOnShow then
                eb._midnightResetOnShow = nil
                if eb.SetText then eb:SetText("") end
                if eb.HighlightText then eb:HighlightText(0, 0) end
            end
            local enterScript = eb:GetScript("OnEnterPressed")
            local escapeScript = eb:GetScript("OnEscapePressed")
            local tabScript = eb:GetScript("OnTabPressed")
            if enterScript ~= MidnightUI_EditBoxOnEnterPressed then
                eb:SetScript("OnEnterPressed", MidnightUI_EditBoxOnEnterPressed)
            end
            if escapeScript ~= MidnightUI_EditBoxOnEscapePressed then
                eb:SetScript("OnEscapePressed", MidnightUI_EditBoxOnEscapePressed)
            end
            if tabScript ~= MidnightUI_EditBoxOnTabPressed then
                eb:SetScript("OnTabPressed", MidnightUI_EditBoxOnTabPressed)
            end
            DMTrace(string.format(
                "EditBoxBinding OnShow enter=%s escape=%s tab=%s reboundEnter=%s reboundEscape=%s reboundTab=%s",
                DMToString(tostring(enterScript)),
                DMToString(tostring(escapeScript)),
                DMToString(tostring(tabScript)),
                DMToString(enterScript ~= MidnightUI_EditBoxOnEnterPressed),
                DMToString(escapeScript ~= MidnightUI_EditBoxOnEscapePressed),
                DMToString(tabScript ~= MidnightUI_EditBoxOnTabPressed)
            ))
        end
        clickZone:Hide()
        -- Auto-expand chat when starting to type
        if isChatCollapsed and not isAnimating then
            ExpandMessengerFromCollapsed()
        end
        DMTrace(string.format("EditBoxVisibility OnShow collapsed=%s animating=%s clickZoneShown=%s %s", DMToString(isChatCollapsed), DMToString(isAnimating), DMToString(clickZone and clickZone.IsShown and clickZone:IsShown() or false), DMDescribeEditBoxState(_G["ChatFrame1EditBox"])))
        DMAutoDiag("dm_editbox_show", "dm_editbox_show phase=show " .. DMDescribeEditBoxState(_G["ChatFrame1EditBox"]), 0)
    end)
    _G["ChatFrame1EditBox"]:HookScript("OnHide", function()
        clickZone:Show()
        DMTrace(string.format("EditBoxVisibility OnHide collapsed=%s animating=%s clickZoneShown=%s %s", DMToString(isChatCollapsed), DMToString(isAnimating), DMToString(clickZone and clickZone.IsShown and clickZone:IsShown() or false), DMDescribeEditBoxState(_G["ChatFrame1EditBox"])))
    end)
end

RefreshInputLabel = function() if _G["ChatFrame1EditBox"] and _G["ChatFrame1EditBox"]:IsShown() then UpdateEditBoxLabel(_G["ChatFrame1EditBox"]) end end

local listener = CreateFrame("Frame")
listener:RegisterEvent("ADDON_LOADED")
listener:RegisterEvent("GROUP_ROSTER_UPDATE")
listener:RegisterEvent("PLAYER_GUILD_UPDATE")
listener:RegisterEvent("CHAT_MSG_SAY")
listener:RegisterEvent("CHAT_MSG_YELL")
listener:RegisterEvent("CHAT_MSG_TEXT_EMOTE")
listener:RegisterEvent("CHAT_MSG_GUILD")
listener:RegisterEvent("CHAT_MSG_GUILD_ACHIEVEMENT")
listener:RegisterEvent("GUILD_MOTD")
listener:RegisterEvent("CHAT_MSG_SYSTEM")
listener:RegisterEvent("CHAT_MSG_OFFICER")
listener:RegisterEvent("CHAT_MSG_WHISPER")
listener:RegisterEvent("CHAT_MSG_WHISPER_INFORM")
listener:RegisterEvent("CHAT_MSG_BN_WHISPER")
listener:RegisterEvent("CHAT_MSG_BN_WHISPER_INFORM")
listener:RegisterEvent("CHAT_MSG_MONSTER_SAY")
listener:RegisterEvent("CHAT_MSG_MONSTER_YELL")
listener:RegisterEvent("CHAT_MSG_MONSTER_EMOTE")
listener:RegisterEvent("CHAT_MSG_MONSTER_WHISPER")
listener:RegisterEvent("CHAT_MSG_RAID_BOSS_EMOTE")
listener:RegisterEvent("CHAT_MSG_RAID_BOSS_WHISPER")
listener:RegisterEvent("CHAT_MSG_PARTY")
listener:RegisterEvent("CHAT_MSG_PARTY_LEADER")
listener:RegisterEvent("CHAT_MSG_RAID")
listener:RegisterEvent("CHAT_MSG_RAID_LEADER")
listener:RegisterEvent("CHAT_MSG_INSTANCE_CHAT")
listener:RegisterEvent("CHAT_MSG_INSTANCE_CHAT_LEADER")
listener:RegisterEvent("CHAT_MSG_COMMUNITIES_CHANNEL")
listener:RegisterEvent("CHAT_MSG_CHANNEL")
listener:RegisterEvent("CHAT_MSG_LOOT")
listener:RegisterEvent("PLAYER_ENTERING_WORLD")
listener:RegisterEvent("ZONE_CHANGED_NEW_AREA")
listener:RegisterEvent("ZONE_CHANGED")
listener:RegisterEvent("PLAYER_UPDATE_RESTING")
listener:RegisterEvent("CHAT_MSG_CHANNEL_NOTICE")
listener:RegisterEvent("CHANNEL_UI_UPDATE")
listener:RegisterEvent("LUA_WARNING")

listener:SetScript("OnEvent", function(self, event, ...)
        if event == "ADDON_LOADED" then
            local addonName = ...
            if addonName == "MidnightUI" then
                InitDB()
                ScheduleSuperTrackedIconApply()
                HideDefaultChatArtAndCombatButtons()
                ApplyDefaultChatVisibility()
                if IsDefaultChatEnabled() then
                    ApplyDefaultChatInterfaceVisibility()
                    StartDefaultFadeAlphaGuard("ADDON_LOADED:MidnightUI")
                    ForceDefaultChatBackgroundAlpha("ADDON_LOADED:MidnightUI")
                    DebugDefaultReloadVisuals("ADDON_LOADED:MidnightUI:Immediate")
                    C_Timer.After(0.5, function()
                        if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("ADDON_LOADED:MidnightUI:0.5") end
                    end)
                    C_Timer.After(1.5, function()
                        if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("ADDON_LOADED:MidnightUI:1.5") end
                    end)
                end
            elseif addonName == "Blizzard_ChatFrame" then
                EnsureChatWindowIndexGuard()
                EnsureChatConfigGuard()
                HideDefaultChatArtAndCombatButtons()
                ApplyDefaultChatVisibility()
                if IsDefaultChatEnabled() then
                    ApplyDefaultChatInterfaceVisibility()
                    StartDefaultFadeAlphaGuard("ADDON_LOADED:Blizzard_ChatFrame")
                    ForceDefaultChatBackgroundAlpha("ADDON_LOADED:Blizzard_ChatFrame")
                    DebugDefaultReloadVisuals("ADDON_LOADED:Blizzard_ChatFrame:Immediate")
                    C_Timer.After(0.5, function()
                        if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("ADDON_LOADED:Blizzard_ChatFrame:0.5") end
                    end)
                    C_Timer.After(1.5, function()
                        if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("ADDON_LOADED:Blizzard_ChatFrame:1.5") end
                    end)
                end
            end

    elseif event == "PLAYER_ENTERING_WORLD" then
        -- [NEW] Suppress Tab Auto-Switching. 
        suppressTabMode = true
        
        -- Release the lock after 3 seconds
        C_Timer.After(3, function() 
            suppressTabMode = false 
        end)
        
        ScheduleSuperTrackedIconApply()
        HideDefaultChatArtAndCombatButtons()
        ApplyDefaultChatVisibility()
        if IsDefaultChatEnabled() then
            ApplyDefaultChatInterfaceVisibility()
            StartDefaultFadeAlphaGuard("PLAYER_ENTERING_WORLD")
            ForceDefaultChatBackgroundAlpha("PLAYER_ENTERING_WORLD")
            DebugDefaultReloadVisuals("PLAYER_ENTERING_WORLD:Immediate")
            C_Timer.After(0.5, function()
                if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("PLAYER_ENTERING_WORLD:0.5") end
            end)
            C_Timer.After(1.5, function()
                if IsDefaultChatEnabled() then DebugDefaultReloadVisuals("PLAYER_ENTERING_WORLD:1.5") end
            end)
        end
        
    local function RefreshWorldChannels()
        local isInMajorCity = IsInMajorCityAdvanced("RefreshWorldChannels")
        local newChannelStaleState = not isInMajorCity
        local currentZone = GetRealZoneText() or ""
        areChannelsStale = newChannelStaleState
            
            -- Hide worldMenu if visible to force refresh
            if worldMenu and worldMenu:IsShown() then
                worldMenu:Hide()
                C_Timer.After(0.05, function()
                    local worldBtn = TabButtons["World"]
                    if worldBtn and MouseIsOver(worldBtn) then
                        if worldBtn:GetScript("OnEnter") then
                            worldBtn:GetScript("OnEnter")(worldBtn)
                        end
                    end
                end)
            end
            
        RefreshInputLabel()
        if UpdateWorldHeader then UpdateWorldHeader() end
        if ACTIVE_TAB == "World" then RefreshDisplay() end
    end

    C_Timer.After(0.5, RefreshWorldChannels)
    C_Timer.After(2.0, RefreshWorldChannels)
    C_Timer.After(5.0, RefreshWorldChannels)

    -- Recheck city state after login/reload because zone/subzone can populate late.
    -- This prevents Trade/Services from staying hidden when logging in directly into a city.
    local recheckAttempts = 0
    local recheckTicker
    recheckTicker = C_Timer.NewTicker(1.0, function()
        recheckAttempts = recheckAttempts + 1
        local isInMajorCity = IsInMajorCityAdvanced("RecheckTicker")
        if isInMajorCity and areChannelsStale then
            areChannelsStale = false
            RefreshInputLabel()
            if UpdateWorldHeader then UpdateWorldHeader() end
            if ACTIVE_TAB == "World" then RefreshDisplay() end
        end
        if isInMajorCity or recheckAttempts >= 20 then
            if recheckTicker then recheckTicker:Cancel() end
        end
    end)

        if not _G.MessengerSlashTrigger then
            local slashFrame = CreateFrame("Button", "MessengerSlashTrigger", UIParent)
            slashFrame:SetScript("OnClick", function() 
                if SLASH_EMOTE_DEBUG then LogDebug("|cff66ccff[SlashTrace]|r MessengerSlashTrigger clicked") end
                -- Auto-expand if collapsed
                if isChatCollapsed and not isAnimating then
                    ExpandMessengerFromCollapsed()
                end
                local eb = _G["ChatFrame1EditBox"]
                if eb then
                    SyncEditBoxToTab(eb)
                    eb:Show()
                    eb:SetFocus()
                    C_Timer.After(0, function()
                        if not eb then return end
                        local text = eb:GetText() or ""
                        if text == "" then
                            eb:SetText("/")
                            if eb.SetCursorPosition then eb:SetCursorPosition(2) end
                        end
                    end)
                end
            end)
        end

        if not InCombatLockdown() then
            SetOverrideBindingClick(Messenger, true, "/", "MessengerSlashTrigger")
        else
            self:RegisterEvent("PLAYER_REGEN_ENABLED")
        end

        StyleDefaultEditBox()
        
        if ChatFrame_SendTell then
            hooksecurefunc("ChatFrame_SendTell", function(name)
                if name then
                    local bnetID = ResolveBNetIDFromTarget(name)
                    local inferredChatType = (bnetID or IsBNetAnonToken(name)) and "BN_WHISPER" or "WHISPER"
                    local dmKey, displayName, tellTarget, isBNet, resolvedBnetID = BuildDirectIdentityFromChatTarget(inferredChatType, name)
                    ACTIVE_TAB = "Direct"
                    if dmKey then
                        local _, registeredKey = RegisterDirectContact(dmKey, displayName, tellTarget, isBNet, resolvedBnetID)
                        if type(registeredKey) == "string" and registeredKey ~= "" then
                            dmKey = registeredKey
                        end
                        ACTIVE_DM_FILTER = dmKey
                    end
                    if TabButtons["Direct"] then TabButtons["Direct"]:Click() end
                    UpdateTabLayout()
                    RefreshDisplay()
                end
            end)
        end
        if GeneralDockManager then GeneralDockManager:Hide() end

    elseif event == "PLAYER_REGEN_ENABLED" then
        if not InCombatLockdown() then
            SetOverrideBindingClick(Messenger, true, "/", "MessengerSlashTrigger")
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end

    elseif event == "GROUP_ROSTER_UPDATE" then
        PruneGroupHistory()
        if not IsInGroup() and ACTIVE_TAB == "Group" then 
            if TabButtons["Local"] then TabButtons["Local"]:Click() end 
        end
        UpdateTabLayout()
        if not IsInGroup() then
            local function RefreshWorldUI()
                RefreshInputLabel()
                if UpdateWorldHeader then UpdateWorldHeader() end
                if ACTIVE_TAB == "World" then RefreshDisplay() end
            end
            C_Timer.After(0.5, RefreshWorldUI)
            C_Timer.After(2.0, RefreshWorldUI)
            C_Timer.After(5.0, RefreshWorldUI)
        end

    elseif event == "PLAYER_GUILD_UPDATE" then 
        UpdateTabLayout()

    elseif event == "PLAYER_UPDATE_RESTING" or event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" then
        local isInMajorCity = IsInMajorCityAdvanced(event)
        local currentZone = GetRealZoneText() or ""
        
        -- Update channel stale state based on location
        local newChannelStaleState = not isInMajorCity
        
        if newChannelStaleState ~= areChannelsStale then
            areChannelsStale = newChannelStaleState
            -- Hide worldMenu if visible to force refresh
            if worldMenu and worldMenu:IsShown() then
                worldMenu:Hide()
                C_Timer.After(0.05, function()
                    local worldBtn = TabButtons["World"]
                    if worldBtn and MouseIsOver(worldBtn) then
                        if worldBtn:GetScript("OnEnter") then
                            worldBtn:GetScript("OnEnter")(worldBtn)
                        end
                    end
                end)
            end
            
            -- GUARD: Prevent infinite loop by not calling these during ZONE_CHANGED events
            if event == "PLAYER_UPDATE_RESTING" then
                RefreshInputLabel()
                if UpdateWorldHeader then UpdateWorldHeader() end
                if ACTIVE_TAB == "World" then RefreshDisplay() end
            else
                -- For ZONE_CHANGED events, defer the update slightly to break recursion
                C_Timer.After(0.1, function()
                    RefreshInputLabel()
                    if UpdateWorldHeader then UpdateWorldHeader() end
                    if ACTIVE_TAB == "World" then RefreshDisplay() end
                end)
            end
        end
        
    elseif event == "CHAT_MSG_CHANNEL_NOTICE" then
        C_Timer.After(0.1, function()
            RefreshInputLabel()
            if UpdateWorldHeader then UpdateWorldHeader() end
            if ACTIVE_TAB == "World" then RefreshDisplay() end
        end)

    elseif event == "CHANNEL_UI_UPDATE" then
        -- Channel list is ready; refresh world header (Trade/Services visibility)
        C_Timer.After(0.1, function()
            RefreshInputLabel()
            if UpdateWorldHeader then UpdateWorldHeader() end
            if ACTIVE_TAB == "World" then RefreshDisplay() end
        end)

    elseif event == "LUA_WARNING" then
        local _, message = ...
        if not message or message == "" then return end
        if _G.MidnightUI_Debug then _G.MidnightUI_Debug("|cffff0000[Lua Warning]|r " .. tostring(message)) end

    else
        OnChatEvent(self, event, ...) 
    end
end)

C_Timer.After(1, function()
    if not IsDefaultChatEnabled() then
        if ACTIVE_TAB == "CombatLog" then EmbedBlizzardCombatLog(true) else EmbedBlizzardCombatLog(false) end
    end
    StyleDefaultEditBox()
    HideDefaultChatArtAndCombatButtons()
    ApplyDefaultChatVisibility()
    if IsDefaultChatEnabled() then
        RestoreCombatLogTabDefaultMode("StartupTimer", true)
        UpdateDefaultModeCombatUI("StartupTimer")
    end
end)

-- =========================================================================
-- Function to hide the Social/Quick Join toast button
local function HideSocialIcon()
    local socialButton = QuickJoinToastButton
    if socialButton then
        socialButton:Hide()
    end
end

-- Call on PLAYER_ENTERING_WORLD to ensure UI is loaded
local socialFrame = CreateFrame("Frame")
socialFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
socialFrame:SetScript("OnEvent", function(self, event)
    C_Timer.After(0.5, function()
        HideSocialIcon()
    end)
end)

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function StyleMessengerOverlayButton(button)
    if not button then return end
    if _G.MidnightUI_StyleButton then
        _G.MidnightUI_StyleButton(button)
        return
    end
    if _G.MidnightUI_Settings and _G.MidnightUI_Settings.StyleSettingsButton then
        _G.MidnightUI_Settings.StyleSettingsButton(button)
    end
end

local function BuildMessengerOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
  local s = (MidnightUISettings and MidnightUISettings.Messenger) or {}
  local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
  b:Header("Settings")
  b:Dropdown("Chat Style", {"Default", "Class Color", "Faithful", "Glass", "Minimal"}, s.style or "Default", function(v)
      MidnightUISettings.Messenger.style = v
      if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
          _G.MidnightUI_Settings.ApplyMessengerSettings()
      end
  end)
  local showDefault = (s.showDefaultChatInterface == true)
  local btn = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    btn:SetSize(220, 26)
    btn:SetPoint("TOPLEFT", 0, b.y)
    if showDefault then
        btn:SetText("Switch to Messenger (Reload)")
    else
        btn:SetText("Switch to Default (Reload)")
    end
    btn:SetScript("OnClick", function()
        if not MidnightUISettings.Messenger then MidnightUISettings.Messenger = {} end
        MidnightUISettings.Messenger.showDefaultChatInterface = not showDefault
        ReloadUI()
    end)
    StyleMessengerOverlayButton(btn)
    if _G.MidnightUI_AttachOverlayTooltip then
        _G.MidnightUI_AttachOverlayTooltip(btn, showDefault and "Switch to Messenger" or "Switch to Default")
    end
    b.y = b.y - 38
    b:Checkbox("Show Timestamps", s.showTimestamp ~= false, function(v)
        MidnightUISettings.Messenger.showTimestamp = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
    end)
    b:Checkbox("Opt Out of Global Tab", s.hideGlobal == true, function(v)
        MidnightUISettings.Messenger.hideGlobal = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
    end)
    b:Checkbox("Opt Out of Login States", s.hideLoginStates == true, function(v)
        MidnightUISettings.Messenger.hideLoginStates = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
    end)
    b:Slider("Background Opacity", 0.1, 1.0, 0.05, s.alpha or 0.85, function(v)
        MidnightUISettings.Messenger.alpha = v
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("Messenger")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Width", 300, 1000, 10, s.width or 650, function(v)
        MidnightUISettings.Messenger.width = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("Messenger")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Height", 200, 800, 10, s.height or 400, function(v)
        MidnightUISettings.Messenger.height = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("Messenger")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Scale %", 50, 200, 5, (s.scale or 1.0) * 100, function(v)
        MidnightUISettings.Messenger.scale = math.floor(v) / 100
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
        if _G.MidnightUI_GetOverlayHandle then
            local o = _G.MidnightUI_GetOverlayHandle("Messenger")
            if o and o.SetAllPoints then o:SetAllPoints() end
        end
    end)
    b:Slider("Chat Font Size", 8, 24, 1, GetMessengerFontSize(), function(v)
        MidnightUISettings.Messenger.fontSize = math.floor(v)
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
    end)
    b:Slider("Tab Font Size", 8, 18, 1, GetMessengerTabFontSize(), function(v)
        MidnightUISettings.Messenger.tabFontSize = math.floor(v)
        UpdateTabLayout()
        if type(UpdateWorldHeader) == "function" then pcall(UpdateWorldHeader) end
        if type(UpdateDMHeader) == "function" then pcall(UpdateDMHeader) end
    end)
    b:Slider("Tab Height Spacing", 28, 64, 1, GetMessengerMainTabSpacing(), function(v)
        MidnightUISettings.Messenger.mainTabSpacing = math.floor(v)
        UpdateTabLayout()
        if _G.MidnightUI_Settings and _G.MidnightUI_Settings.ApplyMessengerSettings then
            _G.MidnightUI_Settings.ApplyMessengerSettings()
        end
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("Messenger", {
        title = "Messenger",
        build = BuildMessengerOverlaySettings,
    })
end



