-- =============================================================================
-- FILE PURPOSE:     Shared configuration table for the entire map + quest-log subsystem.
--                   Defines layout dimensions, animation timings, theme colors, and
--                   scroll/zoom method lists. Consumed by Map.lua, QuestLog_Config.lua,
--                   QuestLog_Data.lua, QuestLog_Panel.lua, and QuestInterface.lua via
--                   the Addon.MapConfig reference.
-- LOAD ORDER:       First of six files in the map/quest subsystem (Map_Config →
--                   QuestLog_Config → QuestLog_Data → QuestLog_Panel → Map →
--                   QuestInterface). Loads after MidnightWeeklyTracker.lua. MUST load
--                   before all other map/quest files. Contains an early-exit guard: if
--                   MidnightUISettings.General.useBlizzardQuestingInterface == true,
--                   this file returns immediately and the entire map subsystem is skipped.
-- DEFINES:          Addon.MapConfig (table MapConfig) with:
--                   MapConfig.GetThemeColor(key) — returns r,g,b for MAP_THEME_COLORS[key].
--                   All layout constants (HEADER_*_HEIGHT, CONTROL_*, NAV_*, MAP_*, etc.)
--                   MAP_THEME_COLORS{} — warm gold palette (accent, bg variants, text variants)
--                   QUEST_TAB_MODE_KEYS{} — {"Quests", "Events", "MapLegend"}
--                   SCROLL_PROBE_METHODS{} — list of Blizzard scroll API candidates to test.
-- READS:            MidnightUISettings.General.useBlizzardQuestingInterface — master gate.
-- WRITES:           Addon.MapConfig — stored on the Addon namespace shared via `...` vararg.
-- DEPENDS ON:       Nothing — pure constant table. Must load before any consumer.
-- USED BY:          QuestLog_Config.lua, QuestLog_Data.lua, QuestLog_Panel.lua,
--                   Map.lua, QuestInterface.lua — all read Addon.MapConfig.
-- GOTCHAS:
--   The early-exit `do ... return end` block at the top of this file (and every other
--   map/quest file) means all five files must share the same guard condition. If the
--   master toggle changes at runtime, a /reload is required to re-enable the subsystem.
--   SCROLL_PROBE_METHODS: Map.lua iterates these to find which zoom/scroll API exists
--   on the current WoW version's WorldMapFrame canvas — the list covers 9.x–12.x.
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

local MapConfig = {
    MODULE_SOURCE = "MapSkin",
    WHITE8X8 = "Interface\\Buttons\\WHITE8x8",
    DEBUG_PROBE_PREFIX = "map_probe",
    QUEST_TAB_ART_PROBE_PREFIX = "map_tab_art",
    QUEST_TAB_ART_CAPTURE_DELAY = 0.18,
    QUEST_TAB_ART_CAPTURE_FOLLOWUP_DELAY = 0.90,
    QUEST_TAB_ART_CHUNK_SIZE = 24,

    -- Rebalanced layout heights for a more modern breathing room
    HEADER_TOP_HEIGHT = 40,
    HEADER_NAV_HEIGHT = 34,
    CONTROL_BUTTON_SIZE = 28,
    CONTROL_SPACING = 6,
    NAV_HOME_TO_FIRST_GAP = 1,
    FLOOR_DROPDOWN_WIDTH = 220,
    FLOOR_DROPDOWN_MIN_WIDTH = 136,
    FLOOR_DROPDOWN_MAX_WIDTH = 220,
    HEADER_HORIZONTAL_PADDING = 14,
    NAV_MIN_BREADCRUMB_WIDTH = 300,
    CONTROL_RAIL_MAX_WIDTH_FACTOR = 0.46,
    MAP_MAXIMIZED_TOP_INSET = 36,
    MAP_MAXIMIZED_BOTTOM_INSET = 34,
    MAP_DEFAULT_SCREEN_BORDER = 30,
    MAP_MAXIMIZED_SCALE = 0.84,
    MAP_CONTAINER_SHADOW_SIZE = 24,
    MAP_CONTAINER_SHADOW_ALPHA = 0.55,
    MAP_CONTAINER_SHADOW_CORNER_ALPHA = 0.34,
    MAP_CONTAINER_SHADOW_SOFT_PAD = 42,
    MAP_CONTAINER_SHADOW_SOFT_ALPHA = 0.68,
    MAP_CONTAINER_SHADOW_SOFT_TEXTURE = "Interface\\GLUES\\MODELS\\UI_MainMenu\\BlizzShadow",

    -- Transition settings for smooth dimension handling
    MAP_TRANSITION_FADE_DUR = 0.35,
    SCROLL_PROBE_METHODS = {
        "SetPanTarget",
        "SetZoomTarget",
        "SetNormalizedZoom",
        "PanAndZoomTo",
        "PanAndZoomToNormalized",
        "SetCanvasScale",
        "ScrollToMap",
    },

    -- Shared chevron dimensions for all custom dropdown arrows.
    ARROW_WIDTH = 12,
    ARROW_HEIGHT = 8,
    ARROW_STROKE_LENGTH = 7,
    ARROW_STROKE_THICKNESS = 2,
    ARROW_STROKE_X_OFFSET = 2,
    ARROW_ROTATION = 0.70,
    FACTION_ICON_ATLAS = "ui-storm-headerorb-level0",
    -- ui-storm-headerorb-level0 atlas is 182x220; keep ratio in compact map header control.
    FACTION_ICON_WIDTH = 18,
    FACTION_ICON_HEIGHT = 21,
    QUEST_LOG_ICON_TEXTURE = "Interface\\GossipFrame\\AvailableQuestIcon",
    QUEST_LOG_PANEL_WIDTH = 380,
    QUEST_LOG_PANEL_INSET = 0,
    QUEST_LOG_SLIDE_DURATION = 0.22,
    QUEST_LOG_PANEL_HEADER_HEIGHT = 72,
    QUEST_LOG_PANEL_CONTENT_INSET = 0,
    QUEST_LOG_PANEL_TAB_HEIGHT = 28,
    QUEST_LOG_PANEL_TAB_WIDTH = 100,
    QUEST_LOG_PANEL_TAB_MIN_WIDTH = 88,
    QUEST_LOG_PANEL_TAB_MAX_WIDTH = 118,
    QUEST_LOG_PANEL_TAB_GAP = 4,
    QUEST_LOG_PANEL_STRATA = "DIALOG",

    -- Quest list layout — refined spacing
    QUEST_LIST_CAMPAIGN_HEIGHT      = 62,
    QUEST_LIST_HEADER_HEIGHT        = 28,
    QUEST_LIST_QUEST_ROW_HEIGHT     = 22,
    QUEST_LIST_OBJECTIVE_ROW_HEIGHT = 18,
    QUEST_LIST_HEADER_GAP           = 4,
    QUEST_LIST_QUEST_GAP            = 2,
    QUEST_LIST_OBJECTIVE_GAP        = 1,
    QUEST_LIST_OBJECTIVE_INDENT     = 20,
    QUEST_LIST_CONTENT_PADDING      = 6,

    -- Refined warm palette — deeper, more sophisticated
    MAP_THEME_COLORS = {
        accent = { 0.72, 0.62, 0.42 },       -- warm gold #B89E6B
        accentMid = { 0.62, 0.52, 0.34 },     -- medium gold #9E8557
        accentDark = { 0.50, 0.40, 0.24 },     -- dark gold #80663D
        bgHeader = { 0.08, 0.065, 0.04 },      -- deep warm charcoal
        bgPanel = { 0.055, 0.045, 0.03 },      -- near-black warm
        bgPanelRaised = { 0.10, 0.08, 0.05 },  -- slightly lifted surface
        bgPanelAlt = { 0.14, 0.11, 0.07 },     -- card surface
        border = { 0.28, 0.22, 0.14 },         -- subtle warm border
        borderStrong = { 0.38, 0.30, 0.20 },   -- emphasis border
        textPrimary = { 0.94, 0.89, 0.78 },    -- warm white #F0E3C7
        textSecondary = { 0.74, 0.66, 0.52 },  -- muted warm #BDA885
        textMuted = { 0.52, 0.46, 0.34 },      -- subtle text #857557
        textDisabled = { 0.38, 0.34, 0.26 },   -- disabled #615742
        ink = { 0.06, 0.05, 0.03 },            -- near-black for marks
    },

    DIAG_LEVEL_RANK = { error = 1, warn = 2, info = 3, debug = 4, trace = 5 },
    QUEST_TAB_MODE_KEYS = { "Quests", "Events", "MapLegend" },
}

function MapConfig.GetThemeColor(key)
    local color = MapConfig.MAP_THEME_COLORS[key]
    if not color then
        return 1, 1, 1
    end
    return color[1], color[2], color[3]
end

Addon.MapConfig = MapConfig
