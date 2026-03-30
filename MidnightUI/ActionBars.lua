-- =============================================================================
-- FILE PURPOSE:     Full action bar system — styles Blizzard's action buttons and
--                   hosts them inside draggable overlay containers. Manages bars 1–8
--                   plus pet and stance bars with per-bar scale/row/spacing settings.
-- LOAD ORDER:       Loads after Settings.lua. ActionBarManager handles ADDON_LOADED
--                   to wire in settings after PLAYER_LOGIN.
-- DEFINES:          ActionBarManager (event frame), actionBarContainers[], actionBarBoxes[],
--                   petBarContainer, stanceBarContainer, actionBarButtons[].
--                   Globals: MidnightUI_ApplyActionBarSettings().
-- READS:            MidnightUI_GetActionBarSettings() → MidnightUISettings.ActionBars.*,
--                   MidnightUISettings.PetBar.*, MidnightUISettings.StanceBar.*,
--                   MidnightUISettings.Messenger.locked (for overlay unlock state).
-- WRITES:           MidnightUISettings.[PetBar|StanceBar|ActionBars[n]].position on drag stop.
-- DEPENDS ON:       MidnightUI_Core.GetClassColor (for "Class Color" style bars),
--                   MidnightUI_GetActionBarSettings (Settings.lua),
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes control widgets),
--                   Settings_Keybinds.lua (keybind mode needs bar containers).
-- KEY FLOWS:
--   ADDON_LOADED → ApplyAllActionBars() → per-bar styling + container layout
--   PLAYER_REGEN_ENABLED → FlushProtectedLayouts() (deferred pet/stance reparent)
--   Drag start/stop on overlay → saves position to MidnightUISettings
-- GOTCHAS:
--   All pet/stance host reparenting must be deferred out of combat via
--   QueueProtectedLayout/PLAYER_REGEN_ENABLED because these are SecureFrames.
--   "Global Style" overrides per-bar style when enabled (Disabled = per-bar wins).
--   BAR_BUTTON_MAP maps bar index [1-8] to WoW's native ActionButton prefix names.
-- NAVIGATION:
--   BAR_BUTTON_MAP{}          — bar→button-prefix map (line ~41)
--   GetConfig()               — settings accessor with safe fallback (line ~68)
--   QueueProtectedLayout()    — combat-deferred callback queue (line ~165)
--   EnsureOverlayContainer()  — shared drag-overlay builder for pet/stance (line ~209)
--   ApplyAllActionBars()      — main entry point called on ADDON_LOADED
-- =============================================================================

local ADDON_NAME = "MidnightUI"

local _G = _G
local C_Timer = C_Timer
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local UnitClass = UnitClass
local GetNumShapeshiftForms = GetNumShapeshiftForms
local UIParent = UIParent
local math_ceil = math.ceil
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local ipairs = ipairs
local pairs = pairs
local type = type

local ActionBarManager = CreateFrame("Frame")

-- Container for each action bar
local actionBarContainers = {}
local actionBarBoxes = {}
local petBarContainer = nil
local petBarBoxes = {}
local stanceBarContainer = nil
local stanceBarBoxes = {}

local CURRENT_HOVER_BUTTON = nil

local actionBarButtons = {}

-- Mapping of bar numbers to WoW action button prefixes
local BAR_BUTTON_MAP = {
    [1] = "ActionButton",           -- Main bar (1-12)
    [2] = "MultiBarBottomLeftButton", -- Bar 2 (1-12)
    [3] = "MultiBarBottomRightButton", -- Bar 3 (1-12)
    [4] = "MultiBarRightButton",    -- Bar 4 (1-12)
    [5] = "MultiBarLeftButton",     -- Bar 5 (1-12)
    [6] = "MultiBar5Button",        -- Bar 6 (1-12)
    [7] = "MultiBar6Button",        -- Bar 7 (1-12)
    [8] = "MultiBar7Button",        -- Bar 8 (1-12)
}

-- Default positions for each bar
local DEFAULT_POSITIONS = {
    [1] = { "BOTTOM", "UIParent", "BOTTOM", 0, 20 },
    [2] = { "BOTTOM", "UIParent", "BOTTOM", 0, 70 },
    [3] = { "BOTTOM", "UIParent", "BOTTOM", 0, 120 },
    [4] = { "BOTTOM", "UIParent", "BOTTOM", 0, 170 },
    [5] = { "BOTTOM", "UIParent", "BOTTOM", 0, 220 },
    [6] = { "BOTTOM", "UIParent", "BOTTOM", 0, 270 },
    [7] = { "BOTTOM", "UIParent", "BOTTOM", 0, 320 },
    [8] = { "BOTTOM", "UIParent", "BOTTOM", 0, 370 },
}

-- =========================================================================
--  GET CONFIGURATION FROM SETTINGS
-- =========================================================================

local function GetConfig()
    if MidnightUI_GetActionBarSettings then
        return MidnightUI_GetActionBarSettings()
    end
    -- Return defaults if settings not loaded yet
    return {
        bar1 = { enabled = true, rows = 1, iconsPerRow = 12, scale = 100, spacing = 6, style = "Class Color" },
        boxColor = {0.08, 0.12, 0.22, 0.92},
        borderColor = {0.25, 0.45, 0.75, 0.85},
        hotkeyColor = {0.85, 0.90, 1.00},
        highlightColor = {0.45, 0.75, 1.00, 0.25},
        style = "Class Color",
        globalStyle = "Disabled",
    }
end

-- =========================================================================
--  SHARED HELPERS
-- =========================================================================

local function EnsureBarSettings(settingsKey, defaults)
    if not MidnightUISettings then return nil end
    if not MidnightUISettings[settingsKey] then MidnightUISettings[settingsKey] = {} end
    local s = MidnightUISettings[settingsKey]
    for k, v in pairs(defaults) do
        if s[k] == nil then s[k] = v end
    end
    return s
end

local function EnsurePetBarSettings()
    return EnsureBarSettings("PetBar", {
        enabled = true, scale = 100, alpha = 1.0,
        buttonSize = 40, spacing = 6, buttonsPerRow = 10,
    })
end

local function EnsureStanceBarSettings()
    return EnsureBarSettings("StanceBar", {
        enabled = true, scale = 100, alpha = 1.0,
        buttonSize = 32, spacing = 4, buttonsPerRow = 3,
    })
end

-- Check if a button slot has an action assigned
local function SlotHasAction(button)
    return button and button.action and HasAction(button.action)
end

-- Check if a button is an empty slot in Hidden style (should be fully invisible)
local function IsHiddenEmptySlot(box, button)
    return box and box._muiStyle == "Hidden" and not SlotHasAction(button)
end

-- =========================================================================
--  CONSISTENT CLASS COLORS (MIDNIGHTUI EXACT PALETTE)
-- =========================================================================

local PET_DEFAULT_POSITION = { "BOTTOM", "UIParent", "BOTTOM", 0, 140 }
local STANCE_DEFAULT_POSITION = { "BOTTOM", "UIParent", "BOTTOM", -160, 120 }
local DEFAULT_CLASS_COLOR = {0.5, 0.5, 0.5}
local pendingProtectedLayouts = {}
local pendingProtectedLayoutCount = 0

local function IsInCombat()
    return InCombatLockdown and InCombatLockdown()
end

local function ResolveRelativeFrame(frameKey)
    if type(frameKey) == "string" then
        return _G[frameKey] or UIParent
    end
    return frameKey or UIParent
end

local VALID_ANCHORS = {
    TOPLEFT = true, TOP = true, TOPRIGHT = true,
    LEFT = true, CENTER = true, RIGHT = true,
    BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true,
}

local function ApplySavedPoint(frame, position, fallback)
    if not frame then return end
    frame:ClearAllPoints()
    if position and VALID_ANCHORS[position[1]] and VALID_ANCHORS[position[2]] then
        frame:SetPoint(position[1], UIParent, position[2], position[3] or 0, position[4] or 0)
        return
    end
    frame:SetPoint(fallback[1], ResolveRelativeFrame(fallback[2]), fallback[3], fallback[4], fallback[5])
end

local function SaveContainerPosition(frame, settings)
    if not frame or not settings then return end
    local point, _, relativePoint, xOfs, yOfs = frame:GetPoint()
    settings.position = { point, relativePoint, xOfs, yOfs }
end

local function QueueProtectedLayout(key, callback)
    if not key or not callback then return end
    if not pendingProtectedLayouts[key] then
        pendingProtectedLayoutCount = pendingProtectedLayoutCount + 1
    end
    pendingProtectedLayouts[key] = callback
    ActionBarManager:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local function FlushProtectedLayouts()
    if IsInCombat() then return end
    for key, callback in pairs(pendingProtectedLayouts) do
        pendingProtectedLayouts[key] = nil
        pendingProtectedLayoutCount = pendingProtectedLayoutCount - 1
        callback()
    end
    if pendingProtectedLayoutCount <= 0 then
        pendingProtectedLayoutCount = 0
        ActionBarManager:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end
end

local function PlayerHasPetClass()
    local _, classFilename = UnitClass("player")
    return classFilename == "HUNTER" or classFilename == "WARLOCK"
end

local function PlayerHasStanceClass()
    if GetNumShapeshiftForms and GetNumShapeshiftForms() > 0 then return true end
    local _, classFilename = UnitClass("player")
    return classFilename == "DRUID" or classFilename == "WARRIOR" or classFilename == "ROGUE" or classFilename == "SHAMAN" or classFilename == "DEATHKNIGHT"
end

local function OverlaysUnlocked()
    return MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false
end

local function GetPlayerClassColor()
    if _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColor then
        return _G.MidnightUI_Core.GetClassColor("player")
    end
    return DEFAULT_CLASS_COLOR[1], DEFAULT_CLASS_COLOR[2], DEFAULT_CLASS_COLOR[3]
end

local function EnsureOverlayContainer(container, frameName, settings, defaultPosition, overlayKey, labelText)
    if container then
        return container
    end

    container = CreateFrame("Frame", frameName, UIParent)
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:SetAlpha(settings.alpha or 1.0)
    container:SetScale((settings.scale or 100) / 100)
    ApplySavedPoint(container, settings.position, defaultPosition)

    local overlay = CreateFrame("Frame", nil, container, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("DIALOG")
    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
    })
    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
    if _G.MidnightUI_StyleOverlay then
        _G.MidnightUI_StyleOverlay(overlay, nil, nil, "bars")
    end

    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function()
        if not IsInCombat() then
            container:StartMoving()
        end
    end)
    overlay:SetScript("OnDragStop", function()
        container:StopMovingOrSizing()
        SaveContainerPosition(container, settings)
    end)

    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, overlayKey)
    end

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER")
    label:SetText(labelText)
    label:SetTextColor(1, 1, 1)

    container.dragOverlay = overlay
    return container
end

local function UpdateOverlayContainer(container, width, height, settings)
    if not container then return end
    if InCombatLockdown() then return end
    container:SetSize(width, height)
    container:SetAlpha(settings.alpha or 1.0)
    container:SetScale((settings.scale or 100) / 100)
end

local function SetOverlayContainerVisibility(container, settings, isVisible)
    if not container then return end
    local alpha = 0
    if isVisible then
        alpha = (settings and settings.alpha) or 1.0
    end
    container:SetAlpha(alpha)
    if container.dragOverlay and not isVisible then
        container.dragOverlay:Hide()
    end
end

local function ApplyProtectedHostLayout(host, container, width, height, queueKey)
    if not host or not container then return false end
    if IsInCombat() then
        QueueProtectedLayout(queueKey, function()
            ApplyProtectedHostLayout(host, container, width, height, queueKey)
        end)
        return false
    end
    if host:GetParent() ~= container then
        host:SetParent(container)
    end
    host:ClearAllPoints()
    host:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    host:SetSize(width, height)
    return true
end

local function GetShortBindingText(key)
    if not key or key == "" then return "" end
    local text = GetBindingText and GetBindingText(key, "KEY_") or key
    if text and text ~= "" then return text end
    return key
end

function MidnightUI_RefreshPetBarHotkeys()
    for i = 1, 10 do
        local btn = _G["PetActionButton"..i]
        if btn then
            local key = GetBindingKey and GetBindingKey("BONUSACTIONBUTTON"..i)
            local display = GetShortBindingText(key)
            if btn.StyledHotkey then
                btn.StyledHotkey:SetText(display)
                btn.StyledHotkey:SetAlpha(1)
                btn.StyledHotkey:Show()
            end
            if btn.HotKey then
                btn.HotKey:SetText("")
                btn.HotKey:SetAlpha(0)
            end
        end
    end
end

local function FormatHotkeyDisplay(keybind)
    if not keybind then return "" end
    local modifiers = ""
    local mainKey = keybind

    if mainKey:find("SHIFT%-") then modifiers = modifiers .. "s"; mainKey = mainKey:gsub("SHIFT%-", "") end
    if mainKey:find("CTRL%-") then modifiers = modifiers .. "c"; mainKey = mainKey:gsub("CTRL%-", "") end
    if mainKey:find("ALT%-") then modifiers = modifiers .. "a"; mainKey = mainKey:gsub("ALT%-", "") end

    local keyAbbreviations = {
        ["MOUSEWHEELUP"] = "W↑", ["MOUSEWHEELDOWN"] = "W↓",
        ["NUMPAD0"] = "n0", ["NUMPAD1"] = "n1", ["NUMPAD2"] = "n2", ["NUMPAD3"] = "n3",
        ["NUMPAD4"] = "n4", ["NUMPAD5"] = "n5", ["NUMPAD6"] = "n6", ["NUMPAD7"] = "n7",
        ["NUMPAD8"] = "n8", ["NUMPAD9"] = "n9",
        ["NUMPADDECIMAL"] = "n.", ["NUMPADPLUS"] = "n+", ["NUMPADMINUS"] = "n-",
        ["NUMPADMULTIPLY"] = "n*", ["NUMPADDIVIDE"] = "n/",
        ["SPACEBAR"] = "Sp", ["BACKSPACE"] = "Bs", ["ESCAPE"] = "Es",
        ["DELETE"] = "De", ["INSERT"] = "In", ["HOME"] = "Hm", ["END"] = "En",
        ["PAGEUP"] = "PU", ["PAGEDOWN"] = "PD", ["CAPSLOCK"] = "Ca",
        ["PRINTSCREEN"] = "Pr", ["SCROLLLOCK"] = "SL", ["PAUSE"] = "Pa",
        ["TAB"] = "Tb", ["ENTER"] = "↵",
    }

    if keyAbbreviations[mainKey] then
        mainKey = keyAbbreviations[mainKey]
    elseif mainKey:match("^BUTTON(%d+)$") then
        mainKey = "M" .. mainKey:match("^BUTTON(%d+)$")
    elseif #mainKey > 3 and not mainKey:match("^F%d+$") then
        mainKey = mainKey:sub(1, 2)
    end

    local display = modifiers .. mainKey
    if #display > 5 then display = display:sub(1, 4) .. "…" end
    return display
end

local ResolveBindingCommandForButton  -- forward declaration

local function RefreshAllHotkeyText()
    for barNum = 1, 8 do
        local prefix = BAR_BUTTON_MAP[barNum]
        if prefix and actionBarButtons[barNum] then
            local boxes = actionBarBoxes[barNum]
            for i = 1, 12 do
                local button = actionBarButtons[barNum][i]
                if button and button.StyledHotkey then
                    local box = boxes and boxes[i]
                    if IsHiddenEmptySlot(box, button) then
                        button.StyledHotkey:SetText("")
                        button.StyledHotkey:Hide()
                        if button.HotKey then button.HotKey:SetAlpha(0); button.HotKey:SetText("") end
                    else
                        button.StyledHotkey:Show()
                        local bindingCommand = ResolveBindingCommandForButton(button, barNum, i)
                        if bindingCommand then
                            local keybind = GetBindingKey(bindingCommand)
                            button.StyledHotkey:SetText(FormatHotkeyDisplay(keybind))
                        else
                            button.StyledHotkey:SetText("")
                        end
                    end
                end
            end
        end
    end
    MidnightUI_RefreshPetBarHotkeys()
end

local function GetActionBarTheme(config, barConfig)
    config = config or GetConfig()
    local gs = config.globalStyle
    if gs == "Per Bar" then gs = "Disabled" end
    local style = (gs and gs ~= "Disabled")
        and gs
        or (barConfig and barConfig.style)
        or config.style
        or "Class Color"

    if style == "Faithful" then
        return {
            style = style,
            bg = {0.65, 0.58, 0.45, 0.85},
            outerBorder = {0.48, 0.40, 0.28, 1},
            mainBorder = {0.78, 0.69, 0.52, 0.9},
            topShineStart = {1.00, 0.96, 0.86, 0.18},
            topShineEnd = {1.00, 0.96, 0.86, 0},
            edgeGlow = {0.92, 0.82, 0.62, 0},
            highlight = {0.95, 0.86, 0.70, 0.20},
            vignette = {0, 0, 0, 0.4},
            vignetteTop = {0, 0, 0, 0.72},
            vignetteBottom = {0, 0, 0, 0.05},
            innerHighlight = {1, 1, 1, 0.05},
            shadow = {0, 0, 0, 0.9},
        }
    elseif style == "Glass" then
        return {
            style = style,
            bg = {0, 0, 0, 0},
            outerBorder = {0.05, 0.06, 0.10, 0.12},
            mainBorder = {0.05, 0.06, 0.10, 0.18},
            topShineStart = {1, 1, 1, 0},
            topShineEnd = {1, 1, 1, 0},
            edgeGlow = {0.70, 0.85, 1.00, 0},
            highlight = {0.05, 0.06, 0.10, 0.06},
            vignette = {0, 0, 0, 0},
            vignetteTop = {0, 0, 0, 0},
            vignetteBottom = {0, 0, 0, 0},
            innerHighlight = {1, 1, 1, 0},
            shadow = {0, 0, 0, 0},
        }
    elseif style == "Hidden" then
        return {
            style = style,
            bg = {0, 0, 0, 0},
            outerBorder = {0, 0, 0, 0},
            mainBorder = {0, 0, 0, 0},
            topShineStart = {0, 0, 0, 0},
            topShineEnd = {0, 0, 0, 0},
            edgeGlow = {0, 0, 0, 0},
            highlight = {0.45, 0.75, 1.00, 0.25},
            vignette = {0, 0, 0, 0},
            vignetteTop = {0, 0, 0, 0},
            vignetteBottom = {0, 0, 0, 0},
            innerHighlight = {0, 0, 0, 0},
            shadow = {0, 0, 0, 0},
        }
    end

    local cR, cG, cB = GetPlayerClassColor()
    return {
        style = "Class Color",
        bg = {cR * 0.15, cG * 0.15, cB * 0.15, 0.85},
        outerBorder = {cR * 0.3, cG * 0.3, cB * 0.3, 1},
        mainBorder = {cR, cG, cB, 0.9},
        topShineStart = {cR, cG, cB, 0.16},
        topShineEnd = {cR, cG, cB, 0},
        edgeGlow = {cR, cG, cB, 0},
        highlight = {cR, cG, cB, 0.25},
        vignette = {0, 0, 0, 0.4},
        vignetteTop = {0, 0, 0, 0.72},
        vignetteBottom = {0, 0, 0, 0.05},
        innerHighlight = {1, 1, 1, 0.05},
        shadow = {0, 0, 0, 0.9},
    }
end

-- =========================================================================
--  HIDE BLIZZARD DEFAULT ART (FIXED HIGHLIGHTS)
-- =========================================================================

local function HideBlizzardActionBarArt()
    if InCombatLockdown and InCombatLockdown() then
        return
    end
    -- 1. Hide specific named frames on the MainMenuBar
    if MainMenuBar then
        if MainMenuBar.EndCaps then MainMenuBar.EndCaps:SetAlpha(0) end
        if MainMenuBar.BorderArt then MainMenuBar.BorderArt:SetAlpha(0) end
        if MainMenuBar.Background then MainMenuBar.Background:SetAlpha(0) end
        MainMenuBar:EnableMouse(false)
        MainMenuBar:SetFrameStrata("BACKGROUND")
        MainMenuBar:SetAlpha(1)
    end
    if MainMenuBarArtFrame then
        MainMenuBarArtFrame:EnableMouse(false)
        MainMenuBarArtFrame:SetFrameStrata("BACKGROUND")
        MainMenuBarArtFrame:SetAlpha(1)
    end
    local function MuteFrame(f, keepAlpha)
        if not f then return end
        if f.EnableMouse then f:EnableMouse(false) end
        if f.SetFrameStrata then f:SetFrameStrata("BACKGROUND") end
        if f.SetAlpha and not keepAlpha then f:SetAlpha(0) end
    end

    MuteFrame(MultiBarBottomLeft, true)
    MuteFrame(MultiBarBottomRight, true)
    MuteFrame(MultiBarRight, true)
    MuteFrame(MultiBarLeft, true)
    MuteFrame(MultiBar5, true)
    MuteFrame(MultiBar6, true)
    MuteFrame(MultiBar7, true)
    MuteFrame(ActionBar1, true)
    MuteFrame(ActionBar2, true)
    MuteFrame(ActionBar3, true)
    MuteFrame(ActionBar4, true)
    MuteFrame(ActionBar5, true)
    MuteFrame(ActionBar6, true)
    MuteFrame(ActionBar7, true)
    MuteFrame(ActionBar8, true)
    MuteFrame(ActionBarController, true)
    MuteFrame(ActionBarButtonEventsFrame, true)
    MuteFrame(MainActionBar, true)
    MuteFrame(MainActionBarArtFrame, true)
    MuteFrame(MainActionBarButtonContainer, true)
    MuteFrame(MainActionBarButtonContainer0, true)
    MuteFrame(MainActionBarButtonContainer1, true)
    MuteFrame(MainActionBarButtonContainer2, true)
    MuteFrame(MainActionBarButtonContainer3, true)
    MuteFrame(MainActionBarButtonContainer4, true)
    MuteFrame(MainActionBarButtonContainer5, true)
    MuteFrame(MainActionBarButtonContainer6, true)
    MuteFrame(MainActionBarButtonContainer7, true)
    MuteFrame(MainActionBarButtonContainer8, true)
    if MainActionBar and MainActionBar.Selection then
        MuteFrame(MainActionBar.Selection)
        if MainActionBar.Selection.MouseOverHighlight then MuteFrame(MainActionBar.Selection.MouseOverHighlight) end
    end
    MuteFrame(MicroMenuContainer)
    MuteFrame(MainMenuBarVehicleLeaveButton)
    MuteFrame(SpellbookMicroButton)
    MuteFrame(CharacterMicroButton)
    MuteFrame(TalentMicroButton)
    MuteFrame(AchievementMicroButton)
    MuteFrame(QuestLogMicroButton)
    MuteFrame(GuildMicroButton)
    MuteFrame(LFDMicroButton)
    MuteFrame(CollectionsMicroButton)
    MuteFrame(EJMicroButton)
    MuteFrame(StoreMicroButton)
    MuteFrame(MainMenuMicroButton)
    -- Do not mute PetActionBarFrame/PetActionBar to avoid breaking pet button input.

    -- 2. Hide elements on the MainActionBar
    if MainActionBar then
        if MainActionBar.EndCaps then MainActionBar.EndCaps:SetAlpha(0) end
        if MainActionBar.ActionBarPageNumber then MainActionBar.ActionBarPageNumber:SetAlpha(0) end
        if MainActionBar.BorderArt then MainActionBar.BorderArt:SetAlpha(0) end
        
        -- Hex Frame Fix
        local children = {MainActionBar:GetChildren()}
        for _, child in ipairs(children) do
            if child and not child:IsForbidden() and child:IsObjectType("Frame") then
                if child.Center or (child.GetBackdrop and child:GetBackdrop()) then
                    child:SetAlpha(0)
                end
            end
        end
    end
    
    -- 3. Hide the Status Tracking Bar Art
    if StatusTrackingBarManager and StatusTrackingBarManager.MainStatusTrackingBarContainer then
        StatusTrackingBarManager.MainStatusTrackingBarContainer:DisableDrawLayer("BACKGROUND")
        StatusTrackingBarManager.MainStatusTrackingBarContainer:DisableDrawLayer("BORDER")
        StatusTrackingBarManager.MainStatusTrackingBarContainer:DisableDrawLayer("OVERLAY")
    end

    -- 4. Clean up individual action buttons
    for barNum = 1, 8 do
        local prefix = BAR_BUTTON_MAP[barNum]
        if prefix then
            for i = 1, 12 do
                local button = _G[prefix..i]
                if button then
                    -- HIDE STATIC BACKGROUNDS
                    if button.SlotBackground then button.SlotBackground:SetAlpha(0) end
                    if button.KeybindSlotBackground then button.KeybindSlotBackground:SetAlpha(0) end
                    if button.SlotArt then button.SlotArt:SetAlpha(0) end
                    
                    -- HIDE INTERACTIVE TEXTURES (The Yellow Glow & Click State)
                    if button.GetHighlightTexture then
                        local hl = button:GetHighlightTexture()
                        if hl and hl ~= button.StyledIconHighlight then hl:SetAlpha(0) end
                    end

                    if button.GetPushedTexture then
                        local pushed = button:GetPushedTexture()
                        if pushed then pushed:SetAlpha(0) end
                    end

                    -- Hide Hotkey & Normal Texture
                    if button.HotKey then button.HotKey:SetAlpha(0) end
                    if button.NormalTexture then 
                        local nt = button:GetNormalTexture()
                        if nt then nt:SetAlpha(0) end
                    end
                end
            end
        end
    end
end

-- =========================================================================
--  CREATE STYLED ACTION BOX - MATCHING PLAYER FRAME COLORS
-- =========================================================================

local function CreateStyledActionBox(barNum, buttonIndex, themeOrSize, sizeOverride)
    local config = GetConfig()
    local barConfig = barNum > 0 and config["bar"..barNum] or nil
    local themeColors, boxSize
    if type(themeOrSize) == "number" then
        -- Called from pet/stance: themeOrSize is the box size
        themeColors = GetActionBarTheme(config)
        boxSize = themeOrSize
    else
        themeColors = themeOrSize or GetActionBarTheme(config, barConfig)
        local baseSize = 44
        boxSize = baseSize * ((barConfig and barConfig.scale or 100) / 100)
    end
    if sizeOverride then boxSize = sizeOverride end
    
    -- Main container
    local frameName = (barNum > 0) and ("StyledActionBox_Bar"..barNum.."_"..buttonIndex) or ("StyledPetBox_"..buttonIndex)
    local box = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    box:SetSize(boxSize, boxSize)
    box:SetFrameStrata("MEDIUM")
    box:EnableMouse(false)
    
    -- 1. Outer Glow Shadow (Neutral Dark)
    -- Keeps the box grounded regardless of class color
    local shadow = box:CreateTexture(nil, "BACKGROUND", nil, -8)
    shadow:SetPoint("CENTER", 0, 0)
    shadow:SetSize(boxSize + 16, boxSize + 16)
    shadow:SetTexture("Interface\\GLUES\\MODELS\\UI_MainMenu\\BlizzShadow")
    shadow:SetVertexColor(unpack(themeColors.shadow))
    shadow:SetBlendMode("BLEND")
    box.shadow = shadow
    
    -- 2. Main Background (Theme Color)
    local bg = box:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(box)
    bg:SetColorTexture(unpack(themeColors.bg))
    box.bg = bg
    
    -- 3. Inner Vignette (Depth)
    local vignette = box:CreateTexture(nil, "BACKGROUND", nil, -6)
    vignette:SetPoint("TOPLEFT", 2, -2)
    vignette:SetPoint("BOTTOMRIGHT", -2, 2)
    vignette:SetColorTexture(unpack(themeColors.vignette))
    vignette:SetGradient("VERTICAL", 
        CreateColor(unpack(themeColors.vignetteTop)), 
        CreateColor(unpack(themeColors.vignetteBottom))
    )
    box.vignette = vignette
    
    -- 4. Outer Border (Theme)
    local outerBorder = box:CreateTexture(nil, "BORDER", nil, -5)
    outerBorder:SetPoint("TOPLEFT", -1, 1)
    outerBorder:SetPoint("BOTTOMRIGHT", 1, -1)
    outerBorder:SetColorTexture(unpack(themeColors.outerBorder))
    box.outerBorder = outerBorder
    
    -- 5. Main Border (Theme Accent Line)
    local mainBorder = box:CreateTexture(nil, "BORDER", nil, -4)
    mainBorder:SetPoint("TOPLEFT", 0, 0)
    mainBorder:SetPoint("BOTTOMRIGHT", 0, 0)
    mainBorder:SetColorTexture(unpack(themeColors.mainBorder))
    box.mainBorder = mainBorder
    
    -- 6. Inner Highlight (Subtle)
    local innerHighlight = box:CreateTexture(nil, "BORDER", nil, -3)
    innerHighlight:SetPoint("TOPLEFT", 1, -1)
    innerHighlight:SetPoint("BOTTOMRIGHT", -1, 1)
    innerHighlight:SetColorTexture(unpack(themeColors.innerHighlight))
    box.innerHighlight = innerHighlight
    
    -- 7. Top Shine (Glass Effect)
    local topShine = box:CreateTexture(nil, "OVERLAY", nil, 1)
    topShine:SetPoint("TOPLEFT", 3, -3)
    topShine:SetPoint("TOPRIGHT", -3, -3)
    topShine:SetHeight(boxSize * 0.3)
    topShine:SetColorTexture(1, 1, 1, 0.02)
    topShine:SetGradient("VERTICAL", 
        CreateColor(unpack(themeColors.topShineStart)), 
        CreateColor(unpack(themeColors.topShineEnd))
    )
    box.topShine = topShine
    
    -- 8. Glow Frame for Procs/Hover
    local glowFrame = CreateFrame("Frame", nil, box)
    glowFrame:SetAllPoints()
    glowFrame:SetFrameLevel(box:GetFrameLevel() + 1)
    box.glowFrame = glowFrame
    
    -- Edge glow (Theme Accent)
    local edgeGlow = glowFrame:CreateTexture(nil, "OVERLAY", nil, 2)
    edgeGlow:SetPoint("CENTER")
    edgeGlow:SetSize(boxSize + 16, boxSize + 16)
    edgeGlow:SetTexture("Interface\\GLUES\\MODELS\\UI_MainMenu\\BlizzShadow")
    edgeGlow:SetVertexColor(unpack(themeColors.edgeGlow)) -- Hidden by default
    edgeGlow:SetBlendMode("ADD")
    box.edgeGlow = edgeGlow
    
    return box
end

-- CreateStyledPetBox delegates to the shared factory with a size override
local function CreateStyledPetBox(index, themeColors, size)
    return CreateStyledActionBox(0, index, size)
end

local function ApplyActionBoxTheme(box, themeColors, boxSize)
    if not box or not themeColors then return end
    if box.bg then box.bg:SetColorTexture(unpack(themeColors.bg)) end
    if box.outerBorder then box.outerBorder:SetColorTexture(unpack(themeColors.outerBorder)) end
    if box.mainBorder then box.mainBorder:SetColorTexture(unpack(themeColors.mainBorder)) end
    if box.shadow then box.shadow:SetVertexColor(unpack(themeColors.shadow)) end
    if box.vignette then box.vignette:SetColorTexture(unpack(themeColors.vignette)) end
    if box.innerHighlight then box.innerHighlight:SetColorTexture(unpack(themeColors.innerHighlight)) end
    if box.topShine then
        if boxSize then box.topShine:SetHeight(boxSize * 0.3) end
        box.topShine:SetGradient("VERTICAL",
            CreateColor(unpack(themeColors.topShineStart)),
            CreateColor(unpack(themeColors.topShineEnd))
        )
    end
    if box.edgeGlow then
        local gR, gG, gB, gA = unpack(themeColors.edgeGlow)
        if themeColors.style ~= "Hidden" and (not gA or gA <= 0) then
            gR, gG, gB = themeColors.highlight[1], themeColors.highlight[2], themeColors.highlight[3]
            gA = math.max(themeColors.highlight[4] or 0.25, 0.25)
        end
        box.edgeGlow:SetVertexColor(gR, gG, gB, gA or 0)
    end
    if box.vignette then
        box.vignette:SetGradient("VERTICAL",
            CreateColor(unpack(themeColors.vignetteTop)),
            CreateColor(unpack(themeColors.vignetteBottom))
        )
    end
end

ResolveBindingCommandForButton = function(button, barNum, index)
    -- Prefer resolving from the real Blizzard button name so grid layouts
    -- cannot desync the displayed hotkey text from the bound button.
    if button and button.GetName then
        local name = button:GetName()
        if name then
            local suffix = name:match("^ActionButton(%d+)$")
            if suffix then return "ACTIONBUTTON" .. suffix end
            suffix = name:match("^MultiBarBottomLeftButton(%d+)$")
            if suffix then return "MULTIACTIONBAR1BUTTON" .. suffix end
            suffix = name:match("^MultiBarBottomRightButton(%d+)$")
            if suffix then return "MULTIACTIONBAR2BUTTON" .. suffix end
            suffix = name:match("^MultiBarRightButton(%d+)$")
            if suffix then return "MULTIACTIONBAR3BUTTON" .. suffix end
            suffix = name:match("^MultiBarLeftButton(%d+)$")
            if suffix then return "MULTIACTIONBAR4BUTTON" .. suffix end
            suffix = name:match("^MultiBar5Button(%d+)$")
            if suffix then return "MULTIACTIONBAR5BUTTON" .. suffix end
            suffix = name:match("^MultiBar6Button(%d+)$")
            if suffix then return "MULTIACTIONBAR6BUTTON" .. suffix end
            suffix = name:match("^MultiBar7Button(%d+)$")
            if suffix then return "MULTIACTIONBAR7BUTTON" .. suffix end
        end
    end

    if not barNum or not index then return nil end
    if barNum == 1 then
        return "ACTIONBUTTON" .. index
    elseif barNum == 2 then
        return "MULTIACTIONBAR1BUTTON" .. index
    elseif barNum == 3 then
        return "MULTIACTIONBAR2BUTTON" .. index
    elseif barNum == 4 then
        return "MULTIACTIONBAR3BUTTON" .. index
    elseif barNum == 5 then
        return "MULTIACTIONBAR4BUTTON" .. index
    elseif barNum == 6 then
        return "MULTIACTIONBAR5BUTTON" .. index
    elseif barNum == 7 then
        return "MULTIACTIONBAR6BUTTON" .. index
    elseif barNum == 8 then
        return "MULTIACTIONBAR7BUTTON" .. index
    end
    return nil
end

-- =========================================================================
--  STYLE ACTION BUTTON - MIDNIGHT EDITION
-- =========================================================================

local function StyleActionButton(button, box, index, barNum, theme)
    if not button then return end
    
    local config = GetConfig()
    local themeColors = theme or GetActionBarTheme(config)
    local tutorialHooked = _G.MidnightUI_ActionBarTutorialHooked
    local btnName = button.GetName and button:GetName()
    local isPetButton = btnName and btnName:find("^PetActionButton") ~= nil
    local isStanceButton = btnName and btnName:find("^StanceButton") ~= nil
    button._muiPetIndex = isPetButton and index or nil

    local function UpdatePetCheckedTexture(btn)
        if not btn then return end
        local activeOverlay = btn._muiPetOverlay or (btn._muiBox and btn._muiBox.petActiveOverlay)
        local idx = btn._muiPetIndex or btn.action
        if not idx or not GetPetActionInfo then
            if activeOverlay then activeOverlay:SetAlpha(0) end
            return
        end
        local name, subText, texture, isActive, autoCastAllowed, autoCastEnabled, spellID = GetPetActionInfo(idx)
        local isMomentary = (name == "PET_ACTION_MOVE_TO")
        if (isActive and not autoCastEnabled and not isMomentary) or (isMomentary and btn._muiMoveToHighlight) then
            if activeOverlay then activeOverlay:SetAlpha(1) end
        else
            if activeOverlay then activeOverlay:SetAlpha(0) end
        end
        -- no debug output
    end

    local function FixTutorialDragTargetFrame()
        local t = _G.TutorialDragTargetFrame
        if not t then return end
        local parent = t:GetParent()
        local b = (parent and parent._muiBox) or parent
        if not b and parent and parent.GetName then
            local parentName = parent:GetName()
            if parentName and _G[parentName] and _G[parentName]._muiBox then
                b = _G[parentName]._muiBox
            end
        end
        if not b then return end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", b, "TOPLEFT", -2, 2)
        t:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", 2, -2)
        if t.Glow then t.Glow:SetAllPoints(t) end
        if t.Border then t.Border:SetAllPoints(t) end
        if t.Circle then t.Circle:SetAllPoints(t) end
    end

    local function HasRotationHelperAtlas(frame)
        if frame.GetRegions then
            for _, region in ipairs({frame:GetRegions()}) do
                local atlas = region.GetAtlas and region:GetAtlas()
                if atlas and type(atlas) == "string" and atlas:find("RotationHelper") then
                    return true
                end
            end
        end
        return false
    end

    local function SyncDescendantsToBox(parent, targetBox)
        for _, child in ipairs({parent:GetChildren()}) do
            if child and child ~= button.cooldown and not HasRotationHelperAtlas(child) then
                child:ClearAllPoints()
                child:SetPoint("TOPLEFT", targetBox, "TOPLEFT", 0, 0)
                child:SetPoint("BOTTOMRIGHT", targetBox, "BOTTOMRIGHT", 0, 0)
                -- Resize textures inside this child to fill it
                if child.GetRegions then
                    for _, region in ipairs({child:GetRegions()}) do
                        if region and region.IsObjectType and region:IsObjectType("Texture") then
                            region:ClearAllPoints()
                            region:SetAllPoints(child)
                        end
                    end
                end
                -- Recurse into grandchildren
                if child.GetChildren then
                    SyncDescendantsToBox(child, targetBox)
                end
            end
        end
    end

    local function SyncButtonToBox()
        if not button or not box then return end
        if button._muiSyncing then return end
        button._muiSyncing = true
        if InCombatLockdown and InCombatLockdown() and button:IsProtected() then
            button._muiSyncing = false
            return
        end
        button:SetScale(1)
        if not isPetButton then
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            button:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        end
        button:SetHitRectInsets(0, 0, 0, 0)
        button._muiBox = box
        SyncDescendantsToBox(button, box)
        button._muiSyncing = false
    end
    
    -- Ensure the action button owns the full hit area and isn't blocked by child frames
    if not button._muiMouseFix then
        button:EnableMouse(true)
        button:SetHitRectInsets(0, 0, 0, 0)
        button:SetScale(1)
    if not isPetButton and not isStanceButton then
        if button.cooldown and button.cooldown.EnableMouse then button.cooldown:EnableMouse(false) end
            if button.Icon and button.Icon.EnableMouse then button.Icon:EnableMouse(false) end
            if button.IconMask and button.IconMask.EnableMouse then button.IconMask:EnableMouse(false) end
            if button.Count and button.Count.EnableMouse then button.Count:EnableMouse(false) end
            if button.HotKey and button.HotKey.EnableMouse then button.HotKey:EnableMouse(false) end
            if button.Name and button.Name.EnableMouse then button.Name:EnableMouse(false) end
            if button.Border and button.Border.EnableMouse then button.Border:EnableMouse(false) end
            if button.Flash and button.Flash.EnableMouse then button.Flash:EnableMouse(false) end
            if button.SpellHighlightTexture and button.SpellHighlightTexture.EnableMouse then button.SpellHighlightTexture:EnableMouse(false) end
            for _, child in ipairs({button:GetChildren()}) do
                if child and child.EnableMouse then child:EnableMouse(false) end
            end
        end
        button._muiMouseFix = true
        button._muiSyncToBox = SyncButtonToBox
        button:HookScript("OnShow", function()
            C_Timer.After(0, SyncButtonToBox)
        end)
        button:HookScript("OnSizeChanged", function()
            C_Timer.After(0, SyncButtonToBox)
        end)
        button:HookScript("OnEvent", function()
            C_Timer.After(0, SyncButtonToBox)
        end)

    end

    if not tutorialHooked and _G.TutorialDragTargetFrame then
        _G.MidnightUI_ActionBarTutorialHooked = true
        local t = _G.TutorialDragTargetFrame
        t:HookScript("OnShow", function()
            local t = _G.TutorialDragTargetFrame
            if t and t.GetParent and t:GetParent() and t:GetParent()._muiBox then
                FixTutorialDragTargetFrame()
            end
        end)
        if t and t.HookScript and t.HasScript and t:HasScript("OnParentChanged") then
            t:HookScript("OnParentChanged", function()
                local t2 = _G.TutorialDragTargetFrame
                if t2 and t2.GetParent and t2:GetParent() and t2:GetParent()._muiBox then
                    FixTutorialDragTargetFrame()
                end
            end)
        else
            t:HookScript("OnUpdate", function(self)
                if self._muiLastParent ~= self:GetParent() then
                    self._muiLastParent = self:GetParent()
                    if self._muiLastParent and self._muiLastParent._muiBox then
                        FixTutorialDragTargetFrame()
                    end
                end
            end)
        end
    end

    if not button._muiHitPadding then
        button:SetHitRectInsets(0, 0, 0, 0)
        button._muiHitPadding = true
    end
    
    -- Hide default textures we don't want (but keep pet button icons)
    if button.NormalTexture then
        local nt = button:GetNormalTexture()
        if nt then
            if isPetButton then
                nt:SetAlpha(1)
            else
                nt:SetAlpha(0)
            end
        end
    end
    if isPetButton or isStanceButton then
        if button.SlotBackground then button.SlotBackground:SetAlpha(0) end
        if button.Border then button.Border:SetAlpha(0) end
        if button.iconBorder then button.iconBorder:SetAlpha(0) end
        if button.IconBorder then button.IconBorder:SetAlpha(0) end
        if button.IconBorder and button.IconBorder.Hide then button.IconBorder:Hide() end
        if button.iconBorder and button.iconBorder.Hide then button.iconBorder:Hide() end
        if button.HighlightTexture then
            button.HighlightTexture:SetAlpha(0)
            if button.HighlightTexture.Hide then button.HighlightTexture:Hide() end
        end
        local hl = button.GetHighlightTexture and button:GetHighlightTexture()
        if hl and hl ~= button.StyledIconHighlight then hl:SetAlpha(0) end
        if button.CheckedTexture then
            if button.isActive then
                button.CheckedTexture:SetAlpha(0.75)
            else
                button.CheckedTexture:SetAlpha(0)
            end
            button.CheckedTexture:SetBlendMode("ADD")
        end
    end
    
    -- Style the icon with a subtle border
    if not button.icon then
        button.icon = button.Icon or (btnName and _G[btnName .. "Icon"]) or button:GetNormalTexture()
    end
    if button.icon then
        if button.icon:IsShown() then
            button.icon:SetAlpha(1)
        end
        button.icon:SetTexCoord(0, 1, 0, 1)
        button.icon:ClearAllPoints()
        button.icon:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
        button.icon:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        if button.IconMask then
            if isPetButton or isStanceButton then
                button.IconMask:ClearAllPoints()
                button.IconMask:SetAllPoints(button.icon)
                button.IconMask:Show()
            else
                button.icon:RemoveMaskTexture(button.IconMask)
                button.IconMask:Hide()
            end
        end

        if not button.iconBorder then
            button.iconBorder = button:CreateTexture(nil, "OVERLAY", nil, 1)
            button.iconBorder:SetAllPoints(button.icon)
            button.iconBorder:SetColorTexture(0, 0, 0, 0)
            button.iconBorder:SetBlendMode("BLEND")
        end
    end

    -- Tag box with its bar's current style for cursor-drag visibility
    if box and barNum then
        local config2 = GetConfig()
        local barConfig2 = config2["bar"..barNum]
        local theme2 = GetActionBarTheme(config2, barConfig2)
        box._muiStyle = theme2 and theme2.style or "Class Color"
    end

    if (isPetButton or isStanceButton) and button.GetRegions then
        local keep = {}
        if button.icon then keep[button.icon] = true end
        local hl = button.GetHighlightTexture and button:GetHighlightTexture()
        if hl then keep[hl] = true end
        if button.AutoCastable then keep[button.AutoCastable] = true end
        if button.AutoCastShine then keep[button.AutoCastShine] = true end
        if button.Flash then keep[button.Flash] = true end
        for _, region in ipairs({button:GetRegions()}) do
            if region and region.IsObjectType and region:IsObjectType("Texture") then
                if not keep[region] and region ~= button.iconBorder and region ~= button.IconBorder then
                    region:SetAlpha(0)
                end
            end
        end
    end

    if isPetButton then
        local hl = button.GetHighlightTexture and button:GetHighlightTexture()
        if hl then
            hl:ClearAllPoints()
            hl:SetAlpha(0)
        end
        if not box.petActiveOverlay then
            local active = box:CreateTexture(nil, "OVERLAY", nil, 4)
            active:SetPoint("TOPLEFT", 4, -4)
            active:SetPoint("BOTTOMRIGHT", -4, 4)
            active:SetColorTexture(1, 0.9, 0.1, 1.0)
            active:SetAlpha(0)
            box.petActiveOverlay = active
        end
        if not box.petHoverOverlay then
            local h = box:CreateTexture(nil, "OVERLAY", nil, 6)
            h:SetPoint("TOPLEFT", 4, -4)
            h:SetPoint("BOTTOMRIGHT", -4, 4)
            h:SetColorTexture(1, 1, 1, 0.15)
            h:SetAlpha(0)
            box.petHoverOverlay = h
        end
        button._muiBox = box
        button._muiPetOverlay = box.petActiveOverlay
        if button.CheckedTexture then
            button.CheckedTexture:SetAlpha(0)
        end
        if button.AutoCastable then
            button.AutoCastable:ClearAllPoints()
            button.AutoCastable:SetAllPoints(box)
        end
        if button.AutoCastShine then
            button.AutoCastShine:ClearAllPoints()
            button.AutoCastShine:SetAllPoints(box)
        end
    end

    if isStanceButton then
        local hl = button.GetHighlightTexture and button:GetHighlightTexture()
        if hl then
            hl:ClearAllPoints()
            hl:SetAlpha(0)
        end
        if box.stanceActiveOverlay and box.stanceActiveOverlay:GetParent() ~= box then
            box.stanceActiveOverlay:Hide()
            box.stanceActiveOverlay = nil
        end
        if box.stanceHoverOverlay and box.stanceHoverOverlay:GetParent() ~= box then
            box.stanceHoverOverlay:Hide()
            box.stanceHoverOverlay = nil
        end
        -- Active stance border uses stanceThinBorder color swap (handled in BuildStanceBar).
        if not box.stanceHoverOverlay then
            local h = box:CreateTexture(nil, "OVERLAY", nil, 6)
            h:SetPoint("TOPLEFT", 4, -4)
            h:SetPoint("BOTTOMRIGHT", -4, 4)
            h:SetColorTexture(1, 1, 1, 0.15)
            h:SetAlpha(0)
            box.stanceHoverOverlay = h
        end
        button._muiBox = box
        button._muiStanceOverlay = box.stanceActiveOverlay
        if button.CheckedTexture then
            button.CheckedTexture:SetAlpha(0)
        end
        if not button._muiStanceHoverHooked then
            button._muiStanceHoverHooked = true
            button:HookScript("OnEnter", function(btn)
                local overlay = btn._muiBox and btn._muiBox.stanceHoverOverlay
                if overlay then overlay:SetAlpha(1) end
            end)
            button:HookScript("OnLeave", function(btn)
                local overlay = btn._muiBox and btn._muiBox.stanceHoverOverlay
                if overlay then overlay:SetAlpha(0) end
            end)
        end
    end

    if isPetButton then
        UpdatePetCheckedTexture(button)
        if not button._muiPetHoverHooked then
            button._muiPetHoverHooked = true
            button:HookScript("OnEnter", function(btn)
                local overlay = btn._muiBox and btn._muiBox.petHoverOverlay
                if overlay then overlay:SetAlpha(1) end
            end)
            button:HookScript("OnLeave", function(btn)
                local overlay = btn._muiBox and btn._muiBox.petHoverOverlay
                if overlay then overlay:SetAlpha(0) end
            end)
        end
        if not _G.MidnightUI_PetCheckedHooked and type(_G.PetActionButton_Update) == "function" then
            _G.MidnightUI_PetCheckedHooked = true
            hooksecurefunc("PetActionButton_Update", function(btn)
                UpdatePetCheckedTexture(btn)
                if _G.MidnightUI_RefreshPetBarHotkeys then
                    _G.MidnightUI_RefreshPetBarHotkeys()
                end
            end)
        end
        if not _G.MidnightUI_MoveToHooked and type(_G.PetActionButton_OnClick) == "function" then
            _G.MidnightUI_MoveToHooked = true
            hooksecurefunc("PetActionButton_OnClick", function(btn)
                local idx = btn and (btn._muiPetIndex or btn.action)
                if not idx or not GetPetActionInfo then return end
                local name = select(1, GetPetActionInfo(idx))
                if name == "PET_ACTION_MOVE_TO" then
                    btn._muiMoveToHighlight = true
                    UpdatePetCheckedTexture(btn)
                else
                    for i = 1, 10 do
                        local b = _G["PetActionButton"..i]
                        if b then
                            b._muiMoveToHighlight = false
                            UpdatePetCheckedTexture(b)
                        end
                    end
                end
            end)
        elseif not _G.MidnightUI_MoveToHooked and _G.PetActionButton1 and _G.PetActionButton1.HookScript then
            _G.MidnightUI_MoveToHooked = true
            for i = 1, 10 do
                local b = _G["PetActionButton"..i]
                if b and b.HookScript then
                    b:HookScript("OnClick", function(btn)
                        local idx = btn and (btn._muiPetIndex or btn.action)
                        if not idx or not GetPetActionInfo then return end
                        local name = select(1, GetPetActionInfo(idx))
                        if name == "PET_ACTION_MOVE_TO" then
                            btn._muiMoveToHighlight = true
                            UpdatePetCheckedTexture(btn)
                        else
                            for j = 1, 10 do
                                local bb = _G["PetActionButton"..j]
                                if bb then
                                    bb._muiMoveToHighlight = false
                                    UpdatePetCheckedTexture(bb)
                                end
                            end
                        end
                    end)
                end
            end
        end
    end
    
    -- Custom hotkey display with Midnight styling
    if not button.StyledHotkey then
        button.StyledHotkey = button:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        button.StyledHotkey:SetPoint("TOPRIGHT", box, "TOPRIGHT", -2, -2)
        button.StyledHotkey:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        button.StyledHotkey:SetTextColor(unpack(config.hotkeyColor))
        button.StyledHotkey:SetShadowOffset(1, -1)
        button.StyledHotkey:SetShadowColor(0, 0, 0, 0.8)
    end
    
    -- Update hotkey text for all bars (skip for pet bar)
    local bindingCommand = ResolveBindingCommandForButton(button, barNum, index)
    if IsHiddenEmptySlot(box, button) then
        button.StyledHotkey:SetText("")
        button.StyledHotkey:Hide()
        if button.HotKey then button.HotKey:SetAlpha(0); button.HotKey:SetText("") end
    elseif bindingCommand then
        button.StyledHotkey:Show()
        local keybind = GetBindingKey(bindingCommand)
        button.StyledHotkey:SetText(FormatHotkeyDisplay(keybind))
    else
        button.StyledHotkey:SetText("")
    end

    if isPetButton then
        local petKey = GetBindingKey("BONUSACTIONBUTTON" .. index)
        local display = GetShortBindingText(petKey)
        if button.StyledHotkey then button.StyledHotkey:SetText(display) end
        if button.HotKey then
            button.HotKey:SetText("")
            button.HotKey:SetAlpha(0)
        end
    end
    
    -- Resize ALL button textures and overlays to match the box
    -- This covers Flash (click), NormalTexture, PushedTexture, and any other
    -- Blizzard-template textures that have fixed sizes from the default UI.
    for _, region in ipairs({button:GetRegions()}) do
        if region and region ~= button.icon and region ~= button.Icon
           and region ~= button.IconMask
           and region ~= button.HotKey and region ~= button.Count
           and region ~= button.Name and region ~= button.StyledHotkey
           and region.IsObjectType and region:IsObjectType("Texture") then
            region:ClearAllPoints()
            region:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            region:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        end
    end
    -- Resize ALL child frames (cooldown, proc glow, overlays) to match the box
    for _, child in ipairs({button:GetChildren()}) do
        if child then
            child:ClearAllPoints()
            child:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
            child:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        end
    end

    -- Anchor WoW's native border/quality textures to the box so they scale properly.
    if not isPetButton and not isStanceButton then
        -- Scale Assisted Highlight (RotationHelper) to match scaled box size.
        -- Blizzard creates a 45x45 frame with a 66x66 texture that overflows the button.
        -- We apply SetScale so the overflow ratio stays correct at any box size.
        -- We do NOT touch the texture — let Blizzard manage it naturally.
        if not button._muiAssistedHighlightHooked then
            button._muiAssistedHighlightHooked = true
            local baseButtonSize = 44
            local function ScaleAssistedHighlight()
                if not button or not box then return end
                local boxW = box:GetWidth()
                if boxW <= baseButtonSize then return end -- no scaling needed at default size
                local scaleRatio = boxW / baseButtonSize
                for _, child in ipairs({button:GetChildren()}) do
                    if child and not child._muiAHScaled and HasRotationHelperAtlas(child) then
                        child._muiAHScaled = true
                        hooksecurefunc(child, "SetScale", function(self, s)
                            if math.abs(s - scaleRatio) > 0.01 then
                                C_Timer.After(0, function()
                                    if self and self.SetScale then
                                        self:SetScale(scaleRatio)
                                    end
                                end)
                            end
                        end)
                    end
                end
                -- Apply scale to all tagged AH frames (may be found on different ticks)
                for _, child in ipairs({button:GetChildren()}) do
                    if child and child._muiAHScaled then
                        child:SetScale(scaleRatio)
                        child:ClearAllPoints()
                        child:SetPoint("CENTER", box, "CENTER", 0, 0)
                    end
                end
            end
            C_Timer.After(0.5, ScaleAssistedHighlight)
            C_Timer.After(2, ScaleAssistedHighlight)
            button:HookScript("OnEvent", function()
                C_Timer.After(0.1, ScaleAssistedHighlight)
            end)
        end


    end

    -- Enhanced box highlight (Theme Accent)
    if not button.StyledIconHighlight and button.icon then
        button.StyledIconHighlight = box:CreateTexture(nil, "OVERLAY")
        button.StyledIconHighlight:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
        button.StyledIconHighlight:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
        button.StyledIconHighlight:SetBlendMode("ADD")
        button.StyledIconHighlight:SetDrawLayer("OVERLAY", 7)
    end
    if button.StyledIconHighlight then
        local hR, hG, hB, hA = unpack(themeColors.highlight)
        -- Suppress highlight for empty Hidden slots; apply for everything else
        if IsHiddenEmptySlot(box, button) then
            button.StyledIconHighlight:SetColorTexture(0, 0, 0, 0)
            button.StyledIconHighlight:SetAlpha(0)
            if button.SetHighlightTexture and not isPetButton then
                if not button._muiEmptyHighlight then
                    button._muiEmptyHighlight = button:CreateTexture(nil, "HIGHLIGHT")
                    button._muiEmptyHighlight:SetColorTexture(0, 0, 0, 0)
                end
                button:SetHighlightTexture(button._muiEmptyHighlight)
            end
        else
            button.StyledIconHighlight:SetColorTexture(hR, hG, hB, math.max(hA or 0.35, 0.65))
            button.StyledIconHighlight:SetAlpha(0)
            if button.SetHighlightTexture and not isPetButton then
                button:SetHighlightTexture(button.StyledIconHighlight)
            end
        end
    end
    
    -- Pulse effect on hover
    if not button.hoverAnimation then
        -- Ensure hover glow is visible even when theme edgeGlow alpha is zero
        if box.edgeGlow then
            local gR, gG, gB, gA = unpack(themeColors.edgeGlow)
            if not gA or gA <= 0 then
                gR, gG, gB = themeColors.highlight[1], themeColors.highlight[2], themeColors.highlight[3]
                gA = math.max(themeColors.highlight[4] or 0.25, 0.55)
            end
            box.edgeGlow:SetVertexColor(gR, gG, gB, gA)
        end

        button.hoverAnimation = box.edgeGlow:CreateAnimationGroup()
        local fadeIn = button.hoverAnimation:CreateAnimation("Alpha")
        fadeIn:SetFromAlpha(0)
        fadeIn:SetToAlpha(1.0)
        fadeIn:SetDuration(0.12)
        fadeIn:SetSmoothing("IN")
        
        local function SetHoverState(isOver)
            if isOver then
                if button.StyledIconHighlight then button.StyledIconHighlight:SetAlpha(1.0) end
                if box.edgeGlow then box.edgeGlow:SetAlpha(1.0) end
            else
                if button.StyledIconHighlight then button.StyledIconHighlight:SetAlpha(0) end
                if box.edgeGlow then box.edgeGlow:SetAlpha(0) end
            end
        end

        button:HookScript("OnEnter", function(self)
            -- Skip hover highlight for empty slots in Hidden style
            if IsHiddenEmptySlot(box, button) and not hiddenDragActive then return end

            if CURRENT_HOVER_BUTTON and CURRENT_HOVER_BUTTON ~= button and CURRENT_HOVER_BUTTON._muiSetHoverState then
                CURRENT_HOVER_BUTTON._muiSetHoverState(false)
            end
            CURRENT_HOVER_BUTTON = button
            SetHoverState(true)
            if button.hoverAnimation and not button.hoverAnimation:IsPlaying() then
                button.hoverAnimation:Play()
            end
        end)
        
        button:HookScript("OnLeave", function(self)
            SetHoverState(false)
            if button.hoverAnimation then
                button.hoverAnimation:Stop()
            end
            if CURRENT_HOVER_BUTTON == button then CURRENT_HOVER_BUTTON = nil end
        end)
        button._muiSetHoverState = SetHoverState
    end
    
    -- Enhanced cooldown styling
    if button.cooldown then
        button.cooldown:ClearAllPoints()
        button.cooldown:SetAllPoints(box)
        button.cooldown:SetDrawEdge(false)
        button.cooldown:SetDrawSwipe(true)
        button.cooldown:SetHideCountdownNumbers(false)
        
        if button.cooldown.currentCooldownType == COOLDOWN_TYPE_NORMAL then
            if not button.cooldown.styledText then
                button.cooldown.styledText = button.cooldown:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                button.cooldown.styledText:SetPoint("CENTER", 0, 0)
                button.cooldown.styledText:SetFont(STANDARD_TEXT_FONT, 16, "OUTLINE")
                button.cooldown.styledText:SetTextColor(0.85, 0.90, 1.00)
                button.cooldown.styledText:SetShadowOffset(1, -1)
                button.cooldown.styledText:SetShadowColor(0, 0, 0, 1)
            end
        end
    end
    
    if button.Count then
        button.Count:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
        button.Count:SetTextColor(1, 1, 1)
        button.Count:SetShadowOffset(1, -1)
        button.Count:SetShadowColor(0, 0, 0, 1)
        button.Count:ClearAllPoints()
        button.Count:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -2, 2)
    end
    
    if button.Name then
        button.Name:SetFont(STANDARD_TEXT_FONT, 9, "OUTLINE")
        button.Name:SetTextColor(0.85, 0.90, 1.00)
        button.Name:SetShadowOffset(1, -1)
        button.Name:SetShadowColor(0, 0, 0, 0.8)
        button.Name:ClearAllPoints()
        button.Name:SetPoint("BOTTOM", box, "BOTTOM", 0, 2)
    end
end

-- =========================================================================
--  BUILD SINGLE ACTION BAR
-- =========================================================================

local function BuildActionBar(barNum)
    local config = GetConfig()
    local barConfig = config["bar"..barNum]
    local themeColors = GetActionBarTheme(config, barConfig)
    local prefix = BAR_BUTTON_MAP[barNum]
    if not prefix then return end
    
    if not barConfig or not barConfig.enabled then
        if actionBarContainers[barNum] then
            actionBarContainers[barNum]:Hide()
        end
        
        if actionBarBoxes[barNum] then
            for i = 1, 12 do
                if actionBarBoxes[barNum][i] then
                    actionBarBoxes[barNum][i]:Hide()
                end
            end
        end
        
        for i = 1, 12 do
            local button = _G[prefix..i]
            if button then
                button:Hide()
            end
        end
        
        return
    end
    
    local baseSize = 44
    local boxSize = baseSize * (barConfig.scale / 100)
    local spacing = barConfig.spacing
    local rows = barConfig.rows
    local iconsPerRow = barConfig.iconsPerRow
    
    local containerWidth = (boxSize * iconsPerRow) + (spacing * (iconsPerRow - 1))
    local containerHeight = (boxSize * rows) + (spacing * (rows - 1))
    
    if not actionBarContainers[barNum] then
        local container = CreateFrame("Frame", "MyActionBarContainer"..barNum, UIParent)
        container:SetMovable(true)
        container:EnableMouse(false)
        container:SetClampedToScreen(true)
        
        local pos = DEFAULT_POSITIONS[barNum]
        container:SetPoint(pos[1], _G[pos[2]], pos[3], pos[4], pos[5])
        
        actionBarContainers[barNum] = container
        actionBarBoxes[barNum] = {}
        _G["MyActionBarContainer"..barNum] = container
    end
    
    local container = actionBarContainers[barNum]
    container:SetSize(containerWidth, containerHeight)
    container:Show()
    
    local buttonIndex = 0
    for row = 1, rows do
        for col = 1, iconsPerRow do
            buttonIndex = buttonIndex + 1
            if buttonIndex > 12 then break end
            
            local button = _G[prefix..buttonIndex]
            if button then
                button:Show()
                    if not actionBarBoxes[barNum][buttonIndex] then
                        local box = CreateStyledActionBox(barNum, buttonIndex, themeColors)
                        box:SetParent(container)
                        actionBarBoxes[barNum][buttonIndex] = box
                    end
                if button:GetParent() ~= container then
                    button:SetParent(container)
                end
                button:ClearAllPoints()
        
                local box = actionBarBoxes[barNum][buttonIndex]
                box:SetSize(boxSize, boxSize)
                box:SetScale(1)
                button:SetSize(boxSize, boxSize)
                button:SetScale(1)
                button:SetHitRectInsets(0, 0, 0, 0)
                box._muiBoundButton = button
                if not actionBarButtons[barNum] then actionBarButtons[barNum] = {} end
                actionBarButtons[barNum][buttonIndex] = button
                
                box:ClearAllPoints()
                local xOffset = (col - 1) * (boxSize + spacing)
                local yOffset = -(row - 1) * (boxSize + spacing)
                box:SetPoint("TOPLEFT", container, "TOPLEFT", xOffset, yOffset)
                button:ClearAllPoints()
                button:SetPoint("TOPLEFT", box, "TOPLEFT", 0, 0)
                button:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", 0, 0)
                
                box:SetFrameLevel(math.max(0, button:GetFrameLevel() - 1))
                button:SetFrameLevel(box:GetFrameLevel() + 2)
                if button._muiSyncToBox then
                    C_Timer.After(0, button._muiSyncToBox)
                    C_Timer.After(0.1, button._muiSyncToBox)
                end

                box._muiStyle = themeColors.style or "Class Color"
                box.shadow:SetSize(boxSize + 12, boxSize + 12)
                box.edgeGlow:SetSize(boxSize + 16, boxSize + 16)
                ApplyActionBoxTheme(box, themeColors, boxSize)
                StyleActionButton(button, box, buttonIndex, barNum, themeColors)
                box:Show()
            end
        end
    end
    
    for i = buttonIndex + 1, 12 do
        if actionBarBoxes[barNum][i] then
            actionBarBoxes[barNum][i]:Hide()
        end
        local button = _G[prefix..i]
        if button then
            button:Hide()
            if button.EnableMouse then button:EnableMouse(false) end
        end
    end

    -- Store layout metadata for hover detection.
    actionBarBoxes[barNum]._muiLayout = {
        boxSize = boxSize,
        spacing = spacing,
        rows = rows,
        iconsPerRow = iconsPerRow,
        container = container,
    }
end

-- =========================================================================
--  BUILD ALL ACTION BARS
-- =========================================================================

-- Shared tuning for pet/stance compact boxes (reduces shadow, hides ornaments, adds thin border)
local function TuneCompactBox(box, themeColors, borderKey, inset, borderAlpha)
    if not box then return end
    local function ScaleAlpha(tex, scale)
        if not tex or not tex.GetVertexColor then return end
        local r, g, b, a = tex:GetVertexColor()
        tex:SetVertexColor(r, g, b, (a or 1) * scale)
    end
    ScaleAlpha(box.shadow, 0.25)
    if box.outerBorder then box.outerBorder:SetAlpha(0) end
    if box.mainBorder then box.mainBorder:SetAlpha(0) end
    if box.innerHighlight then box.innerHighlight:SetAlpha(0) end
    if box.topShine then box.topShine:SetAlpha(0) end
    if box.edgeGlow then box.edgeGlow:SetAlpha(0) end
    ScaleAlpha(box.bg, 0.35)
    if not box[borderKey] then
        local b = box:CreateTexture(nil, "OVERLAY", nil, 5)
        b:SetPoint("TOPLEFT", inset, -inset)
        b:SetPoint("BOTTOMRIGHT", -inset, inset)
        box[borderKey] = b
    end
    if themeColors and box[borderKey] then
        local r, g, b, a = unpack(themeColors.mainBorder)
        box[borderKey]:SetColorTexture(r, g, b, math.min(a or 1, borderAlpha))
    end
end

local function BuildPetBar()
    local settings = EnsurePetBarSettings()
    if not settings or settings.enabled == false then
        if petBarContainer and not IsInCombat() then
            SetOverlayContainerVisibility(petBarContainer, settings, false)
        end
        return
    end
    -- Defer all container-level layout to after combat. SetSize/SetScale/Hide on
    -- the container are blocked while PetActionBarFrame (secure) is parented to it.
    if IsInCombat() then
        QueueProtectedLayout("PetBarBuild", BuildPetBar)
        return
    end
    local buttonSize = settings.buttonSize or 32
    local boxSize = math_floor(buttonSize + 0.5)
    local spacing = settings.spacing or 6
    local buttonsPerRow = math_max(1, math_min(settings.buttonsPerRow or 10, 10))
    local rows = math_ceil(10 / buttonsPerRow)
    local containerWidth = (buttonSize * buttonsPerRow) + (spacing * (buttonsPerRow - 1))
    local containerHeight = (buttonSize * rows) + (spacing * (rows - 1))
    if PlayerHasPetClass() and OverlaysUnlocked() then
        petBarContainer = EnsureOverlayContainer(petBarContainer, "MyPetBarContainer", settings, PET_DEFAULT_POSITION, "PetBar", "PET BAR")
    end
    if not PetHasActionBar or not PetHasActionBar() then
        if petBarContainer then
            if PlayerHasPetClass() and OverlaysUnlocked() and petBarContainer.dragOverlay then
                UpdateOverlayContainer(petBarContainer, containerWidth, containerHeight, settings)
                SetOverlayContainerVisibility(petBarContainer, settings, true)
                petBarContainer.dragOverlay:Show()
            else
                SetOverlayContainerVisibility(petBarContainer, settings, false)
            end
        end
        return
    end

    local themeColors = GetActionBarTheme(GetConfig())

    local petHost = _G.PetActionBarFrame or _G.PetActionBar
    if not petHost then
        if petBarContainer then
            SetOverlayContainerVisibility(petBarContainer, settings, false)
        end
        return
    end

    if not petBarContainer then
        petBarContainer = EnsureOverlayContainer(petBarContainer, "MyPetBarContainer", settings, PET_DEFAULT_POSITION, "PetBar", "PET BAR")
        petBarContainer.dragOverlay:Hide()
    end

    UpdateOverlayContainer(petBarContainer, containerWidth, containerHeight, settings)

    ApplyProtectedHostLayout(petHost, petBarContainer, containerWidth, containerHeight, "PetHostLayout")
    if not petHost._muiLayoutHooked and type(_G.PetActionBar_UpdateLayout) == "function" then
        petHost._muiLayoutHooked = true
        hooksecurefunc("PetActionBar_UpdateLayout", function()
            if petBarContainer and petHost and not IsInCombat() then
                ApplyProtectedHostLayout(petHost, petBarContainer, petBarContainer:GetWidth(), petBarContainer:GetHeight(), "PetHostLayout")
            end
        end)
    end
    if petHost.SetButtonSpacing then
        petHost:SetButtonSpacing(spacing)
    elseif PetActionBar_SetButtonSpacing then
        PetActionBar_SetButtonSpacing(spacing)
    end
    if PetActionBar_UpdateLayout then
        PetActionBar_UpdateLayout()
    elseif PetActionBar_Update then
        PetActionBar_Update()
    end

    if not (InCombatLockdown and InCombatLockdown()) then
        local prev = nil
        for i = 1, 10 do
            local btn = _G["PetActionButton"..i]
            if btn then
                btn:ClearAllPoints()
                if not prev then
                    btn:SetPoint("TOPLEFT", petHost, "TOPLEFT", 0, 0)
                else
                    btn:SetPoint("LEFT", prev, "RIGHT", spacing, 0)
                end
                prev = btn
            end
        end
    end
    petHost:SetAlpha(1)
    local regions = petHost.GetRegions and { petHost:GetRegions() } or nil
    if regions then
        for _, region in ipairs(regions) do
            if region and region.IsObjectType and region:IsObjectType("Texture") then
                region:SetAlpha(0)
            end
        end
    end

    local function TunePetBox(box, themeColors)
        TuneCompactBox(box, themeColors, "petThinBorder", 4, 0.4)
    end

    for i = 1, 10 do
        local button = _G["PetActionButton"..i]
        if button then
            if InCombatLockdown and InCombatLockdown() and button:IsProtected() then
                -- Defer layout changes until out of combat
                if not button._muiDeferredPetUpdate then
                    button._muiDeferredPetUpdate = true
                    button:RegisterEvent("PLAYER_REGEN_ENABLED")
                    button:HookScript("OnEvent", function(self, evt)
                        if evt == "PLAYER_REGEN_ENABLED" then
                            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                            self._muiDeferredPetUpdate = false
                            BuildPetBar()
                        end
                    end)
                end
                return
            end
            if not petBarBoxes[i] then
                petBarBoxes[i] = CreateStyledPetBox(i, themeColors, boxSize)
            end
            local box = petBarBoxes[i]
            box:SetParent(petBarContainer)
            box:SetSize(boxSize, boxSize)
            ApplyActionBoxTheme(box, themeColors, boxSize)
            TunePetBox(box, themeColors)

            local row = math.floor((i - 1) / buttonsPerRow)
            local col = (i - 1) % buttonsPerRow

            if button.SetParent and (not InCombatLockdown or not InCombatLockdown()) then
                button:SetParent(petHost)
            end
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", petBarContainer, "TOPLEFT", col * (buttonSize + spacing), -row * (buttonSize + spacing))
            button:SetSize(buttonSize, buttonSize)
            if not button._muiDragHooked then
                button._muiDragHooked = true
                button:HookScript("OnDragStart", function()
                    if petBarContainer and petHost then
                        ApplyProtectedHostLayout(petHost, petBarContainer, containerWidth, containerHeight, "PetHostLayout")
                    end
                end)
                button:HookScript("OnDragStop", function()
                    if petBarContainer and petHost then
                        ApplyProtectedHostLayout(petHost, petBarContainer, containerWidth, containerHeight, "PetHostLayout")
                    end
                end)
            end

            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", petBarContainer, "TOPLEFT", col * (buttonSize + spacing) + (buttonSize - boxSize) / 2, -row * (buttonSize + spacing) - (buttonSize - boxSize) / 2)
            box:Show()

            StyleActionButton(button, box, i, nil, themeColors)
        end
    end

    SetOverlayContainerVisibility(petBarContainer, settings, true)
end

local function BuildStanceBar()
    local settings = EnsureStanceBarSettings()
    if not settings or settings.enabled == false then
        if stanceBarContainer then stanceBarContainer:Hide() end
        return
    end

    local numForms = GetNumShapeshiftForms and GetNumShapeshiftForms() or 0
    local buttonSize = settings.buttonSize or 32
    local boxSize = math_floor((buttonSize * 0.8) + 0.5)
    local spacing = settings.spacing or 4
    local buttonsPerRow = math_max(1, math_min(settings.buttonsPerRow or math_max(numForms, 1), 10))
    if numForms > 0 then
        buttonsPerRow = math_min(buttonsPerRow, numForms)
    end
    local previewCount = (numForms > 0) and numForms or buttonsPerRow
    local cols = math_min(buttonsPerRow, previewCount)
    local rows = math_ceil(previewCount / buttonsPerRow)
    local containerWidth = (buttonSize * cols) + (spacing * (cols - 1))
    local containerHeight = (buttonSize * rows) + (spacing * (rows - 1))
    if PlayerHasStanceClass() and OverlaysUnlocked() then
        stanceBarContainer = EnsureOverlayContainer(stanceBarContainer, "MyStanceBarContainer", settings, STANCE_DEFAULT_POSITION, "StanceBar", "STANCE BAR")
    end
    if numForms <= 0 then
        if stanceBarContainer then
            if PlayerHasStanceClass() and OverlaysUnlocked() and stanceBarContainer.dragOverlay then
                UpdateOverlayContainer(stanceBarContainer, containerWidth, containerHeight, settings)
                stanceBarContainer:Show()
                stanceBarContainer.dragOverlay:Show()
            else
                stanceBarContainer:Hide()
            end
        end
        return
    end

    local themeColors = GetActionBarTheme(GetConfig())
    local rows = math_ceil(numForms / buttonsPerRow)
    local containerWidth = (buttonSize * buttonsPerRow) + (spacing * (buttonsPerRow - 1))
    local containerHeight = (buttonSize * rows) + (spacing * (rows - 1))

    local stanceHost = _G.StanceBar or _G.StanceBarFrame
    if not stanceHost then
        if stanceBarContainer then stanceBarContainer:Hide() end
        return
    end

    if not stanceBarContainer then
        stanceBarContainer = EnsureOverlayContainer(stanceBarContainer, "MyStanceBarContainer", settings, STANCE_DEFAULT_POSITION, "StanceBar", "STANCE BAR")
        stanceBarContainer.dragOverlay:Hide()
    end

    UpdateOverlayContainer(stanceBarContainer, containerWidth, containerHeight, settings)

    ApplyProtectedHostLayout(stanceHost, stanceBarContainer, containerWidth, containerHeight, "StanceHostLayout")

    stanceHost:SetAlpha(1)
    local regions = stanceHost.GetRegions and { stanceHost:GetRegions() } or nil
    if regions then
        for _, region in ipairs(regions) do
            if region and region.IsObjectType and region:IsObjectType("Texture") then
                region:SetAlpha(0)
            end
        end
    end

    local function TuneStanceBox(box, themeColors)
        TuneCompactBox(box, themeColors, "stanceThinBorder", 3, 0.6)
    end

    local activeIdx = GetShapeshiftForm and GetShapeshiftForm() or 0

    for i = 1, numForms do
        local button = _G["StanceButton"..i]
        if button then
            if InCombatLockdown and InCombatLockdown() and button:IsProtected() then
                if not button._muiDeferredStanceUpdate then
                    button._muiDeferredStanceUpdate = true
                    button:RegisterEvent("PLAYER_REGEN_ENABLED")
                    button:HookScript("OnEvent", function(self, evt)
                        if evt == "PLAYER_REGEN_ENABLED" then
                            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
                            self._muiDeferredStanceUpdate = false
                            BuildStanceBar()
                        end
                    end)
                end
                return
            end
            if not stanceBarBoxes[i] then
                stanceBarBoxes[i] = CreateStyledPetBox(i, themeColors, boxSize)
            end
            local box = stanceBarBoxes[i]
            box:SetParent(stanceBarContainer)
            box:SetSize(boxSize, boxSize)
            ApplyActionBoxTheme(box, themeColors, boxSize)
            TuneStanceBox(box, themeColors)

            local row = math.floor((i - 1) / buttonsPerRow)
            local col = (i - 1) % buttonsPerRow

            if button.SetParent and (not InCombatLockdown or not InCombatLockdown()) then
                button:SetParent(stanceHost)
            end
            button:ClearAllPoints()
            button:SetPoint("TOPLEFT", stanceBarContainer, "TOPLEFT", col * (buttonSize + spacing), -row * (buttonSize + spacing))
            button:SetSize(buttonSize, buttonSize)

            box:ClearAllPoints()
            box:SetPoint("TOPLEFT", stanceBarContainer, "TOPLEFT", col * (buttonSize + spacing) + (buttonSize - boxSize) / 2, -row * (buttonSize + spacing) - (buttonSize - boxSize) / 2)
            box:Show()

            StyleActionButton(button, box, i, nil, themeColors)
            local isActive = (i == activeIdx)
            if box.stanceThinBorder and themeColors and themeColors.mainBorder then
                if isActive then
                    box.stanceThinBorder:SetColorTexture(1, 0.9, 0.1, 1.0)
                else
                    local r, g, b, a = unpack(themeColors.mainBorder)
                    box.stanceThinBorder:SetColorTexture(r, g, b, math.min(a or 1, 0.6))
                end
            end
            button:Show()
        end
    end

    for i = numForms + 1, 10 do
        if stanceBarBoxes[i] then stanceBarBoxes[i]:Hide() end
    end

    stanceBarContainer:Show()
end

local function BuildAllActionBars()
    for barNum = 1, 8 do
        BuildActionBar(barNum)
    end
    BuildPetBar()
    BuildStanceBar()
end

-- =========================================================================
--  HIDDEN STYLE: CURSOR-DRAG VISIBILITY
--  Shows a border on "Hidden" styled boxes when dragging a spell/item/mount
-- =========================================================================

local hiddenDragActive = false

local function SetHiddenBoxesDragVisible(visible)
    if hiddenDragActive == visible then return end
    hiddenDragActive = visible
    for barNum = 1, 8 do
        local boxes = actionBarBoxes[barNum]
        if boxes then
            for i = 1, 12 do
                local box = boxes[i]
                if box and box._muiStyle == "Hidden" and box:IsShown() then
                    if visible then
                        if box.mainBorder then box.mainBorder:SetColorTexture(0.45, 0.75, 1.00, 0.55) end
                        if box.outerBorder then box.outerBorder:SetColorTexture(0.30, 0.55, 0.85, 0.35) end
                    else
                        if box.mainBorder then box.mainBorder:SetColorTexture(0, 0, 0, 0) end
                        if box.outerBorder then box.outerBorder:SetColorTexture(0, 0, 0, 0) end
                    end
                end
            end
        end
    end
end

local function CheckCursorForDrag()
    local cursorType = GetCursorInfo()
    if cursorType and (cursorType == "spell" or cursorType == "item" or cursorType == "mount"
        or cursorType == "macro" or cursorType == "companion" or cursorType == "petaction"
        or cursorType == "flyout" or cursorType == "equipmentset" or cursorType == "toybox") then
        SetHiddenBoxesDragVisible(true)
    else
        SetHiddenBoxesDragVisible(false)
    end
end

local hiddenDragWatcher = CreateFrame("Frame")
hiddenDragWatcher:SetScript("OnEvent", function()
    CheckCursorForDrag()
end)
pcall(function() hiddenDragWatcher:RegisterEvent("CURSOR_CHANGED") end)

function MyActionBars_ResetToDefaults()
    if not MidnightUISettings or not MidnightUISettings.ActionBars then return end

    for barNum = 1, 8 do
        local key = "bar"..barNum
        if MidnightUISettings.ActionBars[key] then
            MidnightUISettings.ActionBars[key].position = nil
        end
    end

    for barNum = 1, 8 do
        local container = actionBarContainers[barNum]
        local pos = DEFAULT_POSITIONS[barNum]
        if container and pos then
            if IsInCombat() then
                QueueProtectedLayout("ActionBarReset"..barNum, function()
                    ApplySavedPoint(container, nil, pos)
                end)
            else
                ApplySavedPoint(container, nil, pos)
            end
        end
    end

    BuildAllActionBars()
end

-- =========================================================================
--  RELOAD SETTINGS (CALLED FROM SETTINGS PANEL)
-- =========================================================================

function MyActionBars_ReloadSettings()
    C_Timer.After(0.1, function()
        BuildAllActionBars()
    end)
end

function MyActionBars_ReloadSettingsImmediate()
    BuildAllActionBars()
end

-- =========================================================================
--  LOCK/UNLOCK FUNCTION (CALLED FROM SETTINGS PANEL)
-- =========================================================================

function MyActionBars_SetLocked(locked)
    for barNum = 1, 8 do
        local container = actionBarContainers[barNum]
        if container and container:IsShown() then
            if locked then
                container:EnableMouse(false)
                container:SetMovable(true)
                container:RegisterForDrag()
                
                if container.dragOverlay then
                    container.dragOverlay:Hide()
                end
            else
                container:EnableMouse(true)
                container:SetMovable(true)
                container:RegisterForDrag("LeftButton")
                
                if not container.dragOverlay then
                    local overlay = CreateFrame("Frame", nil, container, "BackdropTemplate")
                    overlay:SetAllPoints()
                    overlay:SetFrameStrata("HIGH")
                    overlay:SetBackdrop({
                        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                        tile = true, tileSize = 16, edgeSize = 16,
                        insets = { left = 4, right = 4, top = 4, bottom = 4 }
                    })
                    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
                    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
                    if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "bars") end
                    
                    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                    label:SetPoint("CENTER")
                    label:SetText("ACTION BAR " .. barNum)
                    label:SetTextColor(0.85, 0.90, 1.00)
                    label:SetShadowOffset(2, -2)
                    label:SetShadowColor(0, 0, 0, 1)
                    
                    overlay:EnableMouse(true)
                    overlay:RegisterForDrag("LeftButton")
                    overlay:SetScript("OnDragStart", function(self)
                        container:StartMoving()
                    end)
                    overlay:SetScript("OnDragStop", function(self)
                        container:StopMovingOrSizing()
                        local point, _, relativePoint, xOfs, yOfs = container:GetPoint()
                        MidnightUI_SetActionBarSetting("bar"..barNum, {
                            enabled = MidnightUISettings.ActionBars["bar"..barNum].enabled,
                            rows = MidnightUISettings.ActionBars["bar"..barNum].rows,
                            iconsPerRow = MidnightUISettings.ActionBars["bar"..barNum].iconsPerRow,
                            scale = MidnightUISettings.ActionBars["bar"..barNum].scale,
                            spacing = MidnightUISettings.ActionBars["bar"..barNum].spacing,
                            position = { point, relativePoint, xOfs, yOfs }
                        })
                    end)
                    if _G.MidnightUI_AttachOverlaySettings then
                        _G.MidnightUI_AttachOverlaySettings(overlay, "ActionBar" .. tostring(barNum))
                    end
                    
                    container.dragOverlay = overlay
                end
                
                container.dragOverlay:Show()
            end
        end
    end
end

function MidnightUI_SetPetBarLocked(locked)
    if not petBarContainer or not petBarContainer.dragOverlay then return end
    if not PlayerHasPetClass() then
        petBarContainer.dragOverlay:Hide()
        return
    end
    if locked then
        petBarContainer.dragOverlay:Hide()
    else
        petBarContainer.dragOverlay:Show()
    end
end

function MidnightUI_SetStanceBarLocked(locked)
    if not stanceBarContainer or not stanceBarContainer.dragOverlay then return end
    if not PlayerHasStanceClass() then
        stanceBarContainer.dragOverlay:Hide()
        return
    end
    if locked then
        stanceBarContainer.dragOverlay:Hide()
    else
        stanceBarContainer.dragOverlay:Show()
    end
end

-- =========================================================================
--  INITIALIZATION & EVENT HANDLING
-- =========================================================================

-- =========================================================================
--  OVERLAY SETTINGS
-- =========================================================================

local function ReloadActionBars()
    if _G.MyActionBars_ReloadSettingsImmediate then
        _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then
        _G.MyActionBars_ReloadSettings()
    end
end

local function BuildActionBarOverlaySettings(content, key)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local barNum = tonumber(string.match(tostring(key), "^ActionBar(%d+)$"))
    if not barNum then return end
    if not MidnightUISettings.ActionBars then MidnightUISettings.ActionBars = {} end
    MidnightUISettings.ActionBars["bar"..barNum] = MidnightUISettings.ActionBars["bar"..barNum] or {}
    local s = MidnightUISettings.ActionBars["bar"..barNum]
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Settings")
    b:Checkbox("Enable This Bar", s.enabled ~= false, function(v)
        s.enabled = v
        ReloadActionBars()
    end)
    b:Slider("Rows", 1, 12, 1, s.rows or 1, function(v)
        s.rows = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Icons Per Row", 1, 12, 1, s.iconsPerRow or 12, function(v)
        s.iconsPerRow = math.floor(v)
        ReloadActionBars()
    end)
    b:Dropdown("Per-Bar Style", {"Class Color", "Faithful", "Glass", "Hidden"}, s.style or "Class Color", function(v)
        s.style = v
        if MidnightUISettings.ActionBars.globalStyle and MidnightUISettings.ActionBars.globalStyle ~= "Disabled" then
            MidnightUISettings.ActionBars.globalStyle = "Disabled"
        end
        ReloadActionBars()
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        s.scale = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Spacing", 0, 30, 1, s.spacing or 6, function(v)
        s.spacing = math.floor(v)
        ReloadActionBars()
    end)
    return b:Height()
end

local function BuildPetBarOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    local s = MidnightUISettings.PetBar
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Settings")
    b:Checkbox("Enable Pet Bar", s.enabled ~= false, function(v)
        s.enabled = v
        ReloadActionBars()
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        s.scale = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        s.alpha = v
        ReloadActionBars()
    end)
    b:Slider("Button Size", 20, 56, 1, s.buttonSize or 32, function(v)
        s.buttonSize = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Spacing", 0, 30, 1, s.spacing or 15, function(v)
        s.spacing = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Per Row", 1, 10, 1, s.buttonsPerRow or 10, function(v)
        s.buttonsPerRow = math.floor(v)
        ReloadActionBars()
    end)
    return b:Height()
end

local function BuildStanceBarOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    local s = MidnightUISettings.StanceBar
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Settings")
    b:Checkbox("Enable Stance Bar", s.enabled ~= false, function(v)
        s.enabled = v
        ReloadActionBars()
    end)
    b:Slider("Scale %", 50, 200, 5, s.scale or 100, function(v)
        s.scale = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Opacity", 0.1, 1.0, 0.05, s.alpha or 1.0, function(v)
        s.alpha = v
        ReloadActionBars()
    end)
    b:Slider("Button Size", 20, 56, 1, s.buttonSize or 32, function(v)
        s.buttonSize = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Spacing", -6, 30, 1, s.spacing or 4, function(v)
        s.spacing = math.floor(v)
        ReloadActionBars()
    end)
    b:Slider("Per Row", 1, 4, 1, s.buttonsPerRow or 3, function(v)
        s.buttonsPerRow = math.floor(v)
        ReloadActionBars()
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    for i = 1, 8 do
        _G.MidnightUI_RegisterOverlaySettings("ActionBar"..i, { title = "Action Bar "..i, build = BuildActionBarOverlaySettings })
    end
    _G.MidnightUI_RegisterOverlaySettings("PetBar", { title = "Pet Bar", build = BuildPetBarOverlaySettings })
    _G.MidnightUI_RegisterOverlaySettings("StanceBar", { title = "Stance Bar", build = BuildStanceBarOverlaySettings })
end

local initialized = false

ActionBarManager:RegisterEvent("ADDON_LOADED")
ActionBarManager:RegisterEvent("PLAYER_ENTERING_WORLD")
ActionBarManager:RegisterEvent("PET_BAR_UPDATE")
ActionBarManager:RegisterEvent("UNIT_PET")
ActionBarManager:RegisterEvent("UPDATE_SHAPESHIFT_FORMS")
ActionBarManager:RegisterEvent("UPDATE_SHAPESHIFT_FORM")
ActionBarManager:RegisterEvent("UPDATE_BINDINGS")
ActionBarManager:RegisterEvent("ACTIONBAR_SLOT_CHANGED")

ActionBarManager:SetScript("OnEvent", function(self, event, addon)
    if event == "ADDON_LOADED" and addon == ADDON_NAME then
        C_Timer.After(0.1, HideBlizzardActionBarArt)
    elseif event == "PLAYER_REGEN_ENABLED" then
        FlushProtectedLayouts()
    elseif event == "PLAYER_ENTERING_WORLD" and not initialized then
        initialized = true

        C_Timer.After(0.2, function()
            HideBlizzardActionBarArt()
            BuildAllActionBars()

            if MidnightUI_GetActionBarSettings then
                local config = MidnightUI_GetActionBarSettings()
                for barNum = 1, 8 do
                    local barConfig = config["bar"..barNum]
                    if barConfig and barConfig.position and actionBarContainers[barNum] then
                        local container = actionBarContainers[barNum]
                        local p = barConfig.position
                        if IsInCombat() then
                            QueueProtectedLayout("ActionBarRestore"..barNum, function()
                                ApplySavedPoint(container, p, DEFAULT_POSITIONS[barNum])
                            end)
                        else
                            ApplySavedPoint(container, p, DEFAULT_POSITIONS[barNum])
                        end
                    end
                end
            end

            if MidnightUI_GetMessengerSettings then
                local settings = MidnightUI_GetMessengerSettings()
                MyActionBars_SetLocked(settings.locked)
                MidnightUI_SetPetBarLocked(settings.locked)
                MidnightUI_SetStanceBarLocked(settings.locked)
            end
        end)
    elseif event == "PET_BAR_UPDATE" or event == "UNIT_PET" then
        BuildPetBar()
    elseif event == "UPDATE_SHAPESHIFT_FORMS" or event == "UPDATE_SHAPESHIFT_FORM" then
        BuildStanceBar()
    elseif event == "UPDATE_BINDINGS" or event == "ACTIONBAR_SLOT_CHANGED" then
        if initialized then
            RefreshAllHotkeyText()
        end
    end
end)

-- Run a limited number of times at startup, then stop (no need to run forever)
C_Timer.NewTicker(2, HideBlizzardActionBarArt, 5)
-- Safety net: re-hide if Blizzard re-shows art after loading screens
local _abArtWatcher = CreateFrame("Frame")
_abArtWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
_abArtWatcher:SetScript("OnEvent", function() C_Timer.After(1, HideBlizzardActionBarArt) end)
