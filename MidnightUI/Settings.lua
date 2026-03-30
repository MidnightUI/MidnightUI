--------------------------------------------------------------------------------
-- Settings.lua | MidnightUI
-- PURPOSE: Central settings manager. Owns the MidnightUISettings saved-variable
--          tree, provides defaults, initialization, apply/refresh callbacks for
--          every module, the movement-mode grid/HUD, overlay manager, quest
--          objective visibility, slash commands, and global API accessors.
-- DEPENDS ON: Nothing at load time (first file loaded). Other modules register
--             globals that this file calls via _G.MidnightUI_* at runtime.
-- EXPORTS (globals):
--   MidnightUISettings          - SavedVariable table (persisted by WoW)
--   MidnightUI_Settings  (M)   - Module namespace shared with Settings_UI.lua
--     M.DEFAULTS, M.Controls, M.SettingsCategory, M.GridFrame, M.MoveHUD
--     M.DrawGrid, M.ApplyMessengerSettings, M.ApplyPlayerSettings,
--     M.ApplyTargetSettings, M.ApplyFocusSettings, M.ApplyPetSettings,
--     M.ApplyActionBarSettings[Immediate], M.ApplyCastBarSettings,
--     M.ApplyMinimapSettings, M.ApplyPartyFramesSettings,
--     M.ApplyRaidFramesSettings, M.ApplyUnitFrameBarStyle,
--     M.ApplySharedUnitFrameAppearance, M.ApplyNameplateSettings,
--     M.ApplyGlobalTheme, M.EnsureCastBarsSettings, M.EnsureNameplateSettings,
--     M.ApplyQuestObjectiveVisibility, M.InitializeSettings, M.ShowPage
--   MidnightUI_RefreshAllUnitFrames()
--   MidnightUI_GetActionBarSettings(), MidnightUI_SetActionBarSetting()
--   MidnightUI_GetMessengerSettings()
--   MidnightUI_GetSharedUnitAppearanceSettings()
--   MidnightUI_ApplySharedUnitTextStyle()
--   MidnightUI_ApplySharedUnitFrameAppearance()
--   MidnightUI_ApplyQuestObjectivesVisibility()
--   MidnightUI_ToggleOverlayManager()
--   MidnightUI_EnterKeybindMode()
--   SLASH /midnight, /mui
-- ARCHITECTURE: Settings.lua is the backbone. It loads before all UI modules.
--   Settings_Keybinds.lua adds the keybind subsystem.
--   Settings_UI.lua builds the full settings panel and registers with Blizzard.
--   Every other MidnightUI module reads from MidnightUISettings and exposes
--   _G.MidnightUI_* refresh functions that the Apply* helpers call.
--------------------------------------------------------------------------------

MidnightUISettings = MidnightUISettings or {}
MidnightUI_Settings = MidnightUI_Settings or {}
local M = MidnightUI_Settings

-- ============================================================================
-- EARLY TABLE SAFETY
-- Guarantee every top-level sub-table exists before any other file touches them.
-- ============================================================================
if not MidnightUISettings.Messenger then MidnightUISettings.Messenger = {} end
if not MidnightUISettings.ActionBars then MidnightUISettings.ActionBars = {} end
if not MidnightUISettings.PlayerFrame then MidnightUISettings.PlayerFrame = {} end
if not MidnightUISettings.TargetFrame then MidnightUISettings.TargetFrame = {} end
if not MidnightUISettings.FocusFrame then MidnightUISettings.FocusFrame = {} end
if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
if not MidnightUISettings.CastBars then MidnightUISettings.CastBars = {} end
if not MidnightUISettings.Nameplates then MidnightUISettings.Nameplates = {} end
if not MidnightUISettings.Keybinds then MidnightUISettings.Keybinds = {} end
if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
if not MidnightUISettings.InterfaceMenu then MidnightUISettings.InterfaceMenu = {} end
if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
if not MidnightUISettings.General then MidnightUISettings.General = {} end
if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
if not MidnightUISettings.Profiles then MidnightUISettings.Profiles = {} end
if not MidnightUISettings.WelcomeSeen then MidnightUISettings.WelcomeSeen = {} end

local MidnightSettingsCategory = nil
local SettingsControls = {}
M.Controls = SettingsControls

-- ============================================================================
-- DEFAULTS TABLE
-- Master default values for every settings sub-table. Used by InitializeSettings
-- to fill in missing keys and by ResetSettingsToDefaults to restore factory state.
-- Structure mirrors MidnightUISettings exactly (Messenger, ActionBars, PlayerFrame,
-- TargetFrame, FocusFrame, RaidFrames, PartyFrames, MainTankFrames, Nameplates,
-- CastBars, Combat, ConsumableBars, XPBar, RepBar, Minimap, InterfaceMenu,
-- General, Inventory, PetBar, StanceBar).
-- ============================================================================

  local DEFAULTS = {
    Messenger = { locked = true, alpha = 0.85, scale = 1.0, width = 540, height = 310, fontSize = 14, mainTabSpacing = 40, showTimestamp = true, style = "Default", position = {"BOTTOMLEFT", "BOTTOMLEFT", 20, 20}, hideGlobal = false, hideLoginStates = false, showDefaultChatInterface = false, keepDebugHidden = false},
    ActionBars = { boxColor = {0.08, 0.12, 0.22, 0.92}, borderColor = {0.25, 0.45, 0.75, 0.85}, hotkeyColor = {0.85, 0.90, 1.00}, highlightColor = {0.45, 0.75, 1.00, 0.25}, globalStyle = "Disabled" },
    GlobalStyle = "Default",
      PlayerFrame = {
          enabled = true,
          width = 380,
          height = 66,
          scale = 100,
          alpha = 0.95,
          customTooltip = true,
          position = {"BOTTOM", "BOTTOM", -288.33353, 264.00021},
          auras = {
              enabled = true,
              scale = 100,
              alpha = 1.0,
              position = {"CENTER", "CENTER", -377.05408, -267.33368},
              alignment = "Right",
              maxShown = 32,
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
      },
      TargetFrame = {
          enabled = true,
          width = 380,
          height = 66,
          scale = 100,
          alpha = 0.95,
          customTooltip = true,
          rangeSpell = "",
          showTargetOfTarget = false,
          targetOfTarget = {
              scale = 100,
              alpha = 0.95,
              position = nil,
          },
          position = {"BOTTOM", "BOTTOM", 286.66653, 263.44479},
          auras = {
              enabled = true,
              scale = 100,
              alpha = 1.0,
              position = {"CENTER", "CENTER", 188.11072, -251.22168},
              alignment = "Right",
              maxShown = 16,
              perRow = 29,
          },
          debuffs = {
              enabled = true,
              scale = 80,
              alpha = 1.0,
              position = {"BOTTOM", "BOTTOM", 561.58172, 267.56939},
              alignment = "Right",
              filterMode = "AUTO",
              maxShown = 16,
              perRow = 8,
          },
      },
      FocusFrame = {
          enabled = true,
          width = 320,
          height = 58,
          scale = 65,
          alpha = 0.95,
          customTooltip = true,
          position = {"CENTER", "CENTER", 32.171521, -496.92577},
      },
      RaidFrames = {
          enabled = true,
          useDefaultFrames = false,
          position = {"LEFT", "LEFT", 0, 155.77786},
          width = 92,
          height = 24,
          columns = 5,
          spacingX = 6,
          spacingY = 4,
          groupBy = true,
          colorByGroup = true,
          groupBrackets = true,
          layoutStyle = "Detailed",
          showHealthPct = true,
          textSize = 9,
      },
    PartyFrames = {
        enabled = true,
        useDefaultFrames = false,
        position = {"TOPLEFT", "TOPLEFT", 0, 0},
        width = 240,
        height = 58,
        diameter = 64,
        layout = "Vertical",
        spacingX = 8,
        spacingY = 8,
        style = "Rendered",
        hide2DPortrait = false,
        showTooltip = true,
        hideInRaid = false,
    },
    MainTankFrames = {
        enabled = true,
        position = {"TOPLEFT", "UIParent", "TOPLEFT", 20, -620},
        width = 260,
        height = 58,
        spacing = 6,
        scale = 1.0,
    },
    Nameplates = {
        enabled = true,
        debugPartyThreat = false,
        scale = 100,
        showFactionBorder = true,
        targetBorder = true,
        targetPulse = true,
        healthBar = { width = 200, height = 20, alpha = 1.0, nonTargetAlpha = 1.0, nameFontSize = 10, healthPctFontSize = 9, nameAlign = "LEFT", healthPctDisplay = "RIGHT" },
        threatBar = { enabled = true, width = 200, height = 5, alpha = 1.0 },
        castBar = { width = 200, height = 16, alpha = 1.0, fontSize = 12 },
        target = {
            scale = 100,
            healthBar = { width = 240, height = 24, nameFontSize = 10, healthPctFontSize = 9 },
            threatBar = { width = 240, height = 6 },
            castBar = { width = 240, height = 18 },
        },
    },
      CastBars = {
          player = { enabled = true, position = {"BOTTOM", "BOTTOM", -288.8891, 232.88933}, width = 360, height = 24, scale = 100, attachYOffset = -6, matchFrameWidth = true },
          target = { enabled = true, position = nil, width = 360, height = 24, scale = 100, attachYOffset = -6, matchFrameWidth = true },
          focus = { enabled = true, position = nil, width = 320, height = 20, scale = 65, attachYOffset = -6, matchFrameWidth = false },
      },
      Combat = {
          debuffBorderEnabled = true,
          debuffOverlayGlobalEnabled = true,
          debuffOverlayPlayerEnabled = true,
          debuffOverlayFocusEnabled = true,
          debuffOverlayPartyEnabled = true,
          debuffOverlayRaidEnabled = true,
          debuffOverlayTargetOfTargetEnabled = true,
          dispelTrackingEnabled = true,
          dispelTrackingMaxShown = 8,
          dispelTrackingIconScale = 160,
          dispelTrackingOrientation = "HORIZONTAL",
          dispelTrackingAlpha = 1.0,
          dispelTrackingPosition = {"CENTER", "CENTER", -326.6666, -164.66721},
          partyDispelTrackingEnabled = true,
          partyDispelTrackingIconScale = 100,
          partyDispelTrackingAlpha = 1.0,
      },
      ConsumableBars = {
          enabled = true,
          width = 220,
          height = 10,
          spacing = 4,
          scale = 100,
          position = {"BOTTOMRIGHT", "BOTTOMRIGHT", -115.00085, 38.889061},
          hideInactive = false,
          showInInstancesOnly = false,
          debug = false,
          debugVerbose = false,
      },
    XPBar = {
        enabled = true,
        position = {"RIGHT", "RIGHT", -26.666574, 293.66687},
    },
    RepBar = {
        enabled = true,
        position = {"RIGHT", "RIGHT", -26.667011, 275.77802},
    },
    Minimap = {
        enabled = true,
        scale = 100,
        position = nil,
        coordsEnabled = true,
        infoBarStyle = "Default",
        useCustomStatusBars = true,
        infoPanelEnabled = true,
        infoPanelScale = 100,
        infoPanelPosition = nil,
        mailIconPosition = nil,
    },
    InterfaceMenu = {
        enabled = true,
        scale = 100,
        position = {"BOTTOMRIGHT", "BOTTOMRIGHT", -43.889217, 98.333351},
    },
    General = {
        useBlizzardQuestingInterface = false,
        hideQuestObjectivesInCombat = false,
        hideQuestObjectivesAlways = false,
        useDefaultSuperTrackedIcon = false,
        unitFrameBarStyle = "Gradient",
        unitFrameNameScale = 100,
        unitFrameValueScale = 100,
        unitFrameTextOutline = "OUTLINE",
        unitFrameHideLevelText = false,
        unitFrameHidePowerText = false,
        customTooltips = true,
        forceCursorTooltips = true,
        allowSecretHealthPercent = true,
        debugCastBar = false,
        diagnosticsEnabled = true,
        suppressLuaErrors = true,
        diagnosticsToChat = false,
    },
    Inventory = {
        enabled = true,
        separateBags = true,
        dockScale = 105,
        bagSlotSize = 30,
        bagColumns = 4,
        bagSpacing = 4,
    },
    PetBar = {
        enabled = true,
        scale = 85,
        alpha = 0.95,
        buttonSize = 32,
        spacing = 15,
        buttonsPerRow = 10,
        position = {"BOTTOM", "UIParent", "BOTTOM", 0, 140},
    },
      StanceBar = {
          enabled = true,
          scale = 100,
          alpha = 1.0,
          buttonSize = 32,
          spacing = 4,
        buttonsPerRow = 3,
        position = {"BOTTOM", "UIParent", "BOTTOM", -160, 120},
      },
  }

--- CopyTableSafe: Deep-copies a table one level deep. Uses WoW's CopyTable if available.
-- @param src (table|any) - Source value to copy
-- @return (table|any) - Independent copy of src
  local function CopyTableSafe(src)
      if type(src) ~= "table" then return src end
      if type(CopyTable) == "function" then
          return CopyTable(src)
      end
      local t = {}
      for k, v in pairs(src) do
          if type(v) == "table" then
              local sub = {}
              for k2, v2 in pairs(v) do sub[k2] = v2 end
              t[k] = sub
          else
              t[k] = v
          end
      end
      return t
  end

--- ResetSettingsToDefaults: Overwrites every settings sub-table with DEFAULTS.
-- @param reopenWelcome (boolean) - If true, clears WelcomeSeen so the wizard re-opens on next login.
-- @calledby InitializeSettings (when PendingReset is set) and btnResetOverlays OnClick
  local function ResetSettingsToDefaults(reopenWelcome)
      if not MidnightUISettings then return end
      MidnightUISettings.Messenger = CopyTableSafe(DEFAULTS.Messenger)
      MidnightUISettings.PlayerFrame = CopyTableSafe(DEFAULTS.PlayerFrame)
      MidnightUISettings.TargetFrame = CopyTableSafe(DEFAULTS.TargetFrame)
      MidnightUISettings.FocusFrame = CopyTableSafe(DEFAULTS.FocusFrame)
      MidnightUISettings.RaidFrames = CopyTableSafe(DEFAULTS.RaidFrames)
      MidnightUISettings.PartyFrames = CopyTableSafe(DEFAULTS.PartyFrames)
      MidnightUISettings.MainTankFrames = CopyTableSafe(DEFAULTS.MainTankFrames)
      MidnightUISettings.ActionBars = CopyTableSafe(DEFAULTS.ActionBars)
      MidnightUISettings.CastBars = CopyTableSafe(DEFAULTS.CastBars)
      MidnightUISettings.Combat = CopyTableSafe(DEFAULTS.Combat)
      MidnightUISettings.ConsumableBars = CopyTableSafe(DEFAULTS.ConsumableBars)
      MidnightUISettings.Nameplates = CopyTableSafe(DEFAULTS.Nameplates)
      MidnightUISettings.Minimap = CopyTableSafe(DEFAULTS.Minimap)
      MidnightUISettings.General = CopyTableSafe(DEFAULTS.General)
      MidnightUISettings.Inventory = CopyTableSafe(DEFAULTS.Inventory)
      MidnightUISettings.PetBar = CopyTableSafe(DEFAULTS.PetBar)
      MidnightUISettings.StanceBar = CopyTableSafe(DEFAULTS.StanceBar)
      MidnightUISettings.XPBar = CopyTableSafe(DEFAULTS.XPBar)
      MidnightUISettings.RepBar = CopyTableSafe(DEFAULTS.RepBar)
      MidnightUISettings.InterfaceMenu = CopyTableSafe(DEFAULTS.InterfaceMenu)
      MidnightUISettings.PetFrame = { enabled = true, scale = 85, width = 245, height = 48, alpha = 0.95, position = {"CENTER", "CENTER", 19.684318, -229.45317} }
      MidnightUISettings.GlobalStyle = DEFAULTS.GlobalStyle

      MidnightUISettings.Messenger.locked = true
      if MidnightUISettings.General and MidnightUISettings.General.diagnosticsEnabled == nil then
          MidnightUISettings.General.diagnosticsEnabled = true
      end
      if MidnightUISettings.General and MidnightUISettings.General.suppressLuaErrors == nil then
          MidnightUISettings.General.suppressLuaErrors = true
      end

      if reopenWelcome == true then
          -- Clear all welcome flags; key may be unavailable during early load.
          MidnightUISettings.WelcomeSeen = {}
          MidnightUISettings.PendingResetForceWelcome = true
      end

      MidnightUISettings.PendingReset = nil
      MidnightUISettings.PendingResetReopenWelcome = nil
      -- Flag so PLAYER_ENTERING_WORLD knows to force-apply all overlay positions
      MidnightUISettings._wasReset = true
  end
for i = 1, 8 do
    local key = "bar"..i
    local barEnabled = (i <= 3)  -- Bars 1-3 enabled, 4-8 disabled by default
    DEFAULTS.ActionBars[key] = { enabled = barEnabled, rows = 1, iconsPerRow = 12, scale = 100, spacing = 6, style = "Class Color", position = nil }
    if not MidnightUISettings.ActionBars[key] then MidnightUISettings.ActionBars[key] = {} end
end

--- InitializeSettings: Runs once on ADDON_LOADED. Ensures every settings key
--   exists by merging DEFAULTS into MidnightUISettings (nil-check per key).
--   Also handles pending reset, combat debuff overlay migration, value clamping
--   for unitFrameNameScale/unitFrameValueScale, and unitFrameTextOutline validation.
-- @calledby ADDON_LOADED event handler at bottom of this file
  local function InitializeSettings()
if not MidnightUISettings.Profiles then MidnightUISettings.Profiles = {} end
if not MidnightUISettings.WelcomeSeen then MidnightUISettings.WelcomeSeen = {} end
if not MidnightUISettings.CastBars then MidnightUISettings.CastBars = {} end
if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = { enabled = true, scale = 85, width = 245, height = 48, alpha = 0.95 } end
      if MidnightUISettings.PendingReset then
          ResetSettingsToDefaults(MidnightUISettings.PendingResetReopenWelcome == true)
      end
      if MidnightUISettings.GlobalStyle == nil then MidnightUISettings.GlobalStyle = DEFAULTS.GlobalStyle end
    for k, v in pairs(DEFAULTS.Messenger) do if MidnightUISettings.Messenger[k] == nil then MidnightUISettings.Messenger[k] = v end end
    for k, v in pairs(DEFAULTS.ActionBars) do 
        if not k:find("bar") then if MidnightUISettings.ActionBars[k] == nil then MidnightUISettings.ActionBars[k] = v end end
    end
    for i = 1, 8 do
        local key = "bar"..i
        for k, v in pairs(DEFAULTS.ActionBars[key]) do if MidnightUISettings.ActionBars[key][k] == nil then MidnightUISettings.ActionBars[key][k] = v end end
    end
    for k, v in pairs(DEFAULTS.PlayerFrame) do 
        if MidnightUISettings.PlayerFrame[k] == nil then 
            MidnightUISettings.PlayerFrame[k] = v 
        end
    end
    for k, v in pairs(DEFAULTS.RaidFrames) do
        if MidnightUISettings.RaidFrames[k] == nil then
            MidnightUISettings.RaidFrames[k] = v
        end
    end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    for k, v in pairs(DEFAULTS.PartyFrames) do
        if MidnightUISettings.PartyFrames[k] == nil then
            MidnightUISettings.PartyFrames[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.MainTankFrames) do
        if MidnightUISettings.MainTankFrames[k] == nil then
            MidnightUISettings.MainTankFrames[k] = v
        end
    end
    -- Ensure auras sub-table exists
    if not MidnightUISettings.PlayerFrame.auras then 
        MidnightUISettings.PlayerFrame.auras = CopyTable(DEFAULTS.PlayerFrame.auras)
    else
        for k, v in pairs(DEFAULTS.PlayerFrame.auras) do
            if MidnightUISettings.PlayerFrame.auras[k] == nil then
                MidnightUISettings.PlayerFrame.auras[k] = v
            end
        end
    end
    -- Ensure debuffs sub-table exists
    if not MidnightUISettings.PlayerFrame.debuffs then 
        MidnightUISettings.PlayerFrame.debuffs = CopyTable(DEFAULTS.PlayerFrame.debuffs)
    else
        for k, v in pairs(DEFAULTS.PlayerFrame.debuffs) do
            if MidnightUISettings.PlayerFrame.debuffs[k] == nil then
                MidnightUISettings.PlayerFrame.debuffs[k] = v
            end
        end
    end
    for k, v in pairs(DEFAULTS.TargetFrame) do if MidnightUISettings.TargetFrame[k] == nil then MidnightUISettings.TargetFrame[k] = v end end
    if not MidnightUISettings.FocusFrame then MidnightUISettings.FocusFrame = {} end
    -- Ensure auras sub-table exists for TargetFrame
    if not MidnightUISettings.TargetFrame.auras then 
        MidnightUISettings.TargetFrame.auras = CopyTable(DEFAULTS.TargetFrame.auras)
    else
        for k, v in pairs(DEFAULTS.TargetFrame.auras) do
            if MidnightUISettings.TargetFrame.auras[k] == nil then
                MidnightUISettings.TargetFrame.auras[k] = v
            end
        end
    end
    -- Ensure debuffs sub-table exists for TargetFrame
    if not MidnightUISettings.TargetFrame.debuffs then 
        MidnightUISettings.TargetFrame.debuffs = CopyTable(DEFAULTS.TargetFrame.debuffs)
    else
        for k, v in pairs(DEFAULTS.TargetFrame.debuffs) do
            if MidnightUISettings.TargetFrame.debuffs[k] == nil then
                MidnightUISettings.TargetFrame.debuffs[k] = v
            end
        end
    end
    for k, v in pairs(DEFAULTS.FocusFrame) do
        if MidnightUISettings.FocusFrame[k] == nil then MidnightUISettings.FocusFrame[k] = v end
    end
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    for k, v in pairs(DEFAULTS.Combat) do
        if MidnightUISettings.Combat[k] == nil then MidnightUISettings.Combat[k] = v end
    end
    if MidnightUISettings.Combat.debuffOverlayDefaultMigrationApplied ~= true then
        local combat = MidnightUISettings.Combat
        local legacyAllDisabled =
            combat.debuffOverlayGlobalEnabled == false and
            combat.debuffOverlayPlayerEnabled == false and
            combat.debuffOverlayFocusEnabled == false and
            combat.debuffOverlayPartyEnabled == false and
            combat.debuffOverlayRaidEnabled == false and
            combat.debuffOverlayTargetOfTargetEnabled == false
        local legacyGlobalOnlyDisabled =
            combat.debuffOverlayGlobalEnabled == false and
            combat.debuffOverlayPlayerEnabled ~= false and
            combat.debuffOverlayFocusEnabled ~= false and
            combat.debuffOverlayPartyEnabled ~= false and
            combat.debuffOverlayRaidEnabled ~= false and
            combat.debuffOverlayTargetOfTargetEnabled ~= false
        if legacyAllDisabled then
            combat.debuffOverlayGlobalEnabled = true
            combat.debuffOverlayPlayerEnabled = true
            combat.debuffOverlayFocusEnabled = true
            combat.debuffOverlayPartyEnabled = true
            combat.debuffOverlayRaidEnabled = true
            combat.debuffOverlayTargetOfTargetEnabled = true
        elseif legacyGlobalOnlyDisabled then
            combat.debuffOverlayGlobalEnabled = true
        end
        combat.debuffOverlayDefaultMigrationApplied = true
    end
    for k, v in pairs(DEFAULTS.CastBars) do
        if not MidnightUISettings.CastBars[k] then MidnightUISettings.CastBars[k] = {} end
        for kk, vv in pairs(v) do if MidnightUISettings.CastBars[k][kk] == nil then MidnightUISettings.CastBars[k][kk] = vv end end
    end
    if not MidnightUISettings.XPBar then MidnightUISettings.XPBar = {} end
    if MidnightUISettings.XPBar.enabled == nil then MidnightUISettings.XPBar.enabled = true end
    if not MidnightUISettings.RepBar then MidnightUISettings.RepBar = {} end
    if MidnightUISettings.RepBar.enabled == nil then MidnightUISettings.RepBar.enabled = true end
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    for k, v in pairs(DEFAULTS.ConsumableBars) do
        if MidnightUISettings.ConsumableBars[k] == nil then MidnightUISettings.ConsumableBars[k] = v end
    end
    if not MidnightUISettings.Nameplates then MidnightUISettings.Nameplates = {} end
    if MidnightUISettings.Nameplates.enabled == nil then MidnightUISettings.Nameplates.enabled = DEFAULTS.Nameplates.enabled end
    if MidnightUISettings.Nameplates.debugPartyThreat == nil then MidnightUISettings.Nameplates.debugPartyThreat = DEFAULTS.Nameplates.debugPartyThreat end
    if MidnightUISettings.Nameplates.scale == nil then MidnightUISettings.Nameplates.scale = DEFAULTS.Nameplates.scale end
    if MidnightUISettings.Nameplates.showFactionBorder == nil then MidnightUISettings.Nameplates.showFactionBorder = DEFAULTS.Nameplates.showFactionBorder end
    if MidnightUISettings.Nameplates.targetBorder == nil then MidnightUISettings.Nameplates.targetBorder = DEFAULTS.Nameplates.targetBorder end
    if MidnightUISettings.Nameplates.targetPulse == nil then MidnightUISettings.Nameplates.targetPulse = DEFAULTS.Nameplates.targetPulse end
    if not MidnightUISettings.Nameplates.healthBar then MidnightUISettings.Nameplates.healthBar = {} end
    if not MidnightUISettings.Nameplates.threatBar then MidnightUISettings.Nameplates.threatBar = {} end
    if not MidnightUISettings.Nameplates.castBar then MidnightUISettings.Nameplates.castBar = {} end
    if not MidnightUISettings.Nameplates.target then MidnightUISettings.Nameplates.target = {} end
    if MidnightUISettings.Nameplates.target.scale == nil then MidnightUISettings.Nameplates.target.scale = DEFAULTS.Nameplates.target.scale end
    if not MidnightUISettings.Nameplates.target.healthBar then MidnightUISettings.Nameplates.target.healthBar = {} end
    if not MidnightUISettings.Nameplates.target.threatBar then MidnightUISettings.Nameplates.target.threatBar = {} end
    if not MidnightUISettings.Nameplates.target.castBar then MidnightUISettings.Nameplates.target.castBar = {} end
    for k, v in pairs(DEFAULTS.Nameplates.healthBar) do
        if MidnightUISettings.Nameplates.healthBar[k] == nil then
            MidnightUISettings.Nameplates.healthBar[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.Nameplates.threatBar) do
        if MidnightUISettings.Nameplates.threatBar[k] == nil then
            MidnightUISettings.Nameplates.threatBar[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.Nameplates.castBar) do
        if MidnightUISettings.Nameplates.castBar[k] == nil then
            MidnightUISettings.Nameplates.castBar[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.Nameplates.target.healthBar) do
        if MidnightUISettings.Nameplates.target.healthBar[k] == nil then
            MidnightUISettings.Nameplates.target.healthBar[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.Nameplates.target.threatBar) do
        if MidnightUISettings.Nameplates.target.threatBar[k] == nil then
            MidnightUISettings.Nameplates.target.threatBar[k] = v
        end
    end
    for k, v in pairs(DEFAULTS.Nameplates.target.castBar) do
        if MidnightUISettings.Nameplates.target.castBar[k] == nil then
            MidnightUISettings.Nameplates.target.castBar[k] = v
        end
    end
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    for k, v in pairs(DEFAULTS.Minimap) do
        if MidnightUISettings.Minimap[k] == nil then MidnightUISettings.Minimap[k] = v end
    end
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    for k, v in pairs(DEFAULTS.General) do
        if MidnightUISettings.General[k] == nil then MidnightUISettings.General[k] = v end
    end
    if MidnightUISettings.General.unitFrameBarStyle ~= "Gradient"
        and MidnightUISettings.General.unitFrameBarStyle ~= "Flat" then
        MidnightUISettings.General.unitFrameBarStyle = "Gradient"
    end
    -- Force cursor tooltips on (default changed from false to true)
    if MidnightUISettings.General.forceCursorTooltips == false then
        MidnightUISettings.General.forceCursorTooltips = true
    end

    local unitFrameNameScale = tonumber(MidnightUISettings.General.unitFrameNameScale)
    if not unitFrameNameScale then unitFrameNameScale = 100 end
    MidnightUISettings.General.unitFrameNameScale = math.max(50, math.min(150, math.floor(unitFrameNameScale + 0.5)))

    local unitFrameValueScale = tonumber(MidnightUISettings.General.unitFrameValueScale)
    if not unitFrameValueScale then unitFrameValueScale = 100 end
    MidnightUISettings.General.unitFrameValueScale = math.max(50, math.min(150, math.floor(unitFrameValueScale + 0.5)))

    if MidnightUISettings.General.unitFrameTextOutline ~= "NONE"
        and MidnightUISettings.General.unitFrameTextOutline ~= "OUTLINE"
        and MidnightUISettings.General.unitFrameTextOutline ~= "THICKOUTLINE" then
        MidnightUISettings.General.unitFrameTextOutline = "OUTLINE"
    end

    if MidnightUISettings.General.unitFrameHideLevelText == nil then
        MidnightUISettings.General.unitFrameHideLevelText = false
    end
    if MidnightUISettings.General.unitFrameHidePowerText == nil then
        MidnightUISettings.General.unitFrameHidePowerText = false
    end
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    for k, v in pairs(DEFAULTS.PetBar) do
        if MidnightUISettings.PetBar[k] == nil then MidnightUISettings.PetBar[k] = v end
    end
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    for k, v in pairs(DEFAULTS.StanceBar) do
        if MidnightUISettings.StanceBar[k] == nil then MidnightUISettings.StanceBar[k] = v end
    end
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    for k, v in pairs(DEFAULTS.Inventory) do
        if MidnightUISettings.Inventory[k] == nil then MidnightUISettings.Inventory[k] = v end
    end
end

-- ============================================================================
-- APPLICATION LOGIC
-- Apply* functions read MidnightUISettings and push values to live UI frames.
-- Each calls the corresponding module's _G.MidnightUI_* refresh function.
-- ============================================================================

--- ApplyMessengerSettings: Applies chat frame size/scale/font, movement-mode
--   lock/unlock for every moveable overlay, and theme refresh.
-- @note Blocks unlock while InCombatLockdown(). Calls every MidnightUI_Set*Locked
--   and MidnightUI_Apply* global to sync all modules with the locked state.
-- @calledby Settings panel controls, ApplyGlobalTheme, PLAYER_ENTERING_WORLD loader
local function ApplyMessengerSettings()
    if _G.MyMessengerFrame then
        local s = MidnightUISettings.Messenger
        if s.locked == false and InCombatLockdown and InCombatLockdown() then
            s.locked = true
            if UIErrorsFrame and UIErrorsFrame.AddMessage then
                UIErrorsFrame:AddMessage("MidnightUI: Can't unlock overlays while in combat.", 1, 0.2, 0.2)
            end
            return
        end
        local moveHud = _G.MidnightUI_MoveHUD
        local moveHudRestore = _G.MidnightUI_MoveHUDRestore
        if s.locked then
            if moveHud then moveHud:Hide() end
            if moveHudRestore then moveHudRestore:Hide() end
        else
            if not (moveHudRestore and moveHudRestore:IsShown()) then
                if moveHud then moveHud:Show() end
                if moveHudRestore then moveHudRestore:Hide() end
            end
        end
        _G.MyMessengerFrame:SetSize(s.width, s.height)
        _G.MyMessengerFrame:SetScale(s.scale or 1.0)
        if _G.MyMessengerMessageFrame and _G.MyMessengerMessageFrame.GetFont and _G.MyMessengerMessageFrame.SetFont then
            local fontPath, _, fontFlags = _G.MyMessengerMessageFrame:GetFont()
            local fontSize = math.floor(tonumber(s.fontSize) or 14)
            if fontSize < 8 then fontSize = 8 end
            if fontSize > 24 then fontSize = 24 end
            if fontPath then
                _G.MyMessengerMessageFrame:SetFont(fontPath, fontSize, fontFlags)
                _G.MyMessengerMessageFrame:SetSpacing(math.max(1, math.floor(fontSize * 0.28)))
            end
        end
        if _G.MyMessengerFrame.dragOverlay then if s.locked then _G.MyMessengerFrame.dragOverlay:Hide() else _G.MyMessengerFrame.dragOverlay:Show() end end
        if _G.MyActionBars_SetLocked then _G.MyActionBars_SetLocked(s.locked) end
        if _G.MidnightUI_SetPlayerFrameLocked then _G.MidnightUI_SetPlayerFrameLocked(s.locked) end
        if _G.MidnightUI_SetTargetFrameLocked then _G.MidnightUI_SetTargetFrameLocked(s.locked) end
        if _G.MidnightUI_SetFocusFrameLocked then _G.MidnightUI_SetFocusFrameLocked(s.locked) end
        if _G.MidnightUI_SetPetFrameLocked then _G.MidnightUI_SetPetFrameLocked(s.locked) end
        if _G.MidnightUI_SetCastBarsLocked then _G.MidnightUI_SetCastBarsLocked(s.locked) end
        if _G.MidnightUI_SetRaidFramesLocked then _G.MidnightUI_SetRaidFramesLocked(s.locked) end
        if _G.MidnightUI_SetPartyFramesLocked then _G.MidnightUI_SetPartyFramesLocked(s.locked) end
        if _G.MidnightUI_SetPartyDispelTrackingLocked then _G.MidnightUI_SetPartyDispelTrackingLocked(s.locked) end
        if _G.MidnightUI_SetMainTankFramesLocked then _G.MidnightUI_SetMainTankFramesLocked(s.locked) end
        if _G.MidnightUI_SetConsumableBarsLocked then _G.MidnightUI_SetConsumableBarsLocked(s.locked) end
        if _G.MidnightUI_SetAuraBarLocked then _G.MidnightUI_SetAuraBarLocked(s.locked) end
        if _G.MidnightUI_SetDebuffBarLocked then _G.MidnightUI_SetDebuffBarLocked(s.locked) end
        if _G.MidnightUI_SetDispelTrackingLocked then _G.MidnightUI_SetDispelTrackingLocked(s.locked) end
        if _G.MidnightUI_SetTargetAuraBarLocked then _G.MidnightUI_SetTargetAuraBarLocked(s.locked) end
        if _G.MidnightUI_SetTargetDebuffBarLocked then _G.MidnightUI_SetTargetDebuffBarLocked(s.locked) end
        if _G.MidnightUI_SetPetBarLocked then _G.MidnightUI_SetPetBarLocked(s.locked) end
        if _G.MidnightUI_SetStanceBarLocked then _G.MidnightUI_SetStanceBarLocked(s.locked) end
        if _G.MidnightUI_SetMinimapLocked then _G.MidnightUI_SetMinimapLocked(s.locked) end
        if _G.MidnightUI_SetStatusBarsLocked then _G.MidnightUI_SetStatusBarsLocked(s.locked) end
        if _G.MidnightUI_SetInterfaceMenuLocked then _G.MidnightUI_SetInterfaceMenuLocked(s.locked) end
        if _G.MidnightUI_ApplyInterfaceMenuSettings then _G.MidnightUI_ApplyInterfaceMenuSettings() end
        -- Sync overlay sizes to current settings when toggling movement mode.
        if _G.MidnightUI_Settings then
            if _G.MidnightUI_Settings.ApplyPlayerSettings then _G.MidnightUI_Settings.ApplyPlayerSettings() end
            if _G.MidnightUI_Settings.ApplyTargetSettings then _G.MidnightUI_Settings.ApplyTargetSettings() end
            if _G.MidnightUI_Settings.ApplyFocusSettings then _G.MidnightUI_Settings.ApplyFocusSettings() end
            if _G.MidnightUI_Settings.ApplyPetSettings then _G.MidnightUI_Settings.ApplyPetSettings() end
            if _G.MidnightUI_Settings.ApplyPartyFramesSettings then _G.MidnightUI_Settings.ApplyPartyFramesSettings() end
            if _G.MidnightUI_Settings.ApplyRaidFramesSettings then _G.MidnightUI_Settings.ApplyRaidFramesSettings() end
            if _G.MidnightUI_Settings.ApplyCastBarSettings then _G.MidnightUI_Settings.ApplyCastBarSettings() end
            if _G.MidnightUI_Settings.ApplyActionBarSettingsImmediate then _G.MidnightUI_Settings.ApplyActionBarSettingsImmediate() end
            if _G.MidnightUI_Settings.ApplyMinimapSettings then _G.MidnightUI_Settings.ApplyMinimapSettings() end
        end
        if _G.MidnightUI_ApplyMessengerTheme then _G.MidnightUI_ApplyMessengerTheme() end
        if _G.MyMessenger_RefreshDisplay then _G.MyMessenger_RefreshDisplay() end
    end
    if _G.MidnightUI_ApplyDefaultChatInterfaceVisibility then
        _G.MidnightUI_ApplyDefaultChatInterfaceVisibility()
    end
end

--- EnsureCastBarsSettings: Guarantees CastBars.player/target/focus sub-tables exist
--   and fills missing keys from DEFAULTS.CastBars.
-- @calledby Settings_UI.lua ApplySettingsOnShow, any cast bar slider callback
local function EnsureCastBarsSettings()
    if not MidnightUISettings.CastBars then MidnightUISettings.CastBars = {} end
    if not MidnightUISettings.CastBars.player then MidnightUISettings.CastBars.player = {} end
    if not MidnightUISettings.CastBars.target then MidnightUISettings.CastBars.target = {} end
    if not MidnightUISettings.CastBars.focus then MidnightUISettings.CastBars.focus = {} end
    if DEFAULTS and DEFAULTS.CastBars then
        for k, v in pairs(DEFAULTS.CastBars) do
            if not MidnightUISettings.CastBars[k] then MidnightUISettings.CastBars[k] = {} end
            for kk, vv in pairs(v) do
                if MidnightUISettings.CastBars[k][kk] == nil then
                    MidnightUISettings.CastBars[k][kk] = vv
                end
            end
        end
    end
end

--- EnsureNameplateSettings: Guarantees Nameplates and all nested sub-tables
--   (healthBar, threatBar, castBar, target.*) exist with defaults filled in.
local function EnsureNameplateSettings()
    if not MidnightUISettings.Nameplates then MidnightUISettings.Nameplates = {} end
    if MidnightUISettings.Nameplates.enabled == nil then MidnightUISettings.Nameplates.enabled = true end
    if MidnightUISettings.Nameplates.debugPartyThreat == nil then MidnightUISettings.Nameplates.debugPartyThreat = false end
    if MidnightUISettings.Nameplates.scale == nil then MidnightUISettings.Nameplates.scale = 100 end
    if MidnightUISettings.Nameplates.showFactionBorder == nil then MidnightUISettings.Nameplates.showFactionBorder = true end
    if MidnightUISettings.Nameplates.targetBorder == nil then MidnightUISettings.Nameplates.targetBorder = true end
    if MidnightUISettings.Nameplates.targetPulse == nil then MidnightUISettings.Nameplates.targetPulse = true end
    if not MidnightUISettings.Nameplates.healthBar then MidnightUISettings.Nameplates.healthBar = {} end
    if not MidnightUISettings.Nameplates.threatBar then MidnightUISettings.Nameplates.threatBar = {} end
    if not MidnightUISettings.Nameplates.castBar then MidnightUISettings.Nameplates.castBar = {} end
    if not MidnightUISettings.Nameplates.target then MidnightUISettings.Nameplates.target = {} end
    if MidnightUISettings.Nameplates.target.scale == nil then MidnightUISettings.Nameplates.target.scale = 100 end
    if not MidnightUISettings.Nameplates.target.healthBar then MidnightUISettings.Nameplates.target.healthBar = {} end
    if not MidnightUISettings.Nameplates.target.threatBar then MidnightUISettings.Nameplates.target.threatBar = {} end
    if not MidnightUISettings.Nameplates.target.castBar then MidnightUISettings.Nameplates.target.castBar = {} end
end

--- ApplyUnitFrameSettings: Sets scale, alpha, width, height, and visibility
--   for a named unit frame. Handles enabled/disabled toggle, UnitWatch
--   registration, and movement-mode override for conditional units.
-- @param frameName (string) - Global frame name, e.g. "MidnightUI_PlayerFrame"
-- @param settings (table) - The settings sub-table (e.g. MidnightUISettings.PlayerFrame)
-- @calledby ApplyPlayerSettings, ApplyTargetSettings, ApplyFocusSettings, ApplyPetSettings
-- @note Conditional units (Target/Focus/Pet) stay visible in move mode even without a unit.
local function ApplyUnitFrameSettings(frameName, settings)
    local frame = _G[frameName]
    if not frame then return end
    if not settings then settings = {} end
    if settings.enabled == false then
        if UnregisterUnitWatch then UnregisterUnitWatch(frame) end
        frame:Hide()
        return
    else
        local overlaysUnlocked = (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false)
        local isConditionalUnit = (frameName == "MidnightUI_TargetFrame" or frameName == "MidnightUI_FocusFrame" or frameName == "MidnightUI_PetFrame")
        if overlaysUnlocked and isConditionalUnit then
            -- Keep target/focus/pet visible in move mode, even without a unit.
            if UnregisterUnitWatch then UnregisterUnitWatch(frame) end
            frame:Show()
        else
            if RegisterUnitWatch then RegisterUnitWatch(frame) end
            if frameName == "MidnightUI_PlayerFrame" then frame:Show() end
        end
    end

    local sScale = (settings.scale or 100) / 100
    local sAlpha = settings.alpha or 0.95
    local sWidth = settings.width or frame:GetWidth()
    local sHeight = settings.height or frame:GetHeight()
    frame:SetScale(sScale); frame:SetAlpha(sAlpha); frame:SetSize(sWidth, sHeight)
    local hH = sHeight * 0.64; local pH = sHeight * 0.25
    if frame.healthBar and frame.healthBar:GetParent() then frame.healthBar:GetParent():SetHeight(hH); if frame.healthBar.shine then frame.healthBar.shine:SetHeight(hH * 0.35) end end
    if frame.powerBar and frame.powerBar:GetParent() then frame.powerBar:GetParent():SetHeight(pH) end
end

--- ApplyNameplateSettings: Delegates to Nameplates.lua refresh global.
local function ApplyNameplateSettings()
    if _G.MidnightUI_RefreshNameplates then
        _G.MidnightUI_RefreshNameplates()
    end
end

--- MidnightUI_RefreshAllUnitFrames: Refreshes every unit frame type in one call.
-- @note Global function. Called after profile import, reset, or bulk changes.
function MidnightUI_RefreshAllUnitFrames()
    if _G.MidnightUI_RefreshPlayerFrame then _G.MidnightUI_RefreshPlayerFrame() end
    if _G.MidnightUI_RefreshTargetFrame then _G.MidnightUI_RefreshTargetFrame() end
    if _G.MidnightUI_RefreshFocusFrame then _G.MidnightUI_RefreshFocusFrame() end
    if _G.MidnightUI_RefreshPartyFrames then _G.MidnightUI_RefreshPartyFrames() end
    if _G.MidnightUI_UpdateRaidVisibility then _G.MidnightUI_UpdateRaidVisibility() end
    if _G.MidnightUI_RefreshMainTankFrames then _G.MidnightUI_RefreshMainTankFrames() end
    if _G.MidnightUI_RefreshNameplates then _G.MidnightUI_RefreshNameplates() end
end
-- Thin wrappers that delegate to the relevant module's global refresh function.
local function ApplyPlayerSettings() ApplyUnitFrameSettings("MidnightUI_PlayerFrame", MidnightUISettings.PlayerFrame) end
local function ApplyTargetSettings() ApplyUnitFrameSettings("MidnightUI_TargetFrame", MidnightUISettings.TargetFrame) end
local function ApplyFocusSettings() ApplyUnitFrameSettings("MidnightUI_FocusFrame", MidnightUISettings.FocusFrame) end
local function ApplyPetSettings() ApplyUnitFrameSettings("MidnightUI_PetFrame", MidnightUISettings.PetFrame) end
local function ApplyActionBarSettings() if _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end end
--- ApplyActionBarSettingsImmediate: Prefers the immediate (non-deferred) reload path.
local function ApplyActionBarSettingsImmediate()
    if _G.MyActionBars_ReloadSettingsImmediate then
        _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then
        _G.MyActionBars_ReloadSettings()
    end
end
local function ApplyCastBarSettings() if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end end
local function ApplyMinimapSettings() if _G.MidnightUI_ApplyMinimapSettings then _G.MidnightUI_ApplyMinimapSettings() end end
local function ApplyRaidFramesSettings() if _G.MidnightUI_ApplyRaidFramesLayout then _G.MidnightUI_ApplyRaidFramesLayout() end end
--- ApplyPartyFramesSettings: Refreshes party layout, visibility, and dispel overlays.
local function ApplyPartyFramesSettings()
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
    if _G.MidnightUI_UpdatePartyVisibility then _G.MidnightUI_UpdatePartyVisibility() end
    if _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
        _G.MidnightUI_RefreshPartyDispelTrackingOverlay(false)
    end
end

--- ApplyUnitFrameBarStyle: Applies the Gradient/Flat bar style to all unit frame types.
-- @calledby ApplySharedUnitFrameAppearance, RunSharedUnitFrameAppearanceRefresh
  local function ApplyUnitFrameBarStyle()
      if _G.MidnightUI_ApplyPlayerFrameBarStyle then _G.MidnightUI_ApplyPlayerFrameBarStyle() end
      if _G.MidnightUI_ApplyTargetFrameBarStyle then _G.MidnightUI_ApplyTargetFrameBarStyle() end
      if _G.MidnightUI_ApplyFocusFrameBarStyle then _G.MidnightUI_ApplyFocusFrameBarStyle() end
      if _G.MidnightUI_ApplyPetFrameBarStyle then _G.MidnightUI_ApplyPetFrameBarStyle() end
      if _G.MidnightUI_ApplyPartyFramesBarStyle then _G.MidnightUI_ApplyPartyFramesBarStyle() end
      if _G.MidnightUI_ApplyRaidFramesBarStyle then _G.MidnightUI_ApplyRaidFramesBarStyle() end
      if _G.MidnightUI_ApplyMainTankFramesBarStyle then _G.MidnightUI_ApplyMainTankFramesBarStyle() end
  end

--- ClampUnitFrameTextScale: Clamps a percentage value to [50, 150] range.
-- @param value (number|string) - Raw value to clamp
-- @return (number) - Integer in range [50..150]
local function ClampUnitFrameTextScale(value)
    value = tonumber(value) or 100
    return math.max(50, math.min(150, math.floor(value + 0.5)))
end

--- EnsureSharedUnitAppearanceSettings: Validates General.unitFrameName/ValueScale,
--   unitFrameTextOutline, and hide flags. Clamps out-of-range values.
local function EnsureSharedUnitAppearanceSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.General then MidnightUISettings.General = {} end

    if MidnightUISettings.General.unitFrameNameScale == nil then
        MidnightUISettings.General.unitFrameNameScale = 100
    end
    if MidnightUISettings.General.unitFrameValueScale == nil then
        MidnightUISettings.General.unitFrameValueScale = 100
    end
    if MidnightUISettings.General.unitFrameTextOutline ~= "NONE"
        and MidnightUISettings.General.unitFrameTextOutline ~= "OUTLINE"
        and MidnightUISettings.General.unitFrameTextOutline ~= "THICKOUTLINE" then
        MidnightUISettings.General.unitFrameTextOutline = "OUTLINE"
    end
    if MidnightUISettings.General.unitFrameHideLevelText == nil then
        MidnightUISettings.General.unitFrameHideLevelText = false
    end
    if MidnightUISettings.General.unitFrameHidePowerText == nil then
        MidnightUISettings.General.unitFrameHidePowerText = false
    end

    MidnightUISettings.General.unitFrameNameScale = ClampUnitFrameTextScale(MidnightUISettings.General.unitFrameNameScale)
    MidnightUISettings.General.unitFrameValueScale = ClampUnitFrameTextScale(MidnightUISettings.General.unitFrameValueScale)
end

--- GetSharedUnitAppearanceSettings: Returns a snapshot table of shared text appearance.
-- @return (table) - { nameScale, valueScale, outline, showLevelText, showPowerText }
-- @calledby ApplySharedUnitTextStyle, external modules via _G.MidnightUI_GetSharedUnitAppearanceSettings
local function GetSharedUnitAppearanceSettings()
    EnsureSharedUnitAppearanceSettings()

    local outline = MidnightUISettings.General.unitFrameTextOutline
    if outline == "NONE" then
        outline = nil
    end

    return {
        nameScale = ClampUnitFrameTextScale(MidnightUISettings.General.unitFrameNameScale),
        valueScale = ClampUnitFrameTextScale(MidnightUISettings.General.unitFrameValueScale),
        outline = outline,
        showLevelText = not MidnightUISettings.General.unitFrameHideLevelText,
        showPowerText = not MidnightUISettings.General.unitFrameHidePowerText,
    }
end

--- ApplySharedTextShadow: Sets a consistent drop-shadow on any FontString.
-- @param fontString (FontString) - Target font string
-- @param alpha (number|nil) - Shadow alpha (defaults to 1)
local function ApplySharedTextShadow(fontString, alpha)
    if not fontString then return end
    alpha = tonumber(alpha)
    if alpha == nil then alpha = 1 end
    fontString:SetShadowOffset(1, -1)
    fontString:SetShadowColor(0, 0, 0, alpha)
end

--- ApplySharedUnitFont: Applies font with shared scale percentage and optional outline.
-- @param fontString (FontString) - Target font string
-- @param fontPath (string) - Font file path
-- @param baseSize (number) - Base font size before scaling
-- @param scalePercent (number) - Percentage scale (100 = no change)
-- @param outline (string|nil) - "OUTLINE", "THICKOUTLINE", or nil for none
local function ApplySharedUnitFont(fontString, fontPath, baseSize, scalePercent, outline)
    if not fontString or type(fontString.SetFont) ~= "function" then return end

    local size = math.max(6, math.floor((baseSize or 10) * (scalePercent / 100) + 0.5))
    if outline then
        fontString:SetFont(fontPath, size, outline)
    else
        fontString:SetFont(fontPath, size)
    end
end

--- ApplySharedUnitTextStyle: Applies shared name/health/level/power font styles to a unit frame.
-- @param frame (Frame) - Unit frame with .nameText, .healthText, .levelText, .powerText
-- @param options (table) - Per-element font config { nameFont, nameSize, healthFont, ... }
-- @calledby External modules via _G.MidnightUI_ApplySharedUnitTextStyle
local function ApplySharedUnitTextStyle(frame, options)
    if not frame then return end

    local shared = GetSharedUnitAppearanceSettings()
    local opts = options or {}

    if frame.nameText and opts.nameFont and opts.nameSize then
        ApplySharedUnitFont(frame.nameText, opts.nameFont, opts.nameSize, shared.nameScale, shared.outline)
        ApplySharedTextShadow(frame.nameText, opts.nameShadowAlpha)
    end

    if frame.healthText and opts.healthFont and opts.healthSize then
        ApplySharedUnitFont(frame.healthText, opts.healthFont, opts.healthSize, shared.valueScale, shared.outline)
        ApplySharedTextShadow(frame.healthText, opts.healthShadowAlpha)
    end

    if frame.levelText and opts.levelFont and opts.levelSize then
        ApplySharedUnitFont(frame.levelText, opts.levelFont, opts.levelSize, shared.valueScale, shared.outline)
        ApplySharedTextShadow(frame.levelText, opts.levelShadowAlpha)
        frame.levelText:SetAlpha(shared.showLevelText and 1 or 0)
    end

    if frame.powerText and opts.powerFont and opts.powerSize then
        ApplySharedUnitFont(frame.powerText, opts.powerFont, opts.powerSize, shared.valueScale, shared.outline)
        ApplySharedTextShadow(frame.powerText, opts.powerShadowAlpha)
        frame.powerText:SetAlpha(shared.showPowerText and 1 or 0)
    end
end

local sharedUnitAppearanceRefreshFrame
local sharedUnitAppearanceRefreshPending = false

local function RunSharedUnitFrameAppearanceRefresh()
    ApplyUnitFrameBarStyle()

    if ApplyPlayerSettings then ApplyPlayerSettings() end
    if ApplyTargetSettings then ApplyTargetSettings() end
    if ApplyFocusSettings then ApplyFocusSettings() end
    if ApplyPetSettings then ApplyPetSettings() end
    if ApplyPartyFramesSettings then ApplyPartyFramesSettings() end
    if ApplyRaidFramesSettings then ApplyRaidFramesSettings() end
end

local function EnsureUnitFrameAppearanceRefreshFrame()
    if sharedUnitAppearanceRefreshFrame then
        return sharedUnitAppearanceRefreshFrame
    end

    sharedUnitAppearanceRefreshFrame = CreateFrame("Frame")
    sharedUnitAppearanceRefreshFrame:SetScript("OnEvent", function(self, event)
        if event ~= "PLAYER_REGEN_ENABLED" or not sharedUnitAppearanceRefreshPending then
            return
        end

        sharedUnitAppearanceRefreshPending = false
        self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        RunSharedUnitFrameAppearanceRefresh()
    end)

    return sharedUnitAppearanceRefreshFrame
end

--- ApplySharedUnitFrameAppearance: Applies bar style + text style to all unit frames.
--   Defers to PLAYER_REGEN_ENABLED if called in combat.
-- @return (boolean) - true if applied immediately, false if deferred
local function ApplySharedUnitFrameAppearance()
    EnsureSharedUnitAppearanceSettings()

    if InCombatLockdown() then
        sharedUnitAppearanceRefreshPending = true
        EnsureUnitFrameAppearanceRefreshFrame():RegisterEvent("PLAYER_REGEN_ENABLED")
        return false
    end

    sharedUnitAppearanceRefreshPending = false
    if sharedUnitAppearanceRefreshFrame then
        sharedUnitAppearanceRefreshFrame:UnregisterEvent("PLAYER_REGEN_ENABLED")
    end

    RunSharedUnitFrameAppearanceRefresh()
    return true
end

_G.MidnightUI_GetSharedUnitAppearanceSettings = GetSharedUnitAppearanceSettings
_G.MidnightUI_ApplySharedUnitTextStyle = ApplySharedUnitTextStyle
_G.MidnightUI_ApplySharedUnitFrameAppearance = ApplySharedUnitFrameAppearance

-- ============================================================================
-- QUEST OBJECTIVES VISIBILITY (COMBAT FADE)
-- Fades the ObjectiveTrackerFrame in/out based on combat state and user prefs.
-- Three modes: always visible, hide in combat, always hidden.
-- ============================================================================

local QUEST_FADE_DURATION = 0.25

local function EnsureQuestObjectiveSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    if MidnightUISettings.General.useBlizzardQuestingInterface == nil then
        MidnightUISettings.General.useBlizzardQuestingInterface = false
    end
    if MidnightUISettings.General.hideQuestObjectivesInCombat == nil then
        MidnightUISettings.General.hideQuestObjectivesInCombat = false
    end
    if MidnightUISettings.General.hideQuestObjectivesAlways == nil then
        MidnightUISettings.General.hideQuestObjectivesAlways = false
    end
    if MidnightUISettings.General.debugCastBar == nil then
        MidnightUISettings.General.debugCastBar = false
    end
end

local function GetObjectiveTracker()
    return _G.ObjectiveTrackerFrame
end

local function CaptureRestoreAlpha(tracker)
    if not tracker then return end
    local current = tracker:GetAlpha() or 1
    if current and current > 0 then
        tracker.midnightRestoreAlpha = current
    elseif tracker.midnightRestoreAlpha == nil then
        tracker.midnightRestoreAlpha = 1
    end
end

local function FadeTracker(tracker, toAlpha)
    if not tracker then return end
    if not tracker:IsShown() then
        tracker:SetAlpha(toAlpha)
        return
    end

    local fromAlpha = tracker:GetAlpha() or 1
    if toAlpha <= 0 then
        UIFrameFadeOut(tracker, QUEST_FADE_DURATION, fromAlpha, 0)
    else
        UIFrameFadeIn(tracker, QUEST_FADE_DURATION, fromAlpha, toAlpha)
    end
end

local function ApplyQuestObjectiveVisibility()
    EnsureQuestObjectiveSettings()
    local tracker = GetObjectiveTracker()
    if not tracker then return end

    local hideAlways = MidnightUISettings.General.hideQuestObjectivesAlways == true
    if hideAlways then
        CaptureRestoreAlpha(tracker)
        FadeTracker(tracker, 0)
        return
    end

    local hideInCombat = MidnightUISettings.General.hideQuestObjectivesInCombat == true
    if not hideInCombat then
        local restoreAlpha = tracker.midnightRestoreAlpha or 1
        FadeTracker(tracker, restoreAlpha)
        return
    end

    local inCombat = (InCombatLockdown and InCombatLockdown()) or UnitAffectingCombat("player")
    if inCombat then
        CaptureRestoreAlpha(tracker)
        FadeTracker(tracker, 0)
    else
        local restoreAlpha = tracker.midnightRestoreAlpha or 1
        FadeTracker(tracker, restoreAlpha)
    end
end

_G.MidnightUI_ApplyQuestObjectivesVisibility = ApplyQuestObjectiveVisibility

local questListener = CreateFrame("Frame")
questListener:RegisterEvent("ADDON_LOADED")
questListener:RegisterEvent("PLAYER_ENTERING_WORLD")
questListener:RegisterEvent("PLAYER_REGEN_DISABLED")
questListener:RegisterEvent("PLAYER_REGEN_ENABLED")
questListener:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= "MidnightUI" then return end
        EnsureQuestObjectiveSettings()
        C_Timer.After(0.2, ApplyQuestObjectiveVisibility)
        return
    end

    if event == "PLAYER_ENTERING_WORLD" then
        C_Timer.After(0.2, ApplyQuestObjectiveVisibility)
        return
    end

    if event == "PLAYER_REGEN_DISABLED" or event == "PLAYER_REGEN_ENABLED" then
        ApplyQuestObjectiveVisibility()
        return
    end
end)

--- ApplyGlobalTheme: Debounced (one-frame) refresh of action bars, messenger, and minimap theme.
-- @calledby Global Style dropdown in Settings_UI.lua
local globalThemeQueued = false
local function ApplyGlobalTheme()
    if globalThemeQueued then return end
    globalThemeQueued = true
    C_Timer.After(0, function()
        globalThemeQueued = false
        ApplyActionBarSettingsImmediate()
        ApplyMessengerSettings()
        ApplyMinimapSettings()
    end)
end

-- ============================================================================
-- MOVEMENT MODE: GRID & HUD
-- When overlays are unlocked, a translucent alignment grid covers the screen
-- and a floating HUD panel shows instructions and a Lock & Save button.
-- The Overlay Manager window lets users toggle individual overlays on/off.
-- ============================================================================

local GridFrame = CreateFrame("Frame", nil, UIParent)
GridFrame:SetAllPoints(); GridFrame:SetFrameStrata("BACKGROUND"); GridFrame:Hide()

-- MOVEMENT_VISUALS: Color and spacing constants for the grid overlay and MoveHUD.
local MOVEMENT_VISUALS = {
    gridMinorStep = 40,
    gridMajorEvery = 4,
    gridMinorAlpha = 0.052,
    gridMajorAlpha = 0.140,
    gridColor = { 0.40, 0.56, 0.70 },
    gridCenter = { 0.34, 0.78, 1.00, 0.62 },
    gridDim = { 0.02, 0.03, 0.05, 0.20 },
    hudBg = { 0.04, 0.06, 0.09, 0.94 },
    hudBorder = { 0.21, 0.30, 0.39, 0.90 },
    hudHeader = { 0.08, 0.14, 0.22, 0.96 },
    hudAccent = { 0.22, 0.54, 0.72, 0.62 },
    hudInset = { 0.03, 0.07, 0.11, 0.70 },
}

--- StyleCustomButton: Applies MidnightUI button styling. Prefers the global
--   MidnightUI_StyleButton, falls back to M.StyleSettingsButton (set by Settings_UI.lua).
-- @param button (Button) - Button frame to style
local function StyleCustomButton(button)
    if not button then return end
    if _G.MidnightUI_StyleButton then
        _G.MidnightUI_StyleButton(button)
        return
    end
    if _G.MidnightUI_Settings and _G.MidnightUI_Settings.StyleSettingsButton then
        _G.MidnightUI_Settings.StyleSettingsButton(button)
        return
    end
end

--- DrawGrid: Creates the alignment grid texture lines (minor + major + center crosshair).
--   Only runs once; subsequent calls are no-ops (idempotent).
local function DrawGrid()
    if GridFrame.lines then return end
    GridFrame.lines = {}
    local width, height = UIParent:GetSize()
    local step = MOVEMENT_VISUALS.gridMinorStep
    local majorStride = step * MOVEMENT_VISUALS.gridMajorEvery
    local function CL(r, g, b, a)
        local t = GridFrame:CreateTexture(nil, "BACKGROUND")
        t:SetColorTexture(r, g, b, a)
        return t
    end

    local dim = CL(
        MOVEMENT_VISUALS.gridDim[1],
        MOVEMENT_VISUALS.gridDim[2],
        MOVEMENT_VISUALS.gridDim[3],
        MOVEMENT_VISUALS.gridDim[4]
    )
    dim:SetAllPoints()
    GridFrame.dim = dim

    for x = 0, width, step do
        local isMajor = (x % majorStride) == 0
        local alpha = isMajor and MOVEMENT_VISUALS.gridMajorAlpha or MOVEMENT_VISUALS.gridMinorAlpha
        local l = CL(
            MOVEMENT_VISUALS.gridColor[1],
            MOVEMENT_VISUALS.gridColor[2],
            MOVEMENT_VISUALS.gridColor[3],
            alpha
        )
        l:SetSize(isMajor and 2 or 1, height)
        if isMajor and l.SetBlendMode then
            l:SetBlendMode("ADD")
        end
        l:SetPoint("TOPLEFT", x, 0)
        GridFrame.lines[#GridFrame.lines + 1] = l
    end
    for y = 0, height, step do
        local isMajor = (y % majorStride) == 0
        local alpha = isMajor and MOVEMENT_VISUALS.gridMajorAlpha or MOVEMENT_VISUALS.gridMinorAlpha
        local l = CL(
            MOVEMENT_VISUALS.gridColor[1],
            MOVEMENT_VISUALS.gridColor[2],
            MOVEMENT_VISUALS.gridColor[3],
            alpha
        )
        l:SetSize(width, isMajor and 2 or 1)
        if isMajor and l.SetBlendMode then
            l:SetBlendMode("ADD")
        end
        l:SetPoint("TOPLEFT", 0, -y)
        GridFrame.lines[#GridFrame.lines + 1] = l
    end

    local vC = CL(
        MOVEMENT_VISUALS.gridCenter[1],
        MOVEMENT_VISUALS.gridCenter[2],
        MOVEMENT_VISUALS.gridCenter[3],
        MOVEMENT_VISUALS.gridCenter[4]
    )
    vC:SetSize(2, height)
    vC:SetPoint("CENTER")
    local hC = CL(
        MOVEMENT_VISUALS.gridCenter[1],
        MOVEMENT_VISUALS.gridCenter[2],
        MOVEMENT_VISUALS.gridCenter[3],
        MOVEMENT_VISUALS.gridCenter[4]
    )
    hC:SetSize(width, 2)
    hC:SetPoint("CENTER")
    GridFrame.lines[#GridFrame.lines + 1] = vC
    GridFrame.lines[#GridFrame.lines + 1] = hC
end

local MoveHUD = CreateFrame("Frame", "MidnightUI_MoveHUD", UIParent, "BackdropTemplate")
local MOVEHUD_HEADER_H = 64
MoveHUD:SetSize(520, 264); MoveHUD:SetPoint("TOP", 0, -50); MoveHUD:SetFrameStrata("TOOLTIP"); MoveHUD:SetFrameLevel(500)
MoveHUD:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
    edgeFile = "Interface\\Buttons\\WHITE8X8",
    edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 }
})
MoveHUD:SetBackdropColor(
    MOVEMENT_VISUALS.hudBg[1],
    MOVEMENT_VISUALS.hudBg[2],
    MOVEMENT_VISUALS.hudBg[3],
    MOVEMENT_VISUALS.hudBg[4]
)
MoveHUD:SetBackdropBorderColor(
    MOVEMENT_VISUALS.hudBorder[1],
    MOVEMENT_VISUALS.hudBorder[2],
    MOVEMENT_VISUALS.hudBorder[3],
    MOVEMENT_VISUALS.hudBorder[4]
)
MoveHUD:Hide()

local moveHeader = MoveHUD:CreateTexture(nil, "ARTWORK")
moveHeader:SetTexture("Interface\\Buttons\\WHITE8X8")
moveHeader:SetPoint("TOPLEFT", 1, -1)
moveHeader:SetPoint("TOPRIGHT", -1, -1)
moveHeader:SetHeight(MOVEHUD_HEADER_H)
moveHeader:SetVertexColor(
    MOVEMENT_VISUALS.hudHeader[1],
    MOVEMENT_VISUALS.hudHeader[2],
    MOVEMENT_VISUALS.hudHeader[3],
    MOVEMENT_VISUALS.hudHeader[4]
)

local moveHeaderAccent = MoveHUD:CreateTexture(nil, "ARTWORK")
moveHeaderAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
moveHeaderAccent:SetPoint("TOPLEFT", 1, -1)
moveHeaderAccent:SetPoint("TOPRIGHT", -1, -1)
moveHeaderAccent:SetHeight(2)
moveHeaderAccent:SetVertexColor(
    MOVEMENT_VISUALS.hudAccent[1],
    MOVEMENT_VISUALS.hudAccent[2],
    MOVEMENT_VISUALS.hudAccent[3],
    MOVEMENT_VISUALS.hudAccent[4]
)

local moveBodyInset = MoveHUD:CreateTexture(nil, "BACKGROUND")
moveBodyInset:SetTexture("Interface\\Buttons\\WHITE8X8")
moveBodyInset:SetPoint("TOPLEFT", 8, -(MOVEHUD_HEADER_H + 8))
moveBodyInset:SetPoint("BOTTOMRIGHT", -8, 8)
moveBodyInset:SetVertexColor(
    MOVEMENT_VISUALS.hudInset[1],
    MOVEMENT_VISUALS.hudInset[2],
    MOVEMENT_VISUALS.hudInset[3],
    MOVEMENT_VISUALS.hudInset[4]
)

local ht = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
ht:SetPoint("TOPLEFT", 14, -14)
ht:SetPoint("RIGHT", -92, 0)
ht:SetJustifyH("LEFT")
ht:SetText("Movement Mode")
ht:SetTextColor(0.94, 0.97, 1.00)
ht:SetShadowColor(0, 0, 0, 0.8)
ht:SetShadowOffset(1, -1)

local htSub = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
htSub:SetPoint("TOPLEFT", 14, -39)
htSub:SetPoint("RIGHT", -92, 0)
htSub:SetJustifyH("LEFT")
htSub:SetText("Drag overlays to reposition. Right-click overlays for per-frame options.")
htSub:SetTextColor(0.70, 0.77, 0.85)

local moveDivider = MoveHUD:CreateTexture(nil, "ARTWORK")
moveDivider:SetTexture("Interface\\Buttons\\WHITE8X8")
moveDivider:SetPoint("TOP", MoveHUD, "TOP", 0, -(MOVEHUD_HEADER_H + 16))
moveDivider:SetPoint("BOTTOM", MoveHUD, "BOTTOM", 0, 68)
moveDivider:SetWidth(1)
moveDivider:SetVertexColor(0.20, 0.27, 0.35, 0.78)

local leftInstructionBg = MoveHUD:CreateTexture(nil, "BACKGROUND")
leftInstructionBg:SetTexture("Interface\\Buttons\\WHITE8X8")
leftInstructionBg:SetPoint("TOPLEFT", 14, -(MOVEHUD_HEADER_H + 22))
leftInstructionBg:SetPoint("BOTTOMRIGHT", MoveHUD, "BOTTOM", -8, 70)
leftInstructionBg:SetVertexColor(0.05, 0.09, 0.14, 0.46)

local rightInstructionBg = MoveHUD:CreateTexture(nil, "BACKGROUND")
rightInstructionBg:SetTexture("Interface\\Buttons\\WHITE8X8")
rightInstructionBg:SetPoint("TOPLEFT", MoveHUD, "TOP", 8, -(MOVEHUD_HEADER_H + 22))
rightInstructionBg:SetPoint("BOTTOMRIGHT", -14, 70)
rightInstructionBg:SetVertexColor(0.05, 0.09, 0.14, 0.46)

-- ============================================================================
-- OVERLAY MANAGER WINDOW
-- A scrollable popup that lists every moveable overlay (grouped by category)
-- with enable/disable toggles. Accessible from the gear icon on the MoveHUD.
-- ============================================================================

local OverlayManagerFrame = nil
local OverlayManagerRows = {}

-- OVERLAY_GROUPS: Display order and labels for the Overlay Manager categories.
local OVERLAY_GROUPS = {
    { id = "unit", label = "Unit Frames" },
    { id = "cast", label = "Cast Bars" },
    { id = "auras", label = "Auras & Tracking" },
    { id = "bars", label = "Action & Utility Bars" },
    { id = "world", label = "World Frames" },
}

-- OVERLAY_DEFINITIONS: Each entry maps an overlay key to its settings path,
-- display name, apply function, and UI group. Used by the Overlay Manager
-- and by SetOverlayEnabled to toggle individual overlays.
-- Shape: { key, name, settingPath (dot-separated), applyFunc (string), group }
local OVERLAY_DEFINITIONS = {
    { key = "PlayerFrame", name = "Player Frame", settingPath = "PlayerFrame.enabled", applyFunc = "ApplyPlayerSettings", group = "unit" },
    { key = "TargetFrame", name = "Target Frame", settingPath = "TargetFrame.enabled", applyFunc = "ApplyTargetSettings", group = "unit" },
    { key = "TargetOfTarget", name = "Target of Target", settingPath = "TargetFrame.showTargetOfTarget", applyFunc = "MidnightUI_ApplyTargetOfTargetSettings", group = "unit" },
    { key = "FocusFrame", name = "Focus Frame", settingPath = "FocusFrame.enabled", applyFunc = "ApplyFocusSettings", group = "unit" },
    { key = "PetFrame", name = "Pet Frame", settingPath = "PetFrame.enabled", applyFunc = "ApplyPetSettings", group = "unit" },
    { key = "PartyFrames", name = "Party Frames", settingPath = "PartyFrames.enabled", applyFunc = "ApplyPartyFramesSettings", group = "unit" },
    { key = "RaidFrames", name = "Raid Frames", settingPath = "RaidFrames.enabled", applyFunc = "ApplyRaidFramesSettings", group = "unit" },
    { key = "MainTankFrames", name = "Main Tank Frames", settingPath = "MainTankFrames.enabled", applyFunc = "MidnightUI_ApplyMainTankSettings", group = "unit" },
    { key = "PlayerCastBar", name = "Player Cast Bar", settingPath = "CastBars.player.enabled", applyFunc = "ApplyCastBarSettings", group = "cast" },
    { key = "TargetCastBar", name = "Target Cast Bar", settingPath = "CastBars.target.enabled", applyFunc = "ApplyCastBarSettings", group = "cast" },
    { key = "FocusCastBar", name = "Focus Cast Bar", settingPath = "CastBars.focus.enabled", applyFunc = "ApplyCastBarSettings", group = "cast" },
    { key = "PlayerBuffs", name = "Player Buffs", settingPath = "PlayerFrame.auras.enabled", applyFunc = "MidnightUI_ApplyPlayerAuraSettings", group = "auras" },
    { key = "PlayerDebuffs", name = "Player Debuffs", settingPath = "PlayerFrame.debuffs.enabled", applyFunc = "MidnightUI_ApplyPlayerDebuffSettings", group = "auras" },
    { key = "TargetBuffs", name = "Target Buffs", settingPath = "TargetFrame.auras.enabled", applyFunc = "MidnightUI_ApplyTargetAuraSettings", group = "auras" },
    { key = "TargetDebuffs", name = "Target Debuffs", settingPath = "TargetFrame.debuffs.enabled", applyFunc = "MidnightUI_ApplyTargetDebuffSettings", group = "auras" },
    { key = "DispelTracking", name = "Dispel Tracking", settingPath = "Combat.dispelTrackingEnabled", applyFunc = "MidnightUI_RefreshDispelTrackingOverlay", group = "auras" },
    { key = "PartyDispelTracking", name = "Party Dispel Icons", settingPath = "Combat.partyDispelTrackingEnabled", applyFunc = "MidnightUI_RefreshPartyDispelTrackingOverlay", group = "auras" },
    { key = "ActionBar1", name = "Action Bar 1", settingPath = "ActionBars.bar1.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar2", name = "Action Bar 2", settingPath = "ActionBars.bar2.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar3", name = "Action Bar 3", settingPath = "ActionBars.bar3.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar4", name = "Action Bar 4", settingPath = "ActionBars.bar4.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar5", name = "Action Bar 5", settingPath = "ActionBars.bar5.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar6", name = "Action Bar 6", settingPath = "ActionBars.bar6.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar7", name = "Action Bar 7", settingPath = "ActionBars.bar7.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ActionBar8", name = "Action Bar 8", settingPath = "ActionBars.bar8.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "PetBar", name = "Pet Bar", settingPath = "PetBar.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "StanceBar", name = "Stance Bar", settingPath = "StanceBar.enabled", applyFunc = "MyActionBars_ReloadSettingsImmediate", group = "bars" },
    { key = "ConsumableBars", name = "Consumable Bars", settingPath = "ConsumableBars.enabled", applyFunc = "MidnightUI_ApplyConsumableBarsSettings", group = "bars" },
    { key = "Inventory", name = "Bag Bar (Inventory)", settingPath = "Inventory.enabled", applyFunc = "MidnightUI_ApplyInventorySettings", group = "bars" },
    { key = "InterfaceMenu", name = "Game Menu", settingPath = "InterfaceMenu.enabled", applyFunc = "MidnightUI_ApplyInterfaceMenuSettings", group = "bars" },
    { key = "XPBar", name = "XP Bar", settingPath = "XPBar.enabled", applyFunc = "MidnightUI_RefreshStatusBars", group = "world" },
    { key = "RepBar", name = "Reputation Bar", settingPath = "RepBar.enabled", applyFunc = "MidnightUI_RefreshStatusBars", group = "world" },
    { key = "Minimap", name = "Minimap", settingPath = "Minimap.enabled", applyFunc = "ApplyMinimapSettings", group = "world" },
    { key = "MinimapInfoPanel", name = "Info Panel", settingPath = "Minimap.infoPanelEnabled", applyFunc = "ApplyMinimapSettings", group = "world" },
    { key = "Nameplates", name = "Nameplates", settingPath = "Nameplates.enabled", applyFunc = "ApplyNameplateSettings", group = "world" },
}

--- GetOverlayEnabled: Reads a dot-separated settings path to determine if an overlay is enabled.
-- @param def (table) - OVERLAY_DEFINITIONS entry with .settingPath and optional .enabledCheck
-- @return (boolean) - true unless the resolved value is explicitly false
local function GetOverlayEnabled(def)
    local path = def.settingPath
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = MidnightUISettings
    for i, part in ipairs(parts) do
        if type(current) ~= "table" then return false end
        current = current[part]
    end
    
    if def.enabledCheck then
        return def.enabledCheck()
    end
    
    return current ~= false
end

local function OverlayManagerLog(msg)
    if _G.MidnightUI_Diagnostics
        and _G.MidnightUI_Diagnostics.LogDebugSource
        and _G.MidnightUI_Diagnostics.IsEnabled
        and _G.MidnightUI_Diagnostics.IsEnabled()
    then
        _G.MidnightUI_Diagnostics.LogDebugSource("Movement/OverlayManager", tostring(msg))
        return
    end
    if _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("[OverlayManager] " .. tostring(msg))
    end
end

--- SetOverlayEnabled: Writes the enabled state into MidnightUISettings and calls the
--   appropriate Apply* function. Handles frame show/hide for each overlay type.
-- @param def (table) - OVERLAY_DEFINITIONS entry
-- @param enabled (boolean) - New enabled state
-- @return (boolean|nil) - true on success, false if blocked by combat
-- @note Blocks in combat lockdown to avoid taint.
local function SetOverlayEnabled(def, enabled)
    if InCombatLockdown and InCombatLockdown() then
        OverlayManagerLog("Blocked in combat: " .. tostring(def and def.key))
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage("MidnightUI: Can't toggle overlay while in combat.", 1, 0.2, 0.2)
        end
        return false
    end
    local path = def.settingPath
    local parts = {}
    for part in string.gmatch(path, "[^%.]+") do
        table.insert(parts, part)
    end
    
    local current = MidnightUISettings
    for i = 1, #parts - 1 do
        local part = parts[i]
        if type(current[part]) ~= "table" then
            current[part] = {}
        end
        current = current[part]
    end
    
    current[parts[#parts]] = enabled
    
    -- Dispatch apply logic by overlay key (large switch because each overlay type
    -- has unique show/hide, refresh, and frame-existence requirements).
    local key = def.key

    if key == "PlayerFrame" then
        ApplyPlayerSettings()
        local frame = _G.MidnightUI_PlayerFrame
        if frame then
            if enabled then
                frame:Show()
            else
                frame:Hide()
            end
        end
    elseif key == "TargetFrame" then
        ApplyTargetSettings()
        local frame = _G.MidnightUI_TargetFrame
        if frame then
            if enabled and UnitExists("target") then
                frame:Show()
            elseif not enabled then
                frame:Hide()
            end
        end
    elseif key == "TargetOfTarget" then
        if _G.MidnightUI_ApplyTargetOfTargetSettings then
            _G.MidnightUI_ApplyTargetOfTargetSettings()
        end
    elseif key == "FocusFrame" then
        ApplyFocusSettings()
        local frame = _G.MidnightUI_FocusFrame
        if frame then
            if enabled and UnitExists("focus") then
                frame:Show()
            elseif not enabled then
                frame:Hide()
            end
        end
    elseif key == "PetFrame" then
        ApplyPetSettings()
        local frame = _G.MidnightUI_PetFrame
        if frame then
            if enabled and UnitExists("pet") then
                frame:Show()
            elseif not enabled then
                frame:Hide()
            end
        end
    elseif key == "PlayerCastBar" or key == "TargetCastBar" or key == "FocusCastBar" then
        ApplyCastBarSettings()
    elseif key == "PlayerBuffs" then
        if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
        -- BuffFrame is the global WoW frame
        if _G.BuffFrame then
            if enabled then _G.BuffFrame:Show() else _G.BuffFrame:Hide() end
        end
    elseif key == "PlayerDebuffs" then
        if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
        -- DebuffFrame is the global WoW frame
        if _G.DebuffFrame then
            if enabled then _G.DebuffFrame:Show() else _G.DebuffFrame:Hide() end
        end
    elseif key == "DispelTracking" then
        if _G.MidnightUI_RefreshDispelTrackingOverlay then
            _G.MidnightUI_RefreshDispelTrackingOverlay(_G.MidnightUI_PlayerFrame)
        end
        local locked = true
        if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
            locked = MidnightUISettings.Messenger.locked ~= false
        end
        if _G.MidnightUI_SetDispelTrackingLocked then
            _G.MidnightUI_SetDispelTrackingLocked(locked)
        end
    elseif key == "PartyDispelTracking" then
        if _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
            _G.MidnightUI_RefreshPartyDispelTrackingOverlay(false)
        elseif _G.MidnightUI_RefreshPartyFrames then
            _G.MidnightUI_RefreshPartyFrames()
        end
    elseif key == "TargetBuffs" then
        if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
    elseif key == "TargetDebuffs" then
        if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
    elseif key == "ConsumableBars" then
        if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
    elseif key == "Inventory" then
        if _G.MidnightUI_ApplyInventorySettings then
            _G.MidnightUI_ApplyInventorySettings()
        end
        -- Ensure visual state is immediately consistent when toggled from Overlay Manager.
        if enabled then
            if _G.CloseAllBags then _G.CloseAllBags() end
            if _G.ContainerFrameCombinedBags and _G.ContainerFrameCombinedBags.Hide then
                _G.ContainerFrameCombinedBags:Hide()
            end
            if _G.BagsBar and _G.BagsBar.Hide then
                _G.BagsBar:Hide()
            end
            if _G.MidnightDockMain and _G.MidnightDockMain.Show then
                _G.MidnightDockMain:Show()
            end
        else
            if _G.MidnightDockMain and _G.MidnightDockMain.Hide then
                _G.MidnightDockMain:Hide()
            end
            if _G.BagsBar and _G.BagsBar.Show then
                _G.BagsBar:Show()
            end
        end
    elseif key == "XPBar" or key == "RepBar" then
        if _G.MidnightUI_RefreshStatusBars then _G.MidnightUI_RefreshStatusBars() end
    elseif key == "Minimap" or key == "MinimapInfoPanel" then
        ApplyMinimapSettings()
    elseif key == "PetBar" or key == "StanceBar" then
        ApplyActionBarSettingsImmediate()
    elseif key == "Nameplates" then
        ApplyNameplateSettings()
    elseif key == "RaidFrames" then
        ApplyRaidFramesSettings()
        local anchor = _G.MidnightUI_RaidAnchor
        if anchor then
            if enabled then
                if _G.MidnightUI_UpdateRaidVisibility then _G.MidnightUI_UpdateRaidVisibility() end
            else
                anchor:Hide()
            end
        end
    elseif key == "PartyFrames" then
        ApplyPartyFramesSettings()
        local anchor = _G.MidnightUI_PartyAnchor
        if anchor then
            if enabled then
                if _G.MidnightUI_UpdatePartyVisibility then _G.MidnightUI_UpdatePartyVisibility() end
            else
                anchor:Hide()
            end
        end
    elseif key == "MainTankFrames" then
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
        local anchor = _G.MidnightUI_MainTankAnchor
        if anchor then
            if enabled then
                anchor:Show()
            else
                anchor:Hide()
            end
        end
    end
    return true
end

local function CreateOverlayManagerWindow()
    if OverlayManagerFrame then return end
    
    local UI_COLORS = {
        bg = {0.04, 0.06, 0.09},
        panel = {0.08, 0.14, 0.21},
        border = {0.18, 0.25, 0.34},
        text = {0.90, 0.94, 0.98},
        accent = {0.22, 0.54, 0.72},
        enabled = {0.46, 0.76, 0.58},
        disabled = {0.82, 0.52, 0.48},
    }
    
    local HEADER_H = 70
    local frame = CreateFrame("Frame", "MidnightUI_OverlayManagerFrame", UIParent, "BackdropTemplate")
    frame:SetSize(472, 610)
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    frame:SetFrameStrata("FULLSCREEN_DIALOG")
    frame:SetFrameLevel(600)
    table.insert(UISpecialFrames, "MidnightUI_OverlayManagerFrame")
    frame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    frame:SetBackdropColor(UI_COLORS.bg[1], UI_COLORS.bg[2], UI_COLORS.bg[3], 0.95)
    frame:SetBackdropBorderColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.95)
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
    frame:Hide()
    
    -- Header
    local headerBg = frame:CreateTexture(nil, "ARTWORK")
    headerBg:SetPoint("TOPLEFT", 1, -1)
    headerBg:SetPoint("TOPRIGHT", -1, -1)
    headerBg:SetHeight(HEADER_H)
    headerBg:SetColorTexture(UI_COLORS.panel[1], UI_COLORS.panel[2], UI_COLORS.panel[3], 0.97)
    
    local headerAccent = frame:CreateTexture(nil, "ARTWORK")
    headerAccent:SetPoint("TOPLEFT", 1, -1)
    headerAccent:SetPoint("TOPRIGHT", -1, -1)
    headerAccent:SetHeight(2)
    headerAccent:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.78)

    local headerLine = frame:CreateTexture(nil, "BACKGROUND")
    headerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerLine:SetPoint("TOPLEFT", 10, -(HEADER_H + 1))
    headerLine:SetPoint("TOPRIGHT", -10, -(HEADER_H + 1))
    headerLine:SetHeight(1)
    headerLine:SetVertexColor(UI_COLORS.border[1], UI_COLORS.border[2], UI_COLORS.border[3], 0.72)
    
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -14)
    title:SetPoint("TOPRIGHT", -162, -14)
    title:SetJustifyH("LEFT")
    title:SetText("Overlay Manager")
    title:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])

    local subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("TOPLEFT", 14, -40)
    subtitle:SetPoint("TOPRIGHT", -162, -40)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("Toggle movement overlays without leaving edit mode.")
    subtitle:SetTextColor(0.67, 0.74, 0.82)
    
    local closeBtn = CreateFrame("Button", nil, frame, "BackdropTemplate")
    closeBtn:SetSize(24, 24)
    closeBtn:SetPoint("TOPRIGHT", -10, -10)
    closeBtn:SetText("X")
    closeBtn:SetNormalFontObject("GameFontNormalSmall")
    StyleCustomButton(closeBtn)
    closeBtn:SetScript("OnClick", function() frame:Hide() end)

    local minBtnOverlayManager = CreateFrame("Button", nil, frame, "BackdropTemplate")
    minBtnOverlayManager:SetSize(24, 24)
    minBtnOverlayManager:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    minBtnOverlayManager:SetText("_")
    minBtnOverlayManager:SetNormalFontObject("GameFontNormalSmall")
    if minBtnOverlayManager.GetFontString and minBtnOverlayManager:GetFontString() then
        minBtnOverlayManager:GetFontString():SetPoint("CENTER", 0, 1)
    end
    StyleCustomButton(minBtnOverlayManager)
    minBtnOverlayManager:SetScript("OnClick", function() frame:Hide() end)

    local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusText:SetPoint("TOPRIGHT", minBtnOverlayManager, "BOTTOMRIGHT", 0, -6)
    statusText:SetTextColor(0.66, 0.74, 0.82)
    statusText:SetText("")
    frame.statusText = statusText

    local controlsBar = CreateFrame("Frame", nil, frame)
    controlsBar:SetPoint("TOPLEFT", 10, -(HEADER_H + 12))
    controlsBar:SetPoint("TOPRIGHT", -32, -(HEADER_H + 12))
    controlsBar:SetHeight(26)

    local btnEnableAll = CreateFrame("Button", nil, controlsBar, "UIPanelButtonTemplate")
    btnEnableAll:SetSize(94, 24)
    btnEnableAll:SetPoint("LEFT", 0, 0)
    btnEnableAll:SetText("Enable All")
    StyleCustomButton(btnEnableAll)

    local btnDisableAll = CreateFrame("Button", nil, controlsBar, "UIPanelButtonTemplate")
    btnDisableAll:SetSize(94, 24)
    btnDisableAll:SetPoint("LEFT", btnEnableAll, "RIGHT", 8, 0)
    btnDisableAll:SetText("Disable All")
    StyleCustomButton(btnDisableAll)

    local controlsHint = controlsBar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    controlsHint:SetPoint("LEFT", btnDisableAll, "RIGHT", 12, 0)
    controlsHint:SetPoint("RIGHT", controlsBar, "RIGHT", -2, 0)
    controlsHint:SetJustifyH("RIGHT")
    controlsHint:SetText("Tip: right-click overlays for advanced options")
    controlsHint:SetTextColor(0.60, 0.68, 0.77)
    frame.controlsHint = controlsHint
    frame.btnEnableAll = btnEnableAll
    frame.btnDisableAll = btnDisableAll
    
    local listBg = frame:CreateTexture(nil, "BACKGROUND")
    listBg:SetTexture("Interface\\Buttons\\WHITE8X8")
    listBg:SetPoint("TOPLEFT", 10, -(HEADER_H + 44))
    listBg:SetPoint("BOTTOMRIGHT", -30, 12)
    listBg:SetVertexColor(0.03, 0.05, 0.08, 0.58)

    -- Scroll frame
    local scroll = CreateFrame("ScrollFrame", nil, frame, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 10, -(HEADER_H + 44))
    scroll:SetPoint("BOTTOMRIGHT", -30, 12)
    
    local content = CreateFrame("Frame", nil, scroll)
    content:SetPoint("TOPLEFT", 0, 0)
    content:SetPoint("TOPRIGHT", 0, 0)
    content:SetHeight(1)
    scroll:SetScrollChild(content)
    
    frame.scroll = scroll
    frame.content = content

    local function SetAllOverlaysEnabled(enabled)
        if InCombatLockdown and InCombatLockdown() then
            OverlayManagerLog("Blocked bulk toggle in combat")
            if UIErrorsFrame and UIErrorsFrame.AddMessage then
                UIErrorsFrame:AddMessage("MidnightUI: Can't toggle overlays while in combat.", 1, 0.2, 0.2)
            end
            return
        end
        for _, def in ipairs(OVERLAY_DEFINITIONS) do
            SetOverlayEnabled(def, enabled)
        end
        if frame.Refresh then
            frame:Refresh()
        end
    end

    btnEnableAll:SetScript("OnClick", function()
        SetAllOverlaysEnabled(true)
    end)
    btnDisableAll:SetScript("OnClick", function()
        SetAllOverlaysEnabled(false)
    end)

    -- Refresh function
    frame.Refresh = function(self)
        for _, row in ipairs(OverlayManagerRows) do
            if row then
                row:Hide()
                row:SetParent(nil)
            end
        end
        wipe(OverlayManagerRows)

        local grouped = {}
        for _, grp in ipairs(OVERLAY_GROUPS) do
            grouped[grp.id] = {}
        end
        for _, def in ipairs(OVERLAY_DEFINITIONS) do
            local gid = def.group or "world"
            if not grouped[gid] then
                grouped[gid] = {}
            end
            grouped[gid][#grouped[gid] + 1] = def
        end

        local y = -4
        local totalEnabled = 0

        local function AddGroupHeader(labelText)
            local header = CreateFrame("Frame", nil, content)
            header:SetSize(408, 20)
            header:SetPoint("TOPLEFT", 4, y)

            local text = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            text:SetPoint("LEFT", 2, 0)
            text:SetText(labelText)
            text:SetTextColor(0.78, 0.85, 0.93)

            local line = header:CreateTexture(nil, "ARTWORK")
            line:SetTexture("Interface\\Buttons\\WHITE8X8")
            line:SetPoint("LEFT", text, "RIGHT", 8, 0)
            line:SetPoint("RIGHT", -2, 0)
            line:SetHeight(1)
            line:SetVertexColor(0.17, 0.24, 0.32, 0.82)

            header:Show()
            OverlayManagerRows[#OverlayManagerRows + 1] = header
            y = y - 22
        end

        local function AddOverlayRow(def)
            local enabled = GetOverlayEnabled(def)
            if enabled then
                totalEnabled = totalEnabled + 1
            end

            local row = CreateFrame("Frame", nil, content, "BackdropTemplate")
            row:SetSize(408, 32)
            row:SetPoint("TOPLEFT", 4, y)
            row:SetBackdrop({
                bgFile = "Interface\\Buttons\\WHITE8X8",
                edgeFile = "Interface\\Buttons\\WHITE8X8",
                edgeSize = 1,
            })
            row:SetBackdropColor(0.06, 0.09, 0.13, 0.88)
            row:SetBackdropBorderColor(0.15, 0.22, 0.30, 0.84)

            local status = row:CreateTexture(nil, "ARTWORK")
            status:SetSize(4, 20)
            status:SetPoint("LEFT", 5, 0)
            if enabled then
                status:SetColorTexture(UI_COLORS.enabled[1], UI_COLORS.enabled[2], UI_COLORS.enabled[3], 1)
            else
                status:SetColorTexture(UI_COLORS.disabled[1], UI_COLORS.disabled[2], UI_COLORS.disabled[3], 1)
            end

            local name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            name:SetPoint("LEFT", 16, 0)
            name:SetText(def.name)
            name:SetTextColor(UI_COLORS.text[1], UI_COLORS.text[2], UI_COLORS.text[3])

            local state = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            state:SetPoint("RIGHT", -88, 0)
            state:SetText(enabled and "Enabled" or "Disabled")
            if enabled then
                state:SetTextColor(UI_COLORS.enabled[1], UI_COLORS.enabled[2], UI_COLORS.enabled[3])
            else
                state:SetTextColor(UI_COLORS.disabled[1], UI_COLORS.disabled[2], UI_COLORS.disabled[3])
            end

            local toggle = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
            toggle:SetSize(76, 22)
            toggle:SetPoint("RIGHT", -6, 0)
            toggle:SetText(enabled and "Disable" or "Enable")
            toggle:SetScript("OnClick", function()
                SetOverlayEnabled(def, not GetOverlayEnabled(def))
                self:Refresh()
            end)
            StyleCustomButton(toggle)

            local hover = row:CreateTexture(nil, "ARTWORK")
            hover:SetTexture("Interface\\Buttons\\WHITE8X8")
            hover:SetPoint("TOPLEFT", 1, -1)
            hover:SetPoint("BOTTOMRIGHT", -1, 1)
            hover:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.09)
            hover:Hide()

            row:EnableMouse(true)
            row:SetScript("OnEnter", function()
                hover:Show()
            end)
            row:SetScript("OnLeave", function()
                hover:Hide()
            end)

            row:Show()
            OverlayManagerRows[#OverlayManagerRows + 1] = row
            y = y - 36
        end

        for _, grp in ipairs(OVERLAY_GROUPS) do
            local defs = grouped[grp.id]
            if defs and #defs > 0 then
                AddGroupHeader(grp.label)
                for _, def in ipairs(defs) do
                    AddOverlayRow(def)
                end
                y = y - 4
            end
        end

        local total = #OVERLAY_DEFINITIONS
        if self.statusText then
            self.statusText:SetText(string.format("%d/%d enabled", totalEnabled, total))
        end

        local totalHeight = math.max(40, math.abs(y) + 8)
        content:SetHeight(totalHeight)
        content:SetSize(408, totalHeight)
        if self.scroll and self.scroll.SetVerticalScroll then
            self.scroll:SetVerticalScroll(0)
        end
    end
    
    OverlayManagerFrame = frame
end

local function ToggleOverlayManager()
    if not OverlayManagerFrame then
        CreateOverlayManagerWindow()
    end
    
    if OverlayManagerFrame:IsShown() then
        OverlayManagerFrame:Hide()
    else
        OverlayManagerFrame:Refresh()
        OverlayManagerFrame:Show()
        OverlayManagerFrame:Raise()
    end
end

_G.MidnightUI_ToggleOverlayManager = ToggleOverlayManager

-- Gear button in Movement Mode window (high quality built-in icon)
local gearBtn = CreateFrame("Button", nil, MoveHUD)
gearBtn:SetSize(26, 26)
gearBtn:SetPoint("TOPRIGHT", -38, -8)

local gearBg = gearBtn:CreateTexture(nil, "BACKGROUND")
gearBg:SetTexture("Interface\\Buttons\\WHITE8X8")
gearBg:SetAllPoints()
gearBg:SetVertexColor(0.08, 0.13, 0.20, 0.86)

-- Use built-in WoW gear icon (high quality)
local gearNormal = gearBtn:CreateTexture(nil, "ARTWORK")
gearNormal:SetSize(18, 18)
gearNormal:SetPoint("CENTER", 0, 0)
gearNormal:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
gearNormal:SetVertexColor(0.63, 0.79, 0.92, 1.0)
gearBtn:SetNormalTexture(gearNormal)

local gearHighlight = gearBtn:CreateTexture(nil, "HIGHLIGHT")
gearHighlight:SetSize(20, 20)
gearHighlight:SetPoint("CENTER", 0, 0)
gearHighlight:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
gearHighlight:SetVertexColor(0.84, 0.93, 1.0, 0.95)
gearHighlight:SetBlendMode("ADD")
gearBtn:SetHighlightTexture(gearHighlight)

local gearPushed = gearBtn:CreateTexture(nil, "ARTWORK")
gearPushed:SetSize(16, 16)
gearPushed:SetPoint("CENTER", 1, -1)
gearPushed:SetTexture("Interface\\Icons\\INV_Misc_Gear_01")
gearPushed:SetVertexColor(0.47, 0.66, 0.82, 1.0)
gearBtn:SetPushedTexture(gearPushed)

gearBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Overlay Manager", 1, 1, 1)
    GameTooltip:AddLine("Click to manage overlay visibility by section.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("Includes quick Enable All / Disable All actions.", 0.8, 0.84, 0.90, true)
    GameTooltip:Show()
end)
gearBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
gearBtn:SetScript("OnClick", ToggleOverlayManager)

local leftHeader = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
leftHeader:SetPoint("TOP", MoveHUD, "TOP", -122, -(MOVEHUD_HEADER_H + 28))
leftHeader:SetText("Left Drag")
leftHeader:SetTextColor(0.84, 0.90, 0.98)
leftHeader:SetShadowColor(0, 0, 0, 0.7)
leftHeader:SetShadowOffset(1, -1)
leftHeader:SetWidth(180)
leftHeader:SetJustifyH("CENTER")

local leftBody = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
leftBody:SetPoint("TOP", leftHeader, "BOTTOM", 0, -10)
leftBody:SetText("Move frame overlays")
leftBody:SetTextColor(0.77, 0.84, 0.92)
leftBody:SetWidth(180)
leftBody:SetJustifyH("CENTER")

local rightHeader = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
rightHeader:SetPoint("TOP", MoveHUD, "TOP", 122, -(MOVEHUD_HEADER_H + 28))
rightHeader:SetText("Right Click")
rightHeader:SetTextColor(0.84, 0.90, 0.98)
rightHeader:SetShadowColor(0, 0, 0, 0.7)
rightHeader:SetShadowOffset(1, -1)
rightHeader:SetWidth(180)
rightHeader:SetJustifyH("CENTER")

local rightBody = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
rightBody:SetPoint("TOP", rightHeader, "BOTTOM", 0, -10)
rightBody:SetText("Open per-overlay options")
rightBody:SetTextColor(0.77, 0.84, 0.92)
rightBody:SetWidth(180)
rightBody:SetJustifyH("CENTER")

local moveHint = MoveHUD:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
moveHint:SetPoint("BOTTOM", MoveHUD, "BOTTOM", 0, 88)
moveHint:SetText("Use the gear icon to quickly enable or disable overlays.")
moveHint:SetTextColor(0.68, 0.75, 0.83)
moveHint:SetWidth(476)
moveHint:SetJustifyH("CENTER")

local hb = CreateFrame("Button", nil, MoveHUD, "UIPanelButtonTemplate")
hb:SetPoint("BOTTOM", 0, 18)
hb:SetSize(212, 34)
hb:SetText("Lock & Save")
hb:SetScript("OnClick", function()
    -- Check if movement mode was triggered from wizard FIRST
    if _G.MidnightUI_MovementModeFromWizard then
        -- Return to wizard - let the wizard handle locking and cleanup
        _G.MidnightUI_MovementModeFromWizard = false
        if _G.MidnightUI_ReturnToWelcomeWizard then
            _G.MidnightUI_ReturnToWelcomeWizard()
        end
        return
    end
    -- Normal behavior: lock and open settings panel
    MidnightUISettings.Messenger.locked = true; ApplyMessengerSettings(); GridFrame:Hide(); MoveHUD:Hide()
    if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Hide() end
    local cat = M.SettingsCategory
    if cat and Settings and Settings.OpenToCategory then Settings.OpenToCategory(cat.ID)
    elseif SettingsPanel then SettingsPanel:Show() elseif InterfaceOptionsFrame then InterfaceOptionsFrame:Show() end
end)
StyleCustomButton(hb)
if hb.GetFontString and hb:GetFontString() then hb:GetFontString():SetPoint("CENTER", 0, 0) end

local minBtn = CreateFrame("Button", nil, MoveHUD, "UIPanelButtonTemplate")
minBtn:SetSize(24, 24)
minBtn:SetPoint("TOPRIGHT", -8, -8)
minBtn:SetText("-")
StyleCustomButton(minBtn)
if minBtn.GetFontString and minBtn:GetFontString() then minBtn:GetFontString():SetPoint("CENTER", 0, 0) end
minBtn:SetScript("OnClick", function()
    MoveHUD:Hide()
    if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Show() end
end)
minBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Minimize", 1, 1, 1)
    GameTooltip:AddLine("Hide this window. Click \"Show Movement Overlay\" to bring it back.", 0.9, 0.9, 0.9, true)
    GameTooltip:Show()
end)
minBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

local MoveHUDRestore = CreateFrame("Button", "MidnightUI_MoveHUDRestore", UIParent, "UIPanelButtonTemplate")
MoveHUDRestore:SetSize(192, 28)
MoveHUDRestore:SetPoint("TOP", 0, -50)
MoveHUDRestore:SetText("Show Movement Overlay")
MoveHUDRestore:Hide()
StyleCustomButton(MoveHUDRestore)
if MoveHUDRestore.GetFontString and MoveHUDRestore:GetFontString() then
    MoveHUDRestore:GetFontString():SetPoint("CENTER", 0, 0)
end
MoveHUDRestore:SetScript("OnClick", function()
    MoveHUD:Show()
    MoveHUDRestore:Hide()
end)

M.DEFAULTS = DEFAULTS
M.SettingsCategory = MidnightSettingsCategory
M.GridFrame = GridFrame
M.MoveHUD = MoveHUD
M.DrawGrid = DrawGrid
M.ApplyMessengerSettings = ApplyMessengerSettings
M.ApplyPlayerSettings = ApplyPlayerSettings
M.ApplyTargetSettings = ApplyTargetSettings
M.ApplyFocusSettings = ApplyFocusSettings
M.ApplyPetSettings = ApplyPetSettings
M.ApplyActionBarSettings = ApplyActionBarSettings
M.ApplyActionBarSettingsImmediate = ApplyActionBarSettingsImmediate
M.ApplyCastBarSettings = ApplyCastBarSettings
M.ApplyMinimapSettings = ApplyMinimapSettings
  M.ApplyPartyFramesSettings = ApplyPartyFramesSettings
  M.ApplyRaidFramesSettings = ApplyRaidFramesSettings
M.ApplyUnitFrameBarStyle = ApplyUnitFrameBarStyle
M.ApplySharedUnitFrameAppearance = ApplySharedUnitFrameAppearance
M.ApplyNameplateSettings = ApplyNameplateSettings
M.ApplyGlobalTheme = ApplyGlobalTheme
M.EnsureCastBarsSettings = EnsureCastBarsSettings
M.EnsureNameplateSettings = EnsureNameplateSettings
M.ApplyQuestObjectiveVisibility = ApplyQuestObjectiveVisibility
M.InitializeSettings = InitializeSettings

-- ============================================================================
-- MODULE EXPORTS
-- Keybind mode is in Settings_Keybinds.lua. UI component factory and the
-- full settings panel are in Settings_UI.lua.
-- ============================================================================

-- ============================================================================
-- SLASH COMMANDS
-- /midnight or /mui opens the settings panel. Sub-commands provide debug,
-- consumable diagnostics, quest debug, taint trace, and profile tools.
-- ============================================================================

SLASH_MIDNIGHTUI1 = "/midnight"
SLASH_MIDNIGHTUI2 = "/mui"
SlashCmdList["MIDNIGHTUI"] = function(msg)
    msg = (msg and msg:lower() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if msg == "questdebug" then
        if _G.MidnightUI_QuestVisuals_Debug then
            _G.MidnightUI_QuestVisuals_Debug()
        else
            print("MidnightUI QuestVisuals Debug not available.")
        end
        return
    end
    if msg == "tainttrace" or msg == "ttrace" then
        if not MidnightUISettings.General then MidnightUISettings.General = {} end
        MidnightUISettings.General.taintTrace = not (MidnightUISettings.General.taintTrace == true)
        local state = MidnightUISettings.General.taintTrace and "ON" or "OFF"
        -- Defer logging to avoid tainting the chat editbox during slash command execution.
        if C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource
                    and _G.MidnightUI_Diagnostics.IsEnabled
                    and _G.MidnightUI_Diagnostics.IsEnabled() then
                    _G.MidnightUI_Diagnostics.LogDebugSource("SlashCmd", "Taint trace " .. state)
                elseif _G.MidnightUI_Debug then
                    _G.MidnightUI_Debug("[SlashCmd] Taint trace " .. state)
                end
            end)
        end
        return
    end
    if msg == "debugtest" then
        if _G.MidnightUI_ForceDebugMessage then
            _G.MidnightUI_ForceDebugMessage("Debug tab test")
            if _G.MyMessenger_RefreshDisplay then _G.MyMessenger_RefreshDisplay() end
            if _G.UpdateTabLayout then _G.UpdateTabLayout() end
        else
            print("MidnightUI_ForceDebugMessage missing.")
        end
        return
    end
    if msg == "partylive" then
        local launched = false
        if SlashCmdList and SlashCmdList["MUIPARTYLIVE"] then
            SlashCmdList["MUIPARTYLIVE"]("")
            launched = true
        elseif _G.MidnightUI_StartPartyDebuffOverlayLivePreview then
            local okLive = pcall(_G.MidnightUI_StartPartyDebuffOverlayLivePreview)
            launched = okLive
        end
        if not launched and C_Timer and C_Timer.After then
            C_Timer.After(0, function()
                if SlashCmdList and SlashCmdList["MUIPARTYLIVE"] then
                    SlashCmdList["MUIPARTYLIVE"]("")
                    return
                end
                if _G.MidnightUI_StartPartyDebuffOverlayLivePreview then
                    pcall(_G.MidnightUI_StartPartyDebuffOverlayLivePreview)
                    return
                end
                if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
                    _G.MidnightUI_Diagnostics.LogDebugSource("Settings", "party live preview command is not loaded yet")
                else
                    print("MidnightUI party live preview command is not loaded yet.")
                end
            end)
        elseif not launched then
            if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
                _G.MidnightUI_Diagnostics.LogDebugSource("Settings", "party live preview command is not loaded yet")
            else
                print("MidnightUI party live preview command is not loaded yet.")
            end
        end
        return
    end
    local debugAction = msg:match("^debug%s+(%S+)$")
    if debugAction then
        local function SlashOut(text)
            if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
                _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r " .. tostring(text))
            else
                print("MidnightUI: " .. tostring(text))
            end
        end
        if not MidnightUISettings.General then MidnightUISettings.General = {} end
        local current = (MidnightUISettings.General.diagnosticsEnabled ~= false)
        local nextState = current
        if debugAction == "on" or debugAction == "enable" then
            nextState = true
        elseif debugAction == "off" or debugAction == "disable" then
            nextState = false
        elseif debugAction == "toggle" then
            nextState = not current
        elseif debugAction == "status" then
            SlashOut("Diagnostics debug is " .. (current and "ON" or "OFF") .. ". Use /mui debug on|off|toggle.")
            return
        else
            SlashOut("Usage: /mui debug on | /mui debug off | /mui debug toggle | /mui debug status")
            return
        end
        MidnightUISettings.General.diagnosticsEnabled = nextState
        local statusText = nextState and "ON" or "OFF"
        if nextState and _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
            _G.MidnightUI_Diagnostics.LogDebugSource("SlashCmd", "Diagnostics debug toggled " .. statusText .. " via /mui")
        end
        SlashOut("Diagnostics debug is now " .. statusText .. ".")
        return
    end
    local cdebugAction = msg:match("^cdebug%s*(%S*)$") or msg:match("^consumabledebug%s*(%S*)$")
    if cdebugAction then
        local function SlashOut(text)
            if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
                _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r " .. tostring(text))
            else
                print("MidnightUI: " .. tostring(text))
            end
        end
        if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
        local current = (MidnightUISettings.ConsumableBars.debug == true)
        local verbose = (MidnightUISettings.ConsumableBars.debugVerbose == true)
        local action = cdebugAction
        if action == "" then action = "toggle" end
        if action == "verbose" or action == "v" then
            MidnightUISettings.ConsumableBars.debugVerbose = not verbose
            SlashOut("Consumables debug verbose is now " .. (MidnightUISettings.ConsumableBars.debugVerbose and "ON" or "OFF") .. ".")
            return
        end
        local nextState = current
        if action == "on" or action == "enable" then
            nextState = true
        elseif action == "off" or action == "disable" then
            nextState = false
        elseif action == "toggle" then
            nextState = not current
        elseif action == "status" then
            SlashOut("Consumables debug is " .. (current and "ON" or "OFF") .. ". Verbose=" .. (verbose and "ON" or "OFF") .. ". Use /mui cdebug on|off|toggle|status|verbose.")
            return
        else
            SlashOut("Usage: /mui cdebug on | /mui cdebug off | /mui cdebug toggle | /mui cdebug status | /mui cdebug verbose")
            return
        end
        MidnightUISettings.ConsumableBars.debug = nextState
        local statusText = nextState and "ON" or "OFF"
        if nextState and _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
            _G.MidnightUI_Diagnostics.LogDebugSource("SlashCmd", "Consumables debug toggled " .. statusText .. " via /mui")
        end
        SlashOut("Consumables debug is now " .. statusText .. ".")
        return
    end
    if msg == "debug" then
        if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.Open then
            local ok = _G.MidnightUI_Diagnostics.Open()
            if ok == false and _G.MidnightUI_ShowDiagnosticsStatus then
                _G.MidnightUI_ShowDiagnosticsStatus("Diagnostics failed to open")
            end
        else
            if _G.MidnightUI_ShowDiagnosticsStatus then
                _G.MidnightUI_ShowDiagnosticsStatus("Diagnostics API missing")
            else
                print("MidnightUI Diagnostics not available.")
            end
        end
        return
    end
    if msg == "consumableshow" or msg == "cshow" then
        if _G.MidnightUI_ForceShowConsumableOverlay then
            _G.MidnightUI_ForceShowConsumableOverlay()
            if _G.MidnightUI_LogDebug then _G.MidnightUI_LogDebug("Consumables overlay forced show") end
        else
            print("Consumables overlay not available.")
        end
        return
    end
    if msg == "cdump" or msg == "consumabledump" then
        if _G.MidnightUI_Consumables_DumpAuras then
            _G.MidnightUI_Consumables_DumpAuras(60)
        else
            print("Consumables dump not available.")
        end
        return
    end
    if msg == "cstatus" or msg == "consumablestatus" then
        if _G.MidnightUI_Consumables_DebugStatus then
            _G.MidnightUI_Consumables_DebugStatus()
        else
            print("Consumables debug status not available.")
        end
        return
    end
    if msg == "consumablesreset" or msg == "creset" then
        if _G.MidnightUI_ResetConsumablePosition then
            _G.MidnightUI_ResetConsumablePosition()
            if _G.MidnightUI_LogDebug then _G.MidnightUI_LogDebug("Consumables position reset") end
        else
            print("Consumables overlay not available.")
        end
        return
    end
    local cat = M.SettingsCategory
    if Settings and Settings.OpenToCategory and cat then
        Settings.OpenToCategory(cat.ID)
    elseif M.ConfigFrame and InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(M.ConfigFrame)
        InterfaceOptionsFrame_OpenToCategory(M.ConfigFrame)
    end
end

-- ============================================================================
-- GLOBAL API FUNCTIONS
-- Simple accessors for other modules that need settings data without
-- directly reading MidnightUISettings.
-- ============================================================================

--- MidnightUI_GetActionBarSettings: Returns the ActionBars settings sub-table.
-- @return (table) - MidnightUISettings.ActionBars
function MidnightUI_GetActionBarSettings()
    return MidnightUISettings.ActionBars
end

--- MidnightUI_SetActionBarSetting: Merges partial settings into a specific bar key.
-- @param barKey (string) - e.g. "bar1".."bar8"
-- @param settings (table) - Key-value pairs to merge
function MidnightUI_SetActionBarSetting(barKey, settings)
    if MidnightUISettings.ActionBars[barKey] then
        for k, v in pairs(settings) do
            MidnightUISettings.ActionBars[barKey][k] = v
        end
    end
end

function MidnightUI_GetMessengerSettings()
    return MidnightUISettings.Messenger
end

function MidnightUI_SetMessengerSetting(key, value)
    if not MidnightUISettings or not MidnightUISettings.Messenger then return end
    MidnightUISettings.Messenger[key] = value
end

-- ============================================================================
-- BOOTSTRAP LOADER
-- On ADDON_LOADED: runs InitializeSettings and forces locked state.
-- On first PLAYER_ENTERING_WORLD: applies all settings with a 0.2s delay
-- to ensure other modules have finished creating their frames.
-- ============================================================================
local loader = CreateFrame("Frame")
loader:RegisterEvent("ADDON_LOADED")
loader:RegisterEvent("PLAYER_ENTERING_WORLD")
local settingsApplied = false
loader:SetScript("OnEvent", function(s, e, a)
    if e == "ADDON_LOADED" and a == "MidnightUI" then 
        InitializeSettings()
        -- Always relock on UI reload/login to prevent staying in move mode.
        MidnightUISettings.Messenger.locked = true
        return
    end
    if e == "PLAYER_ENTERING_WORLD" and not settingsApplied then
        settingsApplied = true
        local wasReset = MidnightUISettings._wasReset
        MidnightUISettings._wasReset = nil
        C_Timer.After(0.2, function()
            ApplyMessengerSettings()
            ApplyPlayerSettings()
            ApplyTargetSettings()
            ApplyCastBarSettings()
            if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
            ApplyNameplateSettings()
            -- Only force-apply all overlay positions after a reset (not on normal reload)
            if wasReset then
                if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
                if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
                if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
                if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
                if _G.MyActionBars_ResetToDefaults then _G.MyActionBars_ResetToDefaults() end
            end
        end)
        if wasReset then
            -- Second pass for late-loading frames (only after reset)
            C_Timer.After(1.5, function()
                if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
                if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
                if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
                if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
                if _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
                -- Force Messenger position (only after reset)
                local msgFrame = _G.MyMessengerFrame
                local msgPos = MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.position
                if msgFrame and msgPos and #msgPos >= 4 then
                    msgFrame:ClearAllPoints()
                    msgFrame:SetPoint(msgPos[1], UIParent, msgPos[2], msgPos[3], msgPos[4])
                end
                local raidPos = MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.position
                local raidAnchor = _G.MidnightUI_RaidAnchor
                if raidAnchor and raidPos and #raidPos >= 4 then
                    raidAnchor:ClearAllPoints()
                    if raidPos[5] then
                        raidAnchor:SetPoint(raidPos[1], UIParent, raidPos[3], raidPos[4], raidPos[5])
                    else
                        raidAnchor:SetPoint(raidPos[1], UIParent, raidPos[2], raidPos[3], raidPos[4])
                    end
                end
            end)
        end
    end
end)
