-- =============================================================================
-- FILE PURPOSE:     Zone-aware achievement tracker panel. Scans all achievements
--                   asynchronously (SCAN_CHUNK=80 per tick via C_Timer) and buckets
--                   them into: here / seasonal / progress / nearby / undiscovered /
--                   completed. Displays each achievement with icon, name, criteria
--                   progress bar, and inline-expandable criteria list. Includes
--                   search/filter and an async re-scan on zone change.
-- LOAD ORDER:       Loads after QuestInterface.lua, before CharacterPanel.lua.
--                   No shared Addon namespace (standalone file, no early-exit guard).
-- DEFINES:          "MidnightAchievementsPanel" frame (file-local, opened via keybind/hook).
--                   CFG{} — all layout dimensions, BUCKET_COLORS, BUCKET_ORDER,
--                   SCAN_CHUNK, SLIDE_DUR.
--                   THEME{} — local warm-parchment color palette (matches QuestInterface).
--                   TC(key) — resolves from THEME first, then falls back to Addon.MapConfig.
-- READS:            C_AchievementInfo.GetAchievementInfo, GetAchievementCriteriaInfo,
--                   GetAchievementNumCriteria — iterates all achievements (async chunks).
--                   C_Map.GetBestMapForUnit, C_Map.GetMapInfo — zone context for bucketing.
--                   MidnightUISettings.General (feature gates, if any).
-- WRITES:           Nothing persistent — achievement completion is tracked by Blizzard.
--                   Panel show/hide state is file-local.
-- DEPENDS ON:       C_AchievementInfo (Blizzard), C_Map (Blizzard).
--                   Addon.MapConfig (optional — TC() falls back to it for theme colors).
-- USED BY:          Nothing — opened via a keybind or UI button hook. Self-contained.
-- KEY FLOWS:
--   Panel:Show() → StartScan() — async scanner: GetAchievementInfo(id) per chunk of 80,
--     C_Timer.After(0) yields between chunks to avoid frame drops on large achievement lists.
--   Scan complete → BucketAchievements() → render sorted rows per BUCKET_ORDER
--   Row click → inline expand (criteria list with per-criterion progress bars)
--   Search input → live filter against achievement name/description
--   PLAYER_ENTERING_WORLD → RequestScan() — re-bucket on zone change (zone achievements move)
-- GOTCHAS:
--   Async scanner: SCAN_CHUNK controls per-frame budget. Lower = smoother but slower initial load.
--   Achievement IDs are not contiguous — scanner must iterate a known ID range and skip
--   nil returns from GetAchievementInfo (returns nil for invalid IDs).
--   "here" bucket: achievement must match current zone mapID — changes on every zone transition.
--   "seasonal" bucket: detected by category or achievement flags (time-limited events).
--   TC() first checks the local THEME table (faster), then falls back to Addon.MapConfig.GetThemeColor.
-- NAVIGATION:
--   CFG{}             — dimensions, buckets (line ~46)
--   THEME{}           — color palette (line ~15)
--   StartScan()       — async achievement scanner (search "function StartScan")
--   BucketAchievements() — sorting into buckets (search "function BucketAchievements")
-- =============================================================================

local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then ADDON_NAME = "MidnightUI" end
if type(Addon) ~= "table" then Addon = {} end

local W8 = "Interface\\Buttons\\WHITE8x8"

-- ── Theme Colors ────────────────────────────────────────────────────────
-- Matches QuestInterface warm-parchment palette; falls back to MapConfig.
local THEME = {
    frameBg         = { 0.07, 0.06, 0.04, 0.97 },
    contentBg       = { 0.09, 0.075, 0.05, 0.97 },
    headerBg        = { 0.05, 0.04, 0.025, 0.95 },
    cardBg          = { 0.12, 0.10, 0.065, 0.60 },
    cardBgHover     = { 0.18, 0.15, 0.10, 0.60 },
    heroBg          = { 0.10, 0.08, 0.05, 0.80 },
    border          = { 0.76, 0.67, 0.46 },
    borderDim       = { 0.50, 0.42, 0.28 },
    divider         = { 0.60, 0.52, 0.35 },
    accent          = { 0.72, 0.62, 0.42 },
    titleText       = { 0.96, 0.87, 0.58 },
    bodyText        = { 0.94, 0.90, 0.80 },
    sectionText     = { 0.90, 0.78, 0.48 },
    mutedText       = { 0.71, 0.62, 0.44 },
    dimText         = { 0.52, 0.46, 0.34 },
    progressTrack   = { 0.20, 0.17, 0.12, 0.35 },
    progressFill    = { 0.72, 0.62, 0.42, 0.70 },
    success         = { 0.40, 0.80, 0.45 },
    successDim      = { 0.34, 0.68, 0.38 },
}

local function TC(key)
    local c = THEME[key]
    if c then return c[1], c[2], c[3], c[4] or 1 end
    local MC = Addon.MapConfig
    if MC and type(MC.GetThemeColor) == "function" then return MC.GetThemeColor(key) end
    return 1, 1, 1, 1
end

-- ── Configuration ───────────────────────────────────────────────────────
local CFG = {
    WIDTH               = 960,
    HEIGHT              = 720,
    HEADER_H            = 44,
    HERO_H              = 100,
    SEARCH_H            = 30,
    BUCKET_H            = 34,
    ROW_H               = 66,
    ROW_GAP             = 1,
    EXPANSION_PAD       = 10,
    CRITERIA_H          = 22,
    MAX_CRITERIA        = 12,
    PROGRESS_BAR_W      = 120,
    PROGRESS_BAR_H      = 4,
    ICON_SIZE           = 36,
    PILL_H              = 18,
    SCAN_CHUNK          = 80,
    SLIDE_DUR           = 0.20,
    STRATA              = "HIGH",

    BUCKET_COLORS = {
        here         = { r = 0.98, g = 0.60, b = 0.22, label = "HERE" },
        seasonal     = { r = 0.40, g = 0.78, b = 0.90, label = "SEASONAL" },
        progress     = { r = 0.70, g = 0.42, b = 0.85, label = "IN PROGRESS" },
        nearby       = { r = 0.40, g = 0.65, b = 0.92, label = "NEARBY" },
        undiscovered = { r = 0.60, g = 0.58, b = 0.55, label = "UNDISCOVERED" },
        completed    = { r = 0.40, g = 0.80, b = 0.45, label = "COMPLETED" },
    },
    BUCKET_ORDER = { "here", "seasonal", "progress", "nearby", "undiscovered", "completed" },

    -- Sub-groups within UNDISCOVERED, rendered as sub-headers
    UNDISCOVERED_SUBS = {
        { key = "zone",      label = "CURRENT ZONE" },
        { key = "nearby",    label = "NEARBY ZONES" },
        { key = "continent", label = "SAME CONTINENT" },
    },
    UNDISCOVERED_SUB_ORDER = { "zone", "nearby", "continent" },
    UNDISCOVERED_CAPS = { zone = 200, nearby = 100, continent = 150 },
    SUBHEADER_H         = 24,

    -- Content type filters — derived from WoW's top-level achievement categories.
    -- The key is a short label; match patterns are checked against the category root chain.
    CONTENT_TYPES = {
        { key = "all",          label = "ALL" },
        { key = "exploration",  label = "EXPLORE",   patterns = { "Exploration" } },
        { key = "quests",       label = "QUESTS",    patterns = { "Quests" } },
        { key = "dungeons",     label = "DUNGEONS",  patterns = { "Dungeons & Raids", "Dungeon" } },
        { key = "raids",        label = "RAIDS",     patterns = { "Dungeons & Raids", "Raid" } },
        { key = "pvp",          label = "PVP",       patterns = { "Player vs. Player", "PvP" } },
        { key = "professions",  label = "PROFESSIONS", patterns = { "Professions", "Tradeskill" } },
        { key = "reputation",   label = "REPUTATION", patterns = { "Reputation" } },
        { key = "collections",  label = "COLLECT",   patterns = { "Collections", "Pet Battles" } },
        { key = "feats",        label = "FEATS",     patterns = { "Feats of Strength", "Legacy" } },
        { key = "general",      label = "GENERAL",   patterns = { "General" } },
    },

    TAG_COLORS = {
        FEAT     = { r = 0.90, g = 0.80, b = 0.50 },
        SEASONAL = { r = 0.40, g = 0.78, b = 0.90 },
        RAID     = { r = 0.90, g = 0.30, b = 0.30 },
        DUNGEON  = { r = 0.85, g = 0.55, b = 0.20 },
        PTS      = { r = 1.00, g = 0.84, b = 0.28 },
    },

    -- WoW holiday names → category keywords for matching.
    -- Keys are used to match calendar event titles; values are category search terms.
    -- Calendar event title → category keyword for matching.
    -- nil values = recognized but no seasonal achievements to track.
    HOLIDAYS = {
        -- ── Major holidays (with achievement categories) ──
        ["Lunar New Year"]              = "Lunar",
        ["Lunar Festival"]              = "Lunar",
        ["Love is in the Air"]          = "Love is in the Air",
        ["Noblegarden"]                 = "Noblegarden",
        ["Children's Week"]             = "Children",
        ["Midsummer Fire Festival"]     = "Midsummer",
        ["Midsummer"]                   = "Midsummer",
        ["Brewfest"]                    = "Brewfest",
        ["Hallow's End"]                = "Hallow",
        ["Pilgrim's Bounty"]            = "Pilgrim",
        ["Feast of Winter Veil"]        = "Winter Veil",
        ["Winter Veil"]                 = "Winter Veil",
        ["Day of the Dead"]             = "Day of the Dead",
        ["Pirates' Day"]                = "Pirates",
        ["Darkmoon Faire"]              = "Darkmoon Faire",
        ["WoW's Anniversary"]           = "Anniversary",
        ["WoW Anniversary"]             = "Anniversary",

        -- ── Minor holidays & micro-holidays ──
        ["Harvest Festival"]            = "Harvest",
        ["Fireworks Spectacular"]        = "Fireworks",
        ["New Year's Eve"]              = "New Year",
        ["New Year"]                    = "New Year",
        ["Call of the Scarab"]          = "Call of the Scarab",
        ["Hatching of the Hippogryphs"] = "Hatching of the Hippogryphs",
        ["Un'Goro Madness"]             = "Un'Goro Madness",
        ["March of the Tadpoles"]       = "March of the Tadpoles",
        ["Volunteer Guard Day"]         = "Volunteer Guard Day",
        ["Spring Balloon Festival"]     = "Spring Balloon Festival",
        ["Glowcap Festival"]            = "Glowcap Festival",
        ["Thousand Boat Bash"]          = "Thousand Boat Bash",
        ["Auction House Dance Party"]   = "Auction House Dance Party",
        ["Trial of Style"]              = "Trial of Style",
        ["Great Gnomeregan Run"]        = "Great Gnomeregan Run",
        ["Moonkin Festival"]            = "Moonkin Festival",
        ["Kirin Tor Tavern Crawl"]      = "Kirin Tor Tavern Crawl",

        -- ── Recurring bonus events ──
        ["Timewalking"]                 = "Timewalking",
        ["Plunderstorm"]                = "Plunderstorm",
        ["Remix"]                       = "Remix",

        -- ── PvP / bonus events (no seasonal achievements) ──
        ["Arena Skirmish"]              = nil,
        ["Battleground Bonus"]          = nil,
        ["Pet Battle Bonus"]            = nil,
    },

    -- Keywords for identifying seasonal achievement categories.
    -- Used both for category scanning and tag detection.
    SEASONAL_KEYWORDS = {
        -- Major holidays
        "Lunar", "Love is in the Air", "Noblegarden", "Children",
        "Midsummer", "Brewfest", "Hallow", "Pilgrim", "Winter Veil",
        "Day of the Dead", "Pirates", "Darkmoon Faire", "Anniversary",
        -- Minor holidays
        "Harvest", "Fireworks", "New Year",
        "Call of the Scarab", "Hatching of the Hippogryphs",
        "Un'Goro Madness", "March of the Tadpoles",
        "Volunteer Guard Day", "Spring Balloon Festival",
        "Glowcap Festival", "Thousand Boat Bash",
        "Auction House Dance Party", "Trial of Style",
        "Great Gnomeregan Run", "Moonkin Festival",
        "Kirin Tor Tavern Crawl",
        -- Recurring events
        "Timewalking", "Plunderstorm", "Remix",
        -- Meta categories
        "World Events", "Holidays",
    },
}

-- ── Helpers ──────────────────────────────────────────────────────────────
local function Clamp(v, lo, hi) return v < lo and lo or (v > hi and hi or v) end

local function ApplyGradient(tex, orient, r1, g1, b1, a1, r2, g2, b2, a2)
    if not tex then return end
    if type(tex.SetGradientAlpha) == "function" then
        tex:SetGradientAlpha(orient, r1, g1, b1, a1, r2, g2, b2, a2)
    elseif type(tex.SetGradient) == "function" and CreateColor then
        tex:SetGradient(orient, CreateColor(r1, g1, b1, a1), CreateColor(r2, g2, b2, a2))
    end
end

local function BucketColor(key)
    local c = CFG.BUCKET_COLORS[key] or CFG.BUCKET_COLORS.nearby
    return c.r, c.g, c.b
end

-- ── Panel State ─────────────────────────────────────────────────────────
local Panel = {}
_G.MidnightUI_AchievementsPanel = Panel  -- Set early for Minimap.lua

Panel._state = {
    initialized = false, panelOpen = false, panel = nil,
    currentZone = "", currentMapID = nil, parentMapID = nil, siblingMapIDs = {},
    expanded = {}, bucketCollapse = { completed = true }, subBucketCollapse = {}, searchFilter = "",
    buckets = {
        here_ids = {}, seasonal_ids = {}, progress_ids = {}, nearby_ids = {},
        undiscovered_ids = { zone = {}, nearby = {}, continent = {} },
        completed_ids = {},
    },
    zoneCacheKey = nil,
    asyncScanning = false, asyncTimer = nil, asyncSeenIDs = {},
    activeBucket = nil,  -- nil = show all, or a bucket key for filtered view
    activeContentType = nil,  -- nil = all, or a content type key for filtered view
    cacheScanTimer = nil,   -- timer handle for background cache build
    cacheScanRunning = false,
    -- Virtual scroll state
    displayList = {},        -- flat array of display items
    totalHeight = 0,         -- total scroll height
    visibleStart = 0,        -- first visible display list index
    visibleEnd = 0,          -- last visible display list index
    lastScrollOffset = -1,   -- debounce scroll updates
    sortKeys = {},           -- achID -> progress value for sorting
}


-- Send a message to the Diagnostics Console
local function DiagPrint(label, msg)
    if _G.MidnightUI_Diagnostics and _G.MidnightUI_Diagnostics.LogExternal then
        _G.MidnightUI_Diagnostics.LogExternal(
            "AchTracker", label .. "\n" .. msg, "", "", "batch=true", "Debug"
        )
    end
end


-- ============================================================================
-- PERSISTENT ACHIEVEMENT-ZONE CACHE (SavedVariables)
-- ============================================================================
-- MidnightUIAchCache persists across sessions. Schema:
--   version        = schema version (bump to force full rescan)
--   maxScannedID   = highest achievement ID processed in last full scan
--   mapIndex       = { [mapID] = { [achID] = confidence, ... } }
--   achMaps        = { [achID] = { mapID, mapID, ... } }
--   flags          = { [achID] = bitfield }  -- 1=unobtainable, 2=guild, 4=statistic
--   scanComplete   = bool
--   lastScanTime   = server time of last completed scan
--
-- Confidence scores: 3=category hierarchy, 2=criteria-based, 1=text scanning

local CACHE_VERSION = 1
local CONF_CATEGORY  = 3
local CONF_CRITERIA  = 2
local CONF_TEXT      = 1

-- Flags bitfield
local FLAG_UNOBTAINABLE = 1
local FLAG_GUILD        = 2
local FLAG_STATISTIC    = 4

-- Local ref, populated from SavedVariables once ADDON_LOADED fires
local AchCache = nil

local function GetGameBuild()
    local _, build = GetBuildInfo()
    return build or "0"
end

local function InitAchCache()
    if not _G.MidnightUIAchCache or _G.MidnightUIAchCache.version ~= CACHE_VERSION then
        _G.MidnightUIAchCache = {
            version      = CACHE_VERSION,
            maxScannedID = 0,
            mapIndex     = {},
            achMaps      = {},
            flags        = {},
            scanComplete = false,
            lastScanTime = 0,
            build        = GetGameBuild(),
            progressIDs  = {},  -- cached in-progress achievement IDs from last session
        }
    end
    -- Ensure progressIDs exists for older caches
    if not _G.MidnightUIAchCache.progressIDs then _G.MidnightUIAchCache.progressIDs = {} end
    AchCache = _G.MidnightUIAchCache
end

-- Store a mapID → achID association, avoiding duplicates
local function CacheAchToMap(achID, mapID, confidence)
    if not AchCache or not mapID or mapID <= 0 then return end

    -- mapIndex: mapID → { achID = confidence }
    local mi = AchCache.mapIndex
    if not mi[mapID] then mi[mapID] = {} end
    local existing = mi[mapID][achID]
    if not existing or confidence > existing then
        mi[mapID][achID] = confidence
    end

    -- achMaps: achID → { mapID, ... }  (ordered array, no dupes)
    local am = AchCache.achMaps
    if not am[achID] then
        am[achID] = { mapID }
    else
        local found = false
        for _, m in ipairs(am[achID]) do
            if m == mapID then found = true; break end
        end
        if not found then am[achID][#am[achID] + 1] = mapID end
    end
end

local function CacheAchFlag(achID, flag)
    if not AchCache then return end
    local cur = AchCache.flags[achID] or 0
    if bit.band(cur, flag) == 0 then
        AchCache.flags[achID] = bit.bor(cur, flag)
    end
end

local function IsCacheFlagged(achID, flag)
    if not AchCache then return false end
    local f = AchCache.flags[achID]
    return f and bit.band(f, flag) ~= 0
end

-- Get all cached achievement IDs for a mapID (returns table or empty)
local function GetCachedAchsForMap(mapID)
    if not AchCache or not AchCache.mapIndex[mapID] then return {} end
    return AchCache.mapIndex[mapID]
end

-- Get all cached mapIDs for an achievement (returns array or empty)
local function GetCachedMapsForAch(achID)
    if not AchCache or not AchCache.achMaps[achID] then return {} end
    return AchCache.achMaps[achID]
end

-- Check if cache has been fully built at least once
local function IsCacheReady()
    return AchCache and AchCache.scanComplete
end


-- ============================================================================
-- DATA LAYER — Intelligent zone-aware achievement classification
-- ============================================================================

-- ── Map Name Index ──────────────────────────────────────────────────────
-- Walks the entire WoW map hierarchy once and builds:
--   _mapNameIndex[lowercased_name] = { mapID, ancestors = {id, id, ...} }
-- Ancestors are ordered root→leaf (e.g., {947=Azeroth, 13=EK, ...})

local _mapNameIndex = nil    -- name:lower() -> { mapID, ancestors }
local _mapAncestors = {}     -- mapID -> { parentID, grandparentID, ... } (root first)

local function GetMapAncestorChain(mapID)
    if _mapAncestors[mapID] then return _mapAncestors[mapID] end
    local chain = {}
    local visited = {}
    local cur = mapID
    while cur do
        local info = C_Map.GetMapInfo(cur)
        if not info or visited[cur] then break end
        visited[cur] = true
        cur = info.parentMapID
        if cur then table.insert(chain, 1, cur) end
    end
    _mapAncestors[mapID] = chain
    return chain
end

local function BuildMapNameIndex()
    if _mapNameIndex then return _mapNameIndex end
    _mapNameIndex = {}
    local visited = {}

    local function Walk(mapID)
        if visited[mapID] then return end
        visited[mapID] = true
        local info = C_Map.GetMapInfo(mapID)
        if not info then return end

        if info.name and info.name ~= "" and #info.name >= 4 then
            local key = info.name:lower()
            if not _mapNameIndex[key] then
                _mapNameIndex[key] = {
                    mapID = mapID,
                    ancestors = GetMapAncestorChain(mapID),
                    name = info.name,
                }
            end
        end

        -- Recurse into children (all map types)
        local ok, children = pcall(C_Map.GetMapChildrenInfo, mapID)
        if ok and children then
            for _, child in ipairs(children) do Walk(child.mapID) end
        end
    end

    -- Start from Cosmic (946) to cover everything
    Walk(946)
    -- Also try common alternate roots in case 946 doesn't cover all
    for _, root in ipairs({947, 113, 101, 1978, 2274}) do Walk(root) end

    local count = 0; for _ in pairs(_mapNameIndex) do count = count + 1 end
    return _mapNameIndex
end

-- Build breadcrumb chain for display (unchanged)
local function BuildMapBreadcrumbs(mapID)
    if not mapID then return {} end
    local chain = {}
    local visited = {}
    local current = mapID
    while current do
        if visited[current] then break end
        visited[current] = true
        local info = C_Map.GetMapInfo(current)
        if not info then break end
        if info.mapType and info.mapType > 0 then
            table.insert(chain, 1, info.name or "")
        end
        current = info.parentMapID
    end
    return chain
end

-- ── Zone Reference Scanner ──────────────────────────────────────────────
-- Scans text for known zone/location names.
-- Results are cached per achievement ID (text content is static).

local _achTextCache = {}    -- achID -> concatenated text
local _achRefsCache = {}    -- achID -> { [mapID] = indexEntry }

local function GetAchievementFullText(achID)
    if _achTextCache[achID] then return _achTextCache[achID] end
    local _, _, _, _, _, _, _, desc = GetAchievementInfo(achID)
    local parts = { desc or "" }
    local n = GetAchievementNumCriteria(achID)
    if n and n > 0 then
        for i = 1, n do
            local cStr = GetAchievementCriteriaInfo(achID, i)
            if cStr and cStr ~= "" then parts[#parts + 1] = cStr end
        end
    end
    local text = table.concat(parts, " ")
    _achTextCache[achID] = text
    return text
end

local function FindZoneRefsInText(achID, text)
    if _achRefsCache[achID] then return _achRefsCache[achID] end
    if not text or text == "" then _achRefsCache[achID] = {}; return {} end
    local index = BuildMapNameIndex()
    local textLower = text:lower()
    local refs = {}
    for name, data in pairs(index) do
        if textLower:find(name, 1, true) then
            refs[data.mapID] = data
        end
    end
    _achRefsCache[achID] = refs
    return refs
end

-- ============================================================================
-- THREE-TIER ZONE CLASSIFICATION
-- Tier 1: Category hierarchy (GetAchievementCategory → walk parents → match mapIDs)
-- Tier 2: Criteria type analysis (quest zones, sub-achievement categories)
-- Tier 3: Text scanning (description + criteria text for zone names)
-- ============================================================================

-- ── Tier 1: Category Hierarchy ──────────────────────────────────────────
-- Use GetAchievementCategory(id) to get the real category, then walk up
-- the parent chain looking for category names that match known map names.

local _catMapIDCache = {}  -- categoryID -> mapID or false

local function GetCategoryMapID(catID)
    if _catMapIDCache[catID] ~= nil then return _catMapIDCache[catID] end
    local index = BuildMapNameIndex()
    local catName = GetCategoryInfo(catID)
    if catName and catName ~= "" then
        local entry = index[catName:lower()]
        if entry then
            _catMapIDCache[catID] = entry.mapID
            return entry.mapID
        end
    end
    _catMapIDCache[catID] = false
    return false
end

-- Reverse index: mapID → set of category IDs that resolve to that mapID.
-- Built once, cached permanently (category→mapID is static game data).
local _mapToCatsCache = nil

local function BuildMapToCategoryIndex()
    if _mapToCatsCache then return _mapToCatsCache end
    _mapToCatsCache = {}
    local cats = GetCategoryList()
    if not cats then return _mapToCatsCache end
    for _, catID in ipairs(cats) do
        local mid = GetCategoryMapID(catID)
        if mid then
            if not _mapToCatsCache[mid] then _mapToCatsCache[mid] = {} end
            _mapToCatsCache[mid][catID] = true
        end
    end
    return _mapToCatsCache
end

-- Get all achievement categories associated with a specific mapID
local function GetCategoriesForMapID(targetMapID)
    local idx = BuildMapToCategoryIndex()
    return idx[targetMapID] or {}
end

-- Walk an achievement's category chain and collect all mapIDs found
local function GetAchievementCategoryMapIDs(achID)
    local catID = GetAchievementCategory(achID)
    if not catID then return {} end
    local mapIDs = {}
    local visited = {}
    local cur = catID
    while cur and not visited[cur] do
        visited[cur] = true
        local mid = GetCategoryMapID(cur)
        if mid then mapIDs[mid] = BuildMapNameIndex()[C_Map.GetMapInfo(mid) and C_Map.GetMapInfo(mid).name:lower()] or { mapID = mid, ancestors = GetMapAncestorChain(mid) } end
        local _, parentID = GetCategoryInfo(cur)
        if not parentID or parentID <= 0 then break end
        cur = parentID
    end
    return mapIDs
end

-- ── Tier 2: Criteria Type Analysis ──────────────────────────────────────
-- Criteria type 27 = quest (quest has a zone via C_TaskQuest or C_QuestLog)
-- Criteria type 8  = sub-achievement (check sub-achievement's category)
-- Criteria type 36 = item (limited zone info, skip)
-- Criteria type 11 = kill NPC (limited zone info, skip)

local function GetCriteriaZoneRefs(achID)
    local refs = {}
    local index = BuildMapNameIndex()
    local n = GetAchievementNumCriteria(achID)
    if not n or n == 0 then return refs end

    for i = 1, n do
        local _, criteriaType, cDone, _, _, _, _, assetID = GetAchievementCriteriaInfo(achID, i)
        if not cDone and assetID and assetID > 0 then
            if criteriaType == 8 then
                -- Sub-achievement: check its category hierarchy for mapIDs
                local subMaps = GetAchievementCategoryMapIDs(assetID)
                for mid, data in pairs(subMaps) do refs[mid] = data end
            elseif criteriaType == 27 then
                -- Quest: try to get its zone
                local questMapID = nil
                if C_TaskQuest and C_TaskQuest.GetQuestZoneID then
                    questMapID = C_TaskQuest.GetQuestZoneID(assetID)
                end
                if not questMapID and C_QuestLog and C_QuestLog.GetQuestAdditionalHighlights then
                    -- Fallback: some quests expose their zone through the map system
                    local qInfo = C_QuestLog.GetInfo and C_QuestLog.GetInfo(assetID)
                    -- Limited API access for quests not in the log
                end
                if questMapID and questMapID > 0 then
                    local qInfo = C_Map.GetMapInfo(questMapID)
                    if qInfo and qInfo.name then
                        local entry = index[qInfo.name:lower()]
                        if entry then refs[questMapID] = entry end
                    end
                end
            end
        end
    end
    return refs
end

-- ── Tier 3: Text Scanning (existing approach, now a fallback) ───────────
local function GetTextZoneRefs(achID)
    local index = BuildMapNameIndex()
    local n = GetAchievementNumCriteria(achID)
    local totalIncomplete = 0
    local textParts = {}

    -- Include description
    local _, _, _, _, _, _, _, desc = GetAchievementInfo(achID)
    if desc and desc ~= "" then textParts[#textParts + 1] = desc end

    -- Include incomplete criteria text
    if n and n > 0 then
        for i = 1, n do
            local cStr, _, cDone = GetAchievementCriteriaInfo(achID, i)
            if not cDone then
                totalIncomplete = totalIncomplete + 1
                if cStr and cStr ~= "" then textParts[#textParts + 1] = cStr end
            end
        end
    end

    local fullText = table.concat(textParts, " "):lower()
    local refs = {}
    if fullText ~= "" then
        for name, data in pairs(index) do
            if fullText:find(name, 1, true) then
                refs[data.mapID] = data
            end
        end
    end
    return refs, totalIncomplete
end

-- ── Combined: Merge all three tiers ─────────────────────────────────────
local _achZoneCache = {}  -- achID -> { refs, total, tier }

local function GetAchievementZoneRefs(achID)
    if _achZoneCache[achID] then
        return _achZoneCache[achID].refs, _achZoneCache[achID].total
    end

    local allRefs = {}
    local totalIncomplete = 0

    -- Tier 1: Category hierarchy (most reliable)
    local catRefs = GetAchievementCategoryMapIDs(achID)
    for mid, data in pairs(catRefs) do allRefs[mid] = data end

    -- Tier 2: Criteria type analysis
    local critRefs = GetCriteriaZoneRefs(achID)
    for mid, data in pairs(critRefs) do allRefs[mid] = data end

    -- Tier 3: Text scanning (fallback)
    local textRefs, totalInc = GetTextZoneRefs(achID)
    totalIncomplete = totalInc
    for mid, data in pairs(textRefs) do
        if not allRefs[mid] then allRefs[mid] = data end
    end

    _achZoneCache[achID] = { refs = allRefs, total = totalIncomplete }
    return allRefs, totalIncomplete
end

-- ── Proximity Classification ────────────────────────────────────────────
-- Depth-aware proximity using map hierarchy:
--
--   Player in Silvermoon City:
--     Breadcrumb: Azeroth > Eastern Kingdoms > Quel'Thalas > Eversong Woods > Silvermoon City
--
--   Strategy: process zone-level refs first (precise), then fall back to
--   continent-level refs as a softer signal.
--
--   HERE:    zone matches player's zone or parent zone (Silvermoon City / Eversong Woods)
--   NEARBY:  zone is in the same region (Quel'Thalas siblings) or same continent
--   NEARBY:  continent-level ref matches player's continent (fallback — less precise)
--   nil:     no geographic overlap at all

local _mapTypeCache = {}
local function GetMapType(mapID)
    if _mapTypeCache[mapID] ~= nil then return _mapTypeCache[mapID] end
    local info = C_Map.GetMapInfo(mapID)
    local mt = info and info.mapType or false
    _mapTypeCache[mapID] = mt
    return mt
end

-- totalIncomplete: how many incomplete criteria the achievement has (from GetAchievementZoneRefs)
-- Used for ratio-based downgrade: if an achievement has 60 zone criteria spread worldwide
-- and only 1-2 match the player's area, that's too weak for HERE → downgrade to NEARBY.
local function ClassifyProximity(refMapIDs, playerMapID, totalIncomplete)
    if not playerMapID or not refMapIDs or not next(refMapIDs) then return nil end

    local playerAnc = GetMapAncestorChain(playerMapID)
    local playerParent = playerAnc[#playerAnc]
    local playerRegion = #playerAnc >= 2 and playerAnc[#playerAnc - 1] or nil
    local playerContinent = nil
    for _, aid in ipairs(playerAnc) do
        if GetMapType(aid) == Enum.UIMapType.Continent then
            playerContinent = aid; break
        end
    end

    local playerChainSet = { [playerMapID] = true }
    for _, aid in ipairs(playerAnc) do playerChainSet[aid] = true end

    -- Separate refs into zone-level (precise) and continent/broad (fallback)
    local zoneRefs = {}
    local broadRefs = {}
    local totalZoneRefs = 0
    for refMapID, refData in pairs(refMapIDs) do
        local mt = GetMapType(refMapID)
        if mt and mt ~= false and mt <= Enum.UIMapType.Continent then
            broadRefs[refMapID] = refData
        else
            zoneRefs[refMapID] = refData
            totalZoneRefs = totalZoneRefs + 1
        end
    end

    -- ── Pass 1: Zone-level refs (precise matching) ──
    local hereCount = 0     -- how many zone refs match HERE proximity
    local hereMatches = {}  -- names of zones that matched HERE
    local isNearby = false

    for refMapID, refData in pairs(zoneRefs) do
        local isHere = false

        -- Direct match: player IS in this zone
        if refMapID == playerMapID then isHere = true end

        -- Reference is the player's parent zone
        if not isHere and playerParent and refMapID == playerParent then isHere = true end

        -- Player is the parent of the referenced zone
        if not isHere and refData.ancestors and refData.ancestors[#refData.ancestors] == playerMapID then
            isHere = true
        end

        -- Sibling zones (share the same parent)
        if not isHere and playerParent and refData.ancestors then
            local refParent = refData.ancestors[#refData.ancestors]
            if refParent == playerParent then isHere = true end
        end

        if isHere then
            hereCount = hereCount + 1
            if refData.name then hereMatches[#hereMatches + 1] = refData.name end
        else
            -- Same region = NEARBY
            if playerRegion then
                if refMapID == playerRegion then
                    isNearby = true
                elseif refData.ancestors then
                    for _, anc in ipairs(refData.ancestors) do
                        if anc == playerRegion then isNearby = true; break end
                    end
                end
            end

            -- Same continent but different region = NEARBY
            if not isNearby and playerContinent and refData.ancestors then
                for _, anc in ipairs(refData.ancestors) do
                    if anc == playerContinent then isNearby = true; break end
                end
            end
        end
    end

    -- ── Ratio check: is the HERE signal strong enough? ──
    -- For achievements with many zone criteria spread worldwide (e.g., "battle in 67 zones"),
    -- a single matching zone is too weak. Require meaningful local concentration.
    -- Returns: proximity, hereMatches (table of matched zone names for display)
    if hereCount > 0 then
        totalIncomplete = totalIncomplete or totalZoneRefs
        if totalIncomplete > 15 then
            local ratio = hereCount / totalIncomplete
            if ratio < 0.20 then
                -- Too diluted — downgrade to NEARBY but pass matched zones
                return "nearby", hereMatches
            end
        end
        return "here", hereMatches
    end

    if isNearby then return "nearby", nil end

    -- ── Pass 2: Continent-level refs (soft fallback) ──
    for refMapID, _ in pairs(broadRefs) do
        if playerChainSet[refMapID] then
            return "nearby", nil
        end
    end

    return nil, nil
end

-- ── Cheap Undiscovered Classification ────────────────────────────────────
-- Uses ONLY category hierarchy (Tier 1) for speed. No text scanning.
-- Returns: "zone", "nearby", "continent", or "other"

local function ClassifyUndiscoveredTier(achID, playerMapID)
    if not playerMapID then return "other" end

    -- Fast: only check category-derived mapIDs
    local catRefs = GetAchievementCategoryMapIDs(achID)
    if not next(catRefs) then return "other" end

    local playerAnc = GetMapAncestorChain(playerMapID)
    local playerParent = playerAnc[#playerAnc]
    local playerRegion = #playerAnc >= 2 and playerAnc[#playerAnc - 1] or nil
    local playerContinent = nil
    for _, aid in ipairs(playerAnc) do
        if GetMapType(aid) == Enum.UIMapType.Continent then
            playerContinent = aid; break
        end
    end

    local isNearby, isContinent = false, false

    for refMapID, refData in pairs(catRefs) do
        local mt = GetMapType(refMapID)
        -- Skip continent-level refs for "zone" classification
        if mt and mt ~= false and mt <= Enum.UIMapType.Continent then
            -- Check continent match
            if playerContinent and refMapID == playerContinent then isContinent = true end
            -- Check if player is inside this broad area
            local playerSet = { [playerMapID] = true }
            for _, a in ipairs(playerAnc) do playerSet[a] = true end
            if playerSet[refMapID] then isContinent = true end
        else
            -- Zone-level ref
            if refMapID == playerMapID then return "zone" end
            if playerParent and refMapID == playerParent then return "zone" end
            if refData.ancestors and refData.ancestors[#refData.ancestors] == playerMapID then return "zone" end
            if playerParent and refData.ancestors then
                local refParent = refData.ancestors[#refData.ancestors]
                if refParent == playerParent then return "zone" end
            end
            -- Region check
            if playerRegion then
                if refMapID == playerRegion then isNearby = true
                elseif refData.ancestors then
                    for _, anc in ipairs(refData.ancestors) do
                        if anc == playerRegion then isNearby = true; break end
                    end
                end
            end
            -- Continent check
            if playerContinent and refData.ancestors then
                for _, anc in ipairs(refData.ancestors) do
                    if anc == playerContinent then isContinent = true; break end
                end
            end
        end
    end

    if isNearby then return "nearby" end
    if isContinent then return "continent" end
    return "other"
end


-- ============================================================================
-- ENHANCED CLASSIFICATION ENGINE
-- Multi-tier heuristics that go beyond category name matching to associate
-- achievements with mapIDs. Results are stored in the persistent cache.
-- ============================================================================

-- ── Instance Name Index ─────────────────────────────────────────────────
-- Builds dungeon/raid name → mapID from the Encounter Journal API.
-- Catches achievements under "Dungeons & Raids" that reference instances by name.

local _instanceNameIndex = nil  -- lowercase name → mapID

local function BuildInstanceNameIndex()
    if _instanceNameIndex then return _instanceNameIndex end
    _instanceNameIndex = {}

    -- EJ_GetInstanceByIndex(index, isRaid) iterates all instances
    if not EJ_GetInstanceByIndex then return _instanceNameIndex end

    for _, isRaid in ipairs({ false, true }) do
        local i = 1
        while true do
            local instID = EJ_GetInstanceByIndex(i, isRaid)
            if not instID then break end
            local name, _, _, _, _, _, dungeonAreaMapID = EJ_GetInstanceInfo(instID)
            if name and name ~= "" then
                local key = name:lower()
                -- dungeonAreaMapID is the map shown in the EJ; also try to get
                -- the actual instance mapID via the EJ navigation
                if dungeonAreaMapID and dungeonAreaMapID > 0 then
                    _instanceNameIndex[key] = dungeonAreaMapID
                end
            end
            i = i + 1
        end
    end

    -- Also walk all tiers of the EJ if available
    if EJ_GetNumTiers then
        for tier = 1, (EJ_GetNumTiers() or 0) do
            if EJ_SelectTier then EJ_SelectTier(tier) end
            for _, isRaid in ipairs({ false, true }) do
                local i = 1
                while true do
                    local instID = EJ_GetInstanceByIndex(i, isRaid)
                    if not instID then break end
                    local name, _, _, _, _, _, dungeonAreaMapID = EJ_GetInstanceInfo(instID)
                    if name and name ~= "" and dungeonAreaMapID and dungeonAreaMapID > 0 then
                        local key = name:lower()
                        if not _instanceNameIndex[key] then
                            _instanceNameIndex[key] = dungeonAreaMapID
                        end
                    end
                    i = i + 1
                end
            end
        end
    end

    local count = 0; for _ in pairs(_instanceNameIndex) do count = count + 1 end
    return _instanceNameIndex
end

-- ── Exploration Category Mining ─────────────────────────────────────────
-- The "Exploration" root category has per-zone subcategories. Walk the entire
-- tree and map every subcategory's achievements to its zone mapID.

local _explorationMined = false

-- Synchronous exploration mining — only called during chunked cache build,
-- NOT at startup. Deferred to avoid frame hitches.
local function MineExplorationCategories()
    if _explorationMined or not AchCache then return end
    if AchCache.scanComplete then
        _explorationMined = true; return
    end
    _explorationMined = true

    local cats = GetCategoryList()
    if not cats then return end
    -- NOTE: BuildMapNameIndex is only called here during the chunked cache build,
    -- never during the synchronous startup path.
    local index = BuildMapNameIndex()

    for _, catID in ipairs(cats) do
        local curCat = catID
        local isExploration = false
        local depth = 0
        while curCat and depth < 10 do
            local cn, parentID = GetCategoryInfo(curCat)
            if cn == "Exploration" then isExploration = true; break end
            if not parentID or parentID <= 0 then break end
            curCat = parentID
            depth = depth + 1
        end

        if isExploration then
            local catName = GetCategoryInfo(catID)
            if catName and catName ~= "" then
                local entry = index[catName:lower()]
                if entry then
                    local n = GetCategoryNumAchievements(catID, true) or 0
                    for i = 1, n do
                        local achID = GetAchievementInfo(catID, i)
                        if achID then
                            CacheAchToMap(achID, entry.mapID, CONF_CATEGORY)
                        end
                    end
                end
            end
        end
    end
end

-- ── Enhanced Text Classification ────────────────────────────────────────
-- Word-boundary-aware zone name matching in achievement text.
-- Looks for "in [Zone]", "of [Zone]", "at [Zone]" patterns for higher confidence.

local function ClassifyByTextEnhanced(achID)
    if not AchCache then return end
    local index = BuildMapNameIndex()
    local instIndex = BuildInstanceNameIndex()

    -- Gather text from achievement
    local _, _, _, _, _, _, _, desc = GetAchievementInfo(achID)
    local parts = { desc or "" }
    local n = GetAchievementNumCriteria(achID)
    if n and n > 0 then
        for i = 1, n do
            local cStr = GetAchievementCriteriaInfo(achID, i)
            if cStr and cStr ~= "" then parts[#parts + 1] = cStr end
        end
    end
    local fullText = table.concat(parts, " ")
    if fullText == "" then return end
    local textLower = fullText:lower()

    -- Check instance names first (higher value — very specific)
    for instName, instMapID in pairs(instIndex) do
        if textLower:find(instName, 1, true) then
            CacheAchToMap(achID, instMapID, CONF_CRITERIA)
        end
    end

    -- Check zone names with word boundary awareness
    for name, data in pairs(index) do
        if #name >= 4 then  -- skip very short names that false-positive
            local startPos = textLower:find(name, 1, true)
            if startPos then
                -- Word boundary check: character before and after should be non-alpha
                local before = startPos > 1 and textLower:sub(startPos - 1, startPos - 1) or " "
                local afterPos = startPos + #name
                local after = afterPos <= #textLower and textLower:sub(afterPos, afterPos) or " "
                local isWordBound = not before:match("%a") and not after:match("%a")

                if isWordBound then
                    -- Check for preposition pattern: "in/of/at/from [Zone]" → higher confidence
                    local preCheck = startPos >= 4 and textLower:sub(startPos - 4, startPos - 1) or ""
                    local hasPreposition = preCheck:match("[%s]in%s$") or preCheck:match("[%s]of%s$")
                        or preCheck:match("[%s]at%s$") or preCheck:match("[%s]from%s$")
                        or preCheck:match("^in%s$") or preCheck:match("^of%s$")
                        or preCheck:match("^at%s$")

                    local conf = hasPreposition and CONF_CRITERIA or CONF_TEXT
                    CacheAchToMap(achID, data.mapID, conf)
                end
            end
        end
    end
end

-- ── Cross-Achievement Inference ─────────────────────────────────────────
-- If achievement A has a criteria of type 8 (sub-achievement) referencing
-- achievement B, and B is already cached to a zone, inherit B's mapping.

local function ClassifyByCrossReference(achID)
    if not AchCache then return end
    local n = GetAchievementNumCriteria(achID)
    if not n or n == 0 then return end

    for i = 1, n do
        local _, criteriaType, _, _, _, _, _, assetID = GetAchievementCriteriaInfo(achID, i)
        if criteriaType == 8 and assetID and assetID > 0 then
            -- Sub-achievement: inherit its cached zones
            local subMaps = GetCachedMapsForAch(assetID)
            for _, mapID in ipairs(subMaps) do
                CacheAchToMap(achID, mapID, CONF_CRITERIA)
            end
        end
    end
end

-- ── Master Classification (all tiers) ───────────────────────────────────
-- Runs all classification heuristics on a single achievement and stores results.

local function ClassifyAndCacheAchievement(achID)
    if not AchCache then return end

    -- Check flags first
    local id, name, pts, _, _, _, _, desc, flags, icon,
          reward, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
    if not id then return end

    -- Flag guild achievements and statistics
    if isGuild then CacheAchFlag(achID, FLAG_GUILD) end
    if isStat then CacheAchFlag(achID, FLAG_STATISTIC); return end  -- skip statistics entirely

    -- Tier 1: Category hierarchy (existing logic, store results)
    local catRefs = GetAchievementCategoryMapIDs(achID)
    for mid, data in pairs(catRefs) do
        CacheAchToMap(achID, mid, CONF_CATEGORY)
    end

    -- Tier 2: Criteria type analysis (existing logic, store results)
    local critRefs = GetCriteriaZoneRefs(achID)
    for mid, data in pairs(critRefs) do
        CacheAchToMap(achID, mid, CONF_CRITERIA)
    end

    -- Tier 2.5: Cross-achievement inference
    ClassifyByCrossReference(achID)

    -- Tier 3: Enhanced text scanning (word boundaries, instance names)
    ClassifyByTextEnhanced(achID)
end

-- ============================================================================
-- BACKGROUND CACHE BUILD
-- Runs once on first load, or incrementally for new achievements.
-- ============================================================================

-- Forward declaration — defined below StartAsyncScan
local StartCacheBuild, StartIncrementalCacheScan

local function CancelCacheBuild()
    if Panel._state.cacheScanTimer then
        pcall(function() Panel._state.cacheScanTimer:Cancel() end)
    end
    Panel._state.cacheScanTimer = nil
    Panel._state.cacheScanRunning = false
end

-- ── Fully Async Cache Build ─────────────────────────────────────────────
-- Three-phase pipeline, every phase is chunked:
--   Phase 1: Enumerate achievement IDs from categories (chunked by category)
--   Phase 2: Classify each achievement (chunked by ID)
--   Phase 3: Cross-reference pass (chunked by ID)
-- No synchronous loops > 200 iterations.

StartCacheBuild = function()
    if not AchCache or Panel._state.cacheScanRunning then return end
    CancelCacheBuild()
    Panel._state.cacheScanRunning = true

    local cats = GetCategoryList()
    if not cats or #cats == 0 then Panel._state.cacheScanRunning = false; return end

    local allIDs = {}
    local idSet = {}
    local CHUNK = 150  -- API calls per frame budget

    -- ── Phase 1: Enumerate achievement IDs from categories ──
    local catIdx, achIdx = 1, 1
    local curCatCount = 0

    local function Phase1_EnumCategories()
        -- Deferred exploration mining — runs once on first chunk, not at startup
        MineExplorationCategories()
        local calls = 0
        while catIdx <= #cats and calls < CHUNK do
            if achIdx == 1 then
                curCatCount = GetCategoryNumAchievements(cats[catIdx], true) or 0
            end
            while achIdx <= curCatCount and calls < CHUNK do
                local achID = GetAchievementInfo(cats[catIdx], achIdx)
                if achID and not idSet[achID] then
                    idSet[achID] = true
                    allIDs[#allIDs + 1] = achID
                end
                achIdx = achIdx + 1
                calls = calls + 1
            end
            if achIdx > curCatCount then catIdx = catIdx + 1; achIdx = 1 end
        end

        if catIdx > #cats then
            -- Categories done — move to Phase 1b: sequential ID scan (chunked)
            local maxFromCats = 0
            for _, achID in ipairs(allIDs) do
                if achID > maxFromCats then maxFromCats = achID end
            end
            local scanMax = maxFromCats + 100
            local seqID = 1

            local function Phase1b_SequentialScan()
                local calls2 = 0
                while seqID <= scanMax and calls2 < CHUNK do
                    if not idSet[seqID] then
                        local exists = GetAchievementInfo(seqID)
                        if exists then
                            idSet[seqID] = true
                            allIDs[#allIDs + 1] = seqID
                        end
                    end
                    seqID = seqID + 1
                    calls2 = calls2 + 1
                end

                if seqID > scanMax then
                    -- Phase 1 complete — start Phase 2
                    local classIdx = 1
                    local totalIDs = #allIDs

                    local function Phase2_Classify()
                        local processed = 0
                        while classIdx <= totalIDs and processed < CHUNK do
                            ClassifyAndCacheAchievement(allIDs[classIdx])
                            classIdx = classIdx + 1
                            processed = processed + 1
                        end

                        if classIdx > totalIDs then
                            -- Phase 2 complete — start Phase 3 (cross-references)
                            local crossIdx = 1

                            local function Phase3_CrossRef()
                                local processed3 = 0
                                while crossIdx <= totalIDs and processed3 < CHUNK do
                                    ClassifyByCrossReference(allIDs[crossIdx])
                                    crossIdx = crossIdx + 1
                                    processed3 = processed3 + 1
                                end

                                if crossIdx > totalIDs then
                                    -- ALL DONE
                                    AchCache.scanComplete = true
                                    AchCache.maxScannedID = scanMax
                                    AchCache.lastScanTime = time()
                                    Panel._state.cacheScanRunning = false
                                    Panel._state.cacheScanTimer = nil
                                    if Panel.IsOpen() then
                                        InvalidateCache(); CollectZoneBuckets(); Panel.Rebuild()
                                    end
                                else
                                    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase3_CrossRef)
                                end
                            end
                            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase3_CrossRef)
                        else
                            -- Periodic UI refresh during Phase 2
                            if classIdx % 500 < CHUNK and Panel.IsOpen() then
                                InvalidateCache(); CollectZoneBuckets(); Panel.Rebuild()
                            end
                            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase2_Classify)
                        end
                    end
                    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase2_Classify)
                else
                    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1b_SequentialScan)
                end
            end
            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1b_SequentialScan)
        else
            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1_EnumCategories)
        end
    end

    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1_EnumCategories)
end

-- ── Incremental Scan (fully async) ──────────────────────────────────────
-- On returning sessions, only scans achievement IDs above the last known max.

StartIncrementalCacheScan = function()
    if not AchCache or Panel._state.cacheScanRunning then return end
    CancelCacheBuild()
    Panel._state.cacheScanRunning = true

    -- Skip MineExplorationCategories — cache already has exploration data.
    -- It will run if needed during a full rebuild.

    -- Phase 1: Find current max ID from categories (chunked)
    local cats = GetCategoryList()
    if not cats or #cats == 0 then Panel._state.cacheScanRunning = false; return end
    local lastMax = AchCache.maxScannedID or 0
    local currentMax = 0
    local catIdx, achIdx2 = 1, 1
    local curCatCount2 = 0
    local CHUNK = 150

    local function Phase1_FindMax()
        local calls = 0
        while catIdx <= #cats and calls < CHUNK do
            if achIdx2 == 1 then
                curCatCount2 = GetCategoryNumAchievements(cats[catIdx], true) or 0
            end
            while achIdx2 <= curCatCount2 and calls < CHUNK do
                local achID = GetAchievementInfo(cats[catIdx], achIdx2)
                if achID and achID > currentMax then currentMax = achID end
                achIdx2 = achIdx2 + 1
                calls = calls + 1
            end
            if achIdx2 > curCatCount2 then catIdx = catIdx + 1; achIdx2 = 1 end
        end

        if catIdx > #cats then
            -- Found max — now scan new IDs
            if currentMax <= lastMax then
                Panel._state.cacheScanRunning = false
                Panel._state.cacheScanTimer = nil
                return
            end
            local scanEnd = currentMax + 100
            local newIDs = {}
            local seqID = lastMax + 1

            local function Phase2_CollectNew()
                local calls2 = 0
                while seqID <= scanEnd and calls2 < CHUNK do
                    local exists = GetAchievementInfo(seqID)
                    if exists then newIDs[#newIDs + 1] = seqID end
                    seqID = seqID + 1
                    calls2 = calls2 + 1
                end

                if seqID > scanEnd then
                    if #newIDs == 0 then
                        AchCache.maxScannedID = scanEnd
                        Panel._state.cacheScanRunning = false
                        Panel._state.cacheScanTimer = nil
                        return
                    end
                    -- Phase 3: Classify new IDs
                    local idx = 1
                    local function Phase3_Classify()
                        local processed = 0
                        while idx <= #newIDs and processed < CHUNK do
                            ClassifyAndCacheAchievement(newIDs[idx])
                            ClassifyByCrossReference(newIDs[idx])
                            idx = idx + 1
                            processed = processed + 1
                        end
                        if idx > #newIDs then
                            AchCache.maxScannedID = scanEnd
                            AchCache.lastScanTime = time()
                            Panel._state.cacheScanRunning = false
                            Panel._state.cacheScanTimer = nil
                            if Panel.IsOpen() then
                                InvalidateCache(); CollectZoneBuckets(); Panel.Rebuild()
                            end
                        else
                            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase3_Classify)
                        end
                    end
                    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase3_Classify)
                else
                    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase2_CollectNew)
                end
            end
            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase2_CollectNew)
        else
            Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1_FindMax)
        end
    end

    Panel._state.cacheScanTimer = C_Timer.NewTimer(0, Phase1_FindMax)
end


-- ── Content Type Classification ─────────────────────────────────────────
-- Walks the achievement's category chain to determine its content type
-- (Dungeons, Raids, PvP, Exploration, etc.)

local _achContentTypeCache = {}  -- achID -> content type key

local function GetAchievementContentType(achID)
    if _achContentTypeCache[achID] then return _achContentTypeCache[achID] end

    local catID = GetAchievementCategory(achID)
    if not catID then _achContentTypeCache[achID] = "general"; return "general" end

    -- Collect all category names in the chain (child → root)
    local chainNames = {}
    local visited = {}
    local cur = catID
    while cur and not visited[cur] do
        visited[cur] = true
        local cn, parentID = GetCategoryInfo(cur)
        if cn then chainNames[#chainNames + 1] = cn end
        if not parentID or parentID <= 0 then break end
        cur = parentID
    end

    -- Also check description for raid/dungeon hints
    local _, _, _, _, _, _, _, desc = GetAchievementInfo(achID)
    local descLower = desc and desc:lower() or ""

    -- Match against content type patterns
    for _, ctDef in ipairs(CFG.CONTENT_TYPES) do
        if ctDef.patterns then
            for _, pattern in ipairs(ctDef.patterns) do
                for _, cn in ipairs(chainNames) do
                    if cn:find(pattern, 1, true) then
                        -- Special handling: "Dungeons & Raids" needs sub-classification
                        if ctDef.key == "raids" then
                            -- Only classify as raid if a category or desc mentions "raid"
                            local isRaid = false
                            for _, cn2 in ipairs(chainNames) do
                                if cn2:lower():find("raid", 1, true) then isRaid = true; break end
                            end
                            if not isRaid and descLower:find("raid") then isRaid = true end
                            if isRaid then
                                _achContentTypeCache[achID] = "raids"; return "raids"
                            end
                        elseif ctDef.key == "dungeons" then
                            -- "Dungeons & Raids" root but not specifically raid
                            local isRaid = false
                            for _, cn2 in ipairs(chainNames) do
                                if cn2:lower():find("raid", 1, true) then isRaid = true; break end
                            end
                            if not isRaid then
                                _achContentTypeCache[achID] = "dungeons"; return "dungeons"
                            end
                        else
                            _achContentTypeCache[achID] = ctDef.key; return ctDef.key
                        end
                    end
                end
            end
        end
    end

    _achContentTypeCache[achID] = "general"
    return "general"
end

-- ── Reward Icon Resolution ───────────────────────────────────────────────
-- Determines the best icon for an achievement's reward.
-- Returns: texturePath, rewardType
--   rewardType: "item", "title", "mount", "pet", "toy", "tabard", "none"
-- For "none" (no reward), returns nil so the caller can hide the icon entirely.

local _rewardIconCache = {}  -- achID -> { icon, rewardType }

local function GetRewardIcon(achID, rewardText)
    -- Check cache first
    if _rewardIconCache[achID] then
        return _rewardIconCache[achID].icon, _rewardIconCache[achID].rewardType
    end

    -- No reward text at all — no icon
    if not rewardText or rewardText == "" then
        _rewardIconCache[achID] = { icon = nil, rewardType = "none" }
        return nil, "none"
    end

    local lower = rewardText:lower()
    local result = nil

    -- ── Title rewards: use a scroll/parchment icon ──
    if lower:find("^title") or lower:find("title reward") or lower:find("title:") then
        result = { icon = "Interface\\Icons\\INV_Scroll_11", rewardType = "title" }
    end

    -- ── Try the actual item link via GetItemInfo ──
    -- Strip common prefixes to get the item name
    if not result then
        local itemName = rewardText
            :gsub("^Reward:%s*", "")
            :gsub("^Title Reward:%s*", "")
            :gsub("^Mount Reward:%s*", "")
            :gsub("^Companion:%s*", "")

        if itemName ~= "" then
            -- GetItemInfo can return the actual icon for items/mounts/pets/toys
            local _, _, _, _, _, _, _, _, _, itemIcon = GetItemInfo(itemName)
            if itemIcon then
                -- Determine type from text
                local rType = "item"
                if lower:find("mount") or lower:find("proto%-drake") or lower:find("drake")
                    or lower:find("steed") or lower:find("charger") or lower:find("hawkstrider")
                    or lower:find("hippogryph") or lower:find("netherdrake") or lower:find("frostwyrm") then
                    rType = "mount"
                elseif lower:find("companion") or lower:find("pet") then
                    rType = "pet"
                elseif lower:find("toy") then
                    rType = "toy"
                elseif lower:find("tabard") then
                    rType = "tabard"
                end
                result = { icon = itemIcon, rewardType = rType }
            end
        end
    end

    -- ── Keyword-based fallbacks (GetItemInfo returned nil — item not cached yet) ──
    if not result then
        if lower:find("mount") or lower:find("proto%-drake") or lower:find("drake")
            or lower:find("steed") or lower:find("charger") or lower:find("hawkstrider") then
            result = { icon = "Interface\\Icons\\Ability_Mount_RidingHorse", rewardType = "mount" }
        elseif lower:find("companion") or lower:find("pet") then
            result = { icon = "Interface\\Icons\\INV_Pet_BabyBlizzardBear", rewardType = "pet" }
        elseif lower:find("toy") then
            result = { icon = "Interface\\Icons\\INV_Misc_Toy_02", rewardType = "toy" }
        elseif lower:find("tabard") then
            result = { icon = "Interface\\Icons\\INV_Shirt_GuildTabard_01", rewardType = "tabard" }
        else
            -- Has reward text but can't identify — use gift box icon
            result = { icon = "Interface\\Icons\\INV_Misc_Gift_05", rewardType = "item" }
        end
    end

    _rewardIconCache[achID] = result
    return result.icon, result.rewardType
end

-- ── Core Achievement Functions ──────────────────────────────────────────

local function GetCurrentZoneInfo()
    local mapID = C_Map.GetBestMapForUnit("player")
    if not mapID then return nil, "", nil end
    local info = C_Map.GetMapInfo(mapID)
    local zoneName = info and info.name or (GetRealZoneText() or "")
    local parentID = info and info.parentMapID or nil

    -- Instance/dungeon fallback: if inside a dungeon or micro-dungeon,
    -- also return the instance mapID separately and walk up to the outdoor zone.
    -- This lets the panel show dungeon-specific achievements AND the outdoor zone's.
    local instanceMapID = nil
    if info and info.mapType then
        local mt = info.mapType
        if mt == Enum.UIMapType.Dungeon or mt == Enum.UIMapType.Micro then
            instanceMapID = mapID
            -- Walk up until we find a Zone-level or higher map
            local cur = parentID
            local depth = 0
            while cur and depth < 10 do
                local pInfo = C_Map.GetMapInfo(cur)
                if not pInfo then break end
                if pInfo.mapType and pInfo.mapType <= Enum.UIMapType.Zone then
                    -- Found the outdoor zone — use it as primary
                    mapID = cur
                    info = pInfo
                    zoneName = pInfo.name or zoneName
                    parentID = pInfo.parentMapID
                    break
                end
                cur = pInfo.parentMapID
                depth = depth + 1
            end
        end
    end

    return mapID, zoneName, parentID, instanceMapID
end

local function GetAchievementProgress(id)
    local n = GetAchievementNumCriteria(id)
    if not n or n == 0 then return 0, 0, 0 end
    local done, totalQ, curQ = 0, 0, 0
    for i = 1, n do
        local _, _, complete, qty, req = GetAchievementCriteriaInfo(id, i)
        if complete then done = done + 1 end
        if req and req > 0 then totalQ = totalQ + req; curQ = curQ + (qty or 0) end
    end
    local pct = done / n
    if totalQ > 0 then pct = math.max(pct, curQ / totalQ) end
    return Clamp(pct, 0, 1), done, n
end

local function HasAnyProgress(id)
    local n = GetAchievementNumCriteria(id)
    if not n or n == 0 then return false end
    for i = 1, n do
        local _, _, complete, qty, req = GetAchievementCriteriaInfo(id, i)
        if complete then return true end
        if qty and req and qty > 0 and req > 0 then return true end
    end
    return false
end

local function GetAchievementTag(id, catID)
    local _, _, points, _, _, _, _, description = GetAchievementInfo(id)
    if points == 0 and catID then
        local cn = GetCategoryInfo(catID)
        if cn and cn:find("Feats of Strength") then return "FEAT", CFG.TAG_COLORS.FEAT end
    end
    -- Seasonal tag: only if the achievement is filed under a category whose
    -- top-level parent is "World Events" or "Holidays". This prevents dungeon
    -- achievements that happen to be in an anniversary sub-category from being
    -- misclassified as seasonal.
    if catID then
        local curCat = catID
        local depth = 0
        while curCat and depth < 10 do
            local cn, parentID = GetCategoryInfo(curCat)
            if cn then
                -- If we reach a top-level holiday root, this IS seasonal
                if cn == "World Events" or cn == "Holidays" then
                    -- Walk back down to find the specific holiday name
                    local tagCn = GetCategoryInfo(catID) or "SEASONAL"
                    return tagCn:upper(), CFG.TAG_COLORS.SEASONAL
                end
            end
            if not parentID or parentID <= 0 then break end
            curCat = parentID
            depth = depth + 1
        end
    end
    if description then
        local dl = description:lower()
        if dl:find("raid") or dl:find("heroic difficulty") then return "RAID", CFG.TAG_COLORS.RAID end
        if dl:find("dungeon") or dl:find("mythic") then return "DUNGEON", CFG.TAG_COLORS.DUNGEON end
    end
    if points and points >= 10 then return points .. " PTS", CFG.TAG_COLORS.PTS end
    return nil, nil
end

-- Achievement flag constants (from WoW API)
local ACHIEVEMENT_FLAGS_ACCOUNT = 0x00020000  -- account-wide achievement
local ACHIEVEMENT_FLAGS_TRACKING = 0x00000100  -- tracking only (no reward)

local function BuildEntry(achID, catID, doProgress, includeCompleted)
    local id, name, points, completed, month, day, year, desc, flags, icon,
          reward, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
    if not id or isStat or isGuild then return nil end
    if wasEarned and not includeCompleted then return nil end
    if not wasEarned and includeCompleted then return nil end

    -- Filter unobtainable: if flags indicate tracking-only with 0 points
    -- and no criteria, it's likely a removed/legacy achievement
    -- (We don't aggressively filter — some 0-point achievements are Feats of Strength)
    local pct, cd, ct = 0, 0, 0
    if doProgress and not wasEarned then pct, cd, ct = GetAchievementProgress(id) end
    if wasEarned then pct = 1 end
    local tag, tagC = GetAchievementTag(id, catID)
    local earnedDate = nil
    if wasEarned and month and day and year then
        earnedDate = string.format("%d/%d/%d", month, day, year)
    end

    -- Clean reward text (strip "Reward: " prefix)
    local rewardDisplay = nil
    if reward and reward ~= "" then
        rewardDisplay = reward:gsub("^Reward:%s*", "")
    end

    return {
        id = id, name = name or "", description = desc or "", points = points or 0,
        icon = icon, progress = pct, critDone = cd, critTotal = ct,
        catID = catID, tag = tag, tagColor = tagC,
        reward = rewardDisplay,
        completed = wasEarned, earnedDate = earnedDate,
        contentType = GetAchievementContentType(achID),
    }
end

local function ScanCat(catID, includeCompleted)
    local out = {}
    local n = GetCategoryNumAchievements(catID, false)
    if not n or n == 0 then return out end
    for i = 1, n do
        local achID = GetAchievementInfo(catID, i)
        if achID then
            local e = BuildEntry(achID, catID, true, includeCompleted)
            if e then out[#out + 1] = e end
        end
    end
    return out
end

-- ── Category-based zone matching (kept as first pass) ───────────────────
local _zoneCatCache = nil
local function BuildZoneCatMap()
    if _zoneCatCache then return _zoneCatCache end
    _zoneCatCache = {}
    local cats = GetCategoryList()
    if not cats then return _zoneCatCache end
    for _, catID in ipairs(cats) do
        local cn = GetCategoryInfo(catID)
        if cn and cn ~= "" then
            local k = cn:lower()
            _zoneCatCache[k] = _zoneCatCache[k] or {}
            _zoneCatCache[k][#_zoneCatCache[k] + 1] = catID
        end
    end
    return _zoneCatCache
end

local function FindCatsForZone(zoneName)
    if not zoneName or zoneName == "" then return {} end
    local m = BuildZoneCatMap()
    local key = zoneName:lower()
    local out = {}
    if m[key] then for _, c in ipairs(m[key]) do out[c] = true end end
    for ck, cids in pairs(m) do
        if ck:find(key, 1, true) or key:find(ck, 1, true) then
            for _, c in ipairs(cids) do out[c] = true end
        end
    end
    return out
end

-- ── Seasonal / Holiday Detection ────────────────────────────────────────
-- Uses WoW's calendar API to find currently active holidays,
-- then scans matching achievement categories.

local _activeHolidayCache = nil
local _activeHolidayCacheTime = 0

local function GetActiveHolidays()
    -- Cache for 5 minutes (holiday state doesn't change often)
    local now = GetTime()
    if _activeHolidayCache and (now - _activeHolidayCacheTime) < 300 then
        return _activeHolidayCache
    end

    local active = {}  -- keyword -> true

    -- Method 1: Calendar API — scan current month for ongoing events
    local today = C_DateAndTime.GetCurrentCalendarTime()
    if today then
        local okMonth = pcall(C_Calendar.SetAbsMonth, today.month, today.year)
        if okMonth then
            local numEvents = C_Calendar.GetNumDayEvents(0, today.monthDay)
            if numEvents then
                for i = 1, numEvents do
                    local event = C_Calendar.GetDayEvent(0, today.monthDay, i)
                    if event and event.title then
                        -- Match event title against known holidays
                        for holidayName, keyword in pairs(CFG.HOLIDAYS) do
                            if keyword and event.title:find(holidayName, 1, true) then
                                active[keyword] = true
                            end
                        end
                    end
                end
            end
        end
    end

    -- Method 2: Check for active world event buff/quest indicators
    -- GetActiveHolidayEvents is another approach in some WoW versions
    if C_Calendar.GetNumPendingInvites then
        -- Calendar is available, our scan above should have worked
    end

    _activeHolidayCache = active
    _activeHolidayCacheTime = now
    return active
end

-- Check if an achievement category is seasonal by verifying its ancestry
-- leads to "World Events" or "Holidays" as a top-level parent.
-- Returns: isSeasonal, holidayKeyword
local function IsSeasonalCategory(catID)
    local catName = GetCategoryInfo(catID)
    if not catName then return false, nil end

    -- Walk up the category tree to see if it's rooted under World Events/Holidays
    local curCat = catID
    local depth = 0
    local isUnderHolidays = false
    while curCat and depth < 10 do
        local cn, parentID = GetCategoryInfo(curCat)
        if cn and (cn == "World Events" or cn == "Holidays") then
            isUnderHolidays = true; break
        end
        if not parentID or parentID <= 0 then break end
        curCat = parentID
        depth = depth + 1
    end

    if not isUnderHolidays then return false, nil end

    -- It's under World Events — now find the specific holiday keyword
    for _, kw in ipairs(CFG.SEASONAL_KEYWORDS) do
        if catName:find(kw, 1, true) then return true, kw end
    end
    -- If the direct category didn't match a keyword, use the category name itself
    return true, catName
end

-- Find all seasonal achievement category IDs
local _seasonalCatCache = nil
local function GetSeasonalCategories()
    if _seasonalCatCache then return _seasonalCatCache end
    _seasonalCatCache = {}
    local cats = GetCategoryList()
    if not cats then return _seasonalCatCache end
    for _, catID in ipairs(cats) do
        local isSeasonal, keyword = IsSeasonalCategory(catID)
        if isSeasonal then
            _seasonalCatCache[catID] = keyword
        end
    end
    return _seasonalCatCache
end

-- Collect seasonal achievements into the seasonal bucket
-- Prioritizes: active holidays first, then upcoming/all seasonal
local function CollectSeasonalBucket(seen, B)
    local activeHolidays = GetActiveHolidays()
    local seasonalCats = GetSeasonalCategories()
    local hasActiveHoliday = next(activeHolidays) ~= nil

    local activeAchs = {}    -- achievements for currently active holidays
    local otherAchs = {}     -- achievements for non-active seasonal content

    for catID, keyword in pairs(seasonalCats) do
        local isActive = activeHolidays[keyword]

        -- Scan incomplete achievements
        for _, a in ipairs(ScanCat(catID, false)) do
            if not seen[a.id] then
                seen[a.id] = true
                a._holidayKeyword = keyword
                a._holidayActive = isActive

                -- Override tag to show which holiday
                if keyword then
                    a.tag = keyword:upper()
                    a.tagColor = CFG.TAG_COLORS.SEASONAL
                end

                if isActive then
                    activeAchs[#activeAchs + 1] = a
                else
                    otherAchs[#otherAchs + 1] = a
                end
            end
        end
    end

    -- Sort active by progress descending (closest to completion first)
    table.sort(activeAchs, function(a, b) return a.progress > b.progress end)
    -- Sort non-active by name
    table.sort(otherAchs, function(a, b) return a.name < b.name end)

    -- Active holiday achievements go first, then others
    for _, a in ipairs(activeAchs) do B.seasonal[#B.seasonal + 1] = a end

    -- Only include non-active seasonal if no active holiday OR they have progress
    for _, a in ipairs(otherAchs) do
        if a.progress > 0 then
            B.seasonal[#B.seasonal + 1] = a
        end
    end
end

-- ── Master Collection ───────────────────────────────────────────────────
-- Phase 1 (sync): Category-based scan + criteria text proximity check
-- Phase 2 (async): All in-progress achievements, also classified by proximity

-- ── Helper: classify an achievement against player location using cache ──
-- Returns: "zone", "nearby", "continent", or "other"
-- Uses persistent cache first, falls back to runtime heuristics.

local function ClassifyFromCache(achID, playerMapID)
    if not playerMapID then return "other" end

    -- Check persistent cache for this achievement's mapIDs
    local cachedMaps = GetCachedMapsForAch(achID)
    if #cachedMaps > 0 then
        local playerAnc = GetMapAncestorChain(playerMapID)
        local playerParent = playerAnc[#playerAnc]
        local playerRegion = #playerAnc >= 2 and playerAnc[#playerAnc - 1] or nil
        local playerContinent = nil
        for _, aid in ipairs(playerAnc) do
            if GetMapType(aid) == Enum.UIMapType.Continent then
                playerContinent = aid; break
            end
        end

        local isNearby, isContinent = false, false

        for _, refMapID in ipairs(cachedMaps) do
            local mt = GetMapType(refMapID)
            if mt and mt ~= false and mt <= Enum.UIMapType.Continent then
                -- Broad ref: check continent match
                if playerContinent and refMapID == playerContinent then isContinent = true end
                local playerSet = { [playerMapID] = true }
                for _, a in ipairs(playerAnc) do playerSet[a] = true end
                if playerSet[refMapID] then isContinent = true end
            else
                -- Zone-level ref
                if refMapID == playerMapID then return "zone" end
                if playerParent and refMapID == playerParent then return "zone" end
                -- Check if player is parent of the ref
                local refAnc = GetMapAncestorChain(refMapID)
                if refAnc[#refAnc] == playerMapID then return "zone" end
                -- Sibling check
                if playerParent and refAnc[#refAnc] == playerParent then return "zone" end
                -- Region check
                if playerRegion then
                    if refMapID == playerRegion then isNearby = true
                    else
                        for _, anc in ipairs(refAnc) do
                            if anc == playerRegion then isNearby = true; break end
                        end
                    end
                end
                -- Continent check
                if playerContinent then
                    for _, anc in ipairs(refAnc) do
                        if anc == playerContinent then isContinent = true; break end
                    end
                end
            end
        end

        if isNearby then return "nearby" end
        if isContinent then return "continent" end
        return "other"
    end

    -- No cache data: fall back to runtime classification
    return ClassifyUndiscoveredTier(achID, playerMapID)
end

-- Forward declarations for virtual scroll functions (used by async scanner)
local BuildDisplayList, VirtualScrollUpdate, UpdateScrollChildHeight, UpdateHeroSection, UpdateStatPills
local ResolveAchievementData, PopulateAchievementRow

local function CollectZoneBuckets()
    local mapID, zoneName, parentID, instanceMapID = GetCurrentZoneInfo()
    Panel._state.currentZone = zoneName
    Panel._state.currentMapID = mapID
    Panel._state.parentMapID = parentID
    Panel._state.instanceMapID = instanceMapID  -- nil when outdoors

    -- Ensure index is warm
    BuildMapNameIndex()

    -- ID-only bucket arrays
    -- Pre-seed progress from cached IDs so the count shows instantly
    local cachedProgress = {}
    if AchCache and AchCache.progressIDs and #AchCache.progressIDs > 0 then
        for _, id in ipairs(AchCache.progressIDs) do
            cachedProgress[#cachedProgress + 1] = id
        end
    end
    local B = {
        here_ids = {},
        seasonal_ids = {},
        progress_ids = cachedProgress,
        nearby_ids = {},
        undiscovered_ids = { zone = {}, nearby = {}, continent = {} },
        completed_ids = {},
    }
    -- Also keep the old-style seasonal full-entry array for CollectSeasonalBucket compatibility
    local seasonalEntries = {}

    local seen = Panel._state.asyncSeenIDs; wipe(seen)
    local sortKeys = Panel._state.sortKeys; wipe(sortKeys)
    local subCaps = CFG.UNDISCOVERED_CAPS

    -- Mark cached progress IDs as seen so async scanner doesn't duplicate them
    for _, id in ipairs(B.progress_ids) do seen[id] = true end

    -- ── PATH A: Cache-first (fast O(1) lookup) ──
    if IsCacheReady() and mapID then

        -- Gather mapIDs to query: current zone + parent + instance + sub-zones
        local hereMaps = { mapID }
        if parentID then hereMaps[#hereMaps + 1] = parentID end
        if instanceMapID then hereMaps[#hereMaps + 1] = instanceMapID end
        local okC, childrenC = pcall(C_Map.GetMapChildrenInfo, mapID)
        if okC and childrenC then
            for _, ch in ipairs(childrenC) do hereMaps[#hereMaps + 1] = ch.mapID end
        end

        local nearbyMaps = {}
        local nearbySet = {}
        local hereSet = {}
        for _, m in ipairs(hereMaps) do hereSet[m] = true end

        local function AddNearby(mid)
            if mid and not hereSet[mid] and not nearbySet[mid] then
                nearbySet[mid] = true
                nearbyMaps[#nearbyMaps + 1] = mid
            end
        end

        if parentID then
            local okS, siblings = pcall(C_Map.GetMapChildrenInfo, parentID, nil, false)
            if okS and siblings then
                for _, sib in ipairs(siblings) do AddNearby(sib.mapID) end
            end

            local parentInfo = C_Map.GetMapInfo(parentID)
            local gpID = parentInfo and parentInfo.parentMapID
            if gpID then
                AddNearby(gpID)
                local okG, gpChildren = pcall(C_Map.GetMapChildrenInfo, gpID, nil, false)
                if okG and gpChildren then
                    for _, gpc in ipairs(gpChildren) do
                        AddNearby(gpc.mapID)
                        local okGC, gpcChildren = pcall(C_Map.GetMapChildrenInfo, gpc.mapID, nil, false)
                        if okGC and gpcChildren then
                            for _, gpcChild in ipairs(gpcChildren) do AddNearby(gpcChild.mapID) end
                        end
                    end
                end

                local gpInfo = C_Map.GetMapInfo(gpID)
                local contID = gpInfo and gpInfo.parentMapID
                if contID then
                    local contType = GetMapType(contID)
                    if contType == Enum.UIMapType.Continent then
                        AddNearby(contID)
                        local okCont, contChildren = pcall(C_Map.GetMapChildrenInfo, contID, nil, false)
                        if okCont and contChildren then
                            for _, region in ipairs(contChildren) do
                                AddNearby(region.mapID)
                                local okR, regionChildren = pcall(C_Map.GetMapChildrenInfo, region.mapID, nil, false)
                                if okR and regionChildren then
                                    for _, zone in ipairs(regionChildren) do AddNearby(zone.mapID) end
                                end
                            end
                        end
                    end
                end
            end
        end

        -- Query cache: HERE achievements (IDs only)
        local hereAchIDs = {}
        for _, mid in ipairs(hereMaps) do
            local cached = GetCachedAchsForMap(mid)
            for achID, conf in pairs(cached) do
                if not hereAchIDs[achID] then hereAchIDs[achID] = conf end
            end
        end

        for achID, conf in pairs(hereAchIDs) do
            if not seen[achID]
                and not IsCacheFlagged(achID, FLAG_STATISTIC)
                and not IsCacheFlagged(achID, FLAG_GUILD) then
                -- Minimal API call: only GetAchievementInfo for wasEarned (13th return)
                local id, _, _, _, _, _, _, _, _, _, _, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
                if id and not isStat and not isGuild then
                    seen[achID] = true
                    if wasEarned then
                        B.completed_ids[#B.completed_ids + 1] = achID
                    else
                        if HasAnyProgress(achID) then
                            B.here_ids[#B.here_ids + 1] = achID
                            sortKeys[achID] = GetAchievementProgress(achID)
                        else
                            local subKey = ClassifyFromCache(achID, mapID)
                            if subKey == "zone" then subKey = "zone"
                            elseif subKey == "nearby" then subKey = "nearby"
                            else subKey = "zone" end
                            local sb = B.undiscovered_ids[subKey]
                            if sb and #sb < (subCaps[subKey] or 200) then
                                sb[#sb + 1] = achID
                            end
                        end
                    end
                end
            end
        end

        -- Process NEARBY synchronously (ID-only, fast)
        local subCapsNb = CFG.UNDISCOVERED_CAPS
        for _, mid in ipairs(nearbyMaps) do
            local cached = GetCachedAchsForMap(mid)
            for achID, conf in pairs(cached) do
                if not seen[achID] and not hereAchIDs[achID]
                    and not IsCacheFlagged(achID, FLAG_STATISTIC)
                    and not IsCacheFlagged(achID, FLAG_GUILD) then
                    seen[achID] = true
                    local _, _, _, _, _, _, _, _, _, _, _, _, wasEarned = GetAchievementInfo(achID)
                    if wasEarned then
                        B.completed_ids[#B.completed_ids + 1] = achID
                    else
                        local hasProgress = HasAnyProgress(achID)
                        if hasProgress then
                            B.nearby_ids[#B.nearby_ids + 1] = achID
                            Panel._state.sortKeys[achID] = GetAchievementProgress(achID)
                        else
                            local sb = B.undiscovered_ids["nearby"]
                            if sb and #sb < (subCapsNb["nearby"] or 200) then
                                sb[#sb + 1] = achID
                            end
                        end
                    end
                end
            end
        end
        -- No deferred processing needed
        Panel._state._deferredNearbyMaps = nil
        Panel._state._deferredHereSet = nil
        Panel._state._deferredHereAchIDs = nil

    -- ── PATH B: Legacy category-scanning fallback (cache not ready) ──
    else
        local candidateCats = FindCatsForZone(zoneName)

        if mapID then
            local chain = BuildMapBreadcrumbs(mapID)
            for _, crumb in ipairs(chain) do
                for c in pairs(FindCatsForZone(crumb)) do candidateCats[c] = true end
            end
            BuildMapToCategoryIndex()
            for c in pairs(GetCategoriesForMapID(mapID)) do candidateCats[c] = true end
            if parentID then
                for c in pairs(GetCategoriesForMapID(parentID)) do candidateCats[c] = true end
                local parentInfo = C_Map.GetMapInfo(parentID)
                if parentInfo and parentInfo.parentMapID then
                    for c in pairs(GetCategoriesForMapID(parentInfo.parentMapID)) do candidateCats[c] = true end
                end
            end
            if parentID then
                local children = C_Map.GetMapChildrenInfo(parentID, Enum.UIMapType.Zone, true)
                if children then
                    for _, child in ipairs(children) do
                        if child.mapID ~= mapID then
                            for c in pairs(FindCatsForZone(child.name)) do candidateCats[c] = true end
                            for c in pairs(GetCategoriesForMapID(child.mapID)) do candidateCats[c] = true end
                        end
                    end
                end
            end
        end

        for catID in pairs(candidateCats) do
            -- Incomplete achievements
            local n = GetCategoryNumAchievements(catID, false) or 0
            for i = 1, n do
                local achID = GetAchievementInfo(catID, i)
                if achID and not seen[achID] then
                    local id, _, _, _, _, _, _, _, _, _, _, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
                    if id and not isStat and not isGuild and not wasEarned then
                        seen[achID] = true
                        local refs, totalInc = GetAchievementZoneRefs(achID)
                        local proximity, hereMatches = ClassifyProximity(refs, mapID, totalInc)
                        if not proximity then
                            local zl = zoneName:lower()
                            local catName = GetCategoryInfo(catID)
                            if catName then
                                local cl = catName:lower()
                                if cl:find(zl, 1, true) or zl:find(cl, 1, true) then proximity = "here" end
                            end
                            if not proximity then
                                local achCatID = GetAchievementCategory(achID)
                                if achCatID and achCatID ~= catID then
                                    local aCatName = GetCategoryInfo(achCatID)
                                    if aCatName then
                                        local al = aCatName:lower()
                                        if al:find(zl, 1, true) or zl:find(al, 1, true) then proximity = "here" end
                                    end
                                end
                            end
                            if not proximity and parentID then
                                local pInfo2 = C_Map.GetMapInfo(parentID)
                                if pInfo2 and pInfo2.name then
                                    local pl = pInfo2.name:lower()
                                    local catName2 = GetCategoryInfo(catID)
                                    if catName2 and catName2:lower():find(pl, 1, true) then proximity = "here" end
                                    if not proximity then
                                        local achCatID2 = GetAchievementCategory(achID)
                                        if achCatID2 then
                                            local aCatName2 = GetCategoryInfo(achCatID2)
                                            if aCatName2 and aCatName2:lower():find(pl, 1, true) then proximity = "here" end
                                        end
                                    end
                                end
                            end
                        end
                        if proximity == "here" then
                            if HasAnyProgress(achID) then
                                B.here_ids[#B.here_ids + 1] = achID
                                sortKeys[achID] = GetAchievementProgress(achID)
                            else
                                local subKey = ClassifyUndiscoveredTier(achID, mapID)
                                local sb = B.undiscovered_ids[subKey]
                                if sb then sb[#sb + 1] = achID end
                            end
                        elseif proximity == "nearby" then
                            B.nearby_ids[#B.nearby_ids + 1] = achID
                            if HasAnyProgress(achID) then
                                sortKeys[achID] = GetAchievementProgress(achID)
                            end
                        end
                    end
                end
            end
            -- Completed achievements
            local nComp = GetCategoryNumAchievements(catID, false) or 0
            for i = 1, nComp do
                local achID = GetAchievementInfo(catID, i)
                if achID and not seen[achID] then
                    local id, _, _, _, _, _, _, _, _, _, _, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
                    if id and not isStat and not isGuild and wasEarned then
                        local fullText = GetAchievementFullText(achID)
                        local refs = FindZoneRefsInText(achID, fullText)
                        local proximity = ClassifyProximity(refs, mapID)
                        if not proximity then
                            local catName = GetCategoryInfo(catID)
                            if catName and catName:lower():find(zoneName:lower(), 1, true) then proximity = "here" end
                        end
                        if proximity == "here" or proximity == "nearby" then
                            seen[achID] = true
                            B.completed_ids[#B.completed_ids + 1] = achID
                        end
                    end
                end
            end
        end
    end

    -- Collect seasonal achievements (still builds full entries — small set)
    -- We use a temp table that mimics old B structure for CollectSeasonalBucket
    local tempB = { seasonal = {} }
    CollectSeasonalBucket(seen, tempB)
    seasonalEntries = tempB.seasonal
    -- Extract IDs from seasonal entries
    for _, a in ipairs(seasonalEntries) do
        B.seasonal_ids[#B.seasonal_ids + 1] = a.id
    end
    -- Store seasonal entries for ResolveAchievementData to use
    Panel._state._seasonalEntryCache = {}
    for _, a in ipairs(seasonalEntries) do
        Panel._state._seasonalEntryCache[a.id] = a
    end

    -- Sort ID arrays using sortKeys
    table.sort(B.here_ids, function(a, b)
        return (sortKeys[a] or 0) > (sortKeys[b] or 0)
    end)
    table.sort(B.nearby_ids, function(a, b)
        return (sortKeys[a] or 0) > (sortKeys[b] or 0)
    end)
    -- Undiscovered: sort by points desc then name
    local function undSortIDs(idList)
        table.sort(idList, function(a, b)
            local _, nameA, ptsA = GetAchievementInfo(a)
            local _, nameB, ptsB = GetAchievementInfo(b)
            ptsA = ptsA or 0; ptsB = ptsB or 0
            if ptsA ~= ptsB then return ptsA > ptsB end
            return (nameA or "") < (nameB or "")
        end)
    end
    for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
        if B.undiscovered_ids[sk] then undSortIDs(B.undiscovered_ids[sk]) end
    end
    table.sort(B.completed_ids, function(a, b)
        local _, nameA = GetAchievementInfo(a)
        local _, nameB = GetAchievementInfo(b)
        return (nameA or "") < (nameB or "")
    end)

    -- Store the new ID-based buckets on state
    Panel._state.buckets = B
    Panel._state.zoneCacheKey = zoneName
end

-- ── Async Full Scanner ───────────────────────────────────────────────────
-- When cache is ready: only scans for IN PROGRESS achievements (zone buckets
-- are already populated from cache). When cache is not ready: full legacy scan.

local function CancelAsync()
    if Panel._state.asyncTimer then pcall(function() Panel._state.asyncTimer:Cancel() end) end
    Panel._state.asyncTimer = nil; Panel._state.asyncScanning = false
end

local function StartAsyncScan()
    CancelAsync()
    local cats = GetCategoryList()
    if not cats or #cats == 0 then return end
    Panel._state.asyncScanning = true
    -- Don't wipe progress_ids — cached values from last session are pre-seeded.
    -- Scanner appends new discoveries. Final dedup + save at completion.
    local seen = Panel._state.asyncSeenIDs
    local B = Panel._state.buckets
    local sortKeys = Panel._state.sortKeys
    local ci, ai, curCount = 1, 1, 0
    local subCaps = CFG.UNDISCOVERED_CAPS
    local playerMapID = Panel._state.currentMapID
    local rebuildCounter = 0
    local cacheReady = IsCacheReady()
    local function LightweightUpdate()
        if Panel._state.panel then
            BuildDisplayList()
            UpdateScrollChildHeight()
            VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
            UpdateStatPills()
        end
    end

    local function Chunk()
        if not Panel._state.panelOpen then CancelAsync(); return end
        local processed = 0
        while ci <= #cats and processed < CFG.SCAN_CHUNK do
            if ai == 1 then curCount = GetCategoryNumAchievements(cats[ci], false) or 0 end
            while ai <= curCount and processed < CFG.SCAN_CHUNK do
                local achID = GetAchievementInfo(cats[ci], ai)
                ai = ai + 1; processed = processed + 1
                if achID and not seen[achID] then
                    local id, _, _, _, _, _, _, _, _, _, _, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
                    if id and not isStat and not isGuild and not wasEarned then
                        local hasProgress = HasAnyProgress(id)

                        if hasProgress then
                            local pct = GetAchievementProgress(id)
                            if pct > 0 and pct < 1 then
                                seen[id] = true
                                sortKeys[id] = pct

                                if cacheReady then
                                    local tier = ClassifyFromCache(id, playerMapID)
                                    if tier == "zone" then
                                        B.here_ids[#B.here_ids + 1] = id
                                    elseif tier == "nearby" then
                                        B.nearby_ids[#B.nearby_ids + 1] = id
                                    else
                                        B.progress_ids[#B.progress_ids + 1] = id
                                    end
                                else
                                    local refs, totalInc = GetAchievementZoneRefs(id)
                                    local proximity = ClassifyProximity(refs, playerMapID, totalInc)
                                    if proximity == "here" then
                                        B.here_ids[#B.here_ids + 1] = id
                                    elseif proximity == "nearby" then
                                        B.nearby_ids[#B.nearby_ids + 1] = id
                                    else
                                        B.progress_ids[#B.progress_ids + 1] = id
                                    end
                                end
                            end
                        elseif not cacheReady then
                            local subKey = ClassifyUndiscoveredTier(id, playerMapID)
                            local subBucket = B.undiscovered_ids[subKey]
                            if subBucket and #subBucket < (subCaps[subKey] or 200) then
                                seen[id] = true
                                subBucket[#subBucket + 1] = id
                            end
                        end

                        rebuildCounter = rebuildCounter + 1
                        if rebuildCounter >= 1000 then
                            rebuildCounter = 0
                            LightweightUpdate()
                        end
                    end
                end
            end
            if ai > curCount then ci = ci + 1; ai = 1 end
        end
        if ci > #cats then
            table.sort(B.progress_ids, function(a, b)
                return (sortKeys[a] or 0) > (sortKeys[b] or 0)
            end)
            table.sort(B.here_ids, function(a, b)
                return (sortKeys[a] or 0) > (sortKeys[b] or 0)
            end)
            table.sort(B.nearby_ids, function(a, b)
                return (sortKeys[a] or 0) > (sortKeys[b] or 0)
            end)
            local function undSortIDs(idList)
                table.sort(idList, function(a, b)
                    local _, nameA, ptsA = GetAchievementInfo(a)
                    local _, nameB, ptsB = GetAchievementInfo(b)
                    ptsA = ptsA or 0; ptsB = ptsB or 0
                    if ptsA ~= ptsB then return ptsA > ptsB end
                    return (nameA or "") < (nameB or "")
                end)
            end
            for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
                if B.undiscovered_ids[sk] then undSortIDs(B.undiscovered_ids[sk]) end
            end
            Panel._state.asyncScanning = false
            -- Save progress IDs to persistent cache for instant display next session
            if AchCache then
                wipe(AchCache.progressIDs)
                for _, id in ipairs(B.progress_ids) do
                    AchCache.progressIDs[#AchCache.progressIDs + 1] = id
                end
            end
            LightweightUpdate()
        else
            Panel._state.asyncTimer = C_Timer.NewTimer(0, Chunk)
        end
    end
    Panel._state.asyncTimer = C_Timer.NewTimer(0, Chunk)
end

local function InvalidateCache()
    Panel._state.zoneCacheKey = nil; _zoneCatCache = nil; CancelAsync()
    wipe(_achZoneCache)  -- criteria completion state may have changed
    _activeHolidayCache = nil      -- re-check holidays on next open
    -- Clear resolved data cache for virtual scroll
    wipe(Panel._state.displayList)
    Panel._state.totalHeight = 0
    Panel._state.lastScrollOffset = -1
    -- Note: _mapNameIndex, _mapAncestors, _achTextCache, _achRefsCache, _seasonalCatCache are static game data
    -- Note: AchCache (persistent SavedVariables) is NOT wiped — it persists across sessions
end


-- ============================================================================
-- UI FRAMEWORK — Reusable micro-components
-- ============================================================================

-- Chevron (collapsible indicator)
local function MakeChevron(parent, sz)
    sz = sz or 10
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(sz, sz); f:EnableMouse(false)
    local ico = f:CreateTexture(nil, "OVERLAY", nil, 5)
    ico:SetAtlas("common-dropdown-icon-back"); ico:SetSize(sz, sz); ico:SetPoint("CENTER")
    f._i = ico
    function f:Color(r, g, b, a) self._i:SetVertexColor(r, g, b, a or 1) end
    function f:Expand(yes) self._i:SetRotation(yes and (-math.pi/2) or math.pi) end
    f:Color(1, 1, 1, 0.4); f:Expand(true)
    return f
end

-- Pill badge (tag label)
local function MakePill(parent)
    local f = CreateFrame("Frame", nil, parent); f:SetHeight(CFG.PILL_H)
    local bg = f:CreateTexture(nil, "BACKGROUND"); bg:SetAllPoints(); bg:SetTexture(W8); f._bg = bg
    local tx = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightExtraSmall"); tx:SetPoint("CENTER"); f._tx = tx
    function f:Set(text, r, g, b, bgA)
        self._tx:SetText(text); self._tx:SetTextColor(r, g, b, 0.90)
        self._bg:SetVertexColor(r, g, b, bgA or 0.15)
        self:SetWidth(math.max(30, (self._tx:GetStringWidth() or 18) + 14))
    end
    f:Hide(); return f
end

-- Progress bar (track + fill)
local function MakeProgressBar(parent, w, h)
    local f = CreateFrame("Frame", nil, parent); f:SetSize(w, h)
    local track = f:CreateTexture(nil, "BACKGROUND", nil, -2); track:SetAllPoints(); track:SetTexture(W8)
    local tr, tg, tb, ta = TC("progressTrack"); track:SetVertexColor(tr, tg, tb, ta)
    local fill = f:CreateTexture(nil, "ARTWORK", nil, 1); fill:SetHeight(h)
    fill:SetPoint("LEFT", f, "LEFT", 0, 0); fill:SetTexture(W8); fill:SetWidth(1)
    f._track = track; f._fill = fill
    function f:SetProgress(pct, r, g, b)
        local pw = math.max(1, math.floor(self:GetWidth() * Clamp(pct, 0, 1)))
        self._fill:SetWidth(pw)
        if r then self._fill:SetVertexColor(r, g, b, 0.75)
        else local fr, fg, fb = TC("progressFill"); self._fill:SetVertexColor(fr, fg, fb, 0.75) end
    end
    return f
end


-- ============================================================================
-- PANEL SHELL — Large centered frame with structured layout
-- ============================================================================

-- Forward declarations for pool functions (defined after EnsurePanel)
local AcquireRow, ReleaseRows
local AcquireBucket, ReleaseBuckets
local AcquireExpansion, ReleaseExps

-- (virtual scroll forward declarations moved above CollectZoneBuckets)

local _searchTimer = nil

function Panel.EnsurePanel()
    if Panel._state.panel then return Panel._state.panel end

    local p = CreateFrame("Frame", "MidnightUI_AchievementsPanel", UIParent, "BackdropTemplate")
    p:SetSize(CFG.WIDTH, CFG.HEIGHT)
    p:SetFrameStrata(CFG.STRATA); p:SetFrameLevel(100)
    p:SetClampedToScreen(true)
    p:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
    p:Hide()

    -- ── Frame background ──
    local bg = p:CreateTexture(nil, "BACKGROUND", nil, -7)
    bg:SetAllPoints(); bg:SetTexture(W8)
    bg:SetVertexColor(TC("frameBg"))

    -- Drop shadows (4 edges extending outward from panel)
    local shSize = 10
    local shAlpha = 0.45
    -- Top shadow
    local shT = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    shT:SetTexture(W8); shT:SetHeight(shSize)
    shT:SetPoint("BOTTOMLEFT", p, "TOPLEFT", 0, 0)
    shT:SetPoint("BOTTOMRIGHT", p, "TOPRIGHT", 0, 0)
    ApplyGradient(shT, "VERTICAL", 0, 0, 0, shAlpha, 0, 0, 0, 0)
    -- Bottom shadow
    local shB = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    shB:SetTexture(W8); shB:SetHeight(shSize)
    shB:SetPoint("TOPLEFT", p, "BOTTOMLEFT", 0, 0)
    shB:SetPoint("TOPRIGHT", p, "BOTTOMRIGHT", 0, 0)
    ApplyGradient(shB, "VERTICAL", 0, 0, 0, 0, 0, 0, 0, shAlpha)
    -- Left shadow
    local shL = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    shL:SetTexture(W8); shL:SetWidth(shSize)
    shL:SetPoint("TOPRIGHT", p, "TOPLEFT", 0, 0)
    shL:SetPoint("BOTTOMRIGHT", p, "BOTTOMLEFT", 0, 0)
    ApplyGradient(shL, "HORIZONTAL", 0, 0, 0, 0, 0, 0, 0, shAlpha)
    -- Right shadow
    local shR = p:CreateTexture(nil, "BACKGROUND", nil, -8)
    shR:SetTexture(W8); shR:SetWidth(shSize)
    shR:SetPoint("TOPLEFT", p, "TOPRIGHT", 0, 0)
    shR:SetPoint("BOTTOMLEFT", p, "BOTTOMRIGHT", 0, 0)
    ApplyGradient(shR, "HORIZONTAL", 0, 0, 0, shAlpha, 0, 0, 0, 0)

    -- Border (1px gold)
    local bR, bG, bB = TC("borderDim")
    for _, bd in ipairs({
        {"TOPLEFT","TOPLEFT","TOPRIGHT","TOPRIGHT", nil, 1},
        {"BOTTOMLEFT","BOTTOMLEFT","BOTTOMRIGHT","BOTTOMRIGHT", nil, 1},
        {"TOPLEFT","TOPLEFT","BOTTOMLEFT","BOTTOMLEFT", 1, nil},
        {"TOPRIGHT","TOPRIGHT","BOTTOMRIGHT","BOTTOMRIGHT", 1, nil},
    }) do
        local t = p:CreateTexture(nil, "BORDER", nil, 2)
        t:SetTexture(W8); t:SetVertexColor(bR, bG, bB, 0.50)
        t:SetPoint(bd[1], p, bd[2]); t:SetPoint(bd[3], p, bd[4])
        if bd[5] then t:SetWidth(bd[5]) end; if bd[6] then t:SetHeight(bd[6]) end
    end

    -- Top accent stripe (2px gold)
    local acR, acG, acB = TC("accent")
    local topStripe = p:CreateTexture(nil, "ARTWORK", nil, 3)
    topStripe:SetHeight(2)
    topStripe:SetPoint("TOPLEFT", p, "TOPLEFT", 1, -1)
    topStripe:SetPoint("TOPRIGHT", p, "TOPRIGHT", -1, -1)
    topStripe:SetTexture(W8); topStripe:SetVertexColor(acR, acG, acB, 0.80)

    -- Bottom accent strip (matching gold, not class color)
    local botStrip = p:CreateTexture(nil, "OVERLAY", nil, 2)
    botStrip:SetHeight(1); botStrip:SetTexture(W8); botStrip:SetVertexColor(acR, acG, acB, 0.30)
    botStrip:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 1, 1)
    botStrip:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -1, 1)

    -- ════════════════════════════════════════════════════════════════════
    -- HEADER BAR
    -- ════════════════════════════════════════════════════════════════════
    local hdr = CreateFrame("Frame", nil, p)
    hdr:SetHeight(CFG.HEADER_H)
    hdr:SetPoint("TOPLEFT", 0, 0); hdr:SetPoint("TOPRIGHT", 0, 0)
    local hdrBg = hdr:CreateTexture(nil, "BACKGROUND", nil, -6)
    hdrBg:SetAllPoints(); hdrBg:SetTexture(W8); hdrBg:SetVertexColor(TC("headerBg"))

    -- Title
    local ttR, ttG, ttB = TC("titleText")
    local title = hdr:CreateFontString(nil, "OVERLAY")
    title:SetFont(STANDARD_TEXT_FONT, 20, "OUTLINE")
    title:SetPoint("LEFT", hdr, "LEFT", 20, 0)
    title:SetPoint("TOP", hdr, "TOP", 0, -11)
    title:SetTextColor(ttR, ttG, ttB, 1); title:SetText("Achievement Tracker")
    title:SetShadowColor(0, 0, 0, 0.7); title:SetShadowOffset(1, -1)

    local mtR, mtG, mtB = TC("mutedText")

    -- Close button
    local closeBtn = CreateFrame("Button", nil, hdr)
    closeBtn:SetSize(28, 28); closeBtn:SetPoint("RIGHT", hdr, "RIGHT", -10, 0)
    local closeTx = closeBtn:CreateFontString(nil, "OVERLAY")
    closeTx:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE"); closeTx:SetPoint("CENTER", 0, 1)
    closeTx:SetTextColor(mtR, mtG, mtB, 0.70); closeTx:SetText("\195\151")
    closeBtn:SetScript("OnEnter", function() closeTx:SetTextColor(ttR, ttG, ttB, 1) end)
    closeBtn:SetScript("OnLeave", function() closeTx:SetTextColor(mtR, mtG, mtB, 0.70) end)
    closeBtn:SetScript("OnClick", function() Panel.Hide() end)

    -- Header underline
    local hdrLine = hdr:CreateTexture(nil, "ARTWORK", nil, 1)
    hdrLine:SetHeight(1); hdrLine:SetTexture(W8); hdrLine:SetVertexColor(acR, acG, acB, 0.35)
    hdrLine:SetPoint("BOTTOMLEFT", hdr, "BOTTOMLEFT", 0, 0)
    hdrLine:SetPoint("BOTTOMRIGHT", hdr, "BOTTOMRIGHT", 0, 0)

    -- ════════════════════════════════════════════════════════════════════
    -- HERO SECTION — Zone banner + stat pills + progress bar
    -- ════════════════════════════════════════════════════════════════════
    local hero = CreateFrame("Frame", nil, p)
    hero:SetHeight(CFG.HERO_H)
    hero:SetPoint("TOPLEFT", hdr, "BOTTOMLEFT", 0, 0)
    hero:SetPoint("TOPRIGHT", hdr, "BOTTOMRIGHT", 0, 0)
    p._hero = hero

    local heroBg = hero:CreateTexture(nil, "BACKGROUND", nil, -4)
    heroBg:SetAllPoints(); heroBg:SetTexture(W8); heroBg:SetVertexColor(TC("heroBg"))

    -- Top glow wash
    local heroGlow = hero:CreateTexture(nil, "BACKGROUND", nil, -3)
    heroGlow:SetPoint("TOPLEFT"); heroGlow:SetPoint("TOPRIGHT"); heroGlow:SetHeight(50)
    heroGlow:SetTexture(W8)
    ApplyGradient(heroGlow, "VERTICAL", acR, acG, acB, 0.0, acR, acG, acB, 0.08)

    -- Zone breadcrumb (horizontal hierarchy)
    local breadcrumb = hero:CreateFontString(nil, "OVERLAY")
    breadcrumb:SetFont(STANDARD_TEXT_FONT, 12, "")
    breadcrumb:SetPoint("TOPLEFT", hero, "TOPLEFT", 20, -16)
    breadcrumb:SetPoint("RIGHT", hero, "RIGHT", -20, 0)
    breadcrumb:SetJustifyH("LEFT"); breadcrumb:SetWordWrap(false)
    p._heroBreadcrumb = breadcrumb

    -- ── Stat pills row (below zone name) ──
    -- Four pills anchored left-to-right with 8px gaps
    p._heroPills = {}
    local prevPill = nil
    for _, key in ipairs(CFG.BUCKET_ORDER) do
        local bc = CFG.BUCKET_COLORS[key]
        local pill = CreateFrame("Button", nil, hero)
        pill:SetHeight(26); pill:RegisterForClicks("LeftButtonUp")

        local pbg = pill:CreateTexture(nil, "BACKGROUND"); pbg:SetAllPoints(); pbg:SetTexture(W8)
        pbg:SetVertexColor(bc.r, bc.g, bc.b, 0.10); pill._bg = pbg

        -- Left accent dot
        local dot = pill:CreateTexture(nil, "ARTWORK", nil, 1)
        dot:SetSize(3, 14); dot:SetPoint("LEFT", pill, "LEFT", 0, 0); dot:SetTexture(W8)
        dot:SetVertexColor(bc.r, bc.g, bc.b, 0.90); pill._dot = dot

        local lbl = pill:CreateFontString(nil, "OVERLAY")
        lbl:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
        lbl:SetPoint("LEFT", dot, "RIGHT", 8, 0)
        lbl:SetTextColor(bc.r, bc.g, bc.b, 0.85); pill._lbl = lbl

        local cnt = pill:CreateFontString(nil, "OVERLAY")
        cnt:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        cnt:SetPoint("LEFT", lbl, "RIGHT", 6, 0)
        cnt:SetTextColor(bc.r, bc.g, bc.b, 1); pill._cnt = cnt

        -- Anchor: first pill to hero left, others to previous pill's right
        if prevPill then
            pill:SetPoint("LEFT", prevPill, "RIGHT", 8, 0)
        else
            pill:SetPoint("TOPLEFT", hero, "TOPLEFT", 20, -44)
        end
        pill:SetWidth(120)  -- resized dynamically in Rebuild

        -- Hover
        pill:SetScript("OnEnter", function(self)
            self._bg:SetVertexColor(bc.r, bc.g, bc.b, 0.25)
        end)
        pill:SetScript("OnLeave", function(self)
            local active = Panel._state.activeBucket == key
            self._bg:SetVertexColor(bc.r, bc.g, bc.b, active and 0.20 or 0.10)
        end)

        pill._key = key
        pill:SetScript("OnClick", function(self)
            if Panel._state.activeBucket == self._key then
                Panel._state.activeBucket = nil
            else
                Panel._state.activeBucket = self._key
            end
            BuildDisplayList()
            UpdateScrollChildHeight()
            if Panel._state.panel and Panel._state.panel._scroll then
                VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
            end
            UpdateStatPills()
        end)

        p._heroPills[key] = pill
        prevPill = pill
    end

    -- Total points pill (far right of pill row)
    local ptsPill = CreateFrame("Frame", nil, hero)
    ptsPill:SetHeight(26)
    ptsPill:SetPoint("RIGHT", hero, "RIGHT", -20, -8)
    local ptsBg = ptsPill:CreateTexture(nil, "BACKGROUND")
    ptsBg:SetAllPoints(); ptsBg:SetTexture(W8)
    ptsBg:SetVertexColor(acR, acG, acB, 0.10)
    local ptsDot = ptsPill:CreateTexture(nil, "ARTWORK", nil, 1)
    ptsDot:SetSize(3, 14); ptsDot:SetPoint("LEFT", ptsPill, "LEFT", 0, 0)
    ptsDot:SetTexture(W8); ptsDot:SetVertexColor(acR, acG, acB, 0.70)
    local ptsTx = ptsPill:CreateFontString(nil, "OVERLAY")
    ptsTx:SetFont(STANDARD_TEXT_FONT, 11, "OUTLINE")
    ptsTx:SetPoint("LEFT", ptsDot, "RIGHT", 8, 0)
    ptsTx:SetTextColor(acR, acG, acB, 0.90)
    ptsPill._tx = ptsTx
    ptsPill:SetWidth(120) -- resized in Rebuild
    p._heroPoints = ptsPill

    -- Hero progress bar (bottom of hero)
    local heroBar = MakeProgressBar(hero, CFG.WIDTH - 40, 4)
    heroBar:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", 20, 10)
    p._heroBar = heroBar

    -- Hero bottom divider
    local heroDivL = hero:CreateTexture(nil, "ARTWORK", nil, 1)
    heroDivL:SetHeight(1); heroDivL:SetTexture(W8)
    local dvR, dvG, dvB = TC("divider")
    heroDivL:SetVertexColor(dvR, dvG, dvB, 0.30)
    heroDivL:SetPoint("BOTTOMLEFT", hero, "BOTTOMLEFT", 0, 0)
    heroDivL:SetPoint("BOTTOMRIGHT", hero, "BOTTOMRIGHT", 0, 0)


    -- ════════════════════════════════════════════════════════════════════
    -- SEARCH BOX
    -- ════════════════════════════════════════════════════════════════════
    local search = CreateFrame("EditBox", nil, p)
    search:SetHeight(CFG.SEARCH_H)
    search:SetPoint("TOPLEFT", hero, "BOTTOMLEFT", 0, 0)
    search:SetPoint("TOPRIGHT", hero, "BOTTOMRIGHT", 0, 0)
    search:SetAutoFocus(false); search:SetFontObject(GameFontHighlight)
    local btR, btG, btB = TC("bodyText")
    search:SetTextColor(btR, btG, btB, 1); search:SetMaxLetters(64)
    search:SetTextInsets(20, 20, 0, 0)
    p._search = search

    -- Search icon hint
    local searchIcon = search:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    searchIcon:SetPoint("LEFT", search, "LEFT", 20, 0)
    searchIcon:SetTextColor(mtR, mtG, mtB, 0.35); searchIcon:SetText("Search...")
    search._ph = searchIcon

    local searchLine = search:CreateTexture(nil, "BORDER")
    searchLine:SetHeight(1); searchLine:SetTexture(W8)
    searchLine:SetVertexColor(dvR, dvG, dvB, 0.18)
    searchLine:SetPoint("BOTTOMLEFT", search, "BOTTOMLEFT", 20, 0)
    searchLine:SetPoint("BOTTOMRIGHT", search, "BOTTOMRIGHT", -20, 0)

    search:SetScript("OnEditFocusGained", function(s) s._ph:Hide() end)
    search:SetScript("OnEditFocusLost", function(s) if s:GetText() == "" then s._ph:Show() end end)
    search:SetScript("OnTextChanged", function(s, user)
        if user then
            if s:GetText() == "" then s._ph:Show() else s._ph:Hide() end
            Panel._state.searchFilter = s:GetText():lower()
            if _searchTimer then pcall(function() _searchTimer:Cancel() end) end
            _searchTimer = C_Timer.NewTimer(0.20, function()
                BuildDisplayList()
                UpdateScrollChildHeight()
                VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
            end)
        end
    end)
    search:SetScript("OnEscapePressed", function(s)
        s:ClearFocus(); s:SetText(""); s._ph:Show()
        Panel._state.searchFilter = ""
        BuildDisplayList()
        UpdateScrollChildHeight()
        VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
    end)
    search:SetScript("OnEnterPressed", function(s) s:ClearFocus() end)

    -- ════════════════════════════════════════════════════════════════════
    -- CONTENT TYPE FILTER BAR
    -- ════════════════════════════════════════════════════════════════════
    local filterBar = CreateFrame("Frame", nil, p)
    filterBar:SetHeight(22)
    filterBar:SetPoint("TOPLEFT", search, "BOTTOMLEFT", 0, -1)
    filterBar:SetPoint("TOPRIGHT", search, "BOTTOMRIGHT", 0, -1)
    p._filterBar = filterBar

    local filterBg = filterBar:CreateTexture(nil, "BACKGROUND", nil, -5)
    filterBg:SetAllPoints(); filterBg:SetTexture(W8)
    filterBg:SetVertexColor(TC("headerBg"))

    local filterLine = filterBar:CreateTexture(nil, "ARTWORK")
    filterLine:SetHeight(1); filterLine:SetTexture(W8)
    local fdR, fdG, fdB = TC("divider")
    filterLine:SetVertexColor(fdR, fdG, fdB, 0.15)
    filterLine:SetPoint("BOTTOMLEFT", filterBar, "BOTTOMLEFT", 0, 0)
    filterLine:SetPoint("BOTTOMRIGHT", filterBar, "BOTTOMRIGHT", 0, 0)

    p._filterBtns = {}
    local prevFilterBtn = nil
    for _, ctDef in ipairs(CFG.CONTENT_TYPES) do
        local fb = CreateFrame("Button", nil, filterBar)
        fb:SetHeight(18); fb:RegisterForClicks("LeftButtonUp")

        local fbTx = fb:CreateFontString(nil, "OVERLAY")
        fbTx:SetFont(STANDARD_TEXT_FONT, 9, "")
        fbTx:SetPoint("CENTER", 0, 0)
        fbTx:SetText(ctDef.label)
        fb._tx = fbTx; fb._key = ctDef.key

        -- Size to text
        local fw = math.max(30, (fbTx:GetStringWidth() or 20) + 12)
        fb:SetWidth(fw)

        -- Position
        if prevFilterBtn then
            fb:SetPoint("LEFT", prevFilterBtn, "RIGHT", 2, 0)
        else
            fb:SetPoint("LEFT", filterBar, "LEFT", 16, 0)
        end
        fb:SetPoint("TOP", filterBar, "TOP", 0, -2)

        -- Styling function
        function fb:UpdateStyle()
            local isActive = Panel._state.activeContentType == self._key
                or (self._key == "all" and Panel._state.activeContentType == nil)
            if isActive then
                self._tx:SetTextColor(acR, acG, acB, 1)
            else
                local dmfR, dmfG, dmfB = TC("dimText")
                self._tx:SetTextColor(dmfR, dmfG, dmfB, 0.65)
            end
        end

        fb:SetScript("OnEnter", function(self)
            self._tx:SetTextColor(acR, acG, acB, 0.85)
        end)
        fb:SetScript("OnLeave", function(self) self:UpdateStyle() end)
        fb:SetScript("OnClick", function(self)
            if self._key == "all" then
                Panel._state.activeContentType = nil
            else
                if Panel._state.activeContentType == self._key then
                    Panel._state.activeContentType = nil
                else
                    Panel._state.activeContentType = self._key
                end
            end
            -- Update all button styles
            for _, btn in ipairs(p._filterBtns) do btn:UpdateStyle() end
            BuildDisplayList()
            UpdateScrollChildHeight()
            VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
        end)

        fb:UpdateStyle()
        p._filterBtns[#p._filterBtns + 1] = fb
        prevFilterBtn = fb
    end

    -- ════════════════════════════════════════════════════════════════════
    -- SCROLL AREA (virtual scroll — no UIPanelScrollFrameTemplate)
    -- ════════════════════════════════════════════════════════════════════
    local scroll = CreateFrame("ScrollFrame", "MidnightUI_AchScroll", p)
    scroll:SetPoint("TOPLEFT", filterBar, "BOTTOMLEFT", 0, -2)
    scroll:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -8, 8)
    scroll:EnableMouseWheel(true)
    p._scroll = scroll

    local child = CreateFrame("Frame", nil, scroll)
    child:SetWidth(scroll:GetWidth() > 0 and scroll:GetWidth() or (CFG.WIDTH - 16))
    child:SetHeight(1)
    scroll:SetScrollChild(child)
    p._child = child

    -- Ensure child width matches scroll on resize
    scroll:SetScript("OnSizeChanged", function(self, w, h)
        child:SetWidth(w)
    end)

    -- Mouse wheel handler
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local cur = self:GetVerticalScroll()
        local step = CFG.ROW_H * 3
        local max = self:GetVerticalScrollRange()
        self:SetVerticalScroll(Clamp(cur - delta * step, 0, max))
    end)

    -- Vertical scroll handler drives virtual updates
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        VirtualScrollUpdate(offset)
    end)

    -- ── Animations ──
    local fadeIn = p:CreateAnimationGroup()
    local fi = fadeIn:CreateAnimation("Alpha")
    fi:SetFromAlpha(0); fi:SetToAlpha(1); fi:SetDuration(CFG.SLIDE_DUR); fi:SetOrder(1)
    fadeIn:SetScript("OnFinished", function() p:SetAlpha(1) end)
    p._fadeIn = fadeIn

    local fadeOut = p:CreateAnimationGroup()
    local fo = fadeOut:CreateAnimation("Alpha")
    fo:SetFromAlpha(1); fo:SetToAlpha(0); fo:SetDuration(CFG.SLIDE_DUR); fo:SetOrder(1)
    fadeOut:SetScript("OnFinished", function() p:Hide(); p:SetAlpha(1) end)
    p._fadeOut = fadeOut

    -- ESC to close (via UISpecialFrames, registered on every Show to be safe)
    p:SetScript("OnShow", function()
        local found = false
        for _, name in ipairs(UISpecialFrames) do
            if name == "MidnightUI_AchievementsPanel" then
                found = true
                break
            end
        end
        if not found then
            table.insert(UISpecialFrames, "MidnightUI_AchievementsPanel")
        end
    end)
    p:SetScript("OnHide", function()
        Panel._state.panelOpen = false
        CancelAsync()
    end)

    -- Draggable
    p:EnableMouse(true); p:SetMovable(true)
    hdr:EnableMouse(true); hdr:RegisterForDrag("LeftButton")
    hdr:SetScript("OnDragStart", function() p:StartMoving() end)
    hdr:SetScript("OnDragStop", function() p:StopMovingOrSizing() end)

    -- ── Pre-allocate frame pools ──
    for i = 1, 15 do AcquireRow(child) end
    for i = 1, 8 do AcquireBucket(child) end
    for i = 1, 3 do AcquireExpansion(child) end
    ReleaseRows(); ReleaseBuckets(); ReleaseExps()

    Panel._state.panel = p; Panel._state.initialized = true
    return p
end


-- ============================================================================
-- ELEMENT POOLS (rows, bucket headers, expansions)
-- ============================================================================

-- ── Achievement Row Pool ────────────────────────────────────────────────
local _rows, _rowN = {}, 0

AcquireRow = function(parent)
    for _, r in ipairs(_rows) do
        if not r._used then r._used = true; r:SetParent(parent); return r end
    end
    _rowN = _rowN + 1
    local f = CreateFrame("Button", "MUI_AR" .. _rowN, parent)
    f:SetHeight(CFG.ROW_H); f:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- Card background
    local cbg = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    cbg:SetPoint("TOPLEFT", 8, -1); cbg:SetPoint("BOTTOMRIGHT", -8, 1)
    cbg:SetTexture(W8); cbg:SetVertexColor(TC("cardBg")); f._cbg = cbg

    -- Left accent bar (hidden — available for future use)
    f._acc = nil

    -- Icon (left column)
    local ico = f:CreateTexture(nil, "ARTWORK")
    ico:SetSize(CFG.ICON_SIZE, CFG.ICON_SIZE)
    ico:SetPoint("LEFT", f, "LEFT", 22, 0)
    ico:SetTexCoord(0.07, 0.93, 0.07, 0.93); f._ico = ico

    -- Icon border (1px dim border around icon)
    local ibR, ibG, ibB = TC("borderDim")
    local icoTop = f:CreateTexture(nil, "ARTWORK", nil, 1)
    icoTop:SetTexture(W8); icoTop:SetVertexColor(ibR, ibG, ibB, 0.25)
    icoTop:SetHeight(1); icoTop:SetPoint("TOPLEFT", ico, "TOPLEFT"); icoTop:SetPoint("TOPRIGHT", ico, "TOPRIGHT")
    local icoBot = f:CreateTexture(nil, "ARTWORK", nil, 1)
    icoBot:SetTexture(W8); icoBot:SetVertexColor(ibR, ibG, ibB, 0.25)
    icoBot:SetHeight(1); icoBot:SetPoint("BOTTOMLEFT", ico, "BOTTOMLEFT"); icoBot:SetPoint("BOTTOMRIGHT", ico, "BOTTOMRIGHT")
    local icoL = f:CreateTexture(nil, "ARTWORK", nil, 1)
    icoL:SetTexture(W8); icoL:SetVertexColor(ibR, ibG, ibB, 0.25)
    icoL:SetWidth(1); icoL:SetPoint("TOPLEFT", ico, "TOPLEFT"); icoL:SetPoint("BOTTOMLEFT", ico, "BOTTOMLEFT")
    local icoR = f:CreateTexture(nil, "ARTWORK", nil, 1)
    icoR:SetTexture(W8); icoR:SetVertexColor(ibR, ibG, ibB, 0.25)
    icoR:SetWidth(1); icoR:SetPoint("TOPRIGHT", ico, "TOPRIGHT"); icoR:SetPoint("BOTTOMRIGHT", ico, "BOTTOMRIGHT")

    -- ── Reward icon (small, right of achievement icon) ──
    local rewIco = f:CreateTexture(nil, "ARTWORK", nil, 2)
    rewIco:SetSize(18, 18)
    rewIco:SetPoint("BOTTOMRIGHT", ico, "BOTTOMRIGHT", -1, 1)
    rewIco:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    rewIco:Hide(); f._rewIco = rewIco

    -- Reward icon border
    local rewBord = f:CreateTexture(nil, "ARTWORK", nil, 3)
    rewBord:SetSize(20, 20)
    rewBord:SetPoint("CENTER", rewIco, "CENTER")
    rewBord:SetTexture(W8); rewBord:SetVertexColor(0, 0, 0, 0.60)
    rewBord:Hide(); f._rewBord = rewBord

    -- ── Text column (center, between icon and progress) ──

    -- Title (13px, left of icon with 12px gap)
    local ttl = f:CreateFontString(nil, "OVERLAY")
    ttl:SetFont(STANDARD_TEXT_FONT, 13, "")
    ttl:SetPoint("TOPLEFT", ico, "TOPRIGHT", 14, -4)
    ttl:SetPoint("RIGHT", f, "RIGHT", -210, 0)
    ttl:SetJustifyH("LEFT"); ttl:SetWordWrap(false); f._ttl = ttl

    -- Description (11px, below title, 2px gap)
    local desc = f:CreateFontString(nil, "OVERLAY")
    desc:SetFont(STANDARD_TEXT_FONT, 11, "")
    desc:SetPoint("TOPLEFT", ttl, "BOTTOMLEFT", 0, -4)
    desc:SetPoint("RIGHT", f, "RIGHT", -210, 0)
    desc:SetJustifyH("LEFT"); desc:SetWordWrap(false); f._desc = desc

    -- Reward text (below description, gold, only shown if reward exists)
    local rewTx = f:CreateFontString(nil, "OVERLAY")
    rewTx:SetFont(STANDARD_TEXT_FONT, 10, "")
    rewTx:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -2)
    rewTx:SetPoint("RIGHT", f, "RIGHT", -210, 0)
    rewTx:SetJustifyH("LEFT"); rewTx:SetWordWrap(false)
    rewTx:Hide(); f._rewTx = rewTx

    -- ── Right column (stacked: pill+pct on line 1, bar on line 2, criteria on line 3) ──
    -- Row is 62px tall. Layout:
    --   top  8: padding
    --        8-26: tag pill + percentage (same line, 18px)
    --       28-32: progress bar (4px)
    --       34-46: criteria count (12px)

    -- Progress percentage (right-aligned, row 1)
    local pct = f:CreateFontString(nil, "OVERLAY")
    pct:SetFont(STANDARD_TEXT_FONT, 14, "OUTLINE")
    pct:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -10)
    pct:SetJustifyH("RIGHT"); f._pct = pct

    -- Tag pill (left of percentage, same baseline)
    local pill = MakePill(f)
    pill:SetPoint("RIGHT", pct, "LEFT", -8, 0); f._pill = pill

    -- Reward icon (28×28, left of progress bar)
    local rewIcon2 = f:CreateTexture(nil, "ARTWORK", nil, 2)
    rewIcon2:SetSize(28, 28)
    rewIcon2:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f._rewIcon2 = rewIcon2
    -- Reward icon border
    local rewBord2 = f:CreateTexture(nil, "ARTWORK", nil, 1)
    rewBord2:SetSize(30, 30)
    rewBord2:SetTexture(W8); rewBord2:SetVertexColor(0, 0, 0, 0.40)
    rewBord2:SetPoint("CENTER", rewIcon2, "CENTER")
    f._rewBord2 = rewBord2
    -- Reward icon tooltip overlay (invisible button over the icon)
    local rewHit = CreateFrame("Frame", nil, f)
    rewHit:SetSize(30, 30)
    rewHit:SetPoint("CENTER", rewIcon2, "CENTER")
    rewHit:SetFrameLevel(f:GetFrameLevel() + 5)
    rewHit:EnableMouse(true)
    rewHit._rewardText = nil
    rewHit._rewardType = nil
    rewHit:SetScript("OnEnter", function(self)
        if not self._rewardText or self._rewardText == "" then return end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        local rType = self._rewardType or "item"
        if rType == "title" then
            GameTooltip:AddLine("Title Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        elseif rType == "mount" then
            GameTooltip:AddLine("Mount Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        elseif rType == "pet" then
            GameTooltip:AddLine("Pet Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        elseif rType == "toy" then
            GameTooltip:AddLine("Toy Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        elseif rType == "tabard" then
            GameTooltip:AddLine("Tabard Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        else
            GameTooltip:AddLine("Reward", 1, 0.84, 0.28)
            GameTooltip:AddLine(self._rewardText, 1, 1, 1)
        end
        GameTooltip:Show()
    end)
    rewHit:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
    end)
    rewHit:Hide()
    f._rewHit = rewHit

    -- Progress bar (below pct, to the right of reward icon)
    local pbar = MakeProgressBar(f, CFG.PROGRESS_BAR_W, CFG.PROGRESS_BAR_H)
    pbar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -20, -32); f._pbar = pbar

    -- Position reward icon to the left of the progress bar, vertically centered
    rewIcon2:SetPoint("RIGHT", pbar, "LEFT", -40, 0)

    -- Criteria count (below bar, right-aligned)
    local crit = f:CreateFontString(nil, "OVERLAY")
    crit:SetFont(STANDARD_TEXT_FONT, 11, "")
    crit:SetPoint("TOPRIGHT", pbar, "BOTTOMRIGHT", 0, -4)
    crit:SetJustifyH("RIGHT"); f._crit = crit

    -- Bottom separator (subtle divider)
    local dvR2, dvG2, dvB2 = TC("divider")
    local sep = f:CreateTexture(nil, "ARTWORK", nil, -1)
    sep:SetHeight(1); sep:SetTexture(W8)
    sep:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 0)
    sep:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 0)
    sep:SetVertexColor(dvR2, dvG2, dvB2, 0.08); f._sep = sep

    -- Hover
    f:SetScript("OnEnter", function(self)
        if self._data and self._data.completed then
            local sr, sg, sb = TC("success")
            self._cbg:SetVertexColor(sr * 0.20, sg * 0.20, sb * 0.20, 0.60)
        else
            self._cbg:SetVertexColor(TC("cardBgHover"))
        end
        if self._data then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetAchievementByID(self._data.id)
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("|cffaaaaaaClick:|r Expand Criteria", 1, 1, 1)
            GameTooltip:AddLine("|cffaaaaaaShift+Click:|r Open Achievement", 1, 1, 1)
            GameTooltip:AddLine("|cffaaaaaaRight Click:|r Track/Untrack", 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    f:SetScript("OnLeave", function(self)
        if self._data and self._data.completed then
            local sr, sg, sb = TC("success")
            self._cbg:SetVertexColor(sr * 0.15, sg * 0.15, sb * 0.15, 0.50)
        else
            self._cbg:SetVertexColor(TC("cardBg"))
        end
        GameTooltip:Hide()
    end)

    -- Click
    f:SetScript("OnClick", function(self, button)
        if not self._data then return end
        if button == "LeftButton" then
            if IsShiftKeyDown() then
                -- Shift+Click: open in Blizzard's Achievement window
                if OpenAchievement then
                    pcall(OpenAchievement, self._data.id)
                end
            else
                -- Normal click: expand/collapse criteria
                Panel._state.expanded[self._data.id] = not Panel._state.expanded[self._data.id]
                wipe(Panel._state.displayList)
                BuildDisplayList()
                UpdateScrollChildHeight()
                if Panel._state.panel and Panel._state.panel._scroll then
                    VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
                end
            end
        elseif button == "RightButton" then
            local tracked = { GetTrackedAchievements() }
            local found = false
            for _, tid in ipairs(tracked) do if tid == self._data.id then found = true; break end end
            if found then RemoveTrackedAchievement(self._data.id) else AddTrackedAchievement(self._data.id) end
        end
    end)

    f._used = true; f._data = nil
    _rows[#_rows + 1] = f; return f
end

ReleaseRows = function()
    for _, r in ipairs(_rows) do r._used = false; r:Hide(); r:ClearAllPoints() end
end

-- ── Bucket Header Pool ──────────────────────────────────────────────────
local _bkts, _bktN = {}, 0

AcquireBucket = function(parent)
    for _, b in ipairs(_bkts) do
        if not b._used then b._used = true; b:SetParent(parent); return b end
    end
    _bktN = _bktN + 1
    local f = CreateFrame("Button", "MUI_AB" .. _bktN, parent)
    f:SetHeight(CFG.BUCKET_H)

    local bbg = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    bbg:SetAllPoints(); bbg:SetTexture(W8); bbg:SetVertexColor(0.07, 0.06, 0.04, 0.05); f._bg = bbg

    -- Left accent line (3px)
    local bAcc = f:CreateTexture(nil, "ARTWORK", nil, 1)
    bAcc:SetWidth(3); bAcc:SetTexture(W8); bAcc:SetVertexColor(0.07, 0.06, 0.04, 0.05)
    bAcc:SetPoint("TOPLEFT", f, "TOPLEFT", 6, -4)
    bAcc:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 4); f._bAcc = bAcc

    local lbl = f:CreateFontString(nil, "OVERLAY")
    lbl:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
    lbl:SetPoint("LEFT", bAcc, "RIGHT", 10, 0)
    f._lbl = lbl

    local cnt = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cnt:SetPoint("RIGHT", f, "RIGHT", -36, 0); cnt:SetJustifyH("RIGHT")
    f._cnt = cnt

    local chev = MakeChevron(f, 10)
    chev:SetPoint("RIGHT", f, "RIGHT", -16, 0); f._chev = chev

    local bLine = f:CreateTexture(nil, "ARTWORK", nil, 0)
    bLine:SetHeight(1); bLine:SetTexture(W8); bLine:SetVertexColor(0.07, 0.06, 0.04, 0.05)
    bLine:SetPoint("BOTTOMLEFT", 6, 0); bLine:SetPoint("BOTTOMRIGHT", -6, 0); f._bLine = bLine

    -- Highlight
    local hl = f:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints(); hl:SetTexture(W8); hl:SetVertexColor(0.72, 0.62, 0.42, 0.05)

    f:SetScript("OnClick", function(self)
        if self._key then
            Panel._state.bucketCollapse[self._key] = not Panel._state.bucketCollapse[self._key]
            BuildDisplayList()
            UpdateScrollChildHeight()
            if Panel._state.panel and Panel._state.panel._scroll then
                VirtualScrollUpdate(Panel._state.panel._scroll:GetVerticalScroll())
            end
        end
    end)

    function f:SetData(key, count, collapsed, scanning)
        self._key = key
        self:SetHeight(CFG.BUCKET_H)
        self._lbl:SetFont(STANDARD_TEXT_FONT, 12, "OUTLINE")
        local r, g, b = BucketColor(key)
        self._bg:SetVertexColor(r, g, b, 0.05)
        self._bAcc:SetVertexColor(r, g, b, 0.75)
        local text = (CFG.BUCKET_COLORS[key] and CFG.BUCKET_COLORS[key].label) or key:upper()
        if scanning then text = text .. "  \194\183  scanning..." end
        -- For seasonal, append active holiday names
        if key == "seasonal" then
            local active = GetActiveHolidays()
            local names = {}
            for kw in pairs(active) do names[#names + 1] = kw end
            if #names > 0 then
                table.sort(names)
                text = text .. "  \194\183  " .. table.concat(names, ", ")
            end
        end
        self._lbl:SetText(text); self._lbl:SetTextColor(r, g, b, 0.90)
        self._cnt:SetText(tostring(count)); self._cnt:SetTextColor(r, g, b, 0.80)
        self._bLine:SetVertexColor(r, g, b, 0.10)
        self._chev:Expand(not collapsed); self._chev:Color(r, g, b, 0.40)
        self:Show()
    end

    f._used = true; _bkts[#_bkts + 1] = f; return f
end

ReleaseBuckets = function()
    for _, b in ipairs(_bkts) do b._used = false; b:Hide(); b:ClearAllPoints() end
end

-- ── Expansion Pool (criteria detail) ────────────────────────────────────
local _exps, _expN = {}, 0

AcquireExpansion = function(parent)
    for _, e in ipairs(_exps) do
        if not e._used then e._used = true; e:SetParent(parent); return e end
    end
    _expN = _expN + 1
    local f = CreateFrame("Frame", "MUI_AE" .. _expN, parent)
    f:SetHeight(1)

    local ebg = f:CreateTexture(nil, "BACKGROUND", nil, -4)
    ebg:SetAllPoints(); ebg:SetTexture(W8)
    local crR, crG, crB = TC("cardBg"); ebg:SetVertexColor(crR, crG, crB, 0.40)

    -- Left accent (inherited from bucket color, set in SetCriteria)
    local eAcc = f:CreateTexture(nil, "ARTWORK", nil, 1)
    eAcc:SetWidth(2); eAcc:SetTexture(W8)
    eAcc:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -4)
    eAcc:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 4)
    local defAcR, defAcG, defAcB = TC("accent")
    eAcc:SetVertexColor(defAcR, defAcG, defAcB, 0.30); f._eAcc = eAcc

    local eLine = f:CreateTexture(nil, "ARTWORK", nil, 0)
    eLine:SetHeight(1); eLine:SetTexture(W8)
    eLine:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 18, 0)
    eLine:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -18, 0)
    local dv3R, dv3G, dv3B = TC("divider"); eLine:SetVertexColor(dv3R, dv3G, dv3B, 0.12)

    f._rows = {}
    f._subExpanded = {}  -- track which sub-criteria indices are expanded
    f._subRows = {}      -- nested sub-criteria rows

    function f:SetCriteria(achID, bucketR, bucketG, bucketB, achDesc, hereMatches)
        for _, cr in ipairs(self._rows) do cr:Hide() end
        for _, sr in ipairs(self._subRows) do sr:Hide() end
        if self._hereCard then self._hereCard:Hide() end
        if bucketR then self._eAcc:SetVertexColor(bucketR, bucketG, bucketB, 0.35) end

        local n = GetAchievementNumCriteria(achID)
        if not n or n == 0 then self:SetHeight(1); self:Hide(); return end

        local vis = math.min(n, CFG.MAX_CRITERIA)
        local yOff = -CFG.EXPANSION_PAD
        local scR, scG, scB = TC("success")
        local mtR2, mtG2, mtB2 = TC("mutedText")
        local btR2, btG2, btB2 = TC("bodyText")
        local acR2, acG2, acB2 = TC("accent")
        local dmR2, dmG2, dmB2 = TC("dimText")
        local hereR, hereG, hereB = 0.98, 0.60, 0.22  -- HERE orange

        -- ── "Relevant here" card (shown when achievement has scattered criteria) ──
        if hereMatches and #hereMatches > 0 then
            if not self._hereCard then
                local hc = CreateFrame("Frame", nil, self)
                hc:SetHeight(1)  -- sized dynamically
                local hcBg = hc:CreateTexture(nil, "BACKGROUND", nil, -3)
                hcBg:SetAllPoints(); hcBg:SetTexture(W8)
                hcBg:SetVertexColor(hereR, hereG, hereB, 0.08)
                -- Left accent
                local hcAcc = hc:CreateTexture(nil, "ARTWORK", nil, 1)
                hcAcc:SetWidth(3); hcAcc:SetTexture(W8)
                hcAcc:SetVertexColor(hereR, hereG, hereB, 0.60)
                hcAcc:SetPoint("TOPLEFT", hc, "TOPLEFT", 22, -4)
                hcAcc:SetPoint("BOTTOMLEFT", hc, "BOTTOMLEFT", 22, 4)
                -- Label
                local hcLabel = hc:CreateFontString(nil, "OVERLAY")
                hcLabel:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
                hcLabel:SetPoint("TOPLEFT", hc, "TOPLEFT", 32, -6)
                hcLabel:SetTextColor(hereR, hereG, hereB, 0.90)
                hcLabel:SetText("RELEVANT HERE")
                hc._label = hcLabel
                -- Zone names
                local hcZones = hc:CreateFontString(nil, "OVERLAY")
                hcZones:SetFont(STANDARD_TEXT_FONT, 11, "")
                hcZones:SetPoint("TOPLEFT", hcLabel, "BOTTOMLEFT", 0, -4)
                hcZones:SetPoint("RIGHT", hc, "RIGHT", -20, 0)
                hcZones:SetJustifyH("LEFT"); hcZones:SetWordWrap(true)
                hc._zones = hcZones
                -- Bottom line
                local hcLine = hc:CreateTexture(nil, "ARTWORK")
                hcLine:SetHeight(1); hcLine:SetTexture(W8)
                hcLine:SetVertexColor(hereR, hereG, hereB, 0.15)
                hcLine:SetPoint("BOTTOMLEFT", hc, "BOTTOMLEFT", 22, 0)
                hcLine:SetPoint("BOTTOMRIGHT", hc, "BOTTOMRIGHT", -20, 0)
                self._hereCard = hc
            end

            local card = self._hereCard
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", self, "TOPLEFT", 0, yOff)
            card:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, yOff)

            local zoneText = table.concat(hereMatches, "  \194\183  ")
            card._zones:SetText(zoneText)
            card._zones:SetTextColor(btR2, btG2, btB2, 0.85)

            -- Height: label(10) + gap(4) + zones(~14) + padding
            local zonesHeight = card._zones:GetStringHeight() or 14
            local cardHeight = 6 + 10 + 4 + zonesHeight + 8
            card:SetHeight(cardHeight)
            card:Show()
            yOff = yOff - cardHeight - 4
        end
        local subRowIdx = 0

        for i = 1, vis do
            local cStr, criteriaType, cDone, qty, req, _, _, assetID = GetAchievementCriteriaInfo(achID, i)
            if not cStr or cStr == "" then
                cStr = achDesc or "Progress"
            end

            -- Detect sub-achievements (criteriaType 8 = ACHIEVEMENT)
            local subAchID = nil
            if criteriaType == 8 and assetID and assetID > 0 then
                subAchID = assetID
            end

            if not self._rows[i] then
                local rf = CreateFrame("Button", nil, self)
                rf:SetHeight(CFG.CRITERIA_H)
                rf:RegisterForClicks("LeftButtonUp")
                -- Status indicator: atlas texture for complete, fontstring for incomplete
                local indCheck = rf:CreateTexture(nil, "OVERLAY")
                indCheck:SetSize(14, 14)
                indCheck:SetPoint("LEFT", rf, "LEFT", 30, 0)
                indCheck:SetAtlas("achievementcompare-GreenCheckmark")
                indCheck:Hide(); rf._indCheck = indCheck

                local indDash = rf:CreateFontString(nil, "OVERLAY")
                indDash:SetFont(STANDARD_TEXT_FONT, 11, "")
                indDash:SetPoint("LEFT", rf, "LEFT", 30, 0)
                indDash:SetWidth(14); indDash:SetJustifyH("CENTER")
                indDash:Hide(); rf._indDash = indDash

                -- Text (anchored to right of indicator area)
                local ct = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                ct:SetPoint("LEFT", rf, "LEFT", 48, 0)
                ct:SetPoint("RIGHT", rf, "CENTER", 60, 0)
                ct:SetJustifyH("LEFT"); ct:SetWordWrap(false); rf._tx = ct
                -- Progress
                local pt = rf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                pt:SetPoint("RIGHT", rf, "RIGHT", -20, 0); pt:SetJustifyH("RIGHT"); rf._pg = pt
                -- Mini progress bar
                local mb = MakeProgressBar(rf, 80, 3)
                mb:SetPoint("RIGHT", pt, "LEFT", -8, 0); rf._mb = mb
                -- Hover highlight for clickable rows
                local hl = rf:CreateTexture(nil, "HIGHLIGHT")
                hl:SetAllPoints(); hl:SetTexture(W8); hl:SetVertexColor(1, 1, 1, 0.03)
                self._rows[i] = rf
            end

            local row = self._rows[i]
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", self, "TOPLEFT", 0, yOff)
            row:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, yOff)
            row._tx:SetText(cStr or "???")
            row._subAchID = subAchID

            if cDone then
                row._indCheck:Show(); row._indDash:Hide()
                row._tx:SetTextColor(scR, scG, scB, 0.70)
                row._pg:SetText(""); row._pg:Hide()
                row._mb:SetProgress(1, scR, scG, scB); row._mb:SetAlpha(0.30)
            else
                row._indCheck:Hide(); row._indDash:Show()
                row._indDash:SetText("\226\128\147")
                row._indDash:SetTextColor(mtR2, mtG2, mtB2, 0.50)
                row._tx:SetTextColor(btR2, btG2, btB2, 0.80)
                if req and req > 0 and qty then
                    row._pg:SetText(qty .. "/" .. req)
                    local p2 = qty / req
                    if p2 >= 0.8 then row._pg:SetTextColor(acR2, acG2, acB2, 0.85)
                    else row._pg:SetTextColor(mtR2, mtG2, mtB2, 0.65) end
                    row._mb:SetProgress(p2); row._mb:SetAlpha(0.70)
                    row._pg:Show()
                else
                    row._pg:SetText(""); row._pg:Hide()
                    row._mb:SetProgress(0); row._mb:SetAlpha(0.15)
                end
            end

            -- If this is a sub-achievement, show expand hint
            if subAchID then
                row._tx:SetText(cStr .. "  \194\187")  -- » expand hint
                -- Click to toggle sub-expansion
                row:SetScript("OnClick", function(self2)
                    local key = achID .. "_" .. i
                    f._subExpanded[key] = not f._subExpanded[key]
                    f:SetCriteria(achID, bucketR, bucketG, bucketB, achDesc)
                end)
                -- Tooltip
                row:SetScript("OnEnter", function(self2)
                    if self2._subAchID then
                        GameTooltip:SetOwner(self2, "ANCHOR_RIGHT")
                        GameTooltip:SetAchievementByID(self2._subAchID)
                        GameTooltip:Show()
                    end
                end)
                row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            else
                row:SetScript("OnClick", nil)
                row:SetScript("OnEnter", nil)
                row:SetScript("OnLeave", nil)
            end

            row._mb:Show(); row:Show()
            yOff = yOff - CFG.CRITERIA_H

            -- ── Sub-achievement nested criteria (one level deep) ──
            local subKey = achID .. "_" .. i
            if subAchID and f._subExpanded[subKey] then
                local subN = GetAchievementNumCriteria(subAchID)
                if subN and subN > 0 then
                    local subVis = math.min(subN, 8)
                    for si = 1, subVis do
                        local sStr, _, sDone, sQty, sReq = GetAchievementCriteriaInfo(subAchID, si)
                        if not sStr or sStr == "" then sStr = "..." end

                        subRowIdx = subRowIdx + 1
                        if not self._subRows[subRowIdx] then
                            local sf = CreateFrame("Frame", nil, self)
                            sf:SetHeight(CFG.CRITERIA_H)
                            -- Atlas checkmark for complete
                            local sCheck = sf:CreateTexture(nil, "OVERLAY")
                            sCheck:SetSize(12, 12)
                            sCheck:SetPoint("LEFT", sf, "LEFT", 50, 0)
                            sCheck:SetAtlas("achievementcompare-GreenCheckmark")
                            sCheck:Hide(); sf._indCheck = sCheck
                            -- Dash for incomplete
                            local sDash = sf:CreateFontString(nil, "OVERLAY")
                            sDash:SetFont(STANDARD_TEXT_FONT, 10, "")
                            sDash:SetPoint("LEFT", sf, "LEFT", 50, 0)
                            sDash:SetWidth(12); sDash:SetJustifyH("CENTER")
                            sDash:Hide(); sf._indDash = sDash

                            local sTx = sf:CreateFontString(nil, "OVERLAY")
                            sTx:SetFont(STANDARD_TEXT_FONT, 10, "")
                            sTx:SetPoint("LEFT", sf, "LEFT", 66, 0)
                            sTx:SetPoint("RIGHT", sf, "CENTER", 40, 0)
                            sTx:SetJustifyH("LEFT"); sTx:SetWordWrap(false); sf._tx = sTx
                            local sPg = sf:CreateFontString(nil, "OVERLAY")
                            sPg:SetFont(STANDARD_TEXT_FONT, 10, "")
                            sPg:SetPoint("RIGHT", sf, "RIGHT", -20, 0)
                            sPg:SetJustifyH("RIGHT"); sf._pg = sPg
                            self._subRows[subRowIdx] = sf
                        end

                        local sRow = self._subRows[subRowIdx]
                        sRow:ClearAllPoints()
                        sRow:SetPoint("TOPLEFT", self, "TOPLEFT", 0, yOff)
                        sRow:SetPoint("TOPRIGHT", self, "TOPRIGHT", 0, yOff)
                        sRow._tx:SetText(sStr)

                        if sDone then
                            sRow._indCheck:Show(); sRow._indDash:Hide()
                            sRow._tx:SetTextColor(scR, scG, scB, 0.55)
                            sRow._pg:SetText("")
                        else
                            sRow._indCheck:Hide(); sRow._indDash:Show()
                            sRow._indDash:SetText("\226\128\147")
                            sRow._indDash:SetTextColor(dmR2, dmG2, dmB2, 0.40)
                            sRow._tx:SetTextColor(mtR2, mtG2, mtB2, 0.60)
                            if sReq and sReq > 0 and sQty then
                                sRow._pg:SetText(sQty .. "/" .. sReq)
                                sRow._pg:SetTextColor(dmR2, dmG2, dmB2, 0.50)
                            else
                                sRow._pg:SetText("")
                            end
                        end
                        sRow:Show()
                        yOff = yOff - CFG.CRITERIA_H
                    end
                end
            end
        end

        self:SetHeight(CFG.EXPANSION_PAD + math.abs(yOff) + CFG.EXPANSION_PAD - CFG.EXPANSION_PAD)
        self:Show()
    end

    f._used = true; _exps[#_exps + 1] = f; return f
end

ReleaseExps = function()
    for _, e in ipairs(_exps) do e._used = false; e:Hide(); e:ClearAllPoints() end
end


-- ============================================================================
-- VIRTUAL SCROLL — ResolveAchievementData, PopulateAchievementRow,
-- BuildDisplayList, VirtualScrollUpdate, UpdateScrollChildHeight,
-- UpdateHeroSection, UpdateStatPills, Panel.Rebuild, Panel.Show
-- ============================================================================

local _emptyLabel = nil

-- ── Resolve achievement data on demand (lazy, cached per item) ──────────
ResolveAchievementData = function(item)
    if item._resolved then return item._data end

    local achID = item.achID
    if not achID then item._resolved = true; item._data = nil; return nil end

    -- Check if seasonal entry cache has pre-resolved data
    local seasonalCache = Panel._state._seasonalEntryCache
    if seasonalCache and seasonalCache[achID] then
        item._data = seasonalCache[achID]
        item._resolved = true
        return item._data
    end

    local id, name, points, completed, month, day, year, desc, flags, icon,
          reward, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
    if not id then item._resolved = true; item._data = nil; return nil end

    local catID = GetAchievementCategory(achID)
    local pct, cd, ct = 0, 0, 0
    if not wasEarned then
        pct, cd, ct = GetAchievementProgress(id)
    else
        pct = 1
    end

    local tag, tagC = GetAchievementTag(id, catID)
    local earnedDate = nil
    if wasEarned and month and day and year then
        earnedDate = string.format("%d/%d/%d", month, day, year)
    end

    local rewardDisplay = nil
    if reward and reward ~= "" then
        rewardDisplay = reward:gsub("^Reward:%s*", "")
    end

    -- Determine zone label for nearby achievements
    local zoneLbl = nil
    if item.bucketKey == "nearby" or item.bucketKey == "nearby_ids" then
        local achMapIDs = GetCachedMapsForAch(achID)
        local hereSet = Panel._state._deferredHereSet
        for _, m in ipairs(achMapIDs) do
            if not hereSet or not hereSet[m] then
                local mi = C_Map.GetMapInfo(m)
                if mi and mi.name then zoneLbl = mi.name; break end
            end
        end
    end

    local data = {
        id = id, name = name or "", description = desc or "", points = points or 0,
        icon = icon, progress = pct, critDone = cd, critTotal = ct,
        catID = catID, tag = tag, tagColor = tagC,
        reward = rewardDisplay,
        completed = wasEarned, earnedDate = earnedDate,
        contentType = GetAchievementContentType(achID),
        _zone = zoneLbl,
    }

    item._data = data
    item._resolved = true
    return data
end

-- ── Populate an achievement row frame from resolved data ────────────────
PopulateAchievementRow = function(frame, data, bucketKey)
    if not frame or not data then return end
    frame._data = data

    local ttR2, ttG2, ttB2 = TC("titleText")
    local btR2, btG2, btB2 = TC("bodyText")
    local mtR2, mtG2, mtB2 = TC("mutedText")
    local dmR, dmG, dmB = TC("dimText")
    local scR, scG, scB = TC("success")

    -- Icon
    if data.icon then frame._ico:SetTexture(data.icon); frame._ico:Show()
    else frame._ico:Hide() end

    -- Reward badge on icon (points indicator)
    if data.points and data.points > 0 then
        frame._rewIco:SetTexture("Interface\\Icons\\Achievement_General")
        frame._rewIco:Show(); frame._rewBord:Show()
    else
        frame._rewIco:Hide(); frame._rewBord:Hide()
    end

    -- Reward icon (left of progress bar) — only shown if achievement has a reward
    local rewTex, rewType = GetRewardIcon(data.id, data.reward)
    if rewTex and rewType ~= "none" then
        frame._rewIcon2:SetTexture(rewTex)
        frame._rewIcon2:SetAlpha(rewType == "title" and 0.60 or 0.85)
        frame._rewIcon2:Show(); frame._rewBord2:Show()
        frame._rewBord2:SetAlpha(0.30)
        -- Set tooltip data on the hit overlay
        frame._rewHit._rewardText = data.reward
        frame._rewHit._rewardType = rewType
        frame._rewHit:Show()
    else
        frame._rewIcon2:Hide(); frame._rewBord2:Hide()
        frame._rewHit:Hide()
    end

    -- Reward text line
    local rewLine = nil
    if data.reward and data.reward ~= "" then
        if data.points > 0 then
            rewLine = data.points .. " pts  \194\183  " .. data.reward
        else
            rewLine = data.reward
        end
    elseif data.points and data.points > 0 then
        rewLine = data.points .. " achievement pts"
    end
    if rewLine then
        local ptR, ptG, ptB = TC("accent")
        frame._rewTx:SetText(rewLine)
        frame._rewTx:SetTextColor(ptR, ptG, ptB, 0.60)
        frame._rewTx:Show()
    else
        frame._rewTx:Hide()
    end

    if data.completed then
        -- ── COMPLETED row: green tint, checkmark, earned date ──
        frame._ttl:SetText(data.name)
        frame._ttl:SetTextColor(scR, scG, scB, 0.85)

        local dt = data.description or ""
        if #dt > 70 then dt = dt:sub(1, 67) .. "..." end
        frame._desc:SetText(dt)
        frame._desc:SetTextColor(scR, scG, scB, 0.40)

        frame._pct:SetText("\226\156\147") -- checkmark
        frame._pct:SetTextColor(scR, scG, scB, 0.80)
        frame._pct:Show()

        frame._pbar:Show()
        frame._pbar:SetProgress(1, scR, scG, scB)

        if data.earnedDate then
            frame._crit:SetText(data.earnedDate)
            frame._crit:SetTextColor(scR, scG, scB, 0.40)
            frame._crit:Show()
        else
            frame._crit:Hide()
        end

        if data.tag and data.tagColor then
            local tc = data.tagColor
            frame._pill:Set(data.tag, tc.r, tc.g, tc.b, 0.12)
            frame._pill:Show()
        else
            frame._pill:Hide()
        end

        frame._cbg:SetVertexColor(scR * 0.15, scG * 0.15, scB * 0.15, 0.50)

    elseif bucketKey == "undiscovered" then
        -- ── UNDISCOVERED row: muted styling ──
        frame._ttl:SetText(data.name)
        frame._ttl:SetTextColor(mtR2, mtG2, mtB2, 0.85)
        local dt = data.description or ""
        if #dt > 70 then dt = dt:sub(1, 67) .. "..." end
        frame._desc:SetText(dt)
        frame._desc:SetTextColor(dmR, dmG, dmB, 0.55)
        frame._pbar:Show(); frame._pbar:SetProgress(0)
        frame._pct:Hide()
        if data.critTotal and data.critTotal > 0 then
            frame._crit:SetText("0/" .. data.critTotal .. " criteria")
            frame._crit:SetTextColor(dmR, dmG, dmB, 0.45); frame._crit:Show()
        else frame._crit:Hide() end
        if data.tag and data.tagColor then
            local tc = data.tagColor
            frame._pill:Set(data.tag, tc.r, tc.g, tc.b, 0.12); frame._pill:Show()
        else frame._pill:Hide() end
        frame._cbg:SetVertexColor(TC("cardBg"))

    else
        -- ── INCOMPLETE row: normal styling ──
        frame._ttl:SetText(data.name)
        if data.progress > 0 then
            frame._ttl:SetTextColor(btR2, btG2, btB2, 1)
        else
            frame._ttl:SetTextColor(mtR2, mtG2, mtB2, 0.85)
        end

        local dt = data.description or ""
        if data._zone then dt = data._zone .. "  \194\183  " .. dt end
        if #dt > 70 then dt = dt:sub(1, 67) .. "..." end
        frame._desc:SetText(dt)
        frame._desc:SetTextColor(dmR, dmG, dmB, 0.65)

        if data.progress > 0 then
            local pctVal = math.floor(data.progress * 100)
            frame._pbar:Show()
            frame._pbar:SetProgress(data.progress)
            frame._pct:SetText(pctVal .. "%")
            if pctVal >= 80 then frame._pct:SetTextColor(ttR2, ttG2, ttB2, 1)
            elseif pctVal >= 50 then frame._pct:SetTextColor(btR2, btG2, btB2, 0.80)
            else frame._pct:SetTextColor(mtR2, mtG2, mtB2, 0.65) end
            frame._pct:Show()
        else
            frame._pbar:Show(); frame._pbar:SetProgress(0)
            frame._pct:SetText(""); frame._pct:Hide()
        end

        if data.critTotal and data.critTotal > 0 then
            frame._crit:SetText(data.critDone .. "/" .. data.critTotal .. " criteria")
            frame._crit:SetTextColor(mtR2, mtG2, mtB2, 0.75)
            frame._crit:Show()
        else
            frame._crit:Hide()
        end

        if data.tag and data.tagColor then
            local tc = data.tagColor
            frame._pill:Set(data.tag, tc.r, tc.g, tc.b, 0.15)
            frame._pill:Show()
        else
            frame._pill:Hide()
        end

        frame._cbg:SetVertexColor(TC("cardBg"))
    end

    frame:Show()
end

-- ── Filter helper: check if achID passes search/content filters ─────────
local function PassesFilter(achID, filter, contentFilter)
    if filter ~= "" then
        local _, name, _, _, _, _, _, desc = GetAchievementInfo(achID)
        name = name or ""
        desc = desc or ""
        if not name:lower():find(filter, 1, true) and not desc:lower():find(filter, 1, true) then
            return false
        end
    end
    if contentFilter then
        if GetAchievementContentType(achID) ~= contentFilter then
            return false
        end
    end
    return true
end

-- ── Count IDs passing filters ───────────────────────────────────────────
local function CountFilteredIDs(idList, filter, contentFilter)
    if filter == "" and not contentFilter then return #idList end
    local count = 0
    for _, achID in ipairs(idList) do
        if PassesFilter(achID, filter, contentFilter) then count = count + 1 end
    end
    return count
end

-- ── BuildDisplayList ────────────────────────────────────────────────────
-- Builds a flat array of display items from bucket ID arrays.
-- Each item: { type, height, yOffset, achID, bucketKey, subKey, ... }
BuildDisplayList = function()
    local p = Panel._state.panel
    if not p then return end

    local B = Panel._state.buckets
    local filter = Panel._state.searchFilter or ""
    local activeBucket = Panel._state.activeBucket
    local contentFilter = Panel._state.activeContentType
    local displayList = {}
    local yOff = 0

    -- Helper: count total undiscovered
    local function CountUndiscovered()
        local t = 0
        for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
            local ids = B.undiscovered_ids and B.undiscovered_ids[sk]
            if ids then t = t + #ids end
        end
        return t
    end

    for _, bucketKey in ipairs(CFG.BUCKET_ORDER) do
        if activeBucket and activeBucket ~= bucketKey then
            -- skip
        else
            local isUndiscovered = (bucketKey == "undiscovered")
            local idKey = bucketKey .. "_ids"
            local idList = B[idKey] or {}

            local totalCount
            if isUndiscovered then
                totalCount = CountUndiscovered()
            else
                totalCount = CountFilteredIDs(idList, filter, contentFilter)
            end

            local showBucket = totalCount > 0 or (bucketKey == "progress" and Panel._state.asyncScanning)

            if showBucket then
                local collapsed = Panel._state.bucketCollapse[bucketKey]
                local scanning = bucketKey == "progress" and Panel._state.asyncScanning

                -- Bucket header
                displayList[#displayList + 1] = {
                    type = "bucket_header",
                    height = CFG.BUCKET_H,
                    yOffset = yOff,
                    bucketKey = bucketKey,
                    count = totalCount,
                    collapsed = collapsed,
                    scanning = scanning,
                }
                yOff = yOff + CFG.BUCKET_H

                if not collapsed then
                    if isUndiscovered then
                        -- Undiscovered sub-sections
                        for _, subDef in ipairs(CFG.UNDISCOVERED_SUBS) do
                            local subIDs = B.undiscovered_ids and B.undiscovered_ids[subDef.key] or {}
                            local filteredCount = CountFilteredIDs(subIDs, filter, contentFilter)
                            if filteredCount > 0 then
                                local subCollapsed = Panel._state.subBucketCollapse[subDef.key]

                                -- Sub-header
                                displayList[#displayList + 1] = {
                                    type = "sub_header",
                                    height = CFG.SUBHEADER_H,
                                    yOffset = yOff,
                                    bucketKey = bucketKey,
                                    subKey = subDef.key,
                                    subLabel = subDef.label,
                                    count = filteredCount,
                                    collapsed = subCollapsed,
                                }
                                yOff = yOff + CFG.SUBHEADER_H

                                if not subCollapsed then
                                    for _, achID in ipairs(subIDs) do
                                        if PassesFilter(achID, filter, contentFilter) then
                                            local itemH = CFG.ROW_H + CFG.ROW_GAP
                                            local expH = 0
                                            if Panel._state.expanded[achID] then
                                                -- Estimate expansion height based on criteria count
                                                local cn = GetAchievementNumCriteria(achID) or 0
                                                local vis = math.min(cn, CFG.MAX_CRITERIA)
                                                expH = CFG.EXPANSION_PAD + vis * CFG.CRITERIA_H + CFG.EXPANSION_PAD + 2
                                            end

                                            displayList[#displayList + 1] = {
                                                type = "achievement",
                                                height = itemH,
                                                yOffset = yOff,
                                                achID = achID,
                                                bucketKey = "undiscovered",
                                            }
                                            yOff = yOff + itemH

                                            if expH > 0 then
                                                displayList[#displayList + 1] = {
                                                    type = "expansion",
                                                    height = expH,
                                                    yOffset = yOff,
                                                    achID = achID,
                                                    bucketKey = "undiscovered",
                                                }
                                                yOff = yOff + expH
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    else
                        -- Normal bucket achievements
                        for _, achID in ipairs(idList) do
                            if PassesFilter(achID, filter, contentFilter) then
                                local itemH = CFG.ROW_H + CFG.ROW_GAP
                                local expH = 0
                                if Panel._state.expanded[achID] then
                                    local cn = GetAchievementNumCriteria(achID) or 0
                                    local vis = math.min(cn, CFG.MAX_CRITERIA)
                                    expH = CFG.EXPANSION_PAD + vis * CFG.CRITERIA_H + CFG.EXPANSION_PAD + 2
                                end

                                displayList[#displayList + 1] = {
                                    type = "achievement",
                                    height = itemH,
                                    yOffset = yOff,
                                    achID = achID,
                                    bucketKey = bucketKey,
                                }
                                yOff = yOff + itemH

                                if expH > 0 then
                                    displayList[#displayList + 1] = {
                                        type = "expansion",
                                        height = expH,
                                        yOffset = yOff,
                                        achID = achID,
                                        bucketKey = bucketKey,
                                    }
                                    yOff = yOff + expH
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- Empty state item
    if yOff == 0 then
        displayList[#displayList + 1] = {
            type = "empty",
            height = 120,
            yOffset = 0,
        }
        yOff = 120
    end

    -- Building indicator at bottom
    if Panel._state.cacheScanRunning and #displayList > 0 and displayList[1].type ~= "empty" then
        displayList[#displayList + 1] = {
            type = "building",
            height = 30,
            yOffset = yOff,
        }
        yOff = yOff + 30
    end

    Panel._state.displayList = displayList
    Panel._state.totalHeight = yOff + 20
    Panel._state.lastScrollOffset = -1  -- force re-render
end

-- ── UpdateScrollChildHeight ─────────────────────────────────────────────
UpdateScrollChildHeight = function()
    local p = Panel._state.panel
    if not p or not p._child then return end
    p._child:SetHeight(math.max(Panel._state.totalHeight, 1))
end

-- ── VirtualScrollUpdate ─────────────────────────────────────────────────
-- Binary search for first visible item, linear scan forward, bind to pool frames.
VirtualScrollUpdate = function(scrollOffset)
    local p = Panel._state.panel
    if not p or not p._child then return end

    scrollOffset = scrollOffset or 0
    local dl = Panel._state.displayList
    if not dl or #dl == 0 then
        ReleaseRows(); ReleaseBuckets(); ReleaseExps()
        return
    end

    local viewportHeight = p._scroll:GetHeight()
    if viewportHeight <= 0 then viewportHeight = CFG.HEIGHT - CFG.HEADER_H - CFG.HERO_H - CFG.SEARCH_H - 22 - 10 end

    -- Binary search for first visible item
    local lo, hi = 1, #dl
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local item = dl[mid]
        if item.yOffset + item.height <= scrollOffset then
            lo = mid + 1
        else
            hi = mid
        end
    end

    -- Find visible range
    local firstVisible = lo
    local lastVisible = firstVisible
    for i = firstVisible, #dl do
        if dl[i].yOffset >= scrollOffset + viewportHeight then break end
        lastVisible = i
    end

    -- Add buffer (2 items above/below)
    firstVisible = math.max(1, firstVisible - 2)
    lastVisible = math.min(#dl, lastVisible + 2)

    Panel._state.visibleStart = firstVisible
    Panel._state.visibleEnd = lastVisible

    -- Release all pool frames
    ReleaseRows(); ReleaseBuckets(); ReleaseExps()
    if _emptyLabel then _emptyLabel:Hide() end
    if Panel._state._buildLabel then Panel._state._buildLabel:Hide() end

    local child = p._child
    local filter = Panel._state.searchFilter or ""

    -- Bind visible items to pool frames
    for i = firstVisible, lastVisible do
        local item = dl[i]
        if not item then break end

        if item.type == "bucket_header" then
            local bh = AcquireBucket(child)
            bh:ClearAllPoints()
            bh:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -item.yOffset)
            bh:SetPoint("RIGHT", child, "RIGHT")
            bh:SetData(item.bucketKey, item.count, item.collapsed, item.scanning)
            bh:Show()

        elseif item.type == "sub_header" then
            local bR2, bG2, bB2 = BucketColor(item.bucketKey)
            local subH = AcquireBucket(child)
            subH:ClearAllPoints()
            subH:SetPoint("TOPLEFT", child, "TOPLEFT", 16, -item.yOffset)
            subH:SetPoint("RIGHT", child, "RIGHT")
            subH:SetHeight(CFG.SUBHEADER_H)
            subH._bg:SetVertexColor(bR2, bG2, bB2, 0.03)
            subH._bAcc:SetVertexColor(bR2, bG2, bB2, 0.40)
            subH._lbl:SetFont(STANDARD_TEXT_FONT, 10, "OUTLINE")
            subH._lbl:SetText(item.subLabel)
            subH._lbl:SetTextColor(bR2, bG2, bB2, 0.65)
            subH._cnt:SetText(tostring(item.count))
            subH._cnt:SetTextColor(bR2, bG2, bB2, 0.55)
            subH._bLine:SetVertexColor(bR2, bG2, bB2, 0.06)
            subH._chev:Expand(not item.collapsed)
            subH._chev:Color(bR2, bG2, bB2, 0.30)
            subH._key = "sub_" .. item.subKey
            local capturedSubKey = item.subKey
            subH:SetScript("OnClick", function(self)
                Panel._state.subBucketCollapse[capturedSubKey] = not Panel._state.subBucketCollapse[capturedSubKey]
                BuildDisplayList()
                UpdateScrollChildHeight()
                VirtualScrollUpdate(p._scroll:GetVerticalScroll())
            end)
            subH:Show()

        elseif item.type == "achievement" then
            local data = ResolveAchievementData(item)
            if data then
                local row = AcquireRow(child)
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -item.yOffset)
                row:SetPoint("RIGHT", child, "RIGHT")
                PopulateAchievementRow(row, data, item.bucketKey)
            end

        elseif item.type == "expansion" then
            local parentItem = nil
            -- Find the preceding achievement item to get resolved data
            for j = i - 1, 1, -1 do
                if dl[j].type == "achievement" and dl[j].achID == item.achID then
                    parentItem = dl[j]; break
                end
            end
            if parentItem then
                local data = ResolveAchievementData(parentItem)
                if data then
                    local bR2, bG2, bB2 = BucketColor(item.bucketKey)
                    local exp = AcquireExpansion(child)
                    exp:ClearAllPoints()
                    exp:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -item.yOffset)
                    exp:SetPoint("RIGHT", child, "RIGHT")
                    exp:SetCriteria(data.id, bR2, bG2, bB2, data.description, data._hereMatches)
                    -- Update the display list item height to match actual
                    local actualH = exp:GetHeight() + 2
                    if actualH ~= item.height then
                        item.height = actualH
                        local nextYOff = item.yOffset + actualH
                        for k = i + 1, #dl do
                            dl[k].yOffset = nextYOff
                            nextYOff = nextYOff + dl[k].height
                        end
                        Panel._state.totalHeight = nextYOff + 20
                        UpdateScrollChildHeight()
                    end
                    exp:Show()
                end
            end

        elseif item.type == "empty" then
            if not _emptyLabel then
                _emptyLabel = child:CreateFontString(nil, "OVERLAY")
                _emptyLabel:SetFont(STANDARD_TEXT_FONT, 14, "")
                _emptyLabel:SetWidth(CFG.WIDTH - 80)
            end
            _emptyLabel:SetParent(child); _emptyLabel:ClearAllPoints()
            _emptyLabel:SetPoint("TOP", child, "TOP", 0, -50)
            local dmR2, dmG2, dmB2 = TC("dimText")
            _emptyLabel:SetTextColor(dmR2, dmG2, dmB2, 0.60)
            if filter ~= "" then _emptyLabel:SetText("No achievements match \"" .. filter .. "\"")
            elseif Panel._state.cacheScanRunning then _emptyLabel:SetText("Building achievement index\226\128\166")
            elseif Panel._state.asyncScanning then _emptyLabel:SetText("Scanning achievements\226\128\166")
            else _emptyLabel:SetText("No trackable achievements found for this area.") end
            _emptyLabel:Show()

        elseif item.type == "building" then
            if not Panel._state._buildLabel then
                Panel._state._buildLabel = child:CreateFontString(nil, "OVERLAY")
                Panel._state._buildLabel:SetFont(STANDARD_TEXT_FONT, 11, "")
                Panel._state._buildLabel:SetWidth(CFG.WIDTH - 80)
                Panel._state._buildLabel:SetJustifyH("CENTER")
            end
            local bl = Panel._state._buildLabel
            bl:SetParent(child); bl:ClearAllPoints()
            bl:SetPoint("TOP", child, "TOP", 0, -item.yOffset)
            local dmR2, dmG2, dmB2 = TC("dimText")
            bl:SetTextColor(dmR2, dmG2, dmB2, 0.50)
            bl:SetText("Building achievement index\226\128\166")
            bl:Show()
        end
    end
end

-- ── UpdateHeroSection ───────────────────────────────────────────────────
UpdateHeroSection = function()
    local p = Panel._state.panel
    if not p then return end

    -- Update hero breadcrumb
    local crumbs = BuildMapBreadcrumbs(Panel._state.currentMapID)
    if #crumbs > 0 then
        local mtHex = "B59E70"
        local ttHex = "F5DE94"
        local sepHex = "685D46"
        local parts = {}
        for i, name in ipairs(crumbs) do
            if i == #crumbs then
                parts[#parts + 1] = "|cFF" .. ttHex .. name .. "|r"
            else
                parts[#parts + 1] = "|cFF" .. mtHex .. name .. "|r"
            end
        end
        local sep = "  |cFF" .. sepHex .. "\194\183|r  "
        p._heroBreadcrumb:SetText(table.concat(parts, sep))
    else
        p._heroBreadcrumb:SetText(Panel._state.currentZone or "")
    end

    -- Hero progress bar
    local B = Panel._state.buckets
    local hereN = B.here_ids and #B.here_ids or 0
    local undiscZone = B.undiscovered_ids and B.undiscovered_ids.zone and #B.undiscovered_ids.zone or 0
    local totalZone = hereN + undiscZone
    if totalZone > 0 then
        p._heroBar:SetProgress(hereN / totalZone)
    else
        p._heroBar:SetProgress(0)
    end

    UpdateStatPills()
end

-- ── UpdateStatPills ─────────────────────────────────────────────────────
UpdateStatPills = function()
    local p = Panel._state.panel
    if not p then return end

    local B = Panel._state.buckets
    local activeBucket = Panel._state.activeBucket
    local totalPts = 0
    local acR, acG, acB = TC("accent")

    for _, key in ipairs(CFG.BUCKET_ORDER) do
        local count
        if key == "undiscovered" then
            count = 0
            for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
                local ids = B.undiscovered_ids and B.undiscovered_ids[sk]
                if ids then
                    count = count + #ids
                    -- Sum points for these IDs
                    for _, achID in ipairs(ids) do
                        local _, _, pts = GetAchievementInfo(achID)
                        totalPts = totalPts + (pts or 0)
                    end
                end
            end
        else
            local idKey = key .. "_ids"
            local ids = B[idKey] or {}
            count = #ids
            for _, achID in ipairs(ids) do
                local _, _, pts = GetAchievementInfo(achID)
                totalPts = totalPts + (pts or 0)
            end
        end

        local pill = p._heroPills[key]
        if pill then
            local bc = CFG.BUCKET_COLORS[key]
            pill._lbl:SetText(bc.label)
            pill._cnt:SetText(tostring(count))
            local w = 3 + 8 + (pill._lbl:GetStringWidth() or 30) + 6 + (pill._cnt:GetStringWidth() or 12) + 12
            pill:SetWidth(math.max(80, w))

            local active = activeBucket == key
            pill._bg:SetVertexColor(bc.r, bc.g, bc.b, active and 0.22 or 0.10)
            pill._dot:SetVertexColor(bc.r, bc.g, bc.b, active and 1 or 0.65)
        end
    end

    if totalPts > 0 then
        local ptsText = totalPts .. " pts available"
        p._heroPoints._tx:SetText(ptsText)
        local ptsW = 3 + 8 + (p._heroPoints._tx:GetStringWidth() or 60) + 12
        p._heroPoints:SetWidth(math.max(80, ptsW))
        p._heroPoints:Show()
    else
        p._heroPoints:Hide()
    end

    -- Update filter button styles
    if p._filterBtns then
        for _, btn in ipairs(p._filterBtns) do btn:UpdateStyle() end
    end
end

-- ============================================================================
-- REBUILD — Lightweight wrapper
-- ============================================================================

function Panel.Rebuild()
    local p = Panel._state.panel
    if not p then return end
    UpdateHeroSection()
    UpdateStatPills()
    BuildDisplayList()
    UpdateScrollChildHeight()
    VirtualScrollUpdate(p._scroll:GetVerticalScroll())
end


-- ============================================================================
-- SHOW / HIDE / TOGGLE
-- ============================================================================

function Panel.Show()
    local p = Panel.EnsurePanel()
    if not p then return end

    -- Deferred AchCache init: load on first panel open instead of ADDON_LOADED
    if not AchCache and Panel._state.addonLoaded then
        InitAchCache()
        if AchCache and not AchCache.scanComplete then
            StartCacheBuild()
        elseif AchCache and AchCache.maxScannedID > 0 then
            local currentBuild = GetGameBuild()
            local cachedBuild = AchCache.build or "0"
            if currentBuild ~= cachedBuild then
                AchCache.build = currentBuild
                StartIncrementalCacheScan()
            end
        end
        if IsCacheReady() then CollectZoneBuckets() end
        -- PreWarmTextures is defined later in file; use indirect call
        C_Timer.NewTimer(2, function() if PreWarmTextures then PreWarmTextures() end end)
    end

    -- Collect data synchronously BEFORE showing (ID-only, fast)
    local curMapID = C_Map.GetBestMapForUnit("player")
    local curInfo = curMapID and C_Map.GetMapInfo(curMapID)
    local curZone = curInfo and curInfo.name or ""
    local needRescan = (curZone ~= Panel._state.zoneCacheKey)

    if needRescan then CollectZoneBuckets() end

    -- Show panel with data already populated — no flash of empty counts
    p:Show(); p:SetAlpha(0)
    if p._fadeIn then p._fadeIn:Stop(); p._fadeIn:Play() else p:SetAlpha(1) end
    Panel._state.panelOpen = true
    Panel.Rebuild()

    -- Force a second rebuild on next frame — the scroll frame may not
    -- have its dimensions computed on the first Rebuild, causing the
    -- virtual scroll to miscalculate the visible range.
    C_Timer.NewTimer(0, function()
        if Panel.IsOpen() then Panel.Rebuild() end
    end)

    -- Async scan deferred to next frame (for IN PROGRESS bucket)
    if needRescan or (Panel._state.buckets.progress_ids and #Panel._state.buckets.progress_ids == 0 and not Panel._state.asyncScanning) then
        C_Timer.NewTimer(0, function()
            if Panel.IsOpen() then StartAsyncScan() end
        end)
    end
end

function Panel.Hide()
    local p = Panel._state.panel
    if not p then return end
    CancelAsync()
    if p._fadeOut then p._fadeOut:Stop(); p._fadeOut:Play() else p:Hide() end
    Panel._state.panelOpen = false
end

function Panel.Toggle()
    if Panel._state.panelOpen and Panel._state.panel and Panel._state.panel:IsShown() then
        Panel.Hide()
    else
        Panel.Show()
    end
end

function Panel.IsOpen()
    return Panel._state.panelOpen and Panel._state.panel and Panel._state.panel:IsShown()
end

-- ── Texture Pre-Warmer ──────────────────────────────────────────────────
-- Creates a hidden frame with textures set to achievement icons.
-- WoW loads textures even on hidden frames, warming the GPU texture cache
-- so the first panel open doesn't hitch on disk I/O.
-- Runs in chunks to avoid a frame spike.

local _preWarmFrame = nil
local _preWarmTimer = nil

local function PreWarmTextures()
    if _preWarmFrame then return end  -- already running or done
    if not AchCache or not AchCache.scanComplete then return end

    _preWarmFrame = CreateFrame("Frame")
    _preWarmFrame:Hide()

    -- Collect unique icons from cached achievements
    local iconQueue = {}
    local iconSet = {}
    for achID, _ in pairs(AchCache.achMaps) do
        local _, _, _, _, _, _, _, _, _, icon = GetAchievementInfo(achID)
        if icon and not iconSet[icon] then
            iconSet[icon] = true
            iconQueue[#iconQueue + 1] = icon
        end
    end

    -- Also pre-warm the reward icons
    local rewardIcons = {
        REWARD_ICON_UNKNOWN,
        "Interface\\Icons\\Achievement_General",
        "Interface\\Icons\\Achievement_General_StayClassy",
        "Interface\\Icons\\Ability_Mount_RidingHorse",
        "Interface\\Icons\\INV_Pet_BabyBlizzardBear",
        "Interface\\Icons\\INV_Misc_Toy_02",
        "Interface\\Icons\\INV_Shirt_GuildTabard_01",
        "Interface\\Icons\\INV_Misc_Gift_05",
    }
    for _, ico in ipairs(rewardIcons) do
        if not iconSet[ico] then iconQueue[#iconQueue + 1] = ico end
    end

    -- Create textures in chunks (20 per frame to avoid hitches)
    local texPool = {}
    local idx = 1
    local WARM_CHUNK = 20

    local function WarmChunk()
        if idx > #iconQueue then
            -- Done — clean up
            _preWarmTimer = nil
            return
        end
        local limit = math.min(idx + WARM_CHUNK - 1, #iconQueue)
        for i = idx, limit do
            local tex = texPool[i]
            if not tex then
                tex = _preWarmFrame:CreateTexture(nil, "BACKGROUND")
                tex:SetSize(1, 1)
                tex:SetAlpha(0)
                texPool[i] = tex
            end
            tex:SetTexture(iconQueue[i])
        end
        idx = limit + 1
        _preWarmTimer = C_Timer.NewTimer(0, WarmChunk)
    end

    _preWarmTimer = C_Timer.NewTimer(0, WarmChunk)
end


-- ============================================================================
-- EVENTS
-- ============================================================================

local evf = CreateFrame("Frame")
local function SafeReg(ev) pcall(function() evf:RegisterEvent(ev) end) end
SafeReg("ADDON_LOADED")
SafeReg("PLAYER_LOGOUT")
SafeReg("ZONE_CHANGED"); SafeReg("ZONE_CHANGED_NEW_AREA"); SafeReg("ZONE_CHANGED_INDOORS")
SafeReg("ACHIEVEMENT_EARNED"); SafeReg("CRITERIA_UPDATE"); SafeReg("CRITERIA_EARNED")
SafeReg("TRACKED_ACHIEVEMENT_UPDATE")

local _rebuildTimer = nil
local function DeferRebuild()
    if _rebuildTimer then pcall(function() _rebuildTimer:Cancel() end) end
    _rebuildTimer = C_Timer.NewTimer(0.5, function()
        if Panel.IsOpen() then
            InvalidateCache(); CollectZoneBuckets(); Panel.Rebuild(); StartAsyncScan()
        end
    end)
end

local function DeferLightRebuild()
    if _rebuildTimer then pcall(function() _rebuildTimer:Cancel() end) end
    _rebuildTimer = C_Timer.NewTimer(0.3, function()
        if Panel.IsOpen() then
            InvalidateCache(); CollectZoneBuckets(); Panel.Rebuild()
        end
    end)
end

evf:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- AchCache loading deferred to Panel.Show() to save ~2 MB at login
        -- Only mark that ADDON_LOADED has fired so deferred init knows SVs are ready
        Panel._state.addonLoaded = true
    elseif event == "PLAYER_LOGOUT" then
        -- Clean up all running timers to prevent leaks
        CancelCacheBuild()
        CancelAsync()
        if _rebuildTimer then pcall(function() _rebuildTimer:Cancel() end); _rebuildTimer = nil end
    elseif event == "ZONE_CHANGED" or event == "ZONE_CHANGED_NEW_AREA" or event == "ZONE_CHANGED_INDOORS" then
        wipe(Panel._state.expanded)
        if IsCacheReady() then
            DeferLightRebuild()
        else
            DeferRebuild()
        end
    elseif event == "ACHIEVEMENT_EARNED" then
        DeferLightRebuild()
    elseif event == "CRITERIA_UPDATE" or event == "CRITERIA_EARNED" then
        if Panel.IsOpen() then DeferLightRebuild() end
    elseif event == "TRACKED_ACHIEVEMENT_UPDATE" then
        if Panel.IsOpen() then Panel.Rebuild() end
    end
end)


-- ============================================================================
-- DIAGNOSTICS — /achdiag slash command
-- ============================================================================

-- Diagnostics uses a batched approach: collect all lines into a buffer,
-- then flush as a single entry to avoid the 10/sec throttle in Diagnostics.lua.
local _diagBuffer = {}

local function DiagLine(msg)
    _diagBuffer[#_diagBuffer + 1] = msg
end

local function DiagFlush(label)
    if #_diagBuffer == 0 then return end
    local fullMsg = table.concat(_diagBuffer, "\n")
    -- Send as a single LogExternal entry (bypasses throttle since it's one call)
    if _G.MidnightUI_Diagnostics then
        if _G.MidnightUI_Diagnostics.LogExternal then
            _G.MidnightUI_Diagnostics.LogExternal(
                "AchTracker", label .. "\n" .. fullMsg, "", "", "batch=true", "Debug"
            )
        elseif _G.MidnightUI_Diagnostics.LogDebugSource then
            _G.MidnightUI_Diagnostics.LogDebugSource("AchTracker", label .. ": " .. fullMsg)
        end
    end
    wipe(_diagBuffer)
end

local function RunDiagnostics()
    wipe(_diagBuffer)

    -- ── Section 1: Environment ──
    local mapID = C_Map.GetBestMapForUnit("player")
    local info = mapID and C_Map.GetMapInfo(mapID)
    local zoneName = info and info.name or "UNKNOWN"
    local parentID = info and info.parentMapID
    local parentInfo = parentID and C_Map.GetMapInfo(parentID)
    local parentName = parentInfo and parentInfo.name or "NONE"
    local crumbs = BuildMapBreadcrumbs(mapID)
    local index = BuildMapNameIndex()
    local indexCount = 0
    for _ in pairs(index) do indexCount = indexCount + 1 end
    local holidays = GetActiveHolidays()
    local holidayNames = {}
    for kw in pairs(holidays) do holidayNames[#holidayNames + 1] = kw end
    table.sort(holidayNames)

    DiagLine("Zone: " .. zoneName .. " (mapID " .. tostring(mapID) .. ") | Parent: " .. parentName .. " (mapID " .. tostring(parentID) .. ")")
    DiagLine("Breadcrumbs: " .. (#crumbs > 0 and table.concat(crumbs, " > ") or "EMPTY"))
    DiagLine("Map index: " .. indexCount .. " entries | Holidays: " .. (#holidayNames > 0 and table.concat(holidayNames, ", ") or "NONE"))

    -- Bucket summary
    local B = Panel._state.buckets
    local bParts = {}
    for _, key in ipairs(CFG.BUCKET_ORDER) do
        local bCount
        if key == "undiscovered" then
            bCount = 0
            for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
                local ids = B.undiscovered_ids and B.undiscovered_ids[sk]
                bCount = bCount + (ids and #ids or 0)
            end
        else
            local idKey = key .. "_ids"
            local ids = B[idKey]
            bCount = ids and #ids or 0
        end
        bParts[#bParts + 1] = key:upper() .. "=" .. bCount
    end
    DiagLine("Buckets: " .. table.concat(bParts, " | "))
    DiagLine("Async: " .. tostring(Panel._state.asyncScanning) .. " | CacheZone: " .. tostring(Panel._state.zoneCacheKey))

    -- Cache stats
    if AchCache then
        local mapCount, achCount = 0, 0
        for _ in pairs(AchCache.mapIndex) do mapCount = mapCount + 1 end
        for _ in pairs(AchCache.achMaps) do achCount = achCount + 1 end
        local curCached = mapID and GetCachedAchsForMap(mapID) or {}
        local curCount = 0
        for _ in pairs(curCached) do curCount = curCount + 1 end
        DiagLine("PersistCache: v" .. (AchCache.version or "?") .. " | complete=" .. tostring(AchCache.scanComplete)
            .. " | zones=" .. mapCount .. " | achs=" .. achCount .. " | building=" .. tostring(Panel._state.cacheScanRunning)
            .. " | thisZone=" .. curCount)
    else
        DiagLine("PersistCache: NOT INITIALIZED")
    end
    DiagFlush("AchTracker Environment")

    -- ── Section 2: Category Sources ──
    DiagLine("=== Category Source Debug ===")

    -- Name matching
    local nameCats = FindCatsForZone(zoneName)
    local nc = 0; for _ in pairs(nameCats) do nc = nc + 1 end
    DiagLine("FindCatsForZone('" .. zoneName .. "'): " .. nc .. " cats")
    for cid in pairs(nameCats) do
        DiagLine("  [" .. cid .. "] " .. (GetCategoryInfo(cid) or "?"))
    end

    -- Breadcrumb expansion
    if mapID then
        for _, crumb in ipairs(crumbs) do
            local cc = FindCatsForZone(crumb)
            local ccn = 0; for _ in pairs(cc) do ccn = ccn + 1 end
            if ccn > 0 then
                DiagLine("FindCatsForZone('" .. crumb .. "'): " .. ccn .. " cats")
            end
        end
    end

    -- Reverse mapID index
    BuildMapToCategoryIndex()
    for _, mid in ipairs({ mapID, parentID }) do
        if mid then
            local mInfo = C_Map.GetMapInfo(mid)
            local mName = mInfo and mInfo.name or "?"
            local rc = GetCategoriesForMapID(mid)
            local rcn = 0; for _ in pairs(rc) do rcn = rcn + 1 end
            DiagLine("GetCategoriesForMapID(" .. mid .. " = " .. mName .. "): " .. rcn .. " cats")
            for cid in pairs(rc) do
                DiagLine("  [" .. cid .. "] " .. (GetCategoryInfo(cid) or "?"))
            end
        end
    end

    -- Grandparent
    if parentInfo and parentInfo.parentMapID then
        local gpID = parentInfo.parentMapID
        local gpInfo = C_Map.GetMapInfo(gpID)
        local gpName = gpInfo and gpInfo.name or "?"
        local gpCats = GetCategoriesForMapID(gpID)
        local gpn = 0; for _ in pairs(gpCats) do gpn = gpn + 1 end
        DiagLine("GetCategoriesForMapID(" .. gpID .. " = " .. gpName .. "): " .. gpn .. " cats")
    end

    -- Total unique
    local allCands = {}
    for c in pairs(nameCats) do allCands[c] = true end
    if mapID then
        for _, crumb in ipairs(crumbs) do
            for c in pairs(FindCatsForZone(crumb)) do allCands[c] = true end
        end
        for c in pairs(GetCategoriesForMapID(mapID)) do allCands[c] = true end
        if parentID then
            for c in pairs(GetCategoriesForMapID(parentID)) do allCands[c] = true end
            if parentInfo and parentInfo.parentMapID then
                for c in pairs(GetCategoriesForMapID(parentInfo.parentMapID)) do allCands[c] = true end
            end
        end
    end
    local totalC = 0; for _ in pairs(allCands) do totalC = totalC + 1 end
    DiagLine("Total unique candidate categories: " .. totalC)
    DiagFlush("AchTracker Categories")

    -- ── Section 3: Sample Category Scan ──
    DiagLine("=== Sample Category Scan (first 5 cats, 5 achs each) ===")
    local sCount = 0
    for catID in pairs(allCands) do
        if sCount >= 5 then break end
        sCount = sCount + 1
        local catName = GetCategoryInfo(catID) or "?"
        local numAch = GetCategoryNumAchievements(catID, false) or 0
        DiagLine("[cat " .. catID .. "] '" .. catName .. "': " .. numAch .. " achievements")

        for i = 1, math.min(5, numAch) do
            local achID = GetAchievementInfo(catID, i)
            if achID then
                local id, name, pts, _, _, _, _, _, _, _, _, isGuild, wasEarned, _, isStat = GetAchievementInfo(achID)
                if id then
                    local st
                    if isStat then st = "SKIP(stat)"
                    elseif isGuild then st = "SKIP(guild)"
                    elseif wasEarned then st = "EARNED"
                    else
                        local refs, tInc = GetAchievementZoneRefs(id)
                        local prox, _ = ClassifyProximity(refs, mapID, tInc)
                        local rn = 0; for _ in pairs(refs) do rn = rn + 1 end
                        local pct = GetAchievementProgress(id)
                        st = "prox=" .. tostring(prox) .. " refs=" .. rn .. " prog=" .. math.floor(pct*100) .. "%"
                    end
                    DiagLine("  [" .. id .. "] " .. (name or "?") .. " — " .. st)
                end
            end
        end
    end
    DiagFlush("AchTracker SampleScan")

    -- ── Section 4: Per-Bucket Detail ──
    local function DiagBucketIDs(idList, label)
        if not idList or #idList == 0 then return end
        DiagLine("=== " .. label .. " (" .. #idList .. ") ===")
        for i, achID in ipairs(idList) do
            if i > 8 then DiagLine("  ... and " .. (#idList - 8) .. " more"); break end
            local id, name, pts, _, _, _, _, desc, _, _, reward, _, wasEarned = GetAchievementInfo(achID)
            if id then
                local pct = GetAchievementProgress(id)
                local cd, ct = 0, GetAchievementNumCriteria(id) or 0
                local tag = GetAchievementTag(id, GetAchievementCategory(id))
                local line = "[" .. id .. "] " .. (name or "?")
                    .. " | " .. math.floor((pct or 0) * 100) .. "%"
                    .. " | " .. cd .. "/" .. ct .. " crit"
                    .. " | tag=" .. (tag or "-")
                if reward and reward ~= "" then line = line .. " | rew=" .. reward end
                if wasEarned then line = line .. " | DONE" end
                DiagLine("  " .. line)
            end
        end
    end

    for _, key in ipairs(CFG.BUCKET_ORDER) do
        if key == "undiscovered" then
            for _, sk in ipairs(CFG.UNDISCOVERED_SUB_ORDER) do
                local ids = B.undiscovered_ids and B.undiscovered_ids[sk]
                DiagBucketIDs(ids, "UNDISCOVERED/" .. sk:upper())
            end
            DiagFlush("AchTracker Bucket UNDISCOVERED")
        else
            local idKey = key .. "_ids"
            local ids = B[idKey]
            if ids and #ids > 0 then
                DiagBucketIDs(ids, key:upper())
                DiagFlush("AchTracker Bucket " .. key:upper())
            end
        end
    end

    -- ── Section 5: Reward Probe ──
    DiagLine("=== Reward Probe (known reward achievements) ===")
    for _, testID in ipairs({ 2144, 46, 2136, 1038 }) do
        local tid, tname, tpts, _, _, _, _, tdesc, tflags, _, treward, _, twas = GetAchievementInfo(testID)
        if tid then
            DiagLine("  [" .. tid .. "] " .. (tname or "?") .. " | reward='" .. tostring(treward) .. "' | earned=" .. tostring(twas))
        else
            DiagLine("  [" .. testID .. "] NOT FOUND")
        end
    end
    DiagFlush("AchTracker RewardProbe")

    -- ── Section 6: Tier Breakdown (first 3 HERE) ──
    local hereIDs = B.here_ids
    if hereIDs and #hereIDs > 0 then
        DiagLine("=== Tier Breakdown (HERE) ===")
        for i = 1, math.min(3, #hereIDs) do
            local achID = hereIDs[i]
            local _, achName = GetAchievementInfo(achID)
            local catRefs = GetAchievementCategoryMapIDs(achID)
            local critRefs = GetCriteriaZoneRefs(achID)
            local textRefs = GetTextZoneRefs(achID)
            local cn, crn, tn = {}, {}, {}
            for _, rd in pairs(catRefs) do if rd.name then cn[#cn+1] = rd.name end end
            for _, rd in pairs(critRefs) do if rd.name then crn[#crn+1] = rd.name end end
            for _, rd in pairs(textRefs) do if rd.name then tn[#tn+1] = rd.name end end
            DiagLine("[" .. achID .. "] " .. (achName or "?"))
            DiagLine("  T1(cat): " .. (#cn > 0 and table.concat(cn, ", ") or "none"))
            DiagLine("  T2(crit): " .. (#crn > 0 and table.concat(crn, ", ") or "none"))
            DiagLine("  T3(text): " .. (#tn > 0 and table.concat(tn, ", ") or "none"))
        end
        DiagFlush("AchTracker TierBreakdown")
    end
end

-- ============================================================================
-- STARTUP PROFILER — /achdiag startup
-- Records timestamps for every significant function during the first 10 seconds
-- after ADDON_LOADED, then dumps a timeline to chat.
-- ============================================================================

SLASH_ACHDIAG1 = "/achdiag"
SlashCmdList["ACHDIAG"] = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "rebuild" then
        -- Force full cache rebuild
        if AchCache then
            CancelCacheBuild()
            AchCache.scanComplete = false
            AchCache.maxScannedID = 0
            wipe(AchCache.mapIndex)
            wipe(AchCache.achMaps)
            wipe(AchCache.flags)
            _explorationMined = false
            DiagPrint("AchTracker Rebuild", "Cache cleared. Starting full rebuild...")
            StartCacheBuild()
        else
            DiagPrint("AchTracker Rebuild", "Cache not initialized yet.")
        end
        return
    elseif msg == "cache" then
        -- Show cache stats
        if not AchCache then
            DiagPrint("AchTracker Cache", "Cache not initialized.")
            return
        end
        local mapCount, achCount, flagCount = 0, 0, 0
        for _ in pairs(AchCache.mapIndex) do mapCount = mapCount + 1 end
        for _ in pairs(AchCache.achMaps) do achCount = achCount + 1 end
        for _ in pairs(AchCache.flags) do flagCount = flagCount + 1 end
        local totalMappings = 0
        for _, achs in pairs(AchCache.mapIndex) do
            for _ in pairs(achs) do totalMappings = totalMappings + 1 end
        end
        local lines = {
            "Version: " .. (AchCache.version or "?"),
            "Complete: " .. tostring(AchCache.scanComplete),
            "Max scanned ID: " .. (AchCache.maxScannedID or 0),
            "Zones with achievements: " .. mapCount,
            "Achievements mapped: " .. achCount,
            "Total zone-ach mappings: " .. totalMappings,
            "Flagged achievements: " .. flagCount,
            "Building: " .. tostring(Panel._state.cacheScanRunning),
        }
        local curMapID = Panel._state.currentMapID
        if curMapID then
            local cached = GetCachedAchsForMap(curMapID)
            local zoneCount = 0
            for _ in pairs(cached) do zoneCount = zoneCount + 1 end
            local curInfo = C_Map.GetMapInfo(curMapID)
            lines[#lines + 1] = "Current zone (" .. (curInfo and curInfo.name or "?") .. "): " .. zoneCount .. " cached achievements"
        end
        DiagPrint("AchTracker Cache", table.concat(lines, "\n"))
        return
    end
    RunDiagnostics()
end

-- File parse complete — record total top-level execution time
