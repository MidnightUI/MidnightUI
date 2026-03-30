-- =============================================================================
-- FILE PURPOSE:     Custom minimap skin. Replaces the default minimap chrome with a
--                   square frame (no round mask), hides Blizzard's built-in buttons
--                   (zoom in/out, compass, zone text, LFG queue status), and attaches
--                   an info bar below the map with zone name, coords, and time. Supports
--                   Class Color / Faithful / Glass / Default theme variants.
-- LOAD ORDER:       Loads after LootWindow.lua, before MidnightWeeklyTracker.lua. Module initializes at PLAYER_LOGIN to
--                   ensure Minimap and related globals exist before touching them.
-- DEFINES:          No exported globals. All state is file-local.
-- READS:            MidnightUISettings.Minimap.{enabled, scale, shape, infoBar, theme,
--                   showCoords, showTime, showZone, position}.
-- WRITES:           MidnightUISettings.Minimap.position (on drag stop).
--                   Minimap: SetParent, ClearAllPoints, SetSize, SetMaskTexture — re-parents
--                   Minimap into the custom container. RestoreDefaultMinimap() undoes all.
-- DEPENDS ON:       MidnightUI_Core.GetClassColorTable (for CLASS_COLOR accent in info bar).
--                   MidnightUI_StyleOverlay, MidnightUI_AttachOverlaySettings (Core.lua).
-- USED BY:          Settings_UI.lua (exposes minimap settings controls).
-- KEY FLOWS:
--   PLAYER_LOGIN → CacheMinimapDefaults() → SetDefaultMinimapFramesHidden(true) →
--                  BuildMinimapContainer() → reparent Minimap into custom frame
--   MINIMAP_UPDATE_ZOOM → update info bar coords/zone (if enabled)
--   PLAYER_ENTERING_WORLD → refresh zone name in info bar
--   MidnightUI_ApplyMinimapSettings() → called by Settings.lua Apply* chain
-- GOTCHAS:
--   CacheMinimapDefaults() must run before any Minimap modification so
--   RestoreDefaultMinimap() can fully undo all changes when feature is disabled.
--   framesToHide: list of Blizzard frames suppressed; their Show method is replaced
--   with a no-op so addons that call MinimapZoomIn:Show() don't break the layout.
--   SetDefaultMinimapFramesHidden(false) restores the original Show method before un-hiding.
--   CLASS_COLOR: lightened 20% via LightenColor() for readability on the info bar dark bg.
--   GetInfoBarTheme(): four theme variants with distinct bg/strip/text color schemes.
-- NAVIGATION:
--   GetInfoBarTheme()           — theme → {bg, header, strip, text} colors (line ~21)
--   framesToHide[]              — Blizzard elements suppressed by the skin (line ~57)
--   CacheMinimapDefaults()      — captures original Minimap state for restoration (line ~65)
--   SetDefaultMinimapFramesHidden() — hides/restores Blizzard minimap chrome
--   RestoreDefaultMinimap()     — full rollback of all Minimap changes
--   BuildMinimapContainer()     — constructs the custom square frame + info bar
-- =============================================================================

local addonName, ns = ...

-- 1. CONFIG & COLORS
local _, classFilename = UnitClass("player")
local c = (_G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable and _G.MidnightUI_Core.GetClassColorTable(classFilename))
    or C_ClassColor.GetClassColor(classFilename)

-- Helper: Lighten color for text readability against dark backgrounds
local function LightenColor(r, g, b, factor)
    return r + (1 - r) * factor, g + (1 - g) * factor, b + (1 - b) * factor
end

-- Bright Class Color (20% lighter)
local br, bg, bb = LightenColor(c.r, c.g, c.b, 0.2)
local CLASS_COLOR = {br, bg, bb} 

local function GetInfoBarTheme(style)
    if style == "Class Color" then
        return {
            bg = {c.r * 0.08, c.g * 0.08, c.b * 0.08, 0.92},
            header = {c.r * 0.05, c.g * 0.05, c.b * 0.05, 0.85},
            strip = {c.r, c.g, c.b, 1},
            text = {LightenColor(c.r, c.g, c.b, 0.45)},
        }
    elseif style == "Faithful" then
        return {
            bg = {0.16, 0.13, 0.10, 0.92},
            header = {0.11, 0.09, 0.07, 0.85},
            strip = {0.78, 0.69, 0.52, 1},
            text = {0.90, 0.86, 0.78},
        }
    elseif style == "Glass" then
        return {
            bg = {0.06, 0.08, 0.12, 0.7},
            header = {0.03, 0.04, 0.06, 0.6},
            strip = {0.6, 0.8, 1, 1},
            text = {0.75, 0.85, 1},
        }
    end

    return {
        bg = {0.04, 0.04, 0.08, 0.95},
        header = {0, 0, 0, 0.4},
        strip = {CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 1},
        text = {CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3]},
    }
end

local minimapDefaults = { cached = false }
local trackingButton = nil
local trackingDefaults = nil
local frameShowBackup = {}
local framesToHide = {
    "MinimapZoomIn", "MinimapZoomOut",
    "MinimapNorthTag", "MinimapZoneTextButton", "MiniMapWorldMapButton",
    "GameTimeFrame", "MinimapCluster",
    "MinimapZoneText", "MinimapTopBorder", "MinimapBackdrop",
    "MiniMapTrackingFrame", "QueueStatusMinimapButton"
}

local function CacheMinimapDefaults()
    if minimapDefaults.cached then return end
    minimapDefaults.cached = true
    minimapDefaults.parent = Minimap:GetParent()
    minimapDefaults.points = { Minimap:GetPoint() }
    minimapDefaults.width, minimapDefaults.height = Minimap:GetSize()
    if Minimap.GetMaskTexture then
        minimapDefaults.mask = Minimap:GetMaskTexture()
    else
        minimapDefaults.mask = "Textures\\MinimapMask"
    end
    minimapDefaults.scale = Minimap:GetScale()
    minimapDefaults.zoomInAlpha = MinimapZoomIn and MinimapZoomIn:GetAlpha() or 1
    minimapDefaults.zoomOutAlpha = MinimapZoomOut and MinimapZoomOut:GetAlpha() or 1
    minimapDefaults.compassAlpha = MinimapCompassTexture and MinimapCompassTexture:GetAlpha() or 1
end

local function SetFrameHidden(frameName, hide)
    local f = _G[frameName]
    if not f then return end
    if hide then
        if not frameShowBackup[frameName] then frameShowBackup[frameName] = f.Show end
        f:Hide()
        f.Show = function() end
    else
        if frameShowBackup[frameName] then f.Show = frameShowBackup[frameName]; frameShowBackup[frameName] = nil end
        f:Show()
    end
end

local function SetDefaultMinimapFramesHidden(hide)
    CacheMinimapDefaults()
    for _, v in ipairs(framesToHide) do
        SetFrameHidden(v, hide)
    end
    if MinimapZoomIn then
        MinimapZoomIn:SetAlpha(hide and 0 or minimapDefaults.zoomInAlpha or 1)
        if not hide then MinimapZoomIn:Show() end
    end
    if MinimapZoomOut then
        MinimapZoomOut:SetAlpha(hide and 0 or minimapDefaults.zoomOutAlpha or 1)
        if not hide then MinimapZoomOut:Show() end
    end
    if Minimap.ZoomIn then Minimap.ZoomIn:SetAlpha(hide and 0 or minimapDefaults.zoomInAlpha or 1) end
    if Minimap.ZoomOut then Minimap.ZoomOut:SetAlpha(hide and 0 or minimapDefaults.zoomOutAlpha or 1) end
    -- Keep MinimapCompassTexture visible when we use it as the minimap artwork.
end

local function RestoreDefaultMinimap()
    CacheMinimapDefaults()
    Minimap:SetParent(minimapDefaults.parent or UIParent)
    Minimap:ClearAllPoints()
    if minimapDefaults.points[1] then
        Minimap:SetPoint(unpack(minimapDefaults.points))
    end
    if minimapDefaults.width and minimapDefaults.height then
        Minimap:SetSize(minimapDefaults.width, minimapDefaults.height)
    end
    if Minimap.SetMaskTexture then
        Minimap:SetMaskTexture(minimapDefaults.mask or "Textures\\MinimapMask")
    end
    if minimapDefaults.scale then Minimap:SetScale(minimapDefaults.scale) end

    if trackingButton and trackingDefaults then
        trackingButton:SetParent(trackingDefaults.parent or UIParent)
        trackingButton:ClearAllPoints()
        if trackingDefaults.points[1] then trackingButton:SetPoint(unpack(trackingDefaults.points)) end
        if trackingDefaults.width and trackingDefaults.height then trackingButton:SetSize(trackingDefaults.width, trackingDefaults.height) end
        if trackingDefaults.scale then trackingButton:SetScale(trackingDefaults.scale) end
        if trackingDefaults.alpha then trackingButton:SetAlpha(trackingDefaults.alpha) end
        if trackingDefaults.shown then trackingButton:Show() else trackingButton:Hide() end
    end
end


-- 2. UTILITY: CREATE BORDER
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
    return border
end

local function SkinTooltip()
    if GameTooltip.NineSlice then
        GameTooltip.NineSlice:SetCenterColor(0.05, 0.05, 0.1, 0.95)
        GameTooltip.NineSlice:SetBorderColor(0, 0, 0, 1)
    end
end

local function GetFormattedTime(h, m)
    local pm = (h >= 12) and "PM" or "AM"
    if h > 12 then h = h - 12 elseif h == 0 then h = 12 end
    return format("%d:%.2d %s", h, m, pm)
end

local function GetZoneTypeLabel()
    local pvpType = GetZonePVPInfo()
    if (not pvpType or pvpType == "") and C_PvP and C_PvP.GetZonePVPInfo then
        local ok, info = pcall(C_PvP.GetZonePVPInfo)
        if ok and info and info ~= "" then pvpType = info end
    end
    local label = nil
    local color = {r=0.8, g=0.8, b=0.8}
    if C_PvP and C_PvP.IsInNoFlyZone and C_PvP.IsInNoFlyZone() then
        label = "No-fly Zone"
        color = {r=1, g=0.5, b=0.2}
    elseif pvpType and pvpType ~= "" then
        if pvpType == "sanctuary" then
            label = "Sanctuary"
            color = {r=0.41, g=0.8, b=0.94}
        elseif pvpType == "arena" then
            label = "Combat Zone"
            color = {r=1, g=0.1, b=0.1}
        elseif pvpType == "combat" then
            label = "Combat Zone"
            color = {r=1, g=0.5, b=0}
        elseif pvpType == "contested" then
            label = "Contested"
            color = {r=1, g=0.7, b=0}
        elseif pvpType == "friendly" or pvpType == "hostile" then
            local faction = UnitFactionGroup("player")
            if pvpType == "friendly" then
                label = (faction == "Horde") and "Horde" or "Alliance"
                color = {r=0.1, g=1, b=0.1}
            else
                label = (faction == "Horde") and "Alliance" or "Horde"
                color = {r=1, g=0.1, b=0.1}
            end
        else
            label = pvpType:sub(1,1):upper() .. pvpType:sub(2):lower()
        end
    end
    if not label then return nil, nil end
    return label, color
end

local function GetGradualColor(percent)
    if percent > 0.5 then
        return (1 - percent) * 2, 1, 0
    else
        return 1, percent * 2, 0
    end
end

-- =========================================================================
--  3. MINIMAP CLUSTER & SHAPE
-- =========================================================================

local Cluster = CreateFrame("Frame", "MidnightUI_MinimapCluster", UIParent)
Cluster:SetSize(210, 245)
Cluster:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -25, -25)
local minimapLocked = true
local MailIcon = nil
Cluster:SetMovable(true)
Cluster:EnableMouse(true)
Cluster:RegisterForDrag("LeftButton")
Cluster:SetClampedToScreen(true)
Cluster:SetScript("OnDragStart", function(self)
    if minimapLocked then return end
    if InCombatLockdown and InCombatLockdown() then return end
    self:StartMoving()
end)
Cluster:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
end)

local MapBackdrop = CreateFrame("Frame", nil, Cluster, "BackdropTemplate")
MapBackdrop:SetPoint("TOP", 0, 0)
MapBackdrop:SetSize(210, 210)
MapBackdrop:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
})
MapBackdrop:SetBackdropColor(0, 0, 0, 0)
MapBackdrop:SetBackdropBorderColor(0, 0, 0, 0)

function MidnightUI_InitMinimap()
    CacheMinimapDefaults()
    Minimap:SetParent(Cluster)
    Minimap:ClearAllPoints()
    Minimap:SetPoint("CENTER", MapBackdrop, "CENTER", 0, 0)
    Minimap:SetSize(196, 196)
    -- Use a Blizzard circular portrait mask instead of the default minimap mask (which hides the map on this setup).
    Minimap:SetMaskTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    if Minimap.MidnightUIRing then
        Minimap.MidnightUIRing:Hide()
        Minimap.MidnightUIRing = nil
    end
    Minimap:SetArchBlobRingScalar(0)
    Minimap:SetQuestBlobRingScalar(0)
    Minimap:SetAlpha(1)
    Minimap:Show()
    
    Minimap:EnableMouseWheel(true)
    Minimap:SetScript("OnMouseWheel", function(self, delta)
        if delta > 0 then Minimap_ZoomIn() else Minimap_ZoomOut() end
    end)

    SetDefaultMinimapFramesHidden(true)
    if MinimapCompassTexture then
        MinimapCompassTexture:SetParent(Minimap)
        MinimapCompassTexture:ClearAllPoints()
        MinimapCompassTexture:SetPoint("CENTER", Minimap, "CENTER", 0, 0)
        MinimapCompassTexture:SetSize(Minimap:GetWidth() + 30, Minimap:GetHeight() + 30)
        if MinimapCompassTexture.SetDrawLayer then
            MinimapCompassTexture:SetDrawLayer("OVERLAY", 7)
        end
        if MinimapCompassTexture.SetBlendMode then
            MinimapCompassTexture:SetBlendMode("BLEND")
        end
        MinimapCompassTexture:SetAlpha(1)
        MinimapCompassTexture:Show()
    end

    trackingButton = (MinimapCluster and MinimapCluster.Tracking and MinimapCluster.Tracking.Button) or _G.MiniMapTracking or Minimap.TrackingButton
    if trackingButton then
        if not trackingDefaults then
            trackingDefaults = {
                parent = trackingButton:GetParent(),
                points = { trackingButton:GetPoint() },
                width = trackingButton:GetWidth(),
                height = trackingButton:GetHeight(),
                scale = trackingButton:GetScale(),
                alpha = trackingButton:GetAlpha(),
                shown = trackingButton:IsShown()
            }
        end
        trackingButton:SetParent(Cluster)
        trackingButton:ClearAllPoints()
        trackingButton:SetPoint("BOTTOMLEFT", Minimap, "BOTTOMLEFT", -2, -2)
        trackingButton:SetSize(24, 24)
        trackingButton:SetScale(1.0)
        trackingButton:SetAlpha(1)
        trackingButton:Show()
        
        local bg = trackingButton:GetRegions() 
        if bg and bg.SetTexture then bg:SetAlpha(0) end
        
        local icon = trackingButton:GetNormalTexture()
        if icon then 
            icon:ClearAllPoints()
            icon:SetPoint("CENTER", trackingButton, "CENTER", 0, 0)
            icon:SetSize(18, 18)
            icon:SetAlpha(1)
        end
        
        -- Keep above the minimap but below high/tooltip windows (e.g. bags).
        local baseLevel = (Minimap and Minimap.GetFrameLevel and Minimap:GetFrameLevel()) or 0
        trackingButton:SetFrameStrata("MEDIUM")
        trackingButton:SetFrameLevel(baseLevel + 8)
        trackingButton:EnableMouse(true)
    end
end

-- =========================================================================
--  4. INFO BAR
-- =========================================================================

local InfoBar = CreateFrame("Frame", "MidnightUI_InfoBar", Cluster, "BackdropTemplate")
InfoBar:SetSize(210, 50) 
InfoBar:SetPoint("TOP", MapBackdrop, "BOTTOM", 0, -5) 
InfoBar:SetMovable(true)
InfoBar:SetClampedToScreen(true)

InfoBar.bg = InfoBar:CreateTexture(nil, "BACKGROUND")
InfoBar.bg:SetAllPoints()
InfoBar.bg:SetColorTexture(0.04, 0.04, 0.08, 0.95)

InfoBar.header = InfoBar:CreateTexture(nil, "ARTWORK")
InfoBar.header:SetHeight(24) 
InfoBar.header:SetPoint("TOPLEFT", InfoBar, "TOPLEFT", 0, 0)
InfoBar.header:SetPoint("TOPRIGHT", InfoBar, "TOPRIGHT", 0, 0)
InfoBar.header:SetColorTexture(0, 0, 0, 0.4) 

if CreateBorder then CreateBorder(InfoBar, 0, 0, 0, 1) end

InfoBar.strip = InfoBar:CreateTexture(nil, "OVERLAY")
InfoBar.strip:SetHeight(2)
InfoBar.strip:SetPoint("BOTTOMLEFT", InfoBar, "BOTTOMLEFT", 1, 1) 
InfoBar.strip:SetPoint("BOTTOMRIGHT", InfoBar, "BOTTOMRIGHT", -1, 1)
InfoBar.strip:SetColorTexture(unpack(CLASS_COLOR))

local infoPanelLocked = true
local RefreshMailIconState = nil
local ApplyMailIconPosition = nil

local function EnsureMinimapSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.Minimap then MidnightUISettings.Minimap = {} end
    local s = MidnightUISettings.Minimap
    if s.enabled == nil then s.enabled = true end
    if not s.scale then s.scale = 100 end
    if s.infoPanelEnabled == nil then s.infoPanelEnabled = true end
    if not s.infoPanelScale then s.infoPanelScale = 100 end
    return s
end

local function IsMinimapEnabled()
    return EnsureMinimapSettings().enabled ~= false
end

local function GetMinimapScale()
    local scale = tonumber(EnsureMinimapSettings().scale) or 100
    if scale < 60 then scale = 60 end
    if scale > 150 then scale = 150 end
    return scale
end

local function SaveMinimapPosition()
    local s = EnsureMinimapSettings()
    local point, _, relativePoint, xOfs, yOfs = Cluster:GetPoint()
    if not point or not relativePoint or not xOfs or not yOfs then return end
    local scale = Cluster:GetScale()
    if not scale or scale == 0 then scale = 1 end
    s.position = { point, relativePoint, xOfs / scale, yOfs / scale }
end

local function ApplyMinimapPosition()
    local s = EnsureMinimapSettings()
    Cluster:ClearAllPoints()
    if s.position and #s.position >= 4 then
        local scale = Cluster:GetScale()
        if not scale or scale == 0 then scale = 1 end
        local point = s.position[1]
        local relativePoint = s.position[2]
        local x = (s.position[3] or 0) * scale
        local y = (s.position[4] or 0) * scale
        Cluster:SetPoint(point, UIParent, relativePoint, x, y)
        return
    end
    Cluster:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -25, -25)
end

local function EnsureMinimapDragOverlay()
    if Cluster.dragOverlay then return end
    local overlay = CreateFrame("Button", nil, Cluster, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel((Cluster:GetFrameLevel() or 1) + 20)
    overlay:EnableMouse(true)
    overlay:RegisterForClicks("AnyUp")
    overlay:RegisterForDrag("LeftButton")
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    overlay:SetBackdropColor(0.04, 0.07, 0.11, 0.30)
    overlay:SetBackdropBorderColor(0.22, 0.54, 0.72, 0.90)

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER", 0, 0)
    label:SetText("Minimap")
    label:SetTextColor(0.88, 0.94, 1.0)
    overlay._muiLabel = label

    overlay:SetScript("OnDragStart", function()
        if minimapLocked then return end
        if InCombatLockdown and InCombatLockdown() then return end
        Cluster:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        Cluster:StopMovingOrSizing()
        SaveMinimapPosition()
    end)

    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "Minimap")
    end

    Cluster.dragOverlay = overlay
end

local function RefreshMinimapOverlayState()
    EnsureMinimapDragOverlay()
    if not Cluster.dragOverlay then return end
    if minimapLocked then
        Cluster.dragOverlay:Hide()
    else
        Cluster.dragOverlay:Show()
    end
end

local function GetInfoPanelScale()
    local scale = tonumber(EnsureMinimapSettings().infoPanelScale) or 100
    if scale < 60 then scale = 60 end
    if scale > 150 then scale = 150 end
    return scale
end

local function SaveInfoPanelPosition()
    local s = EnsureMinimapSettings()
    local scale = InfoBar:GetEffectiveScale()
    if not scale or scale == 0 then scale = 1 end
    local left, bottom = InfoBar:GetLeft(), InfoBar:GetBottom()
    if not left or not bottom then return end
    -- Store absolute screen position (scale-independent)
    s.infoPanelPosition = { left / scale, bottom / scale }
end

local function ApplyInfoPanelPosition()
    local s = EnsureMinimapSettings()
    InfoBar:ClearAllPoints()
    if s.infoPanelPosition and #s.infoPanelPosition >= 2
        and type(s.infoPanelPosition[1]) == "number"
        and type(s.infoPanelPosition[2]) == "number" then
        local scale = InfoBar:GetEffectiveScale()
        if not scale or scale == 0 then scale = 1 end
        local x = s.infoPanelPosition[1] * scale
        local y = s.infoPanelPosition[2] * scale
        InfoBar:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", x, y)
        return
    end
    -- Clear legacy format or invalid data
    s.infoPanelPosition = nil
    InfoBar:SetPoint("TOP", MapBackdrop, "BOTTOM", 0, -5)
end

local function EnsureInfoPanelDragOverlay()
    if InfoBar.dragOverlay then return end
    local overlay = CreateFrame("Button", nil, InfoBar, "BackdropTemplate")
    overlay:SetAllPoints()
    overlay:SetFrameStrata("TOOLTIP")
    overlay:SetFrameLevel((InfoBar:GetFrameLevel() or 1) + 60)
    overlay:EnableMouse(true)
    overlay:RegisterForClicks("AnyUp")
    overlay:RegisterForDrag("LeftButton")
    overlay:SetBackdrop({
        bgFile = "Interface\\Buttons\\WHITE8x8",
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
    })
    overlay:SetBackdropColor(0.04, 0.07, 0.11, 0.55)
    overlay:SetBackdropBorderColor(0.22, 0.54, 0.72, 0.9)

    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("CENTER")
    label:SetText("Info Panel")
    label:SetTextColor(0.88, 0.94, 1.0)
    overlay._muiLabel = label

    overlay:SetScript("OnDragStart", function()
        if InCombatLockdown and InCombatLockdown() then return end
        InfoBar:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        InfoBar:StopMovingOrSizing()
        SaveInfoPanelPosition()
    end)

    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, "MinimapInfoPanel")
    end

    InfoBar.dragOverlay = overlay
end

local function RefreshInfoPanelOverlayState()
    EnsureInfoPanelDragOverlay()
    if not InfoBar.dragOverlay then return end
    if infoPanelLocked then
        InfoBar.dragOverlay:Hide()
    else
        InfoBar.dragOverlay:Show()
    end
end

function MidnightUI_SetMinimapLocked(locked)
    minimapLocked = (locked ~= false)
    infoPanelLocked = minimapLocked
    RefreshMinimapOverlayState()
    RefreshInfoPanelOverlayState()
    if ApplyMailIconPosition then ApplyMailIconPosition() end
    if RefreshMailIconState then RefreshMailIconState() end
    if MidnightUI_ApplyMinimapSettings then
        MidnightUI_ApplyMinimapSettings()
    end
end
_G.MidnightUI_SetMinimapLocked = MidnightUI_SetMinimapLocked
-- =========================================================================
--  4.0 STATUS TRACKING BARS (XP/REP) UNDER INFO BAR
-- =========================================================================

local StatusBarHost = CreateFrame("Frame", "MidnightUI_StatusBarHost", Cluster, "BackdropTemplate")
StatusBarHost:SetPoint("TOP", InfoBar, "BOTTOM", 0, -4)
StatusBarHost:SetSize(InfoBar:GetWidth(), 16)
StatusBarHost:SetFrameStrata("MEDIUM")
StatusBarHost:SetFrameLevel(InfoBar:GetFrameLevel() + 5)
StatusBarHost:SetBackdrop({
    bgFile = "Interface\\Buttons\\WHITE8X8",
})
StatusBarHost:SetBackdropColor(0, 0, 0, 0)

local HiddenStatusBarHost = CreateFrame("Frame", nil, UIParent)
HiddenStatusBarHost:Hide()

local statusBarDefaults = { cached = false }
local function CacheStatusBarDefaults()
    local function SaveFrameDefaults(frame)
        if not frame then return nil end
        local t = {
            parent = frame:GetParent(),
            scale = frame:GetScale(),
            alpha = frame:GetAlpha(),
            strata = frame:GetFrameStrata(),
            level = frame:GetFrameLevel(),
            shown = frame:IsShown(),
            points = {}
        }
        local num = frame:GetNumPoints() or 0
        for i = 1, num do
            local p, relTo, relPoint, x, y = frame:GetPoint(i)
            t.points[i] = { p, relTo, relPoint, x, y }
        end
        return t
    end
    if StatusTrackingBarManager and not statusBarDefaults.manager then
        statusBarDefaults.manager = SaveFrameDefaults(StatusTrackingBarManager)
    end
    if _G.MainStatusTrackingBarContainer and not statusBarDefaults.main then
        statusBarDefaults.main = SaveFrameDefaults(_G.MainStatusTrackingBarContainer)
    end
    if _G.SecondaryStatusTrackingBarContainer and not statusBarDefaults.secondary then
        statusBarDefaults.secondary = SaveFrameDefaults(_G.SecondaryStatusTrackingBarContainer)
    end
    if (statusBarDefaults.manager or statusBarDefaults.main or statusBarDefaults.secondary) then
        statusBarDefaults.cached = true
    end
end

local function RestoreFrameDefaults(frame, defaults)
    if not frame or not defaults then return end
    frame:SetParent(defaults.parent or UIParent)
    frame:ClearAllPoints()
    if defaults.points and #defaults.points > 0 then
        for _, pt in ipairs(defaults.points) do
            local p, relTo, relPoint, x, y = unpack(pt)
            if p then frame:SetPoint(p, relTo, relPoint, x, y) end
        end
    end
    if defaults.strata then frame:SetFrameStrata(defaults.strata) end
    if defaults.level then frame:SetFrameLevel(defaults.level) end
    if defaults.scale then frame:SetScale(defaults.scale) end
    if defaults.alpha ~= nil then frame:SetAlpha(defaults.alpha) end
    if defaults.shown then frame:Show() else frame:Hide() end
end

local function SkinStatusBarContainer(container, width, height, theme)
    if not container then return end
    container:ClearAllPoints()
    container:SetSize(width, height)
    if container.StatusBar then
        container.StatusBar:ClearAllPoints()
        container.StatusBar:SetAllPoints(container)
        container.StatusBar:SetHeight(height)
        if container.StatusBar.SetStatusBarTexture then
            container.StatusBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
        end
        if container.StatusBar.SetStatusBarColor and theme then
            container.StatusBar:SetStatusBarColor(theme.strip[1], theme.strip[2], theme.strip[3], 1)
        end
        container.StatusBar:SetAlpha(1)
        container.StatusBar:Show()
        local sbTex = container.StatusBar.GetStatusBarTexture and container.StatusBar:GetStatusBarTexture()
        if sbTex then
            sbTex:SetAlpha(1)
            sbTex:Show()
        end
    end
    -- Do not zero out regions here; Blizzard manages some textures we need.
    if not container._muiBG then
        container._muiBG = CreateFrame("Frame", nil, container, "BackdropTemplate")
        container._muiBG:SetAllPoints()
        container._muiBG:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 8,
            insets = { left = 2, right = 2, top = 2, bottom = 2 }
        })
        container._muiBG:SetBackdropBorderColor(0, 0, 0, 1)
    end
    if theme and container._muiBG then
        container._muiBG:SetBackdropColor(theme.bg[1], theme.bg[2], theme.bg[3], 0.85)
    else
        container._muiBG:SetBackdropColor(0.03, 0.03, 0.05, 0.85)
    end
    if container._muiBG then
        container._muiBG:SetAlpha(1)
        container._muiBG:Show()
    end
    if not container._muiStrip then
        container._muiStrip = container:CreateTexture(nil, "OVERLAY")
        container._muiStrip:SetHeight(1)
        container._muiStrip:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 1, 1)
        container._muiStrip:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", -1, 1)
    end
    if theme and container._muiStrip then
        container._muiStrip:SetColorTexture(theme.strip[1], theme.strip[2], theme.strip[3], 0.9)
    else
        container._muiStrip:SetColorTexture(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.9)
    end
    container:SetFrameStrata("MEDIUM")
    container:SetFrameLevel(StatusBarHost:GetFrameLevel() + 1)
    container:SetAlpha(1)
    container:Show()
end

-- Custom bars to mirror Blizzard tracking bars (avoids EditMode/layout issues)
local customMainBar = CreateFrame("StatusBar", "MidnightUI_StatusBarMain", UIParent)
customMainBar:SetPoint("TOP", StatusBarHost, "TOP", 0, 0)
customMainBar:SetSize(StatusBarHost:GetWidth(), 8)
customMainBar:SetClampedToScreen(true)
customMainBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
customMainBar:SetMinMaxValues(0, 1)
customMainBar:SetValue(0)
customMainBar:SetFrameStrata("MEDIUM")
customMainBar:SetFrameLevel(StatusBarHost:GetFrameLevel() + 2)
customMainBar.bg = customMainBar:CreateTexture(nil, "BACKGROUND")
customMainBar.bg:SetAllPoints()
customMainBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6)
customMainBar.borderTop = customMainBar:CreateTexture(nil, "BORDER")
customMainBar.borderTop:SetPoint("TOPLEFT", 0, 0)
customMainBar.borderTop:SetPoint("TOPRIGHT", 0, 0)
customMainBar.borderTop:SetHeight(1)
customMainBar.borderBottom = customMainBar:CreateTexture(nil, "BORDER")
customMainBar.borderBottom:SetPoint("BOTTOMLEFT", 0, 0)
customMainBar.borderBottom:SetPoint("BOTTOMRIGHT", 0, 0)
customMainBar.borderBottom:SetHeight(1)
customMainBar.borderLeft = customMainBar:CreateTexture(nil, "BORDER")
customMainBar.borderLeft:SetPoint("TOPLEFT", 0, 0)
customMainBar.borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
customMainBar.borderLeft:SetWidth(1)
customMainBar.borderRight = customMainBar:CreateTexture(nil, "BORDER")
customMainBar.borderRight:SetPoint("TOPRIGHT", 0, 0)
customMainBar.borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
customMainBar.borderRight:SetWidth(1)
customMainBar.borderTop:SetColorTexture(0, 0, 0, 0.8)
customMainBar.borderBottom:SetColorTexture(0, 0, 0, 0.8)
customMainBar.borderLeft:SetColorTexture(0, 0, 0, 0.8)
customMainBar.borderRight:SetColorTexture(0, 0, 0, 0.8)

customMainBar:EnableMouse(true)
customMainBar:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 80
    local level = UnitLevel("player") or maxLevel
    GameTooltip:AddLine("Experience", CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    if level >= maxLevel then
        GameTooltip:AddLine("Max level", 0.8, 0.8, 0.8)
    else
        local xp = UnitXP("player") or 0
        local xpMax = UnitXPMax("player") or 1
        GameTooltip:AddDoubleLine("Current:", string.format("%d / %d", xp, xpMax), 0.7, 0.7, 0.7, 1, 1, 1)
        local rested = GetXPExhaustion and GetXPExhaustion() or nil
        if rested and rested > 0 then
            GameTooltip:AddDoubleLine("XP State:", "Rested", 0.7, 0.7, 0.7, 0.2, 0.6, 1.0)
        else
            GameTooltip:AddDoubleLine("XP State:", "Normal", 0.7, 0.7, 0.7, 0.7, 0.3, 0.9)
        end
    end
    GameTooltip:Show()
end)
customMainBar:SetScript("OnLeave", function() GameTooltip:Hide() end)
customMainBar:Hide()

local customSecondaryBar = CreateFrame("StatusBar", "MidnightUI_StatusBarSecondary", UIParent)
customSecondaryBar:SetPoint("TOP", customMainBar, "BOTTOM", 0, -4)
customSecondaryBar:SetSize(StatusBarHost:GetWidth(), 8)
customSecondaryBar:SetClampedToScreen(true)
customSecondaryBar:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
customSecondaryBar:SetMinMaxValues(0, 1)
customSecondaryBar:SetValue(0)
customSecondaryBar:SetFrameStrata("MEDIUM")
customSecondaryBar:SetFrameLevel(StatusBarHost:GetFrameLevel() + 2)
customSecondaryBar.bg = customSecondaryBar:CreateTexture(nil, "BACKGROUND")
customSecondaryBar.bg:SetAllPoints()
customSecondaryBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6)
customSecondaryBar.borderTop = customSecondaryBar:CreateTexture(nil, "BORDER")
customSecondaryBar.borderTop:SetPoint("TOPLEFT", 0, 0)
customSecondaryBar.borderTop:SetPoint("TOPRIGHT", 0, 0)
customSecondaryBar.borderTop:SetHeight(1)
customSecondaryBar.borderBottom = customSecondaryBar:CreateTexture(nil, "BORDER")
customSecondaryBar.borderBottom:SetPoint("BOTTOMLEFT", 0, 0)
customSecondaryBar.borderBottom:SetPoint("BOTTOMRIGHT", 0, 0)
customSecondaryBar.borderBottom:SetHeight(1)
customSecondaryBar.borderLeft = customSecondaryBar:CreateTexture(nil, "BORDER")
customSecondaryBar.borderLeft:SetPoint("TOPLEFT", 0, 0)
customSecondaryBar.borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
customSecondaryBar.borderLeft:SetWidth(1)
customSecondaryBar.borderRight = customSecondaryBar:CreateTexture(nil, "BORDER")
customSecondaryBar.borderRight:SetPoint("TOPRIGHT", 0, 0)
customSecondaryBar.borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
customSecondaryBar.borderRight:SetWidth(1)
customSecondaryBar.borderTop:SetColorTexture(0, 0, 0, 0.8)
customSecondaryBar.borderBottom:SetColorTexture(0, 0, 0, 0.8)
customSecondaryBar.borderLeft:SetColorTexture(0, 0, 0, 0.8)
customSecondaryBar.borderRight:SetColorTexture(0, 0, 0, 0.8)

customSecondaryBar:EnableMouse(true)
customSecondaryBar:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    GameTooltip:AddLine("Reputation", CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    local repCur, repMax, repName, repExtra
    if C_Reputation and C_Reputation.GetWatchedFactionData then
        local rep = C_Reputation.GetWatchedFactionData()
        if rep and rep.name then
            repName = rep.name
            local factionID = rep.factionID
            if factionID and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                local ok, majorData = pcall(C_MajorFactions.GetMajorFactionData, factionID)
                if ok and majorData and majorData.renownLevelThreshold and majorData.renownLevelThreshold > 0 then
                    repCur = majorData.renownReputationEarned or 0
                    repMax = majorData.renownLevelThreshold
                    repExtra = "Renown " .. tostring(majorData.renownLevel or "?")
                end
            end
            if not repCur and factionID and C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
                local ok, friendData = pcall(C_GossipInfo.GetFriendshipReputation, factionID)
                if ok and friendData and friendData.nextThreshold and friendData.nextThreshold > 0 then
                    repCur = (friendData.standing or 0) - (friendData.reactionThreshold or 0)
                    repMax = friendData.nextThreshold - (friendData.reactionThreshold or 0)
                    repExtra = friendData.text
                end
            end
            if not repCur then
                local minRep = rep.currentReactionThreshold or 0
                local maxRep = rep.nextReactionThreshold or 0
                local value = rep.currentStanding or 0
                if maxRep > minRep then
                    repCur = value - minRep
                    repMax = maxRep - minRep
                end
            end
        end
    elseif GetWatchedFactionInfo then
        local name, standing, minRep, maxRep, value = GetWatchedFactionInfo()
        if name and maxRep and minRep and maxRep > minRep and value then
            repName = name
            repCur = value - minRep
            repMax = maxRep - minRep
        end
    end
    if repName and repCur and repMax and repMax > 0 then
        if repExtra then
            GameTooltip:AddLine(repExtra, 0.5, 0.8, 1.0)
        end
        GameTooltip:AddDoubleLine(repName, string.format("%d / %d", repCur, repMax), 0.7, 0.7, 0.7, 1, 1, 1)
    else
        GameTooltip:AddLine("No faction tracked", 0.8, 0.8, 0.8)
    end
    GameTooltip:Show()
end)
customSecondaryBar:SetScript("OnLeave", function() GameTooltip:Hide() end)
customSecondaryBar:SetScript("OnMouseUp", function(_, btn)
    if btn == "LeftButton" and _G.MidnightUI_CharacterPanel_Toggle then
        _G.MidnightUI_CharacterPanel_Toggle("reputation")
    end
end)
customSecondaryBar:Hide()

local function SmoothSetBarValue(bar, value)
    if not bar then return end
    bar._muiTargetValue = value
    if bar._muiSmoothing then return end
    bar._muiSmoothing = true
    bar:SetScript("OnUpdate", function(self, elapsed)
        local target = self._muiTargetValue
        if target == nil then
            self._muiSmoothing = false
            self:SetScript("OnUpdate", nil)
            return
        end
        local cur = self:GetValue() or 0
        local diff = target - cur
        if math.abs(diff) < 0.5 then
            self:SetValue(target)
            self._muiSmoothing = false
            self:SetScript("OnUpdate", nil)
            return
        end
        local step = diff * math.min(elapsed * 10, 1)
        self:SetValue(cur + step)
    end)
end

local function GetXPBarSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.XPBar then MidnightUISettings.XPBar = {} end
    return MidnightUISettings.XPBar
end

local function GetRepBarSettings()
    if not MidnightUISettings then MidnightUISettings = {} end
    if not MidnightUISettings.RepBar then MidnightUISettings.RepBar = {} end
    return MidnightUISettings.RepBar
end

local function ApplyBarOrientation(bar, isVertical, w, h)
    if not bar then return end
    if isVertical then
        bar:SetOrientation("VERTICAL")
        bar:SetSize(h, w) -- swap: thin dimension is width, long dimension is height
    else
        bar:SetOrientation("HORIZONTAL")
        bar:SetSize(w, h)
    end
end

local function ApplyBarPositionFromSettings(bar, settingsTable, defaultPos)
    if not bar then return end
    bar:ClearAllPoints()
    local pos = settingsTable and settingsTable.position
    if pos and #pos >= 4 then
        local point = pos[1]
        local relativePoint = pos[2]
        local xOfs = pos[3]
        local yOfs = pos[4]
        if #pos >= 5 then
            relativePoint = pos[3]
            xOfs = pos[4]
            yOfs = pos[5]
        end
        bar:SetPoint(point, UIParent, relativePoint, xOfs, yOfs)
    elseif defaultPos then
        bar:SetPoint(unpack(defaultPos))
    end
end

local statusBarsUnlocked = false

local function UpdateCustomStatusBars()
    -- Skip updates in unlock mode — bars show placeholders for positioning
    if statusBarsUnlocked then return end

    -- XP Bar
    local xpS = GetXPBarSettings()
    if xpS.enabled == false then
        customMainBar:Hide()
    else
        local xpW = xpS.width or InfoBar:GetWidth()
        local xpH = xpS.height or 8
        local xpVert = (xpS.orientation == "vertical")
        ApplyBarOrientation(customMainBar, xpVert, xpW, xpH)
        ApplyBarPositionFromSettings(customMainBar, xpS, {"TOP", StatusBarHost, "TOP", 0, 0})

        local maxLevel = GetMaxPlayerLevel and GetMaxPlayerLevel() or 80
        local level = UnitLevel("player") or maxLevel
        if level < maxLevel then
            local xp = UnitXP("player") or 0
            local xpMax = UnitXPMax("player") or 1
            customMainBar:SetMinMaxValues(0, xpMax)
            SmoothSetBarValue(customMainBar, xp)
            local rested = GetXPExhaustion and GetXPExhaustion() or nil
            if rested and rested > 0 then
                customMainBar:SetStatusBarColor(0.0, 0.39, 0.88, 1)
            else
                customMainBar:SetStatusBarColor(0.58, 0.0, 0.55, 1)
            end
            if customMainBar.bg then customMainBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6) end
            customMainBar:Show()
        else
            customMainBar:Hide()
        end
    end

    -- Reputation Bar — always use direct API for accurate values
    local repS = GetRepBarSettings()
    if repS.enabled == false then
        customSecondaryBar:Hide()
    else
        local repW = repS.width or InfoBar:GetWidth()
        local repH = repS.height or 8
        local repVert = (repS.orientation == "vertical")
        ApplyBarOrientation(customSecondaryBar, repVert, repW, repH)
        ApplyBarPositionFromSettings(customSecondaryBar, repS, {"TOP", customMainBar, "BOTTOM", 0, -6})

        -- Blizzard FACTION_BAR_COLORS: indexed by standing (1=Hated .. 8=Exalted)
        local BLIZZ_REP_COLORS = {
            [1] = {0.80, 0.13, 0.13}, -- Hated
            [2] = {0.80, 0.13, 0.13}, -- Hostile
            [3] = {0.75, 0.27, 0.00}, -- Unfriendly
            [4] = {0.90, 0.70, 0.00}, -- Neutral
            [5] = {0.00, 0.60, 0.10}, -- Friendly
            [6] = {0.00, 0.60, 0.10}, -- Honored
            [7] = {0.00, 0.60, 0.10}, -- Revered
            [8] = {0.00, 0.60, 0.10}, -- Exalted
        }
        local RENOWN_COLOR = {0.06, 0.70, 0.75}
        local FRIENDSHIP_COLOR = {0.89, 0.55, 0.14}

        local repCur, repMax, repName, repColor
        if C_Reputation and C_Reputation.GetWatchedFactionData then
            local rep = C_Reputation.GetWatchedFactionData()
            if rep and rep.name then
                repName = rep.name
                local factionID = rep.factionID
                local standing = rep.reaction
                -- Major (Renown) factions use a different API for accurate level progress
                if factionID and C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                    local ok, majorData = pcall(C_MajorFactions.GetMajorFactionData, factionID)
                    if ok and majorData and majorData.renownLevelThreshold and majorData.renownLevelThreshold > 0 then
                        repCur = majorData.renownReputationEarned or 0
                        repMax = majorData.renownLevelThreshold
                        repColor = RENOWN_COLOR
                    end
                end
                -- Friendship factions
                if not repCur and factionID and C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
                    local ok, friendData = pcall(C_GossipInfo.GetFriendshipReputation, factionID)
                    if ok and friendData and friendData.nextThreshold and friendData.nextThreshold > 0 then
                        repCur = (friendData.standing or 0) - (friendData.reactionThreshold or 0)
                        repMax = friendData.nextThreshold - (friendData.reactionThreshold or 0)
                        repColor = FRIENDSHIP_COLOR
                    end
                end
                -- Standard factions: offset by currentReactionThreshold, color by standing
                if not repCur then
                    local minRep = rep.currentReactionThreshold or 0
                    local maxRep = rep.nextReactionThreshold or 0
                    local value = rep.currentStanding or 0
                    if maxRep > minRep then
                        repCur = value - minRep
                        repMax = maxRep - minRep
                        repColor = (standing and BLIZZ_REP_COLORS[standing]) or BLIZZ_REP_COLORS[5]
                    end
                end
            end
        elseif GetWatchedFactionInfo then
            local name, standing, minRep, maxRep, value = GetWatchedFactionInfo()
            if name and maxRep and minRep and maxRep > minRep and value then
                repName = name
                repCur = value - minRep
                repMax = maxRep - minRep
                repColor = (standing and BLIZZ_REP_COLORS[standing]) or BLIZZ_REP_COLORS[5]
            end
        end
        if repName and repCur and repMax and repMax > 0 then
            customSecondaryBar:SetMinMaxValues(0, repMax)
            customSecondaryBar:SetValue(repCur) -- direct set, no smoothing for accuracy
            customSecondaryBar:SetStatusBarColor(repColor[1], repColor[2], repColor[3], 1)
            if customSecondaryBar.bg then customSecondaryBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6) end
            customSecondaryBar:Show()
        else
            customSecondaryBar:Hide()
        end
    end

    local xpShown = customMainBar:IsShown()
    local repShown = customSecondaryBar:IsShown()
    if xpShown or repShown then
        StatusBarHost:Show()
    else
        StatusBarHost:Hide()
    end
end

local function StyleStatusTrackingBars()
    if StatusBarHost and StatusBarHost._muiStyling then return end
    if StatusBarHost then StatusBarHost._muiStyling = true end
    CacheStatusBarDefaults()

    local useCustom = not (MidnightUISettings and MidnightUISettings.Minimap and MidnightUISettings.Minimap.useCustomStatusBars == false)
    if not useCustom then
        if StatusBarHost then StatusBarHost._muiStyling = false end
        return
    end

    local main = _G.MainStatusTrackingBarContainer
    local secondary = _G.SecondaryStatusTrackingBarContainer
    if not main then
        if StatusBarHost then StatusBarHost._muiStyling = false end
        return
    end

    local style = "Default"
    if MidnightUISettings and MidnightUISettings.Minimap and MidnightUISettings.Minimap.infoBarStyle then
        style = MidnightUISettings.Minimap.infoBarStyle
    end
    local theme = GetInfoBarTheme(style)

    local width = InfoBar:GetWidth()
    local barHeight = 8
    local gap = 6

    if StatusTrackingBarManager then
        if StatusTrackingBarManager:GetParent() ~= StatusBarHost then
            StatusTrackingBarManager:SetParent(StatusBarHost)
        end
        StatusTrackingBarManager:ClearAllPoints()
        StatusTrackingBarManager:SetPoint("TOP", StatusBarHost, "TOP", 0, 0)
    end

    if main:GetParent() ~= StatusBarHost then
        main:SetParent(StatusBarHost)
    end
    main:ClearAllPoints()
    main:SetPoint("TOP", StatusBarHost, "TOP", 0, 0)
    SkinStatusBarContainer(main, width, barHeight, theme)

    if secondary then
        if secondary:GetParent() ~= StatusBarHost then
            secondary:SetParent(StatusBarHost)
        end
        secondary:ClearAllPoints()
        secondary:SetPoint("TOP", main, "BOTTOM", 0, -gap)
        SkinStatusBarContainer(secondary, width, barHeight, theme)
    end

    if StatusBarHost then StatusBarHost._muiStyling = false end
end

local function RefreshStatusTrackingBars()
    if StatusBarHost and StatusBarHost._muiRefresh then return end
    if StatusBarHost then StatusBarHost._muiRefresh = true end
    CacheStatusBarDefaults()
    local useCustom = not (MidnightUISettings and MidnightUISettings.Minimap and MidnightUISettings.Minimap.useCustomStatusBars == false)
    if StatusTrackingBarManager and StatusTrackingBarManager.UpdateBarsShown then
        StatusTrackingBarManager:UpdateBarsShown()
    end
    local main = _G.MainStatusTrackingBarContainer
    local secondary = _G.SecondaryStatusTrackingBarContainer
    if useCustom then
        -- Hide Blizzard status tracking bars to prevent overlap with custom bars.
        if StatusTrackingBarManager then
            StatusTrackingBarManager:Hide()
            StatusTrackingBarManager:SetAlpha(0)
            StatusTrackingBarManager:SetParent(HiddenStatusBarHost)
            StatusTrackingBarManager:ClearAllPoints()
            if StatusTrackingBarManager.DisableDrawLayer then
                StatusTrackingBarManager:DisableDrawLayer("BACKGROUND")
                StatusTrackingBarManager:DisableDrawLayer("BORDER")
                StatusTrackingBarManager:DisableDrawLayer("OVERLAY")
            end
        end
        if main then
            main:Hide()
            main:SetAlpha(0)
            main:SetParent(HiddenStatusBarHost)
            main:ClearAllPoints()
            if main.StatusBar and main.StatusBar.GetStatusBarTexture then
                local tex = main.StatusBar:GetStatusBarTexture()
                if tex then tex:SetAlpha(0) end
            end
        end
        if secondary then
            secondary:Hide()
            secondary:SetAlpha(0)
            secondary:SetParent(HiddenStatusBarHost)
            secondary:ClearAllPoints()
            if secondary.StatusBar and secondary.StatusBar.GetStatusBarTexture then
                local tex = secondary.StatusBar:GetStatusBarTexture()
                if tex then tex:SetAlpha(0) end
            end
        end
        UpdateCustomStatusBars()
    else
        -- Show Blizzard defaults and hide our custom bars.
        if StatusTrackingBarManager and StatusTrackingBarManager.EnableDrawLayer then
            StatusTrackingBarManager:EnableDrawLayer("BACKGROUND")
            StatusTrackingBarManager:EnableDrawLayer("BORDER")
            StatusTrackingBarManager:EnableDrawLayer("OVERLAY")
        end
        RestoreFrameDefaults(StatusTrackingBarManager, statusBarDefaults.manager)
        RestoreFrameDefaults(main, statusBarDefaults.main)
        RestoreFrameDefaults(secondary, statusBarDefaults.secondary)
        if StatusTrackingBarManager then
            StatusTrackingBarManager:SetParent(UIParent)
            StatusTrackingBarManager:ClearAllPoints()
            if statusBarDefaults.manager and statusBarDefaults.manager.points and statusBarDefaults.manager.points[1] then
                local p = statusBarDefaults.manager.points[1]
                StatusTrackingBarManager:SetPoint(p[1], p[2], p[3], p[4], p[5])
            else
                StatusTrackingBarManager:SetPoint("TOP", UIParent, "TOP", 0, -4)
            end
            StatusTrackingBarManager:SetAlpha(1)
            StatusTrackingBarManager:Show()
        end
        if main then
            main:SetParent(StatusTrackingBarManager or UIParent)
            main:SetAlpha(1)
            main:Show()
        end
        if secondary then
            secondary:SetParent(StatusTrackingBarManager or UIParent)
            secondary:SetAlpha(1)
            secondary:Show()
        end
        if main then main:SetAlpha(1); main:Show() end
        if secondary then secondary:SetAlpha(1) end
        if main and main.StatusBar and main.StatusBar.GetStatusBarTexture then
            local tex = main.StatusBar:GetStatusBarTexture()
            if tex then tex:SetAlpha(1) end
        end
        if secondary and secondary.StatusBar and secondary.StatusBar.GetStatusBarTexture then
            local tex = secondary.StatusBar:GetStatusBarTexture()
            if tex then tex:SetAlpha(1) end
        end
        if StatusTrackingBarManager and StatusTrackingBarManager.UpdateBarsShown then
            StatusTrackingBarManager:UpdateBarsShown()
        end
        if StatusTrackingBarManager and StatusTrackingBarManager.LayoutBars then
            StatusTrackingBarManager:LayoutBars()
        end
        if StatusBarHost then StatusBarHost:Hide() end
        if customMainBar then customMainBar:Hide() end
        if customSecondaryBar then customSecondaryBar:Hide() end
    end
    if StatusBarHost then StatusBarHost._muiRefresh = false end
end

InfoBar:HookScript("OnSizeChanged", function()
    if StatusBarHost then
        StyleStatusTrackingBars()
    end
end)

-- 4.1 ZONE (Top)
local ZoneFrame = CreateFrame("Button", nil, InfoBar)
ZoneFrame:SetSize(206, 24)
ZoneFrame:SetPoint("TOP", InfoBar, "TOP", 0, 0) 
ZoneFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

-- =========================================================================
--  STATUS BAR UNLOCK OVERLAYS (Separate XP and Rep)
-- =========================================================================

local function CreateBarDragOverlay(bar, labelText, settingsKey, positionSaveKey)
    local overlay = CreateFrame("Frame", nil, bar, "BackdropTemplate")
    overlay:SetPoint("TOPLEFT", bar, "TOPLEFT", -6, 12)
    overlay:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 6, -12)
    overlay:SetFrameStrata("DIALOG")
    overlay:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    overlay:SetBackdropColor(0.05, 0.08, 0.11, 0.30)
    overlay:SetBackdropBorderColor(0.30, 0.46, 0.58, 0.78)
    if _G.MidnightUI_StyleOverlay then _G.MidnightUI_StyleOverlay(overlay, nil, nil, "world") end
    local label = overlay:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("CENTER")
    label:SetText(labelText)
    label:SetTextColor(1, 1, 1)
    overlay:EnableMouse(true)
    overlay:RegisterForDrag("LeftButton")
    overlay:SetScript("OnDragStart", function()
        bar:SetMovable(true)
        bar:StartMoving()
    end)
    overlay:SetScript("OnDragStop", function()
        bar:StopMovingOrSizing()
        local point, _, relativePoint, xOfs, yOfs = bar:GetPoint()
        if not MidnightUISettings then MidnightUISettings = {} end
        if not MidnightUISettings[positionSaveKey] then MidnightUISettings[positionSaveKey] = {} end
        MidnightUISettings[positionSaveKey].position = { point, relativePoint, xOfs, yOfs }
    end)
    overlay:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Drag to move " .. labelText, 1, 0.82, 0)
        GameTooltip:Show()
    end)
    overlay:SetScript("OnLeave", function() GameTooltip:Hide() end)
    if _G.MidnightUI_AttachOverlaySettings then
        _G.MidnightUI_AttachOverlaySettings(overlay, settingsKey)
    end
    return overlay
end

function MidnightUI_SetStatusBarsLocked(locked)
    local isLocked = (locked ~= false)

    -- XP Bar overlay
    if customMainBar then
        if isLocked then
            if customMainBar.dragOverlay then customMainBar.dragOverlay:Hide() end
        else
            local xpS = GetXPBarSettings()
            local xpW = xpS.width or InfoBar:GetWidth()
            local xpH = xpS.height or 8
            local xpVert = (xpS.orientation == "vertical")
            ApplyBarOrientation(customMainBar, xpVert, xpW, xpH)
            ApplyBarPositionFromSettings(customMainBar, xpS, {"TOP", StatusBarHost, "TOP", 0, 0})
            customMainBar:Show()
            if customMainBar:GetValue() == 0 then
                customMainBar:SetMinMaxValues(0, 100)
                customMainBar:SetValue(65)
                customMainBar:SetStatusBarColor(0.58, 0.0, 0.55, 1)
                if customMainBar.bg then customMainBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6) end
            end
            if not customMainBar.dragOverlay then
                customMainBar.dragOverlay = CreateBarDragOverlay(customMainBar, "XP BAR", "XPBar", "XPBar")
            end
            customMainBar.dragOverlay:Show()
        end
    end

    -- Rep Bar overlay
    if customSecondaryBar then
        if isLocked then
            if customSecondaryBar.dragOverlay then customSecondaryBar.dragOverlay:Hide() end
        else
            local repS = GetRepBarSettings()
            local repW = repS.width or InfoBar:GetWidth()
            local repH = repS.height or 8
            local repVert = (repS.orientation == "vertical")
            ApplyBarOrientation(customSecondaryBar, repVert, repW, repH)
            ApplyBarPositionFromSettings(customSecondaryBar, repS, {"TOP", customMainBar, "BOTTOM", 0, -6})
            customSecondaryBar:Show()
            if customSecondaryBar:GetValue() == 0 then
                customSecondaryBar:SetMinMaxValues(0, 100)
                customSecondaryBar:SetValue(40)
                customSecondaryBar:SetStatusBarColor(0.06, 0.70, 0.75, 1)
                if customSecondaryBar.bg then customSecondaryBar.bg:SetColorTexture(0.03, 0.03, 0.05, 0.6) end
            end
            if not customSecondaryBar.dragOverlay then
                customSecondaryBar.dragOverlay = CreateBarDragOverlay(customSecondaryBar, "REP BAR", "RepBar", "RepBar")
            end
            customSecondaryBar.dragOverlay:Show()
        end
    end

    StatusBarHost:Show()
end
_G.MidnightUI_SetStatusBarsLocked = MidnightUI_SetStatusBarsLocked

_G.MidnightUI_RefreshStatusBars = function()
    RefreshStatusTrackingBars()
end

-- XP Bar overlay settings
local function BuildXPBarOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = GetXPBarSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Header("XP Bar")
    b:Checkbox("Enable", s.enabled ~= false, function(v)
        s.enabled = v
        UpdateCustomStatusBars()
    end)
    b:Slider("Width", 50, 600, 5, s.width or math.floor(InfoBar:GetWidth()), function(v)
        s.width = math.floor(v)
        UpdateCustomStatusBars()
    end)
    b:Slider("Height", 4, 40, 1, s.height or 8, function(v)
        s.height = math.floor(v)
        UpdateCustomStatusBars()
    end)
    b:Checkbox("Vertical", s.orientation == "vertical", function(v)
        s.orientation = v and "vertical" or "horizontal"
        UpdateCustomStatusBars()
    end)
    return b:Height()
end

-- Rep Bar overlay settings
local function BuildRepBarOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = GetRepBarSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })

    b:Header("Reputation Bar")
    b:Checkbox("Enable", s.enabled ~= false, function(v)
        s.enabled = v
        UpdateCustomStatusBars()
    end)
    b:Slider("Width", 50, 600, 5, s.width or math.floor(InfoBar:GetWidth()), function(v)
        s.width = math.floor(v)
        UpdateCustomStatusBars()
    end)
    b:Slider("Height", 4, 40, 1, s.height or 8, function(v)
        s.height = math.floor(v)
        UpdateCustomStatusBars()
    end)
    b:Checkbox("Vertical", s.orientation == "vertical", function(v)
        s.orientation = v and "vertical" or "horizontal"
        UpdateCustomStatusBars()
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("XPBar", {
        title = "XP Bar",
        build = BuildXPBarOverlaySettings,
    })
    _G.MidnightUI_RegisterOverlaySettings("RepBar", {
        title = "Reputation Bar",
        build = BuildRepBarOverlaySettings,
    })
end

ZoneFrame.text = ZoneFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
ZoneFrame.text:SetPoint("CENTER", ZoneFrame, "CENTER", 0, 0)
ZoneFrame.text:SetJustifyH("CENTER")
ZoneFrame.text:SetTextColor(unpack(CLASS_COLOR))

ZoneFrame.icon = ZoneFrame:CreateTexture(nil, "OVERLAY")
ZoneFrame.icon:SetSize(16, 16)
ZoneFrame.icon:SetPoint("RIGHT", ZoneFrame, "RIGHT", -4, 0)
ZoneFrame.icon:SetTexture("Interface\\Icons\\UI_AllianceWarMode")
ZoneFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
ZoneFrame.icon:Hide()

ZoneFrame:EnableMouse(true)
ZoneFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    
    local zone = GetRealZoneText() or GetMinimapZoneText() or ""
    GameTooltip:AddLine(zone, CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    
    local subzone = GetSubZoneText() or ""
    
    GameTooltip:AddLine(" ")
    
    local warMode = C_PvP.IsWarModeDesired()
    local wmText = warMode and "Enabled" or "Disabled"
    local wmR, wmG, wmB = warMode and 1 or 0.5, warMode and 0.2 or 0.5, warMode and 0.2 or 0.5
    GameTooltip:AddDoubleLine("War Mode:", wmText, 0.6, 0.6, 0.6, wmR, wmG, wmB)
    
    local zoneTypeLabel, color = GetZoneTypeLabel()
    local zoneLabel = subzone ~= "" and subzone or zone
    if zoneLabel ~= "" then
        GameTooltip:AddDoubleLine("Zone:", zoneLabel, 0.6, 0.6, 0.6, 1, 1, 1)
    end
    if zoneTypeLabel and color then
        GameTooltip:AddDoubleLine("Zone Type:", zoneTypeLabel, 0.6, 0.6, 0.6, color.r, color.g, color.b)
    end
    
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left Click: Achievements", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Shift+Click: World Map", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right Click: Calendar", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)
ZoneFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
ZoneFrame:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then
        -- Toggle Achievements Panel (shift+click for World Map)
        if IsShiftKeyDown() then
            ToggleWorldMap()
        elseif _G.MidnightUI_AchievementsPanel and _G.MidnightUI_AchievementsPanel.Toggle then
            _G.MidnightUI_AchievementsPanel.Toggle()
        else
            ToggleWorldMap()
        end
    elseif button == "RightButton" then
        if GameTimeFrame then GameTimeFrame:Click() end
    end
end)
ZoneFrame:RegisterEvent("PLAYER_ENTERING_WORLD"); ZoneFrame:RegisterEvent("ZONE_CHANGED"); ZoneFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA"); ZoneFrame:RegisterEvent("PLAYER_FLAGS_CHANGED")
ZoneFrame:SetScript("OnEvent", function(self)
    local warMode = C_PvP.IsWarModeDesired()
    if warMode then
        self.icon:Show()
        local faction = UnitFactionGroup("player")
        if faction == "Alliance" then self.icon:SetTexture("Interface\\Icons\\UI_AllianceWarMode") else self.icon:SetTexture("Interface\\Icons\\UI_HordeWarMode") end
    else self.icon:Hide() end
end)

-- 4.2 TIME (Center)
local TimeFrame = CreateFrame("Button", nil, InfoBar)
TimeFrame:SetSize(70, 24)
TimeFrame:SetPoint("TOP", InfoBar, "TOP", 0, -24)
TimeFrame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

TimeFrame.text = TimeFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
TimeFrame.text:SetPoint("CENTER", TimeFrame, "CENTER", 0, 0)
TimeFrame.text:SetJustifyH("CENTER")

TimeFrame:EnableMouse(true)
TimeFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    
    local lHour, lMin = GetGameTime()
    local lDate = date("*t")
    
    GameTooltip:AddLine("Time", CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    GameTooltip:AddLine(" ")
    GameTooltip:AddDoubleLine("Local Time:", GetFormattedTime(lDate.hour, lDate.min), 1, 1, 1, 1, 1, 1)
    GameTooltip:AddDoubleLine("Server Time:", GetFormattedTime(lHour, lMin), 1, 1, 1, 1, 1, 1)
    GameTooltip:Show()
end)
TimeFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
TimeFrame:SetScript("OnClick", function(self, button)
    if button == "LeftButton" then ToggleWorldMap() elseif button == "RightButton" then if GameTimeFrame then GameTimeFrame:Click() end end
end)

-- 4.3 DURABILITY (Right)
local DurFrame = CreateFrame("Button", nil, InfoBar)
DurFrame:SetSize(55, 24)  
DurFrame:SetPoint("TOPRIGHT", InfoBar, "TOPRIGHT", -8, -24)

DurFrame.icon = DurFrame:CreateTexture(nil, "ARTWORK")
DurFrame.icon:SetSize(14, 14)
DurFrame.icon:SetPoint("LEFT", DurFrame, "LEFT", 0, 0)
DurFrame.icon:SetTexture("Interface\\Icons\\INV_Sword_04")
DurFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

DurFrame.text = DurFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
DurFrame.text:SetPoint("LEFT", DurFrame.icon, "RIGHT", 4, 0)

DurFrame:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    
    GameTooltip:AddLine("Equipment Durability", CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    GameTooltip:AddLine(" ")
    
    local totalCurrent, totalMax = 0, 0
    local damagedItems = {}
    local slots = {"Head", "Neck", "Shoulder", "Shirt", "Chest", "Waist", "Legs", "Feet", "Wrist", "Hands", "Ring 1", "Ring 2", "Trinket 1", "Trinket 2", "Back", "Main Hand", "Off Hand", "Ranged"}
    
    for i = 1, 18 do
        local current, max = GetInventoryItemDurability(i)
        if current and max and max > 0 then
            totalCurrent = totalCurrent + current; totalMax = totalMax + max
            if (current / max) < 1 then table.insert(damagedItems, {slot = slots[i], pct = current / max}) end
        end
    end
    
    if totalMax > 0 then
        local overallPct = totalCurrent / totalMax
        local r, g, b = GetGradualColor(overallPct)
        GameTooltip:AddDoubleLine("Overall:", format("%d%%", overallPct*100), 1, 1, 1, r, g, b)
    end
    
    if #damagedItems > 0 then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Damaged Items:", 1, 0.82, 0)
        for _, item in ipairs(damagedItems) do
            local r, g, b = GetGradualColor(item.pct)
            GameTooltip:AddDoubleLine(item.slot, format("%d%%", item.pct*100), 1, 1, 1, r, g, b)
        end
    else
        GameTooltip:AddLine(" "); GameTooltip:AddLine("All equipment in perfect condition!", 0, 1, 0)
    end
    GameTooltip:AddLine(" "); GameTooltip:AddLine("Left Click: Open Character Panel", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end)
DurFrame:SetScript("OnLeave", function() GameTooltip:Hide() end)
DurFrame:SetScript("OnClick", function() ToggleCharacter("PaperDollFrame") end)

-- =========================================================================
--  4.4 SYSTEM (Left) - MATH VERIFIED & OPTIMIZED
-- =========================================================================
local SysFrame = CreateFrame("Button", nil, InfoBar)
SysFrame:SetSize(85, 24)
SysFrame:SetPoint("TOPLEFT", InfoBar, "TOPLEFT", 8, -24)

SysFrame.icon = SysFrame:CreateTexture(nil, "ARTWORK")
SysFrame.icon:SetSize(14, 14)
SysFrame.icon:SetPoint("LEFT", SysFrame, "LEFT", 2, 0)
SysFrame.icon:SetTexture("Interface\\Icons\\Spell_Nature_Lightning")
SysFrame.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

SysFrame.text = SysFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
SysFrame.text:SetPoint("LEFT", SysFrame.icon, "RIGHT", 10, 0)

-- TRACKING HISTORY
-- These variables persist through Loading Screens (Portals), but reset on Login/Reload.
SysFrame.history = {
    lastHome = nil,
    lastWorld = nil,
    jitterHomeAvg = 0, -- NEW: Smoothed Jitter (Rolling Average)
    jitterWorldAvg = 0, -- NEW: Smoothed Jitter (Rolling Average)
    cpuPrev = {},      -- Stores the lifetime MS from the previous tick
    spikeCount = 0,    -- Our "Packet Loss" proxy counter
    lastTickTime = GetTime() -- NEW: Exact timestamp for drift correction
}

-- COLOR CALCULATOR
local function GetHealthColor(val, good, bad, higherIsBetter)
    if higherIsBetter then
        -- FPS: Higher = Green
        if val >= good then return 0, 1, 0         -- Green
        elseif val >= bad then return 1, 1, 0      -- Yellow
        else return 1, 0.2, 0.2 end                -- Red
    else
        -- Latency/Jitter/CPU: Lower = Green
        if val <= good then return 0, 1, 0         -- Green
        elseif val <= bad then return 1, 1, 0      -- Yellow
        else return 1, 0.2, 0.2 end                -- Red
    end
end

local function UpdateNetworkTooltip()
    if not GameTooltip:IsOwned(SysFrame) then return end
    GameTooltip:ClearLines()
    
    -- 1. HARDWARE REFRESH
    UpdateAddOnMemoryUsage()
    UpdateAddOnCPUUsage()
    
    -- NEW: Calculate exact Delta Time (dt) since last check for drift correction
    local currentTime = GetTime()
    local dt = currentTime - (SysFrame.history.lastTickTime or currentTime)
    if dt <= 0 then dt = 0.5 end -- Fail-safe prevents division by zero
    SysFrame.history.lastTickTime = currentTime
    
    -- 2. NETWORK CALCULATIONS
    local _, _, latencyHome, latencyWorld = GetNetStats()
    
    -- Initialize history on first run
    if not SysFrame.history.lastHome then SysFrame.history.lastHome = latencyHome end
    if not SysFrame.history.lastWorld then SysFrame.history.lastWorld = latencyWorld end
    
    -- Raw Jitter Calculation
    local jitterHome = math.abs(latencyHome - SysFrame.history.lastHome)
    local jitterWorld = math.abs(latencyWorld - SysFrame.history.lastWorld)
    
    -- NEW: Apply Weighted Moving Average (Smoothing)
    -- Filters out micro-spikes. 20% weight to new value, 80% to history.
    SysFrame.history.jitterHomeAvg = (SysFrame.history.jitterHomeAvg * 0.8) + (jitterHome * 0.2)
    SysFrame.history.jitterWorldAvg = (SysFrame.history.jitterWorldAvg * 0.8) + (jitterWorld * 0.2)
    
    -- Packet Loss Proxy: If Latency jumps >100ms, mark as "Spike"
    if jitterHome > 100 or jitterWorld > 100 then
        SysFrame.history.spikeCount = SysFrame.history.spikeCount + 1
    end
    
    SysFrame.history.lastHome = latencyHome
    SysFrame.history.lastWorld = latencyWorld

    -- 3. CPU RATE CALCULATION (ms/sec)
    local totalMemory = 0
    local totalCPU_Rate = 0
    local addonData = {}
    local numAddons = C_AddOns.GetNumAddOns()
    
    for i = 1, numAddons do
        local name = C_AddOns.GetAddOnInfo(i)
        local mem = GetAddOnMemoryUsage(i)
        local lifetimeCPU = GetAddOnCPUUsage(i)
        
        local prevCPU = SysFrame.history.cpuPrev[name] or lifetimeCPU
        local usageDelta = lifetimeCPU - prevCPU
        
        -- NEW: Drift Correction Formula
        -- Instead of 'usageDelta * 2', divide by exact time elapsed
        local usagePerSec = usageDelta / dt
        
        SysFrame.history.cpuPrev[name] = lifetimeCPU
        
        totalMemory = totalMemory + mem
        totalCPU_Rate = totalCPU_Rate + usagePerSec
        
        table.insert(addonData, {name = name, cpu = usagePerSec})
    end
    table.sort(addonData, function(a, b) return a.cpu > b.cpu end)

    -- ===================================
    -- TOOLTIP DISPLAY
    -- ===================================
    
    GameTooltip:AddLine("System Diagnostics", CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    GameTooltip:AddLine(" ")

    -- NETWORK
    GameTooltip:AddLine("Network Status", 0.6, 0.8, 1)

    local r, g, b = GetHealthColor(latencyHome, 60, 150, false)
    GameTooltip:AddDoubleLine("Home Latency:", latencyHome .. " ms", 1, 1, 1, r, g, b)

    r, g, b = GetHealthColor(latencyWorld, 60, 150, false) 
    GameTooltip:AddDoubleLine("Server Latency:", latencyWorld .. " ms", 1, 1, 1, r, g, b)

    r, g, b = GetHealthColor(SysFrame.history.spikeCount, 0, 0, false) 
    GameTooltip:AddDoubleLine("Packet Loss (Est):", SysFrame.history.spikeCount .. " Spikes", 1, 1, 1, r, g, b)

    -- NEW: Display Smoothed Jitter Values
    r, g, b = GetHealthColor(SysFrame.history.jitterHomeAvg, 5, 20, false)
    GameTooltip:AddDoubleLine("Home Jitter (Avg):", format("%.1f ms", SysFrame.history.jitterHomeAvg), 1, 1, 1, r, g, b)

    r, g, b = GetHealthColor(SysFrame.history.jitterWorldAvg, 5, 20, false) 
    GameTooltip:AddDoubleLine("Server Jitter (Avg):", format("%.1f ms", SysFrame.history.jitterWorldAvg), 1, 1, 1, r, g, b)

    -- HARDWARE
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Hardware Performance", 0.6, 0.8, 1)

    -- NEW: Proper Rounding for FPS
    local fps = floor(GetFramerate() + 0.5)
    r, g, b = GetHealthColor(fps, 60, 30, true)
    GameTooltip:AddDoubleLine("Frame Rate:", fps .. " FPS", 1, 1, 1, r, g, b)

    r, g, b = GetHealthColor(totalCPU_Rate, 40, 150, false) 
    GameTooltip:AddDoubleLine("Total Addon CPU:", format("%.1f ms/sec", totalCPU_Rate), 1, 1, 1, r, g, b)

    local memMB = totalMemory / 1024
    r, g, b = GetHealthColor(memMB, 250, 500, false)
    GameTooltip:AddDoubleLine("Addon Memory:", format("%.1f MB", memMB), 1, 1, 1, r, g, b)
    
    -- TOP CPU USERS
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Top CPU Consumers:", 1, 0.3, 0.3)
    
    local foundHog = false
    for i = 1, math.min(3, #addonData) do
        local data = addonData[i]
        if data.cpu > 1.0 then
            r, g, b = GetHealthColor(data.cpu, 10, 50, false)
            GameTooltip:AddDoubleLine(data.name, format("%.1f ms/sec", data.cpu), 1, 1, 1, r, g, b)
            foundHog = true
        end
    end
    
    if not foundHog then
        GameTooltip:AddLine("System is optimal.", 0, 1, 0)
    end
    
    GameTooltip:Show()
end

-- Update text on the bar itself (Latency display)
SysFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
SysFrame:SetScript("OnEvent", function(self)
    -- We do NOT reset history here, so stats persist through Portals.
    -- They will naturally reset on Relog/Reload.
    local _, _, _, latencyWorld = GetNetStats()
    local msColor = (latencyWorld < 100) and "00ff00" or ((latencyWorld < 200) and "ffff00" or "ff0000")
    self.text:SetText(string.format("|cff%s%d|rms", msColor, latencyWorld))
    self.icon:SetVertexColor(1, 1, 1, 1.0)
end)

SysFrame:SetScript("OnEnter", function(self) 
    GameTooltip:SetOwner(self, "ANCHOR_NONE")
    GameTooltip:SetPoint("TOP", self, "BOTTOM", 0, -2)
    SkinTooltip()
    
    -- Prime the CPU history immediately on hover so we don't get a huge "0 to X" spike
    UpdateAddOnCPUUsage()
    for i = 1, C_AddOns.GetNumAddOns() do
        local name = C_AddOns.GetAddOnInfo(i)
        self.history.cpuPrev[name] = GetAddOnCPUUsage(i)
    end
    
    UpdateNetworkTooltip()
    -- Ticker runs every 0.5s to calculate Deltas
    self.tooltipUpdateTimer = C_Timer.NewTicker(0.5, UpdateNetworkTooltip) 
end)

SysFrame:SetScript("OnLeave", function(self) 
    if self.tooltipUpdateTimer then 
        self.tooltipUpdateTimer:Cancel()
        self.tooltipUpdateTimer = nil 
    end
    GameTooltip:Hide() 
end)

local function ApplyInfoBarTheme()
    local style = "Default"
    if MidnightUISettings and MidnightUISettings.Minimap and MidnightUISettings.Minimap.infoBarStyle then
        style = MidnightUISettings.Minimap.infoBarStyle
    end
    local theme = GetInfoBarTheme(style)
    if InfoBar.bg then InfoBar.bg:SetColorTexture(theme.bg[1], theme.bg[2], theme.bg[3], theme.bg[4]) end
    if InfoBar.header then InfoBar.header:SetColorTexture(theme.header[1], theme.header[2], theme.header[3], theme.header[4]) end
    if InfoBar.strip then InfoBar.strip:SetColorTexture(theme.strip[1], theme.strip[2], theme.strip[3], theme.strip[4]) end
    if ZoneFrame and ZoneFrame.text then ZoneFrame.text:SetTextColor(theme.text[1], theme.text[2], theme.text[3]) end
    if TimeFrame and TimeFrame.text then TimeFrame.text:SetTextColor(theme.text[1], theme.text[2], theme.text[3]) end
    if SysFrame and SysFrame.text then SysFrame.text:SetTextColor(theme.text[1], theme.text[2], theme.text[3]) end
end

ApplyInfoBarTheme()

local zoneTypeSeen = {}
local function UpdateInfoBar()
    local zoneName = GetRealZoneText() or GetMinimapZoneText() or "Unknown Zone"
    ZoneFrame.text:SetText(zoneName)
    
    local lDate = date("*t")
    TimeFrame.text:SetText(GetFormattedTime(lDate.hour, lDate.min))
    
    local totalCurrent, totalMax = 0, 0
    for i = 1, 18 do
        local current, max = GetInventoryItemDurability(i)
        if current and max and max > 0 then
            totalCurrent = totalCurrent + current
            totalMax = totalMax + max
        end
    end
    
    if totalMax > 0 then
        local percent = totalCurrent / totalMax
        local r, g, b = GetGradualColor(percent)
        DurFrame.text:SetText(string.format("%d%%", percent * 100))
        DurFrame.text:SetTextColor(r, g, b)
        DurFrame.icon:SetVertexColor(1, 1, 1, 1.0)
    end

    local _, _, _, latencyWorld = GetNetStats()
    local msColor = (latencyWorld < 100) and "00ff00" or ((latencyWorld < 200) and "ffff00" or "ff0000")
    SysFrame.text:SetText(string.format("|cff%s%d|rms", msColor, latencyWorld))
    SysFrame.icon:SetVertexColor(1, 1, 1, 1.0)

    -- Zone type debug logging removed.
end

InfoBar:RegisterEvent("ZONE_CHANGED"); InfoBar:RegisterEvent("PLAYER_ENTERING_WORLD"); InfoBar:RegisterEvent("ZONE_CHANGED_NEW_AREA");
InfoBar:SetScript("OnEvent", UpdateInfoBar)

local function StartInfoBarTicker()
    if InfoBar.updateTicker then return end
    InfoBar.updateTicker = C_Timer.NewTicker(1, UpdateInfoBar)
end

local function StopInfoBarTicker()
    if InfoBar.updateTicker then
        InfoBar.updateTicker:Cancel()
        InfoBar.updateTicker = nil
    end
end

InfoBar:SetScript("OnShow", function()
    UpdateInfoBar()
    StartInfoBarTicker()
end)
InfoBar:SetScript("OnHide", StopInfoBarTicker)
StartInfoBarTicker()

-- =========================================================================
--  5. COORDINATES OVERLAY
-- =========================================================================
local CoordFrame = CreateFrame("Frame", nil, Cluster)
CoordFrame:SetSize(110, 18)
CoordFrame:SetPoint("BOTTOM", Minimap, "BOTTOM", 0, 5) 
-- Keep above the minimap but below high/tooltip windows (e.g. bags).
local coordBaseLevel = (Minimap and Minimap.GetFrameLevel and Minimap:GetFrameLevel()) or 0
CoordFrame:SetFrameStrata("MEDIUM")
CoordFrame:SetFrameLevel(coordBaseLevel + 8)
CoordFrame.bg = CoordFrame:CreateTexture(nil, "BACKGROUND")
CoordFrame.bg:SetAllPoints()
CoordFrame.bg:SetColorTexture(0, 0, 0, 0.6)
CoordFrame.bg:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
CoordFrame.text = CoordFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
CoordFrame.text:SetPoint("CENTER", CoordFrame, "CENTER", 0, 0)
CoordFrame.text:SetTextColor(1, 1, 1)
CoordFrame:Show()

local function GetPlayerCoords()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID and C_Map.SetBestMapForUnit then
        mapID = C_Map.SetBestMapForUnit("player")
    end
    if not mapID and SetMapToCurrentZone then
        SetMapToCurrentZone()
        mapID = C_Map.GetBestMapForUnit("player")
    end
    if not mapID then return nil end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return nil end
    local ok, x, y = pcall(pos.GetXY, pos)
    if _G.MidnightUI_Settings and _G.MidnightUI_Settings.TaintTrace then
        local secret = false
        if type(issecretvalue) == "function" then
            secret = issecretvalue(x) or issecretvalue(y)
        end
        if not ok or secret then
            _G.MidnightUI_Settings.TaintTrace("Minimap:GetPlayerCoords ok=" .. tostring(ok) .. " secret=" .. tostring(secret))
        end
    end
    if not ok then return nil end
    if type(issecretvalue) == "function" then
        if issecretvalue(x) or issecretvalue(y) then return nil end
    end
    if not x or not y then return nil end
    return x * 100, y * 100
end

local function AreCoordsEnabled()
    return not (MidnightUISettings and MidnightUISettings.Minimap and MidnightUISettings.Minimap.coordsEnabled == false)
end

local function ShouldShowCoordsNow()
    if not AreCoordsEnabled() then return false end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
        return false
    end
    local x, y = GetPlayerCoords()
    return x ~= nil and y ~= nil
end

function MidnightUI_ApplyMinimapSettings()
    local s = EnsureMinimapSettings()
    minimapLocked = not (MidnightUISettings and MidnightUISettings.Messenger and MidnightUISettings.Messenger.locked == false)
    infoPanelLocked = minimapLocked

    Cluster:SetScale(GetMinimapScale() / 100)
    ApplyMinimapPosition()
    if IsMinimapEnabled() or not minimapLocked then
        Cluster:Show()
        if not IsMinimapEnabled() and not minimapLocked then
            Cluster:SetAlpha(0.55)
        else
            Cluster:SetAlpha(1)
        end
    else
        Cluster:SetAlpha(1)
        Cluster:Hide()
    end
    RefreshMinimapOverlayState()

    InfoBar:SetScale(GetInfoPanelScale() / 100)
    ApplyInfoPanelPosition()

    if s.infoPanelEnabled ~= false or not infoPanelLocked then
        InfoBar:Show()
        if s.infoPanelEnabled == false and not infoPanelLocked then
            InfoBar:SetAlpha(0.55)
        else
            InfoBar:SetAlpha(1)
        end
    else
        InfoBar:SetAlpha(1)
        InfoBar:Hide()
    end
    RefreshInfoPanelOverlayState()
    if ApplyMailIconPosition then ApplyMailIconPosition() end
    if RefreshMailIconState then RefreshMailIconState() end

    if CoordFrame then
        if IsMinimapEnabled() and ShouldShowCoordsNow() then CoordFrame:Show() else CoordFrame:Hide() end
    end
    ApplyInfoBarTheme()
    if not IsMinimapEnabled() or s.infoPanelEnabled == false then
        if StatusBarHost then StatusBarHost:Hide() end
        if customMainBar then customMainBar:Hide() end
        if customSecondaryBar then customSecondaryBar:Hide() end
    else
        RefreshStatusTrackingBars()
    end
end

local function BuildMinimapInfoPanelOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureMinimapSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Info Panel")
    b:Checkbox("Enable Info Panel", s.infoPanelEnabled ~= false, function(v)
        s.infoPanelEnabled = v and true or false
        MidnightUI_ApplyMinimapSettings()
    end)
    b:Slider("Scale %", 60, 150, 1, s.infoPanelScale or 100, function(v)
        s.infoPanelScale = math.floor(v + 0.5)
        MidnightUI_ApplyMinimapSettings()
    end)
    return b:Height()
end

local function BuildMinimapOverlaySettings(content)
    if not _G.MidnightUI_CreateOverlayBuilder then return end
    local s = EnsureMinimapSettings()
    local b = _G.MidnightUI_CreateOverlayBuilder(content, { startY = -6 })
    b:Header("Minimap")
    b:Checkbox("Enable Minimap", s.enabled ~= false, function(v)
        s.enabled = v and true or false
        MidnightUI_ApplyMinimapSettings()
    end)
    b:Slider("Scale %", 60, 150, 1, s.scale or 100, function(v)
        s.scale = math.floor(v + 0.5)
        MidnightUI_ApplyMinimapSettings()
    end)
    return b:Height()
end

if _G.MidnightUI_RegisterOverlaySettings then
    _G.MidnightUI_RegisterOverlaySettings("Minimap", {
        title = "Minimap",
        build = BuildMinimapOverlaySettings,
    })
    _G.MidnightUI_RegisterOverlaySettings("MinimapInfoPanel", {
        title = "Info Panel",
        build = BuildMinimapInfoPanelOverlaySettings,
    })
end

if _G.MidnightUI_RegisterDiagnostic then
    _G.MidnightUI_RegisterDiagnostic("Minimap Settings", function()
        if _G.MidnightUI_ApplyMinimapSettings then _G.MidnightUI_ApplyMinimapSettings() end
    end)
elseif _G.MidnightUI_DiagnosticsPending then
    table.insert(_G.MidnightUI_DiagnosticsPending, {
        name = "Minimap Settings",
        fn = function()
            if _G.MidnightUI_ApplyMinimapSettings then _G.MidnightUI_ApplyMinimapSettings() end
        end
    })
end

local statusBarListener = CreateFrame("Frame")
statusBarListener:RegisterEvent("PLAYER_ENTERING_WORLD")
statusBarListener:RegisterEvent("UPDATE_FACTION")
statusBarListener:RegisterEvent("UPDATE_EXHAUSTION")
statusBarListener:RegisterEvent("PLAYER_XP_UPDATE")
statusBarListener:RegisterEvent("PLAYER_LEVEL_UP")
statusBarListener:SetScript("OnEvent", function()
    C_Timer.After(0, RefreshStatusTrackingBars)
    -- XP/Rep debug logging removed.
end)

-- Kick an initial refresh after UI settles.
C_Timer.After(1, RefreshStatusTrackingBars)

-- Avoid hooking UpdateBarsShown to prevent recursive updates during reload.

local function UpdateCoordsNow()
    if not AreCoordsEnabled() then
        CoordFrame:Hide()
        return
    end
    local inInstance, instanceType = IsInInstance()
    if inInstance and (instanceType == "party" or instanceType == "raid" or instanceType == "scenario") then
        CoordFrame:Hide()
        return
    end
    local x, y = GetPlayerCoords()
    if x and y then
        CoordFrame.text:SetText(format("%.1f, %.1f", x, y))
        if CoordFrame.bg then CoordFrame.bg:Show() end
        CoordFrame:Show()
    else
        CoordFrame:Hide()
    end
end

local function StartCoordTicker()
    if CoordFrame.coordTicker then return end
    CoordFrame.coordTicker = C_Timer.NewTicker(0.1, UpdateCoordsNow)
end

local function StopCoordTicker()
    if CoordFrame.coordTicker then
        CoordFrame.coordTicker:Cancel()
        CoordFrame.coordTicker = nil
    end
end

CoordFrame:SetScript("OnShow", function()
    UpdateCoordsNow()
    StartCoordTicker()
end)
CoordFrame:SetScript("OnHide", StopCoordTicker)
CoordFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
CoordFrame:RegisterEvent("ZONE_CHANGED")
CoordFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
CoordFrame:RegisterEvent("ZONE_CHANGED_INDOORS")
CoordFrame:SetScript("OnEvent", function()
    if MidnightUI_ApplyMinimapSettings then MidnightUI_ApplyMinimapSettings() end
end)
if CoordFrame:IsShown() then
    UpdateCoordsNow()
    StartCoordTicker()
end

-- =========================================================================
--  6. MAIL OVERLAY
-- =========================================================================
MailIcon = CreateFrame("Button", nil, Cluster)
MailIcon:SetSize(28, 28)
MailIcon:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 6, -2)
MailIcon:Hide()
MailIcon:EnableMouse(true)
MailIcon:SetHitRectInsets(0, 0, 0, 0)
MailIcon:SetMovable(true)
MailIcon:SetClampedToScreen(true)
MailIcon:RegisterForDrag("LeftButton")
if Minimap then
    -- Keep above the minimap but below high/tooltip windows (e.g. bags).
    local baseLevel = (Minimap.GetFrameLevel and Minimap:GetFrameLevel()) or 0
    MailIcon:SetFrameStrata("MEDIUM")
    MailIcon:SetFrameLevel(baseLevel + 8)
else
    MailIcon:SetFrameStrata("MEDIUM")
end

local MailTex = MailIcon:CreateTexture(nil, "ARTWORK")
MailTex:SetAllPoints()
MailTex:SetTexture("Interface\\Icons\\INV_Letter_15")
MailTex:SetTexCoord(0.08, 0.92, 0.08, 0.92)

MailIcon.bg = MailIcon:CreateTexture(nil, "BACKGROUND")
MailIcon.bg:SetAllPoints()
MailIcon.bg:SetColorTexture(0, 0, 0, 0.6)
MailIcon.bg:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")

local mb = CreateBorder(MailIcon, 1, 0.8, 0, 1) 
mb:SetFrameLevel(MailIcon:GetFrameLevel() + 1)
if mb.EnableMouse then mb:EnableMouse(false) end

-- Prevent Blizzard's mail frame from blocking our tooltip.
if MinimapCluster and MinimapCluster.IndicatorFrame then
    local indicator = MinimapCluster.IndicatorFrame
    if indicator.EnableMouse then indicator:EnableMouse(false) end
    if indicator.MailFrame then
        if indicator.MailFrame.EnableMouse then indicator.MailFrame:EnableMouse(false) end
        indicator.MailFrame:SetAlpha(0)
    end
end

-- Ensure child regions don't intercept mouse.
for _, region in ipairs({MailIcon:GetRegions()}) do
    if region and region.EnableMouse then region:EnableMouse(false) end
end

local function SaveMailIconPosition()
    local s = EnsureMinimapSettings()
    local iconX, iconY = MailIcon:GetCenter()
    local clusterX, clusterY = Cluster:GetCenter()
    if not iconX or not iconY or not clusterX or not clusterY then return end
    local scale = Cluster:GetScale()
    if not scale or scale == 0 then scale = 1 end
    local xOfs = (iconX - clusterX) / scale
    local yOfs = (iconY - clusterY) / scale
    s.mailIconPosition = { "CENTER", "CENTER", xOfs, yOfs }
end

ApplyMailIconPosition = function()
    local s = EnsureMinimapSettings()
    MailIcon:ClearAllPoints()
    if s.mailIconPosition and #s.mailIconPosition >= 4 then
        MailIcon:SetPoint(s.mailIconPosition[1], Cluster, s.mailIconPosition[2], s.mailIconPosition[3], s.mailIconPosition[4])
    else
        MailIcon:SetPoint("BOTTOMRIGHT", Minimap, "BOTTOMRIGHT", 6, -2)
    end
end

RefreshMailIconState = function()
    local minimapEnabled = IsMinimapEnabled()
    local hasMail = (HasNewMail and HasNewMail()) and true or false
    local baseLevel = (Minimap and Minimap.GetFrameLevel and Minimap:GetFrameLevel()) or 0

    if minimapLocked then
        MailIcon:SetFrameStrata("MEDIUM")
        MailIcon:SetFrameLevel(baseLevel + 8)
        MailIcon:SetAlpha(1)
        if minimapEnabled and hasMail then
            MailIcon:Show()
        else
            MailIcon:Hide()
        end
        return
    end

    MailIcon:SetFrameStrata("TOOLTIP")
    if Cluster.dragOverlay and Cluster.dragOverlay.GetFrameLevel then
        MailIcon:SetFrameLevel((Cluster.dragOverlay:GetFrameLevel() or 1) + 12)
    else
        MailIcon:SetFrameLevel(baseLevel + 50)
    end
    MailIcon:Show()
    MailIcon:SetAlpha(hasMail and 1 or 0.55)
end

MailIcon:SetScript("OnDragStart", function(self)
    if minimapLocked then return end
    if InCombatLockdown and InCombatLockdown() then return end
    self:StartMoving()
end)
MailIcon:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    SaveMailIconPosition()
    ApplyMailIconPosition()
end)

MailIcon:RegisterEvent("UPDATE_PENDING_MAIL")
MailIcon:RegisterEvent("MAIL_INBOX_UPDATE")
MailIcon:RegisterEvent("MAIL_SHOW")
MailIcon:RegisterEvent("MAIL_CLOSED")
MailIcon:SetScript("OnEvent", function(self)
    RefreshMailIconState()
end)
MailIcon:SetScript("OnEnter", function(self)
    if not GameTooltip then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if HasNewMail() then
        GameTooltip:AddLine("New Mail")
        local s1, s2, s3 = GetLatestThreeSenders()
        if s1 or s2 or s3 then
            if s1 then GameTooltip:AddLine(s1, 0.85, 0.90, 1.00) end
            if s2 then GameTooltip:AddLine(s2, 0.85, 0.90, 1.00) end
            if s3 then GameTooltip:AddLine(s3, 0.85, 0.90, 1.00) end
        else
            GameTooltip:AddLine("Unknown sender", 0.7, 0.7, 0.7)
        end
    else
        GameTooltip:AddLine("No Mail")
        if not minimapLocked then
            GameTooltip:AddLine("Edit Mode: Drag to move", 0.55, 0.80, 1.0)
        end
    end
    GameTooltip:Show()
end)
MailIcon:SetScript("OnLeave", function()
    if GameTooltip then GameTooltip:Hide() end
end)
ApplyMailIconPosition()
RefreshMailIconState()

-- =========================================================================
--  7. LIBDBICON APP DRAWER & CHEST
-- =========================================================================

local LibDBIconDrawer = {}
LibDBIconDrawer.buttons = {}
LibDBIconDrawer.hiddenButtons = {}
LibDBIconDrawer.pinnedAddons = {}
LibDBIconDrawer.addonOrder = {}

local function TooltipIntersectsFrame(tooltipFrame, targetFrame)
    if not tooltipFrame or not targetFrame then return false end
    local tl, tr, tt, tb = tooltipFrame:GetLeft(), tooltipFrame:GetRight(), tooltipFrame:GetTop(), tooltipFrame:GetBottom()
    local fl, fr, ft, fb = targetFrame:GetLeft(), targetFrame:GetRight(), targetFrame:GetTop(), targetFrame:GetBottom()
    if not (tl and tr and tt and tb and fl and fr and ft and fb) then return false end
    return (tl < fr) and (tr > fl) and (tb < ft) and (tt > fb)
end

local function AnchorDrawerTooltipOutsideIcons(ownerButton)
    if not ownerButton or not GameTooltip or not GameTooltip:IsShown() then return end
    local drawer = LibDBIconDrawer.drawer
    if not drawer or not drawer:IsShown() then return end

    local left, right = ownerButton:GetLeft(), ownerButton:GetRight()
    if not left or not right then return end

    local screenRight = UIParent and UIParent:GetRight()
    local placeRight = true
    if screenRight then
        placeRight = ((left + right) * 0.5) <= (screenRight * 0.5)
    end

    GameTooltip:SetClampedToScreen(true)

    local function Place(point, relPoint, xOff, yOff)
        GameTooltip:ClearAllPoints()
        GameTooltip:SetPoint(point, ownerButton, relPoint, xOff, yOff)
    end

    if placeRight then
        Place("TOPLEFT", "TOPRIGHT", 12, 0)
    else
        Place("TOPRIGHT", "TOPLEFT", -12, 0)
    end

    if TooltipIntersectsFrame(GameTooltip, drawer) then
        if placeRight then
            Place("TOPRIGHT", "TOPLEFT", -12, 0)
        else
            Place("TOPLEFT", "TOPRIGHT", 12, 0)
        end
    end
    if TooltipIntersectsFrame(GameTooltip, drawer) then
        Place("BOTTOMLEFT", "TOPLEFT", 0, 10)
    end
    if TooltipIntersectsFrame(GameTooltip, drawer) then
        Place("TOPLEFT", "BOTTOMLEFT", 0, -10)
    end
end

local function StopDrawerTooltipGuard()
    if LibDBIconDrawer.tooltipGuardTicker then
        LibDBIconDrawer.tooltipGuardTicker:Cancel()
        LibDBIconDrawer.tooltipGuardTicker = nil
    end
    LibDBIconDrawer.activeTooltipOwner = nil
end

local function StartDrawerTooltipGuard(ownerButton)
    if not ownerButton then return end
    StopDrawerTooltipGuard()
    LibDBIconDrawer.activeTooltipOwner = ownerButton
    AnchorDrawerTooltipOutsideIcons(ownerButton)

    LibDBIconDrawer.tooltipGuardTicker = C_Timer.NewTicker(0.05, function()
        local owner = LibDBIconDrawer.activeTooltipOwner
        if not owner or not owner:IsShown() or not owner:IsMouseOver() then
            StopDrawerTooltipGuard()
            return
        end
        AnchorDrawerTooltipOutsideIcons(owner)
    end)
end

-- Create a button in the drawer for a LibDBIcon icon
local function CreateDrawerButton(iconButton)
    local drawer = LibDBIconDrawer.drawer
    if not drawer then return nil end
    
    local btnSize, btnSpacing = 24, 28
    local btnIndex = #LibDBIconDrawer.buttons + 1
    
    local btn = CreateFrame("Button", nil, drawer)
    btn:SetSize(btnSize, btnSize)
    btn:SetPoint("TOP", drawer, "TOP", 0, -8 - ((btnIndex - 1) * btnSpacing))
    
    -- Visual Style
    local btnBg = btn:CreateTexture(nil, "BACKGROUND")
    btnBg:SetAllPoints()
    btnBg:SetTexture("Interface\\Buttons\\WHITE8x8")
    btnBg:SetVertexColor(0.1, 0.1, 0.12, 0.7) 
    btn.btnBg = btnBg
    
    local btnBorder = CreateFrame("Frame", nil, btn, "BackdropTemplate")
    btnBorder:SetAllPoints()
    btnBorder:SetBackdrop({edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1})
    btnBorder:SetBackdropBorderColor(0.2, 0.2, 0.24, 1)
    btnBorder:SetFrameLevel(btn:GetFrameLevel() + 1)
    btnBorder:EnableMouse(false)
    btn.btnBorder = btnBorder
    
    local bIcon = btn:CreateTexture(nil, "ARTWORK")
    bIcon:SetPoint("TOPLEFT", 2, -2); bIcon:SetPoint("BOTTOMRIGHT", -2, 2)
    
    local iconSet = false
    if iconButton.icon and iconButton.icon:IsObjectType("Texture") then
        local texture = iconButton.icon:GetTexture()
        if texture then
            bIcon:SetTexture(texture)
            local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy = iconButton.icon:GetTexCoord()
            if ULx then bIcon:SetTexCoord(ULx, ULy, LLx, LLy, URx, URy, LRx, LRy) end
            iconSet = true
        end
    end
    if not iconSet then
        local normalTex = iconButton:GetNormalTexture()
        if normalTex then
            local texture = normalTex:GetTexture()
            if texture then
                bIcon:SetTexture(texture)
                local ULx, ULy, LLx, LLy, URx, URy, LRx, LRy = normalTex:GetTexCoord()
                if ULx then bIcon:SetTexCoord(ULx, ULy, LLx, LLy, URx, URy, LRx, LRy) end
                iconSet = true
            end
        end
    end
    if not iconSet and iconButton.dataObject and iconButton.dataObject.icon then
        local iconPath = iconButton.dataObject.icon
        if type(iconPath) == "string" or type(iconPath) == "number" then
            bIcon:SetTexture(iconPath); bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92); iconSet = true
        end
    end
    if not iconSet then bIcon:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark"); bIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
    btn.bIcon = bIcon
    
    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture("Interface\\Buttons\\WHITE8x8")
    hl:SetVertexColor(1, 1, 1, 0.12)
    hl:SetBlendMode("ADD")
    
    -- Hover Logic
    btn:SetScript("OnEnter", function(self)
        self.btnBorder:SetBackdropBorderColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.7)
        self.btnBg:SetVertexColor(0.15, 0.15, 0.18, 0.85) -- Lighten BG
        
        if LibDBIconDrawer.CloseDrawer then 
            local d = LibDBIconDrawer.drawer
            if d and d.closeTimer then d.closeTimer:Cancel(); d.closeTimer = nil end
        end
        
        if iconButton.dataObject then
            local dbObj = iconButton.dataObject
            
            -- [FIX] Prioritize OnEnter (Raider.IO uses this)
            if dbObj.OnEnter then
                dbObj.OnEnter(self)
            elseif dbObj.OnTooltipShow then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                dbObj.OnTooltipShow(GameTooltip)
                GameTooltip:Show()
            elseif dbObj.tooltip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(dbObj.tooltip)
                GameTooltip:Show()
            else
                local name = dbObj.tocname or dbObj.label or dbObj.text or iconButton:GetName() or "Unknown"
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(name)
                GameTooltip:Show()
            end
        end

        StartDrawerTooltipGuard(self)
    end)
    
    btn:SetScript("OnLeave", function(self)
        self.btnBorder:SetBackdropBorderColor(0.2, 0.2, 0.24, 1) -- Reset to gray
        self.btnBg:SetVertexColor(0.1, 0.1, 0.12, 0.7) -- Reset BG
        StopDrawerTooltipGuard()
        
        -- [FIX] Ensure we call the addon's OnLeave if it exists (Raider.IO relies on this to hide)
        if iconButton.dataObject and iconButton.dataObject.OnLeave then
            iconButton.dataObject.OnLeave(self)
        else
            GameTooltip:Hide()
        end
        if GameTooltip:IsOwned(self) then
            GameTooltip:Hide()
        end
        
        if LibDBIconDrawer.ScheduleClose then LibDBIconDrawer.ScheduleClose() end
    end)
    
    -- Mirror mouse semantics without double-firing full click actions:
    -- trigger real "click" on release, and only pass press/release scripts for hold behavior.
    btn:RegisterForClicks("AnyUp", "AnyDown")
    btn:SetScript("OnClick", function(self, mouseButton, isDown)
        if not iconButton then return end

        if isDown then
            local onMouseDown = iconButton:GetScript("OnMouseDown")
            if onMouseDown then onMouseDown(iconButton, mouseButton) end
        else
            if iconButton.Click then
                iconButton:Click(mouseButton)
            else
                local onClick = iconButton:GetScript("OnClick")
                if onClick then
                    onClick(iconButton, mouseButton, false)
                end
            end
            local onMouseUp = iconButton:GetScript("OnMouseUp")
            if onMouseUp then onMouseUp(iconButton, mouseButton) end
        end
    end)
    
    btn:SetMovable(true)
    btn:EnableMouse(true)
    btn:RegisterForDrag("LeftButton")
    
    btn:SetScript("OnDragStart", function(self)
        self:SetParent(Cluster)
        self:SetFrameStrata("DIALOG")
        self:SetAlpha(0.8)
        self:StartMoving()
        self.isDragging = true
        GameTooltip:Hide()
    end)
    
    btn:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        self:SetAlpha(1.0)
        self.isDragging = false
        self:SetParent(LibDBIconDrawer.drawer)
        self:SetFrameStrata("MEDIUM")
        
        local dbObj = iconButton.dataObject
        local myName = dbObj and (dbObj.tocname or dbObj.label or dbObj.text) or iconButton:GetName() or "Unknown"
        local targetButton, targetIndex = nil, nil
        
        for i, otherBtn in ipairs(LibDBIconDrawer.buttons) do
            if otherBtn ~= self and otherBtn:IsMouseOver() then
                targetButton = otherBtn
                targetIndex = i
                break
            end
        end
        
        if targetButton and targetIndex then
            local myIndex = nil
            for i, name in ipairs(LibDBIconDrawer.addonOrder) do
                if name == myName then myIndex = i; break end
            end
            if myIndex and targetIndex then
                table.remove(LibDBIconDrawer.addonOrder, myIndex)
                table.insert(LibDBIconDrawer.addonOrder, targetIndex, myName)
                if LibDBIconDrawer.RebuildDrawer then LibDBIconDrawer.RebuildDrawer() end
                return
            end
        end
        
        self:ClearAllPoints()
        self:SetPoint("TOP", LibDBIconDrawer.drawer, "TOP", 0, -8 - ((btnIndex - 1) * btnSpacing))
    end)
    
    btn.originalButton = iconButton
    table.insert(LibDBIconDrawer.buttons, btn)
    btn:Show()
    return btn
end

local function CreateLibDBIconDrawer()
    local dockButton = CreateFrame("Button", "MidnightUI_LibDBIconDock", Cluster, "BackdropTemplate")
    dockButton:SetSize(40, 40)
    dockButton:SetPoint("LEFT", MapBackdrop, "LEFT", -50, 0)
    dockButton:SetMovable(true); dockButton:EnableMouse(true); dockButton:RegisterForDrag("LeftButton")
    dockButton:SetScript("OnDragStart", function(self) self:StartMoving() end)
    dockButton:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    
    dockButton:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
    dockButton:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    dockButton:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.9)
    
    local gradient = dockButton:CreateTexture(nil, "BACKGROUND")
    gradient:SetPoint("TOPLEFT", 1, -1); gradient:SetPoint("BOTTOMRIGHT", -1, 1)
    gradient:SetTexture("Interface\\Buttons\\WHITE8x8")
    gradient:SetBlendMode("DISABLE")
    gradient:SetGradient("VERTICAL", CreateColor(0.08, 0.08, 0.12, 0.8), CreateColor(0.05, 0.05, 0.09, 0.8))
    
    local icon = dockButton:CreateTexture(nil, "OVERLAY")
    icon:SetSize(24, 24); icon:SetPoint("CENTER"); icon:SetTexture("Interface\\Icons\\Trade_Engineering"); icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    dockButton.icon = icon
    
    local badgeBg = dockButton:CreateTexture(nil, "OVERLAY")
    badgeBg:SetSize(14, 14); badgeBg:SetPoint("BOTTOMRIGHT", dockButton, "BOTTOMRIGHT", -2, 2)
    badgeBg:SetTexture("Interface\\Buttons\\WHITE8x8"); badgeBg:SetVertexColor(0.02, 0.02, 0.04, 0.95)
    badgeBg:SetMask("Interface\\CharacterFrame\\TempPortraitAlphaMask")
    
    local countBadge = dockButton:CreateFontString(nil, "OVERLAY", nil, 2)
    countBadge:SetFont("Fonts\\FRIZQT__.TTF", 9, "OUTLINE")
    countBadge:SetPoint("CENTER", badgeBg, "CENTER", 0, 0)
    countBadge:SetTextColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
    countBadge:SetText("0")
    dockButton.countBadge = countBadge
    
    -- Avoid default button highlight blowout; keep this call safe to prevent
    -- aborting dock setup before mouse scripts are attached.
    if dockButton.SetHighlightTexture and dockButton.GetHighlightTexture then
        local okHighlight = pcall(dockButton.SetHighlightTexture, dockButton, "Interface\\Buttons\\WHITE8x8", "ADD")
        if okHighlight then
            local hl = dockButton:GetHighlightTexture()
            if hl and hl.SetVertexColor then
                hl:SetVertexColor(0, 0, 0, 0)
            end
            if hl and hl.SetAlpha then
                hl:SetAlpha(0)
            end
        end
    end
    local hoverGlow = dockButton:CreateTexture(nil, "OVERLAY")
    hoverGlow:SetPoint("TOPLEFT", 1, -1); hoverGlow:SetPoint("BOTTOMRIGHT", -1, 1)
    hoverGlow:SetTexture("Interface\\Buttons\\WHITE8x8")
    hoverGlow:SetGradient("VERTICAL",
        CreateColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.14),
        CreateColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.06))
    hoverGlow:SetBlendMode("ADD")
    hoverGlow:Hide()
    dockButton.hoverGlow = hoverGlow
    
    local drawer = CreateFrame("Frame", "MidnightUI_LibDBIconDrawer", dockButton, "BackdropTemplate")
    drawer:SetPoint("TOP", dockButton, "BOTTOM", 0, -6)
    drawer:SetSize(30, 1)
    drawer:SetFrameLevel(dockButton:GetFrameLevel() - 1)
    drawer:SetClipsChildren(true)
    
    drawer:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
    drawer:SetBackdropColor(0.06, 0.06, 0.08, 0.95) -- Darker, smoother background
    drawer:SetBackdropBorderColor(0.15, 0.15, 0.18, 1)
    drawer:SetAlpha(0)
    
    local drawerAccent = drawer:CreateTexture(nil, "OVERLAY")
    drawerAccent:SetHeight(2); drawerAccent:SetPoint("BOTTOMLEFT", 1, 1); drawerAccent:SetPoint("BOTTOMRIGHT", -1, 1)
    drawerAccent:SetTexture("Interface\\Buttons\\WHITE8x8")
    drawerAccent:SetVertexColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 0.6)
    
    -- [FIX] REMOVED HEADER FRAME TO ELIMINATE TOP GAP
    
    drawer.targetHeight = 1; drawer.targetAlpha = 0
    local function UpdateSlide(self, elapsed)
        local speed = math.min(14 * elapsed, 0.6)
        local curH, diffH = self:GetHeight(), self.targetHeight - self:GetHeight()
        if math.abs(diffH) < 0.5 then self:SetHeight(self.targetHeight) else self:SetHeight(curH + (diffH * speed)) end
        local curA, diffA = self:GetAlpha(), self.targetAlpha - self:GetAlpha()
        if math.abs(diffA) < 0.01 then self:SetAlpha(self.targetAlpha); if self.targetAlpha <= 0 and self.targetHeight <= 1 then self:Hide() end
        else self:SetAlpha(curA + (diffA * speed)) end
    end
    drawer:SetScript("OnUpdate", UpdateSlide)
    
    local function OpenDrawer()
        if drawer.closeTimer then drawer.closeTimer:Cancel(); drawer.closeTimer = nil end
        if #LibDBIconDrawer.buttons > 0 then
            drawer:Show()
            -- [FIX] REDUCED HEIGHT CALCULATION TO MATCH NEW OFFSET
            local targetH = (#LibDBIconDrawer.buttons * 28) + 8
            drawer.targetHeight = targetH; drawer.targetAlpha = 1; dockButton:SetBackdropBorderColor(CLASS_COLOR[1]*0.8, CLASS_COLOR[2]*0.8, CLASS_COLOR[3]*0.8, 1)
        end
    end
    local function CloseDrawer()
        if dockButton:IsMouseOver() or drawer:IsMouseOver() then return end
        for _, btn in ipairs(LibDBIconDrawer.buttons) do if btn:IsMouseOver() then return end end
        drawer.targetHeight = 1; drawer.targetAlpha = 0; dockButton:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.9)
    end
    local function ScheduleClose()
        if drawer.closeTimer then drawer.closeTimer:Cancel() end
        drawer.closeTimer = C_Timer.NewTimer(0.35, function() CloseDrawer(); drawer.closeTimer = nil end)
    end
    local function UpdateCount() dockButton.countBadge:SetText(tostring(#LibDBIconDrawer.buttons)) end
    
    dockButton:SetScript("OnEnter", function(self)
        if self.hoverGlow then self.hoverGlow:Show() end
        OpenDrawer()
    end)
    dockButton:SetScript("OnLeave", function(self)
        if self.hoverGlow then self.hoverGlow:Hide() end
        ScheduleClose()
    end)
    drawer:SetScript("OnLeave", ScheduleClose)
    drawer:SetScript("OnEnter", function(self) if self.closeTimer then self.closeTimer:Cancel() end end)
    
    LibDBIconDrawer.dockButton = dockButton
    LibDBIconDrawer.drawer = drawer
    LibDBIconDrawer.UpdateCount = UpdateCount
    LibDBIconDrawer.CloseDrawer = CloseDrawer
    LibDBIconDrawer.ScheduleClose = ScheduleClose
    LibDBIconDrawer.CreateDrawerButton = CreateDrawerButton
    LibDBIconDrawer.pinnedAddons = LibDBIconDrawer.pinnedAddons or {}
    LibDBIconDrawer.addonOrder = LibDBIconDrawer.addonOrder or {}
    
-- "Self-Healing" Rebuild Drawer Logic with Default Fallback
    function LibDBIconDrawer.RebuildDrawer()
        -- RegisterForClicks is protected; defer rebuild until combat ends.
        if InCombatLockdown and InCombatLockdown() then
            LibDBIconDrawer._pendingRebuild = true
            return
        end
        for _, btn in ipairs(LibDBIconDrawer.buttons) do btn:Hide(); btn:SetParent(nil) end
        LibDBIconDrawer.buttons = {}
        
        -- [FIX ISSUE 2] Fallback: Auto-pin first 8 if empty AND chest is not open
        local hasPins = false
        for _ in pairs(LibDBIconDrawer.pinnedAddons) do hasPins = true; break end
        
        -- Check if the chest/overflow window is currently open
        local chestFrame = _G["MidnightUI_AddonChest"]
        local chestIsOpen = chestFrame and chestFrame:IsShown()
        
        -- Only apply fallback if no pins exist AND chest is NOT open
        if not hasPins and not chestIsOpen and #LibDBIconDrawer.hiddenButtons > 0 then
            local count = 0
            for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do
                if btn.dataObject then
                    local name = btn.dataObject.label or btn.dataObject.text or btn:GetName() or "Unknown"
                    if name ~= "Unknown" then
                        LibDBIconDrawer.pinnedAddons[name] = true
                        table.insert(LibDBIconDrawer.addonOrder, name)
                        count = count + 1
                    end
                end
                if count >= 8 then break end
            end
        end

        local usedButtons = {} 
        local pinnedButtons = {}
        
        for _, addonName in ipairs(LibDBIconDrawer.addonOrder) do
            for _, hiddenBtn in ipairs(LibDBIconDrawer.hiddenButtons) do
                if hiddenBtn.dataObject then
                    local name = hiddenBtn.dataObject.label or hiddenBtn.dataObject.text or hiddenBtn:GetName() or "Unknown"
                    if name == addonName and LibDBIconDrawer.pinnedAddons[name] and not usedButtons[hiddenBtn] then
                        table.insert(pinnedButtons, hiddenBtn)
                        usedButtons[hiddenBtn] = true 
                        break 
                    end
                end
            end
        end
        -- [FIX] Increased render limit to 10
        for i = 1, math.min(#pinnedButtons, 10) do
            if LibDBIconDrawer.CreateDrawerButton then LibDBIconDrawer.CreateDrawerButton(pinnedButtons[i]) end
        end
        if LibDBIconDrawer.UpdateCount then LibDBIconDrawer.UpdateCount() end
    end
    
-- Right-Click to Open Chest
    dockButton:RegisterForClicks("AnyUp")
    dockButton:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            local chestFrame = _G["MidnightUI_AddonChest"]
            if chestFrame and chestFrame:IsShown() then chestFrame:Hide(); return end
            
            if not chestFrame then
                chestFrame = CreateFrame("Frame", "MidnightUI_AddonChest", UIParent, "BackdropTemplate")
                chestFrame:SetSize(560, 520)
                chestFrame:SetPoint("CENTER", UIParent, "CENTER")
                chestFrame:SetFrameStrata("DIALOG")
                chestFrame:SetFrameLevel(100)
                chestFrame:EnableMouse(true)
                chestFrame:SetMovable(true)
                chestFrame:RegisterForDrag("LeftButton")
                chestFrame:SetClampedToScreen(true)
                
                chestFrame:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=1})
                chestFrame:SetBackdropColor(0.01, 0.01, 0.03, 0.98)
                chestFrame:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
                
                local header = CreateFrame("Frame", nil, chestFrame)
                header:SetSize(560, 70); header:SetPoint("TOP", 0, 0); header:EnableMouse(true); header:RegisterForDrag("LeftButton")
                header:SetScript("OnDragStart", function() chestFrame:StartMoving() end)
                header:SetScript("OnDragStop", function() chestFrame:StopMovingOrSizing() end)
                
                local title = chestFrame:CreateFontString(nil, "OVERLAY")
                title:SetFont("Fonts\\FRIZQT__.TTF", 16, "OUTLINE"); title:SetPoint("TOP", 0, -16); title:SetText("Addon Icon Chest")
                
                -- Close Button
                local closeBtn = CreateFrame("Button", nil, chestFrame)
                closeBtn:SetSize(20, 20); closeBtn:SetPoint("TOPRIGHT", -12, -12)
                closeBtn:SetFrameLevel(header:GetFrameLevel() + 10)
                
                local l1 = closeBtn:CreateTexture(nil, "ARTWORK"); l1:SetSize(14,2); l1:SetPoint("CENTER"); l1:SetTexture("Interface\\Buttons\\WHITE8x8"); l1:SetRotation(math.rad(45))
                local l2 = closeBtn:CreateTexture(nil, "ARTWORK"); l2:SetSize(14,2); l2:SetPoint("CENTER"); l2:SetTexture("Interface\\Buttons\\WHITE8x8"); l2:SetRotation(math.rad(-45))
                
                closeBtn:SetScript("OnEnter", function() l1:SetVertexColor(1, 0.3, 0.3, 1); l2:SetVertexColor(1, 0.3, 0.3, 1) end)
                closeBtn:SetScript("OnLeave", function() l1:SetVertexColor(1, 1, 1, 1); l2:SetVertexColor(1, 1, 1, 1) end)
                closeBtn:SetScript("OnClick", function(self) self:GetParent():Hide() end)

                -- ESC to close (via UISpecialFrames)
                table.insert(UISpecialFrames, "MidnightUI_AddonChest")

                -- Pinned Header & Container
                local pinnedLabel = chestFrame:CreateFontString(nil, "OVERLAY")
                pinnedLabel:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
                pinnedLabel:SetPoint("TOPLEFT", 24, -70)
                pinnedLabel:SetText("PINNED TO DRAWER")
                pinnedLabel:SetTextColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
                
                local pinnedBg = CreateFrame("Frame", nil, chestFrame, "BackdropTemplate")
                pinnedBg:SetPoint("TOPLEFT", 20, -90); pinnedBg:SetSize(520, 90)
                pinnedBg:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=2})
                pinnedBg:SetBackdropColor(0.03, 0.03, 0.08, 0.85); pinnedBg:SetBackdropBorderColor(CLASS_COLOR[1]*0.4, CLASS_COLOR[2]*0.4, CLASS_COLOR[3]*0.4, 0.9)
                chestFrame.pinnedContainer = pinnedBg
                
                -- Available Header & Container
                local availableLabel = chestFrame:CreateFontString(nil, "OVERLAY")
                availableLabel:SetFont("Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
                availableLabel:SetPoint("TOPLEFT", 24, -190)
                availableLabel:SetText("AVAILABLE ADDONS")
                availableLabel:SetTextColor(0.8, 0.8, 0.85)
                
                local scrollBg = CreateFrame("Frame", nil, chestFrame, "BackdropTemplate")
                scrollBg:SetPoint("TOPLEFT", 20, -210); scrollBg:SetPoint("BOTTOMRIGHT", -20, 20)
                scrollBg:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=2})
                scrollBg:SetBackdropColor(0.02, 0.02, 0.05, 0.85); scrollBg:SetBackdropBorderColor(0.15, 0.15, 0.20, 0.9)
                
                local scrollFrame = CreateFrame("ScrollFrame", nil, scrollBg, "UIPanelScrollFrameTemplate")
                scrollFrame:SetPoint("TOPLEFT", 6, -6); scrollFrame:SetPoint("BOTTOMRIGHT", -26, 6)
                
                local availableContainer = CreateFrame("Frame", nil, scrollFrame)
                availableContainer:SetSize(420, 1)
                scrollFrame:SetScrollChild(availableContainer)
                chestFrame.availableContainer = availableContainer
                
                local function UpdateScrollbar()
                    local sh = scrollFrame.ScrollBar
                    if availableContainer:GetHeight() > scrollFrame:GetHeight() then sh:Show(); sh:SetMinMaxValues(0, availableContainer:GetHeight() - scrollFrame:GetHeight()); sh:SetValueStep(56)
                    else sh:Hide(); sh:SetValue(0) end
                end
                
                -- Populate Chest
                function chestFrame:UpdateChest()
                    for _, child in ipairs({self.pinnedContainer:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    for _, child in ipairs({self.availableContainer:GetChildren()}) do child:Hide(); child:SetParent(nil) end
                    
                    -- 1. Helper Function: Get Addon Name
                    local function GetAddonName(btn)
                        if btn.dataObject then return btn.dataObject.label or btn.dataObject.text or btn:GetName() or "Unknown" end
                        return "Unknown"
                    end
                    
                    -- 2. Cleanup ghost entries (names in addonOrder that don't exist)
                    for i = #LibDBIconDrawer.addonOrder, 1, -1 do
                        local name = LibDBIconDrawer.addonOrder[i]
                        local found = false
                        for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do
                            if GetAddonName(btn) == name then found = true; break end
                        end
                        if not found then
                            table.remove(LibDBIconDrawer.addonOrder, i)
                            LibDBIconDrawer.pinnedAddons[name] = nil
                        end
                    end
                    
                    -- 3. Count ACTUAL pinned icons (not duplicates, not ghosts)
                    self.activePinnedCount = 0
                    local seenPinned = {}
                    for _, name in ipairs(LibDBIconDrawer.addonOrder) do
                        if LibDBIconDrawer.pinnedAddons[name] and not seenPinned[name] then
                            self.activePinnedCount = self.activePinnedCount + 1
                            seenPinned[name] = true
                        end
                    end
                    
                    -- 4. Separate Pinned & Unpinned (prioritize addonOrder)
                    local pinnedBtns, unpinnedBtns, usedButtons = {}, {}, {}
                    
                    -- Add pinned buttons in order
                    for _, addonName in ipairs(LibDBIconDrawer.addonOrder) do
                        if LibDBIconDrawer.pinnedAddons[addonName] then
                            for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do
                                if GetAddonName(btn) == addonName and not usedButtons[btn] then
                                    table.insert(pinnedBtns, btn)
                                    usedButtons[btn] = true
                                    break
                                end
                            end
                        end
                    end
                    
                    -- Add all remaining (unpinned) buttons to available section
                    for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do
                        if not usedButtons[btn] then
                            table.insert(unpinnedBtns, btn)
                        end
                    end

                    -- 5. Helper to Create Icons
                    local function CreateChestIcon(parent, iconButton, isPinned, index)
                        local icon = CreateFrame("Button", nil, parent, "BackdropTemplate")
                        icon:SetSize(48, 48)
                        icon.addonName = GetAddonName(iconButton)
                        
                        icon:SetBackdrop({bgFile="Interface\\Buttons\\WHITE8x8", edgeFile="Interface\\Buttons\\WHITE8x8", edgeSize=2})
                        icon:SetBackdropColor(0.1, 0.1, 0.15, 0.9)
                        icon:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.9)
                        
                        local tex = icon:CreateTexture(nil, "ARTWORK")
                        tex:SetPoint("TOPLEFT", 4, -4); tex:SetPoint("BOTTOMRIGHT", -4, 4)
                        if iconButton.dataObject.icon then
                             local iconPath = iconButton.dataObject.icon
                             if type(iconPath) == "string" or type(iconPath) == "number" then tex:SetTexture(iconPath); tex:SetTexCoord(0.08,0.92,0.08,0.92) end
                        end
                        
                        if isPinned then
                            local pin = icon:CreateTexture(nil, "OVERLAY")
                            pin:SetSize(12, 12); pin:SetPoint("TOPRIGHT", -2, -2); pin:SetTexture("Interface\\Icons\\INV_Misc_Note_06"); pin:SetVertexColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3])
                            icon:SetMovable(true); icon:RegisterForDrag("LeftButton")
                            icon:SetScript("OnDragStart", function(self) self:SetParent(chestFrame); self:SetFrameStrata("DIALOG"); self:StartMoving() end)
                            icon:SetScript("OnDragStop", function(self)
                                self:StopMovingOrSizing()
                                local sourceIndex, targetIndex = nil, nil
                                for i, name in ipairs(LibDBIconDrawer.addonOrder) do if name == self.addonName then sourceIndex = i; break end end
                                
                                local container = chestFrame.pinnedContainer
                                if container then
                                    for _, child in ipairs({container:GetChildren()}) do
                                        if child ~= self and child:IsMouseOver() and child.addonName then
                                            for i, name in ipairs(LibDBIconDrawer.addonOrder) do if name == child.addonName then targetIndex = i; break end end
                                        end
                                        if targetIndex then break end
                                    end
                                end
                                if sourceIndex and targetIndex and sourceIndex ~= targetIndex then
                                    local name = self.addonName
                                    table.remove(LibDBIconDrawer.addonOrder, sourceIndex)
                                    table.insert(LibDBIconDrawer.addonOrder, targetIndex, name)
                                end
                                self:Hide(); self:SetParent(nil)
                                chestFrame:UpdateChest()
                                LibDBIconDrawer.RebuildDrawer()
                            end)
                        end
                        
                        icon:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(CLASS_COLOR[1], CLASS_COLOR[2], CLASS_COLOR[3], 1) end)
                        icon:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(0.25, 0.25, 0.3, 0.9) end)
                        
                        icon:RegisterForClicks("AnyUp")
                        icon:SetScript("OnClick", function(self, btn)
                            if btn == "LeftButton" then
                                local name = self.addonName
                                
                                -- [FIX ISSUE 1] Check current state dynamically instead of relying on isPinned parameter
                                local currentlyPinned = LibDBIconDrawer.pinnedAddons[name] ~= nil
                                
                                if currentlyPinned then
                                    -- UNPIN: Robust cleanup
                                    LibDBIconDrawer.pinnedAddons[name] = nil
                                    -- Remove ALL instances to clean up duplicates
                                    for i = #LibDBIconDrawer.addonOrder, 1, -1 do 
                                        if LibDBIconDrawer.addonOrder[i] == name then 
                                            table.remove(LibDBIconDrawer.addonOrder, i)
                                        end 
                                    end
                                else
                                    -- PIN
                                    if LibDBIconDrawer.pinnedAddons[name] then return end
                                    
                                    -- Check ACTIVE count (ignore ghosts), Limit 10
                                    if chestFrame.activePinnedCount >= 10 then 
                                        print("|cffff0000Maximum 10 addons can be pinned|r")
                                        return 
                                    end
                                    
                                    LibDBIconDrawer.pinnedAddons[name] = true
                                    table.insert(LibDBIconDrawer.addonOrder, name)
                                end
                                chestFrame:UpdateChest(); LibDBIconDrawer.RebuildDrawer()
                            end
                        end)
                        return icon
                    end
                    
                    -- 6. Render Pinned (With Wrapping)
                    for i, btn in ipairs(pinnedBtns) do
                        local icon = CreateChestIcon(self.pinnedContainer, btn, true, i)
                        -- Wrap at 8 icons
                        local col = (i - 1) % 8
                        local row = math.floor((i - 1) / 8)
                        -- Shift down if on row 2
                        icon:SetPoint("TOPLEFT", self.pinnedContainer, "TOPLEFT", 8 + (col * 56), -10 - (row * 56))
                    end
                    
                    -- 7. Render Available
                    local row, col = 0, 0
                    for i, btn in ipairs(unpinnedBtns) do
                        local icon = CreateChestIcon(self.availableContainer, btn, false, i)
                        icon:SetPoint("TOPLEFT", self.availableContainer, "TOPLEFT", 8 + (col * 56), -8 - (row * 56))
                        col = col + 1; if col >= 7 then col = 0; row = row + 1 end
                    end
                    
                    self.availableContainer:SetHeight(math.max(200, (row + 1) * 56 + 16))
                    UpdateScrollbar()
                end
                chestFrame:UpdateChest()
            end
            chestFrame:Show()
        end
    end)
end

local function ScanMinimapButtons()
    local found = 0
    for _, child in ipairs({Minimap:GetChildren()}) do
        if child:IsObjectType("Button") and child.dataObject then
            local alreadyAdded = false
            for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do if btn == child then alreadyAdded = true; break end end
            if not alreadyAdded then
                child:Hide(); child:SetAlpha(0); child:EnableMouse(false); child:SetParent(UIParent); child:ClearAllPoints(); child:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -200, -200)
                table.insert(LibDBIconDrawer.hiddenButtons, child)
                found = found + 1
            end
        end
    end
    if found > 0 and LibDBIconDrawer.RebuildDrawer then LibDBIconDrawer.RebuildDrawer() end
    return found
end

local function RestoreMinimapButtons()
    for _, btn in ipairs(LibDBIconDrawer.hiddenButtons) do
        btn:SetParent(Minimap)
        btn:ClearAllPoints()
        btn:SetAlpha(1)
        btn:EnableMouse(true)
        btn:Show()
    end
    LibDBIconDrawer.hiddenButtons = {}
end

local function HookLibDBIcon()
    if not LibStub then ScanMinimapButtons(); return end
    local LDBI = LibStub:GetLibrary("LibDBIcon-1.0", true)
    if LDBI then
        if LDBI.Register and not LDBI.MidnightUIHooked then
            hooksecurefunc(LDBI, "Register", function() C_Timer.After(0.5, function() ScanMinimapButtons() end) end)
            LDBI.MidnightUIHooked = true
        end
        if LDBI.objects then for name in pairs(LDBI.objects) do LDBI:GetMinimapButton(name) end end
    end
    ScanMinimapButtons()
end


-- =========================================================================
--  INITIALIZATION
-- =========================================================================
local initFrame = CreateFrame("Frame")
initFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
initFrame:SetScript("OnEvent", function()
    MidnightUI_InitMinimap()
    if MidnightUI_ApplyMinimapSettings then MidnightUI_ApplyMinimapSettings() end
    UpdateInfoBar()
    CreateLibDBIconDrawer()
    C_Timer.After(1, function() HookLibDBIcon() end)
    C_Timer.NewTicker(2, function() SetDefaultMinimapFramesHidden(true) end, 5)
    C_Timer.After(3, function() ScanMinimapButtons() end)
    C_Timer.NewTicker(30, function() ScanMinimapButtons() end, 10)
end)

-- Flush deferred drawer rebuild when combat ends
local drawerCombatFrame = CreateFrame("Frame")
drawerCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
drawerCombatFrame:SetScript("OnEvent", function()
    if LibDBIconDrawer and LibDBIconDrawer._pendingRebuild then
        LibDBIconDrawer._pendingRebuild = nil
        if LibDBIconDrawer.RebuildDrawer then
            LibDBIconDrawer.RebuildDrawer()
        end
    end
end)

