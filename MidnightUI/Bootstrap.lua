-- =============================================================================
-- FILE PURPOSE:     Installs a stub debug logger before Core.lua loads so any
--                   file that calls MidnightUI_Debug() early never errors out.
-- LOAD ORDER:       First file in the TOC; must run before every other MidnightUI
--                   file, including Core.lua.
-- DEFINES:          _G.MidnightUI_DebugQueue (table), _G.MidnightUI_DiagnosticsQueue (table),
--                   _G.MidnightUI_Debug (stub function)
-- READS:            Nothing — no SavedVariables are available this early.
-- WRITES:           _G.MidnightUI_DebugQueue, _G.MidnightUI_DiagnosticsQueue,
--                   _G.MidnightUI_Debug
-- DEPENDS ON:       Nothing.
-- USED BY:          Any MidnightUI file that calls MidnightUI_Debug() before
--                   Core.lua has finished loading. Core.lua replaces the stub
--                   with the real implementation and calls M.FlushDebugQueue().
-- KEY FLOWS:        1. Bootstrap.lua loads → queues initialized, stub installed.
--                   2. Any early MidnightUI_Debug("msg") call → message appended
--                      to MidnightUI_DebugQueue instead of being lost.
--                   3. Core.lua ADDON_LOADED → M.FlushDebugQueue() drains queue
--                      into the real ring-buffer logger.
-- GOTCHAS:          The stub guard (`if not _G.MidnightUI_Debug`) means this file
--                   is safe to re-enter (e.g. /reload) without double-installing.
--                   SafeToString uses two pcall layers because some Blizzard values
--                   pass tostring() but then taint on concatenation.
-- =============================================================================

_G.MidnightUI_DebugQueue      = _G.MidnightUI_DebugQueue      or {}
_G.MidnightUI_DiagnosticsQueue = _G.MidnightUI_DiagnosticsQueue or {}

-- PURPOSE:   Convert any value to a printable string without ever raising an error.
-- CONTEXT:   Called by the stub logger for every variadic argument. Needed because
--            Blizzard's taint system can make even tostring() throw on secret values,
--            and a second pcall is required because some values pass tostring() but
--            taint on concatenation.
-- INPUTS:    value (any) - The value to stringify.
-- OUTPUTS:   string — safe representation, or "[Restricted Message Hidden]" on failure.
-- RISKS:     Both pcall layers must stay; removing either exposes taint crashes.
local function SafeToString(value)
    if value == nil then
        return "nil"
    end

    local ok, text = pcall(tostring, value)
    if not ok then
        return "[Restricted Message Hidden]"
    end

    local safe = "[Restricted Message Hidden]"
    if pcall(function()
        safe = table.concat({ text }, "")
    end) then
        return safe
    end

    return "[Restricted Message Hidden]"
end

-- PURPOSE:   Queue debug messages before the real M.Debug logger exists.
-- CONTEXT:   Installed only if Core.lua has not yet replaced _G.MidnightUI_Debug.
--            Serializes all variadic args via SafeToString and appends the joined
--            string to MidnightUI_DebugQueue for later flushing by Core.
-- INPUTS:    ... (any) - Variadic values to log.
-- WRITES:    _G.MidnightUI_DebugQueue
if not _G.MidnightUI_Debug then
    _G.MidnightUI_Debug = function(...)
        local count = select("#", ...)
        local parts = {}

        for i = 1, count do
            parts[i] = SafeToString(select(i, ...))
        end

        _G.MidnightUI_DebugQueue[#_G.MidnightUI_DebugQueue + 1] = table.concat(parts, " ")
    end
end
