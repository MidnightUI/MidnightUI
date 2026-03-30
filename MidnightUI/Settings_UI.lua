--------------------------------------------------------------------------------
-- Settings_UI.lua | MidnightUI
-- PURPOSE: Builds the entire MidnightUI settings panel registered with WoW's
--          Settings.RegisterCanvasLayoutCategory. Contains the component factory
--          (sliders, dropdowns, toggles, section headers, cards, scroll pages),
--          sidebar navigation, sub-tab system, and every settings page:
--          General, Player, Target, Party, Raid, Combat, Action Bars, Tools, About.
-- DEPENDS ON: Settings.lua (MidnightUI_Settings, MidnightUISettings, DEFAULTS,
--             all Apply*/Ensure*/Draw* functions exposed on M)
-- EXPORTS:
--   M.ConfigFrame           - The root settings frame
--   M.ShowPage(id)          - Programmatic page navigation
--   M.StyleSettingsButton   - Button styling function (used addon-wide)
--   M.SettingsCategory      - Blizzard Settings category handle
--   M.UpdMarket, M.UpdActControls, M.ApplyNameplateUIValues, M.SelBar
--   M.EnsureCombatDebuffOverlaySettings, M.RefreshPlayerDebuffOverlayFromSettings
--   M.RefreshCombatDebuffOverlayScope, M.QueueCombatDebuffsReflow
--   _G.MidnightUI_Tooltips  - TOOLTIP_LABELS table for external tooltip lookups
-- ARCHITECTURE: Loaded after Settings.lua and Settings_Keybinds.lua.
--   BuildSettingsUI() constructs all frames at load time (not deferred).
--   ConfigFrame:OnShow calls ApplySettingsOnShow to sync all controls with
--   current MidnightUISettings values. Apply* functions accessed via M.* to
--   stay under the Lua 200-local limit.
--------------------------------------------------------------------------------

local M = MidnightUI_Settings
local SettingsControls = M.Controls
local DEFAULTS = M.DEFAULTS
-- Apply*/Ensure*/Draw* functions accessed via M.X to stay under the 200 local limit.
local MidnightSettingsCategory = nil

-- ============================================================================
-- THEME CONSTANTS
-- UI_COLORS defines the entire color palette for the settings panel.
-- Organized by surface depth, borders, accents, text hierarchy, and navigation.
-- Legacy aliases at the bottom prevent breakage from older code paths.
-- ============================================================================

local UI_COLORS = {
    panelBg      = {0.035, 0.042, 0.070},       -- deepest background
    sidebarBg    = {0.028, 0.034, 0.062},        -- sidebar darker than panel
    contentBg    = {0.055, 0.065, 0.105},         -- content area
    headerBg     = {0.040, 0.050, 0.085},         -- header band
    cardBg       = {0.070, 0.085, 0.135, 0.90},   -- card surface
    cardBgHover  = {0.085, 0.105, 0.160, 0.95},   -- card hover
    inputBg      = {0.050, 0.060, 0.100},         -- input fields

    -- Borders & lines
    borderSubtle = {0.12, 0.15, 0.22, 0.60},     -- very subtle borders
    borderMedium = {0.16, 0.20, 0.30, 0.80},     -- medium emphasis
    borderStrong = {0.22, 0.28, 0.40, 0.95},     -- high emphasis
    separator    = {0.10, 0.13, 0.20, 0.80},     -- section dividers

    -- Accent palette
    accent       = {0.00, 0.78, 1.00},            -- primary blue
    accentGlow   = {0.00, 0.60, 0.90, 0.15},      -- soft glow behind accent items
    accentDim    = {0.00, 0.45, 0.62},             -- dimmed accent
    accentBright = {0.30, 0.88, 1.00},             -- highlighted accent

    -- Text hierarchy
    textPrimary  = {0.94, 0.95, 0.98},            -- headings & labels
    textSecondary= {0.65, 0.68, 0.75},            -- descriptions
    textMuted    = {0.42, 0.45, 0.55},            -- hints & disabled
    textAccent   = {0.40, 0.85, 1.00},            -- accent-colored text (values)

    -- Sidebar navigation
    navIdle      = {0.035, 0.042, 0.070, 0},      -- transparent idle
    navHover     = {0.06, 0.10, 0.17, 0.65},      -- subtle hover fill
    navActive    = {0.05, 0.12, 0.20, 0.85},      -- active page fill
    navActiveMark= {0.00, 0.78, 1.00, 0.95},      -- left accent bar on active

    -- Legacy aliases (so old code doesn't break)
    chatBg       = {0.055, 0.065, 0.105},
    tabBg        = {0.028, 0.034, 0.062},
    subTabBg     = {0.08, 0.15, 0.24},
    subTabHover  = {0.10, 0.20, 0.32},
    subTabActive = {0.12, 0.24, 0.38},
    cardBorder   = {0.16, 0.20, 0.30},
    cardBgFlat   = {0.070, 0.085, 0.135},
    cardBorderClean = {0.12, 0.15, 0.22, 0.60},
    sidebarHover = {0.06, 0.10, 0.17},
    sidebarActive= {0.05, 0.12, 0.20, 0.85},
    glowAccent   = {0.00, 0.60, 0.90, 0.15},
    sectionAccent= {0.00, 0.78, 1.00, 0.55},
}

-- ============================================================================
-- ABOUT PAGE URLS & DATA
-- ============================================================================
local ABOUT_PATREON_URL = "https://patreon.com/MidnightUI?utm_medium=unknown&utm_source=join_link&utm_campaign=creatorshare_creator&utm_content=copyLink"
local ABOUT_DISCORD_URL = "https://discord.gg/3AV6yUaYQ9"
local ABOUT_MPI_URL = "https://mpi.atyzi.com"
local ABOUT_CURSEFORGE_URL = "https://www.curseforge.com/wow/addons/midnightui-midnight-ready"
local ABOUT_SUPPORTERS = {
    -- Keep this list alphabetical as supporters are added.
    -- "Supporter Name",
}

-- TOOLTIP_TEXTS: Hover tooltip text for slider/dropdown control cards, keyed by card title.
-- Looked up in CreateControlCard to auto-attach tooltips.
local TOOLTIP_TEXTS = {
    ["Global UI Theme"] = "Applies a theme to major MidnightUI elements like chat, action bars, and info bars.",
    ["Unit Frame Bar Style"] = "Changes the visual style of your Player/Target/Focus/Party/Raid health and power bars.",
    ["Unit Frame Name Scale %"] = "Sets a shared font scale for unit names across Player, Target, Focus, Party, Raid, and Main Tank frames.",
    ["Unit Frame Value Scale %"] = "Sets a shared font scale for health, level, and power values across MidnightUI unit frames.",
    ["Unit Frame Text Outline"] = "Applies one outline style to the text on all MidnightUI unit frames.",
    ["Show Unit Frame Level Text"] = "Toggles level text on MidnightUI unit frames that support it.",
    ["Show Unit Frame Power Text"] = "Toggles power text on MidnightUI unit frames that support it.",
    ["Chat Style"] = "Changes the look of the chat frame and message styling.",
    ["Info Bar Style"] = "Changes the style of the minimap info bar.",
    ["Background Opacity"] = "Adjusts how transparent the chat background is.",
    ["Width"] = "Adjusts the width of this element.",
    ["Height"] = "Adjusts the height of this element.",
    ["Scale %"] = "Scales this element up or down.",
    ["Opacity"] = "Adjusts how transparent this element is.",
    ["Alignment"] = "Changes where the icons grow from (for example TOPRIGHT vs BOTTOMLEFT).",
    ["Max Shown"] = "Maximum number of icons shown in this bar.",
    ["Dispel Tracking Icon Size %"] = "Adjusts icon size for the player dispel tracking overlay.",
    ["Dispel Tracking Orientation"] = "Arranges dispel icons horizontally or vertically.",
    ["Party Dispel Icon Size %"] = "Adjusts icon size for party dispel icon overlays.",
    ["Filter Mode"] = "Choose which debuffs to display.",
    ["Health Width"] = "Adjusts the width of the nameplate health bar.",
    ["Health Height"] = "Adjusts the height of the nameplate health bar.",
    ["Health Opacity"] = "Adjusts the transparency of the nameplate health bar.",
    ["Non-Target Opacity"] = "Adjusts health bar opacity for nameplates that are not your current target.",
    ["Name Font"] = "Adjusts the name text size on nameplates.",
    ["HP% Font"] = "Adjusts the health percentage text size on nameplates.",
    ["Nameplate Scale %"] = "Scales all visible MidnightUI nameplates.",
    ["Health % Display"] = "Choose where health percentage appears on the nameplate or hide it.",
    ["Name Alignment"] = "Choose how the name text is aligned on the nameplate.",
    ["Threat Width"] = "Adjusts the width of the threat bar.",
    ["Threat Height"] = "Adjusts the height of the threat bar.",
    ["Threat Opacity"] = "Adjusts the transparency of the threat bar.",
    ["Cast Width"] = "Adjusts the width of the cast bar.",
    ["Cast Height"] = "Adjusts the height of the cast bar.",
    ["Cast Font"] = "Adjusts the cast bar text size.",
    ["Cast Opacity"] = "Adjusts the transparency of the cast bar.",
    ["Hide In Raid"] = "Hides party frames while you are in a raid group.",
    ["Hide 2D Portrait"] = "Hides the portrait area on party frames in Rendered and Simple styles.",
    ["Global Style Override"] = "Sets a global action bar style for all bars.",
    ["Per-Bar Style"] = "Overrides the style for the selected action bar only.",
    ["Rows"] = "Number of rows for the selected action bar.",
    ["Icons Per Row"] = "How many buttons are in each row.",
    ["Button Spacing"] = "Space between action bar buttons.",
    ["Button Size"] = "Adjusts the size of the bar's buttons.",
    ["Per Row"] = "How many buttons appear per row.",
    ["Spacing"] = "Space between buttons.",
    ["Player Scale %"] = "Scales the player cast bar.",
    ["Player Width"] = "Changes the player cast bar width.",
    ["Player Height"] = "Changes the player cast bar height.",
    ["Player Y Offset"] = "Moves the player cast bar up or down relative to the frame.",
    ["Target Scale %"] = "Scales the target cast bar.",
    ["Target Width"] = "Changes the target cast bar width.",
    ["Target Height"] = "Changes the target cast bar height.",
    ["Target Y Offset"] = "Moves the target cast bar up or down relative to the frame.",
    ["Focus Scale %"] = "Scales the focus cast bar.",
    ["Focus Width"] = "Changes the focus cast bar width.",
    ["Focus Height"] = "Changes the focus cast bar height.",
    ["Focus Y Offset"] = "Moves the focus cast bar up or down relative to the frame.",
    ["Global Style Override"] = "Sets a global action bar style for all bars.",
    ["Keyword Watchlist"] = "Add keywords to highlight in market listings.",
}

-- TOOLTIP_LABELS: Hover tooltip text for checkboxes and buttons, keyed by label text.
-- AutoAttachTooltips walks the frame tree and attaches these automatically.
local TOOLTIP_LABELS = {
    ["Unlock & Move UI"] = "Unlocks the UI so you can drag frames to new positions.",
    ["Edit Keybinds"] = "Enters keybind mode to bind action buttons.",
    ["Reset All Defaults"] = "Resets this profile to MidnightUI defaults, then reloads your game and reopens the Welcome wizard.",
    ["Hide Quest Objectives in Combat"] = "Fades the quest tracker while you are in combat.",
    ["Always Hide Quest Objectives"] = "Hides the quest tracker at all times.",
    ["Use Default Super Tracked Icon"] = "Use Blizzard's default Super Tracked icon.",
    ["Show Timestamps"] = "Shows timestamps in chat messages.",
  ["Opt Out of Global Tab"] = "Hides the Global chat tab in MidnightUI chat.",
  ["Opt Out of Login States"] = "Hides 'has come online' / 'has gone offline' system spam.",
  ["Use Custom Tooltips"] = "Enables MidnightUI tooltips for units and items.",
  ["Force Cursor Tooltips"] = "Forces all tooltips to appear at your cursor location.",
  ["Log UI Errors in Debug"] = "Sends UI error messages to the Debug tab.",
  ["Show Coordinates"] = "Shows your map coordinates near the minimap.",
    ["Use Custom XP/Rep Bars"] = "Use MidnightUI XP/Rep bars under the minimap info bar.",
    ["Enable Player Frame"] = "Toggles the custom Player unit frame.",
    ["Custom Tooltip"] = "Use MidnightUI tooltips for this frame.",
    ["Show Buff Bar"] = "Toggles the buff bar for this frame.",
    ["Show Debuff Bar"] = "Toggles the debuff bar for this frame.",
    ["Enable Target Frame"] = "Toggles the custom Target unit frame.",
    ["Show Target Buff Bar"] = "Toggles the Target buff bar.",
    ["Show Target Debuff Bar"] = "Toggles the Target debuff bar.",
    ["Enable Focus Frame"] = "Toggles the custom Focus unit frame.",
    ["Lock To 5-Player Groups"] = "Locks layout to 5-player groups. Each group starts a new row.",
    ["Colorize Frame Edges By Group"] = "Adds colored left/right edges to each raid frame based on its group.",
    ["Show Group Brackets (Overlay)"] = "Shows colored left/right brackets around each raid group block in the overlay.",
    ["Show Health %"] = "Toggles health percentage text on raid frames.",
    ["Text Size"] = "Adjusts raid frame name/health text size.",
    ["Units Per Row"] = "Max frames per row. Auto-clamped to screen space.",
    ["Raid Frame Width"] = "Adjusts the width of each raid frame.",
    ["Raid Frame Height"] = "Adjusts the height of each raid frame.",
    ["Styling:"] = "Rendered: standard bars. Simple: flat class-color blocks with centered names.",
    ["Party Layout"] = "Vertical stacks party frames top-to-bottom; Horizontal stacks left-to-right.",
    ["Party Styling"] = "Rendered: standard party frame bars. Simple: flat class-color bars with centered names. Square: compact class-colored squares with portraits.",
    ["Diameter"] = "Sets the size of square party frames.",
    ["Show Tooltip"] = "Shows the unit tooltip when hovering over the Party role icon.",
    ["Hide 2D Portrait"] = "Hides the portrait area on party frames in Rendered and Simple styles.",
    ["Horizontal Spacing"] = "Space between frames left-to-right.",
    ["Vertical Spacing"] = "Space between rows within the same group.",
    ["Dispel Tracking Icon Size %"] = "Adjusts icon size for the player dispel tracking overlay.",
    ["Enable Party Dispel Icon Overlay"] = "Shows a tracked debuff icon beside each party frame.",
    ["Party Dispel Icon Size %"] = "Adjusts icon size for party dispel icon overlays.",
    ["Player Glow Border"] = "Shows a coloured border around your player frame when harmful debuffs are active.",
    ["Enable All Debuff Overlays"] = "Master switch for all debuff overlay visuals across Player, Focus, Party, Raid, and Target of Target.",
    ["Player Debuff Overlay"] = "Enables debuff overlay visuals on the Player Frame.",
    ["Focus Debuff Overlay"] = "Enables debuff overlay visuals on the Focus Frame.",
    ["Party Debuff Overlay"] = "Enables debuff overlay visuals on Party Frames.",
    ["Raid Debuff Overlay"] = "Enables debuff overlay visuals on Raid Frames.",
    ["Target of Target Debuff Overlay"] = "Enables debuff overlay visuals on the Target of Target frame.",
    ["Enable Tracking Overlay"] = "Shows dispel-tracking icons on your player frame.",
    ["Party Tracking Icons"] = "Shows dispel-tracking icons beside party frames.",
    ["Background Opacity"] = "Controls chat background opacity.",
    ["Width"] = "Adjusts the width.",
    ["Height"] = "Adjusts the height.",
    ["Opacity"] = "Adjusts transparency.",
    ["Scale %"] = "Adjusts scale.",
    ["Icon Size %"] = "Adjusts the icon size for this overlay.",
    ["Rows"] = "Number of rows.",
    ["Icons Per Row"] = "Number of buttons per row.",
    ["Button Size"] = "Adjusts button size.",
    ["Spacing"] = "Spacing between buttons.",
    ["Per Row"] = "Number of buttons per row.",
    ["Enable"] = "Toggles this feature on or off.",
    ["Enable MidnightUI Nameplates"] = "Turns MidnightUI nameplates on or off.",
    ["Show Faction Border"] = "Shows blue/red faction borders on player nameplates.",
    ["Show Selected Border"] = "Toggles the static selected-target border on nameplates.",
    ["Enable Target Pulse"] = "Toggles the animated pulse effect on your current target's nameplate.",
    ["Enable Threat Bar"] = "Shows a threat bar under nameplates.",
    ["Enable This Bar"] = "Turns the selected action bar on or off.",
    ["Enable Pet Bar"] = "Toggles the pet action bar.",
    ["Enable Stance Bar"] = "Toggles the stance bar.",
    ["Add Keyword"] = "Adds this keyword to the Market watchlist.",
    ["Keep Debug Hidden"] = "Keeps the Debug tab hidden even when diagnostics are available.",
    ["Match Frame Width"] = "Keeps the cast bar width synced to its unit frame.",
    ["Separate Inventory Bags"] = "Shows each bag separately instead of combining them into one large bag.",
}

--- AttachTooltip: Hooks OnEnter/OnLeave to show a GameTooltip on any control.
-- @param control (Frame) - Frame to attach tooltip to
-- @param text (string) - Tooltip body text
local function AttachTooltip(control, text)
    if not control or not text then return end
    control:HookScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1)
        if GameTooltip.SetWrapTextInTooltip then
            GameTooltip:SetWrapTextInTooltip(true)
        end
        GameTooltip:Show()
    end)
    control:HookScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
end

--- AutoAttachTooltips: Recursively walks a frame's children and attaches TOOLTIP_LABELS
--   tooltips to any child whose text matches a known label key.
-- @param root (Frame) - Root frame to start walking from
local function AutoAttachTooltips(root)
    if not root or not root.GetChildren then return end
    local children = { root:GetChildren() }
    for _, child in ipairs(children) do
        local label = nil
        if child.GetText then
            local ok, t = pcall(child.GetText, child)
            if ok and t and t ~= "" then label = t end
        end
        if not label and child.Text and child.Text.GetText then
            local ok, t = pcall(child.Text.GetText, child.Text)
            if ok and t and t ~= "" then label = t end
        end
        if label and TOOLTIP_LABELS[label] then
            AttachTooltip(child, TOOLTIP_LABELS[label])
        end
        AutoAttachTooltips(child)
    end
end

-- Layout dimensions used by the component factory and LayoutCardsTwoColumn.
local CARD_HEIGHT   = 62
local ROW_GAP       = 78
local SLIDER_INSET  = 14
local COL_GAP       = 14
local PAGE_INSET_X  = 20
local SUBTAB_HEIGHT = 26

-- ============================================================================
-- COMPONENT FACTORY
-- Reusable UI building blocks for the settings panel. Every settings page
-- is built from combinations of these components.
-- ============================================================================

--- CreateSectionHeader: Creates a section divider with accent bar, title, and horizontal rule.
-- @param parent (Frame) - Parent frame
-- @param text (string) - Section title
-- @return (Frame) - Header frame with .SetText method and .line/.bar textures
local function CreateSectionHeader(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(420, 38)

    -- Full-width background band
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetPoint("TOPLEFT", 0, 0)
    bg:SetPoint("TOPRIGHT", 0, 0)
    bg:SetHeight(34)
    bg:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.06)

    -- Bold left accent bar (spans full height of background band)
    local bar = f:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", bg, "TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
    bar:SetWidth(4)
    bar:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.95)

    -- Section title text (larger, bolder)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    t:SetPoint("LEFT", bar, "RIGHT", 10, 0)
    t:SetText(text)
    t:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])
    if t.GetFont and t.SetFont then
        local fp, _, fl = t:GetFont()
        if fp then pcall(t.SetFont, t, fp, 13, fl) end
    end

    -- Horizontal rule extending to right edge
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetPoint("LEFT", t, "RIGHT", 12, 0)
    line:SetPoint("RIGHT", 0, 0)
    line:SetColorTexture(UI_COLORS.separator[1], UI_COLORS.separator[2], UI_COLORS.separator[3], UI_COLORS.separator[4])

    -- Bottom rule under the band
    local bottomRule = f:CreateTexture(nil, "ARTWORK")
    bottomRule:SetPoint("BOTTOMLEFT", bg, "BOTTOMLEFT", 0, 0)
    bottomRule:SetPoint("BOTTOMRIGHT", bg, "BOTTOMRIGHT", 0, 0)
    bottomRule:SetHeight(1)
    bottomRule:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.12)

    f.SetText = function(self, val) t:SetText(val) end
    f:SetScript("OnShow", function(self)
        local p = self:GetParent()
        if p and p.GetWidth then
            self:SetWidth(math.max(280, (p:GetWidth() or 420) - 36))
        end
    end)
    f.line = line
    f.bar = bar
    return f
end

--- CreateControlCard: Base card component with backdrop, label, left accent mark, and hover effect.
--   Used as the foundation for sliders, dropdowns, and toggle cards.
-- @param parent (Frame) - Parent frame
-- @param titleText (string) - Card label (also used for automatic tooltip lookup)
-- @return (Frame) - Card frame with .label FontString and ._leftMark texture
local function CreateControlCard(parent, titleText)
    local f = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    f:SetSize(420, CARD_HEIGHT)
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(UI_COLORS.cardBg[1], UI_COLORS.cardBg[2], UI_COLORS.cardBg[3], UI_COLORS.cardBg[4])
    f:SetBackdropBorderColor(UI_COLORS.borderSubtle[1], UI_COLORS.borderSubtle[2], UI_COLORS.borderSubtle[3], UI_COLORS.borderSubtle[4])

    -- Top gradient band (gives visual depth)
    local topGrad = f:CreateTexture(nil, "ARTWORK")
    topGrad:SetPoint("TOPLEFT", 1, -1)
    topGrad:SetPoint("TOPRIGHT", -1, -1)
    topGrad:SetHeight(24)
    topGrad:SetColorTexture(1, 1, 1, 0.02)

    -- Left accent mark (thin colored bar)
    local leftMark = f:CreateTexture(nil, "ARTWORK")
    leftMark:SetPoint("TOPLEFT", 1, -1)
    leftMark:SetPoint("BOTTOMLEFT", 1, 1)
    leftMark:SetWidth(2)
    leftMark:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.25)

    -- Label text
    local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("TOPLEFT", SLIDER_INSET + 2, -10)
    label:SetText(titleText)
    label:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])
    if label.GetFont and label.SetFont then
        local fp, _, fl = label:GetFont()
        if fp then pcall(label.SetFont, label, fp, 11, fl) end
    end
    f.label = label
    f._leftMark = leftMark

    -- Hover effect (respects toggle override color)
    f:EnableMouse(true)
    f._leftMarkColor = nil  -- set by toggle cards to persist color across hover
    f:SetScript("OnEnter", function(self)
        self:SetBackdropColor(UI_COLORS.cardBgHover[1], UI_COLORS.cardBgHover[2], UI_COLORS.cardBgHover[3], UI_COLORS.cardBgHover[4])
        self:SetBackdropBorderColor(UI_COLORS.borderMedium[1], UI_COLORS.borderMedium[2], UI_COLORS.borderMedium[3], UI_COLORS.borderMedium[4])
        if self._leftMarkColor then
            leftMark:SetColorTexture(self._leftMarkColor[1], self._leftMarkColor[2], self._leftMarkColor[3], self._leftMarkColor[4])
        else
            leftMark:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.55)
        end
    end)
    f:SetScript("OnLeave", function(self)
        self:SetBackdropColor(UI_COLORS.cardBg[1], UI_COLORS.cardBg[2], UI_COLORS.cardBg[3], UI_COLORS.cardBg[4])
        self:SetBackdropBorderColor(UI_COLORS.borderSubtle[1], UI_COLORS.borderSubtle[2], UI_COLORS.borderSubtle[3], UI_COLORS.borderSubtle[4])
        if self._leftMarkColor then
            leftMark:SetColorTexture(self._leftMarkColor[1], self._leftMarkColor[2], self._leftMarkColor[3], self._leftMarkColor[4])
        else
            leftMark:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.25)
        end
    end)

    local tip = TOOLTIP_TEXTS[titleText]
    if tip then AttachTooltip(f, tip) end
    return f
end

--- CreateSlider: Creates a control card with a slider and value badge.
-- @param parent (Frame) - Parent frame
-- @param label (string) - Slider label
-- @param min (number) - Minimum value
-- @param max (number) - Maximum value
-- @param step (number) - Value step increment
-- @param currentVal (number) - Initial value
-- @param callback (function) - Called with (value) on change
-- @return (Frame) - Card with .SetValue(self, v), .SetRange(self, min, max), ._slider
local sliderID = 0
local function CreateSlider(parent, label, min, max, step, currentVal, callback)
    sliderID = sliderID + 1
    local card = CreateControlCard(parent, label)

    -- Value badge (accent-colored, right-aligned)
    local valBadge = CreateFrame("Frame", nil, card, "BackdropTemplate")
    valBadge:SetSize(52, 18)
    valBadge:SetPoint("TOPRIGHT", -SLIDER_INSET, -8)
    valBadge:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    valBadge:SetBackdropColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.12)
    valBadge:SetBackdropBorderColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.30)
    local valText = valBadge:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    valText:SetPoint("CENTER", 0, 0)
    valText:SetTextColor(UI_COLORS.textAccent[1], UI_COLORS.textAccent[2], UI_COLORS.textAccent[3])

    local slider = CreateFrame("Slider", "MidnightUISlider"..sliderID, card, "OptionsSliderTemplate")
    slider:SetPoint("BOTTOMLEFT", SLIDER_INSET + 2, 14)
    slider:SetPoint("BOTTOMRIGHT", -SLIDER_INSET - 2, 14)
    slider:SetHeight(14)
    slider:SetMinMaxValues(min, max)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)

    if _G[slider:GetName().."Low"] then _G[slider:GetName().."Low"]:Hide() end
    if _G[slider:GetName().."High"] then _G[slider:GetName().."High"]:Hide() end
    if _G[slider:GetName().."Text"] then _G[slider:GetName().."Text"]:Hide() end

    local function Upd(v)
        if step < 1 then valText:SetText(string.format("%.2f", v)) else valText:SetText(math.floor(v)) end
    end

    slider:SetValue(currentVal)
    Upd(currentVal)

    slider:SetScript("OnValueChanged", function(self, v) Upd(v); if callback then callback(v) end end)
    card.SetValue = function(self, v) slider:SetValue(v) end
    card.SetRange = function(self, newMin, newMax) slider:SetMinMaxValues(newMin, newMax) end
    card._slider = slider
    return card
end

--- CreateDropdown: Creates a control card with a UIDropDownMenu.
-- @param parent (Frame) - Parent frame
-- @param label (string) - Dropdown label
-- @param options (table) - Array of string option values
-- @param currentVal (string) - Initially selected option
-- @param callback (function) - Called with (selectedOption) on selection
-- @return (Frame) - Card with .SetValue(self, val), .SetDisabled(self, bool)
local dropdownID = 0
local function CreateDropdown(parent, label, options, currentVal, callback)
    dropdownID = dropdownID + 1
    local card = CreateControlCard(parent, label)

    local dropdown = CreateFrame("Frame", "MidnightUIDropdown"..dropdownID, card, "UIDropDownMenuTemplate")
    dropdown:SetPoint("BOTTOMLEFT", -4, 2)

    UIDropDownMenu_SetWidth(dropdown, 180)
    UIDropDownMenu_SetText(dropdown, currentVal)

    UIDropDownMenu_Initialize(dropdown, function(self, level)
        for _, option in ipairs(options) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = option
            info.func = function()
                UIDropDownMenu_SetText(dropdown, option)
                if callback then callback(option) end
            end
            UIDropDownMenu_AddButton(info)
        end
    end)

    card.SetValue = function(self, val) UIDropDownMenu_SetText(dropdown, val) end
    card.SetDisabled = function(self, isDisabled)
        if isDisabled then UIDropDownMenu_DisableDropDown(dropdown) else UIDropDownMenu_EnableDropDown(dropdown) end
    end
    return card
end

--- CreateToggleControlCard: Creates a card with a checkbox, ON/OFF badge, and optional description.
--   The left accent mark changes green when checked, reverts to default when unchecked.
-- @param parent (Frame) - Parent frame
-- @param title (string) - Toggle label
-- @param description (string|nil) - Subtitle text below the title
-- @param isChecked (boolean) - Initial checked state
-- @param onToggle (function) - Called with (checked, checkButton, card)
-- @param opts (table|nil) - { height, tooltip, wrapTitle, titleRightPad, descriptionRightPad }
-- @return (Frame) - Card with .SetChecked(v), .GetChecked(), ._toggle, ._statusBadge
local function CreateToggleControlCard(parent, title, description, isChecked, onToggle, opts)
    opts = opts or {}
    local card = CreateControlCard(parent, title)
    card:SetHeight(opts.height or 68)

    if card.label then
        card.label:ClearAllPoints()
        card.label:SetPoint("TOPLEFT", SLIDER_INSET + 2, -10)
        card.label:SetPoint("TOPRIGHT", -(opts.titleRightPad or 56), -10)
        card.label:SetJustifyH("LEFT")
        if card.label.SetWordWrap then
            card.label:SetWordWrap(opts.wrapTitle == true)
        end
    end

    local desc = nil
    if description and description ~= "" then
        desc = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        desc:SetPoint("TOPLEFT", SLIDER_INSET + 2, -30)
        desc:SetPoint("TOPRIGHT", -(opts.descriptionRightPad or 56), -30)
        desc:SetJustifyH("LEFT")
        desc:SetJustifyV("TOP")
        desc:SetText(description)
        desc:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
    end

    -- Status indicator (ON/OFF badge)
    local statusBadge = card:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    statusBadge:SetPoint("TOPRIGHT", -42, -10)
    statusBadge:SetJustifyH("RIGHT")

    local toggle = CreateFrame("CheckButton", nil, card, "InterfaceOptionsCheckButtonTemplate")
    toggle:SetPoint("TOPRIGHT", -6, -4)
    if toggle.Text then
        toggle.Text:SetText("")
    end
    local regions = { toggle:GetRegions() }
    for _, region in ipairs(regions) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            region:SetText("")
            region:Hide()
        end
    end

    local function UpdateToggleVisual(checked)
        if checked then
            statusBadge:SetText("ON")
            statusBadge:SetTextColor(0.30, 0.90, 0.55)
            card._leftMarkColor = {0.20, 0.85, 0.45, 0.60}
            if card._leftMark then
                card._leftMark:SetColorTexture(0.20, 0.85, 0.45, 0.60)
            end
        else
            statusBadge:SetText("OFF")
            statusBadge:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
            card._leftMarkColor = nil  -- revert to default accent
            if card._leftMark then
                card._leftMark:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.15)
            end
        end
    end

    toggle:SetChecked(isChecked == true)
    UpdateToggleVisual(isChecked == true)
    toggle:SetScript("OnClick", function(self)
        local checked = self:GetChecked() == true
        UpdateToggleVisual(checked)
        if onToggle then
            onToggle(checked, self, card)
        end
    end)

    local tooltipText = opts.tooltip or TOOLTIP_LABELS[title]
    if tooltipText then
        AttachTooltip(card, tooltipText)
    end

    card.SetChecked = function(_, value)
        toggle:SetChecked(value == true)
        UpdateToggleVisual(value == true)
    end
    card.GetChecked = function()
        return toggle:GetChecked() == true
    end
    card._toggle = toggle
    card._desc = desc
    card._statusBadge = statusBadge
    return card
end

--- LayoutCardsTwoColumn: Arranges an array of card frames in a responsive 2-column grid.
--   Falls back to 1 column if the parent is too narrow. Re-layouts on parent resize/show.
-- @param cards (table) - Array of card frames
-- @param leftX (number) - Left inset from parent
-- @param startY (number) - Starting Y offset from parent top
-- @param colGap (number) - Gap between columns
-- @param rowGap (number) - Gap between rows
-- @param minCardWidth (number) - Minimum card width before collapsing to 1 column
local function LayoutCardsTwoColumn(cards, leftX, startY, colGap, rowGap, minCardWidth)
    leftX = leftX or PAGE_INSET_X
    startY = startY or -70
    colGap = colGap or COL_GAP
    rowGap = rowGap or ROW_GAP
    minCardWidth = minCardWidth or 180
    local parent = cards and cards[1] and cards[1]:GetParent()

    local function DoLayout()
        if not cards or #cards == 0 then return end
        local cardHeight = CARD_HEIGHT
        for _, card in ipairs(cards) do
            if card and card.GetHeight then
                local h = card:GetHeight() or CARD_HEIGHT
                if h > cardHeight then
                    cardHeight = h
                end
            end
        end
        local parentWidth = (parent and parent.GetWidth and parent:GetWidth()) or 0
        if parentWidth <= 0 and parent and parent.GetParent then
            parentWidth = (parent:GetParent() and parent:GetParent():GetWidth()) or 0
        end
        if parentWidth <= 0 then parentWidth = 520 end

        local parentHeight = (parent and parent.GetHeight and parent:GetHeight()) or 420
        local usableWidth = math.max(220, parentWidth - (leftX * 2))
        local columns = 2
        local cardWidth = math.floor((usableWidth - colGap) / 2)
        if cardWidth < minCardWidth then columns = 1; cardWidth = usableWidth end

        -- Use natural row gap — scroll frames handle overflow, no compression needed
        local effectiveRowGap = math.max(rowGap, cardHeight + 16)

        for i, card in ipairs(cards) do
            if card then
                local col = (i - 1) % columns
                local row = math.floor((i - 1) / columns)
                card:ClearAllPoints()
                card:SetPoint("TOPLEFT", leftX + (col * (cardWidth + colGap)), startY - (row * effectiveRowGap))
                card:SetWidth(cardWidth)
            end
        end
    end

    DoLayout()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, DoLayout)
        C_Timer.After(0.05, DoLayout)
    end

    if parent then
        parent._midnightUILayouts = parent._midnightUILayouts or {}
        parent._midnightUILayouts[#parent._midnightUILayouts + 1] = DoLayout
        if not parent._midnightUILayoutHooked then
            parent._midnightUILayoutHooked = true
            parent:HookScript("OnSizeChanged", function(self)
                if self._midnightUILayouts then
                    for _, fn in ipairs(self._midnightUILayouts) do fn() end
                end
            end)
            parent:HookScript("OnShow", function(self)
                if self._midnightUILayouts then
                    for _, fn in ipairs(self._midnightUILayouts) do fn() end
                end
            end)
        end
    end
end

--- CreateScrollPage: Creates a scroll frame + child content frame pair for a settings page.
-- @param parent (Frame) - The page container frame
-- @return scroll (ScrollFrame), child (Frame) - The scroll frame and its scrollable content child
local function CreateScrollPage(parent)
    local scroll = CreateFrame("ScrollFrame", nil, parent, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", -26, 0)

    local child = CreateFrame("Frame", nil, scroll)
    child:SetPoint("TOPLEFT", 0, 0)
    child:SetPoint("TOPRIGHT", 0, 0)
    child:SetHeight(1)
    scroll:SetScrollChild(child)

    scroll:HookScript("OnSizeChanged", function(self, w)
        if child and w and w > 0 then
            child:SetWidth(w)
        end
    end)

    return scroll, child
end

--- CreateInfoNote: Creates a small info-icon + text note strip.
-- @param parent (Frame) - Parent frame
-- @param text (string) - Note text
-- @return (Frame) - Note frame with .SetText method
local function CreateInfoNote(parent, text)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(420, 22)
    local icon = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    icon:SetPoint("LEFT", 6, 0)
    icon:SetText("\226\132\185")  -- ℹ
    icon:SetTextColor(UI_COLORS.accentDim[1], UI_COLORS.accentDim[2], UI_COLORS.accentDim[3], 0.7)
    local t = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    t:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    t:SetPoint("RIGHT", -6, 0)
    t:SetJustifyH("LEFT")
    t:SetText(text)
    t:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
    f.SetText = function(self, val) t:SetText(val) end
    return f
end

--- ComputeScrollHeight: Measures the total occupied height of a scroll child's visible children.
-- @param scrollChild (Frame) - The scroll child frame
-- @param padding (number) - Extra padding below the lowest child (default 20)
local function ComputeScrollHeight(scrollChild, padding)
    padding = padding or 20
    local maxBottom = 0
    for _, child in ipairs({ scrollChild:GetChildren() }) do
        if child and child:IsShown() and child.GetBottom and scrollChild.GetTop then
            local top = scrollChild:GetTop()
            local bottom = child:GetBottom()
            if top and bottom then
                local extent = top - bottom
                if extent > maxBottom then maxBottom = extent end
            end
        end
    end
    scrollChild:SetHeight(math.max(1, maxBottom + padding))
end

-- ============================================================================
-- DASHBOARD LAYOUT
-- BuildSettingsUI() creates the entire settings panel: sidebar navigation,
-- content area with header, sub-tab system, and all individual settings pages.
-- Called once at file load time.
-- ============================================================================

local ConfigFrame
local function BuildSettingsUI()
ConfigFrame = CreateFrame("Frame", nil, UIParent)
M.ConfigFrame = ConfigFrame
ConfigFrame.name = "Midnight UI"
local HEADER_HEIGHT = 92

-- ============================================================================
-- SIDEBAR
-- Left panel with brand logo, navigation buttons for each settings page,
-- and the pinned "About" button at the bottom. Dark background with a right
-- edge separator and subtle glow.
-- ============================================================================
local Sidebar = CreateFrame("Frame", nil, ConfigFrame)
Sidebar:SetPoint("TOPLEFT", 0, 0)
Sidebar:SetPoint("BOTTOMLEFT", 0, 0)
Sidebar:SetWidth(186)

-- Sidebar background (deepest surface)
local SidebarBg = Sidebar:CreateTexture(nil, "BACKGROUND")
SidebarBg:SetAllPoints()
SidebarBg:SetColorTexture(UI_COLORS.sidebarBg[1], UI_COLORS.sidebarBg[2], UI_COLORS.sidebarBg[3], 0.95)

-- Right edge separator + glow
local SidebarLine = Sidebar:CreateTexture(nil, "ARTWORK")
SidebarLine:SetPoint("TOPRIGHT"); SidebarLine:SetPoint("BOTTOMRIGHT")
SidebarLine:SetWidth(1)
SidebarLine:SetColorTexture(UI_COLORS.borderMedium[1], UI_COLORS.borderMedium[2], UI_COLORS.borderMedium[3], UI_COLORS.borderMedium[4])
local SidebarGlow = Sidebar:CreateTexture(nil, "ARTWORK", nil, -1)
SidebarGlow:SetPoint("TOPRIGHT", -1, 0); SidebarGlow:SetPoint("BOTTOMRIGHT", -1, 0)
SidebarGlow:SetWidth(4)
SidebarGlow:SetColorTexture(UI_COLORS.accentGlow[1], UI_COLORS.accentGlow[2], UI_COLORS.accentGlow[3], UI_COLORS.accentGlow[4])

-- Brand logo area at top of sidebar
local SidebarBrand = Sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
SidebarBrand:SetPoint("TOP", 0, -18)
SidebarBrand:SetText("MIDNIGHT")
SidebarBrand:SetTextColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.9)
local SidebarBrandSub = Sidebar:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
SidebarBrandSub:SetPoint("TOP", SidebarBrand, "BOTTOM", 0, -2)
SidebarBrandSub:SetText("UI  SETTINGS")
SidebarBrandSub:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
SidebarBrandSub:SetSpacing(2)
-- Brand separator
local SidebarBrandRule = Sidebar:CreateTexture(nil, "ARTWORK")
SidebarBrandRule:SetPoint("TOPLEFT", 16, -52)
SidebarBrandRule:SetPoint("TOPRIGHT", -16, -52)
SidebarBrandRule:SetHeight(1)
SidebarBrandRule:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.20)

-- ============================================================================
-- CONTENT AREA
-- Right panel containing the page header (title, subtitle, breadcrumb hint),
-- sub-tab bar, and the active page content. Separated from sidebar by the
-- sidebar's right-edge line.
-- ============================================================================
local Content = CreateFrame("Frame", nil, ConfigFrame)
Content:SetPoint("TOPLEFT", Sidebar, "TOPRIGHT", 0, 0)
Content:SetPoint("BOTTOMRIGHT", 0, 0)

-- Content background (slightly lighter than sidebar)
local ContentBg = Content:CreateTexture(nil, "BACKGROUND")
ContentBg:SetAllPoints()
ContentBg:SetColorTexture(UI_COLORS.contentBg[1], UI_COLORS.contentBg[2], UI_COLORS.contentBg[3], 0.85)

-- Header band with gradient effect
local HeaderBg = Content:CreateTexture(nil, "ARTWORK")
HeaderBg:SetPoint("TOPLEFT", 0, 0)
HeaderBg:SetPoint("TOPRIGHT", 0, 0)
HeaderBg:SetHeight(HEADER_HEIGHT)
HeaderBg:SetColorTexture(UI_COLORS.headerBg[1], UI_COLORS.headerBg[2], UI_COLORS.headerBg[3], 0.95)

-- Accent line at top of header (brand color)
local HeaderTopAccent = Content:CreateTexture(nil, "ARTWORK")
HeaderTopAccent:SetPoint("TOPLEFT", 0, 0)
HeaderTopAccent:SetPoint("TOPRIGHT", 0, 0)
HeaderTopAccent:SetHeight(2)
HeaderTopAccent:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.45)

-- Bottom rule under header
local HeaderBottomRule = Content:CreateTexture(nil, "ARTWORK")
HeaderBottomRule:SetPoint("TOPLEFT", 0, -HEADER_HEIGHT)
HeaderBottomRule:SetPoint("TOPRIGHT", 0, -HEADER_HEIGHT)
HeaderBottomRule:SetHeight(1)
HeaderBottomRule:SetColorTexture(UI_COLORS.borderMedium[1], UI_COLORS.borderMedium[2], UI_COLORS.borderMedium[3], UI_COLORS.borderMedium[4])

-- Subtle glow under header
local HeaderGlow = Content:CreateTexture(nil, "BACKGROUND")
HeaderGlow:SetPoint("TOPLEFT", 0, -(HEADER_HEIGHT + 1))
HeaderGlow:SetPoint("TOPRIGHT", 0, -(HEADER_HEIGHT + 1))
HeaderGlow:SetHeight(12)
HeaderGlow:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.04)

-- Section title (large, prominent)
local SectionTitle = Content:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
SectionTitle:SetPoint("TOPLEFT", 24, -18)
SectionTitle:SetText("General")
SectionTitle:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])
if SectionTitle.GetFont and SectionTitle.SetFont then
    local fp, _, fl = SectionTitle:GetFont()
    if fp then pcall(SectionTitle.SetFont, SectionTitle, fp, 18, fl) end
end

-- Subtitle
local Subtitle = Content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
Subtitle:SetPoint("TOPLEFT", 24, -44)
Subtitle:SetPoint("TOPRIGHT", -22, -44)
Subtitle:SetJustifyH("LEFT")
Subtitle:SetText("Theme, chat, minimap, questing, inventory, and market options.")
Subtitle:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])

-- Page count hint (e.g., "6 sections")
local PageHint = Content:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
PageHint:SetPoint("TOPRIGHT", -24, -22)
PageHint:SetJustifyH("RIGHT")
PageHint:SetText("")
PageHint:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

-- pages[id] = Frame, navButtons[id] = Button, subTabGroups[id] = group table
-- PAGE_TITLES and PAGE_SUBTITLES provide the header text for each nav page.
local pages = {}
local navButtons = {}
local subTabGroups = {}
local PAGE_TITLES = {
    Interface = "General",
    Player = "Player Frame",
    Target = "Target & Focus",
    PartyFrames = "Party Frames",
    RaidFrames = "Raid Frames",
    Combat = "Combat",
    ActionSystems = "Action Bars",
    Other = "Tools",
    About = "About MidnightUI",
}
local PAGE_SUBTITLES = {
    Interface = "Theme, chat, minimap, questing, inventory, and market options.",
    Player = "Configure player frame, buffs, debuffs, and consumables.",
    Target = "Configure target frame, focus frame, and nameplate controls.",
    PartyFrames = "Adjust party layout, spacing, and party dispel overlays.",
    RaidFrames = "Configure raid and main tank frame behavior.",
    Combat = "Tune cast bars, debuff alerts, and dispel tracking.",
    ActionSystems = "Adjust action bars, pet bar, and stance bar layout.",
    Other = "Manage profiles, security safeguards, and diagnostics.",
    About = "Community links, supporters, and project information.",
}

-- ============================================================================
-- NAV BUTTON & PAGE SYSTEM
-- ShowPage hides all pages, highlights the active nav button, updates the
-- header, and shows the target page (plus its sub-tab if any).
-- CreateNavButton adds a sidebar entry and creates its associated page frame.
-- ============================================================================

--- ShowPage: Switches to the specified settings page.
-- @param id (string) - Page identifier (e.g. "Interface", "Player", "Target")
local function ShowPage(id)
    for k, p in pairs(pages) do p:Hide() end
    for k, b in pairs(navButtons) do
        if k == id then
            -- Active state: filled background, bright text, accent bar
            b.bg:SetColorTexture(UI_COLORS.navActive[1], UI_COLORS.navActive[2], UI_COLORS.navActive[3], UI_COLORS.navActive[4])
            b.text:SetTextColor(1, 1, 1)
            b.icon:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
            b.accent:SetColorTexture(UI_COLORS.navActiveMark[1], UI_COLORS.navActiveMark[2], UI_COLORS.navActiveMark[3], UI_COLORS.navActiveMark[4])
            if b.iconGlow then b.iconGlow:Show() end
        else
            -- Idle state
            b.bg:SetColorTexture(0, 0, 0, 0)
            b.text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
            b.icon:SetVertexColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
            b.accent:SetColorTexture(0, 0, 0, 0)
            if b.iconGlow then b.iconGlow:Hide() end
        end
    end
    if SectionTitle then
        SectionTitle:SetText(PAGE_TITLES[id] or "Settings")
    end
    if Subtitle then
        Subtitle:SetText(PAGE_SUBTITLES[id] or "Choose a category from the left.")
    end
    if pages[id] then
        pages[id]:Show()
        local grp = subTabGroups[id]
        if grp and grp.Show then grp.Show(grp.current or grp.defaultTab) end
    end
end
M.ShowPage = ShowPage

--- CreateNavButton: Creates a sidebar navigation button and its associated page frame.
-- @param id (string) - Unique page identifier
-- @param label (string) - Button display text
-- @param iconInfo (number|string) - Icon texture ID or path
-- @param index (number) - Vertical position index (1-based, top to bottom)
-- @return (Frame) - The page content frame
local function CreateNavButton(id, label, iconInfo, index)
    local NAV_BTN_H = 40
    local NAV_START_Y = 62  -- below brand area
    local b = CreateFrame("Button", nil, Sidebar)
    b:SetSize(186, NAV_BTN_H)
    b:SetPoint("TOPLEFT", 0, -(NAV_START_Y + (index-1) * (NAV_BTN_H + 2)))

    -- Background fill (changes on hover/active)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints()
    b.bg:SetColorTexture(0, 0, 0, 0)

    -- Left accent bar (3px, visible on active)
    b.accent = b:CreateTexture(nil, "ARTWORK")
    b.accent:SetPoint("TOPLEFT", 0, -2); b.accent:SetPoint("BOTTOMLEFT", 0, 2)
    b.accent:SetWidth(3)
    b.accent:SetColorTexture(0, 0, 0, 0)

    -- Icon with subtle glow behind it
    b.iconGlow = b:CreateTexture(nil, "BACKGROUND")
    b.iconGlow:SetSize(28, 28)
    b.iconGlow:SetPoint("LEFT", 14, 0)
    b.iconGlow:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.10)
    b.iconGlow:Hide()

    b.icon = b:CreateTexture(nil, "ARTWORK")
    b.icon:SetSize(20, 20)
    b.icon:SetPoint("LEFT", 18, 0)
    b.icon:SetTexture(iconInfo)
    b.icon:SetVertexColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

    -- Label text (slightly larger)
    b.text = b:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    b.text:SetPoint("LEFT", b.icon, "RIGHT", 12, 0)
    b.text:SetText(label)
    b.text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
    if b.text.GetFont and b.text.SetFont then
        local fp, _, fl = b.text:GetFont()
        if fp then pcall(b.text.SetFont, b.text, fp, 11, fl) end
    end

    b:SetScript("OnClick", function() ShowPage(id) end)
    b:SetScript("OnEnter", function(self)
        if pages[id] and pages[id]:IsShown() then return end
        self.bg:SetColorTexture(UI_COLORS.navHover[1], UI_COLORS.navHover[2], UI_COLORS.navHover[3], UI_COLORS.navHover[4])
        self.text:SetTextColor(0.88, 0.90, 0.95)
        self.icon:SetVertexColor(0.75, 0.80, 0.88)
    end)
    b:SetScript("OnLeave", function(self)
        if pages[id] and pages[id]:IsShown() then return end
        self.bg:SetColorTexture(0, 0, 0, 0)
        self.text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
        self.icon:SetVertexColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
    end)

    navButtons[id] = b
    local p = CreateFrame("Frame", nil, Content)
    p:SetPoint("TOPLEFT", 0, -(HEADER_HEIGHT + 4)); p:SetPoint("BOTTOMRIGHT", 0, 0); p:Hide()
    pages[id] = p
    return p
end

-- ============================================================================
-- SUB-TAB SYSTEM
-- Pages with multiple sections use a horizontal tab bar below the header.
-- CreateFlatSectionGroup builds the tab bar, tab buttons, and content frames.
-- Tabs auto-scale to fit available width.
-- ============================================================================

local SUBTAB_BTN_HEIGHT = 32
local SUBTAB_BAR_HEIGHT = 38

--- CreateFlatSectionGroup: Creates a horizontal sub-tab bar within a main page.
-- @param mainId (string) - Parent page ID (for subTabGroups registration)
-- @param mainPage (Frame) - Parent page frame
-- @param def (table) - { defaultTab = "id", tabs = { {id, label}, ... } }
-- @return (table) - Map of sub-tab id -> content frame
local function CreateFlatSectionGroup(mainId, mainPage, def)
    local grp = { buttons = {}, pages = {}, content = {}, order = {}, defaultTab = def.defaultTab, current = nil }

    -- Tab bar container with subtle background
    local tabBar = CreateFrame("Frame", nil, mainPage, "BackdropTemplate")
    tabBar:SetPoint("TOPLEFT", 0, -2)
    tabBar:SetPoint("TOPRIGHT", 0, -2)
    tabBar:SetHeight(SUBTAB_BAR_HEIGHT)
    tabBar:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
    })
    tabBar:SetBackdropColor(UI_COLORS.panelBg[1], UI_COLORS.panelBg[2], UI_COLORS.panelBg[3], 0.60)

    -- Bottom accent line under tab bar
    local tabBarRule = tabBar:CreateTexture(nil, "ARTWORK")
    tabBarRule:SetPoint("BOTTOMLEFT", 0, 0)
    tabBarRule:SetPoint("BOTTOMRIGHT", 0, 0)
    tabBarRule:SetHeight(1)
    tabBarRule:SetColorTexture(UI_COLORS.borderMedium[1], UI_COLORS.borderMedium[2], UI_COLORS.borderMedium[3], UI_COLORS.borderMedium[4])

    local function ShowSubTab(subId)
        for id, page in pairs(grp.pages) do
            page:Hide()
            local btn = grp.buttons[id]
            if btn then
                -- Idle state: transparent bg, muted text
                btn._bg:SetColorTexture(0, 0, 0, 0)
                btn._text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
                btn._edge:SetColorTexture(0, 0, 0, 0)
            end
        end
        if grp.pages[subId] then grp.pages[subId]:Show(); grp.current = subId end
        local selected = grp.buttons[subId]
        if selected then
            -- Active state: filled bg, bright text, accent bottom edge
            selected._bg:SetColorTexture(UI_COLORS.navActive[1], UI_COLORS.navActive[2], UI_COLORS.navActive[3], 0.60)
            selected._text:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])
            selected._edge:SetColorTexture(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.95)
        end
    end

    local function LayoutTabs()
        local available = math.max(300, (tabBar:GetWidth() or 500) - (PAGE_INSET_X * 2))
        local gap = 4
        local totalPref = 0
        for _, subId in ipairs(grp.order) do
            totalPref = totalPref + (grp.buttons[subId]._prefWidth or 80)
        end
        totalPref = totalPref + ((#grp.order - 1) * gap)
        local scale = 1
        if totalPref > available and totalPref > 0 then scale = available / totalPref end
        local x = PAGE_INSET_X
        for _, subId in ipairs(grp.order) do
            local btn = grp.buttons[subId]
            local w = math.max(56, math.floor((btn._prefWidth or 80) * scale))
            btn:SetWidth(w)
            btn:ClearAllPoints()
            btn:SetPoint("BOTTOMLEFT", tabBar, "BOTTOMLEFT", x, 2)
            x = x + w + gap
        end
        for _, page in pairs(grp.pages) do
            page:ClearAllPoints()
            page:SetPoint("TOPLEFT", mainPage, "TOPLEFT", 0, -(SUBTAB_BAR_HEIGHT + 6))
            page:SetPoint("BOTTOMRIGHT", mainPage, "BOTTOMRIGHT", 0, 0)
        end
    end

    for _, sub in ipairs(def.tabs) do
        local label = sub.label or sub.id
        local w = math.max(64, math.min(160, (string.len(label) * 7) + 24))

        local btn = CreateFrame("Button", nil, tabBar)
        btn:SetSize(w, SUBTAB_BTN_HEIGHT)

        -- Background fill
        btn._bg = btn:CreateTexture(nil, "BACKGROUND")
        btn._bg:SetAllPoints()
        btn._bg:SetColorTexture(0, 0, 0, 0)

        -- Bottom accent edge (visible when active)
        btn._edge = btn:CreateTexture(nil, "ARTWORK")
        btn._edge:SetPoint("BOTTOMLEFT", 2, 0)
        btn._edge:SetPoint("BOTTOMRIGHT", -2, 0)
        btn._edge:SetHeight(2)
        btn._edge:SetColorTexture(0, 0, 0, 0)

        -- Label
        btn._text = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        btn._text:SetPoint("CENTER", 0, 1)
        btn._text:SetText(label)
        btn._text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
        if btn._text.GetFont and btn._text.SetFont then
            local fp, _, fl = btn._text:GetFont()
            if fp then pcall(btn._text.SetFont, btn._text, fp, 11, fl) end
        end

        btn._prefWidth = w
        btn:SetScript("OnClick", function() ShowSubTab(sub.id) end)
        btn:SetScript("OnEnter", function(self)
            if grp.current == sub.id then return end
            self._bg:SetColorTexture(UI_COLORS.navHover[1], UI_COLORS.navHover[2], UI_COLORS.navHover[3], UI_COLORS.navHover[4])
            self._text:SetTextColor(0.88, 0.92, 0.97)
        end)
        btn:SetScript("OnLeave", function(self)
            if grp.current == sub.id then return end
            self._bg:SetColorTexture(0, 0, 0, 0)
            self._text:SetTextColor(UI_COLORS.textSecondary[1], UI_COLORS.textSecondary[2], UI_COLORS.textSecondary[3])
        end)

        grp.buttons[sub.id] = btn
        grp.order[#grp.order + 1] = sub.id

        -- Content page for this sub-tab
        local page = CreateFrame("Frame", nil, mainPage)
        page:Hide()
        grp.pages[sub.id] = page
        grp.content[sub.id] = page
    end

    tabBar:SetScript("OnSizeChanged", LayoutTabs)
    mainPage:HookScript("OnSizeChanged", LayoutTabs)
    LayoutTabs()
    grp.Show = ShowSubTab
    subTabGroups[mainId] = grp
    ShowSubTab(def.defaultTab)
    return grp.content
end

local CreateSubTabGroup = CreateFlatSectionGroup  -- backward-compat alias

-- ============================================================================
-- MAIN NAV BUTTONS + SUB-TAB DEFINITIONS
-- Creates all 9 sidebar pages and their sub-tab groups.
-- ============================================================================

local pInterfaceMain = CreateNavButton("Interface", "General",      136243, 1)
local pPlayerMain    = CreateNavButton("Player",    "Player",       132093, 2)
local pTargetMain    = CreateNavButton("Target",    "Target",       132212, 3)
local pPartyMain     = CreateNavButton("PartyFrames", "Party Frames", 132347, 4)
local pRaidMain      = CreateNavButton("RaidFrames", "Raid Frames", 132333, 5)
local pCombatMain    = CreateNavButton("Combat",    "Combat",       132349, 6)
local pActionMain    = CreateNavButton("ActionSystems", "Action Bars", 132331, 7)
local pOtherMain     = CreateNavButton("Other",     "Tools",        134269, 8)
local pAboutMain     = CreateNavButton("About",     "About MidnightUI", 133896, 10)
pAboutMain:ClearAllPoints()
pAboutMain:SetPoint("TOPLEFT", 0, -60)
pAboutMain:SetPoint("BOTTOMRIGHT", 0, 0)
if navButtons and navButtons.About then
    local aboutBtn = navButtons.About
    aboutBtn:ClearAllPoints()
    aboutBtn:SetWidth(Sidebar:GetWidth() or 186)
    aboutBtn:SetPoint("BOTTOMLEFT", 0, 20)

    if not aboutBtn._muiAboutVisual then
        aboutBtn._muiAboutVisual = true

        local plate = aboutBtn:CreateTexture(nil, "BACKGROUND", nil, -1)
        plate:SetPoint("TOPLEFT", 3, -3)
        plate:SetPoint("BOTTOMRIGHT", -3, 3)
        plate:SetColorTexture(0.02, 0.22, 0.32, 0.34)

        local tint = aboutBtn:CreateTexture(nil, "BACKGROUND")
        tint:SetPoint("TOPLEFT", 4, -4)
        tint:SetPoint("BOTTOMRIGHT", -4, 4)
        tint:SetColorTexture(0.00, 0.78, 1.00, 0.10)

        local marker = aboutBtn:CreateTexture(nil, "ARTWORK")
        marker:SetPoint("LEFT", 0, 0)
        marker:SetSize(2, 26)
        marker:SetColorTexture(0.00, 0.78, 1.00, 0.95)
    end
end

local interfaceTabs = CreateFlatSectionGroup("Interface", pInterfaceMain, {
    defaultTab = "General",
    tabs = {
        { id = "General",  label = "General" },
        { id = "Chat",     label = "Chat" },
        { id = "Minimap",  label = "Minimap" },
        { id = "Questing", label = "Questing" },
        { id = "Inventory", label = "Inventory" },
        { id = "Market",   label = "Market" },
    },
})

local playerTabs = CreateFlatSectionGroup("Player", pPlayerMain, {
    defaultTab = "Core",
    tabs = {
        { id = "Core",    label = "Frame" },
        { id = "Auras",   label = "Buffs" },
        { id = "Debuffs", label = "Debuffs" },
        { id = "PetFrame", label = "Pet Frame" },
        { id = "Consumables", label = "Consumables" },
    },
})

local targetTabs = CreateFlatSectionGroup("Target", pTargetMain, {
    defaultTab = "Core",
    tabs = {
        { id = "Core",       label = "Frame" },
        { id = "Nameplates", label = "Nameplates" },
        { id = "Auras",      label = "Buffs" },
        { id = "Debuffs",    label = "Debuffs" },
        { id = "Focus",      label = "Focus" },
    },
})

-- COMBAT
local combatTabs = CreateFlatSectionGroup("Combat", pCombatMain, {
    defaultTab = "CastBars",
    tabs = {
        { id = "CastBars",     label = "Cast Bars" },
        { id = "Debuffs",      label = "Debuffs" },
    },
})

local actionTabs = CreateFlatSectionGroup("ActionSystems", pActionMain, {
    defaultTab = "ActionLayout",
    tabs = {
        { id = "ActionLayout", label = "Layout" },
        { id = "ActionTheme",  label = "Style" },
        { id = "PetBar",       label = "Pet Bar" },
        { id = "StanceBar",    label = "Stance" },
    },
})

local raidTabs = CreateFlatSectionGroup("RaidFrames", pRaidMain, {
    defaultTab = "Raid",
    tabs = {
        { id = "Raid", label = "Raid Frames" },
        { id = "MainTank", label = "Main Tank(s)" },
    },
})

local otherTabs = CreateFlatSectionGroup("Other", pOtherMain, {
    defaultTab = "Profiles",
    tabs = {
        { id = "Profiles", label = "Profiles" },
        { id = "UnitFrames", label = "Security" },
        { id = "Diagnostics", label = "Diagnostics" },
    },
})

--- StyleSettingsButton: Applies the dark MidnightUI button theme to any UIPanelButtonTemplate.
--   Removes default 9-slice textures and replaces with flat fill, accent line, and hover glow.
--   Idempotent (checks MidnightUI_Styled flag).
-- @param b (Button) - Button to style
local function StyleSettingsButton(b)
    if not b or b.MidnightUI_Styled then return end
    b.MidnightUI_Styled = true
    b:SetNormalFontObject("GameFontNormal")
    b:SetHighlightFontObject("GameFontHighlight")
    b:SetDisabledFontObject("GameFontDisable")

    if b.Left then b.Left:SetAlpha(0); b.Left:Hide() end
    if b.Middle then b.Middle:SetAlpha(0); b.Middle:Hide() end
    if b.Right then b.Right:SetAlpha(0); b.Right:Hide() end

    -- Outer border (accent-tinted)
    local border = b:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(UI_COLORS.borderMedium[1], UI_COLORS.borderMedium[2], UI_COLORS.borderMedium[3], UI_COLORS.borderMedium[4])
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Inner fill
    local bg = b:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(UI_COLORS.contentBg[1], UI_COLORS.contentBg[2], UI_COLORS.contentBg[3], 0.95)
    bg:SetPoint("TOPLEFT", 1, -1)
    bg:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Top accent line on button
    local btnAccent = b:CreateTexture(nil, "ARTWORK")
    btnAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    btnAccent:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.20)
    btnAccent:SetPoint("TOPLEFT", 1, -1)
    btnAccent:SetPoint("TOPRIGHT", -1, -1)
    btnAccent:SetHeight(1)

    -- Hover highlight
    local hover = b:CreateTexture(nil, "HIGHLIGHT")
    hover:SetTexture("Interface\\Buttons\\WHITE8X8")
    hover:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3], 0.12)
    hover:SetPoint("TOPLEFT", 1, -1)
    hover:SetPoint("BOTTOMRIGHT", -1, 1)

    -- Pushed state
    local pushed = b:CreateTexture(nil, "ARTWORK")
    pushed:SetTexture("Interface\\Buttons\\WHITE8X8")
    pushed:SetVertexColor(0.02, 0.04, 0.06, 1.00)
    pushed:SetPoint("TOPLEFT", 1, -1)
    pushed:SetPoint("BOTTOMRIGHT", -1, 1)

    b:SetNormalTexture("")
    b:SetHighlightTexture(hover)
    b:SetPushedTexture(pushed)
    b:SetDisabledTexture("")
end
M.StyleSettingsButton = StyleSettingsButton

local function GetAboutSupporters()
    local names = {}
    for _, name in ipairs(ABOUT_SUPPORTERS) do
        if type(name) == "string" then
            local cleaned = name:gsub("^%s+", ""):gsub("%s+$", "")
            if cleaned ~= "" then
                names[#names + 1] = cleaned
            end
        end
    end
    table.sort(names, function(a, b)
        return string.lower(a) < string.lower(b)
    end)
    return names
end

--- OpenAboutURL: Opens a URL via MidnightUI_OpenURL or shows a copy-paste popup.
-- @param url (string) - URL to open/display
local function OpenAboutURL(url)
    if type(url) ~= "string" or url == "" then return end
    if type(_G.MidnightUI_OpenURL) == "function" then
        _G.MidnightUI_OpenURL(url)
        return
    end
    if not StaticPopupDialogs or type(StaticPopup_Show) ~= "function" then return end

    if not StaticPopupDialogs.MIDNIGHTUI_SETTINGS_COPY_URL then
        StaticPopupDialogs.MIDNIGHTUI_SETTINGS_COPY_URL = {
            text = "Copy this link and paste it in your browser:",
            button1 = CLOSE or "Close",
            hasEditBox = true,
            maxLetters = 512,
            timeout = 0,
            whileDead = true,
            hideOnEscape = true,
            preferredIndex = 3,
            OnShow = function(self, data)
                if not self or not self.editBox then return end
                self.editBox:SetText(data or "")
                self.editBox:SetFocus()
                self.editBox:HighlightText()
            end,
            EditBoxOnEscapePressed = function(editBox)
                if editBox then
                    editBox:ClearFocus()
                    if editBox:GetParent() then
                        editBox:GetParent():Hide()
                    end
                end
            end,
            EditBoxOnEnterPressed = function(editBox)
                if editBox then
                    editBox:HighlightText()
                end
            end,
            EditBoxOnTextChanged = function(editBox)
                if editBox then
                    editBox:HighlightText()
                end
            end,
        }
    end

    StaticPopup_Show("MIDNIGHTUI_SETTINGS_COPY_URL", nil, nil, url)
end

--- BuildRaidFramesTab: Constructs the Raid Frames settings page with group-lock, styling,
--   columns, width/height/spacing sliders, and default/custom frame toggle buttons.
-- @param raidTabs (table) - Sub-tab content frames from CreateFlatSectionGroup
-- @param SettingsControls (table) - Shared controls table for OnShow refresh
-- @param ApplyRaidFramesSettings (function) - Apply callback
local function BuildRaidFramesTab(raidTabs, SettingsControls, ApplyRaidFramesSettings)
    local pRaidScroll, pRaidContent = CreateScrollPage(raidTabs.Raid)
    local pRaidFrames = pRaidContent
    pRaidContent:SetHeight(670)
    local UpdateRaidColumnsSliderVisibility
    local function SetRaidColumnsFromSlider(rawValue, sourceCard)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        local groupLocked = SettingsControls.chkRaidGroupBy and SettingsControls.chkRaidGroupBy:GetChecked() == true
        local maxCols = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
        if groupLocked then
            maxCols = math.min(maxCols, 5)
        end
        local value = math.max(1, math.floor(rawValue or 1))
        if value > maxCols then value = maxCols end
        MidnightUISettings.RaidFrames.columns = value

        if SettingsControls.slRaidColumns and sourceCard ~= SettingsControls.slRaidColumns then
            if not SettingsControls.slRaidColumns._muiClamping then
                SettingsControls.slRaidColumns._muiClamping = true
                SettingsControls.slRaidColumns:SetValue(value)
                SettingsControls.slRaidColumns._muiClamping = false
            end
        end
        if SettingsControls.slRaidColumnsGrouped and sourceCard ~= SettingsControls.slRaidColumnsGrouped then
            local groupedValue = math.min(value, 5)
            if not SettingsControls.slRaidColumnsGrouped._muiClamping then
                SettingsControls.slRaidColumnsGrouped._muiClamping = true
                SettingsControls.slRaidColumnsGrouped:SetValue(groupedValue)
                SettingsControls.slRaidColumnsGrouped._muiClamping = false
            end
        end
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end

    local hRaid = CreateSectionHeader(pRaidFrames, "Raid Layout")
    hRaid:SetPoint("TOPLEFT", PAGE_INSET_X, -4)

    -- "Use Default Frames" toggle buttons (raid)
    local function MakeRaidModeButton(label, onClick)
        local b = CreateFrame("Button", nil, pRaidFrames, "UIPanelButtonTemplate")
        b:SetSize(260, 32)
        b:SetText(label)
        b:SetScript("OnClick", onClick)
        StyleSettingsButton(b)
        return b
    end

    SettingsControls.btnDefaultRaid = MakeRaidModeButton("Switch to Default Raid Frames (Reload)", function()
        if InCombatLockdown() then
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
            return
        end
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.useDefaultFrames = true
        ReloadUI()
    end)
    SettingsControls.btnDefaultRaid:SetPoint("TOPLEFT", hRaid, "BOTTOMLEFT", 0, -12)
    SettingsControls.btnDefaultRaid:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Switch to Default Raid Frames", 1, 1, 1)
        GameTooltip:AddLine("Reloads the UI and uses Blizzard's default raid frames.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("MidnightUI custom raid frames will be disabled.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    SettingsControls.btnDefaultRaid:SetScript("OnLeave", function() GameTooltip:Hide() end)

    SettingsControls.btnCustomRaid = MakeRaidModeButton("Switch to Custom Raid Frames (Reload)", function()
        if InCombatLockdown() then
            if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
            return
        end
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.useDefaultFrames = false
        ReloadUI()
    end)
    SettingsControls.btnCustomRaid:SetPoint("TOPLEFT", hRaid, "BOTTOMLEFT", 0, -12)
    SettingsControls.btnCustomRaid:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Switch to Custom Raid Frames", 1, 1, 1)
        GameTooltip:AddLine("Reloads the UI and enables MidnightUI custom raid frames.", 0.9, 0.9, 0.9, true)
        GameTooltip:AddLine("Blizzard's default raid frames will be hidden.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
    end)
    SettingsControls.btnCustomRaid:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local function UpdateRaidModeButtons()
        local useDefault = MidnightUISettings and MidnightUISettings.RaidFrames and MidnightUISettings.RaidFrames.useDefaultFrames
        if useDefault then
            SettingsControls.btnDefaultRaid:Hide()
            SettingsControls.btnCustomRaid:Show()
        else
            SettingsControls.btnCustomRaid:Hide()
            SettingsControls.btnDefaultRaid:Show()
        end
    end
    UpdateRaidModeButtons()
    SettingsControls.UpdateRaidModeButtons = UpdateRaidModeButtons

    pRaidFrames:HookScript("OnShow", function()
        UpdateRaidModeButtons()
    end)

    SettingsControls.chkRaidGroupBy = CreateFrame("CheckButton", nil, pRaidFrames, "InterfaceOptionsCheckButtonTemplate")
    SettingsControls.chkRaidGroupBy:SetPoint("TOPLEFT", PAGE_INSET_X, -92)
    SettingsControls.chkRaidGroupBy.Text:SetText("Lock To 5-Player Groups")
    SettingsControls.chkRaidGroupBy.Text:SetFontObject("GameFontNormalSmall")
    SettingsControls.chkRaidGroupBy:SetScript("OnClick", function(self)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.groupBy = (self:GetChecked() == true)
        if MidnightUISettings.RaidFrames.groupBy == true and (MidnightUISettings.RaidFrames.columns or 5) > 5 then
            MidnightUISettings.RaidFrames.columns = 5
        end
        if UpdateRaidColumnsSliderVisibility then UpdateRaidColumnsSliderVisibility() end
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    SettingsControls.chkRaidGroupColor = CreateFrame("CheckButton", nil, pRaidFrames, "InterfaceOptionsCheckButtonTemplate")
    SettingsControls.chkRaidGroupColor:SetPoint("TOPLEFT", PAGE_INSET_X, -116)
    SettingsControls.chkRaidGroupColor.Text:SetText("Colorize Frame Edges By Group")
    SettingsControls.chkRaidGroupColor.Text:SetFontObject("GameFontNormalSmall")
    SettingsControls.chkRaidGroupColor:SetScript("OnClick", function(self)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.colorByGroup = (self:GetChecked() == true)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    SettingsControls.chkRaidGroupBrackets = CreateFrame("CheckButton", nil, pRaidFrames, "InterfaceOptionsCheckButtonTemplate")
    SettingsControls.chkRaidGroupBrackets:SetPoint("TOPLEFT", PAGE_INSET_X, -140)
    SettingsControls.chkRaidGroupBrackets.Text:SetText("Show Group Brackets (Overlay)")
    SettingsControls.chkRaidGroupBrackets.Text:SetFontObject("GameFontNormalSmall")
    SettingsControls.chkRaidGroupBrackets:SetScript("OnClick", function(self)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.groupBrackets = (self:GetChecked() == true)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    local suppressRaidStyleCallback = false
    SettingsControls.ddRaidStyle = CreateDropdown(pRaidFrames, "Styling:", {"Rendered", "Simple"}, "Rendered", function(v)
        if suppressRaidStyleCallback then return end
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.layoutStyle = (v == "Simple") and "Simple" or "Detailed"
        -- Sync party + main tank styling with raid styling.
        local partyStyle = (v == "Simple") and "Simple" or "Rendered"
        if _G.MidnightUI_SetPartyStyle then
            _G.MidnightUI_SetPartyStyle(partyStyle)
        else
            if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
            MidnightUISettings.PartyFrames.style = partyStyle
            if ApplyPartyFramesSettings then M.ApplyPartyFramesSettings() end
        end
        if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
        MidnightUISettings.MainTankFrames.layoutStyle = (v == "Simple") and "Simple" or "Detailed"
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
        -- Update Party Styling dropdown immediately to match.
        if SettingsControls.ddPartyStyle then
            suppressPartyStyleCallback = true
            SettingsControls.ddPartyStyle.SetValue(nil, partyStyle)
            suppressPartyStyleCallback = false
        end
        if UpdatePartyStyleVisibility then UpdatePartyStyleVisibility() end
    end)
    SettingsControls.ddRaidStyle:SetPoint("TOPLEFT", PAGE_INSET_X, -180)
    
    SettingsControls.chkRaidShowPct = CreateFrame("CheckButton", nil, pRaidFrames, "InterfaceOptionsCheckButtonTemplate")
    SettingsControls.chkRaidShowPct:SetPoint("TOPLEFT", PAGE_INSET_X, -256)
    SettingsControls.chkRaidShowPct.Text:SetText("Show Health %")
    SettingsControls.chkRaidShowPct.Text:SetFontObject("GameFontNormalSmall")
    SettingsControls.chkRaidShowPct:SetScript("OnClick", function(self)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.showHealthPct = (self:GetChecked() == true)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
        if _G.MidnightUI_ApplyRaidFramesBarStyle then _G.MidnightUI_ApplyRaidFramesBarStyle() end
    end)
    
    SettingsControls.slRaidTextSize = CreateSlider(pRaidFrames, "Text Size", 6, 14, 1, 9, function(v)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.textSize = math.floor(v)
        if _G.MidnightUI_ApplyRaidFramesBarStyle then _G.MidnightUI_ApplyRaidFramesBarStyle() end
    end)

    SettingsControls.slRaidColumns = CreateSlider(pRaidFrames, "Units Per Row", 1, 40, 1, 5, function(v)
        SetRaidColumnsFromSlider(v, SettingsControls.slRaidColumns)
    end)
    SettingsControls.slRaidColumnsGrouped = CreateSlider(pRaidFrames, "Units Per Row", 1, 5, 1, 5, function(v)
        SetRaidColumnsFromSlider(v, SettingsControls.slRaidColumnsGrouped)
    end)

    SettingsControls.slRaidWidth = CreateSlider(pRaidFrames, "Raid Frame Width", 60, 220, 1, 92, function(v)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.width = math.floor(v)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    SettingsControls.slRaidHeight = CreateSlider(pRaidFrames, "Raid Frame Height", 16, 80, 1, 24, function(v)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        local maxH = _G.MidnightUI_GetRaidMaxHeight and _G.MidnightUI_GetRaidMaxHeight() or 80
        if v > maxH then
            if not SettingsControls.slRaidHeight._muiClamping then
                SettingsControls.slRaidHeight._muiClamping = true
                SettingsControls.slRaidHeight:SetValue(maxH)
                SettingsControls.slRaidHeight._muiClamping = false
            end
            return
        end
        MidnightUISettings.RaidFrames.height = math.floor(v)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    SettingsControls.slRaidSpacingX = CreateSlider(pRaidFrames, "Horizontal Spacing", 0, 20, 1, 6, function(v)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.spacingX = math.floor(v)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    SettingsControls.slRaidSpacingY = CreateSlider(pRaidFrames, "Vertical Spacing", 0, 20, 1, 4, function(v)
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        MidnightUISettings.RaidFrames.spacingY = math.floor(v)
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
    end)

    LayoutCardsTwoColumn({ SettingsControls.slRaidTextSize }, PAGE_INSET_X, -294, COL_GAP, ROW_GAP, 180)

    LayoutCardsTwoColumn({
        SettingsControls.slRaidColumns,
        SettingsControls.slRaidWidth,
        SettingsControls.slRaidHeight,
        SettingsControls.slRaidSpacingX,
        SettingsControls.slRaidSpacingY
    }, PAGE_INSET_X, -374, COL_GAP, ROW_GAP, 180)

    -- Group-locked mode uses a dedicated 1..5 Units Per Row slider.
    if SettingsControls.slRaidColumnsGrouped then
        SettingsControls.slRaidColumnsGrouped:ClearAllPoints()
        SettingsControls.slRaidColumnsGrouped:SetPoint("TOPLEFT", SettingsControls.slRaidColumns, "TOPLEFT", 0, 0)
        SettingsControls.slRaidColumnsGrouped:SetPoint("TOPRIGHT", SettingsControls.slRaidColumns, "TOPRIGHT", 0, 0)
    end

    UpdateRaidColumnsSliderVisibility = function()
        if not MidnightUISettings.RaidFrames then MidnightUISettings.RaidFrames = {} end
        local groupLocked = SettingsControls.chkRaidGroupBy and SettingsControls.chkRaidGroupBy:GetChecked() == true
        local maxCols = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
        if groupLocked then
            maxCols = math.min(maxCols, 5)
        end
        if SettingsControls.slRaidColumns and SettingsControls.slRaidColumns._slider and SettingsControls.slRaidColumns._slider.SetMinMaxValues then
            SettingsControls.slRaidColumns._slider:SetMinMaxValues(1, maxCols)
        end
        if SettingsControls.slRaidColumnsGrouped and SettingsControls.slRaidColumnsGrouped._slider and SettingsControls.slRaidColumnsGrouped._slider.SetMinMaxValues then
            SettingsControls.slRaidColumnsGrouped._slider:SetMinMaxValues(1, 5)
        end

        local value = math.floor(MidnightUISettings.RaidFrames.columns or 5)
        if value > maxCols then
            value = maxCols
            MidnightUISettings.RaidFrames.columns = value
        end
        if SettingsControls.slRaidColumns then
            SettingsControls.slRaidColumns._muiClamping = true
            SettingsControls.slRaidColumns:SetValue(value)
            SettingsControls.slRaidColumns._muiClamping = false
        end
        if SettingsControls.slRaidColumnsGrouped then
            SettingsControls.slRaidColumnsGrouped._muiClamping = true
            SettingsControls.slRaidColumnsGrouped:SetValue(math.min(value, 5))
            SettingsControls.slRaidColumnsGrouped._muiClamping = false
            if groupLocked then
                SettingsControls.slRaidColumns:Hide()
                SettingsControls.slRaidColumnsGrouped:Show()
            else
                SettingsControls.slRaidColumnsGrouped:Hide()
                SettingsControls.slRaidColumns:Show()
            end
        end
    end
    UpdateRaidColumnsSliderVisibility()
end

--- BuildMainTankTab: Constructs the Main Tank settings page with width/height/spacing/scale sliders.
-- @param raidTabs (table) - Sub-tab content frames
local function BuildMainTankTab(raidTabs)
    local pMainTank = raidTabs.MainTank

    local hMT1 = CreateSectionHeader(pMainTank, "Main Tank Frames")
    hMT1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

    SettingsControls.slMTWidth = CreateSlider(pMainTank, "Width", 160, 420, 2, 260, function(v)
        if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
        MidnightUISettings.MainTankFrames.width = math.floor(v)
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
    end)

    SettingsControls.slMTHeight = CreateSlider(pMainTank, "Height", 36, 120, 2, 58, function(v)
        if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
        MidnightUISettings.MainTankFrames.height = math.floor(v)
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
    end)

    SettingsControls.slMTSpacing = CreateSlider(pMainTank, "Spacing", 0, 20, 1, 6, function(v)
        if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
        MidnightUISettings.MainTankFrames.spacing = math.floor(v)
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
    end)

    SettingsControls.slMTScale = CreateSlider(pMainTank, "Scale %", 50, 150, 5, 100, function(v)
        if not MidnightUISettings.MainTankFrames then MidnightUISettings.MainTankFrames = {} end
        MidnightUISettings.MainTankFrames.scale = math.floor(v) / 100
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
    end)

    LayoutCardsTwoColumn({ SettingsControls.slMTWidth, SettingsControls.slMTHeight, SettingsControls.slMTSpacing, SettingsControls.slMTScale }, PAGE_INSET_X, -44, COL_GAP, ROW_GAP, 180)
end

--- BuildSecurityUnitFramesTab: Constructs the Security page with protected health %
--   toggle, saved-imports erase button, and tooltips.
-- @param securityTabs (table) - Sub-tab content frames
-- @param SettingsControls (table) - Shared controls table
-- @param UI_COLORS (table) - Theme color palette
local function BuildSecurityUnitFramesTab(securityTabs, SettingsControls, UI_COLORS)
    local pSecUnitFrames = securityTabs.UnitFrames
    local hSecUF = CreateSectionHeader(pSecUnitFrames, "Unit Frame Safety")
    hSecUF:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

    local chkSecretPct = CreateFrame("CheckButton", nil, pSecUnitFrames, "InterfaceOptionsCheckButtonTemplate")
    chkSecretPct:SetPoint("TOPLEFT", PAGE_INSET_X, -40)
    chkSecretPct.Text:SetText("Allow Protected Health %")
    chkSecretPct.Text:SetFontObject("GameFontNormalSmall")
    chkSecretPct:SetScript("OnClick", function(self)
        if not MidnightUISettings.General then MidnightUISettings.General = {} end
        MidnightUISettings.General.allowSecretHealthPercent = (self:GetChecked() == true)
        _G.MidnightUI_ForceHideHealthPct = (self:GetChecked() ~= true)
        if _G.MidnightUI_Debug then
            _G.MidnightUI_Debug("[Security] allowSecretHealthPercent=" .. tostring(MidnightUISettings.General.allowSecretHealthPercent))
        end
        if ApplyPlayerSettings then M.ApplyPlayerSettings() end
        if ApplyTargetSettings then M.ApplyTargetSettings() end
        if ApplyFocusSettings then M.ApplyFocusSettings() end
        if ApplyPartyFramesSettings then M.ApplyPartyFramesSettings() end
        if ApplyRaidFramesSettings then M.ApplyRaidFramesSettings() end
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
        if ApplyNameplateSettings then M.ApplyNameplateSettings() end
        if _G.MidnightUI_RefreshPlayerFrame then _G.MidnightUI_RefreshPlayerFrame() end
        if _G.MidnightUI_RefreshTargetFrame then _G.MidnightUI_RefreshTargetFrame() end
        if _G.MidnightUI_RefreshFocusFrame then _G.MidnightUI_RefreshFocusFrame() end
        if _G.MidnightUI_RefreshPartyFrames then _G.MidnightUI_RefreshPartyFrames() end
        if _G.MidnightUI_UpdateRaidVisibility then _G.MidnightUI_UpdateRaidVisibility() end
        if _G.MidnightUI_RefreshMainTankFrames then _G.MidnightUI_RefreshMainTankFrames() end
        if _G.MidnightUI_RefreshNameplates then _G.MidnightUI_RefreshNameplates() end
        if _G.MidnightUI_RefreshAllUnitFrames then
            C_Timer.After(0, _G.MidnightUI_RefreshAllUnitFrames)
        end
    end)

    AttachTooltip(chkSecretPct, "Allows percent text for protected enemy health values. May trigger Blizzard warnings.")

  local btnEraseImports = CreateFrame("Button", nil, pSecUnitFrames, "UIPanelButtonTemplate")
  btnEraseImports:SetSize(220, 26)
  btnEraseImports:SetPoint("TOPLEFT", chkSecretPct, "BOTTOMLEFT", -2, -16)
  btnEraseImports:SetText("Erase Saved Imports")
  StyleSettingsButton(btnEraseImports)
  btnEraseImports:SetScript("OnClick", function()
      if not MidnightUISettings then return end
      MidnightUISettings.Profiles = {}
      if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
          _G.MidnightUI_Diagnostics.LogDebugSource("Settings", "Security: cleared saved profile imports")
      elseif _G.MidnightUI_Debug then
          _G.MidnightUI_Debug("[Settings] Security: cleared saved profile imports")
      end
  end)

  AttachTooltip(btnEraseImports, "Clears all saved profile imports from this account.")

  SettingsControls.chkSecretPct = chkSecretPct
end

-- =========================================================================
--  PAGE: INTERFACE > GENERAL
-- =========================================================================
local pGenScroll, pGenContent = CreateScrollPage(interfaceTabs.General)
local pGen = pGenContent
pGenContent:SetHeight(580)

local hGeneralMove = CreateSectionHeader(pGen, "Layout & Movement")
hGeneralMove:SetPoint("TOPLEFT", PAGE_INSET_X, -4)

local btnUnlock = CreateFrame("Button", nil, pGen, "UIPanelButtonTemplate")
btnUnlock:SetSize(180, 32); btnUnlock:SetPoint("TOPLEFT", PAGE_INSET_X, -46)
btnUnlock:SetText("Unlock & Move UI")
StyleSettingsButton(btnUnlock)
btnUnlock:GetFontString():SetPoint("CENTER", 0, 0)
btnUnlock:SetScript("OnClick", function()
    if InCombatLockdown and InCombatLockdown() then
        if UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage("MidnightUI: Can't unlock overlays while in combat.", 1, 0.2, 0.2)
        end
        return
    end
    MidnightUISettings.Messenger.locked = false; M.ApplyMessengerSettings()
    M.DrawGrid(); M.GridFrame:Show(); M.MoveHUD:Show()
    if _G.MidnightUI_MoveHUDRestore then _G.MidnightUI_MoveHUDRestore:Hide() end
    if SettingsPanel then SettingsPanel:Hide() elseif InterfaceOptionsFrame then InterfaceOptionsFrame:Hide() end
end)

local btnOverlayMgr = CreateFrame("Button", nil, pGen, "UIPanelButtonTemplate")
btnOverlayMgr:SetSize(180, 32); btnOverlayMgr:SetPoint("TOPLEFT", btnUnlock, "BOTTOMLEFT", 0, -8)
btnOverlayMgr:SetText("Overlay Manager")
StyleSettingsButton(btnOverlayMgr)
btnOverlayMgr:GetFontString():SetPoint("CENTER", 0, 0)
btnOverlayMgr:SetScript("OnClick", function()
    if _G.MidnightUI_ToggleOverlayManager then
        _G.MidnightUI_ToggleOverlayManager()
    end
end)

local btnKeybind = CreateFrame("Button", nil, pGen, "UIPanelButtonTemplate")
btnKeybind:SetSize(180, 32); btnKeybind:SetPoint("LEFT", btnUnlock, "RIGHT", 8, 0)
btnKeybind:SetText("Edit Keybinds")
StyleSettingsButton(btnKeybind)
btnKeybind:GetFontString():SetPoint("CENTER", 0, 0)
btnKeybind:SetScript("OnClick", function() MidnightUI_EnterKeybindMode() end)

local hGeneralTheme = CreateSectionHeader(pGen, "Theme & Style")
hGeneralTheme:SetPoint("TOPLEFT", PAGE_INSET_X, -130)

SettingsControls.ddGlobalStyle = CreateDropdown(pGen, "Global UI Theme", {"Default", "Class Color", "Faithful", "Glass"}, MidnightUISettings.GlobalStyle or "Default", function(v)
    MidnightUISettings.GlobalStyle = v
    local abStyle = (v == "Default") and "Disabled" or v
    MidnightUISettings.ActionBars.globalStyle = abStyle
    if v == "Default" then
        for i = 1, 8 do
            local key = "bar"..i
            if MidnightUISettings.ActionBars[key] then
                MidnightUISettings.ActionBars[key].style = (DEFAULTS.ActionBars[key] and DEFAULTS.ActionBars[key].style) or "Class Color"
            end
        end
    end
    MidnightUISettings.Messenger.style = v
    MidnightUISettings.Minimap.infoBarStyle = v
    if abControls and abControls.globalStyle then abControls.globalStyle.SetValue(nil, abStyle) end
    if abControls and abControls.style and v == "Default" then
        local c = MidnightUISettings.ActionBars["bar"..currentBar]
        if c then abControls.style.SetValue(nil, c.style or "Class Color") end
    end
    if SettingsControls.ddChatStyle then SettingsControls.ddChatStyle.SetValue(nil, v) end
    if SettingsControls.ddInfoBarStyle then SettingsControls.ddInfoBarStyle.SetValue(nil, v) end
    M.ApplyGlobalTheme()
end)

local currentUnitBarStyle = (MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle) or "Gradient"
if currentUnitBarStyle ~= "Gradient" and currentUnitBarStyle ~= "Flat" then
    currentUnitBarStyle = "Gradient"
end
SettingsControls.ddUnitBarStyle = CreateDropdown(pGen, "Unit Frame Bar Style", {"Gradient", "Flat"}, currentUnitBarStyle, function(v)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameBarStyle = v
    if ApplySharedUnitFrameAppearance then
        M.ApplySharedUnitFrameAppearance()
    elseif ApplyUnitFrameBarStyle then
        M.ApplyUnitFrameBarStyle()
    end
end)

local unitFrameTextScaleOptions = {}
for scale = 50, 150, 5 do
    unitFrameTextScaleOptions[#unitFrameTextScaleOptions + 1] = tostring(scale)
end

local currentNameScale = tostring(math.max(50, math.min(150, tonumber(MidnightUISettings.General and MidnightUISettings.General.unitFrameNameScale) or 100)))
SettingsControls.ddUnitFrameNameScale = CreateDropdown(pGen, "Unit Frame Name Scale %", unitFrameTextScaleOptions, currentNameScale, function(v)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameNameScale = tonumber(v) or 100
    if ApplySharedUnitFrameAppearance then M.ApplySharedUnitFrameAppearance() end
end)

local currentValueScale = tostring(math.max(50, math.min(150, tonumber(MidnightUISettings.General and MidnightUISettings.General.unitFrameValueScale) or 100)))
SettingsControls.ddUnitFrameValueScale = CreateDropdown(pGen, "Unit Frame Value Scale %", unitFrameTextScaleOptions, currentValueScale, function(v)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameValueScale = tonumber(v) or 100
    if ApplySharedUnitFrameAppearance then M.ApplySharedUnitFrameAppearance() end
end)

local unitFrameOutlineByLabel = {
    ["None"] = "NONE",
    ["Outline"] = "OUTLINE",
    ["Thick Outline"] = "THICKOUTLINE",
}
local unitFrameOutlineByValue = {
    NONE = "None",
    OUTLINE = "Outline",
    THICKOUTLINE = "Thick Outline",
}
local currentUnitFrameOutline = (MidnightUISettings.General and MidnightUISettings.General.unitFrameTextOutline) or "OUTLINE"
currentUnitFrameOutline = unitFrameOutlineByValue[currentUnitFrameOutline] or "Outline"
SettingsControls.ddUnitFrameTextOutline = CreateDropdown(pGen, "Unit Frame Text Outline", {"Outline", "Thick Outline", "None"}, currentUnitFrameOutline, function(v)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameTextOutline = unitFrameOutlineByLabel[v] or "OUTLINE"
    if ApplySharedUnitFrameAppearance then M.ApplySharedUnitFrameAppearance() end
end)

LayoutCardsTwoColumn({
    SettingsControls.ddGlobalStyle,
    SettingsControls.ddUnitBarStyle,
    SettingsControls.ddUnitFrameNameScale,
    SettingsControls.ddUnitFrameValueScale,
    SettingsControls.ddUnitFrameTextOutline
}, PAGE_INSET_X, -160, COL_GAP, ROW_GAP, 180)

SettingsControls.chkShowUnitFrameLevelText = CreateFrame("CheckButton", nil, pGen, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkShowUnitFrameLevelText:SetPoint("TOPLEFT", SettingsControls.ddUnitFrameTextOutline, "BOTTOMLEFT", -2, -8)
SettingsControls.chkShowUnitFrameLevelText.Text:SetText("Show Unit Frame Level Text")
SettingsControls.chkShowUnitFrameLevelText.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkShowUnitFrameLevelText:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameHideLevelText = (self:GetChecked() ~= true)
    if ApplySharedUnitFrameAppearance then M.ApplySharedUnitFrameAppearance() end
end)

SettingsControls.chkShowUnitFramePowerText = CreateFrame("CheckButton", nil, pGen, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkShowUnitFramePowerText:SetPoint("TOPLEFT", SettingsControls.chkShowUnitFrameLevelText, "BOTTOMLEFT", 0, -8)
SettingsControls.chkShowUnitFramePowerText.Text:SetText("Show Unit Frame Power Text")
SettingsControls.chkShowUnitFramePowerText.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkShowUnitFramePowerText:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.unitFrameHidePowerText = (self:GetChecked() ~= true)
    if ApplySharedUnitFrameAppearance then M.ApplySharedUnitFrameAppearance() end
end)

  local btnResetOverlays = CreateFrame("Button", nil, pGen, "UIPanelButtonTemplate")
  btnResetOverlays:SetSize(180, 30); btnResetOverlays:SetPoint("TOPLEFT", SettingsControls.chkShowUnitFramePowerText, "BOTTOMLEFT", 2, -8)
  btnResetOverlays:SetText("Reset All Defaults")
  StyleSettingsButton(btnResetOverlays)

local hGeneralUtility = CreateSectionHeader(pGen, "Quality of Life")
hGeneralUtility:SetPoint("TOPLEFT", btnResetOverlays, "BOTTOMLEFT", 0, -14)

SettingsControls.chkCustomTooltips = CreateFrame("CheckButton", nil, pGen, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCustomTooltips:SetPoint("TOPLEFT", hGeneralUtility, "BOTTOMLEFT", -2, -8)
SettingsControls.chkCustomTooltips.Text:SetText("Use Custom Tooltips")
SettingsControls.chkCustomTooltips.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCustomTooltips:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.customTooltips = (self:GetChecked() == true)
end)

SettingsControls.chkForceCursorTooltips = CreateFrame("CheckButton", nil, pGen, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkForceCursorTooltips:SetPoint("TOPLEFT", SettingsControls.chkCustomTooltips, "BOTTOMLEFT", 0, -8)
SettingsControls.chkForceCursorTooltips.Text:SetText("Force Cursor Tooltips")
SettingsControls.chkForceCursorTooltips.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkForceCursorTooltips:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.forceCursorTooltips = (self:GetChecked() == true)
    if _G.MidnightUI_ApplyTooltipAnchorSettings then
        _G.MidnightUI_ApplyTooltipAnchorSettings()
    end
end)

-- =========================================================================
--  PAGE: INTERFACE > INVENTORY
-- =========================================================================
local pInventory = interfaceTabs.Inventory

local hInv = CreateSectionHeader(pInventory, "Inventory Settings")
hInv:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

SettingsControls.chkInventoryEnabled = CreateFrame("CheckButton", nil, pInventory, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkInventoryEnabled:SetPoint("TOPLEFT", PAGE_INSET_X, -40)
SettingsControls.chkInventoryEnabled.Text:SetText("Enable MidnightUI Inventory")
SettingsControls.chkInventoryEnabled.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkInventoryEnabled:SetScript("OnClick", function(self)
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    MidnightUISettings.Inventory.enabled = (self:GetChecked() == true)
    if _G.MidnightUI_ApplyInventorySettings then
        _G.MidnightUI_ApplyInventorySettings()
    end
end)

SettingsControls.chkSeparateBagsInv = CreateFrame("CheckButton", nil, pInventory, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkSeparateBagsInv:SetPoint("TOPLEFT", PAGE_INSET_X, -64)
SettingsControls.chkSeparateBagsInv.Text:SetText("Separate Inventory Bags")
SettingsControls.chkSeparateBagsInv.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkSeparateBagsInv:SetScript("OnClick", function(self)
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    MidnightUISettings.Inventory.separateBags = (self:GetChecked() == true)
    -- Close and reopen bags to apply the setting change
    if _G.MidnightBags then
        local wasOpen = _G.MidnightBagWindow and _G.MidnightBagWindow:IsShown()
        -- Check if any separate bag windows are open
        if not wasOpen then
            for i = 0, 5 do
                local win = _G["MidnightBagWindow" .. i]
                if win and win:IsShown() then
                    wasOpen = true
                    break
                end
            end
        end
        _G.MidnightBags:Close()
        if wasOpen then
            _G.MidnightBags:Open()
        end
    end
end)

local invDesc = pInventory:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
invDesc:SetPoint("TOPLEFT", SettingsControls.chkSeparateBagsInv, "BOTTOMLEFT", 2, -2)
invDesc:SetText("Shows each bag separately instead of combining them into one large bag.")
invDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

local hInvSize = CreateSectionHeader(pInventory, "Bag Size")
hInvSize:SetPoint("TOPLEFT", PAGE_INSET_X, -120)

SettingsControls.slBagSlotSize = CreateSlider(pInventory, "Slot Size", 20, 60, 1, 40, function(v)
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    MidnightUISettings.Inventory.bagSlotSize = math.floor(v)
    if _G.MidnightBags and _G.MidnightBags.UpdateLayout then
        _G.MidnightBags:UpdateLayout()
    end
end)

SettingsControls.slBagColumns = CreateSlider(pInventory, "Columns", 4, 20, 1, 12, function(v)
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    MidnightUISettings.Inventory.bagColumns = math.floor(v)
    if _G.MidnightBags and _G.MidnightBags.UpdateLayout then
        _G.MidnightBags:UpdateLayout()
    end
end)

SettingsControls.slBagSpacing = CreateSlider(pInventory, "Spacing", 0, 20, 1, 6, function(v)
    if not MidnightUISettings.Inventory then MidnightUISettings.Inventory = {} end
    MidnightUISettings.Inventory.bagSpacing = math.floor(v)
    if _G.MidnightBags and _G.MidnightBags.UpdateLayout then
        _G.MidnightBags:UpdateLayout()
    end
end)

LayoutCardsTwoColumn({
    SettingsControls.slBagSlotSize,
    SettingsControls.slBagColumns,
    SettingsControls.slBagSpacing
}, PAGE_INSET_X, -166, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: INTERFACE > QUESTING
-- =========================================================================
local pQuest = interfaceTabs.Questing

StaticPopupDialogs["MIDNIGHTUI_QUESTING_RELOAD"] = {
    text = "MidnightUI: A UI reload is required to apply Quest Interface changes.\n\nReload now?",
    button1 = "Reload UI",
    button2 = "Later",
    OnAccept = function() ReloadUI() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

SettingsControls.chkBlizzardQuesting = CreateFrame("CheckButton", nil, pQuest, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkBlizzardQuesting:SetPoint("TOPLEFT", PAGE_INSET_X, -4)
SettingsControls.chkBlizzardQuesting.Text:SetText("Enable Midnight Quest Interface")
SettingsControls.chkBlizzardQuesting.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkBlizzardQuesting:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    -- Setting is stored as Blizzard-mode for backward compatibility.
    MidnightUISettings.General.useBlizzardQuestingInterface = (self:GetChecked() ~= true)
    if self:GetChecked() ~= true and _G.MidnightUI_QuestInterface and _G.MidnightUI_QuestInterface.ForceClose then
        _G.MidnightUI_QuestInterface.ForceClose()
    end
    StaticPopup_Show("MIDNIGHTUI_QUESTING_RELOAD")
end)

SettingsControls.chkQuestCombat = CreateFrame("CheckButton", nil, pQuest, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkQuestCombat:SetPoint("TOPLEFT", SettingsControls.chkBlizzardQuesting, "BOTTOMLEFT", 0, -24)
SettingsControls.chkQuestCombat.Text:SetText("Hide Quest Objectives in Combat")
SettingsControls.chkQuestCombat.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkQuestCombat:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.hideQuestObjectivesInCombat = (self:GetChecked() == true)
    if _G.MidnightUI_ApplyQuestObjectivesVisibility then _G.MidnightUI_ApplyQuestObjectivesVisibility() end
end)

local questCombatDesc = pQuest:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
questCombatDesc:SetPoint("TOPLEFT", SettingsControls.chkQuestCombat, "BOTTOMLEFT", 2, -2)
questCombatDesc:SetText("Fades out the quest tracker while in combat.")
questCombatDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
questCombatDesc:SetText("")
questCombatDesc:SetHeight(1)
questCombatDesc:SetAlpha(0)

SettingsControls.chkQuestAlways = CreateFrame("CheckButton", nil, pQuest, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkQuestAlways:SetPoint("TOPLEFT", SettingsControls.chkQuestCombat, "BOTTOMLEFT", 0, -24)
SettingsControls.chkQuestAlways.Text:SetText("Always Hide Quest Objectives")
SettingsControls.chkQuestAlways.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkQuestAlways:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.hideQuestObjectivesAlways = (self:GetChecked() == true)
    if _G.MidnightUI_ApplyQuestObjectivesVisibility then _G.MidnightUI_ApplyQuestObjectivesVisibility() end
end)

SettingsControls.chkSuperTracked = CreateFrame("CheckButton", nil, pQuest, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkSuperTracked:SetPoint("TOPLEFT", SettingsControls.chkQuestAlways, "BOTTOMLEFT", 0, -24)
SettingsControls.chkSuperTracked.Text:SetText("Use Default Super Tracked Icon")
SettingsControls.chkSuperTracked.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkSuperTracked:SetScript("OnClick", function(self)
    if not MidnightUISettings.General then MidnightUISettings.General = {} end
    MidnightUISettings.General.useDefaultSuperTrackedIcon = (self:GetChecked() == true)
    if _G.MidnightUI_ApplySuperTrackedIcon then _G.MidnightUI_ApplySuperTrackedIcon() end
end)

SettingsControls.superTrackedDesc = pQuest:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SettingsControls.superTrackedDesc:SetPoint("TOPLEFT", SettingsControls.chkSuperTracked, "BOTTOMLEFT", 2, -2)
SettingsControls.superTrackedDesc:SetText("Revert to Blizzard's default Super Tracked icon.")
SettingsControls.superTrackedDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
SettingsControls.superTrackedDesc:SetText("")
SettingsControls.superTrackedDesc:SetHeight(1)
SettingsControls.superTrackedDesc:SetAlpha(0)

-- =========================================================================
--  PAGE: INTERFACE > CHAT
-- =========================================================================
local pChat = interfaceTabs.Chat
local pChatScroll, pChatContent = CreateScrollPage(pChat)
pChat = pChatContent
pChatContent:SetHeight(700)

local hChat1 = CreateSectionHeader(pChat, "Chat Options"); hChat1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

SettingsControls.ddChatStyle = CreateDropdown(pChat, "Chat Style", {"Default", "Class Color", "Faithful", "Glass", "Minimal"}, MidnightUISettings.Messenger.style or "Default", function(v)
    MidnightUISettings.Messenger.style = v; M.ApplyMessengerSettings()
end)
SettingsControls.ddChatStyle:SetPoint("TOPLEFT", PAGE_INSET_X, -42)

SettingsControls.cbTime = CreateFrame("CheckButton", nil, pChat, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.cbTime:SetPoint("TOPLEFT", PAGE_INSET_X, -110); SettingsControls.cbTime.Text:SetText("Show Timestamps")
SettingsControls.cbTime.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.cbTime:SetScript("OnClick", function(self) MidnightUISettings.Messenger.showTimestamp = self:GetChecked(); M.ApplyMessengerSettings() end)

SettingsControls.cbGlobal = CreateFrame("CheckButton", nil, pChat, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.cbGlobal:SetPoint("TOPLEFT", PAGE_INSET_X, -140); SettingsControls.cbGlobal.Text:SetText("Opt Out of Global Tab")
SettingsControls.cbGlobal.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.cbGlobal:SetChecked(MidnightUISettings.Messenger.hideGlobal == true)
SettingsControls.cbGlobal:SetScript("OnClick", function(self)
    MidnightUISettings.Messenger.hideGlobal = (self:GetChecked() == true)
    M.ApplyMessengerSettings()
    if _G.UpdateTabLayout then _G.UpdateTabLayout() end
end)

SettingsControls.cbLoginStates = CreateFrame("CheckButton", nil, pChat, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.cbLoginStates:SetPoint("TOPLEFT", PAGE_INSET_X, -170); SettingsControls.cbLoginStates.Text:SetText("Opt Out of Login States")
SettingsControls.cbLoginStates.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.cbLoginStates:SetChecked(MidnightUISettings.Messenger.hideLoginStates == true)
SettingsControls.cbLoginStates:SetScript("OnClick", function(self)
    MidnightUISettings.Messenger.hideLoginStates = (self:GetChecked() == true)
    M.ApplyMessengerSettings()
end)

SettingsControls.loginStatesDesc = pChat:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SettingsControls.loginStatesDesc:SetPoint("TOPLEFT", SettingsControls.cbLoginStates, "BOTTOMLEFT", 2, -2)
SettingsControls.loginStatesDesc:SetText("Hides 'has come online' / 'has gone offline' spam.")
SettingsControls.loginStatesDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
SettingsControls.loginStatesDesc:SetText("")
SettingsControls.loginStatesDesc:SetHeight(1)
SettingsControls.loginStatesDesc:SetAlpha(0)

-- NEW: Lock Chat Frame toggle
SettingsControls.cbMessengerLock = CreateFrame("CheckButton", nil, pChat, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.cbMessengerLock:SetPoint("TOPLEFT", SettingsControls.cbLoginStates, "BOTTOMLEFT", 0, -10)
SettingsControls.cbMessengerLock.Text:SetText("Lock Chat Frame")
SettingsControls.cbMessengerLock.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.cbMessengerLock:SetChecked(MidnightUISettings.Messenger.locked ~= false)
SettingsControls.cbMessengerLock:SetScript("OnClick", function(self)
    MidnightUISettings.Messenger.locked = (self:GetChecked() == true)
    M.ApplyMessengerSettings()
end)
AttachTooltip(SettingsControls.cbMessengerLock, "Locks the chat frame so it cannot be moved by accident.")

local function MakeChatModeButton(label, onClick)
    local b = CreateFrame("Button", nil, pChat, "UIPanelButtonTemplate")
    b:SetSize(180, 32)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    StyleSettingsButton(b)
    return b
end

SettingsControls.btnDefaultChat = MakeChatModeButton("Switch to Default (Reload)", function()
    if InCombatLockdown() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
        return
    end
    MidnightUISettings.Messenger.showDefaultChatInterface = true
    M.ApplyMessengerSettings()
    ReloadUI()
end)
SettingsControls.hChatMode = CreateSectionHeader(pChat, "Chat Mode")
SettingsControls.hChatMode:SetPoint("TOPLEFT", SettingsControls.cbMessengerLock, "BOTTOMLEFT", 0, -20)
SettingsControls.btnDefaultChat:SetPoint("TOPLEFT", SettingsControls.hChatMode, "BOTTOMLEFT", 0, -12)
SettingsControls.btnDefaultChat:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Switch to Blizzard Default", 1, 1, 1)
    GameTooltip:AddLine("Reloads the UI and enables Blizzard's default chat interface.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("Messenger custom chat will be disabled.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
SettingsControls.btnDefaultChat:SetScript("OnLeave", function() GameTooltip:Hide() end)

SettingsControls.btnResetChat = MakeChatModeButton("Reset Chat", function()
    if SlashCmdList and SlashCmdList["RESETCHAT"] then
        SlashCmdList["RESETCHAT"]("")
    elseif RunMacroText then
        RunMacroText("/resetchat")
    end
end)
SettingsControls.btnResetChat:SetPoint("LEFT", SettingsControls.btnDefaultChat, "RIGHT", 10, 0)
SettingsControls.btnResetChat:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Reset Blizzard Chat", 1, 1, 1)
    GameTooltip:AddLine("Runs /resetchat to restore the default Blizzard chat layout.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("Use this if the default chat looks or behaves incorrectly after switching modes.", 0.85, 0.85, 0.85, true)
    GameTooltip:AddLine("This resets Blizzard chat settings back to default values.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
SettingsControls.btnResetChat:SetScript("OnLeave", function() GameTooltip:Hide() end)

SettingsControls.btnCustomChat = MakeChatModeButton("Switch to Custom (Reload)", function()
    if InCombatLockdown() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
        return
    end
    MidnightUISettings.Messenger.showDefaultChatInterface = false
    M.ApplyMessengerSettings()
    ReloadUI()
end)
SettingsControls.btnCustomChat:SetPoint("TOPLEFT", SettingsControls.hChatMode, "BOTTOMLEFT", 0, -12)
SettingsControls.btnCustomChat:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Switch to Messenger", 1, 1, 1)
    GameTooltip:AddLine("Reloads the UI and enables Messenger custom chat.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("Blizzard's default chat interface will be disabled.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
SettingsControls.btnCustomChat:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdateChatModeButtons()
    local useDefault = MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.showDefaultChatInterface
    if useDefault then
        SettingsControls.btnDefaultChat:Hide()
        SettingsControls.btnCustomChat:Show()
    else
        SettingsControls.btnCustomChat:Hide()
        SettingsControls.btnDefaultChat:Show()
    end
end
UpdateChatModeButtons()
SettingsControls.UpdateChatModeButtons = UpdateChatModeButtons

local hChat2 = CreateSectionHeader(pChat, "Size & Opacity"); hChat2:SetPoint("TOPLEFT", SettingsControls.hChatMode, "BOTTOMLEFT", 0, -72)
SettingsControls.slMAlpha = CreateSlider(pChat, "Background Opacity", 0.1, 1.0, 0.05, 0.95, function(v) MidnightUISettings.Messenger.alpha = v; M.ApplyMessengerSettings() end)
SettingsControls.slMWidth = CreateSlider(pChat, "Width", 300, 1000, 10, 650, function(v) MidnightUISettings.Messenger.width = math.floor(v); M.ApplyMessengerSettings() end)
SettingsControls.slMHeight = CreateSlider(pChat, "Height", 200, 800, 10, 400, function(v) MidnightUISettings.Messenger.height = math.floor(v); M.ApplyMessengerSettings() end)
SettingsControls.slMScale = CreateSlider(pChat, "Scale %", 50, 200, 5, 100, function(v) MidnightUISettings.Messenger.scale = math.floor(v) / 100; M.ApplyMessengerSettings() end)
SettingsControls.slMFontSize = CreateSlider(pChat, "Font Size", 8, 24, 1, 14, function(v) MidnightUISettings.Messenger.fontSize = math.floor(v); M.ApplyMessengerSettings() end)
SettingsControls.slMTabSpacing = CreateSlider(pChat, "Tab Height Spacing", 28, 64, 1, 40, function(v)
    MidnightUISettings.Messenger.mainTabSpacing = math.floor(v)
    M.ApplyMessengerSettings()
    if _G.UpdateTabLayout then _G.UpdateTabLayout() end
end)
LayoutCardsTwoColumn({SettingsControls.slMAlpha, SettingsControls.slMWidth, SettingsControls.slMHeight, SettingsControls.slMScale, SettingsControls.slMFontSize, SettingsControls.slMTabSpacing}, PAGE_INSET_X, -420, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: INTERFACE > MINIMAP
-- =========================================================================
local pMap = interfaceTabs.Minimap
local hMap1 = CreateSectionHeader(pMap, "Minimap"); hMap1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

SettingsControls.chkCoords = CreateFrame("CheckButton", nil, pMap, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCoords:SetPoint("TOPLEFT", PAGE_INSET_X, -40); SettingsControls.chkCoords.Text:SetText("Show Coordinates")
SettingsControls.chkCoords.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCoords:SetScript("OnClick", function(self)
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    MidnightUISettings.Minimap.coordsEnabled = self:GetChecked()
    M.ApplyMinimapSettings()
end)

local mapDesc = pMap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mapDesc:SetPoint("TOPLEFT", SettingsControls.chkCoords, "BOTTOMLEFT", 2, -2)
mapDesc:SetText("Shows player coordinates (hidden in instances).")
mapDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
mapDesc:SetText("")
mapDesc:SetHeight(1)
mapDesc:SetAlpha(0)

SettingsControls.ddInfoBarStyle = CreateDropdown(pMap, "Info Bar Style", {"Default", "Class Color", "Faithful", "Glass"}, MidnightUISettings.Minimap.infoBarStyle or "Default", function(v)
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    MidnightUISettings.Minimap.infoBarStyle = v
    M.ApplyMinimapSettings()
end)
SettingsControls.ddInfoBarStyle:SetPoint("TOPLEFT", PAGE_INSET_X, -82)

SettingsControls.chkStatusBars = CreateFrame("CheckButton", nil, pMap, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkStatusBars:SetPoint("TOPLEFT", SettingsControls.ddInfoBarStyle, "BOTTOMLEFT", 0, -8)
SettingsControls.chkStatusBars.Text:SetText("Use Custom XP/Rep Bars")
SettingsControls.chkStatusBars.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkStatusBars:SetScript("OnClick", function(self)
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    MidnightUISettings.Minimap.useCustomStatusBars = (self:GetChecked() == true)
    M.ApplyMinimapSettings()
end)

local sbDesc = pMap:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
sbDesc:SetPoint("TOPLEFT", SettingsControls.chkStatusBars, "BOTTOMLEFT", 2, -2)
sbDesc:SetText("Use MidnightUI status bars under the Info Bar.")
sbDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
sbDesc:SetText("")
sbDesc:SetHeight(1)
sbDesc:SetAlpha(0)

-- NEW: Minimap Scale slider
SettingsControls.slMinimapScale = CreateSlider(pMap, "Scale %", 50, 200, 5, (MidnightUISettings.Minimap and MidnightUISettings.Minimap.scale) or 100, function(v)
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    MidnightUISettings.Minimap.scale = math.floor(v)
    M.ApplyMinimapSettings()
end)
SettingsControls.slMinimapScale:SetPoint("TOPLEFT", SettingsControls.chkStatusBars, "BOTTOMLEFT", 0, -18)
SettingsControls.slMinimapScale:SetWidth(380)

-- NEW: XP Bar enable toggle
SettingsControls.chkXPBarEnabled = CreateFrame("CheckButton", nil, pMap, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkXPBarEnabled:SetPoint("TOPLEFT", SettingsControls.slMinimapScale, "BOTTOMLEFT", 0, -12)
SettingsControls.chkXPBarEnabled.Text:SetText("Enable XP Bar")
SettingsControls.chkXPBarEnabled.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkXPBarEnabled:SetChecked(MidnightUISettings.XPBar and MidnightUISettings.XPBar.enabled ~= false)
SettingsControls.chkXPBarEnabled:SetScript("OnClick", function(self)
    if not MidnightUISettings.XPBar then MidnightUISettings.XPBar = {} end
    MidnightUISettings.XPBar.enabled = (self:GetChecked() == true)
    if _G.MidnightUI_RefreshStatusBars then _G.MidnightUI_RefreshStatusBars() end
    M.ApplyMinimapSettings()
end)
AttachTooltip(SettingsControls.chkXPBarEnabled, "Toggles the XP bar under the minimap info bar.")

-- NEW: Rep Bar enable toggle
SettingsControls.chkRepBarEnabled = CreateFrame("CheckButton", nil, pMap, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkRepBarEnabled:SetPoint("TOPLEFT", SettingsControls.chkXPBarEnabled, "BOTTOMLEFT", 0, -6)
SettingsControls.chkRepBarEnabled.Text:SetText("Enable Reputation Bar")
SettingsControls.chkRepBarEnabled.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkRepBarEnabled:SetChecked(MidnightUISettings.RepBar and MidnightUISettings.RepBar.enabled ~= false)
SettingsControls.chkRepBarEnabled:SetScript("OnClick", function(self)
    if not MidnightUISettings.RepBar then MidnightUISettings.RepBar = {} end
    MidnightUISettings.RepBar.enabled = (self:GetChecked() == true)
    if _G.MidnightUI_RefreshStatusBars then _G.MidnightUI_RefreshStatusBars() end
    M.ApplyMinimapSettings()
end)
AttachTooltip(SettingsControls.chkRepBarEnabled, "Toggles the reputation bar under the minimap info bar.")

-- =========================================================================
--  PAGE: INTERFACE > MARKET
-- =========================================================================
local pMark = interfaceTabs.Market
local hMark1 = CreateSectionHeader(pMark, "Keyword Watchlist"); hMark1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)
hMark1.line:SetPoint("RIGHT", -100, 0)

-- =========================================================================
--  ABOUT (MAIN TAB)
-- =========================================================================

local pAbout = pAboutMain
local pAboutContent = CreateFrame("Frame", nil, pAbout)
pAboutContent:SetPoint("TOPLEFT", PAGE_INSET_X, -2)
pAboutContent:SetPoint("TOPRIGHT", -PAGE_INSET_X, -2)
pAboutContent:SetPoint("BOTTOMLEFT", PAGE_INSET_X, 10)
pAboutContent:SetPoint("BOTTOMRIGHT", -PAGE_INSET_X, 10)

local function CreateAboutPanel(parent, h)
    local panel = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    panel:SetHeight(h)
    panel:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 10,
        insets = { left = 2, right = 2, top = 2, bottom = 2 },
    })
    panel:SetBackdropColor(0.05, 0.09, 0.16, 0.96)
    panel:SetBackdropBorderColor(UI_COLORS.cardBorder[1], UI_COLORS.cardBorder[2], UI_COLORS.cardBorder[3], 0.95)
    return panel
end

local function CreateAboutSocialTile(parent, side, r, g, b, tagText, titleText, bodyText, impactText, buttonText)
    local tile = CreateAboutPanel(parent, 1)
    if side == "LEFT" then
        tile:SetPoint("TOPLEFT", 0, 0)
        tile:SetPoint("BOTTOMLEFT", 0, 0)
        tile:SetPoint("RIGHT", parent, "CENTER", -8, 0)
    else
        tile:SetPoint("TOPRIGHT", 0, 0)
        tile:SetPoint("BOTTOMRIGHT", 0, 0)
        tile:SetPoint("LEFT", parent, "CENTER", 8, 0)
    end

    local accent = tile:CreateTexture(nil, "ARTWORK")
    accent:SetTexture("Interface\\Buttons\\WHITE8X8")
    accent:SetPoint("TOPLEFT", 1, -1)
    accent:SetPoint("TOPRIGHT", -1, -1)
    accent:SetHeight(34)
    accent:SetVertexColor(r, g, b, 0.92)

    local subBand = tile:CreateTexture(nil, "ARTWORK")
    subBand:SetTexture("Interface\\Buttons\\WHITE8X8")
    subBand:SetPoint("TOPLEFT", accent, "BOTTOMLEFT", 0, 0)
    subBand:SetPoint("TOPRIGHT", accent, "BOTTOMRIGHT", 0, 0)
    subBand:SetHeight(38)
    subBand:SetVertexColor(r, g, b, 0.24)

    local laneTop = tile:CreateTexture(nil, "BACKGROUND")
    laneTop:SetTexture("Interface\\Buttons\\WHITE8X8")
    laneTop:SetPoint("TOPLEFT", 1, -1)
    laneTop:SetPoint("TOPRIGHT", -1, -1)
    laneTop:SetHeight(74)
    laneTop:SetVertexColor(r, g, b, 0.16)

    local pulse = tile:CreateTexture(nil, "BACKGROUND")
    pulse:SetTexture("Interface\\Buttons\\WHITE8X8")
    pulse:SetPoint("TOPLEFT", 1, -1)
    pulse:SetPoint("BOTTOMRIGHT", -1, 1)
    pulse:SetVertexColor(r, g, b, 0.08)

    local tag = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    tag:SetPoint("LEFT", accent, "LEFT", 12, 0)
    tag:SetPoint("RIGHT", accent, "RIGHT", -12, 0)
    tag:SetPoint("TOP", accent, "TOP", 0, -1)
    tag:SetPoint("BOTTOM", accent, "BOTTOM", 0, 1)
    tag:SetJustifyH("CENTER")
    if tag.SetJustifyV then tag:SetJustifyV("MIDDLE") end
    tag:SetText(tagText)
    tag:SetTextColor(0.97, 0.98, 1.00)

    local title = tile:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", subBand, "LEFT", 12, 0)
    title:SetPoint("RIGHT", subBand, "RIGHT", -12, 0)
    title:SetPoint("TOP", subBand, "TOP", 0, -1)
    title:SetPoint("BOTTOM", subBand, "BOTTOM", 0, 1)
    title:SetJustifyH("CENTER")
    if title.SetJustifyV then title:SetJustifyV("MIDDLE") end
    title:SetText(titleText)
    title:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])

    local impact = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    impact:SetPoint("BOTTOMLEFT", 12, 58)
    impact:SetPoint("BOTTOMRIGHT", -12, 58)
    impact:SetJustifyH("LEFT")
    impact:SetText(impactText)
    impact:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])

    local body = tile:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", 12, -86)
    body:SetPoint("TOPRIGHT", -12, -86)
    body:SetPoint("BOTTOMLEFT", impact, "TOPLEFT", 0, 6)
    body:SetPoint("BOTTOMRIGHT", impact, "TOPRIGHT", 0, 6)
    body:SetJustifyH("LEFT")
    if body.SetJustifyV then body:SetJustifyV("MIDDLE") end
    body:SetText(bodyText)
    body:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

    local button = CreateFrame("Button", nil, tile, "UIPanelButtonTemplate")
    button:SetPoint("BOTTOMLEFT", 12, 12)
    button:SetPoint("BOTTOMRIGHT", -12, 12)
    button:SetHeight(32)
    button:SetText(buttonText)
    StyleSettingsButton(button)

    local aura = button:CreateTexture(nil, "BACKGROUND")
    aura:SetTexture("Interface\\Buttons\\WHITE8X8")
    aura:SetPoint("TOPLEFT", 1, -1)
    aura:SetPoint("BOTTOMRIGHT", -1, 1)
    aura:SetVertexColor(r, g, b, 0.16)
    button:HookScript("OnEnter", function()
        aura:SetVertexColor(r, g, b, 0.26)
    end)
    button:HookScript("OnLeave", function()
        aura:SetVertexColor(r, g, b, 0.16)
    end)

    return tile, button, pulse
end

do -- scope About page locals to avoid 200-local-variable limit in BuildSettingsUI

local aboutTitle = pAboutContent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
aboutTitle:SetPoint("TOPLEFT", 0, -8)
aboutTitle:SetText("Community & Links")
aboutTitle:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])

local aboutLead = pAboutContent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
aboutLead:SetPoint("TOPLEFT", 0, -34)
aboutLead:SetPoint("TOPRIGHT", 0, -34)
aboutLead:SetJustifyH("LEFT")
aboutLead:SetText("MidnightUI is free on CurseForge. Join Discord for feedback and visit mpi.atyzi.com for your Mythic+ performance dashboard.")
aboutLead:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

-- ── Tile 1: MPI Companion ──
local mpiTile, btnMPI = CreateAboutSocialTile(
    pAboutContent,
    "LEFT",
    0.20, 0.80, 0.40,
    "MYTHIC+ PERFORMANCE",
    "Install |cff33cc66MPI Companion|r",
    "A free desktop app that scores every player in your group after each M+ run and shares those scores with the community. The more players who install it, the more accurate scores become.",
    "|cff33cc66Helps the community build better groups.|r",
    "Download Companion"
)
mpiTile:ClearAllPoints()
mpiTile:SetPoint("TOPLEFT", pAboutContent, "TOPLEFT", 0, -62)
mpiTile:SetPoint("RIGHT", pAboutContent, "CENTER", -8, 0)
mpiTile:SetHeight(220)

-- ── Tile 2: Discord ──
local discordTile, btnDiscord = CreateAboutSocialTile(
    pAboutContent,
    "RIGHT",
    0.32, 0.69, 1.00,
    "JOIN THE DISCORD",
    "Be part of the |cff53b8ffMidnightUI|r community",
    "Report bugs, request features, get help from other players, and stay up to date with releases. Members also get access to giveaways and exclusive early previews.",
    "|cff53b8ffYour feedback directly shapes every update.|r",
    "Join Discord"
)
discordTile:ClearAllPoints()
discordTile:SetPoint("TOPLEFT", pAboutContent, "TOP", 8, -62)
discordTile:SetPoint("TOPRIGHT", pAboutContent, "TOPRIGHT", 0, -62)
discordTile:SetHeight(220)

-- ── Tile 3: CurseForge (full width below) ──
local curseforgeTile, btnCurseForge = CreateAboutSocialTile(
    pAboutContent,
    "LEFT",
    1.00, 0.56, 0.28,
    "RATE & REVIEW",
    "Help other players find MidnightUI on |cffff9650CurseForge|r",
    "Leave a rating or review to help other players discover the addon. CurseForge is also the best place to grab updates.",
    "|cffff9650Your review helps the addon reach more players.|r",
    "Open CurseForge"
)
curseforgeTile:ClearAllPoints()
curseforgeTile:SetPoint("TOPLEFT", mpiTile, "BOTTOMLEFT", 0, -12)
curseforgeTile:SetPoint("TOPRIGHT", discordTile, "BOTTOMRIGHT", 0, -12)
curseforgeTile:SetHeight(160)

btnMPI:SetScript("OnClick", function() OpenAboutURL(ABOUT_MPI_URL) end)
btnDiscord:SetScript("OnClick", function() OpenAboutURL(ABOUT_DISCORD_URL) end)
btnCurseForge:SetScript("OnClick", function() OpenAboutURL(ABOUT_CURSEFORGE_URL) end)


end -- close About page do...end scope

-- =========================================================================
--  OTHER > PROFILES
-- =========================================================================

local pProfiles = otherTabs.Profiles
local hProf = CreateSectionHeader(pProfiles, "Profiles")
hProf:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

local pDesc = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pDesc:SetPoint("TOPLEFT", hProf, "BOTTOMLEFT", 0, -6)
pDesc:SetPoint("RIGHT", -PAGE_INSET_X, 0)
pDesc:SetJustifyH("LEFT")
pDesc:SetText("Move your MidnightUI layout with a clear 3-step flow: code transfer, character copy, then optional wizard.")
pDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

local hProfCode = CreateSectionHeader(pProfiles, "1) Transfer With Code")
hProfCode:SetPoint("TOPLEFT", pDesc, "BOTTOMLEFT", 0, -14)
hProfCode.line:SetPoint("RIGHT", -100, 0)

local codeDesc = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
codeDesc:SetPoint("TOPLEFT", hProfCode, "BOTTOMLEFT", 0, -6)
codeDesc:SetPoint("RIGHT", -PAGE_INSET_X, 0)
codeDesc:SetJustifyH("LEFT")
codeDesc:SetText("Import from a pasted profile string, or export your current setup to share.")
codeDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

local btnImportProfile = CreateFrame("Button", nil, pProfiles, "UIPanelButtonTemplate")
btnImportProfile:SetPoint("TOPLEFT", codeDesc, "BOTTOMLEFT", 0, -8)
btnImportProfile:SetSize(188, 28)
btnImportProfile:SetText("Import Profile")
btnImportProfile:SetScript("OnClick", function()
    if _G.MidnightUI_ShowProfileImport then
        _G.MidnightUI_ShowProfileImport()
    end
end)
StyleSettingsButton(btnImportProfile)

local btnExportProfile = CreateFrame("Button", nil, pProfiles, "UIPanelButtonTemplate")
btnExportProfile:SetPoint("LEFT", btnImportProfile, "RIGHT", 10, 0)
btnExportProfile:SetSize(188, 28)
btnExportProfile:SetText("Export Current")
btnExportProfile:SetScript("OnClick", function()
    if _G.MidnightUI_ShowProfileExport then
        _G.MidnightUI_ShowProfileExport()
    end
end)
StyleSettingsButton(btnExportProfile)

local function ResolveSettingsProfileOptions()
    local profileAPI = _G.MidnightUI_Profiles
    if not profileAPI or not profileAPI.GetProfileOptions or not profileAPI.GetCharacterKey then
        return {}
    end
    return profileAPI.GetProfileOptions(profileAPI.GetCharacterKey()) or {}
end

local hProfCharacter = CreateSectionHeader(pProfiles, "2) Copy From Another Character")
hProfCharacter:SetPoint("TOPLEFT", btnImportProfile, "BOTTOMLEFT", 0, -16)
hProfCharacter.line:SetPoint("RIGHT", -100, 0)

local charDesc = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
charDesc:SetPoint("TOPLEFT", hProfCharacter, "BOTTOMLEFT", 0, -6)
charDesc:SetPoint("RIGHT", -PAGE_INSET_X, 0)
charDesc:SetJustifyH("LEFT")
charDesc:SetText("Pick another character profile, then import it directly.")
charDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

local profileDropdown = CreateFrame("Frame", "MidnightUI_SettingsProfileDropdown", pProfiles, "UIDropDownMenuTemplate")
profileDropdown:SetPoint("TOPLEFT", charDesc, "BOTTOMLEFT", -8, -6)
UIDropDownMenu_SetWidth(profileDropdown, 306)
UIDropDownMenu_SetText(profileDropdown, "Choose character profile")

local profileDetails = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
profileDetails:SetPoint("TOPLEFT", profileDropdown, "BOTTOMLEFT", 8, -4)
profileDetails:SetPoint("RIGHT", -PAGE_INSET_X, 0)
profileDetails:SetJustifyH("LEFT")
profileDetails:SetText("")
profileDetails:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

local btnImportSelected = CreateFrame("Button", nil, pProfiles, "UIPanelButtonTemplate")
btnImportSelected:SetPoint("TOPLEFT", profileDetails, "BOTTOMLEFT", 0, -8)
btnImportSelected:SetSize(188, 28)
btnImportSelected:SetText("Import Selected")
StyleSettingsButton(btnImportSelected)

local btnRefreshProfiles = CreateFrame("Button", nil, pProfiles, "UIPanelButtonTemplate")
btnRefreshProfiles:SetPoint("LEFT", btnImportSelected, "RIGHT", 10, 0)
btnRefreshProfiles:SetSize(188, 28)
btnRefreshProfiles:SetText("Refresh List")
StyleSettingsButton(btnRefreshProfiles)

local profileStatus = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
profileStatus:SetPoint("TOPLEFT", btnImportSelected, "BOTTOMLEFT", 0, -8)
profileStatus:SetPoint("RIGHT", -PAGE_INSET_X, 0)
profileStatus:SetJustifyH("LEFT")
profileStatus:SetText("")
profileStatus:SetTextColor(1, 0.4, 0.4)

local profileOptions = {}
local selectedProfileKey = nil

local function SetProfileStatus(text, r, g, b)
    profileStatus:SetText(text or "")
    profileStatus:SetTextColor(r or 1, g or 0.4, b or 0.4)
end

local function RefreshSettingsProfileDropdown()
    profileOptions = ResolveSettingsProfileOptions()
    selectedProfileKey = nil
    SetProfileStatus("")
    UIDropDownMenu_SetText(profileDropdown, "Choose character profile")
    profileDetails:SetText(#profileOptions == 0 and "No other character profiles found yet. Log in once on another character to list it here." or "")

    UIDropDownMenu_Initialize(profileDropdown, function()
        if #profileOptions == 0 then
            local info = UIDropDownMenu_CreateInfo()
            info.text = "No other character profiles found"
            info.disabled = true
            UIDropDownMenu_AddButton(info)
            return
        end
        for _, entry in ipairs(profileOptions) do
            local info = UIDropDownMenu_CreateInfo()
            info.text = entry.label
            info.func = function()
                selectedProfileKey = entry.key
                UIDropDownMenu_SetText(profileDropdown, entry.label)
                local created = entry.createdAt and date("%b %d, %Y", entry.createdAt) or "Unknown"
                profileDetails:SetText("Selected: " .. entry.label .. "  |  Saved: " .. created)
            end
            UIDropDownMenu_AddButton(info)
        end
    end)
end

btnImportSelected:SetScript("OnClick", function()
    SetProfileStatus("")
    if not selectedProfileKey then
        SetProfileStatus("Pick a character profile first.")
        return
    end
    local profileAPI = _G.MidnightUI_Profiles
    if not profileAPI or not profileAPI.ImportProfileFromKey then
        SetProfileStatus("Profiles API is missing.")
        return
    end
    local ok, err = profileAPI.ImportProfileFromKey(selectedProfileKey)
    if ok then
        SetProfileStatus("Import successful.", UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
        return
    end
    SetProfileStatus("Import failed. Check Diagnostics.")
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
        _G.MidnightUI_Diagnostics.LogDebugSource("Settings/Profile", "Import from dropdown failed: " .. tostring(err))
    end
end)

btnRefreshProfiles:SetScript("OnClick", RefreshSettingsProfileDropdown)
pProfiles:HookScript("OnShow", RefreshSettingsProfileDropdown)

local hProfWizard = CreateSectionHeader(pProfiles, "3) Setup Wizard")
hProfWizard:SetPoint("TOPLEFT", profileStatus, "BOTTOMLEFT", 0, -16)
hProfWizard.line:SetPoint("RIGHT", -100, 0)

local btnWelcome = CreateFrame("Button", nil, pProfiles, "UIPanelButtonTemplate")
btnWelcome:SetPoint("TOPLEFT", hProfWizard, "BOTTOMLEFT", 0, -8)
btnWelcome:SetSize(386, 28)
btnWelcome:SetText("Open Welcome Wizard")
btnWelcome:SetScript("OnClick", function()
    if _G.MidnightUI_ShowWelcome then
        _G.MidnightUI_ShowWelcome(true)
    end
end)
StyleSettingsButton(btnWelcome)

local pHint = pProfiles:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
pHint:SetPoint("TOPLEFT", btnWelcome, "BOTTOMLEFT", 0, -10)
pHint:SetPoint("TOPRIGHT", -PAGE_INSET_X, -10)
pHint:SetText("Use 1 for share codes, 2 for fast character-to-character copy, and 3 if you want guided setup.")
pHint:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

-- =========================================================================
--  OTHER > DIAGNOSTICS
-- =========================================================================

local pDiag = otherTabs.Diagnostics
local hDiag1 = CreateSectionHeader(pDiag, "Diagnostics"); hDiag1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

local btnOpenDiag = CreateFrame("Button", nil, pDiag, "UIPanelButtonTemplate")
btnOpenDiag:SetPoint("TOPLEFT", PAGE_INSET_X, -42)
btnOpenDiag:SetSize(200, 24)
btnOpenDiag:SetText("Open Diagnostics Menu")
btnOpenDiag:SetScript("OnClick", function()
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
end)

SettingsControls.chkDebugHidden = CreateFrame("CheckButton", nil, pDiag, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkDebugHidden:SetPoint("TOPLEFT", btnOpenDiag, "BOTTOMLEFT", -2, -14)
SettingsControls.chkDebugHidden.Text:SetText("Keep Debug Hidden")
SettingsControls.chkDebugHidden.Text:SetFontObject("GameFontNormalSmall")
  SettingsControls.chkDebugHidden:SetScript("OnClick", function(self)
      if not MidnightUISettings or not MidnightUISettings.Messenger then return end
      MidnightUISettings.Messenger.keepDebugHidden = self:GetChecked() == true
      if _G.UpdateTabLayout then _G.UpdateTabLayout() end
  end)
  
  local chkDebugSub = pDiag:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  chkDebugSub:SetPoint("TOPLEFT", SettingsControls.chkDebugHidden.Text, "BOTTOMLEFT", 0, -2)
  chkDebugSub:SetText("Keeps the Debug tab hidden. Access only via Settings > Other > Diagnostics.")
  chkDebugSub:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])


-- =========================================================================
--  PAGE: OTHER > SECURITY
-- =========================================================================
BuildSecurityUnitFramesTab(otherTabs, SettingsControls, UI_COLORS)

BuildMainTankTab(raidTabs)

local mDesc = pMark:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mDesc:SetPoint("TOPLEFT", PAGE_INSET_X, -28)
mDesc:SetText("Messages containing these keywords are copied to the Market window.")
mDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])
mDesc:SetText("")
mDesc:SetHeight(1)
mDesc:SetAlpha(0)

local mCount = pMark:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
mCount:SetPoint("RIGHT", hMark1, "RIGHT", -10, 0); mCount:SetText("0/8 Active")

local mBox = CreateFrame("Frame", nil, pMark, "BackdropTemplate")
mBox:SetSize(440, 280); mBox:SetPoint("TOPLEFT", PAGE_INSET_X, -48)
mBox:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 14, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
mBox:SetBackdropColor(0.08, 0.08, 0.12, 0.6); mBox:SetBackdropBorderColor(UI_COLORS.cardBorder[1], UI_COLORS.cardBorder[2], UI_COLORS.cardBorder[3], 1)

local mInput = CreateFrame("EditBox", nil, pMark, "InputBoxTemplate")
mInput:SetPoint("TOPLEFT", mBox, "BOTTOMLEFT", 0, -10); mInput:SetSize(240, 28); mInput:SetAutoFocus(false)
local mAdd = CreateFrame("Button", nil, pMark, "UIPanelButtonTemplate"); mAdd:SetPoint("LEFT", mInput, "RIGHT", 8, 0); mAdd:SetSize(90, 28); mAdd:SetText("Add Keyword")
StyleSettingsButton(mAdd)
local mRows = {}
local function UpdMarket()
    if not MessengerDB or not MessengerDB.MarketWatchList then return end
    for _, r in ipairs(mRows) do r:Hide() end
    local c, idx = 0, 0
    for k in pairs(MessengerDB.MarketWatchList) do c = c + 1 end
    mCount:SetText(c.."/8 Active")
    for k in pairs(MessengerDB.MarketWatchList) do
        idx = idx + 1
        local r = mRows[idx]
        if not r then
            r = CreateFrame("Frame", nil, mBox)
            r:SetSize(420, 24)
            r.bg = r:CreateTexture(nil, "BACKGROUND"); r.bg:SetAllPoints()
            r.bg:SetColorTexture(0.12, 0.12, 0.18, 0.5)
            r.t = r:CreateFontString(nil, "OVERLAY", "GameFontHighlight"); r.t:SetPoint("LEFT", 10, 0)
            r.b = CreateFrame("Button", nil, r); r.b:SetSize(18,18); r.b:SetPoint("RIGHT", -5, 0)
            r.b.x = r.b:CreateFontString(nil, "OVERLAY", "GameFontNormal"); r.b.x:SetPoint("CENTER", 0, 0); r.b.x:SetText("X"); r.b.x:SetTextColor(0.5, 0.5, 0.5)
            r.b:SetScript("OnEnter", function(self) self.x:SetTextColor(1, 0.2, 0.2) end)
            r.b:SetScript("OnLeave", function(self) self.x:SetTextColor(0.5, 0.5, 0.5) end)
            r.b:SetScript("OnClick", function(s) MessengerDB.MarketWatchList[s:GetParent().k] = nil; UpdMarket() end)
            mRows[idx] = r
        end
        r:SetPoint("TOPLEFT", 10, -10 - ((idx-1)*26))
        r.t:SetText(k); r.k = k; r:Show()
    end
end
mAdd:SetScript("OnClick", function() local t = mInput:GetText(); if t and t~="" and MessengerDB then MessengerDB.MarketWatchList[t]=true; mInput:SetText(""); UpdMarket() end end)

-- =========================================================================
--  PAGE: PLAYER > CORE
-- =========================================================================
local pPlayCore = playerTabs.Core
local pPlayAuras = playerTabs.Auras
local pPlayDebuffs = playerTabs.Debuffs
local pPlayConsumables = playerTabs.Consumables

SettingsControls.chkPlay = CreateFrame("CheckButton", nil, pPlayCore, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkPlay:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkPlay.Text:SetText("Enable Player Frame")
SettingsControls.chkPlay.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkPlay:SetScript("OnClick", function(self) MidnightUISettings.PlayerFrame.enabled = self:GetChecked(); M.ApplyPlayerSettings() end)

SettingsControls.chkPlayTooltip = CreateFrame("CheckButton", nil, pPlayCore, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkPlayTooltip:SetPoint("LEFT", SettingsControls.chkPlay, "RIGHT", 180, 0); SettingsControls.chkPlayTooltip.Text:SetText("Custom Tooltip")
SettingsControls.chkPlayTooltip.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkPlayTooltip:SetScript("OnClick", function(self) MidnightUISettings.PlayerFrame.customTooltip = (self:GetChecked() == true) end)

SettingsControls.slPScale = CreateSlider(pPlayCore, "Scale %", 50, 200, 5, 100, function(v) MidnightUISettings.PlayerFrame.scale = math.floor(v); M.ApplyPlayerSettings() end)
SettingsControls.slPWidth = CreateSlider(pPlayCore, "Width", 200, 600, 5, 420, function(v) MidnightUISettings.PlayerFrame.width = math.floor(v); M.ApplyPlayerSettings() end)
SettingsControls.slPHeight = CreateSlider(pPlayCore, "Height", 50, 150, 2, 72, function(v) MidnightUISettings.PlayerFrame.height = math.floor(v); M.ApplyPlayerSettings() end)
SettingsControls.slPAlpha = CreateSlider(pPlayCore, "Opacity", 0.1, 1.0, 0.05, 0.95, function(v) MidnightUISettings.PlayerFrame.alpha = v; M.ApplyPlayerSettings() end)
LayoutCardsTwoColumn({SettingsControls.slPScale, SettingsControls.slPWidth, SettingsControls.slPHeight, SettingsControls.slPAlpha}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: PLAYER > AURAS (BUFFS)
-- =========================================================================
SettingsControls.chkAuras = CreateFrame("CheckButton", nil, pPlayAuras, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkAuras:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkAuras.Text:SetText("Show Buff Bar")
SettingsControls.chkAuras.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkAuras:SetScript("OnClick", function(self)
    if not MidnightUISettings.PlayerFrame.auras then MidnightUISettings.PlayerFrame.auras = {} end
    MidnightUISettings.PlayerFrame.auras.enabled = self:GetChecked()
    if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
end)

SettingsControls.slAuraScale = CreateSlider(pPlayAuras, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.PlayerFrame.auras then MidnightUISettings.PlayerFrame.auras = {} end
    MidnightUISettings.PlayerFrame.auras.scale = math.floor(v)
    if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
end)
SettingsControls.slAuraAlpha = CreateSlider(pPlayAuras, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.PlayerFrame.auras then MidnightUISettings.PlayerFrame.auras = {} end
    MidnightUISettings.PlayerFrame.auras.alpha = v
    if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
end)
SettingsControls.slAuraMax = CreateSlider(pPlayAuras, "Max Shown", 1, 32, 1, 32, function(v)
    if not MidnightUISettings.PlayerFrame.auras then MidnightUISettings.PlayerFrame.auras = {} end
    MidnightUISettings.PlayerFrame.auras.maxShown = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slAuraScale, SettingsControls.slAuraAlpha, SettingsControls.slAuraMax}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

SettingsControls.ddAuraAlign = CreateDropdown(pPlayAuras, "Position", {"Left", "Center", "Right"}, "Right", function(v)
    if not MidnightUISettings.PlayerFrame.auras then MidnightUISettings.PlayerFrame.auras = {} end
    MidnightUISettings.PlayerFrame.auras.alignment = v
    if _G.MidnightUI_ApplyPlayerAuraSettings then _G.MidnightUI_ApplyPlayerAuraSettings() end
end)
SettingsControls.ddAuraAlign:ClearAllPoints()
SettingsControls.ddAuraAlign:SetPoint("TOPLEFT", SettingsControls.slAuraMax or SettingsControls.slAuraScale, "BOTTOMLEFT", 0, -18)
if SettingsControls.slAuraScale and SettingsControls.slAuraScale.GetWidth then
    SettingsControls.ddAuraAlign:SetWidth(SettingsControls.slAuraScale:GetWidth())
end

-- =========================================================================
--  PAGE: PLAYER > DEBUFFS
-- =========================================================================
SettingsControls.chkDebuffs = CreateFrame("CheckButton", nil, pPlayDebuffs, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkDebuffs:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkDebuffs.Text:SetText("Show Debuff Bar")
SettingsControls.chkDebuffs.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkDebuffs:SetScript("OnClick", function(self)
    if not MidnightUISettings.PlayerFrame.debuffs then MidnightUISettings.PlayerFrame.debuffs = {} end
    MidnightUISettings.PlayerFrame.debuffs.enabled = self:GetChecked()
    if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
end)

SettingsControls.slDebuffScale = CreateSlider(pPlayDebuffs, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.PlayerFrame.debuffs then MidnightUISettings.PlayerFrame.debuffs = {} end
    MidnightUISettings.PlayerFrame.debuffs.scale = math.floor(v)
    if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
end)
SettingsControls.slDebuffAlpha = CreateSlider(pPlayDebuffs, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.PlayerFrame.debuffs then MidnightUISettings.PlayerFrame.debuffs = {} end
    MidnightUISettings.PlayerFrame.debuffs.alpha = v
    if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
end)
SettingsControls.slDebuffMax = CreateSlider(pPlayDebuffs, "Max Shown", 1, 16, 1, 16, function(v)
    if not MidnightUISettings.PlayerFrame.debuffs then MidnightUISettings.PlayerFrame.debuffs = {} end
    MidnightUISettings.PlayerFrame.debuffs.maxShown = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slDebuffScale, SettingsControls.slDebuffAlpha, SettingsControls.slDebuffMax}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

SettingsControls.ddDebuffAlign = CreateDropdown(pPlayDebuffs, "Position", {"Left", "Center", "Right"}, "Right", function(v)
    if not MidnightUISettings.PlayerFrame.debuffs then MidnightUISettings.PlayerFrame.debuffs = {} end
    MidnightUISettings.PlayerFrame.debuffs.alignment = v
    if _G.MidnightUI_ApplyPlayerDebuffSettings then _G.MidnightUI_ApplyPlayerDebuffSettings() end
end)
SettingsControls.ddDebuffAlign:ClearAllPoints()
SettingsControls.ddDebuffAlign:SetPoint("TOPLEFT", SettingsControls.slDebuffMax or SettingsControls.slDebuffScale, "BOTTOMLEFT", 0, -18)
if SettingsControls.slDebuffScale and SettingsControls.slDebuffScale.GetWidth then
    SettingsControls.ddDebuffAlign:SetWidth(SettingsControls.slDebuffScale:GetWidth())
end

-- =========================================================================
--  PLAYER: PET FRAME (new missing section)
-- =========================================================================
do
local pPetFrame = playerTabs.PetFrame

SettingsControls.chkPetFrameEnabled = CreateToggleControlCard(pPetFrame, "Enable Pet Frame", "Toggles the custom Pet unit frame.", MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.enabled ~= false, function(checked)
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    MidnightUISettings.PetFrame.enabled = checked
    if _G.MidnightUI_ApplyPetSettings then _G.MidnightUI_ApplyPetSettings() end
end)
SettingsControls.chkPetFrameEnabled:SetPoint("TOPLEFT", PAGE_INSET_X, -4)
SettingsControls.chkPetFrameEnabled:SetWidth(400)

SettingsControls.slPetScale = CreateSlider(pPetFrame, "Scale %", 50, 200, 5, (MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.scale) or 100, function(v)
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    MidnightUISettings.PetFrame.scale = math.floor(v)
    if _G.MidnightUI_ApplyPetSettings then _G.MidnightUI_ApplyPetSettings() end
end)
SettingsControls.slPetWidth = CreateSlider(pPetFrame, "Width", 150, 400, 5, (MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.width) or 240, function(v)
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    MidnightUISettings.PetFrame.width = math.floor(v)
    if _G.MidnightUI_ApplyPetSettings then _G.MidnightUI_ApplyPetSettings() end
end)
SettingsControls.slPetHeight = CreateSlider(pPetFrame, "Height", 30, 100, 2, (MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.height) or 48, function(v)
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    MidnightUISettings.PetFrame.height = math.floor(v)
    if _G.MidnightUI_ApplyPetSettings then _G.MidnightUI_ApplyPetSettings() end
end)
SettingsControls.slPetAlpha = CreateSlider(pPetFrame, "Opacity", 0.1, 1.0, 0.05, (MidnightUISettings.PetFrame and MidnightUISettings.PetFrame.alpha) or 0.95, function(v)
    if not MidnightUISettings.PetFrame then MidnightUISettings.PetFrame = {} end
    MidnightUISettings.PetFrame.alpha = v
    if _G.MidnightUI_ApplyPetSettings then _G.MidnightUI_ApplyPetSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slPetScale, SettingsControls.slPetWidth, SettingsControls.slPetHeight, SettingsControls.slPetAlpha}, PAGE_INSET_X, -78, COL_GAP, ROW_GAP, 180)
end

-- =========================================================================
--  PLAYER: CONSUMABLES
-- =========================================================================

local hCons = CreateSectionHeader(pPlayConsumables, "Consumable Bars")
hCons:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

SettingsControls.chkConsEnable = CreateFrame("CheckButton", nil, pPlayConsumables, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkConsEnable:SetPoint("TOPLEFT", PAGE_INSET_X, -40); SettingsControls.chkConsEnable.Text:SetText("Enable Consumable Bars")
SettingsControls.chkConsEnable.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkConsEnable:SetChecked(MidnightUISettings.ConsumableBars and MidnightUISettings.ConsumableBars.enabled ~= false)
SettingsControls.chkConsEnable:SetScript("OnClick", function(self)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.enabled = self:GetChecked()
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)

SettingsControls.chkConsHideInactive = CreateFrame("CheckButton", nil, pPlayConsumables, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkConsHideInactive:SetPoint("TOPLEFT", SettingsControls.chkConsEnable, "BOTTOMLEFT", 0, -6); SettingsControls.chkConsHideInactive.Text:SetText("Hide Inactive Bars")
SettingsControls.chkConsHideInactive.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkConsHideInactive:SetChecked(MidnightUISettings.ConsumableBars and MidnightUISettings.ConsumableBars.hideInactive == true)
SettingsControls.chkConsHideInactive:SetScript("OnClick", function(self)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.hideInactive = self:GetChecked()
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)

SettingsControls.chkConsInstanceOnly = CreateFrame("CheckButton", nil, pPlayConsumables, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkConsInstanceOnly:SetPoint("TOPLEFT", SettingsControls.chkConsHideInactive, "BOTTOMLEFT", 0, -6); SettingsControls.chkConsInstanceOnly.Text:SetText("Show in Dungeon/Raid Only")
SettingsControls.chkConsInstanceOnly.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkConsInstanceOnly:SetChecked(MidnightUISettings.ConsumableBars and MidnightUISettings.ConsumableBars.showInInstancesOnly == true)
SettingsControls.chkConsInstanceOnly:SetScript("OnClick", function(self)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.showInInstancesOnly = self:GetChecked()
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)

SettingsControls.slConsWidth = CreateSlider(pPlayConsumables, "Width", 120, 420, 5, 220, function(v)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.width = math.floor(v)
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)
SettingsControls.slConsHeight = CreateSlider(pPlayConsumables, "Height", 6, 24, 1, 10, function(v)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.height = math.floor(v)
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)
SettingsControls.slConsSpacing = CreateSlider(pPlayConsumables, "Spacing", 0, 12, 1, 4, function(v)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.spacing = math.floor(v)
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)
SettingsControls.slConsScale = CreateSlider(pPlayConsumables, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.ConsumableBars then MidnightUISettings.ConsumableBars = {} end
    MidnightUISettings.ConsumableBars.scale = math.floor(v)
    if _G.MidnightUI_ApplyConsumableBarsSettings then _G.MidnightUI_ApplyConsumableBarsSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slConsWidth, SettingsControls.slConsHeight, SettingsControls.slConsSpacing, SettingsControls.slConsScale}, PAGE_INSET_X, -140, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: PARTY FRAMES (MAIN)
-- =========================================================================
local pPartyScroll, pPartyContent = CreateScrollPage(pPartyMain)
local pParty = pPartyContent
pPartyContent:SetHeight(730)
local RefreshPartyCardsLayout
local hParty = CreateSectionHeader(pParty, "Party Frames")
hParty:SetPoint("TOPLEFT", PAGE_INSET_X, -4)

-- "Use Default Frames" toggle buttons (party)
local function MakePartyModeButton(label, onClick)
    local b = CreateFrame("Button", nil, pParty, "UIPanelButtonTemplate")
    b:SetSize(260, 32)
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    StyleSettingsButton(b)
    return b
end

SettingsControls.btnDefaultParty = MakePartyModeButton("Switch to Default Party Frames (Reload)", function()
    if InCombatLockdown() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
        return
    end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.useDefaultFrames = true
    ReloadUI()
end)
SettingsControls.btnDefaultParty:SetPoint("TOPLEFT", hParty, "BOTTOMLEFT", 0, -12)
SettingsControls.btnDefaultParty:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Switch to Default Party Frames", 1, 1, 1)
    GameTooltip:AddLine("Reloads the UI and uses Blizzard's default party frames.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("MidnightUI custom party frames will be disabled.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
SettingsControls.btnDefaultParty:SetScript("OnLeave", function() GameTooltip:Hide() end)

SettingsControls.btnCustomParty = MakePartyModeButton("Switch to Custom Party Frames (Reload)", function()
    if InCombatLockdown() then
        if DEFAULT_CHAT_FRAME then DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.") end
        return
    end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.useDefaultFrames = false
    ReloadUI()
end)
SettingsControls.btnCustomParty:SetPoint("TOPLEFT", hParty, "BOTTOMLEFT", 0, -12)
SettingsControls.btnCustomParty:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Switch to Custom Party Frames", 1, 1, 1)
    GameTooltip:AddLine("Reloads the UI and enables MidnightUI custom party frames.", 0.9, 0.9, 0.9, true)
    GameTooltip:AddLine("Blizzard's default party frames will be hidden.", 0.8, 0.8, 0.8, true)
    GameTooltip:Show()
end)
SettingsControls.btnCustomParty:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function UpdatePartyModeButtons()
    local useDefault = MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.useDefaultFrames
    if useDefault then
        SettingsControls.btnDefaultParty:Hide()
        SettingsControls.btnCustomParty:Show()
    else
        SettingsControls.btnCustomParty:Hide()
        SettingsControls.btnDefaultParty:Show()
    end
end
UpdatePartyModeButtons()
SettingsControls.UpdatePartyModeButtons = UpdatePartyModeButtons

pParty:HookScript("OnShow", function()
    UpdatePartyModeButtons()
    RefreshPartyCardsLayout()
end)

SettingsControls.ddPartyLayout = CreateDropdown(pParty, "Party Layout", {"Vertical", "Horizontal"}, "Vertical", function(v)
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.layout = v
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
    UpdatePartySpacingVisibility()
end)
SettingsControls.ddPartyLayout:SetPoint("TOPLEFT", PAGE_INSET_X, -100)

local suppressPartyStyleCallback = false
SettingsControls.ddPartyStyle = CreateDropdown(pParty, "Party Styling", {"Rendered", "Simple", "Square"}, "Rendered", function(v)
    if suppressPartyStyleCallback then return end
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    if _G.MidnightUI_SetPartyStyle then
        _G.MidnightUI_SetPartyStyle(v)
    else
        MidnightUISettings.PartyFrames.style = v
        if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
    end
    UpdatePartyStyleVisibility()
end)
SettingsControls.ddPartyStyle:SetPoint("TOPLEFT", PAGE_INSET_X, -178)

SettingsControls.slPartyWidth = CreateSlider(pParty, "Width", 120, 420, 2, 240, function(v)
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.width = math.floor(v)
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
end)
SettingsControls.slPartyHeight = CreateSlider(pParty, "Height", 24, 120, 2, 58, function(v)
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.height = math.floor(v)
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
end)
SettingsControls.slPartyDiameter = CreateSlider(pParty, "Diameter", 28, 140, 2, 64, function(v)
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.diameter = math.floor(v)
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
end)
local partyCardsSize = {SettingsControls.slPartyWidth, SettingsControls.slPartyHeight, SettingsControls.slPartyDiameter}

SettingsControls.slPartySpacingX = CreateSlider(pParty, "Horizontal Spacing", 0, 200, 1, 8, function(v)
    if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
    MidnightUISettings.PartyFrames.spacingX = math.floor(v)
    if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
end)
  SettingsControls.slPartySpacingY = CreateSlider(pParty, "Vertical Spacing", 0, 200, 1, 8, function(v)
      if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
      MidnightUISettings.PartyFrames.spacingY = math.floor(v)
      if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
  end)
  SettingsControls.cbPartyTooltip = CreateFrame("CheckButton", nil, pParty, "InterfaceOptionsCheckButtonTemplate")
  SettingsControls.cbPartyTooltip:SetPoint("TOPLEFT", SettingsControls.slPartyDiameter, "BOTTOMLEFT", 0, -12)
  SettingsControls.cbPartyTooltip.Text:SetText("Show Tooltip")
  SettingsControls.cbPartyTooltip.Text:SetFontObject("GameFontNormalSmall")
  SettingsControls.cbPartyTooltip:SetSize(20, 20)
  SettingsControls.cbPartyTooltip.Text:ClearAllPoints()
  SettingsControls.cbPartyTooltip.Text:SetPoint("LEFT", SettingsControls.cbPartyTooltip, "RIGHT", 6, 0)
  SettingsControls.cbPartyTooltip:SetChecked(true)
  SettingsControls.cbPartyTooltip:SetScript("OnClick", function(self)
      if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
      MidnightUISettings.PartyFrames.showTooltip = self:GetChecked() and true or false
  end)
  AttachTooltip(SettingsControls.cbPartyTooltip, TOOLTIP_TEXTS["Show Tooltip"])
  SettingsControls.cbPartyHideInRaid = CreateFrame("CheckButton", nil, pParty, "InterfaceOptionsCheckButtonTemplate")
  SettingsControls.cbPartyHideInRaid.Text:SetText("Hide In Raid")
  SettingsControls.cbPartyHideInRaid.Text:SetFontObject("GameFontNormalSmall")
  SettingsControls.cbPartyHideInRaid:SetSize(20, 20)
  SettingsControls.cbPartyHideInRaid.Text:ClearAllPoints()
  SettingsControls.cbPartyHideInRaid.Text:SetPoint("LEFT", SettingsControls.cbPartyHideInRaid, "RIGHT", 6, 0)
  SettingsControls.cbPartyHideInRaid:SetChecked(false)
  SettingsControls.cbPartyHideInRaid:SetScript("OnClick", function(self)
      if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
      MidnightUISettings.PartyFrames.hideInRaid = self:GetChecked() and true or false
      if _G.MidnightUI_UpdatePartyVisibility then _G.MidnightUI_UpdatePartyVisibility() end
  end)
  AttachTooltip(SettingsControls.cbPartyHideInRaid, TOOLTIP_TEXTS["Hide In Raid"])

  SettingsControls.cbPartyHide2DPortrait = CreateFrame("CheckButton", nil, pParty, "InterfaceOptionsCheckButtonTemplate")
  SettingsControls.cbPartyHide2DPortrait.Text:SetText("Hide 2D Portrait")
  SettingsControls.cbPartyHide2DPortrait.Text:SetFontObject("GameFontNormalSmall")
  SettingsControls.cbPartyHide2DPortrait:SetSize(20, 20)
  SettingsControls.cbPartyHide2DPortrait.Text:ClearAllPoints()
  SettingsControls.cbPartyHide2DPortrait.Text:SetPoint("LEFT", SettingsControls.cbPartyHide2DPortrait, "RIGHT", 6, 0)
  SettingsControls.cbPartyHide2DPortrait:SetChecked(false)
  SettingsControls.cbPartyHide2DPortrait:SetScript("OnClick", function(self)
      if not MidnightUISettings.PartyFrames then MidnightUISettings.PartyFrames = {} end
      MidnightUISettings.PartyFrames.hide2DPortrait = self:GetChecked() and true or false
      if _G.MidnightUI_ApplyPartyFramesLayout then _G.MidnightUI_ApplyPartyFramesLayout() end
  end)
  AttachTooltip(SettingsControls.cbPartyHide2DPortrait, TOOLTIP_TEXTS["Hide 2D Portrait"])
  local partyCardsSpacing = {SettingsControls.slPartySpacingX, SettingsControls.slPartySpacingY}

RefreshPartyCardsLayout = function()
    local cards = {}
    for _, c in ipairs(partyCardsSize) do
        if c and c:IsShown() then table.insert(cards, c) end
    end
    for _, c in ipairs(partyCardsSpacing) do
        if c and c:IsShown() then table.insert(cards, c) end
    end
      if #cards > 0 then
          LayoutCardsTwoColumn(cards, PAGE_INSET_X, -256, COL_GAP, ROW_GAP, 180)
      end
    local lastCard = nil
    for _, c in ipairs(partyCardsSize) do
        if c and c:IsShown() then lastCard = c end
    end
    for _, c in ipairs(partyCardsSpacing) do
        if c and c:IsShown() then lastCard = c end
    end
    if SettingsControls.cbPartyTooltip then
        SettingsControls.cbPartyTooltip:ClearAllPoints()
        if lastCard then
            SettingsControls.cbPartyTooltip:SetPoint("TOPLEFT", lastCard, "BOTTOMLEFT", 0, -12)
        else
            SettingsControls.cbPartyTooltip:SetPoint("TOPLEFT", PAGE_INSET_X, -256)
        end
        SettingsControls.cbPartyTooltip:SetSize(20, 20)
    end
    if SettingsControls.cbPartyHideInRaid and SettingsControls.cbPartyTooltip then
        SettingsControls.cbPartyHideInRaid:ClearAllPoints()
        SettingsControls.cbPartyHideInRaid:SetPoint("TOPLEFT", SettingsControls.cbPartyTooltip, "BOTTOMLEFT", 0, -6)
        SettingsControls.cbPartyHideInRaid:SetSize(20, 20)
    end
    if SettingsControls.cbPartyHide2DPortrait and SettingsControls.cbPartyHideInRaid then
        SettingsControls.cbPartyHide2DPortrait:ClearAllPoints()
        SettingsControls.cbPartyHide2DPortrait:SetPoint("TOPLEFT", SettingsControls.cbPartyHideInRaid, "BOTTOMLEFT", 0, -6)
        SettingsControls.cbPartyHide2DPortrait:SetSize(20, 20)
    end
end

function UpdatePartySpacingVisibility()
    local layout = MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.layout or "Vertical"
    if layout == "Horizontal" then
        if SettingsControls.slPartySpacingX then SettingsControls.slPartySpacingX:Show() end
        if SettingsControls.slPartySpacingY then SettingsControls.slPartySpacingY:Hide() end
    else
        if SettingsControls.slPartySpacingX then SettingsControls.slPartySpacingX:Hide() end
        if SettingsControls.slPartySpacingY then SettingsControls.slPartySpacingY:Show() end
    end
    RefreshPartyCardsLayout()
end

function UpdatePartyStyleVisibility()
    local style = MidnightUISettings and MidnightUISettings.PartyFrames and MidnightUISettings.PartyFrames.style or "Rendered"
    if style == "Circular" then
        style = "Square"
        MidnightUISettings.PartyFrames.style = "Square"
    end
    if style == "Square" then
        if SettingsControls.slPartyWidth then SettingsControls.slPartyWidth:Hide() end
        if SettingsControls.slPartyHeight then SettingsControls.slPartyHeight:Hide() end
        if SettingsControls.slPartyDiameter then
            SettingsControls.slPartyDiameter:Show()
            if SettingsControls.slPartyDiameter.label then SettingsControls.slPartyDiameter.label:SetText("Scale") end
        end
        if SettingsControls.cbPartyHide2DPortrait then SettingsControls.cbPartyHide2DPortrait:Hide() end
    else
        if SettingsControls.slPartyWidth then SettingsControls.slPartyWidth:Show() end
        if SettingsControls.slPartyHeight then SettingsControls.slPartyHeight:Show() end
        if SettingsControls.slPartyDiameter then
            SettingsControls.slPartyDiameter:Hide()
            if SettingsControls.slPartyDiameter.label then SettingsControls.slPartyDiameter.label:SetText("Diameter") end
        end
        if SettingsControls.cbPartyHide2DPortrait then SettingsControls.cbPartyHide2DPortrait:Show() end
    end
    RefreshPartyCardsLayout()
end
  UpdatePartySpacingVisibility()
  UpdatePartyStyleVisibility()

  -- =========================================================================
  --  PAGE: TARGET > CORE
  -- =========================================================================
local pTargCoreScroll, pTargCore = CreateScrollPage(targetTabs.Core)
local pTargNameplates = targetTabs.Nameplates
local pTargAuras = targetTabs.Auras
local pTargDebuffs = targetTabs.Debuffs
local pFocus = targetTabs.Focus

SettingsControls.hTargetCoreOptions = CreateSectionHeader(pTargCore, "Frame Options")
SettingsControls.hTargetCoreOptions:SetPoint("TOPLEFT", PAGE_INSET_X, -4)

SettingsControls.chkTarg = CreateToggleControlCard(
    pTargCore,
    "Enable Target Frame",
    "Shows or hides the MidnightUI target frame.",
    MidnightUISettings.TargetFrame.enabled ~= false,
    function(v)
        MidnightUISettings.TargetFrame.enabled = v and true or false
        M.ApplyTargetSettings()
    end,
    { height = 66, wrapTitle = false }
)
SettingsControls.chkTarg:SetPoint("TOPLEFT", PAGE_INSET_X, -50)
SettingsControls.chkTarg:SetPoint("TOPRIGHT", -PAGE_INSET_X, -50)

SettingsControls.chkTargTooltip = CreateToggleControlCard(
    pTargCore,
    "Custom Tooltip",
    "Use MidnightUI tooltip styling for the target frame.",
    MidnightUISettings.TargetFrame.customTooltip ~= false,
    function(v)
        MidnightUISettings.TargetFrame.customTooltip = v and true or false
    end,
    { height = 66, wrapTitle = false }
)
SettingsControls.chkTargTooltip:SetPoint("TOPLEFT", SettingsControls.chkTarg, "BOTTOMLEFT", 0, -8)
SettingsControls.chkTargTooltip:SetPoint("TOPRIGHT", SettingsControls.chkTarg, "BOTTOMRIGHT", 0, -8)

SettingsControls.chkTargetOfTarget = CreateToggleControlCard(
    pTargCore,
    "Show Target of Target",
    "Shows a small frame for your target's current target.",
    MidnightUISettings.TargetFrame.showTargetOfTarget == true,
    function(v)
        MidnightUISettings.TargetFrame.showTargetOfTarget = v and true or false
        if _G.MidnightUI_ApplyTargetOfTargetSettings then _G.MidnightUI_ApplyTargetOfTargetSettings() end
    end,
    {
        height = 66,
        wrapTitle = false,
        tooltip = "Shows a small frame displaying your target's target (e.g., who the enemy is attacking).",
    }
)
SettingsControls.chkTargetOfTarget:SetPoint("TOPLEFT", SettingsControls.chkTargTooltip, "BOTTOMLEFT", 0, -8)
SettingsControls.chkTargetOfTarget:SetPoint("TOPRIGHT", SettingsControls.chkTargTooltip, "BOTTOMRIGHT", 0, -8)

SettingsControls.hTargetCoreLayout = CreateSectionHeader(pTargCore, "Frame Layout")
-- 3 cards x 66px + 2 gaps x 8px + header 46px + initial offset 50px = 294px
SettingsControls.hTargetCoreLayout:SetPoint("TOPLEFT", PAGE_INSET_X, -300)

SettingsControls.slTScale = CreateSlider(pTargCore, "Scale %", 50, 200, 5, 100, function(v) MidnightUISettings.TargetFrame.scale = math.floor(v); M.ApplyTargetSettings() end)
SettingsControls.slTWidth = CreateSlider(pTargCore, "Width", 200, 600, 5, 420, function(v) MidnightUISettings.TargetFrame.width = math.floor(v); M.ApplyTargetSettings() end)
SettingsControls.slTHeight = CreateSlider(pTargCore, "Height", 50, 150, 2, 72, function(v) MidnightUISettings.TargetFrame.height = math.floor(v); M.ApplyTargetSettings() end)
SettingsControls.slTAlpha = CreateSlider(pTargCore, "Opacity", 0.1, 1.0, 0.05, 0.95, function(v) MidnightUISettings.TargetFrame.alpha = v; M.ApplyTargetSettings() end)
LayoutCardsTwoColumn({SettingsControls.slTScale, SettingsControls.slTWidth, SettingsControls.slTHeight, SettingsControls.slTAlpha}, PAGE_INSET_X, -346, COL_GAP, ROW_GAP, 180)


-- =========================================================================
--  PAGE: TARGET > NAMEPLATES
-- =========================================================================
local pTargNPScroll, pTargNPContent = CreateScrollPage(pTargNameplates)
local pTNP = pTargNPContent

SettingsControls.chkTargetNPEnabled = CreateFrame("CheckButton", nil, pTNP, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetNPEnabled:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkTargetNPEnabled.Text:SetText("Enable MidnightUI Nameplates")
SettingsControls.chkTargetNPEnabled.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetNPEnabled:SetChecked(MidnightUISettings and MidnightUISettings.Nameplates and MidnightUISettings.Nameplates.enabled ~= false)
SettingsControls.chkTargetNPEnabled:SetScript("OnClick", function(self)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.enabled = self:GetChecked(); M.ApplyNameplateSettings()
end)

SettingsControls.chkTargetNPFactionBorder = CreateFrame("CheckButton", nil, pTNP, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetNPFactionBorder:SetPoint("LEFT", SettingsControls.chkTargetNPEnabled, "RIGHT", 200, 0)
SettingsControls.chkTargetNPFactionBorder.Text:SetText("Show Faction Border")
SettingsControls.chkTargetNPFactionBorder.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetNPFactionBorder:SetChecked(MidnightUISettings and MidnightUISettings.Nameplates and MidnightUISettings.Nameplates.showFactionBorder ~= false)
SettingsControls.chkTargetNPFactionBorder:SetScript("OnClick", function(self)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.showFactionBorder = (self:GetChecked() == true); M.ApplyNameplateSettings()
end)

SettingsControls.chkTargetNPPulse = CreateFrame("CheckButton", nil, pTNP, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetNPPulse:SetPoint("TOPLEFT", PAGE_INSET_X, -28)
SettingsControls.chkTargetNPPulse.Text:SetText("Enable Target Pulse")
SettingsControls.chkTargetNPPulse.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetNPPulse:SetChecked(MidnightUISettings and MidnightUISettings.Nameplates and MidnightUISettings.Nameplates.targetPulse ~= false)
SettingsControls.chkTargetNPPulse:SetScript("OnClick", function(self)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.targetPulse = (self:GetChecked() == true); M.ApplyNameplateSettings()
end)

SettingsControls.chkTargetNPSelectedBorder = CreateFrame("CheckButton", nil, pTNP, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetNPSelectedBorder:SetPoint("LEFT", SettingsControls.chkTargetNPPulse, "RIGHT", 200, 0)
SettingsControls.chkTargetNPSelectedBorder.Text:SetText("Show Selected Border")
SettingsControls.chkTargetNPSelectedBorder.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetNPSelectedBorder:SetChecked(MidnightUISettings and MidnightUISettings.Nameplates and MidnightUISettings.Nameplates.targetBorder ~= false)
SettingsControls.chkTargetNPSelectedBorder:SetScript("OnClick", function(self)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.targetBorder = (self:GetChecked() == true); M.ApplyNameplateSettings()
end)

SettingsControls.chkTargetNPThreat = CreateFrame("CheckButton", nil, pTNP, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetNPThreat:SetPoint("TOPLEFT", PAGE_INSET_X, -52)
SettingsControls.chkTargetNPThreat.Text:SetText("Enable Threat Bar")
SettingsControls.chkTargetNPThreat.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetNPThreat:SetChecked(MidnightUISettings and MidnightUISettings.Nameplates and MidnightUISettings.Nameplates.threatBar and MidnightUISettings.Nameplates.threatBar.enabled ~= false)
SettingsControls.chkTargetNPThreat:SetScript("OnClick", function(self)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.threatBar.enabled = self:GetChecked(); M.ApplyNameplateSettings()
end)

SettingsControls.slTargetNPScale = CreateSlider(pTNP, "Nameplate Scale %", 50, 200, 5, 100, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.scale = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPHealthWidth = CreateSlider(pTNP, "Health Width", 140, 360, 5, 200, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.width = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPHealthHeight = CreateSlider(pTNP, "Health Height", 10, 40, 1, 20, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.height = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPHealthAlpha = CreateSlider(pTNP, "Health Opacity", 0.2, 1.0, 0.05, 1.0, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.alpha = v; M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPNonTargetAlpha = CreateSlider(pTNP, "Non-Target Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.nonTargetAlpha = v; M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPNameFont = CreateSlider(pTNP, "Name Font", 8, 24, 1, 10, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.nameFontSize = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPPctFont = CreateSlider(pTNP, "HP% Font", 8, 24, 1, 9, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.healthBar.healthPctFontSize = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPThreatWidth = CreateSlider(pTNP, "Threat Width", 140, 360, 5, 200, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.threatBar.width = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPThreatHeight = CreateSlider(pTNP, "Threat Height", 2, 20, 1, 5, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.threatBar.height = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPThreatAlpha = CreateSlider(pTNP, "Threat Opacity", 0.2, 1.0, 0.05, 1.0, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.threatBar.alpha = v; M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCastWidth = CreateSlider(pTNP, "Cast Width", 140, 360, 5, 200, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.castBar.width = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCastHeight = CreateSlider(pTNP, "Cast Height", 8, 30, 1, 20, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.castBar.height = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCastFont = CreateSlider(pTNP, "Cast Font", 8, 24, 1, 12, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.castBar.fontSize = math.floor(v); M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCastAlpha = CreateSlider(pTNP, "Cast Opacity", 0.2, 1.0, 0.05, 1.0, function(v)
    M.EnsureNameplateSettings(); MidnightUISettings.Nameplates.castBar.alpha = v; M.ApplyNameplateSettings()
end)
SettingsControls.ddTargetNPNameAlign = CreateDropdown(pTNP, "Name Alignment", {"Left", "Center", "Right"}, "Left", function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.healthBar.nameAlign = string.upper(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.ddTargetNPPctDisplay = CreateDropdown(pTNP, "Health % Display", {"Hidden", "Left", "Right"}, "Right", function(v)
    M.EnsureNameplateSettings()
    if v == "Hidden" then MidnightUISettings.Nameplates.healthBar.healthPctDisplay = "HIDE"
    else MidnightUISettings.Nameplates.healthBar.healthPctDisplay = string.upper(v) end
    M.ApplyNameplateSettings()
end)
LayoutCardsTwoColumn({
    SettingsControls.slTargetNPScale,
    SettingsControls.slTargetNPHealthWidth,
    SettingsControls.slTargetNPHealthHeight,
    SettingsControls.slTargetNPHealthAlpha,
    SettingsControls.slTargetNPNonTargetAlpha,
    SettingsControls.slTargetNPNameFont,
    SettingsControls.slTargetNPPctFont,
    SettingsControls.slTargetNPThreatWidth,
    SettingsControls.slTargetNPThreatHeight,
    SettingsControls.slTargetNPThreatAlpha,
    SettingsControls.slTargetNPCastWidth,
    SettingsControls.slTargetNPCastHeight,
    SettingsControls.slTargetNPCastFont,
    SettingsControls.slTargetNPCastAlpha,
    SettingsControls.ddTargetNPNameAlign,
    SettingsControls.ddTargetNPPctDisplay
}, PAGE_INSET_X, -82, COL_GAP, ROW_GAP, 180)

local hTargetNPCurrent = CreateSectionHeader(pTNP, "Current Target Nameplate")
hTargetNPCurrent:SetPoint("TOPLEFT", PAGE_INSET_X, -510)

SettingsControls.slTargetNPCurScale = CreateSlider(pTNP, "Scale %", 50, 200, 5, 100, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.scale = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurHealthWidth = CreateSlider(pTNP, "Health Width", 140, 420, 5, 240, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.healthBar.width = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurHealthHeight = CreateSlider(pTNP, "Health Height", 10, 50, 1, 24, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.healthBar.height = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurNameFont = CreateSlider(pTNP, "Name Font", 8, 28, 1, 10, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.healthBar.nameFontSize = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurPctFont = CreateSlider(pTNP, "HP% Font", 8, 28, 1, 9, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.healthBar.healthPctFontSize = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurThreatWidth = CreateSlider(pTNP, "Threat Width", 140, 420, 5, 240, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.threatBar.width = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurThreatHeight = CreateSlider(pTNP, "Threat Height", 2, 30, 1, 6, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.threatBar.height = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurCastWidth = CreateSlider(pTNP, "Cast Width", 140, 420, 5, 240, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.castBar.width = math.floor(v)
    M.ApplyNameplateSettings()
end)
SettingsControls.slTargetNPCurCastHeight = CreateSlider(pTNP, "Cast Height", 8, 40, 1, 18, function(v)
    M.EnsureNameplateSettings()
    MidnightUISettings.Nameplates.target.castBar.height = math.floor(v)
    M.ApplyNameplateSettings()
end)
LayoutCardsTwoColumn({
    SettingsControls.slTargetNPCurScale,
    SettingsControls.slTargetNPCurHealthWidth,
    SettingsControls.slTargetNPCurHealthHeight,
    SettingsControls.slTargetNPCurNameFont,
    SettingsControls.slTargetNPCurPctFont,
    SettingsControls.slTargetNPCurThreatWidth,
    SettingsControls.slTargetNPCurThreatHeight,
    SettingsControls.slTargetNPCurCastWidth,
    SettingsControls.slTargetNPCurCastHeight
}, PAGE_INSET_X, -536, COL_GAP, ROW_GAP, 180)
if pTargNPContent then
    pTargNPContent:SetHeight(980)
end

local targetNpControls = {
    masterToggle = SettingsControls.chkTargetNPEnabled,
    borderToggle = SettingsControls.chkTargetNPFactionBorder,
    selectedBorderToggle = SettingsControls.chkTargetNPSelectedBorder,
    pulseToggle = SettingsControls.chkTargetNPPulse,
    threatToggle = SettingsControls.chkTargetNPThreat,
    scale = SettingsControls.slTargetNPScale,
    healthWidth = SettingsControls.slTargetNPHealthWidth,
    healthHeight = SettingsControls.slTargetNPHealthHeight,
    healthAlpha = SettingsControls.slTargetNPHealthAlpha,
    nonTargetAlpha = SettingsControls.slTargetNPNonTargetAlpha,
    nameFont = SettingsControls.slTargetNPNameFont,
    pctFont = SettingsControls.slTargetNPPctFont,
    nameAlign = SettingsControls.ddTargetNPNameAlign,
    pctDisplay = SettingsControls.ddTargetNPPctDisplay,
    threatWidth = SettingsControls.slTargetNPThreatWidth,
    threatHeight = SettingsControls.slTargetNPThreatHeight,
    threatAlpha = SettingsControls.slTargetNPThreatAlpha,
    castWidth = SettingsControls.slTargetNPCastWidth,
    castHeight = SettingsControls.slTargetNPCastHeight,
    castFont = SettingsControls.slTargetNPCastFont,
    castAlpha = SettingsControls.slTargetNPCastAlpha,
    tScale = SettingsControls.slTargetNPCurScale,
    tHealthWidth = SettingsControls.slTargetNPCurHealthWidth,
    tHealthHeight = SettingsControls.slTargetNPCurHealthHeight,
    tNameFont = SettingsControls.slTargetNPCurNameFont,
    tPctFont = SettingsControls.slTargetNPCurPctFont,
    tThreatWidth = SettingsControls.slTargetNPCurThreatWidth,
    tThreatHeight = SettingsControls.slTargetNPCurThreatHeight,
    tCastWidth = SettingsControls.slTargetNPCurCastWidth,
    tCastHeight = SettingsControls.slTargetNPCurCastHeight,
}
SettingsControls.targetNpControls = targetNpControls


-- =========================================================================
--  PAGE: TARGET > AURAS (BUFFS)
-- =========================================================================
SettingsControls.chkTargetAuras = CreateFrame("CheckButton", nil, pTargAuras, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetAuras:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkTargetAuras.Text:SetText("Show Target Buff Bar")
SettingsControls.chkTargetAuras.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetAuras:SetScript("OnClick", function(self)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.enabled = self:GetChecked()
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)

SettingsControls.slTargetAuraScale = CreateSlider(pTargAuras, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.scale = math.floor(v)
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)
SettingsControls.slTargetAuraAlpha = CreateSlider(pTargAuras, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.alpha = v
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)
SettingsControls.slTargetAuraMax = CreateSlider(pTargAuras, "Max Shown", 1, 32, 1, 32, function(v)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.maxShown = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)
SettingsControls.slTargetAuraPerRow = CreateSlider(pTargAuras, "Icons Per Row", 1, 32, 1, 16, function(v)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.perRow = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slTargetAuraScale, SettingsControls.slTargetAuraAlpha, SettingsControls.slTargetAuraMax, SettingsControls.slTargetAuraPerRow}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

SettingsControls.ddTargetAuraAlign = CreateDropdown(pTargAuras, "Alignment", {"Left", "Center", "Right"}, "Right", function(v)
    if not MidnightUISettings.TargetFrame.auras then MidnightUISettings.TargetFrame.auras = {} end
    MidnightUISettings.TargetFrame.auras.alignment = v
    if _G.MidnightUI_ApplyTargetAuraSettings then _G.MidnightUI_ApplyTargetAuraSettings() end
end)
SettingsControls.ddTargetAuraAlign:ClearAllPoints()
SettingsControls.ddTargetAuraAlign:SetPoint("TOPLEFT", SettingsControls.slTargetAuraMax or SettingsControls.slTargetAuraScale, "BOTTOMLEFT", 0, -18)
if SettingsControls.slTargetAuraScale and SettingsControls.slTargetAuraScale.GetWidth then
    SettingsControls.ddTargetAuraAlign:SetWidth(SettingsControls.slTargetAuraScale:GetWidth())
end

-- =========================================================================
--  PAGE: TARGET > DEBUFFS
-- =========================================================================
SettingsControls.chkTargetDebuffs = CreateFrame("CheckButton", nil, pTargDebuffs, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkTargetDebuffs:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkTargetDebuffs.Text:SetText("Show Target Debuff Bar")
SettingsControls.chkTargetDebuffs.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkTargetDebuffs:SetScript("OnClick", function(self)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.enabled = self:GetChecked()
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)

SettingsControls.slTargetDebuffScale = CreateSlider(pTargDebuffs, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.scale = math.floor(v)
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
SettingsControls.slTargetDebuffAlpha = CreateSlider(pTargDebuffs, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.alpha = v
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
SettingsControls.slTargetDebuffMax = CreateSlider(pTargDebuffs, "Max Shown", 1, 16, 1, 16, function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.maxShown = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
SettingsControls.slTargetDebuffPerRow = CreateSlider(pTargDebuffs, "Icons Per Row", 1, 16, 1, 16, function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.perRow = math.floor(v + 0.5)
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slTargetDebuffScale, SettingsControls.slTargetDebuffAlpha, SettingsControls.slTargetDebuffMax, SettingsControls.slTargetDebuffPerRow}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

SettingsControls.ddTargetDebuffAlign = CreateDropdown(pTargDebuffs, "Alignment", {"Left", "Center", "Right"}, "Right", function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.alignment = v
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
  -- Layout handled below

local ddTargetDebuffFilter = CreateDropdown(pTargDebuffs, "Filter Mode", {"AUTO", "PLAYER", "ALL"}, "AUTO", function(v)
    if not MidnightUISettings.TargetFrame.debuffs then MidnightUISettings.TargetFrame.debuffs = {} end
    MidnightUISettings.TargetFrame.debuffs.filterMode = v
    if _G.MidnightUI_ApplyTargetDebuffSettings then _G.MidnightUI_ApplyTargetDebuffSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.ddTargetDebuffAlign, ddTargetDebuffFilter}, PAGE_INSET_X, -210, COL_GAP, ROW_GAP, 160)

-- =========================================================================
--  PAGE: TARGET > FOCUS
-- =========================================================================
SettingsControls.hFocusOptions = CreateSectionHeader(pFocus, "Frame Options")
SettingsControls.hFocusOptions:SetPoint("TOPLEFT", PAGE_INSET_X, -4)

SettingsControls.chkFocus = CreateToggleControlCard(
    pFocus,
    "Enable Focus Frame",
    "Shows or hides the MidnightUI focus frame.",
    MidnightUISettings.FocusFrame.enabled ~= false,
    function(v)
        MidnightUISettings.FocusFrame.enabled = v and true or false
        M.ApplyFocusSettings()
    end,
    { height = 66, wrapTitle = false }
)
SettingsControls.chkFocus:SetPoint("TOPLEFT", PAGE_INSET_X, -50)
SettingsControls.chkFocus:SetPoint("TOPRIGHT", -PAGE_INSET_X, -50)

SettingsControls.chkFocusTooltip = CreateToggleControlCard(
    pFocus,
    "Custom Tooltip",
    "Use MidnightUI tooltip styling for the focus frame.",
    MidnightUISettings.FocusFrame.customTooltip ~= false,
    function(v)
        MidnightUISettings.FocusFrame.customTooltip = v and true or false
    end,
    { height = 66, wrapTitle = false }
)
SettingsControls.chkFocusTooltip:SetPoint("TOPLEFT", SettingsControls.chkFocus, "BOTTOMLEFT", 0, -8)
SettingsControls.chkFocusTooltip:SetPoint("TOPRIGHT", SettingsControls.chkFocus, "BOTTOMRIGHT", 0, -8)

SettingsControls.hFocusLayout = CreateSectionHeader(pFocus, "Frame Layout")
SettingsControls.hFocusLayout:SetPoint("TOPLEFT", PAGE_INSET_X, -210)

SettingsControls.slFScale = CreateSlider(pFocus, "Scale %", 50, 200, 5, 100, function(v) MidnightUISettings.FocusFrame.scale = math.floor(v); M.ApplyFocusSettings() end)
SettingsControls.slFWidth = CreateSlider(pFocus, "Width", 200, 600, 5, 320, function(v) MidnightUISettings.FocusFrame.width = math.floor(v); M.ApplyFocusSettings() end)
SettingsControls.slFHeight = CreateSlider(pFocus, "Height", 40, 120, 2, 58, function(v) MidnightUISettings.FocusFrame.height = math.floor(v); M.ApplyFocusSettings() end)
SettingsControls.slFAlpha = CreateSlider(pFocus, "Opacity", 0.1, 1.0, 0.05, 0.95, function(v) MidnightUISettings.FocusFrame.alpha = v; M.ApplyFocusSettings() end)
LayoutCardsTwoColumn({SettingsControls.slFScale, SettingsControls.slFWidth, SettingsControls.slFHeight, SettingsControls.slFAlpha}, PAGE_INSET_X, -256, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: COMBAT > CAST BARS (combined player + target)
-- =========================================================================
do -- scope: cast bars page locals
local pCastBars = combatTabs.CastBars
local pCastBarsScroll, pCastBarsContent = CreateScrollPage(pCastBars)
local pCB = pCastBarsContent

local hCast1 = CreateSectionHeader(pCB, "Player Cast Bar"); hCast1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)
SettingsControls.chkCP = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCP:SetPoint("TOPLEFT", PAGE_INSET_X, -46); SettingsControls.chkCP.Text:SetText("Enable")
SettingsControls.chkCP.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCP:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.enabled = self:GetChecked(); M.ApplyCastBarSettings()
end)

SettingsControls.chkCPMatch = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCPMatch:SetPoint("LEFT", SettingsControls.chkCP, "RIGHT", 200, 0)
SettingsControls.chkCPMatch.Text:SetText("Match Frame Width")
SettingsControls.chkCPMatch.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCPMatch:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.matchFrameWidth = self:GetChecked(); M.ApplyCastBarSettings()
end)

SettingsControls.slCPScale = CreateSlider(pCB, "Player Scale %", 50, 200, 5, 100, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.scale = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCPWidth = CreateSlider(pCB, "Player Width", 200, 700, 5, 420, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.width = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCPHeight = CreateSlider(pCB, "Player Height", 10, 60, 1, 22, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.height = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCPYOffset = CreateSlider(pCB, "Player Y Offset", -60, 60, 1, -6, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.player.attachYOffset = math.floor(v); M.ApplyCastBarSettings()
end)
LayoutCardsTwoColumn({SettingsControls.slCPScale, SettingsControls.slCPWidth, SettingsControls.slCPHeight, SettingsControls.slCPYOffset}, PAGE_INSET_X, -76, COL_GAP, ROW_GAP, 180)

local hCast2 = CreateSectionHeader(pCB, "Target Cast Bar"); hCast2:SetPoint("TOPLEFT", PAGE_INSET_X, -240)
SettingsControls.chkCT = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCT:SetPoint("TOPLEFT", PAGE_INSET_X, -284); SettingsControls.chkCT.Text:SetText("Enable")
SettingsControls.chkCT.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCT:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.enabled = self:GetChecked(); M.ApplyCastBarSettings()
end)

SettingsControls.chkCTMatch = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCTMatch:SetPoint("LEFT", SettingsControls.chkCT, "RIGHT", 200, 0)
SettingsControls.chkCTMatch.Text:SetText("Match Frame Width")
SettingsControls.chkCTMatch.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCTMatch:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.matchFrameWidth = self:GetChecked(); M.ApplyCastBarSettings()
end)

SettingsControls.slCTScale = CreateSlider(pCB, "Target Scale %", 50, 200, 5, 100, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.scale = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCTWidth = CreateSlider(pCB, "Target Width", 200, 700, 5, 420, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.width = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCTHeight = CreateSlider(pCB, "Target Height", 10, 60, 1, 22, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.height = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCTYOffset = CreateSlider(pCB, "Target Y Offset", -60, 60, 1, -6, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.target.attachYOffset = math.floor(v); M.ApplyCastBarSettings()
end)
LayoutCardsTwoColumn({SettingsControls.slCTScale, SettingsControls.slCTWidth, SettingsControls.slCTHeight, SettingsControls.slCTYOffset}, PAGE_INSET_X, -314, COL_GAP, ROW_GAP, 180)

local hCast3 = CreateSectionHeader(pCB, "Focus Cast Bar"); hCast3:SetPoint("TOPLEFT", PAGE_INSET_X, -478)
SettingsControls.chkCF = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCF:SetPoint("TOPLEFT", PAGE_INSET_X, -522); SettingsControls.chkCF.Text:SetText("Enable")
SettingsControls.chkCF.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCF:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.enabled = self:GetChecked(); M.ApplyCastBarSettings()
end)
SettingsControls.chkCFMatch = CreateFrame("CheckButton", nil, pCB, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkCFMatch:SetPoint("LEFT", SettingsControls.chkCF, "RIGHT", 200, 0)
SettingsControls.chkCFMatch.Text:SetText("Match Frame Width")
SettingsControls.chkCFMatch.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkCFMatch:SetScript("OnClick", function(self)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.matchFrameWidth = self:GetChecked(); M.ApplyCastBarSettings()
end)

SettingsControls.slCFScale = CreateSlider(pCB, "Focus Scale %", 50, 200, 5, 100, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.scale = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCFWidth = CreateSlider(pCB, "Focus Width", 200, 700, 5, 320, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.width = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCFHeight = CreateSlider(pCB, "Focus Height", 10, 60, 1, 20, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.height = math.floor(v); M.ApplyCastBarSettings()
end)
SettingsControls.slCFYOffset = CreateSlider(pCB, "Focus Y Offset", -60, 60, 1, -6, function(v)
    M.EnsureCastBarsSettings(); MidnightUISettings.CastBars.focus.attachYOffset = math.floor(v); M.ApplyCastBarSettings()
end)
LayoutCardsTwoColumn({SettingsControls.slCFScale, SettingsControls.slCFWidth, SettingsControls.slCFHeight, SettingsControls.slCFYOffset}, PAGE_INSET_X, -552, COL_GAP, ROW_GAP, 180)
pCastBarsContent:SetHeight(740)
end -- scope: cast bars page locals

-- =========================================================================
--  PAGE: COMBAT > DEBUFFS
-- =========================================================================
do -- scope: debuffs page locals
local pDebuffs = combatTabs.Debuffs
local pDebuffsScroll, pDebuffsContent = CreateScrollPage(pDebuffs)
pDebuffs = pDebuffsContent

--- M.EnsureCombatDebuffOverlaySettings: Ensures all debuff overlay toggle keys exist in
--   MidnightUISettings.Combat and applies legacy migration from pre-per-frame settings.
-- @return (table) - MidnightUISettings.Combat
function M.EnsureCombatDebuffOverlaySettings()
    if not MidnightUISettings.Combat then
        MidnightUISettings.Combat = {}
    end
    local combat = MidnightUISettings.Combat
    if combat.debuffOverlayGlobalEnabled == nil then
        combat.debuffOverlayGlobalEnabled = true
    end
    if combat.debuffOverlayPlayerEnabled == nil then
        combat.debuffOverlayPlayerEnabled = true
    end
    if combat.debuffOverlayFocusEnabled == nil then
        combat.debuffOverlayFocusEnabled = true
    end
    if combat.debuffOverlayPartyEnabled == nil then
        combat.debuffOverlayPartyEnabled = true
    end
    if combat.debuffOverlayRaidEnabled == nil then
        combat.debuffOverlayRaidEnabled = true
    end
    if combat.debuffOverlayTargetOfTargetEnabled == nil then
        combat.debuffOverlayTargetOfTargetEnabled = true
    end
    if combat.debuffOverlayDefaultMigrationApplied ~= true then
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
    return combat
end

--- M.RefreshPlayerDebuffOverlayFromSettings: Refreshes the player frame's condition border
--   and dispel tracking overlay based on current combat settings and locked state.
M.RefreshPlayerDebuffOverlayFromSettings = function()
    local frame = _G.MidnightUI_PlayerFrame
    local cb = _G.MidnightUI_ConditionBorder
    if frame and cb and cb.Update then
        cb.Update(frame)
    end
    if _G.MidnightUI_RefreshDispelTrackingOverlay then
        _G.MidnightUI_RefreshDispelTrackingOverlay(frame)
    end
    local locked = true
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
        locked = MidnightUISettings.Messenger.locked ~= false
    end
    if _G.MidnightUI_SetDispelTrackingLocked then
        _G.MidnightUI_SetDispelTrackingLocked(locked)
    end
end

--- M.RefreshCombatDebuffOverlayScope: Refreshes debuff overlays for a specific scope.
-- @param scope (string) - "global", "player", "focus", "party", "raid", or "targetOfTarget"
M.RefreshCombatDebuffOverlayScope = function(scope)
    if scope == "global" or scope == "player" then
        M.RefreshPlayerDebuffOverlayFromSettings()
    end
    if scope == "global" or scope == "focus" then
        if _G.MidnightUI_RefreshFocusFrame then
            _G.MidnightUI_RefreshFocusFrame()
        end
    end
    if scope == "global" or scope == "party" then
        if _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
            _G.MidnightUI_RefreshPartyDispelTrackingOverlay(false)
        elseif _G.MidnightUI_RefreshPartyFrames then
            _G.MidnightUI_RefreshPartyFrames()
        end
    end
    if scope == "global" or scope == "raid" then
        if _G.MidnightUI_RefreshRaidDebuffOverlay then
            _G.MidnightUI_RefreshRaidDebuffOverlay("settings-ui")
        end
    end
    if scope == "global" or scope == "targetOfTarget" then
        if _G.MidnightUI_RefreshTargetOfTargetDebuffOverlay then
            _G.MidnightUI_RefreshTargetOfTargetDebuffOverlay()
        end
    end
end

local hDebuffs1 = CreateSectionHeader(pDebuffs, "Visual Alert"); hDebuffs1:SetPoint("TOPLEFT", PAGE_INSET_X, -2)

local debuffBorderDesc = pDebuffs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
debuffBorderDesc:SetPoint("TOPLEFT", hDebuffs1, "BOTTOMLEFT", 2, -6)
debuffBorderDesc:SetWidth(340)
debuffBorderDesc:SetJustifyH("LEFT")
debuffBorderDesc:SetText("Shows a coloured glow border around your Player Frame when you pick up a harmful debuff. Poison = green, Bleed = red, Magic = blue, Curse = purple, Disease = brown.")
debuffBorderDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

SettingsControls.chkDebuffBorder = CreateFrame("CheckButton", nil, pDebuffs, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkDebuffBorder:SetPoint("TOPLEFT", PAGE_INSET_X, -82)
SettingsControls.chkDebuffBorder.Text:SetText("Player Glow Border")
SettingsControls.chkDebuffBorder.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkDebuffBorder:SetScript("OnClick", function(self)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.debuffBorderEnabled = (self:GetChecked() == true)
    M.RefreshPlayerDebuffOverlayFromSettings()
end)

M.CreateDebuffOverlayToggleCard = function(parent, title, description, isChecked, onToggle)
    return CreateToggleControlCard(parent, title, description, isChecked, function(v)
        if onToggle then
            onToggle(v)
        end
    end, { height = 66, wrapTitle = false })
end

SettingsControls.hDebuffScope = CreateSectionHeader(pDebuffs, "Debuff Overlay Controls")
SettingsControls.hDebuffScope:SetPoint("TOPLEFT", PAGE_INSET_X, -140)
SettingsControls.fsDebuffScopeDesc = pDebuffs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SettingsControls.fsDebuffScopeDesc:SetPoint("TOPLEFT", SettingsControls.hDebuffScope, "BOTTOMLEFT", 2, -6)
SettingsControls.fsDebuffScopeDesc:SetWidth(460)
SettingsControls.fsDebuffScopeDesc:SetJustifyH("LEFT")
SettingsControls.fsDebuffScopeDesc:SetText("Master Control toggles all debuff overlays together. Per-Frame Controls let you keep overlays only where you need them.")
SettingsControls.fsDebuffScopeDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

SettingsControls.chkDebuffOverlayGlobal = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Enable All Debuff Overlays",
    "Turns all frame debuff overlays on or off in one action.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayGlobalEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayGlobalEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("global")
    end
)
SettingsControls.chkDebuffOverlayGlobal:ClearAllPoints()
SettingsControls.chkDebuffOverlayGlobal:SetPoint("TOPLEFT", PAGE_INSET_X, -190)
SettingsControls.chkDebuffOverlayGlobal:SetPoint("TOPRIGHT", -PAGE_INSET_X, -190)

SettingsControls.hDebuffPerFrame = CreateSectionHeader(pDebuffs, "Per-Frame Controls")
SettingsControls.hDebuffPerFrame:SetPoint("TOPLEFT", PAGE_INSET_X, -266)

SettingsControls.chkDebuffOverlayPlayer = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Player Debuff Overlay",
    "Player frame border and debuff overlay visuals.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayPlayerEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayPlayerEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("player")
    end
)

SettingsControls.chkDebuffOverlayFocus = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Focus Debuff Overlay",
    "Focus frame debuff overlay visuals.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayFocusEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayFocusEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("focus")
    end
)

SettingsControls.chkDebuffOverlayParty = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Party Debuff Overlay",
    "Party frame debuff overlay visuals.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayPartyEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayPartyEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("party")
    end
)

SettingsControls.chkDebuffOverlayRaid = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Raid Debuff Overlay",
    "Raid frame debuff overlay visuals.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayRaidEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayRaidEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("raid")
    end
)

SettingsControls.chkDebuffOverlayTargetOfTarget = M.CreateDebuffOverlayToggleCard(
    pDebuffs,
    "Target of Target Debuff Overlay",
    "Target of Target frame debuff overlay visuals.",
    M.EnsureCombatDebuffOverlaySettings().debuffOverlayTargetOfTargetEnabled ~= false,
    function(v)
        local combat = M.EnsureCombatDebuffOverlaySettings()
        combat.debuffOverlayTargetOfTargetEnabled = v and true or false
        M.RefreshCombatDebuffOverlayScope("targetOfTarget")
    end
)

SettingsControls.debuffOverlayCards = {
    SettingsControls.chkDebuffOverlayPlayer,
    SettingsControls.chkDebuffOverlayFocus,
    SettingsControls.chkDebuffOverlayParty,
    SettingsControls.chkDebuffOverlayRaid,
    SettingsControls.chkDebuffOverlayTargetOfTarget,
}
LayoutCardsTwoColumn(SettingsControls.debuffOverlayCards, PAGE_INSET_X, -292, COL_GAP, 84, 220)

SettingsControls.hDispel = CreateSectionHeader(pDebuffs, "Tracking Overlay")
SettingsControls.hDispel:SetPoint("TOPLEFT", PAGE_INSET_X, -560)
SettingsControls.fsTrackingDesc = pDebuffs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SettingsControls.fsTrackingDesc:SetPoint("TOPLEFT", SettingsControls.hDispel, "BOTTOMLEFT", 2, -6)
SettingsControls.fsTrackingDesc:SetWidth(340)
SettingsControls.fsTrackingDesc:SetJustifyH("LEFT")
SettingsControls.fsTrackingDesc:SetText("Shows dispel-ready icons on your Player Frame so you can react quickly.")
SettingsControls.fsTrackingDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

SettingsControls.chkDispelTracking = CreateFrame("CheckButton", nil, pDebuffs, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkDispelTracking:SetPoint("TOPLEFT", PAGE_INSET_X, -612)
SettingsControls.chkDispelTracking.Text:SetText("Enable Tracking Overlay")
SettingsControls.chkDispelTracking.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkDispelTracking:SetScript("OnClick", function(self)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.dispelTrackingEnabled = (self:GetChecked() == true)
    M.RefreshPlayerDebuffOverlayFromSettings()
end)

SettingsControls.slDispelTrackingMax = CreateSlider(pDebuffs, "Dispel Tracking Max", 1, 20, 1, 8, function(v)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.dispelTrackingMaxShown = math.floor(v + 0.5)
    if _G.MidnightUI_RefreshDispelTrackingOverlay then
        _G.MidnightUI_RefreshDispelTrackingOverlay(_G.MidnightUI_PlayerFrame)
    end
end)
SettingsControls.slDispelTrackingMax:SetPoint("TOPLEFT", PAGE_INSET_X, -654)

SettingsControls.slDispelTrackingIconSize = CreateSlider(pDebuffs, "Dispel Tracking Icon Size %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.dispelTrackingIconScale = math.floor(v + 0.5)
    if _G.MidnightUI_RefreshDispelTrackingOverlay then
        _G.MidnightUI_RefreshDispelTrackingOverlay(_G.MidnightUI_PlayerFrame)
    end
end)
SettingsControls.slDispelTrackingIconSize:SetPoint("TOPLEFT", PAGE_INSET_X, -696)

SettingsControls.ddDispelTrackingOrientation = CreateDropdown(pDebuffs, "Dispel Tracking Orientation", {"Horizontal", "Vertical"}, "Horizontal", function(v)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    if v == "Vertical" then
        MidnightUISettings.Combat.dispelTrackingOrientation = "VERTICAL"
    else
        MidnightUISettings.Combat.dispelTrackingOrientation = "HORIZONTAL"
    end
    if _G.MidnightUI_RefreshDispelTrackingOverlay then
        _G.MidnightUI_RefreshDispelTrackingOverlay(_G.MidnightUI_PlayerFrame)
    end
end)
SettingsControls.ddDispelTrackingOrientation:SetPoint("TOPLEFT", PAGE_INSET_X, -738)

SettingsControls.hPartyIcons = CreateSectionHeader(pDebuffs, "Party Icons")
SettingsControls.hPartyIcons:SetPoint("TOPLEFT", PAGE_INSET_X, -780)
SettingsControls.fsPartyDesc = pDebuffs:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SettingsControls.fsPartyDesc:SetPoint("TOPLEFT", SettingsControls.hPartyIcons, "BOTTOMLEFT", 2, -6)
SettingsControls.fsPartyDesc:SetWidth(340)
SettingsControls.fsPartyDesc:SetJustifyH("LEFT")
SettingsControls.fsPartyDesc:SetText("Adds icons to party frames showing who is dispel-ready when you have a target.")
SettingsControls.fsPartyDesc:SetTextColor(UI_COLORS.textMuted[1], UI_COLORS.textMuted[2], UI_COLORS.textMuted[3])

SettingsControls.chkPartyDispelTracking = CreateFrame("CheckButton", nil, pDebuffs, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkPartyDispelTracking:SetPoint("TOPLEFT", PAGE_INSET_X, -830)
SettingsControls.chkPartyDispelTracking.Text:SetText("Party Tracking Icons")
SettingsControls.chkPartyDispelTracking.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkPartyDispelTracking:SetScript("OnClick", function(self)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.partyDispelTrackingEnabled = (self:GetChecked() == true)
    if _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
        _G.MidnightUI_RefreshPartyDispelTrackingOverlay(false)
    elseif _G.MidnightUI_RefreshPartyFrames then
        _G.MidnightUI_RefreshPartyFrames()
    end
end)

SettingsControls.slPartyDispelTrackingIconSize = CreateSlider(pDebuffs, "Party Dispel Icon Size %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.Combat then MidnightUISettings.Combat = {} end
    MidnightUISettings.Combat.partyDispelTrackingIconScale = math.floor(v + 0.5)
    if _G.MidnightUI_RefreshPartyDispelTrackingOverlay then
        _G.MidnightUI_RefreshPartyDispelTrackingOverlay(false)
    elseif _G.MidnightUI_RefreshPartyFrames then
        _G.MidnightUI_RefreshPartyFrames()
    end
end)
SettingsControls.slPartyDispelTrackingIconSize:SetPoint("TOPLEFT", PAGE_INSET_X, -872)
M.ComputeDebuffOverlayCardsBottomY = function()
    local parentTop = pDebuffs and pDebuffs.GetTop and pDebuffs:GetTop()
    if parentTop then
        local lowestBottom = nil
        for _, card in ipairs(SettingsControls.debuffOverlayCards or {}) do
            if card and card.GetBottom then
                local bottom = card:GetBottom()
                if bottom and (not lowestBottom or bottom < lowestBottom) then
                    lowestBottom = bottom
                end
            end
        end
        if lowestBottom then
            return lowestBottom - parentTop
        end
    end

    local parentWidth = (pDebuffs and pDebuffs.GetWidth and pDebuffs:GetWidth()) or 0
    if parentWidth <= 0 and pDebuffsScroll and pDebuffsScroll.GetWidth then
        parentWidth = pDebuffsScroll:GetWidth() or 520
    end
    if parentWidth <= 0 then
        parentWidth = 520
    end

    local usableWidth = math.max(220, parentWidth - (PAGE_INSET_X * 2))
    local columns = 2
    local cardWidth = math.floor((usableWidth - COL_GAP) / 2)
    if cardWidth < 220 then
        columns = 1
    end

    local rows = math.ceil((SettingsControls.debuffOverlayCards and #SettingsControls.debuffOverlayCards or 0) / columns)
    return -292 - ((rows - 1) * 84) - 66
end

M.LayoutCombatDebuffsSections = function()
    local cardsBottomY = M.ComputeDebuffOverlayCardsBottomY()
    local hDispelY = cardsBottomY - 34

    SettingsControls.hDispel:ClearAllPoints()
    SettingsControls.hDispel:SetPoint("TOPLEFT", PAGE_INSET_X, hDispelY)

    SettingsControls.chkDispelTracking:ClearAllPoints()
    SettingsControls.chkDispelTracking:SetPoint("TOPLEFT", SettingsControls.hDispel, "BOTTOMLEFT", 0, -52)

    SettingsControls.slDispelTrackingMax:ClearAllPoints()
    SettingsControls.slDispelTrackingMax:SetPoint("TOPLEFT", SettingsControls.chkDispelTracking, "BOTTOMLEFT", 0, -12)

    SettingsControls.slDispelTrackingIconSize:ClearAllPoints()
    SettingsControls.slDispelTrackingIconSize:SetPoint("TOPLEFT", SettingsControls.slDispelTrackingMax, "BOTTOMLEFT", 0, -12)

    SettingsControls.ddDispelTrackingOrientation:ClearAllPoints()
    SettingsControls.ddDispelTrackingOrientation:SetPoint("TOPLEFT", SettingsControls.slDispelTrackingIconSize, "BOTTOMLEFT", 0, -12)

    SettingsControls.hPartyIcons:ClearAllPoints()
    SettingsControls.hPartyIcons:SetPoint("TOPLEFT", SettingsControls.ddDispelTrackingOrientation, "BOTTOMLEFT", 0, -22)

    SettingsControls.chkPartyDispelTracking:ClearAllPoints()
    SettingsControls.chkPartyDispelTracking:SetPoint("TOPLEFT", SettingsControls.hPartyIcons, "BOTTOMLEFT", 0, -50)

    SettingsControls.slPartyDispelTrackingIconSize:ClearAllPoints()
    SettingsControls.slPartyDispelTrackingIconSize:SetPoint("TOPLEFT", SettingsControls.chkPartyDispelTracking, "BOTTOMLEFT", 0, -12)

    local parentTop = pDebuffs and pDebuffs.GetTop and pDebuffs:GetTop()
    local lastBottom = SettingsControls.slPartyDispelTrackingIconSize and SettingsControls.slPartyDispelTrackingIconSize.GetBottom and SettingsControls.slPartyDispelTrackingIconSize:GetBottom()
    if parentTop and lastBottom then
        local usedHeight = parentTop - lastBottom
        pDebuffs:SetHeight(math.max(1020, math.floor(usedHeight + 48)))
    else
        pDebuffs:SetHeight(1120)
    end
end

M.QueueCombatDebuffsReflow = function()
    M.LayoutCombatDebuffsSections()
    if C_Timer and C_Timer.After then
        C_Timer.After(0, M.LayoutCombatDebuffsSections)
        C_Timer.After(0.06, M.LayoutCombatDebuffsSections)
    end
end

pDebuffs:HookScript("OnShow", M.QueueCombatDebuffsReflow)
pDebuffs:HookScript("OnSizeChanged", M.QueueCombatDebuffsReflow)
if pDebuffsScroll then
    pDebuffsScroll:HookScript("OnSizeChanged", M.QueueCombatDebuffsReflow)
end
M.QueueCombatDebuffsReflow()
end -- scope: debuffs page locals

--- ApplyNameplateUIValues: Pushes Nameplates settings into the nameplate slider/checkbox controls.
-- @param n (table) - MidnightUISettings.Nameplates
-- @param c (table) - targetNpControls map of control references
local function ApplyNameplateUIValues(n, c)
    if not n or not c then return end
    if c.masterToggle then c.masterToggle:SetChecked(n.enabled ~= false) end
    if c.borderToggle then c.borderToggle:SetChecked(n.showFactionBorder ~= false) end
    if c.selectedBorderToggle then c.selectedBorderToggle:SetChecked(n.targetBorder ~= false) end
    if c.pulseToggle then c.pulseToggle:SetChecked(n.targetPulse ~= false) end
    if c.scale and c.scale.SetValue then c.scale.SetValue(nil, n.scale or 100) end
    if n.healthBar then
        if c.healthWidth and c.healthWidth.SetValue then c.healthWidth.SetValue(nil, n.healthBar.width or 200) end
        if c.healthHeight and c.healthHeight.SetValue then c.healthHeight.SetValue(nil, n.healthBar.height or 20) end
        if c.healthAlpha and c.healthAlpha.SetValue then c.healthAlpha.SetValue(nil, n.healthBar.alpha or 1.0) end
        if c.nonTargetAlpha and c.nonTargetAlpha.SetValue then c.nonTargetAlpha.SetValue(nil, n.healthBar.nonTargetAlpha or n.healthBar.alpha or 1.0) end
        if c.nameFont and c.nameFont.SetValue then c.nameFont.SetValue(nil, n.healthBar.nameFontSize or 10) end
        if c.pctFont and c.pctFont.SetValue then c.pctFont.SetValue(nil, n.healthBar.healthPctFontSize or 9) end
        if c.nameAlign then
            local a = n.healthBar.nameAlign or "LEFT"
            if a == "CENTER" then c.nameAlign.SetValue(nil, "Center")
            elseif a == "RIGHT" then c.nameAlign.SetValue(nil, "Right")
            else c.nameAlign.SetValue(nil, "Left") end
        end
        if c.pctDisplay then
            local d = n.healthBar.healthPctDisplay or "RIGHT"
            if d == "HIDE" then c.pctDisplay.SetValue(nil, "Hidden")
            elseif d == "LEFT" then c.pctDisplay.SetValue(nil, "Left")
            else c.pctDisplay.SetValue(nil, "Right") end
        end
    end
    if n.threatBar then
        if c.threatToggle then c.threatToggle:SetChecked(n.threatBar.enabled ~= false) end
        if c.threatWidth and c.threatWidth.SetValue then c.threatWidth.SetValue(nil, n.threatBar.width or 200) end
        if c.threatHeight and c.threatHeight.SetValue then c.threatHeight.SetValue(nil, n.threatBar.height or 5) end
        if c.threatAlpha and c.threatAlpha.SetValue then c.threatAlpha.SetValue(nil, n.threatBar.alpha or 1.0) end
    end
    if n.castBar then
        if c.castWidth and c.castWidth.SetValue then c.castWidth.SetValue(nil, n.castBar.width or 200) end
        if c.castHeight and c.castHeight.SetValue then c.castHeight.SetValue(nil, n.castBar.height or 16) end
        if c.castFont and c.castFont.SetValue then c.castFont.SetValue(nil, n.castBar.fontSize or 12) end
        if c.castAlpha and c.castAlpha.SetValue then c.castAlpha.SetValue(nil, n.castBar.alpha or 1.0) end
    end
    if n.target then
        if c.tScale and c.tScale.SetValue then c.tScale.SetValue(nil, n.target.scale or 100) end
        if n.target.healthBar then
            if c.tHealthWidth and c.tHealthWidth.SetValue then c.tHealthWidth.SetValue(nil, n.target.healthBar.width or 240) end
            if c.tHealthHeight and c.tHealthHeight.SetValue then c.tHealthHeight.SetValue(nil, n.target.healthBar.height or 24) end
            if c.tNameFont and c.tNameFont.SetValue then c.tNameFont.SetValue(nil, n.target.healthBar.nameFontSize or (n.healthBar and n.healthBar.nameFontSize) or 10) end
            if c.tPctFont and c.tPctFont.SetValue then c.tPctFont.SetValue(nil, n.target.healthBar.healthPctFontSize or (n.healthBar and n.healthBar.healthPctFontSize) or 9) end
        end
        if n.target.threatBar then
            if c.tThreatWidth and c.tThreatWidth.SetValue then c.tThreatWidth.SetValue(nil, n.target.threatBar.width or 240) end
            if c.tThreatHeight and c.tThreatHeight.SetValue then c.tThreatHeight.SetValue(nil, n.target.threatBar.height or 6) end
        end
        if n.target.castBar then
            if c.tCastWidth and c.tCastWidth.SetValue then c.tCastWidth.SetValue(nil, n.target.castBar.width or 240) end
            if c.tCastHeight and c.tCastHeight.SetValue then c.tCastHeight.SetValue(nil, n.target.castBar.height or 18) end
        end
    end
end

-- =========================================================================
--  PAGE: ACTION BARS > LAYOUT & STYLE
-- =========================================================================
do -- scope: action bars page locals
local pAct = actionTabs.ActionLayout
local pActTheme = actionTabs.ActionTheme
local currentBar = 1
local barBtns = {}
local abControls = {}

local function UpdActControls()
    if not abControls.head then return end
    local c = MidnightUISettings.ActionBars["bar"..currentBar]
    if not c then return end

    abControls.chk:SetChecked(c.enabled)
    abControls.rows.SetValue(nil, c.rows)
    abControls.icons.SetValue(nil, c.iconsPerRow)
    abControls.scale.SetValue(nil, c.scale)
    abControls.space.SetValue(nil, c.spacing)
    if abControls.style then abControls.style.SetValue(nil, c.style or "Class Color") end
    if abControls.globalStyle then
        local gs = MidnightUISettings.ActionBars.globalStyle or "Disabled"
        if gs == "Per Bar" then gs = "Disabled" end
        abControls.globalStyle.SetValue(nil, gs)
        if gs ~= "Disabled" then
            abControls.style:Hide()
        else
            abControls.style:Show()
            abControls.style.SetDisabled(false)
        end
    end
    abControls.head:SetText("Bar " .. currentBar .. " Settings")
end

local function SelBar(id)
    currentBar = id
    for k, b in pairs(barBtns) do
        if k == id then
            b.icon:SetVertexColor(UI_COLORS.accent[1], UI_COLORS.accent[2], UI_COLORS.accent[3])
            b.bg:SetColorTexture(0, 0.18, 0.28, 0.7)
        else
            b.icon:SetVertexColor(0.45, 0.45, 0.45)
            b.bg:SetColorTexture(0.08, 0.08, 0.12, 0.6)
        end
    end
    UpdActControls()
end

-- Bar selector
local abSelContainer = CreateFrame("Frame", nil, pAct)
abSelContainer:SetSize(440, 68); abSelContainer:SetPoint("TOPLEFT", PAGE_INSET_X, -10)
local abSelLbl = abSelContainer:CreateFontString(nil, "OVERLAY", "GameFontNormal")
abSelLbl:SetPoint("TOPLEFT", 0, 0)
abSelLbl:SetText("Select Bar:")
abSelLbl:SetTextColor(UI_COLORS.textPrimary[1], UI_COLORS.textPrimary[2], UI_COLORS.textPrimary[3])

for i = 1, 8 do
    local b = CreateFrame("Button", nil, abSelContainer, "BackdropTemplate")
    b:SetSize(36, 36); b:SetPoint("TOPLEFT", (i-1)*46, -22)
    b:SetBackdrop({ edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 10 })
    b:SetBackdropBorderColor(UI_COLORS.cardBorder[1], UI_COLORS.cardBorder[2], UI_COLORS.cardBorder[3], 1)
    b.bg = b:CreateTexture(nil, "BACKGROUND"); b.bg:SetAllPoints()
    b.bg:SetColorTexture(0.08, 0.08, 0.12, 0.6)
    b.icon = b:CreateTexture(nil, "ARTWORK"); b.icon:SetTexture(136518); b.icon:SetPoint("CENTER"); b.icon:SetSize(20,20)
    b.txt = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"); b.txt:SetPoint("BOTTOMRIGHT", -3, 3); b.txt:SetText(i)
    b:SetScript("OnClick", function() SelBar(i) end)
    barBtns[i] = b
end

abControls.head = CreateSectionHeader(pAct, "Bar 1 Settings")
abControls.head:SetPoint("TOPLEFT", PAGE_INSET_X, -84)

abControls.chk = CreateFrame("CheckButton", nil, pAct, "InterfaceOptionsCheckButtonTemplate")
abControls.chk:SetPoint("TOPLEFT", PAGE_INSET_X, -128); abControls.chk.Text:SetText("Enable This Bar")
abControls.chk.Text:SetFontObject("GameFontNormalSmall")
abControls.chk:SetScript("OnClick", function(self) MidnightUISettings.ActionBars["bar"..currentBar].enabled = self:GetChecked(); M.ApplyActionBarSettings() end)

abControls.rows = CreateSlider(pAct, "Rows", 1, 12, 1, 1, function(v)
    local c = MidnightUISettings.ActionBars["bar"..currentBar]
    if v*c.iconsPerRow > 12 then local fix = math.floor(12/c.iconsPerRow); MidnightUISettings.ActionBars["bar"..currentBar].rows = fix; abControls.rows.SetValue(nil, fix)
    else MidnightUISettings.ActionBars["bar"..currentBar].rows = math.floor(v) end
    M.ApplyActionBarSettings()
end)
abControls.icons = CreateSlider(pAct, "Icons Per Row", 1, 12, 1, 12, function(v)
    local c = MidnightUISettings.ActionBars["bar"..currentBar]
    if c.rows*v > 12 then local fix = math.floor(12/c.rows); MidnightUISettings.ActionBars["bar"..currentBar].iconsPerRow = fix; abControls.icons.SetValue(nil, fix)
    else MidnightUISettings.ActionBars["bar"..currentBar].iconsPerRow = math.floor(v) end
    M.ApplyActionBarSettings()
end)
LayoutCardsTwoColumn({abControls.rows, abControls.icons}, PAGE_INSET_X, -160, COL_GAP, ROW_GAP, 180)

-- Style page
abControls.globalStyle = CreateDropdown(pActTheme, "Global Style Override", {"Disabled", "Class Color", "Faithful", "Glass", "Hidden"}, MidnightUISettings.ActionBars.globalStyle or "Disabled", function(v)
    MidnightUISettings.ActionBars.globalStyle = v
    M.ApplyActionBarSettings()
    UpdActControls()
end)
abControls.style = CreateDropdown(pActTheme, "Per-Bar Style", {"Class Color", "Faithful", "Glass", "Hidden"}, MidnightUISettings.ActionBars["bar"..currentBar].style or "Class Color", function(v)
    MidnightUISettings.ActionBars["bar"..currentBar].style = v
    if MidnightUISettings.ActionBars.globalStyle and MidnightUISettings.ActionBars.globalStyle ~= "Disabled" then
        MidnightUISettings.ActionBars.globalStyle = "Disabled"
        if abControls.globalStyle and abControls.globalStyle.SetValue then
            abControls.globalStyle:SetValue("Disabled")
        end
    end
    M.ApplyActionBarSettings()
end)
LayoutCardsTwoColumn({abControls.globalStyle, abControls.style}, PAGE_INSET_X, -12, COL_GAP, ROW_GAP, 180)

abControls.scale = CreateSlider(pActTheme, "Scale %", 50, 200, 5, 100, function(v) MidnightUISettings.ActionBars["bar"..currentBar].scale = math.floor(v); M.ApplyActionBarSettings() end)
abControls.space = CreateSlider(pActTheme, "Button Spacing", 0, 30, 1, 6, function(v) MidnightUISettings.ActionBars["bar"..currentBar].spacing = math.floor(v); M.ApplyActionBarSettings() end)
LayoutCardsTwoColumn({abControls.scale, abControls.space}, PAGE_INSET_X, -100, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: ACTION BARS > PET BAR
-- =========================================================================
local pPetBar = actionTabs.PetBar
SettingsControls.chkPetBar = CreateFrame("CheckButton", nil, pPetBar, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkPetBar:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkPetBar.Text:SetText("Enable Pet Bar")
SettingsControls.chkPetBar.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkPetBar:SetScript("OnClick", function(self)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.enabled = (self:GetChecked() == true)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)

SettingsControls.slPetScale = CreateSlider(pPetBar, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.scale = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slPetAlpha = CreateSlider(pPetBar, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.alpha = v
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slPetSize = CreateSlider(pPetBar, "Button Size", 20, 56, 1, 32, function(v)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.buttonSize = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slPetSpacing = CreateSlider(pPetBar, "Spacing", 0, 30, 1, 15, function(v)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.spacing = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slPetColumns = CreateSlider(pPetBar, "Per Row", 1, 10, 1, 10, function(v)
    if not MidnightUISettings.PetBar then MidnightUISettings.PetBar = {} end
    MidnightUISettings.PetBar.buttonsPerRow = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slPetScale, SettingsControls.slPetAlpha, SettingsControls.slPetSize, SettingsControls.slPetSpacing, SettingsControls.slPetColumns}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

-- =========================================================================
--  PAGE: ACTION BARS > STANCE BAR
-- =========================================================================
local pStanceBar = actionTabs.StanceBar
SettingsControls.chkStanceBar = CreateFrame("CheckButton", nil, pStanceBar, "InterfaceOptionsCheckButtonTemplate")
SettingsControls.chkStanceBar:SetPoint("TOPLEFT", PAGE_INSET_X, -4); SettingsControls.chkStanceBar.Text:SetText("Enable Stance Bar")
SettingsControls.chkStanceBar.Text:SetFontObject("GameFontNormalSmall")
SettingsControls.chkStanceBar:SetScript("OnClick", function(self)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    MidnightUISettings.StanceBar.enabled = (self:GetChecked() == true)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)

SettingsControls.slStanceScale = CreateSlider(pStanceBar, "Scale %", 50, 200, 5, 100, function(v)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    MidnightUISettings.StanceBar.scale = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slStanceAlpha = CreateSlider(pStanceBar, "Opacity", 0.1, 1.0, 0.05, 1.0, function(v)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    MidnightUISettings.StanceBar.alpha = v
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slStanceSize = CreateSlider(pStanceBar, "Button Size", 20, 56, 1, 32, function(v)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    MidnightUISettings.StanceBar.buttonSize = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slStanceSpacing = CreateSlider(pStanceBar, "Spacing", -6, 30, 1, 4, function(v)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    MidnightUISettings.StanceBar.spacing = math.floor(v)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
SettingsControls.slStanceColumns = CreateSlider(pStanceBar, "Per Row", 1, 4, 1, 3, function(v)
    if not MidnightUISettings.StanceBar then MidnightUISettings.StanceBar = {} end
    local maxStances = 4
    if GetNumShapeshiftForms then
        local forms = GetNumShapeshiftForms()
        if forms and forms > 0 then maxStances = forms end
    end
    MidnightUISettings.StanceBar.buttonsPerRow = math.min(math.floor(v), maxStances)
    if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
    elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
end)
LayoutCardsTwoColumn({SettingsControls.slStanceScale, SettingsControls.slStanceAlpha, SettingsControls.slStanceSize, SettingsControls.slStanceSpacing, SettingsControls.slStanceColumns}, PAGE_INSET_X, -34, COL_GAP, ROW_GAP, 180)

end -- scope: action bars page locals

-- =========================================================================
--  PAGE: RAID FRAMES > RAID
-- =========================================================================
BuildRaidFramesTab(raidTabs, SettingsControls, M.ApplyRaidFramesSettings)

-- =========================================================================
--  RESET OVERLAY DEFAULTS
-- =========================================================================

local function ResetOverlayDefaults(reopenWelcome)
    if not MidnightUISettings then return end

    local function LogReset(msg)
        local wrote = false
        if _G.MidnightUI_Diagnostics
            and _G.MidnightUI_Diagnostics.LogDebugSource
            and _G.MidnightUI_Diagnostics.IsEnabled
            and _G.MidnightUI_Diagnostics.IsEnabled()
        then
            _G.MidnightUI_Diagnostics.LogDebugSource("Settings", msg)
            wrote = true
        end
        if not wrote and _G.MidnightUI_Debug then
            _G.MidnightUI_Debug("[Settings] " .. tostring(msg))
            wrote = true
        end
        if not wrote then
            if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
                _G.DEFAULT_CHAT_FRAME:AddMessage("MidnightUI Settings: " .. tostring(msg))
            else
                print("MidnightUI Settings: " .. tostring(msg))
            end
        end
    end
    if InCombatLockdown and InCombatLockdown() then
        LogReset("Reset blocked: InCombatLockdown")
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r Reload blocked in combat.")
        end
        return
    end

    MidnightUISettings.PendingReset = true
    MidnightUISettings.PendingResetReopenWelcome = (reopenWelcome == true)
    if type(ReloadUI) == "function" then
        ReloadUI()
    else
        LogReset("ReloadUI missing after reset")
    end
end

btnResetOverlays:SetScript("OnClick", function()
    ResetOverlayDefaults(true)
end)

-- ============================================================================
-- INIT: WIRE UP TOOLTIPS AND CLOSE BuildSettingsUI
-- AutoAttachTooltips walks the entire ConfigFrame tree and attaches matching
-- TOOLTIP_LABELS tooltips to every checkbox/button whose text is in the table.
-- ============================================================================

AutoAttachTooltips(ConfigFrame)
_G.MidnightUI_Tooltips = TOOLTIP_LABELS
end

BuildSettingsUI()

-- ============================================================================
-- ON-SHOW REFRESH
-- Every time the settings panel opens, ApplySettingsOnShow reads all current
-- MidnightUISettings values and pushes them into the UI controls (sliders,
-- checkboxes, dropdowns). This ensures the panel always reflects live state.
-- ============================================================================

--- ApplySettingsOnShow: Syncs all settings controls with current MidnightUISettings values.
-- @param controls (table) - SettingsControls table with named control references
-- @calledby ConfigFrame:OnShow
local function ApplySettingsOnShow(controls)
    M.EnsureCastBarsSettings()
    M.EnsureNameplateSettings()
    if M.ShowPage then M.ShowPage("Interface") end
    if M.SelBar then M.SelBar(1) end

    local m = MidnightUISettings.Messenger
    if controls.ddGlobalStyle then controls.ddGlobalStyle.SetValue(nil, MidnightUISettings.GlobalStyle or "Default") end
  if controls.ddUnitBarStyle then
      local v = MidnightUISettings.General and MidnightUISettings.General.unitFrameBarStyle or "Gradient"
      controls.ddUnitBarStyle.SetValue(nil, v)
  end
  if controls.ddUnitFrameNameScale then
      local v = math.max(50, math.min(150, tonumber(MidnightUISettings.General and MidnightUISettings.General.unitFrameNameScale) or 100))
      controls.ddUnitFrameNameScale.SetValue(nil, tostring(v))
  end
  if controls.ddUnitFrameValueScale then
      local v = math.max(50, math.min(150, tonumber(MidnightUISettings.General and MidnightUISettings.General.unitFrameValueScale) or 100))
      controls.ddUnitFrameValueScale.SetValue(nil, tostring(v))
  end
  if controls.ddUnitFrameTextOutline then
      local current = MidnightUISettings.General and MidnightUISettings.General.unitFrameTextOutline or "OUTLINE"
      local label = "Outline"
      if current == "NONE" then
          label = "None"
      elseif current == "THICKOUTLINE" then
          label = "Thick Outline"
      end
      controls.ddUnitFrameTextOutline.SetValue(nil, label)
  end
  if controls.chkShowUnitFrameLevelText then
      controls.chkShowUnitFrameLevelText:SetChecked(not (MidnightUISettings.General and MidnightUISettings.General.unitFrameHideLevelText == true))
  end
  if controls.chkShowUnitFramePowerText then
      controls.chkShowUnitFramePowerText:SetChecked(not (MidnightUISettings.General and MidnightUISettings.General.unitFrameHidePowerText == true))
  end
  if controls.chkCustomTooltips then
      controls.chkCustomTooltips:SetChecked(MidnightUISettings.General and MidnightUISettings.General.customTooltips ~= false)
  end
  if controls.chkForceCursorTooltips then
      controls.chkForceCursorTooltips:SetChecked(MidnightUISettings.General and MidnightUISettings.General.forceCursorTooltips == true)
  end
  if controls.cbTime then controls.cbTime:SetChecked(m.showTimestamp) end
  if controls.cbGlobal then controls.cbGlobal:SetChecked(m.hideGlobal == true) end
  if controls.cbLoginStates then controls.cbLoginStates:SetChecked(m.hideLoginStates == true) end
  if controls.chkDebugHidden then controls.chkDebugHidden:SetChecked(m.keepDebugHidden == true) end
    if controls.ddChatStyle then controls.ddChatStyle.SetValue(nil, m.style or "Default") end
    if controls.slMAlpha then controls.slMAlpha.SetValue(nil, m.alpha) end
    if controls.slMWidth then controls.slMWidth.SetValue(nil, m.width) end
    if controls.slMHeight then controls.slMHeight.SetValue(nil, m.height) end
    if controls.slMScale then controls.slMScale.SetValue(nil, (m.scale or 1.0) * 100) end
    if controls.slMFontSize then controls.slMFontSize.SetValue(nil, m.fontSize or 14) end
    if controls.slMTabSpacing then controls.slMTabSpacing.SetValue(nil, m.mainTabSpacing or 40) end
    if MidnightUISettings.RaidFrames then
        if controls.chkRaidGroupBy then controls.chkRaidGroupBy:SetChecked(MidnightUISettings.RaidFrames.groupBy == true) end
        if controls.chkRaidGroupColor then controls.chkRaidGroupColor:SetChecked(MidnightUISettings.RaidFrames.colorByGroup ~= false) end
        if controls.chkRaidGroupBrackets then controls.chkRaidGroupBrackets:SetChecked(MidnightUISettings.RaidFrames.groupBrackets ~= false) end
        if controls.chkRaidShowPct then controls.chkRaidShowPct:SetChecked(MidnightUISettings.RaidFrames.showHealthPct ~= false) end
        if controls.slRaidColumns then
            local maxCols = _G.MidnightUI_GetRaidMaxColumns and _G.MidnightUI_GetRaidMaxColumns() or 40
            local groupLocked = (MidnightUISettings.RaidFrames.groupBy == true)
            if groupLocked then maxCols = math.min(maxCols, 5) end
            if controls.slRaidColumns._slider and controls.slRaidColumns._slider.SetMinMaxValues then
                controls.slRaidColumns._slider:SetMinMaxValues(1, maxCols)
            elseif controls.slRaidColumns.SetRange then
                controls.slRaidColumns.SetRange(nil, 1, maxCols)
            end
            if controls.slRaidColumnsGrouped and controls.slRaidColumnsGrouped._slider and controls.slRaidColumnsGrouped._slider.SetMinMaxValues then
                controls.slRaidColumnsGrouped._slider:SetMinMaxValues(1, 5)
            end
            local v = MidnightUISettings.RaidFrames.columns or 5
            if v > maxCols then v = maxCols; MidnightUISettings.RaidFrames.columns = maxCols end
            controls.slRaidColumns.SetValue(nil, v)
            if controls.slRaidColumnsGrouped then
                controls.slRaidColumnsGrouped.SetValue(nil, math.min(v, 5))
                if groupLocked then
                    controls.slRaidColumns:Hide()
                    controls.slRaidColumnsGrouped:Show()
                else
                    controls.slRaidColumnsGrouped:Hide()
                    controls.slRaidColumns:Show()
                end
            end
        end
        if controls.slRaidTextSize then controls.slRaidTextSize.SetValue(nil, MidnightUISettings.RaidFrames.textSize or 9) end
        if controls.ddRaidStyle then
            local style = MidnightUISettings.RaidFrames.layoutStyle == "Simple" and "Simple" or "Rendered"
            suppressRaidStyleCallback = true
            controls.ddRaidStyle.SetValue(nil, style)
            suppressRaidStyleCallback = false
        end
        if controls.slRaidWidth then controls.slRaidWidth.SetValue(nil, MidnightUISettings.RaidFrames.width or 92) end
        if controls.slRaidHeight then
            local maxH = _G.MidnightUI_GetRaidMaxHeight and _G.MidnightUI_GetRaidMaxHeight() or 80
            local vh = MidnightUISettings.RaidFrames.height or 24
            if vh > maxH then vh = maxH; MidnightUISettings.RaidFrames.height = maxH end
            controls.slRaidHeight.SetValue(nil, vh)
        end
        if controls.slRaidSpacingX then controls.slRaidSpacingX.SetValue(nil, MidnightUISettings.RaidFrames.spacingX or 6) end
        if controls.slRaidSpacingY then controls.slRaidSpacingY.SetValue(nil, MidnightUISettings.RaidFrames.spacingY or 4) end
    end
    if controls.UpdateChatModeButtons then
        controls.UpdateChatModeButtons()
    end
    if MidnightUISettings.Minimap then
        if controls.chkCoords then controls.chkCoords:SetChecked(MidnightUISettings.Minimap.coordsEnabled ~= false) end
        if controls.ddInfoBarStyle then controls.ddInfoBarStyle.SetValue(nil, MidnightUISettings.Minimap.infoBarStyle or "Default") end
        if controls.chkStatusBars then controls.chkStatusBars:SetChecked(MidnightUISettings.Minimap.useCustomStatusBars ~= false) end
    end
    if controls.chkQuestCombat then
        controls.chkQuestCombat:SetChecked(MidnightUISettings.General and MidnightUISettings.General.hideQuestObjectivesInCombat == true)
    end
    if controls.chkBlizzardQuesting then
        controls.chkBlizzardQuesting:SetChecked(not (MidnightUISettings.General and MidnightUISettings.General.useBlizzardQuestingInterface == true))
    end
    if controls.chkQuestAlways then
        controls.chkQuestAlways:SetChecked(MidnightUISettings.General and MidnightUISettings.General.hideQuestObjectivesAlways == true)
    end
    if controls.chkSuperTracked then
        controls.chkSuperTracked:SetChecked(MidnightUISettings.General and MidnightUISettings.General.useDefaultSuperTrackedIcon == true)
    end
    if controls.chkSecretPct then
        controls.chkSecretPct:SetChecked(MidnightUISettings.General and MidnightUISettings.General.allowSecretHealthPercent == true)
    end
    if controls.chkInventoryEnabled then
        controls.chkInventoryEnabled:SetChecked((not MidnightUISettings.Inventory) or MidnightUISettings.Inventory.enabled ~= false)
    end
    if controls.chkSeparateBagsInv then
        controls.chkSeparateBagsInv:SetChecked(MidnightUISettings.Inventory and MidnightUISettings.Inventory.separateBags == true)
    end

    local p = MidnightUISettings.PlayerFrame
    if controls.chkPlay then controls.chkPlay:SetChecked(p.enabled) end
    if controls.slPScale then controls.slPScale.SetValue(nil, p.scale) end
    if controls.slPAlpha then controls.slPAlpha.SetValue(nil, p.alpha) end
    if controls.slPWidth then controls.slPWidth.SetValue(nil, p.width) end
    if controls.slPHeight then controls.slPHeight.SetValue(nil, p.height) end
    if controls.chkPlayTooltip then controls.chkPlayTooltip:SetChecked(p.customTooltip ~= false) end

    if p.auras then
        if controls.chkAuras then controls.chkAuras:SetChecked(p.auras.enabled ~= false) end
        if controls.slAuraScale then controls.slAuraScale.SetValue(nil, p.auras.scale or 100) end
        if controls.slAuraAlpha then controls.slAuraAlpha.SetValue(nil, p.auras.alpha or 1.0) end
        if controls.slAuraMax then controls.slAuraMax.SetValue(nil, p.auras.maxShown or 32) end
        if controls.ddAuraAlign then controls.ddAuraAlign.SetValue(nil, p.auras.alignment or "Right") end
    end

        if p.debuffs then
            if controls.chkDebuffs then controls.chkDebuffs:SetChecked(p.debuffs.enabled ~= false) end
            if controls.slDebuffScale then controls.slDebuffScale.SetValue(nil, p.debuffs.scale or 100) end
            if controls.slDebuffAlpha then controls.slDebuffAlpha.SetValue(nil, p.debuffs.alpha or 1.0) end
            if controls.slDebuffMax then controls.slDebuffMax.SetValue(nil, p.debuffs.maxShown or 16) end
            if controls.ddDebuffAlign then controls.ddDebuffAlign.SetValue(nil, p.debuffs.alignment or "Right") end
        end

        if MidnightUISettings.ConsumableBars then
            local cb = MidnightUISettings.ConsumableBars
            if controls.chkConsEnable then controls.chkConsEnable:SetChecked(cb.enabled ~= false) end
            if controls.chkConsHideInactive then controls.chkConsHideInactive:SetChecked(cb.hideInactive == true) end
            if controls.chkConsInstanceOnly then controls.chkConsInstanceOnly:SetChecked(cb.showInInstancesOnly == true) end
            if controls.slConsWidth then controls.slConsWidth.SetValue(nil, cb.width or 220) end
            if controls.slConsHeight then controls.slConsHeight.SetValue(nil, cb.height or 10) end
            if controls.slConsSpacing then controls.slConsSpacing.SetValue(nil, cb.spacing or 4) end
            if controls.slConsScale then controls.slConsScale.SetValue(nil, cb.scale or 100) end
        end

      if MidnightUISettings.PartyFrames then
          local pf = MidnightUISettings.PartyFrames
          if controls.ddPartyLayout then controls.ddPartyLayout.SetValue(nil, pf.layout or "Vertical") end
          if controls.ddPartyStyle then
              suppressPartyStyleCallback = true
              local partyStyle = pf.style or "Rendered"
              if partyStyle == "Circular" then partyStyle = "Square" end
              controls.ddPartyStyle.SetValue(nil, partyStyle)
              suppressPartyStyleCallback = false
          end
          if controls.slPartyWidth then controls.slPartyWidth.SetValue(nil, pf.width or 240) end
          if controls.slPartyHeight then controls.slPartyHeight.SetValue(nil, pf.height or 58) end
            if controls.slPartyDiameter then controls.slPartyDiameter.SetValue(nil, pf.diameter or 64) end
            if controls.slPartySpacingX then controls.slPartySpacingX.SetValue(nil, pf.spacingX or 8) end
            if controls.slPartySpacingY then controls.slPartySpacingY.SetValue(nil, pf.spacingY or 8) end
            if controls.cbPartyTooltip then controls.cbPartyTooltip:SetChecked(pf.showTooltip ~= false) end
            if controls.cbPartyHideInRaid then controls.cbPartyHideInRaid:SetChecked(pf.hideInRaid == true) end
            if controls.cbPartyHide2DPortrait then controls.cbPartyHide2DPortrait:SetChecked(pf.hide2DPortrait == true) end
            if pf.layout == "Horizontal" then
                if controls.slPartySpacingX then controls.slPartySpacingX:Show() end
                if controls.slPartySpacingY then controls.slPartySpacingY:Hide() end
          else
              if controls.slPartySpacingX then controls.slPartySpacingX:Hide() end
              if controls.slPartySpacingY then controls.slPartySpacingY:Show() end
          end
          if pf.style == "Square" then
              if controls.slPartyWidth then controls.slPartyWidth:Hide() end
              if controls.slPartyHeight then controls.slPartyHeight:Hide() end
              if controls.slPartyDiameter then controls.slPartyDiameter:Show() end
          else
              if controls.slPartyWidth then controls.slPartyWidth:Show() end
              if controls.slPartyHeight then controls.slPartyHeight:Show() end
              if controls.slPartyDiameter then controls.slPartyDiameter:Hide() end
          end
          if UpdatePartySpacingVisibility then UpdatePartySpacingVisibility() end
          if UpdatePartyStyleVisibility then UpdatePartyStyleVisibility() end
      end

    local pb = MidnightUISettings.PetBar
    if pb then
        if controls.chkPetBar then controls.chkPetBar:SetChecked(pb.enabled ~= false) end
        if controls.slPetScale then controls.slPetScale.SetValue(nil, pb.scale or 100) end
        if controls.slPetAlpha then controls.slPetAlpha.SetValue(nil, pb.alpha or 1.0) end
        if controls.slPetSize then controls.slPetSize.SetValue(nil, pb.buttonSize or 40) end
        if controls.slPetSpacing then controls.slPetSpacing.SetValue(nil, pb.spacing or 6) end
        if controls.slPetColumns then controls.slPetColumns.SetValue(nil, pb.buttonsPerRow or 10) end
    end

    local sb = MidnightUISettings.StanceBar
    if sb then
        if controls.slStanceColumns and controls.slStanceColumns.SetRange then
            local maxStances = 3
            if GetNumShapeshiftForms then
                local forms = GetNumShapeshiftForms()
                if forms and forms > 0 then maxStances = forms end
            end
            if maxStances == 3 then
                local _, class = UnitClass("player")
                if class == "DRUID" then maxStances = 4
                elseif class == "ROGUE" then maxStances = 2
                elseif class == "MONK" then maxStances = 2
                end
            end
            maxStances = math.max(1, math.min(maxStances, 4))
            controls.slStanceColumns.SetRange(nil, 1, maxStances)
            if sb.buttonsPerRow and sb.buttonsPerRow > maxStances then
                sb.buttonsPerRow = maxStances
            end
        end
        if controls.chkStanceBar then controls.chkStanceBar:SetChecked(sb.enabled ~= false) end
        if controls.slStanceScale then controls.slStanceScale.SetValue(nil, sb.scale or 100) end
        if controls.slStanceAlpha then controls.slStanceAlpha.SetValue(nil, sb.alpha or 1.0) end
        if controls.slStanceSize then controls.slStanceSize.SetValue(nil, sb.buttonSize or 32) end
        if controls.slStanceSpacing then controls.slStanceSpacing.SetValue(nil, sb.spacing or 8) end
        if controls.slStanceColumns then controls.slStanceColumns.SetValue(nil, sb.buttonsPerRow or 6) end
    end

    if MidnightUISettings.MainTankFrames then
        local mt = MidnightUISettings.MainTankFrames
        if controls.slMTWidth then controls.slMTWidth.SetValue(nil, mt.width or 260) end
        if controls.slMTHeight then controls.slMTHeight.SetValue(nil, mt.height or 58) end
        if controls.slMTSpacing then controls.slMTSpacing.SetValue(nil, mt.spacing or 6) end
        if controls.slMTScale then controls.slMTScale.SetValue(nil, (mt.scale or 1.0) * 100) end
    end

    local t = MidnightUISettings.TargetFrame
    if controls.chkTarg then controls.chkTarg:SetChecked(t.enabled) end
    if controls.slTScale then controls.slTScale.SetValue(nil, t.scale) end
    if controls.slTAlpha then controls.slTAlpha.SetValue(nil, t.alpha) end
    if controls.slTWidth then controls.slTWidth.SetValue(nil, t.width) end
    if controls.slTHeight then controls.slTHeight.SetValue(nil, t.height) end
    if controls.chkTargTooltip then controls.chkTargTooltip:SetChecked(t.customTooltip ~= false) end
    if controls.chkTargetOfTarget then controls.chkTargetOfTarget:SetChecked(t.showTargetOfTarget == true) end

    if t.auras then
        if controls.chkTargetAuras then controls.chkTargetAuras:SetChecked(t.auras.enabled ~= false) end
        if controls.slTargetAuraScale then controls.slTargetAuraScale.SetValue(nil, t.auras.scale or 100) end
        if controls.slTargetAuraAlpha then controls.slTargetAuraAlpha.SetValue(nil, t.auras.alpha or 1.0) end
        if controls.slTargetAuraMax then controls.slTargetAuraMax.SetValue(nil, t.auras.maxShown or 32) end
        if controls.slTargetAuraPerRow then controls.slTargetAuraPerRow.SetValue(nil, t.auras.perRow or 16) end
        if controls.ddTargetAuraAlign then controls.ddTargetAuraAlign.SetValue(nil, t.auras.alignment or "Right") end
    end

    if t.debuffs then
        if controls.chkTargetDebuffs then controls.chkTargetDebuffs:SetChecked(t.debuffs.enabled ~= false) end
        if controls.slTargetDebuffScale then controls.slTargetDebuffScale.SetValue(nil, t.debuffs.scale or 100) end
        if controls.slTargetDebuffAlpha then controls.slTargetDebuffAlpha.SetValue(nil, t.debuffs.alpha or 1.0) end
        if controls.slTargetDebuffMax then controls.slTargetDebuffMax.SetValue(nil, t.debuffs.maxShown or 16) end
        if controls.slTargetDebuffPerRow then controls.slTargetDebuffPerRow.SetValue(nil, t.debuffs.perRow or 16) end
        if controls.ddTargetDebuffAlign then controls.ddTargetDebuffAlign.SetValue(nil, t.debuffs.alignment or "Right") end
    end

    local f = MidnightUISettings.FocusFrame
    if controls.chkFocus then controls.chkFocus:SetChecked(f.enabled) end
    if controls.slFScale then controls.slFScale.SetValue(nil, f.scale) end
    if controls.slFAlpha then controls.slFAlpha.SetValue(nil, f.alpha) end
    if controls.slFWidth then controls.slFWidth.SetValue(nil, f.width) end
    if controls.slFHeight then controls.slFHeight.SetValue(nil, f.height) end
    if controls.chkFocusTooltip then controls.chkFocusTooltip:SetChecked(f.customTooltip ~= false) end

    local c = MidnightUISettings.CastBars
    if c and c.player then
        if controls.chkCP then controls.chkCP:SetChecked(c.player.enabled ~= false) end
        if controls.chkCPMatch then controls.chkCPMatch:SetChecked(c.player.matchFrameWidth == true) end
        if controls.slCPScale then controls.slCPScale.SetValue(nil, c.player.scale or 100) end
        if controls.slCPWidth then controls.slCPWidth.SetValue(nil, c.player.width or 420) end
        if controls.slCPHeight then controls.slCPHeight.SetValue(nil, c.player.height or 22) end
        if controls.slCPYOffset then controls.slCPYOffset.SetValue(nil, c.player.attachYOffset or -6) end
    end
    if c and c.target then
        if controls.chkCT then controls.chkCT:SetChecked(c.target.enabled ~= false) end
        if controls.chkCTMatch then controls.chkCTMatch:SetChecked(c.target.matchFrameWidth == true) end
        if controls.slCTScale then controls.slCTScale.SetValue(nil, c.target.scale or 100) end
        if controls.slCTWidth then controls.slCTWidth.SetValue(nil, c.target.width or 420) end
        if controls.slCTHeight then controls.slCTHeight.SetValue(nil, c.target.height or 22) end
        if controls.slCTYOffset then controls.slCTYOffset.SetValue(nil, c.target.attachYOffset or -6) end
    end
    if c and c.focus then
        if controls.chkCF then controls.chkCF:SetChecked(c.focus.enabled ~= false) end
        if controls.chkCFMatch then controls.chkCFMatch:SetChecked(c.focus.matchFrameWidth == true) end
        if controls.slCFScale then controls.slCFScale.SetValue(nil, c.focus.scale or 100) end
        if controls.slCFWidth then controls.slCFWidth.SetValue(nil, c.focus.width or 320) end
        if controls.slCFHeight then controls.slCFHeight.SetValue(nil, c.focus.height or 20) end
        if controls.slCFYOffset then controls.slCFYOffset.SetValue(nil, c.focus.attachYOffset or -6) end
    end

    if M.ApplyNameplateUIValues then
        M.ApplyNameplateUIValues(MidnightUISettings.Nameplates, controls.targetNpControls)
    end

    local combatOverlaySettings = M.EnsureCombatDebuffOverlaySettings and M.EnsureCombatDebuffOverlaySettings() or MidnightUISettings.Combat
    if combatOverlaySettings then
        if controls.chkDebuffOverlayGlobal then
            controls.chkDebuffOverlayGlobal:SetChecked(combatOverlaySettings.debuffOverlayGlobalEnabled ~= false)
        end
        if controls.chkDebuffOverlayPlayer then
            controls.chkDebuffOverlayPlayer:SetChecked(combatOverlaySettings.debuffOverlayPlayerEnabled ~= false)
        end
        if controls.chkDebuffOverlayFocus then
            controls.chkDebuffOverlayFocus:SetChecked(combatOverlaySettings.debuffOverlayFocusEnabled ~= false)
        end
        if controls.chkDebuffOverlayParty then
            controls.chkDebuffOverlayParty:SetChecked(combatOverlaySettings.debuffOverlayPartyEnabled ~= false)
        end
        if controls.chkDebuffOverlayRaid then
            controls.chkDebuffOverlayRaid:SetChecked(combatOverlaySettings.debuffOverlayRaidEnabled ~= false)
        end
        if controls.chkDebuffOverlayTargetOfTarget then
            controls.chkDebuffOverlayTargetOfTarget:SetChecked(combatOverlaySettings.debuffOverlayTargetOfTargetEnabled ~= false)
        end

        -- Visual Alert
        if controls.chkDebuffBorder then
            controls.chkDebuffBorder:SetChecked(MidnightUISettings.Combat.debuffBorderEnabled ~= false)
        end

        -- Tracking Overlay
        if controls.chkDispelTracking then
            controls.chkDispelTracking:SetChecked(MidnightUISettings.Combat.dispelTrackingEnabled ~= false)
        end
        if controls.slDispelTrackingMax then
            controls.slDispelTrackingMax.SetValue(nil, MidnightUISettings.Combat.dispelTrackingMaxShown or 8)
        end
        if controls.slDispelTrackingIconSize then
            controls.slDispelTrackingIconSize.SetValue(nil, MidnightUISettings.Combat.dispelTrackingIconScale or 100)
        end
        if controls.ddDispelTrackingOrientation then
            local dispelOrientation = MidnightUISettings.Combat.dispelTrackingOrientation
            controls.ddDispelTrackingOrientation.SetValue(nil, (dispelOrientation == "VERTICAL") and "Vertical" or "Horizontal")
        end

        -- Party Icons
        if controls.chkPartyDispelTracking then
            controls.chkPartyDispelTracking:SetChecked(MidnightUISettings.Combat.partyDispelTrackingEnabled ~= false)
        end
        if controls.slPartyDispelTrackingIconSize then
            controls.slPartyDispelTrackingIconSize.SetValue(nil, MidnightUISettings.Combat.partyDispelTrackingIconScale or 100)
        end
    end

    -- NEW: PetFrame controls
    if MidnightUISettings.PetFrame then
        if controls.chkPetFrameEnabled then controls.chkPetFrameEnabled:SetChecked(MidnightUISettings.PetFrame.enabled ~= false) end
        if controls.slPetScale then controls.slPetScale.SetValue(nil, MidnightUISettings.PetFrame.scale or 100) end
        if controls.slPetWidth then controls.slPetWidth.SetValue(nil, MidnightUISettings.PetFrame.width or 240) end
        if controls.slPetHeight then controls.slPetHeight.SetValue(nil, MidnightUISettings.PetFrame.height or 48) end
        if controls.slPetAlpha then controls.slPetAlpha.SetValue(nil, MidnightUISettings.PetFrame.alpha or 0.95) end
    end

    -- NEW: Minimap Scale, XP/Rep bars
    if controls.slMinimapScale then controls.slMinimapScale.SetValue(nil, (MidnightUISettings.Minimap and MidnightUISettings.Minimap.scale) or 100) end
    if controls.chkXPBarEnabled then controls.chkXPBarEnabled:SetChecked(MidnightUISettings.XPBar and MidnightUISettings.XPBar.enabled ~= false) end
    if controls.chkRepBarEnabled then controls.chkRepBarEnabled:SetChecked(MidnightUISettings.RepBar and MidnightUISettings.RepBar.enabled ~= false) end

    -- NEW: Messenger Lock
    if controls.cbMessengerLock then controls.cbMessengerLock:SetChecked(m.locked ~= false) end

    if M.UpdActControls then M.UpdActControls() end
    if M.UpdMarket then M.UpdMarket() end
end

ConfigFrame:SetScript("OnShow", function()
    ApplySettingsOnShow(SettingsControls)
end)

-- Register with WoW's Settings panel (Dragonflight+) or legacy InterfaceOptions.
if Settings and Settings.RegisterCanvasLayoutCategory then
    local c, l = Settings.RegisterCanvasLayoutCategory(ConfigFrame, "Midnight UI")
    MidnightSettingsCategory = c
    M.SettingsCategory = c
    Settings.RegisterAddOnCategory(c)
else
    ConfigFrame.name = "Midnight UI"
    InterfaceOptions_AddCategory(ConfigFrame)
end
M.UpdMarket = UpdMarket
M.UpdActControls = UpdActControls
M.ApplyNameplateUIValues = ApplyNameplateUIValues
M.SelBar = SelBar

-- =========================================================================
