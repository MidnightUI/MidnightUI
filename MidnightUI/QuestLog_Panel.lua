-- =============================================================================
-- FILE PURPOSE:     Quest log side-panel renderer. Reads bucketed quest data from
--                   QuestLog_Data and builds the scrollable quest panel that slides
--                   out from the right edge of WorldMapFrame. Handles bucket headers,
--                   zone sub-headers, campaign cards, focus header, individual quest
--                   rows with inline accordion expansion, search filtering, and
--                   the empty-state view. Pure UI layer — no quest data collection.
-- LOAD ORDER:       Loads after QuestLog_Data.lua, before Map.lua. Contains same
--                   early-exit guard (useBlizzardQuestingInterface). Fails gracefully
--                   if QuestLogConfig, QuestData, or MapConfig are absent.
-- DEFINES:          Panel (file-local table) with:
--                   Panel._state{} — panel open/close state, focusedQuestID, ownerMap ref.
--                   Panel.EnsurePanel(map) — lazily creates "MidnightUIQuestLogPanel" frame.
--                   Panel.Open(map) / Panel.Close() — slide in/out with animation.
--                   Panel.Refresh() — re-renders the quest list from QuestData.CollectAll().
--                   Addon.Panel = Panel — exported for Map.lua to call.
-- READS:            Addon.QuestLogConfig (QLC) — all layout constants and bucket colors.
--                   Addon.QuestData (QD) — CollectAll() + Acquire/Release row pools.
--                   Addon.MapConfig (MC) — GetThemeColor, WHITE8X8.
--                   MidnightUISettings.General.useBlizzardQuestingInterface (early-exit gate).
-- WRITES:           Panel._state.panel — the created frame ref (created once, reused).
--                   Panel._state.panelOpen, focusedQuestID — runtime open/focus state.
-- DEPENDS ON:       Addon.QuestLogConfig (QLC) — must be loaded before this file.
--                   Addon.QuestData (QD) — must be loaded before this file.
--                   Addon.MapConfig (MC) — must be loaded before this file.
-- USED BY:          Map.lua — calls Panel.EnsurePanel, Panel.Open, Panel.Close, Panel.Refresh
--                   to drive the quest log button in the map header.
-- KEY FLOWS:
--   Map.lua questLog button click → Panel.Open(map)
--   Panel.Open → EnsurePanel (lazy build) → Panel.Refresh → QD.CollectAll()
--   → render: bucket headers → zone sub-headers → campaign cards → quest rows
--   Quest row click → accordion expand (inline objectives) → expand animation
--   Search input → debounced filter → re-render visible rows only
-- GOTCHAS:
--   Panel is parented to WorldMapFrame so it auto-hides when the map closes.
--   EnsurePanel returns early if the panel was already created (idempotent).
--   TC(key) delegates to MC.GetThemeColor() with a warm-gold fallback.
--   ApplyGradient: handles both SetGradientAlpha (pre-10.x) and SetGradient
--   (10.x+, requires CreateColor) for API version compatibility.
--   _searchTimer: debounced via C_Timer.After to avoid per-keystroke full re-renders.
-- NAVIGATION:
--   Panel._state{}        — runtime state (line ~33)
--   Panel.EnsurePanel()   — panel frame construction (search "function Panel.EnsurePanel")
--   Panel.Refresh()       — full quest list render (search "function Panel.Refresh")
-- =============================================================================
local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then
    ADDON_NAME = "MidnightUI"
end
if type(Addon) ~= "table" then
    Addon = {}
end

-- Master toggle: skip custom questing interface entirely when disabled
do
    local s = _G.MidnightUISettings
    if type(s) == "table" and type(s.General) == "table" and s.General.useBlizzardQuestingInterface == true then
        return
    end
end

local QLC = Addon.QuestLogConfig
if type(QLC) ~= "table" then return end

local QD = Addon.QuestData
if type(QD) ~= "table" then return end

local MC = Addon.MapConfig
if type(MC) ~= "table" then return end

local W8 = MC.WHITE8X8 or "Interface\\Buttons\\WHITE8x8"

local Panel = {}
Panel._state = {
    initialized = false,
    panelOpen = false,
    focusedQuestID = nil,
    pendingLayout = false,
    panel = nil,
    ownerMap = nil,
}

-- Helper: get theme color with fallback
local function TC(key)
    return MC.GetThemeColor(key)
end

-- Helper: clamp
local function Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Helper: create a chevron using the common-dropdown-icon-back atlas
-- Atlas points left by default. Rotated: down = expanded, right = collapsed.
local function CreateChevron(parent, size)
    size = size or 10
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(size, size)
    frame:EnableMouse(false)

    local icon = frame:CreateTexture(nil, "OVERLAY", nil, 5)
    icon:SetAtlas("common-dropdown-icon-back")
    icon:SetSize(size, size)
    icon:SetPoint("CENTER", frame, "CENTER", 0, 0)
    frame._icon = icon

    function frame:SetChevronColor(r, g, b, a)
        self._icon:SetVertexColor(r, g, b, a or 1)
    end

    function frame:SetExpanded(expanded)
        if expanded then
            -- Pointing down (left atlas rotated -90 degrees)
            self._icon:SetRotation(-math.pi / 2)
        else
            -- Pointing right (left atlas rotated 180 degrees)
            self._icon:SetRotation(math.pi)
        end
    end

    frame:SetChevronColor(1, 1, 1, 0.5)
    frame:SetExpanded(true)
    return frame
end

-- Helper: apply gradient (compat for 10.x+ where SetGradientAlpha was removed)
local function ApplyGradient(texture, orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    if not texture then return end
    if type(texture.SetGradientAlpha) == "function" then
        texture:SetGradientAlpha(orientation, r1, g1, b1, a1, r2, g2, b2, a2)
    elseif type(texture.SetGradient) == "function" and type(CreateColor) == "function" then
        texture:SetGradient(orientation, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    end
end

-- Helper: format time remaining
local function FormatTimeShort(seconds)
    if type(seconds) ~= "number" or seconds <= 0 then return "" end
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    if h > 0 then
        return string.format("%dh %dm", h, m)
    else
        return string.format("%dm", m)
    end
end

-- Debounce timer for search
local _searchTimer = nil

-- ── Section 1: Panel Shell ────────────────────────────────────────────
-- Creates the main panel frame anchored to the right of WorldMapFrame
-- Background, left accent, left shadow, header, search, scroll area
-- ======================================================================

function Panel.EnsurePanel(map)
    if Panel._state.panel then
        return Panel._state.panel
    end

    map = map or _G.WorldMapFrame
    if not map then return nil end

    Panel._state.ownerMap = map

    local panelWidth = QLC.PANEL_WIDTH
    local headerHeight = QLC.PANEL_HEADER_HEIGHT
    local searchHeight = QLC.PANEL_SEARCH_HEIGHT

    -- Main panel frame (parented to map so it hides/shows with the map)
    local panel = CreateFrame("Frame", "MidnightUIQuestLogPanel", map)
    panel:SetFrameStrata(QLC.PANEL_STRATA)
    local okLevel, mapLevel = pcall(function() return map:GetFrameLevel() end)
    local baseLevel = (okLevel and type(mapLevel) == "number") and mapLevel or 10
    panel:SetFrameLevel(baseLevel + 26)
    -- No SetClipsChildren — scroll frame handles its own clipping.
    -- This allows the left border and shadow to render outside panel bounds.
    panel:SetSize(panelWidth, 1)
    -- Anchor to WorldMapFrame. The +2 top offset aligns the quest log's
    -- visual top edge with the map header's 2px top accent line.
    panel:SetPoint("TOPLEFT", map, "TOPRIGHT", 3, 0)
    panel:SetPoint("BOTTOMLEFT", map, "BOTTOMRIGHT", 0, 0)

    -- (left border added below after acR is defined)
    panel:Hide()

    -- Background
    local bg = panel:CreateTexture(nil, "BACKGROUND", nil, -8)
    bg:SetAllPoints()
    bg:SetTexture(W8)
    local bgR, bgG, bgB = TC("bgPanel")
    bg:SetVertexColor(bgR, bgG, bgB, 0.96)
    panel._muiBg = bg

    -- Right accent bar (3px, continuous, warm gold)
    local acR, acG, acB = TC("accent")
    local rightAccent = panel:CreateTexture(nil, "BACKGROUND", nil, -6)
    rightAccent:SetWidth(1)
    rightAccent:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    rightAccent:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", 0, 0)
    rightAccent:SetTexture(W8)
    rightAccent:SetVertexColor(acR, acG, acB, 0.85)
    panel._muiRightAccent = rightAccent

    -- (no left border line)

    -- Left shadow (20px, anchored to left edge of panel, extending leftward)
    local leftShadow = panel:CreateTexture(nil, "BACKGROUND", nil, -7)
    leftShadow:SetWidth(20)
    leftShadow:SetPoint("TOPRIGHT", panel, "TOPLEFT", 0, 0)
    leftShadow:SetPoint("BOTTOMRIGHT", panel, "BOTTOMLEFT", 0, 0)
    leftShadow:SetTexture(W8)
    ApplyGradient(leftShadow, "HORIZONTAL", 0, 0, 0, 0, 0, 0, 0, 0.45)
    panel._muiLeftShadow = leftShadow

    -- Top line (2px gold, matching map header)
    local topLine = panel:CreateTexture(nil, "ARTWORK", nil, 1)
    topLine:SetHeight(2)
    topLine:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    topLine:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    topLine:SetTexture(W8)
    topLine:SetVertexColor(acR, acG, acB, 0.85)
    panel._muiTopLine = topLine

    -- ── Title bar (compact, 36px) ──
    local titleBarHeight = 36
    local header = CreateFrame("Frame", nil, panel)
    header:SetHeight(titleBarHeight)
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, 0)
    panel._muiHeader = header

    local title = header:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("LEFT", header, "LEFT", 14, 0)
    local tpR, tpG, tpB = TC("textPrimary")
    title:SetTextColor(tpR, tpG, tpB, 1)
    title:SetText("Quest Log")
    panel._muiTitle = title

    local count = header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    count:SetPoint("LEFT", title, "RIGHT", 8, 0)
    local tmR, tmG, tmB = TC("textMuted")
    count:SetTextColor(tmR, tmG, tmB, 0.70)
    count:SetText("")
    panel._muiCount = count

    -- Close button
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(20, 20)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -10, 0)
    local closeText = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    closeText:SetPoint("CENTER", closeBtn, "CENTER", 0, 0)
    local tsR, tsG, tsB = TC("textSecondary")
    closeText:SetTextColor(tsR, tsG, tsB, 0.60)
    closeText:SetText("\195\151")
    closeBtn._muiText = closeText
    closeBtn:SetScript("OnEnter", function(self)
        local ar, ag, ab = TC("accent")
        self._muiText:SetTextColor(ar, ag, ab, 1)
    end)
    closeBtn:SetScript("OnLeave", function(self)
        local sr, sg, sb = TC("textSecondary")
        self._muiText:SetTextColor(sr, sg, sb, 0.60)
    end)
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)
    panel._muiCloseBtn = closeBtn

    local bdR, bdG, bdB = TC("border")
    local bprR, bprG, bprB = TC("bgPanelRaised")

    -- ── Campaign hero card (below title, the star) ──
    local campaignHost = CreateFrame("Frame", nil, panel)
    campaignHost:SetHeight(1)
    campaignHost:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    campaignHost:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", -2, 0)
    campaignHost:Hide()
    panel._muiCampaignHost = campaignHost

    -- Campaign raised background
    local campBg = campaignHost:CreateTexture(nil, "BACKGROUND", nil, -4)
    campBg:SetAllPoints()
    campBg:SetTexture(W8)
    campBg:SetVertexColor(bprR, bprG, bprB, 0.70)

    -- Campaign top glow (warm gold gradient fading down)
    local campGlow = campaignHost:CreateTexture(nil, "BACKGROUND", nil, -3)
    campGlow:SetPoint("TOPLEFT", campaignHost, "TOPLEFT", 0, 0)
    campGlow:SetPoint("TOPRIGHT", campaignHost, "TOPRIGHT", 0, 0)
    campGlow:SetHeight(40)
    campGlow:SetTexture(W8)
    ApplyGradient(campGlow, "VERTICAL", acR, acG, acB, 0.00, acR, acG, acB, 0.10)

    -- Campaign title (large, prominent)
    local campTitle = campaignHost:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    campTitle:SetPoint("TOPLEFT", campaignHost, "TOPLEFT", 14, -10)
    campTitle:SetTextColor(tpR, tpG, tpB, 1)
    panel._muiCampTitle = campTitle

    -- Campaign progress fraction (right-aligned with title)
    local campProgress = campaignHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    campProgress:SetPoint("TOPRIGHT", campaignHost, "TOPRIGHT", -14, -14)
    campProgress:SetTextColor(acR, acG, acB, 0.85)
    panel._muiCampProgress = campProgress

    -- Chapter name (below title)
    local campChapter = campaignHost:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    campChapter:SetPoint("TOPLEFT", campaignHost, "TOPLEFT", 14, -30)
    campChapter:SetPoint("RIGHT", campaignHost, "RIGHT", -60, 0)
    campChapter:SetJustifyH("LEFT")
    campChapter:SetWordWrap(false)
    campChapter:SetTextColor(tmR, tmG, tmB, 0.60)
    panel._muiCampChapter = campChapter

    -- Campaign progress bar (full width, 4px)
    local ptC = QLC.COLORS.progressTrack
    local campTrack = campaignHost:CreateTexture(nil, "ARTWORK", nil, 1)
    campTrack:SetHeight(4)
    campTrack:SetPoint("BOTTOMLEFT", campaignHost, "BOTTOMLEFT", 14, 8)
    campTrack:SetPoint("BOTTOMRIGHT", campaignHost, "BOTTOMRIGHT", -14, 8)
    campTrack:SetTexture(W8)
    campTrack:SetVertexColor(ptC.r, ptC.g, ptC.b, 0.30)
    panel._muiCampTrack = campTrack

    local campFill = campaignHost:CreateTexture(nil, "ARTWORK", nil, 2)
    campFill:SetHeight(4)
    campFill:SetPoint("BOTTOMLEFT", campaignHost, "BOTTOMLEFT", 14, 8)
    campFill:SetTexture(W8)
    campFill:SetVertexColor(acR, acG, acB, 0.70)
    campFill:SetWidth(1)
    panel._muiCampFill = campFill

    -- Campaign bottom edge (gold line)
    local campBottomLine = campaignHost:CreateTexture(nil, "ARTWORK", nil, 3)
    campBottomLine:SetHeight(1)
    campBottomLine:SetPoint("BOTTOMLEFT", campaignHost, "BOTTOMLEFT", 0, 0)
    campBottomLine:SetPoint("BOTTOMRIGHT", campaignHost, "BOTTOMRIGHT", 0, 0)
    campBottomLine:SetTexture(W8)
    campBottomLine:SetVertexColor(acR, acG, acB, 0.30)

    -- ── Search box (below campaign, minimal — just an underlined input) ──
    local searchBox = CreateFrame("EditBox", nil, panel)
    searchBox:SetHeight(26)
    searchBox:SetAutoFocus(false)
    searchBox:SetFontObject(GameFontHighlightSmall)
    searchBox:SetTextColor(tpR, tpG, tpB, 1)
    searchBox:SetMaxLetters(64)
    searchBox:SetTextInsets(14, 14, 0, 0)
    panel._muiSearchBox = searchBox

    -- Search underline only (no box, no background — clean and minimal)
    local searchUnderline = searchBox:CreateTexture(nil, "BORDER")
    searchUnderline:SetHeight(1)
    searchUnderline:SetPoint("BOTTOMLEFT", searchBox, "BOTTOMLEFT", 14, 0)
    searchUnderline:SetPoint("BOTTOMRIGHT", searchBox, "BOTTOMRIGHT", -14, 0)
    searchUnderline:SetTexture(W8)
    searchUnderline:SetVertexColor(bdR, bdG, bdB, 0.20)
    searchBox._muiUnderline = searchUnderline

    -- Placeholder
    local placeholder = searchBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    placeholder:SetPoint("LEFT", searchBox, "LEFT", 14, 0)
    placeholder:SetTextColor(tmR, tmG, tmB, 0.45)
    placeholder:SetText("Search Quests...")
    searchBox._muiPlaceholder = placeholder

    searchBox:SetScript("OnEditFocusGained", function(self)
        self._muiPlaceholder:Hide()
    end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then self._muiPlaceholder:Show() end
    end)
    searchBox:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            if self:GetText() == "" then self._muiPlaceholder:Show()
            else self._muiPlaceholder:Hide() end
            if _searchTimer then pcall(function() _searchTimer:Cancel() end) end
            local ok, timer = pcall(function()
                return C_Timer.NewTimer(0.25, function() Panel.Rebuild() end)
            end)
            if ok and timer then _searchTimer = timer else Panel.Rebuild() end
        end
    end)
    searchBox:SetScript("OnEscapePressed", function(self)
        self:ClearFocus(); self:SetText(""); self._muiPlaceholder:Show(); Panel.Rebuild()
    end)
    searchBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

    -- ── Content scroll area (below search, dynamically anchored in Rebuild) ──
    local scrollFrame = CreateFrame("ScrollFrame", nil, panel, "UIPanelScrollFrameTemplate")
    panel._muiScrollFrame = scrollFrame

    -- Hide default scrollbar art if present
    local scrollBar = scrollFrame.ScrollBar or _G[scrollFrame:GetName() and (scrollFrame:GetName() .. "ScrollBar") or ""]
    if scrollBar then
        local okHideArt = pcall(function()
            if scrollBar.ScrollUpButton then scrollBar.ScrollUpButton:SetAlpha(0) end
            if scrollBar.ScrollDownButton then scrollBar.ScrollDownButton:SetAlpha(0) end
            local thumbTex = scrollBar.ThumbTexture or scrollBar:GetThumbTexture()
            if thumbTex then
                thumbTex:SetTexture(W8)
                thumbTex:SetVertexColor(acR, acG, acB, 0.30)
                thumbTex:SetWidth(4)
            end
            scrollBar:SetWidth(4)
        end)
    end

    -- Scroll child
    local scrollChild = CreateFrame("Frame", nil, scrollFrame)
    scrollChild:SetWidth(panelWidth - 16)
    scrollChild:SetHeight(1)
    scrollFrame:SetScrollChild(scrollChild)
    panel._muiScrollChild = scrollChild

    -- Slide animations
    local slideInGroup = panel:CreateAnimationGroup()
    local slideInTrans = slideInGroup:CreateAnimation("Translation")
    slideInTrans:SetOffset(-panelWidth, 0)
    slideInTrans:SetDuration(0)
    slideInTrans:SetOrder(1)
    local slideInTrans2 = slideInGroup:CreateAnimation("Translation")
    slideInTrans2:SetOffset(panelWidth, 0)
    slideInTrans2:SetDuration(QLC.PANEL_SLIDE_DURATION)
    slideInTrans2:SetSmoothing("OUT")
    slideInTrans2:SetOrder(2)
    local slideInAlpha = slideInGroup:CreateAnimation("Alpha")
    slideInAlpha:SetFromAlpha(0)
    slideInAlpha:SetToAlpha(1)
    slideInAlpha:SetDuration(QLC.PANEL_SLIDE_DURATION)
    slideInAlpha:SetOrder(2)
    slideInGroup:SetScript("OnFinished", function()
        panel:SetAlpha(1)
    end)
    panel._muiSlideIn = slideInGroup

    local slideOutGroup = panel:CreateAnimationGroup()
    local slideOutTrans = slideOutGroup:CreateAnimation("Translation")
    slideOutTrans:SetOffset(-panelWidth, 0)
    slideOutTrans:SetDuration(QLC.PANEL_SLIDE_DURATION)
    slideOutTrans:SetSmoothing("IN")
    slideOutTrans:SetOrder(1)
    local slideOutAlpha = slideOutGroup:CreateAnimation("Alpha")
    slideOutAlpha:SetFromAlpha(1)
    slideOutAlpha:SetToAlpha(0)
    slideOutAlpha:SetDuration(QLC.PANEL_SLIDE_DURATION)
    slideOutAlpha:SetOrder(1)
    slideOutGroup:SetScript("OnFinished", function()
        panel:Hide()
        panel:SetAlpha(1)
        Panel._state.panelOpen = false
    end)
    panel._muiSlideOut = slideOutGroup

    Panel._state.panel = panel
    Panel._state.initialized = true
    return panel
end


-- ── Section 2: Campaign Card ──────────────────────────────────────────
-- Campaign progress widget at top of quest list
-- ======================================================================

function Panel.CreateCampaignCard(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(QLC.CAMPAIGN_CARD_HEIGHT)

    -- Background
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -4)
    bg:SetAllPoints()
    bg:SetTexture(W8)
    local bprR, bprG, bprB = TC("bgPanelRaised")
    bg:SetVertexColor(bprR, bprG, bprB, 0.60)

    -- Left accent bar (3px gold, indented past panel accent)
    local accent = frame:CreateTexture(nil, "ARTWORK", nil, 0)
    accent:SetWidth(3)
    accent:SetPoint("TOPLEFT", frame, "TOPLEFT", 6, -4)
    accent:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 6, 4)
    accent:SetTexture(W8)
    local acR, acG, acB = TC("accent")
    accent:SetVertexColor(acR, acG, acB, 0.85)

    -- Title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -10)
    local tpR, tpG, tpB = TC("textPrimary")
    title:SetTextColor(tpR, tpG, tpB, 1)
    frame._muiTitle = title

    -- Progress text (right side)
    local progressText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressText:SetPoint("RIGHT", frame, "RIGHT", -16, -10 + (QLC.CAMPAIGN_CARD_HEIGHT / 2))
    progressText:SetPoint("TOP", frame, "TOP", 0, -10)
    local tmR, tmG, tmB = TC("textMuted")
    progressText:SetTextColor(tmR, tmG, tmB, 1)
    frame._muiProgressText = progressText

    -- Chapter
    local chapter = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    chapter:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -28)
    chapter:SetTextColor(tmR, tmG, tmB, 0.65)
    frame._muiChapter = chapter

    -- Progress bar track (6px at bottom)
    local trackHeight = QLC.CAMPAIGN_PROGRESS_HEIGHT
    local pTrack = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    pTrack:SetHeight(trackHeight)
    pTrack:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    pTrack:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    pTrack:SetTexture(W8)
    local ptC = QLC.COLORS.progressTrack
    pTrack:SetVertexColor(ptC.r, ptC.g, ptC.b, ptC.a or 0.20)
    frame._muiProgressTrack = pTrack

    -- Progress bar fill
    local pFill = frame:CreateTexture(nil, "ARTWORK", nil, 2)
    pFill:SetHeight(trackHeight)
    pFill:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    pFill:SetTexture(W8)
    pFill:SetVertexColor(acR, acG, acB, 0.60)
    pFill:SetWidth(1)
    frame._muiProgressFill = pFill

    -- Bottom divider
    local divider = frame:CreateTexture(nil, "ARTWORK", nil, 3)
    divider:SetHeight(1)
    divider:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    divider:SetTexture(W8)
    local bdR, bdG, bdB = TC("border")
    divider:SetVertexColor(bdR, bdG, bdB, 0.30)

    function frame:SetCampaignData(data)
        if type(data) ~= "table" then
            self:Hide()
            return
        end
        self._muiTitle:SetText(data.name or "Campaign")
        local prog = data.progress or 0
        local tot = data.total or 1
        if tot < 1 then tot = 1 end
        self._muiProgressText:SetText(string.format("%d/%d", prog, tot))
        self._muiChapter:SetText(data.chapterName or "")

        local fillFrac = Clamp(prog / tot, 0, 1)
        local totalWidth = self:GetWidth()
        if totalWidth < 1 then totalWidth = QLC.PANEL_WIDTH end
        local fillWidth = math.max(1, math.floor(totalWidth * fillFrac))
        self._muiProgressFill:SetWidth(fillWidth)
        -- Deferred update once frame has actual width
        if C_Timer and type(C_Timer.After) == "function" then
            local selfRef = self
            C_Timer.After(0, function()
                if selfRef and selfRef:GetWidth() > 1 then
                    selfRef._muiProgressFill:SetWidth(math.max(1, math.floor(selfRef:GetWidth() * fillFrac)))
                end
            end)
        end
        self:Show()
    end

    return frame
end


-- ── Section 3: Bucket Headers ─────────────────────────────────────────
-- NOW / NEXT / LATER collapsible section headers
-- ======================================================================

function Panel.CreateBucketHeader(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QLC.BUCKET_HEADER_HEIGHT)

    -- Full-width subtle background
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -4)
    bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    bg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
    bg:SetTexture(W8)
    btn._muiBg = bg

    -- Gradient glow (conditional smart sections only)
    local glow = btn:CreateTexture(nil, "BACKGROUND", nil, -3)
    glow:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    glow:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
    glow:SetTexture(W8)
    glow:Hide()
    btn._muiGlow = glow

    -- Label (left)
    local label = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    label:SetPoint("LEFT", btn, "LEFT", 14, 0)
    btn._muiLabel = label

    -- Count pill (right of label — small rounded count badge)
    local countPill = btn:CreateTexture(nil, "ARTWORK", nil, 0)
    countPill:SetTexture(W8)
    countPill:SetHeight(16)
    btn._muiCountPill = countPill

    local countText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    btn._muiCount = countText

    -- Chevron (far right)
    local chevron = CreateChevron(btn, 10)
    chevron:SetPoint("RIGHT", btn, "RIGHT", -14, 0)
    btn._muiChevron = chevron

    -- Bottom edge line
    local bottomLine = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    bottomLine:SetHeight(1)
    bottomLine:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
    bottomLine:SetTexture(W8)
    btn._muiBottomLine = bottomLine

    -- Hover
    local highlight = btn:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
    highlight:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -2, 0)
    highlight:SetTexture(W8)
    local acR, acG, acB = TC("accent")
    highlight:SetVertexColor(acR, acG, acB, 0.06)

    btn._muiBucketKey = nil

    btn:SetScript("OnClick", function(self)
        local key = self._muiBucketKey
        if key then
            QD._bucketCollapseState[key] = not QD._bucketCollapseState[key]
            Panel.Rebuild()
        end
    end)

    function btn:SetBucketData(bucketKey, questCount, isCollapsed)
        self._muiBucketKey = bucketKey
        local bR, bG, bB = QLC.GetBucketColor(bucketKey)

        -- Full-width tinted background (stronger for conditional sections)
        local isConditional = (bucketKey == "turnIn" or bucketKey == "expiring")
        self._muiBg:SetVertexColor(bR, bG, bB, isConditional and 0.10 or 0.06)

        -- Gradient glow for conditional sections
        if self._muiGlow then
            if isConditional then
                ApplyGradient(self._muiGlow, "HORIZONTAL", bR, bG, bB, 0.15, bR, bG, bB, 0.00)
                self._muiGlow:Show()
            else
                self._muiGlow:Hide()
            end
        end

        -- Label
        self._muiLabel:SetText(QLC.BUCKET_LABELS[bucketKey] or bucketKey:upper())
        self._muiLabel:SetTextColor(bR, bG, bB, 0.90)

        -- Count pill: right-aligned to match quest row percentages
        self._muiCount:SetText(tostring(questCount))
        self._muiCount:SetTextColor(bR, bG, bB, 0.80)
        self._muiCount:ClearAllPoints()
        self._muiCount:SetPoint("RIGHT", self, "RIGHT", -36, 0)
        self._muiCount:SetJustifyH("RIGHT")

        local countW = math.max(16, (self._muiCount:GetStringWidth() or 8) + 10)
        self._muiCountPill:SetWidth(countW)
        self._muiCountPill:SetVertexColor(bR, bG, bB, 0.15)
        self._muiCountPill:ClearAllPoints()
        self._muiCountPill:SetPoint("CENTER", self._muiCount, "CENTER", 0, 0)

        -- Bottom line
        self._muiBottomLine:SetVertexColor(bR, bG, bB, 0.12)

        -- Chevron
        self._muiChevron:SetExpanded(not isCollapsed)
        self._muiChevron:SetChevronColor(bR, bG, bB, 0.45)

        self:Show()
    end

    return btn
end


-- ── Section 4: Zone Sub-Headers ───────────────────────────────────────
-- Zone grouping within buckets
-- ======================================================================

function Panel.CreateZoneHeader(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QLC.ZONE_HEADER_HEIGHT)

    -- Zone name (left-aligned, muted uppercase)
    local zoneName = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    zoneName:SetPoint("LEFT", btn, "LEFT", 14, 0)
    btn._muiZoneName = zoneName

    -- Count (right of zone name)
    local countText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    countText:SetPoint("RIGHT", btn, "RIGHT", -36, 0)
    local tmR, tmG, tmB = TC("textMuted")
    local tsR2, tsG2, tsB2 = TC("textSecondary")
    countText:SetTextColor(tsR2, tsG2, tsB2, 0.75)
    btn._muiCount = countText

    -- Chevron (drawn with textures)
    local chevron = CreateChevron(btn, 10)
    chevron:SetPoint("RIGHT", btn, "RIGHT", -14, 0)
    chevron:SetChevronColor(tmR, tmG, tmB, 0.30)
    btn._muiChevron = chevron

    -- Thin top divider line
    local divider = btn:CreateTexture(nil, "ARTWORK", nil, 0)
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", btn, "TOPLEFT", 14, 0)
    divider:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -14, 0)
    divider:SetTexture(W8)
    local bdR, bdG, bdB = TC("border")
    divider:SetVertexColor(bdR, bdG, bdB, 0.08)

    btn._muiZoneNameKey = nil

    btn:SetScript("OnClick", function(self)
        local key = self._muiZoneNameKey
        if key then
            QD._collapseState[key] = not QD._collapseState[key]
            Panel.Rebuild()
        end
    end)

    function btn:SetZoneHeaderData(zoneNameStr, questCount, isCurrentZone, isCollapsed)
        self._muiZoneNameKey = zoneNameStr

        local displayName = zoneNameStr or ""
        if isCurrentZone then
            local tpR, tpG, tpB = TC("textPrimary")
            self._muiZoneName:SetTextColor(tpR, tpG, tpB, 0.85)
        else
            local tsR2, tsG2, tsB2 = TC("textSecondary")
            self._muiZoneName:SetTextColor(tsR2, tsG2, tsB2, 0.70)
        end

        self._muiZoneName:SetText(displayName)
        self._muiCount:SetText(tostring(questCount))
        self._muiChevron:SetExpanded(not isCollapsed)
        self:Show()
    end

    return btn
end


-- ── Section 5: Quest Rows ─────────────────────────────────────────────
-- Quest row with accent bar, title, objective summary, progress
-- ======================================================================

function Panel.CreateQuestRow(parent)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(QLC.QUEST_ROW_HEIGHT)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Hover/state background
    local bg = btn:CreateTexture(nil, "BACKGROUND", nil, -4)
    bg:SetPoint("TOPLEFT", btn, "TOPLEFT", 4, 0)
    bg:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -4, 0)
    bg:SetTexture(W8)
    bg:SetVertexColor(0, 0, 0, 0)
    btn._muiBg = bg

    -- Complete state: left accent bar (3px green, flush left, only shown for complete quests)
    local completeAccent = btn:CreateTexture(nil, "ARTWORK", nil, 1)
    completeAccent:SetWidth(3)
    completeAccent:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, -2)
    completeAccent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 2)
    completeAccent:SetTexture(W8)
    local scR, scG, scB = QLC.COLORS.success.r, QLC.COLORS.success.g, QLC.COLORS.success.b
    completeAccent:SetVertexColor(scR, scG, scB, 0.70)
    completeAccent:Hide()
    btn._muiCompleteAccent = completeAccent

    -- Complete state: "TURN IN" pill badge (top-right)
    local completeBadge = CreateFrame("Frame", nil, btn)
    completeBadge:SetHeight(16)
    completeBadge:SetPoint("RIGHT", btn, "RIGHT", -10, 4)
    -- Pill background
    local completePillBg = completeBadge:CreateTexture(nil, "BACKGROUND")
    completePillBg:SetAllPoints()
    completePillBg:SetTexture(W8)
    completePillBg:SetVertexColor(scR, scG, scB, 0.20)
    -- Pill text
    local completePillText = completeBadge:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    completePillText:SetPoint("CENTER", completeBadge, "CENTER", 0, 0)
    completePillText:SetText("TURN IN")
    completePillText:SetTextColor(scR, scG, scB, 0.90)
    -- Size pill to text
    completeBadge:SetWidth(completePillText:GetStringWidth() + 12)
    completeBadge:Hide()
    btn._muiCompleteIcon = completeBadge

    -- Bottom separator
    local sep = btn:CreateTexture(nil, "ARTWORK", nil, -1)
    sep:SetHeight(1)
    sep:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 16, 0)
    sep:SetPoint("BOTTOMRIGHT", btn, "BOTTOMRIGHT", -14, 0)
    sep:SetTexture(W8)
    local bdR, bdG, bdB = TC("border")
    sep:SetVertexColor(bdR, bdG, bdB, 0.06)
    btn._muiSep = sep

    -- Title
    local title = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    title:SetPoint("TOPLEFT", btn, "TOPLEFT", 14, -7)
    title:SetPoint("RIGHT", btn, "RIGHT", -58, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    btn._muiTitle = title

    -- Progress text (right-aligned with title line)
    local progressText = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    progressText:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -14, -7)
    btn._muiProgressText = progressText

    -- Objective summary (below title, muted)
    local objSummary = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    objSummary:SetPoint("TOPLEFT", btn, "TOPLEFT", 14, -24)
    objSummary:SetPoint("RIGHT", btn, "RIGHT", -70, 0)
    objSummary:SetJustifyH("LEFT")
    objSummary:SetWordWrap(false)
    btn._muiObjSummary = objSummary

    -- Status tag pill (sits at end of objective summary line, not stacked under %)
    local tagPill = CreateFrame("Frame", nil, btn)
    tagPill:SetHeight(14)
    tagPill:SetWidth(1) -- sized dynamically
    local tagPillBg = tagPill:CreateTexture(nil, "BACKGROUND", nil, -1)
    tagPillBg:SetAllPoints()
    tagPillBg:SetTexture(W8)
    tagPill._muiBg = tagPillBg
    local tagPillText = tagPill:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
    tagPillText:SetPoint("CENTER", tagPill, "CENTER", 0, 0)
    tagPill._muiText = tagPillText
    tagPill:Hide()
    btn._muiStatusTag = tagPill

    -- Store accent color for expansion panel to inherit
    btn._muiAccentColor = { r = 0.45, g = 0.72, b = 0.92 }
    btn._muiQuestID = nil
    btn._muiQuestTitle = nil
    btn._muiBucketKey = nil

    -- Hover (state-aware: complete=green, expiring=orange, default=neutral)
    btn:SetScript("OnEnter", function(self)
        if self._muiIsComplete then
            local sc = QLC.COLORS.success
            self._muiBg:SetVertexColor(sc.r, sc.g, sc.b, 0.14)
        elseif self._muiIsExpiring then
            local wc = QLC.COLORS.warning
            self._muiBg:SetVertexColor(wc.r, wc.g, wc.b, 0.12)
        else
            local bpaR, bpaG, bpaB = TC("bgPanelAlt")
            self._muiBg:SetVertexColor(bpaR, bpaG, bpaB, 0.30)
        end
    end)
    btn:SetScript("OnLeave", function(self)
        if self._muiIsComplete then
            local sc = QLC.COLORS.success
            self._muiBg:SetVertexColor(sc.r, sc.g, sc.b, 0.08)
        elseif self._muiIsExpiring then
            local wc = QLC.COLORS.warning
            self._muiBg:SetVertexColor(wc.r, wc.g, wc.b, 0.05)
        else
            self._muiBg:SetVertexColor(0, 0, 0, 0)
        end
    end)

    -- Click handlers
    btn:SetScript("OnClick", function(self, button)
        local questID = self._muiQuestID
        if not questID then return end
        if button == "RightButton" then
            Panel.OpenContextMenu(self, questID, self._muiQuestTitle or "")
        else
            if QD._expandedQuests[questID] then
                QD._expandedQuests[questID] = nil
            else
                QD._expandedQuests[questID] = true
            end
            Panel.Rebuild()
        end
    end)

    function btn:SetQuestData(questData, bucketKey)
        if type(questData) ~= "table" then
            self:Hide()
            return
        end

        self._muiQuestID = questData.questID
        self._muiQuestTitle = questData.title
        self._muiBucketKey = bucketKey

        local successC = QLC.COLORS.success
        local diffColor = questData._difficultyColor or QLC.DIFFICULTY_COLORS.standard
        local tpR, tpG, tpB = TC("textPrimary")
        local bdR, bdG, bdB = TC("border")

        -- Use isComplete from the data layer (set during collection)
        local isComplete = questData.isComplete
        self._muiIsComplete = isComplete

        -- Store bucket color for expansion panel
        local bR, bG, bB = QLC.GetBucketColor(bucketKey or "later")
        self._muiAccentColor = { r = bR, g = bG, b = bB }

        -- ── Visual state ──
        if isComplete then
            -- ── COMPLETE: distinct green card treatment ──
            self._muiIsExpiring = false
            self._muiBg:SetVertexColor(successC.r, successC.g, successC.b, 0.10)
            self._muiCompleteAccent:SetVertexColor(successC.r, successC.g, successC.b, 0.70)
            self._muiCompleteAccent:Show()
            self._muiCompleteIcon:Show()
            self._muiProgressText:Hide()
            self._muiTitle:SetText(questData.title or "")
            self._muiTitle:SetTextColor(tpR, tpG, tpB, 0.90)
            local turnInZone = questData.headerTitle
            if type(turnInZone) == "string" and turnInZone ~= "" then
                self._muiObjSummary:SetText("Turn in \194\183 " .. turnInZone)
            else
                self._muiObjSummary:SetText("Ready for turn-in")
            end
            self._muiObjSummary:SetTextColor(successC.r, successC.g, successC.b, 0.70)
            self._muiObjSummary:Show()
            self._muiSep:SetVertexColor(successC.r, successC.g, successC.b, 0.15)
        else
            -- ── IN PROGRESS ──
            self._muiIsExpiring = (bucketKey == "expiring")
            self._muiCompleteIcon:Hide()
            self._muiProgressText:Show()

            if self._muiIsExpiring then
                -- Warm orange tint for expiring quests
                local warnC = QLC.COLORS.warning
                self._muiBg:SetVertexColor(warnC.r, warnC.g, warnC.b, 0.05)
                self._muiCompleteAccent:SetVertexColor(warnC.r, warnC.g, warnC.b, 0.70)
                self._muiCompleteAccent:Show()
                self._muiSep:SetVertexColor(warnC.r, warnC.g, warnC.b, 0.12)
            else
                self._muiBg:SetVertexColor(0, 0, 0, 0)
                self._muiCompleteAccent:Hide()
                self._muiSep:SetVertexColor(bdR, bdG, bdB, 0.06)
            end

            -- Title in difficulty color
            self._muiTitle:SetText(questData.title or "")
            self._muiTitle:SetTextColor(diffColor.r, diffColor.g, diffColor.b, 0.95)
            -- Progress percentage
            local _, _, pct = QD.ResolveQuestObjectiveProgress(questData)
            pct = pct or 0
            local pctVal = math.floor(pct * 100)
            self._muiProgressText:SetText(pctVal .. "%")
            local tmR, tmG, tmB = TC("textMuted")
            if pctVal >= 80 then
                local wR, wG, wB = TC("accent")
                self._muiProgressText:SetTextColor(wR, wG, wB, 0.80)
            elseif pctVal >= 50 then
                local tsR, tsG, tsB = TC("textSecondary")
                self._muiProgressText:SetTextColor(tsR, tsG, tsB, 0.80)
            else
                self._muiProgressText:SetTextColor(tmR, tmG, tmB, 0.60)
            end
        end

        -- ── Objective summary (skip for complete — already set above) ──
        local objRows = QD.BuildQuestObjectiveDisplayRows(questData)
        if isComplete then
            -- Already set in the visual state block above
        elseif objRows and #objRows > 0 then
            local firstObj = objRows[1]
            local parts = {}
            -- Prepend zone for expiring quests (extracted from spatial context)
            if self._muiIsExpiring and type(questData.headerTitle) == "string" and questData.headerTitle ~= "" then
                parts[#parts + 1] = questData.headerTitle
            end
            if firstObj.text then parts[#parts + 1] = firstObj.text end
            if firstObj.progressText then parts[#parts + 1] = firstObj.progressText end
            self._muiObjSummary:SetText(table.concat(parts, " \194\183 "))
            local tsR, tsG, tsB = TC("textSecondary")
            self._muiObjSummary:SetTextColor(tsR, tsG, tsB, 0.55)
            self._muiObjSummary:Show()
        else
            self._muiObjSummary:SetText("")
            self._muiObjSummary:Hide()
        end

        -- ── Status tag pill (inline with objective line) ──
        local tagText = ""
        local tagR, tagG, tagB = TC("textMuted")
        local tagBgA = 0.12

        if isComplete then
            -- TURN IN badge handles it
        elseif questData._isExpiringSoon then
            local warnC = QLC.COLORS.warning
            tagText = FormatTimeShort(questData._expiresInSeconds or 0)
            tagR, tagG, tagB = warnC.r, warnC.g, warnC.b
            tagBgA = 0.15
        elseif questData._isUpgrade and type(questData._rewardIlvl) == "number" and questData._rewardIlvl > 0 then
            tagText = "ilvl " .. questData._rewardIlvl
            tagR, tagG, tagB = successC.r, successC.g, successC.b
            tagBgA = 0.12
        elseif questData._isCampaignQuest then
            local storyC = QLC.COLORS.story
            tagText = "STORY"
            tagR, tagG, tagB = storyC.r, storyC.g, storyC.b
            tagBgA = 0.12
        elseif questData.frequency then
            if questData.frequency == _G.LE_QUEST_FREQUENCY_DAILY then tagText = "DAILY"
            elseif questData.frequency == _G.LE_QUEST_FREQUENCY_WEEKLY then tagText = "WEEKLY"
            end
            tagBgA = 0.10
        end

        local tagPill = self._muiStatusTag
        if tagText ~= "" then
            tagPill._muiText:SetText(tagText)
            tagPill._muiText:SetTextColor(tagR, tagG, tagB, 0.80)
            tagPill._muiBg:SetVertexColor(tagR, tagG, tagB, tagBgA)
            local pillW = math.max(24, (tagPill._muiText:GetStringWidth() or 16) + 10)
            tagPill:SetWidth(pillW)
            -- Position: right-aligned on the objective summary line
            tagPill:ClearAllPoints()
            tagPill:SetPoint("TOPRIGHT", self, "TOPRIGHT", -14, -22)
            tagPill:Show()

            -- Shrink objective summary to make room for the pill
            self._muiObjSummary:SetPoint("RIGHT", tagPill, "LEFT", -6, 0)
        else
            tagPill:Hide()
            -- Restore full objective summary width
            self._muiObjSummary:ClearAllPoints()
            self._muiObjSummary:SetPoint("TOPLEFT", self, "TOPLEFT", 14, -24)
            self._muiObjSummary:SetPoint("RIGHT", self, "RIGHT", -70, 0)
        end

        -- ── Separator visibility — hide on last row in a group ──
        self._muiSep:Show()

        self:Show()
    end

    return btn
end


-- ── Section 6: Inline Expansion ───────────────────────────────────────
-- Accordion-style details panel showing objectives, rewards, actions
-- ======================================================================

function Panel.CreateExpansion(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(1) -- dynamically calculated

    -- Background
    local bg = frame:CreateTexture(nil, "BACKGROUND", nil, -4)
    bg:SetAllPoints()
    bg:SetTexture(W8)
    local bprR, bprG, bprB = TC("bgPanelRaised")
    bg:SetVertexColor(bprR, bprG, bprB, 0.80)

    -- (No accent bar on expansion — bucket header provides section identity)

    -- Bottom border
    local bottomBorder = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    bottomBorder:SetHeight(1)
    bottomBorder:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 0)
    bottomBorder:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 0)
    bottomBorder:SetTexture(W8)
    local bdR, bdG, bdB = TC("border")
    bottomBorder:SetVertexColor(bdR, bdG, bdB, 0.20)

    -- Pool for child rows
    frame._muiChildFrames = {}

    local function ReleaseChildren(self)
        for i = 1, #self._muiChildFrames do
            local child = self._muiChildFrames[i]
            if child and type(child.Hide) == "function" then
                child:Hide()
                child:ClearAllPoints()
            end
        end
        self._muiChildFrames = {}
    end

    function frame:SetExpansionData(questID, questTitle, accentColor, focusedQuestID)
        ReleaseChildren(self)
        self._muiAccentColorRef = accentColor

        local pad = 14
        local tpR, tpG, tpB = TC("textPrimary")
        local tsR, tsG, tsB = TC("textSecondary")
        local tmR, tmG, tmB = TC("textMuted")
        local bdR2, bdG2, bdB2 = TC("border")
        local successC = QLC.COLORS.success
        local acR, acG, acB = TC("accent")

        -- Select quest for API access
        if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end
        local questLogIndex = Panel.ResolveQuestLogIndex(questID)
        if questLogIndex and type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, questLogIndex)
        end

        -- Collect objectives
        local questData = { questID = questID, objectives = {} }
        if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestObjectives) == "function" then
            local okObj, objs = pcall(C_QuestLog.GetQuestObjectives, questID)
            if okObj and type(objs) == "table" then questData.objectives = objs end
        end
        local objRows = QD.BuildQuestObjectiveDisplayRows(questData)

        -- Collect rewards
        local itemRewards = {}
        local currencyParts = {}
        if type(questID) == "number" then
            local numRewards = 0
            if type(GetNumQuestLogRewards) == "function" then
                local okN, n = pcall(GetNumQuestLogRewards, questID)
                if okN and type(n) == "number" then numRewards = n end
            end
            for i = 1, numRewards do
                if type(GetQuestLogRewardInfo) == "function" then
                    local okR, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogRewardInfo, i, questID)
                    if okR and type(name) == "string" and name ~= "" then
                        itemRewards[#itemRewards + 1] = { name = name, itemID = itemID }
                    end
                end
            end
            local numChoices = 0
            if type(GetNumQuestLogChoices) == "function" then
                local okC, c = pcall(GetNumQuestLogChoices, questID)
                if okC and type(c) == "number" then numChoices = c end
            end
            for i = 1, numChoices do
                if type(GetQuestLogChoiceInfo) == "function" then
                    local okC, name, texture, count, quality, isUsable, itemID = pcall(GetQuestLogChoiceInfo, i, questID)
                    if okC and type(name) == "string" and name ~= "" then
                        itemRewards[#itemRewards + 1] = { name = name, itemID = itemID }
                    end
                end
            end
            if type(GetQuestLogRewardMoney) == "function" then
                local okM, money = pcall(GetQuestLogRewardMoney, questID)
                if okM and type(money) == "number" and money > 0 then
                    local g = math.floor(money / 10000)
                    local s = math.floor((money % 10000) / 100)
                    local parts = {}
                    if g > 0 then parts[#parts + 1] = g .. "g" end
                    if s > 0 then parts[#parts + 1] = s .. "s" end
                    currencyParts[#currencyParts + 1] = table.concat(parts, " ")
                end
            end
            if type(GetQuestLogRewardXP) == "function" then
                local okXP, xp = pcall(GetQuestLogRewardXP, questID)
                if okXP and type(xp) == "number" and xp > 0 then
                    currencyParts[#currencyParts + 1] = xp .. " XP"
                end
            end
        end
        local hasRewards = (#itemRewards > 0 or #currencyParts > 0)

        -- ── Column grid (consistent horizontal positions) ──
        local colIndicator = 10   -- indicator/bullet left edge within card
        local colText = 26        -- text left edge (after indicator gap)
        local colRight = 8        -- right-aligned values inset from card right
        local rowHeight = 24      -- uniform content row height
        local sectionGap = 16     -- vertical gap between sections
        local cardPadV = 6        -- vertical padding inside card

        local totalHeight = sectionGap

        -- Helper: create a section card with pill-badge label
        local function BeginSection(labelText, pillColor)
            local pR, pG, pB = acR, acG, acB
            if pillColor then pR, pG, pB = pillColor.r, pillColor.g, pillColor.b end

            local labelRow = CreateFrame("Frame", nil, self)
            labelRow:SetHeight(20)
            labelRow:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -totalHeight)
            labelRow:SetPoint("TOPRIGHT", self, "TOPRIGHT", -pad, -totalHeight)

            -- Pill background behind label text
            local pillBg = labelRow:CreateTexture(nil, "BACKGROUND", nil, -1)
            pillBg:SetTexture(W8)
            pillBg:SetVertexColor(pR, pG, pB, 0.12)

            local labelFS = labelRow:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
            labelFS:SetPoint("LEFT", labelRow, "LEFT", 0, 0)
            labelFS:SetText(labelText)
            labelFS:SetTextColor(pR, pG, pB, 0.80)

            -- Size pill to fit text
            pillBg:SetPoint("LEFT", labelFS, "LEFT", -6, 0)
            pillBg:SetPoint("RIGHT", labelFS, "RIGHT", 6, 0)
            pillBg:SetPoint("TOP", labelFS, "TOP", 0, 3)
            pillBg:SetPoint("BOTTOM", labelFS, "BOTTOM", 0, -3)

            self._muiChildFrames[#self._muiChildFrames + 1] = labelRow
            totalHeight = totalHeight + 24
            return totalHeight
        end

        local function AddRow()
            local row = CreateFrame("Frame", nil, self)
            row:SetHeight(rowHeight)
            row:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -totalHeight)
            row:SetPoint("TOPRIGHT", self, "TOPRIGHT", -pad, -totalHeight)
            self._muiChildFrames[#self._muiChildFrames + 1] = row
            totalHeight = totalHeight + rowHeight
            return row
        end

        local function AddSeparator()
            local sep = CreateFrame("Frame", nil, self)
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", self, "TOPLEFT", pad + colText, -totalHeight + 1)
            sep:SetPoint("TOPRIGHT", self, "TOPRIGHT", -(pad + colRight), -totalHeight + 1)
            local sepTex = sep:CreateTexture(nil, "ARTWORK")
            sepTex:SetAllPoints()
            sepTex:SetTexture(W8)
            sepTex:SetVertexColor(bdR2, bdG2, bdB2, 0.07)
            self._muiChildFrames[#self._muiChildFrames + 1] = sep
        end

        local function EndSection(cardTop)
            local cardHeight = totalHeight - cardTop + cardPadV
            if cardHeight > 0 then
                local cardBg = self:CreateTexture(nil, "BACKGROUND", nil, -2)
                cardBg:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -cardTop + cardPadV)
                cardBg:SetPoint("TOPRIGHT", self, "TOPRIGHT", -pad, -cardTop + cardPadV)
                cardBg:SetHeight(cardHeight)
                cardBg:SetTexture(W8)
                local bgPR, bgPG, bgPB = TC("bgPanelAlt")
                cardBg:SetVertexColor(bgPR, bgPG, bgPB, 0.25)
            end
            totalHeight = totalHeight + sectionGap
        end

        -- ═══ OBJECTIVES ═══
        if objRows and #objRows > 0 then
            BeginSection("OBJECTIVES")
            local cardTop = totalHeight

            for idx, objData in ipairs(objRows) do
                local row = AddRow()
                local done = objData.finished

                -- Parse numeric progress for the bar
                local filled, required = 0, 0
                if objData.progressText then
                    local f, r = objData.progressText:match("(%d+)/(%d+)")
                    filled = tonumber(f) or 0
                    required = tonumber(r) or 0
                end
                local hasBar = (required > 0)
                local pct = hasBar and (filled / required) or (done and 1 or 0)

                -- Progress bar (behind text, subtle fill)
                local barBg = row:CreateTexture(nil, "BACKGROUND", nil, 1)
                barBg:SetPoint("LEFT", row, "LEFT", colText - 4, 0)
                barBg:SetPoint("RIGHT", row, "RIGHT", -colRight, 0)
                barBg:SetHeight(16)
                barBg:SetTexture(W8)
                barBg:SetVertexColor(tpR, tpG, tpB, 0.04)

                if pct > 0 then
                    local barFill = row:CreateTexture(nil, "BACKGROUND", nil, 2)
                    barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
                    barFill:SetPoint("BOTTOMLEFT", barBg, "BOTTOMLEFT", 0, 0)
                    local barWidth = barBg:GetWidth()
                    -- Can't use GetWidth reliably before layout; use ratio anchor
                    barFill:SetPoint("RIGHT", barBg, "LEFT", 0, 0)
                    -- Use a fill frame so we can set width after layout
                    barFill:SetTexture(W8)
                    if done then
                        barFill:SetVertexColor(successC.r, successC.g, successC.b, 0.10)
                        barFill:SetAllPoints(barBg)
                    else
                        barFill:SetVertexColor(acR, acG, acB, 0.08)
                        barFill:ClearAllPoints()
                        barFill:SetPoint("TOPLEFT", barBg, "TOPLEFT", 0, 0)
                        barFill:SetPoint("BOTTOMLEFT", barBg, "BOTTOMLEFT", 0, 0)
                        -- Approximate fill width using the row width
                        local rowW = (self:GetWidth() or 300) - (pad * 2) - colText + 4 - colRight
                        barFill:SetWidth(math.max(1, math.floor(rowW * pct)))
                    end
                end

                -- Indicator: filled square for done, hollow border for in-progress
                local indicator = row:CreateTexture(nil, "ARTWORK")
                indicator:SetSize(8, 8)
                indicator:SetPoint("LEFT", row, "LEFT", colIndicator, 0)
                indicator:SetTexture(W8)
                if done then
                    indicator:SetVertexColor(successC.r, successC.g, successC.b, 0.85)
                else
                    indicator:SetVertexColor(tpR, tpG, tpB, 0.20)
                end
                -- Inner cutout for hollow effect on incomplete objectives
                if not done then
                    local inner = row:CreateTexture(nil, "ARTWORK", nil, 1)
                    inner:SetPoint("TOPLEFT", indicator, "TOPLEFT", 2, -2)
                    inner:SetPoint("BOTTOMRIGHT", indicator, "BOTTOMRIGHT", -2, 2)
                    inner:SetTexture(W8)
                    local bgPR3, bgPG3, bgPB3 = TC("bgPanelAlt")
                    inner:SetVertexColor(bgPR3, bgPG3, bgPB3, 1)
                end

                -- Objective text
                local objText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                objText:SetPoint("LEFT", row, "LEFT", colText, 0)
                objText:SetPoint("RIGHT", row, "RIGHT", -50, 0)
                objText:SetJustifyH("LEFT")
                objText:SetWordWrap(false)
                objText:SetText(objData.text or "")
                if done then
                    objText:SetTextColor(successC.r, successC.g, successC.b, 0.45)
                else
                    objText:SetTextColor(tpR, tpG, tpB, 0.95)
                end

                -- Right-side fraction / status
                local fracText = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall")
                fracText:SetPoint("RIGHT", row, "RIGHT", -(colRight + 20), 0)
                fracText:SetJustifyH("RIGHT")
                if done then
                    fracText:SetText("Done")
                    fracText:SetTextColor(successC.r, successC.g, successC.b, 0.50)
                elseif hasBar then
                    fracText:SetText(string.format("%d/%d", filled, required))
                    fracText:SetTextColor(acR, acG, acB, 0.75)
                elseif objData.progressText then
                    fracText:SetText(objData.progressText)
                    fracText:SetTextColor(tsR, tsG, tsB, 0.70)
                end

                if idx < #objRows then AddSeparator() end
            end

            EndSection(cardTop)
        end

        -- ═══ REWARDS ═══
        if hasRewards then
            BeginSection("REWARDS")
            local cardTop = totalHeight

            for idx, reward in ipairs(itemRewards) do
                local row = AddRow()

                -- Col 1: accent-colored diamond bullet
                local dot = row:CreateTexture(nil, "ARTWORK")
                dot:SetSize(6, 6)
                dot:SetPoint("LEFT", row, "LEFT", colIndicator + 1, 0)
                dot:SetTexture(W8)
                dot:SetRotation(math.rad(45))
                dot:SetVertexColor(acR, acG, acB, 0.55)

                -- Col 2: item name
                local rewardFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                rewardFS:SetPoint("LEFT", row, "LEFT", colText, 0)
                rewardFS:SetPoint("RIGHT", row, "RIGHT", -colRight, 0)
                rewardFS:SetJustifyH("LEFT")
                rewardFS:SetWordWrap(false)
                rewardFS:SetText(reward.name or "")
                rewardFS:SetTextColor(tpR, tpG, tpB, 0.95)

                if type(reward.itemID) == "number" and reward.itemID > 0 then
                    local itemID = reward.itemID
                    row:EnableMouse(true)
                    row:SetScript("OnEnter", function(self)
                        rewardFS:SetTextColor(acR, acG, acB, 1)
                        dot:SetVertexColor(acR, acG, acB, 1)
                        pcall(function()
                            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                            GameTooltip:SetItemByID(itemID)
                            GameTooltip:Show()
                        end)
                    end)
                    row:SetScript("OnLeave", function()
                        rewardFS:SetTextColor(tpR, tpG, tpB, 0.95)
                        dot:SetVertexColor(acR, acG, acB, 0.55)
                        pcall(function() GameTooltip:Hide() end)
                    end)
                end

                if idx < #itemRewards or #currencyParts > 0 then AddSeparator() end
            end

            -- Currency: styled gold/silver + XP as separate visual elements
            if #currencyParts > 0 then
                local row = AddRow()
                -- Build a rich-formatted currency string
                local richParts = {}
                -- Re-parse money for color-coded display
                if type(GetQuestLogRewardMoney) == "function" then
                    local okM, money = pcall(GetQuestLogRewardMoney, questID)
                    if okM and type(money) == "number" and money > 0 then
                        local g = math.floor(money / 10000)
                        local s = math.floor((money % 10000) / 100)
                        if g > 0 then richParts[#richParts + 1] = string.format("|cffE8CC4A%d|r|cffB8A042g|r", g) end
                        if s > 0 then richParts[#richParts + 1] = string.format("|cffC8C8C8%d|r|cff909090s|r", s) end
                    end
                end
                if type(GetQuestLogRewardXP) == "function" then
                    local okXP, xp = pcall(GetQuestLogRewardXP, questID)
                    if okXP and type(xp) == "number" and xp > 0 then
                        richParts[#richParts + 1] = string.format("|cff8AB4E8%s|r |cff6A94C8XP|r", tostring(xp))
                    end
                end
                local currFS = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                currFS:SetPoint("LEFT", row, "LEFT", colText, 0)
                currFS:SetText(table.concat(richParts, "  |cff555044\194\183|r  "))
            end

            EndSection(cardTop)
        end

        -- ═══ ACTIONS ═══
        -- Evenly distributed across the row as three equal columns
        local actionHeight = 26
        local actionsRow = CreateFrame("Frame", nil, self)
        actionsRow:SetHeight(actionHeight)
        actionsRow:SetPoint("TOPLEFT", self, "TOPLEFT", pad, -totalHeight)
        actionsRow:SetPoint("TOPRIGHT", self, "TOPRIGHT", -pad, -totalHeight)

        -- Subtle background for actions bar
        local actionBg = actionsRow:CreateTexture(nil, "BACKGROUND", nil, -2)
        actionBg:SetAllPoints()
        actionBg:SetTexture(W8)
        local bgPR2, bgPG2, bgPB2 = TC("bgPanelAlt")
        actionBg:SetVertexColor(bgPR2, bgPG2, bgPB2, 0.20)

        local isTracked = false
        if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestWatchType) == "function" then
            local okWatch, watchType = pcall(C_QuestLog.GetQuestWatchType, questID)
            if okWatch and watchType ~= nil then isTracked = true end
        end
        local canShare = Panel.EvaluateShareable(questID)
        local canAbandon = Panel.EvaluateAbandonable(questID)

        -- Three equal-width action buttons
        local function MakeEqualActionBtn(text, colIndex, color, hoverColor, onClick)
            local btn = CreateFrame("Button", nil, actionsRow)
            btn:SetHeight(actionHeight)
            -- Divide row into 3 equal columns
            btn:SetPoint("TOPLEFT", actionsRow, "TOPLEFT", (colIndex - 1) * (1/3) * 1, 0)
            -- Use relative width via two anchor points
            local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("CENTER", btn, "CENTER", 0, 0)
            fs:SetText(text)
            fs:SetTextColor(color.r, color.g, color.b, color.a or 0.70)
            btn._muiFS = fs
            btn._muiDefaultColor = color
            btn:SetScript("OnEnter", function(self)
                self._muiFS:SetTextColor(hoverColor.r, hoverColor.g, hoverColor.b, 1)
            end)
            btn:SetScript("OnLeave", function(self)
                local c = self._muiDefaultColor
                self._muiFS:SetTextColor(c.r, c.g, c.b, c.a or 0.70)
            end)
            if onClick then btn:SetScript("OnClick", onClick) end
            return btn
        end

        -- Position buttons as 3 equal thirds
        local trackColor = isTracked and { r = successC.r, g = successC.g, b = successC.b, a = 0.80 } or { r = tsR, g = tsG, b = tsB, a = 0.65 }
        local trackBtn = MakeEqualActionBtn(isTracked and "Untrack" or "Track", 1, trackColor, { r = acR, g = acG, b = acB }, function()
            Panel.ToggleTracking(questID); Panel.Rebuild()
        end)
        trackBtn:SetPoint("TOPLEFT", actionsRow, "TOPLEFT", 0, 0)
        trackBtn:SetPoint("BOTTOMRIGHT", actionsRow, "BOTTOM", -actionsRow:GetWidth()/6, 0)
        -- Use fractional anchoring instead
        trackBtn:ClearAllPoints()
        trackBtn:SetPoint("TOPLEFT", actionsRow, "TOPLEFT", 0, 0)
        trackBtn:SetPoint("BOTTOM", actionsRow, "BOTTOM", 0, 0)
        trackBtn:SetWidth(math.floor((QLC.PANEL_WIDTH - 2 * pad) / 3))

        local shareColor = canShare and { r = tsR, g = tsG, b = tsB, a = 0.65 } or { r = tmR, g = tmG, b = tmB, a = 0.30 }
        local shareBtn = MakeEqualActionBtn("Share", 2, shareColor, { r = acR, g = acG, b = acB }, function()
            if canShare then Panel.ExecuteShare(questID) end
        end)
        shareBtn:ClearAllPoints()
        shareBtn:SetPoint("TOPLEFT", trackBtn, "TOPRIGHT", 0, 0)
        shareBtn:SetPoint("BOTTOM", actionsRow, "BOTTOM", 0, 0)
        shareBtn:SetWidth(math.floor((QLC.PANEL_WIDTH - 2 * pad) / 3))

        local abandonColor = canAbandon and { r = tsR, g = tsG, b = tsB, a = 0.65 } or { r = tmR, g = tmG, b = tmB, a = 0.30 }
        local abandonBtn = MakeEqualActionBtn("Abandon", 3, abandonColor, { r = 0.9, g = 0.3, b = 0.3 }, function()
            if canAbandon then Panel.ExecuteAbandon(questID, questTitle) end
        end)
        abandonBtn:ClearAllPoints()
        abandonBtn:SetPoint("TOPLEFT", shareBtn, "TOPRIGHT", 0, 0)
        abandonBtn:SetPoint("BOTTOMRIGHT", actionsRow, "BOTTOMRIGHT", 0, 0)

        -- Vertical separators between action buttons
        local actionSep1 = actionsRow:CreateTexture(nil, "ARTWORK")
        actionSep1:SetWidth(1)
        actionSep1:SetPoint("TOPLEFT", trackBtn, "TOPRIGHT", 0, -5)
        actionSep1:SetPoint("BOTTOMLEFT", trackBtn, "BOTTOMRIGHT", 0, 5)
        actionSep1:SetTexture(W8)
        actionSep1:SetVertexColor(bdR2, bdG2, bdB2, 0.10)

        local actionSep2 = actionsRow:CreateTexture(nil, "ARTWORK")
        actionSep2:SetWidth(1)
        actionSep2:SetPoint("TOPLEFT", shareBtn, "TOPRIGHT", 0, -5)
        actionSep2:SetPoint("BOTTOMLEFT", shareBtn, "BOTTOMRIGHT", 0, 5)
        actionSep2:SetTexture(W8)
        actionSep2:SetVertexColor(bdR2, bdG2, bdB2, 0.10)

        self._muiChildFrames[#self._muiChildFrames + 1] = actionsRow
        totalHeight = totalHeight + actionHeight + 6

        self:SetHeight(totalHeight)
        self:Show()
    end

    return frame
end


-- ── Section 7: Focus Header ──────────────────────────────────────────
-- Focused quest indicator at top of list
-- ======================================================================

function Panel.CreateFocusHeader(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(QLC.FOCUS_HEADER_HEIGHT)

    local focusC = QLC.FOCUS_COLOR

    -- "FOCUS" label (no accent bar — clean text only)
    local label = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    label:SetPoint("LEFT", frame, "LEFT", 14, 0)
    label:SetText(QLC.FOCUS_LABEL)
    label:SetTextColor(focusC.r, focusC.g, focusC.b, 1)
    frame._muiLabel = label

    -- Quest title
    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    title:SetPoint("LEFT", label, "RIGHT", 12, 0)
    title:SetPoint("RIGHT", frame, "RIGHT", -14, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    local tsR, tsG, tsB = TC("textSecondary")
    title:SetTextColor(tsR, tsG, tsB, 1)
    frame._muiTitle = title

    -- Bottom gold line
    local bottomLine = frame:CreateTexture(nil, "ARTWORK", nil, 1)
    bottomLine:SetHeight(1)
    bottomLine:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    bottomLine:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    bottomLine:SetTexture(W8)
    bottomLine:SetVertexColor(focusC.r, focusC.g, focusC.b, 0.15)

    function frame:SetFocusData(questData)
        if type(questData) ~= "table" then
            self:Hide()
            return
        end
        self._muiTitle:SetText(questData.title or "")
        self:Show()
    end

    return frame
end


-- ── Section 8: Empty State ────────────────────────────────────────────
-- "No active quests" display
-- ======================================================================

function Panel.CreateEmptyState(parent)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(QLC.EMPTY_STATE_HEIGHT)

    local tpR, tpG, tpB = TC("textPrimary")
    local tmR, tmG, tmB = TC("textMuted")

    -- Main text
    local mainText = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    mainText:SetPoint("CENTER", frame, "CENTER", 0, 10)
    mainText:SetTextColor(tpR, tpG, tpB, 1)
    frame._muiMainText = mainText

    -- Sub text
    local subText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    subText:SetPoint("TOP", mainText, "BOTTOM", 0, -6)
    subText:SetTextColor(tmR, tmG, tmB, 1)
    frame._muiSubText = subText

    -- Clear search button (hidden by default)
    local clearBtn = CreateFrame("Button", nil, frame)
    clearBtn:SetHeight(20)
    clearBtn:SetPoint("TOP", subText, "BOTTOM", 0, -4)
    local clearText = clearBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    clearText:SetPoint("CENTER", clearBtn, "CENTER", 0, 0)
    local acR, acG, acB = TC("accent")
    clearText:SetText("Clear")
    clearText:SetTextColor(acR, acG, acB, 1)
    clearBtn:SetWidth(clearText:GetStringWidth() + 8)
    clearBtn:SetScript("OnClick", function()
        local panel = Panel._state.panel
        if panel and panel._muiSearchBox then
            panel._muiSearchBox:SetText("")
            panel._muiSearchBox._muiPlaceholder:Show()
            Panel.Rebuild()
        end
    end)
    clearBtn:SetScript("OnEnter", function()
        clearText:SetTextColor(1, 1, 1, 1)
    end)
    clearBtn:SetScript("OnLeave", function()
        clearText:SetTextColor(acR, acG, acB, 1)
    end)
    clearBtn:Hide()
    frame._muiClearBtn = clearBtn

    function frame:SetEmptyData(searchText)
        if type(searchText) == "string" and searchText ~= "" then
            self._muiMainText:SetText("No quests match '" .. searchText .. "'")
            self._muiSubText:SetText("")
            self._muiClearBtn:Show()
        else
            self._muiMainText:SetText("No active quests")
            self._muiSubText:SetText("Pick up quests from NPCs")
            self._muiClearBtn:Hide()
        end
        self:Show()
    end

    return frame
end


-- ── Section 9: Layout Engine ──────────────────────────────────────────
-- RebuildQuestListLayout - the master layout function
-- ======================================================================

-- Hide Blizzard's default QuestMapFrame so it doesn't show alongside our panel
local function SuppressBlizzardQuestFrame()
    local qmf = _G.QuestMapFrame
    if qmf and type(qmf.Hide) == "function" then
        pcall(function() qmf:Hide() end)
    end
    -- Also hide the search box Blizzard puts on the map
    local searchBox = qmf and qmf.SearchBox
    if searchBox and type(searchBox.Hide) == "function" then
        pcall(function() searchBox:Hide() end)
    end
    -- Hook it to stay hidden when Blizzard tries to re-show it
    if qmf and not qmf._muiHideHook then
        qmf._muiHideHook = true
        pcall(function()
            qmf:HookScript("OnShow", function(self)
                if Addon.QuestLogPanel and Addon.QuestLogPanel.IsOpen and Addon.QuestLogPanel.IsOpen() then
                    self:Hide()
                end
            end)
        end)
    end
end

function Panel.Rebuild()
    local panel = Panel._state.panel
    if not panel then return end
    if not Panel._state.panelOpen then return end
    SuppressBlizzardQuestFrame()

    -- Get search text
    local searchText = ""
    if panel._muiSearchBox then
        local okText, text = pcall(function() return panel._muiSearchBox:GetText() end)
        if okText and type(text) == "string" then
            searchText = text
        end
    end

    -- Collect data
    local listData = QD.CollectQuestListData(searchText ~= "" and searchText or nil)

    -- Update header count
    if panel._muiCount then
        panel._muiCount:SetText(string.format("(%d/%d)", listData.totalQuestCount, listData.maxQuests))
    end

    -- ── Layout fixed top area: campaign → search → scroll ──
    local campaignHost = panel._muiCampaignHost
    local searchBox = panel._muiSearchBox
    local scrollFrame = panel._muiScrollFrame
    local titleBarHeight = 36
    local campaignHeight = 0

    -- Campaign card (fixed, not scrollable)
    local campaign = listData.campaign
    if not campaign and listData.headers and #listData.headers > 0 then
        campaign = QD.ResolveCampaignCardFallback(listData.headers)
    end
    if campaign and campaign.name and campaignHost then
        campaignHeight = 62
        campaignHost:SetHeight(campaignHeight)
        campaignHost:Show()
        if panel._muiCampTitle then panel._muiCampTitle:SetText(campaign.name or "Campaign") end
        local prog = campaign.progress or 0
        local tot = campaign.total or 1
        if tot < 1 then tot = 1 end
        if panel._muiCampProgress then panel._muiCampProgress:SetText(string.format("%d/%d", prog, tot)) end
        if panel._muiCampChapter then panel._muiCampChapter:SetText(campaign.chapterName or "") end
        -- Progress fill
        if panel._muiCampFill then
            local frac = Clamp(prog / tot, 0, 1)
            local trackW = campaignHost:GetWidth()
            if trackW < 1 then trackW = QLC.PANEL_WIDTH end
            local fillW = math.max(1, math.floor((trackW - 28) * frac))
            panel._muiCampFill:SetWidth(fillW)
        end
    elseif campaignHost then
        campaignHost:Hide()
        campaignHeight = 0
    end

    -- Layout order: title(36) → campaign(62 or 0) → search(26) + padding → scroll
    -- Reposition search below campaign (or title if no campaign)
    if searchBox then
        searchBox:ClearAllPoints()
        if campaignHeight > 0 then
            searchBox:SetPoint("TOPLEFT", campaignHost, "BOTTOMLEFT", 0, -4)
            searchBox:SetPoint("TOPRIGHT", campaignHost, "BOTTOMRIGHT", 0, -4)
        else
            searchBox:SetPoint("TOPLEFT", panel._muiHeader, "BOTTOMLEFT", 0, -4)
            searchBox:SetPoint("TOPRIGHT", panel._muiHeader, "BOTTOMRIGHT", -2, -4)
        end
    end

    local searchHeight = 26
    local fixedTopHeight = titleBarHeight + campaignHeight + 4 + searchHeight + 6
    if scrollFrame then
        scrollFrame:ClearAllPoints()
        scrollFrame:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -fixedTopHeight)
        scrollFrame:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -6, 0)
    end

    -- Release all pools
    QD.QuestListReleaseAllInPool("bucketHeaders")
    QD.QuestListReleaseAllInPool("zoneSubHeaders")
    QD.QuestListReleaseAllInPool("quests")
    QD.QuestListReleaseAllInPool("expansions")
    QD.QuestListReleaseAllInPool("focusHeaders")
    QD.QuestListReleaseAllInPool("empty")

    local scrollChild = panel._muiScrollChild
    if not scrollChild then return end

    local totalHeight = 0
    local gap = QLC.QUEST_ROW_GAP
    local panelContentWidth = QLC.PANEL_WIDTH - 16
    local hasAnyContent = false

    -- Helper to anchor a frame in the scroll list
    local function PlaceFrame(frame, height, extraGap)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, -totalHeight)
        frame:SetPoint("TOPRIGHT", scrollChild, "TOPRIGHT", 0, -totalHeight)
        if height then
            frame:SetHeight(height)
        end
        frame:Show()
        local h = height or frame:GetHeight()
        totalHeight = totalHeight + h + (extraGap or gap)
        hasAnyContent = true
    end

    -- Helper to add breathing space between sections
    local function AddSectionGap()
        totalHeight = totalHeight + 8
    end

    -- 1. (Campaign card is now in fixed header area, not in scroll)

    -- 2. Focused quest
    local focusedQuestID = Panel._state.focusedQuestID
    local focusedQuest, focusBucketKey = nil, nil
    if focusedQuestID then
        focusedQuest, focusBucketKey = QD.ExtractFocusedQuestFromBuckets(listData, focusedQuestID)
        -- Also search conditional sections (TURN IN / EXPIRING)
        if not focusedQuest then
            for _, condKey in ipairs({"turnIn", "expiring"}) do
                local condQuests = listData[condKey]
                if type(condQuests) == "table" then
                    for i = 1, #condQuests do
                        if condQuests[i].questID == focusedQuestID then
                            focusedQuest = table.remove(condQuests, i)
                            focusBucketKey = condKey
                            break
                        end
                    end
                end
                if focusedQuest then break end
            end
        end
    end

    if focusedQuest then
        -- Focus header
        local focusHeader = QD.QuestListAcquireFromPool("focusHeaders", function(p) return Panel.CreateFocusHeader(p) end, scrollChild)
        if focusHeader then
            focusHeader:SetFocusData(focusedQuest)
            PlaceFrame(focusHeader, QLC.FOCUS_HEADER_HEIGHT)
        end

        -- Focused quest row (auto-expanded)
        local focusRow = QD.QuestListAcquireFromPool("quests", function(p) return Panel.CreateQuestRow(p) end, scrollChild)
        if focusRow then
            focusRow:SetQuestData(focusedQuest, focusBucketKey or "now")
            PlaceFrame(focusRow, QLC.QUEST_ROW_HEIGHT)
        end

        -- Auto-expand focused quest
        QD._expandedQuests[focusedQuestID] = true
        local focusExpansion = QD.QuestListAcquireFromPool("expansions", function(p) return Panel.CreateExpansion(p) end, scrollChild)
        if focusExpansion then
            local focusAccentColor = { r = 1, g = 0.84, b = 0.30, a = 1 }
            focusExpansion:SetExpansionData(focusedQuestID, focusedQuest.title, focusAccentColor, focusedQuestID)
            PlaceFrame(focusExpansion)
        end
        AddSectionGap()
    end

    -- 3. Conditional Smart Sections (TURN IN / EXPIRING)
    local hasConditionalContent = false

    local turnInQuests = listData.turnIn
    if type(turnInQuests) == "table" and #turnInQuests > 0 then
        local isCollapsed = QD._bucketCollapseState["turnIn"] or false

        local bucketHeader = QD.QuestListAcquireFromPool("bucketHeaders", function(p) return Panel.CreateBucketHeader(p) end, scrollChild)
        if bucketHeader then
            bucketHeader:SetBucketData("turnIn", #turnInQuests, isCollapsed)
            PlaceFrame(bucketHeader, QLC.BUCKET_HEADER_HEIGHT)
        end

        if not isCollapsed then
            for _, quest in ipairs(turnInQuests) do
                local questRow = QD.QuestListAcquireFromPool("quests", function(p) return Panel.CreateQuestRow(p) end, scrollChild)
                if questRow then
                    questRow:SetQuestData(quest, "turnIn")
                    PlaceFrame(questRow, QLC.QUEST_ROW_HEIGHT)
                end
                if QD._expandedQuests[quest.questID] then
                    local expansion = QD.QuestListAcquireFromPool("expansions", function(p) return Panel.CreateExpansion(p) end, scrollChild)
                    if expansion then
                        local accentColor = questRow and questRow._muiAccentColor or { r = 0.34, g = 0.82, b = 0.46 }
                        expansion:SetExpansionData(quest.questID, quest.title, accentColor, focusedQuestID)
                        PlaceFrame(expansion)
                    end
                end
            end
        end
        hasConditionalContent = true
        AddSectionGap()
    end

    local expiringQuests = listData.expiring
    if type(expiringQuests) == "table" and #expiringQuests > 0 then
        local isCollapsed = QD._bucketCollapseState["expiring"] or false

        local bucketHeader = QD.QuestListAcquireFromPool("bucketHeaders", function(p) return Panel.CreateBucketHeader(p) end, scrollChild)
        if bucketHeader then
            bucketHeader:SetBucketData("expiring", #expiringQuests, isCollapsed)
            PlaceFrame(bucketHeader, QLC.BUCKET_HEADER_HEIGHT)
        end

        if not isCollapsed then
            for _, quest in ipairs(expiringQuests) do
                local questRow = QD.QuestListAcquireFromPool("quests", function(p) return Panel.CreateQuestRow(p) end, scrollChild)
                if questRow then
                    questRow:SetQuestData(quest, "expiring")
                    PlaceFrame(questRow, QLC.QUEST_ROW_HEIGHT)
                end
                if QD._expandedQuests[quest.questID] then
                    local expansion = QD.QuestListAcquireFromPool("expansions", function(p) return Panel.CreateExpansion(p) end, scrollChild)
                    if expansion then
                        local accentColor = questRow and questRow._muiAccentColor or { r = 1.00, g = 0.52, b = 0.20 }
                        expansion:SetExpansionData(quest.questID, quest.title, accentColor, focusedQuestID)
                        PlaceFrame(expansion)
                    end
                end
            end
        end
        hasConditionalContent = true
        AddSectionGap()
    end

    -- Extra breathing room between conditional and spatial sections
    if hasConditionalContent then
        totalHeight = totalHeight + 4
    end

    -- 4. Spatial Buckets (NOW / NEXT / LATER)
    for _, bucketKey in ipairs(QLC.BUCKET_ORDER) do
        local quests = listData.buckets[bucketKey]
        if type(quests) == "table" and #quests > 0 then
            local isCollapsed = QD._bucketCollapseState[bucketKey] or false

            -- Bucket header
            local bucketHeader = QD.QuestListAcquireFromPool("bucketHeaders", function(p) return Panel.CreateBucketHeader(p) end, scrollChild)
            if bucketHeader then
                bucketHeader:SetBucketData(bucketKey, #quests, isCollapsed)
                PlaceFrame(bucketHeader, QLC.BUCKET_HEADER_HEIGHT)
            end

            if not isCollapsed then
                -- Group quests by zone (headerTitle)
                local zoneMap = {}
                local zoneOrder = {}
                for _, quest in ipairs(quests) do
                    local zone = quest.headerTitle or "Unknown"
                    if not zoneMap[zone] then
                        zoneMap[zone] = {}
                        zoneOrder[#zoneOrder + 1] = zone
                    end
                    zoneMap[zone][#zoneMap[zone] + 1] = quest
                end

                -- Sort zones: current zone first, then alphabetical
                local currentZone = listData.zoneName or ""
                table.sort(zoneOrder, function(a, b)
                    local aIsCurrent = (a == currentZone)
                    local bIsCurrent = (b == currentZone)
                    if aIsCurrent and not bIsCurrent then return true end
                    if not aIsCurrent and bIsCurrent then return false end
                    return a < b
                end)

                local showZoneHeaders = (#zoneOrder >= 2)

                for _, zoneName in ipairs(zoneOrder) do
                    local zoneQuests = zoneMap[zoneName]
                    local isCurrentZone = (zoneName == currentZone)
                    local zoneCollapsed = QD._collapseState[zoneName] or false

                    if showZoneHeaders then
                        local zoneHeader = QD.QuestListAcquireFromPool("zoneSubHeaders", function(p) return Panel.CreateZoneHeader(p) end, scrollChild)
                        if zoneHeader then
                            zoneHeader:SetZoneHeaderData(zoneName, #zoneQuests, isCurrentZone, zoneCollapsed)
                            PlaceFrame(zoneHeader, QLC.ZONE_HEADER_HEIGHT)
                        end
                    end

                    if not zoneCollapsed or not showZoneHeaders then
                        for _, quest in ipairs(zoneQuests) do
                            -- Quest row
                            local questRow = QD.QuestListAcquireFromPool("quests", function(p) return Panel.CreateQuestRow(p) end, scrollChild)
                            if questRow then
                                questRow:SetQuestData(quest, bucketKey)
                                PlaceFrame(questRow, QLC.QUEST_ROW_HEIGHT)
                            end

                            -- Expansion (if expanded)
                            if QD._expandedQuests[quest.questID] then
                                local expansion = QD.QuestListAcquireFromPool("expansions", function(p) return Panel.CreateExpansion(p) end, scrollChild)
                                if expansion then
                                    local accentColor = questRow and questRow._muiAccentColor or { r = 1, g = 1, b = 1 }
                                    expansion:SetExpansionData(quest.questID, quest.title, accentColor, focusedQuestID)
                                    PlaceFrame(expansion)
                                end
                            end
                        end
                    end
                end
            end
            -- Extra breathing room after each bucket section
            AddSectionGap()
        end
    end

    -- 4. Empty state
    if not hasAnyContent then
        local emptyState = QD.QuestListAcquireFromPool("empty", function(p) return Panel.CreateEmptyState(p) end, scrollChild)
        if emptyState then
            emptyState:SetEmptyData(searchText)
            PlaceFrame(emptyState, QLC.EMPTY_STATE_HEIGHT)
        end
    end

    -- 5. Set scrollChild height
    scrollChild:SetHeight(math.max(1, totalHeight))
end


-- ── Section 10: Context Menu ──────────────────────────────────────────
-- Right-click menu: Focus, Share, Abandon
-- ======================================================================

function Panel.OpenContextMenu(anchorFrame, questID, questTitle)
    if not questID then return end

    local isFocused = (Panel._state.focusedQuestID == questID)
    local canShare = Panel.EvaluateShareable(questID)
    local canAbandon = Panel.EvaluateAbandonable(questID)

    -- Try modern MenuUtil (10.x+)
    if type(MenuUtil) == "table" and type(MenuUtil.CreateContextMenu) == "function" then
        local okMenu = pcall(function()
            MenuUtil.CreateContextMenu(anchorFrame, function(ownerRegion, rootDescription)
                if isFocused then
                    rootDescription:CreateButton("Clear Focus", function()
                        Panel.ClearFocusedQuest()
                        Panel.Rebuild()
                    end)
                else
                    rootDescription:CreateButton("Focus", function()
                        Panel.SetFocusedQuest(questID)
                        Panel.Rebuild()
                    end)
                end

                if canShare then
                    rootDescription:CreateButton("Share", function()
                        Panel.ExecuteShare(questID)
                    end)
                end

                if canAbandon then
                    rootDescription:CreateButton("Abandon", function()
                        Panel.ExecuteAbandon(questID, questTitle)
                    end)
                end
            end)
        end)
        if okMenu then return end
    end

    -- Fallback: EasyMenu
    if type(EasyMenu) == "function" then
        local menuList = {}

        if isFocused then
            menuList[#menuList + 1] = {
                text = "Clear Focus",
                func = function()
                    Panel.ClearFocusedQuest()
                    Panel.Rebuild()
                end,
                notCheckable = true,
            }
        else
            menuList[#menuList + 1] = {
                text = "Focus",
                func = function()
                    Panel.SetFocusedQuest(questID)
                    Panel.Rebuild()
                end,
                notCheckable = true,
            }
        end

        if canShare then
            menuList[#menuList + 1] = {
                text = "Share",
                func = function()
                    Panel.ExecuteShare(questID)
                end,
                notCheckable = true,
            }
        end

        if canAbandon then
            menuList[#menuList + 1] = {
                text = "Abandon",
                func = function()
                    Panel.ExecuteAbandon(questID, questTitle)
                end,
                notCheckable = true,
            }
        end

        local menuFrame = _G["MidnightUIQuestContextMenu"]
        if not menuFrame then
            menuFrame = CreateFrame("Frame", "MidnightUIQuestContextMenu", UIParent, "UIDropDownMenuTemplate")
        end
        pcall(EasyMenu, menuList, menuFrame, "cursor", 0, 0, "MENU")
    end
end


-- ── Section 11: Quest Actions ─────────────────────────────────────────
-- Track, Share, Abandon API wrappers
-- ======================================================================

function Panel.SetFocusedQuest(questID)
    if type(questID) ~= "number" then return end
    Panel._state.focusedQuestID = questID
    -- Also supertrack
    if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
    end
end

function Panel.ClearFocusedQuest()
    Panel._state.focusedQuestID = nil
    if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
        pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
    end
end

function Panel.ResolveQuestLogIndex(questID)
    if type(questID) ~= "number" then return nil end
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetLogIndexForQuestID) == "function" then
        local ok, index = pcall(C_QuestLog.GetLogIndexForQuestID, questID)
        if ok and type(index) == "number" and index > 0 then
            return index
        end
    end
    return nil
end

function Panel.EvaluateShareable(questID)
    if type(questID) ~= "number" then return false end

    -- Must be in a group
    local inGroup = false
    if type(IsInGroup) == "function" then
        local ok, result = pcall(IsInGroup)
        if ok and result then inGroup = true end
    end
    if not inGroup then return false end

    -- Check if quest is pushable/shareable
    if type(C_QuestLog) == "table" and type(C_QuestLog.IsPushableQuest) == "function" then
        local ok, pushable = pcall(C_QuestLog.IsPushableQuest, questID)
        if ok and pushable then return true end
    end

    -- Fallback: check via GetQuestLogPushable
    local logIndex = Panel.ResolveQuestLogIndex(questID)
    if logIndex then
        if type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, logIndex)
        end
        if type(GetQuestLogPushable) == "function" then
            local ok, pushable = pcall(GetQuestLogPushable)
            if ok and pushable then return true end
        end
    end

    return false
end

function Panel.EvaluateAbandonable(questID)
    if type(questID) ~= "number" then return false end
    if type(C_QuestLog) == "table" and type(C_QuestLog.CanAbandonQuest) == "function" then
        local ok, canAbandon = pcall(C_QuestLog.CanAbandonQuest, questID)
        if ok then return canAbandon end
    end
    -- Fallback: assume yes if quest exists in log
    local logIndex = Panel.ResolveQuestLogIndex(questID)
    return (logIndex ~= nil)
end

function Panel.ExecuteShare(questID)
    if type(questID) ~= "number" then return end
    -- Modern API
    if type(C_QuestLog) == "table" and type(C_QuestLog.SetSelectedQuest) == "function" then
        pcall(C_QuestLog.SetSelectedQuest, questID)
    end
    -- Try QuestMapQuestOptions_ShareQuest first (retail)
    if type(QuestMapQuestOptions_ShareQuest) == "function" then
        pcall(QuestMapQuestOptions_ShareQuest, questID)
        return
    end
    -- Fallback C_QuestLog.ShareQuest
    if type(C_QuestLog) == "table" and type(C_QuestLog.ShareQuest) == "function" then
        pcall(C_QuestLog.ShareQuest, questID)
        return
    end
    -- Legacy fallback
    local logIndex = Panel.ResolveQuestLogIndex(questID)
    if logIndex then
        if type(SelectQuestLogEntry) == "function" then
            pcall(SelectQuestLogEntry, logIndex)
        end
        if type(QuestLogPushQuest) == "function" then
            pcall(QuestLogPushQuest)
        end
    end
end

function Panel.ExecuteAbandon(questID, questTitle)
    if type(questID) ~= "number" then return end
    -- Set up the abandon via C_QuestLog
    if type(C_QuestLog) == "table" then
        if type(C_QuestLog.SetSelectedQuest) == "function" then
            pcall(C_QuestLog.SetSelectedQuest, questID)
        end
        if type(C_QuestLog.SetAbandonQuest) == "function" then
            pcall(C_QuestLog.SetAbandonQuest)
        end
    else
        -- Legacy
        local logIndex = Panel.ResolveQuestLogIndex(questID)
        if logIndex then
            if type(SelectQuestLogEntry) == "function" then
                pcall(SelectQuestLogEntry, logIndex)
            end
            if type(SetAbandonQuest) == "function" then
                pcall(SetAbandonQuest)
            end
        end
    end
    -- Show confirmation popup — must pass quest title as data for SetFormattedText
    if type(StaticPopup_Show) == "function" then
        local displayTitle = questTitle or ""
        pcall(StaticPopup_Show, "ABANDON_QUEST", displayTitle)
    end
end

function Panel.ToggleTracking(questID)
    if type(questID) ~= "number" then return end

    local isTracked = false
    if type(C_QuestLog) == "table" and type(C_QuestLog.GetQuestWatchType) == "function" then
        local ok, watchType = pcall(C_QuestLog.GetQuestWatchType, questID)
        if ok and watchType ~= nil then
            isTracked = true
        end
    end

    if isTracked then
        -- Remove tracking
        if type(C_QuestLog) == "table" and type(C_QuestLog.RemoveQuestWatch) == "function" then
            pcall(C_QuestLog.RemoveQuestWatch, questID)
        end
        -- Clear supertrack if this was the supertracked quest
        if type(C_SuperTrack) == "table" and type(C_SuperTrack.GetSuperTrackedQuestID) == "function" then
            local okST, stID = pcall(C_SuperTrack.GetSuperTrackedQuestID)
            if okST and stID == questID then
                if type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
                    pcall(C_SuperTrack.SetSuperTrackedQuestID, 0)
                end
            end
        end
    else
        -- Add tracking
        if type(C_QuestLog) == "table" and type(C_QuestLog.AddQuestWatch) == "function" then
            local watchType = _G.Enum and _G.Enum.QuestWatchType and _G.Enum.QuestWatchType.Manual
            if watchType then
                pcall(C_QuestLog.AddQuestWatch, questID, watchType)
            else
                pcall(C_QuestLog.AddQuestWatch, questID)
            end
        end
        -- Supertrack
        if type(C_SuperTrack) == "table" and type(C_SuperTrack.SetSuperTrackedQuestID) == "function" then
            pcall(C_SuperTrack.SetSuperTrackedQuestID, questID)
        end
    end
end


-- ── Section 12: Slide Animations ──────────────────────────────────────
-- Panel slide in/out (animation groups created in EnsurePanel)
-- ======================================================================

local function PlaySlideIn(panel)
    if not panel then return end
    -- Stop any running animations
    if panel._muiSlideOut then
        local okStop = pcall(function()
            if panel._muiSlideOut:IsPlaying() then
                panel._muiSlideOut:Stop()
            end
        end)
    end
    panel:SetAlpha(0)
    panel:Show()
    if panel._muiSlideIn then
        pcall(function() panel._muiSlideIn:Play() end)
    else
        panel:SetAlpha(1)
    end
end

local function PlaySlideOut(panel)
    if not panel then return end
    -- Stop any running animations
    if panel._muiSlideIn then
        local okStop = pcall(function()
            if panel._muiSlideIn:IsPlaying() then
                panel._muiSlideIn:Stop()
            end
        end)
    end
    if panel._muiSlideOut then
        pcall(function() panel._muiSlideOut:Play() end)
    else
        panel:Hide()
        Panel._state.panelOpen = false
    end
end


-- ── Section 13: Public API ────────────────────────────────────────────
-- Panel.Show(), Panel.Hide(), Panel.Toggle(), Panel.IsOpen(), Panel.Rebuild()
-- ======================================================================

function Panel.Show(map)
    local panel = Panel.EnsurePanel(map or _G.WorldMapFrame)
    if not panel then return end
    Panel._state.panelOpen = true
    SuppressBlizzardQuestFrame()
    PlaySlideIn(panel)
    Panel.Rebuild()
end

function Panel.Hide()
    local panel = Panel._state.panel
    if not panel then
        Panel._state.panelOpen = false
        return
    end
    PlaySlideOut(panel)
end

function Panel.Toggle(map)
    if Panel._state.panelOpen then
        Panel.Hide()
    else
        Panel.Show(map)
    end
end

function Panel.IsOpen()
    return Panel._state.panelOpen == true
end


-- ── Section 14: Event Handler ─────────────────────────────────────────
-- QUEST_LOG_UPDATE, ZONE_CHANGED, etc.
-- ======================================================================

local EventFrame = CreateFrame("Frame")
EventFrame:RegisterEvent("QUEST_LOG_UPDATE")
EventFrame:RegisterEvent("QUEST_ACCEPTED")
EventFrame:RegisterEvent("QUEST_REMOVED")
EventFrame:RegisterEvent("QUEST_WATCH_UPDATE")
EventFrame:RegisterEvent("ZONE_CHANGED")
EventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
EventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
EventFrame:SetScript("OnEvent", function(_, event)
    if not Panel._state.panelOpen then
        if event == "PLAYER_REGEN_ENABLED" and Panel._state.pendingLayout then
            Panel._state.pendingLayout = false
            Panel.Rebuild()
        end
        return
    end
    if type(InCombatLockdown) == "function" then
        local okCombat, inCombat = pcall(InCombatLockdown)
        if okCombat and inCombat then
            Panel._state.pendingLayout = true
            return
        end
    end
    Panel.Rebuild()
end)

Addon.QuestLogPanel = Panel
