-- =============================================================================
-- FILE PURPOSE:     Custom guild panel replacing Blizzard's GuildFrame/Communities UI.
--                   Layout: top hero banner (guild name, MOTD, online count), left
--                   column member roster (sortable, class-colored, role icons), right
--                   column guild chat with input box and send button. Supports
--                   parchment/midnight/twilight themes matching the character panel.
-- LOAD ORDER:       Loads after CharacterPanel.lua, before GuildRecruit.lua.
--                   Standalone file — no Addon vararg namespace, no early-exit guard.
-- DEFINES:          "MidnightGuildPanel" frame (hidden/shown via hook on GuildFrame:Show).
--                   THEMES{} — shared theme palette keys (parchment/midnight/twilight).
--                   GetClassColor() — local class color resolver via RAID_CLASS_COLORS.
--                   SafeCall() — pcall wrapper for all guild API calls.
-- READS:            IsInGuild, GetGuildInfo, GetNumGuildMembers, GetGuildRosterInfo,
--                   GetGuildRosterMOTD — roster and guild metadata.
--                   MidnightUISettings.General.characterPanelTheme — shared theme key.
--                   CHAT_MSG_GUILD events — appends to chat history display.
-- WRITES:           Nothing persistent — guild data is API-side (Blizzard-owned).
--                   chat history list in the right panel (file-local, cleared on reload).
-- DEPENDS ON:       GuildRoster() — call to request a fresh roster from server.
--                   RAID_CLASS_COLORS — for class-colored member names.
-- USED BY:          GuildRecruit.lua — may hook the panel to add a Recruitment tab button.
-- KEY FLOWS:
--   GuildFrame:Show hook → open custom panel → GuildRoster() → wait for GUILD_ROSTER_UPDATE
--   GUILD_ROSTER_UPDATE → RefreshRoster() — rebuild member list rows, update hero stats
--   CHAT_MSG_GUILD → AppendGuildChat(sender, msg) — add row to right-side chat display
--   InviteUnit button → SendChatMessage / InviteUnit(selected member name)
--   Member row click → select member, show detail tooltip (class/level/rank/note)
-- GOTCHAS:
--   GuildRoster() is an asynchronous request; roster data arrives via GUILD_ROSTER_UPDATE.
--   Do not read GetNumGuildMembers / GetGuildRosterInfo immediately after Show — wait
--   for the event. SafeCall wraps every roster API call to avoid taint issues.
--   Chat history is stored in a file-local table and lost on /reload — this is intentional
--   (guild chat is ephemeral; MessengerDB.History["Guild"] is not used here).
--   Theme key is shared with CharacterPanel via MidnightUISettings.General.characterPanelTheme.
-- NAVIGATION:
--   THEMES{}             — color palettes (line ~59)
--   GetClassColor()      — class color resolver (line ~49)
--   RefreshRoster()      — member list builder (search "function RefreshRoster")
--   AppendGuildChat()    — chat row appender (search "function AppendGuildChat")
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local W8 = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local BODY_FONT  = "Fonts\\FRIZQT__.TTF"

-- ============================================================================
-- §1  UPVALUES
-- ============================================================================
local pcall, type, pairs, ipairs, math, string, table, select, tostring =
      pcall, type, pairs, ipairs, math, string, table, select, tostring
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local IsInGuild, GetGuildInfo, GetNumGuildMembers = IsInGuild, GetGuildInfo, GetNumGuildMembers
local GetGuildRosterInfo, GetGuildRosterMOTD, GuildRoster = GetGuildRosterInfo, GetGuildRosterMOTD, GuildRoster
local SendChatMessage, InviteUnit = SendChatMessage, InviteUnit
local RAID_CLASS_COLORS = RAID_CLASS_COLORS
local hooksecurefunc = hooksecurefunc

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4, r5, r6, r7, r8 = pcall(fn, ...)
    if not ok then return nil end
    return r1, r2, r3, r4, r5, r6, r7, r8
end

local function TrySetFont(fs, fontPath, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, fontPath or TITLE_FONT, size or 12, flags or "")
end

local function FormatNumber(n)
    if not n or type(n) ~= "number" then return "0" end
    n = math.floor(n + 0.5)
    local s = tostring(n)
    while true do
        local k
        s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return s
end

local function GetClassColor(classFile)
    if not classFile or not RAID_CLASS_COLORS then return 0.8, 0.8, 0.8 end
    local cc = RAID_CLASS_COLORS[classFile]
    if cc then return cc.r, cc.g, cc.b end
    return 0.8, 0.8, 0.8
end

-- ============================================================================
-- §2  THEME (reads from MidnightUISettings.General.characterPanelTheme)
-- ============================================================================
local THEMES = {
    parchment = {
        frameBg     = { 0.07, 0.06, 0.04, 0.97 },
        headerBg    = { 0.09, 0.07, 0.04, 0.95 },
        heroBg      = { 0.10, 0.08, 0.05, 0.92 },
        panelBg     = { 0.08, 0.07, 0.05, 0.95 },
        chatBg      = { 0.06, 0.05, 0.03, 0.95 },
        accent      = { 0.72, 0.62, 0.42 },
        titleText   = { 0.96, 0.87, 0.58 },
        bodyText    = { 0.94, 0.90, 0.80 },
        mutedText   = { 0.71, 0.62, 0.44 },
        divider     = { 0.60, 0.52, 0.35 },
        inputBg     = { 0.06, 0.05, 0.03, 0.9 },
        hoverBg     = { 0.18, 0.15, 0.10, 0.4 },
        borderTint  = { 0.72, 0.62, 0.42, 0.6 },
    },
    midnight = {
        frameBg     = { 0.06, 0.07, 0.12, 0.97 },
        headerBg    = { 0.07, 0.08, 0.14, 0.95 },
        heroBg      = { 0.08, 0.09, 0.16, 0.92 },
        panelBg     = { 0.06, 0.07, 0.13, 0.95 },
        chatBg      = { 0.04, 0.05, 0.10, 0.95 },
        accent      = { 0.00, 0.78, 1.00 },
        titleText   = { 0.92, 0.93, 0.96 },
        bodyText    = { 0.82, 0.84, 0.88 },
        mutedText   = { 0.58, 0.60, 0.65 },
        divider     = { 0.25, 0.35, 0.55 },
        inputBg     = { 0.05, 0.06, 0.10, 0.9 },
        hoverBg     = { 0.10, 0.14, 0.25, 0.4 },
        borderTint  = { 0.00, 0.78, 1.00, 0.5 },
    },
    class = {
        frameBg     = { 0.07, 0.06, 0.05, 0.97 },
        headerBg    = { 0.09, 0.07, 0.06, 0.95 },
        heroBg      = { 0.10, 0.08, 0.06, 0.92 },
        panelBg     = { 0.08, 0.07, 0.06, 0.95 },
        chatBg      = { 0.06, 0.05, 0.04, 0.95 },
        accent      = { 0.72, 0.62, 0.42 },
        titleText   = { 0.94, 0.92, 0.88 },
        bodyText    = { 0.92, 0.90, 0.85 },
        mutedText   = { 0.65, 0.62, 0.55 },
        divider     = { 0.50, 0.48, 0.40 },
        inputBg     = { 0.06, 0.05, 0.04, 0.9 },
        hoverBg     = { 0.16, 0.14, 0.12, 0.4 },
        borderTint  = { 0.72, 0.62, 0.42, 0.6 },
    },
}

local C = {}
local function LoadTheme()
    local s = _G.MidnightUISettings
    local key = (s and s.General and s.General.characterPanelTheme) or "parchment"
    local t = THEMES[key] or THEMES.parchment
    for k, v in pairs(t) do C[k] = v end
    -- Class color override
    if key == "class" then
        local cc = _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable
            and _G.MidnightUI_Core.GetClassColorTable("player")
        if cc then
            local r, g, b = cc.r or cc[1] or 0.72, cc.g or cc[2] or 0.62, cc.b or cc[3] or 0.42
            C.accent = { r, g, b }
            C.borderTint = { r, g, b, 0.6 }
        end
    end
    C.online  = { 0.40, 0.85, 0.40 }
    C.offline = { 0.50, 0.50, 0.50 }
end
LoadTheme()

-- ============================================================================
-- §3  CONFIGURATION
-- ============================================================================
local CFG = {
    WIDTH           = 1200,
    HEIGHT          = 780,
    HEADER_H        = 44,
    HERO_H          = 90,
    ROSTER_PCT      = 0.48,
    CHAT_PCT        = 0.52,
    SEARCH_H        = 28,
    SORT_HDR_H      = 24,
    ROSTER_ROW_H    = 24,
    SECTION_HDR_H   = 26,
    CHAT_INPUT_H    = 32,
    CHAT_MSG_H      = 18,
    PAD             = 12,
    STRATA          = "HIGH",
    COL_LVL         = 30,
    COL_RANK        = 90,
    COL_ZONE        = 110,
    COL_LASTON      = 50,
}

-- ============================================================================
-- §4  HELPERS
-- ============================================================================
local function CreateDropShadow(frame, intensity)
    intensity = intensity or 5
    for i = 1, intensity do
        local s = CreateFrame("Frame", nil, frame)
        s:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local off = i * 0.8
        local a = (0.18 - (i * 0.025)) * (intensity / 6)
        s:SetPoint("TOPLEFT", -off, off)
        s:SetPoint("BOTTOMRIGHT", off, -off)
        local t = s:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints(); t:SetColorTexture(0, 0, 0, a)
    end
end

-- ============================================================================
-- §5  PANEL STATE
-- ============================================================================
local Panel = {}
Panel._state = {
    initialized   = false,
    panelOpen     = false,
    searchText    = "",
    sortColumn    = "rank",
    sortAsc       = true,
    onlineExpanded      = true,
    offlineExpanded     = false,
    challengesExpanded  = false,
    newsExpanded        = false,
    filterMode          = "default",  -- "default", "achievePts", "mythicPlus"
}
Panel._refs = {}

-- Forward declarations for functions defined later
local DetectMPlusMessage
local ShowMPlusToast
local ShowLFGNotification

-- ============================================================================
-- §6  DATA: GUILD INFO
-- ============================================================================
local function GetGuildData()
    if not IsInGuild() then return nil end
    local guildName, rankName, rankIndex, realm = SafeCall(GetGuildInfo, "player")
    local total, online, onlineMobile = SafeCall(GetNumGuildMembers)
    local motd = SafeCall(GetGuildRosterMOTD) or ""
    return {
        name = guildName or "Unknown Guild",
        realm = realm or SafeCall(GetRealmName) or "",
        rankName = rankName or "",
        rankIndex = rankIndex or 0,
        totalMembers = total or 0,
        onlineMembers = online or 0,
        onlineMobile = onlineMobile or 0,
        motd = motd,
    }
end

-- ============================================================================
-- §7  DATA: ROSTER
-- ============================================================================
local function CollectRoster(searchText, sortCol, sortAsc)
    local online, offline = {}, {}
    local total = SafeCall(GetNumGuildMembers) or 0
    local search = (searchText and searchText ~= "") and searchText:lower() or nil

    for i = 1, total do
        -- Call directly with pcall (SafeCall only returns 8 values, we need 14+)
        -- Returns: name, rankName, rankIndex, level, classLocalized,
        --          zone, publicNote, officerNote, isOnline, status,
        --          classFile, achievementPoints, achievementRank, isMobile, canSoR, repStanding, guid
        local ok, name, rankName, rankIndex, level, classLocalized,
              zone, publicNote, officerNote, isOnline, status,
              classFile, achievementPoints, achievementRank, isMobile,
              canSoR, repStanding, guid
        if GetGuildRosterInfo then
            ok, name, rankName, rankIndex, level, classLocalized,
                zone, publicNote, officerNote, isOnline, status,
                classFile, achievementPoints, achievementRank, isMobile,
                canSoR, repStanding, guid = pcall(GetGuildRosterInfo, i)
            if not ok then name = nil end
        end

        -- Get last online info for offline members
        local lastOnline = ""
        if name and not isOnline and not isMobile and GetGuildRosterLastOnline then
            local okLO, years, months, days, hours = pcall(GetGuildRosterLastOnline, i)
            if okLO then
                if (years or 0) > 0 then lastOnline = years .. "y"
                elseif (months or 0) > 0 then lastOnline = months .. "mo"
                elseif (days or 0) > 0 then lastOnline = days .. "d"
                elseif (hours or 0) > 0 then lastOnline = hours .. "h"
                else lastOnline = "<1h"
                end
            end
        end

        if name then
            local shortName = name:match("^([^%-]+)") or name
            if not search or shortName:lower():find(search, 1, true) then
                local entry = {
                    fullName        = name,
                    name            = shortName,
                    rankName        = rankName or "",
                    rankIndex       = rankIndex or 99,
                    level           = level or 0,
                    classFile       = classFile or classLocalized or "WARRIOR",
                    className       = classLocalized or "",
                    zone            = zone or "",
                    publicNote      = publicNote or "",
                    officerNote     = officerNote or "",
                    isOnline        = isOnline or false,
                    isMobile        = isMobile or false,
                    lastOnline      = lastOnline,
                    achievementPts  = achievementPoints or 0,
                    guid            = guid or "",
                    rosterIndex     = i,
                    mythicPlusRating = 0,
                }
                -- Pre-fetch M+ rating for online members
                if (isOnline or isMobile) and guid and guid ~= "" then
                    if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary and PlayerLocation then
                        local okLoc, playerLoc = pcall(PlayerLocation.CreateFromGUID, PlayerLocation, guid)
                        if okLoc and playerLoc then
                            local okSum, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, playerLoc)
                            if okSum and summary and summary.currentSeasonScore then
                                entry.mythicPlusRating = summary.currentSeasonScore
                            end
                        end
                    end
                end
                -- Pre-fetch MPI score for sorting
                if _G.MidnightPI then
                    local PI = _G.MidnightPI
                    local prof = PI.GetProfileByName and PI.GetProfileByName(entry.name)
                    if not prof and PI.CommunityLookup then
                        local realm = entry.fullName and entry.fullName:match("%-(.+)$") or (GetRealmName and GetRealmName() or "")
                        prof = PI.CommunityLookup(entry.name, realm)
                    end
                    entry._mpiScore = prof and prof.avgMPI or 0
                end
                if isOnline or isMobile then
                    online[#online + 1] = entry
                else
                    offline[#offline + 1] = entry
                end
            end
        end
    end

    -- Sort
    local function Sorter(a, b)
        if sortCol == "name" then
            if sortAsc then return a.name:lower() < b.name:lower() else return a.name:lower() > b.name:lower() end
        elseif sortCol == "level" then
            if sortAsc then return a.level > b.level else return a.level < b.level end
        elseif sortCol == "rank" then
            if sortAsc then return a.rankIndex < b.rankIndex else return a.rankIndex > b.rankIndex end
        elseif sortCol == "zone" then
            if sortAsc then return a.zone:lower() < b.zone:lower() else return a.zone:lower() > b.zone:lower() end
        elseif sortCol == "class" then
            if sortAsc then return a.classFile < b.classFile else return a.classFile > b.classFile end
        elseif sortCol == "lastOn" then
            local filterMode = Panel._state.filterMode or "default"
            if filterMode == "mythicPlus" then
                local aS, bS = a.mythicPlusRating or 0, b.mythicPlusRating or 0
                if sortAsc then return aS > bS else return aS < bS end
            elseif filterMode == "achievePts" then
                local aP, bP = a.achievementPts or 0, b.achievementPts or 0
                if sortAsc then return aP > bP else return aP < bP end
            elseif filterMode == "mpiScore" then
                local aM, bM = a._mpiScore or 0, b._mpiScore or 0
                if sortAsc then return aM > bM else return aM < bM end
            end
            if sortAsc then return a.lastOnline < b.lastOnline else return a.lastOnline > b.lastOnline end
        end
        return a.rankIndex < b.rankIndex
    end

    table.sort(online, Sorter)
    table.sort(offline, Sorter)
    return online, offline
end

-- ============================================================================
-- §8  PANEL CREATION
-- ============================================================================
function Panel.EnsurePanel()
    if Panel._state.initialized then return Panel._refs.panel end
    Panel._state.initialized = true
    local R = Panel._refs

    -- ── §8a  Main Frame ────────────────────────────────────────────────
    local p = CreateFrame("Frame", "MidnightUI_GuildPanel", UIParent, "BackdropTemplate")
    p:SetSize(CFG.WIDTH, CFG.HEIGHT)
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    p:SetFrameStrata(CFG.STRATA)
    p:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    p:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    p:SetBackdropBorderColor(C.borderTint[1], C.borderTint[2], C.borderTint[3], C.borderTint[4])
    p:Hide()
    R.panel = p
    CreateDropShadow(p, 5)

    -- ESC to close
    p:SetScript("OnShow", function()
        local found = false
        for _, n in ipairs(UISpecialFrames) do if n == "MidnightUI_GuildPanel" then found = true; break end end
        if not found then table.insert(UISpecialFrames, "MidnightUI_GuildPanel") end
    end)
    p:SetScript("OnHide", function()
        Panel._state.panelOpen = false
        R._tabardModelReady = false
    end)

    -- Fade
    local fadeIn = p:CreateAnimationGroup()
    local fi = fadeIn:CreateAnimation("Alpha"); fi:SetFromAlpha(0); fi:SetToAlpha(1); fi:SetDuration(0.20); fi:SetSmoothing("OUT")
    p._fadeIn = fadeIn
    local fadeOut = p:CreateAnimationGroup()
    local fo = fadeOut:CreateAnimation("Alpha"); fo:SetFromAlpha(1); fo:SetToAlpha(0); fo:SetDuration(0.15); fo:SetSmoothing("IN")
    fadeOut:SetScript("OnFinished", function() p:Hide(); p:SetAlpha(1) end)
    p._fadeOut = fadeOut

    -- ── §8b  Header ────────────────────────────────────────────────────
    local hdr = CreateFrame("Frame", nil, p)
    hdr:SetHeight(CFG.HEADER_H); hdr:SetPoint("TOPLEFT", 0, 0); hdr:SetPoint("TOPRIGHT", 0, 0)
    local hdrBg = hdr:CreateTexture(nil, "BACKGROUND"); hdrBg:SetAllPoints()
    hdrBg:SetColorTexture(C.headerBg[1], C.headerBg[2], C.headerBg[3], C.headerBg[4])
    R.header = hdr; R.hdrBg = hdrBg

    -- Header accent line
    local hdrAccent = hdr:CreateTexture(nil, "OVERLAY"); hdrAccent:SetHeight(2)
    hdrAccent:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
    hdrAccent:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
    hdrAccent:SetTexture(W8)
    if hdrAccent.SetGradient and CreateColor then
        hdrAccent:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.6),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
    end

    local titleFS = hdr:CreateFontString(nil, "OVERLAY")
    TrySetFont(titleFS, TITLE_FONT, 16, "OUTLINE")
    titleFS:SetPoint("LEFT", hdr, "LEFT", 16, 0)
    titleFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    R.headerTitle = titleFS

    local closeBtn = CreateFrame("Button", nil, hdr)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTx, TITLE_FONT, 16, "OUTLINE"); closeTx:SetPoint("CENTER"); closeTx:SetText("X")
    closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7) end)
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)

    -- M+ LFG button (Dungeon Eye)
    local lfgBtn = CreateFrame("Button", nil, hdr)
    lfgBtn:SetSize(24, 24); lfgBtn:SetPoint("RIGHT", closeBtn, "LEFT", -8, 0)
    local lfgIcon = lfgBtn:CreateTexture(nil, "OVERLAY")
    lfgIcon:SetAllPoints()
    lfgIcon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
    lfgIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    lfgIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
    lfgBtn:SetScript("OnEnter", function(self)
        lfgIcon:SetVertexColor(C.titleText[1], C.titleText[2], C.titleText[3])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Find M+ Group", 1, 1, 1)
        GameTooltip:AddLine("Create a Mythic+ listing for your guild", C.mutedText[1], C.mutedText[2], C.mutedText[3])
        GameTooltip:Show()
    end)
    lfgBtn:SetScript("OnLeave", function()
        lfgIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
        GameTooltip:Hide()
    end)
    lfgBtn:SetScript("OnClick", function()
        Panel.ShowLFGOverlay()
    end)

    -- Perks button
    local perksBtn = CreateFrame("Button", nil, hdr)
    perksBtn:SetSize(24, 24); perksBtn:SetPoint("RIGHT", lfgBtn, "LEFT", -6, 0)
    local perksIcon = perksBtn:CreateTexture(nil, "OVERLAY")
    perksIcon:SetAllPoints(); perksIcon:SetTexture("Interface\\Icons\\Achievement_GuildPerk_MobileBanking")
    perksIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    perksIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
    perksBtn:SetScript("OnEnter", function(self)
        perksIcon:SetVertexColor(C.titleText[1], C.titleText[2], C.titleText[3])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Guild Perks & Rewards", 1, 1, 1)
        GameTooltip:Show()
    end)
    perksBtn:SetScript("OnLeave", function()
        perksIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
        GameTooltip:Hide()
    end)
    perksBtn:SetScript("OnClick", function()
        Panel.TogglePerks()
    end)

    -- Recruitment button (officer-only, hidden by default — shown in Panel.Show)
    local recruitBtn = CreateFrame("Button", nil, hdr)
    recruitBtn:SetSize(24, 24); recruitBtn:SetPoint("RIGHT", perksBtn, "LEFT", -6, 0)
    local recruitIcon = recruitBtn:CreateTexture(nil, "OVERLAY")
    recruitIcon:SetAllPoints(); recruitIcon:SetTexture("Interface\\Icons\\Achievement_GuildPerk_EverybodysFriend")
    recruitIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    recruitIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
    recruitBtn:SetScript("OnEnter", function(self)
        recruitIcon:SetVertexColor(C.titleText[1], C.titleText[2], C.titleText[3])
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
        GameTooltip:SetText("Guild Recruitment", 1, 1, 1)
        GameTooltip:AddLine("Manage recruitment or review applications", C.mutedText[1], C.mutedText[2], C.mutedText[3])
        GameTooltip:Show()
    end)
    recruitBtn:SetScript("OnLeave", function()
        recruitIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
        GameTooltip:Hide()
    end)
    recruitBtn:SetScript("OnClick", function()
        local api = _G.MidnightUI_GuildRecruitAPI
        if api and api.CanManageRecruitment and api.CanManageRecruitment() then
            api.ShowConfigOverlay()
        end
    end)
    recruitBtn:Hide()

    -- Badge dot (pending application count)
    local badgeDot = recruitBtn:CreateTexture(nil, "OVERLAY", nil, 7)
    badgeDot:SetSize(10, 10); badgeDot:SetPoint("TOPRIGHT", recruitBtn, "TOPRIGHT", 3, 3)
    badgeDot:SetColorTexture(0.90, 0.30, 0.30, 0.9)
    badgeDot:Hide()

    local badgeCount = recruitBtn:CreateFontString(nil, "OVERLAY", nil, 8)
    TrySetFont(badgeCount, BODY_FONT, 8, "OUTLINE")
    badgeCount:SetPoint("CENTER", badgeDot, "CENTER", 0, 0)
    badgeCount:SetTextColor(1, 1, 1)
    badgeCount:Hide()

    -- Store refs for GuildRecruit module to update
    R.recruitBtn = recruitBtn
    R.recruitBadgeDot = badgeDot
    R.recruitBadgeCount = badgeCount
    R.perksBtn = perksBtn

    -- Settings gear button (anchors to perksBtn by default; re-anchored in Panel.Show if recruit btn visible)
    local gearBtn = CreateFrame("Button", nil, hdr)
    gearBtn:SetSize(24, 24); gearBtn:SetPoint("RIGHT", perksBtn, "LEFT", -6, 0)
    local gearIcon = gearBtn:CreateTexture(nil, "OVERLAY")
    gearIcon:SetAllPoints(); gearIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
    gearIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    gearIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70)
    gearBtn:SetScript("OnEnter", function() gearIcon:SetVertexColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
    gearBtn:SetScript("OnLeave", function() gearIcon:SetVertexColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.70) end)
    gearBtn:SetScript("OnClick", function()
        if R.settingsPopup and R.settingsPopup:IsShown() then
            R.settingsPopup:Hide()
        else
            Panel.ShowSettingsPopup()
        end
    end)
    R.gearBtn = gearBtn

    -- Settings popup (theme selector)
    local settingsPopup = CreateFrame("Frame", nil, p, "BackdropTemplate")
    settingsPopup:SetSize(180, 120)
    settingsPopup:SetPoint("TOPRIGHT", gearBtn, "BOTTOMRIGHT", 0, -4)
    settingsPopup:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    settingsPopup:SetBackdropColor(C.headerBg[1], C.headerBg[2], C.headerBg[3], 0.96)
    settingsPopup:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.5)
    settingsPopup:SetFrameLevel(p:GetFrameLevel() + 20)
    settingsPopup:Hide()
    R.settingsPopup = settingsPopup

    local popupTitle = settingsPopup:CreateFontString(nil, "OVERLAY")
    TrySetFont(popupTitle, BODY_FONT, 10, "OUTLINE")
    popupTitle:SetPoint("TOP", settingsPopup, "TOP", 0, -8)
    popupTitle:SetText("Theme"); popupTitle:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

    local themeOptions = {
        { key = "parchment", label = "Warm Parchment" },
        { key = "midnight",  label = "Cool Midnight" },
        { key = "class",     label = "Class Color" },
    }
    for ti, opt in ipairs(themeOptions) do
        local tBtn = CreateFrame("Button", nil, settingsPopup)
        tBtn:SetSize(160, 24); tBtn:SetPoint("TOP", settingsPopup, "TOP", 0, -24 - (ti - 1) * 28)
        local tLbl = tBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(tLbl, BODY_FONT, 11, ""); tLbl:SetPoint("CENTER")
        tLbl:SetText(opt.label); tLbl:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        tBtn:SetScript("OnClick", function()
            local s = _G.MidnightUISettings
            if s and s.General then s.General.characterPanelTheme = opt.key end
            settingsPopup:Hide()
            LoadTheme()
            Panel.ApplyTheme()
        end)
        tBtn:SetScript("OnEnter", function() tLbl:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
        tBtn:SetScript("OnLeave", function() tLbl:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3]) end)
    end

    -- Draggable
    p:EnableMouse(true); p:SetMovable(true)
    hdr:EnableMouse(true); hdr:RegisterForDrag("LeftButton")
    hdr:SetScript("OnDragStart", function() p:StartMoving() end)
    hdr:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)

    -- ── §8c  Hero Banner (tabard + glass panel) ─────────────────────────
    local rosterW = math.floor(CFG.WIDTH * CFG.ROSTER_PCT)
    local contentH = CFG.HEIGHT - CFG.HEADER_H
    local halfH = math.floor(contentH / 2)

    local hero = CreateFrame("Frame", nil, p)
    hero:SetHeight(halfH)
    hero:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    hero:SetWidth(rosterW)
    R.hero = hero

    -- ── Hero background layers ──
    local heroBg = hero:CreateTexture(nil, "BACKGROUND", nil, -8)
    heroBg:SetAllPoints()
    heroBg:SetColorTexture(C.heroBg[1], C.heroBg[2], C.heroBg[3], C.heroBg[4])
    R.heroBg = heroBg

    -- Atlas art background (subtle, behind everything)
    local heroAtlas = hero:CreateTexture(nil, "BACKGROUND", nil, -7)
    heroAtlas:SetAllPoints()
    local atlasOk = pcall(heroAtlas.SetAtlas, heroAtlas, "UI-Frame-Bar-Fill-Yellow", false)
    if not atlasOk then heroAtlas:SetColorTexture(0, 0, 0, 0) end
    heroAtlas:SetAlpha(0.03)
    heroAtlas:SetVertexColor(C.accent[1], C.accent[2], C.accent[3])

    -- Top accent glow (stronger)
    local heroGlow = hero:CreateTexture(nil, "BACKGROUND", nil, -6)
    heroGlow:SetHeight(60)
    heroGlow:SetPoint("TOPLEFT", hero, "TOPLEFT", 0, 0)
    heroGlow:SetPoint("TOPRIGHT", hero, "TOPRIGHT", 0, 0)
    heroGlow:SetTexture(W8)
    if heroGlow.SetGradient and CreateColor then
        heroGlow:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.12))
    end
    R.heroGlow = heroGlow

    -- Bottom vignette
    local heroVig = hero:CreateTexture(nil, "BACKGROUND", nil, -6)
    heroVig:SetHeight(40)
    heroVig:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", 0, 0)
    heroVig:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", 0, 0)
    heroVig:SetTexture(W8)
    if heroVig.SetGradient and CreateColor then
        heroVig:SetGradient("VERTICAL",
            CreateColor(C.heroBg[1], C.heroBg[2], C.heroBg[3], 0.8),
            CreateColor(0, 0, 0, 0))
    end

    -- ── Guild identity section (vertically centered in top area) ──
    -- Emblem container with glow ring
    local emblemFrame = CreateFrame("Frame", nil, hero)
    emblemFrame:SetSize(56, 56)
    emblemFrame:SetPoint("TOPLEFT", hero, "TOPLEFT", CFG.PAD + 4, -CFG.PAD)

    -- Emblem glow ring behind the icon
    local emblemGlow = emblemFrame:CreateTexture(nil, "BACKGROUND")
    emblemGlow:SetSize(64, 64)
    emblemGlow:SetPoint("CENTER")
    emblemGlow:SetTexture("Interface\\COMMON\\RingBorder")
    emblemGlow:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.25)
    emblemGlow:SetBlendMode("ADD")
    R.emblemGlow = emblemGlow

    -- Dark circle behind emblem
    local emblemBg = emblemFrame:CreateTexture(nil, "ARTWORK", nil, 0)
    emblemBg:SetSize(48, 48)
    emblemBg:SetPoint("CENTER")
    emblemBg:SetColorTexture(0, 0, 0, 0.5)

    -- Guild tabard model (most reliable way to show guild emblem)
    local tabardModel = CreateFrame("PlayerModel", nil, emblemFrame)
    tabardModel:SetSize(52, 52)
    tabardModel:SetPoint("CENTER")
    tabardModel:SetFrameLevel(emblemFrame:GetFrameLevel() + 1)
    R.tabardModel = tabardModel

    -- Fallback emblem icon (shown if model doesn't work)
    local emblemIcon = emblemFrame:CreateTexture(nil, "ARTWORK", nil, 1)
    emblemIcon:SetSize(44, 44)
    emblemIcon:SetPoint("CENTER")
    emblemIcon:Hide()
    R.emblemIcon = emblemIcon

    -- 1px accent border on emblem
    local eBorders = {}
    eBorders[1] = emblemFrame:CreateTexture(nil, "OVERLAY"); eBorders[1]:SetHeight(1)
    eBorders[1]:SetPoint("TOPLEFT", emblemBg, -1, 1); eBorders[1]:SetPoint("TOPRIGHT", emblemBg, 1, 1)
    eBorders[2] = emblemFrame:CreateTexture(nil, "OVERLAY"); eBorders[2]:SetHeight(1)
    eBorders[2]:SetPoint("BOTTOMLEFT", emblemBg, -1, -1); eBorders[2]:SetPoint("BOTTOMRIGHT", emblemBg, 1, -1)
    eBorders[3] = emblemFrame:CreateTexture(nil, "OVERLAY"); eBorders[3]:SetWidth(1)
    eBorders[3]:SetPoint("TOPLEFT", emblemBg, -1, 1); eBorders[3]:SetPoint("BOTTOMLEFT", emblemBg, -1, -1)
    eBorders[4] = emblemFrame:CreateTexture(nil, "OVERLAY"); eBorders[4]:SetWidth(1)
    eBorders[4]:SetPoint("TOPRIGHT", emblemBg, 1, 1); eBorders[4]:SetPoint("BOTTOMRIGHT", emblemBg, 1, -1)
    for _, b in ipairs(eBorders) do b:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.4) end
    R.emblemBorders = eBorders

    -- Guild name (large, dramatic)
    local guildNameFS = hero:CreateFontString(nil, "OVERLAY")
    TrySetFont(guildNameFS, TITLE_FONT, 22, "OUTLINE")
    guildNameFS:SetPoint("TOPLEFT", emblemFrame, "TOPRIGHT", 14, -4)
    guildNameFS:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
    guildNameFS:SetShadowColor(0, 0, 0, 0.8)
    guildNameFS:SetShadowOffset(2, -2)
    R.heroGuildName = guildNameFS

    -- Stats bar (below guild name, with colored segments)
    local infoFS = hero:CreateFontString(nil, "OVERLAY")
    TrySetFont(infoFS, BODY_FONT, 11, "")
    infoFS:SetPoint("TOPLEFT", guildNameFS, "BOTTOMLEFT", 0, -4)
    infoFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
    R.infoFS = infoFS

    -- Accent underline below identity
    local identityLine = hero:CreateTexture(nil, "OVERLAY")
    identityLine:SetHeight(2)
    identityLine:SetPoint("TOPLEFT", emblemFrame, "BOTTOMLEFT", -4, -8)
    identityLine:SetPoint("RIGHT", hero, "RIGHT", -CFG.PAD, 0)
    identityLine:SetTexture(W8)
    if identityLine.SetGradient and CreateColor then
        identityLine:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.5),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
    end
    R.identityLine = identityLine

    -- ── Scrollable MOTD + Guild Info area (fills rest of hero) ──
    local heroScroll = CreateFrame("ScrollFrame", nil, hero, "UIPanelScrollFrameTemplate")
    heroScroll:SetPoint("TOPLEFT", identityLine, "BOTTOMLEFT", 0, -8)
    heroScroll:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", -20, 4)
    local heroContent = CreateFrame("Frame", nil, heroScroll)
    heroContent:SetWidth(1)
    heroScroll:SetScrollChild(heroContent)
    heroScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then heroContent:SetWidth(w) end end)
    if heroScroll.ScrollBar then
        local sb = heroScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.20); sb.ThumbTexture:SetWidth(3) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    R.heroScroll = heroScroll
    R.heroContent = heroContent

    -- MOTD card (static, text updated by UpdateGuildInfo)
    local motdCard = CreateFrame("Frame", nil, heroContent, "BackdropTemplate")
    motdCard:SetPoint("TOPLEFT", heroContent, "TOPLEFT", 0, 0)
    motdCard:SetPoint("RIGHT", heroContent, "RIGHT", 0, 0)
    motdCard:SetHeight(60)
    motdCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    motdCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
    motdCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    R.motdCard = motdCard

    local motdLbl = motdCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(motdLbl, BODY_FONT, 10, "OUTLINE")
    motdLbl:SetPoint("TOPLEFT", motdCard, "TOPLEFT", 8, -8)
    motdLbl:SetText("MESSAGE OF THE DAY")
    motdLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    R.motdLbl = motdLbl

    local motdFS = motdCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(motdFS, BODY_FONT, 11, "")
    motdFS:SetPoint("TOPLEFT", motdLbl, "BOTTOMLEFT", 0, -6)
    motdFS:SetPoint("RIGHT", motdCard, "RIGHT", -8, 0)
    motdFS:SetJustifyH("LEFT"); motdFS:SetWordWrap(true); motdFS:SetSpacing(3)
    motdFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    R.motdFS = motdFS

    -- Recruitment status badge (managed by GuildRecruit module)
    local recruitBadgeFrame = CreateFrame("Frame", nil, heroContent)
    recruitBadgeFrame:SetHeight(20)
    recruitBadgeFrame:SetPoint("TOPLEFT", motdCard, "BOTTOMLEFT", 8, -6)
    recruitBadgeFrame:SetPoint("RIGHT", heroContent, "RIGHT", -8, 0)
    recruitBadgeFrame:Hide()
    R.recruitBadgeAnchor = recruitBadgeFrame

    -- Initialize badge if GuildRecruit module is loaded
    C_Timer.After(0.5, function()
        local api = _G.MidnightUI_GuildRecruitAPI
        if api and api.CreateBadge then
            api.CreateBadge(recruitBadgeFrame, C)
            api.RefreshBadge()
        end
        -- Also set header badge refs
        if api and R.recruitBtn then
            -- Find the badge dot and count (children of recruitBtn)
            for _, region in ipairs({ R.recruitBtn:GetRegions() }) do
                if region:GetObjectType() == "Texture" and region:GetSize() and select(1, region:GetSize()) <= 12 then
                    api._headerBadgeDot = region
                end
            end
        end
    end)

    -- Guild Info card (static, text updated by UpdateGuildInfo)
    local gInfoCard = CreateFrame("Frame", nil, heroContent, "BackdropTemplate")
    gInfoCard:SetPoint("TOPLEFT", motdCard, "BOTTOMLEFT", 0, -8)
    gInfoCard:SetPoint("RIGHT", heroContent, "RIGHT", 0, 0)
    gInfoCard:SetHeight(60)
    gInfoCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    gInfoCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
    gInfoCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    R.gInfoCard = gInfoCard

    local gInfoLbl = gInfoCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(gInfoLbl, BODY_FONT, 10, "OUTLINE")
    gInfoLbl:SetPoint("TOPLEFT", gInfoCard, "TOPLEFT", 8, -8)
    gInfoLbl:SetText("GUILD INFORMATION")
    gInfoLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    R.gInfoLbl = gInfoLbl

    local gInfoFS = gInfoCard:CreateFontString(nil, "OVERLAY")
    TrySetFont(gInfoFS, BODY_FONT, 11, "")
    gInfoFS:SetPoint("TOPLEFT", gInfoLbl, "BOTTOMLEFT", 0, -6)
    gInfoFS:SetPoint("RIGHT", gInfoCard, "RIGHT", -8, 0)
    gInfoFS:SetJustifyH("LEFT"); gInfoFS:SetWordWrap(true); gInfoFS:SetSpacing(3)
    gInfoFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], 0.80)
    R.gInfoFS = gInfoFS

    -- Guild Challenges card (collapsible, collapsed by default)
    local challengeCard = CreateFrame("Frame", nil, heroContent, "BackdropTemplate")
    challengeCard:SetPoint("TOPLEFT", gInfoCard, "BOTTOMLEFT", 0, -8)
    challengeCard:SetPoint("RIGHT", heroContent, "RIGHT", 0, 0)
    challengeCard:SetHeight(30)
    challengeCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    challengeCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
    challengeCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    R.challengeCard = challengeCard

    local challengeHdrBtn = CreateFrame("Button", nil, challengeCard)
    challengeHdrBtn:SetHeight(26); challengeHdrBtn:SetPoint("TOPLEFT", 0, 0); challengeHdrBtn:SetPoint("TOPRIGHT", 0, 0)
    challengeHdrBtn:EnableMouse(true); challengeHdrBtn:RegisterForClicks("LeftButtonUp")
    local challengeChevron = challengeHdrBtn:CreateTexture(nil, "OVERLAY")
    challengeChevron:SetSize(10, 10); challengeChevron:SetPoint("LEFT", challengeHdrBtn, "LEFT", 8, 0)
    challengeChevron:SetAtlas("common-dropdown-icon-back"); challengeChevron:SetRotation(math.pi)
    challengeChevron:SetVertexColor(C.accent[1], C.accent[2], C.accent[3])
    R.challengeChevron = challengeChevron
    local challengeLbl = challengeHdrBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(challengeLbl, BODY_FONT, 10, "OUTLINE")
    challengeLbl:SetPoint("LEFT", challengeChevron, "RIGHT", 4, 0)
    challengeLbl:SetText("GUILD CHALLENGES"); challengeLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    R.challengeLbl = challengeLbl
    local challengeContent = CreateFrame("Frame", nil, challengeCard)
    challengeContent:SetPoint("TOPLEFT", challengeHdrBtn, "BOTTOMLEFT", 8, -4)
    challengeContent:SetPoint("RIGHT", challengeCard, "RIGHT", -8, 0)
    challengeContent:SetHeight(1); challengeContent:Hide()
    R.challengeContent = challengeContent
    challengeHdrBtn:SetScript("OnClick", function()
        Panel._state.challengesExpanded = not Panel._state.challengesExpanded
        if Panel._state.challengesExpanded then
            challengeChevron:SetRotation(-math.pi / 2)
            challengeContent:Show()
            Panel.UpdateGuildChallenges()
        else
            challengeChevron:SetRotation(math.pi)
            challengeContent:Hide()
        end
        -- Size immediately and again after a short delay
        Panel.SizeInfoCards()
        C_Timer.After(0.15, function() Panel.SizeInfoCards() end)
    end)

    -- Guild News card (collapsible, collapsed by default)
    local newsCard = CreateFrame("Frame", nil, heroContent, "BackdropTemplate")
    newsCard:SetPoint("TOPLEFT", challengeCard, "BOTTOMLEFT", 0, -8)
    newsCard:SetPoint("RIGHT", heroContent, "RIGHT", 0, 0)
    newsCard:SetHeight(30)
    newsCard:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    newsCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
    newsCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    R.newsCard = newsCard

    local newsHdrBtn = CreateFrame("Button", nil, newsCard)
    newsHdrBtn:SetHeight(26); newsHdrBtn:SetPoint("TOPLEFT", 0, 0); newsHdrBtn:SetPoint("TOPRIGHT", 0, 0)
    newsHdrBtn:EnableMouse(true); newsHdrBtn:RegisterForClicks("LeftButtonUp")
    local newsChevron = newsHdrBtn:CreateTexture(nil, "OVERLAY")
    newsChevron:SetSize(10, 10); newsChevron:SetPoint("LEFT", newsHdrBtn, "LEFT", 8, 0)
    newsChevron:SetAtlas("common-dropdown-icon-back"); newsChevron:SetRotation(math.pi)
    newsChevron:SetVertexColor(C.accent[1], C.accent[2], C.accent[3])
    R.newsChevron = newsChevron
    local newsLbl = newsHdrBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(newsLbl, BODY_FONT, 10, "OUTLINE")
    newsLbl:SetPoint("LEFT", newsChevron, "RIGHT", 4, 0)
    newsLbl:SetText("GUILD NEWS"); newsLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    R.newsLbl = newsLbl
    local newsContent = CreateFrame("Frame", nil, newsCard)
    newsContent:SetPoint("TOPLEFT", newsHdrBtn, "BOTTOMLEFT", 8, -4)
    newsContent:SetPoint("RIGHT", newsCard, "RIGHT", -8, 0)
    newsContent:SetHeight(1); newsContent:Hide()
    R.newsContent = newsContent
    newsHdrBtn:SetScript("OnClick", function()
        Panel._state.newsExpanded = not Panel._state.newsExpanded
        if Panel._state.newsExpanded then
            newsChevron:SetRotation(-math.pi / 2)
            newsContent:Show()
            Panel.UpdateGuildNews()
        else
            newsChevron:SetRotation(math.pi)
            newsContent:Hide()
        end
        Panel.SizeInfoCards()
        C_Timer.After(0.15, function() Panel.SizeInfoCards() end)
    end)

    -- Hero bottom separator (accent gradient)
    local heroSep2 = hero:CreateTexture(nil, "OVERLAY"); heroSep2:SetHeight(1)
    heroSep2:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", 0, 0)
    heroSep2:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", 0, 0)
    heroSep2:SetTexture(W8)
    if heroSep2.SetGradient and CreateColor then
        heroSep2:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.4),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
    end

    -- ── §8d  Left Column: Guild Info + Roster ────────────────────────────

    local rosterPanel = CreateFrame("Frame", nil, p)
    rosterPanel:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, 0)
    rosterPanel:SetHeight(halfH)
    rosterPanel:SetWidth(rosterW)
    local rosterBg = rosterPanel:CreateTexture(nil, "BACKGROUND"); rosterBg:SetAllPoints()
    rosterBg:SetColorTexture(C.panelBg[1], C.panelBg[2], C.panelBg[3], C.panelBg[4])
    R.rosterPanel = rosterPanel; R.rosterBg = rosterBg

    -- Vertical divider between left column and chat
    local colDiv = p:CreateTexture(nil, "OVERLAY")
    colDiv:SetWidth(1)
    colDiv:SetPoint("TOP", hdr, "BOTTOM", 0, 0)
    colDiv:SetPoint("BOTTOM", p, "BOTTOM", 0, 0)
    colDiv:SetPoint("LEFT", p, "LEFT", rosterW, 0)
    R.colDiv = colDiv
    colDiv:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.2)

    -- Search box
    local searchBox = CreateFrame("EditBox", nil, rosterPanel, "BackdropTemplate")
    searchBox:SetHeight(CFG.SEARCH_H)
    searchBox:SetPoint("TOPLEFT", rosterPanel, "TOPLEFT", CFG.PAD, -CFG.PAD)
    searchBox:SetPoint("TOPRIGHT", rosterPanel, "TOPRIGHT", -CFG.PAD, -CFG.PAD)
    searchBox:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 8, right = 8, top = 4, bottom = 4 } })
    searchBox:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    searchBox:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.15)
    TrySetFont(searchBox, BODY_FONT, 11, "")
    searchBox:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    searchBox:SetAutoFocus(false)
    searchBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchBox:SetScript("OnTextChanged", function(self)
        Panel._state.searchText = self:GetText() or ""
        Panel.UpdateRoster()
    end)
    -- Placeholder
    local searchPlaceholder = searchBox:CreateFontString(nil, "OVERLAY")
    TrySetFont(searchPlaceholder, BODY_FONT, 11, "")
    searchPlaceholder:SetPoint("LEFT", searchBox, "LEFT", 8, 0)
    searchPlaceholder:SetText("Search members...")
    searchPlaceholder:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
    searchBox:SetScript("OnEditFocusGained", function() searchPlaceholder:Hide() end)
    searchBox:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then searchPlaceholder:Show() end
    end)
    R.searchBox = searchBox

    -- Filter button (right side of search box, Diagnostics-style)
    local filterBtn = CreateFrame("Button", nil, rosterPanel)
    filterBtn:SetSize(54, CFG.SEARCH_H)
    filterBtn:SetPoint("LEFT", searchBox, "RIGHT", 4, 0)

    -- Border (accent tinted)
    local fbBorder = filterBtn:CreateTexture(nil, "BACKGROUND")
    fbBorder:SetAllPoints(); fbBorder:SetTexture(W8)
    fbBorder:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
    -- Background
    local fbBg = filterBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
    fbBg:SetTexture(W8); fbBg:SetVertexColor(0.07, 0.08, 0.10, 0.95)
    fbBg:SetPoint("TOPLEFT", 1, -1); fbBg:SetPoint("BOTTOMRIGHT", -1, 1)
    -- Sheen
    local fbSheen = filterBtn:CreateTexture(nil, "ARTWORK")
    fbSheen:SetTexture(W8); fbSheen:SetVertexColor(0.18, 0.22, 0.28, 0.35)
    fbSheen:SetPoint("TOPLEFT", 2, -2); fbSheen:SetPoint("BOTTOMRIGHT", -2, 10)
    -- Hover
    local fbHover = filterBtn:CreateTexture(nil, "HIGHLIGHT")
    fbHover:SetTexture(W8); fbHover:SetVertexColor(0.35, 0.40, 0.46, 0.25)
    fbHover:SetPoint("TOPLEFT", 1, -1); fbHover:SetPoint("BOTTOMRIGHT", -1, 1)
    filterBtn:SetHighlightTexture(fbHover)

    local filterBtnFS = filterBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(filterBtnFS, BODY_FONT, 10, "")
    filterBtnFS:SetPoint("CENTER")
    filterBtnFS:SetText("Filters")
    filterBtnFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

    -- Filter dropdown
    local filterDropdown = CreateFrame("Frame", nil, rosterPanel, "BackdropTemplate")
    filterDropdown:SetSize(130, 112)
    filterDropdown:SetPoint("TOPLEFT", filterBtn, "BOTTOMLEFT", 0, -4)
    filterDropdown:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    filterDropdown:SetBackdropColor(C.headerBg[1], C.headerBg[2], C.headerBg[3], 0.96)
    filterDropdown:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)
    filterDropdown:SetFrameLevel(rosterPanel:GetFrameLevel() + 10)
    filterDropdown:Hide()
    R.filterDropdown = filterDropdown

    local FILTER_MODES = {
        { key = "default",    label = "Last Online" },
        { key = "achievePts", label = "Achievement Pts" },
        { key = "mythicPlus", label = "M+ Rating" },
        { key = "mpiScore",   label = "MPI Score" },
    }
    local fdYOfs = 6
    for _, mode in ipairs(FILTER_MODES) do
        local btn = CreateFrame("Button", nil, filterDropdown)
        btn:SetHeight(22)
        btn:SetPoint("TOPLEFT", filterDropdown, "TOPLEFT", 1, -fdYOfs)
        btn:SetPoint("TOPRIGHT", filterDropdown, "TOPRIGHT", -1, -fdYOfs)

        local hv = btn:CreateTexture(nil, "BACKGROUND")
        hv:SetAllPoints(); hv:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.08); hv:Hide()

        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 11, "")
        fs:SetPoint("LEFT", btn, "LEFT", 10, 0)
        fs:SetText(mode.label)
        if Panel._state.filterMode == mode.key then
            fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
        else
            fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        end

        btn:SetScript("OnEnter", function() hv:Show() end)
        btn:SetScript("OnLeave", function() hv:Hide() end)
        local capturedKey = mode.key
        btn:SetScript("OnClick", function()
            Panel._state.filterMode = capturedKey
            filterDropdown:Hide()
            Panel.UpdateSortHeaders()
            Panel.UpdateRoster()
        end)

        fdYOfs = fdYOfs + 22
    end
    filterDropdown:SetHeight(fdYOfs + 6)

    filterBtn:SetScript("OnClick", function()
        if filterDropdown:IsShown() then
            filterDropdown:Hide()
        else
            filterDropdown:Show()
        end
    end)

    -- Adjust search box to leave room for filter button on right
    searchBox:ClearAllPoints()
    searchBox:SetHeight(CFG.SEARCH_H)
    searchBox:SetPoint("TOPLEFT", rosterPanel, "TOPLEFT", CFG.PAD, -CFG.PAD)
    searchBox:SetPoint("TOPRIGHT", rosterPanel, "TOPRIGHT", -(CFG.PAD + 54), -CFG.PAD)

    -- Sort headers
    local sortBar = CreateFrame("Frame", nil, rosterPanel)
    sortBar:SetHeight(CFG.SORT_HDR_H)
    sortBar:SetPoint("TOPLEFT", searchBox, "BOTTOMLEFT", 0, -4)
    sortBar:SetPoint("TOPRIGHT", rosterPanel, "TOPRIGHT", -CFG.PAD, 0)
    sortBar:SetPoint("TOP", searchBox, "BOTTOM", 0, -4)

    local COL_FIXED = CFG.COL_LVL + CFG.COL_RANK + CFG.COL_ZONE + CFG.COL_LASTON

    local SORT_COLS = {
        { key = "name",     label = "Name",     flex = true },
        { key = "level",    label = "Lvl",      width = CFG.COL_LVL,    rightOf = CFG.COL_RANK + CFG.COL_ZONE + CFG.COL_LASTON },
        { key = "rank",     label = "Rank",     width = CFG.COL_RANK,   rightOf = CFG.COL_ZONE + CFG.COL_LASTON },
        { key = "zone",     label = "Zone",     width = CFG.COL_ZONE,   rightOf = CFG.COL_LASTON },
        { key = "lastOn",   label = "Last",     width = CFG.COL_LASTON, rightOf = 0 },
    }
    local sortBtns = {}
    for _, col in ipairs(SORT_COLS) do
        local btn = CreateFrame("Button", nil, sortBar)
        btn:SetHeight(CFG.SORT_HDR_H)
        if col.flex then
            btn:SetPoint("TOPLEFT", sortBar, "TOPLEFT", 0, 0)
            btn:SetPoint("RIGHT", sortBar, "RIGHT", -(COL_FIXED + CFG.PAD), 0)
        else
            btn:SetPoint("RIGHT", sortBar, "RIGHT", -(col.rightOf + CFG.PAD), 0)
            btn:SetWidth(col.width)
        end

        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 10, "OUTLINE")
        if col.flex then
            fs:SetPoint("LEFT", btn, "LEFT", CFG.PAD, 0)
        else
            fs:SetPoint("LEFT", btn, "LEFT", 2, 0)
        end
        fs:SetText(col.label)
        fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
        btn._fs = fs
        btn._key = col.key

        btn:SetScript("OnClick", function()
            if Panel._state.sortColumn == col.key then
                Panel._state.sortAsc = not Panel._state.sortAsc
            else
                Panel._state.sortColumn = col.key
                Panel._state.sortAsc = true
            end
            Panel.UpdateSortHeaders()
            Panel.UpdateRoster()
        end)
        btn:SetScript("OnEnter", function() fs:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end)
        btn:SetScript("OnLeave", function()
            if Panel._state.sortColumn == col.key then
                fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            else
                fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            end
        end)

        sortBtns[col.key] = btn
    end
    R.sortBtns = sortBtns

    -- Sort header separator
    local sortSep = sortBar:CreateTexture(nil, "OVERLAY"); sortSep:SetHeight(1)
    sortSep:SetPoint("BOTTOMLEFT", sortBar, "BOTTOMLEFT", 0, 0)
    sortSep:SetPoint("BOTTOMRIGHT", sortBar, "BOTTOMRIGHT", 0, 0)
    sortSep:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.2)

    -- Roster scroll frame
    local rosterScroll = CreateFrame("ScrollFrame", nil, rosterPanel, "UIPanelScrollFrameTemplate")
    rosterScroll:SetPoint("TOPLEFT", sortBar, "BOTTOMLEFT", 0, -2)
    rosterScroll:SetPoint("BOTTOMRIGHT", rosterPanel, "BOTTOMRIGHT", -20, 4)
    local rosterContent = CreateFrame("Frame", nil, rosterScroll)
    rosterContent:SetWidth(1)
    rosterScroll:SetScrollChild(rosterContent)
    rosterScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then rosterContent:SetWidth(w) end end)
    -- Style scrollbar
    if rosterScroll.ScrollBar then
        local sb = rosterScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.25); sb.ThumbTexture:SetWidth(3) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    R.rosterScroll = rosterScroll
    R.rosterContent = rosterContent

    -- ── §8e  Right Column: Guild Chat ──────────────────────────────────
    local chatPanel = CreateFrame("Frame", nil, p)
    chatPanel:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", rosterW + 1, 0)
    chatPanel:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", 0, 0)
    local chatBg = chatPanel:CreateTexture(nil, "BACKGROUND"); chatBg:SetAllPoints()
    chatBg:SetColorTexture(C.chatBg[1], C.chatBg[2], C.chatBg[3], C.chatBg[4])
    R.chatPanel = chatPanel; R.chatBg = chatBg

    -- Chat title
    local chatTitle = chatPanel:CreateFontString(nil, "OVERLAY")
    TrySetFont(chatTitle, BODY_FONT, 10, "OUTLINE")
    chatTitle:SetPoint("TOPLEFT", chatPanel, "TOPLEFT", CFG.PAD, -8)
    chatTitle:SetText("GUILD CHAT")
    chatTitle:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

    -- Chat scroll area
    local chatScroll = CreateFrame("ScrollFrame", nil, chatPanel, "UIPanelScrollFrameTemplate")
    chatScroll:SetPoint("TOPLEFT", chatPanel, "TOPLEFT", CFG.PAD, -24)
    chatScroll:SetPoint("BOTTOMRIGHT", chatPanel, "BOTTOMRIGHT", -20, CFG.CHAT_INPUT_H + 8)
    local chatContent = CreateFrame("Frame", nil, chatScroll)
    chatContent:SetWidth(1)
    chatScroll:SetScrollChild(chatContent)
    chatScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then chatContent:SetWidth(w) end end)
    if chatScroll.ScrollBar then
        local sb = chatScroll.ScrollBar
        if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.20); sb.ThumbTexture:SetWidth(3) end
        if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
        if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
    end
    R.chatScroll = chatScroll
    R.chatContent = chatContent

    -- Chat channel toggle (Guild / Officer)
    local chatChannel = "GUILD"  -- current channel state

    local chanBtn = CreateFrame("Button", nil, chatPanel, "BackdropTemplate")
    chanBtn:SetSize(58, CFG.CHAT_INPUT_H)
    chanBtn:SetPoint("BOTTOMLEFT", chatPanel, "BOTTOMLEFT", CFG.PAD, 8)
    chanBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    chanBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    chanBtn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.2)

    local chanFS = chanBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(chanFS, BODY_FONT, 9, "OUTLINE"); chanFS:SetPoint("CENTER")
    chanFS:SetText("Guild"); chanFS:SetTextColor(0.25, 0.85, 0.25)

    local function UpdateChanVisual()
        if chatChannel == "OFFICER" then
            chanFS:SetText("Officer")
            chanFS:SetTextColor(0.15, 0.55, 0.15)
            chanBtn:SetBackdropBorderColor(0.15, 0.55, 0.15, 0.3)
        else
            chanFS:SetText("Guild")
            chanFS:SetTextColor(0.25, 0.85, 0.25)
            chanBtn:SetBackdropBorderColor(0.25, 0.85, 0.25, 0.3)
        end
    end

    chanBtn:SetScript("OnClick", function()
        if chatChannel == "GUILD" then chatChannel = "OFFICER" else chatChannel = "GUILD" end
        UpdateChanVisual()
    end)
    chanBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        if chatChannel == "GUILD" then
            GameTooltip:SetText("Guild Chat", 0.25, 0.85, 0.25)
            GameTooltip:AddLine("Click to switch to Officer Chat", C.mutedText[1], C.mutedText[2], C.mutedText[3])
        else
            GameTooltip:SetText("Officer Chat", 0.15, 0.55, 0.15)
            GameTooltip:AddLine("Click to switch to Guild Chat", C.mutedText[1], C.mutedText[2], C.mutedText[3])
        end
        GameTooltip:Show()
    end)
    chanBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)
    R.chanBtn = chanBtn

    -- Chat input (shifted right to make room for channel toggle)
    local chatInput = CreateFrame("EditBox", nil, chatPanel, "BackdropTemplate")
    chatInput:SetHeight(CFG.CHAT_INPUT_H)
    chatInput:SetPoint("BOTTOMLEFT", chanBtn, "BOTTOMRIGHT", 4, 0)
    chatInput:SetPoint("BOTTOMRIGHT", chatPanel, "BOTTOMRIGHT", -CFG.PAD, 8)
    chatInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 8, right = 8, top = 4, bottom = 4 } })
    chatInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    chatInput:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
    TrySetFont(chatInput, BODY_FONT, 11, "")
    chatInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    chatInput:SetAutoFocus(false)
    chatInput:SetScript("OnEscapePressed", function(self) self:SetText(""); self:ClearFocus() end)
    chatInput:SetScript("OnEnterPressed", function(self)
        local text = self:GetText()
        if text and text ~= "" then
            pcall(SendChatMessage, text, chatChannel)
            self:SetText("")
        end
        self:ClearFocus()
    end)
    -- Placeholder
    local chatPlaceholder = chatInput:CreateFontString(nil, "OVERLAY")
    TrySetFont(chatPlaceholder, BODY_FONT, 11, "")
    chatPlaceholder:SetPoint("LEFT", chatInput, "LEFT", 8, 0)
    chatPlaceholder:SetText("Type a message...")
    chatPlaceholder:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.4)
    chatInput:SetScript("OnEditFocusGained", function()
        chatPlaceholder:Hide()
        chatInput:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
    end)
    chatInput:SetScript("OnEditFocusLost", function(self)
        if self:GetText() == "" then chatPlaceholder:Show() end
        chatInput:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
    end)
    R.chatInput = chatInput

    -- ── §8f  Right-Click Context Menu ──────────────────────────────────
    local ctxMenu = CreateFrame("Frame", nil, p, "BackdropTemplate")
    ctxMenu:SetSize(160, 120)
    ctxMenu:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    ctxMenu:SetBackdropColor(C.headerBg[1], C.headerBg[2], C.headerBg[3], 0.96)
    ctxMenu:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.35)
    ctxMenu:SetFrameLevel(p:GetFrameLevel() + 30)
    ctxMenu:Hide()
    ctxMenu._targetName = nil
    ctxMenu._targetIndex = nil
    R.ctxMenu = ctxMenu

    local CTX_OPTIONS = {
        { label = "Whisper",         action = "whisper" },
        { label = "Invite to Group", action = "invite" },
        { label = "View/Edit Note",  action = "note" },
        { label = "Copy Name",       action = "copy" },
    }
    local ctxYOfs = 6
    for _, opt in ipairs(CTX_OPTIONS) do
        local btn = CreateFrame("Button", nil, ctxMenu)
        btn:SetHeight(24)
        btn:SetPoint("TOPLEFT", ctxMenu, "TOPLEFT", 1, -ctxYOfs)
        btn:SetPoint("TOPRIGHT", ctxMenu, "TOPRIGHT", -1, -ctxYOfs)
        local hv = btn:CreateTexture(nil, "BACKGROUND"); hv:SetAllPoints()
        hv:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.08); hv:Hide()
        local fs = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 11, ""); fs:SetPoint("LEFT", btn, "LEFT", 10, 0)
        fs:SetText(opt.label); fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        btn:SetScript("OnEnter", function() hv:Show() end)
        btn:SetScript("OnLeave", function() hv:Hide() end)
        local capturedAction = opt.action
        btn:SetScript("OnClick", function()
            local name = ctxMenu._targetName
            local idx = ctxMenu._targetIndex
            ctxMenu:Hide()
            if not name then return end
            if capturedAction == "whisper" then
                -- Set the chat input to whisper mode targeting this player
                local chatFrame = DEFAULT_CHAT_FRAME or ChatFrame1
                if chatFrame and ChatFrame_SendTell then
                    pcall(ChatFrame_SendTell, name, chatFrame)
                elseif chatFrame and chatFrame.editBox then
                    chatFrame.editBox:SetText("/w " .. name .. " ")
                    pcall(ChatEdit_ActivateChat, chatFrame.editBox)
                end
            elseif capturedAction == "invite" then
                pcall(InviteUnit, name)
            elseif capturedAction == "note" then
                Panel.ShowNoteEditor(name, idx)
            elseif capturedAction == "copy" then
                -- Clipboard trick
                local eb = R.chatInput
                if eb then
                    eb:SetText(name); eb:HighlightText(); eb:SetFocus()
                end
            end
        end)
        ctxYOfs = ctxYOfs + 24
    end
    ctxMenu:SetHeight(ctxYOfs + 6)

    -- Fullscreen click-catcher to close context menu when clicking anywhere else
    local ctxOverlay = CreateFrame("Button", nil, p)
    ctxOverlay:SetAllPoints(UIParent)
    ctxOverlay:SetFrameLevel(ctxMenu:GetFrameLevel() - 1)
    ctxOverlay:RegisterForClicks("AnyUp")
    ctxOverlay:SetScript("OnClick", function()
        ctxMenu:Hide()
        ctxOverlay:Hide()
    end)
    ctxOverlay:Hide()
    R.ctxOverlay = ctxOverlay

    -- Show overlay when context menu opens, hide when it closes
    ctxMenu:HookScript("OnShow", function() ctxOverlay:Show() end)
    ctxMenu:HookScript("OnHide", function() ctxOverlay:Hide() end)

    return p
end

-- ============================================================================
-- §9  ROSTER ROW CREATION
-- ============================================================================
local function CreateRosterRow(parent, entry, yOfs, rosterW)
    local btn = CreateFrame("Button", nil, parent)
    btn:SetHeight(CFG.ROSTER_ROW_H)
    btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -yOfs)
    btn:SetPoint("TOPRIGHT", parent, "TOPRIGHT", 0, -yOfs)
    btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    local hoverBg = btn:CreateTexture(nil, "BACKGROUND")
    hoverBg:SetAllPoints(); hoverBg:SetColorTexture(C.hoverBg[1], C.hoverBg[2], C.hoverBg[3], C.hoverBg[4])
    hoverBg:Hide()

    -- Status dot
    local dot = btn:CreateTexture(nil, "OVERLAY")
    dot:SetSize(6, 6)
    dot:SetPoint("LEFT", btn, "LEFT", 4, 0)
    if entry.isOnline then
        dot:SetColorTexture(C.online[1], C.online[2], C.online[3], 1)
    elseif entry.isMobile then
        dot:SetColorTexture(0.4, 0.6, 0.9, 1)
    else
        dot:SetColorTexture(C.offline[1], C.offline[2], C.offline[3], 0.5)
    end

    local COL_LVL = CFG.COL_LVL
    local COL_RANK = CFG.COL_RANK
    local COL_ZONE = CFG.COL_ZONE
    local COL_LASTON = CFG.COL_LASTON
    local alpha = (entry.isOnline or entry.isMobile) and 1 or 0.45

    -- Name (class colored, flex width)
    local r, g, b = GetClassColor(entry.classFile)
    local nameFS = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(nameFS, BODY_FONT, 11, "")
    nameFS:SetPoint("LEFT", dot, "RIGHT", 4, 0)
    nameFS:SetPoint("RIGHT", btn, "RIGHT", -(COL_LVL + COL_RANK + COL_ZONE + COL_LASTON + CFG.PAD), 0)
    nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
    nameFS:SetText(entry.name)
    nameFS:SetTextColor(r, g, b, alpha)

    -- Level
    local lvlFS = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(lvlFS, BODY_FONT, 10, "")
    lvlFS:SetPoint("RIGHT", btn, "RIGHT", -(COL_RANK + COL_ZONE + COL_LASTON + CFG.PAD), 0)
    lvlFS:SetWidth(COL_LVL); lvlFS:SetJustifyH("CENTER"); lvlFS:SetWordWrap(false)
    lvlFS:SetText(entry.level)
    lvlFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3], alpha * 0.8)

    -- Rank
    local rankFS = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(rankFS, BODY_FONT, 9, "")
    rankFS:SetPoint("RIGHT", btn, "RIGHT", -(COL_ZONE + COL_LASTON + CFG.PAD), 0)
    rankFS:SetWidth(COL_RANK); rankFS:SetJustifyH("LEFT"); rankFS:SetWordWrap(false)
    rankFS:SetText(entry.rankName)
    rankFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], alpha * 0.8)

    -- Zone (online) or blank (offline)
    local zoneFS = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(zoneFS, BODY_FONT, 9, "")
    zoneFS:SetPoint("RIGHT", btn, "RIGHT", -(COL_LASTON + CFG.PAD), 0)
    zoneFS:SetWidth(COL_ZONE); zoneFS:SetJustifyH("LEFT"); zoneFS:SetWordWrap(false)
    zoneFS:SetText((entry.isOnline or entry.isMobile) and entry.zone or "")
    zoneFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], alpha * 0.6)

    -- Last column (changes based on filter mode)
    local lastFS = btn:CreateFontString(nil, "OVERLAY")
    TrySetFont(lastFS, BODY_FONT, 9, "")
    lastFS:SetPoint("RIGHT", btn, "RIGHT", -CFG.PAD, 0)
    lastFS:SetWidth(COL_LASTON); lastFS:SetJustifyH("RIGHT"); lastFS:SetWordWrap(false)

    local filterMode = Panel._state.filterMode or "default"
    if filterMode == "achievePts" then
        -- Achievement Points
        local pts = entry.achievementPts or 0
        if pts > 0 then
            lastFS:SetText(FormatNumber(pts))
            lastFS:SetTextColor(1, 0.82, 0, alpha * 0.9)
        else
            lastFS:SetText("—")
            lastFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.3)
        end
    elseif filterMode == "mythicPlus" then
        -- M+ Rating (Blizzard API — only available for nearby/grouped members)
        local score = entry.mythicPlusRating or 0
        if score == 0 and (entry.isOnline or entry.isMobile) and entry.guid and entry.guid ~= "" then
            if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary and PlayerLocation then
                local playerLoc = PlayerLocation:CreateFromGUID(entry.guid)
                if playerLoc then
                    local okS, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, playerLoc)
                    if okS and summary and summary.currentSeasonScore and summary.currentSeasonScore > 0 then
                        score = summary.currentSeasonScore
                        entry.mythicPlusRating = score
                    end
                end
            end
        end
        if score > 0 then
            local sr, sg, sb = 0.7, 0.7, 0.7
            if C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor then
                local okC, color = pcall(C_ChallengeMode.GetDungeonScoreRarityColor, score)
                if okC and color and color.r then sr, sg, sb = color.r, color.g, color.b end
            end
            lastFS:SetText(FormatNumber(score))
            lastFS:SetTextColor(sr, sg, sb, alpha)
        else
            lastFS:SetText("—")
            lastFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.3)
        end
    elseif filterMode == "mpiScore" then
        -- MPI Score (from personal observations + community data)
        local mpiScore = 0
        if _G.MidnightPI then
            local PI = _G.MidnightPI
            local prof = PI.GetProfileByName and PI.GetProfileByName(entry.name)
            if not prof and PI.CommunityLookup then
                local realm = entry.fullName and entry.fullName:match("%-(.+)$") or (GetRealmName and GetRealmName() or "")
                prof = PI.CommunityLookup(entry.name, realm)
            end
            if prof and prof.avgMPI then mpiScore = prof.avgMPI end
        end
        if mpiScore > 0 then
            local sr, sg, sb = 0.5, 0.5, 0.5
            if _G.MidnightPI and _G.MidnightPI.GetScoreTier then
                local _, r2, g2, b2 = _G.MidnightPI.GetScoreTier(mpiScore)
                sr, sg, sb = r2, g2, b2
            end
            lastFS:SetText(tostring(mpiScore))
            lastFS:SetTextColor(sr, sg, sb, alpha)
        else
            lastFS:SetText("—")
            lastFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.3)
        end
    else
        -- Default: Last Online
        if entry.isOnline or entry.isMobile then
            lastFS:SetText("|cff" .. string.format("%02x%02x%02x", C.online[1]*255, C.online[2]*255, C.online[3]*255) .. "Now|r")
        else
            lastFS:SetText(entry.lastOnline or "")
        end
        lastFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.6)
    end

    btn:SetScript("OnEnter", function(self)
        hoverBg:Show()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(entry.name, r, g, b)
        GameTooltip:AddLine("Level " .. entry.level .. " " .. (entry.className or ""), 1, 1, 1)
        GameTooltip:AddLine(entry.rankName, C.accent[1], C.accent[2], C.accent[3])
        if (entry.isOnline or entry.isMobile) and entry.zone ~= "" then
            GameTooltip:AddLine(entry.zone, C.mutedText[1], C.mutedText[2], C.mutedText[3])
        elseif entry.lastOnline and entry.lastOnline ~= "" then
            GameTooltip:AddLine("Last online: " .. entry.lastOnline .. " ago", C.offline[1], C.offline[2], C.offline[3])
        end
        -- Achievement points
        if entry.achievementPts and entry.achievementPts > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Achievement Points: " .. FormatNumber(entry.achievementPts), 1, 0.82, 0)
        end
        -- Public note
        if entry.publicNote and entry.publicNote ~= "" then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaaaaNote:|r " .. entry.publicNote, C.bodyText[1], C.bodyText[2], C.bodyText[3], true)
        end
        -- Officer note
        if entry.officerNote and entry.officerNote ~= "" then
            GameTooltip:AddLine("|cffaaaaaaOfficer:|r " .. entry.officerNote, 0.65, 0.50, 0.80, true)
        end
        -- Mythic+ Rating (try to get if online)
        if (entry.isOnline or entry.isMobile) and entry.guid and entry.guid ~= "" then
            if C_PlayerInfo and C_PlayerInfo.GetPlayerMythicPlusRatingSummary then
                local playerLoc = PlayerLocation:CreateFromGUID(entry.guid)
                if playerLoc then
                    local ok2, summary = pcall(C_PlayerInfo.GetPlayerMythicPlusRatingSummary, playerLoc)
                    if ok2 and summary and summary.currentSeasonScore and summary.currentSeasonScore > 0 then
                        local score = summary.currentSeasonScore
                        local sr, sg, sb = 0.7, 0.7, 0.7
                        if C_ChallengeMode and C_ChallengeMode.GetDungeonScoreRarityColor then
                            local okC, color = pcall(C_ChallengeMode.GetDungeonScoreRarityColor, score)
                            if okC and color and color.r then sr, sg, sb = color.r, color.g, color.b end
                        end
                        GameTooltip:AddLine("M+ Rating: " .. FormatNumber(score), sr, sg, sb)
                    end
                end
            end
        end
        GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function() hoverBg:Hide(); GameTooltip:Hide() end)

    local capturedName = entry.fullName
    local capturedIdx = entry.rosterIndex
    btn:SetScript("OnClick", function(_, mouseBtn)
        if mouseBtn == "RightButton" then
            local R = Panel._refs
            if R.ctxMenu then
                R.ctxMenu._targetName = capturedName
                R.ctxMenu._targetIndex = capturedIdx
                R.ctxMenu:ClearAllPoints()
                local cx, cy = GetCursorPosition()
                local scale = UIParent:GetEffectiveScale()
                R.ctxMenu:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
                R.ctxMenu:Show()
            end
        end
    end)

    btn:Show()
    return btn
end

-- ============================================================================
-- §10  CHAT MESSAGE RENDERING
-- ============================================================================
function Panel.UpdateChat()
    local R = Panel._refs
    if not R.chatContent then return end

    -- Clear
    local children = { R.chatContent:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { R.chatContent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    -- Pull from MessengerDB — fields: msg, author, timestamp, nameColorDefault
    local messages = {}
    if _G.MessengerDB and _G.MessengerDB.History and _G.MessengerDB.History["Guild"] then
        local hist = _G.MessengerDB.History["Guild"]
        if hist.messages then
            local start = math.max(1, #hist.messages - 99)
            for i = start, #hist.messages do
                messages[#messages + 1] = hist.messages[i]
            end
        end
    end

    -- Build class lookup cache from guild roster (once per UpdateChat call)
    local classCache = {}
    if _G.MessengerDB and _G.MessengerDB.ContactClasses then
        for name, cf in pairs(_G.MessengerDB.ContactClasses) do
            classCache[name] = cf
        end
    end
    local numMembers = SafeCall(GetNumGuildMembers) or 0
    for gi = 1, numMembers do
        local gName, _, _, _, _, _, _, _, _, _, gClassFile = SafeCall(GetGuildRosterInfo, gi)
        if gName and gClassFile then
            local gShort = gName:match("^([^%-]+)") or gName
            if not classCache[gShort] then
                classCache[gShort] = gClassFile
            end
        end
    end

    -- Resolve content width upfront; fall back to scroll frame width if not yet laid out
    local resolvedW = R.chatContent:GetWidth()
    if not resolvedW or resolvedW <= 10 then
        resolvedW = R.chatScroll and R.chatScroll:GetWidth() or 0
    end

    local yOfs = 0
    local MSG_H = 18
    local MSG_GAP = 4
    for _, msg in ipairs(messages) do
        local text = msg.msg or msg.text or ""
        local sender = msg.author or msg.sender or ""
        local timestamp = msg.timestamp or ""
        local nameColor = msg.nameColorDefault or "aaddaa"

        -- Override name color with class color
        local shortName = sender:match("^([^%-]+)") or sender
        local classFile = classCache[shortName]
        if classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile] then
            local cc = RAID_CLASS_COLORS[classFile]
            nameColor = string.format("%02x%02x%02x", cc.r * 255, cc.g * 255, cc.b * 255)
        end

        if type(timestamp) == "number" then
            timestamp = date("%H:%M", timestamp)
        end

        -- Detect M+ LFG messages
        local isMPlus, dungeonName, keyLevel = DetectMPlusMessage(text)

        -- Use a MessageFrame-style button for hyperlink support
        local msgBtn = CreateFrame("Frame", nil, R.chatContent)
        msgBtn:SetPoint("TOPLEFT", R.chatContent, "TOPLEFT", 0, -yOfs)
        msgBtn:SetPoint("RIGHT", R.chatContent, "RIGHT", -4, 0)
        msgBtn:SetHeight(MSG_H)

        -- M+ highlight background
        if isMPlus then
            local mpBg = msgBtn:CreateTexture(nil, "BACKGROUND")
            mpBg:SetAllPoints()
            mpBg:SetColorTexture(0.00, 0.40, 0.55, 0.15)
            -- Left accent bar
            local mpBar = msgBtn:CreateTexture(nil, "BACKGROUND", nil, 1)
            mpBar:SetWidth(2)
            mpBar:SetPoint("TOPLEFT", msgBtn, "TOPLEFT", 0, 0)
            mpBar:SetPoint("BOTTOMLEFT", msgBtn, "BOTTOMLEFT", 0, 0)
            mpBar:SetColorTexture(0.00, 0.78, 1.00, 0.6)
        end
        if msgBtn.SetHyperlinksEnabled then
            msgBtn:SetHyperlinksEnabled(true)
            msgBtn:SetScript("OnHyperlinkClick", function(self, link, text, button)
                local linkType, linkData = link:match("^(%a+):(.+)")
                if linkType == "player" then
                    local whisperTarget = linkData:match("^([^:]+)") or linkData
                    -- Try multiple approaches to open whisper
                    -- 1. Set Messenger's chat input to whisper mode
                    local R2 = Panel._refs
                    if R2.chatInput then
                        R2.chatInput:SetText("/w " .. whisperTarget .. " ")
                        R2.chatInput:SetFocus()
                        R2.chatInput:SetCursorPosition(R2.chatInput:GetNumLetters())
                    end
                    -- 2. Also try the default chat system as fallback
                    if ChatFrame_SendTell then
                        pcall(ChatFrame_SendTell, whisperTarget)
                    end
                    return
                end
                pcall(ChatFrame_OnHyperlinkShow, DEFAULT_CHAT_FRAME or ChatFrame1, link, text, button)
            end)
            msgBtn:SetScript("OnHyperlinkEnter", function(self, link)
                GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
                pcall(GameTooltip.SetHyperlink, GameTooltip, link)
                GameTooltip:Show()
            end)
            msgBtn:SetScript("OnHyperlinkLeave", function() GameTooltip:Hide() end)
        end

        local fs = msgBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(fs, BODY_FONT, 11, "")
        fs:SetPoint("TOPLEFT", msgBtn, "TOPLEFT", 0, 0)
        fs:SetJustifyH("LEFT")
        fs:SetJustifyV("TOP")
        fs:SetWordWrap(true)
        fs:SetSpacing(4)

        -- Build full name with realm for whisper target
        local fullSender = sender
        if sender ~= "" and not sender:find("-") then
            local playerRealm = SafeCall(GetRealmName) or ""
            if playerRealm ~= "" then
                fullSender = sender .. "-" .. playerRealm:gsub("%s", "")
            end
        end

        local displayText = ""
        if timestamp ~= "" then
            displayText = "|cff666666" .. timestamp .. "|r  "
        end
        if sender ~= "" then
            local shortSender = sender:match("^([^%-]+)") or sender
            -- Make name a clickable player link (click to whisper)
            displayText = displayText .. "|Hplayer:" .. fullSender .. "|h|cff" .. nameColor .. shortSender .. "|r|h: "
        end
        displayText = displayText .. text

        -- Append M+ dungeon tag if detected
        if isMPlus and dungeonName then
            displayText = displayText .. "  |cff00c8ff[" .. dungeonName
            if keyLevel then displayText = displayText .. " +" .. keyLevel end
            displayText = displayText .. "]|r"
        elseif isMPlus and keyLevel then
            displayText = displayText .. "  |cff00c8ff[M+ +" .. keyLevel .. "]|r"
        end

        -- Set explicit width so GetStringHeight() can calculate word-wrap correctly
        if resolvedW > 10 then
            fs:SetWidth(resolvedW - 4)
        end

        fs:SetText(displayText)
        fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        fs:Show()
        msgBtn:Show()

        local textH = fs:GetStringHeight() or MSG_H
        msgBtn:SetHeight(math.max(MSG_H, textH))
        yOfs = yOfs + math.max(MSG_H, textH) + MSG_GAP
    end

    R.chatContent:SetHeight(math.max(yOfs + 10, 1))

    -- Auto-scroll to bottom
    C_Timer.After(0.05, function()
        if R.chatScroll then
            local maxScroll = R.chatScroll:GetVerticalScrollRange()
            R.chatScroll:SetVerticalScroll(maxScroll)
        end
    end)
end

-- ============================================================================
-- §11  SORT & FILTER
-- ============================================================================
function Panel.UpdateSortHeaders()
    local R = Panel._refs
    if not R.sortBtns then return end
    for key, btn in pairs(R.sortBtns) do
        if key == Panel._state.sortColumn then
            btn._fs:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
            local arrow = Panel._state.sortAsc and " v" or " ^"
            btn._fs:SetText(btn._key:sub(1,1):upper() .. btn._key:sub(2) .. arrow)
        else
            btn._fs:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            -- Restore original label
            local filterMode = Panel._state.filterMode or "default"
            local lastLabel = "Last"
            if filterMode == "achievePts" then lastLabel = "Ach"
            elseif filterMode == "mythicPlus" then lastLabel = "M+"
            elseif filterMode == "mpiScore" then lastLabel = "MPI"
            end
            local labels = { name="Name", level="Lvl", rank="Rank", zone="Zone", lastOn=lastLabel }
            if labels[key] then btn._fs:SetText(labels[key]) end
        end
    end
end

-- ============================================================================
-- §12  UPDATE FUNCTIONS
-- ============================================================================

-- "No Guild" full-panel overlay — lazy-created, shown/hidden by UpdateGuildInfo
local noGuildOverlay = nil
local function EnsureNoGuildOverlay()
    if noGuildOverlay then return noGuildOverlay end
    local R = Panel._refs
    if not R or not R.panel then return nil end

    -- Class-themed background covering the entire content area below the header
    local classArtifactBGs = {
        DEATHKNIGHT = "Artifacts-DeathKnightFrost-BG",
        DEMONHUNTER = "Artifacts-DemonHunter-BG",
        DRUID       = "Artifacts-Druid-BG",
        HUNTER      = "Artifacts-Hunter-BG",
        MAGE        = "Artifacts-MageArcane-BG",
        MONK        = "Artifacts-Monk-BG",
        PALADIN     = "Artifacts-Paladin-BG",
        PRIEST      = "Artifacts-Priest-BG",
        ROGUE       = "Artifacts-Rogue-BG",
        SHAMAN      = "Artifacts-Shaman-BG",
        WARLOCK     = "Artifacts-Warlock-BG",
        WARRIOR     = "Artifacts-Warrior-BG",
        EVOKER      = "Artifacts-MageArcane-BG",
    }
    local _, playerClass = UnitClass("player")
    -- Shadow Priest uses a unique background
    if playerClass == "PRIEST" then
        local specIndex = GetSpecialization and GetSpecialization()
        if specIndex then
            local specID = GetSpecializationInfo and GetSpecializationInfo(specIndex)
            if specID == 258 then -- Shadow
                classArtifactBGs["PRIEST"] = "Artifacts-PriestShadow-BG"
            end
        end
    end

    local scrim = CreateFrame("Frame", nil, R.panel)
    scrim:SetPoint("TOPLEFT", R.panel, "TOPLEFT", 0, -CFG.HEADER_H)
    scrim:SetPoint("BOTTOMRIGHT", R.panel, "BOTTOMRIGHT", 0, 0)
    scrim:SetFrameLevel(R.panel:GetFrameLevel() + 20)

    -- Class artifact background (subdued)
    local artBG = classArtifactBGs[playerClass]
    if artBG then
        local classBg = scrim:CreateTexture(nil, "BACKGROUND", nil, 0)
        classBg:SetAllPoints()
        classBg:SetAtlas(artBG, false)
        classBg:SetAlpha(0.3)
    end

    -- Dark overlay on top to keep the background subtle
    local darkOverlay = scrim:CreateTexture(nil, "BACKGROUND", nil, 1)
    darkOverlay:SetAllPoints()
    darkOverlay:SetColorTexture(0.01, 0.01, 0.02, 0.65)

    -- Centered card
    local card = CreateFrame("Frame", nil, scrim, "BackdropTemplate")
    card:SetSize(340, 180)
    card:SetPoint("CENTER", scrim, "CENTER", 0, 20)
    card:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    card:SetBackdropColor(0.04, 0.04, 0.06, 0.95)
    card:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.3)

    -- Drop shadow on card
    for i = 1, 5 do
        local s = card:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 2
        s:SetColorTexture(0, 0, 0, 0.18 - (i * 0.03))
        s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
    end

    -- Top accent bar
    local topBar = card:CreateTexture(nil, "OVERLAY", nil, 4)
    topBar:SetHeight(2); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
    topBar:SetTexture(W8)
    if topBar.SetGradient and CreateColor then
        topBar:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.8),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.1))
    end

    -- Icon
    local icon = card:CreateTexture(nil, "ARTWORK")
    icon:SetSize(40, 40)
    icon:SetPoint("TOP", card, "TOP", 0, -22)
    icon:SetTexture("Interface\\GuildFrame\\GuildLogo-NoLogo")
    icon:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.6)

    -- Title
    local title = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", icon, "BOTTOM", 0, -10)
    title:SetText("You are not in a Guild")
    title:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])

    -- Subtitle
    local sub = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sub:SetPoint("TOP", title, "BOTTOM", 0, -6)
    sub:SetText("Find a community to join!")
    sub:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.7)

    -- Guild Finder button
    local btn = CreateFrame("Button", nil, card, "BackdropTemplate")
    btn:SetSize(180, 32)
    btn:SetPoint("TOP", sub, "BOTTOM", 0, -16)
    btn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    btn:SetBackdropColor(C.accent[1] * 0.25, C.accent[2] * 0.25, C.accent[3] * 0.25, 0.9)
    btn:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.5)

    local btnText = btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    btnText:SetPoint("CENTER")
    btnText:SetText("Open Guild Finder")
    btnText:SetTextColor(C.accent[1], C.accent[2], C.accent[3])

    btn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(C.accent[1] * 0.4, C.accent[2] * 0.4, C.accent[3] * 0.4, 0.9)
        self:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.8)
    end)
    btn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(C.accent[1] * 0.25, C.accent[2] * 0.25, C.accent[3] * 0.25, 0.9)
        self:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.5)
    end)
    btn:SetScript("OnClick", function()
        -- Close MidnightUI guild panel first
        Panel.Hide()
        -- Open the Blizzard Communities frame to the Guild Finder tab
        if ToggleGuildFinder then
            ToggleGuildFinder()
        elseif Communities_LoadUI and CommunitiesFrame then
            Communities_LoadUI()
            CommunitiesFrame:Show()
            if CommunitiesFrame.GuildFinderFrame then
                CommunitiesFrame:SelectSettingsCategory(CommunitiesFrame.GuildFinderFrame)
            end
        elseif ToggleGuildFrame then
            ToggleGuildFrame()
        end
    end)

    -- Fade in
    local fadeIn = scrim:CreateAnimationGroup()
    local fi = fadeIn:CreateAnimation("Alpha"); fi:SetFromAlpha(0); fi:SetToAlpha(1); fi:SetDuration(0.25); fi:SetSmoothing("OUT")
    scrim._fadeIn = fadeIn

    scrim:Hide()
    noGuildOverlay = scrim
    return noGuildOverlay
end

function Panel.UpdateGuildInfo()
    local R = Panel._refs
    local data = GetGuildData()
    if not data then
        if R.headerTitle then R.headerTitle:SetText("No Guild") end
        if R.heroGuildName then R.heroGuildName:SetText("") end
        if R.motdFS then R.motdFS:SetText("") end
        if R.infoFS then R.infoFS:SetText("") end
        if R.tabardModel then R.tabardModel:Hide() end
        if R.emblemIcon then R.emblemIcon:Hide() end
        -- Hide content panels and show "no guild" overlay
        if R.hero then R.hero:Hide() end
        if R.rosterPanel then R.rosterPanel:Hide() end
        if R.chatPanel then R.chatPanel:Hide() end
        local overlay = EnsureNoGuildOverlay()
        if overlay then
            overlay:Show()
            if overlay._fadeIn then overlay._fadeIn:Play() end
        end
        return
    end

    -- Restore content panels and hide no-guild overlay when in a guild
    if noGuildOverlay and noGuildOverlay:IsShown() then noGuildOverlay:Hide() end
    if R.hero and not R.hero:IsShown() then R.hero:Show() end
    if R.rosterPanel and not R.rosterPanel:IsShown() then R.rosterPanel:Show() end
    if R.chatPanel and not R.chatPanel:IsShown() then R.chatPanel:Show() end

    -- Header
    if R.headerTitle then
        local titleText = data.name
        if data.realm and data.realm ~= "" then titleText = titleText .. "  \194\183  " .. data.realm end
        R.headerTitle:SetText(titleText)
    end

    -- Hero guild name
    if R.heroGuildName then R.heroGuildName:SetText(data.name) end

    -- MOTD + Guild Info — update text on pre-built static cards (no flickering)
    if R.motdFS then
        if data.motd and data.motd ~= "" then
            R.motdFS:SetText(data.motd)
            R.motdFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
        else
            R.motdFS:SetText("No message of the day")
            R.motdFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
        end
    end

    local guildInfoText = SafeCall(GetGuildInfoText) or ""
    if R.gInfoFS and R.gInfoCard then
        if guildInfoText ~= "" then
            R.gInfoFS:SetText(guildInfoText)
            R.gInfoCard:Show()
        else
            R.gInfoFS:SetText("")
            R.gInfoCard:Hide()
        end
    end

    -- Populate challenges if expanded
    if Panel._state.challengesExpanded then
        Panel.UpdateGuildChallenges()
    end

    -- Size all info cards
    Panel.SizeInfoCards()

    -- Stats
    if R.infoFS then
        local info = FormatNumber(data.totalMembers) .. " Members"
            .. "  |cff888888\194\183|r  "
            .. "|cff" .. string.format("%02x%02x%02x", C.online[1]*255, C.online[2]*255, C.online[3]*255)
            .. FormatNumber(data.onlineMembers) .. " Online|r"
            .. "  |cff888888\194\183|r  "
            .. "Rank: |cff" .. string.format("%02x%02x%02x", C.accent[1]*255, C.accent[2]*255, C.accent[3]*255)
            .. data.rankName .. "|r"
        R.infoFS:SetText(info)
    end

    -- Guild emblem display — only set up the model once to avoid animation resets
    local emblemShown = false

    -- Approach 1: TabardModel showing the guild tabard
    if R.tabardModel then
        if not R._tabardModelReady then
            local modelOk = pcall(function()
                R.tabardModel:SetUnit("player")
                R.tabardModel:SetPortraitZoom(1)
                R.tabardModel:SetCamDistanceScale(0.8)
                R.tabardModel:SetPosition(0, 0, 0)
                R.tabardModel:SetFacing(0)
                R.tabardModel:SetAlpha(1)
            end)
            if modelOk then
                R._tabardModelReady = true
            end
        end
        if R._tabardModelReady then
            R.tabardModel:Show()
            if R.emblemIcon then R.emblemIcon:Hide() end
            emblemShown = true
        end
    end

    -- Approach 2: C_GuildInfo.GetGuildTabardInfo (modern API)
    if not emblemShown and R.emblemIcon then
        if C_GuildInfo and C_GuildInfo.GetGuildTabardInfo then
            local tabardInfo = SafeCall(C_GuildInfo.GetGuildTabardInfo, "player")
            if tabardInfo and tabardInfo.emblemFileID then
                R.emblemIcon:SetTexture(tabardInfo.emblemFileID)
                R.emblemIcon:SetVertexColor(1, 1, 1, 1)
                R.emblemIcon:SetTexCoord(0, 1, 0, 1)
                R.emblemIcon:Show()
                if R.tabardModel then R.tabardModel:Hide() end
                emblemShown = true
            end
        end
    end

    -- Approach 3: GetGuildTabardFiles (legacy)
    if not emblemShown and R.emblemIcon then
        if GetGuildTabardFiles then
            local _, _, tabardEmblem = SafeCall(GetGuildTabardFiles)
            if tabardEmblem and type(tabardEmblem) == "number" and tabardEmblem > 0 then
                R.emblemIcon:SetTexture(tabardEmblem)
                R.emblemIcon:SetVertexColor(1, 1, 1, 1)
                R.emblemIcon:SetTexCoord(0, 1, 0, 1)
                R.emblemIcon:Show()
                if R.tabardModel then R.tabardModel:Hide() end
                emblemShown = true
            end
        end
    end

    -- Fallback: generic guild icon
    if not emblemShown and R.emblemIcon then
        R.emblemIcon:SetTexture("Interface\\GuildFrame\\GuildLogo-NoLogo")
        R.emblemIcon:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.7)
        R.emblemIcon:SetTexCoord(0, 1, 0, 1)
        R.emblemIcon:Show()
        if R.tabardModel then R.tabardModel:Hide() end
    end
end

function Panel.UpdateRoster()
    local R = Panel._refs
    if not R.rosterContent then return end

    -- Clear
    local children = { R.rosterContent:GetChildren() }
    for _, child in ipairs(children) do child:Hide() end
    local regions = { R.rosterContent:GetRegions() }
    for _, region in ipairs(regions) do region:Hide() end

    local online, offline = CollectRoster(
        Panel._state.searchText,
        Panel._state.sortColumn,
        Panel._state.sortAsc
    )

    local yOfs = 0
    local rosterW = R.rosterPanel and R.rosterPanel:GetWidth() or (CFG.WIDTH * CFG.ROSTER_PCT)

    -- ── Online Section Header ──
    local onlineHdr = CreateFrame("Button", nil, R.rosterContent)
    onlineHdr:EnableMouse(true); onlineHdr:RegisterForClicks("LeftButtonUp")
    onlineHdr:SetHeight(CFG.SECTION_HDR_H)
    onlineHdr:SetPoint("TOPLEFT", R.rosterContent, "TOPLEFT", 0, -yOfs)
    onlineHdr:SetPoint("TOPRIGHT", R.rosterContent, "TOPRIGHT", 0, -yOfs)
    local onBg = onlineHdr:CreateTexture(nil, "BACKGROUND")
    onBg:SetAllPoints(); onBg:SetColorTexture(C.online[1], C.online[2], C.online[3], 0.06)
    local onChevron = onlineHdr:CreateTexture(nil, "OVERLAY")
    onChevron:SetSize(10, 10); onChevron:SetPoint("LEFT", onlineHdr, "LEFT", 6, 0)
    onChevron:SetAtlas("common-dropdown-icon-back")
    onChevron:SetRotation(Panel._state.onlineExpanded and (-math.pi / 2) or math.pi)
    onChevron:SetVertexColor(C.online[1], C.online[2], C.online[3])
    local onLabel = onlineHdr:CreateFontString(nil, "OVERLAY")
    TrySetFont(onLabel, BODY_FONT, 10, "OUTLINE")
    onLabel:SetPoint("LEFT", onChevron, "RIGHT", 4, 0)
    onLabel:SetText("ONLINE (" .. #online .. ")")
    onLabel:SetTextColor(C.online[1], C.online[2], C.online[3])
    onlineHdr:SetScript("OnClick", function()
        Panel._state.onlineExpanded = not Panel._state.onlineExpanded
        Panel.UpdateRoster()
    end)
    onlineHdr:Show()
    yOfs = yOfs + CFG.SECTION_HDR_H

    if Panel._state.onlineExpanded then
        for _, entry in ipairs(online) do
            CreateRosterRow(R.rosterContent, entry, yOfs, rosterW)
            yOfs = yOfs + CFG.ROSTER_ROW_H
        end
    end

    -- ── Offline Section Header ──
    local offlineHdr = CreateFrame("Button", nil, R.rosterContent)
    offlineHdr:EnableMouse(true); offlineHdr:RegisterForClicks("LeftButtonUp")
    offlineHdr:SetHeight(CFG.SECTION_HDR_H)
    offlineHdr:SetPoint("TOPLEFT", R.rosterContent, "TOPLEFT", 0, -yOfs)
    offlineHdr:SetPoint("TOPRIGHT", R.rosterContent, "TOPRIGHT", 0, -yOfs)
    local offBg = offlineHdr:CreateTexture(nil, "BACKGROUND")
    offBg:SetAllPoints(); offBg:SetColorTexture(C.offline[1], C.offline[2], C.offline[3], 0.04)
    local offChevron = offlineHdr:CreateTexture(nil, "OVERLAY")
    offChevron:SetSize(10, 10); offChevron:SetPoint("LEFT", offlineHdr, "LEFT", 6, 0)
    offChevron:SetAtlas("common-dropdown-icon-back")
    offChevron:SetRotation(Panel._state.offlineExpanded and (-math.pi / 2) or math.pi)
    offChevron:SetVertexColor(C.offline[1], C.offline[2], C.offline[3])
    local offLabel = offlineHdr:CreateFontString(nil, "OVERLAY")
    TrySetFont(offLabel, BODY_FONT, 10, "OUTLINE")
    offLabel:SetPoint("LEFT", offChevron, "RIGHT", 4, 0)
    offLabel:SetText("OFFLINE (" .. #offline .. ")")
    offLabel:SetTextColor(C.offline[1], C.offline[2], C.offline[3])
    offlineHdr:SetScript("OnClick", function()
        Panel._state.offlineExpanded = not Panel._state.offlineExpanded
        Panel.UpdateRoster()
    end)
    offlineHdr:Show()
    yOfs = yOfs + CFG.SECTION_HDR_H

    if Panel._state.offlineExpanded then
        for _, entry in ipairs(offline) do
            CreateRosterRow(R.rosterContent, entry, yOfs, rosterW)
            yOfs = yOfs + CFG.ROSTER_ROW_H
        end
    end

    R.rosterContent:SetHeight(math.max(yOfs + 10, 1))
end

-- Note editor popup
function Panel.ShowNoteEditor(name, rosterIndex)
    local R = Panel._refs
    if not R.panel then return end
    -- Simple popup with EditBox
    if R.noteEditor then R.noteEditor:Hide() end

    local ne = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
    ne:SetSize(300, 100)
    ne:SetPoint("CENTER", R.panel, "CENTER", 0, 0)
    ne:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    ne:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
    ne:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.4)
    ne:SetFrameLevel(R.panel:GetFrameLevel() + 35)
    R.noteEditor = ne

    local neTitle = ne:CreateFontString(nil, "OVERLAY")
    TrySetFont(neTitle, BODY_FONT, 10, "OUTLINE")
    neTitle:SetPoint("TOP", ne, "TOP", 0, -8)
    local shortName = name:match("^([^%-]+)") or name
    neTitle:SetText("NOTE: " .. shortName)
    neTitle:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

    local neInput = CreateFrame("EditBox", nil, ne, "BackdropTemplate")
    neInput:SetHeight(28)
    neInput:SetPoint("TOPLEFT", ne, "TOPLEFT", 12, -28)
    neInput:SetPoint("TOPRIGHT", ne, "TOPRIGHT", -12, -28)
    neInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 6, right = 6, top = 4, bottom = 4 } })
    neInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    neInput:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
    TrySetFont(neInput, BODY_FONT, 11, "")
    neInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    neInput:SetAutoFocus(true)
    -- Load current note
    if rosterIndex then
        local _, _, _, _, _, _, publicNote = SafeCall(GetGuildRosterInfo, rosterIndex)
        neInput:SetText(publicNote or "")
    end
    neInput:SetScript("OnEscapePressed", function() ne:Hide() end)
    neInput:SetScript("OnEnterPressed", function(self)
        if rosterIndex and GuildRosterSetPublicNote then
            pcall(GuildRosterSetPublicNote, rosterIndex, self:GetText() or "")
        end
        ne:Hide()
    end)

    -- Save/Cancel buttons
    local saveBtn = CreateFrame("Button", nil, ne)
    saveBtn:SetSize(60, 22); saveBtn:SetPoint("BOTTOMRIGHT", ne, "BOTTOMRIGHT", -12, 8)
    local saveFS = saveBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(saveFS, BODY_FONT, 11, ""); saveFS:SetPoint("CENTER"); saveFS:SetText("Save")
    saveFS:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    saveBtn:SetScript("OnClick", function()
        if rosterIndex and GuildRosterSetPublicNote then
            pcall(GuildRosterSetPublicNote, rosterIndex, neInput:GetText() or "")
        end
        ne:Hide()
    end)

    local cancelBtn = CreateFrame("Button", nil, ne)
    cancelBtn:SetSize(50, 22); cancelBtn:SetPoint("RIGHT", saveBtn, "LEFT", -8, 0)
    local cancelFS = cancelBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(cancelFS, BODY_FONT, 11, ""); cancelFS:SetPoint("CENTER"); cancelFS:SetText("Cancel")
    cancelFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
    cancelBtn:SetScript("OnClick", function() ne:Hide() end)

    ne:Show()
end

-- ============================================================================
-- §13  SHOW / HIDE / TOGGLE
-- ============================================================================
function Panel.Show()
    LoadTheme()
    local p = Panel.EnsurePanel()
    if not p then return end

    -- Close other MidnightUI panels to prevent overlap
    local gfHide = _G.MidnightUI_GroupFinder_Hide
    if gfHide then gfHide() end
    local charFrame = _G["MidnightUI_CharacterPanel"]
    if charFrame and charFrame:IsShown() then charFrame:Hide() end

    Panel._state.panelOpen = true
    p:Show()
    if p._fadeIn then p._fadeIn:Play() end

    -- Request roster data from server (async — will trigger GUILD_ROSTER_UPDATE)
    SafeCall(GuildRoster)

    -- Show/hide recruitment button based on officer status (uses GuildRecruit's permission check)
    local R = Panel._refs
    if R.recruitBtn and R.perksBtn then
        local isOfficer = false
        local api = _G.MidnightUI_GuildRecruitAPI
        if api and api.CanManageRecruitment then
            isOfficer = api.CanManageRecruitment()
        end

        if isOfficer then
            R.recruitBtn:Show()
            -- Re-anchor gear button to the recruit button
            if R.gearBtn then
                R.gearBtn:ClearAllPoints()
                R.gearBtn:SetPoint("RIGHT", R.recruitBtn, "LEFT", -6, 0)
            end
            -- Set refs for GuildRecruit module
            if api then
                api._headerBadgeDot = R.recruitBadgeDot
                api._headerBadgeCount = R.recruitBadgeCount
                api.RefreshBadge()
            end
        else
            R.recruitBtn:Hide()
            -- Anchor gear button back to perks button
            if R.gearBtn then
                R.gearBtn:ClearAllPoints()
                R.gearBtn:SetPoint("RIGHT", R.perksBtn, "LEFT", -6, 0)
            end
        end
    end

    -- Show what we have immediately
    Panel.UpdateGuildInfo()
    Panel.UpdateSortHeaders()
    Panel.UpdateRoster()
    Panel.UpdateChat()
end

function Panel.ApplyTheme()
    local R = Panel._refs
    if not R.panel then return end

    -- Main frame
    R.panel:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], C.frameBg[4])
    R.panel:SetBackdropBorderColor(C.borderTint[1], C.borderTint[2], C.borderTint[3], C.borderTint[4])

    -- Header
    if R.hdrBg then R.hdrBg:SetColorTexture(C.headerBg[1], C.headerBg[2], C.headerBg[3], C.headerBg[4]) end
    if R.headerTitle then R.headerTitle:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end

    -- Hero
    if R.heroBg then R.heroBg:SetColorTexture(C.heroBg[1], C.heroBg[2], C.heroBg[3], C.heroBg[4]) end
    if R.heroGuildName then R.heroGuildName:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3]) end
    if R.infoFS then R.infoFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3]) end
    if R.emblemGlow then R.emblemGlow:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.25) end
    if R.emblemBorders then
        for _, b in ipairs(R.emblemBorders) do b:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.4) end
    end
    if R.heroGlow and R.heroGlow.SetGradient and CreateColor then
        R.heroGlow:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.12))
    end
    if R.identityLine and R.identityLine.SetGradient and CreateColor then
        R.identityLine:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.5),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
    end

    -- Roster panel
    if R.rosterBg then R.rosterBg:SetColorTexture(C.panelBg[1], C.panelBg[2], C.panelBg[3], C.panelBg[4]) end

    -- Column divider
    if R.colDiv then R.colDiv:SetColorTexture(C.divider[1], C.divider[2], C.divider[3], 0.2) end

    -- Chat panel
    if R.chatBg then R.chatBg:SetColorTexture(C.chatBg[1], C.chatBg[2], C.chatBg[3], C.chatBg[4]) end

    -- Search box
    if R.searchBox then
        R.searchBox:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
        R.searchBox:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.15)
        R.searchBox:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    end

    -- Chat input
    if R.chatInput then
        R.chatInput:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
        R.chatInput:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.2)
        R.chatInput:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    end
    if R.chanBtn then
        R.chanBtn:SetBackdropColor(C.inputBg[1], C.inputBg[2], C.inputBg[3], C.inputBg[4])
    end

    -- Context menu
    if R.ctxMenu then
        R.ctxMenu:SetBackdropColor(C.headerBg[1], C.headerBg[2], C.headerBg[3], 0.96)
        R.ctxMenu:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.35)
    end

    -- Settings popup
    if R.settingsPopup then
        R.settingsPopup:SetBackdropColor(C.headerBg[1], C.headerBg[2], C.headerBg[3], 0.96)
        R.settingsPopup:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.5)
    end

    -- MOTD and Guild Info cards
    if R.motdCard then
        R.motdCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
        R.motdCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    end
    if R.motdLbl then R.motdLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end
    if R.gInfoCard then
        R.gInfoCard:SetBackdropColor(C.chatBg[1], C.chatBg[2], C.chatBg[3], 0.5)
        R.gInfoCard:SetBackdropBorderColor(C.divider[1], C.divider[2], C.divider[3], 0.1)
    end
    if R.gInfoLbl then R.gInfoLbl:SetTextColor(C.accent[1], C.accent[2], C.accent[3]) end

    -- Sort headers
    Panel.UpdateSortHeaders()

    -- Refresh dynamic content with new colors
    Panel.UpdateGuildInfo()
    Panel.UpdateRoster()
    Panel.UpdateChat()
end

-- ============================================================================
-- §14a  INFO CARD SIZING & GUILD NEWS
-- ============================================================================
function Panel.SizeInfoCards()
    local R = Panel._refs
    if not R.heroContent then return end
    C_Timer.After(0.08, function()
        if not R.motdCard then return end
        local motdH = R.motdFS and R.motdFS:GetStringHeight() or 14
        R.motdCard:SetHeight(8 + 14 + 6 + motdH + 8)
        local totalH = R.motdCard:GetHeight() + 8

        if R.gInfoCard and R.gInfoCard:IsShown() and R.gInfoFS then
            local gInfoH = R.gInfoFS:GetStringHeight() or 14
            R.gInfoCard:SetHeight(8 + 14 + 6 + gInfoH + 8)
            totalH = totalH + R.gInfoCard:GetHeight() + 8
        end

        if R.challengeCard then
            if Panel._state.challengesExpanded and R.challengeContent and R.challengeContent:IsShown() then
                local ch = R.challengeContent:GetHeight()
                R.challengeCard:SetHeight(26 + 4 + ch + 8)
            else
                R.challengeCard:SetHeight(30)
            end
            totalH = totalH + R.challengeCard:GetHeight() + 8
        end

        if R.newsCard then
            if Panel._state.newsExpanded and R.newsContent and R.newsContent:IsShown() then
                local nh = R.newsContent:GetHeight()
                R.newsCard:SetHeight(26 + 4 + nh + 8)
            else
                R.newsCard:SetHeight(30)
            end
            totalH = totalH + R.newsCard:GetHeight() + 8
        end

        R.heroContent:SetHeight(math.max(totalH, 1))

        -- Show/hide scrollbar
        if R.heroScroll and R.heroScroll.ScrollBar then
            local scrollH = R.heroScroll:GetHeight()
            if totalH > scrollH then
                R.heroScroll.ScrollBar:Show()
            else
                R.heroScroll.ScrollBar:Hide()
                R.heroScroll:SetVerticalScroll(0)
            end
        end
    end)
end

function Panel.UpdateGuildChallenges()
    local R = Panel._refs
    if not R.challengeContent then return end

    local oldChildren = { R.challengeContent:GetChildren() }
    for _, child in ipairs(oldChildren) do child:Hide() end
    local oldRegions = { R.challengeContent:GetRegions() }
    for _, region in ipairs(oldRegions) do region:Hide() end

    local yOfs = 0
    local ROW_H = 28
    local PAD = 4
    local challengeFound = false

    -- Challenge type IDs from the API: 1=Dungeon, 2=Mythic+, 3=Raid, 5=RatedBG
    local CHALLENGE_NAMES = {
        [1] = "Dungeon",
        [2] = "Mythic+ Dungeon",
        [3] = "Raid",
        [5] = "Rated Battleground",
    }

    -- GetGuildChallengeInfo returns: challengeType, current, max, goldReward, goldMaxReward
    -- challengeType: 1=Dungeon, 2=Mythic+, 3=Raid, 5=RatedBG
    if GetGuildChallengeInfo then
        for i = 1, 6 do
            local ok, challengeType, current, max, goldReward, goldMaxReward = pcall(GetGuildChallengeInfo, i)
            if ok and challengeType and max and max > 0 then
                challengeFound = true
                local completed = (current or 0) >= max

                local row = CreateFrame("Frame", nil, R.challengeContent)
                row:SetHeight(ROW_H)
                row:SetPoint("TOPLEFT", R.challengeContent, "TOPLEFT", 0, -yOfs)
                row:SetPoint("RIGHT", R.challengeContent, "RIGHT", 0, 0)

                -- Label
                local label = row:CreateFontString(nil, "OVERLAY")
                TrySetFont(label, BODY_FONT, 11, "")
                label:SetPoint("LEFT", row, "LEFT", 0, 2)
                label:SetText(CHALLENGE_NAMES[challengeType] or ("Challenge " .. challengeType))
                label:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

                -- Progress text (right side)
                local progText = row:CreateFontString(nil, "OVERLAY")
                TrySetFont(progText, BODY_FONT, 11, "")
                progText:SetPoint("RIGHT", row, "RIGHT", 0, 2)
                progText:SetJustifyH("RIGHT")
                local cur = current or 0
                -- Gold reward info
                local rewardText = ""
                if goldReward and goldReward > 0 then
                    rewardText = "  |cffffd700(" .. FormatNumber(goldReward) .. "g)|r"
                end

                if completed then
                    progText:SetText("|cff55ff55Complete|r" .. rewardText)

                    -- Green checkmark icon
                    local checkIcon = row:CreateTexture(nil, "OVERLAY")
                    checkIcon:SetSize(14, 14)
                    checkIcon:SetPoint("RIGHT", progText, "LEFT", -4, 0)
                    local checkOk = pcall(checkIcon.SetAtlas, checkIcon, "common-icon-checkmark")
                    if checkOk then
                        checkIcon:SetVertexColor(0.3, 1, 0.3, 1)
                    else
                        checkIcon:SetColorTexture(0.3, 1, 0.3, 1)
                    end

                    label:SetTextColor(C.online[1], C.online[2], C.online[3])
                else
                    progText:SetText(cur .. " / " .. max .. rewardText)
                    progText:SetTextColor(C.titleText[1], C.titleText[2], C.titleText[3])
                end

                -- Progress bar (bottom of row)
                local trackH = 4
                local track = row:CreateTexture(nil, "ARTWORK")
                track:SetHeight(trackH)
                track:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
                track:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
                track:SetColorTexture(0.12, 0.12, 0.14, 0.5)

                local fill = row:CreateTexture(nil, "ARTWORK", nil, 1)
                fill:SetHeight(trackH)
                fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
                local pct = max > 0 and (cur / max) or 0
                fill:SetWidth(1)
                -- Deferred fill width (no OnSizeChanged to avoid recursion)
                local capturedPct = pct
                local capturedTrack = track
                local capturedFill = fill
                C_Timer.After(0.2, function()
                    local w = capturedTrack:GetWidth()
                    if w > 0 then capturedFill:SetWidth(math.max(1, w * capturedPct)) end
                end)
                if completed then
                    fill:SetColorTexture(C.online[1], C.online[2], C.online[3], 0.8)
                else
                    fill:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.7)
                end

                row:Show()
                yOfs = yOfs + ROW_H + PAD
            end
        end
    end

    if not challengeFound then
        local noFS = R.challengeContent:CreateFontString(nil, "OVERLAY")
        TrySetFont(noFS, BODY_FONT, 10, "")
        noFS:SetPoint("TOPLEFT", R.challengeContent, "TOPLEFT", 0, 0)
        noFS:SetText("Guild Challenges not available")
        noFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
        noFS:Show()
        yOfs = 18
    end

    R.challengeContent:SetHeight(math.max(yOfs, 1))
end

function Panel.UpdateGuildNews()
    local R = Panel._refs
    if not R.newsContent then return end

    local oldRegions = { R.newsContent:GetRegions() }
    for _, region in ipairs(oldRegions) do region:Hide() end

    local yOfs = 0
    local ROW_H = 16
    local newsFound = false

    -- Pull guild event messages from Messenger chat history
    if _G.MessengerDB and _G.MessengerDB.History and _G.MessengerDB.History["Guild"] then
        local hist = _G.MessengerDB.History["Guild"]
        if hist.messages then
            -- Scan last 200 messages for event-type messages (achievements, boss kills, etc.)
            local events = {}
            local start = math.max(1, #hist.messages - 199)
            for i = start, #hist.messages do
                local msg = hist.messages[i]
                local text = msg.msg or ""
                local author = msg.author or ""
                local ts = msg.timestamp or ""

                -- Filter for achievement-like messages and guild events
                local isEvent = false
                if text:find("has earned the achievement") or text:find("has completed") then
                    isEvent = true
                elseif text:find("has been defeated") or text:find("has killed") then
                    isEvent = true
                elseif msg.tag and (msg.tag == "GUILD_ACHIEVEMENT" or msg.tag == "achievement") then
                    isEvent = true
                end

                if isEvent then
                    events[#events + 1] = { text = text, author = author, timestamp = ts }
                end
            end

            -- Show last 20 events
            local showStart = math.max(1, #events - 19)
            for i = showStart, #events do
                local evt = events[i]
                local fs = R.newsContent:CreateFontString(nil, "OVERLAY")
                TrySetFont(fs, BODY_FONT, 10, "")
                fs:SetPoint("TOPLEFT", R.newsContent, "TOPLEFT", 0, -yOfs)
                fs:SetPoint("RIGHT", R.newsContent, "RIGHT", 0, 0)
                fs:SetJustifyH("LEFT"); fs:SetWordWrap(false)

                local display = ""
                if evt.timestamp ~= "" then
                    display = "|cff666666" .. evt.timestamp .. "|r  "
                end
                display = display .. evt.text
                fs:SetText(display)
                fs:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
                fs:Show()
                yOfs = yOfs + ROW_H
                newsFound = true
            end
        end
    end

    if not newsFound then
        local fallbackFS = R.newsContent:CreateFontString(nil, "OVERLAY")
        TrySetFont(fallbackFS, BODY_FONT, 10, "")
        fallbackFS:SetPoint("TOPLEFT", R.newsContent, "TOPLEFT", 0, 0)
        fallbackFS:SetText("No recent guild events")
        fallbackFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.5)
        fallbackFS:Show()
        yOfs = 16
    end

    R.newsContent:SetHeight(math.max(yOfs, 1))
end

-- ============================================================================
-- §14b  PERKS & REWARDS OVERLAY
-- ============================================================================
local perksOverlay = nil

function Panel.TogglePerks()
    local R = Panel._refs
    if not R.panel then return end

    if perksOverlay and perksOverlay:IsShown() then
        perksOverlay:Hide()
        return
    end

    if not perksOverlay then
        perksOverlay = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
        perksOverlay:SetSize(350, 500)
        perksOverlay:SetPoint("TOPRIGHT", R.panel, "TOPRIGHT", -10, -(CFG.HEADER_H + 4))
        perksOverlay:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        perksOverlay:SetBackdropColor(C.frameBg[1], C.frameBg[2], C.frameBg[3], 0.97)
        perksOverlay:SetBackdropBorderColor(C.accent[1], C.accent[2], C.accent[3], 0.35)
        perksOverlay:SetFrameLevel(R.panel:GetFrameLevel() + 20)
        perksOverlay:Hide()

        -- Drop shadow
        for i = 1, 4 do
            local s = perksOverlay:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 1.2
            s:SetColorTexture(0, 0, 0, 0.12 - (i * 0.025))
            s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
        end

        -- Title
        local pTitle = perksOverlay:CreateFontString(nil, "OVERLAY")
        TrySetFont(pTitle, BODY_FONT, 10, "OUTLINE")
        pTitle:SetPoint("TOP", perksOverlay, "TOP", 0, -10)
        pTitle:SetText("GUILD PERKS & REWARDS"); pTitle:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])

        -- Scroll frame
        local pScroll = CreateFrame("ScrollFrame", nil, perksOverlay, "UIPanelScrollFrameTemplate")
        pScroll:SetPoint("TOPLEFT", perksOverlay, "TOPLEFT", 10, -28)
        pScroll:SetPoint("BOTTOMRIGHT", perksOverlay, "BOTTOMRIGHT", -24, 8)
        local pContent = CreateFrame("Frame", nil, pScroll)
        pContent:SetWidth(1)
        pScroll:SetScrollChild(pContent)
        pScroll:SetScript("OnSizeChanged", function(self, w) if w > 0 then pContent:SetWidth(w) end end)
        if pScroll.ScrollBar then
            local sb = pScroll.ScrollBar
            if sb.ThumbTexture then sb.ThumbTexture:SetTexture(W8); sb.ThumbTexture:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 0.20); sb.ThumbTexture:SetWidth(3) end
            if sb.ScrollUpButton then sb.ScrollUpButton:SetAlpha(0) end
            if sb.ScrollDownButton then sb.ScrollDownButton:SetAlpha(0) end
        end
        perksOverlay._content = pContent
    end

    -- Populate
    local content = perksOverlay._content
    local oldChildren = { content:GetChildren() }
    for _, child in ipairs(oldChildren) do child:Hide() end
    local oldRegions = { content:GetRegions() }
    for _, region in ipairs(oldRegions) do region:Hide() end

    local yOfs = 0
    local ROW_H = 30
    local PAD = 8

    -- Guild Perks section
    local perksHdr = content:CreateFontString(nil, "OVERLAY")
    TrySetFont(perksHdr, BODY_FONT, 10, "OUTLINE")
    perksHdr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, 0)
    perksHdr:SetText("PERKS"); perksHdr:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    perksHdr:Show()
    yOfs = yOfs + 14

    if GetNumGuildPerks then
        local numPerks = SafeCall(GetNumGuildPerks) or 0
        for i = 1, numPerks do
            local ok, name, spellID, iconTexture = pcall(GetGuildPerkInfo, i)
            if ok and name and name ~= "" then
                local row = CreateFrame("Button", nil, content)
                row:SetHeight(ROW_H)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOfs)
                row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(22, 22); icon:SetPoint("LEFT", row, "LEFT", PAD, 0)
                icon:SetTexture(iconTexture or 134400); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

                local nameFS = row:CreateFontString(nil, "OVERLAY")
                TrySetFont(nameFS, BODY_FONT, 11, "")
                nameFS:SetPoint("LEFT", icon, "RIGHT", 6, 0)
                nameFS:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
                nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
                nameFS:SetText(name); nameFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])

                -- Tooltip
                local capturedSpell = spellID
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    if capturedSpell and GameTooltip.SetSpellByID then
                        pcall(GameTooltip.SetSpellByID, GameTooltip, capturedSpell)
                    else
                        GameTooltip:SetText(name, 1, 1, 1)
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row:Show()
                yOfs = yOfs + ROW_H
            end
        end
    end

    -- Separator
    yOfs = yOfs + 6
    local sep = content:CreateTexture(nil, "OVERLAY")
    sep:SetHeight(1)
    sep:SetPoint("TOPLEFT", content, "TOPLEFT", PAD, -yOfs)
    sep:SetPoint("RIGHT", content, "RIGHT", -PAD, 0)
    sep:SetTexture(W8)
    if sep.SetGradient and CreateColor then
        sep:SetGradient("HORIZONTAL",
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.3),
            CreateColor(C.accent[1], C.accent[2], C.accent[3], 0.0))
    end
    sep:Show()
    yOfs = yOfs + 8

    -- Guild Rewards section
    local rewardsHdr = content:CreateFontString(nil, "OVERLAY")
    TrySetFont(rewardsHdr, BODY_FONT, 10, "OUTLINE")
    rewardsHdr:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOfs)
    rewardsHdr:SetText("REWARDS"); rewardsHdr:SetTextColor(C.accent[1], C.accent[2], C.accent[3])
    rewardsHdr:Show()
    yOfs = yOfs + 14

    if GetNumGuildRewards then
        local numRewards = SafeCall(GetNumGuildRewards) or 0
        for i = 1, numRewards do
            -- Returns: achievementReq, itemID, itemName, iconFileID, quality, cost
            local ok, achReq, itemID, itemName, iconFileID, quality, cost = pcall(GetGuildRewardInfo, i)
            if ok and itemName and itemName ~= "" then
                local row = CreateFrame("Button", nil, content)
                row:SetHeight(ROW_H)
                row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -yOfs)
                row:SetPoint("RIGHT", content, "RIGHT", 0, 0)

                -- Icon
                local icon = row:CreateTexture(nil, "ARTWORK")
                icon:SetSize(22, 22); icon:SetPoint("LEFT", row, "LEFT", PAD, 0)
                icon:SetTexture(iconFileID or 134400); icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

                -- Name (quality colored)
                local nameFS = row:CreateFontString(nil, "OVERLAY")
                TrySetFont(nameFS, BODY_FONT, 11, "")
                nameFS:SetPoint("LEFT", icon, "RIGHT", 6, 0)
                nameFS:SetJustifyH("LEFT"); nameFS:SetWordWrap(false)
                nameFS:SetText(itemName)
                if quality then
                    local qr, qg, qb = GetItemQualityColor(quality)
                    if qr then nameFS:SetTextColor(qr, qg, qb) end
                else
                    nameFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
                end

                -- Cost (right side, gold)
                if cost and cost > 0 then
                    local costFS = row:CreateFontString(nil, "OVERLAY")
                    TrySetFont(costFS, BODY_FONT, 10, "")
                    costFS:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
                    costFS:SetJustifyH("RIGHT")
                    local gold = math.floor(cost / 10000)
                    costFS:SetText("|cffffd700" .. FormatNumber(gold) .. "g|r")
                    nameFS:SetPoint("RIGHT", costFS, "LEFT", -6, 0)
                else
                    nameFS:SetPoint("RIGHT", row, "RIGHT", -PAD, 0)
                end

                -- Tooltip
                local capturedItemID = itemID
                row:SetScript("OnEnter", function(self)
                    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
                    if capturedItemID and GameTooltip.SetItemByID then
                        pcall(GameTooltip.SetItemByID, GameTooltip, capturedItemID)
                    else
                        GameTooltip:SetText(itemName or "Reward", 1, 1, 1)
                    end
                    GameTooltip:Show()
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)

                row:Show()
                yOfs = yOfs + ROW_H
            end
        end
    end

    content:SetHeight(math.max(yOfs + 10, 1))
    perksOverlay:Show()
end

function Panel.ShowSettingsPopup()
    local R = Panel._refs
    if R.settingsPopup then R.settingsPopup:Show() end
end

function Panel.Hide()
    local R = Panel._refs
    if not R.panel then return end
    if R.ctxMenu then R.ctxMenu:Hide() end
    if R.noteEditor then R.noteEditor:Hide() end
    if R.settingsPopup then R.settingsPopup:Hide() end
    -- Close any active Blizzard chat edit box opened by whisper action
    local chatFrame = DEFAULT_CHAT_FRAME or ChatFrame1
    if chatFrame and chatFrame.editBox and chatFrame.editBox:IsShown() then
        if ChatEdit_DeactivateChat then
            pcall(ChatEdit_DeactivateChat, chatFrame.editBox)
        else
            chatFrame.editBox:SetText("")
            chatFrame.editBox:ClearFocus()
            chatFrame.editBox:Hide()
        end
    end
    if R.panel._fadeOut then
        R.panel._fadeOut:Play()
    else
        R.panel:Hide()
    end
    Panel._state.panelOpen = false
end

function Panel.Toggle()
    if Panel._state.panelOpen then
        Panel.Hide()
    else
        Panel.Show()
    end
end

function Panel.IsOpen()
    return Panel._state.panelOpen
end

-- ============================================================================
-- §14  EVENTS
-- ============================================================================
local evf = CreateFrame("Frame")
local function SafeReg(event) pcall(evf.RegisterEvent, evf, event) end

SafeReg("ADDON_LOADED")
SafeReg("GUILD_ROSTER_UPDATE")
SafeReg("GUILD_MOTD")
SafeReg("CHAT_MSG_GUILD")
SafeReg("CHAT_MSG_OFFICER")
SafeReg("CHAT_MSG_GUILD_ACHIEVEMENT")
SafeReg("PLAYER_GUILD_UPDATE")

local pendingRosterUpdate = false
evf:SetScript("OnEvent", function(_, event, arg1)
    if event == "GUILD_ROSTER_UPDATE" then
        if Panel.IsOpen() and not pendingRosterUpdate then
            pendingRosterUpdate = true
            C_Timer.After(0.1, function()
                pendingRosterUpdate = false
                if Panel.IsOpen() then
                    Panel.UpdateGuildInfo()
                    Panel.UpdateRoster()
                end
            end)
        end
    elseif event == "GUILD_MOTD" then
        if Panel.IsOpen() then Panel.UpdateGuildInfo() end
    elseif event == "CHAT_MSG_GUILD" or event == "CHAT_MSG_OFFICER"
        or event == "CHAT_MSG_GUILD_ACHIEVEMENT" then
        if Panel.IsOpen() then
            C_Timer.After(0.1, function()
                if Panel.IsOpen() then Panel.UpdateChat() end
            end)
        end
    elseif event == "PLAYER_GUILD_UPDATE" then
        if Panel.IsOpen() then Panel.UpdateGuildInfo() end
    end
end)

-- ============================================================================
-- §15  HOOK: ToggleGuildFrame Interception
-- ============================================================================
local hookInstalled = false
local hookGuard = false

local function InstallGuildHook()
    if hookInstalled then return end
    if type(ToggleGuildFrame) ~= "function" then return end
    hookInstalled = true

    hooksecurefunc("ToggleGuildFrame", function()
        if hookGuard then return end
        hookGuard = true
        -- Suppress Blizzard frames
        if CommunitiesFrame and CommunitiesFrame:IsShown() then
            pcall(HideUIPanel, CommunitiesFrame)
        end
        Panel.Toggle()
        C_Timer.After(0, function() hookGuard = false end)
    end)
end

InstallGuildHook()

local hookEvf = CreateFrame("Frame")
hookEvf:RegisterEvent("ADDON_LOADED")
hookEvf:SetScript("OnEvent", function(_, event, addon)
    if addon == "Blizzard_Communities" or addon == "Blizzard_GuildUI" then
        InstallGuildHook()
        -- Close Blizzard frame if it opened on first load
        C_Timer.After(0.05, function()
            if CommunitiesFrame and CommunitiesFrame:IsShown() then
                pcall(HideUIPanel, CommunitiesFrame)
                if not Panel.IsOpen() then Panel.Show() end
            end
        end)
    end
end)

-- ============================================================================
-- §17  M+ LFG DETECTION (Guild Chat Keyword Scanner)
-- ============================================================================
-- Detects when guild members are looking for M+ groups and notifies the player.

-- Season 1 Midnight Dungeons + abbreviations
local DUNGEON_PATTERNS = {
    -- Midnight S1
    { full = "Magisters' Terrace",       short = "MT",   patterns = { "magister", "mag terrace", "mgt" } },
    { full = "Maisara Caverns",          short = "MC",   patterns = { "maisara", "caverns" } },
    { full = "Nexus%-Point Xenas",       short = "NPX",  patterns = { "nexus", "xenas", "npx" } },
    { full = "Windrunner Spire",         short = "WS",   patterns = { "windrunner", "spire" } },
    { full = "Algeth'ar Academy",        short = "AA",   patterns = { "algeth", "academy", "aa" } },
    { full = "The Seat of the Triumvirate", short = "SotT", patterns = { "seat", "triumvirate", "sott" } },
    { full = "Skyreach",                 short = "SR",   patterns = { "skyreach" } },
    { full = "Pit of Saron",            short = "PoS",  patterns = { "pit of saron", "pit.*saron", "pos" } },
}

-- M+ keywords that indicate someone is looking for a group
local MPLUS_KEYWORDS = {
    "m%+", "mythic%+", "mythic plus", "mythicplus",
    "key", "keys", "keystone",
    "lf[gm].*dungeon", "lfg", "lfm",
    "anyone.*run", "anyone.*key", "anyone.*m%+",
    "need.*tank", "need.*healer", "need.*dps", "need.*heal",
    "looking for.*m", "looking for.*key", "looking for.*dungeon",
    "want to run", "wanna run", "down for", "down to run",
    "push.*key", "pushing.*key",
    "+%d+", "%+%d+",  -- +15, +20 etc
}

DetectMPlusMessage = function(text)
    if not text or text == "" then return false, nil end
    local lower = text:lower()

    -- Skip achievement messages — they contain M+ keywords like "keystone" but aren't LFG
    if lower:find("has earned the achievement") then return false, nil end

    -- Check for M+ keywords
    local isMPlus = false
    for _, pattern in ipairs(MPLUS_KEYWORDS) do
        if lower:find(pattern) then
            isMPlus = true
            break
        end
    end

    if not isMPlus then return false, nil end

    -- Try to identify the dungeon
    local dungeonName = nil
    for _, dungeon in ipairs(DUNGEON_PATTERNS) do
        for _, pat in ipairs(dungeon.patterns) do
            if lower:find(pat) then
                dungeonName = dungeon.full
                break
            end
        end
        if dungeonName then break end
    end

    -- Also detect key level (e.g., +15, +20)
    local keyLevel = lower:match("%+(%d+)") or lower:match("(%d+)%s*key") or lower:match("(%d+)%s*m%+")

    return true, dungeonName, keyLevel
end

-- ── M+ Toast Notification ──────────────────────────────────────────────
local mplusToast = nil
local mplusToastState = { active = false, timer = 0, phase = "idle" }

ShowMPlusToast = function(sender, dungeonName, keyLevel)
    if not mplusToast then
        mplusToast = CreateFrame("Frame", nil, UIParent)
        mplusToast:SetHeight(40)
        -- Anchor above Messenger, match its width
        local messengerFrame = _G.MyMessengerFrame
        if messengerFrame then
            mplusToast:SetPoint("BOTTOMLEFT", messengerFrame, "TOPLEFT", 0, 4)
            mplusToast:SetPoint("BOTTOMRIGHT", messengerFrame, "TOPRIGHT", 0, 4)
        else
            mplusToast:SetSize(420, 50)
            mplusToast:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)
        end
        mplusToast:SetFrameStrata("FULLSCREEN_DIALOG")
        mplusToast:SetFrameLevel(500)
        mplusToast:SetAlpha(0)
        mplusToast:Hide()

        -- Drop shadow
        for i = 1, 4 do
            local s = mplusToast:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 1.5
            s:SetColorTexture(0, 0, 0, 0.15 - (i * 0.03))
            s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
        end

        -- Background
        local bg = mplusToast:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints(); bg:SetColorTexture(0.04, 0.04, 0.07, 0.95)

        -- Accent top border (cyan gradient)
        local bTop = mplusToast:CreateTexture(nil, "OVERLAY"); bTop:SetHeight(2)
        bTop:SetPoint("TOPLEFT"); bTop:SetPoint("TOPRIGHT")
        bTop:SetTexture(W8)
        if bTop.SetGradient and CreateColor then
            bTop:SetGradient("HORIZONTAL",
                CreateColor(0.00, 0.78, 1.00, 0.8),
                CreateColor(0.00, 0.78, 1.00, 0.0))
        end
        local bBot = mplusToast:CreateTexture(nil, "OVERLAY"); bBot:SetHeight(1)
        bBot:SetPoint("BOTTOMLEFT"); bBot:SetPoint("BOTTOMRIGHT")
        bBot:SetColorTexture(0.00, 0.78, 1.00, 0.2)
        local bLeft = mplusToast:CreateTexture(nil, "OVERLAY"); bLeft:SetWidth(1)
        bLeft:SetPoint("TOPLEFT"); bLeft:SetPoint("BOTTOMLEFT")
        bLeft:SetColorTexture(0.00, 0.78, 1.00, 0.3)
        local bRight = mplusToast:CreateTexture(nil, "OVERLAY"); bRight:SetWidth(1)
        bRight:SetPoint("TOPRIGHT"); bRight:SetPoint("BOTTOMRIGHT")
        bRight:SetColorTexture(0.00, 0.78, 1.00, 0.1)

        -- Icon
        local icon = mplusToast:CreateTexture(nil, "ARTWORK")
        icon:SetSize(22, 22); icon:SetPoint("LEFT", mplusToast, "LEFT", 10, 0)
        icon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
        icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        -- M+ badge
        local badge = mplusToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(badge, BODY_FONT, 10, "OUTLINE")
        badge:SetPoint("LEFT", icon, "RIGHT", 8, 0)
        badge:SetText("M+")
        badge:SetTextColor(0.00, 0.78, 1.00)

        -- Title (player name)
        local titleFS = mplusToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(titleFS, BODY_FONT, 11, "OUTLINE")
        titleFS:SetPoint("LEFT", badge, "RIGHT", 6, 0)
        titleFS:SetTextColor(0.94, 0.90, 0.80)
        titleFS:SetShadowColor(0, 0, 0, 0.8); titleFS:SetShadowOffset(1, -1)
        mplusToast._title = titleFS

        -- Separator dot
        local dot = mplusToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(dot, BODY_FONT, 11, "")
        dot:SetPoint("LEFT", titleFS, "RIGHT", 6, 0)
        dot:SetText("\194\183")
        dot:SetTextColor(0.50, 0.50, 0.55)
        mplusToast._dot = dot

        -- Subtitle (dungeon/description)
        local subFS = mplusToast:CreateFontString(nil, "OVERLAY")
        TrySetFont(subFS, BODY_FONT, 11, "")
        subFS:SetPoint("LEFT", dot, "RIGHT", 6, 0)
        subFS:SetPoint("RIGHT", mplusToast, "RIGHT", -10, 0)
        subFS:SetJustifyH("LEFT"); subFS:SetWordWrap(false)
        subFS:SetTextColor(0.70, 0.72, 0.76, 0.9)
        mplusToast._sub = subFS

        -- Animation
        mplusToast:SetScript("OnUpdate", function(self, elapsed)
            if not mplusToastState.active then return end
            mplusToastState.timer = mplusToastState.timer + elapsed
            if mplusToastState.phase == "fadein" then
                local p = math.min(1, mplusToastState.timer / 0.3)
                self:SetAlpha(p * p * (3 - 2 * p))
                if p >= 1 then mplusToastState.phase = "hold"; mplusToastState.timer = 0 end
            elseif mplusToastState.phase == "hold" then
                self:SetAlpha(1)
                if mplusToastState.timer >= 4.0 then mplusToastState.phase = "fadeout"; mplusToastState.timer = 0 end
            elseif mplusToastState.phase == "fadeout" then
                local p = math.min(1, mplusToastState.timer / 0.5)
                self:SetAlpha(1 - p)
                if p >= 1 then
                    mplusToastState.active = false; mplusToastState.phase = "idle"
                    self:SetAlpha(0); self:Hide()
                end
            end
        end)
    end

    -- Set content
    local shortSender = sender:match("^([^%-]+)") or sender
    mplusToast._title:SetText(shortSender)

    local subText = "is looking for a group"
    if dungeonName then
        subText = dungeonName
        if keyLevel then subText = subText .. "  +" .. keyLevel end
    elseif keyLevel then
        subText = "+" .. keyLevel .. " key"
    end
    mplusToast._sub:SetText(subText)

    -- Play animation
    mplusToastState.active = true
    mplusToastState.timer = 0
    mplusToastState.phase = "fadein"
    mplusToast:SetAlpha(0)
    mplusToast:Show()

    -- Sound
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
end

-- Store detection function for use by chat rendering
Panel._detectMPlus = DetectMPlusMessage
Panel._showMPlusToast = ShowMPlusToast

-- ── Hook into guild chat events for real-time detection ────────────────
local mplusEvf = CreateFrame("Frame")
mplusEvf:RegisterEvent("CHAT_MSG_GUILD")
mplusEvf:SetScript("OnEvent", function(_, event, msg, sender)
    if event == "CHAT_MSG_GUILD" and msg and sender then
        local isMPlus, dungeonName, keyLevel = DetectMPlusMessage(msg)
        if isMPlus then
            -- Don't toast for your own messages
            local playerName = SafeCall(UnitName, "player") or ""
            local shortSender = sender:match("^([^%-]+)") or sender
            if shortSender ~= playerName then
                ShowMPlusToast(sender, dungeonName, keyLevel)
            end
        end
    end
end)

-- ============================================================================
-- §18  M+ GUILD LFG SYSTEM
-- ============================================================================
local LFG_PREFIX = "MUI_MPLUS"
pcall(C_ChatInfo.RegisterAddonMessagePrefix, LFG_PREFIX)

local S1_DUNGEONS = {
    { name = "Magisters' Terrace",          abbr = "MT",   accent = {0.80, 0.30, 0.30} },
    { name = "Maisara Caverns",             abbr = "MC",   accent = {0.30, 0.70, 0.40} },
    { name = "Nexus-Point Xenas",           abbr = "NPX",  accent = {0.40, 0.50, 0.90} },
    { name = "Windrunner Spire",            abbr = "WS",   accent = {0.65, 0.40, 0.85} },
    { name = "Algeth'ar Academy",           abbr = "AA",   accent = {0.85, 0.65, 0.20} },
    { name = "The Seat of the Triumvirate", abbr = "SotT", accent = {0.20, 0.75, 0.80} },
    { name = "Skyreach",                    abbr = "SR",   accent = {0.90, 0.55, 0.25} },
    { name = "Pit of Saron",               abbr = "PoS",  accent = {0.45, 0.70, 0.95} },
}

local ROLE_DEFS = {
    { key = "TANK",   label = "Tank",   atlas = "roleicon-tank" },
    { key = "HEALER", label = "Healer", atlas = "roleicon-healer" },
    { key = "DPS",    label = "DPS",    atlas = "roleicon-dps" },
}

-- LFG State
local lfgState = {
    hosting = false,
    selectedDungeon = nil,
    selectedLevel = "",
    selectedRoles = { TANK = false, HEALER = false, DPS = false },
    applicants = {},  -- { name, class, spec, rating, guid }
}

local lfgOverlay = nil

function Panel.ShowLFGOverlay()
    local R = Panel._refs
    if not R.panel then return end

    if lfgOverlay and lfgOverlay:IsShown() then
        lfgOverlay:Hide()
        return
    end

    lfgState.selectedDungeon = nil
    lfgState.selectedLevel = ""
    lfgState.selectedRoles = { TANK = false, HEALER = false, DPS = false }
    lfgState.applicants = {}

    if lfgOverlay then
        if lfgOverlay._lvlInput then lfgOverlay._lvlInput:SetText("") end
        lfgOverlay:Show()
        return
    end

    if not lfgOverlay then
        local PAD = 20

        lfgOverlay = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
        lfgOverlay:SetSize(440, 495)
        lfgOverlay:SetPoint("CENTER", R.panel, "CENTER", 0, 0)
        lfgOverlay:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        lfgOverlay:SetBackdropColor(0.025, 0.028, 0.045, 0.98)
        lfgOverlay:SetBackdropBorderColor(0.00, 0.55, 0.80, 0.25)
        lfgOverlay:SetFrameLevel(R.panel:GetFrameLevel() + 25)
        lfgOverlay:Hide()

        -- Drop shadow (heavier)
        for i = 1, 6 do
            local s = lfgOverlay:CreateTexture(nil, "BACKGROUND", nil, -1)
            local off = i * 2
            s:SetColorTexture(0, 0, 0, 0.20 - (i * 0.028))
            s:SetPoint("TOPLEFT", -off, off); s:SetPoint("BOTTOMRIGHT", off, -off)
        end

        -- Top accent bar (gradient, 3px)
        local topBar = lfgOverlay:CreateTexture(nil, "OVERLAY", nil, 4)
        topBar:SetHeight(3); topBar:SetPoint("TOPLEFT", 1, -1); topBar:SetPoint("TOPRIGHT", -1, -1)
        topBar:SetTexture(W8)
        if topBar.SetGradient and CreateColor then
            topBar:SetGradient("HORIZONTAL",
                CreateColor(0.00, 0.78, 1.00, 0.9),
                CreateColor(0.30, 0.50, 1.00, 0.2))
        end

        -- Top ambient glow
        local ambGlow = lfgOverlay:CreateTexture(nil, "BACKGROUND", nil, 1)
        ambGlow:SetHeight(60); ambGlow:SetPoint("TOPLEFT", 1, -4); ambGlow:SetPoint("TOPRIGHT", -1, -4)
        ambGlow:SetTexture(W8)
        if ambGlow.SetGradient and CreateColor then
            ambGlow:SetGradient("VERTICAL",
                CreateColor(0, 0, 0, 0),
                CreateColor(0.00, 0.50, 0.80, 0.05))
        end

        -- ── Header ──
        local headerBar = CreateFrame("Frame", nil, lfgOverlay)
        headerBar:SetHeight(44); headerBar:SetPoint("TOPLEFT", 0, 0); headerBar:SetPoint("TOPRIGHT", 0, 0)

        local hIcon = headerBar:CreateTexture(nil, "ARTWORK")
        hIcon:SetSize(26, 26); hIcon:SetPoint("LEFT", headerBar, "LEFT", PAD, 0)
        hIcon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
        hIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

        local hTitle = headerBar:CreateFontString(nil, "OVERLAY")
        TrySetFont(hTitle, TITLE_FONT, 16, "OUTLINE")
        hTitle:SetPoint("LEFT", hIcon, "RIGHT", 10, 2)
        hTitle:SetText("Mythic+ Listing"); hTitle:SetTextColor(1, 1, 1)
        hTitle:SetShadowColor(0, 0, 0, 0.8); hTitle:SetShadowOffset(1, -1)

        local hSub = headerBar:CreateFontString(nil, "OVERLAY")
        TrySetFont(hSub, BODY_FONT, 10, "")
        hSub:SetPoint("TOPLEFT", hTitle, "BOTTOMLEFT", 0, -1)
        hSub:SetText("Create a listing for your guild"); hSub:SetTextColor(0.55, 0.58, 0.65)

        local closeBtn2 = CreateFrame("Button", nil, headerBar)
        closeBtn2:SetSize(22, 22); closeBtn2:SetPoint("RIGHT", headerBar, "RIGHT", -PAD, 0)
        local closeTx2 = closeBtn2:CreateFontString(nil, "OVERLAY")
        TrySetFont(closeTx2, BODY_FONT, 14, "OUTLINE"); closeTx2:SetPoint("CENTER"); closeTx2:SetText("X")
        closeTx2:SetTextColor(0.45, 0.45, 0.50, 0.6)
        closeBtn2:SetScript("OnClick", function() lfgOverlay:Hide() end)
        closeBtn2:SetScript("OnEnter", function() closeTx2:SetTextColor(1, 0.3, 0.3) end)
        closeBtn2:SetScript("OnLeave", function() closeTx2:SetTextColor(0.45, 0.45, 0.50, 0.6) end)

        local hSep = headerBar:CreateTexture(nil, "OVERLAY")
        hSep:SetHeight(1); hSep:SetPoint("BOTTOMLEFT", PAD, 0); hSep:SetPoint("BOTTOMRIGHT", -PAD, 0)
        hSep:SetColorTexture(0.20, 0.22, 0.30, 0.3)

        -- ── Dungeon Grid (single column, card style) ──
        local yOfs = 52
        local dungLabel = lfgOverlay:CreateFontString(nil, "OVERLAY")
        TrySetFont(dungLabel, BODY_FONT, 10, "OUTLINE")
        dungLabel:SetPoint("TOPLEFT", lfgOverlay, "TOPLEFT", PAD, -yOfs)
        dungLabel:SetText("SELECT DUNGEON"); dungLabel:SetTextColor(0.00, 0.68, 0.95)
        yOfs = yOfs + 18

        local dungeonBtns = {}
        local DUNG_CARD_H = 30
        local DUNG_CARD_GAP = 3
        local gridW = 440 - (PAD * 2)

        for i, dungInfo in ipairs(S1_DUNGEONS) do
            local dungName = dungInfo.name
            local accentColor = dungInfo.accent

            local btn = CreateFrame("Button", nil, lfgOverlay)
            btn:SetSize(gridW, DUNG_CARD_H)
            btn:SetPoint("TOPLEFT", lfgOverlay, "TOPLEFT",
                PAD, -(yOfs + (i - 1) * (DUNG_CARD_H + DUNG_CARD_GAP)))

            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(0.04, 0.042, 0.065, 0.7)
            btn._bg = bg

            -- Left accent bar (colored per dungeon)
            local accent = btn:CreateTexture(nil, "OVERLAY", nil, 2)
            accent:SetWidth(3); accent:SetPoint("TOPLEFT", 0, 0); accent:SetPoint("BOTTOMLEFT", 0, 0)
            accent:SetColorTexture(accentColor[1], accentColor[2], accentColor[3], 0.6)
            btn._accent = accent

            -- Abbreviation badge
            local abbrFS = btn:CreateFontString(nil, "OVERLAY")
            TrySetFont(abbrFS, TITLE_FONT, 10, "OUTLINE")
            abbrFS:SetPoint("LEFT", btn, "LEFT", 12, 0)
            abbrFS:SetText(dungInfo.abbr)
            abbrFS:SetTextColor(accentColor[1], accentColor[2], accentColor[3], 0.8)
            abbrFS:SetWidth(36); abbrFS:SetJustifyH("CENTER")
            btn._abbrFS = abbrFS

            -- Dungeon name
            local fs = btn:CreateFontString(nil, "OVERLAY")
            TrySetFont(fs, BODY_FONT, 11, "")
            fs:SetPoint("LEFT", btn, "LEFT", 52, 0)
            fs:SetText(dungName); fs:SetTextColor(0.78, 0.80, 0.85)
            btn._fs = fs

            -- Subtle bottom border
            local bdrB = btn:CreateTexture(nil, "OVERLAY")
            bdrB:SetHeight(1); bdrB:SetPoint("BOTTOMLEFT", 3, 0); bdrB:SetPoint("BOTTOMRIGHT", 0, 0)
            bdrB:SetColorTexture(0.12, 0.14, 0.20, 0.25)
            btn._bdrB = bdrB

            btn:SetScript("OnClick", function()
                lfgState.selectedDungeon = dungName
                for _, db in ipairs(dungeonBtns) do
                    db._bg:SetColorTexture(0.04, 0.042, 0.065, 0.7)
                    db._fs:SetTextColor(0.78, 0.80, 0.85)
                    db._accent:SetAlpha(0.6)
                    db._abbrFS:SetAlpha(0.8)
                    if db._bdrB then db._bdrB:SetColorTexture(0.12, 0.14, 0.20, 0.25) end
                end
                bg:SetColorTexture(accentColor[1] * 0.08, accentColor[2] * 0.08, accentColor[3] * 0.08, 0.9)
                fs:SetTextColor(1, 1, 1)
                accent:SetAlpha(1)
                abbrFS:SetAlpha(1)
                if btn._bdrB then btn._bdrB:SetColorTexture(accentColor[1], accentColor[2], accentColor[3], 0.3) end
            end)
            btn:SetScript("OnEnter", function()
                if lfgState.selectedDungeon ~= dungName then
                    bg:SetColorTexture(0.055, 0.058, 0.085, 0.8)
                end
            end)
            btn:SetScript("OnLeave", function()
                if lfgState.selectedDungeon ~= dungName then
                    bg:SetColorTexture(0.04, 0.042, 0.065, 0.7)
                end
            end)

            dungeonBtns[#dungeonBtns + 1] = btn
        end
        yOfs = yOfs + #S1_DUNGEONS * (DUNG_CARD_H + DUNG_CARD_GAP) + 14

        -- ── Settings Row: Key Level + Roles ──
        local lvlLabel = lfgOverlay:CreateFontString(nil, "OVERLAY")
        TrySetFont(lvlLabel, BODY_FONT, 10, "OUTLINE")
        lvlLabel:SetPoint("TOPLEFT", lfgOverlay, "TOPLEFT", PAD, -yOfs)
        lvlLabel:SetText("KEY LEVEL"); lvlLabel:SetTextColor(0.00, 0.68, 0.95)

        local roleLabel = lfgOverlay:CreateFontString(nil, "OVERLAY")
        TrySetFont(roleLabel, BODY_FONT, 10, "OUTLINE")
        roleLabel:SetPoint("LEFT", lfgOverlay, "LEFT", PAD + 110, 0)
        roleLabel:SetPoint("TOP", lvlLabel, "TOP", 0, 0)
        roleLabel:SetText("LOOKING FOR"); roleLabel:SetTextColor(0.00, 0.68, 0.95)
        yOfs = yOfs + 16

        -- Key level input with keystone icon
        local lvlInput = CreateFrame("EditBox", nil, lfgOverlay, "BackdropTemplate")
        lvlInput:SetSize(90, 36)
        lvlInput:SetPoint("TOPLEFT", lfgOverlay, "TOPLEFT", PAD, -yOfs)
        lvlInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 10, right = 10, top = 4, bottom = 4 } })
        lvlInput:SetBackdropColor(0.04, 0.04, 0.06, 0.9)
        lvlInput:SetBackdropBorderColor(0.15, 0.17, 0.25, 0.4)
        TrySetFont(lvlInput, TITLE_FONT, 16, "")
        lvlInput:SetTextColor(0.00, 0.85, 1.00)
        lvlInput:SetAutoFocus(false); lvlInput:SetNumeric(true); lvlInput:SetMaxLetters(3)
        lvlInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        lvlInput:SetScript("OnEditFocusGained", function(self) self:SetBackdropBorderColor(0.00, 0.65, 0.90, 0.5) end)
        lvlInput:SetScript("OnEditFocusLost", function(self) self:SetBackdropBorderColor(0.15, 0.17, 0.25, 0.4) end)
        lvlInput:SetScript("OnTextChanged", function(self) lfgState.selectedLevel = self:GetText() or "" end)
        lfgOverlay._lvlInput = lvlInput

        -- Plus sign
        local plusFS = lfgOverlay:CreateFontString(nil, "OVERLAY")
        TrySetFont(plusFS, TITLE_FONT, 18, "OUTLINE")
        plusFS:SetPoint("RIGHT", lvlInput, "LEFT", -4, 0)
        plusFS:SetText("+"); plusFS:SetTextColor(0.00, 0.78, 1.00, 0.8)

        -- Role buttons with icons
        local ROLE_COLORS = {
            TANK   = { 0.30, 0.60, 1.00 },
            HEALER = { 0.30, 0.90, 0.40 },
            DPS    = { 0.90, 0.30, 0.30 },
        }
        local roleXOfs = PAD + 110
        for _, role in ipairs(ROLE_DEFS) do
            local rc = ROLE_COLORS[role.key] or { 0.7, 0.7, 0.7 }
            local btn = CreateFrame("Button", nil, lfgOverlay)
            btn:SetSize(90, 36)
            btn:SetPoint("TOPLEFT", lfgOverlay, "TOPLEFT", roleXOfs, -yOfs)

            local bg = btn:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints(); bg:SetColorTexture(0.04, 0.042, 0.065, 0.7)
            btn._bg = bg

            -- Bottom accent (shows role color when selected)
            local bottomAccent = btn:CreateTexture(nil, "OVERLAY", nil, 2)
            bottomAccent:SetHeight(2); bottomAccent:SetPoint("BOTTOMLEFT", 0, 0); bottomAccent:SetPoint("BOTTOMRIGHT", 0, 0)
            bottomAccent:SetColorTexture(rc[1], rc[2], rc[3], 0)
            btn._bottomAccent = bottomAccent

            -- Role icon
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetSize(18, 18); icon:SetPoint("LEFT", btn, "LEFT", 8, 0)
            icon:SetDesaturated(true); icon:SetAlpha(0.5)
            if role.atlas then
                icon:SetAtlas(role.atlas)
            end
            btn._icon = icon

            local fs = btn:CreateFontString(nil, "OVERLAY")
            TrySetFont(fs, BODY_FONT, 11, "OUTLINE")
            fs:SetPoint("LEFT", icon, "RIGHT", 5, 0)
            fs:SetText(role.label); fs:SetTextColor(0.60, 0.62, 0.68)
            btn._fs = fs

            local capturedKey = role.key
            btn:SetScript("OnClick", function()
                lfgState.selectedRoles[capturedKey] = not lfgState.selectedRoles[capturedKey]
                if lfgState.selectedRoles[capturedKey] then
                    bg:SetColorTexture(rc[1] * 0.12, rc[2] * 0.12, rc[3] * 0.12, 0.7)
                    fs:SetTextColor(rc[1], rc[2], rc[3])
                    icon:SetDesaturated(false); icon:SetAlpha(1)
                    bottomAccent:SetColorTexture(rc[1], rc[2], rc[3], 0.8)
                else
                    bg:SetColorTexture(0.04, 0.042, 0.065, 0.7)
                    fs:SetTextColor(0.60, 0.62, 0.68)
                    icon:SetDesaturated(true); icon:SetAlpha(0.5)
                    bottomAccent:SetColorTexture(rc[1], rc[2], rc[3], 0)
                end
            end)

            roleXOfs = roleXOfs + 96
        end

        -- ── Submit Button ──
        local submitBtn = CreateFrame("Button", nil, lfgOverlay)
        submitBtn:SetHeight(38)
        submitBtn:SetPoint("BOTTOMLEFT", lfgOverlay, "BOTTOMLEFT", PAD, PAD)
        submitBtn:SetPoint("BOTTOMRIGHT", lfgOverlay, "BOTTOMRIGHT", -PAD, PAD)

        local submitBg = submitBtn:CreateTexture(nil, "BACKGROUND")
        submitBg:SetAllPoints(); submitBg:SetTexture(W8)
        if submitBg.SetGradient and CreateColor then
            submitBg:SetGradient("HORIZONTAL",
                CreateColor(0.00, 0.35, 0.55, 0.40),
                CreateColor(0.00, 0.50, 0.70, 0.18))
        end

        -- Submit icon (guild crest)
        local submitIcon = submitBtn:CreateTexture(nil, "ARTWORK")
        submitIcon:SetSize(18, 18); submitIcon:SetPoint("LEFT", submitBtn, "LEFT", 14, 0)
        submitIcon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
        submitIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93); submitIcon:SetAlpha(0.7)

        local submitFS = submitBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(submitFS, BODY_FONT, 13, "OUTLINE")
        submitFS:SetPoint("CENTER", submitBtn, "CENTER", 8, 0)
        submitFS:SetText("Send to Guild"); submitFS:SetTextColor(0.00, 0.88, 1.00)

        -- Borders
        local sT = submitBtn:CreateTexture(nil, "OVERLAY"); sT:SetHeight(1)
        sT:SetPoint("TOPLEFT"); sT:SetPoint("TOPRIGHT"); sT:SetColorTexture(0.00, 0.65, 0.90, 0.4)
        local sB = submitBtn:CreateTexture(nil, "OVERLAY"); sB:SetHeight(1)
        sB:SetPoint("BOTTOMLEFT"); sB:SetPoint("BOTTOMRIGHT"); sB:SetColorTexture(0.00, 0.65, 0.90, 0.4)
        local sL = submitBtn:CreateTexture(nil, "OVERLAY"); sL:SetWidth(1)
        sL:SetPoint("TOPLEFT"); sL:SetPoint("BOTTOMLEFT"); sL:SetColorTexture(0.00, 0.65, 0.90, 0.4)
        local sR = submitBtn:CreateTexture(nil, "OVERLAY"); sR:SetWidth(1)
        sR:SetPoint("TOPRIGHT"); sR:SetPoint("BOTTOMRIGHT"); sR:SetColorTexture(0.00, 0.65, 0.90, 0.4)

        submitBtn:SetScript("OnEnter", function()
            if submitBg.SetGradient and CreateColor then
                submitBg:SetGradient("HORIZONTAL",
                    CreateColor(0.00, 0.42, 0.65, 0.55),
                    CreateColor(0.00, 0.58, 0.80, 0.35))
            end
            submitFS:SetTextColor(1, 1, 1)
            submitIcon:SetAlpha(1)
        end)
        submitBtn:SetScript("OnLeave", function()
            if submitBg.SetGradient and CreateColor then
                submitBg:SetGradient("HORIZONTAL",
                    CreateColor(0.00, 0.35, 0.55, 0.40),
                    CreateColor(0.00, 0.50, 0.70, 0.18))
            end
            submitFS:SetTextColor(0.00, 0.88, 1.00)
            submitIcon:SetAlpha(0.7)
        end)
        submitBtn:SetScript("OnClick", function() Panel.SubmitLFGListing() end)
    end

    if lfgOverlay._lvlInput then lfgOverlay._lvlInput:SetText("") end
    lfgOverlay:Show()
end

function Panel.SubmitLFGListing()
    if not lfgState.selectedDungeon then
        local dbg = _G.MidnightUI_Debug or print
        dbg("|cffff5555[M+ LFG]|r Please select a dungeon")
        return
    end

    local dungeon = lfgState.selectedDungeon
    local level = lfgState.selectedLevel ~= "" and lfgState.selectedLevel or "?"
    local roles = {}
    for _, role in ipairs(ROLE_DEFS) do
        if lfgState.selectedRoles[role.key] then
            roles[#roles + 1] = role.label
        end
    end
    local rolesText = #roles > 0 and table.concat(roles, ", ") or "Any"

    -- Build addon message: LISTING|dungeon|level|roles|senderName
    local playerName = SafeCall(UnitName, "player") or "Unknown"
    local payload = "LISTING|" .. dungeon .. "|" .. level .. "|" .. rolesText .. "|" .. playerName

    -- Send via addon channel to guild
    if C_ChatInfo and C_ChatInfo.SendAddonMessage then
        pcall(C_ChatInfo.SendAddonMessage, LFG_PREFIX, payload, "GUILD")
    end

    -- Also send a guild chat message for non-MidnightUI users
    local chatMsg = "[M+ LFG] " .. dungeon .. " +" .. level .. " — LF: " .. rolesText .. " | Type !join " .. playerName .. " to sign up"
    pcall(SendChatMessage, chatMsg, "GUILD")

    -- Mark as hosting
    lfgState.hosting = true
    lfgState.applicants = {}

    -- Close overlay
    if lfgOverlay then lfgOverlay:Hide() end

    -- Show host panel
    Panel.ShowHostPanel(dungeon, level, rolesText)
end

-- ── Host Panel (shows applicants) ──
local hostPanel = nil

function Panel.ShowHostPanel(dungeon, level, rolesText)
    local R = Panel._refs
    if not R.panel then return end

    if not hostPanel then
        hostPanel = CreateFrame("Frame", nil, R.panel, "BackdropTemplate")
        hostPanel:SetSize(300, 200)
        hostPanel:SetPoint("CENTER", R.panel, "CENTER", 0, 0)
        hostPanel:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        hostPanel:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
        hostPanel:SetBackdropBorderColor(0.00, 0.78, 1.00, 0.3)
        hostPanel:SetFrameLevel(R.panel:GetFrameLevel() + 25)
        hostPanel:Hide()
    end

    -- Clear old content
    local old = { hostPanel:GetChildren() }
    for _, child in ipairs(old) do child:Hide() end
    local oldR = { hostPanel:GetRegions() }
    for _, region in ipairs(oldR) do region:Hide() end

    -- Rebuild
    hostPanel:SetBackdropColor(0.04, 0.04, 0.06, 0.97)
    hostPanel:SetBackdropBorderColor(0.00, 0.78, 1.00, 0.3)

    local title = hostPanel:CreateFontString(nil, "OVERLAY")
    TrySetFont(title, BODY_FONT, 10, "OUTLINE")
    title:SetPoint("TOP", hostPanel, "TOP", 0, -10)
    title:SetText("YOUR LISTING"); title:SetTextColor(0.00, 0.78, 1.00)
    title:Show()

    local infoFS = hostPanel:CreateFontString(nil, "OVERLAY")
    TrySetFont(infoFS, BODY_FONT, 11, "")
    infoFS:SetPoint("TOP", title, "BOTTOM", 0, -6)
    infoFS:SetText(dungeon .. "  |cff00c8ff+" .. level .. "|r  \194\183  " .. rolesText)
    infoFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    infoFS:Show()

    local waitFS = hostPanel:CreateFontString(nil, "OVERLAY")
    TrySetFont(waitFS, BODY_FONT, 10, "")
    waitFS:SetPoint("CENTER", hostPanel, "CENTER", 0, -10)
    waitFS:SetText("Waiting for applicants...")
    waitFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
    waitFS:Show()
    hostPanel._waitFS = waitFS
    hostPanel._applicantYOfs = 60

    -- Cancel button
    local cancelBtn = CreateFrame("Button", nil, hostPanel)
    cancelBtn:SetSize(80, 24); cancelBtn:SetPoint("BOTTOM", hostPanel, "BOTTOM", 0, 10)
    local cancelFS = cancelBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(cancelFS, BODY_FONT, 11, ""); cancelFS:SetPoint("CENTER")
    cancelFS:SetText("Cancel"); cancelFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
    cancelBtn:SetScript("OnClick", function()
        lfgState.hosting = false
        hostPanel:Hide()
        -- Notify guild that listing is cancelled
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, LFG_PREFIX, "CANCEL", "GUILD")
        end
    end)
    cancelBtn:SetScript("OnEnter", function() cancelFS:SetTextColor(1, 0.3, 0.3) end)
    cancelBtn:SetScript("OnLeave", function() cancelFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3]) end)

    hostPanel:Show()
end

-- ── Incoming LFG Notification (for guild members receiving a listing) ──
local lfgNotification = nil

ShowLFGNotification = function(sender, dungeon, level, roles)
    -- Don't show notification for your own listing
    local playerName = SafeCall(UnitName, "player") or ""
    if sender == playerName then return end

    if not lfgNotification then
        lfgNotification = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        lfgNotification:SetHeight(45)
        local messengerFrame = _G.MyMessengerFrame
        if messengerFrame then
            lfgNotification:SetPoint("BOTTOMLEFT", messengerFrame, "TOPLEFT", 0, 4)
            lfgNotification:SetPoint("BOTTOMRIGHT", messengerFrame, "TOPRIGHT", 0, 4)
        else
            lfgNotification:SetSize(420, 45)
            lfgNotification:SetPoint("BOTTOM", UIParent, "BOTTOM", 0, 220)
        end
        lfgNotification:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        lfgNotification:SetBackdropColor(0.04, 0.04, 0.07, 0.95)
        lfgNotification:SetBackdropBorderColor(0.00, 0.78, 1.00, 0.3)
        lfgNotification:SetFrameStrata("FULLSCREEN_DIALOG")
        lfgNotification:SetFrameLevel(500)
        lfgNotification:Hide()
    end

    -- Clear old dynamic content (not backdrop)
    local oldC = { lfgNotification:GetChildren() }
    for _, child in ipairs(oldC) do child:Hide() end
    -- Re-apply backdrop (in case it was cleared)
    lfgNotification:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    lfgNotification:SetBackdropColor(0.03, 0.03, 0.06, 0.92)
    lfgNotification:SetBackdropBorderColor(0.00, 0.60, 0.85, 0.3)

    -- Accent bar
    local accent = lfgNotification:CreateTexture(nil, "OVERLAY")
    accent:SetHeight(2); accent:SetPoint("TOPLEFT"); accent:SetPoint("TOPRIGHT")
    accent:SetColorTexture(0.00, 0.78, 1.00, 0.5)
    accent:Show()

    -- Icon
    local icon = lfgNotification:CreateTexture(nil, "ARTWORK")
    icon:SetSize(22, 22); icon:SetPoint("LEFT", lfgNotification, "LEFT", 10, 0)
    icon:SetTexture("Interface\\Icons\\INV_Relics_Hourglass")
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    icon:Show()

    -- Info text
    local infoFS = lfgNotification:CreateFontString(nil, "OVERLAY")
    TrySetFont(infoFS, BODY_FONT, 11, "")
    infoFS:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    local displayText = "|cff00c8ffM+|r  |cffffff00" .. sender .. "|r  " .. dungeon .. "  |cff00c8ff+" .. level .. "|r  \194\183  " .. roles
    infoFS:SetText(displayText)
    infoFS:SetTextColor(C.bodyText[1], C.bodyText[2], C.bodyText[3])
    infoFS:Show()

    -- Join button
    local joinBtn = CreateFrame("Button", nil, lfgNotification)
    joinBtn:SetSize(60, 26); joinBtn:SetPoint("RIGHT", lfgNotification, "RIGHT", -10, 0)
    local joinBg = joinBtn:CreateTexture(nil, "BACKGROUND")
    joinBg:SetAllPoints(); joinBg:SetColorTexture(0.00, 0.50, 0.70, 0.3)
    local joinFS = joinBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(joinFS, BODY_FONT, 11, "OUTLINE"); joinFS:SetPoint("CENTER")
    joinFS:SetText("Join"); joinFS:SetTextColor(0.00, 0.78, 1.00)
    -- Border
    local jT = joinBtn:CreateTexture(nil, "OVERLAY"); jT:SetHeight(1)
    jT:SetPoint("TOPLEFT"); jT:SetPoint("TOPRIGHT"); jT:SetColorTexture(0.00, 0.78, 1.00, 0.3)
    local jB = joinBtn:CreateTexture(nil, "OVERLAY"); jB:SetHeight(1)
    jB:SetPoint("BOTTOMLEFT"); jB:SetPoint("BOTTOMRIGHT"); jB:SetColorTexture(0.00, 0.78, 1.00, 0.3)
    local jL = joinBtn:CreateTexture(nil, "OVERLAY"); jL:SetWidth(1)
    jL:SetPoint("TOPLEFT"); jL:SetPoint("BOTTOMLEFT"); jL:SetColorTexture(0.00, 0.78, 1.00, 0.3)
    local jR = joinBtn:CreateTexture(nil, "OVERLAY"); jR:SetWidth(1)
    jR:SetPoint("TOPRIGHT"); jR:SetPoint("BOTTOMRIGHT"); jR:SetColorTexture(0.00, 0.78, 1.00, 0.3)

    joinBtn:SetScript("OnEnter", function() joinBg:SetColorTexture(0.00, 0.50, 0.70, 0.5) end)
    joinBtn:SetScript("OnLeave", function() joinBg:SetColorTexture(0.00, 0.50, 0.70, 0.3) end)

    local capturedSender = sender
    joinBtn:SetScript("OnClick", function()
        -- Send join request via addon message
        local myName = SafeCall(UnitName, "player") or "Unknown"
        local _, myClass = SafeCall(UnitClass, "player")
        local specIdx = SafeCall(GetSpecialization)
        local mySpec = ""
        if specIdx then
            local _, sName = SafeCall(GetSpecializationInfo, specIdx)
            mySpec = sName or ""
        end
        local myLevel = SafeCall(UnitLevel, "player") or 0

        local joinPayload = "JOIN|" .. capturedSender .. "|" .. myName .. "|" .. (myClass or "") .. "|" .. mySpec .. "|" .. myLevel
        if C_ChatInfo and C_ChatInfo.SendAddonMessage then
            pcall(C_ChatInfo.SendAddonMessage, LFG_PREFIX, joinPayload, "GUILD")
        end

        -- Update button to show "Requested"
        joinFS:SetText("Sent!")
        joinBg:SetColorTexture(0.15, 0.40, 0.15, 0.3)
        joinBtn:SetScript("OnClick", nil)
    end)

    -- Dismiss button
    local dismissBtn = CreateFrame("Button", nil, lfgNotification)
    dismissBtn:SetSize(16, 16); dismissBtn:SetPoint("RIGHT", joinBtn, "LEFT", -6, 0)
    local dismissFS = dismissBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(dismissFS, BODY_FONT, 11, "OUTLINE"); dismissFS:SetPoint("CENTER")
    dismissFS:SetText("X"); dismissFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.4)
    dismissBtn:SetScript("OnClick", function() lfgNotification:Hide() end)
    dismissBtn:SetScript("OnEnter", function() dismissFS:SetTextColor(1, 0.3, 0.3) end)
    dismissBtn:SetScript("OnLeave", function() dismissFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3], 0.4) end)

    lfgNotification:Show()
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
end

-- ── Addon Message Handler ──
local lfgMsgEvf = CreateFrame("Frame")
lfgMsgEvf:RegisterEvent("CHAT_MSG_ADDON")
lfgMsgEvf:RegisterEvent("CHAT_MSG_GUILD")
lfgMsgEvf:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4)
    if event == "CHAT_MSG_ADDON" then
        local prefix, message, channel, sender = arg1, arg2, arg3, arg4
        if prefix ~= LFG_PREFIX or channel ~= "GUILD" then return end
        local shortSender = sender:match("^([^%-]+)") or sender

        local cmd = message:match("^(%a+)|")
        if cmd == "LISTING" then
            local _, dungeon, level, roles, hostName = strsplit("|", message)
            if dungeon and level then
                ShowLFGNotification(hostName or shortSender, dungeon, level, roles or "Any")
            end
        elseif cmd == "JOIN" then
            local _, targetHost, applicantName, applicantClass, applicantSpec, applicantLevel = strsplit("|", message)
            local playerName = SafeCall(UnitName, "player") or ""
            if targetHost == playerName and lfgState.hosting then
                lfgState.applicants[#lfgState.applicants + 1] = {
                    name = applicantName or shortSender,
                    class = applicantClass or "",
                    spec = applicantSpec or "",
                    level = tonumber(applicantLevel) or 0,
                    timestamp = date("%H:%M"),
                }
                Panel.RefreshHostApplicants()
                pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
            end
        elseif cmd == "CANCEL" then
            if lfgNotification and lfgNotification:IsShown() then
                lfgNotification:Hide()
            end
        end

    elseif event == "CHAT_MSG_GUILD" then
        -- Listen for "!join PlayerName" from non-MidnightUI users
        local msg, sender = arg1, arg2
        if not msg or not sender then return end
        local trimmed = msg:match("^%s*(.-)%s*$") or msg
        local lower = trimmed:lower()

        -- Match: "!join HostName" or just "!join" (if only one listing active)
        local joinTarget = lower:match("^!join%s+(%S+)")
        local isJoinCmd = lower:match("^!join") ~= nil

        if isJoinCmd and lfgState.hosting then
            local playerName = SafeCall(UnitName, "player") or ""
            local shortSender = sender:match("^([^%-]+)") or sender

            -- If they specified a name, match against host (short name, case-insensitive)
            -- Handles: !join Mesden, !join mesden, !join Mesden-Sargeras
            if joinTarget then
                local targetShort = joinTarget:match("^([^%-]+)") or joinTarget
                if targetShort ~= playerName:lower() then return end
            end

            -- Don't add yourself
            if shortSender ~= playerName then
                -- Check if already applied
                local alreadyApplied = false
                for _, app in ipairs(lfgState.applicants) do
                    if app.name == shortSender then alreadyApplied = true; break end
                end
                if not alreadyApplied then
                    lfgState.applicants[#lfgState.applicants + 1] = {
                        name = shortSender,
                        class = "",  -- unknown for non-addon users
                        spec = "",
                        level = 0,
                        timestamp = date("%H:%M"),
                        fromChat = true,  -- flag that this came from guild chat, not addon
                    }
                    Panel.RefreshHostApplicants()
                    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
                end
            end
        end
    end
end)

function Panel.RefreshHostApplicants()
    if not hostPanel or not hostPanel:IsShown() then return end
    if hostPanel._waitFS then hostPanel._waitFS:Hide() end

    -- Clear old applicant rows
    if hostPanel._appRows then
        for _, row in ipairs(hostPanel._appRows) do row:Hide() end
    end
    hostPanel._appRows = {}

    local yOfs = hostPanel._applicantYOfs or 60
    for _, app in ipairs(lfgState.applicants) do
        local r, g, b = GetClassColor(app.class)
        if app.class == "" then r, g, b = 0.75, 0.75, 0.75 end  -- unknown class (chat-only)

        local row = CreateFrame("Frame", nil, hostPanel)
        row:SetHeight(28)
        row:SetPoint("TOPLEFT", hostPanel, "TOPLEFT", 10, -yOfs)
        row:SetPoint("RIGHT", hostPanel, "RIGHT", -10, 0)

        -- Timestamp
        local tsFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(tsFS, BODY_FONT, 9, "")
        tsFS:SetPoint("LEFT", row, "LEFT", 0, 0)
        tsFS:SetText(app.timestamp or "")
        tsFS:SetTextColor(0.50, 0.50, 0.55)

        -- Player info
        local infoText = app.name
        if app.spec and app.spec ~= "" then
            infoText = infoText .. "  |cffaaaaaa" .. app.spec .. "|r"
        end
        if app.level and app.level > 0 then
            infoText = infoText .. "  |cffaaaaaa" .. app.level .. "|r"
        end
        if app.fromChat then
            infoText = infoText .. "  |cff666666(via chat)|r"
        end

        local nameFS = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFS, BODY_FONT, 11, "")
        nameFS:SetPoint("LEFT", tsFS, "RIGHT", 8, 0)
        nameFS:SetText(infoText)
        nameFS:SetTextColor(r, g, b)

        -- Invite button
        local invBtn = CreateFrame("Button", nil, row)
        invBtn:SetSize(50, 20); invBtn:SetPoint("RIGHT", row, "RIGHT", 0, 0)
        local invBg = invBtn:CreateTexture(nil, "BACKGROUND")
        invBg:SetAllPoints(); invBg:SetColorTexture(0.15, 0.40, 0.15, 0.3)
        local invFS = invBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(invFS, BODY_FONT, 10, ""); invFS:SetPoint("CENTER")
        invFS:SetText("Invite"); invFS:SetTextColor(0.3, 0.9, 0.3)
        local capturedName = app.name
        invBtn:SetScript("OnClick", function()
            pcall(InviteUnit, capturedName)
            invFS:SetText("Invited"); invFS:SetTextColor(C.mutedText[1], C.mutedText[2], C.mutedText[3])
            invBg:SetColorTexture(0.15, 0.15, 0.15, 0.2)
            invBtn:SetScript("OnClick", nil)
        end)
        invBtn:SetScript("OnEnter", function() invBg:SetColorTexture(0.20, 0.50, 0.20, 0.4) end)
        invBtn:SetScript("OnLeave", function() invBg:SetColorTexture(0.15, 0.40, 0.15, 0.3) end)

        -- Decline button
        local decBtn = CreateFrame("Button", nil, row)
        decBtn:SetSize(16, 16); decBtn:SetPoint("RIGHT", invBtn, "LEFT", -4, 0)
        local decFS = decBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(decFS, BODY_FONT, 10, "OUTLINE"); decFS:SetPoint("CENTER")
        decFS:SetText("X"); decFS:SetTextColor(0.6, 0.2, 0.2, 0.5)
        decBtn:SetScript("OnEnter", function() decFS:SetTextColor(1, 0.3, 0.3) end)
        decBtn:SetScript("OnLeave", function() decFS:SetTextColor(0.6, 0.2, 0.2, 0.5) end)
        local capturedIdx = #lfgState.applicants
        decBtn:SetScript("OnClick", function()
            table.remove(lfgState.applicants, capturedIdx)
            Panel.RefreshHostApplicants()
        end)

        row:Show()
        hostPanel._appRows[#hostPanel._appRows + 1] = row
        yOfs = yOfs + 30
    end

    if #lfgState.applicants == 0 and hostPanel._waitFS then
        hostPanel._waitFS:Show()
    end

    hostPanel:SetHeight(math.max(yOfs + 40, 200))
end

-- ── Test command: /mpt to simulate M+ guild chat messages ──
-- /mpta — simulate an applicant joining your listing
SLASH_MPLUSAPPA1 = "/mpta"
SlashCmdList["MPLUSAPPA"] = function(arg)
    if not lfgState.hosting then
        local dbg = _G.MidnightUI_Debug or print
        dbg("|cffff5555[M+ Test]|r You need an active listing first. Click the keystone icon and send a listing.")
        return
    end
    local names = { "Healbot", "Stabsworth", "Tankmaster", "Dreadjitsu", "Twistmytwig" }
    local classes = { "PRIEST", "ROGUE", "WARRIOR", "MONK", "DRUID" }
    local specs = { "Holy", "Assassination", "Protection", "Brewmaster", "Balance" }
    local idx = tonumber(arg) or math.random(1, #names)
    idx = math.max(1, math.min(#names, idx))
    lfgState.applicants[#lfgState.applicants + 1] = {
        name = names[idx],
        class = classes[idx],
        spec = specs[idx],
        level = 80,
        timestamp = date("%H:%M"),
    }
    Panel.RefreshHostApplicants()
    pcall(PlaySound, SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081)
end

-- /mpt — simulate receiving an LFG notification
SLASH_MPLUSTEST1 = "/mpt"
SlashCmdList["MPLUSTEST"] = function(arg)
    local tests = {
        { sender = "Healbot",      dungeon = "Skyreach",              level = "15", roles = "Tank, DPS" },
        { sender = "Stabsworth",   dungeon = "Windrunner Spire",      level = "12", roles = "Healer" },
        { sender = "Tankmaster",   dungeon = "Magisters' Terrace",    level = "20", roles = "DPS, DPS" },
        { sender = "Dreadjitsu",   dungeon = "Nexus-Point Xenas",     level = "8",  roles = "Tank, Healer, DPS" },
    }
    local idx = tonumber(arg) or math.random(1, #tests)
    idx = math.max(1, math.min(#tests, idx))
    local test = tests[idx]
    local dbg = _G.MidnightUI_Debug or print
    dbg("|cff00c8ff[M+ Test]|r Simulating LFG notification from: " .. test.sender)
    ShowLFGNotification(test.sender, test.dungeon, test.level, test.roles)
end

-- Export theme colors for other modules (GuildRecruit, etc.)
Panel._theme = C

-- Export for Messenger right-click (use different name to not overwrite the frame global)
_G.MidnightUI_GuildPanelAPI = Panel

