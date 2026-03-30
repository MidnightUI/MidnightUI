-- =============================================================================
-- FILE PURPOSE:     Full group finder panel replacing Blizzard's PVEFrame. Provides
--                   three tabs: Dungeon Finder (role queue with lockout display), Raid
--                   Finder (wing list with loot), and Premade Groups (C_LFGList search
--                   results with MPI score integration per applicant/listing). Themed
--                   to match the MidnightUI warm-dark aesthetic.
-- LOAD ORDER:       Loads after GuildRecruit.lua, before db/mpi_sync.lua (db files).
--                   Standalone file — no Addon vararg namespace, no early-exit guard.
-- DEFINES:          "MidnightGroupFinder" frame (hook on PVEFrame:Show / LFGFrame:Show).
--                   CreateDropShadow() — local multi-layer shadow helper (self-contained,
--                   intentional duplicate from other panel files — no shared helper).
--                   Forward declarations: TC, activeTheme, GetActiveTheme,
--                   StartAutoRefresh, StopAutoRefresh.
-- READS:            C_LFGList.Search, C_LFGList.GetSearchResults — premade group search.
--                   C_MythicPlus.GetCurrentAffixes, C_ChallengeMode.GetMapTable — dungeon info.
--                   MidnightUI_MPI (SavedVariable via MidnightPI.lua) — reads scores for
--                   applicants when reviewing premade group listings.
--                   MidnightUISettings.General.characterPanelTheme — shared theme key.
--                   GetAverageItemLevel, C_PlayerInfo — player context for queue eligibility.
-- WRITES:           Nothing persistent. LFG queue actions via C_LFGList (JoinSearch, Leave).
-- DEPENDS ON:       C_LFGList, C_MythicPlus, C_ChallengeMode (Blizzard APIs).
--                   MidnightPI.lua (MidnightUI_MPI SavedVariable) — loaded before this file
--                   via the db/ chain, but MPI scoring writes happen in MidnightPI.lua.
-- USED BY:          MidnightPI.lua — reads GroupFinder's applicant list frames to overlay
--                   MPI scores on listing rows.
-- KEY FLOWS:
--   PVEFrame:Show hook → open MidnightGroupFinder, hide PVEFrame
--   Tab click (Dungeon/Raid/Premade) → switch active content panel
--   Premade tab: Search button → C_LFGList.Search → LFG_LIST_SEARCH_RESULTS_RECEIVED
--   LFG_LIST_SEARCH_RESULTS_RECEIVED → populate listing rows → overlay MPI scores
--   Dungeon Finder: Role toggle buttons → track selected roles → JoinBattlefieldForGroup
--   Applicant row hover → GameTooltip with MPI dimension breakdown
-- GOTCHAS:
--   C_PvP.JoinBattlefield is protected in 12.0 — the PVP tab has been removed and
--   hands off to Blizzard's native UI. Any dead PVP code in this file is a no-op.
--   StartAutoRefresh/StopAutoRefresh are forward-declared and implemented as no-ops
--   for callers that reference them before the implementation is defined.
--   CreateDropShadow is intentionally self-contained (not imported from Core/helpers)
--   to keep this file loadable independently for testing.
-- NAVIGATION:
--   CreateDropShadow()  — multi-layer shadow helper (line ~64)
--   Tab system          — dungeon/raid/premade tab switch (search "Tab click" or "activeTab")
--   MPI overlay         — score display on listing rows (search "MPI" or "MidnightUI_MPI")
-- =============================================================================

local ADDON_NAME = "MidnightUI"
local W8 = "Interface\\Buttons\\WHITE8X8"
local TITLE_FONT = "Fonts\\FRIZQT__.TTF"
local BODY_FONT  = "Fonts\\FRIZQT__.TTF"

-- ============================================================================
-- S1  UPVALUES
-- ============================================================================
local pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber =
      pcall, type, pairs, ipairs, math, string, table, select, tostring, tonumber
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local hooksecurefunc = hooksecurefunc
local PlaySound = PlaySound
local C_Timer = C_Timer
local C_LFGList = C_LFGList
local C_MythicPlus = C_MythicPlus
local C_ChallengeMode = C_ChallengeMode
local C_PlayerInfo = C_PlayerInfo
local GetAverageItemLevel = GetAverageItemLevel

-- ============================================================================
-- S2  HELPERS
-- ============================================================================
-- Forward declarations (defined later)
local TC
local activeTheme
local GetActiveTheme
local StartAutoRefresh  -- kept as no-op for callers
local StopAutoRefresh

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, r1, r2, r3, r4, r5 = pcall(fn, ...)
    if not ok then return nil end
    return r1, r2, r3, r4, r5
end

local function TrySetFont(fs, fontPath, size, flags)
    if not fs or not fs.SetFont then return end
    pcall(fs.SetFont, fs, fontPath or TITLE_FONT, size or 12, flags or "")
end

local function FormatNumber(n)
    if not n or type(n) ~= "number" then return "0" end
    n = math.floor(n + 0.5)
    local formatted = tostring(n)
    while true do
        local k
        formatted, k = string.gsub(formatted, "^(-?%d+)(%d%d%d)", "%1,%2")
        if k == 0 then break end
    end
    return formatted
end

local function CreateDropShadow(frame, intensity)
    intensity = intensity or 6
    local shadows = {}
    for i = 1, intensity do
        local s = CreateFrame("Frame", nil, frame)
        s:SetFrameLevel(math.max(0, frame:GetFrameLevel() - 1))
        local offset = i * 0.8
        local alpha = (0.18 - (i * 0.025)) * (intensity / 6)
        s:SetPoint("TOPLEFT", frame, "TOPLEFT", -offset, offset)
        s:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", offset, -offset)
        local t = s:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0, 0, 0, alpha)
        shadows[#shadows + 1] = s
    end
    return shadows
end

local function CreateGlassPanel(parent, width)
    local glass = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    glass:SetWidth(width)
    glass:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    glass:SetBackdropColor(TC("glassBg"))
    glass:SetBackdropBorderColor(TC("glassBorder"))

    -- Outer shadow (extends beyond frame bounds for soft halo)
    for i = 1, 3 do
        local sh = glass:CreateTexture(nil, "BACKGROUND", nil, -1)
        local off = i * 1.2
        local alpha = 0.06 - (i * 0.015)
        sh:SetPoint("TOPLEFT", glass, "TOPLEFT", -off, off)
        sh:SetPoint("BOTTOMRIGHT", glass, "BOTTOMRIGHT", off, -off)
        sh:SetColorTexture(0, 0, 0, math.max(0.01, alpha))
    end

    -- Frost highlight at top (wider, gradient fade L→R)
    local frost = glass:CreateTexture(nil, "OVERLAY", nil, 3)
    frost:SetHeight(2)
    frost:SetPoint("TOPLEFT", glass, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", glass, "TOPRIGHT", -1, -1)
    frost:SetTexture(W8)
    if frost.SetGradient and CreateColor then
        frost:SetGradient("HORIZONTAL",
            CreateColor(1, 1, 1, 0.02),
            CreateColor(1, 1, 1, 0.06))
    else
        frost:SetColorTexture(1, 1, 1, 0.06)
    end
    glass._frost = frost

    -- Inner gradient (top-to-bottom darkening)
    local grad = glass:CreateTexture(nil, "BACKGROUND", nil, 1)
    grad:SetPoint("TOPLEFT", 1, -1)
    grad:SetPoint("BOTTOMRIGHT", -1, 1)
    grad:SetTexture(W8)
    if grad.SetGradient and CreateColor then
        grad:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0.12),
            CreateColor(0, 0, 0, 0))
    end
    glass._grad = grad

    -- Bottom inner shadow (panel thickness)
    local botShadow = glass:CreateTexture(nil, "BACKGROUND", nil, 2)
    botShadow:SetHeight(6)
    botShadow:SetPoint("BOTTOMLEFT", glass, "BOTTOMLEFT", 1, 1)
    botShadow:SetPoint("BOTTOMRIGHT", glass, "BOTTOMRIGHT", -1, 1)
    botShadow:SetTexture(W8)
    if botShadow.SetGradient and CreateColor then
        botShadow:SetGradient("VERTICAL",
            CreateColor(0, 0, 0, 0.10),
            CreateColor(0, 0, 0, 0))
    end
    glass._botShadow = botShadow

    -- Accent wash (very subtle theme tint)
    local acWash = glass:CreateTexture(nil, "BACKGROUND", nil, 0)
    acWash:SetPoint("TOPLEFT", 1, -1)
    acWash:SetPoint("BOTTOMRIGHT", -1, 1)
    acWash:SetTexture(W8)
    local aR, aG, aB = TC("accent")
    if acWash.SetGradient and CreateColor then
        acWash:SetGradient("VERTICAL",
            CreateColor(aR, aG, aB, 0),
            CreateColor(aR, aG, aB, 0.02))
    end
    glass._acWash = acWash

    function glass:ApplyTheme()
        self:SetBackdropColor(TC("glassBg"))
        self:SetBackdropBorderColor(TC("glassBorder"))
        local ar, ag, ab = TC("accent")
        if self._acWash and self._acWash.SetGradient and CreateColor then
            self._acWash:SetGradient("VERTICAL",
                CreateColor(ar, ag, ab, 0),
                CreateColor(ar, ag, ab, 0.02))
        end
    end

    return glass
end

local function ApplyGradient(tex, dir, r1, g1, b1, a1, r2, g2, b2, a2)
    if tex and tex.SetGradient and CreateColor then
        tex:SetTexture(W8)
        tex:SetGradient(dir,
            CreateColor(r1, g1, b1, a1),
            CreateColor(r2, g2, b2, a2))
        return true
    end
    return false
end

local function GenerateAbbreviation(name)
    if not name or name == "" then return "??" end
    local parts = {}
    for token in name:gmatch("[%w']+") do
        parts[#parts + 1] = token
    end
    local skip = { ["the"] = true, ["of"] = true, ["a"] = true, ["an"] = true }
    local abbr = ""
    for i, w in ipairs(parts) do
        local lower = w:lower()
        if skip[lower] then
            if i > 1 then abbr = abbr .. w:sub(1, 1):lower() end
        else
            abbr = abbr .. w:sub(1, 1):upper()
        end
    end
    if #abbr > 5 then abbr = abbr:sub(1, 5) end
    if #abbr <= 1 then
        for _, w in ipairs(parts) do
            if not skip[w:lower()] then
                abbr = w:sub(1, 3):upper()
                break
            end
        end
    end
    if #abbr == 0 then abbr = name:sub(1, 2):upper() end
    return abbr
end

local ACCENT_PALETTE = {
    { 0.80, 0.30, 0.30 }, -- red
    { 0.30, 0.70, 0.40 }, -- green
    { 0.40, 0.50, 0.90 }, -- blue
    { 0.65, 0.40, 0.85 }, -- purple
    { 0.85, 0.65, 0.20 }, -- gold
    { 0.20, 0.75, 0.80 }, -- teal
    { 0.90, 0.55, 0.25 }, -- orange
    { 0.45, 0.70, 0.95 }, -- sky
    { 0.85, 0.35, 0.60 }, -- pink
    { 0.55, 0.80, 0.35 }, -- lime
    { 0.70, 0.55, 0.35 }, -- bronze
    { 0.50, 0.40, 0.70 }, -- indigo
}

local function GenerateDungeonAccent(mapID)
    local idx = (mapID % #ACCENT_PALETTE) + 1
    return ACCENT_PALETTE[idx]
end

-- Known abbreviations for current season (fallback to auto-generation for future seasons)
local KNOWN_ABBREVS = {
    ["Magisters' Terrace"]          = "MT",
    ["Maisara Caverns"]             = "MC",
    ["Nexus-Point Xenas"]           = "NPX",
    ["Windrunner Spire"]            = "WS",
    ["Den of Nalorakk"]             = "DoN",
    ["The Blinding Vale"]           = "BV",
    ["Murder Row"]                  = "MR",
    ["Voidscar Arena"]              = "VA",
    ["Algeth'ar Academy"]           = "AA",
    ["The Seat of the Triumvirate"] = "SotT",
    ["Skyreach"]                    = "SR",
    ["Pit of Saron"]                = "PoS",
}

local function ExtractKeyLevel(name)
    if not name then return nil end
    -- "+15", "+03"
    local level = tonumber(name:match("%+(%d+)"))
    if level and level >= 2 and level <= 40 then return level end
    -- "Mythic 15", "mythic 03", "Mythic+ 8"
    level = tonumber(name:match("[Mm]ythic%+?%s*(%d+)"))
    if level and level >= 2 and level <= 40 then return level end
    -- Leading bare number: "15 Priory", "03 Stonevault"
    level = tonumber(name:match("^(%d+)"))
    if level and level >= 2 and level <= 40 then return level end
    return nil
end

local function ResolveActivityName(info)
    if info._activityName then return info._activityName end
    local actIDs = info.activityIDs
    local resolvedID = type(actIDs) == "number" and actIDs or (type(actIDs) == "table" and actIDs[1])
    if resolvedID and C_LFGList and C_LFGList.GetActivityInfoTable then
        local aOk, aInfo = pcall(C_LFGList.GetActivityInfoTable, resolvedID)
        if aOk and aInfo then
            if aInfo.fullName and aInfo.fullName ~= "" then
                info._activityName = aInfo.fullName
                return aInfo.fullName
            end
            if aInfo.shortName and aInfo.shortName ~= "" then
                info._activityName = aInfo.shortName
                return aInfo.shortName
            end
        end
    end
    info._activityName = info.name or ""
    return info._activityName
end

local function FormatTimeAgo(seconds)
    if not seconds or seconds < 0 then return "" end
    if seconds < 60 then return "<1m" end
    local mins = math.floor(seconds / 60)
    if mins < 60 then return mins .. "m" end
    return math.floor(mins / 60) .. "h"
end

local function TrySetAtlasFromList(tex, atlasList)
    if not tex or not atlasList then return false end
    for _, atlasName in ipairs(atlasList) do
        local ok = pcall(tex.SetAtlas, tex, atlasName, false)
        if ok then return true end
    end
    return false -- fallback: leave transparent
end

-- Per-tab atlas texture name lists (tried in order, first success wins)
local HERO_ATLASES = {
    dungeons = {
        "groupfinder-background-dungeons",
        "completiondialog-midnightcampaign-background",
    },
    raids = {
        "UI-EJ-BOSS-Default",
        "groupfinder-background-raids",
        "completiondialog-midnightcampaign-background",
    },
    premade = {
        "groupfinder-background-quests",
        "groupfinder-background-arena",
        "completiondialog-midnightcampaign-background",
    },
}

-- ============================================================================
-- S3  COLOR THEMES
-- ============================================================================
local THEMES = {
    parchment = {
        key         = "parchment",
        frameBg     = { 0.04, 0.035, 0.025, 0.97 },
        modelBg     = { 0.03, 0.03, 0.04, 1.0 },
        headerBg    = { 0.05, 0.04, 0.025, 0.95 },
        heroBg      = { 0.06, 0.05, 0.03, 0.85 },
        glassBg     = { 0.04, 0.04, 0.06, 0.70 },
        glassBorder = { 1, 1, 1, 0.04 },
        surfaceBg   = { 0.06, 0.055, 0.045, 0.55 },
        shadowColor = { 0, 0, 0, 0.12 },
        hoverBg     = { 0.72, 0.62, 0.42, 0.06 },
        activeBg    = { 0.72, 0.62, 0.42, 0.10 },
        accent      = { 0.72, 0.62, 0.42 },
        titleText   = { 0.96, 0.87, 0.58 },
        bodyText    = { 0.94, 0.90, 0.80 },
        mutedText   = { 0.71, 0.62, 0.44 },
        divider     = { 0.60, 0.52, 0.35 },
        tabActive   = { 0.96, 0.87, 0.58 },
        tabInactive = { 0.52, 0.46, 0.34 },
    },
    midnight = {
        key         = "midnight",
        frameBg     = { 0.03, 0.04, 0.07, 0.97 },
        modelBg     = { 0.02, 0.025, 0.04, 1.0 },
        headerBg    = { 0.025, 0.03, 0.06, 0.95 },
        heroBg      = { 0.035, 0.045, 0.08, 0.85 },
        glassBg     = { 0.03, 0.04, 0.08, 0.70 },
        glassBorder = { 1, 1, 1, 0.03 },
        surfaceBg   = { 0.05, 0.06, 0.10, 0.55 },
        shadowColor = { 0, 0, 0, 0.15 },
        hoverBg     = { 0.00, 0.78, 1.00, 0.06 },
        activeBg    = { 0.00, 0.78, 1.00, 0.10 },
        accent      = { 0.00, 0.78, 1.00 },
        titleText   = { 0.92, 0.93, 0.96 },
        bodyText    = { 0.82, 0.84, 0.88 },
        mutedText   = { 0.58, 0.60, 0.65 },
        divider     = { 0.35, 0.40, 0.50 },
        tabActive   = { 0.92, 0.93, 0.96 },
        tabInactive = { 0.45, 0.48, 0.55 },
    },
    class = {
        key         = "class",
        frameBg     = { 0.04, 0.035, 0.025, 0.97 },
        modelBg     = { 0.03, 0.03, 0.04, 1.0 },
        headerBg    = { 0.05, 0.04, 0.025, 0.95 },
        heroBg      = { 0.06, 0.05, 0.03, 0.85 },
        glassBg     = { 0.04, 0.04, 0.06, 0.70 },
        glassBorder = { 1, 1, 1, 0.04 },
        surfaceBg   = { 0.06, 0.055, 0.045, 0.55 },
        shadowColor = { 0, 0, 0, 0.12 },
        hoverBg     = { 0.72, 0.62, 0.42, 0.06 },
        activeBg    = { 0.72, 0.62, 0.42, 0.10 },
        accent      = { 0.72, 0.62, 0.42 }, -- overridden at runtime
        titleText   = { 0.94, 0.92, 0.88 },
        bodyText    = { 0.92, 0.90, 0.85 },
        mutedText   = { 0.65, 0.62, 0.55 },
        divider     = { 0.50, 0.48, 0.40 },
        tabActive   = { 0.94, 0.92, 0.88 },
        tabInactive = { 0.50, 0.48, 0.42 },
    },
}

activeTheme = THEMES.parchment

GetActiveTheme = function()
    local s = _G.MidnightUISettings
    local key = (s and s.General and s.General.characterPanelTheme) or "parchment"
    local t = THEMES[key] or THEMES.parchment
    if key == "class" then
        local cc = _G.MidnightUI_Core and _G.MidnightUI_Core.GetClassColorTable
            and _G.MidnightUI_Core.GetClassColorTable("player")
        if cc then
            local ar = cc.r or cc[1] or 0.72
            local ag = cc.g or cc[2] or 0.62
            local ab = cc.b or cc[3] or 0.42
            t.accent  = { ar, ag, ab }
            t.hoverBg = { ar, ag, ab, 0.06 }
            t.activeBg = { ar, ag, ab, 0.10 }
        end
    end
    activeTheme = t
    return t
end

TC = function(key)
    local c = activeTheme[key]
    if not c then return 1, 1, 1, 1 end
    return c[1], c[2], c[3], c[4] or 1
end

-- ============================================================================
-- S4  CONFIGURATION
-- ============================================================================
local CFG = {
    WIDTH           = 1200,
    HEIGHT          = 780,
    HEADER_H        = 44,
    TAB_BAR_H       = 32,
    HERO_H          = 130,
    STRATA          = "HIGH",
    PAD             = 16,
    SCORE_CAP       = 3000,
    -- Premade Groups layout
    CAT_SIDEBAR_W   = 160,
    PLAYER_SIDEBAR_W = 260,
    FILTER_BAR_H    = 36,
    SORT_HEADER_H   = 24,
    ROW_H           = 52,
    ROW_POOL_SIZE   = 20,
    DETAIL_PANEL_H  = 300,
    SEARCH_INPUT_W  = 160,
}

-- ============================================================================
-- S5  PANEL STATE
-- ============================================================================
local Panel = {}
Panel._state = {
    initialized     = false,
    panelOpen       = false,
    activeTab       = "premade",  -- default to premade groups
    activeCategory  = "mythicplus",
    filters         = { dungeon = nil, keyMin = nil, keyMax = nil, role = nil, minMPI = nil },
    searchResults   = {},
    selectedResult  = nil,
    detailOpen      = false,
    sortKey         = nil,
    sortAsc         = true,
    lastSearchTime  = nil,
    prevAppStatuses = {},
    pvpCategory     = "quickmatch",
    pvpRoles        = { tank = false, healer = false, dps = false },
    pvpSelectedActivity = nil,
}
Panel._refs = {} -- UI element references

-- Stale timer stubs (kept as no-ops so callers don't error)
StartAutoRefresh = function() end
StopAutoRefresh  = function() end

-- ============================================================================
-- S6  MPI SCORE LOOKUP
-- ============================================================================
local mpiCache = {}
local MPI_CACHE_TTL = 60

--- Look up a player's MPI score by name. Checks personal DB first, then community.
-- @return profile table or nil (has .avgMPI, .trend, .badges, etc.)
local function GetCachedMPIProfile(name)
    if not name or name == "" then return nil end
    local cached = mpiCache[name]
    if cached and (GetTime() - cached.time) < MPI_CACHE_TTL then
        return cached.profile
    end
    local profile = nil
    local PI = _G.MidnightPI
    if PI then
        -- Try personal observations first
        profile = PI.GetProfileByName and PI.GetProfileByName(name)
        -- Fall back to community DB
        if not profile and PI.CommunityLookup then
            local pName, pRealm = name:match("^([^%-]+)%-(.+)$")
            if not pName then
                pName = name
                pRealm = GetRealmName and GetRealmName() or ""
            end
            profile = PI.CommunityLookup(pName, pRealm)
        end
    end
    mpiCache[name] = { profile = profile, time = GetTime() }
    return profile
end

--- Get tier-colored r,g,b for an MPI score (0-100).
local function GetMPIScoreColor(score)
    if not score then return 0.5, 0.5, 0.5 end
    local PI = _G.MidnightPI
    if PI and PI.GetScoreTier then
        local _, r, g, b = PI.GetScoreTier(score)
        return r, g, b
    end
    return 0.5, 0.5, 0.5
end

-- ============================================================================
-- S6b  DYNAMIC DATA LOADING
-- ============================================================================
-- Season dungeons loaded from Blizzard API at runtime — no hardcoded lists.
-- KNOWN_ABBREVS (defined in S2) provides nice abbreviations for current season;
-- GenerateAbbreviation handles any future season automatically.

-- Build a lookup from dungeon name → LFG dungeon ID for heroic difficulty.
-- C_ChallengeMode.GetMapTable returns challenge-mode map IDs which are NOT the
-- same as LFG dungeon IDs.  JoinSingleLFG needs LFG IDs to queue correctly.
local function BuildNameToLFGID()
    local map = {}
    if not GetLFGDungeonInfo then return map end
    for id = 1, 3500 do
        local ok, name, _, subtypeID, _, _, _, _, _,
              _, _, _, difficulty = pcall(GetLFGDungeonInfo, id)
        -- subtypeID 1 = normal dungeon, difficulty 1 = normal
        if ok and name and name ~= "" and subtypeID == 1 and difficulty == 1 then
            map[name] = id
        end
    end
    return map
end

local function LoadSeasonDungeons()
    local dungeons = {}
    local lfgMap = BuildNameToLFGID()
    if C_ChallengeMode and C_ChallengeMode.GetMapTable then
        local ok, maps = pcall(C_ChallengeMode.GetMapTable)
        if ok and maps then
            for _, mapID in ipairs(maps) do
                local ok2, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
                if ok2 and name and name ~= "" then
                    local abbr = KNOWN_ABBREVS[name] or GenerateAbbreviation(name)
                    local accent = GenerateDungeonAccent(mapID)
                    dungeons[#dungeons + 1] = {
                        mapID        = mapID,
                        name         = name,
                        abbr         = abbr,
                        accent       = accent,
                        lfgDungeonID = lfgMap[name],
                    }
                end
            end
        end
    end
    if #dungeons == 0 then
        dungeons[1] = { mapID = 0, name = "No Dungeons Available", abbr = "--", accent = {0.5, 0.5, 0.5} }
    end
    return dungeons
end

-- Build dropdown list: "All Dungeons" + each season dungeon name
local function BuildDungeonDropdownList(dungeons)
    local list = { "All Dungeons" }
    for _, d in ipairs(dungeons) do
        list[#list + 1] = d.name
    end
    return list
end

-- Load follower dungeon data using C_LFGInfo.IsLFGFollowerDungeon (12.0+).
-- Only includes actual 5-man follower dungeons (difficulty 205).
-- Level eligibility is checked dynamically in UpdateFollowerCardVisibility.
local function LoadFollowerDungeons()
    local dungeons = {}
    if not C_LFGInfo or not C_LFGInfo.IsLFGFollowerDungeon then return dungeons end
    if not GetLFGDungeonInfo then return dungeons end

    local seen = {}
    for id = 1, 3500 do
        local ok, isFollower = pcall(C_LFGInfo.IsLFGFollowerDungeon, id)
        if ok and isFollower then
            local ok2, name, _, _,
                  minLevel, maxLevel, _, _, _,
                  expansionLevel, _, _, difficulty, _, _, _, _, _, _, _,
                  instanceMapID = pcall(GetLFGDungeonInfo, id)
            -- difficulty 205 = true follower dungeons (not Delves/Visions/bosses)
            if ok2 and name and name ~= "" and difficulty == 205 and not seen[name] then
                seen[name] = true
                dungeons[#dungeons + 1] = {
                    dungeonID  = id,
                    mapID      = instanceMapID or id,
                    name       = name,
                    abbr       = KNOWN_ABBREVS[name] or GenerateAbbreviation(name),
                    accent     = GenerateDungeonAccent(instanceMapID or id),
                    isFollower = true,
                    expansion  = expansionLevel,
                    minLevel   = minLevel or 0,
                    maxLevel   = maxLevel or 0,
                }
            end
        end
    end

    -- Sort by name
    table.sort(dungeons, function(a, b) return a.name < b.name end)

    return dungeons
end

-- ============================================================================
-- S6c  BLIZZARD PROGRESSION APIs
-- ============================================================================
-- All progression data comes from Blizzard's native APIs and MPI observations.

local function GetPlayerMPlusData()
    local data = {
        overallScore = 0,
        scoreColor   = { 0.6, 0.6, 0.6 },
        dungeonBest  = {},   -- mapID → best key level
        keystoneMapID = nil,
        keystoneLevel = nil,
        keystoneName  = nil,
    }
    -- Overall score
    if C_ChallengeMode and C_ChallengeMode.GetOverallDungeonScore then
        local ok, score = pcall(C_ChallengeMode.GetOverallDungeonScore)
        if ok and score and score > 0 then
            data.overallScore = score
            if C_ChallengeMode.GetDungeonScoreRarityColor then
                local ok2, color = pcall(C_ChallengeMode.GetDungeonScoreRarityColor, score)
                if ok2 and color and color.r then
                    data.scoreColor = { color.r, color.g, color.b }
                end
            end
        end
    end
    -- Per-dungeon best level via season best affix scores
    if C_MythicPlus and C_MythicPlus.GetSeasonBestAffixScoreInfoForMap then
        local maps = C_ChallengeMode and C_ChallengeMode.GetMapTable and SafeCall(C_ChallengeMode.GetMapTable) or {}
        for _, mapID in ipairs(maps or {}) do
            local ok, affixes = pcall(C_MythicPlus.GetSeasonBestAffixScoreInfoForMap, mapID)
            if ok and affixes then
                local best = 0
                for _, info in ipairs(affixes) do
                    if info.level and info.level > best then best = info.level end
                end
                if best > 0 then data.dungeonBest[mapID] = best end
            end
        end
    end
    -- Fallback: run history if affix scores unavailable
    if next(data.dungeonBest) == nil and C_MythicPlus and C_MythicPlus.GetRunHistory then
        local ok, runs = pcall(C_MythicPlus.GetRunHistory, true, true)
        if ok and runs then
            for _, run in ipairs(runs) do
                local mid = run.mapChallengeModeID
                local lvl = run.level
                if mid and lvl then
                    if not data.dungeonBest[mid] or lvl > data.dungeonBest[mid] then
                        data.dungeonBest[mid] = lvl
                    end
                end
            end
        end
    end
    -- Keystone
    if C_MythicPlus and C_MythicPlus.GetOwnedKeystoneInfo then
        local ok, mapID, level = pcall(C_MythicPlus.GetOwnedKeystoneInfo)
        if ok and mapID and level then
            data.keystoneMapID = mapID
            data.keystoneLevel = level
            if C_ChallengeMode and C_ChallengeMode.GetMapUIInfo then
                local ok2, name = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
                if ok2 and name then data.keystoneName = name end
            end
        end
    end
    return data
end

local function DeriveRaidTierName()
    local ok, numRF = pcall(GetNumRFDungeons)
    if ok and numRF and numRF > 0 then
        local ok2, _, name = pcall(GetRFDungeonInfo, 1)
        if ok2 and name then
            local tierName = name:match("^(.+):%s") or name:match("^(.+) -") or name
            return tierName
        end
    end
    return "Current Raid Tier"
end

local function FindWeakestDungeon(dungeons, dungeonBest)
    local weakest, weakestLevel = nil, 999
    for _, d in ipairs(dungeons) do
        local lvl = dungeonBest[d.mapID] or 0
        if lvl < weakestLevel then
            weakestLevel = lvl
            weakest = d
        end
    end
    return weakest, weakestLevel
end

local function GetRaidBossProgress()
    -- Only count wings that are currently displayed in the wing cards
    -- (matches the same filter used by UpdateRaidFinder)
    local R = Panel._refs
    local wings = {}
    local totalBosses, totalKilled = 0, 0

    if R and R.raidWingCards then
        for _, wcard in ipairs(R.raidWingCards) do
            if wcard:IsShown() and wcard._wingID then
                local id = wcard._wingID
                local name = wcard._nameText and wcard._nameText:GetText() or "Unknown"
                local wing = { id = id, name = name, bosses = {}, killed = 0, total = 0 }
                local ok3, numEnc = pcall(GetLFGDungeonNumEncounters, id)
                if ok3 and numEnc and numEnc > 0 then
                    wing.total = numEnc
                    for e = 1, numEnc do
                        local ok4, eName, eID, isKilled = pcall(GetLFGDungeonEncounterInfo, id, e)
                        wing.bosses[#wing.bosses + 1] = { name = eName, killed = isKilled }
                        if ok4 and isKilled then wing.killed = wing.killed + 1 end
                    end
                end
                totalBosses = totalBosses + wing.total
                totalKilled = totalKilled + wing.killed
                wings[#wings + 1] = wing
            end
        end
    end
    return wings, totalBosses, totalKilled
end

-- ============================================================================
-- S6d  CATEGORY DEFINITIONS
-- ============================================================================
-- Delves category ID: 121 in TWW (confirmed via C_LFGList.GetAvailableCategories dump).
-- Falls back to scanning available categories for any ID > 100 that isn't Island Expeditions (111).
local DELVES_CATEGORY_ID = 121
if C_LFGList and C_LFGList.GetAvailableCategories then
    local ok, cats = pcall(C_LFGList.GetAvailableCategories)
    if ok and cats then
        local found = false
        for _, cid in ipairs(cats) do
            if cid == 121 then found = true; break end
        end
        if not found then
            -- 121 not available — look for any high ID that isn't 111 (Island Expeditions)
            for _, cid in ipairs(cats) do
                if cid > 100 and cid ~= 111 then
                    DELVES_CATEGORY_ID = cid
                    break
                end
            end
        end
    end
end

local CATEGORY_DEFS = {
    { key = "mythicplus", label = "Mythic+",        categoryID = 2,  isMPlus = true },
    { key = "delves",     label = "Delves",          categoryID = DELVES_CATEGORY_ID, isDelves = true },
    { key = "raids",      label = "Raids",           categoryID = 3 },
    { key = "legacy",     label = "Raids (Legacy)",  categoryID = 3,  isLegacy = true },
    { key = "questing",   label = "Questing",        categoryID = 1 },
    { key = "custom",     label = "Custom",          categoryID = 6 },
}

local CATEGORY_ACCENTS = {
    mythicplus = { 0.00, 0.78, 1.00 },
    delves     = { 0.85, 0.65, 0.20 },
    raids      = { 0.80, 0.30, 0.30 },
    legacy     = { 0.55, 0.40, 0.70 },
    questing   = { 0.35, 0.75, 0.40 },
    custom     = { 0.55, 0.55, 0.55 },
}

-- ============================================================================
-- S7  PANEL BUILD
-- ============================================================================
local TAB_DEFS = {
    { key = "dungeons", label = "DUNGEON OVERVIEW" },
    { key = "raids",    label = "RAID FINDER" },
    { key = "premade",  label = "PREMADE GROUPS" },
    { key = "pvp",      label = "PVP" },
}

-- ============================================================================
-- S4b  SHARED HERO HELPERS
-- ============================================================================

-- Create a glass stat pill (gradient accent dot + label + value + soft edges)
local function CreateStatPill(parent, width, height, xOfs, yOfs, acColor)
    local pill = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    pill:SetSize(width, height)
    pill:SetPoint("TOPLEFT", parent, "TOPLEFT", xOfs, yOfs)
    pill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    pill:SetBackdropColor(TC("surfaceBg"))
    pill:SetBackdropBorderColor(0, 0, 0, 0)
    local ac = acColor or { TC("accent") }

    -- Gradient accent dot (fades from full color to transparent)
    local dot = pill:CreateTexture(nil, "OVERLAY", nil, 2)
    dot:SetSize(4, height - 8)
    dot:SetPoint("LEFT", pill, "LEFT", 4, 0)
    dot:SetTexture(W8)
    if dot.SetGradient and CreateColor then
        dot:SetGradient("VERTICAL",
            CreateColor(ac[1], ac[2], ac[3], 0.3),
            CreateColor(ac[1], ac[2], ac[3], 1.0))
    else
        dot:SetColorTexture(ac[1], ac[2], ac[3])
    end
    pill._dot = dot

    local lbl = pill:CreateFontString(nil, "OVERLAY")
    TrySetFont(lbl, BODY_FONT, 9, "OUTLINE")
    lbl:SetPoint("LEFT", dot, "RIGHT", 6, 0)
    lbl:SetTextColor(TC("mutedText"))
    pill._label = lbl

    local val = pill:CreateFontString(nil, "OVERLAY")
    TrySetFont(val, TITLE_FONT, 11, "OUTLINE")
    val:SetPoint("RIGHT", pill, "RIGHT", -8, 0)
    val:SetJustifyH("RIGHT")
    val:SetTextColor(TC("bodyText"))
    pill._value = val

    -- Soft top highlight (gradient)
    local frost = pill:CreateTexture(nil, "OVERLAY", nil, 3)
    frost:SetHeight(1)
    frost:SetPoint("TOPLEFT", pill, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", pill, "TOPRIGHT", -1, -1)
    frost:SetTexture(W8)
    if frost.SetGradient and CreateColor then
        frost:SetGradient("HORIZONTAL",
            CreateColor(1, 1, 1, 0.01),
            CreateColor(1, 1, 1, 0.04))
    else
        frost:SetColorTexture(1, 1, 1, 0.04)
    end

    -- Subtle bottom shadow
    local botLine = pill:CreateTexture(nil, "BACKGROUND", nil, 2)
    botLine:SetHeight(1)
    botLine:SetPoint("BOTTOMLEFT", pill, "BOTTOMLEFT", 1, 1)
    botLine:SetPoint("BOTTOMRIGHT", pill, "BOTTOMRIGHT", -1, 1)
    botLine:SetColorTexture(0, 0, 0, 0.08)

    return pill
end

-- Create a role toggle pill (icon + label, clickable, borderless surface)
local function CreateRolePill(parent, width, height, xOfs, yOfs, roleKey, atlas, label)
    local rpill = CreateFrame("Button", nil, parent, "BackdropTemplate")
    rpill:SetSize(width, height)
    rpill:SetPoint("TOPLEFT", parent, "TOPLEFT", xOfs, yOfs)
    rpill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    rpill:SetBackdropColor(TC("surfaceBg"))
    rpill:SetBackdropBorderColor(0, 0, 0, 0)

    -- Selection glow (hidden by default, shown when role is active)
    local selGlow = rpill:CreateTexture(nil, "BACKGROUND", nil, 1)
    selGlow:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
    selGlow:SetPoint("BOTTOMRIGHT", rpill, "BOTTOMRIGHT", -1, 1)
    selGlow:SetColorTexture(0, 0, 0, 0)
    rpill._selGlow = selGlow

    local ricon = rpill:CreateTexture(nil, "ARTWORK")
    ricon:SetSize(16, 16)
    ricon:SetPoint("LEFT", rpill, "LEFT", 8, 0)
    pcall(ricon.SetAtlas, ricon, atlas)
    ricon:SetDesaturated(true)
    ricon:SetAlpha(0.4)
    rpill._icon = ricon

    local rlbl = rpill:CreateFontString(nil, "OVERLAY")
    TrySetFont(rlbl, BODY_FONT, 10, "OUTLINE")
    rlbl:SetPoint("LEFT", ricon, "RIGHT", 5, 0)
    rlbl:SetTextColor(TC("mutedText"))
    rlbl:SetText(label)
    rpill._label = rlbl
    rpill._roleKey = roleKey

    -- Soft top highlight
    local frost = rpill:CreateTexture(nil, "OVERLAY", nil, 3)
    frost:SetHeight(1)
    frost:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
    frost:SetPoint("TOPRIGHT", rpill, "TOPRIGHT", -1, -1)
    frost:SetTexture(W8)
    if frost.SetGradient and CreateColor then
        frost:SetGradient("HORIZONTAL",
            CreateColor(1, 1, 1, 0.01),
            CreateColor(1, 1, 1, 0.04))
    else
        frost:SetColorTexture(1, 1, 1, 0.04)
    end

    return rpill
end

-- Update role card visuals (shared by all 4 heroes)
function Panel.UpdateRoleCards(cards, stateTable, acColor)
    if not cards then return end
    local ac = acColor or activeTheme.accent
    for _, rcard in ipairs(cards) do
        if stateTable[rcard._roleKey] then
            rcard._icon:SetDesaturated(false)
            rcard._icon:SetAlpha(1.0)
            if rcard.SetBackdropBorderColor then rcard:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.20) end
            if rcard._selGlow then rcard._selGlow:SetColorTexture(ac[1], ac[2], ac[3], 0.08) end
            if rcard._label then rcard._label:SetTextColor(ac[1], ac[2], ac[3]) end
        else
            rcard._icon:SetDesaturated(true)
            rcard._icon:SetAlpha(0.4)
            if rcard.SetBackdropBorderColor then rcard:SetBackdropBorderColor(0, 0, 0, 0) end
            if rcard._selGlow then rcard._selGlow:SetColorTexture(0, 0, 0, 0) end
            if rcard._label then rcard._label:SetTextColor(TC("mutedText")) end
        end
    end
end

-- Populate player identity elements (name + class icon + spec + ilvl)
local function PopulatePlayerIdentity(nameRef, classIconRef, specLineRef)
    local pName = UnitName("player") or "Unknown"
    local _, pClass = UnitClass("player")
    if nameRef then
        local cc = pClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[pClass]
        if cc then
            nameRef:SetText(("|cff%02x%02x%02x"):format(cc.r * 255, cc.g * 255, cc.b * 255) .. pName .. "|r")
        else
            nameRef:SetText(pName)
        end
    end
    if classIconRef and pClass then
        local coords = CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[pClass]
        if coords then classIconRef:SetTexCoord(unpack(coords)) end
    end
    if specLineRef then
        local specStr, ilvlStr = "", ""
        local specIdx = GetSpecialization and GetSpecialization()
        if specIdx then
            local okS, _, specNameStr = pcall(GetSpecializationInfo, specIdx)
            if okS and specNameStr then specStr = specNameStr end
        end
        if GetAverageItemLevel then
            local okI, _, equipped = pcall(GetAverageItemLevel)
            if okI and equipped and equipped > 0 then ilvlStr = math.floor(equipped) .. " iLvl" end
        end
        local line = specStr
        if ilvlStr ~= "" then line = line .. (specStr ~= "" and "  \194\183  " or "") .. ilvlStr end
        specLineRef:SetText(line)
    end
end

function Panel.EnsurePanel()
    local R = Panel._refs
    if R.panel then return R.panel end

    GetActiveTheme()

    -- Main frame
    local frameName = "MidnightUI_GroupFinderPanel"
    local f = CreateFrame("Frame", frameName, UIParent, "BackdropTemplate")
    f:SetSize(CFG.WIDTH, CFG.HEIGHT)
    f:SetPoint("CENTER")
    f:SetFrameStrata(CFG.STRATA)
    f:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    f:SetBackdropColor(TC("frameBg"))
    local ac = activeTheme.accent
    f:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.15)
    f:Hide()
    R.panel = f

    -- ESC-closeable via UISpecialFrames.
    -- We do NOT use EnableKeyboard(true) because it swallows all key input
    -- (Enter for chat, movement keys, keybinds) while the panel is open.
    -- Instead, override Hide so UISpecialFrames closes the detail panel first,
    -- then closes the main panel on the next ESC press.
    tinsert(UISpecialFrames, frameName)

    -- Drop shadow
    CreateDropShadow(f, 5)

    -- OnHide handler — clean up state
    f:SetScript("OnHide", function()
        Panel._state.panelOpen = false
        StopAutoRefresh()
        Panel.HideGroupDetail()
        if R.settingsPopup then R.settingsPopup:Hide() end
    end)

    -- Override Hide: when UISpecialFrames calls Hide() on ESC, close the
    -- detail panel first and keep the main panel open. Next ESC will close
    -- the main panel since detailOpen will be false.
    local frameHide = f.Hide
    f.Hide = function(self)
        if Panel._state.detailOpen then
            Panel.HideGroupDetail()
            return
        end
        frameHide(self)
    end

    -- ----------------------------------------------------------------
    -- Header (44px)
    -- ----------------------------------------------------------------
    local header = CreateFrame("Frame", nil, f)
    header:SetHeight(CFG.HEADER_H)
    header:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    header:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
    R.header = header

    -- Header background
    local headerBg = header:CreateTexture(nil, "BACKGROUND")
    headerBg:SetAllPoints()
    headerBg:SetColorTexture(TC("headerBg"))
    R.headerBg = headerBg

    -- Accent gradient line at bottom of header (2px)
    local accentLine = header:CreateTexture(nil, "OVERLAY", nil, 2)
    accentLine:SetHeight(2)
    accentLine:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 0)
    accentLine:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 0)
    accentLine:SetTexture(W8)
    if accentLine.SetGradient and CreateColor then
        accentLine:SetGradient("HORIZONTAL",
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.6),
            CreateColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.0))
    else
        accentLine:SetColorTexture(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.6)
    end
    R.headerAccentLine = accentLine

    -- Title text
    local title = header:CreateFontString(nil, "OVERLAY")
    TrySetFont(title, TITLE_FONT, 16, "OUTLINE")
    title:SetPoint("LEFT", header, "LEFT", CFG.PAD, 0)
    title:SetTextColor(TC("titleText"))
    title:SetText("Group Finder (Beta)")
    R.title = title

    -- Draggable via header
    header:EnableMouse(true)
    header:RegisterForDrag("LeftButton")
    header:SetScript("OnDragStart", function() f:StartMoving() end)
    header:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)
    f:SetMovable(true)
    f:SetClampedToScreen(true)

    -- Close button
    local closeBtn = CreateFrame("Button", nil, header)
    closeBtn:SetSize(28, 28)
    closeBtn:SetPoint("RIGHT", header, "RIGHT", -8, 0)
    local closeTex = closeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(closeTex, TITLE_FONT, 16, "OUTLINE")
    closeTex:SetPoint("CENTER")
    closeTex:SetTextColor(TC("bodyText"))
    closeTex:SetText("X")
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)
    closeBtn:SetScript("OnEnter", function() closeTex:SetTextColor(1, 0.3, 0.3) end)
    closeBtn:SetScript("OnLeave", function() closeTex:SetTextColor(TC("bodyText")) end)
    R.closeBtn = closeBtn

    -- Settings gear button (24x24, left of close button)
    local gearBtn = CreateFrame("Button", nil, header)
    gearBtn:SetSize(24, 24)
    gearBtn:SetPoint("RIGHT", closeBtn, "LEFT", -6, 0)
    local gearIcon = gearBtn:CreateTexture(nil, "OVERLAY")
    gearIcon:SetAllPoints()
    gearIcon:SetTexture("Interface\\Icons\\Trade_Engineering")
    gearIcon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    gearIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    gearBtn:SetScript("OnEnter", function() gearIcon:SetVertexColor(TC("titleText")) end)
    gearBtn:SetScript("OnLeave", function()
        gearIcon:SetVertexColor(activeTheme.mutedText[1], activeTheme.mutedText[2], activeTheme.mutedText[3], 0.70)
    end)
    gearBtn:SetScript("OnClick", function()
        if R.settingsPopup and R.settingsPopup:IsShown() then
            R.settingsPopup:Hide()
        else
            Panel.ShowSettingsPopup()
        end
    end)
    R.gearBtn = gearBtn

    -- MPI: Companion app button (left of gear)
    if _G.MidnightPI and _G.MidnightPI.BuildCompanionSettingsButton then _G.MidnightPI.BuildCompanionSettingsButton(gearBtn) end

    -- ----------------------------------------------------------------
    -- Tab Bar (32px), below header
    -- ----------------------------------------------------------------
    local tabBar = CreateFrame("Frame", nil, f)
    tabBar:SetHeight(CFG.TAB_BAR_H)
    tabBar:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    tabBar:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    R.tabBar = tabBar

    -- 1px divider at top of tab bar
    local tabDivider = tabBar:CreateTexture(nil, "OVERLAY", nil, 2)
    tabDivider:SetHeight(1)
    tabDivider:SetPoint("TOPLEFT", tabBar, "TOPLEFT", 0, 0)
    tabDivider:SetPoint("TOPRIGHT", tabBar, "TOPRIGHT", 0, 0)
    tabDivider:SetColorTexture(TC("accent"))
    R.tabDivider = tabDivider

    -- Build tabs
    local tabWidth = CFG.WIDTH / #TAB_DEFS
    R.tabs = {}
    for i, def in ipairs(TAB_DEFS) do
        local tab = CreateFrame("Button", nil, tabBar)
        tab:SetSize(tabWidth, CFG.TAB_BAR_H)
        if i == 1 then
            tab:SetPoint("TOPLEFT", tabBar, "TOPLEFT", 0, 0)
        else
            tab:SetPoint("LEFT", R.tabs[i - 1], "RIGHT", 0, 0)
        end

        -- Tab label
        local label = tab:CreateFontString(nil, "OVERLAY")
        TrySetFont(label, BODY_FONT, 11, "OUTLINE")
        label:SetPoint("CENTER")
        label:SetTextColor(TC("tabInactive"))
        label:SetText(def.label)
        tab._label = label

        -- Active underline (2px, accent color, inset 20px)
        local underline = tab:CreateTexture(nil, "OVERLAY", nil, 3)
        underline:SetHeight(2)
        underline:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 20, 0)
        underline:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -20, 0)
        underline:SetColorTexture(TC("accent"))
        underline:Hide()
        tab._underline = underline

        tab._key = def.key

        tab:SetScript("OnClick", function()
            Panel.SetActiveTab(def.key)
        end)
        tab:SetScript("OnEnter", function()
            if Panel._state.activeTab ~= def.key then
                label:SetTextColor(TC("bodyText"))
            end
        end)
        tab:SetScript("OnLeave", function()
            if Panel._state.activeTab ~= def.key then
                label:SetTextColor(TC("tabInactive"))
            end
        end)

        R.tabs[i] = tab
    end

    -- ----------------------------------------------------------------
    -- Content Area (below tab bar to bottom)
    -- ----------------------------------------------------------------
    local content = CreateFrame("Frame", nil, f)
    content:SetPoint("TOPLEFT", tabBar, "BOTTOMLEFT", 0, 0)
    content:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", 0, 0)
    R.content = content

    -- ==================================================================
    -- Dungeon Finder overlay (full implementation)
    -- ==================================================================
    do -- scope block to avoid 200 local variable limit
    local dungeonContent = CreateFrame("Frame", nil, content)
    dungeonContent:SetAllPoints()
    dungeonContent:Hide()
    R.dungeonContent = dungeonContent

    -- Initialize dungeon role state
    Panel._state.dungeonRoles = { tank = false, healer = false, dps = false }

    -- Load season dungeons dynamically
    Panel._dungeonData = LoadSeasonDungeons()
    Panel._followerDungeonData = LoadFollowerDungeons()

    -- ---- Dungeon Hero Banner (130px) ----
    -- Atlas artwork background with vignettes (CharacterPanel pattern).
    -- Content: M+ score, keystone, 8 dungeon badges, suggestions, progress bar.
    local dungeonHero = CreateFrame("Frame", nil, dungeonContent)
    dungeonHero:SetHeight(190)
    dungeonHero:SetPoint("TOPLEFT", dungeonContent, "TOPLEFT", 0, 0)
    dungeonHero:SetPoint("TOPRIGHT", dungeonContent, "TOPRIGHT", 0, 0)
    R.dungeonHero = dungeonHero

    local dAc = activeTheme.accent

    -- Layer -8: Dark base (always visible, provides darkness if atlas fails)
    local dhBase = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -8)
    dhBase:SetAllPoints()
    dhBase:SetColorTexture(0.02, 0.02, 0.03, 1)

    -- Layer -7: Atlas artwork (pcall-wrapped, transparent fallback)
    local dhAtlas = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -7)
    dhAtlas:SetAllPoints()
    if not TrySetAtlasFromList(dhAtlas, HERO_ATLASES.dungeons) then
        dhAtlas:SetColorTexture(0, 0, 0, 0) -- transparent fallback
    end
    dhAtlas:SetAlpha(0.40)

    -- Layer -5: Top vignette (80px, darkens top edge for seamless header blend)
    local dhVigTop = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    dhVigTop:SetHeight(80)
    dhVigTop:SetPoint("TOPLEFT", dungeonHero, "TOPLEFT", 0, 0)
    dhVigTop:SetPoint("TOPRIGHT", dungeonHero, "TOPRIGHT", 0, 0)
    dhVigTop:SetTexture(W8)
    ApplyGradient(dhVigTop, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.5)

    -- Layer -5: Bottom vignette (60px, darkens bottom for content separation)
    local dhVigBot = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    dhVigBot:SetHeight(60)
    dhVigBot:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", 0, 0)
    dhVigBot:SetPoint("BOTTOMRIGHT", dungeonHero, "BOTTOMRIGHT", 0, 0)
    dhVigBot:SetTexture(W8)
    ApplyGradient(dhVigBot, "VERTICAL", 0, 0, 0, 0.6, 0, 0, 0, 0)

    -- Layer -5: Left reading vignette (text zone darkening)
    local dhVigLeft = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    dhVigLeft:SetWidth(math.floor(CFG.WIDTH * 0.40))
    dhVigLeft:SetPoint("TOPLEFT", dungeonHero, "TOPLEFT", 0, 0)
    dhVigLeft:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", 0, 0)
    dhVigLeft:SetTexture(W8)
    ApplyGradient(dhVigLeft, "HORIZONTAL", 0, 0, 0, 0.25, 0, 0, 0, 0)

    -- Layer -4: Accent wash at bottom (ties banner to theme)
    local dhAccentWash = dungeonHero:CreateTexture(nil, "BACKGROUND", nil, -4)
    dhAccentWash:SetHeight(60)
    dhAccentWash:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", 0, 0)
    dhAccentWash:SetPoint("BOTTOMRIGHT", dungeonHero, "BOTTOMRIGHT", 0, 0)
    dhAccentWash:SetTexture(W8)
    ApplyGradient(dhAccentWash, "VERTICAL", dAc[1], dAc[2], dAc[3], 0.03, dAc[1], dAc[2], dAc[3], 0)

    -- ========================
    -- ROW 1: Context bar
    -- ========================
    local dhCtxLeft = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dhCtxLeft, BODY_FONT, 9, "OUTLINE")
    dhCtxLeft:SetPoint("TOPLEFT", dungeonHero, "TOPLEFT", CFG.PAD + 2, -8)
    dhCtxLeft:SetTextColor(TC("mutedText"))
    dhCtxLeft:SetText("")

    local dhCtxRight = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dhCtxRight, BODY_FONT, 9, "OUTLINE")
    dhCtxRight:SetPoint("TOPRIGHT", dungeonHero, "TOPRIGHT", -CFG.PAD, -8)
    dhCtxRight:SetTextColor(TC("mutedText"))
    dhCtxRight:SetText("")
    R.dungeonHeroScore = dhCtxRight

    -- ========================
    -- ROW 2: Centered player name with class icon
    -- ========================
    local dhClassIcon = dungeonHero:CreateTexture(nil, "OVERLAY")
    dhClassIcon:SetSize(22, 22)
    dhClassIcon:SetPoint("TOP", dungeonHero, "TOP", -46, -34)
    dhClassIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes")
    R.dungeonHeroClassIcon = dhClassIcon

    local dhPlayerName = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dhPlayerName, TITLE_FONT, 14, "OUTLINE")
    dhPlayerName:SetPoint("LEFT", dhClassIcon, "RIGHT", 6, 0)
    dhPlayerName:SetTextColor(TC("bodyText"))
    dhPlayerName:SetText("")
    R.dungeonHeroPlayerLine = dhPlayerName

    -- ========================
    -- ROW 3: Spec + iLvl (centered below name)
    -- ========================
    local dhSpecLine = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dhSpecLine, BODY_FONT, 10, "")
    dhSpecLine:SetPoint("TOP", dhClassIcon, "BOTTOM", 20, -2)
    dhSpecLine:SetTextColor(TC("mutedText"))
    dhSpecLine:SetText("")
    R.dungeonHeroSpecLine = dhSpecLine

    -- ========================
    -- ROW 4: Pill bar (3 role toggles + 2 stat pills, centered)
    -- ========================
    local PILL_H = 28
    local PILL_GAP = 8
    local ROLE_PILL_W = 80
    local STAT_PILL_W = 140
    local totalPillW = 3 * ROLE_PILL_W + 2 * STAT_PILL_W + 4 * PILL_GAP
    local pillStartX = math.floor((CFG.WIDTH - totalPillW) / 2)
    local pillY = -82

    -- Stat pills use the shared CreateStatPill helper

    -- Role toggle pills (3x 80px)
    local roleCardDefs = {
        { key = "tank",   atlas = "UI-LFG-RoleIcon-Tank",   label = "Tank" },
        { key = "healer", atlas = "UI-LFG-RoleIcon-Healer", label = "Healer" },
        { key = "dps",    atlas = "UI-LFG-RoleIcon-DPS",    label = "DPS" },
    }
    R.dungeonRoleCards = {}

    for ri, rd in ipairs(roleCardDefs) do
        local rpill = CreateFrame("Button", nil, dungeonHero, "BackdropTemplate")
        rpill:SetSize(ROLE_PILL_W, PILL_H)
        local xOfs = pillStartX + (ri - 1) * (ROLE_PILL_W + PILL_GAP)
        rpill:SetPoint("TOPLEFT", dungeonHero, "TOPLEFT", xOfs, pillY)
        rpill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        rpill:SetBackdropColor(TC("surfaceBg"))
        rpill:SetBackdropBorderColor(0, 0, 0, 0)

        -- Selection glow
        local selGlow = rpill:CreateTexture(nil, "BACKGROUND", nil, 1)
        selGlow:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        selGlow:SetPoint("BOTTOMRIGHT", rpill, "BOTTOMRIGHT", -1, 1)
        selGlow:SetColorTexture(0, 0, 0, 0)
        rpill._selGlow = selGlow

        -- Role icon
        local ricon = rpill:CreateTexture(nil, "ARTWORK")
        ricon:SetSize(16, 16)
        ricon:SetPoint("LEFT", rpill, "LEFT", 8, 0)
        pcall(ricon.SetAtlas, ricon, rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rpill._icon = ricon

        -- Role label
        local rlbl = rpill:CreateFontString(nil, "OVERLAY")
        TrySetFont(rlbl, BODY_FONT, 10, "OUTLINE")
        rlbl:SetPoint("LEFT", ricon, "RIGHT", 5, 0)
        rlbl:SetTextColor(TC("mutedText"))
        rlbl:SetText(rd.label)
        rpill._label = rlbl
        rpill._roleKey = rd.key

        -- Soft top highlight
        local frost = rpill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", rpill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end

        rpill:SetScript("OnClick", function(self)
            Panel._state.dungeonRoles[self._roleKey] = not Panel._state.dungeonRoles[self._roleKey]
            Panel.UpdateDungeonRoleCards()
        end)
        rpill:SetScript("OnEnter", function(self)
            if not Panel._state.dungeonRoles[self._roleKey] then
                self._icon:SetAlpha(0.7)
            end
        end)
        rpill:SetScript("OnLeave", function(self)
            if not Panel._state.dungeonRoles[self._roleKey] then
                self._icon:SetAlpha(0.4)
            end
        end)

        R.dungeonRoleCards[ri] = rpill
    end
    R.dungeonRoleBtns = R.dungeonRoleCards

    -- M+ Rating pill
    local ratingPillX = pillStartX + 3 * (ROLE_PILL_W + PILL_GAP)
    local ratingPill = CreateStatPill(dungeonHero, STAT_PILL_W, PILL_H, ratingPillX, pillY)
    ratingPill._label:SetText("M+ RATING")
    ratingPill._value:SetText("--")
    R.dungeonRatingPill = ratingPill

    -- Keystone pill
    local keyPillX = ratingPillX + STAT_PILL_W + PILL_GAP
    local keyPill = CreateStatPill(dungeonHero, STAT_PILL_W, PILL_H, keyPillX, pillY)
    keyPill._label:SetText("KEY")
    keyPill._value:SetText("None")
    R.dungeonKeystonePill = keyPill
    R.dungeonHeroKeystoneText = keyPill._value  -- backward compat

    -- ========================
    -- ROW 5: 8 dungeon badges (full-width centered row)
    -- ========================
    local BADGE_W = 120
    local BADGE_H = 24
    local BADGE_GAP = 5
    local numDungeons = #Panel._dungeonData
    local totalBadgeW = numDungeons * BADGE_W + (numDungeons - 1) * BADGE_GAP
    local badgeStartX = math.floor((CFG.WIDTH - totalBadgeW) / 2)
    R.heroDungeonBadges = {}

    for i, dung in ipairs(Panel._dungeonData) do
        local badge = CreateFrame("Frame", nil, dungeonHero, "BackdropTemplate")
        badge:SetSize(BADGE_W, BADGE_H)
        local xOfs = badgeStartX + (i - 1) * (BADGE_W + BADGE_GAP)
        badge:SetPoint("TOPLEFT", dungeonHero, "TOPLEFT", xOfs, -120)
        badge:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        badge:SetBackdropColor(TC("surfaceBg"))
        badge:SetBackdropBorderColor(0, 0, 0, 0)

        -- Gradient accent bar (fades top to bottom)
        local bDot = badge:CreateTexture(nil, "OVERLAY", nil, 2)
        bDot:SetSize(3, BADGE_H)
        bDot:SetPoint("LEFT", badge, "LEFT", 0, 0)
        bDot:SetTexture(W8)
        if bDot.SetGradient and CreateColor then
            bDot:SetGradient("VERTICAL",
                CreateColor(dung.accent[1], dung.accent[2], dung.accent[3], 0.25),
                CreateColor(dung.accent[1], dung.accent[2], dung.accent[3], 0.70))
        else
            bDot:SetColorTexture(dung.accent[1], dung.accent[2], dung.accent[3], 0.70)
        end
        badge._acBar = bDot

        local bAbbr = badge:CreateFontString(nil, "OVERLAY")
        TrySetFont(bAbbr, BODY_FONT, 10, "OUTLINE")
        bAbbr:SetPoint("LEFT", badge, "LEFT", 8, 0)
        bAbbr:SetTextColor(dung.accent[1], dung.accent[2], dung.accent[3])
        bAbbr:SetText(dung.abbr)
        badge._abbrText = bAbbr

        local bLevel = badge:CreateFontString(nil, "OVERLAY")
        TrySetFont(bLevel, TITLE_FONT, 11, "OUTLINE")
        bLevel:SetPoint("RIGHT", badge, "RIGHT", -6, 0)
        bLevel:SetJustifyH("RIGHT")
        bLevel:SetTextColor(TC("mutedText"))
        bLevel:SetText("--")
        badge._levelText = bLevel

        badge._mapID = dung.mapID
        badge._accent = dung.accent
        R.heroDungeonBadges[i] = badge
    end

    -- Suggestion text (bottom area, above progress bar)
    local dsWeakText = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dsWeakText, BODY_FONT, 9, "")
    dsWeakText:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", CFG.PAD + 2, 14)
    dsWeakText:SetPoint("RIGHT", dungeonHero, "CENTER", -8, 0)
    dsWeakText:SetJustifyH("LEFT")
    dsWeakText:SetTextColor(TC("mutedText"))
    dsWeakText:SetText("")
    R.suggestWeakText = dsWeakText

    local dsKeyText = dungeonHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(dsKeyText, BODY_FONT, 9, "")
    dsKeyText:SetPoint("LEFT", dungeonHero, "CENTER", 8, 0)
    dsKeyText:SetPoint("BOTTOMRIGHT", dungeonHero, "BOTTOMRIGHT", -CFG.PAD, 14)
    dsKeyText:SetJustifyH("RIGHT")
    dsKeyText:SetTextColor(TC("mutedText"))
    dsKeyText:SetText("")
    R.suggestKeyText = dsKeyText

    -- Progress bar (3px, with bright top edge for track feel)
    local dhTrack = dungeonHero:CreateTexture(nil, "ARTWORK", nil, 1)
    dhTrack:SetHeight(3)
    dhTrack:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", CFG.PAD, 5)
    dhTrack:SetPoint("BOTTOMRIGHT", dungeonHero, "BOTTOMRIGHT", -CFG.PAD, 5)
    dhTrack:SetColorTexture(1, 1, 1, 0.04)
    R.dungeonHeroTrack = dhTrack

    local dhTrackHighlight = dungeonHero:CreateTexture(nil, "ARTWORK", nil, 1)
    dhTrackHighlight:SetHeight(1)
    dhTrackHighlight:SetPoint("TOPLEFT", dhTrack, "TOPLEFT", 0, 0)
    dhTrackHighlight:SetPoint("TOPRIGHT", dhTrack, "TOPRIGHT", 0, 0)
    dhTrackHighlight:SetColorTexture(1, 1, 1, 0.06)

    local dhFill = dungeonHero:CreateTexture(nil, "ARTWORK", nil, 2)
    dhFill:SetHeight(3)
    dhFill:SetPoint("LEFT", dhTrack, "LEFT", 0, 0)
    dhFill:SetWidth(1)
    dhFill:SetColorTexture(dAc[1], dAc[2], dAc[3], 0.55)
    R.dungeonHeroFill = dhFill

    -- Bottom divider (gradient fade from center outward)
    local dhGlassDivL = dungeonHero:CreateTexture(nil, "OVERLAY", nil, 3)
    dhGlassDivL:SetHeight(1)
    dhGlassDivL:SetPoint("BOTTOMLEFT", dungeonHero, "BOTTOMLEFT", 0, 0)
    dhGlassDivL:SetPoint("BOTTOM", dungeonHero, "BOTTOM", 0, 0)
    dhGlassDivL:SetTexture(W8)
    ApplyGradient(dhGlassDivL, "HORIZONTAL", 1, 1, 1, 0, 1, 1, 1, 0.06)

    local dhGlassDivR = dungeonHero:CreateTexture(nil, "OVERLAY", nil, 3)
    dhGlassDivR:SetHeight(1)
    dhGlassDivR:SetPoint("BOTTOM", dungeonHero, "BOTTOM", 0, 0)
    dhGlassDivR:SetPoint("BOTTOMRIGHT", dungeonHero, "BOTTOMRIGHT", 0, 0)
    dhGlassDivR:SetTexture(W8)
    ApplyGradient(dhGlassDivR, "HORIZONTAL", 1, 1, 1, 0.06, 1, 1, 1, 0)

    -- Spacer for queue bar anchoring
    local dungeonSuggest = CreateFrame("Frame", nil, dungeonContent)
    dungeonSuggest:SetHeight(1)
    dungeonSuggest:SetPoint("TOPLEFT", dungeonHero, "BOTTOMLEFT", 0, 0)
    dungeonSuggest:SetPoint("TOPRIGHT", dungeonHero, "BOTTOMRIGHT", 0, 0)
    R.dungeonSuggest = dungeonSuggest

    -- ---- Queue Status Bar (30px, hidden by default) ----
    local queueBar = CreateFrame("Frame", nil, dungeonContent, "BackdropTemplate")
    queueBar:SetHeight(30)
    queueBar:SetPoint("TOPLEFT", dungeonSuggest, "BOTTOMLEFT", 0, 0)
    queueBar:SetPoint("TOPRIGHT", dungeonSuggest, "BOTTOMRIGHT", 0, 0)
    queueBar:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    local qbAc = activeTheme.accent
    queueBar:SetBackdropColor(qbAc[1], qbAc[2], qbAc[3], 0.10)
    queueBar:SetBackdropBorderColor(qbAc[1], qbAc[2], qbAc[3], 0.20)
    queueBar:Hide()
    R.dungeonQueueBar = queueBar

    local queueText = queueBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(queueText, BODY_FONT, 11, "OUTLINE")
    queueText:SetPoint("LEFT", queueBar, "LEFT", 12, 0)
    queueText:SetTextColor(TC("bodyText"))
    queueText:SetText("Queued...")
    R.dungeonQueueText = queueText

    local cancelBtn = CreateFrame("Button", nil, queueBar, "BackdropTemplate")
    cancelBtn:SetSize(60, 24)
    cancelBtn:SetPoint("RIGHT", queueBar, "RIGHT", -8, 0)
    cancelBtn:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    cancelBtn:SetBackdropColor(0.3, 0.05, 0.05, 0.6)
    cancelBtn:SetBackdropBorderColor(1, 0.3, 0.3, 0.3)
    local cancelLabel = cancelBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(cancelLabel, BODY_FONT, 10, "OUTLINE")
    cancelLabel:SetPoint("CENTER")
    cancelLabel:SetTextColor(1, 0.4, 0.4)
    cancelLabel:SetText("Cancel")
    cancelBtn:SetScript("OnClick", function()
        pcall(LeaveLFG, LE_LFG_CATEGORY_LFD or 1)
        C_Timer.After(0.3, function() Panel.UpdateDungeonQueueStatus() end)
    end)
    cancelBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.08, 0.08, 0.8)
    end)
    cancelBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.3, 0.05, 0.05, 0.6)
    end)

    -- ---- Dungeon Card Grid (2 columns, scrollable, dynamic from API) ----
    local CARD_W = math.floor((CFG.WIDTH - 48) / 2)
    local CARD_H = 120
    local CARD_GAP_X = 8
    local CARD_GAP_Y = 8
    local BOTTOM_BAR_H = 50
    local dungeonData = Panel._dungeonData
    -- Store layout constants for dynamic follower card re-layout
    Panel._cardLayout = { W = CARD_W, H = CARD_H, GX = CARD_GAP_X, GY = CARD_GAP_Y, SECTION_H = 28 }

    -- ScrollFrame for the card grid
    local cardScroll = CreateFrame("ScrollFrame", nil, dungeonContent, "UIPanelScrollFrameTemplate")
    cardScroll:SetPoint("TOPLEFT", queueBar, "BOTTOMLEFT", 8, -8)
    cardScroll:SetPoint("BOTTOMRIGHT", dungeonContent, "BOTTOMRIGHT", -28, BOTTOM_BAR_H + 4)

    -- Hide the default scroll bar textures for cleaner look
    if cardScroll.ScrollBar then
        if cardScroll.ScrollBar.ScrollUpButton then
            cardScroll.ScrollBar.ScrollUpButton:SetAlpha(0)
        end
        if cardScroll.ScrollBar.ScrollDownButton then
            cardScroll.ScrollBar.ScrollDownButton:SetAlpha(0)
        end
    end

    local SECTION_HEADER_H = 28
    local followerData = Panel._followerDungeonData
    local mplusRows = math.ceil(#dungeonData / 2)
    local followerRows = math.ceil(#followerData / 2)
    local totalH = SECTION_HEADER_H + mplusRows * (CARD_H + CARD_GAP_Y) + 8
    if #followerData > 0 then
        totalH = totalH + SECTION_HEADER_H + followerRows * (CARD_H + CARD_GAP_Y) + 8
    end

    local cardContainer = CreateFrame("Frame", nil, cardScroll)
    cardContainer:SetWidth(CFG.WIDTH - 48)
    cardContainer:SetHeight(totalH)
    cardScroll:SetScrollChild(cardContainer)
    R.cardContainer = cardContainer

    -- ---- Section header: MYTHIC+ DUNGEONS ----
    local mplusHeader = cardContainer:CreateFontString(nil, "OVERLAY")
    TrySetFont(mplusHeader, TITLE_FONT, 11, "OUTLINE")
    mplusHeader:SetPoint("TOPLEFT", cardContainer, "TOPLEFT", 4, 0)
    mplusHeader:SetTextColor(TC("mutedText"))
    mplusHeader:SetText("MYTHIC+ DUNGEONS")
    local mplusDiv = cardContainer:CreateTexture(nil, "ARTWORK")
    mplusDiv:SetHeight(1)
    mplusDiv:SetPoint("TOPLEFT", mplusHeader, "BOTTOMLEFT", -4, -4)
    mplusDiv:SetPoint("RIGHT", cardContainer, "RIGHT", 0, 0)
    mplusDiv:SetColorTexture(TC("divider"))

    local mplusStartY = -(SECTION_HEADER_H)

    R.dungeonCards = {}
    for i, dungInfo in ipairs(dungeonData) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local xOfs = col * (CARD_W + CARD_GAP_X)
        local yOfs = mplusStartY - (row * (CARD_H + CARD_GAP_Y))
        local dAccent = dungInfo.accent

        local card = CreateFrame("Button", nil, cardContainer, "BackdropTemplate")
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", cardContainer, "TOPLEFT", xOfs, yOfs)
        card:SetBackdrop({
            bgFile = W8,
            edgeFile = W8,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        card:SetBackdropColor(TC("surfaceBg"))
        card:SetBackdropBorderColor(0, 0, 0, 0)

        -- Gradient banner across top 40% of card (accent-tinted)
        local banner = card:CreateTexture(nil, "BACKGROUND", nil, 2)
        banner:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
        banner:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
        banner:SetHeight(math.floor(CARD_H * 0.40))
        banner:SetTexture(W8)
        ApplyGradient(banner, "HORIZONTAL",
            dAccent[1], dAccent[2], dAccent[3], 0.12,
            dAccent[1], dAccent[2], dAccent[3], 0.03)
        card._banner = banner

        -- Large watermark abbreviation (semi-transparent, right-aligned in banner)
        local watermark = card:CreateFontString(nil, "ARTWORK", nil, 1)
        TrySetFont(watermark, TITLE_FONT, 32, "OUTLINE")
        watermark:SetPoint("RIGHT", card, "RIGHT", -10, 8)
        watermark:SetTextColor(dAccent[1], dAccent[2], dAccent[3], 0.10)
        watermark:SetText(dungInfo.abbr)
        card._watermark = watermark

        -- Left accent bar (4px)
        local acBar = card:CreateTexture(nil, "OVERLAY", nil, 2)
        acBar:SetSize(4, CARD_H)
        acBar:SetPoint("LEFT", card, "LEFT", 0, 0)
        acBar:SetColorTexture(dAccent[1], dAccent[2], dAccent[3], 1)
        card._accentBar = acBar

        -- Abbreviation (top-left, accent color)
        local abbrText = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(abbrText, TITLE_FONT, 12, "OUTLINE")
        abbrText:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -12)
        abbrText:SetTextColor(dAccent[1], dAccent[2], dAccent[3])
        abbrText:SetText(dungInfo.abbr)
        card._abbrText = abbrText

        -- Dungeon name
        local nameText = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameText, TITLE_FONT, 13, "OUTLINE")
        nameText:SetPoint("TOPLEFT", abbrText, "TOPRIGHT", 10, 0)
        nameText:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        nameText:SetJustifyH("LEFT")
        nameText:SetTextColor(TC("bodyText"))
        nameText:SetText(dungInfo.name)
        card._nameText = nameText

        -- Best run info line (middle)
        local bestText = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(bestText, BODY_FONT, 11, "")
        bestText:SetPoint("LEFT", card, "LEFT", 14, -4)
        bestText:SetPoint("RIGHT", card, "RIGHT", -12, 0)
        bestText:SetJustifyH("LEFT")
        bestText:SetTextColor(TC("mutedText"))
        bestText:SetText("No runs yet")
        card._bestText = bestText

        -- Blizzard dungeon score contribution line
        local scoreText = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(scoreText, BODY_FONT, 10, "")
        scoreText:SetPoint("TOPLEFT", bestText, "BOTTOMLEFT", 0, -2)
        scoreText:SetTextColor(TC("mutedText"))
        scoreText:SetText("")
        card._scoreText = scoreText

        -- Progress bar track (full width at bottom, 4px)
        local trackBg = card:CreateTexture(nil, "BACKGROUND", nil, 2)
        trackBg:SetHeight(4)
        trackBg:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 1, 1)
        trackBg:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -1, 1)
        trackBg:SetColorTexture(1, 1, 1, 0.06)
        card._trackBg = trackBg

        local trackFill = card:CreateTexture(nil, "ARTWORK", nil, 3)
        trackFill:SetHeight(4)
        trackFill:SetPoint("LEFT", trackBg, "LEFT", 0, 0)
        trackFill:SetWidth(1)
        trackFill:SetColorTexture(dAccent[1], dAccent[2], dAccent[3], 0.6)
        card._trackFill = trackFill

        -- Selection state
        card._selected = false
        card._mapID = dungInfo.mapID
        card._lfgDungeonID = dungInfo.lfgDungeonID
        card._dungeonName = dungInfo.name
        card._dungeonAccent = dAccent

        -- Hover: soft accent glow
        card:SetScript("OnEnter", function(self)
            if not self._selected then
                local cAc = self._dungeonAccent
                self:SetBackdropColor(cAc[1], cAc[2], cAc[3], 0.05)
                self:SetBackdropBorderColor(cAc[1], cAc[2], cAc[3], 0.12)
            end
        end)
        card:SetScript("OnLeave", function(self)
            if not self._selected then
                self:SetBackdropColor(TC("surfaceBg"))
                self:SetBackdropBorderColor(0, 0, 0, 0)
            end
        end)

        -- Click to toggle selection (accent wash when selected)
        card:SetScript("OnClick", function(self)
            self._selected = not self._selected
            if self._selected then
                local cAc = self._dungeonAccent
                self:SetBackdropColor(cAc[1], cAc[2], cAc[3], 0.10)
                self:SetBackdropBorderColor(cAc[1], cAc[2], cAc[3], 0.25)
                -- Auto-switch to "Selected Dungeon" mode
                if Panel._state.dungeonQueueMode ~= "specific" and R.dungeonTypeBtn then
                    Panel._state.dungeonQueueMode = "specific"
                    R.dungeonTypeBtn._label:SetText("Selected Dungeon")
                    R.dungeonTypeBtn:SetBackdropBorderColor(TC("accent"))
                    R.dungeonTypeBtn._label:SetTextColor(TC("accent"))
                end
            else
                self:SetBackdropColor(TC("surfaceBg"))
                self:SetBackdropBorderColor(0, 0, 0, 0)
                -- If no cards selected (M+ or Follower), switch back to random
                local anySelected = false
                for _, c in ipairs(R.dungeonCards or {}) do
                    if c._selected then anySelected = true; break end
                end
                if not anySelected then
                    for _, c in ipairs(R.followerCards or {}) do
                        if c._selected then anySelected = true; break end
                    end
                end
                if not anySelected and R.dungeonTypeBtn then
                    Panel._state.dungeonQueueMode = "random"
                    R.dungeonTypeBtn._label:SetText("Random Dungeon")
                    R.dungeonTypeBtn:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
                    R.dungeonTypeBtn._label:SetTextColor(TC("bodyText"))
                end
            end
        end)

        R.dungeonCards[i] = card
    end

    -- ---- Section header: FOLLOWER DUNGEONS ----
    R.followerCards = {}
    if #followerData > 0 then
        local followerStartY = mplusStartY - (mplusRows * (CARD_H + CARD_GAP_Y)) - 8

        local followerHeader = cardContainer:CreateFontString(nil, "OVERLAY")
        TrySetFont(followerHeader, TITLE_FONT, 11, "OUTLINE")
        followerHeader:SetPoint("TOPLEFT", cardContainer, "TOPLEFT", 4, followerStartY)
        followerHeader:SetTextColor(0.35, 0.75, 0.55)
        followerHeader:SetText("FOLLOWER DUNGEONS")
        local followerDiv = cardContainer:CreateTexture(nil, "ARTWORK")
        followerDiv:SetHeight(1)
        followerDiv:SetPoint("TOPLEFT", followerHeader, "BOTTOMLEFT", -4, -4)
        followerDiv:SetPoint("RIGHT", cardContainer, "RIGHT", 0, 0)
        followerDiv:SetColorTexture(0.35, 0.75, 0.55, 0.25)
        R.followerHeader = followerHeader
        R.followerDiv = followerDiv

        local fCardStartY = followerStartY - SECTION_HEADER_H

        for i, fInfo in ipairs(followerData) do
            local col = (i - 1) % 2
            local row = math.floor((i - 1) / 2)
            local xOfs = col * (CARD_W + CARD_GAP_X)
            local yOfs = fCardStartY - (row * (CARD_H + CARD_GAP_Y))
            local dAccent = fInfo.accent

            local card = CreateFrame("Button", nil, cardContainer, "BackdropTemplate")
            card:SetSize(CARD_W, CARD_H)
            card:SetPoint("TOPLEFT", cardContainer, "TOPLEFT", xOfs, yOfs)
            card:SetBackdrop({
                bgFile = W8,
                edgeFile = W8,
                edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            card:SetBackdropColor(TC("surfaceBg"))
            card:SetBackdropBorderColor(0, 0, 0, 0)

            -- Gradient banner (accent-tinted, slightly different hue for follower)
            local banner = card:CreateTexture(nil, "BACKGROUND", nil, 2)
            banner:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
            banner:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
            banner:SetHeight(math.floor(CARD_H * 0.40))
            banner:SetTexture(W8)
            ApplyGradient(banner, "HORIZONTAL",
                dAccent[1], dAccent[2], dAccent[3], 0.10,
                dAccent[1], dAccent[2], dAccent[3], 0.02)
            card._banner = banner

            -- Large watermark abbreviation
            local watermark = card:CreateFontString(nil, "ARTWORK", nil, 1)
            TrySetFont(watermark, TITLE_FONT, 32, "OUTLINE")
            watermark:SetPoint("RIGHT", card, "RIGHT", -10, 8)
            watermark:SetTextColor(dAccent[1], dAccent[2], dAccent[3], 0.10)
            watermark:SetText(fInfo.abbr)
            card._watermark = watermark

            -- Left accent bar (4px)
            local acBar = card:CreateTexture(nil, "OVERLAY", nil, 2)
            acBar:SetSize(4, CARD_H)
            acBar:SetPoint("LEFT", card, "LEFT", 0, 0)
            acBar:SetColorTexture(dAccent[1], dAccent[2], dAccent[3], 1)
            card._accentBar = acBar

            -- Abbreviation (top-left)
            local abbrText = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(abbrText, TITLE_FONT, 12, "OUTLINE")
            abbrText:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -12)
            abbrText:SetTextColor(dAccent[1], dAccent[2], dAccent[3])
            abbrText:SetText(fInfo.abbr)
            card._abbrText = abbrText

            -- Dungeon name
            local nameText = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(nameText, TITLE_FONT, 13, "OUTLINE")
            nameText:SetPoint("TOPLEFT", abbrText, "TOPRIGHT", 10, 0)
            nameText:SetPoint("RIGHT", card, "RIGHT", -12, 0)
            nameText:SetJustifyH("LEFT")
            nameText:SetTextColor(TC("bodyText"))
            nameText:SetText(fInfo.name)
            card._nameText = nameText

            -- Info line (middle) — shows "Normal · Solo with Followers"
            local infoText = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(infoText, BODY_FONT, 11, "")
            infoText:SetPoint("LEFT", card, "LEFT", 14, -4)
            infoText:SetPoint("RIGHT", card, "RIGHT", -12, 0)
            infoText:SetJustifyH("LEFT")
            infoText:SetTextColor(0.35, 0.75, 0.55)
            infoText:SetText("Normal \194\183 Solo with Followers")
            card._bestText = infoText

            -- Follower badge (bottom-left)
            local badge = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(badge, BODY_FONT, 9, "")
            badge:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 14, 10)
            badge:SetTextColor(TC("mutedText"))
            badge:SetText("FOLLOWER")
            card._scoreText = badge

            -- Selection state
            card._selected = false
            card._dungeonID = fInfo.dungeonID
            card._mapID = fInfo.mapID
            card._dungeonName = fInfo.name
            card._dungeonAccent = dAccent
            card._isFollower = true
            card._minLevel = fInfo.minLevel or 0
            card._maxLevel = fInfo.maxLevel or 0

            -- Hover
            card:SetScript("OnEnter", function(self)
                if not self._selected then
                    local cAc = self._dungeonAccent
                    self:SetBackdropColor(cAc[1], cAc[2], cAc[3], 0.05)
                    self:SetBackdropBorderColor(cAc[1], cAc[2], cAc[3], 0.12)
                end
            end)
            card:SetScript("OnLeave", function(self)
                if not self._selected then
                    self:SetBackdropColor(TC("surfaceBg"))
                    self:SetBackdropBorderColor(0, 0, 0, 0)
                end
            end)

            -- Click to toggle selection
            card:SetScript("OnClick", function(self)
                self._selected = not self._selected
                if self._selected then
                    local cAc = self._dungeonAccent
                    self:SetBackdropColor(cAc[1], cAc[2], cAc[3], 0.10)
                    self:SetBackdropBorderColor(cAc[1], cAc[2], cAc[3], 0.25)
                    if Panel._state.dungeonQueueMode ~= "specific" and R.dungeonTypeBtn then
                        Panel._state.dungeonQueueMode = "specific"
                        R.dungeonTypeBtn._label:SetText("Selected Dungeon")
                        R.dungeonTypeBtn:SetBackdropBorderColor(TC("accent"))
                        R.dungeonTypeBtn._label:SetTextColor(TC("accent"))
                    end
                else
                    self:SetBackdropColor(TC("surfaceBg"))
                    self:SetBackdropBorderColor(0, 0, 0, 0)
                    local anySelected = false
                    for _, c in ipairs(R.dungeonCards or {}) do
                        if c._selected then anySelected = true; break end
                    end
                    if not anySelected then
                        for _, c in ipairs(R.followerCards or {}) do
                            if c._selected then anySelected = true; break end
                        end
                    end
                    if not anySelected and R.dungeonTypeBtn then
                        Panel._state.dungeonQueueMode = "random"
                        R.dungeonTypeBtn._label:SetText("Random Dungeon")
                        R.dungeonTypeBtn:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
                        R.dungeonTypeBtn._label:SetTextColor(TC("bodyText"))
                    end
                end
            end)

            R.followerCards[i] = card
        end
    end

    -- ---- Bottom Bar (50px, anchored to bottom) ----
    local bottomBar = CreateFrame("Frame", nil, dungeonContent, "BackdropTemplate")
    bottomBar:SetHeight(BOTTOM_BAR_H)
    bottomBar:SetPoint("BOTTOMLEFT", dungeonContent, "BOTTOMLEFT", 0, 0)
    bottomBar:SetPoint("BOTTOMRIGHT", dungeonContent, "BOTTOMRIGHT", 0, 0)
    bottomBar:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    bottomBar:SetBackdropColor(0, 0, 0, 0.30)
    bottomBar:SetBackdropBorderColor(1, 1, 1, 0.05)
    R.dungeonBottomBar = bottomBar

    -- 1px divider at top of bottom bar
    local bbDiv = bottomBar:CreateTexture(nil, "OVERLAY", nil, 2)
    bbDiv:SetHeight(1)
    bbDiv:SetPoint("TOPLEFT", bottomBar, "TOPLEFT", 0, 0)
    bbDiv:SetPoint("TOPRIGHT", bottomBar, "TOPRIGHT", 0, 0)
    bbDiv:SetColorTexture(TC("divider"))

    -- Type toggle button: Random Dungeon / Selected Dungeon (left side)
    local typeBtn = CreateFrame("Button", nil, bottomBar, "BackdropTemplate")
    typeBtn:SetSize(160, 28)
    typeBtn:SetPoint("LEFT", bottomBar, "LEFT", 12, 0)
    typeBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    typeBtn:SetBackdropColor(0.06, 0.06, 0.08, 0.7)
    typeBtn:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
    local typeBtnLabel = typeBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(typeBtnLabel, BODY_FONT, 10, "OUTLINE")
    typeBtnLabel:SetPoint("CENTER")
    typeBtnLabel:SetTextColor(TC("bodyText"))
    typeBtnLabel:SetText("Random Dungeon")
    typeBtn._label = typeBtnLabel
    Panel._state.dungeonQueueMode = "random" -- "random" or "specific"

    typeBtn:SetScript("OnClick", function(self)
        if Panel._state.dungeonQueueMode == "random" then
            Panel._state.dungeonQueueMode = "specific"
            self._label:SetText("Selected Dungeon")
            self:SetBackdropBorderColor(TC("accent"))
            self._label:SetTextColor(TC("accent"))
        else
            Panel._state.dungeonQueueMode = "random"
            self._label:SetText("Random Dungeon")
            self:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
            self._label:SetTextColor(TC("bodyText"))
        end
    end)
    typeBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.1, 0.1, 0.13, 0.8)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Click to toggle between Random and Selected Dungeon queue")
        GameTooltip:Show()
    end)
    typeBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.06, 0.06, 0.08, 0.7)
        GameTooltip:Hide()
    end)
    R.dungeonTypeBtn = typeBtn

    -- Queue / Find Group button (right side)
    local queueBtn = CreateFrame("Button", nil, bottomBar, "BackdropTemplate")
    queueBtn:SetSize(120, 32)
    queueBtn:SetPoint("RIGHT", bottomBar, "RIGHT", -12, 0)
    queueBtn:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    queueBtn:SetBackdropColor(TC("glassBg"))
    queueBtn:SetBackdropBorderColor(TC("glassBorder"))

    local qbFrost = queueBtn:CreateTexture(nil, "OVERLAY", nil, 3)
    qbFrost:SetHeight(1)
    qbFrost:SetPoint("TOPLEFT", queueBtn, "TOPLEFT", 1, -1)
    qbFrost:SetPoint("TOPRIGHT", queueBtn, "TOPRIGHT", -1, -1)
    qbFrost:SetColorTexture(1, 1, 1, 0.08)

    local queueBtnLabel = queueBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(queueBtnLabel, TITLE_FONT, 12, "OUTLINE")
    queueBtnLabel:SetPoint("CENTER")
    queueBtnLabel:SetTextColor(TC("accent"))
    queueBtnLabel:SetText("Find Group")

    queueBtn:SetScript("OnEnter", function(self)
        local r, g, b = TC("glassBg")
        self:SetBackdropColor(r + 0.05, g + 0.05, b + 0.05, 0.85)
    end)
    queueBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(TC("glassBg"))
    end)

    queueBtn:SetScript("OnClick", function()
        local roles = Panel._state.dungeonRoles
        pcall(SetLFGRoles, false, roles.tank, roles.healer, roles.dps)
        local lfgCat = LE_LFG_CATEGORY_LFD or 1

        Panel._state.lastQueuedDungeons = {}
        Panel._state.dungeonQueueAttempted = true
        Panel._state._queueErrorMsgs = {}
        if Panel._state.dungeonQueueMode == "specific" then
            local queued = false
            local names = {}
            -- Clear any previous LFG selections before queuing specific dungeons
            if ClearAllLFGDungeons then pcall(ClearAllLFGDungeons, lfgCat) end
            for _, card in ipairs(R.dungeonCards or {}) do
                if card._selected then
                    -- Use LFG dungeon ID (mapped from name), fall back to challenge map ID
                    local qID = card._lfgDungeonID or card._mapID
                    local cardName = card._dungeonName or (card._nameText and card._nameText:GetText()) or tostring(qID)
                    table.insert(Panel._state.lastQueuedDungeons, { id = qID, name = cardName })
                    if SetLFGDungeon then pcall(SetLFGDungeon, lfgCat, qID) end
                    table.insert(names, cardName)
                    queued = true
                end
            end
            -- Also check selected follower dungeon cards
            for _, card in ipairs(R.followerCards or {}) do
                if card._selected then
                    local qID = card._dungeonID or card._mapID
                    local cardName = card._dungeonName or (card._nameText and card._nameText:GetText()) or tostring(qID)
                    table.insert(Panel._state.lastQueuedDungeons, { id = qID, name = cardName })
                    if SetLFGDungeon then pcall(SetLFGDungeon, lfgCat, qID) end
                    table.insert(names, cardName)
                    queued = true
                end
            end
            if not queued then return end
            -- Join with all selected dungeons set
            pcall(JoinLFG, lfgCat)
            Panel._state.dungeonQueuedNames = table.concat(names, ", ")
        else
            local randomID = nil
            local ok, list = pcall(GetRandomDungeonBestChoice)
            if ok and list then randomID = list end
            if randomID then
                table.insert(Panel._state.lastQueuedDungeons, { id = randomID, name = tostring(randomID) })
                pcall(JoinSingleLFG, lfgCat, randomID)
                local dname = tostring(randomID)
                if GetLFGDungeonInfo then
                    local okN, n = pcall(GetLFGDungeonInfo, randomID)
                    if okN and n then dname = n end
                end
                Panel._state.dungeonQueuedNames = dname
                if Panel._state.lastQueuedDungeons[1] then
                    Panel._state.lastQueuedDungeons[1].name = dname
                end
            end
        end
        -- Check queue status at 0.3s, 0.6s, 1.0s — first detection of "not in queue" shows toast
        local function CheckQueueResult()
            if not Panel._state.dungeonQueueAttempted then return end
            local lfgCheck = LE_LFG_CATEGORY_LFD or 1
            local okQ, hasData = pcall(GetLFGQueueStats, lfgCheck)
            if okQ and hasData then
                -- Successfully in queue
                Panel._state.dungeonQueueAttempted = false
                Panel.UpdateDungeonQueueStatus()
                return true
            end
            return false
        end
        C_Timer.After(0.3, function()
            if not Panel._state.dungeonQueueAttempted then return end
            if CheckQueueResult() then return end
            C_Timer.After(0.3, function()
                if not Panel._state.dungeonQueueAttempted then return end
                if CheckQueueResult() then return end
                C_Timer.After(0.4, function()
                    if not Panel._state.dungeonQueueAttempted then return end
                    if not CheckQueueResult() then
                        -- Still not in queue after 1s = rejected
                        Panel._state.dungeonQueueAttempted = false
                        local tried = Panel._state.lastQueuedDungeons or {}
                        local names = {}
                        for _, entry in ipairs(tried) do
                            table.insert(names, entry.name or tostring(entry.id))
                        end
                        local dungeonList = #names > 0 and table.concat(names, "\n") or "Unknown Dungeon"
                        local errorMsgs = Panel._state._queueErrorMsgs or {}
                        local reason = #errorMsgs > 0 and table.concat(errorMsgs, "\n") or "You do not meet the requirements.\nCheck your item level, role, and dungeon eligibility."
                        Panel.ShowToast("Queue Rejected", dungeonList .. "\n\n" .. reason, 8)
                    end
                end)
            end)
        end)
    end)
    R.dungeonQueueBtn = queueBtn

    end -- end Dungeon Finder scope

    -- ================================================================
    -- Raid Finder overlay (full implementation)
    -- ================================================================
    do -- scope block
    local raidContent = CreateFrame("Frame", nil, content)
    raidContent:SetAllPoints()
    raidContent:Hide()
    R.raidContent = raidContent

    -- Initialize raid role state
    Panel._state.raidRoles = { tank = false, healer = false, dps = false }

    -- ---- Raid Hero Banner (130px) ----
    -- Atlas artwork background with vignettes. Boss progress dots, tier name.
    local raidHero = CreateFrame("Frame", nil, raidContent)
    raidHero:SetHeight(190)
    raidHero:SetPoint("TOPLEFT", raidContent, "TOPLEFT", 0, 0)
    raidHero:SetPoint("TOPRIGHT", raidContent, "TOPRIGHT", 0, 0)
    R.raidHero = raidHero

    local raidAc = { 0.80, 0.65, 0.20 }

    -- Background layers (same pattern as dungeon hero)
    local rhBase = raidHero:CreateTexture(nil, "BACKGROUND", nil, -8)
    rhBase:SetAllPoints()
    rhBase:SetColorTexture(0.02, 0.02, 0.03, 1)

    local rhAtlas = raidHero:CreateTexture(nil, "BACKGROUND", nil, -7)
    rhAtlas:SetAllPoints()
    if not TrySetAtlasFromList(rhAtlas, HERO_ATLASES.raids) then
        rhAtlas:SetColorTexture(0, 0, 0, 0)
    end
    rhAtlas:SetAlpha(0.40)

    local rhVigTop = raidHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    rhVigTop:SetHeight(80)
    rhVigTop:SetPoint("TOPLEFT", raidHero, "TOPLEFT", 0, 0)
    rhVigTop:SetPoint("TOPRIGHT", raidHero, "TOPRIGHT", 0, 0)
    rhVigTop:SetTexture(W8)
    ApplyGradient(rhVigTop, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.5)

    local rhVigBot = raidHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    rhVigBot:SetHeight(60)
    rhVigBot:SetPoint("BOTTOMLEFT", raidHero, "BOTTOMLEFT", 0, 0)
    rhVigBot:SetPoint("BOTTOMRIGHT", raidHero, "BOTTOMRIGHT", 0, 0)
    rhVigBot:SetTexture(W8)
    ApplyGradient(rhVigBot, "VERTICAL", 0, 0, 0, 0.6, 0, 0, 0, 0)

    -- Left reading vignette
    local rhVigLeft = raidHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    rhVigLeft:SetWidth(math.floor(CFG.WIDTH * 0.40))
    rhVigLeft:SetPoint("TOPLEFT", raidHero, "TOPLEFT", 0, 0)
    rhVigLeft:SetPoint("BOTTOMLEFT", raidHero, "BOTTOMLEFT", 0, 0)
    rhVigLeft:SetTexture(W8)
    ApplyGradient(rhVigLeft, "HORIZONTAL", 0, 0, 0, 0.25, 0, 0, 0, 0)

    -- Accent wash at bottom
    local rhAccentWash = raidHero:CreateTexture(nil, "BACKGROUND", nil, -4)
    rhAccentWash:SetHeight(60)
    rhAccentWash:SetPoint("BOTTOMLEFT", raidHero, "BOTTOMLEFT", 0, 0)
    rhAccentWash:SetPoint("BOTTOMRIGHT", raidHero, "BOTTOMRIGHT", 0, 0)
    rhAccentWash:SetTexture(W8)
    ApplyGradient(rhAccentWash, "VERTICAL", raidAc[1], raidAc[2], raidAc[3], 0.03, raidAc[1], raidAc[2], raidAc[3], 0)

    -- ROW 1: Context bar
    local rhCtxLeft = raidHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(rhCtxLeft, BODY_FONT, 9, "OUTLINE")
    rhCtxLeft:SetPoint("TOPLEFT", raidHero, "TOPLEFT", CFG.PAD + 2, -8)
    rhCtxLeft:SetTextColor(TC("mutedText"))
    rhCtxLeft:SetText("")

    local rhCtxRight = raidHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(rhCtxRight, BODY_FONT, 9, "OUTLINE")
    rhCtxRight:SetPoint("TOPRIGHT", raidHero, "TOPRIGHT", -CFG.PAD, -8)
    rhCtxRight:SetTextColor(TC("mutedText"))
    rhCtxRight:SetText("")
    R.raidHeroWingProgress = rhCtxRight

    -- ROW 2: Centered player name + class icon
    local rhClassIcon = raidHero:CreateTexture(nil, "OVERLAY")
    rhClassIcon:SetSize(22, 22)
    rhClassIcon:SetPoint("TOP", raidHero, "TOP", -46, -34)
    rhClassIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes")
    R.raidHeroClassIcon = rhClassIcon

    local rhPlayerName = raidHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(rhPlayerName, TITLE_FONT, 14, "OUTLINE")
    rhPlayerName:SetPoint("LEFT", rhClassIcon, "RIGHT", 6, 0)
    rhPlayerName:SetTextColor(TC("bodyText"))
    R.raidHeroPlayerName = rhPlayerName

    -- ROW 3: Spec + iLvl
    local rhSpecLine = raidHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(rhSpecLine, BODY_FONT, 10, "")
    rhSpecLine:SetPoint("TOP", rhClassIcon, "BOTTOM", 20, -2)
    rhSpecLine:SetTextColor(TC("mutedText"))
    R.raidHeroSpecLine = rhSpecLine

    -- ROW 4: Pill bar (3 role toggles + 2 stat pills)
    local PILL_H = 28
    local PILL_GAP = 8
    local ROLE_PILL_W = 80
    local RAID_STAT_W = 180
    local totalPillW = 3 * ROLE_PILL_W + 2 * RAID_STAT_W + 4 * PILL_GAP
    local pillStartX = math.floor((CFG.WIDTH - totalPillW) / 2)
    local pillY = -82

    -- Helper: stat pill (modernized — borderless surface, gradient dot)
    local function CreateRaidStatPill(xOfs, acColor)
        local pill = CreateFrame("Frame", nil, raidHero, "BackdropTemplate")
        pill:SetSize(RAID_STAT_W, PILL_H)
        pill:SetPoint("TOPLEFT", raidHero, "TOPLEFT", xOfs, pillY)
        pill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        pill:SetBackdropColor(TC("surfaceBg"))
        pill:SetBackdropBorderColor(0, 0, 0, 0)
        local dot = pill:CreateTexture(nil, "OVERLAY", nil, 2)
        dot:SetSize(4, PILL_H - 8)
        dot:SetPoint("LEFT", pill, "LEFT", 4, 0)
        dot:SetTexture(W8)
        if dot.SetGradient and CreateColor then
            dot:SetGradient("VERTICAL",
                CreateColor(acColor[1], acColor[2], acColor[3], 0.3),
                CreateColor(acColor[1], acColor[2], acColor[3], 1.0))
        else
            dot:SetColorTexture(acColor[1], acColor[2], acColor[3])
        end
        pill._dot = dot
        local lbl = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 9, "OUTLINE")
        lbl:SetPoint("LEFT", dot, "RIGHT", 6, 0)
        lbl:SetTextColor(TC("mutedText"))
        pill._label = lbl
        local val = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(val, TITLE_FONT, 11, "OUTLINE")
        val:SetPoint("RIGHT", pill, "RIGHT", -8, 0)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(TC("bodyText"))
        pill._value = val
        local frost = pill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", pill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", pill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end
        local botLine = pill:CreateTexture(nil, "BACKGROUND", nil, 2)
        botLine:SetHeight(1)
        botLine:SetPoint("BOTTOMLEFT", pill, "BOTTOMLEFT", 1, 1)
        botLine:SetPoint("BOTTOMRIGHT", pill, "BOTTOMRIGHT", -1, 1)
        botLine:SetColorTexture(0, 0, 0, 0.08)
        return pill
    end

    -- Role toggle pills
    local raidRoleDefs = {
        { key = "tank",   atlas = "UI-LFG-RoleIcon-Tank",   label = "Tank" },
        { key = "healer", atlas = "UI-LFG-RoleIcon-Healer", label = "Healer" },
        { key = "dps",    atlas = "UI-LFG-RoleIcon-DPS",    label = "DPS" },
    }
    R.raidRoleCards = {}

    for ri, rd in ipairs(raidRoleDefs) do
        local rpill = CreateFrame("Button", nil, raidHero, "BackdropTemplate")
        rpill:SetSize(ROLE_PILL_W, PILL_H)
        rpill:SetPoint("TOPLEFT", raidHero, "TOPLEFT", pillStartX + (ri - 1) * (ROLE_PILL_W + PILL_GAP), pillY)
        rpill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        rpill:SetBackdropColor(TC("surfaceBg"))
        rpill:SetBackdropBorderColor(0, 0, 0, 0)
        local selGlow = rpill:CreateTexture(nil, "BACKGROUND", nil, 1)
        selGlow:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        selGlow:SetPoint("BOTTOMRIGHT", rpill, "BOTTOMRIGHT", -1, 1)
        selGlow:SetColorTexture(0, 0, 0, 0)
        rpill._selGlow = selGlow
        local ricon = rpill:CreateTexture(nil, "ARTWORK")
        ricon:SetSize(16, 16)
        ricon:SetPoint("LEFT", rpill, "LEFT", 8, 0)
        pcall(ricon.SetAtlas, ricon, rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rpill._icon = ricon
        local rlbl = rpill:CreateFontString(nil, "OVERLAY")
        TrySetFont(rlbl, BODY_FONT, 10, "OUTLINE")
        rlbl:SetPoint("LEFT", ricon, "RIGHT", 5, 0)
        rlbl:SetTextColor(TC("mutedText"))
        rlbl:SetText(rd.label)
        rpill._label = rlbl
        rpill._roleKey = rd.key
        local frost = rpill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", rpill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end
        rpill:SetScript("OnClick", function(self)
            Panel._state.raidRoles[self._roleKey] = not Panel._state.raidRoles[self._roleKey]
            Panel.UpdateRaidRoleCards()
        end)
        rpill:SetScript("OnEnter", function(self)
            if not Panel._state.raidRoles[self._roleKey] then self._icon:SetAlpha(0.7) end
        end)
        rpill:SetScript("OnLeave", function(self)
            if not Panel._state.raidRoles[self._roleKey] then self._icon:SetAlpha(0.4) end
        end)
        R.raidRoleCards[ri] = rpill
    end
    R.raidRoleBtns = R.raidRoleCards

    -- Stat pills: RAID TIER + BOSSES
    local raidTierPill = CreateRaidStatPill(pillStartX + 3 * (ROLE_PILL_W + PILL_GAP), raidAc)
    raidTierPill._label:SetText("TIER")
    raidTierPill._value:SetText(DeriveRaidTierName())
    R.raidHeroTierName = raidTierPill._value
    R.raidTierName = raidTierPill._value

    local raidBossPill = CreateRaidStatPill(pillStartX + 3 * (ROLE_PILL_W + PILL_GAP) + RAID_STAT_W + PILL_GAP, raidAc)
    raidBossPill._label:SetText("BOSSES")
    raidBossPill._value:SetText("--")
    R.raidHeroBossCount = raidBossPill._value

    -- ROW 5: Boss kill dot container
    -- ROW 5: Wing progress bars (up to 4, glass pill style)
    local WING_BAR_W = 200
    local WING_BAR_H = 24
    local WING_BAR_GAP = 5
    local WING_BAR_COLS = 4
    R.raidWingBars = {}

    local wingAccents = {
        { 0.80, 0.65, 0.20 }, { 0.60, 0.30, 0.30 },
        { 0.30, 0.50, 0.80 }, { 0.50, 0.70, 0.30 },
    }

    for wi = 1, 4 do
        local col = (wi - 1) % WING_BAR_COLS
        local row = math.floor((wi - 1) / WING_BAR_COLS)
        local totalW = WING_BAR_COLS * WING_BAR_W + (WING_BAR_COLS - 1) * WING_BAR_GAP
        local startX = math.floor((CFG.WIDTH - totalW) / 2)
        local xOfs = startX + col * (WING_BAR_W + WING_BAR_GAP)
        local yOfs = -120 - row * (WING_BAR_H + WING_BAR_GAP)

        local bar = CreateFrame("Frame", nil, raidHero, "BackdropTemplate")
        bar:SetSize(WING_BAR_W, WING_BAR_H)
        bar:SetPoint("TOPLEFT", raidHero, "TOPLEFT", xOfs, yOfs)
        bar:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        bar:SetBackdropColor(TC("surfaceBg"))
        bar:SetBackdropBorderColor(0, 0, 0, 0)

        local wAc = wingAccents[wi] or wingAccents[1]

        -- Gradient accent bar (left)
        local acBar = bar:CreateTexture(nil, "OVERLAY", nil, 2)
        acBar:SetSize(3, WING_BAR_H)
        acBar:SetPoint("LEFT", bar, "LEFT", 0, 0)
        acBar:SetTexture(W8)
        if acBar.SetGradient and CreateColor then
            acBar:SetGradient("VERTICAL",
                CreateColor(wAc[1], wAc[2], wAc[3], 0.25),
                CreateColor(wAc[1], wAc[2], wAc[3], 0.7))
        else
            acBar:SetColorTexture(wAc[1], wAc[2], wAc[3], 0.7)
        end

        -- Progress fill (behind text)
        local fill = bar:CreateTexture(nil, "ARTWORK", nil, 1)
        fill:SetHeight(WING_BAR_H - 2)
        fill:SetPoint("LEFT", bar, "LEFT", 1, 0)
        fill:SetWidth(1)
        fill:SetColorTexture(wAc[1], wAc[2], wAc[3], 0.15)
        bar._fill = fill

        -- Wing name (left)
        local nameText = bar:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameText, BODY_FONT, 9, "OUTLINE")
        nameText:SetPoint("LEFT", bar, "LEFT", 8, 0)
        nameText:SetTextColor(wAc[1], wAc[2], wAc[3])
        nameText:SetText("")
        bar._nameText = nameText

        -- Kill count (right)
        local countText = bar:CreateFontString(nil, "OVERLAY")
        TrySetFont(countText, TITLE_FONT, 10, "OUTLINE")
        countText:SetPoint("RIGHT", bar, "RIGHT", -6, 0)
        countText:SetJustifyH("RIGHT")
        countText:SetTextColor(TC("mutedText"))
        countText:SetText("")
        bar._countText = countText

        bar._accent = wAc
        bar:Hide()
        R.raidWingBars[wi] = bar
    end

    -- Progress bar (3px, with track highlight)
    local rhTrack = raidHero:CreateTexture(nil, "ARTWORK", nil, 1)
    rhTrack:SetHeight(3)
    rhTrack:SetPoint("BOTTOMLEFT", raidHero, "BOTTOMLEFT", CFG.PAD, 5)
    rhTrack:SetPoint("BOTTOMRIGHT", raidHero, "BOTTOMRIGHT", -CFG.PAD, 5)
    rhTrack:SetColorTexture(1, 1, 1, 0.04)
    R.raidHeroTrack = rhTrack

    local rhTrackHL = raidHero:CreateTexture(nil, "ARTWORK", nil, 1)
    rhTrackHL:SetHeight(1)
    rhTrackHL:SetPoint("TOPLEFT", rhTrack, "TOPLEFT", 0, 0)
    rhTrackHL:SetPoint("TOPRIGHT", rhTrack, "TOPRIGHT", 0, 0)
    rhTrackHL:SetColorTexture(1, 1, 1, 0.06)

    local rhFill = raidHero:CreateTexture(nil, "ARTWORK", nil, 2)
    rhFill:SetHeight(3)
    rhFill:SetPoint("LEFT", rhTrack, "LEFT", 0, 0)
    rhFill:SetWidth(1)
    rhFill:SetColorTexture(raidAc[1], raidAc[2], raidAc[3], 0.55)
    R.raidHeroFill = rhFill

    -- Bottom divider (gradient fade from center outward)
    local rhGlassDivL = raidHero:CreateTexture(nil, "OVERLAY", nil, 3)
    rhGlassDivL:SetHeight(1)
    rhGlassDivL:SetPoint("BOTTOMLEFT", raidHero, "BOTTOMLEFT", 0, 0)
    rhGlassDivL:SetPoint("BOTTOM", raidHero, "BOTTOM", 0, 0)
    rhGlassDivL:SetTexture(W8)
    ApplyGradient(rhGlassDivL, "HORIZONTAL", 1, 1, 1, 0, 1, 1, 1, 0.06)

    local rhGlassDivR = raidHero:CreateTexture(nil, "OVERLAY", nil, 3)
    rhGlassDivR:SetHeight(1)
    rhGlassDivR:SetPoint("BOTTOM", raidHero, "BOTTOM", 0, 0)
    rhGlassDivR:SetPoint("BOTTOMRIGHT", raidHero, "BOTTOMRIGHT", 0, 0)
    rhGlassDivR:SetTexture(W8)
    ApplyGradient(rhGlassDivR, "HORIZONTAL", 1, 1, 1, 0.06, 1, 1, 1, 0)

    -- ---- Raid Queue Status Bar (30px, hidden by default) ----
    local raidQueueBar = CreateFrame("Frame", nil, raidContent, "BackdropTemplate")
    raidQueueBar:SetHeight(30)
    raidQueueBar:SetPoint("TOPLEFT", raidHero, "BOTTOMLEFT", 0, 0)
    raidQueueBar:SetPoint("TOPRIGHT", raidHero, "BOTTOMRIGHT", 0, 0)
    raidQueueBar:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    local rqbAc = activeTheme.accent
    raidQueueBar:SetBackdropColor(rqbAc[1], rqbAc[2], rqbAc[3], 0.10)
    raidQueueBar:SetBackdropBorderColor(rqbAc[1], rqbAc[2], rqbAc[3], 0.20)
    raidQueueBar:Hide()
    R.raidQueueBar = raidQueueBar

    local raidQueueText = raidQueueBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(raidQueueText, BODY_FONT, 11, "OUTLINE")
    raidQueueText:SetPoint("LEFT", raidQueueBar, "LEFT", 12, 0)
    raidQueueText:SetTextColor(TC("bodyText"))
    raidQueueText:SetText("Queued...")
    R.raidQueueText = raidQueueText

    local raidCancelBtn = CreateFrame("Button", nil, raidQueueBar, "BackdropTemplate")
    raidCancelBtn:SetSize(60, 24)
    raidCancelBtn:SetPoint("RIGHT", raidQueueBar, "RIGHT", -8, 0)
    raidCancelBtn:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    raidCancelBtn:SetBackdropColor(0.3, 0.05, 0.05, 0.6)
    raidCancelBtn:SetBackdropBorderColor(1, 0.3, 0.3, 0.3)
    local raidCancelLabel = raidCancelBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(raidCancelLabel, BODY_FONT, 10, "OUTLINE")
    raidCancelLabel:SetPoint("CENTER")
    raidCancelLabel:SetTextColor(1, 0.4, 0.4)
    raidCancelLabel:SetText("Cancel")
    raidCancelBtn:SetScript("OnClick", function()
        pcall(LeaveLFG, LE_LFG_CATEGORY_RF or 2)
        C_Timer.After(0.3, function() Panel.UpdateRaidQueueStatus() end)
    end)
    raidCancelBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(0.4, 0.08, 0.08, 0.8)
    end)
    raidCancelBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0.3, 0.05, 0.05, 0.6)
    end)

    -- "No wings available" fallback message (hidden by default)
    local raidNoWingsMsg = raidContent:CreateFontString(nil, "OVERLAY")
    TrySetFont(raidNoWingsMsg, TITLE_FONT, 14, "OUTLINE")
    raidNoWingsMsg:SetPoint("CENTER", raidContent, "CENTER", 0, 0)
    raidNoWingsMsg:SetTextColor(TC("mutedText"))
    raidNoWingsMsg:SetText("No LFR wings available at your level")
    raidNoWingsMsg:Hide()
    R.raidNoWingsMsg = raidNoWingsMsg

    -- ---- Wing Cards (up to 4) ----
    local WING_CARD_H = 60
    local WING_GAP = 6
    local RAID_BOTTOM_BAR_H = 50
    local wingAccents = {
        { 0.80, 0.65, 0.20 }, -- gold
        { 0.60, 0.30, 0.30 }, -- red
        { 0.30, 0.50, 0.80 }, -- blue
        { 0.50, 0.70, 0.30 }, -- green
    }

    R.raidWingCards = {}
    for i = 1, 4 do
        local wcard = CreateFrame("Button", nil, raidContent, "BackdropTemplate")
        wcard:SetHeight(WING_CARD_H)
        wcard:SetPoint("LEFT", raidContent, "LEFT", CFG.PAD, 0)
        wcard:SetPoint("RIGHT", raidContent, "RIGHT", -CFG.PAD, 0)
        -- Position below queue bar (header info is now in the hero)
        local yOff = -(8 + (i - 1) * (WING_CARD_H + WING_GAP))
        wcard:SetPoint("TOP", raidQueueBar, "BOTTOM", 0, yOff)

        wcard:SetBackdrop({
            bgFile = W8,
            edgeFile = W8,
            edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        wcard:SetBackdropColor(TC("surfaceBg"))
        wcard:SetBackdropBorderColor(0, 0, 0, 0)

        -- Soft frost line at top
        local wFrost = wcard:CreateTexture(nil, "OVERLAY", nil, 3)
        wFrost:SetHeight(1)
        wFrost:SetPoint("TOPLEFT", wcard, "TOPLEFT", 1, -1)
        wFrost:SetPoint("TOPRIGHT", wcard, "TOPRIGHT", -1, -1)
        wFrost:SetTexture(W8)
        if wFrost.SetGradient and CreateColor then
            wFrost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.06))
        else
            wFrost:SetColorTexture(1, 1, 1, 0.06)
        end

        -- Left accent bar (4px, gradient)
        local wAccent = wingAccents[i] or wingAccents[1]
        local wAccBar = wcard:CreateTexture(nil, "OVERLAY", nil, 2)
        wAccBar:SetSize(4, WING_CARD_H)
        wAccBar:SetPoint("LEFT", wcard, "LEFT", 0, 0)
        wAccBar:SetTexture(W8)
        if wAccBar.SetGradient and CreateColor then
            wAccBar:SetGradient("VERTICAL",
                CreateColor(wAccent[1], wAccent[2], wAccent[3], 0.3),
                CreateColor(wAccent[1], wAccent[2], wAccent[3], 1.0))
        else
            wAccBar:SetColorTexture(wAccent[1], wAccent[2], wAccent[3], 1)
        end
        wcard._accentBar = wAccBar
        wcard._wingAccent = wAccent

        -- Wing name
        local wNameText = wcard:CreateFontString(nil, "OVERLAY")
        TrySetFont(wNameText, TITLE_FONT, 13, "OUTLINE")
        wNameText:SetPoint("TOPLEFT", wcard, "TOPLEFT", 14, -12)
        wNameText:SetPoint("RIGHT", wcard, "RIGHT", -12, 0)
        wNameText:SetJustifyH("LEFT")
        wNameText:SetTextColor(TC("bodyText"))
        wNameText:SetText("Wing " .. i)
        wcard._nameText = wNameText

        -- Info line
        local wInfoText = wcard:CreateFontString(nil, "OVERLAY")
        TrySetFont(wInfoText, BODY_FONT, 10, "")
        wInfoText:SetPoint("BOTTOMLEFT", wcard, "BOTTOMLEFT", 14, 10)
        wInfoText:SetPoint("RIGHT", wcard, "RIGHT", -12, 0)
        wInfoText:SetJustifyH("LEFT")
        wInfoText:SetTextColor(TC("mutedText"))
        wInfoText:SetText("Select to queue")
        wcard._infoText = wInfoText

        -- Selection state
        wcard._selected = false
        wcard._wingID = nil

        -- Hover effects (smooth accent tint)
        wcard:SetScript("OnEnter", function(self)
            if not self._selected then
                local wa = self._wingAccent
                self:SetBackdropColor(wa[1], wa[2], wa[3], 0.05)
            end
        end)
        wcard:SetScript("OnLeave", function(self)
            if not self._selected then
                self:SetBackdropColor(TC("surfaceBg"))
                self:SetBackdropBorderColor(0, 0, 0, 0)
            end
        end)

        -- Click to toggle selection (accent wash)
        wcard:SetScript("OnClick", function(self)
            self._selected = not self._selected
            if self._selected then
                local ac = self._wingAccent
                self:SetBackdropColor(ac[1], ac[2], ac[3], 0.10)
                self:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.20)
            else
                self:SetBackdropColor(TC("surfaceBg"))
                self:SetBackdropBorderColor(0, 0, 0, 0)
            end
        end)

        wcard:Hide()
        R.raidWingCards[i] = wcard
    end

    -- ---- Raid Bottom Bar (50px) ----
    local raidBottomBar = CreateFrame("Frame", nil, raidContent, "BackdropTemplate")
    raidBottomBar:SetHeight(RAID_BOTTOM_BAR_H)
    raidBottomBar:SetPoint("BOTTOMLEFT", raidContent, "BOTTOMLEFT", 0, 0)
    raidBottomBar:SetPoint("BOTTOMRIGHT", raidContent, "BOTTOMRIGHT", 0, 0)
    raidBottomBar:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    raidBottomBar:SetBackdropColor(0, 0, 0, 0.30)
    raidBottomBar:SetBackdropBorderColor(1, 1, 1, 0.05)
    R.raidBottomBar = raidBottomBar

    -- 1px divider at top of bottom bar
    local rbbDiv = raidBottomBar:CreateTexture(nil, "OVERLAY", nil, 2)
    rbbDiv:SetHeight(1)
    rbbDiv:SetPoint("TOPLEFT", raidBottomBar, "TOPLEFT", 0, 0)
    rbbDiv:SetPoint("TOPRIGHT", raidBottomBar, "TOPRIGHT", 0, 0)
    rbbDiv:SetColorTexture(TC("divider"))

    -- Role toggle buttons (left side)
    local RAID_ROLE_SIZE = 32
    local raidRoleData = {
        { key = "tank",   atlas = "roleicon-tank" },
        { key = "healer", atlas = "roleicon-healer" },
        { key = "dps",    atlas = "roleicon-dps" },
    }
    R.raidRoleBtns = {}

    for ri, rd in ipairs(raidRoleData) do
        local rbtn = CreateFrame("Button", nil, raidBottomBar)
        rbtn:SetSize(RAID_ROLE_SIZE, RAID_ROLE_SIZE)
        rbtn:SetPoint("LEFT", raidBottomBar, "LEFT", 12 + (ri - 1) * (RAID_ROLE_SIZE + 6), 0)

        local ricon = rbtn:CreateTexture(nil, "ARTWORK")
        ricon:SetSize(RAID_ROLE_SIZE - 4, RAID_ROLE_SIZE - 4)
        ricon:SetPoint("CENTER")
        ricon:SetAtlas(rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rbtn._icon = ricon
        rbtn._roleKey = rd.key

        rbtn:SetScript("OnClick", function(self)
            local st = Panel._state.raidRoles
            st[self._roleKey] = not st[self._roleKey]
            if st[self._roleKey] then
                self._icon:SetDesaturated(false)
                self._icon:SetAlpha(1.0)
            else
                self._icon:SetDesaturated(true)
                self._icon:SetAlpha(0.4)
            end
        end)

        rbtn:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(rd.key:sub(1,1):upper() .. rd.key:sub(2))
            GameTooltip:Show()
        end)
        rbtn:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        R.raidRoleBtns[ri] = rbtn
    end

    -- Queue for Selected button (right side)
    local raidQueueBtn = CreateFrame("Button", nil, raidBottomBar, "BackdropTemplate")
    raidQueueBtn:SetSize(140, 32)
    raidQueueBtn:SetPoint("RIGHT", raidBottomBar, "RIGHT", -12, 0)
    raidQueueBtn:SetBackdrop({
        bgFile = W8,
        edgeFile = W8,
        edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    raidQueueBtn:SetBackdropColor(TC("glassBg"))
    raidQueueBtn:SetBackdropBorderColor(TC("glassBorder"))

    -- Frost line at top of button
    local rqbFrost = raidQueueBtn:CreateTexture(nil, "OVERLAY", nil, 3)
    rqbFrost:SetHeight(1)
    rqbFrost:SetPoint("TOPLEFT", raidQueueBtn, "TOPLEFT", 1, -1)
    rqbFrost:SetPoint("TOPRIGHT", raidQueueBtn, "TOPRIGHT", -1, -1)
    rqbFrost:SetColorTexture(1, 1, 1, 0.08)

    local raidQueueBtnLabel = raidQueueBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(raidQueueBtnLabel, TITLE_FONT, 12, "OUTLINE")
    raidQueueBtnLabel:SetPoint("CENTER")
    raidQueueBtnLabel:SetTextColor(TC("accent"))
    raidQueueBtnLabel:SetText("Queue for Selected")

    raidQueueBtn:SetScript("OnEnter", function(self)
        local r, g, b = TC("glassBg")
        self:SetBackdropColor(r + 0.05, g + 0.05, b + 0.05, 0.85)
    end)
    raidQueueBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(TC("glassBg"))
    end)

    raidQueueBtn:SetScript("OnClick", function()
        local roles = Panel._state.raidRoles
        pcall(SetLFGRoles, false, roles.tank, roles.healer, roles.dps)
        local lfgCat = LE_LFG_CATEGORY_RF or 2

        local foundWing = false
        for _, wcard in ipairs(R.raidWingCards or {}) do
            if wcard._selected and wcard._wingID then
                Panel._state._raidQueuedWingName = wcard._nameText and wcard._nameText:GetText() or ("Wing " .. tostring(wcard._wingID))
                pcall(JoinSingleLFG, lfgCat, wcard._wingID)
                foundWing = true
                break
            end
        end

        if not foundWing then
            Panel.ShowToast("No Wing Selected", "Select a raid wing to queue for.", 4)
        else
            Panel._state.raidQueueAttempted = true
            local queuedWingName = Panel._state._raidQueuedWingName or "selected raid wing"
            C_Timer.After(1, function()
                if Panel._state.raidQueueAttempted then
                    Panel._state.raidQueueAttempted = false
                    local okQ, hasData = pcall(GetLFGQueueStats, lfgCat)
                    if not (okQ and hasData) then
                        Panel.ShowToast("Queue Rejected", queuedWingName .. "\n\nYou do not meet the requirements.\nCheck your item level, role, and raid eligibility.", 8)
                    else
                        Panel.UpdateRaidQueueStatus()
                    end
                end
            end)
        end
        C_Timer.After(0.5, function() Panel.UpdateRaidQueueStatus() end)
    end)
    R.raidQueueBtn = raidQueueBtn

    end -- end Raid Finder scope

    -- ==================================================================
    -- PVP Tab (hero + category sidebar + activity cards + queue bar + bottom bar)
    -- ==================================================================
    do -- scope block
    local pvpContent = CreateFrame("Frame", nil, content)
    pvpContent:SetAllPoints()
    pvpContent:Hide()
    R.pvpContent = pvpContent

    -- PVP BG Data
    local PVP_CATEGORY_DEFS = {
        { key = "quickmatch", label = "Quick Match" },
        { key = "rated",      label = "Rated" },
        { key = "premade",    label = "Premade Groups" },
        { key = "training",   label = "Training Grounds" },
    }
    local PVP_CAT_ACCENTS = {
        quickmatch = { 0.00, 0.78, 1.00 },
        rated      = { 1.00, 0.60, 0.00 },
        premade    = { 0.55, 0.55, 0.55 },
        training   = { 0.35, 0.75, 0.40 },
    }

    local QUICKMATCH_ACTIVITIES = {
        { name = "Random Battlegrounds",      isRandom = true, queueType = "random_bg" },
        { name = "Random Epic Battlegrounds", isRandom = true, queueType = "random_epic" },
        { name = "Arena Skirmish",            isSkirmish = true, queueType = "skirmish" },
        { name = "Brawl",                     isBrawl = true, queueType = "brawl", minLevel = 90 },
    }
    local SPECIFIC_BGS = {
        { name = "Warsong Gulch",           teamSize = "10v10" },
        { name = "Arathi Basin",            teamSize = "15v15" },
        { name = "Deephaul Ravine",         teamSize = "10v10" },
        { name = "Alterac Valley",          teamSize = "40v40" },
        { name = "Eye of the Storm",        teamSize = "15v15" },
        { name = "Isle of Conquest",        teamSize = "40v40" },
        { name = "The Battle for Gilneas",  teamSize = "10v10" },
        { name = "Battle for Wintergrasp",  teamSize = "40v40" },
        { name = "Ashran",                  teamSize = "40v40" },
        { name = "Twin Peaks",              teamSize = "10v10" },
        { name = "Silvershard Mines",       teamSize = "10v10" },
        { name = "Temple of Kotmogu",       teamSize = "10v10" },
        { name = "Seething Shore",          teamSize = "10v10" },
        { name = "Deepwind Gorge",          teamSize = "15v15" },
    }
    local RATED_ACTIVITIES = {
        { name = "Solo Shuffle (Arena)",        bracket = 7, queueType = "solo_arena" },
        { name = "Solo Shuffle (Battlegrounds)", bracket = 4, queueType = "solo_bg" },
        { name = "2v2 Arena",                   bracket = 1, queueType = "arena2v2" },
        { name = "3v3 Arena",                   bracket = 2, queueType = "arena3v3" },
        { name = "10v10 Rated Battlegrounds",   bracket = 3, queueType = "rated_bg" },
    }
    local TRAINING_ACTIVITIES = {
        { name = "Random Training Battlegrounds", isRandom = true, queueType = "training_random" },
        { name = "The Battle for Gilneas Training Grounds", queueType = "training_gilneas" },
        { name = "Silvershard Mines Training Grounds",      queueType = "training_silvershard" },
        { name = "Arathi Basin Training Grounds",           queueType = "training_arathi" },
    }

    -- ---- PVP Hero Banner (130px) ----
    local pvpHero = CreateFrame("Frame", nil, pvpContent)
    pvpHero:SetHeight(190)
    pvpHero:SetPoint("TOPLEFT", pvpContent, "TOPLEFT", 0, 0)
    pvpHero:SetPoint("TOPRIGHT", pvpContent, "TOPRIGHT", 0, 0)
    R.pvpHero = pvpHero

    local pvpAc = { 0.75, 0.30, 0.30 }

    -- Background layers (unified pattern)
    local pvpHeroBase = pvpHero:CreateTexture(nil, "BACKGROUND", nil, -8)
    pvpHeroBase:SetAllPoints()
    pvpHeroBase:SetColorTexture(0.02, 0.02, 0.03, 1)

    local pvpHeroAtlas = pvpHero:CreateTexture(nil, "BACKGROUND", nil, -7)
    pvpHeroAtlas:SetAllPoints()
    if not TrySetAtlasFromList(pvpHeroAtlas, HERO_ATLASES.premade) then
        pvpHeroAtlas:SetColorTexture(0, 0, 0, 0)
    end
    pvpHeroAtlas:SetAlpha(0.40)

    local pvpHeroVigTop = pvpHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    pvpHeroVigTop:SetHeight(80)
    pvpHeroVigTop:SetPoint("TOPLEFT", pvpHero, "TOPLEFT", 0, 0)
    pvpHeroVigTop:SetPoint("TOPRIGHT", pvpHero, "TOPRIGHT", 0, 0)
    pvpHeroVigTop:SetTexture(W8)
    ApplyGradient(pvpHeroVigTop, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.5)

    local pvpHeroVigBot = pvpHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    pvpHeroVigBot:SetHeight(60)
    pvpHeroVigBot:SetPoint("BOTTOMLEFT", pvpHero, "BOTTOMLEFT", 0, 0)
    pvpHeroVigBot:SetPoint("BOTTOMRIGHT", pvpHero, "BOTTOMRIGHT", 0, 0)
    pvpHeroVigBot:SetTexture(W8)
    ApplyGradient(pvpHeroVigBot, "VERTICAL", 0, 0, 0, 0.6, 0, 0, 0, 0)

    -- ROW 1: Context bar
    local pvpCtxLeft = pvpHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpCtxLeft, BODY_FONT, 9, "OUTLINE")
    pvpCtxLeft:SetPoint("TOPLEFT", pvpHero, "TOPLEFT", CFG.PAD + 2, -8)
    pvpCtxLeft:SetTextColor(TC("mutedText"))
    pvpCtxLeft:SetText("PVP")

    local pvpCtxRight = pvpHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpCtxRight, BODY_FONT, 9, "OUTLINE")
    pvpCtxRight:SetPoint("TOPRIGHT", pvpHero, "TOPRIGHT", -CFG.PAD, -8)
    pvpCtxRight:SetTextColor(TC("mutedText"))
    pvpCtxRight:SetText("")
    R.pvpSeasonValue = pvpCtxRight

    -- ROW 2: Centered player name + class icon
    local pvpClassIcon = pvpHero:CreateTexture(nil, "OVERLAY")
    pvpClassIcon:SetSize(22, 22)
    pvpClassIcon:SetPoint("TOP", pvpHero, "TOP", -46, -34)
    pvpClassIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes")
    R.pvpHeroClassIcon = pvpClassIcon

    local pvpPlayerName = pvpHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpPlayerName, TITLE_FONT, 14, "OUTLINE")
    pvpPlayerName:SetPoint("LEFT", pvpClassIcon, "RIGHT", 6, 0)
    pvpPlayerName:SetTextColor(TC("bodyText"))
    R.pvpHeroPlayerName = pvpPlayerName

    -- ROW 3: Spec + iLvl
    local pvpSpecLine = pvpHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpSpecLine, BODY_FONT, 10, "")
    pvpSpecLine:SetPoint("TOP", pvpClassIcon, "BOTTOM", 20, -2)
    pvpSpecLine:SetTextColor(TC("mutedText"))
    R.pvpHeroSpecLine = pvpSpecLine

    -- ROW 4: Pill bar (3 role toggles + 2 stat pills)
    local PILL_H = 28
    local PILL_GAP = 8
    local ROLE_PILL_W = 80
    local STAT_PILL_W = 140
    local totalPillW = 3 * ROLE_PILL_W + 2 * STAT_PILL_W + 4 * PILL_GAP
    local pillStartX = math.floor((CFG.WIDTH - totalPillW) / 2)
    local pillY = -82

    -- Helper: stat pill
    local function CreatePVPStatPill(xOfs, acColor)
        local pill = CreateFrame("Frame", nil, pvpHero, "BackdropTemplate")
        pill:SetSize(STAT_PILL_W, PILL_H)
        pill:SetPoint("TOPLEFT", pvpHero, "TOPLEFT", xOfs, pillY)
        pill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        pill:SetBackdropColor(TC("surfaceBg"))
        pill:SetBackdropBorderColor(0, 0, 0, 0)
        local dot = pill:CreateTexture(nil, "OVERLAY", nil, 2)
        dot:SetSize(4, PILL_H - 8)
        dot:SetPoint("LEFT", pill, "LEFT", 4, 0)
        dot:SetTexture(W8)
        if dot.SetGradient and CreateColor then
            dot:SetGradient("VERTICAL",
                CreateColor(acColor[1], acColor[2], acColor[3], 0.3),
                CreateColor(acColor[1], acColor[2], acColor[3], 1.0))
        else
            dot:SetColorTexture(acColor[1], acColor[2], acColor[3])
        end
        local lbl = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 9, "OUTLINE")
        lbl:SetPoint("LEFT", dot, "RIGHT", 6, 0)
        lbl:SetTextColor(TC("mutedText"))
        pill._label = lbl
        local val = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(val, TITLE_FONT, 11, "OUTLINE")
        val:SetPoint("RIGHT", pill, "RIGHT", -8, 0)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(TC("bodyText"))
        pill._value = val
        local frost = pill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", pill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", pill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end
        return pill
    end

    -- Role toggle pills
    local pvpRoleDefs = {
        { key = "tank",   atlas = "UI-LFG-RoleIcon-Tank",   label = "Tank" },
        { key = "healer", atlas = "UI-LFG-RoleIcon-Healer", label = "Healer" },
        { key = "dps",    atlas = "UI-LFG-RoleIcon-DPS",    label = "DPS" },
    }
    R.pvpRoleCards = {}

    for ri, rd in ipairs(pvpRoleDefs) do
        local rpill = CreateFrame("Button", nil, pvpHero, "BackdropTemplate")
        rpill:SetSize(ROLE_PILL_W, PILL_H)
        rpill:SetPoint("TOPLEFT", pvpHero, "TOPLEFT", pillStartX + (ri - 1) * (ROLE_PILL_W + PILL_GAP), pillY)
        rpill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        rpill:SetBackdropColor(TC("surfaceBg"))
        rpill:SetBackdropBorderColor(0, 0, 0, 0)
        local selGlow = rpill:CreateTexture(nil, "BACKGROUND", nil, 1)
        selGlow:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        selGlow:SetPoint("BOTTOMRIGHT", rpill, "BOTTOMRIGHT", -1, 1)
        selGlow:SetColorTexture(0, 0, 0, 0)
        rpill._selGlow = selGlow
        local ricon = rpill:CreateTexture(nil, "ARTWORK")
        ricon:SetSize(16, 16)
        ricon:SetPoint("LEFT", rpill, "LEFT", 8, 0)
        pcall(ricon.SetAtlas, ricon, rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rpill._icon = ricon
        local rlbl = rpill:CreateFontString(nil, "OVERLAY")
        TrySetFont(rlbl, BODY_FONT, 10, "OUTLINE")
        rlbl:SetPoint("LEFT", ricon, "RIGHT", 5, 0)
        rlbl:SetTextColor(TC("mutedText"))
        rlbl:SetText(rd.label)
        rpill._label = rlbl
        rpill._roleKey = rd.key
        local frost = rpill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", rpill, "TOPRIGHT", -1, -1)
        frost:SetColorTexture(1, 1, 1, 0.08)
        rpill:SetScript("OnClick", function(self)
            Panel._state.pvpRoles[self._roleKey] = not Panel._state.pvpRoles[self._roleKey]
            Panel.UpdatePVPRoleCards()
        end)
        rpill:SetScript("OnEnter", function(self)
            if not Panel._state.pvpRoles[self._roleKey] then self._icon:SetAlpha(0.7) end
        end)
        rpill:SetScript("OnLeave", function(self)
            if not Panel._state.pvpRoles[self._roleKey] then self._icon:SetAlpha(0.4) end
        end)
        R.pvpRoleCards[ri] = rpill
    end
    R.pvpRoleBtns = R.pvpRoleCards

    -- Stat pills: HONOR LEVEL + HIGHEST RATED
    local honorPill = CreatePVPStatPill(pillStartX + 3 * (ROLE_PILL_W + PILL_GAP), { 1.0, 0.85, 0.0 })
    honorPill._label:SetText("HONOR LVL")
    honorPill._value:SetText("0")
    R.pvpHonorValue = honorPill._value

    local ratingPill = CreatePVPStatPill(pillStartX + 3 * (ROLE_PILL_W + PILL_GAP) + STAT_PILL_W + PILL_GAP, { 1.0, 0.60, 0.0 })
    ratingPill._label:SetText("HIGHEST")
    ratingPill._value:SetText("--")
    R.pvpRatingValue = ratingPill._value

    -- Conquest progress bar (bottom, 3px)
    local pvpConqTrack = pvpHero:CreateTexture(nil, "ARTWORK", nil, 1)
    pvpConqTrack:SetHeight(3)
    pvpConqTrack:SetPoint("BOTTOMLEFT", pvpHero, "BOTTOMLEFT", CFG.PAD, 5)
    pvpConqTrack:SetPoint("BOTTOMRIGHT", pvpHero, "BOTTOMRIGHT", -CFG.PAD, 5)
    pvpConqTrack:SetColorTexture(1, 1, 1, 0.06)
    R.pvpConqTrack = pvpConqTrack

    local pvpConqFill = pvpHero:CreateTexture(nil, "ARTWORK", nil, 2)
    pvpConqFill:SetHeight(3)
    pvpConqFill:SetPoint("LEFT", pvpConqTrack, "LEFT", 0, 0)
    pvpConqFill:SetWidth(1)
    pvpConqFill:SetColorTexture(1.0, 0.60, 0.00, 0.9)
    R.pvpConqFill = pvpConqFill

    -- Glass divider
    local pvpGlassDiv = pvpHero:CreateTexture(nil, "OVERLAY", nil, 3)
    pvpGlassDiv:SetHeight(1)
    pvpGlassDiv:SetPoint("BOTTOMLEFT", pvpHero, "BOTTOMLEFT", 0, 0)
    pvpGlassDiv:SetPoint("BOTTOMRIGHT", pvpHero, "BOTTOMRIGHT", 0, 0)
    pvpGlassDiv:SetColorTexture(1, 1, 1, 0.08)

    -- ---- PVP Body (below hero) ----
    local pvpBody = CreateFrame("Frame", nil, pvpContent)
    pvpBody:SetPoint("TOPLEFT", pvpHero, "BOTTOMLEFT", 0, 0)
    pvpBody:SetPoint("BOTTOMRIGHT", pvpContent, "BOTTOMRIGHT", 0, 0)

    -- ---- PVP Category Sidebar (left, 160px) ----
    local pvpCatSidebar = CreateGlassPanel(pvpBody, CFG.CAT_SIDEBAR_W or 160)
    pvpCatSidebar:SetPoint("TOPLEFT", pvpBody, "TOPLEFT", 0, 0)
    pvpCatSidebar:SetPoint("BOTTOMLEFT", pvpBody, "BOTTOMLEFT", 0, 0)
    R.pvpCatSidebar = pvpCatSidebar

    R.pvpCatButtons = {}
    for i, def in ipairs(PVP_CATEGORY_DEFS) do
        local btn = CreateFrame("Button", nil, pvpCatSidebar)
        btn:SetHeight(36)
        btn:SetPoint("TOPLEFT", pvpCatSidebar, "TOPLEFT", 0, -((i - 1) * 36))
        btn:SetPoint("TOPRIGHT", pvpCatSidebar, "TOPRIGHT", 0, -((i - 1) * 36))

        local btnBg = btn:CreateTexture(nil, "BACKGROUND")
        btnBg:SetAllPoints()
        btnBg:SetColorTexture(TC("glassBg"))
        btn._bg = btnBg

        local accent = btn:CreateTexture(nil, "OVERLAY", nil, 2)
        accent:SetWidth(3)
        accent:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0)
        accent:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 0, 0)
        local ac = PVP_CAT_ACCENTS[def.key] or {0.5, 0.5, 0.5}
        accent:SetColorTexture(ac[1], ac[2], ac[3])
        accent:Hide()
        btn._accent = accent

        local lbl = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 10, "")
        lbl:SetPoint("LEFT", btn, "LEFT", 12, 0)
        lbl:SetTextColor(TC("bodyText"))
        lbl:SetText(def.label)
        btn._label = lbl
        btn._key = def.key

        btn:SetScript("OnClick", function()
            Panel._state.pvpCategory = def.key
            Panel._state.pvpSelectedActivity = nil
            Panel.UpdatePVPCatButtons()
            Panel.UpdatePVPActivities()
        end)
        btn:SetScript("OnEnter", function()
            if Panel._state.pvpCategory ~= def.key then
                btnBg:SetColorTexture(0.1, 0.1, 0.15, 0.6)
            end
        end)
        btn:SetScript("OnLeave", function()
            if Panel._state.pvpCategory ~= def.key then
                btnBg:SetColorTexture(TC("glassBg"))
            end
        end)

        R.pvpCatButtons[i] = btn
    end

    -- ---- PVP Bottom Bar (50px, role selector + queue button) ----
    local pvpBottomBar = CreateFrame("Frame", nil, pvpBody)
    pvpBottomBar:SetHeight(50)
    pvpBottomBar:SetPoint("BOTTOMLEFT", pvpBody, "BOTTOMLEFT", (CFG.CAT_SIDEBAR_W or 160), 0)
    pvpBottomBar:SetPoint("BOTTOMRIGHT", pvpBody, "BOTTOMRIGHT", 0, 0)
    local pvpBbBg = pvpBottomBar:CreateTexture(nil, "BACKGROUND")
    pvpBbBg:SetAllPoints()
    pvpBbBg:SetColorTexture(0, 0, 0, 0.30)
    local pvpBbDiv = pvpBottomBar:CreateTexture(nil, "OVERLAY")
    pvpBbDiv:SetHeight(1)
    pvpBbDiv:SetPoint("TOPLEFT", pvpBottomBar, "TOPLEFT", 0, 0)
    pvpBbDiv:SetPoint("TOPRIGHT", pvpBottomBar, "TOPRIGHT", 0, 0)
    pvpBbDiv:SetColorTexture(TC("divider"))
    R.pvpBottomBar = pvpBottomBar

    -- Role buttons (Tank / Healer / DPS)
    local pvpRoleDefs = {
        { key = "tank",   atlas = "UI-LFG-RoleIcon-Tank" },
        { key = "healer", atlas = "UI-LFG-RoleIcon-Healer" },
        { key = "dps",    atlas = "UI-LFG-RoleIcon-DPS" },
    }
    R.pvpRoleBtns = {}
    for ri, rd in ipairs(pvpRoleDefs) do
        local rbtn = CreateFrame("Button", nil, pvpBottomBar)
        rbtn:SetSize(32, 32)
        rbtn:SetPoint("LEFT", pvpBottomBar, "LEFT", 12 + (ri - 1) * 38, 0)
        local ricon = rbtn:CreateTexture(nil, "ARTWORK")
        ricon:SetAllPoints()
        pcall(ricon.SetAtlas, ricon, rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rbtn._icon = ricon
        rbtn._key = rd.key
        rbtn:SetScript("OnClick", function(self)
            local roles = Panel._state.pvpRoles
            roles[self._key] = not roles[self._key]
            self._icon:SetDesaturated(not roles[self._key])
            self._icon:SetAlpha(roles[self._key] and 1.0 or 0.4)
        end)
        R.pvpRoleBtns[ri] = rbtn
    end

    -- Queue button
    -- SecureActionButton: allows calling protected C_PvP.JoinBattlefield via hardware click
    local pvpQueueBtn = CreateFrame("Button", "MidnightUI_PVPQueueBtn", pvpBottomBar, "SecureActionButtonTemplate, BackdropTemplate")
    pvpQueueBtn:SetSize(140, 32)
    pvpQueueBtn:SetPoint("RIGHT", pvpBottomBar, "RIGHT", -12, 0)
    pvpQueueBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    local qR, qG, qB = TC("accent")
    pvpQueueBtn:SetBackdropColor(qR, qG, qB, 0.15)
    pvpQueueBtn:SetBackdropBorderColor(qR, qG, qB, 0.8)
    pvpQueueBtn:RegisterForClicks("AnyUp")
    pvpQueueBtn:SetAttribute("type", "macro")
    pvpQueueBtn:SetAttribute("macrotext", "")
    local pvpQueueLabel = pvpQueueBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpQueueLabel, TITLE_FONT, 11, "OUTLINE")
    pvpQueueLabel:SetPoint("CENTER")
    pvpQueueLabel:SetTextColor(TC("accent"))
    pvpQueueLabel:SetText("Join Battle")
    pvpQueueBtn._label = pvpQueueLabel

    -- PreClick: build the macro text based on selected activity BEFORE the secure click executes
    pvpQueueBtn:SetScript("PreClick", function(self)
        local activity = Panel._state.pvpSelectedActivity
        if not activity then
            self:SetAttribute("macrotext", "")
            return
        end

        local macro = ""
        if activity.queueType == "random_bg" then
            -- Get bgIndex from C_PvP.GetRandomBGInfo
            local okR, info = pcall(C_PvP.GetRandomBGInfo)
            if okR and type(info) == "table" and info.bgIndex then
                macro = "/run C_PvP.JoinBattlefield(" .. info.bgIndex .. ", " .. tostring(IsInGroup()) .. ")"
            end
        elseif activity.queueType == "random_epic" then
            local okR, info = pcall(C_PvP.GetRandomEpicBGInfo)
            if okR and type(info) == "table" and info.bgIndex then
                macro = "/run C_PvP.JoinBattlefield(" .. info.bgIndex .. ", " .. tostring(IsInGroup()) .. ")"
            end
        elseif activity.queueType == "specific" then
            -- Find bgIndex for this BG
            if C_PvP.GetBattlegroundInfo and GetNumBattlegroundTypes then
                local okN, numBGs = pcall(GetNumBattlegroundTypes)
                if okN and numBGs then
                    for i = 1, numBGs do
                        local okB, bgInfo = pcall(C_PvP.GetBattlegroundInfo, i)
                        if okB and type(bgInfo) == "table" and bgInfo.name then
                            if bgInfo.name:lower():find(activity.name:lower(), 1, true) or activity.name:lower():find(bgInfo.name:lower(), 1, true) then
                                macro = "/run C_PvP.JoinBattlefield(" .. (bgInfo.bgIndex or i) .. ", " .. tostring(IsInGroup()) .. ")"
                                break
                            end
                        end
                    end
                end
            end
        elseif activity.queueType == "skirmish" then
            macro = "/run JoinSingleLFG(" .. (LE_LFG_CATEGORY_WORLDPVP or 4) .. ", 0)"
        elseif activity.queueType == "brawl" then
            macro = "/run C_PvP.JoinBrawl()"
        end


        self:SetAttribute("macrotext", macro)
    end)

    -- PostClick: debug + queue status update
    pvpQueueBtn:SetScript("PostClick", function(self)
        local activity = Panel._state.pvpSelectedActivity
        if not activity then
            Panel.ShowToast("No Activity Selected", "Select a PVP activity to queue for.", 4)
            return
        end
        pcall(SetLFGRoles, false, Panel._state.pvpRoles.tank, Panel._state.pvpRoles.healer, Panel._state.pvpRoles.dps)
        if activity.bracket then
            Panel.ShowToast("Rated PVP", "Rated queueing is protected by Blizzard\nand cannot be done from addon UI.\n\nUse /pvp to open the Blizzard PVP panel.", 6)
        end
        C_Timer.After(0.5, function() Panel.UpdatePVPQueueStatus() end)
    end)
    pvpQueueBtn:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(qR, qG, qB, 1.0) end)
    pvpQueueBtn:SetScript("OnLeave", function(self) self:SetBackdropBorderColor(qR, qG, qB, 0.8) end)
    R.pvpQueueBtn = pvpQueueBtn

    -- ---- PVP Queue Status Bar (30px, above bottom bar, hidden by default) ----
    local pvpQueueBar = CreateFrame("Frame", nil, pvpBody)
    pvpQueueBar:SetHeight(30)
    pvpQueueBar:SetPoint("BOTTOMLEFT", pvpBottomBar, "TOPLEFT", 0, 0)
    pvpQueueBar:SetPoint("BOTTOMRIGHT", pvpBottomBar, "TOPRIGHT", 0, 0)
    local pvpQbBg = pvpQueueBar:CreateTexture(nil, "BACKGROUND")
    pvpQbBg:SetAllPoints()
    pvpQbBg:SetColorTexture(0.05, 0.15, 0.05, 0.8)
    local pvpQueueText = pvpQueueBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpQueueText, BODY_FONT, 10, "OUTLINE")
    pvpQueueText:SetPoint("LEFT", pvpQueueBar, "LEFT", 12, 0)
    pvpQueueText:SetTextColor(0.4, 1.0, 0.4)
    R.pvpQueueText = pvpQueueText

    local pvpQueueCancel = CreateFrame("Button", nil, pvpQueueBar, "BackdropTemplate")
    pvpQueueCancel:SetSize(60, 22)
    pvpQueueCancel:SetPoint("RIGHT", pvpQueueBar, "RIGHT", -8, 0)
    pvpQueueCancel:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    pvpQueueCancel:SetBackdropColor(0.4, 0.1, 0.1, 0.5)
    pvpQueueCancel:SetBackdropBorderColor(1, 0.3, 0.3, 0.6)
    local pvpCancelLabel = pvpQueueCancel:CreateFontString(nil, "OVERLAY")
    TrySetFont(pvpCancelLabel, BODY_FONT, 9, "OUTLINE")
    pvpCancelLabel:SetPoint("CENTER")
    pvpCancelLabel:SetTextColor(1, 0.4, 0.4)
    pvpCancelLabel:SetText("Cancel")
    pvpQueueCancel:SetScript("OnClick", function()
        for i = 1, 3 do
            local status = GetBattlefieldStatus and GetBattlefieldStatus(i)
            if status == "queued" or status == "confirm" then
                pcall(AcceptBattlefieldPort, i, false)
            end
        end
        C_Timer.After(0.3, function() Panel.UpdatePVPQueueStatus() end)
    end)

    pvpQueueBar:Hide()
    R.pvpQueueBar = pvpQueueBar

    -- ---- PVP Activity List Area (scrollable, between sidebar and bottom bar) ----
    local pvpListArea = CreateFrame("Frame", nil, pvpBody)
    pvpListArea:SetPoint("TOPLEFT", pvpCatSidebar, "TOPRIGHT", 0, 0)
    pvpListArea:SetPoint("BOTTOMRIGHT", pvpBottomBar, "TOPRIGHT", 0, 0)
    R.pvpListArea = pvpListArea

    -- Scroll frame for activity cards
    local pvpScroll = CreateFrame("ScrollFrame", nil, pvpListArea, "UIPanelScrollFrameTemplate")
    pvpScroll:SetPoint("TOPLEFT", pvpListArea, "TOPLEFT", 8, -8)
    pvpScroll:SetPoint("BOTTOMRIGHT", pvpListArea, "BOTTOMRIGHT", -24, 8)
    local pvpScrollChild = CreateFrame("Frame", nil, pvpScroll)
    pvpScrollChild:SetWidth(pvpScroll:GetWidth() or 600)
    pvpScrollChild:SetHeight(1)
    pvpScroll:SetScrollChild(pvpScrollChild)
    R.pvpScrollChild = pvpScrollChild
    R.pvpActivityCards = {}

    end -- end PVP scope

    -- ==================================================================
    -- Premade Groups overlay (full three-zone layout)
    -- ==================================================================
    do -- scope block
    local premadeContent = CreateFrame("Frame", nil, content)
    premadeContent:SetAllPoints()
    premadeContent:Hide()
    R.premadeContent = premadeContent

    -- ---- Premade Hero Banner (130px, centered player showcase) ----
    -- Atlas artwork + centered player identity: icon, name, spec, score, keystone.
    local premadeHero = CreateFrame("Frame", nil, premadeContent)
    premadeHero:SetHeight(190)
    premadeHero:SetPoint("TOPLEFT", premadeContent, "TOPLEFT", 0, 0)
    premadeHero:SetPoint("TOPRIGHT", premadeContent, "TOPRIGHT", 0, 0)
    R.premadeHero = premadeHero

    -- Layer -8: Dark base
    local phBase = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -8)
    phBase:SetAllPoints()
    phBase:SetColorTexture(0.02, 0.02, 0.03, 1)

    -- Layer -7: Atlas artwork (lower alpha for readability of centered text)
    local phAtlas = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -7)
    phAtlas:SetAllPoints()
    if not TrySetAtlasFromList(phAtlas, HERO_ATLASES.premade) then
        phAtlas:SetColorTexture(0, 0, 0, 0)
    end
    phAtlas:SetAlpha(0.40)

    -- Layer -5: Top vignette
    local phVigTop = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    phVigTop:SetHeight(80)
    phVigTop:SetPoint("TOPLEFT", premadeHero, "TOPLEFT", 0, 0)
    phVigTop:SetPoint("TOPRIGHT", premadeHero, "TOPRIGHT", 0, 0)
    phVigTop:SetTexture(W8)
    ApplyGradient(phVigTop, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.5)

    -- Layer -5: Bottom vignette
    local phVigBot = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    phVigBot:SetHeight(60)
    phVigBot:SetPoint("BOTTOMLEFT", premadeHero, "BOTTOMLEFT", 0, 0)
    phVigBot:SetPoint("BOTTOMRIGHT", premadeHero, "BOTTOMRIGHT", 0, 0)
    phVigBot:SetTexture(W8)
    ApplyGradient(phVigBot, "VERTICAL", 0, 0, 0, 0.6, 0, 0, 0, 0)

    -- Layer -5: Left reading vignette
    local phVigLeft = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -5)
    phVigLeft:SetWidth(math.floor(CFG.WIDTH * 0.40))
    phVigLeft:SetPoint("TOPLEFT", premadeHero, "TOPLEFT", 0, 0)
    phVigLeft:SetPoint("BOTTOMLEFT", premadeHero, "BOTTOMLEFT", 0, 0)
    phVigLeft:SetTexture(W8)
    ApplyGradient(phVigLeft, "HORIZONTAL", 0, 0, 0, 0.25, 0, 0, 0, 0)

    -- Layer -4: Accent wash at bottom
    local phAcWash = premadeHero:CreateTexture(nil, "BACKGROUND", nil, -4)
    phAcWash:SetHeight(60)
    phAcWash:SetPoint("BOTTOMLEFT", premadeHero, "BOTTOMLEFT", 0, 0)
    phAcWash:SetPoint("BOTTOMRIGHT", premadeHero, "BOTTOMRIGHT", 0, 0)
    phAcWash:SetTexture(W8)
    local phAcR, phAcG, phAcB = TC("accent")
    ApplyGradient(phAcWash, "VERTICAL", phAcR, phAcG, phAcB, 0.03, phAcR, phAcG, phAcB, 0)

    -- Row 1: Category label (left) + Group count (right) — context bar
    local phCategoryLabel = premadeHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(phCategoryLabel, BODY_FONT, 9, "OUTLINE")
    phCategoryLabel:SetPoint("TOPLEFT", premadeHero, "TOPLEFT", CFG.PAD + 2, -8)
    phCategoryLabel:SetTextColor(TC("mutedText"))
    phCategoryLabel:SetText("")
    R.premadeHeroTitle = phCategoryLabel

    local phGroupCount = premadeHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(phGroupCount, BODY_FONT, 9, "OUTLINE")
    phGroupCount:SetPoint("TOPRIGHT", premadeHero, "TOPRIGHT", -CFG.PAD, -8)
    phGroupCount:SetTextColor(TC("mutedText"))
    phGroupCount:SetText("")
    R.premadeHeroGroupCount = phGroupCount

    -- Row 2: Player identity — class icon + name (centered)
    local phClassIcon = premadeHero:CreateTexture(nil, "ARTWORK")
    phClassIcon:SetSize(22, 22)
    phClassIcon:SetPoint("TOP", premadeHero, "TOP", -46, -34)
    R.premadeHeroClassIcon = phClassIcon

    local phPlayerName = premadeHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(phPlayerName, TITLE_FONT, 14, "OUTLINE")
    phPlayerName:SetPoint("LEFT", phClassIcon, "RIGHT", 6, 0)
    phPlayerName:SetTextColor(TC("bodyText"))
    phPlayerName:SetText("")
    R.premadeHeroPlayerName = phPlayerName

    -- Row 3: Spec + iLvl (centered below name)
    local phSpecLine = premadeHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(phSpecLine, BODY_FONT, 10, "")
    phSpecLine:SetPoint("TOP", phClassIcon, "BOTTOM", 20, -2)
    phSpecLine:SetTextColor(TC("mutedText"))
    phSpecLine:SetText("")
    R.premadeHeroSpecLine = phSpecLine

    -- Row 4: Pill bar — 3 role toggles + M+ Rating + Key + MPI
    local PILL_H = 28
    local PILL_GAP = 8
    local ROLE_PILL_W = 80
    local STAT_PILL_W = 120
    local totalPillW = 3 * ROLE_PILL_W + 3 * STAT_PILL_W + 5 * PILL_GAP
    local pillStartX = math.floor((CFG.WIDTH - totalPillW) / 2)
    local pillY = -82

    -- Helper: stat pill (modernized)
    local function CreatePremadeStatPill(xOfs)
        local pill = CreateFrame("Frame", nil, premadeHero, "BackdropTemplate")
        pill:SetSize(STAT_PILL_W, PILL_H)
        pill:SetPoint("TOPLEFT", premadeHero, "TOPLEFT", xOfs, pillY)
        pill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        pill:SetBackdropColor(TC("surfaceBg"))
        pill:SetBackdropBorderColor(0, 0, 0, 0)
        local acR, acG, acB = TC("accent")
        local dot = pill:CreateTexture(nil, "OVERLAY", nil, 2)
        dot:SetSize(4, PILL_H - 8)
        dot:SetPoint("LEFT", pill, "LEFT", 4, 0)
        dot:SetTexture(W8)
        if dot.SetGradient and CreateColor then
            dot:SetGradient("VERTICAL",
                CreateColor(acR, acG, acB, 0.3),
                CreateColor(acR, acG, acB, 1.0))
        else
            dot:SetColorTexture(acR, acG, acB)
        end
        pill._dot = dot
        local lbl = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 9, "OUTLINE")
        lbl:SetPoint("LEFT", dot, "RIGHT", 6, 0)
        lbl:SetTextColor(TC("mutedText"))
        pill._label = lbl
        local val = pill:CreateFontString(nil, "OVERLAY")
        TrySetFont(val, TITLE_FONT, 11, "OUTLINE")
        val:SetPoint("RIGHT", pill, "RIGHT", -8, 0)
        val:SetJustifyH("RIGHT")
        val:SetTextColor(TC("bodyText"))
        pill._value = val
        local frost = pill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", pill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", pill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end
        local botLine = pill:CreateTexture(nil, "BACKGROUND", nil, 2)
        botLine:SetHeight(1)
        botLine:SetPoint("BOTTOMLEFT", pill, "BOTTOMLEFT", 1, 1)
        botLine:SetPoint("BOTTOMRIGHT", pill, "BOTTOMRIGHT", -1, 1)
        botLine:SetColorTexture(0, 0, 0, 0.08)
        return pill
    end

    -- Role toggle pills (same pattern as other heroes)
    local premadeRoleDefs = {
        { key = "tank",   atlas = "UI-LFG-RoleIcon-Tank",   label = "Tank" },
        { key = "healer", atlas = "UI-LFG-RoleIcon-Healer", label = "Healer" },
        { key = "dps",    atlas = "UI-LFG-RoleIcon-DPS",    label = "DPS" },
    }
    R.premadeRoleCards = {}

    for ri, rd in ipairs(premadeRoleDefs) do
        local rpill = CreateFrame("Button", nil, premadeHero, "BackdropTemplate")
        rpill:SetSize(ROLE_PILL_W, PILL_H)
        rpill:SetPoint("TOPLEFT", premadeHero, "TOPLEFT", pillStartX + (ri - 1) * (ROLE_PILL_W + PILL_GAP), pillY)
        rpill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        rpill:SetBackdropColor(TC("surfaceBg"))
        rpill:SetBackdropBorderColor(0, 0, 0, 0)
        local selGlow = rpill:CreateTexture(nil, "BACKGROUND", nil, 1)
        selGlow:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        selGlow:SetPoint("BOTTOMRIGHT", rpill, "BOTTOMRIGHT", -1, 1)
        selGlow:SetColorTexture(0, 0, 0, 0)
        rpill._selGlow = selGlow
        local ricon = rpill:CreateTexture(nil, "ARTWORK")
        ricon:SetSize(16, 16)
        ricon:SetPoint("LEFT", rpill, "LEFT", 8, 0)
        pcall(ricon.SetAtlas, ricon, rd.atlas)
        ricon:SetDesaturated(true)
        ricon:SetAlpha(0.4)
        rpill._icon = ricon
        local rlbl = rpill:CreateFontString(nil, "OVERLAY")
        TrySetFont(rlbl, BODY_FONT, 10, "OUTLINE")
        rlbl:SetPoint("LEFT", ricon, "RIGHT", 5, 0)
        rlbl:SetTextColor(TC("mutedText"))
        rlbl:SetText(rd.label)
        rpill._label = rlbl
        rpill._roleKey = rd.key
        local frost = rpill:CreateTexture(nil, "OVERLAY", nil, 3)
        frost:SetHeight(1)
        frost:SetPoint("TOPLEFT", rpill, "TOPLEFT", 1, -1)
        frost:SetPoint("TOPRIGHT", rpill, "TOPRIGHT", -1, -1)
        frost:SetTexture(W8)
        if frost.SetGradient and CreateColor then
            frost:SetGradient("HORIZONTAL",
                CreateColor(1, 1, 1, 0.01),
                CreateColor(1, 1, 1, 0.04))
        else
            frost:SetColorTexture(1, 1, 1, 0.04)
        end
        rpill:SetScript("OnClick", function(self)
            -- Single-select for premade (radio button style)
            local st = Panel._state.applyRole
            local wasSelected = st[self._roleKey]
            st.tank = false; st.healer = false; st.dps = false
            st[self._roleKey] = not wasSelected
            if not st.tank and not st.healer and not st.dps then st.dps = true end
            Panel.UpdatePremadeRoleCards()
        end)
        rpill:SetScript("OnEnter", function(self)
            if not Panel._state.applyRole[self._roleKey] then self._icon:SetAlpha(0.7) end
        end)
        rpill:SetScript("OnLeave", function(self)
            if not Panel._state.applyRole[self._roleKey] then self._icon:SetAlpha(0.4) end
        end)
        R.premadeRoleCards[ri] = rpill
    end
    R.applyRoleBtns = R.premadeRoleCards

    -- M+ Rating pill
    local statStartX = pillStartX + 3 * (ROLE_PILL_W + PILL_GAP)
    local ratingPill = CreatePremadeStatPill(statStartX)
    ratingPill._label:SetText("M+ RATING")
    ratingPill._value:SetText("--")
    R.premadeHeroScorePill = ratingPill
    R.premadeHeroScoreBadge = ratingPill
    R.premadeHeroScoreText = ratingPill._value

    -- Keystone pill
    local keystonePill = CreatePremadeStatPill(statStartX + STAT_PILL_W + PILL_GAP)
    keystonePill._label:SetText("KEY")
    keystonePill._value:SetText("None")
    R.premadeHeroKeystonePill = keystonePill
    R.premadeHeroKeystoneText = keystonePill._value

    -- MPI pill
    local mpiPill = CreatePremadeStatPill(statStartX + 2 * (STAT_PILL_W + PILL_GAP))
    mpiPill._label:SetText("MPI")
    mpiPill._value:SetText("N/A")
    R.premadeHeroMPIPill = mpiPill
    R.premadeHeroRolePill = nil  -- removed old role pill

    -- Row 5: Suggestion text (bottom, subtle, only when actionable)
    local phSuggestion = premadeHero:CreateFontString(nil, "OVERLAY")
    TrySetFont(phSuggestion, BODY_FONT, 9, "")
    phSuggestion:SetPoint("BOTTOMLEFT", premadeHero, "BOTTOMLEFT", CFG.PAD + 2, 6)
    phSuggestion:SetPoint("BOTTOMRIGHT", premadeHero, "BOTTOMRIGHT", -CFG.PAD, 6)
    phSuggestion:SetJustifyH("CENTER")
    phSuggestion:SetTextColor(TC("mutedText"))
    phSuggestion:SetText("")
    R.premadeHeroSuggestion = phSuggestion

    -- F3: List Your Key button (accent-filled)
    local listKeyBtn = CreateFrame("Button", nil, premadeHero, "BackdropTemplate")
    listKeyBtn:SetSize(120, 26)
    listKeyBtn:SetPoint("BOTTOMRIGHT", premadeHero, "BOTTOMRIGHT", -CFG.PAD, 6)
    listKeyBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    local lkR, lkG, lkB = TC("accent")
    listKeyBtn:SetBackdropColor(lkR, lkG, lkB, 0.12)
    listKeyBtn:SetBackdropBorderColor(lkR, lkG, lkB, 0.25)
    local listKeyLabel = listKeyBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(listKeyLabel, BODY_FONT, 10, "OUTLINE")
    listKeyLabel:SetPoint("CENTER")
    listKeyLabel:SetTextColor(TC("accent"))
    listKeyLabel:SetText("List Your Key")
    listKeyBtn._label = listKeyLabel
    listKeyBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(lkR, lkG, lkB, 0.22)
        self:SetBackdropBorderColor(lkR, lkG, lkB, 0.40)
    end)
    listKeyBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(lkR, lkG, lkB, 0.12)
        self:SetBackdropBorderColor(lkR, lkG, lkB, 0.25)
    end)
    listKeyBtn:SetScript("OnClick", function() Panel.ListMyKey() end)
    R.listKeyBtn = listKeyBtn

    -- Bottom divider (gradient fade from center outward)
    local phGlassDivL = premadeHero:CreateTexture(nil, "OVERLAY", nil, 3)
    phGlassDivL:SetHeight(1)
    phGlassDivL:SetPoint("BOTTOMLEFT", premadeHero, "BOTTOMLEFT", 0, 0)
    phGlassDivL:SetPoint("BOTTOM", premadeHero, "BOTTOM", 0, 0)
    phGlassDivL:SetTexture(W8)
    ApplyGradient(phGlassDivL, "HORIZONTAL", 1, 1, 1, 0, 1, 1, 1, 0.06)

    local phGlassDivR = premadeHero:CreateTexture(nil, "OVERLAY", nil, 3)
    phGlassDivR:SetHeight(1)
    phGlassDivR:SetPoint("BOTTOM", premadeHero, "BOTTOM", 0, 0)
    phGlassDivR:SetPoint("BOTTOMRIGHT", premadeHero, "BOTTOMRIGHT", 0, 0)
    phGlassDivR:SetTexture(W8)
    ApplyGradient(phGlassDivR, "HORIZONTAL", 1, 1, 1, 0.06, 1, 1, 1, 0)

    -- ---- Premade Body (below hero, three-zone layout) ----
    local premadeBody = CreateFrame("Frame", nil, premadeContent)
    premadeBody:SetPoint("TOPLEFT", premadeHero, "BOTTOMLEFT", 0, 0)
    premadeBody:SetPoint("BOTTOMRIGHT", premadeContent, "BOTTOMRIGHT", 0, 0)
    R.premadeBody = premadeBody

    -- ---- Category Sidebar (left, 160px) ----
    local catSidebar = CreateGlassPanel(premadeBody, CFG.CAT_SIDEBAR_W)
    catSidebar:SetPoint("TOPLEFT", premadeBody, "TOPLEFT", 0, 0)
    catSidebar:SetPoint("BOTTOMLEFT", premadeBody, "BOTTOMLEFT", 0, 0)
    R.catSidebar = catSidebar

    R.catButtons = {}
    for i, def in ipairs(CATEGORY_DEFS) do
        local btn = CreateFrame("Button", nil, catSidebar)
        btn:SetSize(CFG.CAT_SIDEBAR_W, 36)
        btn:SetPoint("TOPLEFT", catSidebar, "TOPLEFT", 0, -((i - 1) * 36))

        -- Gradient background (subtle dimensionality)
        local btnBg = btn:CreateTexture(nil, "BACKGROUND")
        btnBg:SetAllPoints()
        btnBg:SetTexture(W8)
        local bgR, bgG, bgB, bgA = TC("glassBg")
        if btnBg.SetGradient and CreateColor then
            btnBg:SetGradient("VERTICAL",
                CreateColor(bgR, bgG, bgB, bgA),
                CreateColor(bgR + 0.01, bgG + 0.01, bgB + 0.01, bgA))
        else
            btnBg:SetColorTexture(TC("glassBg"))
        end
        btn._bg = btnBg

        -- Left accent bar (4px, gradient, only visible when selected)
        local acBar = btn:CreateTexture(nil, "OVERLAY", nil, 2)
        acBar:SetSize(4, 36)
        acBar:SetPoint("LEFT", btn, "LEFT", 0, 0)
        acBar:SetTexture(W8)
        local catAcColor = CATEGORY_ACCENTS[def.key] or {TC("accent")}
        if acBar.SetGradient and CreateColor then
            acBar:SetGradient("VERTICAL",
                CreateColor(catAcColor[1], catAcColor[2], catAcColor[3], 0.3),
                CreateColor(catAcColor[1], catAcColor[2], catAcColor[3], 1.0))
        else
            acBar:SetColorTexture(catAcColor[1], catAcColor[2], catAcColor[3])
        end
        acBar:Hide()
        btn._accentBar = acBar

        -- Separator line between categories (very subtle)
        if i > 1 then
            local sep = btn:CreateTexture(nil, "OVERLAY", nil, 1)
            sep:SetHeight(1)
            sep:SetPoint("TOPLEFT", btn, "TOPLEFT", 8, 0)
            sep:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -8, 0)
            local sepR, sepG, sepB = TC("divider")
            sep:SetColorTexture(sepR, sepG, sepB, 0.04)
        end

        -- Label
        local lbl = btn:CreateFontString(nil, "OVERLAY")
        TrySetFont(lbl, BODY_FONT, 11, "OUTLINE")
        lbl:SetPoint("LEFT", btn, "LEFT", 14, 0)
        lbl:SetTextColor(TC("bodyText"))
        lbl:SetText(def.label)
        btn._label = lbl
        btn._key = def.key

        btn:SetScript("OnClick", function()
            Panel._state.activeCategory = def.key
            Panel._state.searchResults = {}
            Panel._state.scrollOffset = 0
            Panel.UpdateCatButtons()
            Panel.UpdateFilterBarVisibility()
            Panel.UpdateListingRows()
            Panel.DoSearch()
        end)
        btn:SetScript("OnEnter", function()
            if Panel._state.activeCategory ~= def.key then
                local hAc = CATEGORY_ACCENTS[def.key] or {TC("accent")}
                btnBg:SetTexture(W8)
                btnBg:SetColorTexture(hAc[1], hAc[2], hAc[3], 0.06)
            end
        end)
        btn:SetScript("OnLeave", function()
            if Panel._state.activeCategory ~= def.key then
                btnBg:SetTexture(W8)
                if btnBg.SetGradient and CreateColor then
                    btnBg:SetGradient("VERTICAL",
                        CreateColor(bgR, bgG, bgB, bgA),
                        CreateColor(bgR + 0.01, bgG + 0.01, bgB + 0.01, bgA))
                else
                    btnBg:SetColorTexture(TC("glassBg"))
                end
            end
        end)

        R.catButtons[i] = btn
    end

    -- ---- Player Sidebar (right, 260px) ----
    local playerSidebar = CreateGlassPanel(premadeBody, CFG.PLAYER_SIDEBAR_W)
    playerSidebar:SetPoint("TOPRIGHT", premadeBody, "TOPRIGHT", 0, 0)
    playerSidebar:SetPoint("BOTTOMRIGHT", premadeBody, "BOTTOMRIGHT", 0, 0)
    R.playerSidebar = playerSidebar

    -- ---- Listing Area (between cat sidebar and player sidebar) ----
    local listingArea = CreateFrame("Frame", nil, premadeBody)
    listingArea:SetPoint("TOPLEFT", catSidebar, "TOPRIGHT", 0, 0)
    listingArea:SetPoint("BOTTOMRIGHT", playerSidebar, "BOTTOMLEFT", 0, 0)
    R.listingArea = listingArea

    -- ---- Filter Bar (top of listing area, 36px) ----
    local filterBar = CreateFrame("Frame", nil, listingArea)
    filterBar:SetHeight(CFG.FILTER_BAR_H)
    filterBar:SetPoint("TOPLEFT", listingArea, "TOPLEFT", 0, 0)
    filterBar:SetPoint("TOPRIGHT", listingArea, "TOPRIGHT", 0, 0)
    R.filterBar = filterBar

    local filterBg = filterBar:CreateTexture(nil, "BACKGROUND")
    filterBg:SetAllPoints()
    filterBg:SetColorTexture(0, 0, 0, 0.20)

    -- F6: Freeform search input (softer, accent underline)
    local searchInput = CreateFrame("EditBox", nil, filterBar, "BackdropTemplate")
    searchInput:SetSize(CFG.SEARCH_INPUT_W, 28)
    searchInput:SetPoint("LEFT", filterBar, "LEFT", CFG.PAD, 0)
    searchInput:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    searchInput:SetBackdropColor(TC("surfaceBg"))
    searchInput:SetBackdropBorderColor(0, 0, 0, 0)
    -- Accent underline
    local searchUnderline = searchInput:CreateTexture(nil, "OVERLAY", nil, 2)
    searchUnderline:SetHeight(1)
    searchUnderline:SetPoint("BOTTOMLEFT", searchInput, "BOTTOMLEFT", 1, 0)
    searchUnderline:SetPoint("BOTTOMRIGHT", searchInput, "BOTTOMRIGHT", -1, 0)
    local suR, suG, suB = TC("accent")
    searchUnderline:SetColorTexture(suR, suG, suB, 0.15)
    TrySetFont(searchInput, BODY_FONT, 10, "")
    searchInput:SetTextColor(TC("bodyText"))
    searchInput:SetAutoFocus(false)
    searchInput:SetMaxLetters(40)
    searchInput:SetTextInsets(6, 6, 0, 0)
    searchInput:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    searchInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local searchPlaceholder = searchInput:CreateFontString(nil, "OVERLAY")
    TrySetFont(searchPlaceholder, BODY_FONT, 10, "")
    searchPlaceholder:SetPoint("LEFT", searchInput, "LEFT", 6, 0)
    searchPlaceholder:SetTextColor(TC("mutedText"))
    searchPlaceholder:SetText("Search...")
    Panel._state.filters.searchText = ""
    local searchDebounceTimer = nil
    searchInput:SetScript("OnTextChanged", function(self)
        searchPlaceholder:SetShown(self:GetText() == "")
        Panel._state.filters.searchText = self:GetText()
        if searchDebounceTimer then searchDebounceTimer:Cancel() end
        searchDebounceTimer = C_Timer.NewTimer(0.3, function()
            Panel.OnSearchResults() -- re-filter cached results, no API call
        end)
    end)
    R.searchInput = searchInput

    -- a) Dungeon dropdown button (160x28, softer)
    local ddBtn = CreateFrame("Button", nil, filterBar, "BackdropTemplate")
    ddBtn:SetSize(160, 28)
    ddBtn:SetPoint("LEFT", searchInput, "RIGHT", 8, 0)
    ddBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    ddBtn:SetBackdropColor(TC("surfaceBg"))
    ddBtn:SetBackdropBorderColor(0, 0, 0, 0)
    local ddUnderline = ddBtn:CreateTexture(nil, "OVERLAY", nil, 2)
    ddUnderline:SetHeight(1)
    ddUnderline:SetPoint("BOTTOMLEFT", ddBtn, "BOTTOMLEFT", 1, 0)
    ddUnderline:SetPoint("BOTTOMRIGHT", ddBtn, "BOTTOMRIGHT", -1, 0)
    ddUnderline:SetColorTexture(suR, suG, suB, 0.12)
    local ddLabel = ddBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(ddLabel, BODY_FONT, 10, "OUTLINE")
    ddLabel:SetPoint("LEFT", ddBtn, "LEFT", 8, 0)
    ddLabel:SetTextColor(TC("bodyText"))
    ddLabel:SetText("All Dungeons")
    local ddArrow = ddBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(ddArrow, BODY_FONT, 10, "OUTLINE")
    ddArrow:SetPoint("RIGHT", ddBtn, "RIGHT", -6, 0)
    ddArrow:SetTextColor(TC("mutedText"))
    ddArrow:SetText("v")
    ddBtn._label = ddLabel
    R.ddBtn = ddBtn

    -- Dropdown list frame
    local ddList = CreateFrame("Frame", nil, ddBtn, "BackdropTemplate")
    ddList:SetWidth(160)
    ddList:SetPoint("TOPLEFT", ddBtn, "BOTTOMLEFT", 0, -2)
    ddList:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    ddList:SetBackdropColor(0.04, 0.04, 0.07, 0.97)
    ddList:SetBackdropBorderColor(TC("glassBorder"))
    -- Soft shadow below dropdown
    local ddShadow = ddList:CreateTexture(nil, "BACKGROUND", nil, -1)
    ddShadow:SetPoint("TOPLEFT", ddList, "BOTTOMLEFT", 2, 0)
    ddShadow:SetPoint("TOPRIGHT", ddList, "BOTTOMRIGHT", -2, 0)
    ddShadow:SetHeight(4)
    ddShadow:SetTexture(W8)
    ApplyGradient(ddShadow, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.15)
    ddList:SetFrameStrata("TOOLTIP")
    ddList:Hide()
    R.ddList = ddList

    -- Build dropdown items from dynamic dungeon list
    local dropdownNames = BuildDungeonDropdownList(Panel._dungeonData)
    local ddItems = {}
    for idx, dname in ipairs(dropdownNames) do
        local item = CreateFrame("Button", nil, ddList)
        item:SetSize(158, 22)
        item:SetPoint("TOPLEFT", ddList, "TOPLEFT", 1, -((idx - 1) * 22) - 1)
        local itemBg = item:CreateTexture(nil, "BACKGROUND")
        itemBg:SetAllPoints()
        itemBg:SetColorTexture(0, 0, 0, 0)
        local itemLbl = item:CreateFontString(nil, "OVERLAY")
        TrySetFont(itemLbl, BODY_FONT, 10, "")
        itemLbl:SetPoint("LEFT", item, "LEFT", 8, 0)
        itemLbl:SetTextColor(TC("bodyText"))
        itemLbl:SetText(dname)
        item:SetScript("OnEnter", function()
            local hiR, hiG, hiB = TC("accent")
            itemBg:SetColorTexture(hiR, hiG, hiB, 0.06)
        end)
        item:SetScript("OnLeave", function() itemBg:SetColorTexture(0, 0, 0, 0) end)
        item:SetScript("OnClick", function()
            Panel._state.filters.dungeon = (idx == 1) and nil or dname
            ddLabel:SetText(dname)
            ddList:Hide()
        end)
        ddItems[idx] = item
    end
    ddList:SetHeight(#dropdownNames * 22 + 2)

    -- Outside-click catch-all to dismiss dropdown
    local ddCatchAll = CreateFrame("Button", nil, UIParent)
    ddCatchAll:SetAllPoints()
    ddCatchAll:SetFrameStrata("TOOLTIP")
    ddCatchAll:Hide()
    ddCatchAll:SetScript("OnClick", function()
        ddList:Hide()
        ddCatchAll:Hide()
    end)
    ddList:SetScript("OnShow", function()
        ddCatchAll:SetFrameLevel(ddList:GetFrameLevel() - 1)
        ddCatchAll:Show()
    end)
    ddList:SetScript("OnHide", function() ddCatchAll:Hide() end)

    ddBtn:SetScript("OnClick", function()
        if ddList:IsShown() then ddList:Hide() else ddList:Show() end
    end)

    -- b) Key level range (min/max edit boxes)
    local function CreateKeyEditBox(parent, anchorFrame, anchorPoint, xOff)
        local eb = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
        eb:SetSize(40, 28)
        eb:SetPoint("LEFT", anchorFrame, anchorPoint, xOff, 0)
        eb:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        eb:SetBackdropColor(TC("surfaceBg"))
        eb:SetBackdropBorderColor(0, 0, 0, 0)
        TrySetFont(eb, BODY_FONT, 10, "")
        eb:SetTextColor(TC("bodyText"))
        eb:SetJustifyH("CENTER")
        eb:SetNumeric(true)
        eb:SetMaxLetters(2)
        eb:SetAutoFocus(false)
        eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        eb:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        -- Accent underline
        local ebLine = eb:CreateTexture(nil, "OVERLAY", nil, 2)
        ebLine:SetHeight(1)
        ebLine:SetPoint("BOTTOMLEFT", eb, "BOTTOMLEFT", 1, 0)
        ebLine:SetPoint("BOTTOMRIGHT", eb, "BOTTOMRIGHT", -1, 0)
        ebLine:SetColorTexture(suR, suG, suB, 0.12)
        return eb
    end

    local keyMinBox = CreateKeyEditBox(filterBar, ddBtn, "RIGHT", 12)
    R.keyMinBox = keyMinBox

    local dashStr = filterBar:CreateFontString(nil, "OVERLAY")
    TrySetFont(dashStr, BODY_FONT, 10, "OUTLINE")
    dashStr:SetPoint("LEFT", keyMinBox, "RIGHT", 4, 0)
    dashStr:SetTextColor(TC("mutedText"))
    dashStr:SetText("-")

    local keyMaxBox = CreateKeyEditBox(filterBar, dashStr, "RIGHT", 4)
    R.keyMaxBox = keyMaxBox

    -- Placeholder text for key boxes
    local minPlaceholder = keyMinBox:CreateFontString(nil, "OVERLAY")
    TrySetFont(minPlaceholder, BODY_FONT, 10, "")
    minPlaceholder:SetPoint("CENTER")
    minPlaceholder:SetTextColor(TC("mutedText"))
    minPlaceholder:SetText("Min")
    keyMinBox._placeholder = minPlaceholder
    keyMinBox:SetScript("OnTextChanged", function(self)
        minPlaceholder:SetShown(self:GetText() == "")
        Panel._state.filters.keyMin = tonumber(self:GetText())
    end)

    local maxPlaceholder = keyMaxBox:CreateFontString(nil, "OVERLAY")
    TrySetFont(maxPlaceholder, BODY_FONT, 10, "")
    maxPlaceholder:SetPoint("CENTER")
    maxPlaceholder:SetTextColor(TC("mutedText"))
    maxPlaceholder:SetText("Max")
    keyMaxBox._placeholder = maxPlaceholder
    keyMaxBox:SetScript("OnTextChanged", function(self)
        maxPlaceholder:SetShown(self:GetText() == "")
        Panel._state.filters.keyMax = tonumber(self:GetText())
    end)

    -- c) Role filter toggle buttons (3x 28x28)
    local ROLE_DEFS = {
        { role = "TANK",    atlas = "UI-LFG-RoleIcon-Tank" },
        { role = "HEALER",  atlas = "UI-LFG-RoleIcon-Healer" },
        { role = "DAMAGER", atlas = "UI-LFG-RoleIcon-DPS" },
    }
    R.roleButtons = {}
    Panel._state.filters.role = {} -- empty = any role
    local roleAnchor = keyMaxBox
    for ri, rd in ipairs(ROLE_DEFS) do
        local rb = CreateFrame("Button", nil, filterBar)
        rb:SetSize(28, 28)
        rb:SetPoint("LEFT", roleAnchor, "RIGHT", (ri == 1) and 12 or 4, 0)
        local rIcon = rb:CreateTexture(nil, "OVERLAY")
        rIcon:SetSize(20, 20)
        rIcon:SetPoint("CENTER")
        rIcon:SetAtlas(rd.atlas)
        rIcon:SetDesaturated(true)
        rb._icon = rIcon
        rb._role = rd.role
        rb._active = false

        rb:SetScript("OnClick", function()
            rb._active = not rb._active
            rIcon:SetDesaturated(not rb._active)
            if rb._active then
                Panel._state.filters.role[rd.role] = true
            else
                Panel._state.filters.role[rd.role] = nil
            end
        end)
        R.roleButtons[ri] = rb
        roleAnchor = rb
    end

    -- d) Min MPI input (70x28)
    local mpiBox = CreateFrame("EditBox", nil, filterBar, "BackdropTemplate")
    mpiBox:SetSize(70, 28)
    mpiBox:SetPoint("LEFT", roleAnchor, "RIGHT", 12, 0)
    mpiBox:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    mpiBox:SetBackdropColor(TC("surfaceBg"))
    mpiBox:SetBackdropBorderColor(0, 0, 0, 0)
    local mpiUnderline = mpiBox:CreateTexture(nil, "OVERLAY", nil, 2)
    mpiUnderline:SetHeight(1)
    mpiUnderline:SetPoint("BOTTOMLEFT", mpiBox, "BOTTOMLEFT", 1, 0)
    mpiUnderline:SetPoint("BOTTOMRIGHT", mpiBox, "BOTTOMRIGHT", -1, 0)
    mpiUnderline:SetColorTexture(suR, suG, suB, 0.12)
    TrySetFont(mpiBox, BODY_FONT, 10, "")
    mpiBox:SetTextColor(TC("bodyText"))
    mpiBox:SetJustifyH("CENTER")
    mpiBox:SetNumeric(true)
    mpiBox:SetMaxLetters(3)
    mpiBox:SetAutoFocus(false)
    mpiBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    mpiBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    R.mpiBox = mpiBox

    local mpiPlaceholder = mpiBox:CreateFontString(nil, "OVERLAY")
    TrySetFont(mpiPlaceholder, BODY_FONT, 10, "")
    mpiPlaceholder:SetPoint("CENTER")
    mpiPlaceholder:SetTextColor(TC("mutedText"))
    mpiPlaceholder:SetText("MPI")
    mpiBox._placeholder = mpiPlaceholder
    mpiBox:SetScript("OnTextChanged", function(self)
        mpiPlaceholder:SetShown(self:GetText() == "")
        Panel._state.filters.minMPI = tonumber(self:GetText())
    end)

    -- e) Search/Refresh button (28x28, accent-filled)
    local goBtn = CreateFrame("Button", nil, filterBar, "BackdropTemplate")
    goBtn:SetSize(28, 28)
    goBtn:SetPoint("LEFT", mpiBox, "RIGHT", 8, 0)
    goBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    local ar2, ag2, ab2 = TC("accent")
    goBtn:SetBackdropColor(ar2, ag2, ab2, 0.15)
    goBtn:SetBackdropBorderColor(ar2, ag2, ab2, 0.25)
    local goLabel = goBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(goLabel, BODY_FONT, 11, "OUTLINE")
    goLabel:SetPoint("CENTER")
    goLabel:SetTextColor(TC("accent"))
    goLabel:SetText("Go")
    goBtn:SetScript("OnClick", function() Panel.DoSearch() end)
    goBtn:SetScript("OnEnter", function()
        goBtn:SetBackdropColor(ar2, ag2, ab2, 0.25)
        goBtn:SetBackdropBorderColor(ar2, ag2, ab2, 0.45)
    end)
    goBtn:SetScript("OnLeave", function()
        goBtn:SetBackdropColor(ar2, ag2, ab2, 0.15)
        goBtn:SetBackdropBorderColor(ar2, ag2, ab2, 0.25)
    end)
    R.goBtn = goBtn

    -- ---- F4: Sort Header (24px) ----
    local sortHeader = CreateFrame("Frame", nil, listingArea)
    sortHeader:SetHeight(CFG.SORT_HEADER_H)
    sortHeader:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, 0)
    sortHeader:SetPoint("TOPRIGHT", filterBar, "BOTTOMRIGHT", 0, 0)
    local sortBg = sortHeader:CreateTexture(nil, "BACKGROUND")
    sortBg:SetAllPoints()
    sortBg:SetColorTexture(0, 0, 0, 0.12)

    -- Shadow gradient below sort header (separates from content)
    local sortShadow = sortHeader:CreateTexture(nil, "OVERLAY", nil, 0)
    sortShadow:SetHeight(4)
    sortShadow:SetPoint("TOPLEFT", sortHeader, "BOTTOMLEFT", 0, 0)
    sortShadow:SetPoint("TOPRIGHT", sortHeader, "BOTTOMRIGHT", 0, 0)
    sortShadow:SetTexture(W8)
    ApplyGradient(sortShadow, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, 0.08)
    R.sortHeader = sortHeader

    local sortCols = {
        { key = "group",   label = "Group",   anchor = "LEFT",  x = 56, w = nil },
        { key = "level",   label = "Level",   anchor = "RIGHT", x = -(55 + 36 + 54 + 36), w = 40 },
        { key = "members", label = "Members", anchor = "RIGHT", x = -(55 + 10), w = 50 },
        { key = "listed",  label = "Listed",  anchor = "RIGHT", x = -(55 + 36 + 54 + 80), w = 40 },
    }
    R.sortButtons = {}
    for _, col in ipairs(sortCols) do
        local sBtn = CreateFrame("Button", nil, sortHeader)
        sBtn:SetHeight(CFG.SORT_HEADER_H)
        if col.w then sBtn:SetWidth(col.w) end
        if col.anchor == "LEFT" then
            sBtn:SetPoint("LEFT", sortHeader, "LEFT", col.x, 0)
            if not col.w then sBtn:SetPoint("RIGHT", sortHeader, "RIGHT", -(55 + 36 + 54 + 40), 0) end
        else
            sBtn:SetPoint("RIGHT", sortHeader, "RIGHT", col.x, 0)
        end
        local sLbl = sBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(sLbl, BODY_FONT, 9, "OUTLINE")
        sLbl:SetPoint(col.anchor == "LEFT" and "LEFT" or "CENTER")
        sLbl:SetTextColor(TC("mutedText"))
        sLbl:SetText(col.label)
        sBtn._label = sLbl
        sBtn._key = col.key
        sBtn._arrow = sBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(sBtn._arrow, BODY_FONT, 9, "OUTLINE")
        sBtn._arrow:SetPoint("LEFT", sLbl, "RIGHT", 2, 0)
        sBtn._arrow:SetTextColor(TC("accent"))
        sBtn._arrow:SetText("")

        -- Accent underline (shown when this column is active sort)
        local sortLine = sBtn:CreateTexture(nil, "OVERLAY", nil, 2)
        sortLine:SetHeight(2)
        sortLine:SetPoint("BOTTOMLEFT", sBtn, "BOTTOMLEFT", 0, 0)
        sortLine:SetPoint("BOTTOMRIGHT", sBtn, "BOTTOMRIGHT", 0, 0)
        local slR, slG, slB = TC("accent")
        sortLine:SetColorTexture(slR, slG, slB, 0.5)
        sortLine:Hide()
        sBtn._underline = sortLine

        sBtn:SetScript("OnClick", function()
            if Panel._state.sortKey == col.key then
                Panel._state.sortAsc = not Panel._state.sortAsc
            else
                Panel._state.sortKey = col.key
                Panel._state.sortAsc = true
            end
            Panel.SortResults()
            -- Update all arrows and underlines
            for _, sb in ipairs(R.sortButtons) do
                if sb._key == Panel._state.sortKey then
                    sb._arrow:SetText(Panel._state.sortAsc and "^" or "v")
                    sb._label:SetTextColor(TC("accent"))
                    if sb._underline then sb._underline:Show() end
                else
                    sb._arrow:SetText("")
                    sb._label:SetTextColor(TC("mutedText"))
                    if sb._underline then sb._underline:Hide() end
                end
            end
        end)
        sBtn:SetScript("OnEnter", function() sLbl:SetTextColor(TC("bodyText")) end)
        sBtn:SetScript("OnLeave", function()
            if Panel._state.sortKey ~= col.key then sLbl:SetTextColor(TC("mutedText")) end
        end)
        R.sortButtons[#R.sortButtons + 1] = sBtn
    end

    -- ---- Scrollable Group Listing ----
    local scrollArea = CreateFrame("Frame", nil, listingArea)
    scrollArea:SetPoint("TOPLEFT", sortHeader, "BOTTOMLEFT", 0, 0)
    scrollArea:SetPoint("BOTTOMRIGHT", listingArea, "BOTTOMRIGHT", 0, 0)
    scrollArea:SetClipsChildren(true)
    R.scrollArea = scrollArea

    -- Empty state
    local emptyLabel = scrollArea:CreateFontString(nil, "OVERLAY")
    TrySetFont(emptyLabel, BODY_FONT, 14, "OUTLINE")
    emptyLabel:SetPoint("CENTER", scrollArea, "CENTER", 0, 12)
    emptyLabel:SetTextColor(TC("mutedText"))
    emptyLabel:SetText("No groups found.")
    R.emptyLabel = emptyLabel

    local retryBtn = CreateFrame("Button", nil, scrollArea, "BackdropTemplate")
    retryBtn:SetSize(80, 26)
    retryBtn:SetPoint("TOP", emptyLabel, "BOTTOM", 0, -8)
    retryBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    local rtR, rtG, rtB = TC("accent")
    retryBtn:SetBackdropColor(rtR, rtG, rtB, 0.10)
    retryBtn:SetBackdropBorderColor(rtR, rtG, rtB, 0.20)
    local retryLabel = retryBtn:CreateFontString(nil, "OVERLAY")
    TrySetFont(retryLabel, BODY_FONT, 11, "OUTLINE")
    retryLabel:SetPoint("CENTER")
    retryLabel:SetTextColor(TC("accent"))
    retryLabel:SetText("Retry")
    retryBtn:SetScript("OnClick", function() Panel.DoSearch() end)
    retryBtn:SetScript("OnEnter", function(self)
        self:SetBackdropColor(rtR, rtG, rtB, 0.20)
        self:SetBackdropBorderColor(rtR, rtG, rtB, 0.35)
    end)
    retryBtn:SetScript("OnLeave", function(self)
        self:SetBackdropColor(rtR, rtG, rtB, 0.10)
        self:SetBackdropBorderColor(rtR, rtG, rtB, 0.20)
    end)
    retryBtn:Hide()
    R.retryBtn = retryBtn

    local searchingLabel = scrollArea:CreateFontString(nil, "OVERLAY")
    TrySetFont(searchingLabel, BODY_FONT, 14, "OUTLINE")
    searchingLabel:SetPoint("CENTER")
    searchingLabel:SetTextColor(TC("mutedText"))
    searchingLabel:SetText("Searching...")
    searchingLabel:Hide()
    R.searchingLabel = searchingLabel

    -- ---- F1+F2+F5: Two-Line Row Pool (52px rows) ----
    Panel._state.scrollOffset = 0
    R.rowPool = {}

    for ri = 1, CFG.ROW_POOL_SIZE do
        local row = CreateFrame("Button", nil, scrollArea)
        row:SetHeight(CFG.ROW_H)
        row:SetPoint("TOPLEFT", scrollArea, "TOPLEFT", 0, -((ri - 1) * CFG.ROW_H))
        row:SetPoint("RIGHT", scrollArea, "RIGHT", 0, 0)
        row:Hide()

        -- Alternating row tint (even rows slightly lighter)
        local rowBg = row:CreateTexture(nil, "BACKGROUND")
        rowBg:SetAllPoints()
        if ri % 2 == 0 then
            rowBg:SetColorTexture(1, 1, 1, 0.015)
        else
            rowBg:SetColorTexture(0, 0, 0, 0)
        end
        row._bg = rowBg
        row._bgDefault = (ri % 2 == 0) and 0.015 or 0

        -- Left accent bar (hidden, shown on hover)
        local rowAccBar = row:CreateTexture(nil, "OVERLAY", nil, 2)
        rowAccBar:SetSize(2, CFG.ROW_H)
        rowAccBar:SetPoint("LEFT", row, "LEFT", 0, 0)
        rowAccBar:SetTexture(W8)
        local rowAcR, rowAcG, rowAcB = TC("accent")
        if rowAccBar.SetGradient and CreateColor then
            rowAccBar:SetGradient("VERTICAL",
                CreateColor(rowAcR, rowAcG, rowAcB, 0.1),
                CreateColor(rowAcR, rowAcG, rowAcB, 0.5))
        else
            rowAccBar:SetColorTexture(rowAcR, rowAcG, rowAcB, 0.4)
        end
        rowAccBar:SetAlpha(0)
        row._accentBar = rowAccBar

        -- Gradient divider (fades out on both ends)
        local rowDivL = row:CreateTexture(nil, "OVERLAY", nil, 1)
        rowDivL:SetHeight(1)
        rowDivL:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 0, 0)
        rowDivL:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
        rowDivL:SetTexture(W8)
        local dr, dg, db = TC("divider")
        ApplyGradient(rowDivL, "HORIZONTAL", dr, dg, db, 0, dr, dg, db, 0.10)

        local rowDivR = row:CreateTexture(nil, "OVERLAY", nil, 1)
        rowDivR:SetHeight(1)
        rowDivR:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
        rowDivR:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", 0, 0)
        rowDivR:SetTexture(W8)
        ApplyGradient(rowDivR, "HORIZONTAL", dr, dg, db, 0.10, dr, dg, db, 0)

        -- MPI badge (left, vertically centered)
        local mpiBadge = CreateFrame("Frame", nil, row)
        mpiBadge:SetSize(36, 20)
        mpiBadge:SetPoint("LEFT", row, "LEFT", 8, 0)
        local mpiBadgeBg = mpiBadge:CreateTexture(nil, "BACKGROUND")
        mpiBadgeBg:SetAllPoints()
        mpiBadgeBg:SetColorTexture(0.5, 0.5, 0.55, 0.18)
        mpiBadge._bg = mpiBadgeBg
        local mpiBadgeText = mpiBadge:CreateFontString(nil, "OVERLAY")
        TrySetFont(mpiBadgeText, BODY_FONT, 9, "OUTLINE")
        mpiBadgeText:SetPoint("CENTER")
        mpiBadgeText:SetText("--")
        mpiBadge._text = mpiBadgeText
        row._mpiBadge = mpiBadge

        -- ================================================================
        -- ROW LAYOUT (two-line, clean columns, no overlaps)
        -- ================================================================
        -- TOP LINE:    [MPI] Activity Name (+15)        [Tank][Heal][DPS] [Apply]
        -- BOTTOM LINE: [MPI] ClassIcon Leadername     3/5  12m
        -- ================================================================

        local APPLY_W = 60
        local APPLY_PAD = 10
        local ROLE_SIZE = 20
        local ROLE_GAP = 8
        local ROLES_TOTAL = ROLE_SIZE * 3 + ROLE_GAP * 2  -- 76px
        local RIGHT_ZONE = APPLY_W + APPLY_PAD + 20 + ROLES_TOTAL  -- total reserved from right edge
        local COL_TEXT_LEFT = 56  -- after MPI badge

        -- TOP LINE (y=-8): Activity name + key badge (full width up to role icons)
        local activityName = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(activityName, TITLE_FONT, 11, "OUTLINE")
        activityName:SetPoint("TOPLEFT", row, "TOPLEFT", COL_TEXT_LEFT, -8)
        activityName:SetPoint("RIGHT", row, "RIGHT", -(RIGHT_ZONE + 14), 0)
        activityName:SetJustifyH("LEFT")
        activityName:SetWordWrap(false)
        activityName:SetTextColor(TC("bodyText"))
        row._activityName = activityName

        local keyBadge = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(keyBadge, TITLE_FONT, 11, "OUTLINE")
        keyBadge:SetPoint("LEFT", activityName, "RIGHT", 6, 0)
        keyBadge:SetTextColor(TC("accent"))
        row._keyBadge = keyBadge

        -- BOTTOM LINE (y=-30): Class icon + leader name + count + time
        local leaderClassIcon = row:CreateTexture(nil, "ARTWORK")
        leaderClassIcon:SetSize(14, 14)
        leaderClassIcon:SetPoint("TOPLEFT", row, "TOPLEFT", COL_TEXT_LEFT, -30)
        row._leaderClassIcon = leaderClassIcon

        local leaderName = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(leaderName, BODY_FONT, 9, "")
        leaderName:SetPoint("LEFT", leaderClassIcon, "RIGHT", 4, 0)
        leaderName:SetWidth(180)
        leaderName:SetJustifyH("LEFT")
        leaderName:SetWordWrap(false)
        leaderName:SetTextColor(TC("mutedText"))
        row._leaderName = leaderName

        -- Member count (bottom line, after leader name)
        local countText = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(countText, BODY_FONT, 9, "")
        countText:SetPoint("LEFT", leaderName, "RIGHT", 12, 0)
        countText:SetWidth(35)
        countText:SetJustifyH("CENTER")
        countText:SetTextColor(TC("mutedText"))
        row._countText = countText

        -- Time listed (bottom line, after count)
        local listedText = row:CreateFontString(nil, "OVERLAY")
        TrySetFont(listedText, BODY_FONT, 9, "")
        listedText:SetPoint("LEFT", countText, "RIGHT", 8, 0)
        listedText:SetWidth(35)
        listedText:SetJustifyH("LEFT")
        listedText:SetTextColor(TC("mutedText"))
        row._listedText = listedText

        -- Compat refs
        row._leaderText = leaderName
        row._groupName = activityName

        -- ROLE ICONS (3x 20x20, right-aligned, left of Apply)
        local roleIcons = {}
        local roleBubbles = {}
        for rri, rrd in ipairs(ROLE_DEFS) do
            local btn = CreateFrame("Button", nil, row)
            btn:SetSize(ROLE_SIZE, ROLE_SIZE)
            btn:SetFrameLevel(row:GetFrameLevel() + 2)
            local icon = btn:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            pcall(icon.SetAtlas, icon, rrd.atlas)
            icon:SetDesaturated(true)
            icon:SetAlpha(0.3)
            icon:Show()
            btn._tex = icon
            btn:EnableMouse(false)
            btn:Show()
            roleIcons[rri] = btn
        end
        -- Chain: first icon anchored from right, rest follow left-to-right
        -- Anchor rightmost icon (DPS) 20px left of Apply, chain backwards
        roleIcons[3]:SetPoint("RIGHT", row, "RIGHT", -(APPLY_W + APPLY_PAD + 20), 0)
        roleIcons[2]:SetPoint("RIGHT", roleIcons[3], "LEFT", -ROLE_GAP, 0)
        roleIcons[1]:SetPoint("RIGHT", roleIcons[2], "LEFT", -ROLE_GAP, 0)

        -- Count bubbles (bottom-right of each icon)
        for rri = 1, 3 do
            local bubble = CreateFrame("Frame", nil, row)
            bubble:SetSize(13, 13)
            bubble:SetPoint("BOTTOMRIGHT", roleIcons[rri], "BOTTOMRIGHT", 4, -3)
            bubble:SetFrameLevel(row:GetFrameLevel() + 4)
            local bubbleBg = bubble:CreateTexture(nil, "BACKGROUND")
            bubbleBg:SetAllPoints()
            bubbleBg:SetColorTexture(0.06, 0.06, 0.08, 0.9)
            local bubbleBorder = bubble:CreateTexture(nil, "BORDER")
            bubbleBorder:SetPoint("TOPLEFT", -1, 1)
            bubbleBorder:SetPoint("BOTTOMRIGHT", 1, -1)
            bubbleBorder:SetColorTexture(0.25, 0.25, 0.30, 0.5)
            local countFs = bubble:CreateFontString(nil, "OVERLAY")
            pcall(countFs.SetFont, countFs, BODY_FONT, 8, "OUTLINE")
            countFs:SetPoint("CENTER", 0, 0)
            countFs:SetTextColor(1, 1, 1)
            bubble._text = countFs
            bubble:Hide()
            roleBubbles[rri] = bubble
        end
        row._roleIcons = roleIcons
        row._roleBubbles = roleBubbles

        -- APPLY BUTTON (right edge, accent-filled)
        local applyBtn = CreateFrame("Button", nil, row, "BackdropTemplate")
        applyBtn:SetSize(APPLY_W, 24)
        applyBtn:SetPoint("RIGHT", row, "RIGHT", -APPLY_PAD, 0)
        applyBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        local aR, aG, aB = TC("accent")
        applyBtn:SetBackdropColor(aR, aG, aB, 0.10)
        applyBtn:SetBackdropBorderColor(aR, aG, aB, 0.20)
        local applyLabel = applyBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(applyLabel, BODY_FONT, 10, "OUTLINE")
        applyLabel:SetPoint("CENTER")
        applyLabel:SetTextColor(TC("accent"))
        applyLabel:SetText("Apply")
        applyBtn._resultID = nil
        applyBtn._label = applyLabel
        applyBtn:SetScript("OnClick", function(self)
            if self._resultID then Panel.ApplyToGroup(self._resultID) end
        end)
        applyBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(aR, aG, aB, 0.20)
            self:SetBackdropBorderColor(aR, aG, aB, 0.40)
        end)
        applyBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(aR, aG, aB, 0.10)
            self:SetBackdropBorderColor(aR, aG, aB, 0.20)
        end)
        row._applyBtn = applyBtn

        -- Hover + click (accent-tinted hover with left bar)
        row:SetScript("OnEnter", function(self)
            local hR, hG, hB, hA = TC("hoverBg")
            rowBg:SetColorTexture(hR, hG, hB, hA)
            rowAccBar:SetAlpha(1)
            -- Tooltip with raw group title + comment
            if self._tooltipTitle and self._tooltipTitle ~= "" then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:AddLine(self._tooltipTitle, 0.9, 0.9, 0.9)
                if self._tooltipComment and self._tooltipComment ~= "" then
                    GameTooltip:AddLine(self._tooltipComment, 0.6, 0.6, 0.6, true)
                end
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function(self)
            if self._bgDefault and self._bgDefault > 0 then
                rowBg:SetColorTexture(1, 1, 1, self._bgDefault)
            else
                rowBg:SetColorTexture(0, 0, 0, 0)
            end
            rowAccBar:SetAlpha(0)
            GameTooltip:Hide()
        end)
        row:SetScript("OnClick", function()
            if row._resultID then Panel.ShowGroupDetail(row._resultID) end
        end)

        row._resultID = nil
        row._tooltipTitle = nil
        row._tooltipComment = nil
        R.rowPool[ri] = row
    end

    -- Scroll bar indicator
    local scrollTrack = listingArea:CreateTexture(nil, "OVERLAY", nil, 1)
    scrollTrack:SetWidth(3)
    scrollTrack:SetPoint("TOPRIGHT", scrollArea, "TOPRIGHT", 6, -2)
    scrollTrack:SetPoint("BOTTOMRIGHT", scrollArea, "BOTTOMRIGHT", 6, 2)
    scrollTrack:SetColorTexture(1, 1, 1, 0.04)
    scrollTrack:Hide()
    R.scrollTrack = scrollTrack

    local scrollThumb = CreateFrame("Frame", nil, listingArea)
    scrollThumb:SetWidth(3)
    scrollThumb:SetHeight(30)
    scrollThumb:SetPoint("TOPRIGHT", scrollTrack, "TOPRIGHT", 0, 0)
    scrollThumb:SetFrameLevel(listingArea:GetFrameLevel() + 5)
    local thumbTex = scrollThumb:CreateTexture(nil, "OVERLAY")
    thumbTex:SetAllPoints()
    thumbTex:SetColorTexture(TC("accent"))
    thumbTex:SetAlpha(0.35)
    scrollThumb:Hide()
    R.scrollThumb = scrollThumb

    -- Mouse wheel scrolling
    scrollArea:EnableMouseWheel(true)
    scrollArea:SetScript("OnMouseWheel", function(_, delta)
        local maxOffset = math.max(0, #Panel._state.searchResults - CFG.ROW_POOL_SIZE)
        Panel._state.scrollOffset = math.max(0, math.min(Panel._state.scrollOffset - delta, maxOffset))
        Panel.UpdateListingRows()
        Panel.UpdateScrollBar()
    end)

    -- ---- Group Intel Sidebar Content (role demand + application tracker) ----
    -- Player info moved to premade hero. Sidebar now shows search intelligence.
    do
        local ps = R.playerSidebar
        local yOff = -10
        local INNER_PAD = 10
        local PANEL_GAP = 8
        local PANEL_W = CFG.PLAYER_SIDEBAR_W - INNER_PAD * 2
        local SECTION_PAD = 12  -- internal padding within panels
        local ihlR, ihlG, ihlB = TC("accent")

        -- ================================================================
        -- §1  LEADER MPI + GROUP CONTEXT
        -- ================================================================
        Panel._state.applyRole = { tank = false, healer = false, dps = false }

        -- ── §1a  LEADER MPI card ──
        local mpiCardH = 270
        local mpiPanel = CreateGlassPanel(ps, PANEL_W)
        mpiPanel:SetHeight(mpiCardH)
        mpiPanel:SetPoint("TOPLEFT", ps, "TOPLEFT", INNER_PAD, yOff)
        R.intel_mpiPanel = mpiPanel

        -- Panel header with accent dot
        local mpiDot = mpiPanel:CreateTexture(nil, "OVERLAY", nil, 2)
        mpiDot:SetSize(4, 4)
        mpiDot:SetPoint("TOPLEFT", mpiPanel, "TOPLEFT", SECTION_PAD, -SECTION_PAD)
        mpiDot:SetColorTexture(ihlR, ihlG, ihlB, 0.8)

        local mpiHeader = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(mpiHeader, BODY_FONT, 9, "OUTLINE")
        mpiHeader:SetPoint("LEFT", mpiDot, "RIGHT", 5, 0)
        mpiHeader:SetTextColor(TC("mutedText"))
        mpiHeader:SetText("LEADER MPI")

        -- Empty state
        local mpiEmpty = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(mpiEmpty, BODY_FONT, 10, "")
        mpiEmpty:SetPoint("CENTER", mpiPanel, "CENTER", 0, 4)
        mpiEmpty:SetTextColor(TC("mutedText"))
        mpiEmpty:SetText("Select a group to see\nleader MPI score")
        mpiEmpty:SetJustifyH("CENTER")
        mpiEmpty:SetSpacing(3)
        R.intel_mpiEmpty = mpiEmpty

        -- ---- Score card header row (class icon + name + score + tier) ----
        local cardTopY = -28

        -- Class initial badge (colored square)
        local classIcon = mpiPanel:CreateTexture(nil, "ARTWORK")
        classIcon:SetSize(28, 28)
        classIcon:SetPoint("TOPLEFT", mpiPanel, "TOPLEFT", SECTION_PAD, cardTopY)
        classIcon:SetColorTexture(0.4, 0.2, 0.6, 1)
        R.mpi_classIcon = classIcon

        local classInitial = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(classInitial, TITLE_FONT, 12, "OUTLINE")
        classInitial:SetPoint("CENTER", classIcon, "CENTER", 0, 0)
        classInitial:SetTextColor(1, 1, 1)
        R.mpi_classInitial = classInitial

        -- Player name
        local cardName = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(cardName, BODY_FONT, 11, "")
        cardName:SetPoint("TOPLEFT", classIcon, "TOPRIGHT", 6, -1)
        cardName:SetTextColor(1, 1, 1)
        R.mpi_cardName = cardName

        -- Realm name
        local cardRealm = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(cardRealm, BODY_FONT, 8, "")
        cardRealm:SetPoint("LEFT", cardName, "RIGHT", 4, 0)
        cardRealm:SetTextColor(TC("mutedText"))
        R.mpi_cardRealm = cardRealm

        -- Class + Role line
        local cardClass = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(cardClass, BODY_FONT, 9, "")
        cardClass:SetPoint("TOPLEFT", cardName, "BOTTOMLEFT", 0, -2)
        R.mpi_cardClass = cardClass

        local cardRole = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(cardRole, BODY_FONT, 8, "OUTLINE")
        cardRole:SetPoint("LEFT", cardClass, "RIGHT", 6, 0)
        cardRole:SetTextColor(TC("mutedText"))
        R.mpi_cardRole = cardRole

        -- Score (large number, right side)
        local cardScore = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(cardScore, TITLE_FONT, 20, "OUTLINE")
        cardScore:SetPoint("TOPRIGHT", mpiPanel, "TOPRIGHT", -40, cardTopY - 2)
        R.mpi_cardScore = cardScore

        -- Tier badge (bordered square right of score)
        local tierBadge = CreateFrame("Frame", nil, mpiPanel, "BackdropTemplate")
        tierBadge:SetSize(22, 22)
        tierBadge:SetPoint("LEFT", cardScore, "RIGHT", 4, 0)
        tierBadge:SetBackdrop({
            bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 },
        })
        tierBadge:SetBackdropColor(0, 0, 0, 0.3)
        R.mpi_tierBadge = tierBadge

        local tierText = tierBadge:CreateFontString(nil, "OVERLAY")
        TrySetFont(tierText, TITLE_FONT, 11, "OUTLINE")
        tierText:SetPoint("CENTER", tierBadge, "CENTER", 0, 0)
        R.mpi_tierText = tierText

        -- Trend line (below score)
        local trendIcon = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(trendIcon, TITLE_FONT, 9, "")
        trendIcon:SetPoint("TOPRIGHT", mpiPanel, "TOPRIGHT", -SECTION_PAD, cardTopY - 26)
        R.mpi_trendIcon = trendIcon

        -- Divider below header
        local cardDiv = mpiPanel:CreateTexture(nil, "ARTWORK")
        cardDiv:SetTexture(W8)
        cardDiv:SetHeight(1)
        cardDiv:SetPoint("TOPLEFT", mpiPanel, "TOPLEFT", SECTION_PAD, cardTopY - 36)
        cardDiv:SetPoint("RIGHT", mpiPanel, "RIGHT", -SECTION_PAD, 0)
        cardDiv:SetVertexColor(1, 1, 1, 0.06)
        R.mpi_cardDiv = cardDiv

        -- Dimension bars (5 rows)
        local DIM_NAMES = { "Awareness", "Survival", "Output", "Utility", "Consistency" }
        R.mpi_dimRows = {}
        local barStartY = cardTopY - 46
        local BAR_ROW_H = 28

        for i, dimName in ipairs(DIM_NAMES) do
            local rowY = barStartY - (i - 1) * BAR_ROW_H
            local dimRow = {}

            local label = mpiPanel:CreateFontString(nil, "OVERLAY")
            TrySetFont(label, BODY_FONT, 9, "")
            label:SetPoint("TOPLEFT", mpiPanel, "TOPLEFT", SECTION_PAD, rowY)
            label:SetTextColor(TC("mutedText"))
            label:SetText(dimName)
            dimRow.label = label

            local value = mpiPanel:CreateFontString(nil, "OVERLAY")
            TrySetFont(value, BODY_FONT, 9, "OUTLINE")
            value:SetPoint("TOPRIGHT", mpiPanel, "TOPRIGHT", -SECTION_PAD, rowY)
            dimRow.value = value

            local track = mpiPanel:CreateTexture(nil, "BACKGROUND")
            track:SetHeight(4)
            track:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -3)
            track:SetPoint("RIGHT", mpiPanel, "RIGHT", -(SECTION_PAD + 30), 0)
            track:SetColorTexture(0.15, 0.15, 0.20, 0.8)
            dimRow.track = track

            local fill = mpiPanel:CreateTexture(nil, "ARTWORK")
            fill:SetHeight(4)
            fill:SetPoint("TOPLEFT", track, "TOPLEFT", 0, 0)
            fill:SetWidth(1)
            dimRow.fill = fill

            R.mpi_dimRows[i] = dimRow
        end

        -- Badges row
        local badgeDiv = mpiPanel:CreateTexture(nil, "ARTWORK")
        badgeDiv:SetTexture(W8)
        badgeDiv:SetHeight(1)
        local badgeDivY = barStartY - 5 * BAR_ROW_H - 4
        badgeDiv:SetPoint("TOPLEFT", mpiPanel, "TOPLEFT", SECTION_PAD, badgeDivY)
        badgeDiv:SetPoint("RIGHT", mpiPanel, "RIGHT", -SECTION_PAD, 0)
        badgeDiv:SetVertexColor(1, 1, 1, 0.06)
        R.mpi_badgeDiv = badgeDiv

        local badgeLabel = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(badgeLabel, BODY_FONT, 8, "OUTLINE")
        badgeLabel:SetPoint("TOPLEFT", badgeDiv, "BOTTOMLEFT", 0, -6)
        badgeLabel:SetTextColor(TC("mutedText"))
        badgeLabel:SetText("BADGES")
        R.mpi_badgeLabel = badgeLabel

        R.mpi_badgeSlots = {}
        for bi = 1, 6 do
            local slot = mpiPanel:CreateFontString(nil, "OVERLAY")
            TrySetFont(slot, BODY_FONT, 8, "OUTLINE")
            if bi == 1 then
                slot:SetPoint("LEFT", badgeLabel, "RIGHT", 8, 0)
            else
                slot:SetPoint("LEFT", R.mpi_badgeSlots[bi - 1], "RIGHT", 4, 0)
            end
            slot:SetTextColor(ihlR, ihlG, ihlB, 0.8)
            slot:Hide()
            R.mpi_badgeSlots[bi] = slot
        end

        -- "No data" state
        local noDataMsg = mpiPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(noDataMsg, BODY_FONT, 9, "")
        noDataMsg:SetPoint("TOPLEFT", cardDiv, "BOTTOMLEFT", 0, -16)
        noDataMsg:SetPoint("RIGHT", mpiPanel, "RIGHT", -SECTION_PAD, 0)
        noDataMsg:SetTextColor(TC("mutedText"))
        noDataMsg:SetJustifyH("CENTER")
        noDataMsg:SetWordWrap(true)
        noDataMsg:SetSpacing(3)
        noDataMsg:SetText("No community data for this leader.\nRun keys with MPI to build scores.")
        noDataMsg:Hide()
        R.mpi_noDataMsg = noDataMsg

        -- Hide all initially
        classIcon:Hide(); classInitial:Hide()
        cardName:Hide(); cardRealm:Hide(); cardClass:Hide(); cardRole:Hide()
        cardScore:Hide(); tierBadge:Hide(); trendIcon:Hide()
        cardDiv:Hide(); badgeDiv:Hide(); badgeLabel:Hide()
        for _, dr in ipairs(R.mpi_dimRows) do
            dr.label:Hide(); dr.value:Hide(); dr.track:Hide(); dr.fill:Hide()
        end
        mpiEmpty:Show()

        yOff = yOff - mpiCardH - PANEL_GAP

        -- ── §1b  GROUP CONTEXT — listed age, your fit ──
        local ctxPanel = CreateGlassPanel(ps, PANEL_W)
        ctxPanel:SetHeight(100)
        ctxPanel:SetPoint("TOPLEFT", ps, "TOPLEFT", INNER_PAD, yOff)
        R.intel_ctxPanel = ctxPanel

        local ctxDot = ctxPanel:CreateTexture(nil, "OVERLAY", nil, 2)
        ctxDot:SetSize(4, 4)
        ctxDot:SetPoint("TOPLEFT", ctxPanel, "TOPLEFT", SECTION_PAD, -SECTION_PAD)
        ctxDot:SetColorTexture(ihlR, ihlG, ihlB, 0.8)

        local ctxHeader = ctxPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(ctxHeader, BODY_FONT, 9, "OUTLINE")
        ctxHeader:SetPoint("LEFT", ctxDot, "RIGHT", 5, 0)
        ctxHeader:SetTextColor(TC("mutedText"))
        ctxHeader:SetText("GROUP CONTEXT")

        -- Listed age line
        local ctxAge = ctxPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(ctxAge, BODY_FONT, 9, "")
        ctxAge:SetPoint("TOPLEFT", ctxPanel, "TOPLEFT", SECTION_PAD, -28)
        ctxAge:SetPoint("RIGHT", ctxPanel, "RIGHT", -SECTION_PAD, 0)
        ctxAge:SetTextColor(TC("mutedText"))
        ctxAge:SetWordWrap(true)
        R.intel_ctxAge = ctxAge

        -- Your fit line
        local ctxFit = ctxPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(ctxFit, BODY_FONT, 9, "")
        ctxFit:SetPoint("TOPLEFT", ctxAge, "BOTTOMLEFT", 0, -4)
        ctxFit:SetPoint("RIGHT", ctxPanel, "RIGHT", -SECTION_PAD, 0)
        ctxFit:SetTextColor(TC("bodyText"))
        ctxFit:SetWordWrap(true)
        R.intel_ctxFit = ctxFit

        -- Leader abandon/completion info
        local ctxLeaderInfo = ctxPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(ctxLeaderInfo, BODY_FONT, 9, "")
        ctxLeaderInfo:SetPoint("TOPLEFT", ctxFit, "BOTTOMLEFT", 0, -4)
        ctxLeaderInfo:SetPoint("RIGHT", ctxPanel, "RIGHT", -SECTION_PAD, 0)
        ctxLeaderInfo:SetTextColor(TC("mutedText"))
        ctxLeaderInfo:SetWordWrap(true)
        R.intel_ctxLeaderInfo = ctxLeaderInfo

        ctxPanel:Hide()
        R.intel_ctxPanel = ctxPanel

        yOff = yOff - 100 - PANEL_GAP

        -- ================================================================
        -- §2  NOTE TO LEADER — input card with visible field
        -- ================================================================
        local notePanel = CreateGlassPanel(ps, PANEL_W)
        notePanel:SetHeight(80)
        notePanel:SetPoint("TOPLEFT", ps, "TOPLEFT", INNER_PAD, yOff)
        R.intel_notePanel = notePanel

        -- Header with accent dot
        local noteDot = notePanel:CreateTexture(nil, "OVERLAY", nil, 2)
        noteDot:SetSize(4, 4)
        noteDot:SetPoint("TOPLEFT", notePanel, "TOPLEFT", SECTION_PAD, -SECTION_PAD)
        noteDot:SetColorTexture(ihlR, ihlG, ihlB, 0.8)

        local descLabel = notePanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(descLabel, BODY_FONT, 9, "OUTLINE")
        descLabel:SetPoint("LEFT", noteDot, "RIGHT", 5, 0)
        descLabel:SetTextColor(TC("mutedText"))
        descLabel:SetText("NOTE TO LEADER")

        -- Inset input field
        local descBox = CreateFrame("EditBox", nil, notePanel, "BackdropTemplate")
        descBox:SetHeight(42)
        descBox:SetPoint("TOPLEFT", notePanel, "TOPLEFT", 8, -28)
        descBox:SetPoint("TOPRIGHT", notePanel, "TOPRIGHT", -8, -28)
        descBox:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        descBox:SetBackdropColor(0, 0, 0, 0.35)
        descBox:SetBackdropBorderColor(1, 1, 1, 0.12)
        TrySetFont(descBox, BODY_FONT, 10, "")
        descBox:SetTextColor(TC("bodyText"))
        descBox:SetAutoFocus(false)
        descBox:SetMaxLetters(60)
        descBox:SetMultiLine(true)
        descBox:SetTextInsets(10, 10, 8, 8)
        descBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        -- Focus glow: accent border when editing
        descBox:SetScript("OnEditFocusGained", function(self)
            self:SetBackdropBorderColor(ihlR, ihlG, ihlB, 0.5)
        end)
        descBox:SetScript("OnEditFocusLost", function(self)
            self:SetBackdropBorderColor(1, 1, 1, 0.12)
        end)
        R.applyDescBox = descBox

        -- Placeholder text
        local descPlaceholder = descBox:CreateFontString(nil, "OVERLAY")
        TrySetFont(descPlaceholder, BODY_FONT, 10, "")
        descPlaceholder:SetPoint("TOPLEFT", descBox, "TOPLEFT", 10, -8)
        descPlaceholder:SetTextColor(TC("mutedText"))
        descPlaceholder:SetText("Write a note...")
        descBox:SetScript("OnTextChanged", function(self)
            descPlaceholder:SetShown(self:GetText() == "")
        end)

        yOff = yOff - 80 - PANEL_GAP

        -- ================================================================
        -- §3  MY APPLICATIONS — hover flyout from sidebar trigger
        -- ================================================================

        -- Trigger button (bottom of sidebar)
        local appTrigger = CreateFrame("Frame", nil, ps, "BackdropTemplate")
        appTrigger:SetHeight(28)
        appTrigger:SetPoint("BOTTOMLEFT", ps, "BOTTOMLEFT", INNER_PAD, 10)
        appTrigger:SetPoint("BOTTOMRIGHT", ps, "BOTTOMRIGHT", -INNER_PAD, 10)
        appTrigger:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        appTrigger:SetBackdropColor(0.06, 0.06, 0.08, 0.75)
        appTrigger:SetBackdropBorderColor(0.20, 0.20, 0.25, 0.5)
        appTrigger:EnableMouse(true)

        local appTrigDot = appTrigger:CreateTexture(nil, "OVERLAY", nil, 2)
        appTrigDot:SetSize(4, 4)
        appTrigDot:SetPoint("LEFT", appTrigger, "LEFT", 10, 0)
        appTrigDot:SetColorTexture(ihlR, ihlG, ihlB, 0.8)

        local appTrigLabel = appTrigger:CreateFontString(nil, "OVERLAY")
        TrySetFont(appTrigLabel, BODY_FONT, 9, "OUTLINE")
        appTrigLabel:SetPoint("LEFT", appTrigDot, "RIGHT", 5, 0)
        appTrigLabel:SetTextColor(TC("mutedText"))
        appTrigLabel:SetText("MY APPLICATIONS (0/5)")
        R.intel_appHeader = appTrigLabel

        local appTrigArrow = appTrigger:CreateFontString(nil, "OVERLAY")
        TrySetFont(appTrigArrow, BODY_FONT, 10, "")
        appTrigArrow:SetPoint("RIGHT", appTrigger, "RIGHT", -8, 0)
        appTrigArrow:SetTextColor(TC("mutedText"))
        appTrigArrow:SetText("<") -- left-pointing arrow

        -- Flyout panel (appears to the left of the sidebar on hover)
        local FLYOUT_W = 240
        local APP_CARD_H = 40
        local APP_CARD_GAP = 4
        local FLYOUT_MAX_H = 28 + 5 * (APP_CARD_H + APP_CARD_GAP) + 8

        local appFlyout = CreateFrame("Frame", nil, ps, "BackdropTemplate")
        appFlyout:SetSize(FLYOUT_W, FLYOUT_MAX_H)
        appFlyout:SetPoint("BOTTOMRIGHT", ps, "BOTTOMLEFT", -4, 0)
        appFlyout:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        appFlyout:SetBackdropColor(0.04, 0.04, 0.06, 0.96)
        appFlyout:SetBackdropBorderColor(ihlR, ihlG, ihlB, 0.25)
        appFlyout:SetFrameLevel(ps:GetFrameLevel() + 15)
        appFlyout:EnableMouse(true)
        appFlyout:Hide()
        R.intel_appFlyout = appFlyout

        -- Flyout header
        local flyHeader = appFlyout:CreateFontString(nil, "OVERLAY")
        TrySetFont(flyHeader, BODY_FONT, 9, "OUTLINE")
        flyHeader:SetPoint("TOPLEFT", appFlyout, "TOPLEFT", 10, -10)
        flyHeader:SetTextColor(TC("mutedText"))
        flyHeader:SetText("MY APPLICATIONS")

        -- Empty state
        local appEmpty = appFlyout:CreateFontString(nil, "OVERLAY")
        TrySetFont(appEmpty, BODY_FONT, 10, "")
        appEmpty:SetPoint("CENTER", appFlyout, "CENTER", 0, 0)
        appEmpty:SetTextColor(TC("mutedText"))
        appEmpty:SetText("No applications yet")
        R.intel_appEmpty = appEmpty

        -- Application cards inside flyout
        R.intel_appRows = {}
        for ai = 1, 5 do
            local cardY = -28 - (ai - 1) * (APP_CARD_H + APP_CARD_GAP)

            local card = CreateFrame("Frame", nil, appFlyout, "BackdropTemplate")
            card:SetHeight(APP_CARD_H)
            card:SetPoint("TOPLEFT", appFlyout, "TOPLEFT", 6, cardY)
            card:SetPoint("TOPRIGHT", appFlyout, "TOPRIGHT", -6, cardY)
            card:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 } })
            card:SetBackdropColor(0, 0, 0, 0.25)
            card:SetBackdropBorderColor(1, 1, 1, 0.06)

            -- Accent bar (left edge, 2px)
            local statusBar = card:CreateTexture(nil, "OVERLAY", nil, 2)
            statusBar:SetWidth(2)
            statusBar:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
            statusBar:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 0, 0)
            statusBar:SetTexture(W8)
            local appAcR, appAcG, appAcB = TC("accent")
            if statusBar.SetGradient and CreateColor then
                statusBar:SetGradient("VERTICAL",
                    CreateColor(appAcR, appAcG, appAcB, 0.2),
                    CreateColor(appAcR, appAcG, appAcB, 0.8))
            else
                statusBar:SetColorTexture(appAcR, appAcG, appAcB)
            end
            card._statusBar = statusBar

            -- Group name
            local appName = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(appName, BODY_FONT, 10, "")
            appName:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -6)
            appName:SetPoint("RIGHT", card, "RIGHT", -24, 0)
            appName:SetJustifyH("LEFT")
            appName:SetWordWrap(false)
            appName:SetTextColor(TC("bodyText"))
            card._name = appName

            -- Status
            local appStatus = card:CreateFontString(nil, "OVERLAY")
            TrySetFont(appStatus, BODY_FONT, 9, "")
            appStatus:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 6)
            appStatus:SetTextColor(TC("mutedText"))
            card._status = appStatus

            -- Cancel button
            local cancelBtn = CreateFrame("Button", nil, card)
            cancelBtn:SetSize(20, 20)
            cancelBtn:SetPoint("RIGHT", card, "RIGHT", -6, 0)
            local cancelX = cancelBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(cancelX, BODY_FONT, 10, "OUTLINE")
            cancelX:SetPoint("CENTER")
            cancelX:SetTextColor(TC("mutedText"))
            cancelX:SetText("x")
            cancelBtn:SetScript("OnEnter", function() cancelX:SetTextColor(1, 0.3, 0.3) end)
            cancelBtn:SetScript("OnLeave", function() cancelX:SetTextColor(TC("mutedText")) end)
            cancelBtn._resultID = nil
            cancelBtn:SetScript("OnClick", function(self)
                if self._resultID then
                    pcall(C_LFGList.CancelApplication, self._resultID)
                    C_Timer.After(0.3, function()
                        Panel.UpdateGroupIntelSidebar()
                        -- Re-show flyout after cancel so user sees updated list
                        if R.intel_appFlyout then R.intel_appFlyout:Show() end
                    end)
                end
            end)
            card._cancelBtn = cancelBtn

            card:Hide()
            R.intel_appRows[ai] = card
        end

        -- Hover show/hide logic for trigger + flyout
        local hideTimer = nil
        local function ShowFlyout()
            if hideTimer then hideTimer:Cancel(); hideTimer = nil end
            Panel.UpdateGroupIntelSidebar()
            appFlyout:Show()
            appTrigger:SetBackdropBorderColor(ihlR, ihlG, ihlB, 0.4)
            appTrigLabel:SetTextColor(1, 1, 1)
            appTrigArrow:SetTextColor(1, 1, 1)
        end
        local function ScheduleHide()
            if hideTimer then hideTimer:Cancel() end
            hideTimer = C_Timer.NewTimer(0.25, function()
                appFlyout:Hide()
                appTrigger:SetBackdropBorderColor(0.20, 0.20, 0.25, 0.5)
                appTrigLabel:SetTextColor(TC("mutedText"))
                appTrigArrow:SetTextColor(TC("mutedText"))
                hideTimer = nil
            end)
        end

        appTrigger:SetScript("OnEnter", ShowFlyout)
        appTrigger:SetScript("OnLeave", ScheduleHide)
        appFlyout:SetScript("OnEnter", ShowFlyout)
        appFlyout:SetScript("OnLeave", ScheduleHide)

        R.intel_categoryLine = nil
        R.intel_searchTimeLine = nil
    end

    -- ---- Group Detail Panel (overlays bottom of listing area, 300px) ----
    do
        local detailPanel = CreateFrame("Frame", nil, R.listingArea, "BackdropTemplate")
        detailPanel:SetHeight(CFG.DETAIL_PANEL_H)
        detailPanel:SetPoint("BOTTOMLEFT", R.listingArea, "BOTTOMLEFT", 0, 0)
        detailPanel:SetPoint("BOTTOMRIGHT", R.listingArea, "BOTTOMRIGHT", 0, 0)
        detailPanel:SetFrameLevel(R.listingArea:GetFrameLevel() + 10)
        detailPanel:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        detailPanel:SetBackdropColor(0.025, 0.028, 0.045, 0.98)
        local ac = activeTheme.accent
        detailPanel:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.12)
        detailPanel:Hide()
        R.detailPanel = detailPanel

        -- Block clicks from falling through to rows beneath
        detailPanel:EnableMouse(true)

        -- Header row -----------------------------------------------

        -- Back arrow (atlas icon, centered on the header row)
        local DETAIL_HEADER_H = 36
        local backBtn = CreateFrame("Button", nil, detailPanel)
        backBtn:SetSize(24, DETAIL_HEADER_H)
        backBtn:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 8, -2)
        local backIcon = backBtn:CreateTexture(nil, "ARTWORK")
        backIcon:SetSize(14, 14)
        backIcon:SetPoint("CENTER")
        local arrowOk = pcall(backIcon.SetAtlas, backIcon, "shop-header-arrow")
        if arrowOk then
            backIcon:SetTexCoord(0, 1, 1, 0) -- flip to point left
        else
            backIcon:Hide()
            local backFallback = backBtn:CreateFontString(nil, "OVERLAY")
            TrySetFont(backFallback, TITLE_FONT, 16, "")
            backFallback:SetPoint("CENTER")
            backFallback:SetTextColor(TC("mutedText"))
            backFallback:SetText("\226\134\144")
        end
        backIcon:SetVertexColor(TC("mutedText"))
        backBtn:SetScript("OnEnter", function() backIcon:SetVertexColor(TC("accent")) end)
        backBtn:SetScript("OnLeave", function() backIcon:SetVertexColor(TC("mutedText")) end)
        backBtn:SetScript("OnClick", function() Panel.HideGroupDetail() end)

        -- Title block (same height as header row, centered with arrow)
        local titleBlock = CreateFrame("Frame", nil, detailPanel)
        titleBlock:SetHeight(DETAIL_HEADER_H)
        titleBlock:SetPoint("TOPLEFT", backBtn, "TOPRIGHT", 4, 0)
        titleBlock:SetPoint("RIGHT", detailPanel, "RIGHT", -100, 0)

        -- Group name (top of title block)
        local groupName = titleBlock:CreateFontString(nil, "OVERLAY")
        TrySetFont(groupName, TITLE_FONT, 14, "OUTLINE")
        groupName:SetPoint("TOPLEFT", titleBlock, "TOPLEFT", 0, -4)
        groupName:SetPoint("RIGHT", titleBlock, "RIGHT", 0, 0)
        groupName:SetJustifyH("LEFT")
        groupName:SetTextColor(TC("bodyText"))
        groupName:SetWordWrap(false)
        R.detail_groupName = groupName

        -- Comment (below group name, 4px gap)
        local comment = titleBlock:CreateFontString(nil, "OVERLAY")
        TrySetFont(comment, BODY_FONT, 10, "")
        comment:SetPoint("TOPLEFT", groupName, "BOTTOMLEFT", 0, -4)
        comment:SetPoint("RIGHT", titleBlock, "RIGHT", 0, 0)
        comment:SetJustifyH("LEFT")
        comment:SetTextColor(TC("mutedText"))
        comment:SetWordWrap(false)
        R.detail_comment = comment

        -- Apply button (right side, vertically centered with header row)
        local applyBtn = CreateFrame("Button", nil, detailPanel, "BackdropTemplate")
        applyBtn:SetSize(80, 26)
        applyBtn:SetPoint("RIGHT", detailPanel, "RIGHT", -10, 0)
        applyBtn:SetPoint("TOP", detailPanel, "TOP", 0, -(math.floor((DETAIL_HEADER_H - 26) / 2) + 2))
        applyBtn:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        local dAr, dAg, dAb = TC("accent")
        applyBtn:SetBackdropColor(dAr, dAg, dAb, 0.15)
        applyBtn:SetBackdropBorderColor(dAr, dAg, dAb, 0.30)
        local applyLbl = applyBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(applyLbl, BODY_FONT, 11, "OUTLINE")
        applyLbl:SetPoint("CENTER")
        applyLbl:SetTextColor(TC("accent"))
        applyLbl:SetText("Apply")
        applyBtn._label = applyLbl
        applyBtn:SetScript("OnEnter", function(self)
            self:SetBackdropColor(dAr, dAg, dAb, 0.25)
            self:SetBackdropBorderColor(dAr, dAg, dAb, 0.50)
        end)
        applyBtn:SetScript("OnLeave", function(self)
            self:SetBackdropColor(dAr, dAg, dAb, 0.15)
            self:SetBackdropBorderColor(dAr, dAg, dAb, 0.30)
        end)
        applyBtn:SetScript("OnClick", function()
            if detailPanel._resultID then
                Panel.ApplyToGroup(detailPanel._resultID)
            end
        end)
        R.detail_applyBtn = applyBtn

        -- Info pills row (below title, before members) --------------------
        local PILL_Y = -38

        -- Leader pill
        local leaderPill = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
        leaderPill:SetHeight(22)
        leaderPill:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 10, PILL_Y)
        leaderPill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        leaderPill:SetBackdropColor(TC("surfaceBg"))
        leaderPill:SetBackdropBorderColor(0, 0, 0, 0)
        local lpDot = leaderPill:CreateTexture(nil, "OVERLAY", nil, 2)
        lpDot:SetSize(3, 14)
        lpDot:SetPoint("LEFT", leaderPill, "LEFT", 3, 0)
        lpDot:SetColorTexture(TC("accent"))
        local lpLabel = leaderPill:CreateFontString(nil, "OVERLAY")
        TrySetFont(lpLabel, BODY_FONT, 9, "OUTLINE")
        lpLabel:SetPoint("LEFT", lpDot, "RIGHT", 5, 0)
        lpLabel:SetTextColor(TC("mutedText"))
        lpLabel:SetText("LEADER")
        local lpValue = leaderPill:CreateFontString(nil, "OVERLAY")
        TrySetFont(lpValue, BODY_FONT, 10, "")
        lpValue:SetPoint("LEFT", lpLabel, "RIGHT", 6, 0)
        lpValue:SetTextColor(TC("bodyText"))
        leaderPill._value = lpValue
        R.detail_leaderPill = leaderPill

        -- Listed pill
        local listedPill = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
        listedPill:SetHeight(22)
        listedPill:SetPoint("LEFT", leaderPill, "RIGHT", 6, 0)
        listedPill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        listedPill:SetBackdropColor(TC("surfaceBg"))
        listedPill:SetBackdropBorderColor(0, 0, 0, 0)
        local ltDot = listedPill:CreateTexture(nil, "OVERLAY", nil, 2)
        ltDot:SetSize(3, 14)
        ltDot:SetPoint("LEFT", listedPill, "LEFT", 3, 0)
        ltDot:SetColorTexture(TC("accent"))
        local ltLabel = listedPill:CreateFontString(nil, "OVERLAY")
        TrySetFont(ltLabel, BODY_FONT, 9, "OUTLINE")
        ltLabel:SetPoint("LEFT", ltDot, "RIGHT", 5, 0)
        ltLabel:SetTextColor(TC("mutedText"))
        ltLabel:SetText("LISTED")
        local ltValue = listedPill:CreateFontString(nil, "OVERLAY")
        TrySetFont(ltValue, BODY_FONT, 10, "")
        ltValue:SetPoint("LEFT", ltLabel, "RIGHT", 6, 0)
        ltValue:SetTextColor(TC("bodyText"))
        listedPill._value = ltValue
        R.detail_listedPill = listedPill

        -- Voice pill (only shown when voice chat exists)
        local voicePill = CreateFrame("Frame", nil, detailPanel, "BackdropTemplate")
        voicePill:SetHeight(22)
        voicePill:SetPoint("LEFT", listedPill, "RIGHT", 6, 0)
        voicePill:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        voicePill:SetBackdropColor(TC("surfaceBg"))
        voicePill:SetBackdropBorderColor(0, 0, 0, 0)
        local vpDot = voicePill:CreateTexture(nil, "OVERLAY")
        vpDot:SetSize(3, 14)
        vpDot:SetPoint("LEFT", voicePill, "LEFT", 3, 0)
        if vpDot.SetColorTexture then
            pcall(vpDot.SetColorTexture, vpDot, 0.35, 0.88, 0.62, 0.8)
        end
        local vpLabel = voicePill:CreateFontString(nil, "OVERLAY")
        TrySetFont(vpLabel, BODY_FONT, 9, "OUTLINE")
        vpLabel:SetPoint("LEFT", vpDot, "RIGHT", 5, 0)
        vpLabel:SetTextColor(TC("mutedText"))
        vpLabel:SetText("VOICE")
        local vpValue = voicePill:CreateFontString(nil, "OVERLAY")
        TrySetFont(vpValue, BODY_FONT, 10, "")
        vpValue:SetPoint("LEFT", vpLabel, "RIGHT", 6, 0)
        vpValue:SetTextColor(TC("bodyText"))
        voicePill._value = vpValue
        voicePill:Hide()
        R.detail_voicePill = voicePill

        -- Keep compat ref (pills replace the old infoLine)
        R.detail_infoLine = nil

        -- 1px separator ----------------------------------------------------
        local sep = detailPanel:CreateTexture(nil, "ARTWORK")
        sep:SetHeight(1)
        sep:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 8, -72)
        sep:SetPoint("TOPRIGHT", detailPanel, "TOPRIGHT", -8, -72)
        sep:SetColorTexture(1, 1, 1, 0.08)

        -- "MEMBERS" header -------------------------------------------------
        local membersHeader = detailPanel:CreateFontString(nil, "OVERLAY")
        TrySetFont(membersHeader, BODY_FONT, 10, "OUTLINE")
        membersHeader:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 10, -80)
        membersHeader:SetTextColor(TC("mutedText"))
        membersHeader:SetText("MEMBERS")

        -- Scrollable member list (clips overflow, supports up to 40 members)
        -- Height is capped and dynamically resized in ShowGroupDetail
        local memberScroll = CreateFrame("Frame", nil, detailPanel)
        memberScroll:SetPoint("TOPLEFT", detailPanel, "TOPLEFT", 10, -96)
        memberScroll:SetPoint("RIGHT", detailPanel, "RIGHT", -10, 0)
        memberScroll:SetHeight(140) -- default, resized dynamically
        memberScroll:SetClipsChildren(true)
        memberScroll:EnableMouseWheel(true)
        R.detailMemberScroll = memberScroll

        local MEMBER_ROW_H = 28
        local MAX_DETAIL_MEMBERS = 40
        Panel._state.detailMemberScrollOffset = 0
        Panel._state.detailMemberCount = 0

        memberScroll:SetScript("OnMouseWheel", function(_, delta)
            local visibleRows = math.floor(memberScroll:GetHeight() / MEMBER_ROW_H)
            local maxOffset = math.max(0, Panel._state.detailMemberCount - visibleRows)
            Panel._state.detailMemberScrollOffset = math.max(0, math.min(
                Panel._state.detailMemberScrollOffset - delta, maxOffset))
            -- Re-populate rows with new data offset
            local offset = Panel._state.detailMemberScrollOffset
            local resultID = Panel._state._detailMemberResultID
            local info = Panel._state._detailMemberInfo
            if not resultID or not info then return end
            for mi, mRow in ipairs(R.detailMembers) do
                local dataIdx = mi + offset
                if dataIdx <= Panel._state.detailMemberCount then
                    local ok2, role, class, classLocal, specLocal = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, dataIdx)
                    if ok2 then
                        local memberName = ""
                        if specLocal and specLocal ~= "" and classLocal then
                            memberName = specLocal .. " " .. classLocal
                        elseif classLocal then
                            memberName = classLocal
                        end
                        mRow._nameText:SetText(memberName)
                        local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                        if cc then mRow._nameText:SetTextColor(cc.r, cc.g, cc.b)
                        else mRow._nameText:SetTextColor(TC("bodyText")) end
                        local roleLabel = role == "TANK" and "Tank" or role == "HEALER" and "Healer" or "DPS"
                        mRow._roleText:SetText("(" .. roleLabel .. ")")
                        mRow._mpiBg:SetColorTexture(0.5, 0.5, 0.5, 0.3)
                        mRow._mpiText:SetText("--")
                        mRow._bestText:SetText("")
                        mRow:Show()
                    else
                        mRow:Hide()
                    end
                else
                    mRow:Hide()
                end
            end
        end)

        -- Member rows (pool of visible rows)
        R.detailMembers = {}
        local memberPoolSize = math.min(MAX_DETAIL_MEMBERS, math.floor(200 / MEMBER_ROW_H) + 2)

        for mi = 1, memberPoolSize do
            local mRow = CreateFrame("Frame", nil, memberScroll)
            mRow:SetHeight(MEMBER_ROW_H)
            mRow:SetPoint("TOPLEFT", memberScroll, "TOPLEFT", 0, -((mi - 1) * MEMBER_ROW_H))
            mRow:SetPoint("RIGHT", memberScroll, "RIGHT", 0, 0)

            -- MPI score badge (32x18)
            local mpiBg = mRow:CreateTexture(nil, "BACKGROUND")
            mpiBg:SetSize(32, 18)
            mpiBg:SetPoint("LEFT", mRow, "LEFT", 0, 0)
            mpiBg:SetColorTexture(0.5, 0.5, 0.5, 0.3)
            mRow._mpiBg = mpiBg

            local mpiText = mRow:CreateFontString(nil, "OVERLAY")
            TrySetFont(mpiText, BODY_FONT, 9, "OUTLINE")
            mpiText:SetPoint("CENTER", mpiBg, "CENTER", 0, 0)
            mpiText:SetTextColor(1, 1, 1, 0.9)
            mpiText:SetText("--")
            mRow._mpiText = mpiText

            -- Name (class-colored)
            local nameText = mRow:CreateFontString(nil, "OVERLAY")
            TrySetFont(nameText, BODY_FONT, 11, "")
            nameText:SetPoint("LEFT", mpiBg, "RIGHT", 6, 0)
            nameText:SetTextColor(TC("bodyText"))
            mRow._nameText = nameText

            -- Role text
            local roleText = mRow:CreateFontString(nil, "OVERLAY")
            TrySetFont(roleText, BODY_FONT, 10, "")
            roleText:SetPoint("LEFT", nameText, "RIGHT", 4, 0)
            roleText:SetTextColor(TC("mutedText"))
            mRow._roleText = roleText

            -- Best run / raid progress (right-aligned)
            local bestText = mRow:CreateFontString(nil, "OVERLAY")
            TrySetFont(bestText, BODY_FONT, 10, "")
            bestText:SetPoint("RIGHT", mRow, "RIGHT", -4, 0)
            bestText:SetJustifyH("RIGHT")
            bestText:SetTextColor(TC("bodyText"))
            mRow._bestText = bestText

            mRow:Hide()
            R.detailMembers[mi] = mRow
        end
    end

    end -- end Premade Groups scope

    -- ---- Settings Popup (180x120, theme switcher) ----
    local settingsPopup = CreateFrame("Frame", nil, f, "BackdropTemplate")
    settingsPopup:SetSize(180, 120)
    settingsPopup:SetPoint("TOPRIGHT", R.gearBtn, "BOTTOMRIGHT", 0, -4)
    settingsPopup:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
        insets = { left = 1, right = 1, top = 1, bottom = 1 } })
    settingsPopup:SetBackdropColor(0.06, 0.06, 0.08, 0.95)
    settingsPopup:SetBackdropBorderColor(activeTheme.accent[1], activeTheme.accent[2], activeTheme.accent[3], 0.5)
    settingsPopup:SetFrameLevel(f:GetFrameLevel() + 20)
    settingsPopup:Hide()
    R.settingsPopup = settingsPopup

    local popupTitle = settingsPopup:CreateFontString(nil, "OVERLAY")
    TrySetFont(popupTitle, BODY_FONT, 10, "OUTLINE")
    popupTitle:SetPoint("TOP", settingsPopup, "TOP", 0, -8)
    popupTitle:SetText("Theme")
    popupTitle:SetTextColor(TC("mutedText"))

    local themeOptions = {
        { key = "parchment", label = "Warm Parchment" },
        { key = "midnight",  label = "Cool Midnight" },
        { key = "class",     label = "Class Color" },
    }
    for i, opt in ipairs(themeOptions) do
        local tBtn = CreateFrame("Button", nil, settingsPopup)
        tBtn:SetSize(160, 24)
        tBtn:SetPoint("TOP", settingsPopup, "TOP", 0, -24 - (i - 1) * 28)
        local tLbl = tBtn:CreateFontString(nil, "OVERLAY")
        TrySetFont(tLbl, BODY_FONT, 11, "")
        tLbl:SetPoint("CENTER")
        tLbl:SetText(opt.label)
        tLbl:SetTextColor(TC("bodyText"))
        tBtn:SetScript("OnClick", function()
            local s = _G.MidnightUISettings
            if s and s.General then s.General.characterPanelTheme = opt.key end
            Panel.ApplyTheme()
            settingsPopup:Hide()
        end)
        tBtn:SetScript("OnEnter", function() tLbl:SetTextColor(TC("titleText")) end)
        tBtn:SetScript("OnLeave", function() tLbl:SetTextColor(TC("bodyText")) end)
    end

    -- Mark initialized
    Panel._state.initialized = true
    return f
end

-- ============================================================================
-- S8  TAB SWITCHING
-- ============================================================================
function Panel.SetActiveTab(key)
    Panel.HideGroupDetail()
    Panel._state.activeTab = key
    local R = Panel._refs

    -- Map tab keys to content frames
    local contentMap = {
        dungeons = R.dungeonContent,
        raids    = R.raidContent,
        premade  = R.premadeContent,
        pvp      = R.pvpContent,
    }

    -- Update tab button visuals
    if R.tabs then
        for _, tab in ipairs(R.tabs) do
            if tab._key == key then
                tab._label:SetTextColor(TC("tabActive"))
                tab._underline:Show()
            else
                tab._label:SetTextColor(TC("tabInactive"))
                tab._underline:Hide()
            end
        end
    end

    -- Hide all content, show active
    for _, frame in pairs(contentMap) do
        if frame then frame:Hide() end
    end
    if contentMap[key] then
        contentMap[key]:Show()
    end

    -- Auto-refresh management
    if key == "premade" then
        StartAutoRefresh()
    else
        StopAutoRefresh()
    end

    -- When switching to premade, update sidebar & filter visibility
    -- NOTE: We do NOT auto-call DoSearch() here — C_LFGList.Search() is a protected
    -- API that taints when called from hooksecurefunc or C_Timer contexts. The user
    -- clicks the "Go" button to initiate the first search, or we show a prompt.
    if key == "premade" then
        Panel.UpdateCatButtons()
        Panel.UpdateFilterBarVisibility()
        Panel.UpdatePlayerSidebar()
        Panel.UpdatePremadeHero()
        -- Clear stale results from a different category and prompt for search
        if Panel._state._searchCategory ~= Panel._state.activeCategory then
            Panel._state.searchResults = {}
            Panel._state.scrollOffset = 0
            Panel.UpdateListingRows()
        end
        local R = Panel._refs
        if #Panel._state.searchResults == 0 then
            if R.emptyLabel then
                R.emptyLabel:SetText("Search For Groups")
                R.emptyLabel:Show()
            end
        end
    elseif key == "dungeons" then
        Panel.AutoDetectDungeonRoles()
        Panel.UpdateDungeonCards()
        Panel.UpdateDungeonQueueStatus()
        Panel.UpdateDungeonHero()
        Panel.UpdateDungeonSuggestions()
    elseif key == "raids" then
        Panel.AutoDetectRaidRoles()
        Panel.UpdateRaidFinder()
        Panel.UpdateRaidQueueStatus()
        Panel.UpdateRaidHero()
    elseif key == "pvp" then
        -- PVP queueing is fully protected in 12.0 — hand off to Blizzard's PVP UI
        Panel._state.activeTab = "premade"
        Panel._state._pvpHandoff = true
        Panel.Hide()
        C_Timer.After(0.2, function()
            for _, addon in ipairs({"Blizzard_PVEFrame", "Blizzard_PVPUI"}) do
                local isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) and C_AddOns.IsAddOnLoaded(addon) or (IsAddOnLoaded and IsAddOnLoaded(addon))
                if not isLoaded then
                    pcall((C_AddOns and C_AddOns.LoadAddOn) or LoadAddOn, addon)
                end
            end
            if PVEFrame then
                pcall(PVEFrame.Show, PVEFrame)
                if PVEFrame_ShowFrame then
                    pcall(PVEFrame_ShowFrame, "PVPUIFrame")
                end
            end
            C_Timer.After(0.3, function()
                Panel._state._pvpHandoff = false
            end)
        end)
        return
    end
end

-- ============================================================================
-- S8a  PVP TAB LOGIC
-- ============================================================================

local PVP_QUICKMATCH = {
    { name = "Random Battlegrounds",      isRandom = true, queueType = "random_bg" },
    { name = "Random Epic Battlegrounds", isRandom = true, queueType = "random_epic" },
    { name = "Arena Skirmish",            isSkirmish = true, queueType = "skirmish" },
    { name = "Brawl",                     isBrawl = true, queueType = "brawl", minLevel = 90 },
    { name = "Warsong Gulch",             teamSize = "10v10", queueType = "specific" },
    { name = "Arathi Basin",              teamSize = "15v15", queueType = "specific" },
    { name = "Deephaul Ravine",           teamSize = "10v10", queueType = "specific" },
    { name = "Alterac Valley",            teamSize = "40v40", queueType = "specific" },
    { name = "Eye of the Storm",          teamSize = "15v15", queueType = "specific" },
    { name = "Isle of Conquest",          teamSize = "40v40", queueType = "specific" },
    { name = "The Battle for Gilneas",    teamSize = "10v10", queueType = "specific" },
    { name = "Battle for Wintergrasp",    teamSize = "40v40", queueType = "specific" },
    { name = "Ashran",                    teamSize = "40v40", queueType = "specific" },
    { name = "Twin Peaks",               teamSize = "10v10", queueType = "specific" },
    { name = "Silvershard Mines",         teamSize = "10v10", queueType = "specific" },
    { name = "Temple of Kotmogu",         teamSize = "10v10", queueType = "specific" },
    { name = "Seething Shore",            teamSize = "10v10", queueType = "specific" },
    { name = "Deepwind Gorge",           teamSize = "15v15", queueType = "specific" },
}
local PVP_RATED = {
    { name = "Solo Shuffle (Arena)",         bracket = 7, queueType = "solo_arena" },
    { name = "Solo Shuffle (Battlegrounds)", bracket = 4, queueType = "solo_bg" },
    { name = "2v2 Arena",                    bracket = 1, queueType = "arena2v2" },
    { name = "3v3 Arena",                    bracket = 2, queueType = "arena3v3" },
    { name = "10v10 Rated Battlegrounds",    bracket = 3, queueType = "rated_bg" },
}
local PVP_TRAINING = {
    { name = "Random Training Battlegrounds",              isRandom = true, queueType = "training_random" },
    { name = "The Battle for Gilneas Training Grounds",    queueType = "training_gilneas" },
    { name = "Silvershard Mines Training Grounds",         queueType = "training_silvershard" },
    { name = "Arathi Basin Training Grounds",              queueType = "training_arathi" },
}

function Panel.AutoDetectPVPRoles()
    local ok, tank, healer, dps = pcall(GetLFGRoles)
    if ok then
        Panel._state.pvpRoles.tank = tank or false
        Panel._state.pvpRoles.healer = healer or false
        Panel._state.pvpRoles.dps = dps or false
    end
    local R = Panel._refs
    if R.pvpRoleBtns then
        local roleKeys = { "tank", "healer", "dps" }
        for i, btn in ipairs(R.pvpRoleBtns) do
            local active = Panel._state.pvpRoles[roleKeys[i]]
            btn._icon:SetDesaturated(not active)
            btn._icon:SetAlpha(active and 1.0 or 0.4)
        end
    end
end

function Panel.UpdatePVPCatButtons()
    local R = Panel._refs
    if not R.pvpCatButtons then return end
    local PVP_CAT_ACCENTS = {
        quickmatch = { 0.00, 0.78, 1.00 },
        rated      = { 1.00, 0.60, 0.00 },
        premade    = { 0.55, 0.55, 0.55 },
        training   = { 0.35, 0.75, 0.40 },
    }
    local PVP_CAT_KEYS = { "quickmatch", "rated", "premade", "training" }
    for i, btn in ipairs(R.pvpCatButtons) do
        local key = PVP_CAT_KEYS[i]
        local active = Panel._state.pvpCategory == key
        if active then
            local ac = PVP_CAT_ACCENTS[key] or {0.5, 0.5, 0.5}
            btn._bg:SetColorTexture(ac[1] * 0.15, ac[2] * 0.15, ac[3] * 0.15, 0.6)
            btn._accent:SetColorTexture(ac[1], ac[2], ac[3])
            btn._accent:Show()
            btn._label:SetTextColor(1, 1, 1)
        else
            btn._bg:SetColorTexture(TC("glassBg"))
            btn._accent:Hide()
            btn._label:SetTextColor(TC("bodyText"))
        end
    end

    -- Update queue button label based on category
    if R.pvpQueueBtn and R.pvpQueueBtn._label then
        local cat = Panel._state.pvpCategory
        if cat == "rated" then
            R.pvpQueueBtn._label:SetText("Queue Rated")
        elseif cat == "training" then
            R.pvpQueueBtn._label:SetText("Join Training")
        else
            R.pvpQueueBtn._label:SetText("Join Battle")
        end
    end
end

function Panel.UpdatePVPActivities()
    local R = Panel._refs
    if not R.pvpScrollChild then return end
    local cat = Panel._state.pvpCategory

    -- Clear existing cards
    for _, card in ipairs(R.pvpActivityCards or {}) do
        card:Hide()
        card:SetParent(nil)
    end
    R.pvpActivityCards = {}

    -- Select activity list
    local activities
    if cat == "quickmatch" then
        activities = PVP_QUICKMATCH
    elseif cat == "rated" then
        activities = PVP_RATED
    elseif cat == "training" then
        activities = PVP_TRAINING
    else
        -- Premade Groups — show a prompt to use the Premade tab
        local prompt = R.pvpScrollChild:CreateFontString(nil, "OVERLAY")
        TrySetFont(prompt, BODY_FONT, 11, "")
        prompt:SetPoint("TOP", R.pvpScrollChild, "TOP", 0, -40)
        prompt:SetTextColor(TC("mutedText"))
        prompt:SetText("Use the Premade Groups tab for PVP group listings.")
        R.pvpActivityCards[1] = prompt
        R.pvpScrollChild:SetHeight(100)
        return
    end

    -- Build cards
    local CARD_W = 280
    local CARD_H = 50
    local CARD_GAP = 6
    local COLS = 2
    local scrollW = R.pvpScrollChild:GetWidth()
    if scrollW and scrollW > 0 then
        CARD_W = math.floor((scrollW - CARD_GAP) / COLS)
    end

    for i, act in ipairs(activities) do
        local col = ((i - 1) % COLS)
        local row = math.floor((i - 1) / COLS)
        local xOff = col * (CARD_W + CARD_GAP)
        local yOff = -(row * (CARD_H + CARD_GAP))

        local card = CreateFrame("Button", nil, R.pvpScrollChild, "BackdropTemplate")
        card:SetSize(CARD_W, CARD_H)
        card:SetPoint("TOPLEFT", R.pvpScrollChild, "TOPLEFT", xOff, yOff)
        card:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1, insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        card:SetBackdropColor(0.06, 0.06, 0.08, 0.7)
        card:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)

        -- Activity name
        local nameFs = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(nameFs, TITLE_FONT, 10, "OUTLINE")
        nameFs:SetPoint("TOPLEFT", card, "TOPLEFT", 10, -8)
        nameFs:SetPoint("RIGHT", card, "RIGHT", -10, 0)
        nameFs:SetJustifyH("LEFT")
        nameFs:SetWordWrap(false)
        nameFs:SetTextColor(TC("bodyText"))

        local displayName = act.name
        if act.isBrawl then
            local brawlInfo = C_PvP and C_PvP.GetActiveBrawlInfo and SafeCall(C_PvP.GetActiveBrawlInfo)
            if brawlInfo and brawlInfo.name then
                displayName = "Brawl: " .. brawlInfo.name
            else
                displayName = "Brawl: Cooking: Impossible"
            end
        end
        nameFs:SetText(displayName)
        card._nameFs = nameFs

        -- Subtitle (team size or rating)
        local subFs = card:CreateFontString(nil, "OVERLAY")
        TrySetFont(subFs, BODY_FONT, 9, "")
        subFs:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 10, 6)
        subFs:SetTextColor(TC("mutedText"))

        if act.teamSize then
            subFs:SetText(act.teamSize)
        elseif act.isRandom then
            subFs:SetText("Random")
        elseif act.isSkirmish then
            subFs:SetText("Arena")
        elseif act.bracket then
            -- Show rating for rated activities
            local rating = 0
            if GetPersonalRatedInfo then
                local ok2, r = pcall(GetPersonalRatedInfo, act.bracket)
                if ok2 and r then rating = r end
            end
            if rating > 0 then
                subFs:SetText("Rating: " .. rating)
                subFs:SetTextColor(1.0, 0.80, 0.20)
            else
                subFs:SetText("--")
            end
        elseif act.isBrawl then
            local lvl = UnitLevel("player") or 0
            if lvl < (act.minLevel or 90) then
                subFs:SetText("Unlocks at Level " .. (act.minLevel or 90))
                subFs:SetTextColor(1.0, 0.3, 0.3)
                card:SetAlpha(0.5)
            else
                subFs:SetText("Weekly Brawl")
            end
        else
            subFs:SetText("")
        end
        card._subFs = subFs
        card._activity = act

        -- Selection state
        card:SetScript("OnClick", function(self)
            -- Deselect all
            for _, c in ipairs(R.pvpActivityCards) do
                if c.SetBackdropBorderColor then
                    c:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
                end
            end
            -- Select this one
            local ar, ag, ab = TC("accent")
            self:SetBackdropBorderColor(ar, ag, ab, 0.8)
            Panel._state.pvpSelectedActivity = self._activity
        end)
        card:SetScript("OnEnter", function(self)
            if Panel._state.pvpSelectedActivity ~= self._activity then
                self:SetBackdropBorderColor(0.3, 0.3, 0.4, 0.6)
            end
        end)
        card:SetScript("OnLeave", function(self)
            if Panel._state.pvpSelectedActivity ~= self._activity then
                self:SetBackdropBorderColor(0.2, 0.2, 0.25, 0.4)
            end
        end)

        R.pvpActivityCards[i] = card
    end

    -- Set scroll child height
    local totalRows = math.ceil(#activities / COLS)
    R.pvpScrollChild:SetHeight(math.max(1, totalRows * (CARD_H + CARD_GAP)))
end

function Panel.UpdatePVPQueueStatus()
    local R = Panel._refs
    if not R.pvpQueueBar then return end

    if not GetBattlefieldStatus then
        R.pvpQueueBar:Hide()
        return
    end

    for i = 1, 3 do
        local ok, status, mapName = pcall(GetBattlefieldStatus, i)
        if ok and status == "queued" then
            local waitTime = 0
            if GetBattlefieldTimeWaited then
                local ok2, t = pcall(GetBattlefieldTimeWaited, i)
                if ok2 and t then waitTime = t / 1000 end
            end
            R.pvpQueueText:SetText("Queued: " .. (mapName or "PVP") .. " — " .. math.floor(waitTime / 60) .. "m")
            R.pvpQueueBar:Show()
            return
        elseif ok and status == "confirm" then
            R.pvpQueueText:SetText((mapName or "PVP") .. " — READY!")
            R.pvpQueueText:SetTextColor(1.0, 0.85, 0.0)
            R.pvpQueueBar:Show()
            return
        end
    end
    R.pvpQueueBar:Hide()
end

function Panel.UpdatePVPRoleCards()
    Panel.UpdateRoleCards(Panel._refs.pvpRoleCards, Panel._state.pvpRoles, { 0.75, 0.30, 0.30 })
end

function Panel.UpdatePremadeRoleCards()
    Panel.UpdateRoleCards(Panel._refs.premadeRoleCards, Panel._state.applyRole)
end

function Panel.UpdatePVPHero()
    local R = Panel._refs

    PopulatePlayerIdentity(R.pvpHeroPlayerName, R.pvpHeroClassIcon, R.pvpHeroSpecLine)

    -- Season stats (context bar right)
    if R.pvpSeasonValue then
        local totalWins, totalLosses = 0, 0
        if GetPersonalRatedInfo then
            for _, bracket in ipairs({1, 2, 3, 4, 7}) do
                local ok, rating, seasonPlayed, seasonWon = pcall(GetPersonalRatedInfo, bracket)
                if ok and seasonPlayed then
                    totalWins = totalWins + (seasonWon or 0)
                    totalLosses = totalLosses + ((seasonPlayed or 0) - (seasonWon or 0))
                end
            end
        end
        R.pvpSeasonValue:SetText("SEASON: " .. totalWins .. "W - " .. totalLosses .. "L")
    end

    -- Honor level pill
    if R.pvpHonorValue then
        local honorLevel = UnitHonorLevel and UnitHonorLevel("player") or 0
        R.pvpHonorValue:SetText(tostring(honorLevel))
    end

    -- Highest rating across all brackets
    if R.pvpRatingValue then
        local bestRating, bestName = 0, "--"
        local bracketNames = { [1] = "2v2", [2] = "3v3", [3] = "RBG", [4] = "Solo BG", [7] = "Solo Shuffle" }
        if GetPersonalRatedInfo then
            for bracket, bName in pairs(bracketNames) do
                local ok, rating = pcall(GetPersonalRatedInfo, bracket)
                if ok and rating and rating > bestRating then
                    bestRating = rating
                    bestName = bName .. " " .. rating
                end
            end
        end
        if bestRating > 0 then
            R.pvpRatingValue:SetText(bestName)
            R.pvpRatingValue:SetTextColor(1.0, 0.80, 0.20)
        else
            R.pvpRatingValue:SetText("--")
            R.pvpRatingValue:SetTextColor(TC("mutedText"))
        end
    end

    -- Season stats
    if R.pvpSeasonValue then
        local totalWins, totalLosses = 0, 0
        if GetPersonalRatedInfo then
            for _, bracket in ipairs({1, 2, 3, 4, 7}) do
                local ok, rating, seasonPlayed, seasonWon = pcall(GetPersonalRatedInfo, bracket)
                if ok and seasonPlayed then
                    totalWins = totalWins + (seasonWon or 0)
                    totalLosses = totalLosses + ((seasonPlayed or 0) - (seasonWon or 0))
                end
            end
        end
        R.pvpSeasonValue:SetText(totalWins .. "W - " .. totalLosses .. "L")
    end

    -- Conquest progress bar
    if R.pvpConqTrack and R.pvpConqFill then
        local earned, cap = 0, 1
        if C_CurrencyInfo and C_CurrencyInfo.GetCurrencyInfo then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, 1602) -- Conquest currency ID
            if ok and info then
                earned = info.quantity or 0
                cap = info.maxQuantity or 1
                if cap <= 0 then cap = 1 end
            end
        end
        local trackW = R.pvpConqTrack:GetWidth()
        if trackW and trackW > 0 then
            R.pvpConqFill:SetWidth(math.max(1, trackW * math.min(1, earned / cap)))
        end
    end

    Panel.UpdatePVPRoleCards()
end

-- ============================================================================
-- S8b  PREMADE GROUPS LOGIC
-- ============================================================================

-- Update category sidebar button visuals (uses per-category accent colors)
function Panel.UpdateCatButtons()
    Panel.HideGroupDetail()
    local R = Panel._refs
    if not R.catButtons then return end
    local active = Panel._state.activeCategory
    for _, btn in ipairs(R.catButtons) do
        if btn._key == active then
            local catAc = CATEGORY_ACCENTS[btn._key] or {TC("accent")}
            btn._bg:SetTexture(W8)
            btn._bg:SetColorTexture(catAc[1], catAc[2], catAc[3], 0.08)
            btn._accentBar:Show()
            btn._label:SetTextColor(catAc[1], catAc[2], catAc[3])
        else
            local bgR, bgG, bgB, bgA = TC("glassBg")
            btn._bg:SetTexture(W8)
            if btn._bg.SetGradient and CreateColor then
                btn._bg:SetGradient("VERTICAL",
                    CreateColor(bgR, bgG, bgB, bgA),
                    CreateColor(bgR + 0.01, bgG + 0.01, bgB + 0.01, bgA))
            else
                btn._bg:SetColorTexture(TC("glassBg"))
            end
            btn._accentBar:Hide()
            btn._label:SetTextColor(TC("bodyText"))
        end
    end
    -- Also refresh the premade hero and sidebar for the new category
    Panel.UpdatePremadeHero()
    Panel.UpdateGroupIntelSidebar()
end

-- Show/hide filter bar based on active category
function Panel.UpdateFilterBarVisibility()
    local R = Panel._refs
    if not R.filterBar or not R.sortHeader then return end
    local showFilters = (Panel._state.activeCategory == "mythicplus")
    if showFilters then
        R.filterBar:Show()
        R.sortHeader:ClearAllPoints()
        R.sortHeader:SetPoint("TOPLEFT", R.filterBar, "BOTTOMLEFT", 0, 0)
        R.sortHeader:SetPoint("TOPRIGHT", R.filterBar, "BOTTOMRIGHT", 0, 0)
    else
        R.filterBar:Hide()
        R.sortHeader:ClearAllPoints()
        R.sortHeader:SetPoint("TOPLEFT", R.listingArea, "TOPLEFT", 0, 0)
        R.sortHeader:SetPoint("TOPRIGHT", R.listingArea, "TOPRIGHT", 0, 0)
    end
end

-- Search for groups
function Panel.DoSearch()
    local cat = nil
    for _, c in ipairs(CATEGORY_DEFS) do
        if c.key == Panel._state.activeCategory then cat = c; break end
    end
    if not cat then return end

    -- Show searching state
    local R = Panel._refs
    if R.searchingLabel then R.searchingLabel:Show() end
    if R.emptyLabel then R.emptyLabel:Hide() end
    if R.retryBtn then R.retryBtn:Hide() end
    Panel._state.searchResults = {}
    Panel._state.scrollOffset = 0
    Panel._state._searchStartTime = GetTime()
    Panel._state._searchCategory = cat.key
    Panel.UpdateListingRows()

    -- If this categoryID was recently searched (within 15s), re-process cached
    -- results instead of calling Search again. The WoW API sometimes silently
    -- drops Search events, and it coalesces duplicate calls for the same ID.
    -- Using cached results avoids both problems.
    local lastCatID = Panel._state._lastSearchCategoryID
    local lastTime = Panel._state._lastSearchTime or 0
    local lastGotResults = Panel._state._lastSearchGotResults
    if lastCatID == cat.categoryID and (GetTime() - lastTime) < 15 and lastGotResults then
        C_Timer.After(0, function() Panel.OnSearchResults() end)
        return
    end
    Panel._state._lastSearchCategoryID = cat.categoryID
    Panel._state._lastSearchTime = GetTime()
    Panel._state._lastSearchGotResults = false -- not yet received

    -- Call C_LFGList.Search with just the categoryID.
    -- IMPORTANT: Do NOT wrap in pcall (causes taint on this protected API).
    if C_LFGList.Search then
        C_LFGList.Search(cat.categoryID)
    end

    -- Safety timeout with generation counter — stale timeouts from previous
    -- searches are invalidated so they can't stomp valid results.
    -- Safety timeout: can't auto-retry because C_LFGList.Search is a protected
    -- API that taints when called from C_Timer context. Show "No groups found"
    -- and let the user click Go to retry manually.
    Panel._state._searchGeneration = (Panel._state._searchGeneration or 0) + 1
    local thisGeneration = Panel._state._searchGeneration
    C_Timer.After(8, function()
        if Panel._state._searchGeneration ~= thisGeneration then return end
        if R.searchingLabel and R.searchingLabel:IsShown() then
            R.searchingLabel:Hide()
            if #Panel._state.searchResults == 0 and R.emptyLabel then
                R.emptyLabel:SetText("No groups found.")
                R.emptyLabel:Show()
                if R.retryBtn then R.retryBtn:Show() end
            end
        end
    end)
end

-- Handle search results event
function Panel.OnSearchResults()
    local R = Panel._refs
    if R.searchingLabel then R.searchingLabel:Hide() end

    local results = {}
    local ok, numResults, resultList = pcall(function()
        return C_LFGList.GetSearchResults()
    end)

    if ok and resultList then
        local filters = Panel._state.filters
        for _, resultID in ipairs(resultList) do
            local infoOk, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
            if not infoOk or not info then
                -- skip
            elseif info.isDelisted then
                -- delisted, skip
            else
                local dominated = false
                local filterReason = nil

                -- F6: Freeform search text filter (matches group name + activity name)
                if not dominated and filters.searchText and filters.searchText ~= "" then
                    local searchLower = filters.searchText:lower()
                    local gName = (info.name or ""):lower()
                    local aName = (ResolveActivityName(info)):lower()
                    if not gName:find(searchLower, 1, true) and not aName:find(searchLower, 1, true) then
                        dominated = true
                    end
                end

                -- Dungeon name filter (match group name against selected dungeon)
                if not dominated and filters.dungeon and filters.dungeon ~= "" then
                    local groupName = (info.name or ""):lower()
                    local filterName = filters.dungeon:lower()
                    if not groupName:find(filterName, 1, true) then
                        dominated = true
                    end
                end

                -- Key level range filter (parse key level from group name)
                if not dominated and (filters.keyMin or filters.keyMax) then
                    local keyLevel = ExtractKeyLevel(info.name)
                    if keyLevel then
                        if filters.keyMin and keyLevel < filters.keyMin then dominated = true end
                        if filters.keyMax and keyLevel > filters.keyMax then dominated = true end
                    end
                end

                -- Min MPI filter
                if not dominated and filters.minMPI and filters.minMPI > 0 then
                    if info.leaderName then
                        local profile = GetCachedMPIProfile(info.leaderName)
                        if profile and (profile.avgMPI or 0) < filters.minMPI then
                            dominated = true
                        end
                        -- No profile → keep the result (don't penalize unknowns)
                    end
                end

                -- Raids vs Legacy: use activityIDs → GetActivityInfoTable → isCurrentRaidActivity
                if not dominated then
                    local activeCat = Panel._state.activeCategory
                    if activeCat == "raids" or activeCat == "legacy" then
                        local isCurrent = nil
                        local actIDs = info.activityIDs

                        local resolvedID = nil
                        if type(actIDs) == "number" and actIDs > 0 then
                            resolvedID = actIDs
                        elseif type(actIDs) == "table" and #actIDs > 0 then
                            resolvedID = actIDs[1]
                        end

                        if resolvedID and C_LFGList.GetActivityInfoTable then
                            local aOk, actInfo = pcall(C_LFGList.GetActivityInfoTable, resolvedID)
                            if aOk and actInfo then
                                -- Use isCurrentRaidActivity directly (confirmed in diagnostics)
                                if actInfo.isCurrentRaidActivity == true then
                                    isCurrent = true
                                elseif actInfo.isCurrentRaidActivity == false then
                                    isCurrent = false
                                end
                            end
                        end

                        if isCurrent ~= nil then
                            if activeCat == "raids" and not isCurrent then dominated = true end
                            if activeCat == "legacy" and isCurrent then dominated = true end
                        end
                    end
                end

                if not dominated then
                    info._resultID = resultID
                    results[#results + 1] = info
                else
                    -- filtered out
                end
            end -- else (not delisted)
        end -- for resultID
    end -- if ok and resultList

    Panel._state.searchResults = results
    Panel._state.scrollOffset = 0
    Panel._state._lastSearchGotResults = true
    Panel._state.lastSearchTime = GetTime()

    if #results == 0 then
        if R.emptyLabel then
            R.emptyLabel:SetText("No groups found.")
            R.emptyLabel:Show()
        end
        if R.retryBtn then R.retryBtn:Show() end
    else
        if R.emptyLabel then R.emptyLabel:Hide() end
        if R.retryBtn then R.retryBtn:Hide() end
    end

    if Panel._state.sortKey then Panel.SortResults() end
    Panel.UpdateListingRows()
    Panel.UpdateScrollBar()
    -- Update premade hero and group intel sidebar with new results
    if Panel._state.activeTab == "premade" then
        Panel.UpdatePremadeHero()
        Panel.UpdateGroupIntelSidebar()
    end

end

-- Compute role demand across all current search results
function Panel.ComputeRoleDemand()
    local demand = { tank = 0, healer = 0, dps = 0 }
    local results = Panel._state.searchResults or {}
    for _, info in ipairs(results) do
        local numMem = info.numMembers or 0
        local maxMem = info.maxMembers
        if not maxMem or maxMem <= 0 then
            local actIDs = info.activityIDs
            local resolvedID = type(actIDs) == "number" and actIDs or (type(actIDs) == "table" and actIDs[1])
            if resolvedID and C_LFGList.GetActivityInfoTable then
                local aOk, aInfo = pcall(C_LFGList.GetActivityInfoTable, resolvedID)
                if aOk and aInfo and aInfo.maxNumPlayers and aInfo.maxNumPlayers > 0 then
                    maxMem = aInfo.maxNumPlayers
                end
            end
        end
        if not maxMem or maxMem <= 0 then maxMem = 5 end
        -- Count filled roles in this group
        local filled = { TANK = 0, HEALER = 0, DAMAGER = 0 }
        for mi = 1, numMem do
            local ok, mRole = pcall(C_LFGList.GetSearchResultMemberInfo, info._resultID, mi)
            if ok and mRole then
                filled[mRole] = (filled[mRole] or 0) + 1
            end
        end
        -- For M+ groups (5-man): need 1 tank, 1 healer, 3 DPS
        -- For raids: approximate based on maxMembers
        if maxMem <= 5 then
            demand.tank = demand.tank + math.max(0, 1 - filled.TANK)
            demand.healer = demand.healer + math.max(0, 1 - filled.HEALER)
            demand.dps = demand.dps + math.max(0, 3 - filled.DAMAGER)
        else
            -- Raid: ~2 tanks, ~4-5 healers, rest DPS per 20-man
            local needTanks = math.max(0, 2 - filled.TANK)
            local needHealers = math.max(0, math.ceil(maxMem * 0.2) - filled.HEALER)
            local needDPS = math.max(0, (maxMem - 2 - math.ceil(maxMem * 0.2)) - filled.DAMAGER)
            demand.tank = demand.tank + needTanks
            demand.healer = demand.healer + needHealers
            demand.dps = demand.dps + needDPS
        end
    end
    return demand
end

-- Get pending applications and their statuses
function Panel.GetPendingApplications()
    local apps = {}
    if not C_LFGList or not C_LFGList.GetApplications then return apps end
    local ok, appList = pcall(C_LFGList.GetApplications)
    if not ok or not appList then return apps end
    for _, resultID in ipairs(appList) do
        local aOk, _, appStatus = pcall(C_LFGList.GetApplicationInfo, resultID)
        -- Only show active applications (not cancelled, expired, declined, etc.)
        local hideStatuses = { none=true, cancelled=true, timedout=true, declined=true,
            declined_full=true, declined_delisted=true, failed=true }
        if aOk and appStatus and not hideStatuses[appStatus] then
            local iOk, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
            local groupName = (iOk and info and info.name) or "Unknown Group"
            apps[#apps + 1] = {
                name = groupName,
                status = appStatus,
                resultID = resultID,
            }
        end
    end
    return apps
end

-- Update the Leader MPI card + Group Context when a listing is selected
function Panel.UpdateMPIScoreCard(resultID)
    local R = Panel._refs
    if not R.intel_mpiPanel then return end

    local function ShowEmpty()
        if R.intel_mpiEmpty then R.intel_mpiEmpty:Show() end
        if R.mpi_classIcon then R.mpi_classIcon:Hide() end
        if R.mpi_classInitial then R.mpi_classInitial:Hide() end
        if R.mpi_cardName then R.mpi_cardName:Hide() end
        if R.mpi_cardRealm then R.mpi_cardRealm:Hide() end
        if R.mpi_cardClass then R.mpi_cardClass:Hide() end
        if R.mpi_cardRole then R.mpi_cardRole:Hide() end
        if R.mpi_cardScore then R.mpi_cardScore:Hide() end
        if R.mpi_tierBadge then R.mpi_tierBadge:Hide() end
        if R.mpi_trendIcon then R.mpi_trendIcon:Hide() end
        if R.mpi_cardDiv then R.mpi_cardDiv:Hide() end
        if R.mpi_badgeDiv then R.mpi_badgeDiv:Hide() end
        if R.mpi_badgeLabel then R.mpi_badgeLabel:Hide() end
        if R.mpi_dimRows then
            for _, dr in ipairs(R.mpi_dimRows) do
                dr.label:Hide(); dr.value:Hide(); dr.track:Hide(); dr.fill:Hide()
            end
        end
        if R.mpi_badgeSlots then
            for _, s in ipairs(R.mpi_badgeSlots) do s:Hide() end
        end
    end

    local function ShowContent()
        if R.intel_mpiEmpty then R.intel_mpiEmpty:Hide() end
        if R.mpi_classIcon then R.mpi_classIcon:Show() end
        if R.mpi_classInitial then R.mpi_classInitial:Show() end
        if R.mpi_cardName then R.mpi_cardName:Show() end
        if R.mpi_cardRealm then R.mpi_cardRealm:Show() end
        if R.mpi_cardClass then R.mpi_cardClass:Show() end
        if R.mpi_cardRole then R.mpi_cardRole:Show() end
        if R.mpi_cardScore then R.mpi_cardScore:Show() end
        if R.mpi_tierBadge then R.mpi_tierBadge:Show() end
        if R.mpi_trendIcon then R.mpi_trendIcon:Show() end
        if R.mpi_cardDiv then R.mpi_cardDiv:Show() end
        if R.mpi_badgeDiv then R.mpi_badgeDiv:Show() end
        if R.mpi_badgeLabel then R.mpi_badgeLabel:Show() end
        if R.mpi_dimRows then
            for _, dr in ipairs(R.mpi_dimRows) do
                dr.label:Show(); dr.value:Show(); dr.track:Show(); dr.fill:Show()
            end
        end
    end

    -- Also hide/show the context panel
    if R.intel_ctxPanel then R.intel_ctxPanel:Hide() end

    if not resultID then ShowEmpty(); return end

    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not ok or not info then ShowEmpty(); return end

    -- Always use leader (member 1) — WoW API only exposes the leader's name
    -- GetSearchResultMemberInfo returns: role, class, classLocal, specLocal (NO name)
    local mOk, mRole, mClass, mClassLocal, mSpecLocal
    if C_LFGList.GetSearchResultMemberInfo then
        mOk, mRole, mClass, mClassLocal, mSpecLocal = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, 1)
    end
    if not mOk then ShowEmpty(); return end
    local mName = info.leaderName or ""

    -- Parse name and realm
    local shortName = mName or ""
    local realm = ""
    if mName and mName:find("-") then
        shortName = mName:match("^([^%-]+)")
        realm = mName:match("%-(.+)$") or ""
    end

    -- Fallback: if leaderName is empty, use spec or class as display name
    if shortName == "" then
        shortName = mSpecLocal or mClassLocal or mClass or ""
    end

    -- Class color lookup
    local cc = mClass and RAID_CLASS_COLORS and RAID_CLASS_COLORS[mClass]
    local cr, cg, cb = 0.6, 0.6, 0.6
    if cc then cr, cg, cb = cc.r, cc.g, cc.b end

    -- MPI profile lookup
    local profile = nil
    if _G.MidnightPI and _G.MidnightPI.GetProfileByName and mName and mName ~= "" then
        profile = _G.MidnightPI.GetProfileByName(mName)
    end

    -- Always show the player header (comes from LFG API, not MPI)
    ShowContent()
    local className = mClassLocal or mClass or ""
    local specLabel = mSpecLocal or ""
    local classLine = (specLabel ~= "" and specLabel ~= className) and (specLabel .. " " .. className) or className
    R.mpi_classIcon:SetColorTexture(cr, cg, cb, 0.8)
    R.mpi_classInitial:SetText(className:sub(1, 1) or "?")
    R.mpi_cardName:SetText(shortName)
    R.mpi_cardName:SetTextColor(cr, cg, cb)
    R.mpi_cardRealm:SetText(realm)
    R.mpi_cardClass:SetText(classLine)
    R.mpi_cardClass:SetTextColor(cr, cg, cb)
    local roleLabel = mRole == "TANK" and "TANK" or mRole == "HEALER" and "HEALER" or "DPS"
    R.mpi_cardRole:SetText(roleLabel)

    -- ── No MPI profile: show "not yet scored" state ──
    if not profile or not profile.avgMPI or profile.avgMPI == 0 then
        R.mpi_cardScore:SetText("--")
        R.mpi_cardScore:SetTextColor(0.35, 0.35, 0.40)
        R.mpi_tierText:SetText("?")
        R.mpi_tierText:SetTextColor(0.35, 0.35, 0.40)
        R.mpi_tierBadge:SetBackdropBorderColor(0.25, 0.25, 0.30, 0.6)
        R.mpi_trendIcon:SetText("")

        -- Hide dimension bars and badges, show no-data message
        if R.mpi_dimRows then
            for _, dr in ipairs(R.mpi_dimRows) do
                dr.label:Hide(); dr.value:Hide(); dr.track:Hide(); dr.fill:Hide()
            end
        end
        if R.mpi_badgeDiv then R.mpi_badgeDiv:Hide() end
        if R.mpi_badgeLabel then R.mpi_badgeLabel:Hide() end
        if R.mpi_badgeSlots then
            for _, s in ipairs(R.mpi_badgeSlots) do s:Hide() end
        end
        if R.mpi_noDataMsg then R.mpi_noDataMsg:Show() end
        Panel.UpdateGroupContext(resultID, info, profile)
        return
    end

    -- ── Has MPI profile: show full score card ──
    if R.mpi_noDataMsg then R.mpi_noDataMsg:Hide() end

    local score = profile.avgMPI
    local tierLabel, tr, tg, tb = "D", 1.0, 0.35, 0.35
    if _G.MidnightPI and _G.MidnightPI.GetScoreTier then
        tierLabel, tr, tg, tb = _G.MidnightPI.GetScoreTier(score)
    end

    R.mpi_cardScore:SetText(tostring(score))
    R.mpi_cardScore:SetTextColor(tr, tg, tb)
    R.mpi_tierText:SetText(tierLabel)
    R.mpi_tierText:SetTextColor(tr, tg, tb)
    R.mpi_tierBadge:SetBackdropBorderColor(tr, tg, tb, 0.6)

    -- Trend
    if profile.trend == "up" then
        R.mpi_trendIcon:SetText("|cff59e073\226\150\178 Trending Up|r")
    elseif profile.trend == "down" then
        R.mpi_trendIcon:SetText("|cffff5959\226\150\188 Trending Down|r")
    else
        R.mpi_trendIcon:SetText("")
    end

    -- Dimension bars
    local DIM_KEYS = { "awarenessScore", "survivalScore", "outputScore", "utilityScore", "consistencyScore" }
    for i, key in ipairs(DIM_KEYS) do
        local dr = R.mpi_dimRows[i]
        if dr then
            local val = profile[key] or 0
            val = math.floor(val + 0.5)
            local _, dr_r, dg, db2 = "D", 1.0, 0.35, 0.35
            if _G.MidnightPI and _G.MidnightPI.GetScoreTier then
                _, dr_r, dg, db2 = _G.MidnightPI.GetScoreTier(val)
            end
            dr.label:Show(); dr.value:Show(); dr.track:Show(); dr.fill:Show()
            dr.value:SetText(tostring(val))
            dr.value:SetTextColor(dr_r, dg, db2)
            dr.fill:SetColorTexture(dr_r, dg, db2, 0.8)
            local trackW = dr.track:GetWidth()
            if trackW and trackW > 0 then
                dr.fill:SetWidth(math.max(1, trackW * val / 100))
            else
                dr.fill:SetWidth(math.max(1, val))
            end
        end
    end

    -- Badges
    if R.mpi_badgeDiv then R.mpi_badgeDiv:Show() end
    if R.mpi_badgeLabel then R.mpi_badgeLabel:Show() end
    local badges = profile.badges or {}
    for bi = 1, 6 do
        local slot = R.mpi_badgeSlots[bi]
        if slot then
            if badges[bi] then
                slot:SetText(badges[bi])
                slot:Show()
            else
                slot:Hide()
            end
        end
    end

    Panel.UpdateGroupContext(resultID, info, profile)
end

-- Update the Group Context panel (listed age, your fit, leader info)
function Panel.UpdateGroupContext(resultID, info, profile)
    local R = Panel._refs
    if not R.intel_ctxPanel then return end

    -- Listed age
    local ageMin = info.age and math.floor(info.age / 60) or 0
    local ageText
    if ageMin > 10 then
        ageText = "Listed |cffcc6600" .. ageMin .. " min ago|r"
    elseif ageMin > 5 then
        ageText = "Listed |cffffff00" .. ageMin .. " min ago|r"
    elseif ageMin >= 1 then
        ageText = "Listed |cff00cc00" .. ageMin .. " min ago|r"
    else
        ageText = "|cff00cc00Just listed|r"
    end
    R.intel_ctxAge:SetText(ageText)

    -- Your fit assessment
    local fitLines = {}
    local mplusData = GetPlayerMPlusData()
    local groupName = info.name or ""
    local keyLevel = ExtractKeyLevel(groupName)

    local dungeonMapID = nil
    for _, dung in ipairs(Panel._dungeonData or {}) do
        if groupName:lower():find(dung.name:lower(), 1, true) or (dung.abbr and groupName:lower():find(dung.abbr:lower(), 1, true)) then
            dungeonMapID = dung.mapID
            break
        end
    end

    if keyLevel then
        table.insert(fitLines, "+" .. keyLevel .. " key")
    end
    if dungeonMapID and mplusData.dungeonBest then
        local yourBest = mplusData.dungeonBest[dungeonMapID]
        if yourBest and yourBest > 0 then
            table.insert(fitLines, "Your best: +" .. yourBest)
            if keyLevel then
                if yourBest >= keyLevel then
                    table.insert(fitLines, "|cff00cc00Comfort Zone|r")
                elseif yourBest >= keyLevel - 3 then
                    table.insert(fitLines, "|cffffff00Stretch Key|r")
                else
                    table.insert(fitLines, "|cffcc0000Reach Key|r")
                end
            end
        else
            table.insert(fitLines, "|cff00ccffNew dungeon for you|r")
        end
    elseif keyLevel and mplusData.overallScore then
        table.insert(fitLines, "M+ Score: " .. FormatNumber(mplusData.overallScore))
    end
    R.intel_ctxFit:SetText(#fitLines > 0 and table.concat(fitLines, "  |  ") or "")

    -- Leader completion info (from MPI profile if available)
    if profile and profile.runsTracked and profile.runsTracked > 0 then
        local completed = profile.runsTracked - (profile.abandonedRuns or 0)
        local completionPct = math.floor(completed / profile.runsTracked * 100)
        local completionColor = completionPct >= 90 and "|cff00cc00" or completionPct >= 70 and "|cffffff00" or "|cffcc0000"
        R.intel_ctxLeaderInfo:SetText("Leader: " .. profile.runsTracked .. " runs, " .. completionColor .. completionPct .. "% completion|r")
    else
        R.intel_ctxLeaderInfo:SetText("")
    end

    -- Resize panel based on content
    local h = 28
    if R.intel_ctxAge:GetText() ~= "" then h = h + 14 end
    if R.intel_ctxFit:GetText() ~= "" then h = h + 14 end
    if R.intel_ctxLeaderInfo:GetText() ~= "" then h = h + 14 end
    R.intel_ctxPanel:SetHeight(math.max(60, h + 8))
    R.intel_ctxPanel:Show()
end

-- Update the group intel sidebar (application tracker)
function Panel.UpdateGroupIntelSidebar()
    local R = Panel._refs
    if not R.playerSidebar then return end

    -- Auto-select current spec role on sidebar (only if no role is currently selected)
    if R.applyRoleBtns and Panel._state.applyRole then
        local anySelected = Panel._state.applyRole.tank or Panel._state.applyRole.healer or Panel._state.applyRole.dps
        if not anySelected then
            local spec = GetSpecialization and GetSpecialization()
            local specRole = nil
            if spec then
                local ok, _, _, _, role = pcall(GetSpecializationInfo, spec)
                if ok and role then specRole = role end
            end
            local roleMap = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }
            local autoKey = roleMap[specRole] or "dps"
            Panel._state.applyRole[autoKey] = true
            Panel.UpdatePremadeRoleCards()
        end
    end

    -- Application tracker (flyout cards)
    if R.intel_appRows then
        local apps = Panel.GetPendingApplications()
        local hasApps = #apps > 0

        if R.intel_appEmpty then
            R.intel_appEmpty:SetShown(not hasApps)
        end

        -- Update trigger label with count
        if R.intel_appHeader then
            R.intel_appHeader:SetText("MY APPLICATIONS (" .. #apps .. "/5)")
        end

        -- Status colors and labels
        local statusInfo = {
            applied           = { color = { TC("accent") },            label = "Pending" },
            invited           = { color = { 0.35, 0.88, 0.62 },       label = "Invited!" },
            declined          = { color = { 1.0, 0.4, 0.4 },          label = "Declined" },
            declined_full     = { color = { 1.0, 0.4, 0.4 },          label = "Group Full" },
            declined_delisted = { color = { 0.6, 0.6, 0.6 },          label = "Delisted" },
            timedout          = { color = { 0.6, 0.6, 0.6 },          label = "Expired" },
            cancelled         = { color = { 0.6, 0.6, 0.6 },          label = "Cancelled" },
            failed            = { color = { 1.0, 0.4, 0.4 },          label = "Failed" },
        }

        local visibleCount = 0
        for i, card in ipairs(R.intel_appRows) do
            local app = apps[i]
            if app then
                card._name:SetText(app.name)
                local si = statusInfo[app.status]
                local statusLabel = si and si.label or (app.status:sub(1,1):upper() .. app.status:sub(2)):gsub("_", " ")
                local statusColor = si and si.color or { TC("mutedText") }
                card._status:SetText(statusLabel)
                card._status:SetTextColor(statusColor[1], statusColor[2], statusColor[3])
                card._statusBar:SetColorTexture(statusColor[1], statusColor[2], statusColor[3], 0.8)
                card._cancelBtn._resultID = app.resultID
                local canCancel = (app.status == "applied" or app.status == "invited")
                card._cancelBtn:SetShown(canCancel)
                card:Show()
                visibleCount = visibleCount + 1
            else
                card:Hide()
            end
        end

        -- Resize flyout to fit content
        if R.intel_appFlyout then
            local APP_CARD_H = 40
            local APP_CARD_GAP = 4
            if hasApps then
                local flyH = 28 + visibleCount * (APP_CARD_H + APP_CARD_GAP) + 8
                R.intel_appFlyout:SetHeight(math.max(60, flyH))
            else
                R.intel_appFlyout:SetHeight(60)
            end
        end
    end

    -- MPI: Hide Team MPI panel in Group Finder (API does not expose player
    -- names for non-leader members, so MPI lookups cannot work here)
    if _G.MidnightPI and _G.MidnightPI.UpdateSidebarTeamMPI then _G.MidnightPI.UpdateSidebarTeamMPI(R.playerSidebar, nil) end
end

-- Keep UpdatePlayerSidebar as an alias for backwards compatibility
function Panel.UpdatePlayerSidebar()
    Panel.UpdateGroupIntelSidebar()
end

-- UpdateStaleBanner stub (removed — no longer displayed)
function Panel.UpdateStaleBanner() end

-- F4: Sort search results client-side
function Panel.SortResults()
    local key = Panel._state.sortKey
    local asc = Panel._state.sortAsc
    if not key then return end
    local results = Panel._state.searchResults
    if not results or #results == 0 then return end
    table.sort(results, function(a, b)
        local va, vb
        if key == "group" then
            va = (ResolveActivityName(a)):lower()
            vb = (ResolveActivityName(b)):lower()
        elseif key == "level" then
            va = ExtractKeyLevel(a.name) or 0
            vb = ExtractKeyLevel(b.name) or 0
        elseif key == "members" then
            va = a.numMembers or 0
            vb = b.numMembers or 0
        elseif key == "listed" then
            va = a.age or 9999
            vb = b.age or 9999
        else
            return false
        end
        if va == vb then return false end
        if asc then return va < vb else return va > vb end
    end)
    Panel._state.scrollOffset = 0
    Panel.UpdateListingRows()
    Panel.UpdateScrollBar()
end

function Panel.UpdateScrollBar()
    local R = Panel._refs
    if not R.scrollTrack or not R.scrollThumb then return end
    local totalResults = #(Panel._state.searchResults or {})
    if totalResults <= CFG.ROW_POOL_SIZE then
        R.scrollTrack:Hide()
        R.scrollThumb:Hide()
        return
    end
    R.scrollTrack:Show()
    R.scrollThumb:Show()
    local trackH = R.scrollTrack:GetHeight()
    if trackH <= 0 then return end
    local maxOffset = totalResults - CFG.ROW_POOL_SIZE
    local thumbH = math.max(20, trackH * (CFG.ROW_POOL_SIZE / totalResults))
    local thumbOffset = (Panel._state.scrollOffset / maxOffset) * (trackH - thumbH)
    R.scrollThumb:SetHeight(thumbH)
    R.scrollThumb:ClearAllPoints()
    R.scrollThumb:SetPoint("TOPRIGHT", R.scrollTrack, "TOPRIGHT", 0, -thumbOffset)
end

-- Update visible listing rows based on scroll offset and search results
function Panel.UpdateListingRows()
    local R = Panel._refs
    if not R.rowPool then return end
    local results = Panel._state.searchResults
    local offset = Panel._state.scrollOffset

    for i = 1, CFG.ROW_POOL_SIZE do
        local row = R.rowPool[i]
        local dataIdx = offset + i
        if dataIdx <= #results then
            local info = results[dataIdx]
            row._resultID = info._resultID

            -- MPI score
            local mpiProfile = info.leaderName and GetCachedMPIProfile(info.leaderName)
            if mpiProfile and mpiProfile.avgMPI then
                local sr, sg, sb = GetMPIScoreColor(mpiProfile.avgMPI)
                row._mpiBadge._bg:SetColorTexture(sr, sg, sb, 0.3)
                row._mpiBadge._text:SetText(tostring(mpiProfile.avgMPI))
            else
                row._mpiBadge._bg:SetColorTexture(0.5, 0.5, 0.5, 0.18)
                row._mpiBadge._text:SetText("--")
            end

            -- F2: TOP LINE — Activity name (always resolved) + key level badge
            local actName = ResolveActivityName(info)
            row._activityName:SetText(actName)

            local keyLevel = ExtractKeyLevel(info.name)
            if keyLevel then
                row._keyBadge:SetText("+" .. keyLevel)
            else
                row._keyBadge:SetText("")
            end

            -- Tooltip data (raw group title + comment)
            row._tooltipTitle = info.name or ""
            row._tooltipComment = info.comment or ""

            -- BOTTOM LINE — Leader class icon + name
            local ok2, mRole, mClass = pcall(C_LFGList.GetSearchResultMemberInfo, info._resultID, 1)
            if row._leaderClassIcon then
                if ok2 and mClass and CLASS_ICON_TCOORDS then
                    local coords = CLASS_ICON_TCOORDS[mClass]
                    row._leaderClassIcon:SetTexture("Interface\\GLUES\\CHARACTERCREATE\\UI-CharacterCreate-Classes")
                    if coords then
                        row._leaderClassIcon:SetTexCoord(coords[1], coords[2], coords[3], coords[4])
                    end
                    row._leaderClassIcon:Show()
                else
                    row._leaderClassIcon:Hide()
                end
            end

            -- Leader name (bottom line)
            if row._leaderName then
                if info.leaderName then
                    local shortName = info.leaderName:match("^([^-]+)") or info.leaderName
                    row._leaderName:SetText(shortName)
                    local leaderCC = (ok2 and mClass) and RAID_CLASS_COLORS and RAID_CLASS_COLORS[mClass] or nil
                    if leaderCC then
                        row._leaderName:SetTextColor(leaderCC.r, leaderCC.g, leaderCC.b)
                    else
                        row._leaderName:SetTextColor(TC("mutedText"))
                    end
                else
                    row._leaderName:SetText("")
                end
            end

            -- Member count (bottom line)
            local maxMem = info.maxMembers
            if not maxMem or maxMem == 0 then
                local actIDs = info.activityIDs
                local resolvedID = type(actIDs) == "number" and actIDs or (type(actIDs) == "table" and actIDs[1])
                if resolvedID and C_LFGList.GetActivityInfoTable then
                    local aOk, aInfo = pcall(C_LFGList.GetActivityInfoTable, resolvedID)
                    if aOk and aInfo and aInfo.maxNumPlayers and aInfo.maxNumPlayers > 0 then
                        maxMem = aInfo.maxNumPlayers
                    end
                end
            end
            if not maxMem or maxMem <= 0 then
                if Panel._state.activeCategory == "custom" then maxMem = nil else maxMem = 5 end
            end
            if maxMem then
                row._countText:SetText((info.numMembers or 0) .. "/" .. maxMem)
            else
                row._countText:SetText(tostring(info.numMembers or 0))
            end

            -- Time listed (bottom line)
            if row._listedText then
                row._listedText:SetText(FormatTimeAgo(info.age))
            end

            -- F5: Role icons with count bubbles
            if row._roleIcons then
                local roleCountData = { TANK = 0, HEALER = 0, DAMAGER = 0 }
                local numMem = info.numMembers or 0
                for mi = 1, numMem do
                    local mOk, mR = pcall(C_LFGList.GetSearchResultMemberInfo, info._resultID, mi)
                    if mOk and mR then roleCountData[mR] = (roleCountData[mR] or 0) + 1 end
                end
                local ROLE_KEYS = { "TANK", "HEALER", "DAMAGER" }
                for ri, iconFrame in ipairs(row._roleIcons) do
                    local rKey = ROLE_KEYS[ri]
                    local count = roleCountData[rKey] or 0
                    local tex = iconFrame._tex
                    if count > 0 then
                        if tex then tex:SetDesaturated(false); tex:SetAlpha(1.0) end
                    else
                        if tex then tex:SetDesaturated(true); tex:SetAlpha(0.3) end
                    end
                    -- Count bubble
                    if row._roleBubbles and row._roleBubbles[ri] then
                        local bubble = row._roleBubbles[ri]
                        if count > 0 then
                            bubble._text:SetText(tostring(count))
                            bubble:Show()
                        else
                            bubble:Hide()
                        end
                    end
                end

            end

            -- Apply button state
            row._applyBtn._resultID = info._resultID
            local appOk, _, appStatus = pcall(C_LFGList.GetApplicationInfo, info._resultID)
            local disableApply = false
            local applyLabelText = "Apply"
            if appOk and appStatus and appStatus ~= "none" then
                disableApply = true
                if appStatus == "applied" then applyLabelText = "Pending"
                elseif appStatus == "invited" then applyLabelText = "Invited"
                elseif appStatus == "declined" or appStatus == "declined_full" or appStatus == "declined_delisted" then applyLabelText = "Declined"
                elseif appStatus == "cancelled" then applyLabelText = "Cancelled"
                elseif appStatus == "timedout" then applyLabelText = "Expired"
                elseif appStatus == "failed" then applyLabelText = "Failed"
                end
            end
            if row._applyBtn._label then row._applyBtn._label:SetText(applyLabelText) end
            row._applyBtn:SetAlpha(disableApply and 0.35 or 1.0)
            row._applyBtn:EnableMouse(not disableApply)

            -- MPI: Row performance dot
            if _G.MidnightPI and _G.MidnightPI.UpdateListingRowMPI then _G.MidnightPI.UpdateListingRowMPI(row, info) end

            row:Show()
        else
            row:Hide()
        end
    end
end

-- Show the group detail overlay panel
function Panel.ShowGroupDetail(resultID)
    local R = Panel._refs
    if not R.detailPanel then return end

    Panel._state.selectedResult = resultID
    Panel._state.detailOpen = true

    -- Update Leader MPI card + Group Context
    Panel.UpdateMPIScoreCard(resultID)

    -- Get group info
    local ok, info = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not ok or not info then return end

    -- Update header — center title vertically when no comment
    R.detail_groupName:SetText(info.name or "")
    local hasComment = info.comment and info.comment ~= ""
    if hasComment then
        R.detail_comment:SetText(info.comment)
        R.detail_comment:Show()
        -- Title at top, comment below
        R.detail_groupName:ClearAllPoints()
        R.detail_groupName:SetPoint("TOPLEFT", R.detail_groupName:GetParent(), "TOPLEFT", 0, -4)
        R.detail_groupName:SetPoint("RIGHT", R.detail_groupName:GetParent(), "RIGHT", 0, 0)
    else
        R.detail_comment:SetText("")
        R.detail_comment:Hide()
        -- No comment: center title vertically in the title block
        R.detail_groupName:ClearAllPoints()
        R.detail_groupName:SetPoint("LEFT", R.detail_groupName:GetParent(), "LEFT", 0, 0)
        R.detail_groupName:SetPoint("RIGHT", R.detail_groupName:GetParent(), "RIGHT", 0, 0)
    end

    -- Leader pill
    if R.detail_leaderPill then
        local leaderStr = info.leaderName or ""
        if leaderStr == "" then
            -- Fall back to class name from member info
            local mOk, _, mClass, mClassLocal = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, 1)
            if mOk and mClassLocal then leaderStr = mClassLocal end
        end
        R.detail_leaderPill._value:SetText(leaderStr)
        -- Auto-size pill width
        local pillW = 3 + 5 + (R.detail_leaderPill._value:GetStringWidth() or 40) + 50
        R.detail_leaderPill:SetWidth(math.max(80, math.min(200, pillW)))
    end

    -- Listed pill
    if R.detail_listedPill then
        local listedStr = ""
        if info.age then
            local mins = math.floor(info.age / 60)
            listedStr = (mins < 1) and "just now" or (mins .. " min ago")
        end
        R.detail_listedPill._value:SetText(listedStr)
        local pillW = 3 + 5 + (R.detail_listedPill._value:GetStringWidth() or 40) + 50
        R.detail_listedPill:SetWidth(math.max(80, math.min(160, pillW)))
    end

    -- Voice pill
    if R.detail_voicePill then
        if info.voiceChat and info.voiceChat ~= "" then
            R.detail_voicePill._value:SetText(info.voiceChat)
            local pillW = 3 + 5 + (R.detail_voicePill._value:GetStringWidth() or 30) + 50
            R.detail_voicePill:SetWidth(math.max(70, math.min(160, pillW)))
            R.detail_voicePill:Show()
        else
            R.detail_voicePill:Hide()
        end
    end

    -- Update members (scrollable, virtual scroll with offset)
    local numMembers = info.numMembers or 0
    Panel._state.detailMemberCount = numMembers
    Panel._state.detailMemberScrollOffset = 0
    -- Cache member data for scroll repositioning
    Panel._state._detailMemberResultID = resultID
    Panel._state._detailMemberInfo = info

    -- Update the member header with count
    if R.detailMembers then
        local poolSize = #R.detailMembers
        for i = 1, poolSize do
            local memberRow = R.detailMembers[i]
            local dataIdx = i -- no offset on initial display
            if dataIdx <= numMembers then
                local ok2, role, class, classLocal, specLocal = pcall(C_LFGList.GetSearchResultMemberInfo, resultID, dataIdx)
                if ok2 then
                    local roleLabel = role == "TANK" and "Tank" or role == "HEALER" and "Healer" or "DPS"
                    local memberName = ""
                    if specLocal and specLocal ~= "" and classLocal then
                        memberName = specLocal .. " " .. classLocal
                    elseif classLocal then
                        memberName = classLocal
                    elseif specLocal then
                        memberName = specLocal
                    end
                    memberRow._nameText:SetText(memberName)

                    local cc = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
                    if cc then
                        memberRow._nameText:SetTextColor(cc.r, cc.g, cc.b)
                    else
                        memberRow._nameText:SetTextColor(TC("bodyText"))
                    end

                    memberRow._roleText:SetText("(" .. roleLabel .. ")")

                    -- MPI badge
                    local memberMPI = nil
                    if dataIdx == 1 and info.leaderName then
                        local prof = GetCachedMPIProfile(info.leaderName)
                        if prof then memberMPI = prof.avgMPI end
                    end
                    if memberMPI then
                        local sr, sg, sb = GetMPIScoreColor(memberMPI)
                        memberRow._mpiBg:SetColorTexture(sr, sg, sb, 0.3)
                        memberRow._mpiText:SetText(tostring(memberMPI))
                    else
                        memberRow._mpiBg:SetColorTexture(0.5, 0.5, 0.5, 0.3)
                        memberRow._mpiText:SetText("--")
                    end

                    memberRow._bestText:SetText("")

                    memberRow:Show()
                else
                    memberRow:Hide()
                end
            else
                memberRow:Hide()
            end
        end
    end

    -- Dynamically size member scroll and detail panel to fit content
    local MEMBER_ROW_H = 28
    local memberListH = math.min(numMembers, 5) * MEMBER_ROW_H  -- cap visual height at 5 rows
    if R.detailMemberScroll then
        R.detailMemberScroll:SetHeight(math.max(MEMBER_ROW_H, memberListH))
    end
    -- 96px header/pills + memberListH + 8px bottom pad + 36px apply area
    local panelH = 96 + math.max(MEMBER_ROW_H, memberListH) + 44
    R.detailPanel:SetHeight(math.min(CFG.DETAIL_PANEL_H, panelH))

    -- Store resultID for apply + update detail apply button state
    R.detailPanel._resultID = resultID
    if R.detail_applyBtn then
        local dAppOk, _, dAppStatus = pcall(C_LFGList.GetApplicationInfo, resultID)
        local dDisable = false
        local dLabel = "Apply"
        if dAppOk and dAppStatus and dAppStatus ~= "none" then
            dDisable = true
            if dAppStatus == "applied" then dLabel = "Pending"
            elseif dAppStatus == "invited" then dLabel = "Invited"
            elseif dAppStatus == "declined" or dAppStatus == "declined_full" or dAppStatus == "declined_delisted" then dLabel = "Declined"
            elseif dAppStatus == "cancelled" then dLabel = "Cancelled"
            elseif dAppStatus == "timedout" then dLabel = "Expired"
            end
        end
        if R.detail_applyBtn._label then R.detail_applyBtn._label:SetText(dLabel) end
        if dDisable then
            R.detail_applyBtn:SetAlpha(0.35)
            R.detail_applyBtn:EnableMouse(false)
        else
            R.detail_applyBtn:SetAlpha(1.0)
            R.detail_applyBtn:EnableMouse(true)
        end
    end
    R.detailPanel:Show()
end

-- Hide the group detail overlay panel
function Panel.HideGroupDetail()
    local R = Panel._refs
    if R.detailPanel then R.detailPanel:Hide() end
    Panel._state.detailOpen = false
    Panel._state.selectedResult = nil
end

-- F3: List your keystone as a group
function Panel.ListMyKey()
    local mplusData = GetPlayerMPlusData()
    if not mplusData.keystoneMapID or not mplusData.keystoneLevel then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r You don't have a keystone to list.", 1, 0.6, 0.2)
        end
        return
    end
    -- Check if already listed
    if C_LFGList.HasActiveEntryInfo and C_LFGList.HasActiveEntryInfo() then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r You already have an active listing. Delisting first...", 1, 0.6, 0.2)
        end
        pcall(C_LFGList.RemoveListing)
        C_Timer.After(0.5, function() Panel.ListMyKey() end)
        return
    end
    -- Find M+ activity for this dungeon
    local activityID = nil
    if C_LFGList.GetAvailableActivities then
        local ok, activities = pcall(C_LFGList.GetAvailableActivities, 2) -- dungeons
        if ok and activities then
            for _, actID in ipairs(activities) do
                local aOk, aInfo = pcall(C_LFGList.GetActivityInfoTable, actID)
                if aOk and aInfo and aInfo.isMythicPlusActivity and aInfo.mapID == mplusData.keystoneMapID then
                    activityID = actID
                    break
                end
            end
        end
    end
    if not activityID then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Could not find activity for this keystone.", 1, 0.4, 0.4)
        end
        return
    end
    -- Create the listing (hardware event context from button click)
    local groupName = "+" .. mplusData.keystoneLevel .. " " .. (mplusData.keystoneName or "Key")
    local ok, err = pcall(C_LFGList.CreateListing, activityID)
    if ok then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Listed: " .. groupName, 0.5, 1.0, 0.8)
        end
        C_Timer.After(0.5, function() Panel.UpdatePremadeHero() end)
    else
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Failed to create listing.", 1, 0.4, 0.4)
        end
    end
end

-- Apply to a group with the player's current role
function Panel.ApplyToGroup(resultID)
    if not resultID then return end

    -- Validate
    local validOk, validInfo = pcall(C_LFGList.GetSearchResultInfo, resultID)
    if not validOk or not validInfo then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Group is no longer available.", 1, 0.4, 0.4)
        end
        return
    end

    -- Read role from sidebar selector
    local R = Panel._refs
    local roles = Panel._state.applyRole or {}
    local isTank = roles.tank or false
    local isHealer = roles.healer or false
    local isDPS = roles.dps or false
    if not isTank and not isHealer and not isDPS then isDPS = true end

    -- Read description from sidebar box
    local comment = ""
    if R.applyDescBox then
        comment = R.applyDescBox:GetText() or ""
    end

    -- Check application limit (WoW caps at 5 pending applications)
    local pendingCount = 0
    if C_LFGList.GetApplications then
        local aOk, apps = pcall(C_LFGList.GetApplications)
        if aOk and apps then pendingCount = #apps end
    end
    if pendingCount >= 5 then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Cannot apply — you already have 5 pending applications.", 1, 0.6, 0.2)
        end
        return
    end

    local ok = pcall(C_LFGList.ApplyToGroup, resultID, comment, isTank, isHealer, isDPS)
    if ok then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Applied to group. (" .. (pendingCount + 1) .. "/5)", 0.5, 1.0, 0.8)
        end
        -- Refresh the application tracker (slight delay for API to update)
        C_Timer.After(0.3, function()
            Panel.UpdateGroupIntelSidebar()
            Panel.UpdateListingRows()
        end)
    end
end

-- ============================================================================
-- S8c  DUNGEON OVERVIEW LOGIC
-- ============================================================================

function Panel.UpdateDungeonQueueStatus()
    local R = Panel._refs
    if not R.dungeonQueueBar then return end

    local inQueue = false
    local lfgCat = LE_LFG_CATEGORY_LFD or 1
    local ok, hasData, leaderNeeds, tankNeeds, healerNeeds, dpsNeeds,
          totalTanks, totalHealers, totalDPS, instanceType, instanceSubType,
          instanceName, averageWait, tankWait, healerWait, damageWait,
          myWait, queuedTime = pcall(GetLFGQueueStats, lfgCat)
    if ok and hasData then
        inQueue = true
        local waitMin = myWait and math.ceil(myWait / 60) or 0
        local queueMin = queuedTime and math.floor(queuedTime / 60) or 0
        local queuedFor = Panel._state.dungeonQueuedNames or instanceName or "Dungeon"
        R.dungeonQueueText:SetText(tostring(queuedFor) .. " — Est: " .. waitMin .. "m — In queue: " .. queueMin .. "m")
    end

    if inQueue then
        R.dungeonQueueBar:Show()
    else
        R.dungeonQueueBar:Hide()
    end
end

function Panel.UpdateDungeonCards()
    local R = Panel._refs
    if not R.dungeonCards then return end

    -- Use Blizzard APIs for per-dungeon best levels (mapID-based, no name matching)
    local mplusData = GetPlayerMPlusData()
    local maxLevel = 0

    -- First pass: find max level for progress bars
    for _, lvl in pairs(mplusData.dungeonBest) do
        if lvl > maxLevel then maxLevel = lvl end
    end

    for _, card in ipairs(R.dungeonCards) do
        local mapID = card._mapID
        local bestLevel = mplusData.dungeonBest[mapID] or 0

        if bestLevel > 0 then
            card._bestText:SetText("Best: +" .. bestLevel)
            card._bestText:SetTextColor(TC("bodyText"))
        else
            card._bestText:SetText("No runs yet")
            card._bestText:SetTextColor(TC("mutedText"))
        end

        -- Blizzard dungeon score contribution
        if card._scoreText then
            if C_ChallengeMode and C_ChallengeMode.GetSpecificDungeonOverallScoreRankForMap then
                local ok, dungScore = pcall(C_ChallengeMode.GetSpecificDungeonOverallScoreRankForMap, mapID)
                if ok and dungScore and dungScore > 0 then
                    card._scoreText:SetText("Score: " .. dungScore)
                else
                    card._scoreText:SetText("")
                end
            else
                card._scoreText:SetText("")
            end
        end

        -- Update progress bar (proportional to max key level)
        if maxLevel > 0 and bestLevel > 0 then
            local pct = bestLevel / maxLevel
            local trackW = card._trackBg:GetWidth()
            if trackW and trackW > 0 then
                card._trackFill:SetWidth(math.max(1, trackW * pct))
            end
        else
            card._trackFill:SetWidth(1)
        end
    end

    -- Follower cards: filter by level eligibility and re-layout visible ones
    Panel.UpdateFollowerCardVisibility()
end

function Panel.UpdateFollowerCardVisibility()
    local R = Panel._refs
    local cards = R.followerCards
    if not cards or #cards == 0 then return end

    local L = Panel._cardLayout
    if not L then return end

    local playerLevel = UnitLevel and UnitLevel("player") or 0
    local mplusRows = math.ceil(#(R.dungeonCards or {}) / 2)
    local mplusStartY = -(L.SECTION_H)
    local followerStartY = mplusStartY - (mplusRows * (L.H + L.GY)) - 8

    -- Determine which cards are eligible
    local visible = {}
    for _, card in ipairs(cards) do
        local eligible = true
        if playerLevel > 0 then
            local mn = card._minLevel or 0
            local mx = card._maxLevel or 0
            if mn > 0 and playerLevel < mn then eligible = false end
            if mx > 0 and playerLevel > mx then eligible = false end
        end
        if eligible then
            card:Show()
            visible[#visible + 1] = card
        else
            card:Hide()
            card._selected = false
        end
    end

    -- Show/hide section header based on visible count
    if R.followerHeader then
        if #visible > 0 then R.followerHeader:Show() else R.followerHeader:Hide() end
    end
    if R.followerDiv then
        if #visible > 0 then R.followerDiv:Show() else R.followerDiv:Hide() end
    end

    -- Re-layout visible cards in 2-column grid
    local fCardStartY = followerStartY - L.SECTION_H
    for i, card in ipairs(visible) do
        local col = (i - 1) % 2
        local row = math.floor((i - 1) / 2)
        local xOfs = col * (L.W + L.GX)
        local yOfs = fCardStartY - (row * (L.H + L.GY))
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", R.cardContainer, "TOPLEFT", xOfs, yOfs)
    end

    -- Resize container to fit
    local visibleRows = math.ceil(#visible / 2)
    local totalH = L.SECTION_H + mplusRows * (L.H + L.GY) + 8
    if #visible > 0 then
        totalH = totalH + L.SECTION_H + visibleRows * (L.H + L.GY) + 8
    end
    if R.cardContainer then
        R.cardContainer:SetHeight(totalH)
    end

    -- Reposition follower header
    if R.followerHeader and #visible > 0 then
        R.followerHeader:ClearAllPoints()
        R.followerHeader:SetPoint("TOPLEFT", R.cardContainer, "TOPLEFT", 4, followerStartY)
    end
end

function Panel.UpdateDungeonRoleCards()
    Panel.UpdateRoleCards(Panel._refs.dungeonRoleCards or Panel._refs.dungeonRoleBtns, Panel._state.dungeonRoles)
end

function Panel.AutoDetectDungeonRoles()
    local R = Panel._refs
    local cards = R.dungeonRoleCards or R.dungeonRoleBtns
    if not cards then return end

    local spec = GetSpecialization and GetSpecialization()
    local role = nil
    if spec then
        local ok, _, _, _, specRole = pcall(GetSpecializationInfo, spec)
        if ok and specRole then role = specRole end
    end

    local st = Panel._state.dungeonRoles
    st.tank = (role == "TANK")
    st.healer = (role == "HEALER")
    st.dps = (role == "DAMAGER")
    -- Default to DPS if nothing detected
    if not st.tank and not st.healer and not st.dps then st.dps = true end

    Panel.UpdateDungeonRoleCards()
end

-- ============================================================================
-- S8d  RAID FINDER LOGIC
-- ============================================================================

function Panel.AutoDetectRaidRoles()
    local R = Panel._refs
    if not R.raidRoleBtns then return end

    local spec = GetSpecialization and GetSpecialization()
    local role = nil
    if spec then
        local ok, _, _, _, specRole = pcall(GetSpecializationInfo, spec)
        if ok and specRole then role = specRole end
    end

    local st = Panel._state.raidRoles
    if not st then
        Panel._state.raidRoles = { tank = false, healer = false, dps = false }
        st = Panel._state.raidRoles
    end
    st.tank = (role == "TANK")
    st.healer = (role == "HEALER")
    st.dps = (role == "DAMAGER")
    if not st.tank and not st.healer and not st.dps then st.dps = true end

    Panel.UpdateRaidRoleCards()
end

function Panel.UpdateRaidFinder()
    local R = Panel._refs
    if not R.raidWingCards then return end

    local wings = {}
    local playerLevel = UnitLevel("player") or 80
    local ok, numRF = pcall(GetNumRFDungeons)
    if ok and numRF and numRF > 0 then
        for i = 1, numRF do
            local ok2, id, name = pcall(GetRFDungeonInfo, i)
            if ok2 and id and name then
                -- Filter by level eligibility
                local eligible = true
                if GetLFGDungeonInfo then
                    local okI, dName, typeID, subtypeID, minLevel, maxLevel = pcall(GetLFGDungeonInfo, id)
                    if okI and minLevel and maxLevel then
                        if playerLevel < minLevel or playerLevel > maxLevel then
                            eligible = false
                        end
                    end
                end
                if eligible then
                    wings[#wings + 1] = { id = id, name = name }
                end
            end
        end
    end

    -- If we got no wings from API, show fallback message
    if #wings == 0 then
        for i = 1, 4 do
            if R.raidWingCards[i] then R.raidWingCards[i]:Hide() end
        end
        if R.raidNoWingsMsg then R.raidNoWingsMsg:Show() end
        if R.raidTierName then R.raidTierName:SetText("") end
        return
    end

    if R.raidNoWingsMsg then R.raidNoWingsMsg:Hide() end

    -- Populate cards
    for i = 1, 4 do
        local card = R.raidWingCards[i]
        if not card then break end
        local wing = wings[i]
        if wing then
            card._nameText:SetText(wing.name)
            -- Get boss kill progress
            local defeatedText = "Select to queue"
            local ok3, numEnc = pcall(GetLFGDungeonNumEncounters, wing.id)
            if ok3 and numEnc and numEnc > 0 then
                local killed = 0
                for e = 1, numEnc do
                    local ok4, eName, eID, isKilled = pcall(GetLFGDungeonEncounterInfo, wing.id, e)
                    if ok4 and isKilled then killed = killed + 1 end
                end
                if killed > 0 then
                    defeatedText = "Bosses: " .. numEnc .. "  \194\183  Defeated: " .. killed .. "/" .. numEnc
                else
                    defeatedText = "Bosses: " .. numEnc .. "  \194\183  Not started"
                end
            end
            card._infoText:SetText(defeatedText)
            card._wingID = wing.id
            card:Show()
        else
            card:Hide()
        end
    end
end

function Panel.UpdateRaidQueueStatus()
    local R = Panel._refs
    if not R.raidQueueBar then return end

    local inQueue = false
    local lfgCat = LE_LFG_CATEGORY_RF or 2
    local ok, hasData, leaderNeeds, tankNeeds, healerNeeds, dpsNeeds,
          totalTanks, totalHealers, totalDPS, instanceType, instanceSubType,
          instanceName, averageWait, tankWait, healerWait, damageWait,
          myWait, queuedTime = pcall(GetLFGQueueStats, lfgCat)
    if ok and hasData then
        inQueue = true
        local waitMin = myWait and math.ceil(myWait / 60) or 0
        local queueMin = queuedTime and math.floor(queuedTime / 60) or 0
        R.raidQueueText:SetText("Queued \226\128\148 Est: " .. waitMin .. " min \226\128\148 In queue: " .. queueMin .. " min")
    end

    if inQueue then
        R.raidQueueBar:Show()
    else
        R.raidQueueBar:Hide()
    end
end

-- ============================================================================
-- S8e  HERO UPDATE FUNCTIONS
-- ============================================================================

function Panel.UpdateDungeonHero()
    local R = Panel._refs
    if not R.dungeonHero then return end

    local mplusData = GetPlayerMPlusData()

    -- Row 1: Context bar (removed)


    PopulatePlayerIdentity(R.dungeonHeroPlayerLine, R.dungeonHeroClassIcon, R.dungeonHeroSpecLine)

    -- Row 4: M+ Rating pill
    if R.dungeonRatingPill then
        if mplusData.overallScore > 0 then
            R.dungeonRatingPill._value:SetText(FormatNumber(mplusData.overallScore))
            local sc = mplusData.scoreColor
            R.dungeonRatingPill._value:SetTextColor(sc[1], sc[2], sc[3])
        else
            R.dungeonRatingPill._value:SetText("--")
            R.dungeonRatingPill._value:SetTextColor(TC("mutedText"))
        end
    end

    -- Row 4: Keystone pill
    if R.dungeonKeystonePill then
        if mplusData.keystoneLevel and mplusData.keystoneName then
            R.dungeonKeystonePill._value:SetText("+" .. mplusData.keystoneLevel .. " " .. mplusData.keystoneName)
        elseif mplusData.keystoneLevel then
            R.dungeonKeystonePill._value:SetText("+" .. mplusData.keystoneLevel)
        else
            R.dungeonKeystonePill._value:SetText("None")
        end
    end

    -- Row 5: Dungeon badges
    if R.heroDungeonBadges then
        for _, badge in ipairs(R.heroDungeonBadges) do
            local best = mplusData.dungeonBest[badge._mapID]
            if best and best > 0 then
                badge._levelText:SetText("+" .. best)
                badge._levelText:SetTextColor(badge._accent[1], badge._accent[2], badge._accent[3])
                badge:SetAlpha(1.0)
            else
                badge._levelText:SetText("--")
                badge._levelText:SetTextColor(TC("mutedText"))
                badge:SetAlpha(0.5)
            end
        end
    end

    -- Progress bar
    if R.dungeonHeroTrack and R.dungeonHeroFill then
        local pct = math.min(1, mplusData.overallScore / CFG.SCORE_CAP)
        local trackW = R.dungeonHeroTrack:GetWidth()
        if trackW and trackW > 0 then
            R.dungeonHeroFill:SetWidth(math.max(1, trackW * pct))
        end
    end

    -- Role cards
    Panel.UpdateDungeonRoleCards()
end

function Panel.UpdateRaidRoleCards()
    Panel.UpdateRoleCards(Panel._refs.raidRoleCards, Panel._state.raidRoles, { 0.80, 0.65, 0.20 })
end

function Panel.UpdateRaidHero()
    local R = Panel._refs
    if not R.raidHero then return end

    PopulatePlayerIdentity(R.raidHeroPlayerName, R.raidHeroClassIcon, R.raidHeroSpecLine)

    -- Tier name pill
    if R.raidHeroTierName then
        R.raidHeroTierName:SetText(DeriveRaidTierName())
    end

    local wings, totalBosses, totalKilled = GetRaidBossProgress()

    -- Wing progress (context bar removed, boss count pill kept)

    if R.raidHeroBossCount then
        R.raidHeroBossCount:SetText(totalKilled .. "/" .. totalBosses)
    end

    -- Wing progress bars
    if R.raidWingBars then
        for wi = 1, 4 do
            local bar = R.raidWingBars[wi]
            if not bar then break end
            local wing = wings[wi]
            if wing then
                bar._nameText:SetText(wing.name)
                bar._countText:SetText(wing.killed .. "/" .. wing.total)
                if wing.killed > 0 then
                    bar._countText:SetTextColor(bar._accent[1], bar._accent[2], bar._accent[3])
                else
                    bar._countText:SetTextColor(TC("mutedText"))
                end
                -- Fill width based on kill progress
                local barInnerW = bar:GetWidth() - 2
                if barInnerW > 0 and wing.total > 0 then
                    bar._fill:SetWidth(math.max(1, barInnerW * (wing.killed / wing.total)))
                else
                    bar._fill:SetWidth(1)
                end
                bar:Show()
            else
                bar:Hide()
            end
        end
    end

    -- Progress bar (bosses killed / total)
    if R.raidHeroTrack and R.raidHeroFill then
        if totalBosses > 0 then
            local pct = totalKilled / totalBosses
            local trackW = R.raidHeroTrack:GetWidth()
            if trackW and trackW > 0 then
                R.raidHeroFill:SetWidth(math.max(1, trackW * pct))
            end
        else
            R.raidHeroFill:SetWidth(1)
        end
    end

    Panel.UpdateRaidRoleCards()
end

function Panel.UpdatePremadeHero()
    local R = Panel._refs
    if not R.premadeHero then return end

    -- Category label + group count (top bar)
    local cat = Panel._state.activeCategory
    local titles = {
        mythicplus = "MYTHIC+ GROUPS", delves = "DELVE GROUPS",
        raids = "RAID GROUPS", legacy = "LEGACY RAID GROUPS",
        questing = "QUEST GROUPS", custom = "CUSTOM GROUPS",
    }
    -- Context bar text removed

    PopulatePlayerIdentity(R.premadeHeroPlayerName, R.premadeHeroClassIcon, R.premadeHeroSpecLine)

    -- Pill bar: M+ Rating
    local mplusData = GetPlayerMPlusData()
    if R.premadeHeroScorePill then
        local pill = R.premadeHeroScorePill
        if mplusData.overallScore > 0 then
            pill._value:SetText(FormatNumber(mplusData.overallScore))
            local sc = mplusData.scoreColor
            pill._value:SetTextColor(sc[1], sc[2], sc[3])
            pill._dot:SetColorTexture(sc[1], sc[2], sc[3], 0.80)
        else
            pill._value:SetText("--")
            pill._value:SetTextColor(TC("mutedText"))
            pill._dot:SetColorTexture(TC("accent"))
        end
    end

    -- Pill bar: Keystone
    if R.premadeHeroKeystonePill then
        local pill = R.premadeHeroKeystonePill
        if mplusData.keystoneLevel and mplusData.keystoneName then
            pill._value:SetText("+" .. mplusData.keystoneLevel .. " " .. mplusData.keystoneName)
            pill._value:SetTextColor(TC("bodyText"))
            -- Color dot with dungeon accent
            local ksAccent = nil
            for _, d in ipairs(Panel._dungeonData or {}) do
                if d.mapID == mplusData.keystoneMapID then ksAccent = d.accent; break end
            end
            if ksAccent then
                pill._dot:SetColorTexture(ksAccent[1], ksAccent[2], ksAccent[3], 0.80)
            end
        else
            pill._value:SetText("None")
            pill._value:SetTextColor(TC("mutedText"))
        end
    end

    -- Role cards
    Panel.UpdatePremadeRoleCards()

    -- Suggestion (bottom left, only when actionable)
    if R.premadeHeroSuggestion then
        local weakest, weakLevel = FindWeakestDungeon(Panel._dungeonData or {}, mplusData.dungeonBest)
        local hasAnyRuns = false
        for _ in pairs(mplusData.dungeonBest) do hasAnyRuns = true; break end
        if hasAnyRuns and weakest and weakLevel > 0 then
            R.premadeHeroSuggestion:SetText("Weakest: " .. weakest.name .. " (+" .. weakLevel .. ")")
        else
            R.premadeHeroSuggestion:SetText("")
        end
    end

    -- F3: List Your Key button state
    if R.listKeyBtn then
        local hasKey = mplusData.keystoneLevel and mplusData.keystoneMapID
        local hasListing = C_LFGList.HasActiveEntryInfo and SafeCall(C_LFGList.HasActiveEntryInfo)
        if hasListing then
            R.listKeyBtn._label:SetText("Delist")
            R.listKeyBtn:SetAlpha(1.0)
            R.listKeyBtn:EnableMouse(true)
            R.listKeyBtn:SetScript("OnClick", function()
                pcall(C_LFGList.RemoveListing)
                C_Timer.After(0.5, function() Panel.UpdatePremadeHero() end)
            end)
        elseif hasKey then
            R.listKeyBtn._label:SetText("List Your Key")
            R.listKeyBtn:SetAlpha(1.0)
            R.listKeyBtn:EnableMouse(true)
            R.listKeyBtn:SetScript("OnClick", function() Panel.ListMyKey() end)
        else
            R.listKeyBtn._label:SetText("No Key")
            R.listKeyBtn:SetAlpha(0.4)
            R.listKeyBtn:EnableMouse(false)
        end
    end

    -- MPI: Premade hero pill
    if _G.MidnightPI and _G.MidnightPI.UpdatePremadeHeroPill then _G.MidnightPI.UpdatePremadeHeroPill(R) end

    -- MPI: Companion app banner (shows on premade hero when companion not installed)
    if _G.MidnightPI and _G.MidnightPI.UpdateCompanionBanner then _G.MidnightPI.UpdateCompanionBanner(R.premadeHero) end
end

-- ============================================================================
-- S8f  SUGGESTION STRIP LOGIC
-- ============================================================================

function Panel.UpdateDungeonSuggestions()
    local R = Panel._refs
    if not R.suggestWeakText then return end

    local mplusData = GetPlayerMPlusData()
    local dungeons = Panel._dungeonData or {}

    -- Weakest dungeon suggestion — only show when player has some runs
    local weakest, weakLevel = FindWeakestDungeon(dungeons, mplusData.dungeonBest)
    local hasAnyRuns = false
    for _ in pairs(mplusData.dungeonBest) do hasAnyRuns = true; break end

    if hasAnyRuns and weakest then
        if weakLevel == 0 then
            R.suggestWeakText:SetText("Try: " .. weakest.name)
            R.suggestWeakText:SetTextColor(TC("accent"))
        else
            R.suggestWeakText:SetText("Weakest: " .. weakest.name .. " (+" .. weakLevel .. ")")
            R.suggestWeakText:SetTextColor(TC("mutedText"))
        end
    else
        R.suggestWeakText:SetText("")
    end

    -- Keystone — only show when player has one
    if R.suggestKeyText then
        if mplusData.keystoneLevel and mplusData.keystoneName then
            R.suggestKeyText:SetText("Key: +" .. mplusData.keystoneLevel .. " " .. mplusData.keystoneName)
            R.suggestKeyText:SetTextColor(TC("bodyText"))
        else
            R.suggestKeyText:SetText("") -- hide when no keystone
        end
    end

    -- MPI: Personal dashboard
    if _G.MidnightPI and _G.MidnightPI.UpdateDungeonHeroDashboard then _G.MidnightPI.UpdateDungeonHeroDashboard(R.dungeonHero) end
end

-- ============================================================================
-- ============================================================================
-- S8h  INVITATION NOTIFICATION
-- ============================================================================

function Panel.ShowInviteBanner(groupName)
    local R = Panel._refs
    if not R.inviteBanner then
        local parent = R.premadeHero or R.listingArea
        if not parent then return end
        local banner = CreateFrame("Frame", nil, parent, "BackdropTemplate")
        banner:SetHeight(28)
        banner:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", CFG.PAD, 4)
        banner:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -CFG.PAD, 4)
        banner:SetBackdrop({ bgFile = W8, edgeFile = W8, edgeSize = 1,
            insets = { left = 1, right = 1, top = 1, bottom = 1 } })
        banner:SetBackdropColor(0.12, 0.45, 0.2, 0.95)
        banner:SetBackdropBorderColor(0.3, 0.9, 0.4, 0.8)
        banner:SetFrameLevel(parent:GetFrameLevel() + 10)
        local bannerText = banner:CreateFontString(nil, "OVERLAY")
        TrySetFont(bannerText, TITLE_FONT, 12, "OUTLINE")
        bannerText:SetPoint("CENTER")
        bannerText:SetTextColor(1, 1, 1)
        banner._text = bannerText
        R.inviteBanner = banner
    end
    R.inviteBanner._text:SetText("Invited to: " .. (groupName or "a group") .. "!")
    R.inviteBanner:Show()
    C_Timer.After(8, function()
        if R.inviteBanner then R.inviteBanner:Hide() end
    end)
end

-- S8g  SETTINGS / THEME
-- ============================================================================

function Panel.ShowSettingsPopup()
    local R = Panel._refs
    if R.settingsPopup then R.settingsPopup:Show() end
end

function Panel.ApplyTheme()
    GetActiveTheme()
    local R = Panel._refs
    if not R.panel then return end

    -- Main panel
    R.panel:SetBackdropColor(TC("frameBg"))
    local ac = activeTheme.accent
    R.panel:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.15)

    -- Header
    if R.headerBg then R.headerBg:SetColorTexture(TC("headerBg")) end
    if R.title then R.title:SetTextColor(TC("titleText")) end
    if R.headerAccentLine and R.headerAccentLine.SetGradient and CreateColor then
        R.headerAccentLine:SetGradient("HORIZONTAL",
            CreateColor(ac[1], ac[2], ac[3], 0.6),
            CreateColor(ac[1], ac[2], ac[3], 0.0))
    end

    -- Settings popup border
    if R.settingsPopup then
        R.settingsPopup:SetBackdropBorderColor(ac[1], ac[2], ac[3], 0.5)
    end

    -- Tab visuals
    if R.tabDivider then R.tabDivider:SetColorTexture(TC("accent")) end

    -- Glass panels
    if R.catSidebar and R.catSidebar.ApplyTheme then R.catSidebar:ApplyTheme() end
    if R.playerSidebar and R.playerSidebar.ApplyTheme then R.playerSidebar:ApplyTheme() end

    -- Refresh active tab (updates all content colors)
    Panel.SetActiveTab(Panel._state.activeTab)
end

-- ============================================================================
-- S8z  TOAST OVERLAY
-- ============================================================================

do
    local toastFrame, toastTitle, toastSep, toastBody, toastDismiss, toastTimer

    function Panel.ShowToast(title, body, duration)
        local R = Panel._refs
        local parent = R.panel or UIParent

        if not toastFrame then
            toastFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
            toastFrame:SetSize(460, 90)
            toastFrame:SetPoint("TOP", parent, "TOP", 0, -80)
            toastFrame:SetFrameStrata("DIALOG")
            toastFrame:SetFrameLevel(200)
            toastFrame:SetBackdrop({
                bgFile = W8, edgeFile = W8, edgeSize = 1,
                insets = { left = 1, right = 1, top = 1, bottom = 1 },
            })
            toastFrame:SetBackdropColor(0.06, 0.02, 0.02, 0.96)
            toastFrame:SetBackdropBorderColor(0.5, 0.12, 0.12, 0.7)

            -- Top frost line
            local frost = toastFrame:CreateTexture(nil, "OVERLAY", nil, 3)
            frost:SetHeight(1)
            frost:SetPoint("TOPLEFT", toastFrame, "TOPLEFT", 1, -1)
            frost:SetPoint("TOPRIGHT", toastFrame, "TOPRIGHT", -1, -1)
            frost:SetColorTexture(1, 0.3, 0.3, 0.15)

            -- Title (centered)
            toastTitle = toastFrame:CreateFontString(nil, "OVERLAY")
            toastTitle:SetPoint("TOP", toastFrame, "TOP", 0, -12)
            TrySetFont(toastTitle, TITLE_FONT, 12, "OUTLINE")
            toastTitle:SetTextColor(1, 0.35, 0.35)
            toastTitle:SetJustifyH("CENTER")

            -- Separator line below title
            toastSep = toastFrame:CreateTexture(nil, "OVERLAY", nil, 2)
            toastSep:SetHeight(1)
            toastSep:SetPoint("TOPLEFT", toastTitle, "BOTTOMLEFT", -60, -6)
            toastSep:SetPoint("TOPRIGHT", toastTitle, "BOTTOMRIGHT", 60, -6)
            toastSep:SetColorTexture(1, 0.3, 0.3, 0.2)

            -- Body (centered)
            toastBody = toastFrame:CreateFontString(nil, "OVERLAY")
            toastBody:SetPoint("TOP", toastSep, "BOTTOM", 0, -8)
            toastBody:SetPoint("LEFT", toastFrame, "LEFT", 20, 0)
            toastBody:SetPoint("RIGHT", toastFrame, "RIGHT", -20, 0)
            TrySetFont(toastBody, BODY_FONT, 10)
            toastBody:SetTextColor(0.8, 0.7, 0.7)
            toastBody:SetJustifyH("CENTER")
            toastBody:SetWordWrap(true)

            -- Dismiss hint
            toastDismiss = toastFrame:CreateFontString(nil, "OVERLAY")
            toastDismiss:SetPoint("BOTTOM", toastFrame, "BOTTOM", 0, 5)
            TrySetFont(toastDismiss, BODY_FONT, 8)
            toastDismiss:SetTextColor(0.4, 0.3, 0.3)
            toastDismiss:SetText("click to dismiss")

            toastFrame:EnableMouse(true)
            toastFrame:SetScript("OnMouseDown", function(self)
                self:Hide()
                if toastTimer then toastTimer:Cancel(); toastTimer = nil end
            end)

            toastFrame:Hide()
        end

        if toastFrame:GetParent() ~= parent then
            toastFrame:SetParent(parent)
            toastFrame:ClearAllPoints()
            toastFrame:SetPoint("TOP", parent, "TOP", 0, -80)
        end

        toastTitle:SetText(title or "Notice")
        toastBody:SetText(body or "")

        -- Auto-size height to fit content
        local bodyH = toastBody:GetStringHeight() or 14
        toastFrame:SetHeight(math.max(80, 12 + 16 + 6 + 1 + 8 + bodyH + 8 + 14 + 5))

        toastFrame:Show()

        if toastTimer then toastTimer:Cancel() end
        toastTimer = C_Timer.NewTimer(duration or 5, function()
            if toastFrame then toastFrame:Hide() end
            toastTimer = nil
        end)
    end
end

-- ============================================================================
-- S9  SHOW / HIDE / TOGGLE / ISOPEN
-- ============================================================================

function Panel.Show(tab)
    -- Block during PVP handoff to Blizzard UI
    if Panel._state._pvpHandoff then
        return
    end
    -- Block during combat
    if InCombatLockdown and InCombatLockdown() then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Cannot open Group Finder during combat.", 1, 0.4, 0.4)
        end
        return
    end
    local p = Panel.EnsurePanel()
    if not p then return end

    -- Close other MidnightUI panels to prevent overlap
    local charFrame = _G["MidnightUI_CharacterPanel"]
    if charFrame and charFrame:IsShown() then charFrame:Hide() end
    local guildFrame = _G["MidnightUI_GuildPanel"]
    if guildFrame and guildFrame:IsShown() then guildFrame:Hide() end

    GetActiveTheme()
    Panel._state.panelOpen = true
    p:Show()
    Panel.SetActiveTab(tab or Panel._state.activeTab or "premade")

end

function Panel.Hide()
    StopAutoRefresh()
    Panel.HideGroupDetail()
    -- Close dungeon dropdown if open
    local R = Panel._refs
    if R.dungeonDropdown and R.dungeonDropdown:IsShown() then
        R.dungeonDropdown:Hide()
    end
    if R.panel then R.panel:Hide() end
    Panel._state.panelOpen = false
end

function Panel.Toggle()
    -- Always clear PVP handoff on explicit toggle (keybind press)
    Panel._state._pvpHandoff = false
    if Panel._state.panelOpen and Panel._refs.panel and Panel._refs.panel:IsShown() then
        Panel.Hide()
    else
        Panel.Show()
    end
end

function Panel.IsOpen()
    return Panel._state.panelOpen and Panel._refs.panel and Panel._refs.panel:IsShown()
end

-- ============================================================================
-- S9b  LFG SEARCH EVENT HANDLER
-- ============================================================================
local searchEventFrame = CreateFrame("Frame")
searchEventFrame:RegisterEvent("LFG_LIST_SEARCH_RESULTS_RECEIVED")
searchEventFrame:RegisterEvent("LFG_UPDATE")
searchEventFrame:RegisterEvent("LFG_QUEUE_STATUS_UPDATE")
searchEventFrame:RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED")
searchEventFrame:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
searchEventFrame:RegisterEvent("LFG_LIST_APPLICANT_LIST_UPDATED")
searchEventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
searchEventFrame:RegisterEvent("UPDATE_BATTLEFIELD_STATUS")
searchEventFrame:RegisterEvent("PVP_RATED_STATS_UPDATE")
searchEventFrame:RegisterEvent("HONOR_LEVEL_UPDATE")
searchEventFrame:RegisterEvent("UI_ERROR_MESSAGE")
searchEventFrame:RegisterEvent("LFG_LOCK_INFO_RECEIVED")
searchEventFrame:RegisterEvent("LFG_PROPOSAL_SHOW")
searchEventFrame:RegisterEvent("LFG_PROPOSAL_FAILED")
searchEventFrame:RegisterEvent("LFG_PROPOSAL_SUCCEEDED")
searchEventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "UI_ERROR_MESSAGE" then
        local errType, errMsg = ...
        -- If we're in a queue attempt window, capture the error for the toast
        if Panel._state.dungeonQueueAttempted or Panel._state.raidQueueAttempted then
            Panel._state._queueErrorMsgs = Panel._state._queueErrorMsgs or {}
            if errMsg then
                table.insert(Panel._state._queueErrorMsgs, errMsg)
            end
        end
        return
    elseif event == "LFG_LOCK_INFO_RECEIVED" then
        return
    elseif event == "LFG_PROPOSAL_SHOW" then
        return
    elseif event == "LFG_PROPOSAL_FAILED" then
        if DEFAULT_CHAT_FRAME then
            DEFAULT_CHAT_FRAME:AddMessage("|cff00ccff[MidnightUI]|r Queue proposal failed — someone declined or didn't accept.", 1, 0.7, 0.3)
        end
        return
    elseif event == "LFG_PROPOSAL_SUCCEEDED" then
        return
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- Close panel when entering combat
        if Panel.IsOpen() then Panel.Hide() end
        return
    elseif event == "LFG_LIST_APPLICATION_STATUS_UPDATED"
        or event == "LFG_LIST_ACTIVE_ENTRY_UPDATE"
        or event == "LFG_LIST_APPLICANT_LIST_UPDATED" then
        -- F8: Check for new invitations before refreshing
        if Panel._state.activeTab == "premade" then
            local apps = Panel.GetPendingApplications()
            for _, app in ipairs(apps) do
                local prev = Panel._state.prevAppStatuses[app.resultID]
                if app.status == "invited" and prev ~= "invited" then
                    Panel.ShowInviteBanner(app.name)
                    pcall(PlaySound, SOUNDKIT and SOUNDKIT.READY_CHECK or 8960)
                end
                Panel._state.prevAppStatuses[app.resultID] = app.status
            end
            Panel.UpdateListingRows()
            Panel.UpdateGroupIntelSidebar()
            -- MPI: Update applicant panel for group leaders
            if _G.MidnightPI and _G.MidnightPI.OnApplicantListUpdated then _G.MidnightPI.OnApplicantListUpdated(R.playerSidebar) end
        end
        return
    elseif event == "LFG_LIST_SEARCH_RESULTS_RECEIVED" then
        Panel.OnSearchResults()
    elseif event == "LFG_UPDATE" or event == "LFG_QUEUE_STATUS_UPDATE" then
        if Panel._state.activeTab == "dungeons" then
            Panel.UpdateDungeonQueueStatus()
        elseif Panel._state.activeTab == "raids" then
            Panel.UpdateRaidQueueStatus()
        elseif Panel._state.activeTab == "pvp" then
            Panel.UpdatePVPQueueStatus()
        end
    elseif event == "UPDATE_BATTLEFIELD_STATUS" then
        if Panel._state.activeTab == "pvp" then
            Panel.UpdatePVPQueueStatus()
        end
    elseif event == "PVP_RATED_STATS_UPDATE" or event == "HONOR_LEVEL_UPDATE" then
        if Panel._state.activeTab == "pvp" then
            Panel.UpdatePVPHero()
            Panel.UpdatePVPActivities()
        end
    end
end)

-- ============================================================================
-- S10  PVEFRAME HOOK
-- ============================================================================
local hookInstalled = false
local hookGuard = false

local function InstallPVEHook()
    if hookInstalled then return end
    if type(PVEFrame_ToggleFrame) ~= "function" then return end
    hookInstalled = true
    hooksecurefunc("PVEFrame_ToggleFrame", function()
        if hookGuard then return end
        if Panel._state._pvpHandoff then return end  -- let Blizzard PVP UI show
        hookGuard = true
        if PVEFrame and PVEFrame:IsShown() then
            pcall(HideUIPanel, PVEFrame)
        end
        Panel.Toggle()
        C_Timer.After(0, function() hookGuard = false end)
    end)
end

-- Try immediately
InstallPVEHook()

-- Also on ADDON_LOADED in case Blizzard_LookingForGroupUI loads later
local hookEvf = CreateFrame("Frame")
hookEvf:RegisterEvent("ADDON_LOADED")
hookEvf:RegisterEvent("PLAYER_LOGIN")
hookEvf:SetScript("OnEvent", function(_, event, addon)
    if event == "ADDON_LOADED" and (addon == "Blizzard_LookingForGroupUI" or addon == "Blizzard_PVPUI") then
        InstallPVEHook()
        C_Timer.After(0.05, function()
            if Panel._state._pvpHandoff then return end  -- let Blizzard PVP UI show
            if PVEFrame and PVEFrame:IsShown() then
                pcall(HideUIPanel, PVEFrame)
                if not Panel.IsOpen() then Panel.Show() end
            end
        end)
    elseif event == "PLAYER_LOGIN" then
        InstallPVEHook()
    end
end)

-- ============================================================================
-- S11  GLOBAL EXPORTS
-- ============================================================================
_G.MidnightUI_GroupFinder_Toggle = function() Panel.Toggle() end
_G.MidnightUI_GroupFinder_Show   = function(tab) Panel.Show(tab) end
_G.MidnightUI_GroupFinder_Hide   = function() Panel.Hide() end
