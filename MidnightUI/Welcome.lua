--------------------------------------------------------------------------------
-- Welcome.lua | MidnightUI
-- PURPOSE: Three-step setup wizard for new users. Step 1: profile import or
--          fresh start. Step 2: playstyle tuning with Simple/Expert modes and
--          live previews. Step 3: community links (Discord/Patreon) and finish.
-- DEPENDS ON: MidnightUI_Profiles (profile import/export, welcome-seen flag),
--             MidnightUI_Settings (apply functions for every UI subsystem),
--             MidnightUI_Core (InitModules), MidnightUI_Diagnostics (logging),
--             MidnightUI_StyleOverlay / overlay system (movement mode)
-- EXPORTS: MidnightUI_ShowWelcome(force) - opens the wizard,
--          MidnightUI_TryShowWelcome() - opens only if not yet seen,
--          MidnightUI_ReturnToWelcomeWizard() - returns from preview mode,
--          MidnightUI_ShowProfileImport(onImported) - opens import dialog,
--          MidnightUI_ShowProfileExport() - opens export dialog,
--          MidnightUI_OpenURL(url) - shows a copy-to-clipboard URL prompt,
--          MidnightUI_WelcomeExitPreview - global ref to exit preview closure
-- ARCHITECTURE: Self-contained DIALOG-strata wizard. Creates all frames lazily
--               on first show. The wizard writes directly into MidnightUISettings
--               (the global saved-variables table) and calls Apply* functions
--               from MidnightUI_Settings to push changes live. Profile presets
--               ("MidnightUI", "Raid Focused", "Mythic+", "Class Themed") set
--               comprehensive defaults for every subsystem. The wizard also
--               supports a "preview mode" that hides the wizard and shows a
--               return-to-setup dock so the user can test changes in-world.
--------------------------------------------------------------------------------

-- ============================================================================
-- UPVALUES AND CONSTANTS
-- Local references to globals for performance in OnUpdate and tight loops.
-- ============================================================================
local _G = _G
local CreateFrame = CreateFrame
local UIParent = UIParent
local C_Timer = C_Timer
local date = date
local math = math
local pcall = pcall
local tostring = tostring
local type = type
local pairs = pairs
local ipairs = ipairs

--- Profiles: Reference to the MidnightUI_Profiles module which handles
--  per-character saved settings, import/export, and the "welcome seen" flag.
local Profiles = _G.MidnightUI_Profiles

local CURSEFORGE_URL = "https://www.curseforge.com/wow/addons/midnightui-midnight-ready"
local DISCORD_URL = "https://discord.gg/3AV6yUaYQ9"
local MPI_COMPANION_URL = "https://mpi.atyzi.com"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"

--- UI_COLORS: Shared color palette for every frame built by this file.
--  Each entry is an {R, G, B} table (0-1 range). Used for backdrops, text,
--  borders, and accent highlights throughout the wizard.
local UI_COLORS = {
    bg = {0.05, 0.06, 0.11},
    panel = {0.075, 0.09, 0.15},
    inset = {0.08, 0.10, 0.17},
    border = {0.18, 0.22, 0.30},
    text = {0.92, 0.93, 0.96},
    muted = {0.58, 0.60, 0.65},
    accent = {0.00, 0.78, 1.00},
    accentDim = {0.00, 0.45, 0.62},
    success = {0.35, 0.88, 0.62},
    warning = {1.00, 0.72, 0.25},
}

-- ============================================================================
-- UTILITY FUNCTIONS
-- Logging, safe-calling, font helpers, and button styling used throughout.
-- ============================================================================

--- Log: Sends a debug message through the Diagnostics system or fallback.
-- @param msg (string) - Message to log, auto-prefixed with "[Welcome]"
-- @calls MidnightUI_Diagnostics.LogDebugSource or MidnightUI_Debug
local function Log(msg)
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
        _G.MidnightUI_Diagnostics.LogDebugSource("Welcome", msg)
        return
    end
    if _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("[Welcome] " .. tostring(msg))
    end
end

--- SafeCall: pcall wrapper that logs failures via Log().
-- @param tag (string) - Label for the call, used in error messages
-- @param fn (function|nil) - Function to call; no-ops if nil or non-function
-- @param ... - Arguments forwarded to fn
-- @return (bool) - true if fn executed without error
local function SafeCall(tag, fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, err = pcall(fn, ...)
    if not ok then
        Log(tag .. " failed: " .. tostring(err))
    end
    return ok
end

--- TrySetFont: Safely sets a FontString's font face, size, and flags.
-- @param fs (FontString|nil) - Target font string object
-- @param size (number) - Font size in points (default 12)
-- @param flags (string) - Font flags like "OUTLINE" (default "")
local function TrySetFont(fs, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, TITLE_FONT, size or 12, flags or "")
end

--- StyleButton: Applies MidnightUI's shared button styling to a Button frame.
-- @param btn (Button|nil) - The button to style
-- @calls MidnightUI_Settings.StyleSettingsButton
local function StyleButton(btn)
    if not btn then return end
    if _G.MidnightUI_Settings and _G.MidnightUI_Settings.StyleSettingsButton then
        _G.MidnightUI_Settings.StyleSettingsButton(btn)
    end
end

-- ============================================================================
-- SETTINGS INITIALIZATION
-- Bootstraps the global MidnightUISettings saved-variable table with default
-- values for every subsystem. Called before any preset or user change.
-- ============================================================================

--- EnsureSettings: Guarantees all subtables and default values exist inside
--  MidnightUISettings. Also runs a one-time migration that fixes legacy
--  debuff overlay defaults where all flags were incorrectly set to false.
-- @return (table) - Reference to the fully-initialized MidnightUISettings
-- @note MidnightUISettings is a SavedVariable persisted across sessions.
--       Shape (top-level keys):
--       { General, Messenger, ActionBars, Minimap, PlayerFrame, TargetFrame,
--         FocusFrame, PetFrame, PartyFrames, Combat, Nameplates, RaidFrames,
--         MainTankFrames, CastBars, ConsumableBars, PetBar, StanceBar }
local function EnsureSettings()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    local s = _G.MidnightUISettings
    s.General = s.General or {}
    s.Messenger = s.Messenger or {}
    s.ActionBars = s.ActionBars or {}
    s.Minimap = s.Minimap or {}
    s.PlayerFrame = s.PlayerFrame or {}
    s.PlayerFrame.auras = s.PlayerFrame.auras or {}
    s.PlayerFrame.debuffs = s.PlayerFrame.debuffs or {}
    s.TargetFrame = s.TargetFrame or {}
    s.TargetFrame.auras = s.TargetFrame.auras or {}
    s.TargetFrame.debuffs = s.TargetFrame.debuffs or {}
    s.FocusFrame = s.FocusFrame or {}
    s.PetFrame = s.PetFrame or {}
    s.PartyFrames = s.PartyFrames or {}
    if s.PartyFrames.hideInRaid == nil then s.PartyFrames.hideInRaid = false end
    s.Combat = s.Combat or {}
    if s.Combat.debuffOverlayGlobalEnabled == nil then s.Combat.debuffOverlayGlobalEnabled = true end
    if s.Combat.debuffOverlayPlayerEnabled == nil then s.Combat.debuffOverlayPlayerEnabled = true end
    if s.Combat.debuffOverlayFocusEnabled == nil then s.Combat.debuffOverlayFocusEnabled = true end
    if s.Combat.debuffOverlayPartyEnabled == nil then s.Combat.debuffOverlayPartyEnabled = true end
    if s.Combat.debuffOverlayRaidEnabled == nil then s.Combat.debuffOverlayRaidEnabled = true end
    if s.Combat.debuffOverlayTargetOfTargetEnabled == nil then s.Combat.debuffOverlayTargetOfTargetEnabled = true end
    -- Legacy migration: early versions shipped with all debuff overlays disabled
    -- by default. This one-time pass detects that state and resets to enabled.
    if s.Combat.debuffOverlayDefaultMigrationApplied ~= true then
        local legacyAllDisabled =
            s.Combat.debuffOverlayGlobalEnabled == false and
            s.Combat.debuffOverlayPlayerEnabled == false and
            s.Combat.debuffOverlayFocusEnabled == false and
            s.Combat.debuffOverlayPartyEnabled == false and
            s.Combat.debuffOverlayRaidEnabled == false and
            s.Combat.debuffOverlayTargetOfTargetEnabled == false
        local legacyGlobalOnlyDisabled =
            s.Combat.debuffOverlayGlobalEnabled == false and
            s.Combat.debuffOverlayPlayerEnabled ~= false and
            s.Combat.debuffOverlayFocusEnabled ~= false and
            s.Combat.debuffOverlayPartyEnabled ~= false and
            s.Combat.debuffOverlayRaidEnabled ~= false and
            s.Combat.debuffOverlayTargetOfTargetEnabled ~= false
        if legacyAllDisabled then
            s.Combat.debuffOverlayGlobalEnabled = true
            s.Combat.debuffOverlayPlayerEnabled = true
            s.Combat.debuffOverlayFocusEnabled = true
            s.Combat.debuffOverlayPartyEnabled = true
            s.Combat.debuffOverlayRaidEnabled = true
            s.Combat.debuffOverlayTargetOfTargetEnabled = true
        elseif legacyGlobalOnlyDisabled then
            s.Combat.debuffOverlayGlobalEnabled = true
        end
        s.Combat.debuffOverlayDefaultMigrationApplied = true
    end
    s.Nameplates = s.Nameplates or {}
    s.Nameplates.healthBar = s.Nameplates.healthBar or {}
    s.Nameplates.threatBar = s.Nameplates.threatBar or {}
    s.Nameplates.castBar = s.Nameplates.castBar or {}
    s.Nameplates.target = s.Nameplates.target or {}
    s.Nameplates.target.healthBar = s.Nameplates.target.healthBar or {}
    s.Nameplates.target.threatBar = s.Nameplates.target.threatBar or {}
    s.Nameplates.target.castBar = s.Nameplates.target.castBar or {}
    s.RaidFrames = s.RaidFrames or {}
    s.MainTankFrames = s.MainTankFrames or {}
    s.CastBars = s.CastBars or {}
    s.CastBars.player = s.CastBars.player or {}
    s.CastBars.target = s.CastBars.target or {}
    s.CastBars.focus = s.CastBars.focus or {}
    if s.CastBars.player.matchFrameWidth == nil then s.CastBars.player.matchFrameWidth = true end
    if s.CastBars.target.matchFrameWidth == nil then s.CastBars.target.matchFrameWidth = true end
    if s.CastBars.focus.matchFrameWidth == nil then s.CastBars.focus.matchFrameWidth = false end
    s.ConsumableBars = s.ConsumableBars or {}
    s.PetBar = s.PetBar or {}
    s.StanceBar = s.StanceBar or {}
    for i = 1, 8 do
        local key = "bar" .. i
        s.ActionBars[key] = s.ActionBars[key] or {}
        if s.ActionBars[key].enabled == nil then s.ActionBars[key].enabled = true end
        if not s.ActionBars[key].style then s.ActionBars[key].style = "Class Color" end
    end
    if s.ActionBars.globalStyle == nil then s.ActionBars.globalStyle = "Disabled" end
    if s.ConsumableBars.enabled == nil then s.ConsumableBars.enabled = true end
    if s.PetBar.enabled == nil then s.PetBar.enabled = true end
    if s.StanceBar.enabled == nil then s.StanceBar.enabled = true end
    return s
end

-- ============================================================================
-- SETTINGS APPLICATION
-- Pushes the current MidnightUISettings to every UI subsystem in sequence.
-- ============================================================================

--- ApplyAllSettings: Calls every Apply* function in MidnightUI_Settings to
--  push the current saved-variable state to all UI subsystems, then saves
--  the current profile. Defers if player is in combat lockdown.
-- @param tag (string) - Identifier logged for diagnostics ("WELCOME_PRESET", etc.)
-- @return (bool) - true if all apply calls executed; false if deferred or missing
-- @calls MidnightUI_Settings.Initialize/Apply*, MidnightUI_Core.InitModules,
--        Profiles.SaveCurrentProfile
-- @calledby Every control callback, preset application, wizard finish
-- @note Order matters: InitializeSettings must run first (sets up internal
--       caches), and CoreInitModules last (re-lays out the entire HUD).
local function ApplyAllSettings(tag)
    if InCombatLockdown and InCombatLockdown() then
        Log("Apply deferred in combat for " .. tostring(tag))
        return false
    end

    local S = _G.MidnightUI_Settings
    if not S then return false end

    SafeCall("InitializeSettings", S.InitializeSettings)
    SafeCall("ApplyGlobalTheme", S.ApplyGlobalTheme)
    SafeCall("ApplyMessengerSettings", S.ApplyMessengerSettings)
    SafeCall("ApplyActionBarSettingsImmediate", S.ApplyActionBarSettingsImmediate)
    SafeCall("ApplyPlayerSettings", S.ApplyPlayerSettings)
    SafeCall("ApplyTargetSettings", S.ApplyTargetSettings)
    SafeCall("ApplyFocusSettings", S.ApplyFocusSettings)
    SafeCall("ApplyPartyFramesSettings", S.ApplyPartyFramesSettings)
    SafeCall("ApplyUnitFrameBarStyle", S.ApplyUnitFrameBarStyle)
    SafeCall("ApplyNameplateSettings", S.ApplyNameplateSettings)
    SafeCall("ApplyCastBarSettings", S.ApplyCastBarSettings)
    SafeCall("ApplyMinimapSettings", S.ApplyMinimapSettings)
    SafeCall("ApplyRaidFramesSettings", S.ApplyRaidFramesSettings)
    SafeCall("ApplyMainTankSettings", _G.MidnightUI_ApplyMainTankSettings)
    SafeCall("ApplyQuestObjectiveVisibility", S.ApplyQuestObjectiveVisibility)

    -- Cross-module call: re-initialize Core layout after all subsystems updated
    if _G.MidnightUI_Core and _G.MidnightUI_Core.InitModules then
        SafeCall("CoreInitModules", _G.MidnightUI_Core.InitModules, tag or "WELCOME_WIZARD")
    end
    -- Persist the new settings to the profile system
    if Profiles and Profiles.SaveCurrentProfile then
        Profiles.SaveCurrentProfile("welcome_wizard")
    end
    return true
end

-- ============================================================================
-- UI FACTORY FUNCTIONS
-- Reusable builders for the panels, cards, tiles, and controls used across
-- all three wizard steps. Every visual element in the wizard is built by one
-- of these factories.
-- ============================================================================

--- CreatePanel: Builds a BackdropTemplate frame with the standard MidnightUI
--  dark panel look (dark fill, thin border).
-- @param parent (Frame) - Parent frame
-- @param w (number) - Width in pixels
-- @param h (number) - Height in pixels
-- @return (Frame) - The new panel frame
local function CreatePanel(parent, w, h)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    frame:SetSize(w, h)
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    frame:SetBackdropColor(UI_COLORS.panel[1], UI_COLORS.panel[2], UI_COLORS.panel[3], 0.95)
    frame:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 1)
    return frame
end

--- CreateHeaderLine: Draws a 1px horizontal divider line across a parent frame.
-- @param parent (Frame) - Parent frame
-- @param y (number) - Vertical offset from TOPLEFT (negative = down)
-- @return (Texture) - The line texture
local function CreateHeaderLine(parent, y)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetPoint("TOPLEFT", 0, y)
    line:SetPoint("TOPRIGHT", 0, y)
    line:SetHeight(1)
    line:SetColorTexture(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.9)
    return line
end

--- CreateActionTile: Builds a card with icon, title, description, and a full-width
--  action button at the bottom. Used for the "Start Fresh" and "Import" tiles.
-- @param parent (Frame) - Parent frame
-- @param title (string) - Card heading text
-- @param body (string) - Description text
-- @param buttonText (string) - Label for the action button
-- @param iconTexture (number|string|nil) - Texture ID or path for the title icon
-- @param onClick (function) - Button click handler
-- @param width (number) - Card width (default 268)
-- @param height (number) - Card height (default 168)
-- @return (Frame) - The tile frame; tile._button is the action button
local function CreateActionTile(parent, title, body, buttonText, iconTexture, onClick, width, height)
    local tile = CreatePanel(parent, width or 268, height or 168)
    tile:SetBackdropColor(0.07, 0.11, 0.19, 0.92)

    local shine = tile:CreateTexture(nil, "ARTWORK")
    shine:SetTexture("Interface\\Buttons\\WHITE8X8")
    shine:SetPoint("TOPLEFT", 2, -2)
    shine:SetPoint("TOPRIGHT", -2, -2)
    shine:SetHeight(38)
    shine:SetVertexColor(0.10, 0.18, 0.30, 0.45)

    local icon = nil
    if iconTexture then
        icon = tile:CreateTexture(nil, "OVERLAY")
        icon:SetPoint("TOPLEFT", 12, -10)
        icon:SetSize(22, 22)
        icon:SetTexture(iconTexture)
        icon:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.9)
    end

    local t = tile:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if icon then
        t:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    else
        t:SetPoint("TOPLEFT", 12, -16)
    end
    t:SetText(title)
    t:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(t, 14, "OUTLINE")

    local d = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    d:SetPoint("TOPLEFT", 12, -52)
    d:SetPoint("TOPRIGHT", -12, -52)
    d:SetPoint("BOTTOMLEFT", 12, 52)
    d:SetPoint("BOTTOMRIGHT", -12, 52)
    d:SetJustifyH("LEFT")
    d:SetText(body)
    d:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(d, 13)

    local btn = CreateFrame("Button", nil, tile, "UIPanelButtonTemplate")
    btn:SetPoint("BOTTOMLEFT", 12, 12)
    btn:SetPoint("BOTTOMRIGHT", -12, 12)
    btn:SetHeight(30)
    btn:SetText(buttonText)
    StyleButton(btn)
    btn:SetScript("OnClick", onClick)
    tile._button = btn
    return tile
end

--- CARD_LAYOUT: Default layout constants for the two-column card grid used in
--  Step 2's tuning workspace. Cards reflow to single-column if the panel is
--  too narrow for minWidth per card.
local CARD_LAYOUT = {
    leftX = 0,         -- horizontal inset from host left edge
    startY = -6,       -- vertical offset for first card row
    gapX = 16,         -- horizontal gap between columns
    gapY = 108,        -- vertical gap between rows (includes card height)
    minWidth = 262,    -- minimum card width before switching to single-column
    defaultHeight = 92,-- default card height for height estimation
}

--- CreateControlCard: Base factory for settings cards (dropdown, toggle, slider).
--  Creates a panel with a title label and an optional hint text area.
-- @param parent (Frame) - Parent host frame
-- @param title (string) - Card heading
-- @param cardHeight (number) - Height override (default CARD_LAYOUT.defaultHeight)
-- @return (Frame) - The card frame; card._label is the title FontString,
--                   card:SetHint(text) creates/updates a subtitle hint
local function CreateControlCard(parent, title, cardHeight)
    local card = CreatePanel(parent, 300, cardHeight or CARD_LAYOUT.defaultHeight)
    card:SetBackdropColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.9)

    local topGlow = card:CreateTexture(nil, "BACKGROUND")
    topGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    topGlow:SetPoint("TOPLEFT", 1, -1)
    topGlow:SetPoint("TOPRIGHT", -1, -1)
    topGlow:SetHeight(24)
    topGlow:SetVertexColor(0.08, 0.16, 0.28, 0.32)

    local label = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("TOPLEFT", 12, -8)
    label:SetPoint("TOPRIGHT", -12, -8)
    label:SetJustifyH("LEFT")
    label:SetText(title)
    label:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(label, 12, "OUTLINE")
    card._label = label

    card.SetHint = function(self, text)
        if not self._hint then
            self._hint = self:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            self._hint:SetPoint("TOPLEFT", 12, -28)
            self._hint:SetPoint("TOPRIGHT", -12, -28)
            self._hint:SetJustifyH("LEFT")
            self._hint:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
            TrySetFont(self._hint, 11)
        end
        self._hint:SetText(text or "")
    end
    return card
end

--- CreateDropdownCard: Card with a UIDropDownMenu for selecting from a list.
-- @param parent (Frame) - Parent host frame
-- @param title (string) - Card heading
-- @param options (table) - Array of string options for the dropdown
-- @param currentVal (string) - Initially selected value
-- @param onChange (function) - Called with the new selection string
-- @return (Frame) - The card; card:SetValue(v) updates display externally
local function CreateDropdownCard(parent, title, options, currentVal, onChange)
    local card = CreateControlCard(parent, title)
    local dropdown = CreateFrame("Frame", nil, card, "UIDropDownMenuTemplate")
    dropdown:SetPoint("BOTTOMLEFT", -6, 2)
    UIDropDownMenu_SetWidth(dropdown, 170)
    UIDropDownMenu_SetText(dropdown, currentVal)

    UIDropDownMenu_Initialize(dropdown, function()
        for _, option in ipairs(options or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = option
            info.func = function()
                UIDropDownMenu_SetText(dropdown, option)
                if onChange then onChange(option) end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    card.SetValue = function(self, v)
        UIDropDownMenu_SetText(dropdown, v)
    end
    return card
end

--- CreateToggleCard: Card with a checkbox for boolean settings.
-- @param parent (Frame) - Parent host frame
-- @param title (string) - Card heading
-- @param label (string) - Hint text below the title
-- @param currentVal (bool) - Initial checked state
-- @param onChange (function) - Called with true/false on toggle
-- @return (Frame) - The card; card:SetChecked(v) updates externally
local function CreateToggleCard(parent, title, label, currentVal, onChange)
    local card = CreateControlCard(parent, title)
    local cb = CreateFrame("CheckButton", nil, card, "InterfaceOptionsCheckButtonTemplate")
    cb:SetPoint("BOTTOMLEFT", 8, 8)
    if cb.Text then
        cb.Text:SetText("Enabled")
        cb.Text:SetFontObject("GameFontHighlightSmall")
    end
    cb:SetChecked(currentVal == true)
    cb:SetScript("OnClick", function(self)
        if onChange then onChange(self:GetChecked() == true) end
    end)
    card:SetHint((label and label ~= "") and label or "Toggle this option.")
    card.SetChecked = function(self, v)
        cb:SetChecked(v == true)
    end
    return card
end

--- CreateSliderCard: Card with a horizontal slider for numeric settings.
-- @param parent (Frame) - Parent host frame
-- @param title (string) - Card heading
-- @param min (number) - Slider minimum value
-- @param max (number) - Slider maximum value
-- @param step (number) - Value step increment
-- @param currentVal (number) - Initial slider value
-- @param onChange (function) - Called with new numeric value on drag
-- @return (Frame) - The card; card:SetValue(v) updates externally
local function CreateSliderCard(parent, title, min, max, step, currentVal, onChange)
    local card = CreateControlCard(parent, title)
    local slider = CreateFrame("Slider", nil, card, "OptionsSliderTemplate")
    slider:SetPoint("BOTTOMLEFT", 12, 8)
    slider:SetPoint("BOTTOMRIGHT", -12, 8)
    slider:SetHeight(14)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    local sliderName = slider:GetName()
    if sliderName then
        if _G[sliderName .. "Low"] then _G[sliderName .. "Low"]:Hide() end
        if _G[sliderName .. "High"] then _G[sliderName .. "High"]:Hide() end
        if _G[sliderName .. "Text"] then _G[sliderName .. "Text"]:Hide() end
    end

    local valText = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    valText:SetPoint("TOPRIGHT", -10, -8)
    valText:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])

    local function SetDisplay(v)
        local out = v
        if step >= 1 then out = math.floor(v + 0.5) end
        valText:SetText(tostring(out))
    end

    slider:SetValue(currentVal or min)
    SetDisplay(currentVal or min)
    slider:SetScript("OnValueChanged", function(self, v)
        SetDisplay(v)
        if onChange then onChange(v) end
    end)

    card.SetValue = function(self, v)
        slider:SetValue(v)
    end
    return card
end

--- CreateOverlayLauncherCard: Card with a dropdown picker and an "Open Selected"
--  button that launches the per-element overlay settings panel for the chosen
--  UI element (e.g., Player Frame, Action Bar 3, Messenger).
-- @param parent (Frame) - Parent host frame
-- @param title (string) - Card heading
-- @param entries (table) - Array of {label=string, key=string} overlay targets
-- @param currentLabel (string) - Initially selected label
-- @param onOpen (function) - Called with the selected label string
-- @return (Frame) - The card; card:SetValue(label) updates selection externally
local function CreateOverlayLauncherCard(parent, title, entries, currentLabel, onOpen)
    local card = CreateControlCard(parent, title)
    card:SetHint("Pick a UI element, then open its detailed settings panel.")
    local selected = currentLabel or (entries and entries[1] and entries[1].label) or ""

    local dropdown = CreateFrame("Frame", nil, card, "UIDropDownMenuTemplate")
    dropdown:SetPoint("BOTTOMLEFT", -6, 2)
    UIDropDownMenu_SetWidth(dropdown, 140)
    UIDropDownMenu_SetText(dropdown, selected)

    UIDropDownMenu_Initialize(dropdown, function()
        for _, entry in ipairs(entries or {}) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.label
            info.func = function()
                selected = entry.label
                UIDropDownMenu_SetText(dropdown, selected)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    local btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
    btn:SetPoint("BOTTOMRIGHT", -10, 8)
    btn:SetSize(118, 24)
    btn:SetText("Open Selected")
    StyleButton(btn)
    btn:SetScript("OnClick", function()
        if onOpen then onOpen(selected) end
    end)

    card.SetValue = function(self, label)
        selected = label or selected
        UIDropDownMenu_SetText(dropdown, selected)
    end
    return card
end

--- LayoutCards: Arranges an array of card frames into a responsive two-column
--  grid inside a parent frame. Falls back to single column if the parent is
--  too narrow. Hooks OnSizeChanged and OnShow for automatic reflow, plus
--  C_Timer.After(0/0.05) for deferred first-frame layout.
-- @param cards (table) - Array of card frames to lay out
-- @param parent (Frame) - Container frame that determines available width
-- @param leftX (number) - Left inset (default CARD_LAYOUT.leftX)
-- @param startY (number) - Top offset (default CARD_LAYOUT.startY)
-- @param gapX (number) - Column gap (default CARD_LAYOUT.gapX)
-- @param gapY (number) - Row gap (default CARD_LAYOUT.gapY)
-- @param minWidth (number) - Min card width before single-col (default CARD_LAYOUT.minWidth)
local function LayoutCards(cards, parent, leftX, startY, gapX, gapY, minWidth)
    if not parent then return end
    local cfg = parent._muiCardLayout or {}
    parent._muiCardLayout = cfg

    cfg.cards = cards or {}
    cfg.leftX = leftX or CARD_LAYOUT.leftX
    cfg.startY = startY or CARD_LAYOUT.startY
    cfg.gapX = gapX or CARD_LAYOUT.gapX
    cfg.gapY = gapY or CARD_LAYOUT.gapY
    cfg.minWidth = minWidth or CARD_LAYOUT.minWidth

    local function DoLayout()
        local state = parent._muiCardLayout
        if not state then return end
        local list = state.cards
        if not list or #list == 0 then return end

        local pw = (parent and parent.GetWidth and parent:GetWidth()) or 520
        if pw < 320 then pw = 520 end
        local usable = math.max(260, pw - (state.leftX * 2))
        local cols = 2
        local cardW = math.floor((usable - state.gapX) / 2)
        if cardW < state.minWidth then
            cols = 1
            cardW = usable
        end

        for i, card in ipairs(list) do
            if card then
                local col = (i - 1) % cols
                local row = math.floor((i - 1) / cols)
                card:ClearAllPoints()
                card:SetPoint("TOPLEFT", state.leftX + (col * (cardW + state.gapX)), state.startY - (row * state.gapY))
                card:SetWidth(cardW)
            end
        end
    end

    cfg.DoLayout = DoLayout
    if not cfg.hooked then
        parent:HookScript("OnSizeChanged", function()
            if parent._muiCardLayout and parent._muiCardLayout.DoLayout then
                parent._muiCardLayout.DoLayout()
            end
        end)
        parent:HookScript("OnShow", function()
            if parent._muiCardLayout and parent._muiCardLayout.DoLayout then
                parent._muiCardLayout.DoLayout()
            end
        end)
        cfg.hooked = true
    end

    DoLayout()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, DoLayout)
        C_Timer.After(0.05, DoLayout)
    end
end

-- ============================================================================
-- URL PROMPT DIALOG
-- A modal dialog that displays a URL in a selectable EditBox so the user can
-- copy it to their clipboard (WoW does not support programmatic clipboard).
-- ============================================================================

local urlPromptFrame

--- GetCopyShortcutLabel: Returns the platform-appropriate copy shortcut string.
-- @return (string) - "Cmd + C" on Mac, "Ctrl + C" on Windows/Linux
local function GetCopyShortcutLabel()
    local isMac = false
    if _G.IsMacClient then
        local ok, res = pcall(_G.IsMacClient)
        isMac = ok and res == true
    end
    return isMac and "Cmd + C" or "Ctrl + C"
end

--- EnsureURLPromptFrame: Lazily creates the URL copy dialog with title,
--  scrollable EditBox, Copy/Close buttons, and an X corner button.
-- @return (Frame) - The URL prompt frame (cached in urlPromptFrame)
-- @note The frame exposes f:SetURL(url) which populates and auto-selects text.
local function EnsureURLPromptFrame()
    if urlPromptFrame then return urlPromptFrame end

    local f = CreatePanel(UIParent, 980, 244)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(240)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetPoint("TOPRIGHT", -16, -12)
    title:SetJustifyH("LEFT")
    title:SetText("Copy this Link (" .. GetCopyShortcutLabel() .. ")")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(title, 20, "OUTLINE")

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 16, -40)
    sub:SetPoint("TOPRIGHT", -16, -40)
    sub:SetJustifyH("LEFT")
    sub:SetText("Copy the link below and paste it into your browser.")
    sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(sub, 14)

    local box = CreatePanel(f, 1, 108)
    box:SetPoint("TOPLEFT", 16, -66)
    box:SetPoint("TOPRIGHT", -16, -66)
    box:SetBackdropColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.95)

    local boxGlow = box:CreateTexture(nil, "BACKGROUND")
    boxGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    boxGlow:SetPoint("TOPLEFT", 1, -1)
    boxGlow:SetPoint("TOPRIGHT", -1, -1)
    boxGlow:SetHeight(26)
    boxGlow:SetVertexColor(0.10, 0.20, 0.34, 0.45)

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -10)
    scroll:SetPoint("BOTTOMRIGHT", -28, 10)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(false)
    edit:SetFontObject("GameFontHighlight")
    if edit.SetFont then
        pcall(edit.SetFont, edit, TITLE_FONT, 16, "")
    end
    if edit.SetTextColor then
        edit:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3], 1)
    end
    if edit.SetJustifyH then
        edit:SetJustifyH("LEFT")
    end
    if edit.SetTextInsets then
        edit:SetTextInsets(8, 8, 4, 4)
    end
    edit:SetWidth(1600)
    edit:SetHeight(30)
    edit:SetAutoFocus(false)
    edit:SetText("")
    edit:SetScript("OnEscapePressed", function() f:Hide() end)
    edit:SetScript("OnEnterPressed", function(self)
        self:HighlightText()
        self:SetFocus()
    end)
    scroll:SetScrollChild(edit)

    local btnCopy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnCopy:SetSize(130, 30)
    btnCopy:SetPoint("BOTTOM", f, "BOTTOM", -72, 16)
    btnCopy:SetText("Copy")
    StyleButton(btnCopy)
    btnCopy:SetScript("OnClick", function()
        if not f._urlEdit then return end
        f._urlEdit:SetFocus()
        f._urlEdit:HighlightText()
    end)

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetSize(130, 30)
    btnClose:SetPoint("LEFT", btnCopy, "RIGHT", 10, 0)
    btnClose:SetText("Close")
    StyleButton(btnClose)
    btnClose:SetScript("OnClick", function() f:Hide() end)

    local btnCorner = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnCorner:SetSize(24, 24)
    btnCorner:SetPoint("TOPRIGHT", -8, -8)
    btnCorner:SetText("X")
    StyleButton(btnCorner)
    btnCorner:SetScript("OnClick", function() f:Hide() end)

    f._title = title
    f._urlEdit = edit
    f._urlValue = ""
    f.SetURL = function(self, url)
        local link = url or ""
        self._urlValue = link
        if self._title then
            self._title:SetText("Copy this Link (" .. GetCopyShortcutLabel() .. ")")
        end
        if self._urlEdit then
            self._urlEdit:SetText(link)
            if self._urlEdit.SetCursorPosition then
                self._urlEdit:SetCursorPosition(0)
            end
            self._urlEdit:HighlightText()
            self._urlEdit:SetFocus()
        end
    end

    f:SetScript("OnShow", function(self)
        if self._urlEdit then
            self._urlEdit:SetText(self._urlValue or "")
            self._urlEdit:HighlightText()
            self._urlEdit:SetFocus()
        end
    end)

    urlPromptFrame = f
    return urlPromptFrame
end

--- OpenURL: Shows the URL copy dialog with the given link pre-selected.
-- @param url (string) - Full URL to display
-- @calledby Patreon/Discord button clicks
local function OpenURL(url)
    if not url or url == "" then return end
    local prompt = EnsureURLPromptFrame()
    if not prompt then return end
    prompt:SetURL(url)
    prompt:Show()
    prompt:Raise()
end
_G.MidnightUI_OpenURL = OpenURL

--- OpenSettingsPanel: Opens the main MidnightUI settings panel via slash command.
-- @calls SlashCmdList["MIDNIGHTUI"]
local function OpenSettingsPanel()
    if SlashCmdList and SlashCmdList["MIDNIGHTUI"] then
        SlashCmdList["MIDNIGHTUI"]("")
    end
end

--- ResolveProfileOptions: Fetches the list of importable character profiles
--  from the Profiles module, excluding the current character.
-- @return (table) - Array of {label=string, key=string, createdAt=number|nil}
local function ResolveProfileOptions()
    if not Profiles or not Profiles.GetProfileOptions then return {} end
    return Profiles.GetProfileOptions(Profiles.GetCharacterKey()) or {}
end

-- ============================================================================
-- PROFILE IMPORT / EXPORT DIALOGS
-- Standalone DIALOG-strata frames for importing profiles from another character
-- or a pasted string, and for exporting the current profile as a copyable string.
-- ============================================================================

local importFrame
local exportFrame
local welcomeFrame

--- CreateImportFrame: Builds the import dialog with a character-picker dropdown,
--  a multiline paste EditBox, Import Selected / Import Pasted String / Cancel
--  buttons, and a status line for success/error feedback.
-- @return (Frame) - The import dialog frame
-- @note Exposes f.RefreshDropdown(), f.EditBox, f.SetStatus(text,r,g,b),
--       and f._onImported callback for post-import actions.
local function CreateImportFrame()
    local f = CreatePanel(UIParent, 680, 470)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(120)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("Import Profile")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 16, -36)
    sub:SetPoint("TOPRIGHT", -16, -36)
    sub:SetText("Paste a profile string or pull from another one of your characters.")
    sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local dropdown = CreateFrame("Frame", "MidnightUI_WelcomeImportDropdown", f, "UIDropDownMenuTemplate")
    dropdown:SetPoint("TOPLEFT", 10, -60)
    dropdown:SetFrameStrata("DIALOG")
    dropdown:SetFrameLevel(f:GetFrameLevel() + 5)
    UIDropDownMenu_SetWidth(dropdown, 290)
    UIDropDownMenu_SetText(dropdown, "Import from character")

    local details = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    details:SetPoint("TOPLEFT", 330, -68)
    details:SetPoint("TOPRIGHT", -16, -68)
    details:SetJustifyH("LEFT")
    details:SetText("")
    details:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local box = CreatePanel(f, 648, 270)
    box:SetPoint("TOPLEFT", 16, -110)
    box:SetBackdropColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.9)

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetWidth(600)
    edit:SetAutoFocus(false)
    edit:SetText("")
    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
    scroll:SetScrollChild(edit)

    local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("BOTTOMLEFT", 16, 54)
    status:SetText("")
    status:SetTextColor(1, 0.4, 0.4)

    local btnImportCharacter = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImportCharacter:SetPoint("BOTTOMLEFT", 16, 18)
    btnImportCharacter:SetSize(190, 30)
    btnImportCharacter:SetText("Import Selected")
    StyleButton(btnImportCharacter)

    local btnImportString = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnImportString:SetPoint("LEFT", btnImportCharacter, "RIGHT", 8, 0)
    btnImportString:SetSize(190, 30)
    btnImportString:SetText("Import Pasted String")
    StyleButton(btnImportString)

    local btnCancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnCancel:SetPoint("BOTTOMRIGHT", -16, 18)
    btnCancel:SetSize(140, 30)
    btnCancel:SetText("Cancel")
    StyleButton(btnCancel)

    local options = {}
    local selectedKey = nil

    local function SetStatus(text, r, g, b)
        status:SetText(text or "")
        status:SetTextColor(r or 1, g or 0.4, b or 0.4)
    end

    local function RefreshDropdown()
        options = ResolveProfileOptions()
        selectedKey = nil
        UIDropDownMenu_SetText(dropdown, "Import from character")
        details:SetText(#options == 0 and "No account profile found yet. Log into your other character once and it will show here." or "")

        UIDropDownMenu_Initialize(dropdown, function()
            if #options == 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text = "No other characters found"
                info.disabled = true
                UIDropDownMenu_AddButton(info)
                return
            end
            for _, entry in ipairs(options) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry.label
                info.func = function()
                    selectedKey = entry.key
                    UIDropDownMenu_SetText(dropdown, entry.label)
                    local created = entry.createdAt and date("%b %d, %Y", entry.createdAt) or "Unknown"
                    details:SetText("Selected: " .. entry.key .. "\nCreated: " .. created)
                end
                UIDropDownMenu_AddButton(info)
            end
        end)
        if _G.DropDownList1 then
            _G.DropDownList1:SetFrameStrata("DIALOG")
            _G.DropDownList1:SetFrameLevel(f:GetFrameLevel() + 10)
        end
    end

    local function ImportDone(ok, err)
        if ok then
            SetStatus("Import successful", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
            if Profiles and Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
            if f._onImported then f._onImported() end
            f:Hide()
            return
        end
        SetStatus("Import failed. Check Diagnostics.", 1, 0.4, 0.4)
        Log("Import failed: " .. tostring(err))
    end

    btnImportCharacter:SetScript("OnClick", function()
        SetStatus("")
        if not Profiles or not Profiles.ImportProfileFromKey then
            SetStatus("Profiles API is missing.")
            return
        end
        if not selectedKey then
            SetStatus("Pick a character profile first.")
            return
        end
        ImportDone(Profiles.ImportProfileFromKey(selectedKey))
    end)

    btnImportString:SetScript("OnClick", function()
        SetStatus("")
        if not Profiles or not Profiles.ImportProfileString then
            SetStatus("Profiles API is missing.")
            return
        end
        local text = edit:GetText() or ""
        if text:gsub("%s+", "") == "" then
            SetStatus("Paste a profile string first.")
            return
        end
        ImportDone(Profiles.ImportProfileString(text))
    end)

    btnCancel:SetScript("OnClick", function()
        f:Hide()
    end)

    f.RefreshDropdown = RefreshDropdown
    f.EditBox = edit
    f.SetStatus = SetStatus
    return f
end

--- CreateExportFrame: Builds the export dialog with a multiline EditBox showing
--  the serialized profile string, Refresh / Select All / Close buttons, and a
--  payload-length indicator.
-- @return (Frame) - The export dialog frame
-- @note Exposes f.RefreshExport() and f.EditBox.
local function CreateExportFrame()
    local f = CreatePanel(UIParent, 680, 430)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(120)
    f:Hide()

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -12)
    title:SetText("Export Profile")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])

    local sub = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOPLEFT", 16, -36)
    sub:SetPoint("TOPRIGHT", -16, -36)
    sub:SetText("Copy this string and use it on another character or share it with another player.")
    sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local meta = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    meta:SetPoint("TOPLEFT", 16, -56)
    meta:SetText("")
    meta:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])

    local box = CreatePanel(f, 648, 270)
    box:SetPoint("TOPLEFT", 16, -82)
    box:SetBackdropColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.9)

    local scroll = CreateFrame("ScrollFrame", nil, box, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -6)
    scroll:SetPoint("BOTTOMRIGHT", -26, 6)

    local edit = CreateFrame("EditBox", nil, scroll)
    edit:SetMultiLine(true)
    edit:SetFontObject("GameFontHighlightSmall")
    edit:SetWidth(600)
    edit:SetAutoFocus(false)
    edit:SetText("")
    edit:SetScript("OnEscapePressed", function() edit:ClearFocus() end)
    scroll:SetScrollChild(edit)

    local btnRefresh = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnRefresh:SetPoint("BOTTOMLEFT", 16, 18)
    btnRefresh:SetSize(140, 30)
    btnRefresh:SetText("Refresh")
    StyleButton(btnRefresh)

    local btnSelect = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnSelect:SetPoint("LEFT", btnRefresh, "RIGHT", 8, 0)
    btnSelect:SetSize(140, 30)
    btnSelect:SetText("Select All")
    StyleButton(btnSelect)

    local btnClose = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnClose:SetPoint("BOTTOMRIGHT", -16, 18)
    btnClose:SetSize(140, 30)
    btnClose:SetText("Close")
    StyleButton(btnClose)

    local function RefreshExport()
        local payload = (Profiles and Profiles.ExportProfileString and Profiles.ExportProfileString()) or "Profiles system is not available."
        edit:SetText(payload)
        meta:SetText("Payload length: " .. tostring(string.len(payload or "")))
        if Profiles and Profiles.SaveCurrentProfile then
            Profiles.SaveCurrentProfile("manual_export")
        end
    end

    btnRefresh:SetScript("OnClick", RefreshExport)
    btnSelect:SetScript("OnClick", function()
        edit:HighlightText()
        edit:SetFocus()
    end)
    btnClose:SetScript("OnClick", function() f:Hide() end)

    f.RefreshExport = RefreshExport
    f.EditBox = edit
    return f
end

--- MidnightUI_ShowProfileImport: Opens the profile import dialog.
-- @param onImported (function|nil) - Callback fired after a successful import
-- @calledby Step 1 "Open Import" button, slash commands
function _G.MidnightUI_ShowProfileImport(onImported)
    if not importFrame then importFrame = CreateImportFrame() end
    importFrame._onImported = onImported
    importFrame:Show()
    importFrame:Raise()
    if importFrame.EditBox then importFrame.EditBox:SetText("") end
    importFrame:SetStatus("")
    if importFrame.RefreshDropdown then importFrame.RefreshDropdown() end
end

--- MidnightUI_ShowProfileExport: Opens the profile export dialog with the
--  current profile serialized and auto-selected for copying.
-- @calledby Settings panel export button
function _G.MidnightUI_ShowProfileExport()
    if not exportFrame then exportFrame = CreateExportFrame() end
    exportFrame:Show()
    exportFrame:Raise()
    if exportFrame.RefreshExport then exportFrame.RefreshExport() end
    exportFrame.EditBox:HighlightText()
end

-- ============================================================================
-- PRESET SYSTEM
-- Four curated presets that write comprehensive defaults for every subsystem:
--   "MidnightUI" (Casual), "Raid Focused", "Mythic+", "Class Themed" (PvP/fallback).
-- Each preset sets theme, action bar style, frame sizes, nameplate config,
-- cast bar dimensions, party/raid layout, and consumable behavior.
-- ============================================================================

--- ApplyPreset: Writes a full set of default values into MidnightUISettings
--  for the named preset, then optionally calls ApplyAllSettings to push live.
-- @param name (string) - One of "MidnightUI", "Raid Focused", "Mythic+", or
--                         any other value (falls back to "Class Themed" defaults)
-- @param skipApply (bool) - If true, writes settings but does not push live
--                           (caller is responsible for calling ApplyAllSettings)
-- @calls EnsureSettings, ApplyAllSettings (unless skipApply)
-- @calledby ApplyPresetAndRefresh, ApplySimplePlaystyleSelection
-- @note Each preset branch is ~100 lines of direct table assignments. The
--       presets differ primarily in theme, frame dimensions, party style,
--       raid layout, and nameplate sizing to suit different content types.
local function ApplyPreset(name, skipApply)
    local s = EnsureSettings()
    local function SetPartyStyle(style)
        if _G.MidnightUI_SetPartyStyle then
            _G.MidnightUI_SetPartyStyle(style)
        end
        s.PartyFrames.style = style
    end

    local function SetTheme(theme)
        local actionBarStyleByTheme = {
            ["Default"] = "Disabled",
            ["Class Color"] = "Class Color",
            ["Faithful"] = "Faithful",
            ["Glass"] = "Glass",
        }
        s.GlobalStyle = theme
        s.Messenger.style = theme
        s.Minimap.infoBarStyle = theme
        s.ActionBars.globalStyle = actionBarStyleByTheme[theme] or "Disabled"
    end

    local function SetActionColorTheme(style)
        s.ActionBars.globalStyle = style
        s.Messenger.style = style
        s.Minimap.infoBarStyle = style
    end

    local function SetActionBarsEnabled(startIdx, endIdx, enabled)
        for i = startIdx, endIdx do
            local key = "bar" .. i
            s.ActionBars[key] = s.ActionBars[key] or {}
            s.ActionBars[key].enabled = (enabled == true)
        end
    end

    local function SetCoreToggles()
        s.PlayerFrame.enabled = true
        s.TargetFrame.enabled = true
        s.FocusFrame.enabled = true
        s.CastBars.player.enabled = true
        s.CastBars.target.enabled = true
        s.CastBars.focus.enabled = true
        s.Nameplates.enabled = true
        s.Nameplates.threatBar.enabled = true
        s.ConsumableBars.enabled = true
        s.PetBar.enabled = true
        s.StanceBar.enabled = true
    end

    local function ApplySharedDefaults()
        SetCoreToggles()
        s.General.customTooltips = true
        s.PartyFrames.showTooltip = true
    end

    if name == "MidnightUI" then
        SetTheme("Default")
        s.ActionBars.globalStyle = "Glass"
        ApplySharedDefaults()
        s.General.unitFrameBarStyle = "Gradient"
        s.General.hideQuestObjectivesAlways = false
        s.General.hideQuestObjectivesInCombat = true
        s.ConsumableBars.hideInactive = false
        s.ConsumableBars.showInInstancesOnly = false
        SetActionBarsEnabled(1, 4, true)
        SetActionBarsEnabled(5, 8, false)

        s.PlayerFrame.width = 380
        s.PlayerFrame.height = 66
        s.PlayerFrame.scale = 100
        s.PlayerFrame.alpha = 0.95

        s.TargetFrame.width = 380
        s.TargetFrame.height = 66
        s.TargetFrame.scale = 100
        s.TargetFrame.alpha = 0.95
        s.TargetFrame.debuffs.filterMode = "AUTO"
        s.TargetFrame.debuffs.maxShown = 16

        s.FocusFrame.width = 320
        s.FocusFrame.height = 58
        s.FocusFrame.scale = 100
        s.FocusFrame.alpha = 0.95

        s.PartyFrames.layout = "Vertical"
        SetPartyStyle("Rendered")
        s.PartyFrames.width = 240
        s.PartyFrames.height = 58
        s.PartyFrames.diameter = 64
        s.PartyFrames.spacingX = 8
        s.PartyFrames.spacingY = 8

        s.RaidFrames.groupBy = true
        s.RaidFrames.colorByGroup = true
        s.RaidFrames.groupBrackets = true
        s.RaidFrames.columns = 5
        s.RaidFrames.layoutStyle = "Detailed"
        s.RaidFrames.width = 92
        s.RaidFrames.height = 24
        s.RaidFrames.spacingX = 6
        s.RaidFrames.spacingY = 4

        s.MainTankFrames.width = 260
        s.MainTankFrames.height = 58
        s.MainTankFrames.spacing = 6
        s.MainTankFrames.scale = 1.0

        s.Nameplates.healthBar.width = 200
        s.Nameplates.healthBar.height = 20
        s.Nameplates.healthBar.alpha = 1.0
        s.Nameplates.healthBar.nameFontSize = 10
        s.Nameplates.healthBar.healthPctFontSize = 9
        s.Nameplates.healthBar.nameAlign = "LEFT"
        s.Nameplates.healthBar.healthPctDisplay = "RIGHT"
        s.Nameplates.threatBar.width = 200
        s.Nameplates.threatBar.height = 5
        s.Nameplates.threatBar.alpha = 1.0
        s.Nameplates.castBar.width = 200
        s.Nameplates.castBar.height = 16
        s.Nameplates.castBar.alpha = 1.0
        s.Nameplates.castBar.fontSize = 12
        s.Nameplates.target.healthBar.width = 240
        s.Nameplates.target.healthBar.height = 24
        s.Nameplates.target.threatBar.width = 240
        s.Nameplates.target.threatBar.height = 6
        s.Nameplates.target.castBar.width = 240
        s.Nameplates.target.castBar.height = 18

        s.CastBars.player.width = 360
        s.CastBars.player.height = 20
        s.CastBars.player.scale = 100
        s.CastBars.target.width = 360
        s.CastBars.target.height = 20
        s.CastBars.target.scale = 100
        s.CastBars.focus.width = 320
        s.CastBars.focus.height = 20
        s.CastBars.focus.scale = 100
    elseif name == "Raid Focused" then
        SetTheme("Glass")
        SetActionColorTheme("Glass")
        ApplySharedDefaults()
        s.General.unitFrameBarStyle = "Gradient"
        s.General.hideQuestObjectivesAlways = false
        s.General.hideQuestObjectivesInCombat = true
        s.ConsumableBars.hideInactive = true
        s.ConsumableBars.showInInstancesOnly = true
        SetActionBarsEnabled(1, 4, true)
        SetActionBarsEnabled(5, 8, false)

        s.PlayerFrame.width = 374
        s.PlayerFrame.height = 64
        s.PlayerFrame.scale = 100
        s.PlayerFrame.alpha = 0.95

        s.TargetFrame.width = 374
        s.TargetFrame.height = 64
        s.TargetFrame.scale = 100
        s.TargetFrame.alpha = 0.95
        s.TargetFrame.debuffs.filterMode = "AUTO"
        s.TargetFrame.debuffs.maxShown = 22

        s.FocusFrame.width = 312
        s.FocusFrame.height = 56
        s.FocusFrame.scale = 100
        s.FocusFrame.alpha = 0.95

        s.PartyFrames.layout = "Vertical"
        SetPartyStyle("Simple")
        s.PartyFrames.width = 228
        s.PartyFrames.height = 52
        s.PartyFrames.diameter = 62
        s.PartyFrames.spacingX = 6
        s.PartyFrames.spacingY = 6

        s.RaidFrames.groupBy = true
        s.RaidFrames.colorByGroup = true
        s.RaidFrames.groupBrackets = true
        s.RaidFrames.columns = 8
        s.RaidFrames.layoutStyle = "Detailed"
        s.RaidFrames.width = 106
        s.RaidFrames.height = 28
        s.RaidFrames.spacingX = 4
        s.RaidFrames.spacingY = 3

        s.MainTankFrames.width = 282
        s.MainTankFrames.height = 62
        s.MainTankFrames.spacing = 8
        s.MainTankFrames.scale = 1.0

        s.Nameplates.healthBar.width = 212
        s.Nameplates.healthBar.height = 22
        s.Nameplates.healthBar.alpha = 1.0
        s.Nameplates.healthBar.nameFontSize = 11
        s.Nameplates.healthBar.healthPctFontSize = 10
        s.Nameplates.healthBar.nameAlign = "LEFT"
        s.Nameplates.healthBar.healthPctDisplay = "RIGHT"
        s.Nameplates.threatBar.width = 212
        s.Nameplates.threatBar.height = 6
        s.Nameplates.threatBar.alpha = 1.0
        s.Nameplates.castBar.width = 212
        s.Nameplates.castBar.height = 17
        s.Nameplates.castBar.alpha = 1.0
        s.Nameplates.castBar.fontSize = 13
        s.Nameplates.target.healthBar.width = 254
        s.Nameplates.target.healthBar.height = 26
        s.Nameplates.target.threatBar.width = 254
        s.Nameplates.target.threatBar.height = 7
        s.Nameplates.target.castBar.width = 254
        s.Nameplates.target.castBar.height = 19

        s.CastBars.player.width = 386
        s.CastBars.player.height = 22
        s.CastBars.player.scale = 108
        s.CastBars.target.width = 386
        s.CastBars.target.height = 22
        s.CastBars.target.scale = 108
        s.CastBars.focus.width = 312
        s.CastBars.focus.height = 22
        s.CastBars.focus.scale = 108
    elseif name == "Mythic+" then
        SetTheme("Faithful")
        SetActionColorTheme("Glass")
        s.Messenger.style = "Default"
        ApplySharedDefaults()
        s.General.unitFrameBarStyle = "Gradient"
        s.General.hideQuestObjectivesAlways = false
        s.General.hideQuestObjectivesInCombat = true
        s.ConsumableBars.hideInactive = true
        s.ConsumableBars.showInInstancesOnly = true
        SetActionBarsEnabled(1, 4, true)
        SetActionBarsEnabled(5, 8, false)

        s.PlayerFrame.width = 384
        s.PlayerFrame.height = 66
        s.PlayerFrame.scale = 102
        s.PlayerFrame.alpha = 0.95

        s.TargetFrame.width = 384
        s.TargetFrame.height = 66
        s.TargetFrame.scale = 102
        s.TargetFrame.alpha = 0.95
        s.TargetFrame.debuffs.filterMode = "ALL"
        s.TargetFrame.debuffs.maxShown = 24

        s.FocusFrame.width = 324
        s.FocusFrame.height = 58
        s.FocusFrame.scale = 100
        s.FocusFrame.alpha = 0.95

        s.PartyFrames.layout = "Vertical"
        SetPartyStyle("Rendered")
        s.PartyFrames.width = 248
        s.PartyFrames.height = 62
        s.PartyFrames.diameter = 66
        s.PartyFrames.spacingX = 8
        s.PartyFrames.spacingY = 7

        s.RaidFrames.groupBy = false
        s.RaidFrames.colorByGroup = false
        s.RaidFrames.groupBrackets = false
        s.RaidFrames.columns = 5
        s.RaidFrames.layoutStyle = "Simple"
        s.RaidFrames.width = 88
        s.RaidFrames.height = 22
        s.RaidFrames.spacingX = 6
        s.RaidFrames.spacingY = 4

        s.MainTankFrames.width = 266
        s.MainTankFrames.height = 60
        s.MainTankFrames.spacing = 7
        s.MainTankFrames.scale = 1.0

        s.Nameplates.healthBar.width = 220
        s.Nameplates.healthBar.height = 22
        s.Nameplates.healthBar.alpha = 1.0
        s.Nameplates.healthBar.nameFontSize = 11
        s.Nameplates.healthBar.healthPctFontSize = 10
        s.Nameplates.healthBar.nameAlign = "LEFT"
        s.Nameplates.healthBar.healthPctDisplay = "RIGHT"
        s.Nameplates.threatBar.width = 220
        s.Nameplates.threatBar.height = 6
        s.Nameplates.threatBar.alpha = 1.0
        s.Nameplates.castBar.width = 220
        s.Nameplates.castBar.height = 18
        s.Nameplates.castBar.alpha = 1.0
        s.Nameplates.castBar.fontSize = 13
        s.Nameplates.target.healthBar.width = 265
        s.Nameplates.target.healthBar.height = 28
        s.Nameplates.target.threatBar.width = 265
        s.Nameplates.target.threatBar.height = 7
        s.Nameplates.target.castBar.width = 265
        s.Nameplates.target.castBar.height = 20

        s.CastBars.player.width = 392
        s.CastBars.player.height = 22
        s.CastBars.player.scale = 110
        s.CastBars.target.width = 392
        s.CastBars.target.height = 22
        s.CastBars.target.scale = 110
        s.CastBars.focus.width = 324
        s.CastBars.focus.height = 22
        s.CastBars.focus.scale = 110
    else
        SetTheme("Class Color")
        SetActionColorTheme("Class Color")
        ApplySharedDefaults()
        s.General.unitFrameBarStyle = "Flat"
        s.General.hideQuestObjectivesAlways = false
        s.General.hideQuestObjectivesInCombat = false
        s.ConsumableBars.hideInactive = true
        s.ConsumableBars.showInInstancesOnly = false
        SetActionBarsEnabled(1, 4, true)
        SetActionBarsEnabled(5, 8, false)

        s.PlayerFrame.width = 388
        s.PlayerFrame.height = 68
        s.PlayerFrame.scale = 100
        s.PlayerFrame.alpha = 0.96

        s.TargetFrame.width = 388
        s.TargetFrame.height = 68
        s.TargetFrame.scale = 100
        s.TargetFrame.alpha = 0.96
        s.TargetFrame.debuffs.filterMode = "PLAYER"
        s.TargetFrame.debuffs.maxShown = 18

        s.FocusFrame.width = 330
        s.FocusFrame.height = 60
        s.FocusFrame.scale = 100
        s.FocusFrame.alpha = 0.96

        s.PartyFrames.layout = "Horizontal"
        SetPartyStyle("Rendered")
        s.PartyFrames.width = 232
        s.PartyFrames.height = 56
        s.PartyFrames.diameter = 64
        s.PartyFrames.spacingX = 10
        s.PartyFrames.spacingY = 6

        s.RaidFrames.groupBy = false
        s.RaidFrames.colorByGroup = false
        s.RaidFrames.groupBrackets = false
        s.RaidFrames.columns = 6
        s.RaidFrames.layoutStyle = "Simple"
        s.RaidFrames.width = 90
        s.RaidFrames.height = 22
        s.RaidFrames.spacingX = 6
        s.RaidFrames.spacingY = 4

        s.MainTankFrames.width = 250
        s.MainTankFrames.height = 56
        s.MainTankFrames.spacing = 5
        s.MainTankFrames.scale = 1.0

        s.Nameplates.healthBar.width = 196
        s.Nameplates.healthBar.height = 19
        s.Nameplates.healthBar.alpha = 1.0
        s.Nameplates.healthBar.nameFontSize = 10
        s.Nameplates.healthBar.healthPctFontSize = 9
        s.Nameplates.healthBar.nameAlign = "CENTER"
        s.Nameplates.healthBar.healthPctDisplay = "RIGHT"
        s.Nameplates.threatBar.width = 196
        s.Nameplates.threatBar.height = 5
        s.Nameplates.threatBar.alpha = 1.0
        s.Nameplates.castBar.width = 196
        s.Nameplates.castBar.height = 15
        s.Nameplates.castBar.alpha = 1.0
        s.Nameplates.castBar.fontSize = 12
        s.Nameplates.target.healthBar.width = 232
        s.Nameplates.target.healthBar.height = 22
        s.Nameplates.target.threatBar.width = 232
        s.Nameplates.target.threatBar.height = 6
        s.Nameplates.target.castBar.width = 232
        s.Nameplates.target.castBar.height = 17

        s.CastBars.player.width = 350
        s.CastBars.player.height = 20
        s.CastBars.player.scale = 96
        s.CastBars.target.width = 350
        s.CastBars.target.height = 20
        s.CastBars.target.scale = 96
        s.CastBars.focus.width = 330
        s.CastBars.focus.height = 20
        s.CastBars.focus.scale = 96
    end
    if not skipApply then
        ApplyAllSettings("WELCOME_PRESET")
    end
    Log("Preset applied: " .. tostring(name))
end

-- ============================================================================
-- WELCOME WIZARD FRAME
-- The main three-step wizard. This single function (~3000 lines) builds every
-- page, control, and callback. It is called lazily on first MidnightUI_ShowWelcome.
--
-- INTERNAL ARCHITECTURE:
--   state (table)     - Tracks user selections: preset, playstyle, role, etc.
--   stepPages[1..3]   - The three page frames shown one at a time.
--   stepButtons[1..3] - Left-rail navigation buttons.
--   controls (table)  - All settings cards keyed by name (e.g., controls.frameWidth).
--   cardSets (table)  - Maps section IDs to { simple={cards}, expert={cards} }
--                        to control which cards are visible per tune mode.
--   modeUI (table)    - Holds Simple/Expert mode UI elements and status text.
--
-- STEP 1 (Profiles):  "Start Fresh" or "Import" choice, plus quick-import
--                      from another character.
-- STEP 2 (Playstyle): Simple/Expert toggle, preset buttons, command rail
--                      with unlock/lock/preview/settings, and a scrollable
--                      workspace of tuning cards organized into sections
--                      (Profile, Frames, Combat, Modules, Systems, Overlay).
-- STEP 3 (Finish):    Discord/Patreon social tiles, configuration snapshot
--                      summary, and "Finish Setup" button.
-- ============================================================================

--- CreateWelcomeFrame: Builds and returns the entire welcome wizard frame.
-- @return (Frame) - The wizard frame with .Refresh(), .ShowStep(), .AnimateSize()
-- @calledby MidnightUI_ShowWelcome (lazy, called once)
local function CreateWelcomeFrame()
    -- Adaptive sizing: wizard scales to screen but caps at practical maximums
    local screenW = (UIParent and UIParent.GetWidth and UIParent:GetWidth()) or 1920
    local screenH = (UIParent and UIParent.GetHeight and UIParent:GetHeight()) or 1080
    if screenW < 500 then screenW = 1920 end
    if screenH < 400 then screenH = 1080 end
    local maxSafeW = math.floor(screenW * 0.92)
    local maxSafeH = math.floor(screenH * 0.90)

    -- BASE_W/H: initial wizard size (Step 1). EXPANDED_W/H: larger size for Step 2+.
    local BASE_W = math.max(1040, math.min(maxSafeW, 1320, math.floor(screenW * 0.62)))
    local BASE_H = math.max(660, math.min(maxSafeH, 780, math.floor(screenH * 0.70)))
    local EXPANDED_W = math.max(BASE_W + 80, math.min(maxSafeW, 1500, math.floor(screenW * 0.70)))
    local EXPANDED_H = math.max(BASE_H + 70, math.min(maxSafeH, 920, math.floor(screenH * 0.78)))
    local f = CreatePanel(UIParent, BASE_W, BASE_H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(110)
    f:Hide()

    -- ESC to close
    f:EnableKeyboard(true)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            self:Hide()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    --- state: Wizard session state tracking all user selections.
    -- Reset each time the wizard opens. Not persisted directly; values are
    -- written into MidnightUISettings by Apply* functions.
    local state = {
        preset = "MidnightUI",            -- active preset name
        simplePlaystyle = "Mythic+",      -- Simple mode playstyle selection
        roleProfile = "Auto Detect",      -- combat role (Auto/Tank/Healer/DD)
        contentProfile = "Mythic+ Dungeons", -- main activity type
        readabilityPreset = "Balanced",   -- UI scale tier (Compact/Balanced/Large)
        tuneMode = "Simple",              -- "Simple" or "Expert" card visibility
        overlayTarget = "Player Frame",   -- currently selected overlay element
        actionBarSlot = "Action Bar 1",   -- which action bar is being edited
        lastAppliedAt = nil,              -- HH:MM:SS timestamp of last apply
    }

    f._ambient = f:CreateTexture(nil, "BACKGROUND")
    f._ambient:SetTexture("Interface\\Buttons\\WHITE8X8")
    f._ambient:SetPoint("TOPLEFT", 1, -1)
    f._ambient:SetPoint("BOTTOMRIGHT", -1, 1)
    f._ambient:SetVertexColor(0.03, 0.06, 0.11, 0.75)

    local leftRail = CreatePanel(f, 214, BASE_H)
    leftRail:SetPoint("TOPLEFT", 0, 0)
    leftRail:SetBackdropColor(0.04, 0.06, 0.12, 0.95)
    f._leftRail = leftRail

    leftRail._glow = leftRail:CreateTexture(nil, "ARTWORK")
    leftRail._glow:SetTexture("Interface\\Buttons\\WHITE8X8")
    leftRail._glow:SetPoint("TOPLEFT", 0, 0)
    leftRail._glow:SetPoint("TOPRIGHT", 0, 0)
    leftRail._glow:SetHeight(170)
    leftRail._glow:SetVertexColor(0.08, 0.15, 0.25, 0.55)

    leftRail._title = leftRail:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    leftRail._title:SetPoint("TOPLEFT", 18, -20)
    leftRail._title:SetText("MIDNIGHT UI")
    leftRail._title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(leftRail._title, 14)

    leftRail._sub = leftRail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    leftRail._sub:SetPoint("TOPLEFT", 18, -44)
    leftRail._sub:SetText("SETUP WIZARD")
    leftRail._sub:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])

    leftRail._ringA = leftRail:CreateTexture(nil, "ARTWORK")
    leftRail._ringA:SetTexture("Interface\\Buttons\\WHITE8X8")
    if leftRail._ringA.SetMaskTexture then
        leftRail._ringA:SetMaskTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end
    leftRail._ringA:SetSize(118, 118)
    leftRail._ringA:SetPoint("BOTTOM", leftRail, "BOTTOM", 2, 36)
    leftRail._ringA:SetVertexColor(0.00, 0.78, 1.00, 0.34)
    leftRail._ringA:SetBlendMode("ADD")

    leftRail._ringB = leftRail:CreateTexture(nil, "ARTWORK")
    leftRail._ringB:SetTexture("Interface\\Buttons\\WHITE8X8")
    if leftRail._ringB.SetMaskTexture then
        leftRail._ringB:SetMaskTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    end
    leftRail._ringB:SetSize(70, 70)
    leftRail._ringB:SetPoint("CENTER", leftRail._ringA, "CENTER", 0, 0)
    leftRail._ringB:SetVertexColor(0.15, 0.72, 1.00, 0.48)
    leftRail._ringB:SetBlendMode("ADD")
    local ringA = leftRail._ringA
    local ringB = leftRail._ringB

    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", leftRail, "TOPRIGHT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", 0, 0)

    content._headerBg = content:CreateTexture(nil, "BACKGROUND")
    content._headerBg:SetPoint("TOPLEFT", 0, 0)
    content._headerBg:SetPoint("TOPRIGHT", 0, 0)
    content._headerBg:SetHeight(68)
    content._headerBg:SetColorTexture(0.04, 0.06, 0.12, 0.92)
    CreateHeaderLine(content, -68)

    local title = content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 20, -18)
    title:SetText("Welcome to MidnightUI")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(title, 20)

    local subtitle = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", 20, -44)
    subtitle:SetText("Set up in 3 steps")
    subtitle:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local close = CreateFrame("Button", nil, f, "BackdropTemplate")
    close:SetSize(22, 22)
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetText("X")
    close:SetNormalFontObject("GameFontNormalSmall")
    StyleButton(close)
    close:SetScript("OnClick", function() f:Hide() end)

    local stepBar = CreateFrame("Frame", nil, leftRail)
    stepBar:SetPoint("TOPLEFT", 14, -92)
    stepBar:SetPoint("TOPRIGHT", -14, -92)
    stepBar:SetHeight(150)

    local stepButtons = {}
    local stepPages = {}
    local currentStep = 1
    local unlockedStep = 1

    local pageHost = CreateFrame("Frame", nil, content)
    pageHost:SetPoint("TOPLEFT", 16, -82)
    pageHost:SetPoint("BOTTOMRIGHT", -16, 60)

    local footer = CreateFrame("Frame", nil, content, "BackdropTemplate")
    footer:SetPoint("BOTTOMLEFT", 0, 0)
    footer:SetPoint("BOTTOMRIGHT", 0, 0)
    footer:SetHeight(56)
    footer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 0, right = 0, top = 1, bottom = 0 }
    })
    footer:SetBackdropColor(0.04, 0.06, 0.12, 0.9)
    footer:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.75)

    local btnBack = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
    btnBack:SetPoint("LEFT", 16, 0)
    btnBack:SetSize(120, 30)
    btnBack:SetText("Back")
    StyleButton(btnBack)

    local btnNext = CreateFrame("Button", nil, footer, "UIPanelButtonTemplate")
    btnNext:SetPoint("RIGHT", -16, 0)
    btnNext:SetSize(160, 30)
    btnNext:SetText("Next")
    StyleButton(btnNext)

    local footerStatus = footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    footerStatus:SetPoint("LEFT", btnBack, "RIGHT", 12, 0)
    footerStatus:SetPoint("RIGHT", btnNext, "LEFT", -12, 0)
    footerStatus:SetText("")
    footerStatus:SetJustifyH("CENTER")
    footerStatus:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    local function SetFooterStatus(text, r, g, b)
        footerStatus:SetText(text or "")
        footerStatus:SetTextColor(r or UI_COLORS.muted[1], g or UI_COLORS.muted[2], b or UI_COLORS.muted[3])
    end

    local stepCaptions = {
        [1] = "Profiles",
        [2] = "Playstyle",
        [3] = "Ready Check",
    }

    local function CreateStepButton(idx, label)
        local b = CreateFrame("Button", nil, stepBar, "BackdropTemplate")
        b:SetSize(172, 36)
        b:SetPoint("TOPLEFT", 0, -((idx - 1) * 44))
        b:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8", edgeFile = "Interface\\Buttons\\WHITE8X8", edgeSize = 1 })
        b:SetBackdropColor(0.08, 0.11, 0.17, 0.84)
        b:SetBackdropBorderColor(0.15, 0.20, 0.28, 1)

        local glow = b:CreateTexture(nil, "ARTWORK")
        glow:SetTexture("Interface\\Buttons\\WHITE8X8")
        glow:SetPoint("TOPLEFT", 1, -1)
        glow:SetPoint("BOTTOMRIGHT", -1, 1)
        glow:SetVertexColor(0, 0, 0, 0)
        b._glow = glow

        local num = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        num:SetPoint("LEFT", 10, 0)
        num:SetText(tostring(idx))
        num:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
        b._num = num

        local txt = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        txt:SetPoint("LEFT", num, "RIGHT", 10, 0)
        txt:SetText(label)
        txt:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
        b._txt = txt

        return b
    end

    for i = 1, 3 do
        stepButtons[i] = CreateStepButton(i, stepCaptions[i])
    end

    local onStepChanged = nil
    local previewDock = nil

    local function ExitPreviewMode()
        -- Lock movement mode when returning to wizard
        local st = EnsureSettings()
        st.Messenger.locked = true
        local settingsApi = _G.MidnightUI_Settings
        if settingsApi and settingsApi.GridFrame then settingsApi.GridFrame:Hide() end
        if settingsApi and settingsApi.MoveHUD then settingsApi.MoveHUD:Hide() end
        if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Hide() end
        if controls and controls.overlayHandles then controls.overlayHandles:SetChecked(false) end
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility(st) end
        ApplyAllSettings("WELCOME_EXIT_PREVIEW")
        -- Clear the wizard flag
        _G.MidnightUI_MovementModeFromWizard = false
        if previewDock then previewDock:Hide() end
        f:Show()
        f:Raise()
        if onStepChanged then onStepChanged(currentStep) end
    end

    local function EnsurePreviewDock()
        if previewDock then return previewDock end
        previewDock = CreatePanel(UIParent, 404, 62)
        previewDock:SetPoint("TOP", UIParent, "TOP", 0, -132)
        previewDock:SetFrameStrata("DIALOG")
        previewDock:SetFrameLevel(220)
        previewDock:SetBackdropColor(0.06, 0.10, 0.17, 0.95)

        local dockGlow = previewDock:CreateTexture(nil, "BACKGROUND")
        dockGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
        dockGlow:SetPoint("TOPLEFT", 1, -1)
        dockGlow:SetPoint("TOPRIGHT", -1, -1)
        dockGlow:SetHeight(24)
        dockGlow:SetVertexColor(0.08, 0.18, 0.31, 0.55)

        local dockText = previewDock:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        dockText:SetPoint("LEFT", 12, 0)
        dockText:SetPoint("RIGHT", -146, 0)
        dockText:SetJustifyH("LEFT")
        dockText:SetText("Preview mode is active.")
        dockText:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
        TrySetFont(dockText, 12)
        previewDock._msg = dockText

        local btnReturn = CreateFrame("Button", nil, previewDock, "UIPanelButtonTemplate")
        btnReturn:SetPoint("RIGHT", -10, 0)
        btnReturn:SetSize(128, 30)
        btnReturn:SetText("Return to Setup")
        StyleButton(btnReturn)
        btnReturn:SetScript("OnClick", ExitPreviewMode)

        previewDock:Hide()
        return previewDock
    end

    local function EnterPreviewMode(message)
        local dock = EnsurePreviewDock()
        if dock and dock._msg then
            dock._msg:SetText(message or "Preview your settings in the world, then return here.")
        end
        f:Hide()
        if dock then dock:Show() end
    end

    local function RefreshStepButtons()
        for i = 1, 3 do
            local b = stepButtons[i]
            if b then
                local locked = i > unlockedStep
                if i == currentStep then
                    b:SetBackdropColor(0.10, 0.18, 0.29, 1)
                    b._glow:SetVertexColor(0.00, 0.78, 1.00, 0.14)
                    b._txt:SetTextColor(1, 1, 1)
                elseif locked then
                    b:SetBackdropColor(0.07, 0.08, 0.12, 0.7)
                    b._glow:SetVertexColor(0, 0, 0, 0)
                    b._txt:SetTextColor(0.39, 0.41, 0.46)
                else
                    b:SetBackdropColor(0.08, 0.11, 0.17, 0.86)
                    b._glow:SetVertexColor(0, 0, 0, 0)
                    b._txt:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
                end
            end
        end
    end

    local function ShowStep(idx, force)
        if idx < 1 or idx > 3 then return end
        if not force and idx > unlockedStep then return end
        -- Prevent navigating forward from step 1 without using the action buttons
        if not force and currentStep == 1 and idx > 1 then return end
        currentStep = idx
        if currentStep > unlockedStep then unlockedStep = currentStep end
        for i = 1, 3 do
            if stepPages[i] then stepPages[i]:Hide() end
        end
        if stepPages[idx] then stepPages[idx]:Show() end
        subtitle:SetText(idx == 1 and "Import a profile or start from scratch"
            or idx == 2 and "Set role and content, then tune visuals with live previews"
            or "Review community links, then finish setup")
        RefreshStepButtons()
        if onStepChanged then onStepChanged(idx) end
    end

    for i = 1, 3 do
        stepButtons[i]:SetScript("OnClick", function()
            ShowStep(i, false)
        end)
    end

    local p1 = CreateFrame("Frame", nil, pageHost)
    p1:SetAllPoints()
    stepPages[1] = p1

    local p1Tag = p1:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p1Tag:SetPoint("TOPLEFT", 4, -6)
    p1Tag:SetText("STEP 1  START")
    p1Tag:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    TrySetFont(p1Tag, 12, "OUTLINE")

    local p1Head = p1:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p1Head:SetPoint("TOPLEFT", 4, -26)
    p1Head:SetText("Start with your profile")
    p1Head:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(p1Head, 20, "OUTLINE")

    local p1Sub = p1:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p1Sub:SetPoint("TOPLEFT", 4, -52)
    p1Sub:SetPoint("TOPRIGHT", -4, -52)
    p1Sub:SetJustifyH("LEFT")
    p1Sub:SetText("Choose your path: import an existing profile, or begin fresh and fine-tune everything with live previews.")
    p1Sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(p1Sub, 14)
    CreateHeaderLine(p1, -82)

    local actionRow = CreateFrame("Frame", nil, p1)
    actionRow:SetPoint("TOPLEFT", 4, -94)
    actionRow:SetPoint("TOPRIGHT", -4, -94)
    actionRow:SetHeight(206)

    local tileFresh = CreateActionTile(
        actionRow,
        "Start a New Profile",
        "Build a solid baseline now, then tune role, visuals, and overlays in Step 2.",
        "Start Fresh",
        626001,
        function()
            if f and f.AnimateSize then f:AnimateSize(EXPANDED_W, EXPANDED_H, 0.25) end
            unlockedStep = math.max(unlockedStep, 2)
            ShowStep(2, true)
        end,
        1, 206
    )
    tileFresh:ClearAllPoints()
    tileFresh:SetPoint("TOPLEFT", actionRow, "TOPLEFT", 0, 0)
    tileFresh:SetPoint("BOTTOMRIGHT", actionRow, "BOTTOM", -6, 0)
    local tileImport = CreateActionTile(
        actionRow,
        "Import a Profile",
        "Paste a profile code, or copy settings from another character on your account.",
        "Open Import",
        134939,
        function()
            _G.MidnightUI_ShowProfileImport(function()
                if Profiles and Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
                f:Hide()
            end)
        end,
        1, 206
    )
    tileImport:ClearAllPoints()
    tileImport:SetPoint("TOPLEFT", actionRow, "TOP", 6, 0)
    tileImport:SetPoint("BOTTOMRIGHT", actionRow, "BOTTOMRIGHT", 0, 0)

    local quickBox = CreatePanel(p1, 1, 198)
    quickBox:SetPoint("TOPLEFT", 4, -304)
    quickBox:SetPoint("TOPRIGHT", -4, -304)
    quickBox:SetBackdropColor(UI_COLORS.inset[1], UI_COLORS.inset[2], UI_COLORS.inset[3], 0.92)

    local quickGlow = quickBox:CreateTexture(nil, "BACKGROUND")
    quickGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    quickGlow:SetPoint("TOPLEFT", 1, -1)
    quickGlow:SetPoint("TOPRIGHT", -1, -1)
    quickGlow:SetHeight(30)
    quickGlow:SetVertexColor(0.08, 0.16, 0.28, 0.45)

    local quickTitle = quickBox:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    quickTitle:SetPoint("TOPLEFT", 14, -10)
    quickTitle:SetText("Copy from an Existing Character.")
    quickTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(quickTitle, 13, "OUTLINE")

    local quickBody = quickBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickBody:SetPoint("TOPLEFT", 14, -30)
    quickBody:SetPoint("TOPRIGHT", -14, -30)
    quickBody:SetJustifyH("LEFT")
    quickBody:SetText("Pick a saved profile, import it, then jump straight into fine-tuning.")
    quickBody:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(quickBody, 12)

    local quickDrop = CreateFrame("Frame", "MidnightUI_WelcomeQuickImportDropdown", quickBox, "UIDropDownMenuTemplate")
    quickDrop:SetPoint("TOPLEFT", 10, -60)
    UIDropDownMenu_SetWidth(quickDrop, 330)
    UIDropDownMenu_SetText(quickDrop, "Choose character profile")

    local quickTips = quickBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickTips:SetPoint("TOPLEFT", quickDrop, "TOPRIGHT", 20, -2)
    quickTips:SetPoint("TOPRIGHT", -14, -60)
    quickTips:SetJustifyH("LEFT")
    quickTips:SetText("|cffffff00Tip:|r\nUse \"Start Fresh\" if you want to rebuild from scratch.\nUse import when you already trust another setup.")
    quickTips:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(quickTips, 12)

    local quickStatus = quickBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    quickStatus:SetPoint("BOTTOMLEFT", 14, 14)
    quickStatus:SetText("")
    quickStatus:SetTextColor(1, 0.4, 0.4)
    TrySetFont(quickStatus, 12)

    local btnQuickImport = CreateFrame("Button", nil, quickBox, "UIPanelButtonTemplate")
    btnQuickImport:SetPoint("BOTTOMRIGHT", -14, 12)
    btnQuickImport:SetSize(162, 30)
    btnQuickImport:SetText("Import Selected")
    StyleButton(btnQuickImport)

    local btnQuickRefresh = CreateFrame("Button", nil, quickBox, "UIPanelButtonTemplate")
    btnQuickRefresh:SetPoint("RIGHT", btnQuickImport, "LEFT", -8, 0)
    btnQuickRefresh:SetSize(108, 30)
    btnQuickRefresh:SetText("Refresh List")
    StyleButton(btnQuickRefresh)

    local quickOptions = {}
    local quickSelectedKey = nil

    local function RefreshQuickOptions()
        quickOptions = ResolveProfileOptions()
        quickSelectedKey = nil
        UIDropDownMenu_SetText(quickDrop, "Choose character profile")
        quickStatus:SetText("")
        if #quickOptions == 0 then
            UIDropDownMenu_SetText(quickDrop, "No character profiles found yet")
            if quickDrop.Text then
                quickDrop.Text:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
            end
        else
            UIDropDownMenu_SetText(quickDrop, "Choose character profile")
            if quickDrop.Text then
                quickDrop.Text:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
            end
        end

        UIDropDownMenu_Initialize(quickDrop, function()
            if #quickOptions == 0 then
                local info = UIDropDownMenu_CreateInfo()
                info.text = "No other character profiles found"
                info.disabled = true
                UIDropDownMenu_AddButton(info)
                return
            end
            for _, entry in ipairs(quickOptions) do
                local info = UIDropDownMenu_CreateInfo()
                info.text = entry.label
                info.func = function()
                    quickSelectedKey = entry.key
                UIDropDownMenu_SetText(quickDrop, entry.label)
                if quickDrop.Text then
                    quickDrop.Text:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
                end
                local created = entry.createdAt and date("%b %d, %Y", entry.createdAt) or "Unknown"
                quickStatus:SetText("Selected: " .. entry.label .. "  Saved: " .. created)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
    end

    btnQuickImport:SetScript("OnClick", function()
        quickStatus:SetText("")
        if not quickSelectedKey then
            quickStatus:SetText("Select a profile first.")
            return
        end
        if not Profiles or not Profiles.ImportProfileFromKey then
            quickStatus:SetText("Profile system is not available.")
            return
        end
        local ok, err = Profiles.ImportProfileFromKey(quickSelectedKey)
        if ok then
            if Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
            f:Hide()
            return
        end
        quickStatus:SetText("Import failed. Check Diagnostics for details.")
        Log("Quick import failed: " .. tostring(err))
    end)

    btnQuickRefresh:SetScript("OnClick", RefreshQuickOptions)

    local p2 = CreateFrame("Frame", nil, pageHost)
    p2:SetAllPoints()
    p2:Hide()
    stepPages[2] = p2

    local p2Tag = p2:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p2Tag:SetPoint("TOPLEFT", 4, -6)
    p2Tag:SetText("STEP 2  PLAYSTYLE & TUNING")
    p2Tag:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    TrySetFont(p2Tag, 12, "OUTLINE")

    local p2Head = p2:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p2Head:SetPoint("TOPLEFT", 4, -26)
    p2Head:SetText("Build Your Battle UI: Simple or Expert")
    p2Head:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(p2Head, 20, "OUTLINE")

    local p2Sub = p2:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p2Sub:SetPoint("TOPLEFT", 4, -52)
    p2Sub:SetPoint("TOPRIGHT", -4, -52)
    p2Sub:SetJustifyH("LEFT")
    p2Sub:SetText("Simple asks a few key questions and sets the rest for you. Expert shows all options so you can tune everything yourself.")
    p2Sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(p2Sub, 14)
    CreateHeaderLine(p2, -82)

    local controls = {}
    local modeUI = {}

    local modeBand = CreatePanel(p2, 1, 112)
    modeBand:SetPoint("TOPLEFT", 4, -86)
    modeBand:SetPoint("TOPRIGHT", -4, -86)
    modeBand:SetBackdropColor(0.055, 0.09, 0.16, 0.95)

    local modeGlow = modeBand:CreateTexture(nil, "BACKGROUND")
    modeGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    modeGlow:SetPoint("TOPLEFT", 1, -1)
    modeGlow:SetPoint("TOPRIGHT", -1, -1)
    modeGlow:SetHeight(32)
    modeGlow:SetVertexColor(0.09, 0.20, 0.33, 0.62)

    local modeTitle = modeBand:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeTitle:SetPoint("TOPLEFT", 12, -8)
    modeTitle:SetText("Choose How You Want to Set Up")
    modeTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(modeTitle, 14, "OUTLINE")

    local modeBody = modeBand:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeBody:SetPoint("TOPLEFT", 12, -30)
    modeBody:SetPoint("TOPRIGHT", -12, -30)
    modeBody:SetJustifyH("LEFT")
    modeBody:SetText("Simple is quick and safe for most players. Expert gives full control of frames, combat info, modules, and system options.")
    modeBody:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(modeBody, 12)

    modeUI.simpleCard = CreatePanel(modeBand, 1, 44)
    modeUI.simpleCard:SetPoint("TOPLEFT", 12, -58)
    modeUI.simpleCard:SetPoint("RIGHT", modeBand, "CENTER", -6, 0)
    modeUI.simpleCard:SetBackdropColor(0.05, 0.11, 0.18, 0.96)

    local simpleTitle = modeUI.simpleCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    simpleTitle:SetPoint("LEFT", 10, 0)
    simpleTitle:SetText("Simple")
    simpleTitle:SetTextColor(0.86, 0.96, 1.00)
    TrySetFont(simpleTitle, 13, "OUTLINE")

    modeUI.btnSimple = CreateFrame("Button", nil, modeUI.simpleCard, "UIPanelButtonTemplate")
    modeUI.btnSimple:SetSize(112, 24)
    modeUI.btnSimple:SetPoint("RIGHT", -8, 0)
    modeUI.btnSimple:SetText("Use Mode")
    StyleButton(modeUI.btnSimple)

    modeUI.expertCard = CreatePanel(modeBand, 1, 44)
    modeUI.expertCard:SetPoint("TOPRIGHT", -12, -58)
    modeUI.expertCard:SetPoint("LEFT", modeBand, "CENTER", 6, 0)
    modeUI.expertCard:SetBackdropColor(0.10, 0.07, 0.12, 0.96)

    local expertTitle = modeUI.expertCard:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    expertTitle:SetPoint("LEFT", 10, 0)
    expertTitle:SetText("Expert")
    expertTitle:SetTextColor(1.00, 0.92, 0.96)
    TrySetFont(expertTitle, 13, "OUTLINE")

    modeUI.btnExpert = CreateFrame("Button", nil, modeUI.expertCard, "UIPanelButtonTemplate")
    modeUI.btnExpert:SetSize(112, 24)
    modeUI.btnExpert:SetPoint("RIGHT", -8, 0)
    modeUI.btnExpert:SetText("Use Mode")
    StyleButton(modeUI.btnExpert)

    local commandRail = CreatePanel(p2, 304, 1)
    commandRail:SetPoint("TOPLEFT", 4, -204)
    commandRail:SetPoint("BOTTOMLEFT", 4, 6)
    commandRail:SetBackdropColor(0.055, 0.09, 0.16, 0.95)

    local railGlow = commandRail:CreateTexture(nil, "BACKGROUND")
    railGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    railGlow:SetPoint("TOPLEFT", 1, -1)
    railGlow:SetPoint("TOPRIGHT", -1, -1)
    railGlow:SetHeight(30)
    railGlow:SetVertexColor(0.08, 0.18, 0.31, 0.45)

    modeUI.status = commandRail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeUI.status:SetPoint("TOPLEFT", 12, -10)
    modeUI.status:SetPoint("TOPRIGHT", -12, -10)
    modeUI.status:SetJustifyH("LEFT")
    modeUI.status:SetText("")
    modeUI.status:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    TrySetFont(modeUI.status, 12)

    local presetHint = commandRail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    presetHint:SetPoint("TOPLEFT", 12, -42)
    presetHint:SetText("Quick Start Style")
    presetHint:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(presetHint, 12, "OUTLINE")

    local btnPresetBalanced = CreateFrame("Button", nil, commandRail, "UIPanelButtonTemplate")
    btnPresetBalanced:SetSize(132, 28)
    btnPresetBalanced:SetText("Casual")
    StyleButton(btnPresetBalanced)

    local btnPresetMythic = CreateFrame("Button", nil, commandRail, "UIPanelButtonTemplate")
    btnPresetMythic:SetSize(132, 28)
    btnPresetMythic:SetText("Mythic+")
    StyleButton(btnPresetMythic)

    local btnPresetRaid = CreateFrame("Button", nil, commandRail, "UIPanelButtonTemplate")
    btnPresetRaid:SetSize(132, 28)
    btnPresetRaid:SetText("Raider")
    StyleButton(btnPresetRaid)

    local btnPresetArena = CreateFrame("Button", nil, commandRail, "UIPanelButtonTemplate")
    btnPresetArena:SetSize(132, 28)
    btnPresetArena:SetText("PvP")
    StyleButton(btnPresetArena)

    btnPresetBalanced:SetPoint("TOPLEFT", 12, -62)
    btnPresetMythic:SetPoint("TOPRIGHT", -12, -62)
    btnPresetRaid:SetPoint("TOPLEFT", btnPresetBalanced, "BOTTOMLEFT", 0, -8)
    btnPresetArena:SetPoint("TOPLEFT", btnPresetMythic, "BOTTOMLEFT", 0, -8)

    local presetStatus = commandRail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    presetStatus:SetPoint("TOPLEFT", 12, -132)
    presetStatus:SetPoint("TOPRIGHT", -12, -132)
    presetStatus:SetJustifyH("LEFT")
    presetStatus:SetText("")
    presetStatus:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    TrySetFont(presetStatus, 12)

    local railActions = CreatePanel(commandRail, 1, 146)
    railActions:SetPoint("TOPLEFT", 12, -182)
    railActions:SetPoint("TOPRIGHT", -12, -182)
    railActions:SetBackdropColor(0.07, 0.12, 0.20, 0.98)

    local actionTitle = railActions:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    actionTitle:SetPoint("TOPLEFT", 10, -8)
    actionTitle:SetPoint("TOPRIGHT", -10, -8)
    actionTitle:SetJustifyH("LEFT")
    actionTitle:SetText("In-Game Tools")
    actionTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(actionTitle, 12, "OUTLINE")

    local btnUnlockMove = CreateFrame("Button", nil, railActions, "UIPanelButtonTemplate")
    btnUnlockMove:SetSize(132, 28)
    btnUnlockMove:SetPoint("TOPLEFT", 10, -30)
    btnUnlockMove:SetText("Unlock Frames")
    StyleButton(btnUnlockMove)

    local btnLockMove = CreateFrame("Button", nil, railActions, "UIPanelButtonTemplate")
    btnLockMove:SetSize(132, 28)
    btnLockMove:SetPoint("TOPRIGHT", -10, -30)
    btnLockMove:SetText("Lock Frames")
    StyleButton(btnLockMove)

    local btnPreviewWorld = CreateFrame("Button", nil, railActions, "UIPanelButtonTemplate")
    btnPreviewWorld:SetSize(132, 28)
    btnPreviewWorld:SetPoint("TOPLEFT", btnUnlockMove, "BOTTOMLEFT", 0, -8)
    btnPreviewWorld:SetText("Test In World")
    StyleButton(btnPreviewWorld)
    btnPreviewWorld:SetScript("OnClick", function()
        EnterPreviewMode("Test mode: check your UI in combat and open world.")
    end)

    local btnOpenAdvanced = CreateFrame("Button", nil, railActions, "UIPanelButtonTemplate")
    btnOpenAdvanced:SetSize(132, 28)
    btnOpenAdvanced:SetPoint("TOPLEFT", btnLockMove, "BOTTOMLEFT", 0, -8)
    btnOpenAdvanced:SetText("Open All Settings")
    StyleButton(btnOpenAdvanced)
    btnOpenAdvanced:SetScript("OnClick", OpenSettingsPanel)

    modeUI.applied = commandRail:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeUI.applied:SetPoint("TOPLEFT", railActions, "BOTTOMLEFT", 2, -10)
    modeUI.applied:SetPoint("TOPRIGHT", railActions, "BOTTOMRIGHT", -2, -10)
    modeUI.applied:SetJustifyH("LEFT")
    modeUI.applied:SetText("")
    modeUI.applied:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(modeUI.applied, 12)

    local function UpdateWorkspaceHeader()
        if not modeUI.workspaceTitle or not modeUI.workspaceSub then return end
        if state.tuneMode == "Expert" then
            modeUI.workspaceTitle:SetText("Expert Tuning")
            modeUI.workspaceSub:SetText("All options are shown here. Use Open All Settings for the rest of the addon pages.")
        else
            modeUI.workspaceTitle:SetText("Quick Setup  -  " .. tostring(state.simplePlaystyle))
            modeUI.workspaceSub:SetText("Only key options are shown. MidnightUI picks the deeper settings for your playstyle.")
        end
    end

    local function UpdatePresetStatus()
        presetStatus:SetText(
            "Game Style: " .. tostring(state.simplePlaystyle)
                .. "\nRole: " .. tostring(state.roleProfile) .. "   Mode: " .. tostring(state.tuneMode)
                .. "\nUI Scale: " .. tostring(state.readabilityPreset)
        )
        modeUI.applied:SetText("Last Update: " .. tostring(state.lastAppliedAt or "not yet"))
        UpdateWorkspaceHeader()
    end

    local function MarkAppliedNow(ok)
        if ok then
            state.lastAppliedAt = date("%H:%M:%S")
            UpdatePresetStatus()
        end
    end
    UpdatePresetStatus()

    local cardsHost = CreatePanel(p2, 1, 1)
    cardsHost:SetPoint("TOPLEFT", commandRail, "TOPRIGHT", 10, 0)
    cardsHost:SetPoint("TOPRIGHT", -4, -204)
    cardsHost:SetPoint("BOTTOMRIGHT", -4, 6)
    cardsHost:SetBackdropColor(0.05, 0.08, 0.14, 0.94)

    local cardsGlow = cardsHost:CreateTexture(nil, "BACKGROUND")
    cardsGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    cardsGlow:SetPoint("TOPLEFT", 1, -1)
    cardsGlow:SetPoint("TOPRIGHT", -1, -1)
    cardsGlow:SetHeight(46)
    cardsGlow:SetVertexColor(0.08, 0.17, 0.30, 0.55)

    modeUI.workspaceTitle = cardsHost:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    modeUI.workspaceTitle:SetPoint("TOPLEFT", 12, -10)
    modeUI.workspaceTitle:SetPoint("TOPRIGHT", -12, -10)
    modeUI.workspaceTitle:SetJustifyH("LEFT")
    modeUI.workspaceTitle:SetText("Quick Setup")
    modeUI.workspaceTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(modeUI.workspaceTitle, 13, "OUTLINE")

    modeUI.workspaceSub = cardsHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    modeUI.workspaceSub:SetPoint("TOPLEFT", 12, -30)
    modeUI.workspaceSub:SetPoint("TOPRIGHT", -12, -30)
    modeUI.workspaceSub:SetJustifyH("LEFT")
    modeUI.workspaceSub:SetText("")
    modeUI.workspaceSub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(modeUI.workspaceSub, 11)
    UpdateWorkspaceHeader()

    local scroll = CreateFrame("ScrollFrame", nil, cardsHost, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 8, -52)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)
    local scrollContent = CreateFrame("Frame", nil, scroll)
    scrollContent:SetSize(math.max(700, EXPANDED_W - 650), 1880)
    scroll:SetScrollChild(scrollContent)
    local profileHost, framesHost, combatHost, modulesHost, systemsHost, overlayHost = nil, nil, nil, nil, nil, nil

    local s = EnsureSettings()
    local ROLE_OPTIONS = { "Auto Detect", "Tank", "Healer", "Damage Dealer" }
    local CONTENT_OPTIONS = { "Solo / Questing", "Mythic+ Dungeons", "Raid Groups", "Arena / Battleground" }
    local SIMPLE_PLAYSTYLE_OPTIONS = { "Mythic+", "Raider", "PvP", "Casual" }
    local SIMPLE_PLAYSTYLE_TO_CONTENT = {
        ["Mythic+"] = "Mythic+ Dungeons",
        Raider = "Raid Groups",
        ["PvP"] = "Arena / Battleground",
        Casual = "Solo / Questing",
    }
    local CONTENT_TO_SIMPLE_PLAYSTYLE = {
        ["Mythic+ Dungeons"] = "Mythic+",
        ["Raid Groups"] = "Raider",
        ["Arena / Battleground"] = "PvP",
        ["Solo / Questing"] = "Casual",
    }
    local READABILITY_OPTIONS = { "Compact", "Balanced", "Large" }
    local PARTY_STYLE_OPTIONS = { "Rendered", "Simple", "Square" }
    local TARGET_DEBUFF_FILTER_OPTIONS = { "AUTO", "PLAYER", "ALL" }
    local ACTION_BAR_SLOT_OPTIONS = {
        "Action Bar 1", "Action Bar 2", "Action Bar 3", "Action Bar 4",
        "Action Bar 5", "Action Bar 6", "Action Bar 7", "Action Bar 8",
    }
    local OVERLAY_OPTIONS = {
        { label = "Player Frame", key = "PlayerFrame" },
        { label = "Player Auras", key = "PlayerAuras" },
        { label = "Player Debuffs", key = "PlayerDebuffs" },
        { label = "Target Frame", key = "TargetFrame" },
        { label = "Target Auras", key = "TargetAuras" },
        { label = "Target Debuffs", key = "TargetDebuffs" },
        { label = "Target of Target", key = "TargetOfTarget" },
        { label = "Focus Frame", key = "FocusFrame" },
        { label = "Party Frames", key = "PartyFrames" },
        { label = "Raid Frames", key = "RaidFrames" },
        { label = "Main Tank Frames", key = "MainTankFrames" },
        { label = "Messenger", key = "Messenger" },
        { label = "Player Cast Bar", key = "CastBar_player" },
        { label = "Target Cast Bar", key = "CastBar_target" },
        { label = "Focus Cast Bar", key = "CastBar_focus" },
        { label = "Action Bar 1", key = "ActionBar1" },
        { label = "Action Bar 2", key = "ActionBar2" },
        { label = "Action Bar 3", key = "ActionBar3" },
        { label = "Action Bar 4", key = "ActionBar4" },
        { label = "Action Bar 5", key = "ActionBar5" },
        { label = "Action Bar 6", key = "ActionBar6" },
        { label = "Action Bar 7", key = "ActionBar7" },
        { label = "Action Bar 8", key = "ActionBar8" },
        { label = "Consumables Bar", key = "ConsumableBars" },
        { label = "Pet Bar", key = "PetBar" },
        { label = "Stance Bar", key = "StanceBar" },
        { label = "Inventory", key = "Inventory" },
        { label = "Game Menu", key = "InterfaceMenu" },
        { label = "Dispel Tracking", key = "DispelTracking" },
        { label = "Party Dispel Icons", key = "PartyDispelTracking" },
        { label = "XP Bar", key = "XPBar" },
        { label = "Reputation Bar", key = "RepBar" },
        { label = "Minimap", key = "Minimap" },
        { label = "Info Panel", key = "MinimapInfoPanel" },
        { label = "Pet Frame", key = "PetFrame" },
        { label = "Nameplates", key = "Nameplates" },
    }

    state.simplePlaystyle = CONTENT_TO_SIMPLE_PLAYSTYLE[state.contentProfile] or state.simplePlaystyle or "Mythic+"

    local overlayKeyByLabel = {}
    for _, entry in ipairs(OVERLAY_OPTIONS) do
        overlayKeyByLabel[entry.label] = entry.key
    end

    local function ResolveActionBarIndex(selection)
        local idx = tonumber(tostring(selection or ""):match("(%d+)")) or 1
        if idx < 1 then idx = 1 end
        if idx > 8 then idx = 8 end
        return idx
    end

    local function GetSelectedActionBar(st)
        st = st or EnsureSettings()
        local idx = ResolveActionBarIndex(state.actionBarSlot)
        local key = "bar" .. idx
        st.ActionBars[key] = st.ActionBars[key] or {}
        if st.ActionBars[key].enabled == nil then st.ActionBars[key].enabled = true end
        if not st.ActionBars[key].style then st.ActionBars[key].style = "Class Color" end
        if st.ActionBars[key].rows == nil then st.ActionBars[key].rows = 1 end
        if st.ActionBars[key].iconsPerRow == nil then st.ActionBars[key].iconsPerRow = 12 end
        if st.ActionBars[key].scale == nil then st.ActionBars[key].scale = 100 end
        if st.ActionBars[key].spacing == nil then st.ActionBars[key].spacing = 6 end
        return idx, key, st.ActionBars[key]
    end

    local function ResolveDetectedRole()
        local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned("player") or nil
        if role ~= "TANK" and role ~= "HEALER" and role ~= "DAMAGER" and GetSpecializationRole and GetSpecialization then
            local specIndex = GetSpecialization()
            role = specIndex and GetSpecializationRole(specIndex) or nil
        end
        if role == "TANK" then return "Tank" end
        if role == "HEALER" then return "Healer" end
        return "Damage Dealer"
    end

    local function SetPartyStyle(style, st)
        if _G.MidnightUI_SetPartyStyle then
            _G.MidnightUI_SetPartyStyle(style)
        end
        st.PartyFrames.style = style
    end

    local UpdateOverlayPanelVisibility = nil
    local activeOverlayHighlightBorder = nil
    local activeOverlayHighlightToken = 0

    local function HighlightOverlayHandle(key)
        if not key or not _G.MidnightUI_GetOverlayHandle then return false end
        local handle = _G.MidnightUI_GetOverlayHandle(key)
        if not handle then return false end

        local border = handle._muiWelcomeHighlight
        if not border then
            border = CreateFrame("Frame", nil, handle, "BackdropTemplate")
            border:SetBackdrop({
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 2,
                insets = { left = 0, right = 0, top = 0, bottom = 0 },
            })
            border:SetBackdropBorderColor(1.0, 0.15, 0.15, 0.95)
            border:SetFrameStrata("DIALOG")
            border:Hide()
            handle._muiWelcomeHighlight = border
        end

        border:ClearAllPoints()
        border:SetPoint("TOPLEFT", handle, "TOPLEFT", -2, 2)
        border:SetPoint("BOTTOMRIGHT", handle, "BOTTOMRIGHT", 2, -2)
        border:SetFrameLevel((handle:GetFrameLevel() or 1) + 30)

        if activeOverlayHighlightBorder and activeOverlayHighlightBorder ~= border and activeOverlayHighlightBorder.Hide then
            activeOverlayHighlightBorder:Hide()
        end
        activeOverlayHighlightBorder = border
        border:Show()

        activeOverlayHighlightToken = activeOverlayHighlightToken + 1
        local token = activeOverlayHighlightToken
        if C_Timer and C_Timer.After then
            C_Timer.After(6, function()
                if activeOverlayHighlightToken ~= token then return end
                if border and border.Hide then border:Hide() end
                if activeOverlayHighlightBorder == border then
                    activeOverlayHighlightBorder = nil
                end
            end)
        end
        return true
    end

    local function OpenOverlayByLabel(label, highlightOnOpen)
        local key = overlayKeyByLabel[label]
        if key and _G.MidnightUI_ShowOverlaySettings then
            _G.MidnightUI_ShowOverlaySettings(key)
            if highlightOnOpen then
                HighlightOverlayHandle(key)
            end
            EnterPreviewMode("Opened " .. tostring(label) .. " settings. Make changes, then click Return to Setup.")
            return true
        end
        SetFooterStatus("Element settings are not available for " .. tostring(label), UI_COLORS.warning[1], UI_COLORS.warning[2], UI_COLORS.warning[3])
        return false
    end

    local function EnterMovementModeFromWizard()
        if InCombatLockdown and InCombatLockdown() then
            SetFooterStatus("You cannot unlock frames in combat.", UI_COLORS.warning[1], UI_COLORS.warning[2], UI_COLORS.warning[3])
            return
        end
        local st = EnsureSettings()
        st.Messenger.locked = false
        MarkAppliedNow(ApplyAllSettings("WELCOME_MOVE_MODE"))
        local settingsApi = _G.MidnightUI_Settings
        if settingsApi and settingsApi.DrawGrid then settingsApi.DrawGrid() end
        if settingsApi and settingsApi.GridFrame then settingsApi.GridFrame:Show() end
        if settingsApi and settingsApi.MoveHUD then settingsApi.MoveHUD:Show() end
        if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Hide() end
        if controls.overlayHandles then controls.overlayHandles:SetChecked(true) end
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility(st) end
        SetFooterStatus("Frame move mode enabled. Drag frames and right-click for more settings.", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
        -- Set flag to indicate movement mode was entered from wizard
        _G.MidnightUI_MovementModeFromWizard = true
        EnterPreviewMode("Move mode active: drag frames to place them. Right-click any frame for detailed settings.")
    end

    local function LockMovementModeFromWizard()
        local st = EnsureSettings()
        st.Messenger.locked = true
        MarkAppliedNow(ApplyAllSettings("WELCOME_MOVE_MODE_LOCK"))
        local settingsApi = _G.MidnightUI_Settings
        if settingsApi and settingsApi.GridFrame then settingsApi.GridFrame:Hide() end
        if settingsApi and settingsApi.MoveHUD then settingsApi.MoveHUD:Hide() end
        if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Hide() end
        if controls.overlayHandles then controls.overlayHandles:SetChecked(false) end
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility(st) end
        SetFooterStatus("Frame move handles hidden.", UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    end

    btnUnlockMove:SetScript("OnClick", EnterMovementModeFromWizard)
    btnLockMove:SetScript("OnClick", LockMovementModeFromWizard)

    local function CreateSectionShell(parent, titleText, bodyText, mapText, yOffset, panelHeight, accentColor)
        local panel = CreatePanel(parent, 1, panelHeight)
        panel:SetPoint("TOPLEFT", 0, yOffset)
        panel:SetPoint("TOPRIGHT", 0, yOffset)
        panel:SetBackdropColor(0.055, 0.09, 0.16, 0.94)

        local accent = panel:CreateTexture(nil, "ARTWORK")
        accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("BOTTOMLEFT", 1, 1)
        accent:SetWidth(3)
        local aR, aG, aB = 0.00, 0.78, 1.00
        if accentColor and #accentColor >= 3 then
            aR, aG, aB = accentColor[1], accentColor[2], accentColor[3]
        end
        accent:SetVertexColor(aR, aG, aB, 0.88)

        local topGlow = panel:CreateTexture(nil, "BACKGROUND")
        topGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
        topGlow:SetPoint("TOPLEFT", 1, -1)
        topGlow:SetPoint("TOPRIGHT", -1, -1)
        topGlow:SetHeight(34)
        topGlow:SetVertexColor(0.08, 0.17, 0.30, 0.55)

        local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        title:SetPoint("TOPLEFT", 12, -10)
        title:SetText(titleText)
        title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
        TrySetFont(title, 14, "OUTLINE")
        panel._muiTitle = title
        panel._muiBaseTitle = titleText

        local body = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        body:SetPoint("TOPLEFT", 12, -28)
        body:SetPoint("TOPRIGHT", -12, -28)
        body:SetJustifyH("LEFT")
        body:SetText(bodyText)
        body:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
        TrySetFont(body, 12)

        local hasMap = (type(mapText) == "string" and mapText ~= "")
        local map = nil
        if hasMap then
            map = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            map:SetPoint("TOPLEFT", 12, -44)
            map:SetPoint("TOPRIGHT", -12, -44)
            map:SetJustifyH("LEFT")
            map:SetText(mapText)
            map:SetTextColor(0.70, 0.83, 0.92)
            TrySetFont(map, 11)
        end

        local host = CreateFrame("Frame", nil, panel)
        host:SetPoint("TOPLEFT", 12, hasMap and -78 or -58)
        host:SetPoint("BOTTOMRIGHT", -12, 12)
        return panel, host
    end

    local sectionDefs = {}
    local function AddSection(id, titleText, bodyText, mapText, simpleHeight, expertHeight, accentColor)
        local panel, host = CreateSectionShell(scrollContent, titleText, bodyText, mapText, -4, expertHeight, accentColor)
        sectionDefs[#sectionDefs + 1] = {
            id = id,
            panel = panel,
            host = host,
            titleText = titleText,
            simpleHeight = simpleHeight,
            expertHeight = expertHeight,
        }
        return panel, host
    end

    local SECTION_ACCENTS = {
        profile = { 0.00, 0.78, 1.00 },
        frames = { 0.28, 0.86, 0.62 },
        combat = { 1.00, 0.58, 0.28 },
        modules = { 0.96, 0.80, 0.30 },
        systems = { 0.40, 0.78, 0.96 },
        overlay = { 0.86, 0.67, 0.34 },
    }

    profileHost = select(2, AddSection(
        "profile",
        "Your Playstyle Core",
        "Pick your role, main activity, and UI scale. Simple mode builds a strong baseline from these choices.",
        "Found in Settings: Presets + Interface > General",
        250,
        380,
        SECTION_ACCENTS.profile
    ))

    framesHost = select(2, AddSection(
        "frames",
        "Unit Frames and Groups",
        "Set size and spacing for player, target, focus, party, and raid frames so combat stays easy to read.",
        "Found in Settings: Player, Target, Focus, Party, Raid",
        220,
        660,
        SECTION_ACCENTS.frames
    ))

    combatHost = select(2, AddSection(
        "combat",
        "Combat Clarity",
        "Choose what stands out in fights: nameplates, debuffs, cast bars, quest tracker, and action bar style.",
        "Found in Settings: Nameplates, Cast Bars, Quest Tracker, Action Bars",
        220,
        660,
        SECTION_ACCENTS.combat
    ))

    modulesHost = select(2, AddSection(
        "modules",
        "Modules and Bars",
        "Turn major UI pieces on or off, then tune action bars, consumables, pet bar, and stance bar.",
        "Found in Settings: Frame Modules, Action Bars, Consumables, Pet, Stance",
        210,
        800,
        SECTION_ACCENTS.modules
    ))

    systemsHost = select(2, AddSection(
        "systems",
        "Chat and Minimap",
        "Control chat noise, timestamp visibility, minimap info, and coordinate display.",
        "Found in Settings: Interface > Chat and Minimap",
        0,
        450,
        SECTION_ACCENTS.systems
    ))

    local overlayPanel
    overlayPanel, overlayHost = AddSection(
        "overlay",
        "Move and Fine-Tune",
        "Open per-element settings from the same right-click menus used in movement mode.",
        "Found in: Movement Mode right-click menus (frames, cast bars, action bars, chat, and more)",
        0,
        350,
        SECTION_ACCENTS.overlay
    )

    local function CountCards(cards)
        local count = 0
        for _, card in ipairs(cards or {}) do
            if card then count = count + 1 end
        end
        return count
    end

    local function EstimatePanelHeight(def, cards, isSimple)
        local minH = isSimple and def.simpleHeight or def.expertHeight
        local count = CountCards(cards)
        if count <= 0 then return minH end

        local hostW = (def.host and def.host.GetWidth and def.host:GetWidth()) or 520
        if hostW < 320 then hostW = 520 end
        local usable = math.max(260, hostW - (CARD_LAYOUT.leftX * 2))
        local cols = 2
        local cardW = math.floor((usable - CARD_LAYOUT.gapX) / 2)
        if cardW < CARD_LAYOUT.minWidth then
            cols = 1
        end
        local rows = math.max(1, math.ceil(count / cols))
        local contentH = ((rows - 1) * CARD_LAYOUT.gapY) + CARD_LAYOUT.defaultHeight + 20
        local wanted = 92 + contentH
        return math.max(minH, wanted)
    end

    local function ApplySectionLayout(activeCardsById)
        local isSimple = (state.tuneMode ~= "Expert")
        local sectionY = -4
        for _, def in ipairs(sectionDefs) do
            local panel = def.panel
            if panel then
                local cards = activeCardsById and activeCardsById[def.id] or nil
                local cardCount = CountCards(cards)
                if cardCount > 0 then
                    local h = EstimatePanelHeight(def, cards, isSimple)
                    panel:Show()
                    panel:ClearAllPoints()
                    panel:SetPoint("TOPLEFT", 0, sectionY)
                    panel:SetPoint("TOPRIGHT", 0, sectionY)
                    panel:SetHeight(h)
                    if panel._muiTitle then
                        panel._muiTitle:SetText((def.titleText or panel._muiBaseTitle or "") .. "  (" .. tostring(cardCount) .. ")")
                    end
                    sectionY = sectionY - (h + 16)
                else
                    panel:Hide()
                end
            end
        end
        scrollContent:SetHeight(math.max(420, math.abs(sectionY) + 24))
    end

    local function ApplyRoleProfile(st, selection)
        local resolved = selection
        if selection == "Auto Detect" then
            resolved = ResolveDetectedRole()
        end

        if resolved == "Tank" then
            st.TargetFrame.debuffs.filterMode = "ALL"
            st.TargetFrame.debuffs.maxShown = 24
            st.Nameplates.threatBar.enabled = true
            st.Nameplates.threatBar.height = 6
            st.Nameplates.threatBar.width = 210
            st.CastBars.target.scale = 108
            st.CastBars.target.width = 390
            st.PlayerFrame.width = 392
            st.TargetFrame.width = 392
        elseif resolved == "Healer" then
            st.TargetFrame.debuffs.filterMode = "AUTO"
            st.TargetFrame.debuffs.maxShown = 16
            st.RaidFrames.groupBy = true
            st.RaidFrames.colorByGroup = true
            st.RaidFrames.groupBrackets = true
            st.RaidFrames.columns = 8
            st.RaidFrames.width = 104
            st.RaidFrames.height = 28
            st.PartyFrames.layout = "Vertical"
            SetPartyStyle("Rendered", st)
            st.PartyFrames.width = 252
            st.PartyFrames.height = 62
            st.Nameplates.healthBar.nameFontSize = 11
            st.Nameplates.healthBar.healthPctFontSize = 10
        else
            st.TargetFrame.debuffs.filterMode = "PLAYER"
            st.TargetFrame.debuffs.maxShown = 18
            st.Nameplates.threatBar.enabled = true
            st.CastBars.target.scale = 100
            st.CastBars.target.width = 360
        end

        return resolved
    end

    local function ApplyContentProfile(st, selection)
        if selection == "Solo / Questing" then
            st.PartyFrames.layout = "Vertical"
            SetPartyStyle("Rendered", st)
            st.PartyFrames.width = 228
            st.PartyFrames.height = 56
            st.PartyFrames.spacingY = 8
            st.RaidFrames.groupBy = false
            st.RaidFrames.groupBrackets = false
            st.RaidFrames.columns = 5
            st.RaidFrames.width = 88
            st.RaidFrames.height = 22
            st.ConsumableBars.showInInstancesOnly = false
            st.ConsumableBars.hideInactive = true
            st.General.hideQuestObjectivesInCombat = false
        elseif selection == "Mythic+ Dungeons" then
            st.PartyFrames.layout = "Vertical"
            SetPartyStyle("Rendered", st)
            st.PartyFrames.width = 246
            st.PartyFrames.height = 60
            st.PartyFrames.spacingY = 7
            st.RaidFrames.groupBy = false
            st.RaidFrames.groupBrackets = false
            st.RaidFrames.columns = 5
            st.RaidFrames.width = 88
            st.RaidFrames.height = 22
            st.TargetFrame.debuffs.filterMode = "ALL"
            st.TargetFrame.debuffs.maxShown = 24
            st.CastBars.target.scale = 110
            st.Nameplates.threatBar.enabled = true
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
            st.General.hideQuestObjectivesInCombat = true
        elseif selection == "Raid Groups" then
            st.PartyFrames.layout = "Vertical"
            SetPartyStyle("Simple", st)
            st.PartyFrames.width = 226
            st.PartyFrames.height = 52
            st.PartyFrames.spacingY = 6
            st.RaidFrames.groupBy = true
            st.RaidFrames.colorByGroup = true
            st.RaidFrames.groupBrackets = true
            st.RaidFrames.columns = 8
            st.RaidFrames.width = 104
            st.RaidFrames.height = 28
            st.RaidFrames.spacingX = 4
            st.RaidFrames.spacingY = 3
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
            st.General.hideQuestObjectivesInCombat = true
        elseif selection == "Arena / Battleground" then
            st.PartyFrames.layout = "Horizontal"
            SetPartyStyle("Simple", st)
            st.PartyFrames.width = 218
            st.PartyFrames.height = 52
            st.PartyFrames.spacingX = 6
            st.RaidFrames.groupBy = false
            st.RaidFrames.groupBrackets = false
            st.RaidFrames.columns = 5
            st.RaidFrames.width = 86
            st.RaidFrames.height = 22
            st.TargetFrame.debuffs.filterMode = "ALL"
            st.TargetFrame.debuffs.maxShown = 24
            st.CastBars.target.scale = 110
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
            st.General.hideQuestObjectivesInCombat = true
        else
            st.PartyFrames.layout = "Vertical"
            SetPartyStyle("Rendered", st)
            st.PartyFrames.width = 240
            st.PartyFrames.height = 58
            st.PartyFrames.spacingY = 8
            st.RaidFrames.groupBy = true
            st.RaidFrames.groupBrackets = true
            st.RaidFrames.columns = 5
            st.RaidFrames.width = 92
            st.RaidFrames.height = 24
            st.ConsumableBars.showInInstancesOnly = false
            st.ConsumableBars.hideInactive = false
            st.General.hideQuestObjectivesInCombat = true
        end
    end

    local function ApplyReadabilityPreset(st, selection)
        if selection == "Compact" then
            st.PlayerFrame.width = 340
            st.PlayerFrame.height = 60
            st.PlayerFrame.scale = 96
            st.TargetFrame.width = 340
            st.TargetFrame.height = 60
            st.TargetFrame.scale = 96
            st.FocusFrame.width = 290
            st.FocusFrame.height = 52
            st.FocusFrame.scale = 96
            st.PartyFrames.width = 220
            st.PartyFrames.height = 52
            st.PartyFrames.diameter = 58
            st.RaidFrames.width = 86
            st.RaidFrames.height = 22
            st.MainTankFrames.width = 240
            st.MainTankFrames.height = 52
            st.MainTankFrames.scale = 0.95
            st.CastBars.player.width = 330
            st.CastBars.player.height = 18
            st.CastBars.player.scale = 95
            st.CastBars.target.width = 330
            st.CastBars.target.height = 18
            st.CastBars.target.scale = 95
            st.CastBars.focus.width = 290
            st.CastBars.focus.height = 18
            st.CastBars.focus.scale = 95
            st.Nameplates.healthBar.width = 180
            st.Nameplates.healthBar.height = 18
            st.Nameplates.healthBar.nameFontSize = 9
            st.Nameplates.healthBar.healthPctFontSize = 8
            st.Nameplates.threatBar.width = 180
            st.Nameplates.threatBar.height = 4
            st.Nameplates.castBar.width = 180
            st.Nameplates.castBar.height = 14
            st.Nameplates.castBar.fontSize = 11
            st.Nameplates.target.healthBar.width = 220
            st.Nameplates.target.healthBar.height = 22
            st.Nameplates.target.threatBar.width = 220
            st.Nameplates.target.threatBar.height = 5
            st.Nameplates.target.castBar.width = 220
            st.Nameplates.target.castBar.height = 16
        elseif selection == "Large" then
            st.PlayerFrame.width = 410
            st.PlayerFrame.height = 74
            st.PlayerFrame.scale = 108
            st.TargetFrame.width = 410
            st.TargetFrame.height = 74
            st.TargetFrame.scale = 108
            st.FocusFrame.width = 350
            st.FocusFrame.height = 64
            st.FocusFrame.scale = 108
            st.PartyFrames.width = 268
            st.PartyFrames.height = 66
            st.PartyFrames.diameter = 72
            st.RaidFrames.width = 108
            st.RaidFrames.height = 30
            st.MainTankFrames.width = 290
            st.MainTankFrames.height = 66
            st.MainTankFrames.scale = 1.08
            st.CastBars.player.width = 400
            st.CastBars.player.height = 24
            st.CastBars.player.scale = 110
            st.CastBars.target.width = 400
            st.CastBars.target.height = 24
            st.CastBars.target.scale = 110
            st.CastBars.focus.width = 350
            st.CastBars.focus.height = 24
            st.CastBars.focus.scale = 110
            st.Nameplates.healthBar.width = 220
            st.Nameplates.healthBar.height = 24
            st.Nameplates.healthBar.nameFontSize = 12
            st.Nameplates.healthBar.healthPctFontSize = 11
            st.Nameplates.threatBar.width = 220
            st.Nameplates.threatBar.height = 6
            st.Nameplates.castBar.width = 220
            st.Nameplates.castBar.height = 18
            st.Nameplates.castBar.fontSize = 14
            st.Nameplates.target.healthBar.width = 270
            st.Nameplates.target.healthBar.height = 28
            st.Nameplates.target.threatBar.width = 270
            st.Nameplates.target.threatBar.height = 7
            st.Nameplates.target.castBar.width = 270
            st.Nameplates.target.castBar.height = 20
        else
            st.PlayerFrame.width = 380
            st.PlayerFrame.height = 66
            st.PlayerFrame.scale = 100
            st.TargetFrame.width = 380
            st.TargetFrame.height = 66
            st.TargetFrame.scale = 100
            st.FocusFrame.width = 320
            st.FocusFrame.height = 58
            st.FocusFrame.scale = 100
            st.PartyFrames.width = 240
            st.PartyFrames.height = 58
            st.PartyFrames.diameter = 64
            st.RaidFrames.width = 92
            st.RaidFrames.height = 24
            st.MainTankFrames.width = 260
            st.MainTankFrames.height = 58
            st.MainTankFrames.scale = 1.0
            st.CastBars.player.width = 360
            st.CastBars.player.height = 20
            st.CastBars.player.scale = 100
            st.CastBars.target.width = 360
            st.CastBars.target.height = 20
            st.CastBars.target.scale = 100
            st.CastBars.focus.width = 320
            st.CastBars.focus.height = 20
            st.CastBars.focus.scale = 100
            st.Nameplates.healthBar.width = 200
            st.Nameplates.healthBar.height = 20
            st.Nameplates.healthBar.nameFontSize = 10
            st.Nameplates.healthBar.healthPctFontSize = 9
            st.Nameplates.threatBar.width = 200
            st.Nameplates.threatBar.height = 5
            st.Nameplates.castBar.width = 200
            st.Nameplates.castBar.height = 16
            st.Nameplates.castBar.fontSize = 12
            st.Nameplates.target.healthBar.width = 240
            st.Nameplates.target.healthBar.height = 24
            st.Nameplates.target.threatBar.width = 240
            st.Nameplates.target.threatBar.height = 6
            st.Nameplates.target.castBar.width = 240
            st.Nameplates.target.castBar.height = 18
        end
    end

    local function SetActionBarsRange(st, startIdx, endIdx, enabled)
        for i = startIdx, endIdx do
            local key = "bar" .. i
            st.ActionBars[key] = st.ActionBars[key] or {}
            st.ActionBars[key].enabled = (enabled == true)
        end
    end

    local function ApplyRoleContentSynergy(st, resolvedRole, contentSelection)
        if resolvedRole == "Tank" then
            st.Nameplates.threatBar.enabled = true
            st.TargetFrame.debuffs.filterMode = "ALL"
            st.TargetFrame.debuffs.maxShown = math.max(22, st.TargetFrame.debuffs.maxShown or 16)
            st.CastBars.target.scale = math.max(108, st.CastBars.target.scale or 100)
            SetActionBarsRange(st, 1, 4, true)
        elseif resolvedRole == "Healer" then
            st.RaidFrames.groupBy = true
            st.RaidFrames.colorByGroup = true
            st.RaidFrames.groupBrackets = true
            st.PartyFrames.layout = "Vertical"
            st.Nameplates.healthBar.nameAlign = "LEFT"
            st.Nameplates.healthBar.healthPctDisplay = "RIGHT"
            st.TargetFrame.debuffs.filterMode = "AUTO"
            st.TargetFrame.debuffs.maxShown = math.min(st.TargetFrame.debuffs.maxShown or 16, 20)
        else
            st.TargetFrame.debuffs.filterMode = st.TargetFrame.debuffs.filterMode or "PLAYER"
            st.TargetFrame.debuffs.maxShown = st.TargetFrame.debuffs.maxShown or 18
        end

        if contentSelection == "Raid Groups" then
            st.RaidFrames.groupBy = true
            st.RaidFrames.groupBrackets = true
            st.RaidFrames.columns = math.max(st.RaidFrames.columns or 5, resolvedRole == "Healer" and 8 or 7)
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
        elseif contentSelection == "Mythic+ Dungeons" then
            st.PartyFrames.layout = "Vertical"
            st.RaidFrames.groupBy = false
            st.RaidFrames.groupBrackets = false
            st.CastBars.target.scale = math.max(108, st.CastBars.target.scale or 100)
            st.Nameplates.threatBar.enabled = true
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
        elseif contentSelection == "Arena / Battleground" then
            st.PartyFrames.layout = "Horizontal"
            st.TargetFrame.debuffs.filterMode = "ALL"
            st.TargetFrame.debuffs.maxShown = math.max(24, st.TargetFrame.debuffs.maxShown or 16)
            st.ConsumableBars.showInInstancesOnly = true
            st.ConsumableBars.hideInactive = true
        else
            st.ConsumableBars.showInInstancesOnly = false
        end
    end

    local function ApplySmartSelections(tag)
        local st = EnsureSettings()
        local resolvedRole = ApplyRoleProfile(st, state.roleProfile)
        ApplyContentProfile(st, state.contentProfile)
        ApplyRoleContentSynergy(st, resolvedRole, state.contentProfile)
        ApplyReadabilityPreset(st, state.readabilityPreset)
        MarkAppliedNow(ApplyAllSettings(tag or "WELCOME_SMART"))
        return resolvedRole
    end

    local function SyncSimplePlaystyleFromContent()
        state.simplePlaystyle = CONTENT_TO_SIMPLE_PLAYSTYLE[state.contentProfile] or state.simplePlaystyle or "Mythic+"
    end

    local function ApplySimplePlaystyleSelection(playstyle)
        local presetByPlaystyle = {
            ["Mythic+"] = "Mythic+",
            Raider = "Raid Focused",
            ["PvP"] = "Class Themed",
            Casual = "MidnightUI",
        }
        state.simplePlaystyle = playstyle
        state.contentProfile = SIMPLE_PLAYSTYLE_TO_CONTENT[playstyle] or "Mythic+ Dungeons"
        state.preset = presetByPlaystyle[playstyle] or "MidnightUI"
        ApplyPreset(state.preset, true)
        local resolved = ApplySmartSelections("WELCOME_SIMPLE_PLAYSTYLE")
        if controls.contentProfile then controls.contentProfile:SetValue(state.contentProfile) end
        UpdatePresetStatus()
        if modeUI.applyTuneLayout and state.tuneMode ~= "Expert" then
            modeUI.applyTuneLayout()
        end
        return resolved
    end

    controls.simplePlaystyle = CreateDropdownCard(profileHost, "Quick Playstyle", SIMPLE_PLAYSTYLE_OPTIONS, state.simplePlaystyle, function(v)
        local resolvedRole = ApplySimplePlaystyleSelection(v)
        SetFooterStatus("Playstyle set to " .. v .. " (" .. resolvedRole .. ").", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end)

    controls.roleProfile = CreateDropdownCard(profileHost, "Combat Role", ROLE_OPTIONS, state.roleProfile, function(v)
        state.roleProfile = v
        local resolved = ApplySmartSelections("WELCOME_ROLE_PROFILE")
        UpdatePresetStatus()
        if v == "Auto Detect" then
            SetFooterStatus("Role set to Auto (" .. resolved .. ").", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
        else
            SetFooterStatus("Role set to " .. resolved .. ".", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
        end
    end)

    controls.contentProfile = CreateDropdownCard(profileHost, "Main Activity", CONTENT_OPTIONS, state.contentProfile, function(v)
        state.contentProfile = v
        SyncSimplePlaystyleFromContent()
        if controls.simplePlaystyle then controls.simplePlaystyle:SetValue(state.simplePlaystyle) end
        ApplySmartSelections("WELCOME_CONTENT_PROFILE")
        UpdatePresetStatus()
        if modeUI.applyTuneLayout and state.tuneMode ~= "Expert" then
            modeUI.applyTuneLayout()
        end
        SetFooterStatus("Main activity set to " .. v .. ".", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end)

    controls.readabilityPreset = CreateDropdownCard(profileHost, "UI Scale", READABILITY_OPTIONS, state.readabilityPreset, function(v)
        state.readabilityPreset = v
        ApplySmartSelections("WELCOME_READABILITY")
        UpdatePresetStatus()
        SetFooterStatus("UI scale set to " .. v .. ".", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end)

    controls.frameWidth = CreateSliderCard(framesHost, "Player/Target Frame Width", 300, 520, 2, s.PlayerFrame.width or 380, function(v)
        local st = EnsureSettings()
        local width = math.floor(v + 0.5)
        st.PlayerFrame.width = width
        st.TargetFrame.width = width
        st.FocusFrame.width = math.floor(width * 0.84)
        MarkAppliedNow(ApplyAllSettings("WELCOME_FRAME_WIDTH"))
    end)

    controls.theme = CreateDropdownCard(profileHost, "Color Theme", {"Default", "Class Color", "Faithful", "Glass", "Hidden"}, s.GlobalStyle or "Default", function(v)
        local st = EnsureSettings()
        local actionBarStyleByTheme = {
            ["Default"] = "Disabled",
            ["Class Color"] = "Class Color",
            ["Faithful"] = "Faithful",
            ["Glass"] = "Glass",
            ["Hidden"] = "Hidden",
        }
        st.GlobalStyle = v
        st.Messenger.style = v
        st.Minimap.infoBarStyle = v
        st.ActionBars.globalStyle = actionBarStyleByTheme[v] or "Disabled"
        MarkAppliedNow(ApplyAllSettings("WELCOME_THEME"))
        if controls.actionStyle then
            controls.actionStyle:SetValue(st.ActionBars.globalStyle or "Disabled")
        end
    end)

    local unitBarStyle = s.General.unitFrameBarStyle or "Gradient"
    if unitBarStyle ~= "Gradient" and unitBarStyle ~= "Flat" then
        unitBarStyle = "Gradient"
    end
    controls.unitBars = CreateDropdownCard(profileHost, "Health Bar Style", {"Gradient", "Flat"}, unitBarStyle, function(v)
        local st = EnsureSettings()
        st.General.unitFrameBarStyle = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_UNIT_BARS"))
    end)

    controls.frameHeight = CreateSliderCard(framesHost, "Player/Target Frame Height", 50, 120, 2, s.PlayerFrame.height or 66, function(v)
        local st = EnsureSettings()
        local height = math.floor(v + 0.5)
        st.PlayerFrame.height = height
        st.TargetFrame.height = height
        st.FocusFrame.height = math.floor(height * 0.88)
        MarkAppliedNow(ApplyAllSettings("WELCOME_FRAME_HEIGHT"))
    end)

    controls.focusScale = CreateSliderCard(framesHost, "Focus Frame Size (%)", 70, 140, 1, s.FocusFrame.scale or 100, function(v)
        local st = EnsureSettings()
        st.FocusFrame.scale = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_FOCUS_SCALE"))
    end)

    controls.partyStyle = CreateDropdownCard(framesHost, "Party Frame Style", PARTY_STYLE_OPTIONS, s.PartyFrames.style or "Rendered", function(v)
        local st = EnsureSettings()
        SetPartyStyle(v, st)
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_STYLE"))
    end)

    controls.partySize = CreateSliderCard(framesHost, "Party Frame Size", 40, 90, 1, s.PartyFrames.height or 58, function(v)
        local st = EnsureSettings()
        local size = math.floor(v + 0.5)
        st.PartyFrames.height = size
        st.PartyFrames.width = math.floor(size * 4.0)
        st.PartyFrames.diameter = size
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_SIZE"))
    end)

    controls.partyHideInRaid = CreateToggleCard(framesHost, "Party Frames During Raid", "Hide during raid", s.PartyFrames.hideInRaid == true, function(v)
        local st = EnsureSettings()
        st.PartyFrames.hideInRaid = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_HIDE_IN_RAID"))
        if _G.MidnightUI_UpdatePartyVisibility then _G.MidnightUI_UpdatePartyVisibility() end
    end)

    controls.partyLayout = CreateDropdownCard(framesHost, "Party Layout", {"Vertical", "Horizontal"}, s.PartyFrames.layout or "Vertical", function(v)
        local st = EnsureSettings()
        st.PartyFrames.layout = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_LAYOUT"))
        if controls.partySpacing and controls.partySpacing._label then
            controls.partySpacing._label:SetText(v == "Horizontal" and "Party Spacing (Horizontal)" or "Party Spacing (Vertical)")
        end
        if controls.partySpacing then
            local spacing = (v == "Horizontal") and (st.PartyFrames.spacingX or 8) or (st.PartyFrames.spacingY or 8)
            controls.partySpacing:SetValue(spacing)
        end
    end)

    controls.partySpacing = CreateSliderCard(framesHost, "Party Spacing (Vertical)", 0, 30, 1, (s.PartyFrames.layout == "Horizontal") and (s.PartyFrames.spacingX or 8) or (s.PartyFrames.spacingY or 8), function(v)
        local st = EnsureSettings()
        local spacing = math.floor(v + 0.5)
        if (st.PartyFrames.layout or "Vertical") == "Horizontal" then
            st.PartyFrames.spacingX = spacing
        else
            st.PartyFrames.spacingY = spacing
        end
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_SPACING"))
    end)

    controls.partyTooltip = CreateToggleCard(framesHost, "Party Role Tooltip", "Show on hover", s.PartyFrames.showTooltip ~= false, function(v)
        local st = EnsureSettings()
        st.PartyFrames.showTooltip = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_PARTY_TOOLTIP"))
    end)

    controls.raidWidth = CreateSliderCard(framesHost, "Raid Frame Width", 60, 220, 1, s.RaidFrames.width or 92, function(v)
        local st = EnsureSettings()
        st.RaidFrames.width = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_WIDTH"))
    end)

    controls.raidHeight = CreateSliderCard(framesHost, "Raid Frame Height", 16, 80, 1, s.RaidFrames.height or 24, function(v)
        local st = EnsureSettings()
        st.RaidFrames.height = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_HEIGHT"))
    end)

    controls.raidColumns = CreateSliderCard(framesHost, "Raid Frames Per Row", 1, 12, 1, s.RaidFrames.columns or 5, function(v)
        local st = EnsureSettings()
        st.RaidFrames.columns = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_COLUMNS"))
    end)

    controls.raidGroupBy = CreateToggleCard(framesHost, "Raid 5-Player Groups", "Keep 5-player groups", s.RaidFrames.groupBy == true, function(v)
        local st = EnsureSettings()
        st.RaidFrames.groupBy = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_GROUPBY"))
    end)

    controls.raidGroupColor = CreateToggleCard(framesHost, "Raid Group Edge Colors", "Color border by group", s.RaidFrames.colorByGroup ~= false, function(v)
        local st = EnsureSettings()
        st.RaidFrames.colorByGroup = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_GROUPCOLOR"))
    end)

    controls.raidGroupBrackets = CreateToggleCard(framesHost, "Raid Group Brackets", "Show group markers", s.RaidFrames.groupBrackets ~= false, function(v)
        local st = EnsureSettings()
        st.RaidFrames.groupBrackets = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_BRACKETS"))
    end)

    controls.raidStyle = CreateDropdownCard(framesHost, "Raid Frame Style", {"Rendered", "Simple"}, (s.RaidFrames.layoutStyle == "Simple") and "Simple" or "Rendered", function(v)
        local st = EnsureSettings()
        st.RaidFrames.layoutStyle = (v == "Simple") and "Simple" or "Detailed"
        local partyStyle = (v == "Simple") and "Simple" or "Rendered"
        SetPartyStyle(partyStyle, st)
        st.MainTankFrames.layoutStyle = (v == "Simple") and "Simple" or "Detailed"
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_STYLE"))
        if controls.partyStyle then controls.partyStyle:SetValue(st.PartyFrames.style or partyStyle) end
    end)

    controls.raidShowHealthPct = CreateToggleCard(framesHost, "Raid Health Percent", "Show health %", s.RaidFrames.showHealthPct ~= false, function(v)
        local st = EnsureSettings()
        st.RaidFrames.showHealthPct = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_HEALTH_PCT"))
    end)

    controls.raidTextSize = CreateSliderCard(framesHost, "Raid Text Size", 6, 14, 1, s.RaidFrames.textSize or 9, function(v)
        local st = EnsureSettings()
        st.RaidFrames.textSize = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_TEXT_SIZE"))
    end)

    controls.raidSpacingX = CreateSliderCard(framesHost, "Raid Horizontal Spacing", 0, 20, 1, s.RaidFrames.spacingX or 6, function(v)
        local st = EnsureSettings()
        st.RaidFrames.spacingX = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_SPACING_X"))
    end)

    controls.raidSpacingY = CreateSliderCard(framesHost, "Raid Vertical Spacing", 0, 20, 1, s.RaidFrames.spacingY or 4, function(v)
        local st = EnsureSettings()
        st.RaidFrames.spacingY = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_RAID_SPACING_Y"))
    end)

    controls.nameplateFont = CreateSliderCard(combatHost, "Nameplate Font Size", 8, 20, 1, s.Nameplates.healthBar.nameFontSize or 10, function(v)
        local st = EnsureSettings()
        local fontSize = math.floor(v + 0.5)
        st.Nameplates.healthBar.nameFontSize = fontSize
        st.Nameplates.healthBar.healthPctFontSize = math.max(8, fontSize - 1)
        st.Nameplates.castBar.fontSize = math.max(10, fontSize + 2)
        MarkAppliedNow(ApplyAllSettings("WELCOME_NAMEPLATE_FONT"))
    end)

    controls.nameplates = CreateToggleCard(combatHost, "MidnightUI Nameplates", "Enable nameplates", s.Nameplates.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.Nameplates.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_NAMEPLATES"))
    end)

    controls.threatBar = CreateToggleCard(combatHost, "Nameplate Threat Bar", "Show threat bar", s.Nameplates.threatBar.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.Nameplates.threatBar.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_THREAT_BAR"))
    end)

    controls.targetDebuffFilter = CreateDropdownCard(combatHost, "Target Debuff View", TARGET_DEBUFF_FILTER_OPTIONS, s.TargetFrame.debuffs.filterMode or "AUTO", function(v)
        local st = EnsureSettings()
        st.TargetFrame.debuffs.filterMode = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_TARGET_DEBUFF_FILTER"))
    end)

    controls.targetDebuffMax = CreateSliderCard(combatHost, "Target Debuff Limit", 4, 40, 1, s.TargetFrame.debuffs.maxShown or 16, function(v)
        local st = EnsureSettings()
        st.TargetFrame.debuffs.maxShown = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_TARGET_DEBUFF_MAX"))
    end)

    controls.castScale = CreateSliderCard(combatHost, "Cast Bar Scale (%)", 80, 140, 1, s.CastBars.player.scale or 100, function(v)
        local st = EnsureSettings()
        local sv = math.floor(v + 0.5)
        st.CastBars.player.scale = sv
        st.CastBars.target.scale = sv
        st.CastBars.focus.scale = sv
        MarkAppliedNow(ApplyAllSettings("WELCOME_CAST_SCALE"))
    end)
    controls.castWidth = CreateSliderCard(combatHost, "Cast Bar Width", 200, 700, 5, s.CastBars.player.width or 360, function(v)
        local st = EnsureSettings()
        local w = math.floor(v + 0.5)
        st.CastBars.player.width = w
        st.CastBars.target.width = w
        st.CastBars.focus.width = math.min(w, st.CastBars.focus.width or w)
        MarkAppliedNow(ApplyAllSettings("WELCOME_CAST_WIDTH"))
    end)
    controls.castHeight = CreateSliderCard(combatHost, "Cast Bar Height", 8, 60, 1, s.CastBars.player.height or 24, function(v)
        local st = EnsureSettings()
        local h = math.floor(v + 0.5)
        st.CastBars.player.height = h
        st.CastBars.target.height = h
        st.CastBars.focus.height = h
        MarkAppliedNow(ApplyAllSettings("WELCOME_CAST_HEIGHT"))
    end)
    controls.castYOffset = CreateSliderCard(combatHost, "Cast Bar Y Offset", -60, 60, 1, s.CastBars.player.attachYOffset or -6, function(v)
        local st = EnsureSettings()
        local y = math.floor(v + 0.5)
        st.CastBars.player.attachYOffset = y
        st.CastBars.target.attachYOffset = y
        st.CastBars.focus.attachYOffset = y
        st.CastBars.player.position = nil
        st.CastBars.target.position = nil
        st.CastBars.focus.position = nil
        MarkAppliedNow(ApplyAllSettings("WELCOME_CAST_Y_OFFSET"))
    end)
    controls.castMatchWidth = CreateToggleCard(combatHost, "Cast Bars Match Unit Width", "Match unit frame width", (s.CastBars.player.matchFrameWidth == true) and (s.CastBars.target.matchFrameWidth == true) and (s.CastBars.focus.matchFrameWidth == true), function(v)
        local st = EnsureSettings()
        st.CastBars.player.matchFrameWidth = v and true or false
        st.CastBars.target.matchFrameWidth = v and true or false
        st.CastBars.focus.matchFrameWidth = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CAST_MATCH_WIDTH"))
    end)

    controls.questCombat = CreateToggleCard(combatHost, "Quest Tracker in Combat", "Hide in combat", s.General.hideQuestObjectivesInCombat == true, function(v)
        local st = EnsureSettings()
        st.General.hideQuestObjectivesInCombat = v
        if v then st.General.hideQuestObjectivesAlways = false end
        MarkAppliedNow(ApplyAllSettings("WELCOME_QUEST_COMBAT"))
    end)

    controls.questAlways = CreateToggleCard(combatHost, "Always Hide Quest Tracker", "Always hide tracker", s.General.hideQuestObjectivesAlways == true, function(v)
        local st = EnsureSettings()
        st.General.hideQuestObjectivesAlways = v and true or false
        if v then st.General.hideQuestObjectivesInCombat = false end
        MarkAppliedNow(ApplyAllSettings("WELCOME_QUEST_ALWAYS"))
    end)

    controls.tooltips = CreateToggleCard(combatHost, "MidnightUI Tooltips", "Enable custom tooltips", s.General.customTooltips ~= false, function(v)
        local st = EnsureSettings()
        st.General.customTooltips = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_TOOLTIPS"))
    end)

    controls.forceCursorTooltips = CreateToggleCard(combatHost, "Cursor Tooltips", "Anchor tooltips near your cursor.", s.General.forceCursorTooltips == true, function(v)
        local st = EnsureSettings()
        st.General.forceCursorTooltips = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CURSOR_TOOLTIPS"))
    end)

    controls.blizzardQuesting = CreateToggleCard(combatHost, "Blizzard Quest Tracker", "Use Blizzard quest tracking visuals.", s.General.useBlizzardQuestingInterface == true, function(v)
        local st = EnsureSettings()
        st.General.useBlizzardQuestingInterface = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_BLIZZARD_QUESTING"))
    end)

    if not s.Combat then s.Combat = {} end
    controls.debuffBorder = CreateToggleCard(combatHost, "Debuff Alert Border", "Glow border when debuffed", s.Combat.debuffBorderEnabled ~= false, function(v)
        if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
        MidnightUISettings.Combat.debuffBorderEnabled = v
        local frame = _G.MidnightUI_PlayerFrame
        local CB = _G.MidnightUI_ConditionBorder
        if frame and CB then
            if v then
                CB.Update(frame)
            else
                local cb = frame.conditionBorder
                if cb then
                    if cb.pulseGroup and cb.pulseGroup:IsPlaying() then cb.pulseGroup:Stop() end
                    if cb.glowFrame then cb.glowFrame:Hide() end
                    cb:Hide()
                end
            end
        end
    end)

    controls.dispelTrackingEnabled = CreateToggleCard(combatHost, "Dispel Tracking Overlay", "Show dispel-ready indicators on your player frame.", s.Combat.dispelTrackingEnabled ~= false, function(v)
        local st = EnsureSettings()
        st.Combat = st.Combat or {}
        st.Combat.dispelTrackingEnabled = v and true or false
        local ok = ApplyAllSettings("WELCOME_DISPEL_TRACKING_ENABLED")
        if ok and _G.MidnightUI_RefreshDispelTrackingOverlay then
            SafeCall("RefreshDispelTrackingOverlay", _G.MidnightUI_RefreshDispelTrackingOverlay, _G.MidnightUI_PlayerFrame)
        end
        MarkAppliedNow(ok)
    end)

    controls.dispelTrackingMax = CreateSliderCard(combatHost, "Dispel Tracking Max", 1, 20, 1, s.Combat.dispelTrackingMaxShown or 8, function(v)
        local st = EnsureSettings()
        st.Combat = st.Combat or {}
        st.Combat.dispelTrackingMaxShown = math.floor(v + 0.5)
        local ok = ApplyAllSettings("WELCOME_DISPEL_TRACKING_MAX")
        if ok and _G.MidnightUI_RefreshDispelTrackingOverlay then
            SafeCall("RefreshDispelTrackingOverlay", _G.MidnightUI_RefreshDispelTrackingOverlay, _G.MidnightUI_PlayerFrame)
        end
        MarkAppliedNow(ok)
    end)

    controls.partyDispelIcons = CreateToggleCard(combatHost, "Party Dispel Icons", "Show party dispel-ready icons on party frames.", s.Combat.partyDispelTrackingEnabled ~= false, function(v)
        local st = EnsureSettings()
        st.Combat = st.Combat or {}
        st.Combat.partyDispelTrackingEnabled = v and true or false
        local ok = ApplyAllSettings("WELCOME_PARTY_DISPEL_ICONS")
        if ok and _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
            SafeCall("RefreshPartyDispelTrackingOverlay", _G.MidnightUI_RefreshPartyDispelTrackingOverlay, false)
        end
        MarkAppliedNow(ok)
    end)

    controls.actionStyle = CreateDropdownCard(combatHost, "Action Bar Theme", {"Disabled", "Class Color", "Faithful", "Glass", "Hidden"}, s.ActionBars.globalStyle or "Disabled", function(v)
        local st = EnsureSettings()
        st.ActionBars.globalStyle = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTION_STYLE"))
    end)

    controls.playerFrameEnabled = CreateToggleCard(modulesHost, "Player Frame", "Show your player frame.", s.PlayerFrame.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.PlayerFrame.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_PLAYER_ENABLED"))
    end)

    controls.targetFrameEnabled = CreateToggleCard(modulesHost, "Target Frame", "Show your current target frame.", s.TargetFrame.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.TargetFrame.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_TARGET_ENABLED"))
    end)

    controls.focusFrameEnabled = CreateToggleCard(modulesHost, "Focus Frame", "Show your focus target frame.", s.FocusFrame.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.FocusFrame.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_FOCUS_ENABLED"))
    end)

    controls.targetOfTargetEnabled = CreateToggleCard(modulesHost, "Target of Target", "Show target-of-target frame while in combat.", s.TargetFrame.showTargetOfTarget == true, function(v)
        local st = EnsureSettings()
        st.TargetFrame.showTargetOfTarget = v and true or false
        local ok = ApplyAllSettings("WELCOME_TARGET_OF_TARGET")
        if ok and _G.MidnightUI_ApplyTargetOfTargetSettings then
            SafeCall("ApplyTargetOfTargetSettings", _G.MidnightUI_ApplyTargetOfTargetSettings)
        end
        MarkAppliedNow(ok)
    end)

    controls.mainTankFramesEnabled = CreateToggleCard(modulesHost, "Main Tank Frames", "Show raid main-tank assist frames.", s.MainTankFrames.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.MainTankFrames.enabled = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_MAIN_TANK_FRAMES"))
    end)

    controls.castBarsEnabled = CreateToggleCard(modulesHost, "Core Cast Bars", "Show player, target, and focus cast bars.", (s.CastBars.player.enabled ~= false) and (s.CastBars.target.enabled ~= false) and (s.CastBars.focus.enabled ~= false), function(v)
        local st = EnsureSettings()
        st.CastBars.player.enabled = v
        st.CastBars.target.enabled = v
        st.CastBars.focus.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_CASTBAR_ENABLED"))
    end)

    controls.actionBarSlot = CreateDropdownCard(modulesHost, "Active Action Bar", ACTION_BAR_SLOT_OPTIONS, state.actionBarSlot, function(v)
        state.actionBarSlot = v
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        if controls.actionBarEnabled then controls.actionBarEnabled:SetChecked(bar.enabled ~= false) end
        if controls.actionBarStyle then controls.actionBarStyle:SetValue(bar.style or "Class Color") end
        if controls.actionBarRows then controls.actionBarRows:SetValue(bar.rows or 1) end
        if controls.actionBarIcons then controls.actionBarIcons:SetValue(bar.iconsPerRow or 12) end
        if controls.actionBarScale then controls.actionBarScale:SetValue(bar.scale or 100) end
        if controls.actionBarSpacing then controls.actionBarSpacing:SetValue(bar.spacing or 6) end
        SetFooterStatus("Now editing Action Bar " .. tostring(idx) .. ".", UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    end)

    local _, _, selectedBar = GetSelectedActionBar(s)
    controls.actionBarEnabled = CreateToggleCard(modulesHost, "Selected Action Bar", "Turn selected bar on/off", selectedBar.enabled ~= false, function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        bar.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_ENABLED"))
        SetFooterStatus("Action Bar " .. tostring(idx) .. (v and " enabled." or " disabled."), UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end)

    controls.actionBarStyle = CreateDropdownCard(modulesHost, "Selected Bar Theme", {"Class Color", "Faithful", "Glass", "Hidden"}, selectedBar.style or "Class Color", function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        bar.style = v
        if st.ActionBars.globalStyle and st.ActionBars.globalStyle ~= "Disabled" then
            st.ActionBars.globalStyle = "Disabled"
            if controls.actionStyle and controls.actionStyle.SetValue then
                controls.actionStyle:SetValue("Disabled")
            end
        end
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_STYLE"))
        SetFooterStatus("Action Bar " .. tostring(idx) .. " theme set to " .. tostring(v) .. ".", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end)

    controls.actionBarRows = CreateSliderCard(modulesHost, "Selected Bar Rows", 1, 12, 1, selectedBar.rows or 1, function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        local rows = math.max(1, math.floor(v + 0.5))
        local icons = math.max(1, bar.iconsPerRow or 12)
        if rows * icons > 12 then
            rows = math.max(1, math.floor(12 / icons))
            if controls.actionBarRows then controls.actionBarRows:SetValue(rows) end
        end
        bar.rows = rows
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_ROWS"))
    end)

    controls.actionBarIcons = CreateSliderCard(modulesHost, "Selected Bar Buttons/Row", 1, 12, 1, selectedBar.iconsPerRow or 12, function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        local icons = math.max(1, math.floor(v + 0.5))
        local rows = math.max(1, bar.rows or 1)
        if rows * icons > 12 then
            icons = math.max(1, math.floor(12 / rows))
            if controls.actionBarIcons then controls.actionBarIcons:SetValue(icons) end
        end
        bar.iconsPerRow = icons
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_ICONS"))
    end)

    controls.actionBarScale = CreateSliderCard(modulesHost, "Selected Bar Scale (%)", 50, 200, 5, selectedBar.scale or 100, function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        bar.scale = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_SCALE"))
    end)

    controls.actionBarSpacing = CreateSliderCard(modulesHost, "Selected Bar Button Spacing", 0, 30, 1, selectedBar.spacing or 6, function(v)
        local st = EnsureSettings()
        local idx, _, bar = GetSelectedActionBar(st)
        bar.spacing = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_ACTIONBAR" .. tostring(idx) .. "_SPACING"))
    end)

    controls.consumables = CreateToggleCard(modulesHost, "Consumables Bar", "Show cooldown bars for potions and utility items.", s.ConsumableBars.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.enabled = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES"))
    end)

    controls.inventoryEnabled = CreateToggleCard(modulesHost, "Inventory Bar", "Show MidnightUI bag dock controls.", (not s.Inventory) or s.Inventory.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.Inventory = st.Inventory or {}
        st.Inventory.enabled = v and true or false
        local ok = ApplyAllSettings("WELCOME_INVENTORY_ENABLED")
        if ok and _G.MidnightUI_ApplyInventorySettings then
            SafeCall("ApplyInventorySettings", _G.MidnightUI_ApplyInventorySettings)
        end
        MarkAppliedNow(ok)
    end)

    controls.consumablesHideInactive = CreateToggleCard(modulesHost, "Consumables Visibility", "Hide inactive bars", s.ConsumableBars.hideInactive == true, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.hideInactive = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_HIDE_INACTIVE"))
    end)

    controls.consumablesInstancesOnly = CreateToggleCard(modulesHost, "Consumables In Instances", "Show only in dungeons and raids", s.ConsumableBars.showInInstancesOnly == true, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.showInInstancesOnly = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_INSTANCE_ONLY"))
    end)

    controls.consumablesWidth = CreateSliderCard(modulesHost, "Consumables Width", 120, 420, 5, s.ConsumableBars.width or 220, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.width = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_WIDTH"))
    end)

    controls.consumablesHeight = CreateSliderCard(modulesHost, "Consumables Height", 6, 24, 1, s.ConsumableBars.height or 10, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.height = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_HEIGHT"))
    end)

    controls.consumablesSpacing = CreateSliderCard(modulesHost, "Consumables Spacing", 0, 12, 1, s.ConsumableBars.spacing or 4, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.spacing = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_SPACING"))
    end)

    controls.consumablesScale = CreateSliderCard(modulesHost, "Consumables Scale (%)", 50, 200, 5, s.ConsumableBars.scale or 100, function(v)
        local st = EnsureSettings()
        st.ConsumableBars.scale = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_CONSUMABLES_SCALE"))
    end)

    controls.petBarEnabled = CreateToggleCard(modulesHost, "Pet Bar", "Show pet action buttons when needed.", s.PetBar.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.PetBar.enabled = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_ENABLED"))
    end)

    controls.petBarScale = CreateSliderCard(modulesHost, "Pet Bar Scale (%)", 50, 200, 5, s.PetBar.scale or 100, function(v)
        local st = EnsureSettings()
        st.PetBar.scale = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_SCALE"))
    end)

    controls.petBarAlpha = CreateSliderCard(modulesHost, "Pet Bar Opacity", 0.1, 1.0, 0.05, s.PetBar.alpha or 1.0, function(v)
        local st = EnsureSettings()
        st.PetBar.alpha = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_ALPHA"))
    end)

    controls.petBarSize = CreateSliderCard(modulesHost, "Pet Button Size", 20, 56, 1, s.PetBar.buttonSize or 32, function(v)
        local st = EnsureSettings()
        st.PetBar.buttonSize = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_SIZE"))
    end)

    controls.petBarSpacing = CreateSliderCard(modulesHost, "Pet Bar Spacing", 0, 30, 1, s.PetBar.spacing or 15, function(v)
        local st = EnsureSettings()
        st.PetBar.spacing = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_SPACING"))
    end)

    controls.petBarPerRow = CreateSliderCard(modulesHost, "Pet Buttons Per Row", 1, 10, 1, s.PetBar.buttonsPerRow or 10, function(v)
        local st = EnsureSettings()
        st.PetBar.buttonsPerRow = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_PET_BAR_PER_ROW"))
    end)

    controls.stanceBarEnabled = CreateToggleCard(modulesHost, "Stance Bar", "Show stance/form buttons when available.", s.StanceBar.enabled ~= false, function(v)
        local st = EnsureSettings()
        st.StanceBar.enabled = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_ENABLED"))
    end)

    controls.stanceBarScale = CreateSliderCard(modulesHost, "Stance Bar Scale (%)", 50, 200, 5, s.StanceBar.scale or 100, function(v)
        local st = EnsureSettings()
        st.StanceBar.scale = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_SCALE"))
    end)

    controls.stanceBarAlpha = CreateSliderCard(modulesHost, "Stance Bar Opacity", 0.1, 1.0, 0.05, s.StanceBar.alpha or 1.0, function(v)
        local st = EnsureSettings()
        st.StanceBar.alpha = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_ALPHA"))
    end)

    controls.stanceBarSize = CreateSliderCard(modulesHost, "Stance Button Size", 20, 56, 1, s.StanceBar.buttonSize or 32, function(v)
        local st = EnsureSettings()
        st.StanceBar.buttonSize = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_SIZE"))
    end)

    controls.stanceBarSpacing = CreateSliderCard(modulesHost, "Stance Bar Spacing", -6, 30, 1, s.StanceBar.spacing or 4, function(v)
        local st = EnsureSettings()
        st.StanceBar.spacing = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_SPACING"))
    end)

    controls.stanceBarPerRow = CreateSliderCard(modulesHost, "Stance Buttons Per Row", 1, 4, 1, s.StanceBar.buttonsPerRow or 3, function(v)
        local st = EnsureSettings()
        st.StanceBar.buttonsPerRow = math.floor(v + 0.5)
        MarkAppliedNow(ApplyAllSettings("WELCOME_STANCE_BAR_PER_ROW"))
    end)

    controls.overlayHandles = CreateToggleCard(overlayHost, "Move Handles", "Show move handles so you can drag UI elements in-world.", (s.Messenger.locked == false), function(v)
        local st = EnsureSettings()
        st.Messenger.locked = not v
        MarkAppliedNow(ApplyAllSettings("WELCOME_OVERLAY_HANDLES"))
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility(st) end
    end)

    controls.overlayLauncher = CreateOverlayLauncherCard(overlayHost, "Element Settings", OVERLAY_OPTIONS, state.overlayTarget, function(label)
        state.overlayTarget = label
        OpenOverlayByLabel(label, true)
    end)

    controls.chatStyle = CreateDropdownCard(systemsHost, "Chat Theme", {"Default", "Class Color", "Faithful", "Glass", "Minimal"}, s.Messenger.style or "Default", function(v)
        local st = EnsureSettings()
        st.Messenger.style = v
        if st.GlobalStyle == nil or st.GlobalStyle == "" then st.GlobalStyle = v end
        MarkAppliedNow(ApplyAllSettings("WELCOME_CHAT_STYLE"))
    end)

    controls.chatTimestamps = CreateToggleCard(systemsHost, "Chat Timestamps", "Show message timestamps", s.Messenger.showTimestamp ~= false, function(v)
        local st = EnsureSettings()
        st.Messenger.showTimestamp = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CHAT_TIMESTAMPS"))
    end)

    controls.chatGlobalOptOut = CreateToggleCard(systemsHost, "Global Chat Feed", "Hide the Global tab feed", s.Messenger.hideGlobal == true, function(v)
        local st = EnsureSettings()
        st.Messenger.hideGlobal = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CHAT_GLOBAL"))
    end)

    controls.chatLoginStatesOptOut = CreateToggleCard(systemsHost, "Login Messages", "Hide online/offline messages", s.Messenger.hideLoginStates == true, function(v)
        local st = EnsureSettings()
        st.Messenger.hideLoginStates = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_CHAT_LOGIN_STATES"))
    end)

    controls.chatScale = CreateSliderCard(systemsHost, "Chat Scale (%)", 50, 200, 5, (s.Messenger.scale or 1.0) * 100, function(v)
        local st = EnsureSettings()
        st.Messenger.scale = math.floor(v + 0.5) / 100
        MarkAppliedNow(ApplyAllSettings("WELCOME_CHAT_SCALE"))
    end)

    controls.minimapCoords = CreateToggleCard(systemsHost, "Minimap Coordinates", "Show world coordinates", s.Minimap.coordsEnabled ~= false, function(v)
        local st = EnsureSettings()
        st.Minimap.coordsEnabled = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_MINIMAP_COORDS"))
    end)

    controls.minimapStyle = CreateDropdownCard(systemsHost, "Minimap Bar Theme", {"Default", "Class Color", "Faithful", "Glass"}, s.Minimap.infoBarStyle or "Default", function(v)
        local st = EnsureSettings()
        st.Minimap.infoBarStyle = v
        MarkAppliedNow(ApplyAllSettings("WELCOME_MINIMAP_STYLE"))
    end)

    controls.minimapStatusBars = CreateToggleCard(systemsHost, "Custom XP/Rep Bars", "Use MidnightUI XP/Rep bars near minimap", s.Minimap.useCustomStatusBars ~= false, function(v)
        local st = EnsureSettings()
        st.Minimap.useCustomStatusBars = v and true or false
        MarkAppliedNow(ApplyAllSettings("WELCOME_MINIMAP_STATUS_BARS"))
    end)

    local cardSets = {
        profile = {
            simple = {
                controls.simplePlaystyle,
                controls.roleProfile,
                controls.readabilityPreset,
                controls.theme,
            },
            expert = {
                controls.simplePlaystyle,
                controls.roleProfile,
                controls.contentProfile,
                controls.readabilityPreset,
                controls.theme,
                controls.unitBars,
            },
        },
        frames = {
            simple = {
                controls.frameWidth,
                controls.frameHeight,
                controls.partyStyle,
            },
            expert = {
                controls.frameWidth,
                controls.frameHeight,
                controls.focusScale,
                controls.partyStyle,
                controls.partySize,
                controls.partyLayout,
                controls.partySpacing,
                controls.partyHideInRaid,
                controls.partyTooltip,
                controls.raidWidth,
                controls.raidHeight,
                controls.raidStyle,
                controls.raidColumns,
                controls.raidGroupBy,
                controls.raidGroupColor,
                controls.raidGroupBrackets,
                controls.raidShowHealthPct,
                controls.raidTextSize,
                controls.raidSpacingX,
                controls.raidSpacingY,
            },
        },
        combat = {
            simple = {
                controls.nameplates,
                controls.castScale,
                controls.debuffBorder,
                controls.questCombat,
                controls.tooltips,
            },
            expert = {
                controls.nameplates,
                controls.threatBar,
                controls.targetDebuffFilter,
                controls.targetDebuffMax,
                controls.castScale,
                controls.castWidth,
                controls.castHeight,
                controls.castYOffset,
                controls.castMatchWidth,
                controls.nameplateFont,
                controls.debuffBorder,
                controls.dispelTrackingEnabled,
                controls.dispelTrackingMax,
                controls.partyDispelIcons,
                controls.questCombat,
                controls.questAlways,
                controls.blizzardQuesting,
                controls.tooltips,
                controls.forceCursorTooltips,
                controls.actionStyle,
            },
        },
        modules = {
            simple = {
                controls.castBarsEnabled,
                controls.consumables,
            },
            expert = {
                controls.playerFrameEnabled,
                controls.targetFrameEnabled,
                controls.focusFrameEnabled,
                controls.targetOfTargetEnabled,
                controls.mainTankFramesEnabled,
                controls.castBarsEnabled,
                controls.actionBarSlot,
                controls.actionBarEnabled,
                controls.actionBarStyle,
                controls.actionBarRows,
                controls.actionBarIcons,
                controls.actionBarScale,
                controls.actionBarSpacing,
                controls.inventoryEnabled,
                controls.consumables,
                controls.consumablesHideInactive,
                controls.consumablesInstancesOnly,
                controls.consumablesWidth,
                controls.consumablesHeight,
                controls.consumablesSpacing,
                controls.consumablesScale,
                controls.petBarEnabled,
                controls.petBarScale,
                controls.petBarAlpha,
                controls.petBarSize,
                controls.petBarSpacing,
                controls.petBarPerRow,
                controls.stanceBarEnabled,
                controls.stanceBarScale,
                controls.stanceBarAlpha,
                controls.stanceBarSize,
                controls.stanceBarSpacing,
                controls.stanceBarPerRow,
            },
        },
        systems = {
            simple = {
                controls.minimapCoords,
            },
            expert = {
                controls.chatStyle,
                controls.chatTimestamps,
                controls.chatGlobalOptOut,
                controls.chatLoginStatesOptOut,
                controls.chatScale,
                controls.minimapStyle,
                controls.minimapCoords,
                controls.minimapStatusBars,
            },
        },
        overlay = {
            simple = {},
            expert = {
                controls.overlayHandles,
                controls.overlayLauncher,
            },
        },
    }

    local function ApplyCardsToSection(host, allCards, visibleCards)
        local visibleSet = {}
        for _, card in ipairs(visibleCards or {}) do
            if card then visibleSet[card] = true end
        end
        local visibleList = {}
        for _, card in ipairs(allCards or {}) do
            if card then
                if visibleSet[card] then
                    card:Show()
                    visibleList[#visibleList + 1] = card
                else
                    card:Hide()
                end
            end
        end
        LayoutCards(visibleList, host, CARD_LAYOUT.leftX, CARD_LAYOUT.startY, CARD_LAYOUT.gapX, CARD_LAYOUT.gapY, CARD_LAYOUT.minWidth)
    end

    local function BuildSimpleVisible()
        local frames = {
            controls.frameWidth,
            controls.frameHeight,
            controls.partyStyle,
        }
        if state.simplePlaystyle == "Raider" then
            frames[#frames + 1] = controls.raidStyle
            frames[#frames + 1] = controls.raidWidth
            frames[#frames + 1] = controls.raidColumns
        elseif state.simplePlaystyle == "PvP" then
            frames[#frames + 1] = controls.partyLayout
            frames[#frames + 1] = controls.partySpacing
        else
            frames[#frames + 1] = controls.partyLayout
        end

        local combat = {
            controls.nameplates,
            controls.castScale,
            controls.debuffBorder,
            controls.questCombat,
            controls.tooltips,
        }
        if state.simplePlaystyle ~= "Casual" then
            combat[#combat + 1] = controls.targetDebuffFilter
            combat[#combat + 1] = controls.actionStyle
        end
        if state.simplePlaystyle == "PvP" then
            combat[#combat + 1] = controls.targetDebuffMax
        end

        local modules = {
            controls.castBarsEnabled,
            controls.consumables,
        }

        local systems = {
            controls.minimapCoords,
        }
        if state.simplePlaystyle == "Casual" then
            systems[#systems + 1] = controls.minimapStatusBars
        end

        return {
            profile = cardSets.profile.simple,
            frames = frames,
            combat = combat,
            modules = modules,
            systems = systems,
            overlay = {},
        }
    end

    modeUI.applyTuneLayout = function()
        local isExpert = (state.tuneMode == "Expert")
        local visibleById = nil
        if isExpert then
            visibleById = {
                profile = cardSets.profile.expert,
                frames = cardSets.frames.expert,
                combat = cardSets.combat.expert,
                modules = cardSets.modules.expert,
                systems = cardSets.systems.expert,
                overlay = cardSets.overlay.expert,
            }
        else
            visibleById = BuildSimpleVisible()
        end
        ApplySectionLayout(visibleById)
        ApplyCardsToSection(profileHost, cardSets.profile.expert, visibleById.profile)
        ApplyCardsToSection(framesHost, cardSets.frames.expert, visibleById.frames)
        ApplyCardsToSection(combatHost, cardSets.combat.expert, visibleById.combat)
        ApplyCardsToSection(modulesHost, cardSets.modules.expert, visibleById.modules)
        ApplyCardsToSection(systemsHost, cardSets.systems.expert, visibleById.systems)
        ApplyCardsToSection(overlayHost, cardSets.overlay.expert, visibleById.overlay)
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                ApplySectionLayout(visibleById)
            end)
        end
    end

    UpdateOverlayPanelVisibility = function(st)
        st = st or EnsureSettings()
        local unlocked = (st.Messenger and st.Messenger.locked == false)
        if overlayPanel then
            if state.tuneMode == "Expert" then
                overlayPanel:Show()
            else
                overlayPanel:Hide()
            end
        end
        if controls.overlayLauncher and controls.overlayLauncher.SetHint then
            if state.tuneMode ~= "Expert" then
                controls.overlayLauncher:SetHint("More frame tools are available in Expert mode.")
            elseif unlocked then
                controls.overlayLauncher:SetHint("Pick a frame to open settings, or right-click it in movement mode.")
            else
                controls.overlayLauncher:SetHint("You can open frame settings now. Turn on Move Handles if you also want drag controls.")
            end
        end
    end
    UpdateOverlayPanelVisibility(s)

    local function SetTuneMode(mode, quiet)
        if mode ~= "Expert" then mode = "Simple" end
        state.tuneMode = mode
        if modeUI.status then
            if mode == "Expert" then
                modeUI.status:SetText("Expert mode active: all settings are shown for full control.")
            else
                modeUI.status:SetText("Simple mode active: pick your playstyle and key options, MidnightUI handles the rest.")
            end
        end
        if modeUI.simpleCard then
            if mode == "Simple" then
                modeUI.simpleCard:SetBackdropColor(0.05, 0.14, 0.23, 0.98)
            else
                modeUI.simpleCard:SetBackdropColor(0.05, 0.11, 0.18, 0.96)
            end
        end
        if modeUI.expertCard then
            if mode == "Expert" then
                modeUI.expertCard:SetBackdropColor(0.16, 0.08, 0.15, 0.98)
            else
                modeUI.expertCard:SetBackdropColor(0.10, 0.07, 0.12, 0.96)
            end
        end
        if modeUI.btnSimple then modeUI.btnSimple:SetEnabled(mode ~= "Simple") end
        if modeUI.btnExpert then modeUI.btnExpert:SetEnabled(mode ~= "Expert") end
        if modeUI.applyTuneLayout then
            modeUI.applyTuneLayout()
        end
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility() end
        UpdatePresetStatus()
        if not quiet then
            SetFooterStatus("Mode changed to " .. mode .. ".", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
        end
    end

    modeUI.btnSimple:SetScript("OnClick", function()
        SetTuneMode("Simple")
    end)
    modeUI.btnExpert:SetScript("OnClick", function()
        SetTuneMode("Expert")
    end)

    local function RefreshTuneControls()
        local st = EnsureSettings()
        local partyStyle = st.PartyFrames.style or "Rendered"
        if partyStyle == "Circular" then partyStyle = "Square" end

        state.simplePlaystyle = CONTENT_TO_SIMPLE_PLAYSTYLE[state.contentProfile] or state.simplePlaystyle or "Mythic+"
        if controls.simplePlaystyle then controls.simplePlaystyle:SetValue(state.simplePlaystyle) end
        if controls.roleProfile then controls.roleProfile:SetValue(state.roleProfile) end
        if controls.contentProfile then controls.contentProfile:SetValue(state.contentProfile) end
        if controls.readabilityPreset then controls.readabilityPreset:SetValue(state.readabilityPreset) end
        if controls.theme then controls.theme:SetValue(st.GlobalStyle or "Default") end
        if controls.unitBars then controls.unitBars:SetValue(st.General.unitFrameBarStyle or "Gradient") end
        if controls.frameWidth then controls.frameWidth:SetValue(st.PlayerFrame.width or 380) end
        if controls.frameHeight then controls.frameHeight:SetValue(st.PlayerFrame.height or 66) end
        if controls.focusScale then controls.focusScale:SetValue(st.FocusFrame.scale or 100) end
        if controls.partyStyle then controls.partyStyle:SetValue(partyStyle) end
        if controls.partySize then controls.partySize:SetValue(st.PartyFrames.height or 58) end
        if controls.partyHideInRaid then controls.partyHideInRaid:SetChecked(st.PartyFrames.hideInRaid == true) end
        if controls.partyLayout then controls.partyLayout:SetValue(st.PartyFrames.layout or "Vertical") end
        if controls.partySpacing then
            local layout = st.PartyFrames.layout or "Vertical"
            if controls.partySpacing._label then
                controls.partySpacing._label:SetText(layout == "Horizontal" and "Party Horizontal Spacing" or "Party Vertical Spacing")
            end
            local spacing = (layout == "Horizontal") and (st.PartyFrames.spacingX or 8) or (st.PartyFrames.spacingY or 8)
            controls.partySpacing:SetValue(spacing)
        end
        if controls.partyTooltip then controls.partyTooltip:SetChecked(st.PartyFrames.showTooltip ~= false) end
        if controls.raidWidth then controls.raidWidth:SetValue(st.RaidFrames.width or 92) end
        if controls.raidHeight then controls.raidHeight:SetValue(st.RaidFrames.height or 24) end
        if controls.raidColumns then controls.raidColumns:SetValue(st.RaidFrames.columns or 5) end
        if controls.raidGroupBy then controls.raidGroupBy:SetChecked(st.RaidFrames.groupBy == true) end
        if controls.raidGroupColor then controls.raidGroupColor:SetChecked(st.RaidFrames.colorByGroup ~= false) end
        if controls.raidGroupBrackets then controls.raidGroupBrackets:SetChecked(st.RaidFrames.groupBrackets ~= false) end
        if controls.raidStyle then controls.raidStyle:SetValue((st.RaidFrames.layoutStyle == "Simple") and "Simple" or "Rendered") end
        if controls.raidShowHealthPct then controls.raidShowHealthPct:SetChecked(st.RaidFrames.showHealthPct ~= false) end
        if controls.raidTextSize then controls.raidTextSize:SetValue(st.RaidFrames.textSize or 9) end
        if controls.raidSpacingX then controls.raidSpacingX:SetValue(st.RaidFrames.spacingX or 6) end
        if controls.raidSpacingY then controls.raidSpacingY:SetValue(st.RaidFrames.spacingY or 4) end
        if controls.nameplates then controls.nameplates:SetChecked(st.Nameplates.enabled ~= false) end
        if controls.threatBar then controls.threatBar:SetChecked(st.Nameplates.threatBar.enabled ~= false) end
        if controls.targetDebuffFilter then controls.targetDebuffFilter:SetValue(st.TargetFrame.debuffs.filterMode or "AUTO") end
        if controls.targetDebuffMax then controls.targetDebuffMax:SetValue(st.TargetFrame.debuffs.maxShown or 16) end
        if controls.castScale then controls.castScale:SetValue(st.CastBars.player.scale or 100) end
        if controls.castWidth then controls.castWidth:SetValue(st.CastBars.player.width or 360) end
        if controls.castHeight then controls.castHeight:SetValue(st.CastBars.player.height or 24) end
        if controls.castYOffset then controls.castYOffset:SetValue(st.CastBars.player.attachYOffset or -6) end
        if controls.castMatchWidth then
            controls.castMatchWidth:SetChecked((st.CastBars.player.matchFrameWidth == true) and (st.CastBars.target.matchFrameWidth == true) and (st.CastBars.focus.matchFrameWidth == true))
        end
        if controls.nameplateFont then controls.nameplateFont:SetValue(st.Nameplates.healthBar.nameFontSize or 10) end
        if controls.questCombat then controls.questCombat:SetChecked(st.General.hideQuestObjectivesInCombat == true) end
        if controls.questAlways then controls.questAlways:SetChecked(st.General.hideQuestObjectivesAlways == true) end
        if controls.blizzardQuesting then controls.blizzardQuesting:SetChecked(st.General.useBlizzardQuestingInterface == true) end
        if controls.tooltips then controls.tooltips:SetChecked(st.General.customTooltips ~= false) end
        if controls.forceCursorTooltips then controls.forceCursorTooltips:SetChecked(st.General.forceCursorTooltips == true) end
        if controls.debuffBorder then controls.debuffBorder:SetChecked(st.Combat.debuffBorderEnabled ~= false) end
        if controls.dispelTrackingEnabled then controls.dispelTrackingEnabled:SetChecked(st.Combat.dispelTrackingEnabled ~= false) end
        if controls.dispelTrackingMax then controls.dispelTrackingMax:SetValue(st.Combat.dispelTrackingMaxShown or 8) end
        if controls.partyDispelIcons then controls.partyDispelIcons:SetChecked(st.Combat.partyDispelTrackingEnabled ~= false) end
        if controls.actionStyle then controls.actionStyle:SetValue(st.ActionBars.globalStyle or "Disabled") end
        if controls.playerFrameEnabled then controls.playerFrameEnabled:SetChecked(st.PlayerFrame.enabled ~= false) end
        if controls.targetFrameEnabled then controls.targetFrameEnabled:SetChecked(st.TargetFrame.enabled ~= false) end
        if controls.focusFrameEnabled then controls.focusFrameEnabled:SetChecked(st.FocusFrame.enabled ~= false) end
        if controls.targetOfTargetEnabled then controls.targetOfTargetEnabled:SetChecked(st.TargetFrame.showTargetOfTarget == true) end
        if controls.mainTankFramesEnabled then controls.mainTankFramesEnabled:SetChecked(st.MainTankFrames.enabled ~= false) end
        if controls.castBarsEnabled then controls.castBarsEnabled:SetChecked((st.CastBars.player.enabled ~= false) and (st.CastBars.target.enabled ~= false) and (st.CastBars.focus.enabled ~= false)) end
        local idx, _, bar = GetSelectedActionBar(st)
        if not state.actionBarSlot or state.actionBarSlot == "" then
            state.actionBarSlot = "Action Bar " .. tostring(idx)
        end
        if controls.actionBarSlot then controls.actionBarSlot:SetValue(state.actionBarSlot) end
        if controls.actionBarEnabled then controls.actionBarEnabled:SetChecked(bar.enabled ~= false) end
        if controls.actionBarStyle then controls.actionBarStyle:SetValue(bar.style or "Class Color") end
        if controls.actionBarRows then controls.actionBarRows:SetValue(bar.rows or 1) end
        if controls.actionBarIcons then controls.actionBarIcons:SetValue(bar.iconsPerRow or 12) end
        if controls.actionBarScale then controls.actionBarScale:SetValue(bar.scale or 100) end
        if controls.actionBarSpacing then controls.actionBarSpacing:SetValue(bar.spacing or 6) end
        if controls.inventoryEnabled then controls.inventoryEnabled:SetChecked((not st.Inventory) or st.Inventory.enabled ~= false) end
        if controls.consumables then controls.consumables:SetChecked(st.ConsumableBars.enabled ~= false) end
        if controls.consumablesHideInactive then controls.consumablesHideInactive:SetChecked(st.ConsumableBars.hideInactive == true) end
        if controls.consumablesInstancesOnly then controls.consumablesInstancesOnly:SetChecked(st.ConsumableBars.showInInstancesOnly == true) end
        if controls.consumablesWidth then controls.consumablesWidth:SetValue(st.ConsumableBars.width or 220) end
        if controls.consumablesHeight then controls.consumablesHeight:SetValue(st.ConsumableBars.height or 10) end
        if controls.consumablesSpacing then controls.consumablesSpacing:SetValue(st.ConsumableBars.spacing or 4) end
        if controls.consumablesScale then controls.consumablesScale:SetValue(st.ConsumableBars.scale or 100) end
        if controls.petBarEnabled then controls.petBarEnabled:SetChecked(st.PetBar.enabled ~= false) end
        if controls.petBarScale then controls.petBarScale:SetValue(st.PetBar.scale or 100) end
        if controls.petBarAlpha then controls.petBarAlpha:SetValue(st.PetBar.alpha or 1.0) end
        if controls.petBarSize then controls.petBarSize:SetValue(st.PetBar.buttonSize or 32) end
        if controls.petBarSpacing then controls.petBarSpacing:SetValue(st.PetBar.spacing or 15) end
        if controls.petBarPerRow then controls.petBarPerRow:SetValue(st.PetBar.buttonsPerRow or 10) end
        if controls.stanceBarEnabled then controls.stanceBarEnabled:SetChecked(st.StanceBar.enabled ~= false) end
        if controls.stanceBarScale then controls.stanceBarScale:SetValue(st.StanceBar.scale or 100) end
        if controls.stanceBarAlpha then controls.stanceBarAlpha:SetValue(st.StanceBar.alpha or 1.0) end
        if controls.stanceBarSize then controls.stanceBarSize:SetValue(st.StanceBar.buttonSize or 32) end
        if controls.stanceBarSpacing then controls.stanceBarSpacing:SetValue(st.StanceBar.spacing or 4) end
        if controls.stanceBarPerRow then controls.stanceBarPerRow:SetValue(st.StanceBar.buttonsPerRow or 3) end
        if controls.chatStyle then controls.chatStyle:SetValue(st.Messenger.style or "Default") end
        if controls.chatTimestamps then controls.chatTimestamps:SetChecked(st.Messenger.showTimestamp ~= false) end
        if controls.chatGlobalOptOut then controls.chatGlobalOptOut:SetChecked(st.Messenger.hideGlobal == true) end
        if controls.chatLoginStatesOptOut then controls.chatLoginStatesOptOut:SetChecked(st.Messenger.hideLoginStates == true) end
        if controls.chatScale then controls.chatScale:SetValue((st.Messenger.scale or 1.0) * 100) end
        if controls.minimapStyle then controls.minimapStyle:SetValue(st.Minimap.infoBarStyle or "Default") end
        if controls.minimapCoords then controls.minimapCoords:SetChecked(st.Minimap.coordsEnabled ~= false) end
        if controls.minimapStatusBars then controls.minimapStatusBars:SetChecked(st.Minimap.useCustomStatusBars ~= false) end
        if controls.overlayHandles then controls.overlayHandles:SetChecked(st.Messenger.locked == false) end
        if controls.overlayLauncher then controls.overlayLauncher:SetValue(state.overlayTarget) end
        SetTuneMode(state.tuneMode, true)
        if UpdateOverlayPanelVisibility then UpdateOverlayPanelVisibility(st) end
        UpdatePresetStatus()
    end

    local function ApplyPresetAndRefresh(name)
        local playstyleByPreset = {
            ["MidnightUI"] = "Casual",
            ["Raid Focused"] = "Raider",
            ["Mythic+"] = "Mythic+",
            ["Class Themed"] = "PvP",
        }
        state.preset = name
        state.simplePlaystyle = playstyleByPreset[name] or state.simplePlaystyle or "Mythic+"
        state.contentProfile = SIMPLE_PLAYSTYLE_TO_CONTENT[state.simplePlaystyle] or state.contentProfile
        ApplyPreset(name, true)
        local resolvedRole = ApplySmartSelections("WELCOME_PRESET_SMART")
        if controls.simplePlaystyle then controls.simplePlaystyle:SetValue(state.simplePlaystyle) end
        if controls.contentProfile then controls.contentProfile:SetValue(state.contentProfile) end
        RefreshTuneControls()
        SetFooterStatus(state.simplePlaystyle .. " starter applied (" .. resolvedRole .. ").", UI_COLORS.success[1], UI_COLORS.success[2], UI_COLORS.success[3])
    end

    btnPresetBalanced:SetScript("OnClick", function() SetTuneMode("Simple", true); ApplyPresetAndRefresh("MidnightUI") end)
    btnPresetRaid:SetScript("OnClick", function() SetTuneMode("Simple", true); ApplyPresetAndRefresh("Raid Focused") end)
    btnPresetMythic:SetScript("OnClick", function() SetTuneMode("Simple", true); ApplyPresetAndRefresh("Mythic+") end)
    btnPresetArena:SetScript("OnClick", function() SetTuneMode("Simple", true); ApplyPresetAndRefresh("Class Themed") end)

    local p3 = CreateFrame("Frame", nil, pageHost)
    p3:SetAllPoints()
    p3:Hide()
    stepPages[3] = p3

    local p3Tag = p3:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p3Tag:SetPoint("TOPLEFT", 4, -6)
    p3Tag:SetText("STEP 3  FINISH")
    p3Tag:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
    TrySetFont(p3Tag, 12, "OUTLINE")

    local p3Head = p3:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    p3Head:SetPoint("TOPLEFT", 4, -26)
    p3Head:SetText("Stay Connected After Setup")
    p3Head:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    TrySetFont(p3Head, 20, "OUTLINE")

    local p3Sub = p3:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    p3Sub:SetPoint("TOPLEFT", 4, -52)
    p3Sub:SetPoint("TOPRIGHT", -4, -52)
    p3Sub:SetJustifyH("LEFT")
    p3Sub:SetText("MidnightUI is free on |cffff9650CurseForge|r. Join |cff53b8ffDiscord|r for feedback and bug reports, and visit |cff33cc66mpi.atyzi.com|r for your Mythic+ performance dashboard.")
    p3Sub:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(p3Sub, 14)
    CreateHeaderLine(p3, -84)

    local gridCard = CreatePanel(p3, 1, 522)
    gridCard:SetPoint("TOPLEFT", 4, -98)
    gridCard:SetPoint("TOPRIGHT", -4, -98)
    gridCard:SetBackdropColor(0.05, 0.09, 0.16, 0.96)

    local gridAmbient = gridCard:CreateTexture(nil, "BACKGROUND")
    gridAmbient:SetTexture("Interface\\Buttons\\WHITE8X8")
    gridAmbient:SetPoint("TOPLEFT", 1, -1)
    gridAmbient:SetPoint("BOTTOMRIGHT", -1, 1)
    gridAmbient:SetVertexColor(0.02, 0.04, 0.09, 0.88)

    local communityGlow = gridCard:CreateTexture(nil, "ARTWORK")
    communityGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    communityGlow:SetPoint("TOPLEFT", 1, -1)
    communityGlow:SetPoint("TOPRIGHT", -1, -1)
    communityGlow:SetHeight(130)
    communityGlow:SetVertexColor(0.00, 0.78, 1.00, 0.10)

    -- ── Row 1 ──
    local row1 = CreateFrame("Frame", nil, gridCard)
    row1:SetPoint("TOPLEFT", 14, -14)
    row1:SetPoint("TOPRIGHT", -14, -14)
    row1:SetHeight(248)

    local row1Divider = row1:CreateTexture(nil, "BORDER")
    row1Divider:SetTexture("Interface\\Buttons\\WHITE8X8")
    row1Divider:SetPoint("TOP", 0, -4)
    row1Divider:SetPoint("BOTTOM", 0, 4)
    row1Divider:SetWidth(1)
    row1Divider:SetVertexColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.82)

    -- ── Row 2 ──
    local row2 = CreateFrame("Frame", nil, gridCard)
    row2:SetPoint("TOPLEFT", row1, "BOTTOMLEFT", 0, -12)
    row2:SetPoint("TOPRIGHT", row1, "BOTTOMRIGHT", 0, -12)
    row2:SetHeight(248)

    local row2Divider = row2:CreateTexture(nil, "BORDER")
    row2Divider:SetTexture("Interface\\Buttons\\WHITE8X8")
    row2Divider:SetPoint("TOP", 0, -4)
    row2Divider:SetPoint("BOTTOM", 0, 4)
    row2Divider:SetWidth(1)
    row2Divider:SetVertexColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.82)

    -- ── Tile builder ──
    local function CreateSocialTile(parent, side, r, g, b, tagText, titleText, bodyText, impactText, buttonText)
        local tile = CreatePanel(parent, 1, 248)
        if side == "LEFT" then
            tile:SetPoint("TOPLEFT", 0, 0)
            tile:SetPoint("RIGHT", parent, "CENTER", -8, 0)
        else
            tile:SetPoint("TOPRIGHT", 0, 0)
            tile:SetPoint("LEFT", parent, "CENTER", 8, 0)
        end
        tile:SetBackdropColor(0.07, 0.11, 0.19, 0.98)

        local accent = tile:CreateTexture(nil, "ARTWORK")
        accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("TOPRIGHT", -1, -1)
        accent:SetHeight(36)
        accent:SetVertexColor(r, g, b, 0.92)

        local laneTop = tile:CreateTexture(nil, "BACKGROUND")
        laneTop:SetTexture("Interface\\Buttons\\WHITE8X8")
        laneTop:SetPoint("TOPLEFT", 1, -1)
        laneTop:SetPoint("TOPRIGHT", -1, -1)
        laneTop:SetHeight(76)
        laneTop:SetVertexColor(r, g, b, 0.18)

        local subBand = tile:CreateTexture(nil, "ARTWORK")
        subBand:SetTexture("Interface\\Buttons\\WHITE8X8")
        subBand:SetPoint("TOPLEFT", accent, "BOTTOMLEFT", 0, 0)
        subBand:SetPoint("TOPRIGHT", accent, "BOTTOMRIGHT", 0, 0)
        subBand:SetHeight(40)
        subBand:SetVertexColor(r, g, b, 0.22)

        local pulse = tile:CreateTexture(nil, "ARTWORK")
        pulse:SetTexture("Interface\\Buttons\\WHITE8X8")
        pulse:SetPoint("TOPLEFT", 1, -1)
        pulse:SetPoint("BOTTOMRIGHT", -1, 1)
        pulse:SetVertexColor(r, g, b, 0.10)

        local tag = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tag:SetPoint("LEFT", accent, "LEFT", 12, 0)
        tag:SetPoint("RIGHT", accent, "RIGHT", -12, 0)
        tag:SetPoint("TOP", accent, "TOP", 0, -1)
        tag:SetPoint("BOTTOM", accent, "BOTTOM", 0, 1)
        tag:SetJustifyH("CENTER")
        if tag.SetJustifyV then tag:SetJustifyV("MIDDLE") end
        tag:SetText(tagText)
        tag:SetTextColor(0.97, 0.98, 1.00)
        if tag.SetShadowColor then tag:SetShadowColor(0, 0, 0, 0.85) end
        if tag.SetShadowOffset then tag:SetShadowOffset(1, -1) end
        TrySetFont(tag, 13, "OUTLINE")

        local title = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        title:SetPoint("LEFT", subBand, "LEFT", 12, 0)
        title:SetPoint("RIGHT", subBand, "RIGHT", -12, 0)
        title:SetPoint("TOP", subBand, "TOP", 0, -1)
        title:SetPoint("BOTTOM", subBand, "BOTTOM", 0, 1)
        title:SetJustifyH("CENTER")
        if title.SetJustifyV then title:SetJustifyV("MIDDLE") end
        title:SetText(titleText)
        title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
        if title.SetShadowColor then title:SetShadowColor(0, 0, 0, 0.8) end
        if title.SetShadowOffset then title:SetShadowOffset(1, -1) end
        TrySetFont(title, 15, "OUTLINE")

        local impact = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        impact:SetPoint("BOTTOMLEFT", 12, 58)
        impact:SetPoint("BOTTOMRIGHT", -12, 58)
        impact:SetJustifyH("CENTER")
        impact:SetText(impactText)
        impact:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
        TrySetFont(impact, 12)

        local body = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        body:SetPoint("TOPLEFT", 12, -90)
        body:SetPoint("TOPRIGHT", -12, -90)
        body:SetPoint("BOTTOMLEFT", impact, "TOPLEFT", 0, 6)
        body:SetPoint("BOTTOMRIGHT", impact, "TOPRIGHT", 0, 6)
        body:SetJustifyH("CENTER")
        if body.SetJustifyV then body:SetJustifyV("MIDDLE") end
        body:SetText(bodyText)
        body:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
        TrySetFont(body, 12)

        local button = CreateFrame("Button", nil, tile, "UIPanelButtonTemplate")
        button:SetPoint("BOTTOMLEFT", 12, 12)
        button:SetPoint("BOTTOMRIGHT", -12, 12)
        button:SetHeight(34)
        button:SetText(buttonText)
        StyleButton(button)

        local aura = button:CreateTexture(nil, "BACKGROUND")
        aura:SetTexture("Interface\\Buttons\\WHITE8X8")
        aura:SetPoint("TOPLEFT", 1, -1)
        aura:SetPoint("BOTTOMRIGHT", -1, 1)
        aura:SetVertexColor(r, g, b, 0.16)
        button:HookScript("OnEnter", function() aura:SetVertexColor(r, g, b, 0.26) end)
        button:HookScript("OnLeave", function() aura:SetVertexColor(r, g, b, 0.16) end)

        return tile, button, pulse
    end

    -- ── Row 1: MPI + Discord ──
    local mpiTile, btnMPI, mpiPulse = CreateSocialTile(
        row1,
        "LEFT",
        0.20, 0.80, 0.40,
        "MYTHIC+ PERFORMANCE",
        "Install |cff33cc66MPI Companion|r",
        "A free desktop app that scores every player in your group after each Mythic+ run and shares those scores with every other MidnightUI player. The more players who install it, the more accurate scores become for everyone.",
        "|cff33cc66Helps the community build better groups.|r",
        "Download Companion"
    )

    local discordTile, btnDiscord, discordPulse = CreateSocialTile(
        row1,
        "RIGHT",
        0.32, 0.69, 1.00,
        "JOIN THE DISCORD",
        "Be part of the |cff53b8ffMidnightUI|r community",
        "Report bugs, request features, get help from other players, and stay up to date with releases. Members also get access to giveaways and exclusive early previews.",
        "|cff53b8ffYour feedback directly shapes every update.|r",
        "Join Discord"
    )

    -- ── Row 2: CurseForge + Snapshot ──
    local curseforgeTile, btnCurseForge, curseforgePulse = CreateSocialTile(
        row2,
        "LEFT",
        1.00, 0.56, 0.28,
        "RATE & REVIEW",
        "Help other players find MidnightUI on |cffff9650CurseForge|r",
        "Leave a rating or review to help other players discover the addon. CurseForge is also the best place to grab updates.",
        "|cffff9650Your review helps the addon reach more players.|r",
        "Open CurseForge"
    )

    btnMPI:SetScript("OnClick", function() OpenURL(MPI_COMPANION_URL) end)
    btnDiscord:SetScript("OnClick", function() OpenURL(DISCORD_URL) end)
    btnCurseForge:SetScript("OnClick", function() OpenURL(CURSEFORGE_URL) end)

    -- ── Snapshot tile (row2, right) ──
    local snapTile = CreatePanel(row2, 1, 248)
    snapTile:SetPoint("TOPRIGHT", 0, 0)
    snapTile:SetPoint("LEFT", row2, "CENTER", 8, 0)
    snapTile:SetBackdropColor(0.07, 0.11, 0.19, 0.98)

    local snapAccent = snapTile:CreateTexture(nil, "ARTWORK")
    snapAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    snapAccent:SetPoint("TOPLEFT", 1, -1)
    snapAccent:SetPoint("TOPRIGHT", -1, -1)
    snapAccent:SetHeight(36)
    snapAccent:SetVertexColor(0.00, 0.78, 1.00, 0.92)

    local snapLane = snapTile:CreateTexture(nil, "BACKGROUND")
    snapLane:SetTexture("Interface\\Buttons\\WHITE8X8")
    snapLane:SetPoint("TOPLEFT", 1, -1)
    snapLane:SetPoint("TOPRIGHT", -1, -1)
    snapLane:SetHeight(76)
    snapLane:SetVertexColor(0.00, 0.78, 1.00, 0.18)

    local snapSubBand = snapTile:CreateTexture(nil, "ARTWORK")
    snapSubBand:SetTexture("Interface\\Buttons\\WHITE8X8")
    snapSubBand:SetPoint("TOPLEFT", snapAccent, "BOTTOMLEFT", 0, 0)
    snapSubBand:SetPoint("TOPRIGHT", snapAccent, "BOTTOMRIGHT", 0, 0)
    snapSubBand:SetHeight(40)
    snapSubBand:SetVertexColor(0.00, 0.78, 1.00, 0.22)

    local snapTag = snapTile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    snapTag:SetPoint("LEFT", snapAccent, "LEFT", 12, 0)
    snapTag:SetPoint("RIGHT", snapAccent, "RIGHT", -12, 0)
    snapTag:SetPoint("TOP", snapAccent, "TOP", 0, -1)
    snapTag:SetPoint("BOTTOM", snapAccent, "BOTTOM", 0, 1)
    snapTag:SetJustifyH("CENTER")
    if snapTag.SetJustifyV then snapTag:SetJustifyV("MIDDLE") end
    snapTag:SetText("CONFIGURATION SNAPSHOT")
    snapTag:SetTextColor(0.97, 0.98, 1.00)
    if snapTag.SetShadowColor then snapTag:SetShadowColor(0, 0, 0, 0.85) end
    if snapTag.SetShadowOffset then snapTag:SetShadowOffset(1, -1) end
    TrySetFont(snapTag, 13, "OUTLINE")

    local snapSubTitle = snapTile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    snapSubTitle:SetPoint("LEFT", snapSubBand, "LEFT", 12, 0)
    snapSubTitle:SetPoint("RIGHT", snapSubBand, "RIGHT", -12, 0)
    snapSubTitle:SetPoint("TOP", snapSubBand, "TOP", 0, -1)
    snapSubTitle:SetPoint("BOTTOM", snapSubBand, "BOTTOM", 0, 1)
    snapSubTitle:SetJustifyH("CENTER")
    if snapSubTitle.SetJustifyV then snapSubTitle:SetJustifyV("MIDDLE") end
    snapSubTitle:SetText("Your current wizard selections at a glance")
    snapSubTitle:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])
    if snapSubTitle.SetShadowColor then snapSubTitle:SetShadowColor(0, 0, 0, 0.8) end
    if snapSubTitle.SetShadowOffset then snapSubTitle:SetShadowOffset(1, -1) end
    TrySetFont(snapSubTitle, 13, "OUTLINE")

    -- Two-column snapshot data
    local snapColLeft = snapTile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    snapColLeft:SetPoint("TOPLEFT", 12, -86)
    snapColLeft:SetPoint("BOTTOMLEFT", 12, 56)
    snapColLeft:SetPoint("RIGHT", snapTile, "CENTER", -4, 0)
    snapColLeft:SetJustifyH("LEFT")
    if snapColLeft.SetJustifyV then snapColLeft:SetJustifyV("TOP") end
    snapColLeft:SetText("")
    snapColLeft:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(snapColLeft, 11)

    local snapColRight = snapTile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    snapColRight:SetPoint("TOPRIGHT", -12, -86)
    snapColRight:SetPoint("BOTTOMRIGHT", -12, 56)
    snapColRight:SetPoint("LEFT", snapTile, "CENTER", 4, 0)
    snapColRight:SetJustifyH("LEFT")
    if snapColRight.SetJustifyV then snapColRight:SetJustifyV("TOP") end
    snapColRight:SetText("")
    snapColRight:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
    TrySetFont(snapColRight, 11)

    local btnOpenSettings = CreateFrame("Button", nil, snapTile, "UIPanelButtonTemplate")
    btnOpenSettings:SetPoint("BOTTOMLEFT", 12, 12)
    btnOpenSettings:SetPoint("BOTTOMRIGHT", -12, 12)
    btnOpenSettings:SetHeight(34)
    btnOpenSettings:SetText("Open Full Settings")
    StyleButton(btnOpenSettings)
    btnOpenSettings:SetScript("OnClick", OpenSettingsPanel)

    local snapAura = btnOpenSettings:CreateTexture(nil, "BACKGROUND")
    snapAura:SetTexture("Interface\\Buttons\\WHITE8X8")
    snapAura:SetPoint("TOPLEFT", 1, -1)
    snapAura:SetPoint("BOTTOMRIGHT", -1, 1)
    snapAura:SetVertexColor(0.00, 0.78, 1.00, 0.16)
    btnOpenSettings:HookScript("OnEnter", function() snapAura:SetVertexColor(0.00, 0.78, 1.00, 0.26) end)
    btnOpenSettings:HookScript("OnLeave", function() snapAura:SetVertexColor(0.00, 0.78, 1.00, 0.16) end)

    local function UpdateSummary()
        local stamp = state.lastAppliedAt or "not applied yet"
        local st = EnsureSettings()
        local theme = st.GlobalStyle or "Default"
        local barStyle = (st.General and st.General.unitFrameBarStyle) or "Gradient"
        local pW = (st.PlayerFrame and st.PlayerFrame.width) or 380
        local pH = (st.PlayerFrame and st.PlayerFrame.height) or 66
        local tW = (st.TargetFrame and st.TargetFrame.width) or 380
        local tH = (st.TargetFrame and st.TargetFrame.height) or 66
        local castEnabled = (st.CastBars and st.CastBars.player and st.CastBars.player.enabled ~= false and st.CastBars.target and st.CastBars.target.enabled ~= false and st.CastBars.focus and st.CastBars.focus.enabled ~= false) and "On" or "Off"
        local consumablesEnabled = (st.ConsumableBars and st.ConsumableBars.enabled ~= false) and "On" or "Off"
        local tipsEnabled = (st.General and st.General.customTooltips ~= false) and "On" or "Off"
        local questInCombat = (st.General and st.General.hideQuestObjectivesInCombat == true) and "Hide" or "Show"
        local barIndex, _, selectedBar = GetSelectedActionBar(st)
        local selectedBarEnabled = (selectedBar and selectedBar.enabled ~= false) and "On" or "Off"
        local selectedBarStyle = (selectedBar and selectedBar.style) or "Class Color"

        snapColLeft:SetText(
            "|cff7fc8ffPreset|r  " .. tostring(state.preset)
            .. "\n|cff7fc8ffRole|r  " .. tostring(state.roleProfile)
            .. "\n|cff7fc8ffContent|r  " .. tostring(state.contentProfile)
            .. "\n|cff7fc8ffMode|r  " .. tostring(state.tuneMode)
            .. "\n|cff7fc8ffTheme|r  " .. tostring(theme)
            .. "\n|cff7fc8ffReadability|r  " .. tostring(state.readabilityPreset)
            .. "\n|cff7fc8ffPlayer|r  " .. tostring(pW) .. "x" .. tostring(pH)
            .. "\n|cff7fc8ffTarget|r  " .. tostring(tW) .. "x" .. tostring(tH)
        )

        snapColRight:SetText(
            "|cff7fc8ffCast Bars|r  " .. castEnabled
            .. "\n|cff7fc8ffConsumables|r  " .. consumablesEnabled
            .. "\n|cff7fc8ffTooltips|r  " .. tipsEnabled
            .. "\n|cff7fc8ffBar " .. tostring(barIndex) .. "|r  " .. selectedBarEnabled
            .. "\n|cff7fc8ffBar Style|r  " .. selectedBarStyle
            .. "\n|cff7fc8ffUnit Bars|r  " .. barStyle
            .. "\n|cff7fc8ffQuest Combat|r  " .. questInCombat
            .. "\n|cff7fc8ffOverlay|r  " .. tostring(state.overlayTarget)
        )
    end

    onStepChanged = function(idx)
        btnBack:SetEnabled(idx > 1)
        if idx == 3 then
            btnNext:Show()
            btnNext:SetText("Finish Setup")
            btnNext:SetAlpha(0.85)
            SetFooterStatus("Explore the links above, then finish setup.", 0.93, 0.88, 0.72)
            UpdateSummary()
        elseif idx == 2 then
            btnNext:Show()
            btnNext:SetText("Next")
            btnNext:SetAlpha(1)
            RefreshTuneControls()
            SetFooterStatus("Use Simple for a quick setup, or Expert to fine-tune everything. Use Unlock Frames to place your UI.")
        else
            btnNext:Hide()
            SetFooterStatus("Import a profile, or continue with a fresh setup.")
            RefreshQuickOptions()
        end
    end

    btnBack:SetScript("OnClick", function()
        if currentStep > 1 then
            ShowStep(currentStep - 1, true)
        end
    end)

    btnNext:SetScript("OnClick", function()
        if currentStep == 1 and f and f.AnimateSize then
            f:AnimateSize(EXPANDED_W, EXPANDED_H, 0.25)
        end
        if currentStep < 3 then
            unlockedStep = math.max(unlockedStep, currentStep + 1)
            ShowStep(currentStep + 1, true)
            return
        end
        if Profiles and Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
        if Profiles and Profiles.SaveCurrentProfile then Profiles.SaveCurrentProfile("welcome_finish") end
        if previewDock then previewDock:Hide() end
        f:Hide()
        -- Show What's New after wizard finishes
        C_Timer.After(0.5, function()
            if _G.MidnightUI_TryShowWhatsNew then _G.MidnightUI_TryShowWhatsNew() end
        end)
    end)

    close:SetScript("OnClick", function()
        if Profiles and Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
        if previewDock then previewDock:Hide() end
        f:Hide()
        -- Show What's New after wizard closes
        C_Timer.After(0.5, function()
            if _G.MidnightUI_TryShowWhatsNew then _G.MidnightUI_TryShowWhatsNew() end
        end)
    end)

    local t = 0
    local baseA, baseB = 118, 70
    f:SetScript("OnUpdate", function(self, elapsed)
        t = t + (elapsed or 0)
        if self._sizeAnim then
            local a = self._sizeAnim
            a.t = a.t + (elapsed or 0)
            local p = math.min(1, a.t / a.dur)
            local ease = p * p * (3 - 2 * p)
            local w = a.fromW + (a.toW - a.fromW) * ease
            local h = a.fromH + (a.toH - a.fromH) * ease
            self:SetSize(w, h)
            if self._leftRail then self._leftRail:SetHeight(h) end
            if p >= 1 then
                self._sizeAnim = nil
            end
        end
        local pulseA = 0.22 + (math.sin(t * 1.2) * 0.06)
        local pulseB = 0.30 + (math.sin(t * 1.6 + 0.8) * 0.08)
        local scaleA = 1.00 + (math.sin(t * 0.7) * 0.02)
        local scaleB = 1.00 + (math.sin(t * 0.9 + 0.4) * 0.025)
        if ringA and ringB then
            ringA:SetAlpha(math.max(0.10, math.min(0.45, pulseA)))
            ringB:SetAlpha(math.max(0.12, math.min(0.55, pulseB)))
            ringA:SetSize(baseA * scaleA, baseA * scaleA)
            ringB:SetSize(baseB * scaleB, baseB * scaleB)
        end
        communityGlow:SetVertexColor(0.00, 0.78, 1.00, math.max(0.06, math.min(0.24, 0.14 + math.sin(t * 1.8) * 0.08)))
        mpiPulse:SetVertexColor(0.20, 0.80, 0.40, math.max(0.06, math.min(0.24, 0.13 + math.sin(t * 1.9 + 0.6) * 0.09)))
        discordPulse:SetVertexColor(0.32, 0.69, 1.00, math.max(0.06, math.min(0.24, 0.13 + math.sin(t * 2.2 + 0.4) * 0.09)))
        curseforgePulse:SetVertexColor(1.00, 0.56, 0.28, math.max(0.08, math.min(0.30, 0.17 + math.sin(t * 2.0 + 1.0) * 0.11)))
        if ringA and ringA.SetRotation then ringA:SetRotation(t * 0.05) end
        if ringB and ringB.SetRotation then ringB:SetRotation(-t * 0.08) end
    end)

    f.Refresh = function(self)
        if previewDock then previewDock:Hide() end
        RefreshQuickOptions()
        RefreshTuneControls()
        UpdateSummary()
    end

    f.ShowStep = function(self, idx, force)
        if idx == 2 and self.AnimateSize and not self._sizeExpanded then
            self._sizeExpanded = true
            self:AnimateSize(EXPANDED_W, EXPANDED_H, 0.25)
        end
        ShowStep(idx, force)
    end

    f.AnimateSize = function(self, w, h, dur)
        local cw, ch = self:GetSize()
        self._sizeAnim = {
            t = 0,
            dur = dur or 0.25,
            fromW = cw,
            fromH = ch,
            toW = w,
            toH = h,
        }
    end

    ShowStep(1, true)

    -- Expose ExitPreviewMode as a global function
    _G.MidnightUI_WelcomeExitPreview = ExitPreviewMode

    return f
end

function _G.MidnightUI_ShowWelcome(force)
    if not welcomeFrame then welcomeFrame = CreateWelcomeFrame() end
    local seen = false
    if Profiles and Profiles.HasSeenWelcome then
        local ok, res = pcall(Profiles.HasSeenWelcome)
        if ok then seen = (res == true) end
    end
    if not force and seen then
        if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource and _G.MidnightUI_Diagnostics.IsEnabled and _G.MidnightUI_Diagnostics.IsEnabled() then
            _G.MidnightUI_Diagnostics.LogDebugSource("Welcome", "ShowWelcome blocked: HasSeenWelcome=true")
        elseif _G.MidnightUI_Debug then
            _G.MidnightUI_Debug("[Welcome] ShowWelcome blocked: HasSeenWelcome=true")
        end
        return
    end
    if not force and Profiles and Profiles.MarkWelcomeSeen then Profiles.MarkWelcomeSeen() end
    welcomeFrame:Show()
    welcomeFrame:Raise()
    if welcomeFrame.Refresh then welcomeFrame:Refresh() end
    if welcomeFrame.ShowStep then welcomeFrame:ShowStep(1, true) end
end

function _G.MidnightUI_ReturnToWelcomeWizard()
    -- Call the global exit preview function which has proper closure access
    if _G.MidnightUI_WelcomeExitPreview then
        _G.MidnightUI_WelcomeExitPreview()
    elseif welcomeFrame then
        welcomeFrame:Show()
        welcomeFrame:Raise()
    end
end

function _G.MidnightUI_TryShowWelcome()
    if not Profiles or not Profiles.HasSeenWelcome then return end
    local seen = false
    local okSeen, resSeen = pcall(Profiles.HasSeenWelcome)
    if okSeen then seen = (resSeen == true) end
    if seen then
        return
    end
    if InCombatLockdown and InCombatLockdown() then
        Log("Welcome deferred, player in combat")
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function()
                if not InCombatLockdown or not InCombatLockdown() then
                    _G.MidnightUI_ShowWelcome()
                end
            end)
        end
        return
    end
    local ok, err = pcall(_G.MidnightUI_ShowWelcome)
    if not ok then
        if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource and _G.MidnightUI_Diagnostics.IsEnabled and _G.MidnightUI_Diagnostics.IsEnabled() then
            _G.MidnightUI_Diagnostics.LogDebugSource("Welcome", "TryShowWelcome: ShowWelcome error: " .. tostring(err))
        elseif _G.MidnightUI_Debug then
            _G.MidnightUI_Debug("[Welcome] TryShowWelcome: ShowWelcome error: " .. tostring(err))
        end
    end
end


-- ============================================================================
-- §  WHAT'S NEW PANEL
-- ============================================================================
-- Shows once per addon version, either after the Welcome Wizard finishes or
-- on first login after an update. Tracks `WhatsNewSeen[charKey] = version`.
-- 3-panel showcase: Guild Panel, Group Finder, MPI Scores + Dashboard.

local WHATS_NEW_VERSION = "1.9.0"  -- bump this with each release that has news

local whatsNewFrame = nil

local function CreateWhatsNewFrame()
    local W, H = 740, 600
    local f = CreatePanel(UIParent, W, H)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(100)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:Hide()

    -- Top accent bar
    local topBar = f:CreateTexture(nil, "ARTWORK")
    topBar:SetTexture("Interface\\Buttons\\WHITE8X8")
    topBar:SetPoint("TOPLEFT", 1, -1)
    topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetHeight(3)
    topBar:SetVertexColor(0.00, 0.78, 1.00, 0.90)

    -- Header
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 24, -18)
    TrySetFont(title, 24, "OUTLINE")
    title:SetText("What's New in MidnightUI")
    title:SetTextColor(1, 1, 1)

    -- Version + tagline
    local verLine = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    verLine:SetPoint("TOPLEFT", 24, -50)
    TrySetFont(verLine, 12)
    verLine:SetText("v" .. WHATS_NEW_VERSION .. " — here's what we've been working on.")
    verLine:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])

    -- Close button
    local close = CreateFrame("Button", nil, f)
    close:SetSize(28, 28)
    close:SetPoint("TOPRIGHT", -12, -12)
    local closeText = close:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeText, 18, "OUTLINE")
    closeText:SetPoint("CENTER")
    closeText:SetText("x")
    closeText:SetTextColor(0.6, 0.6, 0.6)
    close:SetScript("OnEnter", function() closeText:SetTextColor(1, 0.3, 0.3) end)
    close:SetScript("OnLeave", function() closeText:SetTextColor(0.6, 0.6, 0.6) end)

    CreateHeaderLine(f, -72)

    -- ═══════════════════════════════════════════════════════════════════════
    -- 3-PANEL GRID: Guild | Group Finder | MPI Scores
    -- ═══════════════════════════════════════════════════════════════════════

    local CARD_PAD = 20
    local CARD_TOP = -82
    local CARD_W = math.floor((W - CARD_PAD * 4) / 3)
    local CARD_H = 400

    -- Helper: build a feature showcase card
    local function MakeShowcaseCard(parent, xOffset, accentR, accentG, accentB, tagText, titleText, bodyLines, ctaText, ctaAction)
        local card = CreatePanel(parent, CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", CARD_PAD + xOffset, CARD_TOP)
        card:SetBackdropColor(0.05, 0.07, 0.13, 0.98)

        -- Top accent bar
        local cAccent = card:CreateTexture(nil, "ARTWORK")
        cAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
        cAccent:SetPoint("TOPLEFT", 1, -1)
        cAccent:SetPoint("TOPRIGHT", -1, -1)
        cAccent:SetHeight(3)
        cAccent:SetVertexColor(accentR, accentG, accentB, 0.90)

        -- Ambient glow
        local glow = card:CreateTexture(nil, "BACKGROUND")
        glow:SetTexture("Interface\\Buttons\\WHITE8X8")
        glow:SetPoint("TOPLEFT", 1, -1)
        glow:SetPoint("TOPRIGHT", -1, -1)
        glow:SetHeight(80)
        glow:SetVertexColor(accentR, accentG, accentB, 0.06)

        -- Tag pill
        local tag = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        tag:SetPoint("TOPLEFT", 14, -14)
        TrySetFont(tag, 8, "OUTLINE")
        tag:SetText(tagText)
        tag:SetTextColor(accentR, accentG, accentB)

        -- Title
        local cTitle = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        cTitle:SetPoint("TOPLEFT", 14, -32)
        cTitle:SetPoint("TOPRIGHT", -14, -32)
        TrySetFont(cTitle, 15, "")
        cTitle:SetText(titleText)
        cTitle:SetTextColor(1, 1, 1)
        cTitle:SetJustifyH("LEFT")

        -- Body text (multiple paragraphs)
        local yOff = -60
        for _, line in ipairs(bodyLines) do
            local para = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            para:SetPoint("TOPLEFT", 14, yOff)
            para:SetPoint("TOPRIGHT", -14, yOff)
            para:SetJustifyH("LEFT")
            TrySetFont(para, 11)
            para:SetText(line)
            para:SetTextColor(UI_COLORS.muted[1], UI_COLORS.muted[2], UI_COLORS.muted[3])
            para:SetSpacing(2)
            local h = para:GetStringHeight() or 30
            yOff = yOff - h - 10
        end

        -- CTA button at bottom
        if ctaText then
            local btn = CreateFrame("Button", nil, card, "UIPanelButtonTemplate")
            btn:SetPoint("BOTTOMLEFT", 12, 14)
            btn:SetPoint("BOTTOMRIGHT", -12, 14)
            btn:SetHeight(32)
            btn:SetText(ctaText)
            StyleButton(btn)

            local btnGlow = btn:CreateTexture(nil, "BACKGROUND")
            btnGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
            btnGlow:SetPoint("TOPLEFT", 1, -1)
            btnGlow:SetPoint("BOTTOMRIGHT", -1, 1)
            btnGlow:SetVertexColor(accentR, accentG, accentB, 0.14)
            btn:HookScript("OnEnter", function() btnGlow:SetVertexColor(accentR, accentG, accentB, 0.28) end)
            btn:HookScript("OnLeave", function() btnGlow:SetVertexColor(accentR, accentG, accentB, 0.14) end)

            btn:SetScript("OnClick", function()
                if ctaAction == "groupfinder" then
                    if PVEFrame_ToggleFrame then
                        PVEFrame_ToggleFrame("GroupFinderFrame")
                    end
                    f:Hide()
                elseif ctaAction == "website" then
                    if _G.MidnightUI_OpenURL then
                        _G.MidnightUI_OpenURL("https://mpi.atyzi.com")
                    end
                elseif ctaAction == "guild" then
                    if ToggleGuildFrame then
                        ToggleGuildFrame()
                    elseif GuildFrame_Toggle then
                        GuildFrame_Toggle()
                    end
                    f:Hide()
                end
            end)
        end

        return card
    end

    -- ── Card 1: Redesigned Guild Panel ──────────────────────────────────
    MakeShowcaseCard(f, 0,
        0.32, 0.69, 1.00,  -- blue
        "REDESIGNED",
        "Guild Panel",
        {
            "Your guild interface has been completely rebuilt from the ground up.",
            "See your guild roster, officer notes, and guild news in a clean modern layout that matches the rest of MidnightUI.",
            "Guild recruitment tools are built right in — post listings, review applicants, and manage your guild without leaving the panel.",
        },
        "Open Guild Panel",
        "guild"
    )

    -- ── Card 2: Rebuilt Group Finder ────────────────────────────────────
    MakeShowcaseCard(f, CARD_W + CARD_PAD,
        0.20, 0.80, 0.40,  -- green
        "REBUILT",
        "Dungeon Finder",
        {
            "The Group Finder has been redesigned with a powerful new layout for finding and listing Mythic+ groups.",
            "Browse keys by dungeon, key level, and role. See group composition at a glance. One-click apply with smart filters.",
            "If you have MPI scores (see next panel), you'll see player performance ratings directly on every listing and applicant.",
        },
        "Open Group Finder",
        "groupfinder"
    )

    -- ── Card 3: MPI Scores + Dashboard ─────────────────────────────────
    MakeShowcaseCard(f, (CARD_W + CARD_PAD) * 2,
        0.61, 0.48, 0.93,  -- purple
        "NEW FEATURE",
        "M+ Player Scores",
        {
            "Every player in your group now gets a performance score from 0-100 after each Mythic+ run.",
            "Scores measure five things: how well you dodge mechanics, how often you stay alive, your damage output, how much you interrupt, and how consistent you are.",
            "Install the free |cff9b7aedMPI Companion|r desktop app and your scores upload to |cff9b7aedmpi.atyzi.com|r — a full dashboard with run replays, death analysis, boss breakdowns, and tips to improve.",
        },
        "Get MPI Companion",
        "website"
    )

    -- ═══════════════════════════════════════════════════════════════════════
    -- BOTTOM BAR
    -- ═══════════════════════════════════════════════════════════════════════

    local gotIt = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    gotIt:SetPoint("BOTTOMLEFT", 24, 16)
    gotIt:SetPoint("BOTTOMRIGHT", -24, 16)
    gotIt:SetHeight(36)
    gotIt:SetText("Got It — Let's Go!")
    StyleButton(gotIt)

    -- Close logic
    local function CloseWhatsNew()
        if Profiles and Profiles.MarkWhatsNewSeen then
            Profiles.MarkWhatsNewSeen(WHATS_NEW_VERSION)
        end
        f:Hide()
    end

    close:SetScript("OnClick", CloseWhatsNew)
    gotIt:SetScript("OnClick", CloseWhatsNew)
    f:SetScript("OnKeyDown", function(self, key)
        if key == "ESCAPE" then
            CloseWhatsNew()
            self:SetPropagateKeyboardInput(false)
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)

    return f
end

--- Show the What's New panel if the player hasn't seen it for this version.
function _G.MidnightUI_TryShowWhatsNew()
    if not Profiles then return end

    -- Don't show if they haven't completed the Welcome Wizard yet
    if Profiles.HasSeenWelcome then
        local ok, seen = pcall(Profiles.HasSeenWelcome)
        if ok and not seen then return end
    end

    -- Check if they've already seen What's New for this version
    if Profiles.HasSeenWhatsNew then
        local ok, seen = pcall(Profiles.HasSeenWhatsNew, WHATS_NEW_VERSION)
        if ok and seen then return end
    end

    -- Don't show in combat
    if InCombatLockdown and InCombatLockdown() then
        if C_Timer and C_Timer.After then
            C_Timer.After(3, function()
                if not InCombatLockdown or not InCombatLockdown() then
                    _G.MidnightUI_TryShowWhatsNew()
                end
            end)
        end
        return
    end

    -- Create and show
    if not whatsNewFrame then
        whatsNewFrame = CreateWhatsNewFrame()
    end
    whatsNewFrame:Show()
    whatsNewFrame:Raise()
end

--- Force show What's New (for slash command / settings button)
function _G.MidnightUI_ShowWhatsNew()
    if not whatsNewFrame then
        whatsNewFrame = CreateWhatsNewFrame()
    end
    whatsNewFrame:Show()
    whatsNewFrame:Raise()
end
