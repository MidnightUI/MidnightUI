-- =============================================================================
-- FILE PURPOSE:     Load-safe stub for the weekly activity tracker module.
--                   Registers the module namespace (Addon.WeeklyTracker) and logs
--                   that it loaded as a stub. No UI, no events, no data collection.
-- LOAD ORDER:       Loads after Minimap.lua, before Map_Config.lua. Because this is a
--                   stub, load order has no practical effect on other modules.
-- DEFINES:          Addon.WeeklyTracker.{initialized=true, enabled=false}.
-- READS:            Nothing.
-- WRITES:           Nothing persistent.
-- DEPENDS ON:       MidnightUI_Diagnostics.LogDebugSource (optional logging only).
-- USED BY:          Nothing — stub is a placeholder; no other module references it.
-- GOTCHAS:          This module is intentionally not implemented. The stub exists to
--                   reserve the namespace and prevent nil-index errors if any future code
--                   references Addon.WeeklyTracker before implementation ships.
-- =============================================================================

local ADDON_NAME, Addon = ...
if type(ADDON_NAME) ~= "string" or ADDON_NAME == "" then
    ADDON_NAME = "MidnightUI"
end
if type(Addon) ~= "table" then
    Addon = {}
end

local MODULE_NAME = "MidnightWeeklyTracker"

Addon.WeeklyTracker = Addon.WeeklyTracker or {}
local WeeklyTracker = Addon.WeeklyTracker

local function Log(message)
    if _G.MidnightUI_Diagnostics and type(_G.MidnightUI_Diagnostics.LogDebugSource) == "function" then
        _G.MidnightUI_Diagnostics.LogDebugSource(MODULE_NAME, tostring(message))
    elseif _G.MidnightUI_Debug then
        _G.MidnightUI_Debug("[" .. MODULE_NAME .. "] " .. tostring(message))
    end
end

if not WeeklyTracker.initialized then
    WeeklyTracker.initialized = true
    WeeklyTracker.enabled = false
    Log("Module loaded (stub).")
end

