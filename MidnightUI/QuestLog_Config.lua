-- =============================================================================
-- FILE PURPOSE:     Quest-log panel constants — layout dimensions, bucket colors,
--                   bucket labels, difficulty colors, and time-sensitive tag IDs.
--                   Also provides two convenience accessors (GetThemeColor, GetBucketColor)
--                   used by QuestLog_Panel.lua and Map.lua during rendering.
-- LOAD ORDER:       Loads after Map_Config.lua, before QuestLog_Data.lua (reads Addon.MapConfig).
--                   Contains the same early-exit guard as Map_Config:
--                   useBlizzardQuestingInterface == true → immediate return.
-- DEFINES:          Addon.QuestLogConfig (table QLC) with all layout constants and colors.
--                   QLC.GetThemeColor(key) — delegates to Addon.MapConfig.GetThemeColor.
--                   QLC.GetBucketColor(bucketKey) — returns r,g,b for a quest bucket.
-- READS:            Addon.MapConfig (reads MapConfig.GetThemeColor for shared palette).
--                   MidnightUISettings.General.useBlizzardQuestingInterface (early-exit gate).
-- WRITES:           Addon.QuestLogConfig.
-- DEPENDS ON:       Map_Config.lua (Addon.MapConfig must exist — fails gracefully if absent).
-- USED BY:          QuestLog_Data.lua, QuestLog_Panel.lua, Map.lua — read Addon.QuestLogConfig.
-- KEY CONSTANTS:
--   BUCKET_COLORS / BUCKET_LABELS / BUCKET_ORDER — "now/next/later/turnIn/expiring" buckets.
--   CONDITIONAL_ORDER — sections that appear only when relevant (turnIn/expiring).
--   EXPIRING_EXTRACT_THRESHOLD (7200s = 2h) — quests expiring within 2 hours move to "expiring".
--   TIME_SENSITIVE_TAG_IDS — quest tag IDs (world quests, invasions, bonus objectives)
--     that mark a quest as time-sensitive regardless of duration.
--   DIFFICULTY_COLORS — trivial/standard/difficult/veryhard/impossible progression colors.
--   NEARLY_COMPLETE_THRESHOLD (0.80) — quests ≥80% complete get a "nearly done" visual hint.
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

local MapConfig = Addon.MapConfig
local function GetMapColor(key)
    if MapConfig and type(MapConfig.GetThemeColor) == "function" then
        return MapConfig.GetThemeColor(key)
    end
    return 1, 1, 1
end

local QLC = {
    -- Shared texture
    WHITE8X8 = "Interface\\Buttons\\WHITE8x8",

    -- ── Panel Dimensions ──────────────────────────────────────────────────
    PANEL_WIDTH             = 380,
    PANEL_STRATA            = "DIALOG",
    PANEL_SLIDE_DURATION    = 0.22,
    PANEL_HEADER_HEIGHT     = 68,
    PANEL_SEARCH_HEIGHT     = 26,
    PANEL_ACCENT_WIDTH      = 3,

    -- ── Quest Row Layout ──────────────────────────────────────────────────
    QUEST_ROW_HEIGHT        = 44,
    QUEST_ROW_GAP           = 4,
    QUEST_ROW_ACCENT_WIDTH  = 3,
    QUEST_ROW_PROGRESS_HEIGHT = 2,
    QUEST_ROW_PAD_LEFT      = 14,
    QUEST_ROW_PAD_RIGHT     = 14,

    -- ── Inline Expansion ──────────────────────────────────────────────────
    EXPANSION_PADDING       = 8,
    EXPANSION_OBJ_HEIGHT    = 20,
    EXPANSION_OBJ_INDICATOR = 6,
    EXPANSION_ACTION_HEIGHT = 28,
    EXPANSION_FADE_IN       = 0.12,
    EXPANSION_FADE_OUT      = 0.10,

    -- ── Bucket Headers ────────────────────────────────────────────────────
    BUCKET_HEADER_HEIGHT    = 32,
    BUCKET_ACCENT_WIDTH     = 4,

    -- ── Zone Sub-Headers ──────────────────────────────────────────────────
    ZONE_HEADER_HEIGHT      = 24,
    ZONE_DOT_SIZE           = 6,

    -- ── Campaign Card ─────────────────────────────────────────────────────
    CAMPAIGN_CARD_HEIGHT    = 52,
    CAMPAIGN_ACCENT_WIDTH   = 4,
    CAMPAIGN_PROGRESS_HEIGHT = 6,

    -- ── Focus Header ──────────────────────────────────────────────────────
    FOCUS_HEADER_HEIGHT     = 28,
    FOCUS_ACCENT_WIDTH      = 5,

    -- ── Empty State ───────────────────────────────────────────────────────
    EMPTY_STATE_HEIGHT      = 80,

    -- ── Objective Rows (inside expansion) ─────────────────────────────────
    MAX_VISIBLE_OBJECTIVES  = 6,

    -- ── Bucket Colors ─────────────────────────────────────────────────────
    BUCKET_COLORS = {
        now   = { r = 0.98, g = 0.60, b = 0.22, hex = "FA9938" },
        next  = { r = 0.45, g = 0.72, b = 0.92, hex = "73B8EB" },
        later    = { r = 0.58, g = 0.52, b = 0.43, hex = "94856E" },
        turnIn   = { r = 0.34, g = 0.82, b = 0.46, hex = "57D176" },
        expiring = { r = 1.00, g = 0.52, b = 0.20, hex = "FF8533" },
    },
    BUCKET_LABELS = { now = "NOW", next = "NEXT", later = "LATER", turnIn = "TURN IN", expiring = "EXPIRING" },
    BUCKET_ORDER  = { "now", "next", "later" },

    -- ── Conditional Smart Sections ───────────────────────────────────────
    CONDITIONAL_ORDER        = { "turnIn", "expiring" },
    EXPIRING_EXTRACT_THRESHOLD = 7200,  -- extract quests expiring within 2 hours

    -- ── Focus ─────────────────────────────────────────────────────────────
    FOCUS_LABEL = "FOCUS",
    FOCUS_COLOR = { r = 1.00, g = 0.84, b = 0.30 },

    -- ── Difficulty Colors ─────────────────────────────────────────────────
    DIFFICULTY_COLORS = {
        trivial    = { r = 0.50, g = 0.50, b = 0.50 },
        standard   = { r = 0.25, g = 0.75, b = 0.25 },
        difficult  = { r = 1.00, g = 0.82, b = 0.00 },
        veryhard   = { r = 1.00, g = 0.50, b = 0.25 },
        impossible = { r = 1.00, g = 0.10, b = 0.10 },
    },

    -- ── Synergy / Co-Op ───────────────────────────────────────────────────
    COMBO_PURPLE = { r = 0.58, g = 0.42, b = 0.78 },
    NEARLY_COMPLETE_THRESHOLD = 0.80,

    -- ── Time-Sensitive Tag IDs ────────────────────────────────────────────
    TIME_SENSITIVE_TAG_IDS = {
        [109] = true,   -- World Quest
        [111] = true,   -- World Quest (Epic)
        [112] = true,   -- World Quest (PvP)
        [113] = true,   -- World Quest (Petbattle)
        [136] = true,   -- World Quest (Dungeon)
        [137] = true,   -- World Quest (Invasion)
        [141] = true,   -- World Quest (Profession)
        [151] = true,   -- Threat Quest (BfA)
        [259] = true,   -- Threat (Shadowlands)
        [266] = true,   -- Bonus Objective (Dragonflight)
        [282] = true,   -- World Quest (TWW-era)
    },

    -- ── Semantic Colors ───────────────────────────────────────────────────
    COLORS = {
        success       = { r = 0.34, g = 0.82, b = 0.46 },
        warning       = { r = 1.00, g = 0.52, b = 0.20 },
        story         = { r = 1.00, g = 0.84, b = 0.28 },
        progressTrack = { r = 0.20, g = 0.17, b = 0.12, a = 0.20 },
        progressBg    = { r = 0.04, g = 0.03, b = 0.02, a = 0.30 },
    },
}

-- Accessor that pulls from MapConfig theme colors with fallback
function QLC.GetThemeColor(key)
    return GetMapColor(key)
end

-- Convenience: get a bucket color as r, g, b
function QLC.GetBucketColor(bucketKey)
    local c = QLC.BUCKET_COLORS[bucketKey] or QLC.BUCKET_COLORS.later
    return c.r, c.g, c.b
end

Addon.QuestLogConfig = QLC
