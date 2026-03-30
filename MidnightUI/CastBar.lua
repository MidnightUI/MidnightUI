-- =============================================================================
-- FILE PURPOSE:     Cast bar system for player, target, and focus. Styles Blizzard's
--                   cast bar frames with dark backgrounds, icon borders, animated
--                   active-pulse borders (breathing alpha), interrupt flash overlays,
--                   and a success glow that expands outward on cast completion.
-- LOAD ORDER:       Loads after PlayerFrame, TargetFrame, FocusFrame. CastBarManager
--                   handles ADDON_LOADED to wire the bars after settings are available.
-- DEFINES:          CastBarManager (event frame), castContainers[] (per-unit overlays).
--                   Global refresh: MidnightUI_ApplyCastBarSettings().
-- READS:            MidnightUI_Settings.EnsureCastBarsSettings() via MidnightUISettings.CastBars.
--                   MidnightUISettings.CastBars.{player|target|focus}.{enabled, width, height,
--                   scale, alpha, position, showIcon, showTimer}.
-- WRITES:           MidnightUISettings.CastBars.*.position (on drag stop).
-- DEPENDS ON:       MidnightUI_GetOverlayHandle (Core.lua) — refreshes drag-overlay bounding.
--                   Blizzard cast bar frames: PlayerCastingBarFrame, TargetFrameSpellBar,
--                   FocusFrameSpellBar — styled in-place (not replaced).
-- USED BY:          Settings_UI.lua, MidnightUI_ApplyCastBarSettings (Settings.lua calls here).
-- KEY FLOWS:
--   ADDON_LOADED → ApplyAllCastBarSettings() → hooks each Blizzard bar's Show/Hide/OnUpdate
--   UNIT_SPELLCAST_START → attach pulse animation to border
--   UNIT_SPELLCAST_SUCCEEDED → PlayManagedCastSuccessPulse (expanding glow)
--   UNIT_SPELLCAST_INTERRUPTED/FAILED → SetManagedInterruptedBorderState (red flash)
--   PLAYER_REGEN_ENABLED → QueuePlayerCastBarApply flush (combat-deferred layout)
-- GOTCHAS:
--   Player cast bar is a SecureFrame in combat; layout changes queue via
--   QueuePlayerCastBarApply / PLAYER_REGEN_ENABLED.
--   SafeNumber() wraps frame:GetWidth/GetHeight in pcall+tostring+tonumber to launder
--   secret values returned by Blizzard's secure frame system.
--   SUCCESS_FAILED_QUIET_GRACE (0.75s): a FAILED event within 0.75s of a successful cast
--   is suppressed to avoid false-red flashes from server-latency spell-fail messages.
--   Border animations: EnsureBorderPulse (lazy-init), EnsureInterruptBorderOverlay,
--   EnsureSuccessBorderOverlay — all lazily created on first use per bar.
-- NAVIGATION:
--   PLAYER_CAST_BORDER_COLOR        — green pulse color for active casts (line ~21)
--   INTERRUPTED_BORDER_COLOR        — red flash color (line ~22)
--   CreateBlackBorder()             — shared border factory (line ~88)
--   EnsureBorderPulse()             — lazy-creates the BOUNCE alpha animation group
--   PlaySuccessBorderAccent()       — expanding glow on cast success
--   SetManagedInterruptedBorderState() — manages interrupt visual state machine
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local CastBarManager = CreateFrame("Frame")

local playerOwner
local targetOwner
local focusOwner
local lastLockedState = nil
local pendingPlayerCastBarApply = false
local castContainers = {}

local STYLE_BORDER_ALPHA = 1.0
local STYLE_BORDER_THICKNESS = 2
local STYLE_CAST_ICON_PADDING = 4
local STYLE_CAST_FONT_SIZE = 12
local STYLE_TIMER_FONT_SIZE = 11
local STYLE_CAST_CORNER_CUT = 2
local PLAYER_CAST_BORDER_COLOR = { 0.18, 0.72, 0.28, 0.76 }
local INTERRUPTED_BORDER_COLOR = { 0.92, 0.18, 0.18, 0.78 }
local ACTIVE_BORDER_DIM_ALPHA = 0.78
local ACTIVE_BORDER_BRIGHT_ALPHA = 1.0
local ACTIVE_BORDER_PULSE_DURATION = 1.35
local INTERRUPTED_BORDER_FLASH_ALPHA = 0.90
local INTERRUPTED_BORDER_FLASH_DURATION = 0.24
local SUCCESS_BORDER_PULSE_ALPHA = 0.52
local SUCCESS_BORDER_PULSE_DURATION = 0.56
local SUCCESS_BORDER_PULSE_EXPAND = 11
local SUCCESS_FAILED_QUIET_GRACE = 0.75

local function IsManagedCastKind(kind)
    return kind == "player" or kind == "target" or kind == "focus"
end

local function GetManagedCastKindForUnit(unit)
    if unit == "player" or unit == "target" or unit == "focus" then
        return unit
    end
    return nil
end

local function IsInCombatState()
    if type(InCombatLockdown) ~= "function" then
        return false
    end
    local ok, restricted = pcall(InCombatLockdown)
    return ok and restricted == true
end

-- Safely read a numeric frame property that may return a tainted ("secret")
-- value from Blizzard's secure frame system. Launders the value through
-- tostring+tonumber inside pcall so comparisons and arithmetic won't trigger
-- taint errors.
local function SafeNumber(fn, fallback)
    local result = fallback or 0
    pcall(function()
        local v = fn()
        if v ~= nil then
            result = tonumber(tostring(v)) or fallback or 0
        end
    end)
    return result
end

local function QueuePlayerCastBarApply()
    if pendingPlayerCastBarApply then return end
    pendingPlayerCastBarApply = true
    CastBarManager:RegisterEvent("PLAYER_REGEN_ENABLED")
end

local function ClearQueuedPlayerCastBarApply()
    if not pendingPlayerCastBarApply then return end
    pendingPlayerCastBarApply = false
    CastBarManager:UnregisterEvent("PLAYER_REGEN_ENABLED")
end

local function RefreshOverlayByKey(key)
    if _G.MidnightUI_GetOverlayHandle then
        local o = _G.MidnightUI_GetOverlayHandle(key)
        if o and o.SetAllPoints then
            o:SetAllPoints()
        end
    end
end

local function CreateBlackBorder(parent, alpha, thickness)
    alpha = alpha or 1
    thickness = thickness or STYLE_BORDER_THICKNESS
    local border = CreateFrame("Frame", nil, parent)
    border:SetAllPoints()
    border.top = border:CreateTexture(nil, "OVERLAY"); border.top:SetHeight(thickness); border.top:SetPoint("TOPLEFT"); border.top:SetPoint("TOPRIGHT"); border.top:SetColorTexture(0, 0, 0, alpha)
    border.bottom = border:CreateTexture(nil, "OVERLAY"); border.bottom:SetHeight(thickness); border.bottom:SetPoint("BOTTOMLEFT"); border.bottom:SetPoint("BOTTOMRIGHT"); border.bottom:SetColorTexture(0, 0, 0, alpha)
    border.left = border:CreateTexture(nil, "OVERLAY"); border.left:SetWidth(thickness); border.left:SetPoint("TOPLEFT"); border.left:SetPoint("BOTTOMLEFT"); border.left:SetColorTexture(0, 0, 0, alpha)
    border.right = border:CreateTexture(nil, "OVERLAY"); border.right:SetWidth(thickness); border.right:SetPoint("TOPRIGHT"); border.right:SetPoint("BOTTOMRIGHT"); border.right:SetColorTexture(0, 0, 0, alpha)
    border.innerHighlight = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerHighlight:SetHeight(3)
    border.innerHighlight:SetPoint("TOPLEFT", border.top, "BOTTOMLEFT", thickness, 0)
    border.innerHighlight:SetPoint("TOPRIGHT", border.top, "BOTTOMRIGHT", -thickness, 0)
    border.innerHighlight:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerHighlight:SetGradient("VERTICAL",
        CreateColor(1, 1, 1, 0),
        CreateColor(1, 1, 1, 0.07))
    border.innerShadow = border:CreateTexture(nil, "OVERLAY", nil, 2)
    border.innerShadow:SetHeight(3)
    border.innerShadow:SetPoint("BOTTOMLEFT", border.bottom, "TOPLEFT", thickness, 0)
    border.innerShadow:SetPoint("BOTTOMRIGHT", border.bottom, "TOPRIGHT", -thickness, 0)
    border.innerShadow:SetTexture("Interface\\Buttons\\WHITE8X8")
    border.innerShadow:SetGradient("VERTICAL",
        CreateColor(0, 0, 0, 0.25),
        CreateColor(0, 0, 0, 0))
    return border
end

local function SetSimpleBorderColor(border, r, g, b, a)
    if not border then return false end
    if border.SetBackdropBorderColor then
        border:SetBackdropBorderColor(r, g, b, a)
        return true
    end

    local applied = false
    local edges = { border.top, border.bottom, border.left, border.right }
    for i = 1, #edges do
        local edge = edges[i]
        if edge and edge.SetColorTexture then
            edge:SetColorTexture(r, g, b, a)
            applied = true
        end
    end
    return applied
end

local function EnsureBorderPulse(border)
    if not border or border._muiPulse then return end
    local group = border:CreateAnimationGroup()
    group:SetLooping("BOUNCE")

    local fade = group:CreateAnimation("Alpha")
    fade:SetOrder(1)
    fade:SetFromAlpha(ACTIVE_BORDER_BRIGHT_ALPHA)
    fade:SetToAlpha(ACTIVE_BORDER_DIM_ALPHA)
    fade:SetDuration(ACTIVE_BORDER_PULSE_DURATION)
    fade:SetSmoothing("IN_OUT")

    border._muiPulse = group
end

local function SetBorderPulseActive(border, active)
    if not border then return end
    EnsureBorderPulse(border)
    if not border._muiPulse then return end

    if active then
        border:SetAlpha(ACTIVE_BORDER_BRIGHT_ALPHA)
        if not border._muiPulse:IsPlaying() then
            border._muiPulse:Play()
        end
        return
    end

    if border._muiPulse:IsPlaying() then
        border._muiPulse:Stop()
    end
    border:SetAlpha(ACTIVE_BORDER_BRIGHT_ALPHA)
end

local function EnsureInterruptBorderOverlay(border)
    if not border then return nil end
    if border._muiInterruptOverlay then return border._muiInterruptOverlay end

    local parent = border.GetParent and border:GetParent() or border
    local overlay = CreateBlackBorder(parent, 1, STYLE_BORDER_THICKNESS + 1)
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", parent, "TOPLEFT", -1, 1)
    overlay:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 1, -1)
    if overlay.SetFrameLevel and parent and parent.GetFrameLevel then
        overlay:SetFrameLevel(parent:GetFrameLevel() + 2)
    end
    SetSimpleBorderColor(
        overlay,
        INTERRUPTED_BORDER_COLOR[1],
        INTERRUPTED_BORDER_COLOR[2],
        INTERRUPTED_BORDER_COLOR[3],
        INTERRUPTED_BORDER_COLOR[4]
    )
    overlay:SetAlpha(0)

    local flashGroup = overlay:CreateAnimationGroup()
    local fadeOut = flashGroup:CreateAnimation("Alpha")
    fadeOut:SetOrder(1)
    fadeOut:SetFromAlpha(INTERRUPTED_BORDER_FLASH_ALPHA)
    fadeOut:SetToAlpha(0)
    fadeOut:SetDuration(INTERRUPTED_BORDER_FLASH_DURATION)
    fadeOut:SetSmoothing("OUT")

    overlay._muiFlash = flashGroup
    border._muiInterruptOverlay = overlay
    return overlay
end

local function PlayInterruptBorderAccent(border)
    if not border then return end
    local overlay = EnsureInterruptBorderOverlay(border)
    if not overlay then return end

    if overlay._muiFlash and overlay._muiFlash:IsPlaying() then
        overlay._muiFlash:Stop()
    end
    overlay:SetAlpha(INTERRUPTED_BORDER_FLASH_ALPHA)
    if overlay._muiFlash then
        overlay._muiFlash:Play()
    end
end

local function ClearInterruptBorderAccent(border)
    if not border then return end
    local overlay = EnsureInterruptBorderOverlay(border)
    if not overlay then return end
    if overlay._muiFlash and overlay._muiFlash:IsPlaying() then
        overlay._muiFlash:Stop()
    end
    overlay:SetAlpha(0)
end

local function EnsureSuccessBorderOverlay(border)
    if not border then return nil end
    if border._muiSuccessOverlay then return border._muiSuccessOverlay end

    local source = border.GetParent and border:GetParent() or border
    local host = source and source.GetParent and source:GetParent() or UIParent
    local overlay = CreateFrame("Frame", nil, host)
    overlay:ClearAllPoints()
    overlay:SetPoint("TOPLEFT", source, "TOPLEFT", -2, 2)
    overlay:SetPoint("BOTTOMRIGHT", source, "BOTTOMRIGHT", 2, -2)
    if overlay.SetFrameLevel and source and source.GetFrameLevel then
        overlay:SetFrameLevel(source:GetFrameLevel() + 1)
    end
    overlay.glow = overlay:CreateTexture(nil, "ARTWORK")
    overlay.glow:SetAllPoints()
    overlay.glow:SetTexture("Interface\\Buttons\\WHITE8X8")
    overlay.glow:SetBlendMode("ADD")
    overlay.glow:SetVertexColor(
        PLAYER_CAST_BORDER_COLOR[1],
        PLAYER_CAST_BORDER_COLOR[2],
        PLAYER_CAST_BORDER_COLOR[3],
        0.70
    )
    overlay.innerGlow = overlay:CreateTexture(nil, "ARTWORK")
    overlay.innerGlow:SetPoint("TOPLEFT", overlay, "TOPLEFT", 5, -5)
    overlay.innerGlow:SetPoint("BOTTOMRIGHT", overlay, "BOTTOMRIGHT", -5, 5)
    overlay.innerGlow:SetTexture("Interface\\Buttons\\WHITE8X8")
    overlay.innerGlow:SetBlendMode("ADD")
    overlay.innerGlow:SetVertexColor(
        PLAYER_CAST_BORDER_COLOR[1],
        PLAYER_CAST_BORDER_COLOR[2],
        PLAYER_CAST_BORDER_COLOR[3],
        0.38
    )
    overlay:SetAlpha(0)
    overlay._muiPulseAnchor = source
    overlay._muiPulseTicker = 0
    overlay._muiPulseActive = false
    border._muiSuccessOverlay = overlay
    return overlay
end

local function PlaySuccessBorderAccent(border)
    if not border then return end
    local overlay = EnsureSuccessBorderOverlay(border)
    if not overlay then return end

    overlay._muiPulseActive = true
    overlay._muiPulseTicker = 0
    overlay:Show()
    overlay:SetScript("OnUpdate", function(self, elapsed)
        if not self._muiPulseActive or not self._muiPulseAnchor then
            self:SetScript("OnUpdate", nil)
            return
        end

        local t = (self._muiPulseTicker or 0) + (elapsed or 0)
        self._muiPulseTicker = t
        local p = t / SUCCESS_BORDER_PULSE_DURATION
        if p >= 1 then
            self._muiPulseActive = false
            self._muiPulseTicker = 0
            self:SetAlpha(0)
            self:ClearAllPoints()
            self:SetPoint("TOPLEFT", self._muiPulseAnchor, "TOPLEFT", -2, 2)
            self:SetPoint("BOTTOMRIGHT", self._muiPulseAnchor, "BOTTOMRIGHT", 2, -2)
            self:SetScript("OnUpdate", nil)
            return
        end

        local easedExpand = 1 - ((1 - p) * (1 - p))
        local easedFade = (1 - p) * (1 - p)
        local expand = SUCCESS_BORDER_PULSE_EXPAND * easedExpand
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", self._muiPulseAnchor, "TOPLEFT", -2 - expand, 2 + expand)
        self:SetPoint("BOTTOMRIGHT", self._muiPulseAnchor, "BOTTOMRIGHT", 2 + expand, -2 - expand)
        self:SetAlpha(SUCCESS_BORDER_PULSE_ALPHA * easedFade)
    end)
end

local function ClearSuccessBorderAccent(border)
    if not border then return end
    local overlay = border._muiSuccessOverlay
    if not overlay then return end
    overlay._muiPulseActive = false
    overlay._muiPulseTicker = 0
    overlay:SetScript("OnUpdate", nil)
    overlay:SetAlpha(0)
    if overlay._muiPulseAnchor then
        overlay:ClearAllPoints()
        overlay:SetPoint("TOPLEFT", overlay._muiPulseAnchor, "TOPLEFT", -2, 2)
        overlay:SetPoint("BOTTOMRIGHT", overlay._muiPulseAnchor, "BOTTOMRIGHT", 2, -2)
    end
end

local function SetManagedCastBorderColor(bar, color)
    if not bar or not color then return false, false end
    local iconBorder = bar.iconBorderBorder or bar.iconBorder
    local borderApplied = SetSimpleBorderColor(
        bar.border,
        color[1],
        color[2],
        color[3],
        color[4]
    )
    local iconBorderApplied = SetSimpleBorderColor(
        iconBorder,
        color[1],
        color[2],
        color[3],
        color[4]
    )
    return borderApplied, iconBorderApplied
end

local function RememberSuccessfulCast(bar)
    if not bar then return end
    bar._muiLastSuccessfulCastAt = GetTime and GetTime() or 0
end

local function ShouldSuppressFailedQuiet(bar)
    if not bar or not bar._muiLastSuccessfulCastAt then return false end
    local now = GetTime and GetTime() or 0
    if (now - bar._muiLastSuccessfulCastAt) > SUCCESS_FAILED_QUIET_GRACE then
        return false
    end
    return true
end

local function PlayManagedCastSuccessPulse(bar)
    if not bar then return end
    local iconBorder = bar.iconBorderBorder or bar.iconBorder
    bar._muiInterruptedVisualActive = false
    RememberSuccessfulCast(bar)
    ClearInterruptBorderAccent(bar.border)
    ClearInterruptBorderAccent(iconBorder)
    SetManagedCastBorderColor(bar, PLAYER_CAST_BORDER_COLOR)
    SetBorderPulseActive(bar.border, false)
    SetBorderPulseActive(iconBorder, false)
    PlaySuccessBorderAccent(bar.border)
end

local function SetManagedInterruptedBorderState(kind, bar, active)
    if not bar then return end
    local iconBorder = bar.iconBorderBorder or bar.iconBorder

    if active then
        bar._muiInterruptedVisualActive = true
        ClearSuccessBorderAccent(bar.border)
        ClearSuccessBorderAccent(iconBorder)
        SetBorderPulseActive(bar.border, false)
        SetBorderPulseActive(iconBorder, false)
        SetManagedCastBorderColor(bar, INTERRUPTED_BORDER_COLOR)
        PlayInterruptBorderAccent(bar.border)
        PlayInterruptBorderAccent(iconBorder)
        return
    end

    bar._muiInterruptedVisualActive = false
    ClearInterruptBorderAccent(bar.border)
    ClearInterruptBorderAccent(iconBorder)
    ClearSuccessBorderAccent(bar.border)
    ClearSuccessBorderAccent(iconBorder)
    SetManagedCastBorderColor(bar, PLAYER_CAST_BORDER_COLOR)
    if IsManagedCastKind(kind) or IsManagedCastKind(bar._muiCastKind) then
        local shown = bar.IsShown and bar:IsShown()
        SetBorderPulseActive(bar.border, shown)
        SetBorderPulseActive(iconBorder, shown)
    end
end

local function AttachActiveBorderPulse(bar, border, iconBorder)
    if not bar or bar._muiActiveBorderPulseHooks then return end
    bar._muiActiveBorderPulseHooks = true

    bar:HookScript("OnShow", function(self)
        if not IsManagedCastKind(self._muiCastKind) and not IsManagedCastKind(self.unit) then return end
        if self._muiInterruptedVisualActive then
            ClearSuccessBorderAccent(border)
            ClearSuccessBorderAccent(iconBorder)
            SetManagedCastBorderColor(self, INTERRUPTED_BORDER_COLOR)
            SetBorderPulseActive(border, false)
            SetBorderPulseActive(iconBorder, false)
            return
        end
        ClearInterruptBorderAccent(border)
        ClearInterruptBorderAccent(iconBorder)
        ClearSuccessBorderAccent(border)
        ClearSuccessBorderAccent(iconBorder)
        SetManagedCastBorderColor(self, PLAYER_CAST_BORDER_COLOR)
        SetBorderPulseActive(border, true)
        SetBorderPulseActive(iconBorder, true)
    end)
    bar:HookScript("OnHide", function()
        bar._muiInterruptedVisualActive = false
        ClearInterruptBorderAccent(border)
        ClearInterruptBorderAccent(iconBorder)
        SetBorderPulseActive(border, false)
        SetBorderPulseActive(iconBorder, false)
    end)
end

local function SetFontSafe(fs, fontPath, size, flags)
    local ok = fs:SetFont(fontPath, size, flags)
    if not ok then
        local fallback = GameFontNormal and GameFontNormal:GetFont()
        if fallback then fs:SetFont(fallback, size or 12, flags) end
    end
    return ok
end

local function EnsureCornerCut(frame, size, r, g, b, a)
    if not frame then return end
    local cut = math.max(1, math.floor(size or STYLE_CAST_CORNER_CUT))
    local corners = frame._muiCornerCut
    if not corners then
        corners = {}
        corners.tl = frame:CreateTexture(nil, "OVERLAY")
        corners.tr = frame:CreateTexture(nil, "OVERLAY")
        corners.bl = frame:CreateTexture(nil, "OVERLAY")
        corners.br = frame:CreateTexture(nil, "OVERLAY")
        corners.tl:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        corners.tr:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        corners.bl:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        corners.br:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        frame._muiCornerCut = corners
    end
    corners.tl:SetSize(cut, cut)
    corners.tr:SetSize(cut, cut)
    corners.bl:SetSize(cut, cut)
    corners.br:SetSize(cut, cut)
    corners.tl:SetColorTexture(r, g, b, a)
    corners.tr:SetColorTexture(r, g, b, a)
    corners.bl:SetColorTexture(r, g, b, a)
    corners.br:SetColorTexture(r, g, b, a)
end

local SUPPRESSED_CAST_BAR_REGION_KEYS = {
    "Border",
    "border",
    "borderArt",
    "BorderShield",
    "Shield",
    "shield",
    "TextBorder",
    "textBorder",
    "Flash",
    "flash",
    "Shine",
    "shine",
    "ChargeFlash",
    "chargeFlash",
}

local function SuppressNativeCastBarVisuals(bar)
    if not bar then return end
    if not bar._muiSuppressedRegions then
        bar._muiSuppressedRegions = {}
    end

    for i = 1, #SUPPRESSED_CAST_BAR_REGION_KEYS do
        local key = SUPPRESSED_CAST_BAR_REGION_KEYS[i]
        local region = bar[key]
        if region and region ~= bar._muiCustomBorder then
            if region.SetAlpha then region:SetAlpha(0) end
            if region.Hide then region:Hide() end

            if not bar._muiSuppressedRegions[key] and type(hooksecurefunc) == "function" and type(region.Show) == "function" then
                local ok = pcall(hooksecurefunc, region, "Show", function(self)
                    if self.SetAlpha then self:SetAlpha(0) end
                    if self.Hide then self:Hide() end
                end)
                if ok then
                    bar._muiSuppressedRegions[key] = true
                end
            end
        end
    end
end


local function ApplyNameplateCastVisualStyle(bar)
    if not bar or bar.MidnightStyled then return end
    bar.MidnightStyled = true

    if bar.SetClipsChildren then bar:SetClipsChildren(true) end
    if bar.GetStatusBarTexture then
        local tex = bar:GetStatusBarTexture()
        if tex then
            tex:SetHorizTile(false)
            tex:SetVertTile(false)
            -- Do NOT touch anchor points — the StatusBar engine manages fill width
            -- internally via SetValue(). ClearAllPoints breaks the fill entirely.
        end
    end

    -- Background: subtle vertical gradient for depth
    if not bar.bg then
        bar.bg = bar:CreateTexture(nil, "BACKGROUND")
        bar.bg:ClearAllPoints()
        bar.bg:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        bar.bg:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        bar.bg:SetTexture("Interface\\Buttons\\WHITE8X8")
        bar.bg:SetGradient("VERTICAL",
            CreateColor(0.03, 0.03, 0.03, 0.80),
            CreateColor(0.08, 0.08, 0.10, 0.70))
    end
    EnsureCornerCut(bar, STYLE_CAST_CORNER_CUT, 0.03, 0.03, 0.03, 1)

    if not bar.border then
        local border = CreateFrame("Frame", nil, bar)
        border:SetAllPoints()
        border:SetFrameLevel((bar:GetFrameLevel() or 0) + 2)

        -- 1px outer dark hairline
        border.hairTop = border:CreateTexture(nil, "OVERLAY", nil, 2)
        border.hairTop:SetHeight(1); border.hairTop:SetPoint("TOPLEFT"); border.hairTop:SetPoint("TOPRIGHT")
        border.hairTop:SetColorTexture(0, 0, 0, 1)
        border.hairBottom = border:CreateTexture(nil, "OVERLAY", nil, 2)
        border.hairBottom:SetHeight(1); border.hairBottom:SetPoint("BOTTOMLEFT"); border.hairBottom:SetPoint("BOTTOMRIGHT")
        border.hairBottom:SetColorTexture(0, 0, 0, 1)
        border.hairLeft = border:CreateTexture(nil, "OVERLAY", nil, 2)
        border.hairLeft:SetWidth(1); border.hairLeft:SetPoint("TOPLEFT"); border.hairLeft:SetPoint("BOTTOMLEFT")
        border.hairLeft:SetColorTexture(0, 0, 0, 1)
        border.hairRight = border:CreateTexture(nil, "OVERLAY", nil, 2)
        border.hairRight:SetWidth(1); border.hairRight:SetPoint("TOPRIGHT"); border.hairRight:SetPoint("BOTTOMRIGHT")
        border.hairRight:SetColorTexture(0, 0, 0, 1)

        -- 2px colored band (green/red pulse) inset 1px from the outer hairline
        border.top = border:CreateTexture(nil, "OVERLAY", nil, 3)
        border.top:SetHeight(2); border.top:SetPoint("TOPLEFT", 1, -1); border.top:SetPoint("TOPRIGHT", -1, -1)
        border.top:SetColorTexture(0, 0, 0, STYLE_BORDER_ALPHA)
        border.bottom = border:CreateTexture(nil, "OVERLAY", nil, 3)
        border.bottom:SetHeight(2); border.bottom:SetPoint("BOTTOMLEFT", 1, 1); border.bottom:SetPoint("BOTTOMRIGHT", -1, 1)
        border.bottom:SetColorTexture(0, 0, 0, STYLE_BORDER_ALPHA)
        border.left = border:CreateTexture(nil, "OVERLAY", nil, 3)
        border.left:SetWidth(2); border.left:SetPoint("TOPLEFT", 1, -1); border.left:SetPoint("BOTTOMLEFT", 1, 1)
        border.left:SetColorTexture(0, 0, 0, STYLE_BORDER_ALPHA)
        border.right = border:CreateTexture(nil, "OVERLAY", nil, 3)
        border.right:SetWidth(2); border.right:SetPoint("TOPRIGHT", -1, -1); border.right:SetPoint("BOTTOMRIGHT", -1, 1)
        border.right:SetColorTexture(0, 0, 0, STYLE_BORDER_ALPHA)

        -- Gloss: 1px bright highlight on the top edge of the colored band
        border.gloss = border:CreateTexture(nil, "OVERLAY", nil, 5)
        border.gloss:SetHeight(1)
        border.gloss:SetPoint("TOPLEFT", 1, -1); border.gloss:SetPoint("TOPRIGHT", -1, -1)
        border.gloss:SetColorTexture(1, 1, 1, 0.15)

        bar.border = border
        bar._muiCustomBorder = border
    end

    -- Icon: sized to match bar height (square), positioned left of the bar
    local icon = bar.Icon or bar.icon
    if icon then
        icon:ClearAllPoints()
        icon:SetPoint("RIGHT", bar, "LEFT", -STYLE_CAST_ICON_PADDING, 0)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        if not bar.iconBorder then
            bar.iconBorder = CreateFrame("Frame", nil, bar)
            bar.iconBorder:SetAllPoints(icon)
        end
        if not bar.iconBorderBorder then
            bar.iconBorderBorder = CreateBlackBorder(bar.iconBorder, STYLE_BORDER_ALPHA)
        end
    end

    -- Spell name: centered on the bar
    local text = bar.Text or bar.text or bar.Name
    if text then
        text:ClearAllPoints()
        text:SetPoint("CENTER", bar, "CENTER", 0, 0)
        SetFontSafe(text, "Fonts\\FRIZQT__.TTF", STYLE_CAST_FONT_SIZE, "OUTLINE")
        text:SetJustifyH("CENTER")
        text:SetWordWrap(false)
        text:SetShadowOffset(1, -1)
        text:SetShadowColor(0, 0, 0, 0.8)
    end

    -- Cast timer: right-aligned with padding
    local timer = bar.Timer or bar.Time or bar.time
    if timer then
        timer:ClearAllPoints()
        timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
        SetFontSafe(timer, "Fonts\\FRIZQT__.TTF", STYLE_TIMER_FONT_SIZE, "OUTLINE")
        timer:SetJustifyH("RIGHT")
        timer:SetShadowOffset(1, -1)
        timer:SetShadowColor(0, 0, 0, 0.8)
    end

    -- Keep the spark visible — it's part of the cast bar's normal visual

    -- Persistently suppress Blizzard's default border/shield artwork so
    -- it can't bleed through under our custom border.
    SuppressNativeCastBarVisuals(bar)

    if IsManagedCastKind(bar._muiCastKind) or IsManagedCastKind(bar.unit) then
        AttachActiveBorderPulse(bar, bar.border, bar.iconBorderBorder or bar.iconBorder)
        if bar._muiInterruptedVisualActive then
            SetManagedCastBorderColor(bar, INTERRUPTED_BORDER_COLOR)
            SetBorderPulseActive(bar.border, false)
            SetBorderPulseActive(bar.iconBorderBorder or bar.iconBorder, false)
        else
            SetManagedCastBorderColor(bar, PLAYER_CAST_BORDER_COLOR)
            SetBorderPulseActive(bar.border, bar.IsShown and bar:IsShown())
            SetBorderPulseActive(bar.iconBorderBorder or bar.iconBorder, bar.IsShown and bar:IsShown())
        end
    end

end

local function UpdateCastBarTextLayout(bar)
    if not bar then return end
    local barH = SafeNumber(function() return bar:GetHeight() end, 0)

    local text = bar.Text or bar.text or bar.Name
    if text then
        text:ClearAllPoints()
        text:SetPoint("CENTER", bar, "CENTER", 0, 0)
        if text.SetJustifyH then text:SetJustifyH("CENTER") end
        if text.SetJustifyV then text:SetJustifyV("MIDDLE") end
        if text.SetHeight then text:SetHeight(barH) end
    end

    local timer = bar.Timer or bar.Time or bar.time
    if timer then
        timer:ClearAllPoints()
        timer:SetPoint("RIGHT", bar, "RIGHT", -5, 0)
        if timer.SetJustifyV then timer:SetJustifyV("MIDDLE") end
        if timer.SetHeight then timer:SetHeight(barH) end
    end

    -- Size icon to match bar height (square)
    local icon = bar.Icon or bar.icon
    if icon then
        pcall(function()
            icon:SetSize(barH, barH)
        end)
    end
end

local function GetCastContainer(kind)
    local container = castContainers[kind]
    if container then return container end
    local name = "MidnightUI_CastBar_" .. kind
    container = CreateFrame("Frame", name, UIParent)
    container:SetFrameStrata("HIGH")
    container:SetFrameLevel(60)
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(false)
    castContainers[kind] = container
    return container
end

local function EnsureCastBarSettings()
    if not MidnightUISettings then return nil end
    if not MidnightUISettings.CastBars then MidnightUISettings.CastBars = {} end
    if not MidnightUISettings.CastBars.player then MidnightUISettings.CastBars.player = {} end
    if not MidnightUISettings.CastBars.target then MidnightUISettings.CastBars.target = {} end
    if not MidnightUISettings.CastBars.focus then MidnightUISettings.CastBars.focus = {} end

    local p = MidnightUISettings.CastBars.player
    if p.enabled == nil then p.enabled = true end
    if p.width == nil then p.width = 360 end
    if p.height == nil then p.height = 24 end
    if p.scale == nil then p.scale = 100 end
    if p.attachYOffset == nil then p.attachYOffset = -6 end
    if p.matchFrameWidth == nil then p.matchFrameWidth = true end

    local t = MidnightUISettings.CastBars.target
    if t.enabled == nil then t.enabled = true end
    if t.width == nil then t.width = 360 end
    if t.height == nil then t.height = 24 end
    if t.scale == nil then t.scale = 100 end
    if t.attachYOffset == nil then t.attachYOffset = -6 end
    if t.matchFrameWidth == nil then t.matchFrameWidth = true end

    local f = MidnightUISettings.CastBars.focus
    if f.enabled == nil then f.enabled = true end
    if f.width == nil then f.width = 320 end
    if f.height == nil then f.height = 20 end
    if f.scale == nil then f.scale = 100 end
    if f.attachYOffset == nil then f.attachYOffset = -6 end
    if f.matchFrameWidth == nil then f.matchFrameWidth = false end

    if p.height == 20 and t.height and t.height ~= 20 and p._muiHeightSynced ~= true then
        p.height = t.height
        p._muiHeightSynced = true
    end

    return MidnightUISettings.CastBars
end

local function GetCastBar(kind)
    if kind == "player" then
        return _G.PlayerCastingBarFrame or _G.CastingBarFrame
    end
    if kind == "target" then
        return _G.TargetFrameSpellBar or (_G.TargetFrame and _G.TargetFrame.spellbar)
    end
    if kind == "focus" then
        return _G.FocusFrameSpellBar or (_G.FocusFrame and _G.FocusFrame.spellbar)
    end
    return nil
end

local function GetOwner(kind)
    if kind == "player" then
        return playerOwner or _G.MidnightUI_PlayerFrame
    end
    if kind == "target" then
        return targetOwner or _G.MidnightUI_TargetFrame
    end
    if kind == "focus" then
        return focusOwner or _G.MidnightUI_FocusFrame
    end
    return nil
end

local function SaveCastBarPosition(container, settings)
    if not container or not settings then return end
    local point, _, relativePoint, xOfs, yOfs = container:GetPoint()
    if not point or not relativePoint then return end
    local s = container:GetScale()
    if not s or s == 0 then s = 1 end
    settings.position = { point, relativePoint, xOfs / s, yOfs / s }
end

local function ApplyCastBarPosition(kind, bar, settings)
    if not bar or not settings then return end
    local container = GetCastContainer(kind)
    if container and container._muiIsDragging then
        return
    end
    if settings.position and #settings.position >= 4 and _G.MidnightUI_ApplyOverlayPosition then
        _G.MidnightUI_ApplyOverlayPosition(container, settings.position)
        return
    end

    container:ClearAllPoints()
    local owner = GetOwner(kind) or UIParent
    local y = settings.attachYOffset or -6
    container:SetPoint("TOPLEFT", owner, "BOTTOMLEFT", 0, y)
end

local function ApplyCastBarSizing(kind, bar, settings)
    if not bar or not settings then return end
    local container = GetCastContainer(kind)
    local owner = GetOwner(kind)
    local width = settings.width
    local scalePct = settings.scale or 100
    if settings.matchFrameWidth and owner and owner.GetWidth then
        local ownerWidth = SafeNumber(function() return owner:GetWidth() end, 0)
        if ownerWidth > 0 then
            width = ownerWidth
        end
        if scalePct > 100 then scalePct = 100 end
    end

    -- One-time reset: undo modifications from previous code iterations.
    -- Restores all Blizzard textures to their natural dimensions/scale
    -- so we can re-capture clean baseline values.
    if not bar._muiDecorV3 then
        bar._muiDecorV3 = true
        bar._muiNaturalHeight = nil
        bar._muiNaturalWidth = nil
        pcall(function()
            local regions = { bar:GetRegions() }
            for _, r in ipairs(regions) do
                if r._muiNaturalScale then pcall(r.SetScale, r, r._muiNaturalScale) end
                if r._muiNaturalW and r._muiNaturalH then
                    pcall(r.SetSize, r, r._muiNaturalW, r._muiNaturalH)
                end
                r._muiNaturalW = nil
                r._muiNaturalH = nil
                r._muiNaturalScale = nil
                r._muiOrigH = nil
                r._muiOrigW = nil
            end
        end)
    end

    -- Capture the bar's natural (Blizzard template) dimensions on first encounter.
    if not bar._muiNaturalHeight then
        local curScale = SafeNumber(function() return bar:GetScale() end, 1)
        if curScale ~= 1 then pcall(bar.SetScale, bar, 1) end
        local h = SafeNumber(function() return bar:GetHeight() end, 0)
        local w = SafeNumber(function() return bar:GetWidth() end, 0)
        if h <= 0 then h = 20 end
        if w <= 0 then w = 208 end
        bar._muiNaturalHeight = h
        bar._muiNaturalWidth = w
    end
    local naturalH = bar._muiNaturalHeight
    local naturalW = bar._muiNaturalWidth
    local desiredH = settings.height or naturalH

    -- Set bar dimensions directly. The StatusBar engine handles the fill
    -- texture, and MUI's text/borders are designed for pixel sizes.
    if width and bar.SetWidth then pcall(bar.SetWidth, bar, width) end
    if desiredH and bar.SetHeight then pcall(bar.SetHeight, bar, desiredH) end
    if bar.SetScale then pcall(bar.SetScale, bar, 1) end

    -- Proportionally resize Blizzard's decorative textures (spark, trail glow,
    -- flash). Height scales by the height ratio. Width scales by the width
    -- ratio for background/glow textures so they still cover the full bar.
    -- The spark is the exception: its width stays thin (only height scales).
    local scaleH = desiredH / naturalH
    local scaleW = width / naturalW
    if scaleH <= 0 then scaleH = 1 end
    if scaleW <= 0 then scaleW = 1 end

    pcall(function()
        local statusTex = bar.GetStatusBarTexture and bar:GetStatusBarTexture()
        local spark = bar.Spark or bar.spark
        local regions = { bar:GetRegions() }
        for _, r in ipairs(regions) do
            -- Skip: MUI-created regions, the fill texture, and FontStrings
            if r == bar.bg then                              -- MUI background
            elseif r == statusTex then                       -- engine-managed fill
            elseif bar._muiCornerCut and (
                       r == bar._muiCornerCut.tl or
                       r == bar._muiCornerCut.tr or
                       r == bar._muiCornerCut.bl or
                       r == bar._muiCornerCut.br) then       -- MUI corner cuts
            else
                local objType = r.GetObjectType and r:GetObjectType()
                if objType == "Texture" or objType == "MaskTexture" then
                    -- Capture natural dimensions on first encounter
                    if not r._muiOrigH then
                        r._muiOrigH = SafeNumber(function() return r:GetHeight() end, 0)
                        r._muiOrigW = SafeNumber(function() return r:GetWidth() end, 0)
                    end
                    -- Height always scales proportionally
                    if r._muiOrigH > 0 then
                        pcall(r.SetHeight, r, r._muiOrigH * scaleH)
                    end
                    -- Width scales for all textures EXCEPT the spark
                    -- (spark stays thin; glow/trail textures need to cover the bar)
                    if r ~= spark and r._muiOrigW > 0 then
                        pcall(r.SetWidth, r, r._muiOrigW * scaleW)
                    end
                end
            end
        end
    end)

    -- Container gets the user's scale percentage.
    local containerScale = scalePct / 100
    if container and container.SetScale then container:SetScale(containerScale) end

    if container and container.SetSize then
        container:SetSize(width, desiredH)
    end

end

local function EnsureCastBarOverlay(kind, bar)
    if not bar then return end
    local container = GetCastContainer(kind)
    if not container or container.dragOverlay then
        if container and container.dragOverlay then
            bar.dragOverlay = container.dragOverlay
        end
        return
    end
    container:SetMovable(true)
    container:SetClampedToScreen(true)
    container:EnableMouse(true)

    local overlay = CreateFrame("Frame", nil, container, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("DIALOG")
    overlay:SetFrameLevel((container:GetFrameLevel() or 0) + 10)
    if _G.MidnightUI_StyleOverlay then
        _G.MidnightUI_StyleOverlay(overlay, nil, nil, "cast")
    else
        overlay:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 } })
        overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
        overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
    end

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    label:SetPoint("CENTER")
    if kind == "player" then
        label:SetText("PLAYER CAST BAR")
    elseif kind == "target" then
        label:SetText("TARGET CAST BAR")
    else
        label:SetText("FOCUS CAST BAR")
    end
    label:SetTextColor(1, 1, 1)

    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function()
        if IsInCombatState() then return end
        container._muiIsDragging = true
        container:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        if not container._muiIsDragging then return end
        container:StopMovingOrSizing()
        container._muiIsDragging = false
        local currentSettings = EnsureCastBarSettings()
        if currentSettings and currentSettings[kind] then
            SaveCastBarPosition(container, currentSettings[kind])
        end
    end)
    overlay:SetScript("OnHide", function()
        if container._muiIsDragging then
            container:StopMovingOrSizing()
            container._muiIsDragging = false
            local currentSettings = EnsureCastBarSettings()
            if currentSettings and currentSettings[kind] then
                SaveCastBarPosition(container, currentSettings[kind])
            end
        end
    end)

    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "CastBar_" .. kind)
    end
    container.dragOverlay = overlay
    bar.dragOverlay = overlay
end

local function ApplyCastBarState(kind)
    local settings = EnsureCastBarSettings()
    if not settings then return end
    local s = settings[kind]
    local bar = GetCastBar(kind)
    if not bar or not s then return end
    if bar.IsForbidden and bar:IsForbidden() then return end
    bar._muiCastKind = kind
    local container = GetCastContainer(kind)
    if kind == "player" and IsInCombatState() then
        QueuePlayerCastBarApply()
        if container and container.dragOverlay then
            container.dragOverlay:Hide()
        end
        return
    end
    if kind == "player" then
        ClearQueuedPlayerCastBarApply()
    end

    if s.enabled == false then
        if container and container.dragOverlay then container.dragOverlay:Hide() end
        if container then container:Hide() end
        bar:SetAlpha(0)
        bar:Hide()
        return
    end

    local owner = GetOwner(kind) or UIParent
    if bar.SetParent and container and not IsInCombatState() then
        pcall(function()
            if bar:GetParent() ~= container then
                bar:SetParent(container)
            end
        end)
    end

    if kind == "player" then
        pcall(function()
            bar:SetMovable(true)
            bar:SetClampedToScreen(true)
            if bar.SetUserPlaced then bar:SetUserPlaced(true) end
            bar.ignoreFramePositionManager = true
        end)
        if UIParentManagedFramePositions and UIParentManagedFramePositions[bar] then
            UIParentManagedFramePositions[bar] = nil
        end
    end

    ApplyCastBarSizing(kind, bar, s)
    ApplyCastBarPosition(kind, bar, s)
    if container then
        container:Show()
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
    end
    bar:SetAlpha(1)
    ApplyNameplateCastVisualStyle(bar)
    UpdateCastBarTextLayout(bar)

    -- Adapt border thickness to bar height so it looks substantial on
    -- large bars but doesn't overwhelm small ones.
    if bar.border then
        local barH = SafeNumber(function() return bar:GetHeight() end, 20)
        local band = barH >= 20 and 3 or 2
        if bar.border.top then bar.border.top:SetHeight(band) end
        if bar.border.bottom then bar.border.bottom:SetHeight(band) end
        if bar.border.left then bar.border.left:SetWidth(band) end
        if bar.border.right then bar.border.right:SetWidth(band) end
    end

    if lastLockedState == false then
        EnsureCastBarOverlay(kind, bar)
        if container and container.dragOverlay then
            container.dragOverlay:Show()
        end
    else
        if container and container.dragOverlay then container.dragOverlay:Hide() end
    end
end

local function ApplyAllCastBars()
    ApplyCastBarState("player")
    ApplyCastBarState("target")
    ApplyCastBarState("focus")
end

function _G.MidnightUI_AttachPlayerCastBar(ownerFrame)
    playerOwner = ownerFrame
    ApplyCastBarState("player")
end

function _G.MidnightUI_AttachTargetCastBar(ownerFrame)
    targetOwner = ownerFrame
    ApplyCastBarState("target")
end

function _G.MidnightUI_AttachFocusCastBar(ownerFrame)
    focusOwner = ownerFrame
    ApplyCastBarState("focus")
end

function _G.MidnightUI_SetCastBarsLocked(locked)
    lastLockedState = locked
    ApplyAllCastBars()
end

function _G.MidnightUI_ApplyCastBarSettings()
    local locked = true
    if MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked ~= nil then
        locked = MidnightUISettings.Messenger.locked
    end
    lastLockedState = locked
    ApplyAllCastBars()
end

local function BuildCastBarOverlaySettings(content, key, kind)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureCastBarSettings()
    if not s or not s[kind] then return end
    local cfg = s[kind]
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Cast Bar")
    b:Checkbox("Enable", cfg.enabled ~= false, function(v)
        cfg.enabled = v
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        RefreshOverlayByKey(key)
    end)

    local function GetBaseWidth()
        local baseWidth = cfg.width or 360
        if cfg.matchFrameWidth then
            local owner = GetOwner(kind)
            if owner and owner.GetWidth then
                local ownerWidth = owner:GetWidth()
                if ownerWidth and ownerWidth > 0 then
                    baseWidth = ownerWidth
                end
            end
        end
        return baseWidth
    end

    local function UpdateScaleRange(slScale)
        if not slScale then return end
        if cfg.matchFrameWidth then
            slScale:SetMinMaxValues(50, 100)
            if (cfg.scale or 100) > 100 then
                cfg.scale = 100
                slScale:SetValue(100)
            end
            return
        end
        local baseWidth = GetBaseWidth()
        if not baseWidth or baseWidth <= 0 then baseWidth = 700 end
        local maxScale = math.floor((700 / baseWidth) * 100)
        maxScale = math.max(50, math.min(200, maxScale))
        slScale:SetMinMaxValues(50, maxScale)
        if (cfg.scale or 100) > maxScale then
            cfg.scale = maxScale
            slScale:SetValue(maxScale)
        end
    end

    local slScale = b:Slider("Scale %", 50, 200, 5, cfg.scale or 100, function(v)
        cfg.scale = math.floor(v)
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        RefreshOverlayByKey(key)
    end)
    local slWidth = b:Slider("Width", 200, 700, 5, cfg.width or 360, function(v)
        cfg.width = math.floor(v)
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        UpdateScaleRange(slScale)
        RefreshOverlayByKey(key)
    end)
    b:Slider("Height", 8, 60, 1, cfg.height or 20, function(v)
        cfg.height = math.floor(v)
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Slider("Y Offset", -60, 60, 1, cfg.attachYOffset or -6, function(v)
        cfg.attachYOffset = math.floor(v)
        cfg.position = nil
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        RefreshOverlayByKey(key)
    end)
    b:Checkbox("Match Frame Width", cfg.matchFrameWidth == true, function(v)
        cfg.matchFrameWidth = v
        if _G.MidnightUI_ApplyCastBarSettings then _G.MidnightUI_ApplyCastBarSettings() end
        RefreshOverlayByKey(key)
        if _G.MidnightUI_ShowOverlaySettings then
            _G.MidnightUI_ShowOverlaySettings(key)
        end
    end)
    if cfg.matchFrameWidth == true and slWidth then slWidth:Hide() end
    UpdateScaleRange(slScale)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("CastBar_player", {
        title = "Player Cast Bar",
        build = function(content, key) return BuildCastBarOverlaySettings(content, key, "player") end
    })
    _G.MidnightUI_RegisterOverlaySettings("CastBar_target", {
        title = "Target Cast Bar",
        build = function(content, key) return BuildCastBarOverlaySettings(content, key, "target") end
    })
    _G.MidnightUI_RegisterOverlaySettings("CastBar_focus", {
        title = "Focus Cast Bar",
        build = function(content, key) return BuildCastBarOverlaySettings(content, key, "focus") end
    })
end

CastBarManager:RegisterEvent("ADDON_LOADED")
CastBarManager:RegisterEvent("PLAYER_ENTERING_WORLD")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_START", "player", "target", "focus")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player", "target", "focus")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "target", "focus")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "target", "focus")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player", "target", "focus")
CastBarManager:RegisterUnitEvent("UNIT_SPELLCAST_FAILED_QUIET", "player", "target", "focus")
CastBarManager:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local addonName = ...
        if addonName ~= ADDON_NAME then return end
        EnsureCastBarSettings()
        _G.MidnightUI_ApplyCastBarSettings()
        return
    end
    if event == "PLAYER_ENTERING_WORLD" then
        EnsureCastBarSettings()
        _G.MidnightUI_ApplyCastBarSettings()
        return
    end
    if event == "PLAYER_REGEN_ENABLED" then
        if pendingPlayerCastBarApply then
            ClearQueuedPlayerCastBarApply()
            _G.MidnightUI_ApplyCastBarSettings()
        else
            self:UnregisterEvent("PLAYER_REGEN_ENABLED")
        end
        return
    end
    if event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
        local unit = ...
        local kind = GetManagedCastKindForUnit(unit)
        if not kind then return end
        local bar = GetCastBar(kind)
        SetManagedInterruptedBorderState(kind, bar, false)
        return
    end
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local unit = ...
        local kind = GetManagedCastKindForUnit(unit)
        if not kind then return end
        local bar = GetCastBar(kind)
        if bar and bar:IsShown() then
            PlayManagedCastSuccessPulse(bar)
        end
        return
    end
    if event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" or event == "UNIT_SPELLCAST_FAILED_QUIET" then
        local unit = ...
        local kind = GetManagedCastKindForUnit(unit)
        if not kind then return end
        local bar = GetCastBar(kind)
        if event == "UNIT_SPELLCAST_FAILED_QUIET" and ShouldSuppressFailedQuiet(bar) then
            return
        end
        SetManagedInterruptedBorderState(kind, bar, true)
    end
end)
