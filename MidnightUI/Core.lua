--------------------------------------------------------------------------------
-- Core.lua | MidnightUI
-- PURPOSE: Foundation module — initializes the global module table (M),
--          class colors, tooltip sigil styling, overlay positioning system,
--          overlay settings UI, debug/taint-trace infrastructure, module
--          registry, deferred-execution queue, and Blizzard popup clamping.
-- DEPENDS ON: Bootstrap.lua (for early debug queue stubs)
-- EXPORTS:
--   _G.MidnightUI_Core (table "M") — central module table
--   M.ClassColorsExact — RGB map for all 13 WoW classes
--   M.GetClassColor(unitOrClass) — returns r,g,b for a class token or unit
--   M.GetClassColorTable(unitOrClass) — returns {r,g,b} table
--   M.RegisterModule / M.InitModule / M.InitModules — module lifecycle
--   M.RunOrDefer / M.FlushDeferred — combat-safe deferred execution
--   M.SafeCall — pcall wrapper with debug logging
--   M.EnsureSettings — initializes MidnightUISettings subtables
--   M.Debug / M.SetDebug / M.FlushDebugQueue — debug logging system
--   M.TaintTrace / M.TaintTraceEnabled — taint diagnostic helpers
--   M.RegisterOverlaySettings / M.ShowOverlaySettings — overlay settings panel
--   M.ApplyTooltipAnchorSettings — re-anchors visible tooltips to cursor
--   M.StyleButton — applies MidnightUI dark button style
--   _G.MidnightUI_StyleButton, _G.MidnightUI_StyleOverlay,
--   _G.MidnightUI_SaveOverlayPosition, _G.MidnightUI_ApplyOverlayPosition,
--   _G.MidnightUI_SaveRelativeOverlayPosition,
--   _G.MidnightUI_ApplyRelativeOverlayPosition,
--   _G.MidnightUI_ScaleFromPercent,
--   _G.MidnightUI_RegisterOverlaySettings, _G.MidnightUI_ShowOverlaySettings,
--   _G.MidnightUI_AttachOverlaySettings, _G.MidnightUI_AttachOverlayTooltip,
--   _G.MidnightUI_CreateOverlayBuilder, _G.MidnightUI_GetOverlayHandle,
--   _G.MidnightUI_ApplyTooltipAnchorSettings,
--   _G.MidnightUI_Debug, _G.MidnightUI_LogDebug,
--   _G.MidnightUI_Settings.TaintTrace / .TaintTraceEnabled
-- ARCHITECTURE: Core.lua is the first "real" module after Bootstrap.lua.
--   All other MidnightUI modules depend on M for settings, class colors,
--   debug logging, module registration, and overlay infrastructure.
--   The file is structured in these sections:
--     1. Module table & class colors
--     2. Tooltip sigil system (accent colors, chrome, hooks)
--     3. Debug & taint-trace infrastructure
--     4. Settings initialization & module registry
--     5. Default module registrations
--     6. Overlay position/styling/settings system
--     7. Global exports
--     8. Event handler (ADDON_LOADED, PLAYER_LOGIN, etc.)
--     9. Blizzard popup clamp & HelpTip suppression
--------------------------------------------------------------------------------

-- ============================================================================
-- LOCAL UPVALUES
-- Cached references to frequently used globals for performance
-- ============================================================================
local _G = _G
local CreateFrame = CreateFrame
local InCombatLockdown = InCombatLockdown
local pcall = pcall
local tostring = tostring
local type = type
local wipe = wipe

-- ============================================================================
-- MODULE TABLE INITIALIZATION
-- M is the central table for all MidnightUI Core state and functions.
-- Persists across file reloads by reusing the existing _G.MidnightUI_Core.
-- ============================================================================
local M = _G.MidnightUI_Core or {}
_G.MidnightUI_Core = M

M.Version = "1.0"
M.Modules = M.Modules or {}            -- name → module definition table
M._deferQueue = M._deferQueue or {}    -- combat-deferred {label, fn} entries
M._moduleState = M._moduleState or {}  -- name → {inited=bool} tracking

-- ============================================================================
-- VALUE SAFETY HELPERS
-- Guards against Blizzard's "secret value" taint system where some values
-- returned by secure APIs cannot be read by addon code.
-- ============================================================================

--- IsSecretValue: Checks if a value is a Blizzard tainted/secret value
-- @param value (any) - Value to test
-- @return (boolean) - true if the value is a secret/restricted value
local function IsSecretValue(value)
    if type(issecretvalue) ~= "function" then return false end
    local ok, result = pcall(issecretvalue, value)
    return ok and result == true
end

--- CanUseUnitToken: Validates that a value is a usable unit token string
-- Rejects secret values and non-string types to prevent taint propagation.
-- @param unit (any) - Candidate unit token
-- @return (boolean) - true if safe to pass to UnitExists, UnitClass, etc.
local function CanUseUnitToken(unit)
    if IsSecretValue(unit) then
        return false
    end
    return type(unit) == "string"
end

-- ============================================================================
-- CLASS COLORS
-- Exact RGB values for all 13 WoW classes, matching official class colors.
-- Used by: M.GetClassColor(), M.GetClassColorTable(), tooltip sigil accents,
-- unit frame coloring across PlayerFrame.lua, TargetFrame.lua, Nameplates.lua, etc.
-- ============================================================================

-- ClassColorsExact: Map of CLASS_TOKEN → {r, g, b} for all 13 WoW classes
M.ClassColorsExact = {
    DEATHKNIGHT = { r = 0.77, g = 0.12, b = 0.23 }, -- #C41E3A
    DEMONHUNTER = { r = 0.64, g = 0.19, b = 0.79 }, -- #A330C9
    DRUID = { r = 1.00, g = 0.49, b = 0.04 },       -- #FF7C0A
    EVOKER = { r = 0.20, g = 0.58, b = 0.50 },      -- #33937F
    HUNTER = { r = 0.67, g = 0.83, b = 0.45 },      -- #AAD372
    MAGE = { r = 0.25, g = 0.78, b = 0.92 },        -- #3FC7EB
    MONK = { r = 0.00, g = 1.00, b = 0.60 },        -- #00FF98
    PALADIN = { r = 0.96, g = 0.55, b = 0.73 },     -- #F48CBA
    PRIEST = { r = 1.00, g = 1.00, b = 1.00 },      -- #FFFFFF
    ROGUE = { r = 1.00, g = 0.96, b = 0.41 },       -- #FFF468
    SHAMAN = { r = 0.00, g = 0.44, b = 0.87 },      -- #0070DD
    WARLOCK = { r = 0.53, g = 0.53, b = 0.93 },     -- #8788EE
    WARRIOR = { r = 0.78, g = 0.61, b = 0.43 },     -- #C69B6D
}

--- M.GetClassColor: Returns r,g,b for a class token or unit ID
-- Resolution order: M.ClassColorsExact → RAID_CLASS_COLORS → C_ClassColor API
-- @param unitOrClass (string|nil) - A CLASS_TOKEN (e.g. "WARRIOR") or unit ID (e.g. "player", "target")
-- @return (number, number, number) - r, g, b values (0-1); falls back to white (1,1,1)
-- @calls UnitClass, UnitExists, C_ClassColor.GetClassColor
-- @calledby GetAccentColour(), tooltip sigil system, unit frame modules
function M.GetClassColor(unitOrClass)
    if not unitOrClass then return 1, 1, 1 end
    local class = unitOrClass
    -- If unitOrClass is a valid unit token (e.g. "player"), resolve it to a CLASS_TOKEN
    if UnitExists and CanUseUnitToken(unitOrClass) and UnitExists(unitOrClass) then
        local _, c = UnitClass(unitOrClass)
        class = c
    end
    -- Try MidnightUI's exact color table first
    if class and M.ClassColorsExact[class] then
        local c = M.ClassColorsExact[class]
        return c.r, c.g, c.b
    end
    -- Fallback to Blizzard's RAID_CLASS_COLORS global
    if class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class] then
        local c = RAID_CLASS_COLORS[class]
        return c.r or c[1], c.g or c[2], c.b or c[3]
    end
    -- Fallback to Blizzard's C_ClassColor API (added in newer expansions)
    if class and C_ClassColor and C_ClassColor.GetClassColor then
        local c = C_ClassColor.GetClassColor(class)
        if c then return c.r, c.g, c.b end
    end
    return 1, 1, 1
end

--- M.GetClassColorTable: Returns class color as a table {r, g, b}
-- @param unitOrClass (string|nil) - A CLASS_TOKEN or unit ID
-- @return (table) - {r=number, g=number, b=number}
-- @calls M.GetClassColor
function M.GetClassColorTable(unitOrClass)
    local r, g, b = M.GetClassColor(unitOrClass)
    return { r = r, g = g, b = b }
end


-- ============================================================================
-- TOOLTIP SIGIL SYSTEM
-- Custom tooltip chrome that replaces Blizzard's default NineSlice borders
-- with a dark background, colored accent stripe, and corner brackets.
--
-- Accent color reflects the TARGET's identity:
--   Player unit   → their class color (from M.GetClassColor)
--   Friendly NPC  → green  (0.10, 0.85, 0.10)
--   Neutral  NPC  → amber  (0.95, 0.75, 0.10)
--   Hostile  unit → red    (0.85, 0.10, 0.10)
--   Item/spell    → silver (0.70, 0.70, 0.82)
--   Action button → player's own class color
--   Fallback      → warm off-white (0.72, 0.70, 0.66)
--
-- Visual structure:
--   - Outer shadow frame (soft dark rectangle behind everything)
--   - Chrome container frame (dark background with thin accent border)
--   - Top accent stripe with center-brightened gradient
--   - Glow and shadow textures beneath the accent stripe
--   - 1px border with corner dot accents
-- ============================================================================

-- Shared flat white texture used for all solid-color tooltip elements
local W8 = "Interface\\Buttons\\WHITE8x8"

-- ============================================================================
-- TOOLTIP SETTING GUARDS
-- ============================================================================

--- MUI_TooltipEnabled: Returns whether custom tooltip styling is enabled
-- @return (boolean) - false only if MidnightUISettings.General.customTooltips is explicitly false
local function MUI_TooltipEnabled()
    return not (MidnightUISettings
        and MidnightUISettings.General
        and MidnightUISettings.General.customTooltips == false)
end

--- MUI_ForceCursorTooltips: Returns whether tooltips should follow the cursor
-- @return (boolean) - true if MidnightUISettings.General.forceCursorTooltips is true
local function MUI_ForceCursorTooltips()
    return (MidnightUISettings
        and MidnightUISettings.General
        and MidnightUISettings.General.forceCursorTooltips == true) and true or false
end

--- AnchorTooltipToCursor: Repositions a tooltip frame to follow the mouse cursor
-- Places the tooltip's BOTTOMLEFT at cursor position + 18px offset in both axes.
-- @param tooltip (Frame) - The tooltip frame to reposition
local function AnchorTooltipToCursor(tooltip)
    if not tooltip or not tooltip.ClearAllPoints or not tooltip.SetPoint then return end
    if not _G.GetCursorPosition or not _G.UIParent then return end

    local scale = (_G.UIParent.GetEffectiveScale and _G.UIParent:GetEffectiveScale()) or 1
    if not scale or scale == 0 then scale = 1 end

    local x, y = _G.GetCursorPosition()
    if not x or not y then return end
    -- Convert from screen pixels to UIParent-scaled coordinates
    x, y = x / scale, y / scale

    tooltip:ClearAllPoints()
    tooltip:SetPoint("BOTTOMLEFT", _G.UIParent, "BOTTOMLEFT", x + 18, y + 18)
end

-- ============================================================================
-- ACCENT COLOR MATH HELPERS
-- ============================================================================

--- Mix: Linear interpolation between two values
-- @param a (number) - Start value
-- @param b (number) - End value
-- @param t (number|nil) - Interpolation factor 0-1 (default 0)
-- @return (number) - Interpolated result
local function Mix(a, b, t)
    return a + (b - a) * (t or 0)
end

--- MixRGB: Linear interpolation on three color channels simultaneously
-- @param r,g,b (number) - Source color
-- @param tr,tg,tb (number) - Target color
-- @param t (number) - Interpolation factor 0-1
-- @return (number, number, number) - Interpolated r, g, b
local function MixRGB(r, g, b, tr, tg, tb, t)
    return Mix(r, tr, t), Mix(g, tg, t), Mix(b, tb, t)
end

--- Clamp01: Clamps a number to the 0-1 range
-- @param v (number) - Value to clamp
-- @return (number) - Clamped value
local function Clamp01(v)
    if v < 0 then return 0 end
    if v > 1 then return 1 end
    return v
end

-- ============================================================================
-- ACCENT COLOR RESOLUTION
-- Determines the accent color for a tooltip based on what it's displaying.
-- ============================================================================

--- GetAccentColour: Determines the accent color for a tooltip's sigil chrome
-- Tries multiple strategies to identify what the tooltip is showing, then picks
-- an appropriate accent color. Resolution order:
--   1. tooltip:GetTooltipData().unitToken
--   2. tooltip:GetUnit() (returns name, unitToken)
--   3. "mouseover" fallback for GameTooltip
--   4. tooltip._mui_unit (set by custom tooltip builders)
--   5. Owner's action button → player class color
--   6. tooltip:GetItem() → silver for items
--   7. Warm off-white fallback
-- @param tooltip (Frame) - The tooltip frame to inspect
-- @return (number, number, number) - Accent r, g, b
-- @calls M.GetClassColor, UnitIsPlayer, UnitReaction, UnitClass
local function GetAccentColour(tooltip)
    local unit
    local owner = (tooltip and tooltip.GetOwner and tooltip:GetOwner()) or nil

    -- Strategy 1: GetTooltipData API (modern WoW tooltip data system)
    if not unit and tooltip and tooltip.GetTooltipData then
        local ok, data = pcall(tooltip.GetTooltipData, tooltip)
        if ok and data and CanUseUnitToken(data.unitToken) and UnitExists and UnitExists(data.unitToken) then
            unit = data.unitToken
        end
    end

    -- Strategy 2: GetUnit API (returns name, unitToken — not just unitToken)
    if not unit and tooltip and tooltip.GetUnit then
        local ok, _, unitToken = pcall(tooltip.GetUnit, tooltip)
        if ok and CanUseUnitToken(unitToken) and UnitExists and UnitExists(unitToken) then
            unit = unitToken
        end
    end

    -- Strategy 3: World mouseover fallback when Blizzard's unit token is unavailable
    if not unit and tooltip == _G.GameTooltip and UnitExists and UnitExists("mouseover") then
        unit = "mouseover"
    end

    -- Strategy 4: Custom tooltip builders can set tooltip._mui_unit directly
    if not unit and tooltip and CanUseUnitToken(tooltip._mui_unit) and UnitExists and UnitExists(tooltip._mui_unit) then
        unit = tooltip._mui_unit
    end

    -- If we resolved a unit, determine color by player class or NPC reaction
    if CanUseUnitToken(unit) and UnitExists and UnitExists(unit) then
        if UnitIsPlayer and UnitIsPlayer(unit) then
            local _, classToken = UnitClass(unit)
            if classToken then
                local r, g, b = M.GetClassColor(classToken)
                return r, g, b
            end
        end

        -- NPC reaction coloring: friendly (green) vs neutral/hostile (amber)
        if UnitReaction then
            local reaction = UnitReaction(unit, "player")
            if reaction then
                if reaction >= 5 then
                    return 0.10, 0.80, 0.20  -- Friendly NPC: green
                else
                    return 0.95, 0.78, 0.12  -- Neutral/hostile NPC: amber
                end
            end
        end
    end

    -- Action-button tooltips: use the player's own class color
    if not unit and owner then
        local action
        if type(owner.action) == "number" then
            action = owner.action
        elseif owner.GetAttribute then
            local okAction, attrAction = pcall(owner.GetAttribute, owner, "action")
            if okAction and type(attrAction) == "number" then
                action = attrAction
            end
        end
        if action and action > 0 and HasAction and HasAction(action) then
            local r, g, b = M.GetClassColor("player")
            return r, g, b
        end
    end

    -- Item/spell tooltips: silver accent
    if tooltip and tooltip.GetItem then
        local ok, _, link = pcall(tooltip.GetItem, tooltip)
        if ok and link then
            return 0.70, 0.70, 0.82
        end
    end

    -- Default fallback: warm off-white
    return 0.72, 0.70, 0.66
end

-- ============================================================================
-- BLIZZARD CHROME SUPPRESSION
-- Hides Blizzard's default NineSlice tooltip borders and status bar so the
-- custom sigil chrome can take their place.
-- ============================================================================

--- HideNineSlice: Fully hides a NineSlice frame and all its child regions
-- @param ns (Frame|nil) - The NineSlice frame to hide
local function HideNineSlice(ns)
    if not ns then return end
    if ns.SetAlpha then ns:SetAlpha(0) end
    if ns.Hide then ns:Hide() end
    for _, region in ipairs({ ns:GetRegions() }) do
        if region.SetAlpha then region:SetAlpha(0) end
        if region.Hide then region:Hide() end
    end
end

--- NukeBlizzardChrome: Suppresses all default Blizzard tooltip visuals
-- Hides NineSlice borders, replaces backdrop with dark solid fill, and hides
-- the tooltip status bar. NineSlice is re-suppressed on every call because
-- Blizzard's TargetPlayerTooltips and tooltip data handlers call Show() on the
-- NineSlice AFTER our OnShow hook runs, overriding a one-time Hide().
-- @param tooltip (Frame) - The tooltip frame to strip
-- @note Installs OnShow hooks on NineSlice and status bar (once per tooltip)
--       to ensure they stay hidden even when Blizzard re-shows them.
local function NukeBlizzardChrome(tooltip)
    if tooltip.NineSlice then
        local ns = tooltip.NineSlice
        -- Install OnShow hook only once, but always re-hide immediately
        if not tooltip._mui_nineslice_hooked then
            tooltip._mui_nineslice_hooked = true
            if ns.HookScript then
                -- C_Timer.After(0) defers the hide to after Blizzard's own
                -- post-show logic runs, so our hide always wins the race
                pcall(ns.HookScript, ns, "OnShow", function(self)
                    HideNineSlice(self)
                    if C_Timer and C_Timer.After then
                        C_Timer.After(0, function()
                            if self and self.IsShown and self:IsShown() then
                                HideNineSlice(self)
                            end
                        end)
                    end
                end)
                -- Also hook each individual NineSlice region texture
                for _, region in ipairs({ ns:GetRegions() }) do
                    if region.HookScript then
                        pcall(region.HookScript, region, "OnShow", function(self)
                            self:SetAlpha(0)
                            if self.Hide then self:Hide() end
                        end)
                    end
                end
            end
        end
        -- Always suppress right now, every call
        HideNineSlice(ns)
    end
    -- Replace backdrop with dark solid fill
    if tooltip.SetBackdrop then
        pcall(tooltip.SetBackdrop, tooltip, {
            bgFile = W8,
            insets = { left=0, right=0, top=0, bottom=0 },
        })
        pcall(tooltip.SetBackdropColor, tooltip, 0.04, 0.03, 0.03, 0.97)
    end
    -- Hide the health/power status bar shown on unit tooltips
    if tooltip.GetName then
        local bar = _G[(tooltip:GetName() or "") .. "StatusBar"]
        if bar then
            if not bar._mui_bar_hooked then
                bar._mui_bar_hooked = true
                if bar.HookScript then
                    pcall(bar.HookScript, bar, "OnShow", function(self) self:Hide() end)
                end
            end
            bar:Hide()
        end
    end
end

-- ============================================================================
-- CHROME CONSTRUCTION
-- Builds the visual chrome overlay for a tooltip: shadow, background,
-- inlay, border, accent stripe, gradient shine, and glow textures.
-- ============================================================================

-- Chrome geometry constants (pixels)
local CHROME_PAD_X     = 3   -- Horizontal padding around tooltip content
local CHROME_PAD_TOP   = 6   -- Top padding above tooltip content
local CHROME_PAD_BOTTOM = 2  -- Bottom padding below tooltip content
local BORDER_SIZE      = 1   -- 1px border thickness
local TOP_ACCENT_H     = 3   -- Height of the colored accent stripe
local TOP_ACCENT_INSET = 4   -- Horizontal inset of accent stripe from chrome edges
local CONTENT_PAD_X    = 6   -- Internal text padding horizontal
local CONTENT_PAD_Y    = 4   -- Internal text padding vertical

--- ApplyTooltipPadding: Sets internal content padding on a tooltip
-- @param tooltip (Frame) - Tooltip to pad
local function ApplyTooltipPadding(tooltip)
    if not tooltip or not tooltip.SetPadding then return end
    pcall(tooltip.SetPadding, tooltip, CONTENT_PAD_X, CONTENT_PAD_Y)
end

--- BuildChrome: Creates all visual chrome elements for a tooltip
-- Constructs shadow, chrome container, background fill, inlay, 4-edge border
-- with corner dots, accent stripe with center-brightened gradient overlays,
-- a shadow below the stripe, and a soft additive glow.
-- Skips rebuild if chrome already exists with valid (non-zero) geometry.
-- Clears all stale _mui_* references before rebuilding.
-- @param tooltip (Frame) - The tooltip to build chrome for
-- @note Does NOT call Recolour — caller must do that after BuildChrome.
-- @note At hook-install time, tooltip may have zero geometry; OnShow fires
--       with real dimensions, which triggers a proper build.
local function BuildChrome(tooltip)
    -- Skip if chrome exists, is valid, AND has non-zero size.
    -- Zero-size chrome means it was built while tooltip had no geometry (e.g. at login).
    if tooltip._mui_chrome and tooltip._mui_chrome:GetParent() then
        local cw, ch = tooltip._mui_chrome:GetSize()
        if cw > 0 and ch > 0 then
            return
        end
    end
    -- Clear stale state before rebuilding
    if tooltip._mui_chrome then tooltip._mui_chrome:Hide() end
    if tooltip._mui_shadow then tooltip._mui_shadow:Hide() end
    tooltip._mui_chrome  = nil
    tooltip._mui_shadow  = nil
    tooltip._mui_bg      = nil
    tooltip._mui_inlay   = nil
    tooltip._mui_stripe  = nil
    tooltip._mui_topGlow = nil
    tooltip._mui_border  = nil
    tooltip._mui_arms    = nil

    local strata = tooltip:GetFrameStrata()
    local level  = tooltip:GetFrameLevel()

    -- Outer shadow: dark rectangle behind the chrome, 8px larger on all sides
    local shadow = CreateFrame("Frame", nil, UIParent)
    shadow:SetFrameStrata(strata)
    shadow:SetFrameLevel(math.max(1, level - 2))
    shadow:SetPoint("TOPLEFT",     tooltip, "TOPLEFT",     -(CHROME_PAD_X + 8),  (CHROME_PAD_TOP + 8))
    shadow:SetPoint("BOTTOMRIGHT", tooltip, "BOTTOMRIGHT",  (CHROME_PAD_X + 8), -(CHROME_PAD_BOTTOM + 8))
    local shadowTex = shadow:CreateTexture(nil, "BACKGROUND", nil, 0)
    shadowTex:SetTexture(W8)
    shadowTex:SetAllPoints(shadow)
    shadowTex:SetVertexColor(0, 0, 0, 0.62)
    tooltip._mui_shadow = shadow

    -- Chrome container: the main frame that holds all visual elements
    local chrome = CreateFrame("Frame", nil, UIParent)
    chrome:SetFrameStrata(strata)
    chrome:SetFrameLevel(math.max(1, level - 1))
    chrome:SetPoint("TOPLEFT",     tooltip, "TOPLEFT",     -CHROME_PAD_X,  CHROME_PAD_TOP)
    chrome:SetPoint("BOTTOMRIGHT", tooltip, "BOTTOMRIGHT",  CHROME_PAD_X, -CHROME_PAD_BOTTOM)
    tooltip._mui_chrome = chrome

    -- Background fill: near-black with 96% opacity
    local bg = chrome:CreateTexture(nil, "BACKGROUND", nil, 0)
    bg:SetTexture(W8)
    bg:SetAllPoints(chrome)
    bg:SetVertexColor(0.034, 0.030, 0.028, 0.96)
    tooltip._mui_bg = bg

    -- Inlay: subtle lighter fill inset by BORDER_SIZE to avoid a completely flat look
    local inlay = chrome:CreateTexture(nil, "BACKGROUND", nil, 1)
    inlay:SetTexture(W8)
    inlay:SetPoint("TOPLEFT", chrome, "TOPLEFT", BORDER_SIZE, -BORDER_SIZE)
    inlay:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", -BORDER_SIZE, BORDER_SIZE)
    inlay:SetVertexColor(0.09, 0.085, 0.08, 0.20)
    tooltip._mui_inlay = inlay

    -- 1px border on all four edges, plus 1x1 corner accent dots
    local border = {}

    border.top = chrome:CreateTexture(nil, "ARTWORK", nil, 0)
    border.top:SetTexture(W8)
    border.top:SetPoint("TOPLEFT", chrome, "TOPLEFT", 0, 0)
    border.top:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", 0, 0)
    border.top:SetHeight(BORDER_SIZE)

    border.bottom = chrome:CreateTexture(nil, "ARTWORK", nil, 0)
    border.bottom:SetTexture(W8)
    border.bottom:SetPoint("BOTTOMLEFT", chrome, "BOTTOMLEFT", 0, 0)
    border.bottom:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", 0, 0)
    border.bottom:SetHeight(BORDER_SIZE)

    border.left = chrome:CreateTexture(nil, "ARTWORK", nil, 0)
    border.left:SetTexture(W8)
    border.left:SetPoint("TOPLEFT", chrome, "TOPLEFT", 0, 0)
    border.left:SetPoint("BOTTOMLEFT", chrome, "BOTTOMLEFT", 0, 0)
    border.left:SetWidth(BORDER_SIZE)

    border.right = chrome:CreateTexture(nil, "ARTWORK", nil, 0)
    border.right:SetTexture(W8)
    border.right:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", 0, 0)
    border.right:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", 0, 0)
    border.right:SetWidth(BORDER_SIZE)

    -- Corner accent dots (1x1 pixels at each corner, colored separately from edges)
    border.cornerTL = chrome:CreateTexture(nil, "ARTWORK", nil, 1)
    border.cornerTL:SetTexture(W8)
    border.cornerTL:SetPoint("TOPLEFT", chrome, "TOPLEFT", 0, 0)
    border.cornerTL:SetSize(1, 1)

    border.cornerTR = chrome:CreateTexture(nil, "ARTWORK", nil, 1)
    border.cornerTR:SetTexture(W8)
    border.cornerTR:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", 0, 0)
    border.cornerTR:SetSize(1, 1)

    border.cornerBL = chrome:CreateTexture(nil, "ARTWORK", nil, 1)
    border.cornerBL:SetTexture(W8)
    border.cornerBL:SetPoint("BOTTOMLEFT", chrome, "BOTTOMLEFT", 0, 0)
    border.cornerBL:SetSize(1, 1)

    border.cornerBR = chrome:CreateTexture(nil, "ARTWORK", nil, 1)
    border.cornerBR:SetTexture(W8)
    border.cornerBR:SetPoint("BOTTOMRIGHT", chrome, "BOTTOMRIGHT", 0, 0)
    border.cornerBR:SetSize(1, 1)

    tooltip._mui_border = border

    -- Top accent stripe: colored bar just below the top border
    local stripe = chrome:CreateTexture(nil, "OVERLAY", nil, 0)
    stripe:SetTexture(W8)
    stripe:SetPoint("TOPLEFT",  chrome, "TOPLEFT",  TOP_ACCENT_INSET, -BORDER_SIZE)
    stripe:SetPoint("TOPRIGHT", chrome, "TOPRIGHT", -TOP_ACCENT_INSET, -BORDER_SIZE)
    stripe:SetHeight(TOP_ACCENT_H)
    tooltip._mui_stripe = stripe

    -- Stripe shine: two half-width gradient overlays that brighten toward the center
    -- while keeping the same accent color at both edges (left fades L→center, right fades center→R)
    local stripeShineLeft = chrome:CreateTexture(nil, "OVERLAY", nil, 1)
    stripeShineLeft:SetTexture(W8)
    stripeShineLeft:SetBlendMode("DISABLE")
    stripeShineLeft:SetPoint("TOPLEFT", stripe, "TOPLEFT", 0, 0)
    stripeShineLeft:SetPoint("BOTTOMRIGHT", stripe, "BOTTOM", 0, 0)
    tooltip._mui_stripeShineLeft = stripeShineLeft

    local stripeShineRight = chrome:CreateTexture(nil, "OVERLAY", nil, 1)
    stripeShineRight:SetTexture(W8)
    stripeShineRight:SetBlendMode("DISABLE")
    stripeShineRight:SetPoint("TOPLEFT", stripe, "TOP", 0, 0)
    stripeShineRight:SetPoint("BOTTOMRIGHT", stripe, "BOTTOMRIGHT", 0, 0)
    tooltip._mui_stripeShineRight = stripeShineRight

    -- Controlled penumbra shadow directly under the accent stripe for visual separation
    local shadow = chrome:CreateTexture(nil, "ARTWORK", nil, 0)
    shadow:SetTexture(W8)
    shadow:SetBlendMode("BLEND")
    shadow:SetPoint("TOPLEFT",  stripe, "BOTTOMLEFT", 0, -1)
    shadow:SetPoint("TOPRIGHT", stripe, "BOTTOMRIGHT", 0, -1)
    shadow:SetHeight(4)
    tooltip._mui_topShadow = shadow

    -- Soft additive glow under the accent stripe
    local glow = chrome:CreateTexture(nil, "ARTWORK", nil, 1)
    glow:SetTexture(W8)
    glow:SetBlendMode("ADD")
    glow:SetPoint("TOPLEFT",  stripe, "BOTTOMLEFT",  -1, -1)
    glow:SetPoint("TOPRIGHT", stripe, "BOTTOMRIGHT",  1, -1)
    glow:SetHeight(3)
    tooltip._mui_topGlow = glow

end

-- ============================================================================
-- RECOLOUR
-- Applies the resolved accent color to all chrome elements. Adapts brightness
-- and contrast based on luminance so bright class colors (e.g. Priest white)
-- don't blow out the UI.
-- ============================================================================

--- Recolour: Applies accent color to all chrome elements of a tooltip
-- Computes luminance-adaptive brightness parameters so that bright accent
-- colors (e.g. Priest white) are subdued while dark colors remain vivid.
-- @param tooltip (Frame) - Tooltip whose _mui_* chrome elements to recolor
-- @calls GetAccentColour, MixRGB, Clamp01
local function Recolour(tooltip)
    local r, g, b = GetAccentColour(tooltip)
    local name = (tooltip.GetName and tooltip:GetName()) or "?"

    -- Compute perceptual luminance (ITU-R BT.709 weights)
    local luminance = Clamp01((r * 0.2126) + (g * 0.7152) + (b * 0.0722))
    -- brightBias ramps from 0 to 1 as luminance goes from 0.68 to 1.0
    local brightBias = Clamp01((luminance - 0.68) / 0.32)
    -- Reduce intensity for bright colors to avoid visual blow-out
    local edgeDarken = math.max(0.04, 0.14 - (0.08 * brightBias))
    local centerLift = math.max(0.08, 0.24 - (0.16 * brightBias))
    local glowAlpha = math.max(0.08, 0.16 - (0.07 * brightBias))
    -- Edge color: accent darkened toward black
    local edgeR, edgeG, edgeB = MixRGB(r, g, b, 0, 0, 0, edgeDarken)
    -- Center color: accent lifted toward white
    local midR, midG, midB = MixRGB(r, g, b, 1, 1, 1, centerLift)

    -- Accent stripe base color
    if tooltip._mui_stripe then
        tooltip._mui_stripe:SetVertexColor(edgeR, edgeG, edgeB, 0.90)
    end

    -- Stripe shine gradients: edges use darkened accent, center uses lifted accent
    if tooltip._mui_stripeShineLeft then
        tooltip._mui_stripeShineLeft:SetGradient("HORIZONTAL",
            CreateColor(edgeR, edgeG, edgeB, 0.86),
            CreateColor(midR, midG, midB, 0.98))
    end
    if tooltip._mui_stripeShineRight then
        tooltip._mui_stripeShineRight:SetGradient("HORIZONTAL",
            CreateColor(midR, midG, midB, 0.98),
            CreateColor(edgeR, edgeG, edgeB, 0.86))
    end

    -- Additive glow beneath the stripe
    if tooltip._mui_topGlow then
        tooltip._mui_topGlow:SetGradient("VERTICAL",
            CreateColor(midR, midG, midB, glowAlpha),
            CreateColor(midR, midG, midB, 0))
    end
    -- Shadow beneath the stripe (darkens with luminance)
    if tooltip._mui_topShadow then
        local shadowA = math.max(0.05, 0.11 - (0.04 * brightBias))
        tooltip._mui_topShadow:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, shadowA),
            CreateColor(0, 0, 0, 0))
    end

    -- Border edges and corner dots: tinted toward accent color
    if tooltip._mui_border then
        -- Edge color: 58% darkened accent
        local er, eg, eb = MixRGB(r, g, b, 0, 0, 0, 0.58)
        -- Darker edges for bottom/sides: 70% darkened
        local dr, dg, db = MixRGB(r, g, b, 0, 0, 0, 0.70)
        tooltip._mui_border.top:SetVertexColor(er, eg, eb, 0.90)
        tooltip._mui_border.bottom:SetVertexColor(dr, dg, db, 0.76)
        tooltip._mui_border.left:SetVertexColor(dr, dg, db, 0.80)
        tooltip._mui_border.right:SetVertexColor(dr, dg, db, 0.80)

        -- Corner dots: 40% darkened accent, lower alpha
        local cr, cg, cb = MixRGB(r, g, b, 0, 0, 0, 0.40)
        tooltip._mui_border.cornerTL:SetVertexColor(cr, cg, cb, 0.56)
        tooltip._mui_border.cornerTR:SetVertexColor(cr, cg, cb, 0.56)
        tooltip._mui_border.cornerBL:SetVertexColor(cr, cg, cb, 0.46)
        tooltip._mui_border.cornerBR:SetVertexColor(cr, cg, cb, 0.46)
    end

    -- Inlay: very subtle accent-tinted fill inside the border
    if tooltip._mui_inlay then
        local ir, ig, ib = MixRGB(r, g, b, 0.20, 0.18, 0.16, 0.85)
        tooltip._mui_inlay:SetVertexColor(ir, ig, ib, 0.20)
    end
end

-- ============================================================================
-- TEXT SHARPENING
-- Adds crisp drop shadows to all tooltip text lines for readability.
-- ============================================================================

--- SharpText: Adds 1px black drop shadows to all text lines in a tooltip
-- Only processes each FontString once (flags with _mui_sharp).
-- @param tooltip (Frame) - The tooltip whose text lines to sharpen
local function SharpText(tooltip)
    if not tooltip.GetName then return end
    local name = tooltip:GetName()
    if not name then return end
    for i = 1, tooltip:NumLines() do
        for _, side in ipairs({ "TextLeft", "TextRight" }) do
            local fs = _G[name .. side .. i]
            if fs and not fs._mui_sharp then
                fs:SetShadowOffset(1, -1)
                fs:SetShadowColor(0, 0, 0, 1)
                fs._mui_sharp = true
            end
        end
    end
end

-- ============================================================================
-- MAIN SIGIL APPLICATION
-- Orchestrates the full tooltip styling pass: chrome, color, text.
-- ============================================================================

--- ApplySigil: Main entry point for applying MidnightUI tooltip styling
-- Called on tooltip OnShow, OnSizeChanged, OnTooltipSetUnit, OnTooltipSetItem.
-- Handles cursor anchoring, settings toggle, chrome build, recolor, and text sharpen.
-- @param tooltip (Frame) - The tooltip to style
-- @calls NukeBlizzardChrome, ApplyTooltipPadding, BuildChrome, Recolour, SharpText
local function ApplySigil(tooltip)
    if not tooltip then return end
    -- Re-entrancy guard: ReplaceMouseoverContent below calls Show() which can
    -- re-fire OnShow → ApplySigil.  Block the nested call so we only run once.
    if tooltip._mui_in_apply_sigil then return end
    tooltip._mui_in_apply_sigil = true

    -- For player-unit mouseover tooltips, replace content BEFORE building
    -- chrome so that padding and chrome dimensions are based on the final
    -- (narrower) custom content, not Blizzard's wider default layout.
    if tooltip == _G.GameTooltip and MUI_TooltipEnabled() then
        local PT = _G.MidnightUI_PlayerTooltips
        if PT and PT.ReplaceMouseoverContent then
            local ok1, exists  = pcall(UnitExists, "mouseover")
            local ok2, isPlayer = pcall(UnitIsPlayer, "mouseover")
            if ok1 and exists and ok2 and isPlayer then
                PT:ReplaceMouseoverContent("mouseover")
            end
        end
    end

    -- Optionally anchor tooltip to cursor position (skip shopping tooltips —
    -- they are positioned relative to the main tooltip by DoRepositionShopping)
    if MUI_ForceCursorTooltips() and not tooltip._mui_is_shopping then
        AnchorTooltipToCursor(tooltip)
    end

    -- If custom tooltips are disabled, restore Blizzard chrome and bail out
    if not MUI_TooltipEnabled() then
        if tooltip.NineSlice then tooltip.NineSlice:SetAlpha(1) end
        if tooltip._mui_chrome then tooltip._mui_chrome:Hide() end
        if tooltip._mui_shadow then tooltip._mui_shadow:Hide() end
        tooltip._mui_in_apply_sigil = nil
        return
    end

    NukeBlizzardChrome(tooltip)
    ApplyTooltipPadding(tooltip)

    BuildChrome(tooltip)

    -- Sync chrome and shadow strata/level with the tooltip itself
    local strata = tooltip:GetFrameStrata()
    local level  = tooltip:GetFrameLevel()

    if tooltip._mui_chrome then
        tooltip._mui_chrome:SetFrameStrata(strata)
        tooltip._mui_chrome:SetFrameLevel(math.max(1, level - 1))
        tooltip._mui_chrome:SetAlpha(tooltip:GetAlpha() or 1)
        tooltip._mui_chrome:Show()
    end
    if tooltip._mui_shadow then
        tooltip._mui_shadow:SetFrameStrata(strata)
        tooltip._mui_shadow:SetFrameLevel(math.max(1, level - 2))
        tooltip._mui_shadow:SetAlpha(tooltip:GetAlpha() or 1)
        tooltip._mui_shadow:Show()
    end

    Recolour(tooltip)
    SharpText(tooltip)
    tooltip._mui_in_apply_sigil = nil
end

--- RefreshSigilChrome: Lightweight chrome refresh for OnSizeChanged events.
-- Rebuilds chrome geometry, recolors, and sharpens text WITHOUT re-applying
-- padding.  This prevents the flicker loop where Blizzard strips padding,
-- OnSizeChanged fires, ApplySigil re-adds padding, Blizzard strips it again.
local function RefreshSigilChrome(tooltip)
    if not tooltip then return end
    if not MUI_TooltipEnabled() then return end

    NukeBlizzardChrome(tooltip)
    BuildChrome(tooltip)

    local strata = tooltip:GetFrameStrata()
    local level  = tooltip:GetFrameLevel()

    if tooltip._mui_chrome then
        tooltip._mui_chrome:SetFrameStrata(strata)
        tooltip._mui_chrome:SetFrameLevel(math.max(1, level - 1))
        tooltip._mui_chrome:SetAlpha(tooltip:GetAlpha() or 1)
        tooltip._mui_chrome:Show()
    end
    if tooltip._mui_shadow then
        tooltip._mui_shadow:SetFrameStrata(strata)
        tooltip._mui_shadow:SetFrameLevel(math.max(1, level - 2))
        tooltip._mui_shadow:SetAlpha(tooltip:GetAlpha() or 1)
        tooltip._mui_shadow:Show()
    end

    Recolour(tooltip)
    SharpText(tooltip)
end

-- Forward declaration: shopping tooltip repositioner (defined in the shopping
-- section below) so HookTooltip's OnUpdate can call it for comparison tooltips.
local DoRepositionShopping

-- ============================================================================
-- TOOLTIP HOOK INSTALLATION
-- Installs OnShow/OnHide/OnUpdate/OnSizeChanged/OnTooltipSet* hooks on each
-- tooltip frame to trigger sigil application and alpha synchronization.
-- ============================================================================

--- HookTooltip: Installs all MidnightUI event hooks on a single tooltip frame
-- Hooks: OnShow (apply sigil), OnHide (hide chrome), OnUpdate (sync alpha +
-- cursor tracking), OnSizeChanged (re-apply), OnTooltipSetUnit/Item (re-apply).
-- @param tooltip (Frame) - Tooltip frame to hook
-- @note Idempotent — skips if tooltip._mui_sigil_hooked is already set
-- @note Does NOT call ApplySigil at hook time because tooltip may have zero
--       geometry during PLAYER_LOGIN. OnShow fires with real dimensions.
local function HookTooltip(tooltip)
    if not tooltip or tooltip._mui_sigil_hooked then return end
    tooltip._mui_sigil_hooked = true

    tooltip:HookScript("OnShow", function(self) ApplySigil(self) end)
    tooltip:HookScript("OnHide", function(self)
        if self._mui_chrome then self._mui_chrome:Hide() end
        if self._mui_shadow then self._mui_shadow:Hide() end
        self._mui_unit = nil
        self._mui_custom_guid = nil
        self._mui_transitioning = nil
        self._mui_sizeChangeDefer = nil
    end)

    --- GetTooltipTextAlpha: Reads the alpha of the first visible text line
    -- Some tooltip fade animations lower text alpha before frame alpha,
    -- so chrome must track the minimum of both to stay visually synced.
    -- @param self (Frame) - The tooltip
    -- @return (number|nil) - Alpha of first visible text, or nil
    local function GetTooltipTextAlpha(self)
        if not self.GetName then return nil end
        local name = self:GetName()
        if not name or name == "" then return nil end
        local num = self:NumLines() or 0
        for i = 1, num do
            local left = _G[name .. "TextLeft" .. i]
            if left and left.IsShown and left:IsShown() then
                local a = left:GetAlpha()
                if type(a) == "number" then return a end
            end
        end
        for i = 1, num do
            local right = _G[name .. "TextRight" .. i]
            if right and right.IsShown and right:IsShown() then
                local a = right:GetAlpha()
                if type(a) == "number" then return a end
            end
        end
        return nil
    end

    -- OnUpdate: sync chrome/shadow alpha with tooltip, track minimum of frame
    -- and text alpha so chrome fades in lockstep with tooltip fade animations
    tooltip:HookScript("OnUpdate", function(self)
        local alpha = self:GetAlpha() or 1
        local textAlpha = GetTooltipTextAlpha(self)
        -- 12.0.1: GetAlpha() on tooltip text can return a secret number value
        -- that taints on comparison. pcall the comparison to avoid taint spam.
        if textAlpha then
            local ok, isLess = pcall(function() return type(textAlpha) == "number" and textAlpha < alpha end)
            if ok and isLess then alpha = textAlpha end
        end
        if self._mui_chrome and self._mui_chrome:IsShown() then
            self._mui_chrome:SetAlpha(alpha)
        end
        if self._mui_shadow and self._mui_shadow:IsShown() then
            self._mui_shadow:SetAlpha(alpha)
        end
        -- Accent textures can outlive the frame fade path on some tooltips,
        -- so force them to track the same resolved alpha
        if self._mui_stripe then self._mui_stripe:SetAlpha(alpha) end
        if self._mui_stripeShineLeft then self._mui_stripeShineLeft:SetAlpha(alpha) end
        if self._mui_stripeShineRight then self._mui_stripeShineRight:SetAlpha(alpha) end
        if self._mui_topShadow then self._mui_topShadow:SetAlpha(alpha) end
        if self._mui_topGlow then self._mui_topGlow:SetAlpha(alpha) end
        if self._mui_is_shopping then
            -- Shopping tooltips track the main tooltip, not the cursor
            if DoRepositionShopping then DoRepositionShopping(self) end
        elseif MUI_ForceCursorTooltips() then
            AnchorTooltipToCursor(self)
        end
    end)

    -- OnSizeChanged: refresh chrome geometry without re-applying padding.
    -- Using RefreshSigilChrome (not ApplySigil) prevents the flicker loop
    -- where Blizzard strips padding → OnSizeChanged → re-add padding → repeat.
    --
    -- When Blizzard switches the tooltip to a new unit without hiding it,
    -- ClearLines fires (lines=0) followed by a burst of intermediate sizes
    -- that can spike to ~800-1000px EVEN WITH content present.  Since the
    -- chrome is point-anchored, it follows those spikes.  To fix this we
    -- mark the tooltip as "transitioning" when lines drops to 0, keep the
    -- chrome hidden for the entire burst, and defer the refresh to the next
    -- frame when the layout has settled.  Normal size changes (padding,
    -- content reflow) that don't pass through a 0-line state still get an
    -- immediate refresh with no perceptible gap.
    tooltip:HookScript("OnSizeChanged", function(self, w, h)
        if self._mui_inSizeChanged then return end
        if self:IsShown() then
            -- Detect transition: ClearLines sets lines to 0
            if (self:NumLines() or 0) < 1 then
                self._mui_transitioning = true
            end

            if self._mui_transitioning then
                -- Hide chrome for the entire transition burst
                if self._mui_chrome and self._mui_chrome:IsShown() then self._mui_chrome:Hide() end
                if self._mui_shadow and self._mui_shadow:IsShown() then self._mui_shadow:Hide() end
                -- Schedule a single deferred refresh after the burst settles
                if not self._mui_sizeChangeDefer then
                    self._mui_sizeChangeDefer = true
                    C_Timer.After(0, function()
                        self._mui_sizeChangeDefer = nil
                        self._mui_transitioning = nil
                        if self:IsShown() and (self:NumLines() or 0) > 0 then
                            self._mui_inSizeChanged = true
                            RefreshSigilChrome(self)
                            self._mui_inSizeChanged = nil
                        end
                    end)
                end
                return
            end

            -- Normal size change (no transition) — immediate refresh
            self._mui_inSizeChanged = true
            RefreshSigilChrome(self)
            self._mui_inSizeChanged = nil
        end
    end)

    -- Re-apply sigil when tooltip content changes to unit or item data
    pcall(tooltip.HookScript, tooltip, "OnTooltipSetUnit", function(self) ApplySigil(self) end)
    pcall(tooltip.HookScript, tooltip, "OnTooltipSetItem", function(self) ApplySigil(self) end)
end

--- InstallSigilHooks: Hooks all standard Blizzard tooltip frames
-- Called on PLAYER_LOGIN and ADDON_LOADED to catch tooltips as they become available.
-- @calls HookTooltip for each known tooltip global
local function InstallSigilHooks()
    for _, tt in ipairs({
        _G.GameTooltip,
        _G.ItemRefTooltip,
        _G.ShoppingTooltip1,
        _G.ShoppingTooltip2,
        _G.ItemRefShoppingTooltip1,
        _G.ItemRefShoppingTooltip2,
        _G.EmbeddedItemTooltip,
        _G.WorldMapTooltip,
        _G.QuickKeybindTooltip,
        _G.ReputationParagonTooltip,
    }) do
        HookTooltip(tt)
    end
end

--- M.ApplyTooltipAnchorSettings: Re-anchors all visible tooltips to cursor
-- Called when forceCursorTooltips setting changes at runtime.
-- @calledby Settings panel, _G.MidnightUI_ApplyTooltipAnchorSettings
function M.ApplyTooltipAnchorSettings()
    if not MUI_ForceCursorTooltips() then return end
    for _, tt in ipairs({
        _G.GameTooltip,
        _G.ItemRefTooltip,
        _G.ShoppingTooltip1,
        _G.ShoppingTooltip2,
        _G.ItemRefShoppingTooltip1,
        _G.ItemRefShoppingTooltip2,
        _G.EmbeddedItemTooltip,
        _G.WorldMapTooltip,
        _G.QuickKeybindTooltip,
        _G.ReputationParagonTooltip,
    }) do
        if tt and tt.IsShown and tt:IsShown() then
            AnchorTooltipToCursor(tt)
        end
    end
end

-- Global bridge for cross-module access to ApplyTooltipAnchorSettings
_G.MidnightUI_ApplyTooltipAnchorSettings = function()
    if M and M.ApplyTooltipAnchorSettings then
        M.ApplyTooltipAnchorSettings()
    end
end

-- ── Shopping tooltip anti-overlap ─────────────────────────────────────
-- Force comparison (shopping) tooltips side-by-side with the main tooltip.
-- Blizzard sometimes stacks them vertically which causes overlap with our
-- chrome + shadow.  We always place the comparison to the right of the
-- main tooltip, or to the left if there isn't enough screen space.
local SHOPPING_GAP = (CHROME_PAD_X + 8) * 2 + 4  -- gap between chrome edges

DoRepositionShopping = function(self)
    if not self:IsShown() then return end
    local mainTip = _G.GameTooltip
    if not mainTip or not mainTip:IsShown() then return end

    local selfW = self:GetWidth() or 0
    local mainR = mainTip:GetRight() or 0
    local screenW = GetScreenWidth() or 1920

    self:ClearAllPoints()
    if (mainR + SHOPPING_GAP + selfW) <= screenW then
        self:SetPoint("TOPLEFT", mainTip, "TOPRIGHT", SHOPPING_GAP, 0)
    else
        self:SetPoint("TOPRIGHT", mainTip, "TOPLEFT", -SHOPPING_GAP, 0)
    end
end

local function RepositionShoppingTooltip(self)
    if not MUI_TooltipEnabled() then return end
    -- Defer by one frame: Blizzard's TooltipComparisonManager repositions
    -- the shopping tooltip AFTER OnShow returns, overwriting any anchor we
    -- set here.  C_Timer.After(0) lets Blizzard finish, then we override.
    local captured = self
    C_Timer.After(0, function()
        if captured and captured:IsShown() then
            DoRepositionShopping(captured)
        end
    end)
end

local function InstallShoppingTooltipHooks()
    for _, tt in ipairs({
        _G.ShoppingTooltip1,
        _G.ShoppingTooltip2,
        _G.ItemRefShoppingTooltip1,
        _G.ItemRefShoppingTooltip2,
    }) do
        if tt and not tt._mui_shopping_hooked then
            tt._mui_shopping_hooked = true
            tt._mui_is_shopping = true  -- flag so OnUpdate/ApplySigil skip cursor anchoring
            tt:HookScript("OnShow", RepositionShoppingTooltip)
        end
    end
end

-- Sigil initialization frame: installs hooks on PLAYER_LOGIN and ADDON_LOADED
local SigilInit = CreateFrame("Frame")
SigilInit:RegisterEvent("PLAYER_LOGIN")
SigilInit:RegisterEvent("ADDON_LOADED")
SigilInit:SetScript("OnEvent", function(_, event)
    if event == "PLAYER_LOGIN" or event == "ADDON_LOADED" then
        InstallSigilHooks()
        InstallShoppingTooltipHooks()
    end
end)


-- ============================================================================
-- DEBUG & TAINT-TRACE INFRASTRUCTURE
-- Provides M.Debug() logging with ring buffer, taint detection/reporting,
-- and hooks into Blizzard's ADDON_ACTION_BLOCKED/FORBIDDEN events.
-- ============================================================================

-- Maximum number of debug messages retained in _G.MidnightUI_DebugLog ring buffer
local DEBUG_MAX = 500

--- SafeToString: Safely converts any value to string, handling taint/restricted values
-- @param value (any) - Value to convert
-- @return (string) - String representation, or "[Restricted]" if tainted
local function SafeToString(value)
    if value == nil then return "nil" end
    local ok, s = pcall(tostring, value)
    if not ok then return "[Restricted]" end
    -- Verify string is not tainted by attempting concatenation
    local ok2 = pcall(function() return s .. "" end)
    if not ok2 then return "[Restricted]" end
    return s
end

--- M.TaintTraceEnabled: Returns whether taint tracing mode is active
-- @return (boolean) - true if MidnightUISettings.General.taintTrace is true
function M.TaintTraceEnabled()
    return MidnightUISettings and MidnightUISettings.General and MidnightUISettings.General.taintTrace == true
end

--- M.TaintTrace: Logs a taint trace message with call stack
-- Only active when taint tracing is enabled in settings.
-- @param tag (string) - Label identifying the taint source
-- @calls _G.MidnightUI_Debug or queues to _G.MidnightUI_DebugQueue
function M.TaintTrace(tag)
    if not M.TaintTraceEnabled() then return end
    local stack = ""
    if debugstack then
        local ok, ds = pcall(debugstack, 2, 8, 8)
        if ok and ds then stack = ds end
    end
    if _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("[TaintTrace] " .. tostring(tag) .. " stack=" .. tostring(stack))
    else
        _G.MidnightUI_DebugQueue = _G.MidnightUI_DebugQueue or {}
        table.insert(_G.MidnightUI_DebugQueue, "[TaintTrace] " .. tostring(tag) .. " stack=" .. tostring(stack))
    end
end

-- Legacy bridge: older modules reference _G.MidnightUI_Settings.TaintTrace
_G.MidnightUI_Settings = _G.MidnightUI_Settings or {}
_G.MidnightUI_Settings.TaintTrace = M.TaintTrace
_G.MidnightUI_Settings.TaintTraceEnabled = M.TaintTraceEnabled

-- ============================================================================
-- TAINT TRACE EVENTS (SENSITIVE MODE)
-- Monitors Blizzard's ADDON_ACTION_BLOCKED/FORBIDDEN events and logs details
-- to multiple output channels: Diagnostics panel, debug log, Messenger debug
-- tab, chat frame, and UIErrorsFrame.
-- ============================================================================

--- EmitTaintMessage: Broadcasts a taint trace message to all available output channels
-- Output targets (in order of preference):
--   1. MidnightUI_Diagnostics.LogDebugSource() (Diagnostics.lua)
--   2. _G.MidnightUI_Debug (debug log ring buffer)
--   3. MessengerDB.History.Debug (Messenger addon debug tab)
--   4. _G.MidnightUI_DebugQueue (pre-Core queue fallback)
--   5. DEFAULT_CHAT_FRAME (always, if available)
--   6. UIErrorsFrame (always, if available)
-- @param tag (string) - Event/source identifier
-- @param detail (string|nil) - Additional context string
local function EmitTaintMessage(tag, detail)
    if not M.TaintTraceEnabled() then return end
    local msg = "[TaintTrace] " .. tostring(tag)
    if detail then
        msg = msg .. " " .. tostring(detail)
    end
    -- Channel 1: Diagnostics panel (defined in Diagnostics.lua)
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource
        and _G.MidnightUI_Diagnostics.IsEnabled
        and _G.MidnightUI_Diagnostics.IsEnabled() then
        _G.MidnightUI_Diagnostics.LogDebugSource("TaintTrace", msg)
    end
    -- Channel 2: Debug ring buffer
    local wrote = false
    if _G.MidnightUI_Debug then
        _G.MidnightUI_Debug(msg)
        wrote = true
    end
    -- Channel 3: Messenger addon debug history tab
    if not wrote and MessengerDB and MessengerDB.History then
        MessengerDB.History.Debug = MessengerDB.History.Debug or { unread = 0, messages = {} }
        table.insert(MessengerDB.History.Debug.messages, {
            msg = msg,
            author = "Debug",
            nameColorDefault = "ffaa00",
            msgColorDefault = "ffffff",
            tag = "DBG",
            timestamp = date("%H:%M:%S"),
            epoch = time(),
        })
        if MessengerDB.LastActiveTab ~= "Debug" then
            MessengerDB.History.Debug.unread = (MessengerDB.History.Debug.unread or 0) + 1
        end
        wrote = true
    end
    -- Channel 4: Early queue fallback
    if not wrote then
        _G.MidnightUI_DebugQueue = _G.MidnightUI_DebugQueue or {}
        table.insert(_G.MidnightUI_DebugQueue, msg)
    end
    -- Channel 5+6: Always show in chat and error frames for immediate visibility
    if _G.DEFAULT_CHAT_FRAME and _G.DEFAULT_CHAT_FRAME.AddMessage then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cffffaa00" .. msg .. "|r")
    end
    if _G.UIErrorsFrame and _G.UIErrorsFrame.AddMessage then
        _G.UIErrorsFrame:AddMessage(msg, 1, 0.8, 0.2)
    end
end

-- Event listener for Blizzard taint events
local TaintTraceFrame = CreateFrame("Frame")
TaintTraceFrame:RegisterEvent("ADDON_ACTION_BLOCKED")
TaintTraceFrame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
TaintTraceFrame:SetScript("OnEvent", function(_, event, ...)
    if not M.TaintTraceEnabled() then return end
    if event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        local addonName, action = ...
        EmitTaintMessage(event, "addon=" .. tostring(addonName) .. " action=" .. tostring(action))
        M.TaintTrace(event .. " " .. tostring(addonName) .. " " .. tostring(action))
    end
end)

-- Hook StaticPopup_Show to capture the actual blocked-action popup dialog,
-- regardless of whether the event was delivered to our frame
  if type(hooksecurefunc) == "function" and type(StaticPopup_Show) == "function" then
      hooksecurefunc("StaticPopup_Show", function(which, text, arg1, arg2)
          if not M.TaintTraceEnabled() then return end
          if which == "ADDON_ACTION_BLOCKED" or which == "ADDON_ACTION_FORBIDDEN" then
              local detail = "which=" .. SafeToString(which) .. " text=" .. SafeToString(text)
              detail = detail .. " arg1=" .. SafeToString(arg1) .. " arg2=" .. SafeToString(arg2)
              EmitTaintMessage("STATICPOPUP", detail)
              M.TaintTrace("STATICPOPUP " .. SafeToString(which))
          end
      end)
  end

-- ============================================================================
-- SETTINGS INITIALIZATION & MODULE REGISTRY
-- EnsureSettings creates all required subtables in MidnightUISettings.
-- The module registry allows other files to register init/apply callbacks.
-- ============================================================================

--- EnsureTable: Creates a subtable at root[key] if it doesn't exist
-- @param root (table) - Parent table
-- @param key (string) - Key for the subtable
-- @return (table) - The existing or newly created subtable
local function EnsureTable(root, key)
    if not root[key] then root[key] = {} end
    return root[key]
end

--- M.SafeCall: Executes a function via pcall, logging errors to M.Debug
-- @param label (string) - Descriptive label for error messages
-- @param fn (function) - Function to call
-- @param ... (any) - Arguments passed to fn
-- @return (boolean, any) - success flag and result/error
function M.SafeCall(label, fn, ...)
    if type(fn) ~= "function" then return end
    local ok, res = pcall(fn, ...)
    if not ok then
        M.Debug("[Core] Error in " .. SafeToString(label) .. ": " .. SafeToString(res))
        return false, res
    end
    return true, res
end

--- M.SetDebug: Enables or disables debug logging and chat output
-- @param enabled (boolean) - Whether to enable debug logging
-- @param toChat (boolean) - Whether to also print debug messages to chat
function M.SetDebug(enabled, toChat)
    M.DebugEnabled = enabled == true
    M.DebugToChat = toChat == true
end

--- M.Debug: Logs a debug message to _G.MidnightUI_DebugLog ring buffer
-- Messages are also printed to DEFAULT_CHAT_FRAME if M.DebugToChat is true.
-- The ring buffer is capped at DEBUG_MAX (500) entries.
-- @param ... (any) - Values to concatenate into the log message
-- @calledby M.SafeCall, M.FlushDebugQueue, and many other modules
function M.Debug(...)
    if not M.DebugEnabled then return end
    local parts = {}
    for i = 1, select("#", ...) do
        parts[#parts + 1] = SafeToString(select(i, ...))
    end
    local msg = table.concat(parts, " ")
    local log = _G.MidnightUI_DebugLog
    if not log then
        log = {}
        _G.MidnightUI_DebugLog = log
    end
    log[#log + 1] = msg
    -- Trim ring buffer to DEBUG_MAX entries
    if #log > DEBUG_MAX then
        table.remove(log, 1)
    end
    if M.DebugToChat and _G.DEFAULT_CHAT_FRAME then
        _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r " .. msg)
    end
end

--- M.FlushDebugQueue: Drains _G.MidnightUI_DebugQueue into M.Debug
-- Called once by Core.lua on ADDON_LOADED after M.Debug is fully initialized,
-- replacing the Bootstrap.lua stub. If debug is disabled, silently wipes the queue.
-- @calls M.Debug for each queued message
function M.FlushDebugQueue()
    local q = _G.MidnightUI_DebugQueue
    if not q then return end
    if not M.DebugEnabled then
        wipe(q)
        _G.MidnightUI_DebugQueue = nil
        return
    end
    for i = 1, #q do
        M.Debug(q[i])
    end
    wipe(q)
    _G.MidnightUI_DebugQueue = nil
end

--- M.EnsureSettings: Initializes MidnightUISettings with all required subtables
-- Creates empty subtables for every module that reads from settings, and sets
-- default values for global flags (debug, debugToChat, lowMemory, etc.).
-- @calledby OnEvent handler on ADDON_LOADED for "MidnightUI"
function M.EnsureSettings()
    _G.MidnightUISettings = _G.MidnightUISettings or {}
    local s = _G.MidnightUISettings
    EnsureTable(s, "Messenger")
    EnsureTable(s, "General")
    EnsureTable(s, "Minimap")
    EnsureTable(s, "ActionBars")
    EnsureTable(s, "PlayerFrame")
    EnsureTable(s, "TargetFrame")
    EnsureTable(s, "FocusFrame")
    EnsureTable(s, "CastBars")
    EnsureTable(s, "Nameplates")
    EnsureTable(s, "PartyFrames")
    EnsureTable(s, "RaidFrames")
    EnsureTable(s, "MainTankFrames")
    EnsureTable(s, "StanceBar")
    EnsureTable(s, "PetBar")
    EnsureTable(s, "Market")

    if s.debug == nil then s.debug = false end
    if s.debugToChat == nil then s.debugToChat = false end
    if s.lowMemory == nil then s.lowMemory = false end
    if s.General.useBlizzardQuestingInterface == nil then
        s.General.useBlizzardQuestingInterface = false
    end
    M.SetDebug(s.debug == true, s.debugToChat == true)
end

--- M.RegisterModule: Registers a named module with init/apply callbacks
-- @param name (string) - Unique module name (e.g. "Messenger", "Nameplates")
-- @param def (table) - Module definition with fields:
--   .enabled (function) - Returns boolean; module skipped if false
--   .init (function|nil) - One-time initialization callback
--   .apply (function|nil) - Settings-apply callback (may run multiple times)
--   .once (boolean|nil) - If true (default), init runs only once
function M.RegisterModule(name, def)
    if not name or type(def) ~= "table" then return end
    def.name = name
    if not def.enabled then
        def.enabled = function() return true end
    end
    if def.once == nil then def.once = true end
    M.Modules[name] = def
end

--- M.InitModule: Initializes a single registered module by name
-- Calls def.init (if not already inited, or if once==false) then def.apply.
-- @param name (string) - Module name
-- @param phase (string) - Current load phase ("ADDON_LOADED", "PLAYER_LOGIN", etc.)
-- @calls M.SafeCall
function M.InitModule(name, phase)
    local def = M.Modules[name]
    if not def then return end
    if def.enabled and def.enabled() == false then return end

    local state = M._moduleState[name] or {}
    M._moduleState[name] = state

    if def.init and (not state.inited or def.once == false) then
        M.SafeCall(name .. ".init", def.init, phase)
        state.inited = true
    end
    if def.apply then
        M.SafeCall(name .. ".apply", def.apply, phase)
    end
end

--- M.InitModules: Initializes all registered modules for a given phase
-- @param phase (string) - Load phase (e.g. "ADDON_LOADED", "PLAYER_LOGIN")
-- @calls M.InitModule for each registered module
function M.InitModules(phase)
    for name, _ in pairs(M.Modules) do
        M.InitModule(name, phase)
    end
end

--- M.RunOrDefer: Executes a function immediately, or queues it if in combat
-- Prevents taint by deferring UI changes until PLAYER_REGEN_ENABLED.
-- @param label (string) - Descriptive label for SafeCall
-- @param fn (function) - Function to execute
-- @calls M.SafeCall or queues to M._deferQueue
function M.RunOrDefer(label, fn)
    if InCombatLockdown and InCombatLockdown() then
        M._deferQueue[#M._deferQueue + 1] = { label = label, fn = fn }
        return
    end
    M.SafeCall(label, fn)
end

--- M.FlushDeferred: Executes all combat-deferred functions
-- Called on PLAYER_REGEN_ENABLED (combat ends). Skips if still in combat.
-- @calls M.SafeCall for each queued item
function M.FlushDeferred()
    if InCombatLockdown and InCombatLockdown() then return end
    if #M._deferQueue == 0 then return end
    local q = M._deferQueue
    M._deferQueue = {}
    for i = 1, #q do
        local item = q[i]
        M.SafeCall(item.label, item.fn)
    end
    wipe(q)
end

-- ============================================================================
-- DEFAULT MODULE REGISTRATIONS
-- Registers built-in modules with their enabled checks and apply callbacks.
-- Each apply function calls the relevant global function exported by the
-- module's own .lua file (e.g. ApplyMessengerSettings from Messenger.lua).
-- ============================================================================

M.RegisterModule("Messenger", {
    enabled = function()
        return true
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyMessengerSettings then S.ApplyMessengerSettings() end
        if _G.MidnightUI_ApplyDefaultChatInterfaceVisibility then
            _G.MidnightUI_ApplyDefaultChatInterfaceVisibility()
        end
    end,
})

M.RegisterModule("Nameplates", {
    enabled = function()
        local s = _G.MidnightUISettings
        return not (s and s.Nameplates and s.Nameplates.enabled == false)
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyNameplateSettings then S.ApplyNameplateSettings() end
    end,
})

M.RegisterModule("ActionBars", {
    -- Enabled if globalStyle is set or any individual bar is enabled
    enabled = function()
        local s = _G.MidnightUISettings
        if not s or not s.ActionBars then return true end
        if s.ActionBars.globalStyle and s.ActionBars.globalStyle ~= "Disabled" then return true end
        for i = 1, 8 do
            local bar = s.ActionBars["bar" .. i]
            if bar and bar.enabled ~= false then return true end
        end
        return false
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyActionBarSettings then S.ApplyActionBarSettings() end
        if _G.MyActionBars_ReloadSettingsImmediate then _G.MyActionBars_ReloadSettingsImmediate()
        elseif _G.MyActionBars_ReloadSettings then _G.MyActionBars_ReloadSettings() end
    end,
})

M.RegisterModule("Frames", {
    -- Enabled if any of player/target/focus frames or cast bars are enabled
    enabled = function()
        local s = _G.MidnightUISettings
        if not s then return true end
        local pf = s.PlayerFrame and s.PlayerFrame.enabled ~= false
        local tf = s.TargetFrame and s.TargetFrame.enabled ~= false
        local ff = s.FocusFrame and s.FocusFrame.enabled ~= false
        local cb = s.CastBars
        local cbOn = true
        if cb and cb.player and cb.target then
            cbOn = (cb.player.enabled ~= false) or (cb.target.enabled ~= false)
        end
        return pf or tf or ff or cbOn
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyPlayerSettings then S.ApplyPlayerSettings() end
        if S and S.ApplyTargetSettings then S.ApplyTargetSettings() end
        if S and S.ApplyFocusSettings then S.ApplyFocusSettings() end
        if S and S.ApplyCastBarSettings then S.ApplyCastBarSettings() end
    end,
})

M.RegisterModule("PartyRaid", {
    -- Disabled in low-memory mode
    enabled = function()
        local s = _G.MidnightUISettings
        return not (s and s.lowMemory == true)
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyPartyFramesSettings then S.ApplyPartyFramesSettings() end
        if S and S.ApplyRaidFramesSettings then S.ApplyRaidFramesSettings() end
        if _G.MidnightUI_ApplyMainTankSettings then _G.MidnightUI_ApplyMainTankSettings() end
    end,
})

M.RegisterModule("Minimap", {
    enabled = function()
        return true
    end,
    apply = function()
        local S = _G.MidnightUI_Settings
        if S and S.ApplyMinimapSettings then S.ApplyMinimapSettings() end
    end,
})

M.RegisterModule("Market", {
    -- Disabled in low-memory mode
    enabled = function()
        local s = _G.MidnightUISettings
        return not (s and s.lowMemory == true)
    end,
    apply = function()
        -- Market.lua is self-contained (no external apply function)
    end,
})

-- ============================================================================
-- OVERLAY POSITION / STYLING / SETTINGS SYSTEM
-- Provides a unified system for movable UI element overlays: saving/restoring
-- positions, visual styling with category colors, right-click settings panels,
-- and a builder API for creating settings UI controls (checkboxes, sliders, etc.).
-- ============================================================================

-- Overlay registrations: key → {title, category, build, applyFunc, settingsPage, ...}
M.OverlaySettings = M.OverlaySettings or {}
-- Overlay frame references: key → overlay frame (for external access)
M.OverlayHandles = M.OverlayHandles or {}

-- OVERLAY_CATEGORY_COLORS: Visual color coding for overlay categories
-- Used by: StyleOverlay() accent stripe/border tinting, overlay settings panel badge
-- Each category maps to {r, g, b} array.
local OVERLAY_CATEGORY_COLORS = {
    unit   = { 0.30, 0.70, 0.95 },  -- Blue (unit frames: player, target, focus)
    cast   = { 0.90, 0.65, 0.30 },  -- Orange (cast bars)
    auras  = { 0.65, 0.40, 0.90 },  -- Purple (buff/debuff bars)
    bars   = { 0.45, 0.85, 0.45 },  -- Green (action/pet/stance bars)
    world  = { 0.85, 0.75, 0.40 },  -- Gold (minimap, chat, menu)
}
M.OVERLAY_CATEGORY_COLORS = OVERLAY_CATEGORY_COLORS

-- Human-readable labels for each overlay category
local OVERLAY_CATEGORY_LABELS = {
    unit = "Unit Frame", cast = "Cast Bar", auras = "Auras",
    bars = "Action Bar", world = "Interface",
}

--- M.RegisterOverlaySettings: Registers a settings definition for an overlay key
-- @param key (string) - Overlay identifier (e.g. "PlayerFrame", "ActionBar1")
-- @param def (table) - Settings definition with fields:
--   .title (string) - Display name for the settings panel header
--   .category (string) - One of: "unit", "cast", "auras", "bars", "world"
--   .build (function) - Builder function(content, key) → height
--   .applyFunc (string|nil) - Name of M[applyFunc] to call on reset
--   .settingsPage (string|nil) - Settings page to open via "Open in Settings" button
function M.RegisterOverlaySettings(key, def)
    if not key or type(def) ~= "table" then return end
    M.OverlaySettings[key] = def
end

--- ResolveOverlayPositionTarget: Maps an overlay key to its settings subtable
-- Used by position save/reset logic to find where to store position data.
-- @param key (string) - Overlay key (e.g. "PlayerFrame", "ActionBar3", "CastBar_player")
-- @return (table|nil) - The settings subtable that holds .position data
local function ResolveOverlayPositionTarget(key)
    local s = _G.MidnightUISettings
    if not s or type(key) ~= "string" then return nil end

    -- ActionBar1-8 → s.ActionBars.bar1-bar8
    local barNum = tonumber(key:match("^ActionBar(%d+)$") or "")
    if barNum and s.ActionBars then
        return s.ActionBars["bar" .. barNum]
    end

    -- CastBar_player / CastBar_target → s.CastBars.player / s.CastBars.target
    local castKind = key:match("^CastBar_(%a+)$")
    if castKind and s.CastBars and s.CastBars[castKind] then
        return s.CastBars[castKind]
    end

    -- Direct key → settings subtable mappings
    if key == "Messenger" then return s.Messenger end
    if key == "PlayerFrame" then return s.PlayerFrame end
    if key == "TargetFrame" then return s.TargetFrame end
    if key == "FocusFrame" then return s.FocusFrame end
    if key == "RaidFrames" then return s.RaidFrames end
    if key == "PartyFrames" then return s.PartyFrames end
    if key == "ConsumableBars" then return s.ConsumableBars end
    if key == "PetBar" then return s.PetBar end
    if key == "StanceBar" then return s.StanceBar end
    -- Nested subtable mappings for auras and target-of-target
    if key == "PlayerAuras" then return s.PlayerFrame and s.PlayerFrame.auras end
    if key == "PlayerDebuffs" then return s.PlayerFrame and s.PlayerFrame.debuffs end
    if key == "TargetAuras" then return s.TargetFrame and s.TargetFrame.auras end
    if key == "TargetDebuffs" then return s.TargetFrame and s.TargetFrame.debuffs end
    if key == "TargetOfTarget" then return s.TargetFrame and s.TargetFrame.targetOfTarget end
    return nil
end

--- AttachOverlayRightClick: Installs right-click → settings panel and left-click → save position
-- on a movable overlay frame. Right-click opens/toggles the overlay settings popup;
-- left-click saves the overlay's new position to its settings subtable.
-- @param overlay (Frame) - The movable overlay frame
-- @param key (string) - Overlay key for settings lookup
-- @calls _G.MidnightUI_ShowOverlaySettings, _G.MidnightUI_SaveOverlayPosition
local function AttachOverlayRightClick(overlay, key)
    if not overlay or not key then return end
    if overlay._muiOverlayKey == key then return end
    overlay._muiOverlayKey = key
    M.OverlayHandles[key] = overlay
    local prev = overlay:GetScript("OnMouseUp")
    overlay:SetScript("OnMouseUp", function(self, button, ...)
        if button == "RightButton" and _G.MidnightUI_ShowOverlaySettings
            and MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false then
            local f = _G.MidnightUI_OverlaySettingsFrame
            if f and f:IsShown() and f._muiKey == key then
                f:Hide()
            else
                _G.MidnightUI_ShowOverlaySettings(key)
            end
            return
        end
        if prev then
            prev(self, button, ...)
        end
        -- On left-click release, persist the overlay's new position
        if button == "LeftButton" and _G.MidnightUI_SaveOverlayPosition then
            local target = ResolveOverlayPositionTarget(key)
            local host = self.GetParent and self:GetParent() or nil
            if host and target then
                _G.MidnightUI_SaveOverlayPosition(host, target)
            end
        end
    end)
end

-- ============================================================================
-- OVERLAY POSITION HELPERS
-- Save and restore overlay frame positions relative to UIParent or a parent frame.
-- ============================================================================

--- SaveOverlayPosition: Saves a frame's anchor position to a settings target table
-- Stores as target.position = {point, relativePoint, scaledX, scaledY}
-- @param frame (Frame) - The frame whose position to save
-- @param target (table) - Settings table to write .position into
local function SaveOverlayPosition(frame, target)
    if not frame or not target then return end
    local point, _, relativePoint, xOfs, yOfs = frame:GetPoint()
    if not point or not relativePoint or not xOfs or not yOfs then return end
    local scale = frame.GetScale and frame:GetScale()
    if not scale or scale == 0 then scale = 1 end
    target.position = { point, relativePoint, xOfs / scale, yOfs / scale }
end

--- ApplyOverlayPosition: Restores a frame's position from a saved position array
-- @param frame (Frame) - The frame to reposition
-- @param position (table) - {point, relativePoint, x, y} as saved by SaveOverlayPosition
-- @return (boolean) - true if position was successfully applied
local function ApplyOverlayPosition(frame, position)
    if not frame or not position or #position < 4 then return false end
    local scale = frame.GetScale and frame:GetScale()
    if not scale or scale == 0 then scale = 1 end
    frame:ClearAllPoints()
    frame:SetPoint(position[1], UIParent, position[2], position[3] * scale, position[4] * scale)
    return true
end

--- SaveRelativeOverlayPosition: Saves a frame's position relative to an owner frame
-- Used for child elements (e.g. aura bars relative to their unit frame).
-- Stores as target.positionRelative = {deltaX, deltaY} from owner's BOTTOMLEFT.
-- @param frame (Frame) - The child frame
-- @param ownerFrame (Frame) - The parent/reference frame
-- @param target (table) - Settings table to write .positionRelative into
local function SaveRelativeOverlayPosition(frame, ownerFrame, target)
    if not frame or not ownerFrame or not target then return end
    if not frame.GetLeft or not ownerFrame.GetLeft then return end
    if not frame.GetTop or not ownerFrame.GetBottom then return end
    local frameLeft = frame:GetLeft()
    local ownerLeft = ownerFrame:GetLeft()
    local frameTop = frame:GetTop()
    local ownerBottom = ownerFrame:GetBottom()
    if not frameLeft or not ownerLeft or not frameTop or not ownerBottom then return end
    target.positionRelative = { frameLeft - ownerLeft, frameTop - ownerBottom }
end

--- ApplyRelativeOverlayPosition: Restores a frame's position relative to an owner
-- @param frame (Frame) - The child frame to reposition
-- @param ownerFrame (Frame) - The parent/reference frame
-- @param position (table) - {deltaX, deltaY} as saved by SaveRelativeOverlayPosition
-- @return (boolean) - true if position was successfully applied
local function ApplyRelativeOverlayPosition(frame, ownerFrame, position)
    if not frame or not ownerFrame or not position or #position < 2 then return false end
    frame:ClearAllPoints()
    frame:SetPoint("TOPLEFT", ownerFrame, "BOTTOMLEFT", position[1], position[2])
    return true
end

--- ScaleFromPercent: Converts a percentage value (e.g. 120) to a scale factor (e.g. 1.20)
-- @param value (number|any) - Percentage value; non-numbers return 1
-- @return (number) - Scale factor
local function ScaleFromPercent(value)
    if type(value) ~= "number" then return 1 end
    return value / 100
end

-- ============================================================================
-- OVERLAY VISUAL STYLING
-- Color palettes and rendering functions for movable overlay frames (the
-- semi-transparent handles shown in Unlock/Move mode).
-- ============================================================================

-- OVERLAY_STYLE: Color palette for overlay frame normal and hover states
-- Each key maps to {r, g, b, a}
local OVERLAY_STYLE = {
    bg = { 0.03, 0.05, 0.08, 0.40 },
    border = { 0.25, 0.40, 0.55, 0.85 },
    accent = { 0.20, 0.50, 0.70, 0.22 },
    inset = { 0.25, 0.35, 0.48, 0.40 },
    label = { 0.95, 0.97, 1.00, 1.00 },
    labelBg = { 0.02, 0.04, 0.07, 0.70 },
    hoverBg = { 0.06, 0.10, 0.15, 0.55 },
    hoverBorder = { 0.40, 0.65, 0.85, 0.95 },
    hoverAccent = { 0.30, 0.70, 0.92, 0.35 },
    hoverInset = { 0.40, 0.55, 0.70, 0.60 },
}

-- OVERLAY_MENU_STYLE: Color palette for the overlay settings popup panel controls
local OVERLAY_MENU_STYLE = {
    section = { 0.88, 0.92, 0.98, 1.00 },
    sectionRule = { 0.14, 0.20, 0.28, 0.75 },
    cardBg = { 0.04, 0.06, 0.10, 0.92 },
    cardBorder = { 0.12, 0.18, 0.26, 0.70 },
    cardTop = { 0.15, 0.40, 0.60, 0.12 },
    label = { 0.92, 0.95, 0.99, 1.00 },
    value = { 0.40, 0.85, 1.00, 1.00 },
    note = { 0.68, 0.75, 0.84, 1.00 },
}

--- ApplyOverlayVisual: Sets background, border, accent, and inset colors on an overlay
-- Switches between normal and highlighted color sets.
-- @param overlay (Frame) - The overlay frame (must have BackdropTemplate)
-- @param highlighted (boolean) - true to use hover colors, false for normal
local function ApplyOverlayVisual(overlay, highlighted)
    if not overlay then return end

    local bg = highlighted and OVERLAY_STYLE.hoverBg or OVERLAY_STYLE.bg
    local border = highlighted and OVERLAY_STYLE.hoverBorder or OVERLAY_STYLE.border
    local accent = highlighted and OVERLAY_STYLE.hoverAccent or OVERLAY_STYLE.accent
    local inset = highlighted and OVERLAY_STYLE.hoverInset or OVERLAY_STYLE.inset

    overlay:SetBackdropColor(bg[1], bg[2], bg[3], bg[4])
    overlay:SetBackdropBorderColor(border[1], border[2], border[3], border[4])

    if overlay._muiTopAccent then
        overlay._muiTopAccent:SetVertexColor(accent[1], accent[2], accent[3], accent[4])
    end
    if overlay._muiInnerStroke and overlay._muiInnerStroke.SetBackdropBorderColor then
        overlay._muiInnerStroke:SetBackdropBorderColor(inset[1], inset[2], inset[3], inset[4])
    end
    -- Vertical gradient fill: adapts top→bottom colors based on hover state
    if overlay._muiFillGradient then
        local tr, tg, tb, ta, br, bgc, bb, ba
        if highlighted then
            tr, tg, tb, ta = 0.12, 0.18, 0.25, 0.26
            br, bgc, bb, ba = 0.03, 0.05, 0.08, 0.08
        else
            tr, tg, tb, ta = 0.10, 0.15, 0.21, 0.16
            br, bgc, bb, ba = 0.02, 0.04, 0.06, 0.04
        end

        -- Set safe dark fallback so unsupported gradient APIs never render white
        if overlay._muiFillGradient.SetColorTexture then
            overlay._muiFillGradient:SetColorTexture((tr + br) * 0.5, (tg + bgc) * 0.5, (tb + bb) * 0.5, math.max(ta, ba))
        end

        if overlay._muiFillGradient.SetGradientAlpha then
            pcall(overlay._muiFillGradient.SetGradientAlpha, overlay._muiFillGradient, "VERTICAL",
                tr, tg, tb, ta,
                br, bgc, bb, ba
            )
        end
    end
end

--- BalanceOverlayTextRegions: Normalizes text color, shadow, and minimum font size
-- for all FontString regions in an overlay frame.
-- @param overlay (Frame) - The overlay to process
-- @param minSize (number) - Minimum font size in points (default 12)
local function BalanceOverlayTextRegions(overlay, minSize)
    if not overlay then return end
    local regions = { overlay:GetRegions() }
    for _, region in ipairs(regions) do
        if region and region.GetObjectType and region:GetObjectType() == "FontString" then
            if region.SetTextColor then
                region:SetTextColor(
                    OVERLAY_STYLE.label[1],
                    OVERLAY_STYLE.label[2],
                    OVERLAY_STYLE.label[3],
                    OVERLAY_STYLE.label[4]
                )
            end
            if region.SetShadowColor then
                region:SetShadowColor(0, 0, 0, 0.85)
                region:SetShadowOffset(1, -1)
            end
            if region.GetFont and region.SetFont then
                local font, size, flags = region:GetFont()
                if font and size and size < (minSize or 12) then
                    pcall(region.SetFont, region, font, minSize or 12, flags)
                end
            end
        end
    end
end

--- StyleOverlay: Applies full MidnightUI visual styling to a movable overlay frame
-- Creates backdrop, accent stripe, fill gradient, inner stroke, label text with
-- background pill, and category badge. Installs hover/show/resize hooks.
-- @param overlay (Frame) - The overlay frame (must support BackdropTemplate)
-- @param labelText (string|nil) - Center label text (e.g. "Player Frame")
-- @param labelFont (string|nil) - Font object name (default "GameFontNormalLarge")
-- @param category (string|nil) - Overlay category for color tinting ("unit", "cast", etc.)
-- @calls ApplyOverlayVisual, BalanceOverlayTextRegions
local function StyleOverlay(overlay, labelText, labelFont, category)
    if not overlay then return end
    overlay._muiCategory = category
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        tile = true,
        tileSize = 16,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })

    -- Top accent stripe (colored by category)
    if not overlay._muiTopAccent then
        local accent = overlay:CreateTexture(nil, "ARTWORK")
        accent:SetTexture("Interface\\Buttons\\WHITE8X8")
        accent:SetPoint("TOPLEFT", 1, -1)
        accent:SetPoint("TOPRIGHT", -1, -1)
        overlay._muiTopAccent = accent
    end
    overlay._muiTopAccent:Hide()

    -- Background fill gradient texture
    if not overlay._muiFillGradient then
        local fill = overlay:CreateTexture(nil, "BACKGROUND")
        fill:SetTexture("Interface\\Buttons\\WHITE8X8")
        fill:SetPoint("TOPLEFT", 1, -1)
        fill:SetPoint("BOTTOMRIGHT", -1, 1)
        fill:SetColorTexture(0.06, 0.10, 0.14, 0.14)
        overlay._muiFillGradient = fill
    end

    -- Scale accent stripe height proportionally to overlay height (28% clamped 6-12px)
    local rawHeight = (overlay.GetHeight and overlay:GetHeight()) or 24
    local accentHeight = math.max(6, math.min(12, math.floor(rawHeight * 0.28)))
    overlay._muiTopAccent:SetHeight(accentHeight)

    -- Apply category-specific color tinting to accent stripe and border
    if category and OVERLAY_CATEGORY_COLORS[category] then
        local cc = OVERLAY_CATEGORY_COLORS[category]
        overlay._muiTopAccent:SetVertexColor(cc[1], cc[2], cc[3], 0.55)
        overlay:SetBackdropBorderColor(
            cc[1] * 0.5 + OVERLAY_STYLE.border[1] * 0.5,
            cc[2] * 0.5 + OVERLAY_STYLE.border[2] * 0.5,
            cc[3] * 0.5 + OVERLAY_STYLE.border[3] * 0.5,
            OVERLAY_STYLE.border[4]
        )
        -- Category badge FontString in top-left (currently hidden/empty)
        if not overlay._muiCategoryBadge then
            local badge = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            badge:SetPoint("TOPLEFT", 6, -4)
            overlay._muiCategoryBadge = badge
        end
        overlay._muiCategoryBadge:SetText("")
        overlay._muiCategoryBadge:Hide()
    end

    -- Inner stroke: subtle 1px inset border for depth
    if not overlay._muiInnerStroke then
        local inset = CreateFrame("Frame", nil, overlay, "BackdropTemplate")
        inset:SetPoint("TOPLEFT", 2, -2)
        inset:SetPoint("BOTTOMRIGHT", -2, 2)
        inset:SetBackdrop({
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
        })
        inset:SetBackdropBorderColor(0, 0, 0, 0)
        inset:EnableMouse(false)
        overlay._muiInnerStroke = inset
    end
    overlay._muiInnerStroke:Hide()
    ApplyOverlayVisual(overlay, overlay._muiHoverActive == true)
    BalanceOverlayTextRegions(overlay, 12)

    -- Center label text with dark background pill
    if labelText then
        local label = overlay._muiLabel
        if not label then
            label = overlay:CreateFontString(nil, "OVERLAY", labelFont or "GameFontNormal")
            overlay._muiLabel = label
        end
        if label.SetFontObject and labelFont then
            label:SetFontObject(labelFont)
        elseif label.SetFontObject then
            label:SetFontObject("GameFontNormalLarge")
        end
        label:ClearAllPoints()
        label:SetPoint("CENTER")
        label:SetText(labelText)
        -- Scale label font size proportionally to overlay height (30% clamped 12-16pt)
        if label.GetFont and label.SetFont then
            local fontPath, _, flags = label:GetFont()
            local labelSize = math.max(12, math.min(16, math.floor(rawHeight * 0.30)))
            if fontPath then
                pcall(label.SetFont, label, fontPath, labelSize, flags)
            end
        end
        label:SetTextColor(
            OVERLAY_STYLE.label[1],
            OVERLAY_STYLE.label[2],
            OVERLAY_STYLE.label[3],
            OVERLAY_STYLE.label[4]
        )
        if label.SetShadowColor then
            label:SetShadowColor(0, 0, 0, 0.85)
            label:SetShadowOffset(1, -1)
        end

        -- Dark background pill behind label text
        if not overlay._muiLabelBg then
            local labelBg = overlay:CreateTexture(nil, "ARTWORK")
            labelBg:SetTexture("Interface\\Buttons\\WHITE8X8")
            overlay._muiLabelBg = labelBg
        end
        overlay._muiLabelBg:ClearAllPoints()
        overlay._muiLabelBg:SetPoint("TOPLEFT", label, "TOPLEFT", -6, 4)
        overlay._muiLabelBg:SetPoint("BOTTOMRIGHT", label, "BOTTOMRIGHT", 6, -4)
        overlay._muiLabelBg:SetVertexColor(
            OVERLAY_STYLE.labelBg[1],
            OVERLAY_STYLE.labelBg[2],
            OVERLAY_STYLE.labelBg[3],
            OVERLAY_STYLE.labelBg[4]
        )
        overlay._muiLabelBg:Show()
    elseif overlay._muiLabelBg then
        overlay._muiLabelBg:Hide()
    end

    -- Install hover/show/resize hooks (once per overlay)
    if not overlay._muiHoverHooksInstalled and overlay.HookScript then
        overlay:HookScript("OnEnter", function(self)
            self._muiHoverActive = true
            ApplyOverlayVisual(self, true)
            BalanceOverlayTextRegions(self, 12)
        end)
        overlay:HookScript("OnLeave", function(self)
            self._muiHoverActive = false
            ApplyOverlayVisual(self, false)
            BalanceOverlayTextRegions(self, 12)
        end)
        overlay:HookScript("OnShow", function(self)
            ApplyOverlayVisual(self, self._muiHoverActive == true)
            BalanceOverlayTextRegions(self, 12)
        end)
        -- Dynamically resize accent stripe and label font when overlay resizes
        overlay:HookScript("OnSizeChanged", function(self)
            local h = (self.GetHeight and self:GetHeight()) or 24
            if self._muiTopAccent then
                local hAccent = math.max(6, math.min(12, math.floor(h * 0.28)))
                self._muiTopAccent:SetHeight(hAccent)
            end
            if self._muiLabel and self._muiLabel.GetFont and self._muiLabel.SetFont then
                local fontPath, _, flags = self._muiLabel:GetFont()
                local labelSize = math.max(12, math.min(16, math.floor(h * 0.30)))
                if fontPath then
                    pcall(self._muiLabel.SetFont, self._muiLabel, fontPath, labelSize, flags)
                end
            end
        end)
        overlay._muiHoverHooksInstalled = true
    end
end

-- ============================================================================
-- OVERLAY SETTINGS UI HELPERS
-- Tooltip attachment and button styling used by the overlay settings panel.
-- ============================================================================

--- GetTooltipText: Retrieves tooltip description text from _G.MidnightUI_Tooltips
-- @param label (string) - The tooltip key
-- @return (string|nil) - Tooltip text, or nil if not found
local function GetTooltipText(label)
    local t = _G.MidnightUI_Tooltips
    if t and label then
        return t[label]
    end
end

--- AttachTooltip: Adds GameTooltip hover behavior to a control
-- Shows tooltip with title + description on mouse enter, hides on leave.
-- Tooltip text is looked up from _G.MidnightUI_Tooltips[label].
-- @param control (Frame) - The frame to attach hover tooltip to
-- @param label (string) - Key into _G.MidnightUI_Tooltips for description text
local function AttachTooltip(control, label)
    local tip = GetTooltipText(label)
    if not control or not tip then return end
    control:SetScript("OnEnter", function(self)
        if not GameTooltip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(label, 1, 1, 1)
        GameTooltip:AddLine(tip, 0.9, 0.9, 0.9, true)
        if GameTooltip.SetWrapTextInTooltip then
            GameTooltip:SetWrapTextInTooltip(true)
        end
        GameTooltip:Show()
    end)
    control:SetScript("OnLeave", function()
        if GameTooltip then GameTooltip:Hide() end
    end)
end

--- StyleMidnightButton: Applies dark MidnightUI button chrome to a standard button
-- Hides Blizzard's default Left/Middle/Right button textures and replaces them
-- with a dark background, border, sheen, and hover highlight.
-- @param button (Frame) - A Button frame (typically UIPanelButtonTemplate)
-- @note Idempotent — skips if button.MidnightUI_Styled is already set
local function StyleMidnightButton(button)
    if not button or button.MidnightUI_Styled then return end
    button.MidnightUI_Styled = true

    if button.SetNormalFontObject then button:SetNormalFontObject("GameFontNormal") end
    if button.SetHighlightFontObject then button:SetHighlightFontObject("GameFontHighlight") end
    if button.SetDisabledFontObject then button:SetDisabledFontObject("GameFontDisable") end

    -- Hide Blizzard's default button slice textures
    if button.Left then button.Left:Hide() end
    if button.Middle then button.Middle:Hide() end
    if button.Right then button.Right:Hide() end

    -- Dark border (outer)
    local border = button:CreateTexture(nil, "BACKGROUND")
    border:SetTexture("Interface\\Buttons\\WHITE8X8")
    border:SetVertexColor(0.18, 0.22, 0.30, 1.0)
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetPoint("BOTTOMRIGHT", 0, 0)

    -- Dark fill (inset 2px from border)
    local bg = button:CreateTexture(nil, "BACKGROUND")
    bg:SetTexture("Interface\\Buttons\\WHITE8X8")
    bg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    bg:SetPoint("TOPLEFT", 2, -2)
    bg:SetPoint("BOTTOMRIGHT", -2, 2)

    -- Top-half sheen for subtle depth
    local sheen = button:CreateTexture(nil, "ARTWORK")
    sheen:SetTexture("Interface\\Buttons\\WHITE8X8")
    sheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    sheen:SetPoint("TOPLEFT", 3, -3)
    sheen:SetPoint("BOTTOMRIGHT", -3, 12)

    -- Hover highlight
    local hover = button:CreateTexture(nil, "HIGHLIGHT")
    hover:SetTexture("Interface\\Buttons\\WHITE8X8")
    hover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    hover:SetPoint("TOPLEFT", 2, -2)
    hover:SetPoint("BOTTOMRIGHT", -2, 2)

    if button.SetNormalTexture then button:SetNormalTexture("") end
    if button.SetHighlightTexture then button:SetHighlightTexture(hover) end
    if button.SetPushedTexture then button:SetPushedTexture("") end
    if button.SetDisabledTexture then button:SetDisabledTexture("") end
end

-- Expose StyleButton on M and as a global
M.StyleButton = StyleMidnightButton
_G.MidnightUI_StyleButton = function(button) StyleMidnightButton(button) end

-- ============================================================================
-- OVERLAY SETTINGS BUILDER API
-- CreateOverlayBuilder() returns a builder object with methods for adding
-- UI controls (Header, Checkbox, Slider, Dropdown, Note) to the overlay
-- settings popup panel. Controls are laid out vertically with collapsible sections.
-- ============================================================================

--- CreateOverlayBuilder: Creates a builder for adding controls to an overlay settings panel
-- @param content (Frame) - Parent frame for all created controls
-- @param opts (table|nil) - Options: {startY=number, width=number}
-- @return (table) - Builder with methods: :Header(), :Checkbox(), :Slider(), :Dropdown(), :Note(), :Height()
local function CreateOverlayBuilder(content, opts)
    local b = {}
    b.y = (opts and opts.startY) or -6         -- Current vertical cursor position
    b.width = (opts and opts.width) or 0
    b._sections = {}                            -- Array of section info tables
    b._currentSection = nil                     -- Currently active section name
    b._sectionControls = {}                     -- sectionName → {controls} for collapse

    --- CreateCardRow: Creates a styled card-style row frame at the current y position
    -- Each card has a dark background, thin border, and subtle top accent.
    -- @param height (number) - Row height in pixels
    -- @return (Frame) - The created row frame
    local function CreateCardRow(height)
        local row = CreateFrame("Frame", nil, content, "BackdropTemplate")
        row:SetPoint("TOPLEFT", 0, b.y)
        row:SetPoint("TOPRIGHT", 0, b.y)
        row:SetHeight(height)
        row:SetBackdrop({
            bgFile = "Interface\\Buttons\\WHITE8X8",
            edgeFile = "Interface\\Buttons\\WHITE8X8",
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        row:SetBackdropColor(
            OVERLAY_MENU_STYLE.cardBg[1],
            OVERLAY_MENU_STYLE.cardBg[2],
            OVERLAY_MENU_STYLE.cardBg[3],
            OVERLAY_MENU_STYLE.cardBg[4]
        )
        row:SetBackdropBorderColor(
            OVERLAY_MENU_STYLE.cardBorder[1],
            OVERLAY_MENU_STYLE.cardBorder[2],
            OVERLAY_MENU_STYLE.cardBorder[3],
            OVERLAY_MENU_STYLE.cardBorder[4]
        )

        -- Subtle top accent bar inside the card
        local top = row:CreateTexture(nil, "ARTWORK")
        top:SetTexture("Interface\\Buttons\\WHITE8X8")
        top:SetPoint("TOPLEFT", 1, -1)
        top:SetPoint("TOPRIGHT", -1, -1)
        top:SetHeight(12)
        top:SetVertexColor(
            OVERLAY_MENU_STYLE.cardTop[1],
            OVERLAY_MENU_STYLE.cardTop[2],
            OVERLAY_MENU_STYLE.cardTop[3],
            OVERLAY_MENU_STYLE.cardTop[4]
        )

        -- Advance vertical cursor past this row + 8px gap
        b.y = b.y - height - 8
        -- Track row in current section for collapse toggling
        if b._currentSection and b._sectionControls[b._currentSection] then
            local controls = b._sectionControls[b._currentSection]
            controls[#controls + 1] = row
        end
        return row
    end

    --- b:Header: Adds a collapsible section header with arrow indicator
    -- @param text (string) - Section title
    -- @param defaultCollapsed (boolean|nil) - If true, section starts collapsed
    function b:Header(text, defaultCollapsed)
        self._currentSection = text
        self._sectionControls[text] = {}

        local sectionFrame = CreateFrame("Frame", nil, content)
        sectionFrame:SetPoint("TOPLEFT", 0, self.y)
        sectionFrame:SetPoint("RIGHT", 0, 0)
        sectionFrame:SetHeight(20)

        -- Collapse/expand arrow indicator
        local arrow = sectionFrame:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(10, 10)
        arrow:SetPoint("LEFT", 2, 0)
        arrow:SetAtlas("common-dropdown-icon-back")
        arrow:SetVertexColor(0.70, 0.77, 0.85)
        arrow:SetRotation(defaultCollapsed and math.pi or -math.pi / 2)

        local header = sectionFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        header:SetPoint("LEFT", arrow, "RIGHT", 6, 0)
        header:SetText(text)
        header:SetTextColor(
            OVERLAY_MENU_STYLE.section[1],
            OVERLAY_MENU_STYLE.section[2],
            OVERLAY_MENU_STYLE.section[3],
            OVERLAY_MENU_STYLE.section[4]
        )

        -- Horizontal rule extending from header text to right edge
        local line = sectionFrame:CreateTexture(nil, "ARTWORK")
        line:SetTexture("Interface\\Buttons\\WHITE8X8")
        line:SetPoint("LEFT", header, "RIGHT", 8, 0)
        line:SetPoint("RIGHT", 0, 0)
        line:SetHeight(1)
        line:SetVertexColor(
            OVERLAY_MENU_STYLE.sectionRule[1],
            OVERLAY_MENU_STYLE.sectionRule[2],
            OVERLAY_MENU_STYLE.sectionRule[3],
            OVERLAY_MENU_STYLE.sectionRule[4]
        )

        local isCollapsed = defaultCollapsed == true
        local sectionInfo = { frame = sectionFrame, collapsed = isCollapsed, controls = self._sectionControls[text], arrow = arrow }
        self._sections[#self._sections + 1] = sectionInfo

        -- Click anywhere on the header to toggle section collapse
        sectionFrame:EnableMouse(true)
        sectionFrame:SetScript("OnMouseUp", function()
            sectionInfo.collapsed = not sectionInfo.collapsed
            arrow:SetRotation(sectionInfo.collapsed and math.pi or -math.pi / 2)
            for _, ctrl in ipairs(sectionInfo.controls) do
                if sectionInfo.collapsed then ctrl:Hide() else ctrl:Show() end
            end
        end)

        self.y = self.y - 22
    end

    --- b:Checkbox: Adds a checkbox control in a card row
    -- @param label (string) - Checkbox label text
    -- @param value (boolean) - Initial checked state
    -- @param onChange (function|nil) - Callback(isChecked) when toggled
    -- @return (CheckButton) - The created checkbox frame
    function b:Checkbox(label, value, onChange)
        local row = CreateCardRow(30)
        local cb = CreateFrame("CheckButton", nil, row, "InterfaceOptionsCheckButtonTemplate")
        cb:SetPoint("LEFT", 8, 0)
        cb.Text:SetText(label)
        cb.Text:SetFontObject("GameFontNormal")
        cb.Text:SetTextColor(
            OVERLAY_MENU_STYLE.label[1],
            OVERLAY_MENU_STYLE.label[2],
            OVERLAY_MENU_STYLE.label[3]
        )
        cb:SetChecked(value == true)
        cb:SetScript("OnClick", function(self) if onChange then onChange(self:GetChecked() == true) end end)
        AttachTooltip(cb, label)
        cb._muiRow = row
        return cb
    end

    --- b:Slider: Adds a slider control in a card row
    -- @param label (string) - Slider label text
    -- @param min (number) - Minimum value
    -- @param max (number) - Maximum value
    -- @param step (number) - Step increment
    -- @param value (number|nil) - Initial value (defaults to min)
    -- @param onChange (function|nil) - Callback(newValue) on value change
    -- @return (Frame) - Holder frame with .slider, .labelText, .valText, and
    --   convenience methods: SetMinMaxValues, SetValue, GetValue, SetValueStep, SetEnabled
    function b:Slider(label, min, max, step, value, onChange)
        local holder = CreateCardRow(58)

        local labelText = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        labelText:SetPoint("TOPLEFT", 10, -7)
        labelText:SetText(label)
        labelText:SetTextColor(
            OVERLAY_MENU_STYLE.label[1],
            OVERLAY_MENU_STYLE.label[2],
            OVERLAY_MENU_STYLE.label[3]
        )

        -- Current value display (right-aligned)
        local valText = holder:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        valText:SetPoint("TOPRIGHT", -10, -7)
        valText:SetTextColor(
            OVERLAY_MENU_STYLE.value[1],
            OVERLAY_MENU_STYLE.value[2],
            OVERLAY_MENU_STYLE.value[3]
        )

        local slider = CreateFrame("Slider", nil, holder, "OptionsSliderTemplate")
        slider:SetPoint("TOPLEFT", 8, -24)
        slider:SetPoint("TOPRIGHT", -8, -24)
        slider:SetHeight(20)
        slider:SetMinMaxValues(min, max)
        slider:SetValueStep(step)
        slider:SetObeyStepOnDrag(true)
        slider:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
        if slider.GetThumbTexture then
            local thumb = slider:GetThumbTexture()
            if thumb then thumb:SetSize(40, 28) end
        end

        -- Hide default Blizzard slider labels
        if slider.Low then slider.Low:Hide() end
        if slider.High then slider.High:Hide() end
        if slider.Text then slider.Text:Hide() end

        -- Format display value: decimal for fractional steps, integer otherwise
        local function FormatValue(v)
            if step < 1 then
                return string.format("%.2f", v)
            end
            return tostring(math.floor(v + 0.5))
        end

        slider:SetValue(value or min)
        valText:SetText(FormatValue(value or min))
        slider:SetScript("OnValueChanged", function(self, v)
            if step >= 1 then v = math.floor(v + 0.5) end
            valText:SetText(FormatValue(v))
            if onChange then onChange(v) end
        end)
        AttachTooltip(holder, label)
        AttachTooltip(slider, label)
        holder.slider = slider
        holder.labelText = labelText
        holder.valText = valText
        -- Convenience proxy methods so callers can use holder directly
        holder.SetMinMaxValues = function(self, a, b) slider:SetMinMaxValues(a, b) end
        holder.SetValue = function(self, v) slider:SetValue(v) end
        holder.GetValue = function(self) return slider:GetValue() end
        holder.SetValueStep = function(self, v) slider:SetValueStep(v) end
        holder.SetEnabled = function(self, v) slider:SetEnabled(v) end
        holder._muiSlider = slider
        return holder
    end

    --- b:Dropdown: Adds a dropdown menu control in a card row
    -- Uses Blizzard's UIDropDownMenuTemplate. The row is taller (72px) to
    -- accommodate the dropdown's extra internal padding.
    -- @param label (string) - Dropdown label text
    -- @param options (table) - Array of string option values
    -- @param current (string) - Currently selected option text
    -- @param onChange (function|nil) - Callback(selectedOption) on selection
    -- @return (Frame) - Holder frame with .dropdown, .labelText, SetValue, SetDisabled
    function b:Dropdown(label, options, current, onChange)
        local holder = CreateCardRow(72)

        local labelText = holder:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        labelText:SetPoint("TOPLEFT", 10, -8)
        labelText:SetPoint("TOPRIGHT", -10, -8)
        labelText:SetJustifyH("LEFT")
        labelText:SetText(label)
        labelText:SetTextColor(
            OVERLAY_MENU_STYLE.label[1],
            OVERLAY_MENU_STYLE.label[2],
            OVERLAY_MENU_STYLE.label[3]
        )

        local dropdown = CreateFrame("Frame", nil, holder, "UIDropDownMenuTemplate")
        dropdown:SetPoint("TOPLEFT", -4, -30)
        UIDropDownMenu_SetWidth(dropdown, 176)
        UIDropDownMenu_SetText(dropdown, current)

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

        AttachTooltip(holder, label)
        AttachTooltip(dropdown, label)
        holder.dropdown = dropdown
        holder.labelText = labelText
        holder.SetValue = function(self, v) UIDropDownMenu_SetText(dropdown, v) end
        holder.SetDisabled = function(self, isDisabled)
            if isDisabled then UIDropDownMenu_DisableDropDown(dropdown) else UIDropDownMenu_EnableDropDown(dropdown) end
        end
        return holder
    end

    --- b:Note: Adds a styled note/info text in a card row
    -- @param text (string) - Note text content
    -- @return (FontString) - The created FontString
    function b:Note(text)
        local row = CreateCardRow(38)
        local msg = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        msg:SetPoint("TOPLEFT", 10, -8)
        msg:SetPoint("BOTTOMRIGHT", -10, 8)
        msg:SetJustifyH("LEFT")
        msg:SetTextColor(
            OVERLAY_MENU_STYLE.note[1],
            OVERLAY_MENU_STYLE.note[2],
            OVERLAY_MENU_STYLE.note[3],
            OVERLAY_MENU_STYLE.note[4]
        )
        msg:SetText(text)
        return msg
    end

    --- b:Height: Returns the total content height consumed by all added controls
    -- @return (number) - Total height in pixels (positive value)
    function b:Height()
        return -self.y + 2
    end

    return b
end

-- ============================================================================
-- OVERLAY SETTINGS POPUP PANEL
-- A movable dialog frame that displays per-overlay settings controls, with a
-- header, scrollable body, "Open in Settings" button, and "Reset Position" button.
-- ============================================================================

--- CreateOverlaySettingsFrame: Builds the singleton overlay settings popup frame
-- Creates a DIALOG-strata draggable frame with: header (title + category badge +
-- close button), scrollable content area, footer with "Open in Settings" and
-- "Reset Position" buttons. Registered in UISpecialFrames so ESC closes it.
-- @return (Frame) - The created overlay settings frame
-- @calls M.StyleButton
local function CreateOverlaySettingsFrame()
    local HEADER_H = 58
    local FOOTER_H = 44
    local f = CreateFrame("Frame", "MidnightUI_OverlaySettings", UIParent, "BackdropTemplate")
    f:SetSize(380, 400)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("DIALOG")
    f:SetFrameLevel(50)
    -- Register so ESC closes this popup
    table.insert(UISpecialFrames, "MidnightUI_OverlaySettings")
    f:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8X8",
        edgeFile = "Interface\\Buttons\\WHITE8X8",
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 }
    })
    f:SetBackdropColor(0.04, 0.06, 0.09, 0.96)
    f:SetBackdropBorderColor(0.22, 0.30, 0.38, 0.92)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)

    -- Header background
    local header = f:CreateTexture(nil, "ARTWORK")
    header:SetTexture("Interface\\Buttons\\WHITE8X8")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_H)
    header:SetVertexColor(0.06, 0.10, 0.16, 0.96)

    -- Thin colored accent line at the very top of the header
    local headerAccent = f:CreateTexture(nil, "ARTWORK")
    headerAccent:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerAccent:SetPoint("TOPLEFT", 1, -1)
    headerAccent:SetPoint("TOPRIGHT", -1, -1)
    headerAccent:SetHeight(2)
    headerAccent:SetVertexColor(0.22, 0.54, 0.72, 0.60)
    f.headerAccent = headerAccent

    -- Separator line below header
    local headerLine = f:CreateTexture(nil, "BACKGROUND")
    headerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    headerLine:SetPoint("TOPLEFT", 12, -(HEADER_H + 1))
    headerLine:SetPoint("TOPRIGHT", -12, -(HEADER_H + 1))
    headerLine:SetHeight(1)
    headerLine:SetVertexColor(0.18, 0.22, 0.30, 0.72)

    -- Body inset background (darker area behind scroll content)
    local bodyInset = f:CreateTexture(nil, "BACKGROUND")
    bodyInset:SetTexture("Interface\\Buttons\\WHITE8X8")
    bodyInset:SetPoint("TOPLEFT", 12, -(HEADER_H + 8))
    bodyInset:SetPoint("BOTTOMRIGHT", -12, FOOTER_H + 4)
    bodyInset:SetVertexColor(0.03, 0.05, 0.08, 0.55)

    -- Close button (top-right "X")
    local close = CreateFrame("Button", nil, f, "BackdropTemplate")
    close:SetSize(24, 24)
    close:SetPoint("TOPRIGHT", -10, -10)
    close:SetText("X")
    close:SetNormalFontObject("GameFontNormalSmall")
    if M.StyleButton then M.StyleButton(close) end
    close:SetScript("OnClick", function() f:Hide() end)

    -- Title text (left-aligned in header)
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetPoint("RIGHT", close, "LEFT", -12, 0)
    title:SetJustifyH("LEFT")
    title:SetText("Overlay Settings")
    title:SetTextColor(0.94, 0.97, 1.00)
    f.title = title

    -- Category badge: small colored label below the title (e.g. "Unit Frame")
    local categoryBadge = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    categoryBadge:SetPoint("TOPLEFT", 14, -33)
    categoryBadge:SetJustifyH("LEFT")
    categoryBadge:SetText("")
    categoryBadge:SetTextColor(0.70, 0.77, 0.85)
    f.categoryBadge = categoryBadge

    -- Subtitle text (right of category badge)
    local subtitle = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    subtitle:SetPoint("LEFT", categoryBadge, "RIGHT", 8, 0)
    subtitle:SetPoint("RIGHT", close, "LEFT", -12, 0)
    subtitle:SetJustifyH("LEFT")
    subtitle:SetText("")
    subtitle:SetTextColor(0.55, 0.60, 0.68)
    f.subtitle = subtitle

    -- Scrollable content area
    local scroll = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 14, -(HEADER_H + 10))
    scroll:SetPoint("BOTTOMRIGHT", -30, FOOTER_H + 4)

    -- Keep scroll child width synced with scroll frame width
    scroll:HookScript("OnSizeChanged", function(self, w)
        if f.content and f.content.SetWidth and w and w > 0 then
            f.content:SetWidth(math.max(1, w - 8))
        end
    end)

    f.scroll = scroll

    -- Footer separator line
    local footerLine = f:CreateTexture(nil, "ARTWORK")
    footerLine:SetTexture("Interface\\Buttons\\WHITE8X8")
    footerLine:SetPoint("BOTTOMLEFT", 12, FOOTER_H)
    footerLine:SetPoint("BOTTOMRIGHT", -12, FOOTER_H)
    footerLine:SetHeight(1)
    footerLine:SetVertexColor(0.18, 0.22, 0.30, 0.60)

    -- "Open in Settings" button: closes overlay panel, exits unlock mode,
    -- and opens the Blizzard Settings UI to the appropriate MidnightUI page
    local btnOpenSettings = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnOpenSettings:SetSize(160, 28)
    btnOpenSettings:SetPoint("BOTTOMLEFT", 14, 10)
    btnOpenSettings:SetText("Open in Settings")
    if M.StyleButton then M.StyleButton(btnOpenSettings) end
    btnOpenSettings:SetScript("OnClick", function()
        if InCombatLockdown and InCombatLockdown() then
            if UIErrorsFrame then UIErrorsFrame:AddMessage("MidnightUI: Can't open settings in combat.", 1, 0.2, 0.2) end
            return
        end
        f:Hide()
        -- Lock overlays if currently in unlock mode
        if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false then
            MidnightUISettings.Messenger.locked = true
            if M.ApplyMessengerSettings then M.ApplyMessengerSettings() end
        end
        -- Hide Move HUD and grid if visible
        local moveHud = _G.MidnightUI_MoveHUD
        if moveHud and moveHud:IsShown() then moveHud:Hide() end
        local moveRestore = _G.MidnightUI_MoveHUDRestore
        if moveRestore and moveRestore:IsShown() then moveRestore:Hide() end
        if M.GridFrame and M.GridFrame:IsShown() then M.GridFrame:Hide() end
        -- Open Blizzard Settings to the correct MidnightUI category/page
        local settingsPage = f._muiSettingsPage
        if Settings and Settings.OpenToCategory and M.SettingsCategory then
            C_Timer.After(0.05, function()
                Settings.OpenToCategory(M.SettingsCategory.ID)
                if settingsPage and M.ShowPage then
                    C_Timer.After(0.05, function() M.ShowPage(settingsPage) end)
                end
            end)
        end
    end)
    f.btnOpenSettings = btnOpenSettings

    -- "Reset Position" button: clears saved position and re-applies default layout
    local btnResetPos = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    btnResetPos:SetSize(120, 28)
    btnResetPos:SetPoint("BOTTOMRIGHT", -14, 10)
    btnResetPos:SetText("Reset Position")
    if M.StyleButton then M.StyleButton(btnResetPos) end
    btnResetPos:SetScript("OnClick", function()
        local key = f._muiKey
        if key then
            local target = ResolveOverlayPositionTarget(key)
            if target and target.position then
                target.position = nil
                -- Re-apply the module's settings to restore default position
                local def = M.OverlaySettings[key]
                if def and def.applyFunc and type(M[def.applyFunc]) == "function" then
                    M[def.applyFunc]()
                end
            end
        end
    end)
    f.btnResetPos = btnResetPos

    return f
end

--- M.ShowOverlaySettings: Opens the overlay settings popup for a given overlay key
-- Creates the singleton frame on first call. Builds the settings controls using
-- the registered def.build function, sizes the panel to fit, and shows it.
-- @param key (string) - Overlay key (e.g. "PlayerFrame", "ActionBar1")
-- @calls CreateOverlaySettingsFrame (once), M.SafeCall for def.build
function M.ShowOverlaySettings(key)
    local def = M.OverlaySettings[key]
    local f = _G.MidnightUI_OverlaySettingsFrame
    if not f then
        f = CreateOverlaySettingsFrame()
        _G.MidnightUI_OverlaySettingsFrame = f
    end
    f._muiKey = key

    -- Destroy previous content frame to rebuild fresh
    if f.content then
        f.content:Hide()
        f.content:SetParent(nil)
        f.content = nil
    end

    -- Create new scroll child content frame
    local content = CreateFrame("Frame", nil, f.scroll)
    content:SetPoint("TOPLEFT", 0, 0)
    content:SetWidth(math.max(1, (f.scroll:GetWidth() or 400) - 8))
    content:SetHeight(200)
    f.scroll:SetScrollChild(content)
    f.content = content

    -- Set panel title
    if def and def.title then
        f.title:SetText(def.title)
    else
        f.title:SetText("Overlay Settings")
    end

    -- Set category badge color and label, tint header accent to match
    local category = def and def.category
    f._muiSettingsPage = def and def.settingsPage
    if f.categoryBadge then
        if category and OVERLAY_CATEGORY_COLORS[category] then
            local cc = OVERLAY_CATEGORY_COLORS[category]
            local label = OVERLAY_CATEGORY_LABELS[category] or category
            f.categoryBadge:SetText(label)
            f.categoryBadge:SetTextColor(cc[1], cc[2], cc[3], 0.9)
            if f.headerAccent then
                f.headerAccent:SetVertexColor(cc[1], cc[2], cc[3], 0.50)
            end
        else
            f.categoryBadge:SetText("")
        end
    end
    if f.subtitle then
        f.subtitle:SetText("")
    end

    -- Build the settings controls using the registered builder function
    if def and type(def.build) == "function" then
        local ok, height = M.SafeCall("OverlaySettings:" .. SafeToString(key), def.build, content, key)
        if ok and type(height) == "number" and height > 0 then
            content:SetHeight(height)
            -- Size panel to fit content, clamped between 286-760px
            local desired = math.max(286, math.min(760, height + 122))
            f:SetHeight(desired)
        end
    else
        local msg = content:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        msg:SetPoint("TOPLEFT", 0, 0)
        msg:SetText("No Settings Available")
        msg:SetTextColor(0.9, 0.9, 0.9)
        f:SetHeight(286)
    end

    -- Reset scroll position to top
    if f.scroll and f.scroll.SetVerticalScroll then
        f.scroll:SetVerticalScroll(0)
    end

    f:Show()
end

-- ============================================================================
-- GLOBAL EXPORTS
-- Expose key functions to _G for cross-module access. Other MidnightUI files
-- call these globals rather than requiring a direct reference to M.
-- ============================================================================
_G.MidnightUI_RegisterOverlaySettings = function(key, def) M.RegisterOverlaySettings(key, def) end
_G.MidnightUI_ShowOverlaySettings = function(key) M.ShowOverlaySettings(key) end
_G.MidnightUI_AttachOverlaySettings = function(overlay, key) AttachOverlayRightClick(overlay, key) end
_G.MidnightUI_AttachOverlayTooltip = function(control, label) AttachTooltip(control, label) end
_G.MidnightUI_CreateOverlayBuilder = function(content, opts) return CreateOverlayBuilder(content, opts) end
_G.MidnightUI_GetOverlayHandle = function(key) return M.OverlayHandles[key] end
_G.MidnightUI_StyleOverlay = function(overlay, labelText, labelFont, category) StyleOverlay(overlay, labelText, labelFont, category) end
_G.MidnightUI_SaveOverlayPosition = function(frame, target) SaveOverlayPosition(frame, target) end
_G.MidnightUI_ApplyOverlayPosition = function(frame, position) return ApplyOverlayPosition(frame, position) end
_G.MidnightUI_SaveRelativeOverlayPosition = function(frame, ownerFrame, target) SaveRelativeOverlayPosition(frame, ownerFrame, target) end
_G.MidnightUI_ApplyRelativeOverlayPosition = function(frame, ownerFrame, position) return ApplyRelativeOverlayPosition(frame, ownerFrame, position) end
_G.MidnightUI_ScaleFromPercent = function(value) return ScaleFromPercent(value) end

-- ============================================================================
-- MAIN EVENT HANDLER
-- Central OnEvent handler for Core.lua's event frame. Manages addon lifecycle:
--   ADDON_LOADED "MidnightUI" → settings init, debug setup, module init
--   PLAYER_LOGIN → module init, welcome screen
--   ADDON_LOADED "Blizzard_AchievementUI" → register AchievementFrame for ESC close
--   PLAYER_ENTERING_WORLD → module init
--   PLAYER_REGEN_ENABLED → flush combat-deferred queue
-- ============================================================================

local function OnEvent(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == "MidnightUI" then
        M.EnsureSettings()
        -- Replace Bootstrap.lua's stub with the real debug logger
        if not _G.MidnightUI_Debug then
            _G.MidnightUI_Debug = function(...) M.Debug(...) end
        end
        -- Install _G.MidnightUI_LogDebug as an alias with chat fallback
        if not _G.MidnightUI_LogDebug then
            _G.MidnightUI_LogDebug = function(...)
                if _G.MidnightUI_Debug then
                    return _G.MidnightUI_Debug(...)
                end
                if _G.DEFAULT_CHAT_FRAME then
                    local parts = {}
                    for i = 1, select("#", ...) do
                        parts[#parts + 1] = tostring(select(i, ...))
                    end
                    _G.DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffMidnightUI:|r " .. table.concat(parts, " "))
                end
            end
        end
        -- Drain any messages queued by Bootstrap.lua before Core loaded
        M.FlushDebugQueue()
        M.InitModules("ADDON_LOADED")
        return
    end
    if event == "PLAYER_LOGIN" then
        M.InitModules("PLAYER_LOGIN")
        -- Show welcome screen if available, otherwise try What's New
        if _G.MidnightUI_TryShowWelcome then
            _G.MidnightUI_TryShowWelcome()
        end
        -- For returning users (already seen welcome), show What's New on version update
        if C_Timer and C_Timer.After then
            C_Timer.After(2.0, function()
                if _G.MidnightUI_TryShowWhatsNew then
                    pcall(_G.MidnightUI_TryShowWhatsNew)
                end
            end)
        end
        -- Handle pending forced welcome screen (set by settings reset)
        if _G.MidnightUISettings and _G.MidnightUISettings.PendingResetForceWelcome then
            if _G.MidnightUI_ShowWelcome then
                local ok, err = pcall(_G.MidnightUI_ShowWelcome, true)
                if ok then
                    _G.MidnightUISettings.PendingResetForceWelcome = nil
                else
                    -- Log failure and retry after 1 second
                    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource and _G.MidnightUI_Diagnostics.IsEnabled and _G.MidnightUI_Diagnostics.IsEnabled() then
                        _G.MidnightUI_Diagnostics.LogDebugSource("Core", "PLAYER_LOGIN: force Welcome failed: " .. tostring(err))
                    elseif _G.MidnightUI_Debug then
                        _G.MidnightUI_Debug("[Core] PLAYER_LOGIN: force Welcome failed: " .. tostring(err))
                    end
                    if C_Timer and C_Timer.After then
                        C_Timer.After(1.0, function()
                            if _G.MidnightUISettings and _G.MidnightUISettings.PendingResetForceWelcome and _G.MidnightUI_ShowWelcome then
                                local ok2 = pcall(_G.MidnightUI_ShowWelcome, true)
                                if ok2 then
                                    _G.MidnightUISettings.PendingResetForceWelcome = nil
                                end
                            end
                        end)
                    end
                end
            else
                -- MidnightUI_ShowWelcome not yet available; retry after 1 second
                if C_Timer and C_Timer.After then
                    C_Timer.After(1.0, function()
                        if _G.MidnightUISettings and _G.MidnightUISettings.PendingResetForceWelcome and _G.MidnightUI_ShowWelcome then
                            local ok2 = pcall(_G.MidnightUI_ShowWelcome, true)
                            if ok2 then
                                _G.MidnightUISettings.PendingResetForceWelcome = nil
                            end
                        end
                    end)
                end
            end
        end
        return
    end
    -- Register Blizzard's AchievementFrame in UISpecialFrames so ESC closes it
    if event == "ADDON_LOADED" and arg1 == "Blizzard_AchievementUI" then
        local af = _G.AchievementFrame
        if af and af.GetName then
            local name = af:GetName()
            if name then
                local found = false
                for _, n in ipairs(UISpecialFrames) do
                    if n == name then found = true; break end
                end
                if not found then
                    table.insert(UISpecialFrames, name)
                end
            end
        end
    end
    if event == "PLAYER_ENTERING_WORLD" then
        M.InitModules("PLAYER_ENTERING_WORLD")
        return
    end
    -- Combat ended: flush any deferred function calls
    if event == "PLAYER_REGEN_ENABLED" then
        M.FlushDeferred()
    end
end

-- Register and wire up the main event frame
local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_REGEN_ENABLED")
f:SetScript("OnEvent", OnEvent)

-- ============================================================================
-- BLIZZARD POPUP CLAMP & HELPTIP SUPPRESSION
-- Keeps Blizzard tutorial pointers and HelpTips on-screen (or suppressed).
-- Tutorial pointers can anchor to default UI elements that MidnightUI has
-- repositioned or hidden, causing them to render off-screen. This section
-- hooks SetPoint/OnShow to clamp them back into the visible area.
-- HelpTips (talent notifications, feature callouts) are fully suppressed
-- because they target default UI layout that no longer applies.
-- ============================================================================
do
    local PADDING = 20

    --- ClampFrameOnScreen: Moves a frame back on-screen if any edge exceeds bounds
    -- @param frame (Frame) - The frame to clamp
    local function ClampFrameOnScreen(frame)
        if not frame or not frame.GetCenter then return end
        local cx, cy = frame:GetCenter()
        if not cx or not cy then return end
        local w, h = frame:GetSize()
        if not w or not h or w == 0 or h == 0 then return end
        local sw = GetScreenWidth()
        local sh = GetScreenHeight()
        if not sw or not sh or sw == 0 or sh == 0 then return end
        local s = frame:GetEffectiveScale()
        if not s or s == 0 then s = 1 end
        local halfW = (w / 2)
        local halfH = (h / 2)
        local needsMove = false
        local newX, newY = cx, cy
        if (cx - halfW) < PADDING then newX = halfW + PADDING; needsMove = true end
        if (cx + halfW) > (sw / s - PADDING) then newX = sw / s - halfW - PADDING; needsMove = true end
        if (cy - halfH) < PADDING then newY = halfH + PADDING; needsMove = true end
        if (cy + halfH) > (sh / s - PADDING) then newY = sh / s - halfH - PADDING; needsMove = true end
        if needsMove then
            frame:ClearAllPoints()
            frame:SetPoint("CENTER", UIParent, "BOTTOMLEFT", newX, newY)
        end
    end

    --- HookFrameClamp: Installs SetPoint and OnShow hooks to auto-clamp a frame
    -- Uses C_Timer.After(0) to defer clamping until after Blizzard's own
    -- positioning logic completes. Uses _muiClamping flag to prevent recursion.
    -- @param frame (Frame) - Frame to hook
    -- @note Idempotent — skips if frame._muiClampHooked is set
    local function HookFrameClamp(frame)
        if not frame or frame._muiClampHooked then return end
        frame._muiClampHooked = true
        hooksecurefunc(frame, "SetPoint", function(self)
            if self._muiClamping then return end
            self._muiClamping = true
            C_Timer.After(0, function()
                ClampFrameOnScreen(self)
                self._muiClamping = false
            end)
        end)
        frame:HookScript("OnShow", function(self)
            if self._muiClamping then return end
            self._muiClamping = true
            C_Timer.After(0, function()
                ClampFrameOnScreen(self)
                self._muiClamping = false
            end)
        end)
    end

    -- HelpTip suppression: these are Blizzard's tutorial prompts (talent notifications,
    -- feature callouts, etc.) designed for the default UI. With a custom UI they anchor
    -- to repositioned/hidden elements and end up covering action bars or pointing at nothing.
    local helpTipHooked = false

    --- HideAllActiveHelpTips: Hides all currently visible HelpTip frames
    local function HideAllActiveHelpTips()
        if not HelpTip or not HelpTip.framePool then return end
        for frame in HelpTip.framePool:EnumerateActive() do
            if frame and frame:IsShown() then
                frame:Hide()
            end
        end
    end

    --- HookHelpTipSystem: Hooks HelpTip.Show to immediately hide any new HelpTips
    -- Idempotent — only hooks once via helpTipHooked flag.
    local function HookHelpTipSystem()
        if helpTipHooked then return end
        if not HelpTip or type(HelpTip.Show) ~= "function" then return end
        helpTipHooked = true
        hooksecurefunc(HelpTip, "Show", function(self)
            if not self.framePool then return end
            for frame in self.framePool:EnumerateActive() do
                if frame and frame:IsShown() then
                    frame:Hide()
                end
            end
        end)
        -- Hide any HelpTips that were shown before our hook was installed
        HideAllActiveHelpTips()
    end

    -- Hook immediately if HelpTip is already available at load time
    HookHelpTipSystem()

    -- Event watcher: hooks tutorial pointer frames and retries HelpTip hook
    local clampWatcher = CreateFrame("Frame")
    clampWatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
    clampWatcher:RegisterEvent("ADDON_LOADED")
    clampWatcher:SetScript("OnEvent", function(self, event)
        -- Hook TutorialPointerFrame_1 through _10 for on-screen clamping
        for i = 1, 10 do
            local name = "TutorialPointerFrame_" .. i
            local ptr = _G[name]
            if ptr then HookFrameClamp(ptr) end
        end
        -- Retry HelpTip hook in case it was not available at initial load time
        HookHelpTipSystem()
        -- Sweep any HelpTips that slipped through between hooks
        HideAllActiveHelpTips()
    end)
end

-- =========================================================================
--  SETTINGS DUMP: /muidump
--  Serializes the full MidnightUISettings table to the Diagnostics console
--  so all positions, scales, widths, heights, enabled states, icons per row,
--  visibility toggles, and every other setting can be captured and used as
--  new defaults.
-- =========================================================================
do
    -- Stable key-sorted serializer — outputs valid Lua table literals.
    local function SerializeValue(v, indent)
        local t = type(v)
        if t == "string" then
            return string.format("%q", v)
        elseif t == "number" then
            -- Preserve exact float precision
            if v == math.floor(v) then
                return tostring(v)
            else
                return string.format("%.8g", v)
            end
        elseif t == "boolean" then
            return v and "true" or "false"
        elseif t == "nil" then
            return "nil"
        elseif t == "table" then
            local pad = string.rep("  ", indent)
            local padInner = string.rep("  ", indent + 1)
            -- Check if it's a simple array (consecutive integer keys 1..n)
            local n = #v
            local isArray = n > 0
            if isArray then
                for i = 1, n do
                    if v[i] == nil then isArray = false; break end
                end
                -- Also check for non-integer keys
                local count = 0
                for _ in pairs(v) do count = count + 1 end
                if count ~= n then isArray = false end
            end
            if isArray then
                local parts = {}
                for i = 1, n do
                    parts[i] = SerializeValue(v[i], indent + 1)
                end
                local oneLine = "{ " .. table.concat(parts, ", ") .. " }"
                if #oneLine < 100 then return oneLine end
                -- Multi-line for long arrays
                local lines = { "{" }
                for i = 1, n do
                    lines[#lines + 1] = padInner .. parts[i] .. (i < n and "," or "")
                end
                lines[#lines + 1] = pad .. "}"
                return table.concat(lines, "\n")
            else
                -- Dict table: sort keys for stable output
                local keys = {}
                for k in pairs(v) do keys[#keys + 1] = k end
                table.sort(keys, function(a, b)
                    if type(a) == type(b) then return tostring(a) < tostring(b) end
                    return type(a) < type(b)
                end)
                if #keys == 0 then return "{}" end
                local lines = { "{" }
                for idx, k in ipairs(keys) do
                    local kStr
                    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                        kStr = k
                    else
                        kStr = "[" .. SerializeValue(k, 0) .. "]"
                    end
                    local comma = idx < #keys and "," or ""
                    local valStr = SerializeValue(v[k], indent + 1)
                    lines[#lines + 1] = padInner .. kStr .. " = " .. valStr .. comma
                end
                lines[#lines + 1] = pad .. "}"
                return table.concat(lines, "\n")
            end
        end
        return "nil --[[ unsupported type: " .. t .. " ]]"
    end

    local function DumpAllSettings()
        if not MidnightUISettings then
            if DEFAULT_CHAT_FRAME then
                DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r No settings to dump — MidnightUISettings is nil.", 1, 0.4, 0.4)
            end
            return
        end

        -- Sections to dump (matches DEFAULTS structure in Settings.lua)
        local sections = {
            "PlayerFrame", "TargetFrame", "FocusFrame", "PetFrame",
            "PartyFrames", "RaidFrames", "MainTankFrames",
            "ActionBars", "PetBar", "StanceBar",
            "CastBars", "Messenger", "ConsumableBars",
            "Minimap", "Nameplates", "Combat",
            "General", "Inventory", "XPBar", "RepBar",
            "InterfaceMenu", "GlobalStyle",
        }

        local lines = {}
        local function L(s) lines[#lines + 1] = s end

        L("@@MIDNIGHTUI_SETTINGS_DUMP@@")
        L("")

        for _, section in ipairs(sections) do
            local val = MidnightUISettings[section]
            if val ~= nil then
                L("== " .. section .. " ==")
                L(section .. " = " .. SerializeValue(val, 0))
                L("")
            end
        end

        L("@@END_SETTINGS_DUMP@@")

        local fullText = table.concat(lines, "\n")

        -- Send to diagnostics console
        if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogDebugSource then
            _G.MidnightUI_Diagnostics.LogDebugSource("SettingsDump", fullText)
        end

        -- Chat confirmation
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Full settings dump sent to Diagnostics Console (" .. #lines .. " lines). Open with /muibugs.", 0.5, 1.0, 0.8)
        end
    end

    SlashCmdList["MIDNIGHTUI_DUMPPOS"] = DumpAllSettings
    SLASH_MIDNIGHTUI_DUMPPOS1 = "/muidumppositions"
    SLASH_MIDNIGHTUI_DUMPPOS2 = "/muidump"
end
