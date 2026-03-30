--------------------------------------------------------------------------------
-- InterfaceMenu.lua | MidnightUI
-- PURPOSE: Replaces the default WoW micro-menu bar with a single Game Menu
--          button and a smooth-sliding drawer of interface shortcut buttons.
-- DEPENDS ON: MidnightUI_Core (GetClassColorTable), MidnightUI_Settings
--             (overlay system, lock/unlock), MidnightUI_StyleOverlay,
--             MidnightUI_RegisterOverlaySettings, MidnightUI_CreateOverlayBuilder
-- EXPORTS: MidnightUI_ApplyInterfaceMenuSettings (global function),
--          MidnightUI_SetInterfaceMenuLocked (global function),
--          MidnightUI_InterfaceMenuDock (global frame reference)
-- ARCHITECTURE: Self-contained module. Creates a SecureActionButton dock that
--               opens the GameMenuFrame via macro (taint-safe). On hover, a
--               clipped drawer slides out with icon buttons for Character,
--               Spellbook, Talents, Collections, etc. Position and scale are
--               persisted in MidnightUISettings.InterfaceMenu. The module also
--               hides the default MicroMenuContainer and re-parents the
--               QueueStatusButton so it remains visible and clickable.
--------------------------------------------------------------------------------

local addonName, ns = ...

-- ============================================================================
-- CONFIGURATION
-- Class color used for accent highlights throughout the dock and drawer.
-- ============================================================================

--- C: Module-local config table.
-- C.classColor holds the player's RGBA class color for border/accent tinting.
local C = {
    classColor = (_G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable and _G.MidnightUI_Core.GetClassColorTable("player"))
        or C_ClassColor.GetClassColor(select(2, UnitClass("player"))),
}

-- ============================================================================
-- MODULE STATE
-- ============================================================================

--- MidnightInterface: Hidden event frame that drives PLAYER_LOGIN and
--  PLAYER_REGEN_ENABLED to build the dock and apply deferred settings.
local MidnightInterface = CreateFrame("Frame", "MidnightInterface", UIParent)
MidnightInterface:RegisterEvent("PLAYER_LOGIN")

--- interfaceDockRef: Cached reference to the dock button frame after creation.
local interfaceDockRef = nil

--- pendingInterfaceMenuApply: When true, ApplyInterfaceMenuSettings was called
--  during combat lockdown and must re-run on PLAYER_REGEN_ENABLED.
local pendingInterfaceMenuApply = false

-- ============================================================================
-- UTILITY FUNCTIONS
-- ============================================================================

--- ClampNumber: Safely clamps a numeric value between min and max.
-- @param value (any) - Input to clamp (tonumber is applied)
-- @param minValue (number) - Lower bound
-- @param maxValue (number) - Upper bound
-- @param fallback (number) - Returned when value is not a valid number
-- @return (number) - Clamped result or fallback
local function ClampNumber(value, minValue, maxValue, fallback)
    local n = tonumber(value)
    if not n then return fallback end
    if n < minValue then return minValue end
    if n > maxValue then return maxValue end
    return n
end

--- EnsureInterfaceMenuSettings: Lazily initializes MidnightUISettings.InterfaceMenu
--  with default values for enabled state and scale.
-- @return (table) - Reference to MidnightUISettings.InterfaceMenu
-- @note MidnightUISettings.InterfaceMenu shape:
--   {
--     enabled  = (bool)   whether the dock is shown (default true),
--     scale    = (number) percentage scale 50-200 (default 100),
--     position = (table|nil) { point, relativePoint, xOfs, yOfs } saved anchor,
--   }
local function EnsureInterfaceMenuSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.InterfaceMenu then MidnightUISettings.InterfaceMenu = {} end
    local s = MidnightUISettings.InterfaceMenu
    if s.enabled == nil then s.enabled = true end
    if s.scale == nil then s.scale = 100 end
    return s
end

-- ============================================================================
-- FRAME VISIBILITY HELPERS
-- Used by the Housing button fallback to toggle frames without taint.
-- ============================================================================

--- CanToggleFrameDirectly: Checks whether a value is a frame with Show/Hide API.
-- @param frame (any) - Value to test
-- @return (bool) - true if frame can be toggled
local function CanToggleFrameDirectly(frame)
    return type(frame) == "table"
        and type(frame.IsShown) == "function"
        and (type(frame.SetShown) == "function"
            or (type(frame.Show) == "function" and type(frame.Hide) == "function"))
end

--- SafeToggleFrameVisibility: Toggles a frame's shown state via pcall to
--  absorb taint or protected-frame errors.
-- @param frame (table) - WoW frame to toggle
-- @return (bool) - true if the toggle succeeded
local function SafeToggleFrameVisibility(frame)
    if not CanToggleFrameDirectly(frame) then
        return false
    end

    local shown = frame:IsShown() == true
    if type(frame.SetShown) == "function" then
        local ok = pcall(frame.SetShown, frame, not shown)
        if ok then return true end
    end

    if shown and type(frame.Hide) == "function" then
        local ok = pcall(frame.Hide, frame)
        if ok then return true end
    elseif not shown and type(frame.Show) == "function" then
        local ok = pcall(frame.Show, frame)
        if ok then return true end
    end

    return false
end

-- ============================================================================
-- POSITION PERSISTENCE
-- Saves/restores the dock anchor point relative to UIParent, accounting for
-- scale so the position stays correct when scale changes.
-- ============================================================================

--- SaveInterfaceMenuPosition: Persists the dock frame's current anchor to
--  MidnightUISettings.InterfaceMenu.position, dividing offsets by scale
--  so they remain stable across scale changes.
-- @param dockFrame (Frame) - The dock button frame
-- @calledby OnDragStop scripts, overlay drag handlers
local function SaveInterfaceMenuPosition(dockFrame)
    local s = EnsureInterfaceMenuSettings()
    local point, _, relativePoint, xOfs, yOfs = dockFrame:GetPoint()
    local scale = dockFrame:GetScale()
    if not scale or scale == 0 then scale = 1.0 end
    s.position = {
        point or "BOTTOMRIGHT",
        relativePoint or "BOTTOMRIGHT",
        (tonumber(xOfs) or 0) / scale,
        (tonumber(yOfs) or 0) / scale,
    }
end

-- ============================================================================
-- DRAG OVERLAY
-- A transparent overlay frame that enables dragging the dock when unlocked.
-- Uses MidnightUI's shared overlay/settings infrastructure for consistency
-- with other movable elements.
-- ============================================================================

--- EnsureInterfaceMenuOverlay: Creates (or returns existing) drag overlay for
--  the dock, with a "GAME MENU" label and MidnightUI overlay styling.
-- @param dockFrame (Frame) - The dock button frame to overlay
-- @return (Frame) - The overlay frame (also cached as dockFrame.dragOverlay)
-- @calls MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings
local function EnsureInterfaceMenuOverlay(dockFrame)
    if dockFrame.dragOverlay then return dockFrame.dragOverlay end
    local overlay = CreateFrame("Frame", nil, dockFrame, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("DIALOG")
    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
    -- Cross-module call: apply shared MidnightUI overlay styling
    if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "world") end

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText("GAME MENU")
    label:SetTextColor(1, 1, 1)

    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function(self)
        if InCombatLockdown and InCombatLockdown() then return end
        dockFrame:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function(self)
        dockFrame:StopMovingOrSizing()
        SaveInterfaceMenuPosition(dockFrame)
    end)

    -- Cross-module call: attach right-click overlay settings panel
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "InterfaceMenu")
    end
    dockFrame.dragOverlay = overlay
    return overlay
end

-- ============================================================================
-- SETTINGS APPLICATION
-- Reads persisted settings and applies scale, position, and visibility to
-- the dock frame. Defers to PLAYER_REGEN_ENABLED if called during combat.
-- ============================================================================

--- ApplyInterfaceMenuSettings: Applies scale, position, and visibility from
--  MidnightUISettings.InterfaceMenu to the dock frame.
-- @calledby PLAYER_LOGIN, PLAYER_REGEN_ENABLED, overlay builder callbacks
-- @note Defers execution when InCombatLockdown() is true by registering
--       PLAYER_REGEN_ENABLED. Position offsets are multiplied by effective
--       scale to counteract SetPoint's scale-relative behavior.
local function ApplyInterfaceMenuSettings()
    local dockFrame = interfaceDockRef or _G.MidnightUI_InterfaceMenuDock
    if not dockFrame then return end
    local s = EnsureInterfaceMenuSettings()

    if InCombatLockdown and InCombatLockdown() then
        pendingInterfaceMenuApply = true
        MidnightInterface:RegisterEvent("PLAYER_REGEN_ENABLED")
        return
    end

    pendingInterfaceMenuApply = false
    MidnightInterface:UnregisterEvent("PLAYER_REGEN_ENABLED")

    local scalePct = ClampNumber(s.scale, 50, 200, 100)
    dockFrame:SetScale(scalePct / 100)

    if s.position and type(s.position) == "table" and #s.position >= 4 then
        dockFrame:ClearAllPoints()
        local effScale = dockFrame:GetScale()
        if not effScale or effScale == 0 then effScale = 1.0 end
        dockFrame:SetPoint(
            s.position[1],
            UIParent,
            s.position[2],
            (tonumber(s.position[3]) or 0) * effScale,
            (tonumber(s.position[4]) or 0) * effScale
        )
    end

    if s.enabled == false then
        dockFrame:Hide()
    else
        dockFrame:Show()
    end

    -- Cross-module call: sync lock state with Messenger's global lock toggle
    if _G.MidnightUI_SetInterfaceMenuLocked and MidnightUISettings and MidnightUISettings.Messenger then
        _G.MidnightUI_SetInterfaceMenuLocked(MidnightUISettings.Messenger.locked ~= false)
    end
end
_G.MidnightUI_ApplyInterfaceMenuSettings = ApplyInterfaceMenuSettings

--- MidnightUI_SetInterfaceMenuLocked: Shows or hides the drag overlay based
--  on lock state and enabled state.
-- @param locked (bool) - true hides the overlay, false shows it
-- @calledby Settings lock toggle, ApplyInterfaceMenuSettings
function _G.MidnightUI_SetInterfaceMenuLocked(locked)
    local dockFrame = interfaceDockRef or _G.MidnightUI_InterfaceMenuDock
    if not dockFrame then return end
    local s = EnsureInterfaceMenuSettings()
    local overlay = EnsureInterfaceMenuOverlay(dockFrame)
    if locked or s.enabled == false then
        overlay:Hide()
    else
        overlay:Show()
    end
end

-- ============================================================================
-- INTERFACE BUTTON DEFINITIONS
-- Each entry defines one icon button inside the sliding drawer. The drawer
-- renders these left-to-right from the dock button.
-- ============================================================================

--- INTERFACE_BUTTONS shape:
-- {
--   icon    = (number|string) texture ID or path; "DynamicHousing" is special-cased,
--   tooltip = (string) tooltip text shown on hover,
--   onClick = (function) called when the button is clicked,
-- }
local INTERFACE_BUTTONS = {
    {
        icon = 132146,
        tooltip = "Character",
        onClick = function() ToggleCharacter("PaperDollFrame") end,
    },
    {
        icon = 4620678,
        tooltip = "Professions",
        onClick = function() ToggleProfessionsBook() end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_Coin_01",
        tooltip = "Currency",
        onClick = function() ToggleCharacter("TokenFrame") end,
    },
    {
        icon = "Interface\\Icons\\Achievement_Quests_Completed_08",
        tooltip = "Achievements",
        onClick = function() ToggleAchievementFrame() end,
    },
    {
        icon = "Interface\\Icons\\ClassIcon_Warrior",
        tooltip = "Talents",
        onClick = function()
            if PlayerSpellsUtil and PlayerSpellsUtil.ToggleClassTalentFrame then
                PlayerSpellsUtil.ToggleClassTalentFrame()
            else
                if not ClassTalentFrame then C_AddOns.LoadAddOn("Blizzard_ClassTalentUI") end
                if ClassTalentFrame then ToggleFrame(ClassTalentFrame) end
            end
        end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_Book_07",
        tooltip = "Spellbook & Abilities",
        onClick = function()
            if PlayerSpellsUtil and PlayerSpellsUtil.ToggleSpellBookFrame then
                PlayerSpellsUtil.ToggleSpellBookFrame()
            else
                TogglePlayerSpellsFrame()
            end
        end,
    },
    {
        icon = "Interface\\Icons\\Achievement_GuildPerk_MountUp",
        tooltip = "Warband Collections",
        onClick = function() ToggleCollectionsJournal() end,
    },
    {
        icon = "Interface\\Icons\\Achievement_General_StayClassy",
        tooltip = "Guild & Communities",
        onClick = function() ToggleGuildFrame() end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_Map_01",
        tooltip = "Adventure Guide",
        onClick = function() ToggleEncounterJournal() end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_GroupLooking",
        tooltip = "Group Finder",
        onClick = function()
            if _G.MidnightUI_GroupFinder_Toggle then
                _G.MidnightUI_GroupFinder_Toggle()
            else
                PVEFrame_ToggleFrame()
            end
        end,
    },
    {
        -- Special case: icon texture is pulled dynamically from the Blizzard
        -- HousingMicroButton at runtime via OnShow to stay current with patches.
        icon = "DynamicHousing",
        tooltip = "Housing Dashboard",
        onClick = function()
            -- Load-on-demand: ensure Blizzard_HousingUI is available
            if not HousingDashboardFrame then
                C_AddOns.LoadAddOn("Blizzard_HousingUI")
            end

            -- Prefer secure micro button path to avoid taint
            if HousingMicroButton and type(HousingMicroButton.Click) == "function" then
                HousingMicroButton:Click()
                return
            end

            -- Fallback: direct toggle when the micro button is unavailable
            SafeToggleFrameVisibility(HousingDashboardFrame)
        end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_Book_08",
        tooltip = "Encounter Journal",
        onClick = function() ToggleEncounterJournal() end,
    },
    {
        icon = "Interface\\Icons\\INV_Misc_QuestionMark",
        tooltip = "Help",
        onClick = function() ToggleHelpFrame() end,
    },
}

-- ============================================================================
-- DOCK CREATION
-- Builds the main Game Menu button (SecureActionButton), the sliding drawer,
-- all interface icon buttons, and the hover-driven slide animation.
-- ============================================================================

--- CreateInterfaceDock: Constructs the entire dock UI: main button, drawer
--  container, per-button icons, hover animation, and tooltip handling.
-- @return (Frame) - The dock button frame (also stored as interfaceDockRef
--         and MidnightUI_InterfaceMenuDock global)
-- @calls ApplyInterfaceMenuSettings
-- @calledby OnEvent PLAYER_LOGIN handler
-- @note The main button uses SecureActionButtonTemplate with a macro attribute
--       to toggle GameMenuFrame, which bypasses Blizzard taint restrictions.
--       The drawer uses SetClipsChildren(true) and an OnUpdate lerp to animate
--       width and alpha for a smooth slide effect. A 0.2s hover-off delay
--       prevents the "stuck open" flicker bug.
local function CreateInterfaceDock()
    if interfaceDockRef then return interfaceDockRef end

    -- Main Game Menu button: 46x46 SecureActionButton at bottom-right
    local dockFrame = CreateFrame("Button", "MidnightInterfaceDock", UIParent, "SecureActionButtonTemplate")
    dockFrame:SetSize(46, 46)
    dockFrame:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 95)
    dockFrame:SetFrameStrata("HIGH")
    dockFrame:SetMovable(true)
    dockFrame:EnableMouse(true)
    dockFrame:RegisterForDrag("LeftButton")
    dockFrame:RegisterForClicks("AnyDown")

    dockFrame:SetScript("OnDragStart", function(self)
        if InCombatLockdown and InCombatLockdown() then return end
        self:StartMoving()
    end)
    dockFrame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveInterfaceMenuPosition(self)
    end)

    -- Secure macro attribute: toggles GameMenuFrame without spreading taint
    dockFrame:SetAttribute("type1", "macro")
    dockFrame:SetAttribute("macrotext1", "/run if GameMenuFrame then GameMenuFrame:SetShown(not GameMenuFrame:IsShown()) end")

    -- Background panel with dark backdrop and subtle border
    local bgFrame = CreateFrame("Frame", nil, dockFrame, "BackdropTemplate")
    bgFrame:SetAllPoints()
    bgFrame:SetFrameLevel(dockFrame:GetFrameLevel())
    bgFrame:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 2,
        insets = { left = 2, right = 2, top = 2, bottom = 2 }
    })
    bgFrame:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    bgFrame:SetBackdropBorderColor(0.18, 0.18, 0.22, 1)
    dockFrame.bgFrame = bgFrame

    -- WoW Store icon serves as the main dock icon
    local icon = dockFrame:CreateTexture(nil, "OVERLAY")
    icon:SetSize(36, 36)
    icon:SetPoint("CENTER")
    icon:SetTexture("Interface\\Icons\\WoW_Store")
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dockFrame.icon = icon

    local highlight = dockFrame:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", 2, -2)
    highlight:SetPoint("BOTTOMRIGHT", -2, 2)
    highlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    highlight:SetVertexColor(1, 1, 1, 0.08)
    highlight:SetBlendMode("ADD")

    -- -----------------------------------------------------------------------
    -- SLIDING DRAWER
    -- Anchored to the left of the dock button. Uses ClipsChildren to mask
    -- overflow during width animation. Starts hidden (width=1, alpha=0).
    -- -----------------------------------------------------------------------
    local drawer = CreateFrame("Frame", "MidnightInterfaceDrawer", dockFrame, "BackdropTemplate")
    drawer:SetPoint("RIGHT", dockFrame, "LEFT", 6, 0)
    drawer:SetSize(1, 44)
    drawer:SetFrameLevel(math.max(dockFrame:GetFrameLevel(), 50))
    drawer:SetClipsChildren(true)

    drawer:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    drawer:SetBackdropColor(0.06, 0.06, 0.08, 0.92)
    drawer:SetBackdropBorderColor(0.15, 0.15, 0.18, 1)
    drawer:SetAlpha(0)

    -- Top highlight line inside drawer
    local drawerHighlight = drawer:CreateTexture(nil, "ARTWORK")
    drawerHighlight:SetHeight(1)
    drawerHighlight:SetPoint("TOPLEFT", 1, -1)
    drawerHighlight:SetPoint("TOPRIGHT", -1, -1)
    drawerHighlight:SetTexture("Interface\\Buttons\\WHITE8x8")
    drawerHighlight:SetVertexColor(0.25, 0.25, 0.3, 0.3)

    -- Class-colored accent line at bottom of drawer
    local drawerAccent = drawer:CreateTexture(nil, "OVERLAY")
    drawerAccent:SetHeight(2)
    drawerAccent:SetPoint("BOTTOMLEFT", 6, 1)
    drawerAccent:SetPoint("BOTTOMRIGHT", -6, 1)
    drawerAccent:SetTexture("Interface\\Buttons\\WHITE8x8")
    drawerAccent:SetVertexColor(C.classColor.r, C.classColor.g, C.classColor.b, 0.6)

    -- -----------------------------------------------------------------------
    -- INTERFACE BUTTONS (inside drawer)
    -- Created right-to-left from the drawer's right edge, 38px apart.
    -- -----------------------------------------------------------------------
    local interfaceBtns = {}
    local btnSize = 32
    local btnSpacing = 38

    for i, btnData in ipairs(INTERFACE_BUTTONS) do
        local b = CreateFrame("Button", nil, drawer)
        b:SetSize(btnSize, btnSize)
        b:SetPoint("RIGHT", drawer, "RIGHT", -8 - ((i-1) * btnSpacing), 0)

        -- Dark square background behind each icon
        local btnBg = b:CreateTexture(nil, "BACKGROUND")
        btnBg:SetAllPoints()
        btnBg:SetTexture("Interface\\Buttons\\WHITE8x8")
        btnBg:SetVertexColor(0.1, 0.1, 0.12, 0.7)
        b.btnBg = btnBg

        -- Thin border frame around each button
        local btnBorder = CreateFrame("Frame", nil, b, "BackdropTemplate")
        btnBorder:SetAllPoints()
        btnBorder:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1})
        btnBorder:SetBackdropBorderColor(0.2, 0.2, 0.24, 1)
        btnBorder:SetFrameLevel(b:GetFrameLevel() + 1)
        b.btnBorder = btnBorder

        -- Icon texture with inset for clean edges
        local bIcon = b:CreateTexture(nil, "ARTWORK")
        bIcon:SetPoint("TOPLEFT", 2, -2)
        bIcon:SetPoint("BOTTOMRIGHT", -2, 2)
        bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        b.bIcon = bIcon

        -- Dynamic icon resolution: Housing button pulls texture from the
        -- Blizzard micro button at runtime to stay current across patches
        if btnData.icon == "DynamicHousing" then
            bIcon:SetTexture(4622467)
            b:SetScript("OnShow", function(self)
                local housingBtn = _G["HousingMicroButton"]
                if housingBtn and housingBtn.GetNormalTexture then
                    local normal = housingBtn:GetNormalTexture()
                    if normal then
                        local atlas = normal:GetAtlas()
                        if atlas then
                            self.bIcon:SetAtlas(atlas)
                        else
                            local texture = normal:GetTexture()
                            if texture then
                                self.bIcon:SetTexture(texture)
                            end
                        end
                    end
                end
            end)
        else
            bIcon:SetTexture(btnData.icon)
        end

        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetTexture("Interface\\Buttons\\WHITE8x8")
        hl:SetVertexColor(1, 1, 1, 0.12)
        hl:SetBlendMode("ADD")

        -- Hover: class-colored border highlight + tooltip
        b:SetScript("OnEnter", function(self)
            -- Re-resolve housing icon on hover to catch late texture changes
            if btnData.icon == "DynamicHousing" and self:GetScript("OnShow") then
                self:GetScript("OnShow")(self)
            end

            self.btnBorder:SetBackdropBorderColor(C.classColor.r, C.classColor.g, C.classColor.b, 0.7)
            self.btnBg:SetVertexColor(0.12, 0.12, 0.15, 0.85)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(btnData.tooltip)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function(self)
            self.btnBorder:SetBackdropBorderColor(0.2, 0.2, 0.24, 1)
            self.btnBg:SetVertexColor(0.1, 0.1, 0.12, 0.7)
            GameTooltip:Hide()
        end)

        b:SetScript("OnClick", btnData.onClick)
        table.insert(interfaceBtns, b)
    end

    -- Total drawer width: all buttons + padding
    local drawerWidth = (#INTERFACE_BUTTONS * btnSpacing) + 16

    -- -----------------------------------------------------------------------
    -- SMOOTH SLIDE ANIMATION
    -- OnUpdate lerp that drives drawer width and alpha toward target values.
    -- Uses a 0.2s hover-off delay to prevent flicker from rapid mouse exits.
    -- -----------------------------------------------------------------------
    drawer.targetWidth = 1
    drawer.targetAlpha = 0
    local hoverTimer = 0

    --- UpdateSlide: OnUpdate handler that lerps drawer width/alpha each frame.
    -- @param self (Frame) - The drawer frame
    -- @param elapsed (number) - Seconds since last frame
    -- @note When fully closed (alpha=0, width=1), the drawer calls Hide() to
    --       stop OnUpdate processing and save CPU. Hover on either the drawer
    --       or the dock resets the close timer.
    local function UpdateSlide(self, elapsed)
        -- Check if mouse is over drawer or dock to keep it open
        if self:IsMouseOver() or dockFrame:IsMouseOver() then
            hoverTimer = 0
            self.targetWidth = drawerWidth
            self.targetAlpha = 1
            -- Tint dock border with class color while drawer is open
            dockFrame.bgFrame:SetBackdropBorderColor(C.classColor.r * 0.7, C.classColor.g * 0.7, C.classColor.b * 0.7, 1)
        else
            hoverTimer = hoverTimer + elapsed
        end

        -- Close after 0.2s with mouse away (prevents stuck-open flicker)
        if hoverTimer > 0.2 then
            self.targetWidth = 1
            self.targetAlpha = 0
            dockFrame.bgFrame:SetBackdropBorderColor(0.18, 0.18, 0.22, 1)
        end

        -- Lerp width and alpha toward targets with capped speed
        local speed = math.min(14 * elapsed, 0.6)

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
            -- Hide when fully closed to stop OnUpdate and conserve CPU
            if self.targetAlpha <= 0 and self.targetWidth <= 1 then self:Hide() end
        else
            self:SetAlpha(curA + (diffA * speed))
        end
    end
    drawer:SetScript("OnUpdate", UpdateSlide)

    -- -----------------------------------------------------------------------
    -- HOVER TRIGGERS
    -- Dock hover opens the drawer; leave only hides the tooltip (close is
    -- handled by the 0.2s timer in UpdateSlide).
    -- -----------------------------------------------------------------------
    dockFrame:SetScript("OnEnter", function(self)
        drawer:Show()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Game Menu")
        GameTooltip:Show()
    end)

    dockFrame:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)

    interfaceDockRef = dockFrame
    _G.MidnightUI_InterfaceMenuDock = dockFrame
    ApplyInterfaceMenuSettings()
    return dockFrame
end

-- ============================================================================
-- OVERLAY SETTINGS PANEL
-- Registers a small settings panel (enable toggle + scale slider) with the
-- MidnightUI overlay builder system for right-click access in move mode.
-- ============================================================================

--- BuildInterfaceMenuOverlaySettings: Populates the overlay settings panel
--  content for the Game Menu element.
-- @param content (Frame) - The overlay panel's content host frame
-- @return (number|nil) - Total content height consumed, or nil if builder unavailable
-- @calledby MidnightUI overlay settings system
local function BuildInterfaceMenuOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureInterfaceMenuSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Header("Game Menu")
    b:Checkbox("Enable Game Menu Button", s.enabled ~= false, function(v)
        s.enabled = (v and true or false)
        ApplyInterfaceMenuSettings()
    end)
    b:Slider("Scale %", 50, 200, 5, ClampNumber(s.scale, 50, 200, 100), function(v)
        s.scale = math.floor(v)
        ApplyInterfaceMenuSettings()
    end)

    return b:Height()
end

-- Cross-module call: register with the shared overlay settings registry
if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("InterfaceMenu", { title = "Game Menu", build = BuildInterfaceMenuOverlaySettings })
end

-- ============================================================================
-- EVENT HANDLER
-- PLAYER_LOGIN: builds the dock, hides the default micro menu, rescues the
--               QueueStatusButton, and ensures mouse-enabled state persists.
-- PLAYER_REGEN_ENABLED: re-applies settings that were deferred during combat.
-- ============================================================================

MidnightInterface:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" then
        CreateInterfaceDock()
        ApplyInterfaceMenuSettings()

        -- ===================================================================
        -- QUEUE STATUS BUTTON RESCUE
        -- The QueueStatusButton lives inside MicroMenuContainer which we hide.
        -- We reparent it to UIParent and pin it above the Game Menu dock, then
        -- hook SetPoint to block Blizzard from moving it back.
        -- ===================================================================
        if QueueStatusButton then
            QueueStatusButton:SetParent(UIParent)

            --- ForceQueueButtonPosition: Moves QueueStatusButton to a fixed
            --  position above the Game Menu dock. Uses a re-entrancy guard
            --  (QueueStatusButton.moving) to prevent infinite SetPoint hooks.
            local function ForceQueueButtonPosition()
                if QueueStatusButton.moving then return end
                QueueStatusButton.moving = true

                QueueStatusButton:ClearAllPoints()
                -- Positioned 52px above the dock button (dock is at y=95, so y=147)
                QueueStatusButton:SetPoint("BOTTOMRIGHT", UIParent, "BOTTOMRIGHT", -40, 147)
                QueueStatusButton:SetFrameLevel(20)

                QueueStatusButton.moving = false
            end

            ForceQueueButtonPosition()

            -- Hook SetPoint to immediately override any Blizzard repositioning
            hooksecurefunc(QueueStatusButton, "SetPoint", ForceQueueButtonPosition)

            -- Belt-and-suspenders: re-force after a short delay for late movers
            C_Timer.After(1, ForceQueueButtonPosition)
        end

        -- ===================================================================
        -- HIDE DEFAULT MICRO MENU
        -- Alpha=0 + Scale=0.001 makes it invisible but keeps it in the frame
        -- hierarchy. Mouse stays enabled so MainMenuMicroButton secure clicks
        -- still work (needed for keybinds and other addons).
        -- ===================================================================
        if MicroMenuContainer then
            MicroMenuContainer:SetAlpha(0)
            MicroMenuContainer:SetScale(0.001)
            MicroMenuContainer:EnableMouse(true)
            if MainMenuMicroButton then
                MainMenuMicroButton:EnableMouse(true)
            end
        elseif MicroMenu then
            MicroMenu:SetAlpha(0)
            MicroMenu:SetScale(0.001)
            MicroMenu:EnableMouse(true)
            if MainMenuMicroButton then
                MainMenuMicroButton:EnableMouse(true)
            end
        end

        -- ===================================================================
        -- MOUSE-ENABLED PERSISTENCE
        -- Some Blizzard code re-disables mouse on the micro menu after login.
        -- A ticker + SecureHookSecureFunc combination ensures it stays enabled.
        -- ===================================================================

        --- EnsureMicroMenuMouseEnabled: Re-enables mouse on MicroMenuContainer
        --  and MainMenuMicroButton if Blizzard code disabled them.
        local function EnsureMicroMenuMouseEnabled()
            if MicroMenuContainer then
                if not MicroMenuContainer:IsMouseEnabled() then
                    MicroMenuContainer:EnableMouse(true)
                end
            elseif MicroMenu then
                if not MicroMenu:IsMouseEnabled() then
                    MicroMenu:EnableMouse(true)
                end
            end
            if MainMenuMicroButton and not MainMenuMicroButton:IsMouseEnabled() then
                MainMenuMicroButton:EnableMouse(true)
            end
        end

        EnsureMicroMenuMouseEnabled()
        -- Tick 10 times at 0.5s intervals to catch late Blizzard re-disables
        C_Timer.NewTicker(0.5, EnsureMicroMenuMouseEnabled, 10)

        -- Hook EnableMouse to block any future disabling by Blizzard code
        if MicroMenuContainer and hooksecurefunc then
            hooksecurefunc(MicroMenuContainer, "EnableMouse", function(self, enabled)
                if enabled == false then
                    self:EnableMouse(true)
                end
            end)
        elseif MicroMenu and hooksecurefunc then
            hooksecurefunc(MicroMenu, "EnableMouse", function(self, enabled)
                if enabled == false then
                    self:EnableMouse(true)
                end
            end)
        end
        if MainMenuMicroButton and hooksecurefunc then
            hooksecurefunc(MainMenuMicroButton, "EnableMouse", function(self, enabled)
                if enabled == false then
                    self:EnableMouse(true)
                end
            end)
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- Re-apply settings that were deferred because of combat lockdown
        if pendingInterfaceMenuApply then
            ApplyInterfaceMenuSettings()
        else
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
    end
end)
