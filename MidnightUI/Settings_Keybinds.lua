--------------------------------------------------------------------------------
-- Settings_Keybinds.lua | MidnightUI
-- PURPOSE: Keybind-mode overlay system. When activated, transparent overlays
--          appear on every action button. Hovering a button and pressing a key
--          binds that key to the button's WoW binding command. Saves per-character.
-- DEPENDS ON: Settings.lua (MidnightUI_Settings namespace, MidnightUISettings table)
--             ActionBars.lua (button naming convention matching BAR_BUTTON_MAP)
-- EXPORTS (globals):
--   MidnightUI_EnterKeybindMode()  - Enters keybind mode (called from Settings_UI.lua)
-- ARCHITECTURE: Standalone keybind subsystem loaded after Settings.lua.
--   Creates a fullscreen key-capture frame at DIALOG strata. Overlays are
--   created lazily per button and cached in keybindOverlays[]. The HUD shows
--   status and a Done button. Bindings are saved via WoW's SaveBindings(2)
--   (character-specific).
--------------------------------------------------------------------------------

local M = MidnightUI_Settings

-- ============================================================================
-- BAR BUTTON MAP
-- Maps bar number (1-8) to the global button name prefix used by ActionBars.lua.
-- Must stay in sync with ActionBars.lua button creation.
-- ============================================================================
local BAR_BUTTON_MAP = {
    [1] = "ActionButton",
    [2] = "MultiBarBottomLeftButton",
    [3] = "MultiBarBottomRightButton",
    [4] = "MultiBarRightButton",
    [5] = "MultiBarLeftButton",
    [6] = "MultiBar5Button",
    [7] = "MultiBar6Button",
    [8] = "MultiBar7Button",
}

-- Ensure the Keybinds sub-table exists in saved variables.
if not MidnightUISettings.Keybinds then MidnightUISettings.Keybinds = {} end

-- ============================================================================
-- MODULE STATE
-- KeybindMode: true while keybind capture is active.
-- hoveredButton/BarNum/ButtonIndex: track which button the cursor is over.
-- keybindOverlays: cache of overlay frames keyed as "bar{N}_{I}" or "pet_{I}".
-- ============================================================================
local KeybindMode = false
local ExitKeybindMode
local hoveredButton = nil
local hoveredBarNum = nil
local hoveredButtonIndex = nil
local keybindOverlays = {}

-- ============================================================================
-- KEYBIND HUD
-- Floating instruction panel shown at the top of the screen during keybind mode.
-- Displays title, instructions, hover status, and a Done button.
-- ============================================================================
local KeybindHUD = CreateFrame("Frame", "MidnightUI_KeybindHUD", UIParent, "BackdropTemplate")
KeybindHUD:SetSize(380, 130); KeybindHUD:SetPoint("TOP", 0, -50); KeybindHUD:SetFrameStrata("DIALOG")
KeybindHUD:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
KeybindHUD:SetBackdropColor(0.1, 0.1, 0.1, 0.95); KeybindHUD:SetBackdropBorderColor(1, 0.6, 0, 1)
KeybindHUD:Hide()

local kbTitle = KeybindHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
kbTitle:SetPoint("TOP", 0, -15); kbTitle:SetText("Keybind Mode"); kbTitle:SetTextColor(1, 0.6, 0)

local kbInstr = KeybindHUD:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
kbInstr:SetPoint("TOP", kbTitle, "BOTTOM", 0, -8)
kbInstr:SetText("Hover over an action button and press a key to bind it.\nFor combos like Shift+1, hold Shift then press 1.")
kbInstr:SetTextColor(0.9, 0.9, 0.9)
kbInstr:SetJustifyH("CENTER")

local kbStatus = KeybindHUD:CreateFontString(nil, "OVERLAY", "GameFontNormal")
kbStatus:SetPoint("TOP", kbInstr, "BOTTOM", 0, -12)
kbStatus:SetText("Hovering: None"); kbStatus:SetTextColor(0.6, 0.6, 0.6)

local kbDone = CreateFrame("Button", nil, KeybindHUD, "GameMenuButtonTemplate")
kbDone:SetPoint("BOTTOM", 0, 15); kbDone:SetSize(140, 26); kbDone:SetText("Done")

--- GetKeybindString: Builds a modifier-prefixed key string (e.g. "SHIFT-1", "CTRL-ALT-F").
-- @param key (string) - Raw WoW key name from OnKeyDown
-- @return (string|nil) - Formatted bind string, or nil for standalone modifier keys
local function GetKeybindString(key)
    local modifiers = ""
    if IsShiftKeyDown() then modifiers = modifiers .. "SHIFT-" end
    if IsControlKeyDown() then modifiers = modifiers .. "CTRL-" end
    if IsAltKeyDown() then modifiers = modifiers .. "ALT-" end
    
    -- Ignore standalone modifier keys
    if key == "LSHIFT" or key == "RSHIFT" or key == "LCTRL" or key == "RCTRL" or key == "LALT" or key == "RALT" then
        return nil
    end
    
    return modifiers .. key
end

--- GetBindingCommand: Maps bar number + button index to a WoW binding command string.
-- @param barNum (number|"PET") - Bar number 1-8 or "PET" for pet bar
-- @param buttonIndex (number) - Button slot 1-12 (or 1-10 for pet)
-- @return (string|nil) - e.g. "ACTIONBUTTON1", "MULTIACTIONBAR1BUTTON3", "BONUSACTIONBUTTON5"
local function GetBindingCommand(barNum, buttonIndex)
    if barNum == 1 then
        return "ACTIONBUTTON" .. buttonIndex
    elseif barNum == 2 then
        return "MULTIACTIONBAR1BUTTON" .. buttonIndex
    elseif barNum == 3 then
        return "MULTIACTIONBAR2BUTTON" .. buttonIndex
    elseif barNum == 4 then
        return "MULTIACTIONBAR3BUTTON" .. buttonIndex
    elseif barNum == 5 then
        return "MULTIACTIONBAR4BUTTON" .. buttonIndex
    elseif barNum == 6 then
        return "MULTIACTIONBAR5BUTTON" .. buttonIndex
    elseif barNum == 7 then
        return "MULTIACTIONBAR6BUTTON" .. buttonIndex
    elseif barNum == 8 then
        return "MULTIACTIONBAR7BUTTON" .. buttonIndex
    elseif barNum == "PET" then
        return "BONUSACTIONBUTTON" .. buttonIndex
    end
    return nil
end

--- CreateKeybindOverlay: Creates a semi-transparent overlay frame on top of an action button.
--   Shows the current keybind or bar/button identifier. Highlights on hover.
-- @param button (Button) - The action button frame to overlay
-- @param barNum (number|"PET") - Bar number or "PET"
-- @param buttonIndex (number) - Button slot index
-- @return (Frame|nil) - The overlay frame, or nil if button is nil
local function CreateKeybindOverlay(button, barNum, buttonIndex)
    if not button then return nil end
    
    local overlay = CreateFrame("Frame", nil, button, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("TOOLTIP")
    overlay:EnableMouse(true)
    overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 8 })
    overlay:SetBackdropColor(0, 0, 0, 0.7)
    overlay:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    
    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER", 0, 0)
    label:SetText(barNum .. "-" .. buttonIndex)
    label:SetTextColor(0.7, 0.7, 0.7)
    overlay.label = label
    overlay.label:SetAlpha(1)
    overlay.label._muiFlash = overlay.label:CreateAnimationGroup()
    local fadeIn = overlay.label._muiFlash:CreateAnimation("Alpha")
    fadeIn:SetFromAlpha(0.2)
    fadeIn:SetToAlpha(1)
    fadeIn:SetDuration(0.25)
    fadeIn:SetSmoothing("IN")
    
    overlay.barNum = barNum
    overlay.buttonIndex = buttonIndex
    
    overlay:SetScript("OnEnter", function(self)
        if KeybindMode then
            hoveredButton = button
            hoveredBarNum = self.barNum
            hoveredButtonIndex = self.buttonIndex
            self:SetBackdropBorderColor(1, 0.6, 0, 1)
            self:SetBackdropColor(0.2, 0.1, 0, 0.8)
            if self.barNum == "PET" then
                kbStatus:SetText("Hovering: Pet Button " .. self.buttonIndex)
            else
                kbStatus:SetText("Hovering: Bar " .. self.barNum .. " Button " .. self.buttonIndex)
            end
            kbStatus:SetTextColor(1, 0.6, 0)
        end
    end)
    
    overlay:SetScript("OnLeave", function(self)
        if KeybindMode then
            hoveredButton = nil
            hoveredBarNum = nil
            hoveredButtonIndex = nil
            self:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
            self:SetBackdropColor(0, 0, 0, 0.7)
            kbStatus:SetText("Hovering: None")
            kbStatus:SetTextColor(0.6, 0.6, 0.6)
        end
    end)
    
    overlay:Hide()
    return overlay
end

--- GetBindingDisplay: Returns the current keybind text for a command, or fallback if unbound.
-- @param command (string) - WoW binding command string
-- @param fallback (string) - Text to show if no key is bound
-- @return (string) - Current binding key or fallback
local function GetBindingDisplay(command, fallback)
    if not command or not GetBindingKey then return fallback end
    local key = GetBindingKey(command)
    if key and key ~= "" then return key end
    return fallback
end

--- CommandToOverlayKey: Converts a WoW binding command back to its keybindOverlays[] key.
-- @param command (string) - e.g. "ACTIONBUTTON1" or "BONUSACTIONBUTTON3"
-- @return (string|nil) - e.g. "bar1_1" or "pet_3", nil if unrecognized
local function CommandToOverlayKey(command)
    if not command or command == "" then return nil end
    local idx = command:match("^ACTIONBUTTON(%d+)$")
    if idx then return "bar1_" .. idx end
    idx = command:match("^MULTIACTIONBAR1BUTTON(%d+)$")
    if idx then return "bar2_" .. idx end
    idx = command:match("^MULTIACTIONBAR2BUTTON(%d+)$")
    if idx then return "bar3_" .. idx end
    idx = command:match("^MULTIACTIONBAR3BUTTON(%d+)$")
    if idx then return "bar4_" .. idx end
    idx = command:match("^MULTIACTIONBAR4BUTTON(%d+)$")
    if idx then return "bar5_" .. idx end
    idx = command:match("^MULTIACTIONBAR5BUTTON(%d+)$")
    if idx then return "bar6_" .. idx end
    idx = command:match("^MULTIACTIONBAR6BUTTON(%d+)$")
    if idx then return "bar7_" .. idx end
    idx = command:match("^MULTIACTIONBAR7BUTTON(%d+)$")
    if idx then return "bar8_" .. idx end
    idx = command:match("^BONUSACTIONBUTTON(%d+)$")
    if idx then return "pet_" .. idx end
    return nil
end

--- FlashOverlayLabel: Briefly color-flashes an overlay label to give visual feedback.
-- @param overlay (Frame) - Overlay with .label FontString and .label._muiFlash AnimationGroup
-- @param r,g,b (number) - Flash color
local function FlashOverlayLabel(overlay, r, g, b)
    if not overlay or not overlay.label then return end
    overlay.label:SetTextColor(r, g, b)
    if overlay.label._muiFlash then
        overlay.label._muiFlash:Stop()
        overlay.label._muiFlash:Play()
    end
end

--- RefreshKeybindOverlayText: Updates the display text on all overlays to show current bindings.
--   Bound keys show in cyan; unbound slots show the bar/button fallback in grey.
local function RefreshKeybindOverlayText()
    for barNum = 1, 8 do
        for i = 1, 12 do
            local key = "bar" .. barNum .. "_" .. i
            local overlay = keybindOverlays[key]
            if overlay then
                local cmd = GetBindingCommand(barNum, i)
                local display = GetBindingDisplay(cmd, barNum .. "-" .. i)
                overlay.label:SetText(display)
                overlay.label:SetTextColor(display == (barNum .. "-" .. i) and 0.7 or 0, display == (barNum .. "-" .. i) and 0.7 or 0.8, display == (barNum .. "-" .. i) and 0.7 or 1)
            end
        end
    end
    for i = 1, 10 do
        local key = "pet_" .. i
        local overlay = keybindOverlays[key]
        if overlay then
            local cmd = "BONUSACTIONBUTTON" .. i
            local display = GetBindingDisplay(cmd, "P-" .. i)
            overlay.label:SetText(display)
            overlay.label:SetTextColor(display == ("P-" .. i) and 0.7 or 0, display == ("P-" .. i) and 0.7 or 0.8, display == ("P-" .. i) and 0.7 or 1)
        end
    end
end

--- ShowKeybindOverlays: Creates (if needed) and shows overlays on all action bar + pet bar buttons.
--   Lazy-creates overlays into keybindOverlays[] on first use.
local function ShowKeybindOverlays()
    if not MidnightUISettings.Keybinds then MidnightUISettings.Keybinds = {} end
    
    for barNum = 1, 8 do
        local prefix = BAR_BUTTON_MAP[barNum]
        if prefix then
            for i = 1, 12 do
                local button = _G[prefix .. i]
                if button then
                    local key = "bar" .. barNum .. "_" .. i
                    if not keybindOverlays[key] then
                        keybindOverlays[key] = CreateKeybindOverlay(button, barNum, i)
                    end
                    if keybindOverlays[key] then
                        local cmd = GetBindingCommand(barNum, i)
                        local display = GetBindingDisplay(cmd, barNum .. "-" .. i)
                        keybindOverlays[key].label:SetText(display)
                        if display == (barNum .. "-" .. i) then
                            keybindOverlays[key].label:SetTextColor(0.7, 0.7, 0.7)
                        else
                            keybindOverlays[key].label:SetTextColor(0, 0.8, 1)
                        end
                        keybindOverlays[key]:Show()
                    end
                end
            end
        end
    end

    -- Pet bar buttons
    for i = 1, 10 do
        local button = _G["PetActionButton"..i]
        if button then
            local key = "pet_" .. i
            if not keybindOverlays[key] then
                keybindOverlays[key] = CreateKeybindOverlay(button, "PET", i)
            end
            if keybindOverlays[key] then
                local cmd = "BONUSACTIONBUTTON" .. i
                local display = GetBindingDisplay(cmd, "P-" .. i)
                keybindOverlays[key].label:SetText(display)
                if display == ("P-" .. i) then
                    keybindOverlays[key].label:SetTextColor(0.7, 0.7, 0.7)
                else
                    keybindOverlays[key].label:SetTextColor(0, 0.8, 1)
                end
                keybindOverlays[key]:Show()
            end
        end
    end
end

--- HideKeybindOverlays: Hides all cached overlay frames.
local function HideKeybindOverlays()
    for key, overlay in pairs(keybindOverlays) do
        if overlay then overlay:Hide() end
    end
end

-- ============================================================================
-- KEY CAPTURE FRAME
-- Fullscreen invisible frame at DIALOG strata that captures keyboard input.
-- OnKeyDown: if a button is hovered, binds the pressed key to that button.
-- Escape exits keybind mode. Standalone modifier keys are ignored.
-- ============================================================================
local KeyCaptureFrame = CreateFrame("Frame", "MidnightUI_KeyCapture", UIParent)
KeyCaptureFrame:SetAllPoints(UIParent)
KeyCaptureFrame:SetFrameStrata("DIALOG")
KeyCaptureFrame:SetFrameLevel(1000)
KeyCaptureFrame:EnableKeyboard(true)
KeyCaptureFrame:SetPropagateKeyboardInput(true)
KeyCaptureFrame:Hide()

KeyCaptureFrame:SetScript("OnKeyDown", function(self, key)
    if not KeybindMode then return end

    if key == "ESCAPE" then
        ExitKeybindMode()
        return
    end

    if not hoveredButton or not hoveredBarNum or not hoveredButtonIndex then return end
    
    local keybindStr = GetKeybindString(key)
    if not keybindStr then return end -- Ignore standalone modifiers
    
    -- Get binding command
    local command = GetBindingCommand(hoveredBarNum, hoveredButtonIndex)
    if not command then return end
    
    -- Clear any existing binding for this key
    local oldBinding1, oldBinding2 = GetBindingKey(command)
    if oldBinding1 then SetBinding(oldBinding1) end
    if oldBinding2 then SetBinding(oldBinding2) end

    -- Clear any existing action bound to this key (global unbind)
    local prevCommand = GetBindingAction and GetBindingAction(keybindStr) or nil
    SetBinding(keybindStr)

    -- Remove any saved MidnightUI key that already uses this keybind
    if MidnightUISettings.Keybinds then
        for savedKey, savedBind in pairs(MidnightUISettings.Keybinds) do
            if savedBind == keybindStr then
                MidnightUISettings.Keybinds[savedKey] = nil
            end
        end
    end
    
    -- Set new binding
    local success = SetBinding(keybindStr, command)
    
    if success then
        -- Ensure Keybinds table exists
        if not MidnightUISettings.Keybinds then MidnightUISettings.Keybinds = {} end
        
        -- Save to our settings
        local key
        if hoveredBarNum == "PET" then
            key = "pet_" .. hoveredButtonIndex
        else
            key = "bar" .. hoveredBarNum .. "_" .. hoveredButtonIndex
        end
        MidnightUISettings.Keybinds[key] = keybindStr
        
        -- Update overlay display for all buttons
        RefreshKeybindOverlayText()
        if prevCommand then
            local prevKey = CommandToOverlayKey(prevCommand)
            local prevOverlay = prevKey and keybindOverlays[prevKey] or nil
            if prevOverlay then
                FlashOverlayLabel(prevOverlay, 1, 0.2, 0.2)
            end
        end
        local newOverlay = keybindOverlays[key]
        if newOverlay then
            FlashOverlayLabel(newOverlay, 0.2, 1, 0.2)
        end
        
        -- Flash feedback
        if hoveredBarNum == "PET" then
            kbStatus:SetText("Set: " .. keybindStr .. " -> Pet Btn " .. hoveredButtonIndex)
        else
            kbStatus:SetText("Set: " .. keybindStr .. " -> Bar " .. hoveredBarNum .. " Btn " .. hoveredButtonIndex)
        end
        kbStatus:SetTextColor(0, 1, 0)
        
        -- Save bindings to character
        SaveBindings(2) -- 2 = Character-specific
        if _G.MidnightUI_RefreshPetBarHotkeys then
            _G.MidnightUI_RefreshPetBarHotkeys()
        end
        
        if hoveredBarNum == "PET" then
            print("|cff00ccffMidnight UI:|r Bound |cffFFFF00" .. keybindStr .. "|r to Pet Button " .. hoveredButtonIndex)
        else
            print("|cff00ccffMidnight UI:|r Bound |cffFFFF00" .. keybindStr .. "|r to Action Bar " .. hoveredBarNum .. " Button " .. hoveredButtonIndex)
        end
    else
        kbStatus:SetText("Failed to bind: " .. keybindStr)
        kbStatus:SetTextColor(1, 0, 0)
    end
    
    -- Consume the key during keybind mode
    self:SetPropagateKeyboardInput(false)
end)

--- EnterKeybindMode: Activates keybind mode. Shows overlays, HUD, and key capture frame.
--   Closes the settings panel to avoid interaction conflicts.
local function EnterKeybindMode()
    KeybindMode = true
    ShowKeybindOverlays()
    KeybindHUD:Show()
    KeyCaptureFrame:Show()
    KeyCaptureFrame:SetPropagateKeyboardInput(false)
    
    -- Close settings panel
    if SettingsPanel then SettingsPanel:Hide() 
    elseif InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
end

--- ExitKeybindMode: Deactivates keybind mode. Hides overlays and HUD, reopens settings.
ExitKeybindMode = function()
    KeybindMode = false
    HideKeybindOverlays()
    KeybindHUD:Hide()
    KeyCaptureFrame:SetPropagateKeyboardInput(true)
    KeyCaptureFrame:Hide()
    hoveredButton = nil
    hoveredBarNum = nil
    hoveredButtonIndex = nil
    
    -- Reopen settings panel
    local cat = M and M.SettingsCategory or nil
    if cat and Settings and Settings.OpenToCategory then 
        Settings.OpenToCategory(cat.ID)
    elseif SettingsPanel then SettingsPanel:Show() 
    elseif InterfaceOptionsFrame then InterfaceOptionsFrame:Show() end
end

kbDone:SetScript("OnClick", ExitKeybindMode)

--- MidnightUI_EnterKeybindMode: Global entry point for keybind mode.
-- @calledby Settings_UI.lua "Edit Keybinds" button
function MidnightUI_EnterKeybindMode()
    EnterKeybindMode()
end

-- =========================================================================
